# frozen_string_literal: true

require "test_helper"

class RecorderTest < Minitest::Test
  def test_layers_add_up_and_ruby_is_the_rest
    recorder = build_recorder
    add_sql(recorder, 0, 30, "SELECT 1")
    recorder.add_http([at(recorder, 40), at(recorder, 60)], "GET", "h", "/", 200)
    recorder.view_runtime = 25.0
    stop_at(recorder, 100)

    assert_in_delta 30.0, recorder.db_ms, 0.001
    assert_in_delta 20.0, recorder.http_ms, 0.001
    assert_in_delta 25.0, recorder.view_ms, 0.001
    assert_in_delta 25.0, recorder.ruby_ms, 0.001
    assert_equal 1, recorder.sql_count
    assert_equal 1, recorder.http_count
  end

  def test_ruby_is_floored_at_zero
    recorder = build_recorder
    recorder.add_http([at(recorder, 0), at(recorder, 80)], "GET", "h", "/", 200)
    recorder.view_runtime = 50.0
    stop_at(recorder, 100)

    assert_in_delta 0.0, recorder.ruby_ms
  end

  # A layout around a template around a partial, with a query in the
  # partial: 40 ms of rendering, 10 of it database.
  def test_nested_renders_count_once_without_their_queries
    recorder = build_recorder(:job, name: "ActionMailer::MailDeliveryJob")
    recorder.render_started(at(recorder, 10))
    recorder.render_started(at(recorder, 12))
    recorder.render_started(at(recorder, 15))
    add_sql(recorder, 16, 26, "SELECT 1")
    recorder.render_finished(at(recorder, 30), "_partial")
    recorder.render_finished(at(recorder, 45), "template")
    recorder.render_finished(at(recorder, 50), "layout")
    recorder.render_started(at(recorder, 60))
    recorder.render_finished(at(recorder, 65), "second")
    stop_at(recorder, 100)

    assert_in_delta 35.0, recorder.view_ms, 0.001
    assert_in_delta 10.0, recorder.db_ms, 0.001
    assert_in_delta 55.0, recorder.ruby_ms, 0.001
  end

  def test_without_traces_only_totals_are_kept
    recorder = build_recorder(traces: false)
    add_sql(recorder, 0, 5, "SELECT 1") { flunk "no call site without traces" }
    add_sql(recorder, 0, 5, "SELECT 1") { flunk "no call site without traces" }

    refute recorder.traces?
    assert_nil recorder.spans
    assert_in_delta 10.0, recorder.db_ms, 0.001
  end

  def test_status_and_failure
    recorder = build_recorder
    recorder.response_status = 503

    assert recorder.failed?
    recorder = build_recorder
    recorder.raised!

    assert_equal 500, recorder.status
    assert recorder.failed?
    job = build_recorder(:job)
    job.raised!

    assert_nil job.status
  end
end

class UuidAndLabelTest < Minitest::Test
  def test_uuid_v7_layout_and_order
    first = Performance::UuidV7.generate(Time.at(1_800_000_000, 123, :millisecond))
    second = Performance::UuidV7.generate(Time.at(1_800_000_000, 124, :millisecond))

    assert_match(/\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/, first)
    assert_equal 1_800_000_000_123, first.delete("-")[0, 12].to_i(16)
    assert_operator first, :<, second
  end

  def test_process_labels
    label = Performance::ProcessLabel

    assert_equal "Puma worker 3", label.current("puma: cluster worker 3: 4127 [shop]")
    assert_equal "Puma", label.current("puma 6.4.2 (tcp://0.0.0.0:3000) [shop]")
    assert_equal "Sidekiq", label.current("sidekiq 7.2.0 shop [0 of 5 busy]")
    assert_equal "rails", label.current("/srv/app/bin/rails runner --secret=abc")
  end
end
