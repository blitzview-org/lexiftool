--------------------------------------------------------------------------------
-- File:         lexiftool/PanasonicRaw.lua
-- Ported from:  lib/Image/ExifTool/PanasonicRaw.pm
--
-- Description:  Read/write Panasonic/Leica RAW/RW2/RWL meta information
--
-- Revisions:    2009/03/24 - P. Harvey Created
--               2009/05/12 - PH Added RWL file type (same format as RW2)
--
-- References:   1) https://exiftool.org/forum/index.php/topic,1542.0.html
--               2) http://www.cybercom.net/~dcoffin/dcraw/
--               3) http://syscall.eu/#pana
--               4) Klaus Homeister private communication
--              IB) Iliah Borg private communication (LibRaw)
--              JD) Jens Duttke private communication (TZ3,FZ30,FZ50)
--
-- Port notes:   Complete port of PanasonicRaw.pm: every table and sub, in
--               upstream order (tables mechanically extracted from the Perl,
--               `#` comments carried as `--`, inverse conversions and write
--               attributes included).  `make verify` compares all tables
--               against the original.
--               Deviations forced by Lua:
--               - PROCESS_PROC/WRITE_PROC/ProcessProc/WriteProc references to
--                 the predeclared subs are `false` placeholders filled in at
--                 the bottom of the file.
--               - `%wbTypeInfo` is spread with the `wbTypeInfo { }` helper.
--               - `RawDataOffset`'s IsOffset code string is a function; the
--                 port's WriteExif only tests IsOffset for truth, so it acts
--                 as upstream's condition does for RW2/RWL files.
--               - WriteJpgFromRaw hands WriteJPEG an append-only buffer in
--                 place of upstream's scalar ref; WriteDistortionInfo sets
--                 the checksums through a carray copy.
--               - The Composite tags carry their "PanasonicRaw-" TagID
--                 (AddCompositeTags).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local Writer = require('lexiftool.Writer')
local RandomAccess = require('lexiftool.RandomAccess')
local carray = require('carray')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local substr = perl.substr
local subst = perl.subst
local isMatch = perl.isMatch
local truthy = perl.truthy
local length = perl.length
local num = perl.num
local str = perl.str
local int = perl.int
local hex = perl.hex
local log = perl.log
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Set16u = ExifTool.Set16u
local GetByteOrder = ExifTool.GetByteOrder
local SetByteOrder = ExifTool.SetByteOrder

local PanasonicRaw = {}

-- (upstream's predeclarations `sub ProcessJpgFromRaw($$$);` ... `sub ProcessDistortionInfo($$$);`)
local ProcessJpgFromRaw, WriteJpgFromRaw, WriteDistortionInfo, ProcessDistortionInfo

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

local jpgFromRawMap = {
    IFD1         = 'IFD0',
    EXIF         = 'IFD0', -- to write EXIF as a block
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
    IFD0         = 'APP1',
    MakerNotes   = 'ExifIFD',
    Comment      = 'COM',
}

local wbTypeInfo = spread {
    PrintConv = Exif.lightSource,
    SeparateTable = 'EXIF LightSource',
}

local panasonicWhiteBalance = { -- #forum9396
    [0] = 'Auto',
    [1] = 'Daylight',
    [2] = 'Cloudy',
    [3] = 'Tungsten',
    [4] = 'n/a',
    [5] = 'Flash',
    [6] = 'n/a',
    [7] = 'n/a',
    [8] = 'Custom#1',
    [9] = 'Custom#2',
    [10] = 'Custom#3',
    [11] = 'Custom#4',
    [12] = 'Shade',
    [13] = 'Kelvin',
    [16] = 'AWBc', -- GH5 and G9 (Makernotes WB==19)
}

-- Tags found in Panasonic RAW/RW2/RWL images (ref PH)
PanasonicRaw.Main = {
    GROUPS = { [0] = 'EXIF', [1] = 'IFD0', [2] = 'Image'},
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITE_GROUP = 'IFD0',   -- default write group
    NOTES = 'These tags are found in IFD0 of Panasonic/Leica RAW, RW2 and RWL images.',
    [0x01] = {
        Name = 'PanasonicRawVersion',
        Writable = 'undef',
    },
    [0x02] = 'SensorWidth', -- #1/PH
    [0x03] = 'SensorHeight', -- #1/PH
    [0x04] = 'SensorTopBorder', -- #JD
    [0x05] = 'SensorLeftBorder', -- #JD
    [0x06] = 'SensorBottomBorder', -- #PH
    [0x07] = 'SensorRightBorder', -- #PH
    -- observed values for unknown tags - PH
    -- 0x08: 1
    -- 0x09: 1,3,4
    -- 0x0a: 12
    -- (IB gave 0x08-0x0a as BlackLevel tags, but Klaus' decoding makes more sense)
    [0x08] = { Name = 'SamplesPerPixel', Writable = 'int16u', Protected = 1 }, -- #4
    [0x09] = { -- #4
        Name = 'CFAPattern',
        Writable = 'int16u',
        Protected = 1,
        PrintConv = {
            [0] = 'n/a',
            [1] = '[Red,Green][Green,Blue]', -- (CM-1, FZ70)
            [2] = '[Green,Red][Blue,Green]', -- (LX-7)
            [3] = '[Green,Blue][Red,Green]', -- (ZS100, FZ2500, FZ1000, ...)
            [4] = '[Blue,Green][Green,Red]', -- (LC-100, G-7, V-LUX1, ...)
        },
    },
    [0x0a] = { Name = 'BitsPerSample', Writable = 'int16u', Protected = 1 }, -- #4
    [0x0b] = { -- #4
        Name = 'Compression',
        Writable = 'int16u',
        Protected = 1,
        PrintConv = {
            [34316] = 'Panasonic RAW 1', -- (most models - RAW/RW2/RWL)
            [34826] = 'Panasonic RAW 2', -- (DIGILUX 2 - RAW)
            [34828] = 'Panasonic RAW 3', -- (D-LUX2,D-LUX3,FZ30,LX1 - RAW)
            [34830] = 'Panasonic RAW 4', -- #IB (Leica DIGILUX 3, Panasonic DMC-L1)
        },
    },
    -- 0x0c: 2 (only Leica Digilux 2)
    -- 0x0d: 0,1
    -- 0x0e,0x0f,0x10: 4095
    [0x0e] = { Name = 'LinearityLimitRed',   Writable = 'int16u' }, -- #IB
    [0x0f] = { Name = 'LinearityLimitGreen', Writable = 'int16u' }, -- #IB
    [0x10] = { Name = 'LinearityLimitBlue',  Writable = 'int16u' }, -- #IB
    [0x11] = { -- #JD
        Name = 'RedBalance',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return int(val * 256 + 0.5) end,
        Notes = 'found in Digilux 2 RAW images',
    },
    [0x12] = { -- #JD
        Name = 'BlueBalance',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return int(val * 256 + 0.5) end,
    },
    [0x13] = { -- #IB
        Name = 'WBInfo',
        SubDirectory = { TagTable = 'lexiftool.PanasonicRaw.WBInfo' },
    },
    [0x17] = { -- #1
        Name = 'ISO',
        Writable = 'int16u',
    },
    -- 0x18,0x19,0x1a: 0
    [0x18] = { -- #IB
        Name = 'HighISOMultiplierRed',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return int(val * 256 + 0.5) end,
    },
    [0x19] = { -- #IB
        Name = 'HighISOMultiplierGreen',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return int(val * 256 + 0.5) end,
    },
    [0x1a] = { -- #IB
        Name = 'HighISOMultiplierBlue',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return int(val * 256 + 0.5) end,
    },
    -- 0x1b: [binary data] (something to do with the camera ISO cababilities: int16u count N,
    --                      followed by table of  N entries: int16u ISO, int16u[3] RGB gains - ref IB)
    [0x1c] = { Name = 'BlackLevelRed',   Writable = 'int16u' }, -- #IB
    [0x1d] = { Name = 'BlackLevelGreen', Writable = 'int16u' }, -- #IB
    [0x1e] = { Name = 'BlackLevelBlue',  Writable = 'int16u' }, -- #IB
    [0x24] = { -- #2
        Name = 'WBRedLevel',
        Writable = 'int16u',
    },
    [0x25] = { -- #2
        Name = 'WBGreenLevel',
        Writable = 'int16u',
    },
    [0x26] = { -- #2
        Name = 'WBBlueLevel',
        Writable = 'int16u',
    },
    [0x27] = { -- #IB
        Name = 'WBInfo2',
        SubDirectory = { TagTable = 'lexiftool.PanasonicRaw.WBInfo2' },
    },
    -- 0x27,0x29,0x2a,0x2b,0x2c: [binary data]
    [0x2d] = { -- #IB
        Name = 'RawFormat',
        Writable = 'int16u',
        Protected = 1,
        -- 2 - RAW DMC-FZ8/FZ18
        -- 3 - RAW DMC-L10
        -- 4 - RW2 for most other models, including G9 in "pixel shift off" mode and YUNEEC CGO4
        --     (must add 15 to black levels for RawFormat == 4)
        -- 5 - RW2 DC-GH5s; G9 in "pixel shift on" mode
        -- 6 - RW2 DC-S1, DC-S1r in "pixel shift off" mode
        -- 7 - RW2 DC-S1r (and probably DC-S1, have no raw samples) in "pixel shift on" mode
        -- not used - DMC-LX1/FZ30/FZ50/L1/LX1/LX2
        -- (modes 5 and 7 are lossless)
    },
    [0x2e] = { -- #JD
        Name = 'JpgFromRaw', -- (writable directory!)
        Groups = { [2] = 'Preview' },
        Writable = 'undef',
        -- protect this tag because it contains all the metadata
        Flags = { 'Binary', 'Protected', 'NestedHtmlDump', 'BlockExtract' },
        Notes = 'processed as an embedded document because it contains full EXIF',
        WriteCheck = function(self, _tagInfo, val) if val == 'none' then return nil end return self:CheckImage(val) end,
        DataTag = 'JpgFromRaw',
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
        SubDirectory = {
            -- extract information from embedded image since it is metadata-rich,
            -- unless HtmlDump option set (note that the offsets will be relative,
            -- not absolute like they should be in verbose mode)
            TagTable = 'lexiftool.JPEG.Main',
            WriteProc = false, -- predeclaration, see below for implementation
            ProcessProc = false, -- predeclaration, see below for implementation
        },
    },
    [0x2f] = { Name = 'CropTop',    Writable = 'int16u' },
    [0x30] = { Name = 'CropLeft',   Writable = 'int16u' },
    [0x31] = { Name = 'CropBottom', Writable = 'int16u' },
    [0x32] = { Name = 'CropRight',  Writable = 'int16u' },
    [0x37] = { Name = 'ISO',        Writable = 'int32u' },
    -- 0x44 - may contain another pointer to the raw data starting at byte 2 in this data (DC-GH6)
    [0x10f] = {
        Name = 'Make',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
        DataMember = 'Make',
        -- save this value as an ExifTool member variable
        RawConv = function(self, val) self.Make = val return val end,
    },
    [0x110] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
        DataMember = 'Model',
        -- save this value as an ExifTool member variable
        RawConv = function(self, val) self.Model = val return val end,
    },
    [0x111] = {
        Name = 'StripOffsets',
        -- (this value is 0xffffffff for some models, and RawDataOffset must be used)
        Flags = { 'IsOffset', 'PanasonicHack' },
        OffsetPair = 0x117,  -- point to associated byte counts
        ValueConv = function(_self, val) if length(val) > 32 then return { ref = 'SCALAR', value = val } end return val end,
    },
    [0x112] = {
        Name = 'Orientation',
        Writable = 'int16u',
        PrintConv = Exif.orientation,
        Priority = 0,  -- so IFD1 doesn't take precedence
    },
    [0x116] = {
        Name = 'RowsPerStrip',
        Priority = 0,
    },
    [0x117] = {
        Name = 'StripByteCounts',
        -- (note that this value may represent something like uncompressed byte count
        -- for RAW/RW2/RWL images from some models, and is zero for some other models)
        OffsetPair = 0x111,   -- point to associated offset
        ValueConv = function(_self, val) if length(val) > 32 then return { ref = 'SCALAR', value = val } end return val end,
    },
    [0x118] = {
        Name = 'RawDataOffset', -- #PH (RW2/RWL)
        IsOffset = function(et) return isMatch(et.TIFF_TYPE, '^(RW2|RWL)$') end, -- (invalid in DNG-converted files)
        PanasonicHack = 1,
        OffsetPair = 0x117, -- (use StripByteCounts as the offset pair)
        NotRealPair = 1,    -- (to avoid Validate warning)
        IsImageData = 1,
    },
    [0x119] = {
        Name = 'DistortionInfo',
        SubDirectory = { TagTable = 'lexiftool.PanasonicRaw.DistortionInfo' },
    },
    -- 0x11b - chromatic aberration correction (ref 3) (also see forum9366)
    [0x11c] = { -- #forum9373
        Name = 'Gamma',
        Writable = 'int16u',
        -- unfortunately it seems that the scaling factor varies with model...
        ValueConv = function(_self, val) return val / (num(val) >= 1024 and 1024 or (num(val) >= 256 and 256 or 100)) end,
        ValueConvInv = function(_self, val) return int(val * 256 + 0.5) end,
    },
    [0x120] = {
        Name = 'CameraIFD',
        SubDirectory = {
            TagTable = 'lexiftool.PanasonicRaw.CameraIFD',
            Base = function(_self, _val, start) return start end,
            ProcessProc = ExifTool.ProcessTIFF,
        },
    },
    [0x121] = { -- #forum9295
        Name = 'Multishot',
        Writable = 'int32u',
        PrintConv = {
            [0] = 'Off',
            [65536] = 'Pixel Shift',
        },
    },
    -- 0x122 - int32u: RAWDataOffset for the GH5s/GX9, or pointer to end of raw data for G9 (forum9295)
    [0x127] = { -- #github193 (newer models)
        Name = 'JpgFromRaw2',
        Groups = { [2] = 'Preview' },
        DataTag = 'JpgFromRaw2',
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
    [0x13b] = {
        Name = 'Artist',
        Groups = { [2] = 'Author' },
        Permanent = 1, -- (so we don't add it if the model doesn't write it)
        Writable = 'string',
        WriteGroup = 'IFD0',
        RawConv = function(_self, val) val = subst(val, [[\s+$]], '') return val end, -- trim trailing blanks
    },
    [0x2bc] = { -- PH Extension!!
        Name = 'ApplicationNotes', -- (writable directory!)
        Writable = 'int8u',
        Format = 'undef',
        Flags = { 'Binary', 'Protected' },
        SubDirectory = {
            DirName = 'XMP',
            TagTable = 'lexiftool.XMP.Main',
        },
    },
    [0x001b] = { -- #forum9250
        Name = 'NoiseReductionParams',
        Writable = 'undef',
        Format = 'int16u',
        Count = -1,
        Flags = 'Protected',
        Notes = [[
            the camera's default noise reduction setup.  The first number is the number
            of entries, then for each entry there are 4 numbers: an ISO speed, and
            noise-reduction strengths the R, G and B channels
        ]],
    },
    [0x8298] = { -- #github193
        Name = 'Copyright',
        Groups = { [2] = 'Author' },
        Permanent = 1, -- (so we don't add it if the model doesn't write it)
        Format = 'undef',
        Writable = 'string',
        WriteGroup = 'IFD0',
        RawConv = Exif.Main[0x8298].RawConv,
        RawConvInv = Exif.Main[0x8298].RawConvInv,
        PrintConvInv = Exif.Main[0x8298].PrintConvInv,
    },
    [0x83bb] = { -- PH Extension!!
        Name = 'IPTC-NAA', -- (writable directory!)
        Format = 'undef',      -- convert binary values as undef
        Writable = 'int32u',   -- but write int32u format code in IFD
        WriteGroup = 'IFD0',
        Flags = { 'Binary', 'Protected' },
        SubDirectory = {
            DirName = 'IPTC',
            TagTable = 'lexiftool.IPTC.Main',
        },
    },
    [0x8769] = {
        Name = 'ExifOffset',
        Groups = { [1] = 'ExifIFD' },
        Flags = 'SubIFD',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            DirName = 'ExifIFD',
            Start = function(_self, val) return val end,
        },
    },
    [0x8825] = {
        Name = 'GPSInfo',
        Groups = { [1] = 'GPS' },
        Flags = 'SubIFD',
        SubDirectory = {
            DirName = 'GPS',
            TagTable = 'lexiftool.GPS.Main',
            Start = function(_self, val) return val end,
        },
    },
    -- 0xffff => 'DCSHueShiftValues', #exifprobe (NC)
}

-- white balance information (ref IB)
-- (PanasonicRawVersion<200: Digilux 2)
PanasonicRaw.WBInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    [0] = 'NumWBEntries',
    [1] = wbTypeInfo { Name = 'WBType1' },
    [2] = { Name = 'WB_RBLevels1', Format = 'int16u[2]' },
    [4] = wbTypeInfo { Name = 'WBType2' },
    [5] = { Name = 'WB_RBLevels2', Format = 'int16u[2]' },
    [7] = wbTypeInfo { Name = 'WBType3' },
    [8] = { Name = 'WB_RBLevels3', Format = 'int16u[2]' },
    [10] = wbTypeInfo { Name = 'WBType4' },
    [11] = { Name = 'WB_RBLevels4', Format = 'int16u[2]' },
    [13] = wbTypeInfo { Name = 'WBType5' },
    [14] = { Name = 'WB_RBLevels5', Format = 'int16u[2]' },
    [16] = wbTypeInfo { Name = 'WBType6' },
    [17] = { Name = 'WB_RBLevels6', Format = 'int16u[2]' },
    [19] = wbTypeInfo { Name = 'WBType7' },
    [20] = { Name = 'WB_RBLevels7', Format = 'int16u[2]' },
}

-- white balance information (ref IB)
-- (PanasonicRawVersion>=200: D-Lux2, D-Lux3, DMC-FZ18/FZ30/LX1/L10)
PanasonicRaw.WBInfo2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    [0] = 'NumWBEntries',
    [1] = wbTypeInfo { Name = 'WBType1' },
    [2] = { Name = 'WB_RGBLevels1', Format = 'int16u[3]' },
    [5] = wbTypeInfo { Name = 'WBType2' },
    [6] = { Name = 'WB_RGBLevels2', Format = 'int16u[3]' },
    [9] = wbTypeInfo { Name = 'WBType3' },
    [10] = { Name = 'WB_RGBLevels3', Format = 'int16u[3]' },
    [13] = wbTypeInfo { Name = 'WBType4' },
    [14] = { Name = 'WB_RGBLevels4', Format = 'int16u[3]' },
    [17] = wbTypeInfo { Name = 'WBType5' },
    [18] = { Name = 'WB_RGBLevels5', Format = 'int16u[3]' },
    [21] = wbTypeInfo { Name = 'WBType6' },
    [22] = { Name = 'WB_RGBLevels6', Format = 'int16u[3]' },
    [25] = wbTypeInfo { Name = 'WBType7' },
    [26] = { Name = 'WB_RGBLevels7', Format = 'int16u[3]' },
}

-- lens distortion information (ref 3)
-- (distortion correction equation: Ru = scale*(Rd + a*Rd^3 + b*Rd^5 + c*Rd^7), ref 3)
PanasonicRaw.DistortionInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false, -- predeclaration, see below for implementation
    CHECK_PROC = Writer.CheckBinaryData,
    -- (don't make this family 0 MakerNotes because we don't want it to be a deletable group)
    GROUPS = { [0] = 'PanasonicRaw', [1] = 'PanasonicRaw', [2] = 'Image'},
    WRITABLE = 1,
    FORMAT = 'int16s',
    FIRST_ENTRY = 0,
    NOTES = 'Lens distortion correction information.',
    -- 0,1 - checksums
    [2] = {
        Name = 'DistortionParam02',
        ValueConv = function(_self, val) return val / 32768 end,
        ValueConvInv = function(_self, val) return val * 32768 end,
    },
    -- 3 - usually 0, but seen 0x026b when value 5 is non-zero
    [4] = {
        Name = 'DistortionParam04',
        ValueConv = function(_self, val) return val / 32768 end,
        ValueConvInv = function(_self, val) return val * 32768 end,
    },
    [5] = {
        Name = 'DistortionScale',
        ValueConv = function(_self, val) return 1 / (1 + val / 32768) end,
        ValueConvInv = function(_self, val) return (1 / val - 1) * 32768 end,
    },
    -- 6 - seen 0x0000-0x027f
    [7.1] = {
        Name = 'DistortionCorrection',
        Mask = 0x0f,
        -- (have seen the upper 4 bits set for GF5 and GX1, giving a value of -4095 - PH)
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [8] = {
        Name = 'DistortionParam08',
        ValueConv = function(_self, val) return val / 32768 end,
        ValueConvInv = function(_self, val) return val * 32768 end,
    },
    [9] = {
        Name = 'DistortionParam09',
        ValueConv = function(_self, val) return val / 32768 end,
        ValueConvInv = function(_self, val) return val * 32768 end,
    },
    -- 10 - seen 0xfc,0x0101,0x01f4,0x021d,0x0256
    [11] = {
        Name = 'DistortionParam11',
        ValueConv = function(_self, val) return val / 32768 end,
        ValueConvInv = function(_self, val) return val * 32768 end,
    },
    [12] = {
        Name = 'DistortionN',
        Unknown = 1,
    },
    -- 13 - seen 0x0000,0x01f9-0x02b2
    -- 14,15 - checksums
}

-- Panasonic RW2 camera IFD written by GH5 (ref PH)
-- (doesn't seem to be valid for the GF7 or GM5 -- encrypted?)
PanasonicRaw.CameraIFD = {
    GROUPS = { [0] = 'PanasonicRaw', [1] = 'CameraIFD', [2] = 'Camera'},
    -- (don't know what format codes 0x101 and 0x102 are for, so just
    --  map them into 4 = int32u for now)
    VARS = { MAP_FORMAT = { [0x101] = 4, [0x102] = 4 } },
    [0x1001] = { -- #forum9388
        Name = 'MultishotOn',
        Writable = 'int32u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x1100] = { -- #forum9274
        Name = 'FocusStepNear',
        Writable = 'int16s',
    },
    [0x1101] = { -- #forum9274 (was forum8484)
        Name = 'FocusStepCount',
        Writable = 'int16s',
    },
    [0x1102] = { -- #forum9417
        Name = 'FlashFired',
        Writable = 'int32u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    -- 0x1104 - set when camera shoots on lowest possible Extended-ISO (forum9290)
    [0x1105] = { -- #forum9392
        Name = 'ZoomPosition',
        Notes = 'in the range 0-255 for most cameras',
        Writable = 'int32u',
    },
    [0x1200] = { -- #forum9278
        Name = 'LensAttached',
        Notes = 'many CameraIFD tags are invalid if there is no lens attached',
        Writable = 'int32u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    -- Note: LensTypeMake and LensTypeModel are combined into a Composite LensType tag
    -- defined in Olympus.pm which has the same values as Olympus:LensType
    [0x1201] = { -- #IB
        Name = 'LensTypeMake',
        Condition = function(_self, _valPt, format) return format == 'int16u' end,
        Writable = 'int16u',
        -- when format is int16u, these values have been observed:
        --  0 - Olympus or unknown lens
        --  2 - Leica or Lumix lens
        -- when format is int32u (S models), these values have been observed (ref IB):
        --  256 - Leica lens
        --  257 - Lumix lens
        --  258 - ? (seen once)
    },
    [0x1202] = { -- #IB
        Name = 'LensTypeModel',
        Condition = function(_self, _valPt, format) return format == 'int16u' end,
        Writable = 'int16u',
        RawConv = function(_self, val)
            if not truthy(val) then return nil end
            require('lexiftool.Olympus') -- (to load Composite LensID)
            return val
        end,
        ValueConv = function(_self, val) local _ = sprintf('%.4x', val) _ = subst(_, '(..)(..)', '$2 $1') return _ end,
        ValueConvInv = function(_self, val) val = subst(val, '(..) (..)', '$2$1') return hex(val) end,
    },
    [0x1203] = { -- #4
        Name = 'FocalLengthIn35mmFormat',
        Writable = 'int16u',
        PrintConv = function(_self, val) return str(val) .. ' mm' end,
        PrintConvInv = function(_self, val) val = subst(val, [[\s*mm$]], '') return val end,
    },
    -- 0x1300 - incident light value? (ref forum11395)
    [0x1301] = { -- #forum11395
        Name = 'ApertureValue',
        Writable = 'int16s',
        Priority = 0,
        ValueConv = function(_self, val) return 2 ^ (val / 512) end,
        ValueConvInv = function(_self, val) if num(val) > 0 then return 512 * log(val) / log(2) end return 0 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x1302] = { -- #forum11395
        Name = 'ShutterSpeedValue',
        Writable = 'int16s',
        Priority = 0,
        ValueConv = function(_self, val) if math.abs(val / 256) < 100 then return 2 ^ (-val / 256) end return 0 end,
        ValueConvInv = function(_self, val) if num(val) > 0 then return -256 * log(val) / log(2) end return -25600 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [0x1303] = { -- #forum11395
        Name = 'SensitivityValue',
        Writable = 'int16s',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return int(val * 256) end,
    },
    [0x1305] = { -- #forum9384
        Name = 'HighISOMode',
        Writable = 'int16u',
        RawConv = function(_self, val) if truthy(val) then return val end return nil end,
        PrintConv = { [1] = 'On', [2] = 'Off' },
    },
    -- 0x1306 EV for some models like the GX8 (forum11395)
    -- 0x140b - scaled overall black level? (ref forum9281)
    -- 0x1411 - scaled black level per channel difference (ref forum9281)
    [0x1412] = { -- #forum11397
        Name = 'FacesDetected',
        Writable = 'int8u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    -- 0x2000 - WB tungsten=3, daylight=4 (ref forum9467)
    -- 0x2009 - scaled black level per channel (ref forum9281)
    -- 0x3000-0x310b - red/blue balances * 1024 (ref forum9467)
    --  0x3000 modifiedTungsten-Red (-2?)
    --  0x3001 modifiedTungsten-Blue (-2?)
    --  0x3002 modifiedDaylight-Red (-2?)
    --  0x3003 modifiedDaylight-Blue (-2?)
    --  0x3004 modifiedTungsten-Red (-1?)
    --  0x3005 modifiedTungsten-Blue (-1?)
    --  0x3006 modifiedDaylight-Red (-1?)
    --  0x3007 modifiedDaylight-Blue (-1?)
    --  0x3100 DefaultTungsten-Red
    --  0x3101 DefaultTungsten-Blue
    --  0x3102 DefaultDaylight-Red
    --  0x3103 DefaultDaylight-Blue
    --  0x3104 modifiedTungsten-Red (+1?)
    --  0x3105 modifiedTungsten-Blue (+1?)
    --  0x3106 modifiedDaylight-Red (+1?)
    --  0x3107 modifiedDaylight-Blue (+1?)
    --  0x3108 modifiedTungsten-Red (+2?)
    --  0x3109 modifiedTungsten-Blue (+2?)
    --  0x310a modifiedDaylight-Red (+2?)
    --  0x310b modifiedDaylight-Blue (+2?)
    [0x3200] = { -- #forum9275
        Name = 'WB_CFA0_LevelDaylight',
        Writable = 'int16u',
    },
    [0x3201] = { -- #forum9275
        Name = 'WB_CFA1_LevelDaylight',
        Writable = 'int16u',
    },
    [0x3202] = { -- #forum9275
        Name = 'WB_CFA2_LevelDaylight',
        Writable = 'int16u',
    },
    [0x3203] = { -- #forum9275
        Name = 'WB_CFA3_LevelDaylight',
        Writable = 'int16u',
    },
    -- 0x3204-0x3207 - user multipliers * 1024 ? (ref forum9275)
    -- 0x320a - scaled maximum value of raw data (scaling = 4x) (ref forum9281)
    -- 0x3209 - gamma (x256) (ref forum9281)
    [0x3300] = { -- #forum9296/9396
        Name = 'WhiteBalanceSet',
        Writable = 'int8u',
        PrintConv = panasonicWhiteBalance,
        SeparateTable = 'WhiteBalance',
    },
    [0x3420] = { -- #forum9276
        Name = 'WB_RedLevelAuto',
        Writable = 'int16u',
    },
    [0x3421] = { -- #forum9276
        Name = 'WB_BlueLevelAuto',
        Writable = 'int16u',
    },
    [0x3501] = { -- #4
        Name = 'Orientation',
        Writable = 'int8u',
        PrintConv = Exif.orientation,
    },
    -- 0x3504 = Tag 0x1301+0x1302-0x1303 (Bv = Av+Tv-Sv) (forum11395)
    -- 0x3505 - same as 0x1300 (forum11395)
    [0x3600] = { -- #forum9396
        Name = 'WhiteBalanceDetected',
        Writable = 'int8u',
        PrintConv = panasonicWhiteBalance,
        SeparateTable = 'WhiteBalance',
    },
}

-- PanasonicRaw composite tags
PanasonicRaw.Composite = {
    ImageWidth = {
        TagID = 'PanasonicRaw-ImageWidth',
        Require = {
            [0] = 'IFD0:SensorLeftBorder',
            [1] = 'IFD0:SensorRightBorder',
        },
        ValueConv = function(_self, val) return val[1] - val[0] end,
    },
    ImageHeight = {
        TagID = 'PanasonicRaw-ImageHeight',
        Require = {
            [0] = 'IFD0:SensorTopBorder',
            [1] = 'IFD0:SensorBottomBorder',
        },
        ValueConv = function(_self, val) return val[1] - val[0] end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.PanasonicRaw', nil, PanasonicRaw)

--------------------------------------------------------------------------------
-- checksum algorithm for lens distortion correction information (ref 3)
-- Inputs: 0) data ref, 1) start position, 2) number of bytes, 3) incement

--------------------------------------------------------------------------------
-- checksum algorithm for lens distortion correction information (ref 3)
-- Inputs: 0) data ref, 1) start position, 2) number of bytes, 3) incement
-- Returns: checksum value
function PanasonicRaw.Checksum(dataPt, start, n, inc)
    local csum = 0
    for i = 0, n - 1 do
        csum = (73 * csum + Get8u(dataPt, start + i * inc)) % 0xffef
    end
    return csum
end

--------------------------------------------------------------------------------
-- Read lens distortion information
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessDistortionInfo(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart or 0
    local size = truthy(dirInfo.DirLen) and dirInfo.DirLen or (length(dataPt) - start)
    if size == 32 then
        -- verify the checksums (ref 3)
        local csum1 = PanasonicRaw.Checksum(dataPt, start +  4, 12, 1)
        local csum2 = PanasonicRaw.Checksum(dataPt, start + 16, 12, 1)
        local csum3 = PanasonicRaw.Checksum(dataPt, start +  2, 14, 2)
        local csum4 = PanasonicRaw.Checksum(dataPt, start +  3, 14, 2)
        local res = csum1 ~ Get16u(dataPt, start + 2) ~
                    csum2 ~ Get16u(dataPt, start + 28) ~
                    csum3 ~ Get16u(dataPt, start + 0) ~
                    csum4 ~ Get16u(dataPt, start + 30)
        if res ~= 0 then et:Warn('Invalid DistortionInfo checksum', 1) end
    else
        et:Warn('Invalid DistortionInfo', 1)
    end
    return et:ProcessBinaryData(dirInfo, tagTablePtr)
end
PanasonicRaw.ProcessDistortionInfo = ProcessDistortionInfo

--------------------------------------------------------------------------------
-- Write lens distortion information
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: updated distortion information or undef on error
function WriteDistortionInfo(et, dirInfo, tagTablePtr)
    if not et then return 1 end  -- (allow dummy access)
    local dat = Writer.WriteBinaryData(et, dirInfo, tagTablePtr)
    if dat ~= nil and length(dat) == 32 then
        -- fix checksums (ref 3)
        local buf = carray.new('char'):append(dat)
        Set16u(buf,  2, PanasonicRaw.Checksum(dat,  4, 12, 1))
        Set16u(buf, 28, PanasonicRaw.Checksum(dat, 16, 12, 1))
        dat = buf:tostring()
        Set16u(buf,  0, PanasonicRaw.Checksum(dat,  2, 14, 2))
        dat = buf:tostring()
        Set16u(buf, 30, PanasonicRaw.Checksum(dat,  3, 14, 2))
        dat = buf:tostring()
    else
        et:Warn('Error wriing DistortionInfo', 1)
    end
    return dat
end
PanasonicRaw.WriteDistortionInfo = WriteDistortionInfo

--------------------------------------------------------------------------------
-- Patch necessary metadata for RawDataOffset (upstream PatchRawDataOffset)
-- Inputs: 0) offsetInfo ref, 1) raf ref, 2) IFD number
-- Returns: error string, or nil on success
-- An offsetInfo entry is `{ tagInfo, offsetPos, count, vals, format }`
-- (upstream's 0-based [0..4]); this routine appends a sixth element, the
-- position of the StripOffsets value, so WriteExif can update that one too.
--------------------------------------------------------------------------------
function PanasonicRaw.PatchRawDataOffset(offsetInfo, raf, ifd)
    local stripOffsets = offsetInfo[0x111]
    local stripByteCounts = offsetInfo[0x117]
    local rawDataOffset = offsetInfo[0x118]
    local err
    if ifd ~= 0 then err = 1 end
    if stripOffsets or stripByteCounts then
        if not (stripOffsets and stripByteCounts and stripOffsets[3] == 1) then err = 1 end
    else
        -- the DC-GH6 and DC-GH5M2 write RawDataOffset with no Strip tags, so we need
        -- to create fake StripByteCounts information for copying the data
        if offsetInfo[0x118] then -- (just to be safe)
            stripByteCounts = { PanasonicRaw.Main[0x117], 0, 1, { 0 }, 4 }
            offsetInfo[0x117] = stripByteCounts
            -- set flag so the offset will be fixed (GH6 hack)
            offsetInfo[0x118][7] = 1
        end
    end
    if rawDataOffset and not err then
        if rawDataOffset[3] ~= 1 then err = 1 end
        if stripOffsets then
            -- NB the values come out of ReadValue as strings, so these have to
            -- be numeric comparisons, not Lua's `==` between a string and a number
            if not (tonumber(stripOffsets[4][1]) == 0xffffffff or
                    tonumber(stripByteCounts[4][1]) == 0) then
                err = 1
            end
        end
    end
    if err then return 'Unsupported Panasonic/Leica RAW variant' end
    if rawDataOffset then
        -- update StripOffsets along with this tag if it contains a reasonable value
        if stripOffsets and tonumber(stripOffsets[4][1]) ~= 0xffffffff then
            -- save pointer to StripOffsets value for updating later
            rawDataOffset[#rawDataOffset + 1] = stripOffsets[2]
        end
        -- handle via RawDataOffset instead of StripOffsets
        stripOffsets = rawDataOffset
        offsetInfo[0x111] = rawDataOffset
        offsetInfo[0x118] = nil
    end
    -- determine the length of the raw data
    local pos = raf:Tell()
    if not raf:Seek(0, 2) then err = 1 end -- seek to end of file
    local len = raf:Tell() - (tonumber(stripOffsets[4][1]) or 0)
    raf:Seek(pos, 0)
    -- quick check to be sure the raw data length isn't unreasonable
    -- (the 22-byte length is for '<Dummy raw image data>' in our tests)
    if (len < 1000 and len ~= 22) or (len & 0x80000000) ~= 0 then err = 1 end
    if err then return 'Error reading Panasonic raw data' end
    -- update StripByteCounts info with raw data length
    -- (note that the original value is maintained in the file)
    stripByteCounts[4][1] = len
    return nil
end

--------------------------------------------------------------------------------
-- Write meta information to Panasonic JpgFromRaw in RAW/RW2/RWL image
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: updated image data, or undef if nothing changed
function WriteJpgFromRaw(et, dirInfo, _tagTablePtr)
    local dataPt = dirInfo.DataPt
    local byteOrder = GetByteOrder()
    local fileType = et.TIFF_TYPE   -- RAW, RW2 or RWL
    local dirStart = dirInfo.DirStart
    if truthy(dirStart) then -- DirStart is non-zero in DNG-converted RW2/RWL
        local dirLen = int(dirInfo.DirLen or 0) | (length(dataPt) - dirStart)
        dataPt = substr(dataPt, dirStart, dirLen)
    end
    local raf = RandomAccess.new(dataPt)
    local outbuff = carray.new('char')  -- (`\$outbuff` is the box { value = <carray> })
    local dirInfo2 = {
        RAF = raf,
        OutFile = { value = outbuff },
    }
    et.BASE = dirInfo.DataPos
    et.FILE_TYPE = 'JPEG'
    et.TIFF_TYPE = 'JPEG'
    -- use a specialized map so we don't write XMP or IPTC (or other junk) into the JPEG
    local editDirs = et.EDIT_DIRS
    local addDirs = et.ADD_DIRS
    Writer.InitWriteDirs(et, jpgFromRawMap)
    -- don't add XMP segment (IPTC won't get added because it is in Photoshop record)
    et.ADD_DIRS.XMP = nil
    local result = et:WriteJPEG(dirInfo2)
    -- restore variables we changed
    et.BASE = 0
    et.FILE_TYPE = 'TIFF'
    et.TIFF_TYPE = fileType
    et.EDIT_DIRS = editDirs
    et.ADD_DIRS = addDirs
    SetByteOrder(byteOrder)
    if num(result) > 0 then return outbuff:tostring() end
    return dataPt
end
PanasonicRaw.WriteJpgFromRaw = WriteJpgFromRaw

--------------------------------------------------------------------------------
-- Extract meta information from an Panasonic JpgFromRaw
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JpgFromRaw image
function ProcessJpgFromRaw(et, dirInfo, _tagTablePtr)
    local dataPt = dirInfo.DataPt
    local byteOrder = GetByteOrder()
    local fileType = et.TIFF_TYPE   -- RAW, RW2 or RWL
    local tagInfo = dirInfo.TagInfo
    local verbose = et:Options('Verbose')
    local indent, out
    if not tagInfo then et:Warn('No tag info for Panasonic JpgFromRaw') return 0 end
    local dirStart = dirInfo.DirStart
    if truthy(dirStart) then -- DirStart is non-zero in DNG-converted RW2/RWL
        local dirLen = int(dirInfo.DirLen or 0) | (length(dataPt) - dirStart)
        dataPt = substr(dataPt, dirStart, dirLen)
    end
    et.BASE = dirInfo.DataPos + (dirStart or 0)
    et.FILE_TYPE = 'JPEG'
    et.TIFF_TYPE = 'JPEG'
    et.DOC_NUM = 1
    -- extract information from embedded JPEG
    local dirInfo2 = {
        Parent = 'RAF',
        RAF    = RandomAccess.new(dataPt),
    }
    if truthy(verbose) then
        -- (upstream declares a second `my $indent` here, so its restore
        --  below writes undef; this keeps the saved value instead)
        indent = et.INDENT
        et.INDENT = '  '
        out = et:Options('TextOut') or io.stdout
        out:write('--- DOC1:JpgFromRaw ', string.rep('-', 56), '\n')
    end
    -- fudge HtmlDump base offsets to show as a stand-alone JPEG
    et.BASE_FUDGE = et.BASE
    local rtnVal = et:ProcessJPEG(dirInfo2)
    et.BASE_FUDGE = nil -- (upstream: 0, i.e. false)
    -- restore necessary variables for continued RW2/RWL processing
    et.BASE = 0
    et.FILE_TYPE = 'TIFF'
    et.TIFF_TYPE = fileType
    et.DOC_NUM = nil
    SetByteOrder(byteOrder)
    if truthy(verbose) then
        et.INDENT = indent
        out:write(string.rep('-', 76), '\n')
    end
    return rtnVal
end
PanasonicRaw.ProcessJpgFromRaw = ProcessJpgFromRaw

-- (the predeclared ProcessProc/WriteProc/PROCESS_PROC/WRITE_PROC entries above)
PanasonicRaw.Main[0x2e].SubDirectory.ProcessProc = ProcessJpgFromRaw
PanasonicRaw.Main[0x2e].SubDirectory.WriteProc = WriteJpgFromRaw
PanasonicRaw.DistortionInfo.PROCESS_PROC = ProcessDistortionInfo
PanasonicRaw.DistortionInfo.WRITE_PROC = WriteDistortionInfo

return PanasonicRaw
