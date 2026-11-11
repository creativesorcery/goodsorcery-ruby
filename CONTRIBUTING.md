# Contributing

Thanks for helping. Bug reports, fixes and documentation improvements are welcome. For a larger change, please open an issue first so we can agree on the approach.

Security problems go through private reporting, not issues: see [SECURITY.md](SECURITY.md).

## Setup

```sh
bin/setup              # bundle install, then the whole test suite
bundle exec rake test  # core, then Rack/Sidekiq/Rake, then Rails tests, each in its own process
bundle exec rubocop
```

You need Ruby 3.2 or newer. `Gemfile.lock` is not committed (this is a gem), so you test against the newest dependencies, as users will. To check that the gem works without Rails, the way CI does:

```sh
BUNDLE_WITHOUT=development bundle exec rake test:core
```

## Guidelines

- **Never raise into the host app.** Every public entry point catches its own errors and logs them. The gem's log lines name classes, counts and statuses only, never captured data, SQL or full API keys.
- **Keep it dependency-free.** The only runtime dependency is `logger`; anything else needs a very good reason.
- **Tests for every behaviour change.** Minitest, no network: use `test/support/fake_server.rb` and `test/support/fake_transport.rb`.
- **House style** (enforced by RuboCop): methods of at most 20 lines, and conditionals nested at most one level deep.
- **Docs move with the code.** Update `README.md` for anything users see, `docs/DESIGN.md` for design decisions, and add a line under "Unreleased" in `CHANGELOG.md`.
- The wire format is defined by the server's [INGEST_API.md](https://github.com/creativesorcery/goodsorcery_web/blob/main/docs/INGEST_API.md). Changes to it start in [goodsorcery_web](https://github.com/creativesorcery/goodsorcery_web).

## Commits and pull requests

Write commit subjects as short imperative sentences ("Cap response bodies while reading"), with the reasoning in the body when it isn't obvious. Keep each pull request to one change, and make sure `bundle exec rake test` and `bundle exec rubocop` pass.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
