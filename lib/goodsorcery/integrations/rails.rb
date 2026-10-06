# frozen_string_literal: true

require_relative "../integrations"
require_relative "rails/controller_action"
require_relative "rails/user_lookup"
require_relative "rails/controller_enricher"
require_relative "rails/error_subscriber"
require_relative "rails/notification_breadcrumbs"

module GoodSorcery
  module Integrations
    # Wiring for the Rails layers; GoodSorcery::Railtie calls these.
    module Rails
      module_function

      def install_middleware(middleware)
        middleware.insert_after(::ActionDispatch::ShowExceptions, GoodSorcery::Rack::Middleware,
                                enricher: ControllerEnricher)
      end

      def install_framework_hooks
        ::ActiveSupport.on_load(:active_job) do
          require_relative "active_job"
          GoodSorcery::Integrations::ActiveJob.install(self)
        end
        ::ActiveSupport.on_load(:action_cable_channel) do
          require_relative "action_cable"
          GoodSorcery::Integrations::ActionCable.install(self)
        end
      end

      # After the app's initializers ran: subscribe to Rails.error and to
      # notifications, hook Sidekiq, and recompile the filters so the final
      # filter_parameters apply.
      def after_initialize
        subscribe_to_error_reporter
        NotificationBreadcrumbs.subscribe if GoodSorcery.configuration.breadcrumbs
        install_sidekiq if defined?(::Sidekiq)
        GoodSorcery.client.reconfigure(rebuild_delivery: false)
      end

      def subscribe_to_error_reporter
        return if @error_subscriber || !::Rails.respond_to?(:error)

        @error_subscriber = ErrorSubscriber.new
        ::Rails.error.subscribe(@error_subscriber)
      end

      def install_sidekiq
        require_relative "sidekiq"
        Integrations::Sidekiq.install
      end
    end
  end
end
