# frozen_string_literal: true

require "test_helper"

class TraceBufferTest < Minitest::Test
  TraceBuffer = GoodSorcery::Performance::TraceBuffer
  MINUTE = 29_500_000
  KEY = [:web, "ProductsController#show"].freeze

  def setup
    super
    @buffer = TraceBuffer.new
  end

  def test_keeps_only_the_slowest_trace_per_transaction_per_minute
    assert @buffer.offer(MINUTE, KEY, 100.0, { "id" => "a" })
    assert @buffer.offer(MINUTE, KEY, 300.0, { "id" => "b" })
    refute @buffer.offer(MINUTE, KEY, 200.0, { "id" => "c" })
    refute @buffer.offer(MINUTE, KEY, 300.0, { "id" => "d" })

    assert_equal [{ "id" => "b" }], @buffer.take
  end

  def test_candidate_is_the_cheap_check_before_building
    assert @buffer.candidate?(MINUTE, KEY, 1.0)
    @buffer.offer(MINUTE, KEY, 50.0, {})

    refute @buffer.candidate?(MINUTE, KEY, 49.0)
    assert @buffer.candidate?(MINUTE, KEY, 51.0)
    assert @buffer.candidate?(MINUTE + 1, KEY, 1.0)
    assert @buffer.candidate?(MINUTE, [:job, "SomeJob"], 0.1)
  end

  def test_each_minute_and_kind_keeps_its_own_slowest
    @buffer.offer(MINUTE, KEY, 10.0, { "id" => "m0" })
    @buffer.offer(MINUTE + 1, KEY, 5.0, { "id" => "m1" })
    @buffer.offer(MINUTE, [:job, KEY.last], 7.0, { "id" => "job" })

    assert_equal(%w[m0 job m1], @buffer.take.map { |trace| trace["id"] })
  end

  def test_holds_at_most_30_traces_per_minute_replacing_the_fastest
    30.times { |index| @buffer.offer(MINUTE, [:web, "C#a#{index}"], 100.0 + index, { "id" => index }) }

    refute @buffer.candidate?(MINUTE, [:web, "New#a"], 100.0)
    refute @buffer.offer(MINUTE, [:web, "New#a"], 99.0, { "id" => "slow-enough?" })
    assert @buffer.offer(MINUTE, [:web, "New#a"], 150.0, { "id" => "new" })

    ids = @buffer.take.map { |trace| trace["id"] }

    assert_equal 30, ids.size
    assert_equal "new", ids.first
    refute_includes ids, 0
  end

  def test_take_returns_closed_minutes_slowest_first
    @buffer.offer(MINUTE, KEY, 10.0, { "id" => "old" })
    @buffer.offer(MINUTE + 1, KEY, 20.0, { "id" => "open" })

    assert_equal [{ "id" => "old" }], @buffer.take(MINUTE)
    assert_equal 1, @buffer.size
  end
end
