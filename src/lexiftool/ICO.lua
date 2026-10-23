--------------------------------------------------------------------------------
-- File:         lexiftool/ICO.lua
-- Ported from:  lib/Image/ExifTool/ICO.pm
--
-- Description:  Read Windows ICO and CUR files
--
-- Revisions:    2020-10-18 - P. Harvey Created
--
-- References:   1) https://docs.fileformat.com/image/ico/
--
-- Port notes:   read port: ProcessICO and the Main/IconDir tables. Upstream
--               ICO.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local matches = require('lexiftool.perl').matches
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder = ExifTool.SetByteOrder
local Get16u = ExifTool.Get16u

local ICO = {}

ICO.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = 'Information extracted from Windows ICO (icon) and CUR (cursor) files.',
    [2] = {
        Name = 'ImageType',
        Format = 'int16u',
        PrintConv = { [1] = 'Icon', [2] = 'Cursor' },
    },
    [4] = {
        Name = 'ImageCount',
        Format = 'int16u',
        RawConv = function(self, val) self.ImageCount = val; return val end,
    },
    [6] = {
        Name = 'IconDir',
        SubDirectory = { TagTable = 'lexiftool.ICO.IconDir' },
    },
}

ICO.IconDir = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    [0] = {
        Name = 'ImageWidth',
        ValueConv = function(_self, val) return val ~= 0 and val or val + 256 end,
    },
    [1] = {
        Name = 'ImageHeight',
        ValueConv = function(_self, val) return val ~= 0 and val or val + 256 end,
    },
    [2] = 'NumColors',
    [4] = {
        {
            Name = 'ColorPlanes',
            Condition = function(self) return self.FileType == 'ICO' end,
            Format = 'int16u',
            Notes = 'ICO files',
        },
        {
            Name = 'HotspotX',
            Format = 'int16u',
            Notes = 'CUR files',
        },
    },
    [6] = {
        {
            Name = 'BitsPerPixel',
            Condition = function(self) return self.FileType == 'ICO' end,
            Format = 'int16u',
            Notes = 'ICO files',
        },
        {
            Name = 'HotspotY',
            Format = 'int16u',
            Notes = 'CUR files',
        },
    },
    [8] = {
        Name = 'ImageLength',
        Format = 'int32u',
    },
}

--------------------------------------------------------------------------------
-- Process ICO/CUR file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid ICO/CUR file
--------------------------------------------------------------------------------
function ICO.ProcessICO(et, dirInfo)
    local raf = dirInfo.RAF
    local i, buff, n
    -- verify this is a valid ICO/CUR file
    n, buff = raf:Read(6)
    if n ~= 6 then return 0 end
    local t = matches(buff, [[(?s)^\0\0([\x01\x02])\0[^0]\0]])
    if not t then return 0 end
    -- (note: have seen cursor files in the wild with an 0x01 here,
    -- but SetFileType will use the .cur extension to identify these)
    et:SetFileType(t == "\x01" and 'ICO' or 'CUR')
    SetByteOrder('II')
    local tagTbl = GetTagTable(nil, 'lexiftool.ICO.Main')
    local num = Get16u(buff, 4)
    et:HandleTag(tagTbl, 4, num)
    i = 0
    while i < num do
        n, buff = raf:Read(16)
        if n ~= 16 then et:Warn('Truncated file'); break end
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        et:HandleTag(tagTbl, 6, buff)
        i = i + 1
    end
    et.DOC_NUM = nil
    return 1
end

return ICO
