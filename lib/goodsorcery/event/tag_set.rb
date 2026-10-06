# frozen_string_literal: true

module GoodSorcery
  module Event
    # Merges tag hashes (later ones win) and keeps what the server accepts:
    # up to 25 keys matching KEY with scalar values of at most 200 chars.
    module TagSet
      KEY = /\A[a-z0-9_.-]{1,32}\z/i
      MAX_TAGS = 25
      MAX_VALUE_LENGTH = 200

      module_function

      def merge(*hashes)
        merged = {}
        hashes.each { |hash| add(merged, hash) if hash.is_a?(Hash) }
        merged.first(MAX_TAGS).to_h
      end

      def add(merged, hash)
        hash.each do |key, raw|
          name = key.to_s
          value = scalar(raw)
          merged[name] = value if KEY.match?(name) && !value.nil?
        end
      end

      def scalar(raw)
        case raw
        when String, Symbol then Text.limit(raw.to_s, MAX_VALUE_LENGTH)
        when Integer, true, false then raw
        when Float then finite_float(raw)
        end
      end

      def finite_float(raw)
        raw.finite? ? raw : nil
      end
    end
  end
end
