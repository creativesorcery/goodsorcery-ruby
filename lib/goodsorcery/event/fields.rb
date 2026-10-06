# frozen_string_literal: true

module GoodSorcery
  module Event
    # Small normalizers for top-level event fields.
    module Fields
      LEVELS = %w[fatal error warning info].freeze
      LEVEL_ALIASES = { "warn" => "warning", "critical" => "fatal", "debug" => "info" }.freeze
      MAX_FINGERPRINT_PARTS = 10
      MAX_FINGERPRINT_LENGTH = 200

      module_function

      def level(value, default = "error")
        name = value.to_s.downcase
        name = LEVEL_ALIASES.fetch(name, name)
        LEVELS.include?(name) ? name : default
      end

      def fingerprint(value)
        return nil if value.nil?

        parts = Array(value).select { |part| part.is_a?(String) || part.is_a?(Symbol) || part.is_a?(Numeric) }
        parts = parts.first(MAX_FINGERPRINT_PARTS).map { |part| Text.limit(part.to_s, MAX_FINGERPRINT_LENGTH) }
        parts.empty? ? nil : parts
      end

      def event_id
        SecureRandom.respond_to?(:uuid_v7) ? SecureRandom.uuid_v7 : SecureRandom.uuid
      end

      def timestamp(time = Time.now)
        time.utc.iso8601(3)
      end

      def text(value, max)
        value.nil? ? nil : Text.limit(value, max)
      end
    end
  end
end
