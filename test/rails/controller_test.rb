# frozen_string_literal: true

require_relative "support/rails_app"
require "rack/mock_request"

class ControllerIntegrationTest < Minitest::Test
  def setup
    super
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.filter_params += ["nickname", /\Ahidden_/]
    end
  end

  def request(method, path, **options)
    Rack::MockRequest.new(Rails.application).request(method, path, { "REMOTE_ADDR" => "203.0.113.9" }.merge(options))
  end

  def events = GoodSorcery.test_events

  def post_order
    request("POST", "/orders?token=abc&page=2",
            params: { "order" => { "card_number" => "4111", "nickname" => "neo", "hidden_tip" => "x",
                                   "internal_note" => "vip", "item" => "book" }, "password" => "pw" },
            "HTTP_X_REQUEST_ID" => "req-123", "HTTP_USER_AGENT" => "curl/8", "HTTP_COOKIE" => "_session=abc")
  end

  def test_a_controller_exception_is_reported_once_with_the_filtered_request
    response = post_order
    request = events.first["request"]

    assert_equal 500, response.status
    assert_equal 1, events.size
    assert_equal "http://example.org/orders?token=[FILTERED]&page=2", request["url"]
    assert_equal "POST", request["method"]
    assert_equal "text/html", request["format"]
    assert_equal "req-123", request["request_id"]
    assert_equal "203.0.113.9", request["remote_ip"]
    assert_equal "[FILTERED]", request["headers"]["Cookie"]
    assert_equal "curl/8", request["headers"]["User-Agent"]
  end

  def test_params_are_filtered_by_custom_default_and_rails_rules
    post_order
    params = events.first["request"]["params"]

    assert_equal({ "card_number" => "[FILTERED]", "nickname" => "[FILTERED]", "hidden_tip" => "[FILTERED]",
                   "internal_note" => "[FILTERED]", "item" => "book" }, params["order"])
    assert_equal "[FILTERED]", params["password"]
    assert_equal "[FILTERED]", params["token"]
    assert_equal "2", params["page"]
    assert_equal "orders", params["controller"]
  end

  def test_rails_filter_parameters_apply_to_the_url_query_string
    request("GET", "/orders/1?internal_note=vip&order%5Binternal_note%5D=x&page=2")
    request = events.first["request"]

    assert_equal "http://example.org/orders/1?internal_note=[FILTERED]&order%5Binternal_note%5D=[FILTERED]&page=2",
                 request["url"]
    assert_equal "[FILTERED]", request["params"]["internal_note"]
  end

  def test_rails_filter_parameters_can_be_turned_off
    GoodSorcery.configure { |config| config.use_rails_filter_parameters = false }
    post_order

    assert_equal "vip", events.first["request"]["params"]["order"]["internal_note"]
  end

  def test_transaction_controller_context_user_and_session
    post_order
    event = events.first

    assert_equal "OrdersController#create", event["transaction"]
    assert_equal({ "controller" => "OrdersController", "action" => "create" }, event["context"]["controller"])
    assert_equal "A-1", event["context"]["order_ref"]
    assert_equal({ "id" => 42, "email" => "mara@example.com", "username" => "mara", "name" => "Mara Lind" },
                 event["user"])
    assert_equal({ "cart_id" => 5, "auth_token" => "[FILTERED]" }, event["request"]["session"].except("session_id"))
  end

  def test_breadcrumbs_from_the_request_and_notifications
    post_order
    crumbs = events.first["breadcrumbs"]

    assert_equal(["POST /orders", "OrdersController#create as HTML"], crumbs.first(2).map { |crumb| crumb["message"] })
    sql = crumbs.find { |crumb| crumb["category"] == "sql" }
    assert_match(/\AOrder Load \(\d+(\.\d+)?ms\)\z/, sql["message"])
    assert_equal({ "sql" => "SELECT * FROM orders WHERE email = ? LIMIT ?" }, sql["data"])
    assert_equal(1, crumbs.count { |crumb| crumb["category"] == "sql" })
  end

  def test_an_unloaded_session_is_left_out
    request("GET", "/orders/12")

    assert_equal 1, events.size
    refute events.first["request"].key?("session")
    assert_equal "OrdersController#show", events.first["transaction"]
  end

  def test_handled_errors_are_reported_as_warnings_with_the_rails_error_context
    response = request("GET", "/handled")
    event = events.first

    assert_equal 200, response.status
    assert_equal 1, events.size
    assert_equal "warning", event["level"]
    assert_equal "OrdersController#handled", event["transaction"]
    assert_equal "/handled", URI(event["request"]["url"]).path
    rails_error = event["context"]["rails_error"]
    assert_equal 7, rails_error["order_id"]
    assert_equal "[FILTERED]", rails_error["card_number"]
    assert_equal "#<OrdersController>", rails_error["controller"]
    assert_equal "application", rails_error["source"]
  end

  def test_handled_errors_can_be_left_out
    GoodSorcery.configure { |config| config.report_handled_errors = false }
    request("GET", "/handled")

    assert_empty events
  end

  def test_ignored_exceptions_are_skipped
    request("GET", "/missing")

    assert_empty events
  end

  def test_each_request_starts_with_a_clean_scope
    request("GET", "/leak")

    assert_nil Thread.current[GoodSorcery::Scope::STORAGE_KEY]
    post_order
    refute events.first["context"].key?("leak")
    assert_equal 42, events.first["user"]["id"]
  end

  def test_a_disabled_environment_sends_nothing
    delivered = []
    recorder = Object.new
    recorder.define_singleton_method(:deliver) { |event| delivered << event }
    GoodSorcery.configure do |config|
      config.delivery = recorder
      config.environment = "test"
    end
    post_order

    assert_empty delivered
  end
end
