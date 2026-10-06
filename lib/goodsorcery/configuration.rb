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

    attr_writer :api_key, :environment, :release, :logger, :root
    attr_accessor :disabled_environments, :enabled_environments, :filter_params,
                  :use_rails_filter_parameters, :extra_filters, :ignore_exceptions, :tags,
                  :user_method, :send_code_context, :breadcrumbs,
                  :report_handled_errors, :active_job_queue, :request_extractor,
                  :send_request_params, :send_request_headers, :send_session, :send_job_arguments
    attr_reader :delivery, :filter_mode, :batch_size, :flush_interval, :max_queue_size,
                :shutdown_timeout, :max_retries, :open_timeout, :read_timeout,
                :max_breadcrumbs, :install_check, :before_send

    endpoint_setting
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

    # The endpoint without any user:password part, for logs and reports.
    def endpoint_label
      endpoint.sub(%r{(?<=://)[^/@]*@}, "")
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

    # Rails.root in Rails apps, else the working directory.
    def root
      (@root || rails_root || Dir.pwd).to_s
    end

    # Rails.logger in Rails apps, else WARN and above to $stderr.
    def logger
      @logger || rails_logger || (@default_logger ||= ::Logger.new($stderr, level: ::Logger::WARN))
    end

    # The key filter's companions: Rails' filter_parameters (unless turned
    # off), then config.extra_filters.
    def event_filters
      rails = use_rails_filter_parameters ? RailsFilterParameters.build : nil
      [rails, *extra_filters].compact
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

    # Never shows the API key (or endpoint credentials): consoles, error
    # pages and loggers print objects with #inspect.
    def inspect
      delivery_name = delivery.is_a?(Symbol) ? delivery.inspect : delivery.class.name
      "#<#{self.class.name} api_key=#{masked_api_key} endpoint=#{endpoint_label} " \
        "environment=#{environment} delivery=#{delivery_name}>"
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
      assign_capture_defaults
    end

    def assign_capture_defaults
      @send_request_params = true
      @send_request_headers = true
      @send_session = true
      @send_job_arguments = true
    end

    def rails_app?
      defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
    end

    def rails_root
      ::Rails.root if rails_app? && ::Rails.respond_to?(:root)
    end

    def rails_logger
      ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
    end

    def rails_env
      ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env
    end

    def rails_credentials_api_key
      return unless rails_app?

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
                           "or an object responding to #deliver (got a #{value.class})"
    end
  end
end
