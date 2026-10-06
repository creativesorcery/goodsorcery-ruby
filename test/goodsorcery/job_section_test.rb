# frozen_string_literal: true

require "test_helper"

class JobSectionTest < Minitest::Test
  Identified = Struct.new(:id) do
    def to_global_id = "gid://shop/Customer/#{id}"
  end

  class Opaque
    def inspect = raise("inspect must not be called")
    def to_s = raise("to_s must not be called")
  end

  def serialize(value) = GoodSorcery::JobArguments.new.serialize(value)

  def test_serializes_arguments_the_way_a_job_system_sees_them
    time = Time.utc(2026, 10, 6, 9, 30)
    result = serialize([Identified.new(88_123), { token: :abc, at: time }, 1.5, Opaque.new, String])

    assert_equal "gid://shop/Customer/88123", result[0]
    assert_equal({ "token" => "abc", "at" => time.iso8601 }, result[1])
    assert_equal 1.5, result[2]
    assert_equal "#<JobSectionTest::Opaque>", result[3]
    assert_equal "String", result[4]
  end

  def test_caps_depth_items_and_strings
    deep = { "a" => { "b" => { "c" => { "d" => { "e" => { "f" => { "g" => 1 } } } } } } }
    result = serialize([deep, ("x" * 5_000), (1..80).to_a])

    assert_equal "[truncated]", result[0].dig("a", "b", "c", "d", "e")
    assert_equal 4_096, result[1].length
    assert_equal 50, result[2].size
  end

  def test_job_section_is_built_lazily_and_filtered
    GoodSorcery.configure do |config|
      config.delivery = :test
      config.filter_params += ["customer_ref"]
    end
    enricher = Object.new
    enricher.define_singleton_method(:enrich) do |scope|
      scope.job = { "framework" => "sidekiq", "class" => "HardWorker", "retry_count" => 2, "unknown" => "x",
                    "arguments" => [{ "password" => "pw", "customer_ref" => 7, "amount" => 5 }] }
    end
    GoodSorcery.with_scope do |scope|
      scope.enricher = enricher
      GoodSorcery.notify(raise_and_rescue)
    end
    job = GoodSorcery.test_events.first["job"]

    assert_equal({ "framework" => "sidekiq", "class" => "HardWorker", "retry_count" => 2,
                   "arguments" => [{ "password" => "[FILTERED]", "customer_ref" => "[FILTERED]", "amount" => 5 }] },
                 job)
  end

  def test_enricher_runs_once_per_scope_and_its_errors_are_logged
    GoodSorcery.configure { |config| config.delivery = :test }
    calls = 0
    enricher = Object.new
    enricher.define_singleton_method(:enrich) do |_scope|
      calls += 1
      raise ArgumentError, "secret detail"
    end
    GoodSorcery.with_scope do |scope|
      scope.enricher = enricher
      2.times { GoodSorcery.notify(raise_and_rescue) }
    end

    assert_equal 1, calls
    assert_equal 2, GoodSorcery.test_events.size
    assert_includes log_output, "could not read request or job details (ArgumentError)"
    refute_includes log_output, "secret detail"
  end

  def test_iso_time_accepts_times_epoch_seconds_and_milliseconds
    time = Time.utc(2026, 10, 6, 9, 30)

    assert_equal "2026-10-06T09:30:00.000Z", GoodSorcery::Event::Fields.iso_time(time)
    assert_equal "2026-10-06T09:30:00.000Z", GoodSorcery::Event::Fields.iso_time(time.to_f)
    assert_equal "2026-10-06T09:30:00.000Z", GoodSorcery::Event::Fields.iso_time((time.to_f * 1000).to_i)
    assert_nil GoodSorcery::Event::Fields.iso_time(nil)
  end

  def test_unit_of_work_scope_only_inside_with_scope
    GoodSorcery.scope

    assert_nil GoodSorcery::Scope.unit_of_work
    GoodSorcery.with_scope { |scope| assert_same scope, GoodSorcery::Scope.unit_of_work }
  end
end
