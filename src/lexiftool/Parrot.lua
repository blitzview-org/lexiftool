--------------------------------------------------------------------------------
-- File:         lexiftool/Parrot.lua
-- Ported from:  lib/Image/ExifTool/Parrot.pm
--
-- Description:  Read timed metadata from Parrot drone videos
--
-- Revisions:    2019-10-23 - P. Harvey Created
--
-- References:   1) https://developer.parrot.com/docs/pdraw/metadata.html
--               --> changed to https://developer.parrot.com/docs/pdraw/video-metadata.html
--
-- Port notes:   complete: all thirteen tag tables (mett, V1, V2, V3, TimeStamp,
--               FollowMe, Automation, ARCoreAccel, ARCoreAccel0, ARCoreGyro,
--               ARCoreGyro0, ARCoreVideo, ARCoreCustom), the Composite table
--               and Process_mett, in upstream order.
--               Wired where upstream wires it: the 'mett' entry of
--               QuickTimeStream's Stream table (upstream
--               QuickTimeStream.pl's %Image::ExifTool::QuickTime::Stream).
--               `unpack("x${pos}a2n", $$dataPt)` uses the facade's 0-based
--               `off` argument instead of an interpolated `x${pos}` template
--               -- same result, but without one compiled-template cache
--               entry per byte position of a long 'mett' stream.
--               The VARS SORT_PROC/LONG_TAGS entries are carried verbatim
--               even though this port has no documentation generator to use
--               them.
--               Upstream's Process_mett hands its ARCore records to
--               HandleTag as `DirStart`/`DirLen`, which HandleTag does not
--               read (it takes `Start`/`Size`); the port reproduces that as
--               is, so an ARCore subdirectory sees the whole 'mett' buffer,
--               exactly as upstream does.
--               Upstream's V2 table spells its group override `Groups` in
--               lower case where every other table here uses `GROUPS`; that
--               is carried over verbatim, but the consequence is not: Perl
--               treats the stray key as a tag ID, coerces it to 0 (warning
--               `Argument "Groups" isn't numeric` on every V2 record) and
--               emits a bogus `Groups` tag holding byte 0 of the record.
--               Lua has no such string-to-number coercion, so the entry is
--               simply skipped and the bogus tag never appears.
--               No vendored test image carries Parrot 'mett' metadata.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
-- (GPS is required at the point of use, not at the top: a top-level require
--  would load it for every file that loads this module, and
--  BuildCompositeTags derives its worklist from `package.loaded`)
local Shift = require('lexiftool.Shift')
local perl = require('lexiftool.perl')
local substr = perl.substr
local unpack = perl.unpack
local split = perl.split
local join = perl.join
local ord = perl.ord
local num = perl.num
local matches = perl.matches
local subst = perl.subst
local sprintf = perl.sprintf
local str = perl.str
-- Perl stringifies a number back to "1" where Lua's tostring gives "1.0", so
-- the `"@a"` interpolations below go through NumStr (this port's Perl
-- number-to-string rule) instead of plain concatenation.
local NumStr = ExifTool.NumStr
local GetFloat = ExifTool.GetFloat

local Parrot = {}

-- tags found in Parrot 'mett' timed metadata (ref 1)
Parrot.mett = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    -- put the 'P' records first in the documentation
    VARS = {
        SORT_PROC = function(a, b) a = subst(a, 'P', 'A') b = subst(b, 'P', 'A') return perl.cmp(a, b) end,
        LONG_TAGS = 1
    },
    NOTES = [[
        Streaming metadata found in Parrot drone videos. See
        L<https://developer.parrot.com/docs/pdraw/metadata.html> for the
        specification.
    ]],
    P1 = {
        Name = 'ParrotV1',
        SubDirectory = { TagTable = 'lexiftool.Parrot.V1' },
    },
    P2 = {
        Name = 'ParrotV2',
        SubDirectory = { TagTable = 'lexiftool.Parrot.V2' },
    },
    P3 = {
        Name = 'ParrotV3',
        SubDirectory = { TagTable = 'lexiftool.Parrot.V3' },
    },
    E1 = {
        Name = 'ParrotTimeStamp',
        SubDirectory = { TagTable = 'lexiftool.Parrot.TimeStamp' },
    },
    E2 = {
        Name = 'ParrotFollowMe',
        SubDirectory = { TagTable = 'lexiftool.Parrot.FollowMe' },
    },
    E3 = {
        Name = 'ParrotAutomation',
        SubDirectory = { TagTable = 'lexiftool.Parrot.Automation' },
    },
    -- MetaType of timed metadata written by ARCore (see forum13653)
    ['application/arcore-accel'] = {
        Name = 'ARCoreAccel',
        SubDirectory = { TagTable = 'lexiftool.Parrot.ARCoreAccel', ByteOrder = 'II' },
    },
    ['application/arcore-accel-0'] = {
        Name = 'ARCoreAccel0',
        SubDirectory = { TagTable = 'lexiftool.Parrot.ARCoreAccel0', ByteOrder = 'II' },
    },
    ['application/arcore-gyro'] = {
        Name = 'ARCoreGyro',
        SubDirectory = { TagTable = 'lexiftool.Parrot.ARCoreGyro', ByteOrder = 'II' },
    },
    ['application/arcore-gyro-0'] = {
        Name = 'ARCoreGyro0',
        SubDirectory = { TagTable = 'lexiftool.Parrot.ARCoreGyro0', ByteOrder = 'II' },
    },
    ['application/arcore-video-0'] = {
        Name = 'ARCoreVideo',
        SubDirectory = { TagTable = 'lexiftool.Parrot.ARCoreVideo', ByteOrder = 'II' },
    },
    ['application/arcore-custom-event'] = {
        Name = 'ARCoreCustom',
        SubDirectory = { TagTable = 'lexiftool.Parrot.ARCoreCustom', ByteOrder = 'II' },
    },
}

-- tags found in the Parrot 'mett' V1 timed metadata (ref 1) [untested]
Parrot.V1 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'Parrot version 1 streaming metadata.',
    GROUPS = { [2] = 'Location' },
    [4] = {
        Name = 'DroneYaw',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end, -- convert from rad to deg
    },
    [6] = {
        Name = 'DronePitch',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end,
    },
    [8] = {
        Name = 'DroneRoll',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end,
    },
    [10] = {
        Name = 'CameraPan',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end,
    },
    [12] = {
        Name = 'CameraTilt',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end,
    },
    [14] = {
        Name = 'FrameView',        -- (W,X,Y,Z)
        Format = 'int16s[4]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x1000) end return join(' ', a) end,
    },
    [22] = {
        Name = 'ExposureTime',
        Groups = { [2] = 'Camera' },
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 / 1000 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [24] = {
        Name = 'ISO',
        Groups = { [2] = 'Camera' },
        Format = 'int16s',
    },
    [26] = {
        Name = 'WifiRSSI',
        Groups = { [2] = 'Device' },
        Format = 'int8s',
        PrintConv = function(_self, val) return perl.str(val) .. ' dBm' end,
    },
    [27] = {
        Name = 'Battery',
        Groups = { [2] = 'Device' },
        PrintConv = function(_self, val) return perl.str(val) .. ' %' end,
    },
    [28] = {
        Name = 'GPSLatitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x100000 end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [32] = {
        Name = 'GPSLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x100000 end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [36] = {
        Name = 'GPSAltitude',
        Format = 'int32s',
        Mask = 0xffffff00,
        ValueConv = function(_self, val) return num(val) / 0x100 end,
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [36.1] = {
        Name = 'GPSSatellites',    -- (SV count)
        Format = 'int32s',
        Mask = 0xff,
    },
    [40] = {
        Name = 'AltitudeFromTakeOff',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [44] = {
        Name = 'DistanceFromHome',
        Format = 'int32u',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
    },
    [48] = {
        Name = 'SpeedX',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [50] = {
        Name = 'SpeedY',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [52] = {
        Name = 'SpeedZ',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [54] = {
        Name = 'Binning',
        Groups = { [2] = 'Device' },
        Mask = 0x80,
    },
    [54.1] = {
        Name = 'FlyingState',
        Groups = { [2] = 'Device' },
        Mask = 0x7f,
        PrintConv = {
            [0] = 'Landed',
            [1] = 'Taking Off',
            [2] = 'Hovering',
            [3] = 'Flying',
            [4] = 'Landing',
            [5] = 'Emergency',
        },
    },
    [55] = {
        Name = 'Animation',
        Groups = { [2] = 'Device' },
        Mask = 0x80,
    },
    [55.1] = {
        Name = 'PilotingMode',
        Groups = { [2] = 'Device' },
        Mask = 0x7f,
        PrintConv = {
            [0] = 'Manual',
            [1] = 'Return Home',
            [2] = 'Flight Plan',
            [3] = 'Follow Me',
        },
    },
}

-- tags found in the Parrot 'mett' V2 timed metadata (ref 1) [untested]
Parrot.V2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    Groups = { [2] = 'Location' },
    NOTES = 'Parrot version 2 basic streaming metadata.',
    [4] = {
        Name = 'Elevation',
        Notes = 'estimated distance from ground',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [8] = {
        Name = 'GPSLatitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [12] = {
        Name = 'GPSLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [16] = {
        Name = 'GPSAltitude',
        Format = 'int32s',
        Mask = 0xffffff00,
        ValueConv = function(_self, val) return num(val) / 0x100 end,
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [16.1] = {
        Name = 'GPSSatellites',    -- (SV count)
        Format = 'int32s',
        Mask = 0xff,
    },
    [20] = {
        Name = 'GPSVelocityNorth', -- (m/s)
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [22] = {
        Name = 'GPSVelocityEast',  -- (m/s)
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [24] = {
        Name = 'GPSVelocityDown',  -- (m/s)
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [26] = {
        Name = 'AirSpeed',         -- (m/s)
        Format = 'int16s',
        RawConv = function(_self, val) if num(val) < 0 then return nil end return val end,
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [28] = {
        Name = 'DroneQuaternion',  -- (W,X,Y,Z)
        Format = 'int16s[4]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x4000) end return join(' ', a) end,
    },
    [36] = {
        Name = 'FrameView',        -- (W,X,Y,Z)
        Format = 'int16s[4]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x4000) end return join(' ', a) end,
    },
    [44] = {
        Name = 'CameraPan',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end, -- convert from rad to deg
    },
    [46] = {
        Name = 'CameraTilt',
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x1000 * 180 / 3.14159 end,
    },
    [48] = {
        Name = 'ExposureTime',
        Groups = { [2] = 'Camera' },
        Format = 'int16u',
        ValueConv = function(_self, val) return num(val) / 0x100 / 1000 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [50] = {
        Name = 'ISO',
        Groups = { [2] = 'Camera' },
        Format = 'int16u',
    },
    [52] = {
        Name = 'Binning',
        Groups = { [2] = 'Device' },
        Mask = 0x80,
    },
    [52.1] = {
        Name = 'FlyingState',
        Groups = { [2] = 'Device' },
        Mask = 0x7f,
        PrintConv = {
            [0] = 'Landed',
            [1] = 'Taking Off',
            [2] = 'Hovering',
            [3] = 'Flying',
            [4] = 'Landing',
            [5] = 'Emergency',
            [6] = 'User Takeoff',
            [7] = 'Motor Ramping',
            [8] = 'Emergency Landing',
        },
    },
    [53] = {
        Name = 'Animation',
        Groups = { [2] = 'Device' },
        Mask = 0x80,
    },
    [53.1] = {
        Name = 'PilotingMode',
        Groups = { [2] = 'Device' },
        Mask = 0x7f,
        PrintConv = {
            [0] = 'Manual',
            [1] = 'Return Home',
            [2] = 'Flight Plan',
            [3] = 'Follow Me / Tracking', -- (same as 'Tracking')
            [4] = 'Magic Carpet',
            [5] = 'Move To',
        },
    },
    [54] = {
        Name = 'WifiRSSI',
        Groups = { [2] = 'Device' },
        Format = 'int8s',
        PrintConv = function(_self, val) return perl.str(val) .. ' dBm' end,
    },
    [55] = {
        Name = 'Battery',
        Groups = { [2] = 'Device' },
        PrintConv = function(_self, val) return perl.str(val) .. ' %' end,
    },
}

-- tags found in the Parrot 'mett' V3 timed metadata (ref 1)
Parrot.V3 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'Parrot version 3 basic streaming metadata.',
    [4] = {
        Name = 'Elevation',
        Notes = 'estimated distance from ground',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [8] = {
        Name = 'GPSLatitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [12] = {
        Name = 'GPSLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [16] = {
        Name = 'GPSAltitude',
        Format = 'int32s',
        Mask = 0xffffff00,
        ValueConv = function(_self, val) return num(val) / 0x100 end,
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [16.1] = {
        Name = 'GPSSatellites',    -- (SV count)
        Format = 'int32s',
        Mask = 0xff,
    },
    [20] = {
        Name = 'GPSVelocityNorth', -- (m/s)
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [22] = {
        Name = 'GPSVelocityEast',  -- (m/s)
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [24] = {
        Name = 'GPSVelocityDown',  -- (m/s)
        Format = 'int16s',
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [26] = {
        Name = 'AirSpeed',         -- (m/s)
        Format = 'int16s',
        RawConv = function(_self, val) if num(val) < 0 then return nil end return val end,
        ValueConv = function(_self, val) return num(val) / 0x100 end,
    },
    [28] = {
        Name = 'DroneQuaternion',  -- (W,X,Y,Z)
        Format = 'int16s[4]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x4000) end return join(' ', a) end,
    },
    [36] = {
        Name = 'FrameBaseView',    -- (W,X,Y,Z without pan/tilt)
        Format = 'int16s[4]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x4000) end return join(' ', a) end,
    },
    [44] = {
        Name = 'FrameView',        -- (W,X,Y,Z)
        Format = 'int16s[4]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x4000) end return join(' ', a) end,
    },
    [52] = {
        Name = 'ExposureTime',
        Groups = { [2] = 'Camera' },
        Format = 'int16u',
        ValueConv = function(_self, val) return num(val) / 0x100 / 1000 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [54] = {
        Name = 'ISO',
        Groups = { [2] = 'Camera' },
        Format = 'int16u',
    },
    [56] = {
        Name = 'RedBalance',
        Groups = { [2] = 'Camera' },
        Format = 'int16u',
        ValueConv = function(_self, val) return num(val) / 0x4000 end,
    },
    [58] = {
        Name = 'BlueBalance',
        Groups = { [2] = 'Camera' },
        Format = 'int16u',
        ValueConv = function(_self, val) return num(val) / 0x4000 end,
    },
    [60] = {
        Name = 'FOV',              -- (degrees)
        Description = 'Field Of View',
        Notes = 'horizontal and vertical field of view in degrees',
        Groups = { [2] = 'Image' },
        Format = 'int16u[2]',
        ValueConv = function(_self, val) local a = split(' ', str(val)) for i = 1, #a do a[i] = NumStr(num(a[i]) / 0x100) end return join(' ', a) end,
    },
    [64] = {
        Name = 'LinkGoodput',
        Groups = { [2] = 'Device' },
        Format = 'int32u',
        Mask = 0xffffff00,
        PrintConv = function(_self, val) return perl.str(val) .. ' kbit/s' end,
    },
    [64.1] = {
        Name = 'LinkQuality',
        Groups = { [2] = 'Device' },
        Format = 'int32u',
        Notes = '0-5',
        Mask = 0xff,
    },
    [68] = {
        Name = 'WifiRSSI',
        Groups = { [2] = 'Device' },
        Format = 'int8s',
        PrintConv = function(_self, val) return perl.str(val) .. ' dBm' end,
    },
    [69] = {
        Name = 'Battery',
        Groups = { [2] = 'Device' },
        PrintConv = function(_self, val) return perl.str(val) .. ' %' end,
    },
    [70] = {
        Name = 'Binning',
        Groups = { [2] = 'Device' },
        Mask = 0x80,
    },
    [70.1] = {
        Name = 'FlyingState',
        Groups = { [2] = 'Device' },
        Mask = 0x7f,
        PrintConv = {
            [0] = 'Landed',
            [1] = 'Taking Off',
            [2] = 'Hovering',
            [3] = 'Flying',
            [4] = 'Landing',
            [5] = 'Emergency',
            [6] = 'User Takeoff',
            [7] = 'Motor Ramping',
            [8] = 'Emergency Landing',
        },
    },
    [71] = {
        Name = 'Animation',
        Groups = { [2] = 'Device' },
        Mask = 0x80,
    },
    [71.1] = {
        Name = 'PilotingMode',
        Groups = { [2] = 'Device' },
        Mask = 0x7f,
        PrintConv = {
            [0] = 'Manual',
            [1] = 'Return Home',
            [2] = 'Flight Plan',
            [3] = 'Follow Me / Tracking', -- (same as 'Tracking')
            [4] = 'Magic Carpet',
            [5] = 'Move To',
        },
    },
}

-- tags found in the Parrot 'mett' E1 timestamp timed metadata (ref 1)
Parrot.TimeStamp = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'Parrot streaming metadata timestamp extension.',
    GROUPS = { [2] = 'Time' },
    [4] = {
        Name = 'TimeStamp',
        Format = 'int64u',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
}

-- tags found in the Parrot 'mett' E2 follow-me timed metadata (ref 1) [untested]
Parrot.FollowMe = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'Parrot streaming metadata follow-me extension.',
    [4] = {
        Name = 'GPSTargetLatitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
    },
    [8] = {
        Name = 'GPSTargetLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
    },
    [12] = {
        Name = 'GPSTargetAltitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
    },
    [16] = {
        Name = 'Follow-meMode',
        Groups = { [2] = 'Device' },
        PrintConv = { BITMASK = {
            [0] = 'Follow-me enabled',
            [1] = 'Follow-me',           -- (0=Look-at-me! auggh. see AutomationFlags below)
            [2] = 'Angle locked',
        }},
    },
    [17] = {
        Name = 'Follow-meAnimation',
        Groups = { [2] = 'Device' },
        PrintConv = {
            [0] = 'None',
            [1] = 'Orbit',
            [2] = 'Boomerang',
            [3] = 'Parabola',
            [4] = 'Zenith',
        },
    },
}

-- tags found in the Parrot 'mett' E3 automation timed metadata (ref 1)
Parrot.Automation = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'Parrot streaming metadata automation extension.',
    [4] = {
        Name = 'GPSFramingLatitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
    },
    [8] = {
        Name = 'GPSFramingLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
    },
    [12] = {
        Name = 'GPSFramingAltitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
    },
    [16] = {
        Name = 'GPSDestLatitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
    },
    [20] = {
        Name = 'GPSDestLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x400000 end,
    },
    [24] = {
        Name = 'GPSDestAltitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return num(val) / 0x10000 end,
    },
    [28] = {
        Name = 'AutomationAnimation',
        Groups = { [2] = 'Device' },
        PrintConv = {
            [0] = 'None',
            [1] = 'Orbit',
            [2] = 'Boomerang',
            [3] = 'Parabola',
            [4] = 'Dolly Slide',
            [5] = 'Dolly Zoom',
            [6] = 'Reveal Vertical',
            [7] = 'Reveal Horizontal',
            [8] = 'Candle',
            [9] = 'Flip Front',
            [10] = 'Flip Back',
            [11] = 'Flip Left',
            [12] = 'Flip Right',
            [13] = 'Twist Up',
            [14] = 'Position Twist Up',
        },
    },
    [29] = {
        Name = 'AutomationFlags',
        Groups = { [2] = 'Device' },
        PrintConv = { BITMASK = {
            [0] = 'Follow-me enabled',
            [1] = 'Look-at-me enabled',  -- (really? opposite sense to Follow-meMode above!)
            [2] = 'Angle locked',
        }},
    },
}

-- ARCore Accel data (ref PH)
Parrot.ARCoreAccel = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'ARCore accelerometer data.',
    FIRST_ENTRY = 0,
    -- 00-04: always 10 34 16 1 29
    [4]  = {
        Name = 'AccelerometerUnknown',
        Format = 'undef[16]',
        Unknown = 1,
        ValueConv = function(_self, val) return join(' ', { unpack('Cx4Cx4Cx4C', val) }) end,
    },
    [5]  = { -- (NC)
        Name = 'Accelerometer',
        Format = 'undef[14]',
        RawConv = function(_self, val) return NumStr(GetFloat(val, 0)) .. ' ' .. NumStr(GetFloat(val, 5)) .. ' ' .. NumStr(GetFloat(val, 10)) end,
    },
    -- 05-08: float Accelerometer X
    -- 09: 37
    -- 10-13: float Accelerometer Y
    -- 14: 45
    -- 15-18: float Accelerometer Z
    -- 19: 48
    -- 20-24: 128-255
    -- 25: 246 then 247
    -- 26: 188
    -- 27: 2
    -- 28: 56
    -- 29-32: 128-255
    -- 33: increments slowly (about once every 56 samples or so)
}

-- ARCore Accel data (ref PH)
Parrot.ARCoreAccel0 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'ARCore accelerometer data.',
    FIRST_ENTRY = 0,
    [9]  = { -- (NC)
        Name = 'Accelerometer',
        Format = 'undef[14]',
        RawConv = function(_self, val) return NumStr(GetFloat(val, 0)) .. ' ' .. NumStr(GetFloat(val, 5)) .. ' ' .. NumStr(GetFloat(val, 10)) end,
    },
}

-- ARCore Gyro data (ref PH)
Parrot.ARCoreGyro = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'ARCore gyro data.',
    FIRST_ENTRY = 0,
    -- 00-04: always 10 34 16 3 29
    [4]  = {
        Name = 'GyroscopeUnknown',
        Format = 'undef[16]',
        Unknown = 1, -- always "29 37 45 48" in my sample, just like AccelerometerUnknown
        ValueConv = function(_self, val) return join(' ', { unpack('Cx4Cx4Cx4C', val) }) end,
    },
    [5]  = { -- (NC)
        Name = 'Gyroscope',
        Format = 'undef[14]',
        RawConv = function(_self, val) return NumStr(GetFloat(val, 0)) .. ' ' .. NumStr(GetFloat(val, 5)) .. ' ' .. NumStr(GetFloat(val, 10)) end,
    },
}

-- ARCore Gyro data (ref PH)
Parrot.ARCoreGyro0 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = 'ARCore gyro data.',
    FIRST_ENTRY = 0,
    [9]  = { -- (NC)
        Name = 'Gyroscope',
        Format = 'undef[14]',
        RawConv = function(_self, val) return NumStr(GetFloat(val, 0)) .. ' ' .. NumStr(GetFloat(val, 5)) .. ' ' .. NumStr(GetFloat(val, 10)) end,
    },
}

Parrot.ARCoreVideo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
}

Parrot.ARCoreCustom = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
}

Parrot.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    GPSDateTime = {
        TagID = 'Parrot-GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        SubDoc = 1,
        Require = {
            [0] = 'Parrot:GPSLatitude',  -- (avoids creating this tag for other videos)
            [1] = 'Main:CreateDate',
            [2] = 'SampleTime',
        },
        ValueConv = function(_self, val)
            local time = perl.str(val[1])
            local diff = num(val[2])
            -- handle time zone and shift to UTC
            local c1, c2, c3 = matches(time, [[([-+])(\d{1,2}):?(\d{2})$]])
            if c1 then
                time = subst(time, [[([-+])(\d{1,2}):?(\d{2})$]], '')
                local secs = ((num(c2) * 60) + num(c3)) * 60
                if c1 == '+' then secs = secs * -1 end
                diff = diff + secs
            elseif matches(time, [[Z$]]) then
                time = subst(time, [[Z$]], '')
            else
                -- shift from local time
                diff = diff + ExifTool.GetUnixTime(time, 1) - ExifTool.GetUnixTime(time)
            end
            -- upstream strips the sign off the STRINGIFIED $diff
            -- (`$diff =~ s/^-//`); same thing on the number here
            local sign = ''
            if diff < 0 then sign = '-' diff = -diff end
            time = time .. '.000'   -- add decimal seconds
            time = Shift.ShiftTime(time, sign .. '0:0:' .. diff) or time   -- (unchanged on error)
            return time .. 'Z'
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.Parrot', nil, Parrot)

--------------------------------------------------------------------------------
-- Parse Parrot 'mett' timed metadata
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- (this metadata design is really stupid -- you need to know the size of the base structures)
function Parrot.Process_mett(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirEnd = #dataPt
    local pos = dirInfo.DirStart or 0
    local metaType = et.MetaType or ''

    et:VerboseDir('Parrot mett', nil, dirEnd)

    if tagTbl[metaType] then
        -- loop through ARCore records
        while pos < dirEnd - 2 do
            if substr(dataPt, pos, 1) ~= '\x0a' then break end
            local len = ord(substr(dataPt, pos + 1, 1))
            if pos + len + 2 > dirEnd then
                et:Warn('Unexpected length for ' .. metaType .. ' record', 1)
                break
            end
            if len == 0 then len = dirEnd - pos - 2 end  -- use entire record if length is 0
            et:HandleTag(tagTbl, metaType, nil, {
                DataPt   = dataPt,
                DataPos  = dataPos,
                DirStart = pos,
                DirLen   = len,
                Base     = dirInfo.Base,
            })
            pos = pos + len + 2
        end
        return 1
    end
    while pos + 4 < dirEnd do
        -- (upstream: `unpack("x${pos}a2n", $$dataPt)` -- the facade takes the
        --  position as its 0-based `off` argument instead)
        local id, nwords = unpack('a2n', dataPt, pos)
        local size
        if not matches(id, [[^[EP]\d]]) then
            -- no ID so this should be a 60-byte V1 recording record, otherwise give up
            if dirEnd ~= 60 then break end
            id = 'P1' -- generate a fake ID
            -- ignore the first 4 of the record so the fields will align with
            -- the other V1 records (unfortunately, this means that we won't
            -- decode the V1 recording frame timestamp, but oh well)
            pos = pos + 4
            size = dirEnd - pos
        -- must override size for P3 and P3 records since it includes the extensions (augh!)
        elseif id == 'P2' then
            size = 56
        elseif id == 'P3' then
            size = 72
        else
            size = nwords * 4 + 4
        end
        if pos + size > dirEnd then break end
        et:HandleTag(tagTbl, id, nil, {
            DataPt  = dataPt,
            DataPos = dataPos,
            Base    = dirInfo.Base,
            Start   = pos,
            Size    = size,
        })
        pos = pos + size
    end
    return 1
end

Parrot.mett.PROCESS_PROC = Parrot.Process_mett

return Parrot
