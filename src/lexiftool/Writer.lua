--------------------------------------------------------------------------------
-- File:         lexiftool/Writer.lua
-- Ported from:  lib/Image/ExifTool/Writer.pl
--
-- Description:  ExifTool write routines
--
-- Notes:        Also contains some less used ExifTool functions
--
-- URL:          https://exiftool.org/
--
-- Revisions:    12/16/2004 - P. Harvey Created
--
-- Port notes:   All subs of Writer.pl are ported, in upstream order at
--               their upstream position (the tables at the top of the file
--               as upstream: %tiffMap/%exifMap/%jpegMap/%dirMap,
--               %writableType, @delGroups, %delMore, %excludeGroups, ...).
--               lexiftool.lua calls them through AUTOLOAD stand-ins;
--               TagLookup is loaded on the first FindTagInfo only.
--               File/scalar references: a GLOB is an io file, a scalar
--               reference the box { value = ... } whose scalar is a carray
--               (doc/api.md §4), a RAF a RandomAccess object.
--               Block 2 (WriteInfo side): WriteInfo (including creation
--               without a source file, in place via _exiftool_tmp, return
--               value 0/1/2), WriteJPEG with WriteMultiSegment/WriteMultiXMP/
--               AddNewTrailers, WriteDirectory (including block writing via
--               %Extra), InitWriteDirs, SetFileName (HardLink/SymLink/Test),
--               Rename/Unlink/SetFileTime/CopyFileAttrs, HexDump/VerboseInfo/
--               DumpTrailer/DumpUnknownTrailer/VerboseValue, MakeTiffHeader,
--               ImageDataHash; the group deletion in SetNewValue keeps
--               DEL_GROUP as upstream does (group names, '*', %delMore,
--               exclusions with Replace => 2).
--               Deviations: the darwin branches (macOS resource fork and
--               SetMacOSTags), futimes (SetFileTime falls back to the file
--               name, as upstream does), the UTF-8 flag of scalar inputs.
--               The MSWin32 branches are ported natively through
--               lexiftool.sys instead of Win32::API/Win32API::File:
--               MoveFileExW/DeleteFileW (Rename/Unlink, with the upstream
--               retry loop), SetFileTime on the handle of the file opened
--               by Open (SetFileTime, and with it FileCreateDate), the
--               Zone.Identifier deletion and the Windows name validation
--               in SetFileName.
--               PREVIEW_INFO/LeicaTrailer/HiddenData as upstream (WriteExif
--               sets them, WriteJPEG writes them). WriteBinaryData in full
--               (IS_OFFSET fixups, PREVIEW_INFO/HiddenData, IS_SUBDIR, Mask);
--               the `eval` of the format count understands the forms of the
--               ported tables.  For data in memory WriteTIFF is the write
--               branch of DoProcessTIFF (header, HeaderPtr, WriteDirectory
--               for IFD0).
--               SetNewValue side (block 1): SetNewValuesFromFile (in full),
--               Save/RestoreNewValues, SetSystemTags (without the MacOS/
--               Windows branches) and others; PushValue/InsertTagValues in
--               full, the expressions in "${TAG;EXPR}" through the Perl
--               interpreter perl.eval.
--               SetNewValue, GetNewValue, ConvInv, IsOverwriting and
--               CheckValue follow Writer.pl line for line: the inverse
--               conversion (PrintConvInv, ValueConvInv, WriteCheck or
--               CHECK_PROC) runs when the value is set, NEW_VALUE holds the
--               raw values; multiple groups ("exif:time"), AllowGroup,
--               DelCheck, DelGroup and WriteAlso are included.  Lua forms:
--               SetNewValue always returns (count, error) (upstream's list
--               context, no warn); GetNewValue takes `wantarray` as its
--               third argument and returns the nvHash as its second result
--               (instead of \$nvHash); a conversion is called as
--               conv($self, $val, $wantGroup), a CHECK_PROC, WriteCheck or
--               DelCheck returns (error, changed value);
--               $evalWarning is ExifTool.evalWarning, `local
--               $SIG{'__WARN__'}` is perl.SIG.__WARN__ (perl.warn).  The
--               dummy call of the WRITE_PROC before the Writable check does
--               not exist: the write procs load their package on their
--               first call.
--------------------------------------------------------------------------------

local Writer = {}

local ExifTool = require('lexiftool')
local RandomAccess = require('lexiftool.RandomAccess')
local carray = require('carray')
local Shift = require('lexiftool.Shift')
local perl = require('lexiftool.perl')
local tsort = perl.tsort
local sys = require('lexiftool.sys')
local substr = perl.substr
local matches = perl.matches
local matchesDyn = perl.matchesDyn
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local join = perl.join
local lc = perl.lc
local ucfirst = perl.ucfirst
local sprintf = perl.sprintf
local perlStr = perl.str
local perlTruthy = ExifTool.perlTruthy
local Get16u, Get32u, Get32s = ExifTool.Get16u, ExifTool.Get32u, ExifTool.Get32s
-- (upstream: use Image::ExifTool::TagLookup qw(FindTagInfo TagExists);
--  loaded on first use here: the read path autoloads this file for Get64u &
--  co., and must not pay the TagLookup load for that)
local TagLookup
local function FindTagInfo(...)
    TagLookup = TagLookup or require('lexiftool.TagLookup')
    return TagLookup.FindTagInfo(...)
end
local function TagExists(...)
    TagLookup = TagLookup or require('lexiftool.TagLookup')
    return TagLookup.TagExists(...)
end

local remove, concat = table.remove, table.concat
local exifAPP1hdr = ExifTool.exifAPP1hdr
local xmpAPP1hdr = ExifTool.xmpAPP1hdr
local xmpExtAPP1hdr = ExifTool.xmpExtAPP1hdr
local psAPP13hdr = ExifTool.psAPP13hdr
local sbyte = string.byte

local loadedAllTables    -- flag indicating we loaded all tables
local advFmtSelf         -- (upstream ExifTool.pm's $advFmtSelf: $self for the helpers
                         --  of advanced formatting expressions)

-- (port helper: Perl passes `%opts` flattened, i.e. a copy, to SetNewValue)
local function copyOpts(opts)
    local o = { }
    for k, v in pairs(opts) do o[k] = v end
    return o
end

-- (port helpers for Perl's `ref $val eq 'ARRAY'` and `ref $val eq 'HASH'`:
--  a list is a Lua array (or an empty table), a structure any other table
--  -- the same test XMPStruct makes, including its structure mark)
local function isArrayRef(obj)
    if type(obj) ~= 'table' or obj.ref ~= nil or obj.__struct then return false end
    return obj[1] ~= nil or next(obj) == nil
end
local function isHashRef(obj)
    if type(obj) ~= 'table' or obj.ref ~= nil then return false end
    if obj.__struct then return true end
    return obj[1] == nil and next(obj) ~= nil
end
-- (port helper for `ref $conv eq 'ARRAY'` of a PrintConv/ValueConv: a list of
--  conversions has a table, a function or false (undef) as first entry, a
--  lookup hash maps to strings or numbers only -- the test GetValue makes)
local function isConvList(conv)
    if type(conv) ~= 'table' then return false end
    local first = conv[1]
    return first == false or type(first) == 'table' or type(first) == 'function'
end

--------------------------------------------------------------------------------
-- LastInList - return last element of a new-value-hash linked list
--------------------------------------------------------------------------------
local function LastInList(nvHash)
    while nvHash.Next do nvHash = nvHash.Next end
    return nvHash
end

-- the following is a road map of where we write each directory
-- in the different types of files.
local tiffMap = {
    IFD0         = 'TIFF',
    IFD1         = 'IFD0',
    XMP          = 'IFD0',
    ICC_Profile  = 'IFD0',
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    IPTC         = 'IFD0',
    Photoshop    = 'IFD0',
    SEAL         = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
    CanonVRD     = 'MakerNotes', -- (so VRDOffset will get updated)
    NikonCapture = 'MakerNotes', -- (to allow delete by group)
    PhaseOne     = 'MakerNotes', -- (for editing PhaseOne SensorCalibration tags)
}
local exifMap = {
    IFD1         = 'IFD0',
    EXIF         = 'IFD0', -- to write EXIF as a block
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
    NikonCapture = 'MakerNotes', -- (to allow delete by group)
    -- (no CanonVRD trailer allowed)
}
local jpegMap = {
    -- (%exifMap is spread in below: it covers all JPEG EXIF mappings)
    JFIF         = 'APP0',
    CIFF         = 'APP0',
    IFD0         = 'APP1',
    XMP          = 'APP1',
    ICC_Profile  = 'APP2',
    FlashPix     = 'APP2',
    MPF          = 'APP2',
    Meta         = 'APP3',
    MetaIFD      = 'Meta',
    RMETA        = 'APP5',
    SEAL         = { 'APP8', 'APP9' }, -- (note: add 'IFD0' if this is a possibility)
    AROT         = 'APP10',
    JUMBF        = 'APP11',
    Ducky        = 'APP12',
    Photoshop    = 'APP13',
    Adobe        = 'APP14',
    IPTC         = 'Photoshop',
    MakerNotes   = { 'ExifIFD', 'CIFF' }, -- (first parent is the default)
    CanonVRD     = 'MakerNotes', -- (so VRDOffset will get updated)
    NikonCapture = 'MakerNotes', -- (to allow delete by group)
    Comment      = 'COM',
}
for k, v in pairs(exifMap) do
    if jpegMap[k] == nil then jpegMap[k] = v end
end
local dirMap = {
    JPEG = jpegMap,
    EXV  = jpegMap,
    TIFF = tiffMap,
    ORF  = tiffMap,
    RAW  = tiffMap,
    EXIF = exifMap,
}

-- module names and write functions for each writable file type
-- (defaults to "$type" and "Process$type" if not defined)
-- - types that are handled specially will not appear in this list
-- (Perl's undef module name is false here)
local writableType = {
    CRW = { 'CanonRaw',    'WriteCRW' },
    DR4 =   'CanonVRD',
    EPS = { 'PostScript',  'WritePS'  },
    FLIF= { false,         'WriteFLIF'},
    GIF =   false,
    ICC = { 'ICC_Profile', 'WriteICC' },
    IND =   'InDesign',
    JP2 =   'Jpeg2000',
    JXL =   'Jpeg2000',
    MIE =   false,
    MOV = { 'QuickTime',   'WriteMOV' },
    MRW =   'MinoltaRaw',
    PDF = { false,         'WritePDF' },
    PNG =   false,
    PPM =   false,
    PS  = { 'PostScript',  'WritePS'  },
    PSD =   'Photoshop',
    RAF = { 'FujiFilm',    'WriteRAF' },
    RIFF= { 'RIFF',        'WriteRIFF'},
    VRD =   'CanonVRD',
    WEBP= { 'RIFF',        'WriteRIFF'},
    X3F =   'SigmaRaw',
    XMP = { false,         'WriteXMP' },
}

-- RAW file types (2 = raw file where we can delete maker notes from ExifIFD)
local rawType = {
   ['3FR'] = 1, CR3 = 2, IIQ = 1, NEF = 1, RW2 = 1,
    ARQ = 1,  CRW = 1,  K25 = 1,  NRW = 1,  RWL = 1,
    ARW = 1,  DCR = 1,  KDC = 1,  ORF = 1,  SR2 = 1,
              ERF = 1,  MEF = 1,  PEF = 1,  SRF = 1,
    CR2 = 1,  FFF = 1,  MOS = 1,  RAW = 1,  SRW = 1,
}

-- groups we are allowed to delete
-- Notes:
-- 1) these names must either exist in %dirMap, or be translated in InitWriteDirs())
-- 2) any dependencies must be added to %excludeGroups
local delGroups = split(' ', [[
    Adobe AFCP APP0 APP1 APP2 APP3 APP4 APP5 APP6 APP7 APP8 APP9 APP10 APP11 APP12
    APP13 APP14 APP15 AROT AudioKeys CanonVRD CIFF Ducky EXIF ExifIFD File FlashPix
    FotoStation GlobParamIFD GPS ICC_Profile IFD0 IFD1 Insta360 InteropIFD IPTC
    ItemList iTunes JFIF Jpeg2000 JUMBF Keys MakerNotes Meta MetaIFD Microsoft MIE
    MPF Nextbase NikonApp NikonCapture PDF PDF-update PhotoMechanic Photoshop PNG
    PNG-pHYs PrintIM QuickTime RMETA RSRC SEAL SubIFD Trailer UserData VideoKeys
    Vivo XML XML-* XMP XMP-*
]])
-- family 2 group names that we can delete
local delGroup2 = split(' ', [[
    Audio Author Camera Document ExifTool Image Location Other Preview Printing
    Time Video
]])

-- Extra groups to delete when deleting another group
local delMore = {
    QuickTime = { 'ItemList', 'UserData', 'Keys' },
    XMP = { 'XMP-*' },
    XML = { 'XML-*' },
    SEAL = { 'XMP-SEAL' },
}

-- family 0 groups where directories should never be deleted
local permanentDir = { QuickTime = 1, Jpeg2000 = 1 }

-- lookup for all valid family 2 groups (lower case)
local family2groups = { unknown = 1 }
for _, g in ipairs(delGroup2) do family2groups[lc(g)] = 1 end

-- groups we don't delete when deleting all information
local protectedGroups = '(IFD1|SubIFD|InteropIFD|GlobParamIFD|PDF-update|Adobe)'

-- other group names of new tag values to remove when deleting an entire group
local removeGroups = {
    IFD0    = { 'EXIF', 'MakerNotes' },
    EXIF    = { 'MakerNotes' },
    ExifIFD = { 'MakerNotes', 'InteropIFD' },
    Trailer = { 'CanonVRD' }, --(because we can add back CanonVRD as a block)
}
-- related family 0/1 groups in @delGroups (and not already in %jpegMap)
-- that must be removed from delete list when excluding a group
local excludeGroups = {
    EXIF         = { 'IFD0', 'IFD1', 'ExifIFD', 'GPS', 'MakerNotes', 'GlobParamIFD', 'InteropIFD', 'PrintIM', 'SubIFD' },
    IFD0         = { 'EXIF' },
    IFD1         = { 'EXIF' },
    ExifIFD      = { 'EXIF' },
    GPS          = { 'EXIF' },
    MakerNotes   = { 'EXIF' },
    InteropIFD   = { 'EXIF' },
    GlobParamIFD = { 'EXIF' },
    PrintIM      = { 'EXIF' },
    CIFF         = { 'MakerNotes' },
    -- technically correct, but very uncommon and not a good reason to avoid deleting trailer
  -- IPTC         => [ qw(AFCP FotoStation Trailer) ],
    AFCP         = { 'Trailer' },
    FotoStation  = { 'Trailer' },
    CanonVRD     = { 'Trailer' },
    PhotoMechanic= { 'Trailer' },
    MIE          = { 'Trailer' },
    QuickTime    = { 'ItemList', 'UserData', 'Keys' },
}
-- group names to translate when the USER asks for them (upstream
-- %translateWantGroup): a CIFF directory's tags live in the CanonRaw tables,
-- so `-CIFF:ApertureValue=` and the `-all:all` copy (whose destination group
-- is the source tag's family-1 group, 'CIFF') have to find them there
local translateWantGroup = {
    ciff = 'canonraw',
}

-- group names to translate for writing (upstream %translateWriteGroup, scoped)
local translateWriteGroup = {
    EXIF = 'ExifIFD',
    Meta = 'MetaIFD',
    File = 'Comment',
    -- any entry in this table causes the write group to be set from the
    -- tag information instead of whatever the user specified...
    MIE   = 'MIE',
    APP14 = 'APP14',
}

-- names of valid EXIF and Meta directories (lower case keys):
local exifDirs = {
    gps          = 'GPS',
    exififd      = 'ExifIFD',
    subifd       = 'SubIFD',
    globparamifd = 'GlobParamIFD',
    interopifd   = 'InteropIFD',
    previewifd   = 'PreviewIFD', -- (in MakerNotes)
    metaifd      = 'MetaIFD', -- Kodak APP3 Meta
    makernotes   = 'MakerNotes',
}
-- valid family 0 groups when WriteGroup is set to "All"
local allFam0 = {
    exif         = 1,
    makernotes   = 1,
}

local writableMacOSTags = {
    'FileCreateDate', 'MDItemFinderComment', 'MDItemFSCreationDate', 'MDItemFSLabel', 'MDItemUserTags',
    'XAttrQuarantine', 'XAttrMDItemWhereFroms',
}

-- lookup for file types with block-writable EXIF
local blockExifTypes = {
    JPEG = 1, PNG = 1, JP2 = 1, JXL = 1, MIE = 1, EXIF = 1, FLIF = 1,
    MOV = 1, MP4 = 1, RIFF = 1,
}

local maxSegmentLen = 0xfffd     -- maximum length of data in a JPEG segment
local maxXMPLen = maxSegmentLen  -- maximum length of XMP data in JPEG

-- value separators when conversion list is used (in SetNewValue)
local listSep = { PrintConv = '; ?', ValueConv = ' ' }

--------------------------------------------------------------------------------
-- Set tag value
-- Inputs: 0) ExifTool object reference
--         1) tag key, tag name, or '*' (optionally prefixed by group name),
--            or undef to reset all previous SetNewValue() calls
--         2) new value (scalar, scalar ref or list ref), or undef to delete tag
--         3-N) Options:
--           Type => PrintConv, ValueConv or Raw - specifies value type
--           AddValue => true to add to list of existing values instead of overwriting
--           DelValue => true to delete this existing value value from a list, or
--                       or doing a conditional delete, or to shift a time value
--           Group => family 0 or 1 group name (case insensitive)
--           Replace => 0, 1 or 2 - overwrite previous new values (2=reset)
--           Protected => bitmask to write tags with specified protections
--           EditOnly => true to only edit existing tags (don't create new tag)
--           EditGroup => true to only edit existing groups (don't create new group)
--           Shift => undef, 0, +1 or -1 - shift value if possible
--           NoFlat => treat flattened tags as 'unsafe'
--           NoShortcut => true to prevent looking up shortcut tags
--           ProtectSaved => protect existing new values with a save count greater than this
--           IgnorePermanent => ignore attempts to delete a permanent tag
--           CreateGroups => [internal use] createGroups hash ref from related tags
--           ListOnly => [internal use] set only list or non-list tags
--           SetTags => [internal use] hash ref to return tagInfo refs of set tags
--           Sanitized => [internal use] set to avoid double-sanitizing the value
--           Fixup => [internal use] fixup information when writing maker notes
-- Returns: number of tags set (plus error string in list context)
-- Notes: For tag lists (like Keywords), call repeatedly with the same tag name for
--        each value in the list.  Internally, the new information is stored in
--        the following members of the $$self{NEW_VALUE}{$tagInfo} hash:
--           TagInfo - tag info ref
--           DelValue - list ref for raw values to delete
--           Value - list ref for raw values to add (not defined if deleting the tag)
--           IsCreating - must be set for the tag to be added for the standard file types,
--                        otherwise just changed if it already exists.  This may be
--                        overridden for file types with a PREFERRED metadata type.
--                        Set to 2 to create individual tags but not new groups
--           EditOnly - flag set if tag should never be created (regardless of file type).
--                      If this is set, then IsCreating must be false
--           CreateOnly - flag set if creating only (never edit existing tag)
--           CreateGroups - hash of all family 0 group names where tag may be created
--           WriteGroup - group name where information is being written (correct case)
--           WantGroup - group name as specified in call to function (case insensitive)
--           Next - pointer to next new value hash (if more than one for this tag)
--           NoReplace - set if value was created with Replace=0
--           AddBefore - number of list items added by a subsequent Replace=0 call
--           IsNVH - flag indicating this is a new value hash
--           Order - counter to indicate the order that new value hashes were created
--           Shift - shift value
--           Save - counter used by SaveNewValues()/RestoreNewValues()
--           MAKER_NOTE_FIXUP - pointer to fixup if necessary for a maker note value
-- (Lua: the options are a table; the function always returns both values,
--  upstream's list-context form -- there is no scalar context in which it
--  would `warn` the error instead.  A list value is a Lua array, a structure
--  any other table, a SCALAR ref the box { ref = 'SCALAR', value = ... })
function Writer.SetNewValue(self, tag, value, opts)
    -- (Perl's %options is the caller's list flattened into a new hash, so
    --  changes made here never reach the caller)
    local options = copyOpts(opts or { })
    local err, tagInfo
    local verbose = self.OPTIONS.Verbose or 0
    local out = self.OPTIONS.TextOut or io.stdout
    local protected = options.Protected or 0
    local listOnly = options.ListOnly
    local setTags = options.SetTags
    local noFlat = options.NoFlat
    local numSet = 0

    if tag == nil then
        self.NEW_VALUE = nil
        self.SAVE_COUNT = 0
        self.NV_COUNT = 0
        self.DEL_GROUP = { }
        return 1
    end
    -- allow value to be scalar or list reference
    if type(value) == 'table' then
        if isArrayRef(value) then
            -- value is an ARRAY so it may have more than one entry
            -- - set values both separately and as a combined string if there are more than one
            if #value > 1 then
                -- set all list-type tags first
                local replace = options.Replace
                local noJoin
                for _, v in ipairs(value) do
                    if type(v) == 'table' then noJoin = 1 end
                    local o = copyOpts(options)
                    o.ListOnly = 1
                    local n, e = Writer.SetNewValue(self, tag, v, o)
                    if perlTruthy(e) then err = e end
                    numSet = numSet + n
                    options.Replace = nil -- don't replace earlier values in list
                end
                if noJoin then return numSet end  -- don't join if list contains objects
                -- and now set only non-list tags
                value = join(self.OPTIONS.ListSep, value)
                options.Replace = replace
                listOnly = 0
                options.ListOnly = 0
            else
                value = value[1]
                if type(value) == 'table' and value.ref == 'SCALAR' then value = value.value end -- (handle single scalar ref in a list)
            end
        elseif value.ref == 'SCALAR' then
            value = value.value
        end
    end
    -- un-escape as necessary and make sure the Perl UTF-8 flag is OFF for the value
    -- if perl is 5.6 or greater (otherwise our byte manipulations get corrupted!!)
    if value ~= nil and type(value) ~= 'table' and not options.Sanitized then value = Writer.Sanitize(self, value) end

    -- set group name in options if specified
    do
        local g, t = matches(tag, [[(.*):(.+)]])
        if g then options.Group, tag = g, t end
    end

    -- allow trailing '#' for ValueConv value
    if isMatch(tag, [[#$]]) then
        tag = subst(tag, [[#$]], '')
        options.Type = 'ValueConv'
    end
    local convType = options.Type or (perlTruthy(self.OPTIONS.PrintConv) and 'PrintConv' or 'ValueConv')

    -- filter value if necessary
    if convType == 'PrintConv' then
        local ok
        ok, value = self:Filter(self.OPTIONS.FilterW, value)
        if not ok then return 0 end
    end

    local wantGroup, family2 = { }, nil   -- (wantGroup is upstream's @wantGroup)
    local wantGroupStr = options.Group    -- (upstream's $wantGroup)
    if perlTruthy(wantGroupStr) then
        for _, s in ipairs(split(':', wantGroupStr)) do
            if #s == 0 then goto nextWant end  -- separate family number and group name
            do
                local f, g = matches(s, [[^(\d+)?(.*)]])
                local lcg = lc(g)
                -- save group/family unless '*' or 'all'
                if not (lcg == '*' or lcg == 'all') then wantGroup[#wantGroup + 1] = { f, lcg } end
                if isMatch(g, [[(?i)^ID-]]) then        -- family 7 is a tag ID
                    g = subst(g, [[(?i)^ID-]], '')
                    if f ~= nil and f ~= '7' then return 0 end
                    wantGroup[#wantGroup] = { 7, g }    -- group name with 'ID-' removed and case preserved
                elseif f ~= nil then
                    if tonumber(f) > 2 then return 0 end -- only allow family 0, 1 or 2
                    if tonumber(f) == 2 then family2 = 1 end -- set flag indicating family 2 was used
                else
                    if family2groups[lcg] then family2 = 1 end
                end
            end
            ::nextWant::
        end
        if #wantGroup == 0 then wantGroupStr = nil end
    else
        wantGroupStr = nil  -- (Lua: '' and '0' are true here)
    end

    tag = subst(tag, ' .*', '')     -- convert from tag key to tag name if necessary
    if lc(tag) == 'all' then tag = '*' end  -- use '*' instead of 'all'
--
-- handle group delete
--
    while tag == '*' and value == nil and not family2 and #wantGroup < 2 do -- luacheck: ignore 512
        -- set groups to delete
        local del = { }
        local remove_ = (options.Replace and options.Replace > 1)
        if wantGroupStr then
            if not isMatch(wantGroupStr, [[(?i)^XM[LP]-\*$]]) then
                for _, grp in ipairs(delGroups) do
                    if isMatchDyn(grp, '(?i)^' .. wantGroupStr .. '$') then del[#del + 1] = grp end
                end
            end
            -- remove associated groups when excluding from mass delete
            if #del > 0 and remove_ then
                -- remove associated groups in other family
                if excludeGroups[del[1]] then
                    for _, xg in ipairs(excludeGroups[del[1]]) do del[#del + 1] = xg end
                end
                -- remove upstream groups according to JPEG map
                local dirName = del[1]
                local dirNames = { }
                while true do
                    local parent = jpegMap[dirName]
                    if type(parent) == 'table' then
                        for _, pg in ipairs(parent) do dirNames[#dirNames + 1] = pg end
                        parent = remove(dirNames)
                    end
                    dirName = parent or remove(dirNames, 1)
                    if not dirName then break end
                    del[#del + 1] = dirName    -- exclude this too
                end
            end
            -- allow MIE groups to be deleted by number,
            -- and allow any XMP family 1 group to be deleted
            if isMatch(wantGroupStr, [[(?i)^(MIE\d+|XM[LP]-[-\w]*\w)$]]) then del[#del + 1] = perl.uc(wantGroupStr) end
        else
            -- push all groups plus '*', except the protected groups
            for _, grp in ipairs(delGroups) do
                if not isMatch(grp, '^' .. protectedGroups .. '$') then del[#del + 1] = grp end
            end
            del[#del + 1] = '*'
        end
        if #del > 0 then
            numSet = numSet + 1
            local donegrps = { }
            local delGroup = self.DEL_GROUP
            for _, grp in ipairs(del) do
                if remove_ then
                    local didExcl
                    local x = matches(grp, [[^(XM[LP])(-.*)?$]])
                    if x then
                        if grp == x then
                            -- exclude all related family 1 groups too
                            for _, k in ipairs(perl.keys(delGroup)) do
                                local m = matches(k, '^(-?)' .. x .. '-')
                                if m then
                                    if m == '' then donegrps[#donegrps + 1] = k end
                                    delGroup[k] = nil
                                end
                            end
                        elseif delGroup[x .. '-*'] and not delGroup['-' .. grp] then
                            -- must also exclude XMP or XML to prevent bulk delete
                            if delGroup[x] then
                                donegrps[#donegrps + 1] = x
                                delGroup[x] = nil
                            end
                            -- flag XMP/XML family 1 group for exclusion with leading '-'
                            delGroup['-' .. grp] = 1
                            didExcl = 1
                        end
                    end
                    if delGroup[grp] ~= nil then
                        delGroup[grp] = nil
                    else
                        if not didExcl then goto nextDel end
                    end
                else
                    delGroup[grp] = 1
                    -- add extra groups to delete if necessary
                    if delMore[grp] then
                        for _, mg in ipairs(delMore[grp]) do
                            delGroup[mg] = 1
                            donegrps[#donegrps + 1] = mg
                        end
                    end
                    -- remove all of this group from previous new values
                    Writer.RemoveNewValuesForGroup(self, grp)
                end
                donegrps[#donegrps + 1] = grp
                ::nextDel::
            end
            if verbose > 1 and #donegrps > 0 then
                donegrps = perl.sort(donegrps)
                local msg = remove_ and 'Excluding from deletion' or 'Deleting tags in'
                out:write('  ' .. msg .. ': ' .. join(' ', donegrps) .. "\n")
            end
        else
            local isGroup2
            for _, g2 in ipairs(delGroup2) do
                if isMatchDyn(g2, '(?i)^' .. perlStr(wantGroupStr) .. '$') then isGroup2 = true end
            end
            if isGroup2 then
                break   -- allow tags to be deleted by group2 name
            else
                err = 'Not a deletable group: ' .. perlStr(wantGroupStr)
            end
        end
        -- all done
        return numSet, err
    end

    -- initialize write/create flags
    local createOnly
    local editOnly = options.EditOnly
    local editGroup = options.EditGroup
    -- (upstream's default WriteMode is 'wcg', ExifTool.pm:1170)
    local writeMode = self.OPTIONS.WriteMode or 'wcg'
    if writeMode ~= 'wcg' then
        if not isMatch(writeMode, [[(?i)w]]) then createOnly = 1 end  -- don't write existing tags
        if not isMatch(writeMode, [[(?i)c]]) then
            if createOnly then return 0 end  -- nothing to do unless writing existing tags
            editOnly = 1                    -- don't create new tags
        elseif not isMatch(writeMode, [[(?i)g]]) then
            editGroup = 1                   -- don't create new groups
        end
    end
    local ifdName, mieGroup, movGroup
    -- set family 1 group names
    for _, fg in ipairs(wantGroup) do
        if fg[1] ~= nil and tonumber(fg[1]) ~= 1 then goto nextFG end
        do
            local s = fg[2]
            -- set $ifdName if this group is a valid IFD or SubIFD name
            local grpName
            local n
            n = matches(s, [[(?i)^IFD(\d+)$]])
            if n then
                grpName = 'IFD' .. n
                ifdName = grpName
            else
                n = matches(s, [[(?i)^SubIFD(\d+)$]])
                if n then
                    grpName = 'SubIFD' .. n
                    ifdName = grpName
                else
                    n = matches(s, [[(?i)^Version(\d+)$]])
                    if n then
                        grpName = 'Version' .. n -- Sony IDC VersionIFD
                        ifdName = grpName
                    elseif exifDirs[s] then
                        grpName = exifDirs[s]
                        if not (ifdName and allFam0[s]) then ifdName = grpName end
                    elseif allFam0[s] then
                        grpName = allFam0[s]
                    else
                        n = matches(s, [[(?i)^Track(\d+)$]])
                        if n then
                            grpName = 'Track' .. n -- QuickTime track
                            movGroup = grpName
                        else
                            local m1, m2 = matches(s, [[(?i)^MIE(\d*-?)(\w+)$]])
                            if m1 then
                                grpName = 'MIE' .. m1 .. ucfirst(lc(m2))
                                mieGroup = grpName
                            elseif not ifdName and isMatch(s, [[(?i)^XMP\b]]) then -- luacheck: ignore 542
                                -- must load XMP table to set group1 names
                                -- (Lua: the XMP write package is loaded with
                                --  the table, so the dummy WRITE_PROC call
                                --  upstream makes here is not needed)
                                ExifTool.GetTagTable(nil, 'lexiftool.XMP.Main')
                            end
                        end
                    end
                end
            end
            -- fix case for known groups
            if grpName and perlStr(grpName) ~= s then
                wantGroupStr = perl.substDyn(wantGroupStr, '(?i)' .. perlStr(grpName), perlStr(grpName))
            end
        end
        ::nextFG::
    end
--
-- get list of tags we want to set
--
    local origTag = tag
    if not self.WRITE_PRIORITY then self:SetNewGroups() end -- (upstream Init does this)
    local matchingTags = FindTagInfo(tag)
    while #matchingTags == 0 do -- luacheck: ignore 512
        local langCode
        -- allow language suffix of form "-en_CA" or "-<rfc3066>" on tag name
        local t1, l2, l3 = matches(tag, [[(?i)^([?*\w]+)-([a-z]{2})(_[a-z]{2})$]]) -- MIE
        if not t1 then
            t1, l2, l3 = matches(tag, [[(?i)^([?*\w]+)-([a-z]{2,3}|[xi])(-[a-z\d]{2,8}(-[a-z\d]{1,8})*)?$]]) -- XMP/PNG/QuickTime
        end
        if t1 then
            tag = t1
            -- normalize case of language codes
            langCode = lc(l2)
            if perlTruthy(l3) then langCode = langCode .. (#l3 == 3 and perl.uc(l3) or lc(l3)) end
            local newMatches = FindTagInfo(tag)
            for _, ti in ipairs(newMatches) do
                -- only allow language codes in tables which support them
                if not ti.Table then goto nextLang end
                do
                    local langInfoProc = ti.Table.LANG_INFO
                    if not langInfoProc then goto nextLang end
                    -- (Lua: XMP's GetLangInfo needs the ExifTool object too)
                    local langInfo = langInfoProc(ti, langCode, self)
                    if langInfo then matchingTags[#matchingTags + 1] = langInfo end
                end
                ::nextLang::
            end
            if #matchingTags > 0 then break end
        elseif not options.NoShortcut then
            -- look for a shortcut or alias
            local Shortcuts = require('lexiftool.Shortcuts')
            local match
            for _, name in ipairs(perl.keys(Shortcuts.Main)) do
                if lc(name) == lc(tag) then match = name break end
            end
            err = nil
            if match then
                options.NoShortcut = 1
                options.Sanitized = 1
                for _, t in ipairs(Shortcuts.Main[match]) do
                    local n, e = Writer.SetNewValue(self, t, value, options)
                    numSet = numSet + n
                    if perlTruthy(e) then err = e end
                end
                if numSet > 0 then err = nil end  -- no error if any set successfully
                return numSet, err
            end
        end
        if not perlTruthy(listOnly) then
            if not perlTruthy(TagExists(tag)) then
                if isMatch(tag, [[^[-\w*?]+$]]) then
                    local pre = wantGroupStr and (wantGroupStr .. ':') or ''
                    err = "Tag '" .. pre .. origTag .. "' is not defined"
                    if isMatch(origTag, '-') then err = err .. ' or has a bad language code' end
                    if pre == '' and perl.uc(origTag) == 'TAG' then
                        err = err .. " (specify a writable tag name, not '" .. origTag .. "' literally)"
                    end
                else
                    err = "Invalid tag name '" .. tag .. "'"
                    if isMatch(tag, [[^\$]]) then err = err .. " (remove the leading '$')" end
                end
            elseif langCode then
                err = "Tag '" .. tag .. "' does not support alternate languages"
            elseif wantGroupStr then
                err = 'Sorry, ' .. wantGroupStr .. ':' .. origTag .. " doesn't exist or isn't writable"
            else
                err = 'Sorry, ' .. origTag .. ' is not writable'
            end
            if verbose > 2 then out:write(err .. "\n") end
        end
        -- all done
        return numSet, err
    end
    -- get group name that we're looking for
    local foundMatch = 0
--
-- determine the groups for all tags found, and the tag with
-- the highest priority group
--
    local tagInfoList, writeAlsoList, writeGroupOf, preferred, tagPriority = { }, { }, { }, { }, { }
    local avoid, wasProtected, noCreate, highestPriority, highestQT = { }, nil, nil, { }, { }

    for _, ti in ipairs(matchingTags) do
        tagInfo = ti
        tag = tagInfo.Name          -- get tag name for warnings
        local lcTag = lc(tag)       -- get lower-case tag name for use in variables
        -- initialize highest priority if we are starting a new tag
        if highestPriority[lcTag] == nil then highestPriority[lcTag] = -999 end
        local priority, writeGroup
        local prfTag = tagInfo.Preferred
        if prfTag == nil then prfTag = tagInfo.Table and tagInfo.Table.PREFERRED end
        if wantGroupStr then
            -- a WriteGroup of All is special
            local wgAll = (tagInfo.WriteGroup and tagInfo.WriteGroup == 'All')
            local grp = self:GetGroup(tagInfo)
            local hiPri = 1000
            for _, fg in ipairs(wantGroup) do
                local fam, lcWant = fg[1], fg[2]
                fam = fam ~= nil and tonumber(fam) or nil
                if translateWantGroup[lcWant] then lcWant = translateWantGroup[lcWant] end
                -- only set tag in specified group
                -- bump priority of preferred tag
                if perlTruthy(prfTag) then hiPri = hiPri + prfTag end
                if fam == nil then
                    if lcWant == lc(grp[0]) then
                        -- don't go to more general write group of "All"
                        -- if something more specific was wanted
                        if wgAll and not writeGroup then writeGroup = grp[0] end
                        goto nextFam
                    end
                    if lcWant == lc(grp[2]) then goto nextFam end
                elseif fam == 7 then
                    if perlTruthy(ExifTool.IsSameID(tagInfo.TagID, lcWant)) then goto nextFam end
                elseif fam ~= 1 and not tagInfo.AllowGroup then
                    if lcWant == lc(grp[fam]) then goto nextFam end
                    if wgAll and fam == 0 and allFam0[lcWant] then
                        if not writeGroup then writeGroup = allFam0[lcWant] end
                        goto nextFam
                    end
                    goto nextTag    -- wrong group
                end
                -- handle family 1 groups specially
                if grp[0] == 'EXIF' or grp[0] == 'SonyIDC' or wgAll then
                    if not (ifdName and lcWant == lc(ifdName)) then
                        if not (wgAll and not perlTruthy(fam) and allFam0[lcWant]) then goto nextTag end
                        if not writeGroup then writeGroup = allFam0[lcWant] end
                        goto nextFam
                    end
                    if wgAll and allFam0[lcWant] and perlTruthy(fam) then goto nextTag end
                    -- can't yet write PreviewIFD tags (except for image)
                    if lcWant == 'PreviewIFD' then
                        foundMatch = foundMatch + 1
                        goto nextTag
                    end
                    writeGroup = ifdName -- write to the specified IFD
                elseif grp[0] == 'QuickTime' then
                    if grp[1] == 'Track#' then
                        if not (movGroup and lcWant == lc(movGroup)) then goto nextTag end
                        writeGroup = movGroup
                    else
                        local g = tagInfo.Table.WRITE_GROUP
                        if not (g and lcWant == lc(g)) then goto nextTag end
                        writeGroup = g
                    end
                elseif grp[0] == 'MIE' then
                    if not (mieGroup and lcWant == lc(mieGroup)) then goto nextTag end
                    writeGroup = mieGroup -- write to specific MIE group
                    -- set specific write group with document number if specified
                    if isMatch(writeGroup, [[^MIE\d+$]]) and tagInfo.Table.WRITE_GROUP then
                        writeGroup = tagInfo.Table.WRITE_GROUP
                        writeGroup = subst(writeGroup, '^MIE', mieGroup)
                    end
                elseif not tagInfo.AllowGroup or not isMatchDyn(lcWant, '(?i)^' .. tagInfo.AllowGroup .. '$') then
                    -- allow group1 name to be specified
                    if lcWant ~= lc(grp[1]) then goto nextTag end
                end
                ::nextFam::
            end
            if not perlTruthy(writeGroup) then
                writeGroup = tagInfo.WriteGroup or tagInfo.Table.WRITE_GROUP or grp[0]
            end
            priority = hiPri -- highest priority since group was specified
        end
        foundMatch = foundMatch + 1
        do
            -- must do a dummy call to the write proc to autoload write package
            -- before checking Writable flag
            -- (Lua: the write procs are function references that load their
            --  package themselves when first called, and every one of them
            --  answers the dummy call with 1, so the call is not made here)
            local tbl = tagInfo.Table
            -- must still check writable flags in case of UserDefined tags
            local writable = tagInfo.Writable
            if not (perlTruthy(writable) or (tbl.WRITABLE and
                writable == nil and not tagInfo.SubDirectory)) then goto nextTag end
            -- set specific write group (if we didn't already)
            if not perlTruthy(writeGroup) or (translateWriteGroup[writeGroup] and
                (not tagInfo.WriteGroup or tagInfo.WriteGroup ~= 'All'))
            then
                -- use default write group
                writeGroup = tagInfo.WriteGroup or tagInfo.Table.WRITE_GROUP
                -- use group 0 name if no WriteGroup specified
                local group0 = self:GetGroup(tagInfo, 0)
                if not perlTruthy(writeGroup) then writeGroup = group0 end
                -- get priority for this group
                if not perlTruthy(priority) then
                    if tagInfo.Avoid and tagInfo.WriteAlso then
                        priority = 0
                    else
                        priority = self.WRITE_PRIORITY[lc(writeGroup)]
                        if not perlTruthy(priority) then
                            priority = self.WRITE_PRIORITY[lc(group0)] or 0
                        end
                    end
                end
                -- adjust priority based on Preferred level for this tag
                if perlTruthy(prfTag) then priority = priority + prfTag end
            end
            -- don't write tag if protected
            local prot = tagInfo.Protected
            if noFlat and tagInfo.Flat ~= nil then prot = 1 end
            if perlTruthy(prot) then
                prot = prot & ~protected
                if prot ~= 0 then
                    local lkup = { [1] = 'unsafe', [2] = 'protected', [3] = 'unsafe and protected' }
                    wasProtected = lkup[prot]
                    if verbose > 1 then
                        local wgrp1 = Writer.GetWriteGroup1(self, tagInfo, writeGroup)
                        out:write('Sorry, ' .. wgrp1 .. ':' .. tag .. ' is ' .. perlStr(wasProtected) .. " for writing\n")
                    end
                    goto nextTag
                end
            end
            -- set priority for this tag
            tagPriority[tagInfo] = priority
            -- keep track of highest priority QuickTime tag
            if tbl.GROUPS and tbl.GROUPS[0] == 'QuickTime' and
                (highestQT[lcTag] == nil or highestQT[lcTag] < priority) then highestQT[lcTag] = priority end
            if priority > highestPriority[lcTag] then
                highestPriority[lcTag] = priority
                preferred[lcTag] = { [tagInfo] = 1 }
                avoid[lcTag] = tagInfo.Avoid and 1 or 0
            elseif priority == highestPriority[lcTag] then
                -- create all tags with highest priority
                preferred[lcTag][tagInfo] = 1
                if tagInfo.Avoid then avoid[lcTag] = avoid[lcTag] + 1 end
            end
            if tagInfo.WriteAlso then
                -- store WriteAlso tags separately so we can set them first
                writeAlsoList[#writeAlsoList + 1] = tagInfo
            else
                tagInfoList[#tagInfoList + 1] = tagInfo
            end
            -- special case to allow override of XMP WriteGroup
            if writeGroup == 'XMP' then
                local wg = tagInfo.WriteGroup or tbl.WRITE_GROUP
                if wg then writeGroup = wg end
            end
            writeGroupOf[tagInfo] = writeGroup
        end
        ::nextTag::
    end
    -- sort tag info list in reverse order of priority (highest number last)
    -- so we get the highest priority error message in the end
    -- (perl.sort: Perl's sort is stable, table.sort is not)
    tagInfoList = perl.sort(tagInfoList, function(a, b) return tagPriority[a] - tagPriority[b] end)
    -- must write any tags which also write other tags first
    if #writeAlsoList > 0 then
        for i = #writeAlsoList, 1, -1 do table.insert(tagInfoList, 1, writeAlsoList[i]) end
    end

    -- check priorities for each set of tags we are writing
    for _, lcTag in ipairs(perl.keys(preferred)) do
        -- don't create tags with priority 0 if group priorities are set
        if preferred[lcTag] and highestPriority[lcTag] == 0 and
            next(self.WRITE_PRIORITY) ~= nil
        then
            preferred[lcTag] = nil
        end
        -- avoid creating tags with 'Avoid' flag set if there are other alternatives
        if perlTruthy(avoid[lcTag]) and preferred[lcTag] then
            if avoid[lcTag] < #perl.keys(preferred[lcTag]) then
                -- just remove the 'Avoid' tags since there are other preferred tags
                for _, ti in ipairs(tagInfoList) do
                    if lcTag ~= lc(ti.Name) then goto nextAvoid end
                    if ti.Avoid then preferred[lcTag][ti] = nil end
                    ::nextAvoid::
                end
            elseif highestPriority[lcTag] < 1000 then
                -- look for another priority tag to create instead
                local nextHighest = 0
                local nextBestTags = { }
                for _, ti in ipairs(tagInfoList) do
                    if lcTag ~= lc(ti.Name) then goto nextBest end
                    do
                        local priority = tagPriority[ti]
                        if not perlTruthy(priority) then goto nextBest end
                        if priority == highestPriority[lcTag] then goto nextBest end
                        if priority < nextHighest then goto nextBest end
                        local permanent = ti.Permanent
                        if permanent == nil then permanent = ti.Table.PERMANENT end
                        if ti.Avoid or perlTruthy(permanent) then goto nextBest end
                        if writeGroupOf[ti] == 'MakerNotes' then goto nextBest end
                        if nextHighest < priority then
                            nextHighest = priority
                            nextBestTags = { }
                        end
                        nextBestTags[#nextBestTags + 1] = ti
                    end
                    ::nextBest::
                end
                if #nextBestTags > 0 then
                    -- change our preferred tags to the next best tags
                    preferred[lcTag] = { }
                    for _, ti in ipairs(nextBestTags) do
                        preferred[lcTag][ti] = 1
                    end
                end
            end
        end
    end
--
-- generate new value hash for each tag
--
    local prioritySet, createGroups
    local alsoWrote = { }

    self.CHECK_WARN = nil  -- reset CHECK_PROC warnings

    -- loop through all valid tags to find the one(s) to write
    for _, ti in ipairs(tagInfoList) do
        tagInfo = ti
        if alsoWrote[tagInfo] then goto nextGen end   -- don't rewrite tags we already wrote
        -- only process List or non-List tags if specified
        if listOnly ~= nil and (perlTruthy(listOnly) ~= perlTruthy(tagInfo.List)) then goto nextGen end
        do
            local noConv
            local writeGroup = writeGroupOf[tagInfo]
            local permanent = tagInfo.Permanent
            if permanent == nil then permanent = tagInfo.Table.PERMANENT end
            if permanent == nil and writeGroup == 'MakerNotes' then permanent = 1 end
            local wgrp1 = Writer.GetWriteGroup1(self, tagInfo, writeGroup)
            tag = tagInfo.Name          -- get tag name for warnings
            local lcTag = lc(tag)
            local pref = preferred[lcTag] or { }
            -- don't write Avoid-ed tags with side effect unless preferred
            if not pref[tagInfo] and tagInfo.Avoid and tagInfo.WriteAlso then goto nextGen end
            local shift = options.Shift
            local addValue = options.AddValue
            local val
            do
                if shift ~= nil then
                    -- (can't currently shift list-type tags)
                    local shiftable
                    if tagInfo.List then
                        shiftable = ''      -- can add/delete but not shift
                    else
                        shiftable = tagInfo.Shift
                        if not perlTruthy(shift) then
                            -- set shift according to AddValue/DelValue
                            if perlTruthy(addValue) then shift = 1 end
                            -- can shift a date/time with -=, but this is
                            -- a conditional delete operation for other tags
                            if perlTruthy(options.DelValue) and shiftable ~= nil and shiftable == 'Time' then shift = -1 end
                        end
                        if perlTruthy(shift) and (value == nil or #perlStr(value) == 0) then
                            -- (now allow -= to be used for shiftable tag - v8.05)
                            --$err = "No value for time shift of $wgrp1:$tag";
                            --$verbose > 2 and print $out "$err\n";
                            --next;
                            shift = nil
                        end
                    end
                        -- can't shift List-type tag
                    if (shiftable ~= nil and not perlTruthy(shiftable)) and
                        -- and don't try to conditionally delete if Shift is "0"
                        (perlTruthy(shift) or (perlStr(shiftable) == '0' and perlTruthy(options.DelValue)))
                    then
                        err = wgrp1 .. ':' .. tag .. ' is not shiftable'
                        if verbose > 0 then out:write(err .. "\n") end
                        goto nextGen
                    end
                end
                -- (Lua: Perl's $shift is 0 or undef when not shifting, which
                --  is false there but true here)
                if not perlTruthy(shift) then shift = nil end
                val = value
                if val ~= nil then
                    -- check to make sure this is a List or Shift tag if adding
                    if perlTruthy(addValue) and not (shift or tagInfo.List) then
                        if perlStr(addValue) == '2' then
                            addValue = nil  -- quietly reset this option
                        else
                            err = "Can't add " .. wgrp1 .. ':' .. tag .. ' (not a List type)'
                            if verbose > 2 then out:write(err .. "\n") end
                            goto nextGen
                        end
                    end
                    if shift then
                        if tagInfo.Shift and tagInfo.Shift == 'Time' then
                            -- add '+' or '-' prefix to indicate shift direction
                            val = (shift > 0 and '+' or '-') .. val
                            -- check the shift for validity
                            local err2 = Shift.CheckShift(tagInfo.Shift, val)
                            if err2 then
                                err = err2 .. ' for ' .. wgrp1 .. ':' .. tag
                                if verbose > 2 then out:write(err .. "\n") end
                                goto nextGen
                            end
                        elseif ExifTool.IsFloat(val) then
                            val = val * shift
                        else
                            err = 'Shift value for ' .. wgrp1 .. ':' .. tag .. ' is not a number'
                            if verbose > 2 then out:write(err .. "\n") end
                            goto nextGen
                        end
                        noConv = 1    -- no conversions if shifting tag
                    elseif type(val) ~= 'table' and #perlStr(val) == 0 and perlTruthy(options.DelValue) then
                        noConv = 1    -- no conversions for deleting empty value
                    elseif isHashRef(val) and not tagInfo.Struct then
                        err = "Can't write a structure to " .. wgrp1 .. ':' .. tag
                        if verbose > 2 then out:write(err .. "\n") end
                        goto nextGen
                    end
                elseif perlTruthy(permanent) then
                    if options.IgnorePermanent then return 0 end
                    -- can't delete permanent tags, so set them to DelValue or empty string instead
                    if tagInfo.DelValue ~= nil then
                        val = tagInfo.DelValue
                        noConv = 1    -- DelValue is the raw value, so no conversion necessary
                    else
                        val = ''
                    end
                elseif perlTruthy(addValue) or perlTruthy(options.DelValue) then
                    err = 'No value to add or delete in ' .. wgrp1 .. ':' .. tag
                    if verbose > 2 then out:write(err .. "\n") end
                    goto nextGen
                else
                    if tagInfo.DelCheck then
                        --### eval DelCheck ($self, $tagInfo, $wantGroup)
                        local ok, err2, newVal = pcall(tagInfo.DelCheck, self, tagInfo, wantGroupStr)
                        if not ok then
                            perl.print(io.stderr, tostring(err2) .. '\n')
                            err2 = 'Error evaluating DelCheck'
                        elseif newVal ~= nil then
                            val = newVal    -- (the code string's `$val = ...`)
                        end
                        if err2 ~= nil then
                            -- (allow other tags to be set using DelCheck as a hook)
                            if not perlTruthy(err2) then goto WriteAlso end -- GOTO!
                            if not isMatch(err2, 'delete$') then err2 = err2 .. ' for' end
                            err = err2 .. ' ' .. wgrp1 .. ':' .. tag
                            if verbose > 2 then out:write(err .. "\n") end
                            goto nextGen
                        end
                    end
                    -- set group delete flag if this tag represents an entire group
                    if tagInfo.DelGroup and not perlTruthy(options.DelValue) then
                        local del = { tag }
                        self.DEL_GROUP[tag] = 1
                        -- delete extra groups if necessary
                        if delMore[tag] then
                            for _, g in ipairs(delMore[tag]) do
                                self.DEL_GROUP[g] = 1
                                del[#del + 1] = g
                            end
                        end
                        -- remove all of this group from previous new values
                        Writer.RemoveNewValuesForGroup(self, tag)
                        if verbose > 0 then out:write('  Deleting tags in: ' .. join(' ', del) .. "\n") end
                        numSet = numSet + 1
                        goto nextGen
                    end
                    noConv = 1    -- value is not defined, so don't do conversion
                end
                -- apply inverse PrintConv and ValueConv conversions
                -- save ValueConv setting for use in ConvInv()
                if not noConv then
                    -- set default conversion type used by ConvInv() and CHECK_PROC routines
                    self.ConvType = convType
                    local e
                    val, e = Writer.ConvInv(self, val, tagInfo, tag, wgrp1, self.ConvType, wantGroupStr)
                    if e ~= nil then
                        -- empty error string causes error to be ignored without setting the value
                        if not perlTruthy(e) then goto WriteAlso end -- GOTO!
                        err = e
                    end
                end
                if val == nil and value ~= nil then
                    -- if value conversion failed, we must still add a NEW_VALUE
                    -- entry for this tag it it was a DelValue
                    if not perlTruthy(options.DelValue) then goto nextGen end
                    val = 'xxx never delete xxx'
                end
                if not self.NEW_VALUE then self.NEW_VALUE = { } end
                if perlTruthy(options.Replace) then
                    -- delete the previous new value
                    Writer.GetNewValueHash(self, tagInfo, writeGroup, 'delete', options.ProtectSaved)
                    -- also delete related tag previous new values
                    if tagInfo.WriteAlso then
                        self.INDENT2 = '+'
                        local wgrp
                        if tagInfo.WriteGroup and tagInfo.WriteGroup == 'All' and writeGroup then
                            wgrp = writeGroup .. ':'
                        else
                            wgrp = ''
                        end
                        for _, wtag in ipairs(perl.sort(perl.keys(tagInfo.WriteAlso))) do
                            local n = Writer.SetNewValue(self, wgrp .. wtag, nil, { Replace = 2 })
                            numSet = numSet + n
                        end
                        self.INDENT2 = ''
                    end
                    if options.Replace == 2 then
                        numSet = numSet + 1
                        goto nextGen
                    end
                end

                if val ~= nil then
                    -- we are editing this tag, so create a NEW_VALUE hash entry
                    local nvHash = Writer.GetNewValueHash(self, tagInfo, writeGroup, 'create',
                                        options.ProtectSaved, (perlTruthy(options.DelValue) and not shift))
                    -- ignore new values protected with ProtectSaved
                    if not nvHash then
                        numSet = numSet + 1 -- (increment $numSet to avoid warning)
                        goto nextGen
                    end
                    if tagInfo.List and not perlTruthy(options.Replace) then nvHash.NoReplace = 1 end
                    nvHash.WantGroup = wantGroupStr
                    if editOnly then nvHash.EditOnly = 1 end
                    -- save maker note fixup information if writing maker notes
                    if tagInfo.MakerNotes then nvHash.MAKER_NOTE_FIXUP = options.Fixup end
                    if createOnly then  -- create only (never edit)
                        -- empty item in DelValue list to never edit existing value
                        nvHash.DelValue = { '' }
                        nvHash.CreateOnly = 1
                    elseif perlTruthy(options.DelValue) or perlTruthy(addValue) or shift then
                        -- flag any AddValue or DelValue by creating the DelValue list
                        if not nvHash.DelValue then nvHash.DelValue = { } end
                        if shift then
                            -- add shift value to list
                            nvHash.Shift = val
                        elseif perlTruthy(options.DelValue) then
                            -- don't create if we are replacing a specific value
                            if not (val == '' or tagInfo.List) then nvHash.IsCreating = 0 end
                            -- add delete value to list
                            if isArrayRef(val) then
                                for _, v in ipairs(val) do nvHash.DelValue[#nvHash.DelValue + 1] = v end
                            else
                                nvHash.DelValue[#nvHash.DelValue + 1] = val
                            end
                            if verbose > 1 then
                                local verb = perlTruthy(permanent) and 'Replacing' or 'Deleting'
                                local fromList = tagInfo.List and ' from list' or ''
                                local vals = isArrayRef(val) and { table.unpack(val) } or { val }
                                for _, v in ipairs(vals) do
                                    if isHashRef(v) then
                                        v = require('lexiftool.XMP').SerializeStruct(self, v)
                                    end
                                    out:write(self.INDENT2 .. verb .. ' ' .. wgrp1 .. ':' .. tag .. fromList ..
                                              " if value is '" .. perlStr(v) .. "'\n")
                                end
                            end
                        end
                    end
                    -- set priority flag to add only the high priority info
                    -- (will only create the priority tag if it doesn't exist,
                    --  others get changed only if they already exist)
                    local prf = tagInfo.Preferred
                    if prf == nil then prf = tagInfo.Table.PREFERRED end
                    -- hack to prefer only a single tag in the QuickTime group
                    if tagInfo.Table.GROUPS and tagInfo.Table.GROUPS[0] == 'QuickTime' then
                        if tagPriority[tagInfo] < highestQT[lcTag] then prf = 0 end
                    end
                    if pref[tagInfo] or perlTruthy(prf) then
                        if perlTruthy(permanent) or shift then
                            -- don't create permanent or Shift-ed tag but define IsCreating
                            -- so we know that it is the preferred tag
                            nvHash.IsCreating = 0
                        else
                            local emptyDel   -- (grep(/^$/,@{$$nvHash{DelValue}}))
                            for _, dv in ipairs(nvHash.DelValue or { }) do
                                if dv == '' then emptyDel = true end
                            end
                            if (tagInfo.List and not perlTruthy(options.DelValue)) or
                                 not (nvHash.DelValue and #nvHash.DelValue > 0) or
                                 -- also create tag if any DelValue value is empty ('')
                                 emptyDel
                            then
                                nvHash.IsCreating = editOnly and 0 or (editGroup and 2 or 1)
                                -- add to hash of groups where this tag is being created
                                if not createGroups then createGroups = options.CreateGroups or { } end
                                createGroups[self:GetGroup(tagInfo, 0)] = 1
                                nvHash.CreateGroups = createGroups
                            end
                        end
                    end
                    if perlTruthy(nvHash.IsCreating) then
                        if next(self.DEL_GROUP) ~= nil then
                            local grps = { }
                            for _, grp in ipairs(perl.keys(self.DEL_GROUP)) do
                                if self.DEL_GROUP[grp] == 2 then goto nextDG end
                                -- set flag indicating tags were written after this group was deleted
                                self.DEL_GROUP[grp] = 2
                                grps[#grps + 1] = grp
                                ::nextDG::
                            end
                            if verbose > 1 and #grps > 0 then
                                grps = perl.sort(grps)
                                out:write('  Writing new tags after deleting groups: ' .. join(' ', grps) .. "\n")
                            end
                        end
                    elseif createOnly then
                        noCreate = perlTruthy(permanent) and 'permanent' or (tagInfo.Avoid and 'avoided' or '')
                        if noCreate == '' then noCreate = shift and 'shifting' or 'not preferred' end
                        if verbose > 2 then out:write('Not creating ' .. wgrp1 .. ':' .. tag .. ' (' .. noCreate .. ")\n") end
                        goto nextGen    -- nothing to do (not creating and not editing)
                    end
                    if shift or not perlTruthy(options.DelValue) then
                        if not nvHash.Value then nvHash.Value = { } end
                        if not tagInfo.List then
                            -- not a List tag -- overwrite existing value
                            nvHash.Value[1] = val
                        elseif nvHash.AddBefore ~= nil and #nvHash.Value >= nvHash.AddBefore then
                            -- values from a later argument have been added (ie. Replace=0)
                            -- to this list, so the new values should come before these
                            local pos = #nvHash.Value - nvHash.AddBefore
                            local vals = isArrayRef(val) and val or { val }
                            for i, v in ipairs(vals) do table.insert(nvHash.Value, pos + i, v) end
                        else
                            -- add at end of existing list
                            if isArrayRef(val) then
                                for _, v in ipairs(val) do nvHash.Value[#nvHash.Value + 1] = v end
                            else
                                nvHash.Value[#nvHash.Value + 1] = val
                            end
                        end
                        if verbose > 1 then
                            local ifExists
                            if tagInfo.IsComposite then
                                -- (composite tags don't technically exist in the file)
                                if tagInfo.WriteAlso then
                                    ifExists = ' (+' .. join(',+', perl.sort(perl.keys(tagInfo.WriteAlso))) .. '):'
                                else
                                    ifExists = ''
                                end
                            else
                                if perlTruthy(nvHash.IsCreating) then
                                    if createOnly then
                                        ifExists = nvHash.IsCreating == 2 and
                                            (' if ' .. writeGroup .. " exists and tag doesn't") or
                                            " if tag doesn't exist"
                                    else
                                        ifExists = nvHash.IsCreating == 2 and (' if ' .. writeGroup .. ' exists') or ''
                                    end
                                else
                                    ifExists = (nvHash.DelValue and #nvHash.DelValue > 0) and
                                        ' if tag was deleted' or ' if tag exists'
                                end
                            end
                            local verb = shift and 'Shifting' or (perlTruthy(addValue) and 'Adding' or 'Writing')
                            out:write(self.INDENT2 .. verb .. ' ' .. wgrp1 .. ':' .. tag .. ifExists .. "\n")
                        end
                    end
                elseif perlTruthy(permanent) then
                    err = "Can't delete Permanent tag " .. wgrp1 .. ':' .. tag
                    if verbose > 1 then out:write(err .. "\n") end
                    goto nextGen
                elseif perlTruthy(addValue) or perlTruthy(options.DelValue) then
                    if verbose > 1 then out:write("Adding/Deleting nothing does nothing\n") end
                    goto nextGen
                else
                    -- create empty new value hash entry to delete this tag
                    Writer.GetNewValueHash(self, tagInfo, writeGroup, 'delete')
                    local nvHash = Writer.GetNewValueHash(self, tagInfo, writeGroup, 'create')
                    nvHash.WantGroup = wantGroupStr
                    if verbose > 1 then out:write(self.INDENT2 .. 'Deleting ' .. wgrp1 .. ':' .. tag .. "\n") end
                end
                if setTags then setTags[tagInfo] = 1 end
                if pref[tagInfo] then prioritySet = 1 end
            end
::WriteAlso::
            numSet = numSet + 1
            -- also write related tags
            local writeAlso = tagInfo.WriteAlso
            if writeAlso then
                self.INDENT2 = '+'  -- indicate related tag with a leading "+"
                local wgrp
                if tagInfo.WriteGroup and tagInfo.WriteGroup == 'All' and writeGroup then
                    wgrp = writeGroup .. ':'
                else
                    wgrp = ''
                end
                local oldWarn = perl.SIG.__WARN__
                perl.SIG.__WARN__ = ExifTool.SetWarning
                for _, wtag in ipairs(perl.sort(perl.keys(writeAlso))) do
                    local o = {
                        Type = 'ValueConv',
                        Protected   = protected | 0x02,
                        AddValue    = addValue,
                        DelValue    = options.DelValue,
                        Shift       = options.Shift,
                        Replace     = options.Replace,   -- handle lists properly
                        CreateGroups= createGroups,
                        SetTags     = alsoWrote,         -- remember tags already written
                    }
                    ExifTool.evalWarning = nil
                    --### eval WriteAlso ($val,%opts)
                    -- (Lua: the WriteAlso entries are functions of
                    --  ($self, $val, \%opts) -- they may change the options)
                    local ok, v = pcall(writeAlso[wtag], self, val, o)
                    -- we wanted to do the eval in case there are side effect, but we
                    -- don't want to write a value for a tag that is being deleted:
                    -- (Lua: an entry that fails on the undefined $val of a
                    --  deletion has nothing to report either)
                    if val == nil then v, ok = nil, true end
                    if not ok then
                        ExifTool.evalWarning = perl.isDie(v) and v.msg or tostring(v)
                        v = nil
                    end
                    if not perlTruthy(ExifTool.evalWarning) then
                        local n
                        n, ExifTool.evalWarning = Writer.SetNewValue(self, wgrp .. wtag, v, o)
                        numSet = numSet + n
                        -- count this as being set if any related tag is set
                        if n > 0 and pref[tagInfo] then prioritySet = 1 end
                    end
                    if perlTruthy(ExifTool.evalWarning) and (not perlTruthy(err) or verbose > 2) then
                        local str = ExifTool.CleanWarning()
                        if perlTruthy(str) then
                            if not isMatch(str, [[ for [-\w:]+$]]) then str = str .. ' for ' .. wtag end
                            str = str .. ' in ' .. wgrp1 .. ':' .. tag .. ' (WriteAlso)'
                            if not perlTruthy(err) then err = str end
                            if verbose > 2 then out:write(str .. "\n") end
                        end
                    end
                end
                perl.SIG.__WARN__ = oldWarn
                self.INDENT2 = ''
            end
        end
        ::nextGen::
    end
    -- print warning if we couldn't set our priority tag
    if err ~= nil and not prioritySet then -- luacheck: ignore 542
        -- (upstream warns here in scalar context)
    elseif numSet == 0 then
        local pre = wantGroupStr and (wantGroupStr .. ':') or ''
        if wasProtected then
            verbose = 0   -- we already printed this verbose message
            if not (options.Replace and options.Replace == 2) then
                err = 'Sorry, ' .. pre .. tag .. ' is ' .. wasProtected .. ' for writing'
            end
        elseif not perlTruthy(listOnly) then
            if isMatch(origTag, '[?*]') then
                if noCreate then
                    err = "No tags matching 'pre" .. origTag .. "' will be created"
                    verbose = 0   -- (already printed)
                elseif foundMatch > 0 then
                    err = "Sorry, no writable tags matching '" .. pre .. origTag .. "'"
                else
                    err = "No matching tags for '" .. pre .. origTag .. "'"
                end
            elseif noCreate then
                err = 'Not creating ' .. pre .. tag
                verbose = 0   -- (already printed)
            elseif foundMatch > 0 then
                err = 'Sorry, ' .. pre .. tag .. ' is not writable'
            elseif wantGroupStr and #matchingTags > 0 then
                err = 'Sorry, ' .. pre .. tag .. " doesn't exist or isn't writable"
            else
                err = "Tag '" .. pre .. tag .. "' is not defined"
            end
        end
        if perlTruthy(err) then
            if verbose > 2 then out:write(err .. "\n") end
        end
    elseif self.CHECK_WARN then
        err = self.CHECK_WARN
        if verbose > 2 then out:write(err .. "\n") end
    elseif perlTruthy(err) and not perlTruthy(verbose) then
        err = nil
    end
    return numSet, err
end

--------------------------------------------------------------------------------
-- set new values from information in specified file
-- Inputs: 0) ExifTool object reference, 1) source file name or reference, etc,
--         or ExifTool ref to use already-extracted tags from an ExifTool object,
--         2-N) List of tags to set (or all if none specified), or reference(s) to
--         hash for options to pass to SetNewValue.  The Replace option defaults
--         to 1 for SetNewValuesFromFile -- set this to 0 to allow multiple tags
--         to be copied to a list
-- Returns: Hash of information set successfully (includes Warning or Error messages)
-- Notes: Tag names may contain a group prefix, a leading '-' to exclude from copy,
--        and/or a trailing '#' to copy the ValueConv value.  The tag name '*' may
--        be used to represent all tags in a group.  An optional destination tag
--        may be specified with '>DSTTAG' ('DSTTAG<TAG' also works, but in this
--        case the source tag may also be an expression involving tag names).
--        Simple assignments are also allowed: 'DSTTAG[#][+-][^]=[string]'
-- (Lua: an options hash in the tag list is a table; SetNewValue gets a copy of
--  the options, as Perl's `%$opts` flattening makes one)
function Writer.SetNewValuesFromFile(self, srcFile, ...)
    local setTags = { ... }
    local srcExifTool, tag, info
    local exclude, reqTags = { }, { }

    -- get initial SetNewValuesFromFile options
    local opts = { Replace = 1 }    -- replace existing list items by default
    while type(setTags[1]) == 'table' do
        local o = remove(setTags, 1)
        for k, v in pairs(o) do
            opts[k] = v
        end
    end
    -- expand shortcuts
    if #setTags > 0 then ExifTool.ExpandShortcuts(setTags) end
    -- set options for our extraction tool
    local options = self.OPTIONS
    local printConv = options.PrintConv
    if perlTruthy(opts.Type) then
        -- save source type separately because it may be different than dst Type
        opts.SrcType = opts.Type
        -- override PrintConv option with initial Type if given
        printConv = (opts.Type == 'PrintConv') and 1 or 0
    end
    local srcType = perlTruthy(printConv) and 'PrintConv' or 'ValueConv'
    local structOpt = options.Struct
    if structOpt == nil then structOpt = 2 end

    if type(srcFile) == 'table' and getmetatable(srcFile) == ExifTool then
        srcExifTool = srcFile
        info = srcExifTool:GetInfo({ PrintConv = printConv })
    else
        srcExifTool = ExifTool.new()
        srcExifTool:Options('PrintConv', printConv)
        -- set flag to indicate we are being called from inside SetNewValuesFromFile()
        srcExifTool.TAGS_FROM_FILE = 1
        -- synchronize and increment the file sequence number
        srcExifTool.FILE_SEQUENCE = self.FILE_SEQUENCE
        self.FILE_SEQUENCE = self.FILE_SEQUENCE + 1
        -- copy both structured and flattened tags by default (but flattened tags are "unsafe")
        -- copy structures only if no tags specified (since flattened tags are "unsafe")
        if perlStr(structOpt) == '2' and #setTags == 0 then structOpt = 1 end
        -- +------------------------------------------+
        -- ! DON'T FORGET!!  Must consider each new   !
        -- ! option to decide how it is handled here. !
        -- +------------------------------------------+
        for _, o in ipairs({ 'ByteUnit', 'Charset', 'CharsetEXIF', 'CharsetFileName', 'CharsetID3', 'CharsetIPTC',
                    'CharsetPhotoshop', 'Composite', 'DateFormat', 'Debug', 'EncodeHangs', 'Escape',
                    'ExtendedXMP', 'ExtractEmbedded', 'FastScan', 'Filter', 'FixBase', 'Geolocation',
                    'GeolocAltNames', 'GeolocFeature', 'GeolocMinPop', 'GeolocMaxDist',
                    'GlobalTimeShift', 'GPSQuadrant', 'HexTagIDs', 'IgnoreGroups', 'IgnoreMinorErrors',
                    'IgnoreTags', 'ImageHashType', 'KeepUTCTime', 'Lang', 'LargeFileSupport',
                    'LigoGPSScale', 'ListItem', 'ListSep', 'MDItemTags', 'MissingTagValue', 'NoPDFList',
                    'NoWarning', 'Password', 'PrintConv', 'QuickTimeUTC', 'RequestTags', 'SaveFormat',
                    'SavePath', 'ScanForXMP', 'StructFormat', 'SystemTags', 'SystemTimeRes', 'TimeZone',
                    'Unknown', 'UserParam', 'Validate', 'WindowsLongPath', 'WindowsWideFile', 'XAttrTags',
                    'XMPAutoConv' })
        do
            srcExifTool:Options(o, options[o])
        end
        local makerNotes = 1
        if perlTruthy(options.FastScan) and options.FastScan > 1 then makerNotes = nil end
        local strictDate = options.StrictDate
        if strictDate == nil then strictDate = 1 end
        srcExifTool:Options(
            'Binary',          1,
            -- copy coordinates at high resolution unless otherwise specified
            'CoordFormat',     perlTruthy(options.CoordFormat) and options.CoordFormat or '%d %d %.8f',
            'Duplicates',      1,
          -- Exclude (set below)
            'LimitLongValues', 10000000, -- (10 MB)
            'List',            1,
            'MakerNotes',      makerNotes,
            'RequestAll',      perlTruthy(options.RequestAll) and options.RequestAll or 1, -- (must request all because reqTags doesn't cover wildcards)
            'StrictDate',      strictDate,
            'Struct',          structOpt
        )
        -- reset Geolocation option if we aren't copying any geolocation tags
        if perlTruthy(options.Geolocation) then
            local found
            for _, t in ipairs(setTags) do
                if type(t) == 'string' and isMatch(t, [[(?i)\bGeolocation]]) then found = true break end
            end
            if not found then
                self:VPrint(0, '(resetting unnecessary Geolocation option)')
                srcExifTool.OPTIONS.Geolocation = nil
            end
        end
        srcExifTool.GLOBAL_TIME_OFFSET = self.GLOBAL_TIME_OFFSET
        srcExifTool.ALT_EXIFTOOL = self.ALT_EXIFTOOL
        for _, t in ipairs(setTags) do
            if type(t) == 'table' then goto nextReq end
            do
                -- avoid extracting tags that are excluded
                local ex = matches(t, '^-(.*)')
                if ex then
                    exclude[#exclude + 1] = ex
                    goto nextReq
                end
                -- add specified tags to list of requested tags
                local s = t
                local m1, m2, m3 = matches(s, [[(.+?)\s*(>|<)\s*(.+)]])
                if m1 then
                    if m2 == '>' then
                        s = m1
                    else
                        s = m3
                        if isMatch(s, [[\$]]) then
                            for _, n in ipairs(perl.findAll(s, [[\$\{?(?:[-\w]+:)*([-\w?*]+)]])) do
                                reqTags[#reqTags + 1] = n
                            end
                            goto nextReq
                        end
                    end
                end
                local _, name = matches(s, [[(^|:)([-\w?*]+)#?$]])
                if name then reqTags[#reqTags + 1] = name end
            end
            ::nextReq::
        end
        if #exclude > 0 then
            ExifTool.ExpandShortcuts(exclude, 1)
            srcExifTool:Options('Exclude', exclude)
        end
        if #reqTags > 0 then srcExifTool:Options('RequestTags', reqTags) end
        -- get all tags from source file (including MakerNotes block)
        info = srcExifTool:ImageInfo(srcFile)
    end
    -- (allow processing to continue if we have alternate files that may have been read OK)
    if info.Error and info.Error == 'Error opening file' and not self.ALT_EXIFTOOL then return info end
    srcExifTool.VALUE.Error = nil -- delete so we can check this later

    -- sort tags in file order with priority tags last
    local tags, prio = { }, { }
    local fileOrder = srcExifTool.FILE_ORDER
    local keys = { }
    for k in pairs(info) do keys[#keys + 1] = k end
    tsort(keys, function(a, b)
        local fa, fb = fileOrder[a] or 0, fileOrder[b] or 0
        if fa ~= fb then return fa < fb end
        return perl.lt(a, b)    -- (Perl's hash order is random here; make it stable)
    end)
    for _, k in ipairs(keys) do
        if k:find(' ', 1, true) then
            tags[#tags + 1] = k
        else
            prio[#prio + 1] = k
        end
    end
    for _, k in ipairs(prio) do tags[#tags + 1] = k end
--
-- simply transfer all tags from source image if no tags specified
--
    if #setTags == 0 then
        -- transfer maker note information to this object
        self.MAKER_NOTE_BYTE_ORDER = srcExifTool.MAKER_NOTE_BYTE_ORDER
        local tagExtra = srcExifTool.TAG_EXTRA
        for _, t in ipairs(tags) do
            tag = t
            -- don't try to set errors or warnings
            if isMatch(tag, [[^(Error|Warning)\b]]) then goto nextTag end
            -- get appropriate value type if necessary
            if perlTruthy(opts.SrcType) and opts.SrcType ~= srcType then
                info[tag] = srcExifTool:GetValue(tag, opts.SrcType)
            end
            do
                local fixup = tagExtra[tag] and tagExtra[tag].Fixup
                if fixup then opts.Fixup = fixup end
                -- set value for this tag
                local n = self:SetNewValue(tag, info[tag], copyOpts(opts))
                -- delete this tag if we couldn't set it
                if not perlTruthy(n) then info[tag] = nil end
                if fixup then opts.Fixup = nil end
            end
            ::nextTag::
        end
        return info
    end
--
-- transfer specified tags in the proper order
--
    -- 1) loop through input list of tags to set, and build @setList
    local setList, setMatches, altFiles = { }, { }, { }
    local assign = 0
    for _, t in ipairs(setTags) do
        if type(t) == 'table' then
            -- update current options
            for k, v in pairs(t) do
                opts[k] = v
            end
            goto nextSet
        end
        do
            -- make a copy of the current options for this setTag
            -- (also use this hash to store expression and wildcard flags, EXPR and WILD)
            local o = copyOpts(opts)
            tag = lc(t)    -- change tag/group names to all lower case
            local fg, grp, dst, dstGrp, dstTag, isExclude = { }
            -- handle redirection to another tag
            local m1, m2, m3, m4 = matches(tag, [[(.+?)\s*(>|<|=)(\s*)(.*)]])
            if m1 then
                dstGrp = ''
                local opt, op, spc
                if m2 == '>' then
                    tag, dstTag = m1, m4
                    -- flag add and delete (eg. '+<' and '-<') redirections
                    local c = matches(tag, [[\s*([-+])$]])
                    if c then
                        tag = subst(tag, [[\s*([-+])$]], '')
                        opt = c
                    else
                        c = matches(dstTag, [[^([-+])\s*]])
                        if c then
                            dstTag = subst(dstTag, [[^([-+])\s*]], '')
                            opt = c
                        end
                    end
                else
                    dstTag, op, spc, tag = m1, m2, m3, m4
                    local c = matches(dstTag, [[\s*([-+])$]])
                    if c then
                        dstTag = subst(dstTag, [[\s*([-+])$]], '')
                        opt = c
                    end
                    if op == '=' then
                        -- simple assignment ($tag will be the new value)
                        tag = spc .. tag
                        local caret = isMatch(dstTag, [[\^$]])
                        if caret then dstTag = subst(dstTag, [[\^$]], '') end
                        if not (caret or #tag > 0) then tag = nil end
                        assign = assign + 1
                        o.ASSIGN = assign
                    elseif isMatch(tag, [[\$]]) then    -- handle expressions
                        tag = t  -- restore original case
                        -- recover leading whitespace (except for initial single space)
                        tag = subst(tag, [[(.+?)\s*(>|<) ?]], '')
                        o.EXPR = 1 -- flag this expression
                    else
                        -- (not sure why this is here because sign should be before '<')
                        -- (--> allows "<+" or "<-", which is an undocumented feature)
                        c = matches(tag, [[^([-+])\s*]])
                        if c then
                            tag = subst(tag, [[^([-+])\s*]], '')
                            opt = c
                        end
                    end
                end
                if isMatch(dstTag, [[^\+]]) then
                    dstTag = subst(dstTag, [[^\+]], '')
                    o.Replace = 0
                end
                -- validate tag name(s)
                if not (o.EXPR or o.ASSIGN or ExifTool.ValidTagName(tag)) then
                    self:Warn("Invalid tag name '" .. perlStr(tag) .. "'. Use '=' not '<' to assign a tag value")
                    goto nextSet
                end
                if not ExifTool.ValidTagName(dstTag) then
                    self:Warn("Invalid tag name '" .. dstTag .. "'")
                    goto nextSet
                end
                -- translate '+' and '-' to appropriate SetNewValue option
                if opt then
                    o[({ ['+'] = 'AddValue', ['-'] = 'DelValue' })[opt]] = 1
                    o.Shift = 0  -- shift if shiftable
                end
                local g, d = matches(dstTag, '(.*):(.+)')
                if g then dstGrp, dstTag = g, d end
                -- ValueConv may be specified separately on the destination with '#'
                if isMatch(dstTag, '#$') then
                    dstTag = subst(dstTag, '#$', '')
                    o.Type = 'ValueConv'
                end
                -- replace tag name of 'all' with '*'
                if dstTag == 'all' then dstTag = '*' end
            else
                if isMatch(tag, [[^\+]]) then
                    tag = subst(tag, [[^\+]], '')
                    o.Replace = 0
                end
            end
            if not (o.EXPR or o.ASSIGN) then
                isExclude = isMatch(tag, '^-')
                if isExclude then tag = subst(tag, '^-', '') end
                local g, tg = matches(tag, '(.*):(.+)')
                if g then
                    grp, tag = g, tg
                    for _, part in ipairs(split(':', grp)) do
                        -- save family/groups in list (ignoring 'all' and '*')
                        if #part == 0 then goto nextGrp end
                        do
                            local f, gn = matches(part, [[^(\d+)?(.*)]])
                            if not (f or gn) then goto nextGrp end
                            if (not perlTruthy(f) or f == '7') and isMatch(gn, '(?i)^ID-') then
                                gn = subst(gn, '(?i)^ID-', '')
                                f = 7
                            end
                            if isMatch(gn, [[(?i)^file\d+$]]) and (not perlTruthy(f) or f == '8') then
                                f = 8
                                local g8 = ucfirst(gn)
                                if srcExifTool.ALT_EXIFTOOL[g8] then
                                    o.GROUP8 = g8
                                    if not altFiles[g8] then altFiles[g8] = { } end
                                    -- save list of requested tags for this alternate ExifTool object
                                    local list = altFiles[g8]
                                    list[#list + 1] = grp .. ':' .. tag
                                end
                            end
                            if not (gn == '*' or gn == 'all') then fg[#fg + 1] = { tonumber(f), gn } end
                        end
                        ::nextGrp::
                    end
                end
                -- allow ValueConv to be specified by a '#' on the tag name
                if isMatch(tag, '#$') then
                    tag = subst(tag, '#$', '')
                    o.SrcType = 'ValueConv'
                    if not dstTag then o.Type = 'ValueConv' end
                end
                -- replace 'all' with '*' in tag and group names
                if tag == 'all' then tag = '*' end
                -- allow wildcards in tag names (handle differently from all tags: '*')
                if isMatch(tag, '[?*]') and tag ~= '*' then
                    o.WILD = 1   -- set flag indicating wildcards were used in source tag
                    tag = subst(tag, [[\*]], [==[[-\\w]*]==], 'g')
                    tag = subst(tag, [[\?]], [==[[-\\w]]==], 'g')
                end
            end
            -- redirect, exclude or set this tag (Note: @fg is empty if we don't care about the group)
            if dstTag then
                -- redirect this tag
                if isExclude then return { Error = "Can't redirect excluded tag" } end
                -- set destination group the same as source if necessary
              -- (removed in 7.72 so '-*:*<xmp:*' will preserve XMP family 1 groups)
              -- $dstGrp = $grp if $dstGrp eq '*' and $grp;
                -- write to specified destination group/tag
                dst = { dstGrp, dstTag }
            elseif isExclude then
                -- implicitly assume '*' if first entry is an exclusion
                if #setList == 0 then table.insert(setList, 1, { { }, '*', { '', '*' }, o }) end
                -- exclude this tag by leaving $dst undefined
            else
                dst = { grp or '', o.WILD and '*' or tag } -- use same group name for dest
            end
            -- save in reverse order so we don't set tags before an exclude
            table.insert(setList, 1, { fg, tag, dst, o })
        end
        ::nextSet::
    end
    -- 1b) copy requested tags for each alternate ExifTool object
    local g8s = { }
    for g8 in pairs(altFiles) do g8s[#g8s + 1] = g8 end
    tsort(g8s)
    for _, g8 in ipairs(g8s) do
        -- request specific alternate tags to load them from the alternate ExifTool object
        local altInfo = srcExifTool:GetInfo(altFiles[g8])
        -- add to tags list after dummy entry to signify start of tags for this alt file
        if next(altInfo) then
            local altKeys = { }
            for k in pairs(altInfo) do altKeys[#altKeys + 1] = k end
            tsort(altKeys)
            tags[#tags + 1] = 'Warning DUMMY'
            for k = #altKeys, 1, -1 do tags[#tags + 1] = altKeys[k] end
            for _, k in ipairs(altKeys) do info[k] = altInfo[k] end
        end
    end
    -- 2) initialize lists of matching tags for each setTag
    for _, set in ipairs(setList) do
        if set[3] then setMatches[set] = { } end
    end
    -- no need to search source tags if doing only assignments
    if assign == #setList then tags = { } end
    -- 3) loop through all tags in source image and save tags matching each setTag
    local rtnInfo, isAlt = { }
    for _, t in ipairs(tags) do
        tag = t
        -- don't try to set errors or warnings
        if isMatch(tag, '^(Error|Warning)( |$)') then
            if tag == 'Warning DUMMY' then
                isAlt = 1 -- start of the alt tags
            else
                rtnInfo[tag] = info[tag]
            end
            goto nextTag
        end
        do
            -- only set specified tags
            local lcTag = lc(ExifTool.GetTagName(tag))
            local grpList, grpSet
            for _, set in ipairs(setList) do
                local o = set[4]
                if o.EXPR then goto nextSetMatch end   -- (expressions handled in step 4)
                if (o.GROUP8 and true or false) ~= (isAlt and true or false) then goto nextSetMatch end
                -- check first for matching tag
                if not (set[2] == lcTag or set[2] == '*') then
                    -- handle wildcards
                    if not (o.WILD and isMatchDyn(lcTag, '^' .. set[2] .. '$')) then goto nextSetMatch end
                end
                -- then check for matching group
                if #set[1] > 0 then
                    -- get lower case group names if not done already
                    if not grpList then
                        grpList, grpSet = { }, { }
                        for k, v in pairs(srcExifTool:GetGroup(tag)) do
                            grpList[k] = lc(v)
                            grpSet[grpList[k]] = 1
                        end
                    end
                    for _, fgPair in ipairs(set[1]) do
                        local f, g = fgPair[1], fgPair[2]
                        if f == nil then
                            if not grpSet[g] then goto nextSetMatch end
                        elseif f == 7 then
                            if not perlTruthy(ExifTool.IsSameID(srcExifTool:GetTagID(tag), g)) then goto nextSetMatch end
                        else
                            if not (grpList[f] ~= nil and g == grpList[f]) then goto nextSetMatch end
                        end
                    end
                end
                if not set[3] then break end    -- all done if we hit an exclude
                -- add to the list of tags matching this setTag
                do
                    local list = setMatches[set]
                    list[#list + 1] = tag
                end
                ::nextSetMatch::
            end
        end
        ::nextTag::
    end
    -- 4) loop through each setTag in original order, setting new tag values
    for i = #setList, 1, -1 do
        local set = setList[i]
        -- get options for SetNewValue
        local o = set[4]
        -- handle expressions
        if o.EXPR or o.ASSIGN then
            local val
            if o.EXPR then
                val = srcExifTool:InsertTagValues(set[2], tags, 'Error')
                local err = srcExifTool.VALUE.Error
                if err then
                    -- pass on any error as a warning unless it is suppressed
                    local noWarn = srcExifTool.OPTIONS.NoWarning
                    local suppressed = false
                    if noWarn then
                        local ok, res = pcall(isMatchDyn, err, noWarn)
                        if ok and res then
                            suppressed = true
                        -- (also apply expression to warning without "[minor] " prefix)
                        elseif isMatch(err, [[(?i)^\[minor\] ]]) then
                            err = subst(err, [[(?i)^\[minor\] ]], '')
                            ok, res = pcall(isMatchDyn, err, noWarn)
                            suppressed = ok and res and true or false
                        end
                    end
                    if not suppressed then
                        tag = Writer.NextFreeTagKey(rtnInfo, 'Warning')
                        rtnInfo[tag] = srcExifTool.VALUE.Error
                    end
                    srcExifTool.VALUE.Error = nil
                    if val == nil then goto nextSet4 end
                end
            else
                val = set[2]
            end
            do
                local dstGrp, dstTag = set[3][1], set[3][2]
                if not (isMatch(dstTag, '[?*]') and dstTag ~= '*') then o.Protected = 1 end
                if perlTruthy(dstGrp) then o.Group = dstGrp end
                local n, e = self:SetNewValue(dstTag, val, copyOpts(o))
                if perlTruthy(n) then rtnInfo[dstTag] = val end -- tag was set successfully
                -- return warning if any
                if e then rtnInfo[Writer.NextFreeTagKey(rtnInfo, 'Warning')] = e end
            end
            goto nextSet4
        end
        for _, t in ipairs(setMatches[set] or { }) do
            tag = t
            local val, noWarn
            if perlTruthy(o.SrcType) and o.SrcType ~= srcType then
                val = srcExifTool:GetValue(tag, o.SrcType)
            else
                val = info[tag]
            end
            local dstGrp, dstTag = set[3][1], set[3][2]
            if perlTruthy(dstGrp) then
                local dstGrps = split(':', dstGrp)
                -- destination group of '*' writes to same group as source tag
                -- (family 1 unless otherwise specified)
                for k, d in ipairs(dstGrps) do
                    local fam = matches(d, [[(?i)^(\d*)(all|\*)$]])
                    if fam then
                        dstGrps[k] = fam .. srcExifTool:GetGroup(tag, #fam > 0 and fam or 1)
                        noWarn = 1    -- don't warn on wildcard destinations
                    end
                end
                o.Group = join(':', dstGrps)
            else
                o.Group = nil
            end
            -- transfer maker note information if setting this tag
            if srcExifTool.TAG_INFO[tag] and srcExifTool.TAG_INFO[tag].MakerNotes then
                o.Fixup = srcExifTool.TAG_EXTRA[tag] and srcExifTool.TAG_EXTRA[tag].Fixup
                self.MAKER_NOTE_BYTE_ORDER = srcExifTool.MAKER_NOTE_BYTE_ORDER
            end
            if dstTag == '*' then
                dstTag = tag
                noWarn = 1
            end
            if set[2] == '*' or set[4].WILD then
                -- don't copy from protected binary tags when using wildcards
                local ti = srcExifTool.TAG_INFO[tag]
                if ti and perlTruthy(ti.Protected) and perlTruthy(ti.Binary) then goto nextMatch end
                -- don't copy to protected tags when using wildcards
                o.Protected = nil
                -- don't copy flattened tags if copying structures too when copying all
                o.NoFlat = (perlStr(structOpt) == '2') and 1 or 0
            else
                -- allow protected tags to be copied if specified explicitly
                if not isMatch(dstTag, '[?*]') then o.Protected = 1 end
                o.NoFlat = nil
            end
            do
                -- set value(s) for this tag
                local rtn, wrn = self:SetNewValue(dstTag, val, copyOpts(o))
                -- this was added in version 9.14, and allowed actions like "-subject<all" to
                -- write values of multiple tags into a list, but it had the side effect of
                -- duplicating items if there were multiple list tags with the same name
                -- (eg. -use mwg "-creator<creator"), so disable this as of ExifTool 9.36:
                -- $$opts{Replace} = 0;    # accumulate values from tags matching a single argument
                if wrn and not noWarn then
                    -- return this warning
                    rtnInfo[Writer.NextFreeTagKey(rtnInfo, 'Warning')] = wrn
                    noWarn = 1 -- luacheck: ignore 311
                end
                o.Fixup = nil
                if perlTruthy(rtn) then rtnInfo[tag] = val end  -- tag was set successfully
            end
            ::nextMatch::
        end
        ::nextSet4::
    end
    return rtnInfo   -- return information that we set
end

--------------------------------------------------------------------------------
-- Get new value(s) for tag
-- Inputs: 0) ExifTool object reference, 1) tag name (or tagInfo or nvHash ref, not public)
--         2) optional pointer to return new value hash reference (not part of public API)
-- Returns: List of new Raw values (list may be empty if tag is being deleted)
-- Notes: 1) Preferentially returns new value from Extra table if writable Extra tag exists
-- 2) Must call AFTER IsOverwriting() returns 1 to get proper value for shifted times
-- 3) Tag name is case sensitive and may be prefixed by family 0 or 1 group name
-- 4) Value may have been modified by CHECK_PROC routine after ValueConv
-- (Lua: the new value hash comes back as the second result instead of
--  through the pointer; `wantarray` true asks for upstream's list context, the
--  values then come back as an array, otherwise the first value alone)
function Writer.GetNewValue(self, tag, wantarray)
    local nvHash
    if (type(tag) == 'table' and tag.IsNVH) or tag == nil then
        nvHash = tag
    else
        if self.NEW_VALUE then
            local tagInfo
            if type(tag) == 'table' then
                nvHash = Writer.GetNewValueHash(self, tag)
            elseif ExifTool.Extra[tag] ~= nil and ExifTool.Extra[tag].Writable then
                tagInfo = ExifTool.Extra[tag]
                nvHash = Writer.GetNewValueHash(self, tagInfo)
            else
                -- separate group from tag name
                local groups = { }
                local g, t = matches(tag, [[(.*):(.*)]])
                if g then
                    groups = split(':', g)
                    tag = t
                end
                local tagInfoList = FindTagInfo(tag)
                -- decide which tag we want
                for _, ti in ipairs(tagInfoList) do  -- GNV_TagInfo:
                    tagInfo = ti
                    local nvh = Writer.GetNewValueHash(self, tagInfo)
                    if not nvh then goto nextTagInfo end
                    -- select tag in specified group(s) if necessary
                    for _, grp in ipairs(groups) do
                        if grp == nvh.WriteGroup then goto nextGroup end
                        do
                            local grps = self:GetGroup(tagInfo)
                            if grps[0] == nvh.WriteGroup then
                                -- check family 1 group only if WriteGroup is not specific
                                if grp == grps[1] then goto nextGroup end
                            else
                                -- otherwise check family 0 group
                                if grp == grps[0] then goto nextGroup end
                            end
                            -- also check family 7
                            local id = matches(grp, [[(?i)^ID-(.*)]])
                            if id and perlTruthy(ExifTool.IsSameID(tagInfo.TagID, id)) then goto nextGroup end
                            -- step to next entry in list
                            nvh = nvh.Next
                            if not nvh then goto nextTagInfo end
                        end
                        ::nextGroup::
                    end
                    nvHash = nvh
                    -- give priority to the one we are creating
                    if nvHash.IsCreating ~= nil then break end
                    ::nextTagInfo::
                end
            end
        end
        -- return new value hash if requested
    end
    if not (nvHash and nvHash.Value) then
        if wantarray then return { }, nvHash end  -- return empty list
        return nil, nvHash
    end
    local vals = nvHash.Value
    -- do inverse raw conversion if necessary
    -- - must also check after doing a Shift
    if nvHash.TagInfo.RawConvInv or nvHash.Shift ~= nil then
        local copyVals = { table.unpack(vals) }  -- modify a copy of the values
        vals = copyVals
        local tagInfo = nvHash.TagInfo
        local conv = tagInfo.RawConvInv
        local tbl = tagInfo.Table
        local checkProc
        if nvHash.Shift ~= nil and tbl then checkProc = tbl.CHECK_PROC end
        local oldWarn = perl.SIG.__WARN__
        perl.SIG.__WARN__ = ExifTool.SetWarning
        ExifTool.evalWarning = nil
        for i = 1, #vals do
            local val = vals[i]
            -- must check value now if it was shifted
            if checkProc then
                local err, newVal = checkProc(self, tagInfo, val)
                if newVal ~= nil then val = newVal end
                if perlTruthy(err) or val == nil then
                    if not perlTruthy(err) then err = 'Error generating raw value' end
                    self:Warn(err .. ' for ' .. tagInfo.Name)
                    vals = { }
                    break
                end
                vals[i] = val
                if not conv then goto nextVal end
            else
                if not conv then break end
            end
            do
                -- do inverse raw conversion
                --### eval RawConvInv ($self, $val, $tagInfo)
                -- (Lua: RawConvInv functions take ($self, $val, $tagInfo); an
                --  error raised is the eval's $@)
                local ok, res = pcall(conv, self, val, tagInfo)
                if ok then
                    val = res
                else
                    ExifTool.evalWarning = perl.isDie(res) and res.msg or tostring(res)
                end
                if perlTruthy(ExifTool.evalWarning) then
                    -- an empty warning ("\n") ignores tag with no error
                    if ExifTool.evalWarning ~= "\n" then
                        local err = ExifTool.CleanWarning() .. ' in ' .. tagInfo.Name .. ' (RawConvInv)'
                        self:Warn(err)
                    end
                    vals = { }
                    break
                end
                vals[i] = val
            end
            ::nextVal::
        end
        perl.SIG.__WARN__ = oldWarn
    end
    -- return our value(s)
    if wantarray then
        -- remove duplicates if requested
        if #vals > 1 and perlTruthy(self:Options('NoDups')) then
            local seen, out = { }, { }
            for _, v in ipairs(vals) do
                if not seen[v] then out[#out + 1] = v end
                seen[v] = true
            end
            vals = out
        else
            vals = { table.unpack(vals) }   -- (a list, not the Value array itself)
        end
        return vals, nvHash
    end
    return vals[1], nvHash
end

--------------------------------------------------------------------------------
-- Count the number of new values set (upstream Writer.pl CountNewValues)
-- Inputs: 0) ExifTool ref
-- Returns: 0) number of new values, 1) number of pseudo (WritePseudo) tags
--          among them -- the CLI compares the two to decide whether the file
--          has to be rewritten at all
--------------------------------------------------------------------------------
function Writer.CountNewValues(self)
    local newVal = self.NEW_VALUE
    local num, pseudo = 0, 0
    if newVal then
        for _, nv in pairs(newVal) do
            num = num + 1
            local tagInfo = nv.TagInfo
            -- don't count tags that don't write anything
            if tagInfo and tagInfo.WriteNothing then
                num = num - 1
            -- count the number of pseudo tags included
            elseif tagInfo and tagInfo.WritePseudo then
                pseudo = pseudo + 1
            end
        end
    end
    for _ in pairs(self.DEL_GROUP or {}) do num = num + 1 end
    return num, pseudo
end

--------------------------------------------------------------------------------
-- Save new values for subsequent restore
-- Inputs: 0) ExifTool object reference
-- Returns: Number of times new values have been saved
-- Notes: increments SAVE_COUNT flag each time routine is called
function Writer.SaveNewValues(self)
    local newValues = self.NEW_VALUE
    self.SAVE_COUNT = (self.SAVE_COUNT or 0) + 1
    local saveCount = self.SAVE_COUNT
    for _, key in ipairs(perl.keys(newValues or { })) do
        local nvHash = newValues[key]
        while nvHash do
            -- set Save count if not done already
            if not perlTruthy(nvHash.Save) then nvHash.Save = saveCount end
            nvHash = nvHash.Next
        end
    end
    -- initialize hash for saving overwritten new values
    self.SAVE_NEW_VALUE = { }
    -- make a copy of the delete group hash
    local delGrp = { }
    for k, v in pairs(self.DEL_GROUP or { }) do delGrp[k] = v end
    self.SAVE_DEL_GROUP = delGrp
    return saveCount
end

--------------------------------------------------------------------------------
-- Restore new values to last saved state
-- Inputs: 0) ExifTool object reference
-- Notes: Restores saved new values, but currently doesn't restore them in the
-- original order, so there may be some minor side-effects when restoring tags
-- with overlapping groups. eg) XMP:Identifier, XMP-dc:Identifier
-- Also, this doesn't do the right thing for list-type tags which accumulate
-- values across a save point
function Writer.RestoreNewValues(self)
    local newValues = self.NEW_VALUE
    local savedValues = self.SAVE_NEW_VALUE
    -- 1) remove any new values which don't have the Save flag set
    if newValues then
        local keys = perl.keys(newValues)
        for _, key in ipairs(keys) do
            local lastHash
            local nvHash = newValues[key]
            while nvHash do
                if perlTruthy(nvHash.Save) then
                    lastHash = nvHash
                else
                    -- remove this entry from the list
                    if lastHash then
                        lastHash.Next = nvHash.Next
                    elseif nvHash.Next then
                        newValues[key] = nvHash.Next
                    else
                        newValues[key] = nil
                    end
                end
                nvHash = nvHash.Next
            end
        end
    end
    -- 2) restore saved new values
    if savedValues then
        if not newValues then
            newValues = { }
            self.NEW_VALUE = newValues
        end
        for _, key in ipairs(perl.keys(savedValues)) do
            if newValues[key] then
                -- add saved values to end of list
                local nvHash = LastInList(newValues[key])
                nvHash.Next = savedValues[key]
            else
                newValues[key] = savedValues[key]
            end
        end
        self.SAVE_NEW_VALUE = { }  -- reset saved new values
    end
    -- 3) restore delete groups
    local delGrp = { }
    for k, v in pairs(self.SAVE_DEL_GROUP or { }) do delGrp[k] = v end
    self.DEL_GROUP = delGrp
end

--------------------------------------------------------------------------------
-- Set alternate file for extracting information
-- Inputs: 0) ExifTool ref, 1) family 8 group name (of the form "File#" where # is any number)
--         2) alternate file name (may contain tag names with leading "$"), or undef to reset
-- Returns: 1 on success, or 0 on invalid group name
--------------------------------------------------------------------------------
function Writer.SetAlternateFile(self, g8, file)
    g8 = ucfirst(lc(g8))
    if not g8:match('^File%d+$') then return 0 end
    -- keep the same file if already initialized (possibly has metadata extracted)
    if file == nil then
        self.ALT_EXIFTOOL[g8] = nil
    elseif not (self.ALT_EXIFTOOL[g8] and not file:find('%$') and
        self.ALT_EXIFTOOL[g8].ALT_FILE == file)
    then
        local altExifTool = ExifTool.new()
        altExifTool.ALT_FILE = file
        self.ALT_EXIFTOOL[g8] = altExifTool
    end
    return 1
end

--------------------------------------------------------------------------------
-- Set filesystem time from the FileModifyDate tag (upstream Writer.pl
-- SetFileModifyDate)
-- Inputs: 0) ExifTool ref, 1) file name, 2) time of the original file (used
--            for a shift; taken from the file if not given), 3) tag name to
--            write (nil for 'FileModifyDate'), 4) flag set if input 2 has
--            already been converted to Unix seconds
-- Returns: 1=time changed OK, 0=nothing done, -1=error setting time
--          (increments CHANGED and sets the corresponding WRITTEN tag)
--------------------------------------------------------------------------------
function Writer.SetFileModifyDate(self, file, originalTime, tag, isUnixTime)
    tag = tag or 'FileModifyDate'
    local val, nvHash = Writer.GetNewValue(self, tag)
    if val == nil then return 0 end
    local isOverwriting = Writer.IsOverwriting(self, nvHash)
    if isOverwriting == 0 then return 0 end
    -- can currently only set creation date on Windows systems
    -- (and Mac now too, but that is handled with the MacOS tags)
    if tag == 'FileCreateDate' and perl.osname() ~= 'MSWin32' then return 0 end
    if isOverwriting < 0 then -- are we shifting time?
        -- use original time of this file if not specified
        if originalTime == nil then
            local _, mTime, cTime = self:GetFileTime(file)
            if tag == 'FileCreateDate' then originalTime = cTime else originalTime = mTime end
            if originalTime == nil then return 0 end
            isUnixTime = 1
        end
        -- (upstream converts Perl's -M form -- days before the script start
        -- time -- here; nothing in this port ever passes that form)
        if not isUnixTime then return 0 end
        if Writer.IsOverwriting(self, nvHash, originalTime) == 0 then return 0 end
        val = nvHash.Value[1] -- get shifted value (already in stored form)
    end
    local aTime, mTime, cTime
    if tag == 'FileCreateDate' then
        -- (Win32::API and Win32API::File are lexiftool.sys here, always present)
        cTime = val
    else
        aTime, mTime = val, val
    end
    if not perlTruthy(Writer.SetFileTime(self, file, aTime, mTime, cTime, 1)) then
        self:Warn('Error setting ' .. tag)
        return -1
    end
    self.CHANGED = (self.CHANGED or 0) + 1
    self.WRITTEN = self.WRITTEN or {}
    self.WRITTEN[tag] = val -- remember that we wrote this tag
    Writer.VerboseValue(self, '+ ' .. tag, val)
    return 1
end

--------------------------------------------------------------------------------
-- Change file name and/or directory from FileName and Directory tags
-- Inputs: 0) ExifTool object reference, 1) current file name (including path)
--         2) new name (or undef to build from FileName and Directory tags)
--         3) option: 'HardLink'/'SymLink' to create hard/symbolic link instead of renaming
--                    'Test' to only print new file name
--         4) 0 to indicate that a file will no longer exist (used for 'Test' only)
-- Returns: 1=name changed OK, 0=nothing changed, -1=error changing name
--          (and increments CHANGED flag if filename changed)
-- Notes: Will not overwrite existing file.  Creates directories as necessary.
function Writer.SetFileName(self, file, newName, opt, usedFlag)
    local nvHash, doName, doDir

    if not perlTruthy(opt) then opt = '' end
    -- determine the new file name
    if newName == nil then
        if opt ~= '' then
            if opt == 'HardLink' or opt == 'Link' then
                newName = self:GetNewValue('HardLink')
            elseif opt == 'SymLink' then
                newName = self:GetNewValue('SymLink')
            elseif opt == 'Test' then
                newName = self:GetNewValue('TestName')
            end
            if newName == nil then return 0 end
        else
            local filename, dir
            filename, nvHash = Writer.GetNewValue(self, 'FileName')
            if filename ~= nil and perlTruthy(Writer.IsOverwriting(self, nvHash, file)) then doName = 1 end
            dir, nvHash = Writer.GetNewValue(self, 'Directory')
            if dir ~= nil and perlTruthy(Writer.IsOverwriting(self, nvHash, file)) then doDir = 1 end
            if not (doName or doDir) then return 0 end  -- nothing to do
            if doName then
                newName = Writer.GetNewFileName(file, filename)
                if doDir then newName = Writer.GetNewFileName(newName, dir) end
            else
                newName = Writer.GetNewFileName(file, dir)
            end
        end
    end
    -- validate new file name in Windows
    if perl.osname() == 'MSWin32' then
        if isMatch(newName, [=[[\0-\x1f<>"|*]]=]) then
            self:Warn('New file name not allowed in Windows (contains reserved characters)')
            return -1
        end
        if isMatch(newName, ':') and not isMatch(newName, '(?i)^[A-Z]:[^:]*$') then
            self:Warn("New file name not allowed in Windows (contains ':')")
            return -1
        end
        if isMatch(newName, [[\?]]) and not isMatch(newName, [[^[\\/]{2}\?[\\/][^?]*$]]) then
            self:Warn("New file name not allowed in Windows (contains '?')")
            return -1
        end
        if isMatch(newName, [[(?i)(^|[\\/])(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.[^.]*)?$]]) then
            self:Warn('New file name not allowed in Windows (reserved device name)')
            return -1
        end
        local found, c1 = isMatch(newName, '([. ])$')
        if found then
            if perlTruthy(self:Warn("New file name not recommended for Windows (ends with '" .. c1 .. "')", 2)) then return -1 end
        end
        if perl.length(newName) > 259 and not isMatch(newName, [[\?]]) then
            if perlTruthy(self:Warn('New file name not recommended for Windows (exceeds 260 chars)', 2)) then return -1 end
        end
    else
        newName = perl.tr(newName, [[\0]], '', 'd')   -- make sure name doesn't contain nulls
    end
    -- protect against empty file name
    if perl.length(newName) == 0 then self:Warn('New file name is empty') return -1 end
    -- don't replace existing file
    if self:Exists(newName, 1) and (usedFlag == nil or perlTruthy(usedFlag)) then
        if file ~= newName or isMatch(opt, 'Link$') then
            -- allow for case-insensitive filesystem
            if isMatch(opt, 'Link$') or not perlTruthy(Writer.IsSameFile(self, file, newName)) then
                self:Warn("File '" .. newName .. "' already exists")
                return -1
            end
        else
            self:Warn('File name is unchanged')
            return 0
        end
    end
    if opt == 'Test' then
        local out = self.OPTIONS.TextOut or io.stdout
        out:write("'" .. file .. "' --> '" .. newName .. "'\n")
        return 1
    end
    -- create directory for new file if necessary
    local err = self:CreateDirectory(newName)
    if err ~= nil then
        if perlTruthy(err) then
            if not isMatch(err, '^Error creating') then self:Warn(err) end
            self:Warn("Error creating directory for '" .. newName .. "'")
            return -1
        end
        self:VPrint(0, "Created directory for '" .. newName .. "'\n")
    end
    if opt == 'HardLink' or opt == 'Link' then
        if not perl.link(file, newName) then
            self:Warn("Error creating hard link '" .. newName .. "'")
            return -1
        end
        self.CHANGED = (self.CHANGED or 0) + 1
        Writer.VerboseValue(self, '+ HardLink', newName)
        return 1
    elseif opt == 'SymLink' then
        newName = subst(newName, [[^\./]], '')  -- remove leading "./" from link name if it exists
        -- path to linked file must be relative to the $newName directory, but $file
        -- is relative to the current directory, so convert it to an absolute path
        -- if using a relative directory and $newName isn't in the current directory
        if not isMatch(file, '^/') and isMatch(newName, '/') then
            file = perl.abs_path(file)
            if file == nil then
                self:Warn('Error in Cwd::abs_path when creating symlink')
                return -1
            end
        end
        if not perl.symlink(file, newName) then
            self:Warn("Error creating symbolic link '" .. newName .. "'")
            return -1
        end
        self.CHANGED = (self.CHANGED or 0) + 1
        Writer.VerboseValue(self, '+ SymLink', newName)
        return 1
    end
    -- attempt to rename the file
    if not Writer.Rename(self, file, newName) then
        -- renaming didn't work, so copy the file instead
        local fin = self:Open(file)
        if not fin then
            self:Error("Error opening '" .. file .. "'")
            return -1
        end
        local fout = self:Open(newName, '>')
        if not fout then
            fin:close()
            self:Error("Error creating '" .. newName .. "'")
            return -1
        end
        perl.binmode(fin)
        perl.binmode(fout)
        err = nil
        while true do
            local buff = fin:read(65536)
            if not buff or #buff == 0 then break end
            if not fout:write(buff) then err = 1 end
        end
        if not fout:close() then err = 1 end
        fin:close()
        if err then
            Writer.Unlink(self, newName)    -- erase bad output file
            self:Error("Error writing '" .. newName .. "'")
            return -1
        end
        -- preserve modification time
        local aTime, mTime, cTime = self:GetFileTime(file)
        Writer.SetFileTime(self, newName, aTime, mTime, cTime)
        -- remove the original file
        if Writer.Unlink(self, file) == 0 then self:Warn('Error removing old file') end
    end
    self.NewName = newName -- remember new file name
    self.CHANGED = (self.CHANGED or 0) + 1
    Writer.VerboseValue(self, '+ FileName', newName)
    return 1
end

--------------------------------------------------------------------------------
-- Set file permissions, group/user id and various MDItem tags from new tag values
-- Inputs: 0) ExifTool ref, 1) file name or glob (must be a name for MDItem tags)
-- Returns: 1=something was set OK, 0=didn't try, -1=error (and warning set)
-- Notes: There may be errors even if 1 is returned
function Writer.SetSystemTags(self, file)
    local result = 0

    local perm = Writer.GetNewValue(self, 'FilePermissions')
    if perm ~= nil then
        if perl.chmod(perl.num(perm) & 4095, file) > 0 then  -- (07777)
            self:VerboseValue('+ FilePermissions', perm)
            result = 1
        else
            self:Warn('Error setting FilePermissions')
            result = -1
        end
    end
    local uid = Writer.GetNewValue(self, 'FileUserID')
    local gid = Writer.GetNewValue(self, 'FileGroupID')
    if uid ~= nil or gid ~= nil then
        if uid == nil then uid = -1 end
        if gid == nil then gid = -1 end
        if perl.chown(perl.num(uid), perl.num(gid), file) > 0 then
            if perl.num(uid) >= 0 then self:VerboseValue('+ FileUserID', uid) end
            if perl.num(gid) >= 0 then self:VerboseValue('+ FileGroupID', gid) end
            result = 1
        else
            self:Warn('Error setting FileGroup/UserID')
            if result == 0 then result = -1 end
        end
    end
    for _, tag in ipairs(writableMacOSTags) do
        local _, tagHash = self:GetNewValue(tag)
        if not tagHash then goto nextTag end
        -- (upstream's `$^O eq 'darwin'` branch calls MacOS::SetMacOSTags, which
        --  this port has no counterpart for -- it runs on Unix and Windows-less
        --  systems only, so the non-darwin branch is the one taken)
        if tag ~= 'FileCreateDate' then
            self:Warn('Can only set MDItem tags on MacOS')
            break
        end
        ::nextTag::
    end
    -- delete Windows Zone.Identifier if specified
    local zhash = ExifTool.Extra.ZoneIdentifier and Writer.GetNewValueHash(self, ExifTool.Extra.ZoneIdentifier)
    if zhash then
        local res = -1
        if perl.osname() ~= 'MSWin32' then
            self:Warn('ZoneIdentifer is a Windows-only tag')
        elseif type(file) ~= 'string' then
            self:Warn('Writing ZoneIdentifer requires a file name')
        elseif Writer.GetNewValue(self, zhash) ~= nil then
            self:Warn('ZoneIndentifier may only be deleted')
        else
            -- (Win32API::File is lexiftool.sys here, always present;
            --  FILE_ATTRIBUTE_READONLY from winnt.h)
            local FILE_ATTRIBUTE_READONLY = 0x01
            local wattr, wide
            local zfile = file .. ':Zone.Identifier'
            wide, zfile = self:EncodeFileName(zfile)
            if perlTruthy(wide) then
                wide = 1
                wattr = sys.get_file_attributes(zfile)
            else
                -- (port: GetFileAttributes is the same lexiftool.sys call)
                wattr = sys.get_file_attributes(zfile)
            end
            if wattr == nil then    -- (INVALID_FILE_ATTRIBUTES)
                res = 0 -- file doesn't exist, nothing to do
            elseif (wattr & FILE_ATTRIBUTE_READONLY) ~= 0 then
                self:Warn('Zone.Identifier stream is read-only')
            else
                if wide == 1 then
                    if sys.unlink(zfile) then res = 1 end   -- (DeleteFileW)
                else
                    if perl.unlink(zfile) > 0 then res = 1 end  -- (port: DeleteFile)
                end
                if res > 0 then
                    self:VPrint(0, "  Deleting Zone.Identifier stream\n")
                else
                    self:Warn('Error deleting Zone.Identifier stream')
                end
            end
        end
        if res == 1 or result == 0 then result = res end
    end
    return result
end

--------------------------------------------------------------------------------
-- Write information back to file
-- Inputs: 0) ExifTool object reference,
--         1) input filename, file ref, RAF ref, or scalar ref (or '' or undef to create from scratch)
--         2) output filename, file ref, or scalar ref (or undef to overwrite)
--         3) optional output file type (required only if input file is not specified
--            and output file is a reference)
-- Returns: 1=file written OK, 2=file written but no changes made, 0=file write error
-- (a file ref is an io file, a RAF ref a RandomAccess object, and a scalar
--  ref the port's box { value = ... }; Perl's UTF-8 flag on scalar input,
--  and the Mac OS resource fork copy have no counterpart; truncate() is
--  perl.truncate, over lexiftool.sys.ftruncate)
function Writer.WriteInfo(self, infile, outfile, outType)
    local fileTypeList, fileType, tiffType, hdr, seekErr, type_, tmpfile = { }, nil, nil, nil, nil, nil, nil
    local inRef, outRef, closeIn, closeOut, outPos, outBuff, eraseIn, raf, fileExt
    local hardLink, symLink, testName
    local oldRaf = self.RAF
    local rtnVal = 0
    -- (Perl's `ref` tests on the file arguments)
    local function isGlob(f) return io.type(f) == 'file' end
    local function isRAF(f) return type(f) == 'table' and getmetatable(f) == RandomAccess end

    -- initialize member variables
    self:Init()
    self.IsWriting = 1

    -- first, save original file modify date if necessary
    -- (do this now in case we are modifying file in place and shifting date)
    local nvHash, nvHash2, originalTime, createTime
    local val
    val, nvHash = self:GetNewValue('FileModifyDate')
    local setModDate = val ~= nil
    val, nvHash2 = self:GetNewValue('FileCreateDate')
    local setCreateDate = val ~= nil
    local aTime, mTime, cTime -- luacheck: ignore 211 231
    if setModDate and Writer.IsOverwriting(self, nvHash) < 0 and
        infile ~= nil and (type(infile) ~= 'table' or isRAF(infile))
    then
        aTime, mTime, cTime = self:GetFileTime(infile)
        originalTime = mTime
    end
    if setCreateDate and Writer.IsOverwriting(self, nvHash2) < 0 and
        infile ~= nil and (type(infile) ~= 'table' or isRAF(infile))
    then
        if cTime == nil then aTime, mTime, cTime = self:GetFileTime(infile) end -- luacheck: ignore 311
        createTime = cTime
    end
--
-- do quick in-place change of file dir/name or date if that is all we are doing
--
    local numNew, numPseudo = self:CountNewValues()
    if outfile == nil and infile ~= nil then
        hardLink = self:GetNewValue('HardLink')
        symLink = self:GetNewValue('SymLink')
        testName = self:GetNewValue('TestName')
        if hardLink ~= nil and perl.length(hardLink) == 0 then hardLink = nil end
        if symLink ~= nil and perl.length(symLink) == 0 then symLink = nil end
        if testName ~= nil and perl.length(testName) == 0 then testName = nil end
        local newFileName
        newFileName, nvHash = self:GetNewValue('FileName')
        local newDir = self:GetNewValue('Directory')
        if newDir ~= nil and perl.length(newDir) > 0 then
            if not isMatch(newDir, '/$') then newDir = newDir .. '/' end
        else
            newDir = nil
        end
        if numNew == numPseudo then
            rtnVal = 2
            if (newFileName ~= nil or newDir ~= nil) and type(infile) == 'string' then
                local result = Writer.SetFileName(self, infile)
                if result > 0 then
                    infile = self.NewName  -- file name changed
                    rtnVal = 1
                elseif result < 0 then
                    return 0   -- don't try to do anything else
                end
            end
            if type(infile) == 'string' or isGlob(infile) then
                if setModDate and Writer.SetFileModifyDate(self, infile) > 0 then rtnVal = 1 end
                if setCreateDate and Writer.SetFileModifyDate(self, infile, nil, 'FileCreateDate') > 0 then rtnVal = 1 end
                if Writer.SetSystemTags(self, infile) > 0 then rtnVal = 1 end
            end
            if hardLink ~= nil or symLink ~= nil or testName ~= nil then
                if perlTruthy(hardLink) and perlTruthy(Writer.SetFileName(self, infile, hardLink, 'HardLink')) then rtnVal = 1 end
                if perlTruthy(symLink) and perlTruthy(Writer.SetFileName(self, infile, symLink, 'SymLink')) then rtnVal = 1 end
                if perlTruthy(testName) and perlTruthy(Writer.SetFileName(self, infile, testName, 'Test')) then rtnVal = 1 end
            end
            return rtnVal
        elseif newFileName ~= nil and perl.length(newFileName) > 0 then
            -- can't simply rename file, so just set the output name if new FileName
            -- --> in this case, must erase original copy
            if type(infile) ~= 'string' then
                outfile = newFileName
                -- can't delete original
            elseif perlTruthy(Writer.IsOverwriting(self, nvHash, infile)) then
                outfile = Writer.GetNewFileName(infile, newFileName)
                eraseIn = 1 -- delete original
            end
        end
        -- set new directory if specified
        if newDir ~= nil then
            if not (outfile ~= nil or type(infile) ~= 'string') then outfile = infile end
            if outfile ~= nil then
                outfile = Writer.GetNewFileName(outfile, newDir)
                if type(infile) == 'string' then eraseIn = 1 end
            end
        end
    end
--
-- set up input file
--
    if type(infile) ~= 'string' and infile ~= nil then
        inRef = infile
        if isGlob(inRef) then
            inRef:seek('set', 0) -- make sure we are at the start of the file
        elseif isRAF(inRef) then
            inRef:Seek(0)
            raf = inRef
        end
        -- (Perl's conversion of a UTF-8 flagged scalar to a byte stream has
        --  no counterpart: Lua strings are bytes)
    elseif infile ~= nil and infile ~= '' then
        -- write to a temporary file if no output file given
        if outfile == nil then
            tmpfile = infile .. '_exiftool_tmp'
            outfile = tmpfile
        end
        local fh = self:Open(infile)
        if fh then
            fileExt = ExifTool.GetFileExtension(infile)
            fileType = ExifTool.GetFileType(infile)
            fileTypeList = ExifTool.GetFileTypeList(infile)
            tiffType = ExifTool.GetFileExtension(infile)
            self.FILE_EXT = tiffType
            self:VPrint(0, 'Rewriting ' .. infile .. "...\n")
            inRef = fh
            closeIn = 1   -- we must close the file since we opened it
        else
            self:Error('Error opening file')
            return 0
        end
    elseif outfile == nil then
        self:Error("WriteInfo(): Must specify infile or outfile\n")
        return 0
    else
        -- create file from scratch
        if not (perlTruthy(outType) or type(outfile) ~= 'string') then outType = ExifTool.GetFileExtension(outfile) end
        if perlTruthy(ExifTool.CanCreate(outType)) then
            if isMatch(self.OPTIONS.WriteMode or 'wcg', '(?i)g') then
                fileType = outType     -- use output file type if no input file
                tiffType = outType
                infile = fileType .. ' file'         -- make bogus file name
                self:VPrint(0, 'Creating ' .. infile .. "...\n")
                inRef = { value = '' }      -- set $inRef to reference to empty data
            else
                self:Error('Not creating new ' .. outType .. ' file (disallowed by WriteMode)')
                return 0
            end
        elseif perlTruthy(outType) then
            self:Error("Can't create " .. outType .. ' files')
            return 0
        else
            self:Error("Can't create file (unknown type)")
            return 0
        end
    end
    if #fileTypeList == 0 then
        if perlTruthy(fileType) then
            fileTypeList = { fileType }
        else
            for i, t in ipairs(ExifTool.fileTypes) do fileTypeList[i] = t end
            tiffType = 'TIFF'
        end
    end
--
-- set up output file
--
    if type(outfile) ~= 'string' and outfile ~= nil then
        outRef = outfile
        if isGlob(outRef) then
            perl.binmode(outRef)
            outPos = Writer.Tell(outRef)
        else
            -- initialize our output buffer if necessary
            -- (the scalar is a carray, doc/api.md §4; a string the caller
            --  put into the box becomes one with the same bytes)
            outRef.value = carray.new('char'):append(outRef.value or '')
            outPos = perl.length(outRef.value)
        end
    elseif outfile == nil then
        -- editing in place, so write to memory first
        -- (only when infile is a file ref or scalar ref)
        if raf then
            self:Error("Can't edit File::RandomAccess object in place")
            return 0
        end
        outBuff = { value = carray.new('char') }
        outRef = outBuff
        outPos = 0
    elseif self:Exists(outfile, 1) then
        self:Error('File already exists: ' .. outfile)
    else
        local fh = self:Open(outfile, '>')
        if fh then
            outRef = fh
            closeOut = 1  -- we must close $outRef
            perl.binmode(outRef)
            outPos = 0
        else
            local tmp = tmpfile and ' temporary' or ''
            self:Error('Error creating' .. tmp .. ' file: ' .. outfile)
        end
    end
--
-- write the file
--
    while not self.VALUE.Error do -- luacheck: ignore 512
        -- create random access file object (disable seek test in case of straight copy)
        if not raf then
            raf = RandomAccess.new(type(inRef) == 'table' and inRef.value or inRef, 1)
        end
        raf:BinMode()
        if numNew == numPseudo then
            rtnVal = 1
            -- just do a straight copy of the file (no "real" tags are being changed)
            while true do
                local n, buff = raf:Read(65536)
                if not perlTruthy(n) then break end
                if not Writer.Write(outRef, buff) then rtnVal = -1 break end
            end
            break
        elseif type(infile) == 'string' and (infile == '-' or isMatch(infile, [[\|$]])) then
            -- patch for Windows command shell pipe
            raf.TESTED = -1 -- force buffering
        else
            raf:SeekTest()
        end
       -- $raf->Debug() and warn "  RAF debugging enabled!\n";
        local inPos = raf:Tell()
        self.RAF = raf
        local dirInfo = {
            RAF = raf,
            OutFile = outRef,
        }
        local n
        n, hdr = raf:Read(1024)
        if not perlTruthy(n) then hdr = '' end
        if not raf:Seek(inPos, 0) then seekErr = 1 end
        local wrongType
        while not seekErr do
            type_ = remove(fileTypeList, 1)
            -- do quick test to see if this is the right file type
            if ExifTool.magicNumber[type_] and perl.length(hdr) > 0 and
                not isMatchDyn(hdr, '(?s)^' .. ExifTool.magicNumber[type_])
            then
                if #fileTypeList > 0 then goto nextType end
                wrongType = 1
                break
            end
            -- save file type in member variable
            self.FILE_TYPE = type_
            self.PATH[1] = type_
            dirInfo.Parent = type_
            -- determine which directories we must write for this file type
            Writer.InitWriteDirs(self, type_)
            if type_ == 'JPEG' or type_ == 'EXV' then
                rtnVal = Writer.WriteJPEG(self, dirInfo)
            elseif type_ == 'TIFF' then
                -- disallow writing of some TIFF-based RAW images:
                local noWrite
                for _, t in ipairs(ExifTool.noWriteFile.TIFF) do
                    if t == tiffType then noWrite = true end
                end
                if noWrite then
                    fileType = tiffType
                    rtnVal = nil
                else
                    if tiffType == 'FFF' then
                        -- (see https://exiftool.org/forum/index.php?topic=10848.0)
                        self:Error('Phocus may not properly update previews of edited FFF images', 1)
                    end
                    dirInfo.Parent = tiffType
                    rtnVal = self:ProcessTIFF(dirInfo)
                end
            elseif writableType[type_] ~= nil then
                local module, func
                if type(writableType[type_]) == 'table' then
                    module = writableType[type_][1] or type_
                    func = writableType[type_][2]
                else
                    module = writableType[type_] or type_
                end
                local mod = require('lexiftool.' .. module)
                func = func or ('Process' .. type_)
                if type(mod[func]) ~= 'function' then
                    error('Undefined subroutine lexiftool.' .. module .. '.' .. func)
                end
                rtnVal = mod[func](self, dirInfo)
            elseif type_ == 'ORF' or type_ == 'RAW' then
                rtnVal = self:ProcessTIFF(dirInfo)
            elseif type_ == 'EXIF' then
                -- go through WriteDirectory so block writes, etc are handled
                local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Exif.Main')
                local buff = Writer.WriteDirectory(self, dirInfo, tagTablePtr, Writer.WriteTIFF)
                if buff ~= nil then
                    rtnVal = Writer.Write(outRef, buff) and 1 or -1
                else
                    rtnVal = 0
                end
            else
                rtnVal = nil  -- flag that we don't write this type of file
            end
            -- all done unless we got the wrong type
            if perlTruthy(rtnVal) then break end
            if #fileTypeList == 0 then break end
            -- seek back to original position in files for next try
            if not raf:Seek(inPos, 0) then seekErr = 1 break end
            if isGlob(outRef) then
                outRef:seek('set', outPos)   -- (upstream: seek($outRef, 0, $outPos))
            else
                outRef.value = carray.new('char'):append(substr(outRef.value, 0, outPos))
            end
            ::nextType::
        end
        -- print file format errors
        if not perlTruthy(rtnVal) then
            local err
            if seekErr then
                err = 'Error seeking in file'
            elseif perlTruthy(fileType) and rtnVal ~= nil then
                if self.VALUE.Error then -- luacheck: ignore 542
                    -- existing error message will do
                elseif fileType == 'RAW' then
                    err = 'Writing this type of RAW file is not supported'
                else
                    if wrongType then
                        local t = fileExt or (fileType == 'TIFF' and tiffType or fileType)
                        err = 'Not a valid ' .. t
                        -- do a quick check to see what this file looks like
                        for _, t2 in ipairs(ExifTool.fileTypes) do
                            if ExifTool.magicNumber[t2] and isMatchDyn(hdr, '(?s)^' .. ExifTool.magicNumber[t2]) then
                                err = err .. ' (looks more like a ' .. t2 .. ')'
                                break
                            end
                        end
                    else
                        err = 'Format error in file'
                    end
                end
            elseif perlTruthy(fileType) then
                -- get specific type of file from extension
                if perlTruthy(infile) and ExifTool.GetFileType(infile) then fileType = ExifTool.GetFileExtension(infile) end
                err = 'Writing of ' .. fileType .. ' files is not yet supported'
            else
                err = 'Writing of this type of file is not supported'
            end
            if err then self:Error(err) end
            rtnVal = 0    -- (in case it was undef)
        end
       -- $raf->Close();  # only used to force debug output
        break   -- (didn't really want to loop)
    end
    -- don't return success code if any error occurred
    if rtnVal > 0 then
        if perlTruthy(outType) and type_ and outType ~= type_ then
            local found
            for _, t in ipairs(ExifTool.GetFileTypeList(outType)) do
                if t == type_ then found = true end
            end
            if not found then
                self:Error("Can't create " .. outType .. ' file from ' .. type_)
                rtnVal = 0
            end
        end
        if rtnVal > 0 and not perlTruthy(Writer.Tell(outRef)) and not self.VALUE.Error then
            -- don't write a file with zero length
            if hdr ~= nil and perl.length(hdr) > 0 then
                if type_ == nil then type_ = '<unk>' end
                self:Error("Can't delete all meta information from " .. type_ .. ' file')
            else
                self:Error('Nothing to write')
            end
        end
        if self.VALUE.Error then rtnVal = 0 end
    end

    -- rewrite original file in place if required
    if outBuff ~= nil then
        if rtnVal <= 0 or not perlTruthy(self.CHANGED) then -- luacheck: ignore 542
            -- nothing changed, so no need to write $outBuff
        elseif isGlob(inRef) then
            local len = perl.length(outBuff.value)
            local size = inRef:seek('end')          -- seek to the end of file, get the file size
            if not (size and size >= 0 and
                inRef:seek('set', 0) and            -- seek back to the start
                perl.print(inRef, outBuff.value) == 1 and -- write the new data
                (len >= size or                     -- if necessary:
                perl.truncate(inRef, len) == 1)) --  shorten output file
            then
                rtnVal = -1
            end
        else
            inRef.value = outBuff.value               -- replace original data
        end
        outBuff.value = carray.new('char')  -- free memory but leave $outBuff defined
    end
    -- close input file if we opened it
    if closeIn then
        -- errors on input file are significant if we edited the file in place
        if not (inRef:close() or outBuff == nil) and perlTruthy(rtnVal) then rtnVal = -1 end
        if rtnVal > 0 then
            -- copy Mac OS resource fork if it exists
            -- (the darwin branch has no counterpart)
            -- erase input file if renaming while editing information in place
            if eraseIn and Writer.Unlink(self, infile) == 0 then self:Warn('Error erasing original file') end
        end
    end
    -- close output file if we created it
    if closeOut then
        -- close file and set $rtnVal to -1 if there was an error
        if not outRef:close() and perlTruthy(rtnVal) then rtnVal = -1 end
        -- erase the output file if we weren't successful
        if rtnVal <= 0 then
            Writer.Unlink(self, outfile)
        -- else rename temporary file if necessary
        elseif tmpfile then
            Writer.CopyFileAttrs(self, infile, tmpfile)    -- copy attributes to new file
            if not Writer.Rename(self, tmpfile, infile) then
                -- some filesystems won't overwrite with 'rename', so try erasing original
                if Writer.Unlink(self, infile) == 0 then
                    Writer.Unlink(self, tmpfile)
                    self:Error('Error renaming temporary file')
                    rtnVal = 0
                elseif not Writer.Rename(self, tmpfile, infile) then
                    self:Error('Error renaming temporary file after deleting original')
                    rtnVal = 0
                end
            end
            -- the output file should now have the name of the original infile
            if rtnVal > 0 then outfile = infile end
        end
    end
    -- set filesystem attributes if requested (and if possible!)
    if rtnVal > 0 and (closeOut or (outBuff ~= nil and (closeIn or isGlob(infile)))) then
        local target = closeOut and outfile or infile
        -- set file permissions if requested
        if Writer.SetSystemTags(self, target) > 0 then self.CHANGED = (self.CHANGED or 0) + 1 end
        if closeIn then -- (no use setting file times unless the input file is closed)
            if setModDate and Writer.SetFileModifyDate(self, target, originalTime, nil, 1) > 0 then
                self.CHANGED = (self.CHANGED or 0) + 1
            end
            -- set FileCreateDate if requested (and if possible!)
            if setCreateDate and Writer.SetFileModifyDate(self, target, createTime, 'FileCreateDate', 1) > 0 then
                self.CHANGED = (self.CHANGED or 0) + 1
            end
            -- create hard link if requested and no output filename specified (and if possible!)
            if hardLink ~= nil and perlTruthy(Writer.SetFileName(self, target, hardLink, 'HardLink')) then
                self.CHANGED = (self.CHANGED or 0) + 1
            end
            if symLink ~= nil and perlTruthy(Writer.SetFileName(self, target, symLink, 'SymLink')) then
                self.CHANGED = (self.CHANGED or 0) + 1
            end
            if testName ~= nil then Writer.SetFileName(self, target, testName, 'Test') end
        end
    end
    -- check for write error and set appropriate error message and return value
    if rtnVal < 0 then
        if not self.VALUE.Error then self:Error('Error writing output file') end
        rtnVal = 0    -- return 0 on failure
    elseif rtnVal > 0 then
        if not perlTruthy(self.CHANGED) then rtnVal = rtnVal + 1 end
    end
    -- set things back to the way they were
    self.RAF = oldRaf

    return rtnVal
end

-- upstream's `grep /^$group$/i, @tg` inside GetAllTags/GetWritableTags: does
-- the tagInfo's group list contain this group name (case-insensitively)?  The
-- group name comes from the command line, so it goes through the regex engine
-- as upstream's does rather than a plain string compare.  (GetGroup returns a
-- table keyed 0..3, not a Perl list -- hence pairs() rather than ipairs().)
local function inGroupList(tg, group)
    for _, g in pairs(tg) do
        if perl.isMatchDyn(g, '(?i)^' .. group .. '$') then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Get list of all available tags for specified group
-- Inputs: 0) optional group name (or string of names separated by colons)
-- Returns: tag list (sorted alphabetically)
-- Notes: Can't get tags for specific IFD
function Writer.GetAllTags(group)
    local allTags, groups = {}, {}
    if group then groups = perl.split(':', group) end

    local et = ExifTool.new()
    Writer.LoadAllTables()  -- first load all our tables
    local tableNames = {}
    for name in pairs(ExifTool.GetAllTables()) do tableNames[#tableNames + 1] = name end

    -- loop through all tables and save tag names to %allTags hash
    while #tableNames > 0 do
        local table_ = ExifTool.GetTagTable(nil, remove(tableNames))
        -- generate flattened tag names for structure fields if this is an XMP table
        if table_.GROUPS and table_.GROUPS[0] == 'XMP' then
            require('lexiftool.XMP').AddFlattenedTags(table_)
        end
        local tagID
        for _, id in ipairs(ExifTool.TagTableKeys(table_)) do
            tagID = id
            local infoArray = ExifTool.GetTagInfoList(table_, tagID)
            local tagInfo
            for i = 1, #infoArray do
                tagInfo = infoArray[i]
                repeat -- (GATInfo: upstream's `next GATInfo` out of the group loop)
                    local tag = tagInfo.Name
                    if not tag then perl.print(io.stderr, 'no name for tag!\n') break end
                    -- don't list subdirectories unless they are writable
                    -- (perlTruthy: several tables spell the "not writable"
                    --  half of this as `Writable => 0`, which is Perl-false
                    --  but Lua-true -- CanonRaw alone has eighteen)
                    if tagInfo.SubDirectory and not perlTruthy(tagInfo.Writable) then break end
                    if perlTruthy(tagInfo.Hidden) then break end  -- ignore hidden tags
                    if #groups > 0 then
                        local tg = et:GetGroup(tagInfo)
                        local skip
                        for _, grp in ipairs(groups) do
                            if not inGroupList(tg, grp) then skip = true break end
                        end
                        if skip then break end
                    end
                    allTags[tag] = 1
                until true
            end
        end
    end
    local list = {}
    for tag in pairs(allTags) do list[#list + 1] = tag end
    tsort(list)
    return list
end

--------------------------------------------------------------------------------
-- Get list of all writable tags
-- Inputs: 0) optional group name (or names separated by colons)
-- Returns: tag list (sorted alphabetically)
function Writer.GetWritableTags(group)
    local writableTags, groups = {}, {}
    if group then groups = perl.split(':', group) end

    local et = ExifTool.new()
    Writer.LoadAllTables()
    local tableNames = {}
    for name in pairs(ExifTool.GetAllTables()) do tableNames[#tableNames + 1] = name end

    while #tableNames > 0 do
        local tableName = remove(tableNames)
        local table_ = ExifTool.GetTagTable(nil, tableName)
        -- generate flattened tag names for structure fields if this is an XMP table
        if table_.GROUPS and table_.GROUPS[0] == 'XMP' then
            require('lexiftool.XMP').AddFlattenedTags(table_)
        end
        -- attempt to load Write tables if autoloaded
        local parts = perl.split([[\.]], tableName)
        if #parts > 2 then
            local i = #parts - 1
            parts[i] = 'Write' .. parts[i]   -- add 'Write' before class name
            local module = concat(parts, '.', 1, i)
            pcall(require, module) -- (fails silently if nothing loaded)
        end
        local tagID
        for _, id in ipairs(ExifTool.TagTableKeys(table_)) do
            tagID = id
            local infoArray = ExifTool.GetTagInfoList(table_, tagID)
            local tagInfo
            for i = 1, #infoArray do
                tagInfo = infoArray[i]
                repeat -- (GWTInfo: upstream's `next GWTInfo` out of the group loop)
                    local tag = tagInfo.Name
                    if not tag then perl.print(io.stderr, 'no name for tag!\n') break end
                    local writable = tagInfo.Writable
                    if not (perlTruthy(writable) or (perlTruthy(table_.WRITABLE) and
                        writable == nil and not tagInfo.SubDirectory)) then break end
                    if perlTruthy(tagInfo.Hidden) then break end  -- ignore hidden tags
                    if #groups > 0 then
                        local tg = et:GetGroup(tagInfo)
                        local skip
                        for _, grp in ipairs(groups) do
                            if not inGroupList(tg, grp) then skip = true break end
                        end
                        if skip then break end
                    end
                    writableTags[tag] = 1
                until true
            end
        end
    end
    local list = {}
    for tag in pairs(writableTags) do list[#list + 1] = tag end
    tsort(list)
    return list
end

--------------------------------------------------------------------------------
-- Get list of all group names
-- Inputs: 0) [optional] ExifTool ref, 1) Group family number
-- Returns: List of group names (sorted alphabetically)
function Writer.GetAllGroups(self, family)
    if not perl.truthy(family) then family = 0 end
    -- (a Perl scalar compares as a number in `== 3` and keys GROUPS the same
    --  for "1" and 1; the Lua GROUPS tables are keyed by integer)
    family = perl.num(family)

    if family == 3 then return { 'Doc#', 'Main' } end
    if family == 4 then return { 'Copy#' } end
    if family == 5 then return { '[too many possibilities to list]' } end
    if family == 6 then
        local fn = require('lexiftool.Exif').formatNumber
        local list = {}
        for k in pairs(fn) do list[#list + 1] = k end
        tsort(list, function(a, b) return fn[a] < fn[b] end)
        return list
    end
    if family == 8 then return { 'File#' } end

    Writer.LoadAllTables()  -- first load all our tables

    local tableNames = {}
    for name in pairs(ExifTool.GetAllTables()) do tableNames[#tableNames + 1] = name end

    local allGroups = {}
    -- start with family 1 groups that are missing from the tables
    if family == 1 then
        for _, g in ipairs({ 'Garmin', 'AudioItemList', 'AudioUserData',
            'VideoItemList', 'VideoUserData', 'Track#Keys', 'Track#ItemList', 'Track#UserData', 'KFIX' }) do
            allGroups[g] = 1
        end
    end
    -- loop through all tag tables and get all group names
    while #tableNames > 0 do
        local table_ = ExifTool.GetTagTable(nil, remove(tableNames))
        local grps, grp
        grps = table_.GROUPS
        if grps then
            grp = grps[family]
            if grp then allGroups[grp] = 1 end
        end
        for _, tag in ipairs(ExifTool.TagTableKeys(table_)) do
            local infoArray = ExifTool.GetTagInfoList(table_, tag)
            local tagInfo
            if family == 7 then
                for i = 1, #infoArray do
                    tagInfo = infoArray[i]
                    local id = tagInfo.TagID
                    if id == nil then
                        id = ''   -- (just to be safe)
                    elseif type(id) == 'number' or perlStr(id):match('^%d+$') then
                        if self and perl.truthy(self.OPTIONS.HexTagIDs) then id = sprintf('0x%x', id) end
                        id = perlStr(id)
                    else
                        id = perl.subst(id, [[([^-_A-Za-z0-9])]], function(c) return sprintf('%.2x', sbyte(c)) end, 'ge')
                    end
                    allGroups['ID-' .. id] = 1
                end
            else
                for i = 1, #infoArray do
                    tagInfo = infoArray[i]
                    grps = tagInfo.Groups
                    if grps then
                        grp = grps[family]
                        if grp then allGroups[grp] = 1 end
                    end
                end
            end
        end
    end
    allGroups['*'] = nil        -- (not a real group)
    local list = {}
    for k in pairs(allGroups) do list[#list + 1] = k end
    tsort(list, function(a, b) return perl.lt(lc(a), lc(b)) end)
    return list
end

--------------------------------------------------------------------------------
-- get priority group list for new values
-- Inputs: 0) ExifTool object reference
-- Returns: List of group names
function Writer.GetNewGroups(self)
    return self.WRITE_GROUPS
end

--------------------------------------------------------------------------------
-- Get list of all deletable group names
-- Returns: List of group names (sorted alphabetically)
function Writer.GetDeleteGroups()
    local all = { }
    for _, g in ipairs(delGroups) do all[#all + 1] = g end
    for _, g in ipairs(delGroup2) do all[#all + 1] = g end
    return perl.sort(all, function(a, b)
        return perl.cmp(lc(a), lc(b))     -- (Perl `lc $a cmp lc $b`)
    end)
end

--------------------------------------------------------------------------------
-- Add user-defined tags at run time (upstream Writer.pl:2893)
-- Inputs: 0) destination table name, 1) tagID/tagInfo pairs for tags to add
-- Returns: number of tags added
-- Notes: will replace existing tags
-- (Lua: the tagID/tagInfo pairs come as one table; the port's table names,
--  e.g. 'lexiftool.ExifTool.Composite' for 'Image::ExifTool::Composite')
function Writer.AddUserDefinedTags(tableName, addTags)
    local table_ = ExifTool.GetTagTable(nil, tableName)
    if not table_ then return 0 end
    -- add tags to writer lookup
    require('lexiftool.TagLookup').AddTags(addTags, tableName)
    local num = 0
    -- (Perl `keys %addTags`; sorted here, since the order is unspecified there)
    local tagIDs = {}
    for tagID in pairs(addTags) do tagIDs[#tagIDs + 1] = tagID end
    tsort(tagIDs, function(a, b) return perl.lt(perlStr(a), perlStr(b)) end)
    for _, tagID in ipairs(tagIDs) do
        if not ExifTool.specialTags[tagID] then
            table_[tagID] = nil -- delete old entry if it existed
            ExifTool.AddTagToTable(nil, table_, tagID, addTags[tagID], 1)
            num = num + 1
        end
    end
    return num
end

--==============================================================================
-- Functions below this are not part of the public API

--------------------------------------------------------------------------------
-- Maintain backward compatibility for old GetNewValues function name
function Writer.GetNewValues(self, tag, wantarray)
    return Writer.GetNewValue(self, tag, wantarray)
end

--------------------------------------------------------------------------------
-- Un-escape string according to options settings and clear UTF-8 flag
-- Inputs: 0) ExifTool ref, 1) string ref or string ref ref
-- Notes: also de-references SCALAR values
-- (Lua has no string refs: takes the value and returns the sanitized one)
function Writer.Sanitize(self, valPt)
    -- de-reference SCALAR references
    if type(valPt) == 'table' and valPt.ref == 'SCALAR' then valPt = valPt.value end
    -- (upstream clears Perl's UTF-8 flag here, repacking the string; Lua
    --  strings are plain bytes, so there is nothing to do)
    -- un-escape value if necessary
    if self.OPTIONS.Escape then
        -- (XMP.pm and HTML.pm were require'd as necessary when option was set)
        if self.OPTIONS.Escape == 'XML' then
            valPt = require('lexiftool.XMP').UnescapeXML(valPt)
        elseif self.OPTIONS.Escape == 'HTML' then
            valPt = require('lexiftool.HTML').UnescapeHTML(valPt, self.OPTIONS.Charset)
        end
    end
    return valPt
end

--------------------------------------------------------------------------------
-- Return true if we are deleting or overwriting the specified tag
-- Inputs: 0) ExifTool object ref, 1) new value hash reference
--         2) optional tag value (before RawConv) if deleting specific values
-- Returns: >0 - tag should be overwritten
--          =0 - the tag should be preserved
--          <0 - not sure, we need the old value to tell (if there is no old value
--               then the tag should be written if $$nvHash{IsCreating} is true)
-- Notes: $$nvHash{Value} is updated with the new value when shifting a value
-- (Lua: RawConv functions take ($self, $val, $tag), ValueConv ($self, $val);
--  the comparisons are Perl's string `eq`)
function Writer.IsOverwriting(self, nvHash, val)
    if not nvHash then return 0 end
    -- overwrite regardless if no DelValues specified
    if not nvHash.DelValue then return 1 end
    -- never overwrite if DelValue list exists but is empty
    local shift = nvHash.Shift
    if not (#nvHash.DelValue > 0 or shift ~= nil) then return 0 end
    -- return "don't know" if we don't have a value to test
    if val == nil then return -1 end
    -- apply raw conversion if necessary
    local tagInfo = nvHash.TagInfo
    local conv = tagInfo.RawConv
    if conv then
        --### eval RawConv ($self, $val, $tag, $tagInfo, $priority, @grps)
        local ok, res = pcall(conv, self, val, tagInfo.Name)
        val = ok and res or nil
        if val == nil then return -1 end
    end
    -- do not overwrite if only creating
    if nvHash.CreateOnly then return 0 end
    -- apply time/number shift if necessary
    if shift ~= nil then
        local shiftType = tagInfo.Shift
        if not (shiftType and shiftType == 'Time') then
            if not ExifTool.IsFloat(val) then
                -- do the ValueConv to try to get a number
                conv = tagInfo.ValueConv
                if conv ~= nil then
                    local evalWarning
                    if type(conv) == 'function' then
                        local ok, res = pcall(conv, self, val)
                        if ok then val = res else evalWarning = perl.isDie(res) and res.msg or tostring(res) end
                    end
                    if evalWarning then
                        self:Warn('ValueConv ' .. tagInfo.Name .. ': ' .. ExifTool.CleanWarning(evalWarning))
                        return 0
                    end
                end
                if not (val ~= nil and ExifTool.IsFloat(val)) then
                    self:Warn("Can't shift " .. tagInfo.Name .. ' (not a number)')
                    return 0
                end
            end
            shiftType = 'Number'  -- allow any number to be shifted
        end
        local err = Shift.ApplyShift(self, shiftType, shift, val, nvHash)
        if err then
            self:Warn(err .. ' when shifting ' .. tagInfo.Name)
            return 0
        end
        -- ensure that the shifted value is valid and reformat if necessary
        local checkVal = Writer.GetNewValue(self, nvHash)
        if checkVal == nil then return 0 end
        -- don't bother overwriting if value is the same
        if perlStr(val) == perlStr(nvHash.Value[1]) then return 0 end
        return 1
    end
    -- return 1 if value matches a DelValue
    for _, delVal in ipairs(nvHash.DelValue) do
        if perlStr(val) == perlStr(delVal) then return 1 end
    end
    return 0
end

--------------------------------------------------------------------------------
-- Get new value hash for specified tagInfo/writeGroup (upstream Writer.pl GetNewValueHash)
-- Inputs: 0) ExifTool ref, 1) tagInfo ref, 2) WriteGroup name,
--         3) Options: 'delete' or 'create', 4) optional ProtectSaved, 5) deleting flag
-- Returns: new value hash ref (or first in linked list if writeGroup not specified)
--------------------------------------------------------------------------------
function Writer.GetNewValueHash(self, tagInfo, writeGroup, opts, protectSaved, deleting)
    if not tagInfo then return nil end
    local nvHash = self.NEW_VALUE and self.NEW_VALUE[tagInfo]
    writeGroup = writeGroup or ''
    if writeGroup ~= '' then
        -- find the new value in the list with the specified write group
        while nvHash and nvHash.WriteGroup ~= writeGroup do
            -- QuickTime and All are special cases because all group1 tags may
            -- be updated at once
            if nvHash.WriteGroup == 'QuickTime' or nvHash.WriteGroup == 'All' then break end
            -- replace existing entry if WriteGroup is 'All' ... (forum17770)
            if writeGroup == 'All' or (nvHash.WriteGroup == 'EXIF' and writeGroup:match('IFD')) then break end
            nvHash = nvHash.Next
        end
    end
    -- remove this entry if deleting, or if creating a new entry and
    -- this entry is marked with "Save" flag
    if nvHash and (opts == 'delete' or (opts == 'create' and nvHash.Save)) then
        local protect = (protectSaved ~= nil and nvHash.Save ~= nil and nvHash.Save > protectSaved)
        if protect and not (opts == 'create' and (nvHash.NoReplace or deleting or
            (nvHash.DelValue and nvHash.Shift == nil)))
        then
            return nil    -- honour ProtectSaved value by not writing this tag
        elseif opts == 'delete' then
            Writer.RemoveNewValueHash(self, nvHash, tagInfo)
            nvHash = nil
        else
            -- save a copy of this new value hash
            local copy = {}
            for k, v in pairs(nvHash) do copy[k] = v end
            -- make copies of array-valued members (Value/DelValue)
            for k, v in pairs(copy) do
                if type(v) == 'table' and v[1] ~= nil then
                    local arr = {}
                    for i = 1, #v do arr[i] = v[i] end
                    copy[k] = arr
                end
            end
            local saveHash = self.SAVE_NEW_VALUE or {}
            self.SAVE_NEW_VALUE = saveHash
            -- add to linked list of saved new value hashes
            copy.Next = saveHash[tagInfo]
            saveHash[tagInfo] = copy
            nvHash.Save = nil  -- don't save it again
            if protect and nvHash.Value then nvHash.AddBefore = #nvHash.Value end
        end
    end
    if not nvHash and opts == 'create' then
        -- create a new entry
        self.NEW_VALUE = self.NEW_VALUE or {}
        nvHash = {
            TagInfo = tagInfo,
            WriteGroup = writeGroup,
            IsNVH = 1,   -- set flag so we can recognize a new value hash
            Order = self.NV_COUNT or 0,
        }
        self.NV_COUNT = (self.NV_COUNT or 0) + 1
        -- add entry to our NEW_VALUE hash
        if self.NEW_VALUE[tagInfo] then
            -- add to end of linked list
            local lastHash = LastInList(self.NEW_VALUE[tagInfo])
            lastHash.Next = nvHash
        else
            self.NEW_VALUE[tagInfo] = nvHash
        end
    end
    return nvHash
end

-- Port deviation helper: upstream's SubDirectory TagTable is always a table
-- *name* ('Image::ExifTool::QuickTime::Meta'), so LoadAllTables can just push
-- it onto its worklist.  Some ported modules -- QuickTime.lua above all --
-- reference their sub-tables directly instead, which no name can be recovered
-- from at the point of use.  Since such a reference always points at a table
-- of the same module, the name is recovered by scanning that one module for
-- the field holding it.  Returns nil for a table that is not a module field.
local function tableNameOf(parentName, tbl)
    local modName = parentName:match('^(lexiftool%.[^%.]+)%.')
    local mod = modName and package.loaded[modName]
    if type(mod) ~= 'table' then return nil end
    for k, v in pairs(mod) do
        if v == tbl and type(k) == 'string' then return modName .. '.' .. k end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Load all tag tables
function Writer.LoadAllTables()
    if loadedAllTables then return end

    -- load all of our non-referenced tables (first our modules)
    local table_
    for _, tbl in ipairs(ExifTool.loadAllTables) do
        local tableName = 'lexiftool.' .. tbl
        if not tbl:find('.', 1, true) then tableName = tableName .. '.Main' end
        ExifTool.GetTagTable(nil, tableName)
    end
    -- (then our special tables)
    ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.Extra')
    ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.Composite')
    -- Port deviation: upstream reaches JFIF, APP12::Ducky and CanonVRD through
    -- the SubDirectory entries of %Image::ExifTool::JPEG::Main, which this port
    -- carries as a stub without tag entries (see JPEG.lua's port note), so the
    -- recursion below has nothing to follow.  Name the three heads here until
    -- that table is ported -- without them they are missing from everything
    -- derived from the loaded table set, the write index in TagLookup.lua above
    -- all (their tags would simply not be writable).
    -- (CanonVRD::DR4 hangs off %CanonVRD::Main's Edit4Data via %CanonVRD::Edit4,
    --  and that link is not ported either, so it needs naming as well)
    for _, tbl in ipairs{ 'lexiftool.JFIF.Main', 'lexiftool.APP12.Ducky',
                          'lexiftool.CanonVRD.Main', 'lexiftool.CanonVRD.DR4' } do
        ExifTool.GetTagTable(nil, tbl)
    end
    -- recursively load all tables referenced by the current tables
    local tableNames = {}
    for name in pairs(ExifTool.GetAllTables()) do tableNames[#tableNames + 1] = name end
    local pushedTables = {}
    local n = 1
    while n <= #tableNames do
        table_ = ExifTool.GetTagTable(nil, tableNames[n])
        n = n + 1
        -- (a table named by a SubDirectory of a module this port has not
        --  ported yet simply does not exist -- upstream never sees that case)
        if table_ then
            -- call write proc if it exists in case it adds tags to the table
            local writeProc = table_.WRITE_PROC
            if writeProc then
                -- (upstream calls the write proc with no arguments at all; in
                --  Perl the resulting `$$dirInfo{DataPt}` on an undefined
                --  $dirInfo is simply undef, so a proc without the explicit
                --  `$et or return 1` dummy-access guard falls through
                --  harmlessly.  Lua raises on indexing nil instead, so the
                --  call is guarded here -- the point of the call is the side
                --  effect on the table, which either way has already happened
                --  by the time such a proc reaches its first argument.)
                pcall(writeProc)
            end
            -- recursively scan through tables in subdirectories
            for _, k in ipairs(ExifTool.TagTableKeys(table_)) do
                local infoArray = ExifTool.GetTagInfoList(table_, k)
                local tagInfo
                for i = 1, #infoArray do
                    tagInfo = infoArray[i]
                    local subdir = tagInfo.SubDirectory
                    if subdir then
                        local tableName = subdir.TagTable
                        if type(tableName) == 'table' then
                            tableName = tableNameOf(tableNames[n - 1], tableName)
                        end
                        -- next if table already loaded or queued for loading
                        if tableName and not (ExifTool.GetAllTables()[tableName] or pushedTables[tableName]) then
                            tableNames[#tableNames + 1] = tableName  -- must scan this one too
                            pushedTables[tableName] = 1
                        end
                    end
                end
            end
        end
    end
    loadedAllTables = 1
end

--------------------------------------------------------------------------------
-- Remove new value hash from linked list (upstream Writer.pl RemoveNewValueHash)
--------------------------------------------------------------------------------
function Writer.RemoveNewValueHash(self, nvHash, tagInfo)
    local firstHash = self.NEW_VALUE[tagInfo]
    if nvHash == firstHash then
        if nvHash.Next then
            self.NEW_VALUE[tagInfo] = nvHash.Next
        else
            self.NEW_VALUE[tagInfo] = nil
        end
    else
        local prev = firstHash
        while prev and prev.Next ~= nvHash do prev = prev.Next end
        if prev then prev.Next = nvHash.Next end
    end
    if nvHash.Save then
        local saveHash = self.SAVE_NEW_VALUE or { }
        self.SAVE_NEW_VALUE = saveHash
        nvHash.Next = saveHash[tagInfo]
        saveHash[tagInfo] = nvHash
    end
end

--------------------------------------------------------------------------------
-- Remove all new value entries for specified group
-- Inputs: 0) ExifTool object reference, 1) group name
function Writer.RemoveNewValuesForGroup(self, group)

    if not self.NEW_VALUE then return end

    -- make list of all groups we must remove
    local groups = { group }
    if removeGroups[group] then
        for _, g in ipairs(removeGroups[group]) do groups[#groups + 1] = g end
    end

    local out
    if perlTruthy(self.OPTIONS.Verbose) and self.OPTIONS.Verbose > 1 then out = self.OPTIONS.TextOut or io.stdout end

    -- loop though all new values, and remove any in this group
    local keys = perl.keys(self.NEW_VALUE)
    for _, hashKey in ipairs(keys) do
        local nvHash = self.NEW_VALUE[hashKey]
        -- loop through each entry in linked list
        while nvHash do
            local nextHash = nvHash.Next
            local tagInfo = nvHash.TagInfo
            local grp0 = self:GetGroup(tagInfo, 0)
            local grp1 = self:GetGroup(tagInfo, 1)
            local wgrp = nvHash.WriteGroup
            -- use group1 if write group is not specific
            if wgrp == grp0 then wgrp = grp1 end
            local found = (grp0 == '*' or wgrp == '*')
            if not found then
                for _, g in ipairs(groups) do
                    if isMatchDyn(g, '(?i)^(' .. grp0 .. '|' .. wgrp .. ')$') then found = true break end
                end
            end
            if found then
                if out then out:write('Removed new value for ' .. wgrp .. ':' .. tagInfo.Name .. '\n') end
                -- remove from linked list
                Writer.RemoveNewValueHash(self, nvHash, tagInfo)
            end
            nvHash = nextHash
        end
    end
end

--------------------------------------------------------------------------------
-- Get list of tagInfo hashes for all new data (upstream Writer.pl GetNewTagInfoList)
--------------------------------------------------------------------------------
function Writer.GetNewTagInfoList(self, tagTablePtr)
    local list = { }
    local nv = self.NEW_VALUE
    if nv then
        for _, nvHash in pairs(nv) do
            local tagInfo = nvHash.TagInfo
            if not (tagTablePtr and tagTablePtr ~= tagInfo.Table) then
                list[#list + 1] = tagInfo
            end
        end
    end
    return list
end

--------------------------------------------------------------------------------
-- Get hash of tagInfo refs for all pending new values (upstream Writer.pl
-- GetNewTagInfoHash). If table refs are given, only tags from those tables are
-- included. Returns tagID -> tagInfo hash.
--------------------------------------------------------------------------------
function Writer.GetNewTagInfoHash(self, ...)
    local tables = { ... }
    local tagInfoHash = { }
    if self.NEW_VALUE then
        for tagInfo in pairs(self.NEW_VALUE) do
            if #tables == 0 then
                tagInfoHash[tagInfo.TagID] = tagInfo
            else
                for _, tbl in ipairs(tables) do
                    if tbl == tagInfo.Table then
                        tagInfoHash[tagInfo.TagID] = tagInfo
                        break
                    end
                end
            end
        end
    end
    return tagInfoHash
end

--------------------------------------------------------------------------------
-- Get localized version of tagInfo hash (used by MIE, XMP, PNG and QuickTime)
-- Inputs: 0) tagInfo hash ref, 1) locale code (eg. "en_CA" for MIE)
-- Returns: new tagInfo hash ref, or undef if invalid
-- - sets LangCode member in new tagInfo
function Writer.GetLangInfo(tagInfo, langCode)
    -- make a new tagInfo hash for this locale
    local table_ = tagInfo.Table
    local tagID = tagInfo.TagID .. '-' .. langCode
    local langInfo = table_[tagID]
    if not langInfo then
        -- make a new tagInfo entry for this locale
        langInfo = {}
        for k, v in pairs(tagInfo) do langInfo[k] = v end
        langInfo.Name = tagInfo.Name .. '-' .. langCode
        langInfo.Description = ExifTool.MakeDescription(tagInfo.Name) ..
                               ' (' .. langCode .. ')'
        langInfo.LangCode = langCode
        langInfo.SrcTagInfo = tagInfo -- save reference to original tagInfo
        ExifTool.AddTagToTable(nil, table_, tagID, langInfo)
    end
    return langInfo
end

--------------------------------------------------------------------------------
-- Initialize ADD_DIRS and EDIT_DIRS hashes for all directories that need to be
-- created or will have tags changed in them (upstream Writer.pl InitWriteDirs).
-- Inputs: 0) ExifTool object ref, 1) file type string ('JPEG'/'TIFF') or a
--         directory map table, 2) preferred group, 3) alternate group
--------------------------------------------------------------------------------
function Writer.InitWriteDirs(self, fileType, preferredGroup, altGroup)
    local editDirs = { }
    local addDirs = { }
    self.EDIT_DIRS = editDirs
    self.ADD_DIRS = addDirs
    local fileDirs = dirMap[fileType]
    if not fileDirs then
        if type(fileType) ~= 'table' then return end
        fileDirs = fileType
    end
    -- FindTagInfo only resolves tags in LOADED tables, so make sure the EXIF
    -- sub-directory tables are loaded before resolving the pending edits
    -- (port addition: the write engine itself only loads them later)
    self:GetTagTable('lexiftool.Exif.Main')
    self:GetTagTable('lexiftool.GPS.Main')
    local tagInfoList = self.NEW_VALUE and Writer.GetNewTagInfoList(self) or { }

    -- save the preferred group
    self.PreferredGroup = preferredGroup

    for _, tagInfo in ipairs(tagInfoList) do
        -- cycle through all hashes in linked list
        local nvHash = Writer.GetNewValueHash(self, tagInfo)
        while nvHash do
            -- are we creating this tag? (otherwise just deleting or editing it)
            local isCreating = nvHash.IsCreating
            if preferredGroup then
                local g0 = self:GetGroup(tagInfo, 0)
                if perlTruthy(isCreating) then
                    -- if another group is taking priority, only create
                    -- directory if specifically adding tags to this group
                    -- or if this tag isn't being added to the priority group
                    if preferredGroup ~= g0 and
                        (nvHash.CreateGroups and nvHash.CreateGroups[preferredGroup]) and
                        (not altGroup or altGroup ~= g0) then
                        isCreating = 0
                    end
                else
                    -- create this directory if any tag is preferred and has a value
                    -- (unless group creation is disabled via the WriteMode option)
                    if nvHash.Value and preferredGroup == g0 and not nvHash.EditOnly and
                        isMatch(self.OPTIONS.WriteMode or 'wcg', 'g') then
                        isCreating = 1
                    end
                end
            end
            -- tag belongs to directory specified by WriteGroup, or by
            -- the Group0 name if WriteGroup not defined
            local dirName = nvHash.WriteGroup
            -- remove MIE copy number(s) if they exist
            local isMIE, mie1 = isMatch(dirName, [[(?i)^MIE\d*(-[a-z]+)?\d*$]])
            if isMIE then
                dirName = 'MIE' .. (mie1 or '')
            end
            local dirNames = { }
            -- allow a group name of '*' to force writing EXIF/IPTC/XMP/PNG (ForceWrite tag)
            if dirName == '*' and nvHash.Value then
                local val = nvHash.Value[1]
                if perlTruthy(val) then
                    for _, d in ipairs({ 'EXIF', 'IPTC', 'XMP', 'PNG', 'FixBase' }) do
                        if isMatchDyn(val, '(?i)\\b(' .. d .. '|All)\\b') then
                            dirNames[#dirNames + 1] = d
                            if d == 'FixBase' then dirNames[#dirNames + 1] = 'EXIF' end
                            self.FORCE_WRITE = self.FORCE_WRITE or { }
                            self.FORCE_WRITE[d] = 1
                        end
                    end
                end
                dirName = remove(dirNames, 1)
            elseif dirName == 'QuickTime' then
                -- write to specific QuickTime group
                dirName = self:GetGroup(tagInfo, 1)
            end
            while dirName do
                local parent = fileDirs[dirName]
                if type(parent) == 'table' then
                    for i = #parent, 1, -1 do dirNames[#dirNames + 1] = parent[i] end
                    parent = remove(dirNames)
                end
                -- (Perl stores undef for the root directory and tests it with
                --  `exists`; Lua would drop the key, so a root gets `false`)
                editDirs[dirName] = parent or false
                if perlTruthy(isCreating) and isCreating ~= 2 then addDirs[dirName] = parent or false end
                dirName = parent or remove(dirNames, 1)
            end
            nvHash = nvHash.Next
        end
    end
    if self.DEL_GROUP and next(self.DEL_GROUP) then
        -- add delete groups to list of edited groups
        -- (sorted: Perl's hash order does not matter here, Lua's must not either)
        for _, grp in ipairs(perl.sort(perl.keys(self.DEL_GROUP))) do
            if not isMatch(grp, '^-') then   -- ignore excluded groups
                local dirName = grp
                -- translate necessary group 0 names
                if translateWriteGroup[dirName] then dirName = translateWriteGroup[dirName] end
                -- convert XMP group 1 names
                if isMatch(dirName, '^XMP-') then dirName = 'XMP' end
                local dirNames = { }
                while dirName do
                    local parent = fileDirs[dirName]
                    if type(parent) == 'table' then
                        for i = #parent, 1, -1 do dirNames[#dirNames + 1] = parent[i] end
                        parent = remove(dirNames)
                    end
                    editDirs[dirName] = parent or false
                    dirName = parent or remove(dirNames, 1)
                end
            end
        end
    end
    -- special case to edit JFIF to get resolutions if editing EXIF information
    if editDirs.IFD0 and fileDirs.JFIF then
        editDirs.JFIF = 'IFD1'
        editDirs.APP0 = false
    end

    if perlTruthy(self.OPTIONS.Verbose) then
        local out = self.OPTIONS.TextOut or io.stdout
        out:write('  Editing tags in: ')
        for _, k in ipairs(perl.sort(perl.keys(editDirs))) do out:write(k .. ' ') end
        out:write("\n")
        if self.OPTIONS.Verbose <= 1 then return end
        out:write('  Creating tags in: ')
        for _, k in ipairs(perl.sort(perl.keys(addDirs))) do out:write(k .. ' ') end
        out:write("\n")
    end
end

--------------------------------------------------------------------------------
-- Set byte order according to our current preferences (upstream Writer.pl
-- SetPreferredByteOrder)
-- Inputs: 0) ExifTool ref, 1) default byte order (or nil)
-- Returns: the byte order that was set
--------------------------------------------------------------------------------
function Writer.SetPreferredByteOrder(self, default)
    local newOrder = Writer.GetNewValue(self, 'ExifByteOrder')
    local byteOrder = self.OPTIONS.ByteOrder or newOrder or
                      default or self.MAKER_NOTE_BYTE_ORDER or 'MM'
    if not ExifTool.SetByteOrder(byteOrder) then
        if perl.truthy(self:Options('Verbose')) then
            perl.print(io.stderr, "Invalid byte order '" .. perlStr(byteOrder) .. "'\n")
        end
        byteOrder = self.MAKER_NOTE_BYTE_ORDER or 'MM'
        ExifTool.SetByteOrder(byteOrder)
    end
    return ExifTool.GetByteOrder()
end

-- Write TIFF as a directory (upstream Writer.pl WriteTIFF: ProcessTIFF with an
-- in-memory OutFile). Used as the SubDirectory WriteProc for an EXIF block
-- embedded in another container, where the block carries its own TIFF header.
-- Inputs: 0) ExifTool ref, 1) dirInfo ref (DataPt/DirStart/DirLen, or nothing
--         at all to create the block from scratch), 2) tag table ref
-- Returns: new directory data, or nil on error
function Writer.WriteTIFF(self, dirInfo, tagTablePtr)
    if not self then return 1 end    -- allow dummy access
    if dirInfo.RAF then
        -- (a TIFF read from a file -- the DOS EPS preview -- goes through
        --  ProcessTIFF with an in-memory OutFile, as upstream does for all)
        local buff = { value = carray.new('char') }
        dirInfo.OutFile = buff
        if self:ProcessTIFF(dirInfo, tagTablePtr) > 0 then return buff.value:tostring() end
        return nil
    end
    -- (port: the in-memory branch of DoProcessTIFF, which upstream reaches
    --  through ProcessTIFF with the scalar OutFile; processTIFFWrite in
    --  lexiftool.lua is the file branch)
    local fileType = dirInfo.Parent or ''
    local base = dirInfo.Base or 0
    local exifData
    local dataPt = dirInfo.DataPt
    if dataPt and perl.length(dataPt) > 0 then
        -- save a copy of the EXIF data
        local dirStart = dirInfo.DirStart or 0
        local dirLen = perlTruthy(dirInfo.DirLen) and dirInfo.DirLen or (perl.length(dataPt) - dirStart)
        if dirLen > 0 then exifData = substr(dataPt, dirStart, dirLen) end
        if perlTruthy(self.OPTIONS.Verbose) and perl.length(self.INDENT) > 2 then self:VerboseDir('TIFF') end
    end
    if exifData == nil then
        -- set default byte order for creating new GPS in CR3 images
        local defaultByteOrder
        if dirInfo.DirName and dirInfo.DirName == 'GPS' then
            defaultByteOrder = self.SaveExifByteOrder
        end
        -- create TIFF information from scratch
        if Writer.SetPreferredByteOrder(self, defaultByteOrder) == 'MM' then
            exifData = "MM\0\x2a\0\0\0\x08"
        else
            exifData = "II\x2a\0\x08\0\0\0"
        end
    end
    local savedOrder = ExifTool.GetByteOrder()
    -- set byte ordering
    local byteOrder = substr(exifData,0,2)
    if not ExifTool.SetByteOrder(byteOrder) then return nil end
    -- verify the byte ordering
    local identifier = Get16u(exifData, 2)
    if fileType == 'APP1' and identifier ~= 0x2a then self:Warn('Invalid magic number in EXIF TIFF header') end
    -- get offset to IFD0
    if perl.length(exifData) < 8 then ExifTool.SetByteOrder(savedOrder); return nil end
    local offset = Get32u(exifData, 4)
    if offset < 8 then ExifTool.SetByteOrder(savedOrder); return nil end
    -- (accommodate CR3 images which have a TIFF directory with ExifIFD at the top level)
    local ifdName = 'IFD0'
    if dirInfo.DirName and isMatch(dirInfo.DirName, [[^(ExifIFD|GPS)$]]) then ifdName = dirInfo.DirName end
    if not tagTablePtr or tagTablePtr.GROUPS[0] == 'EXIF' then
        self.ExifByteOrder = byteOrder
    elseif tagTablePtr.GROUPS[0] == 'MakerNotes' then -- (for writing CR3 maker notes)
        ifdName = tagTablePtr.GROUPS[0]
    else
        ifdName = tagTablePtr.GROUPS[1]
    end
    -- remember where we found the TIFF data (APP1, APP3, TIFF, NEF, etc...)
    self.TIFF_TYPE = fileType
    -- get reference to the main EXIF table
    tagTablePtr = tagTablePtr or self:GetTagTable('lexiftool.Exif.Main')
--
-- rewrite the image
--
    if dirInfo.NoTiffEnd then
        self.TIFF_END = nil
    else
        -- initialize TIFF_END so it will be updated by WriteExif()
        self.TIFF_END = 0
    end
    -- write TIFF header (8 bytes [plus optional signature] followed by IFD)
    local otherSig = (fileType == 'EXIF') and 'ExifMeta' or '' -- force this signature for all EXIF files
    local hdrOffset = 8 + perl.length(otherSig)
    -- construct tiff header
    local header = carray.new('char'):append(substr(exifData, 0, 4), ExifTool.Put32u(hdrOffset), otherSig)
    local subdirInfo = {
        Base     = base,
        DataPt   = exifData,
        DataLen  = perl.length(exifData),
        DataPos  = 0,
        DirStart = offset,
        DirLen   = perl.length(exifData) - offset,
        DirName  = ifdName,
        Parent   = fileType,
        ImageData= 'Main', -- set flag to get information to copy main image data later
        Multi    = dirInfo.Multi,
        NewDataPos = hdrOffset,
        HeaderPtr = header,
    }
    local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
    local buff = ''
    if newData ~= nil and perl.length(newData) > 0 then
        -- update header length in case more was added
        local hdrLen = perl.length(header)
        if hdrLen ~= 8 then
            ExifTool.Set32u(header, 4, hdrLen)
            -- also update preview fixup if necessary
            local pi = self.PREVIEW_INFO
            if pi and pi.Fixup then pi.Fixup.Start = pi.Fixup.Start + hdrLen - 8 end
        end
        buff = header:tostring() .. newData
    end
    ExifTool.SetByteOrder(savedOrder)
    self.TIFF_END = nil
    if newData == nil then return nil end
    return buff
end

--------------------------------------------------------------------------------
-- get current position in output file (or end of file if a scalar reference)
-- Inputs: 0) file or scalar reference
-- Returns: Current position or -1 on error
-- (a GLOB is an io file here, a scalar reference the port's box
--  `{ value = <carray> }`, doc/api.md §4)
function Writer.Tell(outfile)
    if io.type(outfile) == 'file' then
        return perl.tell(outfile)
    else
        return perl.length(outfile.value)
    end
end

--------------------------------------------------------------------------------
-- write to file or memory
-- Inputs: 0) file or scalar reference, 1-N) list of stuff to write
-- Returns: true on success
-- (the scalar behind the reference is a carray, so `.=` appends in place;
--  a carray among the arguments is written as its bytes)
function Writer.Write(outfile, ...)
    if io.type(outfile) == 'file' then
        -- (perl.print stringifies a carray to its bytes and returns 1 or '')
        return perl.print(outfile, ...) == 1
    elseif type(outfile) == 'table' then
        local buf = outfile.value
        if buf == nil then  -- (`.=` on undef starts an empty string)
            buf = carray.new('char')
            outfile.value = buf
        end
        for k = 1, select('#', ...) do
            local v = select(k, ...)
            -- (join stringifies; a number must not reach append as a byte)
            if type(v) ~= 'string' and not perl.isCarray(v) then v = perlStr(v) end
            buf:append(v)
        end
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Write trailer buffer to file (applying fixups if necessary)
-- Inputs: 0) ExifTool object ref, 1) trailer dirInfo ref, 2) output file ref
-- Returns: 1 on success
function Writer.WriteTrailerBuffer(self, trailInfo, outfile)
    if self.DEL_GROUP.Trailer then
        self:VPrint(0, '  Deleting trailer (' .. perlStr(trailInfo.Offset) .. " bytes)\n")
        self.CHANGED = (self.CHANGED or 0) + 1
        return 1
    end
    local pos = Writer.Tell(outfile)
    local trailPt = trailInfo.OutFile
    -- apply fixup if necessary (AFCP requires this)
    if trailInfo.Fixup then
        if pos > 0 then
            -- shift offsets to final AFCP location and write it out
            trailInfo.Fixup.Shift = trailInfo.Fixup.Shift + pos
            trailInfo.Fixup:ApplyFixup(trailPt.value)
        else
            self:Error("Can't get file position for trailer offset fixup", 1)
        end
    end
    return Writer.Write(outfile, trailPt.value)
end

--------------------------------------------------------------------------------
-- Add trailers as a block
-- Inputs: 0) ExifTool object ref, 1) [optional] trailer data raf,
--         1 or 2-N) trailer types to add (or none to add all)
-- Returns: new trailer ref, or undef
-- - increments CHANGED if trailer was added
-- (a trailer ref is the port's scalar box { value = <carray> })
function Writer.AddNewTrailers(self, ...)
    local args = table.pack(...)
    local trailPt
    local i = 1
    if type(args[1]) == 'table' then trailPt = args[1]; i = 2 end
    if not perlTruthy(args[i]) then i = i + 1 end -- (in case undef data ref is passed)
    local types = { }
    for k = i, args.n do types[#types + 1] = args[k] end
    -- add all possible trailers if none specified (currently only CanonVRD)
    if #types == 0 then types = { 'CanonVRD', 'CanonDR4' } end
    -- add trailers as a block (if not done already)
    for _, type_ in ipairs(types) do
        if not (self.NEW_VALUE and self.NEW_VALUE[ExifTool.Extra[type_]]) then goto nextType end
        if self['Did' .. type_] then goto nextType end
        do
            local val = self:GetNewValue(type_)
            if not perlTruthy(val) then goto nextType end
            -- DR4 record must be wrapped in VRD trailer package
            if type_ == 'CanonDR4' then
                if self.DidCanonVRD then goto nextType end    -- (only allow one VRD trailer)
                val = require('lexiftool.CanonVRD').WrapDR4(val)
                self.DidCanonVRD = 1
            end
            local verb = trailPt and 'Writing' or 'Adding'
            self:VPrint(0, '  ' .. verb .. ' ' .. type_ .. " as a block\n")
            if trailPt then
                trailPt.value:append(val)
            else
                trailPt = { value = carray.new('char'):append(val) }
            end
            self['Did' .. type_] = 1
            self.CHANGED = (self.CHANGED or 0) + 1
        end
        ::nextType::
    end
    return trailPt
end

--------------------------------------------------------------------------------
-- Write segment, splitting up into multiple segments if necessary
-- Inputs: 0) file or scalar reference, 1) segment marker
--         2) segment header, 3) segment data ref, 4) segment type
-- Returns: number of segments written, or 0 on error
-- Notes: Writes a single empty segment if data is empty
function Writer.WriteMultiSegment(outfile, marker, header, dataPt, type_)
    if not perlTruthy(type_) then type_ = '' end
    local len = perl.length(dataPt)
    local hdr = "\xff" .. perl.chr(marker)
    local count = 0
    local maxLen = maxSegmentLen - perl.length(header)
    if type_ == 'ICC' then maxLen = maxLen - 2 end -- leave room for segment counters
    local num = perl.int((len + maxLen - 1) / maxLen)  -- number of segments to write
    local n = 0
    -- write data, splitting into multiple segments if necessary
    -- (each segment gets its own header)
    while true do
        count = count + 1
        local size = len - n
        if size > maxLen then
            size = maxLen
            -- avoid starting an Extended EXIF segment with a valid TIFF header
            -- (because we would interpret that as a separate EXIF segment)
            if type_ == 'EXIF' and n + maxLen <= len - 4 and
                isMatch(substr(dataPt, n + maxLen, 4), [[^(MM\0\x2a|II\x2a\0)]])
            then
                size = size - 1
            end
        end
        local buff = substr(dataPt, n, size)
        n = n + size
        size = size + perl.length(header)
        if type_ == 'ICC' then
            buff = perl.pack('CC', count, num) .. buff
            size = size + 2
        end
        -- write the new segment with appropriate header
        local segHdr = hdr .. perl.pack('n', size + 2)
        if not Writer.Write(outfile, segHdr, header, buff) then return 0 end
        if n >= len then break end
    end
    return count
end

--------------------------------------------------------------------------------
-- Write XMP segment(s) to JPEG file
-- Inputs: 0) ExifTool object ref, 1) outfile ref, 2) XMP data ref,
--         3) extended XMP data ref, 4) 32-char extended XMP GUID (or undef if no extended data)
-- Returns: true on success, false on write error
function Writer.WriteMultiXMP(self, outfile, dataPt, extPt, guid)
    local success = 1

    -- write main XMP segment
    local size = perl.length(dataPt) + perl.length(ExifTool.xmpAPP1hdr)
    if size > maxXMPLen then
        self:Error('XMP block too large for JPEG segment! (' .. size .. ' bytes)', 1)
        return 1
    end
    local app1hdr = "\xff\xe1" .. perl.pack('n', size + 2)
    if not Writer.Write(outfile, app1hdr, ExifTool.xmpAPP1hdr, dataPt) then success = 0 end
    -- write extended XMP segment(s) if necessary
    if guid ~= nil then
        size = perl.length(extPt)
        local maxLen = maxXMPLen - 75 -- maximum size without 75-byte header
        local off = 0
        while off < size do
            -- header(75) = signature(35) + guid(32) + size(4) + offset(4)
            local len = size - off
            if len > maxLen then len = maxLen end
            app1hdr = "\xff\xe1" .. perl.pack('n', len + 75 + 2)
            self:VPrint(0, 'Writing extended XMP segment (' .. len .. " bytes)\n")
            if not Writer.Write(outfile, app1hdr, ExifTool.xmpExtAPP1hdr, guid, perl.pack('N2', size, off),
                  substr(extPt, off, len)) then success = 0 end
            off = off + maxLen
        end
    end
    return success
end

--------------------------------------------------------------------------------
-- WriteJPEG : Write JPEG image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JPEG file, or -1 if
--          an output file was specified and a write error occurred
-- luacheck: push ignore 311
function Writer.WriteJPEG(self, dirInfo)
    local outfile = dirInfo.OutFile
    local raf = dirInfo.RAF
    local ch, s, length, err, isEXV, creatingEXV
    local doneDir = { }
    local verbose = self.OPTIONS.Verbose
    local out = self.OPTIONS.TextOut or io.stdout
    local rtnVal = 0
    local writeBuffer, oldOutfile -- used to buffer writing until PreviewImage position is known
    local n

    -- check to be sure this is a valid JPG or EXV file
    n, s = raf:Read(2)
    if not (n == 2 and s == "\xff\xd8") then
        if s ~= nil and perl.length(s) > 0 then
            if s ~= "\xff\x01" then return 0 end
            n, s = raf:Read(5)
            if not (n == 5 and s == 'Exiv2') then return 0 end
        else
            if self.FILE_TYPE ~= 'EXV' then return 0 end
            s = 'Exiv2'
            creatingEXV = 1
        end
        if not Writer.Write(outfile, "\xff\x01") then err = 1 end
        isEXV = 1
    end

    self.PREVIEW_INFO = nil   -- reset preview information
    self.DEL_PREVIEW = nil    -- reset flag to delete preview

    if not Writer.Write(outfile, s) then err = 1 end
    -- figure out what segments we need to write for the tags we have set
    local addDirs = self.ADD_DIRS
    local editDirs = self.EDIT_DIRS
    local delGroup = self.DEL_GROUP
    local path = self.PATH
    local pn = #path

    -- set input record separator to 0xff (the JPEG marker) to make reading quicker
    -- (Perl's `local $/ = "\xff"`; ReadLine and chomp take it as an argument)
    local rs = "\xff"
--
-- pre-scan image to determine if any create-able segment already exists
--
    local pos = raf:Tell()
    local marker
    local dirOrder, dirCount = { }, { }
    -- (Prescan:)
    while true do
        -- read up to next marker (JPEG markers begin with 0xff)
        n, s = raf:ReadLine(rs)
        if not perlTruthy(n) then break end
        -- JPEG markers can be padded with unlimited 0xff's
        while true do
            n, ch = raf:Read(1)
            if not perlTruthy(n) then goto lastPrescan end
            marker = perl.ord(ch)
            if marker ~= 0xff then break end
        end
        do
            local dirName
            -- stop pre-scan at SOS (end of meta information) or EOI (end of image)
            if marker == 0xda or marker == 0xd9 then
                dirName = ExifTool.jpegMarker[marker]
                dirOrder[#dirOrder + 1] = dirName
                dirCount[dirName] = 1
                break
            end
            -- handle SOF markers: SOF0-SOF15, except DHT(0xc4), JPGA(0xc8) and DAC(0xcc)
            if (marker & 0xf0) == 0xc0 and (marker == 0xc0 or (marker & 0x03) ~= 0) then
                if not raf:Seek(7, 1) then break end
            -- read data for all markers except stand-alone
            -- markers 0x00, 0x01 and 0xd0-0xd7 (NULL, TEM, RST0-RST7)
            elseif marker ~= 0x00 and marker ~= 0x01 and (marker < 0xd0 or marker > 0xd7) then
                -- read record length word
                n, s = raf:Read(2)
                if n ~= 2 then break end
                local len = perl.unpack('n', s)   -- get data length
                if not (len ~= nil and len >= 2) then break end
                len = len - 2  -- subtract size of length word
                if (marker & 0xf0) == 0xe0 then  -- is this an APP segment?
                    local nn = len < 64 and len or 64
                    n, s = raf:Read(nn)
                    if n ~= nn then break end
                    len = len - nn
                    -- Note: only necessary to recognize APP segments that we can create,
                    -- or delete as a group (and the names below should match @delGroups)
                    if marker == 0xe0 then
                        if isMatch(s, [[^JFIF\0]]) then dirName = 'JFIF' end
                        if isMatch(s, [[^JFXX\0\x10]]) then dirName = 'JFXX' end
                        if isMatch(s, [[(?s)^(II|MM).{4}HEAPJPGM]]) then dirName = 'CIFF' end
                    elseif marker == 0xe1 then
                        local ok, junk, bytes = isMatch(s, [[(?is)^(.{0,4})Exif\0.(.{1,4})]])
                        if ok then
                            dirName = 'IFD0'
                            -- support multi-segment EXIF
                            if #dirOrder > 0 and isMatch(dirOrder[#dirOrder], [[^(IFD0|ExtendedEXIF)$]]) and
                                perl.length(junk) == 0 and not isMatch(bytes, [[^(MM\0\x2a|II\x2a\0)]])
                            then
                                dirName = 'ExtendedEXIF'
                            end
                        end
                        if isMatchDyn(s, '^' .. xmpAPP1hdr) then dirName = 'XMP' end
                        if isMatchDyn(s, '^' .. xmpExtAPP1hdr) then dirName = 'XMP' end
                    elseif marker == 0xe2 then
                        if isMatch(s, [[^ICC_PROFILE\0]]) then dirName = 'ICC_Profile' end
                        if isMatch(s, [[^FPXR\0]]) then dirName = 'FlashPix' end
                        if isMatch(s, [[^MPF\0]]) then dirName = 'MPF' end
                    elseif marker == 0xe3 then
                        if isMatch(s, [[^(Meta|META|Exif)\0\0]]) then dirName = 'Meta' end
                    elseif marker == 0xe5 then
                        if isMatch(s, [[^RMETA\0]]) then dirName = 'RMETA' end
                    elseif marker == 0xea then
                        if isMatch(s, [[^AROT\0\0]]) then dirName = 'AROT' end
                    elseif marker == 0xeb then
                        if isMatch(s, [[^JP]]) then dirName = 'JUMBF' end
                    elseif marker == 0xec then
                        if isMatch(s, [[^Ducky]]) then dirName = 'Ducky' end
                    elseif marker == 0xed then
                        if isMatchDyn(s, '^' .. psAPP13hdr) then dirName = 'Photoshop' end
                    elseif marker == 0xee then
                        if isMatch(s, [[^Adobe]]) then dirName = 'Adobe' end
                    end
                    -- initialize doneDir as a flag that the directory exists
                    -- (unless we are deleting it anyway)
                    if dirName ~= nil and not delGroup[dirName] then doneDir[dirName] = 0 end
                end
                if not raf:Seek(len, 1) then break end
            end
            if not dirName then dirName = ExifTool.JpegMarkerName(marker) end
            dirCount[dirName] = (dirCount[dirName] or 0) + 1
            dirOrder[#dirOrder + 1] = dirName
        end
    end
    ::lastPrescan::
    if not (marker and marker == 0xda) then
        if not isEXV then self:Error('Corrupted JPEG image') return 1 end
        if marker and marker ~= 0xd9 then self:Error('Corrupted EXV file') return 1 end
    end
    if not raf:Seek(pos, 0) then self:Error('Seek error') return 1 end
--
-- re-write the image
--
    local combinedSegData, segPos, firstSegPos
    local extendedXMP = { }
    local iccChunk, iccChunkCount, iccChunksTotal = { }, nil, nil
    -- read through each segment in the JPEG file
    -- (Marker:)
    while true do

        -- read up to next marker (JPEG markers begin with 0xff)
        local segJunk
        n, segJunk = raf:ReadLine(rs)
        if not perlTruthy(n) then segJunk = '' end
        -- remove the 0xff but write the rest of the junk up to this point
        -- (this will handle the data after the first 7 bytes of SOF segments)
        segJunk = perl.chomp(segJunk, rs)
        if perl.length(segJunk) > 0 then Writer.Write(outfile, segJunk) end
        -- JPEG markers can be padded with unlimited 0xff's
        while true do
            n, ch = raf:Read(1)
            if perlTruthy(n) then
                marker = perl.ord(ch)
                if marker ~= 0xff then break end
            elseif creatingEXV then
                -- create EXV from scratch
                marker = 0xd9 -- EOI
                dirOrder[#dirOrder + 1] = 'EOI'
                dirCount.EOI = 1
                break
            else
                self:Error('Format error')
                return 1
            end
        end
        -- read the segment data
        local segData
        -- handle SOF markers: SOF0-SOF15, except DHT(0xc4), JPGA(0xc8) and DAC(0xcc)
        if (marker & 0xf0) == 0xc0 and (marker == 0xc0 or (marker & 0x03) ~= 0) then
            n, segData = raf:Read(7)
            if n ~= 7 then break end
        -- read data for all markers except stand-alone
        -- markers 0x00, 0x01 and 0xd0-0xd7 (NULL, TEM, EOI, RST0-RST7)
        elseif marker ~= 0x00 and marker ~= 0x01 and marker ~= 0xd9 and
            (marker < 0xd0 or marker > 0xd7)
        then
            -- read record length word
            n, s = raf:Read(2)
            if n ~= 2 then break end
            local len = perl.unpack('n', s)   -- get data length
            if not (len ~= nil and len >= 2) then break end
            segPos = raf:Tell()
            len = len - 2  -- subtract size of length word
            n, segData = raf:Read(len)
            if n ~= len then break end
        end
        -- initialize variables for this segment
        local hdr = "\xff" .. perl.chr(marker)    -- segment header
        local markerName = ExifTool.JpegMarkerName(marker)
        local dirName = remove(dirOrder, 1)      -- get directory name
--
-- create all segments that must come before this one
-- (nothing comes before SOI or after SOS)
--
        while markerName ~= 'SOI' do -- luacheck: ignore 512
            if addDirs.JFIF ~= nil and doneDir.JFIF == nil then
                doneDir.JFIF = 1
                if doneDir.Adobe ~= nil then
                    -- JFIF overrides Adobe APP14 colour components, so don't allow this
                    -- (ref https://docs.oracle.com/javase/8/docs/api/javax/imageio/metadata/doc-files/jpeg_metadata.html)
                    self:Warn('Not creating JFIF in JPEG with Adobe APP14')
                else
                    if perlTruthy(verbose) then
                        out:write("Creating APP0:\n")
                        out:write("  Creating JFIF with default values\n")
                    end
                    local jfif = "\x01\x02\x01\0\x48\0\x48\0\0"
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.JFIF.Main')
                    local subdirInfo = {
                        DataPt   = jfif,
                        DirStart = 0,
                        DirLen   = perl.length(jfif),
                        Parent   = 'JFIF',
                    }
                    -- must temporarily remove JFIF from DEL_GROUP so we can
                    -- delete JFIF and add it back again in a single step
                    local delJFIF = delGroup.JFIF
                    delGroup.JFIF = nil
                    path[pn + 1] = 'JFIF'
                    local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                    if delJFIF ~= nil then delGroup.JFIF = delJFIF end
                    -- (port: WriteBinaryData returns undef when it changed
                    --  nothing, where upstream returns the unchanged block)
                    if newData == nil then newData = jfif end
                    if newData ~= nil and perl.length(newData) > 0 then
                        local app0hdr = "\xff\xe0" .. perl.pack('n', perl.length(newData) + 7)
                        if not Writer.Write(outfile, app0hdr, "JFIF\0", newData) then err = 1 end
                    end
                end
            end
            -- don't create anything before APP0 or APP1 EXIF (containing IFD0)
            if markerName == 'APP0' or perlTruthy(dirCount.IFD0) or perlTruthy(dirCount.ExtendedEXIF) then break end
            -- EXIF information must come immediately after APP0
            if addDirs.IFD0 ~= nil and doneDir.IFD0 == nil then
                doneDir.IFD0 = 1
                if perlTruthy(verbose) then out:write("Creating APP1:\n") end
                -- write new EXIF data
                self.TIFF_TYPE = 'APP1'
                local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Exif.Main')
                local subdirInfo = {
                    DirName = 'IFD0',
                    Parent  = 'APP1',
                }
                path[pn + 1] = 'APP1'
                local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr, Writer.WriteTIFF)
                if buff ~= nil and perl.length(buff) > 0 then
                    if perl.length(buff) + perl.length(exifAPP1hdr) > maxSegmentLen then
                        if perlTruthy(self:Options('NoMultiExif')) then
                            self:Error('EXIF is too large for JPEG segment')
                        else
                            self:Warn('Creating multi-segment EXIF', 1)
                        end
                    end
                    -- switch to buffered output if required
                    if (self.PREVIEW_INFO or self.LeicaTrailer or self.HiddenData) and
                        not oldOutfile
                    then
                        writeBuffer = { value = carray.new('char') }
                        oldOutfile = outfile
                        outfile = writeBuffer
                        -- must account for segment, EXIF and TIFF headers
                        for _, k in ipairs({ 'PREVIEW_INFO', 'LeicaTrailer', 'HiddenData' }) do
                            if self[k] then self[k].Fixup.Start = self[k].Fixup.Start + 18 end
                        end
                    end
                    -- write as multi-segment
                    local nSeg = Writer.WriteMultiSegment(outfile, 0xe1, exifAPP1hdr, buff, 'EXIF')
                    if not perlTruthy(nSeg) then
                        err = 1
                    elseif nSeg > 1 and oldOutfile then
                        -- (punt on this because updating the pointers would be a real pain)
                        self:Error("Can't write multi-segment EXIF with external pointers")
                    end
                    self.CHANGED = (self.CHANGED or 0) + 1
                end
            end
            -- APP13 Photoshop segment next
            if perlTruthy(dirCount.Photoshop) then break end
            if addDirs.Photoshop ~= nil and doneDir.Photoshop == nil then
                doneDir.Photoshop = 1
                if perlTruthy(verbose) then out:write("Creating APP13:\n") end
                -- write new APP13 Photoshop record to memory
                local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Photoshop.Main')
                local subdirInfo = {
                    Parent = 'APP13',
                }
                path[pn + 1] = 'APP13'
                local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                if buff ~= nil and perl.length(buff) > 0 then
                    if not perlTruthy(Writer.WriteMultiSegment(outfile, 0xed, psAPP13hdr, buff)) then err = 1 end
                    self.CHANGED = (self.CHANGED or 0) + 1
                end
            end
            -- then APP1 XMP segment
            if perlTruthy(dirCount.XMP) then break end
            if addDirs.XMP ~= nil and doneDir.XMP == nil then
                doneDir.XMP = 1
                if perlTruthy(verbose) then out:write("Creating APP1:\n") end
                -- write new XMP data
                local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.XMP.Main')
                local subdirInfo = {
                    Parent      = 'APP1',
                    -- specify MaxDataLen so XMP is split if required
                    MaxDataLen  = maxXMPLen - perl.length(xmpAPP1hdr),
                }
                path[pn + 1] = 'APP1'
                local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                if buff ~= nil and perl.length(buff) > 0 then
                    if not perlTruthy(Writer.WriteMultiXMP(self, outfile, buff, subdirInfo.ExtendedXMP,
                                  subdirInfo.ExtendedGUID)) then err = 1 end
                end
            end
            -- then APP2 ICC_Profile segment
            if perlTruthy(dirCount.ICC_Profile) then break end
            if addDirs.ICC_Profile ~= nil and doneDir.ICC_Profile == nil then
                doneDir.ICC_Profile = 1
                if delGroup.ICC_Profile and delGroup.ICC_Profile ~= 2 then goto nextCreate end
                if perlTruthy(verbose) then out:write("Creating APP2:\n") end
                -- write new ICC_Profile data
                local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.ICC_Profile.Main')
                local subdirInfo = {
                    Parent   = 'APP2',
                }
                path[pn + 1] = 'APP2'
                local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                if buff ~= nil and perl.length(buff) > 0 then
                    if not perlTruthy(Writer.WriteMultiSegment(outfile, 0xe2, "ICC_PROFILE\0", buff, 'ICC')) then err = 1 end
                    self.CHANGED = (self.CHANGED or 0) + 1
                end
            end
            -- then APP12 Ducky segment
            if perlTruthy(dirCount.Ducky) then break end
            if addDirs.Ducky ~= nil and doneDir.Ducky == nil then
                doneDir.Ducky = 1
                if perlTruthy(verbose) then out:write("Creating APP12 Ducky:\n") end
                -- write new Ducky segment data
                local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.APP12.Ducky')
                local subdirInfo = {
                    Parent   = 'APP12',
                }
                path[pn + 1] = 'APP12'
                local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                if buff ~= nil and perl.length(buff) > 0 then
                    local size = perl.length(buff) + 5
                    if size <= maxSegmentLen then
                        -- write the new segment with appropriate header
                        local app12hdr = "\xff\xec" .. perl.pack('n', size + 2)
                        if not Writer.Write(outfile, app12hdr, 'Ducky', buff) then err = 1 end
                    else
                        self:Warn('APP12 Ducky segment too large! (' .. size .. ' bytes)')
                    end
                end
            end
            -- then APP14 Adobe segment
            if perlTruthy(dirCount.Adobe) then break end
            if addDirs.Adobe ~= nil and doneDir.Adobe == nil then
                doneDir.Adobe = 1
                local buff = self:GetNewValue('Adobe')
                if perlTruthy(buff) then
                    if perlTruthy(verbose) then out:write("Creating APP14:\n  Creating Adobe segment\n") end
                    local size = perl.length(buff)
                    if size <= maxSegmentLen then
                        -- write the new segment with appropriate header
                        local app14hdr = "\xff\xee" .. perl.pack('n', size + 2)
                        if not Writer.Write(outfile, app14hdr, buff) then err = 1 end
                        self.CHANGED = (self.CHANGED or 0) + 1
                    else
                        self:Warn('APP14 Adobe segment too large! (' .. size .. ' bytes)')
                    end
                end
            end
            -- finally, COM segment
            if perlTruthy(dirCount.COM) then break end
            if addDirs.COM ~= nil and doneDir.COM == nil then
                doneDir.COM = 1
                if delGroup.File and delGroup.File ~= 2 then goto nextCreate end
                local newComment = self:GetNewValue('Comment')
                if newComment ~= nil then
                    if perlTruthy(verbose) then
                        out:write("Creating COM:\n")
                        Writer.VerboseValue(self, '+ Comment', newComment)
                    end
                    if not perlTruthy(Writer.WriteMultiSegment(outfile, 0xfe, '', newComment)) then err = 1 end
                    self.CHANGED = (self.CHANGED or 0) + 1
                end
            end
            break   -- didn't want to loop anyway
            ::nextCreate::
        end
        path[pn + 1] = markerName
        -- decrement counter for this directory since we are about to process it
        dirCount[dirName] = (dirCount[dirName] or 0) - 1
--
-- rewrite existing segments
--
        -- handle SOF markers: SOF0-SOF15, except DHT(0xc4), JPGA(0xc8) and DAC(0xcc)
        if (marker & 0xf0) == 0xc0 and (marker == 0xc0 or (marker & 0x03) ~= 0) then
            if perlTruthy(verbose) then out:write('JPEG ' .. markerName .. ":\n") end
            if not Writer.Write(outfile, hdr, segData) then err = 1 end
            goto nextMarker
        elseif marker == 0xda then             -- SOS
            path[#path] = nil
            if perlTruthy(verbose) then out:write("JPEG SOS\n") end
            -- write SOS segment
            s = perl.pack('n', perl.length(segData) + 2)
            if not Writer.Write(outfile, hdr, s, segData) then err = 1 end
            local buff, endPos, trailInfo
            local delPreview = self.DEL_PREVIEW
            if not delGroup.Trailer then trailInfo = self:IdentifyTrailer(raf) end
            local nvTrail = Writer.GetNewValueHash(self, ExifTool.Extra.Trailer)
            if not (oldOutfile or delPreview or trailInfo or delGroup.Trailer or
                nvTrail or self.HiddenData)
            then
                -- blindly copy the rest of the file
                while true do
                    n, buff = raf:Read(65536)
                    if not perlTruthy(n) then break end
                    if not Writer.Write(outfile, buff) then err = 1 break end
                end
                rtnVal = 1  -- success unless we have a file write error
                break       -- all done
            end
            -- write the rest of the image (as quickly as possible) up to the EOI
            local endedWithFF
            while true do
                n, buff = raf:Read(65536)
                if not perlTruthy(n) then goto lastMarker end
                -- (m//g, then pos(): the offset just after the match)
                local m, mpos
                if endedWithFF == 1 then m, mpos = matches(buff, [[^\xd9]]) end
                if not m then m, mpos = matches(buff, [[\xff\xd9]]) end
                if m then
                    rtnVal = 1 -- the JPEG is OK
                    -- write up to the EOI
                    if not Writer.Write(outfile, substr(buff, 0, mpos)) then err = 1 end
                    buff = substr(buff, mpos)
                    break
                end
                if n ~= 65536 then
                    self:Error('JPEG EOI marker not found')
                    goto lastMarker
                end
                if not Writer.Write(outfile, buff) then err = 1 end
                endedWithFF = substr(buff, 65535, 1) == "\xff" and 1 or 0
            end
            -- remember position of last data copied
            endPos = raf:Tell() - perl.length(buff)
            self.TrailerStart = endPos
            -- write new trailer if specified
            if nvTrail then
                -- access new value directly to avoid copying a potentially very large data block
                if nvTrail.Value and perlTruthy(nvTrail.Value[1]) then -- (note: "0" will also delete the trailer)
                    self:VPrint(0, '  Writing new trailer')
                    if not Writer.Write(outfile, nvTrail.Value[1]) then err = 1 end
                    self.CHANGED = (self.CHANGED or 0) + 1
                elseif raf:Seek(0, 2) and raf:Tell() ~= endPos then
                    self:VPrint(0, '  Deleting trailer (', raf:Tell() - endPos, ' bytes)')
                    self.CHANGED = (self.CHANGED or 0) + 1  -- changed if there was previously a trailer
                end
                break   -- all done
            end
            -- rewrite existing trailers into buffer
            if trailInfo then
                local tbuf = carray.new('char')
                raf:Seek(-perl.length(buff), 1)  -- seek back to just after EOI
                trailInfo.OutFile = { value = tbuf }  -- rewrite the trailer
                trailInfo.ScanForTrailer = 1     -- scan if necessary
                if not perlTruthy(self:ProcessTrailers(trailInfo)) then trailInfo = nil end
            end
            if oldOutfile then
                local previewInfo
                -- copy HiddenData if necessary
                if self.HiddenData then
                    local pad
                    local hd = self.HiddenData
                    local hdOff = hd.Offset + hd.Base
                    -- read HiddenData, updating $hdOff with actual offset if necessary
                    local dataPt
                    dataPt, hdOff = require('lexiftool.Sony').ReadHiddenData(self, hdOff, hd.Size)
                    if dataPt then
                        -- preserve padding to avoid invalidating MPF pointers (yuk!)
                        local padLen = hdOff - endPos
                        local nr
                        if padLen >= 0 and raf:Seek(endPos, 0) then nr, pad = raf:Read(padLen) end
                        if not (nr ~= nil and nr == padLen) then
                            self:Error('Error reading HiddenData padding', 1)
                            pad = ''
                        end
                        endPos = endPos + perl.length(pad) + perl.length(dataPt) -- update end position
                    else
                        dataPt, pad = '', ''
                    end
                    local fixup = self.HiddenData.Fixup
                    -- set MakerNote pointer and size (subtract 10 for segment and EXIF headers)
                    fixup:SetMarkerPointers(outfile.value, 'HiddenData', perl.length(outfile.value) + perl.length(pad) - 10)
                    Writer.Write(writeBuffer, pad, dataPt)   -- keep padding for now
                end
                if self.LeicaTrailer then
                    local trailLen
                    if trailInfo then
                        trailLen = (trailInfo.DataPos or 0) - endPos    -- (undef DataPos numifies to 0)
                    else
                        if not raf:Seek(0, 2) then err = 1 end
                        trailLen = raf:Tell() - endPos
                    end
                    local fixup = self.LeicaTrailer.Fixup
                    self.LeicaTrailer.TrailPos = endPos
                    self.LeicaTrailer.TrailLen = trailLen
                    -- get _absolute_ position of new Leica trailer
                    local absPos = Writer.Tell(oldOutfile) + perl.length(outfile.value)
                    local dat = require('lexiftool.Panasonic').ProcessLeicaTrailer(self, absPos)
                    -- allow some junk before Leica trailer (just in case)
                    local junk = perl.num(self.LeicaTrailerPos) - endPos
                    -- set MakerNote pointer and size (subtract 10 for segment and EXIF headers)
                    fixup:SetMarkerPointers(outfile.value, 'LeicaTrailer', perl.length(outfile.value) - 10 + junk)
                    -- use this fixup to set the size too (sneaky)
                    -- (`$$self{LeicaTrailer}{Size}` autovivifies the hash that
                    --  ProcessLeicaTrailer deleted)
                    if self.LeicaTrailer == nil then self.LeicaTrailer = {} end
                    local trailSize = dat ~= nil and perl.length(dat) - junk or self.LeicaTrailer.Size
                    fixup.Start = fixup.Start - 4;  fixup.Shift = fixup.Shift + 4
                    if trailSize ~= nil then fixup:SetMarkerPointers(outfile.value, 'LeicaTrailer', trailSize) end
                    fixup.Start = fixup.Start + 4;  fixup.Shift = fixup.Shift - 4
                    if dat ~= nil then
                        if not Writer.Write(outfile, dat) then err = 1 end  -- write new Leica trailer
                        delPreview = 1                                      -- delete existing Leica trailer
                    end
                end
                -- handle preview image last
                if self.PREVIEW_INFO then
                    -- locate preview image and fix up preview offsets
                    local scanLen = isMatch(self.Make or '', '(?i)^SONY') and 65536 or 1024
                    if perl.length(buff) < scanLen then -- make sure we have enough trailer to scan
                        local nr, buf2 = raf:Read(scanLen - perl.length(buff))
                        if perlTruthy(nr) then buff = buff .. buf2 end
                    end
                    -- get new preview image position, relative to EXIF base
                    local newPos = perl.length(outfile.value) - 10 -- (subtract 10 for segment and EXIF headers)
                    local junkLen
                    -- adjust position if image isn't at the start (eg. Olympus E-1/E-300)
                    local jpegHdr, segLen, mpos = matches(buff, [[(?s)(\xff\xd8\xff.|.\xd8\xff\xdb)(..)]])
                    if jpegHdr then
                        junkLen = mpos - 6
                        -- Sony previewimage trailer has a 32 byte header
                        if isMatch(self.Make or '', '(?i)^SONY') and junkLen > 32 then
                            -- with some newer Sony models, the makernotes preview pointer
                            -- points to JPEG at end of EXIF inside MPImage preview (what a pain!)
                            if jpegHdr == "\xff\xd8\xff\xe1" then   -- is the first segment EXIF?
                                segLen = perl.unpack('n', segLen)   -- the EXIF segment length
                                -- Sony PreviewImage starts with last 2 bytes of EXIF segment
                                -- (and first byte is usually "\0", not "\xff", so don't check this)
                                if perl.length(buff) > junkLen + segLen + 6 and
                                    substr(buff, junkLen + segLen + 3, 3) == "\xd8\xff\xdb"
                                then
                                    junkLen = junkLen + segLen + 2
                                    -- (note: this will not copy the trailer after PreviewImage,
                                    --  which is a 14kB block full of zeros for the A77)
                                end
                            end
                            junkLen = junkLen - 32
                        end
                        newPos = newPos + junkLen
                    end
                    -- fix up the preview offsets to point to the start of the new image
                    previewInfo = self.PREVIEW_INFO
                    self.PREVIEW_INFO = nil
                    local fixup = previewInfo.Fixup
                    newPos = newPos + (previewInfo.BaseShift or 0)
                    -- adjust to absolute file offset if necessary (Samsung STMN)
                    if previewInfo.Absolute then newPos = newPos + Writer.Tell(oldOutfile) + 10 end
                    if previewInfo.Relative then
                        -- adjust for our base by looking at how far the pointer got shifted
                        newPos = newPos - (fixup:GetMarkerPointers(outfile.value, 'PreviewImage')[1] or 0)
                    elseif previewInfo.ChangeBase then
                        -- Leica S2 uses relative offsets for the preview only (leica sucks)
                        local makerOffset = fixup:GetMarkerPointers(outfile.value, 'LeicaTrailer')[1]
                        if perlTruthy(makerOffset) then newPos = newPos - makerOffset end
                    end
                    fixup:SetMarkerPointers(outfile.value, 'PreviewImage', newPos)
                    if previewInfo.Data ~= 'LOAD_PREVIEW' then
                        -- write any junk that existed before the preview image
                        if perlTruthy(junkLen) then previewInfo.Junk = substr(buff, 0, junkLen) end
                    end
                end
                -- clean up and write the buffered data
                outfile = oldOutfile
                oldOutfile = nil
                if not Writer.Write(outfile, writeBuffer.value) then err = 1 end
                writeBuffer = nil
                -- write preview image
                if previewInfo and previewInfo.Data ~= 'LOAD_PREVIEW' then
                    -- write any junk that existed before the preview image
                    if previewInfo.Junk ~= nil and not Writer.Write(outfile, previewInfo.Junk) then err = 1 end
                    -- write the saved preview image
                    if not Writer.Write(outfile, previewInfo.Data) then err = 1 end
                    previewInfo.Data = nil
                    -- (don't increment CHANGED because we could be rewriting existing preview)
                    delPreview = 1    -- remove old preview
                end
            end
            -- copy over preview image (or other data) if necessary
            if not delPreview then
                local extra
                if trailInfo then
                    -- copy everything up to start of first processed trailer
                    extra = trailInfo.DataPos ~= nil and (trailInfo.DataPos - endPos) or 0
                else
                    -- copy everything up to end of file
                    if not raf:Seek(0, 2) then err = 1 end
                    extra = raf:Tell() - endPos
                end
                if extra > 0 then
                    if delGroup.Trailer then
                        if perlTruthy(verbose) then out:write('  Deleting unknown trailer (' .. extra .. " bytes)\n") end
                        self.CHANGED = (self.CHANGED or 0) + 1
                    else
                        -- copy over unknown trailer
                        if perlTruthy(verbose) then out:write('  Preserving unknown trailer (' .. extra .. " bytes)\n") end
                        if not raf:Seek(endPos, 0) then err = 1 end
                        if not perlTruthy(Writer.CopyBlock(raf, outfile, extra)) then err = 1 end
                    end
                end
            end
            -- write trailer if necessary
            if trailInfo then
                if not perlTruthy(Writer.WriteTrailerBuffer(self, trailInfo, outfile)) then err = 1 end
                trailInfo = nil
            end
            break   -- all done parsing file

        elseif marker == 0xd9 and isEXV then
            -- write EXV EOI (any trailer will be lost)
            if not Writer.Write(outfile, "\xff\xd9") then err = 1 end
            rtnVal = 1
            break

        elseif marker == 0x00 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7) then
            if perlTruthy(verbose) and marker ~= 0 then out:write('JPEG ' .. markerName .. ":\n") end
            -- handle stand-alone markers 0x00, 0x01 and 0xd0-0xd7 (NULL, TEM, RST0-RST7)
            if not Writer.Write(outfile, hdr) then err = 1 end
            goto nextMarker
        end
        do
        --
        -- NOTE: A 'next' statement after this point will cause $$segDataPt
        --       not to be written if there is an output file, so in this case
        --       the $$self{CHANGED} flags must be updated
        --
        -- (the port keeps the segment data itself in segDataPt: Perl swaps
        --  references to buffers, a Lua string is swapped by assignment, and
        --  `undef $segDataPt` is nil)
        local segDataPt = segData
        length = perl.length(segData)
        if perlTruthy(verbose) then out:write('JPEG ' .. markerName .. ' (' .. length .. " bytes)\n") end
        -- group delete of APP segments
        if delGroup[dirName] then
            if perlTruthy(verbose) then out:write('  Deleting ' .. dirName .. " segment\n") end
            if dirName == 'ICC_Profile' then self:Warn('ICC_Profile deleted. Image colors may be affected') end
            self.CHANGED = (self.CHANGED or 0) + 1
            goto nextMarker
        end
        local segType, del
        -- rewrite this segment only if we are changing a tag which is contained in its
        -- directory (or deleting '*', in which case we need to identify the segment type)
        while editDirs[markerName] ~= nil or delGroup['*'] do -- luacheck: ignore 512
            if marker == 0xe0 then              -- APP0 (JFIF, CIFF)
                if isMatch(segDataPt, [[^JFIF\0]]) then
                    segType = 'JFIF'
                    if delGroup.JFIF then del = 1 break end
                    if not perlTruthy(editDirs.JFIF) then break end
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.JFIF.Main')
                    local subdirInfo = {
                        DataPt   = segDataPt,
                        DataPos  = segPos,
                        DataLen  = length,
                        DirStart = 5,     -- directory starts after identifier
                        DirLen   = length - 5,
                        Parent   = markerName,
                    }
                    local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                    if newData ~= nil and perl.length(newData) > 0 then
                        segDataPt = "JFIF\0" .. newData
                    end
                elseif isMatch(segDataPt, [[^JFXX\0\x10]]) then
                    segType = 'JFXX'
                    if delGroup.JFIF then del = 1 end
                elseif isMatch(segDataPt, [[(?s)^(II|MM).{4}HEAPJPGM]]) then
                    segType = 'CIFF'
                    if delGroup.CIFF then del = 1 break end
                    if not perlTruthy(editDirs.CIFF) then break end
                    local newData = { value = carray.new('char') }
                    local subdirInfo = {
                        RAF = require('lexiftool.RandomAccess').new(segDataPt),
                        OutFile = newData,
                    }
                    if require('lexiftool.CanonRaw').WriteCRW(self, subdirInfo) > 0 then
                        if perl.length(newData.value) > 0 then
                            segDataPt = newData.value:tostring()  -- (the readers take a string)
                        else
                            segDataPt = nil
                            del = 1   -- delete this segment
                        end
                    end
                end
            elseif marker == 0xe1 then         -- APP1 (EXIF, XMP)
                -- check for EXIF data
                local isExif, junk = isMatch(segDataPt, [[(?is)^(.{0,4})Exif\0.]])
                if isExif then
                    local hdrLen = perl.length(exifAPP1hdr)
                    if perl.length(junk) > 0 then
                        hdrLen = hdrLen + perl.length(junk)
                        self:Error('Unknown garbage at start of EXIF segment', 1)
                    elseif not isMatch(segDataPt, [[^Exif\0]]) then
                        self:Error('Incorrect EXIF segment identifier', 1)
                    end
                    segType = 'EXIF'
                    if not perlTruthy(editDirs.IFD0) then break end
                    -- add this data to the combined data if it exists
                    if combinedSegData ~= nil then
                        combinedSegData:append(substr(segDataPt, hdrLen))
                        segDataPt = combinedSegData:tostring()  -- (the readers take a string)
                        segPos = firstSegPos
                        length = perl.length(combinedSegData)  -- update length
                    end
                    -- peek ahead to see if the next segment is extended EXIF
                    if dirOrder[1] == 'ExtendedEXIF' then
                        -- initialize combined data if necessary
                        if combinedSegData == nil then
                            combinedSegData = carray.new('char'):append(segDataPt)
                            firstSegPos = segPos
                            self:Warn('File contains multi-segment EXIF', 1)
                        end
                        goto nextMarker    -- get the next segment to combine
                    end
                    if perlTruthy(doneDir.IFD0) then self:Warn('Multiple APP1 EXIF records') end
                    doneDir.IFD0 = 1
                    -- check del groups now so we can change byte order in one step
                    if delGroup.IFD0 or delGroup.EXIF then
                        doneDir.IFD0 = nil  -- delete so we will create a new one
                        del = 1
                        break
                    end
                    -- rewrite EXIF as if this were a TIFF file in memory
                    local subdirInfo = {
                        DataPt   = segDataPt,
                        DataPos  = -hdrLen, -- (remember: relative to Base!)
                        DirStart = hdrLen,
                        Base     = segPos + hdrLen,
                        Parent   = markerName,
                        DirName  = 'IFD0',
                    }
                    -- write new EXIF data to memory
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Exif.Main')
                    local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr, Writer.WriteTIFF)
                    if buff ~= nil then
                        segDataPt = buff
                    else
                        if not perlTruthy(self:Options('IgnoreMinorErrors')) then goto lastMarker end
                    end
                    -- delete segment if IFD contains no entries
                    if perl.length(segDataPt) == 0 then del = 1 break end
                    if perl.length(segDataPt) + perl.length(exifAPP1hdr) > maxSegmentLen then
                        if perlTruthy(self:Options('NoMultiExif')) then
                            self:Error('EXIF is too large for JPEG segment')
                        else
                            self:Warn('Writing multi-segment EXIF', 1)
                        end
                    end
                    -- switch to buffered output if required
                    if (self.PREVIEW_INFO or self.LeicaTrailer or self.HiddenData) and
                        not oldOutfile
                    then
                        writeBuffer = { value = carray.new('char') }
                        oldOutfile = outfile
                        outfile = writeBuffer
                        -- must account for segment, EXIF and TIFF headers
                        for _, k in ipairs({ 'PREVIEW_INFO', 'LeicaTrailer', 'HiddenData' }) do
                            if self[k] then self[k].Fixup.Start = self[k].Fixup.Start + 18 end
                        end
                    end
                    -- write as multi-segment
                    local nSeg = Writer.WriteMultiSegment(outfile, marker, exifAPP1hdr, segDataPt, 'EXIF')
                    if not perlTruthy(nSeg) then
                        err = 1
                    elseif nSeg > 1 and oldOutfile then
                        -- (punt on this because updating the pointers would be a real pain)
                        self:Error("Can't write multi-segment EXIF with external pointers")
                    end
                    combinedSegData = nil
                    segDataPt = nil
                    goto nextMarker
                -- check for XMP data
                elseif isMatchDyn(segDataPt, '^(' .. xmpAPP1hdr .. '|' .. xmpExtAPP1hdr .. ')') then
                    segType = 'XMP'
                    if delGroup.XMP then del = 1 break end
                    doneDir.XMP = (doneDir.XMP or 0) + 1
                    if not perlTruthy(editDirs.XMP) then break end
                    if doneDir.XMP + (dirCount.XMP or 0) > 1 then
                        -- must assemble all XMP segments before writing
                        local guid, extXMP
                        if isMatchDyn(segDataPt, '^' .. xmpExtAPP1hdr) then
                            -- save extended XMP data
                            if perl.length(segDataPt) < 75 then
                                extendedXMP.Error = 'Truncated data'
                            else
                                local size, off = perl.unpack('x67N2', segDataPt)
                                guid = substr(segDataPt, 35, 32)
                                if isMatch(guid, '[^A-Za-z0-9]') then -- (technically, should be uppercase)
                                    extendedXMP.Error = 'Invalid GUID'
                                else
                                    -- remember extended data for each GUID
                                    extXMP = extendedXMP[guid]
                                    if extXMP then
                                        if size ~= extXMP.Size then extendedXMP.Error = 'Inconsistent size' end
                                    else
                                        extXMP = { }
                                        extendedXMP[guid] = extXMP
                                    end
                                    extXMP.Size = size
                                    extXMP[off] = substr(segDataPt, 75)
                                end
                            end
                        else
                            -- save all main XMP segments (should normally be only one)
                            if not extendedXMP.Main then extendedXMP.Main = { } end
                            extendedXMP.Main[#extendedXMP.Main + 1] = substr(segDataPt, perl.length(xmpAPP1hdr))
                        end
                        -- continue processing only if we have read all the segments
                        if perlTruthy(dirCount.XMP) then goto nextMarker end
                        -- reconstruct an XMP super-segment
                        segDataPt = carray.new('char'):append(xmpAPP1hdr)
                        local goodGuid = ''
                        for _, main in ipairs(extendedXMP.Main or { }) do
                            -- get the HasExtendedXMP GUID if it exists
                            local ok, _, g2 = isMatch(main, [[:HasExtendedXMP\s*(=\s*['"]|>)(\w{32})]])
                            if ok then
                                -- warn of subsequent XMP blocks specifying a different
                                -- HasExtendedXMP (have never seen this)
                                if goodGuid ~= '' and goodGuid ~= g2 then
                                    self:Warn('Multiple XMP segments specifying different extended XMP GUID')
                                end
                                goodGuid = g2 -- GUID for the standard extended XMP
                            end
                            segDataPt:append(main)
                        end
                        -- GUID of the extended XMP that we want to read
                        local readGuid = self.OPTIONS.ExtendedXMP
                        if not perlTruthy(readGuid) then readGuid = 0 end
                        if perlStr(readGuid) == '1' then readGuid = goodGuid end
                        readGuid = perlStr(readGuid)
                        for _, g in ipairs(perl.sort(perl.keys(extendedXMP))) do
                            guid = g
                            if perl.length(guid) ~= 32 then goto nextGuid end    -- ignore other (internal) keys
                            if guid ~= readGuid and readGuid ~= '2' then
                                local non = guid == goodGuid and '' or 'non-'
                                self:Warn('Ignored ' .. non .. 'standard extended XMP (GUID ' .. guid .. ')')
                                goto nextGuid
                            end
                            if guid ~= goodGuid then
                                self:Warn('Reading non-standard extended XMP (GUID ' .. guid .. ')')
                            end
                            extXMP = extendedXMP[guid]
                            if type(extXMP) ~= 'table' then goto nextGuid end  -- (just to be safe)
                            do
                                local size = extXMP.Size
                                local offsets = { }
                                local off = 0
                                while off < size do
                                    if extXMP[off] == nil then break end
                                    offsets[#offsets + 1] = off
                                    off = off + perl.length(extXMP[off])
                                end
                                if off == size then
                                    -- add all XMP to super-segment
                                    for _, o in ipairs(offsets) do segDataPt:append(extXMP[o]) end
                                else
                                    self:Error('Incomplete extended XMP (GUID ' .. guid .. ')', 1)
                                end
                            end
                            ::nextGuid::
                        end
                        if extendedXMP.Error then self:Error(extendedXMP.Error .. ' in extended XMP', 1) end
                        segDataPt = segDataPt:tostring()    -- (the readers take a string)
                    end
                    local start = perl.length(xmpAPP1hdr)
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.XMP.Main')
                    local subdirInfo = {
                        DataPt     = segDataPt,
                        DirStart   = start,
                        Parent     = markerName,
                        -- limit XMP size and create extended XMP if necessary
                        MaxDataLen = maxXMPLen - perl.length(xmpAPP1hdr),
                    }
                    local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                    if newData ~= nil then
                        extendedXMP = { }
                        if perl.length(newData) > 0 then
                            -- write multi-segment XMP (XMP plus extended XMP if necessary)
                            if not perlTruthy(Writer.WriteMultiXMP(self, outfile, newData, subdirInfo.ExtendedXMP,
                                          subdirInfo.ExtendedGUID)) then err = 1 end
                            segDataPt = nil    -- free the old buffer
                            goto nextMarker
                        else
                            segDataPt = ''   -- delete the XMP
                        end
                    else
                        if perlTruthy(verbose) then out:write("    [XMP rewritten with no changes]\n") end
                        if doneDir.XMP > 1 then
                            -- re-write original multi-segment XMP
                            for _, dat in ipairs(extendedXMP.Main or { }) do      -- main XMP
                                if perl.length(dat) > 0 then
                                    s = perl.pack('n', perl.length(xmpAPP1hdr) + perl.length(dat) + 2)
                                    if not Writer.Write(outfile, hdr, s, xmpAPP1hdr, dat) then err = 1 end
                                end
                            end
                            for _, guid in ipairs(perl.sort(perl.keys(extendedXMP))) do    -- extended XMP
                                if perl.length(guid) ~= 32 then goto nextExt end
                                do
                                    local extXMP = extendedXMP[guid]
                                    if type(extXMP) ~= 'table' then goto nextExt end
                                    local size = extXMP.Size
                                    if not perlTruthy(size) then goto nextExt end
                                    local off = 0
                                    while extXMP[off] ~= nil do
                                        s = perl.pack('n', perl.length(xmpExtAPP1hdr) + perl.length(extXMP[off]) + 42)
                                        if not Writer.Write(outfile, hdr, s, xmpExtAPP1hdr, guid,
                                              perl.pack('N2', size, off), extXMP[off]) then err = 1 end
                                        off = off + perl.length(extXMP[off])
                                    end
                                end
                                ::nextExt::
                            end
                            segDataPt = nil    -- free the old buffer
                            extendedXMP = { }
                            goto nextMarker
                        end
                        -- continue on to re-write original single-segment XMP
                    end
                    if perl.length(segDataPt) == 0 then del = 1 end
                elseif isMatch(segDataPt, '^http') or isMatch(segDataPt, '<exif:') then
                    self:Warn('Ignored APP1 XMP segment with non-standard header', 1)
                end
            elseif marker == 0xe2 then         -- APP2 (ICC Profile, FPXR, MPF)
                if isMatch(segDataPt, [[^ICC_PROFILE\0]]) and length >= 14 then
                    segType = 'ICC_Profile'
                    if delGroup.ICC_Profile then del = 1 break end
                    -- must concatenate blocks of profile
                    local chunkNum = ExifTool.Get8u(segDataPt, 12)
                    local chunksTot = ExifTool.Get8u(segDataPt, 13)
                    if iccChunksTotal ~= nil then
                        -- abort parsing ICC_Profile if the total chunk count is inconsistent
                        if chunksTot ~= iccChunksTotal and iccChunkCount ~= nil then
                            -- an error because the accumulated profile data will be lost
                            self:Error('Inconsistent ICC_Profile chunk count', 1)
                            iccChunkCount = nil -- abort ICC_Profile parsing
                            chunkNum = nil      -- avoid 2nd warning below
                            self.CHANGED = (self.CHANGED or 0) + 1  -- we are deleting the bad chunks before this one
                        end
                    else
                        iccChunkCount = 0
                        iccChunksTotal = chunksTot
                        if chunksTot == 0 then self:Warn('ICC_Profile chunk count is zero') end
                    end
                    if iccChunkCount ~= nil then
                        -- save this chunk
                        if iccChunk[chunkNum] ~= nil then
                            self:Warn('Duplicate ICC_Profile chunk number ' .. chunkNum)
                            iccChunk[chunkNum] = iccChunk[chunkNum] .. substr(segDataPt, 14)
                        else
                            iccChunk[chunkNum] = substr(segDataPt, 14)
                        end
                        -- continue accumulating chunks unless we have all of them
                        iccChunkCount = iccChunkCount + 1
                        if iccChunkCount < iccChunksTotal then goto nextMarker end
                        iccChunkCount = nil  -- prevent reprocessing
                        doneDir.ICC_Profile = 1
                        -- combine the ICC_Profile chunks
                        local icc_profile = carray.new('char')
                        for _, k in ipairs(perl.sort(perl.keys(iccChunk), function(a, b) return a - b end)) do
                            icc_profile:append(iccChunk[k])
                        end
                        iccChunk = { }   -- free memory
                        segDataPt = icc_profile:tostring()  -- (the readers take a string)
                        length = perl.length(icc_profile)
                        local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.ICC_Profile.Main')
                        local subdirInfo = {
                            DataPt   = segDataPt,
                            DataPos  = segPos + 14,
                            DataLen  = length,
                            DirStart = 0,
                            DirLen   = length,
                            Parent   = markerName,
                        }
                        local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                        if newData ~= nil then
                            segDataPt = newData
                        end
                        if perl.length(segDataPt) == 0 then del = 1 break end
                        -- write as ICC multi-segment
                        if not perlTruthy(Writer.WriteMultiSegment(outfile, marker, "ICC_PROFILE\0", segDataPt, 'ICC')) then err = 1 end
                        segDataPt = nil
                        goto nextMarker
                    elseif chunkNum ~= nil then
                        self:Warn('Invalid or extraneous ICC_Profile chunk(s)')
                        -- fall through to preserve this extra profile...
                    end
                elseif isMatch(segDataPt, [[^FPXR\0]]) then
                    segType = 'FPXR'
                    if delGroup.FlashPix then del = 1 end
                elseif isMatch(segDataPt, [[^MPF\0]]) then
                    segType = 'MPF'
                    if delGroup.MPF then del = 1 end
                end
            elseif marker == 0xe3 then         -- APP3 (Kodak Meta)
                if isMatch(segDataPt, [[^(Meta|META|Exif)\0\0]]) then
                    segType = 'Kodak Meta'
                    if delGroup.Meta then del = 1 break end
                    if perlTruthy(doneDir.Meta) then self:Warn('Multiple APP3 Meta segments') end
                    doneDir.Meta = 1
                    if not perlTruthy(editDirs.Meta) then break end
                    -- rewrite Meta IFD as if this were a TIFF file in memory
                    local subdirInfo = {
                        DataPt   = segDataPt,
                        DataPos  = -6, -- (remember: relative to Base!)
                        DirStart = 6,
                        Base     = segPos + 6,
                        Parent   = markerName,
                        DirName  = 'Meta',
                    }
                    -- write new data to memory
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Kodak.Meta')
                    local buff = Writer.WriteDirectory(self, subdirInfo, tagTablePtr, Writer.WriteTIFF)
                    if buff ~= nil then
                        -- update segment with new data
                        segDataPt = substr(segDataPt, 0, 6) .. buff
                    else
                        if not perlTruthy(self:Options('IgnoreMinorErrors')) then goto lastMarker end
                    end
                    -- delete segment if IFD contains no entries
                    if perl.length(segDataPt) <= 6 then del = 1 end
                end
            elseif marker == 0xe5 then         -- APP5 (Ricoh RMETA)
                if isMatch(segDataPt, [[^RMETA\0]]) then
                    segType = 'Ricoh RMETA'
                    if delGroup.RMETA then del = 1 end
                end
            elseif marker == 0xe8 or marker == 0xe9 then -- APP8/9 (SEAL)
                if isMatch(segDataPt, [[^SEAL\0]]) then
                    segType = 'SEAL'
                    if delGroup.SEAL then del = 1 end
                end
            elseif marker == 0xea then         -- APP10 (AROT)
                if isMatch(segDataPt, [[^AROT\0\0]]) then
                    segType = 'AROT'
                    if delGroup.AROT then del = 1 end
                end
            elseif marker == 0xeb then         -- APP11 (JUMBF)
                if isMatch(segDataPt, [[^JP]]) then
                    segType = 'JUMBF'
                    if delGroup.JUMBF then del = 1 end
                end
            elseif marker == 0xec then         -- APP12 (Ducky)
                if isMatch(segDataPt, [[^Ducky]]) then
                    segType = 'Ducky'
                    if delGroup.Ducky then del = 1 break end
                    if perlTruthy(doneDir.Ducky) then self:Warn('Multiple APP12 Ducky segments') end
                    doneDir.Ducky = 1
                    if not perlTruthy(editDirs.Ducky) then break end
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.APP12.Ducky')
                    local subdirInfo = {
                        DataPt   = segDataPt,
                        DataPos  = segPos,
                        DataLen  = length,
                        DirStart = 5,     -- directory starts after identifier
                        DirLen   = length - 5,
                        Parent   = markerName,
                    }
                    local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                    if newData ~= nil then
                        -- add header to new segment unless empty
                        if perl.length(newData) > 0 then newData = 'Ducky' .. newData end
                        segDataPt = newData
                    end
                    if perl.length(segDataPt) == 0 then del = 1 end
                end
            elseif marker == 0xed then         -- APP13 (Photoshop)
                if isMatchDyn(segDataPt, '^' .. psAPP13hdr) then
                    segType = 'Photoshop'
                    -- add this data to the combined data if it exists
                    if combinedSegData ~= nil then
                        combinedSegData:append(substr(segDataPt, perl.length(psAPP13hdr)))
                        segDataPt = combinedSegData:tostring()  -- (the readers take a string)
                        length = perl.length(combinedSegData)  -- update length
                    end
                    -- peek ahead to see if the next segment is photoshop data too
                    if dirOrder[1] == 'Photoshop' then
                        -- initialize combined data if necessary
                        if combinedSegData == nil then combinedSegData = carray.new('char'):append(segDataPt) end
                        goto nextMarker    -- get the next segment to combine
                    end
                    if perlTruthy(doneDir.Photoshop) then
                        self:Warn('Multiple Photoshop records')
                        -- only rewrite the first Photoshop segment when deleting this group
                        -- (to remove multiples when deleting and adding back in one step)
                        if delGroup.Photoshop then del = 1 break end
                    end
                    doneDir.Photoshop = 1
                    -- process APP13 Photoshop record
                    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Photoshop.Main')
                    local subdirInfo = {
                        DataPt   = segDataPt,
                        DataPos  = segPos,
                        DataLen  = length,
                        DirStart = 14,     -- directory starts after identifier
                        DirLen   = length - 14,
                        Parent   = markerName,
                    }
                    local newData = Writer.WriteDirectory(self, subdirInfo, tagTablePtr)
                    if newData ~= nil then
                        segDataPt = newData
                    else
                        -- (port: the segment data still carries its header,
                        --  where upstream's directory data would not either --
                        --  strip it so the unchanged data is rewritten intact)
                        segDataPt = substr(segDataPt, 14)
                    end
                    if perl.length(segDataPt) == 0 then del = 1 break end
                    -- write as multi-segment
                    if not perlTruthy(Writer.WriteMultiSegment(outfile, marker, psAPP13hdr, segDataPt)) then err = 1 end
                    combinedSegData = nil
                    segDataPt = nil
                    goto nextMarker
                end
            elseif marker == 0xee then         -- APP14 (Adobe)
                if isMatch(segDataPt, '^Adobe') then
                    segType = 'Adobe'
                    -- delete it and replace it later if editing
                    if delGroup.Adobe or perlTruthy(editDirs.Adobe) then
                        del = 1
                        doneDir.Adobe = nil  -- so we can add it back again above
                    end
                end
            elseif marker == 0xfe then         -- COM (JPEG comment)
                local newComment
                if not perlTruthy(doneDir.COM) then
                    doneDir.COM = 1
                    if not (delGroup.File and delGroup.File ~= 2) then
                        local tagInfo = ExifTool.Extra.Comment
                        local nvHash = Writer.GetNewValueHash(self, tagInfo)
                        local val = segData
                        val = subst(val, [[\0+$]], '')   -- allow for stupid software that adds NULL terminator
                        if perlTruthy(Writer.IsOverwriting(self, nvHash, val)) or delGroup.File then
                            newComment = Writer.GetNewValue(self, nvHash)
                        else
                            editDirs.COM = nil -- we aren't editing COM after all
                            break
                        end
                    end
                end
                Writer.VerboseValue(self, '- Comment', segDataPt)
                if newComment ~= nil then
                    -- write out the comments
                    Writer.VerboseValue(self, '+ Comment', newComment)
                    if not perlTruthy(Writer.WriteMultiSegment(outfile, 0xfe, '', newComment)) then err = 1 end
                else
                    if perlTruthy(verbose) then out:write("  Deleting COM segment\n") end
                end
                self.CHANGED = (self.CHANGED or 0) + 1      -- increment the changed flag
                segDataPt = nil       -- don't write existing comment
            end
            break   -- didn't want to loop anyway
        end

        -- delete necessary segments (including unknown segments if deleting all)
        if del or (delGroup['*'] and not segType and marker >= 0xe0 and marker <= 0xef) then
            if not segType then segType = 'unknown' end
            if perlTruthy(verbose) then out:write('  Deleting ' .. markerName .. ' ' .. segType .. " segment\n") end
            self.CHANGED = (self.CHANGED or 0) + 1
            goto nextMarker
        end
        -- write out this segment if $segDataPt is still defined
        if segDataPt ~= nil then
            -- write the data for this record (the data could have been
            -- modified, so recalculate the length word)
            local size = perl.length(segDataPt)
            if size > maxSegmentLen then
                if not segType then segType = 'Unknown' end
                self:Error(segType .. ' ' .. markerName .. ' segment too large! (' .. size .. ' bytes)')
                err = 1
            else
                s = perl.pack('n', perl.length(segDataPt) + 2)
                if not Writer.Write(outfile, hdr, s, segDataPt) then err = 1 end
            end
            segDataPt = nil   -- free the buffer
        end
        end
        ::nextMarker::
    end
    ::lastMarker::
    -- make sure the ICC_Profile was complete
    if iccChunkCount ~= nil then self:Error('Incomplete ICC_Profile record', 1) end
    if #path > pn then path[#path] = nil end
    -- if oldOutfile is still set, there was an error copying the JPEG
    if oldOutfile then return 0 end
    if perlTruthy(rtnVal) then
        -- add any new trailers we are creating
        local trailPt = Writer.AddNewTrailers(self)
        if trailPt and not Writer.Write(outfile, trailPt.value) then err = 1 end
    end
    -- set return value to -1 if we only had a write error
    if perlTruthy(rtnVal) and err then rtnVal = -1 end
    if creatingEXV and rtnVal > 0 and not perlTruthy(self.CHANGED) then
        self:Error('Nothing written')
        rtnVal = -1
    end
    return rtnVal
end
-- luacheck: pop

--------------------------------------------------------------------------------
-- Copy data block from RAF to output file in max 64kB chunks
-- Inputs: 0) RAF ref, 1) outfile ref, 2) block size
-- Returns: 1 on success, 0 on read error, undef on write error
function Writer.CopyBlock(raf, outfile, size)
    while true do
        if size <= 0 then break end
        local n = size > 65536 and 65536 or size
        local num, buff = raf:Read(n)
        if num ~= n then return 0 end
        if not Writer.Write(outfile, buff) then return nil end
        size = size - n
    end
    return 1
end

--------------------------------------------------------------------------------
-- Copy image data from one file to another
-- Inputs: 0) ExifTool object reference
--         1) reference to list of image data [ position, size, pad bytes ]
--         2) output file ref
-- Returns: true on success
function Writer.CopyImageData(self, imageDataBlocks, outfile)
    local raf = self.RAF
    local err
    local num = #imageDataBlocks
    if num > 0 then self:VPrint(0, '  Copying ' .. num .. " image data blocks\n") end
    for _, dataBlock in ipairs(imageDataBlocks) do
        local pos, size, pad = dataBlock[1], dataBlock[2], dataBlock[3]
        if not raf:Seek(pos, 0) then err = 'read' break end
        local result = Writer.CopyBlock(raf, outfile, size)
        if not perlTruthy(result) then err = result ~= nil and 'read' or 'writ' end
        -- pad if necessary
        if perlTruthy(pad) and not Writer.Write(outfile, ("\0"):rep(pad)) then err = 'writ' end
        if err then break end
    end
    if err then
        self:Error('Error ' .. err .. 'ing image data')
        return 0
    end
    return 1
end

-- Is any of the named groups being deleted? (port helper for upstream's
-- inline `$$et{DEL_GROUP}{$grp}` test)
-- Inputs: 0) ExifTool ref, 1-N) group names (nil entries are skipped)
-- Returns: the DEL_GROUP flag of the first group found (1, or 2 if tags were
--          written after the group was deleted), or nil
function Writer.IsGroupDeleted(self, ...)
    local del = self.DEL_GROUP
    if not del then return nil end
    for k = 1, select('#', ...) do
        local grp = select(k, ...)
        if grp ~= nil and del[grp] then return del[grp] end
    end
    return nil
end

function Writer.GetAddDirHash(self, tagTablePtr, parent)
    parent = parent or (tagTablePtr.GROUPS and tagTablePtr.GROUPS[0])
    local addDirHash = { }
    local editDirHash = { }
    local addDirs = self.ADD_DIRS
    local editDirs = self.EDIT_DIRS
    for tagID, infoArray in pairs(tagTablePtr) do
        -- upstream walks TagTableKeys, so string tag IDs (MIE, XMP, PNG text)
        -- count too -- only the table meta keys are skipped
        if type(infoArray) == 'table' and not ExifTool.specialTags[tagID] then
            -- resolve via GetTagInfoList so a plain hash tagInfo and a
            -- conditional-list array are both handled (upstream uses
            -- GetTagInfoList here too; #infoArray is 0 for a hash entry)
            for _, tagInfo in ipairs(ExifTool.GetTagInfoList(tagTablePtr, tagID)) do
                if tagInfo.SubDirectory then
                    local dirName = tagInfo.SubDirectory.DirName
                    if not dirName then
                        dirName = tagInfo.Name
                        tagInfo.SubDirectory.DirName = dirName
                    end
                    if editDirs and editDirs[dirName] and editDirs[dirName] == parent then
                        editDirHash[tagID] = tagInfo
                        if addDirs and addDirs[dirName] then
                            addDirHash[tagID] = tagInfo
                        end
                    end
                end
            end
        end
    end
    return addDirHash, editDirHash
end

--------------------------------------------------------------------------------
-- Write an image directory
-- Inputs: 0) ExifTool object reference, 1) source directory information reference
--         2) tag table reference, 3) optional reference to writing procedure
-- Returns: New directory data or undefined on error (or empty string to delete directory)
-- (a write proc that writes straight to an OutFile -- MIE, CIFF -- reports
--  success as a number instead of returning the data)
function Writer.WriteDirectory(self, dirInfo, tagTablePtr, writeProc)
    local out, nvHash, delFlag

    if not tagTablePtr then return nil end
    if perlTruthy(self.OPTIONS.Verbose) then out = self.OPTIONS.TextOut or io.stdout end
    -- set directory name from default group0 name if not done already
    local dirName = dirInfo.DirName
    local parent = dirInfo.Parent or ''
    local dataPt = dirInfo.DataPt
    local grp0 = tagTablePtr.GROUPS and tagTablePtr.GROUPS[0]
    if not perlTruthy(dirName) then
        dirName = grp0
        dirInfo.DirName = grp0
    end
    if self.DEL_GROUP and next(self.DEL_GROUP) then
        local delGroup = self.DEL_GROUP
        -- delete entire directory if specified
        local grp1 = dirName
        delFlag = delGroup[grp0] or delGroup[grp1]
        if permanentDir[grp0] and not (dirInfo.TagInfo and dirInfo.TagInfo.Deletable) then
            delFlag = nil
        end
        if delFlag then
            local m
            if grp0 == 'MakerNotes' then m = grp0
            elseif isMatch(grp1, '^(IFD0|ExifIFD|MakerNotes)$') then m = grp1 end
            if dirInfo.Permanent then
                self:Warn('Not deleting permanent ' .. dirName .. ' directory')
                grp1 = nil
            elseif m and perlTruthy(self:IsRawType()) and
                -- allow non-permanent MakerNote directories to be deleted (ie. NikonCapture)
                (not dirInfo.TagInfo or dirInfo.TagInfo.Permanent == nil or
                perlTruthy(dirInfo.TagInfo.Permanent)) and
                -- allow MakerNotes to be deleted from ExifIFD of CR3 file
                not (self:IsRawType() == 2 and parent == 'ExifIFD')
            then
                self:Warn("Can't delete " .. m .. ' from ' .. perlStr(self.FileType), 1)
                grp1 = nil
            elseif not blockExifTypes[self.FILE_TYPE] then
                -- restrict delete logic to prevent entire tiff image from being killed
                -- (don't allow IFD0 to be deleted, and delete only ExifIFD if EXIF specified)
                if self.FILE_TYPE == 'PSD' then
                    -- don't delete Photoshop directories from PSD image
                    if grp0 == 'Photoshop' then grp1 = nil end
                elseif isMatch(self.FILE_TYPE, '^(EPS|PS)$') then -- luacheck: ignore 542
                    -- allow anything to be deleted from PostScript files
                elseif grp1 == 'IFD0' then
                    local ftype = perlTruthy(self.TIFF_TYPE) and self.TIFF_TYPE or self.FILE_TYPE
                    if delGroup.IFD0 then self:Warn("Can't delete IFD0 from " .. perlStr(ftype), 1) end
                    grp1 = nil
                elseif grp0 == 'EXIF' and delGroup[grp0] then
                    if not (delGroup[grp1] or grp1 == 'ExifIFD') then grp1 = nil end
                end
            end
            if grp1 then
                if dataPt or dirInfo.RAF then
                    self.CHANGED = (self.CHANGED or 0) + 1
                    if out then out:write('  Deleting ' .. grp1 .. "\n") end
                    if grp1 == 'ICC_Profile' then self:Warn('ICC_Profile deleted. Image colors may be affected') end
                    -- can no longer validate TIFF_END if deleting an entire IFD
                    if isMatch(dirName, 'IFD') then self.TIFF_END = nil end
                end
                -- don't add back into the wrong location
                local right = self.ADD_DIRS and self.ADD_DIRS[grp1]
                -- (take care because EXIF directory name may be either EXIF or IFD0,
                --  but IFD0 will be the one that appears in the directory map)
                if not perlTruthy(right) and grp1 == 'EXIF' then right = self.ADD_DIRS and self.ADD_DIRS.IFD0 end
                if delFlag == 2 and perlTruthy(right) then
                    -- also check grandparent because some routines create 2 levels in 1
                    local right2 = self.ADD_DIRS[right] or ''
                    if parent == '' or parent == right or parent == right2 then
                        -- prevent duplicate directories from being recreated at the same path
                        local path = join('-', self.PATH) .. '-' .. dirName
                        if #self.PATH == 0 then path = dirName end
                        if not self.Recreated then self.Recreated = { } end
                        if self.Recreated[path] then
                            local p = parent ~= '' and (' in ' .. parent) or ''
                            self:Warn('Not recreating duplicate ' .. grp1 .. p, 1)
                            return ''
                        end
                        self.Recreated[path] = 1
                        -- empty the directory
                        local data = ''
                        dirInfo.DataPt   = data
                        dirInfo.DataLen  = 0
                        dirInfo.DirStart = 0
                        dirInfo.DirLen   = 0
                        dirInfo.RAF = nil
                        dirInfo.Base = nil
                        dirInfo.DataPos = nil
                    else
                        self:Warn('Not recreating ' .. grp1 .. ' in ' .. parent .. ' (should be in ' .. right .. ')', 1)
                        return ''
                    end
                else
                    if not dirInfo.NoDelete then return '' end
                end
            end
        end
    end
    -- use default proc from tag table if no proc specified
    writeProc = writeProc or tagTablePtr.WRITE_PROC
    if not writeProc then return nil end

    -- are we rewriting a pre-existing directory?
    local isRewriting = perlTruthy(dirInfo.DirLen) or (dataPt ~= nil and perl.length(dataPt) > 0) or
                        dirInfo.RAF ~= nil

    -- copy or delete new directory as a block if specified
    local blockName = dirName
    if blockName == 'IFD0' then blockName = 'EXIF' end
    local tagInfo = ExifTool.Extra[blockName] or dirInfo.TagInfo
    while tagInfo do -- luacheck: ignore 512
        nvHash = self.NEW_VALUE and self.NEW_VALUE[tagInfo]
        if not (nvHash and perlTruthy(Writer.IsOverwriting(self, nvHash)) and
            not (nvHash.CreateOnly and isRewriting)) then break end
        -- protect against writing EXIF to wrong file types, etc
        if blockName == 'EXIF' then
            if not blockExifTypes[self.FILE_TYPE] then
                self:Warn("Can't write EXIF as a block to " .. perlStr(self.FILE_TYPE) .. ' file')
                break
            end
            -- this can happen if we call WriteDirectory for an EXIF directory without going
            -- through WriteTIFF as the WriteProc (which happens if conditionally replacing
            -- the EXIF block and the condition fails), but we never want to do a block write
            -- in this case because the EXIF block would end up with two TIFF headers
            if writeProc ~= Writer.WriteTIFF then break end
        end
        if not perlTruthy(Writer.IsOverwriting(self, nvHash, dataPt or '')) then break end
        local verb = 'Writing'
        local newVal = Writer.GetNewValue(self, nvHash)
        if newVal ~= nil and perl.length(newVal) > 0 then
            -- hack to add back TIFF header when writing MakerNoteCanon to CMT3 in CR3 images
            if tagInfo.Name == 'MakerNoteCanon' then
                if tagInfo == require('lexiftool.Canon').uuid.CMT3 then
                    local hdr
                    if substr(newVal, 0, 1) == "\0" then
                        hdr = "MM\0\x2a" .. perl.pack('N', 8)
                    else
                        hdr = "II\x2a\0" .. perl.pack('V', 8)
                    end
                    newVal = hdr .. newVal
                end
            end
        else
            if not (dataPt or dirInfo.RAF) then return '' end -- nothing to do if block never existed
            -- don't allow MakerNotes to be removed from RAW files
            if blockName == 'MakerNotes' and perlTruthy(self:IsRawType()) and
                -- but allow MakerNotes to be deleted from ExifIFD of CR3 image (shouldn't be there)
                not (self:IsRawType() == 2 and parent == 'ExifIFD')
            then
                self:Warn("Can't delete MakerNotes from " .. perlStr(self.FileType), 1)
                return nil
            end
            verb = 'Deleting'
            newVal = ''
        end
        dirInfo.BlockWrite = 1  -- set flag indicating we did a block write
        if out then out:write('  ' .. verb .. ' ' .. blockName .. " as a block\n") end
        self.CHANGED = (self.CHANGED or 0) + 1
        return newVal
    end
    -- guard against writing the same directory twice
    if dataPt ~= nil and dirInfo.DirStart ~= nil and dirInfo.DataPos ~= nil and
        not dirInfo.NoRefTest
    then
        local addr = dirInfo.DirStart + dirInfo.DataPos + (dirInfo.Base or 0) + (self.BASE or 0)
        -- (Phase One P25 IIQ files have ICC_Profile duplicated in IFD0 and IFD1)
        if self.PROCESSED and self.PROCESSED[addr] and (dirName ~= 'ICC_Profile' or self.TIFF_TYPE ~= 'IIQ') then
            if dirInfo.DirLen ~= nil and not perlTruthy(dirInfo.DirLen) and dirName ~= self.PROCESSED[addr] then -- luacheck: ignore 542
                -- it is hypothetically possible to have 2 different directories
                -- with the same address if one has a length of zero
            elseif self:Error(dirName .. ' pointer references previous ' .. self.PROCESSED[addr] .. ' directory', 2) then
                return nil
            else
                self:Warn('Deleting duplicate ' .. dirName .. ' directory')
                if out then out:write('  Deleting ' .. dirName .. "\n") end
                -- delete the duplicate directory (don't recreate it when writing new
                -- tags to prevent propagating a duplicate IFD in cases like when the
                -- same ExifIFD exists in both IFD0 and IFD1)
                return ''
            end
        else
            self.PROCESSED = self.PROCESSED or { }
            self.PROCESSED[addr] = dirName
        end
    end
    local oldDir = self.DIR_NAME
    local save1, save2 = self.Compression, self.SubfileType
    local name
    if out then
        name = (dirName == 'MakerNotes' and dirInfo.TagInfo) and dirInfo.TagInfo.Name or dirName
        if oldDir == nil or oldDir ~= name then
            local verb = isRewriting and 'Rewriting' or 'Creating'
            out:write('  ' .. verb .. ' ' .. name .. "\n")
        end
    end
    local saveOrder = ExifTool.GetByteOrder()
    local oldChanged = self.CHANGED
    self.DIR_NAME = dirName
    table.insert(self.PATH, dirName)
    dirInfo.IsWriting = 1
    local newData
    if type(writeProc) == 'function' then
        newData = writeProc(self, dirInfo, tagTablePtr)
    else
        local fn = type(writeProc) == 'string' and load('return ' .. writeProc)() or writeProc
        newData = fn(self, dirInfo, tagTablePtr)
    end
    table.remove(self.PATH)
    -- nothing changed if error occurred or nothing was created
    local newLen = type(newData) == 'string' and #newData or (newData ~= nil and 1 or 0)
    if not (newData ~= nil and (newLen > 0 or isRewriting)) then self.CHANGED = oldChanged end
    self.DIR_NAME = oldDir
    self.Compression, self.SubfileType = save1, save2
    ExifTool.SetByteOrder(saveOrder)
    if out then
        if newData ~= nil and newLen == 0 then out:write('  Deleting ' .. name .. "\n") end
        if self.CHANGED == oldChanged and self.OPTIONS.Verbose > 2 then
            out:write((self.INDENT or '') .. '  [nothing changed in ' .. name .. "]\n")
        end
    end
    return newData
end


--------------------------------------------------------------------------------
-- Uncommon utility routines to for reading binary data values
-- Inputs: 0) data reference, 1) offset into data
-- (uv() marks the int64u result as Perl's UV, see perl.uv: Lua's integer
--  arithmetic gives the right 64 bits, Perl's is unsigned; a read past the
--  end of the data returns undef, as the Get32u it is built on does)
function Writer.Get64s(dataPt, pos)
    local pt = ExifTool.GetByteOrder() == 'MM' and 0 or 4   -- get position of high word
    local hi = Get32s(dataPt, pos + pt)       -- preserve sign bit of high word
    local lo = Get32u(dataPt, pos + 4 - pt)
    if hi == nil or lo == nil then return nil end
    return hi * 4294967296 + lo
end
function Writer.Get64u(dataPt, pos)
    local pt = ExifTool.GetByteOrder() == 'MM' and 0 or 4   -- get position of high word
    local hi = Get32u(dataPt, pos + pt)       -- (unsigned this time)
    local lo = Get32u(dataPt, pos + 4 - pt)
    if hi == nil or lo == nil then return nil end
    return perl.uv(hi * 4294967296 + lo)
end
function Writer.GetFixed64s(dataPt, pos)
    local val = Writer.Get64s(dataPt, pos) / 4294967296
    -- remove insignificant digits
    return perl.int(val * 1e10 + (val > 0 and 0.5 or -0.5)) / 1e10
end
-- Decode extended 80-bit float used by Apple SANE and Intel 8087
-- (note: different than the IEEE standard 80-bit float)
function Writer.GetExtended(dataPt, pos)
    local pt = ExifTool.GetByteOrder() == 'MM' and 0 or 2   -- get position of exponent
    local exp = Get16u(dataPt, pos + pt)
    local sig = Writer.Get64u(dataPt, pos + 2 - pt)  -- get significand as int64u
    if exp == nil or sig == nil then return nil end
    local sign = (exp & 0x8000) ~= 0 and -1 or 1
    exp = (exp & 0x7fff) - 16383 - 63 -- (-63 to fractionalize significand)
    return sign * sig * 2.0 ^ exp
end

--------------------------------------------------------------------------------
-- Dump data in hex and ASCII to console
-- Inputs: 0) data reference, 1) length or undef, 2-N) Options:
-- Options: Start => offset to start of data (default=0)
--          Addr => address to print for data start (default=DataPos+Base+Start)
--          DataPos => position of data within block (relative to Base)
--          Base => base offset for pointers from start of file
--          Width => width of printout (bytes, default=16)
--          Prefix => prefix to print at start of line (default='')
--          MaxLen => maximum length to dump
--          Out => output file reference
--          Len => data length
-- (the options come as one table, standing in for Perl's flattened %opts)
function Writer.HexDump(dataPt, len, opts)
    opts = opts or { }
    local start  = opts.Start  or 0
    local addr   = opts.Addr
    local wid    = opts.Width  or 16
    local prefix = opts.Prefix or ''
    local out    = opts.Out    or io.stdout
    local maxLen = opts.MaxLen
    local datLen = perl.length(dataPt) - start
    local more
    if opts.Len ~= nil then len = opts.Len end

    if addr == nil then addr = start + (opts.DataPos or 0) + (opts.Base or 0) end
    if len == nil then len = datLen end
    if perlTruthy(maxLen) and len > maxLen then
        -- print one line less to allow for $more line below
        maxLen = perl.int((maxLen - 1) / wid) * wid
        more = len - maxLen
        len = maxLen
    end
    if len > datLen then
        out:write(prefix .. "    Warning: Attempted dump outside data\n")
        out:write(prefix .. '    (' .. len .. ' bytes specified, but only ' .. datLen .. " available)\n")
        len = datLen
    end
    local format = sprintf('%%-%ds', wid * 3)
    local tmpl = ('H2'):rep(wid) -- ('(H2)*' would have been nice, but older perl versions don't support it)
    local i = 0
    while i < len do
        if wid > len - i then
            wid = len - i
            tmpl = ('H2'):rep(wid)
        end
        out:write(sprintf(prefix .. '%8.4x: ', addr + i))
        local dat = substr(dataPt, i + start, wid)
        local s = join(' ', { perl.unpack(tmpl, dat) })
        out:write(sprintf(format, s))
        dat = perl.tr(dat, [[\x00-\x1f\x7f-\xff]], '.')
        out:write('[' .. dat .. "]\n")
        i = i + wid
    end
    if more then out:write(prefix .. '    [snip ' .. more .. " bytes]\n") end
end

--------------------------------------------------------------------------------
-- Print verbose tag information
-- Inputs: 0) ExifTool object reference, 1) tag ID
--         2) tag info reference (or undef)
--         3-N) extra parms:
-- Parms: Index => Index of tag in menu (starting at 0)
--        Value => Tag value
--        DataPt => reference to value data block
--        DataPos => location of data block in file
--        Base => base added to all offsets
--        Size => length of value data within block
--        Format => value format string
--        Count => number of values
--        Extra => Extra Verbose=2 information to put after tag number
--        Table => Reference to tag table
--        Name => Name to use for unknown tag
--        --> plus any of these HexDump() options: Start, Addr, Width
-- (the parms come as one table, standing in for Perl's flattened %parms)
function Writer.VerboseInfo(self, tagID, tagInfo, parmsIn)
    -- (Perl's %parms is a copy of the caller's list)
    local parms = { }
    for k, v in pairs(parmsIn or { }) do parms[k] = v end
    local verbose = self.OPTIONS.Verbose
    local out = self.OPTIONS.TextOut or io.stdout
    local tag, line, hexID

    -- generate hex number if tagID is numerical
    if tagID ~= nil then
        if isMatch(perlStr(tagID), [[^\d+$]]) then
            if parms.Table and parms.Table.VARS and
                parms.Table.ID_FMT and parms.Table.VARS.ID_FMT == 'dec'
            then
                hexID = tagID
            else
                hexID = sprintf('0x%.4x', tagID)
            end
        end
    else
        tagID = 'Unknown'
    end
    -- get tag name
    if tagInfo and tagInfo.Name then
        tag = tagInfo.Name
    elseif parms.Name then -- (used for PNG Plus FPX tags)
        tag = parms.Name
        hexID = nil
    else
        local prefix
        if parms.Table then prefix = parms.Table.TAG_PREFIX end
        if prefix or hexID ~= nil then
            if not prefix then prefix = 'Unknown' end
            tag = prefix .. '_' .. (hexID ~= nil and hexID or perlStr(tagID))
        else
            tag = tagID
        end
    end
    local dataPt = parms.DataPt
    local size = parms.Size
    if not (size ~= nil or not dataPt) then size = perl.length(dataPt) end
    local indent = self.INDENT

    -- Level 1: print tag/value information
    line = indent
    local index = parms.Index
    if index ~= nil then
        line = line .. index .. ') '
        if #perlStr(index) < 2 then line = line .. ' ' end
        indent = indent .. '    ' -- indent everything else to align with tag name
    end
    line = line .. tag
    if tagInfo and tagInfo.SubDirectory then
        line = line .. ' (SubDirectory) -->'
    else
        local maxLen = 90 - #line
        local val = parms.Value
        if val ~= nil then
            if type(val) == 'table' and val.ref == nil then val = '[' .. join(',', val) .. ']' end
            line = line .. ' = ' .. self:Printable(val, maxLen)
        elseif dataPt then
            local start = parms.Start or 0
            line = line .. ' = ' .. self:Printable(substr(dataPt, start, size), maxLen)
        end
    end
    out:write(line .. "\n")

    -- Level 2: print detailed information about the tag
    if verbose > 1 and (parms.Extra or parms.Format or
        parms.DataPt or size ~= nil or isMatch(perlStr(tagID), '/'))
    then
        line = indent .. '- Tag '
        if hexID ~= nil then
            line = line .. hexID
        else
            tagID = subst(perlStr(tagID), [[([\0-\x1f\x7f-\xff])]],
                          function(c) return sprintf('\\x%.2x', perl.ord(c)) end, 'g')
            line = line .. "'" .. tagID .. "'"
        end
        if parms.Extra ~= nil then line = line .. parms.Extra end
        local format = parms.Format
        if format or size ~= nil then
            line = line .. ' ('
            if size ~= nil then
                line = line .. size .. ' bytes'
                if format then line = line .. ', ' end
            end
            if format then
                line = line .. format
                if perlTruthy(parms.Count) then line = line .. '[' .. perlStr(parms.Count) .. ']' end
            end
            line = line .. ')'
        end
        if verbose > 2 and parms.DataPt then line = line .. ':' end
        out:write(line .. "\n")
    end

    -- Level 3: do hex dump of value
    if verbose > 2 and parms.DataPt and (not tagInfo or not tagInfo.ReadFromRAF) then
        parms.Out = out
        parms.Prefix = indent
        -- limit dump length if Verbose < 5
        if verbose < 5 then parms.MaxLen = verbose == 3 and 96 or 2048 end
        Writer.HexDump(dataPt, size, parms)
    end
end

--------------------------------------------------------------------------------
-- Dump trailer information
-- Inputs: 0) ExifTool object ref, 1) dirInfo hash (RAF, DirName, DataPos, DirLen)
-- Notes: Restores current file position before returning
-- luacheck: push ignore 311
function Writer.DumpTrailer(self, dirInfo)
    local raf = dirInfo.RAF
    local curPos = raf:Tell()
    local trailer = dirInfo.DirName or 'Unknown'
    local pos = dirInfo.DataPos
    local verbose = self.OPTIONS.Verbose
    local htmlDump = self.HTML_DUMP
    local buff, buf2
    local size = dirInfo.DirLen
    -- (DirLen may be a numeric string -- ProcessGoogle passes the XMP length --
    --  which Perl numifies in every comparison below)
    if size ~= nil then size = perl.num(size) end
    if pos == nil then pos = curPos end

    -- get full trailer size if not specified
    repeat -- luacheck: ignore 512
        if not perlTruthy(size) then
            if not raf:Seek(0, 2) then break end
            size = raf:Tell() - pos
            if not perlTruthy(size) then break end
        end
        if not raf:Seek(pos, 0) then break end
        if htmlDump then
            local num
            num, buff = raf:Read(size)
            if not perlTruthy(num) then return end
            local desc = trailer .. ' trailer'
            if trailer == 'Unknown' then desc = '[' .. desc .. ']' end
            self:HDump(pos, num, desc, nil, 0x08)
            break
        end
        local out = self.OPTIONS.TextOut or io.stdout
        out:write(sprintf(trailer .. " trailer (%d bytes at offset 0x%.4x):\n", size, pos))
        if verbose <= 2 then break end
        local num = size    -- number of bytes to read
        -- limit size if not very verbose
        if verbose < 5 then
            local limit = verbose < 4 and 96 or 512
            if num > limit then num = limit end
        end
        local n
        n, buff = raf:Read(num)
        if n ~= num then return end
        -- read the end of the trailer too if not done already
        if size > 2 * num then
            raf:Seek(pos + size - num, 0)
            n, buf2 = raf:Read(num)
        elseif size > num then
            raf:Seek(pos + num, 0)
            n, buf2 = raf:Read(size - num)
            buff = buff .. buf2
            buf2 = nil
        end
        Writer.HexDump(buff, nil, { Addr = pos, Out = out })
        if buf2 ~= nil then
            out:write('    [snip ', size - num * 2, " bytes]\n")
            Writer.HexDump(buf2, nil, { Addr = pos + size - num, Out = out })
        end
    until true
    raf:Seek(curPos, 0)
end
-- luacheck: pop

--------------------------------------------------------------------------------
-- Dump unknown trailer information
-- Inputs: 0) ExifTool ref, 1) dirInfo ref (with RAF, DataPos and DirLen defined)
-- Notes: changes dirInfo elements
function Writer.DumpUnknownTrailer(self, dirInfo)
    local pos = dirInfo.DataPos
    local endPos = pos + dirInfo.DirLen
    -- account for preview/MPF image trailer
    local value = self.VALUE
    local prePos = perlTruthy(value.PreviewImageStart) and value.PreviewImageStart or self.PreviewImageStart
    local preLen = perlTruthy(value.PreviewImageLength) and value.PreviewImageLength or self.PreviewImageLength
    local hidPos = value.HiddenDataOffset
    local hidLen = value.HiddenDataLength
    local tag = 'PreviewImage'
    local mpImageNum = 0
    local image, lastOne = { }, nil
    -- add HiddenData to list of known trailer blocks
    if perlTruthy(hidPos) and perlTruthy(hidLen) then
        -- call ReadHiddenData to validate hidden data and fix offset if necessary
        -- (upstream fixes the offset through its argument list; the port's
        --  ReadHiddenData returns it as a second value)
        local datPt
        datPt, hidPos = require('lexiftool.Sony').ReadHiddenData(self, hidPos, hidLen)
        if datPt then image[hidPos] = { 'HiddenData', hidLen } end
    end
    while true do
        -- add to Preview block list if valid and in the trailer
        if perlTruthy(prePos) and perlTruthy(preLen) and prePos + preLen > pos then
            image[prePos] = { tag, preLen }
        end
        if lastOne then break end   -- checked all images
        -- look for MPF images (in the proper order)
        mpImageNum = mpImageNum + 1
        prePos = value['MPImageStart (' .. mpImageNum .. ')']
        if prePos ~= nil then
            preLen = value['MPImageLength (' .. mpImageNum .. ')']
        else
            prePos = value.MPImageStart
            preLen = value.MPImageLength
            lastOne = 1
        end
        tag = 'MPImage' .. mpImageNum
    end
    -- dump trailer sections in order
    image[endPos] = { '', 0 }   -- add terminator "image"
    for _, p in ipairs(perl.sort(perl.keys(image), function(a, b) return a - b end)) do
        prePos = p
        if pos < prePos then
            -- dump unknown trailer data
            dirInfo.DirName = 'Unknown'
            dirInfo.DataPos = pos
            dirInfo.DirLen = prePos - pos
            Writer.DumpTrailer(self, dirInfo)
        end
        tag, preLen = image[prePos][1], image[prePos][2]
        if not perlTruthy(preLen) then break end
        -- dump image if verbose (it is htmlDump'd by ExtractImage)
        if perlTruthy(self.OPTIONS.Verbose) then
            dirInfo.DirName = tag
            dirInfo.DataPos = prePos
            dirInfo.DirLen  = preLen
            Writer.DumpTrailer(self, dirInfo)
        end
        pos = prePos + preLen
    end
end

--------------------------------------------------------------------------------
-- Print verbose value while writing
-- Inputs: 0) ExifTool object ref, 1) heading "eg. '+ IPTC:Keywords',
--         2) value, 3) [optional] extra text after value
function Writer.VerboseValue(self, str, val, xtra)
    if not (perlTruthy(self.OPTIONS.Verbose) and self.OPTIONS.Verbose > 1) then return end
    local out = self.OPTIONS.TextOut or io.stdout
    if not perlTruthy(xtra) then xtra = '' end
    local maxLen = 81 - perl.length(str) - perl.length(xtra)
    val = self:Printable(val, maxLen)
    out:write('    ' .. str .. " = '" .. val .. "'" .. xtra .. "\n")
end

--------------------------------------------------------------------------------
-- Pack Unicode numbers into UTF8 string
-- Inputs: 0-N) list of Unicode numbers
-- Returns: Packed UTF-8 string
function Writer.PackUTF8(...)
    local out = { }
    local args = { ... }
    while #args > 0 do
        local ch = remove(args)
        if ch < 0x80 then
            table.insert(out, 1, ch)
            goto continue
        end
        table.insert(out, 1, 0x80 | (ch & 0x3f))
        ch = ch >> 6
        if ch < 0x20 then
            table.insert(out, 1, 0xc0 | ch)
            goto continue
        end
        table.insert(out, 1, 0x80 | (ch & 0x3f))
        ch = ch >> 6
        if ch < 0x10 then
            table.insert(out, 1, 0xe0 | ch)
            goto continue
        end
        table.insert(out, 1, 0x80 | (ch & 0x3f))
        ch = ch >> 6
        table.insert(out, 1, 0xf0 | (ch & 0x07))
        ::continue::
    end
    return perl.pack('C*', table.unpack(out))
end

--------------------------------------------------------------------------------
-- Unpack numbers from UTF8 string
-- Inputs: 0) UTF-8 string
-- Returns: List of Unicode numbers (sets $evalWarning on error)
-- (Lua: returns the list as a table; $evalWarning is ExifTool.evalWarning)
function Writer.UnpackUTF8(str)
    local out, pos = { }, 0
    local gpos = 0  -- (Perl's pos($_[0]))
    while true do
        local ch, newPos, val
        local c, en = matches(str, '([\x80-\xff])', gpos)
        if c then
            ch = sbyte(c)
            gpos = en
            newPos = en - 1
        else
            newPos = #str
        end
        -- unpack 7-bit characters
        local len = newPos - pos
        if len > 0 then
            for _, v in ipairs({ perl.unpack('x' .. pos .. 'C' .. len, str) }) do out[#out + 1] = v end
        end
        if ch == nil then break end
        pos = newPos + 1
        -- minimum lead byte for 2-byte sequence is 0xc2 (overlong sequences
        -- not allowed), 0xf8-0xfd are restricted by RFC 3629 (no 5 or 6 byte
        -- sequences), and 0xfe and 0xff are not valid in UTF-8 strings
        if ch < 0xc2 or ch >= 0xf8 then
            out[#out + 1] = perl.ord('?') -- invalid UTF-8
            ExifTool.evalWarning = 'Bad UTF-8'
            goto continue
        end
        do
            -- decode 2, 3 and 4-byte sequences
            local n = 1
            if ch < 0xe0 then
                val = ch & 0x1f     -- 2-byte sequence
            elseif ch < 0xf0 then
                val = ch & 0x0f     -- 3-byte sequence
                n = n + 1
            else
                val = ch & 0x07     -- 4-byte sequence
                n = n + 2
            end
            local seq, en2 = matchesDyn(str, '\\G([\\x80-\\xbf]{' .. n .. '})', gpos)
            if not seq then
                gpos = pos    -- restore position
                out[#out + 1] = perl.ord('?') -- invalid UTF-8
                ExifTool.evalWarning = 'Bad UTF-8'
                goto continue
            end
            gpos = en2
            for _, byte in ipairs({ perl.unpack('C*', seq) }) do
                val = (val << 6) | (byte & 0x3f)
            end
            out[#out + 1] = val   -- save Unicode character value
            pos = pos + n         -- position at end of UTF-8 character
        end
        ::continue::
    end
    return out
end

--------------------------------------------------------------------------------
-- Generate a new, random GUID
-- Inputs: <none>
-- Returns: GUID string
local guidCount
function Writer.NewGUID()
    local tm = perl.localtime(perl.time())
    if guidCount ~= nil then guidCount = guidCount + 1 end
    if not (guidCount ~= nil and guidCount < 0x100) then guidCount = 0 end
    return sprintf('%.4d%.2d%.2d%.2d%.2d%.2d%.2X%.4X%.4X%.4X%.4X',
                   tm[6] + 1900, tm[5] + 1, tm[4], tm[3], tm[2], tm[1], guidCount,
                   perl.pid() & 0xffff, perl.rand(0x10000), perl.rand(0x10000), perl.rand(0x10000))
end

--------------------------------------------------------------------------------
-- Generate a version 4 ("random"), variant 1 UUID (RFC 9562, Section 5.4) (github #421)
-- Inputs: <none>
-- Returns: UUID string
function Writer.NewUUID()
    local rnd = { }
    for i = 1, 16 do rnd[i] = perl.int(perl.rand(256)) end
    rnd[7] = (rnd[7] & 0x0f) | 0x40
    rnd[9] = (rnd[9] & 0x3f) | 0x80
    local chars = { }
    for i = 1, 16 do chars[i] = perl.chr(rnd[i]) end
    return perl.uc((perl.unpack('H32', concat(chars))))
end

--------------------------------------------------------------------------------
-- Make TIFF header for raw data
-- Inputs: 0) width, 1) height, 2) num colour components, 3) bits, 4) resolution
--         5) color-map data for palette-color image (8 or 16 bit)
-- Returns: TIFF header
-- Notes: Multi-byte data must be little-endian
-- (Set32u/Set16u are upstream's returning one-argument forms, Put32u/Put16u
--  here)
function Writer.MakeTiffHeader(w, h, cols, bits, res, cmap)
    local Set32u, Set16u = ExifTool.Put32u, ExifTool.Put16u
    if not perlTruthy(res) then res = 72 end
    local saveOrder = ExifTool.GetByteOrder()
    ExifTool.SetByteOrder('II')
    if not perlTruthy(cmap) then
        cmap = ''
    elseif perl.length(cmap) == 3 * 2^bits then
        -- convert to short
        local shorts = { }
        for _, c in ipairs({ perl.unpack('C*', cmap) }) do shorts[#shorts + 1] = c | (c << 8) end
        cmap = perl.pack('v*', table.unpack(shorts))
    elseif perl.length(cmap) ~= 6 * 2^bits then
        cmap = ''
    end
    local cmo = perlTruthy(cmap) and 12 or 0   -- offset due to ColorMap IFD entry
    local hdr =
    "\x49\x49\x2a\0\x08\0\0\0\x0e\0" ..                 -- 0x00 14 menu entries:
    "\xfe\x00\x04\0\x01\0\0\0\x00\0\0\0" ..             -- 0x0a SubfileType = 0
    "\x00\x01\x04\0\x01\0\0\0" .. Set32u(w) ..          -- 0x16 ImageWidth
    "\x01\x01\x04\0\x01\0\0\0" .. Set32u(h) ..          -- 0x22 ImageHeight
    "\x02\x01\x03\0" .. Set32u(cols) ..                 -- 0x2e BitsPerSample
     Set32u(cols == 1 and bits or 0xb6 + cmo) ..
    "\x03\x01\x03\0\x01\0\0\0\x01\0\0\0" ..             -- 0x3a Compression = 1
    "\x06\x01\x03\0\x01\0\0\0" ..                       -- 0x46 PhotometricInterpretation
     Set32u(perlTruthy(cmap) and 3 or cols == 1 and 1 or 2) ..
    "\x11\x01\x04\0\x01\0\0\0" ..                       -- 0x52 StripOffsets
     Set32u(0xcc + cmo + perl.length(cmap)) ..
    "\x15\x01\x03\0\x01\0\0\0" .. Set32u(cols) ..       -- 0x5e SamplesPerPixel
    "\x16\x01\x04\0\x01\0\0\0" .. Set32u(h) ..          -- 0x6a RowsPerStrip
    "\x17\x01\x04\0\x01\0\0\0" ..                       -- 0x76 StripByteCounts
     Set32u(w * h * cols * perl.int((bits + 7) / 8)) ..
    "\x1a\x01\x05\0\x01\0\0\0" .. Set32u(0xbc + cmo) .. -- 0x82 XResolution
    "\x1b\x01\x05\0\x01\0\0\0" .. Set32u(0xc4 + cmo) .. -- 0x8e YResolution
    "\x1c\x01\x03\0\x01\0\0\0\x01\0\0\0" ..             -- 0x9a PlanarConfiguration = 1
    "\x28\x01\x03\0\x01\0\0\0\x02\0\0\0" ..             -- 0xa6 ResolutionUnit = 2
    (perlTruthy(cmap) and                               -- 0xb2 ColorMap [optional]
    "\x40\x01\x03\0" .. Set32u(3 * 2^bits) .. "\xd8\0\0\0" or '') ..
    "\0\0\0\0" ..                                       -- 0xb2+$cmo (no IFD1)
    (Set16u(bits):rep(3)) ..                            -- 0xb6+$cmo BitsPerSample value
    Set32u(res) .. "\x01\0\0\0" ..                      -- 0xbc+$cmo XResolution = 72
    Set32u(res) .. "\x01\0\0\0" ..                      -- 0xc4+$cmo YResolution = 72
    cmap                                                -- 0xcc or 0xd8 (cmap and data go here)
    ExifTool.SetByteOrder(saveOrder)
    return hdr
end

--------------------------------------------------------------------------------
-- Return current time in EXIF format
-- Inputs: 0) [optional] ExifTool ref, 1) flag to include timezone (0 to disable,
--            undef or 1 to include)
-- Returns: time string
-- - a consistent value is returned for each processed file
function Writer.TimeNow(self, tzFlag)
    local timeNow
    if type(self) ~= 'table' then
        tzFlag = self
        self = { }
    end
    if self.Now then
        timeNow = self.Now[1]
    else
        local time = perl.time()
        local tm = perl.localtime(time)
        local tz = ExifTool.TimeZoneString(tm, time)
        timeNow = sprintf('%4d:%.2d:%.2d %.2d:%.2d:%.2d',
                    tm[6] + 1900, tm[5] + 1, tm[4],
                    tm[3], tm[2], tm[1])
        self.Now = { timeNow, tz }
    end
    if perlTruthy(tzFlag) or tzFlag == nil then timeNow = timeNow .. self.Now[2] end
    return timeNow
end

--------------------------------------------------------------------------------
-- Binary value encoders (write path)
-- Ported from Image::ExifTool::Writer WriteValue / writeValueProc / Rationalize
-- / AssembleRational.  All setters operate in place on a carray buffer at the
-- given 0-based offset (no return value), mirroring the upstream in-place
-- mutation of the data scalar.  Set* for the integer types live in ExifTool.lua
-- (the Image::ExifTool.pm equivalent); the 64-bit / rational / fixed / float
-- encoders below belong to WriteValue in Writer.pl.

-- Assemble a continuing fraction into a rational value
-- Inputs: 0) numerator, 1) denominator
--         2-N) list of fraction denominators, deepest first
-- Returns: numerator, denominator (in list context)
-- (Writer.pl:5202; Lua varargs stand in for the `splice(@_, 0, 3)`)
function Writer.AssembleRational(a, b, c, ...)
    if not c then return a, b end
    return Writer.AssembleRational(c * a + b, a, ...)
end

-- Convert a floating point number (or 'inf' or 'undef' or a fraction) into a rational
-- Inputs: 0) floating point number, 1) optional maximum value (defaults to 0x7fffffff)
-- Returns: numerator, denominator (in list context)
-- Notes:
-- - the returned rational will be accurate to at least 8 significant figures if possible
-- - eg. an input of 3.14159265358979 returns a rational of 104348/33215,
--   which equals    3.14159265392142 and is accurate to 10 significant figures
-- - the returned rational will be reduced to the lowest common denominator except when
--   the input is a fraction in which case the input is returned unchanged
-- - these routines were a bit tricky, but fun to write!
function Writer.Rationalize(val, maxInt)
    maxInt = maxInt or 0x7fffffff
    if val == 'inf' then return 1, 0 end
    if val == 'undef' then return 0, 0 end
    local n, d = string.match(val, '^([-+]?%d+)/(%d+)$')
    if n then return tonumber(n), tonumber(d) end
    local v = tonumber(val)
    if v == 0 then return 0, 1 end
    local sign = 1
    if v < 0 then v = -v; sign = -1 end
    local num, denom, fracs = nil, nil, {}
    local frac = v
    while true do
        local n2, d2 = Writer.AssembleRational(math.floor(frac + 0.5), 1, table.unpack(fracs))
        if n2 > maxInt or d2 > maxInt then
            if num == nil then
                if v < 1 then return sign, maxInt end
                return sign * maxInt, 1
            end
            break
        end
        num, denom = n2, d2
        local err = (n2 / d2 - v) / v
        if math.abs(err) < 1e-8 then break end
        local int = math.floor(frac)
        table.insert(fracs, 1, int)
        frac = frac - int
        if frac == 0 then break end
        frac = 1 / frac
    end
    return num * sign, denom
end

--------------------------------------------------------------------------------
-- Utility routines to for writing binary data values
-- Inputs: 0) value, 1) data ref, 2) offset
-- Notes: prototype is (@) so values can be passed from list if desired
-- (Lua: the port's Set16u/Set32u take (dataPt, pos, val), see lexiftool.lua)
function Writer.Set16s(dataPt, pos, val)
    if val < 0 then val = val + 0x10000 end
    return ExifTool.Set16u(dataPt, pos, val)
end
function Writer.Set32s(dataPt, pos, val)
    if val < 0 then val = val + 0xffffffff + 1 end
    return ExifTool.Set32u(dataPt, pos, val)
end

function Writer.Set64u(dataPt, pos, val)
    local hi = math.floor(val / 4294967296)
    local lo = val - hi * 4294967296
    if ExifTool.GetByteOrder() == 'MM' then
        ExifTool.Set32u(dataPt, pos, hi)
        ExifTool.Set32u(dataPt, pos + 4, lo)
    else
        ExifTool.Set32u(dataPt, pos, lo)
        ExifTool.Set32u(dataPt, pos + 4, hi)
    end
end

function Writer.Set64s(dataPt, pos, val)
    if val < 0 then val = val + 4294967296 * 4294967296 end
    Writer.Set64u(dataPt, pos, val)
end

function Writer.SetRational64u(dataPt, pos, val)
    local numer, denom = Writer.Rationalize(val, 0xffffffff)
    ExifTool.Set32u(dataPt, pos, numer)
    ExifTool.Set32u(dataPt, pos + 4, denom)
end

function Writer.SetRational64s(dataPt, pos, val)
    local numer, denom = Writer.Rationalize(val)
    ExifTool.Set32s(dataPt, pos, numer)
    ExifTool.Set32u(dataPt, pos + 4, denom)
end

function Writer.SetRational32u(dataPt, pos, val)
    local numer, denom = Writer.Rationalize(val, 0xffff)
    ExifTool.Set16u(dataPt, pos, numer)
    ExifTool.Set16u(dataPt, pos + 2, denom)
end

function Writer.SetRational32s(dataPt, pos, val)
    local numer, denom = Writer.Rationalize(val, 0x7fff)
    ExifTool.Set16s(dataPt, pos, numer)
    ExifTool.Set16u(dataPt, pos + 2, denom)
end

function Writer.SetFixed16u(dataPt, pos, val)
    val = perl.num(val)
    ExifTool.Set16u(dataPt, pos, perl.int(val * 0x100 + 0.5))
end

function Writer.SetFixed16s(dataPt, pos, val)
    val = perl.num(val)
    ExifTool.Set16s(dataPt, pos, perl.int(val * 0x100 + (val < 0 and -0.5 or 0.5)))
end

function Writer.SetFixed32u(dataPt, pos, val)
    val = perl.num(val)
    ExifTool.Set32u(dataPt, pos, perl.int(val * 0x10000 + 0.5))
end

function Writer.SetFixed32s(dataPt, pos, val)
    val = perl.num(val)
    ExifTool.Set32s(dataPt, pos, perl.int(val * 0x10000 + (val < 0 and -0.5 or 0.5)))
end

function Writer.SetFloat(dataPt, pos, val)
    local s = string.pack(ExifTool.GetByteOrder() == 'MM' and '>f' or '<f', val)
    dataPt:set(pos + 1, s)
end

function Writer.SetDouble(dataPt, pos, val)
    local s = string.pack(ExifTool.GetByteOrder() == 'MM' and '>d' or '<d', val)
    dataPt:set(pos + 1, s)
end

--------------------------------------------------------------------------------
-- Write binary data values (mirror of WriteValue + writeValueProc in Writer.pl)
-- All setters write in place on a carray buffer, so WriteValue builds the packed
-- value directly in the (optionally supplied) carray instead of returning a
-- mutable string.  Returns the carray (or a new one when dataPt is nil) on
-- success, or nil on error.  Strings/undef are returned as Lua strings.

-- number of bytes written per element for each numeric format
local byteSize = {
    int8s = 1, int8u = 1,
    int16s = 2, int16u = 2, int16uRev = 2,
    int32s = 4, int32u = 4,
    int64s = 8, int64u = 8,
    rational32s = 4, rational32u = 4,
    rational64s = 8, rational64u = 8,
    fixed16u = 2, fixed16s = 2,
    fixed32u = 4, fixed32s = 4,
    float = 4, double = 8,
    ifd = 4,
}

local writeValueProc = {
    int8s = ExifTool.Set8s, int8u = ExifTool.Set8u,
    int16s = ExifTool.Set16s, int16u = ExifTool.Set16u, int16uRev = ExifTool.Set16uRev,
    int32s = ExifTool.Set32s, int32u = ExifTool.Set32u,
    int64s = Writer.Set64s, int64u = Writer.Set64u,
    rational32s = Writer.SetRational32s, rational32u = Writer.SetRational32u,
    rational64s = Writer.SetRational64s, rational64u = Writer.SetRational64u,
    fixed16u = Writer.SetFixed16u, fixed16s = Writer.SetFixed16s,
    fixed32u = Writer.SetFixed32u, fixed32s = Writer.SetFixed32s,
    float = Writer.SetFloat, double = Writer.SetDouble,
    ifd = ExifTool.Set32u,
}

-- Grow a carray buffer (zero-filled) to at least minLen bytes so a following
-- :set() at that offset stays within the current length (carray's :set does not
-- auto-extend, unlike Perl's substr-assignment which the Set* helpers mirror).
local function ensureLen(buf, minLen)
    if buf:len() < minLen then buf:setlen(minLen) end
end

-- Perl `int()` truncates toward zero (unlike Lua's math.floor, which rounds
-- toward negative infinity -- they differ for negative non-integers, and for
-- negative whole-number floats like -200.0 the port's ValueConvInv formulas
-- stringify with a ".0" suffix and so take the IsFloat rounding path here)
local function perlInt(v)
    return v >= 0 and math.floor(v) or math.ceil(v)
end

function Writer.WriteValue(val, format, count, dataPt, offset)
    if val == nil then return nil end
    local proc = writeValueProc[format]
    if proc then
        local vals = {}
        for v in string.gmatch(val, '[^ \t\n\r\f\v]+') do vals[#vals + 1] = v end
        if count then
            if count < 0 then count = #vals end
        else
            count = 1
        end
        local pos = offset or 0
        local out = dataPt or carray.new('char')
        while count > 0 do
            local v = table.remove(vals, 1)
            if v == nil then return nil end
            if format:match('^int') then
                if not ExifTool.IsInt(v) then
                    if not ExifTool.IsHex(v) then
                        if not ExifTool.IsFloat(v) then
                            return nil
                        end
                        v = perlStr(perlInt(tonumber(v) + (tonumber(v) < 0 and -0.5 or 0.5)))
                    else
                        v = perlStr(tonumber(v))
                    end
                end
                v = tonumber(v)
            elseif not ExifTool.IsFloat(v) then
                if not (format:match('^rational') and (v == 'inf' or v == 'undef' or ExifTool.IsRational(v))) then
                    return nil
                end
            end
            ensureLen(out, pos + byteSize[format])
            proc(out, pos, v)
            pos = pos + byteSize[format]
            count = count - 1
        end
        if dataPt then return dataPt end
        return out:tostring()
    elseif format == 'string' or format == 'undef' then
        if type(val) == 'number' then val = perlStr(val) end
        if format == 'string' then val = val .. '\0' end
        if count and count > 0 then
            local diff = count - #val
            if diff ~= 0 then
                if diff < 0 then
                    if format == 'string' then
                        val = string.sub(val, 1, count - 1) .. '\0'
                    else
                        val = string.sub(val, 1, count)
                    end
                else
                    val = val .. string.rep('\0', diff)
                end
            end
        else
            count = #val
        end
        if dataPt then
            ensureLen(dataPt, (offset or 0) + count)
            dataPt:set((offset or 0) + 1, val)
            return dataPt
        end
        return val
    else
        return nil
    end
end

-- valid integer ranges per format (mirror %intRange in Writer.pl)
local intRange = {
    int8u = { 0, 0xff }, int8s = { -0x80, 0x7f },
    int16u = { 0, 0xffff }, int16uRev = { 0, 0xffff },
    int16s = { -0x8000, 0x7fff },
    int32u = { 0, 0xffffffff }, int32s = { -0x80000000, 0x7fffffff },
    int64u = { 0, 18446744073709551615 }, int64s = { -9223372036854775808, 9223372036854775807 },
}

--------------------------------------------------------------------------------
-- Validate an image for writing (Writer.pl:6841-6854)
-- Inputs: 0) ExifTool object reference, 1) raw value reference
-- Returns: error string or undef on success
-- (Perl passes \$val; Lua has no scalar reference, so the value itself)
function Writer.CheckImage(self, valPtr)
    if perl.length(valPtr) > 0 and not matches(valPtr, [[^\xff\xd8]]) and not
        perlTruthy(self:Options('IgnoreMinorErrors'))
    then
        return '[Minor] Not a valid image'
    end
    return nil
end

--------------------------------------------------------------------------------
-- check a value for validity
-- Inputs: 0) value reference, 1) format string, 2) optional count
-- Returns: error string, or undef on success
-- Notes: May modify value (if a count is specified for a string, it is null-padded
-- to the specified length, and floating point values are rounded to integer if required)
-- (Lua: the value instead of its reference; a modified value comes back as
--  the second result, the CHECK_PROC convention)
function Writer.CheckValue(valPtr, format, count)
    local vals, val

    if count ~= nil then count = perl.num(count) end  -- (Perl numifies Count => '2')
    if format == 'string' or format == 'undef' then
        if not (perlTruthy(count) and count > 0) then return nil end
        local len = perl.length(valPtr)
        if format == 'string' then
            if len >= count then return 'String too long' end
        else
            if len > count then return 'Data too long' end
        end
        if len < count then
            valPtr = valPtr .. string.rep("\0", count - len)
        end
        return nil, valPtr
    end
    if perlTruthy(count) and count ~= 1 then
        vals = split(' ', valPtr)
        if count < 0 then
            count = #vals
            if count == 0 then return nil end
        end
    else
        count = 1
        vals = { valPtr }
    end
    if #vals ~= count then
        local str = #vals > count and 'Too many' or 'Not enough'
        return str .. ' values specified (' .. count .. ' required)'
    end
    for n = 1, count do
        val = vals[n]
        if isMatch(format, '^int') then
            -- make sure the value is integer
            if not ExifTool.IsInt(val) then
                if ExifTool.IsHex(val) then
                    val = perl.hex(val)
                    valPtr = val
                else
                    -- round single floating point values to the nearest integer
                    if not (ExifTool.IsFloat(val) and count == 1) then return 'Not an integer' end
                    val = perl.int(val + (perl.num(val) < 0 and -0.5 or 0.5))
                    valPtr = val
                end
            end
            local rng = intRange[format]
            if not rng then return 'Bad int format: ' .. format end
            if perl.num(val) < rng[1] then return 'Value below ' .. format .. ' minimum' end
            -- (allow 0xfeedfeed code as value for 16-bit pointers)
            if perl.num(val) > rng[2] and perl.num(val) ~= 0xfeedfeed then
                return 'Value above ' .. format .. ' maximum'
            end
        elseif isMatch(format, '^rational') or format == 'float' or format == 'double' then
            -- make sure the value is a valid floating point number
            if not ExifTool.IsFloat(val) then
                -- allow 'inf', 'undef' and fractional rational values
                if isMatch(format, '^rational') then
                    if val == 'inf' or val == 'undef' then goto nextVal end
                    local num = matches(val, [[^([-+]?\d+)/(\d+)$]])
                    if num then
                        if not (perl.num(num) < 0 and isMatch(format, 'u$')) then goto nextVal end
                        return 'Must be an unsigned rational'
                    end
                end
                return 'Not a floating point number'
            end
            if isMatch(format, [[^rational\d+u$]]) and perl.num(val) < 0 then
                return 'Must be a positive number'
            end
        end
        ::nextVal::
    end
    return nil, valPtr   -- success!
end

--------------------------------------------------------------------------------
-- check new value for binary data block
-- Inputs: 0) ExifTool object ref, 1) tagInfo hash ref, 2) raw value ref
-- Returns: error string or undef (and may modify value) on success
-- (Lua: the value itself, and the possibly modified value after the error,
--  as CheckValue returns it)
function Writer.CheckBinaryData(_self, tagInfo, valPtr)
    local format = tagInfo.Format
    if not perlTruthy(format) then
        local tbl = tagInfo.Table
        if tbl and perlTruthy(tbl.FORMAT) then
            format = tbl.FORMAT
        else
            -- use default 'int8u' unless specified
            format = 'int8u'
        end
    end
    local count
    local f, c = matches(format, [=[(.*)\[(.*)\]]=])
    if f then
        format = f
        count = c
        -- can't evaluate $count now because we don't know $size yet
        if isMatch(count, [[\$size]]) then count = -1 end -- (-1 = any count allowed)
        count = perl.num(count)
    end
    return Writer.CheckValue(valPtr, format, count)
end

--------------------------------------------------------------------------------
-- Rename a file (with patch for Windows Unicode file names, and other problem)
-- Inputs: 0) ExifTool ref, 1) old name, 2) new name
-- Returns: true on success
function Writer.Rename(self, old, new)
    local result, try, winUni
    local arg1 = old    -- (port: Perl's $_[1], the name as passed in)
    local wide, _

    wide, old = self:EncodeFileName(old)
    if perlTruthy(wide) then
        _, new = self:EncodeFileName(new, 1)
        winUni = 1
    else
        wide, new = self:EncodeFileName(new)
        if perlTruthy(wide) then
            old = arg1
            _, old = self:EncodeFileName(old, 1)
            winUni = 1
        end
    end
    while true do
        if winUni then
            -- (Win32API::File::MoveFileExW with MOVEFILE_REPLACE_EXISTING |
            --  MOVEFILE_COPY_ALLOWED: lexiftool.sys.rename)
            result = sys.rename(old, new) and true or false
        else
            result = perl.rename(old, new)
        end
        if result or perl.osname() ~= 'MSWin32' then break end
        -- keep trying for up to 0.5 seconds
        -- (patch for Windows denial-of-service susceptibility)
        try = (try or 1) + 1
        if try > 50 then break end
        perl.select(nil, nil, nil, 0.01) -- sleep for 0.01 sec
    end
    return result
end

--------------------------------------------------------------------------------
-- Delete a file (with patch for Windows Unicode file names)
-- Inputs: 0) ExifTool ref, 1-N) names of files to delete
-- Returns: number of files deleted
function Writer.Unlink(self, ...)
    local result = 0
    for k = 1, select('#', ...) do
        local file = select(k, ...)
        local wide
        wide, file = self:EncodeFileName(file)
        if perlTruthy(wide) then
            if sys.unlink(file) then result = result + 1 end    -- (Win32API::File::DeleteFileW)
        else
            if perl.unlink(file) > 0 then result = result + 1 end
        end
    end
    return result
end

--------------------------------------------------------------------------------
-- Set file times (Unix seconds since the epoch)
-- Inputs: 0) ExifTool ref, 1) file name or ref, 2) access time, 3) modification time,
--         4) inode change or creation time (or undef for any time to avoid setting)
--         5) flag to suppress warning
-- Returns: 1 on success, 0 on error
function Writer.SetFileTime(self, file, atime, mtime, ctime, noWarn) -- luacheck: ignore 212
    local saveFile

    -- open file by name if necessary
    if type(file) == 'string' then
        -- (file will be automatically closed when *FH goes out of scope)
        local fh = self:Open(file, '+<')
        if not fh then
            local success
            if atime ~= nil or mtime ~= nil then
                local a, m = self:GetFileTime(file)
                if atime == nil then atime = a end
                if mtime == nil then mtime = m end
                if atime ~= nil and mtime ~= nil then
                    local ok, n = pcall(perl.utime, atime, mtime, file)
                    success = ok and n > 0
                end
            end
            if not success then self:Warn('Error updating file time') end
            return success
        end
        saveFile = file
        file = fh
    end
    -- on Windows, try to work around incorrect file times when daylight saving time is in effect
    if perl.osname() == 'MSWin32' then
        -- (Win32::API and Win32API::File are lexiftool.sys here, always present;
        --  GetOsFHandle, the FILETIME conversion and SetFileTime are
        --  lexiftool.sys.set_file_time on the open file)
        if io.type(file) ~= 'file' then
            self:Warn('Win32API::File GetOsFHandle returned invalid handle')
            return 0
        end
        local ok, _, errCode = sys.set_file_time(file, atime, mtime, ctime)
        if saveFile ~= nil then file:close() end
        if not ok then
            self:Warn('Win32::API SetFileTime returned ' .. perlStr(errCode))
            return 0
        end
        return 1
    end
    -- other OS (or Windows fallback)
    if atime ~= nil and mtime ~= nil then
        local success, err
        while true do
            -- (this may fail on the first try if futimes is not implemented)
            local ok, n = pcall(perl.utime, atime, mtime, file)
            if ok then success = n > 0 else err = n end
            if success or saveFile == nil then break end
            file:close()
            file = saveFile
            saveFile = nil
        end
        if saveFile ~= nil then file:close() end
        if not noWarn then
            if err then
                self:Warn(ExifTool.CleanWarning(tostring(err)))
            elseif not success then
                self:Warn('Error setting file time')
            end
        end
        return success
    end
    if saveFile ~= nil then file:close() end
    return 1 -- (nothing to do)
end

--------------------------------------------------------------------------------
-- Add data to hash checksum
-- Inputs: 0) ExifTool ref, 1) RAF ref, 2) data size (or undef to read to end of file),
--         3) data name (or undef for no warnings or messages), 4) flag for no verbose message
-- Returns: number of bytes read and hashed
-- (rawget: the hash object shares its member name with this method, see
--  ExifTool.ImageDataHashMember)
function Writer.ImageDataHash(self, raf, size, type_, noMsg)
    local hash = rawget(self, 'ImageDataHash')
    if not hash then return end
    local bytesRead, n = 0, 65536
    local buff
    while true do
        if size ~= nil then
            if not perlTruthy(size) then break end
            n = size > 65536 and 65536 or size
            size = size - n
        end
        local num
        num, buff = raf:Read(n)
        if not perlTruthy(num) then
            if perlTruthy(type_) and size ~= nil then self:Warn('Error reading ' .. type_ .. ' data') end
            break
        end
        hash:add(buff)
        bytesRead = bytesRead + perl.length(buff)
    end
    if perlTruthy(self.OPTIONS.Verbose) and perlTruthy(bytesRead) and perlTruthy(type_) and not noMsg then
        self:VPrint(0, self.INDENT .. '(ImageDataHash: ' .. bytesRead .. ' bytes of ' .. type_ .. " data)\n")
    end
    return bytesRead
end

-- printConv hash keys to ignore when doing reverse lookup
local ignorePrintConv = { OTHER = 1, BITMASK = 1, Notes = 1 }

--------------------------------------------------------------------------------
-- Reverse hash lookup
-- Inputs: 0) value, 1) hash reference
-- Returns: Hash key or undef if not found (plus flag for multiple matches in list context)
local function ReverseLookup(val, conv)
    if val == nil then return nil end
    local multi
    -- (Perl stringifies hash keys and values; the four patterns below are
    --  quotemeta'd, so they are plain-string comparisons here)
    local function str(v)
        if type(v) == 'number' then return ExifTool.NumStr(v) end
        if type(v) == 'string' then return v end
        return nil -- (a code or hash ref never matches a quoted value)
    end
    local unknown = matches(perlStr(val), [[(?i)^Unknown\s*\((.*)\)$]])
    if unknown then
        val = unknown    -- was unknown
        local hex = matches(val, [[^0x([\da-fA-F]+)$]])
        if hex then
            val = tonumber(hex, 16)   -- convert hex value
        end
    else
        local qval = (perlStr(val):gsub('[ \t\n\r\f\v]+$', ''))      -- remove trailing whitespace
        local lq = lc(qval)
        local patterns = {
            function(v) return v == qval end,                         -- exact match
            function(v) return lc(v) == lq end,                   -- case-insensitive
            function(v) return lc(v):sub(1, #lq) == lq end,       -- beginning of string
            function(v) return lc(v):find(lq, 1, true) ~= nil end, -- substring
        }
        local exact = { true, true, false, false } -- (patterns ending in `$`)
        -- hash entries to ignore in reverse lookup
        local found, nMatches
        local keys = {}
        for k in pairs(conv) do keys[#keys + 1] = k end
        tsort(keys, function(x, y) return perl.lt(str(x) or '', str(y) or '') end)
        for p, pattern in ipairs(patterns) do
            nMatches = 0
            for _, k in ipairs(keys) do
                local v = str(conv[k])
                if v and pattern(v) then nMatches = nMatches + 1 end
            end
            if nMatches > 0 then
                -- multiple matches are bad unless they were exact
                if nMatches > 1 and not exact[p] then
                    -- don't match entries that we should ignore
                    for k in pairs(ignorePrintConv) do
                        local v = perlStr(conv[k])
                        if v and pattern(v) then nMatches = nMatches - 1 end
                    end
                    if nMatches > 1 then break end
                end
                for _, k in ipairs(keys) do
                    local v = perlStr(conv[k])
                    if v and pattern(v) and not ignorePrintConv[k] then
                        val = k
                        found = true
                        break
                    end
                end
                if found then break end
            end
        end
        if not found then
            -- call OTHER conversion routine if available
            if conv.OTHER then
                local oldWarn = perl.SIG.__WARN__
                perl.SIG.__WARN__ = ExifTool.SetWarning
                ExifTool.evalWarning = nil
                -- (pcall: an OTHER sub ported for the read direction only
                --  must not abort the write -- its error is the warning)
                local ok, res = pcall(conv.OTHER, val, 1, conv)
                perl.SIG.__WARN__ = oldWarn
                if ok then
                    val = res
                else
                    val = nil
                    ExifTool.evalWarning = perl.isDie(res) and res.msg or tostring(res)
                end
            else
                val = nil
            end
            if nMatches and nMatches > 1 then multi = 1 end
        end
    end
    return val, multi
end
Writer.ReverseLookup = ReverseLookup

--------------------------------------------------------------------------------
-- Encode bits from a list of names/numbers (upstream Writer.pl EncodeBits).
-- Inputs: 0) value string, 1) lookup hash (name -> bit number), 2) bits/word,
--         3) total bits
-- Returns: space-separated word string, or (nil, error) in list context.
--------------------------------------------------------------------------------
function Writer.EncodeBits(val, lookup, bits, num)
    bits = bits or 32
    num = num or bits
    local words = math.floor((num + bits - 1) / bits)
    local outVal = {}
    for i = 1, words do outVal[i] = 0 end
    if val ~= '(none)' then
        for raw in (val .. ','):gmatch('([^,]+),') do
            local v = raw:match('^[ \t\n\r\f\v]*(.-)[ \t\n\r\f\v]*$')
            local bit
            if lookup then
                bit = ReverseLookup(v, lookup)
                if bit == nil then
                    local bn = v:match('%[(%d+)%]')
                    bit = bn and tonumber(bn)
                end
            else
                bit = tonumber(v)
            end
            if not (ExifTool.IsInt(bit) and bit < num) then
                return nil, (ExifTool.IsInt(bit) and 'bit number too high' or 'not an integer')
            end
            local word = math.floor(bit / bits)
            outVal[word + 1] = outVal[word + 1] | (1 << (bit - word * bits))
        end
    end
    return table.concat(outVal, ' ')
end

--------------------------------------------------------------------------------
-- Apply inverse conversions
-- Inputs: 0) ExifTool ref, 1) value, 2) tagInfo (or Struct item) ref,
--         3) tag name, 4) group 1 name, 5) conversion type (or undef),
--         6) [optional] want group ("" for structure field)
-- Returns: 0) converted value, 1) error string (or undef on success)
-- Notes:
-- - uses ExifTool "ConvType" member when conversion type is undef
-- - conversion types other than 'ValueConv' and 'PrintConv' are treated as 'Raw'
-- (Lua: a conversion function is called as conv($self, $val, $wantGroup), a
--  CHECK_PROC as proc($self, $tagInfo, $val, $convType) and a WriteCheck as
--  check($self, $tagInfo, $val) -- the last two return the error and, where
--  upstream changes $$valPtr, the changed value.  An eval warning is a Lua
--  error; "\n" is the empty warning.  A conversion list is an array whose
--  first entry is a table, a function or false -- see GetValue)
function Writer.ConvInv(self, val, tagInfo, tag, wgrp1, convType, wantGroup)
    local err, type_ = nil, nil

    if not perlTruthy(convType) then convType = self.ConvType or 'PrintConv' end

    while true do -- Conv:
        if type_ == nil then
            -- split value into list if necessary
            if tagInfo.List then
                local listSplit = tagInfo.AutoSplit or self.OPTIONS.ListSplit
                if listSplit ~= nil and not tagInfo.Struct and
                    (perlTruthy(wantGroup) or wantGroup == nil) and type(val) ~= 'table'
                then
                    if perlStr(listSplit) == '1' and tagInfo.AutoSplit then listSplit = [[,?\s+]] end
                    local splitVal = perl.splitDyn(perlStr(listSplit), val, -1)
                    val = #splitVal > 1 and splitVal or (#splitVal > 0 and splitVal[1] or '')
                end
            end
            type_ = convType
        elseif type_ == 'PrintConv' then
            type_ = 'ValueConv'
        else
            -- split raw value if necessary
            if tagInfo.RawJoin and tagInfo.List and type(val) ~= 'table' then
                local splitVal = split(' ', val)
                if #splitVal > 1 then val = splitVal end
            end
            -- finally, do our value check
            local err2
            if tagInfo.WriteCheck then
                --### eval WriteCheck ($self, $tagInfo, $val)
                local ok, e, newVal = pcall(tagInfo.WriteCheck, self, tagInfo, val)
                if not ok then
                    perl.print(io.stderr, tostring(e) .. '\n')
                    err2 = 'Error evaluating WriteCheck'
                else
                    err2 = e
                    if e == nil and newVal ~= nil then val = newVal end
                end
            end
            if err2 == nil then
                local tbl = tagInfo.Table
                if tbl and tbl.CHECK_PROC and not tagInfo.RawConvInv then
                    local checkProc = tbl.CHECK_PROC
                    if isArrayRef(val) then
                        -- loop through array values
                        for i = 1, #val do
                            local newVal
                            err2, newVal = checkProc(self, tagInfo, val[i], convType)
                            if newVal ~= nil then val[i] = newVal end
                            if perlTruthy(err2) then break end
                        end
                    else
                        local newVal
                        err2, newVal = checkProc(self, tagInfo, val, convType)
                        if newVal ~= nil then val = newVal end
                    end
                end
            end
            if err2 ~= nil then
                if perlTruthy(err2) then
                    err = err2 .. ' for ' .. perlStr(wgrp1) .. ':' .. tag
                    self:VPrint(2, err .. "\n")
                    val = nil     -- value was invalid
                else
                    err = err2    -- empty error (quietly don't write tag)
                end
            end
            break
        end
        local conv = tagInfo[type_]
        local convInv = tagInfo[type_ .. 'Inv']
        if conv == false then conv = nil end   -- (Lua: `PrintConv => undef`)
        -- nothing to do at this level if no conversion defined
        if conv == nil and convInv == nil then goto nextType end
        do
            local valList, index, convList, convInvList = { }, 0, nil, nil
            if isArrayRef(val) then
                -- handle ValueConv of ListSplit and AutoSplit values
                for i = 1, #val do valList[i] = val[i] end
                index = 0
                val = valList[index + 1]
            elseif isConvList(conv) or type(convInv) == 'table' then
                -- handle conversion lists
                valList = perl.splitDyn(listSep[type_], val)
                index = 0
                val = valList[index + 1]
                if isConvList(conv) then
                    convList = conv
                    conv = conv[1]
                end
                if type(convInv) == 'table' then
                    convInvList = convInv
                    convInv = convInv[1]
                end
            end
            -- loop through multiple values if necessary
            while true do
                if convInv then
                    -- capture eval warnings too
                    local oldWarn = perl.SIG.__WARN__
                    perl.SIG.__WARN__ = ExifTool.SetWarning
                    ExifTool.evalWarning = nil
                    --### eval PrintConvInv/ValueConvInv ($val, $self, $wantGroup)
                    -- (Lua: a conversion is called as conv($self, $val, $wantGroup);
                    --  an error it raises is the eval's $@)
                    local ok, res = pcall(convInv, self, val, wantGroup)
                    perl.SIG.__WARN__ = oldWarn
                    if ok then
                        val = res
                    else
                        val = nil
                        ExifTool.evalWarning = perl.isDie(res) and res.msg or tostring(res)
                    end
                    local evalWarning = ExifTool.evalWarning
                    if perlTruthy(evalWarning) then
                        -- an empty warning ("\n") ignores tag with no error
                        if evalWarning == "\n" then
                            if err == nil then err = '' end
                        else
                            err = ExifTool.CleanWarning(evalWarning) .. ' in ' .. perlStr(wgrp1) .. ':' .. tag ..
                                  ' (' .. type_ .. 'Inv)'
                            self:VPrint(2, err .. "\n")
                        end
                        val = nil
                        goto lastConv
                    elseif val == nil then
                        err = 'Error converting value for ' .. perlStr(wgrp1) .. ':' .. tag .. ' (' .. type_ .. 'Inv)'
                        self:VPrint(2, err .. "\n")
                        goto lastConv
                    end
                elseif perlTruthy(conv) then
                    if type(conv) == 'table' and (tagInfo[type_ .. 'Inv'] == nil or convInvList) then
                        local multi, lcConv
                        -- insert alternate language print conversions if required
                        if self.CUR_LANG and type_ == 'PrintConv' then
                            lcConv = self.CUR_LANG[tag]
                            lcConv = type(lcConv) == 'table' and lcConv.PrintConv
                        end
                        if lcConv then
                            local newConv = { }
                            for _, k in ipairs(perl.keys(conv)) do
                                local v = conv[k]
                                if lcConv[v] == nil then
                                    newConv[k] = v
                                else
                                    newConv[k] = self:Decode(lcConv[v], 'UTF8')
                                end
                            end
                            if conv.BITMASK then
                                newConv.BITMASK = { }
                                for _, k in ipairs(perl.keys(conv.BITMASK)) do
                                    local v = conv.BITMASK[k]
                                    if lcConv[v] == nil then
                                        newConv.BITMASK[k] = v
                                    else
                                        newConv.BITMASK[k] = self:Decode(lcConv[v], 'UTF8')
                                    end
                                end
                            end
                            conv = newConv
                        end
                        ExifTool.evalWarning = nil
                        if conv.BITMASK then
                            local lookupBits = conv.BITMASK
                            local wbits, tbits = tagInfo.BitsPerWord, tagInfo.BitsTotal
                            local val2, err2 = Writer.EncodeBits(val, lookupBits, wbits, tbits)
                            if err2 then
                                -- ok, try matching a straight value
                                val, multi = ReverseLookup(val, conv)
                                if val == nil then
                                    err = "Can't encode " .. perlStr(wgrp1) .. ':' .. tag .. ' (' .. err2 .. ')'
                                    self:VPrint(2, err .. "\n")
                                    goto lastConv
                                end
                            elseif val2 ~= nil then
                                val = val2
                            else
                                conv.BITMASK = nil
                                val, multi = ReverseLookup(val, conv)
                                conv.BITMASK = lookupBits
                            end
                        else
                            val, multi = ReverseLookup(val, conv)
                        end
                        local evalWarning = ExifTool.evalWarning
                        if val == nil then
                            local prob = evalWarning and perl.lcfirst(ExifTool.CleanWarning(evalWarning)) or
                                         ((multi and 'matches more than one ' or 'not in ') .. type_)
                            err = "Can't convert " .. perlStr(wgrp1) .. ':' .. tag .. ' (' .. prob .. ')'
                            self:VPrint(2, err .. "\n")
                            goto lastConv
                        elseif evalWarning then
                            self:VPrint(2, ExifTool.CleanWarning(evalWarning) .. ' for ' .. perlStr(wgrp1) .. ':' .. tag .. "\n")
                        end
                    elseif not tagInfo.WriteAlso then
                        err = "Can't convert value for " .. perlStr(wgrp1) .. ':' .. tag .. ' (no ' .. type_ .. 'Inv)'
                        self:VPrint(2, err .. "\n")
                        val = nil
                        goto lastConv
                    end
                end
                if #valList == 0 then break end
                valList[index + 1] = val
                index = index + 1
                if index >= #valList then
                    -- leave AutoSplit lists in ARRAY form, or join conversion lists
                    if tagInfo.List then
                        val = valList
                    else
                        val = join(' ', valList)
                    end
                    break
                end
                if convList then conv = convList[index + 1] end
                if convInvList then convInv = convInvList[index + 1] end
                val = valList[index + 1]
            end
        end
        ::nextType::
    end -- end ValueConv/PrintConv loop
    ::lastConv::

    return val, err
end

--------------------------------------------------------------------------------
-- Add value to list, handling lists and binary data
-- Inputs: 0) ExifTool ref, 1) value, 2) list ref, 3) flag to add MissingTagValue if necessary
-- (a SCALAR ref is this port's { ref = 'SCALAR', value = ... }, a list a Lua
--  array, a structure any other table -- the same forms GetValue returns)
function Writer.PushValue(self, val, list, missing)
    if type(val) == 'table' and getmetatable(val) == nil and val.ref == nil and
       val[1] ~= nil and not (type(val[1]) == 'table' and val[1].ref == nil and val[1][1] == nil)
    then
        for _, v in ipairs(val) do Writer.PushValue(self, v, list, missing) end
    elseif type(val) == 'table' and val.ref == 'SCALAR' then
        if perlTruthy(self.OPTIONS.Binary) or matches(perlStr(val.value), '^Binary data') then
            list[#list + 1] = val.value
        else
            list[#list + 1] = 'Binary data ' .. perl.length(val.value) .. ' bytes'
        end
    elseif type(val) == 'table' and getmetatable(val) == nil then
        list[#list + 1] = require('lexiftool.XMP').SerializeStruct(self, val)
    elseif val == nil then
        local mval = self.OPTIONS.MissingTagValue
        if missing and mval ~= nil then list[#list + 1] = mval end
    else
        list[#list + 1] = val
    end
end

-- (Perl's `join $sep, @val`: numbers stringify the Perl way)
local function joinValues(sep, list)
    local strs = {}
    for k, v in ipairs(list) do strs[k] = ExifTool.NumStr(v) end
    return concat(strs, sep)
end

--------------------------------------------------------------------------------
-- Convert tag names to values or variables in a string
-- (eg. '${EXIF:ISO}x $$' --> '100x $' without hash ref, or "$info{'EXIF:ISO'}x $" with)
-- Inputs: 0) ExifTool object ref, 1) string with embedded tag names,
--         2) reference to list of found tags or undef to use FOUND_TAGS, 3) Options:
--               undef    - set missing tags to ''
--              'Error'   - issue minor error on missing tag (and return undef if error sent)
--              'Warn'    - issue minor warning on missing tag (and return undef if warning sent)
--              'Silent'  - just return undef on missing tag (no errors/warnings)
--               Hash ref - defined to interpolate as variables in string instead of values
--                          --> receives tag/value pairs for interpolation of the variables
--         4) document group name if extracting from a specific document
--         5) hash ref to cache tag keys for subsequent calls in document loop
-- Returns: string with embedded tag values (or '$info{TAGNAME}' entries with Hash ref option)
-- Notes:
-- - tag names are not case sensitive and may end with '#' for ValueConv value
-- - uses MissingTagValue option if set
-- - '$GROUP:all' evaluates to 1 if any tag from GROUP exists, or 0 otherwise
-- - advanced feature allows Perl expressions inside braces (eg. '${model;tr/ //d}')
-- - an error/warning in an advanced expression ("${TAG;EXPR}") generates an error
--   if option set to 'Error', or a warning otherwise
-- Port notes:
-- - Lua cannot eval Perl, so an advanced formatting expression runs through
--   perl.eval (statements on $_ with s///, tr///, assignment, ?:, `if`
--   modifiers and blocks, `my` variables, split/join/sprintf/substr, method
--   calls on $self, the DateFmt/ShiftTime/NoDups/SetTags helpers); code
--   outside that subset dies like an eval that fails to compile, with
--   "Perl syntax unsupported in lexiftool: ..." as its message: $_ keeps
--   its value and the error/warning is issued as upstream does.
function Writer.InsertTagValues(self, line, foundTags, opt, docGrp, cache)
    local rtnStr = ''
    local docNum, tag

    if docGrp then
        docNum = matches(docGrp, [[(\d+(-\d+)*)$]]) or 0
    else
        cache = nil     -- no cache if no document groups
    end
    foundTags = foundTags or self.FOUND_TAGS or {}
    while true do
        -- `$line =~ s/(.*?)\$(\{\s*)?([-\w]*\w|\$|\/)//s`
        local pre, bra, var, en = matches(line, [[(?s)^(.*?)\$(\{\s*)?([-\w]*\w|\$|\/)]])
        if not pre then break end
        line = line:sub(en + 1)
        local tags, tg, val, vals, type_, expr, didExpr, asList = {}, nil, nil, {}, nil, nil, nil, nil
        -- "$$" represents a "$" symbol, and "$/" is a newline
        if var == '$' or var == '/' then
            if bra then line = perl.subst(line, [[^\s*\}]], '') end
            if var == '/' then
                var = "\n"
            elseif matches(line, [[^self\b]]) and not matches(rtnStr, [[\$$]]) then
                var = '$$'      -- ("$$self{var}" in string)
            end
            rtnStr = rtnStr .. pre .. var
            goto nextVar
        end
        -- allow multiple group names
        while true do
            local v2, rest = matches(line, [[(?s)^:([-\w]*\w)(.*)]])
            if not v2 then break end
            local group = var
            var, line = v2, rest
            var = group .. ':' .. var
        end
        -- allow trailing '#' to indicate ValueConv value
        if matches(line, '^#') then
            line = perl.subst(line, '^#', '')
            type_ = 'ValueConv'
        end
        -- special advanced formatting '@' feature to evaluate list values separately
        if bra and matches(line, [[^\@]]) then
            local hash = matches(line, [[^\@(#)?]])
            line = perl.subst(line, [[^\@(#)?]], '')
            asList = true
            if hash then type_ = 'ValueConv' end
        end
        -- remove trailing bracket if there was a leading one
        -- and extract Perl expression from inside brackets if it exists
        if bra then
            local closed = matches(line, [[^\s*\}]])
            if closed then
                line = perl.subst(line, [[^\s*\}]], '')
            else
                local part, pen = matches(line, [[(?s)^\s*;\s*(.*?)\s*\}]])
                if part then
                    line = line:sub(pen + 1)
                    expr = ''
                    local level = 0
                    while true do
                        -- increase nesting level for each opening brace
                        for _ in perl.eachMatch(part, [[\{]]) do level = level + 1 end
                        expr = expr .. part
                        if level == 0 then break end
                        -- get next part
                        local nextPart, nen = matches(line, [[(?s)^(.*?)\s*\}]])
                        if not nextPart then break end
                        line = line:sub(nen + 1)
                        part = nextPart
                        expr = expr .. '}'  -- this brace was part of the expression
                        level = level - 1
                    end
                    -- use default Windows filename filter if expression is empty
                    if #expr == 0 then expr = 'tr(/\\\\?*:|"<>\\0)()d' end
                end
            end
        end
        tags[#tags + 1] = var
        ExifTool.ExpandShortcuts(tags)
        if #tags == 0 then
            rtnStr = rtnStr .. pre
            goto nextVar
        end
        -- save advanced formatting expression to allow access by user-defined ValueConv
        self.FMT_EXPR = expr

        while true do
            -- temporarily reset ListJoin option if evaluating list values separately
            local oldListJoin
            if asList then oldListJoin = self:Options('ListJoin', nil) end
            tag = remove(tags, 1)
            local lcTag = lc(tag)
            if cache and not matches(lcTag, '(^|:)all$') then
                -- remove group from tag name (but not lower-case version)
                local group
                local g, t = matches(tag, '^(.*):(.*)')
                if g then group, tag = g, t end
                -- cache tag keys to speed processing for a large number of sub-documents
                -- (similar to code in BuildCompositeTags(), but this is case-insensitive)
                local cacheTag = cache[lcTag]
                if not cacheTag then
                    cacheTag = {}
                    cache[lcTag] = cacheTag
                    -- find all matching keys, organize into groups, and store in cache
                    local ex = self.TAG_EXTRA
                    local found = {}
                    for _, k in ipairs(foundTags) do
                        if perl.isMatchDyn(k, '(?i)^' .. tag .. [[(\s|$)]]) then found[#found + 1] = k end
                    end
                    if group ~= nil then found = self:GroupMatches(group, found) end
                    for _, k in ipairs(found) do
                        local doc = (ex[k] and ex[k].G3) or 0
                        if cacheTag[doc] ~= nil then
                            local cur = matches(cacheTag[doc], [[ \((\d+)\)$]])
                            if not cur then goto nextFound end
                            -- keep the most recently extracted tag
                            local num = matches(k, [[ \((\d+)\)$]])
                            if num and tonumber(num) < tonumber(cur) then goto nextFound end
                        end
                        cacheTag[doc] = k
                        ::nextFound::
                    end
                end
                local doc
                local m1, m2 = matches(lcTag, [[\b(main|doc(\d+(-\d+)*)):]])
                if m1 then
                    doc = m2 or 0
                else
                    doc = docNum
                end
                if cacheTag[doc] then
                    tag = cacheTag[doc]
                    val = self:GetValue(tag, type_)
                end
            else
                -- add document number to tag if specified and it doesn't already exist
                if docGrp and not matches(lcTag, [[\b(main|doc\d+):]]) then
                    tag = docGrp .. ':' .. tag
                    lcTag = lc(tag)
                end
                local et, fileTags = self, foundTags
                local fileGrp = matches(tag, [[(?i)(\bfile\d+):]])
                if fileGrp then
                    tag = perl.subst(tag, [[(?i)(\bfile\d+):]], '')
                    et = self.ALT_EXIFTOOL[ucfirst(lc(fileGrp))]   -- (ucfirst lc $1)
                    if et then
                        fileTags = et.FoundTags or {}
                    else
                        et = self
                        tag = 'no_alt_file'
                    end
                end
                local userParam = et.OPTIONS.UserParam
                if lcTag == 'all' then
                    val = 1     -- always some tag available
                elseif userParam and userParam[lcTag] ~= nil then
                    val = userParam[lcTag]
                elseif matches(tag, '(.*):(.+)') then
                    local group, found
                    group, tag = matches(tag, '(.*):(.+)')
                    -- join values of all matching tags if "All" group is used
                    -- (and remove "All" from group prefix)
                    if matches(group, [[(?i)(^|:)(all|\*)(:|$)]]) then
                        group = perl.subst(group, [[(?i)(^|:)(all|\*)(:|$)]], function(c1, _, c3)
                            -- (Perl `/$1 and $3/e`)
                            if perlTruthy(c1) then return c3 end
                            return c1
                        end)
                        if lc(tag) == 'all' then
                            if perlTruthy(group) then
                                found = et:GroupMatches(group, fileTags)
                            else
                                found = fileTags
                            end
                        else
                            found = {}
                            for _, k in ipairs(fileTags) do
                                if perl.isMatchDyn(k, '(?i)^' .. tag .. [[(\s|$)]]) then found[#found + 1] = k end
                            end
                            if perlTruthy(group) then found = et:GroupMatches(group, found) end
                        end
                        for _, k in ipairs(found) do
                            Writer.PushValue(self, (et:GetValue(k, type_)), vals)
                        end
                    elseif lc(tag) == 'all' then
                        -- return "1" if any tag from the specified group exists
                        val = #et:GroupMatches(group, fileTags) > 0 and 1 or 0
                    else
                        -- find the specified tag
                        found = {}
                        for _, k in ipairs(fileTags) do
                            if perl.isMatchDyn(k, '(?i)^' .. tag .. [[(\s|$)]]) then found[#found + 1] = k end
                        end
                        found = et:GroupMatches(group, found)
                        for _, t in ipairs(found) do
                            tg = t
                            if val ~= nil and matches(tg, [[ \((\d+)\)$]]) then
                                -- take the most recently extracted tag
                                local tagNum = matches(tg, [[ \((\d+)\)$]])
                                local cur = matches(tag, [[ \((\d+)\)$]])
                                if not cur or tonumber(cur) > tonumber(tagNum) then goto nextMatch end
                            end
                            val = et:GetValue(tg, type_)
                            tag = tg
                            if not tag:find(' ', 1, true) then break end    -- all done if we got our best match
                            ::nextMatch::
                        end
                    end
                elseif tag == 'self' then
                    val = et    -- ("$self{var}" or "$file1:self{var}" in string)
                else
                    -- get the tag value (note: this direct access allows excluded tags
                    -- to be accessed if the case is correct and a group name is not used)
                    val = et:GetValue(tag, type_)
                    if val == nil then
                        -- check for tag name with different case
                        for _, k in ipairs(fileTags) do
                            if perl.isMatchDyn(k, '(?i)^' .. tag .. '$') then tg = k break end
                        end
                        if tg ~= nil then
                            val = et:GetValue(tg, type_)
                            -- (upstream also sets `$tag = $tg` here; nothing reads it)
                        end
                    end
                end
            end
            if asList then self:Options('ListJoin', oldListJoin) end
            Writer.PushValue(self, val, vals, asList)
            val = nil
            if #tags == 0 then break end
        end
        if #vals > 0 then
            if val ~= nil then Writer.PushValue(self, val, vals) end
            val = joinValues(self.OPTIONS.ListSep, vals)
        elseif val ~= nil then
            Writer.PushValue(self, val, vals)   -- (so the eval has access to @val if required)
        end
        -- evaluate advanced formatting expression if given (eg. "${TAG;EXPR}")
        if expr ~= nil and val ~= nil then
            local evalWarning
            advFmtSelf = self    -- set variable for access to $self in helper functions
            -- (the variables and helper functions the expression sees: $_ is
            --  evalVars._, read back after each eval)
            local evalVars = { self = self, val = vals, tag = tag, advFmtSelf = advFmtSelf }
            local evalFuncs = {
                DateFmt = function(fmt) evalVars._ = Writer.DateFmt(fmt, evalVars._) return evalVars._ end,
                NoDups = function(flag) evalVars._ = Writer.NoDups(evalVars._, flag) return evalVars._ end,
                -- (Shift.pl's single-argument ShiftTime: shifts $_, returns
                --  the error string or undef)
                ShiftTime = function(shift)
                    local new, err = Shift.ShiftTime(evalVars._, shift)
                    if new ~= nil then evalVars._ = new end
                    return err
                end,
                SetTags = function(...)
                    local rtn, new = Writer.SetTags(evalVars._, ...)
                    evalVars._ = new
                    return rtn
                end,
            }
            local function evalExpr()
                local ok, err = pcall(perl.eval, expr, evalVars, evalFuncs)
                if not ok then evalWarning = perl.isDie(err) and err.msg or tostring(err) end
            end
            if asList then
                local n = #vals
                for i = 1, n do
                    evalVars._ = vals[i]
                    --### eval advanced formatting expression ($_, $self, @val, $tag, $advFmtSelf)
                    evalExpr()
                    vals[i] = evalVars._
                end
                -- join back together if any values are still defined
                local newVals = {}
                for i = 1, n do
                    if vals[i] ~= nil then newVals[#newVals + 1] = vals[i] end
                end
                vals = newVals
                if #vals > 0 then val = joinValues(self.OPTIONS.ListSep, vals) else val = nil end
            else
                evalVars._ = val
                --### eval advanced formatting expression ($_, $self, @val, $tag, $advFmtSelf)
                evalExpr()
                val = evalVars._
                if type(val) == 'table' and val.ref == nil then val = joinValues(self.OPTIONS.ListSep, val) end
            end
            if evalWarning then
                local g3 = ''
                if docGrp and not matches(var, [[(?i)\b(main|doc\d+):]]) then g3 = docGrp .. ':' end
                local str = ExifTool.CleanWarning(evalWarning) .. " for '" .. g3 .. var .. "'"
                if opt then
                    if opt == 'Error' then
                        self:Error(str)
                    elseif opt ~= 'Silent' then
                        self:Warn(str)
                    end
                end
            end
            advFmtSelf = nil
            didExpr = true  -- set flag indicating an expression was evaluated
        end
        if not (val ~= nil or (type(opt) == 'table' and perlTruthy(self.OPTIONS.UndefTags))) then
            val = self.OPTIONS.MissingTagValue
            if val == nil then
                local g3 = ''
                if docGrp and not matches(var, [[(?i)\b(main|doc\d+):]]) then g3 = docGrp .. ':' end
                local msg
                if didExpr then
                    msg = "Advanced formatting expression returned undef for '" .. g3 .. var .. "'"
                else
                    msg = "Tag '" .. g3 .. var .. "' not defined"
                end
                if type(opt) == 'table' then
                    if perlTruthy(self.OPTIONS.IgnoreMinorErrors) then val = '' end
                elseif opt then
                    -- (upstream calls the method named by $opt: Error or Warn)
                    if opt == 'Silent' or perlTruthy(self[opt](self, msg, 2)) then
                        self.FMT_EXPR = nil
                        return nil
                    end
                    val = ''
                end
            end
        end
        if type(opt) == 'table' then
            if type_ then var = var .. '#' end
            if expr ~= nil then
                -- generate unique variable name for this modified tag value
                local i = 1
                while opt[var .. '.expr' .. i] ~= nil do i = i + 1 end
                var = var .. '.expr' .. i
            end
            rtnStr = rtnStr .. pre .. "$info{'" .. var .. "'}"
            opt[var] = val
        else
            rtnStr = rtnStr .. pre .. (val == nil and '' or ExifTool.NumStr(val))
        end
        ::nextVar::
    end
    self.FMT_EXPR = nil
    return rtnStr .. line
end

--------------------------------------------------------------------------------
-- Reformat date/time value in $_ based on specified format string
-- Inputs: 0) date/time format string
-- Returns: Reformatted date/time string
-- (Lua has no $_: the value comes in as argument 1 and the new $_ is returned)
function Writer.DateFmt(fmt, val)
    local et = setmetatable({ OPTIONS = { DateFormat = fmt, StrictDate = 1 } }, ExifTool)
    local shift
    if advFmtSelf then
        shift = advFmtSelf.OPTIONS.GlobalTimeShift
        if shift ~= nil then
            et.OPTIONS.GlobalTimeShift = shift
            et.GLOBAL_TIME_OFFSET = advFmtSelf.GLOBAL_TIME_OFFSET
        end
    end
    val = et:ConvertDateTime(val)
    if val == nil then perl.print(io.stderr, "Error converting date/time\n") end
    if shift ~= nil then advFmtSelf.GLOBAL_TIME_OFFSET = et.GLOBAL_TIME_OFFSET end
    return val
end

--------------------------------------------------------------------------------
-- Utility routine to remove duplicate items from default input string
-- Inputs: 0) true to set $_ to undef if not changed
-- Notes: - for use only in advanced formatting expressions
-- (Lua: $_ is argument 1 and the new $_ the return value; the flag is argument 2)
function Writer.NoDups(val, flag)
    local seen = { }
    local sep = advFmtSelf and advFmtSelf.OPTIONS.ListSep or ', '
    local items = { }
    for _, item in ipairs(perl.splitDyn(perl.quotemeta(sep), val)) do
        if not seen[item] then
            seen[item] = true
            items[#items + 1] = item
        end
    end
    local new = join(sep, items)
    if perlTruthy(flag) and new == val then return nil end
    return new
end

--------------------------------------------------------------------------------
-- Utility routine to set in $_ image from current object
-- Inputs: 0-N) list of tags to copy
-- Returns: Return value from WriteInfo
-- Notes: - for use only in advanced formatting expressions
-- (Lua: the image in $_ is argument 1; returns WriteInfo's value and the new $_)
function Writer.SetTags(val, ...)
    local self = advFmtSelf
    local et = ExifTool.new()
    et:SetNewValuesFromFile(self, ...)
    local buff = { value = val }
    local rtn = et:WriteInfo(buff)
    return rtn, perlStr(buff.value)
end

--------------------------------------------------------------------------------
-- Is specified tag writable
-- Inputs: 0) tag name, case insensitive (optional group name currently ignored)
-- Returns: 0=exists but not writable, 1=writable, undef=doesn't exist
function Writer.IsWritable(tag)
    tag = subst(tag, '^(.*):', '') -- ignore group name
    local tagInfoList = FindTagInfo(tag)
    if #tagInfoList == 0 then
        if perlTruthy(TagExists(tag)) then return 0 end
        return nil
    end
    for _, tagInfo in ipairs(tagInfoList) do
        if tagInfo.Writable ~= nil then return perlTruthy(tagInfo.Writable) and 1 or 0 end
        if tagInfo.Table and perlTruthy(tagInfo.Table.WRITABLE) then return 1 end
        -- must call WRITE_PROC to autoload writer because this may set the writable tag
        local writeProc = tagInfo.Table and tagInfo.Table.WRITE_PROC
        if writeProc then
            writeProc()  -- dummy call to autoload writer
            if perlTruthy(tagInfo.Writable) then return 1 end
        end
    end
    return 0
end

--------------------------------------------------------------------------------
-- Check to see if these are the same file
-- Inputs: 0) ExifTool ref, 1) first file name, 2) second file name
-- Returns: true if file names reference the same file
function Writer.IsSameFile(self, file, file2)
    if lc(file) ~= lc(file2) then return 0 end  -- (only looking for differences in case)
    local isSame
    local tmp1 = file .. '_ExifTool_tmp_' .. perl.pid()
    local tmp2 = file2 .. '_ExifTool_tmp_' .. perl.pid()
    do
        -- (upstream defers SIGINT while the temporary file exists; Lua has no
        --  signal handling, so there is nothing to defer)
        local tmp = self:Open(tmp1, '>')
        if tmp then
            tmp:close()
            if self:Exists(tmp2) then isSame = 1 end
            -- (upstream `$self->Unlink($tmp1)`: Unlink is not ported yet, and
            --  its non-Windows half is this unlink)
            perl.unlink(tmp1)
        end
    end
    return isSame
end

--------------------------------------------------------------------------------
-- Is this a raw file type?
-- Inputs: 0) ExifTool ref
-- Returns: true if FileType is a type of RAW image
function Writer.IsRawType(self)
    return rawType[self.FileType]
end

--------------------------------------------------------------------------------
-- Copy file attributes from one file to another
-- Inputs: 0) ExifTool ref, 1) source file name, 2) destination file name
-- Notes: eventually add support for extended attributes?
function Writer.CopyFileAttrs(self, src, dst)
    local st = perl.stat(src)
    local mode, uid, gid
    if st then mode, uid, gid = st.modeNum, st.uid, st.gid end
    -- copy file attributes unless we already set them
    if mode ~= nil and self:GetNewValue('FilePermissions') == nil then
        pcall(perl.chmod, mode & 4095, dst)
    end
    local newUid = self:GetNewValue('FileUserID')
    local newGid = self:GetNewValue('FileGroupID')
    if uid ~= nil and gid ~= nil and (newUid == nil or newGid == nil) then
        if newGid ~= nil then gid = newGid end
        if newUid ~= nil then uid = newUid end
        pcall(perl.chown, uid, gid, dst)
    end
end

--------------------------------------------------------------------------------
-- Get new file path name
-- Inputs: 0) existing name (may contain directory),
--         1) new file name, new directory, or new path (dir+name)
-- Returns: new file path name
function Writer.GetNewFileName(oldName, newName)
    local dir, name = matches(oldName, '(.*/)(.*)')
    if dir == nil then dir, name = '', oldName end
    if isMatch(newName, '/$') then
        newName = newName .. name -- change dir only
    elseif not isMatch(newName, '/') then
        newName = dir .. newName  -- change name only if newname doesn't specify dir
    end                           -- else change dir and name
    return newName
end

--------------------------------------------------------------------------------
-- Get next available tag key
-- Inputs: 0) hash reference (keys are tag keys), 1) tag name
-- Returns: next available tag key
function Writer.NextFreeTagKey(info, tag)
    if info[tag] == nil then return tag end
    local i = 1
    while true do
        local key = tag .. ' (' .. i .. ')'
        if info[key] == nil then return key end
        i = i + 1
    end
end

--------------------------------------------------------------------------------
-- Get write group for specified tag
-- Inputs: 0) new value hash reference
-- Returns: Write group name
function Writer.GetWriteGroup(nvHash)
    return nvHash.WriteGroup
end

--------------------------------------------------------------------------------
-- Get name of write group or family 1 group
-- Inputs: 0) ExifTool ref, 1) tagInfo ref, 2) write group name
-- Returns: Name of group for verbose message
-- (Writer.pl:3765-3774)
function Writer.GetWriteGroup1(self, tagInfo, writeGroup)
    if not (writeGroup == 'MakerNotes' or writeGroup == 'XMP' or writeGroup == 'Composite' or
            writeGroup == 'QuickTime') then
        return writeGroup
    end
    return self:GetGroup(tagInfo, 1)
end

--------------------------------------------------------------------------------
-- Get list of tags to write for Geolocate feature
-- Inputs: 0) ExifTool ref, 1) group name(s),
--         2) 0=prefer writing City, 1=prefer writing GPS, undef=deleting tags
-- Returns: list of tags to write/delete
function Writer.GetGeolocateTags(self, wantGroup, writeGPS) -- luacheck: ignore 212
    local grps = { }
    if perlTruthy(wantGroup) then
        for _, g in ipairs(split(':', wantGroup)) do grps[#grps + 1] = lc(g) end
    end
    local grpSet = { }   -- lookup for specified groups
    for _, g in ipairs(grps) do grpSet[g] = g end
    if grpSet.exif and not grpSet.gps then
        grpSet.gps = 'gps'
        grps[#grps + 1] = 'gps'
    end
    local tagGroups = {
        ['xmp-iptcext']   = { 'LocationShownCity', 'LocationShownProvinceState', 'LocationShownCountryCode',
                              'LocationShownCountryName', 'LocationShownGPSLatitude', 'LocationShownGPSLongitude' },
        ['xmp-photoshop'] = { 'City', 'State', 'Country' },
        ['xmp-iptccore']  = { 'CountryCode' },
        ['iptc']          = { 'City', 'Province-State', 'Country-PrimaryLocationCode', 'Country-PrimaryLocationName' },
        ['gps']           = { 'GPSLatitude', 'GPSLongitude', 'GPSLatitudeRef', 'GPSLongitudeRef' },
        ['xmp-exif']      = { 'GPSLatitude', 'GPSLongitude' },
        ['itemlist']      = { 'GPSCoordinates' },
        ['userdata']      = { 'GPSCoordinates' },
        -- more general groups not in this lookup: XMP and QuickTime
    }
    local tags = { }
    local function push(...)
        for _, t in ipairs({ ... }) do tags[#tags + 1] = t end
    end
    -- set specific City and GPS tags
    for _, grp in ipairs(grps) do
        if tagGroups[grp] then
            for _, t in ipairs(tagGroups[grp]) do push(grp .. ':' .. t) end
        end
    end
    -- set default XMP City tags if necessary
    if not perlTruthy(writeGPS) then
        if grpSet['keys'] then push('Keys:LocationName') end
        if grpSet.xmp or (#tags == 0 and not grpSet.quicktime) then
            push('XMP:City', 'XMP:State', 'XMP:CountryCode', 'XMP:Country', 'Keys:LocationName')
        end
    end
    if writeGPS == nil then writeGPS = 1 end -- (delete both City and GPS)
    if perlTruthy(writeGPS) and grpSet['keys'] then push('Keys:GPSCoordinates') end
    -- set default QuickTime tag if necessary
    local didQT = 0
    for _, t in ipairs(tags) do
        if isMatch(t, 'GPSCoordinates$') then didQT = didQT + 1 end
    end
    if (grpSet.quicktime and didQT == 0) or (perlTruthy(writeGPS) and #tags == 0 and not grpSet.xmp) then
        push('QuickTime:GPSCoordinates')
    end
    -- set default GPS tags if necessary
    if perlTruthy(writeGPS) then
        if grpSet.xmp and not grpSet['xmp-exif'] then push('XMP:GPSLatitude', 'XMP:GPSLongitude') end
        if not perlTruthy(wantGroup) then push('GPSLatitude', 'GPSLongitude', 'GPSLatitudeRef', 'GPSLongitudeRef') end
    end
    return tags
end

--------------------------------------------------------------------------------
-- Inverse date/time print conversion (reformat to YYYY:mm:dd HH:MM:SS[.ss][+-HH:MM|Z])
-- Inputs: 0) ExifTool object ref, 1) Date/Time string, 2) timezone flag:
--               0     - remove timezone and sub-seconds if they exist
--               1     - add timezone if it doesn't exist
--               undef - leave timezone alone
--         3) flag to allow date-only (YYYY, YYYY:mm or YYYY:mm:dd) or time without seconds
-- Returns: formatted date/time string (or undef and issues warning on error)
-- Notes: currently accepts different separators, but doesn't use DateFormat yet
-- (Lua: Time::Piece->strptime is perl.TimePieceStrptime; POSIX::strptime has
--  no counterpart, so evalRequire finds only Time::Piece)
local strptimeLib -- strptime library name if available
function Writer.InverseDateTime(self, val, tzFlag, dateOnly)
    local rtnVal, tz, fs
    local fmt = self.OPTIONS.DateFormat
    val = perlStr(val)
    -- strip off timezone first if it exists
    local sign, tzh, tzm = matches(val, [[(?i)([-+])(\d{1,2}):?(\d{2})\s*(DST)?$]])
    if not perlTruthy(fmt) and sign then
        val = subst(val, [[(?i)([-+])(\d{1,2}):?(\d{2})\s*(DST)?$]], '')
        tz = sprintf(sign .. '%.2d:' .. tzm, tzh)
    elseif not perlTruthy(fmt) and isMatch(val, [[(?i)Z$]]) then
        val = subst(val, [[(?i)Z$]], '')
        tz = 'Z'
    else
        tz = ''
        -- allow special value of 'now'
        if lc(val) == 'now' then return ExifTool.TimeNow(self, tzFlag) end
    end
    -- only convert date if a format was specified and the date is recognizable
    if perlTruthy(fmt) then
        if strptimeLib == nil then
            if perl.evalRequire('POSIX::strptime') then
                strptimeLib = 'POSIX::strptime'
            elseif perl.evalRequire('Time::Piece') then
                strptimeLib = 'Time::Piece'
                -- (call use_locale() to convert localized date/time,
                --  only available in Time::Piece 1.32 and later)
                perl.TimePieceUseLocale()
            else
                strptimeLib = ''
            end
        end
        -- handle fractional seconds (%f) and time zone (%z)
        fs, tz = '', ''
        if isMatch(fmt, [[%(f|:?z)]]) then
            if isMatch(fmt, [[(.*[^%])%f]]) then
                fmt = subst(fmt, [[(.*[^%])%f]], '$1')
                local pre, frac = matches(val, [[(.*)(\.\d+)]])
                if pre then
                    val = subst(val, [[(.*)(\.\d+)]], '$1') -- (take last .### as fractional seconds)
                    fs = frac
                end
            end
            local _, colon = matches(fmt, [[(.*[^%])%(:?)z]])
            if colon then
                fmt = subst(fmt, [[(.*[^%])%(:?)z]], '$1')
                local pat = '(.*)([-+]\\d{2})' .. colon .. '(\\d{2})'
                local _, h, m = perl.matchesDyn(val, pat)
                if h then
                    val = perl.substDyn(val, pat, '$1')
                    tz = h .. ':' .. m
                end
            end
        end
        local lib, wrn, a = strptimeLib, nil, nil
        while true do   -- TryLib: for ($lib=$strptimeLib; ; $lib='')
            -- handle %s format ourself (not supported in Fedora, see forum15032)
            if fmt == '%s' then
                val = ExifTool.ConvertUnixTime(val, 1)
                break
            end
            if lib == '' then
                if not perlTruthy(self.OPTIONS.StrictDate) then break end
                perl.warn(wrn or "Install POSIX::strptime or Time::Piece for inverse date/time conversions\n")
                return nil
            elseif lib == 'POSIX::strptime' then
                a = {}  -- (not reached: see above)
            else
                -- protect against a negative epoch time, it can cause a hard crash in Windows
                if perl.osname() == 'MSWin32' and isMatch(fmt, '%s') and isMatch(val, [[-\d]]) then
                    perl.warn("Can't convert negative epoch time\n")
                    return nil
                end
                local ok, sec, min, hour, mday, mon, year = pcall(perl.TimePieceStrptime, val, fmt)
                if ok then
                    a = { [0] = sec, min, hour, mday, mon, year }
                elseif perl.isDie(sec) then
                    a = {}
                else
                    error(sec, 0)
                end
            end
            if a[5] ~= nil and perl.length(a[5]) > 0 then
                a[5] = a[5] + 1900 -- add 1900 to year
            else
                wrn = 'Invalid date/time (no year) using ' .. lib .. '\n'
                goto nextLib
            end
            if a[4] ~= nil and perl.length(a[4]) > 0 then a[4] = a[4] + 1 end -- add 1 to month
            for i = 0, 4 do
                if a[i] == nil or perl.length(a[i]) == 0 then
                    if i < 2 or perlTruthy(dateOnly) then -- (allow missing minutes/seconds)
                        a[i] = '  '
                    else
                        wrn = 'Incomplete date/time specification using ' .. lib .. '\n'
                        goto nextLib
                    end
                elseif perl.length(a[i]) < 2 then
                    a[i] = '0' .. perlStr(a[i]) -- pad to 2 digits if necessary
                end
            end
            val = join(':', { a[5], a[4], a[3] }) .. ' ' .. join(':', { a[2], a[1], a[0] }) .. fs .. tz
            break
            ::nextLib::
            lib = ''
        end
    end
    local pre, yr = matches(val, [[^(.*?)(\d{4})]])
    if yr then                                  -- get YYYY
        local a = perl.findAll(substr(val, #pre + 4), [[\d{1,2}]]) -- get mm, dd, HH, and maybe MM, SS
        for i = 1, #a do
            if #a[i] < 2 then a[i] = '0' .. a[i] end   -- pad to 2 digits if necessary
        end
        if #a >= 3 then
            local ss = a[5]                     -- get SS
            while #a < 5 do a[#a + 1] = '00' end -- add MM, SS if not given
            -- get sub-seconds if they exist (must be after SS, and have leading ".")
            if not perlTruthy(fmt) then
                fs = (#a > 5 and matches(val, [[(\.\d+)\s*$]])) or ''
            end
            -- add/remove timezone if necessary
            if perlTruthy(tzFlag) then
                if not perlTruthy(tz) then
                    -- determine timezone offset for this time
                    -- (Time::Local is the perl.timegm/ExifTool.TimeLocal pair)
                    local args = { a[5], a[4], a[3], a[2], a[1] - 1, yr }
                    for i = 1, 6 do args[i] = perl.num(args[i]) end
                    local diff = perl.timegm(table.unpack(args)) - ExifTool.TimeLocal(table.unpack(args))
                    tz = ExifTool.TimeZoneString(diff / 60)
                end
            elseif tzFlag ~= nil then
                tz, fs = '', ''                 -- remove timezone and sub-seconds
            end
            if ss ~= nil and perl.num(ss) < 60 then
                ss = ':' .. ss
            elseif perlTruthy(dateOnly) then
                ss = ''
            else
                ss = ':00'
            end
            -- construct properly formatted date/time string
            if perl.num(a[1]) < 1 or perl.num(a[1]) > 12 then
                perl.warn("Month '" .. a[1] .. "' out of range 1..12\n")
                return nil
            end
            if perl.num(a[2]) < 1 or perl.num(a[2]) > 31 then
                perl.warn("Day '" .. a[2] .. "' out of range 1..31\n")
                return nil
            end
            if perl.num(a[3]) > 24 then perl.warn("Hour '" .. a[3] .. "' out of range 0..24\n") return nil end
            if perl.num(a[4]) > 59 then perl.warn("Minutes '" .. a[4] .. "' out of range 0..59\n") return nil end
            rtnVal = yr .. ':' .. a[1] .. ':' .. a[2] .. ' ' .. a[3] .. ':' .. a[4] .. ss .. fs .. tz
        elseif perlTruthy(dateOnly) then
            rtnVal = join(':', { yr, table.unpack(a) })
        end
    end
    if not perlTruthy(rtnVal) then perl.warn("Invalid date/time (use YYYY:mm:dd HH:MM:SS[.ss][+/-HH:MM|Z])\n") end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Write to binary data block
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: Binary data block or undefined on error
-- (port: the block is a carray while it is edited, returned as a string;
--  the `eval $count` of a Format size understands what the ported tables use
--  there -- a number, $size with an optional -N/-0xN, $$self{Key} with an
--  optional N* factor)
local function evalFormatCount(self, count, size)
    local n = tonumber(count)
    if n then return n end
    local sub = count:match('^%$size%-0x(%x+)$')
    if sub then return size - tonumber(sub, 16) end
    sub = count:match('^%$size%-(%d+)$')
    if sub then return size - tonumber(sub) end
    if count == '$size' then return size end
    local mult, key = count:match('^(%d+)%*%$%$self%{([A-Za-z0-9]+)%}$')
    if mult then return tonumber(mult) * (tonumber(self[key]) or 0) end
    key = count:match('^%$%$self%{([A-Za-z0-9]+)%}$')
    if key then return tonumber(self[key]) or 0 end
    return nil
end
function Writer.WriteBinaryData(self, dirInfo, tagTablePtr)
    if not self then return 1 end    -- allow dummy access to autoload this package

    -- get default format ('int8u' unless specified)
    local dataPt = dirInfo.DataPt
    if not dataPt then return nil end
    local dataLen = perl.length(dataPt)
    local defaultFormat = tagTablePtr.FORMAT or 'int8u'
    local increment = ExifTool.FormatSize(defaultFormat)
    if not perlTruthy(increment) then
        perl.warn("Unknown format " .. defaultFormat .. "\n")
        return nil
    end
    -- extract data members first if necessary
    local varOffsets = { }
    if tagTablePtr.DATAMEMBER then
        dirInfo.DataMember = tagTablePtr.DATAMEMBER
        dirInfo.VarFormatData = varOffsets
        self:ProcessBinaryData(dirInfo, tagTablePtr)
        dirInfo.DataMember = nil
        dirInfo.VarFormatData = nil
    end
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen
    if dirLen == nil or dirLen > dataLen - dirStart then dirLen = dataLen - dirStart end
    local newData = substr(dataPt, dirStart, dirLen)
    if not perlTruthy(newData) then return nil end
    local dirName = dirInfo.DirName
    local varSize = 0
    local varInfo = { }
    for i = 1, #varOffsets do varInfo[i] = varOffsets[i] end
    dataPt = carray.new('char'):append(newData)
    local tagInfoList = Writer.GetNewTagInfoList(self, tagTablePtr)
    tsort(tagInfoList, function(a, b) return a.TagID < b.TagID end)
    for _, tagInfo in ipairs(tagInfoList) do
        local tagID = tagInfo.TagID
        -- evaluate conditional tags now if necessary
        if (type(tagTablePtr[tagID]) == 'table' and tagTablePtr[tagID][1] ~= nil) or tagInfo.Condition then
            local writeInfo = self:GetTagInfo(tagTablePtr, tagID)
            if not (writeInfo and writeInfo == tagInfo) then goto next_tag end
        end
        -- add offsets for variable-sized tags if necessary
        while #varInfo > 0 and varInfo[1][1] < tagID do
            varSize = varInfo[1][2]  -- get accumulated variable size
            remove(varInfo, 1)
        end
        do
            local count = 1
            local format = tagInfo.Format
            local entry = perl.int(tagID) * increment + varSize -- relative offset of this entry
            if format then
                local fm, fc = format:match('^(.*)%[(.*)%]$')
                if fm then
                    format = fm
                    count = fc
                    local size = dirLen -- used in eval
                    --### eval Format size ($size, $self) - NOTE: %val not supported for writing
                    count = evalFormatCount(self, count, size)
                    if count == nil then perl.warn("Can't evaluate count " .. fc .. "\n"); goto next_tag end
                elseif format == 'string' then
                    -- string with no specified count runs to end of block
                    count = (dirLen > entry) and dirLen - entry or 0
                end
            else
                format = defaultFormat
            end
            -- read/write using variable format if changed in Hook
            if #varInfo > 0 and varInfo[1][1] == tagID then format = varInfo[1][3] end
            local val = ExifTool.ReadValue(dataPt, entry, format, count, dirLen-entry)
            if val == nil then goto next_tag end
            local nvHash = Writer.GetNewValueHash(self, tagInfo, self.CUR_WRITE_GROUP)
            if Writer.IsOverwriting(self, nvHash, val) <= 0 then goto next_tag end
            local newVal = Writer.GetNewValue(self, nvHash)
            if newVal == nil then goto next_tag end    -- can't delete from a binary table
            -- update DataMember with new value if necessary
            if tagInfo.DataMember then self[tagInfo.DataMember] = newVal end
            -- only write masked bits if specified
            local mask = tagInfo.Mask
            if mask then newVal = ((perl.int(newVal) << tagInfo.BitShift) & mask) | (perl.int(val) & ~mask) end
            -- set the size
            if tagInfo.DataTag and not tagInfo.IsOffset then
                if perl.num(newVal) ~= 0xfeedfeed then perl.warn('Internal error') end
                local data = self:GetNewValue(tagInfo.DataTag)
                if data ~= nil then newVal = perl.length(data) end
                local fmt = tagInfo.Format or tagTablePtr.FORMAT or 'int32u'
                if isMatch(fmt, '^int16') and newVal > 0xffff then
                    self:Error(tagInfo.DataTag .. " is too large (64 KiB max. for this file)")
                end
            end
            local rtnVal = Writer.WriteValue(newVal, format, count, dataPt, entry)
            if rtnVal ~= nil then
                self:VerboseValue("- " .. perlStr(dirName) .. ":" .. tagInfo.Name, val)
                self:VerboseValue("+ " .. perlStr(dirName) .. ":" .. tagInfo.Name, newVal)
                self.CHANGED = (self.CHANGED or 0) + 1
            else
                self:Warn("Error packing " .. tagInfo.Name .. " value")
            end
        end
        ::next_tag::
    end
    -- add necessary fixups for any offsets
    if tagTablePtr.IS_OFFSET and dirInfo.Fixup then
        varSize = 0
        varInfo = { }
        for i = 1, #varOffsets do varInfo[i] = varOffsets[i] end
        local fixup = dirInfo.Fixup
        for _, tagID in ipairs(tagTablePtr.IS_OFFSET) do
            local tagInfo = self:GetTagInfo(tagTablePtr, tagID)
            if not tagInfo then goto next_off end
            while #varInfo > 0 and varInfo[1][1] < tagID do
                varSize = varInfo[1][2]
                remove(varInfo, 1)
            end
            do
                local entry = tagID * increment + varSize -- (no offset to dirStart for new dir data)
                if entry > dirLen - 4 then goto next_off end
                -- (Ricoh has 16-bit preview image offsets, so can't just assume int32u)
                local format = tagInfo.Format or tagTablePtr.FORMAT or 'int32u'
                local offset = ExifTool.ReadValue(dataPt, entry, format, 1, dirLen-entry)
                -- ignore if offset is zero (eg. Ricoh DNG uses this to indicate no preview)
                if not perlTruthy(offset) then goto next_off end
                fixup:AddFixup(entry, tagInfo.DataTag, format)
                if not (tagInfo.DataTag and tagInfo.OffsetPair ~= nil) then goto next_off end
                -- NOTE: here we assume there are no var-sized tags between the
                -- OffsetPair tags.  If this ever becomes possible we must recalculate
                -- $varSize for the OffsetPair tag here!
                entry = tagInfo.OffsetPair * increment + varSize
                local size = ExifTool.ReadValue(dataPt, entry, format, 1, dirLen-entry)
                if size == nil then goto next_off end
                if tagInfo.DataTag == 'HiddenData' then
                    self.HiddenData = {
                        Offset = offset,
                        Size   = size,
                        Fixup  = require('lexiftool.Fixup').new(),
                        Base   = dirInfo.Base,
                    }
                    goto next_off
                end
                -- handle the preview image now if this is a JPEG file
                if not (tagInfo.DataTag == 'PreviewImage' and self.FILE_TYPE == 'JPEG') then goto next_off end
                local previewInfo = self.PREVIEW_INFO
                if not previewInfo then
                    previewInfo = {
                        Fixup = require('lexiftool.Fixup').new(),
                    }
                    self.PREVIEW_INFO = previewInfo
                end
                -- set flag indicating we are using short pointers
                if format ~= 'int32u' then previewInfo.IsShort = 1 end
                if tagInfo.IsOffset and perlStr(tagInfo.IsOffset) == '3' then previewInfo.Absolute = 1 end
                -- get the value of the Composite::PreviewImage tag
                previewInfo.Data = Writer.GetNewValue(self, ExifTool.GetCompositeTagInfo('PreviewImage'))
                if previewInfo.Data == nil then
                    if offset >= 0 and offset + size <= dirInfo.DataLen then
                        previewInfo.Data = substr(dirInfo.DataPt,offset,size)
                    else
                        previewInfo.Data = 'LOAD_PREVIEW' -- flag to load preview later
                    end
                end
            end
            ::next_off::
        end
    end
    -- write any necessary SubDirectories
    if tagTablePtr.IS_SUBDIR then
        varSize = 0
        varInfo = { }
        for i = 1, #varOffsets do varInfo[i] = varOffsets[i] end
        for _, tagID in ipairs(tagTablePtr.IS_SUBDIR) do
            local tagInfo = self:GetTagInfo(tagTablePtr, tagID)
            if tagInfo == nil then goto next_sub end
            while #varInfo > 0 and varInfo[1][1] < tagID do
                varSize = varInfo[1][2]
                remove(varInfo, 1)
            end
            do
                local entry = perl.int(tagID) * increment + varSize
                if entry >= dirLen then break end
                -- get value for Condition if necessary
                if not tagInfo then
                    local more = dirLen - entry
                    if more > 128 then more = 128 end
                    local v = substr(dataPt, entry, more)
                    tagInfo = self:GetTagInfo(tagTablePtr, tagID, v)
                    if not tagInfo then goto next_sub end
                end
                local subdir = tagInfo.SubDirectory
                if not subdir then goto next_sub end
                local start = subdir.Start
                local len
                if not perlTruthy(start) then
                    start = entry
                    len = dirLen - start
                else
                    -- (port: a ported Start is a function of ($self, $val, $dirStart))
                    local count = 1
                    local format = tagInfo.Format or defaultFormat
                    local fm, fc = format:match('^(.*)%[(.*)%]$')
                    if fm then format, count = fm, tonumber(fc) or 1 end
                    local val = ExifTool.ReadValue(dataPt, entry, format, count, dirLen - entry)
                    -- ignore directories with a zero offset (ie. missing Nikon ShotInfo entries)
                    if not perlTruthy(val) then goto next_sub end
                    local subStart = 0
                    --### eval Start ($val, $dirStart)
                    start = start(self, val, subStart)
                    if start < subStart or start > dataLen then goto next_sub end
                    len = subdir.DirLen
                    if not (perlTruthy(len) and len <= dataLen - start) then len = dataLen - start end
                end
                local subdirInfo = {
                    DataPt   = dataPt:tostring(),
                    DirStart = start,
                    DirLen   = len,
                    TagInfo  = tagInfo,
                }
                local dat = Writer.WriteDirectory(self, subdirInfo, self:GetTagTable(subdir.TagTable))
                if dat ~= nil and perl.length(dat) > 0 then substr(dataPt, start, len, dat) end
            end
            ::next_sub::
        end
    end
    return dataPt:tostring()
end

-- (upstream %Image::ExifTool::JFIF::Main carries `WRITE_PROC =>
--  \&Image::ExifTool::WriteBinaryData` inline, but WriteBinaryData lives in
--  Writer.pl -- the module lexiftool.lua cannot require at load time without a
--  cycle.  So the table predeclares WRITE_PROC and it is filled in here, the
--  same shape conventions.md §2 prescribes for a forward-referenced proc.)
ExifTool.JFIF.Main.WRITE_PROC = Writer.WriteBinaryData
ExifTool.JFIF.Main.CHECK_PROC = Writer.CheckBinaryData

return Writer
