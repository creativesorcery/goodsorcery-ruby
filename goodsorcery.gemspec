# frozen_string_literal: true

require_relative "lib/goodsorcery/version"

Gem::Specification.new do |spec|
  spec.name = "goodsorcery"
  spec.version = GoodSorcery::VERSION
  spec.authors = ["Philip Q Nguyen"]
  spec.email = ["5519675+philipqnguyen@users.noreply.github.com"]

  spec.summary = "Error reporting client for the Good Sorcery error tracker."
  spec.description = "Reports exceptions from Ruby and Rails apps to Good Sorcery. " \
                     "Filters sensitive data in-process and delivers events in batches " \
                     "from a background thread, without blocking the host app."
  spec.homepage = "https://app.goodsorcery.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/creativesorcery/goodsorcery-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/creativesorcery/goodsorcery-ruby/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/creativesorcery/goodsorcery-ruby/issues"

  tracked = `git -C #{__dir__} ls-files -z 2>/dev/null`.split("\x0")
  spec.files = tracked.select do |path|
    path.start_with?("lib/") || %w[plugins.rb README.md CHANGELOG.md LICENSE].include?(path)
  end
  spec.require_paths = ["lib"]
end
