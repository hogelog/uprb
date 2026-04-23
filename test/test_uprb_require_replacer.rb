# frozen_string_literal: true

require "test_helper"

require "open3"
require "rbconfig"

class TestUprbRequireReplacer < Minitest::Test
  DLEXT = RbConfig::CONFIG["DLEXT"]

  def test_pack_script
    script_path = File.join("tmp", "requires_etc_so")
    Uprb::RequireReplacer.pack(fixture_path("require_etc_so.rb"), dest_path: script_path)
    script = File.read(script_path)

    assert_includes script, "InstructionSequence"

    out, status = Open3.capture2e(script_path)
    assert status.success?
    assert_includes out, "Etc loaded: true"
  end

  def test_pack_default_gem
    script_path = File.join("tmp", "require_time")
    Uprb::RequireReplacer.pack(fixture_path("require_time.rb"), dest_path: script_path)

    out, status = Open3.capture2e(script_path)
    assert status.success?, out
    assert_includes out, "Time parsed: 2024-01-02 03:04:05 UTC"
  end

  def test_pack_bundled_gem
    script_path = File.join("tmp", "require_minitest")
    Uprb::RequireReplacer.pack(fixture_path("require_minitest.rb"), dest_path: script_path)

    out, status = Open3.capture2e(script_path)
    assert status.success?, out
    assert_includes out, "Minitest loaded: true"
  end
end
