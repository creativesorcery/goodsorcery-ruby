# frozen_string_literal: true

require "yaml"

module GoodSorcery
  module Generators
    # Adds goodsorcery.api_key to the app's encrypted credentials when they
    # can be decrypted. Returns :added, :present (a key is already stored;
    # it is left alone) or :unavailable. Never logs or echoes the key.
    class CredentialsApiKey
      def initialize(credentials)
        @credentials = credentials
      end

      def add(api_key)
        return :unavailable unless decryptable?

        yaml = @credentials.read.to_s
        data = parse(yaml)
        return :present if stored_key?(data)

        @credentials.write(updated_yaml(yaml, data, api_key))
        :added
      rescue StandardError
        :unavailable
      end

      def path
        @credentials.content_path.to_s
      rescue StandardError
        "config/credentials.yml.enc"
      end

      private

      def decryptable?
        !@credentials.key.to_s.empty?
      end

      def parse(yaml)
        data = YAML.safe_load(yaml, aliases: true, permitted_classes: [Symbol, Date, Time])
        data.is_a?(Hash) ? data : {}
      end

      def section(data)
        data["goodsorcery"] || data[:goodsorcery]
      end

      def stored_key?(data)
        section = section(data)
        section.is_a?(Hash) && !(section["api_key"] || section[:api_key]).to_s.empty?
      end

      # Appends a new section as text, so comments in the file survive; an
      # existing goodsorcery section is merged instead.
      def updated_yaml(yaml, data, api_key)
        return YAML.dump(data.merge("goodsorcery" => section(data).merge("api_key" => api_key))) if section(data)

        addition = YAML.dump("goodsorcery" => { "api_key" => api_key }).delete_prefix("---\n")
        yaml.empty? || yaml.end_with?("\n") ? "#{yaml}#{addition}" : "#{yaml}\n#{addition}"
      end
    end
  end
end
