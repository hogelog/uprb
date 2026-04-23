# uprb

uprb is a Ruby script packer.

It builds a single executable from a Ruby script and freezes how it runs.
Every `.rb` dependency observed at pack time is compiled into
`RubyVM::InstructionSequence` binaries and embedded in the output; C
extensions and other non-`.rb` requires are referenced by their original
absolute paths. The output is meant to be fast to start and deterministic.

This tool does not produce native binaries. It assumes a Ruby interpreter
is already installed and runs the packed script with that Ruby.

## Usage

Pack a script into a single executable:

```bash
uprb pack path/to/script.rb path/to/output
```

Options:

- `--enable-rubygems`: do not pass `--disable-gems` to Ruby

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Options:

- `--enable-rubygems`
- `--path DIR`: install packed executables into this directory

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

Options:

- `--enable-rubygems`
- `--path DIR`: install executables into this directory

## Install

```bash
gem install uprb
```
