# frozen_string_literal: true

module GoodSorcery
  class Configuration
    # The performance monitoring settings (DESIGN.md 8.1). Monitoring is off
    # unless set here or with GOODSORCERY_PERFORMANCE_MONITORING=1.
    module PerformanceSettings
      def self.included(base)
        base.attr_accessor :performance_ignore_transactions
        base.attr_reader :performance_traces
        base.boolean_setting :performance_traces
      end

      def performance_monitoring
        return @performance_monitoring unless @performance_monitoring.nil?

        EnvFlag.parse(ENV.fetch("GOODSORCERY_PERFORMANCE_MONITORING", nil)) || false
      end

      def performance_monitoring=(value)
        unless [true, false, nil].include?(value)
          raise ArgumentError, "performance_monitoring must be true, false or nil (got #{value.inspect})"
        end

        @performance_monitoring = value
      end

      private

      def assign_performance_defaults
        @performance_monitoring = nil
        @performance_traces = true
        @performance_ignore_transactions = Defaults::PERFORMANCE_IGNORE_TRANSACTIONS.dup
      end
    end
  end
end
