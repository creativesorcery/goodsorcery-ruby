# frozen_string_literal: true

require "test_helper"

class NetHttpSpanTest < Minitest::Test
  def setup
    super
    start_performance
    @server = FakeServer.new { |_request| [201, {}, "{}"] }
  end

  def teardown
    @server.stop
    super
  end

  def recording
    recorder = Performance.start(:web)
    recorder.name = "CheckoutsController#create"
    yield
    recorder
  ensure
    Performance.finish(recorder)
  end

  def uri(path) = URI("#{@server.endpoint}#{path}")

  def http_span(recorder)
    spans = recorder.spans.select { |span| span[0] == :http }
    assert_equal 1, spans.size
    spans.first
  end

  def test_records_method_host_path_without_query_and_status
    recorder = recording { Net::HTTP.post(uri("/v2/taxes?api_key=s3cret&x=1"), "{}") }
    span = http_span(recorder)

    assert_equal ["POST", "127.0.0.1", "/v2/taxes?api_key=s3cret&x=1", 201], span[3..6]
    trace_span = recorded_traces.first["spans"].first

    assert_equal({ "type" => "http", "method" => "POST", "host" => "127.0.0.1", "path" => "/v2/taxes",
                   "status" => 201 }, trace_span.except("offset_ms", "duration_ms"))
    assert_equal 1, recorded_traces.first["http_count"]
    assert_operator recorded_traces.first["http_ms"], :>, 0
  end

  def test_a_request_through_start_is_one_span
    recorder = recording do
      Net::HTTP.start("127.0.0.1", @server.port) { |http| http.get("/a") }
      Net::HTTP.get(uri("/b"))
    end

    assert_equal 2, recorder.http_count
  end

  def test_nothing_is_recorded_outside_a_unit_of_work
    response = Net::HTTP.get_response(uri("/free"))

    assert_equal "201", response.code
    assert_empty metrics_transactions
  end

  def test_the_apps_network_errors_still_reach_it
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    recorder = nil
    assert_raises(Errno::ECONNREFUSED) do
      recorder = Performance.start(:web)
      recorder.name = "A#b"
      Net::HTTP.new("127.0.0.1", port).request(Net::HTTP::Get.new("/down"))
    ensure
      Performance.finish(recorder)
    end
    span = http_span(recorder)

    assert_nil span[6]
  end

  def test_a_recording_failure_leaves_the_http_call_alone
    recorder = recording do
      Performance.current_recorder.define_singleton_method(:add_http) { |*| raise "span bug" }
      assert_equal "{}", Net::HTTP.get(uri("/still-works"))
    end

    assert recorder.broken?
  end

  def test_suppressed_requests_are_not_recorded
    recorder = recording { Performance.suppress { Net::HTTP.get(uri("/own")) } }

    assert_equal 0, recorder.http_count
  end

  def test_net_http_is_prepended_once
    Performance::NetHttp.install

    assert_equal 1, Net::HTTP.ancestors.count(Performance::NetHttp)
  end
end
