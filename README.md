# lexiftool

[![CI](https://github.com/blitzview-org/lexiftool/actions/workflows/ci.yml/badge.svg)](https://github.com/blitzview-org/lexiftool/actions/workflows/ci.yml)

lexiftool is a Lua port of [ExifTool](https://exiftool.org/) by Phil Harvey
(the `Image::ExifTool` Perl library and the `exiftool` command-line
application). It reads and writes metadata in the same file formats, with
the same tag names, the same options and the same output.

The port is structural: every `Image::ExifTool::X` module has a counterpart
`lexiftool.X` (`lib/Image/ExifTool/X.pm` ↔ `src/lexiftool/X.lua`) with the
same tag tables, the same function names and the same code order, so it can
be kept in step with upstream releases by reading the two side by side.
Perl built-ins are reached through a small facade (`src/lexiftool/perl.lua`)
that keeps Perl's semantics.

## Download

To try it out without installing anything: [prebuilt executables for
Linux, Windows and macOS](../../releases/latest) -- unzip and run (Linux
x86-64 with glibc 2.17 or newer, macOS 11 or newer, Windows x64; see
[Standalone executables](#standalone-executables)).

## Status

- Tracks ExifTool 13.59 (`vendor/exiftool`, a git submodule of the upstream
  repository).
- Reading and writing are ported; the command-line tool `lexiftool` accepts
  exiftool's command lines and produces byte-identical output for them.
- The ported upstream test suite (`vendor/exiftool/t/*.t` → `src/test/`)
  passes on Lua 5.4 and 5.5.
- What cannot behave identically -- mainly user-supplied Perl code such as
  config files and `-if`/`-p` expressions beyond the supported subset -- is
  listed in [doc/differences.md](doc/differences.md). Config files are
  written in Lua instead ([doc/configuration.md](doc/configuration.md)).

## Installation

lexiftool needs Lua 5.4 or 5.5 and a few LuaRocks modules, three of which
bind C libraries that have to be present first (see
[C libraries](#c-libraries) below):

| Rock            | Purpose                                         | C library             |
|-----------------|-------------------------------------------------|-----------------------|
| `lpcre`         | PCRE2 regex engine behind the `perl` facade     | libpcre2-8            |
| `carray`        | mutable byte buffers                            | --                    |
| `luafilesystem` | file system access                              | --                    |
| `lua-zlib`      | compressed data (Compress::Zlib)                | zlib                  |
| `digest`        | MD5 and SHA-2 digests (Digest::MD5/SHA)         | --                    |
| `lbrotli`       | Brotli-compressed metadata (IO::\*::Brotli)     | libbrotlidec/-enc     |

`lbrotli` is optional for the library -- without it, Brotli-compressed
metadata is reported the way exiftool reports it without the Brotli Perl
modules -- but LuaRocks has no optional dependencies, so the `lexiftool` rock
requires it. The rock also builds the port's own small C module
`lexiftool.sys`, which needs nothing but the C runtime.

### With LuaRocks

```sh
luarocks --lua-version 5.4 install lexiftool     # or --lua-version 5.5;
                                                 # add --local for ~/.luarocks
lexiftool -ver -v
```

This installs the library (`require('lexiftool')`, see
[doc/api.md](doc/api.md)) and the command-line tool `lexiftool` into the rock
tree's `bin/` directory, together with all dependencies. With `--local`,
put `~/.luarocks/bin` on your `PATH`. `lexiftool -ver -v` lists the Lua
libraries it found in place of exiftool's optional Perl modules.

The rock runs from the Lua sources; the precompiled bytecode of a source
checkout (`make bytecode`, about 25 ms faster per start) is not part of it
yet.

`lpcre`, `lbrotli`, `carray` and `digest` are published on luarocks.org, so
the `luarocks install lexiftool` command above pulls them in automatically;
only if one of them is ever missing there would it need installing from its
source repository first (`luarocks make rockspecs/<name>-scm-0.rockspec` in a
clone of `github.com/osch/lua-<name>`), then `lexiftool` itself from this
checkout (`luarocks make rockspecs/lexiftool-scm-0.rockspec`).

### C libraries

The headers and libraries of PCRE2, Brotli and zlib, the Lua headers and a
C compiler:

| Platform        | Command                                                                                              |
|-----------------|------------------------------------------------------------------------------------------------------|
| Arch / Manjaro  | `pacman -S lua luarocks pcre2 brotli zlib base-devel`                                                |
| Debian / Ubuntu | `apt install lua5.4 liblua5.4-dev luarocks libpcre2-dev libbrotli-dev zlib1g-dev build-essential`    |
| Fedora          | `dnf install lua lua-devel luarocks pcre2-devel brotli-devel zlib-devel gcc`                         |
| macOS (Homebrew)| `brew install lua luarocks pcre2 brotli` (zlib comes with the system)                                |
| Windows (vcpkg) | `vcpkg install pcre2 brotli zlib` (with a Lua and LuaRocks set up for MSVC or MinGW)                 |

When LuaRocks does not find a library by itself (typically Homebrew on
Apple Silicon or vcpkg), point it at the installation prefix, e.g.

```sh
luarocks install lpcre    PCRE2_DIR=$(brew --prefix pcre2)
luarocks install lbrotli  BROTLI_DIR=$(brew --prefix brotli)
luarocks install lpcre    PCRE2_DIR=C:\vcpkg\installed\x64-windows     # likewise BROTLI_DIR, ZLIB_DIR
```

### Standalone executables

For a quick try without Lua or LuaRocks: single-file executables that
contain a Lua 5.5 interpreter, all lexiftool modules, the Geolocation
database and the C modules listed above (statically linked, with PCRE2,
zlib and Brotli), for Linux, Windows and macOS -- see
[Download](#download) above, or directly the
[releases page](../../releases/latest). Each zip holds a `lexiftool/`
folder with the executable, `LICENSE`, `LICENSE-THIRD-PARTY` and the
license texts of all built-in components (`licenses/`).

Requirements:

- Linux: x86-64 with glibc 2.17 or newer (RHEL/CentOS 7, Debian 8,
  Ubuntu 14.04 and everything newer); not on musl systems such as Alpine
  -- install the rock there.
- macOS: 11 or newer, x86-64 and Apple Silicon.
- Windows: x64.

The executables are not signed: macOS asks for confirmation on the first
start (or run `xattr -d com.apple.quarantine lexiftool/lexiftool`), Windows
SmartScreen may warn. They are built reproducibly with podman on Linux
(`make windows`, `make macos`, `make linux`); see
[standalone/README.md](standalone/README.md).

### From the sources

```sh
git clone --recurse-submodules https://github.com/blitzview-org/lexiftool.git lexiftool
cd lexiftool
luarocks --lua-version 5.4 --local install carray       # likewise luafilesystem,
                                                          # lua-zlib, digest,
                                                          # lpcre, lbrotli
make sys          # builds build/<5.4|5.5>/lexiftool/sys.so
make bytecode     # optional: precompiled modules for faster start-up
./lexiftool -ver -v
```

`./lexiftool` is the command-line entry point and runs from the checkout; it
finds its modules under `src/` and the C modules under `build/`. The
library can also be used directly: put `src/` on `package.path` and
`build/<version>/` on `package.cpath`, then `require('lexiftool')`
(see [doc/api.md](doc/api.md)).

The rockspecs are in `rockspecs/`; after adding, removing or renaming a
module, `lua rockspecs/update_modules.lua` regenerates their module lists.

## Development

```sh
make check        # C modules, test suite (Lua 5.4 + 5.5), luacheck, parity checks
make test         # the ported upstream test suite only (under a de_DE locale,
                  # see CONTRIBUTING.md; TEST_LOCALE=C to run it under "C")
make verify       # structural parity of the port against vendor/exiftool
make test-cli     # CLI golden comparison against Perl exiftool (report-only,
                  # see doc/cli-tests.md)
make test-corpus  # the same comparison over exiftool.org's sample images,
                  # fetched on demand, never committed (doc/cli-tests.md)
```

The tests and the parity checks need the `vendor/exiftool` submodule (its
`t/` directory holds the test images and expected outputs). The rules the
port follows are in [CONTRIBUTING.md](CONTRIBUTING.md) and
[doc/conventions.md](doc/conventions.md).

## License

lexiftool is distributed under the same terms as ExifTool and Perl itself:
the Artistic License or the GNU General Public License, version 1 or later.
See [LICENSE](LICENSE); third-party components are listed in
[LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY).
