# frozen_string_literal: true

require "test_helper"

class HistogramTest < Minitest::Test
  Histogram = GoodSorcery::Performance::Histogram

  # The same list as goodsorcery_web (INGEST_API.md, scheme gs-v1).
  def test_bounds_are_the_shared_gs_v1_list
    assert_equal [1, 1.5, 2, 3, 4.5, 6.5, 9.5, 14, 20, 28,
                  40, 60, 85, 125, 180, 260, 380, 550, 800, 1150,
                  1700, 2450, 3550, 5100, 7500, 11_000, 16_000, 23_000, 33_000, 48_000], Histogram::BOUNDS_MS
    assert_equal "gs-v1", Histogram::SCHEME
  end

  def test_index_counts_the_bounds_at_or_below_the_duration
    assert_equal 0, Histogram.index(0)
    assert_equal 0, Histogram.index(0.4)
    assert_equal 0, Histogram.index(0.999)
    assert_equal 1, Histogram.index(1)
    assert_equal 15, Histogram.index(250)
    assert_equal 29, Histogram.index(47_999)
    assert_equal 30, Histogram.index(48_000)
    assert_equal 30, Histogram.index(60_000)
    assert_equal 30, Histogram.index(1_000_000)
  end

  def test_every_bound_starts_its_own_bucket
    Histogram::BOUNDS_MS.each_with_index do |bound, index|
      assert_equal index + 1, Histogram.index(bound)
      assert_equal index, Histogram.index(bound - 0.0001)
    end
  end
end
