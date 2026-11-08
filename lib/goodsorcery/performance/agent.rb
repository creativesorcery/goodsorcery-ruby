# frozen_string_literal: true

module GoodSorcery
  module Performance
    # The per-process state: metrics, traces and the flusher. A forked child
    # gets a fresh, empty agent (the parent keeps and sends what it
    # recorded), and its flusher thread starts on the child's first record.
    class Agent
      attr_reader :pid, :aggregator, :trace_buffer, :flusher, :context

      def initialize(config, log)
        @pid = Process.pid
        @aggregator = Aggregator.new
        @trace_buffer = TraceBuffer.new
        @context = TraceContext.new(config)
        @flusher = Flusher.new(agent: self, log: log)
      end

      def current?
        @pid == Process.pid
      end

      def record(recorder, background:)
        minute = (recorder.finished_wall / 60).floor
        @aggregator.record(minute, Sample.from(recorder))
        offer_trace(minute, recorder) if recorder.traces?
        @flusher.ensure_started if background
      end

      private

      # A request's trace is built once the response has gone out, when the
      # server offers a hook for that, so the slowest requests are not kept
      # waiting for it.
      def offer_trace(minute, recorder)
        key = [recorder.kind, recorder.name]
        return unless @trace_buffer.candidate?(minute, key, recorder.duration_ms)

        hooks = AfterReply.hooks(recorder.env)
        return build_trace(minute, key, recorder) unless hooks

        hooks << AfterReply.callback { build_trace(minute, key, recorder) }
      end

      def build_trace(minute, key, recorder)
        return unless @trace_buffer.candidate?(minute, key, recorder.duration_ms)

        trace = TraceBuilder.new(recorder, minute, @context).build
        @trace_buffer.offer(minute, key, recorder.duration_ms, trace)
      end
    end

    # The Rack server's hooks run after the response is sent: Rack 3's
    # rack.response_finished (callables get env, status, headers, error)
    # or Puma's rack.after_reply (no arguments).
    module AfterReply
      KEYS = %w[rack.response_finished rack.after_reply].freeze

      def self.hooks(env)
        return nil unless env.is_a?(Hash)

        KEYS.each do |key|
          hooks = env[key]
          return hooks if hooks.is_a?(Array) && !hooks.frozen?
        end
        nil
      end

      # A hook that never raises into the server.
      def self.callback(&work)
        proc do |*|
          work.call
        rescue StandardError => e
          GoodSorcery.log.warn_every(:apm_trace_error, 60, "could not build a performance trace (#{e.class})")
        end
      end
    end

    # performance_ignore_transactions: exact names or regexps. Answers are
    # cached per name.
    class IgnoreMatcher
      MAX_CACHED = 1_000

      def initialize(list)
        entries = Array(list)
        @names = entries.grep_v(Regexp).map(&:to_s).to_h { |name| [name, true] }
        @patterns = entries.grep(Regexp)
        @cache = {}
      end

      def ignored?(name)
        return true if @names.key?(name)
        return false if @patterns.empty?

        cached = @cache[name]
        return cached unless cached.nil?

        @cache.clear if @cache.size >= MAX_CACHED
        @cache[name] = @patterns.any? { |pattern| pattern.match?(name) }
      end
    end
  end
end
