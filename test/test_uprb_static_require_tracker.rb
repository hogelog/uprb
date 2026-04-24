# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestUprbStaticRequireTracker < Minitest::Test
  def test_records_stdlib
    mapping = Uprb::StaticRequireTracker.trace(fixture_path("require_time.rb"))

    assert mapping["time"]
    assert File.absolute_path?(mapping["time"])
    assert mapping["time"].end_with?("time.rb")
  end

  def test_records_dlext
    mapping = Uprb::StaticRequireTracker.trace(fixture_path("require_etc_so.rb"))

    tracked = mapping["etc.so"]
    assert tracked
    assert File.absolute_path?(tracked)
    assert tracked.end_with?("etc.#{RbConfig::CONFIG['DLEXT']}")
  end

  def test_records_require_relative
    mapping = Uprb::StaticRequireTracker.trace(fixture_path("require_relative.rb"))

    relative_path = fixture_path("foo/bar")
    assert_equal "#{relative_path}.rb", mapping[relative_path]
  end

  def test_records_preloaded_requires
    mapping = Uprb::StaticRequireTracker.trace(
      fixture_path("require_time.rb"),
      requires: ["rubygems/version"],
    )

    assert mapping["rubygems/version"]
    assert mapping["rubygems/version"].end_with?("rubygems/version.rb")
  end

  def test_ignores_non_literal_requires_in_entry
    Dir.mktmpdir do |dir|
      path = File.join(dir, "dyn.rb")
      File.write(path, <<~RUBY)
        name = "time"
        require name
        require "json"
      RUBY

      mapping = Uprb::StaticRequireTracker.trace(path)

      # Dynamic-string require in the entry can't be statically resolved and
      # the entry's top-level code never runs, so `require name` is skipped.
      refute mapping.key?("time")
      assert mapping["json"]
    end
  end

  def test_captures_dynamic_requires_inside_libraries
    # The entry's own non-literal requires are skipped, but libraries
    # reachable via literal requires run normally and contribute whatever
    # they dynamically require.
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib.rb")
      File.write(lib, <<~RUBY)
        name = "time"
        require name
      RUBY
      entry = File.join(dir, "entry.rb")
      File.write(entry, "require_relative \"lib\"\n")

      mapping = Uprb::StaticRequireTracker.trace(entry)

      assert mapping["time"], "dynamic-string require inside library should be captured by the dynamic phase"
    end
  end

  def test_does_not_execute_entry_top_level_code
    Dir.mktmpdir do |dir|
      entry = File.join(dir, "entry.rb")
      File.write(entry, <<~RUBY)
        require "time"
        raise "entry must not execute"
      RUBY

      mapping = Uprb::StaticRequireTracker.trace(entry)

      assert mapping["time"]
    end
  end

  def test_follows_autoload_paths
    Dir.mktmpdir do |dir|
      inner = File.join(dir, "inner.rb")
      File.write(inner, "class Inner; end\n")
      entry = File.join(dir, "entry.rb")
      File.write(entry, <<~RUBY)
        module Foo
          autoload :Inner, "#{inner}"
        end
      RUBY

      mapping = Uprb::StaticRequireTracker.trace(entry)

      assert_equal inner, mapping[inner]
    end
  end

  def test_recurses_into_required_files
    mapping = Uprb::StaticRequireTracker.trace(fixture_path("require_time.rb"))

    # time.rb requires date internally; static analysis should follow it.
    assert mapping["date"]
  end
end
