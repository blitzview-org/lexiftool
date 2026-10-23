--------------------------------------------------------------------------------
-- File:         lexiftool/MOI.lua
-- Ported from:  lib/Image/ExifTool/MOI.pm
--
-- Description:  Read MOI meta information
--
-- Revisions:    2014/12/15 - P. Harvey Created
--
-- References:   1) https://en.wikipedia.org/wiki/MOI_(file_format)
--
-- Port notes:   read port: the Main table plus ProcessMOI. Upstream MOI.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf
local unpack = require('lexiftool.perl').unpack

local MOI = {}

-- MOI tags (ref 1)
MOI.Main = {
    GROUPS = { [2] = 'Video' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = [[
        MOI files store information about associated MOD or TOD files, and are
        written by some JVC, Canon and Panasonic camcorders.
    ]],
    [0x00] = { Name = 'MOIVersion', Format = 'string[2]' },
    -- 0x02 => { Name => 'MOIFileSize', Format => 'int32u' },
    [0x06] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'undef[8]',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            if #val < 8 then return nil end
            local year = ExifTool.Get16u(val, 0)
            local month, day, hour, minute = val:byte(3), val:byte(4), val:byte(5), val:byte(6)
            local ms = ExifTool.Get16u(val, 6)
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%06.3f', year, month, day, hour, minute, ms / 1000)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x0e] = {
        Name = 'Duration',
        Format = 'int32u',
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [0x80] = {
        Name = 'AspectRatio',
        Format = 'int8u',
        PrintConv = function(_self, val)
            local lo = val & 0x0f
            local hi = val >> 4
            local aspect
            if lo < 2 then
                aspect = '4:3'
            elseif lo == 4 or lo == 5 then
                aspect = '16:9'
            else
                aspect = 'Unknown'
            end
            if hi == 4 then
                aspect = aspect .. ' NTSC'
            elseif hi == 5 then
                aspect = aspect .. ' PAL'
            end
            return aspect
        end,
    },
    [0x84] = {
        Name = 'AudioCodec',
        Format = 'int16u',
        Groups = { [2] = 'Audio' },
        PrintHex = 1,
        PrintConv = {
            [0x00c1] = 'AC3',
            [0x4001] = 'MPEG',
        },
    },
    [0x86] = {
        Name = 'AudioBitrate',
        Format = 'int8u',
        Groups = { [2] = 'Audio' },
        ValueConv = function(_self, val) return val * 16000 + 48000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
    [0xda] = {
        Name = 'VideoBitrate',
        Format = 'int16u',
        PrintHex = 1,
        ValueConv = {
            [0x5896] = '8500000',
            [0x813d] = '5500000',
        },
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(tonumber(val)) end,
    },
}

--------------------------------------------------------------------------------
-- Validate and extract metadata from MOI file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid MOI file
--------------------------------------------------------------------------------
function MOI.ProcessMOI(et, dirInfo)
    local raf = dirInfo.RAF
    -- read enough to allow skipping over run-in if it exists
    local n, buff = raf:Read(256)
    if n ~= 256 or buff:sub(1, 2) ~= 'V6' then return 0 end
    if et.VALUE.FileSize then
        local size = unpack('x2N', buff)
        if size ~= et.VALUE.FileSize then return 0 end
    end
    et:SetFileType()
    ExifTool.SetByteOrder('MM')
    local tagTablePtr = et:GetTagTable('lexiftool.MOI.Main')
    return et:ProcessBinaryData({ DataPt = buff }, tagTablePtr)
end

return MOI
