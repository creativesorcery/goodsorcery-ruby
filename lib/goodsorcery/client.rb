# frozen_string_literal: true

module GoodSorcery
  # Wires configuration to the event pipeline and the delivery. One client
  # per process, built lazily; GoodSorcery.configure rebuilds its parts.
  class Client
    NETWORK_DELIVERIES = %i[async sync active_job].freeze
    REPORTING_KEY = :__goodsorcery_reporting

    attr_reader :config, :log

    def initialize(config, log)
      @config = config
      @log = log
      @lock = Monitor.new
      @gate = EnvironmentGate.new(config)
    end

    # => the event id, or nil when nothing was sent. Never raises. An error
    # reported while a report is being built on the same thread (from
    # before_send, the user lookup or a logger that reports errors) is
    # dropped instead of recursing.
    def notify(error, **options)
      return nil unless reporting? && !Thread.current[REPORTING_KEY]

      while_reporting { report(error, options) }
    end

    # Builds, filters and runs before_send, without any gating.
    def prepare_event(exception, options = {})
      scope = Scope.current
      enrich(scope)
      pipeline.prepare(exception, options, scope)
    end

    def reporting?
      return true if test_delivery?

      @gate.enabled? && credentials_present?
    end

    def enabled?
      @gate.enabled?
    end

    def disabled_reason
      @gate.reason
    end

    def add_breadcrumb(message, category: "custom", level: "info", data: nil)
      return nil unless collecting_breadcrumbs?

      crumb = Event::Breadcrumb.build(message, category: category, level: level, data: data)
      Scope.current.add_breadcrumb(crumb, config.max_breadcrumbs)
      nil
    rescue StandardError => e
      log.warn_every(:breadcrumb_error, 60, "could not record a breadcrumb (#{e.class})")
      nil
    end

    # Whether breadcrumbs are recorded at all, so integrations can skip
    # building them.
    def collecting_breadcrumbs?
      config.breadcrumbs && config.max_breadcrumbs.positive? && (test_delivery? || @gate.enabled?)
    end

    def flush(timeout = 5)
      @delivery ? @delivery.flush(timeout) : true
    end

    def shutdown(timeout = config.shutdown_timeout)
      @delivery ? @delivery.shutdown(timeout) : true
    end

    def verify
      Verification.run(config, transport)
    end

    def test_events
      delivery.is_a?(Delivery::Test) ? delivery.events : []
    end

    def clear_test_events
      delivery.clear if delivery.is_a?(Delivery::Test)
    end

    def reconfigure(rebuild_delivery:)
      old_delivery = @lock.synchronize { reset_components(rebuild_delivery) }
      old_delivery&.shutdown(config.shutdown_timeout)
    end

    def delivery
      @delivery || @lock.synchronize do
        @delivery ||= Delivery.build(config, self)
      end
    end

    def transport
      @transport || @lock.synchronize { @transport ||= build_transport }
    end

    def serializer
      @serializer ||= EventSerializer.new(log)
    end

    private

    def while_reporting
      Thread.current[REPORTING_KEY] = true
      yield
    ensure
      Thread.current[REPORTING_KEY] = nil
    end

    def report(error, options)
      exception = ExceptionCoercion.coerce(error)
      return nil if skip?(exception)

      ReportedMark.mark(exception)
      event = prepare_event(exception, options)
      return nil unless event

      delivery.deliver(event) == false ? nil : event["event_id"]
    rescue StandardError => e
      log.error("notify failed with #{e.class}; the error was not reported")
      nil
    end

    def pipeline
      @pipeline || @lock.synchronize { @pipeline ||= EventPipeline.new(config, log) }
    end

    def ignore_list
      @ignore_list || @lock.synchronize { @ignore_list ||= IgnoreList.new(config.ignore_exceptions) }
    end

    def enrich(scope)
      scope.enrich
    rescue StandardError => e
      log.warn_every(:enrich_error, 60, "could not read request or job details (#{e.class})")
    end

    def skip?(exception)
      ReportedMark.reported?(exception) || exception.is_a?(RetryableDeliveryError) || ignore_list.ignore?(exception)
    end

    def test_delivery?
      config.delivery == :test
    end

    def credentials_present?
      return true unless NETWORK_DELIVERIES.include?(config.delivery)
      return true unless config.api_key.to_s.empty?

      log.warn_once(:missing_api_key,
                    "no API key configured (GOODSORCERY_API_KEY or config.api_key); errors are not sent")
      false
    end

    def build_transport
      Transport.new(endpoint: config.endpoint, api_key: config.api_key, open_timeout: config.open_timeout,
                    read_timeout: config.read_timeout, log: log)
    end

    # Returns the delivery to shut down, if it is being replaced.
    def reset_components(rebuild_delivery)
      @pipeline = nil
      @ignore_list = nil
      return nil unless rebuild_delivery

      old_delivery = @delivery
      @transport&.close
      @delivery = nil
      @transport = nil
      old_delivery
    end
  end
end
