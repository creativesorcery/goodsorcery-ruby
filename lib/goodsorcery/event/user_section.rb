# frozen_string_literal: true

module GoodSorcery
  module Event
    # Keeps only the four user fields the server accepts. Reads them from a
    # hash (string or symbol keys) or from an object such as a User model.
    module UserSection
      FIELDS = %w[id email username name].freeze
      MAX_LENGTH = 255

      module_function

      def build(user)
        return nil if user.nil?

        fields = FIELDS.to_h { |field| [field, value(read(user, field))] }.compact
        fields.empty? ? nil : fields
      end

      def read(user, field)
        return user.fetch(field) { user[field.to_sym] } if user.is_a?(Hash)

        user.public_send(field) if user.respond_to?(field)
      rescue StandardError
        nil
      end

      def value(raw)
        return raw if raw.is_a?(Integer)
        return nil if raw.nil?

        Text.limit(raw, MAX_LENGTH)
      end
    end
  end
end
