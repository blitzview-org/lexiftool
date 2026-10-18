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
-- Port notes:   read subset: ProcessICO and the Main/IconDir tables. The
--               `DOC_NUM`/`DOC_COUNT` multi-image document numbering
--               (upstream: each icon in a multi-image ICO/CUR file becomes
--               a separate numbered "document") is tracked but not
--               consumed anywhere in this port yet -- no test file
--               exercises more than one image per ICO/CUR file.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')

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
    local n, buff = raf:Read(6)
    if n ~= 6 then return 0 end
    -- verify this is a valid ICO/CUR file
    -- (note: have seen cursor files in the wild with an 0x01 here, but
    -- SetFileType will use the .cur extension to identify these)
    if not (buff:sub(1, 2) == '\0\0' and (buff:byte(3) == 1 or buff:byte(3) == 2) and
        buff:byte(4) == 0 and buff:byte(5) ~= 0x30 and buff:byte(6) == 0) then
        return 0
    end
    et:SetFileType(buff:byte(3) == 1 and 'ICO' or 'CUR')
    ExifTool.SetByteOrder('II')
    local tagTbl = et:GetTagTable('lexiftool.ICO.Main')
    local num = ExifTool.Get16u(buff, 4)
    et:HandleTag(tagTbl, 4, num)
    for _ = 1, num do
        local n2, buff2 = raf:Read(16)
        if n2 ~= 16 then
            et:Warn('Truncated file')
            break
        end
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        et:HandleTag(tagTbl, 6, buff2, { DataPt = buff2, Size = #buff2 })
    end
    et.DOC_NUM = nil
    return 1
end

return ICO
