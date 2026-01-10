# frozen_string_literal: true

require "test_helper"

class TestUprbRequireTracker < Minitest::Test
  def setup = Uprb::RequireTracker.start
  def teardown = Uprb::RequireTracker.stop

  def test_records
    require "pathname"

    tracked = Uprb::RequireTracker.mapping["pathname"]
    assert tracked
    assert File.absolute_path?(tracked)
    assert tracked.end_with?("pathname.rb")
  end

  def test_records_dlext
    require "etc.so"

    tracked = Uprb::RequireTracker.mapping["etc.so"]
    assert tracked
    assert File.absolute_path?(tracked)
    assert tracked.end_with?("etc.#{RbConfig::CONFIG['DLEXT']}")
  end

  def test_records_dlext_with_plainruby
    require "monitor"

    tracked = Uprb::RequireTracker.mapping["monitor"]
    assert tracked
    assert File.absolute_path?(tracked)
    assert tracked.end_with?("monitor.rb")
  end

  def test_records_require_reltive
    require_relative "fixtures/require_relative.rb"

    caller_path = fixture_path("require_relative.rb")
    assert caller_path == Uprb::RequireTracker.mapping[caller_path]

    relative_path = fixture_path("foo/bar")
    assert "#{relative_path}.rb" == Uprb::RequireTracker.mapping[relative_path]
  end
end
