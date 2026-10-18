--------------------------------------------------------------------------------
-- File:         lexiftool/SonyIDC.lua
-- Ported from:  lib/Image/ExifTool/SonyIDC.pm
--
-- Description:  Read/write Sony IDC information
--
-- Revisions:    2010/01/05 - P. Harvey Created
--
-- Port notes:   complete: the Main table, the Composite table, the loop that
--               sets the "Permanent" flag on every Main tag, and
--               ExtractPreviews.
--               Not reachable yet: upstream dispatches this table only from
--               %Image::ExifTool::Sony::SR2Private (tags 0x7240 IDC_IFD and
--               0x7241 IDC2_IFD), and that table is not ported -- it needs
--               Sony's ProcessSR2/WriteSR2, which the Sony port defers (see
--               Sony.lua's Port notes).  Nothing in the vendored test tree
--               reaches SonyIDC either, so the tables here are verified
--               against the original by `make verify` only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local matches = require('lexiftool.perl').matches
local sprintf = require('lexiftool.perl').sprintf

local SonyIDC = {}

-- Sony IDC tags (ref PH)
SonyIDC.Main = {
    -- (a top-level require of WriteExif would pull in nearly every vendor
    --  module at load time, and BuildCompositeTags derives its worklist
    --  from `package.loaded` -- see the note there)
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    NOTES = 'Tags written by the Sony Image Data Converter utility in ARW images.',
    SET_GROUP1 = 1,
    [0x201] = {
        Name = 'IDCPreviewStart',
        IsOffset = 1,
        OffsetPair = 0x202,
        DataTag = 'IDCPreview',
        Writable = 'int32u',
        Protected = 2,
    },
    [0x202] = {
        Name = 'IDCPreviewLength',
        OffsetPair = 0x201,
        DataTag = 'IDCPreview',
        Writable = 'int32u',
        Protected = 2,
    },
    [0x8000] = {
        Name = 'IDCCreativeStyle',
        Writable = 'int32u',
        PrintConvColumns = 2,
        PrintConv = {
            [1] = 'Camera Setting',
            [2] = 'Standard',
            [3] = 'Real',
            [4] = 'Vivid',
            [5] = 'Adobe RGB',
            [6] = 'A100 Standard', -- shows up as '-' in IDC menu
            [7] = 'Neutral',
            [8] = 'Portrait',
            [9] = 'Landscape',
            [10] = 'Clear',
            [11] = 'Deep',
            [12] = 'Light',
            [13] = 'Sunset',
            [14] = 'Night View',
            [15] = 'Autumn Leaves',
            [16] = 'B&W',
            [17] = 'Sepia',
        },
    },
    [0x8001] = {
        Name = 'CreativeStyleWasChanged',
        Writable = 'int32u',
        Notes = 'set if the creative style was ever changed',
        --        (even if it was changed back again later)
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x8002] = {
        Name = 'PresetWhiteBalance',
        Writable = 'int32u',
        PrintConv = {
            [1] = 'Camera Setting',
            [2] = 'Color Temperature',
            [3] = 'Specify Gray Point',
            [4] = 'Daylight',
            [5] = 'Cloudy',
            [6] = 'Shade',
            [7] = 'Cool White Fluorescent',
            [8] = 'Day Light Fluorescent',
            [9] = 'Day White Fluorescent',
            [10] = 'Warm White Fluorescent',
            [11] = 'Tungsten',
            [12] = 'Flash',
            [13] = 'Auto',
        },
    },
    [0x8013] = { Name = 'ColorTemperatureAdj',  Writable = 'int16u' },
    [0x8014] = { Name = 'PresetWhiteBalanceAdj',Writable = 'int32s' },
    [0x8015] = { Name = 'ColorCorrection',      Writable = 'int32s' },
    [0x8016] = { Name = 'SaturationAdj',        Writable = 'int32s' },
    [0x8017] = { Name = 'ContrastAdj',          Writable = 'int32s' },
    [0x8018] = {
        Name = 'BrightnessAdj',
        Writable = 'int32s',
        PrintConv = function(_self, val) return sprintf('%.2f', val / 300) end, -- #JR
        PrintConvInv = function(_self, val) return val * 300 end,
    },
    [0x8019] = { Name = 'HueAdj',               Writable = 'int32s' },
    [0x801a] = { Name = 'SharpnessAdj',         Writable = 'int32s' },
    [0x801b] = { Name = 'SharpnessOvershoot',   Writable = 'int32s' },
    [0x801c] = { Name = 'SharpnessUndershoot',  Writable = 'int32s' },
    [0x801d] = { Name = 'SharpnessThreshold',   Writable = 'int32s' },
    [0x801e] = {
        Name = 'NoiseReductionMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [0x8021] = {
        Name = 'GrayPoint',
        Writable = 'int16u',
        Count = 4,
    },
    [0x8022] = {
        Name = 'D-RangeOptimizerMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Auto',
            [2] = 'Manual',
        },
    },
    [0x8023] = { Name = 'D-RangeOptimizerValue',    Writable = 'int32s' },
    [0x8024] = { Name = 'D-RangeOptimizerHighlight',Writable = 'int32s' },
    [0x8026] = {
        Name = 'HighlightColorDistortReduct',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Standard',
            [1] = 'Advanced',
        },
    },
    [0x8027] = {
        Name = 'NoiseReductionValue',
        Writable = 'int32s',
        ValueConv = function(_self, val) return (val + 100) / 2 end,
        ValueConvInv = function(_self, val) return val * 2 - 100 end,
    },
    [0x8028] = {
        Name = 'EdgeNoiseReduction',
        Writable = 'int32s',
        ValueConv = function(_self, val) return (val + 100) / 2 end,
        ValueConvInv = function(_self, val) return val * 2 - 100 end,
    },
    [0x8029] = {
        Name = 'ColorNoiseReduction',
        Writable = 'int32s',
        ValueConv = function(_self, val) return (val + 100) / 2 end,
        ValueConvInv = function(_self, val) return val * 2 - 100 end,
    },
    [0x802d] = { Name = 'D-RangeOptimizerShadow',       Writable = 'int32s' },
    [0x8030] = { Name = 'PeripheralIllumCentralRadius', Writable = 'int32s' },
    [0x8031] = { Name = 'PeripheralIllumCentralValue',  Writable = 'int32s' },
    [0x8032] = { Name = 'PeripheralIllumPeriphValue',   Writable = 'int32s' },
    [0x8040] = { -- #JR
        Name = 'DistortionCompensation',
        Writable = 'int32s',
        PrintConv = {
            [-1] = 'n/a', -- (fixed by lens)
            [1] = 'On',
            [2] = 'Off',
        },
    },
    [0x9000] = {
        Name = 'ToneCurveBrightnessX',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9001] = {
        Name = 'ToneCurveRedX',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9002] = {
        Name = 'ToneCurveGreenX',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9003] = {
        Name = 'ToneCurveBlueX',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9004] = {
        Name = 'ToneCurveBrightnessY',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9005] = {
        Name = 'ToneCurveRedY',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9006] = {
        Name = 'ToneCurveGreenY',
        Writable = 'int16u',
        Count = -1,
    },
    [0x9007] = {
        Name = 'ToneCurveBlueY',
        Writable = 'int16u',
        Count = -1,
    },
    [0x900d] = { -- #JR
        Name = 'ChromaticAberrationCorrection', -- "Magnification Chromatic Aberration"
        Writable = 'int32s',
        PrintConv = { [1] = 'On', [2] = 'Off' },
    },
    [0x900e] = { -- #JR
        Name = 'InclinationCorrection',
        Writable = 'int32u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x900f] = { -- #JR
        Name = 'InclinationAngle',
        Writable = 'int32s',
        PrintConv = function(_self, val) return sprintf('%.1f deg', val / 1000) end,
        PrintConvInv = function(_self, val) return ExifTool.ToFloat(val) * 1000 end,
    },
    [0x9010] = { -- #JR
        Name = 'Cropping',
        Writable = 'int32u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x9011] = { -- #JR
        Name = 'CropArea',
        Writable = 'int32u',
        Count = 4,
    },
    [0x9012] = { -- #JR
        Name = 'PreviewImageSize',
        Writable = 'int32u',
        Count = 2,
    },
    [0x9013] = { -- #JR (ARQ images)
        Name = 'PxShiftPeriphEdgeNR',
        Writable = 'int32s',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x9014] = { -- #JR (ARQ images)
        Name = 'PxShiftPeriphEdgeNRValue',
        Writable = 'int32s',
        PrintConv = function(_self, val) return sprintf('%.1f', val / 10) end,
        PrintConvInv = function(_self, val) return val * 10 end,
    },
    [0x9017] = { Name = 'WhitesAdj',        Writable = 'int32s' }, -- #JR
    [0x9018] = { Name = 'BlacksAdj',        Writable = 'int32s' }, -- #JR
    [0x9019] = { Name = 'HighlightsAdj',    Writable = 'int32s' }, -- #JR
    [0x901a] = { Name = 'ShadowsAdj',       Writable = 'int32s' }, -- #JR
    [0xd000] = { Name = 'CurrentVersion',   Writable = 'int32u' },
    [0xd001] = {
        Name = 'VersionIFD',
        Groups = { [1] = 'Version0' },
        Flags = 'SubIFD',
        Notes = 'there is one VersionIFD for each entry in the "Version Stack"',
        SubDirectory = {
            DirName = 'Version0',
            TagTable = 'lexiftool.SonyIDC.Main',
            Start = function(_et, val) return val end,
            Base = function(_et, _val, start) return start end,
            MaxSubdirs = 20,   -- (IDC v3.0 writes max. 10)
            RelativeBase = 1,  -- needed to write SubIFD with relative offsets
        },
    },
    [0xd100] = {
        Name = 'VersionCreateDate',
        Writable = 'string',
        Groups = { [2] = 'Time' },
        Notes = 'date/time when this entry was created in the "Version Stack"',
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val)
            return require('lexiftool.Writer').InverseDateTime(self, val, 0)
        end,
    },
    [0xd101] = {
        Name = 'VersionModifyDate',
        Writable = 'string',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val)
            return require('lexiftool.Writer').InverseDateTime(self, val, 0)
        end,
    },
}

-- extract IDC preview images as composite tags
SonyIDC.Composite = {
    GROUPS = { [2] = 'Image' },
    IDCPreviewImage = {
        TagID = 'SonyIDC-IDCPreviewImage',
        Groups = { [2] = 'Preview' },
        Require = {
            [0] = 'IDCPreviewStart',
            [1] = 'IDCPreviewLength',
        },
        -- extract all preview images (not just one)
        RawConv = function(self, val)
            -- upstream: `@grps = $self->GetGroup($$val{0})` -- family 0/1 of
            -- the output tag follow IDCPreviewStart's own directory; this port
            -- passes them through the SET_GROUP0/SET_GROUP1 side channel
            self.SET_GROUP0 = self:GetGroup(val[0], 0)
            self.SET_GROUP1 = self:GetGroup(val[0], 1)
            return SonyIDC.ExtractPreviews(self)
        end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.SonyIDC', nil, SonyIDC)

-- set "Permanent" flag for all tags
do
    local key
    for _, k in ipairs(ExifTool.TagTableKeys(SonyIDC.Main)) do
        key = k
        SonyIDC.Main[key].Permanent = 1
    end
end

--------------------------------------------------------------------------------
-- Extract all IDC preview images
-- Inputs: 0) ExifTool object ref
-- Returns: data for "IDCPreviewImage" tag (which I have never seen),
--          or undef if there was no preview in the SonyIDC IFD
--------------------------------------------------------------------------------
function SonyIDC.ExtractPreviews(et)
    local i = 1
    local xtra = ' (1)'
    local preview
    -- loop through all available IDC preview images in the order they were found
    while true do
        local key = 'IDCPreviewStart' .. xtra
        if et.VALUE[key] == nil then
            if xtra == '' then break end
            xtra = '' -- do the last tag extracted last
        else
            -- run through IDC preview images in the same order they were extracted
            local off = et:GetValue(key, 'ValueConv')
            if not ExifTool.perlTruthy(off) then break end
            local len = et:GetValue('IDCPreviewLength' .. xtra, 'ValueConv')
            if not ExifTool.perlTruthy(len) then break end
            -- get stack version from number in group 1 name
            local grp1 = et:GetGroup(key, 1)
            local num = matches(grp1, [[(\d+)$]])
            if num then
                local tag = 'IDCPreviewImage' .. num
                if not ExifTool.Extra[tag] then
                    ExifTool.AddTagToTable(et, ExifTool.Extra, tag, {
                        Name = tag,
                        Groups = { [0] = 'Composite', [1] = 'Composite', [2] = 'Preview'},
                    })
                end
                local val = Exif.ExtractImage(et, off, len, tag)
                local grps = et:GetGroup(key)
                et:FoundTag(tag, val, grps[0], grps[1])
            else
                preview = Exif.ExtractImage(et, off, len, 'IDCPreviewImage')
            end
            -- step to next set of tags unless we are done
            if xtra == '' then break end
            i = i + 1
            xtra = ' (' .. ExifTool.NumStr(i) .. ')'
        end
    end
    return preview
end

return SonyIDC
