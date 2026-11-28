# Standalone executables

Single-file `lexiftool` executables for a quick try without a Lua
installation, one per platform, built entirely on Linux with podman.
Platform requirements and the content of the release zips are described in
[README.md, "Standalone executables"](../README.md#standalone-executables).

| Target          | Output                          | Toolchain                    | Links at run time            |
|-----------------|---------------------------------|------------------------------|------------------------------|
| `make windows`  | `dist-windows/lexiftool.exe`    | mingw-w64 (Debian bookworm)  | KERNEL32.dll, msvcrt.dll     |
| `make macos`    | `dist-macos/lexiftool`          | zig cc, llvm-lipo            | libSystem only (x86_64+arm64)|
| `make linux`    | `dist-linux/lexiftool`          | zig cc (glibc 2.17 target)   | libc.so.6, libm.so.6, libpthread.so.0 |

Each target also writes the release zip next to the executable
(`lexiftool-<platform>-<version>.zip`): a folder named like the zip,
holding the executable, `LICENSE`, `LICENSE-THIRD-PARTY` and `licenses/`.
`<version>` is the bare tag on an exact, clean release (e.g. `v13.64.1`),
the full `git describe` identity otherwise.

Further targets (all in `Makefile.standalone`, included by the Makefile):
`make image-<platform>` (builder image only), `make smoke-linux`,
`make smoke-windows` (via wine), `make standalone-clean`,
`make standalone-clean-all` (also removes the images). The macOS binary
cannot run on Linux; the build checks it structurally (both slices, ad-hoc
code signature).

## Files

| File                  | Role                                                              |
|-----------------------|-------------------------------------------------------------------|
| `Dockerfile.<platform>` | builder image: toolchain, then `fetch.sh` and `deps.sh <platform>` |
| `fetch.sh`            | downloads all third-party sources, pinned by URL + SHA256 (the only place with versions) |
| `deps.sh`             | builds the static libraries and the native `lua55` and `zstd` into `/opt/lx`, collects the license texts |
| `build.sh`            | runs in the container on every build: embed, compile, link, zip   |
| `genembed.lua`        | writes `blob.bin` (the entries, each compressed on its own with `SA_COMPRESS=zstd`), the index `embedded_index.c` and `embedded_codec.h` |
| `main.c`, `embedded.h`, `blob.c` | the C host program                                     |
| `launcher.lua`        | main chunk: the counterpart of the `bin/lexiftool` launcher script |
| `check-licenses.sh`   | fails the build if a license text is missing from the zip         |
| `smoke.sh`            | smoke test of a built executable                                  |

Build products: `build/standalone/<platform>/` (intermediate),
`dist-<platform>/` (each with a `.gitignore` of its own).

## What is inside

Lua 5.5; the C modules (`lexiftool.sys`, `lpcre`, `carray`, `lfs`,
`digest`, `compress.*`, `cipher.aes`, `cipher.rc4`) with PCRE2, zlib,
Brotli, liblzma and libbz2, linked statically; all Lua modules of `src/` as
Lua 5.5 bytecode. Everything Lua-side is one blob in the executable, each
module loaded from it when first required (stored as is by default, so
without decoding; `SA_COMPRESS=zstd` compresses each entry on its own, see
"Build options"). Tracebacks name
the modules `<embedded>/lexiftool/X.lua`. How modules are found is
described in the banners of `main.c`, `launcher.lua` and `genembed.lua`;
versions are in `fetch.sh`.

The executable reads nothing from the file system to run and ignores the
Lua environment: `LUA_PATH`, `LUA_CPATH` and their `_5_5` forms are not
read (`main.c` sets `LUA_NOENV`, as `lua -E` does), `LUA_INIT` is never
run, and `package.path`/`package.cpath` are empty. A module that is not
inside fails with `module '...' not found`; a stray `lexiftool/*.lua` on
some `LUA_PATH` is never picked up. The embedded C API is set up the same
way ([doc/capi.md](../doc/capi.md#module-paths)).

## Build options

Variables of `Makefile.standalone`:

| Variable | Meaning |
|---|---|
| `SA_PODMAN` | container tool (default `podman`) |
| `SA_IMAGE` | name prefix of the builder images |
| `SA_STRIP_BYTECODE=1` | dump the bytecode without debug information (like `luac -s`; default 0 keeps line numbers in error messages) |
| `SA_COMPRESS` | codec of the embedded entries: `0` (uncompressed, default) or `zstd`. Uncompressed, a module is loaded straight from the mapped executable, without decoding and without a decode buffer (decoding cost 1-3 ms per run; the buffers, freed after each module, still doubled the peak memory of a run over many file types). The executable grows from about 7 to 17 MB, the zip by a few hundred KB |
| `SA_SOURCE_DATE_EPOCH` | time stamp for the PE header and the zip entries (default: last commit time) |
| `SA_IDENTITY` | the build's version identity (default: `git describe`) |

The build is reproducible: the same commit and the same builder image give a
byte-identical executable and zip.

## C API libraries

The same builder images build the C API's embedded libraries
(`make capi-linux`, `capi-macos`, `capi-windows`: `capi/build-<platform>.sh
embedded`) and their release zips (`make capi-package-<platform>`:
`capi/package.sh`, `capi/build/dist/lexiftool-capi-<platform>-<version>.zip`),
with the same toolchains, the same system requirements, the same
`<version>` and the same `licenses/` as the executables' zips, and just as
reproducibly. The CI builds them in the `standalone` job and publishes them
next to the executables; their content is described in
[doc/capi.md, "Getting the library"](../doc/capi.md#getting-the-library).

## Licenses

`deps.sh` collects one license text per built-in component from the same
source tarballs it builds from; they land in the zip's `licenses/` (of the
executables' and of the C API's zips), and `check-licenses.sh` fails the
build if one is missing.
