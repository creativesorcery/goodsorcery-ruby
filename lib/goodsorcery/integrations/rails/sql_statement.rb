# frozen_string_literal: true

module GoodSorcery
  module Integrations
    module Rails
      # The SQL text recorded in a breadcrumb: the performance normaliser
      # (Performance::SqlNormalizer) applied with the connection's dialect,
      # capped at MAX_LENGTH. Literal values become "?" and comments are
      # removed. Adapters that inline values instead of using bind parameters
      # (mysql2, prepared_statements: false, sanitize_sql) would otherwise
      # send emails, tokens or password digests unfiltered. Sharing the
      # normaliser means a backslash or a quote inside a comment is read the
      # way the database reads it, and a misread never leaves a value behind.
      # Identifiers, keywords and placeholders such as $1 stay readable.
      class SqlStatement
        MAX_LENGTH = 1_000
        NORMALIZER = Performance::SqlNormalizer.new.freeze

        # +dialect+ is :postgres, :mysql, :sqlite or nil (unknown).
        def initialize(sql, dialect = nil)
          @sql = sql
          @dialect = dialect
        end

        # At most MAX_LENGTH characters, without literal values or comments.
        def obfuscated
          Text.limit(NORMALIZER.normalize(@sql, @dialect), MAX_LENGTH)
        end
      end
    end
  end
end
