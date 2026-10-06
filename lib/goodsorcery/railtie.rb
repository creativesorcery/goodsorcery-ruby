# frozen_string_literal: true

require_relative "../goodsorcery" unless defined?(GoodSorcery::Client)
require_relative "integrations/rails"

module GoodSorcery
  # Rails integration (DESIGN.md 5): defaults from Rails (root, environment,
  # logger, filter_parameters and the REVISION file are read lazily by
  # Configuration), the Rack middleware after ActionDispatch::ShowExceptions,
  # the Rails.error subscriber, the Active Job, Action Cable and notification
  # breadcrumb layers, rake tasks and the goodsorcery:install generator.
  class Railtie < ::Rails::Railtie
    initializer "goodsorcery.middleware" do |app|
      GoodSorcery::Integrations::Rails.install_middleware(app.config.middleware)
    end

    initializer "goodsorcery.framework_hooks" do
      GoodSorcery::Integrations::Rails.install_framework_hooks
    end

    config.after_initialize do
      GoodSorcery::Integrations::Rails.after_initialize
    end

    rake_tasks do
      require_relative "tasks"
    end
  end
end
