--------------------------------------------------------------------------------
-- File:         lexiftool/CanonVRD.lua
-- Ported from:  lib/Image/ExifTool/CanonVRD.pm
--
-- Description:  Read/write Canon VRD and DR4 information
--
-- Revisions:    2006/10/30 - P. Harvey Created
--               2007/10/23 - PH Added new VRD 3.0 tags
--               2008/08/29 - PH Added new VRD 3.4 tags
--               2008/12/02 - PH Added new VRD 3.5 tags
--               2010/06/18 - PH Support variable-length CustomPictureStyle data
--               2010/09/14 - PH Added r/w support for XMP in VRD
--               2015/05/16 - PH Added DR4 support (DPP 4.1.50.0)
--               2018/03/13 - PH Update to DPP 4.8.20
--
-- References:   1) Bogdan private communication (Canon DPP v3.4.1.1)
--               2) Gert Kello private communication (DPP 3.8)
--
-- Port notes:   Complete port of CanonVRD.pm: every table and sub, in
--               upstream order (tables mechanically extracted from the Perl,
--               `#` comments carried as `--`, inverse conversions included).
--               `make verify` compares all tables against the original.
--               Deviations forced by Lua:
--               - PROCESS_PROC/WRITE_PROC/ProcessProc/SORT_PROC references to
--                 the predeclared subs are `false` placeholders filled in at
--                 the bottom of the file.
--               - `%noYes` is spread with the `noYes { }` helper.
--               - Upstream edits the VRD buffer in place (`substr(...) =`,
--                 Set32u into $$dataPt); Lua strings are immutable, so the
--                 port splices a new string (spliceSub), and upstream's
--                 "edit the output buffer in place" shortcut in
--                 ProcessCanonVRD is not taken.  Write() is Writer.Write; a
--                 scalar ref is the box `{ value = <carray> }`.
--               - An undefined `Size` in the Edit tables is left out (nil),
--                 which ProcessEditData reads as Perl's `not defined`.
--               WriteCanonDR4 and the IHL processors are ported; WriteCanonDR4
--               is not exercised by a test (no vendored CR3 to rewrite).
--------------------------------------------------------------------------------
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local subst = perl.subst
local findAll = perl.findAll
local isMatch = perl.isMatch
local truthy = perl.truthy
local length = perl.length
local join = perl.join
local num = perl.num
local int = perl.int
local str = perl.str
local hex = perl.hex
local log = perl.log
local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local carray = require('carray')
local RandomAccess = require('lexiftool.RandomAccess')
local Canon = require('lexiftool.Canon')
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local ToFloat = ExifTool.ToFloat

local CanonVRD = {}

local Write = Writer.Write

-- Lua strings are immutable, so upstream's in-place `substr($$dataPt, $off,
-- $len) = $new` becomes a splice returning the new string (0-based offset).
local function spliceSub(s, off, len, new)
    return s:sub(1, off) .. new .. s:sub(off + len + 1)
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

-- map for adding directories to VRD
local vrdMap = {
    XMP      = 'CanonVRD',
    CanonVRD = 'VRD',
}

local noYes = spread {
    PrintConvColumns = 2,
    PrintConv = { [0] = 'No', [1] = 'Yes' },
}

-- DR4 format codes
local vrdFormat = {
    [1] = 'int32u',
    [2] = 'string',
    [8] = 'int32u',
    [9] = 'int32s',
    [13] = 'double',
    [24] = 'int32s', -- (rectangle coordinates)
    [33] = 'int32u', -- (array)
    [38] = 'double', -- (array)
    -- 254 => 'undef', ?
    [255] = 'undef',
}

-- empty VRD header/footer for creating VRD from scratch
local blankHeader = 'CANON OPTIONAL DATA\0\0\x01\0\0\0\0\0\0'
local blankFooter = 'CANON OPTIONAL DATA\0' .. string.rep('\0', 42) .. '\xff\xd9'

-- main tag table blocks in CanonVRD trailer (ref PH)
CanonVRD.Main = {
    WRITE_PROC = false, -- predeclaration, see below for implementation
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        Canon Digital Photo Professional writes VRD (Recipe Data) information as a
        trailer record to JPEG, TIFF, CRW and CR2 images, or as stand-alone VRD or
        DR4 files.  The tags listed below represent information found in these
        records.  The complete VRD/DR4 data record may be accessed as a block using
        the Extra 'CanonVRD' or 'CanonDR4' tag, but this tag is not extracted or
        copied unless specified explicitly.
    ]],
    [0xffff00f4] = {
        Name = 'EditData',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Edit' },
    },
    [0xffff00f5] = {
        Name = 'IHLData',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.IHL' },
    },
    [0xffff00f6] = {
        Name = 'XMP',
        Flags = { 'Binary', 'Protected' },
        Writable = 'undef',    -- allow writing/deleting as a block
        SubDirectory = {
            DirName = 'XMP',
            TagTable = 'lexiftool.XMP.Main',
        },
    },
    [0xffff00f7] = {
        Name = 'Edit4Data',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Edit4' },
    },
}

-- the VRD edit information is divided into sections
CanonVRD.Edit = {
    WRITE_PROC = false, -- predeclaration, see below for implementation
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    VARS = { ID_LABEL = 'Index' }, -- change TagID label in documentation
    NOTES = 'Canon VRD edit information.',
    [0] = {
        Name = 'VRD1',
        Size = 0x272,  -- size of version 1.0 edit information in bytes
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Ver1' },
    },
    [1] = {
        Name = 'VRDStampTool',
        Size = 0,      -- size is variable, and obtained from int32u at directory start
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.StampTool' },
    },
    [2] = {
        Name = 'VRD2',
        Size = false,  -- size is the remaining edit data
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Ver2' },
    },
}

-- Canon DPP version 4 edit information
CanonVRD.Edit4 = {
    WRITE_PROC = false, -- predeclaration, see below for implementation
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    VARS = { ID_LABEL = 'Index' }, -- change TagID label in documentation
    NOTES = 'Canon DPP version 4 edit information.',
    [0] = {
        Name = 'DR4',
        Size = false,  -- size is the remaining edit data
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.DR4' },
    },
}

-- "IHL Created Optional Item Data" tags (not yet writable)
CanonVRD.IHL = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    TAG_PREFIX = 'VRD_IHL',
    GROUPS = { [2] = 'Image' },
    [1] = {
        -- this contains edited TIFF-format data, with an original IFD at 0x0008
        -- and an edited IFD with offset given in the TIFF header.
        {
            Name = 'IHL_EXIF',
            Condition = function(self) return self:Options('ExtractEmbedded') end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = false, -- predeclaration, see below for implementation
            },
        }, {
            Name = 'IHL_EXIF',
            Notes = [[
                extracted as a block if the L<Unknown|../ExifTool.html#Unknown> option is used, or processed as the
                first sub-document with the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option
            ]],
            Binary = 1,
            Unknown = 1,
        },
    },
    -- 2 - written by DPP 3.0.2.6, and it looks something like edit data,
    --     but I haven't decoded it yet - PH
    [3] = {
        -- (same size as the PreviewImage with DPP 3.0.2.6)
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    [4] = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    [5] = {
        Name = 'RawCodecVersion',
        ValueConv = function(_self, val) val = subst(val, [[(?s)\0.*]], '') return val end,  -- truncate string at null
    },
    [6] = {
        Name = 'CRCDevelParams',
        Binary = 1,
        Unknown = 1,
    },
}

-- VRD version 1 tags (ref PH)
CanonVRD.Ver1 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    PERMANENT = 1, -- (can't add/delete these individually)
    FIRST_ENTRY = 0,
    GROUPS = { [2] = 'Image' },
    DATAMEMBER = { 0x002 },   -- necessary for writing
--
-- RAW image adjustment
--
    [0x002] = {
        Name = 'VRDVersion',
        Format = 'int16u',
        Writable = 0,
        DataMember = 'VRDVersion',
        RawConv = function(self, val) self.VRDVersion = val; return val end,
        PrintConv = function(_self, val) val = subst(val, [[^(\d)(\d*)(\d)$]], '$1.$2.$3') return val end,
    },
    [0x006] = {
        Name = 'WBAdjRGGBLevels',
        Format = 'int16u[4]',
    },
    [0x018] = {
        Name = 'WhiteBalanceAdj',
        Format = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Daylight',
            [2] = 'Cloudy',
            [3] = 'Tungsten',
            [4] = 'Fluorescent',
            [5] = 'Flash',
            [8] = 'Shade',
            [9] = 'Kelvin',
            [30] = 'Manual (Click)',
            [31] = 'Shot Settings',
        },
    },
    [0x01a] = {
        Name = 'WBAdjColorTemp',
        Format = 'int16u',
    },
    -- 0x01c similar to 0x006
    [0x024] = noYes {
        Name = 'WBFineTuneActive',
        Format = 'int16u',
        -- %noYes,
    },
    [0x028] = {
        Name = 'WBFineTuneSaturation',
        Format = 'int16u',
    },
    [0x02c] = {
        Name = 'WBFineTuneTone',
        Format = 'int16u',
    },
    [0x02e] = {
        Name = 'RawColorAdj',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Shot Settings',
            [1] = 'Faithful',
            [2] = 'Custom',
        },
    },
    [0x030] = {
        Name = 'RawCustomSaturation',
        Format = 'int32s',
    },
    [0x034] = {
        Name = 'RawCustomTone',
        Format = 'int32s',
    },
    [0x038] = {
        Name = 'RawBrightnessAdj',
        Format = 'int32s',
        ValueConv = function(_self, val) return val / 6000 end,
        ValueConvInv = function(_self, val) return int(val * 6000 + (num(val) < 0 and -0.5 or 0.5)) end,
        PrintConv = function(_self, val) return sprintf('%.2f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x03c] = {
        Name = 'ToneCurveProperty',
        Format = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Shot Settings',
            [1] = 'Linear',
            [2] = 'Custom 1',
            [3] = 'Custom 2',
            [4] = 'Custom 3',
            [5] = 'Custom 4',
            [6] = 'Custom 5',
        },
    },
    -- 0x040 usually "10 9 2"
    [0x07a] = {
        Name = 'DynamicRangeMin',
        Format = 'int16u',
    },
    [0x07c] = {
        Name = 'DynamicRangeMax',
        Format = 'int16u',
    },
    -- 0x0c6 usually "10 9 2"
--
-- RGB image adjustment
--
    [0x110] = noYes {
        Name = 'ToneCurveActive',
        Format = 'int16u',
        -- %noYes,
    },
    [0x113] = {
        Name = 'ToneCurveMode',
        PrintConv = { [0] = 'RGB', [1] = 'Luminance' },
    },
    [0x114] = {
        Name = 'BrightnessAdj',
        Format = 'int8s',
    },
    [0x115] = {
        Name = 'ContrastAdj',
        Format = 'int8s',
    },
    [0x116] = {
        Name = 'SaturationAdj',
        Format = 'int16s',
    },
    [0x11e] = {
        Name = 'ColorToneAdj',
        Notes = 'in degrees, so -1 is the same as 359',
        Format = 'int32s',
    },
    [0x126] = {
        Name = 'LuminanceCurvePoints',
        Format = 'int16u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    [0x150] = {
        Name = 'LuminanceCurveLimits',
        Notes = '4 numbers: input and output highlight and shadow points',
        Format = 'int16u[4]',
    },
    [0x159] = {
        Name = 'ToneCurveInterpolation',
        PrintConv = { [0] = 'Curve', [1] = 'Straight' },
    },
    [0x160] = {
        Name = 'RedCurvePoints',
        Format = 'int16u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    -- 0x193 same as 0x159
    [0x19a] = {
        Name = 'GreenCurvePoints',
        Format = 'int16u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    -- 0x1cd same as 0x159
    [0x1d4] = {
        Name = 'BlueCurvePoints',
        Format = 'int16u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    [0x18a] = {
        Name = 'RedCurveLimits',
        Format = 'int16u[4]',
    },
    [0x1c4] = {
        Name = 'GreenCurveLimits',
        Format = 'int16u[4]',
    },
    [0x1fe] = {
        Name = 'BlueCurveLimits',
        Format = 'int16u[4]',
    },
    -- 0x207 same as 0x159
    [0x20e] = {
        Name = 'RGBCurvePoints',
        Format = 'int16u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    [0x238] = {
        Name = 'RGBCurveLimits',
        Format = 'int16u[4]',
    },
    -- 0x241 same as 0x159
    [0x244] = noYes {
        Name = 'CropActive',
        Format = 'int16u',
        -- %noYes,
    },
    [0x246] = {
        Name = 'CropLeft',
        Notes = 'crop coordinates in original unrotated image',
        Format = 'int16u',
    },
    [0x248] = {
        Name = 'CropTop',
        Format = 'int16u',
    },
    [0x24a] = {
        Name = 'CropWidth',
        Format = 'int16u',
    },
    [0x24c] = {
        Name = 'CropHeight',
        Format = 'int16u',
    },
    [0x25a] = {
        Name = 'SharpnessAdj',
        Format = 'int16u',
    },
    [0x260] = {
        Name = 'CropAspectRatio',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Free',
            [1] = '3:2',
            [2] = '2:3',
            [3] = '4:3',
            [4] = '3:4',
            [5] = 'A-size Landscape',
            [6] = 'A-size Portrait',
            [7] = 'Letter-size Landscape',
            [8] = 'Letter-size Portrait',
            [9] = '4:5',
            [10] = '5:4',
            [11] = '1:1',
            [12] = 'Circle',
            [65535] = 'Custom',
        },
    },
    [0x262] = {
        Name = 'ConstrainedCropWidth',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.7g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x266] = {
        Name = 'ConstrainedCropHeight',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.7g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x26a] = {
        Name = 'CheckMark',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Clear',
            [1] = 1,
            [2] = 2,
            [3] = 3,
        },
    },
    [0x26e] = {
        Name = 'Rotation',
        Format = 'int16u',
        PrintConv = {
            [0] = 0,
            [1] = 90,
            [2] = 180,
            [3] = 270,
        },
    },
    [0x270] = {
        Name = 'WorkColorSpace',
        Format = 'int16u',
        PrintConv = {
            [0] = 'sRGB',
            [1] = 'Adobe RGB',
            [2] = 'Wide Gamut RGB',
            [3] = 'Apple RGB',
            [4] = 'ColorMatch RGB',
        },
    },
    -- (VRD 1.0.0 edit data ends here -- 0x272 bytes)
}

-- VRD Stamp Tool tags (ref PH)
CanonVRD.StampTool = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0x00] = {
        Name = 'StampToolCount',
        Format = 'int32u',
    },
}

-- VRD version 2 and 3 tags (ref PH)
CanonVRD.Ver2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    PERMANENT = 1, -- (can't add/delete these individually)
    FIRST_ENTRY = 0,
    FORMAT = 'int16s',
    DATAMEMBER = { 0x58, 0xdc, 0xdf, 0xe0 }, -- (required for DataMember and var-format tags)
    IS_SUBDIR = { 0xe0 },
    GROUPS = { [2] = 'Image' },
    NOTES = 'Tags added in DPP version 2.0 and later.',
    [0x02] = {
        Name = 'PictureStyle',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Standard',
            [1] = 'Portrait',
            [2] = 'Landscape',
            [3] = 'Neutral',
            [4] = 'Faithful',
            [5] = 'Monochrome',
            [6] = 'Unknown?', -- PH (maybe in-camera custom picture style?)
            [7] = 'Custom',
        },
    },
    [0x03] = noYes { Name = 'IsCustomPictureStyle' },
    -- 0x08: 3
    -- 0x09: 4095
    -- 0x0a: 0
    -- 0x0b: 4095
    -- 0x0c: 0
    [0x0d] = 'StandardRawColorTone',
    [0x0e] = 'StandardRawSaturation',
    [0x0f] = 'StandardRawContrast',
    [0x10] = noYes { Name = 'StandardRawLinear' },
    [0x11] = 'StandardRawSharpness',
    [0x12] = 'StandardRawHighlightPoint',
    [0x13] = 'StandardRawShadowPoint',
    [0x14] = 'StandardOutputHighlightPoint', -- #2
    [0x15] = 'StandardOutputShadowPoint', -- #2
    [0x16] = 'PortraitRawColorTone',
    [0x17] = 'PortraitRawSaturation',
    [0x18] = 'PortraitRawContrast',
    [0x19] = noYes { Name = 'PortraitRawLinear' },
    [0x1a] = 'PortraitRawSharpness',
    [0x1b] = 'PortraitRawHighlightPoint',
    [0x1c] = 'PortraitRawShadowPoint',
    [0x1d] = 'PortraitOutputHighlightPoint',
    [0x1e] = 'PortraitOutputShadowPoint',
    [0x1f] = 'LandscapeRawColorTone',
    [0x20] = 'LandscapeRawSaturation',
    [0x21] = 'LandscapeRawContrast',
    [0x22] = noYes { Name = 'LandscapeRawLinear' },
    [0x23] = 'LandscapeRawSharpness',
    [0x24] = 'LandscapeRawHighlightPoint',
    [0x25] = 'LandscapeRawShadowPoint',
    [0x26] = 'LandscapeOutputHighlightPoint',
    [0x27] = 'LandscapeOutputShadowPoint',
    [0x28] = 'NeutralRawColorTone',
    [0x29] = 'NeutralRawSaturation',
    [0x2a] = 'NeutralRawContrast',
    [0x2b] = noYes { Name = 'NeutralRawLinear' },
    [0x2c] = 'NeutralRawSharpness',
    [0x2d] = 'NeutralRawHighlightPoint',
    [0x2e] = 'NeutralRawShadowPoint',
    [0x2f] = 'NeutralOutputHighlightPoint',
    [0x30] = 'NeutralOutputShadowPoint',
    [0x31] = 'FaithfulRawColorTone',
    [0x32] = 'FaithfulRawSaturation',
    [0x33] = 'FaithfulRawContrast',
    [0x34] = noYes { Name = 'FaithfulRawLinear' },
    [0x35] = 'FaithfulRawSharpness',
    [0x36] = 'FaithfulRawHighlightPoint',
    [0x37] = 'FaithfulRawShadowPoint',
    [0x38] = 'FaithfulOutputHighlightPoint',
    [0x39] = 'FaithfulOutputShadowPoint',
    [0x3a] = {
        Name = 'MonochromeFilterEffect',
        PrintConv = {
            [-2] = 'None',
            [-1] = 'Yellow',
            [0] = 'Orange',
            [1] = 'Red',
            [2] = 'Green',
        },
    },
    [0x3b] = {
        Name = 'MonochromeToningEffect',
        PrintConv = {
            [-2] = 'None',
            [-1] = 'Sepia',
            [0] = 'Blue',
            [1] = 'Purple',
            [2] = 'Green',
        },
    },
    [0x3c] = 'MonochromeContrast',
    [0x3d] = noYes { Name = 'MonochromeLinear' },
    [0x3e] = 'MonochromeSharpness',
    [0x3f] = 'MonochromeRawHighlightPoint',
    [0x40] = 'MonochromeRawShadowPoint',
    [0x41] = 'MonochromeOutputHighlightPoint',
    [0x42] = 'MonochromeOutputShadowPoint',
    [0x45] = { Name = 'UnknownContrast',            Unknown = 1 },
    [0x46] = noYes { Name = 'UnknownLinear',      Unknown = 1 },
    [0x47] = { Name = 'UnknownSharpness',           Unknown = 1 },
    [0x48] = { Name = 'UnknownRawHighlightPoint',   Unknown = 1 },
    [0x49] = { Name = 'UnknownRawShadowPoint',      Unknown = 1 },
    [0x4a] = { Name = 'UnknownOutputHighlightPoint',Unknown = 1 },
    [0x4b] = { Name = 'UnknownOutputShadowPoint',   Unknown = 1 },
    [0x4c] = 'CustomColorTone',
    [0x4d] = 'CustomSaturation',
    [0x4e] = 'CustomContrast',
    [0x4f] = noYes { Name = 'CustomLinear' },
    [0x50] = 'CustomSharpness',
    [0x51] = 'CustomRawHighlightPoint',
    [0x52] = 'CustomRawShadowPoint',
    [0x53] = 'CustomOutputHighlightPoint',
    [0x54] = 'CustomOutputShadowPoint',
    [0x58] = {
        Name = 'CustomPictureStyleData',
        Format = 'var_int16u',
        Binary = 1,
        Notes = 'variable-length data structure',
        Writable = 0,
        RawConv = function(_self, val) if length(val) == 2 then return nil end return val end, -- ignore if no data
    },
    -- (VRD 2.0.0 edit data ends here: 178 bytes, index 0x59)
    [0x5e] = {{
        Name = 'ChrominanceNoiseReduction',
        Condition = function(self) return num(self.VRDVersion) < 330 end,
        Notes = 'VRDVersion prior to 3.3.0',
        PrintConv = {
            [0]   = 'Off',
            [58]  = 'Low',
            [100] = 'High',
        },
    }, { -- #1
        Name = 'ChrominanceNoiseReduction',
        Notes = 'VRDVersion 3.3.0 or later',
        PrintHex = 1,
        PrintConvColumns = 4,
        PrintConv = {
            [0x00] = 0,
            [0x10] = 1,
            [0x21] = 2,
            [0x32] = 3,
            [0x42] = 4,
            [0x53] = 5,
            [0x64] = 6,
            [0x74] = 7,
            [0x85] = 8,
            [0x96] = 9,
            [0xa6] = 10,
            [0xa7] = 11,
            [0xa8] = 12,
            [0xa9] = 13,
            [0xaa] = 14,
            [0xab] = 15,
            [0xac] = 16,
            [0xad] = 17,
            [0xae] = 18,
            [0xaf] = 19,
            [0xb0] = 20,
        },
    }},
    [0x5f] = {{
        Name = 'LuminanceNoiseReduction',
        Condition = function(self) return num(self.VRDVersion) < 330 end,
        Notes = 'VRDVersion prior to 3.3.0',
        PrintConv = {
            [0]   = 'Off',
            [65]  = 'Low',
            [100] = 'High',
        },
    }, { -- #1
        Name = 'LuminanceNoiseReduction',
        Notes = 'VRDVersion 3.3.0 or later',
        PrintHex = 1,
        PrintConvColumns = 4,
        PrintConv = {
            [0x00] = 0,
            [0x41] = 1,
            [0x64] = 2,
            [0x6e] = 3,
            [0x78] = 4,
            [0x82] = 5,
            [0x8c] = 6,
            [0x96] = 7,
            [0xa0] = 8,
            [0xaa] = 9,
            [0xb4] = 10,
            [0xb5] = 11,
            [0xb6] = 12,
            [0xb7] = 13,
            [0xb8] = 14,
            [0xb9] = 15,
            [0xba] = 16,
            [0xbb] = 17,
            [0xbc] = 18,
            [0xbd] = 19,
            [0xbe] = 20,
        },
    }},
    [0x60] = {{
        Name = 'ChrominanceNR_TIFF_JPEG',
        Condition = function(self) return num(self.VRDVersion) < 330 end,
        Notes = 'VRDVersion prior to 3.3.0',
        PrintConv = {
            [0]   = 'Off',
            [33]  = 'Low',
            [100] = 'High',
        },
    }, { -- #1
        Name = 'ChrominanceNR_TIFF_JPEG',
        Notes = 'VRDVersion 3.3.0 or later',
        PrintHex = 1,
        PrintConvColumns = 4,
        PrintConv = {
            [0x00] = 0,
            [0x10] = 1,
            [0x21] = 2,
            [0x32] = 3,
            [0x42] = 4,
            [0x53] = 5,
            [0x64] = 6,
            [0x74] = 7,
            [0x85] = 8,
            [0x96] = 9,
            [0xa6] = 10,
            [0xa7] = 11,
            [0xa8] = 12,
            [0xa9] = 13,
            [0xaa] = 14,
            [0xab] = 15,
            [0xac] = 16,
            [0xad] = 17,
            [0xae] = 18,
            [0xaf] = 19,
            [0xb0] = 20,
        },
    }},
    -- 0x61: 1
    -- (VRD 3.0.0 edit data ends here: 196 bytes, index 0x62)
    [0x62] = noYes { Name = 'ChromaticAberrationOn' },
    [0x63] = noYes { Name = 'DistortionCorrectionOn' },
    [0x64] = noYes { Name = 'PeripheralIlluminationOn' },
    [0x65] = noYes { Name = 'ColorBlur' },
    [0x66] = {
        Name = 'ChromaticAberration',
        ValueConv = function(_self, val) return val / 0x400 end,
        ValueConvInv = function(_self, val) return int(val * 0x400 + 0.5) end,
        PrintConv = function(_self, val) return sprintf('%.0f%%', val * 100) end,
        PrintConvInv = function(_self, val) return ToFloat(val) / 100 end,
    },
    [0x67] = {
        Name = 'DistortionCorrection',
        ValueConv = function(_self, val) return val / 0x400 end,
        ValueConvInv = function(_self, val) return int(val * 0x400 + 0.5) end,
        PrintConv = function(_self, val) return sprintf('%.0f%%', val * 100) end,
        PrintConvInv = function(_self, val) return ToFloat(val) / 100 end,
    },
    [0x68] = {
        Name = 'PeripheralIllumination',
        ValueConv = function(_self, val) return val / 0x400 end,
        ValueConvInv = function(_self, val) return int(val * 0x400 + 0.5) end,
        PrintConv = function(_self, val) return sprintf('%.0f%%', val * 100) end,
        PrintConvInv = function(_self, val) return ToFloat(val) / 100 end,
    },
    [0x69] = {
        Name = 'AberrationCorrectionDistance',
        Notes = '100% = infinity',
        RawConv = function(_self, val) if num(val) == 0x7fff then return nil end return val end,
        ValueConv = function(_self, val) return 1 - val / 0x400 end,
        ValueConvInv = function(_self, val) return int((1 - val) * 0x400 + 0.5) end,
        PrintConv = function(_self, val) return sprintf('%.0f%%', val * 100) end,
        PrintConvInv = function(_self, val) return ToFloat(val) / 100 end,
    },
    [0x6a] = 'ChromaticAberrationRed',
    [0x6b] = 'ChromaticAberrationBlue',
    [0x6d] = { -- #1
        Name = 'LuminanceNR_TIFF_JPEG',
        Notes = 'val = raw / 10',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return int(val * 10 + 0.5) end,
    },
    -- (VRD 3.4.0 edit data ends here: 220 bytes, index 0x6e)
    [0x6e] = noYes { Name = 'AutoLightingOptimizerOn' },
    [0x6f] = {
        Name = 'AutoLightingOptimizer',
        PrintConv = {
            [100] = 'Low',
            [200] = 'Standard',
            [300] = 'Strong',
            [0x7fff] = 'n/a', -- #1
        },
    },
    -- 0x71: 200
    -- 0x73: 100
    -- (VRD 3.5.0 edit data ends here: 232 bytes, index 0x74)
    [0x75] = {
        Name = 'StandardRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x76] = {
        Name = 'PortraitRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x77] = {
        Name = 'LandscapeRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x78] = {
        Name = 'NeutralRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x79] = {
        Name = 'FaithfulRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x7a] = {
        Name = 'MonochromeRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x7b] = {
        Name = 'UnknownRawHighlight',
        Unknown = 1,
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x7c] = {
        Name = 'CustomRawHighlight',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x7e] = {
        Name = 'StandardRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x7f] = {
        Name = 'PortraitRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x80] = {
        Name = 'LandscapeRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x81] = {
        Name = 'NeutralRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x82] = {
        Name = 'FaithfulRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x83] = {
        Name = 'MonochromeRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x84] = {
        Name = 'UnknownRawShadow',
        Unknown = 1,
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x85] = {
        Name = 'CustomRawShadow',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
    },
    [0x8b] = { -- #2
        Name = 'AngleAdj',
        Format = 'int32s',
        ValueConv = function(_self, val) return val / 100 end,
        ValueConvInv = function(_self, val) return val * 100 end,
    },
    [0x8e] = {
        Name = 'CheckMark2',
        Format = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Clear',
            [1] = 1,
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = 5,
        },
    },
    -- (VRD 3.8.0 edit data ends here: 286 bytes, index 0x8f)
    [0x90] = {
        Name = 'UnsharpMask',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x92] = 'StandardUnsharpMaskStrength',
    [0x94] = 'StandardUnsharpMaskFineness',
    [0x96] = 'StandardUnsharpMaskThreshold',
    [0x98] = 'PortraitUnsharpMaskStrength',
    [0x9a] = 'PortraitUnsharpMaskFineness',
    [0x9c] = 'PortraitUnsharpMaskThreshold',
    [0x9e] = 'LandscapeUnsharpMaskStrength',
    [0xa0] = 'LandscapeUnsharpMaskFineness',
    [0xa2] = 'LandscapeUnsharpMaskThreshold',
    [0xa4] = 'NeutraUnsharpMaskStrength',
    [0xa6] = 'NeutralUnsharpMaskFineness',
    [0xa8] = 'NeutralUnsharpMaskThreshold',
    [0xaa] = 'FaithfulUnsharpMaskStrength',
    [0xac] = 'FaithfulUnsharpMaskFineness',
    [0xae] = 'FaithfulUnsharpMaskThreshold',
    [0xb0] = 'MonochromeUnsharpMaskStrength',
    [0xb2] = 'MonochromeUnsharpMaskFineness',
    [0xb4] = 'MonochromeUnsharpMaskThreshold',
    [0xb6] = 'CustomUnsharpMaskStrength',
    [0xb8] = 'CustomUnsharpMaskFineness',
    [0xba] = 'CustomUnsharpMaskThreshold',
    [0xbc] = 'CustomDefaultUnsharpStrength',
    [0xbe] = 'CustomDefaultUnsharpFineness',
    [0xc0] = 'CustomDefaultUnsharpThreshold',
    -- (VRD 3.9.1 edit data ends here: 392 bytes, index 0xc4)
    -- 0xc9: 3    - some RawSharpness
    -- 0xca: 4095 - some RawHighlightPoint
    -- 0xcb: 0    - some RawShadowPoint
    -- 0xcc: 4095 - some OutputHighlightPoint
    -- 0xcd: 0    - some OutputShadowPoint
    -- 0xd1: 3    - some UnsharpMaskStrength
    -- 0xd3: 7    - some UnsharpMaskFineness
    -- 0xd5: 3,4  - some UnsharpMaskThreshold
    [0xd6] = noYes { Name = 'CropCircleActive' },
    [0xd7] = 'CropCircleX',
    [0xd8] = 'CropCircleY',
    [0xd9] = 'CropCircleRadius',
    -- 0xda: 0, 1
    -- 0xdb: 100
    [0xdc] = noYes {
        Name = 'DLOOn',
        DataMember = 'DLOOn',
        RawConv = function(self, val) self.DLOOn = val; return val end,
        -- %noYes,
    },
    [0xdd] = 'DLOSetting',
    -- (VRD 3.11.0 edit data ends here: 444 bytes, index 0xde)
    [0xde] = {
        Name = 'DLOShootingDistance',
        Notes = '100% = infinity',
        RawConv = function(_self, val) if num(val) == 0x7fff then return nil end return val end,
        ValueConv = function(_self, val) return 1 - val / 0x400 end,
        ValueConvInv = function(_self, val) return int((1 - val) * 0x400 + 0.5) end,
        PrintConv = function(_self, val) return sprintf('%.0f%%', val * 100) end,
        PrintConvInv = function(_self, val) return ToFloat(val) / 100 end,
    },
    [0xdf] = {
        Name = 'DLODataLength',
        DataMember = 'DLODataLength',
        Format = 'int32u',
        Writable = 0,
        RawConv = function(self, val) self.DLODataLength = val; return val end,
    },
    [0xe0] = { -- (yes, this overlaps DLODataLength)
        Name = 'DLOInfo',
        -- - have seen DLODataLengths of 65536,64869 when DLO is Off, so must test DLOOn flag
        Condition = function(self) return truthy(self.DLOOn) end,
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.DLOInfo' },
        Hook = function(self) return num(self.DLODataLength) + 0x16 end,
    },
    [0xe1] = 'CameraRawColorTone',
    -- (VRD 3.11.2 edit data ends here: 452 bytes, index 0xe2, unless DLO is on)
    [0xe2] = 'CameraRawSaturation',
    [0xe3] = 'CameraRawContrast',
    [0xe4] = noYes { Name = 'CameraRawLinear' },
    [0xe5] = 'CameraRawSharpness',
    [0xe6] = 'CameraRawHighlightPoint',
    [0xe7] = 'CameraRawShadowPoint',
    [0xe8] = 'CameraRawOutputHighlightPoint',
    [0xe9] = 'CameraRawOutputShadowPoint',
}

-- DLO tags (ref PH)
CanonVRD.DLOInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FIRST_ENTRY = 1,
    FORMAT = 'int16s',
    GROUPS = { [2] = 'Image' },
    NOTES = 'Tags added when DLO (Digital Lens Optimizer) is on.',
    -- 0x01 - seen 3112,3140
    [0x04] = 'DLOSettingApplied',
    [0x05] = {
        Name = 'DLOVersion', -- #(NC)
        Format = 'string[10]',
    },
    [0x0a] = {
        Name = 'DLOData',
        LargeTag = 1, -- large tag, so avoid storing unnecessarily
        Notes = 'variable-length Digital Lens Optimizer data, stored in JPEG-like format',
        Format = 'undef[$$self{DLODataLength}]',
        Writable = 0,
        Binary = 1,
    },
}

-- VRD version 4 tags (ref PH)
CanonVRD.DR4 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false, -- predeclaration, see below for implementation
    WRITABLE = 1,
    PERMANENT = 1, -- (can't add/delete these individually)
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    VARS = { ID_FMT = 'hex', SORT_PROC = false }, -- (SORT_PROC: predeclaration, see below)
    NOTES = [[
        Tags written by Canon DPP version 4 in CanonVRD trailers and DR4 files. Each
        tag has three associated flag words which are stored with the directory
        entry, some of which are extracted as a separate tag, indicated in the table
        below by a decimal appended to the tag ID (.0, .1 or .2).
    ]],
    header = {
        Name = 'DR4Header',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.DR4Header' },
    },
    [0x10002] = 'Rotation', -- left/right rotation 90,180,270
    [0x10003] = 'AngleAdj', -- crop angle
    -- 0x10018 - fmt=8: 0
    -- 0x10020 - fmt=2: ''
    [0x10021] = 'CustomPictureStyle', -- (string)
    [0x10100] = { -- #forum15965
        Name = 'Rating',
        PrintConv = {
            [0] = 'Unrated',
            [1] = 1,
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = 5,
            [4294967295] = 'Rejected',
        },
    },
    [0x10101] = {
        Name = 'CheckMark',
        PrintConv = {
            [0] = 'Clear',
            [1] = 1,
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = 5,
        },
    },
    [0x10200] = {
        Name = 'WorkColorSpace',
        PrintConv = {
            [1] = 'sRGB',
            [2] = 'Adobe RGB',
            [3] = 'Wide Gamut RGB',
            [4] = 'Apple RGB',
            [5] = 'ColorMatch RGB',
        },
    },
    -- 0x10201 - fmt=9: 0
    -- 0x10f20 - fmt=9: 350
    [0x20001] = 'RawBrightnessAdj',
    [0x20101] = {
        Name = 'WhiteBalanceAdj',
        PrintConvColumns = 2,
        PrintConv = {
            [-1] = 'Manual (Click)',
            [0] = 'Auto',
            [1] = 'Daylight',
            [2] = 'Cloudy',
            [3] = 'Tungsten',
            [4] = 'Fluorescent',
            [5] = 'Flash',
            [8] = 'Shade',
            [9] = 'Kelvin',
            [255] = 'Shot Settings',
        },
    },
    [0x20102] = 'WBAdjColorTemp',
    [0x20105] = 'WBAdjMagentaGreen',
    [0x20106] = 'WBAdjBlueAmber',
    [0x20125] = {
        Name = 'WBAdjRGGBLevels',
        PrintConv = function(_self, val) val = subst(val, [[^\d+ ]], '') return val end,  -- remove first integer (14: what is this for?)
        PrintConvInv = function(_self, val) return '14 ' .. str(val) end,
    },
    [0x20200] = noYes { Name = 'GammaLinear' },
    [0x20301] = {
        Name = 'PictureStyle',
        PrintHex = 1,
        PrintConv = {
            [0x81] = 'Standard',
            [0x82] = 'Portrait',
            [0x83] = 'Landscape',
            [0x84] = 'Neutral',
            [0x85] = 'Faithful',
            [0x86] = 'Monochrome',
            [0x87] = 'Auto',
            [0x88] = 'Fine Detail',
            [0xf0] = 'Shot Settings',
            [0xff] = 'Custom',
        },
    },
    -- 0x20302 - Gamma curve data
    [0x20303] = 'ContrastAdj',
    [0x20304] = 'ColorToneAdj',
    [0x20305] = 'ColorSaturationAdj',
    [0x20306] = {
        Name = 'MonochromeToningEffect',
        PrintConv = {
            [0] = 'None',
            [1] = 'Sepia',
            [2] = 'Blue',
            [3] = 'Purple',
            [4] = 'Green',
        },
    },
    [0x20307] = {
        Name = 'MonochromeFilterEffect',
        PrintConv = {
            [0] = 'None',
            [1] = 'Yellow',
            [2] = 'Orange',
            [3] = 'Red',
            [4] = 'Green',
        },
    },
    [0x20308] = 'UnsharpMaskStrength',
    [0x20309] = 'UnsharpMaskFineness',
    [0x2030a] = 'UnsharpMaskThreshold',
    [0x2030b] = 'ShadowAdj',
    [0x2030c] = 'HighlightAdj',
    [0x20310] = {
        Name = 'SharpnessAdj',
        PrintConv = {
            [0] = 'Sharpness',
            [1] = 'Unsharp Mask',
        },
    },
   ['0x20310.0'] = noYes { Name = 'SharpnessAdjOn' },
    [0x20311] = 'SharpnessStrength',
    [0x20400] = {
        Name = 'ToneCurve',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.ToneCurve' },
    },
   ['0x20400.1'] = noYes { Name = 'ToneCurveOriginal' },
    -- 0x20401 - fmt=33 (312 bytes)
    [0x20410] = 'ToneCurveBrightness',
    [0x20411] = 'ToneCurveContrast',
    [0x20500] = {
        Name = 'AutoLightingOptimizer',
        PrintConv = {
            [0] = 'Low',
            [1] = 'Standard',
            [2] = 'Strong',
        },
    },
   ['0x20500.0'] = noYes {
        Name = 'AutoLightingOptimizerOn',
        Notes = 'ignored if gamma is linear',
        -- %noYes,
    },
    -- 0x20501 - fmt=13: 0
    -- 0x20502 - fmt=13: 0
    [0x20600] = 'LuminanceNoiseReduction',
    [0x20601] = 'ChrominanceNoiseReduction',
    -- 0x20650 - fmt=9: 0 (JPG images)
    [0x20670] = 'ColorMoireReduction',
   ['0x20670.0'] = noYes { Name = 'ColorMoireReductionOn' },
    [0x20701] = {
        Name = 'ShootingDistance',
        Notes = '100% = infinity',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
        PrintConv = function(_self, val) return sprintf('%.0f%%', val * 100) end,
        PrintConvInv = function(_self, val) return ToFloat(val) / 100 end,
    },
    [0x20702] = {
        Name = 'PeripheralIllumination',
        PrintConv = function(_self, val) return sprintf('%g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
   ['0x20702.0'] = noYes { Name = 'PeripheralIlluminationOn' },
    [0x20703] = {
        Name = 'ChromaticAberration',
        PrintConv = function(_self, val) return sprintf('%g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
   ['0x20703.0'] = noYes { Name = 'ChromaticAberrationOn' },
    [0x20704] = noYes { Name = 'ColorBlurOn' },
    [0x20705] = {
        Name = 'DistortionCorrection',
        PrintConv = function(_self, val) return sprintf('%g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
   ['0x20705.0'] = noYes { Name = 'DistortionCorrectionOn' },
    [0x20706] = 'DLOSetting',
   ['0x20706.0'] = noYes { Name = 'DLOOn' },
    [0x20707] = {
        Name = 'ChromaticAberrationRed',
        PrintConv = function(_self, val) return sprintf('%g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x20708] = {
        Name = 'ChromaticAberrationBlue',
        PrintConv = function(_self, val) return sprintf('%g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x20709] = {
        Name = 'DistortionEffect',
        PrintConv = {
            [0] = 'Shot Settings',
            [1] = 'Emphasize Linearity',
            [2] = 'Emphasize Distance',
            [3] = 'Emphasize Periphery',
            [4] = 'Emphasize Center',
        },
    },
    [0x2070b] = noYes { Name = 'DiffractionCorrectionOn' },
    -- 0x20800 - fmt=1: 0
    -- 0x20801 - fmt=1: 0
    [0x20900] = 'ColorHue',
    [0x20901] = 'SaturationAdj',
    [0x20910] = 'RedHSL',
    [0x20911] = 'OrangeHSL',
    [0x20912] = 'YellowHSL',
    [0x20913] = 'GreenHSL',
    [0x20914] = 'AquaHSL',
    [0x20915] = 'BlueHSL',
    [0x20916] = 'PurpleHSL',
    [0x20917] = 'MagentaHSL',
    [0x20a00] = {
        Name = 'GammaInfo',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.GammaInfo' },
    },
    -- 0x20a01 - Auto picture style settings
    -- 0x20a02 - Standard picture style settings
    -- 0x20a03 - Portrait picture style settings
    -- 0x20a04 - Landscape picture style settings
    -- 0x20a05 - Neutral picture style settings
    -- 0x20a06 - Faithful picture style settings
    -- 0x20a07 - Monochrome picture style settings
    -- 0x20a08 - (unknown picture style settings)
    -- 0x20a09 - Custom picture style settings
    -- 0x20a20 - Fine Detail picture style settings
    [0x20b10] = 'DPRAWMicroadjustBackFront', -- #forum15660
    [0x20b12] = 'DPRAWMicroadjustStrength', -- #forum15660
    [0x20b20] = 'DPRAWBokehShift', -- #forum15660
    [0x20b21] = 'DPRAWBokehShiftArea', -- #PH
    [0x20b30] = 'DPRAWGhostingReductionArea', -- #forum15660
    [0x30101] = {
        Name = 'CropAspectRatio',
        PrintConv = {
            [0] = 'Free',
            [1] = 'Custom',
            [2] = '1:1',
            [3] = '3:2',
            [4] = '2:3',
            [5] = '4:3',
            [6] = '3:4',
            [7] = '5:4',
            [8] = '4:5',
            [9] = '16:9',
            [10] = '9:16',
        },
    },
    [0x30102] = 'CropAspectRatioCustom',
    -- 0x30103 - fmt=33: "0 0 8"
    [0xf0100] = {
        Name = 'CropInfo',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.CropInfo' },
    },
    [0xf0500] = {
        Name = 'CustomPictureStyleData',
        Binary = 1,
    },
    [0xf0510] = {
        Name = 'StampInfo',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.StampInfo' },
    },
    [0xf0511] = {
        Name = 'DustInfo',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.DustInfo' },
    },
    [0xf0512] = 'LensFocalLength',
    -- 0xf0521 - DLO data
    -- 0xf0520 - DLO data
    -- 0xf0530 - created when dust delete data applied (4 bytes, all zero)
    -- 0xf0561 - 1932 bytes, related to Partial Adjustment Tool Palette (ref forum15660)
    -- 0xf0562 - 1596 bytes, related to Partial Adjustment Tool Palette (ref forum15660)
    -- 0xf0566 - 1520 bytes, related to Partial Adjustment Tool Palette (ref forum15660)
    -- 0xf0600 - fmt=253 (2308 bytes, JPG images)
    -- 0xf0601 - fmt=253 (2308 bytes, JPG images)
    -- 0x1ff52c - values: 129,130,132 (related to custom picture style somehow)
    -- to do:
    -- - find 8-15mm CR2 sample and decode linear distortion effect fine-tune
}

-- Version 4 header information (ref PH)
CanonVRD.DR4Header = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    FORMAT = 'int32u',
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    -- 0 - value: 'IIII' (presumably byte order)
    -- 1 - value: 0x00040004 (currently use this for magic number)
    -- 2 - value: 6
    [3] = {
        Name = 'DR4CameraModel',
        Format = 'int32u',
        PrintHex = 1,
        SeparateTable = 'Canon CanonModelID',
        PrintConv = Canon.canonModelID,
    },
    -- 4 - value: 3
    -- 5 - value: 4
    -- 6 - value: 5
    -- 7 - DR4 directory entry count
}

-- Version 4 RGB tone curve information (ref PH)
CanonVRD.ToneCurve = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    FORMAT = 'int32u',
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    [0x00] = {
        Name = 'ToneCurveColorSpace',
        PrintConv = {
            [0] = 'RGB',
            [1] = 'Luminance',
        },
    },
    [0x01] = {
        Name = 'ToneCurveShape',
        PrintConv = {
            [0] = 'Curve',
            [1] = 'Straight',
        },
    },
    [0x03] = { Name = 'ToneCurveInputRange',  Format = 'int32u[2]', Notes = '255 max' },
    [0x05] = { Name = 'ToneCurveOutputRange', Format = 'int32u[2]', Notes = '255 max' },
    [0x07] = {
        Name = 'RGBCurvePoints',
        Format = 'int32u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    [0x0a] = 'ToneCurveX',
    [0x0b] = 'ToneCurveY',
    [0x2d] = {
        Name = 'RedCurvePoints',
        Format = 'int32u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    [0x53] = {
        Name = 'GreenCurvePoints',
        Format = 'int32u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
    [0x79] = {
        Name = 'BlueCurvePoints',
        Format = 'int32u[21]',
        PrintConv = function(_self, val) return CanonVRD.ToneCurvePrint(val) end,
        PrintConvInv = function(_self, val) return CanonVRD.ToneCurvePrintInv(val) end,
    },
}

-- Version 4 gamma curve information (ref PH)
CanonVRD.GammaInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    FORMAT = 'double',
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    [0x02] = 'GammaContrast',
    [0x03] = 'GammaColorTone',
    [0x04] = 'GammaSaturation',
    [0x05] = 'GammaUnsharpMaskStrength',
    [0x06] = 'GammaUnsharpMaskFineness',
    [0x07] = 'GammaUnsharpMaskThreshold',
    [0x08] = 'GammaSharpnessStrength',
    [0x09] = 'GammaShadow',
    [0x0a] = 'GammaHighlight',
    -- 0x0b-0x10 are the same as first 6 doubles of tag DR4_0x20302
    -- 0x0b - value: 14
    [0x0c] = {
        Name = 'GammaBlackPoint',
        ValueConv = function(_self, val)
            if num(val) <= 0 then return 0 end
            val = log(val / 4.6875) / log(2) + 1
            if math.abs(val) > 1e-10 then return val end return 0
        end,
        ValueConvInv = function(_self, val) if truthy(val) then return math.exp((val - 1) * log(2)) * 4.6876 end return 0 end,
        PrintConv = function(_self, val) return sprintf('%+.3f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0d] = {
        Name = 'GammaWhitePoint',
        ValueConv = function(_self, val)
            if num(val) <= 0 then return val end
            val = log(val / 4.6875) / log(2) - 11.77109325169954
            if math.abs(val) > 1e-10 then return val end return 0
        end,
        ValueConvInv = function(_self, val) if truthy(val) then return math.exp((val + 11.77109325169954) * log(2)) * 4.6875 end return 0 end,
        PrintConv = function(_self, val) return sprintf('%+.3f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0e] = {
        Name = 'GammaMidPoint',
        ValueConv = function(_self, val)
            if num(val) <= 0 then return val end
            val = log(val / 4.6875) / log(2) - 8
            if math.abs(val) > 1e-10 then return val end return 0
        end,
        ValueConvInv = function(_self, val) if truthy(val) then return math.exp((val + 8) * log(2)) * 4.6876 end return 0 end,
        PrintConv = function(_self, val) return sprintf('%+.3f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0f] = { Name = 'GammaCurveOutputRange', Format = 'double[2]', Notes = '16383 max' },
}

-- Version 4 crop information (ref PH)
CanonVRD.CropInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    FORMAT = 'int32s',
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    [0] = noYes { Name = 'CropActive' },
    [1] = 'CropRotatedOriginalWidth',
    [2] = 'CropRotatedOriginalHeight',
    [3] = 'CropX',
    [4] = 'CropY',
    [5] = 'CropWidth',
    [6] = 'CropHeight',
    [7] = 'CropRotation',
    [8] = {
        Name = 'CropAngle',
        Format = 'double',
        PrintConv = function(_self, val) return sprintf('%.7g', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [10] = 'CropOriginalWidth',
    [11] = 'CropOriginalHeight',
    -- 12 double - value: 100
}

-- DR4 Stamp Tool tags (ref PH)
CanonVRD.StampInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    [0x02] = 'StampToolCount',
}

-- DR4 dust delete information (ref PH)
CanonVRD.DustInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'CanonDR4', [2] = 'Image' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    [0x02] = noYes { Name = 'DustDeleteApplied' },
}

--------------------------------------------------------------------------------
-- sort DR4 tag ID's for the documentation

--------------------------------------------------------------------------------
-- sort DR4 tag ID's for the documentation
function CanonVRD.SortDR4(a, b)
    local aHex, aDec, bHex, bDec
    local ok, h, d = isMatch(a, [[^(0x[0-9a-f]+)?\.?(\d*?)$]])
    if ok then aHex, aDec = h, d end
    ok, h, d = isMatch(b, [[^(0x[0-9a-f]+)?\.?(\d*?)$]])
    if ok then bHex, bDec = h, d end
    local function cmp(x, y) return x < y and -1 or (x > y and 1 or 0) end
    if truthy(aHex) then
        if bDec == nil then return 1 end  -- $b is 'header';
        if truthy(bHex) then
            local c = cmp(hex(aHex), hex(bHex))
            if c ~= 0 then return c end
            return cmp(num(aDec), num(bDec))
        end
        local c = cmp(hex(aHex), num(bDec))
        if c ~= 0 then return c end
        return 1
    elseif truthy(bHex) then
        if aDec == nil then return -1 end
        local c = cmp(num(aDec), hex(bHex))
        if c ~= 0 then return c end
        return -1
    else
        if bDec == nil then return 1 end
        if aDec == nil then return -1 end
        return cmp(num(aDec), num(bDec))
    end
end

-- Print conversion for tone curve (upstream CanonVRD::ToneCurvePrint)
function CanonVRD.ToneCurvePrint(val)
    local vals = {}
    for w in str(val):gmatch('[^ \t\n\r\f\v]+') do vals[#vals + 1] = w end
    if #vals ~= 21 then return str(val) end
    local n = tonumber(table.remove(vals, 1))
    if not (n and n >= 2 and n <= 10) then return str(val) end
    local out = {}
    while n > 0 do
        n = n - 1
        out[#out + 1] = '(' .. table.remove(vals, 1) .. ',' .. table.remove(vals, 1) .. ')'
    end
    return table.concat(out, ' ')
end

--------------------------------------------------------------------------------
-- Inverse print conversion for tone curve
function CanonVRD.ToneCurvePrintInv(val)
    local vals = findAll(val, [[\((\d+),(\d+)\)]])
    if not (#vals >= 4 and #vals <= 20 and (#vals & 0x01) == 0) then return nil end
    table.insert(vals, 1, #vals // 2)
    while #vals < 21 do vals[#vals + 1] = 0 end
    return join(' ', vals)
end

--------------------------------------------------------------------------------
-- Read/write VRD edit data (read subset)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function CanonVRD.ProcessEditData(et, dirInfo, tagTablePtr)
    if et == nil then return 1 end -- allow dummy access
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local dataPos = dirInfo.DataPos
    local outfile = dirInfo.OutFile
    local dirLen = dirInfo.DirLen
    local verbose = et:Options('Verbose')
    local oldChanged = et.CHANGED or 0
    local err

    if not outfile then et:VerboseDir('VRD Edit Data', 0, dirLen) end

    if outfile then
        -- make a copy for editing in place
        dataPt = substr(dataPt, pos, dirLen)
        dirInfo.DataPt = dataPt
        dataPos = dataPos + pos
        pos = 0
        dirInfo.DirStart = 0
    end
    local dirEnd = pos + dirLen

    -- loop through all records in the edit data
    local recNum = 0
    while true do
        local recLen
        if pos + 4 > dirEnd then
            if pos == dirEnd then break end -- all done if we arrived at end
            recLen = 0 -- just reset record size (will exit loop on test below)
        else
            recLen = et.Get32u(dataPt, pos)
            -- (DR4 has a null terminator)
            if recLen == 0 and pos + 4 == dirEnd then break end
        end
        pos = pos + 4 -- move to start of record
        if pos + recLen > dirEnd then
            et:Warn('Possibly corrupt CanonVRD Edit record')
            err = 1
            break
        end
        local saveRecLen = recLen
        if verbose and verbose > 1 and not outfile then
            et:VPrint(0, et.INDENT .. sprintf('CanonVRD Edit record (%d bytes at offset 0x%x)\n',
                recLen, pos + dataPos))
            if recNum > 0 then
                et:VerboseDump(dataPt, { Len = recLen, Start = pos, Addr = pos + dataPos })
            end
        end
        recNum = recNum + 1

        -- our edit information is the 0th record, so don't process the others
        if recNum == 1 then
            -- process VRD edit information
            local subdirInfo = {
                DataPt   = dataPt,
                DataPos  = dataPos,
                DirStart = pos,
                DirLen   = recLen,
                OutFile  = outfile,
            }
            local subStart = 0
            local index = 0
            -- loop through various sections of the VRD edit data
            while true do
                local tagInfo = tagTablePtr[index]
                if not tagInfo then break end
                local subLen
                local maxLen = recLen - subStart
                if tagInfo.Size and tagInfo.Size ~= 0 then
                    subLen = tagInfo.Size
                elseif tagInfo.Size ~= nil and tagInfo.Size ~= false then -- (defined; false is undef)
                    -- get size from int32u at subStart
                    if subStart + 4 > recLen then break end
                    subLen = et.Get32u(dataPt, subStart + pos)
                    subStart = subStart + 4 -- skip the length word
                else
                    subLen = maxLen
                end
                if subLen > maxLen then subLen = maxLen end
                if subLen ~= 0 then
                    local subTable = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                    local subName = tagInfo.Name
                    subdirInfo.DataPt = dataPt
                    subdirInfo.DirStart = subStart + pos
                    subdirInfo.DirLen = subLen
                    subdirInfo.DirName = subName
                    if outfile then
                        -- rewrite this section of the VRD edit information
                        if truthy(verbose) then et:VPrint(0, '  Rewriting Canon ' .. subName .. '\n') end
                        local newVal = Writer.WriteDirectory(et, subdirInfo, subTable)
                        if type(newVal) == 'string' and #newVal > 0 then
                            local sizeDiff = #newVal - subLen
                            dataPt = spliceSub(dataPt, pos + subStart, subLen, newVal)
                            if sizeDiff ~= 0 then
                                subLen = #newVal
                                recLen = recLen + sizeDiff
                                dirEnd = dirEnd + sizeDiff
                                dirLen = dirLen + sizeDiff
                            end
                        end
                    else
                        et:VPrint(0, et.INDENT .. subName .. ' (SubDirectory) -->\n')
                        et:VerboseDump(dataPt, {
                            Start = pos + subStart,
                            Addr  = dataPos + pos + subStart,
                            Len   = subLen,
                        })
                        -- extract tags from this section of the VRD edit information
                        et:ProcessDirectory(subdirInfo, subTable)
                    end
                end
                -- next section starts at the end of this one
                subStart = subStart + subLen
                index = index + 1
            end
        end
        if outfile and saveRecLen ~= recLen then
            -- update record length if necessary
            dataPt = spliceSub(dataPt, pos - 4, 4, ExifTool.Put32u(recLen))
        end
        pos = pos + recLen
    end
    if outfile then
        if oldChanged == (et.CHANGED or 0) then return nil end
        return substr(dataPt, dirInfo.DirStart, dirLen)
    end
    return err and 0 or 1
end

--------------------------------------------------------------------------------
-- Process VRD IHL data
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function CanonVRD.ProcessIHL(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local pos = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    local dirEnd = pos + dirLen

    et:VerboseDir('VRD IHL', 0, dirLen)

    SetByteOrder('II') -- (make up your mind, Canon!)
    while pos + 48 <= dirEnd do
        local hdr = substr(dataPt, pos, 48)
        if not isMatch(hdr, [[^IHL Created Optional Item Data\0\0]]) then
            et:Warn('Possibly corrupted VRD IHL data')
            break
        end
        local tag  = Get32u(dataPt, pos + 36)
        local size = Get32u(dataPt, pos + 40) -- size of data in IHL record
        local nxt  = Get32u(dataPt, pos + 44) -- size of complete IHL record
        if size > nxt or pos + 48 + nxt > dirEnd then
            et:Warn(sprintf('Bad size for VRD IHL tag 0x%.4x', tag))
            break
        end
        pos = pos + 48
        et:HandleTag(tagTablePtr, tag, substr(dataPt, pos, size), {
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = pos,
            Size    = size,
        })
        pos = pos + nxt
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process VRD IHL EXIF data
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function CanonVRD.ProcessIHLExif(et, dirInfo, tagTablePtr)
    et.DOC_NUM = 1
    -- the IHL-edited maker notes may look messed up, but the offsets should be OK
    local oldFix = et:Options('FixBase', 0)
    local rtnVal = et:ProcessTIFF(dirInfo, tagTablePtr)
    et:Options('FixBase', oldFix)
    et.DOC_NUM = nil
    return rtnVal
end

--------------------------------------------------------------------------------
-- Wrap DR4 data with the VRD header/footer and edit record (upstream WrapDR4)
-- Inputs: 0) DR4 data block
-- Returns: VRD data block
--------------------------------------------------------------------------------
function CanonVRD.WrapDR4(val)
    local n = #val
    local oldOrder = ExifTool.GetByteOrder()
    ExifTool.SetByteOrder('MM')
    val = blankHeader .. '\255\255\0\247' .. ExifTool.Put32u(n + 8) .. ExifTool.Put32u(n) ..
          val .. '\0\0\0\0' .. blankFooter
    -- update the new VRD length in the header/footer
    -- (extra 16 bytes for the edit record wrapper)
    local len = ExifTool.Put32u(n + 16)
    val = spliceSub(val, 0x18, 4, len)
    val = spliceSub(val, #val - 0x2c, 4, len)
    ExifTool.SetByteOrder(oldOrder)
    return val
end

-- Read/write Canon DR4 information (upstream ProcessDR4; read subset)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) optional tag table ref
-- Returns: 1 on success, 0 if this wasn't a valid DR4 file
function CanonVRD.ProcessDR4(et, dirInfo, tagTablePtr)
    if not et then return 1 end -- allow dummy access
    local dataPt = dirInfo.DataPt
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local isWriting = outfile or dirInfo.IsWriting
    local dataPos = dirInfo.DataPos or 0
    local pos
    local dirLen
    local numEntries
    local newTags
    local err

    -- write CanonDR4 as a block if specified
    if isWriting then
        local newVal, nvHash = et:GetNewValue('CanonDR4')
        if newVal then
            et:VPrint(0, '  Writing CanonDR4 as a block\n')
            et.DidCanonVRD = 1 -- set flag so we don't add this twice
            et.CHANGED = (et.CHANGED or 0) + 1
            if outfile then
                Write(outfile, newVal)
                return 1
            end
            return newVal
        elseif not dataPt and (nvHash or Writer.IsGroupDeleted(et, 'CanonVRD')) then
            et:Error("Can't delete all CanonDR4 information from a DR4 file")
            return 1
        end
    end
    if dataPt then
        pos = dirInfo.DirStart or 0
        dirLen = dirInfo.DirLen or (#dataPt - pos)
    else
        -- load DR4 file into memory
        local n, buff = raf:Read(8)
        -- (upstream: `$buff =~ /^IIII[\x04\x05]\0\x04\0/`)
        if n ~= 8 or buff:sub(1, 4) ~= 'IIII' or
            (buff:byte(5) ~= 0x04 and buff:byte(5) ~= 0x05) or
            buff:sub(6, 8) ~= '\0\4\0' then return 0 end
        et:SetFileType()
        if not raf:Seek(0, 2) then return 0 end
        dirLen = raf:Tell()
        if not raf:Seek(0, 0) then return 0 end
        local n2, buf3 = raf:Read(dirLen)
        if n2 ~= dirLen then
            et:Warn('Error reading DR4 file')
            return 1
        end
        tagTablePtr = tagTablePtr or et:GetTagTable('lexiftool.CanonVRD.DR4')
        dataPt = buf3
        pos = 0
    end
    local dirEnd = pos + dirLen

    -- version 4 header is 32 bytes (int32u[8])
    if dirLen < 32 then
        err = 1
    else
        ExifTool.SetByteOrder(substr(dataPt, pos, 2))
        -- process the DR4 header
        local hdrInfo = {
            DataPt = dataPt,
            DirStart = pos,
            DirLen = 32,
            DirName = 'DR4Header',
        }
        local hdrTable = et:GetTagTable('lexiftool.CanonVRD.DR4Header')
        if outfile then
            local hdr = Writer.WriteDirectory(et, hdrInfo, hdrTable)
            if type(hdr) == 'string' and #hdr == 32 then
                dataPt = spliceSub(dataPt, pos, 32, hdr)
            end
        else
            et:ProcessDirectory(hdrInfo, hdrTable)
        end
        -- number of entries in the DR4 directory
        numEntries = ExifTool.Get32u(dataPt, pos + 28)
        if dirLen < 36 + 28 * numEntries then err = 1 end
    end
    if err then
        et:Warn('Invalid DR4 directory')
        -- (`outfile and nil or 0` would always yield 0 in Lua)
        if outfile then return nil end
        return 0
    end

    tagTablePtr = tagTablePtr or et:GetTagTable('lexiftool.CanonVRD.DR4')
    if outfile then newTags = Writer.GetNewTagInfoHash(et, tagTablePtr) end

    local index = 0
    while index < numEntries do
        local entry = pos + 36 + 28 * index
        if entry + 28 > dirEnd then break end
        local tag = ExifTool.Get32u(dataPt, entry)
        local fmt = ExifTool.Get32u(dataPt, entry + 4)
        local flg = {
            ExifTool.Get32u(dataPt, entry + 8),
            ExifTool.Get32u(dataPt, entry + 12),
            ExifTool.Get32u(dataPt, entry + 16),
        }
        local off = ExifTool.Get32u(dataPt, entry + 20) + pos
        local len = ExifTool.Get32u(dataPt, entry + 24)
        index = index + 1
        if off + len >= dirEnd then goto continue end
        local format = vrdFormat[fmt]
        local val
        if not format then
            val = substr(dataPt, off, len):gsub('.', function(c) return string.format('%02x', c:byte()) end)
            format = 'undef'
        else
            -- (upstream: `$val = ReadValue($dataPt, $off, $format, undef,
            --  $len)` for every known format -- the value must be decoded
            --  here, not left for HandleTag's generic read, which has no
            --  per-tag Format to use)
            val = ExifTool.ReadValue(dataPt, off, format, nil, len)
            if format == 'double' and len == 8 and math.abs(val) < 1e-100 then
                val = 0 -- avoid teeny weeny values
            end
        end
        if isWriting then
            -- write (binary data) subdirectory if it exists
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if tagInfo and tagInfo.SubDirectory then
                local subdirInfo = {
                    DataPt   = dataPt,
                    DirStart = off,
                    DirLen   = len,
                    DirName  = tagInfo.Name,
                }
                local subTablePtr = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                local saveChanged = et.CHANGED or 0
                local dat = Writer.WriteDirectory(et, subdirInfo, subTablePtr)
                if type(dat) == 'string' and #dat == len then
                    dataPt = spliceSub(dataPt, off, len, dat)
                else
                    et.CHANGED = saveChanged -- didn't change anything after all
                end
            else
                -- loop through main tag and flags (don't yet consider flag 2)
                for i = -1, 1 do
                    local ti = newTags and newTags[i >= 0 and sprintf('0x%x.%d', tag, i) or tag]
                    if ti then
                        if i >= 0 then
                            off = entry + 8 + 4 * i
                            format = 'int32u'
                            len = 4
                            val = nil
                        end
                        if val == nil then
                            val = ExifTool.ReadValue(dataPt, off, format, nil, len)
                        end
                        local newVal, nvHash = et:GetNewValue(ti.Name)
                        if ExifTool.perlTruthy(Writer.IsOverwriting(et, nvHash, val))
                                and newVal ~= nil then
                            local count = len // ExifTool.FormatSize(format)
                            local bytes = Writer.WriteValue(newVal, format, count)
                            if bytes ~= nil then
                                dataPt = spliceSub(dataPt, off, #bytes, bytes)
                                et:VerboseValue('- CanonVRD:' .. ti.Name, val)
                                et:VerboseValue('+ CanonVRD:' .. ti.Name, newVal)
                                et.CHANGED = (et.CHANGED or 0) + 1
                            end
                        end
                    end
                end
            end
            goto continue
        end
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            DataPos = dataPos,
            Start = off,
            Size = len,
            Index = index - 1,
            Format = format,
        })
        for i = 0, 2 do
            local flagID = sprintf('0x%x.%d', tag, i)
            if tagTablePtr[flagID] then
                et:HandleTag(tagTablePtr, flagID, flg[i + 1])
            end
        end
        ::continue::
    end
    if not isWriting then return 1 end
    if not raf then return substr(dataPt, pos, dirLen) end
    Write(outfile, substr(dataPt, pos, dirLen))
    return 1
end

--------------------------------------------------------------------------------
-- Read/write Canon VRD file (upstream ProcessVRD)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 if this was a Canon VRD file, 0 otherwise, -1 on write error
--------------------------------------------------------------------------------
function CanonVRD.ProcessVRD(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local num, buff = raf:Read(0x1c) -- luacheck: ignore 431 (upstream's $num)

    -- initialize write directories if necessary
    if outfile then Writer.InitWriteDirs(et, vrdMap, 'XMP') end

    if num == 0 and outfile then
        -- create new VRD file from scratch
        local newVal = et:GetNewValue('CanonVRD')
        if newVal then
            et:VPrint(0, '  Writing CanonVRD as a block\n')
            Write(outfile, newVal)
            et.DidCanonVRD = 1
            et.CHANGED = (et.CHANGED or 0) + 1
        elseif et.ADD_DIRS and et.ADD_DIRS.CanonVRD ~= nil then
            -- allow VRD to be created from individual tags
            local newVal_ = carray.new('char')   -- (upstream's inner `my $newVal`)
            if CanonVRD.ProcessCanonVRD(et, { OutFile = { value = newVal_ } }) > 0 then
                if not Write(dirInfo.OutFile, newVal_) then return -1 end
                et.CHANGED = (et.CHANGED or 0) + 1
                return 1
            end
            et:Error('No CanonVRD information to write')
        else
            et:Error('No CanonVRD information to write')
        end
    else
        if num ~= 0x1c then return 0 end
        if buff:sub(1, 20) ~= 'CANON OPTIONAL DATA\0' then return 0 end
        et:SetFileType()
        dirInfo.DirName = 'CanonVRD' -- set directory name for verbose output
        local result = CanonVRD.ProcessCanonVRD(et, dirInfo)
        if result < 0 then return result end
        if result == 0 then et:Warn('Format error in VRD file') end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Write VRD data record as a block (upstream WriteCanonVRD)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: VRD data block (may be empty if no VRD data)
-- Notes: Increments ExifTool CHANGED flag if changed
--------------------------------------------------------------------------------
function CanonVRD.WriteCanonVRD(et, _dirInfo, _tagTablePtr)
    if et == nil then return 1 end -- allow dummy access
    local val, nvHash = et:GetNewValue('CanonVRD')
    if val == nil then val = '' end
    if not ExifTool.perlTruthy(Writer.IsOverwriting(et, nvHash, val)) then return nil end
    et.CHANGED = (et.CHANGED or 0) + 1
    return val
end

--------------------------------------------------------------------------------
-- Write DR4-type CanonVRD edit record
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: VRD data block (may be empty if deleted, of undef on error)
function CanonVRD.WriteCanonDR4(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access
    local val, nvHash = et:GetNewValue('CanonDR4')
    if val ~= nil then
        if not truthy(Writer.IsOverwriting(et, nvHash, val)) then return nil end
        et:VPrint(0, '  Writing CanonDR4 as a block\n')
        et.CHANGED = (et.CHANGED or 0) + 1
        return CanonVRD.WrapDR4(val)
    end
    local buff = carray.new('char')
    dirInfo.OutFile = { value = buff }
    if CanonVRD.ProcessCanonVRD(et, dirInfo, tagTablePtr) > 0 then return buff:tostring() end
    return nil
end

--------------------------------------------------------------------------------
-- Read/write CanonVRD information in a file (read subset)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this file didn't contain CanonVRD information
-- - updates DataPos to point to start of CanonVRD information
-- - updates DirLen to trailer length
--------------------------------------------------------------------------------
function CanonVRD.ProcessCanonVRD(et, dirInfo, _tagTablePtr)
    local raf = dirInfo.RAF
    local offset = dirInfo.Offset or 0
    local outfile = dirInfo.OutFile
    local dataPt = dirInfo.DataPt
    local verbose = et:Options('Verbose')
    local created, err, fromFile
    local didDir = {}

    -- The CanonVRD trailer has a 0x1c-byte header and a 0x40-byte footer,
    -- each beginning with "CANON OPTIONAL DATA\0" and containing an int32u
    -- giving the size of the contained data (at byte 0x18 and 0x14 respectively)

    if raf then
        fromFile = 1
    else
        if not dataPt then
            if not outfile then return 1 end
            -- create blank VRD data from scratch
            dataPt = blankHeader .. blankFooter
            if truthy(verbose) then et:VPrint(0, '  Creating CanonVRD trailer\n') end
            created = 1
        end
        raf = RandomAccess.new(dataPt)
    end

    -- read and validate the footer
    if not raf:Seek(-0x40 - offset, 2) then return 0 end
    local nb, footer = raf:Read(0x40)
    if nb ~= 0x40 then return 0 end
    if footer:sub(1, 20) ~= 'CANON OPTIONAL DATA\0' then return 0 end
    local dirLen = perl.unpack('N', footer:sub(21, 24)) + 0x5c -- size including header+footer

    -- read and validate the header
    local headerOK = false
    if dirLen < 0x80000000 and raf:Seek(-dirLen, 1) then
        local nh, hdr = raf:Read(0x1c)
        if nh == 0x1c and hdr:sub(1, 20) == 'CANON OPTIONAL DATA\0' and raf:Seek(-0x1c, 1) then
            headerOK = true
        end
    end
    if not headerOK then
        et:Warn('Bad CanonVRD trailer')
        return 0
    end

    -- set variables returned in dirInfo hash
    dirInfo.DataPos = raf:Tell()
    dirInfo.DirLen = dirLen

    if fromFile or dirInfo.DirStart then
        -- read VRD data into memory
        local nd, buff = raf:Read(dirLen)
        if nd ~= dirLen then
            et:Warn('Error reading CanonVRD data')
            return 0
        end
        dataPt = buff
    end
    local vrdType = 'VRD'

    if outfile then
        if truthy(verbose) and not created then et:VPrint(0, '  Rewriting CanonVRD trailer\n') end
        -- exit quickly if writing and no CanonVRD tags are being edited
        if not (et.EDIT_DIRS and et.EDIT_DIRS.CanonVRD ~= nil) then
            if truthy(verbose) then et:VPrint(0, (et.INDENT or '') .. '  [nothing changed in CanonVRD]\n') end
            if Write(outfile, dataPt) then return 1 end
            return -1
        end
        -- delete CanonVRD information if specified
        local doDel = Writer.IsGroupDeleted(et, 'CanonVRD')
        if not doDel then
            if Writer.IsGroupDeleted(et, 'Trailer') and et.FILE_TYPE ~= 'VRD' then doDel = true end
            if not doDel then
                -- also delete if writing as a block (will get added back again later)
                local isVer4 = substr(dataPt, 28, 4) == '\255\255\0\247'
                if et:IsNewValueSet('CanonVRD') and not isVer4 then doDel = true end
                if et:IsNewValueSet('CanonDR4') and not doDel and isVer4 then doDel = true end
            end
        end
        if doDel then
            if et.FILE_TYPE == 'VRD' then
                local newVal = et:GetNewValue('CanonVRD')
                if newVal then
                    if truthy(verbose) then et:VPrint(0, '  Writing CanonVRD as a block\n') end
                    if not Write(outfile, newVal) then return -1 end
                    et.DidCanonVRD = 1
                    et.CHANGED = (et.CHANGED or 0) + 1
                else
                    et:Error("Can't delete all CanonVRD information from a VRD file")
                end
            else
                if truthy(verbose) then et:VPrint(0, '  Deleting CanonVRD trailer\n') end
                et.CHANGED = (et.CHANGED or 0) + 1
            end
            return 1
        end
        -- write now and return if CanonVRD was set as a block
        local val = et:GetNewValue('CanonVRD')
        if not val then
            val = et:GetNewValue('CanonDR4')
            if val then vrdType = 'DR4' end
        end
        if val then
            if truthy(verbose) then et:VPrint(0, '  Writing Canon' .. vrdType .. ' as a block\n') end
            -- must wrap DR4 data with the VRD header/footer and edit record
            if vrdType == 'DR4' then val = CanonVRD.WrapDR4(val) end
            if not Write(outfile, val) then return -1 end
            et.DidCanonVRD = 1
            et.CHANGED = (et.CHANGED or 0) + 1
            return 1
        end
    elseif ((et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0) or et.HTML_DUMP) and dirInfo.RAF then
        et:DumpTrailer(dirInfo)
    end

    local tagTablePtr = et:GetTagTable('lexiftool.CanonVRD.Main')

    -- validate VRD trailer and get position and length of edit record
    et.SetByteOrder('MM') -- VRD header/footer is big-endian
    local pos = 0x1c      -- start at end of header

    -- loop through the VRD blocks
    while true do
        local end_ = dirLen - 0x40 -- end of last VRD block (and start of footer)
        local blockType
        local blockLen
        if pos + 8 > end_ then
            if pos == end_ then break end
            blockLen = end_ -- mark as invalid
        else
            blockType = et.Get32u(dataPt, pos)
            blockLen = et.Get32u(dataPt, pos + 4)
        end
        pos = pos + 8 -- move to start of block
        if pos + blockLen > end_ then
            et:Warn('Possibly corrupt CanonVRD block')
            break
        end
        if et.OPTIONS.Verbose and et.OPTIONS.Verbose > 1 and not outfile then
            et:VPrint(0, sprintf('  CanonVRD block 0x%.8x (%d bytes at offset 0x%x)\n',
                blockType, blockLen, pos + (dirInfo.DataPos or 0)))
            et:VerboseDump(dataPt, { Len = blockLen, Start = pos, Addr = pos + (dirInfo.DataPos or 0) })
        end
        if blockType == 0xffff00f7 then vrdType = 'DR4' end
        local tagInfo = tagTablePtr[blockType]
        local skipBlock = false
        if not tagInfo then
            local unknown = et.OPTIONS.Unknown
            if not truthy(unknown) then
                skipBlock = true
            else
                local name = sprintf('CanonVRD_0x%.8x', blockType)
                local desc = name:gsub('_', ' ')
                tagInfo = {
                    Name        = name,
                    Description = desc,
                    Binary      = 1,
                }
                et:AddTagToTable(tagTablePtr, blockType, tagInfo)
            end
        end
        if not skipBlock then
            if tagInfo.SubDirectory then
                local subTablePtr = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                local subdirInfo = {
                    DataPt   = dataPt,
                    DataLen  = #dataPt,
                    DataPos  = dirInfo.DataPos,
                    DirStart = pos,
                    DirLen   = blockLen,
                    DirName  = tagInfo.Name,
                    Parent   = 'CanonVRD',
                    OutFile  = outfile,
                }
                if outfile then
                    -- set flag indicating we did this directory
                    didDir[tagInfo.Name] = 1
                    local dat
                    if et:IsNewValueSet(tagInfo.Name) then
                        -- write as a block
                        et:VPrint(0, 'Writing ' .. tagInfo.Name .. ' as a block\n')
                        dat = et:GetNewValue(tagInfo.Name) or ''
                        et.CHANGED = (et.CHANGED or 0) + 1
                    else
                        dat = Writer.WriteDirectory(et, subdirInfo, subTablePtr)
                    end
                    -- update data with new directory
                    if type(dat) == 'string' then
                        if #dat > 0 or not (et.FILE_TYPE == 'CRW' or et.FILE_TYPE == 'VRD') then
                            -- replace with new block (updating the block length word)
                            dataPt = spliceSub(dataPt, pos - 4, blockLen + 4,
                                               ExifTool.Put32u(#dat) .. dat)
                        else
                            -- remove block totally (CRW/VRD files only)
                            dataPt = spliceSub(dataPt, pos - 8, blockLen + 8, '')
                        end
                        -- make necessary adjustments if block changes length
                        local diff = #dataPt - dirLen
                        if diff ~= 0 then
                            pos = pos + diff
                            dirLen = dirLen + diff
                            -- update the new VRD length in the header/footer
                            local len = ExifTool.Put32u(dirLen - 0x5c)
                            dataPt = spliceSub(dataPt, 0x18, 4, len)
                            dataPt = spliceSub(dataPt, dirLen - 0x2c, 4, len)
                        end
                    end
                else
                    -- extract as a block if requested
                    et:ProcessDirectory(subdirInfo, subTablePtr)
                end
            elseif not outfile then
                et:HandleTag(tagTablePtr, blockType, substr(dataPt, pos, blockLen))
            end
        end
        pos = pos + blockLen -- step to next block
    end
    if outfile then
        -- create XMP block if necessary (CRW/VRD files only)
        if et.ADD_DIRS and et.ADD_DIRS.CanonVRD ~= nil and not didDir.XMP then
            local subTablePtr = et:GetTagTable('lexiftool.XMP.Main')
            local dat = Writer.WriteDirectory(et, { Parent = 'CanonVRD' }, subTablePtr)
            if type(dat) == 'string' and #dat > 0 then
                dataPt = spliceSub(dataPt, #dataPt - 0x40, 0,
                                   ExifTool.Put32u(0xffff00f6) .. ExifTool.Put32u(#dat) .. dat)
                dirLen = #dataPt
                -- update the new VRD length in the header/footer
                local len = ExifTool.Put32u(dirLen - 0x5c)
                dataPt = spliceSub(dataPt, 0x18, 4, len)
                dataPt = spliceSub(dataPt, dirLen - 0x2c, 4, len)
            end
        end
        -- write CanonVRD trailer unless it is empty
        if #dataPt > 0 then
            if not Write(outfile, dataPt) then err = 1 end
        elseif truthy(verbose) then
            et:VPrint(0, '  Deleting CanonVRD trailer\n')
        end
    elseif vrdType == 'VRD' and
           ((et.TAGS_FROM_FILE and not (et.EXCL_TAG_LOOKUP or {}).canonvrd)
            or (et.REQ_TAG_LOOKUP or {}).canonvrd) then
        -- extract CanonVRD block if copying tags, or if requested (and not DR4 info)
        et:FoundTag('CanonVRD', dataPt)
    end
    if err then return -1 end
    return 1
end

-- (the predeclared PROCESS_PROC/WRITE_PROC/ProcessProc/SORT_PROC entries above)
CanonVRD.Main.WRITE_PROC = CanonVRD.WriteCanonVRD
CanonVRD.Main.PROCESS_PROC = CanonVRD.ProcessCanonVRD
CanonVRD.Edit.WRITE_PROC = CanonVRD.ProcessEditData
CanonVRD.Edit.PROCESS_PROC = CanonVRD.ProcessEditData
CanonVRD.Edit4.WRITE_PROC = CanonVRD.ProcessEditData
CanonVRD.Edit4.PROCESS_PROC = CanonVRD.ProcessEditData
CanonVRD.IHL.PROCESS_PROC = CanonVRD.ProcessIHL
CanonVRD.IHL[1][1].SubDirectory.ProcessProc = CanonVRD.ProcessIHLExif
CanonVRD.DR4.PROCESS_PROC = CanonVRD.ProcessDR4
CanonVRD.DR4.WRITE_PROC = CanonVRD.ProcessDR4
CanonVRD.DR4.VARS.SORT_PROC = CanonVRD.SortDR4

return CanonVRD
