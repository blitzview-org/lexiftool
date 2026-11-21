# Lua library

lexiftool is also a Lua library with the API of Perl's `Image::ExifTool`:
the same functions, the same options and the same tag names, with Lua
calls in place of Perl's. The documentation of
[Image::ExifTool](https://exiftool.org/ExifTool.html) applies; this page
lists how its calls are written in Lua and where Lua has to differ.

## Loading

Installed as a rock (README.md, "Installation"), the library is on Lua's
default paths. From a checkout, put `src/` on `package.path` and
`build/<5.4|5.5>/` (the C module `lexiftool.sys`, `make sys`) on
`package.cpath`, next to the paths of the required rocks:

```sh
LUA_PATH="$PWD/src/?.lua;;" LUA_CPATH="$PWD/build/5.4/?.so;;" lua5.4 script.lua
```

```lua
local ExifTool = require('lexiftool')    -- Image::ExifTool
```

The library sets no paths, reads no environment variable of its own and
changes nothing in the host process (no environment, locale, signal or
working-directory change); its output does not depend on the host's
locale ([differences.md](differences.md#numbers-sorting-and-the-host-locale)).

## Creating an object

```lua
local et = ExifTool:new()                -- Image::ExifTool->new
```

Perl methods are Lua methods (`$et->ImageInfo(...)` is
`et:ImageInfo(...)`), Perl functions are Lua functions
(`ImageInfo($file)` is `ExifTool.ImageInfo(file)`, which creates an object
of its own). Parameters are in Perl's order. The first `new` also loads
the config file ([configuration.md](configuration.md)).

## Options

```lua
et:Options('Duplicates', 0)              -- set; returns the previous value
local sep = et:Options('ListSep')        -- get
et:Options('Unknown', 1, 'Sort', 'Group0')   -- several pairs
et:ClearOptions()                        -- back to the defaults
```

Option names and values are upstream's (`Duplicates`, `Unknown`,
`PrintConv`, `CoordFormat`, `DateFormat`, `Charset`, `ListSep`,
`IgnoreMinorErrors`, `NoWarning`, ...). An options table passed to
`ImageInfo` or `ExtractInfo` applies to that call only. `TimeZone` gives
the object a time zone of its own instead of changing the zone of the
process ([differences.md](differences.md#the-timezone-option--api-timezone)).

## Reading

`ImageInfo(file [, tags...] [, options])` reads a file and returns a table
of tag key → value:

```lua
local info = et:ImageInfo('photo.jpg')                         -- all tags
local info = et:ImageInfo('photo.jpg', 'Make', 'Model')        -- some tags
local tags = { 'Make', 'EXIF:DateTimeOriginal' }
local info = et:ImageInfo('photo.jpg', tags, { PrintConv = 0 })
```

- The file is a file name, an open Lua file (Perl's `\*FH`), the box
  `{ ref = 'SCALAR', value = data }` for data in memory (Perl's `\$data`;
  a Lua string or a carray) or a `lexiftool.RandomAccess` object.
- Perl tells a tag list (`\@tags`) from an options hash (`{...}`) by the
  reference type; in Lua a table with a `[1]` entry, or an empty table, is
  the tag list, any other table the options. A tag list passed in is filled
  with the tag keys found, in the order asked for.
- Keys are tag names, with a copy number for duplicates (`Make (1)`).
  Values are strings or numbers; a list-type tag is joined with `ListSep`
  (a Lua array with the `List` option), binary data is the box
  `{ ref = 'SCALAR', value = data }`.

The other reading calls, as in Image::ExifTool:

| Lua | Returns |
|---|---|
| `et:ExtractInfo(file [, tags...] [, options])` | 1, or 0 when the file could not be read (then an `Error` tag) |
| `et:GetInfo([tags...] [, options])` | the info table of the last `ExtractInfo`; `GetInfo()` all tags, `GetInfo(nil)` the tags requested before |
| `et:GetValue(tag [, type])` | a tag's value; `tag` may carry groups (`'EXIF:Make'`), `type` is `PrintConv` (default), `ValueConv`, `Both` (two values), `Raw`, `Bin` or `Rational` |
| `et:GetTagList([info] [, sort [, sort2]])` | a new list of tag keys; `sort` as upstream (`File`, `Tag`, `Descr`, `Group#`) |
| `et:GetFoundTags([sort [, sort2]])`, `et:GetRequestedTags()` | lists of tag keys |
| `et:GetDescription(tag)` | the tag's description (`Camera Model Name`) |
| `et:GetGroup(tag, family)` | the tag's group name of that family (`EXIF`, `IFD0`, ...) |
| `et:GetGroups([info] [, family])` | the group names present |
| `et:GetTagID(tag)` | the tag ID |
| `ExifTool.GetAllTags([group])`, `ExifTool.GetWritableTags([group])` | lists of known tag names |

Perl's list context has no Lua counterpart: where a Perl call returns a
list in list context and one value in scalar context, the Lua call returns
the scalar result, and an extra `true` argument after the documented ones
asks for the list: `et:GetValue('Subject', nil, nil, true)` returns the
items of a list-type tag one by one, as `my @v = $et->GetValue('Subject')`
does; without it the `PrintConv` value is joined with `ListSep`.

## Writing

```lua
et:SetNewValuesFromFile('other.jpg', 'EXIF:all')               -- copy tags
local n, err = et:SetNewValue('Artist', 'Jane Doe')           -- set
et:SetNewValue('XMP:Subject', { 'one', 'two' })                -- a list
et:SetNewValue('Comment', nil)                                 -- delete
et:SetNewValue('Keywords', 'new', { AddValue = 1, Group = 'IPTC' })
local result = et:WriteInfo('photo.jpg', 'photo_new.jpg')
```

- `SetNewValue(tag, value [, options])` returns the number of tags set and
  an error message (nil when there is none). The options are upstream's
  (`Group`, `AddValue`, `DelValue`, `Replace`, `Protected`, `Type`, ...)
  in one table. `SetNewValue()` with no argument clears all new values.
- `SetNewValuesFromFile(file [, tags...] [, options])` takes upstream's
  tag arguments (`'-all'`, `'XMP:*'`, `'Artist>Creator'`, ...) and returns
  the table of the values set.
- `WriteInfo(src [, dst [, type]])` returns 1 when the file was written,
  2 when it was written without changes and 0 on an error (then
  `et:GetValue('Error')` names it). Without `dst` the file is edited in
  place. Instead of file names both take the box `{ ref = 'SCALAR' }`
  for data in memory: after writing, `box.value` is a carray (read it with
  `box.value:tostring()`, or hand the box to `ImageInfo`/`WriteInfo`
  again).

## Errors and warnings

As in Image::ExifTool, a problem with a file or a value is no Lua error:
`ImageInfo` returns an `Error` tag (`Error opening file`, `File format
error`) and `Warning` tags, `ExtractInfo` and `WriteInfo` return 0 and
set the `Error` tag, and `SetNewValue` returns the message as its second
value. `et:GetValue('Error')` and `et:GetValue('Warning')` read them;
`et:Options('NoWarning', pattern)` suppresses warnings as upstream.

A Lua error is raised where Perl would die as well (a method that does
not exist, a missing module), and for a bug of the port.

## Example

```lua
local ExifTool = require('lexiftool')

local et = ExifTool:new()
et:Options('Duplicates', 0)

-- read: ImageInfo returns tag key -> value and fills in the tag list
local tags = { 'Make', 'Model', 'DateTimeOriginal' }
local info = et:ImageInfo('photo.jpg', tags)
if info.Error then error(info.Error) end
for _, tag in ipairs(tags) do
    print(et:GetDescription(tag) .. ': ' .. info[tag])
end

-- write: note new values, then write them into a new file
local _, err = et:SetNewValue('Artist', 'Jane Doe')
if err then error(err) end
if et:WriteInfo('photo.jpg', 'photo_new.jpg') == 0 then
    error(et:GetValue('Error'))
end
print(ExifTool.ImageInfo('photo_new.jpg', 'Artist').Artist)
```

## File access (`lexiftool.RandomAccess`)

`require('lexiftool.RandomAccess')` is Perl's `File::RandomAccess`, method
for method:

- `RandomAccess:new(file [, isRandom])` -- an open Lua file, or the box
  `{ ref = 'SCALAR', value = data }` (string or carray) for data in memory.
- `raf:Read(len)` returns the number of bytes read and the data: Perl's
  `$raf->Read($buff, $len)` fills `$buff` through its `@_` alias, so
  `my $n = $raf->Read($buff, $len)` is `local n, buff = raf:Read(len)`.
- `raf:Seek(pos [, whence])`, `raf:Tell()`, the other methods as upstream.

## Further differences from the Perl API

- `Filter(filter, value)` returns two values, the result and the filtered
  value, where Perl changes `\$value` in place.
- `Open(FH, file [, mode])`: FH is a table standing for Perl's `*FH`
  (`local FH = { }`); Open puts the open Lua file into `FH.IO` and returns
  1, or nil on failure.
- `NO_SORT` is an object member, as upstream (`et.NO_SORT`).
- `GetTagTable(name)` and `AddTagToTable(table, tagID [, tagInfo [,
  noPrefix]])` are functions: `ExifTool.GetTagTable('lexiftool.Exif.Main')`.
- Where Perl's result depends on its random hash order, lexiftool gives
  one fixed result
  ([differences.md](differences.md#results-that-depend-on-perls-hash-order)).
- Perl code in user input (`-if`-style conditions, `${TAG;EXPR}`, config
  files) runs only within the subset listed in
  [differences.md](differences.md).
