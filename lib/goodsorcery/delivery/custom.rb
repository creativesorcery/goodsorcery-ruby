# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # Wraps an app-supplied delivery object. It must respond to
    # deliver(event_hash) and may respond to flush(timeout) and shutdown(timeout).
    class Custom
      attr_reader :target

      def initialize(target)
        @target = target
      end

      def deliver(event)
        @target.deliver(event)
      end

      def flush(timeout = 5)
        @target.respond_to?(:flush) ? @target.flush(timeout) : true
      end

      def shutdown(timeout = 5)
        @target.respond_to?(:shutdown) ? @target.shutdown(timeout) : true
      end
    end
  end
end
