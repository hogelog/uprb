# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "uprb"

require "minitest/autorun"

def fixture_path(name)
  File.expand_path("fixtures/#{name}", __dir__)
end
