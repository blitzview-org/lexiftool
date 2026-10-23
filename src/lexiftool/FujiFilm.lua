--------------------------------------------------------------------------------
-- File:         lexiftool/FujiFilm.lua
-- Ported from:  lib/Image/ExifTool/FujiFilm.pm
--
-- Description:  Read/write FujiFilm maker notes and RAF images
--
-- Revisions:    11/25/2003 - P. Harvey Created
--               11/14/2007 - PH Added ability to write RAF images
--
-- References:   1) http://park2.wakwak.com/~tsuruzoh/Computer/Digicams/exif-e.html
--               2) http://homepage3.nifty.com/kamisaka/makernote/makernote_fuji.htm (2007/09/11)
--               3) Michael Meissner private communication
--               4) Paul Samuelson private communication (S5)
--               5) http://www.cybercom.net/~dcoffin/dcraw/
--               6) http://forums.dpreview.com/forums/readflat.asp?forum=1012&thread=31350384
--                  and http://forum.photome.de/viewtopic.php?f=2&t=353&p=742#p740
--               7) Kai Lappalainen private communication
--               8) https://exiftool.org/forum/index.php/topic,5223.0.html
--               9) Zilvinas Brobliauskas private communication
--               10) Albert Shan private communication
--               11) https://exiftool.org/forum/index.php/topic,8377.0.html
--               12) https://exiftool.org/forum/index.php/topic,9607.0.html
--               13) https://exiftool.org/forum/index.php/topic=10481.0.html
--               IB) Iliah Borg private communication (LibRaw)
--               JD) Jens Duttke private communication
--
-- Port notes:   FujiFilm.pm in full: every tag table (Main, PrioritySettings,
--               FocusSettings, AFCSettings, DriveSettings, FaceRecInfo,
--               RAFHeader, RAF, RAFData, IFD, FFMV, MOV, MRAW), the
--               %testedRAF/%faceCategories lookups and all subs
--               (ProcessFaceRec, ProcessFujiDir, ProcessMRAW, WriteRAF,
--               ProcessRAF), in upstream order.  Deviations, all port
--               artifacts: the `sub X($$$);` predeclarations become `false`
--               PROCESS_PROC placeholders assigned at the bottom; the
--               `%faceCategories` spread is a `spread` copy per tag;
--               CHECK_PROC => CheckBinaryData is Writer.CheckBinaryData;
--               WriteRAF patches its header as a carray (Set32u in place)
--               and hands WriteJPEG the scalar-reference box
--               `{ value = <carray> }` for `\$outJpeg`.
--               Rewriting the maker notes themselves is not complete: their
--               offsets are relative (OffsetPt/Base '$start'), and the
--               TagInfo branch of MakerNotes::LocateIFD plus WriteExif's
--               one-time fixup for relative offsets are not ported, so an
--               EXIF edit of a FujiFilm JPEG/RAF leaves the maker-note
--               offsets wrong (a MakerNotes/WriteExif gap; WriteRAF itself
--               is byte-identical to upstream when the maker notes stay).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local Exif = require('lexiftool.Exif')
local RandomAccess = require('lexiftool.RandomAccess')
local perl = require('lexiftool.perl')
local carray = require('carray')
local matches = perl.matches
local subst = perl.subst
local findAll = perl.findAll
local split = perl.split
local join = perl.join
local reverse = perl.reverse
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local tr = perl.tr
local unpack = perl.unpack
local pack = perl.pack
local hex = perl.hex
local log = perl.log
local num = perl.num
local int = perl.int
local str = perl.str
local truthy = perl.truthy
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local Get64u = ExifTool.Get64u
local Set32u = ExifTool.Set32u -- (carray form: Set32u(dataPt, pos, val))
local ReadValue = ExifTool.ReadValue
local SetByteOrder = ExifTool.SetByteOrder
local GetByteOrder = ExifTool.GetByteOrder

local FujiFilm = {}

-- (port helper: copy a shared hash into the entry, as a Perl `%hash` spread
--  `{ %faceCategories }` makes a separate copy for each tag)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

local Write = Writer.Write

-- the following firmware version numbers have been tested for writing:
-- (as of ExifTool 11.70, this lookup is no longer used if the version number is numerical)
local testedRAF = {
    ['0100'] = 'E550, E900, F770, S5600, S6000fd, S6500fd, HS10/HS11, HS30, S200EXR, X100, XF1, X-Pro1, X-S1, XQ2 Ver1.00, X-T100, GFX 50R, XF10',
    ['0101'] = 'X-E1, X20 Ver1.01, X-T3',
    ['0102'] = 'S100FS, X10 Ver1.02',
    ['0103'] = 'IS Pro and X-T5 Ver1.03',
    ['0104'] = 'S5Pro Ver1.04',
    ['0106'] = 'S5Pro Ver1.06',
    ['0111'] = 'S5Pro Ver1.11',
    ['0114'] = 'S9600 Ver1.00',
    ['0120'] = 'X-T4 Ver1.20',
    ['0132'] = 'X-T2 Ver1.32',
    ['0144'] = 'X100T Ver1.44',
    ['0159'] = 'S2Pro Ver1.00',
    ['0200'] = 'X10 Ver2.00',
    ['0201'] = 'X-H1 Ver2.01',
    ['0212'] = 'S3Pro Ver2.12',
    ['0216'] = 'S3Pro Ver2.16', -- (NC)
    ['0218'] = 'S3Pro Ver2.18',
    ['0240'] = 'X-E1 Ver2.40',
    ['0264'] = 'F700 Ver2.00',
    ['0266'] = 'S9500 Ver1.01',
    ['0261'] = 'X-E1 Ver2.61',
    ['0269'] = 'S9500 Ver1.02',
    ['0271'] = 'S3Pro Ver2.71', -- UV/IR model?
    ['0300'] = 'X-E2',
   -- 0400  - expect to see this for X-T1
    ['0540'] = 'X-T1 Ver5.40',
    ['0712'] = 'S5000 Ver3.00',
    ['0716'] = 'S5000 Ver3.00', -- (yes, 2 firmware versions with the same Software version)
    ['0Dgi'] = 'X-A10 Ver1.01 and X-A3 Ver1.02', -- (yes, non-digits in the firmware number)
}

local faceCategories = spread {
    Format = 'int8u',
    PrintConv = { BITMASK = {
        [1] = 'Partner',
        [2] = 'Family',
        [3] = 'Friend',
    }},
}

-- FujiFilm MakerNotes tags
FujiFilm.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    [0x0] = {
        Name = 'Version',
        Writable = 'undef',
    },
    [0x0010] = { -- #PH/IB
        Name = 'InternalSerialNumber',
        Writable = 'string',
        Notes = [[
            this number is unique for most models, and contains the camera model ID and
            the date of manufacture
        ]],
        -- eg)  "FPX20017035 592D31313034060427796060110384"
        -- "FPX 20495643     592D313335310701318AD010110047" (F40fd)
        --                   HHHHHHHHHHHHyymmdd
        --   HHHHHHHHHHHH = camera body number in hex
        --   yymmdd       = date of manufacture
        PrintConv = function(_self, val)
            local c1, c2, c3, c4, c5, c6 = matches(val, [[(?s)^(.*?\s*)([0-9a-fA-F]*)(\d{2})(\d{2})(\d{2})(.{12})\s*\0*$]])
            if c1
                and num(c4) >= 1 and num(c4) <= 12 and num(c5) >= 1 and num(c5) <= 31
            then
                local yr = num(c3) + (num(c3) < 70 and 2000 or 1900)
                local sn = pack('H*', c2)
                return c1 .. sn .. ' ' .. yr .. ':' .. c4 .. ':' .. c5 .. ' ' .. c6
            else
                -- handle a couple of models which use a slightly different format
                val = subst(val, [[\b(592D(3[0-9])+)]], function(c1_) return pack('H*', c1_) .. ' ' end)
            end
            return val
        end,
        -- (this inverse conversion doesn't work in all cases, so it is best to write
        --  the ValueConv value if an authentic internal serial number is required)
        PrintConvInv = function(_self, val) val = subst(val, [[(\S+) (19|20)(\d{2}):(\d{2}):(\d{2}) ]], function(c1, _c2, c3, c4, c5) return (unpack('H*', c1)) .. c3 .. c4 .. c5 end) return val end,
    },
    [0x1000] = {
        Name = 'Quality',
        Writable = 'string',
    },
    [0x1001] = {
        Name = 'Sharpness',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x00] = '-4 (softest)', -- #10
            [0x01] = '-3 (very soft)',
            [0x02] = '-2 (soft)',
            [0x03] = '0 (normal)',
            [0x04] = '+2 (hard)',
            [0x05] = '+3 (very hard)',
            [0x06] = '+4 (hardest)',
            [0x82] = '-1 (medium soft)', -- #2
            [0x84] = '+1 (medium hard)', -- #2
            [0x8000] = 'Film Simulation', -- #2
            [0xffff] = 'n/a', -- #2
        },
    },
    [0x1002] = {
        Name = 'WhiteBalance',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x0]   = 'Auto',
            [0x1]   = 'Auto (white priority)', -- #forum10890
            [0x2]   = 'Auto (ambiance priority)', -- #forum10890
            [0x100] = 'Daylight',
            [0x200] = 'Cloudy',
            [0x300] = 'Daylight Fluorescent',
            [0x301] = 'Day White Fluorescent',
            [0x302] = 'White Fluorescent',
            [0x303] = 'Warm White Fluorescent', -- #2/PH (S5)
            [0x304] = 'Living Room Warm White Fluorescent', -- #2/PH (S5)
            [0x400] = 'Incandescent',
            [0x500] = 'Flash', -- #4
            [0x600] = 'Underwater', -- #forum6109
            [0xf00] = 'Custom',
            [0xf01] = 'Custom2', -- #2
            [0xf02] = 'Custom3', -- #2
            [0xf03] = 'Custom4', -- #2
            [0xf04] = 'Custom5', -- #2
            -- 0xfe0 => 'Gray Point?', #2
            [0xff0] = 'Kelvin', -- #4
        },
    },
    [0x1003] = {
        Name = 'Saturation',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x0]   = '0 (normal)', -- # ("Color 0", ref 8)
            [0x080] = '+1 (medium high)', -- #2 ("Color +1", ref 8)
            [0x100] = '+2 (high)', -- ("Color +2", ref 8)
            [0x0c0] = '+3 (very high)',
            [0x0e0] = '+4 (highest)',
            [0x180] = '-1 (medium low)', -- #2 ("Color -1", ref 8)
            [0x200] = 'Low',
            [0x300] = 'None (B&W)', -- #2
            [0x301] = 'B&W Red Filter', -- #PH/8
            [0x302] = 'B&W Yellow Filter', -- #PH (X100)
            [0x303] = 'B&W Green Filter', -- #PH/8
            [0x310] = 'B&W Sepia', -- #PH (X100)
            [0x400] = '-2 (low)', -- #8 ("Color -2")
            [0x4c0] = '-3 (very low)',
            [0x4e0] = '-4 (lowest)',
            [0x500] = 'Acros', -- #PH (X-Pro2)
            [0x501] = 'Acros Red Filter', -- #PH (X-Pro2)
            [0x502] = 'Acros Yellow Filter', -- #PH (X-Pro2)
            [0x503] = 'Acros Green Filter', -- #PH (X-Pro2)
            [0x8000] = 'Film Simulation', -- #2
        },
    },
    [0x1004] = {
        Name = 'Contrast',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x0]   = 'Normal',
            [0x080] = 'Medium High', -- #2
            [0x100] = 'High',
            [0x180] = 'Medium Low', -- #2
            [0x200] = 'Low',
            [0x8000] = 'Film Simulation', -- #2
        },
    },
    [0x1005] = { -- #4
        Name = 'ColorTemperature',
        Writable = 'int16u',
    },
    [0x1006] = { -- #JD
        Name = 'Contrast',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x0]   = 'Normal',
            [0x100] = 'High',
            [0x300] = 'Low',
        },
    },
    [0x100a] = { -- #2
        Name = 'WhiteBalanceFineTune',
        Notes = 'newer cameras should divide these values by 20', -- #forum10800
        Writable = 'int32s',
        Count = 2,
        PrintConv = function(_self, val) return sprintf('Red %+d, Blue %+d', table.unpack(split(' ', val))) end,
        PrintConvInv = function(_self, val) local v = findAll(val, [[-?\d+]]) return join(' ', v) end,
    },
    [0x100b] = { -- #2
        Name = 'NoiseReduction',
        Flags = 'PrintHex',
        Writable = 'int16u',
        RawConv = function(_self, val) if num(val) == 0x100 then return nil end return val end,
        PrintConv = {
            [0x40] = 'Low',
            [0x80] = 'Normal',
            [0x100] = 'n/a', -- #PH (NC) (all X100 samples)
        },
    },
    [0x100e] = { -- #PH (X100)
        Name = 'NoiseReduction',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x000] = '0 (normal)', -- ("NR 0, ref 8)
            [0x100] = '+2 (strong)', -- ("NR+2, ref 8)
            [0x180] = '+1 (medium strong)', -- #8 ("NR+1")
            [0x1c0] = '+3 (very strong)',
            [0x1e0] = '+4 (strongest)',
            [0x200] = '-2 (weak)', -- ("NR-2, ref 8)
            [0x280] = '-1 (medium weak)', -- #8 ("NR-1")
            [0x2c0] = '-3 (very weak)', -- #10 (-3)
            [0x2e0] = '-4 (weakest)', -- #10 (-4)
        },
    },
    [0x100f] = { -- #PR158
        Name = 'Clarity',
        Writable = 'int32s', -- #PH
        PrintConv = {
            [-5000] = '-5',
            [-4000] = '-4',
            [-3000] = '-3',
            [-2000] = '-2',
            [-1000] = '-1',
            [0] = '0',
            [1000] = '1',
            [2000] = '2',
            [3000] = '3',
            [4000] = '4',
            [5000] = '5',
        },
    },
    [0x1010] = {
        Name = 'FujiFlashMode',
        Writable = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0] = 'Auto',
            [1] = 'On',
            [2] = 'Off',
            [3] = 'Red-eye reduction',
            [4] = 'External', -- #JD
            [16] = 'Commander',
            [0x8000] = 'Not Attached', -- #10 (X-T2) (or external flash off)
            [0x8120] = 'TTL', -- #10 (X-T2)
            [0x8320] = 'TTL Auto - Did not fire',
            [0x9840] = 'Manual', -- #10 (X-T2)
            [0x9860] = 'Flash Commander', -- #13
            [0x9880] = 'Multi-flash', -- #10 (X-T2)
            [0xa920] = '1st Curtain (front)', -- #10 (EF-X500 flash)
            [0xaa20] = 'TTL Slow - 1st Curtain (front)', -- #13
            [0xab20] = 'TTL Auto - 1st Curtain (front)', -- #13
            [0xad20] = 'TTL - Red-eye Flash - 1st Curtain (front)', -- #13
            [0xae20] = 'TTL Slow - Red-eye Flash - 1st Curtain (front)', -- #13
            [0xaf20] = 'TTL Auto - Red-eye Flash - 1st Curtain (front)', -- #13
            [0xc920] = '2nd Curtain (rear)', -- #10
            [0xca20] = 'TTL Slow - 2nd Curtain (rear)', -- #13
            [0xcb20] = 'TTL Auto - 2nd Curtain (rear)', -- #13
            [0xcd20] = 'TTL - Red-eye Flash - 2nd Curtain (rear)', -- #13
            [0xce20] = 'TTL Slow - Red-eye Flash - 2nd Curtain (rear)', -- #13
            [0xcf20] = 'TTL Auto - Red-eye Flash - 2nd Curtain (rear)', -- #13
            [0xe920] = 'High Speed Sync (HSS)', -- #10
        },
    },
    [0x1011] = {
        Name = 'FlashExposureComp', -- #JD
        Writable = 'rational64s',
    },
    [0x1020] = {
        Name = 'Macro',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [0x1021] = {
        Name = 'FocusMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
            [65535] = 'Movie', -- #forum10766
        },
    },
    [0x1022] = { -- #8/forum6579
        Name = 'AFMode',
        Writable = 'int16u',
        Notes = '"No" for manual and some AF-multi focus modes',
        PrintConv = {
            [0] = 'No',
            [1] = 'Single Point',
            [256] = 'Zone',
            [512] = 'Wide/Tracking',
        },
    },
    [0x102b] = {
        Name = 'PrioritySettings',
        SubDirectory = { TagTable = 'lexiftool.FujiFilm.PrioritySettings' },
    },
    [0x102d] = {
        Name = 'FocusSettings',
        SubDirectory = { TagTable = 'lexiftool.FujiFilm.FocusSettings' },
    },
    [0x102e] = {
        Name = 'AFCSettings',
        SubDirectory = { TagTable = 'lexiftool.FujiFilm.AFCSettings' },
    },
    [0x1023] = { -- #2
        Name = 'FocusPixel',
        Writable = 'int16u',
        Count = 2,
    },
    [0x1030] = {
        Name = 'SlowSync',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [0x1031] = {
        Name = 'PictureMode',
        Flags = 'PrintHex',
        Writable = 'int16u',
        PrintConv = {
            [0x0] = 'Auto', -- (or 'SR+' if SceneRecognition present, ref 11)
            [0x1] = 'Portrait',
            [0x2] = 'Landscape',
            [0x3] = 'Macro', -- #JD
            [0x4] = 'Sports',
            [0x5] = 'Night Scene',
            [0x6] = 'Program AE',
            [0x7] = 'Natural Light', -- #3
            [0x8] = 'Anti-blur', -- #3
            [0x9] = 'Beach & Snow', -- #JD
            [0xa] = 'Sunset', -- #3
            [0xb] = 'Museum', -- #3
            [0xc] = 'Party', -- #3
            [0xd] = 'Flower', -- #3
            [0xe] = 'Text', -- #3
            [0xf] = 'Natural Light & Flash', -- #3
            [0x10] = 'Beach', -- #3
            [0x11] = 'Snow', -- #3
            [0x12] = 'Fireworks', -- #3
            [0x13] = 'Underwater', -- #3
            [0x14] = 'Portrait with Skin Correction', -- #7
            [0x16] = 'Panorama', -- #PH (X100)
            [0x17] = 'Night (tripod)', -- #7
            [0x18] = 'Pro Low-light', -- #7
            [0x19] = 'Pro Focus', -- #7
            [0x1a] = 'Portrait 2', -- #PH (NC, T500, maybe "Smile & Shoot"?)
            [0x1b] = 'Dog Face Detection', -- #7
            [0x1c] = 'Cat Face Detection', -- #7
            [0x30] = 'HDR', -- #forum10799
            [0x40] = 'Advanced Filter',
            [0x100] = 'Aperture-priority AE',
            [0x200] = 'Shutter speed priority AE',
            [0x300] = 'Manual',
        },
    },
    [0x1032] = { -- #8
        Name = 'ExposureCount',
        Writable = 'int16u',
        Notes = 'number of exposures used for this image',
    },
    [0x1033] = { -- #6
        Name = 'EXRAuto',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
        },
    },
    [0x1034] = { -- #6
        Name = 'EXRMode',
        Writable = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x100] = 'HR (High Resolution)',
            [0x200] = 'SN (Signal to Noise priority)',
            [0x300] = 'DR (Dynamic Range priority)',
        },
    },
    [0x1037] = { -- #forum17591
        Name = 'MultipleExposure',
        Writable = 'int16u', -- (NC)
        PrintConv = {
            [1] = 'Additive',
            [2] = 'Average',
            [3] = 'Light',
            [4] = 'Dark',
        },
    },
    [0x1040] = { -- #8
        Name = 'ShadowTone',
        Writable = 'int32s',
        PrintConv = {
            OTHER = function(val, inv)
                if inv then
                    return int(-num(val) * 16)
                else
                    return -num(val) / 16
                end
            end,
            [-64] = '+4 (hardest)',
            [-48] = '+3 (very hard)',
            [-32] = '+2 (hard)',
            [-16] = '+1 (medium hard)',
            [0] = '0 (normal)',
            [16] = '-1 (medium soft)',
            [32] = '-2 (soft)',
        },
    },
    [0x1041] = { -- #8
        Name = 'HighlightTone',
        Writable = 'int32s',
        PrintConv = {
            OTHER = function(val, inv)
                if inv then
                    return int(-num(val) * 16)
                else
                    return -num(val) / 16
                end
            end,
            [-64] = '+4 (hardest)',
            [-48] = '+3 (very hard)',
            [-32] = '+2 (hard)',
            [-16] = '+1 (medium hard)',
            [0] = '0 (normal)',
            [16] = '-1 (medium soft)',
            [32] = '-2 (soft)',
        },
    },
    [0x1044] = { -- #forum7668
        Name = 'DigitalZoom',
        Writable = 'int32u',
        ValueConv = function(_self, val) return val / 8 end,
        ValueConvInv = function(_self, val) return val * 8 end,
    },
    [0x1045] = { -- #12
        Name = 'LensModulationOptimizer',
        Writable = 'int32u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x1047] = { -- #12
        Name = 'GrainEffectRoughness',
        Writable = 'int32s',
        PrintConv = {
            [0] = 'Off',
            [32] = 'Weak',
            [64] = 'Strong',
        },
    },
    [0x1048] = { -- #12
        Name = 'ColorChromeEffect',
        Writable = 'int32s',
        PrintConv = {
            [0] = 'Off',
            [32] = 'Weak',
            [64] = 'Strong',
        },
    },
    [0x1049] = { -- #12,forum14319
        Name = 'BWAdjustment',
        Notes = 'positive values are warm, negative values are cool',
        Format = 'int8s',
        PrintConv = function(_self, val) if num(val) > 0 then return '+' .. str(val) end return val end,
        PrintConvInv = function(_self, val) return num(val) + 0 end,
    },
    [0x104b] = { -- #forum10800,forum14319
        Name = 'BWMagentaGreen',
        Notes = 'positive values are green, negative values are magenta',
        Format = 'int8s',
        PrintConv = function(_self, val) if num(val) > 0 then return '+' .. str(val) end return val end,
        PrintConvInv = function(_self, val) return num(val) + 0 end,
    },
    [0x104c] = { -- #PR158
        Name = "GrainEffectSize",
        Writable = 'int16u', -- #PH
        PrintConv = {
            [0] = 'Off',
            [16] = 'Small',
            [32] = 'Large',
        },
    },
    [0x104d] = { -- #forum9634
        Name = 'CropMode',
        Writable = 'int16u',
        PrintConv = { -- (perhaps this is a bit mask?)
            [0] = 'n/a',
            [1] = 'Full-frame on GFX', -- #IB
            [2] = 'Sports Finder Mode', -- (mechanical shutter)
            [4] = 'Electronic Shutter 1.25x Crop', -- (continuous high)
            [8] = 'Digital Tele-Conv', -- #forum15784
        },
    },
    [0x104e] = { -- #forum10800 (X-Pro3)
        Name = 'ColorChromeFXBlue',
        Writable = 'int32s',
        PrintConv = {
            [0] = 'Off',
            [32] = 'Weak', -- (NC)
            [64] = 'Strong',
        },
    },
    [0x1050] = { -- #forum6109
        Name = 'ShutterType',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Mechanical',
            [1] = 'Electronic',
            [2] = 'Electronic (long shutter speed)', -- #12
            [3] = 'Electronic Front Curtain', -- #10
        },
    },
    [0x1051] = { -- #forum15784
        Name = 'CropFlag',
        Writable = 'int8u',
        Notes = [[
            this tag exists only if the image was cropped, and is 0 for cropped JPG
            image or 1 for a cropped RAF
        ]],
    },
    [0x1052] = { Name = 'CropTopLeft', Writable = 'int32u' }, -- #forum15784
    [0x1053] = { Name = 'CropSize',    Writable = 'int32u' }, -- #forum15784
    -- 0x1100 - This may not work well for newer cameras (ref forum12682)
    [0x1100] = {{
        Name = 'AutoBracketing',
        Condition = function(self) return self.Model == 'X-T3' end,
        Notes = 'X-T3 only',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
            [2] = 'Pre-shot', -- #12 (Electronic Shutter and Continuous High drive mode only)
        },
    }, {
        Name = 'AutoBracketing',
        Notes = 'other models',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
            [2] = 'No flash & flash', -- #3
            [6] = 'Pixel Shift', -- #IB (GFX100S)
        },
    }},
    [0x1101] = {
        Name = 'SequenceNumber',
        Writable = 'int16u',
    },
    [0x1102] = { -- #forum17602
        Name = 'WhiteBalanceBracketing',
        Writable = 'int16u', -- (NC)
        PrintHex = 1,
        PrintConv = {
            [0x01ff] = '+/- 1',
            [0x02ff] = '+/- 2',
            [0x03ff] = '+/- 3',
        },
    },
    [0x1103] = {
        Name = 'DriveSettings',
        SubDirectory = { TagTable = 'lexiftool.FujiFilm.DriveSettings' },
    },
    [0x1105] = { Name = 'PixelShiftShots',  Writable = 'int16u' }, -- #IB
    [0x1106] = { Name = 'PixelShiftOffset', Writable = 'rational64s', Count = 2 }, -- #IB
    [0x1150] = {
        Name = 'CompositeImageMode',
        Writable = 'int32u',
        PrintConv = {
            [0] = 'n/a', -- #PH
            [1] = 'Pro Low-light', -- #7
            [2] = 'Pro Focus', -- #7
            [32] = 'Panorama', -- #PH
            [128] = 'HDR', -- #forum10799
            [1024] = 'Multi-exposure', -- #forum17591
        },
    },
    [0x1151] = {
        Name = 'CompositeImageCount1',
        Writable = 'int16u',
        -- Pro Low-light - val=4 (number of pictures taken?); Pro Focus - val=2,3 (ref 7); HDR - val=3 (forum10799)
    },
    [0x1152] = {
        Name = 'CompositeImageCount2',
        Writable = 'int16u',
        -- Pro Low-light - val=1,3,4 (stacked pictures used?); Pro Focus - val=1,2 (ref 7); HDR - val=3 (forum10799)
    },
    [0x1153] = { -- #forum7668
        Name = 'PanoramaAngle',
        Writable = 'int16u',
    },
    [0x1154] = { -- #forum7668
        Name = 'PanoramaDirection',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Right',
            [2] = 'Left', -- #forum17591
            [3] = 'Up', -- #forum17591
            [4] = 'Down',
        },
    },
    [0x1201] = { -- #forum6109
        Name = 'AdvancedFilter',
        Writable = 'int32u',
        PrintHex = 1,
        PrintConv = {
            [0x10000] = 'Pop Color',
            [0x20000] = 'Hi Key',
            [0x30000] = 'Toy Camera',
            [0x40000] = 'Miniature',
            [0x50000] = 'Dynamic Tone',
            [0x60001] = 'Partial Color Red',
            [0x60002] = 'Partial Color Yellow',
            [0x60003] = 'Partial Color Green',
            [0x60004] = 'Partial Color Blue',
            [0x60005] = 'Partial Color Orange',
            [0x60006] = 'Partial Color Purple',
            [0x70000] = 'Soft Focus',
            [0x90000] = 'Low Key',
            [0x100000] = 'Light Leak', -- #forum17392
            [0x130000] = 'Expired Film Green', -- #forum17392
            [0x130001] = 'Expired Film Red', -- #forum17392 (NC)
            [0x130002] = 'Expired Film Neutral', -- #forum17392
        },
    },
    [0x1210] = { -- #2
        Name = 'ColorMode',
        Writable = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x00] = 'Standard',
            [0x10] = 'Chrome',
            [0x30] = 'B & W',
        },
    },
    [0x1300] = {
        Name = 'BlurWarning',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'None',
            [1] = 'Blur Warning',
        },
    },
    [0x1301] = {
        Name = 'FocusWarning',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Good',
            [1] = 'Out of focus',
        },
    },
    [0x1302] = {
        Name = 'ExposureWarning',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Good',
            [1] = 'Bad exposure',
        },
    },
    [0x1304] = { -- #PH
        Name = 'GEImageSize',
        Condition = function(self) return matches(self.Make, [[^GENERAL IMAGING]]) ~= nil end,
        Writable = 'string',
        Notes = 'GE models only',
    },
    [0x1400] = { -- #2
        Name = 'DynamicRange',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Standard',
            [3] = 'Wide',
            -- the S5Pro has 100%(STD),130%,170%,230%(W1),300%,400%(W2) - PH
        },
    },
    [0x1401] = { -- #2 (this doesn't seem to work for the X100 - PH)
        Name = 'FilmMode',
        Writable = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x000] = 'F0/Standard (Provia)', -- X-Pro2 "Provia/Standard"
            [0x100] = 'F1/Studio Portrait',
            [0x110] = 'F1a/Studio Portrait Enhanced Saturation',
            [0x120] = 'F1b/Studio Portrait Smooth Skin Tone (Astia)', -- X-Pro2 "Astia/Soft"
            [0x130] = 'F1c/Studio Portrait Increased Sharpness',
            [0x200] = 'F2/Fujichrome (Velvia)', -- X-Pro2 "Velvia/Vivid"
            [0x300] = 'F3/Studio Portrait Ex',
            [0x400] = 'F4/Velvia',
            [0x500] = 'Pro Neg. Std', -- #PH (X-Pro1)
            [0x501] = 'Pro Neg. Hi', -- #PH (X-Pro1)
            [0x600] = 'Classic Chrome', -- #forum6109
            [0x700] = 'Eterna', -- #12
            [0x800] = 'Classic Negative', -- #forum10536
            [0x900] = 'Bleach Bypass', -- #forum10890
            [0xa00] = 'Nostalgic Neg', -- #forum12085
            [0xb00] = 'Reala ACE', -- #forum15190
        },
    },
    [0x1402] = { -- #2
        Name = 'DynamicRangeSetting',
        Writable = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x000] = 'Auto',
            [0x001] = 'Manual', -- #(ref http://forum.photome.de/viewtopic.php?f=2&t=353)
            [0x100] = 'Standard (100%)',
            [0x200] = 'Wide1 (230%)',
            [0x201] = 'Wide2 (400%)',
            [0x8000] = 'Film Simulation',
        },
    },
    [0x1403] = { -- #2 (only valid for manual DR, ref 6)
        Name = 'DevelopmentDynamicRange',
        Writable = 'int16u',
        -- (shows 200, 400 or 800 for HDR200,HDR400,HDR800, ref forum10799)
    },
    [0x1404] = { -- #2
        Name = 'MinFocalLength',
        Writable = 'rational64s',
    },
    [0x1405] = { -- #2
        Name = 'MaxFocalLength',
        Writable = 'rational64s',
    },
    [0x1406] = { -- #2
        Name = 'MaxApertureAtMinFocal',
        Writable = 'rational64s',
    },
    [0x1407] = { -- #2
        Name = 'MaxApertureAtMaxFocal',
        Writable = 'rational64s',
    },
    -- 0x1408 - values: '0100', 'S100', 'VQ10'
    -- 0x1409 - values: same as 0x1408
    -- 0x140a - values: 0, 1, 3, 5, 7 (bit 2=red-eye detection, ref 11/13)
    [0x140b] = { -- #6
        Name = 'AutoDynamicRange',
        Writable = 'int16u',
        PrintConv = function(_self, val) return str(val) .. '%' end,
        PrintConvInv = function(_self, val) val = subst(val, [[\s*\%$]], '') return val end,
    },
    [0x1422] = { -- #8
        Name = 'ImageStabilization',
        Writable = 'int16u',
        Count = 3,
        PrintConv = {{
            [0] = 'None',
            [1] = 'Optical', -- #PH
            [2] = 'Sensor-shift', -- #PH (now IBIS/OIS, ref forum13708)
            [3] = 'OIS Lens', -- #forum9815 (optical+sensor?)
            [258] = 'IBIS/OIS + DIS', -- #forum13708 (digital on top of IBIS/OIS)
            [512] = 'Digital', -- #PH
        }, {
            [0] = 'Off',
            [1] = 'On (mode 1, continuous)',
            [2] = 'On (mode 2, shooting only)',
        }},
    },
    [0x1425] = { -- if present and 0x1031 PictureMode is zero, then PictureMode is SR+, not Auto (ref 11)
        Name = 'SceneRecognition',
        Writable = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0] = 'Unrecognized',
            [0x100] = 'Portrait Image',
            [0x103] = 'Night Portrait', -- #forum10651
            [0x105] = 'Backlit Portrait', -- #forum10651
            [0x200] = 'Landscape Image',
            [0x300] = 'Night Scene',
            [0x400] = 'Macro',
        },
    },
    [0x1431] = { -- #forum6109
        Name = 'Rating',
        Groups = { [2] = 'Image' },
        Writable = 'int32u',
        Priority = 0,
    },
    [0x1436] = { -- #8
        Name = 'ImageGeneration',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Original Image',
            [1] = 'Re-developed from RAW',
        },
    },
    [0x1438] = { -- #forum6579 (X-T1 firmware version 3)
        Name = 'ImageCount',
        Notes = 'may reset to 0 when new firmware is installed',
        Writable = 'int16u',
        ValueConv = function(_self, val) return int(val) & 0x7fff end,
        ValueConvInv = function(_self, val) return int(val) | 0x8000 end,
    },
    [0x1443] = { -- #12 (X-T3)
        Name = 'DRangePriority',
        Writable = 'int16u',
        PrintConv = { [0] = 'Auto', [1] = 'Fixed' },
    },
    [0x1444] = { -- #12 (X-T3, only exists if DRangePriority is 'Auto')
        Name = 'DRangePriorityAuto',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Weak',
            [2] = 'Strong',
            [3] = 'Plus',    -- #forum10799
        },
    },
    [0x1445] = { -- #12 (X-T3, only exists if DRangePriority is 'Fixed')
        Name = 'DRangePriorityFixed',
        Writable = 'int16u',
        PrintConv = { [1] = 'Weak', [2] = 'Strong' },
    },
    [0x1446] = { -- #12
        Name = 'FlickerReduction',
        Writable = 'int32u',
        -- seen values: Off=0x0000, On=0x2100,0x3100
        PrintConv = function(_self, val)
            local on = (((int(val) >> 8) & 0x0f) == 1) and 'On' or 'Off'
            return sprintf('%s (0x%.4x)', on, val)
        end,
        PrintConvInv = function(_self, val) local c1 = matches(val, [[(?i)(0x[0-9a-f]+)]]) return hex(c1) end,
    },
    [0x1447] = { Name = 'FujiModel',  Writable = 'string' },
    [0x1448] = { Name = 'FujiModel2', Writable = 'string' },

    -- Found in X-M5, X-E5
    -- White balance as shot. Same valus as 0xf00e.
    [0x144a] = { Name = 'WBRed',      Writable = 'int16u' },
    [0x144b] = { Name = 'WBGreen',    Writable = 'int16u' },
    [0x144c] = { Name = 'WBBlue',     Writable = 'int16u' },

    [0x144d] = { Name = 'RollAngle',  Writable = 'rational64s' }, -- #forum14319
    [0x3803] = { -- #forum10037
        Name = 'VideoRecordingMode',
        Groups = { [2] = 'Video' },
        Writable = 'int32u',
        PrintHex = 1,
        PrintConv = {
            [0x00] = 'Normal',
            [0x10] = 'F-log',
            [0x20] = 'HLG',
            [0x30] = 'F-log2', -- #forum14384
        },
    },
    [0x3804] = { -- #forum10037
        Name = 'PeripheralLighting',
        Groups = { [2] = 'Video' },
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    -- 0x3805 - int16u: seen 1
    [0x3806] = { -- #forum10037
        Name = 'VideoCompression',
        Groups = { [2] = 'Video' },
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Log GOP',
            [2] = 'All Intra',
        },
    },
    -- 0x3810 - int32u: related to video codec (ref forum10037)
    [0x3820] = { -- #PH (HS20EXR MOV)
        Name = 'FrameRate',
        Writable = 'int16u',
        Groups = { [2] = 'Video' },
    },
    [0x3821] = { -- #PH (HS20EXR MOV)
        Name = 'FrameWidth',
        Writable = 'int16u',
        Groups = { [2] = 'Video' },
    },
    [0x3822] = { -- #PH (HS20EXR MOV)
        Name = 'FrameHeight',
        Writable = 'int16u',
        Groups = { [2] = 'Video' },
    },
    [0x3824] = { -- #forum10480 (X series)
        Name = 'FullHDHighSpeedRec',
        Writable = 'int32u',
        Groups = { [2] = 'Video' },
        PrintConv = { [1] = 'Off', [2] = 'On' },
    },
    [0x4005] = { -- #forum9634
        Name = 'FaceElementSelected', -- (could be face or eye)
        Writable = 'int16u',
        Count = 4,
    },
    [0x4100] = { -- #PH
        Name = 'FacesDetected',
        Writable = 'int16u',
    },
    [0x4103] = { -- #PH
        Name = 'FacePositions',
        Writable = 'int16u',
        Count = -1,
        Notes = [[
            left, top, right and bottom coordinates in full-sized image for each face
            detected
        ]],
    },
    [0x4200] = { -- #11
        Name = 'NumFaceElements',
        Writable = 'int16u',
    },
    [0x4201] = { -- #11
        Name = 'FaceElementTypes',
        Writable = 'int8u',
        Count = -1,
        PrintConv = {{
            [1] = 'Face',
            [2] = 'Left Eye',
            [3] = 'Right Eye',
            [7] = 'Body',
            [8] = 'Head',
            [9] = 'Both Eyes', -- #forum17635
            [11] = 'Bike',
            [12] = 'Body of Car',
            [13] = 'Front of Car',
            [14] = 'Animal Body',
            [15] = 'Animal Head',
            [16] = 'Animal Face',
            [17] = 'Animal Left Eye',
            [18] = 'Animal Right Eye',
            [19] = 'Bird Body',
            [20] = 'Bird Head',
            [21] = 'Bird Left Eye',
            [22] = 'Bird Right Eye',
            [23] = 'Aircraft Body',
            [25] = 'Aircraft Cockpit',
            [26] = 'Train Front',
            [27] = 'Train Cockpit',
            [28] = 'Animal Head (28)', -- #forum15192
            [29] = 'Animal Body (29)', -- #forum15192
        }, 'REPEAT'},
    },
    -- 0x4202 int8u[-1] - number of cooredinates in each rectangle? (ref 11)
    [0x4203] = { -- #11
        Name = 'FaceElementPositions',
        Writable = 'int16u',
        Count = -1,
        Notes = [[
            left, top, right and bottom coordinates in full-sized image for each face
            element
        ]],
    },
    -- 0x4101-0x4105 - exist only if face detection active
    -- 0x4104 - also related to face detection (same number of entries as FacePositions)
    -- 0x4200 - same as 0x4100?
    -- 0x4203 - same as 0x4103
    -- 0x4204 - same as 0x4104
    [0x4282] = { -- #PH
        Name = 'FaceRecInfo',
        SubDirectory = { TagTable = 'lexiftool.FujiFilm.FaceRecInfo' },
    },
    [0x8000] = { -- #2
        Name = 'FileSource',
        Writable = 'string',
    },
    [0x8002] = { -- #2
        Name = 'OrderNumber',
        Writable = 'int32u',
    },
    [0x8003] = { -- #2
        Name = 'FrameNumber',
        Writable = 'int16u',
    },
    [0xb211] = { -- #PH
        Name = 'Parallax',
        -- (value set in camera is -0.5 times this value in MPImage2... why?)
        Writable = 'rational64s',
        Notes = 'only found in MPImage2 of .MPO images',
    },
    -- 0xb212 - also found in MPIMage2 images - PH
}

-- Focus Priority settings, tag 0x102b (X-T3, ref forum 9607)
FujiFilm.PrioritySettings = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int16u',
    WRITABLE = 1,
    [0.1] = {
        Name = 'AF-SPriority',
        Mask = 0x000f,
        PrintConv = {
            [1] = 'Release',
            [2] = 'Focus',
        },
    },
    [0.2] = {
        Name = 'AF-CPriority',
        Mask = 0x00f0,
        PrintConv = {
            [1] = 'Release',
            [2] = 'Focus',
        },
    },
}

-- Focus settings, tag 0x102d (X-T3, ref forum 9607)
FujiFilm.FocusSettings = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int32u',
    WRITABLE = 1,
    [0.1] = {
        Name = 'FocusMode2',
        Mask = 0x0000000f,
        PrintConv = {
            [0x0] = 'AF-M',
            [0x1] = 'AF-S',
            [0x2] = 'AF-C',
        },
    },
    [0.2] = {
        Name = 'PreAF',
        Mask = 0x00f0,
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [0.3] = {
        Name = 'AFAreaMode',
        Mask = 0x0f00,
        PrintConv = {
            [0] = 'Single Point',
            [1] = 'Zone',
            [2] = 'Wide/Tracking',
        },
    },
    [0.4] = {
        Name = 'AFAreaPointSize',
        Mask = 0xf000,
        PrintConv = {
            [0] = 'n/a',
            OTHER = function(val) return val end,
        },
    },
    [0.5] = {
        Name = 'AFAreaZoneSize',
        Mask = 0xff0000,
        PrintConv = {
            [0] = 'n/a',
            OTHER = function(val, inv)
                local w, h
                if inv then
                    local w_, h_ = table.unpack(findAll(val, [[(\d+)]]))
                    if not (truthy(w_) and truthy(h_)) then return 0 end
                    return ((((int(h_) << 5) & 0xf0) | (int(w_) & 0x0f)))
                end
                w, h = int(val) & 0x0f, int(val) >> 5
                return w .. ' x ' .. h
            end,
        },
    },
}

-- AF-C settings, tag 0x102e (ref forum 9607)
FujiFilm.AFCSettings = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int32u',
    WRITABLE = 1,
    [0] = {
        Name = 'AF-CSetting',
        PrintHex = 3,
        PrintSort = 1, -- sort PrintConv by value
        -- decode in-camera preset values (X-T3)
        PrintConv = {
            [0x102] = 'Set 1 (multi-purpose)',              -- (2,0,Auto)
            [0x203] = 'Set 2 (ignore obstacles)',           -- (3,0,Center)
            [0x122] = 'Set 3 (accelerating subject)',       -- (2,2,Auto)
            [0x010] = 'Set 4 (suddenly appearing subject)', -- (0,1,Front)
            [0x123] = 'Set 5 (erratic motion)',             -- (3,2,Auto)
            OTHER = function(val, inv)
                if inv then local c1 = matches(val, [[(0x\w+)]]) if c1 then return hex(c1) end return nil end
                return sprintf('Set 6 (custom 0x%.3x)', val)
            end,
        },
    },
    [0.1] = {
        Name = 'AF-CTrackingSensitivity',
        Mask = 0x000f, -- (values 0-4)
    },
    [0.2] = {
        Name = 'AF-CSpeedTrackingSensitivity',
        Mask = 0x00f0,
        -- (values 0-2)
    },
    [0.3] = {
        Name = 'AF-CZoneAreaSwitching',
        Mask = 0x0f00,
        PrintConv = {
            [0] = 'Front',
            [1] = 'Auto',
            [2] = 'Center',
        },
    },
}

-- DriveMode settings, tag 0x1103 (X-T3, ref forum 9607)
FujiFilm.DriveSettings = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int32u',
    WRITABLE = 1,
    [0.1] = {
        Name = 'DriveMode',
        Mask = 0x000000ff,
        PrintConv = {
            [0] = 'Single',
            [1] = 'Continuous Low', -- not used by X-H2S? (see forum13777)
            [2] = 'Continuous High',
        },
    },
    [0.2] = {
        Name = 'DriveSpeed',
        Mask = 0xff000000,
        PrintConv = {
            [0] = 'n/a',
            OTHER = function(val, inv)
                if not inv then return str(val) .. ' fps' end
                val = subst(val, ' ?fps$', '')
                return val
            end,
        },
    },
}

-- Face recognition information from FinePix F550EXR (ref PH)
FujiFilm.FaceRecInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Face recognition information.',
    Face1Name = { },
    Face2Name = { },
    Face3Name = { },
    Face4Name = { },
    Face5Name = { },
    Face6Name = { },
    Face7Name = { },
    Face8Name = { },
    Face1Category = faceCategories {},
    Face2Category = faceCategories {},
    Face3Category = faceCategories {},
    Face4Category = faceCategories {},
    Face5Category = faceCategories {},
    Face6Category = faceCategories {},
    Face7Category = faceCategories {},
    Face8Category = faceCategories {},
    Face1Birthday = { },
    Face2Birthday = { },
    Face3Birthday = { },
    Face4Birthday = { },
    Face5Birthday = { },
    Face6Birthday = { },
    Face7Birthday = { },
    Face8Birthday = { },
}

-- tags extracted from RAF header
FujiFilm.RAFHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'RAF', [1] = 'RAF', [2] = 'Image' },
    NOTES = 'Tags extracted from the header of RAF images.',
  -- 0x00 - eg. "FUJIFILMCCD-RAW 0201FA392001FinePix S3Pro"
    [0x3c] = { -- #PH
        Name = 'FirmwareVersion', -- #forum17969
        Format = 'undef[4]',
    },
    -- (all int32u values)
  -- 0x40 - 1 for M-RAW, 0 otherwise?
  -- 0x44 - high word of M-RAW offset? (only seen zero)
  -- 0x48 - M-RAW header offset
  -- 0x4c - M-RAW header length
  -- 0x50 - ? (only seen zero)
  -- 0x54 - JPEG offset
  -- 0x58 - JPEG length
  -- 0x5c - RAF directory offset
  -- 0x60 - RAF directory length
  -- 0x64 - FujiIFD dir offset
  -- 0x68 - FujiIFD dir length
  -- 0x6c - RAFCompression or JPEG start
    [0x6c] = { -- #10
        Name = 'RAFCompression',
        Condition = function(_self, valPt) return matches(valPt, [[^\0\0\0]]) ~= nil end, -- (JPEG header is in this location for some RAF versions)
        Format = 'int32u',
        PrintConv = { [0] = 'Uncompressed', [2] = 'Lossless', [3] = 'Lossy'  },
    },
  -- 0x70 - ? same as 0x68?
  -- 0x74 - ? usually 0, but have seen 0x1700
  -- 0x78 - RAF1 dir offset
  -- 0x7c - RAF1 dir length
  -- 0x80 - FujiIFD1 dir offset
  -- 0x84 - FujiIFD1 dir length
  -- 0x88-0x8c - always zero?
  -- 0x90 - ? same as 0x74?
  -- 0x94 - JPEG or M-RAW start
}

-- tags in RAF images (ref 5)
FujiFilm.RAF = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'RAF', [1] = 'RAF', [2] = 'Image' },
    PRIORITY = 0, -- so the first RAF directory takes precedence
    NOTES = [[
        FujiFilm RAF images contain meta information stored in a proprietary
        FujiFilm RAF format, as well as EXIF information stored inside an embedded
        JPEG preview image.  The table below lists tags currently decoded from the
        RAF-format information.
    ]],
    [0x100] = {
        Name = 'RawImageFullSize',
        Format = 'int16u',
        Groups = { [1] = 'RAF2' }, -- (so RAF2 shows up in family 1 list)
        Count = 2,
        Notes = 'including borders',
        ValueConv = function(_self, val) local v = { reverse(table.unpack(split(' ', val))) } return join(' ', v) end, -- reverse to show width first
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
    },
    [0x110] = {
        Name = 'RawImageCropTopLeft',
        Format = 'int16u',
        Count = 2,
        Notes = 'top margin first, then left margin',
    },
    [0x111] = {
        Name = 'RawImageCroppedSize',
        Format = 'int16u',
        Count = 2,
        Notes = 'including borders',
        ValueConv = function(_self, val) local v = { reverse(table.unpack(split(' ', val))) } return join(' ', v) end, -- reverse to show width first
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
    },
    -- 0x112 - int16u[2] same as 0x111 but with width/height swapped?
    -- 0x113 - int16u[2] same as 0x111?
    [0x115] = {
        Name = 'RawImageAspectRatio',
        Format = 'int16u',
        Count = 2,
        ValueConv = function(_self, val) local v = { reverse(table.unpack(split(' ', val))) } return join(' ', v) end, -- reverse to show width first
        PrintConv = function(_self, val) val = tr(val, ' ', ':') return val end,
    },
    [0x117] = {
        Name = 'RawZoomActive',
        Format = 'int32u',
        Count = 1,
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x118] = {
        Name = 'RawZoomTopLeft',
        Format = 'int16u',
        Count = 2,
        Notes = 'relative to RawCroppedImageSize',
        ValueConv = function(_self, val) local v = { reverse(table.unpack(split(' ', val))) } return join(' ', v) end, -- reverse to show width first
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
    },
    [0x119] = {
        Name = 'RawZoomSize',
        Format = 'int16u',
        Count = 2,
        Notes = 'relative to RawCroppedImageSize',
        ValueConv = function(_self, val) local v = { reverse(table.unpack(split(' ', val))) } return join(' ', v) end, -- reverse to show width first
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
    },
    [0x121] = {
        {
            Name = 'RawImageSize',
            Condition = function(self) return self.Model == 'FinePixS2Pro' end,
            Format = 'int16u',
            Count = 2,
            ValueConv = function(_self, val)
                local v = split(' ', val)
                v[1] = v[1] * 2; v[2] = v[2] / 2 -- ($v[0], $v[1])
                return join(' ', v)
            end,
            PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        },
        {
            Name = 'RawImageSize',
            Format = 'int16u',
            Count = 2,
            -- values are height then width, adjusted for the layout
            ValueConv = function(self, val)
                local v = { reverse(table.unpack(split(' ', val))) }
                if truthy(self.FujiLayout) then v[1] = v[1] / 2; v[2] = v[2] * 2 end -- ($v[0], $v[1])
                return join(' ', v)
            end,
            PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        },
    },
    [0x130] = {
        Name = 'FujiLayout',
        Format = 'int8u',
        RawConv = function(self, val)
            local v = table.unpack(split(' ', val))
            self.FujiLayout = (int(v) & 0x80) ~= 0 and 1 or 0
            return val
        end,
    },
    [0x131] = { -- #5
        Name = 'XTransLayout',
        Description = 'X-Trans Layout',
        Format = 'int8u',
        Count = 36,
        PrintConv = function(_self, val) val = tr(val, '012 ', 'RGB', 'd') return join(' ', findAll(val, '......')) end,
    },
    -- 0x141 - int16u[2] Bit depth? "14 42" for 14-bit RAF and "16 48" for 16-bit RAF
    [0x2000] = { -- #IB
        Name = 'WB_GRGBLevelsAuto',
        Format = 'int16u',
        Count = 4, -- (ignore the duplicate values)
    },
    [0x2100] = { -- #IB
        Name = 'WB_GRGBLevelsDaylight', -- (EXIF Fine Weather)
        Format = 'int16u',
        Count = 4,
    },
    [0x2200] = { -- #IB
        Name = 'WB_GRGBLevelsCloudy', -- (EXIF Shade)
        Format = 'int16u',
        Count = 4,
    },
    [0x2300] = { -- #IB
        Name = 'WB_GRGBLevelsDaylightFluor', -- (EXIF FL_D)
        Format = 'int16u',
        Count = 4,
    },
    [0x2301] = { -- #IB
        Name = 'WB_GRGBLevelsDayWhiteFluor', -- (EXIF FL_N)
        Format = 'int16u',
        Count = 4,
    },
    [0x2302] = { -- #IB
        Name = 'WB_GRGBLevelsWhiteFluorescent', -- (EXIF FL_W)
        Format = 'int16u',
        Count = 4,
    },
    [0x2310] = { -- #IB
        Name = 'WB_GRGBLevelsWarmWhiteFluor', -- (EXIF FL_WW)
        Format = 'int16u',
        Count = 4,
    },
    [0x2311] = { -- #IB
        Name = 'WB_GRGBLevelsLivingRoomWarmWhiteFluor', -- (EXIF FL_L)
        Format = 'int16u',
        Count = 4,
    },
    [0x2400] = { -- #IB
        Name = 'WB_GRGBLevelsTungsten',
        Format = 'int16u',
        Count = 4,
    },
    [0x2410] = { -- #IB
        Name = 'WB_GRGBLevelsFlash',
        Format = 'int16u',
        Count = 4,
    },
    -- 0x2f00 => WB_GRGBLevelsCustom: int32u count, then count * (int16u GRGBGRGB), ref IB
    [0x2ff0] = {
        Name = 'WB_GRGBLevels', -- (as shot)
        Format = 'int16u',
        Count = 4,
    },
    [0x9200] = { -- #Frank Markesteijn
        Name = 'RelativeExposure',
        Format = 'rational32s',
        ValueConv = function(_self, val) return log(val) / log(2) end,
        ValueConvInv = function(_self, val) return math.exp(val * log(2)) end,
        PrintConv = function(_self, val) if truthy(val) then return sprintf('%+.1f', val) end return 0 end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- 0x9200 - relative exposure? (ref Frank Markesteijn)
    [0x9650] = { -- #Frank Markesteijn
        Name = 'RawExposureBias',
        Format = 'rational32s',
        PrintConv = function(_self, val) if truthy(val) then return sprintf('%+.1f', val) end return 0 end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0xc000] = {
        Name = 'RAFData',
        SubDirectory = {
            TagTable = 'lexiftool.FujiFilm.RAFData',
            ByteOrder = 'Little-endian',
        }
    },
}

FujiFilm.RAFData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    DATAMEMBER = { 0, 4, 8 },
    FIRST_ENTRY = 0,
    -- (FujiFilm image dimensions are REALLY confusing)
    -- --> this needs some cleaning up
    -- [Note to self: See email from Iliah Borg for more information about WB settings in this data]
    [0] = {
        Name = 'RawImageWidth',
        Format = 'int32u',
        DataMember = 'FujiWidth',
        RawConv = function(self, val) if num(val) < 10000 then self.FujiWidth = val return val end return nil end, -- #5
        ValueConv = function(self, val) if truthy(self.FujiLayout) then return (val / 2) end return val end,
    },
    [4] = {
        {
            Name = 'RawImageWidth',
            Condition = function(self) return not truthy(self.FujiWidth) end,
            Format = 'int32u',
            DataMember = 'FujiWidth',
            RawConv = function(self, val) if num(val) < 10000 then self.FujiWidth = val return val end return nil end, -- #PH
            ValueConv = function(self, val) if truthy(self.FujiLayout) then return (val / 2) end return val end,
        },
        {
            Name = 'RawImageHeight',
            Format = 'int32u',
            DataMember = 'FujiHeight',
            RawConv = function(self, val) self.FujiHeight = val; return val end,
            ValueConv = function(self, val) if truthy(self.FujiLayout) then return (val * 2) end return val end,
        },
    },
    [8] = {
        {
            Name = 'RawImageWidth',
            Condition = function(self) return not truthy(self.FujiWidth) end,
            Format = 'int32u',
            DataMember = 'FujiWidth',
            RawConv = function(self, val) if num(val) < 10000 then self.FujiWidth = val return val end return nil end, -- #PH
            ValueConv = function(self, val) if truthy(self.FujiLayout) then return (val / 2) end return val end,
        },
        {
            Name = 'RawImageHeight',
            Condition = function(self) return not truthy(self.FujiHeight) end,
            Format = 'int32u',
            DataMember = 'FujiHeight',
            RawConv = function(self, val) self.FujiHeight = val; return val end,
            ValueConv = function(self, val) if truthy(self.FujiLayout) then return (val * 2) end return val end,
        },
    },
    [12] = {
        Name = 'RawImageHeight',
        Condition = function(self) return not truthy(self.FujiHeight) end,
        Format = 'int32u',
        ValueConv = function(self, val) if truthy(self.FujiLayout) then return (val * 2) end return val end,
    },
}

-- TIFF IFD-format information stored in FujiFilm RAF images (ref 5)
FujiFilm.IFD = {
    PROCESS_PROC = Exif.ProcessExif,
    GROUPS = { [0] = 'RAF', [1] = 'FujiIFD', [2] = 'Image' },
    NOTES = 'Tags found in the FujiIFD information of RAF images from some models.',
    [0xf000] = {
        Name = 'FujiIFD',
        Groups = { [1] = 'FujiIFD' },
        Flags = 'SubIFD',
        SubDirectory = {
            TagTable = 'lexiftool.FujiFilm.IFD',
            DirName = 'FujiSubIFD',
            Start = function(_self, val, _valuePtr) return val end,
        },
    },
    [0xf001] = 'RawImageFullWidth',
    [0xf002] = 'RawImageFullHeight',
    [0xf003] = 'BitsPerSample',
    -- 0xf004 - values: 4
    -- 0xf005 - values: 1374, 1668
    -- 0xf006 - some sort of flag indicating packed format?
    [0xf007] = {
        Name = 'StripOffsets',
        IsOffset = 1,
        IsImageData = 1,
        OffsetPair = 0xf008,  -- point to associated byte counts
    },
    [0xf008] = {
        Name = 'StripByteCounts',
        OffsetPair = 0xf007,  -- point to associated offsets
    },
    -- 0xf009 - values: 0, 3
    [0xf00a] = 'BlackLevel', -- #IB
    [0xf00b] = 'GeometricDistortionParams', -- #9 (rational64s[23, 35 or 43])
    [0xf00c] = 'WB_GRBLevelsStandard', -- #IB (GRBXGRBX; X=17 is standard illuminant A, X=21 is D65)
    [0xf00d] = 'WB_GRBLevelsAuto', -- #IB
    [0xf00e] = 'WB_GRBLevels',
    [0xf00f] = 'ChromaticAberrationParams', -- (rational64s[23])
    [0xf010] = 'VignettingParams', -- #9 (rational64s[31 or 64])
    -- 0xf013 - int32u[3] same as 0xf00d
    -- 0xf014 - int32u[3] - also related to WhiteBalance
}

-- information found in FFMV atom of MOV videos
FujiFilm.FFMV = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    NOTES = 'Information found in the FFMV atom of MOV videos.',
    [0] = {
        Name = 'MovieStreamName',
        Format = 'string[34]',
    },
}

-- tags in FujiFilm QuickTime videos (ref PH)
-- (similar information in Kodak,Minolta,Nikon,Olympus,Pentax and Sanyo videos)
FujiFilm.MOV = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    NOTES = 'This information is found in MOV videos from some FujiFilm cameras.',
    [0x00] = {
        Name = 'Make',
        Format = 'string[24]',
    },
    [0x18] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[16]',
    },
    [0x2e] = { -- (NC)
        Name = 'ExposureTime',
        Format = 'int32u',
        ValueConv = function(_self, val) if truthy(val) then return 1 / val end return 0 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x32] = {
        Name = 'FNumber',
        Format = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x3a] = { -- (NC)
        Name = 'ExposureCompensation',
        Format = 'rational64s',
        PrintConv = function(_self, val) if truthy(val) then return sprintf('%+.1f', val) end return 0 end,
    },
}

-- tags in RAF M-RAW header (ref PH)
FujiFilm.MRAW = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'RAF', [1] = 'M-RAW', [2] = 'Image' },
    FORMAT = 'int32u',
    TAG_PREFIX = 'MRAW',
    NOTES = [[
        Tags extracted from the M-RAW header of multi-image RAF files.  The family 1
        group name for these tags is "M-RAW".  Additional metadata may be extracted
        from the embedded RAW images with the ExtractEmbedded option.
    ]],
    [0x2001] = { Name = 'RawImageNumber', Format = 'int32u' },
    -- 0x2003 - seen "0 100", "-300 100" and "300 100" for a sequence of 3 images
    [0x2003] = { Name = 'ExposureCompensation', Format = 'rational32s', Unknown = 1, Hidden = 1, PrintConv = function(_self, val) return sprintf('%+.2f', val) end },
    -- 0x2004 - (same value as 3 in all my samples)
    [0x2004] = { Name = 'ExposureCompensation2', Format = 'rational32s', Unknown = 1, Hidden = 1, PrintConv = function(_self, val) return sprintf('%+.2f', val) end },
    -- 0x2005 - seen "10 1600", "10 6800", "10 200", "10 35000" etc
    [0x2005] = { Name = 'ExposureTime', Format = 'rational64u', PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end },
    -- 0x2006 - seen "450 100", "400 100" (all images in RAF have same value)
    [0x2006] = { Name = 'FNumber', Format = 'rational64u', PrintConv = function(_self, val) return Exif.PrintFNumber(val) end },
    -- 0x2007 - seen 200, 125, 250, 2000
    [0x2007] = 'ISO',
    -- 0x2008 - seen 0, 65536
}

--------------------------------------------------------------------------------
-- decode information from FujiFilm face recognition information
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1
function FujiFilm.ProcessFaceRec(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos + (dirInfo.Base or 0)
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    local pos = dirStart
    local end_ = dirStart + dirLen
    local i, n, p, val
    et:VerboseDir('FaceRecInfo')
    i = 1
    while true do
        if pos + 8 > end_ then break end
        local off = Get32u(dataPt, pos) + dirStart
        local len = Get32u(dataPt, pos + 4)
        if len == 0 or off > end_ or off + len > end_ or len < 62 then break end
        -- values observed for each offset (always zero if not listed):
        -- 0=5; 3=1; 4=4; 6=1; 10-13=numbers(constant for a given registered face)
        -- 15=16; 16=3; 18=1; 22=nameLen; 26=1; 27=16; 28=7; 30-33=nameLen(int32u)
        -- 34-37=nameOffset(int32u); 38=32; 39=16; 40=4; 42=1; 46=0,2,4,8(category)
        -- 50=33; 51=16; 52=7; 54-57=dateLen(int32u); 58-61=dateOffset(int32u)
        n = Get32u(dataPt, off + 30)
        p = Get32u(dataPt, off + 34) + dirStart
        if p < dirStart or p + n > end_ then break end
        val = substr(dataPt, p, n)
        et:HandleTag(tagTablePtr, 'Face' .. i .. 'Name', val, {
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = p,
            Size    = n,
        })
        n = Get32u(dataPt, off + 54)
        p = Get32u(dataPt, off + 58) + dirStart
        if p < dirStart or p + n > end_ then break end
        val = substr(dataPt, p, n)
        val = subst(val, [[(\d{4})(\d{2})(\d{2})]], '$1:$2:$2')
        et:HandleTag(tagTablePtr, 'Face' .. i .. 'Birthday', val, {
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = p,
            Size    = n,
        })
        et:HandleTag(tagTablePtr, 'Face' .. i .. 'Category', nil, {
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = off + 46,
            Size    = 1,
        })
        pos = pos + 8
        i = i + 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- get information from FujiFilm RAF directory
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 if this was a valid FujiFilm directory
function FujiFilm.ProcessFujiDir(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local offset = dirInfo.DirStart
    if not raf:Seek(offset, 0) then return 0 end
    local buff, n
    n, buff = raf:Read(4)
    if n == 0 then return 0 end
    local entries = unpack('N', buff)
    if entries >= 256 then return 0 end
    et:VerboseDir('Fuji', entries)
    SetByteOrder('MM')
    local pos = offset + 4
    for index = 0, entries - 1 do
        n, buff = raf:Read(4)
        if n == 0 then return 0 end
        pos = pos + 4
        local tag, len = unpack('nn', buff)
        local val, vbuf
        n, vbuf = raf:Read(len)
        if n == 0 then return 0 end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo and tagInfo.Format then
            val = ReadValue(vbuf, 0, tagInfo.Format, tagInfo.Count, len)
            if val == nil then goto next end
        elseif len == 4 then
            -- interpret unknown 4-byte values as int32u
            val = Get32u(vbuf, 0)
        else
            -- treat other unknown values as binary data
            val = { ref = 'SCALAR', value = vbuf }
        end
        et:HandleTag(tagTablePtr, tag, val, {
            Index   = index,
            DataPt  = vbuf,
            DataPos = pos,
            Size    = len,
            TagInfo = tagInfo,
        })
        pos = pos + len
        ::next::
    end
    return 1
end

--------------------------------------------------------------------------------
-- get information from FujiFilm M-RAW header
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 if this was a valid M-RAW header
function FujiFilm.ProcessMRAW(et, dirInfo, tagTablePtr)
    if truthy(et.DOC_NUM) then return 1 end
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dataLen = length(dataPt)
    if dataLen < 44 then et:Warn('Short M-RAW header') return 0 end
    if not matches(dataPt, '^FUJIFILMM-RAW  ') then et:Warn('Bad M-RAW header') return 0 end
    local ver = substr(dataPt, 16, 4)
    et:VerboseDir('M-RAW ' .. ver, nil, dataLen)
    SetByteOrder('MM')
    local size = Get16u(dataPt, 40) -- (these are just a guess - PH)
    local num_ = Get16u(dataPt, 42)
    local pos = 44
    local i, n
    n = 0
    while true do
        local end_ = pos + 16 + size
        if end_ > dataLen then break end
        local rafStart = Get64u(dataPt, pos)
        local rafLen = Get64u(dataPt, pos + 8)
        pos = pos + 16 -- skip offset/size fields
        if pos > 60 then et.DOC_COUNT = (et.DOC_COUNT or 0) + 1; et.DOC_NUM = et.DOC_COUNT end
        et:VPrint(0, et.INDENT .. '(Raw image ' .. n .. ' parameters: ' .. size .. ' bytes, ' .. num_ .. ' entries)\n')
        i = 0
        while i < num_ do
            if pos + 4 > end_ then break end
            local tag = Get16u(dataPt, pos)
            local size_ = Get16u(dataPt, pos + 2)
            pos = pos + 4
            if pos + size_ > end_ then break end
            et:HandleTag(tagTablePtr, tag, nil, {
                DataPt  = dataPt,
                DataPos = dataPos,
                Start   = pos,
                Size    = size_,
            })
            pos = pos + size_
            i = i + 1
        end
        if truthy(rafStart) and truthy(et:Options('ExtractEmbedded')) then
            if truthy(et:Options('Verbose')) then
                local msg = sprintf(et.INDENT .. '(RAW image ' .. n .. ' data: Start=0x%x, Length=0x%x)\n', rafStart, rafLen)
                et:VPrint(0, msg)
            end
            local raf = et.RAF
            local tell = raf:Tell()
            local order = GetByteOrder()
            local fujiWidth = et.FujiWidth
            if not raf:Seek(rafStart, 0) then goto next end
            FujiFilm.ProcessRAF(et, { RAF = raf, Base = rafStart })
            et.FujiWidth = fujiWidth
            SetByteOrder(order)
            raf:Seek(tell, 0)
        end
        ::next::
        n = n + 1
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- write information to FujiFilm RAW file (RAF)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid RAF file, or -1 on write error
function FujiFilm.WriteRAF(et, dirInfo)
    local raf = dirInfo.RAF
    local hdr, jpeg, outJpeg, err, buff, n

    n, hdr = raf:Read(0x94)
    if n ~= 0x94 then return 0 end
    if not matches(hdr, '^FUJIFILM') then return 0 end
    local ver = substr(hdr, 0x3c, 4)
    if not (matches(ver, [[^\d{4}$]]) or testedRAF[ver]) then return 0 end

    -- get position and size of M-RAW header
    local mpos, mlen = unpack('x72NN', hdr)
    -- get the position and size of embedded JPEG
    local jpos, jlen = unpack('x84NN', hdr)
    -- check to be sure the JPEG starts in the expected location
    if (mpos > 0x94 or jpos > 0x94 + mlen) or jpos < 0x68 or (jpos & 0x03) ~= 0 then
        et:Error('Unsupported or corrupted RAF image (version ' .. ver .. ')')
        return 1
    end
    -- check to make sure this version of RAF has been tested
    --(removed in ExifTool 11.70)
    --unless ($testedRAF{$ver}) {
    --    $et->Warn("RAF version $ver not yet tested", 1);
    --}
    -- read the embedded JPEG
    if raf:Seek(jpos, 0) then n, jpeg = raf:Read(jlen) end
    if not (jpeg and n == jlen) then
        et:Error('Error reading RAF meta information')
        return 1
    end
    if mpos ~= 0 then
        if mlen ~= 0x11c then
            et:Error('Unsupported M-RAW header (please submit sample for testing)')
            return 1
        end
        -- read M-RAW header and add to file header
        local mraw
        if raf:Seek(mpos, 0) then n, mraw = raf:Read(mlen) end
        if not (mraw and n == mlen) then
            et:Error('Error reading M-RAW header')
            return 1
        end
        hdr = hdr .. mraw
        -- verify that the 1st raw image offset is zero, and that the 1st raw image
        -- length is the same as the 2nd raw image offset
        if not (substr(hdr, 0xc0, 8) == '\0\0\0\0\0\0\0\0' and
                substr(hdr, 0xc8, 8) == substr(hdr, 0x110, 8))
        then
            et:Error('Unexpected layout of M-RAW header')
            return 1
        end
    end
    -- use same write directories as JPEG
    Writer.InitWriteDirs(et, 'JPEG')
    -- rewrite the embedded JPEG in memory
    -- (`\$outJpeg` is the box { value = <carray> }, doc/api.md §4)
    outJpeg = carray.new('char')
    local jpegInfo = {
        Parent  = 'RAF',
        RAF     = RandomAccess.new(jpeg),
        OutFile = { value = outJpeg },
    }
    et.FILE_TYPE = 'JPEG'
    local success = et:WriteJPEG(jpegInfo)
    et.FILE_TYPE = 'RAF'
    if not (truthy(success) and truthy(outJpeg)) then
        et:Error('Invalid RAF format')
        return 1
    end
    if success < 0 then return -1 end

    -- rewrite the RAF image
    SetByteOrder('MM')
    local jpegLen = length(outJpeg)
    -- pad JPEG to an even 4 bytes (ALWAYS use padding as Fuji does)
    local pad = ('\0'):rep(4 - (jpegLen % 4))
    -- (Lua strings are immutable: the header becomes a mutable carray, which
    --  Set32u patches in place like upstream's `\$hdr`)
    local hdrStr = hdr
    hdr = carray.new('char')
    hdr:append(hdrStr)
    -- update JPEG size in header (size without padding)
    Set32u(hdr, 0x58, length(outJpeg))
    -- get pointer to start of the next RAF block
    local nextPtr = Get32u(hdr, 0x5c)
    -- determine the length of padding at the end of the original JPEG
    local oldPadLen = nextPtr - (jpos + jlen)
    if oldPadLen ~= 0 then
        local ok = not (oldPadLen > 1000000 or oldPadLen < 0) and raf:Seek(jpos + jlen, 0)
        if ok then n, buff = raf:Read(oldPadLen); ok = (n == oldPadLen) end
        if not ok then
            et:Error('Bad RAF pointer at 0x5c')
            return 1
        end
        -- make sure padding is only zero bytes (can be >100k for HS10)
        -- (have seen non-null padding in X-Pro1)
        if matches(buff, [==[[^\0]]==]) then
            if truthy(et:Error('Non-null bytes found in padding', 2)) then return 1 end
        end
    end
    -- calculate offset difference due to change in JPEG size
    local ptrDiff = length(outJpeg) + length(pad) - (jlen + oldPadLen)
    -- update necessary pointers in header (0xcc and higher in M-RAW header)
    for _, offset in ipairs({ 0x5c, 0x64, 0x78, 0x80, 0xcc, 0x114, 0x164 }) do
        if offset >= jpos then break end -- some versions have a short header
        local oldPtr = Get32u(hdr, offset)
        if oldPtr ~= 0 then             -- don't update if pointer is zero
            local newPtr = oldPtr + ptrDiff
            if newPtr < 0 or newPtr > 0xffffffff then
                if offset < 0xcc then et:Error('Invalid offset in RAF header') return 1 end
                -- assume values at 0xcc and greater are 8-byte integers (NC)
                -- and adjust high word if necessary
                local high = Get32u(hdr, offset - 4)
                if newPtr < 0 then
                    high = high - 1
                    newPtr = newPtr + 0xffffffff + 1
                    if high < 0 then et:Error('RAF header offset error') return 1 end
                else
                    high = high + 1
                    newPtr = newPtr - (0xffffffff + 1)
                end
                Set32u(hdr, offset - 4, high)
            end
            Set32u(hdr, offset, newPtr)
        end
    end
    -- write the new header
    local outfile = dirInfo.OutFile
    if not Write(outfile, substr(hdr, 0, jpos)) then err = 1 end
    -- write the updated JPEG plus padding
    if not Write(outfile, outJpeg, pad) then err = 1 end
    -- copy over the rest of the RAF image
    if not raf:Seek(nextPtr, 0) then
        et:Error('Error reading RAF image')
        return 1
    end
    while true do
        n, buff = raf:Read(65536)
        if n == 0 then break end
        if not Write(outfile, buff) then err = 1 break end
    end
    return err and -1 or 1
end

--------------------------------------------------------------------------------
-- get information from FujiFilm RAW file (RAF)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 if this was a valid RAF file
function FujiFilm.ProcessRAF(et, dirInfo)
    local buff, jpeg, warn, n

    local raf = dirInfo.RAF
    local base = dirInfo.Base or 0
    n, buff = raf:Read(0x70)
    if n ~= 0x70 then return 0 end
    if not matches(buff, '^FUJIFILM') then return 0 end
    -- get position and size of M-RAW header and jpeg preview
    local mpos, mlen = unpack('x72NN', buff) -- luacheck: ignore 211 (mpos unused, as upstream)
    local jpos, jlen = unpack('x84NN', buff)
    if (jpos & 0x8000) ~= 0 then return 0 end
    if jpos ~= 0 then
        if not raf:Seek(jpos + base, 0) then return 0 end
        n, jpeg = raf:Read(jlen)
        if n ~= jlen then return 0 end
    end
    SetByteOrder('MM')
    if not truthy(et.DOC_NUM) then et:SetFileType() end
    local tbl = et:GetTagTable('lexiftool.FujiFilm.RAFHeader')
    et:ProcessDirectory({ DataPt = buff, DirName = 'RAFHeader', Base = base }, tbl)

    -- extract information from embedded JPEG
    local dirInfo_ = {
        Parent = 'RAF',
        RAF    = RandomAccess.new(jpeg),
    }
    if jpos ~= 0 then
        et.BASE = (et.BASE or 0) + jpos + base
        local ok = et:ProcessJPEG(dirInfo_)
        et.BASE = et.BASE - (jpos + base)
        if truthy(ok) then et:FoundTag('PreviewImage', { ref = 'SCALAR', value = jpeg }) end
    end
    -- extract information from Fuji RAF and TIFF directories
    local rafNum, ifdNum = '', ''
    for _, offset in ipairs({ 0x48, 0x5c, 0x64, 0x78, 0x80 }) do
        if jpos ~= 0 and offset >= jpos then break end
        local ok = raf:Seek(offset + base, 0)
        if ok then n, buff = raf:Read(8); ok = (n ~= 0) end
        if not ok then
            warn = 1
            break
        end
        local start, len = unpack('N2', buff)
        if start == 0 then goto next end
        start = start + base
        if offset == 0x64 or offset == 0x80 then
            -- parse FujiIFD directory
            dirInfo_ = {
                RAF  = raf,
                Base = start,
            }
            et.SET_GROUP1 = 'FujiIFD' .. ifdNum
            local tagTablePtr = et:GetTagTable('lexiftool.FujiFilm.IFD')
            -- this is TIFF-format data only for some models, so no warning if it fails
            if not truthy(et:ProcessTIFF(dirInfo_, tagTablePtr, ExifTool.ProcessTIFF)) then
                -- do hash of image data if necessary
                if rawget(et, 'ImageDataHash') and raf:Seek(start, 0) then et:ImageDataHash(raf, len, 'raw') end
            end
            et.SET_GROUP1 = nil
            ifdNum = (truthy(ifdNum) and ifdNum or 1) + 1
        elseif offset == 0x48 then
            et.VALUE.FileType = et.VALUE.FileType .. ' (M-RAW)'
            local n2
            if raf:Seek(start, 0) then n2, buff = raf:Read(mlen) end
            if n2 == mlen then
                local tbl_ = et:GetTagTable('lexiftool.FujiFilm.MRAW')
                et:ProcessDirectory({ DataPt = buff, DataPos = start, DirName = 'M-RAW' }, tbl_)
            else
                et:Warn('Error reading M-RAW header')
            end
        else
            -- parse RAF directory
            dirInfo_ = {
                RAF      = raf,
                DirStart = start,
            }
            et.SET_GROUP1 = 'RAF' .. rafNum
            local tagTablePtr = et:GetTagTable('lexiftool.FujiFilm.RAF')
            if truthy(et:ProcessDirectory(dirInfo_, tagTablePtr)) then
                rafNum = (truthy(rafNum) and rafNum or 1) + 1
            else
                warn = 1
            end
            et.SET_GROUP1 = nil
        end
        ::next::
    end
    if warn then et:Warn('Possibly corrupt RAF information') end

    return 1
end

FujiFilm.FaceRecInfo.PROCESS_PROC = FujiFilm.ProcessFaceRec
FujiFilm.RAF.PROCESS_PROC = FujiFilm.ProcessFujiDir
FujiFilm.MRAW.PROCESS_PROC = FujiFilm.ProcessMRAW

return FujiFilm
