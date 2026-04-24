# uprb

uprb is a Ruby script packer. It builds a single executable from a Ruby
script with a fast, deterministic startup.

This is not a native binary compiler. The packed executable still needs
a Ruby interpreter on the machine that runs it, and it is tied to the
Ruby and gems that were active when you packed.

The packed executable starts Ruby with `--disable-gems`. Gems that
depend on rubygems at load time will not work as-is — use
`--with-rubygems` to embed rubygems into the output.

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

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

Both `gem` subcommands accept `--path DIR` (destination directory),
`-f`/`--force`, `-r`/`--require LIB`, `--with-rubygems`, and `--dynamic`.

By default, `uprb` asks `overwrite? [y/N]` on stderr when the
destination already exists. When stdin is not a TTY (e.g. CI), `uprb`
refuses to overwrite unless `--force` is given.

## Install

```bash
gem install uprb
```
