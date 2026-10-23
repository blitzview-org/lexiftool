# Differences from exiftool

lexiftool runs the same command lines as `exiftool` 13.59 and gives the same
output (checked byte for byte against the Perl original, over its test
images and a corpus of camera sample images). Where it cannot, because the
original runs Perl code that the user supplies, it says so instead of
failing silently.

## Config files (`-config`, `.ExifTool_config`)

- An exiftool config file is Perl code; lexiftool does not run it. It reads
  a Perl config file as data when the file only assigns package variables
  with literal values (hashes, lists, strings, numbers, references, `use`/
  `require` of ExifTool modules, element assignments, `RegisterNamespace`;
  the full list is in [configuration.md](configuration.md#perl-config-files)),
  which most real config files do. A file with other Perl (`sub`, `my`,
  `if`, loops, other calls, interpolation, ...) is not used at all: lexiftool
  warns `Config file not supported by lexiftool (Perl code at line N:
  CONSTRUCT): FILE` and runs on without it, where exiftool would run the code.
  The same goes for a piped config (`-config -`). For such files lexiftool
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
  `-- lexiftool config`. Any other config file is taken for Perl.
- A Perl config file that is not valid Perl is rejected with the message
  above (naming the line where the parser stops), not with Perl's syntax
  error. A file whose last statement is false warns `FILE did not return a
  true value`, without the location in ExifTool.pm that Perl adds.
- In a Perl config file, `undef` as a hash value leaves the key out, so an
  option set to `undef` in `%Image::ExifTool::UserDefined::Options` keeps
  its default instead of becoming undefined.
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

## Perl expressions (`-if`, `${TAG;EXPR}`, `-p`, `-tagsFromFile`, fmt files, `-api GeoHPosErr`)

- exiftool evaluates these as Perl code. lexiftool interprets a subset of
  Perl (`perl.eval` in `src/lexiftool/perl.lua`) that covers every example
  in the exiftool documentation and the shipped fmt files, the expressions
  of the CLI test's expression corpus (doc/cli-tests.md), the conversion
  code of the bundled config files, plus common constructs:
  - scalars `$x`, arrays `@a`, `$a[0]`, `$a[$i]`, `$#a`, hashes `%h`,
    `$info{'Make'}`, `$h{$key}`, slices `@a[1, 2]`, `@h{'a', 'b'}`, list
    slices `(LIST)[0]`, `(split / /)[-1]`, captures `$1`..`$N` and `$&`,
    `my` variables (`my ($x, @a, %h)`), strings `'...'`, `"..."` (with the
    case modifiers `\u \l \U \L \Q \E`, interpolating variables, elements
    and longer expressions such as `"$h{a}{b} $r->[0] @$r $#a"`), `q()`,
    `qq()`, `qw()`
  - references: `\$x`, `\@a`, `\%h`, `\$h{key}`, anonymous arrays `[...]`
    and hashes `{...}`, the dereferences `$$r`, `@$r`, `%$r`, `${...}`,
    `@{...}`, `%{...}`, `$$r[0]`, `$r->[0]`, `$r->{key}` and chains such as
    `$val[0]{RegionList}[1]{Name}` (the arrow is optional between
    subscripts), with Perl's autovivification and the errors of
    `use strict` (`Can't use an undefined value as an ARRAY reference`,
    `Not a HASH reference`, `Can't use string ("abc") as a HASH ref`);
    `ref`. A reference prints as Perl's does (`ARRAY(0x...)`); what the code
    returns or passes to a function is a Lua table again
  - all arithmetic, string, comparison, logical, bitwise and assignment
    operators (`.=`, `+=`, `||=`, ...), `++`/`--`, `?:`, the range `1..5`
    and `'a'..'e'` and the list repetition `(0) x 5` in list context,
    `=~`/`!~` with `m//`, `s///` (also `s///r` and `s///e`) and
    `tr///`/`y///`; patterns interpolate variables like strings
    (`$Model =~ /$Make/i`, `s/$x/y/`, `split /$sep/`)
  - statements with `if`/`unless`/`for`/`foreach`/`while`/`until`
    modifiers, blocks `if (...) {...} elsif (...) {...} else {...}`,
    `unless (...) {...}`, `do {...} while ...`, and the loops
    `for my $x (LIST) {...}` (the loop variable is an alias of each element,
    as `$_` is in `map`, `grep` and `s/// for @list`), `for (INIT; COND;
    STEP) {...}`, `while (...) {...}` and `until (...) {...}` with `next`
    and `last` (also with a label), and `return`, whose value is the value
    of the expression
  - builtins `defined length lc uc lcfirst ucfirst int abs ord chr hex oct
    sqrt exp log sin cos atan2 ref quotemeta scalar substr index rindex
    sprintf join split push unshift shift pop splice reverse rand srand
    time localtime gmtime pack unpack chomp chop exists delete die warn
    keys values each`, `sort` with or without a block
    (`sort { $a <=> $b } ...`), `map` and `grep` (`map { ... } LIST`,
    `grep /re/, LIST`); `rand` is Perl's own generator, so after
    `srand(N)` it gives Perl's numbers
  - a capture variable before the expression's own first match: in
    `${TAG;EXPR}` it is, as in exiftool, that of the match that extracted
    the expression (`$1` is its text up to the first `}`)
  - method calls on the ExifTool object: `$self->GetValue('FileName')`,
    `$self->Options('ExtractEmbedded')`; a new one with
    `Image::ExifTool->new` or `new Image::ExifTool`
  - exiftool's helper functions `DateFmt`, `ShiftTime`, `NoDups`,
    `SetTags`, and `End`/`EndDir` in `-if`; the other Image::ExifTool
    functions by name or package-qualified (`ConvertFileSize($_)`,
    `Image::ExifTool::ConvertFileSize($_)`, `Image::ExifTool::GPS::ToDMS(...)`);
    `require Image::ExifTool::Geolocation` and
    `require 'Image/ExifTool/Shift.pl'` load the module, and the functions
    of a `.pl` file are found by name from then on, as in Perl
  - the warnings of `perl -w`: an undefined value or a string that is not a
    number used in an operator (`Use of uninitialized value $info{"Model"}
    in pattern match (m//)`, `Argument "Canon" isn't numeric in numeric ne
    (!=)`) -- as in exiftool, such a warning fails an `-if` condition and is
    reported for `${TAG;EXPR}`
  - Perl's compile-time warning for a statement whose value is unused
    (`$Model; $Make eq "Canon"` gives `Useless use of hash element in void
    context`, which fails the `-if` condition), with Perl's names for the
    operators and its constant folding (`"abc";` warns, `1;` and `0;` do
    not), and `Found = in conditional` and `Scalar value @a[1] better
    written as $a[1]`
- Not supported: `sub`, `local`, `our`, `eval`, `wantarray`, `redo`,
  `goto`, code references (`$x->()`), `@_` and `shift`/`pop` without an
  array, the flip-flop `..` in scalar context, references to a list
  (`\(@a)`), `delete` of a slice, `continue` blocks, regex objects
  (`qr//`), `s///ee`, `require` of a module that is not part of exiftool
  (it is Perl code), file and system functions, `print`. Perl's
  `use strict` check is not made: an undeclared variable (`$foo`) is
  undefined instead of the `use strict` error `Global symbol "$foo"
  requires explicit package name`. `keys`, `values` and `each` list a hash
  in string order (Perl's order is unpredictable). An undefined value
  stored in a hash element does not exist in a Lua table: the key is
  absent (`exists` is false, and a structure the code builds lacks the
  field, where exiftool shows it empty); in an array it is a hole that
  still counts for the length. An empty pattern (`//`, or one that
  interpolates to nothing) matches the empty string instead of repeating
  the last successful pattern; in `-if`, `$1` before the condition's own
  first match is undefined. Valid Perl outside the subset gives
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
- An empty `NoWarning` (`-api NoWarning^=`) suppresses every warning. In
  Perl an empty pattern reuses the last successfully matched one, so what
  exiftool suppresses depends on the regex it happened to run before.

## Option values Perl warns about

- exiftool runs Perl with warnings on. An API option given an empty or
  undefined value where a number is expected (`-api Verbose^=`,
  `-api Unknown=`, `-api ListSep=`, ...) makes Perl's interpreter print
  `Argument "" isn't numeric in ...` or `Use of uninitialized value ...`,
  naming a line of its own source, on stderr -- and where the value is
  read inside a tag conversion, the same text as a `Warning` tag
  (`RawConv ItemInfoEntry: Argument "" isn't numeric ...`). lexiftool
  reads such a value the way Perl does (empty and undefined count as 0
  and as false) and prints no interpreter warnings.
- The same holds for `-validate`: where exiftool builds a warning from an
  undefined value (`[minor] Undefined value for :ManualFocusDistance` for
  the XMP of `t/images/XMP.xml`, whose directory name is unset), Perl
  also prints `Use of uninitialized value in concatenation (.) or string
  at .../Validate.pm line N.` on stderr. lexiftool gives the same warning
  without the interpreter line.

## `-ver -v`

- `-ver` prints `13.59`, as exiftool.
- `-ver -v` prints `Perl version` as the Lua version, adds a line
  `lexiftool port IDENTITY, Lua 5.5.0, bytecode yes|no` (IDENTITY a
  `git describe`, e.g. `v13.59.2-3-gabc1234`, baked in by the build; or
  `Unknown` for a source checkout or a rock install without that build
  step), and lists for each
  optional Perl module the Lua counterpart lexiftool uses in its place
  (`compress.zlib 0.0.1 (zlib 1.3.2)` for Compress::Zlib, `digest 0.0.1` for
  Digest::MD5 and Digest::SHA (`digest scm` for a build from its scm
  rockspec),
  `compress.brotli 0.0.1 (libbrotli 1.2.0)` for IO::Compress/Uncompress::Brotli,
  `compress.bzip2 0.0.1 (libbz2 1.0.8)` for IO::Compress::Bzip2,
  `compress.lzma 0.0.1 (liblzma 5.8.3)` for Compress::Raw::Lzma,
  `lexiftool.sys (statx)` for File::StatX on Linux, the built-in facade
  for Time::Piece and Time::Local, `lexiftool.perl (GCString,
  Unicode-LineBreak 2019.001 data, Unicode 8.0.0)` for Unicode::LineBreak,
  ...), or `(not installed)` where that counterpart is missing.

## Column alignment with `-lang`

- exiftool aligns translated tag descriptions by their display width
  (double-width CJK characters count twice, combining marks not at all)
  when the Perl module Unicode::LineBreak is installed, and by their number
  of characters otherwise. lexiftool always measures the display width,
  with Unicode::GCString's rules and the character data of the
  Unicode-LineBreak release named by `-ver -v` (built in, generated by
  `tools/gen_gcstring_data.lua`): its output matches exiftool with
  Unicode::LineBreak, not exiftool without it.

## Geolocation language files (`GeoLang`)

- The larger geolocation database of https://exiftool.org/geolocation.html
  (`Geolocation500-<date>.zip`) brings, next to `Geolocation.dat` and
  `AltNames.dat`, the translations of city, region, country and feature
  names in `GeoLang/<lang>.pm`. lexiftool reads all of them as they are:
  unpack the archive and point lexiftool at the directory as for exiftool,
  `-api GeoDir=/PATH/TO/Geolocation500`.
- The `.pm` files are Perl modules that only assign a hash of translations.
  lexiftool never runs them as Perl; it reads exactly that form as data
  (comment and blank lines, one `'KEY' => 'VALUE',` or `BAREWORD => 'VALUE',`
  entry per line, single-quoted strings with Perl's `\'` and `\\` escapes).
  A `.pm` in any other form -- any further statement or code, double-quoted
  or concatenated strings, heredocs -- is not used: lexiftool warns
  "GeoLang file not supported by lexiftool (Perl code, not a pure data
  table): FILE" and leaves that language untranslated, as exiftool leaves it
  untranslated when the `require` of the file fails.
- A language file may also be written in Lua, `GeoLang/<lang>.lua`, a file
  that returns the table of translations (it runs with an empty
  environment). **Deliberate difference:** in each directory searched,
  lexiftool takes `GeoLang/<lang>.lua` before `GeoLang/<lang>.pm`, so a Lua
  file overrides the downloaded `.pm` beside it (exiftool knows only the
  `.pm`). The script `tools/gen_geolang.lua` of the lexiftool source tree
  writes the Lua form of `.pm` files as a starting point for such a file:

  ```
  lua tools/gen_geolang.lua /PATH/TO/Geolocation500
  ```

  (or the `.pm` files one by one: `lua tools/gen_geolang.lua
  /PATH/TO/Geolocation500/GeoLang/de.pm`; a directory argument needs
  luafilesystem). Each `GeoLang/<lang>.lua` is written next to its `.pm`,
  with the same entries in the same order.
- The directories searched are those exiftool searches for the `.pm`: the
  GeoDir directory first, then the module search path (`package.path` for
  lexiftool, where a `DIR/?.lua` entry stands for `DIR/GeoLang/<lang>.lua`
  and `DIR/GeoLang/<lang>.pm`; `@INC` for exiftool). The first file found
  decides. A language without either file is not translated.

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

## Encrypted PDF documents (AES, RC4)

- exiftool decrypts and encrypts PDF documents with its own pure-Perl AES
  (`Image::ExifTool::AES`) and RC4 (`RC4Init`/`RC4Crypt` in `PDF.pm`).
  lexiftool computes both ciphers with the rocks `cipher.aes` and
  `cipher.rc4` (lua-cipher, self-contained C) and keeps upstream's entry
  points as a thin layer over them (`lexiftool/AES.lua`, `RC4Init`/
  `RC4Crypt` in `lexiftool/PDF.lua`), so the PDF code around them follows
  the Perl original line for line. This is the one place where the port
  does not port the Perl code line for line: the ciphers are
  self-contained, have nothing to do with metadata, and a cipher computes
  the same bytes whoever implements it, while upstream's pure-Perl AES
  makes AES-256 (revision 6) documents take seconds to open.
- The output is the same: the same tags and warnings, and the same
  written bytes. exiftool's random IV for AES encryption is kept as well:
  seeded from the time and the process id as upstream, with Perl's own
  random number generator, so the same seed gives the same IV.
- exiftool's warning `Decryption is very slow for encryption V5.6 or
  higher` and its skipping of large AES-encrypted streams without `-m` are
  kept as upstream, although lexiftool decrypts them quickly.

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
