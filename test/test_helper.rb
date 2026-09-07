# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "uprb"

require "minitest/autorun"

require "tempfile"
require "tmpdir"

# Packed subprocesses must not write to the developer's normal cache.
test_cache = Dir.mktmpdir("uprb-test-cache-")
original_cache = ENV["RUBY_UPRB_CACHE_DIR"]
ENV["RUBY_UPRB_CACHE_DIR"] = test_cache
Minitest.after_run do
  ENV["RUBY_UPRB_CACHE_DIR"] = original_cache
  FileUtils.remove_entry(test_cache)
end

def fixture_path(name)
  File.expand_path("fixtures/#{name}", __dir__)
end

def packed_environment
  { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLER_SETUP" => nil, "BUNDLE_GEMFILE" => nil,
    "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR) }
end

def with_tempfile(data)
  Tempfile.create do |f|
    f.binmode
    f.write(data)
    f.rewind
    yield(f)
  end
end
