# frozen_string_literal: true

module GoodSorcery
  # Asks the extra filters (such as Rails' filter_parameters) whether they
  # would filter a key path, by filtering a hash that holds one probe value
  # at that path. Used for URL query parameters, which are text, not hashes.
  class ExtraFilterProbe
    PROBE = "goodsorcery-probe"

    def initialize(extra_filters)
      @extra_filters = Array(extra_filters)
    end

    # +parts+ is a parameter name split on brackets: "user[pin]" => ["user", "pin"].
    def filters_path?(parts)
      return false if parts.empty?

      @extra_filters.any? { |extra| !survives?(extra.filter(probe(parts)), parts) }
    end

    private

    def probe(parts)
      parts.reverse.reduce(PROBE) { |inner, part| { part => inner } }
    end

    def survives?(value, parts)
      parts.each { |part| value = value.is_a?(Hash) ? value[part] : nil }
      value == PROBE
    end
  end
end
