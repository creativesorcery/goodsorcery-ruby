# frozen_string_literal: true

module GoodSorcery
  # Prints "[goodsorcery]"-prefixed lines describing the setup, the verify
  # result and the test event result. Shows the masked API key only.
  class StatusReport
    PREFIX = "[goodsorcery]"

    def initialize(client, out: $stdout)
      @client = client
      @config = client.config
      @out = out
    end

    def print_settings
      say("endpoint:    #{@config.endpoint_label}")
      say("environment: #{@config.environment} (#{enabled_label})")
      say("delivery:    #{delivery_label}")
      say("api key:     #{@config.masked_api_key}")
    end

    def print_verification
      verification = @client.verify
      say("verify:      #{verification.ok? ? "ok" : "FAILED"}, #{verification.message}")
      verification.ok?
    end

    def print_test_event
      outcome = TestEvent.new(@client).send_now
      say("test event:  #{outcome.ok? ? "ok" : "FAILED"}, #{outcome.message}")
      outcome.ok?
    end

    def say(line)
      @out.puts("#{PREFIX} #{line}")
    end

    private

    def enabled_label
      state = @client.enabled? ? "reporting enabled" : "reporting disabled"
      "#{state}: #{@client.disabled_reason}"
    end

    def delivery_label
      delivery = @config.delivery
      delivery.is_a?(Symbol) ? delivery.to_s : delivery.class.name.to_s
    end
  end
end
