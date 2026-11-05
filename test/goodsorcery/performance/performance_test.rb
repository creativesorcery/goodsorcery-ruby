# frozen_string_literal: true

require "test_helper"

class PerformanceSettingsTest < Minitest::Test
  def test_off_by_default
    config = GoodSorcery::Configuration.new

    refute config.performance_monitoring
    assert config.performance_traces
    assert_equal ["Rails::HealthController#show"], config.performance_ignore_transactions
  end

  def test_the_environment_variable_turns_it_on_unless_set_in_code
    with_env("GOODSORCERY_PERFORMANCE_MONITORING" => "1") do
      config = GoodSorcery::Configuration.new

      assert config.performance_monitoring
      config.performance_monitoring = false
      refute config.performance_monitoring
    end
  end

  def test_invalid_values_are_refused
    config = GoodSorcery::Configuration.new

    assert_raises(ArgumentError) { config.performance_monitoring = "yes" }
    assert_raises(ArgumentError) { config.performance_traces = nil }
  end
end

class PerformanceGateTest < Minitest::Test
  def test_install_does_nothing_while_performance_monitoring_is_off
    GoodSorcery.configure do |config|
      config.enabled = true
      config.api_key = "gs_test_key"
    end

    refute Performance.install
    refute Performance.active?
  end

  def test_disabled_environments_record_nothing
    GoodSorcery.configure do |config|
      config.performance_monitoring = true
      config.api_key = "gs_test_key"
      config.environment = "development"
    end

    refute Performance.install
    refute Performance.active?
  end

  def test_a_missing_api_key_records_nothing
    GoodSorcery.configure do |config|
      config.performance_monitoring = true
      config.enabled = true
    end

    refute Performance.install
  end

  def test_a_custom_delivery_records_nothing
    delivery = Object.new
    def delivery.deliver(_event) = true
    GoodSorcery.configure do |config|
      config.performance_monitoring = true
      config.delivery = delivery
    end

    refute Performance.install
    assert_includes log_output, "performance monitoring needs the :async, :sync or :active_job delivery"
  end

  def test_an_enabled_environment_with_a_key_records
    GoodSorcery.configure do |config|
      config.performance_monitoring = true
      config.enabled = true
      config.api_key = "gs_test_key"
    end

    assert Performance.install
    assert Performance.active?
  end

  def test_while_off_a_request_creates_no_recorder_and_no_thread
    app = ->(_env) { [Performance.recording? ? 500 : 200, {}, []] }
    status, = GoodSorcery::Rack::Middleware.new(app).call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/" })

    assert_equal 200, status
    refute(Thread.list.any? { |thread| thread.name == "goodsorcery-apm" })
  end
end

class PerformanceRecordingTest < Minitest::Test
  def setup
    super
    start_performance
  end

  def call(app, env = {})
    GoodSorcery::Rack::Middleware.new(app).call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/products/42" }.merge(env))
  end

  def named(name = "ProductsController#show")
    Performance.current_recorder.name = name
  end

  def test_a_request_is_recorded_as_a_web_transaction
    call(lambda do |_env|
      named
      [200, {}, []]
    end)
    transaction = metrics_transactions.first

    assert_equal %w[web ProductsController#show GET], transaction.values_at("kind", "name", "method")
    assert_equal [1, 0], transaction.values_at("count", "failed")
    assert_equal "/products/42", recorded_traces.first["request"]["path"]
  end

  def test_a_5xx_response_counts_as_failed
    call(lambda do |_env|
      named
      [503, {}, []]
    end)

    assert_equal 1, metrics_transactions.first["failed"]
    assert_equal 503, recorded_traces.first["status"]
  end

  def test_an_exception_is_reraised_counted_failed_and_linked_to_its_error_event
    error = assert_raises(RuntimeError) do
      call(lambda do |_env|
        named
        raise "boom"
      end)
    end
    trace = recorded_traces.first

    assert_equal "boom", error.message
    assert_equal 1, metrics_transactions.first["failed"]
    assert_equal [500, true], trace.values_at("status", "failed")
    assert_equal GoodSorcery.test_events.first["event_id"], trace["error_event_id"]
  end

  def test_the_first_reported_error_is_the_one_linked
    call(lambda do |_env|
      named
      @first = GoodSorcery.notify(RuntimeError.new("first"))
      GoodSorcery.notify(RuntimeError.new("second"))
      [200, {}, []]
    end)

    assert_equal @first, recorded_traces.first["error_event_id"]
  end

  def test_requests_that_never_get_a_name_are_not_recorded
    call(->(_env) { [404, {}, []] })

    assert_empty metrics_transactions
    assert_empty recorded_traces
  end

  def test_ignored_transactions_are_not_recorded
    GoodSorcery.configuration.performance_ignore_transactions += ["HealthController#show", /\AAdmin::/]
    Performance.install
    ["HealthController#show", "Admin::UsersController#index", "GoodSorcery::DeliveryJob", "Kept#show"].each do |name|
      call(lambda do |_env|
        named(name)
        [200, {}, []]
      end)
    end

    assert_equal(["Kept#show"], metrics_transactions.map { |transaction| transaction["name"] })
  end

  def test_a_unit_of_work_inside_another_is_part_of_the_outer_one
    call(lambda do |_env|
      named
      Performance.measure_job(Performance::SidekiqTiming.new({ "class" => "InlineJob" }, "default", nil)) { :ran }
      [200, {}, []]
    end)

    assert_equal(["ProductsController#show"], metrics_transactions.map { |transaction| transaction["name"] })
  end

  def test_without_traces_only_metrics_are_sent
    start_performance(performance_traces: false)
    call(lambda do |_env|
      named
      [200, {}, []]
    end)

    assert_equal 1, metrics_transactions.size
    assert_empty recorded_traces
  end

  def test_the_test_delivery_keeps_payloads_until_cleared
    call(lambda do |_env|
      named
      [200, {}, []]
    end)
    GoodSorcery.flush_performance

    assert_equal(%w[/api/v1/apm/metrics /api/v1/apm/traces],
                 GoodSorcery.test_performance_payloads.map { |payload| payload["path"] })
    GoodSorcery.clear_test_events
    assert_empty GoodSorcery.test_performance_payloads
  end

  def test_no_thread_starts_with_the_test_delivery
    call(lambda do |_env|
      named
      [200, {}, []]
    end)

    refute Performance.agent.flusher.running?
  end

  def test_a_failing_subscriber_stops_recording_that_unit_of_work_only
    call(lambda do |_env|
      named("Broken#show")
      Performance.with_recorder { raise ArgumentError, "subscriber bug" }
      [200, {}, []]
    end)
    call(lambda do |_env|
      named("Fine#show")
      [200, {}, []]
    end)

    assert_equal(["Fine#show"], metrics_transactions.map { |transaction| transaction["name"] })
    assert_includes log_output, "performance recording failed (ArgumentError)"
  end

  def test_a_failure_while_recording_never_reaches_the_app
    Performance.agent.aggregator.define_singleton_method(:record) { |*| raise "aggregator bug" }
    status, = call(lambda do |_env|
      named
      [200, {}, []]
    end)

    assert_equal 200, status
    assert_includes log_output, "could not record performance data (RuntimeError)"
  end

  def test_job_label_failures_never_reach_the_job
    timing = Performance::SidekiqTiming.new({ "class" => "X" }, "q", nil)
    timing.define_singleton_method(:name) { raise "label bug" }

    assert_equal :done, Performance.measure_job(timing) { :done }
    assert_empty metrics_transactions
  end
end
