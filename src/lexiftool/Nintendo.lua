--------------------------------------------------------------------------------
-- File:         lexiftool/Nintendo.lua
-- Ported from:  lib/Image/ExifTool/Nintendo.pm
--
-- Description:  Nintendo EXIF maker notes tags
--
-- Revisions:    2014/03/25 - P. Harvey Created
--
-- References:   1) http://3dbrew.org/wiki/MPO
--
-- Port notes:   complete: `Main` and `CameraInfo` in full, WRITE_PROC/
--               CHECK_PROC on both tables as upstream.  No vendored test
--               image carries Nintendo maker notes.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local unpack = perl.unpack
local sprintf = perl.sprintf

local Nintendo = {}

Nintendo.Main = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = 1,
    -- 0x1000 - undef[28]
    -- 0x1001 - undef[8]
    -- 0x1100 - undef[80] (found in MPO files)
    [0x1101] = {
        Name = 'CameraInfo',
        SubDirectory = {
            TagTable = 'lexiftool.Nintendo.CameraInfo',
            ByteOrder = 'Little-endian',
        },
    },
}

-- Nintendo MPO info (ref 1)
Nintendo.CameraInfo = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    PRIORITY = 0,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    [0x00] = { -- "3DS1"
        Name = 'ModelID',
        Format = 'undef[4]',
    },
    -- 0x04 - int32u: 1,2,4,5
    [0x08] = {
        Name = 'TimeStamp',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        -- zero time is 2000/01/01 (10957 days after Unix time zero)
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val + 10957 * 24 * 3600) end,
        ValueConvInv = function(_self, val) return ExifTool.GetUnixTime(val) - 10957 * 24 * 3600 end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    -- 0x10 - int32u: title ID low
    -- 0x14 - int32u: flags
    [0x18] = {
        Name = 'InternalSerialNumber',
        Groups = { [2] = 'Camera' },
        Format = 'undef[4]',
        ValueConv = function(_self, val) return '0x' .. unpack('H*', val) end,
        ValueConvInv = function(_self, val)
            val = perl.subst(val, '^0x', '')
            return perl.pack('H*', val)
        end,
    },
    [0x28] = {
        Name = 'Parallax',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.2f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x30] = {
        Name = 'Category',
        Format = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x0000] = '(none)',
            [0x1000] = 'Mii',
            [0x2000] = 'Man',
            [0x4000] = 'Woman',
        },
    },
    -- 0x32 - int16u: filter
}

return Nintendo
