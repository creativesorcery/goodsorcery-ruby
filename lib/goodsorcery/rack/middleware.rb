# frozen_string_literal: true

require_relative "request_details"
require_relative "request_enricher"

module GoodSorcery
  module Rack
    # Rack middleware for Rails, Sinatra and plain Rack apps. Opens a fresh
    # scope per request (cleared afterwards, whatever happens), records a
    # "METHOD /path" breadcrumb and reports exceptions that propagate, then
    # re-raises them. Exceptions an inner layer turned into a 5xx response
    # (env["action_dispatch.exception"], env["sinatra.error"]) are reported
    # too. The request itself is only read if an error is reported.
    #
    #   use GoodSorcery::Rack::Middleware
    class Middleware
      RESCUED_ERROR_KEYS = %w[action_dispatch.exception sinatra.error].freeze

      def initialize(app, enricher: RequestEnricher)
        @app = app
        @enricher = enricher
      end

      def call(env)
        GoodSorcery.with_scope do |scope|
          open_request(scope, env)
          response = call_app(env)
          report_rescued_error(env, response)
          response
        end
      end

      private

      def open_request(scope, env)
        scope.request_env = env
        scope.enricher = @enricher.new(env)
        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        GoodSorcery.add_breadcrumb("#{env["REQUEST_METHOD"]} #{path}", category: "request")
      end

      def call_app(env)
        @app.call(env)
      rescue Exception => e # rubocop:disable Lint/RescueException
        GoodSorcery.notify(e)
        raise
      end

      def report_rescued_error(env, response)
        return unless response.is_a?(Array) && response.first.to_i >= 500

        error = RESCUED_ERROR_KEYS.lazy.map { |key| env[key] }.find { |value| value.is_a?(Exception) }
        GoodSorcery.notify(error) if error
      end
    end
  end
end
