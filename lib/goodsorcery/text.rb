# frozen_string_literal: true

module GoodSorcery
  # String helpers: valid UTF-8, length caps, and copies the app can't mutate
  # after the event was built.
  module Text
    module_function

    def limit(value, max)
      string = utf8(value.is_a?(String) ? value : value.to_s)
      return string[0, max] if string.length > max

      string.frozen? ? string : string.dup
    end

    def utf8(string)
      return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

      copy = string.dup
      copy.force_encoding(Encoding::UTF_8) if copy.encoding == Encoding::BINARY
      return copy.scrub if copy.encoding == Encoding::UTF_8

      copy.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue EncodingError
      string.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # to_s that never raises.
    def safe_to_s(object)
      object.to_s
    rescue StandardError
      "#<#{object.class}>"
    end
  end
end
