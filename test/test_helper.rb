# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require "goodsorcery"
require_relative "support/fake_server"
require_relative "support/fake_transport"

module GoodSorceryTestHelpers
  ENV_NAMES = %w[
    GOODSORCERY_API_KEY GOODSORCERY_ENDPOINT GOODSORCERY_ENV GOODSORCERY_ENABLED GOODSORCERY_RELEASE
    GOODSORCERY_SKIP_INSTALL_CHECK RAILS_ENV RACK_ENV APP_ENV CI KAMAL_VERSION HEROKU_SLUG_COMMIT
    HEROKU_BUILD_COMMIT RENDER_GIT_COMMIT GIT_COMMIT GIT_SHA SOURCE_VERSION
  ].freeze

  def setup
    super
    @saved_env = ENV.to_h.slice(*ENV_NAMES)
    ENV_NAMES.each { |name| ENV.delete(name) }
    GoodSorcery.reset!
    @log_output = StringIO.new
    GoodSorcery.configuration.logger = Logger.new(@log_output, level: Logger::DEBUG)
  end

  def teardown
    GoodSorcery.reset!
    ENV_NAMES.each { |name| ENV.delete(name) }
    @saved_env.each { |name, value| ENV[name] = value }
    super
  end

  def log_output
    @log_output.string
  end

  def with_env(values)
    saved = values.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  def raise_and_rescue(error_class = RuntimeError, message = "boom")
    raise error_class, message
  rescue error_class => e
    e
  end

  def wait_until(timeout = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
    true
  end

  def captured_log
    GoodSorcery::Log.new { Logger.new(@log_output, level: Logger::DEBUG) }
  end
end

Minitest::Test.include(GoodSorceryTestHelpers)
