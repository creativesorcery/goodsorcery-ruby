# Changelog

## 0.1.0 (unreleased)

- First release.
- `GoodSorcery.notify` with scoped context, user, tags, breadcrumbs and transaction.
- Client-side filtering of sensitive keys (strings, symbols and regexps; mask or remove), including URL query strings.
- Events trimmed to the server's limits before sending; events over 512 KiB are dropped.
- Deliveries: `:async` (batched background thread, the default), `:sync`, `:active_job`, `:test` and custom objects.
- Keep-alive, gzip-compressed HTTP transport with retries, `Retry-After` handling and a fallback for servers without the batch endpoint.
- `GoodSorcery.verify`, the `goodsorcery:verify` and `goodsorcery:test` rake tasks and the Bundler plugin install check.
- Integrations: Rack middleware (Rails, Sinatra, plain Rack), Railtie with Rails defaults and `filter_parameters`, `Rails.error` subscriber, Action Controller, Active Job, Action Mailer and Action Cable layers, notification breadcrumbs, Sidekiq middleware and error handler, and Rake reporting.
- A `job` event section with filtered job arguments; `send_job_arguments`, `goodsorcery_arguments false` and `sidekiq_options goodsorcery_arguments: false`.
- `send_request_params`, `send_request_headers` and `send_session` switches.
- `bin/rails generate goodsorcery:install [--api-key=KEY]`.
