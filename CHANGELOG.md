# Changelog

## 0.3.2 (2026-11-10)

- Fix: the gem now declares its `logger` dependency. Since Ruby 4.0, `logger` is a bundled gem rather than a default gem, so apps without Rails (Rack, Sinatra, scripts, AWS Lambda) failed at `require "goodsorcery"` with `cannot load such file -- logger`. CI now also loads and tests the gem with only its runtime dependencies.
- Security: the `:async` queue is bounded by bytes as well as by count. Events are serialized in the calling thread before they are queued, so an event over the server's 512 KiB limit is dropped straight away, and the queue holds at most 16 MiB of JSON. Past either limit the newest event is dropped and counted, with one warning a minute. Before, a queue full of large unserialized events could use gigabytes of memory while the server answered `429`.
- Security: query strings inside header values, such as `Referer` and `Origin`, are filtered with the same rules as the request URL (`filter_params`, Rails' `filter_parameters` and `extra_filters`). A Referer could carry the previous page's password-reset or invitation token.
- Security: `GOODSORCERY_ENDPOINT` must pass the same check as `config.endpoint=` (an `http://` or `https://` URL with a host and no credentials). An invalid value turns delivery and performance monitoring off with one warning, instead of sending the API key in plaintext over another scheme. `GoodSorcery.verify`, `goodsorcery:verify` and `goodsorcery:test` report the problem instead of raising `NoMethodError`. The plain-HTTP warning now also recognises `http://[::1]` as local.
- The install generator's initializer sets `config.api_key = ENV["GOODSORCERY_API_KEY"].presence` (Rails credentials are still read when it is unset). `--api-key` remains optional, and the docs recommend the environment variable or `bin/rails credentials:edit`, because a key typed on the command line stays in the shell history.
- The gemspec falls back to the files on disk when it is built outside a git checkout (for example from a GitHub archive), instead of building an empty gem.
- Docs: the README starts with the hosted service (app.goodsorcery.com, where the API key comes from the project's Setup page) and has a separate Self-hosted section showing `GOODSORCERY_ENDPOINT`, `config.endpoint` and how to trust a private CA. Added SECURITY.md and CONTRIBUTING.md. DESIGN.md links to the server repository on GitHub.

## 0.3.1 (2026-11-08)

- Performance traces also send the app-code layer as `app_ms` (the server's language-neutral protocol, revision 1.1), next to `ruby_ms`, which older servers read. Nothing else changes: runtimes still go out as `{ "ruby", "rails" }`, which every server version reads.
- Security: SQL breadcrumbs are normalised with the same rules as performance traces, in the dialect of the connection. Before, a string ending in a backslash on Postgres or SQLite (`'C:\'`), or a quote inside a comment, could leave the next literal value (a token or an email) in the breadcrumb. Breadcrumb SQL now also has comments removed and `IN` lists collapsed.
- Security: responses from the server are requested with `Accept-Encoding: identity` and read into a buffer of at most 64 KiB. A longer body is no longer read to the end (the result keeps its status, the connection is closed), and a gzip response is no longer inflated, so a broken or hostile endpoint cannot exhaust the app's memory.

## 0.3.0 (2026-11-07)

### Removed (breaking)

- Removed the `:active_job` delivery, along with `GoodSorcery::DeliveryJob`, `config.active_job_queue` and `GoodSorcery::RetryableDeliveryError`. Use `:async` (the default). Errors raised in your own jobs are still reported, and jobs are still measured by performance monitoring.
- Removed custom delivery objects (`config.delivery = <object responding to #deliver>`).

### Changed

- `config.delivery` now accepts only `:async`, `:sync` and `:test`; anything else, including `:active_job` or an object, raises `ArgumentError` from `GoodSorcery.configure` with a message saying what to use instead. Setting `config.active_job_queue` raises `NoMethodError`.

## 0.2.0 (2026-11-07)

- **Performance monitoring** (opt-in, `config.performance_monitoring = true` or `GOODSORCERY_PERFORMANCE_MONITORING=1`). Records every Rails request and every Active Job and Sidekiq job: count, failures, total time and a shared log-scale histogram (`gs-v1`) with database, external HTTP, view and Ruby time per bucket, plus queue wait for jobs. Metrics are aggregated per transaction per minute in process and sent once a minute to `POST /api/v1/apm/metrics` from a background thread (`goodsorcery-apm`).
- **Traces** of the slowest request per transaction per minute (`config.performance_traces`, default on), sent to `POST /api/v1/apm/traces`: SQL, `Net::HTTP`, render and enqueue spans; repeated queries grouped with their count, total and app call site (with code context under `send_code_context`); SQL normalised so no literal values leave the process; HTTP spans and the request path without query strings; GC, allocations, host and process; the id of the error reported during the request.
- `config.performance_ignore_transactions` (default `["Rails::HealthController#show"]`). `GoodSorcery::DeliveryJob` is never recorded.
- `GoodSorcery.flush_performance` and, with the `:test` delivery, `GoodSorcery.test_performance_payloads`.
- The gem's own HTTP requests are never measured. Payloads keep their `batch_id` across retries; `429`, `5xx`, `404` (server without performance endpoints: monitoring turns off) and rejected payloads are handled as documented; data is bounded to five minutes and flushed at exit; fork-safe.
- `bundle exec rake bench:performance` measures the per-request cost.

## 0.1.1 (2026-10-11)

- `Sidekiq::JobRetry::Handled` and `Sidekiq::JobRetry::Skip` are ignored by default. Sidekiq raises them internally after its retry handling, so reporting them only duplicated the original error.

## 0.1.0 (2026-10-10)

- First release.
- `GoodSorcery.notify` with scoped context, user, tags, breadcrumbs and transaction.
- Client-side filtering of sensitive keys (strings, symbols and regexps; values masked as `[FILTERED]`), including URL query strings.
- Events trimmed to the server's limits before sending; events over 512 KiB are dropped.
- Deliveries: `:async` (batched background thread, the default), `:sync`, `:active_job`, `:test` and custom objects.
- Keep-alive, gzip-compressed HTTP transport with retries, `Retry-After` handling and a fallback for servers without the batch endpoint.
- `GoodSorcery.verify`, the `goodsorcery:verify` and `goodsorcery:test` rake tasks and an opt-in Bundler plugin (`plugin "goodsorcery"`) that runs the install check after `bundle install`.
- Integrations: Rack middleware (Rails, Sinatra, plain Rack), Railtie with Rails defaults and `filter_parameters`, `Rails.error` subscriber, Action Controller, Active Job, Action Mailer and Action Cable layers, notification breadcrumbs, Sidekiq middleware and error handler, and Rake reporting.
- A `job` event section with filtered job arguments; `send_job_arguments`, `goodsorcery_arguments false` and `sidekiq_options goodsorcery_arguments: false`.
- `send_request_params`, `send_request_headers` and `send_session` switches.
- `bin/rails generate goodsorcery:install [--api-key=KEY]`.
- Hardening from review: `inspect` never shows the API key; `config.endpoint` must be an http(s) URL without credentials; Rails `filter_parameters` also filter the URL query string; filter regexps also match keys with `-` read as `_` (headers); SQL breadcrumbs have literal values replaced by `?`; OpenStruct and Set values are filtered by key.
- Robustness from review: a forked child opens its own keep-alive connection; a batch refused with `413` is split in halves; reports raised while a report is being built are dropped instead of recursing; `:active_job` falls back to the background thread when Rails refuses the enqueue; only the 250 sent backtrace frames are parsed; reconfiguring retires the old transport outside the client lock.
