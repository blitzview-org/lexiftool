--------------------------------------------------------------------------------
-- File:         lexiftool/JPEG.lua
-- Ported from:  lib/Image/ExifTool/JPEG.pm
--
-- Description:  Definitions for uncommon JPEG segments
--
-- Revisions:    10/06/2006 - P. Harvey Created
--
-- Port notes:   all tables and procs of JPEG.pm (the order of the tables
--               after `Main`/`HDRGainInfo` differs from upstream).  As
--               upstream, `Main` is mostly documentation: ProcessJPEG (main
--               module) dispatches the segments itself and looks `Main` up
--               only where upstream does -- HandleTag for APP1 Parrot, APP3
--               InfiRay/DJI, APP5 DJI, APP6 DTAT and the `$useJpegMain`
--               segments (APP2 "urn:", APP10 "AROT" -> `HDRGainInfo`).  Its
--               (defaulted) group names are also what ProcessDirectory takes
--               the directory name from when a SubDirectory names it
--               (PanasonicRaw's JpgFromRaw), and its SubDirectory entries are
--               how Writer's LoadAllTables reaches JFIF, APP12::Ducky,
--               CanonVRD and the rest.  `yCbCrSubSampling` and `SOF` live in
--               ExifTool.pm upstream and are kept here.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local valueCondition = ExifTool.valueCondition
local substr = require('lexiftool.perl').substr
local isMatch = require('lexiftool.perl').isMatch
local eachMatch = require('lexiftool.perl').eachMatch
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str
local split = require('lexiftool.perl').split
local num = require('lexiftool.perl').num
local JPEG = {}

-- (most of the tags in this table are for documentation purposes only)
JPEG.Main = {
    NOTES = [[
        This table lists information extracted by ExifTool from JPEG images. See
        L<https://www.w3.org/Graphics/JPEG/jfif3.pdf> for the JPEG specification.
    ]],
    APP0 = {{
        Name = 'JFIF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^JFIF\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.JFIF.Main' },
      }, {
        Name = 'JFXX',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^JFXX\0\x10]]) end),
        SubDirectory = { TagTable = 'lexiftool.JFIF.Extension' },
      }, {
        Name = 'CIFF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)^(II|MM).{4}HEAPJPGM]]) end),
        SubDirectory = { TagTable = 'lexiftool.CanonRaw.Main' },
      }, {
        Name = 'AVI1',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^AVI1]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.AVI1' },
      }, {
        Name = 'Ocad',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Ocad]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.Ocad' },
    }},
    APP1 = {{
        Name = 'EXIF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Exif\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Exif.Main' },
      }, {
        Name = 'ExtendedXMP',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^http://ns.adobe.com/xmp/extension/\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
      }, {
        Name = 'XMP',
        Condition = valueCondition(function(_self, val)
            return isMatch(str(val), [[^http]]) or isMatch(str(val), [[<exif:]])
        end),
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
      }, {
        Name = 'QVCI',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^QVCI\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Casio.QVCI' },
      }, {
        Name = 'FLIR',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^FLIR\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.FLIR.FFF' },
      }, {
        Name = 'RawThermalImage', -- (from Parrot Bebop-Pro Thermal drone)
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^PARROT\0(II\x2a\0|MM\0\x2a)]]) end),
        Groups = { [0] = 'APP1', [1] = 'Parrot', [2] = 'Preview' },
        Notes = 'thermal image from Parrot Bebop-Pro Thermal drone',
        RawConv = function(_self, val) return substr(val, 7) end,
        Binary = 1,
    }},
    APP2 = {{
        Name = 'ICC_Profile',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^ICC_PROFILE\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
      }, {
        Name = 'FPXR',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^FPXR\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.FlashPix.Main' },
      }, {
        Name = 'MPF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^MPF\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.MPF.Main' },
      }, {
        Name = 'InfiRayVersion',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)^....IJPEG\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Version' },
      }, {
        Name = 'UniformResourceName',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^urn:]]) end),
        Groups = { [1] = 'APP2' },
        Notes = 'used in Apple HDR images',
      }, {
        Name = 'PreviewImage',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)^(|QVGA\0|BGTH|XMTH.{5})\xff\xd8]]) end),
        -- (Samsung/GoPro="", BenQ="QVGA\0", Digilife="BGTH", Xiaomi="XMTH.{5})
        -- (Xiaomi preview is in APP2 of Xiaomi HEIC EXIF data)
        Groups = { [1] = 'APP2', [2] = 'Preview' },
        Notes = 'APP2 preview image',
    }},
    APP3 = {{
        Name = 'Meta',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^(Meta|META|Exif)\0\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Kodak.Meta' },
      }, {
        Name = 'Stim',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Stim\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Stim.Main' },
      }, {
        Name = 'JPS',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^_JPSJPS_]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.JPS' },
      }, {
        Name = 'ThermalData', -- (written by DJI FLIR models)
        Condition = function(self) return self.Make == 'DJI' end,
        Notes = 'DJI raw thermal data',
        Groups = { [0] = 'APP3', [1] = 'DJI', [2] = 'Image' },
        Binary = 1,
      }, {
        Name = 'ImagingData', -- (written by InfiRay models)
        Condition = function(self) return self.HasIJPEG end,
        Notes = 'InfiRay IR+thermal+visible data',
        Groups = { [0] = 'APP3', [1] = 'InfiRay', [2] = 'Image' },
        Binary = 1,
      }, {
        Name = 'PreviewImage', -- (written by HP R837 and Samsung S1060)
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^\xff\xd8\xff\xdb]]) end),
        Notes = 'Samsung/HP preview image', -- (Samsung, HP, BenQ)
    }},
    APP4 = {{
        Name = 'Scalado',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^SCALADO\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Scalado.Main' },
      }, {
        Name = 'FPXR', -- (non-standard location written by some HP models)
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^FPXR\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.FlashPix.Main' },
      }, {
        Name = 'QualcommDualCamera',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Qualcomm Dual Camera Attributes]]) end),
        SubDirectory = { TagTable = 'lexiftool.Qualcomm.DualCamera' },
      }, {
        Name = 'InfiRayFactory',
        -- (upstream's Condition string is '$$self{HasIJPEG}"' -- the trailing
        --  quote is an upstream typo, and there is nothing to carry over here)
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Factory' },
      }, {
        Name = 'ThermalParams', -- (written by some DJI FLIR models)
        Condition = valueCondition(function(self, val)
            return self.Make == 'DJI' and isMatch(str(val), [[^\xaa\x55\x12\x06]])
        end),
        SubDirectory = { TagTable = 'lexiftool.DJI.ThermalParams' },
      }, {
        Name = 'ThermalParams2', -- (written by M3T)
        Condition = valueCondition(function(self, val)
            return self.Make == 'DJI' and isMatch(str(val), [[(?s)^(.{32})?.{32}\x2c\x01\x20\0]])
        end),
        SubDirectory = { TagTable = 'lexiftool.DJI.ThermalParams2' },
      }, {
        Name = 'ThermalParams3', -- (written by M30T)
        Condition = valueCondition(function(self, val)
            return self.Make == 'DJI' and isMatch(str(val), [[(?s)^.{32}\xaa\x55\x38\0]])
        end),
        SubDirectory = { TagTable = 'lexiftool.DJI.ThermalParams3' },
      }, {
        Name = 'PreviewImage', -- (eg. Samsung S1060)
        Notes = 'continued from APP3',
    }},
    APP5 = {{
        Name = 'RMETA',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^RMETA\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Ricoh.RMETA' },
      }, {
        Name = 'SamsungUniqueID',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[ssuniqueid\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Samsung.APP5' },
      }, {
        Name = 'InfiRayPicture',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Picture' },
      }, {
        Name = 'ThermalCalibration', -- (written by DJI FLIR models)
        Condition = function(self) return self.Make == 'DJI' end,
        Notes = 'DJI thermal calibration data',
        Groups = { [0] = 'APP5', [1] = 'DJI', [2] = 'Image' },
        Binary = 1,
      }, {
        Name = 'PreviewImage', -- (eg. BenQ DC E1050)
        Notes = 'continued from APP4',
    }},
    APP6 = {{
        Name = 'EPPIM',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^EPPIM\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.EPPIM' },
      }, {
        Name = 'NITF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^NTIF\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.NITF' },
      }, {
        Name = 'HP_TDHD', -- (written by R837)
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^TDHD\x01\0\0\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.HP.TDHD' },
      }, {
        Name = 'GoPro',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^GoPro\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPMF' },
      }, {
        Name = 'InfiRayMixMode',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.MixMode' },
      }, {
        Name = 'DJI_DTAT', -- (written by ZH20T)
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)^DTAT\0\0.\{]]) end),
        Groups = { [0] = 'APP6', [1] = 'DJI' },
        Notes = 'DJI Thermal Analysis Tool record',
        ValueConv = function(_self, val) return substr(val, 7) end,
      -- also seen Motorola APP6 "MMIMETA\0", with sub-types: AL3A,ALED,MMI0,MOTD,QC3A,LMB1
    }},
    APP7 = {{
        Name = 'Pentax',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^PENTAX \0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Pentax.Main' },
      }, {
        Name = 'Ricoh',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^RICOH\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Pentax.Main' },
      }, {
        Name = 'Huawei',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^HUAWEI\0\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.Unknown.Main' },
      }, {
        Name = 'Qualcomm',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^\x1aQualcomm Camera Attributes]]) end),
        SubDirectory = { TagTable = 'lexiftool.Qualcomm.Main' },
      }, {
        Name = 'InfiRayOpMode',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.OpMode' },
      }, {
        Name = 'DJI-DBG',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^DJI-DBG\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.DJI.Info' },
    }},
    APP8 = {{
        Name = 'SPIFF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^SPIFF\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.SPIFF' },
      }, {
        Name = 'InfiRayIsothermal',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Isothermal' },
      }, {
        Name = 'SEAL',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^SEAL\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    }},
    APP9 = {{
        Name = 'MediaJukebox',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Media Jukebox\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.MediaJukebox' },
      }, {
        Name = 'InfiRaySensor',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Sensor' },
      }, {
        Name = 'SEAL',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^SEAL\0]]) end),
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    }},
    APP10 = {{
        Name = 'Comment',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^UNICODE\0]]) end),
        Notes = 'PhotoStudio Unicode comment',
      }, {
        Name = 'HDRGainInfo', -- #PH (NC)
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)^AROT\0\0.{4}]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.HDRGainInfo' },
    }},
    APP11 = {{
        Name = 'JPEG-HDR',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^HDR_RI ]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.HDR' },
      }, {
        Name = 'JUMBF',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^JP]]) end),
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main' },
        -- Note: The suggested options for reading C2PA CAI JUMBF metadata are "-G3 -b -j -u"
    }},
    APP12 = {{
        Name = 'PictureInfo',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(\[picture info\]|Type=)]]) end),
        SubDirectory = { TagTable = 'lexiftool.APP12.PictureInfo' },
      }, {
        Name = 'Ducky',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Ducky]]) end),
        SubDirectory = { TagTable = 'lexiftool.APP12.Ducky' },
    }},
    APP13 = {{
        Name = 'Photoshop',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^(Photoshop 3.0\0|Adobe_Photoshop2.5)]]) end),
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Main' },
    }, {
        Name = 'Adobe_CM',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Adobe_CM]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.AdobeCM' },
    }},
    APP14 = {
        Name = 'Adobe',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Adobe]]) end),
        Writable = 2,  -- (for docs only)
        SubDirectory = { TagTable = 'lexiftool.JPEG.Adobe' },
    },
    APP15 = {
        Name = 'GraphicConverter',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^Q\s*(\d+)]]) end),
        SubDirectory = { TagTable = 'lexiftool.JPEG.GraphConv' },
    },
    -- APP15 - Also unknown "TEXT\0" segment stored by Casio/FujiFilm
    COM = {
        Name = 'Comment',
        -- note: flag as writable for documentation, but it won't show up
        -- in the TagLookup as writable because there is no WRITE_PROC
        Writable = 2,
    },
    SOF = {
        Name = 'StartOfFrame',
        SubDirectory = { TagTable = 'lexiftool.JPEG.SOF' },
    },
    DQT = {
        Name = 'DefineQuantizationTable',
        Notes = 'used to calculate the Extra JPEGDigest tag value',
    },
    Trailer = {{
        Name = 'AFCP',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)AXS(!|\*).{8}$]]) end),
        SubDirectory = { TagTable = 'lexiftool.AFCP.Main' },
      }, {
        Name = 'CanonVRD',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)CANON OPTIONAL DATA\0.{44}$]]) end),
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Main' },
      }, {
        Name = 'FotoStation',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[\xa1\xb2\xc3\xd4$]]) end),
        SubDirectory = { TagTable = 'lexiftool.FotoStation.Main' },
      }, {
        Name = 'PhotoMechanic',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[cbipcbbl$]]) end),
        SubDirectory = { TagTable = 'lexiftool.PhotoMechanic.Main' },
      }, {
        Name = 'MIE',
        Condition = valueCondition(function(_self, val)
            return isMatch(str(val), [[(?s)~\0\x04\0zmie~\0\0\x06.{4}[\x10\x18]\x04$]]) or
                   isMatch(str(val), [[(?s)~\0\x04\0zmie~\0\0\x0a.{8}[\x10\x18]\x08$]])
        end),
        SubDirectory = { TagTable = 'lexiftool.MIE.Main' },
      }, {
        Name = 'MPF',
        SubDirectory = { TagTable = 'lexiftool.MPF.Main' },
      }, {
        Name = 'Samsung',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[QDIOBS$]]) end),
        SubDirectory = { TagTable = 'lexiftool.Samsung.Trailer' },
      }, {
        Name = 'Vivo',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^(streamdata|vivo\{")]]) end),
        SubDirectory = { TagTable = 'lexiftool.Trailer.Vivo' },
      }, {
        Name = 'OnePlus',
        SubDirectory = { TagTable = 'lexiftool.Trailer.OnePlus' },
      }, {
        Name = 'Google',
        SubDirectory = { TagTable = 'lexiftool.Trailer.Google' },
      }, {
        Name = 'EmbeddedVideo',
        Notes = 'extracted only when ExtractEmbedded option is used',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[(?s)^.{4}ftyp]]) end),
      }, {
        Name = 'Insta360',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[8db42d694ccc418790edff439fe026bf$]]) end),
      }, {
        Name = 'NikonApp',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[\0{6}/NIKON APP$]]) end),
        Notes = 'contains editing information in XMP format',
      }, {
        Name = 'SonyHiddenData',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^\x55\x26\x11\x05\0]]) end),
      }, {
        Name = 'PreviewImage',
        Condition = valueCondition(function(_self, val) return isMatch(str(val), [[^\xff\xd8\xff]]) end),
        Writable = 2,  -- (for docs only)
    }},
}

-- HDR gain information (ref PH)
JPEG.HDRGainInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP10', [1] = 'AROT', [2] = 'Image' },
    [6] = {
        Name = 'HDRGainCurveSize',
        Format = 'int32u',
    },
    [10] = {
        Name = 'HDRGainCurve', -- (NC)
        Format = 'int32uRev[$val{6}]',
        Binary = 1,
    },
}

-- JPEG yCbCrSubSampling lookup (%Image::ExifTool::JPEG::yCbCrSubSampling)
JPEG.yCbCrSubSampling = {
    ['1 1'] = 'YCbCr4:4:4 (1 1)', -- #PH
    ['2 1'] = 'YCbCr4:2:2 (2 1)', -- #14 in Exif.pm
    ['2 2'] = 'YCbCr4:2:0 (2 2)', -- #14 in Exif.pm
    ['4 1'] = 'YCbCr4:1:1 (4 1)', -- #14 in Exif.pm
    ['4 2'] = 'YCbCr4:1:0 (4 2)', -- #PH
    ['1 2'] = 'YCbCr4:4:0 (1 2)', -- #PH
    ['1 4'] = 'YCbCr4:4:1 (1 4)', -- #JD
    ['2 4'] = 'YCbCr4:2:1 (2 4)', -- #JD
}

-- JPEG SOF (start of frame) tags
-- (ref http://www.w3.org/Graphics/JPEG/itu-t81.pdf)
JPEG.SOF = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = 'This information is extracted from the JPEG Start Of Frame segment.',
    VARS = { ID_FMT = 'none' }, -- tag ID's aren't meaningful for these tags
    EncodingProcess = {
        PrintHex = 1,
        PrintConv = {
            [0x0] = 'Baseline DCT, Huffman coding',
            [0x1] = 'Extended sequential DCT, Huffman coding',
            [0x2] = 'Progressive DCT, Huffman coding',
            [0x3] = 'Lossless, Huffman coding',
            [0x5] = 'Sequential DCT, differential Huffman coding',
            [0x6] = 'Progressive DCT, differential Huffman coding',
            [0x7] = 'Lossless, Differential Huffman coding',
            [0x9] = 'Extended sequential DCT, arithmetic coding',
            [0xa] = 'Progressive DCT, arithmetic coding',
            [0xb] = 'Lossless, arithmetic coding',
            [0xd] = 'Sequential DCT, differential arithmetic coding',
            [0xe] = 'Progressive DCT, differential arithmetic coding',
            [0xf] = 'Lossless, differential arithmetic coding',
        },
    },
    BitsPerSample = {},
    ImageHeight = {},
    ImageWidth = {},
    ColorComponents = {},
    YCbCrSubSampling = {
        Notes = 'calculated from components table',
        PrintConv = JPEG.yCbCrSubSampling,
    },
}

-- JPS APP3 segment (ref http://paulbourke.net/stereographics/stereoimage/)
JPEG.JPS = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP3', [1] = 'JPS', [2] = 'Image' },
    NOTES = 'Tags found in JPEG Stereo (JPS) images.',
    [0x0a] = {
        Name = 'JPSSeparation',
        Format = 'int32u', -- (just so we can look ahead to MediaType);
        Notes = 'stereo only',
        RawConv = function(self, val)
            self.MediaType = val & 0xff
            if self.MediaType ~= 1 then return nil end
            return (val >> 24) & 0xff
        end,
    },
    [0x08] = {
        Name = 'HdrLength',
        Format = 'int16u',
        Hidden = 1,
        RawConv = function(self, val) self.HdrLength = val return nil end,
    },
    [0x0b] = {
        Name = 'JPSFlags',
        PrintConv = { BITMASK = {
            [0] = 'Half height',
            [1] = 'Half width',
            [2] = 'Left field first',
        } },
    },
    [0x0c] = {
        {
            Name = 'JPSLayout',
            Condition = function(self) return num(self.MediaType) == 0 end,
            Notes = 'mono',
            PrintConv = {
                [0] = 'Both Eyes',
                [1] = 'Left Eye',
                [2] = 'Right Eye',
            },
        },
        {
            Name = 'JPSLayout',
            Condition = function(self) return num(self.MediaType) == 1 end,
            Notes = 'stereo',
            PrintConv = {
                [1] = 'Interleaved',
                [2] = 'Side By Side',
                [3] = 'Over Under',
                [4] = 'Anaglyph',
            },
        },
    },
    [0x0d] = {
        Name = 'JPSType',
        Hook = function(self) return self.HdrLength - 4 end, -- comment starts after header block
        PrintConv = { [0] = 'Mono', [1] = 'Stereo' },
    },
    -- 0x0e - in16u comment length (ignored -- assume the remainder is all comment)
    --        (this is offset if we had a 4-byte JPS header block)
    [0x10] = {
        Name = 'JPSComment',
        Format = 'string',
    },
}
-- EPPIM APP6 (Toshiba PrintIM) segment (ref PH, from PDR-M700 samples)
JPEG.EPPIM = {
    GROUPS = { [0] = 'APP6', [1] = 'EPPIM', [2] = 'Image' },
    NOTES = [[
        APP6 is used in by the Toshiba PDR-M700 to store a TIFF structure containing
        PrintIM information.
    ]],
    [0xc4a5] = {
        Name = 'PrintIM',
        -- must set Writable here so this tag will be saved with MakerNotes option
        -- (but it isn't actually writable because there is no WRITE_PROC)
        Writable = 'undef',
        Description = 'Print Image Matching',
        SubDirectory = {
            TagTable = 'lexiftool.PrintIM.Main',
        },
    },
}

-- APP8 SPIFF segment.  Refs:
-- 1) http://www.fileformat.info/format/spiff/
-- 2) http://www.jpeg.org/public/spiff.pdf
-- Still Picture Interchange File Format APP8 (ref #1)
JPEG.SPIFF = {    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP8', [1] = 'SPIFF', [2] = 'Image' },
    NOTES = [[
        This information is found in APP8 of SPIFF-style JPEG images (the "official"
        yet rarely used JPEG file format standard: Still Picture Interchange File
        Format).  See L<http://www.jpeg.org/public/spiff.pdf> for the official
        specification.
    ]],
    [0] = {
        Name = 'SPIFFVersion',
        Format = 'int8u[2]',
        PrintConv = function(_self, val) return val:gsub(' ', '.') end,
    },
    [2] = {
        Name = 'ProfileID',
        PrintConv = {
            [0] = 'Not Specified',
            [1] = 'Continuous-tone Base',
            [2] = 'Continuous-tone Progressive',
            [3] = 'Bi-level Facsimile',
            [4] = 'Continuous-tone Facsimile',
        },
    },
    [3] = 'ColorComponents',
    [6] = {
        Name = 'ImageHeight',
        Notes = [[
            at index 4 in specification, but there are 2 extra bytes here in my only
            SPIFF sample, version 1.2
        ]],
        Format = 'int32u',
    },
    [10] = {
        Name = 'ImageWidth',
        Format = 'int32u',
    },
    [14] = {
        Name = 'ColorSpace',
        PrintConv = {
            [0] = 'Bi-level',
            [1] = 'YCbCr, ITU-R BT 709, video',
            [2] = 'No color space specified',
            [3] = 'YCbCr, ITU-R BT 601-1, RGB',
            [4] = 'YCbCr, ITU-R BT 601-1, video',
            [8] = 'Gray-scale',
            [9] = 'PhotoYCC',
            [10] = 'RGB',
            [11] = 'CMY',
            [12] = 'CMYK',
            [13] = 'YCCK',
            [14] = 'CIELab',
        },
    },
    [15] = 'BitsPerSample',
    [16] = {
        Name = 'Compression',
        PrintConv = {
            [0] = 'Uncompressed, interleaved, 8 bits per sample',
            [1] = 'Modified Huffman',
            [2] = 'Modified READ',
            [3] = 'Modified Modified READ',
            [4] = 'JBIG',
            [5] = 'JPEG',
        },
    },
    [17] = {
        Name = 'ResolutionUnit',
        PrintConv = {
            [0] = 'None',
            [1] = 'inches',
            [2] = 'cm',
        },
    },
    [18] = {
        Name = 'YResolution',
        Format = 'int32u',
    },
    [22] = {
        Name = 'XResolution',
        Format = 'int32u',
    },
}

-- APP9 Media Jukebox segment (ref PH)
JPEG.MediaJukebox = {
    GROUPS = { [0] = 'XML', [1] = 'MediaJukebox', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Tags found in the XML metadata of the APP9 "Media Jukebox" segment.',
    Date = {
        Groups = { [2] = 'Time' },
        -- convert from days since Dec 30, 1899 to seconds since Jan 1, 1970
        ValueConv = function(_self, val)
            return ExifTool.ConvertUnixTime((val - (70 * 365 + 17 + 2)) * 24 * 3600)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Album        = { },
    Caption      = { },
    Keywords     = { },
    Name         = { },
    People       = { },
    Places       = { },
    Tool_Name    = { },
    Tool_Version = { },
}

-- JPEG-HDR APP11 information (ref PH, guessed from http://anyhere.com/gward/papers/cic05.pdf)
JPEG.HDR = {
    GROUPS = { [0] = 'APP11', [1] = 'JPEG-HDR', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    TAG_PREFIX = '', -- (no prefix for unknown tags)
    NOTES = 'Information extracted from APP11 of a JPEG-HDR image.',
    ver = 'JPEG-HDRVersion',
    -- (need names for the next 3 tags)
    ln0 = { Description = 'Ln0' },
    ln1 = { Description = 'Ln1' },
    s2n = { Description = 'S2n' },
    alp = { Name = 'Alpha' }, -- (Alpha/Beta are saturation parameters)
    bet = { Name = 'Beta' },
    cor = { Name = 'CorrectionMethod' },
    RatioImage = {
        Groups = { [2] = 'Preview' },
        Notes = 'the embedded JPEG-compressed ratio image',
        Binary = 1,
    },
}

-- AdobeCM APP13 (no references)
JPEG.AdobeCM = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP13', [1] = 'AdobeCM', [2] = 'Image' },
    NOTES = [[
        The APP13 "Adobe_CM" segment presumably contains color management
        information, but the meaning of the data is currently unknown.  If anyone
        has an idea about what this means, please let me know.
    ]],
    FORMAT = 'int16u',
    [0] = 'AdobeCMType',
}

-- Adobe APP14 refs:
-- http://partners.adobe.com/public/developer/en/ps/sdk/5116.DCT_Filter.pdf
-- http://java.sun.com/j2se/1.5.0/docs/api/javax/imageio/metadata/doc-files/jpeg_metadata.html#color
-- Adobe APP14 (ref #1,#2)
JPEG.Adobe = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP14', [1] = 'Adobe', [2] = 'Image' },
    NOTES = [[
        The APP14 "Adobe" segment stores image encoding information for DCT filters.
        This segment may be copied or deleted as a block using the Extra "Adobe"
        tag, but note that it is not deleted by default when deleting all metadata
        because it may affect the appearance of the image.
    ]],
    FORMAT = 'int16u',
    [0] = 'DCTEncodeVersion',
    [1] = {
        Name = 'APP14Flags0',
        PrintConv = {
            [0] = '(none)',
            BITMASK = {
                [15] = 'Encoded with Blend=1 downsampling',
            },
        },
    },
    [2] = {
        Name = 'APP14Flags1',
        PrintConv = {
            [0] = '(none)',
            BITMASK = {},
        },
    },
    [3] = {
        Name = 'ColorTransform',
        Format = 'int8u',
        PrintConv = {
            [0] = 'Unknown (RGB or CMYK)',
            [1] = 'YCbCr',
            [2] = 'YCCK',
        },
    },
}

-- GraphicConverter APP15 (ref PH)
JPEG.GraphConv = {
    GROUPS = { [0] = 'APP15', [1] = 'GraphConv', [2] = 'Image' },
    NOTES = 'APP15 is used by GraphicConverter to store JPEG quality.',
    Q = 'Quality',
}

-- APP0 AVI1 segment (ref http://www.schnarff.com/file-formats/bmp/BMPDIB.TXT)
-- AVI1 APP0 (ref PH)
JPEG.AVI1 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP0', [1] = 'AVI1', [2] = 'Image' },
    NOTES = 'This information may be found in APP0 of JPEG image data from AVI videos.',
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'InterleavedField',
        PrintConv = {
            [0] = 'Not Interleaved',
            [1] = 'Odd',
            [2] = 'Even',
        },
    },
}

-- APP0 Ocad segment (ref PH)
JPEG.Ocad = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'APP0', [1] = 'Ocad', [2] = 'Image' },
    TAG_PREFIX = 'Ocad',
    FIRST_ENTRY = 0,
    NOTES = [[
        Tags extracted from the JPEG APP0 "Ocad" segment (found in Photobucket
        images).
    ]],
    Rev = {
        Name = 'OcadRevision',
        Format = 'string[6]',
    }
}

-- APP6 NITF segment (National Imagery Transmission Format)
-- ref http://www.gwg.nga.mil/ntb/baseline/docs/n010697/bwcguide25aug98.pdf
-- NITF APP6 (ref PH)
JPEG.NITF = {    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP6', [1] = 'NITF', [2] = 'Image' },
    NOTES = [[
        Information in APP6 used by the National Imagery Transmission Format.  See
        L<http://www.gwg.nga.mil/ntb/baseline/docs/n010697/bwcguide25aug98.pdf> for
        the official specification.
    ]],
    [0] = {
        Name = 'NITFVersion',
        Format = 'int8u[2]',
        ValueConv = function(_self, val) return sprintf('%d.%.2d', table.unpack(split(' ',val))) end,
    },
    [2] = {
        Name = 'ImageFormat',
        ValueConv = function(_self, val) return string.char(val & 0xff) end,
        PrintConv = { B = 'IMode B' },
    },
    [3] = {
        Name = 'BlocksPerRow',
        Format = 'int16u',
    },
    [5] = {
        Name = 'BlocksPerColumn',
        Format = 'int16u',
    },
    [7] = {
        Name = 'ImageColor',
        PrintConv = { [0] = 'Monochrome' },
    },
    [8] = 'BitDepth',
    [9] = {
        Name = 'ImageClass',
        PrintConv = {
            [0] = 'General Purpose',
            [4] = 'Tactical Imagery',
        },
    },
    [10] = {
        Name = 'JPEGProcess',
        PrintConv = {
            [1] = 'Baseline sequential DCT, Huffman coding, 8-bit samples',
            [4] = 'Extended sequential DCT, Huffman coding, 12-bit samples',
        },
    },
    [11] = 'Quality',
    [12] = {
        Name = 'StreamColor',
        PrintConv = { [0] = 'Monochrome' },
    },
    [13] = 'StreamBitDepth',
    [14] = {
        Name = 'Flags',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf('0x%x', val) end,
    },
}

-- Extract information from the JPEG APP0 Ocad segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function JPEG.ProcessOcad(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    et:VerboseDir('APP0 Ocad', nil, #dataPt)
    for tag, val in eachMatch(dataPt, [[\$(\w+):([^\0\$]+)]]) do
        val = val:gsub('^[ \t\n\r\f\v]+', ''); val = val:gsub('[ \t\n\r\f\v]+$', '')  -- remove leading/trailing spaces
        if not tagTablePtr[tag] then ExifTool.AddTagToTable(tagTablePtr, tag) end
        et:HandleTag(tagTablePtr, tag, val)
    end
    return 1
end

-- Extract information from the JPEG APP0 Ocad segment
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function JPEG.ProcessJPEG_HDR(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local endpos = dataPt:find('~\0', 1, true)
    if not endpos then
        et:Warn('Unrecognized JPEG-HDR format')
        return 0
    end
    -- (upstream: $pos = 0-based position after '~\0'; the metadata starts at
    --  offset 7 and runs to $pos-9)
    local pos = endpos + 1
    local meta = substr(dataPt, 7, pos - 9)
    et:VerboseDir('APP11 JPEG-HDR', nil, #dataPt)
    for tag, val in eachMatch(meta, [[(\w+)=([^,\s]*)]]) do
        if tagTablePtr[tag] == nil then
            ExifTool.AddTagToTable(tagTablePtr, tag, { Name = tag })
        end
        et:HandleTag(tagTablePtr, tag, val)
    end
    et:HandleTag(tagTablePtr, 'RatioImage', substr(dataPt, pos))
    return 1
end

-- (PROCESS_PROC is set here so the table can reference the function above)
JPEG.Ocad.PROCESS_PROC = JPEG.ProcessOcad

-- (PROCESS_PROC is set here so the table can reference the function below)
JPEG.HDR.PROCESS_PROC = JPEG.ProcessJPEG_HDR


return JPEG
