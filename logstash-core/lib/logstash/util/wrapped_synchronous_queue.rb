# encoding: utf-8

module LogStash; module Util
  class WrappedSynchronousQueue
    java_import java.util.concurrent.SynchronousQueue
    java_import java.util.concurrent.TimeUnit

    def initialize
      @queue = java.util.concurrent.SynchronousQueue.new
    end

    # Push an object to the queue if the queue is full
    # it will block until the object can be added to the queue.
    #
    # @param [Object] Object to add to the queue
    def push(obj)
      @queue.put(obj)
    end
    alias_method(:<<, :push)

    # Offer an object to the queue, wait for the specified amout of time.
    # If adding to the queue was successfull it wil return true, false otherwise.
    #
    # @param [Object] Object to add to the queue
    # @param [Integer] Time in milliseconds to wait before giving up
    # @return [Boolean] True if adding was successfull if not it return false
    def offer(obj, timeout_ms)
      @queue.offer(obj, timeout_ms, TimeUnit::MILLISECONDS)
    end

    # Blocking
    def take
      @queue.take
    end

    # Block for X millis
    def poll(millis)
      @queue.poll(millis, TimeUnit::MILLISECONDS)
    end

    def write_client
      WriteClient.new(self)
    end

    def read_client
      ReadClient.new(self)
    end

    def close
      # ignore
    end

    class ReadClient
      # We generally only want one thread at a time able to access pop/take/poll operations
      # from this queue. We also depend on this to be able to block consumers while we snapshot
      # in-flight buffers

      def initialize(queue, batch_size = 125, wait_for = 250)
        @queue = queue
        @mutex = Mutex.new
        # Note that @infilght_batches as a central mechanism for tracking inflight
        # batches will fail if we have multiple read clients in the pipeline.
        @inflight_batches = {}

        # allow the worker thread to report the execution time of the filter + output
        @inflight_clocks = {}
        @batch_size = batch_size
        @wait_for = wait_for
      end

      def close
        # noop, compat with acked queue read client
      end

      def set_batch_dimensions(batch_size, wait_for)
        @batch_size = batch_size
        @wait_for = wait_for
      end

      def set_events_metric(metric)
        @event_metric = metric
        define_initial_metrics_values(@event_metric)
      end

      def set_pipeline_metric(metric)
        @pipeline_metric = metric
        define_initial_metrics_values(@pipeline_metric)
      end

      def define_initial_metrics_values(namespaced_metric)
        namespaced_metric.gauge(:duration_in_millis, 0)
        namespaced_metric.increment(:filtered, 0)
        namespaced_metric.increment(:in, 0)
        namespaced_metric.increment(:out, 0)
      end

      def inflight_batches
        @mutex.synchronize do
          yield(@inflight_batches)
        end
      end

      def current_inflight_batch
        @inflight_batches.fetch(Thread.current, [])
      end

      def take_batch
        @mutex.synchronize do
          batch = ReadBatch.new(@queue, @batch_size, @wait_for)
          set_current_thread_inflight_batch(batch)

          # We dont actually have any events to work on so lets
          # not bother with recording metrics for them
          if batch.size > 0
            add_starting_metrics(batch)
            start_clock
          end
          batch
        end
      end

      def set_current_thread_inflight_batch(batch)
        @inflight_batches[Thread.current] = batch
      end

      def close_batch(batch)
        @mutex.synchronize do
          @inflight_batches.delete(Thread.current)
          stop_clock
        end
      end

      def start_clock
        @inflight_clocks[Thread.current] = [
          @event_metric.time(:duration_in_millis),
          @pipeline_metric.time(:duration_in_millis)
        ]
      end

      def stop_clock
        unless @inflight_clocks[Thread.current].nil?
          @inflight_clocks[Thread.current].each(&:stop)
          @inflight_clocks.delete(Thread.current)
        end
      end

      def add_starting_metrics(batch)
        @event_metric.increment(:in, batch.starting_size)
        @pipeline_metric.increment(:in, batch.starting_size)
      end

      def add_filtered_metrics(batch)
        @event_metric.increment(:filtered, batch.filtered_size)
        @pipeline_metric.increment(:filtered, batch.filtered_size)
      end

      def add_output_metrics(batch)
        @event_metric.increment(:out, batch.filtered_size)
        @pipeline_metric.increment(:out, batch.filtered_size)
      end
    end

    class ReadBatch
      def initialize(queue, size, wait)
        @originals = Hash.new

        # TODO: disabled for https://github.com/elastic/logstash/issues/6055 - will have to properly refactor
        # @cancelled = Hash.new

        @generated = Hash.new
        @iterating_temp = Hash.new
        @iterating = false # Atomic Boolean maybe? Although batches are not shared across threads
        take_originals_from_queue(queue, size, wait)
      end

      def merge(event)
        return if event.nil? || @originals.key?(event)
        # take care not to cause @generated to change during iteration
        # @iterating_temp is merged after the iteration
        if iterating?
          @iterating_temp[event] = true
        else
          # the periodic flush could generate events outside of an each iteration
          @generated[event] = true
        end
      end

      def cancel(event)
        # TODO: disabled for https://github.com/elastic/logstash/issues/6055 - will have to properly refactor
        raise("cancel is unsupported")
        # @cancelled[event] = true
      end

      def each(&blk)
        # take care not to cause @originals or @generated to change during iteration
        @iterating = true

        # below the checks for @cancelled.include?(e) have been replaced by e.cancelled?
        # TODO: for https://github.com/elastic/logstash/issues/6055 = will have to properly refactor
        @originals.each do |e, _|
          blk.call(e) unless e.cancelled?
        end
        @generated.each do |e, _|
          blk.call(e) unless e.cancelled?
        end
        @iterating = false
        update_generated
      end

      def size
        filtered_size
      end

      def starting_size
        @originals.size
      end

      def filtered_size
        @originals.size + @generated.size
      end

      def cancelled_size
      # TODO: disabled for https://github.com/elastic/logstash/issues/6055 = will have to properly refactor
      raise("cancelled_size is unsupported ")
        # @cancelled.size
      end

      private

      def iterating?
        @iterating
      end

      def update_generated
        @generated.update(@iterating_temp)
        @iterating_temp.clear
      end

      def take_originals_from_queue(queue, size, wait)
        size.times do |t|
          event = queue.poll(wait)
          return if event.nil? # queue poll timed out

          @originals[event] = true
        end
      end
    end

    class WriteClient
      def initialize(queue)
        @queue = queue
      end

      def get_new_batch
        WriteBatch.new
      end

      def push(event)
        @queue.push(event)
      end
      alias_method(:<<, :push)

      def push_batch(batch)
        batch.each do |event|
          push(event)
        end
      end
    end

    class WriteBatch
      def initialize
        @events = []
      end

      def push(event)
        @events.push(event)
      end
      alias_method(:<<, :push)

      def each(&blk)
        @events.each do |e|
          blk.call(e)
        end
      end
    end
  end
end end
