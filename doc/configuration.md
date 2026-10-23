# Configuration file

exiftool reads a config file written in Perl (`.ExifTool_config`, or the
file named with `-config`) that defines user-defined tags, shortcuts,
default options and a few lookups. lexiftool does not run Perl code. It
reads a Perl config file directly when the file only assigns data -- most
real config files do (see [Perl config files](#perl-config-files)) -- and
it has a config file of its own, written in Lua, for everything else. The
data is the same: the Lua file returns the Perl config's package variables
as one Lua table, laid out like the Perl hashes, so that a Perl config
translates almost word for word.

`src/test/config/example_config.lua` is upstream's
`config_files/example.config` translated in full; `src/test/test_config.lua`
runs lexiftool with it against exiftool with the original and checks that
the output and the written files are identical. (example.config itself has
a `sub`, so lexiftool does not read it as Perl.) `src/test/test_perlconfig.lua`
runs lexiftool and exiftool with the same Perl config files -- the test files
in `src/test/config/perl/`, one per construct, and upstream's
`config_files/` -- and compares them likewise.

## Where lexiftool looks

As exiftool does:

1. `-config FILE` (the first option on the command line); `-config ""`
   disables the config file, `-config -` reads it from stdin;
2. otherwise the default file in the home directory -- `$EXIFTOOL_HOME`,
   else `$HOME`, else `$HOMEDRIVE$HOMEPATH`, else the current directory --
   and then in the directory of the `lexiftool` script.

The default file is `.lexiftool_config` when one exists in either place,
otherwise `.ExifTool_config`. So lexiftool and exiftool can share a home
directory: each finds its own file.

A file is loaded as Lua when its name ends in `.lua`, when it is a
`.lexiftool_config`, or when its first line starts with `-- lexiftool config`
(which lets an `.ExifTool_config` hold a Lua config). Any other file is an
exiftool config written in Perl, read as described under
[Perl config files](#perl-config-files).

From the library, set `ExifTool.configFile` (or `ExifTool.noConfig`) after
`require('lexiftool')` and before the first `ExifTool.new()`, which loads the
config file, as a script sets `$Image::ExifTool::configFile` in its BEGIN
block.

## Perl config files

lexiftool reads an exiftool config file without running Perl: it parses the
data the file assigns and carries the assignments out as Perl would. The
same tables result as from the Lua config file that translates it. The file
may contain:

- assignments to the package variables exiftool reads:
  `%Image::ExifTool::UserDefined`, `%Image::ExifTool::UserDefined::NAME`
  (new tag tables, also `UserDefined::A::B`), `::Shortcuts`, `::Options`,
  `::FileTypes`, `@...::Lenses`, `@...::Arguments`, `@...::Geolocation`,
  the older `%Image::ExifTool::Shortcuts::UserDefined`,
  `$Image::ExifTool::Geolocation::geoDir`/`altDir` and
  `%Image::ExifTool::Geolocation::geoLang`, and new tag tables in another
  package (`%Image::ExifTool::XMP::myns = (...)`; a module that has a table
  of that name keeps its own, as in exiftool once the module is loaded);
- element assignments, with or without `->`, creating the hashes and arrays
  on the way: `$Image::ExifTool::UserDefined{'Image::ExifTool::XMP::Main'}{myns} = {...};`,
  `$Image::ExifTool::UserDefined::Shortcuts{Mine}[1] = 'Model';`, and the
  scalar entries of a tag table of a module the file loaded
  (`$Image::ExifTool::QuickTime::Keys{PREFERRED} = 3;`);
- `use` and `require` of `Image::ExifTool` and its modules (they load the
  Lua module; `use` before the file's statements run, as Perl does it at
  compile time), the pragmas `strict`, `warnings` and `utf8` (in a file
  with ASCII text only) and a Perl version (`use 5.008;`);
- the call `Image::ExifTool::XMP::RegisterNamespace(\%...)`;
- as values: numbers (`12`, `1.5`, `1e3`, `0x1f`, `017`, `0b101`, `1_000`),
  strings (`'...'`, `"..."` with escapes but no variables, `q{...}` and
  `qq{...}` with any delimiter), `qw(...)`, `undef`, barewords where Perl
  takes them for strings (before `=>`, in a subscript, and as a value unless
  `use strict` is on), lists, `{...}` and `[...]`, references
  `\%Image::ExifTool::...`, `\@...` and `\&Image::ExifTool::Function`, a
  package hash or array spliced into a list (`%Image::ExifTool::MIE::tableDefaults,`,
  `%{...}`), and the operators `.`, `+`, `-`, `*`, `|`, `&`, `<<`, `>>`
  between constants;
- comments, POD where a statement may begin, `__END__`/`__DATA__`, `1;`.

Perl's semantics hold for these: a later assignment replaces an earlier one
and a later key in a hash literal an earlier one; a reference to a table
defined further down is the same table once it is filled; the package
variables keep their values from one config file to the next. Under
`use warnings` lexiftool warns as Perl does for an odd number of elements
in a hash (`Odd number of elements in hash assignment at FILE line N.`,
`... in anonymous hash ...`, `Reference found where even-sized list
expected ...`). A call of `RegisterNamespace` before its module is loaded
dies as in Perl (`Undefined subroutine &Image::ExifTool::XMP::RegisterNamespace
called at FILE line N.`): the statements before it are in effect, the rest
is not. A file whose last statement is false warns
`FILE did not return a true value` (without Perl's location in ExifTool.pm)
and is used all the same, as in exiftool.

Conversions given as strings (`ValueConv => '$val * 2'`,
`PrintConv => q{ ... }`) are code for later; they run through the Perl
subset of `perl.eval` as in a Lua config file (see below), and Perl beyond
that subset is reported when the conversion runs.

Anything else is not run: `sub`, `my`, `our`, `local`, `package`, `BEGIN`,
`if`, loops, statement modifiers, calls of other functions (`print`,
`map`, `sprintf`, method calls, ...), variables in values, interpolation in
`"..."`, heredocs, regular expressions, `use` of other modules, variables of
`Image::ExifTool` itself or of other packages, the replacement of a whole
tag table of a module, `undef` in a list, a character beyond `\xff` in a
string, and Perl syntax errors. Then lexiftool uses nothing of the file,
warns

    Config file not supported by lexiftool (Perl code at line N: CONSTRUCT): FILE

(with the line of the first such construct) and runs on without it -- the
file can be translated into a Lua config file as described below. A piped
config file (`-config -`) is read the same way, with `use strict` on (as
exiftool evaluates it inside ExifTool.pm).

## Format

The file is a Lua chunk that returns a table. Its keys are the names of the
package variables an exiftool config assigns, with or without the
`Image::ExifTool::UserDefined::` prefix:

| exiftool config (Perl) | lexiftool config (Lua key) |
|---|---|
| `%Image::ExifTool::UserDefined` | `UserDefined` or `'Image::ExifTool::UserDefined'` |
| `%Image::ExifTool::UserDefined::Shortcuts` | `Shortcuts` |
| `%Image::ExifTool::UserDefined::Options` | `Options` |
| `@Image::ExifTool::UserDefined::Lenses` | `Lenses` |
| `%Image::ExifTool::UserDefined::FileTypes` | `FileTypes` |
| `@Image::ExifTool::UserDefined::Geolocation` | `Geolocation` |
| `@Image::ExifTool::UserDefined::Arguments` | `Arguments` |
| `%Image::ExifTool::UserDefined::NAME` (a new tag table) | `'Image::ExifTool::UserDefined::NAME'` (full name) |
| `%Image::ExifTool::X::NAME` (a new tag table in another package) | `'Image::ExifTool::X::NAME'` (used where module X has no table NAME) |

```lua
-- lexiftool config   (only needed when the file name does not say .lua)
local config = { }
config['Image::ExifTool::UserDefined::Shortcuts'] = {
    MyShortcut = { 'exif:createdate','exposuretime','aperture' },
    MyAlias = 'FocalLengthIn35mmFormat',
}
config['Image::ExifTool::UserDefined'] = {
    ['Image::ExifTool::Exif::Main'] = {
        [0xd000] = {
            Name = 'NewEXIFTag',
            Writable = 'int16u',
            WriteGroup = 'IFD0',
        },
    },
}
return config
```

The tables go where the port reads upstream's package variables:
`UserDefined` into `ExifTool.UserDefined` (keyed by the port's table names),
`Options` into `ExifTool.UserDefinedOptions`, `Arguments` into
`ExifTool.UserDefinedArguments`, the rest into `ExifTool.UserDefinedTables`.
From there the ported code uses them exactly as exiftool does: `GetTagTable`
adds the tags to their table when it is loaded (Composite tags through
`AddCompositeTags`), `TagLookup` makes them writable, `Shortcuts` loads the
shortcuts, `new()` applies the default options, the exiftool script prepends
the default arguments, and the Lenses and FileTypes blocks after the config
loop fill the LensID preferences and the file type lookups; the Geolocation
entries are added to the city database when it is read. The tags appear
in `-list`, `-listx`, `-X` and `-j` like any other tag, can be written,
copied with `-tagsFromFile` and used in shortcuts.

Several `-config` options load their files in order. Each file assigns
its variables whole, like the `%... = (...)` assignments of a Perl config:
a later file replaces a variable that an earlier one set, it does not merge
into it.

### Table names

Tables are named as upstream names them, `'Image::ExifTool::Exif::Main'`,
`'Image::ExifTool::XMP::xmp'`, `'Image::ExifTool::Composite'` -- in the keys
of `UserDefined` and in a `SubDirectory`'s `TagTable`. One exception: the
tables of upstream's `QuickTimeStream.pl` (`Image::ExifTool::QuickTime::Stream`
and the other timed-metadata tables) are named
`'Image::ExifTool::QuickTimeStream::NAME'`, after the port's module.

## Translating a Perl config file

| Perl (example.config) | Lua (example_config.lua) |
|---|---|
| `# comment` | `-- comment` |
| `%Image::ExifTool::UserDefined = ( ... );` | `config['Image::ExifTool::UserDefined'] = { ... }` |
| `'Image::ExifTool::Exif::Main' => {` | `['Image::ExifTool::Exif::Main'] = {` |
| `0xd000 => {` / `160 => {` | `[0xd000] = {` / `[160] = {` |
| `Name => 'NewEXIFTag',` | `Name = 'NewEXIFTag',` |
| `Groups => { 2 => 'Author' }` | `Groups = { [2] = 'Author' }` |
| `Units => [ 'cm', 'in' ]` | `Units = { 'cm', 'in' }` |
| `Require => { 0 => 'ImageWidth', 1 => 'ImageHeight' }` | `Require = { [0] = 'ImageWidth', [1] = 'ImageHeight' }` |
| `PrintConv => { 0 => 'Off', 1 => 'On' }` | `PrintConv = { [0] = 'Off', [1] = 'On' }` |
| `NAMESPACE => { 'xxx' => 'http://ns.myname.com/xxx/1.0/' }` | `NAMESPACE = { ['xxx'] = 'http://ns.myname.com/xxx/1.0/' }` |
| `Writable => 0` | `Writable = 0` (Perl's false values 0 and `''` stay false) |
| `ValueConv => '$val=~/\.([^.]*)$/; $1'` | `ValueConv = [[$val=~/\.([^.]*)$/; $1]]` |
| `ValueConv => sub { ... }` | `ValueConv = function(self, val) ... end` |
| `require Image::ExifTool::XMP;`<br>`Image::ExifTool::XMP::RegisterNamespace(\%Image::ExifTool::UserDefined::xxx);` | `require('lexiftool.XMP').RegisterNamespace(config['Image::ExifTool::UserDefined::xxx'])` |
| `%Image::ExifTool::MIE::tableDefaults,` (spliced into a table) | copy `require('lexiftool.MIE').tableDefaults` into the table (see example_config.lua) |
| `$Image::ExifTool::QuickTime::Keys{PREFERRED} = 3;` | `require('lexiftool.QuickTime').Keys.PREFERRED = 3` |
| `@Image::ExifTool::UserDefined::Lenses = ( 'a', 'b' );` | `config['Image::ExifTool::UserDefined::Lenses'] = { 'a', 'b' }` |
| `1;  #end` | `return config` |

A Perl string with backslashes (`'\.'`) is best written as a Lua long string
(`[[\.]]`), since Lua reads backslash escapes in quoted strings.

### Conversions and other code

A conversion may be given two ways:

- **A Perl expression string**, as in exiftool (and as a Perl config file has them). It runs through lexiftool's
  interpreter for a subset of Perl (`perl.eval`, the one `-if` and
  `${TAG;EXPR}` use; [differences.md](differences.md) lists the subset). It
  sees `$val`, `$self` and `$tag`; a Composite tag's `ValueConv` and
  `PrintConv` also see `@val` and `@prt` (and `$val` is `$val[0]` in a
  Composite `ValueConv`), an inverse conversion `$wantGroup`. The functions
  of `Image::ExifTool` can be called (`GetFileType($val,1)`). Perl beyond the
  subset is reported when the conversion runs, as
  `Warning: ValueConv TAG: Perl syntax unsupported in lexiftool: ...`, and
  the tag has no value.
- **A Lua function**, where exiftool has a code reference. It is called
  with the port's argument order (the object first), which is not Perl's
  `($val, $self)`:

  | field | Lua function |
  |---|---|
  | `RawConv`, `ValueConv`, `PrintConv` | `function(self, val, tag)` |
  | Composite `ValueConv` | `function(self, val, prt)`, `val`/`prt` indexed like `Require`/`Desire` (from 0) |
  | Composite `PrintConv` | `function(self, val, vals, prts)` |
  | `ValueConvInv`, `PrintConvInv` | `function(self, val, wantGroup)` |
  | `RawConvInv` | `function(self, val, tagInfo)` |
  | `Condition` | `function(self)`, or `function(self, val, format, count)` when it needs the value |

  A binary value is a table `{ ref = 'SCALAR', value = <bytes> }`. Where
  Perl code would `die`, call `require('lexiftool.perl').die(msg)`: the
  value is then undefined and the message warned, as exiftool does.

Only a whole conversion is turned from a Perl string into a function. A
conversion list (Perl's array of conversions, `[ 'conv1', 'conv2' ]`) must
be a list of Lua functions: a Lua sequence of strings cannot be told apart
from a lookup table.

### What the chunk can use

The chunk runs with the basic Lua functions (`pairs`, `ipairs`, `type`,
`tostring`, `tonumber`, `error`, `pcall`, `select`, `setmetatable`, ...),
copies of `string`, `table`, `math` and `utf8`, and a `require` that loads
only lexiftool's own modules (`lexiftool`, `lexiftool.XMP`, `lexiftool.perl`,
...). `os`, `io`, `print`, `load` and `dofile` are not there. This keeps a
config file to data and conversions; it is not a security boundary -- a
config file is trusted code, as in exiftool.

## Errors

| case | lexiftool says | then |
|---|---|---|
| Lua syntax or runtime error | `FILE:LINE: message` (Lua's message) | runs without this file |
| `require` of a module outside lexiftool | `FILE:LINE: module 'os' is not available in a lexiftool config file` | runs without this file |
| chunk returns no table | `Config file FILE did not return a table` | runs without this file |
| unknown top-level key | `Unknown entry 'KEY' in config file FILE` | the other entries are used |
| `UserDefined` key outside `Image::ExifTool::` | `Bad table name 'NAME' in config file FILE` | the other tables are used |
| table that does not exist | `Can't find table Image::ExifTool::Foo::Bar` when it is needed (as exiftool) | the tags are not writable |
| Perl config file with code (see [Perl config files](#perl-config-files)) | `Config file not supported by lexiftool (Perl code at line N: CONSTRUCT): FILE` | runs without this file |
| Perl config file whose last statement is false | `FILE did not return a true value` | the file is used |
| `-config FILE` missing | `Config file not found` (as exiftool) | runs without configuration |

## Limits

- No Perl is run: code is a Perl expression string within the `perl.eval`
  subset or a Lua function; a Perl config file is read only as far as it is
  data.
- In a Perl config file, `undef` as a hash value leaves the key out (a Lua
  table has no undefined values; for exiftool's tables that is the same).
- Hash keys that are the string of an integer (`'160'`, `0xa0`) are integer
  keys, as the Lua tables have them; the names in `Shortcuts`, `Options`
  and `FileTypes` stay strings.
- `xmpStruct` (structures referenced by name, which exiftool keeps for
  backward compatibility only) is not supported; define a structure in place
  with `Struct = { ... }`.
- `$$valPt` in a `Condition` string is outside the Perl subset; write such a
  condition as a Lua function.
