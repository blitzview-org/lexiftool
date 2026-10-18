--------------------------------------------------------------------------------
-- File:         lexiftool/H264.lua
-- Ported from:  lib/Image/ExifTool/H264.pm
--
-- Description:  Read meta information from H.264 video
--
-- Revisions:    2010/01/31 - P. Harvey Created
--
-- References:   1) http://www.itu.int/rec/T-REC-H.264/e (T-REC-H.264-200305-S!!PDF-E.pdf)
--               2) http://miffteevee.co.uk/documentation/development/H264Parser_8cpp-source.html
--               3) http://ffmpeg.org/
--               4) US Patent 2009/0052875 A1
--               5) European Patent (EP2 051 528A1) application no. 07792522.0 filed 08.08.2007
--               6) Dave Nicholson private communication
--               7) http://www.freepatentsonline.com/20050076039.pdf
--               8) Michael Reitinger private communication (RX100)
--
-- Glossary:     RBSP = Raw Byte Sequence Payload
--
-- Port notes:   Complete port of H264.pm: every table and sub, in upstream
--               order.  The predeclared ProcessSEI is a local at the top;
--               $parsePictureTiming (a test-only switch upstream) is the
--               file-scope `parsePictureTiming`, nil as upstream.  Binary
--               data are strings (upstream: scalar refs).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local substr = perl.substr
local sprintf = perl.sprintf
local unpack = perl.unpack
local tr = perl.tr
local truthy = perl.truthy
local Get8u = ExifTool.Get8u
local GetTagTable = ExifTool.GetTagTable

local H264 = {}

-- (upstream's predeclaration; the sub below assigns to it)
local ProcessSEI

-- luacheck: push ignore 221
local parsePictureTiming -- flag to enable parsing of picture timing information (test only)
-- luacheck: pop

-- lookup for camera manufacturer name
H264.convMake = {
    [0x0103] = 'Panasonic',
    [0x0108] = 'Sony',
    [0x1011] = 'Canon',
    [0x1104] = 'JVC', --Rob Lewis
}

-- information extracted from H.264 video streams
H264.Main = {
    GROUPS = { [2] = 'Video' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Tags extracted from H.264 video streams.  The metadata for AVCHD videos is
        stored in this stream.
    ]],
    ImageWidth = { },
    ImageHeight = { },
    MDPM = { SubDirectory = { TagTable = 'lexiftool.H264.MDPM' } },
}

-- H.264 Supplemental Enhancement Information User Data (ref PH/4)
H264.MDPM = {
    GROUPS = { [2] = 'Camera' },
    PROCESS_PROC = function(...) return ProcessSEI(...) end,
    TAG_PREFIX = 'MDPM',
    NOTES = [[
        The following tags are decoded from the Modified Digital Video Pack Metadata
        (MDPM) of the unregistered user data with UUID
        17ee8c60f84d11d98cd60800200c9a66 in the H.264 Supplemental Enhancement
        Information (SEI).  I<[Yes, this description is confusing, but nothing
        compared to the challenge of actually decoding the data!]>  This information
        may exist at regular intervals through the entire video, but only the first
        occurrence is extracted unless the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option is used (in
        which case subsequent occurrences are extracted as sub-documents).
    ]],
    -- (Note: all these are explained in IEC 61834-4, but it costs money so it is useless to me)
    -- 0x00 - ControlCassetteID (ref 7)
    -- 0x01 - ControlTapeLength (ref 7)
    -- 0x02 - ControlTimerActDate (ref 7)
    -- 0x03 - ControlTimerACS_S_S (ref 7)
    -- 0x04-0x05 - ControlPR_StartPoint (ref 7)
    -- 0x06 - ControlTagIDNoGenre (ref 7)
    -- 0x07 - ControlTopicPageHeader (ref 7)
    -- 0x08 - ControlTextHeader (ref 7)
    -- 0x09 - ControlText (ref 7)
    -- 0x0a-0x0b - ControlTag (ref 7)
    -- 0x0c - ControlTeletextInfo (ref 7)
    -- 0x0d - ControlKey (ref 7)
    -- 0x0e-0x0f - ControlZoneEnd (ref 7)
    -- 0x10 - TitleTotalTime (ref 7)
    -- 0x11 - TitleRemainTime (ref 7)
    -- 0x12 - TitleChapterTotalNo (ref 7)
    [0x13] = {
        Name = 'TimeCode',
        Notes = 'hours:minutes:seconds:frames',
        ValueConv = function(_self, val) return sprintf("%.2x:%.2x:%.2x:%.2x", table.unpack(perl.reverse({ unpack("C*", val) }))) end,
    },
    -- 0x14 - TitleBinaryGroup - val: 0x00000000,0x14200130
    -- 0x15 - TitleCassetteNo (ref 7)
    -- 0x16-0x17 - TitleSoftID (ref 7)
    -- (0x18,0x19 listed as TitleTextHeader/TitleText by ref 7)
    [0x18] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Notes = 'combined with tag 0x19',
        Combine = 1,   -- the next tag (0x19) contains the rest of the date
        -- first byte is timezone information:
        --   0x80 - unused
        --   0x40 - DST flag
        --   0x20 - TimeZoneSign
        --   0x1e - TimeZoneValue
        --   0x01 - half-hour flag
        ValueConv = function(_self, val)
            local a = { unpack('C*', val) }
            local tz = table.remove(a, 1)
            return sprintf('%.2x%.2x:%.2x:%.2x %.2x:%.2x:%.2x%s%.2d:%s%s', a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                           tz & 0x20 ~= 0 and '-' or '+', (tz >> 1) & 0x0f,
                           tz & 0x01 ~= 0 and '30' or '00',
                           tz & 0x40 ~= 0 and ' DST' or '')
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- 0x1a-0x1b - TitleStart (ref 7)
    -- 0x1c-0x1d - TitleReelID (ref 7)
    -- 0x1e-0x1f - TitleEnd (ref 7)
    -- 0x20 - ChapterTotalTime (ref 7)
    -- 0x42 - ProgramRecDTime (ref 7)
    -- 0x50/0x60 - (AAUX/VAUX)Source (ref 7)
    -- 0x51/0x61 - (AAUX/VAUX)SourceControl (ref 7)
    -- 0x52/0x62 - (AAUX/VAUX)RecDate (ref 7)
    -- 0x53/0x63 - (AAUX/VAUX)RecTime (ref 7)
    -- 0x54/0x64 - (AAUX/VAUX)BinaryGroup (ref 7)
    -- 0x55/0x65 - (AAUX/VAUX)ClosedCaption (ref 7)
    -- 0x56/0x66 - (AAUX/VAUX)TR (ref 7)
    [0x70] = { -- ConsumerCamera1
        Name = 'Camera1',
        SubDirectory = { TagTable = 'lexiftool.H264.Camera1' },
    },
    [0x71] = { -- ConsumerCamera2
        Name = 'Camera2',
        SubDirectory = { TagTable = 'lexiftool.H264.Camera2' },
    },
    -- 0x73 Lens - val: 0x04ffffd3,0x0effffd3,0x15ffffd3,0x41ffffd3,0x52ffffd3,0x59ffffd3,0x65ffffd3,0x71ffffd3,0x75ffffd3,0x79ffffd3,0x7fffffd3,0xffffffd3...
    -- 0x74 Gain - val: 0xb8ffff0f
    -- 0x75 Pedestal
    -- 0x76 Gamma
    -- 0x77 Detail
    -- 0x7b CameraPreset
    -- 0x7c Flare
    -- 0x7d Shading
    -- 0x7e Knee
    [0x7f] = { -- Shutter
        Name = 'Shutter',
        SubDirectory = {
            TagTable = 'lexiftool.H264.Shutter',
            ByteOrder = 'LittleEndian', -- weird
        },
    },
    [0xa0] = {
        Name = 'ExposureTime',
        Format = 'rational32u',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
    [0xa1] = {
        Name = 'FNumber',
        Format = 'rational32u',
        Groups = { [2] = 'Image' },
    },
    [0xa2] = {
        Name = 'ExposureProgram',
        Format = 'int32u', -- (guess)
        PrintConv = {
            [0] = 'Not Defined',
            [1] = 'Manual',
            [2] = 'Program AE',
            [3] = 'Aperture-priority AE',
            [4] = 'Shutter speed priority AE',
            [5] = 'Creative (Slow speed)',
            [6] = 'Action (High speed)',
            [7] = 'Portrait',
            [8] = 'Landscape',
        },
    },
    [0xa3] = {
        Name = 'BrightnessValue',
        Format = 'rational32s',
        Groups = { [2] = 'Image' },
    },
    [0xa4] = {
        Name = 'ExposureCompensation',
        Format = 'rational32s',
        Groups = { [2] = 'Image' },
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintFraction(val) end,
    },
    [0xa5] = {
        Name = 'MaxApertureValue',
        Format = 'rational32u',
        ValueConv = function(_self, val) return 2 ^ (val / 2) end,
        PrintConv = function(_self, val) return sprintf("%.1f", val) end,
    },
    [0xa6] = {
        Name = 'Flash',
        Format = 'int32u', -- (guess)
        Flags = 'PrintHex',
        SeparateTable = 'EXIF Flash',
        PrintConv =  require('lexiftool.Exif').flash,
    },
    [0xa7] = {
        Name = 'CustomRendered',
        Format = 'int32u', -- (guess)
        Groups = { [2] = 'Image' },
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Custom',
        },
    },
    [0xa8] = {
        Name = 'WhiteBalance',
        Format = 'int32u', -- (guess)
        Priority = 0,
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
        },
    },
    [0xa9] = {
        Name = 'FocalLengthIn35mmFormat',
        Format = 'rational32u',
        PrintConv = function(_self, val) return perl.str(val) .. " mm" end,
    },
    [0xaa] = {
        Name = 'SceneCaptureType',
        Format = 'int32u', -- (guess)
        PrintConv = {
            [0] = 'Standard',
            [1] = 'Landscape',
            [2] = 'Portrait',
            [3] = 'Night',
        },
    },
    -- 0xab-0xaf ExifOption
    [0xb0] = {
        Name = 'GPSVersionID',
        Format = 'int8u',
        Count = 4,
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = function(_self, val) val = tr(val, ' ', '.') return val end,
    },
    [0xb1] = {
        Name = 'GPSLatitudeRef',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            N = 'North',
            S = 'South',
        },
    },
    [0xb2] = {
        Name = 'GPSLatitude',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        Notes = 'combined with tags 0xb3 and 0xb4',
        Combine = 2,   -- combine the next 2 tags (0xb2=deg, 0xb3=min, 0xb4=sec)
        ValueConv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val) end,
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1) end,
    },
    [0xb5] = {
        Name = 'GPSLongitudeRef',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            E = 'East',
            W = 'West',
        },
    },
    [0xb6] = {
        Name = 'GPSLongitude',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        Combine = 2,   -- combine the next 2 tags (0xb6=deg, 0xb7=min, 0xb8=sec)
        Notes = 'combined with tags 0xb7 and 0xb8',
        ValueConv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val) end,
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1) end,
    },
    [0xb9] = {
        Name = 'GPSAltitudeRef',
        Format = 'int32u', -- (guess)
        Groups = { [1] = 'GPS', [2] = 'Location' },
        ValueConv = function(_self, val) return truthy(val) and 1 or 0 end, -- because I'm not sure about the Format
        PrintConv = {
            [0] = 'Above Sea Level',
            [1] = 'Below Sea Level',
        },
    },
    [0xba] = {
        Name = 'GPSAltitude',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0xbb] = {
        Name = 'GPSTimeStamp',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Time' },
        Combine = 2,    -- the next tags (0xbc/0xbd) contain the minutes/seconds
        Notes = 'combined with tags 0xbc and 0xbd',
        ValueConv = function(_self, val) return require('lexiftool.GPS').ConvertTimeStamp(val) end,
        PrintConv = function(_self, val) return require('lexiftool.GPS').PrintTimeStamp(val) end,
    },
    [0xbe] = {
        Name = 'GPSStatus',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            A = 'Measurement Active',
            V = 'Measurement Void',
        },
    },
    [0xbf] = {
        Name = 'GPSMeasureMode',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            [2] = '2-Dimensional Measurement',
            [3] = '3-Dimensional Measurement',
        },
    },
    [0xc0] = {
        Name = 'GPSDOP',
        Description = 'GPS Dilution Of Precision',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0xc1] = {
        Name = 'GPSSpeedRef',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            K = 'km/h',
            M = 'mph',
            N = 'knots',
        },
    },
    [0xc2] = {
        Name = 'GPSSpeed',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0xc3] = {
        Name = 'GPSTrackRef',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0xc4] = {
        Name = 'GPSTrack',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0xc5] = {
        Name = 'GPSImgDirectionRef',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0xc6] = {
        Name = 'GPSImgDirection',
        Format = 'rational32u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0xc7] = {
        Name = 'GPSMapDatum',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        Combine = 1,    -- the next tag (0xc8) contains the rest of the string
        Notes = 'combined with tag 0xc8',
    },
    -- 0xc9-0xcf - GPSOption
    -- 0xc9 - val: 0x001d0203
    [0xca] = { --PH (Sony DSC-HX7V)
        Name = 'GPSDateStamp',
        Format = 'string',
        Groups = { [1] = 'GPS', [2] = 'Time' },
        Combine = 2,    -- the next 2 tags contain the rest of the string
        Notes = 'combined with tags 0xcb and 0xcc',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
    },
    [0xe0] = {
        Name = 'MakeModel',
        SubDirectory = { TagTable = 'lexiftool.H264.MakeModel' },
    },
    -- 0xe1-0xef - MakerOption
    -- 0xe1 - val: 0x01000670,0x01000678,0x06ffffff,0x01ffffff,0x01000020,0x01000400...
    [0xe1] = { --6
        Name = 'RecInfo',
        Condition = function(self) return self.Make == "Canon" end,
        Notes = 'Canon only',
        SubDirectory = { TagTable = 'lexiftool.H264.RecInfo' },
    },
    -- 0xe2-0xe8 - val: 0x00000000 in many samples
    -- 0xe2 - val: 0x00000000,0x01000000,0x01010000,0x8080900c,0x8080a074
    -- 0xe3 - val: 0x00801f89,0x00801f8b,0x00c01f89,0xc9c01f80
    [0xe4] = { --PH
        Name = 'Model',
        Condition = function(self) return self.Make == "Sony" end, -- (possibly also Canon models?)
        Description = 'Camera Model Name',
        Notes = 'Sony only, combined with tags 0xe5 and 0xe6',
        Format = 'string',
        Combine = 2, -- (not sure about 0xe6, but include it just in case)
        RawConv = function(_self, val) if val == "" then return nil end return val end,
    },
    -- 0xeb - val: 0x008a0a00,0x0a300000,0x508a0a00,0x52880a00,0x528a0a00
    -- 0xec - val: 0x0b700000
    -- 0xed - val: 0x0ce0f819
    [0xee] = { --6 (HFS200)
        Name = 'FrameInfo',
        Condition = function(self) return self.Make == "Canon" end,
        Notes = 'Canon only',
        SubDirectory = { TagTable = 'lexiftool.H264.FrameInfo' },
    },
    -- 0xef - val: 0x01c00000,0x0e00000c
}

-- ConsumerCamera1 information (ref PH)
H264.Camera1 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Camera' },
    TAG_PREFIX = 'Camera1',
    PRINT_CONV = function(_self, val) return sprintf("0x%.2x", val) end,
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'ApertureSetting',
        PrintHex = 1,
        PrintConv = {
            [0xff] = 'Auto',
            [0xfe] = 'Closed',
            OTHER = function(val) return sprintf('%.1f', 2 ^ ((val & 0x3f) / 8)) end,
        },
    },
    [1] = {
        Name = 'Gain',
        Mask = 0x0f,
        -- (0x0f would translate to 42 dB, but this value is used by the Sony
        --  HXR-NX5U for any out-of-range value such as -6 dB or "hyper gain" - PH)
        ValueConv = function(_self, val) return (val - 1) * 3 end,
        PrintConv = function(_self, val) if val == 42 then return "Out of range" end return perl.str(val) .. " dB" end,
    },
    [1.1] = {
        Name = 'ExposureProgram',
        Mask = 0xf0,
        ValueConv = function(_self, val) if val == 15 then return nil end return val end,
        PrintConv = {
            [0] = 'Program AE',
            [1] = 'Gain', --?
            [2] = 'Shutter speed priority AE',
            [3] = 'Aperture-priority AE',
            [4] = 'Manual',
        },
    },
    [2.1] = {
        Name = 'WhiteBalance',
        Mask = 0xe0,
        ValueConv = function(_self, val) if val == 7 then return nil end return val end,
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Hold',
            [2] = '1-Push',
            [3] = 'Daylight',
        },
    },
    [3] = {
        Name = 'Focus',
        ValueConv = function(_self, val) if val == 0xff then return nil end return val end,
        PrintConv = function(_self, val)
            local foc = (val & 0x7e) / ((val & 0x01 ~= 0) and 40 or 400)
            return ((val & 0x80 ~= 0 and 'Manual' or 'Auto') .. " (" .. perl.str(foc) .. ")")
        end,
    },
}

-- ConsumerCamera2 information (ref PH)
H264.Camera2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Camera' },
    TAG_PREFIX = 'Camera2',
    PRINT_CONV = function(_self, val) return sprintf("0x%.2x", val) end,
    FIRST_ENTRY = 0,
    [1] = {
        Name = 'ImageStabilization',
        PrintHex = 1,
        PrintConv = {
            [0] = 'Off',
            [0x3f] = 'On (0x3f)', --8
            [0xbf] = 'Off (0xbf)', --8
            [0xff] = 'n/a',
            OTHER = function(val)
                return sprintf("%s (0x%.2x)", val & 0x10 ~= 0 and "On" or "Off", val)
            end,
        },
    },
}

-- camera info 0x7f (ref PH)
H264.Shutter = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    TAG_PREFIX = 'Shutter',
    PRINT_CONV = function(_self, val) return sprintf("0x%.2x", val) end,
    FIRST_ENTRY = 0,
    FORMAT = 'int16u',
    [1.1] = { --6
        Name = 'ExposureTime',
        Mask = 0x7fff, -- (what is bit 0x8000 for?)
        RawConv = function(_self, val) if val == 0x7fff then return nil end return val end, --7
        ValueConv = function(_self, val) return val / 28125 end, --PH (Vixia HF G30, ref forum5588) (was $val/33640 until 9.49)
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
}

-- camera info 0xe0 (ref PH)
H264.MakeModel = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Camera' },
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'Make',
        PrintHex = 1,
        RawConv = function(self, val) self.Make = (H264.convMake[val] or "Unknown") return val end,
        PrintConv = H264.convMake,
    },
    -- 1 => ModelIDCode according to ref 4/5 (I think not - PH)
    -- 1 => { Name => 'ModelIDCode', PrintConv => 'sprintf("%.4x",$val)' },
    -- vals: 0x0313 - various Pansonic HDC models
    --       0x0345 - Panasonic HC-V7272
    --       0x0414 - Panasonic AG-AF100
    --       0x0591 - various Panasonic DMC models
    --       0x0802 - Panasonic DMC-TZ60 with GPS information off
    --       0x0803 - Panasonic DMC-TZ60 with GPS information on
    --       0x3001 - various Sony DSC, HDR, NEX and SLT models
    --       0x3003 - various Sony DSC models
    --       0x3100 - various Sony DSC, ILCE, NEX and SLT models
    --       0x1000 - Sony HDR-UX1
    --       0x2000 - Canon HF100 (60i)
    --       0x3000 - Canon HF100 (30p)
    --       0x3101 - Canon HFM300 (PH, all qualities and frame rates)
    --       0x3102 - Canon HFS200
    --       0x4300 - Canon HFG30
}

-- camera info 0xe1 (ref 6)
H264.RecInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Camera' },
    FORMAT = 'int8u',
    NOTES = 'Recording information stored by some Canon video cameras.',
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'RecordingMode',
        PrintConv = {
            [0x02] = 'XP+', -- High Quality 12 Mbps
            [0x04] = 'SP',  -- Standard Play 7 Mbps
            [0x05] = 'LP',  -- Long Play 5 Mbps
            [0x06] = 'FXP', -- High Quality 17 Mbps
            [0x07] = 'MXP', -- High Quality 24 Mbps
        },
    },
}

-- camera info 0xee (ref 6)
H264.FrameInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int8u',
    NOTES = 'Frame rate information stored by some Canon video cameras.',
    FIRST_ENTRY = 0,
    [0] = 'CaptureFrameRate',
    [1] = 'VideoFrameRate',
    -- 2 - 8=60i, 10=PF30, 74=PF24 (PH, HFM300)
}

--==============================================================================
-- Bitstream functions (used for H264 video)
--
-- Member variables:
--   Mask    = mask for next bit to read (0 when all data has been read)
--   Pos     = byte offset of next word to read
--   Word    = current data word
--   Len     = total data length in bytes
--   DataPt  = data pointer
--..............................................................................

--==============================================================================
-- Bitstream functions (used for H264 video)
--
-- Member variables:
--   Mask    = mask for next bit to read (0 when all data has been read)
--   Pos     = byte offset of next word to read
--   Word    = current data word
--   Len     = total data length in bytes
--   DataPt  = data pointer
--..............................................................................

--------------------------------------------------------------------------------
-- Read next word from bitstream
-- Inputs: 0) BitStream ref
-- Returns: true if there is more data (and updates
--          Mask, Pos and Word for first bit in next word)
local function ReadNextWord(bstr)
    local pos = bstr.Pos
    if pos + 4 <= bstr.Len then
        bstr.Word = bstr.DataPt:byte(pos + 1) * 0x1000000 +
            bstr.DataPt:byte(pos + 2) * 0x10000 +
            bstr.DataPt:byte(pos + 3) * 0x100 +
            bstr.DataPt:byte(pos + 4)
        bstr.Mask = 0x80000000
        bstr.Pos = pos + 4
    elseif pos < bstr.Len then
        local word = bstr.DataPt:byte(pos + 1)
        local mask = 0x80
        local i = pos + 2
        while i <= bstr.Len do
            word = word * 0x100 + bstr.DataPt:byte(i)
            mask = mask * 0x100
            i = i + 1
        end
        bstr.Word = word
        bstr.Mask = mask
        bstr.Pos = bstr.Len
    else
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- Create a new BitStream object
-- Inputs: 0) data string
-- Returns: BitStream ref, or nil if data is empty
local function NewBitStream(data)
    local bstr = {
        DataPt = data,
        Len = #data,
        Pos = 0,
        Mask = 0,
    }
    if not ReadNextWord(bstr) then return nil end
    return bstr
end

--------------------------------------------------------------------------------
-- Get number of bits remaining in bit stream
-- Inputs: 0) BitStream ref
-- Returns: number of bits remaining
local function BitsLeft(bstr)
    local bits = 0
    local mask = bstr.Mask
    while mask ~= 0 do
        bits = bits + 1
        mask = mask >> 1
    end
    return bits + 8 * (bstr.Len - bstr.Pos)
end
H264.BitsLeft = BitsLeft

--------------------------------------------------------------------------------
-- Get integer from bitstream
-- Inputs: 0) BitStream ref, 1) number of bits
-- Returns: integer (and increments position in bitstream)
local function GetIntN(bstr, nbits)
    local val = 0
    while nbits > 0 do
        nbits = nbits - 1
        val = val << 1
        if bstr.Mask & bstr.Word ~= 0 then val = val + 1 end
        if bstr.Mask >> 1 ~= 0 then
            bstr.Mask = bstr.Mask >> 1
        elseif not ReadNextWord(bstr) then
            break
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Get Exp-Golomb integer from bitstream
-- Inputs: 0) BitStream ref
-- Returns: integer (and increments position in bitstream)
local function GetGolomb(bstr)
    -- first, count the number of zero bits to get the integer bit width
    local count = 0
    while bstr.Mask & bstr.Word == 0 do
        count = count + 1
        if bstr.Mask >> 1 ~= 0 then
            bstr.Mask = bstr.Mask >> 1
        elseif not ReadNextWord(bstr) then
            break
        end
    end
    -- then return the adjusted integer
    return GetIntN(bstr, count + 1) - 1
end

--------------------------------------------------------------------------------
-- Get signed Exp-Golomb integer from bitstream
-- Inputs: 0) BitStream ref
-- Returns: integer (and increments position in bitstream)
local function GetGolombS(bstr)
    local val = GetGolomb(bstr) + 1
    if val & 1 ~= 0 then
        return -((val >> 1))
    end
    return val >> 1
end

-- end bitstream functions
--==============================================================================

--------------------------------------------------------------------------------
-- Decode H.264 scaling matrices
-- Inputs: 0) BitStream ref
-- Reference: http://ffmpeg.org/
local function DecodeScalingMatrices(bstr)
    if GetIntN(bstr, 1) ~= 0 then
        for i = 0, 7 do
            local size = i < 6 and 16 or 64
            if GetIntN(bstr, 1) ~= 0 then
                local last, next_ = 8, 8
                for j = 0, size - 1 do
                    if next_ ~= 0 then next_ = (last + GetGolombS(bstr)) & 0xff end
                    if not (j ~= 0 or next_ ~= 0) then break end
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Parse H.264 sequence parameter set RBSP (ref 1)
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) data ref
-- Notes: All this just to get the image size!
local function ParseSeqParamSet(et, tagTablePtr, dataPt)
    -- initialize our bitstream object
    local bstr = NewBitStream(dataPt)
    if not bstr then return end
    local t, n
    -- the messy nature of H.264 encoding makes it difficult to use
    -- data-driven structure parsing, so I code it explicitly (yuck!)
    t = GetIntN(bstr, 8)            -- profile_idc
    GetIntN(bstr, 16)               -- constraints and level_idc
    GetGolomb(bstr)                 -- seq_parameter_set_id
    if t >= 100 then -- (ref b)
        t = GetGolomb(bstr)         -- chroma_format_idc
        if t == 3 then
            GetIntN(bstr, 1)        -- separate_colour_plane_flag
            n = 12  -- luacheck: ignore 311
        else
            n = 8   -- luacheck: ignore 311
        end
        GetGolomb(bstr)             -- bit_depth_luma_minus8
        GetGolomb(bstr)             -- bit_depth_chroma_minus8
        GetIntN(bstr, 1)            -- qpprime_y_zero_transform_bypass_flag
        DecodeScalingMatrices(bstr)
    end
    GetGolomb(bstr)                 -- log2_max_frame_num_minus4
    t = GetGolomb(bstr)             -- pic_order_cnt_type
    if t == 0 then
        GetGolomb(bstr)             -- log2_max_pic_order_cnt_lsb_minus4
    elseif t == 1 then
        GetIntN(bstr, 1)            -- delta_pic_order_always_zero_flag
        GetGolomb(bstr)             -- offset_for_non_ref_pic
        GetGolomb(bstr)             -- offset_for_top_to_bottom_field
        n = GetGolomb(bstr)         -- num_ref_frames_in_pic_order_cnt_cycle
        for _ = 0, n - 1 do
            GetGolomb(bstr)         -- offset_for_ref_frame[i]
        end
    end
    GetGolomb(bstr)                 -- num_ref_frames
    GetIntN(bstr, 1)                -- gaps_in_frame_num_value_allowed_flag
    local w = GetGolomb(bstr)       -- pic_width_in_mbs_minus1
    local h = GetGolomb(bstr)       -- pic_height_in_map_units_minus1
    local f = GetIntN(bstr, 1)      -- frame_mbs_only_flag
    if f == 0 then GetIntN(bstr, 1) end -- mb_adaptive_frame_field_flag
    GetIntN(bstr, 1)                -- direct_8x8_inference_flag
    -- convert image size to pixels
    w = (w + 1) * 16
    h = (2 - f) * (h + 1) * 16
    -- account for cropping (if any)
    t = GetIntN(bstr, 1)            -- frame_cropping_flag
    if t ~= 0 then
        local m = 4 - f * 2
        w = w -  4 * GetGolomb(bstr)-- frame_crop_left_offset
        w = w -  4 * GetGolomb(bstr)-- frame_crop_right_offset
        h = h - m * GetGolomb(bstr) -- frame_crop_top_offset
        h = h - m * GetGolomb(bstr) -- frame_crop_bottom_offset
    end
    -- quick validity checks (just in case)
    if bstr.Mask == 0 then return end
    if w >= 160 and w <= 4096 and h >= 120 and h <= 3072 then
        et:HandleTag(tagTablePtr, 'ImageWidth', w)
        et:HandleTag(tagTablePtr, 'ImageHeight', h)
        -- (whew! -- so much work just to get ImageSize!!)
    end
    -- return now unless interested in picture timing information
    if not parsePictureTiming then return end

    -- parse vui parameters if they exist
    if GetIntN(bstr, 1) == 0 then return end -- vui_parameters_present_flag
    t = GetIntN(bstr, 1)            -- aspect_ratio_info_present_flag
    if t ~= 0 then
        t = GetIntN(bstr, 8)        -- aspect_ratio_idc
        if t == 255 then            -- Extended_SAR ?
            GetIntN(bstr, 32)       -- sar_width/sar_height
        end
    end
    t = GetIntN(bstr, 1)            -- overscan_info_present_flag
    if t ~= 0 then GetIntN(bstr, 1) end -- overscan_appropriate_flag
    t = GetIntN(bstr, 1)            -- video_signal_type_present_flag
    if t ~= 0 then
        GetIntN(bstr, 4)            -- video_format/video_full_range_flag
        t = GetIntN(bstr, 1)        -- colour_description_present_flag
        if t ~= 0 then GetIntN(bstr, 24) end -- colour_primaries/transfer_characteristics/matrix_coefficients
    end
    t = GetIntN(bstr, 1)            -- chroma_loc_info_present_flag
    if t ~= 0 then
        GetGolomb(bstr)             -- chroma_sample_loc_type_top_field
        GetGolomb(bstr)             -- chroma_sample_loc_type_bottom_field
    end
    t = GetIntN(bstr, 1)            -- timing_info_present_flag
    if t ~= 0 then
        if BitsLeft(bstr) < 65 then return end
        et.VUI_units = GetIntN(bstr, 32) -- num_units_in_tick
        et.VUI_scale = GetIntN(bstr, 32) -- time_scale
        GetIntN(bstr, 1)            -- fixed_frame_rate_flag
    end
    local hard
    for _ = 0, 1 do
        t = GetIntN(bstr, 1)        -- nal_/vcl_hrd_parameters_present_flag
        if t ~= 0 then
            et.VUI_hard = 1
            hard = 1
            n = GetGolomb(bstr)     -- cpb_cnt_minus1
            GetIntN(bstr, 8)        -- bit_rate_scale/cpb_size_scale
            for _ = 0, n do
                GetGolomb(bstr)     -- bit_rate_value_minus1[SchedSelIdx]
                GetGolomb(bstr)     -- cpb_size_value_minus1[SchedSelIdx]
                GetIntN(bstr, 1)    -- cbr_flag[SchedSelIdx]
            end
            GetIntN(bstr, 5)        -- initial_cpb_removal_delay_length_minus1
            et.VUI_clen = GetIntN(bstr, 5) -- cpb_removal_delay_length_minus1
            et.VUI_dlen = GetIntN(bstr, 5) -- dpb_output_delay_length_minus1
            et.VUI_toff = GetIntN(bstr, 5) -- time_offset_length
        end
    end
    if hard then GetIntN(bstr, 1) end -- low_delay_hrd_flag
    et.VUI_pic = GetIntN(bstr, 1)   -- pic_struct_present_flag
    -- (don't yet decode the rest of the vui data)
end
H264.ParseSeqParamSet = ParseSeqParamSet

--------------------------------------------------------------------------------
-- Parse H.264 picture timing SEI message (payload type 1) (ref 1)
-- Inputs: 0) ExifTool ref, 1) data ref
-- Notes: this routine is for test purposes only, and not called unless the
--        $parsePictureTiming flag is set
-- luacheck: push ignore 311 231
local function ParsePictureTiming(et, dataPt)
    local bstr = NewBitStream(dataPt)
    if not bstr then return end
    local t, n
    -- the specification is very odd on this point: the following delays
    -- exist if the VUI hardware parameters are present, or if
    -- "determined by the application, by some means not specified" -- WTF??
    if truthy(et.VUI_hard) then
        GetIntN(bstr, et.VUI_clen + 1)  -- cpb_removal_delay
        GetIntN(bstr, et.VUI_dlen + 1)  -- dpb_output_delay
    end
    if truthy(et.VUI_pic) then
        t = GetIntN(bstr, 4)        -- pic_struct
        -- determine NumClockTS ($n)
        n = ({ [0]=1, [1]=1, [2]=1, [3]=2, [4]=2, [5]=3, [6]=3, [7]=2, [8]=3 })[t]
        if not n then return end
        for _ = 0, n - 1 do
            t = GetIntN(bstr, 1)    -- clock_timestamp_flag[i]
            if t ~= 0 then
                local nu, s, m, h, o
                GetIntN(bstr, 2)        -- ct_type
                nu = GetIntN(bstr, 1)   -- nuit_field_based_flag
                GetIntN(bstr, 5)        -- counting_type
                t = GetIntN(bstr, 1)    -- full_timestamp_flag
                GetIntN(bstr, 1)        -- discontinuity_flag
                GetIntN(bstr, 1)        -- cnt_dropped_flag
                GetIntN(bstr, 8)        -- n_frames
                if t ~= 0 then
                    s = GetIntN(bstr, 6) -- seconds_value
                    m = GetIntN(bstr, 6) -- minutes_value
                    h = GetIntN(bstr, 5) -- hours_value
                else
                    t = GetIntN(bstr, 1) -- seconds_flag
                    if t ~= 0 then
                        s = GetIntN(bstr, 6) -- seconds_value
                        t = GetIntN(bstr, 1) -- minutes_flag
                        if t ~= 0 then
                            m = GetIntN(bstr, 6) -- minutes_value
                            t = GetIntN(bstr, 1) -- hours_flag
                            if t ~= 0 then h = GetIntN(bstr, 5) end -- hours_value
                        end
                    end
                end
                if truthy(et.VUI_toff) then
                    o = GetIntN(bstr, et.VUI_toff) -- time_offset
                end
                break   -- only parse the first clock timestamp found
            end
        end
    end
end
-- luacheck: pop
H264.ParsePictureTiming = ParsePictureTiming

--------------------------------------------------------------------------------
-- Process H.264 Supplementary Enhancement Information (ref 1/PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 if we processed payload type 5
-- Payload types:
--   0 - buffer period
--   1 - pic timing
--   2 - pan scan rect
--   3 - filler payload
--   4 - user data registered itu t t35
--   5 - user data unregistered
--   6 - recovery point
--   7 - dec ref pic marking repetition
--   8 - spare pic
--   9 - sene info
--  10 - sub seq info
--  11 - sub seq layer characteristics
--  12 - sub seq characteristics
--  13 - full frame freeze
--  14 - full frame freeze release
--  15 - full frame snapshot
--  16 - progressive refinement segment start
--  17 - progressive refinement segment end
--  18 - motion constrained slice group set
function ProcessSEI(et, dirInfo)
    local dataPt = dirInfo.DataPt
    local end_ = #dataPt
    local pos = 0
    local type_, size, index, t

    -- scan through SEI payload for type 5 (the unregistered user data)
    while true do
        type_ = 0
        while true do
            if pos >= end_ then return 0 end
            t = Get8u(dataPt, pos)  -- payload type
            pos = pos + 1
            type_ = type_ + t
            if t ~= 255 then break end
        end
        if type_ == 0x80 then return 0 end -- terminator (ref PH - maybe byte alignment bits?)
        size = 0
        while true do
            if pos >= end_ then return 0 end
            t = Get8u(dataPt, pos)  -- payload data length
            pos = pos + 1
            size = size + t
            if t ~= 255 then break end
        end
        if pos + size > end_ then return 0 end
        et:VPrint(1, "    (SEI type " .. type_ .. ")\n")
        if type_ == 1 then                  -- picture timing information
            if parsePictureTiming then
                local buff = substr(dataPt, pos, size) -- luacheck: ignore 211
                ParsePictureTiming(et, dataPt)
            end
        elseif type_ == 5 then              -- unregistered user data
            break -- exit loop to process user data now
        end
        pos = pos + size
    end

    -- look for our 16-byte UUID
    -- - plus "MDPM" for "ModifiedDVPackMeta"
    -- - plus "GA94" for closed-caption data (currently not decoded)
    if not (size > 20 and substr(dataPt, pos, 20) ==
        "\x17\xee\x8c\x60\xf8\x4d\x11\xd9\x8c\xd6\x08\0\x20\x0c\x9a\x66MDPM") then return 0 end
--
-- parse the MDPM records in the UUID 17ee8c60f84d11d98cd60800200c9a66
-- unregistered user data payload (ref PH)
--
    local tagTablePtr = GetTagTable(nil, 'lexiftool.H264.MDPM')
    local oldIndent = et.INDENT
    et.INDENT = et.INDENT .. '| '
    end_ = pos + size   -- end of payload
    pos = pos + 20      -- skip UUID + "MDPM"
    local num = Get8u(dataPt, pos)  -- get entry count
    pos = pos + 1
    local lastTag = 0
    if truthy(et:Options('Verbose')) then et:VerboseDir('MDPM', num) end
    -- walk through entries in the MDPM payload
    index = 0
    while index < num and pos < end_ do
        local tag = Get8u(dataPt, pos)
        if tag <= lastTag then -- should be in numerical order (PH)
            et:Warn('Entries in MDPM directory are out of sequence')
            break
        end
        lastTag = tag
        local buff = substr(dataPt, pos + 1, 4)
        local from
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo then
            -- use our own print conversion for Unknown tags
            if tagInfo.Unknown and not tagInfo.SetPrintConv then
                tagInfo.PrintConv = function(_self, val) return sprintf("0x%.8x", unpack("N", val)) end
                tagInfo.SetPrintConv = 1
            end
            -- combine with next value(s) if necessary
            local combine = tagTablePtr[tag].Combine
            while truthy(combine) do
                if pos + 5 >= end_ then break end
                local t2 =  Get8u(dataPt, pos + 5)
                if t2 ~= lastTag + 1 then break end -- must be consecutive tag ID's
                pos = pos + 5
                buff = buff .. substr(dataPt, pos + 1, 4)
                if from == nil then from = index end
                index = index + 1
                lastTag = lastTag + 1
                combine = combine - 1
            end
            et:HandleTag(tagTablePtr, tag, nil, {
                TagInfo = tagInfo,
                DataPt  = buff,
                Size    = #buff,
                Index   = from ~= nil and from .. "-" .. index or index,
            })
        end
        pos = pos + 5
        index = index + 1
    end
    et.INDENT = oldIndent
    return 1
end
H264.ProcessSEI = ProcessSEI

--------------------------------------------------------------------------------
-- Extract information from H.264 video stream
-- Inputs: 0) ExifTool ref, 1) data ref
-- Returns: 0 = done parsing, 1 = we want to parse more of these
function H264.ParseH264Video(et, dataPt)
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout
    local tagTablePtr = GetTagTable(nil, 'lexiftool.H264.Main')
    local parseNalUnit = { [0x06] = 1, [0x07] = 1 }   -- NAL unit types to parse
    local foundUserData
    local len = #dataPt
    local pos = 0
    local gpos = 0  -- (pos($$dataPt))
    while pos < len do
        local nextPos, end_
        -- find start of next NAL unit
        local m1, e = matches(dataPt, [[(\0{2,3}\x01)]], gpos)
        if e ~= nil then
            gpos = e
            nextPos = gpos
            end_ = nextPos - #m1
            if pos == 0 then pos = nextPos goto next_ end
        else
            gpos = 0
            if pos == 0 then break end
            nextPos, end_ = len, len
        end
        if pos >= len then break end
        do
            -- parse NAL unit from $pos to $end
            local nal_unit_type = Get8u(dataPt, pos)
            pos = pos + 1
            -- check forbidden_zero_bit
            if nal_unit_type & 0x80 ~= 0 then et:Warn('H264 forbidden bit error') break end
            nal_unit_type = nal_unit_type & 0x1f
            -- ignore this NAL unit unless we will parse it
            if not (parseNalUnit[nal_unit_type] or truthy(verbose)) then pos = nextPos goto next_ end
            -- read NAL unit (and convert all 0x000003's to 0x0000 as per spec.)
            local buff = ''
            gpos = pos + 1
            while true do
                local _, e2 = matches(dataPt, [[\0\0\x03]], gpos)
                if e2 == nil then break end
                gpos = e2
                if gpos > end_ then break end
                buff = buff .. substr(dataPt, pos, gpos - 1 - pos)
                pos = gpos
            end
            buff = buff .. substr(dataPt, pos, end_ - pos)
            if (verbose or 0) > 1 then
                out:write(sprintf("  NAL Unit Type: 0x%x (%d bytes)\n", nal_unit_type, #buff))
                et:VerboseDump(buff)
            end
            pos = nextPos
            gpos = pos

            if nal_unit_type == 0x06 then       -- sei_rbsp (supplemental enhancement info)

                if truthy(et.GotNAL06) then
                    -- process only the first SEI unless ExtractEmbedded is set
                    if not truthy(et:Options('ExtractEmbedded')) then goto next_ end
                    et.DOC_NUM = et.GotNAL06
                end
                foundUserData = ProcessSEI(et, { DataPt = buff })
                et.DOC_NUM = nil
                -- keep parsing SEI's until we find the user data
                if not truthy(foundUserData) then goto next_ end
                et.GotNAL06 = (et.GotNAL06 or 0) + 1

            elseif nal_unit_type == 0x07 then   -- sequence_parameter_set_rbsp

                -- process this NAL unit type only once
                if truthy(et.GotNAL07) then goto next_ end
                et.GotNAL07 = 1
                ParseSeqParamSet(et, tagTablePtr, buff)
            end
            -- we were successful, so don't parse this NAL unit type again
            parseNalUnit[nal_unit_type] = nil
        end
        ::next_::
    end
    -- parse one extra H264 frame if we didn't find the user data in this one
    -- (Panasonic cameras don't put the SEI in the first frame)
    if truthy(foundUserData) or truthy(et.ParsedH264) then return 0 end
    et.ParsedH264 = 1
    return 1
end

return H264
