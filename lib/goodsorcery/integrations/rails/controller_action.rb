# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # The controller and action handling a request, from the controller
      # instance when Rails dispatched to one, else from the router's path
      # parameters.
      class ControllerAction
        attr_reader :controller, :action

        def self.from_env(env)
          instance = env["action_controller.instance"]
          return new(instance.class.name, instance.action_name) if instance.respond_to?(:action_name)

          from_path_parameters(env["action_dispatch.request.path_parameters"])
        end

        def self.from_path_parameters(params)
          return nil unless params.is_a?(Hash) && params[:controller] && params[:action]

          new("#{::ActiveSupport::Inflector.camelize(params[:controller].to_s)}Controller", params[:action].to_s)
        end

        def initialize(controller, action)
          @controller = controller.to_s
          @action = action.to_s
        end

        def transaction
          "#{controller}##{action}"
        end

        def to_h
          { "controller" => controller, "action" => action }
        end
      end
    end
  end
end
