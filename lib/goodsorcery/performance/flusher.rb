# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Sends the closed minutes once a minute from one background thread per
    # process ("goodsorcery-apm"), at the minute boundary plus a random
    # 2–20 s offset that spreads the server's load (DESIGN.md 8.7).
    class Flusher
      OFFSET_RANGE = (2.0..20.0)

      attr_reader :offset, :outbox

      def initialize(agent:, log:, clock: nil, offset: nil, transport: nil)
        @agent = agent
        @log = log
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_REALTIME) }
        @offset = offset || rand(OFFSET_RANGE)
        @outbox = Outbox.new(log: log, transport: transport || -> { GoodSorcery.client.transport })
        @lock = Mutex.new
        @wake = ConditionVariable.new
        @flush_lock = Mutex.new
        @stopped = false
        @dropped_seen = 0
      end

      # The next wall-clock time (seconds) to wake at after +now+.
      def next_wake_at(now)
        (((now / 60).floor + 1) * 60) + @offset
      end

      def ensure_started
        return if @stopped || @thread&.alive?

        @lock.synchronize { start_thread unless @stopped || @thread&.alive? }
      end

      def running?
        @thread&.alive? || false
      end

      # Collects the closed minutes (every minute with +include_open+) and
      # sends what is pending, stopping at +deadline+ (monotonic seconds).
      # With the :test delivery the payloads are stored instead.
      def flush(include_open: false, deadline: nil)
        @flush_lock.synchronize do
          collect(include_open ? nil : (@clock.call / 60).floor - 1)
          test_delivery? ? @outbox.store_for_tests : @outbox.send_pending(deadline)
        end
        true
      rescue StandardError => e
        @log.warn_every(:apm_flush_error, 60, "performance flush failed (#{e.class})")
        false
      end

      # Stops the thread and sends everything, including the open minute.
      def shutdown(timeout)
        thread = stop_thread
        thread&.join([timeout, 1].min) unless thread == Thread.current
        flush(include_open: true, deadline: Performance.monotonic + timeout)
      end

      # Performance monitoring was turned off: stop and forget what is pending.
      def stop!
        stop_thread
        @outbox.clear
      end

      private

      def start_thread
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          run
        end
        @thread.name = "goodsorcery-apm"
        Delivery::ExitHook.install
      end

      def stop_thread
        @lock.synchronize do
          @stopped = true
          @wake.broadcast
          @thread
        end
      end

      def run
        until @stopped
          wait_until(next_wake_at(@clock.call))
          flush unless @stopped
        end
      end

      def wait_until(target)
        @lock.synchronize do
          loop do
            remaining = target - @clock.call
            break if @stopped || remaining <= 0

            @wake.wait(@lock, remaining)
          end
        end
      end

      def collect(last_minute)
        minutes = @agent.aggregator.take(last_minute)
        traces = @agent.trace_buffer.take(last_minute)
        log_dropped_minutes
        @outbox.add(Payloads.metrics(minutes) + Payloads.traces(traces))
      end

      def log_dropped_minutes
        dropped = @agent.aggregator.dropped_minutes
        return if dropped == @dropped_seen

        @dropped_seen = dropped
        @log.warn_every(:apm_minutes_dropped, 60, "dropped #{dropped} minute(s) of performance metrics so far")
      end

      def test_delivery?
        GoodSorcery.configuration.delivery == :test
      end
    end

    # The payloads waiting to be sent, oldest first, and what to do with each
    # result (DESIGN.md 8.7): 5xx or a network error keeps the payload (with
    # its batch_id) for the next wake, up to MAX_ATTEMPTS; 429 pauses sending
    # until Retry-After; 400/401/413/415/422 drop it; 404 turns performance
    # monitoring off for the process. At most MAX_PENDING_MINUTES minutes of
    # metrics and MAX_TRACE_BODIES trace bodies wait; the oldest go first.
    class Outbox
      MAX_ATTEMPTS = 3
      MAX_TRACE_BODIES = 5
      Pending = Struct.new(:body, :attempts)

      def initialize(log:, transport:)
        @log = log
        @transport = transport
        @pending = []
        @resume_at = nil
      end

      def add(bodies)
        bodies.each { |body| @pending << Pending.new(body, 0) }
        drop_oldest(:metrics?) while pending_minutes > Aggregator::MAX_PENDING_MINUTES
        drop_oldest(:traces?) while @pending.count { |item| traces?(item) } > MAX_TRACE_BODIES
      end

      def size = @pending.size
      def clear = @pending.clear

      def send_pending(deadline = nil)
        return if paused?

        while (item = @pending.first)
          break if deadline && Performance.monotonic > deadline
          break unless handled?(@transport.call.post_apm(item.body.path, item.body.json), item)
        end
      end

      def store_for_tests
        @pending.each { |item| Performance.store_test_payload(item.body.path, JSON.parse(item.body.json)) }
        @pending.clear
      end

      private

      def metrics?(item) = item.body.minutes.positive?
      def traces?(item) = item.body.minutes.zero?
      def pending_minutes = @pending.sum { |item| item.body.minutes }

      def drop_oldest(kind)
        @pending.delete_at(@pending.index { |item| send(kind, item) })
        @log.warn_every(:apm_dropped, 60, "dropped unsent performance data (the server did not accept it in time)")
      end

      # => true to go on with the next payload.
      def handled?(result, item)
        return sent if result.success?
        return pause(result.retry_after) if result.rate_limited?
        return server_without_apm if result.not_found?
        return failed_attempt(result, item) if result.retryable?

        @pending.shift
        @log.warn_every(:apm_rejected, 60, "the server rejected performance data (#{result.description}); dropped")
        true
      end

      def sent
        @pending.shift
        true
      end

      def pause(seconds)
        @resume_at = Performance.monotonic + seconds.to_f
        false
      end

      def paused?
        return false unless @resume_at
        return true if Performance.monotonic < @resume_at

        @resume_at = nil
        false
      end

      def failed_attempt(result, item)
        item.attempts += 1
        return false if item.attempts < MAX_ATTEMPTS

        @pending.shift
        @log.warn_every(:apm_failed, 60, "could not send performance data (#{result.description}); dropped")
        false
      end

      def server_without_apm
        @log.warn_once(:apm_not_found, "the server has no performance endpoints; performance monitoring is off")
        @pending.clear
        Performance.disable!
        false
      end
    end
  end
end
