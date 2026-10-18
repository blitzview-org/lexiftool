--------------------------------------------------------------------------------
-- File:         lexiftool/Red.lua
-- Ported from:  lib/Image/ExifTool/Red.pm
--
-- Description:  Read Redcode R3D video files
--
-- Revisions:    2018-01-25 - P. Harvey Created
--
-- References:   1) http://www.wikiwand.com/en/REDCODE
--
-- Port notes:   read subset. Ported: ProcessR3D (the block reader with the
--               version-1/version-2 header dispatch, the "rdi"/"rda"/"rdx"
--               record skipping, the Red-directory search-and-sanity-check,
--               and the per-tag format-code dispatch), the RED1/RED2 header
--               tables, and the Main table. Deferred (unexercised): the
--               verbose dumps.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local str = perl.str

local Red = {}

-- RED format codes (ref PH)
local redFormat = {
    [0] = 'int8u',
    [1] = 'string',
    [2] = 'float',
    [3] = 'int8u', -- (how is this different than 0?)
    [4] = 'int16u',
    [5] = 'int8s', -- (not sure about this)
    [6] = 'int32s',
    [7] = 'undef', -- (mixed-format structure?)
    [8] = 'int32u', -- (NC)
    [9] = 'undef', -- ? (seen 256 bytes, all zero)
}

-- error strings
local errTrunc = 'Truncated R3D file'

-- RED directory tags (ref PH) (upstream %Image::ExifTool::Red::Main)
Red.Main = {
    GROUPS = { [2] = 'Camera' },
    NOTES = 'Tags extracted from Redcode R3D video files.',
    VARS = { ALPHA_FIRST = 1 },
    RED1 = { Name = 'Red1Header', SubDirectory = { TagTable = 'lexiftool.Red.RED1' } },
    RED2 = { Name = 'Red2Header', SubDirectory = { TagTable = 'lexiftool.Red.RED2' } },
    -- (upper 4 bits of tag ID are the format code)
    -- ---- format 1 (string) ----
    [0x1000] = 'StartEdgeCode',
    [0x1001] = { Name = 'StartTimecode', Groups = { [2] = 'Time' } },
    [0x1002] = {
        Name = 'OtherDate1',
        Groups = { [2] = 'Time' },
        -- format is "YYYY_MM_DD[_TZ?]"
        ValueConv = function(_self, val)
            val = str(val):gsub('(%d%d%d%d)_(%d%d)_', '%1:%2:', 1)
            return (val:gsub('_', ' '))
        end,
    },
    [0x1003] = {
        Name = 'OtherDate2',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            val = str(val):gsub('(%d%d%d%d)_(%d%d)_', '%1:%2:', 1)
            return (val:gsub('_', ' '))
        end,
    },
    [0x1004] = {
        Name = 'OtherDate3',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            val = str(val):gsub('(%d%d%d%d)_(%d%d)_', '%1:%2:', 1)
            return (val:gsub('_', ' '))
        end,
    },
    [0x1005] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return (str(val):gsub('(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)', '%1:%2:%3 %4:%5:', 1))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x1006] = 'SerialNumber',
    [0x1019] = 'CameraType',
    [0x101a] = { Name = 'ReelNumber', Groups = { [2] = 'Video' } },
    [0x101b] = { Name = 'Take', Groups = { [2] = 'Video' } },
    [0x1023] = {
        Name = 'DateCreated',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return (str(val):gsub('(%d%d%d%d)(%d%d)', '%1:%2:', 1))
        end,
    },
    [0x1024] = {
        Name = 'TimeCreated',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return (str(val):gsub('(%d%d)(%d%d)', '%1:%2:', 1))
        end,
    },
    [0x1025] = 'FirmwareVersion',
    [0x1029] = { Name = 'ReelTimecode', Groups = { [2] = 'Time' } },
    [0x102a] = 'StorageType',
    [0x1030] = {
        Name = 'StorageFormatDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return (str(val):gsub('(%d%d%d%d)(%d%d)', '%1:%2:', 1))
        end,
    },
    [0x1031] = {
        Name = 'StorageFormatTime',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return (str(val):gsub('(%d%d)(%d%d)', '%1:%2:', 1))
        end,
    },
    [0x1032] = 'StorageSerialNumber',
    [0x1033] = 'StorageModel',
    [0x1036] = 'AspectRatio',
    -- 0x1041 - seen 'NA'
    [0x1042] = 'Revision',
    -- 0x1051 - seen 'C', 'L'
    -- 0x1052 - seen 'E9'
    [0x1056] = 'OriginalFileName',
    [0x106e] = 'LensMake',
    [0x106f] = 'LensNumber', -- (last 2 hex digits are LensType)
    [0x1070] = 'LensModel',
    [0x1071] = { Name = 'Model', Description = 'Camera Model Name' },
    [0x107c] = { Name = 'CameraOperator', Groups = { [2] = 'Author' } },
    [0x1086] = { Name = 'VideoFormat', Groups = { [2] = 'Video' } },
    [0x1096] = 'Filter', -- optical low-pass filter
    [0x10a0] = 'Brain',
    [0x10a1] = 'Sensor',
    [0x10be] = 'Quality',
    -- ---- format 2 (float) ----
    [0x200d] = 'ColorTemperature',
    -- 0x200e - (sometimes this is frame rate)
    -- 0x2015 - seen '1 1 1' (RGBGain or RGBGamma?)
    [0x204b] = 'RGBCurves', -- (blackx/y,toex/y,midx/y,kneex/y,whitex/y)
    [0x2066] = {
        Name = 'OriginalFrameRate',
        Groups = { [2] = 'Video' },
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    -- ---- format 3 (int8u?) ----
    -- ---- format 4 (int16u) ----
    [0x4037] = { Name = 'CropArea' }, -- (NC)
    [0x403b] = 'ISO',
    -- 0x404e - related to CropArea (or "0 0 0 0")
    [0x406a] = { Name = 'FNumber', ValueConv = function(_self, val) return val / 10 end },
    [0x406b] = 'FocalLength',
    -- 0x4084 - related to ISO?
    -- 0x4087 - related to ISO?
    -- ---- format 5 (int8s?) ----
    -- ---- format 6 (int32s) ----
    [0x606c] = {
        Name = 'FocusDistance',
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return perl.str(val) .. ' m' end,
    },
    -- ---- format 7 (undef? structure?) ----
    -- ---- format 8 (int32u?) ----
    -- ---- format 9 (undef?) ----
}

-- RED1 file header (ref PH) (upstream %Red::RED1)
Red.RED1 = {
    GROUPS = { [2] = 'Video' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'Redcode version 1 header.',
    -- 0x00 - int32u: length of header
    -- 0x04 - string: "RED1"
    -- 0x0a - string: "R1"
    [0x07] = { Name = 'RedcodeVersion', Format = 'string[1]' },
    -- 0x0e - looks funny; my sample has a value of 43392 here
    -- 0x0e => { Name => 'AudioSampleRate', Format => 'int16u' },
    [0x36] = { Name = 'ImageWidth', Format = 'int16u' },
    [0x3a] = { Name = 'ImageHeight', Format = 'int16u' }, -- PH (ref 1 gave 0x3c)
    [0x3e] = { -- PH (ref 1 gave 0x42 for denom)
        Name = 'FrameRate',
        Format = 'rational32u',
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    [0x43] = { Name = 'OriginalFileName', Format = 'string[32]' },
}

-- RED2 file header (ref PH) (upstream %Red::RED2)
Red.RED2 = {
    GROUPS = { [2] = 'Video' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'Redcode version 2 header.',
    -- 0x00 - int32u: length of header
    -- 0x04 - string: "RED2"
    [0x07] = { Name = 'RedcodeVersion', Format = 'string[1]' },
    -- 0x08 - seen 0x05
    -- 0x09 - seen 0x0d,0x0f,0x10
    -- 0x0a - string: "R2"
    -- 0x0c - seen 0x04,0x05,0x07,0x08,0x0b,0x0c
    -- 0x0d - seen 0x01,0x08 (and 0x09 in block 1)
    -- 0x0e - int16u: seen 3072
    -- 0x10 - looks like some sort of 32-byte hash or something (same in other blocks)
    -- 0x30-0x3f - mostly 0x00's with a couple of 0x01's
    -- 0x40 - int8u: count of 0x18-byte "rdi" records
    -- 0x41-0x43 - seen "\0\0\x01"
    -- ---- rdi record: (0x18 bytes long) ----
    -- 0x44 - string: "rdi#" (where number is index of "rdi" record, starting at \x01)
    [0x4c] = { Name = 'ImageWidth', Format = 'int32u' },
    [0x50] = { Name = 'ImageHeight', Format = 'int32u' },
    -- 0x54 - seen 0x11,0x13,0x15 (and 0x03 in "rdi\x02" record)
    -- 0x55 - seen 0x02
    [0x56] = {
        Name = 'FrameRate',
        Format = 'int16u[3]',
        ValueConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
            -- (upstream `($a[1] * 0x10000 + $a[2]) / $a[0]`)
            return (a[2] * 0x10000 + a[3]) / a[1]
        end,
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    -- (immediately following last "rdi" record is a
    --  Red directory beginning with int16u size)
}

--------------------------------------------------------------------------------
-- Process metadata from a Redcode R3D video (ref PH) (upstream ProcessR3D)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid R3D file
--------------------------------------------------------------------------------
function Red.ProcessR3D(et, dirInfo)
    local raf = dirInfo.RAF

    -- R3D file structure:
    -- - each block starts with int32u block size followed by 4-byte block type
    -- - first block type is either "RED1" (version 1) or "RED2" (version 2)
    -- - blocks begin on even 0x1000 byte boundaries for version 2 files

    -- validate the file header
    local n0, buff = raf:Read(8)
    if n0 ~= 8 then return 0 end
    -- upstream: `$buff =~ /^\0\0..RED(1|2)/s` with `my $ver = $1` (PCRE2 via
    -- the facade -- Lua patterns have no alternation)
    local ver = perl.matches(buff, '(?s)^\\0\\0..RED(1|2)')
    if not ver then return 0 end
    local size = perl.unpack('N', buff)
    if not size or size < 8 then return 0 end

    et:SetFileType()
    ExifTool.SetByteOrder('MM')
    local tagTablePtr = et:GetTagTable('lexiftool.Red.Main')
    local dataPos = 0

    -- read the first block of the file
    local n1, buf2 = raf:Read(size - 8)
    if n1 ~= size - 8 then
        et:Warn(errTrunc)
        return 0
    end
    buff = buff .. buf2

    -- extract tags from the header
    et:HandleTag(tagTablePtr, 'RED' .. ver, nil, { DataPt = buff })

    -- read the second block from a version 1 file because the first block
    -- doesn't contain a Red directory
    local pos
    if ver == '1' then
        -- (read more than we need)
        local n2, b = raf:Read(0x10000)
        if n2 == 0 then
            et:Warn(errTrunc)
            return 0
        end
        buff = b
        dataPos = dataPos + size
        pos = 0x22 -- directory starts at offset 0x22
    else
        -- calculate position of Red directory start
        pos = 0x44
        if #buff < pos then
            et:Warn(errTrunc)
            return 0
        end
        pos = pos + ExifTool.Get8u(buff, 0x40) * 0x18 -- skip "rdi" records
        pos = pos + ExifTool.Get8u(buff, 0x41) * 0x14 -- skip "rda" records
        pos = pos + ExifTool.Get8u(buff, 0x42) * 0x10 -- skip "rdx" records
    end
    local dirLen
    local dirEnd
    if pos + 8 > #buff then
        dirLen = 0 -- find directory the hard way
    else
        dirLen = ExifTool.Get16u(buff, pos) -- get length of Red directory
        pos = pos + 2 -- skip length word
    end
    -- do sanity check on the directory size (in case our assumptions were wrong)
    if not (dirLen and dirLen >= 300 and dirLen < 2048 and pos + dirLen <= #buff) then
        -- tag 0x1000 with length 0x000f should be near the directory start
        local found = buff:find('\0\15\16[\0\6]')
        if not found then
            et:Warn("Can't find Red directory. Please submit sample for testing")
            return 0
        end
        pos = found - 1 - 4
        dirEnd = #buff
        dirLen = nil
        et:Warn('This R3D file is different. Please submit a sample for testing')
    else
        dirEnd = pos + dirLen
    end

    -- process the first Red directory
    while pos + 4 <= dirEnd do
        local len = ExifTool.Get16u(buff, pos)
        if len < 4 or pos + len > dirEnd then break end
        local tag = ExifTool.Get16u(buff, pos + 2)
        local fmt = redFormat[math.floor(tag / 0x1000)] -- format is top 4 bits of tag ID (ref PH)
        if not fmt then
            if dirLen then et:Warn('Unknown format code') end
            break
        end
        et:HandleTag(tagTablePtr, tag, nil, {
            DataPt = buff,
            DataPos = dataPos,
            Start = pos + 4,
            Size = len - 4,
            Format = fmt,
        })
        pos = pos + len
    end
    return 1
end

return Red