# frozen_string_literal: true

module GoodSorcery
  module Backtrace
    # Turns absolute paths under the app root into app-relative ones and
    # decides whether a frame is the app's own code.
    class Paths
      THIRD_PARTY = %r{(?:\A|/)(?:vendor|bundle|\.bundle|gems|node_modules)/}

      attr_reader :root

      def initialize(root)
        expanded = root ? File.expand_path(root.to_s) : nil
        @root = expanded && "#{expanded.chomp("/")}/"
      end

      def relative(path)
        return path unless @root && path.start_with?(@root)

        path.delete_prefix(@root)
      end

      def in_app?(path)
        relative_path = app_relative(path)
        relative_path ? !THIRD_PARTY.match?(relative_path) : false
      end

      def under_root?(path)
        @root ? path.start_with?(@root) : false
      end

      private

      def app_relative(path)
        return nil if path.empty? || path.start_with?("<", "(")
        return path unless path.start_with?("/")

        under_root?(path) ? path.delete_prefix(@root) : nil
      end
    end
  end
end
