# frozen_string_literal: true

require "test_helper"

class SqlNormalizerTest < Minitest::Test
  def normalize(sql, dialect = nil) = GoodSorcery::Performance::SqlNormalizer.new.normalize(sql, dialect)

  TRAILING_BACKSLASH = "SELECT * FROM files WHERE dir = 'C:\\' AND token = 'hunter2secret' AND n = 5"

  def test_bind_placeholders_and_identifiers_stay
    sql = 'SELECT "users".* FROM "users" WHERE "users"."id" = $1 LIMIT $2'

    assert_equal sql, normalize(sql)
  end

  def test_string_literals_become_placeholders
    assert_equal "SELECT * FROM users WHERE email = ? AND name = ?",
                 normalize("SELECT * FROM users WHERE email = 'mara@example.com' AND name = 'O''Brien'")
  end

  def test_backslash_escaped_quotes_stay_inside_the_literal
    assert_equal "SELECT ? FROM t WHERE a = ?", normalize("SELECT 'it\\'s secret' FROM t WHERE a = 'x'", :mysql)
  end

  def test_dollar_quoted_strings_become_placeholders
    assert_equal "SELECT ?, ? FROM t", normalize("SELECT $$ s3cret $$, $body$ it's $body$ FROM t")
  end

  def test_a_string_cut_off_by_the_length_cap_is_replaced
    sql = "SELECT * FROM t WHERE token = 'abc#{"x" * 5_000}'"

    assert_equal "SELECT * FROM t WHERE token = ?", normalize(sql)
  end

  def test_numbers_become_placeholders_but_not_inside_identifiers_or_bind_params
    sql = "SELECT t2.col1 FROM t2 WHERE id = 42 AND price > 12.50 AND n = 1e5 AND x = $3 AND h = 0xFF"

    assert_equal "SELECT t2.col1 FROM t2 WHERE id = ? AND price > ? AND n = ? AND x = $3 AND h = ?", normalize(sql)
  end

  def test_quoted_identifiers_keep_digits_and_quotes
    assert_equal 'SELECT "2fa_codes"."it\'s" FROM "2fa_codes" WHERE id = ?',
                 normalize('SELECT "2fa_codes"."it\'s" FROM "2fa_codes" WHERE id = 7', :postgres)
  end

  # Postgres (standard_conforming_strings) and SQLite: a backslash is an
  # ordinary character, so 'C:\' ends at its second quote.
  def test_a_trailing_backslash_does_not_hide_the_next_literal
    expected = "SELECT * FROM files WHERE dir = ? AND token = ? AND n = ?"

    assert_equal expected, normalize(TRAILING_BACKSLASH, :postgres)
    assert_equal expected, normalize(TRAILING_BACKSLASH, :sqlite)
  end

  # With no dialect, a backslash in a string could be read either way, so
  # nothing after that string is kept.
  def test_with_an_unknown_dialect_everything_from_a_string_with_a_backslash_is_dropped
    assert_equal "SELECT * FROM files WHERE dir = ?", normalize(TRAILING_BACKSLASH)
    assert_equal "SELECT * FROM t WHERE a = ? AND b = ?", normalize("SELECT * FROM t WHERE a = 'x' AND b = 'C:\\'")
  end

  def test_postgres_escape_strings_honour_backslashes
    assert_equal "SELECT ? WHERE a = ? AND b = ?",
                 normalize("SELECT E'it\\'s secret' WHERE a = 'C:\\' AND b = 'secret'", :postgres)
  end

  def test_mysql_backslash_escapes
    assert_equal "SELECT ? FROM t WHERE a = ? AND b = ?",
                 normalize("SELECT 'it\\'s secret' FROM t WHERE a = 'C:\\\\' AND b = 'secret'", :mysql)
  end

  # A string left open at the end of a whole statement means the quotes
  # were misread (a database setting the gem cannot see).
  def test_a_misread_backslash_drops_everything_from_its_string
    assert_equal "SELECT ?", normalize("SELECT 'it\\'s' FROM t WHERE a = 'x' AND b = 'secret'", :postgres)
    assert_equal "SELECT * FROM files WHERE dir = ?", normalize(TRAILING_BACKSLASH, :mysql)
  end

  def test_a_statement_cut_inside_a_string_with_an_unknown_dialect_drops_everything_after_the_first_string
    sql = "SELECT * FROM t WHERE a = 'C:\\' AND token = 'secret#{"x" * 5_000}'"

    assert_equal "SELECT * FROM t WHERE a = ? AND token = ?", normalize(sql, :postgres)
    assert_equal "SELECT * FROM t WHERE a = ?", normalize(sql)
  end

  def test_double_quoted_values_are_literals_in_mysql
    assert_equal "SELECT `users`.* FROM `users` WHERE email = ? AND `users`.`id` = ?",
                 normalize('SELECT `users`.* FROM `users` WHERE email = "bob@example.com" AND `users`.`id` = 4', :mysql)
  end

  def test_double_quoted_text_that_cannot_be_an_identifier_is_a_literal_unless_postgres
    sql = 'SELECT "users".* FROM "users" WHERE "email" = "bob@example.com" AND "note" = "two words"'
    guessed = 'SELECT "users".* FROM "users" WHERE "email" = ? AND "note" = ?'

    assert_equal guessed, normalize(sql)
    assert_equal guessed, normalize(sql, :sqlite)
    assert_equal sql, normalize(sql, :postgres)
  end

  def test_dialects_from_the_connection_adapter
    dialect = GoodSorcery::Performance::SqlDialect
    adapter = Struct.new(:adapter_name)

    assert_equal(%i[postgres postgres mysql mysql sqlite],
                 %w[PostgreSQL PostGIS Mysql2 Trilogy SQLite].map { |name| dialect.from_name(name) })
    assert_nil dialect.from_name("SQLServer")
    assert_equal :mysql, dialect.for(adapter.new("Trilogy"))
    assert_nil dialect.for(nil)
  end

  def test_in_lists_collapse
    assert_equal "SELECT * FROM t WHERE id IN (…) AND k NOT IN (…)",
                 normalize("SELECT * FROM t WHERE id IN (1, 2, -3, 4) AND k NOT IN ('a','b')")
    assert_equal "SELECT * FROM t WHERE id IN (…)", normalize("SELECT * FROM t WHERE id IN ($1, $2, $3)")
    assert_equal "SELECT * FROM t WHERE id IN (…)", normalize("SELECT * FROM t WHERE id IN (7)")
  end

  def test_values_rows_collapse_to_the_first
    assert_equal 'INSERT INTO "t" ("a", "b") VALUES (?, ?), … RETURNING "id"',
                 normalize("INSERT INTO \"t\" (\"a\", \"b\") VALUES (1, 'x'), (2, 'y'), (3, 'z') RETURNING \"id\"")
  end

  def test_comments_are_removed
    sql = "SELECT 1 /*application:Shop,request_id:7f3a*/ FROM t -- note 'x'\nWHERE a = 'it''s' /* it's */"

    assert_equal "SELECT ? FROM t WHERE a = ?", normalize(sql)
  end

  def test_comment_markers_inside_strings_are_part_of_the_string
    assert_equal "SELECT ? WHERE note = ? AND c = TRUE AND d IS NULL AND e = FALSE",
                 normalize("SELECT 1 WHERE note = 'a -- b /* c' AND c = TRUE AND d IS NULL AND e = FALSE")
  end

  def test_whitespace_collapses
    assert_equal "SELECT a FROM b WHERE c = $1", normalize("  SELECT  a\n\tFROM   b\r\n WHERE c = $1  ")
  end

  def test_output_is_capped_at_2000_characters
    sql = "SELECT #{(1..900).map { |n| "col#{n}" }.join(", ")} FROM t"

    assert_equal 2_000, normalize(sql).length
  end

  def test_input_beyond_4000_characters_is_ignored
    sql = "SELECT a FROM t WHERE #{"a = $1 AND " * 400}b = 'secret'"

    refute_includes normalize(sql), "secret"
  end

  def test_nil_and_binary_input
    assert_equal "", normalize(nil)
    assert_equal "SELECT ?", normalize("SELECT '\xFF'".b)
  end
end
