# goodsorcery

The Ruby client for the [Good Sorcery](https://errors.goodsorcery.dev) error tracker. It reports exceptions from Ruby and Rails apps without slowing them down:

- Events are built and filtered in the calling thread, then handed to **one background thread** that sends them in **batches** over a keep-alive, gzip-compressed HTTPS connection.
- Sensitive data is **filtered in-process** before anything leaves your app (the server scrubs again as a second layer).
- The queue is bounded and **drops rather than blocks** when it is full. Rate limits (`429` + `Retry-After`) and server errors are retried with backoff.
- It has no runtime dependencies (standard library only). It needs Ruby 3.2 or newer and works with or without Rails.

## Installation

```ruby
# Gemfile
gem "goodsorcery"
plugin "goodsorcery"   # optional: checks your setup after `bundle install` in development
```

```sh
bundle install
export GOODSORCERY_API_KEY=gs_live_...   # or use Rails credentials, see below
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
| `api_key` | `ENV["GOODSORCERY_API_KEY"]`, then `Rails.application.credentials.dig(:goodsorcery, :api_key)` | Per-environment ingest key. Never logged in full. A missing key disables delivery with one warning. |
| `endpoint` | `ENV["GOODSORCERY_ENDPOINT"]` or `https://errors.goodsorcery.dev` | Your self-hosted URL. `http://` is fine for localhost. |
| `environment` | `ENV["GOODSORCERY_ENV"]`, `Rails.env`, `RACK_ENV`, `APP_ENV`, else `"development"` | Used for gating only; the server takes the environment from the key. |
| `disabled_environments` | `%w[development test]` | Environments that don't report. |
| `enabled_environments` | `nil` | Allow-list; when set, only these report. |
| `enabled` | `ENV["GOODSORCERY_ENABLED"]` (`1`/`0`), else `nil` | Hard override of the environment check. |
| `release` | auto-detected (see below) | Version or commit, up to 64 chars. |
| `root` | `Dir.pwd` (`Rails.root` in Rails) | Makes backtrace paths app-relative and decides which frames are "in app". |
| `filter_params` | see [Filtering](#filtering) | Strings/symbols match whole keys; regexps match any part. |
| `filter_mode` | `:mask` | `:mask` replaces values with `"[FILTERED]"`; `:remove` drops the key. |
| `use_rails_filter_parameters` | `true` | Also apply `Rails.application.config.filter_parameters` (Rails integration). |
| `extra_filters` | `[]` | Objects responding to `filter(hash) -> hash`; see [Extension points](#extension-points). |
| `ignore_exceptions` | Rails/Rack routing and 4xx errors, `SignalException`, `SystemExit` | Class names; subclasses are ignored too. |
| `before_send` | `nil` | `->(event) { event }`. Return a (changed) hash, or `nil` to drop. If it raises, the event is dropped and the error class logged. |
| `tags` | `{}` | Global tags on every event. |
| `user_method` | `:current_user` | Controller method the Rails integration uses to find the user. |
| `send_code_context` | `true` | Source lines (±5) around the top 10 in-app frames. |
| `breadcrumbs` / `max_breadcrumbs` | `true` / `40` | Up to 100. |
| `report_handled_errors` | `true` | Rails integration: also report `Rails.error.handle` errors. |
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

Filtering applies at any depth to request params, headers, session, the URL query string, context, tags and breadcrumb data. The `user` section (`id`, `email`, `username`, `name`) is sent as given, because it identifies affected users; only set the fields you want sent.

The defaults mirror Rails' generated `filter_parameters` plus the server's scrub list:

```ruby
GoodSorcery::Defaults::FILTER_PARAMS
# => [/passw/i, /secret/i, /token/i, /_key/i, /api-?key/i, /crypt/i, /salt/i, /certificate/i,
#     /otp/i, /ssn/i, /cvv/i, /cvc/i, /authorization/i, /cookie/i, /csrf/i, /xsrf/i,
#     /session[-_]?id/i, /credit[-_]?card/i, /card[-_]?number/i, /signature/i, /email/i]
```

- **Strings and symbols** match a whole key, case-insensitively, with `-` and `_` treated as equal: `"secret_key"` matches `secret_key` and `Secret-Key`, but not `my_secret_key`.
- **Regexps** match any part of a key: `/_key/i` matches `api_key` and `secret_key_base`.

```ruby
config.filter_params += %i[card_token ssn]            # add exact keys
config.filter_params += [/_key\z/i, /secret_key/i]    # add patterns
config.filter_params -= [/email/i]                    # remove a default
config.filter_params = [/password/i]                  # replace the defaults entirely
config.filter_mode = :remove                          # drop keys instead of masking them
```

In Rails apps, `Rails.application.config.filter_parameters` is applied as well, with Rails' own matching rules, unless `use_rails_filter_parameters = false`.

## Install check

With `plugin "goodsorcery"` in the Gemfile, every `bundle install` runs a short check, but only when `RAILS_ENV`/`RACK_ENV`/`APP_ENV` are unset or `development`, `CI` is unset, `GOODSORCERY_SKIP_INSTALL_CHECK` is unset and the Gemfile depends on `goodsorcery`. It runs `bundle exec ruby` in the app root with a 30-second limit, boots the app (`config/environment.rb` when present, so your initializer applies) and, per `config.install_check`:

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

Point `endpoint` (or `GOODSORCERY_ENDPOINT`) at your instance, for example `https://errors.example.com`. A path prefix such as `https://example.com/tracker` is kept. Servers without the batch endpoint (`404`) are detected once, and the gem then sends one event per request.

## Extension points

These are for integrations and advanced setups:

- `config.extra_filters`: objects responding to `filter(hash) -> hash`, applied after the key filter to every filtered section. `ActiveSupport::ParameterFilter` fits as is; the Rails integration adds one for `filter_parameters`.
- `config.request_extractor`: an object responding to `extract(rack_env) -> Hash` (keys `url`, `method`, `format`, `request_id`, `remote_ip`, `params`, `headers`, `session`). Integrations keep the env in `GoodSorcery.scope.request_env`, so the request is only read when an error is reported. Alternatively they can set `GoodSorcery.scope.request` to a ready hash.
- `GoodSorcery.scope`, `GoodSorcery.with_scope` and `GoodSorcery.clear_scope` manage the per-thread scope.

## Development

```sh
bin/setup              # bundle install, then the whole test suite
bundle exec rake test  # core tests, then ActiveJob tests in a separate process
bundle exec rubocop
bin/console
```

## License

MIT. See [LICENSE](LICENSE).
