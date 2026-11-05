# frozen_string_literal: true

require "test_helper"

class TraceBuilderTest < Minitest::Test
  MINUTE = 29_500_000
  PRODUCT_SQL = 'SELECT "products".* FROM "products" WHERE "products"."id" = $1 LIMIT $2'

  def build(recorder, **settings)
    Performance::TraceBuilder.new(recorder, MINUTE, trace_context(**settings)).build
  end

  def call_site
    Performance::CallSite.new(File.expand_path(__FILE__), CALL_LINE, "load_products")
  end

  CALL_LINE = __LINE__ + 1
  def load_products = :placeholder_for_the_call_site_line

  def n_plus_one_recorder(calls: 12)
    recorder = build_recorder
    add_sql(recorder, 1, 3, 'SELECT "users".* FROM "users" WHERE "users"."id" = $1 LIMIT $2', name: "User Load")
    calls.times do |index|
      add_sql(recorder, 10 + (index * 5), 13 + (index * 5), PRODUCT_SQL) { call_site }
    end
    stop_at(recorder, 200)
  end

  def web_trace
    recorder = n_plus_one_recorder
    recorder.http_method = "GET"
    recorder.route = "/products/:id"
    recorder.env = { "PATH_INFO" => "/products/42", "QUERY_STRING" => "token=abc",
                     "action_dispatch.request_id" => "req-1" }
    recorder.response_status = 200
    build(recorder)
  end

  def test_trace_fields
    trace = web_trace

    assert_match(/\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/, trace["id"])
    assert_equal %w[web ProductsController#show GET /products/:id], trace.values_at("kind", "name", "method", "route")
    assert_equal 200, trace["status"]
    assert_equal "2026-02-02T02:40:00Z", trace["minute"]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, trace["started_at"])
    assert_in_delta 200.0, trace["duration_ms"], 0.01
    assert_equal({ "method" => "GET", "path" => "/products/42", "request_id" => "req-1" }, trace["request"])
    assert_equal false, trace["failed"]
    assert trace.key?("error_event_id")
    assert_equal 13, trace["sql_count"]
    assert_equal RUBY_VERSION, trace["runtime"]["ruby"]
    assert_kind_of Integer, trace["allocations"]
    assert_equal %w[count time_ms], trace["gc"].keys.sort
    refute trace.key?("source")
  end

  def test_trace_id_encodes_the_start_time
    recorder = stop_at(build_recorder, 5)
    trace = build(recorder)
    milliseconds = trace["id"].delete("-")[0, 12].to_i(16)

    assert_in_delta recorder.started_wall * 1000, milliseconds, 1
  end

  def test_repeated_sql_is_grouped_with_count_total_span_and_rows
    spans = build(n_plus_one_recorder)["spans"]
    group = spans.last

    assert_equal 2, spans.size
    assert_equal "User Load", spans.first["name"]
    refute spans.first.key?("count")
    assert_equal 12, group["count"]
    assert_equal 12, group["rows"]
    assert_in_delta 36.0, group["duration_ms"], 0.01
    assert_in_delta 10.0, group["offset_ms"], 0.01
    assert_in_delta 58.0, group["span_ms"], 0.01
    assert_equal PRODUCT_SQL, group["sql"]
  end

  def test_sql_with_inlined_literals_groups_by_its_normalised_text
    recorder = build_recorder
    3.times { |id| add_sql(recorder, id, id + 1, "SELECT * FROM products WHERE id = #{id + 1} AND sku = 'S-#{id}'") }
    span = build(stop_at(recorder, 10))["spans"].then { |spans| only(spans) }

    assert_equal "SELECT * FROM products WHERE id = ? AND sku = ?", span["sql"]
    assert_equal 3, span["count"]
    refute span.key?("call_site")
  end

  def test_a_group_carries_its_call_site_with_five_lines_of_code
    site = build(n_plus_one_recorder)["spans"].last["call_site"]

    assert_equal "test/goodsorcery/performance/trace_builder_test.rb", site["file"]
    assert_equal CALL_LINE, site["line"]
    assert_equal "load_products", site["method"]
    assert_equal CALL_LINE - 2, site["context"]["start_line"]
    assert_equal 5, site["context"]["lines"].size
    assert_includes site["context"]["lines"][2], "def load_products"
  end

  def test_no_code_context_without_send_code_context
    site = build(n_plus_one_recorder, send_code_context: false)["spans"].last["call_site"]

    assert_equal CALL_LINE, site["line"]
    refute site.key?("context")
  end

  def test_the_call_site_is_captured_once_on_the_second_run
    recorder = build_recorder
    captures = 0
    5.times do
      add_sql(recorder, 1, 2, PRODUCT_SQL) do
        captures += 1
        call_site
      end
    end

    assert_equal 1, captures
    assert_equal CALL_LINE, recorder.call_site_for(PRODUCT_SQL).line
  end

  def test_spans_are_capped_at_300_keeping_the_longest
    recorder = build_recorder
    320.times { |index| add_sql(recorder, index, index + (index == 5 ? 50 : 0.5), "SELECT #{index} FROM t#{index}") }
    trace = build(stop_at(recorder, 400))

    assert_equal 300, trace["spans"].size
    assert_equal 20, trace["spans_dropped"]
    assert_equal trace["spans"].sort_by { |span| span["offset_ms"] }, trace["spans"]
    assert(trace["spans"].any? { |span| span["sql"] == "SELECT ? FROM t5" })
  end

  def test_raw_spans_past_2000_are_counted_not_kept
    recorder = build_recorder
    2_005.times { add_sql(recorder, 1, 2, PRODUCT_SQL) }
    stop_at(recorder, 10)

    assert_equal 2_000, recorder.spans.size
    assert_equal 5, build(recorder)["spans_dropped"]
    assert_equal 2_005, recorder.sql_count
    assert_in_delta 2_005.0, recorder.db_ms, 0.01
  end

  def test_a_trace_stays_under_64_kib
    recorder = build_recorder
    300.times { |index| add_sql(recorder, index, index + 1, "SELECT #{"c#{index}x, " * 120}a FROM t#{index}") }
    trace = build(stop_at(recorder, 400))

    assert_operator JSON.generate(trace).bytesize, :<=, 65_536
    assert_operator trace["spans_dropped"], :>, 0
  end

  def test_http_view_and_enqueue_spans
    recorder = build_recorder
    recorder.add_http([at(recorder, 5), at(recorder, 25)], "POST", "api.example.com", "/v2/taxes?key=s3cret#frag", 201)
    recorder.render_started(at(recorder, 30))
    recorder.render_finished(at(recorder, 40), "/srv/app/app/views/products/show.html.erb")
    recorder.add_enqueue(at(recorder, 45), at(recorder, 46), "Orders::PlaceJob", "critical")
    spans = build(stop_at(recorder, 50))["spans"]

    assert_equal({ "type" => "http", "offset_ms" => 5.0, "duration_ms" => 20.0, "method" => "POST",
                   "host" => "api.example.com", "path" => "/v2/taxes", "status" => 201 }, round(spans[0]))
    assert_equal "products/show.html.erb", spans[1]["template"]
    assert_equal({ "type" => "enqueue", "offset_ms" => 45.0, "duration_ms" => 1.0, "job" => "Orders::PlaceJob",
                   "queue" => "critical" }, round(spans[2]))
  end

  def test_repeated_renders_of_a_template_are_grouped
    recorder = build_recorder
    3.times do |index|
      recorder.render_started(at(recorder, index * 10))
      recorder.render_finished(at(recorder, (index * 10) + 2), "/srv/app/app/views/products/_row.html.erb")
    end
    span = build(stop_at(recorder, 50))["spans"].then { |spans| only(spans) }

    assert_equal 3, span["count"]
    assert_equal "products/_row.html.erb", span["template"]
  end

  def test_job_traces_carry_the_job_section
    recorder = build_recorder(:job, name: "Orders::PlaceJob")
    recorder.adapter = "sidekiq"
    recorder.queue = "critical"
    recorder.queue_wait_ms = 42.5
    trace = build(stop_at(recorder, 5))

    assert_equal({ "adapter" => "sidekiq", "queue" => "critical", "queue_wait_ms" => 42.5 }, trace["job"])
    refute trace.key?("request")
    refute trace.key?("status")
  end

  def only(spans)
    assert_equal 1, spans.size
    spans.first
  end

  def round(span)
    span.transform_values { |value| value.is_a?(Float) ? value.round(1) : value }
  end
end
