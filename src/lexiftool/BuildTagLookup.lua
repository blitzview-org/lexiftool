--------------------------------------------------------------------------------
-- File:         lexiftool/BuildTagLookup.lua
-- Ported from:  lib/Image/ExifTool/BuildTagLookup.pm
--
-- Description:  Utility to build tag lookup tables in Image::ExifTool::TagLookup.pm
--
-- Revisions:    12/31/2004 - P. Harvey Created
--               02/15/2005 - PH Added ability to generate TagNames documentation
--
-- Notes:        Documentation for the tag tables may either be placed in the
--               %docs hash below or in a NOTES entry in the table itself, and
--               individual tags may have their own Notes entry.
--
-- Port notes:   complete: all 12 subs in upstream order (new,
--               WriteTagLookup, NumbersFirst, Doc2Pod, Doc2Html, TweakOrder,
--               SortedTagTableKeys, GetTableOrder, OpenHtmlFile,
--               CloseHtmlFiles, PodMask, WriteTagNames) and the data at the
--               top of the file (%tweakOrder, %formatOK, %docs,
--               %shortcutNotes, %riffSpec, %xmpSpec) verbatim.  The caller
--               is tools/gen_tag_lookup.lua, the counterpart of upstream's
--               build_tag_lookup script; it writes the POD and HTML below
--               build/doc/.
--
--               Table names keep upstream's spelling inside this file
--               ('Image::ExifTool::Exif::Main'), so every name pattern reads
--               as in the .pm; PerlTableName/LuaTableName translate at the
--               boundary to the port's 'lexiftool.Exif.Main' (GetTagTable,
--               %allTables, @tableOrder, a SubDirectory's TagTable and the
--               tableList written to TagLookup.lua).  Tables are therefore
--               sorted and numbered by their upstream names.
--
--               WriteTagLookup writes the Lua form of upstream's index into
--               the generated section of src/lexiftool/TagLookup.lua: the
--               same sections, comments, entries and sort order, with Lua
--               syntax where it must differ -- `{ }` for `( )`, `['key'] =`
--               for `'key' =>`, 1-based table numbers (tableList is a Lua
--               array), the Lua table names in tableList, and the root
--               structure ID of a flattened tag as a one-element table
--               (`{'Regions'}`) where Perl stores a scalar reference.
--
--               Conversions, Conditions, Hooks, Start and Format expressions
--               are Lua functions in this port, so the checks in new() that
--               match their *code* (`$valPt`, `$self{...} =`, `$val`,
--               `DecodeBits(...)`) only see the string ones: a function Start
--               gets no SubIFD verdict, a function Format passes, a function
--               RawConv counts as setting a data member when the table's
--               DATAMEMBER lists it, and the "Bit N = ..." values of a
--               DecodeBits PrintConv are not listed (documentation and
--               warnings only, never the lookup).  Where upstream walks a
--               hash (%structs, %createdFiles) the keys are sorted.  The
--               BEGIN block's $configFile/$debug have no counterpart: this
--               port reads no config file and has no debug flag.
--------------------------------------------------------------------------------

local BuildTagLookup = {}

-- (BEGIN block: upstream empties $Image::ExifTool::configFile to prevent
--  ExifTool from loading the user config file, and sets $debug; see the
--  Port notes)

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local Exif = require('lexiftool.Exif')
local Shortcuts = require('lexiftool.Shortcuts')
local HTML = require('lexiftool.HTML')
local IPTC = require('lexiftool.IPTC')
local XMP = require('lexiftool.XMP')
local Canon = require('lexiftool.Canon') -- luacheck: ignore 211
local Nikon = require('lexiftool.Nikon')
local Sony = require('lexiftool.Sony')
local Validate = require('lexiftool.Validate')
local MacOS = require('lexiftool.MacOS') -- luacheck: ignore 211
local perl = require('lexiftool.perl')

local matches, isMatch, isMatchDyn = perl.matches, perl.isMatch, perl.isMatchDyn
local subst, substDyn = perl.subst, perl.substDyn
local eachMatch = perl.eachMatch
local split, join = perl.split, perl.join
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local lc, ucfirst = perl.lc, perl.ucfirst
local hex = perl.hex
local unpack = perl.unpack
local quotemeta = perl.quotemeta
local warn = perl.warn
local perlTruthy = perl.truthy
local perlStr = perl.str
local EscapeHTML = HTML.EscapeHTML
local TagTableKeys = ExifTool.TagTableKeys
local GetTagInfoList = ExifTool.GetTagInfoList
local remove, insert = table.remove, table.insert

--------------------------------------------------------------------------------
-- (port artifacts, see the Port notes: the two spellings of a table name.
--  Upstream's name is derived from the port's once and remembered, so the
--  way back is exact for every table this file has seen; a name it has not
--  seen (Shortcuts::Main, the plug-in table before it is loaded) is a plain
--  respelling)
local luaTableName = { }
local function PerlTableName(name)
    local perlName = name:match('^lexiftool%.ExifTool%.(.*)$')
    if perlName then
        perlName = 'Image::ExifTool::' .. perlName
    else
        perlName = name:gsub('^lexiftool%.QuickTimeStream%.', 'lexiftool.QuickTime.')
        perlName = 'Image::ExifTool::' .. perlName:sub(11):gsub('%.', '::')
    end
    luaTableName[perlName] = name
    return perlName
end
local function LuaTableName(name)
    return luaTableName[name] or ('lexiftool.' .. name:sub(18):gsub('::', '.'))
end
-- (upstream's GetTagTable, %allTables and @tableOrder, in upstream spelling)
local function GetTagTable(tableName)
    return ExifTool.GetTagTable(nil, LuaTableName(tableName))
end
local function allTablesKeys()
    local list = { }
    for name in pairs(ExifTool.GetAllTables()) do list[#list + 1] = PerlTableName(name) end
    return list
end
local function tableOrderList()
    local list = { }
    for i, name in ipairs(ExifTool.tableOrder) do list[i] = PerlTableName(name) end
    return list
end
-- (Perl hash keys are strings: a tag ID or PrintConv key as Perl spells it;
--  any other value stringifies too -- a code ref or hash ref as Perl's
--  'CODE(0x...)'/'HASH(0x...)' would, only ever compared, never printed)
local function keyStr(key)
    if type(key) == 'number' then return ExifTool.NumStr(key) end
    if type(key) ~= 'string' then return perlStr(key) end
    return key
end
-- (upstream tells a list of conversions from a lookup hash by ref(); this is
--  the rule lexiftool.lua's GetValue applies to the same Lua tables: a list's
--  first element is a table, a function or false (upstream undef), a plain
--  lookup maps its keys to strings)
-- (is tagID listed in the table's DATAMEMBER, see new())
local function DataMember(table_, tagID)
    for _, id in ipairs(table_.DATAMEMBER or { }) do
        if id == tagID then return true end
    end
    return false
end
local function convRef(conv)
    if type(conv) == 'function' then return 'CODE' end
    if type(conv) ~= 'table' then return '' end
    local first = conv[1]
    if first == false or type(first) == 'table' or type(first) == 'function' then return 'ARRAY' end
    return 'HASH'
end

BuildTagLookup.VERSION = '3.69'

-- (upstream predeclares `sub NumbersFirst($$); sub SortedTagTablekeys($);`;
--  the package subs below are bound to these file-scope locals right after
--  their definitions, so new() and the other subs can call them unqualified)
local NumbersFirst, Doc2Pod, Doc2Html, TweakOrder, SortedTagTableKeys
local GetTableOrder, OpenHtmlFile, CloseHtmlFiles, PodMask

local createDate = 'Feb 15, 2005'

-- global variables to control sorting order of table entries
local numbersFirst = 1  -- set to -1 to sort numbers last, or 2 to put negative numbers last
local caseInsensitive   -- flag to ignore case when sorting tag names

-- list of all tables in plug-in modules
local pluginTables = { 'Image::ExifTool::MWG::Composite' }

-- colors for html pages
local noteFont = '<span class=n>'
local noteFontSmall = "<span class='n s'>"

local docType = [[<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"
        "http://www.w3.org/TR/html4/loose.dtd">
]]

local homePage = 'https://exiftool.org'

-- luacheck: push ignore 314 (upstream repeats the MinoltaRaw key)
-- tweak the ordering of tables in the documentation
local tweakOrder = {
  -- this    => comes after this
  -- -------    -----------------
    JPEG    = '-',     -- JPEG comes first
    IPTC    = 'Exif',  -- put IPTC after EXIF,
    GPS     = 'XMP',   -- etc...
    Composite = 'Extra',
    CBOR    = 'JSON',
    GeoTiff = 'GPS',
    CanonVRD= 'CanonCustom',
    CaptureOne = 'CanonVRD',
    DJI     = 'Casio',
    FLIR    = 'DJI',
    FujiFilm = 'FLIR',
    Google  = 'GE',
    GoPro   = 'Google',
    Kodak   = 'JVC',
    Leaf    = 'Kodak',
    Lytro   = 'Leaf',
    Minolta = 'Lytro',
    Motorola = 'Minolta',
    Nikon   = 'Motorola',
    NikonCapture = 'Nikon',
    NikonCustom = 'NikonCapture',
    NikonSettings = 'NikonCustom',
    Nintendo = 'NikonSettings',
    Panasonic = 'Olympus',
    Pentax  = 'Panasonic',
    Ricoh   = 'Reconyx',
    Samsung = 'Ricoh',
    SonyIDC = 'Sony',
    Unknown = 'SonyIDC',
    DNG     = 'Unknown',
    PrintIM = 'ICC_Profile',
    Vorbis  = 'Ogg',
    ID3     = 'PostScript',
    MinoltaRaw = 'KyoceraRaw',
    KyoceraRaw = 'CanonRaw',
    MinoltaRaw = 'KyoceraRaw',
    PanasonicRaw = 'MinoltaRaw',
    SigmaRaw = 'PanasonicRaw',
    PhotoMechanic = 'FotoStation',
    Microsoft     = 'PhotoMechanic',
    GIMP    = 'Microsoft',
    DarwinCore = 'AFCP',
    MWG     = 'Shortcuts',
    ['FujiFilm::RAF'] = 'FujiFilm::RAFHeader',
    ['FujiFilm::RAFData'] = 'FujiFilm::RAF',
    ['QuickTime::AudioKeys'] = 'QuickTime::Keys',
    ['QuickTime::VideoKeys'] = 'QuickTime::AudioKeys',
}
-- luacheck: pop

-- list of all recognized Format strings
-- (not a complete list, but this is all we use so far)
-- (also, formats like "var_X[num]" are allowed for any valid X)
local formatOK = {
    -- %Image::ExifTool::Exif::formatNumber, (spread below)
    ['0'] = 1,
    ['1'] = 1,
    ['2'] = 1, -- (writable for docs only)
    real    = 1,
    integer = 1,
    date    = 1,
    boolean = 1,
    rational  = 1,
   ['lang-alt'] = 1,
    fixed16u = 1,
    fixed16s = 1,
    fixed32u = 1,
    fixed32s = 1,
    extended = 1,
    resize   = 1,
    digits   = 1,
    int16uRev = 1,
    int32uRev = 1,
    rational32u = 1,
    rational32s = 1,
    pstring     = 1,
    var_string  = 1,
    var_int16u  = 1,
    var_pstr32  = 1,
    var_ustr32  = 1,
    var_ue7     = 1, -- (BPG)
    -- Matroska
    signed      = 1,
    unsigned    = 1,
    utf8        = 1,
    Unicode     = 1, -- (Microsoft Xtra)
    GUID        = 1, -- (Microsoft Xtra)
    vt_filetime = 1, -- (Microsoft Xtra)
}
-- (upstream spreads %Image::ExifTool::Exif::formatNumber into %formatOK as
--  its first entries, so the explicit entries above win)
for k, v in pairs(Exif.formatNumber) do
    if formatOK[k] == nil then formatOK[k] = v end
end

-- (a q{} string keeps the newline after its opening brace, a Lua long
--  string drops it -- the `'\n' ..` puts it back, so that the POD heading on
--  the first line still follows a newline for Doc2Pod's `s/\n~/\n=/g`)

-- Descriptions for the TagNames documentation
-- (descriptions may also be defined in tag table NOTES)
-- Note: POD headers in these descriptions start with '~' instead of '=' to keep
-- from confusing POD parsers which apparently parse inside quoted strings.
local docs = {
    PodHeader = '\n' .. [[
~head1 NAME

Image::ExifTool::TagNames - ExifTool tag name documentation

~head1 DESCRIPTION

This document contains a complete list of ExifTool tag names, organized into
tables based on information type.  Tag names are used to reference specific
meta information extracted from or written to a file.

~head1 TAG TABLES
]],
    ExifTool = '\n' .. [[
The tables listed below give the names of all tags recognized by ExifTool.
They contain a total of $$self{COUNT}{'total tags'} tags, with $$self{COUNT}{'unique tag names'} unique tag names.
]],
    ExifTool2 = '\n' .. [[
B<Tag ID>, B<Index#> or B<Sequence> is given in the first column of each
table.  A B<Tag ID> is the computer-readable equivalent of a tag name, and
is the identifier that is actually stored in the file.  B<Index#> refers to
the offset of a value when found at a fixed position within a data block
(B<#> is the multiplier for calculating a byte offset: B<1>, B<2>, B<4> or
B<8>).  These offsets may have a decimal part which is used only to
differentiate tags with values stored at the same position.  (Note that
writable tags within binary data blocks are not individually deletable,
and the usual alternative is to set them to a value of zero.)  B<Sequence>
gives the order of values for a serial data stream.

A B<Tag Name> is the handle by which the information is accessed in
ExifTool.  In some instances, more than one name may correspond to a single
tag ID.  In these cases, the actual name used depends on the context in
which the information is found.  Valid characters in a tag name are A-Z,
a-z, 0-9, hyphen (-) and underline (_).  Case is not significant.  A
question mark (C<?>) after a tag name indicates that the information is
either not understood, not verified, or not very useful -- these tags are
not extracted by ExifTool unless the L<Unknown|../ExifTool.html#Unknown> (-u) option is enabled.  Be
aware that some tag names are different than the descriptions printed out by
default when extracting information with exiftool.  To see the tag names
instead of the descriptions, use C<exiftool -s>.

The B<Writable> column indicates whether the tag is writable by ExifTool.
Anything but a C<no> in this column means the tag is writable.  A C<yes>
indicates writable information that is either unformatted or written using
the existing format.  Other expressions give details about the format of the
stored value, and vary depending on the general type of information.  The
format name may be followed by a number in square brackets to indicate the
number of values written, or the number of characters in a fixed-length
string (including a null terminator which is added if required).

A plus sign (C<+>) after an entry in the B<Writable> column indicates a
I<List> tag which supports multiple values and allows individual values to
be added and deleted.  A slash (C</>) indicates a tag that ExifTool will
I<Avoid> when writing.  These will be edited but not created if another
same-named tag may be created instead.  To create these tags, the group
should be specified.  A tilde (C<~>) indicates a tag this is writable only
when the print conversion is disabled (by setting L<PrintConv|../ExifTool.html#PrintConv> to 0, using the
-n option, or suffixing the tag name with a C<#> character). An exclamation
point (C<!>) indicates a tag that is considered I<Unsafe> to write under
normal circumstances.  These tags are not written unless specified
explicitly (ie. not when wildcards or "all" are used), and care should be
taken when editing them manually since they may affect the way an image is
rendered.  An asterisk (C<*>) indicates a I<Protected> tag which is not
writable directly, but is written automatically by ExifTool (often when a
corresponding L<Composite|Image::ExifTool::TagNames/Composite Tags> or
L<Extra|Image::ExifTool::TagNames/Extra Tags> tag is written). A colon
(C<:>) indicates a I<Mandatory> tag which may be added automatically when
writing (use the API L<NoMandatory|../ExifTool.html#NoMandatory> option to avoid creating mandatory EXIF
tags).  Normally MakerNotes tags may not be deleted individually, but a
caret (C<^>) indicates a I<Deletable> MakerNotes tag.

The HTML version of these tables also lists possible B<Values> for
discrete-valued tags, as well as B<Notes> for some tags.  The B<Values> are
listed with the computer-readable values on the left of the equals sign
(C<=>), and the human-readable values on the right.  The human-readable
values are used by default when reading and writing, but the
computer-readable values may be accessed by disabling the value conversion
with the -n option on the command line, by setting the L<PrintConv|../ExifTool.html#PrintConv> option to 0
in the API, or or on a per-tag basis by adding a hash (C<#>) after the tag
name.

B<Note>: If you are familiar with common meta-information tag names, you may
find that some ExifTool tag names are different than expected.  The usual
reason for this is to make the tag names more consistent across different
types of meta information.  To determine a tag name, either consult this
documentation or run C<exiftool -s> on a file containing the information in
question.

I<(This documentation is the result of decades of research, testing and
reverse engineering, and is the most complete metadata tag list available
anywhere on the internet.  It is provided not only for ExifTool users, but
more importantly as a public service to help augment the collective
knowledge, and is often used as a primary source of information in the
development of other metadata software.  Please help keep this documentation
as accurate and complete as possible, and feed any new discoveries back to
ExifTool.  A big thanks to everyone who has helped with this so far!)>
]],
    EXIF = '\n' .. [[
EXIF stands for "Exchangeable Image File Format".  This type of information
is formatted according to the TIFF specification, and may be found in JPG,
TIFF, PNG, JP2, PGF, MIFF, HDP, PSP and XCF images, as well as many
TIFF-based RAW images, and even some AVI and MOV videos.

The EXIF meta information is organized into different Image File Directories
(IFD's) within an image.  The names of these IFD's correspond to the
ExifTool family 1 group names.  When writing EXIF information, the default
B<Group> listed below is used unless another group is specified.

Mandatory tags (indicated by a colon after the B<Writable> type) may be
added automatically with default values when creating a new IFD, and the IFD
is removed automatically when deleting tags if only default-valued mandatory
tags remain.

The table below lists all EXIF tags.  Also listed are TIFF, DNG, HDP and
other tags which are not part of the EXIF specification, but may co-exist
with EXIF tags in some images.  Tags which are part of the EXIF 3.1
specification have an underlined B<Tag Name> in the HTML version of this
documentation.  See
L<https://www.cipa.jp/std/documents/download_e.html?CIPA_DC-008-2026-E>
for the official EXIF 3.1 specification.
]],
    GPS = '\n' .. [[
These GPS tags are part of the EXIF standard, and are stored in a separate
IFD within the EXIF information.

ExifTool is very flexible about the input format when writing lat/long
coordinates, and will accept from 1 to 3 floating point numbers (for decimal
degrees, degrees and minutes, or degrees, minutes and seconds) separated by
just about anything, and will format them properly according to the EXIF
specification.

Some GPS tags have values which are fixed-length strings. For these, the
indicated string lengths include a null terminator which is added
automatically by ExifTool.  Remember that the descriptive values are used
when writing (eg. 'Above Sea Level', not '0') unless the print conversion is
disabled (with '-n' on the command line or the L<PrintConv|../ExifTool.html#PrintConv> option in the API,
or by suffixing the tag name with a C<#> character).

When adding GPS information to an image, it is important to set all of the
following tags: GPSLatitude, GPSLatitudeRef, GPSLongitude, GPSLongitudeRef,
and GPSAltitude and GPSAltitudeRef if the altitude is known.  ExifTool will
write the required GPSVersionID tag automatically if new a GPS IFD is added
to an image.
]],
    XMP = '\n' .. [[
XMP stands for "Extensible Metadata Platform", an XML/RDF-based metadata
format which is being pushed by Adobe.  Information in this format can be
embedded in many different image file types including JPG, JP2, TIFF, GIF,
EPS, PDF, PSD, IND, INX, PNG, DJVU, SVG, PGF, MIFF, XCF, CRW, DNG and a
variety of proprietary TIFF-based RAW images, as well as MOV, AVI, ASF, WMV,
FLV, SWF and MP4 videos, and WMA and audio formats supporting ID3v2
information.

The XMP B<Tag ID>'s aren't listed because in most cases they are identical
to the B<Tag Name> (aside from differences in case).  Tags with different
ID's are mentioned in the B<Notes> column of the HTML version of this
document.

All XMP information is stored as character strings.  The B<Writable> column
specifies the information format:  C<string> is an unformatted string,
C<integer> is a string of digits (possibly beginning with a '+' or '-'),
C<real> is a floating point number, C<rational> is entered as a floating
point number but stored as two C<integer> strings separated by a '/'
character, C<date> is a date/time string entered in the format "YYYY:mm:dd
HH:MM:SS[.ss][+/-HH:MM]" but some partial date/time formats are also
accepted (see L<https://exiftool.org/faq.html#Q5>), C<boolean> is either
"True" or "False" (but "true" and "false" may be written as a ValueConv
value for compatibility with non-conforming applications), C<struct>
indicates a structured tag, and C<lang-alt> is a tag that supports alternate
languages.

When reading, C<struct> tags are extracted only if the L<Struct|../ExifTool.html#Struct> (-struct)
option is used.  Otherwise the corresponding I<Flattened> tags, indicated by
an underline (C<_>) after the B<Writable> type, are extracted.  When
copying, by default both structured and flattened tags are available, but
the flattened tags are considered "unsafe" so they aren't copied unless
specified explicitly.  The L<Struct|../ExifTool.html#Struct> option may be disabled by setting Struct
to 0 via the API or with --struct on the command line to copy only flattened
tags, or enabled by setting Struct to 1 via the API or with -struct on the
command line to copy only as structures.  When writing, the L<Struct|../ExifTool.html#Struct> option
has no effect, and both structured and flattened tags may be written.  See
L<https://exiftool.org/struct.html> for more details.

Individual languages for C<lang-alt> tags are accessed by suffixing the tag
name with a '-', followed by an RFC 3066 language code (eg. "XMP:Title-fr",
or "Rights-en-US").  (See L<http://www.ietf.org/rfc/rfc3066.txt> for the RFC
3066 specification.)  A C<lang-alt> tag with no language code accesses the
"x-default" language, but causes other languages for this tag to be deleted
when writing.  The "x-default" language code may be specified when writing
to preserve other existing languages (eg. "XMP-dc:Description-x-default").
When reading, "x-default" is not specified.

The XMP tags are organized according to schema B<Namespace> in the following
tables.  The ExifTool family 1 group names are derived from the namespace
prefixes by adding a leading "XMP-" (eg. "XMP-dc").  A few of the longer
prefixes have been shortened (as mentioned in the documentation below) to
avoid excessively long ExifTool group names.  The tags of any namespace may
be deleted as a group by specifying the family 1 group name (eg.
"-XMP-dc:all=" on the command line).  This includes namespaces which are not
pre-defined by ExifTool.

In cases where a tag name exists in more than one namespace, less common
namespaces are avoided when writing.  However, a specific namespace may be
written by providing a family 1 group name for the tag (eg. XMP-crs:Contrast
or XMP-exif:Contrast).  When deciding on which tags to add to an image,
using standard schemas such as L<dc|/XMP dc Tags>, L<xmp|/XMP xmp Tags>,
L<iptcCore|/XMP iptcCore Tags> and L<iptcExt|/XMP iptcExt Tags> is
recommended if possible.

For structures, the heading of the first column is B<Field Name>.  Field
names are very similar to tag names, except they are used to identify fields
inside structures instead of stand-alone tags.  See
L<the Field Name section of the Structured Information documentation|https://exiftool.org/struct.html#Fields> for more
details.

ExifTool will extract XMP information even if it is not listed in these
tables, but other tags are not writable unless added as user-defined tags in
the L<ExifTool config file|../config.html>.  For example, the C<pdfx> namespace doesn't have a
predefined set of tag names because it is used to store application-defined
PDF information, so although this information will be extracted, it is only
writable if the corresponding user-defined tags have been created.

The tables below list tags from the official XMP specification (with an
underlined B<Namespace> in the HTML version of this documentation), as well
as extensions from various other sources.  See
L<http://www.adobe.com/devnet/xmp/> for the official XMP specification.
]],
    IPTC = '\n' .. [[
The tags listed below are part of the International Press Telecommunications
Council (IPTC) and the Newspaper Association of America (NAA) Information
Interchange Model (IIM).  This is an older meta information format, slowly
being phased out in favor of XMP -- the newer IPTCCore specification uses
XMP format.  IPTC information may be found in JPG, TIFF, PNG, MIFF, PS, PDF,
PSD, XCF and DNG images.

IPTC information is separated into different records, each of which has its
own set of tags.  See
L<http://www.iptc.org/std/IIM/4.1/specification/IIMV4.1.pdf> for the
official IPTC IIM specification.

This specification dictates a length for ASCII (C<string> or C<digits>) and
binary (C<undef>) values.  These lengths are given in square brackets after
the B<Writable> format name.  For tags where a range of lengths is allowed,
the minimum and maximum lengths are separated by a comma within the
brackets.  When writing, ExifTool issues a minor warning and truncates the
value if it is longer than allowed by the IPTC specification.  Minor errors
may be ignored with the L<IgnoreMinorErrors|../ExifTool.html#IgnoreMinorErrors> (-m) option, allowing longer
values to be written, but beware that values like this may cause problems
for some other IPTC readers. ExifTool will happily read IPTC values of any
length.

Separate IPTC date and time tags may be written with a combined date/time
value and ExifTool automagically takes the appropriate part of the date/time
string depending on whether a date or time tag is being written.  This is
very useful when copying date/time values to IPTC from other metadata
formats.

IPTC time values include a timezone offset.  If written with a value which
doesn't include a timezone then the current local timezone offset is used
(unless written with a combined date/time, in which case the local timezone
offset at the specified date/time is used, which may be different due to
changes in daylight savings time).

Note that it is not uncommon for IPTC to be found in non-standard locations
in JPEG and TIFF-based images.  When reading, the family 1 group name has a
number added for non-standard IPTC ("IPTC2", "IPTC3", etc), but when writing
only "IPTC" may be specified as the group.  To keep the IPTC consistent,
ExifTool updates tags in all existing IPTC locations, but will create a new
IPTC group only in the standard location.
]],
    QuickTime = '\n' .. [[
The QuickTime format is used for many different types of audio, video and
image files (most notably, MOV/MP4 videos and HEIC/CR3 images).  ExifTool
extracts standard meta information and a variety of audio, video and image
parameters, as well as proprietary information written by many camera
models.  Tags with a question mark after their name are not extracted unless
the L<Unknown|../ExifTool.html#Unknown> option is set.

When writing video files, ExifTool creates both QuickTime and XMP tags by
default, but the group may be specified to write one or the other
separately.  If no location is specified, newly created QuickTime tags are
added in the L<ItemList|Image::ExifTool::TagNames/QuickTime ItemList Tags>
location if possible, otherwise in
L<UserData|Image::ExifTool::TagNames/QuickTime UserData Tags>, and
finally in L<Keys|Image::ExifTool::TagNames/QuickTime Keys Tags>,
but this order may be changed by setting the PREFERRED level of the
appropriate table in the config file (see
L<example.config|../config.html#PREF> in the full distribution for an
example).  Note that some tags with the same name but different ID's may
exist in the same location, but the family 7 group names may be used to
differentiate these.

ExifTool currently writes
L<ItemList|Image::ExifTool::TagNames/QuickTime ItemList Tags> and
L<UserData|Image::ExifTool::TagNames/QuickTime UserData Tags> only as
top-level metadata, but select Keys tags are may be written to the audio or
video track.  See the
L<AudioKeys|Image::ExifTool::TagNames/QuickTime AudioKeys Tags> and
L<VideoKeys|Image::ExifTool::TagNames/QuickTime VideoKeys Tags> tags for
more information.

Alternate language tags may be accessed for
L<ItemList|Image::ExifTool::TagNames/QuickTime ItemList Tags> and
L<Keys|Image::ExifTool::TagNames/QuickTime Keys Tags> tags by adding
a 3-character ISO 639-2 language code and an optional ISO 3166-1 alpha 2
country code to the tag name (eg. "ItemList:Artist-deu" or
"ItemList::Artist-deu-DE").  Most
L<UserData|Image::ExifTool::TagNames/QuickTime UserData Tags> tags support a
language code, but without a country code.  If no language code is specified
when writing, the default language is written and alternate languages for
the tag are deleted.  Use the "und" language code to write the default
language without deleting alternate languages.  Note that when reading,
"eng" is also treated as the default language if there is no country code.

According to the specification, integer-format QuickTime date/time tags
should be stored as UTC.  Unfortunately, digital cameras often store local
time values instead (presumably because they don't know the time zone).  For
this reason, by default ExifTool does not assume a time zone for these
values.  However, if the API L<QuickTimeUTC|../ExifTool.html#QuickTimeUTC> option is set, then ExifTool will
assume these values are properly stored as UTC, and will convert them to
local time when extracting.

When writing string-based date/time tags, the system time zone is added if
the L<PrintConv|../ExifTool.html#PrintConv> option is enabled and no time zone is specified.  This is
because Apple software may display crazy values if the time zone is missing
for some tags.

By default ExifTool will remove null padding from some QuickTime containers
in Canon CR3 files when writing, but the
L<QuickTimePad|../ExifTool.html#QuickTimePad> option may be used to preserve
the original size by padding with nulls if necessary.

See
L<https://developer.apple.com/library/archive/documentation/QuickTime/QTFF/>
for the official QuickTime specification.
]],
    Photoshop = '\n' .. [[
Photoshop tags are found in PSD and PSB files, as well as inside embedded
Photoshop information in many other file types (JPEG, TIFF, PDF, PNG to name
a few).

Many Photoshop tags are marked as Unknown (indicated by a question mark
after the tag name) because the information they provide is not very useful
under normal circumstances.  These unknown tags are not extracted unless the
L<Unknown|../ExifTool.html#Unknown> (-u) option is used.  See
L<http://www.adobe.com/devnet-apps/photoshop/fileformatashtml/> for the
official specification

Photoshop path tags (Tag ID's 0x7d0 to 0xbb5) are not defined by default,
but a config file included in the full ExifTool distribution
(config_files/photoshop_paths.config) contains the tag definitions to allow
access to this information.
]],
    PrintIM = '\n' .. [[
The format of the PrintIM information is known, however no PrintIM tags have
been decoded.  Use the L<Unknown|../ExifTool.html#Unknown> (-u) option to extract PrintIM information.
]],
    GeoTiff = '\n' .. [[
ExifTool extracts the following tags from GeoTIFF images.  See
L<https://web.archive.org/web/20070820121549/http://www.remotesensing.org/geotiff/spec/geotiffhome.html>
for the complete GeoTIFF specification.  Also included in the table below
are ChartTIFF tags (see
L<https://web.archive.org/web/20020828193928/http://www.charttiff.com/whitepapers.shtml>).
GeoTIFF tags are not writable individually, but they may be copied en mass
via the block tags GeoTiffDirectory, GeoTiffDoubleParams and
GeoTiffAsciiParams.
]],
    JFIF = '\n' .. [[
The following information is extracted from the JPEG JFIF header.  See
L<https://www.w3.org/Graphics/JPEG/jfif3.pdf> for the JFIF 1.02
specification.
]],
    Kodak = '\n' .. [[
Many Kodak models don't store the maker notes in standard IFD format, and
these formats vary with different models.  Some information has been
decoded, but much of the Kodak information remains unknown.
]],
    ['Kodak SpecialEffects'] = '\n' .. [[
The Kodak SpecialEffects and Borders tags are found in sub-IFD's within the
Kodak JPEG APP3 "Meta" segment.
]],
    Minolta = '\n' .. [[
These tags are used by Minolta, Konica/Minolta as well as some Sony cameras.
Minolta doesn't make things easy for decoders because the meaning of some
tags and the location where some information is stored is different for
different camera models.  (Take MinoltaQuality for example, which may be
located in 5 different places.)
]],
    Olympus = '\n' .. [[
Tags 0x0000 through 0x0103 are used by some older Olympus cameras, and are
the same as Konica/Minolta tags.  These tags are also used for some models
from other brands such as Acer, BenQ, Epson, Hitachi, HP, Maginon, Minolta,
Pentax, Ricoh, Samsung, Sanyo, SeaLife, Sony, Supra and Vivitar.
]],
    Panasonic = '\n' .. [[
These tags are used in Panasonic/Leica cameras.
]],
    Pentax = '\n' .. [[
These tags are used in Pentax/Asahi/Ricoh cameras.
]],
    CanonRaw = '\n' .. [[
These tags apply to CRW-format Canon RAW files and information in the APP0
"CIFF" segment of JPEG images.  When writing CanonRaw/CIFF information, the
length of the information is preserved (and the new information is truncated
or padded as required) unless B<Writable> is C<resize>. Currently, only
JpgFromRaw and ThumbnailImage are allowed to change size.  See
L<https://exiftool.org/canon_raw.html> for a description of the Canon CRW
format.

CRW images also support the addition of a CanonVRD trailer, which in turn
supports XMP.  This trailer is created automatically if necessary when
ExifTool is used to write XMP to a CRW image.
]],
    NikonCustom = '\n' .. [[
Unfortunately, the NikonCustom settings are stored in a binary data block
which changes from model to model.  This means that significant effort must
be spent in decoding these for each model, usually requiring hundreds of
test images from a dedicated Nikon owner.  For this reason, the NikonCustom
settings have not been decoded for all models.  The tables below list the
custom settings for the currently supported models.
]],
    Unknown = '\n' .. [[
The following tags are decoded in unsupported maker notes.  Use the L<Unknown|../ExifTool.html#Unknown>
(-u) option to display other unknown tags.
]],
    PDF = '\n' .. [[
The tags listed in the PDF tables below are those which are used by ExifTool
to extract meta information, but they are only a small fraction of the total
number of available PDF tags.  See
L<http://www.adobe.com/devnet/pdf/pdf_reference.html> for the official PDF
specification.

ExifTool supports reading and writing PDF documents up to version 2.0,
including support for RC4, AES-128 and AES-256 encryption.  A
L<Password|../ExifTool.html#Password> option is provided to allow processing
of password-protected PDF files.

ExifTool may be used to write native PDF and XMP metadata to PDF files. It
uses an incremental update technique that has the advantages of being both
fast and reversible.  If ExifTool was used to modify a PDF file, the
original may be recovered by deleting the C<PDF-update> pseudo-group (with
C<-PDF-update:all=> on the command line).  However, there are two main
disadvantages to this technique:

1) A linearized PDF file is no longer linearized after the update, so it
must be subsequently re-linearized if this is required.

2) All metadata edits are reversible.  While this would normally be
considered an advantage, it is a potential security problem because old
information is never actually deleted from the file.  (However, after
running ExifTool the old information may be removed permanently using the
"qpdf" utility with this command: "qpdf --linearize in.pdf out.pdf".)
]],
    DNG = '\n' .. [[
The main DNG tags are found in the EXIF table.  The tables below define only
information found within structures of these main DNG tag values.  See
L<https://helpx.adobe.com/camera-raw/digital-negative.html> for the official
DNG specification.
]],
    MPEG = '\n' .. [[
The MPEG format doesn't specify any file-level meta information.  In lieu of
this, information is extracted from the first audio and video frame headers
in the file.
]],
    Real = '\n' .. [[
ExifTool recognizes three basic types of Real audio/video files: 1)
RealMedia (RM, RV and RMVB), 2) RealAudio (RA), and 3) Real Metafile (RAM
and RPM).
]],
    Extra = '\n' .. [[
The extra tags provide extra features or extra information extracted or
generated by ExifTool that is not directly associated with another tag
group.  The B<Group> column lists the family 1 group name when reading.
Tags with a "-" in this column are write-only.

Tags in the family 1 "System" group are referred to as "pseudo" tags because
they don't represent real metadata in the file.  Instead, this information
is stored in the directory structure of the filesystem.  The B<Writable>
System "pseudo" tags in this table may be written without modifying the file
itself.  The TestName tag is used for dry-run testing before writing
FileName.
]],
    Composite = '\n' .. [[
The values of the composite tags are B<Derived From> the values of other
tags.  These are convenience tags which are calculated after all other
information is extracted.  Only a few of these tags are writable directly,
the others are changed by writing the corresponding B<Derived From> tags.
User-defined Composite tags, also useful for custom-formatting of tag
values, may created via the L<ExifTool configuration file|../config.html>.
]],
    Shortcuts = '\n' .. [[
Shortcut tags are convenience tags that represent one or more other tag
names.  They are used like regular tags to read and write the information
for a specified set of tags.

The shortcut tags below have been pre-defined, but user-defined shortcuts
may be added via the %Image::ExifTool::UserDefined::Shortcuts lookup in the
~/.ExifTool_config file.  See the Image::ExifTool::Shortcuts documentation
for more details.
]],
    MWG = '\n' .. [[
The Metadata Working Group (MWG) recommends techniques to allow certain
overlapping EXIF, IPTC and XMP tags to be reconciled when reading, and
synchronized when writing.  The MWG Composite tags below are designed to aid
in the implementation of these recommendations.  As well, the MWG defines
new XMP tags which are listed in the subsequent tables below.  See
L<https://web.archive.org/web/20180919181934/http://www.metadataworkinggroup.org/pdf/mwg_guidance.pdf>
for the official MWG specification.
]],
    MacOS = '\n' .. [[
On MacOS systems, the there are additional MDItem and XAttr Finder tags that
may be extracted.  These tags are not extracted by default -- they must be
specifically requested or enabled via an API option.  (Except when reading
MacOS "._" files directly, see below.)

The tables below list some of the tags that may be extracted, but ExifTool
will extract all available information even for tags not listed.

Tags in these tables are referred to as "pseudo" tags because their
information is not stored in the file itself.  As such, B<Writable> tags in
these tables may be changed without having to rewrite the file.
]],
    GM = '\n' .. [[
These tags are extracted from GM/Cosworth PDR (Performance Data Recorder)
information found in videos from General Motors cars such as Corvette and
Camero.

Use the API L<PrintCSV|../ExifTool.html#PrintCSV> option to output all timed
PDR data in CSV format at greatly increased speed and with much lower memory
usage.  This option prints the numerical values for each channel in CSV
format, suitable for import into RaceRender.  In this output, the gear
numbers for Neutral and Reverse are changed to -1 and -100 respectively for
compatibility with RaceRender.
]],
    PodTrailer = '\n' .. [[
~head1 NOTES

This document generated automatically by
L<Image::ExifTool::BuildTagLookup|Image::ExifTool::BuildTagLookup>.

~head1 AUTHOR

Copyright 2003-2026, Phil Harvey (philharvey66 at gmail.com)

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

~head1 SEE ALSO

L<Image::ExifTool(3pm)|Image::ExifTool>

~cut
]],
}

-- notes for Shortcuts tags
local shortcutNotes = {
    AllDates = [[
        contrary to the shortcut name, this represents only the common EXIF
        date/time tags.  To access all date/time tags, use Time:All instead
    ]],
    MakerNotes = [[
        useful when copying tags between files to either copy the maker notes as a
        block or prevent it from being copied
    ]],
    ColorSpaceTags = [[
        standard tags which carry color space information.  Useful for preserving
        color space when deleting all other metadata
    ]],
    CommonIFD0 = [[
        common metadata tags found in IFD0 of TIFF-format images.  Used to simplify
        deletion of all metadata from these images.  See
        L<FAQ number 7|../faq.html#Q7> for details
    ]],
    Unsafe = [[
        I<Unsafe> tags in JPEG images which are normally not copied.  Defined here
        as a shortcut to use when rebuilding JPEG EXIF from scratch. See
        L<FAQ number 20|../faq.html#Q20> for more information
    ]],
    LargeTags = [[
        large binary data tags which may be excluded to reduce memory usage if
        memory limitations are a problem
    ]],
   ['ls-l'] = [[
        mimics columns shown by Unix "ls -l" command.  Includes some tags which are
        extracted only if the API L<SystemTags|../ExifTool.html#SystemTags> option
        is enabled
    ]],
}

-- lookup for RIFF INFO tags which are found in the EXIF spec
local riffSpec = {
    IARL = 1,  ICRD = 1,  IGNR = 1,  IPLT = 1,  ISRC = 1,
    IART = 1,  ICRP = 1,  IKEY = 1,  IPRD = 1,  ISRF = 1,
    ICMS = 1,  IDIM = 1,  ILGT = 1,  ISBJ = 1,  ITCH = 1,
    ICMT = 1,  IDPI = 1,  IMED = 1,  ISFT = 1,
    ICOP = 1,  IENG = 1,  INAM = 1,  ISHP = 1,
}
-- same thing for XMP namespaces
local xmpSpec = {
    aux       = 1,   ['x']      = 1,
    crs       = 1,    xmp       = 1,
    dc        = 1,    xmpBJ     = 1,
    exif      = 1,    xmpDM     = 1,
    pdf       = 1,    xmpMM     = 1,
    pdfx      = 1,    xmpNote   = 1,
    photoshop = 1,    xmpRights = 1,
    tiff      = 1,    xmpTPg    = 1,
}

--------------------------------------------------------------------------------
-- New - create new BuildTagLookup object
-- Inputs: 0) reference to BuildTagLookup object or BuildTagLookup class name
function BuildTagLookup.new(that) -- luacheck: ignore 212
    local self = setmetatable({ }, { __index = BuildTagLookup })
    local subdirs, isShortcut = { }, { }
    local count_h = {
        ['unique tag names'] = 0,
        ['total tags'] = 0,
    }
--
-- loop through all tables, accumulating TagLookup and TagName information
--
    local tagNameInfo, id_h, longID, longName, shortName, tableNum_h = { }, { }, { }, { }, { }, { }
    local tagLookup, tagExists, noLookup, tableWritable, sepTable, case = { }, { }, { }, { }, { }, { }
    local structs, compositeModules, isPlugin_h, flattened, structLookup = { }, { }, { }, { }, { }
    local writePseudo, dupXmpTag = { }, { }
    self.TAG_NAME_INFO = tagNameInfo
    self.ID_LOOKUP = id_h
    self.LONG_ID = longID
    self.LONG_NAME = longName
    self.SHORT_NAME = shortName
    self.TABLE_NUM = tableNum_h
    self.TAG_LOOKUP = tagLookup
    self.TAG_EXISTS = tagExists
    self.FLATTENED = flattened
    self.TABLE_WRITABLE = tableWritable
    self.SEPARATE_TABLE = sepTable
    self.STRUCTURES = structs
    self.STRUCT_LOOKUP = structLookup  -- lookup for Struct hash ref based on Struct name
    self.COMPOSITE_MODULES = compositeModules
    self.COUNT = count_h
    self.WRITE_PSEUDO = writePseudo

    Writer.LoadAllTables()
    local tableNames = perl.sort(allTablesKeys())
    -- add Shortcuts after other tables
    tableNames[#tableNames + 1] = 'Image::ExifTool::Shortcuts::Main'
    -- add plug-in modules last
    for _, plugin in ipairs(pluginTables) do
        tableNames[#tableNames + 1] = plugin
        isPlugin_h[plugin] = 1
    end

    local tableNum = 0
    local et = ExifTool.new()
    local tableName, tag
    -- create lookup for short table names
    for _, tn in ipairs(tableNames) do
        tableName = tn
        local short = tableName
        short = subst(short, [[^Image::ExifTool::]], '')
        short = subst(short, [[::Main$]], '')
        short = subst(short, [[::]], ' ')
        if short ~= 'Nikon AVITags' then short = subst(short, [[^(.+)Tags$]], function(s) return ucfirst(s) end) end
        short = subst(short, [[^Exif\b]], 'EXIF')
        -- change underlines to dashes in XMP-mwg group names
        -- (we used underlines just because Perl variables can't contain dashes)
        short = subst(short, [[^XMP mwg_]], 'XMP mwg-')
        shortName[tableName] = short    -- remember short name
        tableNum_h[tableName] = tableNum; tableNum = tableNum + 1
    end
    -- validate DICOM UID values
    for _, v in pairs(require('lexiftool.DICOM').uid) do
        if isMatch(v, [=[[\0-\x1f\x7f-\xff]]=]) then
            warn('Warning: Special characters in DICOM UID value (' .. v .. ")\n")
        end
    end
    -- make lookup table to check for shortcut tags
    for t in pairs(Shortcuts.Main) do
        tag = t
        local entry = Shortcuts.Main[tag]
        -- ignore if shortcut tag name includes itself
        local includesItself
        if type(entry) == 'table' then
            for _, e in ipairs(entry) do
                if isMatchDyn(e, '^' .. tag .. '$') then includesItself = true break end
            end
        end
        if not includesItself then isShortcut[lc(tag)] = 1 end
    end
    for _, tn in ipairs(tableNames) do
        tableName = tn
        -- create short table name
        local short = shortName[tableName]
        local info = { }
        tagNameInfo[tableName] = info
        local isPlugin = isPlugin_h[tableName]
        local table_, shortcut
        local isOffset, datamember, hasSubdir = { }, { }, { }
        if short == 'Shortcuts' then
            -- can't use GetTagTable() for Shortcuts (not a normal table)
            table_ = Shortcuts.Main
            shortcut = 1
        elseif isPlugin then
            table_ = GetTagTable(tableName)
            -- don't add to allTables list because this messes our table order
            ExifTool.GetAllTables()[LuaTableName(tableName)] = nil
            remove(ExifTool.tableOrder)
        else
            table_ = GetTagTable(tableName)
        end
        local tableNum = tableNum_h[tableName] -- luacheck: ignore 421
        local writeProc = table_.WRITE_PROC
        local vars = table_.VARS or { }
        longID[tableName] = 0
        longName[tableName] = 0
        -- save all tag names
        local binaryTable, noID, prtID, isIPTC, isXMP
        if writeProc and writeProc == IPTC.WriteIPTC then isIPTC = 1 end
        -- generate flattened tag names for structure fields if this is an XMP table
        if table_.GROUPS and table_.GROUPS[0] == 'XMP' or vars.ADD_FLATTENED then
            XMP.AddFlattenedTags(table_)
            isXMP = 1
        end
        prtID = vars.ID_FMT
        if isXMP or isMatch(short, [[^(Shortcuts|ASF.*)$]]) or prtID and prtID == 'none' then noID = 1 end
        if table_.WRITE_PROC and table_.WRITE_PROC == Writer.WriteBinaryData
            and not table_.CHECK_PROC
        then
            warn('Binary table ' .. tableName .. " doesn't have a CHECK_PROC\n")
        end
        local processBinaryData = (table_.PROCESS_PROC and (
            table_.PROCESS_PROC == ExifTool.ProcessBinaryData or
            table_.PROCESS_PROC == Nikon.ProcessNikonEncrypted or
            table_.PROCESS_PROC == Sony.ProcessEnciphered) or
            table_.VARS and perlTruthy(table_.VARS.IS_BINARY))
        if vars.ID_LABEL or processBinaryData then
            local s = table_.FORMAT and (ExifTool.FormatSize(table_.FORMAT) or 1) or 1
            binaryTable = 1
            id_h[tableName] = vars.ID_LABEL or ('Index' .. s)
        elseif isIPTC and table_.PROCESS_PROC then -- only the main IPTC table has a PROCESS_PROC
            id_h[tableName] = 'Record'
        elseif not noID then
            id_h[tableName] = 'Tag ID'
        end
        caseInsensitive = isXMP
        numbersFirst = 2
        if table_.VARS and table_.VARS.ALPHA_FIRST then numbersFirst = -1 end
        local keys = SortedTagTableKeys(table_)
        numbersFirst = 1
        local defFormat = table_.FORMAT
        -- use default format for binary data tables
        if not defFormat and binaryTable then defFormat = 'int8u' end

        for _, key in ipairs(keys) do -- (TagID:)
            local tagID = key
            local tagInfo, tagNames, values = nil, { }, { } -- luacheck: ignore 311
            local infoArray, require_a, writeGroup_a, writable_a = nil, { }, { }, { } -- luacheck: ignore 311
            if shortcut then
                -- must build a dummy tagInfo list since Shortcuts is not a normal table
                tagInfo = {
                    Name = tagID,
                    Notes = shortcutNotes[tagID],
                    Writable = 1,
                    Require = { },
                }
                local i = 0
                while i < #table_[tagID] do
                    tagInfo.Require[i] = table_[tagID][i + 1]
                    i = i + 1
                end
                infoArray = { tagInfo }
            else
                infoArray = GetTagInfoList(table_, tagID)
            end
            for _, ti in ipairs(infoArray) do
                tagInfo = ti
                if binaryTable and perlTruthy(tagInfo.Writable) and keyStr(tagInfo.Writable) ~= '1' then
                    warn(tableName .. ' ' .. tagInfo.Name .. ' Writable should be 1, not ' .. keyStr(tagInfo.Writable) .. "\n")
                end
                local name = tagInfo.Name
                if tagInfo.WritePseudo then
                    writePseudo[#writePseudo + 1] = name
                    if not tagInfo.Protected then warn('Writable pseudo tag ' .. name .. " is not protected!\n") end
                end
                if not (tagInfo.SubDirectory or tagInfo.Struct) then
                    local lcn = lc(name)
                    if case[lcn] and case[lcn] ~= name then warn('Different case for ' .. tableName .. ' ' .. name .. ' ' .. case[lcn] .. "\n") end
                    case[lcn] = name
                end
                local format = tagInfo.Format
                -- check TagID's to make sure they don't start with 'ID-'
                local grps = et:GetGroup(tagInfo)
                for f = 0, #grps do
                    if isMatch(grps[f], [[(?i)^ID-]]) then warn("Group name starts with 'ID-' for " .. short .. ' ' .. name .. "\n") end
                end
                if isXMP and not perlTruthy(tagInfo.Avoid) and not tagInfo.Struct and
                    (perlTruthy(tagInfo.Writable) or perlTruthy(table_.WRITABLE))
                then
                    if dupXmpTag[name] then warn('Duplicate writable XMP tag ' .. name .. "\n") end
                    dupXmpTag[name] = 1
                end
                -- validate Name (must not start with a digit or else XML output will not be valid;
                -- must not start with a dash or exiftool command line may get confused)
                if not isMatch(name, [[^[_A-Za-z][-\w]+$]]) and
                    -- single-character subdirectory names are allowed
                    (not tagInfo.SubDirectory or not isMatch(name, [[^[_A-Za-z]$]]))
                then
                    warn('Warning: Invalid tag name ' .. short .. " '" .. name .. "'\n")
                end
                -- validate list type
                if perlTruthy(tagInfo.List) and not isMatch(keyStr(tagInfo.List), [[^(1|Alt|Bag|Seq|array|string)$]]) then
                    warn('Warning: Unknown List type (' .. keyStr(tagInfo.List) .. ') for ' .. name .. ' in ' .. tableName .. "\n")
                end
                if tagInfo.Hook and perlTruthy(tagInfo.Unknown) then
                    warn('Warning: Unknown tag with Hook - ' .. short .. ' ' .. name .. "\n")
                end
                -- accumulate information for consistency check of BinaryData tables
                if processBinaryData and perlTruthy(table_.WRITABLE) then
                    -- can't currently write tag if Condition accesses $valPt
                    if tagInfo.Condition and not tagInfo.SubDirectory and
                        type(tagInfo.Condition) == 'string' and isMatch(tagInfo.Condition, [[\$valPt]]) and
                        (perlTruthy(tagInfo.Writable) or tagInfo.Writable == nil)
                    then
                        warn('Warning: Tag not writable due to Condition - ' .. short .. ' ' .. name .. "\n")
                    end
                    if tagInfo.IsOffset then isOffset[tagID] = name end
                    if tagInfo.SubDirectory then hasSubdir[tagID] = name end
                    -- require DATAMEMBER for writable var-format tags, Hook and DataMember tags
                    if type(format) == 'string' and isMatch(format, [[^var_]]) then
                        datamember[tagID] = name
                        if not (tagInfo.Writable ~= nil and not perlTruthy(tagInfo.Writable)) then
                            warn('Warning: Var-format tag is writable - ' .. short .. ' ' .. name .. "\n")
                        end
                        -- also need DATAMEMBER for tags used in length of var-sized value
                        for idStr in eachMatch(format, [[\$val\{(.*?)\}]]) do
                            local id = idStr
                            if isMatch(id, [[^0x]]) then id = hex(id) end -- convert from hex if necessary
                            id = tonumber(id) or id
                            if type(table_[id]) == 'table' and table_[id][1] == nil then datamember[id] = table_[id].Name end
                            if not datamember[id] then
                                warn('Warning: Unknown ID (' .. keyStr(id) .. ') used in Format - ' .. short .. ' ' .. name .. "\n")
                            end
                        end
                    elseif tagInfo.Hook or (type(tagInfo.RawConv) == 'string' and
                             isMatch(tagInfo.RawConv, [[\$self(->)?\{\w+\}\s*=(?!~)]])) or
                             -- (a RawConv that is a Lua function cannot be
                             --  searched for `$self{...} =`: the table's own
                             --  DATAMEMBER entry is taken at its word)
                             (type(tagInfo.RawConv) == 'function' and DataMember(table_, tagID))
                    then
                        datamember[tagID] = name
                    end
                    if type(format) == 'string' and isMatch(format, [[\$val\{]]) and
                        (perlTruthy(tagInfo.Writable) or tagInfo.Writable == nil)
                    then
                        warn('Warning: $val{} used in Format of writable tag - ' .. short .. ' ' .. name .. "\n")
                    end
                end
                if perlTruthy(tagInfo.Hidden) then
                    if keyStr(tagInfo.Hidden) ~= '2' and not perlTruthy(tagInfo.Unknown) and
                        (not tagInfo.RawConv or type(tagInfo.RawConv) == 'string' and
                         not isMatch(tagInfo.RawConv, [[Unknown|undef]]))
                    then
                        warn('Warning: ' .. short .. ' ' .. name .. " is Hidden contrary to guidelines\n")
                    end
                    if tagInfo == infoArray[1] then
                        goto nextTagID  -- hide all tags with this ID if first tag in list is hidden
                    else
                        goto nextTagInfo    -- only hide this tag
                    end
                end
                do
                local writable
                if tagInfo.Writable ~= nil then
                    writable = tagInfo.Writable
                    -- validate Writable
                    local okW, w1 = isMatch(keyStr(writable), [[(.*)\[]])
                    if not (formatOK[keyStr(writable)] or  (okW and formatOK[w1])) then
                        warn('Warning: Unknown Writable (' .. keyStr(writable) .. ') - ' .. short .. ' ' .. name .. "\n")
                    end
                elseif not tagInfo.SubDirectory then
                    writable = table_.WRITABLE
                end
                -- in general, we can't write unless we have a WRITE_PROC
                if perlTruthy(writable) and not (table_.WRITE_PROC or isMatch(tableName, [[Shortcuts]]) or keyStr(writable) == '2') then
                    writable = nil
                end
                --if ($writable and $$tagInfo{Unknown} and $$table{GROUPS}{0} ne 'MakerNotes') {
                --    warn "Warning: Writable Unknown tag - $short $name\n";
                --}
                -- validate some characteristics of obvious date/time tags
                local g = et:GetGroup(tagInfo)
                if perlTruthy(tagInfo.List) and g[2] == 'Time' and perlTruthy(writable) and not perlTruthy(tagInfo.Protected) and
                    not tagInfo.PrintConvInv
                then
                    -- (this is a problem because shifting Time:All would create a new list entry)
                    warn('Writable List-type Time tag ' .. g[1] .. ':' .. name .. " has no PrintConvInv and is not Protected!\n")
                end
                if tagInfo.PrintConv and tagInfo.PrintConv == '$self->ConvertDateTime($val)' then
                    if g[2] ~= 'Time' then warn(short .. ' ' .. name .. " should be in 'Time' group!\n") end
                    if perlTruthy(writable) and tagInfo.Shift == nil and short ~= 'PostScript' then
                        warn(short .. ' ' .. name .. " is not shiftable!\n")
                    end
                    if perlTruthy(writable) and (not tagInfo.PrintConvInv or
                        not isMatch(tagInfo.PrintConvInv, [[InverseDateTime]]))
                    then
                        warn(short .. ' ' .. name .. " missing InverseDateTime PrintConvInv\n")
                    end
                elseif isMatch(name, [[DateTime(?!Stamp)]]) and (not (tagInfo.Groups and tagInfo.Groups[2]) or
                    tagInfo.Groups[2] ~= 'Time') and short ~= 'DICOM' then
                    warn(short .. ' ' .. name .. " should be in 'Time' group!\n")
                end
                if name == 'DateTimeOriginal' and (not tagInfo.Description or
                    tagInfo.Description ~= 'Date/Time Original')
                then
                    warn('Need Description for ' .. short .. " DateTimeOriginal\n")
                end
                -- validate Description (can't contain special characters)
                if tagInfo.Description and
                    tagInfo.Description ~= EscapeHTML(tagInfo.Description)
                then
                    -- this is a problem because the Escape option currently only
                    -- escapes descriptions if the default Lang option isn't default
                    warn(name .. " description contains special characters!\n")
                end
                -- generate structure lookup
                local struct = tagInfo.Struct
                local strTable
                if type(struct) == 'table' then
                    strTable = struct
                    struct = strTable.STRUCT_NAME
                    if struct then
                        local oldTable = structLookup[struct]
                        if oldTable and oldTable ~= strTable then
                            warn('Duplicate XMP structure with name ' .. struct .. "\n")
                        else
                            structLookup[struct] = strTable
                        end
                    else
                        warn('Missing STRUCT_NAME for structure in ' .. tagInfo.Name .. "\n")
                        strTable = nil -- luacheck: ignore 311
                    end
                elseif struct then
                    strTable = structLookup[struct]
                    if not strTable then
                        if not isMatch(struct, ' ') then struct = 'XMP ' .. struct end
                        warn('Missing ' .. struct .. " structure!\n")
                        struct = nil
                    end
                end
                -- validate SubIFD flag
                local subdir = tagInfo.SubDirectory
                local isSub = (subdir and type(subdir.Start) == 'string' and isMatch(subdir.Start, [[\$val\b]]))
                -- (a Start expression that is a Lua function cannot be
                --  matched against `$val`: no verdict either way)
                if subdir and type(subdir.Start) == 'function' then -- luacheck: ignore 542
                elseif tagInfo.SubIFD then
                    if not isSub then warn('Warning: Wrong SubDirectory Start for SubIFD tag - ' .. short .. ' ' .. name .. "\n") end
                else
                    if isSub and not processBinaryData then warn('Warning: SubIFD flag not set for ' .. short .. ' ' .. name .. "\n") end
                end
                if tagInfo.Notes then
                    local note = tagInfo.Notes
                    -- remove leading/trailing blank lines
                    note = subst(note, [[^\s+]], ''); note = subst(note, [[\s+$]], '')
                    -- remove leading/trailing spaces on each line
                    note = subst(note, [[(?m)(^[ \t]+|[ \t]+$)]], '', 'g')
                    values[#values + 1] = '(' .. note .. ')'
                end
                if isXMP and (lc(keyStr(tagID)) ~= lc(name) or tagInfo.NotFlat) then
                    local note
                    if tagInfo.NotFlat then
                        note = 'NOT a flattened tag!'
                    else
                        -- add note about different XMP Tag ID
                        note = tagInfo.RootTagInfo and keyStr(tagID) or ("tag ID is '" .. keyStr(tagID) .. "'")
                    end
                    if tagInfo.Notes then
                        values[#values] = subst(values[#values], [[^\(]], function() return '(' .. note .. '; ' end)
                    else
                        values[#values + 1] = '(' .. note .. ')'
                    end
                end
                local writeGroup
                if short == 'Extra' then
                    writeGroup = tagInfo.WriteOnly and '-' or g[1]
                else
                    writeGroup = tagInfo.WriteGroup
                end
                if not writeGroup then
                    if perlTruthy(writable) then writeGroup = table_.WRITE_GROUP end
                    if not writeGroup then writeGroup = '-' end
                end
                if format ~= nil then
                    -- validate Format
                    -- (a Format expression is Lua code in this port, with no
                    --  text to check: such a format passes)
                    local okF, _, f2 = isMatch(keyStr(format), [[^(var_)?(.*)\[]])
                    if not (formatOK[format] or short == 'PICT' or type(format) == 'function' or
                        (okF and formatOK[f2]))
                    then
                        warn('Warning: Unknown Format (' .. format .. ') for ' .. short .. ' ' .. name .. "\n")
                    end
                else
                    format = defFormat
                end
                if subdir then
                    local subTable = subdir.TagTable and PerlTableName(subdir.TagTable) or tableName
                    values[#values + 1] = shortName[subTable]
                elseif struct then
                    values[#values + 1] = struct
                    structs[struct] = 1
                end
                for _, type_ in ipairs({ 'Require', 'Desire' }) do
                    local require = tagInfo[type_] -- luacheck: ignore 421
                    if type(require) == 'table' then
                        for _, k in ipairs(perl.sort(perl.keys(require), function(a, b) return perl.num(a) - perl.num(b) end)) do
                            require_a[#require_a + 1] = require[k]
                        end
                    elseif perlTruthy(require) then
                        require_a[#require_a + 1] = require
                    end
                end
                local printConv = tagInfo.PrintConv
                if perlTruthy(tagInfo.Mask) then
                    local val = tagInfo.Mask
                    local bsh = tagInfo.BitShift
                    if perlTruthy(bsh) then
                        values[#values + 1] = sprintf('[val >> %d & 0x%x]', bsh, val >> bsh)
                    else
                        values[#values + 1] = sprintf('[val & 0x%x]', val)
                    end
                    -- verify that all values are within the mask
                    if convRef(printConv) == 'HASH' then
                        val = val >> (tagInfo.BitShift or 0)
                        for k in pairs(printConv) do
                            local ks = keyStr(k)
                            if isMatch(ks, [[^\d+$]]) and (perl.int(ks) & val) ~= perl.int(ks) then
                                local hex_ = sprintf('0x%.2x', ks)
                                warn(short .. ' ' .. name .. ' PrintConv value ' .. hex_ .. " is not in Mask!\n")
                            end
                        end
                    end
                end
                if isMatch(convRef(printConv), [[^(HASH|ARRAY)$]]) then
                    local printConvList, indexList, index, valueConvHash = { }, { }, nil, nil
                    if convRef(printConv) == 'ARRAY' then
                        index = 0
                        while index < #printConv do
                            local pc = printConv[index + 1]
                            if convRef(pc) == 'HASH' then
                                if next(pc) == nil then goto nextIndex end
                                printConvList[#printConvList + 1] = pc
                                indexList[#indexList + 1] = index
                            elseif pc and pc == 'REPEAT' and index ~= 0 then
                                printConvList[#printConvList + 1] = printConv[index]
                                indexList[#indexList + 1] = 'N'
                            else
                                goto nextIndex
                            end
                            -- collapse values with identical PrintConv's
                            if #printConvList >= 2 and printConvList[#printConvList] == printConvList[#printConvList - 1] then
                                if type(indexList[#indexList - 1]) == 'table' then
                                    local l = indexList[#indexList - 1]
                                    l[#l + 1] = indexList[#indexList]
                                else
                                    indexList[#indexList - 1] = { indexList[#indexList - 1], indexList[#indexList] }
                                end
                                remove(printConvList)
                                remove(indexList)
                            end
                            ::nextIndex::
                            index = index + 1
                        end
                        printConv = remove(printConvList, 1)
                        index = remove(indexList, 1)
                    else
                        if convRef(tagInfo.ValueConv) == 'HASH' then valueConvHash = tagInfo.ValueConv end
                    end
                    while printConv ~= nil do
                        if index ~= nil then
                            -- (print indices of original values if reorganized)
                            local s = ''
                            local idx
                            if tagInfo.Relist and type(index) ~= 'table' then idx = tagInfo.Relist[index + 1] else idx = index end
                            if type(idx) == 'table' then
                                if #idx > 1 then s = 's' end
                                -- collapse consecutive number ranges
                                local i, i_, rngStart = 0, { }, nil
                                while i < #idx do
                                    if i < #idx - 1 and (idx[i + 2] == 'N' or perl.num(idx[i + 2]) == perl.num(idx[i + 1]) + 1) then
                                        if rngStart == nil then rngStart = idx[i + 1] end
                                    else
                                        i_[#i_ + 1] = (rngStart ~= nil and (rngStart .. '-') or '') .. idx[i + 1]
                                    end
                                    i = i + 1
                                end
                                idx = subst(join(', ', i_), [[(.*),]], '$1 and')
                            elseif not tagInfo.Relist then
                                while #printConvList > 0 and printConv == printConvList[1] do
                                    remove(printConvList, 1)
                                    index = remove(indexList, 1)
                                end
                                if perl.num(idx) ~= perl.num(index) then
                                    idx = idx .. '-' .. index
                                    s = 's'
                                end
                            end
                            values[#values + 1] = '[Value' .. s .. ' ' .. idx .. ']'
                        end
                        if tagInfo.SeparateTable then
                            subdir = 1
                            local s = tagInfo.SeparateTable
                            if keyStr(s) == '1' then s = name end
                            -- add module name if not specified
                            if not isMatch(s, ' ') then
                                local m = matches(short, [[^(\w+)]])
                                if m then s = m .. ' ' .. s end
                            end
                            values[#values + 1] = s
                            sepTable[s] = printConv
                            -- add PrintHex flag to PrintConv so we can check it later
                            if perlTruthy(tagInfo.PrintHex) then printConv.PrintHex = 1 end
                            if perlTruthy(tagInfo.PrintInt) then printConv.PrintInt = 1 end
                            if perlTruthy(tagInfo.PrintString) then printConv.PrintString = 1 end
                        else
                            caseInsensitive = false
                            local pk
                            if tagInfo.PrintSort then
                                pk = perl.sort(perl.keys(printConv), function(a, b) return NumbersFirst(keyStr(printConv[a]), keyStr(printConv[b])) end)
                            else
                                pk = perl.sort(perl.keys(printConv), function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) end)
                            end
                            local n = #values
                            local bits, i
                            for _, k in ipairs(pk) do
                                local ks = keyStr(k)
                                if ks == '' and printConv[k] == '' then goto nextKey end
                                if ks == 'BITMASK' then bits = printConv[k] goto nextKey end
                                if ks == 'OTHER' then goto nextKey end
                                do
                                local index_ = ks
                                if perlTruthy(tagInfo.PrintInt) then index_ = subst(index_, [[\.\d+$]], '') end
                                if (perlTruthy(tagInfo.PrintHex) or printConv.BITMASK) and isMatch(index_, [[^-?\d+$]]) then
                                    local dig = perlTruthy(tagInfo.PrintHex) and tagInfo.PrintHex or 1
                                    if perl.num(index_) >= 0 then
                                        index_ = sprintf('0x%.*x', dig, index_)
                                    else
                                        local okI, m = isMatch(format, [[int(16|32)]])
                                        if perlTruthy(format) and okI then
                                            -- mask off unused bits of signed integer hex value
                                            local mask = ({ ['16'] = 0xffff, ['32'] = 0xffffffff })[m]
                                            index_ = sprintf('0x%.*x', dig, perl.int(index_) & mask)
                                        end
                                    end
                                elseif perlTruthy(tagInfo.PrintString) or not isMatch(ks, [[^[+-]?(?=\d|\.\d)\d*(\.\d*)?$]]) then
                                    -- translate unprintable values
                                    local nsub = 0
                                    index_ = subst(index_, [[([\x00-\x1f\x7f-\xff])]],
                                                   function(c) nsub = nsub + 1 return sprintf('\\x%.2x', perl.ord(c)) end, 'g')
                                    if nsub > 0 then
                                        index_ = '"' .. index_ .. '"'
                                    else
                                        index_ = "'" .. index_ .. "'"
                                    end
                                end
                                values[#values + 1] = index_ .. ' = ' .. keyStr(printConv[k])
                                if valueConvHash then
                                    for v in pairs(valueConvHash) do
                                        if keyStr(valueConvHash[v]) == ks then
                                            values[#values] = keyStr(v) .. ' => ' .. values[#values]
                                            break
                                        end
                                    end
                                end
                                -- validate all PrintConv values
                                if isMatch(keyStr(printConv[k]), [=[[\0-\x1f\x7f-\xff]]=]) then
                                    warn('Warning: Special characters in ' .. short .. ' ' .. name .. ' PrintConv (' .. keyStr(printConv[k]) .. ")\n")
                                end
                                end
                                ::nextKey::
                            end
                            if bits then
                                local pk_ = perl.sort(perl.keys(bits), function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) end)
                                for _, k in ipairs(pk_) do
                                    values[#values + 1] = 'Bit ' .. keyStr(k) .. ' = ' .. bits[k]
                                end
                            end
                            -- organize values into columns if specified
                            local cols = tagInfo.PrintConvColumns
                            if not cols and #values - n >= 6 then
                                -- do columns if more than 6 short entries
                                local maxLen = 0
                                i = n
                                while i < #values do
                                    if maxLen < length(values[i + 1]) then
                                        maxLen = length(values[i + 1])
                                    end
                                    i = i + 1
                                end
                                local num = #values - n
                                cols = perl.int(50 / (maxLen + 2)) -- (50 chars max width)
                                -- have 3 rows minimum
                                while cols ~= 0 and num / cols < 3 do cols = cols - 1 end
                            end
                            if perlTruthy(cols) then
                                local new = { }
                                for j = n + 1, #values do new[#new + 1] = values[j] end
                                for j = #values, n + 1, -1 do values[j] = nil end
                                local v = '[!HTML]<table class=cols><tr>'
                                local rows = perl.int((#new + cols - 1) / cols)
                                n = 0
                                while true do
                                    v = v .. "\n  <td>"
                                    i = 0
                                    while i < rows and n + i < #new do
                                        if i ~= 0 then v = v .. "\n  <br>" end
                                        v = v .. EscapeHTML(new[n + i + 1])
                                        i = i + 1
                                    end
                                    v = v .. '</td>'
                                    n = n + rows
                                    if n >= #new then break end
                                    v = v .. '<td>&nbsp;&nbsp;</td>' -- add spaces between columns
                                end
                                values[#values + 1] = v .. "</tr></table>\n"
                            end
                        end
                        if #printConvList == 0 then break end
                        printConv = remove(printConvList, 1)
                        index = remove(indexList, 1)
                    end
                -- look inside scalar PrintConv for a bit/byte conversion
                -- (see Photoshop:PrintFlags for use of "$byte" decoding)
                elseif perlTruthy(printConv) and type(printConv) == 'string' and
                       isMatch(printConv, [[(?s)DecodeBits\(\$(val|byte),\s*(\\\%[\w:]+|\{.*\})\s*\)]]) then
                    -- (see the Port notes: a conversion here is a Lua function,
                    --  so there is no hash expression to `eval` -- upstream's
                    --  "Byte/Bit N = ..." list has no source in this port)
                    warn('(' .. short .. ' ' .. name .. ": DecodeBits hash not evaluated)\n")
                end
                if subdir and not tagInfo.SeparateTable then
                    if perlTruthy(writable) then
                        -- subdirectories are only writable if specified explicitly
                        local tw = tagInfo.Writable
                        if perlTruthy(tw) and keyStr(writable) == '1' or keyStr(writable) == '2' then writable = 'yes' end
                        writable = '-' .. (perlTruthy(tw) and keyStr(writable) or '')
                        if perlTruthy(tw) and ((tagInfo.Protected or 0) & 0x01) ~= 0 then writable = writable .. '!' end
                        if perlTruthy(tagInfo.List) or tagInfo.IsList then writable = writable .. '+' end
                        if tagInfo.Permanent ~= nil then
                            if not perlTruthy(tagInfo.Permanent) then writable = writable .. '^' end
                        elseif table_.PERMANENT ~= nil then
                            if not perlTruthy(table_.PERMANENT) then writable = writable .. '^' end
                        end
                    else
                        writable = '-'
                    end
                else
                    -- not writable if we can't do the inverse conversions
                    local noPrintConvInv
                    if perlTruthy(writable) then
                        for _, conv in ipairs({ 'PrintConv', 'ValueConv' }) do
                            if not perlTruthy(tagInfo[conv]) then goto nextConv end
                            if tagInfo[conv .. 'Inv'] ~= nil and tagInfo[conv .. 'Inv'] ~= false then goto nextConv end
                            -- (undefined inverse conversion overrides hash lookup)
                            if tagInfo[conv .. 'Inv'] == nil then
                                if isMatch(convRef(tagInfo[conv]), [[^(HASH|ARRAY)$]]) then goto nextConv end
                                if tagInfo.WriteAlso then goto nextConv end
                            end
                            if conv == 'ValueConv' then
                                writable = nil
                            else
                                noPrintConvInv = 1
                            end
                            ::nextConv::
                        end
                    end
                    if not perlTruthy(writable) then
                        writable = 'no'
                    else
                        if keyStr(writable) == '1' or keyStr(writable) == '2' then
                            writable = perlTruthy(format) and format or 'yes'
                        end
                        local count = perlTruthy(tagInfo.Count) and tagInfo.Count or 1
                        -- adjust count to Writable size if different than Format
                        if perlTruthy(writable) and perlTruthy(format) and writable ~= format and
                            writable ~= 'string' and format ~= 'string' and
                            Exif.formatNumber[writable] and
                            Exif.formatNumber[format]
                        then
                            local n1 = Exif.formatNumber[format]
                            local n2 = Exif.formatNumber[writable]
                            count = perl.num(count) * Exif.formatSize[n1] /
                                     Exif.formatSize[n2]
                        end
                        if perl.num(count) ~= 1 then
                            if perl.num(count) < 0 then count = 'n' end
                            writable = writable .. '[' .. keyStr(count) .. ']'
                        end
                        if noPrintConvInv then writable = writable .. '~' end
                        -- add a '*' if this tag is protected or a '!' for unsafe tags
                        if perlTruthy(tagInfo.Protected) then
                            if (tagInfo.Protected & 0x02) ~= 0 then writable = writable .. '*' end
                            if (tagInfo.Protected & 0x01) ~= 0 then writable = writable .. '!' end
                        end
                        if perlTruthy(tagInfo.Avoid) then writable = writable .. '/' end
                    end
                    if struct then writable = '=struct' end
                    if tagInfo.Flat ~= nil then writable = writable .. '_' end
                    if perlTruthy(tagInfo.List) or tagInfo.IsList then writable = writable .. '+' end
                    if perlTruthy(tagInfo.Mandatory) then writable = writable .. ':' end
                    if tagInfo.Permanent ~= nil then
                        if not perlTruthy(tagInfo.Permanent) then writable = writable .. '^' end
                    elseif table_.PERMANENT ~= nil then
                        if not perlTruthy(table_.PERMANENT) then writable = writable .. '^' end
                    end
                    -- separate tables link like subdirectories (flagged with leading '-')
                    if subdir then writable = '-' .. writable end
                end
                -- don't duplicate a tag name unless an entry is different
                local lcName = lc(name)
                -- check for conflicts with shortcut names
                if isShortcut[lcName] and short ~= 'Shortcuts' and
                    (perlTruthy(tagInfo.Writable) or not tagInfo.SubDirectory)
                then
                    warn('WARNING: ' .. short .. ' ' .. name .. " is a shortcut tag!\n")
                end
                if perlTruthy(tagInfo.Unknown) then name = name .. '?' end
                if not (#tagNames > 0 and tagNames[#tagNames] == name and
                    writeGroup_a[#writeGroup_a] == writeGroup and writable_a[#writable_a] == writable)
                then
                    tagNames[#tagNames + 1] = name
                    writeGroup_a[#writeGroup_a + 1] = writeGroup
                    writable_a[#writable_a + 1] = writable
                end
--
-- add this tag to the tag lookup unless NO_LOOKUP is set or shortcut or plug-in tag
--
                if shortcut or isPlugin then goto nextTagInfo end
                -- count tags
                if tagInfo.SubDirectory then
                    if vars.NO_LOOKUP then goto nextTagInfo end
                    if not subdirs[lcName] then subdirs[lcName] = 0 end
                    subdirs[lcName] = subdirs[lcName] + 1
                else
                    count_h['total tags'] = count_h['total tags'] + 1
                    if not (perlTruthy(tagExists[lcName]) and
                        (not perlTruthy(subdirs[lcName]) or subdirs[lcName] == tagExists[lcName]))
                    then
                        if not noLookup[lcName] then count_h['unique tag names'] = count_h['unique tag names'] + 1 end
                    end
                    -- don't add to tag lookup if specified
                    if vars.NO_LOOKUP then noLookup[lcName] = 1 goto nextTagInfo end
                end
                if not tagExists[lcName] then tagExists[lcName] = 0 end
                tagExists[lcName] = tagExists[lcName] + 1
                -- only add writable tags to lookup table (for speed)
                local wflag = tagInfo.Writable
                if not (writeProc and (perlTruthy(wflag) or (perlTruthy(table_.WRITABLE) and
                    wflag == nil and not tagInfo.SubDirectory))) then goto nextTagInfo end
                if not tagLookup[lcName] then tagLookup[lcName] = { } end
                -- add to lookup for flattened tags if necessary
                if tagInfo.RootTagInfo then
                    if not flattened[lcName] then flattened[lcName] = { } end
                    flattened[lcName][tableNum] = tagInfo.RootTagInfo.TagID
                end
                -- remember number for this table
                local tagIDs = tagLookup[lcName][tableNum]
                -- must allow for duplicate tags with the same name in a single table!
                if perlTruthy(tagIDs) then
                    if type(tagIDs) == 'table' then
                        tagIDs[keyStr(tagID)] = 1
                        goto nextTagInfo
                    elseif keyStr(tagID) == tagIDs then
                        goto nextTagInfo
                    else
                        tagIDs = { [tagIDs] = 1, [keyStr(tagID)] = 1 }
                    end
                else
                    tagIDs = keyStr(tagID)
                end
                tableWritable[tableName] = 1
                tagLookup[lcName][tableNum] = tagIDs
                -- keep track of extra modules needed for Composite tags
                if tagInfo.Module then compositeModules[lcName] = tagInfo.Module end
                end
                ::nextTagInfo::
            end
--
-- save TagName information
--
            do
            local tagIDstr
            tagID = keyStr(tagID)
            local isNum, m1, m2 = isMatch(tagID, [[^(-)?\d+(\.\d+)?$]])
            if isNum then
                if m1 then
                    tagIDstr = tagID
                elseif prtID ~= nil then
                    if prtID == 'hex' then
                        tagIDstr = sprintf('0x%.4x', tagID)
                    elseif prtID == 'str' then
                        tagIDstr = "'" .. tagID .. "'"
                    else
                        tagIDstr = tagID
                    end
                elseif not m2 and not binaryTable and not isIPTC and
                         not (isMatch(short, [[^CanonCustom]]) and perl.num(tagID) < 256)
                then
                    tagIDstr = sprintf('0x%.4x', tagID)
                elseif perl.num(tagID) < 0x10000 then
                    tagIDstr = tagID
                else
                    tagIDstr = sprintf('0x%.8x', tagID)
                end
            elseif short == 'DICOM' then
                tagIDstr = subst(tagID, [[_]], ',')
            elseif isMatch(tagID, [[^0x([0-9a-f]+)\.(\d+)$]]) then  -- DR4 tags like '0x20500.0'
                tagIDstr = tagID
            else
                -- convert non-printable characters to hex escape sequences
                local nsub = 0
                tagID = subst(tagID, [[([\x00-\x1f\x7f-\xff])]],
                              function(c) nsub = nsub + 1 return '\\x' .. unpack('H*', c) end, 'g')
                if nsub > 0 then
                    tagID = subst(tagID, [[\\x00]], [[\\0]], 'g')
                    if tagID == [[jP\x1a\x1a]] then goto nextTagID end -- ignore abnormal JP2 signature tag
                    tagIDstr = '"' .. tagID .. '"'
                else
                    tagIDstr = "'" .. tagID .. "'"
                end
            end
            local len = length(tagIDstr)
            if longID[tableName] < len then longID[tableName] = len end
            for _, n in ipairs(tagNames) do
                len = length(n)
                if longName[tableName] < len then longName[tableName] = len end
            end
            info[#info + 1] = { tagIDstr, tagNames, writable_a, values, require_a, writeGroup_a }
            end
            ::nextTagID::
        end
        -- do consistency check of writable BinaryData tables
        if processBinaryData and perlTruthy(table_.WRITABLE) then
            local lookup = {
                IS_OFFSET = isOffset,
                IS_SUBDIR = hasSubdir,
                DATAMEMBER = datamember,
            }
            for _, var in ipairs(perl.sort(perl.keys(lookup))) do
                local hash = lookup[var]
                if table_[var] then
                    for _, tagID in ipairs(table_[var]) do
                        if hash[tagID] then
                            hash[tagID] = nil
                        else
                            warn(sprintf("Warning: Extra %s for %s tag %d (0x%.4x)\n",
                                         var, short, tagID, tagID))
                        end
                    end
                end
                for _, tagID in ipairs(perl.sort(perl.keys(hash))) do
                    warn(sprintf("Warning: Missing %s for %s %s, tag %s (0x%.4x)\n",
                                 var, short, hash[tagID], keyStr(tagID), tagID))
                end
            end
        end
    end
    -- save information about structures
    -- (the Perl loop runs over the key list taken when it starts, so a
    --  structure first seen inside it is not visited; the snapshot here is
    --  sorted instead of Perl's hash order)
    for _, strName in ipairs(perl.sort(perl.keys(structs))) do
        local struct = structLookup[strName]
        local fullName = (isMatch(strName, ' ') and '' or 'XMP ') .. strName .. ' Struct'
        local info = { }
        tagNameInfo[fullName] = info
        local order = struct.SORT_ORDER or perl.sort(perl.keys(struct))
        for _, tag_ in ipairs(order) do
            local tagInfo = struct[tag_]
            if not (type(tagInfo) == 'table' and tag_ ~= 'NAMESPACE' and tag_ ~= 'GROUPS') then goto nextField end
            if ExifTool.specialTags[tag_] then warn('WARNING: ' .. strName .. ' Struct containes ' .. tag_ .. "\n") end
            do
            local writable = tagInfo.Writable
            local vals = { }
            if not perlTruthy(writable) then
                writable = tagInfo.Struct
                if type(writable) == 'table' then writable = writable.STRUCT_NAME end
                if writable then
                    vals[#vals + 1] = writable
                    structs[writable] = 1
                    writable = '=' .. writable
                elseif tagInfo.Writable ~= nil then
                    writable = 'no'
                else
                    writable = 'string'
                end
            end
            writable = keyStr(writable)
            if perlTruthy(tagInfo.List) or tagInfo.IsList then writable = writable .. '+' end
            if tagInfo.Notes then vals[#vals + 1] = '(' .. tagInfo.Notes .. ')' end
            -- handle PrintConv lookups in Structure elements
            local printConv = tagInfo.PrintConv
            if convRef(printConv) == 'HASH' then
                for _, k in ipairs(perl.sort(perl.keys(printConv), function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) end)) do
                    if not isMatch(keyStr(k), [[^(OTHER|BITMASK)$]]) then
                        vals[#vals + 1] = keyStr(k) .. ' = ' .. keyStr(printConv[k])
                    end
                end
            end
            info[#info + 1] = {
                tag_,
                { tagInfo.Name or ucfirst(tag_) },
                { writable },
                vals,
                { }, { }
            }
            end
            ::nextField::
        end
    end
    return self
end

--------------------------------------------------------------------------------
-- Rewrite this file to build the lookup tables
-- Inputs: 0) BuildTagLookup object reference
--         1) output tag lookup module name (eg. 'lib/Image/ExifTool/TagLookup.pm')
-- Returns: true on success
function BuildTagLookup:WriteTagLookup(file)
    local tagLookup = self.TAG_LOOKUP
    local tagExists = self.TAG_EXISTS
    local flattened = self.FLATTENED
    local tableWritable = self.TABLE_WRITABLE
--
-- open/create necessary files and transfer file headers
--
    local tmpFile = file .. '_tmp'
    local INFILE = io.open(file, 'r')
    if not INFILE then warn("Can't open " .. file .. "\n") return 0 end
    local OUTFILE = io.open(tmpFile, 'w')
    if not OUTFILE then
        warn("Can't create temporary file " .. tmpFile .. "\n")
        INFILE:close()
        return 0
    end
    local success
    for line in INFILE:lines('L') do
        if not OUTFILE:write(line) then break end
        if isMatch(line, [[^--\+{4} Begin]]) then
            success = 1
            break
        end
    end
    OUTFILE:write("\n-- list of tables containing writable tags\n")
    OUTFILE:write("local tableList = {\n")

--
-- write table list
--
    local tableNames = perl.sort(allTablesKeys())
    local wrNum = { }   -- translate from allTables index to writable tables index
    local count = 0
    local num = 0
    for _, tableName in ipairs(tableNames) do
        if tableWritable[tableName] then
            OUTFILE:write("    '" .. LuaTableName(tableName) .. "',\n")
            wrNum[count] = num; num = num + 1
        end
        count = count + 1
    end
--
-- write the tag lookup table
--
    -- verify that certain critical tag names aren't duplicated
    for _, tag in ipairs({ 'filename', 'directory' }) do
        if tagLookup[tag] then
            local n = #perl.keys(tagLookup[tag])
            if n > 1 then warn('Warning: ' .. n .. " writable '" .. tag .. "' tags!\n") end
        end
    end
    OUTFILE:write("}\n\n-- lookup for all writable tags\nlocal tagLookup = {\n")
    for _, tag in ipairs(perl.sort(perl.keys(tagLookup))) do
        OUTFILE:write("    ['" .. tag .. "'] = { ")
        local tableNums = perl.sort(perl.keys(tagLookup[tag]), function(a, b) return a - b end)
        local entries = { }
        for _, tableNum in ipairs(tableNums) do
            local tagID = tagLookup[tag][tableNum]
            local rootID = flattened[tag] and flattened[tag][tableNum]
            local entry
            if type(tagID) == 'table' or rootID then
                if type(tagID) ~= 'table' then tagID = { [tagID] = 1 } end
                local tagIDs = perl.sort(perl.keys(tagID))
                for i, id in ipairs(tagIDs) do
                    if isMatch(id, [[^\d+$]]) then
                        tagIDs[i] = sprintf('0x%x', id)
                    else
                        local quot = "'"
                        -- escape non-printable characters in tag ID if necessary
                        local nsub = 0
                        id = subst(id, [[([\x00-\x1f,\x7f-\xff])]],
                                   function(c) nsub = nsub + 1 return sprintf('\\x%.2x', perl.ord(c)) end, 'g')
                        if nsub > 0 then quot = '"' end
                        tagIDs[i] = quot .. id .. quot
                    end
                end
                -- reference to root structure ID must come first in lookup
                -- (so we can generate the flattened tags just before we need them)
                -- (Lua has no scalar references: a one-element table is the
                --  marker, see the Port notes)
                if rootID then insert(tagIDs, 1, "{'" .. rootID .. "'}") end
                entry = '{' .. join(',', tagIDs) .. '}'
            elseif isMatch(tagID, [[^\d+$]]) then
                entry = sprintf('0x%x', tagID)
            else
                local quot = "'"
                -- escape non-printable characters in tag ID if necessary
                local nsub = 0
                tagID = subst(tagID, [[([\x00-\x1f,\x7f-\xff])]],
                              function(c) nsub = nsub + 1 return sprintf('\\x%.2x', perl.ord(c)) end, 'g')
                if nsub > 0 then quot = '"' end
                entry = quot .. tagID .. quot
            end
            local wrNum_ = wrNum[tableNum]
            -- (1-based: tableList is a Lua array)
            entries[#entries + 1] = '[' .. (wrNum_ + 1) .. '] = ' .. entry
        end
        OUTFILE:write(join(', ', entries))
        OUTFILE:write(" },\n")
    end
--
-- write tag exists lookup
--
    OUTFILE:write("}\n\n-- lookup for non-writable tags to check if the name exists\n")
    OUTFILE:write("local tagExists = {\n")
    for _, tag in ipairs(perl.sort(perl.keys(tagExists))) do
        if not tagLookup[tag] then
            OUTFILE:write("    ['" .. tag .. "'] = 1,\n")
        end
    end
--
-- write module lookup for writable composite tags
--
    local compositeModules = self.COMPOSITE_MODULES
    OUTFILE:write("}\n\n-- module names for writable Composite tags\n")
    OUTFILE:write("local compositeModules = {\n")
    for _, tag in ipairs(perl.sort(perl.keys(compositeModules))) do
        OUTFILE:write("    ['" .. tag .. "'] = '" .. compositeModules[tag] .. "',\n")
    end
    OUTFILE:write("}\n\n")
--
-- finish writing TagLookup.pm and clean up
--
    if success then
        success = 0
        for line in INFILE:lines('L') do
            if perlTruthy(success) or isMatch(line, [[^--\+{4} End]]) then
                OUTFILE:write(line)
                success = 1
            end
        end
    end
    INFILE:close()
    if not OUTFILE:close() then success = 0 end
--
-- return success code
--
    if perlTruthy(success) then
        -- only rename the file if something changed
        local ORG = io.open(file, 'rb')
        if not ORG then return 0 end
        local TMP = io.open(tmpFile, 'rb')
        if not TMP then ORG:close() return 0 end
        local changed
        while true do
            local buff = ORG:read(65536)
            local buf2 = TMP:read(65536)
            local n1, n2 = buff and #buff or 0, buf2 and #buf2 or 0
            if n1 ~= n2 then changed = 1 break end
            if n1 == 0 then break end
            if buff ~= buf2 then changed = 1 break end
        end
        ORG:close()
        TMP:close()
        if changed then
            if not perl.rename(tmpFile, file) then warn('Error renaming ' .. tmpFile .. "\n") success = 0 end
        else
            perl.unlink(tmpFile)
        end
    else
        perl.unlink(tmpFile)
        warn("Error rewriting file\n")
    end
    return success
end

--------------------------------------------------------------------------------
-- Sort numbers first numerically, then strings alphabetically
-- - case-insensitive sorting set by global variable $caseInsensitive
-- - two global variables are used to change the sort algorithm:
--   $numbersFirst: -1 = put numbers after other strings
--                   1 = put numbers before other strings
--                   2 = put numbers first, but negative numbers last
function BuildTagLookup.NumbersFirst(a, b)
    local rtnVal
    local bNum, bDec
    local okB, b1, _, b3 = isMatch(b, [[^(-?[0-9]+)(\.(\d*))?$]])
    if okB then bNum, bDec = b1, b3 end
    local okA, a1, _, a3 = isMatch(a, [[^(-?[0-9]+)(\.(\d*))?$]])
    if okA then
        if bNum ~= nil then
            bNum = perl.num(bNum)
            if numbersFirst == 2 and bNum < 0 then bNum = bNum + 1e9 end
            local aInt = perl.num(a1)
            if numbersFirst == 2 and aInt < 0 then aInt = aInt + 1e9 end
            -- compare integer part as a number
            rtnVal = (aInt < bNum and -1) or (aInt > bNum and 1) or 0
            if rtnVal == 0 then
                local aDec = perlTruthy(a3) and perl.num(a3) or 0
                bDec = perlTruthy(bDec) and perl.num(bDec) or 0
                -- compare decimal part as an integer too
                -- (so that "1.10" comes after "1.9")
                rtnVal = (aDec < bDec and -1) or (aDec > bDec and 1) or 0
            end
        else
            rtnVal = -numbersFirst
        end
    elseif bNum ~= nil then
        rtnVal = numbersFirst
    else
        local a2, b2 = a, b
        -- expand numbers to 3 digits (with restrictions to avoid messing up
        -- ascii-hex tags -- Nikon LensID's are 23 characters long)
        if isMatch(a2, [[^(APP|DMC-\w+ |dvtm_.*|(IDB|SHB)-)?[.0-9 ]*$]]) and length(a2) < 23 then
            a2 = subst(a2, [[(\d+)]], function(d) return sprintf('%.3d', d) end, 'g')
        end
        if isMatch(b2, [[^(APP|DMC-\w+ |dvtm_.*|(IDB|SHB)-)?[.0-9 ]*$]]) and length(b2) < 23 then
            b2 = subst(b2, [[(\d+)]], function(d) return sprintf('%.3d', d) end, 'g')
        end
        if caseInsensitive then
            local la, lb = lc(a2), lc(b2)
            rtnVal = perl.cmp(la, lb)
        end
        if not perlTruthy(rtnVal) then rtnVal = perl.cmp(a2, b2) end
    end
    return rtnVal
end
NumbersFirst = BuildTagLookup.NumbersFirst

--------------------------------------------------------------------------------
-- Convert our pod-like documentation to pod
-- (funny, I know, but the pod headings must be hidden to prevent confusing
--  the pod parser)
-- Inputs: 0-N) documentation strings
function BuildTagLookup.Doc2Pod(doc, ...)
    for i = 1, select('#', ...) do doc = doc .. select(i, ...) end
    doc = subst(doc, [[\n~]], "\n=", 'g')
    doc = subst(doc, [[L<[^>]+?\|(http[^>]+)>]], 'L<$1>', 'g') -- POD doesn't support text for http links
    doc = subst(doc, [[L<([^>]+?)\|[^>]+\.html(#\w+)?>]], '$1', 'g')  -- remove relative HTML links
    return doc
end
Doc2Pod = BuildTagLookup.Doc2Pod

--------------------------------------------------------------------------------
-- Convert our pod-like documentation to html
-- Inputs: 0) string
function BuildTagLookup.Doc2Html(doc)
    doc = EscapeHTML(doc)
    doc = subst(doc, [[\n\n]], "</p>\n\n<p>", 'g')
    doc = subst(doc, [[(?s)B&lt;(.*?)&gt;]], '<b>$1</b>', 'g')
    doc = subst(doc, [[(?s)C&lt;(.*?)&gt;]], '<code>$1</code>', 'g')
    doc = subst(doc, [[(?s)I&lt;(.*?)&gt;]], '<i>$1</i>', 'g')
    -- L<some text|https://exiftool.org/struct.html#Fields> --> <a href="../struct.html#Fields">some text</a>
    doc = substDyn(doc, [[(?s)L&lt;([^&]+?)\|]] .. quotemeta(homePage) .. [[/(.*?)&gt;]], '<a href="../$2">$1</a>', 'g')
    -- L<https://exiftool.org/struct.html> --> <a href="https://exiftool.org/struct.html">https://exiftool.org/struct.html</a>
    doc = substDyn(doc, [[(?s)L&lt;]] .. quotemeta(homePage) .. [[/(.*?)&gt;]], '<a href="../$1">$1</a>', 'g')
    -- L<XMP DICOM Tags|Image::ExifTool::TagNames/XMP DICOM Tags> --> <a href="XMP.html#DICOM">XMP DICOM Tags</a>
    -- (specify "Image::ExifTool::TagNames" to link to another html file)
    doc = subst(doc, [[(?s)L&lt;([^&]+?)\|Image::ExifTool::TagNames/(\w+) ([^/&|]+) Tags&gt;]], '<a href="$2.html#$3">$1</a>', 'g')
    -- L<DICOM Tags|Image::ExifTool::TagNames/DICOM Tags> --> <a href="DICOM.html">DICOM Tags</a>
    doc = subst(doc, [[(?s)L&lt;([^&]+?)\|Image::ExifTool::TagNames/(\w+) Tags&gt;]], '<a href="$2.html">$1</a>', 'g')
    -- L<dc|/XMP dc Tags> --> <a href="#dc">dc</a>
    -- (a relative POD link turns into a relative HTML link)
    doc = subst(doc, [[(?s)L&lt;([^&]+?)\|/\w+ ([^/&|]+) Tags&gt;]], '<a href="#$2">$1</a>', 'g')
    -- L<sample config file|../config.html> --> <a href="../config.html">sample config file</a>
    doc = subst(doc, [[(?s)L&lt;([^&]+?)\|(.+?)&gt;]], '<a href="$2">$1</a>', 'g')
    -- L<http://some.web.site/> --> <a href="http://some.web.site">http://some.web.site</a>
    doc = subst(doc, [[(?s)L&lt;(http.*?)&gt;]], '<a href="$1">$1</a>', 'g')
    return doc
end
Doc2Html = BuildTagLookup.Doc2Html

--------------------------------------------------------------------------------
-- Tweak order of tables
-- Inputs: 0) table list ref, 1) reference to tweak hash
function BuildTagLookup.TweakOrder(sortedTables, tweakOrder) -- luacheck: ignore 431
    local tweak = perl.sort(perl.keys(tweakOrder))
    local sorted, hasMain, module = { }, { }, { }
    -- apply manual tweaks
    while #tweak > 0 do
        local table_ = remove(tweak, 1)
        local first = tweakOrder[table_]
        if tweakOrder[first] then
            tweak[#tweak + 1] = table_  -- must defer this till later
        else
            tweakOrder[table_] = nil -- because the table won't move again
            local moving = perl.grepDyn('^Image::ExifTool::' .. table_ .. '\\b', sortedTables)
            local notMoving = { }
            for _, t in ipairs(sortedTables) do
                if not isMatchDyn(t, '^Image::ExifTool::' .. table_ .. '\\b') then notMoving[#notMoving + 1] = t end
            end
            local after = { }
            while #notMoving > 0 do
                if isMatchDyn(notMoving[#notMoving], '^Image::ExifTool::' .. first .. '\\b') then break end
                insert(after, 1, remove(notMoving))
            end
            for i = #sortedTables, 1, -1 do sortedTables[i] = nil end
            for _, list in ipairs({ notMoving, moving, after }) do
                for _, t in ipairs(list) do sortedTables[#sortedTables + 1] = t end
            end
        end
    end
    -- flag modules which have a "Main" table, and organize tables by module name
    for _, t in ipairs(sortedTables) do
        local ok, m1, m2 = isMatch(t, [[^Image::ExifTool::(\w+)::(\w+)]])
        if not ok then
            sorted[#sorted + 1] = t
        else
            if m2 == 'Main' then hasMain[m1] = 1 end
            if not module[m1] then module[m1] = { } sorted[#sorted + 1] = module[m1] end
            local list = module[m1]
            list[#list + 1] = t
        end
    end
    -- force MWG::Composite table first
    local mwg = { 'Image::ExifTool::MWG::Composite' }
    for _, t in ipairs(module.MWG or { }) do
        if not isMatch(t, [[Composite]]) then mwg[#mwg + 1] = t end
    end
    if not module.MWG then module.MWG = { } end
    for i = #module.MWG, 1, -1 do module.MWG[i] = nil end
    for i, t in ipairs(mwg) do module.MWG[i] = t end
    -- make sure that the main table always comes first in each file
    -- and that all other tables from this group follow
    for i = #sortedTables, 1, -1 do sortedTables[i] = nil end
    for _, entry in ipairs(sorted) do
        if type(entry) ~= 'table' then
            sortedTables[#sortedTables + 1] = entry
        else
            local ok, m1 = isMatch(entry[1], [[^Image::ExifTool::(\w+)::(\w+)]])
            if not ok then error('Internal error') end
            local main = 'Image::ExifTool::' .. m1 .. '::Main'
            -- main table must come first (even if it doesn't exist)
            if hasMain[m1] then sortedTables[#sortedTables + 1] = main end
            for _, t in ipairs(entry) do
                if t ~= main then sortedTables[#sortedTables + 1] = t end
            end
        end
    end
end
TweakOrder = BuildTagLookup.TweakOrder

--------------------------------------------------------------------------------
-- Get a list of sorted tag ID's from a table
-- Inputs: 0) tag table ref
-- Returns: list of sorted keys
function BuildTagLookup.SortedTagTableKeys(table_)
    local vars = table_.VARS or { }
    local keys = TagTableKeys(table_)
    if vars.ID_FMT and vars.ID_FMT == 'none' then
        -- sort by tag name if ID not shown
        local name = { }
        for _, key in ipairs(keys) do
            local tagInfo = GetTagInfoList(table_, key)[1]
            name[key] = tagInfo.Name
        end
        return perl.sort(keys, function(a, b)
            local c = perl.cmp(name[a], name[b])
            if c == 0 then c = perl.cmp(keyStr(a), keyStr(b)) end
            return c
        end)
    else
        local sortProc = vars.SORT_PROC or NumbersFirst
        return perl.sort(keys, function(a, b) return sortProc(keyStr(a), keyStr(b)) end)
    end
end
SortedTagTableKeys = BuildTagLookup.SortedTagTableKeys

--------------------------------------------------------------------------------
-- Get the order that we want to print the tables in the documentation
-- Inputs: 0-N) Extra tables to add at end
-- Returns: tables in the order we want
function BuildTagLookup.GetTableOrder(...)
    local gotTable = { }
    local tableNames = tableOrderList()
    local orderedTables, mainTables, outOfOrder = { }, { }, { }
    local lastTable = ''

    while #tableNames > 0 do
        local tableName = remove(tableNames, 1)
        if gotTable[tableName] then goto continue end
        do
        local isMain, m1 = isMatch(tableName, [[^Image::ExifTool::(\w+)::Main]])
        if isMain then
            mainTables[m1] = 1
        elseif perlTruthy(lastTable) and not isMatchDyn(tableName, '^' .. lastTable .. '::') then
            outOfOrder[#outOfOrder + 1] = tableName
        end
        lastTable = matches(tableName, [[^(Image::ExifTool::\w+)]])
        orderedTables[#orderedTables + 1] = tableName
        gotTable[tableName] = 1
        -- (upstream's GetTagTable warns and returns undef for an unknown table,
        --  whose key list is then empty)
        local table_ = GetTagTable(tableName) or { }
        -- recursively scan through tables in subdirectories
        local moreTables = { }
        caseInsensitive = (table_.GROUPS and table_.GROUPS[0] == 'XMP')
        if table_.VARS and table_.VARS.ALPHA_FIRST then numbersFirst = -1 end
        local keys = SortedTagTableKeys(table_)
        numbersFirst = 1
        for _, key in ipairs(keys) do
            local infoArray = GetTagInfoList(table_, key)
            for _, tagInfo in ipairs(infoArray) do
                local subdir = tagInfo.SubDirectory
                if subdir and subdir.TagTable then
                    tableName = PerlTableName(subdir.TagTable)
                    if not gotTable[tableName] then         -- next if table already loaded
                        moreTables[#moreTables + 1] = tableName -- must scan this one too
                    end
                end
            end
        end
        for i = #moreTables, 1, -1 do insert(tableNames, 1, moreTables[i]) end
        end
        ::continue::
    end
    -- clean up the order for tables which are out of order
    -- (groups all Canon and Kodak tables together)
    local fixOrder = { }
    for _, t in ipairs(outOfOrder) do
        local m1 = matches(t, [[^Image::ExifTool::(\w+)]])
        -- only re-order tables which have a corresponding main table
        if m1 and mainTables[m1] then
            fixOrder[m1] = { }     -- fix the order of these tables
        end
    end
    local sortedTables, fixPos, pos = { }, { }, nil -- luacheck: ignore 311
    for _, t in ipairs(orderedTables) do
        local m1 = matches(t, [[^Image::ExifTool::(\w+)]])
        if m1 and fixOrder[m1] then
            local fix = fixOrder[m1]
            if #fix == 0 then
                pos = #sortedTables
                if not fixPos[pos] then fixPos[pos] = { } end
                local l = fixPos[pos]
                l[#l + 1] = m1
            end
            fix[#fix + 1] = t
        else
            sortedTables[#sortedTables + 1] = t
        end
    end
    -- insert back in better order
    for _, p in ipairs(perl.sort(perl.keys(fixPos), function(a, b) return b - a end)) do -- (reverse sort)
        pos = p
        local fix = fixPos[pos]
        for _, m in ipairs(fix) do
            for i, t in ipairs(fixOrder[m]) do insert(sortedTables, pos + i, t) end
        end
    end
    -- add the extra tables
    for i = 1, select('#', ...) do sortedTables[#sortedTables + 1] = select(i, ...) end
    -- tweak the table order
    TweakOrder(sortedTables, tweakOrder)

    return sortedTables
end
GetTableOrder = BuildTagLookup.GetTableOrder

--------------------------------------------------------------------------------
-- Open HTMLFILE and print header and description
-- Inputs: 0) Filename, 1) optional category
-- Returns: True on success
local createdFiles = { }
-- (upstream's HTMLFILE and PODFILE are package file handles, shared by the
--  subs below)
local HTMLFILE, PODFILE
function BuildTagLookup.OpenHtmlFile(htmldir, category, sepTable)
    local htmlFile, head, title, url, class
    local top = ''

    if category then
        local names = split(' ', category)
        class = remove(names, 1)
        htmlFile = htmldir .. '/TagNames/' .. class .. '.html'
        head = category
        if isMatch(head, [[^\S+ .+ Struct$]]) then
            remove(names)
        else
            head = head .. (sepTable and ' Values' or ' Tags')
        end
        title = subst(head, ' .* ', ' ')
        if #names > 0 then url = join('_', names) end
    else
        htmlFile = htmldir .. '/TagNames/index.html'
        category = 'ExifTool'; class = 'ExifTool'
        head = 'ExifTool Tag Names'; title = head
    end
    if createdFiles[htmlFile] then
        HTMLFILE = io.open(htmlFile .. '_tmp', 'a')
        if not HTMLFILE then return 0 end
    else
        HTMLFILE = io.open(htmlFile .. '_tmp', 'w')
        if not HTMLFILE then return 0 end
        HTMLFILE:write(docType .. "<html>\n")
        HTMLFILE:write("<!-- (this file generated automatically by Image::ExifTool::BuildTagLookup) -->\n")
        HTMLFILE:write("<head>\n<title>" .. title .. "</title>\n")
        HTMLFILE:write("<link rel=stylesheet type='text/css' href='style.css' title='Style'>\n")
        HTMLFILE:write("</head>\n<body>\n")
        if category ~= class and docs[class] then
            if not HTMLFILE:write('<h2 class=top>' .. class .. " Tags</h2>\n") then return 0 end
            if not HTMLFILE:write('<p>', Doc2Html(docs[class]), "</p>\n") then return 0 end
        else
            top = ' class=top'
        end
    end
    if url then head = "<a name='" .. url .. "'>" .. head .. '</a>' end
    if not HTMLFILE:write('<h2' .. top .. '>' .. head .. "</h2>\n") then return 0 end
    if docs[category] then HTMLFILE:write('<p>', Doc2Html(docs[category]), "</p>\n") end
    createdFiles[htmlFile] = 1
    return 1
end
OpenHtmlFile = BuildTagLookup.OpenHtmlFile

--------------------------------------------------------------------------------
-- Close all html files and write trailers
-- Returns: true on success
-- Inputs: 0) BuildTagLookup object reference
function BuildTagLookup:CloseHtmlFiles()
    local preserveDate = self.PRESERVE_DATE
    local success = 1
    -- get the date
    local lt = perl.localtime()
    local day, mon, yr = lt[4], lt[5], lt[6]
    local month = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
    yr = yr + 1900
    local date = month[mon + 1] .. ' ' .. day .. ', ' .. yr
    local countNewFiles = 0
    local countSameFiles = 0
    -- (sorted: upstream walks the hash in Perl's order)
    for _, htmlFile in ipairs(perl.sort(perl.keys(createdFiles))) do
        local tmpFile = htmlFile .. '_tmp'
        local fileDate = date
        if preserveDate then
            local lines = perl.qx("grep '<i>Last revised' " .. htmlFile, true)
            if #lines > 0 then
                local m = matches(lines[#lines], [[<i>Last revised (.*)</i>]])
                if m then fileDate = m end
            end
        end
        HTMLFILE = io.open(tmpFile, 'a')
        if not HTMLFILE then success = 0 goto nextFile end
        -- write the trailers
        HTMLFILE:write("<hr>\n")
        HTMLFILE:write("(This document generated automatically by Image::ExifTool::BuildTagLookup)\n")
        if htmlFile == 'html/TagNames/index.html' then HTMLFILE:write('<br><i>Created ' .. createDate .. "</i>\n") end
        HTMLFILE:write('<br><i>Last revised ' .. fileDate .. "</i>\n")
        HTMLFILE:write('<p class=lf><a href=')
        if isMatch(htmlFile, [[index\.html$]]) then
            HTMLFILE:write("'../index.html'>&lt;-- Back to ExifTool home page</a></p>\n")
        else
            HTMLFILE:write("'index.html'>&lt;-- ExifTool Tag Names</a></p>\n")
        end
        if not HTMLFILE:write("</body>\n</html>\n") then success = 0 end
        if not HTMLFILE:close() then success = 0 end
        -- check for differences and only use new file if it was changed
        -- (so the date only gets updated if changes were really made)
        do
        local useNewFile
        if perlTruthy(success) then
            local TEMPFILE = io.open(tmpFile, 'r')
            if not TEMPFILE then success = 0 break end
            local OLDFILE = io.open(htmlFile, 'r')
            if OLDFILE then
                for line in OLDFILE:lines('L') do
                    local newLine = TEMPFILE:read('L')
                    if newLine ~= nil then
                        if isMatch(line, [[^<br><i>Last revised]]) then goto nextLine end
                        if line == newLine then goto nextLine end
                    end
                    -- files are different -- use the new file
                    useNewFile = 1
                    break
                    ::nextLine::
                end
                if TEMPFILE:read('L') then useNewFile = 1 end
                OLDFILE:close()
            else
                useNewFile = 1
            end
            TEMPFILE:close()
            if useNewFile then
                countNewFiles = countNewFiles + 1
                if not perl.rename(tmpFile, htmlFile) then warn("Error renaming temporary file\n") success = 0 end
            else
                countSameFiles = countSameFiles + 1
                perl.unlink(tmpFile)   -- erase new file and use existing file
            end
        end
        end
        ::nextFile::
        if not perlTruthy(success) then break end
    end
    -- save number of files processed so we can check the results later
    self.COUNT['HTML files changed'] = countNewFiles
    self.COUNT['HTML files unchanged'] = countSameFiles
    return success
end
CloseHtmlFiles = BuildTagLookup.CloseHtmlFiles

--------------------------------------------------------------------------------
-- Get bitmask for POD documentation
-- Inputs: mask string from HTML docs
-- Returns: mask string for POD, or ''
function BuildTagLookup.PodMask(mask)
    local ok, _, m2, m3 = isMatch(mask, [=[^\[val( >> (\d+))? \& (0x[\da-f]+)\]]=])
    if not ok then return '' end
    return sprintf(' & 0x%.2x', hex(m3) << (perlTruthy(m2) and perl.int(m2) or 0))
end
PodMask = BuildTagLookup.PodMask

--------------------------------------------------------------------------------
-- Write the TagName HTML and POD documentation
-- Inputs: 0) BuildTagLookup object reference
--         1) output pod file (eg. 'lib/Image/ExifTool/TagNames.pod')
--         2) output html directory (eg. 'html')
-- Returns: true on success
-- Notes: My apologies for the patchwork code, but this is only used to generate the docs.
function BuildTagLookup:WriteTagNames(podFile, htmldir)
    local tableName, short, url
    local sepTables, structs_a = { }, { }
    local tagNameInfo = self.TAG_NAME_INFO
    if not tagNameInfo then return 0 end
    local idLabel = self.ID_LOOKUP
    local shortName = self.SHORT_NAME
    local sepTable = self.SEPARATE_TABLE
    local structs = self.STRUCTURES
    local structLookup = self.STRUCT_LOOKUP
    local success = 1
    local columns = 6    -- number of columns in html index
    local percent = perl.int(100 / columns)

    -- open the file and write the header
    PODFILE = io.open(podFile, 'w')
    if not PODFILE then return 0 end
    -- (upstream: `eval qq{"$docs{ExifTool}"}` -- the text interpolates
    --  $$self{COUNT}{...}, and those are the only variables in it)
    docs.ExifTool = subst(docs.ExifTool, [[\$\$self\{COUNT\}\{'([^']*)'\}]],
                          function(k) return perlStr(self.COUNT[k]) end, 'g')
    PODFILE:write(Doc2Pod(docs.PodHeader, docs.ExifTool, docs.ExifTool2))
    require('lfs').mkdir(htmldir .. '/TagNames')
    if not perlTruthy(OpenHtmlFile(htmldir)) then return 0 end
    HTMLFILE:write("<blockquote>\n")
    HTMLFILE:write("<table width='100%' class=frame><tr><td>\n")
    HTMLFILE:write("<table width='100%' class=inner cellspacing=1><tr class=h>\n")
    HTMLFILE:write('<th colspan=' .. columns .. "><span class=l>Tag Table Index</span></th></tr>\n")
    HTMLFILE:write("<tr class=b><td width='" .. percent .. "%'>\n")

    -- get the full table list, adding shortcuts and plug-in tables to the end
    local tableNames = GetTableOrder('Image::ExifTool::Shortcuts::Main', table.unpack(pluginTables))

    -- get list of headings and add any missing ones
    local heading = 'xxx'
    local tableIndexNames, headings = { }, { }
    for _, tn in ipairs(tableNames) do
        tableName = tn
        short = shortName[tableName]
        local names = split(' ', short)
        local class = remove(names, 1)
        if #names > 0 and class ~= 'Other' then
            -- add heading for tables without a Main
            if heading ~= class then
                heading = class
                tableIndexNames[#tableIndexNames + 1] = heading
                headings[#headings + 1] = heading
            end
        else
            heading = short
            headings[#headings + 1] = heading
        end
        tableIndexNames[#tableIndexNames + 1] = tableName
    end
    tableNames = tableIndexNames
    -- print html index of headings only
    local count = 0
    local lines = perl.int((#headings + columns - 1) / columns)
    for _, tn in ipairs(headings) do
        tableName = tn
        if count ~= 0 then
            if count % lines ~= 0 then
                HTMLFILE:write("<br>\n")
            else
                HTMLFILE:write("</td><td width='" .. percent .. "%'>\n")
            end
        end
        short = shortName[tableName]
        if not short then short = tableName end
        url = short .. '.html' -- luacheck: ignore 311
        -- handle various tables in "Other.pm"
        local isOther, m1 = isMatch(short, [[^Other (.*)]])
        if isOther then
            short = m1
            url = 'Other.html#' .. m1
        else
            url = short .. '.html'
        end
        HTMLFILE:write("<a href='" .. url .. "'>" .. short .. '</a>')
        count = count + 1
    end
    HTMLFILE:write("\n</td></tr></table></td></tr></table></blockquote>\n")
    HTMLFILE:write('<p>', Doc2Html(docs.ExifTool2), "</p>\n")

    -- write all the tag tables
    while #tableNames > 0 or #sepTables > 0 or #structs_a > 0 do
        while #sepTables > 0 do
            tableName = remove(sepTables, 1)
            local printConv = sepTable[tableName]
            if convRef(printConv) ~= 'HASH' then goto nextSepTable end
            sepTable[tableName] = 1
            do
            local notes = printConv.Notes
            if notes then
                -- remove unnecessary whitespace
                notes = subst(notes, [[^\s+]], ''); notes = subst(notes, [[\s+$]], '')
                notes = subst(notes, [[(?m)(^[ \t]+|[ \t]+$)]], '', 'g')
            end
            local head = tableName
            head = subst(head, [[(?s)^.* ]], '')
            HTMLFILE:close()
            if perlTruthy(OpenHtmlFile(htmldir, tableName, 1)) then
                if notes then HTMLFILE:write('<p>', Doc2Html(notes), "</p>\n") end
                HTMLFILE:write("<blockquote>\n")
                HTMLFILE:write("<table class=frame><tr><td>\n")
                HTMLFILE:write("<table class='inner sep' cellspacing=1>\n")
                local align = ' class=r'
                local wid = 0
                local keys, bits_a = { }, { }
                for _, k in ipairs(perl.sort(perl.keys(printConv), function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) end)) do
                    local ks = keyStr(k)
                    if isMatch(ks, [[^(Notes|PrintHex|PrintInt|PrintString|OTHER|BITMASK)$]]) then goto nextKey end
                    if align ~= '' and isMatch(ks, [=[[^\d]]=]) then align = '' end
                    do
                    local w = length(ks) + length(keyStr(printConv[k]))
                    if wid < w then wid = w end
                    keys[#keys + 1] = k
                    if isMatch(keyStr(printConv[k]), [=[[\0-\x1f\x7f-\xff]]=]) then
                        warn('Warning: Special characters in ' .. tableName .. ' PrintConv (' .. keyStr(printConv[k]) .. ")\n")
                    end
                    end
                    ::nextKey::
                end
                local bits = printConv.BITMASK
                if bits then
                    align = ''
                    for _, k in ipairs(perl.sort(perl.keys(bits), function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) end)) do
                        local w = length(keyStr(k)) + length(bits[k]) + 4
                        if wid < w then wid = w end
                        bits_a[#bits_a + 1] = k
                        if isMatch(bits[k], [=[[\0-\x1f\x7f-\xff]]=]) then
                            warn('Warning: Special characters in ' .. tableName .. ' PrintConv BITMASK (' .. bits[k] .. ")\n")
                        end
                    end
                end
                if wid < length(tableName) + 7 then wid = length(tableName) + 7 end
                -- print in multiple columns if there is room
                local cols = perl.int(110 / (wid + 4))
                local items = #keys + #bits_a
                if cols < 1 or cols > items or items < 4 then cols = 1 end
                local rows = perl.int((items + cols - 1) / cols)
                local r, c
                HTMLFILE:write('<tr class=h>')
                c = 0
                while c < cols do
                    HTMLFILE:write('<th>Value</th><th>' .. head .. '</th>')
                    c = c + 1
                end
                HTMLFILE:write("</tr>\n")
                r = 0
                while r < rows do
                    HTMLFILE:write('<tr>')
                    c = 0
                    while c < cols do
                        local key, val, index, prt, bit
                        local n = r + c * rows
                        if n < #keys then
                            key = keys[n + 1]
                            val = printConv[key]
                            key = keyStr(key)
                        elseif n < items then
                            bit = 1
                            key = 'Bit ' .. keyStr(bits_a[n - #keys + 1])
                            val = bits[bits_a[n - #keys + 1]]
                        end
                        if key ~= nil then
                            index = key
                            prt = '= ' .. EscapeHTML(keyStr(val))
                            if printConv.PrintInt then index = subst(index, [[\.\d+$]], '') end
                            if printConv.PrintHex then
                                local dec = matches(index, [[(\.\d+)$]])
                                index = subst(index, [[(\.\d+)$]], '') -- remove decimal
                                index = sprintf('0x%x', index)
                                if dec then index = index .. dec end -- add back decimal
                            elseif printConv.PrintString or
                                not isMatch(index, [[^[+-]?(?=\d|\.\d)\d*(\.\d*)?$]])
                            then
                                index = EscapeHTML(index)
                                if not bit then index = "'" .. index .. "'" end
                            end
                        else
                            index = '&nbsp;'; prt = index
                        end
                        local ic, pc
                        if (c & 0x01) ~= 0 then
                            pc = ' class=b'
                            ic = align ~= '' and " class='r b'" or pc
                        else
                            ic = align
                            pc = ''
                        end
                        HTMLFILE:write('<td' .. ic .. '>' .. index .. '</td><td' .. pc .. '>' .. prt .. "</td>\n")
                        c = c + 1
                    end
                    HTMLFILE:write('</tr>')
                    r = r + 1
                end
                HTMLFILE:write("</table></td></tr></table></blockquote>\n\n")
            end
            end
            ::nextSepTable::
        end
        if not (#tableNames > 0 or #structs_a > 0) then break end
        do
        local isStruct
        if #structs_a > 0 then
            tableName = remove(structs_a, 1)
            if structs[tableName] == 2 then goto nextTable end -- only list each structure once
            structs[tableName] = 2
            isStruct = structLookup[tableName]
            if not isStruct then warn('Missing structure ' .. tableName .. "\n") goto nextTable end
            if not isMatch(tableName, ' ') then tableName = 'XMP ' .. tableName end
            tableName = tableName .. ' Struct'
            short = tableName
            local maxLen = 0
            for k in pairs(isStruct) do
                if maxLen < length(keyStr(k)) then maxLen = length(keyStr(k)) end
            end
            self.LONG_ID[tableName] = maxLen
        else
            tableName = remove(tableNames, 1)
            short = shortName[tableName]
            if not short then
                -- this is just an index heading
                PODFILE:write("\n=head2 " .. tableName .. " Tags\n")
                if docs[tableName] then PODFILE:write(Doc2Pod(docs[tableName])) end
                goto nextTable
            end
        end
        do
        local isExif = (tableName == 'Image::ExifTool::Exif::Main')
        local isRiff = (tableName == 'Image::ExifTool::RIFF::Info')
        local isXmpMain = (tableName == 'Image::ExifTool::XMP::Main')
        local info = tagNameInfo[tableName] or { }
        local id = idLabel[tableName]
        local hid, showGrp
        -- widths of the different columns in the POD documentation
        local wID, wTag, wReq, wGrp = 8, 36, 24, 10
        local composite, derived, notes, longTags, prefix
        local wasLong = 0
        if short == 'Shortcuts' then
            derived = '<th>Refers To</th>'
            composite = 2
        elseif isStruct then
            derived = ''
            notes = isStruct.NOTES
        else
            local table_ = GetTagTable(tableName)
            notes = table_.NOTES
            if table_.NAMESPACE then
                local ns = XMP.stdXlatNS[table_.NAMESPACE] or table_.NAMESPACE
                local msg = 'These tags belong to the ExifTool XMP-' .. ns .. ' family 1 group.'
                if notes then
                    notes = subst(notes, [[\s+$]], '')
                    notes = notes .. "\n\n" .. msg
                else
                    notes = msg
                end
            end
            if table_.VARS then longTags = table_.VARS.LONG_TAGS end
            if table_.GROUPS[0] == 'Composite' then
                composite = 1
                derived = '<th>Derived From</th>'
            else
                composite = 0
                derived = ''
            end
        end
        local podIdLen = self.LONG_ID[tableName] or 0
        if notes then
            -- remove unnecessary whitespace
            notes = subst(notes, [[^\s+]], ''); notes = subst(notes, [[\s+$]], '')
            notes = subst(notes, [[(?m)(^[ \t]+|[ \t]+$)]], '', 'g')
            local hasPrefix, m1 = isMatch(notes, [[leading '(.*?_)' which]])
            if hasPrefix then
                prefix = m1
                podIdLen = podIdLen - length(prefix)
            end
        end
        if podIdLen <= wID then
            podIdLen = wID
        elseif short == 'DICOM' then
            podIdLen = 10
        else
            -- align tag names in secondary columns if possible
            local col = (podIdLen <= 10) and 12 or 20
            if podIdLen < col then podIdLen = col end
        end
        if id then
            hid = subst('<th>' .. id .. '</th>', ' ', '&nbsp;', 'g')
            wTag = wTag - (podIdLen - wID)
            wID = podIdLen
            local longTag = self.LONG_NAME[tableName] or 0
            if wTag < longTag then
                if wID - longTag + wTag >= 6 then -- don't let ID column get too narrow
                    wID = wID - (longTag - wTag)
                    wTag = longTag
                end
                if wID <= (self.LONG_ID[tableName] or 0) then wasLong = wasLong + 1 end
            end
        elseif perlTruthy(composite) then
            wTag = wTag + wID - wReq
            hid = ''
        else
            wTag = wTag + 9
            hid = ''
        end
        if short == 'EXIF' or short == 'Extra' then
            derived = '<th>Group</th>'
            showGrp = 1
            if short == 'Extra' then wGrp = wGrp + 8 end    -- tweak Group column width for "Extra" tags
            wTag = wTag - (wGrp + 1)
        end
        local head = isMatch(short, ' ') and 'head3' or 'head2'
        local str = isStruct and '' or ' Tags'
        PODFILE:write("\n=" .. head .. ' ' .. short .. str .. "\n")
        if docs[short] then PODFILE:write(Doc2Pod(docs[short])) end
        if notes then PODFILE:write("\n", Doc2Pod(notes), "\n") end
        local line = "\n"
        if id then
            -- shift over 'Index' heading by one character for a bit more balance
            if id == 'Index' then id = ' ' .. id end
            line = line .. sprintf('  %-' .. wID .. 's', id)
        else
            line = line .. ' '
        end
        local tagNameHeading = (short == 'XMP') and 'Namespace' or ((isStruct and 'Field' or 'Tag') .. ' Name')
        line = line .. sprintf(' %-' .. wTag .. 's', tagNameHeading)
        if perlTruthy(composite) then line = line .. sprintf(' %-' .. wReq .. 's', composite == 2 and 'Refers To' or 'Derived From') end
        if showGrp then line = line .. sprintf(' %-' .. wGrp .. 's', 'Group') end
        line = line .. ' Writable'
        PODFILE:write(line)
        line = subst(line, [[^(\s*\w.{6}\w) ]], "$1\t")   -- change space to tab after long ID label (eg. "Sequence")
        line = subst(line, [[\S]], '-', 'g')
        line = subst(line, [[- -]], '---', 'g')
        line = perl.tr(line, "\t", ' ')                  -- change tab back to space
        PODFILE:write(line, "\n")
        HTMLFILE:close()
        if not perlTruthy(OpenHtmlFile(htmldir, short)) then success = 0 end
        if notes then HTMLFILE:write('<p>', Doc2Html(notes), "</p>\n") end
        HTMLFILE:write("<blockquote>\n")
        HTMLFILE:write("<table class=frame><tr><td>\n")
        HTMLFILE:write("<table class=inner cellspacing=1>\n")
        HTMLFILE:write('<tr class=h>' .. hid .. '<th>' .. tagNameHeading .. "</th>\n")
        HTMLFILE:write('<th>Writable</th>' .. derived .. '<th>Values / ' .. noteFont .. "Notes</span></th></tr>\n")
        local rowClass = 1
        local infoCount = 0
        for _, infoList in ipairs(info) do
            infoCount = infoCount + 1
            local tagIDstr, tagNames, writable, values, require, writeGroup = table.unpack(infoList, 1, 6)
            local align, idStr, w, tip
            local wTag2 = wTag
            if not id then
                idStr = '  '
            elseif isMatch(tagIDstr, [[^-?\d+(\.\d+)?$]]) then
                w = wID - 3
                idStr = sprintf('  %' .. w .. 'g    ', tagIDstr)
                local tooLong = length(idStr) - 6 - w
                if tooLong ~= 0 then
                    if tooLong > 3 then tooLong = 3 end
                    idStr = substr(idStr, 0, -tooLong)
                end
                align = ' class=r'
            else
                if prefix then tagIDstr = substDyn(tagIDstr, "^'" .. prefix, "'") end
                w = wID
                local over = length(tagIDstr) - w
                if over > 0 then
                    -- shift over tag name if there is room
                    if over <= wTag - length(tagNames[1]) then
                        wTag2 = wTag2 - over
                        w = w + over
                        wasLong = wasLong - 1
                    else
                        -- put tag name on next line if ID is too long
                        idStr = '  ' .. tagIDstr .. "\n   " .. string.rep(' ', w)
                        if perlTruthy(longTags) then
                            longTags = longTags - 1
                        else
                            warn('Notice: Split ' .. tagNames[1] .. " line\n")
                        end
                    end
                end
                if idStr == nil then idStr = sprintf('  %-' .. w .. 's ', tagIDstr) end
                align = ''
            end
            local reqs = { }
            local tags = { table.unpack(tagNames) }
            local wGrp_a = { table.unpack(writeGroup) }
            local vals = { table.unpack(writable) }
            local wrStr = remove(vals, 1)
            local subdir
            local masks = perl.grep([=[^\[val( >> \d+)? \& 0x[\da-f]+\]]=], values)
            local tag = remove(tags, 1)
            -- if this is a subdirectory or structure, print subdir name (from values) instead of writable
            if isMatch(wrStr, [=[^[-=]]=]) then
                subdir = 1
                if #masks > 0 then
                    -- combine any mask into the format string
                    wrStr = wrStr .. PodMask(masks[1])
                    remove(masks, 1)
                    vals = { }
                    for _, v in ipairs(values) do
                        if not isMatch(v, [=[^\[val( >> \d+)? \& 0x[\da-f]+\]]=]) then vals[#vals + 1] = v end
                    end
                else
                    vals = { table.unpack(values) }
                end
                -- remove Notes if subdir has Notes as well
                if vals[1] and isMatch(vals[1], [[^\(]]) and #vals >= #writable then remove(vals, 1) end
                for i, v in ipairs(vals) do if isMatch(v, [[^\(]]) then vals[i] = '-' end end
                local i = 0  -- fill in any missing entries from non-directory tags
                while i < #writable do
                    if vals[i + 1] == nil then vals[i + 1] = writable[i + 1] end
                    if #masks > 0 then
                        vals[i + 1] = vals[i + 1] .. PodMask(masks[1])
                        remove(masks, 1)
                    end
                    i = i + 1
                end
                if sepTable[vals[1]] then
                    wrStr = subst(wrStr, [=[^[-=]]=], '')
                    if wrStr == '' then wrStr = 'no' end
                elseif structs[vals[1]] then
                    local flags = matches(wrStr, [[([+_]+)$]]) or ''
                    wrStr = vals[1] .. ' Struct' .. flags
                else
                    wrStr = vals[1]
                end
                remove(vals, 1)
            elseif perlTruthy(wrStr) and wrStr ~= 'no' and #masks > 0 then
                -- fill in missing entries if masks are different
                local mask = remove(masks, 1)
                while #masks > #vals do
                    if masks[#vals + 1] == mask then break end
                    vals[#vals + 1] = wrStr
                    if #tags < #vals then tags[#tags + 1] = tag end
                end
                -- add Mask to Writable column in POD doc
                wrStr = wrStr .. PodMask(mask)
            end
            local pod = sprintf('%s%-' .. wTag2 .. 's', idStr, tag)
            local tGrp = wGrp
            if id and length(tag) > wTag2 then
                local madeRoom
                if showGrp then
                    local wGrp0 = length(wGrp_a[1] or '-')
                    if not perlTruthy(composite) and wGrp > wGrp0 then
                        tGrp = wGrp - (length(tag) - wTag2)
                        if tGrp < length(keyStr(wGrp0)) then
                            tGrp = length(keyStr(wGrp0))
                        else
                            madeRoom = 1
                        end
                    end
                end
                if not madeRoom then warn('Warning: Pushed ' .. tag .. "\n") end
            end
            if showGrp then pod = pod .. sprintf(' %-' .. tGrp .. 's', remove(wGrp_a, 1) or '-') end
            if perlTruthy(composite) then
                reqs = { table.unpack(require) }
                w = wReq -- Keep writable column in line
                if length(tag) > wTag2 then w = w - (length(tag) - wTag2) end
                pod = pod .. sprintf(' %-' .. w .. 's', remove(reqs, 1) or '')
            end
            pod = pod .. ' ' .. wrStr
            -- limit line length to 82 characters (even if it means messing up column alignment)
            if length(pod) > 82 and not isMatch(pod, "\n") then
                local remove_ = length(pod) - 82
                pod = substDyn(pod, [[(\w)\s{]] .. remove_ .. '}', '$1')
            end
            PODFILE:write(pod, "\n")
            local numTags = #tagNames
            local n = 0
            while #tags > 0 or #reqs > 0 or #vals > 0 do
                local more = (#tags > 0 or #reqs > 0)
                line = '  '
                if id then line = line .. string.rep(' ', wID + 1) end
                line = line .. sprintf('%-' .. wTag2 .. 's', remove(tags, 1) or '')
                if perlTruthy(composite) then line = line .. sprintf(' %-' .. wReq .. 's', remove(reqs, 1) or '') end
                if showGrp then line = line .. sprintf(' %-' .. wGrp .. 's', remove(wGrp_a, 1) or '-') end
                n = n + 1
                if #vals > 0 then
                    local val = remove(vals, 1)
                    -- use writable if this is a note
                    local wrStr_ = writable[n + 1]
                    if subdir and (isMatch(val, [[^\(]]) or isMatch(val, '=') or (wrStr_ and not isMatch(wrStr_, [=[^[-=]]=]))) then
                        val = wrStr_
                        if val ~= nil then
                            val = subst(val, [=[^[-=]]=], '')
                        else
                            -- done with tag if nothing else to print
                            if not more then break end
                        end
                    end
                    if val ~= nil then
                        line = line .. ' ' .. val
                        if #masks > 0 then
                            line = line .. PodMask(masks[1])
                            remove(masks, 1)
                        end
                    end
                end
                line = subst(line, [[\s+$]], '')  -- trim trailing white space
                PODFILE:write(line .. "\n")
            end
            local htmlTags = { }
            for _, t in ipairs(tagNames) do
                htmlTags[#htmlTags + 1] = EscapeHTML(t)
            end
            local okR, r1 = isMatch(tagIDstr, [[(\w+)]])
            local okX, x1 = isMatch(tagIDstr, [[([-\w]+)]])
            if (isExif and Validate.exifSpec[hex(tagIDstr)]) or
                (isRiff and okR and riffSpec[r1]) or
                (isXmpMain and okX and xmpSpec[x1])
            then
                -- underline "unknown" makernote tags only
                local n_ = tagIDstr == '0x927c' and #htmlTags or 1
                htmlTags[n_] = '<u>' .. htmlTags[n_] .. '</u>'
            end
            rowClass = perlTruthy(rowClass) and '' or ' class=b'
            local isSubdir
            if isMatch(writable[1], [=[^[-=]]=]) then
                isSubdir = 1
                for i, v in ipairs(writable) do writable[i] = subst(v, [[^[-=](.+)]], '$1') end
            end
            -- add tooltip for hex conversion of Tag ID
            local okH, h1, h2 = isMatch(tagIDstr, [[(?i)^(0x[0-9a-f]+)(\.\d+)?$]])
            local okD, d1 = isMatch(tagIDstr, [[^(\d+)(\.\d*)?$]])
            if okH then
                tip = sprintf(" title='" .. tagIDstr .. " = %u%s'", hex(h1), h2 or '')
            elseif okD then
                tip = sprintf(" title='%u = 0x%x'", d1, d1)
            else
                tip = ''
                -- use copyright symbol in QuickTime UserData tags
                tagIDstr = subst(tagIDstr, [[^"\\xa9]], '"&copy;')
                -- escape necessary characters in html
                tagIDstr = subst(tagIDstr, '>', '&gt;', 'g')
                tagIDstr = subst(tagIDstr, '<', '&lt;', 'g')
            end
            -- add tooltip for special writable attributes
            local wtip = ''
            local wattr = {
                ['_'] = 'Flattened',
                ['+'] = 'List',
                ['/'] = 'Avoid',
                ['~'] = 'Writable only with -n',
                ['!'] = 'Unsafe',
                ['*'] = 'Protected',
                [':'] = 'Mandatory',
                ['^'] = 'Deletable',
            }
            local hasAttr, hasAttr_a = { }, { }
            for _, wstr in ipairs(writable) do
                local m = matches(wstr, [[([+/~!*:_^]+)$]])
                if m then
                    local a = split('', m)
                    for _, ch in ipairs(a) do
                        if not hasAttr[ch] then
                            hasAttr_a[#hasAttr_a + 1] = ch
                            hasAttr[ch] = 1
                        end
                    end
                end
            end
            if #hasAttr_a > 0 then
                wtip = " title='"
                local n_ = 0
                for _, ch in ipairs(hasAttr_a) do
                    if n_ ~= 0 then wtip = wtip .. "\n" end
                    wtip = wtip .. ' ' .. ch .. ' = ' .. wattr[ch]
                    n_ = n_ + 1
                end
                wtip = wtip .. "'"
            end
            -- print this row in the tag table
            HTMLFILE:write('<tr' .. rowClass .. ">\n")
            if id then HTMLFILE:write('<td' .. align .. tip .. '>' .. tagIDstr .. "</td>\n") end
            HTMLFILE:write('<td>', join("\n  <br>", htmlTags), "</td>\n")
            HTMLFILE:write('<td class=c' .. wtip .. '>', join('<br>', writable), "</td>\n")
            if perlTruthy(composite) then HTMLFILE:write('<td class=n>', join("\n  <br>", require), "</td>\n") end
            if showGrp then HTMLFILE:write('<td class=c>', join('<br>', writeGroup), "</td>\n") end
            HTMLFILE:write('<td>')
            if #values > 0 then
                if isSubdir then
                    local smallNote, values_a = nil, { }
                    for i, v in ipairs(values) do
                        if isMatch(v, [[^\(]]) then
                            v = Doc2Html(v)
                            values[i] = v
                            -- set the note font
                            if numTags < 2 then smallNote = 1 end
                            values_a[#values_a + 1] = (smallNote and noteFontSmall or noteFont) .. v .. '</span>'
                            goto nextValue
                        end
                        -- make text in square brackets small
                        if isMatch(v, [[^\[]]) then
                            if isMatch(v, [=[^\[!HTML\]]=]) then
                                v = subst(v, [=[^\[!HTML\]]=], '')
                                values[i] = v
                                values_a[#values_a + 1] = v
                            else
                                v = Doc2Html(v)
                                values[i] = v
                                values_a[#values_a + 1] = '<span class=s>' .. v .. '</span>'
                            end
                            goto nextValue
                        end
                        if isMatch(v, '=') then values_a[#values_a + 1] = v goto nextValue end
                        do
                        local names = split(' ', v)
                        local suffix = ' Tags'
                        if sepTable[v] then
                            sepTables[#sepTables + 1] = v
                            suffix = ' Values'
                        end
                        -- handle structures specially
                        if structs[v] then
                            -- assume XMP module for this struct unless otherwise specified
                            if not isMatch(v, ' ') then insert(names, 1, 'XMP') end
                            structs_a[#structs_a + 1] = v  -- list this later
                            -- hack to put Area Struct in with XMP tags,
                            -- even though it is only used by the MWG module
                            if v == 'Dimensions' then structs_a[#structs_a + 1] = 'Area' end
                            suffix = ' Struct'
                        end
                        url = remove(names, 1) .. '.html'
                        if #names > 0 then url = url .. '#' .. join('_', names) end
                        values_a[#values_a + 1] = "--&gt; <a href='" .. url .. "'>" .. v .. suffix .. '</a>'
                        end
                        ::nextValue::
                    end
                    -- put small note last
                    if smallNote then values_a[#values_a + 1] = remove(values_a, 1) end
                    HTMLFILE:write(join("\n  <br>", values_a))
                else
                    local close, br = '', ''
                    for i, v in ipairs(values) do
                        if isMatch(v, [=[^\[!HTML\]]=]) then
                            v = subst(v, [=[^\[!HTML\]]=], '')
                            values[i] = v
                            if close ~= '' then HTMLFILE:write(close) end
                            HTMLFILE:write(v)
                            close = ''; br = ''
                        else
                            if isMatch(v, [[^\(]]) then
                                -- notes can use POD syntax
                                v = noteFont .. Doc2Html(v) .. '</span>'
                            else
                                v = EscapeHTML(v)
                            end
                            if close == '' then v = '<span class=s>' .. v; close = '</span>' end
                            values[i] = v
                            HTMLFILE:write(br, v)
                            br = "\n  <br>"
                        end
                    end
                    if close ~= '' then HTMLFILE:write(close) end
                end
            else
                HTMLFILE:write('&nbsp;')
            end
            HTMLFILE:write("</td></tr>\n")
        end
        if perlTruthy(longTags) then warn(longTags .. ' unaccounted-for long tags in ' .. tableName .. "\n") end
        if wasLong ~= 0 and longTags == nil then
            warn('Notice: Long tags in ' .. tableName .. " table\n")
        end
        if infoCount == 0 then
            PODFILE:write("  [no tags known]\n")
            local cols = 3
            if hid ~= '' then cols = cols + 1 end
            if derived ~= '' then cols = cols + 1 end
            HTMLFILE:write('<tr><td colspan=' .. cols .. " class=c><i>[no tags known]</i></td></tr>\n")
        end
        HTMLFILE:write("</table></td></tr></table></blockquote>\n\n")
        end
        end
        ::nextTable::
    end
    if not HTMLFILE:close() then success = 0 end
    if not perlTruthy(CloseHtmlFiles(self)) then success = 0 end
    if not PODFILE:write(Doc2Pod(docs.PodTrailer)) then success = 0 end
    if not PODFILE:close() then success = 0 end
    return success
end

return BuildTagLookup
