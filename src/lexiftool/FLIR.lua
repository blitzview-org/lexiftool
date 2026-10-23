--------------------------------------------------------------------------------
-- File:         lexiftool/FLIR.lua
-- Ported from:  lib/Image/ExifTool/FLIR.pm
--
-- Description:  Read FLIR meta information
--
-- Revisions:    2013/03/28 - P. Harvey Created
--
-- References:   1) https://exiftool.org/forum/index.php/topic,4898.0.html
--               2) http://www.nuage.ch/site/flir-i7-some-analysis/
--               3) http://www.workswell.cz/manuals/flir/hardware/A3xx_and_A6xx_models/Streaming_format_ThermoVision.pdf
--               4) http://support.flir.com/DocDownload/Assets/62/English/1557488%24A.pdf
--               5) http://code.google.com/p/dvelib/source/browse/trunk/flirPublicFormat/fpfConverter/Fpfimg.h?spec=svn3&r=3
--               6) https://exiftool.org/forum/index.php/topic,5538.0.html
--               JD) Jens Duttke private communication
--
-- Glossary:     FLIR = Forward Looking Infra Red
--
-- Port notes:   read port of the APP1 'FLIR\0' segment of JPEG images and of
--               standalone FFF/FPF files.  All 28 upstream tag tables are
--               carried, in upstream's order, as are GetImageType,
--               UnescapeFLIR, ProcessFLIRText, ProcessMeasInfo, ProcessFLIR
--               (including the SEQ multi-frame recursion under
--               ExtractEmbedded) and ProcessFPF.  Read only (upstream has
--               no write side for FLIR either).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local matches = perl.matches
local subst = perl.subst
local substr = perl.substr
local sprintf = perl.sprintf
local str = perl.str
local ucfirst = perl.ucfirst
local GetTagTable = ExifTool.GetTagTable
local Get16u, Get32u = ExifTool.Get16u, ExifTool.Get32u
local ToggleByteOrder = ExifTool.ToggleByteOrder

local FLIR = {}

-- Perl `int()` truncates toward zero (unlike Lua's math.floor, which rounds
-- toward negative infinity -- they differ for negative non-integers)
local function perlInt(v)
    return v >= 0 and math.floor(v) or math.ceil(v)
end

-- (port helper: copy the shared hash into the entry, as Perl's `%hash`
--  spread does -- explicit fields of the entry win)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

local temperatureInfo = spread {
    Writable = 'rational64u',
    Format = 'rational64s', -- (have seen negative values)
}

-- tag information for floating point Kelvin tag
local floatKelvin = spread {
    Format = 'float',
    ValueConv = function(_self, val) return val - 273.15 end,
    PrintConv = function(_self, val) return sprintf('%.1f C', val) end,
}

-- commonly used tag information elements
local float1f = spread { Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f', val) end }
local float2f = spread { Format = 'float', PrintConv = function(_self, val) return sprintf('%.2f', val) end }
local float6f = spread { Format = 'float', PrintConv = function(_self, val) return sprintf('%.6f', val) end }
local float8g = spread { Format = 'float', PrintConv = function(_self, val) return sprintf('%.8g', val) end }

-- FLIR makernotes tags (ref PH)
FLIR.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITABLE = 1,
    PRIORITY = 0, -- (unreliable)
    NOTES = [[
        Information extracted from the maker notes of JPEG images from thermal
        imaging cameras by FLIR Systems Inc.
    ]],
    [0x01] = temperatureInfo { -- #2
        Name = 'ImageTemperatureMax',
        Notes = [[
            these temperatures may be in Celsius, Kelvin or Fahrenheit, but there is no
            way to tell which
        ]],
    },
    [0x02] = temperatureInfo { Name = 'ImageTemperatureMin' }, -- #2
    [0x03] = { -- #1
        Name = 'Emissivity',
        Writable = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.2f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- 0x04 does not change with temperature units; often 238, 250 or 457
    [0x04] = temperatureInfo { Name = 'UnknownTemperature', Unknown = 1 },
    -- 0x05,0x06 are unreliable.  As written by FLIR tools, these are the
    -- CameraTemperatureRangeMax/Min, but the units vary depending on the
    -- options settings.  But as written by some cameras, the values are different.
    [0x05] = temperatureInfo { Name = 'CameraTemperatureRangeMax', Unknown = 1 },
    [0x06] = temperatureInfo { Name = 'CameraTemperatureRangeMin', Unknown = 1 },
    -- 0x07 - string[33] (some sort of image ID?)
    -- 0x08 - string[33]
    -- 0x09 - undef (tool info)
    -- 0x0a - int32u: 1
    -- 0x0f - rational64u: 0/1000
    -- 0x10,0x11,0x12 - int32u: 0
    -- 0x13 - rational64u: 0/1000
}

-- FLIR FFF tag table (ref PH)
FLIR.FFF = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return FLIR.ProcessFLIR(et, dirInfo, tagTablePtr) end,
    VARS = { ALPHA_FIRST = 1 },
    NOTES = [[
        Information extracted from FLIR FFF images and the APP1 FLIR segment of JPEG
        images.  These tags may also be extracted from the first frame of an FLIR
        SEQ file, or all frames if the ExtractEmbedded option is used.  Setting
        ExtractEmbedded to 2 also the raw thermal data from all frames.
    ]],
    ['_header'] = {
        Name = 'FFFHeader',
        SubDirectory = { TagTable = 'lexiftool.FLIR.Header' },
    },
    -- 0 = free (ref 3)
    [0x01] = {
        Name = 'RawData',
        SubDirectory = { TagTable = 'lexiftool.FLIR.RawData' },
    },
    -- 2 = GainMap (ref 3)
    -- 3 = OffsMap (ref 3)
    -- 4 = DeadMap (ref 3)
    [0x05] = { -- #6
        Name = 'GainDeadData',
        SubDirectory = { TagTable = 'lexiftool.FLIR.GainDeadData' },
    },
    [0x06] = { -- #6
        Name = 'CoarseData',
        SubDirectory = { TagTable = 'lexiftool.FLIR.CoarseData' },
    },
    -- 7 = ImageMap (ref 3)
    [0x0e] = {
        Name = 'EmbeddedImage',
        SubDirectory = { TagTable = 'lexiftool.FLIR.EmbeddedImage' },
    },
    [0x20] = {
        Name = 'CameraInfo', -- (BasicData - ref 3)
        SubDirectory = { TagTable = 'lexiftool.FLIR.CameraInfo' },
    },
    [0x21] = { -- #6
        Name = 'MeasurementInfo',
        SubDirectory = { TagTable = 'lexiftool.FLIR.MeasInfo' },
    },
    [0x22] = {
        Name = 'PaletteInfo', -- (ColorPal - ref 3)
        SubDirectory = { TagTable = 'lexiftool.FLIR.PaletteInfo' },
    },
    [0x23] = {
        Name = 'TextInfo',
        SubDirectory = { TagTable = 'lexiftool.FLIR.TextInfo' },
    },
    [0x24] = {
        Name = 'EmbeddedAudioFile',
        -- (sometimes has an unknown 8-byte header)
        RawConv = function(self, val)
            -- (upstream tests and rewrites in one `s///`; Lua's facade has no
            --  substitution count, so the same pattern is matched first)
            if matches(val, [[(?s)^.{0,16}?RIFF]]) then
                return { ref = 'SCALAR', value = subst(val, [[(?s)^.{0,16}?RIFF]], 'RIFF') }
            end
            self:Warn('Unknown EmbeddedAudioFile format')
            return nil
        end,
    },
    -- 0x27: 01 00 08 00 10 00 00 00
    [0x28] = {
        Name = 'PaintData',
        SubDirectory = { TagTable = 'lexiftool.FLIR.PaintData' },
    },
    [0x2a] = {
        Name = 'PiP',
        SubDirectory = {
            TagTable = 'lexiftool.FLIR.PiP',
            ByteOrder = 'LittleEndian',
        },
    },
    [0x2b] = {
        Name = 'GPSInfo',
        SubDirectory = {
            TagTable = 'lexiftool.FLIR.GPSInfo',
            ByteOrder = 'LittleEndian',
        },
    },
    [0x2c] = {
        Name = 'MeterLink',
        SubDirectory = {
            TagTable = 'lexiftool.FLIR.MeterLink' ,
            ByteOrder = 'LittleEndian'
        },
    },
    [0x2e] = {
        Name = 'ParameterInfo',
        SubDirectory = { TagTable = 'lexiftool.FLIR.ParamInfo' },
    },
}

-- FFF file header (ref PH)
FLIR.Header = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = 'Tags extracted from the FLIR FFF/AFF header.',
    [4] = { Name = 'CreatorSoftware', Format = 'string[16]' },
}

-- FLIR raw data record (ref PH)
FLIR.RawData = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    NOTES = [[
        The thermal image data may be stored either as raw data, or in PNG format.
        If stored as raw data, ExifTool adds a TIFF header to allow the data to be
        viewed as a TIFF image.  If stored in PNG format, the PNG image is extracted
        as-is.  Note that most FLIR cameras using the PNG format seem to write the
        16-bit raw image data in the wrong byte order.
    ]],
    [0x00] = {
        -- use this tag only to determine the byte order of the raw data
        -- (the value should be 0x0002 if the byte order is correct)
        -- - always "II" when RawThermalImageType is "TIFF"
        -- - seen both "II" and "MM" when RawThermalImageType is "PNG"
        Name = 'RawDataByteOrder',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [0x01] = {
        Name = 'RawThermalImageWidth',
        RawConv = function(self, val) self.RawThermalImageWidth = val return val end,
    },
    [0x02] = {
        Name = 'RawThermalImageHeight',
        RawConv = function(self, val) self.RawThermalImageHeight = val return val end,
    },
    -- 0x03-0x05: 0
    -- 0x06: raw image width - 1
    -- 0x07: 0
    -- 0x08: raw image height - 1
    -- 0x09: 0,15,16
    -- 0x0a: 0,2,3,11,12,13,30
    -- 0x0b: 0,2
    -- 0x0c: 0 or a large number
    -- 0x0d: 0,3,4,6
    -- 0x0e-0x0f: 0
    [16] = {
        Name = 'RawThermalImageType',
        Format = 'undef[$size-0x20]',
        RawConv = function(self, val) return FLIR.GetImageType(self, val, 'RawThermalImage') end,
    },
    ['16.1'] = {
        Name = 'RawThermalImage',
        Groups = { [2] = 'Preview' },
        -- make a copy in case we want to extract more of them with -ee2
        RawConv = function(self, _val)
            local copy = self.RawThermalImage
            return { ref = 'SCALAR', value = copy }
        end,
    },
}

-- GainDeadMap record (ref 6) (see RawData above)
FLIR.GainDeadData = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    NOTES = 'Information found in FFF-format .GAN calibration image files.',
    [0x00] = {
        Name = 'GainDeadMapByteOrder',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [0x01] = {
        Name = 'GainDeadMapImageWidth',
        RawConv = function(self, val) self.GainDeadMapImageWidth = val return val end,
    },
    [0x02] = {
        Name = 'GainDeadMapImageHeight',
        RawConv = function(self, val) self.GainDeadMapImageHeight = val return val end,
    },
    [16] = {
        Name = 'GainDeadMapImageType',
        Format = 'undef[$size-0x20]',
        RawConv = function(self, val) return FLIR.GetImageType(self, val, 'GainDeadMapImage') end,
    },
    ['16.1'] = {
        Name = 'GainDeadMapImage',
        -- (upstream takes a reference to the hash element and then a reference
        --  to that -- one level more than RawThermalImage above; carried over
        --  as-is rather than silently "fixed")
        RawConv = function(self, _val)
            local copy = { ref = 'SCALAR', value = self.GainDeadMapImage }
            return { ref = 'SCALAR', value = copy }
        end,
    },
}

-- CoarseMap record (ref 6) (see RawData above)
FLIR.CoarseData = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    NOTES = 'Information found in FFF-format .CRS correction image files.',
    [0x00] = {
        Name = 'CoarseMapByteOrder',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [0x01] = {
        Name = 'CoarseMapImageWidth',
        RawConv = function(self, val) self.CoarseMapImageWidth = val return val end,
    },
    [0x02] = {
        Name = 'CoarseMapImageHeight',
        RawConv = function(self, val) self.CoarseMapImageHeight = val return val end,
    },
    [16] = {
        Name = 'CoarseMapImageType',
        Format = 'undef[$size-0x20]',
        RawConv = function(self, val) return FLIR.GetImageType(self, val, 'CoarseMapImage') end,
    },
    ['16.1'] = {
        Name = 'CoarseMapImage',
        -- (same double reference as GainDeadMapImage above)
        RawConv = function(self, _val)
            local copy = { ref = 'SCALAR', value = self.CoarseMapImage }
            return { ref = 'SCALAR', value = copy }
        end,
    },
}

-- "Paint colors" record (ref PH)
FLIR.PaintData = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    NOTES = 'Information generated by FLIR Tools "Paint colors" tool.',
    [0x01] = {
        Name = 'PaintByteOrder',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [0x05] = {
        Name = 'PaintImageWidth',
        RawConv = function(self, val) self.PaintImageWidth = val return val end,
    },
    [0x06] = {
        Name = 'PaintImageHeight',
        RawConv = function(self, val) self.PaintImageHeight = val return val end,
    },
    [20] = {
        Name = 'PaintImageType',
        Format = 'undef[$size-0x28]',
        RawConv = function(self, val) return FLIR.GetImageType(self, val, 'PaintImage') end,
    },
    ['20.1'] = {
        Name = 'PaintImage',
        -- (same double reference as GainDeadMapImage above)
        RawConv = function(self, _val)
            local copy = { ref = 'SCALAR', value = self.PaintImage }
            return { ref = 'SCALAR', value = copy }
        end,
    },
}

-- FLIR embedded image (ref 1)
FLIR.EmbeddedImage = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    [0] = {
        -- use this tag only to determine the byte order
        -- (the value should be 0x0003 if the byte order is correct)
        Name = 'EmbeddedImageByteOrder',
        Format = 'int16u',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [1] = 'EmbeddedImageWidth',
    [2] = 'EmbeddedImageHeight',
    [16] = {
        Name = 'EmbeddedImageType',
        Format = 'undef[4]',
        RawConv = function(_self, val)
            return val:match('^\137PNG') and 'PNG' or (val:match('^\255\216\255') and 'JPG' or 'DAT')
        end,
        Notes = [[
            "PNG" for PNG image in Y Cb Cr colors, "JPG" for a JPEG image, or "DAT" for
            other image data
        ]],
    },
    ['16.1'] = {
        Name = 'EmbeddedImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef[$size-0x20]',
        Binary = 1,
    },
}

-- FLIR camera record (ref PH)
FLIR.CameraInfo = {
    GROUPS = { [0] = 'APP1', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = [[
        FLIR camera information.  The Planck tags are variables used in the
        temperature calculation.  See
        L<https://exiftool.org/forum/index.php?topic=4898.msg23972#msg23972>
        for details.
    ]],
    [0x00] = {
        -- use this tag only to determine the byte order
        -- (the value should be 0x0002 if the byte order is correct)
        Name = 'CameraInfoByteOrder',
        Format = 'int16u',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    -- 0x02 - int16u: image width
    -- 0x04 - int16u: image height
    -- 0x0c - int32u: image width - 1
    -- 0x10 - int32u: image height - 1
    [0x20] = float2f { Name = 'Emissivity' },
    [0x24] = { Name = 'ObjectDistance', Format = 'float', PrintConv = function(_self, val) return sprintf('%.2f m', val) end },
    [0x28] = floatKelvin { Name = 'ReflectedApparentTemperature' },
    [0x2c] = floatKelvin { Name = 'AtmosphericTemperature' },
    [0x30] = floatKelvin { Name = 'IRWindowTemperature' },
    [0x34] = float2f { Name = 'IRWindowTransmission' },
    -- 0x38: 0
    [0x3c] = {
        Name = 'RelativeHumidity',
        Format = 'float',
        ValueConv = function(_self, val) return val > 2 and val / 100 or val end, -- have seen value expressed as percent in FFF file
        PrintConv = function(_self, val) return sprintf('%.1f %%', val * 100) end,
    },
    -- 0x40 - float: 0,6
    -- 0x44,0x48,0x4c: 0
    -- 0x50 - int32u: 1
    -- 0x54: 0
    [0x58] = float8g { Name = 'PlanckR1' }, --1
    [0x5c] = float8g { Name = 'PlanckB' }, --1
    [0x60] = float8g { Name = 'PlanckF' }, --1
    -- 0x64,0x68,0x6c: 0
    [0x070] = float6f { Name = 'AtmosphericTransAlpha1' }, --1 (value: 0.006569)
    [0x074] = float6f { Name = 'AtmosphericTransAlpha2' }, --1 (value: 0.012620)
    [0x078] = float6f { Name = 'AtmosphericTransBeta1' }, --1 (value: -0.002276)
    [0x07c] = float6f { Name = 'AtmosphericTransBeta2' }, --1 (value: -0.006670)
    [0x080] = float6f { Name = 'AtmosphericTransX' }, --1 (value: 1.900000)
    -- 0x84,0x88: 0
    -- 0x8c - float: 0,4,6
    [0x90] = floatKelvin { Name = 'CameraTemperatureRangeMax' },
    [0x94] = floatKelvin { Name = 'CameraTemperatureRangeMin' },
    [0x98] = floatKelvin { Name = 'CameraTemperatureMaxClip' }, -- 50 degrees over camera max
    [0x9c] = floatKelvin { Name = 'CameraTemperatureMinClip' }, -- usually 10 or 20 degrees below camera min
    [0xa0] = floatKelvin { Name = 'CameraTemperatureMaxWarn' }, -- same as camera max
    [0xa4] = floatKelvin { Name = 'CameraTemperatureMinWarn' }, -- same as camera min
    [0xa8] = floatKelvin { Name = 'CameraTemperatureMaxSaturated' }, -- usually 50 or 88 degrees over camera max
    [0xac] = floatKelvin { Name = 'CameraTemperatureMinSaturated' }, -- usually 10, 20 or 40 degrees below camera min
    [0xd4] = { Name = 'CameraModel',        Format = 'string[32]' },
    [0xf4] = { Name = 'CameraPartNumber',   Format = 'string[16]' }, --1
    [0x104] = { Name = 'CameraSerialNumber',Format = 'string[16]' }, --1
    [0x114] = { Name = 'CameraSoftware',    Format = 'string[16]' }, --1/PH (NC)
    [0x170] = { Name = 'LensModel',         Format = 'string[32]' },
    -- note: it seems that FLIR updated their lenses at some point, so lenses with the same
    -- name may have different part numbers (eg. the FOL38 is either 1196456 or T197089)
    [0x190] ={ Name = 'LensPartNumber',    Format = 'string[16]' },
    [0x1a0] = { Name = 'LensSerialNumber',  Format = 'string[16]' },
    [0x1b4] = { Name = 'FieldOfView',       Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f deg', val) end }, --1
    -- 0x1d0 - int16u: 0,12,24,25,46
    -- 0x1d2 - int16u: 170,180,190,380,760,52320
    [0x1ec] = { Name = 'FilterModel',       Format = 'string[16]' },
    [0x1fc] = { Name = 'FilterPartNumber',  Format = 'string[32]' },
    [0x21c] = { Name = 'FilterSerialNumber',Format = 'string[32]' },
    [0x308] = { Name = 'PlanckO',           Format = 'int32s' }, --1
    [0x30c] = float8g { Name = 'PlanckR2' }, --1
    [0x310] = { Name = 'RawValueRangeMin',  Format = 'int16u', Groups = { [2] = 'Image' } }, -- #forum10060
    [0x312] = { Name = 'RawValueRangeMax',  Format = 'int16u', Groups = { [2] = 'Image' } }, -- #forum10060
    [0x338] = { Name = 'RawValueMedian',    Format = 'int16u', Groups = { [2] = 'Image' } },
    [0x33c] = { Name = 'RawValueRange',     Format = 'int16u', Groups = { [2] = 'Image' } },
    [0x384] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'undef[10]',
        Groups = { [2] = 'Time' },
        RawConv = function(_self, val)
            local tm = ExifTool.Get32u(val, 0)
            local ss = ExifTool.Get32u(val, 4) & 0xffff
            local tz = ExifTool.Get16s(val, 8)
            return ExifTool.ConvertUnixTime(tm - tz * 60) ..
                sprintf('.%.3d', ss) .. ExifTool.TimeZoneString(-tz)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x390] = { Name = 'FocusStepCount', Format = 'int16u' },
    [0x45c] = { Name = 'FocusDistance',  Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f m', val) end },
    -- 0x43c - string: either "Live" or the file name
    [0x464] = { Name = 'FrameRate',  Format = 'int16u' }, -- #SebastianHani
}

-- FLIR measurement tools record (ref 6)
FLIR.MeasInfo = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    FORMAT = 'int16u',
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Tags listed below are only for the first measurement tool, however multiple
        measurements may be added, and information is extracted for all of them.
        Tags for subsequent measurements are generated as required with the prefixes
        "Meas2", "Meas3", etc.
    ]],
    Meas1Type = {
        PrintConv = {
            [1] = 'Spot',
            [2] = 'Area',
            [3] = 'Ellipse',
            [4] = 'Line',
            [5] = 'Endpoint', -- #PH (NC, FLIR Tools v2.0 for Mac generates an empty one of these after each Line)
            [6] = 'Alarm', -- #PH seen params: "0 1 0 1 9142 0 9142 0" (called "Isotherm" by Mac version)
            [7] = 'Unused', -- #PH (NC) (or maybe "Free"?)
            [8] = 'Difference',
        },
    },
    Meas1Params = {
        Notes = 'Spot=X,Y; Area=X1,Y1,W,H; Ellipse=XC,YC,X1,Y1,X2,Y2; Line=X1,Y1,X2,Y2',
    },
    Meas1Label = { },
}

-- FLIR palette record (ref PH/JD)
FLIR.PaletteInfo = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    [0x00] = { -- #JD
        Name = 'PaletteColors',
        RawConv = function(self, val) self.PaletteColors = val return val end,
    },
    [0x06] = { Name = 'AboveColor',     Format = 'int8u[3]', Notes = 'Y Cr Cb color components' }, -- #JD
    [0x09] = { Name = 'BelowColor',     Format = 'int8u[3]' }, -- #JD
    [0x0c] = { Name = 'OverflowColor',  Format = 'int8u[3]' }, -- #JD
    [0x0f] = { Name = 'UnderflowColor', Format = 'int8u[3]' }, -- #JD
    [0x12] = { Name = 'Isotherm1Color', Format = 'int8u[3]' }, -- #JD
    [0x15] = { Name = 'Isotherm2Color', Format = 'int8u[3]' }, -- #JD
    [0x1a] = { Name = 'PaletteMethod' }, -- #JD
    [0x1b] = { Name = 'PaletteStretch' }, -- #JD
    [0x30] = {
        Name = 'PaletteFileName',
        Format = 'string[32]',
        -- (not valid for all images)
        RawConv = function(_self, val)
            val = val:gsub('\0.*', '', 1)
            if val:match('^[\32-\126][\32-\126]*$') and #val >= 3 and #val <= 31 then
                return val
            end
            return nil
        end,
    },
    [0x50] = {
        Name = 'PaletteName',
        Format = 'string[32]',
        -- (not valid for all images)
        RawConv = function(_self, val)
            val = val:gsub('\0.*', '', 1)
            if val:match('^[\32-\126][\32-\126]*$') and #val >= 3 and #val <= 31 then
                return val
            end
            return nil
        end,
    },
    [0x70] = {
        Name = 'Palette',
        Format = 'undef[3*$$self{PaletteColors}]',
        Notes = 'Y Cr Cb byte values for each palette color',
        Binary = 1,
    },
}

-- FLIR text information record (ref PH)
FLIR.TextInfo = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    VARS = { ID_FMT = 'none' },
    Label0 = { },
    Value0 = { },
    Label1 = { },
    Value1 = { },
    Label2 = { },
    Value2 = { },
    Label3 = { },
    Value3 = { },
    -- (there could be more, and we will generate these on the fly if necessary)
}

-- FLIR parameter information record (ref PH)
FLIR.ParamInfo = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    VARS = { ID_FMT = 'none' },
    Generated = {
        Name = 'DateTimeGenerated',
        Description = 'Date/Time Generated',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return (val:gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Param0 = { },
    Param1 = { },
    Param2 = { },
    Param3 = { },
    -- (there could be more, and we will generate these on the fly if necessary)
}

-- FLIR Picture in Picture record (ref 1)
FLIR.PiP = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = 'FLIR Picture in Picture tags.',
    FORMAT = 'int16s',
    [0x00] = {
        Name = 'Real2IR',
        Format = 'float',
    },
    [2] = {
        Name = 'OffsetX',
        Notes = 'offset from of insertion point from center',
        PrintConv = function(_self, val) return sprintf('%+d', tonumber(val)) end, -- (add sign for direct use with IM convert)
    },
    [3] = {
        Name = 'OffsetY',
        PrintConv = function(_self, val) return sprintf('%+d', tonumber(val)) end,
    },
    [4] = {
        Name = 'PiPX1',
        Description = 'PiP X1',
        Notes = 'crop size for radiometric image',
    },
    [5] = { Name = 'PiPX2', Description = 'PiP X2' },
    [6] = { Name = 'PiPY1', Description = 'PiP Y1' },
    [7] = { Name = 'PiPY2', Description = 'PiP Y2' },
}

-- FLIR GPS record (ref PH/JD/forum9615)
FLIR.GPSInfo = {
    GROUPS = { [0] = 'APP1', [2] = 'Location' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    [0x00] = {
        Name = 'GPSValid',
        Format = 'int32u',
        RawConv = function(self, val) self.GPSValid = val return val end,
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x04] = {
        Name = 'GPSVersionID',
        Format = 'undef[4]',
        RawConv = function(_self, val) if val == '\0\0\0\0' then return nil end return val end,
        -- (upstream `join ".", split //, $val`: Perl's empty split yields the
        --  individual characters, which in Lua is a gmatch over single bytes)
        PrintConv = function(_self, val)
            local chars = {}
            for c in val:gmatch('.') do chars[#chars + 1] = c end
            return table.concat(chars, '.')
        end,
    },
    [0x08] = {
        Name = 'GPSLatitudeRef',
        Format = 'string[2]',
        RawConv = function(_self, val) if #val ~= 0 then return val end return nil end,
        PrintConv = {
            N = 'North',
            S = 'South',
        },
    },
    [0x0a] = {
        Name = 'GPSLongitudeRef',
        Format = 'string[2]',
        RawConv = function(_self, val) if #val ~= 0 then return val end return nil end,
        PrintConv = {
            E = 'East',
            W = 'West',
        },
    },
  -- 0x0c - 4 unknown bytes
    [0x10] = {
        Name = 'GPSLatitude',
        Condition = function(self) return self.GPSValid end,    -- valid only if GPSValid is 1
        Format = 'double', -- (signed)
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [0x18] = {
        Name = 'GPSLongitude',
        Condition = function(self) return self.GPSValid end,    -- valid only if GPSValid is 1
        Format = 'double', -- (signed)
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [0x20] = {
        Name = 'GPSAltitude',
        Condition = function(self) return self.GPSValid end,    -- valid only if GPSValid is 1
        Format = 'float',
        -- (have seen likely invalid value of -1 when GPSValid is 1)
        PrintConv = function(_self, val) return sprintf('%.2f m', val) end,
    },
  -- 0x24 - 28 unknown bytes:
  -- 0x28 - int8u: seen 0,49,51,55,57 (ASCII "1","3","7","9")
  -- 0x29 - int8u: seen 0,48 (ASCII "0")
    [0x40] = {
        Name = 'GPSDOP',
        Description = 'GPS Dilution Of Precision',
        Format = 'float',
        RawConv = function(_self, val) if tonumber(val) > 0 then return val end return nil end, -- (have also seen likely invalid value of 1)
        PrintConv = function(_self, val) return sprintf('%.2f', val) end,
    },
    [0x44] = {
        Name = 'GPSSpeedRef',
        Format = 'string[2]',
        RawConv = function(_self, val) if #val ~= 0 then return val end return nil end,
        PrintConv = {
            K = 'km/h',
            M = 'mph',
            N = 'knots',
        },
    },
    [0x46] = {
        Name = 'GPSTrackRef',
        Format = 'string[2]',
        RawConv = function(_self, val) if #val ~= 0 then return val end return nil end,
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0x48] = { -- #PH (NC)
        Name = 'GPSImgDirectionRef',
        Format = 'string[2]',
        RawConv = function(_self, val) if #val ~= 0 then return val end return nil end,
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0x4c] = float2f {
        Name = 'GPSSpeed',
        RawConv = function(_self, val) if tonumber(val) < 0 then return nil end return val end,
    },
    [0x50] = float2f {
        Name = 'GPSTrack',
        RawConv = function(_self, val) if tonumber(val) < 0 then return nil end return val end,
    },
    [0x54] = float2f {
        Name = 'GPSImgDirection',
        RawConv = function(_self, val) if tonumber(val) < 0 then return nil end return val end,
    },
    [0x58] = {
        Name = 'GPSMapDatum',
        Format = 'string[16]',
        RawConv = function(_self, val) if #val ~= 0 then return val end return nil end,
    },
  -- 0xa4 - string[6]: seen 000208,081210,020409,000608,010408,020808,091011
  -- 0x78 - double[2]: seen "-1 -1","0 0"
  -- 0x78 - float[2]: seen "-1 -1","0 0"
  -- 0xb2 - string[2]?: seen "5\0"
}

-- humidity meter information
-- (ref https://exiftool.org/forum/index.php/topic,5325.0.html)
-- The %Image::ExifTool::UserDefined hash defines new tags to be added to existing tables.
FLIR.MeterLink = {
    GROUPS = { [0] = 'APP1', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = 'Tags containing Meterlink humidity meter information.',
    [26] = {
        Name = 'Reading1Units',
        DataMember = 'Reading1Units',
        RawConv = function(self, val) self.Reading1Units = val return val end,
        PrintHex = 1,
        PrintConv = {
            [0x0d] = 'C',
            [0x1b] = '%',
            [0x1d] = 'Relative',
            [0x24] = 'g/kg',
        },
    },
    [28] = {
        Name = 'Reading1Description',
        DataMember = 'Reading1Description',
        RawConv = function(self, val) self.Reading1Description = val return val end,
        PrintConv = {
            [0] = 'Humidity',
            [3] = 'Moisture', -- Pinless Moisture Readings with INTernal sensor
            [7] = 'Dew Point',
            [8] = 'Air Temperature',
            [9] = 'IR Temperature',
            [11] = 'Difference Temperature', -- Difference Temp: IR-Temp and DewPoint
        },
    },
    [32] = {
        Name = 'Reading1Device',
        Format = 'string[16]',
    },
    [96] = {
        Name = 'Reading1Value',
        Format = 'double',
        -- convert Kelvin -> Celsius and kg/kg -> g/kg
        ValueConv = function(self, val)
            if tonumber(self.Reading1Units) == 0x0d and tonumber(self.Reading1Description) ~= 11 then return val - 273.15 end
            if tonumber(self.Reading1Units) == 0x24 then val = val * 1000 return val end
            return val
        end,
    },
    -- add 100 for subsequent readings
    [126] = {
        Name = 'Reading2Units',
        DataMember = 'Reading2Units',
        RawConv = function(self, val) self.Reading2Units = val return val end,
        PrintHex = 1,
        PrintConv = {
            [0x0d] = 'C',
            [0x1b] = '%',
            [0x1d] = 'rel',
            [0x24] = 'g/kg',
        },
    },
    [128] = {
        Name = 'Reading2Description',
        DataMember = 'Reading2Description',
        RawConv = function(self, val) self.Reading2Description = val return val end,
        PrintConv = {
            [0] = 'Humidity',
            [3] = 'Moisture',
            [7] = 'Dew Point',
            [8] = 'Air Temperature',
            [9] = 'IR Temperature',
            [11] = 'Difference Temperature', -- Difference Temp: IR-Temp and DewPoint
        },
    },
    [132] = {
        Name = 'Reading2Device',
        Format = 'string[16]',
    },
    [196] = {
        Name = 'Reading2Value',
        Format = 'double',
        -- convert Kelvin -> Celsius and kg/kg -> g/kg
        ValueConv = function(self, val)
            if tonumber(self.Reading2Units) == 0x0d and tonumber(self.Reading2Description) ~= 11 then return val - 273.15 end
            if tonumber(self.Reading2Units) == 0x24 then val = val * 1000 return val end
            return val
        end,
    },
    [226] = {
        Name = 'Reading3Units',
        DataMember = 'Reading3Units',
        RawConv = function(self, val) self.Reading3Units = val return val end,
        PrintHex = 1,
        PrintConv = {
            [0x0d] = 'C',
            [0x1b] = '%',
            [0x1d] = 'rel',
            [0x24] = 'g/kg',
        },
    },
    [228] = {
        Name = 'Reading3Description',
        DataMember = 'Reading3Description',
        RawConv = function(self, val) self.Reading3Description = val return val end,
        PrintConv = {
            [0] = 'Humidity',
            [3] = 'Moisture',
            [7] = 'Dew Point',
            [8] = 'Air Temperature',
            [9] = 'IR Temperature',
            [11] = 'Difference Temperature', -- Difference Temp: IR-Temp and DewPoint
        },
    },
    [232] = {
        Name = 'Reading3Device',
        Format = 'string[16]',
    },
    [296] = {
        Name = 'Reading3Value',
        Format = 'double',
        -- convert Kelvin -> Celsius and kg/kg -> g/kg
        ValueConv = function(self, val)
            if tonumber(self.Reading3Units) == 0x0d and tonumber(self.Reading3Description) ~= 11 then return val - 273.15 end
            if tonumber(self.Reading3Units) == 0x24 then val = val * 1000 return val end
            return val
        end,
    },

    [326] = {
        Name = 'Reading4Units',
        DataMember = 'Reading4Units',
        RawConv = function(self, val) self.Reading4Units = val return val end,
        PrintHex = 1,
        PrintConv = {
            [0x0d] = 'C',
            [0x1b] = '%',
            [0x1d] = 'rel',
            [0x24] = 'g/kg',
        },
    },
    [328] = {
        Name = 'Reading4Description',
        DataMember = 'Reading4Description',
        RawConv = function(self, val) self.Reading4Description = val return val end,
        PrintConv = {
            [0] = 'Humidity',
            [3] = 'Moisture',
            [7] = 'Dew Point',
            [8] = 'Air Temperature',
            [9] = 'IR Temperature',
            [11] = 'Difference Temperature', -- Difference Temp: IR-Temp and DewPoint
        },
    },
    [332] = {
        Name = 'Reading4Device',
        Format = 'string[16]',
    },
    [396] = {
        Name = 'Reading4Value',
        Format = 'double',
        -- convert Kelvin -> Celsius and kg/kg -> g/kg
        ValueConv = function(self, val)
            if tonumber(self.Reading4Units) == 0x0d and tonumber(self.Reading4Description) ~= 11 then return val - 273.15 end
            if tonumber(self.Reading4Units) == 0x24 then val = val * 1000 return val end
            return val
        end,
    },
}

-- FLIR public image format (ref 4/5)
FLIR.FPF = {
    GROUPS = { [0] = 'FLIR', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'Tags extracted from FLIR Public image Format (FPF) files.',
    [0x20] = { Name = 'FPFVersion',         Format = 'int32u' },
    [0x24] = { Name = 'ImageDataOffset',    Format = 'int32u' },
    [0x28] = {
        Name = 'ImageType',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Temperature',
            [1] = 'Temperature Difference',
            [2] = 'Object Signal',
            [3] = 'Object Signal Difference',
        },
    },
    [0x2a] = {
        Name = 'ImagePixelFormat',
        Format = 'int16u',
        PrintConv = {
            [0] = '2-byte short integer',
            [1] = '4-byte long integer',
            [2] = '4-byte float',
            [3] = '8-byte double',
        },
    },
    [0x2c] = { Name = 'ImageWidth',         Format = 'int16u' },
    [0x2e] = { Name = 'ImageHeight',        Format = 'int16u' },
    [0x30] = { Name = 'ExternalTriggerCount',Format = 'int32u' },
    [0x34] = { Name = 'SequenceFrameNumber',Format = 'int32u' },
    [0x78] = { Name = 'CameraModel',        Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x98] = { Name = 'CameraPartNumber',   Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0xb8] = { Name = 'CameraSerialNumber', Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0xd8] = floatKelvin { Name = 'CameraTemperatureRangeMin', Groups = { [2] = 'Camera' } },
    [0xdc] = floatKelvin { Name = 'CameraTemperatureRangeMax', Groups = { [2] = 'Camera' } },
    [0xe0] = { Name = 'LensModel',          Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x100] = { Name = 'LensPartNumber',   Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x120] = { Name = 'LensSerialNumber', Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x140] = { Name = 'FilterModel',      Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x150] = { Name = 'FilterPartNumber', Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x180] = { Name = 'FilterSerialNumber',Format = 'string[32]', Groups = { [2] = 'Camera' } },
    [0x1e0] = float2f { Name = 'Emissivity' },
    [0x1e4] = { Name = 'ObjectDistance',    Format = 'float', PrintConv = function(_self, val) return sprintf('%.2f m', val) end },
    [0x1e8] = floatKelvin { Name = 'ReflectedApparentTemperature' },
    [0x1ec] = floatKelvin { Name = 'AtmosphericTemperature' },
    [0x1f0] = { Name = 'RelativeHumidity',  Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f %%', val * 100) end },
    [0x1f4] = float2f { Name = 'ComputedAtmosphericTrans' },
    [0x1f8] = float2f { Name = 'EstimatedAtmosphericTrans'},
    [0x1fc] = floatKelvin { Name = 'ReferenceTemperature' },
    [0x200] = floatKelvin { Name = 'IRWindowTemperature',  Groups = { [2] = 'Camera' } },
    [0x204] = float2f { Name = 'IRWindowTransmission', Groups = { [2] = 'Camera' } },
    [0x248] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Format = 'int32u[7]',
        ValueConv = function(_self, val)
            local parts = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do parts[#parts + 1] = tonumber(w) end
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d.%.3d',
                parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7])
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- Notes (based on ref 4):
    -- 1) The above date/time structure is documented to be 32 bytes for FPFVersion 1, but in
    --    fact it is only 28.  Maybe this is why the full header length of my FPFVersion 2
    --    sample is 892 bytes instead of 896.  If this was a documentation error, we are OK,
    --    but if the alignment was really different in version 1, then the temperatures below
    --    will be mis-aligned.  I don't have any version 1 samples to check this.
    -- 2) The following temperatures may not always be in Kelvin
    [0x2a4] = float1f { Name = 'CameraScaleMin' },
    [0x2a8] = float1f { Name = 'CameraScaleMax' },
    [0x2ac] = float1f { Name = 'CalculatedScaleMin' },
    [0x2b0] = float1f { Name = 'CalculatedScaleMax' },
    [0x2b4] = float1f { Name = 'ActualScaleMin' },
    [0x2b8] = float1f { Name = 'ActualScaleMax' },
}

--------------------------------------------------------------------------------
-- Determine the image type and save the image data (upstream GetImageType)
-- Inputs: 0) ExifTool ref, 1) image data, 2) tag name ('RawThermalImage')
-- Returns: image type
--------------------------------------------------------------------------------
function FLIR.GetImageType(et, val, tag)
    local w = et[tag .. 'Width']
    local h = et[tag .. 'Height']
    local imgType = 'DAT'
    -- add TIFF header only if this looks like 16-bit raw data
    -- (note: MakeTiffHeader currently works only for little-endian,
    --  and I haven't seen any big-endian samples, but check anwyay)
    if val:match('^\137PNG\r\n\x1a\n') then
        imgType = 'PNG'
    elseif val:match('^\255\216\255') then -- (haven't seen this, but just in case - PH)
        imgType = 'JPG'
    elseif #val ~= w * h * 2 then
        et:Warn('Unrecognized FLIR ' .. tag .. ' data format')
    elseif ExifTool.GetByteOrder() == 'II' then
        val = ExifTool.MakeTiffHeader(w, h, 1, 16) .. val
        imgType = 'TIFF'
    else
        et:Warn("Don't yet support big-endian TIFF " .. tag)
    end
    -- save image data
    et[tag] = val
    return imgType
end

--------------------------------------------------------------------------------
-- Unescape FLIR Unicode character (upstream UnescapeFLIR)
-- Inputs: 0) escaped character code
-- Returns: UTF8 character
--------------------------------------------------------------------------------
function FLIR.UnescapeFLIR(char)
    if #char ~= 4 then return char end -- escaped ASCII char (eg. '\\')
    local val = tonumber(char, 16)
    if not val then return char end
    if val < 0x80 then return string.char(val) end -- simple ASCII
    -- (upstream `pack('C0U', $val)`)
    return utf8.char(val)
end

--------------------------------------------------------------------------------
-- Process FLIR text info record (ref PH) (upstream ProcessFLIRText)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function FLIR.ProcessFLIRText(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen

    if dirLen < 12 then return 0 end

    et:VerboseDir('FLIR Text')

    local dat = substr(dataPt, dirStart + 12, dirLen - 12)
    dat = subst(dat, [[(?s)\0.*]], '', 'g') -- truncate at null

    -- the parameter text contains an additional header entry...
    if tagTablePtr == FLIR.ParamInfo then
        local gen, when = matches(dat, [==[# (Generated) at (.*?)[\n\r]]==])
        if gen then
            et:HandleTag(tagTablePtr, gen, when)
        end
    end

    -- (upstream runs this /g match in a `for(;;)` loop over the whole string)
    for num, kind, enc, val in perl.eachMatch(dat, [[.(\d+).(label|value|param) (unicode|text) "(.*)"]]) do
        local tag = ucfirst(kind) .. num
        if enc == 'unicode' and val:find('\\', 1, true) then
            -- convert escaped Unicode characters (backslash followed by 4 hex digits)
            val = perl.subst(val, [[(?s)\\([0-9a-fA-F]{4}|.)]],
                             function(c) return FLIR.UnescapeFLIR(c) end, 'g')
            et:Decode(val, 'UTF8')
        end
        if not tagTablePtr[tag] then
            et:AddTagToTable(tagTablePtr, tag, { Name = tag })
        end
        et:HandleTag(tagTablePtr, tag, val)
    end

    return 1
end

--------------------------------------------------------------------------------
-- Process FLIR measurement tool record (ref 6) (upstream ProcessMeasInfo)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- (code-driven decoding isn't pretty, but sometimes it is necessary)
--------------------------------------------------------------------------------
function FLIR.ProcessMeasInfo(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dataPos = dirInfo.DataPos
    local dirEnd = dirStart + dirInfo.DirLen

    local pos = dirStart + 12
    if pos > dirEnd then return 0 end
    if ExifTool.Get16u(dataPt, dirStart) >= 0x100 then ExifTool.ToggleByteOrder() end
    local i = 1
    while true do
        if pos + 2 > dirEnd then break end
        local recLen = ExifTool.Get16u(dataPt, pos)
        if recLen < 0x28 or pos + recLen > dirEnd then break end
        local pre = 'Meas' .. i
        et:VerboseDir('MeasInfo ' .. i, nil, recLen)
        et:VerboseDump(dataPt, { Len = recLen, Start = pos, DataPos = dataPos })
        local coordLen = ExifTool.Get16u(dataPt, pos + 4)
        -- generate tag table entries for this tool if necessary
        for _, t in ipairs({ 'Type', 'Params', 'Label' }) do
            local tag = pre .. t
            if tagTablePtr[tag] then break end
            local tagInfo = { Name = tag }
            tagInfo.PrintConv = tagTablePtr['Meas1' .. t].PrintConv
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        -- extract measurement tool type
        et:HandleTag(tagTablePtr, pre .. 'Type', nil,
            { DataPt = dataPt, DataPos = dataPos, Start = pos + 0x0a, Size = 2 })
        if pos + 0x24 + coordLen > dirEnd then break end
        -- extract measurement parameters
        et:HandleTag(tagTablePtr, pre .. 'Params', nil,
            { DataPt = dataPt, DataPos = dataPos, Start = pos + 0x24, Size = coordLen })
        local uni = {}
        -- extract label (sometimes-null-terminated Unicode)
        local p = 0x24 + coordLen
        while p < recLen - 1 do
            local ch = ExifTool.Get16u(dataPt, p + pos)
            -- FLIR Tools v2.0 for Mac doesn't properly null-terminate these strings,
            -- so end the string at any funny character
            if ch < 0x20 or ch > 0x7f then break end
            uni[#uni + 1] = ch
            p = p + 2
        end
        -- convert to the ExifTool character set
        local Charset = require('lexiftool.Charset')
        local val = Charset.Recompose(et, uni)
        et:HandleTag(tagTablePtr, pre .. 'Label', val,
            { DataPt = dataPt, DataPos = dataPos, Start = pos + 0x24 + coordLen,
              Size = 2 * #uni })
        pos = pos + recLen    -- step to next record
        i = i + 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process FLIR FFF record (ref PH/1/3)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 if this was a valid FFF record
--------------------------------------------------------------------------------
function FLIR.ProcessFLIR(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF or require('lexiftool.RandomAccess').new(dirInfo.DataPt)
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout
    local base = raf:Tell()
    local i, hdr, buff, rec, n

    -- read and verify FFF header
    n, hdr = raf:Read(0x40)
    local typ = n == 0x40 and matches(hdr, [[^([AF]FF)\0]])
    if not typ then return 0 end

    -- set file type if reading from FFF or SEQ file ($tagTablePtr will not be defined)
    if not tagTablePtr then et:SetFileType(typ == 'FFF' and 'FLIR' or 'SEQ') end

    -- FLIR file header (ref 3)
    -- 0x00 - string[4] file format ID = "FFF\0"
    -- 0x04 - string[16] file creator: seen "\0","MTX IR\0","CAMCTRL\0"
    -- 0x14 - int32u file format version = 100
    -- 0x18 - int32u offset to record directory
    -- 0x1c - int32u number of entries in record directory
    -- 0x20 - int32u next free index ID = 2
    -- 0x24 - int16u swap pattern = 0 (?)
    -- 0x28 - int16u[7] spares
    -- 0x34 - int32u[2] reserved
    -- 0x3c - int32u checksum

    -- determine byte ordering by validating version number
    -- (in my samples FLIR APP1 is big-endian, FFF files are little-endian)
    i = 0
    while true do
        local ver = Get32u(hdr, 0x14)
        if ver >= 100 and ver < 200 then break end -- (have seen 100 and 101 - PH)
        ToggleByteOrder()
        if i ~= 0 then
            if perlTruthy(et.DOC_NUM) then return 0 end
            et:Warn('Unsupported FLIR ' .. typ .. ' version')
            return 1
        end
        i = i + 1
    end

    -- read the FLIR record directory
    local pos = Get32u(hdr, 0x18)
    local num = Get32u(hdr, 0x1c)
    if raf:Seek(base+pos) then n, buff = raf:Read(num * 0x20) else n = nil end
    if n ~= num * 0x20 then
        et:Warn('Truncated FLIR FFF directory')
        return perlTruthy(et.DOC_NUM) and 0 or 1
    end

    if not tagTablePtr then
        tagTablePtr = GetTagTable(nil, 'lexiftool.FLIR.' .. typ)
        et.SET_GROUP0 = 'FLIR' -- (set group 0 to 'FLIR' for FFF files)
    end

    -- process the header data
    et:HandleTag(tagTablePtr, '_header', hdr)

    local success = 1
    local oldIndent = et.INDENT
    et.INDENT = et.INDENT .. '| '
    et:VerboseDir(typ, num)

    i = 0
    while i < num do

        -- FLIR record entry (ref 3):
        -- 0x00 - int16u record type
        -- 0x02 - int16u record subtype: RawData 1=BE, 2=LE, 3=PNG; 1 for other record types
        -- 0x04 - int32u record version: seen 0x64,0x66,0x67,0x68,0x6f,0x104
        -- 0x08 - int32u index id = 1
        -- 0x0c - int32u record offset from start of FLIR data
        -- 0x10 - int32u record length
        -- 0x14 - int32u parent = 0 (?)
        -- 0x18 - int32u object number = 0 (?)
        -- 0x1c - int32u checksum: 0 for no checksum

        local entry = i * 0x20
        local recType = Get16u(buff, entry)
        if recType == 0 then
            if perlTruthy(verbose) then perl.print(out, et.INDENT .. i .. ") FLIR Record 0x00 (empty)\n") end
            goto next
        end
        do
            local recPos = Get32u(buff, entry + 0x0c)
            local recLen = Get32u(buff, entry + 0x10)

            if perlTruthy(verbose) then perl.printf(out, "%s%d) FLIR Record 0x%.2x, offset 0x%.4x, length 0x%.4x\n",
                                     et.INDENT, i, recType, recPos, recLen) end

            -- skip RawData records for embedded documents
            if recType == 1 and perlTruthy(et.DOC_NUM) and perl.num(et:Options('ExtractEmbedded')) < 2 then
                if not raf:Seek(base+recPos+recLen) then success = 0; break end
                goto next
            end
            if raf:Seek(base+recPos) then n, rec = raf:Read(recLen) else n = nil end
            if n ~= recLen then
                if perlTruthy(et.DOC_NUM) then
                    success = 0   -- abort processing more documents
                else
                    et:Warn('Invalid FLIR record')
                end
                break
            end
            if tagTablePtr[recType] then
                et:HandleTag(tagTablePtr, recType, nil, {
                    Base    = base,
                    DataPt  = rec,
                    DataPos = recPos,
                    Start   = 0,
                    Size    = recLen,
                })
            elseif perl.num(verbose) > 2 then
                et:VerboseDump(rec, { Len = recLen, DataPos = recPos })
            end
        end
        ::next::
        i = i + 1
    end
    et.SET_GROUP0 = nil
    et.INDENT = oldIndent

    -- extract information from subsequent frames in SEQ file if ExtractEmbedded is used
    if dirInfo.RAF and perlTruthy(et:Options('ExtractEmbedded')) and not perlTruthy(et.DOC_NUM) then
        while true do
            et.DOC_NUM = et.DOC_COUNT + 1
            if not perlTruthy(FLIR.ProcessFLIR(et, dirInfo, tagTablePtr)) then break end
            -- (DOC_COUNT will be incremented automatically if we extracted any tags)
        end
        et.DOC_NUM = nil
    end
    return success
end

--------------------------------------------------------------------------------
-- Process FLIR public image format (FPF) file (ref PH/4)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 if this was a valid FFF file
--------------------------------------------------------------------------------
function FLIR.ProcessFPF(et, dirInfo)
    local raf = dirInfo.RAF

    local n, buff = raf:Read(892)
    if n ~= 892 or buff:sub(1, 24) ~= 'FPF Public Image Format\0' then return 0 end

    -- I think these are always little-endian, but check FPFVersion just in case
    ExifTool.SetByteOrder('II')
    if (ExifTool.Get32u(buff, 0x20) & 0xffff) == 0 then
        ExifTool.ToggleByteOrder()
    end

    local tagTablePtr = et:GetTagTable('lexiftool.FLIR.FPF')
    et:SetFileType()
    et:ProcessDirectory({ DataPt = buff, Parent = 'FPF' }, tagTablePtr)
    return 1
end

-- top-level user data written by FLIR cameras in MP4 videos
FLIR.UserData = {
    GROUPS = { [1] = 'FLIR', [2] = 'Camera' },
    NOTES = [[
        Tags written by some FLIR cameras in a top-level (!) "udta" atom of MP4
        videos.
    ]],
    uuid = {
        {
            Name = 'FLIR_Parts',
            Condition = function(_self, val) return val:sub(1, 16) == '\x43\xc3\x99\x3b\x0f\x94\x42\x4b\x82\x05\x6b\x66\x51\x3f\x48\x5d' end,
            SubDirectory = {
                TagTable = 'lexiftool.FLIR.Parts',
                Start = 16,
            },
        },
        {
            Name = 'FLIR_Serial',
            Condition = function(_self, val) return val:sub(1, 16) == '\x57\xf5\xb9\x3e\x51\xe4\x48\xaf\xa0\xd9\xc3\xef\x1b\x37\xf7\x12' end,
            SubDirectory = {
                TagTable = 'lexiftool.FLIR.SerialNums',
                Start = 16,
            },
        },
        {
            Name = 'FLIR_Params',
            Condition = function(_self, val) return val:sub(1, 16) == '\x41\xe5\xdc\xf9\xe8\x0a\x41\xce\xad\xfe\x7f\x0c\x58\x08\x2c\x19' end,
            SubDirectory = {
                TagTable = 'lexiftool.FLIR.Params',
                Start = 16,
            },
        },
        {
            Name = 'FLIR_UnknownUUID',
            Condition = function(_self, val) return val:sub(1, 16) == '\x57\x45\x20\x50\x2c\xbb\x44\xad\xae\x54\x15\xe9\xb8\x39\xd9\x03' end,
            SubDirectory = {
                TagTable = 'lexiftool.FLIR.UnknownUUID',
                Start = 16,
            },
        },
        {
            Name = 'FLIR_GPS',
            Condition = function(_self, val) return val:sub(1, 16) == '\x7f\x2e\x21\x00\x8b\x46\x49\x18\xaf\xb1\xde\x70\x9a\x74\xf6\xf5' end,
            SubDirectory = {
                TagTable = 'lexiftool.FLIR.GPS_UUID',
                Start = 16,
            },
        },
        {
            Name = 'FLIR_MoreInfo',
            Condition = function(_self, val) return val:sub(1, 16) == '\x2b\x45\x2f\xdc\x74\x35\x40\x94\xba\xee\x22\xa6\xb2\x3a\x7c\xf8' end,
            SubDirectory = {
                TagTable = 'lexiftool.FLIR.MoreInfo',
                Start = 16,
            },
        },
        {
            Name = 'SoftwareComponents',
            Condition = function(_self, val) return val:sub(1, 16) == '\x78\x3f\xc7\x83\x0c\x95\x4b\x00\x8c\xc7\xac\xf1\xec\xb4\xd3\x9a' end,
            Unknown = 1,
            ValueConv = function(_self, val) return table.concat({ perl.unpack('x20N4xZ*', val) }, ' ') end,
        },
        {
            Name = 'FLIR_Unknown',
            Condition = function(_self, val) return val:sub(1, 16) == '\x52\xae\xda\x45\x17\x1e\x48\xb1\x92\x47\x93\xa4\x21\x4e\x43\xf5' end,
            Unknown = 1,
            -- (upstream evaluates this in scalar context, so only the first
            --  byte of the unpack survives)
            ValueConv = function(_self, val) return (perl.unpack('x20C*', val)) end,
        },
        {
            Name = 'Units',
            Condition = function(_self, val) return val:sub(1, 16) == '\xf8\xab\x72\x1e\x84\x73\x44\xa0\xb8\xc8\x1b\x04\x82\x6e\x07\x24' end,
            List = 1,
            RawConv = function(_self, val) local a = perl.split([[\0]], substr(val, 20)) return a end,
        },
        {
            Name = 'ThumbnailImage',
            Groups = { [2] = 'Preview' },
            -- (upstream matches the 16-byte uuid, skips 4 bytes and expects a
            --  JPEG SOI; the wildcard run is a fixed offset, so no regex)
            Condition = function(_self, val)
                return val:sub(1, 16) == '\x91\xaf\x9b\x93\x45\x9b\x44\x56\x98\xd1\x5e\x76\xea\x01\x04\xac' and
                    val:sub(21, 23) == '\xff\xd8\xff'
            end,
            RawConv = function(_self, val) return substr(val, 20) end,
            Binary = 1,
        },
    },
}

-- uuid 43c3993b0f94424b82056b66513f485d box of MP4 videos (ref PH)
FLIR.Parts = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'undef',
    NOTES = [[
        Tags extracted from the "uuid" box with ID 43c3993b0f94424b82056b66513f485d
        in FLIR MP4 videos.
    ]],
    [4] = {
        {
            Name = 'BAHPVer',
            Condition = function(_self, val) return val:match('^bahpver\0') ~= nil end,
            Format = 'undef[$size]',
            RawConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'BALPVer',
            Condition = function(_self, val) return val:match('^balpver\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'Battery',
            Condition = function(_self, val) return val:match('^battery\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'BAVPVer',
            Condition = function(_self, val) return val:match('^bavpver\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
            -- (the first string corresponds with a lens part number)
        },
        {
            Name = 'CamCore',
            Condition = function(_self, val) return val:match('^camcore\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'DetectorBoard',
            Condition = function(_self, val) return val:match('^det_board\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 10)), ' ') end,
        },
        {
            Name = 'Detector',
            Condition = function(_self, val) return val:match('^detector\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 9)), ' ') end,
        },
        {
            Name = 'GIDCVer',
            Condition = function(_self, val) return val:match('^gidcver\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'GIDPVer',
            Condition = function(_self, val) return val:match('^gidpver\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'GIPC_CPLD',
            Condition = function(_self, val) return val:match('^gipccpld\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 9)), ' ') end,
        },
        {
            Name = 'GIPCVer',
            Condition = function(_self, val) return val:match('^gipcver\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'GIXIVer',
            Condition = function(_self, val) return val:match('^gixiver\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 8)), ' ') end,
        },
        {
            Name = 'MainBoard',
            Condition = function(_self, val) return val:match('^mainboard\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 10)), ' ') end,
        },
        {
            Name = 'Optics',
            Condition = function(_self, val) return val:match('^optics\0') ~= nil end,
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], substr(val, 7)), ' ') end,
        },
        {
            Name = 'PartNumber',
            Format = 'undef[$size]',
            ValueConv = function(_self, val) return table.concat(perl.split([[\0]], val), ' ') end,
        },
    },
}

-- uuid 57f5b93e51e448afa0d9c3ef1b37f712 box of MP4 videos (ref PH)
FLIR.SerialNums = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the "uuid" box with ID 57f5b93e51e448afa0d9c3ef1b37f712
        in FLIR MP4 videos.
    ]],
    -- (not sure if these offsets are constant)
    [0x0c] = { Name = 'UnknownSerial1',     Format = 'string[33]', Unknown = 1 },
    [0x2d] = { Name = 'UnknownSerial2',     Format = 'string[33]', Unknown = 1 },
    [0x4e] = { Name = 'UnknownSerial3',     Format = 'string[33]', Unknown = 1 },
    [0x6f] = { Name = 'UnknownSerial4',     Format = 'string[11]', Unknown = 1 },
    [0x7b] = { Name = 'UnknownNumber',      Format = 'string[3]',  Unknown = 1 },
    [0x7e] = { Name = 'CameraSerialNumber', Format = 'string[9]' },
}

-- uuid 41e5dcf9e80a41ceadfe7f0c58082c19 box of MP4 videos (ref PH)
FLIR.Params = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'float',
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the "uuid" box with ID 41e5dcf9e80a41ceadfe7f0c58082c19
        in FLIR MP4 videos.
    ]],
    [1] = floatKelvin { Name = 'ReflectedApparentTemperature' },
    [2] = floatKelvin { Name = 'AtmosphericTemperature' },
    [3] = float2f { Name = 'Emissivity' },
    [4] = { Name = 'ObjectDistance',   PrintConv = function(_self, val) return sprintf('%.2f m', val) end },
    [5] = { Name = 'RelativeHumidity', PrintConv = function(_self, val) return sprintf('%.1f %%', val * 100) end },
    [6] = float2f { Name = 'EstimatedAtmosphericTrans' },
    [7] = floatKelvin { Name = 'IRWindowTemperature' },
    [8] = float2f { Name = 'IRWindowTransmission' },
}

-- uuid 574520502cbb44adae5415e9b839d903 box of MP4 videos (ref PH)
FLIR.UnknownUUID = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'float',
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the "uuid" box with ID 574520502cbb44adae5415e9b839d903
        in FLIR MP4 videos.
    ]],
    -- 1 - 1
    -- 2 - 0
    -- 3 - 0
}

-- uuid 7f2e21008b464918afb1de709a74f6f5 box of MP4 videos (ref PH)
FLIR.GPS_UUID = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'FLIR', [2] = 'Location' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'float',
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the "uuid" box with ID 7f2e21008b464918afb1de709a74f6f5
        in FLIR MP4 videos.
    ]],
    [1] = {
        Name = 'GPSLatitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [2] = {
        Name = 'GPSLongitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [3] = {
        Name = 'GPSAltitude',
        PrintConv = function(_self, val)
            val = perlInt(tonumber(val) * 100 + 0.5) / 100
            return ExifTool.NumStr(val) .. ' m'
        end,
    },
    -- 4 - int32u: 0x0001bf74
    -- 5 - int32u: 0
    -- 6 - int32u: 1
}

-- uuid 2b452fdc74354094baee22a6b23a7cf8 box of MP4 videos (ref PH)
FLIR.MoreInfo = {
    GROUPS = { [0] = 'MakerNotes', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the "uuid" box with ID 2b452fdc74354094baee22a6b23a7cf8
        in FLIR MP4 videos.
    ]],
    [5] = { Name = 'LensModel', Format = 'string[6]' },
    [11] = floatKelvin { Name = 'UnknownTemperature1', Unknown = 1 }, -- (-14.9 C)
    [15] = floatKelvin { Name = 'UnknownTemperature2', Unknown = 1 }, -- (60.0 C)
}

-- FLIR AFF tag table (ref PH)
FLIR.AFF = {
    GROUPS = { [0] = 'FLIR', [1] = 'FLIR', [2] = 'Image' },
    NOTES = 'Tags extracted from FLIR "AFF" SEQ images.',
    VARS = { ALPHA_FIRST = 1 },
    ['_header'] = {
        Name = 'AFFHeader',
        SubDirectory = { TagTable = 'lexiftool.FLIR.Header' },
    },
    [0x01] = {
        Name = 'AFF1',
        SubDirectory = { TagTable = 'lexiftool.FLIR.AFF1' },
    },
    [0x05] = {
        Name = 'AFF5',
        SubDirectory = { TagTable = 'lexiftool.FLIR.AFF5' },
    },
}

-- AFF record type 1 (ref forum?topic=4898.msg27627)
FLIR.AFF1 = {
    GROUPS = { [0] = 'FLIR', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    [0x00] = {
        -- use this tag only to determine the byte order of the raw data
        -- (the value should be 0x0002 if the byte order is correct)
        Name = 'RawDataByteOrder',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [0x01] = { Name = 'SensorWidth',  Format = 'int16u' },
    [0x02] = { Name = 'SensorHeight', Format = 'int16u' },
}

-- AFF record type 5 (ref forum?topic=4898.msg27628)
FLIR.AFF5 = {
    GROUPS = { [0] = 'FLIR', [1] = 'FLIR', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    [0x12] = {
        -- use this tag only to determine the byte order of the raw data
        -- (the value should be 0x0002 if the byte order is correct)
        Name = 'RawDataByteOrder',
        Hidden = 1,
        RawConv = function(_self, val)
            if val >= 0x0100 then ExifTool.ToggleByteOrder() end
            return nil
        end,
    },
    [0x13] = { Name = 'SensorWidth',  Format = 'int16u' },
    [0x14] = { Name = 'SensorHeight', Format = 'int16u' },
}

-- FLIR composite tags (ref 1)
FLIR.Composite = {
    -- (upstream AddCompositeTags fills in family 0 as 'Composite' and the
    --  'FLIR-'-prefixed TagID; set explicitly per this port's convention)
    GROUPS = { [0] = 'Composite', [1] = 'FLIR', [2] = 'Camera' },
    PeakSpectralSensitivity = {
        TagID = 'FLIR-PeakSpectralSensitivity',
        Require = { [0] = 'FLIR:PlanckB' },
        ValueConv = function(_self, val) return 14387.6515 / val[0] end, -- (val[0] = PlanckB)
        PrintConv = function(_self, val) return sprintf('%.1f um', val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.FLIR', nil, FLIR)

-- (PROCESS_PROC is set here so the tables can reference the functions above)
FLIR.MeasInfo.PROCESS_PROC = FLIR.ProcessMeasInfo
FLIR.TextInfo.PROCESS_PROC = FLIR.ProcessFLIRText
FLIR.ParamInfo.PROCESS_PROC = FLIR.ProcessFLIRText

return FLIR
