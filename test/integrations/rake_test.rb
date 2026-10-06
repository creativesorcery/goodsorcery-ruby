# frozen_string_literal: true

require "test_helper"
require "open3"
require "rake"
require "goodsorcery/tasks"

class RakeIntegrationTest < Minitest::Test
  class TaskError < StandardError; end

  def setup
    super
    GoodSorcery.configure { |config| config.delivery = :test }
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
  end

  def teardown
    Rake.application = @previous_application
    super
  end

  def run_top_level(command_line)
    app = Rake.application
    app.instance_variable_set(:@top_level_tasks, [command_line])
    error = assert_raises(TaskError) { app.invoke_task(command_line) }
    app.options.trace_output = StringIO.new
    app.display_error_message(error)
    error
  end

  def test_reports_the_failing_task_with_its_filtered_arguments
    Rake::Task.define_task(:import, %i[file password]) { raise TaskError, "bad row" }
    run_top_level("import[users.csv,hunter2]")
    event = GoodSorcery.test_events.first

    assert_equal 1, GoodSorcery.test_events.size
    assert_equal "rake import", event["transaction"]
    assert_equal({ "task" => "import", "arguments" => { "file" => "users.csv", "password" => "[FILTERED]" } },
                 event["context"]["rake"])
  end

  def test_names_the_innermost_failing_task
    Rake::Task.define_task(:inner) { raise TaskError, "inner" }
    Rake::Task.define_task(outer: :inner)
    run_top_level("outer")

    assert_equal "rake outer", GoodSorcery.test_events.first["transaction"]
    assert_equal "inner", GoodSorcery.test_events.first["context"]["rake"]["task"]
  end

  def test_reports_and_sends_before_a_real_rake_process_exits
    server = FakeServer.new
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Rakefile"), <<~RUBY)
        require "goodsorcery"
        require "goodsorcery/tasks"
        GoodSorcery.configure { |config| config.flush_interval = 30 }
        task(:explode) { raise ArgumentError, "kaboom" }
      RUBY
      _out, err, status = run_rake(dir, server.endpoint)

      refute status.success?
      assert_includes err, "kaboom"
    end
    event = server.requests.first.json["events"].first
    assert_equal "rake explode", event["transaction"]
    assert_equal "explode", event["context"]["rake"]["task"]
  ensure
    server&.stop
  end

  def run_rake(dir, endpoint)
    env = { "GOODSORCERY_API_KEY" => "gs_test_0123456789abcdef", "GOODSORCERY_ENDPOINT" => endpoint,
            "GOODSORCERY_ENV" => "production" }
    lib = File.expand_path("../../lib", __dir__)
    Open3.capture3(env, Gem.ruby, "-I", lib, Gem.bin_path("rake", "rake"), "-f", File.join(dir, "Rakefile"),
                   "explode", chdir: dir)
  end
end
