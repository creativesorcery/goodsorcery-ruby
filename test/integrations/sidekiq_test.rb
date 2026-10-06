# frozen_string_literal: true

require "test_helper"
require "sidekiq"
require "goodsorcery/integrations/sidekiq"

class SidekiqIntegrationTest < Minitest::Test
  class JobError < StandardError; end

  class HardWorker
    include Sidekiq::Job
  end

  class QuietWorker
    include Sidekiq::Job

    sidekiq_options goodsorcery_arguments: false
  end

  ENQUEUED_AT_MS = Time.utc(2026, 10, 6, 8, 10).to_i * 1000

  def setup
    super
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.filter_params += ["customer_ref"]
    end
  end

  def job_hash(overrides = {})
    { "class" => "SidekiqIntegrationTest::HardWorker", "jid" => "b4a577edbccf1d805744efa9", "queue" => "critical",
      "args" => [{ "api_token" => "t0k", "customer_ref" => 7, "amount" => 5 }, "plain"],
      "retry_count" => 2, "enqueued_at" => ENQUEUED_AT_MS }.merge(overrides)
  end

  def middleware = GoodSorcery::Integrations::Sidekiq::ServerMiddleware.new
  def handler = GoodSorcery::Integrations::Sidekiq::ErrorHandler.new
  def events = GoodSorcery.test_events

  def run_failing(job, worker = HardWorker.new)
    assert_raises(JobError) { middleware.call(worker, job, job["queue"]) { raise JobError, "failed" } }
  end

  def test_reports_a_failing_job_with_the_job_section_and_filtered_args
    run_failing(job_hash)
    event = events.first

    assert_equal 1, events.size
    assert_equal "SidekiqIntegrationTest::HardWorker", event["transaction"]
    assert_equal "critical", event["tags"]["queue"]
    assert_equal({ "framework" => "sidekiq", "class" => "SidekiqIntegrationTest::HardWorker",
                   "id" => "b4a577edbccf1d805744efa9", "queue" => "critical", "retry_count" => 2,
                   "enqueued_at" => "2026-10-06T08:10:00.000Z",
                   "arguments" => [{ "api_token" => "[FILTERED]", "customer_ref" => "[FILTERED]", "amount" => 5 },
                                   "plain"] }, event["job"])
  end

  def test_runs_through_a_real_sidekiq_middleware_chain
    chain = Sidekiq::Middleware::Chain.new(Sidekiq.default_configuration)
    chain.add(GoodSorcery::Integrations::Sidekiq::ServerMiddleware)
    assert_raises(JobError) { chain.invoke(HardWorker.new, job_hash, "critical") { raise JobError } }

    assert_equal "sidekiq", events.first["job"]["framework"]
  end

  def test_error_handler_does_not_report_the_same_exception_twice
    error = run_failing(job_hash)
    handler.call(error, { job: job_hash, context: "Job raised exception" }, Sidekiq.default_configuration)

    assert_equal 1, events.size
  end

  def test_error_handler_reports_what_the_middleware_never_saw
    error = raise_and_rescue(JobError, "fetch failed")
    handler.call(error, { job: job_hash, context: "Job raised exception" })

    assert_equal 1, events.size
    assert_equal "b4a577edbccf1d805744efa9", events.first["job"]["id"]
    assert_equal "SidekiqIntegrationTest::HardWorker", events.first["transaction"]
  end

  def test_arguments_can_be_turned_off_globally_or_per_job_class
    run_failing(job_hash("class" => "SidekiqIntegrationTest::QuietWorker"), QuietWorker.new)
    run_failing(job_hash("goodsorcery_arguments" => false))
    GoodSorcery.configure { |config| config.send_job_arguments = false }
    run_failing(job_hash)

    assert_equal 3, events.size
    events.each { |event| refute event["job"].key?("arguments") }
  end

  def test_leaves_active_job_wrapped_jobs_to_the_active_job_layer
    wrapped = job_hash("wrapped" => "ChargeCustomerJob")
    inside = :unset
    assert_raises(JobError) do
      middleware.call(HardWorker.new, wrapped, "critical") do
        inside = GoodSorcery::Scope.unit_of_work
        raise JobError
      end
    end

    assert_nil inside
    assert_empty events
  end

  def test_install_registers_the_middleware_and_error_handler_for_servers
    config = Sidekiq.default_configuration
    with_sidekiq_server { GoodSorcery::Integrations::Sidekiq.install }

    assert config.server_middleware.exists?(GoodSorcery::Integrations::Sidekiq::ServerMiddleware)
    assert(config.error_handlers.any?(GoodSorcery::Integrations::Sidekiq::ErrorHandler))
  ensure
    config.server_middleware.remove(GoodSorcery::Integrations::Sidekiq::ServerMiddleware)
    config.error_handlers.delete_if { |entry| entry.is_a?(GoodSorcery::Integrations::Sidekiq::ErrorHandler) }
  end

  def with_sidekiq_server
    GoodSorcery::Integrations::Sidekiq.instance_variable_set(:@installed, false)
    Sidekiq.singleton_class.alias_method(:__original_server?, :server?)
    Sidekiq.define_singleton_method(:server?) { true }
    yield
  ensure
    Sidekiq.singleton_class.alias_method(:server?, :__original_server?)
    Sidekiq.singleton_class.remove_method(:__original_server?)
  end
end
