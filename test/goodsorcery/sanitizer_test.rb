# frozen_string_literal: true

require "test_helper"

class SanitizerTest < Minitest::Test
  Point = Struct.new(:x, :password)

  def sanitizer
    GoodSorcery::Sanitizer.new
  end

  def test_caps_depth_at_six
    value = { "1" => { "2" => { "3" => { "4" => { "5" => { "6" => { "7" => "deep" } } } } } } }
    result = sanitizer.sanitize(value)

    assert_equal "[truncated]", result.dig("1", "2", "3", "4", "5", "6")
  end

  def test_caps_arrays_keys_and_strings
    result = sanitizer.sanitize(
      "list" => (1..80).to_a,
      "wide" => (1..150).to_h { |n| ["k#{n}", n] },
      "long" => "x" * 5_000
    )

    assert_equal 50, result["list"].size
    assert_equal 100, result["wide"].size
    assert_equal 4_096, result["long"].length
  end

  def test_turns_objects_into_json_safe_values
    time = Time.utc(2026, 10, 4, 9, 14, 3.112r)
    result = sanitizer.sanitize(
      sym: :value, time: time, point: Point.new(1, "p"), object: Object.new, nan: Float::NAN, num: 1.5
    )

    assert_equal "value", result["sym"]
    assert_equal "2026-10-04T09:14:03.112Z", result["time"]
    assert_equal({ "x" => 1, "password" => "p" }, result["point"])
    assert_match(/\A#<Object/, result["object"])
    assert_equal "NaN", result["nan"]
    assert_in_delta 1.5, result["num"]
  end

  def test_open_structs_and_sets_keep_their_structure_so_keys_are_filtered
    begin
      require "ostruct"
    rescue LoadError
      skip "ostruct is not installed"
    end
    options = OpenStruct.new(password: "hunter2", plan: "pro") # rubocop:disable Style/OpenStructUse
    result = sanitizer.sanitize("options" => options, "ids" => Set[1, 2])
    filtered = GoodSorcery::KeyFilter.new(GoodSorcery::Defaults::FILTER_PARAMS).filter(result)

    assert_equal({ "password" => "[FILTERED]", "plan" => "pro" }, filtered["options"])
    assert_equal [1, 2], filtered["ids"]
  end

  def test_repairs_invalid_utf8_and_binary_strings
    result = sanitizer.sanitize("bad" => (+"caf\xC3"), "bin" => (+"ok\xFF").force_encoding(Encoding::BINARY))

    assert_predicate result["bad"], :valid_encoding?
    assert_equal Encoding::UTF_8, result["bin"].encoding
    assert_predicate result["bin"], :valid_encoding?
  end

  def test_copies_mutable_strings
    original = +"value"
    result = sanitizer.sanitize("a" => original)
    original << " changed"

    assert_equal "value", result["a"]
  end
end
