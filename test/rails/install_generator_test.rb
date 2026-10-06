# frozen_string_literal: true

require_relative "support/rails_app"
require "rails/generators/test_case"
require "generators/goodsorcery/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests GoodSorcery::Generators::InstallGenerator
  destination File.join(Dir.tmpdir, "goodsorcery-generator-test")
  setup :prepare_destination
  setup :write_gemfile

  API_KEY = "gs_test_0123456789abcdef"

  def write_gemfile
    File.write(File.join(destination_root, "Gemfile"), "source \"https://rubygems.org\"\ngem \"goodsorcery\"\n")
  end

  def credentials(with_key: true)
    config_dir = File.join(destination_root, "config")
    FileUtils.mkdir_p(config_dir)
    key_path = File.join(config_dir, "master.key")
    File.write(key_path, ActiveSupport::EncryptedConfiguration.generate_key) if with_key
    ActiveSupport::EncryptedConfiguration.new(config_path: File.join(config_dir, "credentials.yml.enc"),
                                              key_path: key_path, env_key: "GOODSORCERY_TEST_UNUSED_KEY",
                                              raise_if_missing_key: false)
  end

  def with_credentials(credentials)
    previous = Rails.application.credentials
    Rails.application.credentials = credentials
    yield
  ensure
    Rails.application.credentials = previous
  end

  def test_writes_the_initializer_and_the_bundler_plugin_once
    output = run_generator
    run_generator

    assert_file "config/initializers/goodsorcery.rb", /GoodSorcery\.configure do \|config\|/
    assert_file "config/initializers/goodsorcery.rb", /# config\.send_job_arguments = true/
    assert_file("Gemfile") { |gemfile| assert_equal 1, gemfile.scan(/^plugin "goodsorcery"/).size }
    assert_includes output, "GOODSORCERY_API_KEY"
  end

  def test_stores_the_api_key_in_credentials_without_printing_it
    store = credentials
    store.write("# aws:\n#   access_key_id: 123\nsecret_key_base: abc\n")
    output = with_credentials(store) { run_generator ["--api-key=#{API_KEY}"] }
    stored = credentials(with_key: false)

    refute_includes output, API_KEY
    assert_includes output, "added goodsorcery.api_key"
    assert_equal API_KEY, stored.dig(:goodsorcery, :api_key)
    assert_equal "abc", stored[:secret_key_base]
    assert_includes stored.read, "# aws:"
  end

  def test_leaves_an_existing_api_key_alone
    store = credentials
    store.write("goodsorcery:\n  api_key: gs_live_existing\n")
    output = with_credentials(store) { run_generator ["--api-key=#{API_KEY}"] }

    assert_includes output, "already set"
    assert_equal "gs_live_existing", credentials(with_key: false).dig(:goodsorcery, :api_key)
  end

  def test_explains_what_to_do_when_credentials_cannot_be_decrypted
    output = with_credentials(credentials(with_key: false)) { run_generator ["--api-key=#{API_KEY}"] }

    refute_includes output, API_KEY
    assert_includes output, "could not be decrypted"
    assert_includes output, "GOODSORCERY_API_KEY"
  end
end
