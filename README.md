# uprb

[![Test](https://github.com/hogelog/uprb/actions/workflows/main.yml/badge.svg)](https://github.com/hogelog/uprb/actions/workflows/main.yml)
[![Gem Version](https://badge.fury.io/rb/uprb.svg)](http://badge.fury.io/rb/uprb)


uprb is a Ruby script packer. It builds a single executable from a Ruby
script with a fast, deterministic startup.

This is not a native binary compiler. The packed executable still needs
a Ruby interpreter on the machine that runs it, and it is tied to the
Ruby and gems that were active when you packed.

The packed executable starts Ruby with `--disable-gems` by default.
Gems that depend on rubygems at load time will not work as-is — use
`--with-rubygems` to embed rubygems into the output, or
`--skip-disable-gems` to drop the flag entirely (vendoring only; gives
up the fast-startup headline).

## Install

```bash
gem install uprb
```

## Usage

Pack a script into a single executable:

```bash
uprb pack path/to/script.rb path/to/output
```

Options:

- `-f`, `--force`: overwrite the destination without prompting
- `-r`, `--require LIB`: pre-`require` `LIB` so it is embedded and loaded before the script runs. Repeatable.
- `--with-rubygems`: shortcut for `--require rubygems`. Needed when the script references `Gem::Version` / `Gem::Requirement` / `Gem::Platform` etc. Trade-off: larger output.
- `--dynamic`: execute the entry script at pack time so runtime-only requires (e.g. interpolated `require`s) are captured. The entry actually runs, which is a problem for scripts that do I/O on startup — arguments after `--` are forwarded as `ARGV` so you can steer into a safe path (e.g. `-- --help`).
- `--skip-disable-gems`: drop `--disable-gems` from the shebang. The output then behaves like a normal Ruby invocation — rubygems, `RUBYOPT`, and Bundler's Gemfile autodetection all run as usual. Use this when you want single-file vendoring of `.rb` dependencies and don't care about startup latency.
- `--skip-ruby-path-replace`: keep the source file's shebang ruby invocation (e.g. `/usr/bin/env ruby`) instead of rewriting it to an absolute `RbConfig.ruby` path. `--disable-gems` is still appended (unless `--skip-disable-gems` is also passed), so this is orthogonal to `--skip-disable-gems`. Use for vendoring when you want a portable Ruby reference in the output.

If the source has no shebang, the packed output also has no shebang and is not chmod'd executable — invoke via `ruby packed_file`. This applies regardless of flags.

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

Both `gem` subcommands accept `--path DIR` (destination directory),
`-f`/`--force`, `-r`/`--require LIB`, `--with-rubygems`, `--dynamic`,
`--skip-disable-gems`, and `--skip-ruby-path-replace`.

By default, `uprb` asks `overwrite? [y/N]` on stderr when the
destination already exists. When stdin is not a TTY (e.g. CI), `uprb`
refuses to overwrite unless `--force` is given.
