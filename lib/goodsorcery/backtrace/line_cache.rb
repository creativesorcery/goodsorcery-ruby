# frozen_string_literal: true

module GoodSorcery
  module Backtrace
    # A small thread-safe LRU cache of source file lines. It only reads files
    # under the app root that are smaller than 1 MB, and remembers misses too.
    class LineCache
      MAX_BYTES = 1_048_576
      MISS = Object.new.freeze

      def initialize(paths, max_files: 64)
        @paths = paths
        @max_files = max_files
        @entries = {}
        @mutex = Mutex.new
      end

      def lines(path)
        cached = fetch(path)
        return cached unless cached.equal?(MISS)

        store(path, read(path))
      end

      private

      def fetch(path)
        @mutex.synchronize do
          next MISS unless @entries.key?(path)

          @entries[path] = @entries.delete(path)
        end
      end

      def store(path, lines)
        @mutex.synchronize do
          @entries[path] = lines
          @entries.shift while @entries.size > @max_files
        end
        lines
      end

      def read(path)
        return nil unless readable?(path)

        File.readlines(path, chomp: true)
      rescue SystemCallError, IOError
        nil
      end

      def readable?(path)
        path.start_with?("/") && File.expand_path(path) == path && @paths.under_root?(path) &&
          File.file?(path) && File.size(path) < MAX_BYTES
      end
    end
  end
end
