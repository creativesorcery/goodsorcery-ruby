# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Where the app ran a repeated query: the first stack frame that is the
    # app's own code (not a gem, not this library). Captured inside the
    # sql.active_record callback; the code lines are read only when a trace
    # is built.
    class CallSite
      GEM_LIB = "#{File.expand_path("../..", __dir__)}/".freeze
      CONTEXT_BEFORE = 2
      CONTEXT_AFTER = 2
      MAX_LINE_LENGTH = 200
      MAX_PATH_LENGTH = 1_024
      MAX_METHOD_LENGTH = 255

      attr_reader :path, :line, :label

      # => a CallSite, or nil when no app frame is on the stack.
      def self.capture(paths)
        Thread.each_caller_location do |location|
          path = location.absolute_path || location.path
          next if path.nil? || path.start_with?(GEM_LIB) || !paths.in_app?(path)

          return new(path, location.lineno, location.base_label)
        end
        nil
      end

      def initialize(path, line, label)
        @path = path
        @line = line
        @label = label
      end

      def to_h(paths, line_cache: nil)
        hash = { "file" => Text.limit(paths.relative(path), MAX_PATH_LENGTH), "line" => line,
                 "method" => label && Text.limit(label, MAX_METHOD_LENGTH) }.compact
        context = line_cache && code_context(line_cache)
        hash["context"] = context if context
        hash
      end

      private

      # Two lines before and after the call (5 lines of up to 200 chars).
      def code_context(line_cache)
        lines = line_cache.lines(path)
        return nil unless lines && line.between?(1, lines.size)

        first = [line - CONTEXT_BEFORE, 1].max
        last = [line + CONTEXT_AFTER, lines.size].min
        { "start_line" => first, "lines" => limited(lines[(first - 1)..(last - 1)]) }
      end

      def limited(lines)
        lines.map { |text| Text.limit(text, MAX_LINE_LENGTH) }
      end
    end
  end
end
