# frozen_string_literal: true

require "test_helper"

class NotifyTest < Minitest::Test
  class AppError < StandardError; end
  class IgnoredError < StandardError; end
  class IgnoredChildError < IgnoredError; end

  def use_test_delivery(&block)
    GoodSorcery.configure do |config|
      config.delivery = :test
      block&.call(config)
    end
  end

  def test_returns_nil_and_builds_nothing_when_disabled
    GoodSorcery.configure do |config|
      config.environment = "development"
      config.api_key = "gs_test_abcdefabcdefabcd"
    end

    assert_nil GoodSorcery.notify(raise_and_rescue)
    assert_nil GoodSorcery.client.instance_variable_get(:@delivery)
    assert_nil GoodSorcery.client.instance_variable_get(:@pipeline)
  end

  def test_test_delivery_bypasses_the_environment_check
    use_test_delivery { |config| config.environment = "test" }
    id = GoodSorcery.notify(raise_and_rescue(AppError, "nope"))

    assert_equal([id], GoodSorcery.test_events.map { |event| event["event_id"] })
    assert_equal "NotifyTest::AppError", GoodSorcery.test_events.first["exception"]["class"]
    GoodSorcery.clear_test_events
    assert_empty GoodSorcery.test_events
  end

  def test_missing_api_key_disables_network_delivery_with_one_warning
    GoodSorcery.configure { |config| config.environment = "production" }

    assert_nil GoodSorcery.notify(raise_and_rescue)
    assert_nil GoodSorcery.notify(raise_and_rescue)
    assert_equal 1, log_output.scan("no API key configured").size
  end

  def test_ignores_listed_classes_and_their_subclasses
    use_test_delivery { |config| config.ignore_exceptions += ["NotifyTest::IgnoredError"] }

    assert_nil GoodSorcery.notify(raise_and_rescue(IgnoredError))
    assert_nil GoodSorcery.notify(raise_and_rescue(IgnoredChildError))
    assert_nil GoodSorcery.notify(SystemExit.new)
    assert GoodSorcery.notify(raise_and_rescue(AppError))
  end

  def test_reports_the_same_exception_object_once
    use_test_delivery
    error = raise_and_rescue

    assert GoodSorcery.notify(error)
    assert_nil GoodSorcery.notify(error)
    assert_equal 1, GoodSorcery.test_events.size
  end

  def test_frozen_exceptions_can_still_be_reported
    use_test_delivery

    assert GoodSorcery.notify(raise_and_rescue.freeze)
  end

  def test_message_becomes_a_runtime_error_with_the_callers_backtrace
    use_test_delivery
    GoodSorcery.notify("Payment provider timed out", level: :warning)
    exception = GoodSorcery.test_events.first["exception"]

    assert_equal "RuntimeError", exception["class"]
    assert_equal "Payment provider timed out", exception["message"]
    assert_match(/notify_test\.rb\z/, exception["backtrace"].first["file"])
    assert_equal "warning", GoodSorcery.test_events.first["level"]
  end

  def test_before_send_can_change_the_event
    use_test_delivery do |config|
      config.before_send = lambda do |event|
        event["tags"] = { "changed" => "yes" }
        event
      end
    end
    GoodSorcery.notify(raise_and_rescue)

    assert_equal({ "changed" => "yes" }, GoodSorcery.test_events.first["tags"])
  end

  def test_before_send_returning_nil_drops_the_event
    use_test_delivery { |config| config.before_send = ->(_event) {} }

    assert_nil GoodSorcery.notify(raise_and_rescue)
    assert_empty GoodSorcery.test_events
  end

  def test_before_send_errors_drop_the_event_and_are_logged_without_details
    use_test_delivery { |config| config.before_send = ->(_event) { raise "secret detail" } }

    assert_nil GoodSorcery.notify(raise_and_rescue)
    assert_empty GoodSorcery.test_events
    assert_includes log_output, "before_send raised RuntimeError"
    refute_includes log_output, "secret detail"
  end

  def test_before_send_sees_filtered_data
    seen = nil
    use_test_delivery { |config| config.before_send = ->(event) { seen = event } }
    GoodSorcery.notify(raise_and_rescue, context: { password: "hunter2" })

    assert_equal "[FILTERED]", seen["context"]["password"]
  end

  def test_notify_never_raises
    exploding_filter = Object.new
    def exploding_filter.filter(_hash) = raise(ArgumentError, "contains hunter2")
    use_test_delivery { |config| config.extra_filters = [exploding_filter] }

    assert_nil GoodSorcery.notify(raise_and_rescue, context: { a: 1 })
    assert_includes log_output, "notify failed with ArgumentError"
    refute_includes log_output, "hunter2"
  end

  def test_with_context_is_scoped_to_the_block
    use_test_delivery
    GoodSorcery.context(outer: 1)
    GoodSorcery.with_context(job: "Import") { GoodSorcery.notify(raise_and_rescue) }
    GoodSorcery.notify(raise_and_rescue)
    inside, outside = GoodSorcery.test_events.map { |event| event["context"] }

    assert_equal "Import", inside["job"]
    assert_equal 1, inside["outer"]
    refute outside.key?("job")
  end

  def test_scope_is_per_thread
    use_test_delivery
    GoodSorcery.user = { id: 1 }
    GoodSorcery.tags(main: "yes")
    Thread.new { GoodSorcery.notify(raise_and_rescue) }.join
    event = GoodSorcery.test_events.first

    refute event.key?("user")
    refute event.key?("tags")
  end

  def test_with_scope_starts_fresh_and_restores
    use_test_delivery
    GoodSorcery.user = { id: 1 }
    GoodSorcery.with_scope do |scope|
      scope.transaction = "rake db:migrate"
      GoodSorcery.notify(raise_and_rescue)
    end

    assert_equal "rake db:migrate", GoodSorcery.test_events.first["transaction"]
    refute GoodSorcery.test_events.first.key?("user")
    assert_equal({ id: 1 }, GoodSorcery.scope.user)
  end

  def test_breadcrumbs_keep_the_most_recent
    use_test_delivery { |config| config.max_breadcrumbs = 3 }
    5.times { |n| GoodSorcery.add_breadcrumb("step #{n}") }
    GoodSorcery.notify(raise_and_rescue)

    assert_equal(["step 2", "step 3", "step 4"], GoodSorcery.test_events.first["breadcrumbs"].map { |c| c["message"] })
  end

  def test_breadcrumbs_are_not_recorded_when_disabled
    GoodSorcery.configure { |config| config.environment = "development" }
    GoodSorcery.add_breadcrumb("ignored")

    assert_equal 0, GoodSorcery.scope.breadcrumbs.size
  end

  def test_queue_full_notify_returns_nil
    dropping = Object.new
    def dropping.deliver(_event) = false
    GoodSorcery.configure do |config|
      config.delivery = dropping
      config.enabled = true
    end

    assert_nil GoodSorcery.notify(raise_and_rescue)
  end

  def test_enabled_reflects_the_gate
    GoodSorcery.configure { |config| config.environment = "production" }

    assert_predicate GoodSorcery, :enabled?
  end
end

class EventSerializerTest < Minitest::Test
  def test_drops_events_over_512_kib_and_logs_the_size_only
    serializer = GoodSorcery::EventSerializer.new(captured_log)

    assert_nil serializer.dump("blob" => "s3cr3t" * 100_000)
    assert_match(/dropped an event of \d+ bytes/, log_output)
    refute_includes log_output, "s3cr3t"
    assert serializer.dump("small" => 1)
  end
end
