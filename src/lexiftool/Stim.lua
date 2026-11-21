--------------------------------------------------------------------------------
-- File:         lexiftool/Stim.lua
-- Ported from:  lib/Image/ExifTool/Stim.pm
--
-- Description:  Definitions for Stereo Still Image tags
--
-- Revisions:    06/12/2009 - P. Harvey Created
--
-- References:   1) http://www.cipa.jp/std/documents/e/DC-006_E.pdf
--
-- Port notes:   ported in full: all three tables (`Main`, `CropX`, `CropY`).
--               Upstream Stim.pm is tag definitions only -- no subs -- and
--               is read-only.
--               No vendored test image carries an APP3 Stim segment.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')

local Stim = {}

-- Tags found in APP3 Stim segment in JPEG images
Stim.Main = {
    GROUPS = { [0] = 'Stim', [1] = 'Stim', [2] = 'Image'},
    NOTES = [[
        These tags are part of the CIPA Stereo Still Image specification, and are
        found in the APP3 "Stim" segment of JPEG images.  See
        L<https://web.archive.org/web/20190718152459/http://www.cipa.jp/std/documents/e/DC-006_E.pdf>
        for the official specification.
    ]],
    [0] = 'StimVersion',
    [1] = {
        Name = 'ApplicationData',
        Binary = 1,
    },
    [2] = {
        Name = 'ImageArrangement',
        PrintConv = {
            [0] = 'Parallel View Alignment',
            [1] = 'Cross View Alignment',
        },
    },
    [3] = {
        Name = 'ImageRotation',
        PrintConv = {
            [1] = 'None',
        },
    },
    [4] = 'ScalingFactor',
    [5] = 'CropXSize',
    [6] = 'CropYSize',
    [7] = {
        Name = 'CropX',
        SubDirectory = {
            TagTable = 'lexiftool.Stim.CropX',
        },
    },
    [8] = {
        Name = 'CropY',
        SubDirectory = {
            TagTable = 'lexiftool.Stim.CropY',
        },
    },
    [9] = {
        Name = 'ViewType',
        PrintConv = {
            [0] = 'No Pop-up Effect',
            [1] = 'Pop-up Effect',
        },
    },
    [10] = {
        Name = 'RepresentativeImage',
        PrintConv = {
            [0] = 'Left Viewpoint',
            [1] = 'Right Viewpoint',
        },
    },
    [11] = {
        Name = 'ConvergenceBaseImage',
        PrintConv = {
            [0] = 'Left Viewpoint',
            [1] = 'Right Viewpoint',
            [255] = 'Equivalent for Both Viewpoints',
        },
    },
    [12] = {
        Name = 'AssumedDisplaySize',
        PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' mm' end,
    },
    [13] = {
        Name = 'AssumedDistanceView',
        PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' mm' end,
    },
    [14] = 'RepresentativeDisparityNear',
    [15] = 'RepresentativeDisparityFar',
    [16] = {
        Name = 'InitialDisplayEffect',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [17] = {
        Name = 'ConvergenceDistance',
        PrintConv = function(_self, val)
            return ExifTool.perlTruthy(val) and (ExifTool.NumStr(val) .. ' mm') or 'inf'
        end,
    },
    [18] = {
        Name = 'CameraArrangementInterval',
        PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' mm' end,
    },
    [19] = 'ShootingCount',
}

-- crop offset X tags
Stim.CropX = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'Stim', [1] = 'Stim', [2] = 'Image'},
    [0] = {
        Name = 'CropXCommonOffset',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Common Offset Setting',
            [1] = 'Individual Offset Setting',
        },
    },
    [2] = 'CropXViewpointNumber',
    [3] = {
        Name = 'CropXOffset',
        Format = 'int32s',
    },
    [7] = 'CropXViewpointNumber2',
    [8] = {
        Name = 'CropXOffset2',
        Format = 'int32s',
    },
}

-- crop offset Y tags
Stim.CropY = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'Stim', [1] = 'Stim', [2] = 'Image'},
    [0] = {
        Name = 'CropYCommonOffset',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Common Offset Setting',
            [1] = 'Individual Offset Setting',
        },
    },
    [2] = 'CropYViewpointNumber',
    [3] = {
        Name = 'CropYOffset',
        Format = 'int32s',
    },
    [7] = 'CropYViewpointNumber2',
    [8] = {
        Name = 'CropYOffset2',
        Format = 'int32s',
    },
}

return Stim
