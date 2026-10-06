# frozen_string_literal: true

require "json"
require "logger"
require "monitor"
require "net/http"
require "securerandom"
require "socket"
require "time"
require "uri"
require "zlib"

require_relative "goodsorcery/version"
require_relative "goodsorcery/errors"
require_relative "goodsorcery/log"
require_relative "goodsorcery/defaults"
require_relative "goodsorcery/env_flag"
require_relative "goodsorcery/masked_key"
require_relative "goodsorcery/release_detector"
require_relative "goodsorcery/configuration"
require_relative "goodsorcery/environment_gate"
require_relative "goodsorcery/text"
require_relative "goodsorcery/sanitizer"
require_relative "goodsorcery/key_filter"
require_relative "goodsorcery/event_filter"
require_relative "goodsorcery/scope"
require_relative "goodsorcery/backtrace/parser"
require_relative "goodsorcery/backtrace/paths"
require_relative "goodsorcery/backtrace/line_cache"
require_relative "goodsorcery/backtrace/code_context"
require_relative "goodsorcery/event/fields"
require_relative "goodsorcery/event/exception_section"
require_relative "goodsorcery/event/cause_chain"
require_relative "goodsorcery/event/runtime_context"
require_relative "goodsorcery/event/user_section"
require_relative "goodsorcery/event/tag_set"
require_relative "goodsorcery/event/request_section"
require_relative "goodsorcery/event/breadcrumb"
require_relative "goodsorcery/event/builder"
require_relative "goodsorcery/event_pipeline"
require_relative "goodsorcery/event_serializer"
require_relative "goodsorcery/reported_mark"
require_relative "goodsorcery/ignore_list"
require_relative "goodsorcery/exception_coercion"
require_relative "goodsorcery/transport"
require_relative "goodsorcery/delivery"
require_relative "goodsorcery/verification"
require_relative "goodsorcery/test_event"
require_relative "goodsorcery/client"

# Reports exceptions to a Good Sorcery error tracker. See README.md.
module GoodSorcery
  LOCK = Mutex.new
  @log = Log.new { configuration.logger }

  class << self
    def configuration
      @configuration || LOCK.synchronize { @configuration ||= Configuration.new }
    end

    # Yields the configuration. Rebuilds the delivery when a delivery-related
    # setting changed, and recompiles filters.
    def configure
      before = configuration.delivery_settings
      yield configuration
      client.reconfigure(rebuild_delivery: before != configuration.delivery_settings)
      configuration
    end

    def client
      return @client if @client

      config = configuration
      LOCK.synchronize { @client ||= Client.new(config, log) }
    end

    # The gem's own logger (prefixed, rate-limited; see GoodSorcery::Log).
    attr_reader :log

    # Reports an exception (or a message). => event id, or nil. Never raises.
    def notify(exception_or_message, context: nil, tags: nil, user: nil, level: nil,
               fingerprint: nil, transaction: nil)
      options = { context: context, tags: tags, user: user, level: level,
                  fingerprint: fingerprint, transaction: transaction }.compact
      client.notify(exception_or_message, **options)
    rescue StandardError
      nil
    end

    def enabled?
      client.enabled?
    end

    def scope
      Scope.current
    end

    def clear_scope
      Scope.clear
    end

    # Runs the block with a fresh scope (one request or job), then restores
    # the previous one.
    def with_scope
      previous = Thread.current[Scope::STORAGE_KEY]
      Scope.current = Scope.new
      yield Scope.current
    ensure
      Scope.current = previous
    end

    def with_context(hash, &)
      scope.with_context(hash, &)
    end

    def context(hash)
      scope.merge_context(hash)
    end

    def user=(user)
      scope.user = user
    end

    def tags(hash)
      scope.merge_tags(hash)
    end

    def add_breadcrumb(message, category: "custom", level: "info", data: nil)
      client.add_breadcrumb(message, category: category, level: level, data: data)
    end

    def flush(timeout = 5)
      client.flush(timeout)
    end

    def shutdown(timeout = nil)
      @client&.shutdown(timeout || configuration.shutdown_timeout)
    rescue StandardError
      nil
    end

    def verify
      client.verify
    end

    def test_events
      client.test_events
    end

    def clear_test_events
      client.clear_test_events
    end

    # Forgets configuration, client and the current scope. For tests.
    def reset!
      shutdown(0.5)
      LOCK.synchronize do
        @client = nil
        @configuration = nil
      end
      clear_scope
    end
  end
end
