# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. User-facing docs live in `README.md`.

## Commands

- `bin/setup` — `bundle install`.
- `bundle exec rake` — run the full test suite.
- `bundle exec ruby -Itest test/test_uprb_cli.rb -n test_pack_builds_executable` — run a single test by name.
- `bundle exec exe/uprb pack path/to/script.rb path/to/out` — run the CLI from the working tree.

Ruby 3.1+ (`uprb.gemspec`). CI: 3.4.7.

## What uprb does

Packs a Ruby script into a deterministic, fast-starting executable by **freezing every observed `require` at pack time**. At runtime, the frozen mapping is preferred; anything else falls through to Ruby's normal `require`. If the environment changes, the executable is expected to break — the only remediation is repack.

## Architecture

- `lib/uprb/require_tracker.rb` — aliases `Kernel#require` / `Kernel#require_relative` and records `name => $LOADED_FEATURES` path on every successful call.
- `lib/uprb/require_replacer.rb` — `Kernel#load`s the source in-process (stdout/stderr captured to `Tempfile`, `ARGV` cleared, `$PROGRAM_NAME` set), then emits the output in one of two modes:
  - default (`pack_iseq`): compiles the main script and every required `.rb` into `RubyVM::InstructionSequence` binaries, appends a `Marshal` payload after `__END__`. A prepended `FixedRequire` module serves embedded ISeqs; non-`.rb` requires use a fallback `REQUIRE_MAP`; unknown names defer to `super`.
  - `--skip-iseq-cache` (`pack`): plain Ruby output with `FixedRequire` + hard-coded `REQUIRE_MAP` prepended to the original source.
- `lib/uprb/cli.rb`, `exe/uprb` — CLI: `pack`, `gem install`, `gem pack`. Options: `--skip-iseq-cache`, `--enable-rubygems`, `--path DIR` (gem subcommands; default `Gem.bindir`).

The output's shebang is the absolute `RbConfig.ruby` path plus `--disable-gems` unless `--enable-rubygems`.

## Hard constraints on the generated executable

Any change to the output generator must preserve these — violating any is a bug:

- Absolute `RbConfig.ruby` path in the shebang; never `/usr/bin/env ruby`, never a PATH lookup
- `--disable-gems` unless `--enable-rubygems` was requested
- No `-I`, no `$LOAD_PATH` modification, no `RUBYLIB`, no Bundler
- `.rb` dependencies are embedded as ISeq binaries (default) or looked up via the frozen `REQUIRE_MAP` (`--skip-iseq-cache`); C extensions and other non-`.rb` requires are always referenced by their **original absolute path** via `REQUIRE_MAP` — never copied, never relocated

## Non-goals

Declining these is a design choice, not a todo:

- Bundling Ruby itself; vendoring C extensions; cross-machine portability
- Surviving Ruby/gem upgrades, graceful degradation
- Plugin systems or dynamic resolution beyond the frozen mapping

(The default ISeq mode does embed compiled `.rb` sources into the output, so the output is *partially* self-contained for pure-Ruby deps. C extensions and the Ruby interpreter are still referenced by absolute path, so the output remains tied to the machine it was packed on.)

The output is expected to break when the Ruby path moves, C extension paths change, gems are up/downgraded, or new code paths hit unseen `require`s. The only remediation is `uprb pack <src> <dest>`.

## Testing notes

`test/test_uprb_cli.rb` shells out to `exe/uprb` via `Open3` and writes artifacts under `./tmp/` (gitignored). `test/fixtures/` is exercised end-to-end (`aws-sdk-core` is a dev dependency for that reason). `examples/rls` and `examples/s3-ls` are sample gems, not part of the suite.
