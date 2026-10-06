# frozen_string_literal: true

require_relative "transport/result"
require_relative "transport/connection"
require_relative "transport/batch_chunks"

module GoodSorcery
  # Talks to the ingest API over HTTP(S): keep-alive, gzip, Bearer auth.
  # Takes serialized events (JSON strings) and returns Transport::Result
  # objects. Logs statuses and counts only, never bodies or the full key.
  class Transport
    EVENTS_PATH = "/api/v1/events"
    BATCH_PATH = "/api/v1/events/batch"
    VERIFY_PATH = "/api/v1/verify"
    GZIP_MIN_BYTES = 1_024

    def initialize(endpoint:, api_key:, open_timeout:, read_timeout:, log:)
      @uri = URI(endpoint)
      @api_key = api_key.to_s
      @timeouts = { open_timeout: open_timeout, read_timeout: read_timeout }
      @log = log
      @connection = Connection.new(@uri, **@timeouts)
      @connection_lock = Mutex.new
      @batch_supported = true
      warn_about_plain_http
    end

    def post_event(json)
      result = send_request(post(EVENTS_PATH, json))
      log_result(result, 1)
      result
    end

    # Sends events in as few requests as possible. On a 429 or a retryable
    # failure it stops and returns that result with the unsent events in
    # +pending+. Falls back to one request per event if the server has no
    # batch endpoint (404), and remembers that. A batch the server (or a
    # proxy in front of it) refuses as too large (413) is split in halves.
    def post_batch(jsons)
      return post_each(jsons) unless @batch_supported

      chunks = BatchChunks.split(jsons)
      chunks.each_with_index do |chunk, index|
        result = post_chunk(chunk)
        return result.with_pending(unsent(result, chunk, chunks[(index + 1)..])) if result.retry_later?
        return post_each(chunks[index..].flatten) if result.not_found? && batch_unsupported!
      end
      Result.new(:success)
    end

    def verify
      send_request(Net::HTTP::Get.new(path(VERIFY_PATH), headers))
    end

    def close
      @connection_lock.synchronize { @connection.close }
    end

    def batch_supported?
      @batch_supported
    end

    # Shows the host and the masked key only.
    def inspect
      "#<#{self.class.name} #{@uri.scheme}://#{@uri.host}:#{@uri.port} api_key=#{MaskedKey.new(@api_key)}>"
    end

    private

    def post_chunk(chunk)
      result = send_request(post(BATCH_PATH, BatchChunks.body(chunk)))
      return post_halves(chunk) if result.status == 413 && chunk.size > 1

      log_result(result, chunk.size) unless result.not_found?
      log_partial_rejections(result) if result.success?
      result
    end

    def post_halves(chunk)
      halves = chunk.each_slice((chunk.size + 1) / 2).to_a
      halves.each_with_index do |half, index|
        result = post_chunk(half)
        return result.with_pending(unsent(result, half, halves[(index + 1)..])) if result.retry_later?
      end
      Result.new(:success)
    end

    # What is left after a 429 or retryable result for +chunk+.
    def unsent(result, chunk, later_chunks)
      (result.pending.empty? ? chunk : result.pending) + later_chunks.flatten
    end

    def post_each(jsons)
      jsons.each_with_index do |json, index|
        result = post_event(json)
        return result.with_pending(jsons[index..]) if result.retry_later?
      end
      Result.new(:success)
    end

    def batch_unsupported!
      @log.info("the server has no batch endpoint; sending events one per request")
      @batch_supported = false
      true
    end

    def send_request(request)
      Result.from_response(perform(request))
    rescue StandardError => e
      Result.from_error(e)
    end

    # The persistent connection serves one thread at a time; a concurrent
    # caller (the :sync delivery in a busy app) gets a short-lived one.
    def perform(request)
      return Connection.new(@uri, **@timeouts).request_once(request) unless @connection_lock.try_lock

      begin
        @connection.request(request)
      ensure
        @connection_lock.unlock
      end
    end

    def post(path_name, body)
      request = Net::HTTP::Post.new(path(path_name), headers)
      if body.bytesize >= GZIP_MIN_BYTES
        request["Content-Encoding"] = "gzip"
        body = Zlib.gzip(body, level: Zlib::BEST_SPEED)
      end
      request.body = body
      request
    end

    def headers
      {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "User-Agent" => "#{NOTIFIER_NAME}/#{VERSION}"
      }
    end

    def path(name)
      "#{@uri.path.chomp("/")}#{name}"
    end

    def log_result(result, count)
      return log_invalid_key if result.status == 401
      return if result.success? || result.retry_later?

      @log.warn_every(:"rejected_#{result.status}", 60, "the server rejected #{count} event(s) (#{result.description})")
    end

    def log_invalid_key
      @log.warn_once(:invalid_api_key, "invalid API key #{MaskedKey.new(@api_key)} (HTTP 401); events are dropped")
    end

    def log_partial_rejections(result)
      rejected = Array(result.body["rejected"])
      return if rejected.empty?

      @log.warn_every(:batch_rejections, 60, "the server rejected #{rejected.size} event(s) of a batch as invalid")
    end

    def warn_about_plain_http
      return unless @uri.scheme == "http" && !%w[localhost 127.0.0.1 ::1].include?(@uri.host)

      @log.warn_once(:plain_http, "endpoint #{@uri.host} uses plain HTTP; the API key is sent unencrypted")
    end
  end
end
