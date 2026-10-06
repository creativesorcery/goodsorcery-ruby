# frozen_string_literal: true

module GoodSorcery
  # Framework integrations (DESIGN.md 5). Each layer opens a fresh scope per
  # unit of work and leaves an enricher that reads its details only when an
  # error is reported.
  module Integrations
    # GoodSorcery::DeliveryJob sends events; errors it raises are never
    # reported (no recursion).
    def self.delivery_job?(object)
      GoodSorcery.const_defined?(:DeliveryJob, false) && object.is_a?(GoodSorcery::DeliveryJob)
    end

    # Runs the block in a fresh scope prepared by +details+ (an object with
    # +open(scope)+), reporting any exception that escapes it, then
    # re-raising.
    def self.run_unit_of_work(details)
      GoodSorcery.with_scope do |scope|
        details.open(scope)
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        GoodSorcery.notify(e)
        raise
      end
    end
  end
end
