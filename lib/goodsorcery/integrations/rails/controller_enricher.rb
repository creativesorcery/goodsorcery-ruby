# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # The Action Controller layer (DESIGN.md 5.1): the Rack request plus the
      # transaction ("UsersController#update"), context.controller and the
      # signed-in user. Runs only when an error is reported.
      class ControllerEnricher < GoodSorcery::Rack::RequestEnricher
        def enrich(scope)
          super
          add_controller(scope, ControllerAction.from_env(@env))
          scope.user ||= UserLookup.new(GoodSorcery.configuration.user_method).find(@env["action_controller.instance"])
        end

        private

        def add_controller(scope, action)
          return unless action

          scope.transaction ||= action.transaction
          scope.merge_context("controller" => action.to_h)
        end
      end
    end
  end
end
