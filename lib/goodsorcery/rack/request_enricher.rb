# frozen_string_literal: true

module GoodSorcery
  module Rack
    # Fills in the request section when an error is reported during a Rack
    # request. Leaves it to config.request_extractor when one is configured.
    class RequestEnricher
      def initialize(env)
        @env = env
      end

      def enrich(scope)
        config = GoodSorcery.configuration
        return if config.request_extractor || scope.request

        scope.request = RequestDetails.new(@env, config).to_h
      end
    end
  end
end
