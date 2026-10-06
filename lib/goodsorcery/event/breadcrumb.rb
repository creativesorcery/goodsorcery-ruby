# frozen_string_literal: true

module GoodSorcery
  module Event
    # Builds one breadcrumb, copying and capping its data when it is recorded
    # so the scope never holds on to app objects.
    module Breadcrumb
      CATEGORIES = %w[request controller sql http cache log job custom].freeze
      LEVELS = %w[debug info warning error].freeze
      MAX_MESSAGE_LENGTH = 1_000
      DATA_SANITIZER = Sanitizer.new(max_depth: 4, max_items: 20, max_keys: 20, max_string: 1_000)

      module_function

      def build(message, category: "custom", level: "info", data: nil, time: Time.now)
        crumb = {
          "timestamp" => Fields.timestamp(time),
          "category" => choice(category, CATEGORIES, "custom"),
          "level" => choice(Fields::LEVEL_ALIASES.fetch(level.to_s, level.to_s), LEVELS, "info"),
          "message" => Text.limit(message, MAX_MESSAGE_LENGTH)
        }
        crumb["data"] = DATA_SANITIZER.sanitize(data) if data.is_a?(Hash) && !data.empty?
        crumb
      end

      def choice(value, allowed, default)
        name = value.to_s
        allowed.include?(name) ? name : default
      end
    end
  end
end
