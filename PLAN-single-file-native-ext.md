# PLAN: Bundle native extensions into the packed output

## Goal

Make `uprb pack` produce a **truly single-file** executable that bundles every C extension (`.so`, plus its companion files) used by the script as part of the embedded payload. On first run, the executable extracts the native bits into a content-addressed cache directory and `dlopen`s them from there. After this change, the output stops referencing pack-time absolute `.so` paths on the host filesystem.

## Non-goals

- In-memory `dlopen` (Linux `memfd_create` + `/proc/self/fd/N`). Linux-only, runs into `noexec`/`MFD_NOEXEC_SEAL` and bootstrap problems. Not pursued, even as a fast path.
- Preserving the existing `REQUIRE_MAP` "external absolute path" mode for native extensions. There are essentially no users yet; the old mode is removed outright. No `--external-ext` opt-out flag.
- Bundling Ruby itself or aiming for cross-machine portability (tebako / ruby-packer territory). Pack-time Ruby/glibc ABI lock is unchanged.
- Adding configuration knobs beyond `--cache-dir`.

## Design summary

- Output layout stays "Ruby script + `__END__` + Marshal payload". The payload format grows a `native` section alongside the existing ISeq map.
- Native section: a content-hashable archive holding every required `.so` (and adjacent companion files such as headers / data files referenced by the gem) keyed by the same logical name used in the existing `REQUIRE_MAP`.
- Runtime cache directory resolution order:
  1. `--cache-dir DIR` (CLI flag, highest precedence)
  2. `$XDG_CACHE_HOME/uprb/` if set, else `~/.cache/uprb/`
  3. `Dir.tmpdir/uprb-#{Process.uid}/`
- Cache subdirectory name is the SHA-256 of the native section bytes. Permissions `0700`.
- First run extracts to `<cache>/<hash>.tmp/`, then atomically `rename` to `<cache>/<hash>/`. Concurrent invocations coordinate via `flock` on a per-hash lockfile.
- `require_replacer` collapses the `embedded`/`external` distinction: every entry is either an ISeq blob (`.rb`) or a logical-name → extracted-path lookup (`.so` and companions). The runtime path is uniform; there is no fallback to host absolute paths.
- `noexec` cache directory: detected at extract time (probe with a tiny extracted file) and surfaced as a clear error message that points at `--cache-dir`.

## Hard constraints (carry forward)

These existing invariants must keep holding for the generated executable:

- Absolute `RbConfig.ruby` shebang by default; `--skip-ruby-path-replace` opt-out only.
- `--disable-gems` in shebang by default; `--skip-disable-gems` opt-out only.
- No `-I`, no `$LOAD_PATH` mutation, no `RUBYLIB`, no Bundler.
- `.rb` dependencies remain ISeq-embedded inside the Marshal payload.

The new constraint replacing the old "`.so` referenced by absolute pack-time path":

- Native extensions and their companion files are bundled into the payload and only loaded from the content-addressed cache directory. The output never references pack-time host paths for non-`.rb` requires.

## Milestones

Milestones are intended to be picked up one-by-one by the `plan-dev` flow. Earlier milestones must merge before later ones start; cross-milestone dependencies are noted explicitly.

### M1 — Payload format design + framing

Design the binary layout for the native section and the new top-level payload structure. Decide on the archive format (preference order: a hand-rolled length-prefixed concatenation of `{logical_name, relative_path, mode, bytes}` records, vs. `tar`, vs. `zip`) and document the choice in `lib/uprb/`. Avoid pulling in non-stdlib deps — anything we serialize must round-trip with stdlib only at runtime.

**Acceptance criteria**

- A short design note (header comment in the new payload module is fine) describing: top-level `Marshal` schema, native section format, hash algorithm (SHA-256 over the native section bytes), and how `require_replacer` reads it.
- A unit test that round-trips a fake native section (two `.so` files plus one companion file) through serialize → deserialize and checks bytes-identical output and stable hash.
- Decision recorded for the archive format. Default to the hand-rolled concatenation unless there is a concrete reason to depend on `tar`/`zip` (we read it back at runtime under `--disable-gems`, so stdlib-only is required).

**Implementation notes**

- Keep the native section streamable: extract code in M3 should not have to load the whole archive into memory.
- The hash is computed over the native section *only*, not the whole payload — re-compiling `.rb` ISeqs (e.g. across Ruby patch versions) must not invalidate the native cache.

### M2 — Pack-side: collect `.so` + companion files into the payload

In `lib/uprb/require_replacer.rb` (`build_mapping` / `build_payload`), replace the "store absolute path in `REQUIRE_MAP`" branch for non-`.rb` entries with: read the file bytes, plus any companion files in the same gem `lib`/`ext` directory that the `.so` is known to need, and add them to the native section.

**Acceptance criteria**

- For a script that requires a gem with a C extension (the existing `aws-sdk-core` test fixture or similar), `uprb pack` produces an output whose payload contains the `.so` bytes; the host's original `.so` path no longer appears anywhere in the output (verifiable by `grep`).
- Pack-time errors when a required path resolves to something other than `.rb` or a recognized native extension shape (current behavior of falling back to absolute path is removed).
- Companion-file detection: at minimum, sibling files inside the same `ext/<name>/` or `lib/<name>/` directory that are referenced by relative path from the `.so` via standard `require`/`__dir__` patterns. If none are detected, only the `.so` is bundled. The detection rule is documented in the code.

**Implementation notes**

- This milestone strictly depends on M1's payload module being in place.
- Do not re-introduce the `external` map. Delete the branch.

### M3 — Runtime: self-extract loader

Add a small bootstrap snippet emitted at the head of every packed output (alongside the existing `FixedRequire` prelude). On first call into the loader, it:

1. Reads `DATA`, parses out the native section header to get the SHA-256.
2. Resolves the cache directory (precedence as above).
3. If `<cache>/<hash>/` exists and looks complete (a `READY` sentinel file), uses it as-is.
4. Otherwise acquires `<cache>/<hash>.lock` via `flock(LOCK_EX)`, extracts into `<cache>/<hash>.tmp/`, writes `READY`, `rename`s to `<cache>/<hash>/`, releases the lock.
5. Stashes the resolved directory in a constant the `require_replacer` lookup uses.

**Acceptance criteria**

- Cold cache: a clean cache directory triggers extraction; second invocation in the same directory does no work beyond stat+open.
- Concurrent invocations: launching N copies in parallel against an empty cache results in exactly one extraction; the rest wait on `flock` and reuse the result. Add a test that races at least 4 processes.
- Cache directory permissions: `0700` on the per-hash subdirectory.
- Atomic rename: a process killed mid-extraction must leave no half-populated `<hash>/` behind on the next run (the `.tmp/` directory is fine to leave; subsequent runs detect missing `READY` and re-extract).

**Implementation notes**

- `flock` on a sibling lockfile (`<cache>/<hash>.lock`), not on the directory itself.
- The bootstrap must work under `--disable-gems`. No rubygems, no Bundler, stdlib only (`fileutils`, `digest`, `tmpdir` are all stdlib).
- M3 depends on M1 (parse) and M2 (something to extract).

### M4 — Wire `require_replacer` to the extracted directory

Collapse the embedded/external split in `require_replacer.rb`. The `FixedRequire` prelude:

- For `.rb` logical names → return the embedded ISeq as today.
- For non-`.rb` logical names → resolve to `<cache>/<hash>/<relative-path>` (built in M3), call the underlying `require` with that absolute path, and pre-populate `$LOADED_FEATURES` so subsequent `require`s short-circuit.
- Unknown names still fall through to `super`.

The `mark_runtime_resolved` C-extension special case (currently handling `rb_require` bypass) needs to be checked against the new flow — the goal is the same: any extension load goes through the cache dir, never the host's gem path.

**Acceptance criteria**

- `REQUIRE_MAP`-as-absolute-host-path is removed; the constant the runtime reads is now the logical-name → cache-relative-path mapping.
- All existing tests that exercised native extension loading still pass against the new mechanism (with their fixtures regenerated).
- Running `strings` on a packed output containing native ext shows no `/usr/lib`, no `~/.gem`, no host-specific absolute paths beyond the shebang.

**Implementation notes**

- Depends on M1+M2+M3.
- Keep the `FixedRequire` prelude small — it ships in every packed output.

### M5 — Error handling: noexec, write-failure, corruption

Make failure modes loud and actionable.

**Acceptance criteria**

- If the chosen cache directory is on a `noexec` mount (detected by attempting to `chmod +x` an extracted file and confirming `dlopen` would fail, or by mount option probe), the loader aborts with a single-line error pointing at `--cache-dir`. No silent fallback that "works" in misleading ways.
- If no candidate cache directory is writable, the loader prints the list of candidates it tried and the first errno seen.
- If the cache contents fail a hash check (bit-rot, manual tampering), the loader removes the directory and re-extracts.

**Implementation notes**

- The `noexec` probe runs only once per process (cache it). It must not run on the warm-cache path — only when extraction is actually happening.
- Error messages are user-facing copy; keep them concise and free of stack traces unless `UPRB_DEBUG` is set.
- Depends on M3.

### M6 — `--cache-dir` CLI flag

Add `--cache-dir DIR` to the *runtime* of the packed output (consumed by the bootstrap loader before user `ARGV` is honored), not to `uprb pack`.

**Acceptance criteria**

- `packed_script --cache-dir /some/path -- <user args>` extracts under `/some/path/<hash>/` and forwards everything after `--` to the user script as `ARGV`.
- Without `--cache-dir`, behavior is unchanged from M3.
- Without `--`, the loader leaves `ARGV` alone (no flag stripping that could collide with user options that happen to share a name). The flag is only recognized when it is the first argument and is followed by `--`.

**Implementation notes**

- Keep the parsing primitive: a hand-rolled check of `ARGV[0]` and `ARGV[2] == "--"` is enough. Do not pull `optparse` into the bootstrap.
- Document the exact grammar in README (M8).
- Depends on M3.

### M7 — Test suite update

Update `test/test_uprb_cli.rb` and add focused tests for the new mechanism.

**Acceptance criteria**

- New tests:
  - Cold/warm cache behavior on a packed output that uses a real C extension fixture.
  - Concurrent first-run race (≥4 processes).
  - Hash-stable across re-packs of identical input.
  - Noexec cache directory produces the documented error.
  - `--cache-dir` flag round-trip.
- Removed tests: anything that asserted host-absolute paths in the packed output, or the old `external` map shape.
- `bundle exec rake` is green on CI Ruby (3.4.7) and locally on Ruby 3.1+.

**Implementation notes**

- Reuse `examples/rls` / `examples/s3-ls` fixtures where possible.
- Race test: spawn via `Process.fork` (Linux test env) and synchronize on a barrier file. Skip on platforms without `fork` if any.
- Depends on M2+M3+M4 at minimum; ideally land alongside M4.

### M8 — Documentation update

Rewrite the parts of `README.md` and `CLAUDE.md` that describe the old "external absolute path" model.

**Acceptance criteria**

- `README.md`:
  - "Single executable" tagline is honest: the output is one file; native extensions are bundled and extracted into a cache directory on first run.
  - Cache directory resolution order is documented.
  - `--cache-dir` runtime flag is documented.
  - Pack-time ABI lock (Ruby version, glibc, gem versions at pack time) is still called out.
  - Keep the README concise — no tutorial sections, no etymology, no expanded "Security model" prose. Reference material only.
- `CLAUDE.md`:
  - Drop the "C extensions and other non-`.rb` requires are always referenced by their **original absolute path** via `REQUIRE_MAP`" hard constraint. Replace with the new constraint: bundled into the payload, extracted to content-addressed cache.
  - Drop "vendoring C extensions" from Non-goals. The wider non-goal of "bundling Ruby itself" / "cross-machine portability" stays.
  - Update the architecture description of `require_replacer.rb` to match the unified flow.

**Implementation notes**

- Last milestone. Depends on M2 through M6 being merged so the documentation matches the actually-shipped behavior.
- Do not duplicate the PLAN content into either README or CLAUDE.md; this PLAN file is removed in the same PR or in a follow-up cleanup.

## Out of plan / future notes

- Linux fast path using `memfd_create` + `dlopen("/proc/self/fd/N")` to skip extraction entirely on supported kernels. Documented here only so the option is not re-evaluated from scratch later. Not implemented; the disk-extract path is sufficient.
- Cache GC (`uprb cache prune` or similar). Not in scope; users can `rm -rf` the cache directory safely. Revisit only if real usage shows cache bloat.
