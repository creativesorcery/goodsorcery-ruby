# frozen_string_literal: true

# Good Sorcery error reporting. Every setting is optional; the defaults are
# shown. See https://errors.goodsorcery.dev and the goodsorcery README.
GoodSorcery.configure do |config|
  # --- Credentials -----------------------------------------------------------
  # Looked up in ENV["GOODSORCERY_API_KEY"], then in Rails credentials
  # (goodsorcery.api_key). Use one key per environment. Never commit it.
  # config.api_key = Rails.application.credentials.dig(:goodsorcery, :api_key)
  # config.endpoint = "https://errors.goodsorcery.dev"   # or ENV["GOODSORCERY_ENDPOINT"]

  # --- Environments ----------------------------------------------------------
  # config.environment = Rails.env                       # or ENV["GOODSORCERY_ENV"]
  # config.disabled_environments = %w[development test]
  # config.enabled_environments = %w[production staging] # allow-list instead
  # config.enabled = true                                # hard override; or GOODSORCERY_ENABLED=1/0

  # --- Filtering -------------------------------------------------------------
  # Strings/symbols match whole keys (case-insensitive, "-" and "_" equal);
  # regexps match any part of a key. Rails' filter_parameters apply too.
  # config.filter_params += %i[card_token ssn]
  # config.filter_params += [/_key\z/i]
  # config.filter_mode = :mask                           # or :remove
  # config.use_rails_filter_parameters = true
  # config.send_request_params = true
  # config.send_request_headers = true
  # config.send_session = true
  # config.send_job_arguments = true                     # false = never send job arguments

  # --- Delivery --------------------------------------------------------------
  # config.delivery = :async                             # :sync, :active_job, :test or a custom object
  # config.batch_size = 25
  # config.flush_interval = 2.0
  # config.max_queue_size = 1_000
  # config.max_retries = 3
  # config.shutdown_timeout = 5
  # config.open_timeout = 2
  # config.read_timeout = 5
  # config.active_job_queue = "default"                  # with delivery = :active_job

  # --- What gets reported ----------------------------------------------------
  # config.release = ENV["GIT_SHA"]                      # auto-detected from deploy env vars or REVISION
  # config.ignore_exceptions += ["MyApp::NotFound"]      # class names; subclasses too
  # config.before_send = ->(event) { event }             # change the event, or return nil to drop it
  # config.tags = { region: "eu" }
  # config.user_method = :current_user                   # controller method that returns the user
  # config.report_handled_errors = true                  # Rails.error.handle / report
  # config.send_code_context = true
  # config.breadcrumbs = true
  # config.max_breadcrumbs = 40

  # --- Development -----------------------------------------------------------
  # config.install_check = :verify                       # after bundle install: :verify, :test_event or false
  # config.logger = Rails.logger
end
