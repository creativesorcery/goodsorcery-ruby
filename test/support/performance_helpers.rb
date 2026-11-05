# frozen_string_literal: true

# Helpers for performance monitoring tests: turning it on with the :test
# delivery, building recorders with synthetic spans and reading the
# payloads GoodSorcery.flush_performance stores.
module PerformanceHelpers
  Performance = GoodSorcery::Performance
  REPO_ROOT = File.expand_path("../..", __dir__)

  def start_performance(**settings)
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.performance_monitoring = true
      config.root = REPO_ROOT
      settings.each { |name, value| config.public_send(:"#{name}=", value) }
    end
    assert Performance.install, "performance monitoring did not start"
  end

  def performance_payloads(path_suffix)
    GoodSorcery.flush_performance
    GoodSorcery.test_performance_payloads.select { |payload| payload["path"].end_with?(path_suffix) }
               .map { |payload| payload["body"] }
  end

  def metrics_transactions
    performance_payloads("/metrics").flat_map { |body| body["minutes"] }.flat_map { |minute| minute["transactions"] }
  end

  def recorded_traces
    performance_payloads("/traces").flat_map { |body| body["traces"] }
  end

  # A recorder whose clock starts at +t0+ (monotonic seconds); spans are
  # added at offsets in milliseconds from it.
  def build_recorder(kind = :web, name: "ProductsController#show", traces: true)
    recorder = Performance::Recorder.new(kind, traces: traces)
    recorder.name = name
    recorder
  end

  def at(recorder, offset_ms)
    recorder.started + (offset_ms / 1000.0)
  end

  def add_sql(recorder, from_ms, to_ms, sql, name: "Product Load", rows: 1, &)
    recorder.add_sql(at(recorder, from_ms), at(recorder, to_ms), sql, name, rows, &)
  end

  def stop_at(recorder, duration_ms)
    recorder.stop(at(recorder, duration_ms))
    recorder
  end

  def trace_context(**settings)
    config = GoodSorcery::Configuration.new
    config.root = REPO_ROOT
    settings.each { |name, value| config.public_send(:"#{name}=", value) }
    Performance::TraceContext.new(config)
  end

  def sample(duration_ms, name: "ProductsController#show", kind: :web, db: 0.0, http: 0.0, view: 0.0,
             failed: false, queue_wait_ms: nil, labels: { "method" => "GET" })
    ruby = [duration_ms - db - http - view, 0.0].max
    Performance::Sample.new(kind, name, labels, duration_ms, failed, db, http, view, ruby, queue_wait_ms)
  end
end

Minitest::Test.include(PerformanceHelpers)
