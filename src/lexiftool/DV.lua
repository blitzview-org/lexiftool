--------------------------------------------------------------------------------
-- File:         lexiftool/DV.lua
-- Ported from:  lib/Image/ExifTool/DV.pm
--
-- Description:  Read DV meta information
--
-- Revisions:    2010/12/24 - P. Harvey Created
--
-- References:   1) http://www.ffmpeg.org/
--               2) http://dvswitch.alioth.debian.org/wiki/DV_format/
--
-- Port notes:   read port: the Main table plus ProcessDV. The local findStart
--               helper has no upstream counterpart -- it locates the DIF block
--               start that Perl finds inline. Upstream DV.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf
local lt = require('lexiftool.perl').lt

local DV = {}

-- DV profiles (ref 1)
local dvProfiles = {
    {
        DSF = 0, VideoSType = 0x0, FrameSize = 120000,
        VideoFormat = 'IEC 61834, SMPTE-314M - 525/60 (NTSC)',
        Colorimetry = '4:1:1', FrameRate = 30000 / 1001,
        ImageHeight = 480, ImageWidth = 720,
    },
    {
        DSF = 1, VideoSType = 0x0, FrameSize = 144000,
        VideoFormat = 'IEC 61834 - 625/50 (PAL)',
        Colorimetry = '4:2:0', FrameRate = 25 / 1,
        ImageHeight = 576, ImageWidth = 720,
    },
    {
        DSF = 1, VideoSType = 0x0, FrameSize = 144000,
        VideoFormat = 'SMPTE-314M - 625/50 (PAL)',
        Colorimetry = '4:1:1', FrameRate = 25 / 1,
        ImageHeight = 576, ImageWidth = 720,
    },
    {
        DSF = 0, VideoSType = 0x4, FrameSize = 240000,
        VideoFormat = 'DVCPRO50: SMPTE-314M - 525/60 (NTSC) 50 Mbps',
        Colorimetry = '4:2:2', FrameRate = 30000 / 1001,
        ImageHeight = 480, ImageWidth = 720,
    },
    {
        DSF = 1, VideoSType = 0x4, FrameSize = 288000,
        VideoFormat = 'DVCPRO50: SMPTE-314M - 625/50 (PAL) 50 Mbps',
        Colorimetry = '4:2:2', FrameRate = 25 / 1,
        ImageHeight = 576, ImageWidth = 720,
    },
    {
        DSF = 0, VideoSType = 0x14, FrameSize = 480000,
        VideoFormat = 'DVCPRO HD: SMPTE-370M - 1080i60 100 Mbps',
        Colorimetry = '4:2:2', FrameRate = 30000 / 1001,
        ImageHeight = 1080, ImageWidth = 1280,
    },
    {
        DSF = 1, VideoSType = 0x14, FrameSize = 576000,
        VideoFormat = 'DVCPRO HD: SMPTE-370M - 1080i50 100 Mbps',
        Colorimetry = '4:2:2', FrameRate = 25 / 1,
        ImageHeight = 1080, ImageWidth = 1440,
    },
    {
        DSF = 0, VideoSType = 0x18, FrameSize = 240000,
        VideoFormat = 'DVCPRO HD: SMPTE-370M - 720p60 100 Mbps',
        Colorimetry = '4:2:2', FrameRate = 60000 / 1001,
        ImageHeight = 720, ImageWidth = 960,
    },
    {
        DSF = 1, VideoSType = 0x18, FrameSize = 288000,
        VideoFormat = 'DVCPRO HD: SMPTE-370M - 720p50 100 Mbps',
        Colorimetry = '4:2:2', FrameRate = 50 / 1,
        ImageHeight = 720, ImageWidth = 960,
    },
    {
        DSF = 1, VideoSType = 0x1, FrameSize = 144000,
        VideoFormat = 'IEC 61883-5 - 625/50 (PAL)',
        Colorimetry = '4:2:0', FrameRate = 25 / 1,
        ImageHeight = 576, ImageWidth = 720,
    },
}

-- tags to extract, in the order we want to extract them
local dvTags = {
    'DateTimeOriginal', 'ImageWidth', 'ImageHeight', 'Duration',
    'TotalBitrate', 'VideoFormat', 'VideoScanType', 'FrameRate',
    'AspectRatio', 'Colorimetry', 'AudioChannels', 'AudioSampleRate',
    'AudioBitsPerSample',
}

-- DV tags
DV.Main = {
    GROUPS = { [2] = 'Video' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'The following tags are extracted from DV videos.',
    DateTimeOriginal = {
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ImageWidth = {},
    ImageHeight = {},
    Duration = { PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end },
    TotalBitrate = { PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    VideoFormat = {},
    VideoScanType = {},
    FrameRate = { PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end },
    AspectRatio = {},
    Colorimetry = {},
    AudioChannels = { Groups = { [2] = 'Audio' } },
    AudioSampleRate = { Groups = { [2] = 'Audio' } },
    AudioBitsPerSample = { Groups = { [2] = 'Audio' } },
}

-- find the start of the first DIF sequence header (upstream's two-stage
-- regex search); Returns: 0-based start offset, or nil
local function findStart(buff)
    local m = buff:find('\31\7\0[\63\191]')
    if m then return m - 1 end
    local pat = '[\0\255]\63\7\0' .. string.rep('.', 76) .. '\255\63\7\1'
    local searchFrom = 1
    while true do
        local m1 = buff:find(pat, searchFrom)
        if not m1 then return nil end
        local start0 = m1 - 80
        if start0 >= 0 then return start0 end
        searchFrom = m1 + 1
    end
end

--------------------------------------------------------------------------------
-- Read information in a DV file (ref 1)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid DV file
--------------------------------------------------------------------------------
function DV.ProcessDV(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(12000)
    if n == 0 then return 0 end

    local start = findStart(buff)
    if not start then return 0 end
    local len = #buff
    -- must at least have a full DIF header
    if start + 80 * 6 > len then return 0 end

    et:SetFileType()

    local pos = start
    local dsf = (ExifTool.Get8u(buff, pos + 3) & 0x80) >> 7
    local stype = ExifTool.Get8u(buff, pos + 80 * 5 + 48 + 3) & 0x1f

    local profile
    -- 576i50 25Mbps 4:1:1 is a special case
    if dsf == 1 and stype == 0 and ExifTool.Get8u(buff, 4) & 0x07 ~= 0 then
        profile = dvProfiles[3] -- (Lua 1-based: dvProfiles[2] in Perl's 0-based list)
    else
        for _, p in ipairs(dvProfiles) do
            if dsf == p.DSF and stype == p.VideoSType then
                profile = p
                break
            end
        end
        if not profile then
            et:Warn('Unrecognized DV profile')
            return 1
        end
    end
    local tagTablePtr = et:GetTagTable('lexiftool.DV.Main')

    -- calculate total bit rate and duration
    local byteRate = profile.FrameSize * profile.FrameRate
    local fileSize = et.VALUE.FileSize
    profile.TotalBitrate = 8 * byteRate
    if fileSize then profile.Duration = fileSize / byteRate end

    -- read DVPack metadata from the VAUX DIF's to extract video tags
    profile.DateTimeOriginal = nil
    profile.AspectRatio = nil
    profile.VideoScanType = nil
    local date, time, is16_9, interlace
    for _ = 1, 5 do
        pos = pos + 80
        local dtype = ExifTool.Get8u(buff, pos)
        if dtype & 0xf0 == 0x50 then -- look for VAUX types
            for j = 0, 14 do
                local p = pos + j * 5 + 3
                dtype = ExifTool.Get8u(buff, p)
                if dtype == 0x61 then -- video control
                    local apt = ExifTool.Get8u(buff, start + 4) & 0x07
                    local t = ExifTool.Get8u(buff, p + 2)
                    is16_9 = (t & 0x07) == 0x02 or (apt == 0 and (t & 0x07) == 0x07)
                    interlace = ExifTool.Get8u(buff, p + 3) & 0x10 -- (ref 2)
                elseif dtype == 0x62 then -- date
                    -- mask off unused bits
                    -- luacheck: ignore 211
                    local d1, d2, d3, d4 = buff:byte(p + 2, p + 5)
                    -- (ignore timezone in byte 0 until we can test this properly - see ref 2)
                    date = sprintf('%.2x:%.2x:%.2x', d4, d3 & 0x1f, d2 & 0x3f)
                    if date:match('[a-f]') then
                        date = nil -- invalid date
                    else
                        -- add century (this will work until 2089)
                        date = (lt(date, '9') and '20' or '19') .. date
                    end
                    time = nil
                elseif dtype == 0x63 and date then -- time
                    -- (ignore frames past second in byte 0 for now - see ref 2)
                    -- luacheck: ignore 211
                    local t1, t2, t3, t4 = buff:byte(p + 2, p + 5)
                    time = sprintf('%.2x:%.2x:%.2x', t4 & 0x3f, t3 & 0x7f, t2 & 0x7f)
                    break
                else
                    time = nil -- must be consecutive
                end
            end
        end
    end
    if date and time then
        profile.DateTimeOriginal = date .. ' ' .. time
        if is16_9 ~= nil then
            profile.AspectRatio = is16_9 and '16:9' or '4:3'
            profile.VideoScanType = (interlace and interlace ~= 0) and 'Interlaced' or 'Progressive'
        end
    end

    -- read audio tags if available
    profile.AudioSampleRate = nil
    profile.AudioBitsPerSample = nil
    profile.AudioChannels = nil
    pos = start + 80 * 6 + 80 * 16 * 3 + 3
    if pos + 4 < len and ExifTool.Get8u(buff, pos) == 0x50 then
        local freq = (ExifTool.Get8u(buff, pos + 4) >> 3) & 0x07
        local astype = ExifTool.Get8u(buff, pos + 3) & 0x1f
        local quant = ExifTool.Get8u(buff, pos + 4) & 0x07
        if freq < 3 then
            profile.AudioSampleRate = ({ [0] = 48000, [1] = 44100, [2] = 32000 })[freq]
        end
        if astype < 3 then
            if astype == 0 and quant ~= 0 and freq == 2 then astype = 2 end
            profile.AudioChannels = ({ [0] = 2, [1] = 0, [2] = 4, [3] = 8 })[astype]
        end
        profile.AudioBitsPerSample = quant ~= 0 and 12 or 16
    end

    -- save our metadata
    for _, tag in ipairs(dvTags) do
        if profile[tag] ~= nil then et:HandleTag(tagTablePtr, tag, profile[tag]) end
    end

    return 1
end

return DV
