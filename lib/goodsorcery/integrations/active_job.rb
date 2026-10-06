# frozen_string_literal: true

require_relative "active_job/job_details"

module GoodSorcery
  module Integrations
    # The Active Job layer (DESIGN.md 5.1), prepended into ActiveJob::Base.
    # It wraps perform_now, outside the job's own rescue_from/retry_on
    # handling, so an error is reported once, when it escapes the job (after
    # the last retry), not on every attempt the job handles itself.
    module ActiveJob
      # Prepended into ActiveJob::Base.
      module Extension
        def self.prepended(base)
          base.class_attribute :goodsorcery_send_arguments, instance_accessor: false, default: true
          base.extend(ClassMethods)
        end

        # Class macro: `goodsorcery_arguments false` never sends this job's
        # arguments (inherited by subclasses).
        module ClassMethods
          def goodsorcery_arguments(enabled)
            self.goodsorcery_send_arguments = enabled ? true : false
          end
        end

        def perform_now
          return super if Integrations.delivery_job?(self)

          Integrations.run_unit_of_work(JobDetails.new(self)) { super }
        end
      end

      def self.install(base = ::ActiveJob::Base)
        base.prepend(Extension) unless base <= Extension
      end
    end
  end
end
