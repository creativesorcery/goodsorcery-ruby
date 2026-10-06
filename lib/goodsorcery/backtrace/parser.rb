# frozen_string_literal: true

module GoodSorcery
  module Backtrace
    # One raw stack frame: absolute (or as-given) path, line number and label.
    Frame = Struct.new(:path, :line, :label)

    # Reads frames from Thread::Backtrace::Location objects when Ruby kept
    # them, else parses the backtrace strings. Both label formats are
    # understood: Ruby 3.4+ ("in 'Class#method'") and older ("in `method'").
    class Parser
      LINE = /\A(?<path>.+?):(?<line>\d+)(?::in [`'](?<label>.*)')?\z/

      # The first +limit+ frames; the rest are never parsed, so a deep
      # SystemStackError backtrace costs no more than a short one.
      def frames(exception, limit: nil)
        locations = exception.backtrace_locations
        return locations.first(limit || locations.size).map { |location| from_location(location) } if locations

        lines = Array(exception.backtrace)
        lines.first(limit || lines.size).filter_map { |line| parse(line.to_s) }
      end

      def parse(line)
        match = LINE.match(line)
        return Frame.new(line, nil, nil) unless match

        Frame.new(match[:path], match[:line].to_i, match[:label])
      end

      private

      def from_location(location)
        Frame.new(location.absolute_path || location.path, location.lineno, location.label)
      end
    end
  end
end
