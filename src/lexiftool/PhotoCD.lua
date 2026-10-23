--------------------------------------------------------------------------------
-- File:         lexiftool/PhotoCD.lua
-- Ported from:  lib/Image/ExifTool/PhotoCD.pm
--
-- Description:  Read Kodak Photo CD Image Pac (PCD) metadata
--
-- Revisions:    2012/05/07 - P. Harvey Created
--
-- References:   1) http://pcdtojpeg.sourceforge.net/
--
-- Port notes:   complete: ProcessPCD (the seek-to-2048 + 2048-byte read +
--               `PCD_IPI` signature check) and the Main table (with the
--               HasSBA/CopyrightStatus-gated entries and the Mask-based
--               Orientation/ImageWidth/ImageHeight/CompressionClass group at
--               offset 1538).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local str = require('lexiftool.perl').str

local PhotoCD = {}

-- PhotoCD info (upstream %Image::ExifTool::PhotoCD::Main)
PhotoCD.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'Tags extracted from Kodak Photo CD Image Pac (PCD) files.',
    [7] = {
        Name = 'SpecificationVersion',
        Format = 'int8u[2]',
        RawConv = function(_self, val) if str(val) == '255 255' then return 'n/a' end return val end,
        ValueConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [9] = {
        Name = 'AuthoringSoftwareRelease',
        Format = 'int8u[2]',
        RawConv = function(_self, val) if str(val) == '255 255' then return 'n/a' end return val end,
        ValueConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [11] = {
        Name = 'ImageMagnificationDescriptor',
        Format = 'int8u[2]',
        ValueConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [13] = {
        Name = 'CreateDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        RawConv = function(_self, val) if val == 0xffffffff then return nil end return val end,
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [17] = {
        Name = 'ModifyDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        RawConv = function(_self, val) if val == 0xffffffff then return nil end return val end,
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [21] = {
        Name = 'ImageMedium',
        PrintConv = {
            [0] = 'Color negative',
            [1] = 'Color reversal',
            [2] = 'Color hard copy',
            [3] = 'Thermal hard copy',
            [4] = 'Black and white negative',
            [5] = 'Black and white reversal',
            [6] = 'Black and white hard copy',
            [7] = 'Internegative',
            [8] = 'Synthetic image',
        },
    },
    [22] = {
        Name = 'ProductType',
        Format = 'string[20]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [42] = {
        Name = 'ScannerVendorID',
        Format = 'string[20]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [62] = {
        Name = 'ScannerProductID',
        Format = 'string[16]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [78] = {
        Name = 'ScannerFirmwareVersion',
        Format = 'string[4]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [82] = {
        Name = 'ScannerFirmwareDate',
        Format = 'string[8]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [90] = {
        Name = 'ScannerSerialNumber',
        Format = 'string[20]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [110] = {
        Name = 'ScannerPixelSize',
        Format = 'undef[2]',
        ValueConv = function(_self, val)
            -- (upstream `join(".",unpack("H2H2",$val))`)
            return string.format('%02x.%02x', val:byte(1), val:byte(2))
        end,
        PrintConv = function(_self, val) return str(val) .. ' micrometers' end,
    },
    [112] = {
        Name = 'ImageWorkstationMake',
        Format = 'string[20]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [132] = {
        Name = 'CharacterSet',
        PrintConv = {
            [1] = '38 characters ISO 646',
            [2] = '65 characters ISO 646',
            [3] = '95 characters ISO 646',
            [4] = '191 characters ISO 8850-1',
            [5] = 'ISO 2022',
            [6] = 'Includes characters not ISO 2375 registered',
        },
    },
    [133] = {
        Name = 'CharacterEscapeSequence',
        Format = 'undef[32]',
        Binary = 1,
        Unknown = 1,
    },
    [165] = {
        Name = 'PhotoFinisherName',
        Format = 'string[60]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [225] = {
        Name = 'HasSBA',
        Format = 'undef[3]',
        Hidden = 1,
        RawConv = function(self, val)
            if str(val) == 'SBA' then self.HasSBA = 1 end
            return nil
        end,
    },
    [228] = {
        Name = 'SceneBalanceAlgorithmRevision',
        Condition = function(self) return self.HasSBA end,
        Format = 'int8u[2]',
        ValueConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [230] = {
        Name = 'SceneBalanceAlgorithmCommand',
        Condition = function(self) return self.HasSBA end,
        PrintConv = {
            [0] = 'Neutral SBA On, Color SBA On',
            [1] = 'Neutral SBA Off, Color SBA Off',
            [2] = 'Neutral SBA On, Color SBA Off',
            [3] = 'Neutral SBA Off, Color SBA On',
        },
    },
    [325] = {
        Name = 'SceneBalanceAlgorithmFilmID',
        Condition = function(self) return self.HasSBA end,
        Format = 'int16u',
        PrintConv = {
            [1] = '3M ScotchColor AT 100',
            [2] = '3M ScotchColor AT 200',
            [3] = '3M ScotchColor HR2 400',
            [7] = '3M Scotch HR 200 Gen 2',
            [9] = '3M Scotch HR 400 Gen 2',
            [16] = 'Agfa Agfacolor XRS 400 Gen 1',
            [17] = 'Agfa Agfacolor XRG/XRS 400',
            [18] = 'Agfa Agfacolor XRG/XRS 200',
            [19] = 'Agfa Agfacolor XRS 1000 Gen 2',
            [20] = 'Agfa Agfacolor XRS 400 Gen 2',
            [21] = 'Agfa Agfacolor XRS/XRC 100',
            [26] = 'Fuji Reala 100 (JAPAN)',
            [27] = 'Fuji Reala 100 Gen 1',
            [28] = 'Fuji Reala 100 Gen 2',
            [29] = 'Fuji SHR 400 Gen 2',
            [30] = 'Fuji Super HG 100',
            [31] = 'Fuji Super HG 1600 Gen 1',
            [32] = 'Fuji Super HG 200',
            [33] = 'Fuji Super HG 400',
            [34] = 'Fuji Super HG 100 Gen 2',
            [35] = 'Fuji Super HR 100 Gen 1',
            [36] = 'Fuji Super HR 100 Gen 2',
            [37] = 'Fuji Super HR 1600 Gen 2',
            [38] = 'Fuji Super HR 200 Gen 1',
            [39] = 'Fuji Super HR 200 Gen 2',
            [40] = 'Fuji Super HR 400 Gen 1',
            [43] = 'Fuji NSP 160S (Pro)',
            [45] = 'Kodak Kodacolor VR 100 Gen 2',
            [47] = 'Kodak Gold 400 Gen 3',
            [55] = 'Kodak Ektar 100 Gen 1',
            [56] = 'Kodak Ektar 1000 Gen 1',
            [57] = 'Kodak Ektar 125 Gen 1',
            [58] = 'Kodak Royal Gold 25 RZ',
            [60] = 'Kodak Gold 1600 Gen 1',
            [61] = 'Kodak Gold 200 Gen 2',
            [62] = 'Kodak Gold 400 Gen 2',
            [65] = 'Kodak Kodacolor VR 100 Gen 1',
            [66] = 'Kodak Kodacolor VR 1000 Gen 2',
            [67] = 'Kodak Kodacolor VR 1000 Gen 1',
            [68] = 'Kodak Kodacolor VR 200 Gen 1',
            [69] = 'Kodak Kodacolor VR 400 Gen 1',
            [70] = 'Kodak Kodacolor VR 200 Gen 2',
            [71] = 'Kodak Kodacolor VRG 100 Gen 1',
            [72] = 'Kodak Gold 100 Gen 2',
            [73] = 'Kodak Kodacolor VRG 200 Gen 1',
            [74] = 'Kodak Gold 400 Gen 1',
            [87] = 'Kodak Ektacolor Gold 160',
            [88] = 'Kodak Ektapress 1600 Gen 1 PPC',
            [89] = 'Kodak Ektapress Gold 100 Gen 1 PPA',
            [90] = 'Kodak Ektapress Gold 400 PPB-3',
            [92] = 'Kodak Ektar 25 Professional PHR',
            [97] = 'Kodak T-Max 100 Professional',
            [98] = 'Kodak T-Max 3200 Professional',
            [99] = 'Kodak T-Max 400 Professional',
            [101] = 'Kodak Vericolor 400 Prof VPH',
            [102] = 'Kodak Vericolor III Pro',
            [121] = 'Konika Konica Color SR-G 3200',
            [122] = 'Konika Konica Color Super SR100',
            [123] = 'Konika Konica Color Super SR 400',
            [138] = 'Kodak Gold Unknown',
            [139] = 'Kodak Unknown Neg A- Normal SBA',
            [143] = 'Kodak Ektar 100 Gen 2',
            [147] = 'Kodak Kodacolor CII',
            [148] = 'Kodak Kodacolor II',
            [149] = 'Kodak Gold Plus 200 Gen 3',
            [150] = 'Kodak Internegative +10% Contrast',
            [151] = 'Agfa Agfacolor Ultra 50',
            [152] = 'Fuji NHG 400',
            [153] = 'Agfa Agfacolor XRG 100',
            [154] = 'Kodak Gold Plus 100 Gen 3',
            [155] = 'Konika Konica Color Super SR200 Gen 1',
            [156] = 'Konika Konica Color SR-G 160',
            [157] = 'Agfa Agfacolor Optima 125',
            [158] = 'Agfa Agfacolor Portrait 160',
            [162] = 'Kodak Kodacolor VRG 400 Gen 1',
            [163] = 'Kodak Gold 200 Gen 1',
            [164] = 'Kodak Kodacolor VRG 100 Gen 2',
            [174] = 'Kodak Internegative +20% Contrast',
            [175] = 'Kodak Internegative +30% Contrast',
            [176] = 'Kodak Internegative +40% Contrast',
            [184] = 'Kodak TMax-100 D-76 CI = .40',
            [185] = 'Kodak TMax-100 D-76 CI = .50',
            [186] = 'Kodak TMax-100 D-76 CI = .55',
            [187] = 'Kodak TMax-100 D-76 CI = .70',
            [188] = 'Kodak TMax-100 D-76 CI = .80',
            [189] = 'Kodak TMax-100 TMax CI = .40',
            [190] = 'Kodak TMax-100 TMax CI = .50',
            [191] = 'Kodak TMax-100 TMax CI = .55',
            [192] = 'Kodak TMax-100 TMax CI = .70',
            [193] = 'Kodak TMax-100 TMax CI = .80',
            [195] = 'Kodak TMax-400 D-76 CI = .40',
            [196] = 'Kodak TMax-400 D-76 CI = .50',
            [197] = 'Kodak TMax-400 D-76 CI = .55',
            [198] = 'Kodak TMax-400 D-76 CI = .70',
            [214] = 'Kodak TMax-400 D-76 CI = .80',
            [215] = 'Kodak TMax-400 TMax CI = .40',
            [216] = 'Kodak TMax-400 TMax CI = .50',
            [217] = 'Kodak TMax-400 TMax CI = .55',
            [218] = 'Kodak TMax-400 TMax CI = .70',
            [219] = 'Kodak TMax-400 TMax CI = .80',
            [224] = '3M ScotchColor ATG 400/EXL 400',
            [266] = 'Agfa Agfacolor Optima 200',
            [267] = 'Konika Impressa 50',
            [268] = 'Polaroid Polaroid CP 200',
            [269] = 'Konika Konica Color Super SR200 Gen 2',
            [270] = 'ILFORD XP2 400',
            [271] = 'Polaroid Polaroid Color HD2 100',
            [272] = 'Polaroid Polaroid Color HD2 400',
            [273] = 'Polaroid Polaroid Color HD2 200',
            [282] = '3M ScotchColor ATG-1 200',
            [284] = 'Konika XG 400',
            [307] = 'Kodak Universal Reversal B/W',
            [308] = 'Kodak RPC Copy Film Gen 1',
            [312] = 'Kodak Universal E6',
            [324] = 'Kodak Gold Ultra 400 Gen 4',
            [328] = 'Fuji Super G 100',
            [329] = 'Fuji Super G 200',
            [330] = 'Fuji Super G 400 Gen 2',
            [333] = 'Kodak Universal K14',
            [334] = 'Fuji Super G 400 Gen 1',
            [366] = 'Kodak Vericolor HC 6329 VHC',
            [367] = 'Kodak Vericolor HC 4329 VHC',
            [368] = 'Kodak Vericolor L 6013 VPL',
            [369] = 'Kodak Vericolor L 4013 VPL',
            [418] = 'Kodak Ektacolor Gold II 400 Prof',
            [430] = 'Kodak Royal Gold 1000',
            [431] = 'Kodak Kodacolor VR 200 / 5093',
            [432] = 'Kodak Gold Plus 100 Gen 4',
            [443] = 'Kodak Royal Gold 100',
            [444] = 'Kodak Royal Gold 400',
            [445] = 'Kodak Universal E6 auto-balance',
            [446] = 'Kodak Universal E6 illum. corr.',
            [447] = 'Kodak Universal K14 auto-balance',
            [448] = 'Kodak Universal K14 illum. corr.',
            [449] = 'Kodak Ektar 100 Gen 3 SY',
            [456] = 'Kodak Ektar 25',
            [457] = 'Kodak Ektar 100 Gen 3 CX',
            [458] = 'Kodak Ektapress Plus 100 Prof PJA-1',
            [459] = 'Kodak Ektapress Gold II 100 Prof',
            [460] = 'Kodak Pro 100 PRN',
            [461] = 'Kodak Vericolor HC 100 Prof VHC-2',
            [462] = 'Kodak Prof Color Neg 100',
            [463] = 'Kodak Ektar 1000 Gen 2',
            [464] = 'Kodak Ektapress Plus 1600 Pro PJC-1',
            [465] = 'Kodak Ektapress Gold II 1600 Prof',
            [466] = 'Kodak Super Gold 1600 GF Gen 2',
            [467] = 'Kodak Kodacolor 100 Print Gen 4',
            [468] = 'Kodak Super Gold 100 Gen 4',
            [469] = 'Kodak Gold 100 Gen 4',
            [470] = 'Kodak Gold III 100 Gen 4',
            [471] = 'Kodak Funtime 100 FA',
            [472] = 'Kodak Funtime 200 FB',
            [473] = 'Kodak Kodacolor VR 200 Gen 4',
            [474] = 'Kodak Gold Super 200 Gen 4',
            [475] = 'Kodak Kodacolor 200 Print Gen 4',
            [476] = 'Kodak Super Gold 200 Gen 4',
            [477] = 'Kodak Gold 200 Gen 4',
            [478] = 'Kodak Gold III 200 Gen 4',
            [479] = 'Kodak Gold Ultra 400 Gen 5',
            [480] = 'Kodak Super Gold 400 Gen 5',
            [481] = 'Kodak Gold 400 Gen 5',
            [482] = 'Kodak Gold III 400 Gen 5',
            [483] = 'Kodak Kodacolor 400 Print Gen 5',
            [484] = 'Kodak Ektapress Plus 400 Prof PJB-2',
            [485] = 'Kodak Ektapress Gold II 400 Prof G5',
            [486] = 'Kodak Pro 400 PPF-2',
            [487] = 'Kodak Ektacolor Gold II 400 EGP-4',
            [488] = 'Kodak Ektacolor Gold 400 Prof EGP-4',
            [489] = 'Kodak Ektapress Gold II Multspd PJM',
            [490] = 'Kodak Pro 400 MC PMC',
            [491] = 'Kodak Vericolor 400 Prof VPH-2',
            [492] = 'Kodak Vericolor 400 Plus Prof VPH-2',
            [493] = 'Kodak Unknown Neg Product Code 83',
            [505] = 'Kodak Ektacolor Pro Gold 160 GPX',
            [508] = 'Kodak Royal Gold 200',
            [517] = 'Kodak 4050000000',
            [519] = 'Kodak Gold Plus 100 Gen 5',
            [520] = 'Kodak Gold 800 Gen 1',
            [521] = 'Kodak Gold Super 200 Gen 5',
            [522] = 'Kodak Ektapress Plus 200 Prof',
            [523] = 'Kodak 4050 E6 auto-balance',
            [524] = 'Kodak 4050 E6 ilum. corr.',
            [525] = 'Kodak 4050 K14',
            [526] = 'Kodak 4050 K14 auto-balance',
            [527] = 'Kodak 4050 K14 ilum. corr.',
            [528] = 'Kodak 4050 Reversal B&W',
            [532] = 'Kodak Advantix 200',
            [533] = 'Kodak Advantix 400',
            [534] = 'Kodak Advantix 100',
            [535] = 'Kodak Ektapress Multspd Prof PJM-2',
            [536] = 'Kodak Kodacolor VR 200 Gen 5',
            [537] = 'Kodak Funtime 200 FB Gen 2',
            [538] = 'Kodak Commercial 200',
            [539] = 'Kodak Royal Gold 25 Copystand',
            [540] = 'Kodak Kodacolor DA 100 Gen 5',
            [545] = 'Kodak Kodacolor VR 400 Gen 2',
            [546] = 'Kodak Gold 100 Gen 6',
            [547] = 'Kodak Gold 200 Gen 6',
            [548] = 'Kodak Gold 400 Gen 6',
            [549] = 'Kodak Royal Gold 100 Gen 2',
            [550] = 'Kodak Royal Gold 200 Gen 2',
            [551] = 'Kodak Royal Gold 400 Gen 2',
            [552] = 'Kodak Gold Max 800 Gen 2',
            [554] = 'Kodak 4050 E6 high contrast',
            [555] = 'Kodak 4050 E6 low saturation high contrast',
            [556] = 'Kodak 4050 E6 low saturation',
            [557] = 'Kodak Universal E-6 Low Saturation',
            [558] = 'Kodak T-Max T400 CN',
            [563] = 'Kodak Ektapress PJ100',
            [564] = 'Kodak Ektapress PJ400',
            [565] = 'Kodak Ektapress PJ800',
            [567] = 'Kodak Portra 160NC',
            [568] = 'Kodak Portra 160VC',
            [569] = 'Kodak Portra 400NC',
            [570] = 'Kodak Portra 400VC',
            [575] = 'Kodak Advantix 100-2',
            [576] = 'Kodak Advantix 200-2',
            [577] = 'Kodak Advantix Black & White + 400',
            [578] = 'Kodak Ektapress PJ800-2',
        },
    },
    [331] = {
        Name = 'CopyrightStatus',
        Condition = function(self) return self.HasSBA end,
        RawConv = function(self, val) self.CopyrightStatus = val return val end,
        PrintConv = {
            [1] = 'Restrictions apply',
            [0xff] = 'Not specified',
        },
    },
    [332] = {
        Name = 'CopyrightFileName',
        Condition = function(self) return self.CopyrightStatus and self.CopyrightStatus == 1 end,
        Format = 'string[12]',
        ValueConv = function(_self, val) return (str(val):gsub('[ \0]+$', '')) end,
    },
    [1538] = {
        Name = 'Orientation',
        Mask = 0x03,
        RawConv = function(self, val) self.Orient = val return val end,
        PrintConv = {
            [0] = 'Horizontal (normal)',
            [1] = 'Rotate 270 CW',
            [2] = 'Rotate 180',
            [3] = 'Rotate 90 CW',
        },
    },
    ['1538.1'] = {
        Name = 'ImageWidth',
        Mask = 0x0c,
        -- 0=Base (768x512), 1=4Base (1536x1024), 2=16Base (3072x2048)
        ValueConv = function(self, val)
            local orient = self.Orient or 0
            local base = (orient & 0x01) ~= 0 and 512 or 768
            return base * ((val * 2) or 1)
        end,
    },
    ['1538.2'] = {
        Name = 'ImageHeight',
        Mask = 0x0c,
        ValueConv = function(self, val)
            local orient = self.Orient or 0
            local base = (orient & 0x01) ~= 0 and 768 or 512
            return base * ((val * 2) or 1)
        end,
    },
    ['1538.3'] = {
        Name = 'CompressionClass',
        Mask = 0x60,
        PrintConv = {
            [0] = 'Class 1 - 35mm film; Pictoral hard copy',
            [1] = 'Class 2 - Large format film',
            [2] = 'Class 3 - Text and graphics, high resolution',
            [3] = 'Class 4 - Text and graphics, high dynamic range',
        },
    },
    -- 1544 => 'InterleaveRatio',
    -- 1545 => 'ADPCMResolution',
    -- 1546 => 'ADPCMMagnificationPanning',
    -- 1548 => 'ADPCMMagnificationFactor',
    -- 1549 => 'ADPCMDisplayOffset',
    -- 1551 => 'ADPCMTransitionDescriptor',
}

--------------------------------------------------------------------------------
-- Extract information from a PhotoCD image (upstream ProcessPCD)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PhotoCD file
--------------------------------------------------------------------------------
function PhotoCD.ProcessPCD(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff
    if raf:Seek(2048, 0) then
        n, buff = raf:Read(2048)
    end
    if n ~= 2048 or buff:sub(1, 7) ~= 'PCD_IPI' then return 0 end
    ExifTool.SetByteOrder('MM')
    et:SetFileType()
    local d = {
        DirName = 'PhotoCD',
        DataPt = buff,
        DataPos = 4096,
    }
    local tagTablePtr = et:GetTagTable('lexiftool.PhotoCD.Main')
    return ExifTool.ProcessBinaryData(et, d, tagTablePtr)
end

return PhotoCD