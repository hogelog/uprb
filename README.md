# uprb

uprb is a Ruby script packer.

It builds a single executable from a Ruby script and freezes how it runs.
Every `.rb` dependency discovered at pack time is compiled into
`RubyVM::InstructionSequence` binaries and embedded in the output; C
extensions and other non-`.rb` requires are referenced by their original
absolute paths. The output is meant to be fast to start and deterministic.

By default, `uprb` skips executing the entry script: it parses the
entry with Prism, loads the literal `require` / `require_relative` /
`autoload` targets it finds, records whatever those libraries pull in
transitively, and augments that with a static walk of every reachable
`.rb` file. The entry's other top-level code (e.g. `App.start(ARGV)`)
never runs. Pass `--dynamic` to instead execute the entry at pack time,
which catches runtime-only requires (e.g. interpolated `require`s that
only fire when a specific code path is exercised) at the cost of actually
running the script.

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
- `-r`, `--require LIB`: pre-require `LIB` at pack time so it is embedded, and re-`require` it before the script runs. Repeatable. Useful when a gem references constants (e.g. `Gem::Version`) that are normally provided by rubygems but whose defining file is standalone-loadable under `--disable-gems` (for `Gem::Version`, `-r rubygems/version`).
- `--with-rubygems`: shortcut for `--require rubygems`. Embeds the whole rubygems library as ISeq so `Gem::*` constants are available at runtime. The shebang stays `--disable-gems` — rubygems is carried in the payload, not auto-loaded at Ruby boot. Convenient for packing gems that reference `Gem::Version` / `Gem::Requirement` / `Gem::Platform` etc. Trade-off: larger output.
- `--dynamic`: execute the entry script at pack time instead of only parsing it. The runtime require tracker observes every `require` that actually fires, catching interpolated-string requires and other dynamic resolution the default mode misses — but the entry's top-level code *runs*, which is a problem for CLI scripts that do I/O or hit the network on startup.

Pack executables from an installed gem:

```bash
uprb gem pack GEM_NAME
```

Options:

- `--path DIR`: install packed executables into this directory
- `-f`, `--force`: overwrite existing executables without prompting
- `-r`, `--require LIB`: same as above; repeatable
- `--with-rubygems`: same as above
- `--dynamic`: same as above

Install a gem and pack its executables:

```bash
uprb gem install GEM_NAME
```

Options:

- `--path DIR`: install executables into this directory
- `-f`, `--force`: overwrite existing executables without prompting
- `-r`, `--require LIB`: same as above; repeatable
- `--with-rubygems`: same as above
- `--dynamic`: same as above

By default, `uprb` asks `overwrite? [y/N]` on stderr when the destination
already exists and proceeds only if you answer `y`/`yes`. When stdin is
not a TTY (e.g. CI), `uprb` refuses to overwrite unless `--force` is
given.

## Install

```bash
gem install uprb
```
