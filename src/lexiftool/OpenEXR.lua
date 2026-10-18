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
-- Port notes:   read subset. Ported: the Main table, ProcessEXR (the
--               header/attribute reader with the %formatType value-format
--               mapping, tiledesc/chlist/stringvector special cases, and
--               the dataWindow-derived ImageWidth/ImageHeight). Deferred
--               (unexercised): multipart images (ExtractEmbedded), the
--               embedded EXIF/XMP subdirectories, verbose dumps.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local str = perl.str
local uc, ucfirst = perl.uc, perl.ucfirst

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
-- Extract information from an OpenEXR file (upstream ProcessEXR, read
-- subset without the multipart/ExtractEmbedded and verbose branches)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid OpenEXR file
--------------------------------------------------------------------------------
function OpenEXR.ProcessEXR(et, dirInfo)
    local raf = dirInfo.RAF
    local binary = perl.truthy(et.OPTIONS.Binary) and et.OPTIONS.Binary or et.OPTIONS.Verbose

    -- verify this is a valid OpenEXR file
    local n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    if buff:sub(1, 4) ~= '\118\47\49\1' then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('II')
    local tagTablePtr = et:GetTagTable('lexiftool.OpenEXR.Main')

    -- extract information from header
    local flags = perl.unpack('V', buff:sub(5, 8))
    et:HandleTag(tagTablePtr, '_ver', flags & 0xff)
    et:HandleTag(tagTablePtr, '_flags', flags & 0xffffff00)
    local maxLen = (flags & 0x400) ~= 0 and 255 or 31

    -- extract attributes
    local dim
    for _ = 1, 100000 do
        local bn, b2 = raf:Read((maxLen + 1) * 2 + 5)
        if not (bn and bn > 0) then break end
        -- (multipart/sub-document handling deferred -- the vendored file is
        --  single-part, so a leading null means end of headers)
        if b2:sub(1, 1) == '\0' then break end
        -- parse: name\0 type\0 size(4)
        local name, type_, size = b2:match('^([^\0]-)\0([^\0]-)\0(....)')
        if not name then
            et:Warn('EXR format error')
            break
        end
        size = perl.unpack('V', size)
        -- seek back to just after the size field (the read may have pulled
        -- in more bytes than the attribute header; upstream seeks back by
        -- `length($buff) - pos($buff)`)
        local consumed = #name + 1 + #type_ + 1 + 4
        if not raf:Seek(-(#b2 - consumed), 1) then
            et:Warn('Seek error')
            break
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, name)
        if not tagInfo then
            -- dynamic tag creation
            local nm = ucfirst(name)
            nm = nm:gsub('([^a-zA-Z])([a-z])', function(a, c) return a .. uc(c) end)
            nm = nm:gsub('[^%-_a-zA-Z0-9]', '')
            if #nm <= 1 then
                nm = (#nm == 1 and ('Tag' .. nm) or 'Invalid')
            end
            tagInfo = { Name = nm }
            et:AddTagToTable(tagTablePtr, name, tagInfo)
        end
        local val, success, buf2
        local fmt = formatType[type_]
        local subdir = tagInfo.SubDirectory
        if fmt or binary or subdir then
            local dn, d2 = raf:Read(size)
            success = dn == size
            buf2 = d2
            if subdir then
                et:HandleTag(tagTablePtr, name, nil, {
                    DataPt = buf2,
                    DataPos = raf:Tell() - #buf2,
                })
                if success then goto continueAttr end
            elseif not fmt then
                val = { ref = 'SCALAR', value = buf2 } -- treat as undef binary data
            elseif fmt ~= 1 then
                -- handle formats which map nicely into ExifTool format codes
                local fmt2, cnt = fmt:match('^([A-Za-z0-9]+)%[?(%d*)')
                if fmt2 then
                    if cnt == '' then cnt = fmt2 == 'string' and size or 1 end
                    val = ExifTool.ReadValue(buf2, 0, fmt2, tonumber(cnt), size)
                end
            -- handle other format types
            elseif type_ == 'tiledesc' then
                if size >= 9 then
                    local x = ExifTool.Get32u(buf2, 0)
                    local y = ExifTool.Get32u(buf2, 4)
                    local mode = ExifTool.Get8u(buf2, 8)
                    local lvl = ({ [0] = 'One Level', [1] = 'MIMAP Levels', [2] = 'RIPMAP Levels' })[mode & 0x0f]
                    lvl = lvl or ('Unknown Levels (' .. (mode & 0xf) .. ')')
                    local rnd = ({ [0] = 'Round Down', [1] = 'Round Up' })[mode >> 4]
                    rnd = rnd or ('Unknown Rounding (' .. (mode >> 4) .. ')')
                    val = x .. 'x' .. y .. '; ' .. lvl .. '; ' .. rnd
                end
            elseif type_ == 'chlist' then
                val = {}
                local pos = 1
                while true do
                    local cname = buf2:match('^([^\0]-)\0', pos)
                    if not cname then break end
                    local dataStart = pos + #cname
                    local dat = buf2:sub(dataStart + 1, dataStart + 16)
                    if #dat < 16 then break end
                    -- (upstream `unpack('VCx3VV', $dat)`: pix=V(0),
                    --  lin=C(4), x=V(8), y=V(12))
                    local pix = ExifTool.Get32u(dat, 0)
                    local lin = ExifTool.Get8u(dat, 4)
                    local x = ExifTool.Get32u(dat, 8)
                    local y = ExifTool.Get32u(dat, 12)
                    pix = ({ [0] = 'int8u', [1] = 'half', [2] = 'float' })[pix] or ('unknown(' .. pix .. ')')
                    val[#val + 1] = cname .. ' ' .. pix .. (lin ~= 0 and ' linear' or '') .. ' ' .. x .. ' ' .. y
                    pos = dataStart + 17
                end
            elseif type_ == 'stringvector' then
                val = {}
                local pos = 0
                while pos + 4 <= #buf2 do
                    local len = ExifTool.Get32u(buf2, pos)
                    if pos + 4 + len > #buf2 then break end
                    val[#val + 1] = buf2:sub(pos + 5, pos + 4 + len)
                    pos = pos + 4 + len
                end
            else
                val = { ref = 'SCALAR', value = buf2 } -- (shouldn't happen)
            end
        else
            -- avoid loading binary data
            val = { ref = 'SCALAR', value = 'Binary data ' .. size .. ' bytes' }
            success = raf:Seek(size, 1)
        end
        if not success then
            et:Warn('Truncated or corrupted EXR file')
            break
        end
        if val == nil then val = '<bad>' end

        -- take image dimensions from dataWindow (with displayWindow as backup)
        if (name == 'dataWindow' or (not dim and name == 'displayWindow')) and
            str(val):match('^(-?%d+) (-?%d+) (-?%d+) (-?%d+)$') then
            local x1, y1, x2, y2 = str(val):match('^(-?%d+) (-?%d+) (-?%d+) (-?%d+)$')
            dim = { tonumber(x2) - tonumber(x1) + 1, tonumber(y2) - tonumber(y1) + 1 }
        end
        et:FoundTag(tagInfo, val)
        ::continueAttr::
    end
    if dim then
        et:FoundTag('ImageWidth', dim[1])
        et:FoundTag('ImageHeight', dim[2])
    end
    return 1
end

return OpenEXR