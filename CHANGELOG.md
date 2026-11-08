# Changelog

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
