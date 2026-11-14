--------------------------------------------------------------------------------
-- File:         lexiftool/KyoceraRaw.lua
-- Ported from:  lib/Image/ExifTool/KyoceraRaw.pm
--
-- Description:  Read Kyocera RAW meta information
--
-- Revisions:    02/17/2006 - P. Harvey Created
--
-- References:   1) http://www.cybercom.net/~dcoffin/dcraw/
--
-- Port notes:   ported in full -- `Main` is a small, self-contained fixed
--               binary-data header table (12 tags) with no conditional
--               branches or unexercised variants to subset. `ProcessRAW`
--               (the whole-file container reader: validates the reversed
--               "KYOCERA" signature at a fixed offset, then hands the fixed
--               156-byte header to the generic `ProcessBinaryData`) is
--               ported as-is.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str

local KyoceraRaw = {}

-- upstream: `pack('C*',reverse unpack('C*',shift))` -- reverse the order of
-- bytes in a string
local function ReverseString(_self, val)
    return str(val):reverse()
end

KyoceraRaw.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Tags for Kyocera Contax N Digital RAW images.',
    [0x01] = {
        Name = 'FirmwareVersion',
        Format = 'string[10]',
        ValueConv = ReverseString,
    },
    [0x0c] = {
        Name = 'Model',
        Format = 'string[12]',
        ValueConv = ReverseString,
    },
    [0x19] = {
        Name = 'Make',
        Format = 'string[7]',
        ValueConv = ReverseString,
    },
    [0x21] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Format = 'string[20]',
        ValueConv = ReverseString,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x34] = {
        Name = 'ISO',
        Groups = { [2] = 'Image' },
        Format = 'int32u',
        PrintConv = {
            [7] = 25, [8] = 32, [9] = 40, [10] = 50, [11] = 64, [12] = 80,
            [13] = 100, [14] = 125, [15] = 160, [16] = 200, [17] = 250,
            [18] = 320, [19] = 400,
        },
    },
    [0x38] = {
        Name = 'ExposureTime',
        Groups = { [2] = 'Image' },
        Format = 'int32u',
        ValueConv = function(_self, val) return 2 ^ (val / 8) / 16000 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x3c] = {
        Name = 'WB_RGGBLevels',
        Groups = { [2] = 'Image' },
        Format = 'int32u[4]',
    },
    [0x58] = {
        Name = 'FNumber',
        Groups = { [2] = 'Image' },
        Format = 'int32u',
        ValueConv = function(_self, val) return 2 ^ (val / 16) end,
        PrintConv = function(_self, val) return sprintf('%.2g', val) end,
    },
    [0x68] = {
        Name = 'MaxAperture',
        Format = 'int32u',
        ValueConv = function(_self, val) return 2 ^ (val / 16) end,
        PrintConv = function(_self, val) return sprintf('%.2g', val) end,
    },
    [0x70] = {
        Name = 'FocalLength',
        Format = 'int32u',
        PrintConv = function(self, val) return self.NumStr(val) .. ' mm' end,
    },
    [0x7c] = {
        Name = 'Lens',
        Format = 'string[32]',
    },
}

--------------------------------------------------------------------------------
-- Extract information from a Kyocera RAW image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference ({ RAF })
-- Returns: 1 if this was a valid Kyocera RAW image
function KyoceraRaw.ProcessRAW(et, dirInfo)
    local raf = dirInfo.RAF
    local size = 156 -- size of header
    local n, buff = raf:Read(size)
    if n ~= size then return 0 end
    -- validate Make string ('KYOCERA' reversed)
    if buff:sub(0x19 + 1, 0x19 + 7) ~= 'ARECOYK' then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('MM')
    local subDirInfo = {
        DataPt = buff,
        DataPos = 0,
        DataLen = size,
        DirStart = 0,
        DirLen = size,
    }
    local tagTablePtr = et:GetTagTable('lexiftool.KyoceraRaw.Main')
    et:ProcessDirectory(subDirInfo, tagTablePtr)
    return 1
end

return KyoceraRaw
