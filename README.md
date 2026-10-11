# goodsorcery

The Ruby client for the [Good Sorcery](https://app.goodsorcery.com) error tracker. It reports exceptions from Ruby and Rails apps without slowing them down:

- Events are built and filtered in the calling thread, then handed to **one background thread** that sends them in **batches** over a keep-alive, gzip-compressed HTTPS connection.
- Sensitive data is **filtered in-process** before anything leaves your app (the server scrubs again as a second layer).
- The queue is bounded and **drops rather than blocks** when it is full. Rate limits (`429` + `Retry-After`) and server errors are retried with backoff.
- It has no runtime dependencies (standard library only). It needs Ruby 3.2 or newer and works with or without Rails.
- Rails, Rack/Sinatra, Active Job, Action Mailer, Action Cable, Sidekiq and Rake are covered out of the box (see [Integrations](#integrations)).

## Installation

```ruby
# Gemfile
gem "goodsorcery"
```

```sh
bundle install
export GOODSORCERY_API_KEY=gs_live_...   # or use Rails credentials, see below
```

In a Rails app, run the generator. It writes `config/initializers/goodsorcery.rb` (every option, commented out) and, with `--api-key`, stores the key in your encrypted credentials. It never prints the key.

```sh
bin/rails generate goodsorcery:install --api-key=gs_live_...
```

Outside Rails, `require "goodsorcery"` and call `GoodSorcery.configure` once at boot.

## Reporting errors

```ruby
begin
  charge_card!
rescue => e
  GoodSorcery.notify(e, context: { order_id: order.id }, tags: { provider: "stripe" })
  raise
end

GoodSorcery.notify("Inventory sync skipped 3 SKUs", level: :warning)   # a message works too
```

`notify` returns the event id (a String) or `nil` when nothing was sent. It **never raises**: internal errors are logged and swallowed.

```ruby
GoodSorcery.notify(exception_or_message, context: {}, tags: {}, user: nil, level: nil,
                   fingerprint: nil, transaction: nil)   # => event_id or nil
GoodSorcery.with_context(job: "Import") { ... }           # context for the block only
GoodSorcery.context(account_id: 42)                       # merge into the current scope
GoodSorcery.user = { id: 1, email: "mara@example.com" }   # or a User object
GoodSorcery.tags(region: "eu")
GoodSorcery.add_breadcrumb("Cart loaded", category: "custom", level: "info", data: { items: 3 })
GoodSorcery.flush(5)                                      # wait up to 5 s for the queue to drain
GoodSorcery.verify                                        # => GoodSorcery::Verification (ok?, message)
GoodSorcery.test_events / GoodSorcery.clear_test_events   # with delivery :test
GoodSorcery.enabled?                                      # is reporting on in this environment?
```

Context, user, tags, transaction and breadcrumbs belong to the **current scope**, which is local to the thread (and fiber). `GoodSorcery.with_scope { |scope| ... }` runs a block with a fresh scope; `GoodSorcery.clear_scope` resets it. Integrations open one scope per request or job.

The same exception object is only reported once, even when several integrations see it. `level` is one of `fatal`, `error` (the default), `warning` or `info`. `fingerprint` (up to 10 strings) overrides how events are grouped into issues.

## Configuration

```ruby
# config/initializers/goodsorcery.rb
GoodSorcery.configure do |config|
  config.api_key  = Rails.application.credentials.dig(:goodsorcery, :api_key)
  config.endpoint = "https://errors.example.com"
  config.filter_params += %i[card_token]
end
```

Change settings inside `GoodSorcery.configure`: it recompiles the filters and rebuilds the delivery when a delivery setting changed. Invalid values raise `ArgumentError` with a clear message.

| Setting | Default | Notes |
|---|---|---|
| `api_key` | `ENV["GOODSORCERY_API_KEY"]`, then `Rails.application.credentials.dig(:goodsorcery, :api_key)` | Per-environment ingest key. Never logged in full (`inspect` shows it masked). A missing key disables delivery with one warning. |
| `endpoint` | `ENV["GOODSORCERY_ENDPOINT"]` or `https://app.goodsorcery.com` | Your self-hosted URL (`http://` or `https://`; credentials in the URL are refused). `http://` is fine for localhost. |
| `environment` | `ENV["GOODSORCERY_ENV"]`, `Rails.env`, `RACK_ENV`, `APP_ENV`, else `"development"` | Used for gating only; the server takes the environment from the key. |
| `disabled_environments` | `%w[development test]` | Environments that don't report. |
| `enabled_environments` | `nil` | Allow-list; when set, only these report. |
| `enabled` | `ENV["GOODSORCERY_ENABLED"]` (`1`/`0`), else `nil` | Hard override of the environment check. |
| `release` | auto-detected (see below) | Version or commit, up to 64 chars. |
| `root` | `Dir.pwd` (`Rails.root` in Rails) | Makes backtrace paths app-relative and decides which frames are "in app". |
| `filter_params` | see [Filtering](#filtering) | Strings/symbols match whole keys; regexps match any part. |
| `use_rails_filter_parameters` | `true` | Also apply `Rails.application.config.filter_parameters` (Rails integration). |
| `extra_filters` | `[]` | Objects responding to `filter(hash) -> hash`; see [Extension points](#extension-points). |
| `ignore_exceptions` | Rails/Rack routing and 4xx errors, Sidekiq's internal retry signals (`Sidekiq::JobRetry::Handled`, `Sidekiq::JobRetry::Skip`), `SignalException`, `SystemExit` | Class names; subclasses are ignored too. |
| `before_send` | `nil` | `->(event) { event }`. Return a (changed) hash, or `nil` to drop. If it raises, the event is dropped and the error class logged. |
| `tags` | `{}` | Global tags on every event. |
| `user_method` | `:current_user` | Controller method the Rails integration uses to find the user. |
| `send_code_context` | `true` | Source lines (±5) around the top 10 in-app frames. |
| `breadcrumbs` / `max_breadcrumbs` | `true` / `40` | Up to 100. |
| `report_handled_errors` | `true` | Rails integration: also report `Rails.error.handle` errors. |
| `send_request_params` / `send_request_headers` / `send_session` | `true` | Leave those parts of the request out entirely. |
| `send_job_arguments` | `true` | `false` never sends Active Job, mailer or Sidekiq arguments. |
| `install_check` | `:verify` | `:verify`, `:test_event` or `false`; see [Install check](#install-check). |
| `logger` | `Logger.new($stderr)` at `WARN` (`Rails.logger` in Rails) | The gem's own messages, prefixed `[goodsorcery]`. |
| `delivery` | `:async` | See [Delivery](#delivery). |
| `batch_size` | `25` | Events per request, 1–100. |
| `flush_interval` | `2.0` s | Longest an event waits in the queue. |
| `max_queue_size` | `1_000` | Events beyond this are dropped and counted. |
| `max_retries` | `3` | For `5xx`/network failures (exponential backoff with jitter, capped at 60 s). |
| `shutdown_timeout` | `5` s | How long the exit hook waits for the queue to drain. |
| `open_timeout` / `read_timeout` | `2` s / `5` s | HTTP timeouts (writes use `read_timeout`). |
| `active_job_queue` | `"default"` | Queue for `delivery = :active_job`. |

### Delivery

| `config.delivery` | What it does | When to use |
|---|---|---|
| `:async` (default) | Pushes events onto a bounded in-memory queue. One background thread (`goodsorcery-worker`) sends them to `POST /api/v1/events/batch` when `batch_size` events are waiting or `flush_interval` has passed. Restarts after `fork`; drains at exit. | Web apps and job workers (almost everyone). |
| `:sync` | Sends each event immediately in the calling thread. | Scripts, rake tasks, serverless functions, debugging. |
| `:active_job` | Enqueues `GoodSorcery::DeliveryJob` with the filtered event as JSON; the job sends it and retries `429`/`5xx` (5 attempts). Falls back to `:async` if enqueueing fails. **The filtered event is stored in your job backend.** | Apps that want delivery to survive a crash and already run a durable queue. |
| `:test` | Keeps events in memory (`GoodSorcery.test_events`). Never touches the network and ignores the environment check. | Your app's test suite. |
| any object | Must respond to `deliver(event_hash)`; may respond to `flush(timeout)` and `shutdown(timeout)`. | Custom transports. |

### Environments

Reporting is on when, in this order:

1. `config.enabled` (or `GOODSORCERY_ENABLED`) is set: that value wins;
2. else, if `enabled_environments` is set: `environment` is in it;
3. else: `environment` is not in `disabled_environments` (default `development` and `test`).

When reporting is off, `notify` returns `nil` straight away: no event is built and no thread starts.

### Credentials

Use one API key per environment (`gs_live_…` for production, `gs_test_…` otherwise). Keep it in an environment variable or Rails credentials, never in the browser:

```yaml
# bin/rails credentials:edit
goodsorcery:
  api_key: gs_live_...
```

Logs and the install check only ever show a masked key, such as `gs_live_…e81a`.

### Release

`config.release`, else the first present of `GOODSORCERY_RELEASE`, `KAMAL_VERSION`, `HEROKU_SLUG_COMMIT`, `HEROKU_BUILD_COMMIT`, `RENDER_GIT_COMMIT`, `GIT_COMMIT`, `GIT_SHA` and `SOURCE_VERSION`, else the `REVISION` file in the app root (Capistrano). It never shells out to git.

## Filtering

Filtering applies at any depth to request params, headers, session, the URL query string, job arguments, context, tags and breadcrumb data. The `user` section (`id`, `email`, `username`, `name`) is sent as given, because it identifies affected users; only set the fields you want sent.

The defaults mirror Rails' generated `filter_parameters` plus the server's scrub list:

```ruby
GoodSorcery::Defaults::FILTER_PARAMS
# => [/passw/i, /secret/i, /token/i, /_key/i, /api-?key/i, /crypt/i, /salt/i, /certificate/i,
#     /otp/i, /ssn/i, /cvv/i, /cvc/i, /authorization/i, /cookie/i, /csrf/i, /xsrf/i,
#     /session[-_]?id/i, /credit[-_]?card/i, /card[-_]?number/i, /signature/i, /email/i]
```

- **Strings and symbols** match a whole key, case-insensitively, with `-` and `_` treated as equal: `"secret_key"` matches `secret_key` and `Secret-Key`, but not `my_secret_key`.
- **Regexps** match any part of a key, as spelled or with `-` read as `_`: `/_key/i` matches `api_key`, `secret_key_base` and the `X-Access-Key` header.

```ruby
config.filter_params += %i[card_token ssn]            # add exact keys
config.filter_params += [/_key\z/i, /secret_key/i]    # add patterns
config.filter_params -= [/email/i]                    # remove a default
config.filter_params = [/password/i]                  # replace the defaults entirely
```

In Rails apps, `Rails.application.config.filter_parameters` is applied as well (to the URL query string too), with Rails' own matching rules (`ActiveSupport::ParameterFilter`), unless `use_rails_filter_parameters = false`.

Key filtering can't protect a secret passed as a bare positional job argument (`perform(user_id, "s3cr3t")`). Turn arguments off for such jobs, or everywhere with `config.send_job_arguments = false`:

```ruby
class ChargeCustomerJob < ApplicationJob
  goodsorcery_arguments false            # this job and its subclasses
end

class LegacyWorker
  include Sidekiq::Job
  sidekiq_options goodsorcery_arguments: false
end
```

## Integrations

Each integration opens a **fresh scope** for one request, job or channel action, so context, user, tags and breadcrumbs never leak from one to the next. Request and job details are only read **when an error is reported**, so a request or job that succeeds pays almost nothing. Each exception object is reported once, however many integrations see it.

| Where the error happened | `transaction` | What is sent |
|---|---|---|
| Controller / Rack request | `UsersController#update` | `request`: URL (query filtered), method, format, request id, remote IP, params (as Rails parsed them), headers, session (only if the request already loaded it); `context.controller`; the user |
| Active Job (any adapter) | `ChargeCustomerJob` | `job`: `framework` (`active_job`), `class`, `id`, `provider_job_id`, `queue`, `priority`, `executions`, `enqueued_at`, `scheduled_at`, `arguments`; tag `queue` |
| Action Mailer `deliver_later` | `UserMailer#welcome` | as Active Job, plus `mailer` and `action`; `arguments` holds the mailer method's `args` and `params` |
| Sidekiq (jobs not wrapped by Active Job) | worker class | `job`: `framework` (`sidekiq`), `class`, `id` (jid), `queue`, `retry_count`, `enqueued_at`, `arguments`; tag `queue` |
| Action Cable | `ChatChannel#speak` | `request`: the connection's URL, request id, remote IP and headers; params `{ "channel" => subscription params, "data" => action data }` |
| Rake | `rake db:migrate` | `context.rake`: the failing task and its arguments |
| `Rails.error.report` / `handle` | unchanged | `context.rails_error`: the reporter's `context:` plus `source` |

Job arguments are serialised the way the job system sees them, without loading anything: records become their GlobalID (`"gid://shop/Customer/88123"`), hashes keep their keys (so filtering applies), symbols become strings, times ISO 8601, and any other object a `"#<ClassName>"` placeholder. `#inspect` is never called. Sizes and depth are capped like request params.

### Rails

Nothing to set up beyond the initializer. The Railtie:

- uses `Rails.root`, `Rails.env`, `Rails.logger` and the `REVISION` file in `Rails.root` as defaults, and applies `filter_parameters`;
- inserts `GoodSorcery::Rack::Middleware` right after `ActionDispatch::ShowExceptions`, so it sees exceptions before Rails renders the error page. Errors that a lower layer turned into a 5xx response (`env["action_dispatch.exception"]`) are reported too;
- subscribes to `Rails.error`: unhandled errors are reported at level `error`, handled ones (`Rails.error.handle`, `Rails.error.report(handled: true)`) at their severity (`warning` by default). Set `report_handled_errors = false` to skip handled ones;
- finds the user with the controller's `user_method` (default `current_user`, private methods too), else `Current.user`, and sends only `id`, `email`, `username` and `name`;
- wraps Active Job's `perform_now` outside the job's own `rescue_from`/`retry_on`, so a job is reported once when it finally fails, not on every attempt it retries itself. `GoodSorcery::DeliveryJob` is never reported;
- wraps Action Cable channel subscribe, unsubscribe and actions; errors your channel's `rescue_from` handles are not reported;
- records breadcrumbs from `ActiveSupport::Notifications` inside requests, jobs and channel actions: `start_processing.action_controller`, `sql.active_record` (without `SCHEMA`, `CACHE` and `TRANSACTION` queries; SQL capped at 1,000 chars, with quoted strings and numbers replaced by `?` so inlined values never leave the app), `perform.active_job` and `deliver.action_mailer`. Turn them off with `config.breadcrumbs = false`;
- loads the `goodsorcery:verify` and `goodsorcery:test` tasks and reports exceptions that end a rake task.

### Rack and Sinatra

```ruby
# config.ru
require "goodsorcery"
GoodSorcery.configure { |config| config.api_key = ENV["GOODSORCERY_API_KEY"] }
use GoodSorcery::Rack::Middleware
run MyApp
```

The middleware reports exceptions that propagate (and re-raises them) and errors Sinatra turned into a 5xx (`env["sinatra.error"]`). Params are the query string plus a form body only if the app already parsed it: the middleware never reads the request body and never loads a session that wasn't loaded.

### Sidekiq

Hooked in automatically when Sidekiq is loaded before `goodsorcery` or in a Rails app. Otherwise call `GoodSorcery::Integrations::Sidekiq.install` after requiring both. A server middleware reports jobs that fail (on every attempt, as Sidekiq retries them) and an error handler catches anything raised outside it. Jobs enqueued through Active Job are left to the Active Job layer.

### Rake

Rails apps get this automatically; elsewhere `require "goodsorcery/tasks"` in your Rakefile. An exception that ends a rake run is reported with `transaction = "rake <tasks>"` (task arguments stay out of the name and go, filtered, to `context.rake`), and the queue is flushed, for up to `shutdown_timeout`, before rake exits.

## Install check

`bin/rails goodsorcery:verify` (or `rake goodsorcery:verify`) checks your setup on demand; see the end of this section.

The gem can also run that check after every `bundle install`. It's a Bundler plugin, so it's opt-in: add `plugin "goodsorcery"` to your Gemfile. Each `bundle install` then boots your app and calls the server, so leave it out if that's too slow or noisy. With the plugin, every `bundle install` runs a short check, but only when `RAILS_ENV`/`RACK_ENV`/`APP_ENV` are unset or `development`, `CI` is unset, `GOODSORCERY_SKIP_INSTALL_CHECK` is unset and the Gemfile depends on `goodsorcery`. It runs `bundle exec ruby` in the app root with a 30-second limit, boots the app (`config/environment.rb` when present, so your initializer applies) and, per `config.install_check`:

- `:verify` (default): prints the endpoint, environment (and why reporting is on or off), delivery and masked key, then calls `GET /api/v1/verify`. No event is created.
- `:test_event`: also sends a real `GoodSorcery::TestError`, even in development.
- `false`: skipped.

It never fails or blocks `bundle install`: problems are printed as single `[goodsorcery]` lines.

```
[goodsorcery] endpoint:    https://errors.example.com
[goodsorcery] environment: development (reporting disabled: environment "development" is in disabled_environments)
[goodsorcery] delivery:    async
[goodsorcery] api key:     gs_test_…e81a
[goodsorcery] verify:      ok, API key gs_test_…e81a is valid for environment "staging" at https://errors.example.com
```

The same checks run on demand. Rails apps get the tasks automatically; elsewhere, add `require "goodsorcery/tasks"` to your Rakefile.

```sh
bin/rails goodsorcery:verify   # report + verify, sends nothing
bin/rails goodsorcery:test     # always sends a test exception and prints its id
```

## Testing your app

```ruby
# test/test_helper.rb
GoodSorcery.configure { |config| config.delivery = :test }

# in a test
GoodSorcery.clear_test_events
post checkouts_path, params: { ... }
event = GoodSorcery.test_events.last
assert_equal "Payments::DeclinedError", event["exception"]["class"]
```

The `:test` delivery ignores the environment check, stores the filtered event hashes exactly as they would be sent, and never touches the network.

## Self-hosted servers

Point `endpoint` (or `GOODSORCERY_ENDPOINT`) at your instance, for example `https://errors.example.com`. A path prefix such as `https://example.com/tracker` is kept. Servers without the batch endpoint (`404`) are detected once, and the gem then sends one event per request. A batch refused as too large (`413`, for example by a proxy with a smaller body limit) is split in halves and resent.

## Extension points

These are for integrations and advanced setups:

- `config.extra_filters`: objects responding to `filter(hash) -> hash`, applied after the key filter to every filtered section (URL query parameters are checked by filtering a one-value hash at their key path). `ActiveSupport::ParameterFilter` fits as is; the Rails integration adds one for `filter_parameters`.
- `config.request_extractor`: an object responding to `extract(rack_env) -> Hash` (keys `url`, `method`, `format`, `request_id`, `remote_ip`, `params`, `headers`, `session`). Integrations keep the env in `GoodSorcery.scope.request_env`, so the request is only read when an error is reported. Alternatively they can set `GoodSorcery.scope.request` to a ready hash.
- `GoodSorcery.scope`, `GoodSorcery.with_scope` and `GoodSorcery.clear_scope` manage the per-thread scope.
- `scope.enricher`: an object responding to `enrich(scope)`, run once, just before the first event in that scope is built. Integrations use it to fill in `scope.request`, `scope.job`, `scope.user` and `scope.transaction` only when something is reported. `scope.job` takes the `job` section's fields (see [Integrations](#integrations)).

## Development

```sh
bin/setup              # bundle install, then the whole test suite
bundle exec rake test  # core, then Rack/Sidekiq/Rake, then Rails tests, each in its own process
bundle exec rubocop
bin/console
```

### Releasing

1. Bump `GoodSorcery::VERSION` in `lib/goodsorcery/version.rb` and add a dated section to `CHANGELOG.md`.
2. Commit both on `main`.
3. Run `bundle exec rake release`. It refuses to run with uncommitted changes. It builds the gem into `pkg/`, tags `vX.Y.Z`, pushes the commit and the tag to GitHub and pushes the gem to RubyGems, asking for your MFA code.

## License

Created by [Philip Q Nguyen](https://github.com/philipqnguyen). MIT licensed; see [LICENSE](LICENSE).
