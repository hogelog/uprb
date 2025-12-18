# frozen_string_literal: true

require "test_helper"
require "open3"

class TestUprbCLI < Minitest::Test
  def test_pack_builds_executable
    dest = File.join("tmp", "aws-sdk-core")

    stdout, stderr, status = run_cli("pack", fixture_path("aws-sdk-core.rb"), dest)
    assert status.success?, stderr
    assert_includes stdout, dest
  end

  private

  def run_cli(*args)
    Open3.capture3(
      RbConfig.ruby,
      File.expand_path("../exe/uprb", __dir__),
      *args
    )
  end
end
