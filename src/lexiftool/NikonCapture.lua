--------------------------------------------------------------------------------
-- File:         lexiftool/NikonCapture.lua
-- Ported from:  lib/Image/ExifTool/NikonCapture.pm
--
-- Description:  Read/write Nikon Capture information
--
-- Revisions:    11/08/2005 - P. Harvey Created
--               10/10/2008 - P. Harvey Updated for Capture NX 2
--               16/04/2011 - P. Harvey Decode NikonCaptureEditVersions
--
-- References:   1) http://www.cybercom.net/~dcoffin/dcraw/
--               IB) Iliah Borg private communication (LibRaw)
--
-- Port notes:   Complete port of NikonCapture.pm: all tables and subs in
--               upstream order (tables mechanically extracted from the Perl).
--               PROCESS_PROC/WRITE_PROC of `Main` are `false` placeholders
--               filled in after the subs at the bottom of the file.
--               CHECK_PROC => CheckBinaryData is Writer.CheckBinaryData.
--               The `%Image::ExifTool::NikonCapture::Main` CHECK_PROC
--               (Exif::CheckExif) is reached through WriteExif.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local matches = perl.matches
local length = perl.length
local truthy = perl.truthy
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local ReadValue = ExifTool.ReadValue
local GetTagTable = ExifTool.GetTagTable
local Set32u = ExifTool.Put32u -- (upstream's one-argument Set32u($val))

local NikonCapture = {}

-- common print conversions
local offOn = { [0] = 'Off', [1] = 'On' }
local noYes = { [0] = 'No', [1] = 'Yes' }
local unsharpColor = {
    [0] = 'RGB',
    [1] = 'Red',
    [2] = 'Green',
    [3] = 'Blue',
    [4] = 'Yellow',
    [5] = 'Magenta',
    [6] = 'Cyan',
}

-- Nikon Capture data (ref PH)
NikonCapture.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false, -- predeclaration, see below for implementation
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    NOTES = [[
        This information is written by the Nikon Capture software in tag 0x0e01 of
        the maker notes of NEF images.
    ]],
    -- 0x007ddc9d contains contrast information
    [0x008ae85e] = {
        Name = 'LCHEditor',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x0c89224b] = {
        Name = 'ColorAberrationControl',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x116fea21] = {
        Name = 'HighlightData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.HighlightData',
        },
    },
    [0x2175eb78] = {
        Name = 'D-LightingHQ',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x2fc08431] = {
        Name = 'StraightenAngle',
        Writable = 'double',
    },
    [0x374233e0] = {
        Name = 'CropData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.CropData',
        },
    },
    [0x39c456ac] = {
        Name = 'PictureCtrl',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.PictureCtrl',
        },
    },
    [0x3cfc73c6] = {
        Name = 'RedEyeData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.RedEyeData',
        },
    },
    [0x3d136244] = {
        Name = 'EditVersionName',
        Writable = 'string', -- (null terminated)
    },
    -- 0x3e726567 added when I rotated by 90 degrees
    [0x416391c6] = {
        Name = 'QuickFix',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x56a54260] = {
        Name = 'Exposure',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.Exposure',
        },
    },
    [0x5f0e7d23] = {
        Name = 'ColorBooster',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x6a6e36b6] = {
        Name = 'D-LightingHQSelected',
        Writable = 'int8u',
        PrintConv = noYes,
    },
    [0x753dcbc0] = {
        Name = 'NoiseReduction',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43200] = {
        Name = 'UnsharpMask',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43201] = {
        Name = 'Curves',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43202] = {
        Name = 'ColorBalanceAdj',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43203] = {
        Name = 'AdvancedRaw',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43204] = {
        Name = 'WhiteBalanceAdj',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43205] = {
        Name = 'VignetteControl',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0x76a43206] = {
        Name = 'FlipHorizontal',
        Writable = 'int8u',
        PrintConv = noYes,
    },
    [0x76a43207] = { -- rotation angle in degrees
        Name = 'Rotation',
        Writable = 'int16u',
    },
    [0x083a1a25] = {
        Name = 'HistogramXML',
        Writable = 'undef',
        Binary = 1,
        AdjustSize = 4,    -- patch Nikon bug
    },
    [0x84589434] = {
        Name = 'BrightnessData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.Brightness',
        },
    },
  -- 0x88f55e48 - related to QuickFix
    [0x890ff591] = {
        Name = 'D-LightingHQData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.DLightingHQ',
        },
    },
    [0x926f13e0] = {
        Name = 'NoiseReductionData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.NoiseReduction',
        },
    },
    [0x9ef5f6e0] = {
        Name = 'IPTCData',
        SubDirectory = {
            TagTable = 'lexiftool.IPTC.Main',
        },
    },
  -- 0xa7264a72 - related to QuickFix
    [0xab5eca5e] = {
        Name = 'PhotoEffects',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0xac6bd5c0] = {
        Name = 'VignetteControlIntensity',
        Writable = 'int16s',
    },
    [0xb0384e1e] = {
        Name = 'PhotoEffectsData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.PhotoEffects',
        },
    },
    [0xb999a36f] = {
        Name = 'ColorBoostData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.ColorBoost',
        },
    },
    [0xbf3c6c20] = {
        Name = 'WBAdjData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.WBAdjData',
        },
    },
    [0xce5554aa] = {
        Name = 'D-LightingHS',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0xe2173c47] = {
        Name = 'PictureControl',
        Writable = 'int8u',
        PrintConv = offOn,
    },
    [0xe37b4337] = {
        Name = 'D-LightingHSData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.DLightingHS',
        },
    },
    [0xe42b5161] = {
        Name = 'UnsharpData',
        SubDirectory = {
            TagTable = 'lexiftool.NikonCapture.UnsharpData',
        },
    },
    [0xe9651831] = {
        Name = 'PhotoEffectHistoryXML',
        Binary = 1,
        Writable = 'undef',
    },
    [0xfe28a44f] = {
        Name = 'AutoRedEye',
        Writable = 'int8u',
        PrintConv = offOn, -- (have seen a value of 28 here for older software?)
    },
    [0xfe443a45] = {
        Name = 'ImageDustOff',
        Writable = 'int8u',
        PrintConv = offOn,
    },
}

NikonCapture.UnsharpData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = 'UnsharpCount',
    [19] = { Name = 'Unsharp1Color', Format = 'int16u', PrintConv = unsharpColor },
    [23] = { Name = 'Unsharp1Intensity', Format = 'int16u' },
    [25] = { Name = 'Unsharp1HaloWidth', Format = 'int16u' },
    [27] = 'Unsharp1Threshold',
    [46] = { Name = 'Unsharp2Color', Format = 'int16u', PrintConv = unsharpColor },
    [50] = { Name = 'Unsharp2Intensity', Format = 'int16u' },
    [52] = { Name = 'Unsharp2HaloWidth', Format = 'int16u' },
    [54] = 'Unsharp2Threshold',
    [73] = { Name = 'Unsharp3Color', Format = 'int16u', PrintConv = unsharpColor },
    [77] = { Name = 'Unsharp3Intensity', Format = 'int16u' },
    [79] = { Name = 'Unsharp3HaloWidth', Format = 'int16u' },
    [81] = 'Unsharp3Threshold',
    [100] = { Name = 'Unsharp4Color', Format = 'int16u', PrintConv = unsharpColor },
    [104] = { Name = 'Unsharp4Intensity', Format = 'int16u' },
    [106] = { Name = 'Unsharp4HaloWidth', Format = 'int16u' },
    [108] = 'Unsharp4Threshold',
    -- there could be more, but I grow bored of this... :P
}

NikonCapture.DLightingHS = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = 'D-LightingHSAdjustment',
    [1] = 'D-LightingHSColorBoost',
}

NikonCapture.DLightingHQ = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = 'D-LightingHQShadow',
    [1] = 'D-LightingHQHighlight',
    [2] = 'D-LightingHQColorBoost',
}

NikonCapture.ColorBoost = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'ColorBoostType',
        PrintConv = {
            [0] = 'Nature',
            [1] = 'People',
        },
    },
    [1] = {
        Name = 'ColorBoostLevel',
        Format = 'int32u',
    },
}

NikonCapture.WBAdjData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0x00] = {
        Name = 'WBAdjRedBalance',
        Format = 'double',
    },
    [0x08] = {
        Name = 'WBAdjBlueBalance',
        Format = 'double',
    },
    [0x10] = {
        Name = 'WBAdjMode',
        PrintConv = {
            [1] = 'Use Gray Point',
            [2] = 'Recorded Value',
            [3] = 'Use Temperature',
            [4] = 'Calculate Automatically',
            [5] = 'Auto2', -- #IB
            [6] = 'Underwater', -- #IB
            [7] = 'Auto1',
        },
    },
    [0x14] = { -- #IB
        Name = 'WBAdjLighting',
        Format = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x000] = 'None',
            [0x100] = 'Incandescent',
            [0x200] = 'Daylight (direct sunlight)',
            [0x201] = 'Daylight (shade)',
            [0x202] = 'Daylight (cloudy)',
            [0x300] = 'Standard Fluorescent (warm white)',
            [0x301] = 'Standard Fluorescent (3700K)',
            [0x302] = 'Standard Fluorescent (cool white)',
            [0x303] = 'Standard Fluorescent (5000K)',
            [0x304] = 'Standard Fluorescent (daylight)',
            [0x305] = 'Standard Fluorescent (high temperature mercury vapor)',
            [0x400] = 'High Color Rendering Fluorescent (warm white)',
            [0x401] = 'High Color Rendering Fluorescent (3700K)',
            [0x402] = 'High Color Rendering Fluorescent (cool white)',
            [0x403] = 'High Color Rendering Fluorescent (5000K)',
            [0x404] = 'High Color Rendering Fluorescent (daylight)',
            [0x500] = 'Flash',
            [0x501] = 'Flash (FL-G1 filter)',
            [0x502] = 'Flash (FL-G2 filter)',
            [0x503] = 'Flash (TN-A1 filter)',
            [0x504] = 'Flash (TN-A2 filter)',
            [0x600] = 'Sodium Vapor Lamps',
            -- 0x1002 => seen for WBAdjMode modes of Underwater and Calculate Automatically
        },
    },
    [0x18] = {
        Name = 'WBAdjTemperature',
        Format = 'int16u',
    },
    [0x25] = {
        Name = 'WBAdjTint',
        Format = 'int32s',
    },
}

NikonCapture.PhotoEffects = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'PhotoEffectsType',
        PrintConv = {
            [0] = 'None',
            [1] = 'B&W',
            [2] = 'Sepia',
            [3] = 'Tinted',
        },
    },
    [4] = {
        Name = 'PhotoEffectsRed',
        Format = 'int16s',
    },
    [6] = {
        Name = 'PhotoEffectsGreen',
        Format = 'int16s',
    },
    [8] = {
        Name = 'PhotoEffectsBlue',
        Format = 'int16s',
    },
}

NikonCapture.Brightness = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'BrightnessAdj',
        Format = 'double',
        ValueConv = function(_self, val) return val * 50 end,
        ValueConvInv = function(_self, val) return val / 50 end,
    },
    [8] = {
        Name = 'EnhanceDarkTones',
        PrintConv = offOn,
    },
}

NikonCapture.NoiseReduction = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0x04] = {
        Name = 'EdgeNoiseReduction',
        PrintConv = offOn,
    },
    [0x05] = {
        Name = 'ColorMoireReductionMode',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Low',
            [2] = 'Medium',
            [3] = 'High',
        },
    },
    [0x09] = {
        Name = 'NoiseReductionIntensity',
        Format = 'int32u',
    },
    [0x0d] = {
        Name = 'NoiseReductionSharpness',
        Format = 'int32u',
    },
    [0x11] = {
        Name = 'NoiseReductionMethod',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Faster',
            [1] = 'Better Quality',
            [2] = 'Better Quality 2013',
        },
    },
    [0x15] = {
        Name = 'ColorMoireReduction',
        PrintConv = offOn,
    },
    [0x17] = {
        Name = 'NoiseReduction',
        PrintConv = offOn,
    },
    [0x18] = {
        Name = 'ColorNoiseReductionIntensity',
        Format = 'int32u',
    },
    [0x1c] = {
        Name = 'ColorNoiseReductionSharpness',
        Format = 'int32u',
    },
}

NikonCapture.CropData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0x1e] = {
        Name = 'CropLeft',
        Format = 'double',
        ValueConv = function(_self, val) return val / 2 end,
        ValueConvInv = function(_self, val) return val * 2 end,
    },
    [0x26] = {
        Name = 'CropTop',
        Format = 'double',
        ValueConv = function(_self, val) return val / 2 end,
        ValueConvInv = function(_self, val) return val * 2 end,
    },
    [0x2e] = {
        Name = 'CropRight',
        Format = 'double',
        ValueConv = function(_self, val) return val / 2 end,
        ValueConvInv = function(_self, val) return val * 2 end,
    },
    [0x36] = {
        Name = 'CropBottom',
        Format = 'double',
        ValueConv = function(_self, val) return val / 2 end,
        ValueConvInv = function(_self, val) return val * 2 end,
    },
    [0x8e] = {
        Name = 'CropOutputWidthInches',
        Format = 'double',
    },
    [0x96] = {
        Name = 'CropOutputHeightInches',
        Format = 'double',
    },
    [0x9e] = {
        Name = 'CropScaledResolution',
        Format = 'double',
    },
    [0xae] = {
        Name = 'CropSourceResolution',
        Format = 'double',
        ValueConv = function(_self, val) return val / 2 end,
        ValueConvInv = function(_self, val) return val * 2 end,
    },
    [0xb6] = {
        Name = 'CropOutputResolution',
        Format = 'double',
    },
    [0xbe] = {
        Name = 'CropOutputScale',
        Format = 'double',
    },
    [0xc6] = {
        Name = 'CropOutputWidth',
        Format = 'double',
    },
    [0xce] = {
        Name = 'CropOutputHeight',
        Format = 'double',
    },
    [0xd6] = {
        Name = 'CropOutputPixels',
        Format = 'double',
    },
}

NikonCapture.PictureCtrl = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0x00] = {
        Name = 'PictureControlActive',
        PrintConv = offOn,
    },
    [0x13] = {
        Name = 'PictureControlMode',
        Format = 'string[16]',
    },
    -- 0x29 changes with Hue and Sharpening
    [0x2a] = {
        Name = 'QuickAdjust',
        ValueConv = function(_self, val) return val - 128 end,
        ValueConvInv = function(_self, val) return val + 128 end,
    },
    [0x2b] = {
        Name = 'SharpeningAdj',
        ValueConv = function(_self, val) if truthy(val) then return val - 128 end return 'Auto' end,
        ValueConvInv = function(_self, val) if matches(val, [[\d]]) then return val + 128 end return 0 end,
    },
    [0x2c] = {
        Name = 'ContrastAdj',
        ValueConv = function(_self, val) if truthy(val) then return val - 128 end return 'Auto' end,
        ValueConvInv = function(_self, val) if matches(val, [[\d]]) then return val + 128 end return 0 end,
    },
    [0x2d] = {
        Name = 'BrightnessAdj',
        ValueConv = function(_self, val) if truthy(val) then return val - 128 end return 'Auto' end, -- no "Auto" mode (yet) for this setting
        ValueConvInv = function(_self, val) if matches(val, [[\d]]) then return val + 128 end return 0 end,
    },
    [0x2e] = {
        Name = 'SaturationAdj',
        ValueConv = function(_self, val) if truthy(val) then return val - 128 end return 'Auto' end,
        ValueConvInv = function(_self, val) if matches(val, [[\d]]) then return val + 128 end return 0 end,
    },
    [0x2f] = {
        Name = 'HueAdj',
        ValueConv = function(_self, val) return val - 128 end,
        ValueConvInv = function(_self, val) return val + 128 end,
    },
    -- 0x37 changed from 0 to 2 when Picture Control is enabled (and no active DLighting)
}

NikonCapture.RedEyeData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'RedEyeCorrection',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Automatic',
            [2] = 'Click on Eyes',
        },
    },
}

NikonCapture.Exposure = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0x00] = {
        Name = 'ExposureAdj',
        Format = 'int16s',
        ValueConv = function(_self, val) return val / 100 end,
        ValueConvInv = function(_self, val) return val * 100 end,
    },
    [0x12] = {
        Name = 'ExposureAdj2',
        Format = 'double',
        PrintConv = function(_self, val) return sprintf('%.4f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x24] = {
        Name = 'ActiveD-Lighting',
        PrintConv = offOn,
    },
    [0x25] = {
        Name = 'ActiveD-LightingMode',
        PrintConv = {
            [0] = 'Unchanged',
            [1] = 'Off',
            [2] = 'Low',
            [3] = 'Normal',
            [4] = 'High',
            [6] = 'Extra High',
            [7] = 'Extra High 1',
            [8] = 'Extra High 2',
        },
    },
}

NikonCapture.HighlightData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int8s',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = 'ShadowProtection',
    [1] = 'SaturationAdj',
    [6] = 'HighlightProtection',
}

--------------------------------------------------------------------------------
-- write Nikon Capture data (ref 1)
-- Inputs: 0) ExifTool object reference, 1) reference to directory information
--         2) pointer to tag table
-- Returns: 1 on success
function NikonCapture.WriteNikonCapture(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package

    -- no need to edit this information unless necessary
    if not (et.EDIT_DIRS.MakerNotes or et.EDIT_DIRS.IPTC) then
        return nil
    end
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    if dirLen < 22 then
        et:Warn('Short Nikon Capture Data', 1)
        return nil
    end
    -- make sure the capture data is properly contained
    SetByteOrder('II')
    local tagID = Get32u(dataPt, dirStart)
    -- sometimes size includes 18 header bytes, and other times it doesn't (eg. ViewNX 2.1.1)
    local size = Get32u(dataPt, dirStart + 18)
    local pad = dirLen - size - 18
    if not (tagID == 0x7a86a940 and (pad >= 0 or pad == -18)) then
        et:Warn('Unrecognized Nikon Capture Data header')
        return nil
    end
    -- determine if there is any data after this block
    if pad > 0 then
        pad = substr(dataPt, dirStart + 18 + size, pad)
        dirLen = size + 18
    else
        pad = ''
    end
    local outBuff = ''
    local pos
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
    local dirEnd = dirStart + dirLen

    -- loop through all entries in the Nikon Capture data
    pos = dirStart + 22
    while pos + 22 < dirEnd do
        tagID = Get32u(dataPt, pos)
        size = Get32u(dataPt, pos + 18) - 4
        if size < 0 or pos + 22 + size > dirEnd then break end
        local tagInfo = et:GetTagInfo(tagTablePtr, tagID)
        local done = false
        if tagInfo then
            local newVal
            if tagInfo.SubDirectory then
                -- rewrite the subdirectory
                local subdirInfo = {
                    DataPt = dataPt,
                    DirStart = pos + 22,
                    DirLen = size,
                }
                local subTable = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                -- ignore minor errors in IPTC since there is typically trailing garbage
                local oldSetting = et:Options('IgnoreMinorErrors')
                if matches(tagInfo.Name, 'IPTC') then et:Options('IgnoreMinorErrors', 1) end
                -- rewrite the directory
                newVal = Writer.WriteDirectory(et, subdirInfo, subTable)
                -- restore our original options
                et:Options('IgnoreMinorErrors', oldSetting)
            elseif newTags[tagID] then
                -- get new value for this tag if we are writing it
                local format = tagInfo.Format or tagInfo.Writable
                local oldVal = ReadValue(dataPt, pos + 22, format, 1, size)
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                if Writer.IsOverwriting(et, nvHash, oldVal) then
                    local val = Writer.GetNewValue(et, tagInfo)
                    if val ~= nil then newVal = Writer.WriteValue(val, tagInfo.Writable) end
                    if newVal ~= nil and length(newVal) > 0 then
                        et.CHANGED = (et.CHANGED or 0) + 1
                    else
                        newVal = nil
                        et:Warn("Can't delete " .. tagInfo.Name)
                    end
                end
            end
            if newVal ~= nil then
                done = true
                if length(newVal) > 0 then -- don't write zero length information
                    -- write the new value
                    outBuff = outBuff .. substr(dataPt, pos, 18)
                    outBuff = outBuff .. Set32u(length(newVal) + 4)
                    outBuff = outBuff .. newVal
                end
            end
        end
        -- rewrite the existing information
        if not done then outBuff = outBuff .. substr(dataPt, pos, 22 + size) end
        pos = pos + 22 + size
    end
    if pos ~= dirEnd then
        if pos == dirEnd - 4 then
            -- it seems that sometimes (NX2) the main block size is wrong by 4 bytes
            -- (did they forget to include the size word?)
            outBuff = outBuff .. substr(dataPt, pos, 4)
        else
            et:Warn('Nikon Capture Data improperly terminated', 1)
            return nil
        end
    end
    -- add the header and return the new directory
    return substr(dataPt, dirStart, 18) ..
           Set32u(length(outBuff) + 4) ..
           outBuff .. pad
end

--------------------------------------------------------------------------------
-- process Nikon Capture data (ref 1)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function NikonCapture.ProcessNikonCaptureEditVersions(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    local dirEnd = dirStart + dirLen
    local verbose = et:Options('Verbose')
    SetByteOrder('II')
    if dirLen <= 4 then return 0 end
    local num = Get32u(dataPt, dirStart)
    local pos = dirStart + 4
    if truthy(verbose) then et:VerboseDir('NikonCaptureEditVersions', num) end
    while num ~= 0 do
        if pos + 4 > dirEnd then break end
        local len = Get32u(dataPt, pos)
        if pos + len + 4 > dirEnd then break end
        local dirInfo_ = {
            DirName  = 'NikonCapture',
            Parent   = 'NikonCaptureEditVersions',
            DataPt   = dataPt,
            DirStart = pos + 4,
            DirLen   = len,
        }
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        et:ProcessDirectory(dirInfo_, tagTablePtr)
        num = num - 1
        pos = pos + len + 4
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- process Nikon Capture data (ref 1)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function NikonCapture.ProcessNikonCapture(et, dirInfo, tagTablePtr)
    if not et then return 1 end -- allow dummy access to autoload this package
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or 0
    local dirEnd = dirStart + dirLen
    local verbose = et:Options('Verbose')
    local success = 0
    SetByteOrder('II')
    if truthy(verbose) then et:VerboseDir('NikonCapture', 0, dirLen) end
    local pos = dirStart + 22
    while pos + 22 < dirEnd do
        local tagID = Get32u(dataPt, pos)
        local size = Get32u(dataPt, pos + 18) - 4
        pos = pos + 22
        if size < 0 or pos + size > dirEnd then break end
        local tagInfo = et:GetTagInfo(tagTablePtr, tagID)
        if tagInfo or truthy(verbose) then
            local format, value
            -- (note that Writable will be 0 for Unknown tags)
            -- (upstream `$$tagInfo{Format} || $$tagInfo{Writable}`: a 0 is
            --  false in Perl, so an Unknown tag gets the default format below)
            if tagInfo then
                if truthy(tagInfo.Format) then format = tagInfo.Format else format = tagInfo.Writable end
            end
            -- generate a reasonable default format type for short values
            if not truthy(format) and (size == 1 or size == 2 or size == 4) then
                format = 'int' .. (size * 8) .. 'u'
            end
            if truthy(format) then
                local count = 1
                if format == 'string' or format == 'undef' then
                    -- patch Nikon bug in size of some values (HistogramXML)
                    if tagInfo and tagInfo.AdjustSize then size = size + tagInfo.AdjustSize end
                    count = size
                end
                value = ReadValue(dataPt, pos, format, count, size)
            elseif size == 1 then
                value = substr(dataPt, pos, size)
            end
            local parms = {
                DataPt = dataPt,
                DataPos = dirInfo.DataPos,
                Base = dirInfo.Base,
                Start = pos,
                Size = size,
            }
            if et:HandleTag(tagTablePtr, tagID, value, parms) then success = 1 end
        end
        pos = pos + size
    end
    return success
end

-- (the predeclared PROCESS_PROC/WRITE_PROC, see above)
NikonCapture.Main.PROCESS_PROC = NikonCapture.ProcessNikonCapture
NikonCapture.Main.WRITE_PROC = NikonCapture.WriteNikonCapture

return NikonCapture
