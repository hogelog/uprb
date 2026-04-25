# frozen_string_literal: true

module Uprb
  module GemspecMetadata
    KNOWN_KEYS = %w[uprb.requires].freeze
    REQUIRES_KEY = "uprb.requires"
    REQUIRE_ENTRY_PATTERN = %r{\A[A-Za-z0-9_.][A-Za-z0-9_./-]*\z}

    Result = Struct.new(:requires, :warnings, keyword_init: true)

    def self.read(spec)
      metadata = spec.metadata || {}
      warnings = []
      requires = []

      metadata.each do |key, value|
        next unless key.start_with?("uprb.")

        unless KNOWN_KEYS.include?(key)
          warnings << "uprb: ignoring unknown gemspec metadata key #{key.inspect}"
          next
        end

        if key == REQUIRES_KEY
          parsed, entry_warnings = parse_requires(value)
          requires.concat(parsed)
          warnings.concat(entry_warnings)
        end
      end

      Result.new(requires:, warnings:)
    end

    def self.parse_requires(value)
      warnings = []
      entries = value.to_s.split(",").map(&:strip).reject(&:empty?)
      kept = entries.select do |entry|
        if REQUIRE_ENTRY_PATTERN.match?(entry)
          true
        else
          warnings << "uprb: ignoring gemspec metadata #{REQUIRES_KEY} entry #{entry.inspect}"
          false
        end
      end
      [kept, warnings]
    end
  end
end
