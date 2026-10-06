# frozen_string_literal: true

module GoodSorcery
  # Turns what was passed to notify into an exception. A message becomes a
  # RuntimeError whose backtrace is the caller's stack (without this gem's
  # own frames).
  module ExceptionCoercion
    GEM_DIR = File.expand_path("..", __dir__)

    def self.coerce(error)
      return error if error.is_a?(Exception)

      exception = RuntimeError.new(Text.safe_to_s(error))
      exception.set_backtrace(caller.reject { |line| line.start_with?(GEM_DIR) })
      exception
    end
  end
end
