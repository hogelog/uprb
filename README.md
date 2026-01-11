# uprb

uprb is a Ruby script packer.

It builds a single executable from a Ruby script and freezes how it runs.
The output is meant to be fast to start and deterministic.

## Usage

Pack a script into a single executable:

```bash
uprb pack path/to/script.rb path/to/output
```

Options:

- `--skip-iseq-cache`: keep plain Ruby output instead of ISeq payload
- `--enable-rubygems`: do not pass `--disable-gems` to Ruby

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Options:

- `--skip-iseq-cache`
- `--enable-rubygems`

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

Options:

- `--skip-iseq-cache`
- `--enable-rubygems`

## Install

```bash
gem install uprb
```
