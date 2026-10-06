# frozen_string_literal: true

require "test_helper"

class SyncDeliveryTest < Minitest::Test
  def setup
    super
    @server = FakeServer.new
    GoodSorcery.configure do |config|
      config.delivery = :sync
      config.environment = "production"
      config.api_key = "gs_live_9f2c41aa77d0e81a"
      config.endpoint = @server.endpoint
    end
  end

  def teardown
    @server.stop
    super
  end

  def test_sends_each_event_immediately_to_the_single_endpoint
    id = GoodSorcery.notify(raise_and_rescue(ArgumentError, "now"))
    request = @server.requests.first

    assert_equal "/api/v1/events", request.path
    assert_equal id, request.json["event_id"]
    assert_equal "ArgumentError", request.json["exception"]["class"]
  end

  def test_failures_return_nil_and_are_logged_without_raising
    @server.handler = ->(_request) { [503, {}, "{}"] }

    assert_nil GoodSorcery.notify(raise_and_rescue)
    assert_includes log_output, "could not deliver an event (HTTP 503)"
  end

  def test_concurrent_callers_do_not_share_a_connection
    threads = Array.new(4) { Thread.new { GoodSorcery.notify(raise_and_rescue) } }
    threads.each(&:join)

    assert_equal 4, @server.requests.size
  end
end

class AsyncEndToEndTest < Minitest::Test
  def setup
    super
    @server = FakeServer.new
    GoodSorcery.configure do |config|
      config.environment = "production"
      config.api_key = "gs_live_9f2c41aa77d0e81a"
      config.endpoint = @server.endpoint
      config.flush_interval = 30
    end
  end

  def teardown
    @server.stop
    super
  end

  def test_notify_returns_quickly_and_flush_sends_one_batch
    ids = Array.new(3) { GoodSorcery.notify(raise_and_rescue) }

    assert GoodSorcery.flush(2)
    assert_equal 1, @server.requests.size
    assert_equal "/api/v1/events/batch", @server.requests.first.path
    assert_equal(ids, @server.requests.first.json["events"].map { |event| event["event_id"] })
  end
end

class CustomDeliveryTest < Minitest::Test
  class Collector
    attr_reader :events

    def initialize
      @events = []
    end

    def deliver(event)
      @events << event
    end
  end

  def test_custom_objects_receive_filtered_event_hashes
    collector = Collector.new
    GoodSorcery.configure do |config|
      config.delivery = collector
      config.environment = "production"
    end
    GoodSorcery.notify(raise_and_rescue, context: { token: "t" })

    assert_equal "[FILTERED]", collector.events.first["context"]["token"]
    assert GoodSorcery.flush(1)
    assert GoodSorcery.client.delivery.shutdown(1)
  end

  def test_custom_objects_are_gated_by_environment
    collector = Collector.new
    GoodSorcery.configure do |config|
      config.delivery = collector
      config.environment = "test"
    end
    GoodSorcery.notify(raise_and_rescue)

    assert_empty collector.events
  end
end

class ActiveJobFallbackTest < Minitest::Test
  def test_falls_back_to_the_background_thread_without_active_job
    fallback = GoodSorcery::Delivery::Test.new
    queue = GoodSorcery::Delivery::ActiveJobQueue.new(serializer: GoodSorcery::EventSerializer.new(captured_log),
                                                      queue_name: "default", log: captured_log) { fallback }
    skip "ActiveJob is loaded in this process" if defined?(ActiveJob::Base)

    assert queue.deliver("event_id" => "x")
    assert_equal(["x"], fallback.events.map { |event| event["event_id"] })
    assert_includes log_output, "ActiveJob is not loaded"
  end
end
