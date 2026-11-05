# frozen_string_literal: true

require "test_helper"

class RecorderTest < Minitest::Test
  def test_layers_add_up_and_ruby_is_the_rest
    recorder = build_recorder
    add_sql(recorder, 0, 30, "SELECT 1")
    recorder.add_http([at(recorder, 40), at(recorder, 60)], "GET", "h", "/", 200)
    recorder.render_started(at(recorder, 70))
    recorder.render_finished(at(recorder, 95), "show")
    stop_at(recorder, 100)

    assert_in_delta 30.0, recorder.db_ms, 0.001
    assert_in_delta 20.0, recorder.http_ms, 0.001
    assert_in_delta 25.0, recorder.view_ms, 0.001
    assert_in_delta 25.0, recorder.ruby_ms, 0.001
    assert_equal 1, recorder.sql_count
    assert_equal 1, recorder.http_count
  end

  # Queries run in parallel (load_async) can add up to more than the total.
  def test_ruby_is_floored_at_zero
    recorder = build_recorder
    recorder.add_http([at(recorder, 0), at(recorder, 80)], "GET", "h", "/", 200)
    add_sql(recorder, 0, 80, "SELECT 1")
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

  # A web request's view time comes from the same render events: every
  # render adds up, and an HTTP call made from a template is HTTP time only.
  def test_web_view_time_sums_renders_without_their_queries_or_http_calls
    recorder = build_recorder
    recorder.render_started(at(recorder, 10))
    add_sql(recorder, 12, 22, "SELECT 1")
    recorder.render_finished(at(recorder, 30), "render_to_string")
    recorder.render_started(at(recorder, 40))
    recorder.add_http([at(recorder, 45), at(recorder, 60)], "GET", "h", "/", 200)
    recorder.render_finished(at(recorder, 70), "show")
    stop_at(recorder, 100)

    assert_in_delta 25.0, recorder.view_ms, 0.001
    assert_in_delta 10.0, recorder.db_ms, 0.001
    assert_in_delta 15.0, recorder.http_ms, 0.001
    assert_in_delta 50.0, recorder.ruby_ms, 0.001
  end

  def test_without_traces_only_totals_are_kept
    recorder = build_recorder(traces: false)
    add_sql(recorder, 0, 5, "SELECT 1") { flunk "no call site without traces" }
    add_sql(recorder, 0, 5, "SELECT 1") { flunk "no call site without traces" }

    refute recorder.traces?
    assert_nil recorder.spans
    assert_in_delta 10.0, recorder.db_ms, 0.001
  end

  # A trace reads at most 4,000 characters of a statement; one more marks
  # the text as cut.
  def test_long_statements_are_kept_only_as_far_as_a_trace_reads_them
    recorder = build_recorder
    add_sql(recorder, 0, 1, "INSERT INTO t (a) VALUES #{"(1), " * 30_000}(1)")

    assert_equal Performance::SqlNormalizer::INPUT_LIMIT + 1, recorder.spans.first[3].length
  end

  def test_sql_text_kept_per_unit_of_work_is_bounded
    recorder = build_recorder
    statement = "SELECT '#{"x" * 4_100}'"
    1_500.times { |index| add_sql(recorder, index, index + 0.1, statement) }
    kept = recorder.spans.size

    assert_equal Performance::Recorder::MAX_SQL_BYTES / Performance::Recorder::MAX_SQL_CHARS, kept
    assert_equal 1_500 - kept, recorder.spans_dropped
    assert_equal 1_500, recorder.sql_count
    assert_in_delta 150.0, recorder.db_ms, 0.01
  end

  def test_repeated_queries_keep_no_copy_of_the_sql_text
    recorder = build_recorder
    2.times { add_sql(recorder, 0, 1, "SELECT * FROM t WHERE id = 1") { :site } }
    shapes = recorder.instance_variable_get(:@repeats).instance_variable_get(:@shapes)

    assert(shapes.keys.all?(Integer))
    broken = (+"SELECT \xFF 1").force_encoding(Encoding::UTF_8)
    2.times { add_sql(recorder, 0, 1, broken) { :site } }

    assert_equal 4, recorder.spans.size
  end

  def test_status_and_failure
    recorder = build_recorder
    recorder.response_status = 503

    assert recorder.failed?
    recorder = build_recorder
    recorder.raised!

    assert_equal 500, recorder.status
    assert recorder.failed?
    recorder = build_recorder
    recorder.raised!(404)

    assert_equal 404, recorder.status
    refute recorder.failed?
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
