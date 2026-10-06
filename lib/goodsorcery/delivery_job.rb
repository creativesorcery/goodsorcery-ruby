# frozen_string_literal: true

module GoodSorcery
  # Sends one already-filtered event (a JSON string) synchronously. Retries
  # 429/5xx/network failures with ActiveJob's retry_on. Any exception raised
  # here is marked as reported first, so no integration reports it back to
  # Good Sorcery (no recursion).
  class DeliveryJob < ::ActiveJob::Base
    WAIT = ::ActiveJob.gem_version >= Gem::Version.new("7.1") ? :polynomially_longer : :exponentially_longer

    queue_as { GoodSorcery.configuration.active_job_queue }
    retry_on GoodSorcery::RetryableDeliveryError, wait: WAIT, attempts: 5

    def perform(event_json)
      result = GoodSorcery.client.transport.post_event(event_json)
      return unless result.retry_later?

      raise GoodSorcery::RetryableDeliveryError, "event delivery failed (#{result.description})"
    rescue Exception => e # rubocop:disable Lint/RescueException
      ReportedMark.mark(e)
      raise
    end
  end
end
