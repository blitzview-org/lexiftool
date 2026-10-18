--------------------------------------------------------------------------------
-- File:         lexiftool/Samsung.lua
-- Ported from:  lib/Image/ExifTool/Samsung.pm
--
-- Description:  Samsung EXIF maker notes tags
--
-- Revisions:    2010/03/01 - P. Harvey Created
--
-- References:   1) Tae-Sun Park private communication
--               2) http://www.cybercom.net/~dcoffin/dcraw/
--               3) Pascal de Bruijn private communication (NX100)
--               4) Jaroslav Stepanek via rt.cpan.org
--               5) Nick Livchits private communication
--               6) Sreerag Raghavan private communication (SM-C200)
--               IB) Iliah Borg private communication (LibRaw)
--               NJ) Niels Kristian Bech Jensen private communication
--
-- Port notes:   read-only port.  All 23 upstream tag tables are carried, in
--               upstream's order (`Main`, `IFD`, `Type2`, `OrientationInfo`,
--               `PictureWizard`, `INFO`, `MP4`, `Thumbnail`, `sec`, `smta`,
--               `svss`, `Thumbnail2`, `APP5`, `Trailer`, `DualShotExtra`,
--               `SingleShotMeta`, `ReEditData`, `ClipInfo`, `ToneInfo`,
--               `EffectInfo`, `PortraitEffect`, `PEgInfo`, `Composite`), as
--               are `samsungLensTypes`/`formatMinMax` and the procs `Crypt`,
--               `ProcessINFO`, `ProcessSamsungMeta`, `ProcessSamsungIFD` and
--               `ProcessSamsung` (the SEFT trailer reader).
--               `WriteSTMN` is ported (Main's WRITE_PROC); deferred: the
--               HTML_DUMP branch of `ProcessSamsungIFD`.
--               `WriteExif` is reached through a wrapper instead of a
--               top-level require: requiring it here pulls in nearly every
--               vendor module, and `BuildCompositeTags` derives its worklist
--               from `package.loaded` (see the note there), so an eager
--               require changes Composite build order for every file.
--------------------------------------------------------------------------------

-- luacheck: ignore 421 313 512
--   (421: the nested `for index` loops and the inner `blockType` re-declare
--    the upstream loop variables; 313: the `blockEnd` update mirrors the
--    upstream `$blockEnd -= $len + 8`; 512: the single-iteration block-scan
--    `while` loop mirrors the upstream `last`-controlled loop)

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local length = perl.length
local RandomAccess = require('lexiftool.RandomAccess')
local substr = perl.substr
local sprintf = perl.sprintf
local str = perl.str
local JSON = require('lexiftool.JSON')  -- (upstream `use Image::ExifTool::JSON`)
local carray = require('carray')

local Samsung = {}

-- Samsung LensType lookup
local samsungLensTypes = {
    -- (added "Samsung NX" in all of these lens names - ref 4)
    [0] = 'Built-in or Manual Lens', -- #PH (EX1, WB2000)
    [1] = 'Samsung NX 30mm F2 Pancake',
    [2] = 'Samsung NX 18-55mm F3.5-5.6 OIS', -- (also version II, ref 1)
    [3] = 'Samsung NX 50-200mm F4-5.6 ED OIS',
    -- what about the non-OIS version of the 18-55,
    -- which was supposed to be available before the 20-50? - PH
    [4] = 'Samsung NX 20-50mm F3.5-5.6 ED', -- #PH/4
    [5] = 'Samsung NX 20mm F2.8 Pancake', -- #PH
    [6] = 'Samsung NX 18-200mm F3.5-6.3 ED OIS', -- #4
    [7] = 'Samsung NX 60mm F2.8 Macro ED OIS SSA', -- #1
    [8] = 'Samsung NX 16mm F2.4 Pancake', -- #1/4
    [9] = 'Samsung NX 85mm F1.4 ED SSA', -- #4
    [10] = 'Samsung NX 45mm F1.8', -- #3
    [11] = 'Samsung NX 45mm F1.8 2D/3D', -- #3
    [12] = 'Samsung NX 12-24mm F4-5.6 ED', -- #4
    [13] = 'Samsung NX 16-50mm F2-2.8 S ED OIS', -- #forum3833
    [14] = 'Samsung NX 10mm F3.5 Fisheye', -- #NJ
    [15] = 'Samsung NX 16-50mm F3.5-5.6 Power Zoom ED OIS', -- #5
    [20] = 'Samsung NX 50-150mm F2.8 S ED OIS', -- #PH
    [21] = 'Samsung NX 300mm F2.8 ED OIS', -- #IB
}
Samsung.samsungLensTypes = samsungLensTypes

-- range of values for Formats used in encrypted information
local formatMinMax = {
    int16u = { 0, 65535 },
    int32u = { 0, 4294967295 },
    int16s = { -32768, 32767 },
    int32s = { -2147483648, 2147483647 },
}


-- Samsung "STMN" maker notes (ref PH)
Samsung.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = false, -- predeclaration, see below for implementation
    CHECK_PROC = false, -- predeclaration: Writer.CheckBinaryData (set below)
    WRITABLE = 1,
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    IS_OFFSET = { 2 }, -- tag 2 is 'IsOffset'
    IS_SUBDIR = { 11 },
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    NOTES = [[
        Tags found in the binary "STMN" format maker notes written by a number of
        Samsung models.
    ]],
    [0] = {
        Name = 'MakerNoteVersion',
        Format = 'undef[8]',
    },
    [2] = {
        Name = 'PreviewImageStart',
        OffsetPair = 3, -- associated byte count tagID
        DataTag = 'PreviewImage',
        IsOffset = 3,
        Protected = 2,
        WriteGroup = 'MakerNotes',
    },
    [3] = {
        Name = 'PreviewImageLength',
        OffsetPair = 2, -- point to associated offset
        DataTag = 'PreviewImage',
        Protected = 2,
        WriteGroup = 'MakerNotes',
    },
    [11] = {
        Name = 'SamsungIFD',
        -- Note: this is not always an IFD.  In many models the string
        -- "Park Byeongchan" is found at this location
        Condition = function(_self, valPt) return perl.matches(valPt or '', '^[^\\0]\\0\\0\\0') ~= nil end,
        Format = 'undef[$size - 44]',
        SubDirectory = { TagTable = 'lexiftool.Samsung.IFD' },
    },
}

Samsung.IFD = {
    PROCESS_PROC = false, -- predeclaration: Samsung.ProcessSamsungIFD (set below)
    NOTES = [[
        This is a standard-format IFD found in the maker notes of some Samsung
        models, except that the entry count is a 4-byte integer and the offsets are
        relative to the end of the IFD.  Currently, no tags in this IFD are known,
        so the L<Unknown|../ExifTool.html#Unknown> (-u) or L<Verbose|../ExifTool.html#Verbose> (-v) option must be used to see this
        information.
    ]],
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    -- 0x0001 - undef[4000|4100]: starts with "MN_PRV" (or all zeros)
    -- 0x0002 - undef[7000]     : starts with "Kim Miae"
    -- 0x0003 - undef[5000]     : starts with "Lee BK"
    -- 0x0004 - undef[500|2000] : starts with "IPCD"   (or all zeros)
    -- 0x0006 - undef[100|200]  : starts with "MN_ADS" (or all zeros)
}

-- Samsung maker notes (ref PH)
Samsung.Type2 = {
    WRITE_PROC = false, -- predeclaration: WriteExif.WriteExif (set below)
    CHECK_PROC = false, -- predeclaration: WriteExif.CheckExif (set below)
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    NOTES = 'Tags found in the EXIF-format maker notes of newer Samsung models.',
    [0x0001] = {
        Name = 'MakerNoteVersion',
        Writable = 'undef',
        Count = 4,
    },
    [0x0002] = {
        Name = 'DeviceType',
        Groups = { [2] = 'Camera' },
        Writable = 'int32u',
        PrintHex = 1,
        PrintConv = {
            [0x1000] = 'Compact Digital Camera',
            [0x2000] = 'High-end NX Camera',
            [0x3000] = 'HXM Video Camera',
            [0x12000] = 'Cell Phone',
            [0x300000] = 'SMX Video Camera',
        },
    },
    [0x0003] = {
        Name = 'SamsungModelID',
        Groups = { [2] = 'Camera' },
        Writable = 'int32u',
        PrintHex = 1,
        PrintConv = {
            [0x100101c] = 'NX10',
            -- (upstream Samsung.pm:160/161 and :163/164 each list the same ID
            --  twice -- Perl and a Lua table constructor both keep the last)
            -- luacheck: push ignore 314
            [0x1001226] = 'HMX-S10BP',
            [0x1001226] = 'HMX-S15BP',
            [0x1001233] = 'HMX-Q10',
            [0x1001234] = 'HMX-H300',
            [0x1001234] = 'HMX-H304',
            -- luacheck: pop
            [0x100130c] = 'NX100',
            [0x1001327] = 'NX11',
            [0x170104b] = 'ES65, ES67 / VLUU ES65, ES67 / SL50',
            [0x170104e] = 'ES70, ES71 / VLUU ES70, ES71 / SL600',
            [0x1701052] = 'ES73 / VLUU ES73 / SL605',
            [0x1701055] = 'ES25, ES27 / VLUU ES25, ES27 / SL45',
            [0x1701300] = 'ES28 / VLUU ES28',
            [0x1701303] = 'ES74,ES75,ES78 / VLUU ES75,ES78',
            [0x2001046] = 'PL150 / VLUU PL150 / TL210 / PL151',
            [0x2001048] = 'PL100 / TL205 / VLUU PL100 / PL101',
            [0x2001311] = 'PL120,PL121 / VLUU PL120,PL121',
            [0x2001315] = 'PL170,PL171 / VLUUPL170,PL171',
            [0x200131e] = 'PL210, PL211 / VLUU PL210, PL211',
            [0x2701317] = 'PL20,PL21 / VLUU PL20,PL21',
            [0x2a0001b] = 'WP10 / VLUU WP10 / AQ100',
            [0x3000000] = 'Various Models (0x3000000)',
           --0x3000000 => 'DV150F / DV151F / DV155F',
           --0x3000000 => 'NX mini',
           --0x3000000 => 'NX3000',
           --0x3000000 => 'NX3300',
           --0x3000000 => 'ST150F / ST151F / ST152F',
           --0x3000000 => 'WB200F / WB201F / WB202F',
           --0x3000000 => 'WB250F / WB251F / WB252F',
           --0x3000000 => 'WB30F / WB31F / WB32F',
           --0x3000000 => 'WB350F / WB351F / WB352F',
           --0x3000000 => 'WB800F',
            [0x3a00018] = 'Various Models (0x3a00018)',
           --0x3a00018 => 'ES30 / VLUU ES30',
           --0x3a00018 => 'ES80 / ES81',
           --0x3a00018 => 'ES9 / ES8',
           --0x3a00018 => 'PL200 / VLUU PL200',
           --0x3a00018 => 'PL80 / VLUU PL80 / SL630 / PL81',
           --0x3a00018 => 'PL90 / VLUU PL90',
           --0x3a00018 => 'WB1100F / WB1101F / WB1102F',
           --0x3a00018 => 'WB2200F',
            [0x400101f] = 'ST1000 / ST1100 / VLUU ST1000 / CL65',
            [0x4001022] = 'ST550 / VLUU ST550 / TL225',
            [0x4001025] = 'Various Models (0x4001025)',
           --0x4001025 => 'DV300 / DV300F / DV305F',
           --0x4001025 => 'ST500 / VLUU ST500 / TL220',
           --0x4001025 => 'ST200 / ST200F / ST201 / ST201F / ST205F',
            [0x400103e] = 'VLUU ST5500, ST5500, CL80',
            [0x4001041] = 'VLUU ST5000, ST5000, TL240',
            [0x4001043] = 'ST70 / VLUU ST70 / ST71',
            [0x400130a] = 'Various Models (0x400130a)',
           --0x400130a => 'VLUU ST100, ST100',
           --0x400130a => 'VLUU ST600, ST600',
           --0x400130a => 'VLUU ST80, ST80',
            [0x400130e] = 'ST90,ST91 / VLUU ST90,ST91',
            [0x4001313] = 'VLUU ST95, ST95',
            [0x4a00015] = 'VLUU ST60',
            [0x4a0135b] = 'ST30, ST65 / VLUU ST65 / ST67',
            [0x5000000] = 'Various Models (0x5000000)',
           --0x5000000 => 'EX2F',
           --0x5000000 => 'NX1000',
           --0x5000000 => 'NX20',
           --0x5000000 => 'NX200',
           --0x5000000 => 'NX210',
           --0x5000000 => 'ST96',
           --0x5000000 => 'WB750',
           --0x5000000 => 'ST700',
            [0x5001038] = 'Various Models (0x5001038)',
           --0x5001038 => 'EK-GN120',
           --0x5001038 => 'HMX-E10',
           --0x5001038 => 'NX1',
           --0x5001038 => 'NX2000',
           --0x5001038 => 'NX30',
           --0x5001038 => 'NX300',
           --0x5001038 => 'NX500',
           --0x5001038 => 'SM-C200',
           --0x5001038 => 'WB2000',
            [0x500103a] = 'WB650 / VLUU WB650 / WB660',
            [0x500103c] = 'WB600 / VLUU WB600 / WB610',
            [0x500133e] = 'WB150 / WB150F / WB152 / WB152F / WB151',
            [0x5a0000f] = 'WB5000 / HZ25W',
            [0x5a0001e] = 'WB5500 / VLUU WB5500 / HZ50W',
            [0x6001036] = 'EX1',
            [0x700131c] = 'VLUU SH100, SH100',
            [0x27127002] = 'SMX-C20N',
        },
    },
    -- 0x0004 - undef[x] (SamsungContentsID?)
    -- 0x000a - int32u (ContinuousShotMode?)
    -- 0x000b - int16u (BestPhotoMode?)
    -- 0x000c - int32u ? values: 0,1
    -- 0x000e - int32u[2] (SoundMultiPicture?)
    -- 0x0010 - rational64u ? values: undef,inf
    [0x0011] = { --6
        Name = 'OrientationInfo',
        SubDirectory = { TagTable = 'lexiftool.Samsung.OrientationInfo' },
    },
    [0x0020] = { { --forum7685
        Name = 'SmartAlbumColor',
        Condition = function(_self, valPt) return perl.matches(valPt or '', '^\\0{4}') ~= nil end,
        Writable = 'int16u',
        Count = 2,
        PrintConv = {
            ['0 0'] = 'n/a',
        },
    }, {
        Name = 'SmartAlbumColor',
        Writable = 'int16u',
        Count = 2,
        PrintConv = { {
            [0] = 'Red',
            [1] = 'Yellow',
            [2] = 'Green',
            [3] = 'Blue',
            [4] = 'Magenta',
            [5] = 'Black',
            [6] = 'White',
            [7] = 'Various',
        } },
    } },
    [0x0021] = { --1
        Name = 'PictureWizard',
        Writable = 'int16u',
        SubDirectory = { TagTable = 'lexiftool.Samsung.PictureWizard' },
    },
    -- 0x0022 - int32u (CaptureMode?) (Gamma? eg. 65538 = 1.2, ref forum7720)
    -- 0x0023 - string: "0123456789" (PH) (placeholder for SerialNumber?)
    -- 0x0025 - int32u (ImageCount?)
    -- 0x002a - undef[4] (SNSDirectShare?)
    -- 0x002f - string (GPSInfo01?)
    [0x0030] = { --1 (NX100 with GPS)
        Name = 'LocalLocationName',
        Groups = { [2] = 'Location' },
        Writable = 'string',
        Format = 'undef',
        -- this contains 2 place names (in Korean if in Korea), separated by a null+space
        -- - terminate at double-null and replace nulls with newlines
        ValueConv = function(_self, val)
            val = perl.subst(str(val), '\\0\\0.*', '')
            return perl.subst(val, '\\0 *', '\\n', 'g')
        end,
        ValueConvInv = function(_self, val)
            return perl.subst(str(val), '(\\x0d\\x0a|\\x0d|\\x0a)', '\\0 ', 'g') .. '\\0\\0'
        end,
    },
    [0x0031] = { --1 (NX100 with GPS)
        Name = 'LocationName',
        Groups = { [2] = 'Location' },
        Writable = 'string',
    },
    -- 0x0032 - string (GPSInfo03)
    -- 0x0033 - string (GPSInfo04)
    -- 0x0034 - string (GPSInfo05)
    [0x0035] = { {
        Name = 'PreviewIFD',
        Condition = function(self) return self.TIFF_TYPE == 'SRW' and self.Model ~= 'EK-GN120' end, -- (not an IFD in JPEG images)
        Groups = { [1] = 'PreviewIFD' },
        Flags = 'SubIFD',
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.PreviewIFD',
            ByteOrder = 'Unknown',
            Start = function(_self, val, _start) return val end,
        },
    }, {
        Name = 'PreviewIFD',
        Condition = function(self) return self.TIFF_TYPE == 'SRW' end, -- (not an IFD in JPEG images)
        Groups = { [1] = 'PreviewIFD' },
        Flags = 'SubIFD',
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.PreviewIFD',
            ByteOrder = 'Unknown',
            Start = function(_self, val, _start) return val - 36 end,
        },
    } },
    -- 0x003a - int16u[2] (SmartLensInfo?)
    -- 0x003b - int16u[2] (PhotoStyleSelectInfo?)
    -- 0x003c - int16u (SmartRange?)
    -- 0x003d - int16u[5] (SmartCropInfo?)
    -- 0x003e - int32u (DualCapture?)
    -- 0x003f - int16u[2] (SGIFInfo?)
    [0x0040] = { --forum7432
        Name = 'RawDataByteOrder',
        PrintConv = {
            [0] = 'Little-endian (Intel, II)',
            [1] = 'Big-endian (Motorola, MM)', --(NC)
        },
    },
    [0x0041] = { --forum7684
        Name = 'WhiteBalanceSetup',
        Writable = 'int32u',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
        },
    },
    [0x0043] = { --1 (NC)
        Name = 'CameraTemperature',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64s',
        -- (DPreview samples all 0.2 C --> pre-production model)
        PrintConv = function(_self, val) return perl.matches(str(val), '\\d') and (val .. ' C') or val end,
        PrintConvInv = function(_self, val) return perl.subst(str(val), ' ?C', '') end,
    },
    -- 0x0045 => { Name => 'RawCompressionMode', Writable => 'int32u' }, # (related to ExposureMode, not raw compresison? ref forum7432)
    -- 0x004a - int32u[7] (ImageVerification?)
    -- 0x004b - int32u[2] (RewindInfo?)
    -- 0x0050 - int32u (ColorSpace? - inconsistent) values: 1 (related to compression mode, ref forum7432)
    [0x0050] = { --forum7432
        Name = 'RawDataCFAPattern',
        PrintConv = {
            [0] = 'Unchanged',
            [1] = 'Swap',
            [65535] = 'Roll',
        },
    },
    -- 0x0054 - int16u[2] (WeatherInfo?)
    -- 0x0060 - undef (AEInfo?)
    -- 0x0080 - undef (AFInfo?)
    -- 0x00a0 - undef[8192] (AWBInfo1): white balance information (ref 1):
    --   At byte 5788, the WBAdjust: "Adjust\0\X\0\Y\0\Z\xee\xea\xce\xab", where
    --   Y = BA adjust (0=Blue7, 7=0, 14=Amber7), Z = MG (0=Magenta7, 7=0, 14=Green7)
    -- 0x00a1 - undef (AWBInfo2?)
    -- 0x00c0 - undef (IPCInfo?)
    -- 0x00c7 - undef (SmartFunctionInfo?)
    -- 0x00e0 - int16u (SceneResult?)
    -- 0x00e1 - int16u[8] (SADebugInfo01?)
    -- 0x00e1 - int16u[x] (SADebugInfo02?)
    [0x0100] = {
        Name = 'FaceDetect',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' }, --(NC)
    },
    -- 0x0101 - int16u[6] (FaceDetectInfo?)
    -- 0x0102 - int16u[x] (FaceDetectInfo?)
    [0x0120] = {
        Name = 'FaceRecognition',
        Writable = 'int32u',
        PrintConv = { [0] = 'Off', [1] = 'On' }, --(NC)
    },
    [0x0123] = { Name = 'FaceName', Writable = 'string' },
    -- 0x140 - undef (LensInfo?)
--
-- the following tags found only in SRW images
--
    -- 0xa000 - rational64u: 1 or 1.1 (ref PH) (MakerNoteVersion?)
    [0xa001] = { --1
        Name = 'FirmwareName',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
    },
    [0xa002] = { --PH/IB
        Name = 'SerialNumber',
        Condition = function(_self, valPt) return perl.matches(valPt or '', '^\\w{5}') ~= nil end, -- should be at least 5 characters long
        Groups = { [2] = 'Camera' },
        Writable = 'string',
    },
    [0xa003] = { --1 (SRW images only)
        Name = 'LensType',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        Count = -1,
        PrintConv = { samsungLensTypes },
    },
    [0xa004] = { --1
        Name = 'LensFirmware',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
    },
    [0xa005] = {
        Name = 'InternalLensSerialNumber', -- Not the printed serial number (ref 1)
        Groups = { [2] = 'Camera' },
        Writable = 'string',
    },
    [0xa010] = { --1
        Name = 'SensorAreas',
        Groups = { [2] = 'Camera' },
        Notes = 'full and valid sensor areas',
        Writable = 'int32u',
        Count = 8,
    },
    [0xa011] = { --1
        Name = 'ColorSpace',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'sRGB',
            [1] = 'Adobe RGB',
        },
    },
    [0xa012] = { --1
        Name = 'SmartRange',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0xa013] = { --1
        Name = 'ExposureCompensation',
        Writable = 'rational64s',
    },
    [0xa014] = { --1
        Name = 'ISO',
        Writable = 'int32u',
    },
    [0xa018] = { --1
        Name = 'ExposureTime',
        Writable = 'rational64u',
        ValueConv = function(_self, val) return perl.subst(str(val), ' .*', '') end, -- some models write 2 values here
        ValueConvInv = function(_self, val) return val end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0xa019] = { --1
        Name = 'FNumber',
        Priority = 0,
        Writable = 'rational64u',
        ValueConv = function(_self, val) return perl.subst(str(val), ' .*', '') end, -- some models write 2 values here
        ValueConvInv = function(_self, val) return val end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0xa01a] = { --1
        Name = 'FocalLengthIn35mmFormat',
        Groups = { [2] = 'Camera' },
        Priority = 0,
        Format = 'int32u',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
        PrintConv = function(_self, val) return perl.str(val) .. ' mm' end,
        PrintConvInv = function(_self, val) return perl.subst(str(val), '\\s*mm$', '') end,
    },
    -- 0xa01b - int32u (ImageCount?)
    -- 0xa01b - int16u (LDCLens?)
    [0xa020] = { --1
        Name = 'EncryptionKey',
        Writable = 'int32u',
        Count = 11,
        Protected = 1,
        DataMember = 'EncryptionKey',
        RawConv = function(self, val) self.EncryptionKey = perl.split(' ', str(val)) return val end,
        Notes = 'key used to decrypt the tags below',
        -- value is "305 72 737 456 282 307 519 724 13 505 193"
    },
    [0xa021] = { --1
        Name = 'WB_RGGBLevelsUncorrected',
        Writable = 'int32u',
        Count = 4,
        Notes = 'these tags not corrected for WB_RGGBLevelsBlack',
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
    },
    [0xa022] = { --1
        Name = 'WB_RGGBLevelsAuto',
        Writable = 'int32u',
        Count = 4,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -4) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 4) end,
    },
    [0xa023] = { --1
        Name = 'WB_RGGBLevelsIlluminator1',
        Writable = 'int32u',
        Count = 4,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -8) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 8) end,
    },
    [0xa024] = { --1
        Name = 'WB_RGGBLevelsIlluminator2',
        Writable = 'int32u',
        Count = 4,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -1) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 1) end,
    },
    -- (upstream Samsung.pm:523/529 lists 0xa025 twice -- see above)
    -- luacheck: push ignore 314
    [0xa025] = { -- (PostAEGain?)
        Name = 'DigitalGain', --IB
        Writable = 'int32u',
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 6) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -6) end,
    },
    [0xa025] = { --IB
        -- luacheck: pop
        Name = 'HighlightLinearityLimit',
        Writable = 'int32u',
    },
    [0xa028] = { --2/PH
        Name = 'WB_RGGBLevelsBlack',
        Writable = 'int32s',
        Count = 4,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
    },
    [0xa030] = { --1
        Name = 'ColorMatrix',
        Writable = 'int32s',
        Count = 9,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
    },
    [0xa031] = { --1
        Name = 'ColorMatrixSRGB',
        Writable = 'int32s',
        Count = 9,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
    },
    [0xa032] = { --1
        Name = 'ColorMatrixAdobeRGB',
        Writable = 'int32s',
        Count = 9,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
    },
    [0xa033] = { --1
        Name = 'CbCrMatrixDefault',
        Writable = 'int32s',
        Count = 4,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
    },
    [0xa034] = { --1
        Name = 'CbCrMatrix',
        Writable = 'int32s',
        Count = 4,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 4) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -4) end,
    },
    [0xa035] = { --1
        Name = 'CbCrGainDefault',
        Writable = 'int32u',
        Count = 2,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
    },
    [0xa036] = { --1
        Name = 'CbCrGain',
        Writable = 'int32u',
        Count = 2,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -2) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 2) end,
    },
    [0xa040] = { --1
        Name = 'ToneCurveSRGBDefault',
        Writable = 'int32u',
        Count = 23,
        Notes = [[
            first value gives the number of tone curve entries.  This is followed by an
            array of X coordinates then an array of Y coordinates
        ]],
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa041] = { --1
        Name = 'ToneCurveAdobeRGBDefault',
        Writable = 'int32u',
        Count = 23,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa042] = { --1
        Name = 'ToneCurveSRGB',
        Writable = 'int32u',
        Count = 23,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa043] = { --1
        Name = 'ToneCurveAdobeRGB',
        Writable = 'int32u',
        Count = 23,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa048] = { --1
        Name = 'RawData',
        Unknown = 1,
        Writable = 'int32s',
        Count = 12,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
    },
    [0xa050] = { --1
        Name = 'Distortion',
        Unknown = 1,
        Writable = 'int32s',
        Count = 8,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0') end,
    },
    [0xa051] = { --1
        Name = 'ChromaticAberration',
        Unknown = 1,
        Writable = 'int16u',
        Count = 22,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', -7, -3) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, 7, 3) end,
    },
    [0xa052] = { --1
        Name = 'Vignetting',
        Unknown = 1,
        Writable = 'int16u',
        Count = 15,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa053] = { --1
        Name = 'VignettingCorrection',
        Unknown = 1,
        Writable = 'int16u',
        Count = 15,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa054] = { --1
        Name = 'VignettingSetting',
        Unknown = 1,
        Writable = 'int16u',
        Count = 15,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 0, '-0') end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, '-0', 0) end,
    },
    [0xa055] = { --1
        Name = 'Samsung_Type2_0xa055', -- (DistortionCamera1st?)
        Unknown = 1,
        Hidden = 1,
        Writable = 'int32s',
        Count = 8,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 8) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -8) end,
    },
    [0xa056] = { --1
        Name = 'Samsung_Type2_0xa056', -- (DistortionCamera2nd?)
        Unknown = 1,
        Hidden = 1,
        Writable = 'int32s',
        Count = 8,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 5) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -5) end,
    },
    [0xa057] = { --1
        Name = 'Samsung_Type2_0xa057', -- (DistortionCameraSetting?)
        Unknown = 1,
        Hidden = 1,
        Writable = 'int32s',
        Count = 8,
        RawConv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, 2) end,
        RawConvInv = function(self, val, tagInfo) return Samsung.Crypt(self, val, tagInfo, -2) end,
    },
    -- 0xa060 - rational64u (CISTemperature?)
    -- 0xa061 - int16u (Compression?)
}

-- orientation information (ref 6)
Samsung.OrientationInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = false, -- predeclaration: Writer.WriteBinaryData (set below)
    CHECK_PROC = false, -- predeclaration: Writer.CheckBinaryData (set below)
    WRITABLE = 1,
    FORMAT = 'rational64s',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Camera orientation information written by the Gear 360 (SM-C200).',
    [0] = {
        Name = 'YawAngle', --(NC)
        Unknown = 1,
        Notes = 'always zero',
    },
    [1] = {
        Name = 'PitchAngle',
        Notes = 'upward tilt of rear camera in degrees',
    },
    [2] = {
        Name = 'RollAngle',
        Notes = 'clockwise rotation of rear camera in degrees',
    },
}

-- Picture Wizard information (ref 1)
Samsung.PictureWizard = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = false, -- predeclaration: Writer.WriteBinaryData (set below)
    CHECK_PROC = false, -- predeclaration: Writer.CheckBinaryData (set below)
    WRITABLE = 1,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'PictureWizardMode',
        PrintConvColumns = 3,
        PrintConv = { --3
             [0] = 'Standard',
             [1] = 'Vivid',
             [2] = 'Portrait',
             [3] = 'Landscape',
             [4] = 'Forest',
             [5] = 'Retro',
             [6] = 'Cool',
             [7] = 'Calm',
             [8] = 'Classic',
             [9] = 'Custom1',
            [10] = 'Custom2',
            [11] = 'Custom3',
           [255] = 'n/a', --PH
        },
    },
    [1] = 'PictureWizardColor',
    [2] = {
        Name = 'PictureWizardSaturation',
        ValueConv = function(_self, val) return val - 4 end,
        ValueConvInv = function(_self, val) return val + 4 end,
    },
    [3] = {
        Name = 'PictureWizardSharpness',
        ValueConv = function(_self, val) return val - 4 end,
        ValueConvInv = function(_self, val) return val + 4 end,
    },
    [4] = {
        Name = 'PictureWizardContrast',
        ValueConv = function(_self, val) return val - 4 end,
        ValueConvInv = function(_self, val) return val + 4 end,
    },
}

-- INFO tags in Samsung MP4 videos (ref PH)
Samsung.INFO = {
    PROCESS_PROC = false, -- predeclaration: Samsung.ProcessINFO (set below)
    GROUPS = { [0] = 'MakerNotes', [2] = 'Video' },
    NOTES = [[
        This information is found in MP4 videos from Samsung models such as the
        SMX-C20N.
    ]],
    EFCT = 'Effect', -- (guess)
    QLTY = 'Quality',
    -- MDEL - value: 0
    -- ASPT - value: 1, 2
}

-- Samsung MP4 TAGS information (PH - from WP10 sample)
-- --> very similar to Sanyo MP4 information
Samsung.MP4 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        This information is found in Samsung MP4 videos from models such as the
        WP10.
    ]],
    [0x00] = {
        Name = 'Make',
        Format = 'string[24]',
        PrintConv = function(_self, val)
            local XMP = require('lexiftool.XMP')
            return XMP.ucfirst(XMP.lc(val))
        end,
    },
    [0x18] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[16]',
    },
    [0x2e] = { --(NC)
        Name = 'ExposureTime',
        Format = 'int32u',
        ValueConv = function(_self, val) return ExifTool.perlTruthy(val) and 10 / val or 0 end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
    [0x32] = {
        Name = 'FNumber',
        Format = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x3a] = { --(NC)
        Name = 'ExposureCompensation',
        Format = 'rational64s',
        PrintConv = function(_self, val) return ExifTool.perlTruthy(val) and sprintf('%+.1f', val) or 0 end,
    },
    [0x6a] = {
        Name = 'ISO',
        Format = 'int32u',
    },
    [0x7d] = {
        Name = 'Software',
        Format = 'string[32]',
        -- (these tags are not at a constant offset for Olympus/Sanyo videos,
        --  so just to be safe use this to validate subsequent tags)
        RawConv = function(self, val)
            if not perl.matches(str(val), '^SAMSUNG') then return nil end
            self.SamsungMP4 = 1
            return val
        end,
    },
    [0xf4] = {
        Name = 'Thumbnail',
        Condition = function(self) return ExifTool.perlTruthy(self.SamsungMP4) end,
        SubDirectory = {
            TagTable = 'lexiftool.Samsung.Thumbnail',
            Base = function(_self, _val, start) return start end,
        },
    },
}

-- thumbnail image information found in MP4 videos (similar in Olympus,Samsung,Sanyo)
Samsung.Thumbnail = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    FORMAT = 'int32u',
    [1] = 'ThumbnailWidth',
    [2] = 'ThumbnailHeight',
    [3] = 'ThumbnailLength',
    [4] = { Name = 'ThumbnailOffset', IsOffset = 1 },
}

-- Samsung MP4 @sec information (PH - from WB30F sample)
Samsung.sec = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        This information is found in the @sec atom of Samsung MP4 videos from models
        such as the WB30F.
    ]],
    [0x00] = {
        Name = 'Make',
        Format = 'string[32]',
        PrintConv = function(_self, val)
            local XMP = require('lexiftool.XMP')
            return XMP.ucfirst(XMP.lc(val))
        end,
    },
    [0x20] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[32]',
    },
    [0x200] = { Name = 'ThumbnailWidth',  Format = 'int32u' },
    [0x204] = { Name = 'ThumbnailHeight', Format = 'int32u' },
    [0x208] = { Name = 'ThumbnailLength', Format = 'int32u' }, -- (2 bytes too long in my sample)
    [0x20c] = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef[$val{0x208}]',
        Notes = 'the THM image, embedded metadata is extracted as the first sub-document',
        SetBase = 1,
        RawConv = function(self, val, tag)
            local pt = self:ValidateImage(val, tag)
            if pt then
                self.BASE = (self.BASE or 0) + 0x20c
                self.DOC_COUNT = (self.DOC_COUNT or 0) + 1
                self.DOC_NUM = self.DOC_COUNT
                self:ExtractInfo(pt, { ReEntry = 1 })
                self.DOC_NUM = 0
            end
            return pt
        end,
    },
}

-- Samsung MP4 smta information (PH - from SM-C101 sample)
Samsung.smta = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Video' },
    NOTES = [[
        This information is found in the smta atom of Samsung MP4 videos from models
        such as the Galaxy S4.
    ]],
    svss = {
        Name = 'SamsungSvss',
        SubDirectory = { TagTable = 'lexiftool.Samsung.svss' },
    },
    mdln = 'SamsungModel', --PH (Samsung SM-A136U, etc)
    -- swtr - 4 bytes, all zero
    -- scid - 8 bytes, all zero
    -- saut - 4 or 6 bytes, all zero
}

-- Samsung MP4 svss information (PH - from SM-C101 sample)
Samsung.svss = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Video' },
    NOTES = [[
        This information is found in the svss atom of Samsung MP4 videos from models
        such as the Galaxy S4.
    ]],
    -- junk - 10240 bytes, all zero
}

-- thumbnail image information found in some MP4 videos
Samsung.Thumbnail2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    FORMAT = 'int32u',
    [1] = 'ThumbnailWidth',
    [2] = 'ThumbnailHeight',
    [3] = 'ThumbnailLength',
    [4] = { Name = 'ThumbnailOffset', IsOffset = 1 },
}

-- information extracted from "ssuniqueid\0" APP5 (ref PH)
Samsung.APP5 = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    ssuniqueid = {
        Name = 'UniqueID',
        -- 32 bytes - some sort of serial number?
        ValueConv = function(_self, val) return perl.unpack('H*', val) end,
    },
}


-- information extracted from Samsung trailer (ie. Samsung SM-T805 "Sound & Shot" JPEG) (ref PH)
-- NOTE: These tags may use $$self{SamsungTagName} in a Condition statement
--       if necessary to differentiate tags with the same ID but different names
Samsung.Trailer = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Other' },
    VARS = { ID_FMT = 'none' },
    PROCESS_PROC = false, -- predeclaration: Samsung.ProcessSamsung (set below)
    TAG_PREFIX = 'SamsungTrailer',
    PRIORITY = 0, -- (first one takes priority so DepthMapWidth/Height match first DepthMapData)
    NOTES = [[
        Tags extracted from the SEFT trailer of JPEG and PNG images written when
        using certain features (such as "Sound & Shot" or "Shot & More") from
        Samsung models such as the Galaxy S4 and Tab S, and from the 'sefd' atom in
        HEIC images from models such as the S10+.
    ]],
    ['0x0001-name'] = 'EmbeddedImageName', -- ("DualShot_1","DualShot_2","SingleShot")
    ['0x0001'] = {
        {
            Name = 'EmbeddedImage',
            Condition = function(self)
                return self.SamsungTagName ~= 'DualShot_2'
            end,
            Groups = { [2] = 'Preview' },
            Binary = 1,
        },
        {
            Name = 'EmbeddedImage2',
            Groups = { [2] = 'Preview' },
            Binary = 1,
        },
        -- (have also seen the string "BOKEH" here (SM-A226B)
    },
    ['0x0100-name'] = 'EmbeddedAudioFileName', -- ("SoundShot_000")
    ['0x0100'] = { Name = 'EmbeddedAudioFile', Groups = { [2] = 'Audio' }, Binary = 1 },
    ['0x0201-name'] = 'SurroundShotVideoName', -- ("Interactive_Panorama_000")
    ['0x0201'] = { Name = 'SurroundShotVideo', Groups = { [2] = 'Video' }, Binary = 1 },
   -- 0x0800-name - seen 'SoundShot_Meta_Info'
   -- 0x0800 - unknown (29 bytes) (contains already-extracted EmbeddedAudioFileName)
   -- 0x0830-name - seen '1165724808.pre'
   -- 0x0830 - unknown (164004 bytes)
   -- 0x08c0-name - seen 'Auto_Enhance_Info' #forum16086
   -- 0x08d0-name - seen 'Interactive_Panorama_Info'
   -- 0x08d0 - unknown (7984 bytes)
   -- 0x08e0-name - seen 'Panorama_Shot_Info'
   -- 0x08e0 - string, seen 'PanoramaShot'
   -- 0x08e1-name - seen 'Motion_Panorama_Info'
   -- 0x0910-name - seen 'Front_Cam_Selfie_Info'
   -- 0x0910 - string, seen 'Front_Cam_Selfie_Info'
   -- 0x09e0-name - seen 'Burst_Shot_Info'
   -- 0x09e0 - string, seen '489489125'
   -- 0x09e1-name - seen 'BurstShot_Best_Photo_Info' #forum16086
   -- 0x09f0-name - seen 'Pro_Mode_Info' #forum16086
   -- 0x0a01-name - seen 'Image_UTC_Data'
    ['0x0a01'] = { -- #forum7161
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        ValueConv = function(self, val)
            return self.ConvertUnixTime(tonumber(val) / 1e3, 1, 3)
        end,
        PrintConv = function(self, val)
            return self:ConvertDateTime(val)
        end,
    },
    ['0x0a20-name'] = 'DualCameraImageName', -- ("FlipPhoto_002")
    ['0x0a20'] = { Name = 'DualCameraImage', Groups = { [2] = 'Preview' }, Binary = 1 },
    ['0x0a30-name'] = 'EmbeddedVideoType', -- ("MotionPhoto_Data")
    -- Note: A duplicate of this video may be extracted as MotionPhotoVideo from
    --       the Google trailer, but keep this copy named as EmbeddedVideoFile
    --       for backward compatibility and to avoid confusion due to extracting
    --       multiple tags with the same name
    ['0x0a30'] = {
        {
            Name = 'EmbeddedVideoOffsetSize',
            -- (have seen 12-byte data starting with "mpv2" that contains
            --  absolute file offset and size of embedded video)
            Condition = function(_self, val, _fmt, _count)
                return #val == 12
            end,
            ValueConv = function(self, val)
                -- (upstream: join(" ", unpack("x4N2", $val)))
                return str(self.Get32u(val, 4)) .. ' ' .. str(self.Get32u(val, 8))
            end,
        },
        { -- #forum7161
            Name = 'EmbeddedVideoFile',
            Groups = { [2] = 'Video' },
            Binary = 1,
        },
    },
   -- 0x0a31-name - seen MotionPhoto_Version
    ['0x0a31'] = 'SamsungMotionPhotoVersion', -- (to distinguish from XMP-GCamera:MotionPhotoVersion)
    ['0x0a33'] = { -- seen MotionPhoto_AutoPlay
        Name = 'MotionPhotoAutoPlayVideo',
        Groups = { [2] = 'Video' },
        Binary = 1,
    },
   -- 0x0a41-name - seen 'BackupRestore_Data' #forum16086
   -- 0x0aa1-name - seen 'MCC_Data'
   -- 0x0aa1 - seen '204','222','234','302','429'
    ['0x0aa1'] = {
        Name = 'MCCData',
        Groups = { [2] = 'Location' },
        PrintConv = {
            [202] = 'Greece (202)',
            [204] = 'Netherlands (204)',
            [206] = 'Belgium (206)',
            [208] = 'France (208)',
            [212] = 'Monaco (212)',
            [213] = 'Andorra (213)',
            [214] = 'Spain (214)',
            [216] = 'Hungary (216)',
            [218] = 'Bosnia & Herzegov. (218)',
            [219] = 'Croatia (219)',
            [220] = 'Serbia (220)',
            [221] = 'Kosovo (221)',
            [222] = 'Italy (222)',
            [226] = 'Romania (226)',
            [228] = 'Switzerland (228)',
            [230] = 'Czech Rep. (230)',
            [231] = 'Slovakia (231)',
            [232] = 'Austria (232)',
            [234] = 'United Kingdom (234)',
            [235] = 'United Kingdom (235)',
            [238] = 'Denmark (238)',
            [240] = 'Sweden (240)',
            [242] = 'Norway (242)',
            [244] = 'Finland (244)',
            [246] = 'Lithuania (246)',
            [247] = 'Latvia (247)',
            [248] = 'Estonia (248)',
            [250] = 'Russian Federation (250)',
            [255] = 'Ukraine (255)',
            [257] = 'Belarus (257)',
            [259] = 'Moldova (259)',
            [260] = 'Poland (260)',
            [262] = 'Germany (262)',
            [266] = 'Gibraltar (266)',
            [268] = 'Portugal (268)',
            [270] = 'Luxembourg (270)',
            [272] = 'Ireland (272)',
            [274] = 'Iceland (274)',
            [276] = 'Albania (276)',
            [278] = 'Malta (278)',
            [280] = 'Cyprus (280)',
            [282] = 'Georgia (282)',
            [283] = 'Armenia (283)',
            [284] = 'Bulgaria (284)',
            [286] = 'Turkey (286)',
            [288] = 'Faroe Islands (288)',
            [289] = 'Abkhazia (289)',
            [290] = 'Greenland (290)',
            [292] = 'San Marino (292)',
            [293] = 'Slovenia (293)',
            [294] = 'Macedonia (294)',
            [295] = 'Liechtenstein (295)',
            [297] = 'Montenegro (297)',
            [302] = 'Canada (302)',
            [308] = 'St. Pierre & Miquelon (308)',
            [310] = 'United States / Guam (310)',
            [311] = 'United States / Guam (311)',
            [312] = 'United States (312)',
            [316] = 'United States (316)',
            [330] = 'Puerto Rico (330)',
            [334] = 'Mexico (334)',
            [338] = 'Jamaica (338)',
            [340] = 'French Guiana / Guadeloupe / Martinique (340)',
            [342] = 'Barbados (342)',
            [344] = 'Antigua and Barbuda (344)',
            [346] = 'Cayman Islands (346)',
            [348] = 'British Virgin Islands (348)',
            [350] = 'Bermuda (350)',
            [352] = 'Grenada (352)',
            [354] = 'Montserrat (354)',
            [356] = 'Saint Kitts and Nevis (356)',
            [358] = 'Saint Lucia (358)',
            [360] = 'St. Vincent & Gren. (360)',
            [362] = 'Bonaire, Sint Eustatius and Saba / Curacao / Netherlands Antilles (362)',
            [363] = 'Aruba (363)',
            [364] = 'Bahamas (364)',
            [365] = 'Anguilla (365)',
            [366] = 'Dominica (366)',
            [368] = 'Cuba (368)',
            [370] = 'Dominican Republic (370)',
            [372] = 'Haiti (372)',
            [374] = 'Trinidad and Tobago (374)',
            [376] = 'Turks and Caicos Islands / US Virgin Islands (376)',
            [400] = 'Azerbaijan (400)',
            [401] = 'Kazakhstan (401)',
            [402] = 'Bhutan (402)',
            [404] = 'India (404)',
            [405] = 'India (405)',
            [410] = 'Pakistan (410)',
            [412] = 'Afghanistan (412)',
            [413] = 'Sri Lanka (413)',
            [414] = 'Myanmar (Burma) (414)',
            [415] = 'Lebanon (415)',
            [416] = 'Jordan (416)',
            [417] = 'Syrian Arab Republic (417)',
            [418] = 'Iraq (418)',
            [419] = 'Kuwait (419)',
            [420] = 'Saudi Arabia (420)',
            [421] = 'Yemen (421)',
            [422] = 'Oman (422)',
            [424] = 'United Arab Emirates (424)',
            [425] = 'Israel / Palestinian Territory (425)',
            [426] = 'Bahrain (426)',
            [427] = 'Qatar (427)',
            [428] = 'Mongolia (428)',
            [429] = 'Nepal (429)',
            [430] = 'United Arab Emirates (430)',
            [431] = 'United Arab Emirates (431)',
            [432] = 'Iran (432)',
            [434] = 'Uzbekistan (434)',
            [436] = 'Tajikistan (436)',
            [437] = 'Kyrgyzstan (437)',
            [438] = 'Turkmenistan (438)',
            [440] = 'Japan (440)',
            [441] = 'Japan (441)',
            [450] = 'South Korea (450)',
            [452] = 'Viet Nam (452)',
            [454] = 'Hongkong, China (454)',
            [455] = 'Macao, China (455)',
            [456] = 'Cambodia (456)',
            [457] = 'Laos P.D.R. (457)',
            [460] = 'China (460)',
            [466] = 'Taiwan (466)',
            [467] = 'North Korea (467)',
            [470] = 'Bangladesh (470)',
            [472] = 'Maldives (472)',
            [502] = 'Malaysia (502)',
            [505] = 'Australia (505)',
            [510] = 'Indonesia (510)',
            [514] = 'Timor-Leste (514)',
            [515] = 'Philippines (515)',
            [520] = 'Thailand (520)',
            [525] = 'Singapore (525)',
            [528] = 'Brunei Darussalam (528)',
            [530] = 'New Zealand (530)',
            [537] = 'Papua New Guinea (537)',
            [539] = 'Tonga (539)',
            [540] = 'Solomon Islands (540)',
            [541] = 'Vanuatu (541)',
            [542] = 'Fiji (542)',
            [544] = 'American Samoa (544)',
            [545] = 'Kiribati (545)',
            [546] = 'New Caledonia (546)',
            [547] = 'French Polynesia (547)',
            [548] = 'Cook Islands (548)',
            [549] = 'Samoa (549)',
            [550] = 'Micronesia (550)',
            [552] = 'Palau (552)',
            [553] = 'Tuvalu (553)',
            [555] = 'Niue (555)',
            [602] = 'Egypt (602)',
            [603] = 'Algeria (603)',
            [604] = 'Morocco (604)',
            [605] = 'Tunisia (605)',
            [606] = 'Libya (606)',
            [607] = 'Gambia (607)',
            [608] = 'Senegal (608)',
            [609] = 'Mauritania (609)',
            [610] = 'Mali (610)',
            [611] = 'Guinea (611)',
            [612] = 'Ivory Coast (612)',
            [613] = 'Burkina Faso (613)',
            [614] = 'Niger (614)',
            [615] = 'Togo (615)',
            [616] = 'Benin (616)',
            [617] = 'Mauritius (617)',
            [618] = 'Liberia (618)',
            [619] = 'Sierra Leone (619)',
            [620] = 'Ghana (620)',
            [621] = 'Nigeria (621)',
            [622] = 'Chad (622)',
            [623] = 'Central African Rep. (623)',
            [624] = 'Cameroon (624)',
            [625] = 'Cape Verde (625)',
            [626] = 'Sao Tome & Principe (626)',
            [627] = 'Equatorial Guinea (627)',
            [628] = 'Gabon (628)',
            [629] = 'Congo, Republic (629)',
            [630] = 'Congo, Dem. Rep. (630)',
            [631] = 'Angola (631)',
            [632] = 'Guinea-Bissau (632)',
            [633] = 'Seychelles (633)',
            [634] = 'Sudan (634)',
            [635] = 'Rwanda (635)',
            [636] = 'Ethiopia (636)',
            [637] = 'Somalia (637)',
            [638] = 'Djibouti (638)',
            [639] = 'Kenya (639)',
            [640] = 'Tanzania (640)',
            [641] = 'Uganda (641)',
            [642] = 'Burundi (642)',
            [643] = 'Mozambique (643)',
            [645] = 'Zambia (645)',
            [646] = 'Madagascar (646)',
            [647] = 'Reunion (647)',
            [648] = 'Zimbabwe (648)',
            [649] = 'Namibia (649)',
            [650] = 'Malawi (650)',
            [651] = 'Lesotho (651)',
            [652] = 'Botswana (652)',
            [653] = 'Swaziland (653)',
            [654] = 'Comoros (654)',
            [655] = 'South Africa (655)',
            [657] = 'Eritrea (657)',
            [659] = 'South Sudan (659)',
            [702] = 'Belize (702)',
            [704] = 'Guatemala (704)',
            [706] = 'El Salvador (706)',
            [708] = 'Honduras (708)',
            [710] = 'Nicaragua (710)',
            [712] = 'Costa Rica (712)',
            [714] = 'Panama (714)',
            [716] = 'Peru (716)',
            [722] = 'Argentina Republic (722)',
            [724] = 'Brazil (724)',
            [730] = 'Chile (730)',
            [732] = 'Colombia (732)',
            [734] = 'Venezuela (734)',
            [736] = 'Bolivia (736)',
            [738] = 'Guyana (738)',
            [740] = 'Ecuador (740)',
            [744] = 'Paraguay (744)',
            [746] = 'Suriname (746)',
            [748] = 'Uruguay (748)',
            [750] = 'Falkland Islands (Malvinas) (750)',
            [901] = 'International Networks / Satellite Networks (901)',
        },
    },
   -- 0x0ab0-name - seen 'DualShot_Meta_Info'
    ['0x0ab1-name'] = {
        Name = 'DepthMapName',
        -- seen 'DualShot_DepthMap_1' (SM-N950U), DualShot_DepthMap_5 (SM-G998W)
        RawConv = function(self, val) self.DepthMapName = val return val end,
    },
    ['0x0ab1'] = {
        {
            Name = 'DepthMapData',
            Condition = function(self) return self.DepthMapName == 'DualShot_DepthMap_1' end,
            Binary = 1,
        },{
            Name = 'DepthMapData2',
            Binary = 1,
        },
    },
   -- 0x0ab3-name - seen 'DualShot_Extra_Info' (SM-N950U)
    ['0x0ab3'] = { -- (SM-N950U)
        Name = 'DualShotExtra',
        SubDirectory = { TagTable = 'lexiftool.Samsung.DualShotExtra' },
     },
   -- 0x0ab4-name - seen 'DualShot_Core_Info' #forum16086
   -- 0x0ac0-name - seen 'ZoomInOut_Info' (SM-N950U)
   -- 0x0ac0 - 2048 bytes of interesting stuff including firmware version? (SM-N950U)
   -- 0x0b30-name - seen 'Camera_Sticker_Info' #forum16086
    ['0x0b40'] = { -- (SM-N975X front camera)
        Name = 'SingleShotMeta',
        SubDirectory = { TagTable = 'lexiftool.Samsung.SingleShotMeta' },
        -- (have also see the string "BOKEH_INFO" here (SM-A226B)
     },
   -- 0x0b41-name - seen 'SingeShot_DepthMap_1' (Yes, "Singe") (SM-N975X front camera)
    ['0x0b41'] = { Name = 'SingleShotDepthMap', Binary = 1 },
   -- 0x0b51-name - seen 'Intelligent_PhotoEditor_Data' #forum16086
   -- 0x0b60-name - seen 'UltraWide_PhotoEditor_Data' #forum16086
   -- 0x0b90-name - seen 'Document_Scan_Info' #forum16086
   -- 0x0ba1-name - seen 'Original_Path_Hash_Key', 'PhotoEditor_Re_Edit_Data', 'deco_doodle_bitmap',
   --               'deco_sticker_bitmap', 'deco_text_bitmap','PhotoEditor_Re_Edit_Data'
   --               (one line upstream; wrapped here for the 160-column limit)
    ['0x0ba1'] = {{
        Name = 'ReEditData',
        Condition = function(self) return self.SamsungTagName == 'PhotoEditor_Re_Edit_Data' end,
        SubDirectory = { TagTable = 'lexiftool.Samsung.ReEditData' },
    },{
        Name = 'OriginalPathHashKey',
        Condition = function(self) return self.SamsungTagName == 'Original_Path_Hash_Key' end,
    }},
   -- 0x0ba2-name - seen 'Copy_Available_Edit_Info' #forum16086
   -- 0x0bc0-name - seen 'Single_Relighting_Bokeh_Info' #forum16086
   -- 0x0bd0-name - seen 'Dual_Relighting_Bokeh_Info' #forum16086
   -- 0x0be0-name - seen 'Livefocus_JDM_Info' #forum16086
   -- 0x0bf0-name - seen 'Remaster_Info' #forum16086
   ['0x0bf0'] = 'RemasterInfo', --forum16086/16242
   -- 0x0c21-name - seen 'Portrait_Effect_Info' #forum16086
   -- 0x0c51-name - seen 'Samsung_Capture_Info' #forum16086
   ['0x0c51'] = 'SamsungCaptureInfo', --forum16086/16242
   -- 0x0c61-name - seen 'Camera_Capture_Mode_Info' #forum16086
   -- 0x0c71-name - seen 'Pro_White_Balance_Info' #forum16086
   -- 0x0c81-name - seen 'Watermark_Info' #forum16086
   -- 0x0cc1-name - seen 'Color_Display_P3' #forum16086
   -- 0x0cd2-name - seen 'Photo_HDR_Info' #forum16086
   -- 0x0ce1-name - seen 'Gallery_DC_Data' #forum16086
   -- 0x0d01-name - seen 'Camera_Scene_Info', 'Camera_Scene_Info2', 'Camera_Scene_Info3' #forum16086
   -- 0x0d11-name - seen 'Video_Snapshot_Info' #forum16086
   -- 0x0d21-name - seen 'Camera_Scene_Info' #forum16086
   -- 0x0d31-name - seen 'Food_Blur_Effect_Info' #forum16086
    ['0x0d91'] = { --forum16086/16242
        Name = 'PEg_Info',
        Description = 'PEg Info',
        SubDirectory = { TagTable = 'lexiftool.Samsung.PEgInfo' },
    },
   -- 0x0da1-name - seen 'Captured_App_Info' #forum16086
   -- 0xa050-name - seen 'Jpeg360_2D_Info' (Samsung Gear 360)
   -- 0xa050 - seen 'Jpeg3602D' (Samsung Gear 360)
   -- 0x0c61-name - seen 'Camera_Capture_Mode_Info'
   -- 0x0c61 - seen '1'
   -- 0x0c81-name - seen 'Watermark_Info'
   -- 0x0ce1-name - seen 'Gallery_DC_Data'
   -- 0x0ce1 - seen '0,109,2,19010102,4000,3000,0,0,0,0;116.284004;1.0'
   -- 0x0e41-name - seen 'Video_Edited_UTC_Offset'
   -- 0x0e41 - seen '+0800'
    ['0x0e41'] = {
        Name = 'VideoEditedTimeZone',
        Groups = { [2] = 'Time' },
    },
}

-- DualShot Extra Info (ref PH)
Samsung.DualShotExtra = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FIRST_ENTRY = 0,
    FORMAT = 'int32u',
    -- This is a pain, but the DepthMapWidth/Height move around in this record.
    -- In all of my samples so far, the bytes "01 00 ff ff" precede these tags.
    -- I have seen this byte sequence at offsets 32, 60, 64 and 68, so look for
    -- it in bytes 32-95, and use its location to adjust the tag positions
    [8] = {
        Name = 'DualShotDummy',
        Format = 'undef[64]',
        Hidden = 1,
        -- (the port's Hook is called with the ProcessBinaryData context and
        --  returns the delta to add to $varSize -- see lexiftool.lua)
        Hook = function(self, _format, _varSize, size, dataPt, pos)
            if size >= 96 then
                local tmp = substr(dataPt, pos, 64)
                -- (have seen 0x01,0x03 and 0x07)
                -- (perl.matches returns Perl's pos() as its last value)
                local _, m = perl.matches(tmp, '[\\x01-\\x09]\\0\\xff\\xff')
                if m and m % 4 == 0 then
                    self.DepthMapTagPos = m
                    return self.DepthMapTagPos - 32
                end
            end
            return 0
        end,
        RawConv = function() return nil end, -- not a real tag
    },
    [16] = {
        Name = 'DepthMapWidth',
        Condition = function(self) return ExifTool.perlTruthy(self.DepthMapTagPos) end,
        Notes = 'index varies depending on model',
    },
    [17] = {
        Name = 'DepthMapHeight',
        Condition = function(self) return ExifTool.perlTruthy(self.DepthMapTagPos) end,
        Notes = 'index varies depending on model',
    },
}

-- SingleShot Meta Info (ref PH) (SM-N975X front camera)
Samsung.SingleShotMeta = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    inputWidth          = { },
    inputHeight         = { },
    outputWidth         = { },
    outputHeight        = { },
    segWidth            = { },
    segHeight           = { },
    depthSWWidth        = { },
    depthSWHeight       = { },
    depthHWWidth        = { },
    depthHWHeight       = { },
    flipStatus          = { },
    lensFacing          = { },
    deviceOrientation   = { },
    objectOrientation   = { },
    isArtBokeh          = { },
    beautyRetouchLevel  = { },
    beautyColorLevel    = { },
    effectType          = { },
    effectStrength      = { },
    blurStrength        = { },
    spinStrength        = { },
    zoomStrength        = { },
    colorpopStrength    = { },
    monoStrength        = { },
    sidelightStrength   = { },
    vintageStrength     = { },
    bokehShape          = { },
    perfMode            = { },
}

Samsung.ReEditData = {
    GROUPS = { [0] = 'JSON', [2] = 'Image' },
    PROCESS_PROC = JSON.ProcessJSON,
    VARS = { LONG_TAGS = 2 },
    originalPath        = { },
    representativeFrameLoc = { },
    startMotionVideo    = { },
    endMotionVideo      = { },
    isMotionVideoMute   = { },
    isTrimMotionVideo   = { },
    clipInfoValue       = { SubDirectory = { TagTable = 'lexiftool.Samsung.ClipInfo' } },
    toneValue           = { SubDirectory = { TagTable = 'lexiftool.Samsung.ToneInfo' } },
    effectValue         = { SubDirectory = { TagTable = 'lexiftool.Samsung.EffectInfo' } },
    portraitEffectValue = { SubDirectory = { TagTable = 'lexiftool.Samsung.PortraitEffect' }  },
    isBlending          = { },
    isNotReEdit         = { },
    sepVersion          = { Name = 'SEPVersion' },
    ndeVersion          = { Name = 'NDEVersion' },
    reSize              = { },
    isScaleAI           = { },
    rotation            = { },
    adjustmentValue     = { },
    isApplyShapeCorrection = { },
    isNewReEditOnly     = { },
    isDecoReEditOnly    = { },
    isAIFilterReEditOnly= { },
}

Samsung.ClipInfo = {
    GROUPS = { [0] = 'JSON', [2] = 'Image' },
    PROCESS_PROC = JSON.ProcessJSON,
    mCenterX        = { Name = 'ClipCenterX' },
    mCenterY        = { Name = 'ClipCenterY' },
    mWidth          = { Name = 'ClipWidth' },
    mHeight         = { Name = 'ClipHeight' },
    mRotation       = { Name = 'ClipRotation' },
    mRotate         = { Name = 'ClipRotate' },
    mHFlip          = { Name = 'ClipHFlip' },
    mVFlip          = { Name = 'ClipVFlip' },
    mRotationEffect = { Name = 'ClipRotationEffect' },
    mRotateEffect   = { Name = 'ClipRotateEffect' },
    mHFlipEffect    = { Name = 'ClipHFlipEffect' },
    mVFlipEffect    = { Name = 'ClipVFlipEffect' },
    mHozPerspective = { Name = 'ClipHozPerspective' },
    mVerPerspective = { Name = 'ClipVerPerspective' },
}

Samsung.ToneInfo = {
    GROUPS = { [0] = 'JSON', [2] = 'Image' },
    PROCESS_PROC = JSON.ProcessJSON,
    brightness      = { },
    exposure        = { },
    contrast        = { },
    saturation      = { },
    hue             = { },
    wbMode          = { Name = 'WBMode' },
    wbTemperature   = { Name = 'WBTemperature' },
    tint            = { },
    shadow          = { },
    highlight       = { },
    lightbalance    = { },
    sharpness       = { },
    definition      = { },
    isBrightnessIPE = { },
    isExposureIPE   = { },
    isContrastIPE   = { },
    isSaturationIPE = { },
}

Samsung.EffectInfo = {
    GROUPS = { [0] = 'JSON', [2] = 'Image' },
    PROCESS_PROC = JSON.ProcessJSON,
    filterIndication= { },
    alphaValue      = { },
    filterType      = { },
}

Samsung.PortraitEffect = {
    GROUPS = { [0] = 'JSON', [2] = 'Image' },
    PROCESS_PROC = JSON.ProcessJSON,
    VARS = { LONG_TAGS = 1 },
    effectId        = { Name = 'PortraitEffectID' },
    effectLevel     = { Name = 'PortraitEffectLevel' },
    exifRotation    = { Name = 'PortraitExifRotation' },
    lightLevel      = { Name = 'PortraitLightLevel' },
    touchX          = { Name = 'PortraitTouchX' },
    touchY          = { Name = 'PortraitTouchY' },
    refocusX        = { Name = 'PortraitRefocusX' },
    refocusY        = { Name = 'PortraitRefocusY' },
    effectIdOriginal    = { Name = 'PortraitEffectIDOriginal' },
    effectLevelOriginal = { Name = 'EffectLevelOriginal' },
    lightLevelOriginal  = { Name = 'LightLevelOriginal' },
    touchXOriginal  = { },
    touchYOriginal  = { },
    refocusXOriginal= { },
    refocusYOriginal= { },
    waterMarkRemoved= { Name = 'WaterMarkRemoved' },
    waterMarkRemovedOriginal = { Name = 'WaterMarkRemovedOriginal' },
}

Samsung.PEgInfo = {
    GROUPS = { [0] = 'JSON', [2] = 'Image' },
    PROCESS_PROC = JSON.ProcessJSON,
    genImageVersion = { },
    connectorType   = { },
}

-- Samsung composite tags
Samsung.Composite = {
    GROUPS = { [2] = 'Image' },
    WB_RGGBLevels = {
        TagID = 'Samsung-WB_RGGBLevels',
        Require = {
            [0] = 'WB_RGGBLevelsUncorrected',
            [1] = 'WB_RGGBLevelsBlack',
        },
        ValueConv = function(_self, val)
            local a, b = {}, {}
            for v in perl.str(val[0]):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(v) end
            for v in perl.str(val[1]):gmatch('[^ \t\n\r\f\v]+') do b[#b + 1] = tonumber(v) end
            for i = 1, #a do a[i] = a[i] - (b[i] or 0) end
            return table.concat(a, ' ')
        end,
    },
    DepthMapTiff = {
        TagID = 'Samsung-DepthMapTiff',
        Require = {
            [0] = 'DepthMapData',
            [1] = 'DepthMapWidth',
            [2] = 'DepthMapHeight',
        },
        ValueConv = function(_self, val)
            local dat = type(val[0]) == 'table' and val[0].value or val[0]
            if #dat ~= val[1] * val[2] then return nil end
            local tiff = ExifTool.MakeTiffHeader(val[1], val[2], 1, 8) .. dat
            return { ref = 'SCALAR', value = tiff }
        end,
    },
    SingleShotDepthMapTiff = {
        TagID = 'Samsung-SingleShotDepthMapTiff',
        Require = {
            [0] = 'SingleShotDepthMap',
            [1] = 'SegWidth',
            [2] = 'SegHeight',
        },
        ValueConv = function(_self, val)
            local dat = type(val[0]) == 'table' and val[0].value or val[0]
            if #dat ~= val[1] * val[2] then return nil end
            local tiff = ExifTool.MakeTiffHeader(val[1], val[2], 1, 8) .. dat
            return { ref = 'SCALAR', value = tiff }
        end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.Samsung', nil, Samsung)

-- (PROCESS_PROC is set after the function definition below)

--------------------------------------------------------------------------------
-- Decrypt Samsung MakerNotes data (upstream Crypt)
-- Inputs: 0) ExifTool ref, 1) value, 2) tagInfo ref, 3-N) salt
-- Returns: decrypted value, or undef on error
function Samsung.Crypt(et, val, tagInfo, ...)
    local key = et.EncryptionKey
    if not key then return nil end
    local format = tagInfo.Writable or tagInfo.Format
    if not format then return nil end
    local mm = formatMinMax[format]
    if not mm then return nil end
    local min, max = mm[1], mm[2]
    local salt = { ... }
    local a = perl.split(' ', str(val))
    for i = 1, #a do a[i] = tonumber(a[i]) end
    local newSalt = #salt > 1 and 1 or 0  -- skip length entry if this is an array
    local sign, s, start
    local si = 1
    for i = newSalt, #a - 1 do
        if i == newSalt then
            start = i
            s = salt[si]; si = si + 1
            if type(s) == 'string' then
                sign = s:sub(1, 1) == '-' and -1 or 1
                s = tonumber(s:gsub('^%-', ''))
            else
                sign = 1
            end
            if si <= #salt then newSalt = newSalt + a[1] end
        end
        local k = key[((s + i - start) % #key) + 1]
        a[i + 1] = a[i + 1] + sign * tonumber(k)
        -- handle integer wrap-around
        if sign > 0 then
            if a[i + 1] > max then a[i + 1] = a[i + 1] - (max - min + 1) end
        else
            if a[i + 1] < min then a[i + 1] = a[i + 1] + (max - min + 1) end
        end
    end
    return perl.join(' ', a)
end

--------------------------------------------------------------------------------
-- Read Samsung INFO data
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: true on success
function Samsung.ProcessINFO(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local len = dirInfo.DirLen
    local endPos = pos + len
    while pos + 8 <= endPos do
        local tag = substr(dataPt, pos, 4)
        local val = ExifTool.Get32u(dataPt, pos + 4)
        if not tagTablePtr[tag] then
            local name = ('Samsung_INFO_' .. tag):gsub('[^%-_0-9a-zA-Z]', '')
            if name ~= '' then
                ExifTool.AddTagToTable(nil, tagTablePtr, tag, { Name = name })
            end
        end
        et:HandleTag(tagTablePtr, tag, val)
        pos = pos + 8
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read Samsung Meta Info from trailer
-- Inputs: 0) ExifTool ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: true on success
function Samsung.ProcessSamsungMeta(et, dirInfo, tagTablePtr)
    local dirName = dirInfo.DirName
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local endPos = dirInfo.DirLen + pos
    if not (pos + 8 <= endPos and substr(dataPt, pos, 4) == 'DOFS') then
        et:Warn('Unrecognized ' .. str(dirName) .. ' data', 1)
        return 0
    end
    local ver = ExifTool.Get32u(dataPt, pos + 4)
    if ver == 3 then
        if not (pos + 18 <= endPos and ExifTool.Get32u(dataPt, pos + 12) == dirInfo.DirLen) then
            et:Warn('Unrecognized ' .. str(dirName) .. ' version ' .. ver .. ' data')
            return 0
        end
        local num = ExifTool.Get16u(dataPt, pos + 16)
        pos = pos + 18
        local i = 0
        while i < num do
            if pos + 2 > endPos then break end
            local n = dataPt:byte(pos + 2)  -- (upstream unpack "x${pos}CC": $x is unused)
            pos = pos + 2
            if pos + n + 2 > endPos then break end
            local tag = substr(dataPt, pos, n)
            local len = ExifTool.Get16u(dataPt, pos + n)
            pos = pos + n + 2
            if pos + len > endPos then break end
            local val
            if len == 4 then
                val = ExifTool.Get32u(dataPt, pos)
            else
                -- (upstream stores a reference to the position here)
                val = { ref = 'SCALAR', value = pos }
            end
            et:HandleTag(tagTablePtr, tag, val)
            pos = pos + len
            i = i + 1
        end
        if i < num then
            et:Warn('Unexpected end of ' .. str(dirName) .. ' version ' .. ver ..
                ' ' .. i .. ' ' .. num .. ' data')
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process Samsung maker notes IFD
-- Inputs: 0) ExifTool ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: true on success
-- Port notes: the HTML_DUMP branch is out of scope with the rest of the dumper.
function Samsung.ProcessSamsungIFD(et, dirInfo, tagTablePtr)
    local Exif = require('lexiftool.Exif')
    local len = dirInfo.DataLen
    local pos = dirInfo.DirStart
    if pos + 4 >= len then return 0 end
    local dataPt = dirInfo.DataPt
    local buff = substr(dataPt, pos, 4)
    -- this is not an IFD for many models
    -- (the string "Park Byeongchan" is often found here)
    local c = buff:match('^([^%z])%z%z%z')
    if not c then return 0 end
    buff = c .. '\0' .. c .. '\0'
    local numEntries = c:byte()
    -- insert bogus 2-byte entry count
    dataPt = dataPt:sub(1, pos) .. buff .. dataPt:sub(pos + 5)
    dirInfo.DataPt = dataPt
    -- offset base is at end of IFD
    local shift = dirInfo.DirStart + 4 + numEntries * 12 + 4
    dirInfo.Base = (dirInfo.Base or 0) + shift
    dirInfo.DataPos = dirInfo.DataPos - shift
    dirInfo.DirStart = dirInfo.DirStart + 2   -- start at bogus entry count
    dirInfo.ZeroOffsetOK = 1                  -- disable check for zero offset
    et.NO_UNKNOWN = nil  -- (set for BinaryData, but not for EXIF IFD's)
    local rtn = Exif.ProcessExif(et, dirInfo, tagTablePtr)
    -- remove bogus count
    dataPt = dirInfo.DataPt
    dirInfo.DataPt = dataPt:sub(1, pos + 2) .. '\0' .. dataPt:sub(pos + 4)
    return rtn
end

--------------------------------------------------------------------------------
-- Process Samsung SEFT trailer
-- Inputs: 0) ExifTool ref, 1) dirInfo ref (RAF, Offset)
-- Returns: 1 on success, 0 if no Samsung trailer
--------------------------------------------------------------------------------
function Samsung.ProcessSamsung(et, dirInfo)
    local raf = dirInfo.RAF
    local offset = dirInfo.Offset or 0
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local unknown = et:Options('Unknown')
    local buff, buf2, offsetPos, audioNOff, audioSize
    local n

    if not raf then
        raf = RandomAccess.new(dirInfo.DataPt)
        et:VerboseDir('SamsungTrailer')
    end
    if raf:Seek(-6-offset, 2) then n, buff = raf:Read(6) end
    if not (n == 6 and (buff == 'QDIOBS' or buff == "\0\0SEFT")) then return 0 end
    local endPos = raf:Tell()
    if buff == 'QDIOBS' and not raf:Seek(-2, 1) then return 0 end -- rewind to before 'BS'
    local blockEnd = raf:Tell()
    ExifTool.SetByteOrder('II')

    -- read blocks backward until we find the SEFH/SEFT block
    -- (the only other block I have seen is QDIO/QDIO)
    while true do -- (SamBlock)
        n = nil
        if raf:Seek(blockEnd-8, 0) then n, buff = raf:Read(8) end
        if n ~= 8 then break end
        local type_ = substr(buff, 4)
        if not isMatch(type_, [[^\w+$]]) then break end
        local len = ExifTool.Get32u(buff, 0)
        if not (len < 0x10000 and len >= 4 and len + 8 < blockEnd) then break end
        n = nil
        if raf:Seek(-8-len, 1) then n, buff = raf:Read(len) end
        if n ~= len then break end
        blockEnd = blockEnd - (len + 8)
        if type_ ~= 'SEFT' then -- look for directory block (ends with "SEFT")
            if not (outfile and type_ == 'QDIO') then goto nextBlock end
            -- QDIO block format:
            --   0 - 'QDIO'
            --   4 - int32u: 101 (version)
            --   8 - int32u: 1
            --  12 - int32u: absolute offset of audio file start (augh!!)
            --  16 - int32u: absolute offset of audio file end (augh!!)
            --  20 - int32u: 20 (QDIO block length minus 8)
            --  24 - 'QDIO'
            if len == 20 then
                -- save position of audio file offset in QDIO block
                offsetPos = endPos - raf:Tell() + len - 12
            else
                et:Error('Unsupported Samsung trailer QDIO block', 1)
            end
            goto nextBlock
        end
        -- validate SEFH header
        if not (isMatch(buff, [[^SEFH]]) and len >= 12) then
            -- tolerate extra junk written by Samsung Gallery
            -- (m//g, then pos(): matches hands back the end offset)
            local ok, gpos = matches(buff, [[\0\0SEFT]])
            if not ok then break end
            et:Warn('Trailer likely corrupted by Samsung Gallery')
            blockEnd = blockEnd + gpos
            goto nextBlock
        end
        do
            local dirPos = raf:Tell() - len
            -- my $ver = Get32u(\$buff, 0x04);  # version (=101)
            local count = ExifTool.Get32u(buff, 0x08)
            if 12 + 12 * count > len then break end
            local tagTablePtr = et:GetTagTable('lexiftool.Samsung.Trailer')

            -- scan ahead quickly to look for the block where the data comes first
            -- (have only seen this to be the first in the directory, but just in case)
            local firstBlock = 0
            for index = 0, count - 1 do
                local entry = 12 + 12 * index
                local noff = ExifTool.Get32u(buff, entry + 4)  -- negative offset
                if firstBlock < noff then firstBlock = noff end
            end
            -- save trailer position and length
            dirInfo.DataPos = dirPos - firstBlock
            local dataPos = dirInfo.DataPos
            dirInfo.DirLen = endPos - dataPos
            local dirLen = dirInfo.DirLen
            if (perl.truthy(verbose) or et.HTML_DUMP) and not outfile and dirInfo.RAF then
                et:DumpTrailer(dirInfo)
                if et.HTML_DUMP then return 1 end
            end
            -- read through the SEFH/SEFT directory entries
            for index = 0, count - 1 do
                local entry = 12 + 12 * index
                -- first 2 bytes always 0 (may be part of block type)
                local type2 = ExifTool.Get16u(buff, entry + 2)  -- block type
                local noff = ExifTool.Get32u(buff, entry + 4)   -- negative offset
                local size = ExifTool.Get32u(buff, entry + 8)   -- block size
                if noff > dirPos or size > noff or size < 8 then goto lastSamBlock end
                if firstBlock < noff then firstBlock = noff end
                if outfile then
                    if not (type2 == 0x0100 and not audioNOff) then goto nextEntry end
                    -- save offset and length of first audio file for QDIO block
                    n = nil
                    if raf:Seek(dirPos-noff, 0) then n, buf2 = raf:Read(8) end
                    if n ~= 8 then break end
                    len = ExifTool.Get32u(buf2, 4)
                    audioNOff = noff - 8 - len  -- negative offset to start of audio data
                    audioSize = size - 8 - len
                    goto nextEntry
                end
                n = nil
                if raf:Seek(dirPos-noff, 0) then n, buf2 = raf:Read(size) end
                if n ~= size then break end
                -- (could validate the first 4 bytes of the block because they
                -- are the same as the first 4 bytes of the directory entry)
                len = ExifTool.Get32u(buf2, 4)
                if len + 8 > size then break end
                do
                    local tag = sprintf("0x%.4x", type2)
                    -- add unknown tags if necessary
                    if not tagTablePtr[tag] then
                        if not (perl.truthy(unknown) or perl.truthy(verbose)) then goto nextEntry end
                        local tagInfo = {
                            Name        = 'SamsungTrailer_' .. tag,
                            Description = 'Samsung Trailer ' .. tag,
                            Unknown     = 1,
                            Binary      = 1,
                        }
                        ExifTool.AddTagToTable(et, tagTablePtr, tag, tagInfo)
                    end
                    if not tagTablePtr[tag .. '-name'] then
                        local tagInfo2 = {
                            Name        = 'SamsungTrailer_' .. tag .. 'Name',
                            Description = 'Samsung Trailer ' .. tag .. ' Name',
                            Unknown     = 1,
                        }
                        ExifTool.AddTagToTable(et, tagTablePtr, tag .. '-name', tagInfo2)
                    end
                    -- set SamsungTagName ExifTool member for use in tag Condition
                    et.SamsungTagName = substr(buf2, 8, len)
                    -- extract tag name and value
                    et:HandleTag(tagTablePtr, tag .. '-name', nil, {
                        DataPt  = buf2,
                        DataPos = dirPos - noff,
                        Start   = 8,
                        Size    = len,
                    })
                    et:HandleTag(tagTablePtr, tag, nil, {
                        DataPt  = buf2,
                        DataPos = dirPos - noff,
                        Start   = 8 + len,
                        Size    = size - (8 + len),
                    })
                    et.SamsungTagName = nil
                end
                ::nextEntry::
            end
            if outfile then
                n = nil
                if raf:Seek(dataPos, 0) then n, buff = raf:Read(dirLen) end
                if n ~= dirLen then break end
                -- adjust the absolute offset in the QDIO block if necessary
                if perl.truthy(offsetPos) and perl.truthy(audioNOff) then
                    local Writer = require('lexiftool.Writer')   -- (Writer.pl, loaded on demand)
                    buff = carray.new('char'):append(buff)
                    -- initialize the audio file start/end position in the QDIO block
                    local newPos = Writer.Tell(outfile) + dirPos - audioNOff - dataPos
                    ExifTool.Set32u(buff, length(buff) - offsetPos, newPos)
                    ExifTool.Set32u(buff, length(buff) - offsetPos + 4, newPos + audioSize)
                    -- add a fixup so the calling routine can apply further shifts if necessary
                    local Fixup = require('lexiftool.Fixup')
                    local fixup = dirInfo.Fixup
                    if not fixup then fixup = Fixup.new(); dirInfo.Fixup = fixup end
                    fixup:AddFixup(length(buff) - offsetPos)
                    fixup:AddFixup(length(buff) - offsetPos + 4)
                end
                if perl.truthy(verbose) then et:VPrint(0, "  Writing Samsung trailer (" .. dirLen .. " bytes)\n") end
                if not require('lexiftool.Writer').Write(dirInfo.OutFile, buff) then return -1 end
                return 1
            end
            return 1
        end
        ::nextBlock::
    end
    ::lastSamBlock::
    et:Warn('Error processing Samsung trailer',1)
    return 0
end

--------------------------------------------------------------------------------
-- Write Samsung STMN maker notes
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: Binary data block or undefined on error
function Samsung.WriteSTMN(et, dirInfo, tagTablePtr)
    -- create a Fixup for the PreviewImage
    dirInfo.Fixup = require('lexiftool.Fixup').new()
    local val = require('lexiftool.Writer').WriteBinaryData(et, dirInfo, tagTablePtr)
    -- force PreviewImage into the trailer even if it fits in EXIF segment
    if et.PREVIEW_INFO then et.PREVIEW_INFO.IsTrailer = 1 end
    return val
end

Samsung.Trailer.PROCESS_PROC = Samsung.ProcessSamsung
Samsung.IFD.PROCESS_PROC = Samsung.ProcessSamsungIFD
Samsung.INFO.PROCESS_PROC = Samsung.ProcessINFO
Samsung.SingleShotMeta.PROCESS_PROC = Samsung.ProcessSamsungMeta

-- Write-side procs, filled in after the tables (conventions.md §2).
-- `WriteExif` is reached through a wrapper rather than a top-level require:
-- requiring it here would pull in almost every vendor module at Samsung load
-- time, and BuildCompositeTags decides its worklist from `package.loaded`
-- (see the note there) -- an eager require changes Composite build order for
-- every file.
local Writer = require('lexiftool.Writer')
Samsung.Main.WRITE_PROC = Samsung.WriteSTMN
Samsung.Main.CHECK_PROC = Writer.CheckBinaryData
Samsung.Type2.WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end
Samsung.Type2.CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end
for _, t in ipairs({ Samsung.OrientationInfo, Samsung.PictureWizard }) do
    t.WRITE_PROC = Writer.WriteBinaryData
    t.CHECK_PROC = Writer.CheckBinaryData
end

return Samsung
