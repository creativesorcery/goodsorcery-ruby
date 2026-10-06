# goodsorcery (Ruby client): design

The `goodsorcery` gem reports exceptions from Ruby and Rails apps to a Good Sorcery error tracker (`../error_tracker`). The payload it sends is specified in `error_tracker/docs/INGEST_API.md`. This document is the binding blueprint for the gem and for the server changes made alongside it.

## 1. Research: how other error-tracking gems deliver events

| Gem | Default delivery | Other options | Batching | Notes |
|---|---|---|---|---|
| sentry-ruby | In-process background worker (thread pool via concurrent-ruby, `background_worker_threads`, bounded queue `background_worker_max_queue`, drops when full) | `config.async` lambda to hand events to ActiveJob/Sidekiq (**deprecated in v5**: it serialised events into the job store, recursed when the job system itself failed, and lost the request's thread context); `background_worker_threads = 0` makes it synchronous | Envelopes can carry several items; client reports and sessions are aggregated and flushed on an interval | Respects `429` + `Retry-After` / `X-Sentry-Rate-Limits` by pausing categories |
| honeybadger | Single worker thread with a bounded queue (`max_queue_size`, drops when full); throttles itself on `429` and backs off on `5xx` | `backend: :test` (in-memory, for app test suites), `:debug`, `:null`, `:server`; `send_data_at_exit`; `honeybadger test` CLI sends a test exception | Insights events are batched (`events.batch_size`, `events.timeout`); errors go one per request | `development_environments` (default `development test cucumber`) disables reporting |
| airbrake-ruby | Async thread pool (`workers`, `queue_size`) | `Airbrake.notify_sync` | Performance stats are aggregated and flushed every 15 s | `ignore_environments`; `blocklist_keys` accepts strings, symbols **and regexps** |
| bugsnag | `delivery_method :thread_queue` (one background thread) | `:synchronous` | No | `enabled_release_stages`; `redacted_keys` accepts strings and regexps |
| rollbar | Synchronous by default | `use_async` with handlers for Sidekiq, Resque, DelayedJob, SuckerPunch, ActiveJob, threads | No | Async handlers push the (already scrubbed) payload into the job store |

Conclusions:

1. **The best default is an in-process, bounded, non-blocking background thread.** It costs the request nothing, needs no infrastructure, survives the job system being down, and every major gem converged on it (Sentry moved *away* from job-based delivery).
2. **Batching pays off at volume.** One HTTPS request (with keep-alive and gzip) per batch instead of per event cuts TLS/HTTP overhead, server request-rate pressure and socket churn when an incident produces hundreds of errors a second. Nobody batches errors today mostly for historical reasons: their ingest APIs accept one event per request. We control the server, so we add a batch endpoint.
3. **The queue must be bounded and drop rather than block**, and the worker must handle `429` (`Retry-After`) and `5xx` with backoff, re-using `event_id` for idempotent retries.
4. **Fork safety matters** (Puma cluster, Unicorn, Sidekiq Enterprise swarm, Resque): threads don't survive `fork`, so the worker must start lazily and restart in a forked child.
5. **A synchronous mode** is needed for short-lived processes (scripts, rake tasks, Lambda) and for debugging.
6. **Job-based delivery** is still useful when an app insists on durable delivery via its existing queue, but it puts scrubbed error data into the job store, so it is opt-in, documented as such, and falls back to the background thread if enqueueing fails.
7. **An in-memory test delivery** lets app test suites assert on reported errors without network.

## 2. Delivery options (`config.delivery`)

| Option | Behaviour | When to use |
|---|---|---|
| `:async` (default) | Events are built and filtered in the calling thread, then pushed onto a bounded in-memory queue. One background thread (`goodsorcery-worker`) sends them in **batches** to `POST /api/v1/events/batch` when `batch_size` events are waiting or `flush_interval` seconds have passed, whichever comes first. Keep-alive HTTP connection, gzip. Drops (and counts) events when the queue is full. Flushed at exit. | Web apps and job workers (almost everyone). |
| `:sync` | Sends each event immediately to `POST /api/v1/events` in the calling thread, with short timeouts. | Scripts, rake tasks, serverless, debugging. |
| `:active_job` | Enqueues `GoodSorcery::DeliveryJob` with the already-filtered event JSON; the job sends it synchronously and retries `429`/`5xx` with ActiveJob's `retry_on`. Falls back to `:async` if enqueueing raises. Errors raised inside the delivery job are never reported (no recursion). | Apps that want delivery to survive process crashes and already run a durable queue. **Note:** filtered event data is stored in the job backend (e.g. Redis). |
| `:test` | Stores event hashes in memory (`GoodSorcery.test_events`). Never touches the network. Bypasses the environment check, because nothing leaves the process. | App test suites. |
| any object | Must respond to `deliver(event_hash)`; may respond to `flush(timeout)` and `shutdown(timeout)`. | Custom transports. |

Async tuning (all optional):

| Setting | Default | Meaning |
|---|---|---|
| `batch_size` | `25` | Events per request (server maximum 100). |
| `flush_interval` | `2.0` s | Longest an event waits before being sent. |
| `max_queue_size` | `1_000` | Events held in memory; beyond this new events are dropped and counted. |
| `shutdown_timeout` | `5` s | How long `at_exit` waits to drain the queue. |
| `max_retries` | `3` | Retries for a batch on `5xx`/network errors (exponential backoff with jitter, capped at 60 s). `429` pauses the worker until `Retry-After` passes and does not consume a retry. |

## 3. Configuration

```ruby
# config/initializers/goodsorcery.rb
GoodSorcery.configure do |config|
  # Credentials. Default lookup order: ENV["GOODSORCERY_API_KEY"], then
  # Rails.application.credentials.dig(:goodsorcery, :api_key).
  config.api_key  = Rails.application.credentials.dig(:goodsorcery, :api_key)
  # Default: ENV["GOODSORCERY_ENDPOINT"] || "https://errors.goodsorcery.dev"
  config.endpoint = "https://errors.example.com"

  # Environments. Default environment: ENV["GOODSORCERY_ENV"] || Rails.env || RACK_ENV || APP_ENV || "development".
  config.environment = Rails.env
  config.disabled_environments = %w[development test]   # the default
  # config.enabled_environments = %w[production staging] # allow-list; nil (default) = every env not disabled
  # config.enabled = false                               # hard override; also ENV["GOODSORCERY_ENABLED"]=0/1

  # Filtering. Strings and symbols match a whole key (case-insensitive, "-" and "_" equivalent);
  # regexps match any part of a key. Sane defaults; add with +=, remove with -=, replace with =.
  config.filter_params += %i[card_token ssn]
  config.filter_params += [/_key\z/i, /secret_key/i]
  # config.filter_params = [/password/i]               # replace the defaults entirely
  # config.filter_mode = :mask                          # :mask (default) => "[FILTERED]", :remove => key dropped
  # config.use_rails_filter_parameters = true           # default: also apply Rails.application.config.filter_parameters

  # Delivery
  config.delivery = :async   # :async (default), :sync, :active_job, :test, or a custom object
  # config.batch_size = 25; config.flush_interval = 2.0; config.max_queue_size = 1_000

  # Everything else is optional.
  # config.release = ENV["GIT_SHA"]                     # auto-detected (see 3.3)
  # config.ignore_exceptions += ["MyApp::NotFound"]     # class names; subclasses are ignored too
  # config.before_send = ->(event) { event }            # mutate or return nil to drop
  # config.tags = { region: "eu" }
  # config.user_method = :current_user                  # controller method used to find the user
  # config.send_code_context = true
  # config.breadcrumbs = true; config.max_breadcrumbs = 40
  # config.install_check = :verify                      # bundle-install check: :verify, :test_event or false
end
```

### 3.1 Credentials

`api_key` is the per-environment ingest key (`gs_live_…`/`gs_test_…`), sent as `Authorization: Bearer <key>`. It is never logged in full: logs and the install check show a masked form (`gs_test_…e81a`). A missing key disables delivery and logs one warning (only in an enabled environment).

### 3.2 Environment gating

`GoodSorcery.enabled?` is true when, in order:

1. `config.enabled` (or `GOODSORCERY_ENABLED`) is set → that value;
2. else `enabled_environments` is set → `environment` is in it;
3. else → `environment` is not in `disabled_environments` (default `%w[development test]`).

When disabled, `notify` returns `nil` immediately: no event is built, no thread starts. The `:test` delivery bypasses the check.

### 3.3 Release detection

`config.release`, else the first present of `GOODSORCERY_RELEASE`, `KAMAL_VERSION`, `HEROKU_SLUG_COMMIT`, `HEROKU_BUILD_COMMIT`, `RENDER_GIT_COMMIT`, `GIT_COMMIT`, `GIT_SHA`, `SOURCE_VERSION`, else the contents of `REVISION` in the app root (Capistrano). Truncated to 64 chars. No shelling out to git.

### 3.4 Default filter list

Mirrors Rails' generated `filter_parameters` plus the server's scrub list, so data is filtered client-side first (the server scrubs again as a second layer):

```ruby
DEFAULT_FILTER_PARAMS = [
  /passw/i, /secret/i, /token/i, /_key/i, /api-?key/i, /crypt/i, /salt/i, /certificate/i,
  /otp/i, /ssn/i, /cvv/i, /cvc/i, /authorization/i, /cookie/i, /csrf/i, /xsrf/i,
  /session[-_]?id/i, /credit[-_]?card/i, /card[-_]?number/i, /signature/i, /email/i
].freeze
```

Filtering applies to keys at any depth in: `request.params`, `request.headers`, `request.session`, the query string of `request.url`, `context`, `breadcrumbs[].data`, `tags` and anything passed to `notify(context:)`. It does **not** apply to the `user` object (its `id`, `email`, `username` and `name` exist to identify affected users; don't set the ones you don't want sent). Values are masked as `"[FILTERED]"` (or the key removed with `filter_mode = :remove`). In Rails apps, `Rails.application.config.filter_parameters` is applied as well via `ActiveSupport::ParameterFilter` (with Rails' own matching rules), unless `use_rails_filter_parameters = false`.

## 4. Install check on `bundle install` (development)

The gem ships a Bundler plugin (`plugins.rb` at the gem root). Apps opt in with one Gemfile line (the generator adds it):

```ruby
gem "goodsorcery"
plugin "goodsorcery"   # runs a connectivity/credentials check after `bundle install` in development
```

After every `bundle install`, the plugin's `after-install-all` hook runs **only when all hold**: `RAILS_ENV`/`RACK_ENV`/`APP_ENV` are unset or `development`; `CI` is unset; `GOODSORCERY_SKIP_INSTALL_CHECK` is unset; `goodsorcery` is among the Gemfile dependencies. It spawns `bundle exec ruby -e 'require "goodsorcery/install_check"; …'` in the app root with a 30 s timeout. That process boots the app (`config/environment.rb` if present, so the initializer's config is used; otherwise env vars only) and, per `config.install_check`:

- `:verify` (default): prints a short report (endpoint, environment, enabled or not and why, delivery, masked key), then calls `GET /api/v1/verify` to confirm the endpoint is reachable and the key valid. No event is created.
- `:test_event`: also sends a real test exception synchronously (`GoodSorcery::TestError`), even though development is disabled.
- `false`: skipped.

The check never fails or slows down `bundle install` beyond the timeout: every error is caught and printed as one `[goodsorcery]` line. `bin/rails goodsorcery:verify` and `bin/rails goodsorcery:test` run the same checks on demand (`goodsorcery:test` always sends a test event).

For the gem's own development environment, `bin/setup` runs `bundle install` and then the test suite.

## 5. Integrations

- **Rack middleware** `GoodSorcery::Rack::Middleware`: opens a fresh scope per request (context, user, tags, breadcrumbs are fiber-local), keeps a reference to `env` and builds the request section only if an error is reported. Reports exceptions that propagate, and `env["action_dispatch.exception"]`/`env["sinatra.error"]` for 5xx responses. Re-raises.
- **Rails** (`GoodSorcery::Railtie`): sets defaults from Rails (`root`, `environment`, `logger`, filter parameters), inserts the middleware after `ActionDispatch::ShowExceptions`, subscribes to `Rails.error` (unhandled → `error`; handled → mapped severity, opt-out with `report_handled_errors = false`), adds the ActiveJob layer (§5.1), breadcrumbs from `ActiveSupport::Notifications` (controller, sql without `SCHEMA`/`CACHE`, job, mailer), rake tasks and the `goodsorcery:install` generator.
- **Sidekiq** (if loaded): server middleware opens a scope with the Sidekiq job layer (§5.1); error handler as a fallback. Every exception is reported once (the exception object is marked when reported).
- **Rake**: unhandled task exceptions are reported with `transaction = "rake <task>"` and flushed before the process exits.
- **User**: `GoodSorcery.user = { id:, email:, username:, name: }`, or in Rails the controller's `user_method` (default `current_user`), falling back to `Current.user`. Only those four fields are sent.

Default `ignore_exceptions`: `AbstractController::ActionNotFound`, `ActionController::BadRequest`, `ActionController::InvalidAuthenticityToken`, `ActionController::InvalidCrossOriginRequest`, `ActionController::MethodNotAllowed`, `ActionController::NotImplemented`, `ActionController::ParameterMissing`, `ActionController::RoutingError`, `ActionController::UnknownFormat`, `ActionController::UnknownHttpMethod`, `ActionDispatch::Http::MimeNegotiation::InvalidType`, `ActionDispatch::Http::Parameters::ParseError`, `ActiveRecord::RecordNotFound`, `CGI::Session::CookieStore::TamperedWithCookie`, `Rack::QueryParser::InvalidParameterError`, `Rack::QueryParser::ParameterTypeError`, `Sinatra::NotFound`, `SignalException`, `SystemExit`.

### 5.1 Layers: what each part of a Rails app contributes

An error is reported with the data of the layer it happened in. Each layer opens a fresh scope, so data never leaks between requests, jobs or channel actions, and everything below is filtered with `filter_params` (and Rails' `filter_parameters`) before it leaves the process.

| Layer | `transaction` | Section sent | Data |
|---|---|---|---|
| Action Controller / Rack | `UsersController#update` | `request` | `url` (query filtered), `method`, `format`, `request_id`, `remote_ip`, `params` (path + query + body params as Rails parsed them), `headers`, `session` (only if already loaded), plus `context.controller` = `{controller, action}` |
| Active Job (any adapter) | job class, e.g. `ChargeCustomerJob` | `job` | `framework: "active_job"`, `class`, `id`, `provider_job_id`, `queue`, `priority`, `executions`, `enqueued_at`, `scheduled_at`, `arguments` |
| Action Mailer `deliver_later` | `UserMailer#welcome` | `job` | as Active Job, with `mailer` and `action`; `arguments` are the mailer method's args/params |
| Sidekiq (jobs not wrapped by Active Job) | worker class | `job` | `framework: "sidekiq"`, `class`, `id` (jid), `queue`, `retry_count`, `enqueued_at`, `arguments` (`args`) |
| Action Cable | `ChatChannel#speak` | `request` | connection `url`, `request_id`, `remote_ip`, `headers`; `params` = `{ "channel" => <subscription params>, "data" => <action data> }` |
| Rake | `rake db:migrate` | `context.rake` | task name and its arguments (`Rake::TaskArguments#to_h`) |
| `Rails.error.report` / `handle` | unchanged | `context.rails_error` | the `context:` hash given to the reporter, plus `source` |
| Anywhere | — | `context`, `tags`, `user` | whatever the app adds with `GoodSorcery.context`, `tags`, `user=` |

**Job arguments** are serialised the way the job system would see them, without loading anything: Active Record/GlobalID objects become their GlobalID string (`"gid://shop/Customer/88123"`), hashes keep their keys (so key filtering applies at any depth), symbols become strings, times become ISO 8601, any other object becomes a truncated `#inspect`-free placeholder `"#<ClassName>"`. Arrays, depth and string sizes are capped like `request.params`. Key filtering cannot protect a secret passed as a bare positional argument (`perform(user_id, "s3cr3t")`), so arguments can be turned off:

```ruby
config.send_job_arguments = true          # default; false = never send job arguments
class ChargeCustomerJob < ApplicationJob
  goodsorcery_arguments false             # per Active Job class (also inherited)
end
class LegacyWorker
  include Sidekiq::Job
  sidekiq_options goodsorcery_arguments: false
end
```

The other layers have equivalent switches: `config.send_request_params`, `send_request_headers`, `send_session` (all default `true`).

## 6. Public API

```ruby
GoodSorcery.notify(exception_or_message, context: {}, tags: {}, user: nil, level: nil,
                   fingerprint: nil, transaction: nil)        # => event_id (String) or nil
GoodSorcery.with_context(hash) { ... }                         # scoped context
GoodSorcery.context(hash)                                      # merge into current scope
GoodSorcery.user = { id: 1, email: "…" }
GoodSorcery.tags(hash)
GoodSorcery.add_breadcrumb(message, category: "custom", level: "info", data: {})
GoodSorcery.flush(timeout = 5)                                 # drain the async queue
GoodSorcery.verify                                             # => GoodSorcery::Verification (ok?, message)
GoodSorcery.test_events / GoodSorcery.clear_test_events        # with delivery :test
```

`notify` never raises (internal errors are logged and swallowed) and does the minimum work in the caller: build, filter, `before_send`, enqueue.

## 7. Server changes (error_tracker)

- `POST /api/v1/events/batch`: body `{"events":[…]}` with 1–100 events; body ≤ 2 MiB (compressed and decompressed); each event is validated exactly like the single endpoint and must re-serialise to ≤ 512 KiB. Same auth, gzip, quota, media-type rules. Per-key and per-account rate limits count **events** (a batch of N consumes N; the single endpoint consumes 1, sharing counters); over the limit the whole batch gets `429` + `Retry-After`. Accepted events are stored as encrypted `InboundEvent`s in one transaction and enqueued with one bulk enqueue (`ActiveJob.perform_all_later`). Response `202 {"accepted":[{"index":0,"id":"…"}],"rejected":[{"index":3,"error":"invalid_payload","messages":["…"]}]}`; if nothing was accepted, the same body with `422`.
- `GET /api/v1/verify`: authenticates the key (same rate limiting by IP and key) and returns `200 {"ok":true,"environment":"staging"}` without creating anything. Used by the install check.
- **`job` payload section.** The ingest payload gains a top-level `job` object (the fields in §5.1; unknown keys dropped, `arguments` bounded like `request.params`, scrubbed by key like params, stored **encrypted** with the occurrence). The issue page gets a **Job** tab next to Request/Params/Headers/Session/Environment showing the job fields and its arguments as JSON (muted `[FILTERED]`, like Params). It shows "No job was captured with this occurrence." when absent. `docs/INGEST_API.md` documents the field and its limits.

