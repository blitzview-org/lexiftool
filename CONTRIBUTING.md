# Contributing to lexiftool

lexiftool is a structural port: its value lies in staying line-for-line
comparable with the Perl original, so that every upstream ExifTool release
can be followed by reading the two side by side. The rules below serve that
goal. The full mapping rules are in [doc/conventions.md](doc/conventions.md),
the contract of the `perl` facade in [doc/perl-facade.md](doc/perl-facade.md).

## Structural parity

- The `lexiftool` namespace maps 1:1 onto `Image::ExifTool`, with the same
  file base names, function and variable names and code order, and module
  tables named after the module
  ([conventions §1, §2](doc/conventions.md#1-files)).
- All calls of Perl built-ins go through the `perl` facade; the Perl
  original decides per call site
  ([conventions §3a](doc/conventions.md#3a-facade-or-raw-lua-what-decides)).
- A module is `require`d at another module's top level only where upstream
  has the corresponding `use` ([conventions §1](doc/conventions.md#1-files)).
- Comments and formatting stay comparable to the original, banners and
  table comments verbatim, 4-space indentation; each ported file names its
  counterpart and records its scope under `Port notes:`, updated in the same
  change that extends or shrinks the ported subset
  ([conventions §10](doc/conventions.md#10-comments-and-formatting-fidelity)).

## Configuration

- The library invents no configuration of its own: no `os.getenv` for
  lexiftool's own settings, no working-directory assumptions, no
  `package.path` manipulation in library code. Only the launcher
  `lexiftool` sets up module paths (and reads the switch
  `LEXIFTOOL_BYTECODE=0`, which forces loading the sources).
- Where the Perl original itself reads `%ENV`, so does the port -- same
  variable, same call site (`perl.getenv`): the config-file lookup reads
  `EXIFTOOL_HOME`, `HOME`, `HOMEDRIVE` and `HOMEPATH`. The library writes no
  environment; the one place where upstream does (`Options('TimeZone')`)
  is a documented deviation
  ([differences.md](doc/differences.md#the-timezone-option--api-timezone)).
- Globals are read only via `_G.`, all-caps with the `LEXIFTOOL_` prefix:
  `_G.LEXIFTOOL_BACKEND`, `_G.LEXIFTOOL_PORT_VERSION` (the build's
  identity, set by the launcher or build script) and globals for test code
  only ([perl-facade.md §5](doc/perl-facade.md#5-backend-and-globals)).
- The test runner gets its module paths from the Makefile (`LUA_PATH`,
  `LUA_CPATH`).

## Tests

- Expected output (`.out` files) and test images come solely from the
  vendored upstream repository (`vendor/exiftool/t/`); expected data is
  never invented. A test file in `src/test/` ports one upstream `t/*.t`
  file; deviations it has to make are named in its banner.
- Additional fixtures for code paths the upstream images do not reach live
  in `src/test/images/` with a `lex_` prefix (see the README there).
- `make test` runs the suite under a locale with a decimal comma and a
  collation of its own (the first of `de_DE.UTF-8`, `de_DE.utf8`, `de-DE`,
  `German_Germany.1252` the C library accepts), so any formatting or
  sorting past the facade fails; test code builds its expectations through
  the facade too (`perl.str`, `perl.sprintf`, `perl.tsort`).
  `TEST_LOCALE=<name>` picks another locale, `TEST_LOCALE=C` turns it off;
  without such a locale the runner warns and runs under "C", with
  `TEST_LOCALE_REQUIRED=1` (as in CI) it fails. `make test-locales` runs
  the suite under "C", `de_DE.UTF-8` and the single-byte `de_DE`
  (ISO-8859-1) in turn; CI runs the single-byte case on Linux, and on
  Windows under cp1252.
- The facade's `localtime`/`gmtime` are compared with those of a Perl on
  the same machine (`perl`, or `TEST_PERL=<path>`; skipped without one). On
  Windows that has to be a native Perl such as Strawberry Perl, as in CI.

## Help text

`lexiftool --help` prints the original's documentation, generated rather
than maintained by hand: `tools/usage_rules.lua` is the only place where the
deviations are defined (tool and library names, a preamble naming the port,
a copyright note, no `SEE ALSO`), and `make usage` (`tools/gen_usage.lua`)
regenerates `src/lexiftool/usage.lua` from the vendored exiftool's help.
`src/test/test_usage.lua` checks that the generated file is current and
that `lexiftool --help` prints exactly it.

## Adding or renaming a module

The rockspecs in `rockspecs/` list every Lua module explicitly; after
adding, removing or renaming a module, `lua rockspecs/update_modules.lua`
regenerates those lists.

## Before submitting

```sh
make check        # C modules + tests (Lua 5.4 and 5.5) + luacheck
```

The port follows the vendored original structurally; the maintainers check
these rules on every change:

- Tag tables and banners match the Perl original field by field.
- Every `sub NAME` has its Lua function; no eager `require` where upstream
  has no `use`.
- Per module, element order and function signatures follow Perl; every
  deviation is recorded with its reason.
- A table's `PROCESS_PROC`/`WRITE_PROC`/`CHECK_PROC` matches the original.
- No raw `string.format` where Perl has `sprintf`.
- No raw `table.sort` (`perl.tsort`/`perl.sort`, `perl.lt`/`perl.cmp`).
- No boolean test of a match whose first group may be unset, no unsafe
  patterns in `findAll`/`split`/`eachMatch`.
- No `tostring()` on a value that may be a number (`perl.str`).
- No locale-dependent Lua pattern class or `lower`/`upper` outside the
  facade.
- No writable static variable in the C modules
  ([conventions §12](doc/conventions.md#12-c-modules-no-writable-static-state)).

The reasons behind these rules are in [doc/conventions.md](doc/conventions.md).

A module counts as complete only when it satisfies
[conventions §11](doc/conventions.md#11-definition-of-done-for-a-module).
Documentation changes go into the same commit as the code they describe.
