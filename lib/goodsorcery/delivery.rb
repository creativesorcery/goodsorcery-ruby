# frozen_string_literal: true

require_relative "delivery/event_queue"
require_relative "delivery/backoff"
require_relative "delivery/worker"
require_relative "delivery/async"
require_relative "delivery/sync"
require_relative "delivery/test"
require_relative "delivery/custom"
require_relative "delivery/active_job_queue"

module GoodSorcery
  # Delivery strategies (config.delivery). Each exposes deliver(event),
  # flush(timeout) and shutdown(timeout).
  module Delivery
    def self.build(config, client)
      case config.delivery
      when :async then async(config, client.transport, client.serializer, client.log)
      when :sync then Sync.new(transport: client.transport, serializer: client.serializer, log: client.log)
      when :test then Test.new
      when :active_job then active_job(config, client)
      else Custom.new(config.delivery)
      end
    end

    def self.async(config, transport, serializer, log)
      Async.new(transport: transport, serializer: serializer, log: log,
                batch_size: config.batch_size, flush_interval: config.flush_interval,
                max_queue_size: config.max_queue_size, max_retries: config.max_retries,
                shutdown_timeout: config.shutdown_timeout)
    end

    def self.active_job(config, client)
      ActiveJobQueue.new(serializer: client.serializer, queue_name: config.active_job_queue, log: client.log) do
        async(config, client.transport, client.serializer, client.log)
      end
    end
  end
end
