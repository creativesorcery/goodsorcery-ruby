# frozen_string_literal: true

module GoodSorcery
  # The Bundler plugin behind `plugin "goodsorcery"` in a Gemfile. Bundler
  # loads plugins.rb from its own copy of the gem (.bundle/plugin), so this
  # file must stay self-contained: no other gem files, no dependencies.
  #
  # After `bundle install` it runs the install check in a subprocess
  # (`bundle exec ruby -e ...` in the app root, 30 s timeout), but only in
  # development, outside CI, unless GOODSORCERY_SKIP_INSTALL_CHECK is set,
  # and only when the Gemfile depends on goodsorcery.
  module BundlerPlugin
    GEM_NAME = "goodsorcery"
    PREFIX = "[goodsorcery]"
    TIMEOUT = 30
    SCRIPT = 'require "goodsorcery/install_check"; GoodSorcery::InstallCheck.new.run'

    def self.register
      ::Bundler::Plugin.add_hook(::Bundler::Plugin::Events::GEM_AFTER_INSTALL_ALL) do |dependencies|
        after_install(dependencies)
      end
    end

    def self.after_install(dependencies, env: ENV, root: nil)
      return unless Gate.new(env, dependencies).open?

      CheckProcess.new(root: root || ::Bundler.root.to_s).run
    rescue StandardError, ScriptError => e
      warn("#{PREFIX} install check skipped: #{e.class}")
    end

    # Decides whether the check runs at all.
    class Gate
      ENV_NAMES = %w[RAILS_ENV RACK_ENV APP_ENV].freeze

      def initialize(env, dependencies)
        @env = env
        @dependencies = Array(dependencies)
      end

      def open?
        development? && !set?("CI") && !set?("GOODSORCERY_SKIP_INSTALL_CHECK") && depends_on_gem?
      end

      private

      def development?
        ENV_NAMES.all? { |name| !set?(name) || @env[name] == "development" }
      end

      def set?(name)
        value = @env[name]
        !(value.nil? || value.strip.empty?)
      end

      def depends_on_gem?
        @dependencies.any? { |dependency| dependency_name(dependency) == GEM_NAME }
      end

      def dependency_name(dependency)
        dependency.respond_to?(:name) ? dependency.name.to_s : dependency.to_s
      end
    end

    # Runs the check command and kills it when it outlives the timeout.
    class CheckProcess
      POLL_SECONDS = 0.05

      def initialize(root:, timeout: TIMEOUT, command: ["bundle", "exec", "ruby", "-e", SCRIPT], out: $stdout)
        @root = root
        @timeout = timeout
        @command = command
        @out = out
      end

      # => true when the check finished in time.
      def run
        pid = spawn_check
        return true if finished?(pid)

        terminate(pid)
        @out.puts("#{PREFIX} install check timed out after #{@timeout} s and was stopped")
        false
      end

      private

      def spawn_check
        options = { chdir: @root, in: File::NULL }
        return Process.spawn(*@command, **options) unless bundler_loaded?

        ::Bundler.with_original_env { Process.spawn(*@command, **options) }
      end

      def bundler_loaded?
        defined?(::Bundler) && ::Bundler.respond_to?(:with_original_env)
      end

      def finished?(pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        until Process.wait(pid, Process::WNOHANG)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep(POLL_SECONDS)
        end
        true
      end

      def terminate(pid)
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue SystemCallError
        nil
      end
    end
  end
end
