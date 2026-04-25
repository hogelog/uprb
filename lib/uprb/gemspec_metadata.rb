# frozen_string_literal: true

module Uprb
  # Reads pack hints from `Gem::Specification#metadata`.
  #
  # Only `uprb.requires` is honored. Values are inert strings; uprb parses them
  # into existing knobs. No code from the gem runs as a result of reading
  # metadata.
  module GemspecMetadata
    KNOWN_KEYS = %w[uprb.requires].freeze
    REQUIRES_KEY = "uprb.requires"
    # `,` split, trim. Each entry must match this to be honored. Rejects
    # shell metacharacters, whitespace, and leading dashes (so the value can't
    # smuggle a `-r` style argument).
    REQUIRE_ENTRY_PATTERN = %r{\A[A-Za-z0-9_.][A-Za-z0-9_./-]*\z}

    Result = Struct.new(:requires, :warnings, keyword_init: true)

    # @param spec [Gem::Specification]
    # @return [Result]
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

      Result.new(requires: requires, warnings: warnings)
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
