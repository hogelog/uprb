# frozen_string_literal: true

require "test_helper"

class TestUprbRequireTracker < Minitest::Test
  def setup = Uprb::RequireTracker.start
  def teardown = Uprb::RequireTracker.stop

  def test_records
    require "set"

    tracked = Uprb::RequireTracker.mapping["set"]
    assert tracked
    assert File.absolute_path?(tracked)
    assert tracked.end_with?("set.rb")
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
end
