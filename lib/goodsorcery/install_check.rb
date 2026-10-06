# frozen_string_literal: true

require_relative "../goodsorcery"
require_relative "status_report"

module GoodSorcery
  # Runs after `bundle install` (via the Bundler plugin) in a subprocess of
  # the app root. Boots the app when config/environment.rb exists, so the
  # initializer's settings apply, then reports per config.install_check:
  # :verify (default), :test_event or false. Prints one "[goodsorcery]" line
  # per finding and never raises.
  class InstallCheck
    def initialize(root: Dir.pwd, out: $stdout, env: ENV)
      @root = root
      @out = out
      @env = env
    end

    def run
      boot_app
      check
    rescue StandardError, ScriptError => e
      @out.puts("#{StatusReport::PREFIX} install check failed: #{e.class}: #{one_line(e.message)}")
      false
    end

    private

    def boot_app
      environment_file = File.join(@root, "config", "environment.rb")
      return unless File.file?(environment_file)

      @env["RAILS_ENV"] ||= "development"
      require environment_file
    end

    def check
      report = StatusReport.new(GoodSorcery.client, out: @out)
      mode = GoodSorcery.configuration.install_check
      return skipped(report) unless mode

      report.print_settings
      verified = report.print_verification
      return verified unless mode == :test_event

      report.print_test_event && verified
    end

    def skipped(report)
      report.say("install check skipped (config.install_check = false)")
      true
    end

    def one_line(message)
      Text.limit(message.to_s.lines.first.to_s.strip, 200)
    end
  end
end
