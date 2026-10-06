# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module ActiveJob
      # The "job" section, transaction and queue tag for one Active Job
      # execution, read when an error is reported (arguments are deserialized
      # by then). Action Mailer deliveries (deliver_later) are named
      # "UserMailer#welcome" and carry the mailer method's args and params.
      class JobDetails
        def initialize(job)
          @job = job
        end

        def open(scope)
          scope.merge_tags("queue" => @job.queue_name)
          scope.enricher = self
        end

        def enrich(scope)
          mail = MailDelivery.for(@job)
          scope.transaction ||= mail ? mail.transaction : @job.class.name
          scope.job = to_h(mail)
        end

        def to_h(mail = MailDelivery.for(@job))
          section = execution_fields.merge(timestamps)
          section.merge!(mail.to_h) if mail
          section["arguments"] = arguments(mail) if send_arguments?
          section.compact
        end

        private

        def execution_fields
          {
            "framework" => "active_job", "class" => @job.class.name, "id" => @job.job_id,
            "provider_job_id" => @job.provider_job_id&.to_s, "queue" => @job.queue_name,
            "priority" => @job.priority, "executions" => @job.executions
          }
        end

        def timestamps
          scheduled = @job.respond_to?(:scheduled_at) ? @job.scheduled_at : nil
          {
            "enqueued_at" => Event::Fields.iso_time(@job.enqueued_at),
            "scheduled_at" => Event::Fields.iso_time(scheduled)
          }
        end

        def send_arguments?
          GoodSorcery.configuration.send_job_arguments && @job.class.goodsorcery_send_arguments
        end

        def arguments(mail)
          JobArguments.new.serialize(mail ? mail.arguments : @job.arguments)
        end
      end

      # ActionMailer::MailDeliveryJob's arguments:
      # [mailer, method, delivery_method, { args:, kwargs:, params: }].
      class MailDelivery
        def self.for(job)
          return nil unless defined?(::ActionMailer::MailDeliveryJob) && job.is_a?(::ActionMailer::MailDeliveryJob)

          new(job.arguments)
        end

        def initialize(arguments)
          mailer, action, _delivery_method, options = arguments
          @mailer = mailer.to_s
          @action = action.to_s
          @options = options.is_a?(Hash) ? options : {}
        end

        def transaction
          "#{@mailer}##{@action}"
        end

        def to_h
          { "mailer" => @mailer, "action" => @action }
        end

        def arguments
          { "args" => @options[:args], "kwargs" => @options[:kwargs], "params" => @options[:params] }.compact
        end
      end
    end
  end
end
