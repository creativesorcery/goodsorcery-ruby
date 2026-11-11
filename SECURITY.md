# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting:

**https://github.com/creativesorcery/goodsorcery-ruby/security/advisories/new**

Don't open a public issue, pull request or discussion for a security problem.

Please include:

- the gem version, Ruby version and framework (Rails, Sinatra, plain Rack, ...);
- what an attacker can do, and the steps or a small script that shows it;
- any configuration it depends on (delivery mode, filters, self-hosted endpoint).

Never paste real API keys or captured customer data into a report. A masked key such as `gs_live_…e81a` is enough.

We'll confirm we received the report, keep you updated while we work on a fix, and credit you in the advisory unless you'd rather stay anonymous.

## Supported versions

Security fixes go into the latest released minor version of the `goodsorcery` gem. Please upgrade to the newest release before reporting, if you can.

## Scope

This repository is the Ruby client. In scope are, for example: sensitive data that leaves the app despite the documented filtering, ways to make the gem leak its API key, and ways for a request or a server response to exhaust the host app's memory or block it.

Problems with the server or the hosted service at app.goodsorcery.com belong in [goodsorcery_web](https://github.com/creativesorcery/goodsorcery_web/security/advisories/new).
