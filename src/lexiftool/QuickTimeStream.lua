--------------------------------------------------------------------------------
-- File:         lexiftool/QuickTimeStream.lua
-- Ported from:  lib/Image/ExifTool/QuickTimeStream.pl
--
-- Description:  Extract embedded information from QuickTime media data
--
-- Revisions:    2018-01-03 - P. Harvey Created
--
-- Notes:        Set API "Debug" option to generate GPSType tag
--
-- References:   1) https://developer.apple.com/library/content/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html#//apple_ref/doc/uid/TP40000939-CH205-SW130
--               2) http://sergei.nz/files/nvtk_mp42gpx.py
--               3) https://forum.flitsservice.nl/dashcam-info/dod-ls460w-gps-data-uit-mov-bestand-lezen-t87926.html
--               4) https://developers.google.com/streetview/publish/camm-spec
--               5) https://sergei.nz/extracting-gps-data-from-viofo-a119-and-other-novatek-powered-cameras/
--               6) Thomas Allen https://github.com/exiftool/exiftool/pull/62
--
-- Port notes:   Complete port of QuickTimeStream.pl: every table, lookup and
--               sub, in upstream order.  Upstream these live in package
--               QuickTime (the file is loaded by QuickTime.pm's AUTOLOAD and
--               by GetTagTable for QuickTime::Stream); here the file is its
--               own module, QuickTime.lua binds its predeclared subs to
--               closures that load this one, and the core (SetupTagTable)
--               maps the table names back to `QuickTime::...` for
--               SHORT_NAME, the default family 0/1 groups and TAG_PREFIX.
--               Calls of QuickTime.pm subs (EEWarn, PrintableTagID,
--               ProcessMOV) go through the QuickTime module, which upstream's
--               `use Image::ExifTool::QuickTime` loads first here as well.
--               Deviations forced by Lua:
--               - The predeclarations `sub Process_tx3g($$$);` ...
--                 `sub OrderCipherDigits($$$;$);` are one block of locals at
--                 the top; the subs assign to them (and are exported on the
--                 module table), the PROCESS_PROC entries of the tables are
--                 `false` placeholders filled in at the bottom of the file,
--                 and SubDirectory ProcessProc entries are closures calling
--                 the local.  String ProcessProcs ('Image::ExifTool::PLIST::
--                 ProcessBinaryPLIST') are closures that load the module.
--               - ConvertLatLon changes its two arguments in place upstream
--                 (through @_); Lua cannot, so it returns the converted pair
--                 and every caller assigns it back:
--                 `lat, lon = ConvertLatLon(lat, lon)` (LigoGPS.lua too).
--               - SignedInt32 reads `$_` upstream; here the value is its
--                 argument (`map { SignedInt32 / 256 } ...` becomes
--                 `map(function(v) return SignedInt32(v) / 256 end, {...})`,
--                 with `map` a small port helper).
--               - ReadValue in list context (`@$size = ReadValue(...)`) is the
--                 core ReadValue with its `wantarray` argument set.
--               - Where a sub has two Perl variables of the same name in
--                 different namespaces (`@time`/`$time`, `@chunkSize`/
--                 `$chunkSize`, `$size`/`@$size`, `$str`/`@str`, `$a`/`@a`,
--                 `$dirInfo`/`%dirInfo`) the one declared later gets a
--                 trailing underscore; `$type`/`$then`/`$end` are `type_`/
--                 `then_`/`end_` (Lua builtin or keyword).
--               - `@xtra` of ProcessFreeGPS holds { tag, value } pairs: Lua
--                 arrays cannot hold the undef values upstream pushes.
--               - If/elsif chains whose conditions bind $1.. test each regex
--                 in turn and leave the chain with `goto`/`break`.
--               - ProcessFreeGPS changes the caller's buffer in place for two
--                 formats (`$$dataPt = substr(...)`, `$$dataPt =~ s/\0+$//`);
--               here it stores the new string back in dirInfo.DataPt, and
--               ScanMediaData reads it from there.
--               SetGPSDateTime builds Perl's `localtime` list from os.date.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local QuickTime = require('lexiftool.QuickTime')  -- (upstream `use Image::ExifTool::QuickTime`)
local GPS = require('lexiftool.GPS')    -- (loaded by QuickTime.pm's `use Image::ExifTool::GPS`)
local Exif = require('lexiftool.Exif')  -- (loaded by QuickTime.pm's `use Image::ExifTool::Exif`)
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local eachMatch = perl.eachMatch
local subst = perl.subst
local split = perl.split
local join = perl.join
local length = perl.length
local substr = perl.substr
local sprintf = perl.sprintf
local unpack = perl.unpack
local pack = perl.pack
local tr = perl.tr
local ord = perl.ord
local uc = perl.uc
local ucfirst = perl.ucfirst
local int = perl.int
local truthy = perl.truthy
local tsort = perl.tsort
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get16s = ExifTool.Get16s
local Get32u = ExifTool.Get32u
local Get32s = ExifTool.Get32s
local Get64u = ExifTool.Get64u
local Get64s = ExifTool.Get64s
local GetFloat = ExifTool.GetFloat
local GetDouble = ExifTool.GetDouble
local GetByteOrder = ExifTool.GetByteOrder
local SetByteOrder = ExifTool.SetByteOrder
local ReadValue = ExifTool.ReadValue
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ConvertUnixTime = ExifTool.ConvertUnixTime
local ConvertDuration = ExifTool.ConvertDuration

local QuickTimeStream = {}

-- (upstream's predeclarations `sub Process_tx3g($$$);` ... are this block of
--  locals; the subs below assign to them)
local Process_tx3g, Process_mebx, Process_text, ProcessFreeGPS, Process360Fly
local ProcessFMAS, ProcessWolfbox, ProcessCAMM
local OrderCipherDigits -- luacheck: ignore 211 (predeclared upstream, defined in LigoGPS.pm)

-- (port helper: Perl's `map BLOCK LIST` -- a new array of fn applied to each
--  element of list)
local function map(fn, list)
    local out = {}
    for i = 1, #list do out[i] = fn(list[i]) end
    return out
end

-- QuickTime data types that have ExifTool equivalents
-- (ref https://developer.apple.com/library/content/documentation/QuickTime/QTFF/Metadata/Metadata.html#//apple_ref/doc/uid/TP40000939-CH1-SW35)
local qtFmt = {
    [0] = 'undef',
    [1] = 'string', -- (UTF-8)
    -- 2 - UTF-16
    -- 3 - shift-JIS
    -- 4 - UTF-8 sort
    -- 5 - UTF-16 sort
    -- 13 - JPEG image
    -- 14 - PNG image
    -- 21 - signed integer (1,2,3 or 4 bytes)
    -- 22 - unsigned integer (1,2,3 or 4 bytes)
    [23] = 'float',
    [24] = 'double',
    -- 27 - BMP image
    -- 28 - QuickTime atom
    [65] = 'int8s',
    [66] = 'int16s',
    [67] = 'int32s',
    [70] = 'float', -- float[2] x,y
    [71] = 'float', -- float[2] width,height
    [72] = 'float', -- float[4] x,y,width,height
    [74] = 'int64s',
    [75] = 'int8u',
    [76] = 'int16u',
    [77] = 'int32u',
    [78] = 'int64u',
    [79] = 'float', -- float[9] transform matrix
    [80] = 'float', -- float[8] face coordinates
}

-- maximums for validating H,M,S,d,m,Y from "freeGPS " metadata
local dateMax = { 24, 59, 59, 2200, 12, 31 }

-- typical (minimum?) size of freeGPS block
local gpsBlockSize = 0x8000

-- conversion factors
local knotsToKph = 1.852     -- knots --> km/h
local mpsToKph   = 3.6       -- m/s   --> km/h
local mphToKph   = 1.60934   -- mph   --> km/h

-- handler types to process based on MetaFormat/OtherFormat
local processByMetaFormat = {
    meta = 1,  -- ('CTMD' in CR3 images, 'priv' unknown in DJI video)
    data = 1,  -- ('RVMI')
    sbtl = 1,  -- (subtitle; 'tx3g' in Yuneec drone videos)
    ctbx = 1,  -- ('marl' in GM videos)
}

-- data lengths for each INSV/INSP record type
local insvDataLen = {
    [0x000] = 0,     -- directory table (any size)
    [0x200] = 0,     -- PreviewImage (any size) (a duplicate of PreviewImage in APP2 of INSP files)
    [0x300] = 0,     -- accelerometer (could be either 20 or 56 bytes)
    [0x400] = 16,    -- exposure (ref 6)
    [0x600] = 8,     -- timestamps (ref 6)
    [0x700] = 53,    -- GPS
  -- 0x900 => 48,    # ? (Insta360 X3)
  -- 0xa00 => 5?,    # ? (Insta360 ONE RS)
  -- 0xb00 => 10,    # ? (Insta360 X3)
  -- 0xd00 => 10,    # ? (Insta360 Ace Pro)
  -- 0x1200 ?        # ? (Insta360 Ace Pro)
  -- 0x1600 ?        # ? (?)
}

-- limit the default amount of data we read for some record types
-- (to avoid running out of memory)
local insvLimit = {
    [0x300] = { 'accelerometer', 20000 },    -- maximum of 20000 accelerometer records
}

-- tags extracted from various QuickTime data streams
QuickTimeStream.Stream = {
    GROUPS = { [2] = 'Location' },
    NOTES = [[
        The tags below are extracted from timed metadata in QuickTime and other
        formats of video files when the ExtractEmbedded option is used.  Although
        most of these tags are combined into the single table below, ExifTool
        currently reads 124 different types of timed GPS metadata.
    ]],
    GPSLatitude  = { PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end, RawConv = function(self, val) self.FoundGPSLatitude = 1 return val end },
    GPSLongitude = { PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end },
    GPSLatitude2 = { PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end },
    GPSLongitude2= { PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end },
    GPSAltitude  = { PrintConv = function(_self, val) return perl.str(perl.num(sprintf('%.4f', val))) .. ' m' end }, -- round to 4 decimals
    GPSSpeed     = { PrintConv = function(_self, val) return perl.num(sprintf('%.4f', val)) end, Notes = 'in km/h unless GPSSpeedRef says otherwise' },
    GPSSpeedRef  = { PrintConv = { K = 'km/h', M = 'mph', N = 'knots' } },
    GPSTrack     = { PrintConv = function(_self, val) return perl.num(sprintf('%.4f', val)) end, Notes = 'relative to true north unless GPSTrackRef says otherwise' },
    GPSTrackRef  = { PrintConv = { M = 'Magnetic North', T = 'True North' } },
    GPSDateTime  = {
        Groups = { [2] = 'Time' },
        Description = 'GPS Date/Time',
        RawConv = function(self, val) self.FoundGPSDateTime = 1 return val end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    DateTimeOriginal = {
        Groups = { [2] = 'Time' },
        Description = 'Date/Time Original',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    GPSTimeStamp = { PrintConv = function(_self, val) return GPS.PrintTimeStamp(val) end, Groups = { [2] = 'Time' } },
    GPSSatellites= { },
    GPSDOP       = { Description = 'GPS Dilution Of Precision' },
    Distance     = { PrintConv = function(_self, val) return perl.str(val) .. ' m' end },
    VerticalSpeed= { PrintConv = function(_self, val) return perl.str(val) .. ' m/s' end },
    CameraModel  = { Groups = { [2] = 'Camera' } },
    FNumber      = { PrintConv = function(_self, val) return Exif.PrintFNumber(val) end, Groups = { [2] = 'Camera' } },
    ExposureTime = { PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end, Groups = { [2] = 'Camera' } },
    ExposureCompensation = { PrintConv = function(_self, val) return Exif.PrintFraction(val) end, Groups = { [2] = 'Camera' } },
    ISO          = { Groups = { [2] = 'Camera' } },
    CameraDateTime={ PrintConv = function(self, val) return self:ConvertDateTime(val) end, Groups = { [2] = 'Time' } },
    DateTimeStamp ={ PrintConv = function(self, val) return self:ConvertDateTime(val) end, Groups = { [2] = 'Time' } },
    VideoTimeStamp = { Groups = { [2] = 'Video' } },
    Accelerometer= { Notes = '3-axis acceleration, usually in units of g' },
    AccelerometerData = { },
    AngularVelocity = { },
    GSensor      = { },
    Car          = { },
    RawGSensor   = {
        -- (same as GSensor, but offset by some unknown value)
        ValueConv = function(_self, val) local a = split(' ', val) for i = 1, #a do a[i] = perl.num(a[i]) / 1000 end return join(' ', a) end,
    },
    Text         = { Groups = { [2] = 'Other' } },
    TimeCode     = { Groups = { [2] = 'Video' } },
    FrameNumber  = { Groups = { [2] = 'Video' } },
    SampleTime   = { Groups = { [2] = 'Video' }, PrintConv = function(_self, val) return ConvertDuration(val) end, Notes = 'sample decoding time' },
    SampleDuration={ Groups = { [2] = 'Video' }, PrintConv = function(_self, val) return ConvertDuration(val) end },
    UserLabel    = { Groups = { [2] = 'Other' } },
    KiloCalories = { Groups = { [2] = 'Other' } },
    SampleDateTime = {
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ConvertUnixTime(val, 0, -6) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- timed metadata decoded based on MetaFormat (format of 'meta' or 'data' sample description)
-- [or HandlerType, or specific 'vide' type if specified]
--
    mebx = {
        Name = 'mebx',
        SubDirectory = {
            TagTable = 'lexiftool.QuickTime.Keys',
            ProcessProc = function(...) return Process_mebx(...) end,
        },
    },
    gpmd = {{
        Name = 'gpmd_Kingslim', -- Kingslim D4 dashcam
        Condition = function(_self, valPt) return isMatch(valPt, [=[(?s)^.{21}\0\0\0A[NS][EW]]=]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return ProcessFreeGPS(...) end,
        },
    },{
        Name = 'gpmd_Rove', -- Rove Stealth 4K encrypted text
        Condition = function(_self, valPt) return isMatch(valPt, [[^\0\0\xf2\xe1\xf0\xeeTT]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return Process_text(...) end,
        },
    },{
        Name = 'gpmd_FMAS', -- Vantrue N2S binary format
        Condition = function(_self, valPt) return isMatch(valPt, [[^FMAS\0\0\0\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return ProcessFMAS(...) end,
        },
    },{
        Name = 'gpmd_Wolfbox', -- Wolfbox G900 Dashcam and Redtiger F9 4K
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^.{136}(0{16}[A-Z]{4}|https:\/\/www.redtiger\0)]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return ProcessWolfbox(...) end,
        },
    },{
        Name = 'gpmd_GoPro',
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPMF' },
    }},
    fdsc = {
        Name = 'fdsc',
        Condition = function(_self, valPt) return isMatch(valPt, [[^GPRO]]) end,
        -- (other types of "fdsc" samples aren't yet parsed: /^GP\x00/ and /^GP\x04/)
        SubDirectory = { TagTable = 'lexiftool.GoPro.fdsc' },
    },
    rtmd = {
        Name = 'rtmd',
        SubDirectory = { TagTable = 'lexiftool.Sony.rtmd' },
    },
    marl = {
        Name = 'marl',
        SubDirectory = { TagTable = 'lexiftool.GM.marl' },
    },
    CTMD = { -- (Canon Timed MetaData)
        Name = 'CTMD',
        SubDirectory = { TagTable = 'lexiftool.Canon.CTMD' },
    },
    tx3g = {
        Name = 'tx3g',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.tx3g' },
    },
    RVMI = {{ -- data "OtherFormat" written by unknown software
        Name = 'RVMI_gReV',
        Condition = function(_self, valPt) return isMatch(valPt, [[^gReV]]) end,  -- GPS data
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.RVMI_gReV',
            ByteOrder = 'Little-endian',
        },
    },{
        Name = 'RVMI_sReV',
        Condition = function(_self, valPt) return isMatch(valPt, [[^sReV]]) end,  -- sensor data
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.RVMI_sReV',
            ByteOrder = 'Little-endian',
        },
    -- (there is also "tReV" data that hasn't been decoded yet)
    }},
    camm = {{
        Name = 'camm0',
        -- (according to the spec. the first 2 bytes are reserved and should be zero,
        -- but I have samples where these bytes are non-zero, so allow anything here)
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\0\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm0',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'camm1',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x01\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm1',
            ByteOrder = 'Little-Endian',
        },
    },{ -- (written by Insta360) - [HandlerType, not MetaFormat]
        Name = 'camm2',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x02\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm2',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'camm3',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x03\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm3',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'camm4',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x04\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm4',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'camm5',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x05\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm5',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'camm6',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x06\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm6',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'camm7',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^..\x07\0]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.camm7',
            ByteOrder = 'Little-Endian',
        },
    }},
    -- (have also seen unknown mett from Google Pixel with MetaType 'application/meta'
    --  and 'application/microvideo-image-meta')
    mett = { -- Parrot drones and iPhone/Android using ARCore
        Name = 'mett',
        SubDirectory = { TagTable = 'lexiftool.Parrot.mett' },
    },
    JPEG = { -- (in CR3 images) - [vide HandlerType with JPEG in SampleDescription, not MetaFormat]
        Name = 'JpgFromRaw',
        Groups = { [2] = 'Preview' },
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
    text = { -- (TomTom Bandit MP4) - [sbtl HandlerType with 'text' in SampleDescription]
        Name = 'PreviewInfo',
        Condition = function(_self, valPt) return length(valPt) > 12 and Get32u(valPt, 4) == length(valPt) and isMatch(valPt, [[(?s)^.{8}\xff\xd8\xff]]) end,
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.PreviewInfo' },
    },
    INSV = {
        Groups = { [0] = 'Trailer', [1] = 'Insta360' }, -- (so these groups will appear in the -listg options)
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.INSV_MakerNotes' },
    },
    ssmd = {{
        Name = 'RoveGPS', -- Rove R2-4K new model
        -- double value of GPSLatitude is 4294967295 (00 00 e0 ff ff ff ef 41) for no GPS
        Condition = function(_self, valPt) return length(valPt) == 32 and not isMatch(valPt, [[^\0\0\xe0\xff\xff\xff\xef\x41]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.RoveGPS',
            ByteOrder = 'Little-Endian',
        },
    },{
        Name = 'Accelerometer', -- Rove R2-4K new model
        Condition = function(_self, valPt) return length(valPt) == 12 end,
        Format = 'float',
        ByteOrder = 'Little-Endian',
    },{
        Name = 'PreviewImage',  -- Chigee AIO-5 dashcam
        Condition = function(_self, valPt) return isMatch(valPt, [[^\xff\xd8\xff]]) end,
        Groups = { [2] = 'Preview' },
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    }},
    djmd = { -- (DJI AC003 Osmo Action 4 cam)
        Name = 'DJIMetadata',
        SubDirectory = { TagTable = 'lexiftool.DJI.Protobuf' },
    },
    dbgi = { -- (DJI AC003 Osmo Action 4 cam)
        Name = 'DJIDebug',
        Unknown = 2,
        Notes = 'extracted only if Unknown option is 2 or greater',
        SubDirectory = { TagTable = 'lexiftool.DJI.Protobuf' },
    },
    Unknown00 = { Unknown = 1 },
    Unknown01 = { Unknown = 1 },
    Unknown02 = { Unknown = 1 },
    Unknown03 = { Unknown = 1 },
    MagneticVariation = { }, -- (from LIGOGPSINFO)
}

-- accelerometer from newer Rove R2-4K cam
QuickTimeStream.RoveGPS = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'GPSLatitude',
        Format = 'double',
        ValueConv = function(_self, val) local deg = int(val / 100) val = deg + (val - deg * 100) / 60 return val end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    [8] = {
        Name = 'GPSLongitude',
        Format = 'double',
        ValueConv = function(_self, val) local deg = int(val / 100) val = deg + (val - deg * 100) / 60 return val end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    [20] = {
        Name = 'GPSSpeed',
        Format = 'int16u',
        ValueConv = function(_self, val) return val * 1.852 end, -- convert from knots to km/h
    },
    [22] = {
        Name = 'GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        Format = 'int8u[6]',
        ValueConv = function(_self, val)
            local v = split(' ', val)
            v[1] = v[1] + 2000
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', table.unpack(v))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- Seen this in the next 4 bytes:
    -- ff 01 01 00 - good GPS?
    -- ff 00 ff ff - no GPS?
}

-- tags found in 'camm' type 0 timed metadata (ref 4)
QuickTimeStream.camm0 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    NOTES = [[
        The camm0 through camm7 tables define tags extracted from the Google Street
        View Camera Motion Metadata of MP4 videos.  See
        L<https://developers.google.com/streetview/publish/camm-spec> for the
        specification.
    ]],
    [4] = {
        Name = 'AngleAxis',
        Notes = 'angle axis orientation in radians in local coordinate system',
        Format = 'float[3]',
    },
}

-- tags found in 'camm' type 1 timed metadata (ref 4)
QuickTimeStream.camm1 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Camera' },
    FIRST_ENTRY = 0,
    [4] = {
        Name = 'PixelExposureTime',
        Format = 'int32s',
        ValueConv = function(_self, val) return val * 1e-9 end,
        PrintConv = function(_self, val) return sprintf('%.4g ms', val * 1000) end,
    },
    [8] = {
        Name = 'RollingShutterSkewTime',
        Format = 'int32s',
        ValueConv = function(_self, val) return val * 1e-9 end,
        PrintConv = function(_self, val) return sprintf('%.4g ms', val * 1000) end,
    },
}

-- tags found in 'camm' type 2 timed metadata (ref PH, Insta360Pro)
QuickTimeStream.camm2 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [4] = {
        Name = 'AngularVelocity',
        Notes = 'gyro angular velocity about X, Y and Z axes in rad/s',
        Format = 'float[3]',
    },
}

-- tags found in 'camm' type 3 timed metadata (ref PH, Insta360Pro)
QuickTimeStream.camm3 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [4] = {
        Name = 'Acceleration',
        Notes = 'acceleration in the X, Y and Z directions in m/s^2',
        Format = 'float[3]',
    },
}

-- tags found in 'camm' type 4 timed metadata (ref 4)
QuickTimeStream.camm4 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [4] = {
        Name = 'Position',
        Notes = 'X, Y, Z position in local coordinate system',
        Format = 'float[3]',
    },
}

-- tags found in 'camm' type 5 timed metadata (ref 4)
QuickTimeStream.camm5 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [4] = {
        Name = 'GPSLatitude',
        Format = 'double',
        RawConv = function(self, val) self.FoundGPSLatitude = 1; return val end,
        ValueConv = function(_self, val) return GPS.ToDegrees(val, 1) end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    [12] = {
        Name = 'GPSLongitude',
        Format = 'double',
        ValueConv = function(_self, val) return GPS.ToDegrees(val, 1) end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    [20] = {
        Name = 'GPSAltitude',
        Format = 'double',
        PrintConv = function(_self, val) local s = sprintf('%.6f', val) s = subst(s, [[\.?0+$]], '') return s .. ' m' end,
    },
}

-- tags found in 'camm' type 6 timed metadata (ref PH/4, Insta360)
QuickTimeStream.camm6 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [0x04] = {
        Name = 'GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        Format = 'double',
        RawConv = function(self, val) self.FoundGPSDateTime = 1; return val end,
        -- by the specification, this should use the GPS epoch of Jan 6, 1980,
        -- but I have samples which use the Unix epoch of Jan 1, 1970, so convert
        -- to the Unix Epoch only if it doesn't match the CreateDate within 5 years
        ValueConv = function(self, val)
            local offset = 315964800
            if truthy(self.CreateDate) and self.CreateDate - val > 24 * 3600 * 365 * 5 then
                val = val + offset
            end
            local str = ConvertUnixTime(val, 0, -6)
            return str .. 'Z'
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x0c] = {
        Name = 'GPSMeasureMode',
        Format = 'int32u',
        PrintConv = {
            [0] = 'No Measurement',
            [2] = '2-Dimensional Measurement',
            [3] = '3-Dimensional Measurement',
        },
    },
    [0x10] = {
        Name = 'GPSLatitude',
        Format = 'double',
        RawConv = function(self, val) self.FoundGPSLatitude = 1; return val end,
        ValueConv = function(_self, val) return GPS.ToDegrees(val, 1) end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    [0x18] = {
        Name = 'GPSLongitude',
        Format = 'double',
        ValueConv = function(_self, val) return GPS.ToDegrees(val, 1) end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    [0x20] = {
        Name = 'GPSAltitude',
        Format = 'float',
        PrintConv = function(_self, val) local s = sprintf('%.3f', val) s = subst(s, [[\.?0+$]], '') return s .. ' m' end,
    },
    [0x24] = { Name = 'GPSHorizontalAccuracy', Format = 'float', Notes = 'metres' },
    [0x28] = { Name = 'GPSVerticalAccuracy',   Format = 'float' },
    [0x2c] = { Name = 'GPSVelocityEast',       Format = 'float', Notes = 'm/s' },
    [0x30] = { Name = 'GPSVelocityNorth',      Format = 'float' },
    [0x34] = { Name = 'GPSVelocityUp',         Format = 'float' },
    [0x38] = { Name = 'GPSSpeedAccuracy',      Format = 'float' },
}

-- tags found in 'camm' type 7 timed metadata (ref 4)
QuickTimeStream.camm7 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    [4] = {
        Name = 'MagneticField',
        Format = 'float[3]',
        Notes = 'microtesla',
    },
}

-- preview image stored by TomTom Bandit ActionCam
QuickTimeStream.PreviewInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FIRST_ENTRY = 0,
    NOTES = 'Preview stored by TomTom Bandit ActionCam.',
    [8] = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
        Format = 'undef[$size-8]',
    },
}

-- tags found in 'RVMI' 'gReV' timed metadata (ref PH)
QuickTimeStream.RVMI_gReV = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    NOTES = 'GPS information extracted from the RVMI box of MOV videos.',
    [4] = {
        Name = 'GPSLatitude',
        Format = 'int32s',
        RawConv = function(self, val) self.FoundGPSLatitude = 1; return val end,
        ValueConv = function(_self, val) return GPS.ToDegrees(val / 1e6, 1) end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    [8] = {
        Name = 'GPSLongitude',
        Format = 'int32s',
        ValueConv = function(_self, val) return GPS.ToDegrees(val / 1e6, 1) end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    -- 12 - int32s: space for altitude? (always zero in my sample)
    [16] = {
        Name = 'GPSSpeed', -- km/h
        Format = 'int16s',
        ValueConv = function(_self, val) return val / 10 end,
    },
    [18] = {
        Name = 'GPSTrack',
        Format = 'int16u',
        ValueConv = function(_self, val) return val * 2 end,
    },
}

-- tags found in 'RVMI' 'sReV' timed metadata (ref PH)
QuickTimeStream.RVMI_sReV = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    NOTES = [[
        G-sensor information extracted from the RVMI box of MOV videos.
    ]],
    [4] = {
        Name = 'GSensor',
        Format = 'int16s[3]', -- X Y Z
        ValueConv = function(_self, val) local a = split(' ', val) for i = 1, #a do a[i] = perl.num(a[i]) / 1000 end return join(' ', a) end,
    },
}

-- tags found in 'tx3g' sbtl timed metadata (ref PH)
QuickTimeStream.tx3g = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Location' },
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the tx3g sbtl timed metadata of Yuneec and Autel drones,
        and subtitle text in some other videos.
    ]],
    Lat = {
        Name = 'GPSLatitude',
        RawConv = function(self, val) self.FoundGPSLatitude = 1; return val end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    Lon = {
        Name = 'GPSLongitude',
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    Alt = {
        Name = 'GPSAltitude',
        ValueConv = function(_self, val) val = subst(val, [[\s*m$]], '') return val end, -- remove " m"
        PrintConv = function(_self, val) return perl.str(val) .. ' m' end, -- add it back again
    },
    Yaw      = 'Yaw',
    Pitch    = 'Pitch',
    Roll     = 'Roll',
    GimYaw   = 'GimbalYaw',
    GimPitch = 'GimbalPitch',
    GimRoll  = 'GimbalRoll',
    DateTime = { -- for date/time-format subtitle text
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Text = { Groups = { [2] = 'Other' } },
    -- the following tags are extracted from Autel Evo II drone videos
    GPSDateTime  = {
        Groups = { [2] = 'Time' },
        Description = 'GPS Date/Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    HomeLat = {
        Name = 'GPSHomeLatitude',
        RawConv = function(self, val) self.FoundGPSLatitude = 1; return val end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    HomeLon = {
        Name = 'GPSHomeLongitude',
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    ISO = { },
    SHUTTER = {
        Name = 'ExposureTime',
        ValueConv = function(_self, val) return 1 / perl.num(val) end, -- (subtitle text: Perl numifies)
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    ['F-NUM'] = {
        Name = 'FNumber',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    EV = 'ExposureCompensation',
}

QuickTimeStream.INSV_MakerNotes = {
    GROUPS = { [1] = 'MakerNotes', [2] = 'Camera' },
    [0x0a] = 'SerialNumber',
    [0x12] = 'Model',
    [0x1a] = 'Firmware',
    [0x2a] = {
        Name = 'Parameters',
        -- (see https://exiftool.org/forum/index.php?msg=78942)
        Notes = 'number of lenses, 6-axis orientation of each lens, raw resolution',
        ValueConv = function(_self, val) val = tr(val, '_', ' ') return val end,
    },
}

QuickTimeStream.Tags360Fly = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'Timed metadata found in MP4 videos from the 360Fly.',
    [1] = {
        Name = 'Accel360Fly',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.Accel360Fly' },
    },
    [2] = {
        Name = 'Gyro360Fly',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.Gyro360Fly' },
    },
    [3] = {
        Name = 'Mag360Fly',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.Mag360Fly' },
    },
    [5] = {
        Name = 'GPS360Fly',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.GPS360Fly' },
    },
    [6] = {
        Name = 'Rot360Fly',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.Rot360Fly' },
    },
    [250] = {
        Name = 'Fusion360Fly',
        SubDirectory = { TagTable = 'lexiftool.QuickTimeStream.Fusion360Fly' },
    },
}

QuickTimeStream.Accel360Fly = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    [1]  = { Name = 'AccelMode', Unknown = 1 }, -- (always 2 in my sample)
    [2]  = {
        Name = 'SampleTime',
        Groups = { [2] = 'Video' },
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    [10] = { Name = 'AccelYPR',  Format = 'float[3]' },
}

QuickTimeStream.Gyro360Fly = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    [1]  = { Name = 'GyroMode', Unknown = 1 }, -- (always 1 in my sample)
    [2]  = {
        Name = 'SampleTime',
        Groups = { [2] = 'Video' },
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    [10] = { Name = 'GyroYPR', Format = 'float[3]' },
}

QuickTimeStream.Mag360Fly = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    [1]  = { Name = 'MagMode', Unknown = 1 }, -- (always 1 in my sample)
    [2]  = {
        Name = 'SampleTime',
        Groups = { [2] = 'Video' },
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    [10] = { Name = 'MagnetometerXYZ', Format = 'float[3]' },
}

QuickTimeStream.GPS360Fly = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    [1]  = { Name = 'GPSMode', Unknown = 1 }, -- (always 16 in my sample)
    [2]  = {
        Name = 'SampleTime',
        Groups = { [2] = 'Video' },
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    [10] = { Name = 'GPSLatitude',  Format = 'float', PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end },
    [14] = { Name = 'GPSLongitude', Format = 'float', PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end },
    [18] = { Name = 'GPSAltitude',  Format = 'float', PrintConv = function(_self, val) return perl.str(val) .. ' m' end }, -- (questionable accuracy)
    [22] = {
        Name = 'GPSSpeed',
        Notes = 'converted to km/hr',
        Format = 'int16u',
        ValueConv = function(_self, val) return val * 0.036 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [24] = { Name = 'GPSTrack',     Format = 'int16u', ValueConv = function(_self, val) return val / 100 end },
    [26] = { Name = 'Acceleration', Format = 'int16u', ValueConv = function(_self, val) return val / 1000 end },
}

QuickTimeStream.Rot360Fly = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    [1]  = { Name = 'RotMode', Unknown = 1 }, -- (always 1 in my sample)
    [2]  = {
        Name = 'SampleTime',
        Groups = { [2] = 'Video' },
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    [10] = { Name = 'RotationXYZ', Format = 'float[3]' },
}

QuickTimeStream.Fusion360Fly = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    [1]  = { Name = 'FusionMode', Unknown = 1 }, -- (always 0 in my sample)
    [2]  = {
        Name = 'SampleTime',
        Groups = { [2] = 'Video' },
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    [10] = { Name = 'FusionYPR', Format = 'float[3]' },
}

-- found in live photo .mov files
QuickTimeStream.setu = {
    PROCESS_PROC = QuickTime.ProcessMOV,
    cfgv = {
        Name = 'CFGV',
        SubDirectory = {
            TagTable = 'lexiftool.PLIST.Main',
            ProcessProc = function(...) return require('lexiftool.PLIST').ProcessBinaryPLIST(...) end,
        },
    },
    dims = {
        Name = 'Dimensions',
        Format = 'int32u',
        Count = 2,
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
    },
}

-- found in live photo .mov files
QuickTimeStream.sdpd = {
    PROCESS_PROC = QuickTime.ProcessMOV,
    sdpi = {
        Name = 'SDPI',
        Unknown = 1,
        Format = 'int32u',
    },
}

--------------------------------------------------------------------------------
-- Convert unsigned 32-bit integer to signed
-- Inputs: <none> (uses value in $_)
-- Returns: signed integer
-- (port: Lua has no $_, the value is the argument)
function QuickTimeStream.SignedInt32(val)
    if val < 0x80000000 then return val end
    return val - 4294967296
end
local SignedInt32 = QuickTimeStream.SignedInt32

--------------------------------------------------------------------------------
-- Save information from keys in OtherSampleDesc directory for processing timed metadata
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- (ref "Timed Metadata Media" here:
--  https://developer.apple.com/library/content/documentation/QuickTime/QTFF/QTFFChap3/qtff3.html)
function QuickTimeStream.SaveMetaKeys(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = length(dataPt)
    if dirLen <= 8 then return 0 end
    local pos = 0
    local verbose = et.OPTIONS.Verbose or 0
    local oldIndent = et.INDENT
    local ee = et.ee
    if not ee then ee = {} et.ee = ee end

    if truthy(verbose) then et:VerboseDir(dirInfo.DirName, nil, dirLen) end

    -- loop through metadata key table
    while pos + 8 < dirLen do
        local size = Get32u(dataPt, pos)
        local id = substr(dataPt, pos + 4, 4)
        local end_ = pos + size
        if end_ > dirLen then end_ = dirLen end
        pos = pos + 8
        local tagID, format, pid
        if truthy(verbose) then
            pid = QuickTime.PrintableTagID(id, 1)
            et:VPrint(0, oldIndent .. '+ [Metadata Key entry, Local ID=' .. pid .. ', ' .. size .. " bytes]\n")
            et.INDENT = et.INDENT .. '| '
        end

        while pos + 4 < end_ do
            local len = unpack('x' .. pos .. 'N', dataPt)
            if len < 8 or pos + len > end_ then break end
            local tag = substr(dataPt, pos + 4, 4)
            pos = pos + 8  len = len - 8
            local base = (dirInfo.Base or 0) + pos
            local val = substr(dataPt, pos, len)
            pos = pos + len
            local str
            if tag == 'keyd' then
                tagID = subst(val, [[^(mdta|fiel)com\.apple\.quicktime\.]], '')
                if not truthy(tagID) then tagID = 'Tag_' .. val end
                if truthy(verbose) then str = subst(val, [[(.{4})]], '$1 ') end
            elseif tag == 'dtyp' then
                if length(val) < 4 then goto continue end
                if length(val) >= 4 then
                    local ns = unpack('N', val)
                    if ns == 0 then
                        if length(val) < 8 then et:Warn('Short dtyp data') goto continue end
                        str = unpack('x4N', val)
                        format = qtFmt[str] or 'undef'
                    elseif ns == 1 then
                        str = substr(val, 4)
                        format = 'undef'
                    else
                        format = 'undef'
                    end
                    if truthy(verbose) and str ~= nil then str = str .. ' (' .. format .. ')' end
                end
            else
                et:HandleTag(tagTbl, tag, nil, {
                    DataPt = val,
                    Base = base,
                })
                goto continue
            end
            if verbose > 1 then
                if str ~= nil then
                    str = tr(perl.str(str), [[\x00-\x1f\x7f-\xff]], '.')
                    str = ' = ' .. str
                else
                    str = ''
                end
                et:VPrint(1, et.INDENT .. "- Tag '" .. QuickTime.PrintableTagID(tag, 2) .. "' (" .. len .. ' bytes)' .. str .. "\n")
                et:VerboseDump(val, { Base = base })
            end
            ::continue::
        end
        if tagID ~= nil and format ~= nil then
            if truthy(verbose) then
                local t2 = QuickTime.PrintableTagID(tagID)
                et:VPrint(0, et.INDENT .. 'Added Local ID ' .. pid .. ' = ' .. t2 .. ' (' .. format .. ")\n")
            end
            if not ee.keys then ee.keys = {} end
            ee.keys[id] = { TagID = tagID, Format = format }
        end
        et.INDENT = oldIndent
    end
    return 1
end

--------------------------------------------------------------------------------
-- We found some tags for this sample, so set document number and save timing information
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) sample time, 3) sample duration
function QuickTimeStream.FoundSomething(et, tagTbl, time, dur)
    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
    et.DOC_NUM = et.DOC_COUNT
    if time ~= nil then et:HandleTag(tagTbl, 'SampleTime', time) end
    if dur ~= nil then et:HandleTag(tagTbl, 'SampleDuration', dur) end
end
local FoundSomething = QuickTimeStream.FoundSomething

--------------------------------------------------------------------------------
-- Approximate GPSDateTime value from sample time and CreateDate
-- Inputs: 0) ExifTool ref, 1) tag table ptr, 2) sample time (s)
--         3) true if CreateDate is UTC
-- Notes: Uses ExifTool CreateDateAtEnd as flag to subtract video duration
function QuickTimeStream.SetGPSDateTime(et, tagTbl, sampleTime, isUTC)
    local value = et.VALUE
    if sampleTime ~= nil and truthy(value.CreateDate) then
        sampleTime = sampleTime + value.CreateDate -- adjust sample time to seconds since the epoch
        if truthy(et.CreateDateAtEnd) then         -- adjust if CreateDate is at end of video
            if not (truthy(value.TimeScale) and truthy(value.Duration)) then return end
            sampleTime = sampleTime - value.Duration / value.TimeScale
            et:Warn('Approximating GPSDateTime as CreateDate - Duration + SampleTime', 1)
        else
            et:Warn('Approximating GPSDateTime as CreateDate + SampleTime', 1)
        end
        local utc = et:Options('QuickTimeUTC')
        if utc == nil then utc = isUTC end  -- (allow QuickTimeUTC=0 to override $isUTC default)
        if not truthy(utc) then
            local tzOff = et.tzOff    -- use previously calculated offset
            if tzOff == nil then
                -- adjust to UTC, assuming time is local
                -- (Perl's `localtime` list, built from os.date like perl.gmtime's)
                local lt = os.date('*t', int(value.CreateDate))
                local tm = { lt.sec, lt.min, lt.hour, lt.day, lt.month - 1, lt.year - 1900 }
                local gm = perl.gmtime(int(value.CreateDate))
                tzOff = ExifTool.GetTimeZone(tm, gm) * 60
                et.tzOff = tzOff
            end
            sampleTime = sampleTime - tzOff  -- shift from local time to UTC
        end
        et.SET_GROUP0 = 'Composite'
        et:HandleTag(tagTbl, 'GPSDateTime', ConvertUnixTime(sampleTime, 0, 3) .. 'Z')
        et.SET_GROUP0 = nil
    end
end
local SetGPSDateTime = QuickTimeStream.SetGPSDateTime

--------------------------------------------------------------------------------
-- Handle tags that we found in the subtitle 'text'
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) hash of tag names/values
function QuickTimeStream.HandleTextTags(et, tagTbl, tags)
    tags.done = nil
    if truthy(tags.GPSDateTime) then tags.GPSTimeStamp = nil end
    local keys = {}
    for k in pairs(tags) do keys[#keys + 1] = k end
    tsort(keys)
    for _, tag in ipairs(keys) do
        et:HandleTag(tagTbl, tag, tags[tag])
    end
    et.UnknownTextCount = 0
    for k in pairs(tags) do tags[k] = nil end   -- clear the hash
end
local HandleTextTags = QuickTimeStream.HandleTextTags

--------------------------------------------------------------------------------
-- Handle new time in NMEA stream and store queued tags if necessary
-- Inputs: 0) ExifTool ref, 1) time string, 2) tag table ref, 3) tags hash
function QuickTimeStream.HandleNewTime(et, time, tagTbl, tags)
    if truthy(et.LastTime) then
        if et.LastTime == time then
            -- combine with the previous NMEA sentence
            et.DOC_NUM = et.LastDoc
        elseif next(tags) ~= nil then
            -- handle existing tags and start a new document
            -- (see https://exiftool.org/forum/index.php?msg=75422)
            HandleTextTags(et, tagTbl, tags)
            -- increment document number and update document count if necessary
            et.DOC_NUM = (et.DOC_NUM or 0) + 1
            if (et.DOC_COUNT or 0) < et.DOC_NUM then et.DOC_COUNT = et.DOC_NUM end
        end
    end
    et.LastTime = time
    et.LastDoc = et.DOC_NUM
end
local HandleNewTime = QuickTimeStream.HandleNewTime

--------------------------------------------------------------------------------
-- Process subtitle 'text'
-- Inputs: 0) ExifTool ref, 1) data ref or dirInfo ref, 2) tag table ref
--         3) flag set if text was already stored
function Process_text(et, dataPt, tagTbl, handled)
    local tags = {}

    if truthy(et.NoMoreTextDecoding) then return end

    if type(dataPt) == 'table' then    -- (ref $dataPt eq 'HASH')
        local dirName = dataPt.DirName
        dataPt = dataPt.DataPt
        et:VerboseDir(dirName, nil, length(dataPt))
    end

    for tag, dat in eachMatch(dataPt, [[\$(\w+)([^\$\0]*)]]) do
        local ok, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14
        if isMatch(tag, [[^[A-Z]{2}RMC$]]) then
            ok, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14 = isMatch(dat,
                [[^,(\d{2})(\d{2})(\d+(?:\.\d*)),A?,(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]])
            if not ok then
                if not truthy(handled) then tags.Text = tags.Text ~= nil and tags.Text .. '$' .. tag .. dat or '$' .. tag .. dat end
                if isMatch(dat, [[^,\d+\.?\d*,V,]]) then et.UnknownTextCount = 0 end -- (allow any number of void fixes)
                goto continue
            end
            local time = c1 .. ':' .. c2 .. ':' .. c3
            HandleNewTime(et, time, tagTbl, tags)
            local year = c14 + (perl.num(c14) >= 70 and 1900 or 2000)
            local date = sprintf('%.4d:%.2d:%.2d', year, c13, c12)
            et.LastDate = date
            tags.GPSDateTime = date .. ' ' .. time .. 'Z'
            tags.GPSLatitude = ((truthy(c4) and c4 or 0) + c5 / 60) * (c6 == 'N' and 1 or -1)
            tags.GPSLongitude = ((truthy(c7) and c7 or 0) + c8 / 60) * (c9 == 'E' and 1 or -1)
            if length(c10) > 0 then tags.GPSSpeed = c10 * knotsToKph end
            if length(c11) > 0 then tags.GPSTrack = c11 end
            goto continue
        end
        if isMatch(tag, [[^[A-Z]{2}GGA$]]) then
            ok, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12 = isMatch(dat,
                [[(?s)^,(\d{2})(\d{2})(\d+(?:\.\d*)?),(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),[1-6]?,(\d+)?,(\.\d+|\d+\.?\d*)?,(-?\d+\.?\d*)?,M?]])
        end
        if ok then
            local time = c1 .. ':' .. c2 .. ':' .. c3
            HandleNewTime(et, time, tagTbl, tags)
            tags.GPSTimeStamp = time
            tags.GPSLatitude = ((truthy(c4) and c4 or 0) + c5 / 60) * (c6 == 'N' and 1 or -1)
            tags.GPSLongitude = ((truthy(c7) and c7 or 0) + c8 / 60) * (c9 == 'E' and 1 or -1)
            if c10 ~= nil then tags.GPSSatellites = c10 end
            if c11 ~= nil then tags.GPSDOP = c11 end
            if c12 ~= nil then tags.GPSAltitude = c12 end
            goto continue
        end
        -- ($G and $GS are ref https://exiftool.org/forum/index.php?topic=13115.msg71743#msg71743)
        if tag == 'G' then
            ok, c1, c2, c3, c4, c5, c6, c7, c8, c9 = isMatch(dat,
                [[:(\d{4})-(\d{2})-(\d{2}) (\d{2}:\d{2}:\d{2})-([NS])(\d+\.\d+)-([EW])(\d+\.\d+)-S(\d+)]])
        end
        if ok then
            tags.GPSDateTime = c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4
            tags.GPSLatitude = c6 * (c5 == 'S' and -1 or 1)
            tags.GPSLongitude = c8 * (c7 == 'W' and -1 or 1)
            tags.GPSSpeed = c9
            goto continue
        end
        if tag == 'GS' then ok, c1, c2, c3 = isMatch(dat, [[:([-+]?\d+),([-+]?\d+),([-+]?\d+)]]) end
        if ok then
            -- scale and re-arrange to match gsensor output from Win app (forum11665)
            local acc = { (c2 + 2432) / 1000, (c3 + 361) / 1000, (c1 - 3708) / 1000 }
            tags.Accelerometer = join(' ', acc)
            goto continue
        end
        if tag == 'BEGINGSENSOR' then ok, c1, c2, c3 = isMatch(dat, [[^:([-+]\d+\.\d+):([-+]\d+\.\d+):([-+]\d+\.\d+)]]) end
        if ok then
            tags.Accelerometer = c1 .. ' ' .. c2 .. ' ' .. c3
            goto continue
        end
        if tag == 'TIME' then ok, c1 = isMatch(dat, [[^:(\d+)]]) end
        if ok then
            tags.TimeCode = c1 / (truthy(et.MediaTS) and et.MediaTS or 1)
        elseif tag == 'BEGIN' then
            if length(dat) > 0 then tags.Text = dat end
            tags.done = 1
        elseif tag ~= 'END' and not truthy(handled) then
            tags.Text = tags.Text ~= nil and tags.Text .. '$' .. tag .. dat or '$' .. tag .. dat
        end
        ::continue::
    end
    if next(tags) ~= nil then
        if not truthy(tags.Accelerometer) then -- (probably unnecessary test)
            -- check for NextBase 622GW accelerometer data
            -- Example data (leading 2-byte length word has been stripped by ProcessSamples):
            -- 0000: 00 00 00 00 32 30 32 32 30 39 30 35 31 36 34 30 [....202209051640]
            -- 0010: 33 33 00 00 29 00 ba ff 48 ff 18 00 f2 07 5a ff [33..)...H.....Z.]
            -- 0020: 64 ff e8 ff 58 ff e8 ff c1 07 43 ff 41 ff d2 ff [d...X.....C.A...]
            -- 0030: 58 ff ea ff dc 07 50 ff 30 ff e0 ff 72 ff d8 ff [X.....P.0...r...]
            -- 0040: f5 07 51 ff 16 ff dc ff 6a ff ca ff 33 08 45 ff [..Q.....j...3.E.]
            local ok, c1, c2, _, c4, c5, c6 = isMatch(dataPt, [[(?s)^\0{4}(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\0\0.{2}]])
            if ok then
                tags.DateTimeStamp = c1 .. ':' .. c2 .. ':' .. c2 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6
                local num = unpack('x20v', dataPt) -- number of accelerometer readings
                if truthy(num) and num * 12 + 22 < length(dataPt) then
                    num = num * 6
                    local acc = { unpack('x22v' .. num, dataPt) }
                    for i = 1, #acc do if acc[i] >= 0x8000 then acc[i] = acc[i] - 0x10000 end end
                    tags.AccelerometerData = join(' ', acc)
                end
            end
        end
        if truthy(tags.GPSTimeStamp) and not truthy(tags.GPSDateTime) and truthy(et.LastDate) then
            -- hack to fill in missing date for NextBase 662GW
            -- (note: this doesn't necessarily handle day rollover properly)
            tags.GPSDateTime = et.LastDate .. ' ' .. tags.GPSTimeStamp .. 'Z'
        end
        HandleTextTags(et, tagTbl, tags)
        return
    end
    -- check for enciphered binary GPS data
    -- BlueSkySea:
    --   0000: 00 00 aa aa aa aa 54 54 98 9a 9b 93 9a 92 98 9a [......TT........]
    --   0010: 9a 9d 9f 9b 9f 9d aa aa aa aa aa aa aa aa aa aa [................]
    --   0020: aa aa aa aa aa a9 e4 9e 92 9f 9b 9f 92 9d 99 ef [................]
    --   0030: 9a 9a 98 9b 93 9d 9d 9c 93 aa aa aa aa aa 9a 99 [................]
    --   0040: 9b aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa [................]
    --   [...]
    --  decrypted:
    --   0000: aa aa 00 00 00 00 fe fe 32 30 31 39 30 38 32 30 [........20190820]
    --   0010: 30 37 35 31 35 37 00 00 00 00 00 00 00 00 00 00 [075157..........]
    --   0020: 00 00 00 00 00 03 4e 34 38 35 31 35 38 37 33 45 [......N48515873E]
    --   0030: 30 30 32 31 39 37 37 36 39 00 00 00 00 00 30 33 [002197769.....03]
    --   0040: 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [1...............]
    --   [...]
    -- Ambarella A12:
    --   0000: 00 00 f2 e1 f0 ee 54 54 98 9a 9b 93 9b 9b 9b 9c [......TT........]
    --   0010: 9b 9a 9a 93 9a 9b a6 9a 9b 9b 93 9b 9a 9b 9c 9a [................]
    --   0020: 9d 9a 92 9f 93 a9 e4 9f 9f 9e 9f 9b 9b 9c 9d ef [................]
    --   0030: 9a 99 9d 9e 99 9a 9a 9e 9b 81 9a 9b 9f 9d 9a 9a [................]
    --   0040: 9a 87 9a 9a 9a 87 9a 98 99 87 9a 9a 99 87 9a 9a [................]
    --   [...]
    --  decrypted:
    --   0000: aa aa 58 4b 5a 44 fe fe 32 30 31 39 31 31 31 36 [..XKZD..20191116]
    --   0010: 31 30 30 39 30 31 0c 30 31 31 39 31 30 31 36 30 [100901.011910160]
    --   0020: 37 30 38 35 39 03 4e 35 35 34 35 31 31 36 37 45 [70859.N55451167E]
    --   0030: 30 33 37 34 33 30 30 34 31 2b 30 31 35 37 30 30 [037430041+015700]
    --   0040: 30 2d 30 30 30 2d 30 32 33 2d 30 30 33 2d 30 30 [0-000-023-003-00]
    --   [...]
    --   0100: aa 55 57 ed ed 45 58 54 44 00 01 30 30 30 30 31 [.UW..EXTD..00001]
    --   0110: 31 30 38 30 30 30 58 00 58 00 58 00 58 00 58 00 [108000X.X.X.X.X.]
    --   0120: 58 00 58 00 58 00 58 00 00 00 00 00 00 00 00 00 [X.X.X.X.........]
    --   0130: 00 00 00 00 00 00 00                            [.......]
    local function xorAA(c) return c ~ 0xaa end -- (the `map { $_ ^ 0xaa }` block below)
    if isMatch(dataPt, [[(?s)^\0\0(..\xaa\xaa|\xf2\xe1\xf0\xee)]]) and length(dataPt) >= 282 then
        local val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 8, 14)) })))
        local ok, c1, c2, c3, c4, c5, c6 = isMatch(val, [[^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$]])
        if ok then
            tags.GPSDateTime = c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6
            val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 38, 9)) })))
            ok, c1, c2, c3 = isMatch(val, [[^([NS])(\d{2})(\d+$)$]])
            if ok then
                tags.GPSLatitude = (c2 + c3 / 600000) * (c1 == 'S' and -1 or 1)
            end
            val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 47, 10)) })))
            ok, c1, c2, c3 = isMatch(val, [[^([EW])(\d{3})(\d+$)$]])
            if ok then
                tags.GPSLongitude = (c2 + c3 / 600000) * (c1 == 'W' and -1 or 1)
            end
            val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 0x39, 5)) })))
            if isMatch(val, [[^[-+]\d+$]]) then tags.GPSAltitude = perl.num(val) end
            val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 0x3e, 3)) })))
            if isMatch(val, [[^\d+$]]) then tags.GPSSpeed = perl.num(val) end
            if isMatch(dataPt, [[(?s)^\0\0..\xaa\xaa]]) then -- (BlueSkySea)
                val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 0xad, 12)) })))
                -- the first X,Y,Z accelerometer readings from the AccelerometerData
                ok, c1, c2, c3 = isMatch(val, [[^([-+]\d{3})([-+]\d{3})([-+]\d{3})$]])
                if ok then
                    tags.Accelerometer = c1 .. ' ' .. c2 .. ' ' .. c3
                    val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 0xba, 96)) })))
                    local order = GetByteOrder()
                    SetByteOrder('II')
                    val = ReadValue(val, 0, 'float')
                    SetByteOrder(order)
                    tags.AccelerometerData = val
                end
            else -- (Ambarella)
                local acc = {}
                val = pack('C*', table.unpack(map(xorAA, { unpack('C*', substr(dataPt, 0x41, 195)) })))
                local p = 0
                while true do
                    local a1, a2, a3, en = matches(val, [[\G([-+]\d{3})([-+]\d{3})([-+]\d{3})]], p)
                    if not a1 then break end
                    acc[#acc + 1] = a1  acc[#acc + 1] = a2  acc[#acc + 1] = a3
                    p = en
                end
                if #acc > 0 then tags.Accelerometer = join(' ', acc) end
            end
        end
        if next(tags) ~= nil then HandleTextTags(et, tagTbl, tags) end
        return
    end

    -- check for DJI telemetry data, eg:
    -- "F/3.5, SS 1000, ISO 100, EV 0, GPS (8.6499, 53.1665, 18), D 24.26m,
    --  H 6.00m, H.S 2.10m/s, V.S 0.00m/s \n"
    local ok, c1, c2 = isMatch(dataPt, [[GPS \(([-+]?\d*\.\d+),\s*([-+]?\d*\.\d+)]])
    if ok then
        et.CreateDateAtEnd = 1  -- set flag indicating the file creation date is at the end
        tags.GPSLatitude = c2
        tags.GPSLongitude = c1
        local v
        v = matches(dataPt, [[,\s*H\s+([-+]?\d+\.?\d*)m]])
        if v then tags.GPSAltitude = v end
        v = matches(dataPt, [[,\s*H.S\s+([-+]?\d+\.?\d*)]])
        if v then tags.GPSSpeed = v * mpsToKph end
        v = matches(dataPt, [[,\s*D\s+(\d+\.?\d*)m]])
        if v then tags.Distance = v * mpsToKph end
        v = matches(dataPt, [[,\s*V.S\s+([-+]?\d+\.?\d*)]])
        if v then tags.VerticalSpeed = v end
        v = matches(dataPt, [[\bF\/(\d+\.?\d*)]])
        if v then tags.FNumber = v end
        v = matches(dataPt, [[\bSS\s+(\d+\.?\d*)]])
        if v then tags.ExposureTime = 1 / v end
        local v2
        v, v2 = matches(dataPt, [[\bEV\s+([-+]?\d+\.?\d*)(\/\d+)?]])
        if v then tags.ExposureCompensation = (v / (truthy(v2) and perl.num(v2) or 1)) end
        v = matches(dataPt, [[\bISO\s+(\d+\.?\d*)]])
        if v then tags.ISO = v end
        HandleTextTags(et, tagTbl, tags)
        return
    end

    -- check for Mini 0806 dashcam GPS, eg:
    -- "A,270519,201555.000,3356.8925,N,08420.2071,W,000.0,331.0M,+01.84,-09.80,-00.61;\n"
    local c3, c4, c5, c6
    ok, c1, c2, c3, c4, c5, c6 = isMatch(dataPt, [[^A,(\d{2})(\d{2})(\d{2}),(\d{2})(\d{2})(\d{2}(\.\d+)?)]])
    if ok then
        tags.GPSDateTime = '20' .. c3 .. ':' .. c2 .. ':' .. c1 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6 .. 'Z'
        local d1, d2, d3 = matches(dataPt, [[^A,.*?,.*?,(\d{2})(\d+\.\d+),([NS])]])
        if d1 then
            tags.GPSLatitude = (d1 + d2 / 60) * (d3 == 'S' and -1 or 1)
        end
        d1, d2, d3 = matches(dataPt, [[^A,.*?,.*?,.*?,.*?,(\d{3})(\d+\.\d+),([EW])]])
        if d1 then
            tags.GPSLongitude = (d1 + d2 / 60) * (d3 == 'W' and -1 or 1)
        end
        local a = split(',', dataPt)
        if truthy(a[9]) and isMatch(a[9], [[M$]]) then a[9] = subst(a[9], [[M$]], '') tags.GPSAltitude = a[9] end
        if truthy(a[8]) and isMatch(a[8], [[^\d+\.\d+$]]) then tags.GPSSpeed = a[8] end -- (NC)
        if truthy(a[12]) and isMatch(a[12], [[;\s*$]]) then
            a[12] = subst(a[12], [[;\s*$]], '')
            tags.Accelerometer = perl.str(a[10]) .. ' ' .. perl.str(a[11]) .. ' ' .. a[12]
        end
        HandleTextTags(et, tagTbl, tags)
        return
    end

    -- check for Roadhawk dashcam text
    -- ".;;;;D?JL;6+;;;D;R?;4;;;;DBB;;O;;;=D;L;;HO71G>F;-?=J-F:FNJJ;DPP-JF3F;;PL=DBRLBF0F;=?DNF-RD-PF;N;?=JF;;?D=F:*6F~"
    -- decoded:
    -- "X0000.2340Y-000.0720Z0000.9900G0001.0400$GPRMC,082138,A,5330.6683,N,00641.9749,W,012.5,87.86,050213,002.1,A"
    -- (note: "002.1" is magnetic variation and is not decoded; it should have ",E" or ",W" afterward for direction)
    if isMatch(dataPt, [[\*[0-9A-F]{2}~$]]) then
        -- (ref https://reverseengineering.stackexchange.com/questions/11582/how-to-reverse-engineer-dash-cam-metadata)
        local decode = { unpack('C*', '-I8XQWRVNZOYPUTA0B1C2SJ9K.L,M$D3E4F5G6H7') }
        local chars = { unpack('C*', substr(dataPt, 0, -4)) }
        for i = 1, #chars do    -- foreach (@chars)
            local n = chars[i] - 43
            if n >= 0 and decode[n + 1] ~= nil then chars[i] = decode[n + 1] end
        end
        local buff = pack('C*', table.unpack(chars))
        ok, c1, c2, c3, c4 = isMatch(buff, [[X(.*?)Y(.*?)Z(.*?)G(.*?)\$]])
        if ok then
            -- yup. the decoding worked out
            tags.Accelerometer = c1 .. ' ' .. c2 .. ' ' .. c3 .. ' ' .. c4
            dataPt = buff   -- (process GPRMC below)
        end
    end

    -- check for Thinkware format (and other NMEA RMC), eg:
    -- "gsensori,4,512,-67,-12,100;GNRMC,161313.00,A,4529.87489,N,07337.01215,W,6.225,35.34,310819,,,A*52..;
    --  CAR,0,0,0,0.0,0,0,0,0,0,0,0,0"
    local c7, c8, c9, c10, c11, c12, c13, c14, c15, _
    ok, c1, c2, c3, _, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15 = isMatch(dataPt,
        [[[A-Z]{2}RMC,(\d{2})(\d{2})(\d+(\.\d*)?),A?,(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]])
    if ok and
        -- do some basic sanity checks on the date
        perl.num(c13) <= 31 and perl.num(c14) <= 12 and perl.num(c15) <= 99
    then
        local year = c15 + (perl.num(c15) >= 70 and 1900 or 2000)
        tags.GPSDateTime = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', year, c14, c13, c1, c2, c3)
        tags.GPSLatitude = ((truthy(c5) and c5 or 0) + c6 / 60) * (c7 == 'N' and 1 or -1)
        tags.GPSLongitude = ((truthy(c8) and c8 or 0) + c9 / 60) * (c10 == 'E' and 1 or -1)
        if length(c11) > 0 then tags.GPSSpeed = c11 * knotsToKph end
        if length(c12) > 0 then tags.GPSTrack = c12 end
    end
    local v = matches(dataPt, [[\bgsensori,(.*?)(;|$)]])
    if v then tags.GSensor = v end
    v = matches(dataPt, [[\bCAR,(.*?)(;|$)]])
    if v then tags.Car = v end

    if next(tags) ~= nil then
        HandleTextTags(et, tagTbl, tags)
    else
        et.UnknownTextCount = (et.UnknownTextCount or 0) + 1
        -- give up trying to decode useful information if we haven't found anything for a while
        if et.UnknownTextCount > 100 then et.NoMoreTextDecoding = 1 end
    end
end
QuickTimeStream.Process_text = Process_text

--------------------------------------------------------------------------------
-- Extract embedded metadata from media samples
-- Inputs: 0) ExifTool ref
-- Notes: Also accesses ExifTool RAF*, SET_GROUP1, HandlerType, MetaFormat,
--        ee*, and avcC elements (* = must exist)
-- - may be called either due to ExtractEmbedded option, or ImageDataHash requested
-- - hash includes only video and audio data
function QuickTimeStream.ProcessSamples(et)
    local raf, ee = et.RAF, et.ee
    local pos, hdrLen, hdrFmt, oldIndent, hash
    local time, dur = {}, {}
    local mdatOffset, mdatSize -- (for range-checking samples when hash is done)

    if not ee then return end
    et.ee = nil    -- use only once

    local eeOpt = et:Options('ExtractEmbedded') or 0
    local type_ = et.HandlerType or ''
    if type_ == 'vide' then
        -- only process specific types of video streams
        hash = rawget(et, 'ImageDataHash')  -- (rawget: also the name of a method)
        -- only process specific video types if ExtractEmbedded was used
        -- (otherwise we are only here to calculate the audio/video hash)
        if truthy(eeOpt) then
            if     truthy(ee.avcC) then type_ = 'avcC'
            elseif truthy(ee.JPEG) then type_ = 'JPEG'
            elseif not hash then return end
        end
    elseif type_ == 'soun' then
        hash = rawget(et, 'ImageDataHash')
        if not hash then return end
    else
        if not truthy(eeOpt) then return end   -- (don't do hash on other types)
    end

    local hashSize = 0
    local start, size = ee.start, ee.size
--
-- determine sample start offsets from chunk offsets (stco) and sample-to-chunk table (stsc),
-- and sample time/duration from time-to-sample (stts)
--
    if not (start and size) then
        if not size then return end
        local stco, stsc, stts = ee.stco, ee.stsc, ee.stts
        if not (stco and stsc and #stsc > 0) then return end
        start = {}
        local nextChunk, iChunk = 0, 1
        local startChunk, samplesPerChunk, descIdx, timeCount, timeDelta, time_ -- luacheck: ignore 231
        if stts and #stts > 1 then
            time_ = 0
            timeCount = table.remove(stts, 1)
            timeDelta = table.remove(stts, 1)
        end
        local ts = truthy(et.MediaTS) and et.MediaTS or 1
        local chunkSize = {}  -- total size of each chunk
        for _, chunkStart in ipairs(stco) do
            if iChunk >= nextChunk and #stsc > 0 then
                local e = table.remove(stsc, 1)
                startChunk, samplesPerChunk, descIdx = e[1], e[2], e[3]
                if #stsc > 0 then nextChunk = stsc[1][1] end
            end
            if #size < #start + samplesPerChunk then et:Warn('Sample size error') break end
            if not (chunkStart ~= nil and length(chunkStart) > 0) then break end
            local sampleStart = chunkStart
            local chunkSize_ = 0
            local i = 0
            while true do -- (Sample:)
                start[#start + 1] = sampleStart
                if time_ ~= nil then
                    while not truthy(timeCount) do
                        if #stts < 2 then
                            time_ = nil
                            goto Sample  -- (last Sample)
                        end
                        timeCount = table.remove(stts, 1)
                        timeDelta = table.remove(stts, 1)
                    end
                    time[#time + 1] = time_ / ts
                    dur[#dur + 1] = timeDelta / ts
                    time_ = time_ + timeDelta
                    timeCount = timeCount - 1
                end
                -- (eventually should use the description indices: $descIdx)
                chunkSize_ = chunkSize_ + size[#start]
                i = i + 1
                if i >= samplesPerChunk then break end
                sampleStart = sampleStart + size[#start]
            end
            ::Sample::
            chunkSize[#chunkSize + 1] = chunkSize_
            iChunk = iChunk + 1
        end
        if #start ~= #size then et:Warn('Incorrect sample start/size count') return end
        -- process as chunks if we are only interested in calculating hash
        if type_ == 'soun' or type_ == 'vide' then
            start = stco
            size = chunkSize
        end
    end
--
-- extract and parse the sample data
--
    local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
    local verbose = et:Options('Verbose') or 0
    local metaFormat = et.MetaFormat or ''
    local tell = raf:Tell()

    if truthy(verbose) then
        et:VPrint(0, "---- Extract Embedded ----\n")
        oldIndent = et.INDENT
        et.INDENT = ''
    end
    if hash then
        mdatSize = et.MediaDataSize
        if mdatSize ~= nil then mdatOffset = et.MediaDataOffset end
    end
    -- get required information from avcC box if parsing video data
    if type_ == 'avcC' then
        hdrLen = (Get8u(ee.avcC, 4) & 0x03) + 1
        hdrFmt = (hdrLen == 4 and 'N' or hdrLen == 2 and 'n' or 'C')
        require('lexiftool.H264')
    end

    -- loop through all samples
    for i = 0, math.min(#start, #size) - 1 do

        -- initialize our flags for setting GPSDateTime
        et.FoundGPSLatitude = nil
        et.FoundGPSDateTime = nil

        -- range check the sample data for hash if necessary
        local size_ = size[i + 1]
        if mdatOffset ~= nil then
            if start[i + 1] < mdatOffset then
                et:Warn('Sample ' .. i .. " for '" .. type_ .. "' data is before start of mdat")
            elseif start[i + 1] + size_ > mdatOffset + mdatSize then
                et:Warn('Sample ' .. i .. " for '" .. type_ .. "' data runs off end of mdat")
                size_ = mdatOffset + mdatSize - start[i + 1]
                if size_ < 0 then size_ = 0 end
            end
        end
        -- read the sample data
        if not raf:Seek(start[i + 1], 0) then et:Warn('Seek error in ' .. type_ .. ' data') goto continue end
        local n, buff = raf:Read(size_)
        if n ~= size_ then
            et:Warn('Error reading ' .. type_ .. ' data')
            if not truthy(n) then goto continue end
            size_ = n
        end
        if hash then
            hash:add(buff)
            hashSize = hashSize + length(buff)
        end
        if type_ == 'avcC' then
            if length(buff) <= hdrLen then goto continue end
            -- scan through all NAL units and send them to ParseH264Video()
            -- (port: unpack at an offset, not with a "x$pos" template -- one
            --  cached template per NAL position would pile up)
            pos = 0
            while true do
                local len = unpack(hdrFmt, buff, pos)
                if pos + hdrLen + len > length(buff) then break end
                local tmp = "\0\0\0\x01" .. substr(buff, pos + hdrLen, len)
                require('lexiftool.H264').ParseH264Video(et, tmp)
                pos = pos + hdrLen + len
                if pos + hdrLen >= length(buff) then break end
            end
            if truthy(et.GotNAL06) and eeOpt < 3 then break end
            goto continue
        end
        if verbose > 1 then
            local hdr = truthy(et.SET_GROUP1) and (et.SET_GROUP1 .. " Type='" .. type_ .. "' Format='" .. metaFormat .. "'") or ("Type='" .. type_ .. "'")
            et:VPrint(1, hdr .. ', Sample ' .. (i + 1) .. ' of ' .. #start .. ' (' .. size_ .. " bytes)\n")
            et:VerboseDump(buff, { Addr = start[i + 1] })
        end
        if type_ == 'text' or
            -- (PNDM is normally 'text', but was sbtl/tx3g in concatenated Garmin sample output_3videos.mp4)
            (type_ == 'sbtl' and metaFormat == 'tx3g' and isMatch(buff, [[(?s)^..PNDM]]))
        then

            local handled
            FoundSomething(et, tagTbl, time[i + 1], dur[i + 1])
            if not isMatch(buff, [[^\$BEGIN]]) then
                -- remove ending "encd" box if it exists
                if isMatch(buff, [[\0\0\0\x0cencd\0\0\x01\0$]]) then
                    buff = subst(buff, [[\0\0\0\x0cencd\0\0\x01\0$]], '')
                    size_ = size_ - 12
                end
                -- cameras such as the CanonPowerShotN100 store ASCII time codes with a
                -- leading 2-byte integer giving the length of the string
                -- (and chapter names start with a 2-byte integer too)
                if size_ >= 2 and unpack('n', buff) == size_ - 2 then
                    if size_ == 2 then goto continue end
                    buff = substr(buff, 2)
                end
                local val
                -- check for encrypted GPS text as written by E-PRANCE B47FS camera
                if isMatch(buff, [[^\0]]) and isMatch(buff, [[\x0a$]]) and length(buff) > 5 then
                    -- decode simple ASCII difference cipher,
                    -- based on known value of 4th-last char = '*'
                    local dif = ord('*') - ord(substr(buff, -4, 1))
                    local tmp = pack('C*', table.unpack(map(function(c) return (c + dif) & 0xff end, { unpack('C*', substr(buff, 1, -1)) })))
                    if verbose > 2 then
                        et:VPrint(0, "[decrypted text]\n")
                        et:VerboseDump(tmp)
                    end
                    local ok, c1, c2 = isMatch(tmp, [[(?s)^(.*?)(\$[A-Z]{2}RMC.*)]])
                    if ok then
                        val, buff = c1, c2
                        val = tr(val, '\t', ' ')
                        if length(val) > 0 then et:HandleTag(tagTbl, 'RawGSensor', val) end
                    end
                else
                    local ok, c1 = isMatch(buff, [[(?s)^(\0.{3})?PNDM]])
                    if ok then
                        -- Garmin Dashcam format (actually binary, not text)
                        n = c1 and 4 or 0 -- skip leading 4-byte size word if it exists
                        if length(buff) < 20 + n then goto continue end
                        et:HandleTag(tagTbl, 'GPSLatitude', Get32s(buff, 12 + n) * 180 / 0x80000000)
                        et:HandleTag(tagTbl, 'GPSLongitude', Get32s(buff, 16 + n) * 180 / 0x80000000)
                        et:HandleTag(tagTbl, 'GPSSpeed', Get16u(buff, 8 + n) * mphToKph)
                        SetGPSDateTime(et, tagTbl, time[i + 1], 1)
                        goto continue -- all done (don't store/process as text)
                    end
                end
                if not (val ~= nil or isMatch(buff, [=[\0[^\0]]=])) then
                    -- just store any other plain text
                    et:HandleTag(tagTbl, 'Text', buff)
                    handled = 1
                end
            end
            Process_text(et, buff, tagTbl, handled)

        elseif processByMetaFormat[type_] then

            if tagTbl[metaFormat] then
                local tagInfo = et:GetTagInfo(tagTbl, metaFormat, buff)
                if tagInfo and (not truthy(tagInfo.Unknown) or (et.OPTIONS.Unknown or 0) >= tagInfo.Unknown) then
                    FoundSomething(et, tagTbl, time[i + 1], dur[i + 1])
                    et.ee = ee -- need ee information for 'keys'
                    et:HandleTag(tagTbl, metaFormat, nil, {
                        DataPt  = buff,
                        Base    = start[i + 1], -- (Base must be set for CR3 files)
                        TagInfo = tagInfo,
                    })
                    et.ee = nil
                    -- synthesize GPSDateTime if necessary for djmd metadata
                    if metaFormat == 'djmd' then
                        if et.GPSLatitude ~= nil and et.GPSLongitude ~= nil and not truthy(et.GPSDateTime) then
                            SetGPSDateTime(et, tagTbl, time[i + 1], 1) -- (NC)
                        end
                        et.GPSLatitude = nil
                        et.GPSLongitude = nil
                        et.GPSDateTime = nil
                    end
                elseif metaFormat == 'camm' and isMatch(buff, [[^X]]) then
                    -- seen 'camm' metadata in this format (X/Y/Z acceleration and G force? + GPRMC + ?)
                    -- "X0000.0000Y0000.0000Z0000.0000G0000.0000$GPRMC,000125,V,,,,,000.0,,280908,002.1,N*71~, 794021  \x0a"
                    FoundSomething(et, tagTbl, time[i + 1], dur[i + 1])
                    local ok, c1, c2, c3, c4 = isMatch(buff, [[X(.*?)Y(.*?)Z(.*?)G(.*?)\$]])
                    if ok then et:HandleTag(tagTbl, 'Accelerometer', c1 .. ' ' .. c2 .. ' ' .. c3 .. ' ' .. c4) end
                    Process_text(et, buff, tagTbl)
                end
            elseif truthy(verbose) then
                et:VPrint(0, 'Unknown ' .. type_ .. ' format (' .. metaFormat .. ')')
            end

        elseif type_ == 'gps ' then -- (ie. GPSDataList tag)

            if isMatch(buff, [[(?s)^....freeGPS ]]) then
                -- parse freeGPS data unless done already in brute-force scan
                -- (some videos don't reference all freeGPS info from 'gps ' table, eg. INNOV,
                --  and some videos don't put 'gps ' data in mdat, eg XGODY 12" 4K Dashcam)
                if truthy(et.FoundGPSByScan) then break end
                -- decode "freeGPS " data (Novatek and others)
                ProcessFreeGPS(et, {
                    DataPt = buff,
                    DataPos = start[i + 1],
                    SampleTime = time[i + 1],
                    SampleDuration = dur[i + 1],
                }, tagTbl)
            end

        elseif tagTbl[type_] then

            local tagInfo = et:GetTagInfo(tagTbl, type_, buff)
            if tagInfo then
                FoundSomething(et, tagTbl, time[i + 1], dur[i + 1])
                et:HandleTag(tagTbl, type_, nil, {
                    DataPt  = buff,
                    Base    = start[i + 1], -- (Base must be set for CR3 files)
                    TagInfo = tagInfo,
                })
            end
        end
        -- generate approximate GPSDateTime if necessary
        if truthy(et.FoundGPSLatitude) and not truthy(et.FoundGPSDateTime) then SetGPSDateTime(et, tagTbl, time[i + 1]) end
        ::continue::
    end
    if truthy(verbose) then
        local str = type_ == 'soun' and 'Audio' or 'Video'
        if hashSize ~= 0 then et:VPrint(0, et.INDENT .. '(ImageDataHash: ' .. hashSize .. ' bytes of ' .. str .. " data)\n") end
        et.INDENT = oldIndent
        et:VPrint(0, "--------------------------\n")
    end
    -- clean up
    raf:Seek(tell, 0) -- restore original file position
    et.DOC_NUM = nil
    et.HandlerType = ''
end

--------------------------------------------------------------------------------
-- Convert latitude/longitude from DDDMM.MMMM format to decimal degrees
-- Inputs: 0) latitude, 1) longitude
-- Returns: lat/lon are changed in place
-- (note: this method works fine for negative coordinates)
-- (port: Lua cannot change the caller's variables, so the converted pair is
--  returned -- callers write `lat, lon = ConvertLatLon(lat, lon)`)
function QuickTimeStream.ConvertLatLon(lat, lon)
    local deg = int(lat / 100)      -- latitude
    lat = deg + (lat - deg * 100) / 60
    deg = int(lon / 100)            -- longitude
    lon = deg + (lon - deg * 100) / 60
    return lat, lon
end
local ConvertLatLon = QuickTimeStream.ConvertLatLon

--------------------------------------------------------------------------------
-- Decrypt Lucky data
-- Inputs: 0) string to decrypt, 1) encryption key
-- Returns: decrypted string
local luckyKeys = { 'luckychip gps',  'customer ## gps' }
function QuickTimeStream.DecryptLucky(str_, key_)
    local str = { unpack('C*', str_) }
    local key = { unpack('C*', key_) }
    local enc = {}  -- (0..255), 0-based like the Perl array
    for n = 0, 255 do enc[n] = n end
    local i, j, k = 0, 0, 0 -- luacheck: ignore 311 (as upstream)
    repeat
        j = (j + enc[i] + key[i % length(key_) + 1]) & 0xff
        enc[i], enc[j] = enc[j], enc[i]
        i = i + 1
    until i >= 256
    i, j, k = 0, 0, 0
    repeat
        j = (j + 1) & 0xff
        k = (k + enc[j]) & 0xff
        enc[j], enc[k] = enc[k], enc[j]
        str[i + 1] = str[i + 1] ~ enc[(enc[j] + enc[k]) & 0xff]
        i = i + 1
    until i >= #str
    return pack('C*', table.unpack(str))
end

--------------------------------------------------------------------------------
-- Process "freeGPS " data blocks
-- Inputs: 0) ExifTool ref, 1) dirInfo ref {DataPt,SampleTime,SampleDuration}, 2) tagTable ref
-- Returns: 1 on success (or 0 on unrecognized or "measurement-void" GPS data)
-- Notes:
function ProcessFreeGPS(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = length(dataPt)
    local yr, mon, day, hr, min, sec, ss, stat, lbl, ddd, done -- luacheck: ignore 231
    local lat, latRef, lon, lonRef, spd, trk, alt
    local acc, xtra = {}, {}

    if dirLen < 82 then return 0 end

    local debug = et:Options('Debug')
    local oldOrder = GetByteOrder()
    SetByteOrder('II')
    et.FoundEmbedded = 1

    local function SignedInt32_256(v) return SignedInt32(v) / 256 end      -- (the `map { SignedInt32 / 256 }` block)
    local function SignedInt32_1000(v) return SignedInt32(v) / 1000 end    -- (the `map { SignedInt32 / 1000 }` block)

    -- (upstream's if/elsif chain: several conditions bind $1.., so each
    --  branch tests its regex in turn and leaves the chain with `break`)
    repeat
    local ok, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13
    if substr(dataPt, 18, 8) == "\xaa\xaa\xf2\xe1\xf0\xee\x54\x54" then

        if truthy(debug) then et:FoundTag('GPSType', 1) end
        -- (this is very similar to the encrypted text format)
        -- decode encrypted ASCII-based GPS (DashCam Azdome GS63H, ref 5)
        -- header looks like this in my sample:
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 05 01 00 00 [....freeGPS ....]
        --  0010: 01 03 aa aa f2 e1 f0 ee 54 54 98 9a 9b 92 9a 93 [........TT......]
        --  0020: 98 9e 98 98 9e 93 98 92 a6 9f 9f 9c 9d ed fa 8a [................]
        -- decrypted (from byte 18):
        --  0000: 00 00 58 4b 5a 44 fe fe 32 30 31 38 30 39 32 34 [..XKZD..20180924]
        --  0010: 32 32 34 39 32 38 0c 35 35 36 37 47 50 20 20 20 [224928.5567GP   ]
        --  0020: 00 00 00 00 00 03 4e 34 30 34 36 34 33 35 30 57 [......N40464350W]
        --  0030: 30 30 37 30 34 30 33 30 38 30 30 30 30 30 30 30 [0070403080000000]
        --  0040: 37 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [7...............]
        --  [...]
        --  00a0: 00 00 00 00 00 00 00 00 00 00 00 00 00 2b 30 39 [.............+09]
        --  00b0: 33 2d 30 30 33 2d 30 30 35 00 00 00 00 00 00 00 [3-003-005.......]
        -- header looks like this for EEEkit gps:
        --  0000: 00 00 04 00 66 72 65 65 47 50 53 20 f0 03 00 00 [....freeGPS ....]
        --  0010: 01 03 aa aa f2 e1 f0 ee 54 54 98 9a 98 9a 9a 9f [........TT......]
        --  0020: 9b 93 9b 9c 98 99 99 9f a6 9a 9a 98 9a 9a 9f 9b [................]
        --  0030: 93 9b 9c 98 99 99 9c a9 e4 99 9d 9e 9f 98 9e 9b [................]
        --  0040: 9c fd 9b 98 98 98 9f 9f 9a 9a 93 81 9a 9b 9d 9f [................]
        -- decrypted (from byte 18):
        --  0000: 00 00 58 4b 5a 44 fe fe 32 30 32 30 30 35 31 39 [..XKZD..20200519]
        --  0010: 31 36 32 33 33 35 0c 30 30 32 30 30 35 31 39 31 [162335.002005191]
        --  0020: 36 32 33 33 36 03 4e 33 37 34 35 32 34 31 36 57 [62336.N37452416W]
        --  0030: 31 32 32 32 35 35 30 30 39 2b 30 31 37 35 30 31 [122255009+017501]
        --  0040: 31 2b 30 31 34 2b 30 30 32 2b 30 32 36 2b 30 31 [1+014+002+026+01]
        local n = dirLen - 18
        if n > 0x101 then n = 0x101 end
        local buf2 = pack('C*', table.unpack(map(function(c) return c ~ 0xaa end, { unpack('C*', substr(dataPt, 18, n)) })))
        if (et:Options('Verbose') or 0) > 1 then
            et:VPrint(1, '[decrypted freeGPS data]')
            et:VerboseDump(buf2)
        end
        -- (extract longitude as 9 digits, not 8, ref PH)
        ok, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12 = isMatch(buf2,
            [[(?s)^.{8}(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2}).(.{15})([NS])(\d{8})([EW])(\d{9})(\d{8})?]])
        if ok then
            yr, mon, day, hr, min, sec, lbl, latRef, lat, lonRef, lon, spd = c1, c2, c3, c4, c5, c6, c7, c8, c9 / 1e4, c10, c11 / 1e4, c12
            if spd ~= nil then -- (Azdome)
                spd = perl.num(spd)  -- remove leading 0's
            else
                local _, d2 = matches(buf2, [[(?s)^.{57}([-+]\d{4})(\d{3})]])
                if d2 then -- (EEEkit)
                    -- $alt = $1 + 0;  (doesn't look right for my sample, but the Ambarella A12 text has this)
                    spd = perl.num(d2)
                end
            end
        end
        -- extract accelerometer data (ref PH)
        ok, c1, c2, c3, c4 = isMatch(buf2, [[(?s)^.{65}(([-+]\d{3})([-+]\d{3})([-+]\d{3})([-+]\d{3})*)]])
        if ok then
            local _ = c1
            acc = { c2 / 100, c3 / 100, c4 / 100 }
            _ = subst(_, [[([-+])]], ' $1', 'g')  _ = subst(_, [[^ ]], '')
            xtra[#xtra + 1] = { 'AccelerometerData', _ }
        else
            ok, c1, c2, c3 = isMatch(buf2, [[(?s)^.{173}([-+]\d{3})([-+]\d{3})([-+]\d{3})]])
            if ok then -- (Azdome)
                -- (Adzome may contain acc and date/time/label even if GPS doesn't exist)
                acc = { c1 / 100, c2 / 100, c3 / 100 }
                if yr == nil then
                    ok, c1, c2, c3, c4, c5, c6, c7 = isMatch(buf2, [[(?s)^.{8}(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2}).(.{15})]])
                    if ok then
                        yr, mon, day, hr, min, sec, lbl = c1, c2, c3, c4, c5, c6, c7
                    end
                end
            end
        end
        if lbl ~= nil then
            lbl = subst(lbl, [[(?s)\0.*]], '')  lbl = subst(lbl, [[\s+$]], '')  -- truncate at null and remove trailing spaces
            if length(lbl) > 0 then xtra[#xtra + 1] = { 'UserLabel', lbl } end
        end
        break
    end
    ok, c1, c2, c3, c4, c5, c6 = isMatch(dataPt, [[(?s)^.{52}(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})]])
    if ok then

        if truthy(debug) then et:FoundTag('GPSType', 2) end
        -- decode NMEA-format GPS data (Nextbase 512GW dashcam, ref PH)
        -- header looks like this in my sample:
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 40 01 00 00 [....freeGPS @...]
        --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0030: 00 00 00 00 32 30 31 38 30 39 31 39 31 30 30 39 [....201809191009]
        --  0040: 35 39 00 00 1c 01 00 00 06 00 00 00 ef ff ff ff [59..............]
        --  0050: 20 24 47 50 52 4d 43 2c 30 38 30 39 35 31 2e 30 [ $GPRMC,080951.0]
        --  0060: 30 30 2c 41 2c 35 32 30 37 2e 39 30 39 37 2c 4e [00,A,5207.9097,N]
        --  0070: 2c 30 30 35 30 35 2e 35 31 37 35 2c 45 2c 35 35 [,00505.5175,E,55]
        --  0080: 2e 31 31 2c 31 32 35 2e 35 38 2c 31 39 30 39 31 [.11,125.58,19091]
        --  0090: 38 2c 2c 2c 41 2a 35 39 0d 0a 00 00 00 00 00 00 [8,,,A*59........]
        xtra[#xtra + 1] = { 'CameraDateTime', c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6 }
        local _
        ok, c1, c2, c3, _, c5, c6, c7, c8, c9, c10, c11, c12, c13 = isMatch(dataPt,
            [[(?s)\$[A-Z]{2}RMC,(\d{2})(\d{2})(\d+(\.\d*)?),A?,(\d+\.\d+),([NS]),(\d+\.\d+),([EW]),(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]])
        if ok then
            lat, latRef, lon, lonRef = c5, c6, c7, c8
            yr = c13 + (perl.num(c13) >= 70 and 1900 or 2000)
            mon, day, hr, min, sec = c12, c11, c1, c2, c3
            if length(c9) > 0 then spd = c9 * knotsToKph end
            if length(c10) > 0 then trk = c10 end
        end
        ok, c1, c2, c3, _, c5, c6, c7, c8, c9, c10, c11 = isMatch(dataPt,
            [[(?s)\$[A-Z]{2}GGA,(\d{2})(\d{2})(\d+(\.\d*)?),(\d+\.\d+),([NS]),(\d+\.\d+),([EW]),[1-6]?,(\d+)?,(\.\d+|\d+\.?\d*)?,(-?\d+\.?\d*)?,M?]])
        if ok then
            if yr == nil then hr, min, sec, lat, latRef, lon, lonRef = c1, c2, c3, c5, c6, c7, c8 end
            alt = c11
            table.insert(xtra, 1, { 'GPSSatellites', c9 })
            table.insert(xtra, 1, { 'GPSDOP', c10 })
        end
        if lat ~= nil then
            -- extract accelerometer readings if GPS was valid
            -- and change to signed integer and divide by 256
            acc = map(SignedInt32_256, { unpack('x68V3', dataPt) })
        end
        break
    end
    ok, c1, c2, c3 = isMatch(dataPt, [[(?s)^(.{37}|.{85})\0\0\0A([NS])([EW])\0]])
    if ok then

        if length(c1) == 85 then
            -- Kenwood DRV-A510W (header is 48 bytes longer)
            -- 0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
            -- 0010: 4d 4e 3a 44 52 56 2d 41 35 31 30 57 40 56 31 2e [MN:DRV-A510W@V1.]
            -- 0020: 37 5f 42 44 5a 49 43 5a 5f 43 00 00 00 00 00 00 [7_BDZICZ_C......]
            -- 0030: 00 00 00 00 00 00 00 00 3a 3a 73 74 61 72 74 40 [........::start@]
            -- 0040: 0c 00 00 00 10 00 00 00 16 00 00 00 ea 07 00 00 [................]
            -- 0050: 02 00 00 00 1c 00 00 00 41 4e 57 00 55 e7 a5 45 [........ANW.U..E]
            -- 0060: d7 84 52 43 52 b8 d8 41 48 21 9a 43 f9 ff ff ff [..RCR..AH!.C....]
            -- 0070: ff ff ff ff 01 00 00 00 00 00 00 00 00 00 00 00 [................]
            dataPt = substr(dataPt, 48)
            dirInfo.DataPt = dataPt -- (upstream changes the caller's buffer)
        end
        latRef, lonRef = c2, c3
        hr, min, sec, yr, mon, day = unpack('x16V6', dataPt)
        -- test for base64-encoded and encrypted lucky gps strings
        local notEnc, notStr, lt, ln
        if length(dataPt) < 0x78 then
            notEnc, notStr = 1, 1
        else
            lt = substr(dataPt, 0x2c, 20) -- latitude
            ln = substr(dataPt, 0x40, 20) -- longitude
            for _, v in ipairs({ lt, ln }) do if not isMatch(v, [[^[A-Za-z0-9+\/]{8,20}={0,2}\0*$]]) then notEnc = 1 break end end
            for _, v in ipairs({ lt, ln }) do if not isMatch(v, [[^\d{1,5}\.\d+\0*$]]) then notStr = 1 break end end
        end
        if notEnc and notStr then

            if truthy(debug) then et:FoundTag('GPSType', 3) end
            -- decode freeGPS from ViofoA119v3 dashcam (similar to Novatek GPS format)
            -- 0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
            -- 0010: 05 00 00 00 2f 00 00 00 03 00 00 00 13 00 00 00 [..../...........]
            -- 0020: 09 00 00 00 1b 00 00 00 41 4e 57 00 25 d1 99 45 [........ANW.%..E]
            -- 0030: f1 47 40 46 66 66 d2 41 85 eb 83 41 00 00 00 00 [.G@Fff.A...A....]
            if yr >= 2000 then
                -- Kenwood dashcam sometimes stores absolute year and local time
                -- (but sometimes year since 2000 and UTC time in same video!)
                local time = ExifTool.TimeLocal(sec, min, hr, day, mon - 1, yr)
                local gm = perl.gmtime(time)
                sec, min, hr, day, mon, yr = gm[1], gm[2], gm[3], gm[4], gm[5], gm[6]
                yr = yr + 1900
                mon = mon + 1
                et:Warn('Converting GPSDateTime to UTC based on local time zone', 1)
            end
            lat = GetFloat(dataPt, 0x2c)
            lon = GetFloat(dataPt, 0x30)
            spd = GetFloat(dataPt, 0x34) * knotsToKph
            trk = GetFloat(dataPt, 0x38)
            -- (may be all zeros or int16u counting from 1 to 6 if not valid)
            local tmp = substr(dataPt, 60, 12)
            if tmp ~= "\0\0\0\0\0\0\0\0\0\0\0\0" and tmp ~= "\x01\0\x02\0\x03\0\x04\0\x05\0\x06\0" then
                acc = map(SignedInt32_256, { unpack('V3', tmp) })
            end

        else

            if truthy(debug) then et:FoundTag('GPSType', 4) end
            -- decode freeGPS from E-ACE B44 dashcam
            -- 0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
            -- 0010: 08 00 00 00 22 00 00 00 01 00 00 00 18 00 00 00 [...."...........]
            -- 0020: 08 00 00 00 10 00 00 00 41 4e 45 00 67 4e 69 69 [........ANE.gNii]
            -- 0030: 5a 38 4a 54 74 48 63 61 36 74 77 3d 00 00 00 00 [Z8JTtHca6tw=....]
            -- 0040: 68 74 75 69 5a 4d 4a 53 73 58 55 58 37 4e 6f 3d [htuiZMJSsXUX7No=]
            -- 0050: 00 00 00 00 64 3b ac 41 e1 3a 1d 43 2b 01 00 00 [....d;.A.:.C+...]
            -- 0060: fd ff ff ff 43 00 00 00 32 4a 37 31 50 70 55 48 [....C...2J71PpUH]
            -- 0070: 37 69 68 66 00 00 00 00 00 00 00 00 00 00 00 00 [7ihf............]
            -- (16-byte string at 0x68 is base64 encoded and encrypted 'luckychip' string)
            spd = GetFloat(dataPt, 0x54) * knotsToKph
            trk = GetFloat(dataPt, 0x58)
            acc = map(SignedInt32, { unpack('x92V3', dataPt) })
            -- (accelerometer scaling is roughly 1G=250-300, but it varies depending on the axis,
            --  so leave the values as raw.  The axes are positive acceleration up,left,forward)
            if notEnc then -- (not encrypted)
                lat = subst(lt, [[\0+$]], '')
                lon = subst(ln, [[\0+$]], '')
            else
                -- decode base64 strings
                local XMP = require('lexiftool.XMP')
                lt = XMP.DecodeBase64(lt)  ln = XMP.DecodeBase64(ln)
                -- try various keys to decrypt lat/lon
                local ch, key = 'a', luckyKeys[1]
                for i = 0, 19 do
                    if i ~= 0 then key = subst(luckyKeys[2], '#', ch, 'g') ch = string.char(ch:byte() + 1) end
                    lat = QuickTimeStream.DecryptLucky(lt, key)
                    if not isMatch(lat, [[^\d{1,4}\.\d+$]]) then lat = nil goto continue end
                    lon = QuickTimeStream.DecryptLucky(ln, key)
                    if not isMatch(lon, [[^\d{1,5}\.\d+$]]) then lon = nil goto continue end
                    break
                    ::continue::
                end
                if not truthy(lon) then et:Warn('Unknown encryption for latitude/longitude') end
            end
        end
        break
    end
    ok, c1 = isMatch(dataPt, [[(?s)^(.{16}|.{48}|.{80})LIGOGPSINFO\0]])
    if ok and length(dataPt) >= length(c1) + 0x84 then

        if truthy(debug) then et:FoundTag('GPSType', 5) end
        local pos = length(c1)
        -- iiway s1 dual dash cam - offset 16, encrypted and fuzzed with scale 1
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
        --  0010: 4c 49 47 4f 47 50 53 49 4e 46 4f 00 00 00 00 05 [LIGOGPSINFO.....]
        --  0020: 0a 00 00 00 23 23 23 23 6a 00 00 00 c0 20 20 20 [....####j....   ]
        --  0030: 20 f0 12 10 12 22 e1 0e 10 12 2f 90 10 13 02 f2 [ ...."..../.....]
        -- XGODY 12" 4K Dashcam - offset 16, encrypted and fuzzed with scale 1
        --  0000: 00 00 00 a8 66 72 65 65 47 50 53 20 98 00 00 00 [....freeGPS ....]
        --  0010: 4c 49 47 4f 47 50 53 49 4e 46 4f 00 00 00 00 05 [LIGOGPSINFO.....]
        --  0020: cd 61 00 00 23 23 23 23 6d 00 00 00 c1 ec 41 20 [.a..####m.....A ]
        --  0030: 20 f0 12 10 12 24 e5 0e 10 11 2f 92 10 12 00 f6 [ ....$..../.....]
        -- ABASK A8 4K Dashcam - offset 16, encrypted and fuzzed with scale 3
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
        --  0010: 4c 49 47 4f 47 50 53 49 4e 46 4f 00 00 00 00 05 [LIGOGPSINFO.....]
        --  0020: 00 00 00 00 23 23 23 23 69 00 00 00 c0 20 20 20 [....####i....   ]
        --  0030: 20 f0 12 10 12 23 e5 0e 10 12 2f 99 10 11 02 f2 [ ....#..../.....]
        -- Unknown dashcam (forum16060) - offset 16, enciphered and fuzzed with scale 1
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 98 00 00 00 [..@.freeGPS ....]
        --  0010: 4c 49 47 4f 47 50 53 49 4e 46 4f 00 00 00 00 0d [LIGOGPSINFO.....]
        --  0020: 0a 00 00 00 23 23 23 23 3b 00 a0 34 46 44 46 31 [....####;..4FDF1]
        --  0030: 2f 44 39 2f 45 38 20 44 3d 4c 47 4a 4c 39 38 20 [/D9/E8 D=LGJL98 ]
        -- Rexing dashcam V1GW-4K - offset 48, encrypted and fuzzed with scale 1
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
        --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0030: 4c 49 47 4f 47 50 53 49 4e 46 4f 00 00 00 00 05 [LIGOGPSINFO.....]
        --  0040: 01 00 00 00 23 23 23 23 73 00 00 00 c0 20 20 20 [....####s....   ]
        --  0050: 20 f0 12 10 12 23 e5 0e 10 12 2f 95 10 12 01 f3 [ ....#..../.....]
        -- Kingslim D4 dashcam - offset 80, encrypted and fuzzed with scale 1
        --  0000: 0a 00 00 00 0b 00 00 00 07 00 00 00 e5 07 00 00 [................]
        --  0010: 06 00 00 00 03 00 00 00 41 4e 57 31 91 52 83 45 [........ANW1.R.E]
        --  0020: 15 70 fe c5 29 5c c3 41 ae c7 af 42 00 00 d1 be [.p..)\.A...B....]
        --  0030: 00 00 80 3b 00 00 2c 3e 00 00 00 00 00 00 00 00 [...;..,>........]
        --  0040: 00 00 00 00 00 00 00 00 00 00 00 00 26 26 26 26 [............&&&&]
        --  0050: 4c 49 47 4f 47 50 53 49 4e 46 4f 00 00 00 00 05 [LIGOGPSINFO.....]
        --  0060: 01 00 00 00 23 23 23 23 75 00 00 00 c0 22 20 20 [....####u...."  ]
        --  0070: 20 f0 12 10 12 21 e5 0e 10 12 2f 90 10 13 01 f2 [ ....!..../.....]
        local dirInfo_ = { DataPt = dataPt, DirStart = pos, DirName = 'LigoGPS_' .. pos }
        -- (this is weak, but the only difference I could find between these 2 headers)
        -- (NOTE: ../testpics/gps_video/forum16229.mp4 uses this word for a counter!)
        if pos == 16 and isMatch(dataPt, [[(?s)^.{12}\xf0\x03\0\0.{16}\0{4}]]) then et.LigoGPSScale = 3 end
        require('lexiftool.LigoGPS').ProcessLigoGPS(et, dirInfo_, tagTbl)
        done = 1

        -- also... when offset is 0x50 (Kingslim), the GPS also exists in this format:
        -- ($latRef, $lonRef) = ($1, $2);
        -- ($hr,$min,$sec,$yr,$mon,$day) = unpack("V6", $$dataPt);
        -- # lat/lon aren't decoded properly, but spd,trk,acc are
        -- $lat = GetFloat($dataPt, 0x1c);
        -- $lon = GetFloat($dataPt, 0x20);
        -- $et->VPrint(0, sprintf("Raw lat/lon = %.9f %.9f\n", $lat, $lon));
        -- $et->Warn('GPSLatitude/Longitude encryption is not yet known, so these will be wrong');
        -- $lat = abs $lat;
        -- $lon = abs $lon;
        -- $spd = GetFloat($dataPt, 0x24) * $knotsToKph; # (convert knots to km/h)
        -- $trk = GetFloat($dataPt, 0x28);
        -- $acc[0] = GetFloat($dataPt, 0x2c);
        -- $acc[1] = GetFloat($dataPt, 0x30);
        -- $acc[2] = GetFloat($dataPt, 0x34);
        break
    end
    ok, c1, c2 = isMatch(dataPt, [[(?s)^.{60}A\0{3}.{4}([NS])\0{3}.{4}([EW])\0{3}]])
    if ok then

        if truthy(debug) then et:FoundTag('GPSType', 6) end
        -- decode freeGPS from Akaso dashcam
        -- 0000: 00 00 80 00 66 72 65 65 47 50 53 20 60 00 00 00 [....freeGPS `...]
        -- 0010: 78 2e 78 78 00 00 00 00 00 00 00 00 00 00 00 00 [x.xx............]
        -- 0020: 30 30 30 30 30 00 00 00 00 00 00 00 00 00 00 00 [00000...........]
        -- 0030: 12 00 00 00 2f 00 00 00 19 00 00 00 41 00 00 00 [..../.......A...]
        -- 0040: 13 b3 ca 44 4e 00 00 00 29 92 fb 45 45 00 00 00 [...DN...)..EE...]
        -- 0050: d9 ee b4 41 ec d1 d3 42 e4 07 00 00 01 00 00 00 [...A...B........]
        -- 0060: 0c 00 00 00 01 00 00 00 05 00 00 00 00 00 00 00 [................]
        -- (unknown dashcam, "Anticlock 2 2020_1125_1455_007.MOV"):
        -- 0000: 00 00 80 00 66 72 65 65 47 50 53 20 68 00 00 00 [....freeGPS h...]
        -- 0010: 32 30 31 33 30 33 32 35 41 00 00 00 00 00 00 00 [20130325A.......]
        -- 0020: 41 70 72 20 20 36 20 32 30 31 36 2c 20 31 36 3a [Apr  6 2016, 16:]
        -- 0030: 0e 00 00 00 38 00 00 00 22 00 00 00 41 00 00 00 [....8..."...A...]
        -- 0040: 8a 63 24 45 53 00 00 00 9f e6 42 45 45 00 00 00 [.c$ES.....BEE...]
        -- 0050: 59 c0 04 3f 52 b8 42 41 14 00 00 00 0b 00 00 00 [Y..?R.BA........]
        -- 0060: 19 00 00 00 06 00 00 00 05 00 00 00 f6 ff ff ff [................]
        -- 0070: 03 00 00 00 04 00 00 00 00 00 00 00 00 00 00 00 [................]
        latRef, lonRef = c1, c2
        hr, min, sec, yr, mon, day, acc[1], acc[2], acc[3] = unpack('x48V3x28V6', dataPt)
        lat = GetFloat(dataPt, 0x40)
        lon = GetFloat(dataPt, 0x48)
        spd = GetFloat(dataPt, 0x50)
        trk = GetFloat(dataPt, 0x54)
        if substr(dataPt, 16, 4) == 'x.xx' then
            trk = trk + 180   -- (why is this off by 180?)
            if trk >= 360 then trk = trk - 360 end
            acc = {}
        else
            acc = map(SignedInt32_1000, acc) -- (NC)
        end
        break
    end
    if isMatch(dataPt, [[(?s)^.{60}4W`b]S<]]) and length(dataPt) >= 140 then

        if truthy(debug) then et:FoundTag('GPSType', 7) end
        -- 0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 01 00 00 [..@.freeGPS ....]
        -- 0010: 5a 58 53 42 4e 58 59 53 00 00 00 00 00 00 00 00 [ZXSBNXYS........]
        -- 0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        -- 0030: 00 00 00 00 00 00 00 00 00 00 00 00 34 57 60 62 [............4W`b]
        -- 0040: 5d 53 3c 41 44 45 41 41 42 3e 40 40 3c 51 3c 45 []S<ADEAAB>@@<Q<E]
        -- 0050: 41 40 43 3e 41 47 49 48 44 3c 5e 3c 40 41 46 43 [A@C>AGIHD<^<@AFC]
        -- 0060: 42 3e 49 49 40 42 45 3c 55 3c 45 47 3e 45 43 41 [B>II@BE<U<EG>ECA]
        -- decipher $GPRMC by subtracting 16 from each character value
        -- (Perl's `$_>=16 and $_-=16` yields '' -- packed as 0 -- below 16)
        local _ = pack('C*', table.unpack(map(function(c) if c >= 16 then return c - 16 end return 0 end, { unpack('x60C80', dataPt) })))
        ok, c1, c2, c3, _, c5, c6, c7, c8, c9, c10, c11, c12, c13 = isMatch(_,
            [[[A-Z]{2}RMC,(\d{2})(\d{2})(\d+(\.\d*)?),A?,(\d*?\d{1,2}\.\d+),([NS]),(\d*?\d{1,2}\.\d+),([EW]),(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]])
        if ok then
            yr, mon, day, hr, min, sec, lat, latRef, lon, lonRef = c13, c12, c11, c1, c2, c3, c5, c6, c7, c8
            yr = yr + (perl.num(yr) >= 70 and 1900 or 2000)
            if length(c9) > 0 then spd = c9 * knotsToKph end
            if length(c10) > 0 then trk = c10 end
        else
            done = 1
        end
        break
    end
    if isMatch(dataPt, [[(?s)^.{64}[\x01-\x0c]\0{3}[\x01-\x1f]\0{3}A[NS][EW]\0{5}]]) then

        if truthy(debug) then et:FoundTag('GPSType', 8) end
        -- Akaso V1 dascham
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 78 00 00 00 [....freeGPS x...]
        --  0010: 59 6e 64 41 6b 61 73 6f 43 61 72 00 00 00 00 00 [YndAkasoCar.....]
        --  0020: 30 30 30 30 30 00 00 00 00 00 00 00 00 00 00 00 [00000...........]
        --  0030: 0e 00 00 00 27 00 00 00 2c 00 00 00 e3 07 00 00 [....'...,.......]
        --  0040: 05 00 00 00 1d 00 00 00 41 4e 45 00 00 00 00 00 [........ANE.....]
        --  0050: f1 4e 3e 3d 90 df ca 40 e3 50 bf 0b 0b 31 a0 40 [.N>=...@.P...1.@]
        --  0060: 4b dc c8 41 9a 79 a7 43 34 58 43 31 4f 37 31 35 [K..A.y.C4XC1O715]
        --  0070: 35 31 32 36 36 35 37 35 59 4e 44 53 0d e7 cc f9 [51266575YNDS....]
        --  0080: 00 00 00 00 05 00 00 00 00 00 00 00 00 00 00 00 [................]
        -- Redtiger F7N dashcam
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 01 00 00 [..@.freeGPS ....]
        --  0010: 0a 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0020: 01 00 00 00 b0 56 50 01 7b 18 68 45 17 02 3f 46 [.....VP.{.hE..?F]
        --  0030: 13 00 00 00 01 00 00 00 06 00 00 00 15 00 00 00 [................]
        --  0040: 0c 00 00 00 1c 00 00 00 41 4e 57 00 00 00 00 00 [........ANW.....]
        --  0050: 80 d4 26 4e 36 11 b5 40 74 b5 15 7b cd 7b f3 40 [..&N6..@t..{.{.@]
        --  0060: 0a d7 a3 3d cd 4c 4e 43 38 34 37 41 45 48 31 36 [...=.LNC847AEH16]
        --  0070: 33 36 30 38 32 34 35 37 59 53 4b 4a 01 00 00 00 [36082457YSKJ....]
        --  0080: ec ff ff ff 00 00 00 00 0e 00 00 00 01 00 00 00 [................]
        --  0090: 0a 00 00 00 e5 07 00 00 0c 00 00 00 1c 00 00 00 [................]
        hr, min, sec, yr, mon, day, stat, latRef, lonRef =
            unpack('x48V6a1a1a1x1', dataPt)

        et:Warn('GPSLatitude/Longitude encryption is not yet known, so these will be wrong')
        -- (see https://exiftool.org/forum/index.php?topic=11320.0)

        spd = GetFloat(dataPt, 0x60)
        trk = GetFloat(dataPt, 0x64) + 180   -- (why is this off by 180?)
        lat = GetDouble(dataPt, 0x50)    -- latitude is here, but encrypted somehow
        lon = GetDouble(dataPt, 0x58)    -- longitude is here, but encrypted somehow
        ddd = 1 -- don't convert until we know what the format is
        --my $serialNum = substr($$dataPt, 0x68, 20); # (confirmed)
        break
    end
    if isMatch(dataPt, [[(?s)^.{12}\xac\0\0\0.{44}(.{72})]]) then

        if truthy(debug) then et:FoundTag('GPSType', 9) end
        -- EACHPAI dash cam
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 ac 00 00 00 [....freeGPS ....]
        --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0030: 00 00 00 00 00 00 00 00 00 00 00 00 34 57 60 62 [............4W`b]
        --  0040: 5d 53 3c 41 47 45 45 42 42 3e 40 40 40 3c 51 3c []S<AGEEBB>@@@<Q<]
        --  0050: 44 42 44 40 3e 48 46 43 45 3c 5e 3c 40 48 43 41 [DBD@>HFCE<^<@HCA]
        --  0060: 42 3e 46 42 47 48 3c 67 3c 40 3e 40 42 3c 43 3e [B>FBGH<g<@>@B<C>]
        --  0070: 43 41 3c 40 42 40 46 42 40 3c 3c 3c 51 3a 47 46 [CA<@B@FB@<<<Q:GF]
        --  0080: 00 2a 36 35 00 00 00 00 00 00 00 00 00 00 00 00 [.*65............]

        et:Warn("Can't yet decrypt EACHPAI timed GPS", 1)
        -- (see https://exiftool.org/forum/index.php?topic=5095.msg61266#msg61266)
        done = 1

      --  my $time = pack 'C*', map { $_ ^= 0 } unpack 'C*', $1;
      --  # bytes 7-12 are the timestamp in ASCII HHMMSS after xor-ing with 0x70
      --  substr($time,7,6) = pack 'C*', map { $_ ^= 0x70 } unpack 'C*', substr($time,7,6);
      --  # (other values are currently unknown)
        break
    end
    ok, c1, c2 = isMatch(dataPt, [[(?s)^.{64}A([NS])([EW])\0]])
    if ok then

        if truthy(debug) then et:FoundTag('GPSType', 10) end
        -- Vantrue S1 dashcam
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 78 00 00 00 [....freeGPS x...]
        --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0030: 68 6f 72 73 6f 6e 74 65 63 68 00 00 00 00 00 00 [horsontech......]
        --  0040: 41 4e 45 00 15 00 00 00 07 00 00 00 02 00 00 00 [ANE.............]
        --  0050: 03 00 00 00 35 00 00 00 05 00 00 00 4f 74 4c 44 [....5.......OtLD]
        --  0060: e2 77 a0 45 89 c1 98 42 71 bd ac 42 02 ab 0d 43 [.w.E...Bq..B...C]
        --  0070: 05 00 00 00 7f 00 00 00 07 01 00 00 00 00 00 00 [................]
        latRef, lonRef = c1, c2
        yr, mon, day, hr, min, sec, acc[1], acc[2], acc[3] = unpack('x68V6x20V3', dataPt)
        if mon >= 1 and mon <= 12 and day >= 1 and day <= 31 then
            -- (not sure about acc scaling)
            acc = map(SignedInt32_1000, acc)
            lon = GetFloat(dataPt, 0x5c)
            lat = GetFloat(dataPt, 0x60)
            spd = GetFloat(dataPt, 0x64) * knotsToKph
            trk = GetFloat(dataPt, 0x68)
            alt = GetFloat(dataPt, 0x6c)
        else
            done = 1
        end
        break
    end
    if substr(dataPt, 0x45, 3) == 'ATC' then

        if truthy(debug) then et:FoundTag('GPSType', 11) end
        -- header looks like this: (sample 1)
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 38 06 00 00 [....freeGPS 8...]
        --  0010: 49 51 53 32 30 31 33 30 33 30 36 42 00 00 00 00 [IQS20130306B....]
        --  0020: 4d 61 79 20 31 35 20 32 30 31 35 2c 20 31 39 3a [May 15 2015, 19:]
        -- (sample 2)
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 4c 06 00 00 [....freeGPS L...]
        --  0010: 32 30 31 33 30 33 31 38 2e 30 31 00 00 00 00 00 [20130318.01.....]
        --  0020: 4d 61 72 20 31 38 20 32 30 31 33 2c 20 31 34 3a [Mar 18 2013, 14:]

        local recPos, lastRecPos, foundNew
        local verbose = et:Options('Verbose')
        local dataPos = dirInfo.DataPos
        if not et.FreeGPS2 then et.FreeGPS2 = {} end
        local then_ = et.FreeGPS2.Then
        if not then_ then then_ = { 0, 0, 0, 0, 0, 0 } et.FreeGPS2.Then = then_ end
        -- Loop through records in the ATC-type GPS block until we find the most recent.
        -- If we have already found one, then we only need to check the first record
        -- (in case the buffer wrapped around), and the record after the position of
        -- the last record we found, because the others will be old.  Odd, but this
        -- is the way it is done...  I have only seen one new 52-byte record in the
        -- entire 32 kB block, but the entire device ring buffer (containing 30
        -- entries in my samples) is stored every time.  The code below allows for
        -- the possibility of missing blocks and multiple new records in a single
        -- block, but I have never seen this.  Note that there may be some earlier
        -- GPS records at the end of the first block that we will miss decoding, but
        -- these should (I believe) be before the start of the video
        recPos = 0x30
        while recPos + 52 < dirLen do -- (ATCRec:)
            do
                local a = substr(dataPt, recPos, 52) -- isolate a single record
                -- decrypt record
                local a_ = { unpack('C*', a) }
                local key1, key2 = a_[0x14 + 1], a_[0x1c + 1]
                for j = 0x00, 0x14 do a_[j + 1] = a_[j + 1] ~ key1 end
                for j = 0x18, 0x1b do a_[j + 1] = a_[j + 1] ~ key1 end
                a_[0x1c + 1] = a_[0x1c + 1] ~ key2
                for j = 0x20, 0x32 do a_[j + 1] = a_[j + 1] ~ key2 end
                local b = pack('C*', table.unpack(a_))
                -- unpack and validate date/time
                local now = { unpack('x13C3x28vC2', b) } -- (H-1,M,S,Y,m,d)
                now[1] = (now[1] + 1) & 0xff     -- increment hour
                for i = 0, #dateMax - 1 do
                    if now[i + 1] > dateMax[i + 1] then
                        et:Warn('Invalid GPS date/time')
                        goto ATCRec    -- ignore this record (next ATCRec)
                    end
                end
                -- look for next ATC record in temporal sequence
                for _, i in ipairs({ 3, 4, 5, 0, 1, 2 }) do
                    if now[i + 1] < then_[i + 1] then
                        if foundNew then goto ATCRec_last end
                        break
                    end
                    if now[i + 1] == then_[i + 1] then goto nextI end
                    -- we found a more recent record -- extract it and remember its location
                    if truthy(verbose) then
                        et:VPrint(2, "  + [encrypted GPS record]\n")
                        et:VerboseDump(a, { DataPos = (dataPos or 0) + recPos })
                        et:VPrint(2, "  + [decrypted GPS record]\n")
                        et:VerboseDump(b)
                        --my @v = unpack 'H8VVC4V!CA3V!CA3VvvV!vCCCCH4', $b;
                        --$et->VPrint(2, "  + [unpacked: @v]\n");
                        -- values unpacked above (ref PH):
                        --  0) 0x00 4 bytes - byte 0=1, 1=counts to 255, 2=record index, 3=0 (ref 3)
                        --  1) 0x04 4 bytes - int32u: bits 0-4=day, 5-8=mon, 9-19=year (ref 3)
                        --  2) 0x08 4 bytes - int32u: bits 0-5=sec, 6-11=min, 12-16=hour (ref 3)
                        --  3) 0x0c 1 byte  - seen values of 0,1,2 - GPS status maybe?
                        --  4) 0x0d 1 byte  - hour minus 1
                        --  5) 0x0e 1 byte  - minute
                        --  6) 0x0f 1 byte  - second
                        --  7) 0x10 4 bytes - int32s latitude * 1e7
                        --  8) 0x14 1 byte  - always 0 (used for decryption)
                        --  9) 0x15 3 bytes - always "ATC"
                        -- 10) 0x18 4 bytes - int32s longitude * 1e7
                        -- 11) 0x1c 1 byte  - always 0 (used for decryption)
                        -- 12) 0x1d 3 bytes - always "001"
                        -- 13) 0x20 4 bytes - int32s speed * 100 (m/s)
                        -- 14) 0x24 2 bytes - int16u heading * 100 (-180 to 180 deg)
                        -- 15) 0x26 2 bytes - always zero
                        -- 16) 0x28 4 bytes - int32s altitude * 1000 (ref 3)
                        -- 17) 0x2c 2 bytes - int16u year
                        -- 18) 0x2e 1 byte  - month
                        -- 19) 0x2f 1 byte  - day
                        -- 20) 0x30 1 byte  - unknown
                        -- 21) 0x31 1 byte  - always zero
                        -- 22) 0x32 2 bytes - checksum ?
                    end
                    for k = 1, #now do then_[k] = now[k] end
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    trk = Get16s(b, 0x24) / 100
                    if trk < 0 then trk = trk + 360 end
                    local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', now[4], now[5], now[6], now[1], now[2], now[3])
                    et:HandleTag(tagTbl, 'GPSDateTime', time)
                    et:HandleTag(tagTbl, 'GPSLatitude', Get32s(b, 0x10) / 1e7)
                    et:HandleTag(tagTbl, 'GPSLongitude', Get32s(b, 0x18) / 1e7)
                    et:HandleTag(tagTbl, 'GPSSpeed', Get32s(b, 0x20) / 100 * mpsToKph)
                    et:HandleTag(tagTbl, 'GPSTrack', trk)
                    et:HandleTag(tagTbl, 'GPSAltitude', Get32s(b, 0x28) / 1000)
                    lastRecPos = recPos
                    foundNew = 1
                    -- don't skip to location of previous recent record in ring buffer
                    -- since we found a more recent record here
                    et.FreeGPS2.RecentRecPos = nil
                    do break end
                    ::nextI::
                end
                -- skip older records
                local recentRecPos = et.FreeGPS2.RecentRecPos
                if truthy(recentRecPos) and recPos < recentRecPos then recPos = recentRecPos end
            end
            ::ATCRec::
            recPos = recPos + 52
        end
        ::ATCRec_last::
        -- save position of most recent record (needed when parsing the next freeGPS block)
        et.FreeGPS2.RecentRecPos = lastRecPos
        done = 1
        break
    end
    ok, c1, c2 = isMatch(dataPt, [[(?s)^.{60}A\0.{10}([NS])\0.{14}([EW])\0]])
    if ok and dirLen >= 0x88 then

        if truthy(debug) then et:FoundTag('GPSType', 12) end
        -- header looks like this in my sample:
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 08 01 00 00 [....freeGPS ....]
        --  0010: 32 30 31 33 30 38 31 35 2e 30 31 00 00 00 00 00 [20130815.01.....]
        --  0020: 4a 75 6e 20 31 30 20 32 30 31 37 2c 20 31 34 3a [Jun 10 2017, 14:]

        -- Type 2 (ref PH):
        -- 0x30 - int32u hour
        -- 0x34 - int32u minute
        -- 0x38 - int32u second
        -- 0x3c - int32u GPS status ('A' or 'V')
        -- 0x40 - double latitude  (DDMM.MMMMMM)
        -- 0x48 - int32u latitude ref  ('N' or 'S')
        -- 0x50 - double longitude (DDMM.MMMMMM)
        -- 0x58 - int32u longitude ref ('E' or 'W')
        -- 0x60 - double speed (knots)
        -- 0x68 - double heading (deg)
        -- 0x70 - int32u year - 2000
        -- 0x74 - int32u month
        -- 0x78 - int32u day
        -- 0x7c - int32s[3] accelerometer * 1000
        latRef, lonRef = c1, c2
        hr, min, sec, yr, mon, day, acc[1], acc[2], acc[3] = unpack('x48V3x52V6', dataPt)
        acc = map(SignedInt32_1000, acc)
        lat = GetDouble(dataPt, 0x40)
        lon = GetDouble(dataPt, 0x50)
        spd = GetDouble(dataPt, 0x60) * knotsToKph
        trk = GetDouble(dataPt, 0x68)
        break
    end
    if isMatch(dataPt, [[(?s)^.{16}A([NS])([EW])\0]]) then

        if truthy(debug) then et:FoundTag('GPSType', 13) end
        -- INNOVV MP4 video (same format as INNOVV TS)
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
        --  0010: 41 4e 45 00 e4 56 96 45 86 b1 ca 44 5c 8f e2 40 [ANE..V.E...D\..@]
        --  0020: 33 33 58 43 c3 00 00 00 30 00 00 00 a0 fe ff ff [33XC....0.......]
        --  0030: 41 4e 45 00 e3 56 96 45 82 b1 ca 44 5c 8f fa 40 [ANE..V.E...D\..@]
        --  0040: c3 75 56 43 8c ff ff ff 8c 00 00 00 c3 fd ff ff [.uVC............]
        for dat in eachMatch(dataPt, [[(?s)(A[NS][EW]\0.{28})]]) do
            lat = math.abs(GetFloat(dat, 4)) -- (abs just to be safe)
            lon = math.abs(GetFloat(dat, 8)) -- (abs just to be safe)
            spd = GetFloat(dat, 12) * knotsToKph
            trk = GetFloat(dat, 16)
            acc = map(SignedInt32, { unpack('x20V3', dat) })
            lat, lon = ConvertLatLon(lat, lon)
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            et:HandleTag(tagTbl, 'GPSLatitude', lat * (substr(dat, 1, 1) == 'S' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSLongitude', lon * (substr(dat, 2, 1) == 'W' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSSpeed', spd)
            et:HandleTag(tagTbl, 'GPSTrack', trk)
            et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
        end
        done = 1
        break
    end
    if isMatch(dataPt, [[(?s)^.{20}[\0-\x18][\0-\x3b]{2}[\0-\x09]A([NS])([EW])]]) then

        if truthy(debug) then et:FoundTag('GPSType', 14) end
        -- XBHT motorcycle dashcam Model XB702
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
        --  0010: 00 17 05 11 0d 25 18 00 41 4e 45 64 83 3f 00 00 [.....%..ANEd.?..]
        --  0020: 44 3d c5 02 48 6d ff 07 df 03 00 00 6b 00 00 00 [D=..Hm......k...]
        --  0030: 00 00 00 00 00 17 05 11 0d 25 18 01 41 4e 45 64 [.........%..ANEd]
        --  0040: 8b 3f 00 00 30 3d c5 02 50 6d ff 07 df 03 00 00 [.?..0=..Pm......]
        for dat in eachMatch(dataPt, [[(?s)(.{7}[\0-\x09]A[NS][EW].{25})]]) do
            yr, mon, day, hr, min, sec, ss, latRef, lonRef, lat, lon, spd =
                unpack('xC7xCCx5VVx4v', dat)
            yr = yr + 2000  lat = lat / 1e4  lon = lon / 1e4
            lat, lon = ConvertLatLon(lat, lon)
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d.%d', yr, mon, day, hr, min, sec, ss)
            et:HandleTag(tagTbl, 'GPSDateTime', time)
            et:HandleTag(tagTbl, 'GPSLatitude', lat * (latRef == 'S' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSLongitude', lon * (lonRef == 'W' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSSpeed', spd)
        end
        done = 1
        break
    end
    ok, c1, c2 = isMatch(dataPt, [[(?s)^.{28}A.{11}([NS]).{15}([EW])]])
    if ok then

        if truthy(debug) then et:FoundTag('GPSType', 15) end
        -- Vantrue N4 dashcam
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 f0 03 00 00 [..@.freeGPS ....]
        --  0010: 0d 00 00 00 16 00 00 00 1e 00 00 00 41 00 00 00 [............A...]
        --  0020: 2c b7 b4 1a 5a 71 b2 40 4e 00 00 00 00 00 00 00 [,...Zq.@N.......]
        --  0030: fb ae 08 fe 77 f6 89 40 45 00 00 00 00 00 00 00 [....w..@E.......]
        --  0040: be 9f 1a 2f dd 84 36 40 5c 8f c2 f5 28 fc 68 40 [.../..6@\...(.h@]
        --  0050: 16 00 00 00 0c 00 00 00 0e 00 00 00 f2 fb ff ff [................]
        --  0060: 42 00 00 00 02 00 00 00 20 24 47 4e 52 4d 43 2c [B....... $GNRMC,]
        --  0070: 31 33 32 32 33 30 2e 30 30 30 2c 41 2c 34 37 32 [132230.000,A,472]
        --  0080: 31 2e 33 35 31 39 37 2c 4e 2c 30 30 38 33 30 2e [1.35197,N,00830.]
        --  0090: 38 30 38 35 39 2c 45 2c 32 32 2e 35 31 39 2c 31 [80859,E,22.519,1]
        --  00a0: 39 39 2e 38 38 2c 31 34 31 32 32 32 2c 2c 2c 41 [99.88,141222,,,A]
        --  00b0: 2a 37 35 0d 0a 00 00 00 00 00 00 00 00 00 00 00 [*75.............]
        latRef, lonRef = c1, c2
        hr, min, sec, yr, mon, day, acc[1], acc[2], acc[3] = unpack('x16V3x52V3V3', dataPt)
        lat = math.abs(GetDouble(dataPt, 32)) -- (abs just to be safe)
        lon = math.abs(GetDouble(dataPt, 48)) -- (abs just to be safe)
        spd = GetDouble(dataPt, 64) * knotsToKph
        trk = GetDouble(dataPt, 72)
        acc = map(SignedInt32_1000, acc) -- (NC)
        -- (not necessary to read RMC sentence because we already have it all)
        break
    end
    if isMatch(dataPt, [[(?s)^.{72}A[NS][EW]\0]]) then

        -- decode binary GPS format (Viofo A119S, ref 2)
        -- header looks like this in my sample:
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 4c 00 00 00 [....freeGPS L...]
        --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        --  0030: 10 00 00 00 2d 00 00 00 14 00 00 00 11 00 00 00 [....-...........]
        --  0040: 0c 00 00 00 1f 00 00 00 41 4e 45 00 5d 9a a9 45 [........ANE.]..E]
        --  0050: ab 1e e5 44 ec 51 f0 40 b8 5e a5 43 00 00 00 00 [...D.Q.@.^.C....]
        -- (records are same structure as Type 3 Novatek GPS:)
        -- Type 3 (Novatek GPS, ref 2):
        -- 0x30 - int32u hour
        -- 0x34 - int32u minute
        -- 0x38 - int32u second
        -- 0x3c - int32u year - 2000
        -- 0x40 - int32u month
        -- 0x44 - int32u day
        -- 0x48 - int8u  GPS status ('A' or 'V')
        -- 0x49 - int8u  latitude ref  ('N' or 'S')
        -- 0x4a - int8u  longitude ref ('E' or 'W')
        -- 0x4b - 0
        -- 0x4c - float  latitude  (DDMM.MMMMMM)
        -- 0x50 - float  longitude (DDMM.MMMMMM)
        -- 0x54 - float  speed (knots)
        -- 0x58 - float  heading (deg)
        -- Type 3b, same as above for 0x30-0x4a (ref PH)
        -- 0x4c - int32s latitude (decimal degrees * 1e7)
        -- 0x50 - int32s longitude (decimal degrees * 1e7)
        -- 0x54 - int32s speed (m/s * 100)
        -- 0x58 - float  altitude (m * 1000, NC)
        hr, min, sec, yr, mon, day, stat, latRef, lonRef =
            unpack('x48V6a1a1a1x1V4', dataPt)
        if substr(dataPt, 16, 3) == 'IQS' then
            if truthy(debug) then et:FoundTag('GPSType', 16) end
            -- IQS variant (ref PH)
            -- header looks like this in my sample:
            --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 4c 00 00 00 [....freeGPS L...]
            --  0010: 49 51 53 5f 41 37 5f 32 30 31 35 30 34 31 37 00 [IQS_A7_20150417.]
            --  0020: 4d 61 72 20 32 39 20 32 30 31 37 2c 20 31 36 3a [Mar 29 2017, 16:]
            ddd = 1
            lat = math.abs(Get32s(dataPt, 0x4c) / 1e7)
            lon = math.abs(Get32s(dataPt, 0x50) / 1e7)
            spd = Get32s(dataPt, 0x54) / 100 * mpsToKph
            alt = GetFloat(dataPt, 0x58) / 1000 -- (NC)
        else
            lat = GetFloat(dataPt, 0x4c)
            lon = GetFloat(dataPt, 0x50)
            spd = GetFloat(dataPt, 0x54) * knotsToKph
            trk = GetFloat(dataPt, 0x58) -- (NC, may be GPSImageDirection)
            -- Rexing V1-4k dashcam scales the lat/lon
            -- (recognize this dashcam by the KodakVersion, "3.01.054" for my sample)
            --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 4c 00 00 00 [....freeGPS L...]
            --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
            --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
            --  0030: 0e 00 00 00 22 00 00 00 28 00 00 00 14 00 00 00 [...."...(.......]
            --  0040: 02 00 00 00 16 00 00 00 41 4e 57 00 e9 7e 90 43 [........ANW..~.C]
            --  0050: 48 76 17 45 0c 02 48 42 14 6e 85 43 00 00 00 00 [Hv.E..HB.n.C....]
            if truthy(et.KodakVersion) and et.KodakVersion == '3.01.054' then
                if truthy(debug) then et:FoundTag('GPSType', '17b') end
                lat = (lat - 187.982162849635) / 3
                lon = (lon - 2199.19873715495) / 2
                ddd = 1
            elseif Get32u(dataPt, 0) == 0x400000 and math.abs(lat) <= 90 and math.abs(lon) <= 180 then
                if truthy(debug) then et:FoundTag('GPSType', '17c') end
                -- Transcend Drive Body Camera 70
                --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 4c 00 00 00 [..@.freeGPS L...]
                --  0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
                --  0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
                --  0030: 09 00 00 00 26 00 00 00 15 00 00 00 e9 07 00 00 [....&...........]
                --  0040: 05 00 00 00 10 00 00 00 41 53 45 00 6c 59 ee 41 [........ASE.lY.A]
                --  0050: 9f 1a f7 41 3c 6b 0f 41 9a 99 99 43 00 00 00 00 [...A<k.A...C....]
                ddd = 1               -- already in decimal degrees
                spd = spd / knotsToKph    -- already in km/h
            else
                if truthy(debug) then et:FoundTag('GPSType', 17) end
            end
        end
        if dirLen >= 0xb0 then
            -- lat/lon also stored as doubles by Transcend Driver Pro 230 (ref PH)
            local lat2, lon2 = GetDouble(dataPt, 0x70), GetDouble(dataPt, 0x80)
            -- (0xa0 is altitude, don't know what 0x98 and 0xa8 are)
            if math.abs(lat2 - lat) < 0.001 and math.abs(lon2 - lon) < 0.001 then
                lat = lat2
                lon = lon2
                alt = GetDouble(dataPt, 0xa0)
            end
        end
        break
    end
    ok, c1, c2, c3, c4, c5, c6 = isMatch(dataPt, [=[(?s)^.{23}(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2}) [N|S]]=])
    if ok then

        if truthy(debug) then et:FoundTag('GPSType', 18) end
        -- XGODY 12" 4K Dashcam
        --  0000: 00 00 00 a8 66 72 65 65 47 50 53 20 98 00 00 00 [....freeGPS ....]
        --  0010: 6e 6f 72 6d 61 6c 3a 32 30 32 34 2f 30 35 2f 32 [normal:2024/05/2]
        --  0020: 32 20 30 32 3a 35 34 3a 32 39 20 4e 3a 34 32 2e [2 02:54:29 N:42.]
        --  0030: 33 38 32 34 37 30 20 57 3a 38 33 2e 33 38 39 35 [382470 W:83.3895]
        --  0040: 37 30 20 35 33 2e 36 20 6b 6d 2f 68 20 78 3a 2d [70 53.6 km/h x:-]
        --  0050: 30 2e 30 32 20 79 3a 30 2e 39 39 20 7a 3a 30 2e [0.02 y:0.99 z:0.]
        --  0060: 31 30 20 41 3a 32 36 39 2e 32 20 48 3a 32 34 35 [10 A:269.2 H:245]
        --  0070: 2e 35 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [.5..............]
        yr, mon, day, hr, min, sec = c1, c2, c3, c4, c5, c6
        dataPt = subst(dataPt, [[\0+$]], '')   -- remove trailing nulls
        dirInfo.DataPt = dataPt -- (upstream changes the caller's buffer)
        local a = split(' ', substr(dataPt, 43))
        ddd = 1
        for _, v in ipairs(a) do  -- (foreach (@a), $_ is v)
            local ok2, m1, m2 = isMatch(v, [[(?i)^([A-Z]):([-+]?\d+(\.\d+)?)$]])
            if not ok2 then
                -- (the "km/h" after spd is display units? because the value is stored in knots)
                if lon ~= nil and spd == nil and isMatch(v, [[^\d+\.\d+$]]) then spd = v * knotsToKph end
                goto continue
            end
            if m1 == 'N' or m1 == 'S' then lat = m2 latRef = m1 goto continue end
            if m1 == 'E' or m1 == 'W' then lon = m2 lonRef = m1 goto continue end
            if m1 == 'x' or m1 == 'y' or m1 == 'z' then acc[#acc + 1] = m2 goto continue end
            if m1 == 'A' then trk = m2 goto continue end -- (verified, but why 'A'?)
            -- seen 'H' - one might expect altitude ('H'eight), but it doesn't fit
            -- the sample data, so save all other information as an "Unknown_X" tag
            if not tagTbl[m1] then AddTagToTable(nil, tagTbl, m1, { Name = 'Unknown_' .. m1, Unknown = 1 }) end
            xtra[#xtra + 1] = { m1, m2 }
            ::continue::
        end
        break
    end
    if isMatch(dataPt, [[^.{30}A.{20}VV]]) then

        if truthy(debug) then et:FoundTag('GPSType', 19) end
        -- 70mai A810 dashcam (note: no timestamps in the samples I have)
        --  0000: 00 00 40 00 66 72 65 65 47 50 53 20 ed 01 00 00 [..@.freeGPS ....]
        --  0010: 03 00 ed 01 00 00 00 0f 00 00 70 08 00 00 41 66 [..........p...Af]
        --  0020: 13 7d 1e 3c 11 dc 03 5d 01 00 00 01 00 00 00 23 [.}.<...].......#]
        --  0030: 00 00 00 56 56 00 00 00 00 00 00 00 00 00 00 00 [...VV...........]
        --  0040: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
        SetByteOrder('II')
        SetGPSDateTime(et, tagTbl, dirInfo.SampleTime)
        lat = Get32s(dataPt, 31) / 1e5
        lon = Get32s(dataPt, 35) / 1e5
        spd = Get32s(dataPt, 43)  -- (seems to be km/h but not confirmed)
        -- offset 475 - int16u=N string[N] - some sort of settings?:
        -- eg. "\x15\x00{pA:V,rA:V,sF:0,tF:2}"
        break
    end
    do

        if truthy(debug) then et:FoundTag('GPSType', 20) end
        -- (look for binary GPS as stored by Nextbase 512G, ref PH)
        --  0000: 00 00 80 00 66 72 65 65 47 50 53 20 78 01 00 00 [....freeGPS x...]
        --  0010: 78 2e 78 78 00 00 00 00 00 00 00 00 00 00 00 00 [x.xx............]
        --  0020: 30 30 30 30 30 00 00 00 00 00 00 00 00 00 00 00 [00000...........]
        --  0030: 24 53 02 79 d4 85 07 e2 0a 08 06 2a 01 d1 02 20 [$S.y.......*... ]
        --  0040: 14 98 ff ff 21 67 97 10 00 00 00 00 00 00 00 00 [....!g..........]
        --  0050: 24 53 02 a2 d4 42 07 e2 0a 08 06 2a 01 d2 02 20 [$S...B.....*... ]
        --  0060: 14 98 e3 ff 21 67 3b 10 00 00 00 00 00 00 00 00 [....!g;.........]
        -- 32-byte record structure (big endian!):
        -- 0x30 - int16u unknown (seen: 0x24 0x53 = "$S")
        -- 0x32 - int16u speed (m/s * 100)
        -- 0x34 - int16s heading (deg * 100) (or GPSImgDirection?)
        -- 0x36 - int16u year
        -- 0x38 - int8u  month
        -- 0x39 - int8u  day
        -- 0x3a - int8u  hour
        -- 0x3b - int8u  min
        -- 0x3c - int16u sec * 10
        -- 0x3e - int8u  unknown (seen: 2)
        -- 0x3f - int32s latitude (decimal degrees * 1e7)
        -- 0x43 - int32s longitude (decimal degrees * 1e7)
        -- 0x47 - int8u  unknown (seen: 16)
        -- 0x48-0x4f -   all zero
        local pos = 0x32
        while true do
            spd, trk, yr, mon, day, hr, min, sec, lat, lon = unpack('x' .. pos .. 'nnnCCCCnx1NN', dataPt)
            -- validate record using date/time
            if yr < 2000 or yr > 2200 or
                    mon < 1 or mon > 12 or
                    day < 1 or day > 31 or
                    hr > 59 or min > 59 or sec > 600 then break end
            -- change lat/lon to signed integer and divide by 1e7
            lat, lon = SignedInt32(lat) / 1e7, SignedInt32(lon) / 1e7
            if trk >= 0x8000 then trk = trk - 0x10000 end  -- make it signed
            trk = trk / 100
            if trk < 0 then trk = trk + 360 end
            local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%04.1fZ', yr, mon, day, hr, min, sec / 10)
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            et:HandleTag(tagTbl, 'GPSDateTime', time)
            et:HandleTag(tagTbl, 'GPSLatitude', lat)
            et:HandleTag(tagTbl, 'GPSLongitude', lon)
            et:HandleTag(tagTbl, 'GPSSpeed', spd / 100 * mpsToKph)
            et:HandleTag(tagTbl, 'GPSTrack', trk)
            -- (Perl precedence: this is `$pos += (0x20 > length($$dataPt) - 0x1e)`,
            --  so the loop always ends after the first record)
            pos = pos + ((0x20 > length(dataPt) - 0x1e) and 1 or 0)
            if pos ~= 0 then break end
        end
        done = 1
    end
    until true
    SetByteOrder(oldOrder)
    if truthy(done) then
        if truthy(et.DOC_NUM) then return 1 end
        return 0
    end
    if yr ~= nil and (perl.num(mon) < 1 or perl.num(mon) > 12) then return 0 end  -- quick sanity check
--
-- save tag values extracted by above code
--
    FoundSomething(et, tagTbl, dirInfo.SampleTime, dirInfo.SampleDuration)
    if sec ~= nil and not isMatch(perl.str(sec), [[^\d{2}]]) then sec = '0' .. perl.str(sec) end  -- pad integer part of seconds to 2 digits
    if yr ~= nil then
        if perl.num(yr) < 2000 then yr = yr + 2000 end
        local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%sZ', yr, mon, day, hr, min, sec)
        et:HandleTag(tagTbl, 'GPSDateTime', time)
    elseif hr ~= nil then
        local time = sprintf('%.2d:%.2d:%sZ', hr, min, sec)
        et:HandleTag(tagTbl, 'GPSTimeStamp', time)
    end
    if lat ~= nil and lon ~= nil then
        -- lat/long are in DDDMM.MMMM format unless $ddd is set
        if not truthy(ddd) then lat, lon = ConvertLatLon(lat, lon) end
        et:HandleTag(tagTbl, 'GPSLatitude', lat * ((truthy(latRef) and latRef == 'S') and -1 or 1))
        et:HandleTag(tagTbl, 'GPSLongitude', lon * ((truthy(lonRef) and lonRef == 'W') and -1 or 1))
    end
    if alt ~= nil then et:HandleTag(tagTbl, 'GPSAltitude', alt) end
    if spd ~= nil then et:HandleTag(tagTbl, 'GPSSpeed', spd) end
    if trk ~= nil then et:HandleTag(tagTbl, 'GPSTrack', trk) end
    for _, x in ipairs(xtra) do   -- (while (@xtra) ... shift @xtra)
        et:HandleTag(tagTbl, x[1], x[2])
    end
    if #acc > 0 then et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc)) end
    return 1
end
QuickTimeStream.ProcessFreeGPS = ProcessFreeGPS

--------------------------------------------------------------------------------
-- Extract embedded information referenced from a track
-- Inputs: 0) ExifTool ref, 1) tag name, 2) data ref
-- (port: Perl autovivifies $$et{ee}; here each branch that stores into it
--  creates it first)
function QuickTimeStream.ParseTag(et, tag, dataPt)
    local dataLen = length(dataPt)

    if tag == 'stsz' or tag == 'stz2' and dataLen > 12 then
        -- read the sample sizes
        local sz, num = unpack('x4N2', dataPt)
        if not et.ee then et.ee = {} end
        local size = {}
        et.ee.size = size
        if tag == 'stsz' then
            if sz == 0 then
                size = ReadValue(dataPt, 12, 'int32u', num, dataLen - 12, nil, 1) -- (list context)
                et.ee.size = size
            else
                for i = 1, num do size[i] = sz end
            end
        else
            sz = sz & 0xff
            if sz == 4 then
                local tmp = ReadValue(dataPt, 12, 'int8u', int((num + 1) / 2), dataLen - 12, nil, 1)
                for _, v in ipairs(tmp) do
                    size[#size + 1] = v >> 4
                    size[#size + 1] = v & 0xff
                end
            elseif sz == 8 or sz == 16 then
                size = ReadValue(dataPt, 12, 'int' .. sz .. 'u', num, dataLen - 12, nil, 1)
                et.ee.size = size
            end
        end
    elseif tag == 'stco' or tag == 'co64' and dataLen > 8 then
        -- read the chunk offsets
        local num = unpack('x4N', dataPt)
        if not et.ee then et.ee = {} end
        et.ee.stco = ReadValue(dataPt, 8, tag == 'stco' and 'int32u' or 'int64u', num, dataLen - 8, nil, 1)
    elseif tag == 'stsc' and dataLen > 8 then
        -- read the sample-to-chunk box
        local num = unpack('x4N', dataPt)
        if dataLen >= 8 + num * 12 then
            local stsc = {}
            for i = 0, num - 1 do
                -- list of (first-chunk, samples-per-chunk, sample-description-index)
                stsc[#stsc + 1] = { unpack('x' .. (8 + i * 12) .. 'N3', dataPt) }
            end
            if not et.ee then et.ee = {} end
            et.ee.stsc = stsc
        end
    elseif tag == 'stts' and dataLen > 8 then
        -- read the time-to-sample box
        local num = unpack('x4N', dataPt)
        if dataLen >= 8 + num * 8 then
            if not et.ee then et.ee = {} end
            et.ee.stts = { unpack('x8N' .. (num * 2), dataPt) }
        end
    elseif tag == 'avcC' then
        -- read the AVC compressor configuration
        if dataLen >= 7 then  -- (minimum length is 7)
            if not et.ee then et.ee = {} end
            et.ee.avcC = dataPt
        end
    elseif tag == 'JPEG' then
        if not et.ee then et.ee = {} end
        et.ee.JPEG = dataPt
    elseif tag == 'gps ' and dataLen > 8 then
        -- decode Novatek 'gps ' box (ref 2)
        local num = Get32u(dataPt, 4)
        if num * 8 + 8 > dataLen then num = int((dataLen - 8) / 8) end
        if not et.ee then et.ee = {} end
        local start = {}
        et.ee.start = start
        local size = {}
        et.ee.size = size
        for i = 0, num - 1 do
            start[#start + 1] = Get32u(dataPt, 8 + i * 8)
            size[#size + 1] = Get32u(dataPt, 12 + i * 8)
        end
        et.HandlerType = tag   -- fake handler type
        QuickTimeStream.ProcessSamples(et)        -- we have all we need to process sample data now
    elseif tag == 'GPS ' then
        local pos = 0
        local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
        SetByteOrder('II')
        while pos + 36 < dataLen do
            local dat = substr(dataPt, pos, 36)
            if dat == ("\x00"):rep(36) then break end
            local a = { unpack('VVVVaVaV', dat) }
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            -- 0=1, 1=1, 2=secs, 3=?
            SetGPSDateTime(et, tagTbl, a[3])
            local lat = a[6] / 1e3
            local lon = a[8] / 1e3
            lat, lon = ConvertLatLon(lat, lon)
            if a[5] == 'S' then lat = -math.abs(lat) end
            if a[7] == 'W' then lon = -math.abs(lon) end
            et:HandleTag(tagTbl, 'GPSLatitude', lat)
            et:HandleTag(tagTbl, 'GPSLongitude', lon)
            et:HandleTag(tagTbl, 'GPSSpeed', a[4] / 1e3)
            pos = pos + 36
        end
        SetByteOrder('MM')
        et.DOC_NUM = nil
    end
end

--------------------------------------------------------------------------------
-- Process Yuneec 'tx3g' and Autel sbtl metadata (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function Process_tx3g(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    if length(dataPt) < 2 then return 0 end
    et:VerboseDir('tx3g', nil, length(dataPt) - 2)
    local text = substr(dataPt, 2) -- remove 2-byte length word
    et:HandleTag(tagTablePtr, 'Text', text)
    local ok, c1, c2, c3, c4, c5, c6, c7
    if isMatch(text, [[^HOME\(]]) then
        -- --- sample text from Autel Evo II drone ---
        -- HOME(W: 109.318642, N: 40.769371) 2023-09-12 10:28:07
        -- GPS(W: 109.339287, N: 40.768574, 2371.76m)
        -- HDR ISO:100 SHUTTER:1000 EV:-0.7 F-NUM:1.8
        -- F.PRY (1.0\xc2\xb0, -3.7\xc2\xb0, -59.0\xc2\xb0), G.PRY (-51.1\xc2\xb0, 0.0\xc2\xb0, -58.9\xc2\xb0)
        for _, line in ipairs(split([[\x0a]], text)) do
            ok, c1, c2, c3, c4, c5 = isMatch(line, [[^HOME\(([EW]):\s*(\d+\.\d+),\s*([NS]):\s*(\d+\.\d+)\)\s*(.*)]])
            if ok then
                local lon, lat, time = c2, c4, c5
                if c1 == 'W' then lon = -lon end
                if c3 == 'S' then lat = -lat end
                time = tr(time, '-', ':') -- (likely local time zone, but not confirmed)
                et:HandleTag(tagTablePtr, 'GPSDateTime', time)
                et:HandleTag(tagTablePtr, 'HomeLat', lat)
                et:HandleTag(tagTablePtr, 'HomeLon', lon)
                goto continue
            end
            ok, c1, c2, c3, c4, c5 = isMatch(line, [[^GPS\(([EW]):\s*(\d+\.\d+),\s*([NS]):\s*(\d+\.\d+),\s*(.*)m]])
            if ok then
                local lon, lat, alt = c2, c4, c5
                if c1 == 'W' then lon = -lon end
                if c3 == 'S' then lat = -lat end
                et:HandleTag(tagTablePtr, 'Lat', lat)
                et:HandleTag(tagTablePtr, 'Lon', lon)
                et:HandleTag(tagTablePtr, 'Alt', alt)
                goto continue
            end
            ok, c1, c2, c3 = isMatch(line, [[^F\.PRY\s*\((-?[\d.]+)\xc2\xb0,\s*(-?[\d.]+)\xc2\xb0,\s*(-?[\d.]+)\xc2\xb0]])
            if ok then
                et:HandleTag(tagTablePtr, 'Yaw', c1)
                et:HandleTag(tagTablePtr, 'Pitch', c2)
                et:HandleTag(tagTablePtr, 'Roll', c3)
                ok, c1, c2, c3 = isMatch(line, [[G\.PRY\s*\((-?[\d.]+)\xc2\xb0,\s*(-?[\d.]+)\xc2\xb0,\s*(-?[\d.]+)\xc2\xb0]])
                if ok then
                    et:HandleTag(tagTablePtr, 'GimYaw', c1)
                    et:HandleTag(tagTablePtr, 'GimPitch', c2)
                    et:HandleTag(tagTablePtr, 'GimRoll', c3)
                end
            else
                for tag, val in eachMatch(line, [[(?s)([-\w]+):([^:]*[^:\s])(\s|$)]]) do et:HandleTag(tagTablePtr, tag, val) end
            end
            ::continue::
        end
    else
        ok, c1, c2, c3, c4, c5, c6, c7 = isMatch(text, [[(?s)^\w{3} (\d{4})-(\d{2})-(\d{2}) (\d{2}:\d{2}:\d{2}) ?([-+])(\d{2}):?(\d{2})$]])
        if ok then
            et:HandleTag(tagTablePtr, 'DateTime', c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. c5 .. c6 .. ':' .. c7)
        else
            for tag, val in eachMatch(text, [[(?s)(\w+):([^:]*[^:\s])(\s|$)]]) do et:HandleTag(tagTablePtr, tag, val) end
        end
    end
    return 1
end
QuickTimeStream.Process_tx3g = Process_tx3g

--------------------------------------------------------------------------------
-- Process QuickTime 'mebx' timed metadata
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- - uses tag ID keys stored in the ExifTool ee data member by a previous call to SaveMetaKeys
function Process_mebx(et, dirInfo, tagTbl)
    local ee = et.ee
    if not ee then return 0 end
    if not ee.keys then return 0 end
    local dataPt = dirInfo.DataPt

    -- parse using information from 'keys' table (eg. Apple iPhone7+ hevc 'Core Media Data Handler')
    et:VerboseDir('mebx', nil, length(dataPt))
    local pos, len
    pos = 0
    while pos + 8 < length(dataPt) do
        len = Get32u(dataPt, pos)
        if len < 8 or pos + len > length(dataPt) then break end
        local id = substr(dataPt, pos + 4, 4)
        local info = ee.keys[id]
        if info then
            local tag = info.TagID
            if not tagTbl[tag] then
                if not isMatch(tag, [[^[-\w.]+$]]) then goto continue end
                -- create info for tags with reasonable id's
                local name = tag
                name = subst(name, [[[-.](.)]], function(c) return uc(c) end, 'g')
                AddTagToTable(nil, tagTbl, tag, { Name = ucfirst(name) })
            end
            local val = ReadValue(dataPt, pos + 8, info.Format, nil, len - 8)
            et:HandleTag(tagTbl, tag, val, {
                DataPt = dataPt,
                Base   = dirInfo.Base,
                Start  = pos + 8,
                Size   = len - 8,
            })
        else
            et:Warn('No key information for mebx ID ' .. QuickTime.PrintableTagID(id, 1))
        end
        ::continue::
        pos = pos + len
    end
    return 1
end
QuickTimeStream.Process_mebx = Process_mebx

--------------------------------------------------------------------------------
-- Process QuickTime '3gf' timed metadata (ref PH, Pittasoft Blackvue dashcam)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function QuickTimeStream.Process_3gf(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local recLen = 10     -- 10-byte record length
    et:VerboseDir('3gf', nil, dirLen)
    if dirLen > recLen and not truthy(et:Options('ExtractEmbedded')) then
        dirLen = recLen
        QuickTime.EEWarn(et)
    end
    local pos = 0
    while pos + recLen <= dirLen do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        local tc = Get32u(dataPt, pos)
        if tc == 0xffffffff then break end
        local x, y, z = Get16s(dataPt, pos + 4) / 10, Get16s(dataPt, pos + 6) / 10, Get16s(dataPt, pos + 8) / 10
        et:HandleTag(tagTbl, 'TimeCode', tc / 1000)
        et:HandleTag(tagTbl, 'Accelerometer', join(' ', { x, y, z }))
        pos = pos + recLen
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process DuDuBell M1 dashcam / VSYS M6L 'gps0' atom (ref PH)
-- (Lamax S9 dual dashcam also uses 'gps0' atom, but encrypted text format)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function QuickTimeStream.Process_gps0(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local pos, recLen
    et:VerboseDir('gps0', nil, dirLen)
    -- check for encrypted format written by Lamax S9 dual dashcam
    -- (similar to Ambarella A12, but in multiple 311-byte records)
    if isMatch(dataPt, [[(?s)^.{2}\xf2\xe1\xf0\xeeTT\x98]]) then
        recLen = 311
        pos = 0
        while pos + recLen <= dirLen do
            local dat = substr(dataPt, pos, recLen)
            if not isMatch(dat, [[(?s)^.{2}\xf2\xe1\xf0\xeeTT\x98]]) then break end
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            Process_text(et, dat, tagTbl)
            pos = pos + recLen
            pos = pos + recLen
        end
        et.DOC_NUM = nil
        return 1
    end
    recLen = 32    -- 32-byte record length
    SetByteOrder('II')
    if dirLen > recLen and not truthy(et:Options('ExtractEmbedded')) then
        dirLen = recLen
        QuickTime.EEWarn(et)
    end
    pos = 0
    while pos + recLen <= dirLen do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        -- lat/long are in DDDMM.MMMM format
        local lat = GetDouble(dataPt, pos)
        local lon = GetDouble(dataPt, pos + 8)
        if not (math.abs(lat) > 9000 or math.abs(lon) > 18000) then
            lat, lon = ConvertLatLon(lat, lon)
            local a = { unpack('C*', substr(dataPt, pos + 22, 6)) } -- unpack date/time
            a[1] = a[1] + 2000
            et:HandleTag(tagTbl, 'GPSDateTime', sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', table.unpack(a)))
            et:HandleTag(tagTbl, 'GPSLatitude', lat)
            et:HandleTag(tagTbl, 'GPSLongitude', lon)
            et:HandleTag(tagTbl, 'GPSSpeed', Get16u(dataPt, pos + 0x14))
            et:HandleTag(tagTbl, 'GPSTrack', Get8u(dataPt, pos + 0x1c) * 2) -- (NC)
            et:HandleTag(tagTbl, 'GPSAltitude', Get32s(dataPt, pos + 0x10))
            -- yet to be decoded:
            -- 0x1d - int8u[3] seen: "1 1 0"
        end
        pos = pos + recLen
    end
    et.DOC_NUM = nil
    SetByteOrder('MM')
    return 1
end

--------------------------------------------------------------------------------
-- Process DuDuBell M1 dashcam / VSYS M6L 'gsen' atom (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function QuickTimeStream.Process_gsen(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local recLen = 3     -- 3-byte record length
    et:VerboseDir('gsen', nil, dirLen)
    if dirLen > recLen and not truthy(et:Options('ExtractEmbedded')) then
        dirLen = recLen
        QuickTime.EEWarn(et)
    end
    local pos = 0
    while pos + recLen <= dirLen do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        local acc = map(function(v) return v / 16 end, { unpack('x' .. pos .. 'c3', dataPt) })
        et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
        -- (there are no associated timestamps, but these are sampled at 5 Hz in my test video)
        pos = pos + recLen
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process 'gdat' atom Base64-encoded JSON-format timed GPS used by Nextbase software (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function QuickTimeStream.Process_gdat(et, dirInfo, tagTbl)
    if not truthy(et.OPTIONS.ExtractEmbedded) then
        et:Warn('Use the ExtractEmbedded option to extract timed GPSData', 3)
        return 0
    end
    local dataPt = dirInfo.DataPt
    dataPt = require('lexiftool.XMP').DecodeBase64(dataPt)
    local dbase = {}
    local Import = require('lexiftool.Import')
    Import.ReadJSON({ ref = 'SCALAR', value = dataPt }, dbase)
    local info = dbase['*']
    if not info then return 0 end
    if truthy(info.cameraModel) then et:HandleTag(tagTbl, 'CameraModel', info.cameraModel) end
    local gps = info.gpsData
    if not gps then return 0 end
    -- (`ref $gps eq 'ARRAY'`: a JSON array is a table without the object key list)
    if not (type(gps) == 'table' and gps._ordered_keys_ == nil) then return 0 end
    for _, fix in ipairs(gps) do
        if not (type(fix) == 'table' and fix._ordered_keys_ ~= nil and truthy(fix.gpsStatus) and fix.gpsStatus == 'A') then goto continue end
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        if truthy(fix.datetime) then
            fix.datetime = tr(fix.datetime, '-T', ': ')
            et:HandleTag(tagTbl, 'GPSDateTime', fix.datetime)
        end
        if fix.lat ~= nil then et:HandleTag(tagTbl, 'GPSLatitude', fix.lat) end
        if fix.lon ~= nil then et:HandleTag(tagTbl, 'GPSLongitude', fix.lon) end
        if fix.speed ~= nil then et:HandleTag(tagTbl, 'GPSSpeed', fix.speed * mphToKph) end
        if fix.bearing ~= nil then et:HandleTag(tagTbl, 'GPSTrack', fix.bearing) end
        if fix.xAcc ~= nil and fix.yAcc ~= nil and fix.zAcc ~= nil then
            et:HandleTag(tagTbl, 'Accelerometer', perl.str(fix.xAcc) .. ' ' .. perl.str(fix.yAcc) .. ' ' .. perl.str(fix.zAcc))
        end
        ::continue::
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Extract GPS from Nextbase 'nbmt' atom
-- Inputs: 0) ExifTool ref, 1) data ref or dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function QuickTimeStream.Process_nbmt(et, dataPt, tagTbl)

    if truthy(et.OPTIONS.ExtractEmbedded) then
        et.DOC_NUM = (et.DOC_COUNT or 0) + 1
        et.UnknownTextCount = nil
        et.NoMoreTextDecoding = nil
        et.SET_GROUP1 = 'Nextbase'
        Process_text(et, dataPt, tagTbl, 1)
        et.SET_GROUP1 = nil
        et.UnknownTextCount = nil
        et.NoMoreTextDecoding = nil
        et.DOC_NUM = nil
    else
        et:Warn('Use the ExtractEmbedded option to extract timed GPSData', 3)
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process Kenwood drv-a301w dashcam 'udta' atom (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Sample data:
-- 0000: 56 49 44 45 4f 55 55 55 55 55 55 55 55 55 55 55 [VIDEOUUUUUUUUUUU]
-- 0010: 55 55 55 55 55 55 55 55 55 55 55 fe fe 32 30 32 [UUUUUUUUUUU..202]
-- 0020: 33 30 31 30 37 31 31 31 39 31 34 2e 32 30 32 33 [30107111914.2023]
-- 0030: 30 31 30 37 31 31 31 39 31 35 03 4e 34 37 33 37 [0107111915.N4737]
-- 0040: 37 30 35 33 57 31 32 32 30 39 39 30 31 34 2b 30 [7053W122099014+0]
-- 0050: 30 35 38 30 30 30 2b 30 30 36 2b 30 30 39 2b 30 [058000+006+009+0]
-- 0060: 30 34 2b 30 30 32 2b 30 30 39 2b 30 30 35 2b 30 [04+002+009+005+0]
-- (port: the `\G` matches continue at the end offset of the previous one,
--  Perl's pos($dat))
function QuickTimeStream.ProcessKenwood(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen -- luacheck: ignore 211 (unused upstream as well)
    for dat in eachMatch(dataPt, [[\xfe\xfe([^\xfe]+)]]) do
        local c1, c2, c3, c4, c5, c6, pos = matches(dat, [[(?s)^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2}).]])
        if not c1 then goto continue end
        do
            local time = c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6 -- (likely local time zone, but not confirmed)
            -- ignore second date (what is this for?)
            local _
            c1, _, _, _, _, _, pos = matches(dat, [[(?s)\G(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2}).]], pos)
            if not c1 then goto continue end
            c1, c2, c3, c4, pos = matches(dat, [[\G([NS])(\d+)([EW])(\d+)]], pos)
            if not c1 then goto continue end
            local lat, lon = c2 / 1e4, c4 / 1e4
            lat, lon = ConvertLatLon(lat, lon)
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            et:HandleTag(tagTbl, 'GPSDateTime', time)
            et:HandleTag(tagTbl, 'GPSLatitude', lat * (c1 == 'S' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSLongitude', lon * (c3 == 'W' and -1 or 1))
            c1, c2, pos = matches(dat, [[\G([-+]\d{4})(\d+)]], pos)
            if not c1 then goto continue end
            et:HandleTag(tagTbl, 'GPSAltitude', perl.num(c1)) -- (NC, educated guess)
            et:HandleTag(tagTbl, 'GPSSpeed', c2) -- (km/h)
            local acc = {}
            while true do
                local a1, a2, a3, p = matches(dat, [[\G([-+]\d+)([-+]\d+)([-+]\d+)]], pos)
                if not a1 then break end
                pos = p
                acc[#acc + 1] = a1 / 1000  acc[#acc + 1] = a2 / 1000  acc[#acc + 1] = a3 / 1000
            end
            if #acc > 0 then et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc)) end
            if not truthy(et:Options('ExtractEmbedded')) then
                et:Warn('Use the ExtractEmbedded option to extract all timed GPS', 3)
                break
            end
        end
        ::continue::
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process RIFF-format trailer written by Auto-Vox dashcam (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Note: This trailer is basically RIFF chunks added to a QuickTime-format file (augh!),
--       but there are differences in the record formats so we can't just call
--       ProcessRIFF to process the gps0 and gsen atoms using the routines above
function QuickTimeStream.ProcessRIFFTrailer(et, dirInfo, tagTbl)
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose') or 0
    local buff, pos, n
    SetByteOrder('II')
    while true do
        n, buff = raf:Read(8)
        if n ~= 8 then break end
        local tag, len = unpack('a4V', buff)
        if tag == "\0\0\0\0" then break end
        if not (isMatch(tag, [[^[\w ]{4}]]) and len < 0x2000000) then
            et:Warn('Bad RIFF trailer')
            break
        end
        n, buff = raf:Read(len)
        if n ~= len then et:Warn('Truncated ' .. tag .. ' record in RIFF trailer') break end
        if truthy(verbose) then
            et:VPrint(0, "  - RIFF trailer '" .. tag .. "' (" .. len .. " bytes)\n")
            if verbose > 2 then et:VerboseDump(buff, { Addr = raf:Tell() - len }) end
            et.INDENT = et.INDENT .. '| '
            if isMatch(tag, [[^(gps0|gsen)$]]) then et:VerboseDir(tag, nil, len) end
        end
        if tag == 'gps0' then
            -- (similar to record decoded in Process_gps0, but with some differences)
            -- 0000: 41 49 54 47 74 46 94 f6 c6 c5 b4 40 34 a2 b4 37 [AITGtF.....@4..7]
            -- 0010: f8 7b 8a 40 ff ff 00 00 38 00 77 0a 1a 0c 12 28 [.{.@....8.w....(]
            -- 0020: 8d 01 02 40 29 07 00 00                         [...@)...]
            -- 0x00 - undef[4] 'AITG'
            -- 0x04 - double   latitude  (always positive)
            -- 0x0c - double   longitude (always positive)
            -- 0x14 - ?        seen hex "ff ff 00 00" (altitude in Process_gps0 record below)
            -- 0x18 - int16u   speed in knots (different than km/hr in Process_gps0)
            -- 0x1a - int8u[6] yr-1900,mon,day,hr,min,sec (different than -2000 in Process_gps0)
            -- 0x20 - int8u    direction in degrees / 2
            -- 0x21 - int8u    guessing that this is 1=N, 2=S - PH
            -- 0x22 - int8u    guessing that this is 1=E, 2=W - PH
            -- 0x23 - ?        seen hex "40"
            -- 0x24 - in32u    time since start of video (ms)
            local recLen = 0x28
            pos = 0
            while pos + recLen < len do
                if substr(buff, pos, 4) ~= 'AITG' then et:Warn('Unrecognized gps0 record') break end
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                -- lat/long are in DDDMM.MMMM format
                local lat = GetDouble(buff, pos + 4)
                local lon = GetDouble(buff, pos + 12)
                if math.abs(lat) > 9000 or math.abs(lon) > 18000 then
                    if truthy(et:Warn('Bad gps0 record')) then break end
                end
                lat, lon = ConvertLatLon(lat, lon)
                if Get8u(buff, pos + 0x21) == 2 then lat = -lat end   -- wild guess
                if Get8u(buff, pos + 0x22) == 2 then lon = -lon end   -- wild guess
                local a = { unpack('C*', substr(buff, pos + 26, 6)) } -- unpack date/time
                a[1] = a[1] + 1900 -- (different than Proces_gps0)
                et:HandleTag(tagTbl, 'SampleTime', Get32u(buff, pos + 0x24) / 1000)
                et:HandleTag(tagTbl, 'GPSDateTime', sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', table.unpack(a)))
                et:HandleTag(tagTbl, 'GPSLatitude', lat)
                et:HandleTag(tagTbl, 'GPSLongitude', lon)
                et:HandleTag(tagTbl, 'GPSSpeed', Get16u(buff, pos + 0x18) * knotsToKph)
                et:HandleTag(tagTbl, 'GPSTrack', Get8u(buff, pos + 0x20) * 2)
                pos = pos + recLen
            end
        elseif tag == 'gsen' then
            -- (similar to record decoded in Process_gsen)
            -- 0000: 41 49 54 53 1a 0d 05 ff c8 00 00 00 [AITS........]
            -- 0x00 - undef[4] 'AITS'
            -- 0x04 - int8s[3] accelerometer readings
            -- 0x07 - ?        seen hex "ff"
            -- 0x08 - in32u    time since start of video (ms)
            local recLen = 0x0c
            pos = 0
            while pos + recLen < len do
                if substr(buff, pos, 4) ~= 'AITS' then et:Warn('Unrecognized gsen record') break end
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                local acc = map(function(v) return v / 24 end, { unpack('x' .. (pos + 4) .. 'c3', buff) })
                et:HandleTag(tagTbl, 'SampleTime', Get32u(buff, pos + 8) / 1000)
                -- 0=+Up, 1=+Right, 3=+Forward (calibration of 24 counts/g is a wild guess - PH)
                et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
                pos = pos + recLen
            end
        end
        -- also seen, but not decoded:
        -- gpsa (8 bytes): hex "01 20 00 00 08 03 02 08 "
        -- gsea (20 bytes): all zeros
        if truthy(verbose) then et.INDENT = substr(et.INDENT, 0, -2) end
    end
    et.DOC_NUM = nil
    SetByteOrder('MM')
    return 1
end

--------------------------------------------------------------------------------
-- Process Kenwood Dashcam trailer (forum16229)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Sample data (chained 512-byte records starting like this):
-- 0000:  43 43 43 43 43 43 43 43 43 43 43 43 43 43 47 50 [CCCCCCCCCCCCCCGP]
-- 0010:  53 44 41 54 41 2d 2d 32 30 32 34 30 37 31 31 31 [SDATA--202407111]
-- 0020:  32 30 34 31 32 4e 35 30 2e 36 31 32 33 38 36 30 [20412N50.6123860]
-- 0030:  36 37 37 45 38 2e 37 30 32 37 31 38 30 39 38 39 [677E8.7027180989]
-- 0040:  35 33 33 2e 30 30 30 30 30 30 30 30 30 30 30 30 [533.000000000000]
-- 0050:  2e 30 30 30 30 30 30 30 30 30 30 30 30 30 2e 30 [.0000000000000.0]
-- 0060:  31 39 39 39 39 39 39 39 35 35 33 2d 30 2e 30 39 [19999999553-0.09]
-- 0070:  30 30 30 30 30 30 33 35 37 2d 30 2e 31 34 30 30 [000000357-0.1400]
-- 0080:  30 30 30 30 30 35 39 47 50 53 44 41 54 41 2d 2d [0000059GPSDATA--]
function QuickTimeStream.ProcessKenwoodTrailer(et, dirInfo, tagTbl)
    local raf = dirInfo.RAF
    local buff, n
    -- current file position is 8 bytes into the 14 C's, so test the next 6:
    n, buff = raf:Read(14)
    if not (truthy(n) and buff == 'CCCCCCCCCCCCCC') then return 0 end
    et:VerboseDir('Kenwood trailer', nil, nil)
    if not truthy(et.OPTIONS.ExtractEmbedded) then
        et:Warn('Use the ExtractEmbedded option to extract timed GPSData from Kenwood trailer', 3)
        return 1
    end
    while true do
        n, buff = raf:Read(121)
        if not truthy(n) then break end
        local ok, c1, c2, c3, c4, c5, c6 = isMatch(buff, [[^GPSDATA--(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})]])
        if not ok then break end
        FoundSomething(et, tagTbl)
        et:HandleTag(tagTbl, 'GPSDateTime', c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6)
        local i = 9 + 14
        local val
        local acc = {}
        for _, tag in ipairs({ 'GPSLatitude', 'GPSLongitude', 'GPSSpeed', 'unk', 'acc', 'acc', 'acc' }) do
            val = substr(buff, i, 14)  i = i + 14
            if tag == 'unk' then goto continue end
            local hemi
            local ok2, h = isMatch(val, [[^([NSEW])]])
            if ok2 then hemi = h val = subst(val, [[^([NSEW])]], '') end
            if not isMatch(val, [[^[-+]?\d+\.\d+$]]) then goto continue end
            if tag == 'acc' then acc[#acc + 1] = val goto continue end
            if hemi and (hemi == 'S' or hemi == 'W') then val = -perl.num(val) end
            et:HandleTag(tagTbl, tag, val)
            ::continue::
        end
        if #acc == 3 then et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc)) end
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process 'gps ' atom containing NMEA from Pittasoft Blackvue dashcam (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- (port: `pos` is Perl's pos($$dataPt) -- the end offset of the last /g
--  match, reset to 0 when one fails)
function QuickTimeStream.ProcessNMEA(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local rtnVal -- luacheck: ignore 221 (never set upstream either)
    local fix = {}
    local pos_ = 0
    -- parse only RMC and GGA sentence [with leading timecode] for now
    while true do
        local tc, type_, tim
        local m1, m2, m3, _, en = matches(dataPt, [[(?:\[(\d+)\])?\$[A-Z]{2}(RMC|GGA),(\d{2}\d{2}\d+(\.\d*)?),]], pos_)
        if en then
            tc, type_, tim = m1, m2, m3
            pos_ = en
        else
            pos_ = 0
        end
        -- write out last fix now if complete
        -- (use the GPS timestamps because they may be different for the same timecode)
        if truthy(fix.tim) and (not truthy(tim) or perl.num(fix.tim) ~= perl.num(tim)) then
            if truthy(fix.dat) and fix.lat ~= nil and fix.lon ~= nil then
                local sampleTime
                if truthy(fix.tc) and truthy(et.StartTime) then sampleTime = (fix.tc - et.StartTime) / 1000 end
                FoundSomething(et, tagTbl, sampleTime)
                et:HandleTag(tagTbl, 'GPSDateTime', fix.dat)
                et:HandleTag(tagTbl, 'GPSLatitude', fix.lat)
                et:HandleTag(tagTbl, 'GPSLongitude', fix.lon)
                if fix.spd ~= nil then et:HandleTag(tagTbl, 'GPSSpeed', fix.spd * knotsToKph) end
                if fix.trk ~= nil then et:HandleTag(tagTbl, 'GPSTrack', fix.trk) end
                if fix.alt ~= nil then et:HandleTag(tagTbl, 'GPSAltitude', fix.alt) end
                if fix.nsats ~= nil then et:HandleTag(tagTbl, 'GPSSatellites', perl.num(fix.nsats)) end
                if fix.hdop ~= nil then et:HandleTag(tagTbl, 'GPSDOP', fix.hdop) end
            end
            fix = {}
        end
        fix.tim = tim
        if not truthy(tim) then break end
        local pos = pos_
        pos_ = pos - length(tim) - 1 -- rewind to re-parse time
        -- (parsing of NMEA strings copied from Geotag.pm)
        local c1, c2, c3, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, e, _
        if type_ == 'RMC' then
            c1, c2, c3, _, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, e = matches(dataPt,
                [[\G(\d{2})(\d{2})(\d+(\.\d*)?),A?,(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]], pos_)
        end
        if e then
            pos_ = e
            local year = c15 + (perl.num(c15) >= 70 and 1900 or 2000)
            fix.tc = tc -- use timecode of RMC sentence
            fix.dat = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%sZ', year, c14, c13, c1, c2, c3)
            fix.lat = ((truthy(c5) and c5 or 0) + c6 / 60) * (c7 == 'N' and 1 or -1)
            fix.lon = ((truthy(c8) and c8 or 0) + c9 / 60) * (c10 == 'E' and 1 or -1)
            if length(c11) > 0 then fix.spd = c11 end
            if length(c12) > 0 then fix.trk = c12 end
        else
            if type_ == 'GGA' then
                _, _, _, _, c5, c6, c7, c8, c9, c10, c11, c12, c13, e = matches(dataPt,
                    [[\G(\d{2})(\d{2})(\d+(\.\d*)?),(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),[1-6]?,(\d+)?,(\.\d+|\d+\.?\d*)?,(-?\d+\.?\d*)?,M?]], pos_)
            end
            if e then
                pos_ = e
                fix.lat = ((truthy(c5) and c5 or 0) + c6 / 60) * (c7 == 'N' and 1 or -1)
                fix.lon = ((truthy(c8) and c8 or 0) + c9 / 60) * (c10 == 'E' and 1 or -1)
                fix.nsats, fix.hdop, fix.alt = c11, c12, c13
            else
                pos_ = pos   -- continue searching from our last match
            end
        end
    end
    et.DOC_NUM = nil
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process 'gps ' or 'udat' atom possibly containing NMEA (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function QuickTimeStream.ProcessGPSLog(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local rtnVal

    -- try NMEA format first
    if truthy(QuickTimeStream.ProcessNMEA(et, dirInfo, tagTbl)) then return 1 end

    -- DENVER ACG-8050WMK2 format looks like this:
    -- 210318073213[1][N][52200970][E][006362321][+00152][100][00140][C000000]+000+000+000+000+000+000+000+000+000+000+000+000+000+000+000+000+000+000
    -- YYMMDDHHMMSS A? NS lat       EW lon         alt    kph  dir    kCal    accel
    for c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15 in eachMatch(dataPt,
        [[\b(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\[1\]\[([NS])\]\[(\d{8})\]\[([EW])\]\[(\d{9})\]\[([-+]?\d*)\]\[(\d*)\]\[(\d*)\]\[C?(\d*)\](([-+]\d{3})+)]]) do
        local lat = substr(c8, 0, 2) + substr(c8, 2) / 600000
        local lon = substr(c10, 0, 3) + substr(c10, 3) / 600000
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        et:HandleTag(tagTbl, 'GPSDateTime', '20' .. c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6 .. 'Z')
        et:HandleTag(tagTbl, 'GPSLatitude', lat * (c7 == 'S' and -1 or 1))
        et:HandleTag(tagTbl, 'GPSLongitude', lon * (c9 == 'W' and -1 or 1))
        if length(c11) > 0 then et:HandleTag(tagTbl, 'GPSAltitude', perl.num(c11) / 10) end
        if length(c12) > 0 then et:HandleTag(tagTbl, 'GPSSpeed', perl.num(c12)) end
        if length(c13) > 0 then et:HandleTag(tagTbl, 'GPSTrack', perl.num(c13)) end
        if length(c14) > 0 then et:HandleTag(tagTbl, 'KiloCalories', perl.num(c14) / 10) end
        if length(c15) > 0 then et:HandleTag(tagTbl, 'Accelerometer', c15) end
        rtnVal = 1
    end
    et.DOC_NUM = nil
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process TomTom Bandit Action Cam TTAD atom (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
local ttLen = { -- lengths of known TomTom records
    [0] = 12,    -- angular velocity (NC)
    [1] = 4,     -- ?
    [2] = 12,    -- ?
    [3] = 12,    -- accelerometer (NC)
    -- (haven't seen a record 4 yet)
    [5] = 92,    -- GPS
    [0xff] = 4,  -- timecode
}
function QuickTimeStream.ProcessTTAD(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local pos = 76

    if dirLen < pos then return 0 end

    et:VerboseDir('TTAD', nil, dirLen)
    SetByteOrder('II')

    local eeOpt = et:Options('ExtractEmbedded')
    local unknown = et:Options('Unknown')
    local found = 0
    local sampleTime = 0
    local resync = 1
    local skipped = 0
    local warned

    while pos < dirLen do
        -- get next record type
        local type_ = Get8u(dataPt, pos)  pos = pos + 1
        -- resync if necessary by skipping data until next timecode record
        if truthy(resync) and type_ ~= 0xff then
            skipped = skipped + 1
            if skipped > 0x100 then et:Warn('Unrecognized or bad TTAD data', 1) break end
            goto continue
        end
        if not truthy(ttLen[type_]) then
            -- skip unknown records
            if not warned then et:Warn('Unknown TTAD record type ' .. type_, 1) end
            resync, warned = 1, 1
            skipped = skipped + 1
            goto continue
        end
        if pos + ttLen[type_] > dirLen then break end
        if type_ == 0xff then    -- timecode?
            local tm = Get32u(dataPt, pos)
            -- validate timecode if skipping unknown data
            if truthy(resync) then
                if tm < sampleTime or tm > sampleTime + 250 then
                    skipped = skipped + 1
                    goto continue
                end
                resync = nil
                skipped = 0
            end
            pos = pos + ttLen[type_]
            sampleTime = tm
            goto continue
        end
        if not truthy(eeOpt) then
            -- only extract one of each type without -ee option
            if found & (1 << type_) ~= 0 then pos = pos + ttLen[type_] goto continue end
            found = found | (1 << type_)
        end
        if type_ == 0 or type_ == 3 then
            -- (these are both just educated guesses - PH)
            FoundSomething(et, tagTbl, sampleTime / 1000)
            local a = map(function(v) return Get32s(dataPt, pos + 4 * v) / 1000 end, { 0, 1, 2 })
            et:HandleTag(tagTbl, type_ ~= 0 and 'Accelerometer' or 'AngularVelocity', join(' ', a))
        elseif type_ == 5 then
            -- example records unpacked with 'dVddddVddddv*'
            -- datetime                 ? spd  ele    lat        lon       ? trk   ?     ?      ?      ? ? ? ?     ? ?
            -- 2019:03:05 07:52:58.999Z 3 0.02 242    48.0254203 7.8497567 0 45.69 13.34 17.218 17.218 0 0 0 32760 5 0
            -- 2019:03:05 07:52:59.999Z 3 0.14 242    48.0254203 7.8497567 0 45.7  12.96 15.662 15.662 0 0 0 32760 5 0
            -- 2019:03:05 07:53:00.999Z 3 0.67 243.78 48.0254584 7.8497907 0 50.93  9.16 10.84  10.84  0 0 0 32760 5 0
            -- (I think "5" may be the number of satellites.  seen: 5,6,7 - PH)
            FoundSomething(et, tagTbl, sampleTime / 1000)
            local t = GetDouble(dataPt, pos)
            et:HandleTag(tagTbl, 'GPSDateTime', ConvertUnixTime(t, nil, 3) .. 'Z')
            et:HandleTag(tagTbl, 'GPSLatitude', GetDouble(dataPt, pos + 0x1c))
            et:HandleTag(tagTbl, 'GPSLongitude', GetDouble(dataPt, pos + 0x24))
            et:HandleTag(tagTbl, 'GPSAltitude', GetDouble(dataPt, pos + 0x14))
            et:HandleTag(tagTbl, 'GPSSpeed', GetDouble(dataPt, pos + 0x0c) * mpsToKph)
            et:HandleTag(tagTbl, 'GPSTrack', GetDouble(dataPt, pos + 0x30))
            if truthy(unknown) then
                local a = map(function(v) return GetDouble(dataPt, pos + 0x38 + 8 * v) end, { 0, 1, 2 })
                et:HandleTag(tagTbl, 'Unknown03', join(' ', a))
            end
        elseif type_ < 3 then
            -- as yet unknown:
            -- 1 - int32s[1]? (values around 98k)
            -- 2 - int32s[3] (values like "806 8124 4323" -- probably something * 1000 again)
            if truthy(unknown) then
                FoundSomething(et, tagTbl, sampleTime / 1000)
                local n = type_ == 1 and 0 or 2
                local a = {}
                for k = 0, n do a[#a + 1] = Get32s(dataPt, pos + 4 * k) end
                et:HandleTag(tagTbl, 'Unknown0' .. type_, join(' ', a))
            end
        else
            et:Warn('Unknown TTAD record type ' .. type_, 1)
        end
        -- without -ee, stop after we find types 0,3,5 (ie. bitmask 0x29)
        if not truthy(eeOpt) and (found & 0x29) == 0x29 then QuickTime.EEWarn(et) break end
        pos = pos + ttLen[type_]
        ::continue::
    end
    SetByteOrder('MM')
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from Insta360 trailer (INSV, INSP and MP4 files) or 'inst' box (ref PH)
-- Inputs: 0) ExifTool ref, 1) Optional dirInfo ref for returning trailer info
-- (dirInfo has Offset from end of trailer to end of file or DirEnd absolute end of trailer)
-- Returns: true on success
-- Notes: There looks to be some useful information by telemetry-parser, but
--        the code is cryptic:  https://github.com/AdrianEddy/telemetry-parser
function QuickTimeStream.ProcessInsta360(et, dirInfo)
    local raf = et.RAF
    local offset = dirInfo and (dirInfo.Offset or 0) or 0
    local buff, dirTable, dirTablePos, n

    if dirInfo and truthy(dirInfo.DirEnd) then
        raf:Seek(0, 2)
        offset = raf:Tell() - dirInfo.DirEnd
    end
    if not raf:Seek(-78 - offset, 2) then return 0 end
    n, buff = raf:Read(78)
    if not (n == 78 and substr(buff, -32) == '8db42d694ccc418790edff439fe026bf') then return 0 end    -- check magic number

    local verbose = et:Options('Verbose') or 0
    local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
    local trailEnd = raf:Tell()
    local trailerLen = unpack('x38V', buff)
    if trailerLen > trailEnd then et:Warn('Bad Insta360 trailer size') return 0 end
    if dirInfo then
        dirInfo.DirLen = trailerLen
        dirInfo.DataPos = trailEnd - trailerLen
        if dirInfo.OutFile then
            if require('lexiftool.Writer').IsGroupDeleted(et, 'Insta360') then -- (upstream `$$et{DEL_GROUP}{Insta360}`)
                et.CHANGED = (et.CHANGED or 0) + 1
                return 1
            -- just copy the trailer when writing
            elseif trailerLen > trailEnd or not raf:Seek(dirInfo.DataPos, 0) then
                return 0
            else
                local data
                n, data = raf:Read(trailerLen)
                if n ~= trailerLen then return 0 end
                dirInfo.OutFile.value = require('carray').new('char'):append(data)
                return 1
            end
        end
        if truthy(verbose) or et.HTML_DUMP then et:DumpTrailer(dirInfo) end
    end
    if not truthy(et:Options('ExtractEmbedded')) then
        -- can arrive here when reading Insta360 trailer on JPEG image (INSP file)
        et:Warn('Use ExtractEmbedded option to extract timed metadata from Insta360 trailer', 3)
        return 1
    end

    local unknown = et:Options('Unknown')
    -- position relative to end of trailer (avoids using large offsets for files > 2 GB)
    local epos = -78
    local i, p
    et.SET_GROUP0 = 'Trailer'
    et.SET_GROUP1 = 'Insta360'
    SetByteOrder('II')
    -- loop through all records in the trailer, from last to first
    while true do
        local id, len = unpack('vV', buff)
        epos = epos - len
        if epos + trailerLen < 0 then break end
        if not raf:Seek(epos - offset, 2) then break end
        if truthy(verbose) then
            et:VPrint(0, sprintf("Insta360 Record 0x%x (offset 0x%x, %d bytes):\n", id, trailEnd + epos, len))
        end
        -- there are 2 types of record 0x300:
        -- 1. 56 byte records
        -- 0000: 4a f7 02 00 00 00 00 00 00 00 00 00 00 1e e7 3f [J..............?]
        -- 0010: 00 00 00 00 00 b2 ef bf 00 00 00 00 00 70 c1 bf [.............p..]
        -- 0020: 00 00 00 e0 91 5c 8c bf 00 00 00 20 8f ff 87 bf [.....\..... ....]
        -- 0030: 00 00 00 00 88 7f c9 bf
        -- 2. 20 byte records
        -- 0000: c1 d8 d9 0b 00 00 00 00 f5 83 14 80 df 7f fe 7f [................]
        -- 0010: fe 7f 01 80
        local dlen = insvDataLen[id]
        if dlen ~= nil and not truthy(dlen) then
            if id == 0x300 then
                if len % 20 ~= 0 and len % 56 == 0 then
                    dlen = 56
                elseif len % 56 ~= 0 and len % 20 == 0 then
                    dlen = 20
                else
                    n, buff = raf:Read(20)
                    if n == 20 then
                        if substr(buff, 16, 3) == "\0\0\0" then
                            dlen = 56
                        else
                            dlen = 20
                        end
                    end
                    if not raf:Seek(epos - offset, 2) then break end
                end
            elseif id == 0x200 then
                dlen = len
            end
        end
        -- limit the number of records we read if necessary
        if truthy(dlen) and insvLimit[id] and len > insvLimit[id][2] * dlen and
            truthy(et:Warn('Insta360 ' .. insvLimit[id][1] .. ' data is huge. Processing only the first ' .. insvLimit[id][2] .. ' records', 2))
        then
            len = insvLimit[id][2] * dlen
        end
        n, buff = raf:Read(len)
        if n ~= len then break end
        if verbose > 2 then et:VerboseDump(buff) end
        if truthy(dlen) then
            if len % dlen ~= 0 and id ~= 0x700 then -- (have seen one 0x700 record which was expected format but not multiple of 53 bytes)
                et:Warn(sprintf('Unexpected Insta360 record 0x%x length', id))
            elseif id == 0x200 then
                -- there are 4 types of record 0x200
                -- 1. JPEG preview (starts with ff d8 ff e1)
                -- 2. TIFF preview (starts with 01 00 00 00, then record length)
                -- 3. Unknown 1 (starts with 00 00 00 01)
                -- 4. Unknown 2 (starts with 00 00 01 34)
                local ok, c1
                if isMatch(buff, [[^\xff\xd8\xff]]) then
                    et:FoundTag('PreviewImage', buff)
                else
                    ok, c1 = isMatch(buff, [[(?s)^\x01\0\0\0(.{4})\x01]])
                    if ok and unpack('V', c1) == dlen then
                        local w, h = unpack('x16V2', buff)
                        -- build the TIFF image (could the 1 at byte 9 be the SamplesPerPixel?)
                        local hdr = ExifTool.MakeTiffHeader(w, h, 1, 8)
                        et:FoundTag('PreviewTIFF', hdr .. substr(buff, 40))
                    end
                end
            elseif id == 0x300 then
                p = 0
                while p < len do
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    local a
                    if dlen == 56 then
                        a = map(function(v) return GetDouble(buff, p + 8 * v) end, { 1, 2, 3, 4, 5, 6 })
                    else
                        a = { unpack('x' .. p .. 'x8v6', buff) }
                        a = map(function(v) return (v - 0x8000) / 1000 end, a)
                    end
                    et:HandleTag(tagTbl, 'TimeCode', sprintf('%.3f', Get64u(buff, p) / 1000))
                    et:HandleTag(tagTbl, 'Accelerometer', join(' ', { a[1], a[2], a[3] })) -- (NC)
                    et:HandleTag(tagTbl, 'AngularVelocity', join(' ', { a[4], a[5], a[6] })) -- (NC)
                    p = p + dlen
                end
            elseif id == 0x400 then
                p = 0
                while p < len do
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    et:HandleTag(tagTbl, 'TimeCode', sprintf('%.3f', Get64u(buff, p) / 1000))
                    et:HandleTag(tagTbl, 'ExposureTime', GetDouble(buff, p + 8)) --6
                    p = p + dlen
                end
            elseif id == 0x600 then --6
                p = 0
                while p < len do
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    et:HandleTag(tagTbl, 'VideoTimeStamp', sprintf('%.3f', Get64u(buff, p) / 1000))
                    p = p + dlen
                end
            elseif id == 0x700 then
                p = 0
                while p + dlen <= len do
                  do
                    local tmp = substr(buff, p, dlen)
                    local a = { unpack('VVvaa8aa8aa8a8a8', tmp) }
                    if not ((a[6] == 'N' or a[6] == 'S') and -- (quick validation)
                            (a[8] == 'E' or a[8] == 'W' or
                             -- (odd, but I've seen "O" instead of "W".  Perhaps
                             --  when the language is french? ie. "Ouest"?)
                             a[8] == 'O'))
                    then
                        if a[4] == 'V' then goto continue end   -- void fixes don't have N/S E/W
                        et:Warn('Unrecognized INSV GPS format')
                        break
                    end
                    if a[4] ~= 'A' then goto continue end   -- (ignore void fixes)
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    for _, k in ipairs({ 4, 6, 8, 9, 10 }) do a[k + 1] = GetDouble(a[k + 1], 0) end
                    if a[6] == 'S' then a[5] = -math.abs(a[5]) end -- (abs just in case it was already signed)
                    if a[8] ~= 'E' then a[7] = -math.abs(a[7]) end
                    local ms = ''
                    if truthy(a[3]) then ms = subst(sprintf('.%.3d', a[3]), [[0+$]], '') end
                    et:HandleTag(tagTbl, 'GPSDateTime', ConvertUnixTime(a[1]) .. ms .. 'Z')
                    et:HandleTag(tagTbl, 'GPSLatitude', a[5])
                    et:HandleTag(tagTbl, 'GPSLongitude', a[7])
                    et:HandleTag(tagTbl, 'GPSSpeed', a[9] * mpsToKph)
                    et:HandleTag(tagTbl, 'GPSTrack', a[10])
                    et:HandleTag(tagTbl, 'GPSAltitude', a[11])
                    if truthy(unknown) then et:HandleTag(tagTbl, 'Unknown02', a[2]) end
                  end
                    ::continue::
                    p = p + dlen
                end
            end
        elseif id == 0x101 then
            local tagTablePtr = GetTagTable(nil, 'lexiftool.QuickTimeStream.INSV_MakerNotes')
            i, p = 0, 0
            while i < 4 do
                if p + 2 > len then break end
                local t, n_ = unpack('x' .. p .. 'CC', buff)
                if p + 2 + n_ > len then break end
                local val = substr(buff, p + 2, n_)
                et:HandleTag(tagTablePtr, t, val)
                p = p + 2 + n_
                i = i + 1
            end
        elseif id == 0x0 then
            if not truthy(len) then break end
            -- example directory table for record locations from Insta360AcePro MP4 video:
            --  vv vv                         - record ID
            --        vv vv vv vv             - record size
            --                    vv vv vv vv - offset from start of footer
            --  00 00 00 00 00 00 00 00 00 00
            --  01 01 82 04 00 00 1b 45 62 00
            --  02 00 28 46 05 00 ed fe 5c 00
            --  03 00 40 aa 24 00 ed fe 34 00
            --  04 00 00 c1 01 00 ed fe 30 00
            --  [...]
            if not dirTable then
                dirTable = buff
                dirTablePos = 0
            end
        end
        -- step through directory table instead of sequential scanning if possible
        if dirTable then
            epos = nil
            while true do
                if dirTablePos + 10 > length(dirTable) then break end
                local id_, siz, off = unpack('x' .. dirTablePos .. 'vVV', dirTable)
                dirTablePos = dirTablePos + 10
                if truthy(id_) and truthy(siz) and off + siz < trailerLen then
                    epos = off + siz - trailerLen
                    break
                end
            end
            if epos == nil then break end
        else
            epos = epos - 6
            if epos + trailerLen < 0 then break end    -- step back to previous record
        end
        if not raf:Seek(epos - offset, 2) then break end   -- seek to start of next footer
        n, buff = raf:Read(6)
        if n ~= 6 then break end      -- read footer
    end
    et.DOC_NUM = nil
    SetByteOrder('MM')
    et.SET_GROUP0 = nil
    et.SET_GROUP1 = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process CAMM metadata (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessCAMM(et, dirInfo, tagTbl) -- luacheck: ignore 212 (shadowed below, as upstream)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart or 0
    local end_ = pos + (truthy(dirInfo.DirLen) and dirInfo.DirLen or length(dataPt) - pos)
    -- camm record size for each type, including 4-byte header
    local size = { [1] = 12, [2] = 16, [3] = 16, [4] = 16, [5] = 28, [6] = 60, [7] = 16 }
    local rtnVal = 0
    while pos + 4 < end_ do
        local type_ = Get16u(dataPt, pos + 2)
        local size_ = size[type_]
        if not size_ then et:Warn('Unknown camm record type ' .. type_) break end
        if pos + size_ > end_ then et:Warn('Truncated camm record ' .. type_) break end
        local tagTbl_ = GetTagTable(nil, 'lexiftool.QuickTimeStream.camm' .. type_)
        dirInfo.DirStart = pos
        dirInfo.DirLen = size_
        if truthy(et:ProcessBinaryData(dirInfo, tagTbl_)) then rtnVal = 1 end
        -- not sure if this is according to specification, but I have seen multiple
        -- camm records all in a single sample, so step forward to process the next one
        pos = pos + size_
    end
    return rtnVal
end
QuickTimeStream.ProcessCAMM = ProcessCAMM

--------------------------------------------------------------------------------
-- Process Garmin GPS 'uuid' atom (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Note: This format is used by the Garmin DriveAssist 51, but the DriveAssist 50
--       uses a completely different format.  :(
function QuickTimeStream.ProcessGarminGPS(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)
    local pos = 33
    local epoch = (66 * 365 + 17) * 24 * 3600 -- time is relative to Jan 1, 1904
    local scl = 180 / (32768 * 65536)         -- scaling factor for lat/lon
    et:VerboseDir('GarminGPS')
    et.SET_GROUP1 = 'Garmin'
    while pos + 20 <= dataLen do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        local time = ConvertUnixTime(Get32u(dataPt, pos) - epoch) .. 'Z'
        local lat = Get32s(dataPt, pos + 12)
        local lon = Get32s(dataPt, pos + 16)
        local spd = Get16u(dataPt, pos + 4) -- (in mph)
        et:HandleTag(tagTbl, 'GPSDateTime',  time)
        -- skip bad GPS fixes
        if lat ~= -2147483648 or lon ~= -2147483648 then
            et:HandleTag(tagTbl, 'GPSLatitude',  lat * scl)
            et:HandleTag(tagTbl, 'GPSLongitude', lon * scl)
            et:HandleTag(tagTbl, 'GPSSpeed',     spd)
            et:HandleTag(tagTbl, 'GPSSpeedRef', 'M')
        end
        pos = pos + 20
    end
    et.DOC_NUM = nil
    et.SET_GROUP1 = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process 360Fly 'uuid' atom containing sensor data
-- (ref https://github.com/JamesHeinrich/getID3/blob/master/getid3/module.audio-video.quicktime.php)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function Process360Fly(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)
    local pos = 16
    local lastTime = -1
    local streamTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
    while pos + 32 <= dataLen do
        local type_ = ord(substr(dataPt, pos, 1))
        local time = Get64u(dataPt, pos + 2) -- (only valid for some types)
        if tagTbl[type_] then
            if time ~= lastTime then
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                lastTime = time
            end
        end
        et:HandleTag(tagTbl, type_, nil, { DataPt = dataPt, Start = pos, Size = 32 })
        -- synthesize GPSDateTime from the timestamp for GPS records
        if type_ == 5 then SetGPSDateTime(et, streamTbl, time / 1e6) end
        pos = pos + 32
    end
    et.DOC_NUM = nil
    return 1
end
QuickTimeStream.Process360Fly = Process360Fly

--------------------------------------------------------------------------------
-- Process GPS from Vantrue N2S dashcam
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessFMAS(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    if not (isMatch(dataPt, [[(?s)^FMAS\0\0\0\0.{72}SAMM.{36}A]]) and length(dataPt) >= 160) then return 0 end
    et:VerboseDir('FMAS', nil, length(dataPt))
    -- 0000: 46 4d 41 53 00 00 00 00 00 00 00 00 00 00 00 00 [FMAS............]
    -- 0010: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
    -- 0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
    -- 0030: 02 08 01 08 06 08 02 04 07 02 06 00 00 00 00 00 [................]
    -- 0040: 00 00 00 00 00 00 00 00 4f 46 4e 49 4d 4d 41 53 [........OFNIMMAS]
    -- 0050: 53 41 4d 4d 01 00 00 00 00 00 00 00 00 00 00 00 [SAMM............]
    -- 0060: e5 07 09 18 08 00 22 00 02 00 00 00 a1 82 8a bf [......".........]
    -- 0070: 89 23 8e bd 0b 2c 30 bc 41 57 4e 51 16 00 a1 01 [.#...,0.AWNQ....]
    -- 0080: 29 26 27 0c 4b 00 49 00 00 00 00 00 00 00 00 00 [)&'.K.I.........]
    -- 0090: 00 00 00 00 00 00 00 00 00 52 00 00 00 00 00 00 [.........R......]
    -- (`@a` is 0-based upstream: $a[N] is a[N + 1] here)
    local a = { unpack('x96vCCCCCCx16AAACCCvCCvvv', dataPt) }
    SetByteOrder('II')
    local acc = ReadValue(dataPt, 0x6c, 'float', 3) -- (looks like Z comes first in my sample)
    local lon = a[11] + (a[12] + a[14] / 6000) / 60 -- (why zero byte at $a[12]?)
    local lat = a[15] + (a[16] + a[17] / 6000) / 60
    et:HandleTag(tagTbl, 'GPSDateTime', sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', a[1], a[2], a[3], a[4], a[5], a[6]))
    et:HandleTag(tagTbl, 'GPSLatitude', lat * (a[10] == 'S' and -1 or 1))
    et:HandleTag(tagTbl, 'GPSLongitude', lon * (a[9] == 'W' and -1 or 1))
    et:HandleTag(tagTbl, 'GPSSpeed', a[18] * mphToKph) -- convert mph -> kph
    et:HandleTag(tagTbl, 'GPSTrack', a[19])
    et:HandleTag(tagTbl, 'Accelerometer', acc)
    SetByteOrder('MM')
    return 1
end
QuickTimeStream.ProcessFMAS = ProcessFMAS

--------------------------------------------------------------------------------
-- Process GPS from Wolfbox G900 Dashcam and Redtiger F9 4K
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessWolfbox(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    if length(dataPt) < 0xf8 then return 0 end
    et:VerboseDir('Wolfbox', nil, length(dataPt))
    -- 0000: 65 00 00 00 00 00 00 00 31 01 01 00 e3 ff 00 00 [e.......1.......]
    -- 0010: 04 00 00 00 10 00 00 00 2a 00 00 00 00 00 00 00 [........*.......]
    -- 0020: 01 00 00 00 00 00 00 00 8b 33 ff 51 00 00 00 00 [.........3.Q....]
    -- 0030: a0 86 01 00 00 00 00 00 4d 5e 07 fa ff ff ff ff [........M^......]
    -- 0040: a0 86 01 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
    -- 0050: 64 00 00 00 00 00 00 00 90 21 00 00 00 00 00 00 [d........!......]
    -- 0060: 64 00 00 00 00 00 00 00 18 00 00 00 03 00 00 00 [d...............]
    -- 0070: e8 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
    -- 0080: 00 00 00 00 00 00 00 00 30 30 30 30 30 30 30 30 [........00000000]
    -- 0090: 30 30 30 30 30 30 30 30 48 59 54 48 00 00 00 00 [00000000HYTH....]
    -- 00a0: 0c 00 00 00 10 00 00 00 2a 00 00 00 00 00 00 00 [........*.......]
    -- 00b0: 4f 3f 0c 1f 00 00 00 00 a0 86 01 00 00 00 00 00 [O?..............]
    -- 00c0: 7f cf 2d ff ff ff ff ff a0 86 01 00 00 00 00 00 [..-.............]
    -- 00d0: 01 00 00 00 08 00 00 00 0a 00 00 00 00 00 00 00 [................]
    -- 00e0: 0a 00 00 00 00 00 00 00 e8 03 00 00 00 00 00 00 [................]
    -- 00f0: 0a 00 00 00 00 00 00 00 4d 00 00 00 00 00 00 00 [........M.......]
    -- lat/lon at 0xb0/0xc0 and 0x128/0x138
    -- h/m/s at 0x10 and 0xa0 and 0x148 (the first imprinted on the video, and
    -- the latter 2 presumed UTC, but there is a 1 second offset for the Redtiger)
    -- spd at 0x48, dir at 0x58, alt at 0xe8
    -- Redtiger F9 4K Dual Front and Rear Mini Dash Cam
    -- 0000: 01 00 00 00 00 00 00 00 f4 ff 5d fe 24 00 00 00 [..........].$...]
    -- 0010: 10 00 00 00 2d 00 00 00 25 00 00 00 00 00 00 00 [....-...%.......]
    -- 0020: 01 00 00 00 00 00 00 00 44 eb 8f 00 00 00 00 00 [........D.......]
    -- 0030: 10 27 00 00 00 00 00 00 1b 94 8a 04 00 00 00 00 [.'..............]
    -- 0040: 10 27 00 00 00 00 00 00 8c 69 00 00 00 00 00 00 [.'.......i......]
    -- 0050: e8 03 00 00 00 00 00 00 ba 47 00 00 00 00 00 00 [.........G......]
    -- 0060: 64 00 00 00 00 00 00 00 19 00 00 00 05 00 00 00 [d...............]
    -- 0070: e9 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
    -- 0080: 00 00 00 00 00 00 00 00 30 30 30 30 30 30 30 30 [........00000000]
    -- 0090: 30 30 30 30 30 30 30 30 58 58 58 58 00 00 00 00 [00000000XXXX....]
    -- 00a0: 08 00 00 00 2d 00 00 00 24 00 00 00 00 00 00 00 [....-...$.......]
    -- 00b0: 90 eb 8f 00 00 00 00 00 10 27 00 00 00 00 00 00 [.........'......]
    -- 00c0: 20 94 8a 04 00 00 00 00 10 27 00 00 00 00 00 00 [ ........'......]
    -- 00d0: 01 00 00 00 11 00 00 00 40 00 00 00 00 00 00 00 [........@.......]
    -- 00e0: 64 00 00 00 00 00 00 00 8a 00 00 00 00 00 00 00 [d...............]
    -- 00f0: 0a 00 00 00 00 00 00 00 4d 00 00 00 00 00 00 00 [........M.......]
    SetByteOrder('II')
    local d, mo, yr, h, m, s = unpack('x104V3x44V3', dataPt)
    local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', yr, mo, d, h, m, s)
    local a = {}  -- (0-based upstream: $a[N] is a[N + 1] here)
    --             0=spd 1=dir 2=lat 3=lon 4=alt
    for _, pos in ipairs({ 0x48, 0x58, 0xb0, 0xc0, 0xe8 }) do
        local val = Get64s(dataPt, pos)
        local scl = Get64s(dataPt, pos + 8)
        a[#a + 1] = val / (truthy(scl) and scl or 1)
    end
    a[3], a[4] = ConvertLatLon(a[3], a[4])
    et:HandleTag(tagTbl, 'GPSDateTime', time)
    et:HandleTag(tagTbl, 'GPSLatitude', a[3])
    et:HandleTag(tagTbl, 'GPSLongitude', a[4])
    et:HandleTag(tagTbl, 'GPSSpeed', a[1] * knotsToKph)
    et:HandleTag(tagTbl, 'GPSTrack', a[2])
    et:HandleTag(tagTbl, 'GPSAltitude', a[5])
    return 1
end
QuickTimeStream.ProcessWolfbox = ProcessWolfbox

--------------------------------------------------------------------------------
-- Scan media data for "freeGPS" and GoPro metadata if not found already (ref PH)
-- Inputs: 0) ExifTool ref
function QuickTimeStream.ScanMediaData(et)
    local raf = et.RAF
    if not raf then return end
    local tagTbl, verbose, buff, dataLen, found, cnt

    -- don't rescan for freeGPS if we already found embedded metadata
    local dataPos = et.MediaDataOffset
    if truthy(et.FoundEmbedded) or not truthy(dataPos) then return end

    local pos, buf2 = 0, ''
    local ee = et:Options('ExtractEmbedded') or 0
    if ee > 2 then -- scan entire file from start of mdat if ExtractEmbedded > 2
        raf:Seek(0, 2)
        dataLen = raf:Tell() - et.MediaDataOffset
    else
        dataLen = et.MediaDataSize
    end
    if not (truthy(dataLen) and raf:Seek(dataPos)) then return end

    -- loop through 'mdat' media data looking for GPS information
    while truthy(dataLen) do
        local n = gpsBlockSize
        if n + pos > dataLen then n = dataLen - pos end
        if n <= length(buf2) then break end
        cnt, buff = raf:Read(n - length(buf2))
        if not truthy(cnt) then break end
        if length(buf2) > 0 then buff = buf2 .. buff end
        -- look for "freeGPS " or GoPro record
        -- (freeGPS found on an absolute 0x8000-byte boundary in all of my samples,
        --  but allow for any alignment when searching)
        -- (`pos($buff)` is the end offset of this match)
        local c1, buffPos = matches(buff, [[(?s)(\0..\0freeGPS |GP\x06\0\0)]])
        if c1 == nil then
            buf2 = substr(buff, -12)
            pos = pos + length(buff) - 12
            -- in all of my samples the first freeGPS block is within 2 MB of the start
            -- of the mdat, so limit the scan to the first 20 MB to be fast and safe
            if truthy(found) or pos < 20e6 or ee > 1 then goto continue end
            break
        elseif c1 == "GP\x06\0\0" then -- (GoPro GPS record header)
            -- (found in Chigee Aio-5 Lite and some Insta360 videos)
            local filePos = raf:Tell()
            local start = filePos - length(buff) + buffPos - length(c1)
            if not raf:Seek(start) then break end
            if found == nil then
                et:VPrint(0, "---- Extract Embedded ----\n")
                et.INDENT = et.INDENT .. '| '
                found = 0
            end
            local maxLen = dataLen - (start - et.MediaDataOffset)
            local GoPro = require('lexiftool.GoPro')
            et:VPrint(0, sprintf("Unreferenced GoPro record at 0x%x\n", filePos))
            local size = GoPro.ProcessGP6(et, { RAF = raf, DirLen = maxLen })
            if truthy(size) then
                if not truthy(found) then
                    -- scan entire file if we found a valid GoPro record
                    -- (some records may exist in trailer)
                    if raf:Seek(0, 2) then dataLen = raf:Tell() - et.MediaDataOffset end
                    found = 2
                end
                if not raf:Seek(start + size) then break end
                pos = start + size - et.MediaDataOffset
                buf2 = ''
            else
                -- (could have been a random match -- continue with search)
                if not raf:Seek(filePos) then break end
                buf2 = substr(buff, buffPos)
                pos = pos + buffPos
            end
            goto continue
        end
        if length(buff) < gpsBlockSize then break end
        if not tagTbl then
            -- initialize variables for extracting metadata from this block
            tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            verbose = et.OPTIONS.Verbose
            et:VPrint(0, "---- Extract Embedded ----\n")
            et.INDENT = et.INDENT .. '| '
            found = 1
        end
        if buffPos > 12 then
            pos = pos + buffPos - 12
            buff = substr(buff, buffPos - 12)
        end
        -- make sure we have the full freeGPS record
        do
            local len = unpack('N', buff)
            if len < 12 then
                len = 12
            else
                local more = len - length(buff)
                if more > 0 then
                    cnt, buf2 = raf:Read(more)
                    if cnt ~= more then break end
                    buff = buff .. buf2
                end
                if truthy(verbose) then
                    et:VerboseDir('GPS', nil, len)
                    et:VerboseDump(buff, { DataPos = pos + dataPos })
                end
                local dirInfo = { DataPt = buff, DataPos = pos + dataPos, DirLen = len }
                ProcessFreeGPS(et, dirInfo, tagTbl)
                buff = dirInfo.DataPt -- (ProcessFreeGPS may change the buffer, as upstream)
                et.FoundGPSByScan = 1
            end
            pos = pos + len
            buf2 = substr(buff, len)
        end
        ::continue::
    end
    if truthy(found) then
        et.DOC_NUM = nil -- reset DOC_NUM after extracting embedded metadata
        et:VPrint(0, "--------------------------\n")
        et.INDENT = substr(et.INDENT, 0, -2)
    end
end

-- (PROCESS_PROC of the tables above: the predeclared subs exist only now, see
--  the predeclaration placeholders)
QuickTimeStream.camm0.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm1.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm2.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm3.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm4.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm5.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm6.PROCESS_PROC = ProcessCAMM
QuickTimeStream.camm7.PROCESS_PROC = ProcessCAMM
QuickTimeStream.tx3g.PROCESS_PROC = Process_tx3g
QuickTimeStream.Tags360Fly.PROCESS_PROC = Process360Fly

return QuickTimeStream
