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
