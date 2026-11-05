# frozen_string_literal: true

require "test_helper"
require "sidekiq"
require "goodsorcery/integrations/sidekiq"

class SidekiqPerformanceTest < Minitest::Test
  class JobError < StandardError; end

  class ChargeWorker
    include Sidekiq::Job
  end

  def setup
    super
    start_performance
  end

  def middleware = GoodSorcery::Integrations::Sidekiq::ServerMiddleware.new

  def job_hash(overrides = {})
    { "class" => "SidekiqPerformanceTest::ChargeWorker", "jid" => "b4a577edbccf1d805744efa9", "queue" => "critical",
      "args" => [1], "enqueued_at" => Time.now.to_f - 2.5 }.merge(overrides)
  end

  def run_job(job = job_hash, &work)
    work ||= -> { :ok }
    middleware.call(ChargeWorker.new, job, job["queue"], &work)
  end

  def test_a_job_is_recorded_with_adapter_queue_and_queue_wait
    run_job
    transactions = metrics_transactions
    transaction = transactions.first

    assert_equal 1, transactions.size
    trace = recorded_traces.first

    assert_equal %w[job SidekiqPerformanceTest::ChargeWorker sidekiq critical],
                 transaction.values_at("kind", "name", "adapter", "queue")
    assert_equal "test/integrations/sidekiq_performance_test.rb", transaction["source"]
    assert_in_delta 2_500, transaction["queue_wait_ms"], 200
    assert_equal [[22, 1]], transaction["queue_wait"]
    assert_equal({ "adapter" => "sidekiq", "queue" => "critical", "executions" => 1 },
                 trace["job"].except("queue_wait_ms"))
  end

  def test_sidekiq_8_millisecond_timestamps
    run_job(job_hash("enqueued_at" => ((Time.now.to_f - 1.2) * 1000).to_i, "retry_count" => 0))

    assert_in_delta 1_200, metrics_transactions.first["queue_wait_ms"], 200
    assert_equal 2, recorded_traces.first["job"]["executions"]
  end

  def test_a_job_without_an_enqueue_time_has_no_wait
    run_job(job_hash.except("enqueued_at"))

    refute metrics_transactions.first.key?("queue_wait_ms")
  end

  def test_a_raised_job_counts_as_failed_and_is_reraised
    assert_raises(JobError) { run_job { raise JobError, "declined" } }
    run_job

    transaction = metrics_transactions.first

    assert_equal [2, 1], transaction.values_at("count", "failed")
    assert_equal GoodSorcery.test_events.first["event_id"], recorded_traces.first["error_event_id"]
  end

  # What the Active Job layer sees: a job whose enqueued_at is the first
  # enqueue, an hour ago.
  class RetriedActiveJob
    def self.name = "RetriedActiveJob"
    def queue_name = "default"
    def enqueued_at = Time.now - 3_600
    def scheduled_at = nil
    def executions = 1
  end

  def run_wrapped_job(job)
    run_job(job) do
      Performance.measure_job(Performance::ActiveJobTiming.new(RetriedActiveJob.new)) { :ok }
    end
  end

  # Sidekiq retried the Active Job: its own enqueued_at is the requeue.
  def test_a_retried_active_job_waits_from_its_requeue
    run_wrapped_job(job_hash("wrapped" => "RetriedActiveJob", "retry_count" => 0, "enqueued_at" => Time.now.to_f - 1.5))

    assert_in_delta 1_500, metrics_transactions.first["queue_wait_ms"], 200
    assert_nil Thread.current[Performance::ActiveJobTiming::REQUEUED_AT_KEY]
  end

  def test_a_first_run_active_job_waits_from_its_own_enqueue
    run_wrapped_job(job_hash("wrapped" => "RetriedActiveJob", "enqueued_at" => Time.now.to_f - 1.5))

    assert_in_delta 3_600_000, metrics_transactions.first["queue_wait_ms"], 2_000
  end

  def test_jobs_wrapped_by_active_job_are_left_to_the_active_job_layer
    run_job(job_hash("wrapped" => "SomeJob"))

    assert_empty metrics_transactions
  end

  def test_nothing_is_recorded_while_off
    GoodSorcery.reset!
    GoodSorcery.configure { |config| config.delivery = :test }

    assert_equal :ok, run_job
    refute Performance.recording?
    assert_empty metrics_transactions
  end
end
