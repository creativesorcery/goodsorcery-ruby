# frozen_string_literal: true

module GoodSorcery
  module Event
    # The "request" section. Integrations either store a ready hash in
    # scope.request, or keep the Rack env in scope.request_env and set
    # config.request_extractor (an object responding to +extract(env)+), so
    # the request is only read when an error is actually reported.
    class RequestSection
      SCALARS = %w[url method format request_id remote_ip].freeze
      NESTED = %w[params headers session].freeze

      def initialize(extractor, sanitizer)
        @extractor = extractor
        @sanitizer = sanitizer
      end

      def build(scope)
        raw = scope.request || extract(scope.request_env)
        return nil unless raw.is_a?(Hash)

        section = {}
        raw.each { |key, value| add(section, key.to_s, value) }
        section.empty? ? nil : section
      end

      private

      def extract(env)
        env && @extractor ? @extractor.extract(env) : nil
      end

      def add(section, key, value)
        return if value.nil?

        section[key] = Text.limit(value, 4_096) if SCALARS.include?(key)
        section[key] = @sanitizer.sanitize(value) if NESTED.include?(key) && value.is_a?(Hash)
      end
    end
  end
end
