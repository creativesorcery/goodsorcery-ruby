# frozen_string_literal: true

require "test_helper"

class KeyFilterTest < Minitest::Test
  FILTERED = GoodSorcery::KeyFilter::FILTERED

  def filter(patterns)
    GoodSorcery::KeyFilter.new(patterns)
  end

  def test_regexp_matches_any_part_of_a_key
    key_filter = filter([/_key/i])

    assert key_filter.filter_key?("api_key")
    assert key_filter.filter_key?("SECRET_KEY_BASE")
    refute key_filter.filter_key?("keyboard")
  end

  def test_regexps_read_dashes_as_underscores_too
    key_filter = filter(GoodSorcery::Defaults::FILTER_PARAMS)

    %w[X-Access-Key X-Private-Key X-Auth-Key stripe-key].each { |name| assert key_filter.filter_key?(name), name }
    refute key_filter.filter_key?("X-Request-Id")
    refute key_filter.filter_key?("Keep-Alive")
  end

  def test_string_matches_whole_key_case_insensitively_with_dash_and_underscore_equal
    key_filter = filter(["secret_key"])

    assert key_filter.filter_key?("secret_key")
    assert key_filter.filter_key?("Secret-Key")
    assert key_filter.filter_key?(:SECRET_KEY)
    refute key_filter.filter_key?("my_secret_key")
    refute key_filter.filter_key?("secret")
  end

  def test_symbols_match_whole_keys
    key_filter = filter(%i[card_token ssn])

    assert key_filter.filter_key?("card_token")
    refute key_filter.filter_key?("card_token_id")
  end

  def test_masks_values_at_any_depth
    result = filter(GoodSorcery::Defaults::FILTER_PARAMS).filter(
      "user" => { "name" => "Mara", "password" => "hunter2", "emails" => ["a@b.c"] },
      "items" => [{ "api_key" => "k", "sku" => 1 }],
      "Authorization" => "Bearer x"
    )

    assert_equal({ "name" => "Mara", "password" => FILTERED, "emails" => FILTERED }, result["user"])
    assert_equal [{ "api_key" => FILTERED, "sku" => 1 }], result["items"]
    assert_equal FILTERED, result["Authorization"]
  end

  def test_masks_a_whole_nested_value
    assert_equal({ "secret" => FILTERED }, filter([/secret/i]).filter("secret" => { "a" => [1, 2] }))
  end

  def test_does_not_mutate_the_input
    input = { "password" => "x", "nested" => { "token" => "y" } }
    filter([/password/, /token/]).filter(input)

    assert_equal({ "password" => "x", "nested" => { "token" => "y" } }, input)
  end

  def test_caps_depth
    deep = { "a" => nil }
    cursor = deep
    30.times do
      cursor["a"] = { "a" => nil }
      cursor = cursor["a"]
    end

    assert_includes filter([]).filter(deep).to_s, "[truncated]"
  end

  def test_filters_url_query_strings
    key_filter = filter(GoodSorcery::Defaults::FILTER_PARAMS)

    assert_equal "https://x.dev/cb?token=[FILTERED]&page=2",
                 key_filter.filter_url("https://x.dev/cb?token=abc&page=2")
    assert_equal "/s?user%5Bpassword%5D=[FILTERED]&q=1#top", key_filter.filter_url("/s?user%5Bpassword%5D=p&q=1#top")
    assert_equal "https://x.dev/plain", key_filter.filter_url("https://x.dev/plain")
  end

  def test_default_list_is_extendable_and_replaceable
    config = GoodSorcery::Configuration.new
    config.filter_params += %i[card_token]
    config.filter_params += [/_key\z/i, /secret_key/i]
    extended = filter(config.filter_params)

    assert extended.filter_key?("card_token")
    assert extended.filter_key?("password")
    assert extended.filter_key?("email")

    config.filter_params -= [/email/i]
    refute filter(config.filter_params).filter_key?("email")

    config.filter_params = [/password/i]
    replaced = filter(config.filter_params)

    refute replaced.filter_key?("token")
    assert replaced.filter_key?("password_confirmation")
  end
end

class EventFilterTest < Minitest::Test
  UpcaseFilter = Struct.new(:key) do
    def filter(hash)
      hash.to_h { |name, value| [name, name == key ? "[RAILS]" : value] }
    end
  end

  def event
    {
      "request" => {
        "url" => "https://x.dev/?token=abc",
        "params" => { "password" => "p", "q" => "shoes" },
        "headers" => { "Cookie" => "c", "Accept" => "text/html" },
        "session" => { "session_id" => "s", "cart_id" => 1 }
      },
      "user" => { "email" => "mara@example.com" },
      "context" => { "secret" => "x" },
      "tags" => { "api_key" => "k", "region" => "eu" },
      "breadcrumbs" => [{ "message" => "m", "data" => { "otp" => "123" } }]
    }
  end

  def test_filters_every_free_form_section_but_not_the_user
    filtered = GoodSorcery::EventFilter.new(GoodSorcery::KeyFilter.new(GoodSorcery::Defaults::FILTER_PARAMS))
                                       .filter_event(event)

    assert_equal "https://x.dev/?token=[FILTERED]", filtered["request"]["url"]
    assert_equal({ "password" => "[FILTERED]", "q" => "shoes" }, filtered["request"]["params"])
    assert_equal "[FILTERED]", filtered["request"]["headers"]["Cookie"]
    assert_equal "[FILTERED]", filtered["request"]["session"]["session_id"]
    assert_equal "[FILTERED]", filtered["context"]["secret"]
    assert_equal({ "api_key" => "[FILTERED]", "region" => "eu" }, filtered["tags"])
    assert_equal "[FILTERED]", filtered["breadcrumbs"][0]["data"]["otp"]
    assert_equal "mara@example.com", filtered["user"]["email"]
  end

  def test_applies_extra_filters_after_key_filter
    event_filter = GoodSorcery::EventFilter.new(GoodSorcery::KeyFilter.new([]), [UpcaseFilter.new("q")])

    assert_equal "[RAILS]", event_filter.filter_event(event)["request"]["params"]["q"]
  end

  # Masks nested values too, like ActiveSupport::ParameterFilter does.
  DeepFilter = Struct.new(:key) do
    def filter(hash)
      hash.to_h do |name, value|
        next [name, "[FILTERED]"] if name == key

        [name, value.is_a?(Hash) ? filter(value) : value]
      end
    end
  end

  def test_extra_filters_apply_to_the_url_query_too
    event_filter = GoodSorcery::EventFilter.new(GoodSorcery::KeyFilter.new([]), [DeepFilter.new("pin")])
    url = "https://x.dev/a?pin=1234&user%5Bpin%5D=99&ids[]=3&page=2#top"
    filtered = event_filter.filter_event({ "request" => { "url" => url } })

    assert_equal "https://x.dev/a?pin=[FILTERED]&user%5Bpin%5D=[FILTERED]&ids[]=3&page=2#top",
                 filtered["request"]["url"]
  end

  def test_extra_filter_probe_follows_nested_paths
    probe = GoodSorcery::ExtraFilterProbe.new([DeepFilter.new("pin")])

    assert probe.filters_path?(%w[user pin])
    refute probe.filters_path?(%w[user name])
    refute probe.filters_path?([])
  end
end
