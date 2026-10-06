# frozen_string_literal: true

module GoodSorcery
  # Raises, captures and synchronously sends a GoodSorcery::TestError,
  # regardless of the environment check. Used by `goodsorcery:test` and the
  # install check.
  class TestEvent
    MESSAGE = "Test error from goodsorcery-ruby: if you can see this, error reporting works."

    Outcome = Struct.new(:ok, :event_id, :message) do
      def ok? = ok
    end

    def initialize(client)
      @client = client
    end

    def send_now
      return Outcome.new(false, nil, "no API key configured") if @client.config.api_key.to_s.empty?

      raise TestError, MESSAGE
    rescue TestError => e
      deliver(e)
    end

    private

    def deliver(exception)
      event = @client.prepare_event(exception, transaction: "goodsorcery:test",
                                               tags: { "source" => "goodsorcery:test" })
      return Outcome.new(false, nil, "the test event was dropped by before_send") unless event

      json = @client.serializer.dump(event)
      return Outcome.new(false, nil, "the test event could not be serialized") unless json

      outcome_for(@client.transport.post_event(json), event)
    end

    def outcome_for(result, event)
      return Outcome.new(false, nil, "the server answered #{result.description}") unless result.success?

      id = result.event_id || event["event_id"]
      Outcome.new(true, id, "sent test event #{id}")
    end
  end
end
