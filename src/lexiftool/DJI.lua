--------------------------------------------------------------------------------
-- File:         lexiftool/DJI.lua
-- Ported from:  lib/Image/ExifTool/DJI.pm
--
-- Description:  DJI Phantom maker notes tags
--
-- Revisions:    2016-07-25 - P. Harvey Created
--               2017-06-23 - PH Added XMP tags
--               2024-12-04 - PH Added protobuf tags
--
-- Port notes:   complete: %knownProtocol, all ten tag tables (Main, Info,
--               ThermalParams, ThermalParams2, ThermalParams3, XMP, Glamour,
--               Protobuf, DroneInfo, GimbalInfo, FrameInfo, GPSInfo) and both
--               subs (ProcessSettings, ProcessDJIInfo), in upstream order.
--               Wired where upstream wires it: MakerNotes.Main's
--               `MakerNoteDJIInfo`/`MakerNoteDJI` entries, Exif.Main's
--               0xc634 `MakerNoteDJIInfo` branch, XMP.Main's 'drone-dji'
--               namespace, QuickTime.UserData's DJI block (`btec`
--               GlamourSettings), QuickTimeStream.Stream's 'djmd'/'dbgi'
--               timed-metadata entries and the DJI branches of ProcessJPEG's
--               APP3-APP7 dispatch in lexiftool.lua.
--               `WRITE_PROC`/`CHECK_PROC` of Main are Exif's, taken from
--               WriteExif directly (as SonyIDC.lua does) rather than through
--               WriteExif.lua's MakerNote wiring list.
--               The `Condition` of the Mavic 4 Pro / Mini 5 Pro GPSInfo tags
--               is carried verbatim including upstream's `=` (an assignment,
--               not a comparison -- it sets CoordUnits and is always true).
--               No vendored test image or video carries DJI metadata; the
--               tables and both subs were verified against upstream with
--               hand-built samples (see the port task notes).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local XMP = require('lexiftool.XMP')
local GPS = require('lexiftool.GPS')
local Protobuf = require('lexiftool.Protobuf')
local perl = require('lexiftool.perl')
local substr = perl.substr
local length = perl.length
local split = perl.split
local matches = perl.matches
local eachMatch = perl.eachMatch
local truthy = perl.truthy
local num = perl.num
local sprintf = perl.sprintf
local perlStr = perl.str

local DJI = {}

DJI.knownProtocol = {
    ['dvtm_ac203.proto'] = 1,       -- Osmo Action 4
    ['dvtm_ac204.proto'] = 1,       -- Osmo Action 5
    ['dvtm_ac206.proto'] = 1,       -- Osmo Action 6
    ['dvtm_AVATA2.proto'] = 1,      -- Avata 2
    ['dvtm_wm265e.proto'] = 1,      -- Mavic 3
    ['dvtm_pm320.proto'] = 1,       -- Matrice 30
    ['dvtm_Mini4_Pro.proto'] = 1,   -- Mini 4
    ['dvtm_dji_neo.proto'] = 1,     -- Neo
    ['dvtm_Air3.proto'] = 1,        -- Air 3
    ['dvtm_Air3s.proto'] = 1,       -- Air 3s
    ['dvtm_PP-101.proto'] = 1,      -- Osmo Pocket 3
    ['dvtm_oq101.proto'] = 1,       -- Osmo 360
    ['dvtm_wa345e.proto'] = 1,      -- Matrice 4E
    ['dvtm_wm261.proto'] = 1,       -- Mavic 3 Pro
    ['dvtm_Mavic4.proto'] = 1,      -- Mavic 4 Pro
    ['dvtm_Mini5Pro.proto'] = 1,    -- Mini 5 Pro
-- dvtm_wm169.proto seems to be DJI O3 but the structure is unknown
}


-- (upstream spreads %convFloat2 into the tag hashes below; this helper is
--  that spread)
local function convFloat2(t)
    t.PrintConv = function(_self, val) return sprintf('%+.2f', num(val)) end
    t.PrintConvInv = function(_self, val) return val end
    return t
end

-- DJI maker notes (ref PH, mostly educated guesses based on DJI QuickTime::UserData tags)
DJI.Main = {
    -- (a top-level require of WriteExif would pull in nearly every vendor
    --  module at load time, and BuildCompositeTags derives its worklist
    --  from `package.loaded` -- see the note there)
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        This table lists tags found in the maker notes of images from some DJI
        Phantom drones.
    ]],
    [0x01] = { Name = 'Make',       Writable = 'string' },
  -- 0x02 - int8u[4]: "1 0 0 0", "1 1 0 0"
    [0x03] = convFloat2{ Name = 'SpeedX',     Writable = 'float' }, -- (guess)
    [0x04] = convFloat2{ Name = 'SpeedY',     Writable = 'float' }, -- (guess)
    [0x05] = convFloat2{ Name = 'SpeedZ',     Writable = 'float' }, -- (guess)
    [0x06] = convFloat2{ Name = 'Pitch',      Writable = 'float' },
    [0x07] = convFloat2{ Name = 'Yaw',        Writable = 'float' },
    [0x08] = convFloat2{ Name = 'Roll',       Writable = 'float' },
    [0x09] = convFloat2{ Name = 'CameraPitch',Writable = 'float' },
    [0x0a] = convFloat2{ Name = 'CameraYaw',  Writable = 'float' },
    [0x0b] = convFloat2{ Name = 'CameraRoll', Writable = 'float' },
}

-- DJI debug maker notes
DJI.Info = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Tags written by some DJI drones.',
    VARS = { LONG_TAGS = 2 },
    ae_dbg_info         = { Name = 'AEDebugInfo' },
    ae_histogram_info   = { Name = 'AEHistogramInfo' },
    ae_local_histogram  = { Name = 'AELocalHistogram' },
    ae_liveview_histogram_info  = { Name = 'AELiveViewHistogramInfo' },
    ae_liveview_local_histogram = { Name = 'AELiveViewLocalHistogram' },
    awb_dbg_info        = { Name = 'AWBDebugInfo' },
    af_dbg_info         = { Name = 'AFDebugInfo' },
    hiso                = { Name = 'Histogram' },
    xidiri              = { Name = 'Xidiri' },
   ['GimbalDegree(Y,P,R)']= { Name = 'GimbalDegree' },
   ['FlightDegree(Y,P,R)']= { Name = 'FlightDegree' },
    adj_dbg_info        = { Name = 'ADJDebugInfo' },
    sensor_id           = { Name = 'SensorID' },
   ['FlightSpeed(X,Y,Z)'] = { Name = 'FlightSpeed' },
    hyperlapse_dbg_info = { Name = 'HyperlapsDebugInfo' },
}

-- thermal parameters in APP4 of DJI ZH20T images (ref forum11401)
DJI.ThermalParams = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP4', [2] = 'Image' },
    NOTES = 'Thermal parameters extracted from APP4 of DJI RJPEG files from the ZH20T.',
  -- 0x00 - 0xaa551206 - temperature header magic number
    [0x24] = { Name = 'K1', Format = 'float' },
    [0x28] = { Name = 'K2', Format = 'float' },
    [0x2c] = { Name = 'K3', Format = 'float' },
    [0x30] = { Name = 'K4', Format = 'float' },
    [0x34] = { Name = 'KF', Format = 'float' },
    [0x38] = { Name = 'B1', Format = 'float' },
    [0x3c] = { Name = 'B2', Format = 'float' },
    [0x44] = { Name = 'ObjectDistance',     Format = 'int16u' },
    [0x46] = { Name = 'RelativeHumidity',   Format = 'int16u' },
    [0x48] = { Name = 'Emissivity',         Format = 'int16u' },
    [0x4a] = { Name = 'Reflection',         Format = 'int16u',  },
    [0x4c] = { Name = 'AmbientTemperature', Format = 'int16u' }, -- (aka D1)
    [0x50] = { Name = 'D2', Format = 'int32s' },
    [0x54] = { Name = 'KJ', Format = 'int16u' },
    [0x56] = { Name = 'DB', Format = 'int16u' },
    [0x58] = { Name = 'KK', Format = 'int16u' },
  -- 0x500 - 0x55aa1206 - device header magic number
    -- (nothing yet decoded from device header)
}

-- thermal parameters in APP4 of DJI M3T, H20N, M2EA and some M30T images (ref PH/forum11401)
DJI.ThermalParams2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP4', [2] = 'Image' },
    NOTES = 'Thermal parameters extracted from APP4 of DJI M3T RJPEG files.',
    [0x00] = { Name = 'AmbientTemperature',  Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f C', num(val)) end }, -- (NC)
    [0x04] = { Name = 'ObjectDistance',      Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f m', num(val)) end },
    [0x08] = { Name = 'Emissivity',          Format = 'float', PrintConv = function(_self, val) return sprintf('%.2f', num(val)) end },
    [0x0c] = { Name = 'RelativeHumidity',    Format = 'float', PrintConv = function(_self, val) return sprintf('%g %%', num(val) * 100) end },
    [0x10] = { Name = 'ReflectedTemperature',Format = 'float', PrintConv = function(_self, val) return sprintf('%.1f C', num(val)) end },
    [0x65] = { Name = 'IDString',            Format = 'string[16]' }, -- (NC)
}

-- thermal parameters in APP4 of some DJI M30T images (ref PH)
DJI.ThermalParams3 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP4', [2] = 'Image' },
    NOTES = 'Thermal parameters extracted from APP4 of some DJI RJPEG files.',
  -- 0x00 - 0xaa553800 - params3 magic number
    [0x04] = { Name = 'RelativeHumidity',    Format = 'int16u' },
    [0x06] = { Name = 'ObjectDistance',      Format = 'int16u', ValueConv = function(_self, val) return num(val) / 10 end },
    [0x08] = { Name = 'Emissivity',          Format = 'int16u', ValueConv = function(_self, val) return num(val) / 100 end },
    [0x0a] = { Name = 'ReflectedTemperature',Format = 'int16u', ValueConv = function(_self, val) return num(val) / 10 end },
}

DJI.XMP = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-drone-dji', [2] = 'Location' },
    NAMESPACE = 'drone-dji',
    TABLE_DESC = 'XMP DJI',
    VARS = { ID_FMT = 'none' },
    NOTES = 'XMP tags used by DJI for images from drones.',
    AbsoluteAltitude  = { Writable = 'real' },
    RelativeAltitude  = { Writable = 'real' },
    GimbalRollDegree  = { Writable = 'real' },
    GimbalYawDegree   = { Writable = 'real' },
    GimbalPitchDegree = { Writable = 'real' },
    FlightRollDegree  = { Writable = 'real' },
    FlightYawDegree   = { Writable = 'real' },
    FlightPitchDegree = { Writable = 'real' },
    GpsLatitude = {
        Name = 'GPSLatitude',
        Writable = 'real',
        Avoid = 1,
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lat') end,
    },
    GpsLongtitude = { -- [sic] (misspelt in DJI original file)
        Name = 'GPSLongtitude',
        Writable = 'real',
        Avoid = 1, -- (in case someone tries to write "GPSLong*")
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lon') end,
    },
    GpsLongitude = { --PH (NC)
        Name = 'GPSLongitude',
        Writable = 'real',
        Avoid = 1,
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lon') end,
    },
    FlightXSpeed  = { Writable = 'real' },
    FlightYSpeed  = { Writable = 'real' },
    FlightZSpeed  = { Writable = 'real' },
    CamReverse    = { }, -- integer?
    GimbalReverse = { }, -- integer?
    SelfData      = { Groups = { [2] = 'Image' } },
    CalibratedFocalLength    = { Writable = 'real', Groups = { [2] = 'Image' } },
    CalibratedOpticalCenterX = { Writable = 'real', Groups = { [2] = 'Image' } },
    CalibratedOpticalCenterY = { Writable = 'real', Groups = { [2] = 'Image' } },
    RtkFlag       = { }, -- integer?
    RtkStdLon     = { Writable = 'real' },
    RtkStdLat     = { Writable = 'real' },
    RtkStdHgt     = { Writable = 'real' },
    DewarpData    = { Groups = { [2] = 'Image' } },
    DewarpFlag    = { Groups = { [2] = 'Image' } }, -- integer?
    Latitude = {
        Name = 'Latitude',
        Writable = 'real',
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lat') end,
    },
    Longitude = {
        Name = 'Longitude',
        Writable = 'real',
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lon') end,
    },
}

DJI.Glamour = {
    GROUPS = { [0] = 'QuickTime', [1] = 'DJI', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'Glamour settings used by some DJI models.',
    beauty_enable   = 'BeautyEnable',
    smoother        = 'Smoother',
    whitening       = 'Whitening',
    face_slimming   = 'FaceSlimming',
    eye_enlarge     = 'EyeEnlarge',
    nose_slimming   = 'NoseSlimming',
    mouth_beautify  = 'MouthModify',
    teeth_whitening = 'TeethWhitening',
    leg_longer      = 'LegLonger',
    head_shrinking  = 'HeadShrinking',
    lipstick        = 'Lipstick',
    blush           = 'Blush',
    dark_circle     = 'DarkCircle',
    acne_spot_removal='AcneSpotRemoval',
    eyebrows        = 'Eyebrows',
}

-- metadata in protobuf format (djmd and dbgi meta types, ref PH)
DJI.Protobuf = {
    GROUPS = { [0] = 'Protobuf', [1] = 'DJI', [2] = 'Camera' },
    TAG_PREFIX = '',
    PROCESS_PROC = Protobuf.ProcessProtobuf,
    NOTES = [[
        Tags found in protobuf-format DJI djmd and dbgi timed metadata.  The known
        tags listed below are extracted by default, but unknown djmd tags may be
        extracted as well by setting the Unknown option to 1, or 2 to also extract
        unknown dbgi debug tags.  Tag ID's are composed of the corresponding .proto
        file name combined with the hierarchical protobuf field numbers.

        ExifTool currently extracts timed GPS plus a few other tags from DJI devices
        which use the following protocols:  dvtm_AVATA2.proto (Avata 2),
        dvtm_ac203.proto (Osmo Action 4), dvtm_ac204.proto (Osmo Action 5),
        dvtm_ac206.proto (Osmo Action 6),dvtm_wm265e.proto (Mavic 3),
        dvtm_pm320.proto (Matrice 30), dvtm_Mini4_Pro.proto (Mini 4 Pro),
        dvtm_dji_neo.proto (DJI Neo), dvtm_Air3.proto (Air 3), dvtm_Air3s.proto (Air
        3s), dvtm_PP-101.proto (Osmo Pocket 3), dvtm_oq101.proto (Osmo 360),
        dvtm_wa345e.proto (Matrice 4E), dvtm_wm261.proto (Mavic 3 Pro),
        dvtm_Mavic4.proto (Mavic 4 Pro) and dvtm_Mini5Pro.proto (Mini 5 Pro).

        Note that with the protobuf format, numerical tags missing from the output
        for a given protocol should be considered to have the default value of 0.
    ]],
    Protocol = {
        Notes = "typically protobuf field 1-1-1, but ExifTool doesn't rely on this",
        RawConv = function(self, val)
            if not (DJI.knownProtocol[val] or matches(val, [[^dbginfo]])) then
                self:Warn('Unknown protocol ' .. val .. ' (please submit sample for testing)')
            end
            return val
        end,
    },
--
-- Osmo Action 4
--
    ['dvtm_ac203_1-1-5'] = { Name = 'SerialNumber', Notes = 'Osmo Action 4' }, -- (NC)
   -- dvtm_ac203_1-1-6 - some version number
    ['dvtm_ac203_1-1-10'] = 'Model',
    ['dvtm_ac203_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    --WRONG (forum17996) 'dvtm_ac203_3-2-2-1' => { Name => 'ISO', Format => 'float' },
    ['dvtm_ac203_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' }, --forum17996
    ['dvtm_ac203_3-2-3-1'] = { Name = 'ISO', Format = 'float' }, --forum17996
    ['dvtm_ac203_3-2-4-1'] = { -- (NC)
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_ac203_3-2-6-1'] = { Name = 'ColorTemperature', Format = 'unsigned' }, -- (NC)
   -- dvtm_ac203_3-2-9-1 - looks like Z accerometer measurement, but 2 and 3 don't look like other components
    ['dvtm_ac203_3-2-10-2'] = { Name = 'AccelerometerX', Format = 'float' } , -- (NC) left/right
    ['dvtm_ac203_3-2-10-3'] = { Name = 'AccelerometerY', Format = 'float' } , -- (NC) front/back
    ['dvtm_ac203_3-2-10-4'] = { Name = 'AccelerometerZ', Format = 'float' } , -- (NC) up/down
   -- dvtm_ac203_3-4-1-4 - model code?
    ['dvtm_ac203_3-4-2-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_ac203_3-4-2-2'] = {
        Name = 'GPSAltitude',
        Groups = { [2] = 'Location' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1000 end,
    },
    ['dvtm_ac203_3-4-2-6-1'] = {
        Name = 'GPSDateTime',
        Format = 'string',
        Groups = { [2] = 'Time' },
        RawConv = function(self, val) self.GPSDateTime = val return val end,
        ValueConv = function(_self, val) return (perlStr(val):gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- Osmo Action 5
--
    ['dvtm_ac204_1-1-5'] = { Name = 'SerialNumber', Notes = 'Osmo Action 5' }, -- (NC)
   -- dvtm_ac204_1-1-6 - some version number
    ['dvtm_ac204_1-1-10'] = 'Model',
    ['dvtm_ac204_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_ac204_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' }, --forum17996
    ['dvtm_ac204_3-2-3-1'] = { Name = 'ISO', Format = 'float' }, --forum17996
    ['dvtm_ac204_3-2-4-1'] = { -- (NC)
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_ac204_3-2-6-1'] = { Name = 'ColorTemperature', Format = 'unsigned' }, -- (NC)
    ['dvtm_ac204_3-2-10-2'] = { Name = 'AccelerometerX', Format = 'float' } , -- (NC) left/right
    ['dvtm_ac204_3-2-10-3'] = { Name = 'AccelerometerY', Format = 'float' } , -- (NC) front/back
    ['dvtm_ac204_3-2-10-4'] = { Name = 'AccelerometerZ', Format = 'float' } , -- (NC) up/down
   -- dvtm_ac204_3-4-1-4 - model code?
    ['dvtm_ac204_3-4-2-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_ac204_3-4-2-2'] = {
        Name = 'GPSAltitude',
        Groups = { [2] = 'Location' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1000 end,
    },
    ['dvtm_ac204_3-4-2-6-1'] = {
        Name = 'GPSDateTime',
        Format = 'string',
        Groups = { [2] = 'Time' },
        RawConv = function(self, val) self.GPSDateTime = val return val end,
        ValueConv = function(_self, val) return (perlStr(val):gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- Osmo Action 6 (same as Action 5)
--
    ['dvtm_ac206_1-1-5'] = { Name = 'SerialNumber', Notes = 'Osmo Action 6' }, -- (NC)
   -- dvtm_ac206_1-1-6 - some version number
    ['dvtm_ac206_1-1-10'] = 'Model',
   -- dvtm_ac206_2-1-3 - 'video'
    ['dvtm_ac206_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_ac206_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' }, --forum17996
    ['dvtm_ac206_3-2-3-1'] = { Name = 'ISO', Format = 'float' }, --forum17996
    ['dvtm_ac206_3-2-4-1'] = { -- (NC)
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_ac206_3-2-6-1'] = { Name = 'ColorTemperature', Format = 'unsigned' }, -- (NC)
    ['dvtm_ac206_3-2-10-2'] = { Name = 'AccelerometerX', Format = 'float' } , -- (NC) left/right
    ['dvtm_ac206_3-2-10-3'] = { Name = 'AccelerometerY', Format = 'float' } , -- (NC) front/back
    ['dvtm_ac206_3-2-10-4'] = { Name = 'AccelerometerZ', Format = 'float' } , -- (NC) up/down
   -- dvtm_ac206_3-4-1-4 - model code?
    ['dvtm_ac206_3-4-2-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_ac206_3-4-2-2'] = {
        Name = 'GPSAltitude',
        Groups = { [2] = 'Location' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1000 end,
    },
    ['dvtm_ac206_3-4-2-6-1'] = {
        Name = 'GPSDateTime',
        Format = 'string',
        Groups = { [2] = 'Time' },
        RawConv = function(self, val) self.GPSDateTime = val return val end,
        ValueConv = function(_self, val) return (perlStr(val):gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- Avata 2
--
   -- dvtm_AVATA2_1-1-2 - some version number
   -- dvtm_AVATA2_1-1-3 - some version number
    ['dvtm_AVATA2_1-1-5'] = { Name = 'SerialNumber', Notes = 'Avata 2' }, -- (NC)
    ['dvtm_AVATA2_1-1-10'] = 'Model',
   -- dvtm_AVATA2_2-2-1-4 - model code?
    ['dvtm_AVATA2_2-2-3-1'] = 'SerialNumber2', -- (NC)
    ['dvtm_AVATA2_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_AVATA2_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_AVATA2_3-1-2'] = { -- (also 3-2-1-6 and 3-4-1-6)
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        -- milliseconds, but I don't know what the zero is
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
   -- dvtm_AVATA2_3-2-1-4 - model code?
   -- dvtm_AVATA2_3-2-1-5 - frame rate?
    ['dvtm_AVATA2_3-2-2-1'] = { Name = 'ISO', Format = 'float' }, -- (NC)
    ['dvtm_AVATA2_3-2-4-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_AVATA2_3-2-6-1'] = { Name = 'ColorTemperature', Format = 'unsigned' }, -- (NC)
    ['dvtm_AVATA2_3-2-10-1'] = { -- (NC)
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
   -- dvtm_AVATA2_3-4-1-4 - model code?
    ['dvtm_AVATA2_3-4-3'] = { -- (NC)
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_AVATA2_3-4-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_AVATA2_3-4-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
    ['dvtm_AVATA2_3-4-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
--
-- Mavic 3
--
    ['dvtm_wm265e_1-1-5'] = { Name = 'SerialNumber', Notes = 'Mavic 3' }, -- (confirmed)
    ['dvtm_wm265e_1-1-10'] = 'Model',
    ['dvtm_wm265e_2-2'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_wm265e_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
   -- dvtm_wm265e_3-2-1-4 - model code?
    ['dvtm_wm265e_3-2-2-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_wm265e_3-2-3-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
   -- dvtm_wm265e_3-2-5-1 - unknown rational (xxxx / 1000)
    ['dvtm_wm265e_3-2-6-1'] = { Name = 'DigitalZoom', Format = 'float' },
    ['dvtm_wm265e_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_wm265e_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_wm265e_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_wm265e_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_wm265e_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
--
-- Matrice 30
--
    ['dvtm_pm320_1-1-5'] = { Name = 'SerialNumber', Notes = 'Matrice 30' },
    ['dvtm_pm320_1-1-10'] = 'Model',
    ['dvtm_pm320_2-2'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_pm320_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_pm320_3-2-2-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_pm320_3-2-3-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_pm320_3-2-4-1'] = { -- (NC)
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    ['dvtm_pm320_3-2-6-1'] = { Name = 'DigitalZoom', Format = 'float' },
    ['dvtm_pm320_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_pm320_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_pm320_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_pm320_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_pm320_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
--
-- Mini 4 Pro
--
    ['dvtm_Mini4_Pro_1-1-5'] = { Name = 'SerialNumber', Notes = 'Mini 4 Pro' },
    ['dvtm_Mini4_Pro_1-1-10'] = 'Model',
    ['dvtm_Mini4_Pro_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_Mini4_Pro_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_Mini4_Pro_3-2-7-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_Mini4_Pro_3-2-10-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_Mini4_Pro_3-2-11-1'] = {
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    ['dvtm_Mini4_Pro_3-2-32-1'] = { Name = 'ColorTemperature', Format = 'unsigned' },
    ['dvtm_Mini4_Pro_3-2-37-1'] = { Name = 'Temperature', Format = 'float' }, -- (NC)
    ['dvtm_Mini4_Pro_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_Mini4_Pro_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_Mini4_Pro_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_Mini4_Pro_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
    ['dvtm_Mini4_Pro_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
--
-- DJI Neo (very similar to AVATA2)
--
   -- dvtm_dji_neo_1-1-2 - some version number
   -- dvtm_dji_neo_1-1-3 - some version number
    ['dvtm_dji_neo_1-1-5'] = { Name = 'SerialNumber', Notes = 'DJI Neo' }, -- (NC)
    ['dvtm_dji_neo_1-1-10'] = 'Model',
   -- dvtm_dji_neo_2-2-1-4 - model code?
   -- dvtm_dji_neo_2-2-2-1 - some firmware version?
   -- dvtm_dji_neo_2-2-2-2 - some version number?
    ['dvtm_dji_neo_2-2-3-1'] = 'SerialNumber2', -- (NC)
    ['dvtm_dji_neo_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_dji_neo_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_dji_neo_3-1-2'] = { -- (also 3-2-1-6 and 3-4-1-6)
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        -- milliseconds, but I don't know what the zero is
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
   -- dvtm_dji_neo_3-2-1-4 - model code?
   -- dvtm_dji_neo_3-2-1-5 - frame rate?
    ['dvtm_dji_neo_3-2-2-1'] = { Name = 'ISO', Format = 'float' }, -- (NC)
    ['dvtm_dji_neo_3-2-4-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_dji_neo_3-2-6-1'] = { Name = 'ColorTemperature', Format = 'unsigned' }, -- (NC)
    ['dvtm_dji_neo_3-2-10-1'] = { -- (NC)
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
   -- dvtm_dji_neo_3-4-1-4 - model code?
    ['dvtm_dji_neo_3-4-3'] = { -- (NC)
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_dji_neo_3-4-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_dji_neo_3-4-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
--
-- Air 3
--
    ['dvtm_Air3_1-1-5'] = { Name = 'SerialNumber', Notes = 'Air 3' },
    ['dvtm_Air3_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_Air3_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' }, -- (NC)
    ['dvtm_Air3_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
    ['dvtm_Air3_3-2-7-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_Air3_3-2-10-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_Air3_3-2-32-1'] = { Name = 'ColorTemperature', Format = 'unsigned' },
    ['dvtm_Air3_3-2-11-1'] = {
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    ['dvtm_Air3_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_Air3_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_Air3_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_Air3_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_Air3_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
--
-- Air 3s (same structure as Air 3)
--
    ['dvtm_Air3s_1-1-5'] = { Name = 'SerialNumber', Notes = 'Air 3s' },
    ['dvtm_Air3s_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_Air3s_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' }, -- (NC)
    ['dvtm_Air3s_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
    ['dvtm_Air3s_3-2-7-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_Air3s_3-2-10-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_Air3s_3-2-32-1'] = { Name = 'ColorTemperature', Format = 'unsigned' },
    ['dvtm_Air3s_3-2-11-1'] = {
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    ['dvtm_Air3s_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_Air3s_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_Air3s_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_Air3s_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_Air3s_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
--
-- Osmo 360 (similar to Action 4/5/6)
--
    ['dvtm_oq101_1-1-5'] = { Name = 'SerialNumber', Notes = 'Osmo 360' },
    ['dvtm_oq101_1-1-10'] = 'Model',
    ['dvtm_oq101_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_oq101_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
    ['dvtm_oq101_3-2-3-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_oq101_3-2-4-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_oq101_3-2-6-1'] = { Name = 'ColorTemperature', Format = 'unsigned' },
    ['dvtm_oq101_1-14-1'] = {
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    ['dvtm_oq101_3-4-2-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_oq101_3-4-2-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_oq101_3-4-2-6-1'] = {
        Name = 'GPSDateTime',
        Format = 'string',
        Groups = { [2] = 'Time' },
        RawConv = function(self, val) self.GPSDateTime = val return val end,
        ValueConv = function(_self, val) return (perlStr(val):gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['dvtm_oq101_3-2-10-2'] = { Name = 'AccelerometerX', Format = 'float' },
    ['dvtm_oq101_3-2-10-3'] = { Name = 'AccelerometerY', Format = 'float' },
    ['dvtm_oq101_3-2-10-4'] = { Name = 'AccelerometerZ', Format = 'float' },
--
-- Osmo Pocket 3
--
    ['dvtm_PP-101_1-1-5'] = { Name = 'SerialNumber', Notes = 'Osmo Pocket 3' },
    ['dvtm_PP-101_1-1-10'] = 'Model',
    ['dvtm_PP-101_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_PP-101_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_PP-101_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
    ['dvtm_PP-101_3-2-9-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_PP-101_3-2-10-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_PP-101_3-2-24-1'] = { Name = 'ColorTemperature', Format = 'unsigned' },
--
-- Matrice 4E
--
    ['dvtm_wa345e_1-1-5'] = { Name = 'SerialNumber', Notes = 'Matrice 4E' },
    ['dvtm_wa345e_1-1-10'] = 'Model',
    ['dvtm_wa345e_2-2'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_wa345e_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_wa345e_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
    ['dvtm_wa345e_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_wa345e_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_wa345e_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_wa345e_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_wa345e_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
    ['dvtm_wa345e_3-3-4-6-1'] = {
        Name = 'GPSDateTime',
        Format = 'string',
        Groups = { [2] = 'Time' },
        RawConv = function(self, val) self.GPSDateTime = val return val end,
        ValueConv = function(_self, val) return (perlStr(val):gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- Mavic 3 Pro
--
    ['dvtm_wm261_1-1-5'] = { Name = 'SerialNumber', Notes = 'Mavic 3 Pro' },
    ['dvtm_wm261_1-1-10'] = 'Model',
    ['dvtm_wm261_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_wm261_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_wm261_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
    ['dvtm_wm261_3-2-9-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_wm261_3-2-10-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_wm261_3-2-11-1']= {
        Name = 'FNumber',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    ['dvtm_wm261_3-3-3'] = {
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_wm261_3-3-4-1'] = {
        Name = 'GPSInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_wm261_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_wm261_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end },
    ['dvtm_wm261_3-4-3'] = {
        Name = 'GimbalInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.GimbalInfo' },
    },
    ['dvtm_wm261_3-3-4-6-1'] = {
        Name = 'GPSDateTime',
        Format = 'string',
        Groups = { [2] = 'Time' },
        RawConv = function(self, val) self.GPSDateTime = val return val end,
        ValueConv = function(_self, val) return (perlStr(val):gsub('%-', ':')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- Mavic 4 Pro
--
    ['dvtm_Mavic4_1-1-5'] = { Name = 'SerialNumber', Notes = 'Mavic 4 Pro' },
    ['dvtm_Mavic4_1-1-10'] = 'Model',
   -- dvtm_Mavic4_2-2-1-4 - model code?
   -- dvtm_Mavic4_2-2-1-5 - frame rate again
    ['dvtm_Mavic4_2-3'] = {
        Name = 'FrameInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.FrameInfo' },
    },
    ['dvtm_Mavic4_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' },
    ['dvtm_Mavic4_3-1-2'] = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return num(val) / 1e6 end,
    },
   -- dvtm_Mavic4_3-2-1-4 - string: model code?
   -- dvtm_Mavic4_3-2-1-5 - float: frame rate again
    ['dvtm_Mavic4_3-2-9-1'] = { Name = 'ISO', Format = 'float' },
    ['dvtm_Mavic4_3-2-10-1'] = {
        Name = 'ShutterSpeed',
        Format = 'rational',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['dvtm_Mavic4_3-2-24-1'] = { Name = 'ColorTemperature', Format = 'unsigned' },
   -- dvtm_Mavic4_3-2-32-1 - unsigned: color temperature again
    ['dvtm_Mavic4_3-2-37-1'] = { Name = 'Temperature', Format = 'float' }, -- (NC)
    ['dvtm_Mavic4_3-3-3'] = { -- (NC)
        Name = 'DroneInfo',
        SubDirectory = { TagTable = 'lexiftool.DJI.DroneInfo' },
    },
    ['dvtm_Mavic4_3-3-4-1'] = {
        Name = 'GPSInfo',
        Condition = function(self) self.CoordUnits = 1 return self.CoordUnits end, -- (stores in degrees)
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_Mavic4_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
    ['dvtm_Mavic4_3-3-5-1'] = { Name = 'RelativeAltitude', Format = 'float', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
   -- dvtm_Mavic4_3-4-1-4 - string: model code?
--
-- Mini 5 Pro
--
    ['dvtm_Mini5Pro_1-1-5'] = { Name = 'SerialNumber', Notes = 'Mini 5 Pro' }, -- (NC)
    ['dvtm_Mini5Pro_1-1-10'] = 'Model', -- (NC)
    ['dvtm_Mini5Pro_3-1-1'] = { Name = 'FrameNumber', Format = 'unsigned' }, -- (NC)
    ['dvtm_Mini5Pro_3-2-37-1'] = { Name = 'Temperature', Format = 'float' }, -- (NC)
    ['dvtm_Mini5Pro_3-3-4-1'] = {
        Name = 'GPSInfo',
        Condition = function(self) self.CoordUnits = 1 return self.CoordUnits end, -- (NC)
        SubDirectory = { TagTable = 'lexiftool.DJI.GPSInfo' },
    },
    ['dvtm_Mini5Pro_3-3-4-2'] = { Name = 'AbsoluteAltitude', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 1000 end }, -- (NC)
}

-- debug info (not yet extracted)
-- Mavic 4 Pro (ref forum17855)
-- dbginfo_wa341_2-1-29-12 - Absolute Altitude
-- dbginfo_wa341_2-1-29-14 - Relative Altitude
-- dbginfo_wa341_2-1-29-16 - VPS Height (Ultrasonic)
-- dbginfo_wa341_2-1-4-200-198 - Sensor Temperature

DJI.DroneInfo = {
    GROUPS = { [0] = 'Protobuf', [1] = 'DJI', [2] = 'Camera' },
    PROCESS_PROC = Protobuf.ProcessProtobuf,
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Field #' },
    [1] = { Name = 'DroneRoll',  Format = 'int64s', ValueConv = function(_self, val) return num(val) / 10 end },
    [2] = { Name = 'DronePitch', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 10 end },
    [3] = { Name = 'DroneYaw',   Format = 'int64s', ValueConv = function(_self, val) return num(val) / 10 end },
}

DJI.GimbalInfo = {
    GROUPS = { [0] = 'Protobuf', [1] = 'DJI', [2] = 'Camera' },
    PROCESS_PROC = Protobuf.ProcessProtobuf,
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Field #' },
    [1] = { Name = 'GimbalPitch',Format = 'int64s', ValueConv = function(_self, val) return num(val) / 10 end },
    [2] = { Name = 'GimbalRoll', Format = 'int64s', ValueConv = function(_self, val) return num(val) / 10 end }, -- usually 0, so missing
    [3] = { Name = 'GimbalYaw',  Format = 'int64s', ValueConv = function(_self, val) return num(val) / 10 end },
}

DJI.FrameInfo = {
    GROUPS = { [0] = 'Protobuf', [1] = 'DJI', [2] = 'Video' },
    PROCESS_PROC = Protobuf.ProcessProtobuf,
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Field #' },
    [1] = { Name = 'FrameWidth',  Format = 'unsigned' },
    [2] = { Name = 'FrameHeight', Format = 'unsigned' },
    [3] = { Name = 'FrameRate',   Format = 'float' },
  -- 4-8: seen these values respectively for DJI Neo: 1,8,4,1,4
}

DJI.GPSInfo = {
    GROUPS = { [0] = 'Protobuf', [1] = 'DJI', [2] = 'Location' },
    PROCESS_PROC = Protobuf.ProcessProtobuf,
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Field #' },
    [1] = {
        Name = 'CoordinateUnits',
        Format  = 'unsigned',
        Notes = 'not extracted, but used internally to convert coordinates to degrees',
        -- don't extract this -- just convert to degrees
        RawConv = function(self, val) self.CoordUnits = val return nil end,
        -- PrintConv = { [0] = 'Radians', [1] = 'Degrees' },
    },
    [2] = {
        Name = 'GPSLatitude',
        Format = 'double',
        -- set ExifTool GPSLatitude/GPSLongitude members so GPSDateTime will be generated if necessary
        RawConv = function(self, val) -- (NC)
            self.GPSLatitude = truthy(self.CoordUnits) and val or num(val) * 180 / 3.141592653589793
            return self.GPSLatitude
        end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    [3] = {
        Name = 'GPSLongitude',
        Format = 'double',
        RawConv = function(self, val) -- (NC)
            self.GPSLongitude = truthy(self.CoordUnits) and val or num(val) * 180 / 3.141592653589793
            return self.GPSLongitude
        end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
}

--------------------------------------------------------------------------------
-- Process DJI beauty settings (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function DJI.ProcessSettings(et, dirInfo, tagTbl)
    et:VerboseDir(dirInfo.DirName, nil, length(dirInfo.DataPt))
    for _, item in ipairs(split(';', dirInfo.DataPt)) do
        local a = split('=', item)
        local tag, val = a[1], a[2]
        if tag ~= nil and val ~= nil then
            et:HandleTag(tagTbl, tag, val, { MakeTagInfo = 1 })
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process DJI info (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function DJI.ProcessDJIInfo(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (length(dataPt) - dirStart)
    if truthy(dirStart) then
        local buff = substr(dataPt, dirStart, dirLen)
        dataPt = buff
    end
    et:VerboseDir('DJIInfo', nil, length(dataPt))
    for rec in eachMatch(dataPt, [[(?s)\G\[(.*?)\](?=(\[|$))]]) do
        local a = split(':', rec, 2)
        local tag, val = a[1], a[2]
        if tag ~= nil and val ~= nil then
            local str = matches(val, [[^([\x20-\x7e]+)\0*$]])
            if str then
                val = str
            else
                local buff = val
                val = { ref = 'SCALAR', value = buff }
            end
            et:HandleTag(tagTbl, tag, val, { MakeTagInfo = 1 })
        end
    end
    return 1
end

-- (upstream predeclares these with `sub ProcessDJIInfo($$$);` /
--  `sub ProcessSettings($$$);` above the tables; here the tables carry a
--  placeholder and the real function is assigned once it exists)
DJI.Info.PROCESS_PROC = DJI.ProcessDJIInfo
DJI.Glamour.PROCESS_PROC = DJI.ProcessSettings

return DJI
