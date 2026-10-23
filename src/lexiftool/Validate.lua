--------------------------------------------------------------------------------
-- File:         lexiftool/Validate.lua
-- Ported from:  lib/Image/ExifTool/Validate.pm
--
-- Description:  Additional metadata validation
--
-- Created:      2017/01/18 - P. Harvey
--
-- Notes:        My apologies for the convoluted logic contained herein, but it
--               is done this way to retro-fit the Validate feature into the
--               existing ExifTool code while reducing the possibility of
--               introducing bugs or slowing down processing when this feature
--               is not used.
--
-- Port notes:   Full port of Validate.pm: all six data tables plus
--               %validateInfo, and ValidateRaw, ValidateExifDate,
--               ValidateXMPDate, ValidateExif, ValidateOffsetInfo and
--               FinishValidate, in upstream order.
--
--               %validValue holds Perl code strings that upstream `eval`s
--               with $val and %val in scope; per conventions.md §5 they
--               become Lua functions of the same two values, in the same
--               story order.  Their two arguments keep upstream's names as
--               closely as Lua allows: `val` is Perl's `$val` (the value of
--               the tag being checked) and `valH` is Perl's `%val` (the
--               group's tagID -> value lookup) -- Perl's separate scalar and
--               hash namespaces have no Lua equivalent, so `%val` is the one
--               that gets renamed.  The functions return exactly what the
--               eval'd Perl returns: 1 (OK), '' (generic failure), or an
--               error-message string; FinishValidate's `not defined $result`
--               branch is reached when the function itself raises an error
--               (upstream: when the eval dies).
--               An upstream entry whose value is `undef` ("tag must not
--               exist") is stored as `false`, since a nil value would remove
--               the key from the table altogether and the key itself is what
--               the `foreach $tag (sort keys %$validValue)` loop needs.
--
--               Wired where upstream wires it.  Every call of a function in
--               this module is pulled in:
--                 - ExifTool.pm:2679-2681 -> Options: setting 'Validate'
--                   loads this module.
--                 - ExifTool.pm:2757 -> ExtractInfo: a requested `validate`
--                   tag turns the option on.
--                 - ExifTool.pm:4454 -> DoneExtract: FinishValidate.
--                 - ExifTool.pm:5628 -> Warn: ignorable == 3 is silenced.
--                 - ExifTool.pm:9623 -> FoundTag: ValidateRaw.
--                 - Exif.pm:6500 -> ProcessExif: ValidateExif.
--                 - Exif.pm:7199 -> ProcessExif: ValidateOffsetInfo (which
--                   needed ProcessExif's %offsetInfo, also added).
--               The tag-level `Validate` code strings these read are carried
--               over too: Exif.pm:915/2252/2262 (ValidateExifDate on
--               ModifyDate/DateTimeOriginal/CreateDate) and XMP.pm:240
--               (ValidateXMPDate in %dateTimeInfo).
--               Two further Validate-gated blocks of Exif.pm's ProcessExif
--               come along because they are what the above checks are read
--               next to: Exif.pm:6511-6527 (Odd/Invalid offset, value
--               overlaps IFD / another value) and ExifTool.pm:9183
--               (GetTagInfo returns Unknown tags under Validate).
--
--               The module-local Validate-gated checks of the other ported
--               modules are wired where upstream wires them, too:
--                 - Exif.pm:6314-6332 -> Exif.lua ProcessExif: "Non-standard
--                   EXIF at <path>" / "Duplicate EXIF at <path>".
--                 - Exif.pm:6747-6755 -> Exif.lua ProcessExif: "Wrong format
--                   (%s) for ..." on offset-type tags, which is what sets
--                   $$et{WrongFormat} for FinishValidate.
--                 - ExifTool.pm:7653/7660 -> ProcessJPEG: keep scanning to
--                   EOI, and read the trailer for Sony HiddenData.
--                 - ExifTool.pm:8458 -> ProcessJPEG: "Unknown <marker>
--                   segment" for every segment whose branch leaves
--                   $dumpType empty (all APPn branches are ported, so it
--                   fires where upstream fires, e.g. the J2C SIZ marker).
--                 - IPTC.pm:1086/1162/1190/1201/1230/1242 -> IPTC.lua
--                   ProcessIPTC: "Non-standard IPTC at", "Records out of
--                   sequence", "Multiple IPTC ... tags", "IPTC ... too
--                   short/long", "improperly terminated".
--                 - XMP.pm:3688/4028/4102/4144/4206/4286-4290/4570 and
--                   WriteXMP.pl:98-143 -> XMP.lua: the XmpValidate
--                   machinery (ValidateProperty with its "Non-standard XMP
--                   property"/"Duplicate XMP property"/"Improperly enclosed
--                   XMP property"/"Duplicate language" warnings, the
--                   boolean-capitalization check, "Wrong namespace for
--                   xmpmeta", "Different 'rdf:about' attributes",
--                   "Non-standard XMP at"/"Duplicate XMP at", and "XMP is
--                   missing xpacket wrapper").
--                 - PNG.pm:974 -> PNG.lua FoundPNG: "Non-standard <what> in
--                   PNG <chunk> chunk".
--                 - Photoshop.pm:1029 -> Photoshop.lua ProcessPhotoshop:
--                   "Non-standard Photoshop at <path>".
--                 - PDF.pm:1859/1895 -> PDF.lua ProcessDict: "PDF... is
--                   deprecated in PDF 2.0".
--                 - RIFF.pm:2033 -> RIFF.lua:1683, M2TS.pm:349 ->
--                   M2TS.lua:360 (both were already there).
--                 - Exif.pm:5562-5598 -> Exif.lua ConvertExifText: "<type>
--                   text header ... has spaces instead of nulls" and "Wrong
--                   byte order for EXIF ... text" (WrongByteOrder is set by
--                   Charset.lua's Decode).
--                 - PNG.pm:851 -> PNG.lua ConvertPNGDate: "Non standard PNG
--                   date/time format".
--                 - PNG.pm:1448/1586/1612 -> PNG.lua ProcessPNG: under
--                   Validate the data chunks are read and CRC-checked ("Bad
--                   CRC for <chunk> chunk").
--                 - QuickTime.pm:8408/9939/10079-10092 -> QuickTime.lua:
--                   "Invalid 'wide' atom size", "Duplicate <tag> at <path>"
--                   (%dupTagOK, %dupDirOK, $$et{ValidatePath}).
--                 - Sony.pm:10976/11057 -> Sony.lua HiddenData/
--                   ReadHiddenData: "Fixed incorrect HiddenDataOffset".
--                 - XMP.pm:3776-3986/4216-4229 -> XMP.lua ParseXMPElement:
--                   the per-scope %definedNS/%usedNS bookkeeping and its
--                   "Undefined XMP namespace"/"XMP namespace <ns> is used
--                   out of scope" warnings.
--               Where upstream gates a check on
--               `$Image::ExifTool::MWG::strict or ...Validate`, so does the
--               port (ExifTool.MWGstrict, lexiftool.lua).
--
--               Not pulled in, because it is dead code upstream:
--                 - exiftool:2417 -- the CLI's `$$et{Validate}` exit-code
--                   test.  That member is never assigned anywhere in
--                   upstream (the option lives in $$et{OPTIONS}{Validate}),
--                   so the test is always false and porting it would add
--                   dead code.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch, isMatchDyn = perl.isMatch, perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local length = perl.length
local truthy = perl.truthy
local D = perl.D
local num = perl.num
local sprintf = perl.sprintf
local tsort = perl.tsort
local perlStr = perl.str
local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local uc = perl.uc

local Validate = {}

-- Perl's `sort keys %h` (string sort, as everywhere upstream relies on it).
local function sortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    tsort(keys, function(a, b) return perl.lt(perlStr(a), perlStr(b)) end)
    return keys
end

-- Perl's `sort { $a <=> $b } keys %h` (numeric sort).
local function sortedNumKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    tsort(keys, function(a, b) return num(a) < num(b) end)
    return keys
end

-- Perl's `A xor B` on two values tested for Perl truth.
local function xor(a, b)
    return (truthy(a) and true or false) ~= (truthy(b) and true or false)
end

-- EXIF table tag ID's which are part of the EXIF 2.32 specification
-- (with ExifVersion numbers for tags where I can determine the version)
-- (also used by BuildTagLookup to add underlines in HTML version of EXIF Tag Table)
Validate.exifSpec = {
    [0x1] = 210,
    [0x100] = 1,  [0x8298] = 1,   [0x9207] = 1,   [0xa217] = 1,
    [0x101] = 1,  [0x829a] = 1,   [0x9208] = 1,   [0xa300] = 1,
    [0x102] = 1,  [0x829d] = 1,   [0x9209] = 1,   [0xa301] = 1,
    [0x103] = 1,  [0x8769] = 1,   [0x920a] = 1,   [0xa302] = 1,
    [0x106] = 1,  [0x8822] = 1,   [0x9214] = 220, [0xa401] = 220,
    [0x10e] = 1,  [0x8824] = 1,   [0x927c] = 1,   [0xa402] = 220,
    [0x10f] = 1,  [0x8825] = 200, [0x9286] = 1,   [0xa403] = 220,
    [0x110] = 1,  [0x8827] = 1,   [0x9290] = 1,   [0xa404] = 220,
    [0x111] = 1,  [0x8828] = 1,   [0x9291] = 1,   [0xa405] = 220,
    [0x112] = 1,  [0x8830] = 230, [0x9292] = 1,   [0xa406] = 220,
    [0x115] = 1,  [0x8831] = 230, [0x9400] = 231, [0xa407] = 220,
    [0x116] = 1,  [0x8832] = 230, [0x9401] = 231, [0xa408] = 220,
    [0x117] = 1,  [0x8833] = 230, [0x9402] = 231, [0xa409] = 220,
    [0x11a] = 1,  [0x8834] = 230, [0x9403] = 231, [0xa40a] = 220,
    [0x11b] = 1,  [0x8835] = 230, [0x9404] = 231, [0xa40b] = 220,
    [0x11c] = 1,  [0x9000] = 1,   [0x9405] = 231, [0xa40c] = 220,
    [0x128] = 1,  [0x9003] = 1,   [0xa000] = 1,   [0xa460] = 232,
    [0x12d] = 1,  [0x9004] = 1,   [0xa001] = 1,   [0xa461] = 232,
    [0x131] = 1,  [0x9010] = 231, [0xa002] = 1,   [0xa462] = 232,
    [0x132] = 1,  [0x9011] = 231, [0xa003] = 1,   [0xa420] = 220,
    [0x13b] = 1,  [0x9012] = 231, [0xa004] = 1,   [0xa430] = 230,
    [0x13e] = 1,  [0x9101] = 1,   [0xa005] = 210, [0xa431] = 230,
    [0x13f] = 1,  [0x9102] = 1,   [0xa20b] = 1,   [0xa432] = 230,
    [0x201] = 1,  [0x9201] = 1,   [0xa20c] = 1,   [0xa433] = 230,
    [0x202] = 1,  [0x9202] = 1,   [0xa20e] = 1,   [0xa434] = 230,
    [0x211] = 1,  [0x9203] = 1,   [0xa20f] = 1,   [0xa435] = 230,
    [0x212] = 1,  [0x9204] = 1,   [0xa210] = 1,   [0xa500] = 221,
    [0x213] = 1,  [0x9205] = 1,   [0xa214] = 1,
    [0x214] = 1,  [0x9206] = 1,   [0xa215] = 1,

    -- new Exif 3.0 tags
    [0xa436] = 300,
    [0xa437] = 300,
    [0xa438] = 300,
    [0xa439] = 300,
    [0xa43a] = 300,
    [0xa43b] = 300,
    [0xa43c] = 300,

    -- new Exif 3.1 tags
    [0x9287] = 310,
    [0xa40d] = 310,
    [0xa40e] = 310,
    [0xa40f] = 310,
    [0xa410] = 310,
    [0xa411] = 310,
    [0xa412] = 310,
}
local exifSpec = Validate.exifSpec

-- GPSVersionID numbers when each tag was introduced
local gpsVer = {
    [0x01] = 2000,  [0x09] = 2000,  [0x11] = 2000,  [0x19] = 2000,
    [0x02] = 2000,  [0x0a] = 2000,  [0x12] = 2000,  [0x1a] = 2000,
    [0x03] = 2000,  [0x0b] = 2000,  [0x13] = 2000,  [0x1b] = 2200,
    [0x04] = 2000,  [0x0c] = 2000,  [0x14] = 2000,  [0x1c] = 2200,
    [0x05] = 2000,  [0x0d] = 2000,  [0x15] = 2000,  [0x1d] = 2200,
    [0x06] = 2000,  [0x0e] = 2000,  [0x16] = 2000,  [0x1e] = 2200,
    [0x07] = 2000,  [0x0f] = 2000,  [0x17] = 2000,  [0x1f] = 2300,
    [0x08] = 2000,  [0x10] = 2000,  [0x18] = 2000,
}

-- lookup to check version numbers
local verCheck = {
    ExifIFD    = { ExifVersion = exifSpec },
    InteropIFD = { ExifVersion = exifSpec },
    GPS        = { GPSVersionID = gpsVer },
}

-- tags standard in various RAW file formats or IFD's
local otherSpec = {
    CR2 = { [0xc5d8] = 1, [0xc5d9] = 1, [0xc5e0] = 1, [0xc640] = 1, [0xc6dc] = 1, [0xc6dd] = 1 },
    NEF = { [0x9216] = 1, [0x9217] = 1 },
    DNG = { [0x882a] = 1, [0x9211] = 1, [0x9216] = 1 },
    ARW = { [0x7000] = 1, [0x7001] = 1, [0x7010] = 1, [0x7011] = 1, [0x7020] = 1, [0x7031] = 1,
            [0x7032] = 1, [0x7034] = 1, [0x7035] = 1, [0x7036] = 1, [0x7037] = 1, [0x7038] = 1,
            [0x7310] = 1, [0x7313] = 1, [0x7316] = 1, [0x74c7] = 1, [0x74c8] = 1, [0xa500] = 1 },
    RW2 = { All = 1 },    -- ignore all unknown tags in RW2
    RWL = { All = 1 },
    RAF = { All = 1 },    -- (temporary)
    DCR = { All = 1 },
    KDC = { All = 1 },
    JXR = { All = 1 },
    SRW = { [0xa010] = 1, [0xa011] = 1, [0xa101] = 1, [0xa102] = 1 },
    NRW = { [0x9216] = 1, [0x9217] = 1 },
    X3F = { [0xa500] = 1 },
    CameraIFD = { All = 1 }, -- (exists in JPG and DNG of Leica Q3 images)
}

-- standard format for tags (not necessary for exifSpec or GPS tags where Writable is defined)
local stdFormat = {
    ExifIFD = {
        [0xa002] = 'int(16|32)u',
        [0xa003] = 'int(16|32)u',
    },
    InteropIFD = {
        [0x01]   = 'string',
        [0x02]   = 'undef',
        [0x1000] = 'string',
        [0x1001] = 'int(16|32)u',
        [0x1002] = 'int(16|32)u',
    },
    IFD = {
        -- TIFF, EXIF, XMP, IPTC, ICC_Profile and PrintIM standard tags:
        [0xfe]  = 'int32u',      [0x11f] = 'rational64u', [0x14a] = 'int32u',      [0x205] = 'int16u',
        [0xff]  = 'int16u',      [0x120] = 'int32u',      [0x14c] = 'int16u',      [0x206] = 'int16u',
        [0x100] = 'int(16|32)u', [0x121] = 'int32u',      [0x14d] = 'string',      [0x207] = 'int32u',
        [0x101] = 'int(16|32)u', [0x122] = 'int16u',      [0x14e] = 'int16u',      [0x208] = 'int32u',
        [0x107] = 'int16u',      [0x123] = 'int16u',      [0x150] = 'int(8|16)u',  [0x209] = 'int32u',
        [0x108] = 'int16u',      [0x124] = 'int32u',      [0x151] = 'string',      [0x211] = 'rational64u',
        [0x109] = 'int16u',      [0x125] = 'int32u',      [0x152] = 'int16u',      [0x212] = 'int16u',
        [0x10a] = 'int16u',      [0x129] = 'int16u',      [0x153] = 'int16u',      [0x213] = 'int16u',
        [0x10d] = 'string',      [0x13c] = 'string',      [0x154] = '.*',          [0x214] = 'rational64u',
        [0x111] = 'int(16|32)u', [0x13d] = 'int16u',      [0x155] = '.*',          [0x2bc] = 'int8u',
        [0x116] = 'int(16|32)u', [0x140] = 'int16u',      [0x156] = 'int16u',      [0x828d] = 'int16u',
        [0x117] = 'int(16|32)u', [0x141] = 'int16u',      [0x15b] = 'undef',       [0x828e] = 'int8u',
        [0x118] = 'int16u',      [0x142] = 'int(16|32)u', [0x200] = 'int16u',      [0x83bb] = 'int32u',
        [0x119] = 'int16u',      [0x143] = 'int(16|32)u', [0x201] = 'int32u',      [0x8649] = 'int8u',
        [0x11d] = 'string',      [0x144] = 'int32u',      [0x202] = 'int32u',      [0x8773] = 'undef',
        [0x11e] = 'rational64u', [0x145] = 'int(16|32)u', [0x203] = 'int16u',      [0xc4a5] = 'undef',
        -- Windows Explorer tags:
        [0x9c9b] = 'int8u',      [0x9c9d] = 'int8u',      [0x9c9f] = 'int8u',
        [0x9c9c] = 'int8u',      [0x9c9e] = 'int8u',
        -- GeoTiff tags:
        [0x830e] = 'double',     [0x8482] = 'double',     [0x87af] = 'int16u',     [0x87b1] = 'string',
        [0x8480] = 'double',     [0x85d8] = 'double',     [0x87b0] = 'double',
        -- DNG tags: (use '' for non-DNG tags in the range 0xc612-0xcd48)
        [0xc615] = '(string|int8u)',              [0xc6f4] = '(string|int8u)',    [0xcd49] = 'float',
        [0xc61a] = '(int16u|int32u|rational64u)', [0xc6f6] = '(string|int8u)',    [0xcd4a] = 'int32u',
        [0xc61d] = 'int(16|32)u',                 [0xc6f8] = '(string|int8u)',    [0xcd4b] = 'int32u',
        [0xc61f] = '(int16u|int32u|rational64u)', [0xc6fe] = '(string|int8u)',
        [0xc620] = '(int16u|int32u|rational64u)', [0xc716] = '(string|int8u)',
        [0xc628] = '(int16u|rational64u)',        [0xc717] = '(string|int8u)',
        [0xc634] = 'int8u',                       [0xc718] = '(string|int8u)',
        [0xc640] = '',                            [0xc71e] = 'int(16|32)u',
        [0xc660] = '',                            [0xc71f] = 'int(16|32)u',
        [0xc68b] = '(string|int8u)',              [0xc791] = 'int(16|32)u',
        [0xc68d] = 'int(16|32)u',                 [0xc792] = 'int(16|32)u',
        [0xc68e] = 'int(16|32)u',                 [0xc793] = '(int16u|int32u|rational64u)',
        [0xc6d2] = '',                            [0xcd43] = 'int(16|32)u',
        [0xc6d3] = '',                            [0xcd48] = '(string|int8u)',

        -- Exif 3.0 spec
        [0x10e]  = 'string|utf8',  [0xa430] = 'string|utf8',  [0xa439] = 'string|utf8',
        [0x10f]  = 'string|utf8',  [0xa433] = 'string|utf8',  [0xa43a] = 'string|utf8',
        [0x110]  = 'string|utf8',  [0xa434] = 'string|utf8',  [0xa43b] = 'string|utf8',
        [0x131]  = 'string|utf8',  [0xa436] = 'string|utf8',  [0xa43c] = 'string|utf8',
        [0x13b]  = 'string|utf8',  [0xa437] = 'string|utf8',  -- luacheck: ignore
        [0x8298] = 'string|utf8',  [0xa438] = 'string|utf8',
    },
}

-- generate lookup for any IFD
local stdFormatAnyIFD = {}
for _, k in ipairs(sortedKeys(stdFormat)) do
    for tag, fmt in pairs(stdFormat[k]) do stdFormatAnyIFD[tag] = fmt end
end

-- tag values to validate based on file type (from EXIF specification)
-- - validation code may access $val and %val, and returns 1 on success,
--   or error message otherwise ('' for a generic message)
-- - entry is undef if tag must not exist (same as 'not defined $val' in code)
local validValue = {
    JPEG = {
        IFD0 = {
            [0x100] = false,    -- ImageWidth
            [0x101] = false,    -- ImageLength
            [0x102] = false,    -- BitsPerSample
            [0x103] = false,    -- Compression
            [0x106] = false,    -- PhotometricInterpretation
            [0x111] = false,    -- StripOffsets
            [0x115] = false,    -- SamplesPerPixel
            [0x116] = false,    -- RowsPerStrip
            [0x117] = false,    -- StripByteCounts
            -- (optional as of 3.0) 0x11a => 'defined $val',        # XResolution
            -- (optional as of 3.0) 0x11b => 'defined $val',        # YResolution
            [0x11c] = false,    -- PlanarConfiguration
            -- (optional as of 3.0) 0x128 => '$val =~ /^[123]$/',   # ResolutionUnit
            [0x201] = false,    -- JPEGInterchangeFormat
            [0x202] = false,    -- JPEGInterchangeFormatLength
            [0x212] = false,    -- YCbCrSubSampling
            [0x213] = function(val) return matches(val, [[^[12]$]]) ~= nil and 1 or '' end,    -- YCbCrPositioning
        },
        IFD1 = {
            [0x100] = false,    -- ImageWidth
            [0x101] = false,    -- ImageLength
            [0x102] = false,    -- BitsPerSample
            [0x103] = function(val) return num(val) == 6 and 1 or '' end,     -- Compression
            [0x106] = false,    -- PhotometricInterpretation
            [0x111] = false,    -- StripOffsets
            [0x115] = false,    -- SamplesPerPixel
            [0x116] = false,    -- RowsPerStrip
            [0x117] = false,    -- StripByteCounts
            [0x11a] = function(val) return D(val) and 1 or '' end,            -- XResolution
            [0x11b] = function(val) return D(val) and 1 or '' end,            -- YResolution
            [0x11c] = false,    -- PlanarConfiguration
            [0x128] = function(val) return matches(val, [[^[123]$]]) ~= nil and 1 or '' end,   -- ResolutionUnit
            [0x201] = function(val) return D(val) and 1 or '' end,            -- JPEGInterchangeFormat
            [0x202] = function(val) return D(val) and 1 or '' end,            -- JPEGInterchangeFormatLength
            [0x212] = false,    -- YCbCrSubSampling
        },
        ExifIFD = {
            [0x9000] = function(val) return (D(val) and matches(val, [[^\d{4}$]]) ~= nil) and 1 or '' end, -- ExifVersion
            [0x9101] = function(val) return D(val) and 1 or '' end,           -- ComponentsConfiguration
            -- (optional as of 3.0) 0xa000 => 'defined $val',       # FlashpixVersion
            [0xa001] = function(val) return (num(val) == 1 or num(val) == 0xffff) and 1 or '' end,    -- ColorSpace
            [0xa002] = function(val) return D(val) and 1 or '' end,           -- PixelXDimension
            [0xa003] = function(val) return D(val) and 1 or '' end,           -- PixelYDimension
        },
        GPS = {
            [0x00] = function(val) return (D(val) and matches(val, [[^\d \d \d \d$]]) ~= nil) and 1 or '' end, -- GPSVersionID
            [0x1b] = function(val) return (not D(val) or matches(val, [[^(GPS|CELLID|WLAN|MANUAL)$]]) ~= nil) and 1 or '' end, -- GPSProcessingMethod
        },
        InteropIFD = { },       -- (needed for ExifVersion check)
    },
    TIFF = {
        IFD0 = {
            [0x100] = function(val) return D(val) and 1 or '' end,            -- ImageWidth
            [0x101] = function(val) return D(val) and 1 or '' end,            -- ImageLength
            -- (default is 1) 0x102 => 'defined $val',        # BitsPerSample
            [0x103] = function(val, valH)
                return (not D(val) or matches(val, [[^(1|5|6|32773)$]]) ~= nil or
                    (num(val) == 2 and (not D(valH[0x102]) or num(valH[0x102]) == 1))) and 1 or ''
            end, -- Compression
            [0x106] = function(val) return matches(val, [[^[0123]$]]) ~= nil and 1 or '' end,  -- PhotometricInterpretation
            [0x111] = function(val) return D(val) and 1 or '' end,            -- StripOffsets
            -- SamplesPerPixel
            [0x115] = function(val, valH)
                local pi = truthy(valH[0x106]) and valH[0x106] or 0
                local xtra = (truthy(valH[0x152]) and #split(' ', valH[0x152]) or 0)
                if num(pi) == 2 or num(pi) == 6 then
                    return num(val) == 3 + xtra and 1 or ''
                elseif num(pi) == 5 then
                    return num(val) == 4 + xtra and 1 or ''
                else
                    return 1
                end
            end,
            [0x116] = function(val) return D(val) and 1 or '' end,            -- RowsPerStrip
            [0x117] = function(val) return D(val) and 1 or '' end,            -- StripByteCounts
            [0x11a] = function(val) return D(val) and 1 or '' end,            -- XResolution
            [0x11b] = function(val) return D(val) and 1 or '' end,            -- YResolution
            [0x128] = function(val) return (not D(val) or matches(val, [[^[123]$]]) ~= nil) and 1 or '' end,   -- ResolutionUnit
            -- ColorMap (must be palette image with correct number of colors)
            [0x140] = function(val, valH)
                if xor(D(valH[0x106]) and num(valH[0x106]) == 3, D(val)) then return '' end
                if not D(val) or length(val) == 6 * 2 ^ (truthy(valH[0x102]) and num(valH[0x102]) or 0) then return 1 end
                return 'Invalid count for'
            end,
            [0x201] = false,    -- JPEGInterchangeFormat
            [0x202] = false,    -- JPEGInterchangeFormatLength
        },
        ExifIFD = {
            [0x9000] = function(val) return D(val) and 1 or '' end,           -- ExifVersion
            [0x9101] = false,               -- ComponentsConfiguration
            [0x9102] = false,               -- CompressedBitsPerPixel
            [0xa000] = function(val) return D(val) and 1 or '' end,           -- FlashpixVersion
            [0xa001] = function(val) return (num(val) == 1 or num(val) == 0xffff) and 1 or '' end,    -- ColorSpace
            [0xa002] = false,               -- PixelXDimension
            [0xa003] = false,               -- PixelYDimension
        },
        InteropIFD = {
            [0x0001] = false,               -- InteropIndex
        },
        GPS = {
            [0x00] = function(val) return (D(val) and matches(val, [[^\d \d \d \d$]]) ~= nil) and 1 or '' end, -- GPSVersionID
            [0x1b] = function(val) return matches(val, [[^(GPS|CELLID|WLAN|MANUAL)$]]) ~= nil and 1 or '' end, -- GPSProcessingMethod
        },
    },
}

-- validity ranges for constrained date/time fields
local validDateField = {
    { 'Month',   1, 12 },
    { 'Day',     1, 31 },
    { 'Hour',    0, 23 },
    { 'Minutes', 0, 59 },
    { 'Seconds', 0, 59 },
    { 'TZhr',    0, 14 },
    { 'TZmin',   0, 59 },
}

-- "Validate" tag information
local validateInfo = {
    Groups = { [0] = 'ExifTool', [1] = 'ExifTool', [2] = 'ExifTool' },
    Notes = [[
        generated only if specifically requested.  Requesting this tag automatically
        enables the API L<Validate|../ExifTool.html#Validate> option, imposing
        additional validation checks when extracting metadata.  Returns the number
        of errors, warnings and minor warnings encountered.  Note that the Validate
        feature focuses mainly on validation of EXIF/TIFF metadata
    ]],
    PrintConv = {
        ['0 0 0'] = 'OK',
        OTHER = function(val)
            val = split(' ', val)
            local rtn = {}
            if truthy(val[1]) then rtn[#rtn + 1] = sprintf('%d Error%s', val[1], num(val[1]) == 1 and '' or 's') end
            if truthy(val[2]) then rtn[#rtn + 1] = sprintf('%d Warning%s', val[2], num(val[2]) == 1 and '' or 's') end
            if truthy(val[3]) then
                local str = (num(val[2]) == num(val[3]) and (num(val[2]) == 1 and '' or 'all ') or (val[3] .. ' '))
                rtn[#rtn] = rtn[#rtn] .. ' (' .. str .. 'minor)'
            end
            return table.concat(rtn, ' and ')
        end,
    },
    Hidden = 0,
}

-- add "Validate" tag to Extra table
-- (this port's AddTagToTable takes the ExifTool object as its first argument
--  and ignores it, so upstream's plain-function call passes nil for it)
ExifTool.AddTagToTable(nil, ExifTool.Extra, 'Validate', validateInfo, 1)

--------------------------------------------------------------------------------
-- Validate the raw value of a tag
-- Inputs: 0) ExifTool ref, 1) tag key, 2) raw tag value
-- Returns: nothing, but issues a minor Warning if a problem was detected
function Validate.ValidateRaw(self, tag, val)
    local tagInfo = self.TAG_INFO[tag]
    local wrn

    -- evaluate Validate code if specified
    if tagInfo and truthy(tagInfo.Validate) then
        ---- eval Validate ($self, $val, $tagInfo)
        local ok, wrn = pcall(tagInfo.Validate, self, val, tagInfo)   -- luacheck: ignore wrn
        local err
        if not ok then err, wrn = wrn, nil end
        if truthy(wrn) or truthy(err) then
            local name = tagInfo.Table.GROUPS[0] .. ':' .. ExifTool.GetTagName(tag)
            if truthy(err) then self:Warn('Validate ' .. name .. ': ' .. tostring(err), 1) end
            if truthy(wrn) then self:Warn(perlStr(wrn) .. ' for ' .. name, 1) end
        end
    end
    -- check for unknown values in PrintConv lookup for all standard EXIF tags
    if tagInfo and type(tagInfo.PrintConv) == 'table' and (tagInfo.Table.SHORT_NAME == 'GPS::Main' or
        (tagInfo.Table == Exif.Main and exifSpec[tagInfo.TagID]))
    then
        local prt = self:GetValue(tag, 'PrintConv')
        if truthy(prt) and matches(perlStr(prt), [[^Unknown \(]]) ~= nil then wrn = 'Unknown value for' end
    end
    if val == 'undef' then wrn = 'Undefined value for' end
    if wrn then
        local name = (self.DIR_NAME or '') .. ':' .. ExifTool.GetTagName(tag)
        self:Warn(wrn .. ' ' .. name, 1)
    end
end

--------------------------------------------------------------------------------
-- Validate raw EXIF date/time value
-- Inputs: 0) date/time value
-- Returns: error string
function Validate.ValidateExifDate(val)
    local m = { matches(val, [[^\d{4}:(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$]]) }
    m[#m] = nil     -- (drop the trailing match position perl.matches appends)
    if m[1] ~= nil then
        local a = { m[1], m[2], m[3], m[4], m[5] }
        local bad = {}
        for i = 1, #a do
            if not (a[i] == '  ' or (num(a[i]) >= validDateField[i][2] and num(a[i]) <= validDateField[i][3])) then
                bad[#bad + 1] = validDateField[i][1]
            end
        end
        if #bad > 0 then return table.concat(bad, '+') .. ' out of range' end
    -- the EXIF specification allows blank fields or an entire blank value
    elseif val ~= '    :  :     :  :  ' and val ~= '                   ' then
        return 'Invalid date/time format'
    end
    return nil      -- OK!
end

--------------------------------------------------------------------------------
-- Validate EXIF-reformatted XMP date/time value
-- Inputs: 0) date/time value
-- Returns: error string
-- (the six alternative patterns are tried in upstream order, the winner's
--  captures being Perl's $1..$8; isMatch, since $6..$8 may be unset, and the
--  first pattern has no capturing groups at all -- all of them stay nil
--  then, as in Perl)
local xmpDatePatterns = {
    [[^\d{4}$]],
    [[^\d{4}:(\d{2})$]],
    [[^\d{4}:(\d{2}):(\d{2})$]],
    [[^\d{4}:(\d{2}):(\d{2}) (\d{2}):(\d{2})()(Z|[-+](\d{2}):(\d{2}))?$]],
    [[^\d{4}:(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})(Z|[-+](\d{2}):(\d{2}))?$]],
    [[^\d{4}:(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})\.?\d*(Z|[-+](\d{2}):(\d{2}))?$]],
}

function Validate.ValidateXMPDate(val)
    local ok, c1, c2, c3, c4, c5, c7, c8
    for _, pat in ipairs(xmpDatePatterns) do
        local c6 -- luacheck: ignore c6 ($6 is not checked upstream either)
        ok, c1, c2, c3, c4, c5, c6, c7, c8 = isMatch(val, pat)
        if ok then break end
    end
    if ok then
        local a = { c1, c2, c3, c4, c5, c7, c8 }
        local bad = {}
        for i = 1, 7 do
            if not a[i] then break end
            if not (a[i] == '' or (num(a[i]) >= validDateField[i][2] and num(a[i]) <= validDateField[i][3])) then
                bad[#bad + 1] = validDateField[i][1]
            end
        end
        if #bad > 0 then return table.concat(bad, '+') .. ' out of range' end
    else
        return 'Invalid date/time format'
    end
    return nil      -- OK!
end

--------------------------------------------------------------------------------
-- Validate EXIF tag
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) tag ID, 3) tagInfo ref,
--         4) previous tag ID, 5) IFD name, 6) number of values, 7) value format string
-- Returns: Nothing, but sets Warning tags if any problems are found
function Validate.ValidateExif(et, tagTablePtr, tag, tagInfo, lastTag, ifd, count, formatStr)

    if tag <= lastTag then et:Warn('Entries in ' .. ifd .. ' are out of order') end

    -- (get tagInfo for unknown tags if Unknown option not used)
    if tagInfo == nil and tagTablePtr[tag] and type(tagTablePtr[tag]) == 'table' and tagTablePtr[tag][1] == nil then
        tagInfo = tagTablePtr[tag]
    end
    if tagInfo ~= nil then
        local ti = tagInfo or tagTablePtr[tag]
        if type(ti) == 'table' and ti[1] ~= nil then ti = ti[#ti] end
        local stdFmt = stdFormat[ifd] or stdFormat.IFD
        if stdFmt.All ~= nil or (tagTablePtr == Exif.Main and
            (exifSpec[tag] or stdFmt[tag] or
            (tag >= 0xc612 and tag <= 0xcd48 and stdFmt[tag] == nil))) or -- (DNG tags)
            tagTablePtr.SHORT_NAME == 'GPS::Main'
        then
            local wgp = ti.WriteGroup or tagTablePtr.WRITE_GROUP
            if truthy(wgp) and wgp ~= ifd and wgp ~= 'All' and not ti.OffsetPair and
                xor(isMatch(ifd, [[^(Sub|Profile)?IFD\d*$]]), (isMatch(wgp, [[^(Sub)?IFD\d*$]]))) and
                (truthy(ti.Writable) or truthy(ti.WriteGroup)) and matches(ifd, [[^SRF\d+$]]) == nil
            then
                et:Warn(sprintf('Wrong IFD for 0x%.4x %s (should be %s not %s)', tag, ti.Name, wgp, ifd))
            end
            local fmt = truthy(stdFmt[tag]) and stdFmt[tag] or ti.Writable
            -- (upstream's %stdFormat values are format-name patterns and
            --  Writable is either such a name or a plain flag; the flag form
            --  is stringified for the same never-matching '^1$' upstream gets)
            if fmt == true then fmt = 1 end
            if truthy(fmt) and not isMatchDyn(formatStr, '^' .. perlStr(fmt) .. '$') and (not tagInfo or
                not tagInfo.IsOffset or Exif.intFormat[formatStr])
            then
                et:Warn(sprintf('Non-standard format (%s) for %s 0x%.4x %s', formatStr, ifd, tag, ti.Name))
            end
        elseif stdFormatAnyIFD[tag] then
            if truthy(ti.Writable) or truthy(ti.WriteGroup) then
                local wgp = ti.WriteGroup or tagTablePtr.WRITE_GROUP
                if truthy(wgp) and wgp ~= ifd then
                    et:Warn(sprintf('Wrong IFD for 0x%.4x %s (should be %s not %s)', tag, ti.Name, wgp, ifd))
                end
            end
        elseif not otherSpec[et.FileType] or
            (not otherSpec[et.FileType][tag] and not otherSpec[et.FileType].All)
        then
            if tagTablePtr == Exif.Main or ti.Unknown then
                if not otherSpec[ifd] then
                    et:Warn(sprintf('Non-standard %s tag 0x%.4x %s', ifd, tag, ti.Name), 1)
                end
            end
        end
        -- change expected count from read Format to Writable size
        local tiCount = ti.Count
        if truthy(tiCount) then
            if ti.Format and ti.Writable and
                Exif.formatNumber[ti.Format] and
                Exif.formatNumber[ti.Writable]
            then
                local s1 = Exif.formatSize[Exif.formatNumber[ti.Format]]
                local s2 = Exif.formatSize[Exif.formatNumber[ti.Writable]]
                tiCount = math.floor(num(tiCount) * s1 / s2)
            end
            if num(tiCount) > 0 and count ~= num(tiCount) then
                et:Warn(sprintf('Non-standard count (%d) for %s 0x%.4x %s', count, ifd, tag, ti.Name))
            end
        end
    elseif not otherSpec[et.FileType] or
        (not otherSpec[et.FileType][tag] and not otherSpec[et.FileType].All)
    then
        if not otherSpec[ifd] then et:Warn(sprintf('Unknown %s tag 0x%.4x', ifd, tag), 1) end
    end
end

--------------------------------------------------------------------------------
-- Validate image data offsets/sizes
-- Inputs: 0) ExifTool ref, 1) offset info hash ref (arrays of tagInfo/value pairs, keyed by tagID)
--         2) directory name, 3) optional flag for minor warning
function Validate.ValidateOffsetInfo(et, offsetInfo, dirName, minor)

    local fileSize = et.VALUE.FileSize
    if not truthy(fileSize) then return end

    -- (don't test RWZ files and some other file types)
    if et.DontValidateImageData then return end
    -- (Minolta A200 uses wrong byte order for these)
    if et.TIFF_TYPE == 'MRW' and dirName == 'IFD0' and matches(perlStr(et.Model), [[^DiMAGE A200]]) ~= nil then return end
    -- (don't test 3FR, RWL or RW2 files)
    if matches(perlStr(et.TIFF_TYPE), [[^(3FR|RWL|RW2)$]]) ~= nil then return end

    -- upstream's Image::ExifTool::Exif::ValidateImageData lives in
    -- WriteExif.pl, which this port keeps as its own module.  Required
    -- here rather than at the top: a top-level require would pull in
    -- nearly every vendor module, and BuildCompositeTags derives its
    -- worklist from `package.loaded` (see the note there).
    require('lexiftool.WriteExif').ValidateImageData(et, offsetInfo, dirName)

    -- loop through all offsets
    while next(offsetInfo) ~= nil do
        local id1 = sortedKeys(offsetInfo)[1]
        local offsets = offsetInfo[id1]
        offsetInfo[id1] = nil
        if type(offsets) == 'table' then
            local id2 = offsets[1].OffsetPair
            if not (D(id2) and offsetInfo[id2]) then
                if not (offsets[1].NotRealPair or (D(id2) and id2 == -1)) then
                    local corr = offsets[1].IsOffset and 'size' or 'offset'
                    if not truthy(minor) then
                        et:Warn(dirName .. ':' .. offsets[1].Name .. ' is missing the corresponding ' .. corr .. ' tag')
                    end
                end
                goto continue
            end
            local sizes = offsetInfo[id2]
            offsetInfo[id2] = nil
            if sizes[1].IsOffset then sizes, offsets = offsets, sizes end
            local offsetList = split(' ', perlStr(offsets[2]))
            local sizeList = split(' ', perlStr(sizes[2]))
            if #sizeList ~= #offsetList then
                et:Warn(sprintf('Wrong number of values in %s 0x%.4x %s',
                                  dirName, offsets[1].TagID, offsets[1].Name), minor)
                goto continue
            end
            while #offsetList > 0 do
                local start = num(table.remove(offsetList))
                local endP = start + num(table.remove(sizeList))
                if start == 0 then et:Warn(dirName .. ':' .. offsets[1].Name .. ' is zero', minor) end
                if start == endP then et:Warn(dirName .. ':' .. sizes[1].Name .. ' is zero', minor) end
                if endP <= num(fileSize) then goto nextOffset end
                if start >= num(fileSize) then
                    if start == 0xffffffff then
                        et:Warn(dirName .. ':' .. offsets[1].Name .. ' is invalid (0xffffffff)', minor)
                    else
                        et:Warn(dirName .. ':' .. offsets[1].Name .. ' is past end of file', minor)
                    end
                else
                    et:Warn(dirName .. ':' .. offsets[1].Name .. '+' .. sizes[1].Name .. ' runs past end of file', minor)
                end
                break
                ::nextOffset::
            end
        end
        ::continue::
    end
end

--------------------------------------------------------------------------------
-- Finish Validating tags
-- Inputs: 0) ExifTool ref, 1) True to generate Validate tag
function Validate.FinishValidate(et, mkTag)

    local fileType = et.FILE_TYPE or ''
    if fileType == 'TIFF' then fileType = et.TIFF_TYPE end

    if validValue[fileType] then
        for _, grp in ipairs(sortedKeys(validValue[fileType])) do
            if et.FOUND_DIR and et.FOUND_DIR[grp] then
            local valH, info, minor, verTag, ver, vstr = {}, {}
            local verCheck_ = verCheck[grp]
            if verCheck_ then
                verTag = sortedKeys(verCheck_)[1]
                ver = perlStr(et.VALUE[verTag] or ''):gsub('%D', '')   -- (remove non-digits)
                if matches(ver, [[^\d{4}$]]) == nil then ver = nil end  -- (already warned if invalid version)
            end
            -- get all tags in this group
            for _, key in ipairs(sortedKeys(et.VALUE)) do
                if et:GetGroup(key, 1) == grp and
                    not (et.TAG_EXTRA[key] and et.TAG_EXTRA[key].G3) and -- ignore sub-documents
                    et.TAG_INFO[key] and et.TAG_INFO[key].TagID ~= nil then
                    -- fill in %val lookup with values based on tag ID
                    local tag = et.TAG_INFO[key].TagID
                    valH[tag] = et.VALUE[key]
                    -- save TagInfo ref for later
                    info[tag] = et.TAG_INFO[key]
                    if ver ~= nil then
                        local chk = verCheck_[verTag]
                        if not (chk[tag] == nil or chk[tag] == 1 or num(ver) >= chk[tag]) then
                            if verTag == 'GPSVersionID' then
                                vstr = subst(perlStr(chk[tag]), [[^(\d)(\d)(\d)]], '$1.$2.$3.')
                            else
                                vstr = sprintf('%.4d', chk[tag])
                            end
                            et:Warn(sprintf('%s tag 0x%.4x %s requires %s %s or higher',
                                      grp, tag, et.TAG_INFO[key].Name, verTag, vstr))
                        end
                    end
                end
            end
            -- make quick lookup for values based on tag ID
            local validValue_ = validValue[fileType][grp]
            for _, tag in ipairs(sortedNumKeys(validValue_)) do
                local val = valH[tag]
                local pre, post
                if validValue_[tag] then
                    ---- eval ($val, %val)
                    local ok, result = pcall(validValue_[tag], val, valH)
                    if not ok then result = nil end
                    if result == nil then
                        pre = 'Internal error validating'
                    elseif result == '' then
                        pre = D(val) and 'Invalid value for' or ('Missing required ' .. fileType)
                    else
                        if perlStr(result) == '1' then goto continue end
                        pre = result
                    end
                else
                    if not D(val) then goto continue end
                    post = 'is not allowed in ' .. fileType
                    minor = 1
                end
                local name
                if info[tag] then
                    name = info[tag].Name
                else
                    local table_ = 'lexiftool.' .. (grp == 'GPS' and 'GPS' or 'Exif') .. '.Main'
                    local tagInfo = et:GetTagTable(table_)[tag]
                    if type(tagInfo) == 'table' and tagInfo[1] ~= nil then tagInfo = tagInfo[1] end
                    name = tagInfo and tagInfo.Name or '<unknown>'
                end
                if et.WrongFormat and et.WrongFormat[grp .. ':' .. name] then goto continue end
                pre = pre and (pre .. ' ') or ''
                post = post and (' ' .. post) or ''
                et:Warn(sprintf('%s%s tag 0x%.4x %s%s', pre, grp, tag, name, post), minor)
                ::continue::
            end
            end
        end
    end
    -- validate file extension
    if et.FILENAME and et.FILENAME ~= '' then
        local ext = matches(et.FILENAME, [[(?s)^.*\.([^.]+)$]])
        local fileExt = ext and uc(ext) or ''
        local extFileType = ExifTool.GetFileType(fileExt)
        if extFileType and extFileType ~= fileType then
            local normExt = et.VALUE.FileTypeExtension
            if truthy(normExt) and normExt ~= fileExt then
                local lkup = ExifTool.fileTypeLookup[fileExt]
                if type(lkup) == 'table' or lkup ~= normExt then
                    et:Warn('File has wrong extension (should be ' .. normExt .. ', not ' .. fileExt .. ')')
                end
            end
        end
    end
    -- issue warning if FastScan option used
    if truthy(et:Options('FastScan')) then et:Warn('Validation incomplete because FastScan option used') end

    -- generate Validate tag if necessary
    if truthy(mkTag) then
        local numList = {}
        numList[1] = et.VALUE.Error   and ((et.DUPL_TAG.Error   or 0) + 1) or 0
        numList[2] = et.VALUE.Warning and ((et.DUPL_TAG.Warning or 0) + 1) or 0
        numList[3] = 0
        local key = 'Warning'
        while true do
            if et.VALUE[key] and matches(perlStr(et.VALUE[key]), [==[(?i)^\[minor\]]==]) ~= nil then
                numList[3] = numList[3] + 1
            end
            key = et:NextTagKey(key)
            if not key then break end
        end
        et:FoundTag('Validate', table.concat(numList, ' '))
    end
end

return Validate
