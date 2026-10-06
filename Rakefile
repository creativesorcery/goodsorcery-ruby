# frozen_string_literal: true

require "rake/testtask"

namespace :test do
  Rake::TestTask.new(:core) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/goodsorcery/**/*_test.rb"]
    t.warning = false
  end

  # Framework tests load ActiveJob/Rails, so they run in their own process.
  Rake::TestTask.new(:rails) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/rails/**/*_test.rb"]
    t.warning = false
  end
end

desc "Run the core and framework test suites"
task test: %w[test:core test:rails]

task default: :test
