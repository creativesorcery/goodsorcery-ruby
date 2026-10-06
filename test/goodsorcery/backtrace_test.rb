# frozen_string_literal: true

require "test_helper"

class BacktraceParserTest < Minitest::Test
  def parser
    GoodSorcery::Backtrace::Parser.new
  end

  def test_parses_ruby_34_labels
    frame = parser.parse("/app/app/models/cart.rb:42:in 'Cart#total'")

    assert_equal ["/app/app/models/cart.rb", 42, "Cart#total"], frame.to_a
  end

  def test_parses_older_labels
    frame = parser.parse("/app/app/models/cart.rb:42:in `block in total'")

    assert_equal ["/app/app/models/cart.rb", 42, "block in total"], frame.to_a
  end

  def test_parses_lines_without_a_method
    assert_equal ["script.rb", 7, nil], parser.parse("script.rb:7").to_a
  end

  def test_keeps_unparseable_lines_as_paths
    assert_equal ["weird", nil, nil], parser.parse("weird").to_a
  end

  def test_uses_backtrace_locations_when_available
    error = raise_and_rescue
    frame = parser.frames(error).first

    assert_equal File.expand_path("../test_helper.rb", __dir__), frame.path
    assert_kind_of Integer, frame.line
    assert_match(/raise_and_rescue/, frame.label)
  end

  def test_falls_back_to_strings
    error = RuntimeError.new("x")
    error.set_backtrace(["/a/b.rb:1:in 'A#b'", "/a/c.rb:2:in `c'"])

    assert_equal [["/a/b.rb", 1, "A#b"], ["/a/c.rb", 2, "c"]], parser.frames(error).map(&:to_a)
  end

  def test_unraised_exception_has_no_frames
    assert_empty parser.frames(RuntimeError.new("x"))
  end
end

class BacktracePathsTest < Minitest::Test
  def paths
    GoodSorcery::Backtrace::Paths.new("/srv/app/")
  end

  def test_relative_paths_under_root
    assert_equal "app/models/cart.rb", paths.relative("/srv/app/app/models/cart.rb")
    assert_equal "/usr/lib/ruby/3.4.0/set.rb", paths.relative("/usr/lib/ruby/3.4.0/set.rb")
  end

  def test_in_app_only_under_root_and_outside_vendored_code
    assert paths.in_app?("/srv/app/app/models/cart.rb")
    assert paths.in_app?("app/models/cart.rb")
    refute paths.in_app?("/srv/app/vendor/bundle/ruby/3.4.0/gems/rack-3.1/lib/rack.rb")
    refute paths.in_app?("/srv/app/node_modules/x/y.rb")
    refute paths.in_app?("/srv/app/gems/x.rb")
    refute paths.in_app?("/usr/lib/ruby/gems/3.4.0/gems/rails/x.rb")
    refute paths.in_app?("<internal:kernel>")
    refute paths.in_app?("/srv/application/x.rb")
  end
end

class LineCacheTest < Minitest::Test
  def test_reads_files_under_root_only
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      path = File.join(root, "a.rb")
      File.write(path, "one\ntwo\n")
      cache = GoodSorcery::Backtrace::LineCache.new(GoodSorcery::Backtrace::Paths.new(root))

      assert_equal %w[one two], cache.lines(path)
      assert_nil cache.lines(__FILE__)
      assert_nil cache.lines(File.join(root, "../etc/passwd"))
    end
  end

  def test_skips_large_files
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      path = File.join(root, "big.rb")
      File.write(path, "x" * 1_100_000)
      cache = GoodSorcery::Backtrace::LineCache.new(GoodSorcery::Backtrace::Paths.new(root))

      assert_nil cache.lines(path)
    end
  end

  def test_evicts_least_recently_used
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      files = %w[a b c].map { |name| File.join(root, "#{name}.rb").tap { |path| File.write(path, name) } }
      cache = GoodSorcery::Backtrace::LineCache.new(GoodSorcery::Backtrace::Paths.new(root), max_files: 2)
      cache.lines(files[0])
      cache.lines(files[1])
      cache.lines(files[0])
      cache.lines(files[2])
      File.write(files[0], "changed")
      File.write(files[1], "changed")

      assert_equal ["a"], cache.lines(files[0])
      assert_equal ["changed"], cache.lines(files[1])
    end
  end
end

class CodeContextTest < Minitest::Test
  def test_five_lines_around_clamped_to_the_file
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      path = File.join(root, "f.rb")
      File.write(path, (1..20).map { |n| "line #{n}" }.join("\n"))
      context = GoodSorcery::Backtrace::CodeContext.new(
        GoodSorcery::Backtrace::LineCache.new(GoodSorcery::Backtrace::Paths.new(root))
      )

      middle = context.around(path, 10)
      assert_equal 5, middle["start_line"]
      assert_equal (5..15).map { |n| "line #{n}" }, middle["lines"]
      assert_equal 1, context.around(path, 2)["start_line"]
      assert_equal 6, context.around(path, 20)["lines"].size
      assert_nil context.around(path, 99)
    end
  end
end
