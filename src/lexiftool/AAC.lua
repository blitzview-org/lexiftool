--------------------------------------------------------------------------------
-- File:         lexiftool/AAC.lua
-- Ported from:  lib/Image/ExifTool/AAC.pm
--
-- Description:  Read AAC audio files
--
-- Revisions:    2023-12-29 - P. Harvey Created
--
-- Port notes:   read subset: ProcessAAC and the Main table. Deferred:
--               average-bitrate calculation (would need scanning every
--               frame in the file).
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local FLAC = require('lexiftool.FLAC')

local AAC = {}

local convSampleRate = {
    [0] = 96000, [7] = 22050,
    [1] = 88200, [8] = 16000,
    [2] = 64000, [9] = 12000,
    [3] = 48000, [10] = 11025,
    [4] = 44100, [11] = 8000,
    [5] = 32000, [12] = 7350,
    [6] = 24000,
}

AAC.Main = {
    PROCESS_PROC = FLAC.ProcessBitStream,
    GROUPS = { [2] = 'Audio' },
    NOTES = 'Tags extracted from Advanced Audio Coding (AAC) files.',
    -- Bit000-011 - sync word (all 1's)
    -- Bit012     - ID (seems to be always 0)
    -- Bit013-014 - layer (00)
    -- Bit015     - CRC absent (0=crc exists, 1=no crc)
    ['Bit016-017'] = {
        Name = 'ProfileType',
        PrintConv = {
            [0] = 'Main',
            [1] = 'Low Complexity',
            [2] = 'Scalable Sampling Rate',
        },
    },
    ['Bit018-021'] = {
        Name = 'SampleRate',
        ValueConv = convSampleRate,
    },
    -- Bit022 - private
    ['Bit023-025'] = {
        Name = 'Channels',
        PrintConv = {
            [0] = '?',
            [1] = 1,
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = 5,
            [6] = '5+1',
            [7] = '7+1',
        },
    },
    -- Bit026 - original/copy
    -- Bit027 - home
    -- Bit028 - copyright ID
    -- Bit029 - copyright start
    -- Bit030-042 - FrameLength
    -- Bit043-053 - buffer fullness
    -- Bit054-055 - BlocksInFrame (minus 1)
    -- Note: Bitrate for frame = FrameLength * 8 * SampleRate / ((BlocksInFrame+1) * 1024)
    -- - but all frames must be scanned to calculate average bitrate
    Encoder = {
        Name = 'Encoder',
        Notes = 'taken from filler payload of first frame',
    },
}

--------------------------------------------------------------------------------
-- Read information from an AAC file
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid AAC file
--------------------------------------------------------------------------------
function AAC.ProcessAAC(et, dirInfo)
    local raf = dirInfo.RAF

    -- format of frame header (7 bytes):
    -- SSSS SSSS SSSS ILLC PPRR RRpC CCoh csff ffff ffff fffb bbbb bbbb bbNN
    -- 1111 1111 1111 0001 0110 0000 0100 0000 0000 0101 0101 1111 1111 1100 (eg.)
    --  S = sync word                o = original/copy
    --  I = ID                       h = home
    --  L = layer (00)               c = copyright ID
    --  C = CRC absent               s = copyright start
    --  P = profile object type      f = frame length
    --  R = sampling rate index      b = buffer fullness
    --  p = private                  N = number of raw data blocks in frame
    --  C = channel configuration

    local n, buff = raf:Read(7)
    if n ~= 7 then return 0 end
    if not (buff:byte(1) == 0xff and (buff:byte(2) == 0xf0 or buff:byte(2) == 0xf1)) then return 0 end
    local t0, t1, t2 = perl.unpack('NnC', buff)
    if (t0 >> 16) & 0x03 == 3 then return 0 end -- (reserved profile type)
    if (t0 >> 12) & 0x0f > 12 then return 0 end -- validate sampling frequency index
    local len = ((t0 << 11) & 0x1800) | ((t1 >> 5) & 0x07ff)
    if len < 7 then return 0 end

    et:SetFileType()

    local tagTablePtr = et:GetTagTable('lexiftool.AAC.Main')
    et:ProcessDirectory({ DataPt = buff }, tagTablePtr)

    -- read the first frame data to check for a filler with the encoder name
    if len > 8 then
        local n2, buf = raf:Read(len - 7)
        if n2 == len - 7 then
            local noCRC = t0 & 0x00010000
            local blocks = t2 & 0x03
            local pos = 0
            if noCRC == 0 then pos = pos + 2 + 2 * blocks end
            if pos + 2 <= #buf then
                local tmp = perl.unpack('x' .. pos .. 'n', buf)
                local id = tmp >> 13
                -- read filler payload
                if id == 6 then
                    local cnt = (tmp >> 9) & 0x0f
                    pos = pos + 1
                    if cnt == 15 then
                        cnt = cnt + ((tmp >> 1) & 0xff) - 1
                        pos = pos + 1
                    end
                    if pos + cnt <= #buf then
                        local dat = buf:sub(pos + 1, pos + cnt)
                        dat = dat:gsub('^%z+', ''):gsub('%z+$', '') -- (Lua 5.4: %z matches an embedded zero byte)
                        if dat:match('^[\32-\126]+$') then
                            et:HandleTag(tagTablePtr, 'Encoder', dat)
                        end
                    end
                end
            end
        end
    end

    return 1
end

return AAC
