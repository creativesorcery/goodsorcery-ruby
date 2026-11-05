# frozen_string_literal: true

require_relative "performance/histogram"
require_relative "performance/uuid_v7"
require_relative "performance/process_label"
require_relative "performance/sql_normalizer"
require_relative "performance/call_site"
require_relative "performance/recorder"
require_relative "performance/transaction_stats"
require_relative "performance/aggregator"
require_relative "performance/trace_buffer"
require_relative "performance/span_list"
require_relative "performance/trace_builder"
require_relative "performance/payloads"
require_relative "performance/flusher"
require_relative "performance/job_timing"
require_relative "performance/subscribers"
require_relative "performance/net_http"
require_relative "performance/agent"
require_relative "performance/measurement"

module GoodSorcery
  # Performance monitoring (DESIGN.md 8): metrics for every request and job,
  # and traces of the slowest ones, aggregated in process and sent once a
  # minute. Off unless config.performance_monitoring is true; then
  # Performance.install (the Railtie calls it after the app initialized)
  # subscribes to Rails' notifications and instruments Net::HTTP. Nothing
  # here ever raises into the host app.
  module Performance
    RECORDER_KEY = :__goodsorcery_recorder
    SUPPRESS_KEY = :__goodsorcery_suppress_performance
    LOCK = Mutex.new

    @active = false
    @traces = true
    @ignore = IgnoreMatcher.new([])

    extend Measurement
    extend TestPayloads

    class << self
      # Starts recording when performance_monitoring is on and the
      # environment reports (or the delivery is :test). => true when on.
      def install(config = GoodSorcery.configuration)
        return false unless config.performance_monitoring && GoodSorcery.client.performance_allowed?

        configure(config)
        Subscribers.subscribe
        NetHttp.install
        @active = true
      rescue StandardError => e
        log.warn("could not start performance monitoring (#{e.class})")
        false
      end

      # The one check integrations make per request or job.
      def active? = @active

      # Stops recording in this process (the server has no APM endpoints).
      def disable!
        @active = false
        @agent&.flusher&.stop!
      end

      def recording? = !Thread.current[RECORDER_KEY].nil?
      def current_recorder = Thread.current[RECORDER_KEY]
      def suppressed? = Thread.current[SUPPRESS_KEY] ? true : false
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Nothing is measured inside the block (the gem's own HTTP requests).
      def suppress
        previous = Thread.current[SUPPRESS_KEY]
        Thread.current[SUPPRESS_KEY] = true
        yield
      ensure
        Thread.current[SUPPRESS_KEY] = previous
      end

      # => a new recorder for this fiber, or nil when off or already recording
      # (a unit of work inside another is part of the outer one).
      def start(kind)
        return nil unless @active && Thread.current[RECORDER_KEY].nil?

        Thread.current[RECORDER_KEY] = Recorder.new(kind, traces: @traces)
      rescue StandardError
        nil
      end

      def finish(recorder)
        Thread.current[RECORDER_KEY] = nil if Thread.current[RECORDER_KEY].equal?(recorder)
        recorder.stop
        agent.record(recorder, background: GoodSorcery.configuration.delivery != :test) if recordable?(recorder)
      rescue StandardError => e
        log.warn_every(:apm_finish_error, 60, "could not record performance data (#{e.class})")
      end

      # Sends (or, with the :test delivery, stores) what was recorded.
      def flush_performance(include_open_minute: true)
        current = @agent
        return true unless current&.current?

        current.flusher.flush(include_open: include_open_minute)
      end

      def shutdown(timeout)
        current = @agent
        current.flusher.shutdown(timeout) if current&.current?
        true
      rescue StandardError
        false
      end

      def agent
        current = @agent
        return current if current&.current?

        LOCK.synchronize do
          @agent = Agent.new(GoodSorcery.configuration, log) unless @agent&.current?
          @agent
        end
      end

      def paths
        @paths ||= Backtrace::Paths.new(GoodSorcery.configuration.root)
      end

      def minute_iso(minute)
        Time.at(minute * 60).utc.strftime("%Y-%m-%dT%H:%M:00Z")
      end

      # Forgets everything recorded and turns recording off. For tests.
      def reset!
        @active = false
        @agent&.flusher&.stop!
        @agent = nil
        @paths = nil
        Thread.current[RECORDER_KEY] = nil
        SourceLocation.clear
        clear_test_payloads
      end

      private

      def configure(config)
        @traces = config.performance_traces
        @ignore = IgnoreMatcher.new(config.performance_ignore_transactions)
        @paths = Backtrace::Paths.new(config.root)
        SourceLocation.clear
      end

      def log = GoodSorcery.log

      def recordable?(recorder)
        @active && !recorder.broken? && !recorder.name.nil? && !@ignore.ignored?(recorder.name)
      end
    end
  end
end
