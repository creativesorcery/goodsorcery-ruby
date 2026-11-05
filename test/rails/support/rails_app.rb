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

  # Templates for the performance tests (written before boot, so the view
  # path exists).
  VIEWS = File.join(ROOT, "app/views")
  FileUtils.mkdir_p(File.join(VIEWS, "perf"))
  FileUtils.mkdir_p(File.join(VIEWS, "perf_mailer"))
  File.write(File.join(VIEWS, "perf/show.html.erb"),
             "<h1><%= @name %></h1><%= render partial: \"perf/row\", collection: [1, 2, 3] %>")
  File.write(File.join(VIEWS, "perf/_row.html.erb"), "<p><%= row %></p>")
  File.write(File.join(VIEWS, "perf_mailer/notice.text.erb"), "Hello <%= @name %>")

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

# Controller for the performance tests (test/rails/performance_test.rb).
class PerfController < ActionController::Base
  def show
    2.times { product_query }
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "PRAGMA table_info", name: "SCHEMA")
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "CACHE", cached: true)
    @name = "Lamp"
    render :show
  end

  def boom
    raise GoodSorceryTestApp::OrderError, "perf boom"
  end

  def unavailable
    head :service_unavailable
  end

  # Literals written into the SQL, from a Postgres connection.
  def files
    connection = Struct.new(:adapter_name).new("PostgreSQL")
    sql = "SELECT * FROM files WHERE dir = 'C:\\' AND token = 'hunter2secret'"
    ActiveSupport::Notifications.instrument("sql.active_record", sql: sql, name: "File Load", connection: connection)
    head :ok
  end

  def inline_job
    GoodSorceryTestApp::PerfJob.perform_now
    GoodSorceryTestApp::PerfJob.perform_later
    head :ok
  end

  private

  def product_query
    ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM products WHERE id = 1",
                                                                 name: "Product Load", row_count: 1)
  end
end

module GoodSorceryTestApp
  class PerfJob < ActiveJob::Base
    queue_as :billing

    def perform
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "UPDATE t SET a = 1", name: "T Update")
    end
  end

  class PerfMailer < ActionMailer::Base
    default from: "app@example.com"

    def notice
      @name = "Mara"
      mail(to: "m@example.com", subject: "Hi", template_path: "perf_mailer")
    end
  end
end

Rails.application.routes.draw do
  get "/perf/products/:id" => "perf#show"
  get "/perf/boom" => "perf#boom"
  get "/perf/unavailable" => "perf#unavailable"
  get "/perf/inline_job" => "perf#inline_job"
  get "/perf/files" => "perf#files"
  get "/up" => "rails/health#show"
  post "/orders" => "orders#create"
  get "/orders/:id" => "orders#show"
  get "/handled" => "orders#handled"
  get "/leak" => "orders#leak"
  get "/missing" => "orders#missing"
end
