# Changelog

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
