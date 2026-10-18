# Standalone executables

Single-file `lexiftool` executables for a quick try without a Lua
installation, built entirely on Linux with podman. They run on x86-64
Linux with glibc 2.17 or newer (not on musl systems such as Alpine), macOS
11 or newer (x86-64 and Apple Silicon) and Windows x64; everything but the
system libraries below is linked in:

| Target          | Output                          | Toolchain                    | Links at run time            |
|-----------------|---------------------------------|------------------------------|------------------------------|
| `make windows`  | `dist-windows/lexiftool.exe`    | mingw-w64 (Debian bookworm)  | KERNEL32.dll, msvcrt.dll     |
| `make macos`    | `dist-macos/lexiftool`          | zig cc 0.14.1, llvm-lipo     | libSystem only (x86_64+arm64)|
| `make linux`    | `dist-linux/lexiftool`          | zig cc 0.14.1, glibc 2.17    | libc.so.6, libm.so.6, libpthread.so.0 (glibc ≥ 2.17) |

Each target also writes the release zip next to the executable
(`lexiftool-windows-<version>.zip`, `lexiftool-macos-<version>.zip`,
`lexiftool-linux-<version>.zip`): a folder named like the zip without the
`.zip` extension, containing the executable, `LICENSE`,
`LICENSE-THIRD-PARTY` and `licenses/`. `<version>` is the bare tag on an exact, clean release
(`v13.59.1`), the full `git describe` identity otherwise.

Further targets (all in `Makefile.standalone`, included by the Makefile):
`make image-<platform>` (builder image only), `make smoke-linux`,
`make smoke-windows` (via wine), `make standalone-clean`,
`make standalone-clean-all` (also removes the images). The macOS binary
cannot run on Linux; the build checks it structurally (both slices, ad-hoc
code signature) and the `macos-smoke` job of the `ci` workflow runs it on a
macOS runner.

## Files

| File                  | Role                                                              |
|-----------------------|-------------------------------------------------------------------|
| `Dockerfile.<platform>` | builder image: toolchain, then `fetch.sh` and `deps.sh <platform>` |
| `fetch.sh`            | downloads all third-party sources, pinned by URL + SHA256 (the only place with versions) |
| `deps.sh`             | builds the static libraries and the native `lua55` and `zstd` into `/opt/lx`, collects the license texts |
| `build.sh`            | runs in the container on every build: embed, compile, link, zip   |
| `genembed.lua`        | writes `blob.bin` (every entry compressed on its own), the index `embedded_index.c` and `embedded_codec.h` |
| `main.c`, `embedded.h`, `blob.c` | the C host program                                     |
| `launcher.lua`        | main chunk: the counterpart of the `lexiftool` launcher script    |
| `check-licenses.sh`   | fails the build if a license text is missing from the zip         |
| `smoke.sh`            | smoke test of a built executable (`-ver -v`, `-j`, `-listgeo`, geolocation, `-stay_open`) |

Build products: `build/standalone/<platform>/` (intermediate),
`dist-<platform>/` (each with a `.gitignore` of its own).

## What is inside

- Lua 5.5.1, compiled without `LUA_USE_DLOPEN` (Unix: `LUA_USE_POSIX`, for
  `io.popen`, `mkstemp`, 64-bit `fseeko`).
- C modules, linked statically and put into `package.preload` by `main.c`:
  `lexiftool.sys` (`src/lexiftool/sys.c`, compiled from the project on
  every build), `lpcre`, `carray`, `lbrotli`, `lfs`, `digest`,
  `zlib` (lua-zlib), with PCRE2 10.47 (8-bit, Unicode, no JIT), zlib 1.3.2 and
  Brotli 1.2.0 (needed by `lbrotli` for JXL/WOFF2, not for the blob
  below); the zstd 1.5.7 decoder (built without compression, legacy
  formats and dictBuilder) for the embedded blob. Module versions: see
  `fetch.sh`.
- Lua modules: `src/lexiftool.lua` and `src/lexiftool/**.lua`, as Lua 5.5
  bytecode (dumped by the builder's native Lua 5.5.1). A searcher inserted right after the preload searcher finds them,
  so they win over anything on `package.path`. Chunk names are
  `@<embedded>/lexiftool/X.lua`, so tracebacks read
  `<embedded>/lexiftool/perl.lua:123:`.
- Data file: the source text of `lexiftool/QuickTime.lua` (WriteQuickTime's
  `ConditionUUID` reads a Condition's source back to get a UUID). The
  module opens it by path relative to its own chunk name
  (`<embedded>/lexiftool/QuickTime.lua`); `launcher.lua` wraps `io.open` to
  serve exactly the paths below `<embedded>/` from memory (read-only),
  everything else goes to the real `io.open`. `src/` is not changed for
  this. (The bundled Geolocation database used to be a second such data
  file, `Geolocation.dat`; it is now the ordinary module
  `lexiftool.GeolocationData` instead -- see `src/lexiftool/Geolocation.lua`'s
  Port notes for why. `-api GeoDir=...` and an `AltNames.dat` on disk keep
  working as with the launcher: that path is the caller's, not derived
  from a chunk name.)
- Everything is one blob (`blob.bin`, about 5 MB), placed in read-only
  data with the assembler's `.incbin` (`blob.c`): a C array initializer of
  that size would cost the compilers minutes and gigabytes. Each entry is
  compressed on its own (`genembed.lua`, with the native `zstd` tool the
  image builds from the same sources as the linked decoder;
  `SA_COMPRESS=zstd` (default) or `0`) and decoded by `main.c` only when
  it is used: a module on its `require`, a data file on its `io.open`.
  `genembed.lua` writes the codec into `embedded_codec.h`, which selects
  the decoder in `main.c`. See "Size" below.

The launcher chunk then does what the `lexiftool` script does:
`os.exit(require('lexiftool.main')(arg, { bytecode = true }))`. `arg[0]`
and `arg[-1]` are the executable.

## Size

Measured on Linux x86-64 (commit of 2026-10-18; Windows within 0.1 MB):

| Part (uncompressed)                          | MB    | zstd, per entry |
|----------------------------------------------|-------|-----------------|
| bytecode, 246 modules with debug info        | 14.77 | 5.39            |
| -- of which `GeolocationData` (bundled database) | 3.30 |             |
| -- of which `Lang/*` (18 translations)       |  1.99 |                 |
| -- maker-note modules (Nikon, Canon, Sony, ...) | 2.62 |              |
| -- `TagLookup`, `DICOM`, `QuickTime*`, `XMP*` | 2.23 |                 |
| `QuickTime.lua` source (for `ConditionUUID`) |  0.50 | 0.09            |
| C code and data (Lua 0.27; PCRE2 0.24; libc 0.11; zlib 0.06; the Lua C modules 0.05; the zstd decoder 0.12) | 1.6 | -- |

A run decodes only what it loads: `-ver` 0.57 MB of bytecode, `-j
Canon.jpg` 1.46 MB (13 modules), `-lang` adds its one `Lang/*` module,
`GeolocationData` only `-listgeo` and `-api geolocation`.

|                                   | executable | zip     | `-ver` | `-j Canon.jpg` | `-j DNG.dng` |
|-----------------------------------|------------|---------|--------|----------------|--------------|
| uncompressed (`SA_COMPRESS=0`)    | 16.98 MB   | 6.85 MB | 3.8 ms | 17.1 ms        | 22.5 ms      |
| **each entry zstd --ultra -22 (default)** | **7.31 MB** | **6.29 MB** | 5.0 ms | 19.9 ms | 25.9 ms |

(Linux x86-64, 2026-10-17. CPU time = user + system of the process,
minimum of 20 runs, the variants interleaved; load average 3.4 before and
after, below the limit of 4 of `docs/performance.md` §13. Windows:
7.25 / 16.90 MB executable, 6.25 / 6.80 MB zip for zstd / uncompressed.)
The cost over the uncompressed build is the decoding: zstd +1.3 / +2.8 /
+3.4 ms (about 2.5 ms per MB, 24.8 million instructions). The whole blob
would cost every run some 60 ms and 30 MB of memory, so the entries are
compressed one by one. Peak memory (RSS) is the same for both builds,
within 0.2 MB (8.5 MB compressed, 9.4 MB uncompressed): a decoded module
is freed as soon as Lua has loaded it, and the compressed blob pages a
run touches are fewer than the uncompressed ones.

(Brotli was measured and used as the default through 2026-10-17 -- each
entry brotli -q 11 gave 6.75 MB executable / 5.81 MB zip but cost +3.4 /
+7.7 / +8.7 ms per run, about 6 ms per MB of bytecode; the project then
settled on zstd only, to keep one blob codec, and dropped the native
`brotli` command-line tool and the `SA_COMPRESS=brotli` option -- the
Brotli *library* stays linked, `lbrotli` still needs it for JXL/WOFF2.)

zstd variants tried, none of them changing the picture: `-19` instead of
`--ultra -22` (0.8 KB larger, same speed), the decoder at `-O3` instead of
`-O2`, one decoding context reused instead of one per entry (both within
the noise, under 0.3 ms), a trained dictionary (110-150 KB) shared by all
entries (100 KB smaller in total).

`-api geolocation` takes some 50 ms longer (300 ms before). Leaving the
bundled database out (deleting `src/lexiftool/GeolocationData.lua` before
the build) would save another ~1.8 MB compressed, but `-listgeo` and the
Geolocation tags would fail ("No Geolocation database"), so it stays in.

### Bytecode with or without debug information

`SA_STRIP_BYTECODE=1` (e.g. `make linux SA_STRIP_BYTECODE=1`) dumps the
bytecode like `luac -s`; `Geolocation.lua` and `QuickTime.lua` keep their
debug information regardless, because they need their chunk name at run
time. With zstd compression the difference shrinks to 0.38 MB (executable
6.93 MB, zip 5.91 MB) and about 2-4 ms per run.

Decision: keep the debug information. Those are not worth losing line
numbers in error messages from people trying the executables out.

## Reproducibility

The Makefile passes `SOURCE_DATE_EPOCH` (last commit time): it goes into
the PE timestamp and the zip entry times; ELF and Mach-O carry no wall
clock. `genembed.lua` sorts its entries, the zip is written with fixed
modes, sorted entries and `zip -X`. Same commit + same builder image =
byte-identical executable and zip; the workflow builds twice in separate
containers and compares the SHA256.

## Pitfalls

- zig cc compiles only the first file of a multi-file `-c` call: every
  source is compiled on its own (`deps.sh`).
- zig cc ignores host include directories: all headers via `-I`.
- GNU ar cannot index Mach-O objects: `llvm-ar-14` for macOS.
- Apple Silicon kills unsigned arm64 binaries: lld signs ad hoc; `build.sh`
  checks `LC_CODE_SIGNATURE`.
- mingw-w64 with msvcrt.dll has no `timespec_get` (UCRT only): C code for
  the Windows build must use Win32 or msvcrt functions.
- The native Lua build in `deps.sh` must run before the cross passes (same
  object directory) and needs `gcc` + `libc6-dev` in the image.
