# frozen_string_literal: true

require "test_helper"
require "goodsorcery/install_check"
require "goodsorcery/bundler_plugin"
require "rake"

class BundlerPluginGateTest < Minitest::Test
  Dependency = Struct.new(:name)
  DEPENDENCIES = [Dependency.new("rails"), Dependency.new("goodsorcery")].freeze

  def open?(env, dependencies = DEPENDENCIES)
    GoodSorcery::BundlerPlugin::Gate.new(env, dependencies).open?
  end

  def test_runs_in_development_by_default
    assert open?({})
    assert open?("RAILS_ENV" => "development", "RACK_ENV" => "", "APP_ENV" => "development")
  end

  def test_skips_other_environments
    refute open?("RAILS_ENV" => "production")
    refute open?("RACK_ENV" => "test")
    refute open?("APP_ENV" => "staging")
  end

  def test_skips_in_ci_and_when_asked
    refute open?("CI" => "true")
    refute open?("GOODSORCERY_SKIP_INSTALL_CHECK" => "1")
  end

  def test_skips_when_the_gemfile_does_not_depend_on_the_gem
    refute open?({}, [Dependency.new("rails")])
  end

  def test_after_install_never_raises
    broken = Object.new
    def broken.name = raise("boom")

    assert_output(nil, /install check skipped: RuntimeError/) do
      GoodSorcery::BundlerPlugin.after_install([broken], env: {})
    end
  end

  def test_after_install_does_nothing_when_gated
    assert_silent { GoodSorcery::BundlerPlugin.after_install(DEPENDENCIES, env: { "CI" => "1" }) }
  end

  def test_plugins_rb_registers_the_after_install_all_hook
    hooks = []
    plugin = Module.new
    plugin.define_singleton_method(:add_hook) { |event, &block| hooks << [event, block] }
    events = Module.new
    events.const_set(:GEM_AFTER_INSTALL_ALL, "after-install-all")
    plugin.const_set(:Events, events)
    with_bundler_plugin(plugin) { load File.expand_path("../../plugins.rb", __dir__) }

    assert_equal ["after-install-all"], hooks.map(&:first)
  end

  private

  def with_bundler_plugin(plugin)
    require "bundler"
    original = Bundler::Plugin
    Bundler.send(:remove_const, :Plugin)
    Bundler.const_set(:Plugin, plugin)
    yield
  ensure
    Bundler.send(:remove_const, :Plugin)
    Bundler.const_set(:Plugin, original)
  end
end

class BundlerPluginCheckProcessTest < Minitest::Test
  def check_process(command, timeout)
    @out = StringIO.new
    GoodSorcery::BundlerPlugin::CheckProcess.new(root: Dir.pwd, timeout: timeout, command: command, out: @out)
  end

  def test_waits_for_the_check_to_finish
    assert check_process([RbConfig.ruby, "-e", "exit 0"], 5).run
  end

  def test_kills_a_check_that_outlives_the_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    refute check_process([RbConfig.ruby, "-e", "sleep 10"], 0.3).run
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    assert_includes @out.string, "[goodsorcery] install check timed out after 0.3 s"
  end
end

class InstallCheckTest < Minitest::Test
  def setup
    super
    @server = FakeServer.new { |_request| [200, {}, '{"ok":true,"environment":"staging"}'] }
    @root = Dir.mktmpdir
    @out = StringIO.new
    GoodSorcery.configure do |config|
      config.endpoint = @server.endpoint
      config.api_key = "gs_test_9f2c41aa77d0e81a"
    end
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@root)
    super
  end

  def run_check(env = {})
    GoodSorcery::InstallCheck.new(root: @root, out: @out, env: env).run
  end

  def lines
    @out.string.lines.map(&:chomp)
  end

  def test_verify_prints_a_report_and_creates_no_event
    assert run_check

    assert(lines.all? { |line| line.start_with?("[goodsorcery] ") })
    assert_includes @out.string, "endpoint:    #{@server.endpoint}"
    assert_includes @out.string, "reporting disabled: environment \"development\" is in disabled_environments"
    assert_includes @out.string, "api key:     gs_test_…e81a"
    assert_includes @out.string, "verify:      ok"
    refute_includes @out.string, "gs_test_9f2c41aa77d0e81a"
    assert_equal ["/api/v1/verify"], @server.requests.map(&:path)
  end

  def test_test_event_mode_also_sends_a_test_error_in_development
    GoodSorcery.configure { |config| config.install_check = :test_event }
    @server.handler = lambda do |request|
      if request.http_method == "GET"
        [200, {},
         '{"ok":true}']
      else
        [202, {}, '{"id":"0192f7a4-6c1e-7b3a-9d21-5f0c8e1b0aa1"}']
      end
    end

    assert run_check
    assert_includes @out.string, "test event:  ok, sent test event 0192f7a4-6c1e-7b3a-9d21-5f0c8e1b0aa1"
    assert_equal "GoodSorcery::TestError", @server.requests.last.json["exception"]["class"]
  end

  def test_disabled_check_prints_one_line
    GoodSorcery.configure { |config| config.install_check = false }

    assert run_check
    assert_equal ["[goodsorcery] install check skipped (config.install_check = false)"], lines
    assert_empty @server.requests
  end

  def test_boots_config_environment_in_development
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/environment.rb"), <<~RUBY)
      GoodSorcery.configure { |config| config.install_check = false }
      $goodsorcery_booted_env = ENV["RAILS_ENV"]
    RUBY
    env = {}
    run_check(env)

    assert_equal "development", env["RAILS_ENV"]
    assert_includes @out.string, "install check skipped"
  end

  def test_boot_errors_are_printed_as_one_line_and_never_raised
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/environment.rb"), "raise LoadError, 'cannot load such file -- missing'\n")

    refute run_check
    assert_equal ["[goodsorcery] install check failed: LoadError: cannot load such file -- missing"], lines
  end

  def test_unreachable_endpoint_is_reported
    @server.stop
    GoodSorcery.configure { |config| config.endpoint = "http://127.0.0.1:9" }

    refute run_check
    assert_match(/verify:      FAILED, could not reach/, @out.string)
  end
end

class RakeTasksTest < Minitest::Test
  def setup
    super
    @server = FakeServer.new
    GoodSorcery.configure do |config|
      config.endpoint = @server.endpoint
      config.api_key = "gs_test_9f2c41aa77d0e81a"
    end
    @rake = Rake::Application.new
    Rake.application = @rake
    load File.expand_path("../../lib/goodsorcery/tasks.rb", __dir__)
  end

  def teardown
    @server.stop
    super
  end

  def test_goodsorcery_test_always_sends_a_test_error
    output = capture_io { @rake["goodsorcery:test"].invoke }.first

    assert_match(/\[goodsorcery\] test event:  ok, sent test event \h{8}-/, output)
    assert_equal "/api/v1/events", @server.requests.first.path
    assert_equal "goodsorcery:test", @server.requests.first.json["transaction"]
  end

  def test_goodsorcery_verify_aborts_on_failure
    @server.handler = ->(_request) { [401, {}, "{}"] }

    assert_raises(SystemExit) { capture_io { @rake["goodsorcery:verify"].invoke } }
  end

  def test_tasks_invoke_the_environment_task_when_defined
    booted = false
    @rake.define_task(Rake::Task, :environment) { booted = true }
    @server.handler = ->(_request) { [200, {}, '{"ok":true}'] }
    capture_io { @rake["goodsorcery:verify"].invoke }

    assert booted
  end
end
