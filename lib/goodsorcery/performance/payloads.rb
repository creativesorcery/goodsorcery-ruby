# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Builds the request bodies for POST /api/v1/apm/metrics and
    # /api/v1/apm/traces (INGEST_API.md › Performance monitoring), split so
    # each stays under the server's size and count limits. Each body gets a
    # UUIDv7 batch_id that it keeps on every retry.
    module Payloads
      METRICS_PATH = "/api/v1/apm/metrics"
      TRACES_PATH = "/api/v1/apm/traces"
      METRICS_MAX_BYTES = 450 * 1_024
      TRACES_MAX_BYTES = 1_800 * 1_024
      MAX_TRANSACTIONS_PER_MINUTE = 1_000
      MAX_TRACES = 50
      MAX_TRACES_PER_PAYLOAD = 50

      # One JSON body with its path and how many minutes it carries.
      Body = Struct.new(:path, :json, :minutes)

      module_function

      # +minutes+ as Aggregator#take returns them.
      def metrics(minutes)
        chunks = MetricsChunks.new
        minutes.each do |minute, kinds|
          kinds.each do |kind, names|
            names.each { |name, stats| chunks.add(minute, JSON.generate(stats.to_h(kind, name))) }
          end
        end
        chunks.bodies
      end

      # At most MAX_TRACES traces (the slowest, as TraceBuffer#take orders
      # them), as few bodies as the size limit allows.
      def traces(traces)
        jsons = traces.first(MAX_TRACES).map { |trace| JSON.generate(trace) }
        Packer.pack(jsons, TRACES_MAX_BYTES, MAX_TRACES_PER_PAYLOAD).map do |chunk|
          Body.new(TRACES_PATH, envelope("traces" => "[#{chunk.join(",")}]"), 0)
        end
      end

      def header
        { "batch_id" => UuidV7.generate, "notifier" => { "name" => NOTIFIER_NAME, "version" => VERSION } }
      end

      # The envelope as JSON, with already serialised members spliced in.
      def envelope(fields, extra = {})
        head = JSON.generate(header.merge(extra))
        members = fields.map { |key, json| "#{JSON.generate(key)}:#{json}" }
        "#{head[0..-2]},#{members.join(",")}}"
      end

      # Greedy packing of JSON strings into groups under a byte budget.
      module Packer
        def self.pack(jsons, max_bytes, max_items)
          jsons.each_with_object([[]]) do |json, chunks|
            current = chunks.last
            size = current.sum(&:bytesize) + json.bytesize
            chunks << [] if !current.empty? && (size > max_bytes || current.size >= max_items)
            chunks.last << json
          end.reject(&:empty?)
        end
      end
    end

    # Packs serialised transactions into metrics bodies: a new body when the
    # current one would pass the size limit or a minute's transaction limit.
    class MetricsChunks
      def initialize
        @bodies = []
        @current = {}
        @bytes = 0
      end

      def add(minute, json)
        start_new_body if full?(minute, json)
        (@current[minute] ||= []) << json
        @bytes += json.bytesize + 1
      end

      def bodies
        start_new_body
        @bodies
      end

      private

      def full?(minute, json)
        return false if @current.empty?

        @bytes + json.bytesize > Payloads::METRICS_MAX_BYTES ||
          @current.fetch(minute, []).size >= Payloads::MAX_TRANSACTIONS_PER_MINUTE
      end

      def start_new_body
        return if @current.empty?

        minutes = @current.map do |minute, jsons|
          "{\"minute\":#{JSON.generate(Performance.minute_iso(minute))},\"transactions\":[#{jsons.join(",")}]}"
        end
        json = Payloads.envelope({ "minutes" => "[#{minutes.join(",")}]" }, "histogram" => Histogram::SCHEME)
        @bodies << Payloads::Body.new(Payloads::METRICS_PATH, json, @current.size)
        @current = {}
        @bytes = 0
      end
    end
  end
end
