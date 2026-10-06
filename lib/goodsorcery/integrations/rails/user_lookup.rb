# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # Finds the signed-in user for a report: the controller's user_method
      # (default current_user), else Current.user. Keeps only id, email,
      # username and name. Anything the app raises while looking is ignored.
      class UserLookup
        def initialize(user_method)
          @user_method = user_method
        end

        def find(controller)
          user = from_controller(controller) || from_current_attributes
          user && Event::UserSection.build(user)
        end

        private

        def from_controller(controller)
          return nil unless controller && @user_method && controller.respond_to?(@user_method, true)

          controller.send(@user_method)
        rescue StandardError
          nil
        end

        def from_current_attributes
          return nil unless defined?(::Current) && ::Current.respond_to?(:user)

          ::Current.user
        rescue StandardError
          nil
        end
      end
    end
  end
end
