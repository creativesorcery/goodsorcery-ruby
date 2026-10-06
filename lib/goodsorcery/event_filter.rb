# frozen_string_literal: true

module GoodSorcery
  # Applies the key filter, and any extra filters, to every part of an event
  # that holds free-form data: request params, headers, session and URL query,
  # job arguments, context, tags and breadcrumb data. The user section is left alone on
  # purpose (DESIGN.md 3.4).
  #
  # Extra filters (config.extra_filters) are objects responding to
  # +filter(hash) -> hash+, for example ActiveSupport::ParameterFilter, which
  # the Rails integration adds for Rails.application.config.filter_parameters.
  class EventFilter
    REQUEST_SECTIONS = %w[params headers session].freeze

    def initialize(key_filter, extra_filters = [])
      @key_filter = key_filter
      @extra_filters = Array(extra_filters)
      @extra_probe = @extra_filters.empty? ? nil : ExtraFilterProbe.new(@extra_filters)
    end

    def filter_event(event)
      filter_request(event["request"]) if event["request"]
      filter_job(event["job"]) if event["job"]
      filter_section(event, "context")
      filter_section(event, "tags")
      event["breadcrumbs"]&.each { |crumb| filter_section(crumb, "data") }
      event
    end

    def filter_hash(hash)
      filtered = @key_filter.filter(hash)
      @extra_filters.reduce(filtered) { |result, extra| extra.filter(result) }
    end

    private

    def filter_request(request)
      request["url"] = @key_filter.filter_url(request["url"], @extra_probe) if request["url"]
      REQUEST_SECTIONS.each { |name| filter_section(request, name) }
    end

    # Arguments are often an array, so they are filtered inside a wrapper hash.
    def filter_job(job)
      return unless job.key?("arguments")

      job["arguments"] = filter_hash({ "arguments" => job["arguments"] })["arguments"]
    end

    def filter_section(container, name)
      value = container[name]
      container[name] = filter_hash(value) if value.is_a?(Hash)
    end
  end
end
