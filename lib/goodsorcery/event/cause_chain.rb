# frozen_string_literal: true

module GoodSorcery
  module Event
    # Up to three causes of an exception, as class and message.
    class CauseChain
      MAX_CAUSES = 3
      MAX_MESSAGE_LENGTH = 1_000

      def initialize(exception)
        @exception = exception
      end

      def to_a
        causes.map do |cause|
          {
            "class" => ExceptionSection.class_name(cause),
            "message" => ExceptionSection.message(cause, MAX_MESSAGE_LENGTH)
          }
        end
      end

      private

      def causes
        seen = {}.compare_by_identity
        seen[@exception] = true
        current = @exception.cause
        list = []
        while current && list.size < MAX_CAUSES && !seen[current]
          seen[current] = true
          list << current
          current = current.cause
        end
        list
      end
    end
  end
end
