# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Prepended to Net::HTTP: one "http" span per request made while a unit
    # of work is recorded (DESIGN.md 8.3). It always calls super and never
    # rescues the app's exceptions. The recursive call Net::HTTP#request
    # makes through #start is skipped, and nothing is recorded while
    # Performance.suppressed? (the gem's own requests).
    module NetHttp
      ACTIVE_KEY = :__goodsorcery_http_request

      def self.install
        ::Net::HTTP.prepend(self) unless installed?
      end

      def self.installed?
        defined?(::Net::HTTP) ? ::Net::HTTP.ancestors.include?(self) : false
      end

      def request(req, body = nil, &)
        recorder = Thread.current[ACTIVE_KEY] ? nil : Performance.http_recorder
        return super unless recorder

        Thread.current[ACTIVE_KEY] = true
        started = Performance.monotonic
        response = nil
        begin
          response = super
        ensure
          Thread.current[ACTIVE_KEY] = nil
          Performance.record_http(recorder, started, address, req, response)
        end
      end
    end
  end
end
