# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # The default delivery: a bounded in-memory queue drained in batches by
    # one background thread ("goodsorcery-worker"). The thread starts on the
    # first event and restarts in a forked child, which starts with an empty
    # queue (the parent still owns the events it queued).
    class Async
      DEFAULTS = {
        batch_size: 25, flush_interval: 2.0, max_queue_size: 1_000,
        max_retries: 3, shutdown_timeout: 5, backoff: nil, sleeper: nil
      }.freeze

      def initialize(transport:, serializer:, log:, **settings)
        @transport = transport
        @serializer = serializer
        @log = log
        @settings = DEFAULTS.merge(settings)
        @settings[:backoff] ||= Backoff.new
        @lock = Mutex.new
        @pid = Process.pid
        @queue = new_queue
        @thread = nil
      end

      def deliver(event)
        ensure_worker
        return true if @queue.push(event)

        @log.warn_every(:queue_full, 60, "queue full (max_queue_size #{@settings[:max_queue_size]}); " \
                                         "#{@queue.dropped} event(s) dropped so far")
        false
      end

      # Waits until every queued event has been handled. => true when drained.
      def flush(timeout = 5)
        return true unless running?

        @queue.wait_until_idle(timeout)
      end

      def shutdown(timeout = @settings[:shutdown_timeout])
        thread, queue = @lock.synchronize { [@thread, @queue] }
        return true unless thread&.alive? && @pid == Process.pid

        drained = queue.wait_until_idle(timeout)
        queue.close
        thread.join(drained ? 1 : 0.1)
        log_undelivered(queue) unless drained
        drained
      end

      def dropped_count
        @queue.dropped
      end

      def queue_size
        @queue.size
      end

      def running?
        @pid == Process.pid && @thread&.alive? ? true : false
      end

      private

      def ensure_worker
        return if running?

        @lock.synchronize { start_worker unless running? }
      end

      def start_worker
        if @pid != Process.pid
          @pid = Process.pid
          @queue = new_queue
        end
        @queue = new_queue if @queue.closed?
        @thread = spawn_thread(build_worker)
        ExitHook.install
      end

      def spawn_thread(worker)
        thread = Thread.new do
          Thread.current.report_on_exception = false
          worker.run
        end
        thread.name = "goodsorcery-worker"
        thread
      end

      def build_worker
        Worker.new(queue: @queue, transport: @transport, serializer: @serializer, log: @log,
                   settings: @settings.slice(:flush_interval, :max_retries, :backoff, :sleeper))
      end

      def new_queue
        EventQueue.new(max_size: @settings[:max_queue_size], batch_size: @settings[:batch_size])
      end

      def log_undelivered(queue)
        @log.warn("shutdown timed out with #{queue.size} event(s) undelivered")
      end
    end

    # Drains the queue when the process exits (registered once, on the first
    # background delivery).
    module ExitHook
      @installed = false

      def self.install
        return if @installed

        @installed = true
        at_exit { GoodSorcery.shutdown }
      end
    end
  end
end
