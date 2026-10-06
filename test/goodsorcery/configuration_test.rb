# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def config
    @config ||= GoodSorcery::Configuration.new
  end

  def test_defaults_match_the_design
    assert_equal :async, config.delivery
    assert_equal 25, config.batch_size
    assert_in_delta 2.0, config.flush_interval
    assert_equal 1_000, config.max_queue_size
    assert_equal 5, config.shutdown_timeout
    assert_equal 3, config.max_retries
    assert_equal 2, config.open_timeout
    assert_equal 5, config.read_timeout
    assert_equal %w[development test], config.disabled_environments
    assert_nil config.enabled_environments
    assert_equal :mask, config.filter_mode
    assert_equal GoodSorcery::Defaults::FILTER_PARAMS, config.filter_params
    assert_equal :verify, config.install_check
    assert_equal 40, config.max_breadcrumbs
    assert_equal "default", config.active_job_queue
    assert_equal "https://errors.goodsorcery.dev", config.endpoint
  end

  def test_default_lists_are_copies
    config.filter_params += [:card_token]
    config.ignore_exceptions -= ["SystemExit"]

    refute_includes GoodSorcery::Defaults::FILTER_PARAMS, :card_token
    assert_includes GoodSorcery::Defaults::IGNORE_EXCEPTIONS, "SystemExit"
  end

  def test_reads_credentials_and_endpoint_from_env
    with_env("GOODSORCERY_API_KEY" => "gs_test_abc", "GOODSORCERY_ENDPOINT" => "http://localhost:3000/") do
      assert_equal "gs_test_abc", config.api_key
      assert_equal "http://localhost:3000", config.endpoint
    end
  end

  def test_explicit_settings_win_over_env
    with_env("GOODSORCERY_API_KEY" => "gs_test_env", "GOODSORCERY_ENV" => "staging") do
      config.api_key = "gs_live_explicit"
      config.environment = "production"

      assert_equal "gs_live_explicit", config.api_key
      assert_equal "production", config.environment
    end
  end

  def test_environment_lookup_order
    assert_equal "development", config.environment
    with_env("APP_ENV" => "app") { assert_equal "app", config.environment }
    with_env("APP_ENV" => "app", "RACK_ENV" => "rack") { assert_equal "rack", config.environment }
    with_env("RACK_ENV" => "rack", "GOODSORCERY_ENV" => "gs") { assert_equal "gs", config.environment }
  end

  def test_enabled_reads_env_flag
    assert_nil config.enabled
    with_env("GOODSORCERY_ENABLED" => "1") { assert config.enabled }
    with_env("GOODSORCERY_ENABLED" => "false") { refute config.enabled }
    config.enabled = true
    with_env("GOODSORCERY_ENABLED" => "0") { assert config.enabled }
  end

  def test_masked_api_key_never_shows_the_whole_key
    config.api_key = "gs_test_9f2c41aa77d0e81a"

    assert_equal "gs_test_…e81a", config.masked_api_key
    assert_equal "…", GoodSorcery::MaskedKey.new("short").to_s
    assert_equal "(not set)", GoodSorcery::MaskedKey.new(nil).to_s
  end

  def test_inspect_and_pp_never_show_the_api_key
    require "pp"
    GoodSorcery.configure do |c|
      c.api_key = "gs_live_9f2c41aa77d0e81a"
      c.endpoint = "http://127.0.0.1:9"
    end
    client = GoodSorcery.client
    client.delivery
    client.transport
    shown = [GoodSorcery.configuration.inspect, client.inspect, client.transport.inspect,
             client.delivery.inspect, PP.pp(client, +"")]

    shown.each { |text| refute_includes text, "9f2c41aa77d0" }
    assert_includes GoodSorcery.configuration.inspect, "api_key=gs_live_…e81a"
  end

  def test_rejects_endpoints_that_are_not_http_urls_without_echoing_them
    ["errors.example.com", "ftp://errors.example.com", "https://"].each do |value|
      assert_raises(ArgumentError) { config.endpoint = value }
    end
    error = assert_raises(ArgumentError) { config.endpoint = "https://user:s3cr3t@errors.example.com" }
    refute_includes error.message, "s3cr3t"
    config.endpoint = "https://errors.example.com/tracker/"
    assert_equal "https://errors.example.com/tracker", config.endpoint
  end

  def test_endpoint_label_hides_credentials_from_the_environment
    with_env("GOODSORCERY_ENDPOINT" => "https://user:s3cr3t@errors.example.com") do
      assert_equal "https://errors.example.com", config.endpoint_label
      refute_includes config.inspect, "s3cr3t"
    end
  end

  def test_rejects_unknown_delivery
    error = assert_raises(ArgumentError) { config.delivery = :carrier_pigeon }
    assert_match(/delivery must be one of :async, :sync, :active_job, :test/, error.message)

    holder = Struct.new(:api_key).new("gs_live_9f2c41aa77d0e81a")
    error = assert_raises(ArgumentError) { config.delivery = holder }
    refute_includes error.message, "9f2c41aa77d0"
  end

  def test_accepts_delivery_strings_and_custom_objects
    config.delivery = "sync"
    assert_equal :sync, config.delivery

    custom = Object.new
    def custom.deliver(_event) = true
    config.delivery = custom
    assert_same custom, config.delivery
  end

  def test_rejects_batch_size_outside_server_limit
    assert_raises(ArgumentError) { config.batch_size = 0 }
    error = assert_raises(ArgumentError) { config.batch_size = 101 }
    assert_match(/batch_size must be an Integer in 1..100/, error.message)
    config.batch_size = 100
    assert_equal 100, config.batch_size
  end

  def test_rejects_invalid_numbers_and_choices
    assert_raises(ArgumentError) { config.flush_interval = 0 }
    assert_raises(ArgumentError) { config.max_queue_size = -1 }
    assert_raises(ArgumentError) { config.filter_mode = :shred }
    assert_raises(ArgumentError) { config.install_check = :sometimes }
    assert_raises(ArgumentError) { config.before_send = "not callable" }
    assert_raises(ArgumentError) { config.enabled = "yes" }
    assert_raises(ArgumentError) { config.max_breadcrumbs = 101 }
  end

  def test_choice_settings_accept_strings
    config.filter_mode = "remove"
    config.install_check = false

    assert_equal :remove, config.filter_mode
    refute config.install_check
  end

  def test_configure_rebuilds_delivery_only_when_delivery_settings_change
    GoodSorcery.configure { |c| c.delivery = :test }
    first = GoodSorcery.client.delivery

    GoodSorcery.configure { |c| c.tags = { region: "eu" } }
    assert_same first, GoodSorcery.client.delivery

    GoodSorcery.configure { |c| c.delivery = :sync }
    assert_instance_of GoodSorcery::Delivery::Sync, GoodSorcery.client.delivery
  end

  def test_configure_shuts_down_the_replaced_delivery
    custom = Class.new do
      attr_reader :shut_down

      def deliver(_event) = true
      def shutdown(_timeout) = (@shut_down = true)
    end.new
    GoodSorcery.configure { |c| c.delivery = custom }
    GoodSorcery.client.delivery

    GoodSorcery.configure { |c| c.batch_size = 10 }

    assert custom.shut_down
  end

  def test_replaced_transport_closes_after_the_delivery_drains_and_outside_the_lock
    GoodSorcery.configure do |c|
      c.api_key = "gs_test_9f2c41aa77d0e81a"
      c.endpoint = "http://127.0.0.1:9"
    end
    client = GoodSorcery.client
    lock = client.instance_variable_get(:@lock)
    steps = []
    client.delivery.define_singleton_method(:shutdown) { |_timeout| steps << [:shutdown, lock.mon_locked?] }
    client.transport.define_singleton_method(:close) { steps << [:close, lock.mon_locked?] }
    GoodSorcery.configure { |c| c.api_key = "gs_test_0000000000000000" }

    assert_equal [[:shutdown, false], [:close, false]], steps
  end
end

class ReleaseDetectorTest < Minitest::Test
  def test_explicit_release_wins_and_is_truncated
    config = GoodSorcery::Configuration.new
    config.release = "x" * 80

    assert_equal "x" * 64, config.release
  end

  def test_env_variables_in_order
    with_env("GIT_SHA" => "sha", "HEROKU_SLUG_COMMIT" => "heroku") do
      assert_equal "heroku", GoodSorcery::ReleaseDetector.new(nil).release
    end
    with_env("GOODSORCERY_RELEASE" => "gs", "KAMAL_VERSION" => "kamal") do
      assert_equal "gs", GoodSorcery::ReleaseDetector.new(nil).release
    end
  end

  def test_capistrano_revision_file
    Dir.mktmpdir do |root|
      File.write(File.join(root, "REVISION"), "abc123\n")

      assert_equal "abc123", GoodSorcery::ReleaseDetector.new(root).release
    end
  end

  def test_nil_without_any_source
    Dir.mktmpdir { |root| assert_nil GoodSorcery::ReleaseDetector.new(root).release }
  end
end

class EnvironmentGateTest < Minitest::Test
  def gate(**settings)
    config = GoodSorcery::Configuration.new
    settings.each { |name, value| config.public_send(:"#{name}=", value) }
    GoodSorcery::EnvironmentGate.new(config)
  end

  def test_development_and_test_are_disabled_by_default
    refute_predicate gate(environment: "development"), :enabled?
    refute_predicate gate(environment: "test"), :enabled?
    assert_predicate gate(environment: "production"), :enabled?
  end

  def test_explicit_enabled_wins
    assert_predicate gate(environment: "development", enabled: true), :enabled?
    refute_predicate gate(environment: "production", enabled: false), :enabled?
    with_env("GOODSORCERY_ENABLED" => "0") { refute_predicate gate(environment: "production"), :enabled? }
  end

  def test_allow_list
    assert_predicate gate(environment: "staging", enabled_environments: %w[staging production]), :enabled?
    refute_predicate gate(environment: "review", enabled_environments: %w[staging production]), :enabled?
  end

  def test_reason_explains_the_decision
    assert_equal 'environment "development" is in disabled_environments', gate(environment: "development").reason
    assert_equal "config.enabled (or GOODSORCERY_ENABLED) is false", gate(enabled: false).reason
  end
end
