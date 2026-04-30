# PLAN: Bundle native extensions into the packed output

## Goal

Make `uprb pack` produce a truly single-file executable that bundles every C extension (`.so` and its companion files) into the embedded payload. On first run, the executable extracts the native bits into a content-addressed cache directory and `dlopen`s them from there. The output stops referencing pack-time absolute `.so` paths on the host filesystem.

## Non-goals

- In-memory `dlopen` (Linux `memfd_create` + `/proc/self/fd/N`). Linux-only, runs into `noexec` / `MFD_NOEXEC_SEAL` and bootstrap issues. Not pursued — even as a fast path.
- Preserving the existing `REQUIRE_MAP` "external absolute path" mode. There are essentially no users yet; the old mode is removed outright. No `--external-ext` opt-out.
- Bundling Ruby itself or aiming for cross-machine portability. Pack-time Ruby/glibc ABI lock is unchanged.
- Configuration knobs beyond `--cache-dir`.

## Hard constraints

These existing invariants must keep holding for the generated executable:

- Absolute `RbConfig.ruby` shebang by default; `--skip-ruby-path-replace` opt-out only.
- `--disable-gems` in shebang by default; `--skip-disable-gems` opt-out only.
- No `-I`, no `$LOAD_PATH` mutation, no `RUBYLIB`, no Bundler.
- `.rb` dependencies remain ISeq-embedded inside the Marshal payload.

Replacing the old "non-`.rb` requires resolved via absolute pack-time path" constraint:

- Native extensions and their companion files are bundled into the payload and only loaded from the content-addressed cache directory. The output contains no pack-time host paths for non-`.rb` requires.

## Design

- The Marshal payload grows a `native` section alongside the existing ISeq map. Format: a hand-rolled length-prefixed concatenation of `{logical_name, relative_path, mode, bytes}` records. Stdlib-only round-trip — no `tar`/`zip`/non-stdlib deps at runtime under `--disable-gems`.
- Cache key: SHA-256 over the `native` section bytes only. Re-compiling `.rb` ISeqs (e.g. across Ruby patch versions) does not invalidate the native cache.
- Cache directory resolution order:
  1. `--cache-dir DIR` (runtime flag on the packed output)
  2. `$XDG_CACHE_HOME/uprb/` if set, else `~/.cache/uprb/`
  3. `Dir.tmpdir/uprb-#{Process.uid}/`
- Per-hash subdirectory `<cache>/<hash>/`, permissions `0700`. A `READY` sentinel file marks a complete extraction.
- Concurrency: `flock(LOCK_EX)` on `<cache>/<hash>.lock`; extract into `<cache>/<hash>.tmp/`, write `READY`, atomically `rename` to `<cache>/<hash>/`.
- `require_replacer` collapses the embedded/external split: every entry is either an ISeq blob (`.rb`) or a logical-name → cache-relative-path lookup (`.so` and companions). The runtime path is uniform; no fallback to host absolute paths.
- `noexec` cache directory is detected at extract time and surfaced as a clear error pointing at `--cache-dir`.

## Acceptance criteria

- Pack-time: `.so` plus detected companion files (sibling files inside the same `ext/<name>/` or `lib/<name>/` directory referenced by relative path from the `.so`) are written into the payload's `native` section. `strings` on the output shows no `/usr/lib`, no `~/.gem`, no host-specific absolute paths beyond the shebang.
- Pack-time: a required path that is neither `.rb` nor a recognized native-extension shape is a hard error; the previous "fall back to absolute path" behavior is gone.
- Cold cache: empty cache directory triggers extraction; warm cache does only stat + open.
- Concurrent first-run race: launching ≥4 packed processes against an empty cache results in exactly one extraction; the rest wait on `flock` and reuse the result. Test covers this.
- Hash stability: identical pack input produces identical native-section hash across re-packs.
- `noexec` cache directory: single-line error pointing at `--cache-dir`. No silent misleading fallback.
- Cache write-failure: when no candidate cache directory is writable, the loader prints the candidates tried and the first errno seen.
- Corruption: cache contents that fail the hash check are removed and re-extracted.
- Runtime flag: `packed_script --cache-dir DIR -- <user args>` extracts under `DIR/<hash>/` and forwards everything after `--` as `ARGV`. Without `--cache-dir`, behavior is unchanged. Without `--`, the loader leaves `ARGV` alone — the flag is recognized only when it is the first argument and is followed by `--`.
- Tests: previous assertions about host-absolute paths in packed output / the `external` map shape are removed. Real native-extension fixture (e.g. `aws-sdk-core` already in dev deps) drives the new path. `bundle exec rake` is green on Ruby 3.1+ and CI Ruby 3.4.7.
- `README.md`: "single executable" framing made honest (one file; native ext extracted to a cache directory on first run); cache directory order and `--cache-dir` runtime flag documented; pack-time ABI lock still called out. Concise — no tutorial sections.
- `CLAUDE.md`: "C extensions ... referenced by their original absolute path via `REQUIRE_MAP`" hard constraint replaced with the bundled-and-extracted constraint. "Vendoring C extensions" dropped from Non-goals (the broader "bundling Ruby itself" / "cross-machine portability" non-goal stays). `require_replacer.rb` architecture description updated to match the unified flow.
- This PLAN file is removed in the same PR that lands the change.

## Implementation notes

- Bootstrap loader runs under `--disable-gems`. Stdlib only: `fileutils`, `digest`, `tmpdir`. No rubygems, no Bundler.
- `--cache-dir` parsing is hand-rolled: only the exact form `ARGV[0] == "--cache-dir" && ARGV[2] == "--"` is recognized. `optparse` is not pulled into the bootstrap.
- `noexec` probe runs only on the extract path (cold cache). The warm-cache path stays free of the probe cost.
- `flock` on a sibling lockfile (`<cache>/<hash>.lock`), not on the directory itself.
- Keep the `FixedRequire` prelude small — it ships in every packed output.

## Out of plan / future notes

Documented so they are not re-evaluated from scratch later:

- Linux fast path using `memfd_create` + `dlopen("/proc/self/fd/N")` to skip extraction on supported kernels. Not implemented; the disk-extract path is sufficient.
- Cache GC (`uprb cache prune` etc.). Out of scope; users can `rm -rf` the cache directory safely. Revisit only if real usage shows cache bloat.
