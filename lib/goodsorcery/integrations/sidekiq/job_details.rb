# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Sidekiq
      # The "job" section, transaction and queue tag for one Sidekiq job,
      # read from the job hash when an error is reported. Arguments are left
      # out when send_job_arguments is false or the job class has
      # `sidekiq_options goodsorcery_arguments: false`.
      class JobDetails
        def initialize(job, queue: nil, worker: nil)
          @job = job
          @queue = queue || job["queue"]
          @worker = worker
        end

        def open(scope)
          scope.transaction = job_class
          scope.merge_tags("queue" => @queue) if @queue
          scope.enricher = self
        end

        def enrich(scope)
          scope.job = to_h
        end

        def to_h
          section = {
            "framework" => "sidekiq", "class" => job_class, "id" => @job["jid"], "queue" => @queue,
            "retry_count" => @job["retry_count"], "enqueued_at" => Event::Fields.iso_time(@job["enqueued_at"])
          }
          section["arguments"] = JobArguments.new.serialize(Array(@job["args"])) if send_arguments?
          section.compact
        end

        private

        def job_class
          @job["class"].to_s
        end

        def send_arguments?
          GoodSorcery.configuration.send_job_arguments && @job["goodsorcery_arguments"] != false &&
            class_option != false
        end

        def class_option
          klass = @worker&.class
          klass.respond_to?(:get_sidekiq_options) ? klass.get_sidekiq_options["goodsorcery_arguments"] : nil
        end
      end
    end
  end
end
