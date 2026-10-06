# frozen_string_literal: true

module GoodSorcery
  # Rails.application.config.filter_parameters as an extra filter, using
  # ActiveSupport::ParameterFilter so Rails' own matching rules apply. Built
  # whenever the event pipeline is compiled; nil outside a Rails app.
  module RailsFilterParameters
    def self.build
      filters = rails_filters
      return nil if filters.nil? || filters.empty?

      ::ActiveSupport::ParameterFilter.new(filters, mask: KeyFilter::FILTERED)
    rescue StandardError
      nil
    end

    def self.rails_filters
      return nil unless defined?(::ActiveSupport::ParameterFilter) && defined?(::Rails)
      return nil unless ::Rails.respond_to?(:application) && ::Rails.application

      ::Rails.application.config.filter_parameters
    end
  end
end
