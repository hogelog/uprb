# frozen_string_literal: true

require "test_helper"
require "bundler"
require "open3"

class TestUprbCLI < Minitest::Test
  def test_pack_builds_executable
    dest = File.join("tmp", "require_etc_so")

    stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest)
    assert status.success?, stderr
    assert_includes stdout, dest
  end

  def test_pack_aws_sdk_core_executable
    dest = File.join("tmp", "aws-sdk-core")

    stdout, stderr, status = run_cli("pack", fixture_path("aws-sdk-core.rb"), dest)
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
