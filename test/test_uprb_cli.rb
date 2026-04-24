# frozen_string_literal: true

require "test_helper"
require "bundler"
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

    out, run_status = Bundler.with_unbundled_env { Open3.capture2e(dest) }
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

    out, run_status = Bundler.with_unbundled_env { Open3.capture2e(dest) }
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

    out, run_status = Bundler.with_unbundled_env { Open3.capture2e(dest) }
    assert run_status.success?, out
    assert_includes out, "Time parsed: 2024-01-02 03:04:05 UTC"
  end

  def test_pack_aws_sdk_core_executable
    dest = File.join("tmp", "aws-sdk-core")

    stdout, stderr, status = run_cli("pack", fixture_path("aws-sdk-core.rb"), dest, "--force")
    assert status.success?, stderr
    assert_includes stdout, dest

    out, status = Bundler.with_unbundled_env { Open3.capture2e(dest) }
    assert status.success?, out
    assert_includes out, "Aws"
  end

  private

  def run_cli(*args)
    Bundler.with_unbundled_env do
      Open3.capture3(
        RbConfig.ruby,
        File.expand_path("../exe/uprb", __dir__),
        *args
      )
    end
  end
end
