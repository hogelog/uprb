# uprb

[![Test](https://github.com/hogelog/uprb/actions/workflows/test.yml/badge.svg)](https://github.com/hogelog/uprb/actions/workflows/test.yml)
[![Gem Version](https://badge.fury.io/rb/uprb.svg)](http://badge.fury.io/rb/uprb)

uprb packs a Ruby script into a single executable with fast, deterministic startup.

The output is a single file: `.rb` dependencies are embedded as `RubyVM::InstructionSequence` binaries and native extensions (`.so` and companion files) are bundled inside the payload, then extracted on first run into a content-addressed cache directory and `dlopen`'d from there. Re-runs find the cache warm and skip extraction.

The output still requires a Ruby interpreter and stays ABI-locked to the Ruby and gems active at pack time. The default shebang runs Ruby with `--disable-gems`; flags below can change this.

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

## Runtime cache

Packed outputs extract their bundled native extensions into a content-addressed cache directory on first run. The directory is resolved in this order:

1. `--cache-dir DIR` — runtime flag on the packed output. Recognized only when it is the first argument and is followed by `--`: `packed_script --cache-dir DIR -- user args`. Without `--`, the loader leaves `ARGV` alone.
2. `$XDG_CACHE_HOME/uprb/`, falling back to `~/.cache/uprb/`.
3. `$TMPDIR/uprb-<uid>/` (final fallback).

The cache is keyed by the SHA-256 of the bundled native section, so re-compiling `.rb` ISeqs (e.g. across Ruby patch versions) does not invalidate it. The cache contents are safe to remove with `rm -rf` at any time.

## Gemspec metadata

`uprb gem pack` / `uprb gem install` honors `uprb.requires` (comma-separated) in `Gem::Specification#metadata` as additional pre-`require` libraries, merged with `-r`:

```ruby
spec.metadata["uprb.requires"] = "openssl,json"
```
