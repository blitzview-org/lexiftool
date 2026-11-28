# Differences from exiftool

lexiftool runs the same command lines as `exiftool` 13.64 and gives the same
output (checked byte for byte against the Perl original, over its test
images and a corpus of camera sample images). Where it cannot, because the
original runs Perl code that the user supplies, it says so instead of
failing silently.

## Config files (`-config`, `.ExifTool_config`)

An exiftool config file is Perl code, which lexiftool does not run: it
reads a Perl config file that only assigns data and warns about and skips
one with other Perl code. For everything else lexiftool has a config file
of its own, written in Lua; lookup, format, the Perl subset read as data
and the remaining limits are in [configuration.md](configuration.md).

## Perl expressions (`-if`, `${TAG;EXPR}`, `-p`, `-tagsFromFile`, fmt files, `-api GeoHPosErr`)

- exiftool evaluates these as Perl code. lexiftool interprets a subset of
  Perl that covers every example in the exiftool documentation and the
  shipped fmt files, the conversion code of the bundled config files, plus
  common constructs:
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

## Interpreter messages that name a Perl source line

- Where exiftool's own code calls Perl's `warn` without a trailing newline,
  or the interpreter warns about an operation, Perl appends the location in
  its source: `Internal error at .../Image/ExifTool/Writer.pl line N,
  <EXIFTOOL_FILE2> chunk 8.` (WriteBinaryData, for a size tag whose value
  is not the 0xfeedfeed placeholder, seen when copying the maker notes of
  some newer Sony models), `Use of uninitialized value in subtraction (-)
  at .../Writer.pl line N` (writing a Leica JPEG whose trailer position is
  unknown). lexiftool prints the first as `Internal error at (eval) line
  1.` and gives no interpreter warning for the second; the written file is
  the same.
- Inside a tag conversion the location is cut off (exiftool reports
  `Use of uninitialized value in pattern match (m//) in
  Minolta:Saturation (ValueConvInv)`), and lexiftool gives the same text.

## `-ver -v`

- `-ver` prints `13.64`, as exiftool.
- `-ver -v` prints `Perl version` as the Lua version, adds a line
  `lexiftool port IDENTITY, Lua X.Y.Z, bytecode yes|no` (IDENTITY a
  `git describe` of the form `vTAG-N-gHASH`, baked in by the build; for
  a LuaRocks install, which has no such build step, the rock version the
  rockspec compiles into the C module, as `VERSION (LuaRocks)`, e.g.
  `scm-0 (LuaRocks)`; or `Unknown` for a
  source checkout), and lists for each
  optional Perl module the Lua counterpart lexiftool uses in its place,
  as `MODULE VERSION`, followed by the version of the C library behind it
  in parentheses where there is one
  (`compress.zlib VERSION (zlib VERSION)` for Compress::Zlib,
  `digest VERSION` for Digest::MD5 and Digest::SHA (`digest scm` for a
  build from its scm rockspec),
  `compress.brotli VERSION (libbrotli VERSION)` for
  IO::Compress/Uncompress::Brotli,
  `compress.bzip2 VERSION (libbz2 VERSION)` for IO::Compress::Bzip2,
  `compress.lzma VERSION (liblzma VERSION)` for Compress::Raw::Lzma,
  `lexiftool.sys (statx)` for File::StatX on Linux, the built-in facade
  for Time::Piece and Time::Local, `lexiftool.perl (GCString,
  Unicode-LineBreak VERSION data, Unicode VERSION)` for Unicode::LineBreak,
  ...), or `(not installed)` where that counterpart is missing; the
  versions are those of the installed modules and libraries.

## Column alignment with `-lang`

- exiftool aligns translated tag descriptions by their display width
  (double-width CJK characters count twice, combining marks not at all)
  when the Perl module Unicode::LineBreak is installed, and by their number
  of characters otherwise. lexiftool always measures the display width,
  with Unicode::GCString's rules and the character data of the
  Unicode-LineBreak release named by `-ver -v` (built in): its output
  matches exiftool with
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
- **Deliberate difference:** when `GeoDir` is not set, exiftool still looks
  for `AltNames.dat` (city name lookup) and the `GeoLang` translation files
  in the directory of `Geolocation.pm` itself. lexiftool only looks there
  when `GeoDir` is given explicitly; without it, there is no geo directory
  to search, since the standalone executable and the embedded C API have no
  module directory to fall back to.

## Features behind optional Perl modules

exiftool enables some features only when an optional Perl module is
installed and silently leaves them out otherwise. lexiftool has a
counterpart for each of them built in (see `-ver -v` above), so these
features are always on -- its output is that of an exiftool with all
optional modules installed. The one a user notices most: on Linux,
`FileCreateDate` (`File Creation Date/Time`, the file's birth time from
`statx`) is always extracted, where exiftool needs `File::StatX` for it.

## Windows file names and times

- Unicode file names and wildcards work natively on Windows: opening,
  reading, writing, renaming, deleting, creating directories, directory
  listings and wildcard expansion all handle names outside the ANSI code
  page, and file times are read and set on the open file, exiftool's
  workaround for the daylight saving time error of the C runtime's `stat`.
  exiftool needs the Perl modules `Win32::API`, `Win32API::File` and
  `Win32::FindFile` for this and falls back to ANSI names without them.
- `WindowsLongPath` is therefore on by default, and `-preserve` keeps
  `FileCreateDate` (exiftool does both only when those Perl modules are
  installed).

## Date formatting (`-d`, `DateFormat`)

- The format goes to the C library's own `strftime`, as exiftool's
  `POSIX::strftime` does, in the `LC_TIME` locale Perl takes from the
  environment (`LC_ALL`, `LC_TIME`, `LANG`), so the conversions the platform
  knows -- and the ones it rejects -- behave as in exiftool there. Unlike
  Perl, lexiftool never sets the process locale for this; the result is
  the same. lexiftool follows `POSIX::strftime` of Perl 5.42.1 and later:
  the date is normalized by `mktime` with daylight saving time left to the
  C library, so a local time that does not exist (inside the
  spring-forward gap) moves on by the gap (`02:30` becomes `03:30`). Perl
  5.42.0 and some older versions keep such a time as given.

## The `TimeZone` option (`-api TimeZone`)

exiftool implements the option by setting `$ENV{TZ}` and calling `tzset`:
the time zone of the whole process changes for good, every other ExifTool
object of the program and the program itself see it, and setting the option
to undef changes nothing back. lexiftool gives the zone to the object that
sets the option instead. Its local times -- dates from Unix times such as
`FileModifyDate`, `-d`/`DateFormat` with `%z` and `%Z`, local times that
are written, shifted or converted with `QuickTimeUTC`, geotag times without
a zone -- use that zone; the environment and the process's time zone stay
as they are, and other objects keep theirs, or the system's. On the command
line there is one object, as in exiftool, and the output is the same.

The value is read as the platform's C library reads `TZ`, so a value means
what it means to exiftool on that platform:

- Linux and other Unix systems (glibc): a zone ID names a file under
  `$TZDIR` (default `/usr/share/zoneinfo`), or a file by its absolute path;
  anything else is a POSIX TZ string (`EST5EDT`, `<+05>-5`,
  `CET-1CEST,M3.5.0,M10.5.0/3`, the offset positive west of Greenwich). A
  string with a daylight-saving name but no rule takes the transitions of
  the `posixrules` file, else the US rules. A value glibc cannot parse is
  UTC: `+05:00` is UTC with an empty zone name.
- macOS: the same, with the zone files under `/var/db/timezone/zoneinfo`;
  a zone name may be empty, so `+05:00` is UTC-5 (the reading exiftool's
  documentation describes).
- Windows: the C runtime's format `tzn[+|-]hh[:mm[:ss]][dzn]` -- three
  letters of standard name, the offset, and, if anything follows, daylight
  saving time by the US rules under the next three letters. Zone IDs are
  not understood: `America/New_York` is a zone "Ame" at UTC with US
  daylight saving time named "ric", as in exiftool on Windows.

A library function called without an object (`ConvertUnixTime`,
`TimeLocal`, ...) takes the zone of the object whose method it runs in --
also through a helper object without a zone of its own that the method
creates, as geotagging and copying tags from a file do -- and the system's
zone outside of any. In the command-line tool this concerns the helper
object of `-fileOrder`, which runs outside the main object's calls: it
sorts by local times of the system's zone, which can order two files
differently from exiftool only where their times fall around a daylight
saving change. Zone files with leap seconds (`right/...`) are read as if
they had none.

`strftime` (behind `-d`/`DateFormat`) first normalizes the date with the C
library's `mktime`, and each platform resolves a local time that exists
twice (the hour in which daylight saving time ends) or not at all (the
hour in which it begins) its own way; lexiftool follows the platform's.
On Windows that is the C runtime's: a time in a daylight saving period
shows its daylight-time name, and one before 1970, which the C runtime's
`mktime` cannot convert, shows the daylight-time name too (empty for a
zone without one), as Perl's `strftime` does there. (Perl 5.42.0 behaves
otherwise; see "Upstream bugs the port does not reproduce".)
glibc starts from the UTC offset of the previous `mktime` call, so the
hour that exists twice comes out with the offset of the date converted
before it. In exiftool that offset is shared by the whole process; in
lexiftool each object has its own, which differs only where several objects
with a time zone convert dates in turn.

## Numbers, sorting and the host locale

lexiftool's output does not depend on the locale of the process it runs
in, as exiftool's does not (Perl ignores the locale outside `use locale`,
which exiftool never uses). This matters where lexiftool is embedded (C
API, a Lua host) and the host has set, say, `de_DE`:

- numbers print with `.` as the decimal point;
- strings sort and compare bytewise (`-sort`, `-G` grouping, sorted key
  lists), not by the locale's collation (`de_DE` would sort `a A ä b B z`,
  Perl gives `A B a b z ä`);
- character classes and case changes are ASCII-only, so UTF-8 text such as
  place names is never changed by a single-byte locale.

lexiftool never sets a locale itself; it reads the decimal point and the
collation of the current locale when the library loads, in `ExifTool:new`
and, in the C API, before every call. A Lua host that switches its locale
between two calls on the same `ExifTool` object formats with the old one.
One difference remains under a locale with a decimal comma: Lua's own
number parsing accepts `1,5` there, where Perl reads `1`.

## Results that depend on Perl's hash order

- A few code paths of exiftool walk a Perl hash (`keys %hash`), whose order
  Perl randomizes per process, and the result depends on that order. Example:
  copying the tags of a file whose EXIF directory holds two maker-note
  entries (tag 0x927c) of different kinds, `-tagsFromFile @ -all:all`. Both
  source entries become pending new values for the same tag ID, and which
  one is written (into both entries) depends on the order in which
  `GetNewTagInfoHash` sees them, so exiftool writes one of two files from run
  to run. Other cases: the order of some warnings (several `Error N placing
  ... in structure or list` warnings of an XML track log read with
  `-struct`), and the order of group names that differ only in case in
  `-listg7`.
- lexiftool walks such hashes in a fixed order (the keys in Perl's string
  order; a hash keyed by tag information, as the pending new
  values are, by table, tag ID and tag name), so it gives the same result on
  every run, and that result is one of those exiftool gives. A byte
  comparison with a single exiftool run can therefore differ for such a
  file or output.
- Fixing Perl's hash seed (`PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0`) makes
  exiftool repeat its order for hashes with string keys, but not for hashes keyed by references, such as the pending new
  values: their keys are addresses, which change from run to run on systems
  with address-space randomization.

## Division by zero in a conversion

- A tag conversion that divides by zero dies in Perl ("Illegal division by
  zero"); exiftool's eval leaves the value undefined and warns
  (`ValueConv TAG: Illegal division by zero`). lexiftool does the same: it
  reads the floating-point "division by zero" flag around each conversion
  (and turns Lua's integer division/modulus errors into the same message).
  One case stays different: `0/0` of two numbers (the floating-point
  "invalid" flag, which comparisons with NaN raise as well, so it cannot
  tell this case apart) gives `NaN` where exiftool drops the value.

## Encrypted PDF documents (AES, RC4)

lexiftool decrypts and encrypts PDF documents with the `cipher.aes` and
`cipher.rc4` modules instead of exiftool's pure-Perl AES and RC4; the
output -- tags, warnings, written bytes, even the random IV of AES
encryption for the same seed -- is the same. exiftool's warning
`Decryption is very slow for encryption V5.6 or higher` and its skipping
of large AES-encrypted streams without `-m` are kept, although lexiftool
decrypts them quickly.

## `-k` without a console (Windows)

When standard input is no console, lexiftool ends with the same
`GetConsoleMode failed, LastError=|6|` message as exiftool, but the
location it names is in lexiftool (`.../lexiftool/perl.lua line N`) rather
than `.../Term/ReadKey.pm`. Its exit status is 255, where exiftool's is
usually 2 (a leftover `errno` of exiftool's module search).

## Upstream bugs the port does not reproduce

Where the Perl original has an obvious bug, lexiftool does what the code
evidently means instead of reproducing the bug. The ported line keeps the
upstream line recognizable and names the bug in a comment.

- **7z archives, file attributes** (`7Z.pm`, `ReadFilesInfo`, attributes
  property): exiftool reads the attributes' "external" byte from the outer
  header stream instead of the property's own data, so it sees the id of
  the property that follows. Where that is not the end marker, it calls
  `ReadUINT64`, which `7Z.pm` does not define (its reader is `ReadUInt64`),
  and dies with `Undefined subroutine &Image::ExifTool::7Z::ReadUINT64`.
  lexiftool reads the byte from the property data, as the 7z format defines
  it, and lists the archive's files. Archives that 7-Zip writes put the
  attributes last and give the same output in both; only an archive with
  another property after the attributes differs.
- **Pentax `ImageTone`, Ricoh GR IV Monochrome** (`Pentax.pm`, tag
  `0x004f`): the print conversion lists the GR IV Monochrome's tones
  `Standard` to `HDR tone` as 33024 to 33029, followed by `Custom 1`,
  `Custom 2` and `Custom 3` -- all three with the key 33024 again. In a Perl
  hash the last one wins, so exiftool shows the Standard tone as
  `Custom 3`. lexiftool shows `Standard` for 33024 and leaves the three
  custom entries out, since their own values are not known; like in
  exiftool, they show as `Unknown (N)`, and writing `Custom 3` is refused as
  it is for `Custom 1` and `Custom 2`.
- **QuickTime `skip` atom with a preview image** (`QuickTime.pm`, the
  conditional list of `skip`): the entry for the JPEG preview that DuDuBell
  M1 dashcams store in a `skip` atom comes after the unconditional `Skip`
  entry, and a conditional list takes the first entry that applies, so
  exiftool never extracts that preview. lexiftool checks the preview entry
  before `Skip` and extracts the `PreviewImage`.
- **Geolocation database, truncated `-api GeoDir` file** (`Geolocation.pm`,
  `ReadDatabase`): the loops that read the country, region, subregion and
  time zone lists never clear them first, unlike the city list just above.
  A database given with `-api GeoDir` that ends partway through one of
  those lists leaves it half filled; when `ReadDatabase` then fails and
  falls back to the bundled database, the fallback's entries are appended
  onto the leftover ones instead of replacing them, so every index into
  those lists is off by the leftover count and exiftool reports the wrong
  country, region, subregion or time zone for every city. lexiftool clears
  all four lists (and the feature-type lookup filled alongside the fourth)
  before reading them, so the bundled database's indices come out right.

### Bugs of the Perl interpreter

Where exiftool's output depends on a bug of the Perl interpreter itself,
lexiftool behaves as Perl does without the bug.

- **`POSIX::strftime` in Perl 5.42.0** (Perl issue GH #22351): that release
  defaults `strftime`'s `isdst` argument to 0 instead of -1, so it
  normalizes the date without asking the C library whether daylight saving
  time applies. On a platform whose `struct tm` has no `tm_gmtoff`/`tm_zone`
  -- Windows -- `%Z` then gives the standard-time name for every date
  (`EST` for a summer date under `TimeZone=EST5EDT`, and `%z` the standard
  offset). Other releases run the C library's `mktime` with `isdst` -1 and
  give the daylight-time name for a date in daylight saving time;
  lexiftool does the same on every Perl. Elsewhere Perl 5.42.0 still takes
  `%Z` from `mktime`, so only Windows shows the difference.
- **Inexact `**` in Strawberry Perl**: the `pow` of the C library that
  Strawberry Perl is built with is off in the last digits where the one of
  other platforms is not, so a value computed with `**` can differ in its
  15th significant digit -- XMP's `ApertureValue` (`sqrt(2) ** $val`) is
  `8.00000000000001` there for an aperture of 8, which other Perls print as
  `8`. lexiftool gives `8` on every platform.

## Starting `lexiftool`

How the `lexiftool` launcher finds its modules is described in the
[README](../README.md).
