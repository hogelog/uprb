# uprb

uprb is a Ruby script packer.

It builds a single executable from a Ruby script and freezes how it runs.
Every `.rb` dependency observed at pack time is compiled into
`RubyVM::InstructionSequence` binaries and embedded in the output; C
extensions and other non-`.rb` requires are referenced by their original
absolute paths. The output is meant to be fast to start and deterministic.

The packed executable always starts Ruby with `--disable-gems`, so
rubygems is not available at runtime. Scripts that depend on gems which
require rubygems to load (e.g. gems that pull in `rubygems/vendor/uri`)
are out of scope.

This tool does not produce native binaries. It assumes a Ruby interpreter
is already installed and runs the packed script with that Ruby.

## Usage

Pack a script into a single executable:

```bash
uprb pack path/to/script.rb path/to/output
```

Options:

- `-f`, `--force`: overwrite the destination without prompting

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Options:

- `--path DIR`: install packed executables into this directory
- `-f`, `--force`: overwrite existing executables without prompting

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

Options:

- `--path DIR`: install executables into this directory
- `-f`, `--force`: overwrite existing executables without prompting

By default, `uprb` asks `overwrite? [y/N]` on stderr when the destination
already exists and proceeds only if you answer `y`/`yes`. When stdin is
not a TTY (e.g. CI), `uprb` refuses to overwrite unless `--force` is
given.

## Install

```bash
gem install uprb
```
