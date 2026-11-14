--------------------------------------------------------------------------------
-- File:         lexiftool/MPEG.lua
-- Ported from:  lib/Image/ExifTool/MPEG.pm
--
-- Description:  Read MPEG-1 and MPEG-2 meta information
--
-- Revisions:    05/11/2006 - P. Harvey Created
--
-- References:   1) http://www.mp3-tech.org/
--               2) http://www.getid3.org/
--               3) http://dvd.sourceforge.net/dvdinfo/dvdmpeg.html
--               4) http://ffmpeg.org/
--               5) http://sourceforge.net/projects/mediainfo/
--
-- Port notes:   Complete port of MPEG.pm: every table and sub, in upstream
--               order (MPEG.pm is read-only; it has no write code).
--               Deviations forced by Lua:
--               - The Composite ValueConv gets @prt as its third argument
--                 (`function(self, val, prt)`), as upstream evaluates it
--                 with @val and @prt.
--               - Perl keeps the regex position pos($$buffPt) on the
--                 string; the /g scans of ParseMPEGAudio and
--                 ParseMPEGAudioVideo carry it in a local (`buffPos`), fed
--                 to and returned by `matches`.
--               - Perl's `$type` is `type_`.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local length = perl.length
local substr = perl.substr
local unpack = perl.unpack
local index = perl.index
local sort = perl.sort
local keys = perl.keys
local int = perl.int
local num = perl.num
local str = perl.str
local truthy = perl.truthy
local GetTagTable = ExifTool.GetTagTable
local ConvertBitrate = ExifTool.ConvertBitrate
local ConvertDuration = ExifTool.ConvertDuration

local MPEG = {}

MPEG.Audio = {
    GROUPS = { [2] = 'Audio' },
    ['Bit11-12'] = {
        Name = 'MPEGAudioVersion',
        RawConv = function(self, val) self.MPEG_Vers = val return val end,
        PrintConv = {
            [0] = 2.5,
            [2] = 2,
            [3] = 1,
        },
    },
    ['Bit13-14'] = {
        Name = 'AudioLayer',
        RawConv = function(self, val) self.MPEG_Layer = val return val end,
        PrintConv = {
            [1] = 3,
            [2] = 2,
            [3] = 1,
        },
    },
    -- Bit 15 indicates CRC protection
    ['Bit16-19'] = {
        {
            Name = 'AudioBitrate',
            Condition = function(self) return num(self.MPEG_Vers) == 3 and num(self.MPEG_Layer) == 3 end,
            Notes = 'version 1, layer 1',
            PrintConvColumns = 3,
            ValueConv = {
                [0] = 'free',
                [1] = 32000,
                [2] = 64000,
                [3] = 96000,
                [4] = 128000,
                [5] = 160000,
                [6] = 192000,
                [7] = 224000,
                [8] = 256000,
                [9] = 288000,
                [10] = 320000,
                [11] = 352000,
                [12] = 384000,
                [13] = 416000,
                [14] = 448000,
            },
            PrintConv = function(_self, val) return ConvertBitrate(val) end,
        },
        {
            Name = 'AudioBitrate',
            Condition = function(self) return num(self.MPEG_Vers) == 3 and num(self.MPEG_Layer) == 2 end,
            Notes = 'version 1, layer 2',
            PrintConvColumns = 3,
            ValueConv = {
                [0] = 'free',
                [1] = 32000,
                [2] = 48000,
                [3] = 56000,
                [4] = 64000,
                [5] = 80000,
                [6] = 96000,
                [7] = 112000,
                [8] = 128000,
                [9] = 160000,
                [10] = 192000,
                [11] = 224000,
                [12] = 256000,
                [13] = 320000,
                [14] = 384000,
            },
            PrintConv = function(_self, val) return ConvertBitrate(val) end,
        },
        {
            Name = 'AudioBitrate',
            Condition = function(self) return num(self.MPEG_Vers) == 3 and num(self.MPEG_Layer) == 1 end,
            Notes = 'version 1, layer 3',
            PrintConvColumns = 3,
            ValueConv = {
                [0] = 'free',
                [1] = 32000,
                [2] = 40000,
                [3] = 48000,
                [4] = 56000,
                [5] = 64000,
                [6] = 80000,
                [7] = 96000,
                [8] = 112000,
                [9] = 128000,
                [10] = 160000,
                [11] = 192000,
                [12] = 224000,
                [13] = 256000,
                [14] = 320000,
            },
            PrintConv = function(_self, val) return ConvertBitrate(val) end,
        },
        {
            Name = 'AudioBitrate',
            Condition = function(self) return num(self.MPEG_Vers) ~= 3 and num(self.MPEG_Layer) == 3 end,
            Notes = 'version 2 or 2.5, layer 1',
            PrintConvColumns = 3,
            ValueConv = {
                [0] = 'free',
                [1] = 32000,
                [2] = 48000,
                [3] = 56000,
                [4] = 64000,
                [5] = 80000,
                [6] = 96000,
                [7] = 112000,
                [8] = 128000,
                [9] = 144000,
                [10] = 160000,
                [11] = 176000,
                [12] = 192000,
                [13] = 224000,
                [14] = 256000,
            },
            PrintConv = function(_self, val) return ConvertBitrate(val) end,
        },
        {
            Name = 'AudioBitrate',
            Condition = function(self) return num(self.MPEG_Vers) ~= 3 and truthy(self.MPEG_Layer) end,
            Notes = 'version 2 or 2.5, layer 2 or 3',
            PrintConvColumns = 3,
            ValueConv = {
                [0] = 'free',
                [1] = 8000,
                [2] = 16000,
                [3] = 24000,
                [4] = 32000,
                [5] = 40000,
                [6] = 48000,
                [7] = 56000,
                [8] = 64000,
                [9] = 80000,
                [10] = 96000,
                [11] = 112000,
                [12] = 128000,
                [13] = 144000,
                [14] = 160000,
            },
            PrintConv = function(_self, val) return ConvertBitrate(val) end,
        },
    },
    ['Bit20-21'] = {
        {
            Name = 'SampleRate',
            Condition = function(self) return num(self.MPEG_Vers) == 3 end,
            Notes = 'version 1',
            PrintConv = {
                [0] = 44100,
                [1] = 48000,
                [2] = 32000,
            },
        },
        {
            Name = 'SampleRate',
            Condition = function(self) return num(self.MPEG_Vers) == 2 end,
            Notes = 'version 2',
            PrintConv = {
                [0] = 22050,
                [1] = 24000,
                [2] = 16000,
            },
        },
        {
            Name = 'SampleRate',
            Condition = function(self) return num(self.MPEG_Vers) == 0 end,
            Notes = 'version 2.5',
            PrintConv = {
                [0] = 11025,
                [1] = 12000,
                [2] = 8000,
            },
        },
    },
    -- Bit 22 - padding flag
    -- Bit 23 - private bit
    ['Bit24-25'] = {
        Name = 'ChannelMode',
        RawConv = function(self, val) self.MPEG_Mode = val return val end,
        PrintConv = {
            [0] = 'Stereo',
            [1] = 'Joint Stereo',
            [2] = 'Dual Channel',
            [3] = 'Single Channel',
        },
    },
    ['Bit26'] = {
        Name = 'MSStereo',
        Condition = function(self) return num(self.MPEG_Layer) == 1 end,
        Notes = 'layer 3',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    ['Bit27'] = {
        Name = 'IntensityStereo',
        Condition = function(self) return num(self.MPEG_Layer) == 1 end,
        Notes = 'layer 3',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    ['Bit26-27'] = {
        Name = 'ModeExtension',
        Condition = function(self) return num(self.MPEG_Layer) > 1 end,
        Notes = 'layer 1 or 2',
        PrintConv = {
            [0] = 'Bands 4-31',
            [1] = 'Bands 8-31',
            [2] = 'Bands 12-31',
            [3] = 'Bands 16-31',
        },
    },
    ['Bit28']    = {
        Name = 'CopyrightFlag',
        PrintConv = {
            [0] = 'False',
            [1] = 'True',
        },
    },
    ['Bit29']    = {
        Name = 'OriginalMedia',
        PrintConv = {
            [0] = 'False',
            [1] = 'True',
        },
    },
    ['Bit30-31'] = {
        Name = 'Emphasis',
        PrintConv = {
            [0] = 'None',
            [1] = '50/15 ms',
            [2] = 'reserved',
            [3] = 'CCIT J.17',
        },
    },
}

MPEG.Video = {
    GROUPS = { [2] = 'Video' },
    ['Bit00-11'] = 'ImageWidth',
    ['Bit12-23'] = 'ImageHeight',
    ['Bit24-27'] = {
        Name = 'AspectRatio',
        ValueConv = {
            [1] = 1,
            [2] = 0.6735,
            [3] = 0.7031,
            [4] = 0.7615,
            [5] = 0.8055,
            [6] = 0.8437,
            [7] = 0.8935,
            [8] = 0.9157,
            [9] = 0.9815,
            [10] = 1.0255,
            [11] = 1.0695,
            [12] = 1.0950,
            [13] = 1.1575,
            [14] = 1.2015,
        },
        PrintConv = {
            [1]      = '1:1',
            [0.6735] = '0.6735',
            [0.7031] = '16:9, 625 line, PAL',
            [0.7615] = '0.7615',
            [0.8055] = '0.8055',
            [0.8437] = '16:9, 525 line, NTSC',
            [0.8935] = '0.8935',
            [0.9157] = '4:3, 625 line, PAL, CCIR601',
            [0.9815] = '0.9815',
            [1.0255] = '1.0255',
            [1.0695] = '1.0695',
            [1.0950] = '4:3, 525 line, NTSC, CCIR601',
            [1.1575] = '1.1575',
            [1.2015] = '1.2015',
        },
    },
    ['Bit28-31'] = {
        Name = 'FrameRate',
        ValueConv = {
            [1] = 23.976,
            [2] = 24,
            [3] = 25,
            [4] = 29.97,
            [5] = 30,
            [6] = 50,
            [7] = 59.94,
            [8] = 60,
        },
        PrintConv = function(_self, val) return str(val) .. ' fps' end,
    },
    ['Bit32-49'] = {
        Name = 'VideoBitrate',
        ValueConv = function(_self, val) if str(val) == str(0x3ffff) then return 'Variable' end return val * 400 end,
        PrintConv = function(_self, val) return ConvertBitrate(val) end,
    },
    -- these tags not very interesting
    --'Bit50'    => 'MarkerBit',
    --'Bit51-60' => 'VBVBufferSize',
    --'Bit61'    => 'ConstrainedParamFlag',
    --'Bit62'    => 'IntraQuantMatrixFlag',
}

MPEG.Xing = {
    GROUPS = { [2] = 'Audio' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'These tags are extracted from the Xing/Info frame.',
    [1] = { Name = 'VBRFrames' },
    [2] = { Name = 'VBRBytes' },
    [3] = { Name = 'VBRScale' },
    [4] = { Name = 'Encoder' },
    [5] = { Name = 'LameVBRQuality' },
    [6] = { Name = 'LameQuality' },
    [7] = { -- (for documentation only)
        Name = 'LameHeader',
        SubDirectory = { TagTable = 'lexiftool.MPEG.Lame' },
    },
}

-- Lame header tags (ref 5)
MPEG.Lame = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    NOTES = 'Tags extracted from Lame 3.90 or later header.',
    [9] = {
        Name = 'LameMethod',
        Mask = 0x0f,
        PrintConv = {
            [1] = 'CBR',
            [2] = 'ABR',
            [3] = 'VBR (old/rh)',
            [4] = 'VBR (new/mtrh)',
            [5] = 'VBR (old/rh)',
            [6] = 'VBR',
            [8] = 'CBR (2-pass)',
            [9] = 'ABR (2-pass)',
        },
    },
    [10] = {
        Name = 'LameLowPassFilter',
        ValueConv = function(_self, val) return val * 100 end,
        PrintConv = function(_self, val) return str(val / 1000) .. ' kHz' end,
    },
    -- 19 - EncodingFlags
    [20] = {
        Name = 'LameBitrate',
        ValueConv = function(_self, val) return val * 1000 end,
        PrintConv = function(_self, val) return ConvertBitrate(val) end,
    },
    [24] = {
        Name = 'LameStereoMode',
        Mask = 0x1c,
        PrintConv = {
            [0] = 'Mono',
            [1] = 'Stereo',
            [2] = 'Dual Channels',
            [3] = 'Joint Stereo',
            [4] = 'Forced Joint Stereo',
            [6] = 'Auto',
            [7] = 'Intensity Stereo',
        },
    },
}

-- composite tags
MPEG.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    Duration = {
        TagID = 'MPEG-Duration',
        Groups = { [2] = 'Video' },
        Require = {
            [0] = 'FileSize',
        },
        Desire = {
            [1] = 'ID3Size',
            [2] = 'MPEG:AudioBitrate',
            [3] = 'MPEG:VideoBitrate',
            [4] = 'MPEG:VBRFrames',
            [5] = 'MPEG:SampleRate',
            [6] = 'MPEG:MPEGAudioVersion',
        },
        Priority = -1, -- (don't want to replace any other Duration tag)
        ValueConv = function(_self, val, prt)
            if truthy(val[4]) and val[5] ~= nil and val[6] ~= nil then
                -- calculate from number of VBR audio frames
                local mfs = num(prt[5]) / (num(val[6]) == 3 and 144 or 72)
                -- calculate using VBR length
                return 8 * num(val[4]) / mfs
            end
            -- calculate duration as file size divided by total bitrate
            -- (note: this is only approximate!)
            if not (truthy(val[2]) or truthy(val[3])) then return nil end
            if truthy(val[2]) and not isMatch(str(val[2]), [[^\d+$]]) then return nil end
            if truthy(val[3]) and not isMatch(str(val[3]), [[^\d+$]]) then return nil end
            return (8 * (num(val[0]) - num(val[1]))) / (num(val[2]) + num(val[3]))
        end,
        PrintConv = function(_self, val) return ConvertDuration(val) .. ' (approx)' end,
    },
    AudioBitrate = {
        TagID = 'MPEG-AudioBitrate',
        Groups = { [2] = 'Audio' },
        Notes = 'calculated for variable-bitrate MPEG audio',
        Require = {
            [0] = 'MPEG:MPEGAudioVersion',
            [1] = 'MPEG:SampleRate',
            [2] = 'MPEG:VBRBytes',
            [3] = 'MPEG:VBRFrames',
        },
        ValueConv = function(_self, val, prt)
            if not truthy(val[3]) then return nil end
            local mfs = num(prt[1]) / (num(val[0]) == 3 and 144 or 72)
            return mfs * num(val[2]) / num(val[3])
        end,
        PrintConv = function(_self, val) return ConvertBitrate(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.MPEG', nil, MPEG)


--------------------------------------------------------------------------------
-- Process information in an MPEG audio or video frame header
-- Inputs: 0) ExifTool object ref, 1) tag table ref, 2-N) list of 32-bit data words
local function ProcessFrameHeader(et, tagTablePtr, ...)
    local data = { ... }
    for _, tag in ipairs(sort(keys(tagTablePtr))) do
        local c1, c2 = matches(tag, [[^Bit(\d{2})-?(\d{2})?]])
        if c1 == nil then goto continue end
        do
            local b1, b2 = c1, truthy(c2) and c2 or c1
            local index_ = int(num(b1) / 32)
            local word = data[index_ + 1]
            local mask = 0
            for i = 0, num(b2) - num(b1) do
                mask = mask + (1 << i)
            end
            local val = (num(word) >> (31 + 32*index_ - num(b2))) & mask
            et:HandleTag(tagTablePtr, tag, val)
        end
        ::continue::
    end
end
MPEG.ProcessFrameHeader = ProcessFrameHeader

--------------------------------------------------------------------------------
-- Read MPEG audio frame header
-- Inputs: 0) ExifTool object reference, 1) Reference to audio data
--         2) flag set if we are trying to recognized MP3 file only
-- Returns: 1 on success, 0 if no audio header was found
local function ParseMPEGAudio(et, buffPt, mp3)
    local word, pos
    local ext = et.FILE_EXT or ''
    local buffPos = 0   -- (pos($$buffPt))

    while true do
        -- find frame sync
        local c1
        c1, buffPos = matches(buffPt, [[(?s)(\xff.{3})]], buffPos)
        if c1 == nil then return 0 end
        word = unpack('N', c1)    -- get audio frame header word
        if (word & 0xffe00000) ~= 0xffe00000 then
            buffPos = buffPos - 2  -- next possible location for frame sync
            goto continue
        end
        -- validate header as much as possible
        if (word & 0x180000) == 0x080000 or   -- 01 is a reserved version ID
            (word & 0x060000) == 0x000000 or   -- 00 is a reserved layer description
            (word & 0x00f000) == 0x000000 or   -- 0000 is the "free" bitrate index
            (word & 0x00f000) == 0x00f000 or   -- 1111 is a bad bitrate index
            (word & 0x000c00) == 0x000c00 or   -- 11 is a reserved sampling frequency
            (word & 0x000003) == 0x000002 or   -- 10 is a reserved emphasis
            ((truthy(mp3) and (word & 0x060000) ~= 0x020000)) -- must be layer 3 for MP3
        then
            -- give up easily unless this really should be an MP3 file
            if ext ~= 'MP3' then return 0 end
            buffPos = buffPos - 1
            goto continue
        end
        pos = buffPos
        break
        ::continue::
    end
    -- set file type if not done already
    et:SetFileType()

    local tagTablePtr = GetTagTable(nil, 'lexiftool.MPEG.Audio')
    ProcessFrameHeader(et, tagTablePtr, word)

    -- extract the VBR information (ref MP3::Info)
    local v, m = et.MPEG_Vers, et.MPEG_Mode
    while v ~= nil and m ~= nil do -- luacheck: ignore 512
        local len = length(buffPt)
        pos = pos + (v == 3 and (m == 3 and 17 or 32) or (m == 3 and  9 or 17))
        if pos + 8 > len then break end
        local buff = substr(buffPt, pos, 8)
        if not isMatch(buff, [[^(Xing|Info)]]) then break end
        local xingTable = GetTagTable(nil, 'lexiftool.MPEG.Xing')
        local vbrScale
        local flags = unpack('x4N', buff)
        local isVBR = not isMatch(buff, [[^Info]])     -- Info frame is not VBR (ref 5)
        pos = pos + 8
        if (flags & 0x01) ~= 0 then    -- VBRFrames
            if pos + 4 > len then break end
            if isVBR then et:HandleTag(xingTable, 1, unpack('x' .. pos .. 'N', buffPt)) end
            pos = pos + 4
        end
        if (flags & 0x02) ~= 0 then    -- VBRBytes
            if pos + 4 > len then break end
            if isVBR then et:HandleTag(xingTable, 2, unpack('x' .. pos .. 'N', buffPt)) end
            pos = pos + 4
        end
        if (flags & 0x04) ~= 0 then    -- VBR_TOC
            if pos + 100 > len then break end
            -- (ignore toc for now)
            pos = pos + 100
        end
        if (flags & 0x08) ~= 0 then    -- VBRScale
            if pos + 4 > len then break end
            vbrScale = unpack('x' .. pos .. 'N', buffPt)
            if isVBR then et:HandleTag(xingTable, 3, vbrScale) end
            pos = pos + 4
        end
        -- process Lame header (ref 5)
        if (flags & 0x10) ~= 0 then    -- Lame
            if pos + 348 > len then break end
        elseif pos + 4 <= len then
            local lib = substr(buffPt, pos, 4)
            if not (lib == 'LAME' or lib == 'GOGO') then
                -- attempt to identify other encoders
                local n
                if index(buffPt, 'RCA mp3PRO Encoder') >= 0 then
                    lib = 'RCA mp3PRO'
                else
                    n = index(buffPt, 'THOMSON mp3PRO Encoder')
                    if n >= 0 then
                        lib = 'Thomson mp3PRO'
                        n = n + 22
                        if length(buffPt) - n >= 6 then lib = lib .. ' ' .. substr(buffPt, n, 6) end
                    elseif index(buffPt, 'MPGE') >= 0 then
                        lib = 'Gogo (<3.0)'
                    else
                        break
                    end
                end
                et:HandleTag(xingTable, 4, lib)
                break
            end
        end
        local lameLen = len - pos
        if lameLen < 9 then break end
        local enc = substr(buffPt, pos, 9)
        if not perl.lt(enc, 'LAME3.90') then
            et:HandleTag(xingTable, 4, enc)
            if num(vbrScale) <= 100 then
                et:HandleTag(xingTable, 5, int((100 - num(vbrScale)) / 10))
                et:HandleTag(xingTable, 6, (100 - num(vbrScale)) % 10)
            end
            local dirInfo = {
                DataPt   = buffPt,
                DirStart = pos,
                DirLen   = length(buffPt) - pos,
            }
            local subTablePtr = GetTagTable(nil, 'lexiftool.MPEG.Lame')
            et:ProcessDirectory(dirInfo, subTablePtr)
        else
            et:HandleTag(xingTable, 4, substr(buffPt, pos, 20))
        end
        break   -- (didn't want to loop anyway)
    end

    return 1
end
MPEG.ParseMPEGAudio = ParseMPEGAudio

--------------------------------------------------------------------------------
-- Read MPEG video frame header
-- Inputs: 0) ExifTool object reference, 1) Reference to video data
-- Returns: 1 on success, 0 if no video header was found
local function ProcessMPEGVideo(et, buffPt)

    if length(buffPt) < 4 then return 0 end
    local w1, w2 = unpack('N2', buffPt)
    -- validate as much as possible
    if (w1 & 0x000000f0) == 0x00000000 or     -- 0000 is a forbidden aspect ratio
        (w1 & 0x000000f0) == 0x000000f0 or     -- 1111 is a reserved aspect ratio
        (w1 & 0x0000000f) == 0 or              -- frame rate must be 1-8
        (w1 & 0x0000000f) > 8
    then
        return 0
    end
    -- set file type if not done already
    if not truthy(et.FileType) then et:SetFileType('MPEG') end

    local tagTablePtr = GetTagTable(nil, 'lexiftool.MPEG.Video')
    ProcessFrameHeader(et, tagTablePtr, w1, w2)
    return 1
end
MPEG.ProcessMPEGVideo = ProcessMPEGVideo

--------------------------------------------------------------------------------
-- Read MPEG audio and video frame headers
-- Inputs: 0) ExifTool object reference, 1) Reference to audio/video data
-- Returns: 1 on success, 0 if no video header was found
-- To Do: Properly parse MPEG streams:
--   0xb7 - sequence end
--   0xb9 - end code
--   0xba - pack start code
--   0xbb - system header
--   0xbc - program map <-- should parse this
--   0xbd - private stream 1 --> for VOB, this contains sub-streams:
--           0x20-0x3f - pictures
--           0x80-0x87 - audio (AC3,DTS,SDDS)
--           0xa0-0xa7 - audio (LPCM)
--   0xbe - padding
--   0xbf - private stream 2
--   0xc0-0xdf - audio stream
--   0xe0-0xef - video stream
local function ParseMPEGAudioVideo(et, buffPt)
    local found, didHdr = {}, nil
    local rtnVal = 0
    local proc = { audio = ParseMPEGAudio, video = ProcessMPEGVideo }

    et.AudioBitrate = nil
    et.VideoBitrate = nil

    local buffPos = 0   -- (pos($$buffPt))
    while true do
        local c1
        c1, buffPos = matches(buffPt, [[\0\0\x01(\xb3|\xc0)]], buffPos)
        if c1 == nil then break end
        local type_ = c1 == "\xb3" and 'video' or 'audio'
        if not didHdr then
            -- make sure we didn't miss an audio frame sync before this (eg. MP3 file)
            -- (the last byte of the 4-byte MP3 audio frame header word may be zero,
            -- but the 2nd last must be non-zero, so we need only check to pos-3)
            local buff = substr(buffPt, 0, buffPos - 3)
            if truthy(ParseMPEGAudio(et, buff)) then found.audio = 1 end
            didHdr = 1
        end
        if found[type_] then goto continue end
        do
            local len = length(buffPt) - buffPos
            if len < 4 then break end
            if len > 256 then len = 256 end
            local dat = substr(buffPt, buffPos, len)
            -- process MPEG audio or video
            if truthy(proc[type_](et, dat)) then
                rtnVal = 1
                found[type_] = 1
                -- done if we found audio and video
                if #keys(found) == 2 then break end
            end
        end
        ::continue::
    end
    return rtnVal
end
MPEG.ParseMPEGAudioVideo = ParseMPEGAudioVideo

--------------------------------------------------------------------------------
-- Read information from an MPEG file
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid MPEG file
function MPEG.ProcessMPEG(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff

    n, buff = raf:Read(4)
    if n ~= 4 then return 0 end
    if not isMatch(buff, [=[^\0\0\x01[\xb0-\xbf]]=]) then return 0 end
    et:SetFileType()

    raf:Seek(0,0)
    n, buff = raf:Read(65536*4)
    if not truthy(n) then return 0 end

    return ParseMPEGAudioVideo(et, buff)
end

return MPEG
