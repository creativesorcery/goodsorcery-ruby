# frozen_string_literal: true

module GoodSorcery
  # Turns job arguments (and other app values headed for an event) into JSON
  # data the way a job system would see them, without loading anything or
  # calling #inspect: GlobalID objects become their gid string, hash keys are
  # kept (so key filtering applies), symbols become strings, times ISO 8601,
  # and any other object a "#<ClassName>" placeholder. Depth, collection sizes
  # and string lengths are capped like request params.
  class JobArguments
    MAX_DEPTH = 6
    MAX_ITEMS = 50
    MAX_KEYS = 100
    MAX_STRING = 4_096
    MAX_KEY_LENGTH = 200

    def serialize(value, depth = 1)
      case value
      when Hash then serialize_hash(value, depth)
      when Array then serialize_array(value, depth)
      when String then Text.limit(value, MAX_STRING)
      when Symbol then Text.limit(value.name, MAX_STRING)
      when Integer, true, false, nil then value
      else serialize_object(value)
      end
    end

    private

    def serialize_hash(hash, depth)
      return Sanitizer::TRUNCATED if depth > MAX_DEPTH

      hash.first(MAX_KEYS).to_h do |key, item|
        [Text.limit(key_name(key), MAX_KEY_LENGTH), serialize(item, depth + 1)]
      end
    end

    def serialize_array(array, depth)
      return Sanitizer::TRUNCATED if depth > MAX_DEPTH

      array.first(MAX_ITEMS).map { |item| serialize(item, depth + 1) }
    end

    def key_name(key)
      plain_key?(key) ? key.to_s : placeholder(key)
    end

    def plain_key?(key)
      key.is_a?(String) || key.is_a?(Symbol) || key.is_a?(Integer)
    end

    def serialize_object(value)
      return value if value.is_a?(Float) && value.finite?
      return value.to_s if value.is_a?(Numeric)
      return value.name.to_s if value.is_a?(Module)

      identify(value)
    rescue StandardError
      placeholder(value)
    end

    # Records as their GlobalID, times and dates as ISO 8601, anything else
    # as a placeholder.
    def identify(value)
      return value.to_global_id.to_s if value.respond_to?(:to_global_id)
      return Text.limit(value.iso8601, 64) if value.respond_to?(:iso8601)

      placeholder(value)
    end

    def placeholder(value)
      "#<#{value.class.name || "Object"}>"
    rescue StandardError
      "#<Object>"
    end
  end
end
