# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Time-ordered UUIDs (RFC 9562 version 7): the first 48 bits are the
    # given time in Unix milliseconds, the rest random. Trace ids carry the
    # request's start time this way, which SecureRandom.uuid_v7 (always "now")
    # cannot do.
    module UuidV7
      VARIANT_NIBBLES = %w[8 9 a b].freeze

      def self.generate(time = Time.now)
        hex = hex_digits(time)
        "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
      end

      # 32 hex digits: 48 bits of time, the version, the variant, randomness.
      def self.hex_digits(time)
        milliseconds = (time.to_r * 1000).to_i & 0xFFFF_FFFF_FFFF
        hex = format("%012x", milliseconds) + SecureRandom.random_bytes(10).unpack1("H*")
        hex[12] = "7"
        hex[16] = VARIANT_NIBBLES[hex[16].to_i(16) & 3]
        hex
      end
    end
  end
end
