# frozen_string_literal: true

module GoodSorcery
  module Backtrace
    # The source lines around a frame: up to 5 before and 5 after.
    class CodeContext
      RADIUS = 5
      MAX_LINE_LENGTH = 500

      def initialize(line_cache)
        @line_cache = line_cache
      end

      def around(path, line)
        lines = line ? @line_cache.lines(path) : nil
        return nil unless lines && line.between?(1, lines.size)

        first = [line - RADIUS, 1].max
        last = [line + RADIUS, lines.size].min
        {
          "start_line" => first,
          "lines" => lines[(first - 1)..(last - 1)].map { |text| Text.limit(text, MAX_LINE_LENGTH) }
        }
      end
    end
  end
end
