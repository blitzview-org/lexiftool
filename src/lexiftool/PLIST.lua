--------------------------------------------------------------------------------
-- File:         lexiftool/PLIST.lua
-- Ported from:  lib/Image/ExifTool/PLIST.pm
--
-- Description:  Read Apple PLIST information
--
-- Revisions:    2013-02-01 - P. Harvey Created
--
-- References:   1) http://www.apple.com/DTDs/PropertyList-1.0.dtd
--               2) http://opensource.apple.com/source/CF/CF-550/CFBinaryPList.c
--
-- Notes:      - Sony MODD files also use XML PLIST format, but with a few quirks
--
--             - Decodes both the binary and XML-based PLIST formats
--
-- Port notes: - the CompressedPLIST path (raw-deflated adjustmentData of an
--               AAE file) inflates through ExifTool.rawinflate, the
--               IO::Uncompress::RawInflate equivalent.
--             - the JSON PLIST branch is not ported (not exercised by any
--               golden test; JSON.lua exists and could be wired in later).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local XMP = require('lexiftool.XMP')
local ASF = require('lexiftool.ASF')
local substr = require('lexiftool.perl').substr
local length = require('lexiftool.perl').length
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst

local PLIST = {}

-- access routines to read various-sized integer/real values (add 0x100 to size for reals)
local function Get24u(dataPt, off)
    return ExifTool.Get32u('\0' .. substr(dataPt, off, 3), 0)
end
local readProc = {
    [1] = ExifTool.Get8u,
    [2] = ExifTool.Get16u,
    [3] = Get24u,
    [4] = ExifTool.Get32u,
    [8] = ExifTool.Get64u,
    [0x104] = ExifTool.GetFloat,
    [0x108] = ExifTool.GetDouble,
}

-- recognize different types of PLIST files based on certain tags
local plistType = {
    adjustmentBaseVersion = 'AAE',
}

-- PLIST tags (generated on-the-fly for most tags)
PLIST.Main = {
    GROUPS = { [0] = 'PLIST', [1] = 'XML', [2] = 'Document' },
    VARS = { LONG_TAGS = 18 },
    NOTES = [[
        Apple Property List tags.  ExifTool reads both XML and binary-format PLIST
        files, and will extract any existing tags even if they aren't listed below.
        These tags belong to the family 0 "PLIST" group, but family 1 group may be
        either "XML" or "PLIST" depending on whether the format is XML or binary.
    ]],
    --
    -- tags found in PLIST information of QuickTime iTunesInfo iTunMOVI atom (ref PH)
    --
    ['cast//name'] = { Name = 'Cast', List = 1 },
    ['directors//name'] = { Name = 'Directors', List = 1 },
    ['producers//name'] = { Name = 'Producers', List = 1 },
    ['screenwriters//name'] = { Name = 'Screenwriters', List = 1 },
    ['codirectors//name'] = { Name = 'Codirectors', List = 1 },
    ['studio//name'] = { Name = 'Studio', List = 1 },
    --
    -- tags found in MODD files (ref PH)
    --
    ['MetaDataList//DateTimeOriginal'] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        -- Sony uses a "real" here -- number of days since Dec 31, 1899
        ValueConv = function(_self, val)
            if type(val) == 'number' then return ExifTool.ConvertUnixTime((val - 25569) * 24 * 3600) end
            return val
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['MetaDataList//Duration'] = {
        Name = 'Duration',
        Groups = { [2] = 'Video' },
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    ['MetaDataList//Geolocation/Latitude'] = {
        Name = 'GPSLatitude',
        Groups = { [2] = 'Location' },
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    ['MetaDataList//Geolocation/Longitude'] = {
        Name = 'GPSLongitude',
        Groups = { [2] = 'Location' },
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    ['MetaDataList//Geolocation/MapDatum'] = {
        Name = 'GPSMapDatum',
        Groups = { [2] = 'Location' },
    },
    -- slow motion stuff found in AAE files
    ['slowMotion/regions/timeRange/start/flags'] = {
        Name = 'SlowMotionRegionsStartTimeFlags',
        PrintConv = { BITMASK = {
            [0] = 'Valid', [1] = 'Has been rounded', [2] = 'Positive infinity',
            [3] = 'Negative infinity', [4] = 'Indefinite',
        } },
    },
    ['slowMotion/regions/timeRange/start/value'] = 'SlowMotionRegionsStartTimeValue',
    ['slowMotion/regions/timeRange/start/timescale'] = 'SlowMotionRegionsStartTimeScale',
    ['slowMotion/regions/timeRange/start/epoch'] = 'SlowMotionRegionsStartTimeEpoch',
    ['slowMotion/regions/timeRange/duration/flags'] = {
        Name = 'SlowMotionRegionsDurationFlags',
        PrintConv = { BITMASK = {
            [0] = 'Valid', [1] = 'Has been rounded', [2] = 'Positive infinity',
            [3] = 'Negative infinity', [4] = 'Indefinite',
        } },
    },
    ['slowMotion/regions/timeRange/duration/value'] = 'SlowMotionRegionsDurationValue',
    ['slowMotion/regions/timeRange/duration/timescale'] = 'SlowMotionRegionsDurationTimeScale',
    ['slowMotion/regions/timeRange/duration/epoch'] = 'SlowMotionRegionsDurationEpoch',
    ['slowMotion/regions'] = 'SlowMotionRegions',
    ['slowMotion/rate'] = 'SlowMotionRate',
    -- buried deep in live photo .mov file
    LivePhotoMetadataSetupDataVersion = {},
    ['SystemVersion/ProductBuildVersion'] = 'ProductBuildVersion',
    ['SystemVersion/ProductName'] = 'ProductName',
    ['SystemVersion/ProductVersion'] = 'ProductVersion',
    ['FrameworkVersions/CoreMotion'] = 'CoreMotionVersion',
    ['FrameworkVersions/CMCaptureCore'] = 'CMCaptureCoreVersion',
    ['FrameworkVersions/H16ISPServices'] = 'H16ISPServicesVersion',
    ['FrameworkVersions/CoreMedia'] = 'CoreMediaVersion',
    XMLFileType = {
        -- recognize MODD files by their content
        RawConv = function(self, val)
            if val == 'ModdXML' and self.FILE_TYPE == 'PLIST' then
                self:OverrideFileType('MODD')
            end
            return val
        end,
    },
    adjustmentData = { -- AAE file
        Name = 'AdjustmentData',
        CompressedPLIST = 1,
        SubDirectory = { TagTable = 'lexiftool.PLIST.Main' },
    },
}

--------------------------------------------------------------------------------
-- We found a PLIST XML property name/value
-- Inputs: 0) ExifTool object ref, 1) tag table ref
--         2) array of XML property names (last is current property)
--         3) property value, 4) attribute table (not used here)
-- Returns: 1 if valid tag was found
--------------------------------------------------------------------------------
function PLIST.FoundTag(et, tagTablePtr, props, val, _attrs)
    if #props == 0 then return 0 end
    local verbose = et:Options('Verbose')
    local keys = et.PListKeys
    if not keys then
        keys = {}
        et.PListKeys = keys
    end

    local prop = props[#props]
    if perlTruthy(verbose) and verbose > 1 then
        et:VPrint(0, et.INDENT, '[', table.concat(props, '/'), ' = ',
                  et:Printable(val), ']\n')
    end
    -- un-escape XML character entities
    val = XMP.UnescapeXML(val)

    -- handle the various PLIST properties
    if prop == 'data' then
        if val:match('^[0-9a-f]+$') and #val % 2 == 0 then
            -- MODD files use ASCII-hex encoded "data"...
            local buff = {}
            for i = 1, #val, 2 do buff[#buff + 1] = string.char(tonumber(val:sub(i, i + 1), 16)) end
            val = { ref = 'SCALAR', value = table.concat(buff) }
        else
            -- ...but the PLIST DTD specifies Base64 encoding
            val = { ref = 'SCALAR', value = XMP.DecodeBase64(val) }
        end
    elseif prop == 'date' then
        val = XMP.ConvertXMPDate(val)
    elseif prop == 'true' or prop == 'false' then
        val = ucfirst(prop)
    else
        -- convert from UTF8 to ExifTool Charset
        val = et:Decode(val, 'UTF8')
        if prop == 'key' then
            if #props <= 3 then -- top-level key should be plist/dict/key
                keys = { val }
                et.PListKeys = keys
            else
                -- save key names to be used in tag name
                while #keys < #props - 3 do keys[#keys + 1] = '' end
                while #keys > #props - 2 do table.remove(keys) end
                keys[#props - 2] = val
            end
            return 0
        end
    end

    if #keys == 0 then return 0 end -- can't store value if no associated key

    local tag = table.concat(keys, '/') -- generate tag ID from 'key' values
    local tagInfo = tagTablePtr[tag]
    if not tagInfo then
        if perlTruthy(verbose) then et:VPrint(0, et.INDENT, '[adding ' .. tag .. ']\n') end
        -- generate tag name from ID
        local name = tag
        name = name:gsub('^MetaDataList//', '') -- shorten long MODD metadata tag names
        name = name:gsub('//name$', '') -- remove unnecessary MODD "name" property
        name = name:gsub('([^A-Za-z])([a-z])', function(a, b) return a .. uc(b) end) -- capitalize words
        name = name:gsub('[^%-_a-zA-Z0-9]', '') -- remove illegal characters
        tagInfo = { Name = ucfirst(name), List = 1 }
        if prop == 'date' then
            tagInfo.Groups = { [2] = 'Time' }
            tagInfo.PrintConv = function(self, v) return self:ConvertDateTime(v) end
        end
        et:AddTagToTable(tagTablePtr, tag, tagInfo)
    end
    -- allow list-behaviour only for consecutive tags with the same ID
    if et.LastPListTag and et.LastPListTag ~= tagInfo then
        et.LIST_TAGS[et.LastPListTag] = nil
    end
    et.LastPListTag = tagInfo
    -- override file type if applicable
    if plistType[tag] and et.FILE_TYPE == 'PLIST' then et:OverrideFileType(plistType[tag]) end
    -- handle compressed PLIST/JSON data
    if tagInfo.CompressedPLIST and type(val) == 'table' and val.ref == 'SCALAR' and not val.value:find('^bplist00') then
        if ExifTool.hasZlib() then   -- (`eval { require IO::Uncompress::RawInflate }`)
            local inflated, ok = ExifTool.rawinflate(nil, val.value)
            if ok then
                val = { ref = 'SCALAR', value = inflated }
            else
                et:Warn('Error inflating PLIST::' .. tagInfo.Name)
            end
        else
            et:Warn('Install IO::Uncompress to decode compressed PLIST data')
        end
    end
    -- save the tag
    et:HandleTag(tagTablePtr, tag, val)

    return 1
end

--------------------------------------------------------------------------------
-- Extract object from binary PLIST file at the current file position (ref 2)
-- Inputs: 0) ExifTool ref, 1) PLIST info table, 2) parent tag ID (nil for top)
-- Returns: the object, or nil on error
--------------------------------------------------------------------------------
-- Marks Lua tables returned by ExtractObject() for a binary-PLIST "dict"
-- object (upstream distinguishes these from "array"/"set" objects by Perl
-- ref type, HASH vs ARRAY; both are plain Lua tables here, so a weak-keyed
-- side table is used instead of tagging the table's own keys)
local isDictResult = setmetatable({}, { __mode = 'k' })

-- Externally-callable check for whether a value returned via
-- ProcessBinaryPLIST's dirInfo.Value came from a top-level "dict" object
-- (upstream's `ref $dirInfo{Value} eq 'HASH'`; used by e.g. MacOS.lua's
-- ReadXAttrValue, which must skip a decoded value that's a dict)
function PLIST.isDict(val)
    return isDictResult[val] == true
end

local function ExtractObject(et, plistInfo, parent)
    local raf = plistInfo.RAF
    local n, buff = raf:Read(1)
    if n ~= 1 then return nil end
    local b0 = buff:byte(1)
    local objType = b0 >> 4
    local size = b0 & 0x0f
    local val
    if objType == 0 then -- null/bool/fill
        local m = { [0x00] = '<null>', [0x08] = 'True', [0x09] = 'False', [0x0f] = '<fill>' }
        val = m[size]
    elseif objType == 1 or objType == 2 or objType == 3 then -- int, float or date
        size = 1 << size
        local proc = readProc[objType == 1 and size or (size + 0x100)]
        if not proc then return nil end
        local n2, buff2 = raf:Read(size)
        if n2 == size then val = proc(buff2, 0) end
        if objType == 3 and val ~= nil then -- date
            -- dates are referenced to Jan 1, 2001 (11323 days from Unix time zero)
            val = ExifTool.ConvertUnixTime(val + 11323 * 24 * 3600, 1)
            plistInfo.DateFormat = 1
        end
    elseif objType == 8 then -- UID
        size = size + 1
        local n2, buff2 = raf:Read(size)
        if n2 ~= size then return nil end
        local proc = readProc[size]
        if proc then
            val = proc(buff2, 0)
        elseif size == 16 then
            val = ASF.GetGUID(buff2)
        else
            local hex = {}
            for i = 1, #buff2 do hex[i] = string.format('%02x', buff2:byte(i)) end
            val = '0x' .. table.concat(hex)
        end
    else
        -- size is the size of the remaining types
        if size == 0x0f then
            -- size is stored in extra integer object
            local sz = ExtractObject(et, plistInfo)
            if type(sz) ~= 'number' then return nil end
            size = sz
        end
        if objType == 4 then -- data
            local buff2
            if size < 1000000 or et.OPTIONS.Binary then
                local n2
                n2, buff2 = raf:Read(size)
                if n2 ~= size then return nil end
            else
                buff2 = 'Binary data ' .. size .. ' bytes'
            end
            val = { ref = 'SCALAR', value = buff2 } -- (return reference for binary data)
        elseif objType == 5 then -- ASCII string
            local n2, buff2 = raf:Read(size)
            if n2 ~= size then return nil end
            val = buff2
        elseif objType == 6 then -- UCS-2BE string
            size = size * 2
            local n2, buff2 = raf:Read(size)
            if n2 ~= size then return nil end
            val = et:Decode(buff2, 'UTF16') -- (might as well support surrogates too)
        elseif objType == 10 or objType == 12 or objType == 13 then -- array, set or dict
            -- the remaining types store a list of references
            local refSize = plistInfo.RefSize
            local refProc = plistInfo.RefProc
            local num = objType == 13 and size * 2 or size
            local len = num * refSize
            local n2, buff2 = raf:Read(len)
            if n2 ~= len then return nil end
            local table_ = plistInfo.Table
            local refs = {}
            for i = 0, num - 1 do
                local ref = refProc(buff2, i * refSize)
                if ref >= #table_ then return nil end
                refs[#refs + 1] = ref
            end
            if objType == 13 then -- dict
                -- prevent infinite recursion
                if parent ~= nil and #parent > 1000 then
                    et:Warn('Possible deep recursion while parsing PLIST')
                    return nil
                end
                local tagTablePtr = plistInfo.TagTablePtr
                val = {} -- initialize return dictionary (will stay empty if tags are saved)
                isDictResult[val] = true
                for i = 0, size - 1 do
                    -- get the entry key
                    if not raf:Seek(table_[refs[i + 1] + 1], 0) then return nil end
                    local key = ExtractObject(et, plistInfo)
                    if key ~= nil and type(key) == 'string' and #key > 0 then
                        -- get the entry value
                        if not raf:Seek(table_[refs[i + size + 1] + 1], 0) then return nil end
                        -- generate an ID for this tag
                        local tag = parent ~= nil and (parent .. '/' .. key) or key
                        plistInfo.DateFormat = nil
                        local obj = ExtractObject(et, plistInfo, tag)
                        if obj ~= nil then
                            if not tagTablePtr then
                                -- make sure this is a valid structure field name
                                if not key:match('^[%-_a-zA-Z0-9]+$') then
                                    key = 'Tag' .. i -- (generate fake tag name if it had illegal characters)
                                elseif not key:match('^[_a-zA-Z]') then
                                    key = '_' .. key -- (must begin with alpha or underline)
                                end
                                val[key] = obj
                            elseif not isDictResult[obj] then
                                local tagInfo = et:GetTagInfo(tagTablePtr, tag)
                                if not tagInfo then
                                    if perlTruthy(et:Options('Verbose')) then et:VPrint(0, et.INDENT .. '[adding ' .. tag .. ']\n') end
                                    local name = tag
                                    name = name:gsub('([^A-Za-z])([a-z])', function(a, b) return a .. uc(b) end)
                                    name = name:gsub('[^%-_a-zA-Z0-9]', '')
                                    if #name < 2 or name:match('^[%-0-9]') then
                                        name = 'Tag' .. ucfirst(name)
                                    end
                                    tagInfo = { Name = ucfirst(name), List = 1 }
                                    if plistInfo.DateFormat then
                                        tagInfo.Groups = { [2] = 'Time' }
                                        tagInfo.PrintConv = function(self, v) return self:ConvertDateTime(v) end
                                    end
                                    et:AddTagToTable(tagTablePtr, tag, tagInfo)
                                end
                                if et.LastPListTag and et.LastPListTag ~= tagInfo then
                                    et.LIST_TAGS[et.LastPListTag] = nil
                                end
                                et.LastPListTag = tagInfo
                                et:HandleTag(tagTablePtr, tag, obj)
                            end
                        end
                    end
                end
            else
                -- extract the referenced objects
                local array = {}
                for _, ref in ipairs(refs) do
                    if not raf:Seek(table_[ref + 1], 0) then return nil end -- seek to this object
                    local v = ExtractObject(et, plistInfo, parent)
                    if v ~= nil and not isDictResult[v] then
                        array[#array + 1] = v
                    end
                end
                val = array
            end
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Process binary PLIST data (ref 2)
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success (and returns plist value as dirInfo.Value)
--------------------------------------------------------------------------------
function PLIST.ProcessBinaryPLIST(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt

    if not dirInfo.NoVerboseDir then et:VerboseDir('Binary PLIST') end
    ExifTool.SetByteOrder('MM')

    if dataPt then
        local start = dirInfo.DirStart or 0
        if start ~= 0 or (dirInfo.DirLen and dirInfo.DirLen ~= length(dataPt)) then
            local buf2 = substr(dataPt, start, dirInfo.DirLen or (length(dataPt) - start))
            dirInfo.RAF = require('lexiftool.RandomAccess').new(buf2)
        else
            dirInfo.RAF = require('lexiftool.RandomAccess').new(dataPt)
        end
    end
    -- read and parse the trailer
    local raf = dirInfo.RAF
    if not raf then return 0 end
    if not raf:Seek(-32, 2) then return 0 end
    local n, buff = raf:Read(32)
    if n ~= 32 then return 0 end
    local intSize = ExifTool.Get8u(buff, 6)
    local refSize = ExifTool.Get8u(buff, 7)
    local numObj = ExifTool.Get64u(buff, 8)
    local topObj = ExifTool.Get64u(buff, 16)
    local tableOff = ExifTool.Get64u(buff, 24)

    if topObj >= numObj then return 0 end
    local intProc = readProc[intSize]
    local refProc = readProc[refSize]
    if not (intProc and refProc) then return 0 end

    -- read and parse the offset table
    local tableSize = intSize * numObj
    if not raf:Seek(tableOff, 0) then return 0 end
    local n2, tbuff = raf:Read(tableSize)
    if n2 ~= tableSize then return 0 end
    local table_ = {}
    for i = 0, numObj - 1 do
        table_[i + 1] = intProc(tbuff, i * intSize)
    end
    local plistInfo = {
        RAF = raf,
        RefSize = refSize,
        RefProc = refProc,
        Table = table_,
        TagTablePtr = tagTablePtr,
    }
    -- position file pointer at the top object, and extract it
    if not raf:Seek(table_[topObj + 1], 0) then return 0 end
    dirInfo.Value = ExtractObject(et, plistInfo)
    return dirInfo.Value ~= nil and 1 or 0
end

--------------------------------------------------------------------------------
-- Extract information from a PLIST file (binary, XML or JSON format)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, 0 if this wasn't valid PLIST
--------------------------------------------------------------------------------
function PLIST.ProcessPLIST(et, dirInfo, tagTablePtr)
    tagTablePtr = tagTablePtr or et:GetTagTable('lexiftool.PLIST.Main')
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart or 0
    local notXML

    if dataPt then
        if dataPt:sub(start + 1, start + 1) ~= '<' then notXML = 1 end
    else
        local raf = dirInfo.RAF
        if not raf then return 0 end
        if not raf:Seek(0, 0) then return 0 end
        dataPt = raf:ReadFile()
        if #dataPt == 0 then return 0 end
        dirInfo.DataPt = dataPt
        dirInfo.DirStart = 0
        dirInfo.DirLen = #dataPt
        start = 0
    end

    if not notXML and dataPt:sub(start + 1, start + 7) ~= 'bplist0' then
        -- process XML PLIST data using the XMP module. Upstream's real
        -- ProcessXMP (given a bare RAF, not a DataPt) disambiguates real
        -- XMP/RDF content from a genuine PLIST/generic-XML file itself, by
        -- content, before this port's DetectFileType ever runs (its own
        -- %magicNumber entry for XMP is nearly as permissive as PLIST's own
        -- "starts with whitespace then '<'" test) -- this port's
        -- DetectFileType instead hard-codes PLIST for anything '<'-led, so
        -- the distinction is made here instead: a leading "<?xpacket
        -- begin=" or "<x:xmpmeta"/"<xmp:xapmeta" (upstream's own `$hasXMP`
        -- test) means this is really a standalone XMP file, not PLIST.
        local probe = dataPt:sub(start + 1, start + 64)
        local isXMP = probe:match('^[ \t\n\r\f\v]*<%?xpacket begin=') or probe:match('^[ \t\n\r\f\v]*<x:xmpmeta') or
            probe:match('^[ \t\n\r\f\v]*<xmp:xapmeta') or
            probe:match('^[ \t\n\r\f\v]*<%?xml[^\n]*\n[ \t\n\r\f\v]*<rdf:RDF') or probe:match('^[ \t\n\r\f\v]*<rdf:RDF')
        local result
        if isXMP then
            -- real XMP/RDF content: use XMP's own default tag-building
            -- logic, not PLIST.FoundTag's dict/key/array-specific parsing
            et:SetFileType('XMP', 'application/rdf+xml')
            result = XMP.ProcessXMP(et, dirInfo, et:GetTagTable('lexiftool.XMP.Main'))
        else
            et:SetFileType('PLIST', 'application/xml')
            dirInfo.XMPParseOpts = { FoundProc = PLIST.FoundTag }
            result = XMP.ProcessXMP(et, dirInfo, tagTablePtr)
            dirInfo.XMPParseOpts = nil
        end
        if result ~= 0 then return result end
    end
    if dataPt:sub(start + 1, start + 7) == 'bplist0' then -- binary PLIST
        -- binary PLIST file
        et:SetFileType('PLIST', 'application/x-plist')
        et.SET_GROUP1 = 'PLIST'
        if PLIST.ProcessBinaryPLIST(et, dirInfo, tagTablePtr) == 0 then
            et:Error('Error reading binary PLIST file')
        end
        et.SET_GROUP1 = nil
        return 1
    end
    -- JSON PLIST and old UCS-2BE PLIST formats are not ported (not exercised)
    return 0
end

PLIST.Main.PROCESS_PROC = PLIST.ProcessPLIST

return PLIST
