--------------------------------------------------------------------------------
-- File:         lexiftool/FLAC.lua
-- Ported from:  lib/Image/ExifTool/FLAC.pm
--
-- Description:  Read Free Lossless Audio Codec information
--
-- Revisions:    11/13/2006 - P. Harvey Created
--
-- References:   1) http://flac.sourceforge.net/
--
-- Port notes:   read subset. Ported: ProcessBitStream (the generic
--               "BitNNN-MMM" tag-table processor, also reused by AAC.lua),
--               ProcessFLAC (the whole-file metadata-block walker),
--               Main/StreamInfo/Picture tables (including the
--               `Application_riff` branch, which dispatches an embedded RIFF
--               block into RIFF.Main), and the Duration composite.
--               Deferred (not exercised by the vendored images): the ID3
--               leading/trailing scan gating.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local matches = require('lexiftool.perl').matches
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local tsort = perl.tsort
local str = perl.str

local FLAC = {}

--------------------------------------------------------------------------------
-- Read a directory of bit-packed tags with "BitNNN-MMM" (or "BitNNN") keys
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table
-- Returns: 1 on success
--------------------------------------------------------------------------------
function FLAC.ProcessBitStream(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (#dataPt - dirStart)
    local verbose = et:Options('Verbose')
    local byteOrder = ExifTool.GetByteOrder()

    if perl.truthy(verbose) then
        et:VPrint(0, '  + [BitStream directory, ' .. dirLen .. " bytes, '" .. byteOrder .. "' order]\n")
    end

    -- extract known tags in tag-name order (upstream: `sort keys %$tagTablePtr`)
    local tags = {}
    for k in pairs(tagTablePtr) do
        if not ExifTool.specialTags[k] and str(k):match('^Bit%d') then
            tags[#tags + 1] = k
        end
    end
    tsort(tags)

    for _, tag in ipairs(tags) do
        local b1, b2 = matches(str(tag), [[^Bit(\d+)-?(\d+)?]])
        b1 = tonumber(b1)
        b2 = (b2 and b2 ~= '' and tonumber(b2)) or b1
        local i1, i2 = b1 // 8, b2 // 8 -- start/end byte numbers
        local f1, f2 = b1 % 8, b2 % 8 -- start/end bit numbers within each byte
        if i2 >= dirLen then break end

        local tagInfo = tagTablePtr[tag]
        local val
        local extra
        if type(tagInfo) ~= 'table' or not tagInfo.Format then
            val = 0
            local mask
            if perl.truthy(verbose) and (f1 ~= 0 or f2 ~= 7) then extra = ', Mask=0x' end
            if byteOrder == 'MM' then
                -- loop from high byte to low byte
                for i = i1, i2 do
                    mask = 0xff
                    if i == i1 and f1 ~= 0 then
                        -- mask off high bits in first word (0 is high bit)
                        for b = 8 - f1, 7 do mask = mask ~ (1 << b) end
                    end
                    if i == i2 and f2 < 7 then
                        -- mask off low bits in last word (7 is low bit)
                        for b = 0, 6 - f2 do mask = mask ~ (1 << b) end
                    end
                    val = val * 256 + (mask & ExifTool.Get8u(dataPt, i + dirStart))
                    if extra then extra = extra .. sprintf('%.2x', mask) end
                end
            else
                -- (FLAC is big-endian, but support little-endian bit streams
                --  so this routine can be used by other modules)
                for i = i2, i1, -1 do
                    mask = 0xff
                    if i == i1 and f1 ~= 0 then
                        -- mask off low bits in first word (0 is low bit)
                        for b = 0, f1 - 1 do mask = mask ~ (1 << b) end
                    end
                    if i == i2 and f2 < 7 then
                        -- mask off high bits in last word (7 is high bit)
                        for b = f2 + 1, 7 do mask = mask ~ (1 << b) end
                    end
                    val = val * 256 + (mask & ExifTool.Get8u(dataPt, i + dirStart))
                    if extra then extra = extra .. sprintf('%.2x', mask) end
                end
            end
            -- shift word down until low bit is in position 0
            while mask & 0x01 == 0 do
                val = val // 2
                mask = mask >> 1
            end
        end
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            DataPos = dataPos,
            Start = dirStart + i1,
            Size = i2 - i1 + 1,
            Extra = extra,
        })
    end
    return 1
end

-- FLAC metadata blocks (upstream %Image::ExifTool::FLAC::Main)
FLAC.Main = {
    NOTES = [[
        Free Lossless Audio Codec (FLAC) meta information.  ExifTool also extracts
        ID3 information from these files.
    ]],
    [0] = {
        Name = 'StreamInfo',
        SubDirectory = { TagTable = 'lexiftool.FLAC.StreamInfo' },
    },
    [1] = { Name = 'Padding', Binary = 1, Unknown = 1 },
    [2] = { { -- (see forum14064)
        Name = 'Application_riff',
        Condition = function(_self, val) return matches(val, [[^riff(?!RIFF)]]) ~= nil end, -- (all "riff" blocks but header)
        SubDirectory = {
            TagTable = 'lexiftool.RIFF.Main',
            ByteOrder = 'LittleEndian',
            Start = 4,
        },
    }, {
        Name = 'ApplicationUnknown',
        Binary = 1,
        Unknown = 1,
    } },
    [3] = { Name = 'SeekTable', Binary = 1, Unknown = 1 },
    [4] = {
        Name = 'VorbisComment',
        SubDirectory = { TagTable = 'lexiftool.Vorbis.Comments' },
    },
    [5] = { Name = 'CueSheet', Binary = 1, Unknown = 1 },
    [6] = {
        Name = 'Picture',
        SubDirectory = { TagTable = 'lexiftool.FLAC.Picture' },
    },
}

-- FLAC stream information (upstream %FLAC::StreamInfo)
FLAC.StreamInfo = {
    PROCESS_PROC = FLAC.ProcessBitStream,
    NOTES = 'FLAC is big-endian, so bit 0 is the high-order bit in this table.',
    GROUPS = { [2] = 'Audio' },
    ['Bit000-015'] = 'BlockSizeMin',
    ['Bit016-031'] = 'BlockSizeMax',
    ['Bit032-055'] = 'FrameSizeMin',
    ['Bit056-079'] = 'FrameSizeMax',
    ['Bit080-099'] = 'SampleRate',
    ['Bit100-102'] = {
        Name = 'Channels',
        ValueConv = function(_self, val) return val + 1 end,
    },
    ['Bit103-107'] = {
        Name = 'BitsPerSample',
        ValueConv = function(_self, val) return val + 1 end,
    },
    ['Bit108-143'] = 'TotalSamples',
    ['Bit144-271'] = { -- Tim Eliseo
        Name = 'MD5Signature',
        Format = 'undef',
        ValueConv = function(_self, val)
            local out = {}
            for i = 1, #val do out[#out + 1] = string.format('%02x', val:byte(i)) end
            return table.concat(out)
        end,
    },
}

-- FLAC picture block (upstream %FLAC::Picture)
FLAC.Picture = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int32u',
    [0] = {
        Name = 'PictureType',
        PrintConv = { -- (Note: Duplicated in ID3, ASF and FLAC modules!)
            [0] = 'Other',
            [1] = '32x32 PNG Icon',
            [2] = 'Other Icon',
            [3] = 'Front Cover',
            [4] = 'Back Cover',
            [5] = 'Leaflet',
            [6] = 'Media',
            [7] = 'Lead Artist',
            [8] = 'Artist',
            [9] = 'Conductor',
            [10] = 'Band',
            [11] = 'Composer',
            [12] = 'Lyricist',
            [13] = 'Recording Studio or Location',
            [14] = 'Recording Session',
            [15] = 'Performance',
            [16] = 'Capture from Movie or Video',
            [17] = 'Bright(ly) Colored Fish',
            [18] = 'Illustration',
            [19] = 'Band Logo',
            [20] = 'Publisher Logo',
        },
    },
    [1] = {
        Name = 'PictureMIMEType',
        Format = 'var_pstr32',
    },
    [2] = {
        Name = 'PictureDescription',
        Format = 'var_pstr32',
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end,
    },
    [3] = 'PictureWidth',
    [4] = 'PictureHeight',
    [5] = 'PictureBitsPerPixel',
    [6] = 'PictureIndexedColors',
    [7] = 'PictureLength',
    [8] = {
        Name = 'Picture',
        Groups = { [2] = 'Preview' },
        Format = 'undef[$val{7}]',
        Binary = 1,
    },
}

-- FLAC composite tags (upstream %FLAC::Composite)
FLAC.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    Duration = {
        TagID = 'FLAC-Duration',
        Require = {
            [0] = 'FLAC:SampleRate',
            [1] = 'FLAC:TotalSamples',
        },
        ValueConv = function(_self, val)
            -- (Perl truthiness: a 0 SampleRate/TotalSamples must not build;
            --  composite inputs arrive as ValueConv'd strings)
            if not (val[0] and val[0] ~= 0 and val[0] ~= '0' and val[1] and val[1] ~= 0 and val[1] ~= '0') then return nil end
            return val[1] / val[0]
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.FLAC', nil, FLAC)

--------------------------------------------------------------------------------
-- Extract information from an Ogg FLAC file (upstream ProcessFLAC, read
-- subset: no ID3 leading/trailing scan)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid FLAC file
--------------------------------------------------------------------------------
function FLAC.ProcessFLAC(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(4)
    if n ~= 4 or buff ~= 'fLaC' then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('MM')
    local tagTablePtr = et:GetTagTable('lexiftool.FLAC.Main')
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout
    local err
    for _ = 1, 128 do
        -- read next metadata block header
        local hn, hBuff = raf:Read(4)
        if hn ~= 4 then break end
        local flag = hBuff:byte(1)
        local size = perl.unpack('N', hBuff) & 0x00ffffff
        local dn, dBuff = raf:Read(size)
        if dn ~= size then err = 1 break end
        local last = flag & 0x80 -- last-metadata-block flag
        local tag = flag & 0x7f -- tag bits
        if perl.truthy(verbose) then
            out:write('FLAC metadata block, type ' .. tag .. ':\n')
            et:VerboseDump(dBuff, { DataPos = raf:Tell() - size })
        end
        et:HandleTag(tagTablePtr, tag, dBuff, {
            DataPt = dBuff,
            DataPos = raf:Tell() - size,
            Start = 0,
            Size = size,
        })
        if last ~= 0 then break end -- all done if last-metadata-block flag set
    end
    if err then et:Warn('Format error in FLAC file') end
    return 1
end

return FLAC
