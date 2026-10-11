# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

namespace :test do
  Rake::TestTask.new(:core) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/goodsorcery/**/*_test.rb"]
    t.warning = false
  end

  # Rack, Sidekiq and Rake integrations, without Rails.
  Rake::TestTask.new(:integrations) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/integrations/**/*_test.rb"]
    t.warning = false
  end

  # Framework tests boot a Rails app, so they run in their own process.
  Rake::TestTask.new(:rails) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/rails/**/*_test.rb"]
    t.warning = false
  end
end

desc "Run the core, integration and Rails test suites"
task test: %w[test:core test:integrations test:rails]

task default: :test
