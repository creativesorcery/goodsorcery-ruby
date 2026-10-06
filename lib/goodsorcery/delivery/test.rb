# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # Keeps events in memory for app test suites (GoodSorcery.test_events).
    # Never touches the network.
    class Test
      def initialize
        @events = []
        @mutex = Mutex.new
      end

      def deliver(event)
        @mutex.synchronize { @events << event }
        true
      end

      def events
        @mutex.synchronize { @events.dup }
      end

      def clear
        @mutex.synchronize { @events.clear }
      end

      def flush(_timeout = nil) = true
      def shutdown(_timeout = nil) = true
    end
  end
end
