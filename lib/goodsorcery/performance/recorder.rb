# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Measures one unit of work (a request or a job) on the current fiber:
    # the total duration, the time per layer and, when traces are on, a raw
    # span list. Spans are small arrays appended as events finish; nothing
    # is copied or normalised until a trace is built (DESIGN.md 8.3).
    #
    #   [:sql, start, finish, sql, name, row_count, dialect]
    #   [:http, start, finish, method, host, path, status]
    #   [:view, start, finish, identifier]
    #   [:enqueue, start, finish, job_class, queue]
    #
    # Times are monotonic seconds.
    class Recorder
      MAX_RAW_SPANS = 2_000
      MAX_RENDER_DEPTH = 100

      attr_reader :kind, :started, :started_wall, :spans, :db_ms, :http_ms, :sql_count, :http_count,
                  :spans_dropped, :duration_ms, :finished_wall, :gc
      attr_accessor :name, :http_method, :route, :source, :adapter, :queue, :queue_wait_ms, :status,
                    :error_event_id, :view_runtime, :env, :job_details

      def initialize(kind, traces:)
        @kind = kind
        @started = Performance.monotonic
        @started_wall = Process.clock_gettime(Process::CLOCK_REALTIME)
        @db_ms = @http_ms = @render_view_ms = 0.0
        @sql_count = @http_count = @spans_dropped = 0
        @render_stack = []
        @failed = @broken = false
        start_trace if traces
      end

      def traces? = !@spans.nil?
      def failed? = @failed
      def broken? = @broken
      def failed! = (@failed = true)
      def broken! = (@broken = true)

      # An exception escaped the unit of work.
      def raised!
        @failed = true
        @status = 500 if @kind == :web
      end

      def response_status=(status)
        @status = status
        @failed = true if status && status >= 500
      end

      # Yields once, the second time the same SQL text runs, for the call site.
      def add_sql(start, finish, sql, name, rows, dialect: nil, &)
        @db_ms += (finish - start) * 1000.0
        @sql_count += 1
        return unless @spans

        @repeats.note(sql, &)
        push([:sql, start, finish, sql, name, rows, dialect])
      end

      # +times+ is [start, finish].
      def add_http(times, method, host, path, status)
        start, finish = times
        @http_ms += (finish - start) * 1000.0
        @http_count += 1
        push([:http, start, finish, method, host, path, status]) if @spans
      end

      def add_enqueue(start, finish, job_class, queue)
        push([:enqueue, start, finish, job_class, queue]) if @spans
      end

      def render_started(now)
        @render_stack.push([now, @db_ms]) if @render_stack.size < MAX_RENDER_DEPTH
      end

      # Only the outermost render counts toward view time, minus the queries
      # run while it was open, so nested renders are never counted twice.
      def render_finished(now, identifier)
        start, db_at_start = @render_stack.pop
        return unless start

        push([:view, start, now, identifier]) if @spans
        return unless @render_stack.empty?

        @render_view_ms += [((now - start) * 1000.0) - (@db_ms - db_at_start), 0.0].max
      end

      def call_site_for(sql)
        @repeats&.call_site(sql)
      end

      def stop(now = Performance.monotonic)
        @duration_ms = (now - @started) * 1000.0
        @finished_wall = @started_wall + (now - @started)
        @gc = @gc_start&.delta
      end

      # Web requests use the controller's view_runtime when Rails gave one.
      def view_ms
        @view_runtime || @render_view_ms
      end

      def ruby_ms
        [@duration_ms - @db_ms - @http_ms - view_ms, 0.0].max
      end

      private

      def start_trace
        @spans = []
        @repeats = RepeatedQueries.new
        @gc_start = GcSnapshot.take
      end

      def push(span)
        if @spans.size < MAX_RAW_SPANS
          @spans << span
        else
          @spans_dropped += 1
        end
      end
    end

    # Remembers which raw SQL texts ran in one unit of work, and the call
    # site of each text that ran at least twice (captured once).
    class RepeatedQueries
      MAX_TEXTS = 2_000
      SEEN_ONCE = true

      def initialize
        @texts = {}
      end

      def note(sql)
        seen = @texts[sql]
        if seen.nil?
          @texts[sql] = SEEN_ONCE if @texts.size < MAX_TEXTS
        elsif seen == SEEN_ONCE
          @texts[sql] = (block_given? && yield) || false
        end
      end

      def call_site(sql)
        site = @texts[sql]
        site.is_a?(CallSite) ? site : nil
      end
    end

    # Process-wide GC figures at the start of a unit of work, and their
    # change since.
    GcSnapshot = Struct.new(:time_ms, :gc_count, :allocations) do
      def self.take
        new(GC.stat(:time), GC.count, GC.stat(:total_allocated_objects))
      end

      def delta
        now = self.class.take
        { "time_ms" => (now.time_ms - time_ms).to_f, "count" => now.gc_count - gc_count,
          "allocations" => now.allocations - allocations }
      end
    end
  end
end
