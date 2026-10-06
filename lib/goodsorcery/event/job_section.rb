# frozen_string_literal: true

module GoodSorcery
  module Event
    # The "job" section (DESIGN.md 5.1): which job ran, where, and with which
    # arguments. Keeps the known fields only; arguments are capped like
    # request params and filtered by EventFilter afterwards.
    module JobSection
      TEXT_FIELDS = %w[
        framework class id provider_job_id queue mailer action enqueued_at scheduled_at
      ].freeze
      INTEGER_FIELDS = %w[priority executions retry_count].freeze
      MAX_TEXT_LENGTH = 255

      module_function

      def build(raw, sanitizer)
        return nil unless raw.is_a?(Hash)

        section = {}
        raw.each { |key, value| add(section, key.to_s, value, sanitizer) }
        section.empty? ? nil : section
      end

      def add(section, key, value, sanitizer)
        return if value.nil?

        section[key] = Text.limit(value, MAX_TEXT_LENGTH) if TEXT_FIELDS.include?(key)
        section[key] = value if INTEGER_FIELDS.include?(key) && value.is_a?(Integer)
        section[key] = sanitizer.sanitize(value) if key == "arguments"
      end
    end
  end
end
