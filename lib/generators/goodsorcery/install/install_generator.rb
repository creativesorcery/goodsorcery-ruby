# frozen_string_literal: true

require "rails/generators"
require_relative "credentials_api_key"

module GoodSorcery
  module Generators
    # bin/rails generate goodsorcery:install [--api-key=KEY]
    #
    # Writes config/initializers/goodsorcery.rb, adds `plugin "goodsorcery"`
    # to the Gemfile, and stores the API key in the encrypted credentials when
    # one is given and they can be decrypted. Never prints the key.
    class InstallGenerator < ::Rails::Generators::Base
      namespace "goodsorcery:install"
      source_root File.expand_path("templates", __dir__)
      desc "Set up Good Sorcery error reporting"

      class_option :api_key, type: :string, desc: "Ingest API key to store in Rails credentials"

      PLUGIN_LINE = /^\s*plugin\s+["']goodsorcery["']/
      PLUGIN_SNIPPET = <<~RUBY

        # Checks the Good Sorcery endpoint and API key after `bundle install` in
        # development (never in CI or production). Set GOODSORCERY_SKIP_INSTALL_CHECK=1 to skip.
        plugin "goodsorcery"
      RUBY
      KEY_HINT = <<~TEXT
        Add your API key with `bin/rails credentials:edit`:

          goodsorcery:
            api_key: <your gs_live_... or gs_test_... key>

        or set the GOODSORCERY_API_KEY environment variable.
      TEXT

      def create_initializer
        copy_file "initializer.rb", "config/initializers/goodsorcery.rb"
      end

      def add_bundler_plugin
        gemfile = File.join(destination_root, "Gemfile")
        return unless File.exist?(gemfile)
        return if File.read(gemfile).match?(PLUGIN_LINE)

        append_to_file "Gemfile", PLUGIN_SNIPPET
      end

      def store_api_key
        api_key = options[:api_key].to_s.strip
        return say(KEY_HINT) if api_key.empty?

        credentials = CredentialsApiKey.new(::Rails.application.credentials)
        report_credentials(credentials.add(api_key), credentials.path)
      end

      private

      def report_credentials(status, path)
        case status
        when :added then say_status(:credentials, "added goodsorcery.api_key to #{relative(path)}")
        when :present then say_status(:credentials, "goodsorcery.api_key is already set; left unchanged", :yellow)
        else say("The credentials could not be decrypted, so the API key was not stored.\n#{KEY_HINT}")
        end
      end

      def relative(path)
        path.delete_prefix("#{destination_root}/")
      end
    end
  end
end
