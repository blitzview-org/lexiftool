--------------------------------------------------------------------------------
-- File:         lexiftool/Theora.lua
-- Ported from:  lib/Image/ExifTool/Theora.pm
--
-- Description:  Read Theora video meta information
--
-- Revisions:    2011/07/13 - P. Harvey Created
--
-- References:   1) http://www.theora.org/doc/Theora.pdf
--
-- Port notes:   complete: both tables in full. The module is pure tag tables
--               with no processor of its own -- Ogg.lua dispatches the Theora
--               header packets into Theora.Main.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local str = require('lexiftool.perl').str

local Theora = {}

-- Theora header types
Theora.Main = {
    NOTES = [[
        Information extracted from Ogg Theora video files.  See
        L<http://www.theora.org/doc/Theora.pdf> for the Theora specification.
    ]],
    [0x80] = {
        Name = 'Identification',
        SubDirectory = {
            TagTable = 'lexiftool.Theora.Identification',
            ByteOrder = 'BigEndian',
        },
    },
    [0x81] = {
        Name = 'Comments',
        SubDirectory = {
            TagTable = 'lexiftool.Vorbis.Comments',
        },
    },
    -- 0x82 - Setup
}

-- tags extracted from Theora Idenfication header
Theora.Identification = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    NOTES = 'Tags extracted from the Theora identification header.',
    [0] = {
        Name = 'TheoraVersion',
        Format = 'int8u[3]',
        PrintConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [7] = {
        Name = 'ImageWidth',
        Format = 'int32u',
        ValueConv = function(_self, val) return val >> 8 end,
    },
    [10] = {
        Name = 'ImageHeight',
        Format = 'int32u',
        ValueConv = function(_self, val) return val >> 8 end,
    },
    [13] = 'XOffset',
    [14] = 'YOffset',
    [15] = {
        Name = 'FrameRate',
        Format = 'rational64u',
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    [23] = {
        Name = 'PixelAspectRatio',
        Format = 'int16u[3]',
        ValueConv = function(_self, val)
            local a = {}
            for n in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(n) end
            return ((a[1] << 8) + (a[2] >> 8)) / (((a[2] & 0xff) << 8) + a[3])
        end,
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    [29] = {
        Name = 'ColorSpace',
        PrintConv = {
            [0] = 'Undefined',
            [1] = 'Rec. 470M',
            [2] = 'Rec. 470BG',
        },
    },
    [30] = {
        Name = 'NominalVideoBitrate',
        Format = 'int32u',
        ValueConv = function(_self, val) return val >> 8 end,
        PrintConv = {
            [0] = 'Unspecified',
            OTHER = function(val) return ExifTool.ConvertBitrate(val) end,
        },
    },
    [33] = {
        Name = 'Quality',
        ValueConv = function(_self, val) return val >> 2 end,
    },
    [34] = {
        Name = 'PixelFormat',
        ValueConv = function(_self, val) return (val >> 3) & 0x3 end,
        PrintConv = {
            [0] = '4:2:0',
            [2] = '4:2:2',
            [3] = '4:4:4',
        },
    },
}

return Theora
