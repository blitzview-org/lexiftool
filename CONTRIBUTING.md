# Contributing to lexiftool

lexiftool is a structural port: its value lies in staying line-for-line
comparable with the Perl original, so that every upstream ExifTool release
can be followed by reading the two side by side. The rules below serve that
goal. The full mapping rules are in [doc/conventions.md](doc/conventions.md),
the facade and API reference in [doc/api.md](doc/api.md).

## Structural parity

- The `lexiftool` namespace maps 1:1 onto `Image::ExifTool`
  (`Image::ExifTool::X` ↔ `lexiftool.X`, file base names preserved,
  `.pm` → `.lua`), with the same function and variable names and the same
  code order as the mapped upstream file.
- All calls of Perl built-ins go through the `perl` facade
  (`src/lexiftool/perl.lua`), which follows Perl's conventions (0-based
  indices and offsets, Perl truthiness, undef as nil). The Perl original
  decides per call site: if the corresponding Perl line contains the
  built-in (`substr`, `sprintf`, `unpack`, a regex, ...), the Lua line uses
  the facade, bound to a file-scope local alias so that both lines read the
  same; where the Lua code has no built-in behind it, plain Lua is right
  (doc/conventions.md §3a).
- A module is `require`d at another module's top level only where upstream
  has the corresponding `use`; otherwise it is loaded lazily, as upstream
  does (eager loading changes the order in which Composite tags are built;
  `tools/verify_requires_allowlist.lua`).
- Comments and formatting stay comparable to the original: header banners
  and table comments verbatim (`#` → `--`), the upstream `Revisions`,
  `References`, `Notes` and `Legal` sections copied, never extended;
  reference cites (`#3`, `#PH`, ...) preserved; one entry per line; columns
  aligned where the Perl aligns them; 4-space indentation everywhere
  (doc/conventions.md §10).
- Each ported file names its counterpart in the banner (`File:`,
  `Ported from:`) and records its scope and deviations under `Port notes:`,
  updated in the same change that extends or shrinks the ported subset.
- Module tables use the module name (`local DPX = {}` … `return DPX`),
  never a generic `M` (doc/conventions.md §1).

## Configuration

- The library invents no configuration of its own: no `os.getenv` for
  lexiftool's own settings, no working-directory assumptions, no
  `package.path` manipulation in library code. Only the launcher
  `lexiftool` sets up module paths (and reads the switch
  `LEXIFTOOL_BYTECODE=0`, which forces loading the sources).
- Where the Perl original itself touches `%ENV`, so does the port -- same
  variable, same call site, same direction (`perl.getenv`/`perl.setenv`):
  `Options('TimeZone')` writes `TZ`, the config-file lookup reads
  `EXIFTOOL_HOME`, `HOME`, `HOMEDRIVE` and `HOMEPATH`.
- Globals are read only via `_G.`, all-caps with the `LEXIFTOOL_` prefix:
  `_G.LEXIFTOOL_BACKEND` (facade backend override), `_G.LEXIFTOOL_PORT_VERSION`
  (the build's own version/identity, set by the launcher or build script,
  read by `lexiftool.lua`'s `_VERSION` field and `-ver -v`'s port line) and,
  in test code only, `_G.LEXIFTOOL_REPO_DIR` (repository root; otherwise
  `src/test/TestLib.lua` finds it by walking up to `vendor/exiftool/t`).
- The test runner gets its module paths from the Makefile (`LUA_PATH`,
  `LUA_CPATH`).

## Tests

- Expected output (`.out` files) and test images come solely from the
  vendored upstream repository (`vendor/exiftool/t/`); expected data is
  never invented. A test file in `src/test/` ports one upstream `t/*.t`
  file; deviations it has to make are named in its banner.
- Additional fixtures for code paths the upstream images do not reach live
  in `src/test/images/` with a `lex_` prefix (see the README there).

## Before submitting

```sh
make check        # C modules + tests (Lua 5.4 and 5.5) + luacheck + verify
```

`make verify` compares the port with the vendored original: tag tables
field by field (`verify_port`), `sub NAME` against Lua function names
(`verify_structure`), table procs (`verify_procs`), no raw `string.format`
where Perl has `sprintf` (`verify_sprintf`), no raw `table.sort` -- sort
through `perl.tsort`/`perl.sort` and compare strings with `perl.lt`/
`perl.cmp`, which order bytes like Perl whatever the locale (`verify_sort`)
-- no boolean test of a regex match whose first group may be unset
(`verify_matchbool`) -- and no `tostring()` whose argument may be a number
(`verify_tostring`): ported code stringifies with `perl.str`, which prints
like Perl (`%.15g`, always with `.`, undef as `''`); `tostring()` is left
for error objects (allowlisted in `tools/verify_tostring_allowlist.lua`)
-- and no Lua pattern class (`%a %l %u %w %s %p %c %g`, or a negation) in
the pattern of a `find`/`match`/`gmatch`/`gsub` call and no
`:lower()`/`:upper()`/`string.lower`/`string.upper` outside the facade
(`verify_ctype`): these follow the host's `LC_CTYPE`, so ported code
spells ASCII sets (`[ \t\n\r\f\v]`, `[A-Za-z0-9]`, ...) and changes case
through `perl.lc`/`perl.uc` (doc/conventions.md §3a).
It must stay green.

`make test` runs the suite under a locale with a decimal comma and a
collation of its own (the first of `de_DE.UTF-8`, `de_DE.utf8`, `de-DE`,
`German_Germany.1252` the C library accepts -- on Windows
`German_Germany.1252` first; `TEST_LOCALE=<name>` picks another,
`TEST_LOCALE=C` turns it off), so any formatting or sorting past the
`perl` facade fails there. `make test-locales` runs the suite under "C",
`de_DE.UTF-8` and the single-byte `de_DE` (ISO-8859-1, where Lua's
pattern classes and `string.lower`/`upper` take `0xE4` for a letter) in
turn; CI runs the latter on Linux, and Windows' cp1252 run covers it too. Test code builds its expectations the same
way (`perl.str`, `perl.sprintf`, `perl.tsort`). Where no such locale is
installed the runner warns and runs under "C" (with
`TEST_LOCALE_REQUIRED=1`, as in CI, it fails instead).

The facade's `localtime`/`gmtime` are compared with those of the Perl on
the same machine (`perl`, or `TEST_PERL=<path>`; without one these checks
are skipped, with `TEST_PERL` set a Perl that does not run fails them).
On Windows that has to be a native Perl such as Strawberry Perl
(`TEST_PERL=C:/Strawberry/perl/bin/perl.exe`, as in CI): the perl of Git
Bash is an msys build with a different `localtime` range.

A module counts as complete only when it satisfies
doc/conventions.md §11. Documentation changes go into the same commit as
the code they describe.
