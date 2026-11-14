--------------------------------------------------------------------------------
-- File:         lexiftool/Opus.lua
-- Ported from:  lib/Image/ExifTool/Opus.pm
--
-- Description:  Read Ogg Opus audio meta information
--
-- Revisions:    2016/07/14 - P. Harvey Created
--
-- References:   1) https://www.opus-codec.org/docs/
--               2) https://wiki.xiph.org/OggOpus
--               3) https://tools.ietf.org/pdf/rfc7845.pdf
--
-- Port notes:   read subset. Ported in full: Main (OpusHead -> Header,
--               OpusTags -> Vorbis.Comments) and Header (the 10-byte
--               OpusHead binary table).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')

local Opus = {}

-- Opus metadata types (upstream %Image::ExifTool::Opus::Main)
Opus.Main = {
    NOTES = [[
        Information extracted from Ogg Opus files.  See
        L<https://www.opus-codec.org/docs/> for the specification.
    ]],
    OpusHead = {
        Name = 'Header',
        SubDirectory = { TagTable = 'lexiftool.Opus.Header' },
    },
    OpusTags = {
        Name = 'Comments',
        SubDirectory = { TagTable = 'lexiftool.Vorbis.Comments' },
    },
}

-- Opus header (upstream %Opus::Header)
Opus.Header = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    [0] = 'OpusVersion',
    [1] = 'AudioChannels',
    [4] = {
        Name = 'SampleRate',
        Format = 'int32u',
    },
    [8] = {
        Name = 'OutputGain',
        Format = 'int16u',
        ValueConv = function(_self, val) return 10 ^ (val / 5120) end,
    },
}

return Opus