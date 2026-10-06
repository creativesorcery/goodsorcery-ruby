# frozen_string_literal: true

module GoodSorcery
  # Base class for errors raised by the gem itself.
  class Error < StandardError; end

  # Raised (and rescued) by `goodsorcery:test` and the install check to send a
  # realistic test exception.
  class TestError < StandardError; end

  # Raised by GoodSorcery::DeliveryJob so ActiveJob retries a delivery that
  # failed with a 429, a 5xx or a network error.
  class RetryableDeliveryError < Error; end
end
