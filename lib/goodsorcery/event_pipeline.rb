# frozen_string_literal: true

module GoodSorcery
  # Builds, filters and passes an event through before_send, in the caller's
  # thread. Returns the event, or nil when before_send drops it (or raises).
  class EventPipeline
    def initialize(config, log)
      @builder = Event::Builder.new(config)
      @filter = EventFilter.new(KeyFilter.new(config.filter_params, mode: config.filter_mode), config.event_filters)
      @before_send = config.before_send
      @log = log
    end

    def prepare(exception, options, scope)
      event = @builder.build(exception, options, scope)
      @filter.filter_event(event)
      apply_before_send(event)
    end

    private

    def apply_before_send(event)
      return event unless @before_send

      result = @before_send.call(event)
      return result if result.is_a?(Hash)

      @log.warn_once(:before_send_type, "before_send returned #{result.class}; event dropped") unless result.nil?
      nil
    rescue StandardError => e
      @log.warn_every(:before_send_error, 60, "before_send raised #{e.class}; event dropped")
      nil
    end
  end
end
