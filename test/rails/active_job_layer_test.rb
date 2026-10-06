# frozen_string_literal: true

require_relative "support/rails_app"

class ActiveJobLayerTest < Minitest::Test
  include ActiveJob::TestHelper

  class ChargeError < StandardError; end
  class MailerError < StandardError; end

  class ChargeCustomerJob < ActiveJob::Base
    queue_as :billing

    def perform(_customer, _options)
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "UPDATE customers", name: "Customer Update")
      raise ChargeError, "card declined"
    end
  end

  class RetriedJob < ActiveJob::Base
    retry_on ChargeError, attempts: 2, wait: 0

    def perform = raise(ChargeError, "still failing")
  end

  class PrivateJob < ActiveJob::Base
    goodsorcery_arguments false

    def perform(_secret) = raise(ChargeError, "private")
  end

  class PrivateChildJob < PrivateJob; end

  class UserMailer < ActionMailer::Base
    default from: "app@example.com"

    def welcome(_customer, reset_token:)
      raise MailerError, "template missing for #{reset_token.length} chars"
    end
  end

  def setup
    super
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.filter_params += ["customer_ref"]
    end
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def events = GoodSorcery.test_events

  def run_jobs(error_class = ChargeError)
    assert_raises(error_class) { perform_enqueued_jobs }
  end

  def charge_options
    { "card_token" => "tok_123", "amount" => 5, "customer_ref" => 7, "nested" => { "password" => "x" },
      "at" => Time.utc(2026, 10, 6, 9, 30) }
  end

  def test_a_failing_job_is_reported_once_with_the_job_section
    ChargeCustomerJob.perform_later(GoodSorceryTestApp::Customer.new(88_123), charge_options)
    run_jobs
    event = events.first
    job = event["job"]

    assert_equal 1, events.size
    assert_equal "ActiveJobLayerTest::ChargeCustomerJob", event["transaction"]
    assert_equal "billing", event["tags"]["queue"]
    assert_equal "active_job", job["framework"]
    assert_equal "ActiveJobLayerTest::ChargeCustomerJob", job["class"]
    assert_match(/\A\h{8}-/, job["id"])
    assert_equal "billing", job["queue"]
    assert_equal 1, job["executions"]
    assert_match(/\A\d{4}-\d\d-\d\dT/, job["enqueued_at"])
  end

  def test_job_arguments_are_serialised_and_filtered
    ChargeCustomerJob.perform_later(GoodSorceryTestApp::Customer.new(88_123), charge_options)
    run_jobs
    customer, options = events.first["job"]["arguments"]

    assert_match %r{\Agid://[^/]+/GoodSorceryTestApp::Customer/88123\z}, customer
    assert_equal({ "card_token" => "[FILTERED]", "amount" => 5, "customer_ref" => "[FILTERED]",
                   "nested" => { "password" => "[FILTERED]" }, "at" => "2026-10-06T09:30:00Z" }, options)
  end

  def test_breadcrumbs_are_recorded_inside_the_job_scope
    ChargeCustomerJob.perform_later(GoodSorceryTestApp::Customer.new(1), {})
    run_jobs

    sql, job = events.first["breadcrumbs"]

    assert_match(/\ACustomer Update \(/, sql["message"])
    assert_equal "ActiveJobLayerTest::ChargeCustomerJob failed (ActiveJobLayerTest::ChargeError)", job["message"]
    assert_equal %w[job error], [job["category"], job["level"]]
  end

  def test_jobs_retried_by_retry_on_are_reported_only_when_they_finally_fail
    RetriedJob.perform_later
    perform_enqueued_jobs

    assert_empty events
    run_jobs

    assert_equal 1, events.size
    assert_equal 2, events.first["job"]["executions"]
  end

  def test_arguments_can_be_turned_off_globally
    GoodSorcery.configure { |config| config.send_job_arguments = false }
    ChargeCustomerJob.perform_later(GoodSorceryTestApp::Customer.new(1), {})
    run_jobs

    refute events.first["job"].key?("arguments")
  end

  def test_the_class_macro_turns_arguments_off_and_is_inherited
    PrivateJob.perform_later("s3cr3t")
    PrivateChildJob.perform_later("s3cr3t")
    run_jobs
    run_jobs

    assert_equal 2, events.size
    events.each { |event| refute event["job"].key?("arguments") }
    refute_includes JSON.generate(events), "s3cr3t"
  end

  def test_mailer_deliver_later_is_named_after_the_mailer_action
    UserMailer.with(account_password: "pw").welcome(GoodSorceryTestApp::Customer.new(5),
                                                    reset_token: "abc").deliver_later
    run_jobs(MailerError)
    event = events.first
    job = event["job"]

    assert_equal 1, events.size
    assert_equal "ActiveJobLayerTest::UserMailer#welcome", event["transaction"]
    assert_equal "ActionMailer::MailDeliveryJob", job["class"]
    assert_equal "ActiveJobLayerTest::UserMailer", job["mailer"]
    assert_equal "welcome", job["action"]
    assert_equal({ "account_password" => "[FILTERED]" }, job["arguments"]["params"])
    customer, kwargs = job["arguments"]["args"]
    assert_match(%r{Customer/5\z}, customer)
    assert_equal({ "reset_token" => "[FILTERED]" }, kwargs)
  end

  def test_scope_is_cleared_after_each_job
    ChargeCustomerJob.perform_later(GoodSorceryTestApp::Customer.new(1), {})
    run_jobs

    assert_nil Thread.current[GoodSorcery::Scope::STORAGE_KEY]
  end
end
