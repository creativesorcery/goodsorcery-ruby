# frozen_string_literal: true

module GoodSorcery
  # Reads boolean environment variables such as GOODSORCERY_ENABLED.
  module EnvFlag
    TRUE_VALUES = %w[1 true yes on].freeze
    FALSE_VALUES = %w[0 false no off].freeze

    # => true, false, or nil when the value is unset or unrecognised.
    def self.parse(value)
      normalized = value.to_s.strip.downcase
      return true if TRUE_VALUES.include?(normalized)
      return false if FALSE_VALUES.include?(normalized)

      nil
    end

    # ENV[name] unless it is unset or blank.
    def self.present(name)
      value = ENV.fetch(name, nil)
      value unless value.nil? || value.strip.empty?
    end
  end
end
