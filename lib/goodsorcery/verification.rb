# frozen_string_literal: true

module GoodSorcery
  # The outcome of GoodSorcery.verify: can this endpoint be reached, and does
  # it accept the API key? Messages show the masked key only.
  class Verification
    attr_reader :message, :environment

    NO_KEY = "no API key configured (set GOODSORCERY_API_KEY or config.api_key)"

    def self.run(config, transport)
      return new(false, NO_KEY) if config.api_key.to_s.empty?

      from_result(transport.verify, config)
    end

    def self.from_result(result, config)
      return success(result, config) if result.success?
      return new(false, "the server rejected API key #{config.masked_api_key} (HTTP 401)") if result.status == 401
      return new(false, "#{config.endpoint_label} has no verify endpoint (HTTP 404)") if result.not_found?
      return new(false, "rate limited (HTTP 429); try again in #{result.retry_after} s") if result.rate_limited?

      new(false, "could not reach #{config.endpoint_label} (#{result.description})")
    end

    def self.success(result, config)
      environment = result.body["environment"]
      label = environment ? " for environment #{environment.to_s.inspect}" : ""
      message = "API key #{config.masked_api_key} is valid#{label} at #{config.endpoint_label}"
      new(true, message, environment: environment)
    end

    def initialize(succeeded, message, environment: nil)
      @ok = succeeded
      @message = message
      @environment = environment
    end

    def ok?
      @ok
    end

    def to_s
      message
    end
  end
end
