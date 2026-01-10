# frozen_string_literal: true

require "test_helper"

require "open3"
require "rbconfig"

class TestUprbRequireReplacer < Minitest::Test
  DLEXT = RbConfig::CONFIG["DLEXT"]

  def test_replace_stdlib
    packed = with_tempfile(<<~CODE) {|f| Uprb::RequireReplacer.pack(f.path) }
      require "rbconfig"
    CODE

    assert_match %r["/.+/rbconfig.rb"], packed
  end

  def test_replace_defaultgem
    replaced = with_tempfile(<<~CODE) {|f| Uprb::RequireReplacer.pack(f.path) }
      require "fileutils"
    CODE

    assert_match %r["/.+/fileutils.rb"], replaced
  end

  def test_replace_bundledgem
    replaced = with_tempfile(<<~CODE) {|f| Uprb::RequireReplacer.pack(f.path) }
      require "minitest"
    CODE

    assert_match %r["/.+/minitest.rb"], replaced
  end

  def test_replace_rubygemsgem
    replaced = with_tempfile(<<~CODE) {|f| Uprb::RequireReplacer.pack(f.path) }
      require "aws-sdk-core"
    CODE

    assert_match %r["/.+/aws-sdk-core.rb"], replaced
  end


  def test_replace_require_so
    replaced = Uprb::RequireReplacer.pack(fixture_path("require_etc_so.rb"))

    assert_match %r["/.+/etc.#{DLEXT}"], replaced

    out, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", stdin_data: replaced)
    assert status.success?
    assert_includes out, "Etc loaded: true"
  end

  def test_pack_script
    script_path = File.join("tmp", "requires_etc_so")
    Uprb::RequireReplacer.pack(fixture_path("require_etc_so.rb"), dest_path: script_path)
    script = File.read(script_path)

    assert_match %r["/.+/etc.#{DLEXT}"], script
  end

  def test_pack_iseq_script
    script_path = File.join("tmp", "requires_etc_so_iseq")
    Uprb::RequireReplacer.pack_iseq(fixture_path("require_etc_so.rb"), dest_path: script_path)
    script = File.read(script_path)

    assert_includes script, "InstructionSequence"

    out, status = Open3.capture2e(script_path)
    assert status.success?
    assert_includes out, "Etc loaded: true"
  end
end
