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
    # read correctly. How quotes work depends on the database (SqlDialect):
    # a backslash escapes only in MySQL and in Postgres E'…' strings, and
    # "…" is a string in MySQL (and may be one in SQLite). The two ways of
    # reading a backslash first disagree at a string that contains one, so
    # when the dialect is unknown, or a string runs on to the end of a
    # statement that was not cut off (the quotes were misread), everything
    # from that string on becomes one placeholder: a misread never leaves a
    # literal value in the text.
    class SqlNormalizer
      INPUT_LIMIT = 4_000
      OUTPUT_LIMIT = 2_000
      PLACEHOLDER = "?"
      ELLIPSIS = "…"

      COMMENT = %r{/\*.*?(?:\*/|\z)|--[^\n]*}m
      BACKTICK = /`[^`]*(?:`|\z)/
      DOLLAR_QUOTED = /\$(?<tag>(?:[a-z_]\w*)?)\$.*?(?:(?<close>\$\k<tag>\$)|\z)/mi
      STANDARD_STRING = /'(?:[^']|'')*(?:(?<close>')|\z)/
      BACKSLASH_STRING = /'(?:[^'\\]|\\.|'')*(?:(?<close>')|\z)/m
      ESCAPE_STRING = /(?<![\w$])[eE]'(?:[^'\\]|\\.|'')*(?:(?<close>')|\z)/m
      STANDARD_DOUBLE = /"(?:[^"]|"")*(?:(?<close>")|\z)/
      BACKSLASH_DOUBLE = /"(?:[^"\\]|\\.|"")*(?:(?<close>")|\z)/m
      NUMBER = /(?<![\w$])(?:0x[0-9a-f]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)/i
      # What an unquoted identifier may contain; other "…" text is a value.
      IDENTIFIER = /\A[[:alnum:]_$]*\z/

      def self.token(strings, double)
        /(?<comment>#{COMMENT})|(?<backtick>#{BACKTICK})|(?<double>#{double})
         |(?<literal>#{DOLLAR_QUOTED}|#{strings})|(?<number>#{NUMBER})/x
      end

      # One way of reading quotes: the token pattern and what "…" is
      # (:identifier, :literal, or :guess from its contents).
      Rules = Struct.new(:token, :double)
      RULES = {
        postgres: Rules.new(token(/#{ESCAPE_STRING}|#{STANDARD_STRING}/, STANDARD_DOUBLE), :identifier),
        sqlite: Rules.new(token(STANDARD_STRING, STANDARD_DOUBLE), :guess),
        mysql: Rules.new(token(BACKSLASH_STRING, BACKSLASH_DOUBLE), :literal),
        nil => Rules.new(token(BACKSLASH_STRING, BACKSLASH_DOUBLE), :guess)
      }.freeze

      LIST_ITEM = /(?:-?\?|\$\d+)/
      IN_LIST = /\bIN\s*\(\s*#{LIST_ITEM}(?:\s*,\s*#{LIST_ITEM})*\s*\)/io
      VALUES_ROWS = /(\bVALUES\s*\([^()]*\))(?:\s*,\s*\([^()]*\))+/i
      WHITESPACE = /\s+/

      # +dialect+ is :postgres, :mysql, :sqlite or nil (unknown).
      def normalize(sql, dialect = nil)
        text = Text.utf8(sql.is_a?(String) ? sql : sql.to_s)
        cut = text.length > INPUT_LIMIT
        text = remove_literals(Text.limit(text, INPUT_LIMIT), dialect, cut)
        text = text.gsub(IN_LIST, "IN (#{ELLIPSIS})").gsub(VALUES_ROWS) { "#{Regexp.last_match(1)}, #{ELLIPSIS}" }
        Text.limit(text.gsub(WHITESPACE, " ").strip, OUTPUT_LIMIT)
      end

      private

      # With a known dialect, a string left open is trusted only where the
      # length cap cut the statement.
      def remove_literals(text, dialect, cut)
        rules = RULES.fetch(dialect, RULES[nil])
        pass = Pass.new(text, rules)
        at = pass.first_backslash
        return pass.result if at.nil? || (dialect && (pass.closed? || cut))

        "#{Pass.new(text[0, at], rules).result} #{PLACEHOLDER}"
      end

      # One left-to-right replacement of comments, literals and numbers.
      class Pass
        attr_reader :result, :first_backslash

        def initialize(text, rules)
          @rules = rules
          @open = false
          @first_backslash = nil
          @result = text.gsub(rules.token) { replacement(Regexp.last_match) }
        end

        # => false when a string ran on to the end of the text.
        def closed? = !@open

        private

        def replacement(match)
          return " " if match[:comment]
          return match[0] if match[:backtick] || identifier?(match)

          note_quote(match) unless match[:number]
          PLACEHOLDER
        end

        def identifier?(match)
          return false unless (double = match[:double])

          case @rules.double
          when :identifier then true
          when :literal then false
          else IDENTIFIER.match?(double[1..].delete_suffix("\""))
          end
        end

        # Where the first quoted value holding a backslash starts, and
        # whether one ran on to the end.
        def note_quote(match)
          @first_backslash ||= match.begin(0) if match[0].include?("\\")
          @open = true if match[:close].nil?
        end
      end
    end

    # Which SQL dialect a sql.active_record payload's connection speaks
    # (:postgres, :mysql, :sqlite, or nil), cached per adapter class.
    module SqlDialect
      MAX_ENTRIES = 32
      @cache = {}

      def self.for(connection)
        return nil unless connection.respond_to?(:adapter_name)

        klass = connection.class
        return @cache[klass] if @cache.key?(klass)

        dialect = from_name(connection.adapter_name)
        @cache[klass] = dialect if @cache.size < MAX_ENTRIES
        dialect
      end

      def self.from_name(name)
        case name.to_s
        when /mysql|trilogy|maria/i then :mysql
        when /postg|cockroach/i then :postgres
        when /sqlite/i then :sqlite
        end
      end
    end
  end
end
