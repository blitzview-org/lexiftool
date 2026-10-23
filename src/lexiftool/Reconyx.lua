--------------------------------------------------------------------------------
-- File:         lexiftool/Reconyx.lua
-- Ported from:  lib/Image/ExifTool/Reconyx.pm
--
-- Description:  Reconyx maker notes tags
--
-- Revisions:    2011-01-11 - P. Harvey Created
--
-- References:   1) RCNX_MN10.pdf (courtesy of Reconyx Inc.)
--               2) ultrafire_makernote.pdf (courtesy of Reconyx Inc.)
--               3) Reconyx private communication
--               4) "Reconyx Metadata 1_4.pdf"
--
-- Port notes:   complete: all five tag tables (HyperFire, UltraFire,
--               HyperFire2, MicroFire, HyperFire4K) in upstream order, with
--               every ValueConv/PrintConv and their Inv counterparts.
--               Reconyx.pm has no subs of its own -- all five tables are
--               plain ProcessBinaryData tables, wired from MakerNotes.Main's
--               `MakerNoteReconyx*` entries.  The `%versionInfo`/
--               `%convUnicode` hashes upstream spreads into single tag
--               entries become the `versionInfo()`/`convUnicode()` helpers
--               below, as MISB.lua does for the same construct.
--               `CHECK_PROC => \&Image::ExifTool::CheckBinaryData` is
--               Writer.CheckBinaryData.
--               The tables carry WRITE_PROC, so they are part of the
--               generated write index in TagLookup.lua and a bare
--               `-Reconyx:Tag=` resolves.
--               No vendored test image carries Reconyx maker notes.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local unpack = perl.unpack
local pack = perl.pack
local split = perl.split
local join = perl.join
local matches = perl.matches
local findAll = perl.findAll
local subst = perl.subst
local reverse = perl.reverse
local num = perl.num
local ord = perl.ord
local sprintf = perl.sprintf
local str = perl.str

local Reconyx = {}

-- info for Type2 version tags
local function versionInfo(t)
    t.Format = 'undef[7]'
    t.ValueConv = function(_self, val) return sprintf('%.2x.%.2x %.4x:%.2x:%.2x Rev.%s', unpack('CCvCCa', val)) end
    t.ValueConvInv = function(_self, val)
        local v = { matches(str(val), [[(?i)^([0-9a-f]+)\.([0-9a-f]+) (\d{4}):(\d{2}):(\d{2})\s*Rev\.(\w)]]) }
        if v[1] == nil then return nil end
        return pack('CCvCCa', tonumber(v[1], 16), tonumber(v[2], 16), tonumber(v[3], 16),
                              tonumber(v[4], 16), tonumber(v[5], 16), v[6])
    end
    return t
end

local moonPhase = {
    [0] = 'New',
    [1] = 'New Crescent',
    [2] = 'First Quarter',
    [3] = 'Waxing Gibbous',
    [4] = 'Full',
    [5] = 'Waning Gibbous',
    [6] = 'Last Quarter',
    [7] = 'Old Crescent',
}

local sunday0 = {
    [0] = 'Sunday',
    [1] = 'Monday',
    [2] = 'Tuesday',
    [3] = 'Wednesday',
    [4] = 'Thursday',
    [5] = 'Friday',
    [6] = 'Saturday',
}

local sunday1 = {
    [1] = 'Sunday',
    [2] = 'Monday',
    [3] = 'Tuesday',
    [4] = 'Wednesday',
    [5] = 'Thursday',
    [6] = 'Friday',
    [7] = 'Saturday',
}

local function convUnicode(t)
    t.ValueConv = function(self, val) return self:Decode(val, 'UTF16', 'II') end
    t.ValueConvInv = function(self, val) return self:Encode(val, 'UTF16', 'II') end
    return t
end

-- maker notes for Reconyx HyperFire cameras (ref PH)
Reconyx.HyperFire = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    TAG_PREFIX = 'Reconyx',
    FORMAT = 'int16u',
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    NOTES = [[
        The following tags are extracted from the maker notes of Reconyx RapidFire
        and HyperFire models such as the HC500, HC600 and PC900.
    ]],
    [0x00] = { -- #1
        Name = 'MakerNoteVersion',
        Writable = 0, -- (we use this for identification, 0xf101 --> rev 1.0)
        PrintConv = function(_self, val) return sprintf('0x%.4x', val) end,
        PrintConvInv = function(_self, val) return tonumber(str(val), 16) end,
    },
    [0x01] = { -- #1
        Name = 'FirmwareVersion',
        Format = 'int16u[3]',
        Writable = 0, -- (we use this for identification, 0x0003 --> ver 2 or 3)
        PrintConv = function(_self, val) return (str(val):gsub(' ', '.')) end, -- upstream: `$val=~tr/ /./; $val`
    },
    [0x04] = { -- #1
        Name = 'FirmwareDate',
        Format = 'int16u[2]',
        ValueConv = function(_self, val)
            local v = split(' ', str(val))
            return sprintf('%.4x:%.2x:%.2x', num(v[1]), num(v[2]) >> 8, num(v[2]) & 0xff)
        end,
        ValueConvInv = function(_self, val)
            local v = split(':', str(val))
            return tonumber(v[1], 16) .. ' ' .. tonumber(v[2] .. v[3], 16)
        end,
    },
    [0x06] = {
        Name = 'TriggerMode',
        Format = 'string[2]',
        PrintConv = {
            C = 'CodeLoc Not Entered', -- #1
            E = 'External Sensor', -- #1
            M = 'Motion Detection',
            T = 'Time Lapse',
        },
    },
    [0x07] = {
        Name = 'Sequence',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) return subst(str(val), ' ', ' of ') end,
        PrintConvInv = function(_self, val) return join(' ', findAll(str(val), [[\d+]])) end,
    },
    [0x09] = { -- #1
        Name = 'EventNumber',
        Format = 'int16u[2]',
        ValueConv = function(_self, val) local v = split(' ', str(val)) return (num(v[1]) << 16) + num(v[2]) end,
        ValueConvInv = function(_self, val) return (num(val) >> 16) .. ' ' .. (num(val) & 0xffff) end,
    },
    [0x0b] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'int16u[6]',
        Groups = { [2] = 'Time' },
        Priority = 0, -- (not as reliable as EXIF)
        Shift = 'Time',
        ValueConv = function(_self, val)
            local a = split(' ', str(val))
            for i = 1, #a do a[i] = num(a[i]) end -- (Perl numifies on use)
            -- have seen these values written big-endian when everything else is little-endian
            if a[1] & 0xff00 ~= 0 and a[1] & 0xff == 0 then
                for i = 1, #a do a[i] = (a[i] >> 8) | ((a[i] & 0xff) << 8) end
            end
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', a[6], a[4], a[5], a[3], a[2], a[1])
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            if #a < 6 then return nil end
            return join(' ', { a[6], a[5], a[4], a[2], a[3], a[1] })
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x12] = {
        Name = 'MoonPhase',
        Groups = { [2] = 'Time' },
        PrintConv = moonPhase,
    },
    [0x13] = {
        Name = 'AmbientTemperatureFahrenheit',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' F' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x14] = {
        Name = 'AmbientTemperature',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' C' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x15] = convUnicode{ Name = 'SerialNumber', Format = 'unicode[15]' },
    [0x24] = 'Contrast', -- #1
    [0x25] = 'Brightness', -- #1
    [0x26] = 'Sharpness', -- #1
    [0x27] = 'Saturation', -- #1
    [0x28] = {
        Name = 'InfraredIlluminator',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x29] = 'MotionSensitivity', -- #1
    [0x2a] = { -- #1
        Name = 'BatteryVoltage',
        ValueConv = function(_self, val) return val / 1000 end,
        ValueConvInv = function(_self, val) return num(val) * 1000 end,
        PrintConv = function(self, val) return self.NumStr(val) .. ' V' end,
        PrintConvInv = function(_self, val) return subst(str(val), [[ ?V$]], '') end,
    },
    [0x2b] = {
        Name = 'UserLabel',
        Format = 'string[22]', -- #1 (but manual says 16-char limit)
    },
}

-- maker notes for Reconyx UltraFire cameras (ref PH)
Reconyx.UltraFire = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    TAG_PREFIX = 'Reconyx',
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    NOTES = 'Maker notes tags for Reconyx UltraFire models.',
  -- 0x0a - int32u makernote ID 0x00020000 #2
  -- 0x0e - int16u makernote size #2
  -- 0x12 - int32u public structure ID 0x07f100001 #2
  -- 0x16 - int16u public structure size #2 (0x5d = start of public ID to end of UserLabel)
    [0x18] = versionInfo{ Name = 'FirmwareVersion'   },
    [0x1f] = versionInfo{ Name = 'Micro1Version'     }, -- #2
    [0x26] = versionInfo{ Name = 'BootLoaderVersion' }, -- #2
    [0x2d] = versionInfo{ Name = 'Micro2Version'     }, -- #2
    [0x34] = {
        Name = 'TriggerMode',
        Format = 'undef[1]',
        PrintConv = {
            M = 'Motion Detection',
            T = 'Time Lapse',
            P = 'Point and Shoot', -- #2
        },
    },
    [0x35] = {
        Name = 'Sequence',
        Format = 'int8u[2]',
        PrintConv = function(_self, val) return subst(str(val), ' ', ' of ') end,
        PrintConvInv = function(_self, val) return join(' ', findAll(str(val), [[\d+]])) end,
    },
    [0x37] = { -- #2
        Name = 'EventNumber',
        Format = 'int32u',
    },
    [0x3b] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'int8u[7]',
        Groups = { [2] = 'Time' },
        Priority = 0, -- (not as reliable as EXIF)
        Shift = 'Time',
        ValueConv = function(_self, val) return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', reverse(unpack('C5v', val))) end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            if #a < 6 then return nil end
            return pack('C5v', num(a[6]), num(a[5]), num(a[4]), num(a[3]), num(a[2]), num(a[1]))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x42] = { -- #2
        Name = 'DayOfWeek',
        Groups = { [2] = 'Time' },
        PrintConv = sunday0,
    },
    [0x43] = {
        Name = 'MoonPhase',
        Groups = { [2] = 'Time' },
        PrintConv = moonPhase,
    },
    [0x44] = {
        Name = 'AmbientTemperatureFahrenheit',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' F' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x46] = {
        Name = 'AmbientTemperature',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' C' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x48] = {
        Name = 'Illumination',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x49] = {
        Name = 'BatteryVoltage',
        Format = 'int16u',
        ValueConv = function(_self, val) return val / 1000 end,
        ValueConvInv = function(_self, val) return num(val) * 1000 end,
        PrintConv = function(self, val) return self.NumStr(val) .. ' V' end,
        PrintConvInv = function(_self, val) return subst(str(val), [[ ?V$]], '') end,
    },
    [0x4b] = { Name = 'SerialNumber', Format = 'string[15]' },
    [0x5a] = { Name = 'UserLabel',    Format = 'string[21]' },
}

-- maker notes for Reconyx HF2 PRO cameras (ref 3)
Reconyx.HyperFire2 = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    TAG_PREFIX = 'Reconyx',
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    NOTES = 'Maker notes tags for Reconyx HyperFire 2 models.',
  -- 0x0a => { Name => 'StructureVersion',   Format => 'int16u' },
  -- 0x0c => { Name => 'ParentFileSize',     Format => 'int32u' },
    [0x10] = { Name = 'FileNumber',         Format = 'int16u' },
    [0x12] = { Name = 'DirectoryNumber',    Format = 'int16u' },
    [0x14] = {
        Name = 'DirectoryCreateDate',
        Format = 'int16u[2]',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        -- similar to ZIP date/time, but date word comes first
        ValueConv = function(_self, val)
            local a = split([[ ]], str(val))
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                (num(a[1]) >> 9)  + 1980, -- year
                (num(a[1]) >> 5)  & 0x0f, -- month
                 num(a[1])        & 0x1f, -- day
                (num(a[2]) >> 11) & 0x1f, -- hour
                (num(a[2]) >> 5)  & 0x3f, -- minute
                (num(a[2])        & 0x1f) * 2  -- second
            )
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            return sprintf('%d %d', ((num(a[1]) - 1980) << 9) | (num(a[2]) << 5) | num(a[3]),
                (num(a[4]) << 11) | (num(a[5]) << 5) | (num(a[6]) // 2))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
  -- 0x18 - int16[8] SDCardLabel
  -- 0x28 => { Name => 'MakerNoteVersion',   Format => 'int16u' },
    [0x2a] = {
        Name = 'FirmwareVersion',
        Format = 'int16u[3]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) return sprintf('%d.%d%c', num(a[1]), num(a[2]), num(a[3])) end,
        ValueConvInv = function(_self, val)
            local v1, v2, v3 = matches(str(val), [[(\d+)\.(\d+)([a-zA-Z])]])
            return v1 and (v1 .. ' ' .. v2 .. ' ' .. ord(v3)) or nil
        end,
    },
    [0x30] = {
        Name = 'FirmwareDate',
        Format = 'int16u[2]',
        ValueConv = function(_self, val)
            local y, d = table.unpack(split(' ', str(val)))
            return sprintf('%.4x:%.2x:%.2x', num(y), num(d) >> 8, num(d) & 0xff)
        end,
        ValueConvInv = function(_self, val) local a = split(':', str(val)) return tonumber(a[1], 16) .. ' ' .. tonumber(a[2] .. a[3], 16) end,
    },
    [0x34] = {
        Name = 'TriggerMode', -- #PH (NC) (called EventType in the Reconyx code)
        Format = 'string[2]',
        PrintConv = {
            M = 'Motion Detection', -- (seen this one only)
            T = 'Time Lapse', -- (NC)
            P = 'Point and Shoot', -- (NC)
        },
    },
    [0x36] = {
        Name = 'Sequence',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) return subst(str(val), ' ', ' of ') end,
        PrintConvInv = function(_self, val) return join(' ', findAll(str(val), [[\d+]])) end,
    },
    [0x3a] = {
        Name = 'EventNumber',
        Format = 'int16u[2]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) return (num(a[1]) << 16) + num(a[2]) end,
        ValueConvInv = function(_self, val) return (num(val) >> 16) .. ' ' .. (num(val) & 0xffff) end,
    },
    [0x3e] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'int16u[6]',
        Groups = { [2] = 'Time' },
        Priority = 0, -- (not as reliable as EXIF)
        Shift = 'Time',
        ValueConv = function(_self, val)
            local a = split(' ', str(val))
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', reverse(table.unpack(a)))
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            if #a < 6 then return nil end
            return join(' ', { a[6], a[5], a[4], a[3], a[2], a[1] })
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x4a] = { -- #2
        Name = 'DayOfWeek',
        Groups = { [2] = 'Time' },
        Format = 'int16u',
        PrintConv = sunday0,
    },
    [0x4c] = {
        Name = 'MoonPhase',
        Groups = { [2] = 'Time' },
        Format = 'int16u',
        PrintConv = moonPhase,
    },
    [0x4e] = {
        Name = 'AmbientTemperatureFahrenheit',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' F' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x50] = {
        Name = 'AmbientTemperature',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' C' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x52] = { Name = 'Contrast',           Format = 'int16u' },
    [0x54] = { Name = 'Brightness',         Format = 'int16u' },
    [0x56] = { Name = 'Sharpness',          Format = 'int16u' },
    [0x58] = { Name = 'Saturation',         Format = 'int16u' },
    [0x5a] = { Name = 'Flash',              Format = 'int16u', PrintConv = { [0] = 'Off', [1] = 'On' } },
    [0x5c] = { Name = 'AmbientInfrared',    Format = 'int16u' },
    [0x5e] = { Name = 'AmbientLight',       Format = 'int16u' },
    [0x60] = { Name = 'MotionSensitivity',  Format = 'int16u' },
    [0x62] = { Name = 'BatteryVoltage',     Format = 'int16u' },
    [0x64] = { Name = 'BatteryVoltageAvg',  Format = 'int16u' },
    [0x66] = { Name = 'BatteryType',        Format = 'int16u' },
    [0x68] = { Name = 'UserLabel',          Format = 'string[22]' },
    [0x7e] = convUnicode{ Name = 'SerialNumber',       Format = 'unicode[15]' },
}

-- maker notes for Reconyx MicroFire cameras (ref 4) (no samples for testing)
Reconyx.MicroFire = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    TAG_PREFIX = 'Reconyx',
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    NOTES = 'Maker notes tags for Reconyx MicroFire cameras.',
    [0x10] = { Name = 'FileNumber',         Format = 'int16u' },
    [0x12] = { Name = 'DirectoryNumber',    Format = 'int16u' },
    [0x14] = {
        Name = 'DirectoryCreateDate',
        Format = 'int16u[2]',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        -- similar to ZIP date/time, but date word comes first
        ValueConv = function(_self, val)
            local a = split([[ ]], str(val))
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                (num(a[1]) >> 9)  + 1980, -- year
                (num(a[1]) >> 5)  & 0x0f, -- month
                 num(a[1])        & 0x1f, -- day
                (num(a[2]) >> 11) & 0x1f, -- hour
                (num(a[2]) >> 5)  & 0x3f, -- minute
                (num(a[2])        & 0x1f) * 2  -- second
            )
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            return sprintf('%d %d', ((num(a[1]) - 1980) << 9) | (num(a[2]) << 5) | num(a[3]),
                (num(a[4]) << 11) | (num(a[5]) << 5) | (num(a[6]) // 2))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x18] = {
        Name = 'SDCardID',
        Format = 'int16u[8]',
        PrintConv = function(_self, val)
            local a = split([[ ]], str(val))
            for i = 1, #a do a[i] = sprintf('%.4x', num(a[i])) end
            return join('-', a)
        end,
    },
    -- 0x28 - INFO structure version
    [0x2a] = {
        Name = 'FirmwareVersion',
        Format = 'int16u[3]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) return sprintf('%d.%d%c', num(a[1]), num(a[2]), num(a[3])) end,
        ValueConvInv = function(_self, val)
            local v1, v2, v3 = matches(str(val), [[(\d+)\.(\d+)([a-zA-Z])]])
            return v1 and (v1 .. ' ' .. v2 .. ' ' .. ord(v3)) or nil
        end,
    },
    [0x30] = {
        Name = 'FirmwareDate',
        Format = 'int16u[2]',
        ValueConv = function(_self, val)
            local y, d = table.unpack(split(' ', str(val)))
            return sprintf('%.4x:%.2x:%.2x', num(y), num(d) >> 8, num(d) & 0xff)
        end,
        ValueConvInv = function(_self, val) local a = split(':', str(val)) return tonumber(a[1], 16) .. ' ' .. tonumber(a[2] .. a[3], 16) end,
    },
    [0x34] = {
        Name = 'BluetoothFirmwareVersion',
        Format = 'int16u[3]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) return sprintf('%d.%d%c', num(a[1]), num(a[2]), num(a[3])) end,
        ValueConvInv = function(_self, val)
            local v1, v2, v3 = matches(str(val), [[(\d+)\.(\d+)([a-zA-Z])]])
            return v1 and (v1 .. ' ' .. v2 .. ' ' .. ord(v3)) or nil
        end,
    },
    [0x3a] = {
        Name = 'BluetoothFirmwareDate',
        Format = 'int16u',
        ValueConv = function(_self, val)
            return sprintf('%.4d:%.2d:%.2d',
                (num(val) >> 9)  + 1980, -- year
                (num(val) >> 5)  & 0x0f, -- month
                 num(val)        & 0x1f  -- day
            )
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            return ((num(a[1]) - 1980) << 9) | (num(a[2]) << 5) | num(a[3])
        end,
    },
    [0x3c] = {
        Name = 'WifiFirmwareVersion',
        Format = 'int16u[3]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) return sprintf('%d.%d%c', num(a[1]), num(a[2]), num(a[3])) end,
        ValueConvInv = function(_self, val)
            local v1, v2, v3 = matches(str(val), [[(\d+)\.(\d+)([a-zA-Z])]])
            return v1 and (v1 .. ' ' .. v2 .. ' ' .. ord(v3)) or nil
        end,
    },
    [0x42] = {
        Name = 'WifiFirmwareDate',
        Format = 'int16u',
        ValueConv = function(_self, val)
            return sprintf('%.4d:%.2d:%.2d',
                (num(val) >> 9)  + 1980, -- year
                (num(val) >> 5)  & 0x0f, -- month
                 num(val)        & 0x1f  -- day
            )
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            return ((num(a[1]) - 1980) << 9) | (num(a[2]) << 5) | num(a[3])
        end,
    },
    [0x44] = {
        Name = 'TriggerMode',
        Format = 'string[2]',
        PrintConv = {
            M = 'Motion Sensor',
            E = 'External Sensor',
            T = 'Time Lapse',
            C = 'CodeLoc Not Entered',
        },
    },
    [0x46] = {
        Name = 'Sequence',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) return subst(str(val), ' ', ' of ') end,
        PrintConvInv = function(_self, val) return join(' ', findAll(str(val), [[\d+]])) end,
    },
    [0x4a] = {
        Name = 'EventNumber',
        Format = 'int16u[2]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) return (num(a[1]) << 16) + num(a[2]) end,
        ValueConvInv = function(_self, val) return (num(val) >> 16) .. ' ' .. (num(val) & 0xffff) end,
    },
    [0x4e] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'int16u[6]',
        Groups = { [2] = 'Time' },
        Priority = 0, -- (not as reliable as EXIF)
        Shift = 'Time',
        ValueConv = function(_self, val)
            local a = split(' ', str(val))
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', a[6], a[4], a[5], a[3], a[2], a[1])
        end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            if #a < 6 then return nil end
            return join(' ', { a[6], a[5], a[4], a[2], a[3], a[1] })
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x5a] = {
        Name = 'DayOfWeek',
        Format = 'int16u',
        Groups = { [2] = 'Time' },
        PrintConv = sunday1,
    },
    [0x5c] = {
        Name = 'MoonPhase',
        Format = 'int16u',
        Groups = { [2] = 'Time' },
        PrintConv = moonPhase,
    },
    [0x5e] = {
        Name = 'AmbientTemperatureFahrenheit',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' F' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x60] = {
        Name = 'AmbientTemperature',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' C' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x62] = { Name = 'Contrast',           Format = 'int16u' },
    [0x64] = { Name = 'Brightness',         Format = 'int16u' },
    [0x66] = { Name = 'Sharpness',          Format = 'int16u' },
    [0x68] = { Name = 'Saturation',         Format = 'int16u' },
    [0x6a] = { Name = 'Flash',              Format = 'int8u', PrintConv = { [0] = 'Off', [1] = 'On' } },
    [0x6c] = { Name = 'AmbientInfrared',    Format = 'int16u' },
    [0x6e] = { Name = 'AmbientLight',       Format = 'int16u' },
    [0x70] = { Name = 'MotionSensitivity',  Format = 'int16u' },
    [0x72] = { Name = 'BatteryVoltage',     Format = 'int16u',
        ValueConv = function(_self, val) return val / 1000 end, ValueConvInv = function(_self, val) return num(val) * 1000 end,
    },
    [0x74] = { Name = 'BatteryType',        Format = 'int16u',
        PrintConv = {
            [0] = 'Lithium',
            [1] = 'NiMH',
            [2] = 'Alkaline',
            [3] = 'Lead Acid',
        },
    },
    [0x76] = { Name = 'UserLabel',          Format = 'string[22]' },
    [0x8c] = convUnicode{ Name = 'SerialNumber',       Format = 'unicode[15]' },
}

-- maker notes for Reconyx HyperFire 4K (ref 4)
Reconyx.HyperFire4K = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    TAG_PREFIX = 'Reconyx',
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    NOTES = 'Maker notes tags for Reconyx HyperFire 4K models.',
  -- 0x0c => { Name => 'AgregateStructureVersion', Format => 'int32u' },
  -- 0x10 => { Name => 'AgregateStructureSize',    Format => 'int32u' },
  -- 0x14 => { Name => 'InfoStructureVersion',     Format => 'int32u' },
  -- 0x18 => { Name => 'InfoStructureSize',        Format => 'int16u' },
    [0x1a] = versionInfo{ Name = 'FirmwareVersion' },
    [0x21] = versionInfo{ Name = 'UIBFirmwareVersion' },
    [0x28] = {
        Name = 'TriggerMode',
        Format = 'undef[1]',
        PrintConv = {
            M = 'Motion Sensor',
            E = 'External Sensor',
            T = 'Time Lapse',
            C = 'CodeLoc Not Entered',
            S = 'Cell Status',
            L = 'Cell Live View',
        },
    },
    [0x29] = {
        Name = 'Sequence',
        Format = 'int8u[2]',
        PrintConv = function(_self, val) return subst(str(val), ' ', ' of ') end,
        PrintConvInv = function(_self, val) return join(' ', findAll(str(val), [[\d+]])) end,
    },
    [0x2b] = {
        Name = 'EventNumber',
        Format = 'int32u',
    },
    [0x2f] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'undef[7]',
        Groups = { [2] = 'Time' },
        Priority = 0, -- (not as reliable as EXIF)
        Shift = 'Time',
        ValueConv = function(_self, val) return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', reverse(unpack('C5v', val))) end,
        ValueConvInv = function(_self, val)
            local a = findAll(str(val), [[\d+]])
            if #a < 6 then return nil end
            return pack('C5v', num(a[6]), num(a[5]), num(a[4]), num(a[3]), num(a[2]), num(a[1]))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x36] = {
        Name = 'DayOfWeek',
        Groups = { [2] = 'Time' },
        PrintConv = sunday1,
    },
    [0x37] = {
        Name = 'MoonPhase',
        Groups = { [2] = 'Time' },
        PrintConv = moonPhase,
    },
    [0x38] = {
        Name = 'AmbientTemperatureFahrenheit',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' F' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x3a] = {
        Name = 'AmbientTemperature',
        Format = 'int16s',
        PrintConv = function(self, val) return self.NumStr(val) .. ' C' end,
        PrintConvInv = function(_self, val) return matches(str(val), [[(-?\d+)]]) or val end,
    },
    [0x3c] = { Name = 'Contrast',           Format = 'int16u' },
    [0x3e] = { Name = 'Brightness',         Format = 'int16u' },
    [0x40] = { Name = 'Sharpness',          Format = 'int16u' },
    [0x42] = { Name = 'Saturation',         Format = 'int16u' },
    [0x44] = { Name = 'Flash',              Format = 'int8u', PrintConv = { [0] = 'Off', [1] = 'On' } },
    [0x45] = { Name = 'AmbientLight',       Format = 'int32u' },
    [0x49] = { Name = 'MotionSensitivity',  Format = 'int16u' },
    [0x4b] = { Name = 'BatteryVoltage',     Format = 'int16u',
        ValueConv = function(_self, val) return val / 1000 end, ValueConvInv = function(_self, val) return num(val) * 1000 end,
    },
    [0x4d] = { Name = 'BatteryVoltageAvg',  Format = 'int16u',
        ValueConv = function(_self, val) return val / 1000 end, ValueConvInv = function(_self, val) return num(val) * 1000 end,
    },
    [0x4f] = { Name = 'BatteryType',        Format = 'int16u',
        PrintConv = {
            [1] = 'NiMH',
            [2] = 'Lithium',
            [3] = 'External',
            [4] = 'SC10 Solar',
        },
    },
    [0x51] = { Name = 'UserLabel',          Format = 'string[51]' },
    [0x84] = { Name = 'SerialNumber',       Format = 'string[15]' },
    [0x93] = { Name = 'DirectoryNumber',    Format = 'int16u' },
    [0x95] = { Name = 'FileNumber',         Format = 'int16u' },
}

return Reconyx
