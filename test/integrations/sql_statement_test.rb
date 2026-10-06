# frozen_string_literal: true

require "test_helper"
require "goodsorcery/integrations/rails/sql_statement"

class SqlStatementTest < Minitest::Test
  def obfuscate(sql) = GoodSorcery::Integrations::Rails::SqlStatement.new(sql).obfuscated

  def test_replaces_inlined_strings_and_numbers
    sql = "UPDATE `users` SET `encrypted_password` = '$2a$12$abc', `failed` = 3 " \
          "WHERE `users`.`email` = 'mara@example.com' AND `users`.`id` = 42"

    assert_equal "UPDATE `users` SET `encrypted_password` = ?, `failed` = ? " \
                 "WHERE `users`.`email` = ? AND `users`.`id` = ?", obfuscate(sql)
  end

  def test_handles_escaped_quotes_dollar_quotes_and_decimals
    assert_equal "SELECT ? WHERE n = ? OR n = ?", obfuscate("SELECT 'O''Reilly' WHERE n = 1.5 OR n = 2e10")
    assert_equal "SELECT ?, ?", obfuscate("SELECT 'it\\'s secret', $$body text$$")
  end

  def test_keeps_identifiers_and_bind_placeholders
    sql = 'SELECT "users".* FROM "users" WHERE "users"."id" = $1 AND t1.col = ? LIMIT $2'

    assert_equal sql, obfuscate(sql)
  end

  def test_caps_the_length_and_hides_a_string_cut_off_by_the_cap
    sql = "INSERT INTO notes (body) VALUES ('#{"s3cr3t " * 400}')"
    result = obfuscate(sql)

    assert_equal "INSERT INTO notes (body) VALUES (?", result
    refute_includes result, "s3cr3t"
  end
end
