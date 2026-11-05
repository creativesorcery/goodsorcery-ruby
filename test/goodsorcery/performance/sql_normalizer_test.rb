# frozen_string_literal: true

require "test_helper"

class SqlNormalizerTest < Minitest::Test
  def normalize(sql) = GoodSorcery::Performance::SqlNormalizer.new.normalize(sql)

  def test_bind_placeholders_and_identifiers_stay
    sql = 'SELECT "users".* FROM "users" WHERE "users"."id" = $1 LIMIT $2'

    assert_equal sql, normalize(sql)
  end

  def test_string_literals_become_placeholders
    assert_equal "SELECT * FROM users WHERE email = ? AND name = ?",
                 normalize("SELECT * FROM users WHERE email = 'mara@example.com' AND name = 'O''Brien'")
  end

  def test_backslash_escaped_quotes_stay_inside_the_literal
    assert_equal "SELECT ? FROM t WHERE a = ?", normalize("SELECT 'it\\'s secret' FROM t WHERE a = 'x'")
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
                 normalize('SELECT "2fa_codes"."it\'s" FROM "2fa_codes" WHERE id = 7')
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
