# frozen_string_literal: true

module GoodSorcery
  module Integrations
    # The Action Cable layer (DESIGN.md 5.1), prepended into
    # ActionCable::Channel::Base. Each subscribe, unsubscribe and action runs
    # in a fresh scope named "ChatChannel#speak"; exceptions that escape the
    # channel's own rescue_from handlers are reported, then re-raised.
    module ActionCable
      # Prepended into ActionCable::Channel::Base.
      module Extension
        def subscribe_to_channel
          Integrations.run_unit_of_work(ChannelAction.new(self, "subscribed")) { super }
        end

        def unsubscribe_from_channel
          Integrations.run_unit_of_work(ChannelAction.new(self, "unsubscribed")) { super }
        end

        def perform_action(data)
          Integrations.run_unit_of_work(ChannelAction.new(self, ChannelAction.action_name(data), data)) { super }
        end
      end

      def self.install(base = ::ActionCable::Channel::Base)
        base.prepend(Extension) unless base <= Extension
      end

      # One channel action. The request section (the connection's request,
      # with the subscription params and action data as params) is read only
      # when an error is reported.
      class ChannelAction
        def self.action_name(data)
          name = data.is_a?(Hash) ? data["action"].to_s : ""
          name.empty? ? "receive" : name
        end

        def initialize(channel, action, data = nil)
          @channel = channel
          @action = action
          @data = data
        end

        def open(scope)
          scope.transaction = "#{@channel.class.name}##{@action}"
          scope.enricher = self
        end

        def enrich(scope)
          scope.request ||= request_section
        end

        private

        def request_section
          env = @channel.connection.respond_to?(:env) ? @channel.connection.env : nil
          section = env ? connection_request(env) : {}
          section["params"] = params if GoodSorcery.configuration.send_request_params
          section.compact
        end

        def connection_request(env)
          details = GoodSorcery::Rack::RequestDetails.new(env, GoodSorcery.configuration)
          { "url" => details.url, "request_id" => details.request_id, "remote_ip" => details.remote_ip,
            "headers" => details.headers }
        end

        def params
          channel_params = @channel.params
          { "channel" => channel_params.is_a?(Hash) ? channel_params.to_h : nil, "data" => @data }.compact
        end
      end
    end
  end
end
