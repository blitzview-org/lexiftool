--------------------------------------------------------------------------------
-- File:         lexiftool/OpenEXR.lua
-- Ported from:  lib/Image/ExifTool/OpenEXR.pm
--
-- Description:  Read OpenEXR meta information
--
-- Revisions:    2011/12/10 - P. Harvey Created
--               2023/01/31 - PH Added support for multipart images
--
-- References:   1) http://www.openexr.com/
--
-- Port notes:   Complete port of OpenEXR.pm.  An attribute value Perl keeps
--               as a SCALAR reference (undef binary data, the "Binary data N
--               bytes" placeholder) is a `{ ref = 'SCALAR', value = ... }`
--               box, and Perl's `next` in the attribute loop is a
--               `goto continue`.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local str = perl.str
local uc, ucfirst = perl.uc, perl.ucfirst
local matches, matchesDyn, isMatch = perl.matches, perl.matchesDyn, perl.isMatch
local eachMatch, subst, tr = perl.eachMatch, perl.subst, perl.tr
local substr, length, unpack, push = perl.substr, perl.length, perl.unpack, perl.push
local perlTruthy = ExifTool.perlTruthy
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ReadValue = ExifTool.ReadValue
local Get8u, Get32u = ExifTool.Get8u, ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder

local OpenEXR = {}

-- supported EXR value format types (other types are extracted as undef binary data)
local formatType = {
    box2f          = 'float[4]',
    box2i          = 'int32s[4]',
    chlist         = 1,
    chromaticities = 'float[8]',
    compression    = 'int8u',
    double         = 'double',
    envmap         = 'int8u',
    float          = 'float',
    ['int']        = 'int32s',
    keycode        = 'int32s[7]',
    lineOrder      = 'int8u',
    m33f           = 'float[9]',
    m44f           = 'float[16]',
    rational       = 'rational64s',
    string         = 'string', -- incorrect in specification! (no leading int)
    stringvector   = 1,
    tiledesc       = 1,
    timecode       = 'int32u[2]',
    v2f            = 'float[2]',
    v2i            = 'int32s[2]',
    v3f            = 'float[3]',
    v3i            = 'int32s[3]',
}

-- OpenEXR tags (upstream %Image::ExifTool::OpenEXR::Main)
OpenEXR.Main = {
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        Information extracted from EXR images.  Use the ExtractEmbedded option to
        extract information from all frames of a multipart image.  See
        L<http://www.openexr.com/> for the official specification.
    ]],
    _ver = { Name = 'EXRVersion', Notes = 'low byte of Flags word' },
    _flags = {
        Name = 'Flags',
        PrintConv = { BITMASK = {
            [9] = 'Tiled',
            [10] = 'Long names',
            [11] = 'Deep data',
            [12] = 'Multipart',
        } },
    },
    adoptedNeutral = {},
    altitude = {
        Name = 'GPSAltitude',
        Groups = { [2] = 'Location' },
        PrintConv = function(_self, val)
            val = math.floor(val * 10) / 10
            local neg = str(val):match('^-')
            local s = str(math.abs(val))
            return (neg and (s .. ' m Below') or (s .. ' m Above')) .. ' Sea Level'
        end,
    },
    aperture = { PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    channels = {},
    chromaticities = {},
    capDate = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    comments = {},
    compression = {
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'None',
            [1] = 'RLE',
            [2] = 'ZIPS',
            [3] = 'ZIP',
            [4] = 'PIZ',
            [5] = 'PXR24',
            [6] = 'B44',
            [7] = 'B44A',
            [8] = 'DWAA',
            [9] = 'DWAB',
        },
    },
    dataWindow = {},
    displayWindow = {},
    envmap = {
        Name = 'EnvironmentMap',
        PrintConv = {
            [0] = 'Latitude/Longitude',
            [1] = 'Cube',
        },
    },
    expTime = {
        Name = 'ExposureTime',
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
    focus = {
        Name = 'FocusDistance',
        PrintConv = function(_self, val) return perl.str(val) .. ' m' end,
    },
    framesPerSecond = {},
    keyCode = {},
    isoSpeed = { Name = 'ISO' },
    latitude = {
        Name = 'GPSLatitude',
        Groups = { [2] = 'Location' },
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    lineOrder = {
        PrintConv = {
            [0] = 'Increasing Y',
            [1] = 'Decreasing Y',
            [2] = 'Random Y',
        },
    },
    longitude = {
        Name = 'GPSLongitude',
        Groups = { [2] = 'Location' },
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    lookModTransform = {},
    multiView = {},
    owner = { Groups = { [2] = 'Author' } },
    pixelAspectRatio = {},
    preview = { Groups = { [2] = 'Preview' } },
    renderingTransform = {},
    screenWindowCenter = {},
    screenWindowWidth = {},
    tiles = {},
    timeCode = {},
    utcOffset = {
        Name = 'TimeZone',
        Groups = { [2] = 'Time' },
        PrintConv = function(_self, val) return ExifTool.TimeZoneString(val / 60) end,
    },
    whiteLuminance = {},
    worldToCamera = {},
    worldToNDC = {},
    wrapmodes = { Name = 'WrapModes' },
    xDensity = { Name = 'XResolution' },
    name = {},
    type = {},
    version = {},
    chunkCount = {},
    exif = {
        Name = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            Start = 4, -- (skip leading 4 bytes with data length)
        },
    },
    xmp = {
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

--------------------------------------------------------------------------------
-- Extract information from an OpenEXR file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid OpenEXR file
function OpenEXR.ProcessEXR(et, dirInfo)
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local binary = et:Options('Binary')
    if not perlTruthy(binary) then binary = verbose end
    local buff, dim, n

    -- verify this is a valid RIFF file
    n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    if not isMatch(buff, [[(?s)^\x76\x2f\x31\x01]]) then return 0 end
    et:SetFileType()
    SetByteOrder('II')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.OpenEXR.Main')

    -- extract information from header
    local flags = unpack('x4V', buff)
    et:HandleTag(tagTablePtr, '_ver', flags & 0xff)
    et:HandleTag(tagTablePtr, '_flags', flags & 0xffffff00)
    local maxLen = (flags & 0x400) ~= 0 and 255 or 31
    local multi = flags & 0x1000

    -- extract attributes
    while true do -- (upstream `for (;;)`)
        n, buff = raf:Read((maxLen + 1) * 2 + 5)
        if n == 0 then break end
        if isMatch(buff, [[^\0]]) then
            if not (multi ~= 0 and perlTruthy(et:Options('ExtractEmbedded'))) then break end
            -- remove null and process the next frame header as a sub-document
            -- (second null is end of all headers)
            local nulls = matches(buff, [[^(\0+)]])
            buff = subst(buff, [[^(\0+)]], '')
            if nulls and length(nulls) > 1 then break end
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
        end
        local c1, c2, c3, pos = matchesDyn(buff, [[(?s)^([^\0]{1,]] .. maxLen .. [[})\0([^\0]{1,]] .. maxLen .. [[})\0(.{4})]])
        if not c1 then
            et:Warn('EXR format error')
            break
        end
        local tag, type_, size = c1, c2, unpack('V', c3)
        if not raf:Seek(pos - length(buff), 1) then
            et:Warn('Seek error')
            break
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not tagInfo then
            local name = ucfirst(tag)
            name = subst(name, [[([^a-zA-Z])([a-z])]], function(m1, m2) return m1 .. uc(m2) end, 'g') -- capitalize first letter of each word
            name = tr(name, '-_a-zA-Z0-9', '', 'dc')
            if length(name) <= 1 then
                if length(name) ~= 0 then
                    name = 'Tag' .. name
                else
                    name = 'Invalid'
                end
            end
            tagInfo = { Name = name }
            AddTagToTable(et, tagTablePtr, tag, tagInfo)
            et:VPrint(0, et.INDENT, '[adding ' .. tag .. ']\n')
        end
        local val, success, buf2
        local format = formatType[type_]
        local subdir = tagInfo.SubDirectory
        if format or perlTruthy(binary) or subdir then
            n, buf2 = raf:Read(size)
            if n == size then success = 1 end
            if subdir then
                et:HandleTag(tagTablePtr, tag, nil, {
                    DataPt = buf2, DataPos = raf:Tell() - length(buf2) })
                if success then goto continue end
            elseif not format then
                val = { ref = 'SCALAR', value = buf2 }  -- treat as undef binary data
            elseif format ~= 1 then
                -- handle formats which map nicely into ExifTool format codes
                local fmt, cnt = matches(format, [[^(\w+)\[?(\d*)]])
                if fmt then
                    if not perlTruthy(cnt) then cnt = fmt == 'string' and size or 1 end
                    val = ReadValue(buf2, 0, fmt, perl.num(cnt), size)
                end
            -- handle other format types
            elseif type_ == 'tiledesc' then
                if size >= 9 then
                    local x = Get32u(buf2, 0)
                    local y = Get32u(buf2, 4)
                    local mode = Get8u(buf2, 8)
                    local lvl = ({ [0] = 'One Level', [1] = 'MIMAP Levels', [2] = 'RIPMAP Levels' })[mode & 0x0f]
                    if not lvl then lvl = 'Unknown Levels (' .. (mode & 0xf) .. ')' end
                    local rnd = ({ [0] = 'Round Down', [1] = 'Round Up' })[mode >> 4]
                    if not rnd then rnd = 'Unknown Rounding (' .. (mode >> 4) .. ')' end
                    val = x .. 'x' .. y .. '; ' .. lvl .. '; ' .. rnd
                end
            elseif type_ == 'chlist' then
                val = { }
                for str_, dat in eachMatch(buf2, [[(?s)\G([^\0]{1,31})\0(.{16})]]) do
                    local pix, lin, x, y = unpack('VCx3VV', dat)
                    pix = ({ [0] = 'int8u', [1] = 'half', [2] = 'float' })[pix] or ('unknown(' .. pix .. ')')
                    push(val, str_ .. ' ' .. pix .. (lin ~= 0 and ' linear' or '') .. ' ' .. x .. ' ' .. y)
                end
            elseif type_ == 'stringvector' then
                val = { }
                local pos2 = 0
                while pos2 + 4 <= length(buf2) do
                    local len = Get32u(buf2, pos2)
                    if pos2 + 4 + len > length(buf2) then break end
                    push(val, substr(buf2, pos2 + 4, len))
                    pos2 = pos2 + 4 + len
                end
            else
                val = { ref = 'SCALAR', value = buf2 }  -- (shouldn't happen)
            end
        else
            -- avoid loading binary data
            val = { ref = 'SCALAR', value = 'Binary data ' .. size .. ' bytes' }
            success = raf:Seek(size, 1)
        end
        if not perlTruthy(success) then
            et:Warn('Truncated or corrupted EXR file')
            break
        end
        if val == nil then val = '<bad>' end

        -- take image dimensions from dataWindow (with displayWindow as backup)
        if tag == 'dataWindow' or (not dim and tag == 'displayWindow') then
            local x1, y1, x2, y2 = matches(val, [[^(-?\d+) (-?\d+) (-?\d+) (-?\d+)$]])
            if x1 and not perlTruthy(et.DOC_NUM) then
                dim = { x2 - x1 + 1, y2 - y1 + 1 }
            end
        end
        if perlTruthy(verbose) then
            local dataPt = (type(val) == 'table' and val.ref == 'SCALAR') and val.value or buf2
            et:VerboseInfo(tag, tagInfo, {
                Table   = tagTablePtr,
                Value   = val,
                Size    = size,
                Format  = type_,
                DataPt  = dataPt,
                Addr    = raf:Tell() - size,
            })
        end
        et:FoundTag(tagInfo, val)
        ::continue::
    end
    et.DOC_NUM = nil
    if dim then
        et:FoundTag('ImageWidth', dim[1])
        et:FoundTag('ImageHeight', dim[2])
    end
    return 1
end

return OpenEXR
