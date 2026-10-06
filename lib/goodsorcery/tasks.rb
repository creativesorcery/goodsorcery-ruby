# frozen_string_literal: true

require "rake"
require_relative "../goodsorcery"
require_relative "status_report"

module GoodSorcery
  # Rake tasks: `require "goodsorcery/tasks"` in a Rakefile (Rails apps get
  # them automatically). They load the app's :environment task when there is
  # one.
  module Tasks
    extend Rake::DSL

    def self.load_environment
      Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
    end

    def self.verify(out: $stdout)
      report = StatusReport.new(GoodSorcery.client, out: out)
      report.print_settings
      report.print_verification
    end

    def self.send_test_event(out: $stdout)
      StatusReport.new(GoodSorcery.client, out: out).print_test_event
    end

    namespace :goodsorcery do
      desc "Check the Good Sorcery endpoint and API key (sends nothing)"
      task :verify do
        GoodSorcery::Tasks.load_environment
        abort("[goodsorcery] verification failed") unless GoodSorcery::Tasks.verify
      end

      desc "Send a test exception to Good Sorcery, in any environment"
      task :test do
        GoodSorcery::Tasks.load_environment
        abort("[goodsorcery] test event failed") unless GoodSorcery::Tasks.send_test_event
      end
    end
  end
end
