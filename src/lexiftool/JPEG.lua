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
local substr = require('lexiftool.perl').substr
local matches = require('lexiftool.perl').matches
local isMatch = require('lexiftool.perl').isMatch
local eachMatch = require('lexiftool.perl').eachMatch
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str
local JPEG = {}

-- (most of the tags in this table are for documentation purposes only)
JPEG.Main = {
    NOTES = [[
        This table lists information extracted by ExifTool from JPEG images. See
        L<https://www.w3.org/Graphics/JPEG/jfif3.pdf> for the JPEG specification.
    ]],
    APP0 = {{
        Name = 'JFIF',
        Condition = function(_self, val) return matches(str(val), [[^JFIF\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JFIF.Main' },
      }, {
        Name = 'JFXX',
        Condition = function(_self, val) return matches(str(val), [[^JFXX\0\x10]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JFIF.Extension' },
      }, {
        Name = 'CIFF',
        Condition = function(_self, val) return matches(str(val), [[(?s)^(II|MM).{4}HEAPJPGM]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.CanonRaw.Main' },
      }, {
        Name = 'AVI1',
        Condition = function(_self, val) return matches(str(val), [[^AVI1]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.AVI1' },
      }, {
        Name = 'Ocad',
        Condition = function(_self, val) return matches(str(val), [[^Ocad]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.Ocad' },
    }},
    APP1 = {{
        Name = 'EXIF',
        Condition = function(_self, val) return matches(str(val), [[^Exif\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Exif.Main' },
      }, {
        Name = 'ExtendedXMP',
        Condition = function(_self, val) return matches(str(val), [[^http://ns.adobe.com/xmp/extension/\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
      }, {
        Name = 'XMP',
        Condition = function(_self, val)
            return matches(str(val), [[^http]]) ~= nil or matches(str(val), [[<exif:]]) ~= nil
        end,
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
      }, {
        Name = 'QVCI',
        Condition = function(_self, val) return matches(str(val), [[^QVCI\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Casio.QVCI' },
      }, {
        Name = 'FLIR',
        Condition = function(_self, val) return matches(str(val), [[^FLIR\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.FLIR.FFF' },
      }, {
        Name = 'RawThermalImage', -- (from Parrot Bebop-Pro Thermal drone)
        Condition = function(_self, val) return matches(str(val), [[^PARROT\0(II\x2a\0|MM\0\x2a)]]) ~= nil end,
        Groups = { [0] = 'APP1', [1] = 'Parrot', [2] = 'Preview' },
        Notes = 'thermal image from Parrot Bebop-Pro Thermal drone',
        RawConv = function(_self, val) return substr(val, 7) end,
        Binary = 1,
    }},
    APP2 = {{
        Name = 'ICC_Profile',
        Condition = function(_self, val) return matches(str(val), [[^ICC_PROFILE\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
      }, {
        Name = 'FPXR',
        Condition = function(_self, val) return matches(str(val), [[^FPXR\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.FlashPix.Main' },
      }, {
        Name = 'MPF',
        Condition = function(_self, val) return matches(str(val), [[^MPF\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.MPF.Main' },
      }, {
        Name = 'InfiRayVersion',
        Condition = function(_self, val) return matches(str(val), [[(?s)^....IJPEG\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Version' },
      }, {
        Name = 'UniformResourceName',
        Groups = { [1] = 'APP2' },
        Condition = function(_self, val) return matches(str(val), [[^urn:]]) ~= nil end,
        Notes = 'used in Apple HDR images',
      }, {
        Name = 'PreviewImage',
        Condition = function(_self, val) return matches(str(val), [[^(|QVGA\0|BGTH)\xff\xd8\xff\xdb]]) ~= nil end,
        Notes = 'Samsung APP2 preview image', -- (Samsung/GoPro="", BenQ="QVGA\0", Digilife="BGTH")
    }},
    APP3 = {{
        Name = 'Meta',
        Condition = function(_self, val) return matches(str(val), [[^(Meta|META|Exif)\0\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Kodak.Meta' },
      }, {
        Name = 'Stim',
        Condition = function(_self, val) return matches(str(val), [[^Stim\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Stim.Main' },
      }, {
        Name = 'JPS',
        Condition = function(_self, val) return matches(str(val), [[^_JPSJPS_]]) ~= nil end,
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
        Condition = function(_self, val) return matches(str(val), [[^\xff\xd8\xff\xdb]]) ~= nil end,
        Notes = 'Samsung/HP preview image', -- (Samsung, HP, BenQ)
    }},
    APP4 = {{
        Name = 'Scalado',
        Condition = function(_self, val) return matches(str(val), [[^SCALADO\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Scalado.Main' },
      }, {
        Name = 'FPXR', -- (non-standard location written by some HP models)
        Condition = function(_self, val) return matches(str(val), [[^FPXR\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.FlashPix.Main' },
      }, {
        Name = 'QualcommDualCamera',
        Condition = function(_self, val) return matches(str(val), [[^Qualcomm Dual Camera Attributes]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Qualcomm.DualCamera' },
      }, {
        Name = 'InfiRayFactory',
        -- (upstream's Condition string is '$$self{HasIJPEG}"' -- the trailing
        --  quote is an upstream typo, and there is nothing to carry over here)
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Factory' },
      }, {
        Name = 'ThermalParams', -- (written by some DJI FLIR models)
        Condition = function(self, val)
            return self.Make == 'DJI' and matches(str(val), [[^\xaa\x55\x12\x06]]) ~= nil
        end,
        SubDirectory = { TagTable = 'lexiftool.DJI.ThermalParams' },
      }, {
        Name = 'ThermalParams2', -- (written by M3T)
        Condition = function(self, val)
            return self.Make == 'DJI' and isMatch(str(val), [[(?s)^(.{32})?.{32}\x2c\x01\x20\0]])
        end,
        SubDirectory = { TagTable = 'lexiftool.DJI.ThermalParams2' },
      }, {
        Name = 'ThermalParams3', -- (written by M30T)
        Condition = function(self, val)
            return self.Make == 'DJI' and matches(str(val), [[(?s)^.{32}\xaa\x55\x38\0]]) ~= nil
        end,
        SubDirectory = { TagTable = 'lexiftool.DJI.ThermalParams3' },
      }, {
        Name = 'PreviewImage', -- (eg. Samsung S1060)
        Notes = 'continued from APP3',
    }},
    APP5 = {{
        Name = 'RMETA',
        Condition = function(_self, val) return matches(str(val), [[^RMETA\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Ricoh.RMETA' },
      }, {
        Name = 'SamsungUniqueID',
        Condition = function(_self, val) return matches(str(val), [[ssuniqueid\0]]) ~= nil end,
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
        Condition = function(_self, val) return matches(str(val), [[^EPPIM\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.EPPIM' },
      }, {
        Name = 'NITF',
        Condition = function(_self, val) return matches(str(val), [[^NTIF\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.NITF' },
      }, {
        Name = 'HP_TDHD', -- (written by R837)
        Condition = function(_self, val) return matches(str(val), [[^TDHD\x01\0\0\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.HP.TDHD' },
      }, {
        Name = 'GoPro',
        Condition = function(_self, val) return matches(str(val), [[^GoPro\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.GoPro.GPMF' },
      }, {
        Name = 'InfiRayMixMode',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.MixMode' },
      }, {
        Name = 'DJI_DTAT', -- (written by ZH20T)
        Condition = function(_self, val) return matches(str(val), [[(?s)^DTAT\0\0.\{]]) ~= nil end,
        Groups = { [0] = 'APP6', [1] = 'DJI' },
        Notes = 'DJI Thermal Analysis Tool record',
        ValueConv = function(_self, val) return substr(val, 7) end,
      -- also seen Motorola APP6 "MMIMETA\0", with sub-types: AL3A,ALED,MMI0,MOTD,QC3A,LMB1
    }},
    APP7 = {{
        Name = 'Pentax',
        Condition = function(_self, val) return matches(str(val), [[^PENTAX \0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Pentax.Main' },
      }, {
        Name = 'Ricoh',
        Condition = function(_self, val) return matches(str(val), [[^RICOH\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Pentax.Main' },
      }, {
        Name = 'Huawei',
        Condition = function(_self, val) return matches(str(val), [[^HUAWEI\0\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Unknown.Main' },
      }, {
        Name = 'Qualcomm',
        Condition = function(_self, val) return matches(str(val), [[^\x1aQualcomm Camera Attributes]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Qualcomm.Main' },
      }, {
        Name = 'InfiRayOpMode',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.OpMode' },
      }, {
        Name = 'DJI-DBG',
        Condition = function(_self, val) return matches(str(val), [[^DJI-DBG\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.DJI.Info' },
    }},
    APP8 = {{
        Name = 'SPIFF',
        Condition = function(_self, val) return matches(str(val), [[^SPIFF\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.SPIFF' },
      }, {
        Name = 'InfiRayIsothermal',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Isothermal' },
      }, {
        Name = 'SEAL',
        Condition = function(_self, val) return matches(str(val), [[^SEAL\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    }},
    APP9 = {{
        Name = 'MediaJukebox',
        Condition = function(_self, val) return matches(str(val), [[^Media Jukebox\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.MediaJukebox' },
      }, {
        Name = 'InfiRaySensor',
        Condition = function(self) return self.HasIJPEG end,
        SubDirectory = { TagTable = 'lexiftool.InfiRay.Sensor' },
      }, {
        Name = 'SEAL',
        Condition = function(_self, val) return matches(str(val), [[^SEAL\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    }},
    APP10 = {{
        Name = 'Comment',
        Condition = function(_self, val) return matches(str(val), [[^UNICODE\0]]) ~= nil end,
        Notes = 'PhotoStudio Unicode comment',
      }, {
        Name = 'HDRGainInfo', -- #PH (NC)
        Condition = function(_self, val) return matches(str(val), [[(?s)^AROT\0\0.{4}]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.HDRGainInfo' },
    }},
    APP11 = {{
        Name = 'JPEG-HDR',
        Condition = function(_self, val) return matches(str(val), [[^HDR_RI ]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.HDR' },
      }, {
        Name = 'JUMBF',
        Condition = function(_self, val) return matches(str(val), [[^JP]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main' },
        -- Note: The suggested options for reading C2PA CAI JUMBF metadata are "-G3 -b -j -u"
    }},
    APP12 = {{
        Name = 'PictureInfo',
        Condition = function(_self, val) return matches(str(val), [[(\[picture info\]|Type=)]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.APP12.PictureInfo' },
      }, {
        Name = 'Ducky',
        Condition = function(_self, val) return matches(str(val), [[^Ducky]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.APP12.Ducky' },
    }},
    APP13 = {{
        Name = 'Photoshop',
        Condition = function(_self, val) return matches(str(val), [[^(Photoshop 3.0\0|Adobe_Photoshop2.5)]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Main' },
    }, {
        Name = 'Adobe_CM',
        Condition = function(_self, val) return matches(str(val), [[^Adobe_CM]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.JPEG.AdobeCM' },
    }},
    APP14 = {
        Name = 'Adobe',
        Condition = function(_self, val) return matches(str(val), [[^Adobe]]) ~= nil end,
        Writable = 2,  -- (for docs only)
        SubDirectory = { TagTable = 'lexiftool.JPEG.Adobe' },
    },
    APP15 = {
        Name = 'GraphicConverter',
        Condition = function(_self, val) return matches(str(val), [[^Q\s*(\d+)]]) ~= nil end,
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
        Condition = function(_self, val) return matches(str(val), [[(?s)AXS(!|\*).{8}$]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.AFCP.Main' },
      }, {
        Name = 'CanonVRD',
        Condition = function(_self, val) return matches(str(val), [[(?s)CANON OPTIONAL DATA\0.{44}$]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Main' },
      }, {
        Name = 'FotoStation',
        Condition = function(_self, val) return matches(str(val), [[\xa1\xb2\xc3\xd4$]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.FotoStation.Main' },
      }, {
        Name = 'PhotoMechanic',
        Condition = function(_self, val) return matches(str(val), [[cbipcbbl$]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.PhotoMechanic.Main' },
      }, {
        Name = 'MIE',
        Condition = function(_self, val)
            return matches(str(val), [[(?s)~\0\x04\0zmie~\0\0\x06.{4}[\x10\x18]\x04$]]) ~= nil or
                   matches(str(val), [[(?s)~\0\x04\0zmie~\0\0\x0a.{8}[\x10\x18]\x08$]]) ~= nil
        end,
        SubDirectory = { TagTable = 'lexiftool.MIE.Main' },
      }, {
        Name = 'MPF',
        SubDirectory = { TagTable = 'lexiftool.MPF.Main' },
      }, {
        Name = 'Samsung',
        Condition = function(_self, val) return matches(str(val), [[QDIOBS$]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Samsung.Trailer' },
      }, {
        Name = 'Vivo',
        Condition = function(_self, val) return matches(str(val), [[^(streamdata|vivo\{")]]) ~= nil end,
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
        Condition = function(_self, val) return matches(str(val), [[(?s)^.{4}ftyp]]) ~= nil end,
      }, {
        Name = 'Insta360',
        Condition = function(_self, val) return matches(str(val), [[8db42d694ccc418790edff439fe026bf$]]) ~= nil end,
      }, {
        Name = 'NikonApp',
        Condition = function(_self, val) return matches(str(val), [[\0{6}/NIKON APP$]]) ~= nil end,
        Notes = 'contains editing information in XMP format',
      }, {
        Name = 'SonyHiddenData',
        Condition = function(_self, val) return matches(str(val), [[^\x55\x26\x11\x05\0]]) ~= nil end,
      }, {
        Name = 'PreviewImage',
        Condition = function(_self, val) return matches(str(val), [[^\xff\xd8\xff]]) ~= nil end,
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

-- AdobeCM APP13
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

-- GraphicConverter APP15 (ref PH)
JPEG.GraphConv = {
    GROUPS = { [0] = 'APP15', [1] = 'GraphConv', [2] = 'Image' },
    NOTES = 'APP15 is used by GraphicConverter to store JPEG quality.',
    Q = 'Quality',
}

-- APP9 Media Jukebox segment (ref PH)
JPEG.MediaJukebox = {
    GROUPS = { [0] = 'XML', [1] = 'MediaJukebox', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Tags found in the XML metadata of the APP9 "Media Jukebox" segment.',
    Date = {
        Groups = { [2] = 'Time' },
        -- convert from days since Dec 30, 1899 to seconds since Jan 1, 1970
        ValueConv = function(self, val)
            return self.ConvertUnixTime((tonumber(val) - (70 * 365 + 17 + 2)) * 24 * 3600)
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

-- EPPIM APP6 (ref PH)
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
        ValueConv = function(_self, val)
            local v1, v2 = val:match('(%d+) (%d+)')
            return sprintf('%d.%.2d', tonumber(v1), tonumber(v2))
        end,
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

-- Extract information from the JPEG APP0 Ocad segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function JPEG.ProcessOcad(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    et:VerboseDir('APP0 Ocad', nil, #dataPt)
    for tag, val in eachMatch(dataPt, [[\$(\w+):([^\0\$]+)]]) do
        val = val:gsub('^[ \t\n\r\f\v]+', ''); val = val:gsub('[ \t\n\r\f\v]+$', '')  -- remove leading/trailing spaces
        if not tagTablePtr[tag] then et:AddTagToTable(tagTablePtr, tag) end
        et:HandleTag(tagTablePtr, tag, val)
    end
    return 1
end

-- (PROCESS_PROC is set here so the table can reference the function above)
JPEG.Ocad.PROCESS_PROC = JPEG.ProcessOcad

-- Extract information from the JPEG APP11 JPEG-HDR segment
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
            et:AddTagToTable(tagTablePtr, tag, { Name = tag })
        end
        et:HandleTag(tagTablePtr, tag, val)
    end
    et:HandleTag(tagTablePtr, 'RatioImage', substr(dataPt, pos))
    return 1
end

-- (PROCESS_PROC is set here so the table can reference the function below)
JPEG.HDR.PROCESS_PROC = JPEG.ProcessJPEG_HDR

-- JPS APP3 segment (ref http://paulbourke.net/stereographics/stereoimage/)
JPEG.JPS = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'APP3', [1] = 'JPS', [2] = 'Image' },
    NOTES = 'Tags found in JPEG Stereo (JPS) images.',
    [0x0a] = {
        Name = 'JPSSeparation',
        Format = 'int32u', -- (just so we can look ahead to MediaType)
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
            Condition = function(self) return self.MediaType == 0 end,
            Notes = 'mono',
            PrintConv = {
                [0] = 'Both Eyes',
                [1] = 'Left Eye',
                [2] = 'Right Eye',
            },
        },
        {
            Name = 'JPSLayout',
            Condition = function(self) return self.MediaType == 1 end,
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
    -- 0x0e - int16u comment length (ignored -- assume the remainder is all comment)
    --        (this is offset if we had a 4-byte JPS header block)
    [0x10] = {
        Name = 'JPSComment',
        Format = 'string',
    },
}

return JPEG
