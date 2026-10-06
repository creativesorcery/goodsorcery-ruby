# frozen_string_literal: true

module GoodSorcery
  class Transport
    # The outcome of one request, classified for retry decisions:
    #
    # - success: 2xx
    # - rejected: 400, 401, 413, 415, 422 and other 4xx (never retried)
    # - not_found: 404 (an older server without the endpoint)
    # - rate_limited: 429, with retry_after seconds
    # - retryable: 5xx, 408, timeouts and connection errors
    #
    # +pending+ lists the serialized events still to send after a
    # rate_limited or retryable batch result.
    class Result
      KINDS = %i[success rejected not_found rate_limited retryable].freeze

      attr_reader :kind, :status, :retry_after, :error_class, :body, :pending

      def self.from_response(response)
        status = response.code.to_i
        new(kind_for(status), status: status, body: ResponseBody.parse(response),
                              retry_after: status == 429 ? RetryAfter.parse(response["Retry-After"]) : nil)
      end

      def self.from_error(error)
        new(:retryable, error_class: error.class.name)
      end

      def self.kind_for(status)
        return :success if (200..299).cover?(status)
        return :not_found if status == 404
        return :rate_limited if status == 429
        return :retryable if status >= 500 || status == 408

        :rejected
      end

      def initialize(kind, status: nil, body: nil, retry_after: nil, error_class: nil, pending: [])
        @kind = kind
        @status = status
        @body = body || {}
        @retry_after = retry_after
        @error_class = error_class
        @pending = pending
      end

      KINDS.each { |name| define_method(:"#{name}?") { @kind == name } }

      def retry_later?
        rate_limited? || retryable?
      end

      def with_pending(pending)
        self.class.new(kind, status: status, body: body, retry_after: retry_after,
                             error_class: error_class, pending: pending)
      end

      def event_id
        body["id"]
      end

      # Status or error class only, never the body.
      def description
        status ? "HTTP #{status}" : error_class.to_s
      end
    end

    # Parses small JSON response bodies; anything else becomes {}.
    module ResponseBody
      MAX_BYTES = 65_536

      def self.parse(response)
        text = response.body.to_s
        return {} if text.empty? || text.bytesize > MAX_BYTES

        parsed = JSON.parse(text)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end

    # Reads a Retry-After header (seconds or an HTTP date), defaulting to 60 s.
    module RetryAfter
      DEFAULT = 60
      RANGE = (1..3_600)

      def self.parse(value, now: Time.now)
        seconds = value.to_s.strip.match?(/\A\d+\z/) ? value.to_i : http_date_delay(value, now)
        (seconds || DEFAULT).clamp(RANGE.min, RANGE.max)
      end

      def self.http_date_delay(value, now)
        return nil if value.nil? || value.to_s.empty?

        (Time.httpdate(value.to_s) - now).ceil
      rescue ArgumentError
        nil
      end
    end
  end
end
