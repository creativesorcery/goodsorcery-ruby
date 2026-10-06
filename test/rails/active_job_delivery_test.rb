# frozen_string_literal: true

require_relative "support/rails_app"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

class ActiveJobDeliveryTest < Minitest::Test
  include ActiveJob::TestHelper

  def setup
    super
    @server = FakeServer.new
    GoodSorcery.configure do |config|
      config.delivery = :active_job
      config.active_job_queue = "errors"
      config.environment = "production"
      config.api_key = "gs_live_9f2c41aa77d0e81a"
      config.endpoint = @server.endpoint
      config.flush_interval = 0.01
    end
    clear_enqueued_jobs
    GoodSorcery.log.forget(:active_job_fallback)
    GoodSorcery::Delivery::DeliveryJobLoader.job_class
  end

  def teardown
    @server.stop
    super
  end

  def test_enqueues_the_filtered_event_as_a_json_string
    secret = %w[hunter 2].join
    id = GoodSorcery.notify(raise_and_rescue, context: { password: secret })
    job = enqueued_jobs.first

    assert_equal "GoodSorcery::DeliveryJob", job[:job].name
    assert_equal "errors", job[:queue]
    payload = JSON.parse(job[:args].first)
    assert_equal id, payload["event_id"]
    assert_equal "[FILTERED]", payload["context"]["password"]
    refute_includes job[:args].first, secret
  end

  def test_the_event_never_reaches_the_active_job_log
    log = StringIO.new
    ActiveJob::Base.logger = Logger.new(log)
    GoodSorcery.notify(RuntimeError.new("card 4242 for mara@example.com"))
    perform_enqueued_jobs

    assert_includes log.string, "GoodSorcery::DeliveryJob"
    refute_includes log.string, "mara@example.com"
  ensure
    ActiveJob::Base.logger = Logger.new(nil)
  end

  def test_job_sends_the_event_synchronously
    GoodSorcery.notify(raise_and_rescue)
    perform_enqueued_jobs

    assert_equal ["/api/v1/events"], @server.requests.map(&:path)
  end

  def test_job_retries_server_errors
    @server.handler = ->(_request) { [503, {}, "{}"] }
    GoodSorcery::DeliveryJob.perform_now(JSON.generate("event_id" => SecureRandom.uuid))

    assert_equal 1, enqueued_jobs.size
    assert_equal "GoodSorcery::DeliveryJob", enqueued_jobs.first[:job].name
  end

  def test_errors_raised_by_the_job_are_never_reported
    GoodSorcery.client.transport.define_singleton_method(:post_event) { |_json| raise ArgumentError, "boom" }
    error = assert_raises(ArgumentError) { GoodSorcery::DeliveryJob.new("{}").perform("{}") }

    assert_nil GoodSorcery.notify(error)
  end

  def test_falls_back_to_the_background_thread_when_enqueueing_fails
    GoodSorcery::DeliveryJob.define_singleton_method(:set) { |**| raise IOError, "redis down" }
    id = GoodSorcery.notify(raise_and_rescue)

    assert GoodSorcery.flush(2)
    assert_equal ["/api/v1/events/batch"], @server.requests.map(&:path)
    assert_equal id, @server.requests.first.json["events"].first["event_id"]
    assert_includes log_output, "enqueueing GoodSorcery::DeliveryJob failed (IOError)"
  ensure
    GoodSorcery::DeliveryJob.singleton_class.send(:remove_method, :set)
  end

  # Rails returns false instead of raising when a callback aborts the
  # enqueue or the adapter raises ActiveJob::EnqueueError.
  def test_falls_back_to_the_background_thread_when_enqueueing_is_refused
    refused = Struct.new(:queue) { def perform_later(_json) = false }
    GoodSorcery::DeliveryJob.define_singleton_method(:set) { |queue:| refused.new(queue) }
    id = GoodSorcery.notify(raise_and_rescue)

    assert GoodSorcery.flush(2)
    assert_equal id, @server.requests.first.json["events"].first["event_id"]
    assert_includes log_output, "GoodSorcery::DeliveryJob was not enqueued"
  ensure
    GoodSorcery::DeliveryJob.singleton_class.send(:remove_method, :set)
  end
end
