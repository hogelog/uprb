# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "uprb"

require "minitest/autorun"

require "tempfile"

def fixture_path(name)
  File.expand_path("fixtures/#{name}", __dir__)
end

def with_tempfile(data)
  Tempfile.create do |f|
    f.binmode
    f.write(data)
    f.rewind
    yield(f)
  end
end
