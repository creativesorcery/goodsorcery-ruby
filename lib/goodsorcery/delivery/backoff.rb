# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # Exponential backoff with jitter: about 1, 2, 4, 8 … seconds, capped at
    # 60 s, each multiplied by a random factor between 0.5 and 1.
    class Backoff
      BASE = 1.0
      MAX = 60.0

      def initialize(random: Random.new)
        @random = random
      end

      def delay(attempt)
        [BASE * (2**attempt), MAX].min * (0.5 + (@random.rand * 0.5))
      end
    end
  end
end
