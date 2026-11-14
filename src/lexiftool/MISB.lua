--------------------------------------------------------------------------------
-- File:         lexiftool/MISB.lua
-- Ported from:  lib/Image/ExifTool/MISB.pm
--
-- Description:  Read Motion Industry Standards Board metadata
--
-- Revisions:    2022/10/08 - P. Harvey Created
--
-- References: 1) https://dokumen.tips/documents/nato-standardization-agreement-stanag-4609-ed-3.html
--             2) https://upload.wikimedia.org/wikipedia/commons/1/19/MISB_Standard_0601.pdf
--             3) https://dokumen.tips/documents/misb-st-010211-standard-security-metadata-universal-standard-describes-the-use.html
--
-- Port notes:   complete: all five tables (Main, UASDatalink, Security,
--               ChurchillNav, Unknown) plus ProcessKLV and ParseMISB.
--               The `%timeInfo`/`%latInfo`/`%lonInfo`/`%altInfo` hashes that
--               upstream spreads into single tag entries become the
--               `timeInfo()`/`latInfo()`/`lonInfo()`/`altInfo()` helpers
--               below, as Garmin.lua does for the same construct.
--               `ValueConv => '\$val'` (a scalar reference, so the value
--               renders as "(Binary data N bytes)") maps onto this port's
--               `{ref='SCALAR', value=...}` tuple.
--               Wired where upstream wires it: the type 0x15 branch of
--               M2TS.ParsePID.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
-- (GPS is required at the point of use, not at the top: a top-level require
--  would load it for every file that loads this module, and
--  BuildCompositeTags derives its worklist from `package.loaded`)
local perl = require('lexiftool.perl')
local matches = perl.matches
local substr = perl.substr
local sprintf = perl.sprintf
local Get8u = ExifTool.Get8u
local ReadValue = ExifTool.ReadValue
local SetByteOrder = ExifTool.SetByteOrder

local MISB = {}

local function timeInfo(t)
    t.Groups = { [2] = 'Time' }
    t.Format = 'int64u'
    t.ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val / 1e6, 0, 6) .. 'Z' end
    t.PrintConv = function(self, val) return self:ConvertDateTime(val) end
    return t
end
local function latInfo(t)
    t.Format = 'int32s'
    t.ValueConv = function(_self, val) return val * 90 / 0x7fffffff end
    t.PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end
    return t
end
local function lonInfo(t)
    t.Format = 'int32s'
    t.ValueConv = function(_self, val) return val * 180 / 0x7fffffff end
    t.PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end
    return t
end
local function altInfo(t)
    t.Format = 'int16u'
    t.ValueConv = function(_self, val) return val * 19900 / 0xffff - 900 end
    t.PrintConv = function(_self, val) return sprintf('%.2f m', val) end
    return t
end

-- default format based on size of unknown KLV information
local defaultFormat = {
    [1] = 'int8u',
    [2] = 'int16u',
    [4] = 'int32u',
    [8] = 'int64u',
}

-- small helper for the many repeated `ValueConv => '$val * A / B'` entries
-- below (same 1:1 story as upstream, factored to avoid a hundred
-- near-identical closures)
local function scl(a, b)
    return function(_self, val) return val * a / b end
end

-- upstream's `ValueConv => '\$val'`: hand back a scalar reference, so the
-- value renders as "(Binary data N bytes)"
local function scalarRef(_self, val)
    return { ref = 'SCALAR', value = val }
end

MISB.Main = {
    GROUPS = { [0] = 'MISB', [1] = 'MISB', [2] = 'Other' },
    VARS = { LONG_TAGS = 2 },
    NOTES = [[
        These tags are extracted from STANAG-4609 MISB (Motion Industry Standards
        Board) KLV-format metadata in M2TS videos.
    ]],
    ['060e2b34020b01010e01030101000000'] = {
        Name = 'UASDataLink',
        SubDirectory = { TagTable = 'lexiftool.MISB.UASDatalink' },
    },
    ['060e2b3402030101434e415644494147'] = { -- "CNAVDIAG" written by ChurchillNavigation ION
        Name = 'ChurchillNav',
        SubDirectory = {
            TagTable = 'lexiftool.MISB.ChurchillNav',
            ByteOrder = 'LittleEndian', -- !!
        },
    },
    ['060E2B34030101010E01030302000000'] = { -- (NC)
        Name = 'Security',
        SubDirectory = { TagTable = 'lexiftool.MISB.Security' },
    },
    ['<other>'] = {
        Name = 'Unknown',
        SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' },
    },
}

-- UAS datalink local set tags (ref 2, MISB ST 0601.11)
MISB.UASDatalink = {
    GROUPS = { [0] = 'MISB', [1] = 'MISB', [2] = 'Location' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'Tags extracted from the MISB ST 0601.11 UAS Datalink local set.',
    [1]  = { Name = 'Checksum',                 Format = 'int16u' },
    [2]  = timeInfo { Name = 'GPSDateTime' },
    [3]  = { Name = 'MissionID',                Format = 'string' },
    [4]  = { Name = 'TailNumber',               Format = 'string' },
    [5]  = { Name = 'GPSTrack',                 Format = 'int16u', ValueConv = scl(360, 0xffff) },
    [6]  = { Name = 'PitchAngle',               Format = 'int16s', ValueConv = scl(20, 0x7fff) },
    [7]  = { Name = 'RollAngle',                Format = 'int16s', ValueConv = scl(50, 0x7fff) },
    [8]  = { Name = 'TrueAirspeed',             Format = 'int8u',  PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' m/s' end },
    [9]  = { Name = 'IndicatedAirspeed',        Format = 'int8u',  PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' m/s' end },
    [10] = { Name = 'ProjectIDCode',            Format = 'string' },
    [11] = { Name = 'SensorName',               Format = 'string' },
    [12] = { Name = 'ImageCoordinateSystem',    Format = 'string' },
    [13] = latInfo { Name = 'GPSLatitude' },
    [14] = lonInfo { Name = 'GPSLongitude' },
    [15] = altInfo { Name = 'GPSAltitude' },
    [16] = { Name = 'HorizontalFieldOfView',    Format = 'int16u', ValueConv = scl(180, 0xffff) },
    [17] = { Name = 'VerticalFieldOfView',      Format = 'int16u', ValueConv = scl(180, 0xffff) },
    [18] = { Name = 'SensorRelativeAzimuthAngle',Format= 'int32u', ValueConv = scl(360, 0xffffffff) },
    [19] = { Name = 'SensorRelativeElevationAngle',Format='int32s',ValueConv = scl(180, 0x7fffffff) },
    [20] = { Name = 'SensorRelativeRollAngle',  Format = 'int32u', ValueConv = scl(360, 0xffffffff) },
    [21] = { Name = 'SlantRange',               Format = 'int32u', ValueConv = scl(5000000, 0xffffffff) },
    [22] = { Name = 'TargetWidth',              Format = 'int16u', ValueConv = scl(10000, 0xffff) },
    [23] = latInfo { Name = 'FrameCenterLatitude' },
    [24] = lonInfo { Name = 'FrameCenterLongitude' },
    [25] = altInfo { Name = 'FrameCenterElevation' },
    [26] = { Name = 'OffsetCornerLatitude1',    Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [27] = { Name = 'OffsetCornerLongitude1',   Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [28] = { Name = 'OffsetCornerLatitude2',    Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [29] = { Name = 'OffsetCornerLongitude2',   Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [30] = { Name = 'OffsetCornerLatitude3',    Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [31] = { Name = 'OffsetCornerLongitude3',   Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [32] = { Name = 'OffsetCornerLatitude4',    Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [33] = { Name = 'OffsetCornerLongitude4',   Format = 'int16s', ValueConv = scl(.075, 0x7fff) },
    [34] = { Name = 'IcingDetected',            Format = 'int8u',  PrintConv = { [0] = 'n/a', [1] = 'No', [2] = 'Yes' } },
    [35] = { Name = 'WindDirection',            Format = 'int16u', ValueConv = scl(360, 0xffff) },
    [36] = { Name = 'WindSpeed',                Format = 'int8u',  ValueConv = scl(100, 0xff), Notes = 'm/s' },
    [37] = { Name = 'StaticPressure',           Format = 'int16u', ValueConv = scl(5000, 0xffff), Notes = 'mbar' },
    [38] = { Name = 'DensityAltitude',          Format = 'int16u', ValueConv = function(_self, val) return val * 19900 / 0xffff - 900 end },
    [39] = { Name = 'AirTemperature',           Format = 'int8s' },
    [40] = latInfo { Name = 'TargetLocationLatitude' },
    [41] = lonInfo { Name = 'TargetLocationLongitude' },
    [42] = altInfo { Name = 'TargetLocationElevation' },
    [43] = { Name = 'TargetTrackGateWidth',     Format = 'int8u' },
    [44] = { Name = 'TargetTrackGateHeight',    Format = 'int8u' },
    [45] = { Name = 'TargetErrorEstimateCE90',  Format = 'int16u' },
    [46] = { Name = 'TargetErrorEstimateLE90',  Format = 'int16u' },
    [47] = { Name = 'GenericFlagData01',
        Format = 'int8u',
        PrintConv = { BITMASK = {
            [0] = 'Laser range',
            [1] = 'Auto-track',
            [2] = 'IR polarity black',
            [3] = 'Icing detected',
            [4] = 'Slant range measured',
            [5] = 'Image invalid',
        }},
    },
    [48] = { Name = 'SecurityLocalMetadataSet', SubDirectory = { TagTable = 'lexiftool.MISB.Security' } },
    [49] = { Name = 'DifferentialPressure',     Format = 'int16u', ValueConv = scl(5000, 0xffff) },
    [50] = { Name = 'AngleOfAttack',            Format = 'int16s', ValueConv = scl(20, 0x7fff) },
    [51] = { Name = 'VerticalSpeed',            Format = 'int16s', ValueConv = scl(180, 0x7fff), Notes = 'm/s' },
    [52] = { Name = 'SideslipAngle',            Format = 'int16s', ValueConv = scl(20, 0x7fff) },
    [53] = { Name = 'AirfieldBarometricPressure',Format= 'int16u', ValueConv = scl(5000, 0xffff) },
    [54] = altInfo { Name = 'AirfieldElevation' },
    [55] = { Name = 'RelativeHumidity',         Format = 'int8u',  ValueConv = scl(100, 0xff) },
    [56] = { Name = 'GPSSpeed',                 Format = 'int8u',  Notes = 'm/s' },
    [57] = { Name = 'GroundRange',              Format = 'int32u', ValueConv = scl(5000000, 0xffffffff) },
    [58] = { Name = 'FuelRemaining',            Format = 'int16u', ValueConv = scl(10000, 0xffff), Notes = 'kg' },
    [59] = { Name = 'CallSign',                 Format = 'string' },
    [60] = { Name = 'WeaponLoad',               Format = 'int16u', PrintConv = function(_self, val) return sprintf('0x%.4x', val) end },
    [61] = { Name = 'WeaponFired',              Format = 'int8u',  PrintConv = function(_self, val) return sprintf('0x%.2x', val) end },
    [62] = { Name = 'LaserPRFCode',             Format = 'int16u' },
    [63] = { Name = 'SensorFieldOfViewName',    Format = 'int8u',
        PrintConv = {
            [0] = 'Ultranarrow',
            [1] = 'Narrow',
            [2] = 'Medium',
            [3] = 'Wide',
            [4] = 'Ultrawide',
            [5] = 'Narrow Medium',
            [6] = '2x Ultranarrow',
            [7] = '4x Ultranarrow',
        },
    },
    [64] = { Name = 'MagneticHeading',          Format = 'int16u', ValueConv = scl(360, 0xffff) },
    [65] = { Name = 'UAS_LSVersionNumber',      Format = 'int8u' },
    [66] = { Name = 'TargetLocationCovarianceMatrix', Format = 'undef', ValueConv = scalarRef },
    [67] = latInfo { Name = 'AlternateLatitude' },
    [68] = lonInfo { Name = 'AlternateLongitude' },
    [69] = altInfo { Name = 'AlternateAltitude' },
    [70] = { Name = 'AlternateName',            Format = 'string' },
    [71] = { Name = 'AlternateHeading',         Format = 'int16u', ValueConv = scl(360, 0xffff) },
    [72] = timeInfo { Name = 'EventStartTime' },
    [73] = { Name = 'RVTLocalSet',              SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [74] = { Name = 'VMTIDataSet',              SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [75] = altInfo { Name = 'SensorEllipsoidHeight' },
    [76] = altInfo { Name = 'AlternateEllipsoidHeight' },
    [77] = { Name = 'OperationalMode',          Format = 'int8u',
        PrintConv = {
            [0] = 'Other',
            [1] = 'Operational',
            [2] = 'Training',
            [3] = 'Exercise',
            [4] = 'Maintenance',
        },
    },
    [78] = altInfo { Name = 'FrameCenterHeightAboveEllipsoid' },
    [79] = { Name = 'SensorVelocityNorth',      Format = 'int16s', ValueConv = scl(327, 0x7fff) },
    [80] = { Name = 'SensorVelocityEast',       Format = 'int16s', ValueConv = scl(327, 0x7fff) },
    [81] = { Name = 'ImageHorizonPixelPack',    Format = 'undef',  ValueConv = scalarRef },
    [82] = latInfo { Name = 'CornerLatitude1' },
    [83] = lonInfo { Name = 'CornerLongitude1' },
    [84] = latInfo { Name = 'CornerLatitude2' },
    [85] = lonInfo { Name = 'CornerLongitude2' },
    [86] = latInfo { Name = 'CornerLatitude3' },
    [87] = lonInfo { Name = 'CornerLongitude3' },
    [88] = latInfo { Name = 'CornerLatitude4' },
    [89] = lonInfo { Name = 'CornerLongitude4' },
    [90] = { Name = 'FullPitchAngle',           Format = 'int32s', ValueConv = scl(90, 0x7fffffff) },
    [91] = { Name = 'FullRollAngle',            Format = 'int32s', ValueConv = scl(90, 0x7fffffff) },
    [92] = { Name = 'FullAngleOfAttack',        Format = 'int32s', ValueConv = scl(90, 0x7fffffff) },
    [93] = { Name = 'FullSideslipAngle',        Format = 'int32s', ValueConv = scl(90, 0x7fffffff) },
    [94] = { Name = 'MIISCoreIdentifier',       Format = 'undef',  ValueConv = scalarRef },
    [95] = { Name = 'SARMotionImageryData',     SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [96] = { Name = 'TargetWidthExtended',      Format = 'undef',  ValueConv = scalarRef }, -- IMAPB format
    [97] = { Name = 'RangeImageLocalSet',       SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [98] = { Name = 'GeoregistrationLocalSet',  SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [99] = { Name = 'CompositeImagingLocalSet', SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [100]= { Name = 'SegmentLocalSet',          SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [101]= { Name = 'AmendLocalSet',            SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } },
    [102]= { Name = 'SDCC-FLP',                 Format = 'undef',  ValueConv = scalarRef }, -- IMAPB format
    [103]= { Name = 'DensityAltitudeExtended',  Format = 'undef',  ValueConv = scalarRef }, -- IMAPB format
    [104]= { Name = 'SensorEllipsoidHeightExtended', Format = 'undef',  ValueConv = scalarRef }, -- IMAPB format
    [105]= { Name = 'AlternateEllipsoidHeightExtended', Format = 'undef',  ValueConv = scalarRef }, -- IMAPB format
}

-- tags from MISB ST 0102.11 local set
MISB.Security = {
    GROUPS = { [0] = 'MISB', [1] = 'MISB', [2] = 'Document' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'Tags extracted from the MISB ST 0102.11 Security Metadata local set.',
    [1]  = { Name = 'SecurityClassification', PrintConv = {
        [1] = 'Unclassified',
        [2] = 'Restricted',
        [3] = 'Confidential',
        [4] = 'Secret',
        [5] = 'Top Secret',
    }},
    [2]  = { Name = 'ClassifyingCountryCodeMethod', PrintConv = {
        [0x01] = 'ISO-3166 Two Letter',
        [0x02] = 'ISO-3166 Three Letter',
        [0x03] = 'FIPS 10-4 Two Letter',
        [0x04] = 'FIPS 10-4 Four Letter',
        [0x05] = 'ISO-3166 Numeric',
        [0x06] = '1059 Two Letter',
        [0x07] = '1059 Three Letter',
        [0x0a] = 'FIPS 10-4 Mixed',
        [0x0b] = 'ISO 3166 Mixed',
        [0x0c] = 'STANAG 1059 Mixed',
        [0x0d] = 'GENC Two Letter',
        [0x0e] = 'GENC Three Letter',
        [0x0f] = 'GENC Numeric',
        [0x10] = 'GENC Mixed',
    }},
    [3]  = { Name = 'ClassifyingCountry',   Format = 'string', PrintConv = function(_self, val) return perl.subst(val, '^//', '') end },
    [4]  = 'SecuritySCI-SHIInformation',
    [5]  = { Name = 'Caveats',              Format = 'string' },
    [6]  = { Name = 'ReleasingInstructions',Format = 'string' },
    [7]  = { Name = 'ClassifiedBy',         Format = 'string' },
    [8]  = { Name = 'DerivedFrom',          Format = 'string' },
    [9]  = { Name = 'ClassificationReason', Format = 'string' },
    [10] = {
        Name = 'DeclassificationDate',
        Format = 'string',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return perl.subst(val, [[(\d{4})(\d{2})(\d{2})]], '$1:$2:$3') end,
    },
    [11] = 'ClassificationAndMarkingSystem',
    [12] = { Name = 'ObjectCountryCodingMethod', PrintConv = {
        [0x01] = 'ISO-3166 Two Letter',
        [0x02] = 'ISO-3166 Three Letter',
        [0x03] = 'ISO-3166 Numeric',
        [0x04] = 'FIPS 10-4 Two Letter',
        [0x05] = 'FIPS 10-4 Four Letter',
        [0x06] = '1059 Two Letter',
        [0x07] = '1059 Three Letter',
        [0x0d] = 'GENC Two Letter',
        [0x0e] = 'GENC Three Letter',
        [0x0f] = 'GENC Numeric',
        [0x40] = 'GENC AdminSub',
    }},
    [13] = { Name = 'ObjectCountryCodes', Format = 'string', PrintConv = function(_self, val) return perl.subst(val, '^//', '') end },
    [14] = { Name = 'ClassificationComments', Format = 'string' },
    [15] = 'UMID',
    [16] = 'StreamID',
    [17] = 'TransportStreamID',
    [21] = 'ItemDesignatorID',
    [22] = { Name = 'SecurityVersion', Format = 'int16u', PrintConv = function(_self, val) return '0102.' .. ExifTool.NumStr(val) end },
    [23] = {
        Name = 'ClassifyingCountryCodingMethodDate',
        Groups = { [2] = 'Time' },
        Format = 'string',
        ValueConv = function(_self, val) return (val:gsub('%-', ':')) end,
    },
    [24] = {
        Name = 'ObjectCountryCodingMethodDate',
        Groups = { [2] = 'Time' },
        Format = 'string',
        ValueConv = function(_self, val) return (val:gsub('%-', ':')) end,
    },
}

-- I have seen these, but don't know what they are for - PH
-- (they look interesting, but remain static through my sample video)
MISB.ChurchillNav = {
    GROUPS = { [0] = 'MISB', [1] = 'MISB', [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    TAG_PREFIX = 'ChurchillNav',
    NOTES = [[
        Proprietary tags used by Churchill Navigation units.  These tags are all
        currently unknown, but extracted with the Unknown option.
    ]],
    -- Note: tag ID's are decimal (because the MISB specification uses decimal ID's)
    [1]  = { Name = 'ChurchillNav_0x0001', Format = 'double', Unknown = 1, Hidden = 1 },
    [2]  = { Name = 'ChurchillNav_0x0002', Format = 'double', Unknown = 1, Hidden = 1 },
    [3]  = { Name = 'ChurchillNav_0x0003', Format = 'double', Unknown = 1, Hidden = 1 },
    [4]  = { Name = 'ChurchillNav_0x0004', Format = 'double', Unknown = 1, Hidden = 1 },
    [5]  = { Name = 'ChurchillNav_0x0005', Format = 'double', Unknown = 1, Hidden = 1 },
    [6]  = { Name = 'ChurchillNav_0x0006', Format = 'double', Unknown = 1, Hidden = 1 },
    [9]  = { Name = 'ChurchillNav_0x0009', Format = 'double', Unknown = 1, Hidden = 1 },
    [10] = { Name = 'ChurchillNav_0x000a', Format = 'double', Unknown = 1, Hidden = 1 },
    [11] = { Name = 'ChurchillNav_0x000b', Format = 'string', Unknown = 1, Hidden = 1 },
    [12] = { Name = 'ChurchillNav_0x000c', Format = 'double', Unknown = 1, Hidden = 1 },
    [13] = { Name = 'ChurchillNav_0x000d', Format = 'double', Unknown = 1, Hidden = 1 },
    [14] = { Name = 'ChurchillNav_0x000e', Format = 'double', Unknown = 1, Hidden = 1 },
    [16] = { Name = 'ChurchillNav_0x0010', Format = 'double', Unknown = 1, Hidden = 1 },
    [17] = { Name = 'ChurchillNav_0x0011', Format = 'double', Unknown = 1, Hidden = 1 },
    [18] = { Name = 'ChurchillNav_0x0012', Format = 'double', Unknown = 1, Hidden = 1 },
    [20] = { Name = 'ChurchillNav_0x0014', Format = 'double', Unknown = 1, Hidden = 1 },
}

MISB.Unknown = {
    GROUPS = { [0] = 'MISB', [1] = 'MISB', [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'Other tags are extracted with the Unknown option.',
}

--------------------------------------------------------------------------------
-- Process KLV (Key-Length-Value) metadata
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 if anything was extracted
function MISB.ProcessKLV(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirEnd = dirStart + dirInfo.DirLen
    local rtnVal = 0
    local pos

    et:VerboseDir(dirInfo.DirName, nil, dirInfo.DirLen)

    -- loop through KLV packets
    pos = dirStart
    while pos < dirEnd - 1 do
        local tag = Get8u(dataPt, pos) pos = pos + 1
        local len = Get8u(dataPt, pos) pos = pos + 1
        if (len & 0x80) ~= 0 then
            local n = len & 0x7f
            if pos + n > dirEnd then break end
            len = 0
            for _ = 1, n do len = len * 256 + Get8u(dataPt, pos) pos = pos + 1 end
        end
        if pos + len > dirEnd then break end
        -- best guess at decoding the value
        local val
        local tagInfo = tagTablePtr[tag] or { }
        local format = tagInfo.Format or defaultFormat[len]
        if format then
            val = ReadValue(dataPt, pos, format, nil, len)
        else
            -- treat as string or binary data
            val = substr(dataPt, pos, len)
            if not matches(val, [[^[\t\n\r\x20-\x7e]*$]]) then
                val = { ref = 'SCALAR', value = val }
            end
        end
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            Start  = pos,
            Size   = len,
        })
        rtnVal = 1
        pos = pos + len
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Parse MISB metadata
-- Inputs: 0) ExifTool ref, 1) data ref, 2) tag table ref
-- Returns: 1 if something was extracted, 0 otherwise
function MISB.ParseMISB(et, dataPt, tagTablePtr)
    local endPos = #dataPt
    local rtnVal = 0
    local unknown = et.OPTIONS.Unknown
    local verbose = et.OPTIONS.Verbose
    local pos

    -- increment document number in case we find any tags
    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
    et.DOC_NUM = et.DOC_COUNT
    et.INDENT = et.INDENT .. '| '

    -- skip the 5-byte header (ref 1 pg. 68)
    --   0 - int8u: metadata service ID (0x00)
    --   1 - int8u: sequence number (increments each packet)
    --   2 - int8u: 0x0f (bits: cell fragmentation 00, decoder config 0, random access 0, reserved 1111)
    --   3-4 - int16u: data length (ie. packet length - 5)
    pos = 5
    while pos + 16 < endPos do
        local key = perl.unpack('H*', substr(dataPt, pos, 16))
        pos = pos + 16
        local len = Get8u(dataPt, pos)
        pos = pos + 1
        if (len & 0x80) ~= 0 then -- is this a BER long form integer? (Basic Encoding Rules)
            local n = len & 0x7f
            len = 0
            if pos + n > endPos then return rtnVal end
            for _ = 1, n do len = len * 256 + Get8u(dataPt, pos) pos = pos + 1 end
        end
        local tagInfo = tagTablePtr[key]
        local skip = false
        if not tagInfo then
            if ExifTool.perlTruthy(verbose) or ExifTool.perlTruthy(unknown) then
                -- (assume this is a data set, but it maybe be a simple tag)
                tagInfo = { Name = 'MISB_' .. key, SubDirectory = { TagTable = 'lexiftool.MISB.Unknown' } }
                et:VPrint(0, '  [adding ' .. tagInfo.Name .. ']\n')
                ExifTool.AddTagToTable(et, tagTablePtr, key, tagInfo)
            else
                -- skip this record
                pos = pos + len
                skip = true
            end
        end
        if not skip then
            if pos + len > endPos then
                len = endPos - pos
                et:VPrint(0, et.INDENT .. '(truncated record, only ' .. ExifTool.NumStr(len) .. ' bytes available)\n')
            end
            local dir = tagInfo.SubDirectory
            if dir.ByteOrder then SetByteOrder(dir.ByteOrder) end
            local dirInfo = {
                DataPt   = dataPt,
                DirStart = pos,
                DirLen   = len,
                DirName  = tagInfo.Name,
            }
            if MISB.ProcessKLV(et, dirInfo, et:GetTagTable(dir.TagTable)) == 1 then rtnVal = 1 end
            SetByteOrder('MM')
            pos = pos + len
        end
    end
    et.INDENT = et.INDENT:sub(1, -3)
    et.DOC_NUM = nil
    if rtnVal == 0 then et.DOC_COUNT = et.DOC_COUNT - 1 end
    return rtnVal
end

MISB.UASDatalink.PROCESS_PROC = MISB.ProcessKLV
MISB.Security.PROCESS_PROC = MISB.ProcessKLV
MISB.ChurchillNav.PROCESS_PROC = MISB.ProcessKLV
MISB.Unknown.PROCESS_PROC = MISB.ProcessKLV

return MISB
