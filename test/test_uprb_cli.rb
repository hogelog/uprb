# frozen_string_literal: true

require "test_helper"
require "uprb/cli"
require "open3"
require "stringio"

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

  def test_packed_binary_extracts_native_section_into_cache_dir
    dest = File.join("tmp", "cache_extract")
    cache_dir = File.expand_path(File.join("tmp", "cache_extract_dir"))
    FileUtils.rm_rf(cache_dir)
    _stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest, "--force")
    assert status.success?, stderr

    out, run_status = Open3.capture2e(dest, "--cache-dir", cache_dir, "--")
    assert run_status.success?, out
    assert_includes out, "Etc loaded: true"

    hash_dir = Dir.children(cache_dir).find { |d| File.directory?(File.join(cache_dir, d)) && d.match?(/\A[0-9a-f]{64}\z/) }
    refute_nil hash_dir, "expected a content-addressed hash dir under #{cache_dir}"
    assert File.exist?(File.join(cache_dir, hash_dir, "READY"))
  end

  def test_packed_binary_warm_cache_does_not_reextract
    dest = File.join("tmp", "warm_cache")
    cache_dir = File.expand_path(File.join("tmp", "warm_cache_dir"))
    FileUtils.rm_rf(cache_dir)
    _stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest, "--force")
    assert status.success?, stderr

    out, run_status = Open3.capture2e(dest, "--cache-dir", cache_dir, "--")
    assert run_status.success?, out

    hash_dir = Dir.children(cache_dir).grep(/\A[0-9a-f]{64}\z/).first
    ready = File.join(cache_dir, hash_dir, "READY")
    first_mtime = File.mtime(ready)

    sleep 1.1 # mtime resolution
    out, run_status = Open3.capture2e(dest, "--cache-dir", cache_dir, "--")
    assert run_status.success?, out
    assert_equal first_mtime, File.mtime(ready), "warm cache should not rewrite READY"
  end

  def test_packed_binary_recovers_from_corrupted_cache
    dest = File.join("tmp", "corrupt_cache")
    cache_dir = File.expand_path(File.join("tmp", "corrupt_cache_dir"))
    FileUtils.rm_rf(cache_dir)
    _stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest, "--force")
    assert status.success?, stderr

    out, run_status = Open3.capture2e(dest, "--cache-dir", cache_dir, "--")
    assert run_status.success?, out

    hash_dir = File.join(cache_dir, Dir.children(cache_dir).grep(/\A[0-9a-f]{64}\z/).first)
    File.delete(File.join(hash_dir, "READY"))

    out, run_status = Open3.capture2e(dest, "--cache-dir", cache_dir, "--")
    assert run_status.success?, out
    assert File.exist?(File.join(hash_dir, "READY")), "READY should be re-created"
  end

  def test_concurrent_first_run_extracts_exactly_once
    skip "requires fork" unless Process.respond_to?(:fork)

    dest = File.join("tmp", "concurrent_cache")
    cache_dir = File.expand_path(File.join("tmp", "concurrent_cache_dir"))
    FileUtils.rm_rf(cache_dir)
    _stdout, stderr, status = run_cli("pack", fixture_path("require_etc_so.rb"), dest, "--force")
    assert status.success?, stderr

    pids = Array.new(4) do
      Process.spawn(dest, "--cache-dir", cache_dir, "--", out: File::NULL, err: File::NULL)
    end
    pids.each { |p| Process.wait(p) }

    hash_dirs = Dir.children(cache_dir).grep(/\A[0-9a-f]{64}\z/)
    assert_equal 1, hash_dirs.size, "expected exactly one hash dir, got #{hash_dirs.inspect}"
    refute Dir.children(cache_dir).any? { |c| c.end_with?(".tmp") }, "no .tmp leftovers expected"
  end

  def test_packed_binary_argv_unchanged_without_separator
    dest = File.join("tmp", "argv_unchanged")
    _stdout, stderr, status = run_cli("pack", fixture_path("print_argv.rb"), dest, "--force")
    assert status.success?, stderr

    # Without `--`, --cache-dir DIR is forwarded verbatim to the script's ARGV.
    out, run_status = Open3.capture2e(dest, "--cache-dir", "/tmp/some/dir")
    assert run_status.success?, out
    assert_includes out, '["--cache-dir", "/tmp/some/dir"]'
  end

  def test_packed_binary_with_separator_strips_cache_flag_from_argv
    dest = File.join("tmp", "argv_strip_cache")
    cache_dir = File.expand_path(File.join("tmp", "argv_strip_cache_dir"))
    FileUtils.rm_rf(cache_dir)
    _stdout, stderr, status = run_cli("pack", fixture_path("print_argv.rb"), dest, "--force")
    assert status.success?, stderr

    out, run_status = Open3.capture2e(dest, "--cache-dir", cache_dir, "--", "one", "two")
    assert run_status.success?, out
    assert_includes out, '["one", "two"]'
  end

  def test_gem_pack_applies_gemspec_metadata_requires
    with_fixture_gem_spec("uprb.requires" => "json,openssl") do
      dest_dir = File.expand_path("tmp/with_metadata_meta")
      FileUtils.rm_rf(dest_dir)

      stdout, stderr = run_cli_in_process(
        "gem", "pack", "with-metadata", "--force", "--path", dest_dir
      )
      assert_includes stderr, "uprb: applying gemspec metadata uprb.requires"
      assert_includes stdout, dest_dir

      packed = File.join(dest_dir, "with-metadata")
      assert File.executable?(packed), "expected packed binary to be executable"

      out, run_status = Open3.capture2e(packed)
      assert run_status.success?, out
      assert_includes out, "json: loaded"
      assert_includes out, "openssl: loaded"
      assert_includes out, "etc: missing"
    end
  end

  def test_gem_pack_merges_gemspec_metadata_with_cli_requires
    with_fixture_gem_spec("uprb.requires" => "json,openssl") do
      dest_dir = File.expand_path("tmp/with_metadata_merge")
      FileUtils.rm_rf(dest_dir)

      stdout, _stderr = run_cli_in_process(
        "gem", "pack", "with-metadata", "--force", "--path", dest_dir, "-r", "etc"
      )
      assert_includes stdout, dest_dir

      packed = File.join(dest_dir, "with-metadata")
      out, run_status = Open3.capture2e(packed)
      assert run_status.success?, out
      assert_includes out, "json: loaded"
      assert_includes out, "openssl: loaded"
      assert_includes out, "etc: loaded"
    end
  end

  private

  def run_cli(*args)
    Open3.capture3(
      RbConfig.ruby,
      File.expand_path("../exe/uprb", __dir__),
      *args,
    )
  end

  def run_cli_in_process(*args)
    orig_stdout = $stdout
    orig_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    Uprb::CLI.new(args).run
    [$stdout.string, $stderr.string]
  ensure
    $stdout = orig_stdout
    $stderr = orig_stderr
  end

  def with_fixture_gem_spec(metadata)
    fixture_full_gem_path = fixture_path("gems/with-metadata-gem/gems/with-metadata-0.1.0")
    spec = Gem::Specification.new do |s|
      s.name = "with-metadata"
      s.version = "0.1.0"
      s.summary = "uprb test fixture"
      s.authors = ["uprb test"]
      s.bindir = "exe"
      s.executables = ["with-metadata"]
      s.metadata = metadata
    end
    spec.define_singleton_method(:full_gem_path) { fixture_full_gem_path }
    Gem::Specification.add_spec(spec)
    yield
  ensure
    Gem::Specification.remove_spec(spec) if spec
  end
end
