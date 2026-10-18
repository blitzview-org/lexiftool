--------------------------------------------------------------------------------
-- File:         lexiftool/CanonRaw.lua
-- Ported from:  lib/Image/ExifTool/CanonRaw.pm
--
-- Description:  Read Canon RAW (CRW) meta information
--
-- Revisions:    11/25/2003 - P. Harvey Created
--               12/02/2003 - P. Harvey Completely reworked and figured out many
--                            more tags
--
-- References:   1) http://www.cybercom.net/~dcoffin/dcraw/
--               2) http://www.wonderland.org/crw/
--               3) http://xyrion.org/ciff/CIFFspecV1R04.pdf
--               4) Dave Nicholson private communication (PowerShot S30)
--
-- Port notes:   Complete port of CanonRaw.pm: every table and sub, in upstream
--               order.  The write-include WriteCanonRaw.pl is
--               lexiftool/WriteCanonRaw.lua; its subs (WriteCRW,
--               WriteCanonRaw, CheckCanonRaw, InitMakerNotes, SaveMakerNotes,
--               BuildMakerNotes, WriteCR2) are bound at the predeclaration
--               position to closures that load it on first use (upstream
--               AUTOLOAD/DoAutoLoad).  Canon.lua is reached lazily through
--               Canon() (an eager require would pull Canon's Composite tags
--               into every file that loads this module).  ProcessCanonRaw
--               evaluates the SubDirectory Validate hooks as upstream.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local str = perl.str

local CanonRaw = {}

-- (upstream's predeclarations `sub WriteCRW($$);` ...: the subs of
--  WriteCanonRaw.pl, which upstream AUTOLOADs -- DoAutoLoad loads it on the
--  first call.  Here each is bound to a closure that loads WriteCanonRaw.lua
--  on first use; ProcessCanonRaw is defined below)
for _, name in ipairs({ 'WriteCRW', 'WriteCanonRaw', 'CheckCanonRaw', 'InitMakerNotes',
                        'SaveMakerNotes', 'BuildMakerNotes', 'WriteCR2' }) do
    CanonRaw[name] = function(...) return require('lexiftool.WriteCanonRaw')[name](...) end
end

-- (lazy access to Canon.lua, see the Port notes)
local function Canon() return require('lexiftool.Canon') end

-- formats for CRW tag types (($tag >> 8) & 0x38)
-- Note: don't define format for undefined types
local crwTagFormat = {
    [0x00] = 'int8u',
    [0x08] = 'string',
    [0x10] = 'int16u',
    [0x18] = 'int32u',
  -- 0x20 => 'undef',
  -- 0x28 => 'undef',
  -- 0x30 => 'undef',
}
CanonRaw.crwTagFormat = crwTagFormat   -- (upstream package variable %crwTagFormat, read by DNG.pm)

-- Canon raw file tag table
-- Note: Tag ID's have upper 2 bits set to zero, since these 2 bits
-- just specify the location of the information
CanonRaw.Main = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = function(...) return CanonRaw.ProcessCanonRaw(...) end,
    WRITE_PROC = function(...) return CanonRaw.WriteCanonRaw(...) end,
    CHECK_PROC = function(...) return CanonRaw.CheckCanonRaw(...) end,
    WRITABLE = 1,
    [0x0000] = { Name = 'NullRecord', Writable = 'undef' }, -- #3
    [0x0001] = { -- #3
        Name = 'FreeBytes',
        Format = 'undef',
        Binary = 1,
    },
    [0x0032] = { Name = 'CanonColorInfo1', Writable = 0 },
    [0x0805] = {
        -- this tag is found in more than one directory...
        {
            Condition = function(self) return self.DIR_NAME == "ImageDescription" end,
            Name = 'CanonFileDescription',
            Writable = 'string[32]',
        },
        {
            Name = 'UserComment',
            Writable = 'string[256]',
        },
    },
    [0x080a] = {
        Name = 'CanonRawMakeModel',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.CanonRaw.MakeModel' },
    },
    [0x080b] = { Name = 'CanonFirmwareVersion', Writable = 'string[32]' },
    [0x080c] = { Name = 'ComponentVersion',     Writable = 'string'     }, -- #3
    [0x080d] = { Name = 'ROMOperationMode',     Writable = 'string[8]'  }, -- #3
    [0x0810] = { Name = 'OwnerName',            Writable = 'string[32]' },
    [0x0815] = { Name = 'CanonImageType',       Writable = 'string[32]' },
    [0x0816] = { Name = 'OriginalFileName',     Writable = 'string[32]' },
    [0x0817] = { Name = 'ThumbnailFileName',    Writable = 'string[32]' },
    [0x100a] = { -- #3
        Name = 'TargetImageType',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Real-world Subject',
            [1] = 'Written Document',
        },
    },
    [0x1010] = { -- #3
        Name = 'ShutterReleaseMethod',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Single Shot',
            [2] = 'Continuous Shooting',
        },
    },
    [0x1011] = { -- #3
        Name = 'ShutterReleaseTiming',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Priority on shutter',
            [1] = 'Priority on focus',
        },
    },
    [0x1016] = { Name = 'ReleaseSetting',       Writable = 'int16u' }, -- #3
    [0x101c] = { Name = 'BaseISO',              Writable = 'int16u' }, -- #3
    [0x1028]= { -- #PH
        Name = 'CanonFlashInfo',
        Writable = 'int16u',
        Count = 4,
        Unknown = 1,
    },
    [0x1029] = {
        Name = 'CanonFocalLength',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.Canon.FocalLength' },
    },
    [0x102a] = {
        Name = 'CanonShotInfo',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.Canon.ShotInfo' },
    },
    [0x102c] = {
        Name = 'CanonColorInfo2',
        Writable = 0,
        -- for the S30, the following information has been decoded: (ref 4)
        -- offset 66: int32u - shutter half press time in ms
        -- offset 70: int32u - image capture time in ms
        -- offset 74: int16u - custom white balance flag (0=Off, 512=On)
    },
    [0x102d] = {
        Name = 'CanonCameraSettings',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.Canon.CameraSettings' },
    },
    [0x1030] = { -- #4
        Name = 'WhiteSample',
        Writable = 0,
        SubDirectory = {
            Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size) end,
            TagTable = 'lexiftool.CanonRaw.WhiteSample',
        },
    },
    [0x1031] = {
        Name = 'SensorInfo',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.Canon.SensorInfo' },
    },
    -- this tag has only be verified for the 10D in CRW files, but the D30 and D60
    -- also produce CRW images and have CustomFunction information in their JPEG's
    [0x1033] = {
        {
            Name = 'CustomFunctions10D',
            Condition = function(self) return isMatch(self.Model, [[EOS 10D]]) end,
            SubDirectory = {
                Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size) end,
                TagTable = 'lexiftool.CanonCustom.Functions10D',
            },
        },
        {
            Name = 'CustomFunctionsD30',
            Condition = function(self) return isMatch(self.Model, [[EOS D30\b]]) end,
            SubDirectory = {
                Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size) end,
                TagTable = 'lexiftool.CanonCustom.FunctionsD30',
            },
        },
        {
            Name = 'CustomFunctionsD60',
            Condition = function(self) return isMatch(self.Model, [[EOS D60\b]]) end,
            SubDirectory = {
                -- the stored size in the D60 apparently doesn't include the size word:
                Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size - 2, size) end,
                -- (D60 custom functions are basically the same as D30)
                TagTable = 'lexiftool.CanonCustom.FunctionsD30',
            },
        },
        {
            Name = 'CustomFunctionsUnknown',
            SubDirectory = {
                Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size) end,
                TagTable = 'lexiftool.CanonCustom.FuncsUnknown',
            },
        },
    },
    [0x1038] = {
        Name = 'CanonAFInfo',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.Canon.AFInfo' },
    },
    [0x1093] = {
        Name = 'CanonFileInfo',
        SubDirectory = {
            Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size) end,
            TagTable = 'lexiftool.Canon.FileInfo',
        },
    },
    [0x10a9] = {
        Name = 'ColorBalance',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.Canon.ColorBalance' },
    },
    [0x10b5] = { -- #PH
        Name = 'RawJpgInfo',
        SubDirectory = {
            Validate = function(_self, _val, dirData, subdirStart, size) return Canon().Validate(dirData, subdirStart, size) end,
            TagTable = 'lexiftool.CanonRaw.RawJpgInfo',
        },
    },
    [0x10ae] = {
        Name = 'ColorTemperature',
        Writable = 'int16u',
    },
    [0x10b4] = {
        Name = 'ColorSpace',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'sRGB',
            [2] = 'Adobe RGB',
            [0xffff] = 'Uncalibrated',
        },
    },
    [0x1803] = { -- #3
        Name = 'ImageFormat',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.CanonRaw.ImageFormat' },
    },
    [0x1804] = { Name = 'RecordID', Writable = 'int32u' }, -- #3
    [0x1806] = { -- #3
        Name = 'SelfTimerTime',
        Writable = 'int32u',
        ValueConv = function(_self, val) return val / 1000 end,
        ValueConvInv = function(_self, val) return val * 1000 end,
        PrintConv = function(_self, val) return perl.str(val) .. " s" end,
        PrintConvInv = function(_self, val) val = subst(val, [[\s*s.*]], '') return val end,
    },
    [0x1807] = {
        Name = 'TargetDistanceSetting',
        Format = 'float',
        PrintConv = function(_self, val) return perl.str(val) .. " mm" end,
        PrintConvInv = function(_self, val) val = subst(val, [[\s*mm$]], '') return val end,
    },
    [0x180b] = {
        {
            -- D30
            Name = 'SerialNumber',
            Condition = function(self) return isMatch(self.Model, [[EOS D30\b]]) end,
            Writable = 'int32u',
            PrintConv = function(_self, val) return sprintf("%x-%.5d", val >> 16, val & 0xffff) end,
            PrintConvInv = function(_self, val)
                local isSN, s1, s2 = isMatch(val, [[(.*)-(\d+)]])
                if isSN then return (perl.hex(s1) << 16) + perl.num(s2) end
                return nil
            end,
        },
        {
            -- all EOS models (D30, 10D, 300D)
            Name = 'SerialNumber',
            Condition = function(self) return isMatch(self.Model, [[EOS]]) end,
            Writable = 'int32u',
            PrintConv = function(_self, val) return sprintf("%.10d", val) end,
            PrintConvInv = function(_self, val) return val end,
        },
        {
            -- this is not SerialNumber for PowerShot models (but what is it?) - PH
            Name = 'UnknownNumber',
            Unknown = 1,
        },
    },
    [0x180e] = {
        Name = 'TimeStamp',
        Writable = 0,
        SubDirectory = {
            TagTable = 'lexiftool.CanonRaw.TimeStamp',
        },
    },
    [0x1810] = {
        Name = 'ImageInfo',
        Writable = 0,
        SubDirectory = {
            TagTable = 'lexiftool.CanonRaw.ImageInfo',
        },
    },
    [0x1813] = { -- #3
        Name = 'FlashInfo',
        Writable = 0,
        SubDirectory = {
            TagTable = 'lexiftool.CanonRaw.FlashInfo',
        },
    },
    [0x1814] = { -- #3
        Name = 'MeasuredEV',
        Notes = [[
            this is the Canon name for what could better be called MeasuredLV, and
            should be close to the calculated LightValue for a proper exposure with most
            models
        ]],
        Format = 'float',
        ValueConv = function(_self, val) return val + 5 end,
        ValueConvInv = function(_self, val) return val - 5 end,
    },
    [0x1817] = {
        Name = 'FileNumber',
        Writable = 'int32u',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) local _ = subst(val, [[(\d+)(\d{4})]], '$1-$2') return _ end,
        PrintConvInv = function(_self, val) local _ = subst(val, '-', '') return _ end,
    },
    [0x1818] = { -- #3
        Name = 'ExposureInfo',
        Groups = { [1] = 'CIFF' }, -- (only so CIFF shows up in group lists)
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.CanonRaw.ExposureInfo' },
    },
    [0x1834] = { -- #PH
        Name = 'CanonModelID',
        Writable = 'int32u',
        PrintHex = 1,
        Notes = [[
            this is the complete list of model ID numbers, but note that many of these
            models do not produce CRW images
        ]],
        SeparateTable = 'Canon CanonModelID',
        PrintConv = setmetatable({}, {
            __index = function(_, k) return Canon().canonModelID[k] end,
            __pairs = function() return pairs(Canon().canonModelID) end,
        }),
    },
    [0x1835] = {
        Name = 'DecoderTable',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.CanonRaw.DecoderTable' },
    },
    [0x183b] = { -- #PH
        -- display format for serial number
        Name = 'SerialNumberFormat',
        Writable = 'int32u',
        PrintHex = 1,
        PrintConv = {
            [0x90000000] = 'Format 1',
            [0xa0000000] = 'Format 2',
        },
    },
    [0x2005] = {
        Name = 'RawData',
        Writable = 0,
        Binary = 1,
    },
    [0x2007] = {
        Name = 'JpgFromRaw',
        Groups = { [2] = 'Preview' },
        Writable = 'resize',  -- 'resize' allows this value to change size
        Permanent = 0,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage gets and returns the scalar ref \$val)
            local img = self:ValidateImage(val, tag)
            return img ~= nil and { ref = 'SCALAR', value = img } or nil
        end,
    },
    [0x2008] = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Writable = 'resize',  -- 'resize' allows this value to change size
        WriteCheck = function(self, _tagInfo, val) return self:CheckImage(val) end,
        Permanent = 0,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage gets and returns the scalar ref \$val)
            local img = self:ValidateImage(val, tag)
            return img ~= nil and { ref = 'SCALAR', value = img } or nil
        end,
    },
    -- the following entries are subdirectories
    -- (any 0x28 and 0x30 tag types are handled automatically by the decoding logic)
    [0x2804] = {
        Name = 'ImageDescription',
        SubDirectory = { },
        Writable = 0,
    },
    [0x2807] = { -- #3
        Name = 'CameraObject',
        SubDirectory = { },
        Writable = 0,
    },
    [0x3002] = { -- #3
        Name = 'ShootingRecord',
        SubDirectory = { },
        Writable = 0,
    },
    [0x3003] = { -- #3
        Name = 'MeasuredInfo',
        SubDirectory = { },
        Writable = 0,
    },
    [0x3004] = { -- #3
        Name = 'CameraSpecification',
        SubDirectory = { },
        Writable = 0,
    },
    [0x300a] = { -- #3
        Name = 'ImageProps',
        SubDirectory = { },
        Writable = 0,
    },
    [0x300b] = {
        Name = 'ExifInformation',
        SubDirectory = { },
        Writable = 0,
    },
}

-- Canon binary data blocks
CanonRaw.MakeModel = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    DATAMEMBER = { 0, 6 }, -- indices of data members to extract when writing
    WRITABLE = 1,
    FORMAT = 'string',
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- (can't specify a first entry because this isn't
    -- a simple binary table with fixed offsets)
    [0] = {
        Name = 'Make',
        Format = 'string[6]',  -- "Canon\0"
        DataMember = 'Make',
        RawConv = function(self, val) self.Make = val return val end,
    },
    [6] = {
        Name = 'Model',
        Format = 'string', -- no size = to the end of the data
        Description = 'Camera Model Name',
        DataMember = 'Model',
        RawConv = function(self, val) self.Model = val return val end,
    },
}

CanonRaw.TimeStamp = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Time' },
    [0] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Shift = 'Time',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end,
        ValueConvInv = function(_self, val) return ExifTool.GetUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    [1] = { -- #3
        Name = 'TimeZoneCode',
        Format = 'int32s',
        ValueConv = function(_self, val) return val / 3600 end,
        ValueConvInv = function(_self, val) return val * 3600 end,
    },
    [2] = { -- #3
        Name = 'TimeZoneInfo',
        Notes = 'set to 0x80000000 if TimeZoneCode is valid',
    },
}

CanonRaw.ImageFormat = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'FileFormat',
        Flags = 'PrintHex',
        PrintConv = {
            [0x00010000] = 'JPEG (lossy)',
            [0x00010002] = 'JPEG (non-quantization)',
            [0x00010003] = 'JPEG (lossy/non-quantization toggled)',
            [0x00020001] = 'CRW',
        },
    },
    [1] = {
        Name = 'TargetCompressionRatio',
        Format = 'float',
    },
}

CanonRaw.RawJpgInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    FORMAT = 'int16u',
    FIRST_ENTRY = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
--    0 => 'RawJpgInfoSize',
    [1] = { -- #PH
        Name = 'RawJpgQuality',
        PrintConv = {
            [1] = 'Economy',
            [2] = 'Normal',
            [3] = 'Fine',
            [5] = 'Superfine',
        },
    },
    [2] = { -- #PH
        Name = 'RawJpgSize',
        PrintConv = {
            [0] = 'Large',
            [1] = 'Medium',
            [2] = 'Small',
        },
    },
    [3] = 'RawJpgWidth', -- #PH
    [4] = 'RawJpgHeight', -- #PH
}

CanonRaw.FlashInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    FORMAT = 'float',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = 'FlashGuideNumber',
    [1] = 'FlashThreshold',
}

CanonRaw.ExposureInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    FORMAT = 'float',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = 'ExposureCompensation',
    [1] = {
        Name = 'ShutterSpeedValue',
        ValueConv = function(_self, val) return math.abs(perl.num(val)) < 100 and 1 / (2 ^ val) or 0 end,
        ValueConvInv = function(_self, val) return perl.num(val) > 0 and -perl.log(val) / perl.log(2) or -100 end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.Exif').ConvertFraction(val) end,
    },
    [2] = {
        Name = 'ApertureValue',
        ValueConv = function(_self, val) return 2 ^ (val / 2) end,
        ValueConvInv = function(_self, val) return perl.num(val) > 0 and 2 * perl.log(val) / perl.log(2) or 0 end,
        PrintConv = function(_self, val) return sprintf("%.1f", val) end,
        PrintConvInv = function(_self, val) return val end,
    },
}

CanonRaw.ImageInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    -- Note: Don't make these writable (except rotation) because it confuses
    -- Canon decoding software if the are changed
    [0] = 'ImageWidth', -- #3
    [1] = 'ImageHeight', -- #3
    [2] = { -- #3
        Name = 'PixelAspectRatio',
        Format = 'float',
    },
    [3] = {
        Name = 'Rotation',
        Format = 'int32s',
        Writable = 1,
    },
    [4] = 'ComponentBitDepth', -- #3
    [5] = 'ColorBitDepth', -- #3
    [6] = 'ColorBW', -- #3
}

-- ref 4
CanonRaw.DecoderTable = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    [0] = 'DecoderTableNumber',
    [2] = 'CompressedDataOffset',
    [3] = 'CompressedDataLength',
}

-- ref 1/4
CanonRaw.WhiteSample = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int16u',
    FIRST_ENTRY = 1,
    [1] = 'WhiteSampleWidth',
    [2] = 'WhiteSampleHeight',
    [3] = 'WhiteSampleLeftBorder',
    [4] = 'WhiteSampleTopBorder',
    [5] = 'WhiteSampleBits',
    -- (followed by the encrypted white sample values, ref 1)
    -- BlackLevels seem valid for D30 and D60, but not sure about PowerShot models
    [0x37] = { Name = 'BlackLevels', Format = 'int16u[4]' }, -- #github387
}

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WriteCanonRaw.pl -- its subs are bound
--  to loader closures at their predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Process Raw file directory
-- Inputs: 0) ExifTool object reference
--         1) directory information reference, 2) tag table reference
-- Returns: 1 on success
function CanonRaw.ProcessCanonRaw(et, dirInfo, rawTagTable)
    local buildMakerNotes = et:Options('MakerNotes')
    local blockStart = dirInfo.DirStart
    local blockSize = dirInfo.DirLen
    local raf = dirInfo.RAF
    if not raf then return 0 end

    -- 4 bytes at end of block give directory position within block
    if not raf:Seek(blockStart + blockSize - 4, 0) then return 0 end
    local n, buff = raf:Read(4)
    if n ~= 4 then return 0 end
    local dirOffset = et.Get32u(buff, 0) + blockStart
    -- avoid infinite recursion
    et.ProcessedCanonRaw = et.ProcessedCanonRaw or {}
    if et.ProcessedCanonRaw[dirOffset] then
        et:Warn('Not processing double-referenced ' .. str(dirInfo.DirName) .. ' directory')
        return 0
    end
    et.ProcessedCanonRaw[dirOffset] = 1
    if not raf:Seek(dirOffset, 0) then return 0 end
    local n2, buff2 = raf:Read(2)
    if n2 ~= 2 then return 0 end
    local entries = et.Get16u(buff2, 0) -- get number of entries in directory
    -- read the directory (10 bytes per entry)
    local n3, dirBuff = raf:Read(10 * entries)
    if n3 ~= 10 * entries then return 0 end

    local verbose = et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0
    if verbose then et:VerboseDir('CIFF', entries) end

    for index = 0, entries - 1 do
        local pt = 10 * index
        local tag = et.Get16u(dirBuff, pt)
        local size = et.Get32u(dirBuff, pt + 2)
        local valuePtr = et.Get32u(dirBuff, pt + 6)
        local ptr = valuePtr + blockStart -- all pointers relative to block start
        if tag & 0x8000 ~= 0 then
            et:Warn('Bad CRW directory entry')
            return 1
        end
        local tagID = tag & 0x3fff -- get tag ID
        local tagType = (tag >> 8) & 0x38 -- get tag type
        local valueInDir = (tag & 0x4000) ~= 0 -- flag for value in directory
        local tagInfo = et:GetTagInfo(rawTagTable, tagID)
        if (tagType == 0x28 or tagType == 0x30) and not valueInDir then
            -- this type of tag specifies a raw subdirectory
            local name = tagInfo and tagInfo.Name
            if not name then name = sprintf('CanonRaw_0x%.4x', tag) end
            local subdirInfo = {
                DirName  = name,
                DataLen  = 0,
                DirStart = ptr,
                DirLen   = size,
                Nesting  = (dirInfo.Nesting or 0) + 1,
                RAF      = raf,
                Parent   = dirInfo.DirName,
            }
            if verbose then
                local fakeInfo = { Name = name, SubDirectory = {} }
                et:VerboseInfo(tagID, fakeInfo, { Index = index, Size = size, Start = ptr })
            end
            et:ProcessDirectory(subdirInfo, rawTagTable)
            goto continue
        end
        local valueDataPos
        local count
        local subdir
        local format = crwTagFormat[tagType]
        if tagInfo then
            subdir = tagInfo.SubDirectory
            if tagInfo.Format then format = tagInfo.Format end
            count = tagInfo.Count
        end
        -- get value data
        local value, delRawConv
        if valueInDir then
            -- this type of tag stores the value in the 'size' and 'ptr' fields
            valueDataPos = dirOffset + pt + 4 -- (remember, +2 for the entry count)
            size = 8
            value = dirBuff:sub(pt + 2 + 1, pt + 2 + size)
            -- set count to 1 by default for normal values in directory
            if count == nil and format and format ~= 'string' and not subdir then count = 1 end
        else
            valueDataPos = ptr
            -- do hash of image data if requested
            -- (rawget: the member, not the method of that name)
            if rawget(et, 'ImageDataHash') and tagID == 0x2005 then
                if raf:Seek(ptr, 0) then et:ImageDataHash(raf, size, 'raw') end
            end
            -- (upstream `grep(/^$$tagInfo{Name}$/i, $et->GetRequestedTags())`)
            local requested
            if tagInfo then
                for _, t in ipairs(et:GetRequestedTags()) do
                    if isMatchDyn(t, '(?i)^' .. tagInfo.Name .. '$') then requested = true break end
                end
            end
            if size <= 512 or ((et.OPTIONS.Verbose or 0) > 2 and size <= 65536)
                or (tagInfo and (tagInfo.SubDirectory or requested))
            then
                -- read value if size is small or specifically requested
                -- or if this is a SubDirectory
                if not raf:Seek(ptr, 0) then
                    et:Warn(sprintf('Error reading %d bytes from 0x%x', size, ptr))
                    goto continue
                end
                local nr, vr = raf:Read(size)
                if nr ~= size then
                    et:Warn(sprintf('Error reading %d bytes from 0x%x', size, ptr))
                    goto continue
                end
                value = vr
            else
                value = 'Binary data ' .. size .. ' bytes'
                if tagInfo then
                    if et:Options('Binary') or verbose then
                        -- read the value anyway
                        if not raf:Seek(ptr, 0) then
                            et:Warn(sprintf('Error reading %d bytes from 0x%x', size, ptr))
                            goto continue
                        end
                        local nr2, vr2 = raf:Read(size)
                        if nr2 ~= size then
                            et:Warn(sprintf('Error reading %d bytes from 0x%x', size, ptr))
                            goto continue
                        end
                        value = vr2
                    end
                    -- force this to be a binary (scalar reference)
                    tagInfo.RawConv = function(_self, val) return { ref = 'SCALAR', value = val } end
                    delRawConv = 1
                end
                size = #value
                format = nil
            end
        end
        -- set count from tagInfo count if necessary
        if format and not count then
            -- set count according to format and size
            local Exif = require('lexiftool.Exif')
            local fnum = Exif.formatNumber[format]
            local fsiz = Exif.formatSize[fnum]
            count = perl.int(size / fsiz)
        end
        if verbose then
            local val = value
            if format then val = et.ReadValue(val, 0, format, count, size) end
            et:VerboseInfo(tagID, tagInfo, {
                Table   = rawTagTable,
                Index   = index,
                Value   = val,
                DataPt  = value,
                DataPos = valueDataPos,
                Size    = size,
                Format  = format,
                Count   = count,
            })
        end
        if buildMakerNotes then
            -- build maker notes information if requested
            CanonRaw.BuildMakerNotes(et, tagID, tagInfo, value, format, count)
        end
        if not tagInfo then goto continue end

        if subdir then
            local name = tagInfo.Name
            local newTagTable = et:GetTagTable(subdir.TagTable)
            if not newTagTable then
                et:Warn(string.format('Unknown tag table %s', str(subdir.TagTable)))
                goto continue
            end
            local subdirStart = 0
            -- (upstream evals $$subdir{Start}; no CanonRaw table has one)
            local dirData = value
            local subdirInfo = {
                Name     = name,
                DataPt   = value,
                DataLen  = size,
                DataPos  = valueDataPos,
                DirStart = subdirStart,
                DirLen   = size - subdirStart,
                Nesting  = (dirInfo.Nesting or 0) + 1,
                RAF      = raf,
                DirName  = name,
                Parent   = dirInfo.DirName,
            }
            if subdir.Validate ~= nil and not subdir.Validate(et, nil, dirData, subdirStart, size) then
                et:Warn("Invalid " .. name .. " data")
            else
                et:ProcessDirectory(subdirInfo, newTagTable, subdir.ProcessProc)
            end
        else
            -- convert to specified format if necessary
            if format then value = et.ReadValue(value, 0, format, count, size) end
            -- save the information
            et:FoundTag(tagInfo, value)
            if delRawConv then tagInfo.RawConv = nil end
        end
        ::continue::
    end
    return 1
end

--------------------------------------------------------------------------------
-- get information from raw file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 if this was a valid Canon RAW file
function CanonRaw.ProcessCRW(et, dirInfo)
    local buildMakerNotes = et:Options('MakerNotes')
    local raf = dirInfo.RAF
    if not raf then return 0 end
    et:SetFileType()
    local n, buff = raf:Read(2)
    if n ~= 2 then return 0 end
    if not et.SetByteOrder(buff) then return 0 end
    local n2, buff2 = raf:Read(4)
    if n2 ~= 4 then return 0 end
    local n3, sig = raf:Read(8)
    if n3 ~= 8 then return 0 end -- get file signature
    -- upstream: `$sig =~ /^HEAP(CCDR|JPGM)/ or return 0` (validate signature;
    -- PCRE2 via the facade -- Lua patterns have no alternation)
    if not matches(sig, '^HEAP(CCDR|JPGM)') then return 0 end
    local hlen = et.Get32u(buff2, 0)

    if not raf:Seek(0, 2) then return 0 end -- seek to end of file
    local filesize = raf:Tell()
    if not filesize then return 0 end

    -- initialize maker note data if building maker notes
    if buildMakerNotes then CanonRaw.InitMakerNotes(et) end

    -- build directory information for main raw directory
    local dirInfo2 = {
        DataLen  = 0,
        DirStart = hlen,
        DirLen   = filesize - hlen,
        Nesting  = 0,
        RAF      = raf,
        Parent   = 'CRW',
    }

    -- process the raw directory
    local rawTagTable = et:GetTagTable('lexiftool.CanonRaw.Main')
    local oldIndent = et.INDENT
    et.INDENT = et.INDENT .. '| '
    if not CanonRaw.ProcessCanonRaw(et, dirInfo2, rawTagTable) then
        et:Warn('CRW file format error')
    end
    et.INDENT = oldIndent

    -- finish building maker notes if necessary
    if buildMakerNotes then CanonRaw.SaveMakerNotes(et) end

    -- process trailers if they exist in CRW file (not in CIFF information!)
    if et.FILE_TYPE == 'CRW' then
        local trailInfo = et:IdentifyTrailer(raf)
        if trailInfo then et:ProcessTrailers(trailInfo) end
    end
    return 1
end

return CanonRaw
