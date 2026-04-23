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

  def test_records_path_added_by_this_require_not_preexisting_match
    real_path = fixture_path("tracker_preload.rb")
    polluting_path = "/nonexistent/preloaded/tracker_preload.rb"
    $LOADED_FEATURES << polluting_path
    $LOAD_PATH.unshift(fixture_path(""))
    begin
      assert require("tracker_preload")
      assert_equal real_path, Uprb::RequireTracker.mapping["tracker_preload"]
    ensure
      $LOAD_PATH.delete(fixture_path(""))
      $LOADED_FEATURES.delete(polluting_path)
      $LOADED_FEATURES.delete(real_path)
    end
  end

  def test_records_parent_path_when_child_shares_basename
    parent = fixture_path("tracker_collide.rb")
    child = fixture_path("tracker_inner/tracker_collide.rb")
    $LOAD_PATH.unshift(fixture_path(""))
    begin
      assert require("tracker_collide")
      assert_equal parent, Uprb::RequireTracker.mapping["tracker_collide"]
      assert_equal child, Uprb::RequireTracker.mapping["tracker_inner/tracker_collide"]
    ensure
      $LOAD_PATH.delete(fixture_path(""))
      $LOADED_FEATURES.delete(parent)
      $LOADED_FEATURES.delete(child)
    end
  end
end
