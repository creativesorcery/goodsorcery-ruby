# frozen_string_literal: true

require "test_helper"

# The payload shapes in goodsorcery_web/docs/INGEST_API.md › Performance
# monitoring, checked field by field.
class PayloadsTest < Minitest::Test
  Payloads = GoodSorcery::Performance::Payloads
  Aggregator = GoodSorcery::Performance::Aggregator
  MINUTE = 29_500_000
  UUID = /\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/

  def aggregated(&)
    aggregator = Aggregator.new
    yield aggregator
    aggregator.take
  end

  def test_metrics_payload_shape
    minutes = aggregated do |aggregator|
      aggregator.record(MINUTE, sample(250.0, db: 100.0, labels: { "method" => "POST", "route" => "/checkout",
                                                                   "source" => "app/controllers/c.rb" }))
      aggregator.record(MINUTE + 1, sample(40.0, kind: :job, name: "Orders::PlaceJob", queue_wait_ms: 12.0,
                                                 labels: { "adapter" => "sidekiq", "queue" => "critical" }))
    end
    body = sole_body(Payloads.metrics(minutes))

    assert_metrics_envelope(body)
    web, job = body["minutes"].map { |minute| minute["transactions"].first }

    assert_equal(%w[2026-02-02T02:40:00Z 2026-02-02T02:41:00Z], body["minutes"].map { |minute| minute["minute"] })
    assert_equal({ "kind" => "web", "name" => "ProductsController#show", "method" => "POST", "route" => "/checkout",
                   "source" => "app/controllers/c.rb", "count" => 1, "failed" => 0, "duration_ms" => 250.0,
                   "buckets" => [[15, 1, 100.0, 0.0, 0.0, 150.0]] }, web)
    assert_equal({ "kind" => "job", "name" => "Orders::PlaceJob", "adapter" => "sidekiq", "queue" => "critical",
                   "count" => 1, "failed" => 0, "duration_ms" => 40.0, "buckets" => [[11, 1, 0.0, 0.0, 0.0, 40.0]],
                   "queue_wait_ms" => 12.0, "queue_wait" => [[7, 1]] }, job)
  end

  def assert_metrics_envelope(body)
    assert_equal %w[batch_id notifier histogram minutes], body.keys
    assert_match UUID, body["batch_id"]
    assert_equal "gs-v1", body["histogram"]
    assert_equal({ "name" => "goodsorcery-ruby", "version" => GoodSorcery::VERSION }, body["notifier"])
  end

  def test_metrics_split_under_the_size_limit_and_keep_every_transaction
    minutes = aggregated do |aggregator|
      500.times { |index| aggregator.record(MINUTE, sample(5.0, name: "#{"N" * 900}#{index}")) }
    end
    bodies = Payloads.metrics(minutes)

    assert_operator bodies.size, :>, 1
    bodies.each { |body| assert_operator body.json.bytesize, :<=, 512 * 1_024 }
    assert_equal(500, bodies.sum do |body|
      JSON.parse(body.json)["minutes"].sum do |minute|
        minute["transactions"].size
      end
    end)
    assert_equal bodies.size, bodies.map { |body| JSON.parse(body.json)["batch_id"] }.uniq.size
  end

  def test_traces_payload_shape_and_limits
    traces = Array.new(60) { |index| { "id" => "t#{index}", "padding" => "x" * 40_000 } }
    bodies = Payloads.traces(traces)
    parsed = bodies.map { |body| JSON.parse(body.json) }

    assert_equal(50, parsed.sum { |body| body["traces"].size })
    assert_equal "t0", parsed.first["traces"].first["id"]
    parsed.each do |body|
      assert_equal %w[batch_id notifier traces], body.keys
      assert_match UUID, body["batch_id"]
    end
    bodies.each do |body|
      assert_equal "/api/v1/apm/traces", body.path
      assert_operator body.json.bytesize, :<=, 2 * 1_024 * 1_024
    end
  end

  def sole_body(bodies)
    assert_equal 1, bodies.size
    assert_equal "/api/v1/apm/metrics", bodies.first.path
    JSON.parse(bodies.first.json)
  end

  def test_no_bodies_without_data
    assert_empty Payloads.metrics([])
    assert_empty Payloads.traces([])
  end
end
