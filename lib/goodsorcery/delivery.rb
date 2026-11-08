# frozen_string_literal: true

require_relative "delivery/event_queue"
require_relative "delivery/backoff"
require_relative "delivery/worker"
require_relative "delivery/async"
require_relative "delivery/sync"
require_relative "delivery/test"

module GoodSorcery
  # Delivery strategies (config.delivery: :async, :sync or :test; the
  # setter rejects anything else). Each exposes deliver(event),
  # flush(timeout) and shutdown(timeout).
  module Delivery
    def self.build(config, client)
      case config.delivery
      when :sync then Sync.new(transport: client.transport, serializer: client.serializer, log: client.log)
      when :test then Test.new
      else async(config, client.transport, client.serializer, client.log)
      end
    end

    def self.async(config, transport, serializer, log)
      Async.new(transport: transport, serializer: serializer, log: log,
                batch_size: config.batch_size, flush_interval: config.flush_interval,
                max_queue_size: config.max_queue_size, max_retries: config.max_retries,
                shutdown_timeout: config.shutdown_timeout)
    end
  end
end
