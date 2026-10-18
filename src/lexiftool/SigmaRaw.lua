--------------------------------------------------------------------------------
-- File:         lexiftool/SigmaRaw.lua
-- Ported from:  lib/Image/ExifTool/SigmaRaw.pm
--
-- Description:  Read Sigma/Foveon RAW (X3F) meta information
--
-- Revisions:    2005/10/16 - P. Harvey Created
--               2009/11/30 - P. Harvey Support X3F v2.3 written by Sigma DP2
--
-- References:   1) http://www.x3f.info/technotes/FileDocs/X3F_Format.pdf
--
-- Port notes:   read-path subset (Sigma.t tests 4/5). The X3F container reader
--               (`ProcessX3F`/`ProcessX3FDirectory`/`ProcessX3FHeader`/
--               `ProcessX3FProperties`), the `Main`/`Header`/`Header4`/
--               `HeaderExt`/`Properties` tables, and the `ExtractUnicodeString`
--               helper are ported in full. The write path (`WriteX3F`) is
--               ported in full, as is the `ImageDataHash` block; the
--               verbose-only `VerboseDir`/`VerboseDump`/`VPrint` calls are not.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local unpack_ = perl.unpack
local substr = perl.substr
local sprintf = perl.sprintf
local tsort = perl.tsort
local str = perl.str
local carray = require('carray')
local lc, ucfirst = perl.lc, perl.ucfirst

local SigmaRaw = {}

-- (upstream: `use Image::ExifTool::Sigma;` for %sigmaLensTypes -- an eager
--  require here would reorder the Composite build for every file, so the
--  lookup is reached through a proxy that loads Sigma.lua on first use)
local sigmaLensTypes = setmetatable({}, {
    __index = function(_, k) return require('lexiftool.Sigma').sigmaLensTypes[k] end,
    __pairs = function() return pairs(require('lexiftool.Sigma').sigmaLensTypes) end,
})

-- main X3F sections (plus header stuff)
SigmaRaw.Main = {
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return SigmaRaw.ProcessX3FDirectory(et, dirInfo, tagTablePtr) end,
    NOTES = [[
        These tags are used in Sigma and Foveon RAW (.X3F) images.  Metadata is also
        extracted from the JpgFromRaw image if it exists (all models but the SD9 and
        SD10).  Currently, metadata may only be written to the embedded JpgFromRaw.
    ]],
    Header = {
        SubDirectory = { TagTable = 'lexiftool.SigmaRaw.Header' },
    },
    Header4 = {
        SubDirectory = { TagTable = 'lexiftool.SigmaRaw.Header4' },
    },
    HeaderExt = {
        SubDirectory = { TagTable = 'lexiftool.SigmaRaw.HeaderExt' },
    },
    PROP = {
        Name = 'Properties',
        SubDirectory = { TagTable = 'lexiftool.SigmaRaw.Properties' },
    },
    IMAG = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    IMA2 = {
        {
            Name = 'PreviewImage',
            Condition = function(self) return not self.IsJpgFromRaw end,
            Groups = { [2] = 'Preview' },
            Binary = 1,
        },
        {
            Name = 'JpgFromRaw',
            Groups = { [2] = 'Preview' },
            Binary = 1,
        },
    },
}

-- common X3F header structure
SigmaRaw.Header = {
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return SigmaRaw.ProcessX3FHeader(et, dirInfo, tagTablePtr) end,
    FORMAT = 'int32u',
    NOTES = 'Information extracted from the header of an X3F file.',
    [1] = {
        Name = 'FileVersion',
        ValueConv = function(_self, val)
            return math.floor(val / 65536) .. '.' .. (val & 0xffff)
        end,
    },
    [2] = {
        Name = 'ImageUniqueID',
        -- the serial number (with an extra leading "0") makes up
        -- the first 8 digits of this UID,
        Format = 'undef[16]',
        ValueConv = function(_self, val)
            local out = {}
            for i = 1, #val do out[#out + 1] = string.format('%02x', val:byte(i)) end
            return table.concat(out)
        end,
    },
    [6] = {
        Name = 'MarkBits',
        PrintConv = { BITMASK = {} },
    },
    [7] = 'ImageWidth',
    [8] = 'ImageHeight',
    [9] = 'Rotation',
    [10] = {
        Name = 'WhiteBalance',
        Format = 'string[32]',
    },
    [18] = { -- #PH (DP2, FileVersion 2.3)
        Name = 'SceneCaptureType',
        Format = 'string[32]',
    },
}

-- X3F version 4 header structure (ref PH)
SigmaRaw.Header4 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int32u',
    NOTES = 'Header information for version 4.0 or greater X3F.',
    [1] = {
        Name = 'FileVersion',
        ValueConv = function(_self, val)
            return math.floor(val / 65536) .. '.' .. (val & 0xffff)
        end,
    },
    -- 8 - undef[4]: 4 random ASCII characters
    [10] = 'ImageWidth',
    [11] = 'ImageHeight',
    [12] = 'Rotation',
    -- don't know what the rest of the header contains, but none of
    -- these values change in any of my samples...
}

-- extended header tags
SigmaRaw.HeaderExt = {
    GROUPS = { [2] = 'Camera' },
    FORMAT = 'float',
    NOTES = 'Extended header data found in version 2.1 and 2.2 files',
    [0] = 'Unused',
    [1] = { Name = 'ExposureAdjust', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [2] = { Name = 'Contrast', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [3] = { Name = 'Shadow', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [4] = { Name = 'Highlight', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [5] = { Name = 'Saturation', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [6] = { Name = 'Sharpness', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [7] = { Name = 'RedAdjust', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [8] = { Name = 'GreenAdjust', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [9] = { Name = 'BlueAdjust', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
    [10] = { Name = 'X3FillLight', PrintConv = function(_self, val) return sprintf('%.1f', val) end },
}

-- PROP tags
SigmaRaw.Properties = {
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return SigmaRaw.ProcessX3FProperties(et, dirInfo, tagTablePtr) end,
    GROUPS = { [2] = 'Camera' },
    PRIORITY = 0, -- (because these aren't writable like the EXIF ones)
    AEMODE = {
        Name = 'MeteringMode',
        PrintConv = {
            ['8'] = '8-segment',
            C = 'Center-weighted average',
            A = 'Average',
        },
    },
    AFAREA = 'AFArea', -- observed: CENTER_V
    AFINFOCUS = 'AFInFocus', -- observed: H
    AFMODE = 'FocusMode',
    AP_DESC = 'ApertureDisplayed',
    APERTURE = {
        Name = 'FNumber',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    BRACKET = 'BracketShot',
    BURST = 'BurstShot',
    CAMMANUF = 'Make',
    CAMMODEL = 'Model',
    CAMNAME = 'CameraName',
    CAMSERIAL = 'SerialNumber',
    CM_DESC = 'SceneCaptureType', -- #PH (DP2)
    COLORSPACE = 'ColorSpace', -- observed: sRGB
    DRIVE = {
        Name = 'DriveMode',
        PrintConv = {
            SINGLE = 'Single Shot',
            MULTI = 'Multi Shot',
            ['2S'] = '2 s Timer',
            ['10S'] = '10 s Timer',
            UP = 'Mirror Up',
            AB = 'Auto Bracket',
            OFF = 'Off',
        },
    },
    EVAL_STATE = 'EvalState', -- observed: POST-EXPOSURE
    EXPCOMP = {
        Name = 'ExposureCompensation',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintFraction(val) end,
    },
    EXPNET = {
        Name = 'NetExposureCompensation',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintFraction(val) end,
    },
    EXPTIME = {
        Name = 'IntegrationTime',
        Groups = { [2] = 'Image' },
        ValueConv = function(_self, val) return val * 1e-6 end, -- convert from usec
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
    FIRMVERS = 'FirmwareVersion',
    FLASH = {
        Name = 'FlashMode',
        PrintConv = function(_self, val)
            return ucfirst(lc(val))
        end,
    },
    FLASHEXPCOMP = 'FlashExpComp',
    FLASHPOWER = 'FlashPower',
    FLASHTTLMODE = 'FlashTTLMode', -- observed: ON
    FLASHTYPE = 'FlashType', -- observed: NONE
    FLENGTH = {
        Name = 'FocalLength',
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
    },
    FLEQ35MM = {
        Name = 'FocalLengthIn35mmFormat',
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
    },
    FOCUS = {
        Name = 'Focus',
        PrintConv = {
            AF = 'Auto-focus Locked',
            ['NO LOCK'] = "Auto-focus Didn't Lock",
            M = 'Manual',
        },
    },
    IMAGERBOARDID = 'ImagerBoardID',
    IMAGERTEMP = {
        Name = 'SensorTemperature',
        PrintConv = function(_self, val) return str(val) .. ' C' end,
    },
    IMAGEBOARDID = 'ImageBoardID', -- #PH (DP2)
    ISO = 'ISO',
    LENSARANGE = 'LensApertureRange',
    LENSFRANGE = 'LensFocalRange',
    LENSMODEL = {
        Name = 'LensType',
        ValueConv = function(_self, val)
            if str(val):match('^[0-9a-f]+$') then
                local n = tonumber(str(val), 16)
                return n or val
            end
            return val
        end,
        ValueConvInv = function(_self, val)
            val = perl.subst(val, [[\.\d+$]], '')
            if ExifTool.IsInt(val) then return sprintf('%x', val) end
            return val
        end,
        SeparateTable = 'Sigma LensType',
        PrintHex = 1,
        PrintConv = sigmaLensTypes,
    },
    PMODE = {
        Name = 'ExposureProgram',
        PrintConv = {
            P = 'Program',
            A = 'Aperture Priority',
            S = 'Shutter Priority',
            M = 'Manual',
        },
    },
    RESOLUTION = {
        Name = 'Quality',
        PrintConv = {
            LOW = 'Low',
            MED = 'Medium',
            HI = 'High',
        },
    },
    SENSORID = 'SensorID',
    SH_DESC = 'ShutterSpeedDisplayed',
    SHUTTER = {
        Name = 'ExposureTime',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
    TIME = {
        Name = 'DateTimeOriginal',
        Groups = { [2] = 'Time' },
        Description = 'Date/Time Original',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    WB_DESC = 'WhiteBalance',
    VERSION_BF = 'VersionBF',
}

--------------------------------------------------------------------------------
-- Extract null-terminated unicode string from list of characters
-- Inputs: 0) ExifTool ref, 1) list ref, 2) position in list
-- Returns: Converted string
--------------------------------------------------------------------------------
function SigmaRaw.ExtractUnicodeString(et, chars, pos)
    local i = pos
    while chars[i] ~= nil do -- ($i<@$chars)
        -- (`last unless $$chars[$i]`: stop at the null terminator -- 0 is
        --  false in Perl, but true in Lua)
        if not ExifTool.perlTruthy(chars[i]) then break end
        i = i + 1
    end
    local out = {}
    for j = pos, i - 1 do out[#out + 1] = chars[j] end
    -- pack 'v*' -- little-endian uint16 values
    local parts = {}
    for _, v in ipairs(out) do parts[#parts + 1] = string.pack('<I2', v) end
    return et:Decode(table.concat(parts), 'UTF16', 'II')
end

--------------------------------------------------------------------------------
-- Process an X3F header
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function SigmaRaw.ProcessX3FHeader(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local hdrLen = dirInfo.DirLen

    -- process the static header structure first
    ExifTool.ProcessBinaryData(et, dirInfo, tagTablePtr)

    -- process extended data if available
    if #dataPt - hdrLen >= 160 then
        local headerExtTable = et:GetTagTable('lexiftool.SigmaRaw.HeaderExt')
        local tags = { unpack_('C32', dataPt, hdrLen) }
        local unused = 0
        for i = 1, 32 do
            local t = tags[i]
            if not t or t == 0 then
                unused = unused + 1
            else
                et:HandleTag(headerExtTable, t, nil, {
                    Index = i - 1,
                    DataPt = dataPt,
                    Start = hdrLen + 32 + (i - 1) * 4,
                    Size = 4,
                })
            end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process an X3F properties
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function SigmaRaw.ProcessX3FProperties(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local size = #dataPt
    local unknown = et.OPTIONS.Unknown

    if not (size >= 24 and dataPt:sub(1, 4) == 'SECp') then
        et:Warn('Bad properties header')
        return 0
    end
    local entries, fmt, len = unpack_('x8V2x4V', dataPt)
    if size < 24 + 8 * entries + len then
        et:Warn('Truncated Property directory')
        return 0
    end
    if fmt ~= 0 then
        et:Warn('Unsupported character format ' .. str(fmt))
        return 0
    end
    local charPos = 24 + 8 * entries
    local chars = { unpack_('v' .. len, dataPt, charPos) }
    for index = 0, entries - 1 do
        local namePos, valPos = unpack_('V2', dataPt, index * 8 + 24)
        if namePos >= #chars or valPos >= #chars then
            et:Warn('Bad Property pointer')
            return 0
        end
        local tag = SigmaRaw.ExtractUnicodeString(et, chars, namePos + 1)
        local val = SigmaRaw.ExtractUnicodeString(et, chars, valPos + 1)
        if not tagTablePtr[tag] and perl.truthy(unknown) and tag:match('^[A-Za-z0-9]+$') then
            local tagInfo = {
                Name = 'SigmaRaw_' .. tag,
                Description = ExifTool.MakeDescription('SigmaRaw', tag),
                Unknown = 1,
                Writable = 0, -- can't write unknown tags
            }
            -- add tag information to table
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end

        et:HandleTag(tagTablePtr, tag, val, {
            Index = index,
            DataPt = dataPt,
            Start = charPos + 2 * valPos,
            Size = 2 * (#val + 1),
        })
    end
    return 1
end

--------------------------------------------------------------------------------
-- Write an X3F file
-- Inputs: 0) ExifTool ref, 1) DirInfo ref (DirStart = directory offset)
-- Returns: error string, nil on success, or -1 on write error
-- Notes: Writes metadata to embedded JpgFromRaw image
--------------------------------------------------------------------------------
function SigmaRaw.WriteX3F(et, dirInfo)
    local Writer = require('lexiftool.Writer')
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local outPos, didContain
    local order, orderList = { }, { }

    if not raf:Seek(dirInfo.DirStart, 0) then return 'Error seeking to directory start' end

    -- read the X3F directory header (will be copied directly to output)
    local n, hdr = raf:Read(12)
    if n ~= 12 then return 'Truncated X3F image' end
    if hdr:sub(1, 4) ~= 'SECd' then return 'Bad section header' end
    local _, entries = unpack_('x4V2', hdr)

    -- do sanity check on number of entries in directory
    if not (entries > 2 and entries < 20) then return 'Invalid X3F directory count' end
    -- read the directory entries
    local n2, dir = raf:Read(entries * 12)
    if n2 ~= entries * 12 then return 'Truncated X3F directory' end
    -- do a quick scan to determine the offset of the first data subsection,
    -- and the order in which the actual data is stored in the file
    local bad
    for index = 0, entries - 1 do
        local pos = index * 12
        local offset = unpack_('x' .. pos .. 'V2a4', dir)
        -- remember position of first data subsection
        if outPos == nil or outPos > offset then outPos = offset end
        -- save the order of the data
        if order[offset] ~= nil then bad = 1 end
        order[offset] = index
    end
    -- copy the file header up to the start of the first data subsection
    if not raf:Seek(0, 0) then return 'Error reading X3F header' end
    local n3, buff = raf:Read(outPos)
    if n3 ~= outPos then return 'Error reading X3F header' end
    if not Writer.Write(outfile, buff) then return -1 end

    -- this is a bit tricky/unfortunate:  the current version of Sigma Photo Pro
    -- (2022-10-18) is sensitive to the order of the data sections, and these may
    -- differ from the order of their respective entries in the footer.  To patch
    -- this, instead of looping through the footer sections in order, we process
    -- them in the order of the offsets they contain, writing their referenced data
    -- sequentially as we go.  This preserves both the order of the data sections
    -- and the order of the footer entries.  (Note that the upcoming release of
    -- Sigma Photo Pro will fix this issue at their end, but this patch will remain
    -- to maintain backward compatibilty with older SPP versions.)
    if bad then
        -- (this could perhaps happen if any of the sections is ever zero-length)
        et:Error('Double-referenced data in footer directory!', 1)
        for index = 0, entries - 1 do orderList[#orderList + 1] = index end
    else
        local offsets = { }
        for offset in pairs(order) do offsets[#offsets + 1] = offset end
        tsort(offsets)
        for _, offset in ipairs(offsets) do orderList[#orderList + 1] = order[offset] end
    end

    -- loop through footer directory, rewriting each section
    for _, index in ipairs(orderList) do

        local pos = index * 12
        local offset, len, tag = unpack_('x' .. pos .. 'V2a4', dir)
        if not raf:Seek(offset, 0) then return 'Bad data offset' end

        if tag == 'IMA2' and len > 28 then
            -- check subsection header (28 bytes) to see if this is a JPEG preview image
            local n4, b = raf:Read(28)
            if n4 ~= 28 then return 'Error reading PreviewImage header' end
            if not Writer.Write(outfile, b) then return -1 end
            len = len - 28

            -- only rewrite full-sized JpgFromRaw (version 2.0, type 2, format 18)
            -- (upstream pattern `/^SECi\0\0\x02\0\x02\0\0\0\x12\0\0\0/`, spelled
            --  out as in ProcessX3FDirectory above)
            if b:sub(1, 4) == 'SECi' and b:sub(5, 8) == '\0\0\x02\0'
                and b:sub(9, 12) == '\x02\0\0\0' and b:sub(13, 16) == '\x12\0\0\0' then
                local n5, img = raf:Read(len)
                if n5 ~= len then return 'Error reading JpgFromRaw' end
                if img:sub(1, 4) == '\255\216\255\225' then -- does this preview contain EXIF?
                    -- use same write directories as JPEG
                    Writer.InitWriteDirs(et, 'JPEG')
                    -- make sure we don't add APP0 JFIF because it would mess up our preview identification
                    et.ADD_DIRS.APP0 = nil
                    et.ADD_DIRS.JFIF = nil
                    -- rewrite the embedded JPEG in memory
                    -- (`\$newData` is the box { value = <carray> }, doc/api.md §4)
                    local newData = carray.new('char')
                    local jpegInfo = {
                        Parent  = 'X3F',
                        RAF     = require('lexiftool.RandomAccess').new(img),
                        OutFile = { value = newData },
                    }
                    et.FILE_TYPE = 'JPEG'
                    local success = et:WriteJPEG(jpegInfo)
                    et.FILE_TYPE = 'X3F'
                    ExifTool.SetByteOrder('II')
                    if not (perl.truthy(success) and perl.truthy(newData)) then
                        return 'Error writing X3F JpgFromRaw'
                    end
                    if success < 0 then return -1 end
                    -- (this shouldn't happen unless someone tries to delete the EXIF...)
                    if not perl.isMatch(newData, [[^\xff\xd8\xff\xe1]]) then
                        return 'EXIF segment must come first in X3F JpgFromRaw'
                    end
                    -- trim off any extra null bytes (since section length includes padding -- silly Sigma)
                    perl.subst(newData, [[\0+$]], '')
                    -- write new data if anything changed, otherwise copy old image
                    local outPt = perl.truthy(et.CHANGED) and newData or img
                    if not Writer.Write(outfile, outPt) then return -1 end
                    -- set len to the total subsection data length
                    len = perl.length(outPt)
                    didContain = 1
                else
                    if not Writer.Write(outfile, img) then return -1 end
                end
            else
                -- copy original image data
                if Writer.CopyBlock(raf, outfile, len) ~= 1 then return 'Corrupted X3F image' end
            end
            len = len + 28      -- add back header length
        else
            -- copy data for this subsection
            if Writer.CopyBlock(raf, outfile, len) ~= 1 then return 'Corrupted X3F directory' end
        end
        -- pad data to an even 4-byte boundary
        -- (stored length includes padding! ref Sigma engineer Yuki Miyahara)
        if len & 0x03 ~= 0 then
            local pad = 4 - (len & 0x03)
            if not Writer.Write(outfile, string.rep('\0', pad)) then return -1 end
            len = len + pad
        end
        -- update footer entry with new offset/size
        dir = dir:sub(1, pos) .. perl.pack('V2', outPos, len) .. dir:sub(pos + 9)
        outPos = outPos + len
    end
    -- warn if we couldn't add metadata to this image (should only be SD9 or SD10)
    if not didContain then et:Warn("Can't yet write SD9 or SD10 X3F images") end
    -- write out the directory and the directory pointer, and we are done
    if not Writer.Write(outfile, hdr, dir, perl.pack('V', outPos)) then return -1 end
    return nil
end

--------------------------------------------------------------------------------
-- Process an X3F directory
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: error string or nil on success
--------------------------------------------------------------------------------
function SigmaRaw.ProcessX3FDirectory(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF

    if not raf:Seek(dirInfo.DirStart, 0) then return 'Error seeking to directory start' end

    -- parse the X3F directory structure
    local n, buff = raf:Read(12)
    if n ~= 12 then return 'Truncated X3F image' end
    if buff:sub(1, 4) ~= 'SECd' then return 'Bad section header' end
    local _, entries = unpack_('x4V2', buff)
    local n2, dir = raf:Read(entries * 12)
    if n2 ~= entries * 12 then return 'Truncated X3F directory' end
    for index = 0, entries - 1 do
        local pos = index * 12
        local offset, len, tag = unpack_('x' .. pos .. 'V2a4', dir)
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo then
            if not raf:Seek(offset, 0) then return 'Error seeking for ' .. str(tagInfo.Name) end
            if tagInfo.Name == 'PreviewImage' then
                -- check image header to see if this is a JPEG preview image
                local n3, b = raf:Read(28)
                if n3 ~= 28 then return 'Error reading PreviewImage header' end
                offset = offset + 28
                len = len - 28
                -- ignore all image data but JPEG compressed (version 2.0, type 2, format 18)
                -- (upstream pattern `/^SECi\0\0\x02\0\x02\0\0\0\x12\0\0\0/`;
                --  spelled out as explicit substring comparisons -- version,
                --  type and format are each little-endian int32 fields)
                if not (b:sub(1, 4) == 'SECi' and b:sub(5, 8) == '\0\0\x02\0'
                    and b:sub(9, 12) == '\x02\0\0\0' and b:sub(13, 16) == '\x12\0\0\0') then
                    -- do hash on non-preview data if requested
                    -- (rawget: the member, not the method of that name)
                    if rawget(et, 'ImageDataHash') and substr(b, 8, 1) ~= '\x02' then
                        et:ImageDataHash(raf, len, 'SigmaRaw IMAG')
                    end
                    goto continue
                end
                local n4, b2 = raf:Read(len)
                if n4 ~= len then return 'Error reading PreviewImage data' end
                buff = b2
                -- check for EXIF segment, and extract this image as the JpgFromRaw
                if buff:sub(1, 4) == '\255\216\255\225' then
                    et.IsJpgFromRaw = 1
                    tagInfo = et:GetTagInfo(tagTablePtr, tag)
                    et.IsJpgFromRaw = nil
                end
            else
                local n5, b3 = raf:Read(len)
                if n5 ~= len then return 'Error reading ' .. str(tagInfo.Name) .. ' data' end
                buff = b3
            end
            local subdir = tagInfo.SubDirectory
            if subdir then
                local subInfo = { DataPt = buff }
                local subTable = et:GetTagTable(subdir.TagTable)
                et:ProcessDirectory(subInfo, subTable)
            else
                -- extract metadata from JpgFromRaw
                if tagInfo.Name == 'JpgFromRaw' then
                    local subInfo = {
                        Parent = 'X3F',
                        RAF = require('lexiftool.RandomAccess').new(buff),
                    }
                    et.BASE = (et.BASE or 0) + offset
                    et:ProcessJPEG(subInfo)
                    et.BASE = (et.BASE or 0) - offset
                    ExifTool.SetByteOrder('II')
                end
                et:FoundTag(tagInfo, buff)
            end
            ::continue::
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Read/write information from a Sigma raw (X3F) image
-- Inputs: 0) ExifTool ref, 1) DirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid X3F image, or -1 on write error
--------------------------------------------------------------------------------
function SigmaRaw.ProcessX3F(et, dirInfo)
    local outfile = dirInfo.OutFile
    local raf = dirInfo.RAF
    -- (upstream picks the reporting method up front: Error when writing,
    --  Warn when reading)
    local warn = outfile and ExifTool.Error or ExifTool.Warn
    local n, buff = raf:Read(40)
    if n ~= 40 then return 0 end
    if buff:sub(1, 4) ~= 'FOVb' then return 0 end

    ExifTool.SetByteOrder('II')
    et:SetFileType()

    -- check version number
    local ver = unpack_('x4V', buff)
    ver = math.floor(ver / 65536) .. '.' .. (ver & 0xffff)
    if tonumber(ver) > 5 then
        warn(et, 'Untested X3F version (' .. str(ver) .. '). Please submit sample for testing', 1)
    end
    -- read version 2.1/2.2/2.3 extended header
    local hdrLen
    if tonumber(ver) > 2 then
        local extra
        if tonumber(ver) >= 4 then
            hdrLen = 0x300
            extra = 0
        else
            hdrLen = tonumber(ver) > 2.2 and 104 or 72 -- SceneCaptureType string added in 2.3
            extra = 160 -- (extended header is 160 bytes)
        end
        local more = hdrLen - #buff + extra
        local n2, buf2 = raf:Read(more)
        if n2 ~= more then
            warn(et, 'Error reading X3F header')
            return 1
        end
        buff = buff .. buf2
    end
    local hdrType = tonumber(ver) < 4 and 'Header' or 'Header4'
    -- process header information
    local mainTable = et:GetTagTable('lexiftool.SigmaRaw.Main')
    if not outfile then
        et:HandleTag(mainTable, hdrType, buff, {
            DataPt = buff,
            Size = hdrLen,
        })
    end
    -- read the directory pointer
    if not raf:Seek(-4, 2) then
        warn(et, 'Seek error')
        return 1
    end
    local n3, ptr = raf:Read(4)
    if n3 ~= 4 then
        warn(et, 'Error reading X3F dir pointer')
        return 1
    end
    local offset = unpack_('V', ptr)
    local dirInfo2 = {
        RAF = raf,
        DirStart = offset,
    }
    local err
    if outfile then
        dirInfo2.OutFile = outfile
        err = SigmaRaw.WriteX3F(et, dirInfo2)
        if err == -1 then return -1 end
    else
        -- process the X3F subsections
        err = et:ProcessDirectory(dirInfo2, mainTable)
    end
    if err then warn(et, str(err)) end
    return 1
end

return SigmaRaw
