# frozen_string_literal: true

module GoodSorcery
  class Configuration
    # Class macros that define setters which reject invalid values with a clear
    # ArgumentError. Messages show the rejected value only for plain settings,
    # never for credentials.
    module Validation
      def integer_setting(name, range)
        define_method(:"#{name}=") do |value|
          unless value.is_a?(Integer) && range.cover?(value)
            raise ArgumentError, "#{name} must be an Integer in #{range} (got #{value.inspect})"
          end

          instance_variable_set(:"@#{name}", value)
        end
      end

      def seconds_setting(name)
        define_method(:"#{name}=") do |value|
          unless value.is_a?(Numeric) && value.positive?
            raise ArgumentError, "#{name} must be a positive number of seconds (got #{value.inspect})"
          end

          instance_variable_set(:"@#{name}", value)
        end
      end

      # The message never echoes the value: an endpoint URL can carry credentials.
      def endpoint_setting
        define_method(:endpoint=) do |value|
          unless value.nil? || Validation.http_url?(value)
            raise ArgumentError, "endpoint must be an http:// or https:// URL with a host and no user:password part"
          end

          @endpoint = value
        end
      end

      def self.http_url?(value)
        uri = URI(value.to_s)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? && uri.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end

      def choice_setting(name, choices)
        define_method(:"#{name}=") do |value|
          normalized = value.is_a?(String) ? value.to_sym : value
          unless choices.include?(normalized)
            raise ArgumentError, "#{name} must be one of #{choices.map(&:inspect).join(", ")} (got #{value.inspect})"
          end

          instance_variable_set(:"@#{name}", normalized)
        end
      end
    end
  end
end
