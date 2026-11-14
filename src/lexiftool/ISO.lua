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
-- Port notes:   complete (read-only module).  The hash spreads %rawStr
--               and %dateInfo are spread{} helpers: `rawStr { ... }` adds
--               their entries to the tagInfo.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf, unpack, subst, isMatch, length = perl.sprintf, perl.unpack, perl.subst, perl.isMatch, perl.length
local perlTruthy = perl.truthy
local GetTagTable, SetByteOrder, TimeZoneString = ExifTool.GetTagTable, ExifTool.SetByteOrder, ExifTool.TimeZoneString

local ISO = {}

-- (port helper: Perl's `{ ..., %hash }` -- the entries of %hash are added to
--  the tagInfo)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do t[k] = v end
        return t
    end
end

-- trim trailing spaces and ignore tag if empty
local rawStr = spread {
    RawConv = function(_self, val)
        val = subst(val, [[ +$]], '')
        return length(val) ~= 0 and val or nil
    end,
}

-- tag info for date/time tags
local dateInfo = spread {
    Format = 'undef[17]',
    Groups = { [2] = 'Time' },
    ValueConv = function(_self, val)
        if not isMatch(val, [=[[^0\0 ]]=]) then return nil end -- ignore if empty
        local ok, _, _, _, _, _, _, _, c8 = isMatch(val, [[(?s)(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(.)]])
        if ok then
            val = subst(val, [[(?s)(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(.)]], '$1:$2:$3 $4:$5:$6.$7')
            val = val .. TimeZoneString(unpack('c', c8) * 15)
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
    -- 0 => { Name => 'VolumeType', PrintConv => \%volumeDescriptorType }, # (0 for boot record)
    -- 1 => { Name => 'Identifier',      Format => 'undef[5]' }, # (always "CD001")
    -- 6 => 'VolumeDesriptorVersion', # (always 1)
    -- always extract BootSystem, even if empty, as an indication that this is bootable
      [7] = { Name = 'BootSystem',      Format = 'string[32]', ValueConv = function(_self, val) val = subst(val, [[ +$]], '') return val end },
    [39]  = rawStr { Name = 'BootIdentifier',  Format = 'string[32]' },
}

ISO.PrimaryVolume = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    -- 0 => { Name => 'VolumeType', PrintConv => \%volumeDescriptorType }, # (1 for primary volume)
    -- 1 => { Name => 'Identifier',          Format => 'undef[5]' }, # (always "CD001")
    -- 6 => 'VolumeDesriptorVersion', # (always 1)
      [8] = rawStr { Name = 'System',              Format = 'string[32]' },
     [40] = rawStr { Name = 'VolumeName',          Format = 'string[32]' },
     [80] = { Name = 'VolumeBlockCount',    Format = 'int32u' },
    [120] = { Name = 'VolumeSetDiskCount',  Format = 'int16u', Unknown = 1 },
    [124] = { Name = 'VolumeSetDiskNumber', Format = 'int16u', Unknown = 1 },
    [128] = { Name = 'VolumeBlockSize',     Format = 'int16u' },
    [132] = { Name = 'PathTableSize',       Format = 'int32u', Unknown = 1 },
    [140] = { Name = 'PathTableLocation',   Format = 'int32u', Unknown = 1 },
    [174] = {
        Name = 'RootDirectoryCreateDate',
        Format = 'undef[7]',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            local a = { unpack('C6c', val) }
            a[1] = a[1] + 1900
            a[7] = TimeZoneString(a[7] * 15)
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d%s', table.unpack(a))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [190] = rawStr { Name = 'VolumeSetName',       Format = 'string[128]' },
    [318] = rawStr { Name = 'Publisher',           Format = 'string[128]' },
    [446] = rawStr { Name = 'DataPreparer',        Format = 'string[128]' },
    [574] = rawStr { Name = 'Software',            Format = 'string[128]' },
    [702] = rawStr { Name = 'CopyrightFileName',   Format = 'string[38]' },
    [740] = rawStr { Name = 'AbstractFileName',    Format = 'string[36]' },
    [776] = rawStr { Name = 'BibligraphicFileName',Format = 'string[37]' },
    [813] = dateInfo { Name = 'VolumeCreateDate' },
    [830] = dateInfo { Name = 'VolumeModifyDate' },
    [847] = dateInfo { Name = 'VolumeExpirationDate' },
    [864] = dateInfo { Name = 'VolumeEffectiveDate' },
   --881 => 'FileStructureVersion', # (always 1)
}

-- ISO Composite tags
ISO.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    VolumeSize = {
        TagID = 'ISO-VolumeSize',
        Require = {
            [0] = 'ISO:VolumeBlockCount',
            [1] = 'ISO:VolumeBlockSize',
        },
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
function ISO.ProcessISO(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, tagTablePtr
    local n

    -- verify this is a valid ISO file
    if not perlTruthy(raf:Seek(32768, 0)) then return 0 end

    while true do
        n, buff = raf:Read(2048)
        if n ~= 2048 then break end
        if not isMatch(buff, [[^[\0-\x03\xff]CD001]]) then break end
        if not tagTablePtr then
            et:SetFileType() -- set the FileType tag
            SetByteOrder('II') -- read little-endian values only
            tagTablePtr = GetTagTable(nil, 'lexiftool.ISO.Main')
        end
        local type_ = unpack('C', buff)
        et:VPrint(0, 'Volume descriptor type ' .. type_ .. ' (' .. perl.str(volumeDescriptorType[type_]) .. ')\n')
        if type_ == 255 then break end   -- stop at terminator
        if tagTablePtr[type_] then
            local subTablePtr = GetTagTable(nil, tagTablePtr[type_].SubDirectory.TagTable)
            local dirInfo_ = {
                DataPt   = buff,
                DataPos  = raf:Tell() - 2048,
                DirStart = 0,
                DirLen   = length(buff),
            }
            et:ProcessDirectory(dirInfo_, subTablePtr)
        end
    end
    return tagTablePtr and 1 or 0
end

return ISO
