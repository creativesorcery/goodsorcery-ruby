# frozen_string_literal: true

module GoodSorcery
  module Rack
    # Reads the "request" section from a Rack env, only when an error is
    # reported. Uses what Rails (or Rack) already parsed and never reads the
    # request body or loads the session. Filtering happens later, in
    # EventFilter, like for every other section.
    class RequestDetails
      HEADER_PREFIX = "HTTP_"
      DEFAULT_PORTS = { "http" => ":80", "https" => ":443" }.freeze
      CONTENT_HEADERS = { "CONTENT_TYPE" => "Content-Type", "CONTENT_LENGTH" => "Content-Length" }.freeze

      def initialize(env, config)
        @env = env
        @config = config
      end

      def to_h
        {
          "url" => url, "method" => @env["REQUEST_METHOD"], "format" => format,
          "request_id" => request_id, "remote_ip" => remote_ip,
          "params" => params, "headers" => headers, "session" => session
        }.compact
      end

      def url
        scheme = @env["rack.url_scheme"] || "http"
        query = @env["QUERY_STRING"].to_s
        base = "#{scheme}://#{host(scheme)}#{@env["SCRIPT_NAME"]}#{@env["PATH_INFO"]}"
        query.empty? ? base : "#{base}?#{query}"
      end

      def request_id
        @env["action_dispatch.request_id"] || @env["HTTP_X_REQUEST_ID"]
      end

      def remote_ip
        rails_ip = @env["action_dispatch.remote_ip"]
        (rails_ip && Text.safe_to_s(rails_ip)) || @env["REMOTE_ADDR"]
      end

      def headers
        return nil unless @config.send_request_headers

        @env.each_with_object({}) do |(name, value), headers|
          header = header_name(name)
          headers[header] = value if header && value.is_a?(String)
        end
      end

      def params
        return nil unless @config.send_request_params

        parsed = @env["action_dispatch.request.parameters"]
        parsed.is_a?(Hash) ? parsed : RackParams.new(@env).to_h
      end

      def session
        return nil unless @config.send_session

        session = @env["rack.session"]
        return session if session.is_a?(Hash)
        return nil unless session.respond_to?(:loaded?) && session.loaded?

        session.to_hash
      rescue StandardError
        nil
      end

      private

      def host(scheme)
        host = @env["HTTP_HOST"] || [@env["SERVER_NAME"], @env["SERVER_PORT"]].compact.join(":")
        host.delete_suffix(DEFAULT_PORTS.fetch(scheme, ""))
      end

      def format
        formats = @env["action_dispatch.request.formats"]
        formats.is_a?(Array) && formats.first ? Text.safe_to_s(formats.first) : nil
      end

      def header_name(name)
        return CONTENT_HEADERS[name] unless name.start_with?(HEADER_PREFIX)

        name.delete_prefix(HEADER_PREFIX).split("_").map(&:capitalize).join("-")
      end
    end

    # Params a plain Rack app already has: the parsed query string, plus the
    # form body only if the app parsed it already (Rack caches it in the env).
    # Path params from the Rails router are added when present.
    class RackParams
      def initialize(env)
        @env = env
      end

      def to_h
        merged = query.merge(cached_form)
        path = @env["action_dispatch.request.path_parameters"]
        path.is_a?(Hash) ? merged.merge(path.transform_keys(&:to_s)) : merged
      rescue StandardError
        nil
      end

      private

      def query
        return {} unless defined?(::Rack::Request)

        ::Rack::Request.new(@env).GET
      end

      def cached_form
        form = @env["rack.request.form_hash"]
        form.is_a?(Hash) ? form : {}
      end
    end
  end
end
