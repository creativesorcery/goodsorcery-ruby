# frozen_string_literal: true

require_relative "support/rails_app"
require "rack/mock_request"
require "open3"
require "rbconfig"

class RailsPerformanceTest < Minitest::Test
  include ActiveJob::TestHelper

  class DeclinedError < StandardError; end

  class ChargeJob < ActiveJob::Base
    queue_as :payments

    def perform(fail_with = nil)
      raise DeclinedError, "declined" if fail_with
    end
  end

  class RetriedChargeJob < ActiveJob::Base
    retry_on DeclinedError, attempts: 2, wait: 0

    def perform = raise(DeclinedError, "still declined")
  end

  def setup
    super
    start_performance
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def get(path)
    Rack::MockRequest.new(Rails.application).get(path, "HTTP_X_REQUEST_ID" => "req-77")
  end

  def transaction(name)
    metrics_transactions.find { |each_transaction| each_transaction["name"] == name }
  end

  def trace(name)
    recorded_traces.find { |each_trace| each_trace["name"] == name }
  end

  def test_a_request_records_name_method_route_status_and_layers
    assert_equal 200, get("/perf/products/42?token=abc").status
    metrics = transaction("PerfController#show")
    trace = trace("PerfController#show")

    assert_equal %w[web GET /perf/products/:id test/rails/support/rails_app.rb],
                 metrics.values_at("kind", "method", "route", "source")
    assert_equal [1, 0], metrics.values_at("count", "failed")
    assert_equal 200, trace["status"]
    assert_equal({ "method" => "GET", "path" => "/perf/products/42", "request_id" => "req-77" }, trace["request"])
    assert_equal 2, trace["sql_count"]
    assert_operator trace["db_ms"], :>, 0
    assert_operator trace["view_ms"], :>, 0
    assert_in_delta trace["duration_ms"], trace.values_at("db_ms", "http_ms", "view_ms", "ruby_ms").sum, 0.01
  end

  def test_the_trace_groups_repeated_queries_with_their_call_site_and_lists_views
    get("/perf/products/42")
    spans = trace("PerfController#show")["spans"]
    query = spans.find { |span| span["type"] == "sql" }

    assert_equal ["SELECT * FROM products WHERE id = ?", 2, 2], query.values_at("sql", "count", "rows")
    assert_equal "test/rails/support/rails_app.rb", query["call_site"]["file"]
    assert_equal "product_query", query["call_site"]["method"]
    assert_includes query["call_site"]["context"]["lines"].join("\n"), "Product Load"
    templates = spans.select { |span| span["type"] == "view" }.map { |span| span["template"] }

    assert_includes templates, "perf/show.html.erb"
    assert(templates.any? { |template| template.start_with?("perf/_row") })
  end

  # The controller's view_runtime would count the template's query again
  # (Active Record takes it out only when its logger is at info).
  def test_a_query_run_from_a_template_is_database_time_not_view_time
    get("/perf/view_query")
    trace = trace("PerfController#view_query")

    assert_operator trace["db_ms"], :>=, 40
    assert_operator trace["view_ms"], :<, 40
    assert_in_delta trace["duration_ms"], trace.values_at("db_ms", "http_ms", "view_ms", "ruby_ms").sum, 0.01
  end

  def test_sql_is_normalised_in_the_dialect_of_its_connection
    get("/perf/files")
    query = trace("PerfController#files")["spans"].find { |span| span["type"] == "sql" }

    assert_equal "SELECT * FROM files WHERE dir = ? AND token = ?", query["sql"]
  end

  def test_a_raised_request_is_failed_with_status_500_and_links_its_error_event
    assert_equal 500, get("/perf/boom").status
    trace = trace("PerfController#boom")

    assert_equal 1, transaction("PerfController#boom")["failed"]
    assert_equal [500, true], trace.values_at("status", "failed")
    assert_equal GoodSorcery.test_events.first["event_id"], trace["error_event_id"]
  end

  def test_a_5xx_response_is_failed
    get("/perf/unavailable")

    assert_equal 1, transaction("PerfController#unavailable")["failed"]
  end

  def test_routing_404s_and_ignored_transactions_are_not_recorded
    assert_equal 404, get("/no/such/page").status
    assert_equal 200, get("/up").status

    assert_empty metrics_transactions
  end

  def test_an_active_job_records_adapter_queue_and_queue_wait
    perform_enqueued_jobs { ChargeJob.perform_later }
    metrics = transaction("RailsPerformanceTest::ChargeJob")
    trace = trace("RailsPerformanceTest::ChargeJob")

    assert_equal %w[job test payments], metrics.values_at("kind", "adapter", "queue")
    assert_equal "test/rails/performance_test.rb", metrics["source"]
    assert_operator metrics["queue_wait_ms"], :<, 1_000
    assert_equal({ "adapter" => "test", "queue" => "payments", "executions" => 1 },
                 trace["job"].except("queue_wait_ms"))
  end

  def test_a_scheduled_job_waits_from_its_scheduled_time
    perform_enqueued_jobs { ChargeJob.set(wait_until: Time.now - 3).perform_later }

    assert_in_delta 3_000, transaction("RailsPerformanceTest::ChargeJob")["queue_wait_ms"], 500
  end

  def test_a_raised_job_counts_as_failed
    assert_raises(DeclinedError) { ChargeJob.perform_now(true) }

    assert_equal [1, 1], transaction("RailsPerformanceTest::ChargeJob").values_at("count", "failed")
  end

  def test_each_failed_attempt_counts_even_when_retry_on_handles_it
    RetriedChargeJob.perform_later
    perform_enqueued_jobs
    assert_raises(DeclinedError) { perform_enqueued_jobs }

    assert_equal [2, 2], transaction("RailsPerformanceTest::RetriedChargeJob").values_at("count", "failed")
  end

  def test_a_job_run_inline_in_a_request_is_part_of_the_request
    get("/perf/inline_job")
    names = metrics_transactions.map { |each_transaction| each_transaction["name"] }
    spans = trace("PerfController#inline_job")["spans"]

    assert_equal ["PerfController#inline_job"], names
    assert(spans.any? { |span| span["type"] == "sql" && span["name"] == "T Update" })
    assert_includes(spans, spans.find { |span| span["type"] == "enqueue" })
    assert_equal({ "job" => "GoodSorceryTestApp::PerfJob", "queue" => "billing" },
                 spans.find { |span| span["type"] == "enqueue" }.slice("job", "queue"))
  end

  def test_a_mailer_job_records_its_view_time
    perform_enqueued_jobs { GoodSorceryTestApp::PerfMailer.notice.deliver_later }
    trace = trace("ActionMailer::MailDeliveryJob")

    assert_operator trace["view_ms"], :>, 0
    assert(trace["spans"].any? { |span| span["template"] == "perf_mailer/notice.text.erb" })
  end
end

# Booting the app in a fresh process shows what the Railtie does on its own.
class RailsPerformanceBootTest < Minitest::Test
  SCRIPT = <<~RUBY
    require "rails/support/rails_app"
    require "json"
    state = {
      active: GoodSorcery::Performance.active?,
      subscribed: GoodSorcery::Performance::Subscribers.subscribed?,
      net_http: GoodSorcery::Performance::NetHttp.installed?,
      thread: Thread.list.any? { |thread| thread.name == "goodsorcery-apm" }
    }
    puts "STATE=\#{JSON.generate(state)}"
  RUBY

  def boot(env)
    root = PerformanceHelpers::REPO_ROOT
    output, status = Open3.capture2e(env, RbConfig.ruby, "-I#{root}/lib", "-I#{root}/test", "-e", SCRIPT)
    assert status.success?, output
    JSON.parse(output[/^STATE=(.*)$/, 1])
  end

  def test_off_by_default_nothing_is_subscribed_or_prepended
    state = boot({ "GOODSORCERY_ENABLED" => "1", "GOODSORCERY_API_KEY" => "gs_test_key" })

    assert_equal({ "active" => false, "subscribed" => false, "net_http" => false, "thread" => false }, state)
  end

  def test_turned_on_it_starts_after_initialize_without_a_thread_until_work_is_recorded
    state = boot({ "GOODSORCERY_ENABLED" => "1", "GOODSORCERY_API_KEY" => "gs_test_key",
                   "GOODSORCERY_PERFORMANCE_MONITORING" => "1" })

    assert_equal({ "active" => true, "subscribed" => true, "net_http" => true, "thread" => false }, state)
  end

  def test_a_disabled_environment_stays_off_even_when_turned_on
    state = boot({ "RAILS_ENV" => "test", "GOODSORCERY_API_KEY" => "gs_test_key",
                   "GOODSORCERY_PERFORMANCE_MONITORING" => "1" })

    assert_equal false, state["active"]
  end
end
