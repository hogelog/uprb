# CLAUDE.md

Guidance for working on `uprb`. User-facing documentation lives in `README.md`.

## Commands

- `bin/setup` — install dependencies.
- `bundle exec rake` — run the full test suite.
- `bundle exec ruby -Itest test/test_uprb_cli.rb -n test_pack_builds_executable` — run one test.
- `bundle exec exe/uprb pack path/to/script.rb path/to/out` — run the CLI from the working tree.

Ruby 3.1+ is supported; CI runs Ruby 3.4.7.

## Design

`uprb` packs a Ruby script by freezing the `require` paths observed at pack time. Unknown runtime requires defer to Ruby normally; a changed environment or a newly reached dynamic require requires repacking. Static tracing is the default; `--dynamic` executes the entry to capture runtime-only requires.

## Generated-output invariants

Changes to the packer must preserve all of these:

- By default, a source shebang becomes an absolute `RbConfig.ruby` shebang with `--disable-gems`. `--skip-ruby-path-replace` and `--skip-disable-gems` are the respective opt-outs.
- A source without a shebang produces a non-executable output without one; run it with `ruby packed_file`.
- Do not add `$LOAD_PATH`/`RUBYLIB`/Bundler dependencies or `-I` flags at runtime.
- Embed `.rb` dependencies as ISeq payloads. Keep C extensions and other non-Ruby requirements as their original absolute paths; never vendor or relocate them.

## Testing

`test/test_uprb_cli.rb` shells out to `exe/uprb` and writes gitignored artifacts under `tmp/`. It relies on the Bundler environment inherited from `bundle exec rake`. The directories under `examples/` are sample gems, not part of the suite.
