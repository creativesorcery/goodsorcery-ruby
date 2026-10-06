# frozen_string_literal: true

module GoodSorcery
  # Shows an API key without revealing it: "gs_test_9f2c…e81a" becomes "gs_test_…e81a".
  class MaskedKey
    PREFIX = /\A(gs_[a-z]+_)/
    MIN_LENGTH_FOR_TAIL = 16

    def initialize(key)
      @key = key.to_s
    end

    def to_s
      return "(not set)" if @key.empty?

      "#{prefix}…#{tail}"
    end

    private

    def prefix
      @key[PREFIX, 1].to_s
    end

    def tail
      @key.length >= MIN_LENGTH_FOR_TAIL ? @key[-4..] : ""
    end
  end
end
