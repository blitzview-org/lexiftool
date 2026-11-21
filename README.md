# lexiftool

[![CI](https://github.com/blitzview-org/lexiftool/actions/workflows/ci.yml/badge.svg)](https://github.com/blitzview-org/lexiftool/actions/workflows/ci.yml)

lexiftool is a Lua port of [ExifTool](https://exiftool.org/) by Phil Harvey
(the `Image::ExifTool` Perl library and the `exiftool` command-line
application). It reads and writes metadata in the same file formats, with
the same tag names, the same options and the same output. Every upstream
module has a Lua counterpart with the same tables, functions and code
order, so the port follows upstream releases file by file (see
[CONTRIBUTING.md](CONTRIBUTING.md)).

## Download

[Prebuilt executables for Linux, Windows and macOS](../../releases/tag/latest-dev)
-- unzip and run, no Lua or Perl needed (see [Platforms](#platforms)). These
are snapshots of the latest commit on master, rebuilt on every push;
`lexiftool -ver -v` prints the build's identity. Tagged versions are on the
[releases page](../../releases).

## Why lexiftool

- **Same results as exiftool**: the same command lines, options and tag
  names, with output verified byte for byte against the Perl original;
  where it cannot be the same, [doc/differences.md](doc/differences.md)
  says why.
- **A single executable** without Perl for Linux, macOS and Windows.
- **Fast start**: each process starts several times faster than Perl
  exiftool.
- **Embeddable**: a C API with synchronous sessions, several of them in
  threads of one program, without child processes or pipes; and directly a
  Lua library. The library leaves the host process alone: no global time
  zone, locale or signal changes; a time zone set by the `TimeZone` option
  belongs to its object.
- **Config files in Lua** ([doc/configuration.md](doc/configuration.md));
  exiftool's Perl config files are read as far as they assign data.

Every development snapshot is measured against the Perl original of the
same ExifTool version on a GitHub runner, as part of the build that
publishes it ([method](doc/benchmark.md)); the tables by file type are on
the [comparison page](https://blitzview-org.github.io/lexiftool/), the raw
data on the [download page](../../releases/tag/latest-dev).

<a href="https://blitzview-org.github.io/lexiftool/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://blitzview-org.github.io/lexiftool/benchmark-dark.svg">
    <img alt="Performance comparison with Perl ExifTool, latest development snapshot" src="https://blitzview-org.github.io/lexiftool/benchmark.svg">
  </picture>
</a>

## Quick start

Command line, as with exiftool:

```sh
lexiftool -Make -Model photo.jpg                         # two tags (-j: all tags as JSON)
lexiftool -Artist="Jane Doe" -o photo_new.jpg photo.jpg  # write a tag into a copy
lexiftool -stay_open True -@ -                           # commands from stdin, as exiftool does
```

Lua ([doc/api.md](doc/api.md)):

```lua
local ExifTool = require('lexiftool')
local et = ExifTool:new()
local info = et:ImageInfo('photo.jpg', 'Make', 'Model')
print(info.Make, info.Model)
et:SetNewValue('Artist', 'Jane Doe')
et:WriteInfo('photo.jpg', 'photo_new.jpg')
```

C ([doc/capi.md](doc/capi.md); `lexiftool_execute` runs exiftool command
lines, a complete program in [capi/example.c](capi/example.c)):

```c
#include <lexiftool.h>

lexiftool_session* s = lexiftool_open(NULL);
const char* tags[] = { "Make", "Model" };
lexiftool_info info;
lexiftool_image_info(s, "photo.jpg", tags, 2, 0, &info);
for (size_t i = 0; i < info.count; i++)
    printf("%s: %s\n", info.tags[i].name, info.tags[i].value);
lexiftool_info_free(&info);
lexiftool_set_new_value(s, "Artist", "Jane Doe", LEXIFTOOL_NUL_TERMINATED);
lexiftool_write_info(s, "photo.jpg", "photo_new.jpg");
lexiftool_close(s);
```

## Status

- Tracks ExifTool 13.64 (`vendor/exiftool`, a git submodule of the upstream
  repository).
- Reading and writing are ported; the command-line tool `lexiftool` accepts
  exiftool's command lines and produces byte-identical output for them.
- The ported upstream test suite (`vendor/exiftool/t/*.t` → `src/test/`)
  passes on Lua 5.4 and 5.5.
- What cannot behave identically -- mainly user-supplied Perl code such as
  config files and `-if`/`-p` expressions beyond the supported subset -- is
  listed in [doc/differences.md](doc/differences.md).

## Platforms

|                      | Linux                          | macOS                          | Windows                    |
|----------------------|--------------------------------|--------------------------------|----------------------------|
| LuaRocks install     | Lua 5.4 / 5.5                  | Lua 5.4 / 5.5                  | Lua 5.4 / 5.5 (MSVC or MinGW) |
| Standalone executable| x86-64, glibc 2.17 or newer    | 11 or newer, x86-64 and Apple Silicon | x64                 |
| C API                | x86-64, glibc 2.17 or newer    | 11 or newer, x86-64 and Apple Silicon | x64, Windows 7 or newer (MSVC, MinGW) |

glibc 2.17 covers RHEL/CentOS 7, Debian 8, Ubuntu 14.04 and everything
newer; on musl systems such as Alpine, install the rock.

## Installation

lexiftool needs Lua 5.4 or 5.5 and a few LuaRocks modules, five of which
bind C libraries that have to be present first (see
[C libraries](#c-libraries) below):

| Rock            | Purpose                                         | C library             |
|-----------------|-------------------------------------------------|-----------------------|
| `lpcre`         | PCRE2 regex engine behind the `perl` facade     | libpcre2-8            |
| `carray`        | mutable byte buffers                            | --                    |
| `luafilesystem` | file system access                              | --                    |
| `compress.zlib` | compressed data (Compress::Zlib, IO::\*::\*flate) | zlib                  |
| `digest`        | MD5 and SHA-2 digests (Digest::MD5/SHA)         | --                    |
| `compress.brotli` | Brotli-compressed metadata (IO::\*::Brotli)   | libbrotlidec/-enc     |
| `compress.lzma` | compressed 7z headers (Compress::Raw::Lzma)     | liblzma               |
| `compress.bzip2` | Rawzor metadata (IO::Uncompress::Bunzip2)      | libbz2                |
| `cipher.aes`    | AES-encrypted PDF documents                     | --                    |
| `cipher.rc4`    | RC4-encrypted PDF documents                     | --                    |

All of them are required. The rock also builds the port's own small C module
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

The rock runs from the Lua sources.

All rocks above are published on luarocks.org; should one be missing
there, install it with `luarocks make rockspecs/<name>-scm-0.rockspec` in a
clone of `github.com/osch/lua-<name>` (`lua-compress`, `lua-cipher` for the
`compress.*` and `cipher.*` rocks), and lexiftool itself with
`luarocks make rockspecs/lexiftool-scm-0.rockspec` in this checkout.

### C libraries

The headers and libraries of PCRE2, Brotli, zlib, liblzma (XZ Utils) and
libbz2, the Lua headers and a C compiler:

| Platform        | Command                                                                                              |
|-----------------|------------------------------------------------------------------------------------------------------|
| Arch / Manjaro  | `pacman -S lua luarocks pcre2 brotli zlib xz bzip2 base-devel`                                      |
| Debian / Ubuntu | `apt install lua5.4 liblua5.4-dev luarocks libpcre2-dev libbrotli-dev zlib1g-dev liblzma-dev libbz2-dev build-essential` |
| Fedora          | `dnf install lua lua-devel luarocks pcre2-devel brotli-devel zlib-devel xz-devel bzip2-devel gcc`    |
| macOS (Homebrew)| `brew install lua luarocks pcre2 brotli xz bzip2` (zlib comes with the system)                       |
| Windows (vcpkg) | `vcpkg install pcre2 brotli zlib liblzma bzip2` (with a Lua and LuaRocks set up for MSVC or MinGW)  |

When LuaRocks does not find a library by itself (typically Homebrew on
Apple Silicon or vcpkg), point it at the installation prefix, e.g.

```sh
luarocks install lpcre    PCRE2_DIR=$(brew --prefix pcre2)
luarocks install compress.brotli BROTLIDEC_DIR=$(brew --prefix brotli) BROTLIENC_DIR=$(brew --prefix brotli)
luarocks install compress.zlib   ZLIB_DIR=$(brew --prefix zlib)          # optional on macOS
luarocks install compress.lzma   LZMA_DIR=$(brew --prefix xz)
luarocks install compress.bzip2  BZIP2_DIR=$(brew --prefix bzip2)        # keg-only in Homebrew
luarocks install lpcre    PCRE2_DIR=C:\vcpkg\installed\x64-windows     # likewise BROTLIDEC_DIR/BROTLIENC_DIR, ZLIB_DIR, LZMA_DIR, BZIP2_DIR
```

### Standalone executables

Single-file executables that contain a Lua 5.5 interpreter, all lexiftool
modules, the Geolocation database and the C modules listed above
(statically linked, with PCRE2, zlib and Brotli) -- from the
[download page](../../releases/tag/latest-dev); the systems they run on are listed
under [Platforms](#platforms). Each zip holds a `lexiftool/` folder with
the executable, `LICENSE`, `LICENSE-THIRD-PARTY` and the license texts of
all built-in components (`licenses/`).

The executables are not signed: macOS asks for confirmation on the first
start (or run `xattr -d com.apple.quarantine lexiftool/lexiftool`), Windows
SmartScreen may warn. They are built reproducibly with podman on Linux
(`make windows`, `make macos`, `make linux`); see
[standalone/README.md](standalone/README.md).

### From the sources

```sh
git clone --recurse-submodules https://github.com/blitzview-org/lexiftool.git lexiftool
cd lexiftool
for r in carray luafilesystem digest lpcre compress.zlib compress.brotli \
         compress.lzma compress.bzip2 cipher.aes cipher.rc4; do
    luarocks --lua-version 5.4 --local install $r
done
make sys          # builds build/<5.4|5.5>/lexiftool/sys.so
make bytecode     # optional: precompiled modules for faster start-up
./lexiftool -ver -v
```

`./lexiftool` is the command-line entry point and runs from the checkout; it
finds its modules under `src/` and the C modules under `build/`. The
library can also be used directly: put `src/` on `package.path` and
`build/<version>/` on `package.cpath`, then `require('lexiftool')`
(see [doc/api.md](doc/api.md)).

### System-wide, from the sources

`make install` installs the command-line tool, the Lua modules,
`lexiftool.sys` and the C API (a shared library) for one Lua version, in
the layout of a distribution package. The rocks above must be installed
system-wide for that Lua. Paths and settings: [doc/install.md](doc/install.md).

```sh
make install PREFIX=/usr LUA_VERSION=5.5          # DESTDIR=... for a staged install
```

On Arch Linux, the AUR has `lexiftool-git` and the rocks it needs.

## Starting lexiftool

- The `lexiftool` launcher sets its own module paths for the Lua version it
  runs on: it ignores entries of another Lua version's rock tree (which an
  unversioned `LUA_PATH`/`LUA_CPATH` set up for Lua 5.1 brings in) and adds
  `~/.luarocks`, `/usr/local` and `/usr` for its own version. A versioned
  `LUA_PATH_5_5`/`LUA_CPATH_5_5` takes precedence.
- When the script has a source tree next to it (`src/lexiftool/main.lua`),
  that tree is searched first, so `./lexiftool` in a checkout runs the
  checkout even if a lexiftool is also installed.
- `LEXIFTOOL_BYTECODE=0` makes it load the modules from `src/` instead of
  the precompiled ones of `make bytecode`.

## Documentation

- [doc/api.md](doc/api.md) -- the Lua library
- [doc/capi.md](doc/capi.md) -- the C API
- [doc/install.md](doc/install.md) -- system-wide installation (`make install`)
- [doc/configuration.md](doc/configuration.md) -- the config file
- [doc/differences.md](doc/differences.md) -- differences from exiftool
- [doc/cli-tests.md](doc/cli-tests.md) -- the comparison with Perl exiftool
- [doc/benchmark.md](doc/benchmark.md) -- the performance comparison with Perl exiftool
- [standalone/README.md](standalone/README.md) -- building the standalone
  executables
- For contributors: [CONTRIBUTING.md](CONTRIBUTING.md),
  [doc/conventions.md](doc/conventions.md), [doc/perl-facade.md](doc/perl-facade.md)

## Development

`make check` builds the C modules and runs the test suite (Lua 5.4 and 5.5)
and luacheck; the tests need the `vendor/exiftool` submodule. The rules the
port follows are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

lexiftool is distributed under the same terms as ExifTool and Perl itself:
the Artistic License or the GNU General Public License, version 1 or later.
See [LICENSE](LICENSE); third-party components are listed in
[LICENSE-THIRD-PARTY](LICENSE-THIRD-PARTY).
