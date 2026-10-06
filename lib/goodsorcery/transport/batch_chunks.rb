# frozen_string_literal: true

module GoodSorcery
  class Transport
    # Splits serialized events into batch request bodies of at most 100
    # events and about 1.5 MiB of uncompressed JSON (the server accepts 2 MiB).
    module BatchChunks
      MAX_EVENTS = 100
      MAX_BYTES = 1_572_864

      module_function

      def split(jsons)
        chunks = []
        current = []
        bytes = 0
        jsons.each do |json|
          if full?(current, bytes, json)
            chunks << current
            current = []
            bytes = 0
          end
          current << json
          bytes += json.bytesize + 1
        end
        current.empty? ? chunks : chunks << current
      end

      def full?(chunk, bytes, json)
        return false if chunk.empty?

        chunk.size >= MAX_EVENTS || bytes + json.bytesize > MAX_BYTES
      end

      def body(chunk)
        "{\"events\":[#{chunk.join(",")}]}"
      end
    end
  end
end
