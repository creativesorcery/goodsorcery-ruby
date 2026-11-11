# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # A bounded queue of serialized events (JSON strings) between the app's
    # threads and the delivery worker. push never blocks: when the queue
    # already holds max_size events, or the new one would take it past
    # max_bytes, the new event is dropped and counted. The worker takes
    # batches and reports when each is done, so wait_until_idle can tell
    # when everything queued has been handled.
    class EventQueue
      attr_reader :dropped

      def initialize(max_size:, batch_size:, max_bytes: Float::INFINITY)
        @max_size = max_size
        @max_bytes = max_bytes
        @batch_size = batch_size
        @items = []
        @bytes = 0
        @in_flight = 0
        @dropped = 0
        @closed = false
        @flushing = false
        @mutex = Mutex.new
        @arrived = ConditionVariable.new
        @idle = ConditionVariable.new
        @wakeup = ConditionVariable.new
      end

      def push(json)
        @mutex.synchronize do
          next reject if @closed || full?(json.bytesize)

          @items << json
          @bytes += json.bytesize
          @arrived.signal if @items.size == 1 || @items.size >= @batch_size
          true
        end
      end

      # Waits until a batch is due: batch_size events queued, +interval+
      # seconds since the first one arrived, a flush, or close. Returns []
      # once the queue is closed and empty.
      def take_batch(interval)
        @mutex.synchronize do
          @arrived.wait(@mutex) while @items.empty? && !@closed
          wait_for_full_batch(interval)
          batch = @items.shift(@batch_size)
          @bytes -= batch.sum(&:bytesize)
          @in_flight = batch.size
          batch
        end
      end

      def batch_done
        @mutex.synchronize do
          @in_flight = 0
          @flushing = false if @items.empty?
          @idle.broadcast if idle?
        end
      end

      def wait_until_idle(timeout)
        deadline = Clock.now + timeout
        @mutex.synchronize do
          @flushing = true
          @arrived.signal
          wait_on(@idle, deadline) until idle? || Clock.now >= deadline
          @flushing = false if idle?
          idle?
        end
      end

      # Sleeps for +seconds+ unless the queue is closed first.
      def pause(seconds)
        deadline = Clock.now + seconds
        @mutex.synchronize do
          wait_on(@wakeup, deadline) until @closed || Clock.now >= deadline
        end
      end

      def close
        @mutex.synchronize do
          @closed = true
          [@arrived, @wakeup, @idle].each(&:broadcast)
        end
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def size
        @mutex.synchronize { @items.size + @in_flight }
      end

      # Bytes of the events waiting to be taken (not counting a batch in flight).
      def bytes
        @mutex.synchronize { @bytes }
      end

      private

      def full?(incoming_bytes)
        @items.size >= @max_size || @bytes + incoming_bytes > @max_bytes
      end

      def reject
        @dropped += 1
        false
      end

      def idle?
        @items.empty? && @in_flight.zero?
      end

      def wait_for_full_batch(interval)
        deadline = Clock.now + interval
        wait_on(@arrived, deadline) until batch_due? || Clock.now >= deadline
      end

      def batch_due?
        @items.size >= @batch_size || @closed || @flushing
      end

      def wait_on(condition, deadline)
        remaining = deadline - Clock.now
        condition.wait(@mutex, remaining) if remaining.positive?
      end
    end

    # Monotonic seconds.
    module Clock
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
