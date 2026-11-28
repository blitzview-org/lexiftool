# C API

lexiftool as an in-process library for C and C++ programs, on Linux, macOS
and Windows. `LEXIFTOOL_API_VERSION` numbers the API.

## Idea

A *session* is one lexiftool instance inside the calling process: an own
Lua state in which the command-line script waits in its own `-stay_open`
command loop, plus one ExifTool object of the library. Through it the
caller can

- run **commands** -- an argument list or argfile text, exactly what an
  exiftool `-stay_open` client writes before `-execute` -- and get each
  command's stdout, stderr and exit status back (`lexiftool_execute`,
  `lexiftool_execute_text`);
- **read tags** through the library's `ImageInfo`: a file and an optional
  tag list in, a list of entries out, each with name, groups of families
  0-2, description, tag ID, converted and numerical value and copy number
  (`lexiftool_image_info`), without any text format in between;
- **write tags** as Image::ExifTool does: `SetNewValue` notes new values,
  `WriteInfo` writes them (`lexiftool_set_new_value`,
  `lexiftool_write_info`), with the object's options set by
  `lexiftool_set_option`.

Everything is synchronous: each call returns its result. Nothing is read
from stdin, nothing is written to stdout or stderr. Concurrency comes from
several sessions in threads of the caller.

In scope this matches exiftool's C++ interface (a `-stay_open` process
behind pipes, commands, tag lists with the same fields, new values and a
write call), without the process: no command numbers, no queue, no
timeouts.

```c
#include <stdio.h>
#include "lexiftool.h"

int main(void) {
    lexiftool_session* s = lexiftool_open(NULL);
    const char* argv[] = { "-G", "-Make", "-Model", "photo.jpg" };
    lexiftool_result r;
    if (lexiftool_execute(s, 4, argv, &r) == LEXIFTOOL_OK)
        fwrite(r.stdout_data, 1, r.stdout_len, stdout);
    else
        fprintf(stderr, "%s\n", lexiftool_last_error(s));
    lexiftool_result_free(&r);
    lexiftool_close(s);
    return 0;
}
```

`capi/example.c` is a complete program around `lexiftool_image_info`.

## API

The header `capi/lexiftool.h` (C99, usable from C++) declares every
function and struct and comments every field; this section explains what
the comments leave out. Functions that return `int` return a non-negative
result or one of the negative `LEXIFTOOL_E_*` codes of the header. After
`LEXIFTOOL_E_NOMEM` the session stays usable; after `LEXIFTOOL_E_FAILED`
(a Lua error, or a failed start) and `LEXIFTOOL_E_ENDED` (a command
contained `-stay_open False`) it is unusable and only `lexiftool_close`
remains.

An error *of a command or of a file* ("File not found", "Error opening
file") is no return code: it is on the command's stderr and in its
status, or an `Error` tag of `image_info`, or the result 0 of
`write_info`.

### Session

- `lexiftool_open` copies the options (NULL: all defaults; fields beyond
  `struct_size` count as 0, so the struct can grow) and starts the script
  as `lexiftool [-config FILE] -stay_open True -@ - [-common_args ...]` up
  to the wait for the first command. It returns NULL only when out of
  memory. A failed start (a module cannot be loaded) still returns the
  session: `lexiftool_state` is `LEXIFTOOL_E_FAILED` and
  `lexiftool_last_error` says why. Output of the start itself (a config
  file warning) arrives with the first command's output, as with
  `-stay_open`.
- `lexiftool_close` ends the loop the way a client's `-stay_open False`
  does (the script's cleanup runs) and frees everything.
- `lexiftool_last_error` carries a Lua traceback for a Lua error.
- `lexiftool_version` is a `git describe` baked in at build time;
  `lexiftool_api_version` returns the library's `LEXIFTOOL_API_VERSION`,
  to be checked against the header's.

### Commands

- `lexiftool_execute` takes the arguments verbatim: unlike argfile lines
  they may contain newlines and leading or trailing blanks.
  `lexiftool_execute_text` takes the same command as argfile text, with
  exiftool's argfile rules; a `#[CSTR]` line with C escapes is the way to
  put a newline into an argument there.
- In both, a `-execute` among the arguments separates commands, as for a
  client; the result then holds the output of all of them and the status
  of the last.
- The return value says whether the command *ran*; the command's own
  result is `out->status`. `out` is filled on every return (empty strings
  on errors), so it is always freed with `lexiftool_result_free`.
  `stdout_data`/`stderr_data` are NUL-terminated, but the lengths count:
  with `-b` the output is binary.

The session options carry what goes on the exiftool command line before
`-stay_open` (`-config`, `-common_args`); everything else is an argument
of the command, as for a client. Differences from a client: no `{ready}`
markers and no line encoding; an option left without its argument takes
the `-execute` that ends the command; `-stay_open True -@ FILE` inside a
command is not meaningful.

The output for a file can depend on the files processed before it in the
same session (the order of the Composite tags), in Perl exiftool as well
as here; comparisons across sessions must use the same sequence.

### Reading tags

`lexiftool_image_info` is `ImageInfo($file, \@tags)` of the session's
ExifTool object, followed by, for every tag key of the returned list,
`GetTagName`, `GetGroup` (families 0, 1, 2 and 4), `GetDescription`,
`GetTagID` and `GetValue($key, 'ValueConv')`:

- **Tags**: `tags[0..ntags-1]` are requested tags as `ImageInfo` takes
  them (`Model`, `EXIF:*`, `-Composite:all`, `ExposureTime#`); NULL or
  `ntags` 0 means all tags. A requested tag that is not in the file is
  left out.
- **Order**: that of `ImageInfo`'s tag list -- the order in the file, or
  the requested order when tags were named. The `Sort` option changes it:
  with `Sort` = `Group0:1:2:4` the entries come exactly in the order (and
  with the groups and copy numbers) of the keys of
  `exiftool -php -l -G:0:1:2:4 -D`, the command an exiftool C++ client
  sends.
- **Duplicates**: all of them, with `copy_num` from the family 4 group
  (`Copy1`, ...), as the library's default `Duplicates` = 1 returns them;
  `Duplicates` = 0 leaves them out.
- **Values**: `value` is the value of the info hash (PrintConv, unless
  the `PrintConv` option is 0), `num` the ValueConv value (`value` again
  if there is none; then both point to the same bytes). A list is joined
  with the `ListSep` option (default `", "`), a structure (option
  `Struct`) is serialized as in exiftool's text output, and NUL bytes
  inside a value are kept -- the lengths count, the strings are
  NUL-terminated as well.
- **Binary values** (a SCALAR reference in Perl, such as `ThumbnailImage`
  or `PreviewImage`) are delivered only on request: with the flag
  `LEXIFTOOL_INFO_BINARY` (the `Binary` option for this call) or when the
  tag is named in `tags`. Then `binary` is `LEXIFTOOL_BINARY_DATA` and
  `value`/`num` hold the bytes. Otherwise `binary` is
  `LEXIFTOOL_BINARY_HIDDEN` and `value` is exiftool's placeholder
  `(Binary data N bytes, use -b option to extract)`, with N also in
  `binary_len` -- so large data is not copied on every call.
- **Errors and warnings** of reading are tags (`ExifTool:Error`,
  `ExifTool:Warning`), as in `ImageInfo`; the first of each is also in
  `out->error`/`out->warning`. A file that cannot be opened gives
  `Error opening file`, as `ImageInfo` does (the command line says
  `File not found` because it checks first).
- The result is **one block of memory** (the array and all strings),
  owned by the caller until `lexiftool_info_free`, independent of the
  session (it may outlive it and be freed in another thread).

`lexiftool_set_option(s, name, value)` is `Options(name, value)` of the
session's object -- `PrintConv`, `Duplicates`, `Sort`, `Unknown`, `Lang`,
`DateFormat`, `TimeZone`, `Struct`, `ListSep`, `RequestAll`, `Charset` and
the rest of the library's options. They apply to `image_info`,
`set_new_value` and `write_info`; the commands of `lexiftool_execute*`
take their options from their arguments, as on the command line.

### Writing tags

- `lexiftool_set_new_value` is `SetNewValue(tag, value)`: the value is
  only noted. `len` is the value's length (binary data, NUL bytes) or
  `LEXIFTOOL_NUL_TERMINATED`. When it returns 0, `lexiftool_last_error`
  has `SetNewValue`'s message (`Tag 'X' is not defined`).
- `lexiftool_write_info` is `WriteInfo(file, outfile)`: `outfile` NULL
  rewrites `file` in place (no `_original` backup). The result 2 (written
  without changes) also comes when there are no new values. The new
  values stay set for further writes until cleared with
  `lexiftool_set_new_value(s, NULL, NULL, 0)`.

A value read with `image_info` (binary data included, when requested) can
be passed to `set_new_value` as it is, with its length.

### Memory

The caller owns everything it passes in; nothing is kept past the call
(`lexiftool_open` copies the options). The library owns the session. A
`lexiftool_result` or `lexiftool_info` belongs to the caller until
`lexiftool_result_free`/`lexiftool_info_free` -- always these, never
`free()` -- which are safe on a zeroed struct and zero it.

A command's output is collected in memory and copied once into the
result, so it must fit in memory; a command that would print gigabytes
(`-b` of a large embedded video) should write to files with `-w`/`-o`/`-W`
instead, as one would do through a pipe. The same holds for binary values
requested from `image_info`.

### Threads

A session is used from one thread at a time; the caller serializes.
Different sessions may be used from different threads at the same time,
and opened and closed in parallel: every session is its own Lua state, and
sessions share nothing (see [conventions.md](conventions.md#12-c-modules-no-writable-static-state)
for the rule the C modules follow). The library starts no threads and has
no asynchronous, timeout or cancel mechanism.

The host must not change the environment, the locale or the time zone
(`setenv`/`putenv`, `setlocale`, a new `TZ` with `tzset`) while sessions
run in other threads, as POSIX requires of any program that calls those
functions; the library itself never does.

Without a `TimeZone` option a session converts local times with the C
library's `mktime` in the process's zone. glibc's `mktime` starts from the
UTC offset of its previous call, process-wide, so for a local time that
exists twice (the hour after a change back from daylight saving time) the
result can depend on other threads' calls. A session with a `TimeZone`
option has a zone of its own, with its own such state.

What a session leaves to the host process:

- **Signals.** The library installs no signal handlers.
- **Environment, locale, time zone.** Nothing writes the environment or
  sets a locale. The `TimeZone` option, which upstream implements by
  setting `$ENV{TZ}` for the whole process, is a time zone of the session's
  ExifTool object (see [differences.md](differences.md#the-timezone-option--api-timezone)),
  so sessions with different zones run side by side; a session without the
  option uses the process's zone. Numbers print with `.` and strings sort
  as bytes whatever the host's locale.
- **Output.** Commands write into the result's buffers. Whatever the
  library itself would print during `image_info`, `set_option`,
  `set_new_value` or `write_info` (the `Verbose` option's output, a
  warning of `Options`) is dropped: reading and writing report through
  tags and return values. Nothing reaches the process's standard streams
  or file descriptors 1 and 2.
- **Current directory.** Relative file names are resolved against the
  process's current directory, which is process-wide; there is no
  per-session working directory, callers pass absolute paths (or change
  directory themselves while no other session runs).
- **Standard input.** A command that names `-` as a file (or `-@ -`)
  reads the *process's* stdin, and `-k` waits for its terminal. Hosts
  leave those out.

## Getting the library

- **Download** (the embedded variant, see below): every build of master
  and every release attaches one zip per platform to the
  [latest-dev pre-release](../../../releases/tag/latest-dev) or the
  [release](../../../releases), `lexiftool-capi-<platform>-<version>.zip`
  (`<version>` as for the standalone executables: the tag of a release,
  the `git describe` identity otherwise); the
  [C API download page](https://blitzview-org.github.io/lexiftool/capi/)
  lists those of latest-dev with size, SHA-256 and direct links. Each zip
  unpacks into one folder of its own name:

  ```
  README.txt                    what is where, how to link
  LICENSE, LICENSE-THIRD-PARTY  lexiftool's license, the components'
  licenses/                     their license texts (as in the
                                standalone zip)
  doc/capi.md                   this document
  example.c                     capi/example.c
  include/lexiftool.h
  lib/...                       Linux:   liblexiftool.a, liblexiftool.so.3,
                                         liblexiftool.so -> liblexiftool.so.3
                                macOS:   liblexiftool.a, liblexiftool.3.dylib,
                                         liblexiftool.dylib -> liblexiftool.3.dylib
                                         (universal: x86_64 and arm64)
                                Windows: lexiftool.lib (MSVC),
                                         liblexiftool.dll.a (MinGW),
                                         liblexiftool.a (MinGW, static),
                                         lexiftool.def
  lib/pkgconfig/lexiftool.pc    finds its own directory
  bin/lexiftool.dll             Windows only
  ```

  The unversioned names on Linux and macOS are symbolic links stored in
  the zip; `unzip`, `bsdtar`, 7-Zip and the macOS Archive Utility restore
  them. Should an unpacker leave a small text file instead,
  `ln -sf liblexiftool.so.3 lib/liblexiftool.so` (macOS:
  `ln -sf liblexiftool.3.dylib lib/liblexiftool.dylib`) repairs it. The
  libraries need the system's C library only (see "Build variants"); the
  CI links `test_capi` and `example` against each zip with the
  platform's own compiler (`capi/test-package.sh`: cc on Linux, cc
  universal natively and under Rosetta on macOS, MSVC on Windows) before
  it publishes them. Linking: [Linking](#linking).
- **Build it yourself**: `make capi-linux`, `make capi-macos`,
  `make capi-windows` (podman, the builder images of the standalone
  executables; see [Building the embedded libraries](#building-the-embedded-libraries)),
  and `make capi-package-<platform>` packs the same zip into
  `capi/build/dist/` (`capi/package.sh`, reproducible: the same commit
  and builder image give a byte-identical zip).
- **Against the system's Lua** (the rock variant, nothing embedded): with
  lexiftool and its rocks installed through LuaRocks or `make install`,
  `make capi-shared` builds `liblexiftool.so.<API>` for that Lua, and
  `make install` installs it with the header and `lexiftool.pc` (see
  [Build variants](#build-variants)).

## Platforms

The same API and the same sources on Linux (x86-64, glibc 2.17 or newer),
macOS (11 or newer, x86_64 and arm64) and Windows (x64, Windows 7 or
newer; MSVC and MinGW). What differs:

- **File names** are bytes everywhere, as for exiftool. On Windows a
  name is taken in the ANSI code page unless the session says otherwise:
  with `CharsetFileName` set to `UTF8` (`lexiftool_set_option`, or
  `-charset filename=utf8` in a command or in `common_argv`) a UTF-8 name
  is opened through the wide file API (see
  [differences.md](differences.md#windows-file-names-and-times)), so names
  outside the ANSI code page work. A host that has wide (UTF-16) names
  converts them to UTF-8 and sets that option. `FileName`, `Directory` and
  the other name tags come back in the same encoding.
- **Line ends.** A command's stdout and stderr in the result are the
  bytes the command printed, with `\n` line ends on every platform:
  exiftool's text-mode translation to CR LF on Windows belongs to a
  stream of the process, and a session writes to no stream. `binmode`
  in a session (`-b`) leaves the host's stdout as it is.
- **Threads** are the caller's (POSIX threads or Windows threads).

Build scripts: `capi/build-linux.sh`, `capi/build-macos.sh`,
`capi/build-windows.sh` (POSIX shell; on Windows Git Bash with the MSVC
environment), with the variants `rock`, `embedded` and `test` each; the
embedded libraries of all three are built on Linux, in the builder
containers of the standalone executables. The comment at the top of each
script lists its variants and settings.

## Build variants

- **rock**: only `capi/lexiftool.c`; the Lua modules and C modules come
  from `package.path`/`package.cpath` (the installed rocks and
  `build/5.5/lexiftool/sys.so`), Lua from the system's `liblua` 5.5. The
  options `lua_path`/`lua_cpath` set the paths, otherwise Lua's defaults
  (`LUA_PATH_5_5`, ...) apply. `capi/build-linux.sh rock` builds
  `liblexiftool.a`, `example` and the test programs into
  `capi/build/rock/`. The Lua is the system's (`-llua`) or the one named
  by `CAPI_LUA_INCDIR` and `CAPI_LUA_LIB`; a static `liblua.a` is linked
  whole and its symbols exported, since the C modules (shared objects)
  take the Lua API from the program. `capi/build-macos.sh rock` does the
  same on a Mac (`cc`, the Lua that luarocks is configured for, a static
  one with `-force_load`), `capi/build-windows.sh rock` on Windows with
  MSVC's `cl` against the Lua DLL of luarocks' configuration
  (`LUA_LIBDIR`, `LUALIB`); there the C modules are DLLs linked against
  the same Lua DLL.
  `make capi-shared` builds the same variant as a shared library for a
  system-wide installation: `build/<ver>/capi/liblexiftool.so.<API>`
  (soname `liblexiftool.so.<API>`, `lexiftool_*` exported only), linked
  against the system's `liblua` of `LUA_VERSION` (default 5.5, found
  through pkg-config), with a `lexiftool.pc` for `PREFIX` and `LIBDIR`
  (`Requires.private: lua`), and `make install` puts both, the header,
  the launcher and the Lua modules into `DESTDIR/PREFIX`
  ([install.md](install.md)). A program
  linked against it needs the rocks and the lexiftool modules installed
  for that Lua, as the launcher does (the modules as bytecode, so a
  session's first `require`s parse nothing); unlike the development
  build it does not read the module paths from the environment (see
  [Module paths](#module-paths)).
- **embedded** (as the standalone executable): all Lua modules and C
  modules and their libraries (Lua 5.5, PCRE2, zlib, brotli, zstd,
  liblzma, libbz2) inside the library. Nothing is loaded from the file
  system, and `lua_path`/`lua_cpath` have no effect. The library needs
  only the C library: on Linux glibc 2.17 or newer (x86-64: `libc`,
  `libm`, `libpthread`), on macOS `libSystem`, on Windows `KERNEL32.dll`
  and `msvcrt.dll`.

### Module paths

How a session's Lua state gets `package.path`/`package.cpath`:

| Build                                   | Environment (`LUA_PATH`, `LUA_CPATH`, `_5_5` forms) | Paths |
|-----------------------------------------|------------|-------|
| embedded (`capi-linux`, ...; also the standalone executable) | ignored | empty: only the linked and embedded modules (`package.preload` and the embedded searcher) |
| installed (`make capi-shared`, `make install`) | ignored | `PREFIX/share/lua/<ver>/`, `LIBDIR/lua/<ver>/` (and `LUA_ROCKS_TREE`'s), then Lua's built-in default |
| development "rock" (`capi/build-*.sh rock`) | read, as by `lua` | Lua's defaults, i.e. `LUA_PATH_5_5`/`LUA_PATH`, ... |

"Ignored" means that the library sets the registry field `LUA_NOENV`
before it opens the standard libraries, as `lua -E` does; Lua's
`package` library then does not read those variables. (`LUA_INIT` is
never run by a library.) In the embedded build `package.path` and
`package.cpath` are then emptied (`lx_setup` in `standalone/main.c`): a
module that is not inside fails to load with Lua's `module '...' not
found` instead of being taken from the file system, and the options
`lua_path`/`lua_cpath` have no effect. In the installed build the
options replace the paths when given, as in the development build. The
installed build's directories are compiled in (`-DLEXIFTOOL_PREFIX`,
`-DLEXIFTOOL_LIBDIR`, optionally `-DLEXIFTOOL_ROCKS_TREE`, from the
Makefile's `PREFIX`, `LIBDIR` and `LUA_ROCKS_TREE`); they are the paths at
run time, without `DESTDIR`, the same the installed launcher has.

### Building the embedded libraries

`make capi-linux` (podman) builds them in the Linux builder container of
the standalone executable (`make image-linux`) and writes into
`capi/build/embedded/`:

```
include/lexiftool.h
lib/liblexiftool.a           static
lib/liblexiftool.so.3        shared; soname liblexiftool.so.3
lib/liblexiftool.so          -> liblexiftool.so.3
lib/pkgconfig/lexiftool.pc
bin/                         example and the tests, linked against both
```

The number in the soname is `LEXIFTOOL_API_VERSION`: it changes exactly
when the API changes incompatibly.

On macOS, `make capi-macos` builds them in the macOS builder container
(zig cc, `make image-macos`), both architectures joined into universal
files, in `capi/build/macos/`:

```
include/lexiftool.h
lib/liblexiftool.a           static, universal
lib/liblexiftool.3.dylib     shared, universal; install name
                             @rpath/liblexiftool.3.dylib
lib/liblexiftool.dylib       -> liblexiftool.3.dylib
lib/pkgconfig/lexiftool.pc
bin/                         example and the tests, universal, linked
                             against both (NAME, NAME-so)
```

The arm64 slice of the dylib is signed ad hoc by the linker, as macOS
requires. The programs run on a Mac only (`capi/build-macos.sh test`).

On Windows, `make capi-windows` builds them with mingw-w64 in the Windows
builder container (`make image-windows`), in `capi/build/windows/`:

```
include/lexiftool.h
bin/lexiftool.dll            shared; exports lexiftool_* only
lib/liblexiftool.dll.a       its import library for MinGW
lib/lexiftool.lib            its import library for MSVC
lib/lexiftool.def            the exports
lib/liblexiftool.a           static, MinGW only
lib/pkgconfig/lexiftool.pc
bin/                         example and the tests, linked against the
                             static library (NAME.exe) and the DLL
                             (NAME-dll.exe)
```

The DLL and the programs import only `KERNEL32.dll` and `msvcrt.dll`.
The static library is for MinGW only; an MSVC program uses the DLL.

`make capi-install` copies `include/` and `lib/` to `$(DESTDIR)$(PREFIX)`
(`PREFIX` defaults to `/usr/local`) and writes `PREFIX` into the
installed `lexiftool.pc`. The `lexiftool.pc` in the build tree finds its
directory itself (`${pcfiledir}`), so the build tree can be used in place
or moved as a whole.

### Linking

Through pkg-config (`PKG_CONFIG_PATH` = the `lib/pkgconfig` directory,
unless installed where pkg-config looks):

```sh
# shared
cc app.c $(pkg-config --cflags --libs lexiftool)
# static: the archive, although the shared library is next to it
cc app.c $(pkg-config --cflags lexiftool) \
   $(pkg-config --static --libs lexiftool | sed 's/-llexiftool/-Wl,-Bstatic -llexiftool -Wl,-Bdynamic/')
```

On macOS the linker prefers the dylib for `-llexiftool`; for the static
library name the archive itself (`<prefix>/lib/liblexiftool.a`). A
program that uses the dylib from a directory of its own sets an rpath
(`-Wl,-rpath,@loader_path/...`).

On Windows a program that uses the DLL includes `lexiftool.h` as it is
(`LEXIFTOOL_API` is then `__declspec(dllimport)`) and links
`lexiftool.lib` (MSVC) or `liblexiftool.dll.a` (MinGW, `-llexiftool.dll`);
`lexiftool.dll` goes next to the program. One that links the static
library defines `LEXIFTOOL_STATIC` before the header
(`pkg-config --static --cflags lexiftool` adds `-DLEXIFTOOL_STATIC`).

`Libs.private` is `-lm -lpthread` on Linux (everything else is inside the
archive); `pkg-config --static --libs lexiftool` gives the full list for a
link with `-static`. Without pkg-config: `-I<prefix>/include` and
`<prefix>/lib/liblexiftool.a -lm -lpthread`, or `-L<prefix>/lib
-llexiftool` for the shared library (with an rpath or `LD_LIBRARY_PATH` if
it is not in a system directory).

### Symbol visibility

The embedded libraries define only the `lexiftool_*` functions of the
header as global symbols, and the shared ones export nothing else. Lua,
PCRE2, zlib, brotli, zstd, liblzma, libbz2 and the Lua C modules inside
are hidden, so a program can link its own Lua (of any version), zlib,
PCRE2, ... next to lexiftool, statically or dynamically: the two copies
never mix. The library's undefined symbols are those of the C library
only. In the static MinGW library the inner symbols stay global but carry
the prefix `lxint_`, which keeps them apart from a program's own.

## Tests

`make capi-test` (Linux) builds the rock variant and runs, against every
build there is (rock, rock with AddressSanitizer, and after
`make capi-linux` the embedded static and shared library): `test_capi`,
which covers every function and its edge cases; `test_threads`, in which
threads with a session and a time zone each must give the same output as
when run one after the other; `test_hostlibs` (embedded only), which runs
a session inside a program with its own Lua 5.4 and zlib; and the
comparison of `capi/example` with `capi/info_dump.pl`, which makes the
same calls through Perl's Image::ExifTool over `vendor/exiftool/t/images`
with several option sets and must print identical output.
`make capi-test-sideeffects` runs `test_sideeffects`, which checks that
the host's environment, locale, time zone, signals, working directory,
descriptors and standard streams are the same after many sessions as
before. `make capi-test-tsan` and `make capi-test-tsan-embedded` run
`test_threads` and `test_capi` under ThreadSanitizer, `make capi-test-wine`
the Windows programs under wine; on a Mac and on Windows the `test`
variant of `capi/build-macos.sh` and `capi/build-windows.sh` runs the
same programs and the Perl comparison (`CAPI_PERL` names the Perl).
`make capi-test-package` links `test_capi` and `example` against the Linux
release zip (`capi/build/dist/`) with the host's compiler and runs them;
`capi/test-package.sh ZIP` does the same on a Mac and on Windows (MSVC).
