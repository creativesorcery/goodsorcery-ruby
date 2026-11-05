# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Turns raw SQL into the text a trace may carry (DESIGN.md 8.6): no
    # comments, no literal values, IN lists and VALUES rows collapsed,
    # whitespace collapsed. Bind placeholders ($1), identifiers and the
    # keywords TRUE, FALSE and NULL stay readable.
    #
    # One left-to-right pass decides what each piece is, so a quote inside a
    # comment, "--" inside a string or a digit inside a quoted identifier is
    # read correctly.
    class SqlNormalizer
      INPUT_LIMIT = 4_000
      OUTPUT_LIMIT = 2_000
      PLACEHOLDER = "?"
      ELLIPSIS = "…"

      TOKEN = %r{
        (?<comment>/\*.*?(?:\*/|\z)|--[^\n]*)
        |(?<identifier>"(?:[^"]|"")*(?:"|\z)|`[^`]*(?:`|\z))
        |(?<literal>\$(?<tag>(?:[a-z_]\w*)?)\$.*?(?:\$\k<tag>\$|\z)|'(?:[^'\\]|\\.|'')*(?:'|\z))
        |(?<number>(?<![\w$])(?:0x[0-9a-f]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?))
      }mix
      LIST_ITEM = /(?:-?\?|\$\d+)/
      IN_LIST = /\bIN\s*\(\s*#{LIST_ITEM}(?:\s*,\s*#{LIST_ITEM})*\s*\)/io
      VALUES_ROWS = /(\bVALUES\s*\([^()]*\))(?:\s*,\s*\([^()]*\))+/i
      WHITESPACE = /\s+/

      def normalize(sql)
        text = Text.limit(sql, INPUT_LIMIT).gsub(TOKEN) { replacement(Regexp.last_match) }
        text = text.gsub(IN_LIST, "IN (#{ELLIPSIS})").gsub(VALUES_ROWS) { "#{Regexp.last_match(1)}, #{ELLIPSIS}" }
        Text.limit(text.gsub(WHITESPACE, " ").strip, OUTPUT_LIMIT)
      end

      private

      def replacement(match)
        return " " if match[:comment]

        match[:identifier] || PLACEHOLDER
      end
    end
  end
end
