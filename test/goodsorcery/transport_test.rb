# frozen_string_literal: true

require "English"
require "test_helper"

class TransportTest < Minitest::Test
  API_KEY = "gs_test_9f2c41aa77d0e81a"

  def setup
    super
    @server = FakeServer.new
  end

  def teardown
    @transport&.close
    @server.stop
    super
  end

  def transport(endpoint: @server.endpoint)
    @transport = GoodSorcery::Transport.new(endpoint: endpoint, api_key: API_KEY, open_timeout: 1,
                                            read_timeout: 1, log: captured_log)
  end

  def event_json(id = SecureRandom.uuid, extra = {})
    JSON.generate({ "event_id" => id, "exception" => { "class" => "RuntimeError" } }.merge(extra))
  end

  def respond(status, body = "{}", headers = {})
    @server.handler = ->(_request) { [status, headers, body] }
  end

  def test_post_event_sends_headers_and_returns_the_id
    result = transport.post_event(event_json("0192f7a4-6c1e-7b3a-9d21-5f0c8e1b0aa1"))
    request = @server.requests.first

    assert_predicate result, :success?
    assert_equal "0192f7a4-6c1e-7b3a-9d21-5f0c8e1b0aa1", result.event_id
    assert_equal ["POST", "/api/v1/events"], [request.http_method, request.path]
    assert_equal "Bearer #{API_KEY}", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]
    assert_equal "goodsorcery-ruby/#{GoodSorcery::VERSION}", request.headers["user-agent"]
    assert_nil request.headers["content-encoding"]
  end

  def test_large_bodies_are_gzipped
    transport.post_event(event_json(SecureRandom.uuid, "padding" => "x" * 5_000))
    request = @server.requests.first

    assert_equal "gzip", request.headers["content-encoding"]
    assert_operator request.raw_body.bytesize, :<, request.body.bytesize
    assert_equal "x" * 5_000, request.json["padding"]
  end

  def test_endpoint_path_prefix_is_kept
    transport(endpoint: "#{@server.endpoint}/tracker").post_event(event_json)

    assert_equal "/tracker/api/v1/events", @server.requests.first.path
  end

  def test_post_batch_sends_one_request_with_all_events
    ids = Array.new(3) { SecureRandom.uuid }
    result = transport.post_batch(ids.map { |id| event_json(id) })
    request = @server.requests.first

    assert_predicate result, :success?
    assert_equal 1, @server.requests.size
    assert_equal "/api/v1/events/batch", request.path
    assert_equal(ids, request.json["events"].map { |event| event["event_id"] })
  end

  def test_batches_are_split_by_count
    transport.post_batch(Array.new(150) { event_json })

    assert_equal([100, 50], @server.requests.map { |request| request.json["events"].size })
  end

  def test_keeps_the_connection_alive
    client = transport
    3.times { client.post_event(event_json) }

    assert_equal 3, @server.requests.size
    assert_equal 1, @server.connections
  end

  def test_falls_back_to_single_events_when_batch_endpoint_is_missing
    @server.handler = lambda do |request|
      request.path.end_with?("/batch") ? [404, {}, "{}"] : FakeServer.accept(request)
    end
    client = transport

    assert_predicate client.post_batch([event_json, event_json]), :success?
    assert_predicate client.post_batch([event_json]), :success?
    refute_predicate client, :batch_supported?
    assert_equal ["/api/v1/events/batch", "/api/v1/events", "/api/v1/events", "/api/v1/events"],
                 @server.requests.map(&:path)
  end

  def test_rate_limited_batch_keeps_events_pending
    respond(429, '{"error":"rate_limited"}', "Retry-After" => "30")
    jsons = [event_json, event_json]
    result = transport.post_batch(jsons)

    assert_predicate result, :rate_limited?
    assert_equal 30, result.retry_after
    assert_equal jsons, result.pending
  end

  def test_server_errors_are_retryable
    respond(503)

    assert_predicate transport.post_event(event_json), :retryable?
  end

  def test_client_errors_are_rejected_and_not_retried
    [400, 413, 415, 422].each do |status|
      respond(status)
      result = transport.post_batch([event_json])

      assert_predicate result, :success?, "a rejected batch is not retried (#{status})"
      assert_empty result.pending
    end
    assert_includes log_output, "the server rejected 1 event(s) (HTTP 422)"
  end

  def test_invalid_api_key_is_logged_once_and_masked
    respond(401, '{"error":"invalid_api_key"}')
    client = transport
    2.times { assert_predicate client.post_event(event_json), :rejected? }

    assert_equal 1, log_output.scan("invalid API key gs_test_…e81a").size
    refute_includes log_output, API_KEY
  end

  def test_connection_errors_are_retryable
    port = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
    result = transport(endpoint: "http://127.0.0.1:#{port}").post_event(event_json)

    assert_predicate result, :retryable?
    assert_match(/ECONNREFUSED/, result.description)
  end

  def test_read_timeouts_are_retryable
    @server.handler = lambda do |_request|
      sleep 1.5
      [202, {}, "{}"]
    end
    @transport = GoodSorcery::Transport.new(endpoint: @server.endpoint, api_key: API_KEY, open_timeout: 1,
                                            read_timeout: 0.2, log: captured_log)

    assert_predicate @transport.post_event(event_json), :retryable?
  end

  def test_verify
    respond(200, '{"ok":true,"environment":"staging"}')
    result = transport.verify

    assert_predicate result, :success?
    assert_equal "GET", @server.requests.first.http_method
    assert_equal "/api/v1/verify", @server.requests.first.path
    assert_equal "staging", result.body["environment"]
  end

  def test_a_forked_child_opens_its_own_connection
    skip "fork is not available" unless Process.respond_to?(:fork)
    client = transport
    client.post_event(event_json)
    pid = fork do
      result = client.post_event(event_json)
      client.close
      exit!(result.success? ? 0 : 1)
    end
    Process.wait(pid)

    assert_predicate $CHILD_STATUS, :success?
    assert_predicate client.post_event(event_json), :success?
    assert_equal 3, @server.requests.size
    assert_equal 2, @server.connections, "the child must not write to the parent's keep-alive socket"
  end

  def test_https_connections_verify_the_certificate
    connection = GoodSorcery::Transport::Connection.new(URI("https://errors.example.com"), open_timeout: 1,
                                                                                           read_timeout: 1)

    assert_equal OpenSSL::SSL::VERIFY_PEER, connection.send(:build_http).verify_mode
  end

  def test_warns_about_plain_http_for_remote_hosts
    GoodSorcery::Transport.new(endpoint: "http://errors.example.com", api_key: API_KEY, open_timeout: 1,
                               read_timeout: 1, log: captured_log)

    assert_includes log_output, "uses plain HTTP"
  end
end

class BatchChunksTest < Minitest::Test
  def test_splits_by_bytes
    big = "x" * 700_000
    chunks = GoodSorcery::Transport::BatchChunks.split([big, big, big])

    assert_equal [2, 1], chunks.map(&:size)
  end

  def test_body_wraps_events
    assert_equal '{"events":[{"a":1},{"b":2}]}', GoodSorcery::Transport::BatchChunks.body(['{"a":1}', '{"b":2}'])
  end
end

class RetryAfterTest < Minitest::Test
  def test_parses_seconds_dates_and_defaults
    now = Time.utc(2026, 10, 4, 9, 0, 0)

    assert_equal 30, GoodSorcery::Transport::RetryAfter.parse("30")
    assert_equal 120, GoodSorcery::Transport::RetryAfter.parse((now + 120).httpdate, now: now)
    assert_equal 60, GoodSorcery::Transport::RetryAfter.parse(nil)
    assert_equal 3_600, GoodSorcery::Transport::RetryAfter.parse("999999")
  end
end

class VerificationTest < Minitest::Test
  def setup
    super
    @server = FakeServer.new
    GoodSorcery.configure do |config|
      config.endpoint = @server.endpoint
      config.api_key = "gs_test_9f2c41aa77d0e81a"
    end
  end

  def teardown
    @server.stop
    super
  end

  def test_ok_with_environment
    @server.handler = ->(_request) { [200, {}, '{"ok":true,"environment":"staging"}'] }
    verification = GoodSorcery.verify

    assert_predicate verification, :ok?
    assert_equal "staging", verification.environment
    assert_includes verification.message, "gs_test_…e81a"
  end

  def test_rejected_key
    @server.handler = ->(_request) { [401, {}, "{}"] }

    refute_predicate GoodSorcery.verify, :ok?
    assert_includes GoodSorcery.verify.message, "rejected API key"
  end

  def test_missing_key_sends_nothing
    GoodSorcery.configure { |config| config.api_key = nil }

    refute_predicate GoodSorcery.verify, :ok?
    assert_empty @server.requests
  end
end
