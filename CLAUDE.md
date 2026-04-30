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
- `lib/uprb/static_require_tracker.rb` — the **default** tracer. Two passes: (1) parse the entry with Prism and actually `require` each literal require/autoload target — libraries load normally but the entry's other top-level code (e.g. `App.start(ARGV)`) does not run, and everything pulled in transitively is recorded via `RequireTracker`; (2) `StaticWalker` recursively parses every reachable `.rb` file to pick up literal requires and autoload paths that the runtime never hit (rescued `LoadError` alternates, unused autoloads, feature-flag branches). The merged map uses dynamic results on conflict since those reflect the actually-resolved path. Interpolated-string requires triggered only by runtime execution (e.g. `require "foo/#{name}"` inside a method called by the entry) are still missed — those need `--dynamic`.
- `lib/uprb/require_replacer.rb` — `pack` builds the mapping via `build_mapping` (default: `StaticRequireTracker.trace`; `--dynamic`: `execute_with_tracker` + `StaticWalker` as a second pass so the runtime-only captures are augmented with literal/autoload paths not exercised by the execution). Then compiles the main script and every `.rb` entry into `RubyVM::InstructionSequence` binaries, encodes the bundled native extensions into a hand-rolled length-prefixed `native section`, and appends a `Marshal` payload after `__END__`. The bootstrap loader resolves a content-addressed cache directory (`--cache-dir DIR --` runtime flag, then `$XDG_CACHE_HOME/uprb/` or `~/.cache/uprb/`, then `Dir.tmpdir/uprb-#{uid}/`), `flock`s `<cache>/<hash>.lock`, extracts the section into `<cache>/<hash>.tmp/`, writes a `READY` sentinel, and atomically `rename`s into place. A prepended `FixedRequire` module serves embedded ISeqs; native requires resolve through a unified `REQUIRE_MAP` of cache-relative paths under the extracted hash directory. `execute_with_tracker` captures stdout/stderr to `Tempfile`, clears `ARGV`, sets `$PROGRAM_NAME`, and `Kernel#load`s the source in-process.
- `lib/uprb/native_section.rb` — encoding/decoding of the native section blob.
- `lib/uprb/cli.rb`, `exe/uprb` — CLI: `pack`, `gem install`, `gem pack`. Options: `--path DIR` (gem subcommands; default `Gem.bindir`).

The output gets a shebang only when the source does. With a source shebang, the wrapper's shebang is the absolute `RbConfig.ruby` path plus `--disable-gems` by default. Two orthogonal opt-outs:

- `--skip-disable-gems` drops the `--disable-gems` flag so the output starts Ruby normally (rubygems / `RUBYOPT` / Bundler Gemfile autodetection all active) — intended for vendoring-only use cases that accept normal startup cost.
- `--skip-ruby-path-replace` keeps the source file's shebang ruby invocation verbatim (e.g. `/usr/bin/env ruby`) instead of rewriting it to `RbConfig.ruby` — intended for vendoring that wants a portable Ruby reference in the output.

The two flags can be combined (e.g. `#!/usr/bin/env ruby` with no `--disable-gems`). When the source has no shebang, the packed output also has none and is not chmod'd executable — invoke via `ruby packed_file`. This is uniform across all flag combinations.

## Hard constraints on the generated executable

Any change to the output generator must preserve these — violating any is a bug:

- Absolute `RbConfig.ruby` path in the shebang by default; never `/usr/bin/env ruby`, never a PATH lookup. `--skip-ruby-path-replace` is the one documented opt-out, for vendoring-only outputs that preserve the source's shebang ruby invocation
- `--disable-gems` in the shebang by default; rubygems is not available at runtime. `--skip-disable-gems` is the one documented opt-out, for vendoring-only outputs that accept normal Ruby startup cost
- No `-I`, no `$LOAD_PATH` modification, no `RUBYLIB`, no Bundler
- `.rb` dependencies are always embedded as ISeq binaries inside the `Marshal` payload; native extensions and their companion files are always bundled into the payload's `native` section and only loaded from the content-addressed cache directory after first-run extraction. The output contains no pack-time host paths for non-`.rb` requires.

## Non-goals

Declining these is a design choice, not a todo:

- Bundling Ruby itself; cross-machine portability
- Surviving Ruby/gem upgrades, graceful degradation
- Plugin systems or dynamic resolution beyond the frozen mapping
- In-memory `dlopen` of bundled native extensions (Linux `memfd_create` + `/proc/self/fd/N`). Disk extraction into the content-addressed cache is the only supported path.

(Compiled `.rb` sources and bundled native extensions are both embedded in the output. The Ruby interpreter is still referenced by absolute path in the shebang, and the output stays ABI-locked to the pack-time Ruby/glibc, so it remains tied to the family of machines compatible with the pack-time host.)

The output is expected to break when the Ruby ABI changes, gems are up/downgraded, or new code paths hit unseen `require`s. The only remediation is `uprb pack <src> <dest>`.

## Testing notes

`test/test_uprb_cli.rb` shells out to `exe/uprb` via `Open3` and writes artifacts under `./tmp/` (gitignored). `aws-sdk-core` is a dev dependency so the suite can verify that a library pulling in rubygems vendored stdlib packs and runs end-to-end. The suite runs under `bundle exec rake`, so subprocesses inherit the bundler-configured environment that resolves those gems — tests don't scrub it. `examples/rls` and `examples/s3-ls` are sample gems, not part of the suite. `examples/s3-ls` depends on `aws-sdk-s3` and is kept as a reference — with a bare `uprb gem pack` it won't run under `--disable-gems`, but `uprb gem pack s3-ls --with-rubygems --dynamic` runs it up to the AWS credential/region resolution path (see `examples/s3-ls/README.md`).
