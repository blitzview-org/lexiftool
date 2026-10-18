--------------------------------------------------------------------------------
-- File:         lexiftool/WriteQuickTime.lua
-- Ported from:  lib/Image/ExifTool/WriteQuickTime.pl
--
-- Description:  Write XMP to QuickTime (MOV and MP4) files
--
-- Revisions:    2013-10-29 - P. Harvey Created
--
-- Port notes:   Write path (upstream WriteQuickTime.pl), first slice: the
--               atom-rewriting engine (WriteMOV/WriteQuickTime), the
--               container recursion through WriteDirectory, the 'mdat'
--               bookkeeping and the stco/co64 chunk-offset fixup that
--               follows from moving the media data.  That is enough to write
--               a nested non-QuickTime directory (XMP, EXIF).  What that
--               slice still left out -- the HEIC item machinery, CR3 CTBO
--               offsets -- arrived with the fourth and fifth slices below;
--               WriteLast, language alternates, movie fragments and trailers
--               are still missing.
--
--               Second slice: editing QuickTime tag VALUES -- CheckQTValue,
--               FormatQTValue, WriteKeys, the Keys tag table, the Keys index
--               remapping in the ItemList, and the modify branch of
--               WriteQuickTime for the three value shapes (ItemList 'data'
--               atoms, '\xa9' international text, plain formats).  Of the
--               Keys table, all entries are ported except 'live-photo-info'
--               (needs an unpack ValueConv with no equivalent here) and the
--               four SubDirectory entries whose target tables are not
--               ported (FaceInfo, PLIST::Main, setu, sdpd).
--
--               Third slice: creating and deleting QuickTime tags -- the
--               addTags block after the atom loop (scalar tags only, in a
--               directory that already exists), the group-deletion branch,
--               and the "delete an empty Meta box" rule with its boxPos
--               bookkeeping.  The Keys part as upstream: $createKeys and
--               $keysPath, the new-tag hash of an ItemList built from the
--               Keys lookups (Remap/Info), %didDir, Meta with mdta handler
--               and empty Keys+ItemList created where Keys tags are
--               written, the Add'ed Keys entries appended to the ItemList,
--               and the Keys lookups dropped after their Meta (language
--               alternates excepted, see below).
--
--               Fourth slice: the offset bookkeeping that CR3 needs --
--               Handle_iloc (with GetVarInt), the full offsetAtom
--               classification, extended (8-byte) atom sizes, the CTBO
--               offset/size fixup for Canon CR3, PreservePadding and the
--               ChunkOffset length update for a rewritten 'uuid' atom, and
--               the VisualSampleDesc child atoms CMP1/CDI1 that carry a CR3
--               track's real ImageWidth/ImageHeight.
--               Canon.uuid/uuid2 got their WRITE_PROC and the CMT1..CMT4
--               SubDirectories their WriteProc, without which the writer
--               never recursed into the CR3 EXIF IFDs at all. Still deferred:
--               WriteLast, language alternates, movie fragments and trailers.
--
--               Fifth slice: writing HEIC items -- SetVarInt, WriteItemInfo
--               with both of its halves (replacing the data of an existing
--               EXIF/XMP item, and creating a new one with its infe/cdsc/iloc
--               entries), the WriteHook call in the atom loop (which is what
--               fills et.ItemInfo while writing, through the same
--               ParseItemLocation/ParseItemInfoEntry/ParseContentDescribes
--               parsers the read path uses, plus the pitm WriteHooks), and
--               the mdatEdit processing in WriteQuickTime that inserts,
--               replaces or drops the item's chunk in the mdat and fixes the
--               mdat header size.  Compressed ('deflate') items are inflated
--               and re-deflated through this port's zlib facade; the CLI does
--               not yet route -api Compress= into the Compress option, so
--               writing NEW compressed XMP is unreachable from the command
--               line.  Deferred: the retracted iinf-sorting block.
--
--               Moved here from QuickTime.lua to mirror upstream's file
--               split; QuickTime.lua loads it on first use of a write
--               routine (upstream AUTOLOAD).  GetLangInfo and WriteNextbase
--               came with the move (no test exercises them).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local substr = perl.substr
local length = perl.length
local sprintf = perl.sprintf
local tr = perl.tr
local tsort = perl.tsort
local perlStr = perl.str
local RandomAccess = require('lexiftool.RandomAccess')
local carray = require('carray')
-- (Writer.pl's Write, loaded on first use like the other Writer calls here)
local function Write(...) return require('lexiftool.Writer').Write(...) end
local perlTruthy = ExifTool.perlTruthy
local NumStr = ExifTool.NumStr
local Get32u = ExifTool.Get32u
local Get16u = ExifTool.Get16u

-- (upstream: package Image::ExifTool::QuickTime -- this file adds to the
--  QuickTime package; the package variables %stringEncoding and %avType and
--  the subs GetVarInt etc. live in QuickTime.lua)
local QuickTime = require('lexiftool.QuickTime')
local stringEncoding = QuickTime.stringEncoding
local avType = QuickTime.avType
local GetVarInt = QuickTime.GetVarInt

local WriteQuickTime = {}

-- maps for adding metadata to various QuickTime-based file types
-- MOV (no 'ftyp', or 'ftyp'='qt  ') -> XMP in 'moov'-'udta'-'XMP_'
local movMap = {
    QuickTime = 'ItemList',    -- (default location for QuickTime tags)
    ItemList  = 'Meta',        -- MOV-Movie-UserData-Meta-ItemList
    Keys      = 'Movie',       -- MOV-Movie-Meta-Keys !! (hack due to different Meta location)
    AudioKeys = 'Track',       -- MOV-Movie-Track-Meta-Keys !!
    VideoKeys = 'Track',       -- MOV-Movie-Track-Meta-Keys !!
    Meta      = 'UserData',
    XMP       = 'UserData',    -- MOV-Movie-UserData-XMP
    Microsoft = 'UserData',    -- MOV-Movie-UserData-Microsoft
    UserData  = 'Movie',       -- MOV-Movie-UserData
    Movie     = 'MOV',
    GSpherical = 'SphericalVideoXML', -- MOV-Movie-Track-SphericalVideoXML
    SphericalVideoXML = 'Track',      -- (video track specifically, don't create if it doesn't exist)
    Track     = 'Movie',
}
-- MP4 ('ftyp' compatible brand 'mp41', 'mp42' or 'f4v ') -> XMP at top level
local mp4Map = {
    QuickTime = 'ItemList',
    ItemList  = 'Meta',
    Keys      = 'Movie',
    AudioKeys = 'Track',
    VideoKeys = 'Track',
    Meta      = 'UserData',
    UserData  = 'Movie',
    Microsoft = 'UserData',
    Movie     = 'MOV',
    XMP       = 'MOV',         -- MOV-XMP
    GSpherical = 'SphericalVideoXML',
    SphericalVideoXML = 'Track',
    Track     = 'Movie',
}
local heicMap = {
    -- HEIC/HEIF/AVIF ('ftyp' compatible brand 'heic','mif1','avif') -> XMP/EXIF in top level 'meta'
    Meta         = 'MOV',
    ItemInformation = 'Meta',
    ItemPropertyContainer = 'Meta',
    XMP          = 'ItemInformation',
    EXIF         = 'ItemInformation',
    ICC_Profile  = 'ItemPropertyContainer',
    IFD0         = 'EXIF',
    IFD1         = 'IFD0',
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}
-- CR3 ('ftyp' compatible brand 'crx ') -> XMP at top level
local cr3Map = {
    Movie     = 'MOV',
    XMP       = 'MOV',
   ['UUID-Canon'] = 'Movie',
    ExifIFD   = 'UUID-Canon',
    IFD0      = 'UUID-Canon',
    GPS       = 'UUID-Canon',
    --MakerNoteCanon = 'UUID-Canon', -- (doesn't yet work -- goes into ExifIFD instead)
   ['UUID-Canon2'] = 'MOV',
    CanonVRD  = 'UUID-Canon2',
}
local dirMap = {
    MOV  = movMap,
    MP4  = mp4Map,
    CR3  = cr3Map,
    HEIC = heicMap,
}

-- convert ExifTool Format to QuickTime type
local qtFormat = {
   ['undef'] = 0x00,  string = 0x01,
    int8s  = 0x15,  int16s = 0x15,  int32s = 0x15,  int64s = 0x15,
    int8u  = 0x16,  int16u = 0x16,  int32u = 0x16,  int64u = 0x16,
    float  = 0x17,  double = 0x18,
}

local undLang = 0x55c4   -- numeric code for default ('und') language

local maxReadLen = 100000000 -- maximum size of atom to read into memory (100 MB)

-- boxes that may exist in an "empty" Meta box
local emptyMeta = {
    hdlr = 'Handler', keys = 'Keys', lang = 'Language', ctry = 'Country', free = 'Free',
}

-- starting word for Keys tags which use a full tag ID
local fullKeysID = { com = 1, xiaomi = 1, samsung = 1 }

-- lookup for CTBO ID number based on uuid for Canon CR3 files
local ctboID = {
    ["\xbe\x7a\xcf\xcb\x97\xa9\x42\xe8\x9c\x71\x99\x94\x91\xe3\xaf\xac"] = 1, -- XMP
    ["\xea\xf4\x2b\x5e\x1c\x98\x4b\x88\xb9\xfb\xb7\xdc\x40\x6e\x4d\x16"] = 2, -- PreviewImage
    -- ID 3 is used for 'mdat' atom (not a uuid)
    -- (haven't seen ID 4 yet)
    ["\x57\x66\xb8\x29\xbb\x6a\x47\xc5\xbc\xfb\x8b\x9f\x22\x60\xd0\x6d"] = 5, -- something to do with burst-roll image
}

-- mark UserData tags that don't have ItemList counterparts as Preferred
-- - and set Preferred to 0 for any Avoid-ed tag
-- - also, for now, set Writable to 0 for any tag with a RawConv and no RawConvInv
do
    local itemList = QuickTime.ItemList
    local userData = QuickTime.UserData
    local pref = { }
    for _, tag in ipairs(ExifTool.TagTableKeys(itemList)) do
        local tagInfo = itemList[tag]
        if type(tagInfo) ~= 'table' or tagInfo[1] ~= nil then
            if type(tagInfo) == 'table' then goto nextItemList end -- (conditional list)
            tagInfo = { Name = tagInfo }
            itemList[tag] = tagInfo
        else
            if tagInfo.RawConv and not tagInfo.RawConvInv then tagInfo.Writable = 0 end
            if tagInfo.Avoid then tagInfo.Preferred = 0 goto nextItemList end
            if tagInfo.Preferred ~= nil and not perlTruthy(tagInfo.Preferred) then goto nextItemList end
        end
        pref[tagInfo.Name] = 1
        ::nextItemList::
    end
    for _, tag in ipairs(ExifTool.TagTableKeys(userData)) do
        local tagInfo = userData[tag]
        if type(tagInfo) ~= 'table' or tagInfo[1] ~= nil then
            if type(tagInfo) == 'table' then goto nextUserData end -- (conditional list)
            tagInfo = { Name = tagInfo }
            userData[tag] = tagInfo
        else
            if tagInfo.RawConv and not tagInfo.RawConvInv then tagInfo.Writable = 0 end
            if tagInfo.Avoid then tagInfo.Preferred = 0 goto nextUserData end
            if tagInfo.Preferred ~= nil or pref[tagInfo.Name] then goto nextUserData end
        end
        tagInfo.Preferred = 1
        ::nextUserData::
    end
end

--------------------------------------------------------------------------------
-- Format GPSCoordinates for writing (upstream WriteQuickTime.pl)
-- Inputs: 0) PrintConv value
-- Returns: ValueConv value
function WriteQuickTime.PrintInvGPSCoordinates(val)
    local GPS = require('lexiftool.GPS')
    val = perlStr(val)
    local v = perl.split(', *', val)
    if #v == 2 or #v == 3 then
        local below = perlTruthy(v[3]) and matches(v[3], [[(?i)below]])
        v[1] = GPS.ToDegrees(v[1], 1)
        v[2] = GPS.ToDegrees(v[2], 1)
        if #v == 3 then v[3] = (ExifTool.ToFloat(v[3]) or 0) * (below and -1 or 1) end
        -- "@v": Perl joins an interpolated array with $" (a space)
        for i = 1, #v do v[i] = NumStr(v[i]) end
        return table.concat(v, ' ')
    end
    if matches(val, [[^([-+]?\d+(\.\d*)?)\s+([-+]?\d+(\.\d*)?)$]]) then return val end -- already 2 floats?
    if matches(val, [[^([-+]\d+(\.\d*)?){2,3}(CRS.*)?\/?$]]) then return val end -- already in ISO6709 format?
    return nil
end

-- Convert GPS coordinates back to ISO6709 format (upstream WriteQuickTime.pl)
-- Inputs: 0) ValueConv value
-- Returns: ISO6709 coordinates
function WriteQuickTime.ConvInvISO6709(val)
    local a = perl.split(' ', perlStr(val))
    if #a == 2 or #a == 3 then
        -- latitude must have 2 digits before the decimal, and longitude 3,
        -- and all values must start with a "+" or "-", and Google Photos
        -- requires at least 3 digits after the decimal point
        -- (and as of Apr 2021, Google Photos doesn't accept coordinats
        --  with more than 5 digits after the decimal place:
        --  https://exiftool.org/forum/index.php?topic=11055.msg67171#msg67171
        --  still a problem Apr 2024: https://exiftool.org/forum/index.php?msg=85761)
        local fmt = { '%s%02d.%s%s', '%s%03d.%s%s', '%s%d.%s%s' }
        local limit = { 90, 180 }
        for i = 1, #a do
            if not ExifTool.IsFloat(a[i]) then return nil end
            local lim = table.remove(limit, 1)
            if lim and math.abs(perl.num(a[i])) > lim then
                -- upstream `warn`, which lands in the $SIG{'__WARN__'} handler
                -- ConvInv installs: it sets $evalWarning, and the caller then
                -- throws the value away -- exactly what an error() does here
                -- (level 0, so the message reaches ConvInv unprefixed).  The
                -- one difference: Perl finishes the loop and keeps the *last*
                -- warning, so two out-of-range values report the longitude.
                error((#limit > 0 and 'Lat' or 'Long') .. 'itude out of range\n', 0)
            end
            -- upstream's /e substitution over $_, with the format shifted
            -- off @fmt so a third value (the altitude) takes '%s%d.%s%s'
            local f = table.remove(fmt, 1)
            a[i] = subst(a[i], [[^([-+]?)(\d+)\.?(\d*)]], function(s, d, frac)
                return sprintf(f, perlTruthy(s) and s or '+', perl.num(d), frac,
                                     #frac < 3 and string.rep('0', 3 - #frac) or '')
            end)
        end
        return table.concat(a) .. '/'
    end
    if matches(val, [[^([-+]\d+(\.\d*)?){2,3}(CRS.*)?\/?$]]) then return val end -- already in ISO6709 format?
    return nil
end

-- atoms that may store absolute file offsets
-- (upstream's /^(stco|co64|iloc|mfra|moof|sidx|saio|gps |CTBO|uuid)$/ test)
local offsetAtom = {
    stco = 1, co64 = 1, iloc = 1, mfra = 1, moof = 1, sidx = 1, saio = 1,
    ['gps '] = 1, CTBO = 1, uuid = 1,
}

--------------------------------------------------------------------------------
-- Handle offsets in iloc (ItemLocation) atom when writing (ref ISO 14496-12:2015 pg.79)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) data ref, 3) output buffer ref
-- Returns: true on success
-- Notes: see also ParseItemLocation() in QuickTime.pm
-- (variable names with underlines correspond to names in ISO 14496-12)
--------------------------------------------------------------------------------
local function Handle_iloc(et, dirInfo, dataPt, outfile)
    local id

    local off = dirInfo.ChunkOffset
    local len = #dataPt
    if len < 8 then return 0 end
    local ver = dataPt:byte(1)
    local siz = Get16u(dataPt, 4)
    local noff = (siz >> 12)
    local nlen = (siz >> 8) & 0x0f
    local nbas = (siz >> 4) & 0x0f
    local nind = siz & 0x0f
    local ok = { [0] = 1, [4] = 1, [8] = 8 }
    if not (ok[noff] and ok[nlen] and ok[nbas] and ok[nind]) then return 0 end
    -- piggy-back on existing code to fix up stco/co64 4/8-byte offsets
    local tag = (noff == 4) and 'stco_iloc' or 'co64_iloc'
    local num, pos
    if ver < 2 then
        num = Get16u(dataPt, 6)
        pos = 8
    else
        if len < 10 then return 0 end
        num = Get32u(dataPt, 6)
        pos = 10
    end
    for i = 0, num - 1 do
        if ver < 2 then
            if pos + 2 > len then return 0 end
            id = Get16u(dataPt, pos)
            pos = pos + 2
        else
            if pos + 4 > len then return 0 end
            id = Get32u(dataPt, pos)
            pos = pos + 4
        end
        local constOff, minOffset
        local offBase, offItem = {}, {}
        if ver == 1 or ver == 2 then
            if pos + 2 > len then return 0 end
            -- offsets are absolute only if ConstructionMethod is 0, otherwise
            -- the relative offsets are constant as far as we are concerned
            constOff = Get16u(dataPt, pos) & 0x0f
            if constOff == 0 then constOff = nil end
            pos = pos + 2
        end
        if pos + 2 > len then return 0 end
        local drefIdx = Get16u(dataPt, pos)
        if drefIdx ~= 0 then
            local dref = et.QtDataRef and et.QtDataRef[drefIdx]
            if dref then
                -- these offsets are constant unless the data is in this file
                if not (dref[2] == 1 and dref[1] ~= 'rsrc') then constOff = 1 end
            else
                et:Error('No data reference for iloc entry ' .. i)
                return 0
            end
        end
        pos = pos + 2
        -- get base offset and save its location if in this file
        local base_offset
        base_offset, pos = GetVarInt(dataPt, pos, nbas)
        if base_offset and base_offset ~= 0 and not constOff then
            local tg = ((nbas == 4) and 'stco' or 'co64') .. '_iloc'
            offBase[#offBase + 1] = { tg, length(outfile.value) + 8 + pos - nbas, nbas, 0, id }
        end
        if pos + 2 > len then return 0 end
        local ext_num = Get16u(dataPt, pos)
        pos = pos + 2
        -- run through the item list to get offset locations and the minimum offset in this file
        for _ = 0, ext_num - 1 do
            if ver == 1 or ver == 2 then pos = pos + nind end
            local extent_offset
            extent_offset, pos = GetVarInt(dataPt, pos, noff)
            if extent_offset == nil then return 0 end
            if not constOff then
                if noff ~= 0 then
                    offItem[#offItem + 1] = { tag, length(outfile.value) + 8 + pos - noff, noff, 0, id }
                end
                if minOffset == nil or minOffset > extent_offset then minOffset = extent_offset end
            end
            if pos + nlen > #dataPt then return 0 end
            pos = pos + nlen
        end
        -- decide whether to fix up the base offset or individual item offsets
        -- (adjust the one that is larger)
        if minOffset ~= nil and minOffset > (base_offset or 0) then
            for _, e in ipairs(offItem) do e[4] = base_offset or 0 end
            for _, e in ipairs(offItem) do off[#off + 1] = e end
        else
            for _, e in ipairs(offBase) do e[4] = minOffset end
            for _, e in ipairs(offBase) do off[#off + 1] = e end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Get localized version of tagInfo hash
-- Inputs: 0) tagInfo hash ref, 1) language code (eg. "fra-FR")
-- Returns: new tagInfo hash ref, or undef if invalid or no language code
function WriteQuickTime.GetLangInfo(tagInfo, langCode)
    if not perlTruthy(langCode) then return nil end
    -- only allow alternate language tags in lang-alt lists
    local writable = tagInfo.Writable
    if writable == nil then writable = tagInfo.Table.WRITABLE end
    if not perlTruthy(writable) then return nil end
    langCode = tr(langCode, '_', '-')   -- RFC 3066 specifies '-' as a separator
    local langInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, langCode)
    return langInfo
end

--------------------------------------------------------------------------------
-- Check to see if we can write the specified tag (upstream CheckQTValue)
-- Inputs: 0) ExifTool ref, 1) tagInfo ref, 2) raw value
-- Returns: error string or nil on success
--------------------------------------------------------------------------------
function WriteQuickTime.CheckQTValue(_et, tagInfo, val)
    local format = tagInfo.Format or tagInfo.Writable or
                   (tagInfo.Table and tagInfo.Table.FORMAT)
    if not format then return nil end
    return require('lexiftool.Writer').CheckValue(val, format, tagInfo.Count)
end

--------------------------------------------------------------------------------
-- Format QuickTime value for writing (upstream FormatQTValue)
-- Inputs: 0) ExifTool ref, 1) value, 2) tagInfo ref, 3) Format (or nil)
-- Returns: flags for the QT data type, and the reformatted value (nil on error)
--------------------------------------------------------------------------------
local function FormatQTValue(et, val, tagInfo, format)
    local writable = tagInfo.Writable
    local count = tagInfo.Count
    local flags
    format = format or tagInfo.Format
    if (format and format ~= 'string') or
       (not format and writable and writable ~= 'string') then
        val = require('lexiftool.Writer').WriteValue(val, format or writable, count)
        if writable and qtFormat[writable] then
            flags = qtFormat[writable]
        else
            flags = qtFormat[format or 0] or 0
        end
    elseif val:sub(1, 3) == '\255\216\255' then
        flags = 0x0d  -- JPG
    elseif matches(val, [[^(\x89P|\x8aM|\x8bJ)NG\r\n\x1a\n]]) then
        flags = 0x0e  -- PNG
    elseif matches(val, [[^BM.{15}\0]]) then
        flags = 0x1b  -- BMP
    else
        flags = 0x01  -- UTF8
        val = et:Encode(val, 'UTF8')
    end
    if val == nil then et:Warn('Error converting value for ' .. perlStr(tagInfo.Name)) end
    return flags, val
end

--------------------------------------------------------------------------------
-- Set variable-length integer (used by WriteItemInfo)
-- Inputs: 0) value, 1) integer size in bytes (0, 4 or 8),
-- Returns: packed integer
--------------------------------------------------------------------------------
local function SetVarInt(val, n)
    if n == 4 then
        return ExifTool.Put32u(val)
    elseif n == 8 then
        -- (this port has no Put64u; Set64u's two-word split, as a string)
        local hi = math.floor(val / 4294967296)
        local lo = val - hi * 4294967296
        if ExifTool.GetByteOrder() == 'MM' then
            return ExifTool.Put32u(hi) .. ExifTool.Put32u(lo)
        end
        return ExifTool.Put32u(lo) .. ExifTool.Put32u(hi)
    end
    return ''
end

--------------------------------------------------------------------------------
-- Write Nextbase infi atom (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: updated infi data
function WriteQuickTime.WriteNextbase(et, dirInfo, _tagTablePtr)
    if not et then return 1 end
    if et.DEL_GROUP.Nextbase then
        et.CHANGED = et.CHANGED + 1
        return ''
    end
    return dirInfo.DataPt
end

--------------------------------------------------------------------------------
-- Write Keys tags (upstream WriteKeys)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: updated Keys box
-- Notes: leaves the Remap/Info/Add/Num lookups in et[keysGrp] for the
--        ItemList writer, whose entries are keyed by Keys index
--------------------------------------------------------------------------------
function WriteQuickTime.WriteKeys(et, dirInfo, tagTablePtr)
    if not et then return 1 end   -- allow dummy access
    local Writer = require('lexiftool.Writer')
    local dataPt = dirInfo.DataPt or ''
    local dirLen = #dataPt
    local done, remap, info, add = { }, { }, { }, { }

    local keysGrp = avType[et.MediaType] and (avType[et.MediaType] .. 'Keys') or 'Keys'
    if dirLen < 8 then
        et:Warn('Short Keys box')
        dirLen = 8
        dataPt = string.rep('\0', 8)
    end
    if Writer.IsGroupDeleted(et, keysGrp) then
        dirLen = 8    -- delete all existing keys
        -- deleted keys are identified by a zero entry in the Remap lookup
        local num = Get32u(dataPt, 4)
        for i = 1, num do remap[i] = 0 end
        et:VPrint(0, '  [deleting ' .. num .. ' ' .. keysGrp .. ' entr' ..
                     (num == 1 and 'y' or 'ies') .. ']\n')
        et.CHANGED = (et.CHANGED or 0) + 1
    end
    local pos = 8
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
    local newData = carray.new('char'):append(substr(dataPt, 0, pos))

    local newIndex, index = 1, 1
    while pos < dirLen - 4 do
        local len = Get32u(dataPt, pos)
        if len < 8 or pos + len > dirLen then break end
        local ns = dataPt:sub(pos + 5, pos + 8)
        local tag = dataPt:sub(pos + 9, pos + len)
        tag = tag:gsub('%z.*', '')                     -- truncate at null
        if ns == 'mdta' then                            -- remove apple quicktime domain
            tag = tag:gsub('^com%.apple%.quicktime%.', '')
        end
        if tag == '' then tag = 'Tag_' .. ns end
        done[tag] = 1    -- set flag to avoid creating this tag
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        local dropped
        if tagInfo then
            info[index] = tagInfo
            if newTags[tag] then
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                -- drop this tag if it is being deleted
                -- (upstream tests `> 0` here: a -1 "don't know" must not
                --  delete the key)
                if nvHash and Writer.IsOverwriting(et, nvHash) > 0 and
                   Writer.GetNewValue(et, nvHash) == nil then
                    -- (upstream also keeps the key alive when an alternate-language
                    --  version of this tag is being written; language alternates
                    --  are not ported)
                    et:VPrint(1, (et.INDENT or '') .. '[deleting ' .. keysGrp ..
                                 ' entry ' .. index .. " '" .. tag .. "']\n")
                    pos = pos + len
                    remap[index] = 0
                    index = index + 1
                    et.CHANGED = (et.CHANGED or 0) + 1
                    dropped = true
                end
            end
        end
        if not dropped then
            -- add to the Keys box data
            newData:append(substr(dataPt, pos, len))
            remap[index] = newIndex
            index = index + 1
            newIndex = newIndex + 1
            pos = pos + len
        end
    end
    -- add keys for any tags we need to create
    local ids = { }
    for tag in pairs(newTags) do ids[#ids + 1] = tag end
    tsort(ids)
    for _, tag in ipairs(ids) do
        local tagInfo = newTags[tag]
        local id = tag
        if not done[id] then
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            if nvHash and nvHash.IsCreating and nvHash.IsCreating ~= 0 and
               perlTruthy(Writer.IsOverwriting(et, nvHash)) and
               Writer.GetNewValue(et, nvHash) ~= nil then
                -- add new entry to 'keys' data
                local val = id
                local head = val:match('^(.-)%.')
                if not (head and fullKeysID[head]) then
                    val = 'com.apple.quicktime.' .. val
                end
                newData:append(ExifTool.Put32u(8 + #val) .. 'mdta' .. val)
                et:VPrint(1, (et.INDENT or '') .. '[adding ' .. keysGrp ..
                             ' entry ' .. newIndex .. " '" .. id .. "']\n")
                add[newIndex] = tagInfo
                newIndex = newIndex + 1
                et.CHANGED = (et.CHANGED or 0) + 1
            end
        end
    end
    local num = newIndex - 1
    if num ~= 0 then
        ExifTool.Set32u(newData, 4, num)   -- update count in header
    else
        newData = carray.new('char')  -- delete empty Keys box
    end
    -- save temporary variables for use when writing ItemList:
    --   Remap - lookup for remapping Keys ID numbers (0 if item is deleted)
    --   Info  - Keys tag information, based on old index value
    --   Add   - Keys items added, based on new index value
    --   Num   - Number of items in edited Keys box
    et[keysGrp] = { Remap = remap, Info = info, Add = add, Num = num }

    return newData:tostring()    -- return updated Keys box
end

--------------------------------------------------------------------------------
-- Write ItemInformation in HEIC files (upstream WriteItemInfo)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref (with BoxPos entry), 2) output buffer
-- Returns: mdat edit list (nil if nothing changed)
-- Port note: upstream's $outfile is a scalar ref it patches in place; here it
-- is the carray in that reference's box (the output buffer of the calling
-- WriteQuickTime), patched in place the same way.  The mdat edit entries keep upstream's member order in a
-- 1-based array: 1=old pos, 2=old end, 3=new data, 4=new data item ID.
--------------------------------------------------------------------------------
function WriteQuickTime.WriteItemInfo(et, dirInfo, outfile)
    local Writer = require('lexiftool.Writer')
    local boxPos = dirInfo.BoxPos -- hash of [position,length,irefVer(iref only)] for box in outfile
    local raf = et.RAF
    local items = et.ItemInfo
    local did, mdatEdit = { }, { }
    local name, tmap

    if not (items and raf) then return nil end

    -- extract information from EXIF/XMP metadata items
    local primary = et.PrimaryItem
    local curPos = raf:Tell()
    local lastID = 0
    local ids = { }
    for id in pairs(items) do ids[#ids + 1] = id end
    tsort(ids)
    for _, id in ipairs(ids) do
        lastID = id
        if primary == nil then primary = id end -- assume primary is lowest-number item if pitm missing
        local item = items[id]
        -- only edit primary EXIF/XMP metadata
        if item.RefersTo and item.RefersTo[primary] then
            local type_ = item.ContentType or item.Type
            if type_ ~= nil and type_ ~= '' then
                if type_ == 'tmap' then tmap = id end -- save ID of primary 'tmap' item (tone-mapped image)
                -- get ExifTool name for this item
                name = ({ Exif = 'EXIF', ['application/rdf+xml'] = 'XMP' })[type_]
                -- only care about EXIF and XMP, and only if we are editing it
                if name and et.EDIT_DIRS and et.EDIT_DIRS[name] ~= nil then
                    did[name] = 1    -- set flag to prevent creating this metadata
                    local warn, buff
                    local edit = { }
                    if not boxPos.iloc then warn = 'Missing iloc box' end
                    if not (item.Extents and #item.Extents > 0) then warn = 'No Extents for ' .. type_ .. ' item' end
                    if perlTruthy(item.ContentEncoding) then
                        if item.ContentEncoding ~= 'deflate' then
                            warn = "Can't currently decode " .. item.ContentEncoding .. ' encoded ' .. type_ .. ' metadata'
                        elseif not et:hasZlib() then
                            warn = 'Install Compress::Zlib to decode deflated ' .. type_ .. ' metadata'
                        end
                    end
                    if perlTruthy(item.ProtectionIndex) then
                        warn = "Can't currently decode protected " .. type_ .. ' metadata'
                    end
                    if perlTruthy(item.ConstructionMethod) then
                        warn = "Can't currently extract " .. type_ .. ' with construction method ' ..
                               item.ConstructionMethod
                    end
                    if perlTruthy(item.DataReferenceIndex) then
                        warn = type_ .. ' metadata is not in this file'
                    end
                    if warn then et:Warn(warn) goto nextItem end
                    do
                    local base = item.BaseOffset or 0
                    local val = ''
                    for _, extent in ipairs(item.Extents) do
                        if buff ~= nil then val = val .. buff end
                        local pos = extent[2] + base
                        if perlTruthy(extent[3]) then
                            if not raf:Seek(pos, 0) then break end
                            local got
                            got, buff = raf:Read(extent[3])
                            if not got or got == 0 then break end
                        else
                            buff = ''
                        end
                        edit[#edit + 1] = { pos, pos + extent[3] }  -- replace or delete this if changed
                    end
                    if buff == nil then goto nextItem end
                    if #val > 0 then buff = val .. buff end
                    do
                    local comp = et:Options('Compress')
                    if comp ~= nil and (perlTruthy(comp) ~= perlTruthy(item.ContentEncoding)) then
                        --TODO: add ability to edit infe entry in iinf to change encoding according to Compress option if set
                        et:Warn("Can't currently change compression when rewriting " .. name .. ' in HEIC', 1)
                    end
                    local wasDeflated
                    if perlTruthy(item.ContentEncoding) then
                        local v2, ok = et:inflate(buff)
                        et:VPrint(0, '  (Inflating stored ' .. name .. ' metadata)\n')
                        if ok then
                            buff = v2
                            wasDeflated = 1
                        else
                            et:Warn('Error inflating ' .. name .. ' metadata')
                            goto nextItem
                        end
                    end
                    local hdr, subTable, proc
                    local strt = 0
                    if name == 'EXIF' then
                        if #buff == 0 then
                            -- create EXIF from scratch
                            hdr = '\0\0\0\6Exif\0\0'
                        elseif matches(buff, [[^(MM\0\x2a|II\x2a\0)]]) then
                            et:Warn('Missing Exif header')
                            hdr = ''
                        elseif #buff >= 4 and #buff >= 4 + perl.unpack('N', buff) then
                            hdr = substr(buff, 0, 4 + perl.unpack('N', buff))
                            strt = #hdr
                        else
                            et:Warn('Invalid Exif header')
                            goto nextItem
                        end
                        subTable = et:GetTagTable('lexiftool.Exif.Main')
                        proc = Writer.WriteTIFF
                    else
                        hdr = ''
                        subTable = et:GetTagTable('lexiftool.XMP.Main')
                    end
                    local subdirInfo = {
                        DataPt   = buff,
                        DataLen  = #buff,
                        DirStart = strt,
                        DirLen   = #buff - strt,
                    }
                    local changed = et.CHANGED
                    local newVal = Writer.WriteDirectory(et, subdirInfo, subTable, proc)
                    if newVal ~= nil and changed ~= et.CHANGED and
                       -- nothing changed if deleting an empty directory
                       (perlTruthy(subdirInfo.DirLen) or #newVal > 0)
                    then
                        if #hdr > 0 and #newVal > 0 then newVal = hdr .. newVal end
                        if wasDeflated then
                            et:VPrint(0, '  (Re-deflating new ' .. name .. ' metadata)\n')
                            local buf2, ok = et:deflate(newVal)
                            if ok then newVal = buf2 end
                        end
                        edit[1][3] = newVal     -- replace the old chunk with the new data
                        edit[1][4] = id         -- mark this chunk with the item ID
                        for _, e in ipairs(edit) do mdatEdit[#mdatEdit + 1] = e end
                        -- update item extent_length
                        local n = #newVal
                        for _, extent in ipairs(item.Extents) do
                            local nlen, lenPt = extent[4], extent[5]
                            if nlen == 8 then
                                Writer.Set64u(outfile, boxPos.iloc[1] + 8 + lenPt, n)
                            elseif n <= 0xffffffff then
                                ExifTool.Set32u(outfile, boxPos.iloc[1] + 8 + lenPt, n)
                            else
                                et:Error("Can't yet promote iloc length to 64 bits")
                                return nil
                            end
                            n = 0
                        end
                        if #item.Extents ~= 1 then
                            et:Error("Can't yet handle " .. name .. ' in multiple parts. Please submit sample for testing')
                        end
                    end
                    et.CHANGED = changed   -- (will set this later if successful in editing mdat)
                    end
                    end
                end
            end
        end
        ::nextItem::
    end
    raf:Seek(curPos, 0)     -- seek back to original position

    -- add necessary metadata types if they didn't already exist
    -- (upstream also builds a %usedID lookup here that it never reads again)
    local countNew, add = nil, { }
    for _, nm in ipairs({ 'EXIF', 'XMP' }) do
        name = nm
        if did[name] or not (et.ADD_DIRS and et.ADD_DIRS[name] ~= nil) then goto nextName end
        do
        local missing = { }
        for _, t in ipairs({ 'iinf', 'iloc' }) do
            if not boxPos[t] then missing[#missing + 1] = t end
        end
        if #missing > 0 then
            local str = #missing > 1 and (table.concat(missing, ' and ') .. ' boxes') or (missing[1] .. ' box')
            et:Warn("Can't create " .. name .. '. Missing expected ' .. str)
            break
        end
        if et.PrimaryItem == nil then
            if primary == nil then
                et:Warn("Can't create " .. name .. '. No items to reference')
                break
            end
            -- add new primary item reference box after hdrl box
            if primary < 0x10000 then
                add.hdlr = perl.pack('Na4Nn', 14, 'pitm', 0, primary)
            else
                add.hdlr = perl.pack('Na4CCCCN', 16, 'pitm', 1, 0, 0, 0, primary)
            end
            et:Warn('Added missing PrimaryItemReference (for item ' .. primary .. ')', 1)
        end
        local buff = ''
        local hdr, subTable, proc
        if name == 'EXIF' then
            hdr = '\0\0\0\6Exif\0\0'
            subTable = et:GetTagTable('lexiftool.Exif.Main')
            proc = Writer.WriteTIFF
        else
            hdr = ''
            subTable = et:GetTagTable('lexiftool.XMP.Main')
        end
        local subdirInfo = {
            DataPt   = buff,
            DataLen  = 0,
            DirStart = 0,
            DirLen   = 0,
        }
        local changed = et.CHANGED
        local newVal = Writer.WriteDirectory(et, subdirInfo, subTable, proc)
        if newVal ~= nil and changed ~= et.CHANGED then
            local irefVer
            if boxPos.iref then
                irefVer = ExifTool.Get8u(outfile, boxPos.iref[1] + 8)
            else
                -- create iref box after end of iinf box (and save version in boxPos list)
                irefVer = (primary < 0x10000) and 0 or 1
                boxPos.iref = { boxPos.iinf[1] + boxPos.iinf[2], 0, irefVer }
            end
            if #hdr > 0 then newVal = hdr .. newVal end
            -- add new infe to iinf
            if add.iinf == nil then add.iinf, add.iref, add.iloc = '', '', '' end
            local type_, mime
            local enc = ''
            if name == 'XMP' then
                type_ = 'mime\0'
                mime = 'application/rdf+xml\0'
                -- write compressed XMP if Compress option is set
                if perlTruthy(et:Options('Compress')) and #newVal > 0 then
                    if not et:hasZlib() then
                        et:Warn('Install Compress::Zlib to write compressed metadata')
                    else
                        et:VPrint(0, '  (Deflating new ' .. name .. ' metadata)\n')
                        local buf2, ok = et:deflate(newVal)
                        if ok then
                            newVal = buf2
                            enc = 'deflate\0'
                        end
                    end
                end
            else
                type_ = 'Exif\0'
                mime = ''
            end
            lastID = lastID + 1
            local newID = lastID -- use next highest available ID (so ID's in iinf are in order)
            -- add new infe entry to iinf box
            local n = #type_ + #mime + #enc + 16
            if newID < 0x10000 then
                add.iinf = add.iinf .. perl.pack('Na4CCCCnn', n, 'infe', 2, 0, 0, 1, newID, 0) .. type_ .. mime .. enc
            else
                n = n + 2
                add.iinf = add.iinf .. perl.pack('Na4CCCCNn', n, 'infe', 3, 0, 0, 1, newID, 0) .. type_ .. mime .. enc
            end
            -- add new cdsc to iref (also refer to primary 'tmap' if it exists)
            if perlTruthy(irefVer) then
                local fmt, siz, num
                if tmap ~= nil then fmt, siz, num = 'N', 22, 2 else fmt, siz, num = '', 18, 1 end
                add.iref = add.iref .. perl.pack('Na4NnN' .. fmt, siz, 'cdsc', newID, num, primary, tmap)
            else
                local fmt, siz, num
                if tmap ~= nil then fmt, siz, num = 'n', 16, 2 else fmt, siz, num = '', 14, 1 end
                add.iref = add.iref .. perl.pack('Na4nnn' .. fmt, siz, 'cdsc', newID, num, primary, tmap)
            end
            -- add new entry to iloc table (see ISO14496-12:2015 pg.79)
            local ilocVer = ExifTool.Get8u(outfile, boxPos.iloc[1] + 8)
            local siz = Get16u(outfile, boxPos.iloc[1] + 12)  -- get size information
            local noff = (siz >> 12)
            local nlen = (siz >> 8) & 0x0f
            local nbas = (siz >> 4) & 0x0f
            local nind = siz & 0x0f
            local pbas, poff
            if ilocVer == 0 then
                -- set offset to 0 as flag that this is a new idat chunk being added
                pbas = #add.iloc + 4
                poff = pbas + nbas + 2
                add.iloc = add.iloc .. perl.pack('nn', newID, 0) .. SetVarInt(0, nbas) .. ExifTool.Put16u(1) ..
                            SetVarInt(0, noff) .. SetVarInt(#newVal, nlen)
            elseif ilocVer == 1 then
                pbas = #add.iloc + 6
                poff = pbas + nbas + 2 + nind
                add.iloc = add.iloc .. perl.pack('nnn', newID, 0, 0) .. SetVarInt(0, nbas) .. ExifTool.Put16u(1) ..
                            SetVarInt(0, nind) .. SetVarInt(0, noff) .. SetVarInt(#newVal, nlen)
            elseif ilocVer == 2 then
                pbas = #add.iloc + 8
                poff = pbas + nbas + 2 + nind
                add.iloc = add.iloc .. perl.pack('Nnn', newID, 0, 0) .. SetVarInt(0, nbas) .. ExifTool.Put16u(1) ..
                            SetVarInt(0, nind) .. SetVarInt(0, noff) .. SetVarInt(#newVal, nlen)
            else
                et:Warn("Can't create " .. name .. '. Unsupported iloc version ' .. ilocVer)
                break
            end
            -- add new ChunkOffset entry to update this new offset
            local off = dirInfo.ChunkOffset
            if not off then et:Warn('Internal error. Missing ChunkOffset') break end
            local newOff
            if noff == 4 then
                newOff = { 'stco_iloc', boxPos.iloc[1] + boxPos.iloc[2] + poff, noff, 0, newID }
            elseif noff == 8 then
                newOff = { 'co64_iloc', boxPos.iloc[1] + boxPos.iloc[2] + poff, noff, 0, newID }
            elseif noff == 0 then
                -- offset_size is zero, so store the offset in base_offset instead
                if nbas == 4 then
                    newOff = { 'stco_iloc', boxPos.iloc[1] + boxPos.iloc[2] + pbas, nbas, 0, newID }
                elseif nbas == 8 then
                    newOff = { 'co64_iloc', boxPos.iloc[1] + boxPos.iloc[2] + pbas, nbas, 0, newID }
                else
                    et:Warn("Can't create " .. name .. '. Invalid iloc offset+base size')
                    break
                end
            else
                et:Warn("Can't create " .. name .. '. Invalid iloc offset size')
                break
            end
            -- add directory as a new mdat chunk
            off[#off + 1] = newOff
            mdatEdit[#mdatEdit + 1] = { 0, 0, newVal, newID }
            countNew = (countNew or 0) + 1
            et.CHANGED = changed -- set this later if successful in editing mdat
        end
        end
        ::nextName::
    end
    if countNew then
        -- insert new entries into iinf, iref and iloc boxes,
        -- and add new pitm box after hdlr if necessary
        local added = 0
        local tags = { }
        for t in pairs(boxPos) do tags[#tags + 1] = t end
        tsort(tags, function(a, b) return boxPos[a][1] < boxPos[b][1] end)
        for _, tag in ipairs(tags) do
            boxPos[tag][1] = boxPos[tag][1] + added
            if perlTruthy(add[tag]) then
                local pos = boxPos[tag][1]
                local skip
                if not perlTruthy(boxPos[tag][2]) then
                    if tag ~= 'iref' then et:Error('Internal error adding iref box') break end
                    -- create new iref box
                    add[tag] = ExifTool.Put32u(12 + #add[tag]) .. tag ..
                               string.char(boxPos[tag][3]) .. '\0\0\0' .. add[tag]
                elseif tag ~= 'hdlr' then
                    local n = Get32u(outfile, pos) + #add[tag]
                    ExifTool.Set32u(outfile, pos, n)    -- increase box size
                end
                if tag == 'iinf' then
                    local iinfVer = ExifTool.Get8u(outfile, pos + 8)
                    if iinfVer == 0 then
                        local n = Get16u(outfile, pos + 12) + countNew
                        if n > 0xffff then
                            et:Error("Can't currently handle rollover to long item count")
                            return nil
                        end
                        ExifTool.Set16u(outfile, pos + 12, n)    -- incr count
                    else
                        local n = Get32u(outfile, pos + 12) + countNew
                        ExifTool.Set32u(outfile, pos + 12, n)    -- incr count
                    end
                elseif tag == 'iref' then -- luacheck: ignore 542
                    -- nothing more to do
                elseif tag == 'iloc' then
                    local ilocVer = ExifTool.Get8u(outfile, pos + 8)
                    if ilocVer < 2 then
                        local n = Get16u(outfile, pos + 14) + countNew
                        ExifTool.Set16u(outfile, pos + 14, n)    -- incr count
                        if n > 0xffff then
                            et:Error("Can't currently handle rollover to long item count")
                            return nil
                        end
                    else
                        local n = Get32u(outfile, pos + 14) + countNew
                        ExifTool.Set32u(outfile, pos + 14, n)    -- incr count
                    end
                    -- must also update pointer locations in this box
                    if perlTruthy(added) then
                        for _, co in ipairs(dirInfo.ChunkOffset) do co[2] = co[2] + added end
                    end
                elseif tag ~= 'hdlr' then
                    skip = true
                end
                if not skip then
                    -- add new entries to this box (or add pitm after hdlr)
                    substr(outfile, pos + boxPos[tag][2], 0, add[tag])
                    boxPos[tag][2] = boxPos[tag][2] + #add[tag]
                    added = added + #add[tag]    -- positions are shifted by length of new entries
                end
            end
        end
    end
    et.ItemInfo = nil
    return #mdatEdit > 0 and mdatEdit or nil
end

--------------------------------------------------------------------------------
-- (port helper: upstream gets the UUID of a uuid atom by evaluating the regex
--  of the tag's Condition string -- `$cond =~ m{=~\s*\/\^(.*)/}` and
--  `eval qq("$1")`.  A Lua Condition is a function, so its source line is
--  read back and the `^...` pattern of its isMatch call unescaped the same way)
local function ConditionUUID(cond)
    if type(cond) ~= 'function' then return nil end
    local info = debug.getinfo(cond, 'S')
    local path = info.source:match('^@(.*)$')
    local f = path and io.open(path, 'r')
    -- (the chunk name is relative to the directory lexiftool was started in;
    --  failing that, look the module source up on the search path)
    if not f then
        path = package.searchpath('lexiftool.QuickTime', package.path)
        f = path and io.open(path, 'r')
    end
    if not f then return nil end
    local text = { }
    local n = 0
    for line in f:lines() do
        n = n + 1
        if n >= info.linedefined then text[#text + 1] = line end
        if n >= info.lastlinedefined then break end
    end
    f:close()
    local pat = table.concat(text, '\n'):match('valPt, %[%[%^(.-)%]%]')
    if not pat then return nil end
    -- (the Perl double-quoted string escapes that occur in these patterns)
    return (pat:gsub('\\x(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
               :gsub('\\0', '\0'))
end

--------------------------------------------------------------------------------
-- Write QuickTime atoms (upstream WriteQuickTime)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: at the top level 1 on success / 0 on error; for a sub-directory the
--          new atom data, or nil on error
--------------------------------------------------------------------------------
function WriteQuickTime.WriteQuickTime(et, dirInfo, tagTablePtr)
    if not et then return 1 end   -- allow dummy access
    local Writer = require('lexiftool.Writer')
    local outfile = dirInfo.OutFile
    if not outfile then return 0 end
    local raf = dirInfo.RAF         -- (will be null for lower-level atoms)
    local dataPt = dirInfo.DataPt   -- (will be null for top-level atoms)
    local dirName = dirInfo.DirName
    local dirStart = dirInfo.DirStart or 0
    local addDirs = et.ADD_DIRS or { }
    -- (upstream also carries $rtnErr for the write-error paths this slice
    --  doesn't have yet)
    -- (`dataPt and nil or 1` would always yield 1 in Lua)
    local rtnVal
    if not dataPt then rtnVal = 1 end

    if dataPt then
        raf = RandomAccess.new(dataPt)
    elseif not raf then
        return 0
    end
    -- use buffered output for everything but 'mdat' atoms
    -- (upstream `$outBuff = ''; $outfile = \$outBuff`: `buffered` is that
    --  scalar reference, the box { value = <carray> } of doc/api.md §4)
    local buffered = { value = carray.new('char') }

    if dirStart ~= 0 then raf:Seek(dirStart, 1) end -- skip header if it exists

    local keysGrp, keysPath
    if avType[et.MediaType] then
        -- (note: these won't be correct now if we haven't yet processed the Media box,
        -- but in this case they won't be needed until after we set them properly below)
        keysGrp, keysPath = avType[et.MediaType] .. 'Keys', 'MOV-Movie-Track'
    else
        keysGrp, keysPath = 'Keys', 'MOV-Movie'
    end
    local curPath = table.concat(et.PATH or { }, '-')
    local dir, writePath = dirName, dirName
    while true do
        dir = et.DirMap and et.DirMap[dir] or nil
        if not dir then break end
        writePath = dir .. '-' .. writePath
    end
    local newTags = { }
    local createKeys = 0
    -- hack to create Keys directories if necessary (its containing Meta is in a different location)
    if addDirs.Keys and isMatch(curPath, [[^MOV-Movie(-Meta)?$]]) then
        createKeys = 1    -- create new Keys directories
    elseif (addDirs.AudioKeys or addDirs.VideoKeys) and isMatch(curPath, [[^MOV-Movie-Track(-Meta)?$]]) then
        createKeys = -1   -- (must wait until MediaType is known)
    elseif (curPath == 'MOV-Movie-Meta-ItemList') or
           (curPath == 'MOV-Movie-Track-Meta-ItemList' and avType[et.MediaType])
    then
        createKeys = 2    -- create new Keys tags
        local keys = et[keysGrp]
        if keys then
            -- add new tag entries for existing Keys tags, now that we know their ID's
            -- - first make lookup to convert Keys tagInfo ref to index number
            local keysInfo = { }
            for index, ti in pairs(keys.Info) do
                if perlTruthy(keys.Remap[index]) then keysInfo[ti] = index end
            end
            local keysTable = et:GetTagTable('lexiftool.QuickTime.' .. keysGrp)
            local newKeysTags = Writer.GetNewTagInfoHash(et, keysTable)
            for _, tagInfo in pairs(newKeysTags) do
                local index = keysInfo[tagInfo]
                -- (upstream also maps an alternate-language tag through its
                --  SrcTagInfo and LangCode; QuickTime language alternates are
                --  not ported)
                if index then
                    local id = ExifTool.Put32u(index)
                    newTags[id] = tagInfo
                end
            end
        end
    else
        -- get hash of new tags to edit/create in this directory
        newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
    end
    local canCreate, delGrp
    if curPath == writePath or createKeys ~= 0 then
        canCreate = 1
        -- (must check the appropriate Keys delete flag if this is a Keys ItemList)
        delGrp = Writer.IsGroupDeleted(et, createKeys ~= 0 and keysGrp or dirName)
    end
    local delCount
    local boxPos = { }   -- tags written at this level (upstream %boxPos)
    local didDir = { }   -- directories written at this level (upstream %didDir)
    et.DidTag = et.DidTag or { }
    local mdat = { }        -- media data blocks to copy later
    local term               -- 4-zero udta terminator, held to the end

    -- loop through all atoms at this level
    while true do
        local n, hdr = raf:Read(8)
        if n ~= 8 then
            if n == 4 and hdr == '\0\0\0\0' then
                -- "for historical reasons" the udta is optionally terminated
                -- by 4 zeros (ref 1) --> hold this terminator to the end
                term = hdr
            elseif n ~= 0 then
                -- warn unless this is 1-3 pad bytes
                if n > 3 or hdr ~= string.rep('\0', n) then
                    et:Error('Unknown ' .. n .. ' bytes at end of file', 1)
                end
            end
            break
        end
        local size = Get32u(hdr, 0) - 8    -- (atom size without 8-byte header)
        local tag = hdr:sub(5, 8)
        if size == -7 then
            -- read the extended size
            local n2, buff = raf:Read(8)
            if n2 ~= 8 then et:Error('Truncated extended atom') break end
            hdr = hdr .. buff
            local hi, lo = Get32u(buff, 0), Get32u(buff, 4)
            if hi ~= 0 or lo > 0x7fffffff then
                if hi > 0x7fffffff then
                    et:Error('Invalid atom size')
                    break
                elseif not perlTruthy(et:Options('LargeFileSupport')) then
                    et:Error('End of processing at large atom (LargeFileSupport not enabled)')
                    break
                elseif perlStr(et:Options('LargeFileSupport')) == '2' then
                    et:Warn('Processing large atom (LargeFileSupport is 2)')
                end
            end
            size = hi * 4294967296 + lo - 16
            if size < 0 then et:Error('Invalid extended atom size') break end
        elseif size == -8 then
            if dataPt then
                et:Error('Terminator found in ' .. perlStr(dirName), 1)
            else
                -- size of zero indicates the atom extends to the end of file
                mdat[#mdat + 1] = { raf:Tell(), 0, hdr }
            end
            break
        elseif size < 0 then
            et:Error('Invalid atom size')
            break
        end

        -- keep track of 'mdat' atom locations for writing later
        if tag == 'mdat' then
            if dataPt then
                et:Error("'mdat' not at top level")
                break
            end
            mdat[#mdat + 1] = { raf:Tell(), raf:Tell() + size, hdr }
            if not raf:Seek(size, 1) then
                et:Error('Seek error in mdat atom')
                return rtnVal
            end
            goto nextAtom
        elseif tag == 'cmov' then
            et:Error("Can't yet write compressed movie metadata")
            return rtnVal
        elseif tag == 'wide' then
            if size ~= 0 then
                et:Warn("Incorrect size for 'wide' atom (" .. size .. ' bytes)')
                raf:Seek(size, 1)
            end
            goto nextAtom   -- drop 'wide' tag
        end

        -- read the atom data
        local buff = ''
        if size ~= 0 then
            if size > maxReadLen then
                et:Error("'" .. tag .. "' atom is too large for rewriting")
                return rtnVal
            end
            local got
            got, buff = raf:Read(size)
            if got ~= size then
                et:Error("Truncated '" .. tag .. "' atom")
                return rtnVal
            end
        end

        -- save the handler type of the track media
        if tag == 'hdlr' and length(buff) >= 12 and
            et.PATH and #et.PATH > 0 and et.PATH[#et.PATH] == 'Media'
        then
            et.MediaType = substr(buff, 8, 4)
        end
        -- if this atom stores offsets, save its location so we can fix up offsets later
        -- (are there any other atoms that may store absolute file offsets?)
        if offsetAtom[tag] then
            -- (note that we only need to do this if the media data is stored in this file)
            if tag == 'mfra' or tag == 'moof' then
                et:Error("Can't yet handle movie fragments when writing")
                return rtnVal
            elseif tag == 'sidx' or tag == 'saio' then
                et:Error("Can't yet handle " .. tag .. ' box when writing')
                return rtnVal
            elseif tag == 'iloc' then
                if not Handle_iloc(et, dirInfo, buff, buffered) then et:Error('Error parsing iloc atom') end
            elseif tag == 'gps ' then
                -- (only care about the 'gps ' box in 'moov')
                if dirInfo.DirID and dirInfo.DirID == 'moov' and #buff > 8 then
                    local off = dirInfo.ChunkOffset
                    local num = Get32u(buff, 4)
                    if num * 8 + 8 > #buff then num = (#buff - 8) // 8 end
                    for i = 0, num - 1 do
                        off[#off + 1] = { 'stco_gps ', length(buffered.value) + #hdr + 8 + i * 8, 4 }
                    end
                end
            elseif tag == 'CTBO' or tag == 'uuid' then -- hack for updating CR3 CTBO offsets
                dirInfo.ChunkOffset[#dirInfo.ChunkOffset + 1] = { tag, length(buffered.value), #hdr + size }
            else
                -- must update offsets since the data is in this file
                -- (this port has no QtDataFlg tracking, so it always assumes the
                --  media data is in this file -- upstream's `not $flg or $flg == 1`)
                dirInfo.ChunkOffset[#dirInfo.ChunkOffset + 1] = { tag, length(buffered.value) + #hdr, size }
            end
        end

        -- rewrite this atom
        local tagInfo = et:GetTagInfo(tagTablePtr, tag, buff)

        -- call write hook if it exists
        if tagInfo and tagInfo.WriteHook then tagInfo.WriteHook(buff, et) end

        -- delete all ItemList tags when deleting group, but take care not to
        -- delete UserData Meta
        if delGrp then
            if dirName == 'ItemList' then
                delCount = (delCount or 0) + 1
                et.CHANGED = (et.CHANGED or 0) + 1
                goto nextAtom
            elseif dirName == 'UserData' and not (tagInfo and tagInfo.SubDirectory) then
                delCount = (delCount or 0) + 1
                et.CHANGED = (et.CHANGED or 0) + 1
                goto nextAtom
            end
        end
        local newData
        local chunkOffset = { }
        -- allow numerical tag ID's (ItemList entries defined by Keys)
        if not tagInfo and dirName == 'ItemList' and et[keysGrp] then
            local keysIndex = Get32u(tag, 0)
            local newIndex = et[keysGrp].Remap[keysIndex]
            if newIndex ~= nil then
                tagInfo = et[keysGrp].Info[keysIndex]
                if newIndex == 0 then
                    if tagInfo then
                        et:VPrint(1, '    - Keys:' .. tagInfo.Name)
                    else
                        delCount = (delCount or 0) + 1
                    end
                    et.CHANGED = (et.CHANGED or 0) + 1
                    goto nextAtom
                end
                -- use the new Keys index of this item if it changed
                if keysIndex ~= newIndex then
                    tag = ExifTool.Put32u(newIndex)
                    hdr = carray.new('char'):append(hdr)    -- (a string again below)
                    substr(hdr, 4, 4, tag)
                    hdr = hdr:tostring()
                end
            end
        end
        if tagInfo and (tagInfo.Writable == nil or tagInfo.Writable) then
          if tagInfo.SubDirectory then
            local subdir = tagInfo.SubDirectory
            if tag == 'trak' then
                et.MediaType = ''  -- init media type for this track
            end
            local subName = subdir.DirName or tagInfo.Name
            local start = subdir.Start or 0
            local subdirInfo = {
                Parent   = dirName,
                DirName  = subName,
                Name     = tagInfo.Name,
                TagInfo  = tagInfo,
                DirID    = tag,
                DataPt   = buff,
                DataLen  = size,
                DataPos  = 0,
                DirStart = start,
                DirLen   = size - start,
                Base     = (dirInfo.Base or 0) + raf:Tell() - size,
                HasData  = subdir.HasData,
                OutFile  = buffered,
                NoRefTest = 1,
                WriteGroup = tagInfo.WriteGroup,
                Permanent = tagInfo.Permanent,
                -- details about the chunk offset tables inside this atom
                ChunkOffset = chunkOffset,
            }
            local subTable = subdir.TagTable
            if type(subTable) == 'string' then subTable = et:GetTagTable(subTable) end
            if subTable then
                local oldChanged = et.CHANGED
                newData = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                if newData ~= nil and #newData == 0 and
                   (tagInfo.Permanent or (tagTablePtr.PERMANENT and tagInfo.Permanent == nil)) then
                    -- do nothing if trying to delete tag from a PERMANENT table
                    et.CHANGED = oldChanged
                    newData = nil
                end
                -- add back header if necessary
                if start ~= 0 and newData ~= nil and #newData > 0 then
                    newData = buff:sub(1, start) .. newData
                    for _, co in ipairs(chunkOffset) do co[2] = co[2] + start end
                end
                if tag == 'trak' then
                    et.MediaType = ''     -- reset media type at end of track
                end
                -- the directory exists, so we don't need to add it
                if curPath == writePath and addDirs[subName] == dirName then
                    addDirs[subName] = nil
                end
                didDir[tag] = 1 -- (note: keyed by tag ID)
            end
            else
                -- modify existing QuickTime tags in various formats
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                if nvHash or delGrp then
                    local val, lang, format
                    format = tagInfo.Format
                    local hasData = dirInfo.HasData and matches(buff, [[\0...data\0]]) ~= nil
                    if hasData then
                        -- a sequence of 'data' atoms (upstream's $hasData branch)
                        local pos = 0
                        while pos + 16 <= size do
                            local len = Get32u(buff, pos)
                            local type_ = buff:sub(pos + 5, pos + 8)
                            local flags = Get32u(buff, pos + 8)
                            local ctry = Get16u(buff, pos + 12)
                            lang = Get16u(buff, pos + 14)
                            if lang == 0 then lang = undLang end
                            if pos + len > size then break end
                            if type_ == 'data' and len >= 16 then
                                local vlen = len - 16
                                val = buff:sub(pos + 17, pos + 16 + vlen)
                                -- decode value (see QuickTime.pm for an explanation)
                                -- (upstream also updates $flags for the format
                                --  it is about to write here, but FormatQTValue
                                --  below recomputes it, so the assignment is
                                --  dropped rather than carried dead)
                                if stringEncoding[flags] then
                                    val = et:Decode(val, stringEncoding[flags])
                                    if not tagInfo.Binary then val = val:gsub('%z$', '') end
                                elseif format then
                                    val = ExifTool.ReadValue(val, 0, format, tagInfo.Count, vlen)
                                end
                                local overwrite = nvHash and
                                    perlTruthy(Writer.IsOverwriting(et, nvHash, val))
                                if overwrite or delGrp then
                                    local newVal = et:GetNewValue(nvHash)
                                    newData = newData or carray.new('char'):append(substr(buff, 0, pos))
                                    local grp = et:GetGroup(tagInfo, 1)
                                    if et.VerboseValue then
                                        et:VerboseValue('- ' .. grp .. ':' .. tagInfo.Name, val)
                                    end
                                    et.CHANGED = (et.CHANGED or 0) + 1
                                    if newVal ~= nil and not (nvHash and et.DidTag[nvHash]) then
                                        local prVal = newVal
                                        local nf
                                        nf, newVal = FormatQTValue(et, newVal, tagInfo, format)
                                        if newVal ~= nil then
                                            if et.VerboseValue then
                                                et:VerboseValue('+ ' .. grp .. ':' .. tagInfo.Name, prVal)
                                            end
                                            local wLang = (lang == undLang) and 0 or lang
                                            newData:append(
                                                ExifTool.Put32u(#newVal + 16) .. type_ ..
                                                ExifTool.Put32u(nf) .. ExifTool.Put16u(ctry) ..
                                                ExifTool.Put16u(wLang) .. newVal)
                                        end
                                    end
                                elseif newData ~= nil then
                                    newData:append(substr(buff, pos, len))
                                end
                            elseif newData ~= nil then
                                newData:append(substr(buff, pos, len))
                            end
                            if nvHash then et.DidTag[nvHash] = 1 end
                            pos = pos + len
                        end
                        if newData ~= nil and pos < size then
                            newData:append(substr(buff, pos))
                        end
                        if newData ~= nil then newData = newData:tostring() end    -- (a string below)
                        val = nil   -- (already constructed newData)
                    elseif format then
                        val = ExifTool.ReadValue(buff, 0, format, nil, size)
                    elseif tag:sub(1, 1) == '\xa9' and size >= 4 then
                        -- international text: 2-byte length + 2-byte language
                        local len = Get16u(buff, 0)
                        lang = Get16u(buff, 2)
                        if 4 + len > size then len = len - 4 end
                        if len > size - 4 or len < 0 then len = size - 4 end
                        val = buff:sub(5, 4 + len)
                        if lang == 0 then lang = undLang end
                        local enc
                        if lang < 0x400 and val:sub(1, 2) ~= '\254\255' then
                            -- (this port has no CharsetQuickTime option;
                            --  upstream's default is MacRoman)
                            enc = et:Options('CharsetQuickTime') or 'MacRoman'
                        else
                            if val:sub(1, 2) == '\254\255' then
                                val = val:sub(3)
                                enc = 'UTF16'
                            else
                                enc = 'UTF8'
                            end
                        end
                        if not tagInfo.NoDecode then
                            val = et:Decode(val, enc)
                            val = val:gsub('%z+$', '')  -- remove trailing nulls
                        end
                    else
                        val = buff
                    end
                    if nvHash and val ~= nil then
                        if perlTruthy(Writer.IsOverwriting(et, nvHash, val)) then
                            newData = et:GetNewValue(nvHash)
                            if newData == nil and not canCreate then newData = '' end
                            et.CHANGED = (et.CHANGED or 0) + 1
                            local grp = et:GetGroup(tagInfo, 1)
                            if et.VerboseValue then
                                et:VerboseValue('- ' .. grp .. ':' .. tagInfo.Name, val)
                            end
                            if not (newData ~= nil and not et.DidTag[nvHash]) then
                                -- deleting this tag: drop the whole atom
                                -- (upstream keeps iprp items here; the HEIC
                                --  item machinery is not ported)
                                et.DidTag[nvHash] = 1
                                goto nextAtom
                            end
                            if et.VerboseValue then
                                et:VerboseValue('+ ' .. grp .. ':' .. tagInfo.Name, newData)
                            end
                            -- add back necessary header and encode as necessary
                            if lang ~= nil then
                                if not tagInfo.NoDecode then
                                    newData = et:Encode(newData,
                                        lang < 0x400 and
                                        (et:Options('CharsetQuickTime') or 'MacRoman') or 'UTF8')
                                end
                                local wLang = (lang == undLang) and 0 or lang
                                newData = ExifTool.Put16u(#newData) ..
                                          ExifTool.Put16u(wLang) .. newData
                            elseif not format or
                                   (format:match('^string') and not tagInfo.Binary
                                    and not tagInfo.ValueConv) then
                                -- write all strings as UTF-8
                                newData = et:Encode(newData, 'UTF8')
                            elseif format and not tagInfo.Binary then
                                newData = Writer.WriteValue(newData, format, tagInfo.Count)
                            end
                        end
                        et.DidTag[nvHash] = 1   -- so we don't add this tag again
                    end
                end
          end
        end

        -- write the new atom if it was modified
        if newData ~= nil then
            local sizeDiff = #buff - #newData
            -- pad to original size if specified, otherwise give verbose message about the changed size
            if sizeDiff > 0 and tagInfo.PreservePadding and perlTruthy(et:Options('QuickTimePad')) then
                newData = newData .. string.rep('\0', sizeDiff)
                et:VPrint(1, '    (' .. perlStr(tagInfo.Name) .. ' padded to original size)')
            elseif sizeDiff ~= 0 then
                et:VPrint(1, '    (' .. perlStr(tagInfo.Name) .. ' changed size)')
            end
            local len = #newData + 8
            if len > 0x7fffffff then
                et:Error(perlStr(tagInfo.Name) .. ' too large to write')
                break
            end
            -- update size in ChunkOffset list for modified 'uuid' atom
            if tag == 'uuid' and #dirInfo.ChunkOffset > 0 then
                dirInfo.ChunkOffset[#dirInfo.ChunkOffset][3] = len
            end
            if len > 8 then   -- don't write empty atom header
                -- maintain pointer to chunk offsets if necessary
                for _, co in ipairs(chunkOffset) do
                    co[2] = co[2] + 8 + length(buffered.value)
                    dirInfo.ChunkOffset[#dirInfo.ChunkOffset + 1] = co
                end
                boxPos[tag] = { length(buffered.value), #newData + 8 }
                Write(buffered, ExifTool.Put32u(len), tag, newData)
            end
            goto nextAtom
        end

        -- copy the existing atom
        boxPos[tag] = { length(buffered.value), #hdr + #buff }
        Write(buffered, hdr, buff)
        ::nextAtom::
    end

    -- can finally set necessary variables for creating Video/AudioKeys tags
    if createKeys < 0 then
        if avType[et.MediaType] then
            createKeys = 1
            keysGrp, keysPath = avType[et.MediaType] .. 'Keys', 'MOV-Movie-Track'
        else
            canCreate = nil
        end
    end
    if not addDirs[keysGrp] then createKeys = createKeys & ~0x01 end  -- (Keys may have been written)

    -- add new directories/tags at this level if necessary
    -- (port: WriteItemInfo for HEIC is called below; WriteLast is not ported)
    if canCreate and ((et.EDIT_DIRS and et.EDIT_DIRS[dirName] ~= nil) or createKeys ~= 0) then
        -- get a hash of tagInfo references to add to this directory
        local dirs = Writer.GetAddDirHash(et, tagTablePtr, dirName)
        -- make sorted list of new tags to be added
        local seen, addTags = { }, { }
        for _, t in ipairs({ dirs, newTags }) do
            for k in pairs(t) do
                if not seen[k] then seen[k] = true; addTags[#addTags + 1] = k end
            end
        end
        tsort(addTags)
        -- add Keys tags if necessary
        if createKeys ~= 0 then
            if curPath == keysPath then
                -- add Meta for Keys if necessary
                if not didDir.meta then
                    dirs.meta = QuickTime.Movie.meta
                    addTags[#addTags + 1] = 'meta'
                end
            elseif curPath == keysPath .. '-Meta' then
                -- special case for Keys Meta -- reset directories and start again
                addTags = { }
                dirs = { }
                for _, t in ipairs({ 'keys', 'ilst' }) do
                    if not didDir[t] then  -- don't add again
                        dirs[t] = QuickTime.Meta[t]
                        addTags[#addTags + 1] = t
                    end
                end
            elseif curPath == keysPath .. '-Meta-ItemList' and et[keysGrp] then
                local indices = { }
                for index in pairs(et[keysGrp].Add) do indices[#indices + 1] = index end
                tsort(indices)
                for _, index in ipairs(indices) do
                    local id = ExifTool.Put32u(index)
                    newTags[id] = et[keysGrp].Add[index]
                    addTags[#addTags + 1] = id
                end
            else
                dirs = Writer.GetAddDirHash(et, tagTablePtr, dirName)
                local more = { }
                for k in pairs(dirs) do more[#more + 1] = k end
                tsort(more)
                for _, k in ipairs(more) do addTags[#addTags + 1] = k end
            end
        end
        -- (note that aTag may be a binary Keys index here)
        for _, aTag in ipairs(addTags) do
            local tagInfo = dirs[aTag] or newTags[aTag]
            -- (upstream `ref $tagInfo eq 'HASH'`: a list of conditional
            --  tagInfos, as Meta's 'keys', is an array ref)
            if type(tagInfo) == 'table' and tagInfo[1] ~= nil then
                tagInfo = et:GetTagInfo(tagTablePtr, aTag)
            end
            local skip = type(tagInfo) ~= 'table'
            if not skip and tagInfo.CanCreate ~= nil and not tagInfo.CanCreate then skip = true end
            if not skip and tagInfo.MediaType and et.MediaType ~= tagInfo.MediaType then skip = true end
            local subdir = not skip and tagInfo.SubDirectory or nil
            if not skip and subdir then
                local subName = subdir.DirName or tagInfo.Name
                local buf2
                -- QuickTime hierarchy is complex, so check full directory path before adding
                if createKeys ~= 0 and curPath == keysPath and subName == 'Meta' then
                    et:VPrint(0, '  Creating Meta with mdta Handler and Keys\n')
                    -- init Meta box for Keys tags with mdta Handler and empty Keys+ItemList
                    buf2 = '\0\0\0\x20hdlr\0\0\0\0\0\0\0\0mdta\0\0\0\0\0\0\0\0\0\0\0\0' ..
                           '\0\0\0\x10keys\0\0\0\0\0\0\0\0' ..
                           '\0\0\0\x08ilst'
                elseif createKeys ~= 0 and curPath == keysPath .. '-Meta' then
                    buf2 = (subName == 'Keys' and '\0\0\0\0\0\0\0\0' or '')
                elseif subName == 'Meta' and perlTruthy(et:Options('QuickTimeHandler')) then
                    et:VPrint(0, '  Creating Meta with mdir Handler\n')
                    -- init Meta box for ItemList tags with mdir Handler
                    buf2 = '\0\0\0\32hdlr\0\0\0\0\0\0\0\0mdir\0\0\0\0\0\0\0\0\0\0\0\0'
                elseif curPath == writePath and addDirs[subName] == dirName then
                    buf2 = ''   -- write from scratch
                end
                if buf2 then
                    local subdirInfo = {
                        Parent      = dirName,
                        DirName     = subName,
                        DataPt      = buf2,
                        DirStart    = 0,
                        HasData     = subdir.HasData,
                        OutFile     = buffered,
                        ChunkOffset = { },  -- (just to be safe)
                        WriteGroup  = tagInfo.WriteGroup,
                    }
                    local subTable = subdir.TagTable
                    if type(subTable) == 'string' then subTable = et:GetTagTable(subTable) end
                    local newData = subTable and
                        Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                    if newData and #newData > 0 and #newData <= 0x7ffffff7 then
                        -- add the atom's version or UUID prefix if necessary
                        -- (upstream digs the UUID out of the tag's Condition
                        --  regexp with an eval; this port's Conditions are Lua
                        --  functions, so the bytes are carried in
                        --  SubDirectory.UUID instead -- see the tag definition)
                        local prefix = ''
                        if subdir.Start == 4 then
                            prefix = '\0\0\0\0'     -- a simple version number
                        elseif subdir.Start then
                            -- get UUID from Condition expression
                            prefix = ConditionUUID(tagInfo.Condition)
                            if prefix == nil or #prefix ~= subdir.Start then
                                et:Error('Internal UUID error')
                                prefix = nil
                            end
                        end
                        if prefix then
                            local newHdr = ExifTool.Put32u(8 + #newData + #prefix) .. aTag .. prefix
                            boxPos[aTag] = { length(buffered.value), #newHdr + #newData }
                            Write(buffered, newHdr, newData)
                        end
                    end
                    -- add only once (must delete _after_ call to WriteDirectory())
                    -- (Keys tags are a special case, and are handled separately)
                    if createKeys == 0 then addDirs[subName] = nil end
                end
            elseif not skip then
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                if nvHash and not et.DidTag[nvHash] and
                   nvHash.IsCreating and nvHash.IsCreating ~= 0 and
                   perlTruthy(Writer.IsOverwriting(et, nvHash)) then
                    local newVal = et:GetNewValue(nvHash)
                    if newVal ~= nil then
                        local prVal = newVal
                        local flags
                        flags, newVal = FormatQTValue(et, newVal, tagInfo)
                        if newVal ~= nil then
                            -- (upstream also packs the language/country code of
                            --  an alternate-language tag here; not ported)
                            if dirInfo.HasData then
                                -- add 'data' header
                                newVal = ExifTool.Put32u(16 + #newVal) .. 'data' ..
                                         ExifTool.Put32u(flags) .. ExifTool.Put16u(0) ..
                                         ExifTool.Put16u(0) .. newVal
                            elseif aTag:sub(1, 1) == '\169' or tagInfo.IText then
                                if tagInfo.IText and tagInfo.IText >= 6 then
                                    -- add 6-byte langText header and trailing null
                                    -- (with extra junk before language code if IText > 6)
                                    local n = tagInfo.IText - 6
                                    -- (upstream `$newVal .= ' ' x $n if length($newVal) < $n`
                                    --  appends n spaces, it does not pad TO n)
                                    if #newVal < n then newVal = newVal .. string.rep(' ', n) end
                                    -- (upstream's `pack('n',0,$lang)` packs only
                                    --  the FIRST value -- one 'n' template, two
                                    --  arguments -- so the language code never
                                    --  makes it into the box.  Reproduced, not
                                    --  "fixed": the box length depends on it)
                                    newVal = '\0\0\0\0' .. newVal:sub(1, n) ..
                                             ExifTool.Put16u(0) ..
                                             newVal:sub(n + 1) .. '\0'
                                else
                                    -- add IText header
                                    newVal = ExifTool.Put16u(#newVal) .. ExifTool.Put16u(0) .. newVal
                                end
                            end
                            boxPos[aTag] = { length(buffered.value), 8 + #newVal }
                            Write(buffered, ExifTool.Put32u(8 + #newVal), aTag, newVal)
                            local grp = et:GetGroup(tagInfo, 1)
                            if et.VerboseValue then
                                et:VerboseValue('+ ' .. grp .. ':' .. tagInfo.Name, prVal)
                            end
                            et.DidTag[nvHash] = 1
                            et.CHANGED = (et.CHANGED or 0) + 1
                        end
                    end
                end
            end
        end
    end

    if delCount then
        et:VPrint(0, '  [deleting ' .. delCount .. ' ' .. perlStr(dirName) .. ' tag' ..
                     (delCount == 1 and '' or 's') .. ']\n')
    end

    -- write HEIC metadata after top-level 'meta' box has been processed if editing this information
    if curPath == 'MOV-Meta' and et.EDIT_DIRS and et.EDIT_DIRS.ItemInformation ~= nil then
        dirInfo.BoxPos = boxPos
        -- (upstream patches its output buffer in place; this port collects the
        --  buffer as a list of strings, so flatten it into one mutable carray
        --  for the duration of the call and hand the result back)
        local mdatEdit = WriteQuickTime.WriteItemInfo(et, dirInfo, buffered.value)
        if mdatEdit then
            if et.mdatEdit then et:Error('Multiple top-level Meta containers') end
            et.mdatEdit = mdatEdit
        end
    end

    -- write out any necessary terminator
    if term and length(buffered.value) > 0 then Write(buffered, term) end

    -- delete temporary Keys variables after Meta is processed
    if dirName == 'Meta' then
        -- delete any Meta box with no useful information (ie. only 'hdlr','keys','lang','ctry')
        local isEmpty = true
        local names = { }
        for t in pairs(boxPos) do
            if not emptyMeta[t] then isEmpty = false break end
            names[#names + 1] = emptyMeta[t]
        end
        if isEmpty then
            if #names > 0 then
                tsort(names)
                et:VPrint(0, '  Deleting ' .. table.concat(names, '+'))
            end
            buffered.value = carray.new('char')
        end
        if curPath == keysPath .. '-Meta' then
            addDirs[keysGrp] = nil  -- prevent creation of another Meta for Keys tags
            et[keysGrp] = nil
        end
    end

    -- return now if writing subdirectory
    if dataPt then
        return buffered.value:tostring()
    end

    -- issue minor error if we didn't find an 'mdat' atom
    local off = dirInfo.ChunkOffset
    if #mdat == 0 then
        for _, co in ipairs(off) do
            if co[1] ~= 'uuid' then
                et:Error('Media data referenced but not found')
                return rtnVal
            end
        end
        et:Warn('No media data', 1)
    end

    -- edit mdat blocks as required
    -- (1=old pos [0 if creating], 2=old end [0 if creating], 3=new data or nil to delete,
    --  4=new data item id)
    local mdatEdit = { }
    if et.mdatEdit then
        mdatEdit = et.mdatEdit
        et.mdatEdit = nil
    end
    -- (the metadata buffer is patched from here on -- the mdat edit below sets
    --  the chunk offset of a newly inserted item chunk, the fixup loop after it
    --  every other offset)
    local outStr = buffered.value
    for _, edit in ipairs(mdatEdit) do
        local thisMdat, newMdat, changed = { }, { }, nil
        for i = 1, #mdat do
            local m = mdat[i]
            -- keep track of all chunks for the mdat with this header
            if #m[3] > 0 then
                for _, t in ipairs(thisMdat) do newMdat[#newMdat + 1] = t end
                thisMdat = { }
            end
            thisMdat[#thisMdat + 1] = m
            -- is this edit inside this mdat chunk?
            -- - edit[1] and edit[2] will both be zero if we are creating a new chunk
            -- - m[2] is zero if mdat runs to end of file
            -- - edit[1] == edit[2] == m[1] if reviving a deleted chunk
            -- - m[6] is defined if this was a newly added/edited chunk
            if m[6] ~= nil or changed then goto nextMdat end -- don't replace a newly added chunk
            if not perlTruthy(edit[1]) or    -- (newly created chunk)
                -- (edit is inside chunk)
                (((edit[1] < m[2] or not perlTruthy(m[2])) and edit[2] > m[1]) or
                -- (edit inserted at start or end of chunk)
                (edit[1] == edit[2] and (edit[1] == m[1] or edit[1] == m[2])))
            then
                if not perlTruthy(edit[1]) then
                    edit[1] = m[1]  -- insert at start of this mdat
                    edit[2] = m[1]
                elseif edit[1] < m[1] or (edit[2] > m[2] and perlTruthy(m[2])) then
                    et:Error('ItemInfo runs across mdat boundary')
                    return rtnVal
                end
                local hdrChunk = thisMdat[1]
                if not hdrChunk then et:Error('Internal error finding mdat header') return rtnVal end
                -- calculate difference in mdat size
                local diff = (edit[3] and #edit[3] or 0) - (edit[2] - edit[1])
                -- edit size of mdat in header if necessary
                if diff ~= 0 then
                    if #hdrChunk[3] == 8 then
                        local size2 = Get32u(hdrChunk[3], 0)
                        if size2 ~= 0 then -- (0 size = extends to end of file)
                            size2 = size2 + diff
                            if size2 > 0xffffffff then
                                et:Error("Can't yet grow mdat across 4GB boundary")
                                return rtnVal
                            end
                            local h = carray.new('char')
                            h:append(hdrChunk[3])
                            ExifTool.Set32u(h, 0, size2)
                            hdrChunk[3] = h:tostring()
                        end
                    elseif #hdrChunk[3] == 16 then
                        local size2 = ExifTool.Get64u(hdrChunk[3], 8)
                        if size2 ~= 0 then
                            size2 = size2 + diff
                            local h = carray.new('char')
                            h:append(hdrChunk[3])
                            Writer.Set64u(h, 8, size2)
                            hdrChunk[3] = h:tostring()
                        end
                    else
                        et:Error('Internal error. Invalid mdat header')
                        return rtnVal
                    end
                end
                changed = 1
                -- remove the edited section of this chunk (if any) and replace with new data (if any)
                if edit[1] > m[1] then
                    if edit[3] then
                        thisMdat[#thisMdat + 1] = { edit[1], edit[2], '', 0, edit[3], edit[4] }
                    end
                    -- add remaining data after edit (or empty stub in case it is referenced by an offset)
                    thisMdat[#thisMdat + 1] = { edit[2], m[2], '' }
                    m[2] = edit[1]  -- now ends at start of edit
                else
                    if edit[3] then
                        -- insert the new chunk before this chunk, moving the header to the new chunk
                        table.insert(thisMdat, #thisMdat, { edit[1], edit[2], m[3], 0, edit[3], edit[4] })
                        m[3] = ''     -- (header was moved to new chunk)
                        -- initialize ChunkOffset pointer if necessary
                        if perlTruthy(edit[4]) then
                            local n = 0
                            for _, co in ipairs(off) do
                                if co[5] ~= nil and co[5] == edit[4] then
                                    n = n + 1
                                    if co[1] == 'stco_iloc' then
                                        ExifTool.Set32u(outStr, co[2], m[1])
                                    else
                                        Writer.Set64u(outStr, co[2], m[1])
                                    end
                                end
                            end
                            if n ~= 1 then et:Error('Internal error updating chunk offsets') end
                        end
                    end
                    m[1] = edit[2]  -- remove old data
                end
            end
            ::nextMdat::
        end
        if changed then
            mdat = { }
            for _, m in ipairs(newMdat) do mdat[#mdat + 1] = m end
            for _, m in ipairs(thisMdat) do mdat[#mdat + 1] = m end
            et.CHANGED = (et.CHANGED or 0) + 1
        else
            et:Error('Internal error modifying mdat')
        end
    end

    -- determine our new mdat positions
    -- (1=old pos, 2=old end, 3=mdat header, 4=new pos, 5=new data if changed, 6=new item ID)
    local pos = length(buffered.value)
    for _, m in ipairs(mdat) do
        pos = pos + #m[3]
        m[4] = pos
        pos = pos + (m[5] and #m[5] or (m[2] - m[1]))
    end

    -- fix up offsets for new mdat position(s) (and uuid positions in CR3 images)
    for _, co in ipairs(off) do
        local type_, ptr, len, base, id = co[1], co[2], co[3], co[4], co[5]
        base = base or 0
        local kind, sub = type_:match('^(stco)_?(.*)$')
        if not kind then kind, sub = type_:match('^(co64)_?(.*)$') end
        if not kind then
            if type_ == 'uuid' then goto nextOff end
            if type_ ~= 'CTBO' then
                et:Error('Internal error fixing offsets')
                break
            end
            -- update 'CTBO' item offsets/sizes in Canon CR3 images
            if co[3] <= 12 then et:Error('Invalid CTBO atom') break end
            if #mdat == 0 then et:Error('Missing CR3 image data') break end
            local n = Get32u(outStr, co[2] + 8)
            if co[3] < n * 20 + 12 then et:Error('Truncated CTBO atom') break end
            local ctboOff = {}
            -- (one snapshot for the uuid identifiers below, rather than one
            --  string copy of the whole output buffer per uuid box)
            local outAll = outStr:tostring()
            -- determine uuid types, and build an offset lookup based on CTBO ID number
            for _, u in ipairs(off) do
                -- (ignore undersized and deleted uuid boxes)
                if u[1] == 'uuid' and u[3] >= 24 then
                    local upos = u[2]
                    -- (will happen for WriteLast uuid tags)
                    if upos + 24 <= #outAll then
                        local usiz = Get32u(outStr, upos)   -- get size of uuid atom
                        local skip = false
                        if usiz == 1 then                   -- check for extended (8-byte) size
                            if u[3] < 32 then skip = true else upos = upos + 8 end
                        end
                        if not skip then
                            -- get CTBO entry ID based on 16-byte UUID identifier
                            local uid = ctboID[outAll:sub(upos + 9, upos + 24)]
                            if uid ~= nil then ctboOff[uid] = u end
                        end
                    end
                end
            end
            -- calculate new offset for the first mdat (size of -1 indicates it didn't change)
            ctboOff[3] = { 'mdat', mdat[1][4] - #mdat[1][3], -1 }
            for i = 0, n - 1 do
                local cpos = co[2] + 12 + i * 20
                local cid = Get32u(outStr, cpos)
                -- ignore if size is zero unless we can add this entry
                -- (note: can't yet add/delete PreviewImage, but leave this possibility open)
                if ExifTool.Get64u(outStr, cpos + 12) ~= 0 or cid == 1 or cid == 2 then
                    if ctboOff[cid] == nil then
                        if cid ~= 1 and cid ~= 2 then
                            et:Error("Can't handle CR3 CTBO ID number " .. cid)
                            break
                        end
                        -- XMP or PreviewImage was deleted -- set offset and size to zero
                        ctboOff[cid] = { 'uuid', 0, 0 }
                    end
                    -- update the new offset and size of this entry
                    Writer.Set64u(outStr, cpos + 4, ctboOff[cid][2])
                    -- (upstream `unless $ctboOff{$id}[2] < 0`; a size of -1
                    --  marks the mdat entry, whose size did not change)
                    if ctboOff[cid][3] >= 0 then
                        Writer.Set64u(outStr, cpos + 12, ctboOff[cid][3])
                    end
                end
            end
            goto nextOff
        end
        do
            local siz = (kind == 'co64') and 8 or 4
            local n, tag
            if sub ~= '' then   -- is this an offset in an iloc or 'gps ' atom?
                n = 1
                type_ = kind
                tag = sub
            else                -- this is an stco or co84 atom
                if len < 8 then goto nextOff end
                n = Get32u(outStr, ptr + 4)     -- get number of entries in table
                ptr = ptr + 8
                len = len - 8
                tag = kind
            end
            local endPtr = ptr + n * siz
            if endPtr > ptr + len then
                et:Error('Invalid ' .. tag .. ' table')
                return rtnVal
            end
            while ptr < endPtr do
                local val = (type_ == 'co64') and ExifTool.Get64u(outStr, ptr) or Get32u(outStr, ptr)
                local ok
                for i = 1, #mdat do
                    local m = mdat[i]
                    local mpos = val + base
                    local take
                    if m[6] ~= nil then -- is this chunk associated with an item we edited?
                        -- set offset only for the corresponding new chunk
                        if id ~= nil and id == m[6] then
                            take = true
                        else
                            -- could have pointed to empty chunk before inserted chunk
                            take = (mpos == m[1] and m[1] ~= m[2])
                        end
                    else
                        -- (have seen mpos == m[2], which is a real PITA)
                        take = mpos >= m[1] and (mpos <= m[2] or m[2] == 0)
                        -- step to next chunk if contiguous and at the end of this one
                        if take and mpos == m[2] and i < #mdat and mpos == mdat[i + 1][1] then
                            take = false
                        end
                    end
                    if take then
                        val = val + m[4] - m[1]
                        if val < 0 then
                            et:Error('Error fixing up ' .. tag .. ' offset')
                            return rtnVal
                        end
                        if type_ == 'co64' then
                            Writer.Set64u(outStr, ptr, val)
                        elseif val <= 0xffffffff then
                            ExifTool.Set32u(outStr, ptr, val)
                        else
                            et:Error("Can't yet promote " .. tag .. ' offset to 64 bits')
                            return rtnVal
                        end
                        ok = true
                        break
                    end
                end
                if not ok then
                    et:Error('Chunk offset in ' .. tag .. ' atom is outside media data')
                    return rtnVal
                end
                ptr = ptr + siz
            end
        end
        ::nextOff::
    end

    -- write the metadata
    Write(outfile, outStr)

    -- write the media data
    for _, m in ipairs(mdat) do
        Write(outfile, m[3])                        -- write mdat header
        if m[5] then
            Write(outfile, m[5])
            goto nextMdatWrite
        end
        if not raf:Seek(m[1], 0) then
            et:Error('Seek error')
            break
        end
        if m[2] ~= 0 then
            if Writer.CopyBlock(raf, outfile, m[2] - m[1]) ~= 1 then
                et:Error('Truncated mdat atom')
                break
            end
        else
            -- mdat continues to end of file
            while true do
                local nr, chunk = raf:Read(65536)
                if not nr or nr == 0 then break end
                Write(outfile, chunk)
            end
        end
        ::nextMdatWrite::
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Write QuickTime-format MOV/MP4 file (upstream WriteMOV)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid QuickTime file,
--          or -1 if a write error occurred
--------------------------------------------------------------------------------
function WriteQuickTime.WriteMOV(et, dirInfo)
    if not et then return 1 end   -- allow dummy access
    local Writer = require('lexiftool.Writer')
    local raf = dirInfo.RAF
    if not raf then return 0 end

    -- read the first atom header
    local n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    local size = Get32u(buff, 0)
    local tag = buff:sub(5, 8)
    if size < 8 and size ~= 1 then return 0 end

    -- validate the file format
    local tagTablePtr = et:GetTagTable('lexiftool.QuickTime.Main')
    if not tagTablePtr[tag] then return 0 end

    -- determine the file type (by default, assume MP4 if 'ftyp' exists
    -- without 'qt  ' as a compatible brand, but HEIC is an exception)
    local ftype
    local n2, brands
    if tag == 'ftyp' and size >= 12 and size < 100000 then
        n2, brands = raf:Read(size - 8)
    end
    if n2 == size - 8 and not matches(brands, [[^(....)+(qt  )]]) then
        if brands:sub(1, 4) == 'crx ' then
            ftype = 'CR3'
        elseif matches(brands, [[^(heic|mif1|msf1|heix|hevc|hevx|avif)]]) then
            ftype = 'HEIC'
        else
            ftype = 'MP4'
        end
    else
        ftype = 'MOV'
    end
    et:SetFileType(ftype)   -- need to set "FileType" tag for a Condition
    if not dirMap[ftype] then
        et:Error('Writing of ' .. ftype .. ' files is not yet supported')
        return 0
    end
    if ftype == 'HEIC' then
        -- EXIF is preferred in HEIC files
        Writer.InitWriteDirs(et, dirMap[ftype], 'EXIF', 'QuickTime')
    else
        Writer.InitWriteDirs(et, dirMap[ftype], 'XMP', 'QuickTime')
    end
    et.DirMap = dirMap[ftype]   -- need access to directory map when writing
    -- track tags globally to avoid creating multiple tags in the case of
    -- duplicate directories
    et.DidTag = { }
    ExifTool.SetByteOrder('MM')
    raf:Seek(0, 0)

    -- write the file
    et.MediaType = ''
    dirInfo.Parent = ''
    dirInfo.DirName = 'MOV'
    dirInfo.ChunkOffset = { }   -- (just to be safe)
    return WriteQuickTime.WriteQuickTime(et, dirInfo, tagTablePtr) and 1 or -1
end

return WriteQuickTime
