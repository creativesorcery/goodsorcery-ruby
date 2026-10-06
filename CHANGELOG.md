# Changelog

## 0.1.0 (unreleased)

- First release.
- `GoodSorcery.notify` with scoped context, user, tags, breadcrumbs and transaction.
- Client-side filtering of sensitive keys (strings, symbols and regexps; mask or remove), including URL query strings.
- Events trimmed to the server's limits before sending; events over 512 KiB are dropped.
- Deliveries: `:async` (batched background thread, the default), `:sync`, `:active_job`, `:test` and custom objects.
- Keep-alive, gzip-compressed HTTP transport with retries, `Retry-After` handling and a fallback for servers without the batch endpoint.
- `GoodSorcery.verify`, the `goodsorcery:verify` and `goodsorcery:test` rake tasks and the Bundler plugin install check.
