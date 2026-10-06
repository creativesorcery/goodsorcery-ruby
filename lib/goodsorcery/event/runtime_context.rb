# frozen_string_literal: true

module GoodSorcery
  module Event
    # Runtime details for the Environment tab: Ruby (and YJIT), Rails, host,
    # process and the RAILS_ENV/RACK_ENV variables only.
    class RuntimeContext
      ENV_NAMES = %w[RAILS_ENV RACK_ENV].freeze

      def initialize
        @ruby = ruby_label
        @host = hostname
      end

      def to_h
        {
          "runtime" => { "ruby" => @ruby, "rails" => rails_version }.compact,
          "host" => @host,
          "process" => "pid #{Process.pid} · thread #{thread_label}",
          "env" => env_vars
        }.compact
      end

      private

      def env_vars
        vars = ENV.to_h.slice(*ENV_NAMES)
        vars.empty? ? nil : vars
      end

      def ruby_label
        yjit = defined?(::RubyVM::YJIT) && ::RubyVM::YJIT.respond_to?(:enabled?) && ::RubyVM::YJIT.enabled?
        yjit ? "#{RUBY_VERSION} (YJIT on)" : RUBY_VERSION
      end

      def rails_version
        ::Rails.version.to_s if defined?(::Rails) && ::Rails.respond_to?(:version)
      end

      def hostname
        Text.limit(Socket.gethostname, 255)
      rescue StandardError
        nil
      end

      def thread_label
        thread = Thread.current
        thread.name || thread.native_thread_id || thread.object_id
      end
    end
  end
end
