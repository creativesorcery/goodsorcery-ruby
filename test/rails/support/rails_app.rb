# frozen_string_literal: true

# A minimal in-memory Rails app, booted once per test process.
require "test_helper"
require "rails"
require "action_controller/railtie"
require "action_mailer/railtie"
require "active_job/railtie"
require "action_cable/engine"
require "goodsorcery/railtie"

module GoodSorceryTestApp
  ROOT = Dir.mktmpdir("goodsorcery-rails-app")
  REVISION = "4f2a9c1e"
  File.write(File.join(ROOT, "REVISION"), "#{REVISION}\n")

  class OrderError < StandardError; end
  class HandledError < StandardError; end

  # A signed-in user with more attributes than the four that may be sent.
  UserRecord = Struct.new(:id, :email, :username, :name, :password_digest)

  # A record that ActiveJob serialises through GlobalID, without a database.
  class Customer
    include GlobalID::Identification

    attr_reader :id

    def self.find(id) = new(id)

    def initialize(id)
      @id = id.to_i
    end
  end

  class Application < Rails::Application
    config.root = ROOT
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "a" * 64
    config.hosts.clear
    config.consider_all_requests_local = false
    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :test
    config.filter_parameters += [:internal_note]
  end
end

GoodSorceryTestApp::Application.initialize!
ActionCable.server.config.cable = { "adapter" => "test" }
ActiveJob::Base.logger = Logger.new(nil)

class OrdersController < ActionController::Base
  def create
    GoodSorcery.context(order_ref: "A-1")
    sql = "SELECT * FROM orders WHERE email = 'm@x.dev' LIMIT 1"
    ActiveSupport::Notifications.instrument("sql.active_record", sql: sql, name: "Order Load")
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "PRAGMA table_info", name: "SCHEMA")
    session[:cart_id] = 5
    session[:auth_token] = "t0k"
    raise GoodSorceryTestApp::OrderError, "payment failed"
  end

  def show
    params.require(:id)
    raise GoodSorceryTestApp::OrderError, "no session touched"
  end

  def handled
    Rails.error.handle(context: { order_id: 7, card_number: "4111" }) do
      raise GoodSorceryTestApp::HandledError, "soft failure"
    end
    head :ok
  end

  def leak
    GoodSorcery.context(leak: true)
    GoodSorcery.user = { id: 9 }
    head :ok
  end

  def missing
    raise ActionController::RoutingError, "nope"
  end

  private

  def current_user
    GoodSorceryTestApp::UserRecord.new(42, "mara@example.com", "mara", "Mara Lind", "$2a$12$hash")
  end
end

Rails.application.routes.draw do
  post "/orders" => "orders#create"
  get "/orders/:id" => "orders#show"
  get "/handled" => "orders#handled"
  get "/leak" => "orders#leak"
  get "/missing" => "orders#missing"
end
