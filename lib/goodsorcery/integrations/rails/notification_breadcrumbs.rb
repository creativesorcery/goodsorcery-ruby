# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # Turns ActiveSupport::Notifications events into breadcrumbs, recorded
      # only inside a scope an integration opened (a request, job or channel
      # action). Never raises into the instrumented code.
      class NotificationBreadcrumbs
        EVENTS = %w[
          start_processing.action_controller sql.active_record perform.active_job deliver.action_mailer
        ].freeze
        IGNORED_SQL_NAMES = %w[SCHEMA CACHE TRANSACTION].freeze

        def self.subscribe
          return if @subscribed

          @subscribed = true
          recorder = new
          EVENTS.each do |event_name|
            ::ActiveSupport::Notifications.subscribe(event_name) do |name, started, finished, _id, payload|
              recorder.record_notification(name, started, finished, payload)
            end
          end
        end

        def record_notification(name, started, finished, payload)
          return unless Scope.unit_of_work && GoodSorcery.client.collecting_breadcrumbs?

          record(name, payload, duration_ms(started, finished))
        rescue StandardError
          nil
        end

        private

        def record(name, payload, duration)
          case name
          when "start_processing.action_controller" then controller(payload)
          when "sql.active_record" then sql(payload, duration)
          when "perform.active_job" then job(payload)
          when "deliver.action_mailer" then mail(payload)
          end
        end

        def controller(payload)
          format = payload[:format].to_s.upcase
          message = "#{payload[:controller]}##{payload[:action]}"
          GoodSorcery.add_breadcrumb(format.empty? ? message : "#{message} as #{format}", category: "controller")
        end

        def sql(payload, duration)
          return if payload[:cached] || IGNORED_SQL_NAMES.include?(payload[:name])

          statement = SqlStatement.new(payload[:sql]).obfuscated
          GoodSorcery.add_breadcrumb("#{payload[:name] || "SQL"} (#{duration}ms)", category: "sql",
                                                                                   data: { "sql" => statement })
        end

        def job(payload)
          job = payload[:job]
          return unless job

          failure = payload[:exception_object]
          message = failure ? "#{job.class.name} failed (#{failure.class})" : "Performed #{job.class.name}"
          GoodSorcery.add_breadcrumb(message, category: "job", level: failure ? "error" : "info",
                                              data: { "queue" => job.queue_name })
        end

        def mail(payload)
          GoodSorcery.add_breadcrumb("Delivered mail from #{payload[:mailer]}", category: "custom")
        end

        def duration_ms(started, finished)
          ((finished - started) * 1000).round(1)
        rescue StandardError
          nil
        end
      end
    end
  end
end
