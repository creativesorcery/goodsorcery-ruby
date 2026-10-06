# frozen_string_literal: true

module GoodSorcery
  # Turns app data into JSON-safe values within the server's limits
  # (INGEST_API.md "Limits"): nesting depth, array and object sizes, string
  # lengths. Unknown objects become strings; structs become hashes so their
  # keys are filtered too. The result shares no mutable objects with the app.
  class Sanitizer
    TRUNCATED = "[truncated]"

    def initialize(max_depth: 6, max_items: 50, max_keys: 100, max_string: 4_096)
      @max_depth = max_depth
      @max_items = max_items
      @max_keys = max_keys
      @max_string = max_string
    end

    def sanitize(value, depth = 1)
      case value
      when Hash then sanitize_hash(value, depth)
      when Array then sanitize_array(value, depth)
      when String then Text.limit(value, @max_string)
      when Symbol then Text.limit(value.name, @max_string)
      when Integer, true, false, nil then value
      else sanitize_object(value, depth)
      end
    end

    private

    def sanitize_hash(hash, depth)
      return TRUNCATED if depth > @max_depth

      hash.first(@max_keys).to_h do |key, value|
        [Text.limit(key, 200), sanitize(value, depth + 1)]
      end
    end

    def sanitize_array(array, depth)
      return TRUNCATED if depth > @max_depth

      array.first(@max_items).map { |item| sanitize(item, depth + 1) }
    end

    def sanitize_object(value, depth)
      return value if value.is_a?(Float) && value.finite?
      return value.utc.iso8601(3) if value.is_a?(Time)
      return sanitize_collection(value, depth) if collection?(value)

      Text.limit(Text.safe_to_s(value), @max_string)
    end

    # Objects whose to_s would print their fields (OpenStruct's is its
    # inspect) become hashes or arrays, so their keys are filtered too.
    def collection?(value)
      structured?(value) || value.respond_to?(:to_unsafe_h) || value.is_a?(::Set)
    end

    def structured?(value)
      value.is_a?(Struct) || (defined?(::Data) && value.is_a?(::Data)) ||
        (defined?(::OpenStruct) && value.is_a?(::OpenStruct)) # rubocop:disable Style/OpenStructUse
    end

    def sanitize_collection(value, depth)
      return sanitize_array(value.to_a, depth) if value.is_a?(::Set)
      return sanitize_hash(value.to_unsafe_h, depth) if value.respond_to?(:to_unsafe_h)

      sanitize_hash(value.to_h, depth)
    end
  end
end
