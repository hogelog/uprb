# frozen_string_literal: true

require "rbconfig"

module Uprb
  class Error < StandardError; end

  DL_SUFFIXES = [".#{RbConfig::CONFIG['DLEXT']}", ".so", ".o"].uniq.freeze
  SUFFIXES = ([".rb"] + DL_SUFFIXES).freeze
end

require_relative "uprb/version"
require_relative "uprb/require_tracker"
require_relative "uprb/static_require_tracker"
require_relative "uprb/require_replacer"
require_relative "uprb/gemspec_metadata"
