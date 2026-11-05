# frozen_string_literal: true

module GoodSorcery
  module Performance
    # The fixed log-scale duration buckets (scheme "gs-v1", DESIGN.md 8.6),
    # shared literally with the server. Bucket i holds durations d with
    # BOUNDS_MS[i - 1] <= d < BOUNDS_MS[i]; bucket 30 holds 48 s and up.
    module Histogram
      SCHEME = "gs-v1"
      BOUNDS_MS = [
        1, 1.5, 2, 3, 4.5, 6.5, 9.5, 14, 20, 28,
        40, 60, 85, 125, 180, 260, 380, 550, 800, 1_150,
        1_700, 2_450, 3_550, 5_100, 7_500, 11_000, 16_000, 23_000, 33_000, 48_000
      ].freeze
      LAST_INDEX = BOUNDS_MS.size

      # The bucket index (0..30) for a duration in milliseconds.
      def self.index(duration_ms)
        BOUNDS_MS.bsearch_index { |bound| bound > duration_ms } || LAST_INDEX
      end
    end
  end
end
