# frozen_string_literal: true

require "test_helper"
require "rubygems"

class TestUprbGemspecMetadata < Minitest::Test
  def build_spec(metadata)
    Gem::Specification.new do |s|
      s.name = "fixture"
      s.version = "0.0.1"
      s.summary = "test"
      s.authors = ["test"]
      s.metadata = metadata
    end
  end

  def test_parses_comma_separated_requires
    spec = build_spec("uprb.requires" => "json,openssl,etc")
    result = Uprb::GemspecMetadata.read(spec)

    assert_equal %w[json openssl etc], result.requires
    assert_empty result.warnings
  end

  def test_trims_whitespace_and_drops_empty_entries
    spec = build_spec("uprb.requires" => " json , , openssl ")
    result = Uprb::GemspecMetadata.read(spec)

    assert_equal %w[json openssl], result.requires
    assert_empty result.warnings
  end

  def test_warns_and_skips_invalid_entry
    spec = build_spec("uprb.requires" => "json,foo bar,openssl")
    result = Uprb::GemspecMetadata.read(spec)

    assert_equal %w[json openssl], result.requires
    assert_equal 1, result.warnings.length
    assert_includes result.warnings.first, "foo bar"
    assert_includes result.warnings.first, "uprb.requires"
  end

  def test_rejects_leading_dash_entry
    spec = build_spec("uprb.requires" => "-rmalicious")
    result = Uprb::GemspecMetadata.read(spec)

    assert_empty result.requires
    assert_equal 1, result.warnings.length
    assert_includes result.warnings.first, "-rmalicious"
  end

  def test_rejects_shell_metacharacter_entry
    spec = build_spec("uprb.requires" => "json;rm -rf")
    result = Uprb::GemspecMetadata.read(spec)

    assert_empty result.requires
    assert_equal 1, result.warnings.length
  end

  def test_warns_on_unknown_uprb_key
    spec = build_spec(
      "uprb.requires" => "json",
      "uprb.dynamic" => "true",
    )
    result = Uprb::GemspecMetadata.read(spec)

    assert_equal %w[json], result.requires
    assert_equal 1, result.warnings.length
    assert_includes result.warnings.first, "uprb.dynamic"
  end

  def test_ignores_non_uprb_metadata_keys
    spec = build_spec(
      "homepage_uri" => "https://example.com",
      "source_code_uri" => "https://example.com/src",
    )
    result = Uprb::GemspecMetadata.read(spec)

    assert_empty result.requires
    assert_empty result.warnings
  end

  def test_returns_empty_result_for_no_metadata
    spec = build_spec({})
    result = Uprb::GemspecMetadata.read(spec)

    assert_empty result.requires
    assert_empty result.warnings
  end
end
