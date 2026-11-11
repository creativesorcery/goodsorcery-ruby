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

  spec.metadata["documentation_uri"] = "https://github.com/creativesorcery/goodsorcery-ruby#readme"

  # The files git tracks. Outside a git checkout (a tarball or a GitHub
  # archive) the same files are taken from disk, so the gem is never empty.
  packaged = %w[plugins.rb README.md CHANGELOG.md LICENSE]
  tracked = `git -C #{__dir__} ls-files -z 2>/dev/null`.split("\x0")
  if tracked.empty?
    tracked = Dir.glob("lib/**/*", base: __dir__).select { |path| File.file?(File.join(__dir__, path)) } + packaged
  end
  spec.files = tracked.select { |path| path.start_with?("lib/") || packaged.include?(path) }
  spec.require_paths = ["lib"]

  # logger is a bundled gem, not a default gem, since Ruby 4.0: under Bundler
  # it only loads when something in the bundle depends on it.
  spec.add_dependency "logger", ">= 1.5"
end
