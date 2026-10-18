--------------------------------------------------------------------------------
-- File:         lexiftool/PCX.lua
-- Ported from:  lib/Image/ExifTool/PCX.pm
--
-- Description:  Read metadata from PC Paintbrush files
--
-- Revisions:    2018/12/12 - P. Harvey Created
--
-- References:   1) http://qzx.com/pc-gpe/pcx.txt
--               2) https://www.fileformat.info/format/pcx/corion.htm
--
-- Port notes:   read port: the Main table plus ProcessPCX. Upstream PCX.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')

local PCX = {}

-- PCX info
PCX.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = 'Tags extracted from PC Paintbrush images.',
    DATAMEMBER = { 0x04, 0x05 },
    [0x00] = {
        Name = 'Manufacturer',
        PrintConv = { [10] = 'ZSoft' },
    },
    [0x01] = {
        Name = 'Software',
        PrintConv = {
            [0] = 'PC Paintbrush 2.5',
            [2] = 'PC Paintbrush 2.8 (with palette)',
            [3] = 'PC Paintbrush 2.8 (without palette)',
            [4] = 'PC Paintbrush for Windows',
            [5] = 'PC Paintbrush 3.0+',
        },
    },
    [0x02] = { Name = 'Encoding', PrintConv = { [1] = 'RLE' } },
    [0x03] = 'BitsPerPixel',
    [0x04] = {
        Name = 'LeftMargin',
        Format = 'int16u',
        RawConv = function(self, val) self.LeftMargin = val; return val end,
    },
    [0x06] = {
        Name = 'TopMargin',
        Format = 'int16u',
        RawConv = function(self, val) self.TopMargin = val; return val end,
    },
    [0x08] = {
        Name = 'ImageWidth',
        Format = 'int16u',
        Notes = 'adjusted for LeftMargin',
        ValueConv = function(self, val) return val - self.LeftMargin + 1 end,
    },
    [0x0a] = {
        Name = 'ImageHeight',
        Format = 'int16u',
        Notes = 'adjusted for TopMargin',
        ValueConv = function(self, val) return val - self.TopMargin + 1 end,
    },
    [0x0c] = 'XResolution',
    [0x0e] = 'YResolution',
    [0x41] = 'ColorPlanes',
    [0x42] = { Name = 'BytesPerLine', Format = 'int16u' },
    [0x44] = {
        Name = 'ColorMode',
        PrintConv = {
            [0] = 'n/a',
            [1] = 'Color Palette',
            [2] = 'Grayscale',
        },
    },
    [0x46] = {
        Name = 'ScreenWidth',
        Format = 'int16u',
        RawConv = function(_self, val) return val ~= 0 and val or nil end,
    },
    [0x48] = {
        Name = 'ScreenHeight',
        Format = 'int16u',
        RawConv = function(_self, val) return val ~= 0 and val or nil end,
    },
}

--------------------------------------------------------------------------------
-- Extract information from a PCX image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PCX file
--------------------------------------------------------------------------------
function PCX.ProcessPCX(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(0x50)
    if n ~= 0x50 then return 0 end
    -- verify the signature (upstream: /^\x0a[\0-\x05]\x01[\x01\x02\x04\x08].{64}[\0-\x02]/s)
    if not (buff:byte(1) == 0x0a and buff:byte(2) <= 0x05 and buff:byte(3) == 0x01 and
        (buff:byte(4) == 1 or buff:byte(4) == 2 or buff:byte(4) == 4 or buff:byte(4) == 8) and
        buff:byte(69) <= 0x02) then
        return 0
    end
    ExifTool.SetByteOrder('II')
    et:SetFileType()
    local subdirInfo = { DirName = 'PCX', DataPt = buff }
    local tagTablePtr = et:GetTagTable('lexiftool.PCX.Main')
    return et:ProcessBinaryData(subdirInfo, tagTablePtr)
end

return PCX
