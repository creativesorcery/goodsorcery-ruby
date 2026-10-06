# frozen_string_literal: true

require_relative "support/rails_app"

class RailtieTest < Minitest::Test
  def test_defaults_come_from_rails
    config = GoodSorcery::Configuration.new

    assert_equal Rails.root.to_s, config.root
    assert_same Rails.logger, config.logger
    assert_equal Rails.env.to_s, config.environment
    assert_equal GoodSorceryTestApp::REVISION, config.release
  end

  def test_settings_win_over_rails_defaults
    config = GoodSorcery::Configuration.new
    config.root = "/srv/app"
    config.environment = "staging"

    assert_equal "/srv/app", config.root
    assert_equal "staging", config.environment
  end

  def test_middleware_sits_right_after_show_exceptions
    stack = Rails.application.middleware.middlewares
    show_exceptions = stack.index(ActionDispatch::ShowExceptions)

    assert_equal GoodSorcery::Rack::Middleware, stack[show_exceptions + 1].klass
  end

  def test_subscribes_to_the_rails_error_reporter
    subscribers = Rails.error.instance_variable_get(:@subscribers)

    assert(subscribers.any?(GoodSorcery::Integrations::Rails::ErrorSubscriber))
  end

  def test_rails_filter_parameters_join_the_event_filters
    filters = GoodSorcery.configuration.event_filters

    assert_instance_of ActiveSupport::ParameterFilter, filters.first
    GoodSorcery.configuration.use_rails_filter_parameters = false
    assert_empty GoodSorcery.configuration.event_filters
  end

  def test_errors_from_the_delivery_job_are_not_reported
    GoodSorcery.configure { |config| config.delivery = :test }
    job = GoodSorcery::Delivery::DeliveryJobLoader.job_class.new("{}")
    Rails.error.report(RuntimeError.new("delivery failed"), handled: false, context: { job: job })

    assert_empty GoodSorcery.test_events
  end
end
