# uprb

[![Test](https://github.com/hogelog/uprb/actions/workflows/test.yml/badge.svg)](https://github.com/hogelog/uprb/actions/workflows/test.yml)
[![Gem Version](https://badge.fury.io/rb/uprb.svg)](http://badge.fury.io/rb/uprb)

uprb packs a Ruby script into a single executable with fast, deterministic startup.

Ruby dependencies are embedded as ISeq binaries. Native extensions are bundled too, and extracted into a reusable cache on first run. Outputs with no native extensions include no cache loader and do not touch the cache.

The output still requires the pack-time Ruby interpreter and compatible Ruby/OS libraries; it is not a cross-platform binary. Original source filenames remain in ISeqs for diagnostics and relative requires. The default shebang runs Ruby with `--disable-gems`; flags below can change this.

## Install

```bash
gem install uprb
```

## Usage

Pack a script:

```bash
uprb pack path/to/script.rb path/to/output
```

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

## Options

- `-f`, `--force` — overwrite destination
- `-r`, `--require LIB` — pre-`require` `LIB` (repeatable)
- `--with-rubygems` — embed rubygems; needed when the script references `Gem::Version` etc.
- `--dynamic` — run the entry script at pack time to capture runtime `require`s. Arguments after `--` become `ARGV` (e.g. `-- --help` to avoid side effects)
- `--skip-disable-gems` — drop `--disable-gems` from the shebang (vendoring mode; gives up fast startup)
- `--skip-ruby-path-replace` — keep the source shebang's ruby invocation instead of rewriting to an absolute path
- `--path DIR` — destination directory (`gem` subcommands only)

## Native cache

Set `RUBY_UPRB_CACHE_DIR` to override the cache location:

```bash
RUBY_UPRB_CACHE_DIR=/path/to/cache packed_script --your-options
```

The loader tries this directory first, then `$XDG_CACHE_HOME/uprb` (or `~/.cache/uprb`), then `uprb-<uid>` under the temporary directory (`TMPDIR`, `TMP`, `TEMP`, or `/tmp`). Empty environment values are ignored. Cache roots must be owned by the current user and not writable by other users. An unusable location falls through to the next candidate; a `noexec` error asks you to set `RUBY_UPRB_CACHE_DIR` to an executable filesystem.

Native files live in a private directory keyed by the SHA-256 of their bundled contents. Concurrent first runs share a lock and publish the extraction by atomic rename. Warm runs check file metadata; changes trigger comparison with the embedded bytes and repair if needed. Cache directories can be deleted when no packed process is using them; the next run rebuilds them.

Packed programs receive `ARGV` unchanged, including `--cache-dir` and `--`: there are no uprb runtime CLI options. Native companions in an extension's own same-named directory retain their relative layout. Arbitrary gem data files and system shared libraries are not bundled; unknown runtime requires still use Ruby's normal loader.

## Gemspec metadata

`uprb gem pack` / `uprb gem install` honors `uprb.requires` (comma-separated) in `Gem::Specification#metadata` as additional pre-`require` libraries, merged with `-r`:

```ruby
spec.metadata["uprb.requires"] = "openssl,json"
```
