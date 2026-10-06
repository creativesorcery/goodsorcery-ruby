# frozen_string_literal: true

module GoodSorcery
  # Serializes an event to JSON, dropping (and logging, by size only) events
  # over the server's 512 KiB limit.
  class EventSerializer
    MAX_BYTES = 524_288

    def initialize(log)
      @log = log
    end

    def dump(event)
      json = JSON.generate(event)
      return json if json.bytesize <= MAX_BYTES

      @log.warn_once(:oversized_event,
                     "dropped an event of #{json.bytesize} bytes (limit 512 KiB); later drops are not logged")
      nil
    rescue StandardError => e
      @log.warn_every(:unserializable_event, 300, "dropped an event that could not be serialized (#{e.class})")
      nil
    end
  end
end
