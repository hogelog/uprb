# frozen_string_literal: true

require "test_helper"
require "uprb/native_cache"
require "open3"
require "minitest/mock"

class TestUprbNativeCache < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("uprb-native-")
    @records = [
      { logical_name: "fixture", relative_path: "0/fixture.so", mode: 0o755, bytes: "native\x00bytes".b },
      { logical_name: "data", relative_path: "0/data/value", mode: 0o644, bytes: "companion" },
    ]
    section = UprbRuntime::NativeSection.encode(@records)
    @native = { section: section, hash: Digest::SHA256.hexdigest(section), manifest: { "fixture" => "0/fixture.so" } }
    @cache = UprbRuntime::NativeCache.new(@native)
    @hash_dir = File.join(@directory, @native[:hash])
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_section_round_trip_and_validation
    index = UprbRuntime::NativeSection.index(@native[:section])
    @records.each do |record|
      mode, offset, length = index.fetch(record[:relative_path])
      assert_equal record[:mode], mode
      assert_equal record[:bytes], @native[:section].byteslice(offset, length)
    end
    [@native[:section][0...-1], @native[:section] + "extra", [2, 0].pack("NN")].each do |invalid|
      assert_raises(ArgumentError) { UprbRuntime::NativeSection.index(invalid) }
    end
    ["../outside", "/absolute", "a/../../b", "a//b", "a\\b", "a\x00b"].each do |path|
      blob = UprbRuntime::NativeSection.encode([@records.first.merge(relative_path: path)])
      assert_raises(ArgumentError) { UprbRuntime::NativeSection.index(blob) }
    end
  end

  def test_extracts_binary_companions_and_permissions
    prepare
    @records.each do |record|
      path = File.join(@hash_dir, record[:relative_path])
      assert_equal record[:bytes], File.binread(path)
      assert_equal record[:mode], File.stat(path).mode & 0o777
    end
    assert_equal 0o700, File.stat(@hash_dir).mode & 0o777
    assert File.file?(File.join(@hash_dir, "READY"))
  end

  def test_warm_cache_skips_extraction_and_byte_verification
    prepare
    ready = File.stat(File.join(@hash_dir, "READY"))
    @cache.define_singleton_method(:extract) { |_| raise "unexpected extraction" }
    @cache.define_singleton_method(:intact?) { |_| raise "unexpected file read" }
    @cache.define_singleton_method(:check_noexec) { |_| raise "unexpected probe" }
    prepare
    assert_equal ready.mtime, File.mtime(File.join(@hash_dir, "READY"))
    assert_equal ready.ino, File.stat(File.join(@hash_dir, "READY")).ino
  end

  def test_repairs_same_size_corruption_with_ready_and_restored_mtime
    prepare
    target = File.join(@hash_dir, "0/fixture.so")
    time = File.mtime(target)
    File.binwrite(target, "x" * File.size(target))
    File.utime(time, time, target)
    prepare
    assert_equal @records.first[:bytes], File.binread(target)
  end

  def test_recovers_missing_files_ready_and_interrupted_extraction
    prepare
    File.delete(File.join(@hash_dir, "0/data/value"))
    File.delete(File.join(@hash_dir, "READY"))
    FileUtils.mkdir_p("#{@hash_dir}.tmp")
    File.write(File.join("#{@hash_dir}.tmp", "partial"), "unfinished")
    prepare
    assert_equal "companion", File.binread(File.join(@hash_dir, "0/data/value"))
    refute File.exist?("#{@hash_dir}.tmp")
  end

  def test_changed_metadata_with_intact_bytes_does_not_reextract
    prepare
    target = File.join(@hash_dir, "0/fixture.so")
    File.utime(Time.at(1), Time.at(1), target)
    @cache.define_singleton_method(:extract) { |_| raise "unexpected extraction" }
    prepare
    assert @cache.send(:valid?, @hash_dir)
  end

  def test_replaces_symlink_without_writing_through_it
    prepare
    outside = File.join(@directory, "outside")
    File.write(outside, "leave alone")
    target = File.join(@hash_dir, "0/fixture.so")
    File.delete(target)
    File.symlink(outside, target)
    prepare
    refute File.symlink?(target)
    assert_equal "leave alone", File.read(outside)
  end

  def test_rejects_symlink_cache_root_and_lock
    root = File.join(@directory, "linked-root")
    File.symlink(@directory, root)
    assert_raises(UprbRuntime::NativeCache::Error) { @cache.send(:prepare, root) }
    outside = File.join(@directory, "outside")
    File.write(outside, "leave alone")
    File.symlink(outside, File.join(@directory, "#{@native[:hash]}.lock"))
    assert_raises(Errno::ELOOP) { prepare }
    assert_equal "leave alone", File.read(outside)
  end

  def test_replaces_symlink_directory_even_when_file_metadata_is_unchanged
    prepare
    outside = File.join(@directory, "outside")
    nested = File.join(@hash_dir, "0/data")
    FileUtils.mv(nested, outside)
    File.symlink(outside, nested)
    prepare
    refute File.symlink?(nested)
    assert_equal "companion", File.read(File.join(nested, "value"))
    assert_equal "companion", File.read(File.join(outside, "value"))
  end

  def test_falls_back_after_failure_to_write_inside_an_existing_root
    fallback = File.join(@directory, "fallback")
    roots = [@directory, fallback]
    @cache.define_singleton_method(:candidates) { |_| roots }
    # mkdir_p(root) succeeds, but opening the lock fails.
    FileUtils.mkdir_p(File.join(@directory, "#{@native[:hash]}.lock"))
    assert_equal File.join(fallback, @native[:hash], "0/fixture.so"), @cache.resolve.fetch("fixture")
  end

  def test_reports_candidates_and_errno_when_all_fail
    roots = [File.join(@directory, "first"), File.join(@directory, "second")]
    roots.each { |root| File.write(root, "not a directory") }
    @cache.define_singleton_method(:candidates) { |_| roots }
    error = assert_raises(UprbRuntime::NativeCache::Error) { @cache.resolve }
    roots.each { |root| assert_includes error.message, root }
    assert_match(/Errno::E(EXIST|NOTDIR)/, error.message)
    assert_includes error.message, "RUBY_UPRB_CACHE_DIR"
  end

  def test_environment_candidates_and_empty_override
    with_environment("RUBY_UPRB_CACHE_DIR" => "", "XDG_CACHE_HOME" => @directory) do
      assert_equal File.join(@directory, "uprb"), @cache.send(:candidates, []).first
    end
    with_environment("RUBY_UPRB_CACHE_DIR" => @directory, "XDG_CACHE_HOME" => "unused") do
      assert_equal @directory, @cache.send(:candidates, []).first
      assert_equal File.join(@hash_dir, "0/fixture.so"), @cache.resolve.fetch("fixture")
    end
    with_environment("RUBY_UPRB_CACHE_DIR" => nil, "XDG_CACHE_HOME" => nil, "HOME" => @directory) do
      assert_equal File.join(@directory, ".cache/uprb"), @cache.send(:candidates, []).first
    end
  end

  def test_noexec_error_mentions_environment_variable
    roots = [@directory]
    @cache.define_singleton_method(:candidates) { |_| roots }
    File.stub(:file?, true) do
      File.stub(:readlines, ["device / filesystem rw,noexec 0 0\n"]) do
        error = assert_raises(UprbRuntime::NativeCache::NoexecError) { @cache.resolve }
        assert_includes error.message, "noexec"
        assert_includes error.message, "RUBY_UPRB_CACHE_DIR"
        refute File.exist?(@hash_dir)
      end
    end
  end

  def test_noexec_probe_resolves_symlinks_and_escaped_mount_names
    path = File.join(@directory, "space here")
    FileUtils.mkdir_p(path)
    alias_path = File.join(@directory, "alias")
    File.symlink(path, alias_path)
    actual = File.realpath(path).gsub(" ") { '\\040' }
    mounts = ["device / filesystem rw 0 0\n", "device #{actual} filesystem rw,noexec 0 0\n"]
    File.stub(:file?, true) do
      File.stub(:readlines, mounts) do
        assert_raises(UprbRuntime::NativeCache::NoexecError) { @cache.send(:check_noexec, alias_path) }
      end
    end
  end

  def test_four_concurrent_processes_extract_once
    input = File.join(@directory, "input")
    log = File.join(@directory, "extractions")
    File.binwrite(input, Marshal.dump(@native))
    code = <<~'RUBY'
      class UprbRuntime::NativeCache
        alias original_extract extract
        def extract(directory)
          File.open(ENV.fetch("UPRB_TEST_EXTRACTIONS"), "a") { |file| file.puts(Process.pid) }
          original_extract(directory)
        end
      end
      UprbRuntime::NativeCache.new(Marshal.load(File.binread(ARGV.fetch(0)))).resolve
    RUBY
    env = { "RUBYOPT" => nil, "RUBY_UPRB_CACHE_DIR" => @directory, "UPRB_TEST_EXTRACTIONS" => log }
    children = Array.new(4) do
      Open3.popen2e(env, RbConfig.ruby, "--disable-gems",
        "-r", File.expand_path("../lib/uprb/native_section", __dir__),
        "-r", File.expand_path("../lib/uprb/native_cache", __dir__), "-e", code, input)
    end
    children.each do |stdin, output, waiter|
      stdin.close
      text = output.read
      output.close
      assert waiter.value.success?, text
    end
    assert_equal 1, File.readlines(log).size
    assert @cache.send(:valid?, @hash_dir)
    refute File.exist?("#{@hash_dir}.tmp")
  end

  private

  def prepare
    @cache.send(:prepare, @directory)
  end

  def with_environment(values)
    previous = ENV.to_h.slice(*values.keys)
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    values.each_key { |key| ENV[key] = previous[key] }
  end
end
