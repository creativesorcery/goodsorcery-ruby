# frozen_string_literal: true

module GoodSorcery
  class Transport
    # One persistent (keep-alive) HTTP connection. A failed request closes it,
    # so the next one reconnects. A request on a reused connection that the
    # server already closed is retried once on a fresh connection; event
    # POSTs are idempotent because the server deduplicates event_id.
    class Connection
      STALE_ERRORS = [EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].freeze
      KEEP_ALIVE_SECONDS = 15

      def initialize(uri, open_timeout:, read_timeout:)
        @uri = uri
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @http = nil
      end

      def request(request)
        reused = @http&.started?
        perform(request)
      rescue *STALE_ERRORS
        raise unless reused

        perform(request)
      end

      # Sends one request on a short-lived connection.
      def request_once(request)
        http = build_http
        http.start { |started| started.request(request) }
      end

      def close
        @http&.finish if @http&.started?
      rescue IOError, SystemCallError
        nil
      ensure
        @http = nil
      end

      private

      def perform(request)
        http.request(request)
      rescue StandardError
        close
        raise
      end

      def http
        return @http if @http&.started?

        @http = build_http
        @http.start
        @http
      end

      def build_http
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @read_timeout
        http.keep_alive_timeout = KEEP_ALIVE_SECONDS
        http.max_retries = 0
        http
      end
    end
  end
end
