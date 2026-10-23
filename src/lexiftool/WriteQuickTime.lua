--------------------------------------------------------------------------------
-- File:         lexiftool/WriteQuickTime.lua
-- Ported from:  lib/Image/ExifTool/WriteQuickTime.pl
--
-- Description:  Write XMP to QuickTime (MOV and MP4) files
--
-- Revisions:    2013-10-29 - P. Harvey Created
--
-- Port notes:   Complete port of WriteQuickTime.pl: the atom-rewriting
--               engine (WriteMOV/WriteQuickTime) with its container recursion
--               through WriteDirectory, the 'mdat' bookkeeping and the
--               stco/co64/iloc/'gps '/CTBO offset fixup, the data-reference
--               tracking (dinf/dref/stsd) that decides whether offsets point
--               into this file, value editing for the three value shapes
--               (ItemList 'data' atoms, international text, plain formats)
--               including alternate-language tags (Keys, ItemList and
--               UserData), tag and directory creation and deletion, Keys
--               (WriteKeys and the index remapping in the ItemList), HEIC
--               items (WriteItemInfo, the mdat edits, and the restriction of
--               item properties to the primary item), WriteLast boxes after
--               the media data, and the trailers: those IdentifyTrailers
--               finds from the end of the file and those recognised from
--               their first bytes after the last atom are copied or deleted
--               (a MIE trailer is rewritten through MIE.ProcessMIE).
--               Movie fragments (moof/mfra) and sidx/saio boxes stop the
--               write with upstream's error.
--
--               Port artifacts: upstream's $outfile scalar reference is the
--               box { value = <carray> } of doc/api.md §4, which
--               WriteItemInfo patches in place; the mdat, mdatEdit,
--               ChunkOffset and trailer lists keep upstream's member order
--               in 1-based Lua arrays.  The UUID prefix of a newly created
--               'uuid' atom comes from its Lua Condition function, whose
--               source line ConditionUUID reads back (upstream evaluates the
--               regex of its Condition string).
--
--               Moved here from QuickTime.lua to mirror upstream's file
--               split; QuickTime.lua loads it on first use of a write
--               routine (upstream AUTOLOAD).
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
local unpack = perl.unpack
local lc, uc = perl.lc, perl.uc
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
    if not et then return 1 end   -- allow dummy access to autoload this package
    local Writer = require('lexiftool.Writer')
    local dataPt = dirInfo.DataPt or ''
    local dirLen = length(dataPt)
    local done, remap, info, add = { }, { }, { }, { }

    local keysGrp = avType[et.MediaType] and (avType[et.MediaType] .. 'Keys') or 'Keys'
    if dirLen < 8 then et:Warn('Short Keys box') dirLen = 8 dataPt = string.rep('\0', 8) end
    if Writer.IsGroupDeleted(et, keysGrp) then
        dirLen = 8    -- delete all existing keys
        -- deleted keys are identified by a zero entry in the Remap lookup
        local n = Get32u(dataPt, 4)
        for i = 1, n do remap[i] = 0 end
        et:VPrint(0, '  [deleting ' .. n .. ' ' .. keysGrp .. ' entr' .. (n == 1 and 'y' or 'ies') .. ']\n')
        et.CHANGED = (et.CHANGED or 0) + 1
    end
    local pos = 8
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
    local newData = carray.new('char'):append(substr(dataPt, 0, pos))

    local newIndex = 1
    local index = 1
    while pos < dirLen - 4 do
        local len = unpack('x' .. pos .. 'N', dataPt)
        if len < 8 or pos + len > dirLen then break end
        local ns  = substr(dataPt, pos + 4, 4)
        local tag = substr(dataPt, pos + 8, len - 8)
        tag = subst(tag, [[(?s)\0.*]], '') -- truncate at null
        if ns == 'mdta' then tag = subst(tag, [[^com\.apple\.quicktime\.]], '') end -- remove apple quicktime domain
        if not perlTruthy(tag) then tag = 'Tag_' .. ns end
        done[tag] = 1    -- set flag to avoid creating this tag
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo then
            info[index] = tagInfo
            if newTags[tag] then
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                -- drop this tag if it is being deleted
                if nvHash and Writer.IsOverwriting(et, nvHash) > 0 and et:GetNewValue(nvHash) == nil then
                    -- don't delete this key if we could be writing any alternate-language version of this tag
                    local dontDelete
                    for t in pairs(newTags) do
                        if newTags[t].SrcTagInfo and newTags[t].SrcTagInfo == tagInfo then
                            local nv = Writer.GetNewValueHash(et, newTags[t])
                            if perlTruthy(Writer.IsOverwriting(et, nv)) and et:GetNewValue(nv) ~= nil then
                                dontDelete = 1
                                break
                            end
                        end
                    end
                    if not dontDelete then
                        -- delete this key
                        et:VPrint(1, (et.INDENT or '') .. '[deleting ' .. keysGrp .. ' entry ' .. index .. " '" .. tag .. "']\n")
                        pos = pos + len
                        remap[index] = 0
                        index = index + 1
                        et.CHANGED = (et.CHANGED or 0) + 1
                        goto next
                    end
                end
            end
        end
        -- add to the Keys box data
        newData:append(substr(dataPt, pos, len))
        remap[index] = newIndex
        index = index + 1
        newIndex = newIndex + 1
        pos = pos + len
        ::next::
    end
    -- add keys for any tags we need to create
    local tags = { }
    for t in pairs(newTags) do tags[#tags + 1] = t end
    tsort(tags)
    for _, tag in ipairs(tags) do
        local tagInfo = newTags[tag]
        local id
        if tagInfo.LangCode and tagInfo.SrcTagInfo then
            id = tagInfo.SrcTagInfo.TagID
        else
            id = tag
        end
        if done[id] then goto nextTag end
        do
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            if not (nvHash and perlTruthy(nvHash.IsCreating) and perlTruthy(Writer.IsOverwriting(et, nvHash)) and
                et:GetNewValue(nvHash) ~= nil) then goto nextTag end
            -- add new entry to 'keys' data
            local val = id
            local ok, c1 = isMatch(val, [[^(.*?)\.]])
            if not (ok and fullKeysID[c1]) then
                val = 'com.apple.quicktime.' .. val
            end
            newData:append(ExifTool.Put32u(8 + length(val)) .. 'mdta' .. val)
            et:VPrint(1, (et.INDENT or '') .. '[adding ' .. keysGrp .. ' entry ' .. newIndex .. " '" .. id .. "']\n")
            add[newIndex] = tagInfo
            newIndex = newIndex + 1
            et.CHANGED = (et.CHANGED or 0) + 1
        end
        ::nextTag::
    end
    local num = newIndex - 1
    if num ~= 0 then
        ExifTool.Set32u(newData, 4, num)     -- update count in header
    else
        newData = carray.new('char')  -- delete empty Keys box
    end
    -- save temporary variables for use when writing ItemList:
    --   Remap - lookup for remapping Keys ID numbers (0 if item is deleted)
    --   Info  - Keys tag information, based on old index value
    --   Add   - Keys items deleted, based on old index value
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
            --[retracted] # create new item information hash to save infe box in case we need it for sorting
            --[retracted] my $item = $$items{$id} = { };
            -- add new infe entry to iinf box
            local n = #type_ + #mime + #enc + 16
            if newID < 0x10000 then
                add.iinf = add.iinf .. perl.pack('Na4CCCCnn', n, 'infe', 2, 0, 0, 1, newID, 0) .. type_ .. mime .. enc
            else
                n = n + 2
                add.iinf = add.iinf .. perl.pack('Na4CCCCNn', n, 'infe', 3, 0, 0, 1, newID, 0) .. type_ .. mime .. enc
            end
            --[retracted] $add{iinf} .= $$item{infe};
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
    --[This sorting idea was retracted because just sorting 'iinf' wasn't sufficient to
    -- repair the problem where an out-of-order ID was added -- Apple Preview still
    -- ignores the gain-map image.  It looks like either or both 'iref' and 'iloc' must
    -- also be sorted by ID, although the spec doesn't mention this]
    --[retracted] # sort infe entries in iinf box if necessary
    --[retracted] if ($$et{ItemsNotSorted}) {
    --[retracted]     if ($$boxPos{iinf}) {
    --[retracted]         my $iinfVer = Get8u($outfile, $$boxPos{iinf}[0] + 8);
    --[retracted]         my $off = $iinfVer == 0 ? 14 : 16;  # offset to first infe item
    --[retracted]         my $sorted = '';    # sorted iinf payload
    --[retracted]         $sorted .= $$items{$_}{infe} || '' foreach sort { $a <=> $b } keys %$items;
    --[retracted]         if (length $sorted == $$boxPos{iinf}[1]-$off) {
    --[retracted]             # replace with sorted infe entries
    --[retracted]             substr($$outfile, $$boxPos{iinf}[0] + $off, length $sorted) = $sorted;
    --[retracted]             $et->Warn('Item info entries are out of order. Fixed.');
    --[retracted]             ++$$et{CHANGED};
    --[retracted]         } else {
    --[retracted]             $et->Warn('Error sorting item info entries');
    --[retracted]         }
    --[retracted]     } else {
    --[retracted]         $et->Warn('Item info entries are out of order');
    --[retracted]     }
    --[retracted]     delete $$et{ItemsNotSorted};
    --[retracted] }
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
-- Write a series of QuickTime atoms from file or in memory
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: A) if dirInfo contains DataPt: new directory data
--          B) otherwise: true on success, 0 if a write error occurred
--             (true but sets an Error on a file format error)
-- Notes: Yes, this is a real mess.  Just like the QuickTime metadata situation.
-- (port: the mdat, mdatEdit, ChunkOffset and trailer lists keep upstream's
--  member order in 1-based Lua arrays -- upstream $$mdat[0..5] are mdat[1..6]
--  here; the "new data" member holds the data itself, not a reference to it)
--------------------------------------------------------------------------------
function WriteQuickTime.WriteQuickTime(et, dirInfo, tagTablePtr)
    if not et then return 1 end   -- allow dummy access to autoload this package
    local Writer = require('lexiftool.Writer')
    -- (upstream @mdat is mdatList here, next to the loop variable $mdat)
    local mdat
    local mdatList, mdatEdit, edit, track, outBuff, co, term, delCount = { }, { }
    local langTags, canCreate, delGrp, boxPos, didDir, writeLast, err, atomCount = { }, nil, nil, { }, { }
    local tag, lastTag, lastPos, errStr, trailer, buf2, keysGrp, keysPath, itemIndex
    local outfile = dirInfo.OutFile
    if not outfile then return 0 end
    local raf = dirInfo.RAF         -- (will be null for lower-level atoms)
    local dataPt = dirInfo.DataPt   -- (will be null for top-level atoms)
    local dirName = dirInfo.DirName
    local dirStart = dirInfo.DirStart or 0
    local parent = dirInfo.Parent
    local addDirs = et.ADD_DIRS or { }
    if not et.DidTag then et.DidTag = { } end
    local didTag = et.DidTag
    local newTags = { }
    local createKeys = 0
    -- (`$dataPt ? (undef, undef) : (1, 0)`)
    local rtnVal, rtnErr
    if not dataPt then rtnVal, rtnErr = 1, 0 end

    -- check for trailer at end of file
    if raf then
        trailer = QuickTime.IdentifyTrailers(raf)
        if trailer and type(trailer) ~= 'table' then et:Error(trailer) return 1 end
    end
    if dataPt then
        raf = RandomAccess.new(dataPt)
    else
        if not raf then return 0 end
    end
    -- use buffered output for everything but 'mdat' atoms
    -- (upstream `$outBuff = ''; $outfile = \$outBuff`: `outBuff` is that
    --  scalar reference, the box { value = <carray> } of doc/api.md §4)
    outBuff = { value = carray.new('char') }
    outfile = outBuff

    if dirStart ~= 0 then raf:Seek(dirStart, 1) end  -- skip header if it exists

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
        if dir == nil then break end
        writePath = dir .. '-' .. writePath
    end
    -- hack to create Keys directories if necessary (its containing Meta is in a different location)
    if (addDirs.Keys and isMatch(curPath, [[^MOV-Movie(-Meta)?$]])) then
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
            local index
            local keysInfo = { }
            for i in pairs(keys.Info) do
                if perlTruthy(keys.Remap[i]) then keysInfo[keys.Info[i]] = i end
            end
            local keysTable = et:GetTagTable('lexiftool.QuickTime.' .. keysGrp)
            local newKeysTags = Writer.GetNewTagInfoHash(et, keysTable)
            for k in pairs(newKeysTags) do
                local tagInfo = newKeysTags[k]
                index = keysInfo[tagInfo] or (tagInfo.SrcTagInfo and keysInfo[tagInfo.SrcTagInfo])
                if index then
                    local id = ExifTool.Put32u(index)
                    if tagInfo.LangCode then
                        -- add to lookup of language tags we are writing with this ID
                        if not langTags[id] then langTags[id] = { } end
                        langTags[id][k] = tagInfo
                        id = id .. '-' .. tagInfo.LangCode
                    end
                    newTags[id] = tagInfo
                end
            end
        end
    else
        -- get hash of new tags to edit/create in this directory
        newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
        -- make lookup of language tags for each ID
        for k in pairs(newTags) do
            if newTags[k].LangCode and newTags[k].SrcTagInfo then
                local id = newTags[k].SrcTagInfo.TagID
                if not langTags[id] then langTags[id] = { } end
                langTags[id][k] = newTags[k]
            end
        end
    end
    if curPath == writePath or createKeys ~= 0 then
        canCreate = 1
        -- (must check the appropriate Keys delete flag if this is a Keys ItemList)
        delGrp = Writer.IsGroupDeleted(et, createKeys ~= 0 and keysGrp or dirName)
    end
    if tagTablePtr.VARS then atomCount = tagTablePtr.VARS.ATOM_COUNT end

    tag, lastTag = '', ''
    if dirName == 'ItemPropertyContainer' then itemIndex = 0 end

    -- read ahead to parse item property associations if this is 'iprp' ItemProperties
    -- (necessary to determine which properties belong to primary item in HEIC file)
    if dirName == 'ItemProperties' then
        local pos = raf:Tell()
        while true do
            local n
            n, buf2 = raf:Read(8)
            if n ~= 8 then break end
            local size = Get32u(buf2, 0) - 8    -- (atom size without 8-byte header)
            tag = substr(buf2, 4, 4)
            if size < 0 then break end
            if tag ~= 'ipma' then raf:Seek(size, 1) goto nextIprp end
            n, buf2 = raf:Read(size)
            if n == size then QuickTime.ParseItemPropAssoc(buf2, et) end
            break
            ::nextIprp::
        end
        raf:Seek(pos)
    end
    while true do   -- loop through all atoms at this level
        if itemIndex ~= nil then itemIndex = itemIndex + 1 end
        lastPos = raf:Tell()
        -- stop processing if we reached a known trailer
        if trailer and lastPos >= trailer[2] then
            if lastPos ~= trailer[2] then errStr = 'Corrupted ' .. trailer[1] .. ' trailer' end
            break
        end
        if tagTablePtr[tag] then lastTag = tag end    -- keep track of last known tag
        if atomCount ~= nil then atomCount = atomCount - 1 end
        if atomCount ~= nil and atomCount < 0 and dataPt then
            -- stop processing now and just copy the rest of the atom
            if not Write(outfile, substr(dataPt, raf:Tell())) then rtnVal = rtnErr err = 1 end
            break
        end
        local hdr, buff, keysIndex
        local n
        n, hdr = raf:Read(8)
        if n ~= 8 then
            if n == 4 and hdr == '\0\0\0\0' then
                -- "for historical reasons" the udta is optionally terminated by 4 zeros (ref 1)
                -- --> hold this terminator to the end
                term = hdr
            elseif n ~= 0 then
                -- warn unless this is 1-3 pad bytes
                if n > 3 or hdr ~= string.rep('\0', n) then et:Error('Unknown ' .. n .. ' bytes at end of file', 1) end
            end
            break
        end
        local size = Get32u(hdr, 0) - 8    -- (atom size without 8-byte header)
        tag = substr(hdr, 4, 4)
        if size == -7 then
            -- read the extended size
            n, buff = raf:Read(8)
            if n ~= 8 then errStr = 'Truncated extended atom' break end
            hdr = hdr .. buff
            local hi, lo = unpack('NN', buff)
            if hi ~= 0 or lo > 0x7fffffff then
                if hi > 0x7fffffff then
                    errStr = 'Invalid atom size'
                    break
                elseif not perlTruthy(et:Options('LargeFileSupport')) then
                    et:Error('End of processing at large atom (LargeFileSupport not enabled)')
                    break
                elseif perlStr(et:Options('LargeFileSupport')) == '2' then
                    et:Warn('Processing large atom (LargeFileSupport is 2)')
                end
            end
            size = hi * 4294967296 + lo - 16
            if size < 0 then errStr = 'Invalid extended atom size' break end
        elseif size == -8 then
            if dataPt then
                if dirInfo.DirName == 'CanonCNTH' then break end  -- (this is normal for Canon CNTH atom)
                local pos = raf:Tell() - 4
                raf:Seek(0, 2)
                local str = perlStr(dirInfo.DirName) .. ' with ' .. (raf:Tell() - pos) .. ' bytes'
                et:Error('Terminator found in ' .. str .. ' remaining', 1)
            else
                -- size of zero is only valid for top-level atom, and
                -- indicates the atom extends to the end of file
                -- (save in mdat list to write later; with zero end position to copy rest of file)
                mdatList[#mdatList + 1] = { raf:Tell(), 0, hdr }
            end
            break
        elseif size < 0 then
            errStr = 'Invalid atom size'
            break
        end

        -- keep track of 'mdat' atom locations for writing later
        if tag == 'mdat' then
            if dataPt then
                et:Error("'mdat' not at top level")
                break
            end
            mdatList[#mdatList + 1] = { raf:Tell(), raf:Tell() + size, hdr }
            if not raf:Seek(size, 1) then et:Error('Seek error in mdat atom') return rtnVal end
            goto nextAtom
        elseif tag == 'cmov' then
            et:Error("Can't yet write compressed movie metadata")
            return rtnVal
        elseif tag == 'wide' then
            if size ~= 0 then
                et:Warn("Incorrect size for 'wide' atom (" .. size .. ' bytes)')
                if not raf:Seek(size, 1) then et:Error('Truncated wide atom') end
            end
            goto nextAtom   -- drop 'wide' tag
        end

        -- read the atom data
        do
        local got
        if size == 0 then
            buff = ''
            got = 0
        else
            -- read the atom data (but only first 64kB if data is huge)
            got, buff = raf:Read(size > maxReadLen and 0x10000 or size)
        end
        if got ~= size then
            -- ignore up to 256 bytes of garbage at end of file
            local type_
            local garbage = got <= 256 and size >= 1024 and tag ~= 'mdat'
            if not garbage and got < 3000 and isMatch(perl.pack('N', size), [=[^<b[r>]]=]) then
                type_ = 'extraneous HTML'
                garbage = true
            end
            if garbage then
                local bytes = got + length(hdr)
                if not type_ then type_ = 'garbage' end
                if perlTruthy(et.OPTIONS.IgnoreMinorErrors) then
                    et:Warn('Deleted ' .. type_ .. ' at end of file (' .. bytes .. ' bytes)')
                    buff, hdr = '', ''
                else
                    et:Error('Possible ' .. type_ .. ' at end of file (' .. bytes .. ' bytes)', 1)
                    return rtnVal
                end
            else
                tag = QuickTime.PrintableTagID(tag, 3)
                if size > maxReadLen and got == 0x10000 then
                    local mb = math.floor(size / 0x100000 + 0.5)
                    errStr = "'" .. tag .. "' atom is too large for rewriting (" .. mb .. ' MB)'
                else
                    errStr = "Truncated '" .. tag .. "' atom"
                end
                break
            end
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
        if isMatch(tag, [[^(stco|co64|iloc|mfra|moof|sidx|saio|gps |CTBO|uuid)$]]) then
            -- (note that we only need to do this if the media data is stored in this file)
            local flg = et.QtDataFlg
            if tag == 'mfra' or tag == 'moof' then
                et:Error("Can't yet handle movie fragments when writing")
                return rtnVal
            elseif tag == 'sidx' or tag == 'saio' then
                et:Error("Can't yet handle " .. tag .. ' box when writing')
                return rtnVal
            elseif tag == 'iloc' then
                if not Handle_iloc(et, dirInfo, buff, outfile) then et:Error('Error parsing iloc atom') end
            elseif tag == 'gps ' then
                -- (only care about the 'gps ' box in 'moov')
                if dirInfo.DirID and dirInfo.DirID == 'moov' and length(buff) > 8 then
                    local off = dirInfo.ChunkOffset
                    local num = Get32u(buff, 4)
                    if num * 8 + 8 > length(buff) then num = (length(buff) - 8) // 8 end
                    for i = 0, num - 1 do
                        off[#off + 1] = { 'stco_gps ', length(outfile.value) + length(hdr) + 8 + i * 8, 4 }
                    end
                end
            elseif tag == 'CTBO' or tag == 'uuid' then -- hack for updating CR3 CTBO offsets
                dirInfo.ChunkOffset[#dirInfo.ChunkOffset + 1] = { tag, length(outfile.value), length(hdr) + size }
            elseif not perlTruthy(flg) or flg == 1 then
                -- assume "1" if stsd is yet to be read
                if not perlTruthy(flg) then et.AssumedDataRef = 1 end
                -- must update offsets since the data is in this file
                dirInfo.ChunkOffset[#dirInfo.ChunkOffset + 1] = { tag, length(outfile.value) + length(hdr), size }
            elseif flg == 3 then
                et:Error("Can't write files with mixed internal/external media data")
                return rtnVal
            end
        end

        -- rewrite this atom
        do
        local tagInfo = et:GetTagInfo(tagTablePtr, tag, buff)

        -- call write hook if it exists
        if tagInfo and tagInfo.WriteHook then tagInfo.WriteHook(buff, et) end

        -- allow numerical tag ID's (ItemList entries defined by Keys)
        if not tagInfo and dirName == 'ItemList' and et[keysGrp] then
            keysIndex = unpack('N', tag)
            local newIndex = et[keysGrp].Remap[keysIndex]
            if newIndex ~= nil then
                tagInfo = et[keysGrp].Info[keysIndex]
                if not perlTruthy(newIndex) then
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
                    -- (`substr($hdr, 4, 4) = $tag` on a string)
                    hdr = substr(hdr, 0, 4) .. tag .. substr(hdr, 8)
                end
            else
                keysIndex = nil -- luacheck: ignore 311
            end
        end
        -- delete all ItemList tags when deleting group, but take care not to delete UserData Meta
        if delGrp then
            if dirName == 'ItemList' then
                delCount = (delCount or 0) + 1
                et.CHANGED = (et.CHANGED or 0) + 1
                goto nextAtom
            elseif dirName == 'UserData' and (not tagInfo or not tagInfo.SubDirectory) then
                delCount = (delCount or 0) + 1
                et.CHANGED = (et.CHANGED or 0) + 1
                goto nextAtom
            end
        end
        if tagInfo and tagInfo.AddedUnknown then tagInfo = nil end

        -- don't write this tag unless associated with the primary item
        -- (Note: This relies on iinf and dimg coming before iprp)
        if itemIndex ~= nil and et.ItemInfo then
            local items = et.ItemInfo
            local isPrimary
            local primary = et.PrimaryItem
            if primary == nil then
                if et.ItemInfo then
                    local ids = { }
                    for id in pairs(et.ItemInfo) do ids[#ids + 1] = id end
                    tsort(ids)
                    primary = ids[1]
                end
                if primary == nil then primary = 0 end
            end
            local pitem = items[primary] or { }
            if not pitem.RefersTo then pitem.RefersTo = { } end
            local ids = { }
            for id in pairs(items) do ids[#ids + 1] = id end
            tsort(ids, function(a, b) return a > b end)    -- (reverse sort { $a <=> $b })
            for _, id in ipairs(ids) do
                if not items[id].Association then goto nextID end
                do
                    local item = items[id]
                    for _, prop in ipairs(item.Association) do
                        if prop == itemIndex then
                            local dont = QuickTime.dontInherit[tag] or 0
                            if not (id == primary or (dont == 0 and
                                (item.RefersTo and item.RefersTo[primary])) or
                                -- special case to assume this property belongs to the primary
                                -- image if it belongs to an item referred to by the primary
                                (dont ~= 1 and pitem.RefersTo[id])) then break end
                            isPrimary = 1
                            goto lastItemID2
                        end
                    end
                end
                ::nextID::
            end
            ::lastItemID2::
            if not isPrimary then tagInfo = nil end
        end

        if tagInfo and (tagInfo.Writable == nil or perlTruthy(tagInfo.Writable)) then
            local subdir = tagInfo.SubDirectory
            local newData
            local chunkOffset = { }

            if subdir then  -- process atoms in this container from a buffer in memory

                if tag == 'trak' then
                    et.MediaType = ''  -- init media type for this track
                    et.AssumedDataRef = nil
                end
                local subName = subdir.DirName or tagInfo.Name
                local start = subdir.Start or 0
                local base = (dirInfo.Base or 0) + raf:Tell() - size
                local dPos = 0
                local hdrLen = start
                -- handle case where known trailer is the payload of a "DontRead" box (eg. 'inst')
                if tagInfo.DontRead and trailer and base == trailer[2] then trailer = trailer[4] end
                if subdir.Base then
                    local localBase = subdir.Base(et, buff, start)
                    dPos = dPos - localBase
                    base = base - dPos
                    -- get length of header before base offset
                    if localBase <= hdrLen then hdrLen = hdrLen - localBase end
                end
                local subdirInfo = {
                    Parent   = dirName,
                    DirName  = subName,
                    Name     = tagInfo.Name,
                    TagInfo  = tagInfo,
                    DirID    = tag,
                    DataPt   = buff,
                    DataLen  = size,
                    DataPos  = dPos,
                    DirStart = start,
                    DirLen   = size - start,
                    Base     = base,
                    HasData  = subdir.HasData,
                    Multi    = subdir.Multi,    -- necessary?
                    OutFile  = outfile,
                    NoRefTest= 1,     -- don't check directory references
                    WriteGroup = tagInfo.WriteGroup,
                    Permanent = tagInfo.Permanent,
                    -- initialize array to hold details about chunk offset table
                    -- (each entry has 3-5 items: 0=atom type, 1=table offset, 2=table size,
                    --  3=optional base offset, 4=optional item ID)
                    ChunkOffset = chunkOffset,
                }
                -- set InPlace flag so XMP will be padded properly when
                -- QuickTimePad is used if this is an XMP directory
                if perlTruthy(et:Options('QuickTimePad')) then subdirInfo.InPlace = 2 end
                -- pass the header pointer if necessary (for EXIF IFD's
                -- where the Base offset is at the end of the header)
                if hdrLen ~= 0 and hdrLen < size then
                    local header = carray.new('char'):append(substr(buff, 0, hdrLen))
                    subdirInfo.HeaderPtr = header
                end
                if subdir.ByteOrder and isMatch(subdir.ByteOrder, [[^Little]]) then ExifTool.SetByteOrder('II') end
                local oldWriteGroup = et.CUR_WRITE_GROUP
                if subName == 'Track' then
                    if not track then track = 0 end
                    track = track + 1
                    et.CUR_WRITE_GROUP = 'Track' .. track
                end
                local subTable = et:GetTagTable(subdir.TagTable)
                -- demote non-QuickTime errors to warnings
                if subTable.GROUPS[0] ~= 'QuickTime' then et.DemoteErrors = 1 end
                local oldChanged = et.CHANGED
                newData = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                if et.DemoteErrors then
                    -- just copy existing subdirectory if a non-quicktime error occurred
                    if et.DemoteErrors > 1 then et.CHANGED = oldChanged end
                    et.DemoteErrors = nil
                end
                if newData ~= nil and length(newData) == 0 and (tagInfo.Permanent or
                    (tagTablePtr.PERMANENT and tagInfo.Permanent == nil))
                then
                    -- do nothing if trying to delete tag from a PERMANENT table
                    et.CHANGED = oldChanged
                    newData = nil
                end
                if tag == 'trak' then
                    et.MediaType = ''     -- reset media type at end of track
                    if et.AssumedDataRef then
                        local grp = et.CUR_WRITE_GROUP or dirName
                        et:Error("Can't locate data reference to update offsets for " .. grp)
                        et.AssumedDataRef = nil
                    end
                end
                et.CUR_WRITE_GROUP = oldWriteGroup
                ExifTool.SetByteOrder('MM')
                -- add back header if necessary
                if start ~= 0 and newData ~= nil and (length(newData) > 0 or
                    (tagInfo.Permanent ~= nil and not perlTruthy(tagInfo.Permanent)))
                then
                    newData = substr(buff, 0, start) .. newData
                    for _, c in ipairs(chunkOffset) do c[2] = c[2] + start end
                end
                -- the directory exists, so we don't need to add it
                if curPath == writePath and addDirs[subName] and addDirs[subName] == dirName then
                    addDirs[subName] = nil
                end
                didDir[tag] = 1 -- (note: keyed by tag ID)

            else    -- modify existing QuickTime tags in various formats

                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                if nvHash or langTags[tag] or delGrp then
                    local nvHashNoLang = nvHash
                    local val, len, lang, type_, flags, ctry, charsetQuickTime
                    local format = tagInfo.Format
                    local hasData = (dirInfo.HasData and isMatch(buff, [[(?s)\0...data\0]]))
                    local langInfo = tagInfo
                    if hasData then
                        local pos = 0
                        -- (newData is built in a carray here, a string again below)
                        while true do
                            if pos + 16 > size then
                                -- add any new alternate language tags now
                                if langTags[tag] then
                                    local tgs = { '' }
                                    local sorted = { }
                                    for t in pairs(langTags[tag]) do sorted[#sorted + 1] = t end
                                    tsort(sorted)
                                    for _, t in ipairs(sorted) do tgs[#tgs + 1] = t end
                                    for _, tg in ipairs(tgs) do
                                        local ti
                                        if tg ~= '' then ti = langTags[tag][tg] else ti = nvHashNoLang end
                                        -- (`GetNewValueHash($nvHashNoLang)`: the hash is
                                        --  passed where a tagInfo is expected)
                                        nvHash = Writer.GetNewValueHash(et, ti)
                                        if not (nvHash and not didTag[nvHash]) then goto nextTg end
                                        didTag[nvHash] = 1
                                        if not (perlTruthy(nvHash.IsCreating) and perlTruthy(Writer.IsOverwriting(et, nvHash))) then goto nextTg end
                                        do
                                            local newVal = et:GetNewValue(nvHash)
                                            if newVal == nil then goto nextTg end
                                            local prVal = newVal
                                            local flags2
                                            flags2, newVal = FormatQTValue(et, newVal, tagInfo, format)
                                            if newVal == nil then goto nextTg end
                                            local ctry2, lang2 = 0, 0
                                            if ti.LangCode then
                                                local ok, c1, c2 = isMatch(ti.LangCode, [[(?i)^([A-Z]{3})?[-_]?([A-Z]{2})?$]])
                                                if not ok then
                                                    et:Warn('Invalid language code for ' .. ti.Name)
                                                    goto nextTg
                                                end
                                                -- pack language and country codes
                                                if perlTruthy(c1) and c1 ~= 'und' then
                                                    for _, b in ipairs({ unpack('C*', lc(c1)) }) do lang2 = (lang2 << 5) | (b - 0x60) end
                                                end
                                                if perlTruthy(c2) and c2 ~= 'ZZ' then ctry2 = unpack('n', perl.pack('a2', uc(c2))) end
                                            end
                                            if newData == nil then newData = carray.new('char'):append(substr(buff, 0, pos)) end
                                            newData:append(perl.pack('Na4Nnn', 16 + length(newVal), 'data', flags2, ctry2, lang2) .. newVal)
                                            local grp = et:GetGroup(ti, 1)
                                            Writer.VerboseValue(et, '+ ' .. grp .. ':' .. ti.Name, prVal)
                                            et.CHANGED = (et.CHANGED or 0) + 1
                                        end
                                        ::nextTg::
                                    end
                                end
                                break
                            end
                            len, type_, flags, ctry, lang = unpack('x' .. pos .. 'Na4Nnn', buff)
                            if not perlTruthy(lang) then lang = undLang end  -- treat both 0 and 'und' as 'und'
                            langInfo = tagInfo -- luacheck: ignore 311
                            local delTag = delGrp
                            local newVal
                            local langCode = QuickTime.GetLangCode(lang, ctry, 1)
                            while true do
                                langInfo = WriteQuickTime.GetLangInfo(tagInfo, langCode)
                                nvHash = Writer.GetNewValueHash(et, langInfo)
                                if nvHash or not perlTruthy(ctry) or lang ~= undLang or length(langCode) == 2 then break end
                                -- check to see if tag was written with a 2-char country code only
                                langCode = lc(unpack('a2', perl.pack('n', ctry)))
                            end
                            -- set flag to delete language tag when writing default
                            -- (except for a default-language Keys entry)
                            if not nvHash and nvHashNoLang then
                                if lang == undLang and not perlTruthy(ctry) and not didTag[nvHashNoLang] then
                                    nvHash = nvHashNoLang    -- write existing default
                                else
                                    delTag = 1    -- delete tag
                                end
                            end
                            if pos + len > size then break end
                            if type_ == 'data' and len >= 16 then
                                pos = pos + 16
                                len = len - 16
                                val = substr(buff, pos, len)
                                -- decode value (see QuickTime.pm for an explanation)
                                if stringEncoding[flags] then
                                    val = et:Decode(val, stringEncoding[flags])
                                    if not tagInfo.Binary then val = subst(val, [[\0$]], '') end
                                    flags = 0x01  -- luacheck: ignore 311 (write all strings as UTF-8)
                                else
                                    if format then
                                        -- update flags for the format we are writing
                                        if tagInfo.Writable and qtFormat[tagInfo.Writable] then
                                            flags = qtFormat[tagInfo.Writable] -- luacheck: ignore 311
                                        elseif qtFormat[format] then
                                            flags = qtFormat[format] -- luacheck: ignore 311
                                        end
                                    else
                                        format = QuickTime.QuickTimeFormat(flags, len)
                                    end
                                    if format then val = ExifTool.ReadValue(val, 0, format, tagInfo.Count, len) end
                                end
                                if (nvHash and perlTruthy(Writer.IsOverwriting(et, nvHash, val))) or delTag then
                                    if nvHash ~= nil then newVal = et:GetNewValue(nvHash) end
                                    if delTag or newVal == nil or didTag[nvHash] then
                                        -- delete the tag
                                        local grp = et:GetGroup(langInfo, 1)
                                        Writer.VerboseValue(et, '- ' .. grp .. ':' .. perlStr((langInfo or { }).Name), val)
                                        -- copy data up to start of this tag to delete this value
                                        if newData == nil then newData = carray.new('char'):append(substr(buff, 0, pos - 16)) end
                                        et.CHANGED = (et.CHANGED or 0) + 1
                                        goto nextData
                                    end
                                    local prVal = newVal
                                    -- format new value for writing (and get new flags)
                                    flags, newVal = FormatQTValue(et, newVal, tagInfo, format)
                                    if newVal == nil then goto nextData end
                                    local grp = et:GetGroup(langInfo, 1)
                                    Writer.VerboseValue(et, '- ' .. grp .. ':' .. perlStr((langInfo or { }).Name), val)
                                    Writer.VerboseValue(et, '+ ' .. grp .. ':' .. perlStr((langInfo or { }).Name), prVal)
                                    if newData == nil then newData = carray.new('char'):append(substr(buff, 0, pos - 16)) end
                                    local wLang = lang == undLang and 0 or lang
                                    newData:append(perl.pack('Na4Nnn', length(newVal) + 16, type_, flags, ctry, wLang))
                                    newData:append(newVal)
                                    et.CHANGED = (et.CHANGED or 0) + 1
                                elseif newData ~= nil then
                                    newData:append(substr(buff, pos - 16, len + 16))
                                end
                            elseif newData ~= nil then
                                newData:append(substr(buff, pos, len))
                            end
                            if nvHash then didTag[nvHash] = 1 end
                            ::nextData::
                            pos = pos + len
                        end
                        if newData ~= nil and pos < size then newData:append(substr(buff, pos)) end
                        if newData ~= nil then newData = newData:tostring() end
                        val = nil   -- (already constructed $newData)
                    elseif format then
                        val = ExifTool.ReadValue(buff, 0, format, nil, size)
                    elseif (isMatch(tag, [[^\xa9]]) or tagInfo.IText) and size >= (tagInfo.IText or 4) then
                        local hdr2
                        if tagInfo.IText and tagInfo.IText >= 6 then
                            local iText = tagInfo.IText
                            local pos = iText - 2
                            lang = unpack('x' .. pos .. 'n', buff)
                            hdr2 = substr(buff, 4, iText - 6)
                            len = size - iText
                            val = substr(buff, iText, len)
                        else
                            len, lang = unpack('nn', buff)
                            if 4 + len > size then len = len - 4 end -- (see QuickTime.pm for explanation)
                            if len > size - 4 or len < 0 then len = size - 4 end
                            val = substr(buff, 4, len)
                        end
                        if not perlTruthy(lang) then lang = undLang end  -- treat both 0 and 'und' as 'und'
                        local enc
                        if lang < 0x400 and not isMatch(val, [[^\xfe\xff]]) then
                            charsetQuickTime = et:Options('CharsetQuickTime')
                            enc = charsetQuickTime
                        else
                            local bom = isMatch(val, [[^\xfe\xff]])
                            if bom then val = subst(val, [[^\xfe\xff]], '') end
                            enc = bom and 'UTF16' or 'UTF8'
                        end
                        if not tagInfo.NoDecode then
                            val = et:Decode(val, enc)
                            val = subst(val, [[\0+$]], '')   -- remove trailing nulls if they exist
                        end
                        if hdr2 ~= nil then val = hdr2 .. val end
                        local langCode = QuickTime.UnpackLang(lang, 1)
                        langInfo = WriteQuickTime.GetLangInfo(tagInfo, langCode)
                        nvHash = Writer.GetNewValueHash(et, langInfo)
                        if not nvHash and nvHashNoLang then
                            if lang == undLang and not didTag[nvHashNoLang] then
                                nvHash = nvHashNoLang
                            elseif canCreate then
                                -- delete other languages when writing default
                                local grp = et:GetGroup(langInfo, 1)
                                Writer.VerboseValue(et, '- ' .. grp .. ':' .. perlStr((langInfo or { }).Name), val)
                                et.CHANGED = (et.CHANGED or 0) + 1
                                goto nextAtom
                            end
                        end
                    else
                        val = buff
                        if isMatch(tag, [[^\xa9]]) or tagInfo.IText then
                            et:Warn('Corrupted ' .. tagInfo.Name .. ' value')
                        end
                    end
                    if nvHash and val ~= nil then
                        if perlTruthy(Writer.IsOverwriting(et, nvHash, val)) then
                            newData = et:GetNewValue(nvHash)
                            if not (newData ~= nil or canCreate) then newData = '' end
                            et.CHANGED = (et.CHANGED or 0) + 1
                            local grp = et:GetGroup(langInfo, 1)
                            Writer.VerboseValue(et, '- ' .. grp .. ':' .. perlStr((langInfo or { }).Name), val)
                            if not (newData ~= nil and not didTag[nvHash]) then
                                -- must not delete items from iprp because it will mess up the ordering
                                if itemIndex == nil then goto nextAtom end
                            end
                            Writer.VerboseValue(et, '+ ' .. grp .. ':' .. perlStr((langInfo or { }).Name), newData)
                            -- add back necessary header and encode as necessary
                            if lang ~= nil then
                                local iText = tagInfo.IText or 0
                                local hdr2
                                if iText > 6 then
                                    if length(newData) < iText - 6 then newData = newData .. string.rep(' ', iText - 6) end
                                    hdr2 = substr(newData, 0, iText - 6)
                                    newData = substr(newData, iText - 6)
                                end
                                if not tagInfo.NoDecode then
                                    -- (if/else: charsetQuickTime may be undef)
                                    local encTo = 'UTF8'
                                    if lang < 0x400 then encTo = charsetQuickTime end
                                    newData = et:Encode(newData, encTo)
                                end
                                local wLang = lang == undLang and 0 or lang
                                if iText < 6 then
                                    newData = perl.pack('nn', length(newData), wLang) .. newData
                                elseif iText == 6 then
                                    newData = perl.pack('Nn', 0, wLang) .. newData .. '\0'
                                else
                                    newData = '\0\0\0\0' .. hdr2 .. perl.pack('n', wLang) .. newData .. '\0'
                                end
                            elseif not format or isMatch(format, [[^string]]) and
                                     not tagInfo.Binary and not tagInfo.ValueConv
                            then
                                -- write all strings as UTF-8
                                newData = et:Encode(newData, 'UTF8')
                            elseif format and not tagInfo.Binary then
                                -- format new value for writing
                                newData = Writer.WriteValue(newData, format, tagInfo.Count)
                            end
                        end
                        didTag[nvHash] = 1   -- set flag so we don't add this tag again
                    end
                end
            end
            -- write the new atom if it was modified
            if newData ~= nil then
                local sizeDiff = length(buff) - length(newData)
                -- pad to original size if specified, otherwise give verbose message about the changed size
                if sizeDiff > 0 and tagInfo.PreservePadding and perlTruthy(et:Options('QuickTimePad')) then
                    newData = newData .. string.rep('\0', sizeDiff)
                    et:VPrint(1, '    (' .. tagInfo.Name .. ' padded to original size)')
                elseif sizeDiff ~= 0 then
                    et:VPrint(1, '    (' .. tagInfo.Name .. ' changed size)')
                end
                local len = length(newData) + 8
                if len > 0x7fffffff then et:Error(tagInfo.Name .. ' to large to write') break end
                -- update size in ChunkOffset list for modified 'uuid' atom
                if tag == 'uuid' then dirInfo.ChunkOffset[#dirInfo.ChunkOffset][3] = len end
                if len <= 8 then goto nextAtom end   -- don't write empty atom header
                -- maintain pointer to chunk offsets if necessary
                if #chunkOffset > 0 then
                    for _, c in ipairs(chunkOffset) do c[2] = c[2] + 8 + length(outfile.value) end
                    for _, c in ipairs(chunkOffset) do dirInfo.ChunkOffset[#dirInfo.ChunkOffset + 1] = c end
                end
                if tagInfo.WriteLast then
                    writeLast = (writeLast or '') .. ExifTool.Put32u(len) .. tag .. newData
                else
                    boxPos[tag] = { length(outfile.value), length(newData) + 8 }
                    -- write the updated directory with its atom header
                    if not Write(outfile, ExifTool.Put32u(len), tag, newData) then rtnVal = rtnErr err = 1 break end
                end
                goto nextAtom
            end
        end
        -- keep track of data references in this track
        if tag == 'dinf' then
            et.QtDataRef = { }  -- initialize list of data references
        elseif parent == 'DataInfo' and length(buff) >= 4 then
            -- save data reference type and version/flags
            if not et.QtDataRef then et.QtDataRef = { } end
            et.QtDataRef[#et.QtDataRef + 1] = { tag, Get32u(buff, 0) }
        elseif tag == 'stsd' and length(buff) >= 8 then
            local num = Get32u(buff, 4)      -- get number of sample descriptions in table
            local pos, flg = 8, 0
            local msg
            for i = 0, num - 1 do       -- loop through sample descriptions
                if pos + 16 > length(buff) then msg = 'Truncated sample table' break end
                local siz = Get32u(buff, pos)
                if pos + siz > length(buff) then msg = 'Truncated sample table' break end
                local drefIdx = Get16u(buff, pos + 14)
                local drefTbl = et.QtDataRef
                if drefIdx == 0 then
                    flg = flg | 0x01   -- in this file if data reference index is 0 (if like iloc)
                elseif drefTbl and drefTbl[drefIdx] then
                    local dref = drefTbl[drefIdx]
                    -- $flg = 0x01-in this file, 0x02-in some other file
                    flg = flg | ((dref[2] == 1 and dref[1] ~= 'rsrc') and 0x01 or 0x02)
                else
                    msg = 'No data reference for sample description ' .. i
                    break
                end
                pos = pos + siz
            end
            if msg then
                -- (allow empty sample description for non-audio/video handler types, eg. 'url ', 'meta')
                -- (also, incorrectly written 'mett' SampleEntry by Google phones,
                --  see https://exiftool.org/forum/index.php?msg=91158)
                if avType[et.MediaType] then
                    local grp = et.CUR_WRITE_GROUP or parent
                    et:Error(msg .. ' for ' .. grp)
                    return rtnErr
                end
                flg = 1 -- (this seems to be the case)
            end
            et.QtDataFlg = flg
            if et.AssumedDataRef then
                if flg ~= et.AssumedDataRef then
                    local grp = et.CUR_WRITE_GROUP or parent
                    et:Error('Assumed incorrect data reference for ' .. grp .. ' (was ' .. flg .. ')')
                end
                et.AssumedDataRef = nil
            end
        end
        if tagInfo and tagInfo.WriteLast then
            writeLast = (writeLast or '') .. hdr .. buff
        else
            -- save position of this box in the output buffer
--TODO do this:
--TODO            my $bp = $boxPos{$tag} || ($boxPos{$tag} = [ ]);
--TODO            push @$bp, length($$outfile), length($hdr) + length($buff);
--TODO instead of this:
            boxPos[tag] = { length(outfile.value), length(hdr) + length(buff) }
--TODO then we have the positions of all the infe boxes -- we then only need
--TODO to know the index of the box to edit if the encoding changes for one of them
            -- copy the existing atom
            if not Write(outfile, hdr, buff) then rtnVal = rtnErr err = 1 break end
        end
        end
        ::nextAtom::
    end
    -- ($errStr is set if there was an error that could possibly be due to an unknown trailer)
    if errStr then
        if (lastTag == 'mdat' or lastTag == 'moov') and not dataPt and (not tagTablePtr[tag] or
            type(tagTablePtr[tag]) == 'table' and tagTablePtr[tag][1] == nil and tagTablePtr[tag].Unknown)
        then
            -- identify other known trailers from their first bytes
            buf2 = ''
            if raf:Seek(lastPos, 0) then
                local _
                _, buf2 = raf:Read(8)
            end
            local type_, len
            if buf2 == 'CCCCCCCC' then
                type_ = 'Kenwood'
            elseif isMatch(buf2, [[(?s)^(gpsa|gps0|gsen|gsea)...\0]]) then
                type_ = 'RIFF'
            else
                type_ = 'Unknown'
            end
            -- determine length of this trailer
            if trailer then
                len = trailer[2] - lastPos -- runs to start of next trailer
            else
                if not raf:Seek(0, 2) then
                    et:Error('Seek error')
                    if dataPt then return nil end
                    return 1
                end
                len = raf:Tell() - lastPos -- runs to end of file
            end
            -- add to start of linked list of trailers
            trailer = { type_, lastPos, len, trailer }
        else
            et:Error(errStr)
            if dataPt then return nil end
            return 1
        end
    end
    if delCount then
        et:VPrint(0, '  [deleting ' .. delCount .. ' ' .. dirName .. ' tag' .. (delCount == 1 and '' or 's') .. ']\n')
    end

    -- can finally set necessary variables for creating Video/AudioKeys tags
    if createKeys < 0 then
        if avType[et.MediaType] then
            createKeys = 1
            keysGrp, keysPath = avType[et.MediaType] .. 'Keys', 'MOV-Movie-Track'
        else
            canCreate = 0
        end
    end
    if not addDirs[keysGrp] then createKeys = createKeys & ~0x01 end  -- (Keys may have been written)

    -- add new directories/tags at this level if necessary
    if perlTruthy(canCreate) and ((et.EDIT_DIRS and et.EDIT_DIRS[dirName] ~= nil) or createKeys ~= 0) then
        -- get a hash of tagInfo references to add to this directory
        local dirs = Writer.GetAddDirHash(et, tagTablePtr, dirName)
        -- make sorted list of new tags to be added
        local addTags = { }
        for k in pairs(dirs) do addTags[#addTags + 1] = k end
        for k in pairs(newTags) do addTags[#addTags + 1] = k end
        tsort(addTags)
        local tag, index -- luacheck: ignore 421
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
                for i in pairs(et[keysGrp].Add) do indices[#indices + 1] = i end
                tsort(indices)
                for _, i in ipairs(indices) do
                    index = i
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
        -- (note that $tag may be a binary Keys index here)
        for _, t in ipairs(addTags) do
            tag = t
            local tagInfo = dirs[tag] or newTags[tag]
            -- (upstream `ref $tagInfo eq 'HASH'`: a list of conditional
            --  tagInfos, as Meta's 'keys', is an array ref)
            if not (type(tagInfo) == 'table' and tagInfo[1] == nil) then -- (shouldn't happen, but somehow there is forum17260)
                -- (also can happen if Meta exists but Keys does not since 'keys' is an array ref.
                --  SonyPMW-EX1R.mp4 has a Movie-Meta atom with XML and no Keys that triggers this
                --  issue.  Note that in this case the Meta HandlerType is 'meta' instead of 'mdta',
                --  which isn't a problem for ExifTool, but may be for other software?)
                if not (type(tagInfo) == 'table' and tagInfo[1] ~= nil) then goto nextAdd end
                tagInfo = et:GetTagInfo(tagTablePtr, tag)
                if not tagInfo then goto nextAdd end
            end
            if tagInfo.CanCreate ~= nil and not perlTruthy(tagInfo.CanCreate) then goto nextAdd end
            if tagInfo.MediaType ~= nil and et.MediaType ~= tagInfo.MediaType then goto nextAdd end
            do
            local subdir = tagInfo.SubDirectory
            if not subdir then
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                if not (nvHash and not didTag[nvHash]) then goto nextAdd end
                if not (perlTruthy(nvHash.IsCreating) and perlTruthy(Writer.IsOverwriting(et, nvHash))) then goto nextAdd end
                local newVal = et:GetNewValue(nvHash)
                if newVal == nil then goto nextAdd end
                local prVal = newVal
                local flags
                flags, newVal = FormatQTValue(et, newVal, tagInfo)
                if newVal == nil then goto nextAdd end
                local ctry, lang = 0, 0
                -- handle alternate languages
                if tagInfo.LangCode then
                    tag = substr(tag, 0, 4)  -- strip language code from tag ID
                    local ok, c1, c2 = isMatch(tagInfo.LangCode, [[(?i)^([A-Z]{3})?[-_]?([A-Z]{2})?$]])
                    if not ok then
                        et:Warn('Invalid language code for ' .. tagInfo.Name)
                        goto nextAdd
                    end
                    -- pack language and country codes
                    if perlTruthy(c1) and c1 ~= 'und' then
                        for _, b in ipairs({ unpack('C*', lc(c1)) }) do lang = (lang << 5) | (b - 0x60) end
                    end
                    if perlTruthy(c2) and c2 ~= 'ZZ' then ctry = unpack('n', perl.pack('a2', uc(c2))) end
                end
                if dirInfo.HasData then
                    -- add 'data' header
                    newVal = perl.pack('Na4Nnn', 16 + length(newVal), 'data', flags, ctry, lang) .. newVal
                elseif isMatch(tag, [[^\xa9]]) or tagInfo.IText then
                    if ctry ~= 0 then
                        local grp = et:GetGroup(tagInfo, 1)
                        et:Warn("Can't use country code for " .. grp .. ':' .. tagInfo.Name)
                        goto nextAdd
                    elseif tagInfo.IText and tagInfo.IText >= 6 then
                        -- add 6-byte langText header and trailing null
                        -- (with extra junk before language code if IText > 6)
                        local n = tagInfo.IText - 6
                        if length(newVal) < n then newVal = newVal .. string.rep(' ', n) end
                        -- (`pack('n',0,$lang)` packs only the first value: one
                        --  'n' template, two arguments -- so the language code
                        --  never makes it into the box)
                        newVal = '\0\0\0\0' .. substr(newVal, 0, n) .. perl.pack('n', 0, lang) .. substr(newVal, n) .. '\0'
                    else
                        -- add IText header
                        newVal = perl.pack('nn', length(newVal), lang) .. newVal
                    end
                elseif ctry ~= 0 or lang ~= 0 then
                    local grp = et:GetGroup(tagInfo, 1)
                    et:Warn("Can't use language code for " .. grp .. ':' .. tagInfo.Name)
                    goto nextAdd
                end
                if tagInfo.WriteLast then
                    writeLast = (writeLast or '') ..  ExifTool.Put32u(8 + length(newVal)) .. tag .. newVal
                else
                    boxPos[tag] = { length(outfile.value), 8 + length(newVal) }
                    if not Write(outfile, ExifTool.Put32u(8 + length(newVal)), tag, newVal) then rtnVal = rtnErr err = 1 end
                end
                local grp = et:GetGroup(tagInfo, 1)
                Writer.VerboseValue(et, '+ ' .. grp .. ':' .. tagInfo.Name, prVal)
                didTag[nvHash] = 1
                et.CHANGED = (et.CHANGED or 0) + 1
                goto nextAdd
            end
            local subName = subdir.DirName or tagInfo.Name
            -- QuickTime hierarchy is complex, so check full directory path before adding
            if createKeys ~= 0 and curPath == keysPath and subName == 'Meta' then
                et:VPrint(0, '  Creating Meta with mdta Handler and Keys\n')
                -- init Meta box for Keys tags with mdta Handler and empty Keys+ItemList
                buf2 = '\0\0\0\x20hdlr\0\0\0\0\0\0\0\0mdta\0\0\0\0\0\0\0\0\0\0\0\0' ..
                        '\0\0\0\x10keys\0\0\0\0\0\0\0\0' ..
                        '\0\0\0\x08ilst'
            elseif createKeys ~= 0 and curPath == keysPath .. '-Meta' then
                buf2 = (subName == 'Keys' and '\0\0\0\0\0\0\0\0' or '')
            elseif subName == 'Meta' and perlTruthy(et.OPTIONS.QuickTimeHandler) then
                et:VPrint(0, '  Creating Meta with mdir Handler\n')
                -- init Meta box for ItemList tags with mdir Handler
                buf2 = '\0\0\0\x20hdlr\0\0\0\0\0\0\0\0mdir\0\0\0\0\0\0\0\0\0\0\0\0'
            else
                if not (curPath == writePath and addDirs[subName] and addDirs[subName] == dirName) then goto nextAdd end
                buf2 = ''  -- write from scratch
            end
            local subdirInfo = {
                Parent   = dirName,
                DirName  = subName,
                DataPt   = buf2,
                DirStart = 0,
                HasData  = subdir.HasData,
                OutFile  = outfile,
                ChunkOffset = { }, -- (just to be safe)
                WriteGroup = tagInfo.WriteGroup,
            }
            local subTable = et:GetTagTable(subdir.TagTable)
            local newData = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
            if perlTruthy(newData) and length(newData) <= 0x7ffffff7 then
                local prefix = ''
                -- add atom version or ID if necessary
                if perlTruthy(subdir.Start) then
                    if subdir.Start == 4 then
                        prefix = '\0\0\0\0' -- a simple version number
                    else
                        -- get UUID from Condition expression
                        -- (port: a Lua Condition is a function; ConditionUUID
                        --  reads the pattern back from its source line)
                        local cond = tagInfo.Condition
                        prefix = cond and ConditionUUID(cond) or prefix
                        if length(prefix) ~= subdir.Start then et:Error('Internal UUID error') end
                    end
                end
                local newHdr = ExifTool.Put32u(8 + length(newData) + length(prefix)) .. tag .. prefix
                if tagInfo.WriteLast then
                    writeLast = (writeLast or '') .. newHdr .. newData
                else
                    if tag == 'uuid' then
                        -- add offset for new uuid (needed for CR3 CTBO offsets)
                        local off = dirInfo.ChunkOffset
                        off[#off + 1] = { tag, length(outfile.value), length(newHdr) + length(newData) }
                    end
                    boxPos[tag] = { length(outfile.value), length(newHdr) + length(newData) }
                    if not Write(outfile, newHdr, newData) then rtnVal = rtnErr err = 1 end
                end
            end
            -- add only once (must delete _after_ call to WriteDirectory())
            -- (Keys tags are a special case, and are handled separately)
            if createKeys == 0 then addDirs[subName] = nil end
            end
            ::nextAdd::
        end
    end
    -- write HEIC metadata after top-level 'meta' box has been processed if editing this information
    if curPath == 'MOV-Meta' and et.EDIT_DIRS and et.EDIT_DIRS.ItemInformation then
        dirInfo.BoxPos = boxPos
        local mdatEdit2 = WriteQuickTime.WriteItemInfo(et, dirInfo, outfile.value)
        if mdatEdit2 then
            if et.mdatEdit then et:Error('Multiple top-level Meta containers') end
            et.mdatEdit = mdatEdit2
        end
    end
    -- write out any necessary terminator
    if term and length(outfile.value) > 0 then
        if not Write(outfile, term) then rtnVal = rtnErr err = 1 end
    end

    -- delete temporary Keys variables after Meta is processed
    if dirName == 'Meta' then
        -- delete any Meta box with no useful information (ie. only 'hdlr','keys','lang','ctry')
        local isEmpty = 1
        for t in pairs(boxPos) do
            if not emptyMeta[t] then isEmpty = 0 break end
        end
        if isEmpty ~= 0 then
            if next(boxPos) then
                local names = { }
                for t in pairs(boxPos) do names[#names + 1] = emptyMeta[t] end
                tsort(names)
                et:VPrint(0, '  Deleting ' .. table.concat(names, '+'))
            end
            outfile.value = carray.new('char')
            -- (could report a file if editing nothing when it contained an empty Meta atom)
            -- ++$$et{CHANGED};
        end
        if curPath == keysPath .. '-Meta' then
            addDirs[keysGrp] = nil -- prevent creation of another Meta for Keys tags
            et[keysGrp] = nil
        end
    end

    -- return now if writing subdirectory
    if dataPt then
        if writeLast then et:Error('Internal error: WriteLast not on top-level atom!\n') end
        if err then return nil end
        return outfile.value:tostring()
    end

    -- issue minor error if we didn't find an 'mdat' atom
    local off = dirInfo.ChunkOffset
    if #mdatList == 0 then
        for _, c in ipairs(off) do
            co = c
            if co[1] ~= 'uuid' then
                et:Error('Media data referenced but not found')
                return rtnVal
            end
        end
        et:Warn('No media data', 1)
    end

    -- edit mdat blocks as required
    -- (0=old pos [0 if creating], 1=old end [0 if creating], 2=new data ref or undef to delete,
    --  3=new data item id)
    if et.mdatEdit then
        mdatEdit = et.mdatEdit
        et.mdatEdit = nil
    end
    for _, e in ipairs(mdatEdit) do
        edit = e
        local thisMdat, newMdat, changed = { }, { }, nil
        for _, m in ipairs(mdatList) do
            mdat = m
            -- keep track of all chunks for the mdat with this header
            if length(mdat[3]) > 0 then
                for _, t in ipairs(thisMdat) do newMdat[#newMdat + 1] = t end
                thisMdat = { }
            end
            thisMdat[#thisMdat + 1] = mdat
            -- is this edit inside this mdat chunk?
            -- - $$edit[0] and $$edit[1] will both be zero if we are creating a new chunk
            -- - $$mdat[1] is zero if mdat runs to end of file
            -- - $$edit[0] == $$edit[1] == $$mdat[0] if reviving a deleted chunk
            -- - $$mdat[5] is defined if this was a newly added/edited chunk
            if mdat[6] ~= nil or changed then goto nextMdat end  -- don't replace a newly added chunk
            if not perlTruthy(edit[1]) or    -- (newly created chunk)
                -- (edit is inside chunk)
                (((edit[1] < mdat[2] or not perlTruthy(mdat[2])) and edit[2] > mdat[1]) or
                -- (edit inserted at start or end of chunk)
                (edit[1] == edit[2] and (edit[1] == mdat[1] or edit[1] == mdat[2])))
            then
                if not perlTruthy(edit[1]) then
                    edit[1], edit[2] = mdat[1], mdat[1]  -- insert at start of this mdat
                elseif edit[1] < mdat[1] or (edit[2] > mdat[2] and perlTruthy(mdat[2])) then
                    et:Error('ItemInfo runs across mdat boundary')
                    return rtnVal
                end
                local hdrChunk = thisMdat[1]
                if not hdrChunk then et:Error('Internal error finding mdat header') return rtnVal end
                -- calculate difference in mdat size
                local diff = (edit[3] and length(edit[3]) or 0) - (edit[2] - edit[1])
                -- edit size of mdat in header if necessary
                if diff ~= 0 then
                    if length(hdrChunk[3]) == 8 then
                        local size = Get32u(hdrChunk[3], 0)
                        if size ~= 0 then -- (0 size = extends to end of file)
                            size = size + diff
                            if size > 0xffffffff then et:Error("Can't yet grow mdat across 4GB boundary") return rtnVal end
                            -- (`Set32u($size, \$$hdrChunk[2], 0)` on a string)
                            local h = carray.new('char'):append(hdrChunk[3])
                            ExifTool.Set32u(h, 0, size)
                            hdrChunk[3] = h:tostring()
                        end
                    elseif length(hdrChunk[3]) == 16 then
                        local size = ExifTool.Get64u(hdrChunk[3], 8)
                        if size ~= 0 then
                            size = size + diff
                            local h = carray.new('char'):append(hdrChunk[3])
                            Writer.Set64u(h, 8, size)
                            hdrChunk[3] = h:tostring()
                        end
                    else
                        et:Error('Internal error. Invalid mdat header')
                        return rtnVal
                    end
                end
                changed = 1
                -- remove the edited section of this chunk (if any) and replace with new data (if any)
                if edit[1] > mdat[1] then
                    if edit[3] then thisMdat[#thisMdat + 1] = { edit[1], edit[2], '', 0, edit[3], edit[4] } end
                    -- add remaining data after edit (or empty stub in case it is referenced by an offset)
                    thisMdat[#thisMdat + 1] = { edit[2], mdat[2], '' }
                    mdat[2] = edit[1]  -- now ends at start of edit
                else
                    if edit[3] then
                        -- insert the new chunk before this chunk, moving the header to the new chunk
                        table.insert(thisMdat, #thisMdat, { edit[1], edit[2], mdat[3], 0, edit[3], edit[4] })
                        mdat[3] = ''     -- (header was moved to new chunk)
                        -- initialize ChunkOffset pointer if necessary
                        if perlTruthy(edit[4]) then
                            local n = 0
                            for _, c in ipairs(off) do
                                co = c
                                if co[5] ~= nil and co[5] == edit[4] then
                                    n = n + 1
                                    if co[1] == 'stco_iloc' then
                                        ExifTool.Set32u(outfile.value, co[2], mdat[1])
                                    else
                                        Writer.Set64u(outfile.value, co[2], mdat[1])
                                    end
                                end
                            end
                            if n ~= 1 then et:Error('Internal error updating chunk offsets') end
                        end
                    end
                    mdat[1] = edit[2]  -- remove old data
                end
            end
            ::nextMdat::
        end
        if changed then
            mdatList = { }
            for _, m in ipairs(newMdat) do mdatList[#mdatList + 1] = m end
            for _, m in ipairs(thisMdat) do mdatList[#mdatList + 1] = m end
            et.CHANGED = (et.CHANGED or 0) + 1
        else
            et:Error('Internal error modifying mdat')
        end
    end

    -- determine our new mdat positions
    -- (0=old pos, 1=old end, 2=mdat header, 3=new pos, 4=new data ref if changed, 5=new item ID)
    local pos = length(outfile.value)
    for _, m in ipairs(mdatList) do
        mdat = m
        pos = pos + length(mdat[3])
        mdat[4] = pos
        pos = pos + (mdat[5] and length(mdat[5]) or mdat[2] - mdat[1])
    end

    -- fix up offsets for new mdat position(s) (and uuid positions in CR3 images)
    for _, c in ipairs(off) do
        co = c
        local type_, ptr, len, base, id = co[1], co[2], co[3], co[4], co[5]
        if not perlTruthy(base) then base = 0 end
        local ok, c1, c2 = isMatch(type_, [[^(stco|co64)_?(.*)$]])
        if not ok then
            if type_ == 'uuid' then goto nextCo end
            if type_ ~= 'CTBO' then et:Error('Internal error fixing offsets') break end
            -- update 'CTBO' item offsets/sizes in Canon CR3 images
            if co[3] <= 12 then et:Error('Invalid CTBO atom') break end
            if #mdatList == 0 then et:Error('Missing CR3 image data') break end
            local n = Get32u(outfile.value, co[2] + 8)
            if co[3] < n * 20 + 12 then et:Error('Truncated CTBO atom') break end
            local ctboOff = { }
            -- determine uuid types, and build an offset lookup based on CTBO ID number
            for _, u in ipairs(off) do
                if not (u[1] == 'uuid' and u[3] >= 24) then goto nextUuid end -- (ignore undersized and deleted uuid boxes)
                do
                    local upos = u[2]
                    if upos + 24 > length(outfile.value) then goto nextUuid end   -- (will happen for WriteLast uuid tags)
                    local siz = Get32u(outfile.value, upos)       -- get size of uuid atom
                    if siz == 1 then                        -- check for extended (8-byte) size
                        if u[3] < 32 then goto nextUuid end
                        upos = upos + 8
                    end
                    -- get CTBO entry ID based on 16-byte UUID identifier
                    local uid = ctboID[substr(outfile.value, upos + 8, 16)]
                    if uid ~= nil then ctboOff[uid] = u end
                end
                ::nextUuid::
            end
            -- calculate new offset for the first mdat (size of -1 indicates it didn't change)
            ctboOff[3] = { 'mdat', mdatList[1][4] - length(mdatList[1][3]), -1 }
            for i = 0, n - 1 do
                local cpos = co[2] + 12 + i * 20
                local cid = Get32u(outfile.value, cpos)
                -- ignore if size is zero unless we can add this entry
                -- (note: can't yet add/delete PreviewImage, but leave this possibility open)
                if not (ExifTool.Get64u(outfile.value, cpos + 12) ~= 0 or cid == 1 or cid == 2) then goto nextCtbo end
                if ctboOff[cid] == nil then
                    if not (cid == 1 or cid == 2) then et:Error("Can't handle CR3 CTBO ID number " .. cid) break end
                    -- XMP or PreviewImage was deleted -- set offset and size to zero
                    ctboOff[cid] = { 'uuid', 0, 0 }
                end
                -- update the new offset and size of this entry
                Writer.Set64u(outfile.value, cpos + 4, ctboOff[cid][2])
                if ctboOff[cid][3] >= 0 then Writer.Set64u(outfile.value, cpos + 12, ctboOff[cid][3]) end
                ::nextCtbo::
            end
            goto nextCo
        end
        do
            local siz = c1 == 'co64' and 8 or 4
            local n, tag -- luacheck: ignore 421
            if c2 ~= '' then   -- is this an offset in an iloc or 'gps ' atom?
                n = 1
                type_ = c1
                tag = c2
            else    -- this is an stco or co84 atom
                if len < 8 then goto nextCo end
                n = Get32u(outfile.value, ptr + 4)    -- get number of entries in table
                ptr = ptr + 8
                len = len - 8
                tag = c1
            end
            local end_ = ptr + n * siz
            if end_ > ptr + len then et:Error('Invalid ' .. tag .. ' table') return rtnVal end
            while ptr < end_ do
                local fixed
                local val = type_ == 'co64' and ExifTool.Get64u(outfile.value, ptr) or Get32u(outfile.value, ptr)
                for i = 1, #mdatList do
                    mdat = mdatList[i]
                    local mpos = val + base
                    if mdat[6] ~= nil then -- is this chunk associated with an item we edited?
                        -- set offset only for the corresponding new chunk
                        if not (id ~= nil and id == mdat[6]) then
                            -- could have pointed to empty chunk before inserted chunk
                            if not (mpos == mdat[1] and mdat[1] ~= mdat[2]) then goto nextI end
                        end
                    else
                        -- (have seen $pos == $$mdat[1], which is a real PITA)
                        if not (mpos >= mdat[1] and (mpos <= mdat[2] or not perlTruthy(mdat[2]))) then goto nextI end
                        -- step to next chunk if contiguous and at the end of this one
                        if mpos == mdat[2] and i < #mdatList and mpos == mdatList[i + 1][1] then goto nextI end
                    end
                    val = val + mdat[4] - mdat[1]
                    if val < 0 then
                        et:Error('Error fixing up ' .. tag .. ' offset')
                        return rtnVal
                    end
                    if type_ == 'co64' then
                        Writer.Set64u(outfile.value, ptr, val)
                    elseif val <= 0xffffffff then
                        ExifTool.Set32u(outfile.value, ptr, val)
                    else
                        et:Error("Can't yet promote " .. tag .. ' offset to 64 bits')
                        return rtnVal
                    end
                    fixed = 1
                    do break end
                    ::nextI::
                end
                if not fixed then
                    et:Error('Chunk offset in ' .. tag .. ' atom is outside media data')
                    return rtnVal
                end
                ptr = ptr + siz
            end
        end
        ::nextCo::
    end

    -- switch back to actual output file
    outfile = dirInfo.OutFile

    -- write the metadata
    if not Write(outfile, outBuff.value) then rtnVal = 0 end

    -- write the media data
    for _, m in ipairs(mdatList) do
        mdat = m
        if not Write(outfile, mdat[3]) then rtnVal = 0 end  -- write mdat header
        if mdat[5] then
            if not Write(outfile, mdat[5]) then rtnVal = 0 end
        else
            if not raf:Seek(mdat[1], 0) then et:Error('Seek error') break end
            if perlTruthy(mdat[2]) then
                local result = Writer.CopyBlock(raf, outfile, mdat[2] - mdat[1])
                if result == nil then rtnVal = 0 break end
                if not perlTruthy(result) then et:Error('Truncated mdat atom') break end
            else
                -- mdat continues to end of file
                while true do
                    local n
                    n, buf2 = raf:Read(65536)
                    if not perlTruthy(n) then break end
                    if not Write(outfile, buf2) then rtnVal = 0 break end
                end
            end
        end
    end

    -- write the stuff that must come last
    if writeLast then
        if not Write(outfile, writeLast) then rtnVal = 0 end
    end

    -- copy trailers if necessary
    while perlTruthy(rtnVal) and trailer do
        -- are we deleting the trailers?
        local nvTrail = Writer.GetNewValueHash(et, ExifTool.Extra.Trailer)
        if Writer.IsGroupDeleted(et, 'Trailer') or Writer.IsGroupDeleted(et, trailer[1]) or
            (nvTrail and not (nvTrail.Value and perlTruthy(nvTrail.Value[1])))
        then
            et:Warn('Deleted ' .. trailer[1] .. ' trailer', 1)
            et.CHANGED = (et.CHANGED or 0) + 1
            trailer = trailer[4]
            goto nextTrailer
        end
        if not raf:Seek(trailer[2], 0) then rtnVal = 0 break end
        if trailer[1] == 'MIE' then
            local MIE = require('lexiftool.MIE')
            local dirInfo2 = { RAF = raf, OutFile = outfile }
            local result = MIE.ProcessMIE(et, dirInfo2)
            if result <= 0 then et:Error('Error writing MIE trailer') rtnVal = 0 break end
        else
            et:Warn(sprintf('Copying %s trailer from offset 0x%x (%d bytes)', trailer[1], trailer[2], trailer[3]), 1)
            local len = trailer[3]
            while len ~= 0 do
                local n = len > 65536 and 65536 or len
                local got
                got, buf2 = raf:Read(n)
                if not (got == n and Write(outfile, buf2)) then rtnVal = 0 break end
                len = len - n
            end
            if not perlTruthy(rtnVal) then et:Error('Error copying ' .. trailer[1] .. ' trailer') break end
        end
        trailer = trailer[4]    -- step to next trailer in linked list
        ::nextTrailer::
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Write QuickTime-format MOV/MP4 file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid QuickTime file,
--          or -1 if a write error occurred
--------------------------------------------------------------------------------
function WriteQuickTime.WriteMOV(et, dirInfo)
    if not et then return 1 end   -- allow dummy access to autoload this package
    local Writer = require('lexiftool.Writer')
    local raf = dirInfo.RAF
    if not raf then return 0 end
    local buff, ftype

    -- read the first atom header
    local n
    n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    local size, tag = unpack('Na4', buff)
    if size < 8 and size ~= 1 then return 0 end

    -- validate the file format
    local tagTablePtr = et:GetTagTable('lexiftool.QuickTime.Main')
    if not tagTablePtr[tag] then return 0 end

    -- determine the file type (by default, assume MP4 if 'ftyp' exists
    -- without 'qt  ' as a compatible brand, but HEIC is an exception)
    local isFtyp = tag == 'ftyp' and size >= 12 and size < 100000
    if isFtyp then
        n, buff = raf:Read(size - 8)
        isFtyp = n == size - 8 and not isMatch(buff, [[(?s)^(....)+(qt  )]])
    end
    if isFtyp then
        if isMatch(buff, [[^crx ]]) then
            ftype = 'CR3'
        elseif isMatch(buff, [[^(heic|mif1|msf1|heix|hevc|hevx|avif)]]) then
            ftype = 'HEIC'
        else
            ftype = 'MP4'
        end
    else
        ftype = 'MOV'
    end
    et:SetFileType(ftype) -- need to set "FileType" tag for a Condition
    if ftype == 'HEIC' then
        -- EXIF is preferred in HEIC files
        Writer.InitWriteDirs(et, dirMap[ftype], 'EXIF', 'QuickTime')
    else
        Writer.InitWriteDirs(et, dirMap[ftype], 'XMP', 'QuickTime')
    end
    et.DirMap = dirMap[ftype]     -- need access to directory map when writing
    -- track tags globally to avoid creating multiple tags in the case of duplicate directories
    et.DidTag = { }
    ExifTool.SetByteOrder('MM')
    raf:Seek(0, 0)

    -- write the file
    et.MediaType = ''
    dirInfo.Parent = ''
    dirInfo.DirName = 'MOV'
    dirInfo.ChunkOffset = { } -- (just to be safe)
    return perlTruthy(WriteQuickTime.WriteQuickTime(et, dirInfo, tagTablePtr)) and 1 or -1
end

return WriteQuickTime
