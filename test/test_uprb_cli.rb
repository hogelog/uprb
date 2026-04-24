# frozen_string_literal: true

require "test_helper"
require "open3"

class TestUprbCLI < Minitest::Test
  def test_pack_builds_executable
    dest = File.join("tmp", "require_etc_so")

    stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest, "--force")
    assert status.success?, stderr
    assert_includes stdout, dest
  end

  def test_pack_with_require_option_resolves_gem_version
    dest = File.join("tmp", "gem_version")

    stdout, stderr, status = run_cli(
      "pack", fixture_path("gem_version.rb"), dest, "--force", "-r", "rubygems/version"
    )
    assert status.success?, stderr
    assert_includes stdout, dest

    out, run_status = Open3.capture2e(dest)
    assert run_status.success?, out
    assert_includes out, "1.2.3"
  end

  def test_pack_with_rubygems_flag_resolves_gem_constants
    dest = File.join("tmp", "gem_platform")

    stdout, stderr, status = run_cli(
      "pack", fixture_path("gem_platform.rb"), dest, "--force", "--with-rubygems"
    )
    assert status.success?, stderr
    assert_includes stdout, dest

    out, run_status = Open3.capture2e(dest)
    assert run_status.success?, out
    assert_includes out, "ok"
  end

  def test_pack_with_dynamic_option_builds_executable
    dest = File.join("tmp", "require_time_dynamic")

    stdout, stderr, status = run_cli(
      "pack", fixture_path("require_time.rb"), dest, "--force", "--dynamic"
    )
    assert status.success?, stderr
    assert_includes stdout, dest

    out, run_status = Open3.capture2e(dest)
    assert run_status.success?, out
    assert_includes out, "Time parsed: 2024-01-02 03:04:05 UTC"
  end

  def test_pack_with_dynamic_forwards_trailing_args_to_argv
    dest = File.join("tmp", "echo_argv")

    _stdout, stderr, status = run_cli(
      "pack", fixture_path("echo_argv.rb"), dest, "--force", "--dynamic",
      "--", "one", "two",
    )
    refute status.success?
    assert_includes stderr, '["one", "two"]'
  end

  def test_pack_with_skip_disable_gems_drops_flag_from_shebang
    dest = File.join("tmp", "skip_disable_gems")

    stdout, stderr, status = run_cli(
      "pack", fixture_path("require_etc_so.rb"), dest, "--force", "--skip-disable-gems"
    )
    assert status.success?, stderr
    assert_includes stdout, dest

    shebang = File.open(dest, &:readline)
    assert_includes shebang, RbConfig.ruby
    refute_includes shebang, "--disable-gems"

    out, run_status = Open3.capture2e(dest)
    assert run_status.success?, out
    assert_includes out, "Etc loaded: true"
  end

  def test_pack_with_skip_ruby_path_replace_keeps_source_ruby_invocation
    dest = File.join("tmp", "skip_ruby_path_replace")

    stdout, stderr, status = run_cli(
      "pack", fixture_path("with_shebang.rb"), dest, "--force", "--skip-ruby-path-replace"
    )
    assert status.success?, stderr
    assert_includes stdout, dest

    shebang = File.open(dest, &:readline).chomp
    assert_equal "#!/usr/bin/env ruby --disable-gems", shebang
  end

  def test_pack_with_skip_ruby_path_replace_is_orthogonal_to_skip_disable_gems
    dest = File.join("tmp", "skip_ruby_path_replace_and_disable_gems")

    stdout, stderr, status = run_cli(
      "pack", fixture_path("with_shebang.rb"), dest, "--force",
      "--skip-ruby-path-replace", "--skip-disable-gems",
    )
    assert status.success?, stderr
    assert_includes stdout, dest

    shebang = File.open(dest, &:readline).chomp
    assert_equal "#!/usr/bin/env ruby", shebang

    out, run_status = Open3.capture2e(dest)
    assert run_status.success?, out
    assert_includes out, "Etc loaded: true"
  end

  def test_pack_shebangless_source_produces_non_executable_output
    dest = File.join("tmp", "no_shebang")

    stdout, stderr, status = run_cli("pack", fixture_path("no_shebang.rb"), dest, "--force")
    assert status.success?, stderr
    assert_includes stdout, dest

    first_line = File.open(dest, &:readline)
    refute first_line.start_with?("#!"), "expected no shebang, got: #{first_line.inspect}"
    refute File.executable?(dest), "expected non-executable output when source has no shebang"

    out, run_status = Open3.capture2e(RbConfig.ruby, dest)
    assert run_status.success?, out
    assert_includes out, "no shebang: ok"
  end

  def test_pack_default_keeps_disable_gems_in_shebang
    dest = File.join("tmp", "default_disable_gems")

    _stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest, "--force")
    assert status.success?, stderr

    shebang = File.open(dest, &:readline)
    assert_includes shebang, "--disable-gems"
  end

  def test_pack_aws_sdk_core_executable
    dest = File.join("tmp", "aws-sdk-core")

    stdout, stderr, status = run_cli("pack", fixture_path("aws-sdk-core.rb"), dest, "--force")
    assert status.success?, stderr
    assert_includes stdout, dest

    out, status = Open3.capture2e(dest)
    assert status.success?, out
    assert_includes out, "Aws"
  end

  private

  def run_cli(*args)
    Open3.capture3(
      RbConfig.ruby,
      File.expand_path("../exe/uprb", __dir__),
      *args,
    )
  end
end
