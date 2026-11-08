# frozen_string_literal: true

module GoodSorcery
  class Transport
    # One persistent (keep-alive) HTTP connection. A failed request closes it,
    # so the next one reconnects. A request on a reused connection that the
    # server already closed is retried once on a fresh connection; event
    # POSTs are idempotent because the server deduplicates event_id.
    #
    # A connection opened before a fork belongs to the parent: the child
    # drops it without closing it (closing would end the parent's TLS
    # session) and opens its own.
    #
    # A response body is read into a buffer of at most ResponseBody::MAX_BYTES.
    # A longer one is not read to the end: BodyTooLarge carries the response
    # (status and headers) and the connection is closed, so a broken or
    # hostile server cannot fill the app's memory.
    class Connection
      STALE_ERRORS = [EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].freeze
      KEEP_ALIVE_SECONDS = 15

      # Raised when a response body is longer than the buffer allows.
      class BodyTooLarge < StandardError
        attr_reader :response

        def initialize(response)
          super("response body over #{ResponseBody::MAX_BYTES} bytes")
          @response = response
        end
      end

      # The String a response body is read into; refuses to grow past +max+.
      class BoundedBody < String
        class Overflow < StandardError
        end

        def initialize(max)
          super()
          @max = max
        end

        def <<(chunk)
          raise Overflow if bytesize + chunk.bytesize > @max

          super
        end
      end

      def initialize(uri, open_timeout:, read_timeout:)
        @uri = uri
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @http = nil
        @pid = Process.pid
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
        http.start { |started| exchange(started, request) }
      end

      def close
        forget_inherited_connection
        @http&.finish if @http&.started?
      rescue IOError, SystemCallError
        nil
      ensure
        @http = nil
      end

      private

      def perform(request)
        exchange(http, request)
      rescue StandardError
        close
        raise
      end

      def exchange(http, request)
        response = nil
        http.request(request) { |res| (response = res).read_body(BoundedBody.new(ResponseBody::MAX_BYTES)) }
      rescue BoundedBody::Overflow
        raise BodyTooLarge, response
      end

      def http
        forget_inherited_connection
        return @http if @http&.started?

        @http = build_http
        @http.start
        @http
      end

      def forget_inherited_connection
        return if @pid == Process.pid

        @pid = Process.pid
        @http = nil
      end

      def build_http
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
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
