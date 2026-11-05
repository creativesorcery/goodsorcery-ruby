# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Turns a recorder's raw spans into the trace payload's "spans"
    # (DESIGN.md 8.5): SQL normalised, repeated identical SQL (and repeated
    # renders of one template) grouped into one span with its count, total
    # and call site, at most MAX_SPANS spans (the longest), in start order.
    class SpanList
      MAX_SPANS = 300
      MAX_NAME_LENGTH = 255
      MAX_PATH_LENGTH = 1_024
      VIEWS_DIR = "/app/views/"

      attr_reader :dropped

      def initialize(recorder, context)
        @recorder = recorder
        @context = context
        @normalized = {}
        @dropped = 0
      end

      def to_a
        groups = group(@recorder.spans).sort_by(&:first_start)
        groups = cap(groups) if groups.size > MAX_SPANS
        groups.map { |span_group| span_group.to_h(@recorder.started, @context) }
      end

      private

      def group(raw_spans)
        groups = {}
        raw_spans.each_with_index do |raw, index|
          slot = group_key(raw) || index
          existing = groups[slot]
          existing ? existing.add(raw) : groups[slot] = SpanGroup.new(raw, fields(raw))
          groups[slot].find_call_site(@recorder, raw)
        end
        groups.values
      end

      def cap(groups)
        kept = groups.max_by(MAX_SPANS, &:total_ms)
        @dropped += (groups - kept).sum(&:count)
        kept.sort_by(&:first_start)
      end

      # SQL groups by its normalised text and views by template; HTTP calls
      # and enqueues are never grouped.
      def group_key(raw)
        case raw[0]
        when :sql then [:sql, normalized(raw[3])]
        when :view then [:view, template_name(raw[3])]
        end
      end

      def fields(raw)
        case raw[0]
        when :sql then { "name" => Text.limit(raw[4] || "SQL", MAX_NAME_LENGTH), "sql" => normalized(raw[3]) }
        when :view then { "template" => template_name(raw[3]) }
        when :http then http_fields(raw)
        else enqueue_fields(raw)
        end
      end

      def normalized(sql)
        @normalized[sql] ||= @context.normalizer.normalize(sql)
      end

      def http_fields(raw)
        path = raw[5].to_s.split(/[?#]/, 2).first.to_s
        { "method" => Text.limit(raw[3], 16), "host" => Text.limit(raw[4], MAX_NAME_LENGTH),
          "path" => Text.limit(path.empty? ? "/" : path, MAX_PATH_LENGTH), "status" => raw[6] }.compact
      end

      def enqueue_fields(raw)
        { "job" => Text.limit(raw[3], MAX_NAME_LENGTH), "queue" => raw[4] && Text.limit(raw[4], 128) }.compact
      end

      # Relative to app/views; a template outside the app keeps the part
      # after its last "views/" directory, else its file name.
      def template_name(identifier)
        @templates ||= {}
        @templates[identifier] ||= relative_template(identifier.to_s)
      end

      def relative_template(path)
        index = path.rindex(VIEWS_DIR)
        name = if index then path[(index + VIEWS_DIR.size)..]
               elsif (views = path.rindex("/views/")) then path[(views + 7)..]
               else File.basename(path)
               end
        Text.limit(name, MAX_NAME_LENGTH)
      end
    end

    # One span of the payload: a single call, or a group of identical ones.
    class SpanGroup
      DECIMALS = 3

      attr_reader :first_start, :last_finish, :total_ms, :count, :rows, :call_site

      def initialize(raw, fields)
        @type = raw[0]
        @fields = fields
        @first_start = raw[1]
        @last_finish = raw[2]
        @total_ms = (raw[2] - raw[1]) * 1000.0
        @count = 1
        @rows = sql_rows(raw)
      end

      def add(raw)
        @count += 1
        @total_ms += (raw[2] - raw[1]) * 1000.0
        @last_finish = raw[2] if raw[2] > @last_finish
        rows = sql_rows(raw)
        @rows = (@rows || 0) + rows if rows
      end

      # A SQL group takes the call site captured for any of its raw texts.
      def find_call_site(recorder, raw)
        return @call_site if @call_site || @type != :sql

        @call_site = recorder.call_site_for(raw[3])
      end

      def to_h(origin, context)
        hash = { "type" => @type.to_s, "offset_ms" => ms(@first_start - origin),
                 "duration_ms" => @total_ms.round(DECIMALS) }.merge!(@fields)
        hash["rows"] = @rows if @rows
        return hash if @count < 2

        hash.merge!("count" => @count, "span_ms" => ms(@last_finish - @first_start))
        hash["call_site"] = context.call_site_hash(@call_site) if @call_site
        hash
      end

      private

      def sql_rows(raw)
        raw[0] == :sql && raw[5].is_a?(Integer) ? raw[5] : nil
      end

      def ms(seconds)
        [(seconds * 1000.0).round(DECIMALS), 0.0].max
      end
    end
  end
end
