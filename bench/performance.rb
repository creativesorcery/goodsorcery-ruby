# frozen_string_literal: true

# Measures the per-request cost of performance monitoring (DESIGN.md 8.8):
# a dummy Rails request that runs 50 queries, with monitoring off and on.
# Run with `bundle exec rake bench:performance`; not part of the test suite.
require "bundler/setup"
require "logger"
require "rails"
require "action_controller/railtie"
require "rack/mock_request"
require "goodsorcery"
require "goodsorcery/railtie"

# A minimal Rails app with one action that runs 50 queries.
module PerformanceBench
  # The app.
  class Application < Rails::Application
    config.root = __dir__
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "b" * 64
    config.hosts.clear
  end
  Application.initialize!

  # The measured action.
  class BenchController < ActionController::Base
    SQL = 'SELECT "products".* FROM "products" WHERE "products"."id" = $1 LIMIT $2'

    def index
      50.times { ActiveSupport::Notifications.instrument("sql.active_record", sql: SQL, name: "Product Load") }
      render plain: "ok"
    end
  end
end

Rails.application.routes.draw { get "/" => "performance_bench/bench#index" }

# Times +count+ requests after a warm-up; => microseconds per request.
def per_request(count)
  request = Rack::MockRequest.new(Rails.application)
  200.times { request.get("/") }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  count.times { request.get("/") }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / count * 1_000_000
end

COUNT = Integer(ENV.fetch("COUNT", "3000"))
off = per_request(COUNT)
GoodSorcery.configure do |config|
  config.delivery = :test
  config.performance_monitoring = true
end
GoodSorcery::Performance.install
on = per_request(COUNT)

puts format("YJIT %<yjit>s, %<count>d requests with 50 queries each", yjit: defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?,
                                                                      count: COUNT)
puts format("monitoring off: %<off>.1f µs/request", off: off)
puts format("monitoring on:  %<on>.1f µs/request (+%<delta>.1f µs, %<per_span>.2f µs per query)",
            on: on, delta: on - off, per_span: (on - off) / 50)
