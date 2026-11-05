# frozen_string_literal: true

require "test_helper"

class AggregatorTest < Minitest::Test
  Aggregator = GoodSorcery::Performance::Aggregator
  MINUTE = 29_500_000

  def setup
    super
    @aggregator = Aggregator.new
  end

  def row(minute = MINUTE, kind: :web, name: "ProductsController#show")
    @aggregator.take.to_h.fetch(minute).fetch(kind).fetch(name).to_h(kind, name)
  end

  def test_counts_failures_and_sums_durations_per_minute
    @aggregator.record(MINUTE, sample(100.0))
    @aggregator.record(MINUTE, sample(300.0, failed: true))

    hash = row

    assert_equal 2, hash["count"]
    assert_equal 1, hash["failed"]
    assert_in_delta 400.0, hash["duration_ms"]
  end

  def test_each_bucket_carries_its_count_and_layer_sums
    @aggregator.record(MINUTE, sample(250.0, db: 100.0, http: 50.0, view: 30.0))
    @aggregator.record(MINUTE, sample(255.0, db: 10.0, http: 0.0, view: 5.0))
    @aggregator.record(MINUTE, sample(0.5, db: 0.1))

    buckets = row["buckets"]

    assert_equal [[0, 1, 0.1, 0.0, 0.0, 0.4], [15, 2, 110.0, 50.0, 35.0, 310.0]], buckets
    assert_equal(3, buckets.sum { |bucket| bucket[1] })
  end

  def test_layer_sums_add_up_to_the_duration_without_overlap
    samples = [sample(812.0, db: 300.5, http: 200.25, view: 111.0), sample(14.2, db: 3.1, view: 1.0)]
    samples.each { |each_sample| @aggregator.record(MINUTE, each_sample) }

    hash = row
    layer_total = hash["buckets"].sum { |bucket| bucket[2..].sum }

    assert_in_delta hash["duration_ms"], layer_total, 0.001
  end

  def test_ruby_time_is_floored_at_zero_when_layers_overlap
    sample = sample(100.0, db: 60.0, http: 70.0)

    assert_in_delta 0.0, sample.ruby_ms
    @aggregator.record(MINUTE, sample)
    assert_equal [[13, 1, 60.0, 70.0, 0.0, 0.0]], row["buckets"]
  end

  def test_labels_come_from_the_latest_sample
    @aggregator.record(MINUTE, sample(10.0, labels: { "method" => "GET", "route" => "/a" }))
    @aggregator.record(MINUTE, sample(10.0, labels: { "method" => "GET", "route" => "/b" }))

    assert_equal "/b", row["route"]
  end

  def test_jobs_add_queue_wait
    job = ->(wait) { sample(50.0, kind: :job, name: "Orders::PlaceJob", queue_wait_ms: wait, labels: {}) }
    @aggregator.record(MINUTE, job.call(12.0))
    @aggregator.record(MINUTE, job.call(14.0))
    @aggregator.record(MINUTE, job.call(nil))

    hash = row(kind: :job, name: "Orders::PlaceJob")

    assert_in_delta 26.0, hash["queue_wait_ms"]
    assert_equal [[7, 1], [8, 1]], hash["queue_wait"]
    assert_equal 3, hash["count"]
  end

  def test_names_past_the_cap_fold_into_other_without_labels
    (Aggregator::MAX_TRANSACTIONS + 3).times { |index| @aggregator.record(MINUTE, sample(5.0, name: "C#a#{index}")) }
    @aggregator.record(MINUTE, sample(5.0, name: "C#a0"))

    names = @aggregator.take.first.last[:web]
    other = names["(other)"].to_h(:web, "(other)")

    assert_equal Aggregator::MAX_TRANSACTIONS + 1, names.size
    assert_equal 3, other["count"]
    refute other.key?("method")
    assert_equal 2, names["C#a0"].count
  end

  def test_the_cap_counts_per_kind
    Aggregator::MAX_TRANSACTIONS.times { |index| @aggregator.record(MINUTE, sample(5.0, name: "C#a#{index}")) }
    @aggregator.record(MINUTE, sample(5.0, kind: :job, name: "SomeJob"))

    assert_equal ["SomeJob"], @aggregator.take.first.last[:job].keys
  end

  def test_holds_at_most_five_minutes_dropping_the_oldest
    7.times { |offset| @aggregator.record(MINUTE + offset, sample(5.0)) }

    assert_equal ((MINUTE + 2)..(MINUTE + 6)).to_a, @aggregator.minutes
    assert_equal 2, @aggregator.dropped_minutes
  end

  def test_take_returns_closed_minutes_oldest_first
    [2, 0, 1].each { |offset| @aggregator.record(MINUTE + offset, sample(5.0)) }

    assert_equal [MINUTE, MINUTE + 1], @aggregator.take(MINUTE + 1).map(&:first)
    assert_equal [MINUTE + 2], @aggregator.minutes
  end

  def test_concurrent_records_are_all_counted
    threads = Array.new(8) { Thread.new { 250.times { @aggregator.record(MINUTE, sample(3.0)) } } }
    threads.each(&:join)

    assert_equal 2_000, row["count"]
  end
end
