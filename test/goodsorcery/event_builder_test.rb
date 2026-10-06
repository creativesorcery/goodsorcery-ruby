# frozen_string_literal: true

require "test_helper"

class EventBuilderTest < Minitest::Test
  UUID = /\A\h{8}-\h{4}-[47]\h{3}-[89ab]\h{3}-\h{12}\z/
  APP_SOURCE = <<~RUBY
    module GsFixture
      class Cart
        def total(depth)
          return recurse(depth) if depth.positive?

          raise ArgumentError, "price missing"
        end

        def recurse(depth)
          total(depth - 1)
        end
      end
    end
  RUBY

  def setup
    super
    @root = File.realpath(Dir.mktmpdir)
    FileUtils.mkdir_p(File.join(@root, "app/models"))
    File.write(File.join(@root, "app/models/cart.rb"), APP_SOURCE)
    load File.join(@root, "app/models/cart.rb")
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.root = @root
      config.release = "a1b2c3d"
    end
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def app_error(depth = 0)
    GsFixture::Cart.new.total(depth)
  rescue ArgumentError => e
    e
  end

  def build(error = app_error, **options)
    GoodSorcery.client.prepare_event(error, options)
  end

  def test_top_level_fields_follow_the_ingest_api
    event = build(level: :warn, transaction: "CartsController#show", fingerprint: ["cart", :total, 3, {}])

    assert_match UUID, event["event_id"]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, event["occurred_at"])
    assert_equal "warning", event["level"]
    assert_equal "a1b2c3d", event["release"]
    assert_equal "CartsController#show", event["transaction"]
    assert_equal %w[cart total 3], event["fingerprint"]
    assert_equal({ "name" => "goodsorcery-ruby", "version" => GoodSorcery::VERSION }, event["notifier"])
    assert_equal "error", build["level"]
  end

  def test_event_is_json_and_uses_only_documented_keys
    documented = %w[event_id occurred_at level release transaction exception request user breadcrumbs
                    context tags fingerprint notifier]
    event = build

    assert_empty event.keys - documented
    assert_equal event, JSON.parse(JSON.generate(event))
  end

  def test_exception_section
    exception = build["exception"]
    frame = exception["backtrace"].first

    assert_equal "ArgumentError", exception["class"]
    assert_equal "price missing", exception["message"]
    assert_equal "app/models/cart.rb", frame["file"]
    assert_equal 6, frame["line"]
    assert_match(/total/, frame["method"])
    assert frame["in_app"]
    assert_equal 1, frame["context"]["start_line"]
    assert_equal '      raise ArgumentError, "price missing"', frame["context"]["lines"][5]
  end

  def test_code_context_only_for_the_top_ten_in_app_frames
    frames = build(app_error(6))["exception"]["backtrace"]
    in_app = frames.select { |frame| frame["in_app"] }

    assert_operator in_app.size, :>, 10
    assert(in_app.first(10).all? { |frame| frame["context"] })
    assert(in_app.drop(10).none? { |frame| frame["context"] })
    refute(frames.reject { |frame| frame["in_app"] }.any? { |frame| frame["context"] })
  end

  def test_code_context_can_be_turned_off
    GoodSorcery.configure { |config| config.send_code_context = false }

    refute(build["exception"]["backtrace"].any? { |frame| frame["context"] })
  end

  def test_message_is_capped
    assert_equal 10_000, build(RuntimeError.new("x" * 20_000))["exception"]["message"].length
  end

  def test_cause_chain_up_to_three
    error = nested_error(5)
    causes = build(error)["context"]["cause"]

    assert_equal 3, causes.size
    assert_equal({ "class" => "RuntimeError", "message" => "level 4" }, causes.first)
  end

  def test_runtime_context
    context = build["context"]

    assert_match(/\A\d+\.\d+\.\d+/, context["runtime"]["ruby"])
    assert_kind_of String, context["host"]
    assert_match(/\Apid \d+ · thread \S+\z/, context["process"])
  end

  def test_env_context_only_has_rails_and_rack_env
    with_env("RAILS_ENV" => "production", "SECRET_KEY_BASE" => "nope") do
      assert_equal({ "RAILS_ENV" => "production" }, build["context"]["env"])
    end
  end

  def test_user_keeps_four_fields
    user = { id: 5521, email: "mara@example.com", username: "mara", name: "Mara", admin: true }

    assert_equal({ "id" => 5521, "email" => "mara@example.com", "username" => "mara", "name" => "Mara" },
                 build(user: user)["user"])
  end

  def test_user_from_an_object
    user = Struct.new(:id, :email, :password).new(7, "a@b.c", "secret")

    assert_equal({ "id" => 7, "email" => "a@b.c" }, build(user: user)["user"])
  end

  def test_tags_merge_global_scope_and_call_and_drop_invalid_ones
    GoodSorcery.configure { |config| config.tags = { region: "eu", tier: "gold" } }
    GoodSorcery.tags(tier: "silver", "bad key!" => "x")
    tags = build(tags: { nested: { a: 1 }, flag: true, long: "y" * 300 })["tags"]

    assert_equal({ "region" => "eu", "tier" => "silver", "flag" => true, "long" => "y" * 200 }, tags)
  end

  def test_at_most_25_tags
    tags = build(tags: (1..40).to_h { |n| ["t#{n}", n] })["tags"]

    assert_equal 25, tags.size
  end

  def test_scope_context_and_call_context_are_filtered_and_capped
    GoodSorcery.context(order_id: 1, api_token: "t")
    context = build(context: { "big" => "z" * 5_000 })["context"]

    assert_equal 1, context["order_id"]
    assert_equal "[FILTERED]", context["api_token"]
    assert_equal 4_096, context["big"].length
  end

  def test_breadcrumbs_from_the_scope
    GoodSorcery.add_breadcrumb("POST /checkout", category: :request, data: { password: "x", n: 1 })
    GoodSorcery.add_breadcrumb("odd", category: "nope", level: "warn")
    crumbs = build["breadcrumbs"]

    assert_equal(%w[request custom], crumbs.map { |crumb| crumb["category"] })
    assert_equal({ "password" => "[FILTERED]", "n" => 1 }, crumbs.first["data"])
    assert_equal "warning", crumbs.last["level"]
    assert_match(/Z\z/, crumbs.first["timestamp"])
  end

  def test_request_from_scope_hash
    GoodSorcery.scope.request = {
      url: "https://shop.dev/checkout?token=abc", method: "POST", params: { card_token: "x", coupon: "FALL" },
      headers: { "Accept" => "text/html" }, ignored: "dropped"
    }
    request = build["request"]

    assert_equal "https://shop.dev/checkout?token=[FILTERED]", request["url"]
    assert_equal({ "card_token" => "[FILTERED]", "coupon" => "FALL" }, request["params"])
    refute request.key?("ignored")
  end

  def test_request_extracted_lazily_from_request_env
    extractor = Object.new
    def extractor.extract(env) = { "method" => env["REQUEST_METHOD"] }
    GoodSorcery.configure { |config| config.request_extractor = extractor }
    GoodSorcery.scope.request_env = { "REQUEST_METHOD" => "GET" }

    assert_equal({ "method" => "GET" }, build["request"])
  end

  private

  def nested_error(levels)
    raise "level 0"
  rescue RuntimeError => e
    raise_nested(e, 1, levels)
  end

  def raise_nested(error, level, levels)
    return error if level > levels

    begin
      raise "level #{level}"
    rescue RuntimeError => e
      raise_nested(e, level + 1, levels)
    end
  rescue RuntimeError
    error
  end
end
