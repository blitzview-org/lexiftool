# Differences from exiftool

lexiftool runs the same command lines as `exiftool` 13.59 and gives the same
output (checked byte for byte against the Perl original, over its test
images and a corpus of camera sample images). Where it cannot, because the
original runs Perl code that the user supplies, it says so instead of
failing silently.

## Config files (`-config`, `.ExifTool_config`)

- An exiftool config file is Perl code; lexiftool does not run it. lexiftool
  has a config file of its own, written in Lua, that covers the same data:
  user-defined tags (EXIF, GPS, IPTC, XMP with new namespaces and
  structures, PNG, MIE, Composite, ...), Shortcuts, Options, Lenses,
  FileTypes and Arguments. Format, lookup and how to translate a Perl config
  file are in [configuration.md](configuration.md).
- The file is looked up as exiftool does: `-config FILE`, or the default in
  `$EXIFTOOL_HOME`, else `$HOME`, else `$HOMEDRIVE$HOMEPATH`, else the
  current directory, then the directory of the `lexiftool` script. The
  default is `.lexiftool_config` where one exists in those places, else
  `.ExifTool_config`.
- A config file is loaded as Lua when its name ends in `.lua`, when it is a
  `.lexiftool_config`, or when its first line starts with
  `-- lexiftool config`. Any other config file is taken for Perl: lexiftool
  warns on stderr `Config file not supported by lexiftool (Perl code): FILE`
  and runs on without configuration, as with `-config ""`. A piped config
  (`-config -`) is treated the same way.
- An error in a Lua config file is warned as Lua reports it, with file and
  line (`FILE:3: unexpected symbol near <eof>`), where exiftool warns Perl's
  message; the command then runs on without that file's configuration.
- A `-config FILE` that does not exist gives exiftool's own
  `Config file not found`. `-config ""` disables the lookup, as in exiftool.
- A conversion (`ValueConv`, `PrintConv`, ...) given as a Perl expression
  string runs through the same Perl subset as `-if` (below); anything else is
  written as a Lua function.
- `xmpStruct` (structures by name, kept upstream for backward compatibility
  only) is not supported; a structure is defined in place.

## Perl expressions (`-if`, `${TAG;EXPR}`, `-p`, `-tagsFromFile`, fmt files)

- exiftool evaluates these as Perl code. lexiftool interprets a subset of
  Perl (`perl.eval` in `src/lexiftool/perl.lua`) that covers every example
  in the exiftool documentation and the shipped fmt files, plus common
  constructs:
  - scalars `$x`, hash elements `$info{'Make'}`, arrays `@a` and `$a[0]`,
    captures `$1`..`$N`, `my` variables, strings `'...'`, `"..."` (with
    interpolation), `q()`, `qq()`
  - all arithmetic, string, comparison, logical, bitwise and assignment
    operators (`.=`, `+=`, `||=`, ...), `++`/`--`, `?:`, `=~`/`!~` with
    `m//`, `s///` and `tr///`/`y///` (not `s///e` or `s///r`)
  - statements with `if`/`unless` modifiers, blocks
    `if (...) {...} elsif (...) {...} else {...}`, `unless (...) {...}`
  - builtins `defined length lc uc lcfirst ucfirst int abs ord chr hex oct
    sqrt exp log scalar substr index rindex sprintf join split push unshift`
  - method calls on the ExifTool object: `$self->GetValue('FileName')`,
    `$self->Options('ExtractEmbedded')`
  - exiftool's helper functions `DateFmt`, `ShiftTime`, `NoDups`,
    `SetTags`, and `End`/`EndDir` in `-if`
- Not supported: loops (`for`, `foreach`, `while`), `sub`, `sort`, `map`,
  `grep`, `keys`, `local`, references and nested data structures,
  `$hash{$expr}` with a computed key, regex objects (`qr//`), `s///e`,
  file and system functions, `print`. Valid Perl outside the subset gives
  `Perl syntax unsupported in lexiftool: WHAT (near "...")` -- as a
  warning for `${TAG;EXPR}` (the value stays as it was, like a failed
  expression in exiftool), and for `-if` as
  `Condition: Perl syntax unsupported in lexiftool: ...` even without `-v`
  (exiftool reports a failing condition only with `-v`); the file then fails
  the condition.
- A genuine syntax error is reported like Perl's (`syntax error ...`).

## Regular expressions given as options

- lexiftool's regular expressions are PCRE2's. An expression that does not
  compile -- the API option `NoWarning` is checked when it is set -- is
  reported with PCRE2's reason and the pattern marked where PCRE2 stopped
  (`NoWarning: missing closing parenthesis in regex; marked by <-- HERE in
  m/( <-- HERE /`), where exiftool gives Perl's (`Unmatched ( in regex; ...`).

## `-ver -v`

- `-ver` prints `13.59`, as exiftool.
- `-ver -v` prints `Perl version` as the Lua version, adds a line
  `lexiftool port IDENTITY, Lua 5.5.0, bytecode yes|no` (IDENTITY a
  `git describe`, e.g. `v13.59.2-3-gabc1234`, baked in by the build; or
  `Unknown` for a source checkout or a rock install without that build
  step), and lists for each
  optional Perl module the Lua counterpart lexiftool uses in its place
  (`lua-zlib (zlib 1.3.2)` for Compress::Zlib, `digest 0.0.1` for
  Digest::MD5 and Digest::SHA (`digest scm` for a build from its scm
  rockspec),
  `lbrotli (libbrotli 1.2.0)` for IO::Compress/Uncompress::Brotli,
  `lexiftool.sys (statx)` for File::StatX on Linux, the built-in facade
  for Time::Piece and Time::Local, ...), or `(not installed)` where there
  is none (IO::Compress::Bzip2, Unicode::LineBreak, Compress::Raw::Lzma).

## Windows file names and times

- lexiftool handles Windows file names natively through the wide API
  (`CreateFileW`, `MoveFileExW`, `DeleteFileW`, `CreateDirectoryW`,
  `GetFileAttributesW`, `GetFullPathNameW` in `lexiftool.sys`), so opening
  files, reading and writing, renaming, deleting and creating directories all
  work with names outside the ANSI code page. Files are opened with
  `CreateFileW` and the same access and sharing flags exiftool uses, and the
  file times are read and set with `GetFileTime`/`SetFileTime` on the open
  file, exiftool's workaround for the daylight saving time error of the C
  runtime's `stat`. The Perl original needs
  `Win32::API` and `Win32API::File` for this; where those are missing it
  falls back to ANSI names. `WindowsLongPath` is therefore on by default
  here, and `-preserve` keeps `FileCreateDate` (exiftool does both only when
  the two Perl modules are installed).
- Wildcards in file names are expanded by the shell on Unix, so they need no
  code there. On Windows the shell does not expand them, so lexiftool does it
  itself, as exiftool does: `perl.bsd_glob` stands in for `File::Glob` and
  `FindFileWindows` (main.lua) for `Win32::FindFile`, both native, so a
  wildcard argument works without an extra module. Directory listings there
  go through `lexiftool.sys.read_dir` (wide `FindFirstFileW`/`FindNextFileW`,
  what `Win32::FindFile::ReadDir` does), so Unicode names in directories are
  read as UTF-8 without the Perl module upstream would need.

## Date formatting (`-d`, `DateFormat`)

- The format goes to the C library's own `strftime`, as exiftool's
  `POSIX::strftime` does, in the `LC_TIME` locale Perl takes from the
  environment (`LC_ALL`, `LC_TIME`, `LANG`), so the conversions the platform
  knows -- and the ones it rejects -- behave as in exiftool there. Perl
  sets that locale for the whole process at startup; lexiftool only reads
  the environment and loads the locale into an object of its own, which
  its `strftime` (and `Time::Piece`'s `use_locale`, for reading localized
  dates back) formats with, and never sets the process locale -- the
  result is the same. One exception: the static C library
  `liblexiftool.a` links musl, which has no locale data of its own and
  cannot read glibc's, so name conversions (`%a %A %b %B %p %c %x`) give
  English names there; the command-line tool, the standalone executable
  (dynamic against glibc) and `liblexiftool.so` use the system's locale
  data like Perl. lexiftool
  follows `POSIX::strftime` of Perl 5.42.1 and later: the date is normalized
  by `mktime` with daylight saving time left to the C library, so a local
  time that does not exist (inside the spring-forward gap) moves on by the
  gap (`02:30` becomes `03:30`). Perl 5.42.0 and some older versions keep
  such a time as given.

## Numbers, sorting and the host locale

- exiftool prints numbers with `.` as the decimal point: Perl keeps
  `LC_NUMERIC` at "C" outside `use locale`, which exiftool never uses.
  lexiftool does the same whatever the process's global C locale is, which
  matters where it is embedded (C API, a Lua host) and the host has set,
  say, `de_DE` (where C's own formatting gives `1,5`). It does so without
  touching any locale state: the `perl` facade reads the decimal point the
  C library currently uses (`localeconv`) and replaces it with `.` in the
  numbers it formats (`perl.str`, the float conversions of `perl.sprintf`).
  The decimal point is read when the library loads, by `ExifTool.new` and,
  in the C API, before every command; a Lua host that switches its locale
  between two calls on the same `ExifTool` object without one of those
  formats with the old one. The command-line tool never sets a locale.
- exiftool sorts and compares strings as unsigned bytes: Perl's `sort`,
  `cmp`, `lt`/`gt` ignore the locale outside `use locale`. Lua's `<` on two
  strings goes through `strcoll`, i.e. the host's `LC_COLLATE` (`de_DE`
  sorts `a A ä b B z`, Perl `A B a b z ä`). lexiftool sorts and compares
  bytewise like Perl whatever `LC_COLLATE` is -- tag orders (`-sort`,
  `-G` grouping), sorted key lists and the few string comparisons of the
  original (firmware versions, MIE tag order, ...) -- again only reading
  the locale: under "C"/"POSIX" `strcoll` already is `strcmp` and Lua's
  own `<` is used; under any other collation the facade compares through
  the C module (`sys.strless`/`sys.strcmp`). Like the decimal point, the
  collation is read when the library loads, by `ExifTool.new` and, in the
  C API, before every command.
- exiftool treats a byte string's characters as ASCII: Perl's `\s`, `\w`
  and `lc`/`uc` ignore `LC_CTYPE` outside `use locale`. Lua's pattern
  classes (`%a`, `%s`, `%w`, ...) and `string.lower`/`upper` follow it, and
  under a single-byte locale (Windows cp1252, glibc's `de_DE` ISO-8859-1)
  they take `0xE4` for a letter and lower `0xC4` to `0xE4` -- which would
  change UTF-8 text such as place names. lexiftool's own patterns spell
  their classes as ASCII sets and change case only through the `perl`
  facade (`perl.lc`/`perl.uc`, ASCII-only like Perl), so the result is the
  same under any locale; the regex facade (PCRE2) uses PCRE2's built-in
  character tables and is not affected. The facade itself, the expression
  parser and the Geolocation lookups are covered by the unit tests under
  such a locale.
- Remaining difference under such a locale: Lua's own number parsing
  (`tonumber`) also accepts `1,5` there, where Perl reads `1`. The port
  stringifies numbers only through the facade (`perl.str`, `perl.sprintf`,
  and the regex functions for a number subject); `tools/verify_tostring.lua`
  rejects a `tostring()` that may see a number, and the unit tests run
  under a `de_DE` locale.

## `-k` without a console (Windows)

- When standard input is no console, `Term::ReadKey` fails and the
  message ends exiftool as an uncaught `die`; lexiftool prints the same
  `GetConsoleMode failed, LastError=|6|` text, but two details of it differ.
  The place it names is lexiftool's (`.../lexiftool/perl.lua line N`, the
  line that calls into the console) where Perl names
  `.../Term/ReadKey.pm line 346`, the corresponding line of the Perl
  module. And the exit status is 255 where exiftool's is usually 2: an
  uncaught `die` exits with `$!` when it is set, and exiftool's `$!` at that
  moment is the `ENOENT` its `require Term::ReadKey` left behind while it
  searched `@INC` (exiftool's own `lib` directory comes first and never
  holds that module) -- a leftover of an unrelated earlier step. lexiftool
  has `Term::ReadKey` built in, so nothing is searched, and Lua's own file
  reads and writes clear `errno`, so it exits with 255, the status of a
  `die` without `$!`.

## Starting `lexiftool`

- The `lexiftool` launcher sets its own module paths for the Lua version it
  runs on: it ignores entries of another Lua version's rock tree (as an
  unversioned `LUA_PATH`/`LUA_CPATH` set up for Lua 5.1 brings in) and adds
  `~/.luarocks`, `/usr/local` and `/usr` for its own version. A versioned
  `LUA_PATH_5_5`/`LUA_CPATH_5_5` still takes precedence.
- When the script has a source tree next to it (`src/lexiftool/main.lua`),
  that tree is searched first, so `./lexiftool` in a checkout runs the
  checkout even if a lexiftool is also installed in a system or rock tree.
