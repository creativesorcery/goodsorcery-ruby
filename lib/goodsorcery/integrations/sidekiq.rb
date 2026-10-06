# frozen_string_literal: true

require_relative "../integrations"
require_relative "sidekiq/job_details"

module GoodSorcery
  module Integrations
    # Sidekiq (DESIGN.md 5.1), without depending on the gem: a server
    # middleware opens a scope per job and reports what escapes it, and an
    # error handler catches anything raised outside the middleware. Each
    # exception object is reported once. Jobs wrapped by Active Job are left
    # to the Active Job layer.
    module Sidekiq
      def self.install
        return if @installed

        @installed = true
        ::Sidekiq.configure_server do |config|
          config.server_middleware { |chain| chain.add(ServerMiddleware) }
          config.error_handlers << ErrorHandler.new.method(:report)
        end
      end

      def self.active_job_wrapper?(job)
        job.is_a?(Hash) && !job["wrapped"].nil?
      end

      # Sidekiq server middleware.
      class ServerMiddleware
        attr_accessor :config

        def call(worker, job, queue, &)
          return yield if Sidekiq.active_job_wrapper?(job)

          Integrations.run_unit_of_work(JobDetails.new(job, queue: queue, worker: worker), &)
        end
      end

      # Sidekiq error handler, registered as its #report method: Sidekiq
      # passes (exception, context) before Sidekiq 7, (exception, context,
      # config) since.
      class ErrorHandler
        def report(exception, context, _config = nil)
          return if ReportedMark.reported?(exception)

          job = context.is_a?(Hash) ? context[:job] : nil
          GoodSorcery.with_scope do |scope|
            JobDetails.new(job).open(scope) if job.is_a?(Hash) && !Sidekiq.active_job_wrapper?(job)
            GoodSorcery.notify(exception)
          end
        end
      end
    end
  end
end
