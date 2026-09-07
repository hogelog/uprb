# CLAUDE.md

Guidance for working on `uprb`. User-facing documentation lives in `README.md`.

## Commands

- `bin/setup` — install dependencies.
- `bundle exec rake` — run the full test suite.
- `bundle exec ruby -Itest test/test_uprb_cli.rb -n test_pack_builds_executable` — run one test.
- `bundle exec exe/uprb pack path/to/script.rb path/to/out` — run the CLI from the working tree.

Ruby 3.3+ is supported; CI runs Ruby 3.3, 3.4, 4.0, and head.

## Design

`uprb` packs a Ruby script by freezing the `require` paths observed at pack time. Unknown runtime requires defer to Ruby normally; a changed environment or a newly reached dynamic require requires repacking. Static tracing is the default; `--dynamic` executes the entry to capture runtime-only requires.

`require_replacer.rb` builds the payload and selects runtime templates. `require_hook.rb` serves embedded ISeqs and relative requires. Native-bearing outputs also embed `native_section.rb` (length-prefixed binary records) and `native_cache.rb` (environment-based cache selection, validation, locked extraction, and native requires). Native cache keys are SHA-256 over the native section alone. Warm caches use metadata signatures; changed files are compared with the payload without loading a host digest extension.

## Generated-output invariants

Changes to the packer must preserve all of these:

- By default, a source shebang becomes an absolute `RbConfig.ruby` shebang with `--disable-gems`. `--skip-ruby-path-replace` and `--skip-disable-gems` are the respective opt-outs.
- A source without a shebang produces a non-executable output without one; run it with `ruby packed_file`.
- Do not add `$LOAD_PATH`/`RUBYLIB`/Bundler dependencies or `-I` flags at runtime.
- Embed `.rb` dependencies as ISeq payloads. Bundle native extensions and their companions; load them from the content-addressed cache, never from pack-time native load targets. Source filenames/require aliases may retain original paths, but native manifest values are always cache-relative.
- Runtime cache configuration uses `RUBY_UPRB_CACHE_DIR`; never consume or rewrite `ARGV`, including `--cache-dir` or `--`.
- Outputs with no native files omit the native payload, loader, and cache-related requires entirely.
- Preserve the source's magic comments and line numbers by compiling it independently of the bootstrap.

Bundling Ruby itself, arbitrary gem resources, system-library dependency discovery, cross-machine portability, and in-memory `dlopen` are non-goals.

## Testing

`test/test_uprb_cli.rb` shells out to `exe/uprb` and writes gitignored artifacts under `tmp/`. It relies on the Bundler environment inherited from `bundle exec rake`. The directories under `examples/` are sample gems, not part of the suite.

Native tests use temporary caches, strip Bundler/RUBYOPT from runtime subprocesses, and test removal of the original files. The companion-library test builds a small C extension with the local compiler and `make`. Cache tests cover corruption, concurrent extraction, write failures, and Linux mount detection (simulated on other platforms).
