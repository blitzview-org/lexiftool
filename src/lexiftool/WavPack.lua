--------------------------------------------------------------------------------
-- File:         lexiftool/WavPack.lua
-- Ported from:  lib/Image/ExifTool/WavPack.pm
--
-- Description:  Read metadata from WavPack audio files
--
-- Revisions:    2025-09-24 - P. Harvey Created
--
-- References:   1) https://www.wavpack.com/WavPack5FileFormat.pdf
--
-- Port notes:   complete: the Main table and ProcessWV, both in full.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches

local WavPack = {}

WavPack.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Audio' },
    FORMAT = 'int32u',
    NOTES = [[
        Tags extracted from the header of WavPack (WV and WVP) audio files.  These
        files may also contain RIFF, ID3 and/or APE metadata which is also extracted
        by ExifTool.  See L<https://www.wavpack.com/WavPack5FileFormat.pdf> for the
        WavPack specification.
    ]],
    [6.1] = {
        Name = 'BytesPerSample',
        Mask = 0x03,
        ValueConv = function(_self, val) return val + 1 end,
    },
    [6.2] = {
        Name = 'AudioType',
        Mask = 0x04,
        PrintConv = { [0] = 'Stereo', [1] = 'Mono' },
    },
    [6.3] = {
        Name = 'Compression',
        Mask = 0x08,
        PrintConv = { [0] = 'Lossless', [1] = 'Hybrid' },
    },
    [6.4] = {
        Name = 'DataFormat',
        Mask = 0x80,
        PrintConv = { [0] = 'Integer', [1] = 'Floating Point' },
    },
    [6.5] = {
        Name = 'SampleRate',
        Mask = 0x07800000,
        Priority = 0, -- ("Custom" is not very useful)
        PrintConv = { -- (NC)
            [0] = 6000,
            [1] = 8000,
            [2] = 9600,
            [3] = 11025,
            [4] = 12000,
            [5] = 16000,
            [6] = 22050,
            [7] = 24000,
            [8] = 32000,
            [9] = 44100,
            [10] = 48000,
            [11] = 64000,
            [12] = 88200,
            [13] = 96000,
            [14] = 192000,
            [15] = 'Custom',
        },
    },
}

--------------------------------------------------------------------------------
-- Extract metadata from a WavPack file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid WavPack file
--------------------------------------------------------------------------------
function WavPack.ProcessWV(et, dirInfo)
    local raf = dirInfo.RAF

    -- verify this is a valid WavPack file
    local n, buff = raf:Read(32)
    if n ~= 32 then return 0 end
    if not matches(buff, [[(?s)^wvpk.{4}[\x02\x10]\x04]]) then return 0 end
    et:SetFileType()
    local subDirInfo = {
        DataPt = buff,
        DirStart = 0,
        DirLen = #buff,
    }
    et:ProcessBinaryData(subDirInfo, et:GetTagTable('lexiftool.WavPack.Main'))
    -- historically, the RIFF module has handled RIFF-type WavPack files
    raf:Seek(0, 0)
    et.PATH[#et.PATH + 1] = 'RIFF' -- update metadata path
    require('lexiftool.RIFF').ProcessRIFF(et, dirInfo)
    -- also look for ID3 and APE trailers (ProcessAPE also checks for ID3)
    et.PATH[#et.PATH] = 'APE'
    require('lexiftool.APE').ProcessAPE(et, dirInfo)
    et.PATH[#et.PATH] = nil
    return 1
end

return WavPack
