# frozen_string_literal: true

require "test_helper"
require "goodsorcery/integrations/rails/sql_statement"

class SqlStatementTest < Minitest::Test
  def obfuscate(sql, dialect = nil) = GoodSorcery::Integrations::Rails::SqlStatement.new(sql, dialect).obfuscated

  def test_replaces_inlined_strings_and_numbers
    sql = "UPDATE `users` SET `encrypted_password` = '$2a$12$abc', `failed` = 3 " \
          "WHERE `users`.`email` = 'mara@example.com' AND `users`.`id` = 42"

    assert_equal "UPDATE `users` SET `encrypted_password` = ?, `failed` = ? " \
                 "WHERE `users`.`email` = ? AND `users`.`id` = ?", obfuscate(sql, :mysql)
  end

  def test_handles_escaped_quotes_dollar_quotes_and_decimals
    assert_equal "SELECT ? WHERE n = ? OR n = ?", obfuscate("SELECT 'O''Reilly' WHERE n = 1.5 OR n = 2e10")
    assert_equal "SELECT ?, ?", obfuscate("SELECT 'it\\'s secret', $$body text$$", :mysql)
  end

  def test_keeps_identifiers_and_bind_placeholders
    sql = 'SELECT "users".* FROM "users" WHERE "users"."id" = $1 AND t1.col = ? LIMIT $2'

    assert_equal sql, obfuscate(sql, :postgres)
  end

  # Postgres and SQLite quote C:\ as 'C:\': reading the backslash as an escape
  # would pair the quotes wrongly and leave the next value in clear text.
  def test_a_string_ending_in_a_backslash_does_not_expose_the_next_value
    sql = "UPDATE users SET path = 'C:\\', token = 'tok_SECRET123' WHERE id = 1"

    assert_equal "UPDATE users SET path = ?, token = ? WHERE id = ?", obfuscate(sql, :postgres)
    assert_equal "UPDATE users SET path = ?, token = ? WHERE id = ?", obfuscate(sql, :sqlite)
    [nil, :mysql].each { |dialect| refute_includes obfuscate(sql, dialect), "tok_SECRET123" }
  end

  def test_a_quote_inside_a_comment_does_not_expose_a_value
    result = obfuscate("/* don't */ SELECT * FROM users WHERE token = 'tok_SECRET123' -- it's\nLIMIT 1")

    assert_equal "SELECT * FROM users WHERE token = ? LIMIT ?", result
  end

  def test_caps_the_length_and_hides_a_string_cut_off_by_the_cap
    sql = "INSERT INTO notes (body) VALUES ('#{"s3cr3t " * 400}')"

    assert_equal "INSERT INTO notes (body) VALUES (?)", obfuscate(sql)

    long = "SELECT #{(1..400).map { |n| "c#{n}" }.join(", ")} FROM t WHERE body = '#{"s3cr3t " * 1_000}'"
    result = obfuscate(long, :postgres)

    assert_equal GoodSorcery::Integrations::Rails::SqlStatement::MAX_LENGTH, result.length
    refute_includes result, "s3cr3t"
  end
end
