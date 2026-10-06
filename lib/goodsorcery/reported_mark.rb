# frozen_string_literal: true

module GoodSorcery
  # Marks exception objects once reported, so the same object reaching
  # several integrations (middleware, Rails.error, Sidekiq) is sent once.
  module ReportedMark
    IVAR = :@__goodsorcery_reported

    def self.reported?(exception)
      exception.instance_variable_defined?(IVAR)
    end

    def self.mark(exception)
      exception.instance_variable_set(IVAR, true) unless exception.frozen?
    rescue StandardError
      nil
    end
  end
end
