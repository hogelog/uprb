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

  def test_packed_output_has_no_host_so_paths
    script_path = File.join("tmp", "no_host_so_paths")
    Uprb::RequireReplacer.pack(fixture_path("require_etc_so.rb"), dest_path: script_path)
    bytes = File.binread(script_path)

    refute_match(%r{/usr/lib[^\s"]*\.so}, bytes, "packed output leaks /usr/lib .so paths")
    refute_match(%r{/\.gem/[^\s"]*\.so}, bytes, "packed output leaks ~/.gem .so paths")
  end

  def test_native_hash_is_stable_across_repacks
    a = File.join("tmp", "stable_hash_a")
    b = File.join("tmp", "stable_hash_b")
    Uprb::RequireReplacer.pack(fixture_path("require_etc_so.rb"), dest_path: a)
    Uprb::RequireReplacer.pack(fixture_path("require_etc_so.rb"), dest_path: b)

    assert_equal native_hash_of(a), native_hash_of(b)
  end

  def test_build_payload_rejects_unknown_require_shape
    mapping = { "weird" => "/etc/hostname" } # absolute, exists, not .rb / .so
    error = assert_raises(Uprb::Error) do
      Uprb::RequireReplacer.send(:build_payload, mapping)
    end
    assert_match(/unsupported require shape/, error.message)
  end

  def test_build_payload_rejects_missing_relative_path
    mapping = { "weird" => "made_up_thing.txt" }
    error = assert_raises(Uprb::Error) do
      Uprb::RequireReplacer.send(:build_payload, mapping)
    end
    assert_match(/cannot bundle require/, error.message)
  end

  private

  def native_hash_of(path)
    bytes = File.binread(path)
    marker = bytes.index("__END__\n") or raise "no __END__ in #{path}"
    payload = bytes[(marker + "__END__\n".bytesize)..]
    Marshal.load(payload).fetch(:native_hash)
  end
end
