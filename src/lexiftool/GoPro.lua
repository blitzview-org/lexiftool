--------------------------------------------------------------------------------
-- File:         lexiftool/GoPro.lua
-- Ported from:  lib/Image/ExifTool/GoPro.pm
--
-- Description:  Read information from GoPro videos
--
-- Revisions:    2018/01/12 - P. Harvey Created
--
-- References:   1) https://github.com/gopro/gpmf-parser
--               2) https://github.com/stilldavid/gopro-utils
--               3) https://github.com/gopro/gpmf-parser
--
-- Port notes:   read port of the APP6 "GoPro" segment of JPEG images and of
--               the GPMF/gpmd metadata. All seven tag tables are carried in
--               full (GPMF, GPS5, GPS9, GPRI, GLPI, KBAT, fdsc), as are the
--               goProFmt/goProSize format maps and ScaleValues,
--               ConvertSystemTime, ProcessString and ProcessGoPro (the full
--               record walker, including the TYPE-driven 0x3f structure
--               decode and the TYPE/UNIT/SIUN/SCAL state tracking).
--               ProcessGP6 ("GP\x06\0" mdat records) is ported for
--               QuickTimeStream's ScanMediaData.
--               AddUnits is ported: its PrintConv receives the tag key as
--               third argument (upstream's `$tag` in the eval'd string), and
--               ProcessGoPro saves the UNIT/SIUN units in TAG_EXTRA.
--               PrintableTagID is a local subset of the QuickTime.pm
--               function, kept from before QuickTime.lua existed.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local unpack = perl.unpack
local sprintf = perl.sprintf
local tsort = perl.tsort
local perlStr = perl.str

local GoPro = {}

-- GoPro data types that have ExifTool equivalents (ref 1)
local goProFmt = { -- format codes
    -- 0x00 - container (subdirectory)
    [0x62] = 'int8s',    -- 'b'
    [0x42] = 'int8u',    -- 'B'
    [0x63] = 'string',   -- 'c' (possibly null terminated)
    [0x73] = 'int16s',   -- 's'
    [0x53] = 'int16u',   -- 'S'
    [0x6c] = 'int32s',   -- 'l'
    [0x4c] = 'int32u',   -- 'L'
    [0x66] = 'float',    -- 'f'
    [0x64] = 'double',   -- 'd'
    [0x46] = 'undef',    -- 'F' (4-char ID)
    [0x47] = 'undef',    -- 'G' (16-byte uuid)
    [0x6a] = 'int64s',   -- 'j'
    [0x4a] = 'int64u',   -- 'J'
    [0x71] = 'fixed32s', -- 'q'
    [0x51] = 'fixed64s', -- 'Q'
    [0x55] = 'undef',    -- 'U' (16-byte date)
    [0x3f] = 'undef',    -- '?' (complex structure)
}

-- sizes of format codes if different than what FormatSize() would return
local goProSize = {
    [0x46] = 4,
    [0x47] = 16,
    [0x55] = 16,
}

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

-- tagInfo elements to add units to PrintConv value
local addUnits = spread {
    AddUnits = 1,
    PrintConv = function(self, val, tag) return GoPro.AddUnits(self, val, tag) end,
}

local noYes = { N = 'No', Y = 'Yes' }

-- Tags found in the GPMF box of Hero6 mp4 videos (ref PH), and
-- the gpmd-format timed metadata of Hero5 and Hero6 videos (ref 1)
GoPro.GPMF = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Camera' },
    NOTES = [[
        Tags extracted from the GPMF box of GoPro MP4 videos, the APP6 "GoPro"
        segment of JPEG files, and from the "gpmd" timed metadata if the
        L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option is enabled.  Many more tags exist, but are
        currently unknown and extracted only with the L<Unknown|../ExifTool.html#Unknown> (-u) option. Please
        let me know if you discover the meaning of any of these unknown tags. See
        L<https://github.com/gopro/gpmf-parser> for details about this format.
    ]],
    ABSC = 'AutoBoostScore', --3
    ACCL = { --2 (gpmd)
        Name = 'Accelerometer',
        Notes = 'accelerator readings in m/s2',
        Binary = 1,
    },
  -- ANGX (GPMF-GEOC) - seen -0.05 (fmt d, Max)
  -- ANGY (GPMF-GEOC) - seen 179.9 (fmt d, Max)
  -- ANGZ (GPMF-GEOC) - seen 0.152 (fmt d, Max)
    ALLD = 'AutoLowLightDuration', --1 (gpmd) (untested)
    APTO = 'AudioProtuneOption', --3
    ARUW = 'AspectRatioUnwarped', --3
    ARWA = 'AspectRatioWarped', --3
    ATTD = { --PH (Karma)
        Name = 'Attitude',
        -- UNIT=s,rad,rad,rad,rad/s,rad/s,rad/s,
        -- TYPE=LffffffB
        -- SCAL=1000 1 1 1 1 1 1 1
        Binary = 1,
    },
    ATTR = { --PH (Karma)
        Name = 'AttitudeTarget',
        -- UNIT=s,rad,rad,rad,
        -- TYPE=Jffff
        -- SCAL=1000 1 1 1 1
        Binary = 1,
    },
    AUBT = { Name = 'AudioBlueTooth', PrintConv = noYes }, --3
    AUDO = 'AudioSetting', --PH (GPMF - seen: 'WIND', fmt c)
    AUPT = { Name = 'AutoProtune', PrintConv = noYes },
    BITR = 'BitrateSetting', --3
    BPOS = addUnits { --PH (Karma)
        Name = 'Controller',
        Unknown = 1,
        -- UNIT=deg,deg,m,deg,deg,m,m,m
        -- TYPE=lllfffff
        -- SCAL=10000000 10000000 1000 1 1 1 1 1
    },
  -- BRID (GPMF) - seen: 0 (fmt B)
  -- BROD (GPMF) - seen: 'ASK','' (fmt c)
  -- CALH (GPMF-GEOC) - seen 3040 (fmt L, Max)
  -- CALW (GPMF-GEOC) - seen 4056 (fmt L, Max)
    CASN = 'CameraSerialNumber', --PH (GPMF - seen: 'C3221324545448', fmt c)
    CDAT = { --3
        Name = 'CreationDate',
        Groups = { [2] = 'Time' },
        RawConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    CDTM = 'CaptureDelayTimer', --3
  -- CINF (GPMF) - seen: 0x67376be7709bc8876a8baf3940908618, 0xe230988539b30cf5f016627ae8fc5395,
  --                     0x8bcbe424acc5b37d7d77001635198b3b (fmt B) (Camera INFormation?)
    CLDP = { Name = 'ClassificationDataPresent', PrintConv = noYes },
  -- CLKC (GPMF) - seen: 0 (fmt L)
  -- CLKS (GPMF) - seen: 2 (fmt B)
  -- CMOD (GPMF) - seen: 12,13,17 [12 360 video, 13 time-laps video, 17 JPEG] (fmt B) - CameraMode (ref 3)
  -- CPID (GPMF) - seen: '1194885996 3387225026 733916448 2433577768' (fmt L)
  -- CPIN (GPMF) - seen: 1
    CPIN = 'ChapterNumber',
  -- CRTX (GPMF-BACK/FRNT) - double[1]
  -- CRTY (GPMF-BACK/FRNT) - double[1]
    CSEN = { --PH (Karma)
        Name = 'CoyoteSense',
        -- UNIT=s,rad/s,rad/s,rad/s,g,g,g,,,,
        -- TYPE=LffffffLLLL
        -- SCAL=1000 1 1 1 1 1 1 1 1 1 1
        Binary = 1,
    },
    CTRL = 'ControlLevel', --3
    CYTS = { --PH (Karma)
        Name = 'CoyoteStatus',
        -- UNIT=s,,,,,rad,rad,rad,,
        -- TYPE=LLLLLfffBB
        -- SCAL=1000 1 1 1 1 1 1 1 1 1
        Binary = 1,
    },
    DEVC = { --PH (gpmd,GPMF, fmt \0)
        Name = 'DeviceContainer',
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPMF' },
        -- (Max) DVID=1,DVNM='Global Settings',VERS,FMWR,LINF,CINF,CASN,MINF,MUID,CMOD,MTYP,OREN,
        --       DZOM,DZST,SMTR,PRTN,PTWB,PTSH,PTCL,EXPT,PIMX,PIMN,PTEV,RATE,SROT,ZFOV,VLTE,VLTA,
        --       EISE,EISA,AUPT,AUDO,BROD,BRID,PVUL,PRJT,SOFF
        -- (Max) DVID='GEOC',DVNM='Geometry Calibrations',SHFX,SHFY,SHFZ,ANGX,ANGY,ANGZ,CALW,CALH
        -- (Max) DVID='BACK',DVNM='Back Lens',KLNS,CTRX,CTRY,MFOV,SFTR
        -- (Max) DVID='FRNT',DVNM='Front Lens',KLNS,CTRX,CTRY,MFOV,SFTR
        -- (Max) DVID='HLMT',DVNM='Highlights'
    },
  -- DNSC (GPMF) - seen: 'HIGH' (fmt c)
    DUST = 'DurationSetting', --3
  -- DVID (GPMF) - DeviceID; seen: 1 (fmt L), HLMT (fmt F), GEOC (fmt F), 'BACK' (fmt F, Max)
    DVID = { Name = 'DeviceID', Unknown = 1 }, --2 (gpmd)
  -- DVNM (GPMF) seen: 'Video Global Settings' (fmt c), 'Highlights' (fmt c), 'Geometry Calibrations' (Max)
  -- DVNM (gpmd) seen: 'Camera' (Hero5), 'Hero6 Black' (Hero6), 'GoPro Karma v1.0' (Karma)
    DVNM = 'DeviceName', --PH (n/c)
    DZOM = { --PH (GPMF - seen: 'Y', fmt c)
        Name = 'DigitalZoomOn',
        PrintConv = noYes,
    },
    DZMX = 'DigitalZoomAmount', --3
    DZST = 'DigitalZoom', --3
    EISA = { --PH (GPMF) - seen: 'Y','N','HS EIS','N/A' (fmt c) [N was for a time-lapse video]
        Name = 'ElectronicImageStabilization',
    },
    EISE = { Name = 'ElectronicStabilizationOn', PrintConv = noYes }, --3
    EMPT = { Name = 'Empty', Unknown = 1 }, --2 (gpmd)
    ESCS = addUnits { --PH (Karma)
        Name = 'EscapeStatus',
        -- UNIT=s,rpm,rpm,rpm,rpm,rpm,rpm,rpm,rpm,degC,degC,degC,degC,V,V,V,V,A,A,A,A,,,,,,,,,
        -- TYPE=JSSSSSSSSssssSSSSSSSSSSSSSSSSB
        -- (no SCAL!)
        Unknown = 1,
    },
    EXPT = 'ExposureType', --3
    FACE = 'FaceDetected', --PH (gpmd)
    FCNM = 'FaceNumbers', --PH (gpmd) (faces counted per frame, ref 1)
    FMWR = 'FirmwareVersion', --PH (GPMF - seen: HD6.01.01.51.00, fmt c)
    FWVS = 'OtherFirmware', --PH (NC) (gpmd - seen: '1.1.11.0', Karma)
    GLPI = { --PH (gpmd, Karma)
        Name = 'GPSPos',
        -- UNIT=s,deg,deg,m,m,m/s,m/s,m/s,deg
        -- TYPE=LllllsssS
        -- SCAL=1000 10000000 10000000 1000 1000 100 100 100 100
        RawConv = function(_self, val) return val end, -- necessary to use scaled value instead of raw data as subdir data
        SubDirectory = { TagTable = 'lexiftool.GoPro.GLPI' },
    },
    GPRI = { --PH (gpmd, Karma)
        Name = 'GPSRaw',
        -- UNIT=s,deg,deg,m,m,m,m/s,deg,,
        -- TYPE=JlllSSSSBB
        -- SCAL=1000000,10000000,10000000,1000,100,100,100,100,1,1
        Unknown = 1,
        RawConv = function(_self, val) return val end, -- necessary to use scaled value instead of raw data as subdir data
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPRI' },
    },
    GPS5 = { --2 (gpmd)
        Name = 'GPSInfo',
        -- UNIT=deg,deg,m,m/s,m/s
        -- TYPE=l
        -- SCAL=10000000,10000000,1000,1000,100
        RawConv = function(_self, val) return val end, -- necessary to use scaled value instead of raw data as subdir data
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPS5' },
    },
    GPS9 = { --PH (gpmd, Hero 13)
        Name = 'GPSInfo9',
        -- UNIT=deg,deg,m,m/s,m/s,,s,,
        -- TYPE=lllllllSS
        -- SCAL=10000000 10000000 1000 1000 100 1 1000 100 1
        RawConv = function(_self, val) return val end, -- necessary to use scaled value instead of raw data as subdir data
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPS9' },
    },
    GPSF = { --2 (gpmd)
        Name = 'GPSMeasureMode',
        PrintConv = {
            [2] = '2-Dimensional Measurement',
            [3] = '3-Dimensional Measurement',
        },
    },
    GPSP = { --2 (gpmd)
        Name = 'GPSHPositioningError',
        Description = 'GPS Horizontal Positioning Error',
        ValueConv = function(_self, val) return val / 100 end, -- convert from cm to m
    },
    GPSU = { --2 (gpmd)
        Name = 'GPSDateTime',
        Groups = { [2] = 'Time' },
        -- (HERO5 writes this in 'c' format, HERO6 writes 'U')
        ValueConv = function(_self, val)
            return subst(perlStr(val), [[^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})]],
                         '20$1:$2:$3 $4:$5:')
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    GYRO = { --2 (gpmd)
        Name = 'Gyroscope',
        Notes = 'gyroscope readings in rad/s',
        Binary = 1,
    },
    LOGS = 'HealthLogs',
    HCTL = 'HorizonControl', --3
    HDRV = { Name = 'HDRVideo', PrintConv = noYes }, --3/PH (NC)
  -- HFLG (APP6) - seen: 0
    HSGT = 'HindsightSettings', --3
    ISOE = 'ISOSpeeds', --PH (gpmd)
    ISOG = { --2 (gpmd)
        Name = 'ImageSensorGain',
        Binary = 1,
    },
    KBAT = { --PH (gpmd) (Karma)
        Name = 'BatteryStatus',
        -- UNIT=A,Ah,J,degC,V,V,V,V,s,%,,,,,%
        -- TYPE=lLlsSSSSSSSBBBb
        -- SCAL=1000,1000,0.00999999977648258,100,1000,1000,1000,1000,0.0166666675359011,1,1,1,1,1,1
        RawConv = function(_self, val) return val end, -- necessary to use scaled value instead of raw data as subdir data
        SubDirectory = { TagTable = 'lexiftool.GoPro.KBAT' },
    },
  -- KLNS (GPMF-BACK/FRNT) - double[5] (fmt d, Max)
  -- LINF (GPMF) - seen: LAJ7061916601668,C3341326002180,C33632245450981 (fmt c) (Lens INFormation?)
  -- LMOD (GPMF) - seen: 'NONE' (fmt F)
    LNED = { --PH (Karma)
        Name = 'LocalPositionNED',
        -- UNIT=s,m,m,m,m/s,m/s,m/s
        -- TYPE=Lffffff
        -- SCAL=1000 1 1 1 1 1 1
        Binary = 1,
    },
    MAGN = 'Magnetometer', --1 (gpmd) (units of uT)
    MAPX = 'MappingXCoefficients', --3
    MAPY = 'MappingYCoefficients', --3
  -- MFOV (GPMF-BACK/FRNT) - seen: 100 (fmt d, Max)
    MINF = { --PH (GPMF - seen: HERO6 Black, fmt c)
        Name = 'Model',
        Groups = { [2] = 'Camera' },
        Description = 'Camera Model Name',
    },
    MMOD = 'MediaMode', --3
  -- MTYP (GPMF) - seen: 0,1,5,11 [1 for time-lapse video, 5 for 360 video, 11 for JPEG] (fmt B) - MediaType (ref 3)
  -- (upstream defines MUID twice: 'MediaUID' here and 'MediaUniqueID' in the
  --  forum12825 block below -- in Perl the later one wins, so only that one is
  --  a Lua key; this is the dead first definition)
--  MUID = { Name = 'MediaUID', ValueConv = 'join("-", unpack("H8H4H4H4H12", $val))' },
    MXCF = 'MappingXMode', --3
    MYCF = 'MappingYMode', --3
    ORDP = { Name = 'OrientationDataPresent', PrintConv = noYes }, --3
    OREN = { --PH (GPMF - seen: 'U', fmt c)
        Name = 'AutoRotation',
        PrintConv = {
            U = 'Up',
            D = 'Down', -- (NC)
            A = 'Auto', -- (NC)
        },
    },
    -- (most of the "P" tags are Protune settings - PH)
    PHDR = 'HDRSetting', --PH (APP6 - seen: 0)
    PIMD = 'ProtuneISOMode', --3
    PIMN = 'AutoISOMin', --PH (GPMF - seen: 100, fmt L)
    PIMX = 'AutoISOMax', --PH (GPMF - seen: 1600, fmt L)
    POLY = 'PolynomialCoefficients', --3
  -- PRAW (APP6) - seen: 0, 'N', 'Y' (fmt c)
  -- PRCN (GPMF) - seen: 65 zeros (fmt B)
    PRES = 'PhotoResolution', --PH (APP6 - seen: '12MP_W')
    PRJT = 'LensProjection', --3
  -- PRNA (GPMF) - seen 10 (fmt B) - PresetIDs (ref 3)
  -- PRNU (GPMF) - seen 0 (fmt B) - PresetIDs (ref 3)
    PRTN = { --PH (GPMF - seen: 'N', fmt c)
        Name = 'Protune',
        PrintConv = {
            N = 'Off',
            Y = 'On', -- (NC)
        },
    },
    PTCL = 'ColorMode', --PH (GPMF - seen: 'GOPRO', fmt c' APP6: 'FLAT')
    PTEV = 'ExposureCompensation', --PH (GPMF - seen: '0.0', fmt c)
    PTSH = 'Sharpness', --PH (GPMF - seen: 'HIGH', fmt c)
    PTWB = 'WhiteBalance', --PH (GPMF - seen: 'AUTO', fmt c)
  -- PVUL (APP6) - seen: 'F' (fmt c, Hero8, Max)
    PWPR = 'PowerProfile', --3
    PYCF = 'PolynomialPower', --3
    RAMP = 'SpeedRampSetting', --3
    RATE = 'Rate', --PH (GPMF - seen: '0_5SEC', fmt c; APP6 - seen: '4_1SEC')
    RMRK = { --2 (gpmd)
        Name = 'Comments',
        ValueConv = function(self, val) return self:Decode(val, 'Latin') end,
    },
    SCAL = { --2 (gpmd) scale factor for subsequent data
        Name = 'ScaleFactor',
        Unknown = 1,
    },
    SCAP = { Name = 'ScheduleCapture', PrintConv = noYes }, --3
    SCPR = addUnits { --PH (Karma) [stream was empty]
        Name = 'ScaledPressure',
        -- UNIT=s,Pa,Pa,degC
        -- TYPE=Lffs
        -- SCAL=1000 0.00999999977648258 0.00999999977648258 100
    },
    SCTM = 'ScheduleCaptureTime', --3 (seconds since UTC midnight)
  -- SFTR (GPMF-BACK/FRNT) - seen 0.999,1.00004 (fmt d, Max)
  -- SHFX (GPMF-GEOC) - seen 22.92 (fmt d, Max)
  -- SHFY (GPMF-GEOC) - seen 0.123 (fmt d, Max)
  -- SHFZ (GPMF-GEOC) - seen 36.06 (fmt d, Max)
    SHUT = { --2 (gpmd)
        Name = 'ExposureTimes',
        PrintConv = function(_self, val)
            local a = {}
            for tok in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do
                a[#a + 1] = require('lexiftool.Exif').PrintExposureTime(tok)
            end
            return table.concat(a, ' ')
        end,
    },
    SIMU = addUnits { --PH (Karma)
        Name = 'ScaledIMU',
        -- UNIT=s,g,g,g,rad/s,rad/s,rad/s,T,T,T
        -- TYPE=Lsssssssss
        -- SCAL=1000 1000 1000 1000 1000 1000 1000 1000 1000 1000
    },
    SIUN = { --2 (gpmd - seen : 'm/s2','rad/s')
        Name = 'SIUnits',
        Unknown = 1,
        ValueConv = function(self, val) return self:Decode(val, 'Latin') end,
    },
    SMTR = { Name = 'SpotMeter', PrintConv = noYes }, --3
  -- SOFF (APP6) - seen: 0 (fmt L, Hero8, Max)
    SROT = 'SensorReadoutTime', --3
    STMP = { --1 (gpmd)
        Name = 'TimeStamp',
        ValueConv = function(_self, val) return val / 1e6 end,
    },
    STRM = { --2 (gpmd,GPMF, fmt \0)
        Name = 'NestedSignalStream',
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPMF' },
    },
    STNM = { --2 (gpmd)
        Name = 'StreamName',
        Unknown = 1,
        ValueConv = function(self, val) return self:Decode(val, 'Latin') end,
    },
    SYST = { --PH (Karma)
        Name = 'SystemTime',
        -- UNIT=s,s
        -- TYPE=JJ
        -- SCAL=1000000 1000
        -- save system time calibrations for later
        RawConv = function(self, val)
            local v = {}
            for tok in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(tok) end
            if #v == 2 then
                local s = self.SystemTimeList
                if not s then s = { } self.SystemTimeList = s end
                s[#s + 1] = v
            end
            return val
        end,
    },
  -- TICK => { Name => 'InTime', Unknown => 1, ValueConv => '$val/1000' }, #1 (gpmd)
    TMPC = { --2 (gpmd)
        Name = 'CameraTemperature',
        PrintConv = function(_self, val) return perlStr(val) .. ' C' end,
    },
  -- TOCK => { Name => 'OutTime', Unknown => 1, ValueConv => '$val/1000' }, #1 (gpmd)
    TSMP = { Name = 'TotalSamples', Unknown = 1 }, --2 (gpmd)
    TIMO = 'TimeOffset',
    TYPE = { Name = 'StructureType', Unknown = 1 }, --2 (gpmd,GPMF - eg 'LLLllfFff', fmt c)
    TZON = { -- (GPMF) - seen: 60 (fmt s)
        Name = 'TimeZone',
        PrintConv = function(_self, val) return ExifTool.TimeZoneString(val) end,
    },
    UNIT = { --2 (gpmd) alternative units
        Name = 'Units',
        Unknown = 1,
        ValueConv = function(self, val) return self:Decode(val, 'Latin') end,
    },
    VERS = {
        Name = 'MetadataVersion',
        PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '.')) end,
    },
    VFOV = { --PH (GPMF - seen: 'W', fmt c)
        Name = 'FieldOfView',
        PrintConv = {
            W = 'Wide',
            S = 'Super View', -- (NC, not seen)
            L = 'Linear', -- (NC, not seen)
        },
    },
  -- VLTA (GPMF) - seen: 78 ('N') (fmt B -- wrong format?)
    VFPS = { Name = 'VideoFrameRate', PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '/', 1)) end }, --PH (GPMF, fmt L)
    VFRH = { --PH (Karma)
        Name = 'VisualFlightRulesHUD',
        BinaryData = 1,
        -- UNIT=m/s,m/s,m,m/s,deg,%
        -- TYPE=ffffsS
    },
  -- VLTE (GPMF) - seen: 'Y','N' (fmt c)
    VRES = { Name = 'VideoFrameSize', PrintConv = function(_self, val) return (perlStr(val):gsub(' ', 'x', 1)) end }, --PH (GPMF, fmt L)
    WBAL = 'ColorTemperatures', --PH (gpmd)
    WRGB = { --PH (gpmd)
        Name = 'WhiteBalanceRGB',
        Binary = 1,
    },
    ZFOV = 'DiagonalFieldOfView', --3
    ZMPL = 'ZoomScaleNormalization', --3
--
-- the following ref forum12825
--
    MUID = {
        Name = 'MediaUniqueID',
        PrintConv = function(_self, val)
            local a = {}
            for tok in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do
                a[#a + 1] = sprintf('%.8x', tonumber(tok))
            end
            return table.concat(a)
        end,
    },
    MTRX = 'AccelerometerMatrix',
    ORIN = 'InputOrientation',
    ORIO = 'OutputOrientation',
    UNIF = 'InputUniformity',
  -- (upstream repeats SROT here with the same value; once is enough for Lua)
--  SROT = 'SensorReadoutTime',
    -- the following are ref https://exiftool.org/forum/index.php?topic=15517.0
    CORI = { Name = 'CameraOrientation', Binary = 1, Notes = 'quaternions 0-1' },
    AALP = { Name = 'AudioLevel', Notes = 'dBFS' },
    GPSA = 'GPSAltitudeSystem', -- (eg. 'MSLV')
    GRAV = { Name = 'GravityVector', Binary = 1 },
    -- DISP - Disparity track
    HUES = 'PredominantHue',
    IORI = { Name = 'ImageOrientation', Binary = 1, Notes = 'quaternions 0-1' },
    -- LRVO - ? Part of LRV Frame Skip
    -- LRVS - ? Part of LRV Frame Skip
    -- LSKP - LRV Frame Skip
    -- MSKP - MRV Frame Skip
    MWET = 'MicrophoneWet',
    SCEN = 'SceneClassification', -- (SNOW,URBA,INDO,WATR,VEGE,BEAC + probability)
    WNDM = 'WindProcessing',
    YAVG = 'LumaAverage',
}

-- GoPro GPS5 tags (ref 2) (Hero5,Hero6,Hero9)
GoPro.GPS5 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [1] = 'GoPro', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Index' },
    [0] = { -- (unit='deg')
        Name = 'GPSLatitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [1] = { -- (unit='deg')
        Name = 'GPSLongitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [2] = { -- (unit='m')
        Name = 'GPSAltitude',
        PrintConv = function(_self, val) return perlStr(val) .. ' m' end,
    },
    [3] = {
        Name = 'GPSSpeed',
        Notes = 'stored as m/s but converted to km/h when extracted',
        ValueConv = function(_self, val) return val * 3.6 end,
    },
    [4] = {
        Name = 'GPSSpeed3D',
        Notes = 'stored as m/s but converted to km/h when extracted',
        ValueConv = function(_self, val) return val * 3.6 end,
    },
}

-- GoPro GPS9 tags (Hero13)
GoPro.GPS9 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [1] = 'GoPro', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Index' },
    [0] = { -- (unit='deg')
        Name = 'GPSLatitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [1] = { -- (unit='deg')
        Name = 'GPSLongitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [2] = { -- (unit='m')
        Name = 'GPSAltitude',
        PrintConv = function(_self, val) return perlStr(val) .. ' m' end,
    },
    [3] = {
        Name = 'GPSSpeed',
        Notes = 'stored as m/s but converted to km/h when extracted',
        ValueConv = function(_self, val) return val * 3.6 end,
    },
    [4] = {
        Name = 'GPSSpeed3D',
        Notes = 'stored as m/s but converted to km/h when extracted',
        ValueConv = function(_self, val) return val * 3.6 end,
    },
    [5] = { -- days since 2000
        Name = 'GPSDays',
        RawConv = function(self, val) self.GPSDays = val return nil end,
        Hidden = 1,
    },
    [6] = { -- seconds of date/time
        Name = 'GPSDateTime',
        Groups = { [2] = 'Time' },
        -- (10957 days from Jan 1 1970 to Jan 1 2000)
        RawConv = function(self, val)
            return ExifTool.ConvertUnixTime((self.GPSDays + 10957) * 24 * 3600 + val, nil, 3)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [7] = 'GPSDOP',
    [8] = {
        Name = 'GPSMeasureMode', --PH (NC)
        PrintConv = {
            [2] = '2-Dimensional Measurement',
            [3] = '3-Dimensional Measurement',
        },
    },
}

-- GoPro GPRI tags (ref PH) (Karma)
GoPro.GPRI = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [1] = 'GoPro', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Index' },
    [0] = { -- (unit='s')
        Name = 'GPSDateTimeRaw',
        Groups = { [2] = 'Time' },
        ValueConv = function(self, val) return GoPro.ConvertSystemTime(val, self) end, -- convert to date/time based on SystemTime clock
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [1] = { -- (unit='deg')
        Name = 'GPSLatitudeRaw',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [2] = { -- (unit='deg')
        Name = 'GPSLongitudeRaw',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [3] = {
        Name = 'GPSAltitudeRaw', -- (NC)
        PrintConv = function(_self, val) return perlStr(val) .. ' m' end,
    },
    -- (unknown tags must be defined so that ProcessString() will iterate through all values)
    [4] = { Name = 'GPRI_Unknown4', Unknown = 1, Hidden = 1, PrintConv = function(_self, val) return perlStr(val) .. ' m' end },
    [5] = { Name = 'GPRI_Unknown5', Unknown = 1, Hidden = 1, PrintConv = function(_self, val) return perlStr(val) .. ' m' end },
    [6] = 'GPSSpeedRaw', -- (NC) # (unit='m/s' -- should convert to other units?)
    [7] = 'GPSTrackRaw', -- (NC) # (unit='deg')
    [8] = { Name = 'GPRI_Unknown8', Unknown = 1, Hidden = 1 }, -- (no units)
    [9] = { Name = 'GPRI_Unknown9', Unknown = 1, Hidden = 1 }, -- (no units)
}

-- GoPro GLPI tags (ref PH) (Karma)
GoPro.GLPI = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [1] = 'GoPro', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Index' },
    [0] = { -- (unit='s')
        Name = 'GPSDateTime',
        Groups = { [2] = 'Time' },
        ValueConv = function(self, val) return GoPro.ConvertSystemTime(val, self) end, -- convert to date/time based on SystemTime clock
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [1] = { -- (unit='deg')
        Name = 'GPSLatitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [2] = { -- (unit='deg')
        Name = 'GPSLongitude',
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [3] = { -- (unit='m')
        Name = 'GPSAltitude', -- (NC)
        PrintConv = function(_self, val) return perlStr(val) .. ' m' end,
    },
    -- (unknown tags must be defined so that ProcessString() will iterate through all values)
    [4] = { Name = 'GLPI_Unknown4', Unknown = 1, Hidden = 1, PrintConv = function(_self, val) return perlStr(val) .. ' m' end },
    [5] = { Name = 'GPSSpeedX', PrintConv = function(_self, val) return perlStr(val) .. ' m/s' end }, -- (NC)
    [6] = { Name = 'GPSSpeedY', PrintConv = function(_self, val) return perlStr(val) .. ' m/s' end }, -- (NC)
    [7] = { Name = 'GPSSpeedZ', PrintConv = function(_self, val) return perlStr(val) .. ' m/s' end }, -- (NC)
    [8] = { Name = 'GPSTrack' }, -- (unit='deg')
}

-- GoPro KBAT tags (ref PH)
GoPro.KBAT = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [1] = 'GoPro', [2] = 'Camera' },
    VARS = { ID_FMT = 'dec', ID_LABEL = 'Index' },
    NOTES = 'Battery status information found in GoPro Karma videos.',
     [0] = { Name = 'BatteryCurrent',  PrintConv = function(_self, val) return perlStr(val) .. ' A' end },
     [1] = { Name = 'BatteryCapacity', PrintConv = function(_self, val) return perlStr(val) .. ' Ah' end },
     [2] = { Name = 'KBAT_Unknown2',   PrintConv = function(_self, val) return perlStr(val) .. ' J' end, Unknown = 1, Hidden = 1 },
     [3] = { Name = 'BatteryTemperature', PrintConv = function(_self, val) return perlStr(val) .. ' C' end },
     [4] = { Name = 'BatteryVoltage1', PrintConv = function(_self, val) return perlStr(val) .. ' V' end },
     [5] = { Name = 'BatteryVoltage2', PrintConv = function(_self, val) return perlStr(val) .. ' V' end },
     [6] = { Name = 'BatteryVoltage3', PrintConv = function(_self, val) return perlStr(val) .. ' V' end },
     [7] = { Name = 'BatteryVoltage4', PrintConv = function(_self, val) return perlStr(val) .. ' V' end },
     [8] = { Name = 'BatteryTime',     PrintConv = function(_self, val) return ExifTool.ConvertDuration(math.floor(val + 0.5)) end }, -- (NC)
     [9] = { Name = 'KBAT_Unknown9',   PrintConv = function(_self, val) return perlStr(val) .. ' %' end, Unknown = 1, Hidden = 1,  },
    [10] = { Name = 'KBAT_Unknown10',  Unknown = 1, Hidden = 1 }, -- (no units)
    [11] = { Name = 'KBAT_Unknown11',  Unknown = 1, Hidden = 1 }, -- (no units)
    [12] = { Name = 'KBAT_Unknown12',  Unknown = 1, Hidden = 1 }, -- (no units)
    [13] = { Name = 'KBAT_Unknown13',  Unknown = 1, Hidden = 1 }, -- (no units)
    [14] = { Name = 'BatteryLevel',    PrintConv = function(_self, val) return perlStr(val) .. ' %' end },
}

-- GoPro fdsc tags written by the Hero5 and Hero6 (ref PH)
GoPro.fdsc = {
    GROUPS = { [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = [[
        Tags extracted from the MP4 "fdsc" timed metadata when the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded>
        (-ee) option is used.
    ]],
    [0x08] = { Name = 'FirmwareVersion',    Format = 'string[15]' },
    [0x17] = { Name = 'SerialNumber',       Format = 'string[16]' },
    [0x57] = { Name = 'OtherSerialNumber',  Format = 'string[15]' }, -- (NC)
    [0x66] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[16]',
    },
    -- ...
    -- after this there are lots of interesting values also found in the GPMF box,
    -- but this block is lacking tag ID's and any directory structure, so the
    -- value offsets are therefore presumably firmware dependent :(
}

--------------------------------------------------------------------------------
-- Convert system time to date/time string (upstream ConvertSystemTime)
-- Inputs: 0) system time value, 1) ExifTool ref
-- Returns: EXIF-format date/time string with milliseconds
--------------------------------------------------------------------------------
function GoPro.ConvertSystemTime(val, et)
    local s = et.SystemTimeList
    if not s then return '<uncalibrated>' end
    if not et.SystemTimeListSorted then
        tsort(s, function(a, b) return a[1] < b[1] end)
        et.SystemTimeList = s
        et.SystemTimeListSorted = 1
    end
    local i, j = 1, #s
    -- perform binary search to find this system time value
    while j - i > 1 do
        local t = (i + j) // 2
        if val < s[t][1] then j = t else i = t end
    end
    if i == j or s[j][1] == s[i][1] then
        val = s[i][2]
    else
        -- interpolate between values
        val = s[i][2] + (s[j][2] - s[i][2]) * (val - s[i][1]) / (s[j][1] - s[i][1])
    end
    -- (a bit tricky to remove fractional seconds then add them back again after
    --  the date/time conversion while avoiding round-off errors which could
    --  put the seconds out by 1...)
    local t, f = matches(perlStr(val), [[^(\d+)(\.\d+)]])
    if not t then return val end
    return ExifTool.ConvertUnixTime(tonumber(t), et.OPTIONS.QuickTimeUTC) .. f
end

--------------------------------------------------------------------------------
-- Scale values by last 'SCAL' constants
-- Inputs: 0) value or list of values, 1) string of scale factors
-- Returns: updated value or list (upstream updates $_[0] in place; Lua has no
--          output-argument aliasing, so the caller assigns the result)
function GoPro.ScaleValues(val, scl)
    -- upstream: `return unless $val and $scl` (Perl truthiness: '' and 0 too)
    if not (perl.truthy(val) and perl.truthy(scl)) then return val end
    local sclList = {}
    for tok in perlStr(scl):gmatch('[^ \t\n\r\f\v]+') do sclList[#sclList + 1] = tonumber(tok) end
    if sclList[1] == nil then return val end
    local v = type(val) == 'table' and val or { val }
    local scaled = {}
    for i = 1, #v do
        local a = {}
        local j = 0
        for tok in perlStr(v[i]):gmatch('[^ \t\n\r\f\v]+') do
            j = j + 1
            a[j] = ExifTool.NumStr(tonumber(tok) / sclList[((j - 1) % #sclList) + 1])
        end
        scaled[#scaled + 1] = table.concat(a, ' ')
    end
    if #scaled > 1 then return scaled end
    return scaled[1]
end

--------------------------------------------------------------------------------
-- Add units to values for human-readable output
-- Inputs: 0) ExifTool ref, 1) value, 2) tag key
-- Returns: converted value
function GoPro.AddUnits(et, val, tag)
    if et and et.TAG_EXTRA[tag] and perl.truthy(et.TAG_EXTRA[tag].Units) then
        local u = et.TAG_EXTRA[tag].Units
        if type(u) ~= 'table' then u = { u } end
        local a = perl.split(' ', val)
        if #u == #a then
            for i = 1, #a do
                if perl.truthy(u[i]) then a[i] = a[i] .. ' ' .. u[i] end
            end
            val = perl.join(' ', a)
        end
    end
    return val
end


--------------------------------------------------------------------------------
-- Process string of values (or array of strings) to extract as separate tags
-- (upstream ProcessString)
-- Inputs: 0) ExifTool object ref, 1) directory information ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function GoPro.ProcessString(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local list = type(dataPt) == 'table' and dataPt or { dataPt }
    et:VerboseDir('GoPro structure')
    local docNum = et.DOC_NUM
    local subDoc = 0
    for _, str in ipairs(list) do
        local i = 0
        for val in perlStr(str):gmatch('[^ \t\n\r\f\v]+') do
            et:HandleTag(tagTablePtr, i, val)
            i = i + 1
            if tagTablePtr[i] == nil then
                -- increment subdoc for records stored as string of values (eg. GPS5)
                i = 0
                subDoc = subDoc + 1
                et.DOC_NUM = docNum .. '-' .. subDoc
            end
        end
        if i ~= 0 then
            -- increment subdoc for records stored as array of strings (eg. GPS9)
            subDoc = subDoc + 1
            et.DOC_NUM = docNum .. '-' .. subDoc
        end
    end
    et.DOC_NUM = docNum
    return 1
end

--------------------------------------------------------------------------------
-- Process "GP\x06\0" records in MP4 'mdat' atom
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref (RAF and DirLen)
-- Returns: size of GoPro record, or 0 on error
function GoPro.ProcessGP6(et, dirInfo)
    local raf = dirInfo.RAF
    local len = dirInfo.DirLen
    local buff, n
    while len > 16 do
        n, buff = raf:Read(16)
        if n ~= 16 then break end
        local tag, size = unpack('a4N', buff) -- luacheck: ignore 211 (unused upstream as well)
        if size + 16 > len or not isMatch(buff, [[(?s)^GP..\0]]) then break end
        n, buff = raf:Read(size)
        if n ~= size then break end
        if isMatch(buff, [[^DEVC]]) then
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            local tagTbl = et:GetTagTable('lexiftool.GoPro.GPMF')
            GoPro.ProcessGoPro(et, { DataPt = buff, DataPos = raf:Tell() - size }, tagTbl)
        end
        len = len - (size + 16)
    end
    et.DOC_NUM = nil
    return dirInfo.DirLen - len
end

--------------------------------------------------------------------------------
-- Convert a binary tag ID to printable form (upstream
-- Image::ExifTool::QuickTime::PrintableTagID, single-argument form only --
-- the flag variants are only ever passed from QuickTime.pm itself)
function GoPro.PrintableTagID(tag)
    return (tag:gsub('([^-_a-zA-Z0-9])', function(c)
        return 'x' .. string.format('%02x', c:byte())
    end))
end

--------------------------------------------------------------------------------
-- Process GoPro metadata (gpmd samples, GPMF box, or APP6) (ref PH/1/2)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- - with hack to check for encrypted text in gpmd data (Rove Stealth 4K)
function GoPro.ProcessGoPro(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local base = dirInfo.Base
    local pos = dirInfo.DirStart or 0
    local dirEnd = pos + (dirInfo.DirLen or (#dataPt - pos))
    local verbose = et:Options('Verbose')
    local unknown = perl.truthy(verbose) and verbose or et:Options('Unknown')
    local size, fmtCode, unit, scal, setGroup0
    local goproType -- upstream $type ('type' is a Lua builtin)

    if perl.truthy(verbose) then et:VerboseDir(dirInfo.DirName or 'GPMF', nil, dirEnd - pos) end
    et.FoundEmbedded = 1
    -- upstream Perl truthiness: `if ($pos)` -- pos==0 takes the else branch
    if pos ~= 0 then
        local parent = dirInfo.Parent
        if parent and parent == 'APP6' then
            setGroup0 = true
            et.SET_GROUP0 = 'APP6'
        end
    elseif not et.SET_GROUP1 then
        -- set group0 to "QuickTime" unless group1 is being changed (to Track#)
        setGroup0 = true
        et.SET_GROUP0 = 'QuickTime'
    end

    -- upstream: `for (; $pos+8<=$dirEnd; $pos+=($size+3)&0xfffffffc)` -- the
    -- increment runs after every body iteration (including `next`s); the body
    -- itself does `$pos += 8` after reading each header
    while pos + 8 <= dirEnd do
        local tag = dataPt:sub(pos + 1, pos + 4)
        fmtCode = dataPt:byte(pos + 5)
        local len = dataPt:byte(pos + 6)
        local count = dataPt:byte(pos + 7) * 256 + dataPt:byte(pos + 8)
        if tag:match('[^-_a-zA-Z0-9 ]') then
            if tag ~= '\0\0\0\0' then et:Warn('Unrecognized GoPro record') end
            break
        end
        size = len * count
        pos = pos + 8
        if pos + size > dirEnd then
            et:Warn('Truncated GoPro record')
            break
        end
        -- (val/format/extra are declared before the first `goto continue`:
        -- Lua gotos must not jump into the scope of a local declared between
        -- the jump and the label)
        local tagInfo, format, val, extra, key
        tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tag == '\0\0\0\0' then break end -- stop at null tag
        if not (size ~= 0 or verbose) then goto continue end -- don't save empty values unless verbose
        format = goProFmt[fmtCode] or 'undef'
        if fmtCode == 0x3f and goproType then
            -- decode structure with format given by previous 'TYPE'
            local v = {}
            for i = 0, count - 1 do
                local s = {}
                local p = 0
                for j = 1, #goproType do
                    local b = goproType:byte(j)
                    local f = goProFmt[b]
                    if not f then break end
                    local l = goProSize[b] or ExifTool.FormatSize(f)
                    if not l then break end
                    if p + l > len then break end
                    local sv = ExifTool.ReadValue(dataPt, pos + i * len + p, f, nil, l)
                    if sv == nil then break end
                    s[#s + 1] = sv
                    p = p + l
                end
                if s[1] then v[#v + 1] = table.concat(s, ' ') end
            end
            val = #v > 1 and v or v[1]
        elseif (format == 'undef' or format == 'string') and count > 1 and len > 1 then
            -- unpack multiple undef/string values as a list
            local a = {}
            for i = 0, count - 1 do
                local sv = dataPt:sub(pos + i * len + 1, pos + (i + 1) * len)
                if format == 'string' then
                    -- (upstream unpacks 'A' fields, stripping trailing NULs/spaces)
                    sv = sv:gsub('[%z ]+$', '')
                end
                a[i + 1] = sv
            end
            val = a
        else
            val = ExifTool.ReadValue(dataPt, pos, format, nil, size)
        end
        -- save TYPE, UNIT/SIUN and SCAL values for later
        if tag == 'TYPE' then goproType = val end
        if tag == 'UNIT' or tag == 'SIUN' then unit = val end
        if tag == 'SCAL' then scal = val end

        if not tagInfo then
            if not perl.truthy(unknown) then goto continue end
            local name = GoPro.PrintableTagID(tag)
            tagInfo = { Name = 'GoPro_' .. name, Description = 'GoPro ' .. name, Unknown = 1 }
            if fmtCode == 0 then
                tagInfo.SubDirectory = { TagTable = 'lexiftool.GoPro.GPMF' }
            end
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        -- apply scaling if available to last tag in this container
        if scal and tag ~= 'SCAL' and pos + size + 3 >= dirEnd then
            val = GoPro.ScaleValues(val, scal)
        end
        if perl.truthy(verbose) then
            extra = ", type='" .. (fmtCode ~= 0 and string.char(fmtCode) or '\\0') ..
                "' size=" .. len .. ' count=' .. count
        end
        key = et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            DataPos = dirInfo.DataPos,
            Base = base,
            Start = pos,
            Size = size,
            TagInfo = tagInfo,
            Format = format,
            Extra = extra,
        })
        -- save units for adding in print conversion if specified
        if tagInfo.AddUnits and key then
            if not et.TAG_EXTRA[key] then et.TAG_EXTRA[key] = {} end
            et.TAG_EXTRA[key].Units = unit
        end
        ::continue::
        pos = pos + ((size + 3) & ~3)
    end
    if setGroup0 then et.SET_GROUP0 = nil end
    return 1
end

-- (PROCESS_PROC is set here so the tables can reference the function above)
GoPro.GPMF.PROCESS_PROC = GoPro.ProcessGoPro
GoPro.GPS5.PROCESS_PROC = GoPro.ProcessString
GoPro.GPS9.PROCESS_PROC = GoPro.ProcessString
GoPro.GPRI.PROCESS_PROC = GoPro.ProcessString
GoPro.GLPI.PROCESS_PROC = GoPro.ProcessString
GoPro.KBAT.PROCESS_PROC = GoPro.ProcessString

return GoPro
