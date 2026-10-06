# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # The SQL text recorded in a breadcrumb, with literal values replaced by
      # "?": quoted strings (also dollar-quoted, and one cut off by the length
      # cap) and numbers. Adapters that inline values instead of using bind
      # parameters (mysql2, prepared_statements: false, sanitize_sql) would
      # otherwise send emails, tokens or password digests unfiltered.
      # Identifiers, keywords and placeholders such as $1 stay readable.
      class SqlStatement
        MAX_LENGTH = 1_000
        # A dollar-quoted string ($$…$$, $tag$…$tag$) or a quoted one; the
        # leftmost wins, so "$" inside a quoted string is not a dollar quote.
        LITERAL = /\$((?:[a-z_]\w*)?)\$.*?(?:\$\1\$|\z)|'(?:[^'\\]|\\.|'')*(?:'|\z)/im
        NUMBER = /(?<![\w$])\d+(?:\.\d+)?(?:e[+-]?\d+)?/i
        PLACEHOLDER = "?"

        def initialize(sql)
          @sql = sql.to_s
        end

        # The first MAX_LENGTH characters, without literal values.
        def obfuscated
          Text.limit(@sql, MAX_LENGTH).gsub(LITERAL, PLACEHOLDER).gsub(NUMBER, PLACEHOLDER)
        end
      end
    end
  end
end
