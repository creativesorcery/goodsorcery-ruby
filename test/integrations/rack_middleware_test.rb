# frozen_string_literal: true

require "test_helper"
require "rack"
require "rack/mock_request"

class RackMiddlewareTest < Minitest::Test
  class AppError < StandardError; end
  class IgnoredError < StandardError; end

  # A session object that is not loaded yet; reading it would load it.
  class LazySession
    def loaded? = false
    def to_hash = raise("the session must not be loaded")
  end

  def setup
    super
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.filter_params += ["nickname", /\Ahidden_/]
      config.ignore_exceptions += ["RackMiddlewareTest::IgnoredError"]
    end
  end

  def stack(&app) = GoodSorcery::Rack::Middleware.new(app)

  def request(app, method, path, **options)
    ::Rack::MockRequest.new(app).request(method, path, options)
  end

  def events = GoodSorcery.test_events

  def post_order(app)
    request(app, "POST", "/orders?token=abc&page=2",
            params: { "password" => "pw", "nickname" => "neo", "hidden_note" => "n", "item" => "book" },
            "HTTP_USER_AGENT" => "curl/8", "HTTP_AUTHORIZATION" => "Bearer x",
            "HTTP_X_REQUEST_ID" => "req-1", "REMOTE_ADDR" => "203.0.113.9")
  end

  def test_reports_a_propagating_exception_with_the_filtered_request
    app = stack do |env|
      ::Rack::Request.new(env).POST
      raise AppError, "boom"
    end
    assert_raises(AppError) { post_order(app) }

    assert_equal 1, events.size
    request = events.first["request"]
    assert_equal "http://example.org/orders?token=[FILTERED]&page=2", request["url"]
    assert_equal "POST", request["method"]
    assert_equal "req-1", request["request_id"]
    assert_equal "203.0.113.9", request["remote_ip"]
    assert_equal({ "token" => "[FILTERED]", "page" => "2", "password" => "[FILTERED]", "nickname" => "[FILTERED]",
                   "hidden_note" => "[FILTERED]", "item" => "book" }, request["params"])
    assert_equal "curl/8", request["headers"]["User-Agent"]
    assert_equal "[FILTERED]", request["headers"]["Authorization"]
    assert_equal "application/x-www-form-urlencoded", request["headers"]["Content-Type"]
  end

  def test_records_a_request_breadcrumb
    assert_raises(AppError) { request(stack { raise AppError }, "GET", "/reports/7") }

    crumb = events.first["breadcrumbs"].first
    assert_equal "request", crumb["category"]
    assert_equal "GET /reports/7", crumb["message"]
  end

  def test_never_reads_an_unparsed_body_or_an_unloaded_session
    seen_env = nil
    app = stack do |env|
      seen_env = env
      raise AppError
    end
    assert_raises(AppError) do
      request(app, "POST", "/login?step=1", params: { "password" => "pw" }, "rack.session" => LazySession.new)
    end

    assert_equal({ "step" => "1" }, events.first["request"]["params"])
    assert_nil events.first["request"]["session"]
    refute seen_env.key?("rack.request.form_hash")
  end

  def test_includes_a_loaded_session_filtered
    app = stack { raise AppError }
    assert_raises(AppError) do
      request(app, "GET", "/", "rack.session" => { "cart_id" => 5, "session_id" => "abc" })
    end

    assert_equal({ "cart_id" => 5, "session_id" => "[FILTERED]" }, events.first["request"]["session"])
  end

  def test_capture_switches_leave_out_params_headers_and_session
    GoodSorcery.configure do |config|
      config.send_request_params = false
      config.send_request_headers = false
      config.send_session = false
    end
    assert_raises(AppError) { request(stack { raise AppError }, "GET", "/?q=1", "rack.session" => { "a" => 1 }) }

    assert_equal %w[method url], events.first["request"].keys.sort
  end

  def test_reports_an_error_a_framework_turned_into_a_5xx_response_once
    error = raise_and_rescue(AppError, "rendered")
    app = stack do |env|
      env["sinatra.error"] = error
      [500, {}, ["oops"]]
    end
    response = request(app, "GET", "/")
    GoodSorcery.notify(error)

    assert_equal 500, response.status
    assert_equal 1, events.size
    assert_equal "rendered", events.first["exception"]["message"]
  end

  def test_ignores_rescued_errors_behind_non_5xx_responses
    app = stack do |env|
      env["action_dispatch.exception"] = raise_and_rescue(AppError)
      [404, {}, []]
    end
    request(app, "GET", "/")

    assert_empty events
  end

  def test_skips_ignored_exceptions_but_still_raises_them
    assert_raises(IgnoredError) { request(stack { raise IgnoredError }, "GET", "/") }
    assert_empty events
  end

  def test_each_request_starts_with_a_clean_scope_and_clears_it_after
    leaky = stack do
      GoodSorcery.context(leak: true)
      GoodSorcery.user = { id: 9 }
      [200, {}, []]
    end
    request(leaky, "GET", "/first")
    assert_nil Thread.current[GoodSorcery::Scope::STORAGE_KEY]

    assert_raises(AppError) { request(stack { raise AppError }, "GET", "/second") }
    refute events.first["context"].key?("leak")
    assert_nil events.first["user"]
    assert_equal(["GET /second"], events.first["breadcrumbs"].map { |crumb| crumb["message"] })
  end

  def test_a_configured_request_extractor_takes_over
    extractor = Object.new
    extractor.define_singleton_method(:extract) { |env| { "url" => "custom://#{env["PATH_INFO"]}" } }
    GoodSorcery.configure { |config| config.request_extractor = extractor }
    assert_raises(AppError) { request(stack { raise AppError }, "GET", "/x") }

    assert_equal({ "url" => "custom:///x" }, events.first["request"])
  end

  def test_disabled_environment_sends_nothing
    delivered = []
    recorder = Object.new
    recorder.define_singleton_method(:deliver) { |event| delivered << event }
    GoodSorcery.configure do |config|
      config.delivery = recorder
      config.environment = "development"
    end
    assert_raises(AppError) { request(stack { raise AppError }, "GET", "/") }

    assert_empty delivered
  end
end
