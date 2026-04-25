# uprb

[![Test](https://github.com/hogelog/uprb/actions/workflows/test.yml/badge.svg)](https://github.com/hogelog/uprb/actions/workflows/test.yml)
[![Gem Version](https://badge.fury.io/rb/uprb.svg)](http://badge.fury.io/rb/uprb)

uprb packs a Ruby script into a single executable with fast, deterministic startup.

The output still requires a Ruby interpreter and is tied to the Ruby and gems active at pack time. The default shebang runs Ruby with `--disable-gems`; flags below can change this.

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

## Gemspec metadata for pack hints

Gem authors can declare pack hints in `Gem::Specification#metadata`. When `uprb gem pack <gem>` or `uprb gem install <gem>` resolves the spec, recognized `uprb.*` keys augment the CLI options so end users get gem-specific defaults without remembering flags.

| key | type | meaning |
|---|---|---|
| `uprb.requires` | comma-separated string | additional libraries to pre-`require` (merged with `-r` from the CLI) |

Example gemspec:

```ruby
Gem::Specification.new do |spec|
  spec.name = "your-gem"
  spec.metadata["uprb.requires"] = "openssl,json"
end
```

When packing this gem, `uprb` behaves as if `-r openssl -r json` were passed.

### Security model

Hints are advisory and parsed strictly; no code from the gem is executed as a result of reading metadata.

- Values are inert strings. Each entry is split on `,`, trimmed, and must match `/\A[A-Za-z0-9_.\/-]+\z/` — entries with shell metacharacters, whitespace, or a leading dash are dropped with a warning.
- Only keys explicitly listed above are honored. Unknown `uprb.*` keys produce a warning and are ignored (helps catch typos without expanding the surface).
- Packer-side knobs (`--skip-disable-gems`, `--skip-ruby-path-replace`, `--dynamic`, script `ARGV`) are intentionally not exposed via metadata: they reflect packer intent rather than gem requirements.
