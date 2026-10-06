# frozen_string_literal: true

module GoodSorcery
  module Event
    # The "exception" section: class, message and backtrace frames, with code
    # context for the top in-app frames.
    class ExceptionSection
      MAX_CLASS_LENGTH = 255
      MAX_MESSAGE_LENGTH = 10_000
      MAX_FRAMES = 250
      CONTEXT_FRAMES = 10

      def initialize(paths:, code_context:, send_code_context:)
        @paths = paths
        @code_context = code_context
        @send_code_context = send_code_context
        @parser = Backtrace::Parser.new
      end

      def build(exception)
        {
          "class" => self.class.class_name(exception),
          "message" => self.class.message(exception, MAX_MESSAGE_LENGTH),
          "backtrace" => backtrace(exception)
        }
      end

      def self.class_name(exception)
        Text.limit(exception.class.name || exception.class.to_s, MAX_CLASS_LENGTH)
      end

      def self.message(exception, max)
        Text.limit(exception.message, max)
      rescue StandardError
        ""
      end

      private

      def backtrace(exception)
        remaining = @send_code_context ? CONTEXT_FRAMES : 0
        @parser.frames(exception, limit: MAX_FRAMES).map do |frame|
          hash = frame_hash(frame)
          next hash unless hash["in_app"] && remaining.positive?

          remaining -= 1
          add_code_context(hash, frame)
        end
      end

      def frame_hash(frame)
        path = frame.path.to_s
        {
          "file" => Text.limit(@paths.relative(path), 1_024),
          "line" => frame.line,
          "method" => frame.label && Text.limit(frame.label, 255),
          "in_app" => @paths.in_app?(path)
        }.compact
      end

      def add_code_context(hash, frame)
        context = @code_context.around(frame.path.to_s, frame.line)
        hash["context"] = context if context
        hash
      end
    end
  end
end
