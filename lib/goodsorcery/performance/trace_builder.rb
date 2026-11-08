# frozen_string_literal: true

module GoodSorcery
  module Performance
    # What every trace in this process shares: the SQL normaliser, app paths,
    # the source line cache (only with send_code_context), host and runtime.
    class TraceContext
      attr_reader :normalizer, :paths, :host, :runtime

      def initialize(config)
        @normalizer = SqlNormalizer.new
        @paths = Backtrace::Paths.new(config.root)
        @line_cache = config.send_code_context ? Backtrace::LineCache.new(@paths, max_files: 32) : nil
        @host = hostname
        @runtime = { "ruby" => RUBY_VERSION, "rails" => rails_version }.compact
      end

      def call_site_hash(call_site)
        call_site.to_h(@paths, line_cache: @line_cache)
      end

      private

      def hostname
        Text.limit(Socket.gethostname, 255)
      rescue StandardError
        nil
      end

      def rails_version
        ::Rails.version.to_s if defined?(::Rails) && ::Rails.respond_to?(:version)
      end
    end

    # Builds one trace payload (INGEST_API.md › Traces payload) from a
    # finished recorder. Only the slowest unit of work so far in its minute
    # gets here, so this may take a little time; it never runs inside a lock.
    class TraceBuilder
      MAX_TRACE_BYTES = 65_536
      DECIMALS = 3

      def initialize(recorder, minute, context)
        @recorder = recorder
        @minute = minute
        @context = context
      end

      def build
        spans = SpanList.new(@recorder, @context)
        trace = identity.merge(timing, outcome, details, counts(spans.to_a, spans.dropped))
        fit(trace)
      end

      private

      def identity
        hash = { "id" => UuidV7.generate(Time.at(@recorder.started_wall)), "kind" => @recorder.kind.to_s,
                 "name" => Text.limit(@recorder.name, 255) }
        hash.merge(Labels.for(@recorder).except("source"))
      end

      # The fourth layer goes out under both names: app_ms (protocol
      # revision 1.1) and ruby_ms, which older servers read.
      def timing
        app_ms = round(@recorder.ruby_ms)
        { "minute" => Performance.minute_iso(@minute), "started_at" => Time.at(@recorder.started_wall).utc.iso8601(3),
          "duration_ms" => round(@recorder.duration_ms), "db_ms" => round(@recorder.db_ms),
          "http_ms" => round(@recorder.http_ms), "view_ms" => round(@recorder.view_ms),
          "app_ms" => app_ms, "ruby_ms" => app_ms }
      end

      def outcome
        hash = { "failed" => @recorder.failed?, "error_event_id" => @recorder.error_event_id }
        hash["status"] = @recorder.status if @recorder.kind == :web && @recorder.status
        hash
      end

      def details
        section = @recorder.kind == :web ? { "request" => request } : { "job" => job }
        gc = @recorder.gc || {}
        section.merge("host" => @context.host, "process" => ProcessLabel.current, "runtime" => @context.runtime,
                      "gc" => gc.slice("time_ms", "count"), "allocations" => gc["allocations"]).compact
      end

      def request
        env = @recorder.env || {}
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        { "method" => @recorder.http_method && Text.limit(@recorder.http_method, 16),
          "path" => Text.limit(path.empty? ? "/" : path, SpanList::MAX_PATH_LENGTH),
          "request_id" => env["action_dispatch.request_id"] && Text.limit(env["action_dispatch.request_id"], 128) }
          .compact
      end

      def job
        { "adapter" => @recorder.adapter, "queue" => @recorder.queue,
          "queue_wait_ms" => @recorder.queue_wait_ms && round(@recorder.queue_wait_ms),
          "executions" => @recorder.job_details&.executions }.compact
      end

      def counts(spans, dropped)
        { "sql_count" => @recorder.sql_count, "http_count" => @recorder.http_count,
          "spans_dropped" => @recorder.spans_dropped + dropped, "spans" => spans }
      end

      # Keeps a trace under MAX_TRACE_BYTES of JSON by dropping its shortest
      # spans, half at a time.
      def fit(trace)
        halve_spans(trace) while JSON.generate(trace).bytesize > MAX_TRACE_BYTES && !trace["spans"].empty?
        trace
      end

      def halve_spans(trace)
        spans = trace["spans"]
        kept = spans.max_by(spans.size / 2) { |span| span["duration_ms"] }.sort_by { |span| span["offset_ms"] }
        trace["spans_dropped"] += (spans - kept).sum { |span| span.fetch("count", 1) }
        trace["spans"] = kept
      end

      def round(value)
        value.to_f.round(DECIMALS)
      end
    end
  end
end
