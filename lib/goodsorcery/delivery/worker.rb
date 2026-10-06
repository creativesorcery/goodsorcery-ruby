# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # The loop run by the goodsorcery-worker thread: take a batch, serialize
    # it, send it, retry 5xx/network failures with backoff and wait out 429s
    # without spending a retry. It never raises and never reports its own
    # errors as events.
    class Worker
      def initialize(queue:, transport:, serializer:, log:, settings:)
        @queue = queue
        @transport = transport
        @serializer = serializer
        @log = log
        @flush_interval = settings.fetch(:flush_interval)
        @max_retries = settings.fetch(:max_retries)
        @backoff = settings.fetch(:backoff)
        @sleeper = settings.fetch(:sleeper) || queue
      end

      def run
        loop do
          batch = @queue.take_batch(@flush_interval)
          break if batch.empty?

          deliver_batch(batch)
        end
      end

      def deliver_batch(events)
        jsons = events.filter_map { |event| @serializer.dump(event) }
        send_with_retries(jsons)
      rescue StandardError => e
        @log.error("the delivery worker hit #{e.class}; #{events.size} event(s) dropped")
      ensure
        @queue.batch_done
      end

      private

      def send_with_retries(jsons)
        attempt = 0
        until jsons.empty?
          result = @transport.post_batch(jsons)
          jsons = result.pending
          attempt = wait_before_retry(result, attempt, jsons.size) unless jsons.empty?
          break if attempt.nil?
        end
      end

      # Returns the next attempt number, or nil to give up.
      def wait_before_retry(result, attempt, count)
        return give_up(result, count) if @queue.closed?

        if result.rate_limited?
          @sleeper.pause(result.retry_after)
          return attempt
        end
        return give_up(result, count) if attempt >= @max_retries

        @sleeper.pause(@backoff.delay(attempt))
        attempt + 1
      end

      def give_up(result, count)
        @log.warn_every(:delivery_failed, 60, "could not deliver #{count} event(s) (#{result.description}); dropped")
        nil
      end
    end
  end
end
