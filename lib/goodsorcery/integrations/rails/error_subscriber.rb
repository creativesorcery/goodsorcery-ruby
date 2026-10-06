# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # Subscribed to Rails.error. Unhandled errors are reported at level
      # "error"; handled ones (Rails.error.handle/report) at their severity,
      # unless report_handled_errors is false. The reporter's context goes to
      # context.rails_error (filtered like any context), with the source.
      class ErrorSubscriber
        LEVELS = { error: "error", warning: "warning", info: "info" }.freeze

        def report(error, handled:, severity: nil, context: {}, source: nil)
          return if handled && !GoodSorcery.configuration.report_handled_errors
          return if ReportedMark.reported?(error) || from_delivery_job?(context)

          GoodSorcery.notify(error, level: level(handled, severity),
                                    context: { "rails_error" => rails_error_context(context, source) })
        end

        private

        def level(handled, severity)
          handled ? LEVELS.fetch(severity.to_s.to_sym, "warning") : "error"
        end

        def from_delivery_job?(context)
          context.is_a?(Hash) && Integrations.delivery_job?(context[:job])
        end

        # Controllers and jobs from Rails' execution context become
        # "#<ClassName>"; records become GlobalID strings.
        def rails_error_context(context, source)
          details = context.is_a?(Hash) ? JobArguments.new.serialize(context) : {}
          details.merge("source" => source&.to_s).compact
        end
      end
    end
  end
end
