# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # Sends each event immediately, in the calling thread. For scripts, rake
    # tasks, serverless functions and debugging.
    class Sync
      def initialize(transport:, serializer:, log:)
        @transport = transport
        @serializer = serializer
        @log = log
      end

      def deliver(event)
        json = @serializer.dump(event)
        return false unless json

        result = @transport.post_event(json)
        @log.warn_every(:sync_failed, 60, "could not deliver an event (#{result.description})") if result.retry_later?
        result.success?
      end

      def flush(_timeout = nil) = true
      def shutdown(_timeout = nil) = true
    end
  end
end
