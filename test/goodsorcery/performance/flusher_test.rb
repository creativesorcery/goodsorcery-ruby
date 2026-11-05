# frozen_string_literal: true

require "test_helper"

# Stands in for the Transport: records APM posts and answers from a script.
class FakeApmTransport
  Result = GoodSorcery::Transport::Result

  attr_reader :posts

  def initialize(*script)
    @script = script
    @posts = []
  end

  def post_apm(path, json)
    @posts << [path, JSON.parse(json)]
    step = @script.shift || :success
    case step
    when :success then Result.new(:success, status: 202)
    when :rate_limited then Result.new(:rate_limited, status: 429, retry_after: 0.05)
    when :retryable then Result.new(:retryable, status: 503)
    when :not_found then Result.new(:not_found, status: 404)
    else Result.new(:rejected, status: step)
    end
  end

  def batch_ids = @posts.map { |_path, body| body["batch_id"] }
end

class FlusherTest < Minitest::Test
  Flusher = GoodSorcery::Performance::Flusher
  FakeAgent = Struct.new(:aggregator, :trace_buffer)
  NOW = 29_500_000 * 60.0

  def setup
    super
    GoodSorcery.configure { |config| config.delivery = :sync }
    @agent = FakeAgent.new(Performance::Aggregator.new, Performance::TraceBuffer.new)
    @now = NOW + 30
  end

  def flusher(transport, offset: 7.5)
    Flusher.new(agent: @agent, log: captured_log, clock: -> { @now }, offset: offset, transport: -> { transport })
  end

  def record(minute_offset = -1, name: "ProductsController#show")
    @agent.aggregator.record((NOW / 60).floor + minute_offset, sample(20.0, name: name))
  end

  def test_wakes_at_the_next_minute_plus_its_offset
    assert_equal NOW + 60 + 7.5, flusher(nil).next_wake_at(NOW + 30)
    assert_equal NOW + 120 + 7.5, flusher(nil).next_wake_at(NOW + 60)
    offsets = Array.new(20) { Flusher.new(agent: @agent, log: captured_log).offset }

    assert(offsets.all? { |offset| offset.between?(2.0, 20.0) })
    assert_operator offsets.uniq.size, :>, 1
  end

  def test_sends_closed_minutes_only_unless_the_open_one_is_included
    transport = FakeApmTransport.new
    subject = flusher(transport)
    record(-1)
    record(0, name: "Open#minute")
    subject.flush

    assert_equal([["/api/v1/apm/metrics", "2026-02-02T02:39:00Z"]],
                 transport.posts.map { |path, body| [path, body["minutes"].first["minute"]] })
    subject.flush(include_open: true)
    assert_equal "Open#minute", transport.posts.last.last["minutes"].first["transactions"].first["name"]
  end

  def test_traces_follow_the_metrics
    transport = FakeApmTransport.new
    record
    @agent.trace_buffer.offer((NOW / 60).floor - 1, [:web, "A#b"], 10.0, { "id" => "t1" })
    flusher(transport).flush

    assert_equal %w[/api/v1/apm/metrics /api/v1/apm/traces], transport.posts.map(&:first)
    assert_equal [{ "id" => "t1" }], transport.posts.last.last["traces"]
  end

  def test_a_failed_payload_keeps_its_batch_id_and_is_dropped_after_three_attempts
    transport = FakeApmTransport.new(:retryable, :retryable, :retryable)
    subject = flusher(transport)
    record
    3.times { subject.flush }

    assert_equal 3, transport.posts.size
    assert_equal 1, transport.batch_ids.uniq.size
    assert_equal 0, subject.outbox.size
    assert_includes log_output, "could not send performance data (HTTP 503); dropped"
  end

  def test_a_retry_succeeds_with_the_same_batch_id
    transport = FakeApmTransport.new(:retryable)
    subject = flusher(transport)
    record
    subject.flush
    subject.flush

    assert_equal 2, transport.posts.size
    assert_equal 1, transport.batch_ids.uniq.size
    assert_equal 0, subject.outbox.size
  end

  def test_rate_limited_waits_for_retry_after
    transport = FakeApmTransport.new(:rate_limited)
    subject = flusher(transport)
    record
    subject.flush
    subject.flush

    assert_equal 1, transport.posts.size
    sleep 0.06
    subject.flush
    assert_equal 2, transport.posts.size
    assert_equal 1, transport.batch_ids.uniq.size
  end

  def test_rejected_payloads_are_dropped_and_the_rest_still_sent
    transport = FakeApmTransport.new(422)
    subject = flusher(transport)
    record
    @agent.trace_buffer.offer((NOW / 60).floor - 1, [:web, "A#b"], 10.0, { "id" => "t1" })
    subject.flush

    assert_equal 2, transport.posts.size
    assert_equal 0, subject.outbox.size
    assert_includes log_output, "the server rejected performance data (HTTP 422); dropped"
  end

  def test_not_found_turns_performance_monitoring_off
    start_performance(delivery: :sync, enabled: true, api_key: "gs_test_key")
    transport = FakeApmTransport.new(:not_found)
    subject = flusher(transport)
    record
    subject.flush

    refute Performance.active?
    assert_equal 0, subject.outbox.size
    assert_includes log_output, "the server has no performance endpoints; performance monitoring is off"
  end

  def test_pending_metrics_are_bounded_to_five_minutes
    transport = FakeApmTransport.new(Array.new(10, :retryable))
    subject = flusher(transport)
    7.times do |index|
      record(-1)
      subject.flush
      @now += 60 if index < 6
      transport.posts.clear
    end

    assert_operator subject.outbox.size, :<=, 5
  end

  def test_shutdown_sends_the_open_minute
    transport = FakeApmTransport.new
    subject = flusher(transport)
    record(0)
    subject.ensure_started

    assert subject.running?
    subject.shutdown(1)
    refute subject.running?
    assert_equal ["/api/v1/apm/metrics"], transport.posts.map(&:first)
  end

  def test_the_thread_is_named_and_stops
    subject = flusher(FakeApmTransport.new)
    subject.ensure_started
    thread = Thread.list.find { |each_thread| each_thread.name == "goodsorcery-apm" }

    assert thread
    subject.stop!
    assert(wait_until { !thread.alive? })
  end

  def test_a_flush_that_fails_never_raises
    exploding = Object.new
    def exploding.post_apm(*) = raise(IOError, "boom")
    subject = flusher(exploding)
    record

    refute subject.flush
    assert_includes log_output, "performance flush failed (IOError)"
  end
end

# Real HTTP: paths, auth, gzip.
class FlusherOverHttpTest < Minitest::Test
  def setup
    super
    @server = FakeServer.new { |_request| [202, {}, '{"id":"x"}'] }
    GoodSorcery.configure do |config|
      config.delivery = :sync
      config.enabled = true
      config.api_key = "gs_test_flusher"
      config.endpoint = @server.endpoint
      config.performance_monitoring = true
      config.root = PerformanceHelpers::REPO_ROOT
    end
    assert Performance.install
  end

  def teardown
    GoodSorcery.reset!
    @server.stop
    super
  end

  def test_posts_gzip_json_with_the_api_key
    50.times { |index| Performance.agent.aggregator.record(1, sample(5.0, name: "C#a#{index}")) }
    GoodSorcery.flush_performance

    assert_equal 1, @server.requests.size
    request = @server.requests.first

    assert_equal ["POST", "/api/v1/apm/metrics"], [request.http_method, request.path]
    assert_equal "Bearer gs_test_flusher", request.headers["authorization"]
    assert_equal "gzip", request.headers["content-encoding"]
    assert_equal 50, request.json["minutes"].first["transactions"].size
  end

  def test_the_gems_own_requests_are_not_measured
    recorder = Performance.start(:web)
    recorder.name = "A#b"
    Performance.agent.aggregator.record(1, sample(5.0))
    GoodSorcery.flush_performance
    Performance.finish(recorder)

    assert_equal 0, recorder.http_count
  end

  def test_a_forked_child_starts_empty
    skip "fork is not available" unless Process.respond_to?(:fork)

    Performance.agent.aggregator.record(1, sample(5.0))
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write([Performance.agent.aggregator.empty?, Performance.agent.pid == Process.pid].inspect)
      writer.close
      exit!(0)
    end
    writer.close
    result = reader.read
    Process.wait(pid)

    assert_equal "[true, true]", result
    refute Performance.agent.aggregator.empty?
  end
end
