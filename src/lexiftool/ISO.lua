--------------------------------------------------------------------------------
-- File:         lexiftool/ISO.lua
-- Ported from:  lib/Image/ExifTool/ISO.pm
--
-- Description:  Read information from ISO 9660 disk images
--
-- Revisions:    2016-04-07 - P. Harvey created
--
-- References:   1) http://wiki.osdev.org/ISO_9660
--
-- Port notes:   read port: the Main/BootRecord/PrimaryVolume/Composite tables
--               plus ProcessISO. The local rawStr helper trims the space-padded
--               fixed-width strings that Perl trims inline. Upstream ISO.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf

local ISO = {}

-- trim trailing spaces and ignore tag if empty
local function rawStr(_self, val)
    val = (val:gsub(' +$', ''))
    if #val == 0 then return nil end
    return val
end

-- tag info for date/time tags
local dateInfo = {
    Format = 'undef[17]',
    Groups = { [2] = 'Time' },
    ValueConv = function(_self, val)
        if not val:find('[^0%z ]') then return nil end -- ignore if empty
        local y, mo, d, h, mi, s, cs, tzb = val:match('^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(.)')
        if y then
            local tz = tzb:byte()
            if tz > 127 then tz = tz - 256 end
            return y .. ':' .. mo .. ':' .. d .. ' ' .. h .. ':' .. mi .. ':' .. s .. '.' .. cs ..
                ExifTool.TimeZoneString(tz * 15)
        end
        return val
    end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- lookup for volume descriptor types
local volumeDescriptorType = {
    [0] = 'Boot Record',
    [1] = 'Primary Volume',
    [2] = 'Supplementary Volume',
    [3] = 'Volume Partition',
    [255] = 'Terminator',
}

-- ISO tags
ISO.Main = {
    GROUPS = { [2] = 'Other' },
    NOTES = 'Tags extracted from ISO 9660 disk images.',
    [0] = {
        Name = 'BootRecord',
        SubDirectory = { TagTable = 'lexiftool.ISO.BootRecord' },
    },
    [1] = {
        Name = 'PrimaryVolume',
        SubDirectory = { TagTable = 'lexiftool.ISO.PrimaryVolume' },
    },
}

ISO.BootRecord = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    -- always extract BootSystem, even if empty, as an indication that this is bootable
    [7] = {
        Name = 'BootSystem',
        Format = 'string[32]',
        ValueConv = function(_self, val) return (val:gsub(' +$', '')) end,
    },
    [39] = { Name = 'BootIdentifier', Format = 'string[32]', RawConv = rawStr },
}

ISO.PrimaryVolume = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [8] = { Name = 'System', Format = 'string[32]', RawConv = rawStr },
    [40] = { Name = 'VolumeName', Format = 'string[32]', RawConv = rawStr },
    [80] = { Name = 'VolumeBlockCount', Format = 'int32u' },
    [120] = { Name = 'VolumeSetDiskCount', Format = 'int16u', Unknown = 1 },
    [124] = { Name = 'VolumeSetDiskNumber', Format = 'int16u', Unknown = 1 },
    [128] = { Name = 'VolumeBlockSize', Format = 'int16u' },
    [132] = { Name = 'PathTableSize', Format = 'int32u', Unknown = 1 },
    [140] = { Name = 'PathTableLocation', Format = 'int32u', Unknown = 1 },
    [174] = {
        Name = 'RootDirectoryCreateDate',
        Format = 'undef[7]',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            local yr, mo, d, h, mi, s = val:byte(1, 6)
            local tz = val:byte(7)
            if tz > 127 then tz = tz - 256 end
            yr = yr + 1900
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d%s', yr, mo, d, h, mi, s,
                ExifTool.TimeZoneString(tz * 15))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [190] = { Name = 'VolumeSetName', Format = 'string[128]', RawConv = rawStr },
    [318] = { Name = 'Publisher', Format = 'string[128]', RawConv = rawStr },
    [446] = { Name = 'DataPreparer', Format = 'string[128]', RawConv = rawStr },
    [574] = { Name = 'Software', Format = 'string[128]', RawConv = rawStr },
    [702] = { Name = 'CopyrightFileName', Format = 'string[38]', RawConv = rawStr },
    [740] = { Name = 'AbstractFileName', Format = 'string[36]', RawConv = rawStr },
    [776] = { Name = 'BibligraphicFileName', Format = 'string[37]', RawConv = rawStr },
    [813] = {
        Name = 'VolumeCreateDate', Format = dateInfo.Format, Groups = dateInfo.Groups,
        ValueConv = dateInfo.ValueConv, PrintConv = dateInfo.PrintConv,
    },
    [830] = {
        Name = 'VolumeModifyDate', Format = dateInfo.Format, Groups = dateInfo.Groups,
        ValueConv = dateInfo.ValueConv, PrintConv = dateInfo.PrintConv,
    },
    [847] = {
        Name = 'VolumeExpirationDate', Format = dateInfo.Format, Groups = dateInfo.Groups,
        ValueConv = dateInfo.ValueConv, PrintConv = dateInfo.PrintConv,
    },
    [864] = {
        Name = 'VolumeEffectiveDate', Format = dateInfo.Format, Groups = dateInfo.Groups,
        ValueConv = dateInfo.ValueConv, PrintConv = dateInfo.PrintConv,
    },
}

-- ISO Composite tags
ISO.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    VolumeSize = {
        TagID = 'ISO-VolumeSize',
        Require = { [0] = 'ISO:VolumeBlockCount', [1] = 'ISO:VolumeBlockSize' },
        ValueConv = function(_self, val) return val[0] * val[1] end,
        PrintConv = function(_self, val) return ExifTool.ConvertFileSize(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.ISO', nil, ISO)

--------------------------------------------------------------------------------
-- Extract information from an ISO 9660 disk image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid ISO 9660 image
--------------------------------------------------------------------------------
function ISO.ProcessISO(et, dirInfo)
    local raf = dirInfo.RAF
    if not raf:Seek(32768, 0) then return 0 end

    local tagTablePtr
    while true do
        local n, buff = raf:Read(2048)
        if n ~= 2048 then break end
        local b1 = buff:byte(1)
        if not ((b1 <= 3 or b1 == 0xff) and buff:sub(2, 6) == 'CD001') then break end
        if not tagTablePtr then
            et:SetFileType() -- set the FileType tag
            ExifTool.SetByteOrder('II') -- read little-endian values only
            tagTablePtr = et:GetTagTable('lexiftool.ISO.Main')
        end
        local vtype = b1
        et:VPrint(0, 'Volume descriptor type ' .. vtype .. ' (' .. (volumeDescriptorType[vtype] or '') .. ')\n')
        if vtype == 255 then break end -- stop at terminator
        local entry = tagTablePtr[vtype]
        if entry then
            local subTablePtr = et:GetTagTable(entry.SubDirectory.TagTable)
            et:ProcessDirectory({
                DataPt = buff,
                DataPos = raf:Tell() - 2048,
                DirStart = 0,
                DirLen = #buff,
            }, subTablePtr)
        end
    end
    return tagTablePtr and 1 or 0
end

return ISO
