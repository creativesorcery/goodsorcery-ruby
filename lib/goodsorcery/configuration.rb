# frozen_string_literal: true

require_relative "configuration/validation"

module GoodSorcery
  # Every setting the gem reads (DESIGN.md 2 and 3). Unset credentials,
  # endpoint, environment, release and the enabled flag fall back to
  # environment variables (and Rails) when they are read.
  class Configuration
    extend Validation

    DELIVERIES = %i[async sync active_job test].freeze
    DELIVERY_SETTINGS = %i[
      delivery api_key endpoint batch_size flush_interval max_queue_size shutdown_timeout
      max_retries open_timeout read_timeout active_job_queue
    ].freeze

    attr_writer :api_key, :endpoint, :environment, :release
    attr_accessor :disabled_environments, :enabled_environments, :filter_params,
                  :use_rails_filter_parameters, :extra_filters, :ignore_exceptions, :tags,
                  :user_method, :send_code_context, :breadcrumbs, :logger, :root,
                  :report_handled_errors, :active_job_queue, :request_extractor
    attr_reader :delivery, :filter_mode, :batch_size, :flush_interval, :max_queue_size,
                :shutdown_timeout, :max_retries, :open_timeout, :read_timeout,
                :max_breadcrumbs, :install_check, :before_send

    choice_setting :filter_mode, %i[mask remove]
    choice_setting :install_check, [:verify, :test_event, false]
    integer_setting :batch_size, 1..100
    integer_setting :max_queue_size, 1..1_000_000
    integer_setting :max_retries, 0..20
    integer_setting :max_breadcrumbs, 0..100
    seconds_setting :flush_interval
    seconds_setting :shutdown_timeout
    seconds_setting :open_timeout
    seconds_setting :read_timeout

    def initialize
      assign_list_defaults
      assign_delivery_defaults
      assign_behaviour_defaults
    end

    def api_key
      @api_key || EnvFlag.present("GOODSORCERY_API_KEY") || rails_credentials_api_key
    end

    def endpoint
      (@endpoint || EnvFlag.present("GOODSORCERY_ENDPOINT") || Defaults::ENDPOINT).to_s.chomp("/")
    end

    def environment
      (@environment || EnvFlag.present("GOODSORCERY_ENV") || rails_env ||
        EnvFlag.present("RACK_ENV") || EnvFlag.present("APP_ENV") || "development").to_s
    end

    def release
      return @release.to_s[0, ReleaseDetector::MAX_LENGTH] if @release

      @detected_release = ReleaseDetector.new(root).release unless defined?(@detected_release)
      @detected_release
    end

    def enabled
      @enabled.nil? ? EnvFlag.parse(ENV.fetch("GOODSORCERY_ENABLED", nil)) : @enabled
    end

    def enabled=(value)
      unless [true, false, nil].include?(value)
        raise ArgumentError, "enabled must be true, false or nil (got #{value.inspect})"
      end

      @enabled = value
    end

    def delivery=(value)
      @delivery = DeliverySetting.normalize(value)
    end

    def before_send=(callable)
      unless callable.nil? || callable.respond_to?(:call)
        raise ArgumentError, "before_send must respond to #call (or be nil)"
      end

      @before_send = callable
    end

    def masked_api_key
      MaskedKey.new(api_key).to_s
    end

    def delivery_settings
      DELIVERY_SETTINGS.to_h { |name| [name, public_send(name)] }
    end

    private

    def assign_list_defaults
      @disabled_environments = Defaults::DISABLED_ENVIRONMENTS.dup
      @enabled_environments = nil
      @filter_params = Defaults::FILTER_PARAMS.dup
      @ignore_exceptions = Defaults::IGNORE_EXCEPTIONS.dup
      @extra_filters = []
      @tags = {}
    end

    def assign_delivery_defaults
      @delivery = :async
      @batch_size = 25
      @flush_interval = 2.0
      @max_queue_size = 1_000
      @shutdown_timeout = 5
      @max_retries = 3
      @open_timeout = 2
      @read_timeout = 5
      @active_job_queue = "default"
    end

    def assign_behaviour_defaults
      @filter_mode = :mask
      @use_rails_filter_parameters = true
      @user_method = :current_user
      @send_code_context = true
      @breadcrumbs = true
      @max_breadcrumbs = 40
      @install_check = :verify
      @report_handled_errors = true
      @root = Dir.pwd
      @logger = ::Logger.new($stderr, level: ::Logger::WARN)
    end

    def rails_env
      ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env
    end

    def rails_credentials_api_key
      return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

      ::Rails.application.credentials.dig(:goodsorcery, :api_key)
    rescue StandardError
      nil
    end
  end

  # Normalizes and validates config.delivery.
  module DeliverySetting
    def self.normalize(value)
      symbol = value.is_a?(String) ? value.to_sym : value
      return symbol if Configuration::DELIVERIES.include?(symbol)
      return value if !value.is_a?(Symbol) && value.respond_to?(:deliver)

      raise ArgumentError, "delivery must be one of #{Configuration::DELIVERIES.map(&:inspect).join(", ")} " \
                           "or an object responding to #deliver (got #{value.inspect})"
    end
  end
end
