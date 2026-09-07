# frozen_string_literal: true

require "test_helper"
require "open3"

class TestUprbNativePack < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("uprb-pack-")
    @source_dir = File.join(@directory, "source")
    @cache_dir = File.join(@directory, "cache")
    @output = File.join(@directory, "packed")
    FileUtils.mkdir_p(@source_dir)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_native_and_ruby_dependencies_work_without_original_files_or_gems
    copy_native
    File.write(File.join(@source_dir, "library.rb"), <<~RUBY)
      require_relative "etc/etc.#{RbConfig::CONFIG['DLEXT']}"
    RUBY
    pack(<<~'RUBY')
      require_relative "library"
      puts Etc.respond_to?(:getpwuid)
      puts $LOADED_FEATURES.grep(%r{/etc\.(so|bundle)\z})
      p ARGV
    RUBY
    native = payload.fetch(:native)
    assert_equal Digest::SHA256.hexdigest(native[:section]), native[:hash]
    native[:manifest].each_value { |path| refute File.absolute_path?(path) }
    refute native[:section].include?(@source_dir)
    FileUtils.remove_entry(@source_dir)

    arguments = ["--cache-dir", "program-option", "--", "--help", "", "日本語"]
    out, status = run_packed(*arguments)
    assert status.success?, out
    assert_equal "true", out.lines.first.chomp
    assert_includes out, File.join(@cache_dir, native[:hash], "0/etc.#{RbConfig::CONFIG['DLEXT']}")
    assert_equal arguments.inspect, out.lines.last.chomp
    refute_includes out, @source_dir
    assert_equal "companion data", File.read(File.join(@cache_dir, native[:hash], "0/assets/value"))
  end

  def test_native_aliases_load_only_once
    copy_native
    pack(<<~RUBY)
      p [require_relative("etc/etc"), require_relative("etc/etc.#{RbConfig::CONFIG['DLEXT']}")]
    RUBY
    out, status = run_packed
    assert status.success?, out
    assert_equal "[true, false]\n", out
    paths = payload.fetch(:native).fetch(:manifest).values.uniq
    assert_equal 1, paths.length
  end

  def test_pure_ruby_output_omits_native_bootstrap_and_preserves_arguments
    File.write(File.join(@source_dir, "library.rb"), "VALUE = 42\n")
    pack(<<~'RUBY')
      # frozen_string_literal: true
      module Local
        def self.require(*) = raise("must not intercept require_relative")
        require_relative "library"
      end
      p [VALUE, "literal".frozen?, __LINE__, ARGV]
    RUBY
    refute payload.key?(:native)
    wrapper = File.binread(@output).split("__END__\n", 2).first
    %w[NativeCache NativeSection NATIVE_MAP RUBY_UPRB_CACHE_DIR flock fileutils tmpdir digest].each do |term|
      refute_includes wrapper, term
    end
    arguments = ["--cache-dir", "a", "--", "b"]
    original, status = Open3.capture2e(clean_environment, RbConfig.ruby, "--disable-gems", File.join(@source_dir, "entry.rb"), *arguments)
    assert status.success?, original
    FileUtils.remove_entry(@source_dir)
    File.write(@cache_dir, "not a directory")
    out, status = run_packed(*arguments)
    assert status.success?, out
    assert_equal original, out
    assert_equal "not a directory", File.read(@cache_dir)
  end

  def test_native_hash_is_stable_after_repack_and_relocation
    copy_native
    pack('require_relative "etc/etc"')
    first = payload.fetch(:native).fetch(:hash)
    pack('require_relative "etc/etc"' + "\nputs :changed_ruby_code\n")
    assert_equal first, payload.fetch(:native).fetch(:hash)
    moved = File.join(@directory, "moved")
    FileUtils.mv(@source_dir, moved)
    @source_dir = moved
    pack('require_relative "etc/etc"')
    assert_equal first, payload.fetch(:native).fetch(:hash)
  end

  def test_rejects_unknown_missing_and_non_builtin_require_paths
    unknown = File.join(@directory, "data.txt")
    File.write(unknown, "not Ruby or native code")
    [unknown, File.join(@directory, "missing.so"), "not_a_builtin.so", nil].each do |path|
      assert_raises(Uprb::Error) do
        Uprb::RequireReplacer.send(:build_payload, { "unknown" => path })
      end
    end
    data = Uprb::RequireReplacer.send(:build_payload, { "enumerator" => "enumerator.so" })
    refute data.key?(:native)
  end

  def test_aws_sdk_runs_under_disable_gems_without_bundler_preload
    entry = File.read(fixture_path("aws-sdk-core.rb")).lines.drop(1).join
    pack(entry)
    out, status = run_packed
    assert status.success?, out
    assert_includes out, "Aws"
  end

  def test_native_extension_loads_its_sibling_shared_library_after_relocation
    build = File.join(@directory, "build")
    FileUtils.mkdir_p(build)
    Dir.children(fixture_path("native")).each do |name|
      FileUtils.cp(fixture_path("native/#{name}"), build)
    end
    out, status = Open3.capture2e(RbConfig.ruby, "extconf.rb", chdir: build)
    assert status.success?, out
    out, status = Open3.capture2e("make", chdir: build)
    assert status.success?, out

    directory = File.join(@source_dir, "uprb_fixture")
    FileUtils.mkdir_p(directory)
    FileUtils.cp(File.join(build, "uprb_fixture.#{RbConfig::CONFIG['DLEXT']}"), directory)
    companion = RUBY_PLATFORM.include?("darwin") ? "libuprb_companion.dylib" : "libuprb_companion.so"
    FileUtils.cp(File.join(build, companion), directory)
    pack(<<~'RUBY')
      require_relative "uprb_fixture/uprb_fixture"
      puts UprbFixture.value
    RUBY
    FileUtils.remove_entry(build)
    FileUtils.remove_entry(@source_dir)
    out, status = run_packed
    assert status.success?, out
    assert_equal "42\n", out
  end

  private

  def copy_native
    directory = File.join(@source_dir, "etc")
    FileUtils.mkdir_p(File.join(directory, "assets"))
    original = $LOADED_FEATURES.find { |path| File.basename(path) == "etc.#{RbConfig::CONFIG['DLEXT']}" }
    raise "etc extension not loaded in test process" unless original
    FileUtils.cp(original, directory)
    File.write(File.join(directory, "assets/value"), "companion data")
    File.write(File.join(directory, "unneeded.rb"), "raise 'must not be copied as a native companion'")
  end

  def pack(source)
    entry = File.join(@source_dir, "entry.rb")
    File.write(entry, "#!/usr/bin/env ruby\n#{source}\n")
    out, status = Open3.capture2e(RbConfig.ruby, File.expand_path("../exe/uprb", __dir__), "pack", entry, @output, "--force")
    assert status.success?, out
  end

  def payload
    Marshal.load(File.binread(@output).split("__END__\n", 2).last)
  end

  def clean_environment
    { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil,
      "GEM_HOME" => File.join(@directory, "empty-gems"), "GEM_PATH" => "",
      "RUBY_UPRB_CACHE_DIR" => @cache_dir }
  end

  def run_packed(*arguments)
    Open3.capture2e(clean_environment, @output, *arguments)
  end
end
