--------------------------------------------------------------------------------
-- File:         lexiftool/PNG.lua
-- Ported from:  lib/Image/ExifTool/PNG.pm
--
-- Description:  Read and write PNG meta information
--
-- Revisions:    06/10/2005 - P. Harvey Created
--               06/23/2005 - P. Harvey Added MNG and JNG support
--               09/16/2005 - P. Harvey Added write support
--
-- References:   1) http://www.libpng.org/pub/png/spec/1.2/
--               2) http://www.faqs.org/docs/png/
--               3) http://www.libpng.org/pub/mng/
--               4) http://www.libpng.org/pub/png/spec/register/
--               5) ftp://ftp.simplesystems.org/pub/png/documents/pngext-1.4.0-pdg.html
--               6) ftp://ftp.simplesystems.org/pub/png/documents/pngext-1.5.0.html
--
-- Notes:        Writing meta information in PNG images is a pain in the butt
--               for a number of reasons:  One biggie is that you have to
--               decompress then decode the ASCII/hex profile information before
--               you can edit it, then you have to ASCII/hex-encode, recompress
--               and calculate a CRC before you can write it out again.  gaaaak.
--
--               Although XMP is allowed after the IDAT chunk according to the
--               PNG specifiction, some apps (Apple Spotlight and Preview for
--               OS X 10.8.5 and Adobe Photoshop CC 14.0) ignore it unless it
--               comes before IDAT.  As of version 11.58, ExifTool uses a 2-pass
--               writing algorithm to allow it to be compatible with XMP after
--               IDAT while writing it before IDAT.  (PNG and EXIF are still
--               written after IDAT.)  As of version 11.63, this strategy is
--               applied to all text chunks (tEXt, zTXt and iTXt).
--
-- Port notes:   Complete port of PNG.pm: every table, lookup and sub, in
--               upstream order (PNG, MNG and JNG signatures; MNG/JNG chunks
--               go to lexiftool.MNG.Main).  Deviations forced by Lua:
--               - The predeclarations `sub ProcessPNG_tEXt($$$);` ... are
--                 one block of locals at the top; the subs assign to them
--                 (and are exported on the module table).  The ProcessProc
--                 entries of Main and the TextualData PROCESS_PROC are
--                 `false` placeholders filled in after the subs: FoundPNG
--                 compares a ProcessProc with ProcessPNG_Compressed, so they
--                 must be the functions themselves, not closures.
--               - An output buffer (upstream `\$theBuff`) is a box
--                 `{ value = ... }`; `%unreg` is spelled out in each entry.
--               - `$$et{DEL_GROUP}{X}` is Writer.IsGroupDeleted(et, X).
--               - Compress::Zlib is ExifTool hasZlib/inflate/deflateInit.
--                 Where inflating fails, Compress::Zlib has already consumed
--                 part of the input; ExifTool:inflate does not pass on how
--                 much, so such a corrupt value keeps all its bytes here.
--               - The write-include WritePNG.pl is lexiftool/WritePNG.lua;
--                 its subs are bound here as AUTOLOAD closures (see the
--                 predeclarations).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local Write = Writer.Write
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local tr = perl.tr
local join = perl.join
local lc = perl.lc
local uc = perl.uc
local ucfirst = perl.ucfirst
local length = perl.length
local substr = perl.substr
local sprintf = perl.sprintf
local pack = perl.pack
local unpack = perl.unpack
local int = perl.int
local truthy = perl.truthy
local carray = require('carray')
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable

local PNG = {}

-- (upstream's predeclarations `sub ProcessPNG_tEXt($$$);` ... are this block
--  of locals; the subs below assign to them.  CalculateCRC, HexEncode,
--  AddChunks, Add_iCCP, DoneDir and BuildTextChunk are subs of WritePNG.pl,
--  which upstream AUTOLOADs -- DoAutoLoad loads it on the first call.  Here
--  every sub of WritePNG.pl (WriteProfile too, which has no predeclaration)
--  is bound to a closure that loads WritePNG.lua on first use)
local ProcessPNG_tEXt, ProcessPNG_iTXt, ProcessPNG_eXIf, ProcessPNG_Compressed
local CalculateCRC, HexEncode, AddChunks, Add_iCCP, DoneDir
local GetLangInfo, BuildTextChunk, ConvertPNGDate, InversePNGDate
for _, name in ipairs({ 'CalculateCRC', 'HexEncode', 'WriteProfile', 'Add_iCCP', 'DoneDir',
                        'BuildTextChunk', 'AddChunks' }) do
    PNG[name] = function(...) return require('lexiftool.WritePNG')[name](...) end
end
CalculateCRC, HexEncode, AddChunks, Add_iCCP, DoneDir, BuildTextChunk =
    PNG.CalculateCRC, PNG.HexEncode, PNG.AddChunks, PNG.Add_iCCP, PNG.DoneDir, PNG.BuildTextChunk

-- translate lower-case to actual case used for eXIf/zXIf chunks
local stdCase = { zxif = 'zxIf', exif = 'eXIf' }
PNG.stdCase = stdCase

local noCompressLib

-- look up for file type, header chunk and end chunk, based on file signature
local pngLookup = {
    ["\x89PNG\r\n\x1a\n"] = { 'PNG', 'IHDR', 'IEND' },
    ["\x8aMNG\r\n\x1a\n"] = { 'MNG', 'MHDR', 'MEND' },
    ["\x8bJNG\r\n\x1a\n"] = { 'JNG', 'JHDR', 'IEND' },
}

-- map for directories in PNG images
local pngMap = {
    IFD1         = 'IFD0',
    EXIF         = 'IFD0', -- to write EXIF as a block
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
    IFD0         = 'PNG',
    XMP          = 'PNG',
    ICC_Profile  = 'PNG',
    Photoshop    = 'PNG',
   ['PNG-pHYs']  = 'PNG',
    JUMBF        = 'PNG',
    IPTC         = 'Photoshop',
--  MakerNotes   = 'ExifIFD',  (repeated upstream; one key in a Lua table)
}

-- color type of current image
PNG.colorType = -1

-- data and text chunk types
local isDatChunk = { IDAT = 1, JDAT = 1, JDAA = 1 }
local isTxtChunk = { tEXt = 1, zTXt = 1, iTXt = 1, eXIf = 1 }

-- chunks that we shouldn't move other chunks across (ref 3)
local noLeapFrog = { SAVE = 1, SEEK = 1, IHDR = 1, JHDR = 1, IEND = 1, MEND = 1,
                     DHDR = 1, BASI = 1, CLON = 1, PAST = 1, SHOW = 1, MAGN = 1 }

-- PNG chunks
PNG.Main = {
    WRITE_PROC = ExifTool.DummyWriteProc,
    GROUPS = { [2] = 'Image' },
    PREFERRED = 1, -- always add these tags when writing
    NOTES = [[
        Tags extracted from PNG images.  See
        L<http://www.libpng.org/pub/png/spec/1.2/> for the official PNG 1.2
        specification.

        According to the specification, a PNG file should end at the IEND chunk,
        however ExifTool will preserve any data found after this when writing unless
        it is specifically deleted with C<-Trailer:All=>.  When reading, a minor
        warning is issued if this trailer exists, and ExifTool will attempt to parse
        this data as additional PNG chunks.

        Also according to the PNG specification, there is no restriction on the
        location of text-type chunks (tEXt, zTXt and iTXt).  However, certain
        utilities (including some Apple and Adobe utilities) won't read the XMP iTXt
        chunk if it comes after the IDAT chunk, and at least one utility won't read
        other text chunks here.  For this reason, when writing, ExifTool 11.63 and
        later create new text chunks (including XMP) before IDAT, and move existing
        text chunks to before IDAT.

        The PNG format contains CRC checksums that are validated when reading with
        either the L<Verbose|../ExifTool.html#Verbose> or L<Validate|../ExifTool.html#Validate> option.  When writing, these checksums are
        validated by default, but the L<FastScan|../ExifTool.html#FastScan> option may be used to bypass this
        check if speed is more of a concern.
    ]],
    bKGD = {
        Name = 'BackgroundColor',
        ValueConv = function(_self, val) return join(' ', { unpack(length(val) < 2 and 'C' or 'n*', val) }) end,
    },
    cHRM = {
        Name = 'PrimaryChromaticities',
        SubDirectory = { TagTable = 'lexiftool.PNG.PrimaryChromaticities' },
    },
    dSIG = {
        Name = 'DigitalSignature',
        Binary = 1,
    },
    fRAc = {
        Name = 'FractalParameters',
        Binary = 1,
    },
    gAMA = {
        Name = 'Gamma',
        Writable = 1,
        Protected = 1,
        Notes = [[
            ExifTool reports the gamma for decoding the image, which is consistent with
            the EXIF convention, but is the inverse of the stored encoding gamma
        ]],
        ValueConv = function(_self, val) local a = unpack('N', val) if truthy(a) then return int(1e9 / a + 0.5) / 1e4 end return val end,
        ValueConvInv = function(_self, val) return pack('N', int(1e5 / perl.num(val) + 0.5)) end,
    },
    gIFg = {
        Name = 'GIFGraphicControlExtension',
        Binary = 1,
    },
    gIFt = {
        Name = 'GIFPlainTextExtension',
        Binary = 1,
    },
    gIFx = {
        Name = 'GIFApplicationExtension',
        Binary = 1,
    },
    hIST = {
        Name = 'PaletteHistogram',
        Binary = 1,
    },
    iCCP = {
        Name = 'ICC_Profile',
        Notes = [[
            this is where ExifTool will write a new ICC_Profile.  When creating a new
            ICC_Profile, the SRGBRendering tag should be deleted if it exists
        ]],
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessPNG_Compressed)
        },
    },
   ['iCCP-name'] = {
        Name = 'ProfileName',
        Writable = 1,
        FakeTag = 1, -- (not a real PNG tag, so don't try to write it)
        Notes = [[
            not a real tag ID, this tag represents the iCCP profile name, and may only
            be written when the ICC_Profile is written
        ]],
    },
--  IDAT
--  IEND
    IHDR = {
        Name = 'ImageHeader',
        SubDirectory = { TagTable = 'lexiftool.PNG.ImageHeader' },
    },
    iTXt = {
        Name = 'InternationalText',
        SubDirectory = {
            TagTable = 'lexiftool.PNG.TextualData',
            ProcessProc = false, -- predeclaration, see below (ProcessPNG_iTXt)
        },
    },
    oFFs = {
        Name = 'ImageOffset',
        ValueConv = function(_self, val)
            local a = { unpack('NNC', val) }
            a[3] = (truthy(a[3]) and 'microns' or 'pixels')
            return a[1] .. ', ' .. a[2] .. ' (' .. a[3] .. ')'
        end,
    },
    pCAL = {
        Name = 'PixelCalibration',
        Binary = 1,
    },
    pHYs = {
        Name = 'PhysicalPixel',
        SubDirectory = {
            TagTable = 'lexiftool.PNG.PhysicalPixel',
            DirName = 'PNG-pHYs', -- (needed for writing)
        },
    },
    PLTE = {
        Name = 'Palette',
        ValueConv = function(_self, val) if length(val) <= 3 then return join(' ', { unpack('C*', val) }) end return { ref = 'SCALAR', value = val } end,
    },
    sBIT = {
        Name = 'SignificantBits',
        ValueConv = function(_self, val) return join(' ', { unpack('C*', val) }) end,
    },
    sCAL = { -- png 1.4.0
        Name = 'SubjectScale',
        SubDirectory = { TagTable = 'lexiftool.PNG.SubjectScale' },
    },
    sPLT = {
        Name = 'SuggestedPalette',
        Binary = 1,
        -- (upstream `split("\0",$$val,1)`: with LIMIT 1 nothing is actually
        --  split, and a PrintConv is eval'd in scalar context, so what comes
        --  out is the field count -- reproduced, not "fixed")
        PrintConv = function(_self, val) -- extract palette name
            local s = type(val) == 'table' and val.value or val
            return #split([[\0]], s, 1)
        end,
    },
    sRGB = {
        Name = 'SRGBRendering',
        Writable = 1,
        Protected = 1,
        Notes = 'this chunk should not be present if an iCCP chunk exists',
        ValueConv = function(_self, val) return unpack('C', val) end,
        ValueConvInv = function(_self, val) return pack('C', val) end,
        PrintConv = {
            [0] = 'Perceptual',
            [1] = 'Relative Colorimetric',
            [2] = 'Saturation',
            [3] = 'Absolute Colorimetric',
        },
    },
    sTER = { -- png 1.4.0
        Name = 'StereoImage',
        SubDirectory = { TagTable = 'lexiftool.PNG.StereoImage' },
    },
    tEXt = {
        Name = 'TextualData',
        SubDirectory = { TagTable = 'lexiftool.PNG.TextualData' },
    },
    tIME = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        Writable = 1,
        Shift = 'Time',
        ValueConv = function(_self, val) return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', unpack('nC5', val)) end,
        ValueConvInv = function(_self, val)
            local a = { matches(val, [[^(\d+):(\d+):(\d+)\s+(\d+):(\d+):(\d+)]]) }
            if #a ~= 7 then error('Invalid date', 0) end   -- (the 7th value is the match end)
            return pack('nC5', table.unpack(a, 1, 6))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val) end,
    },
    tRNS = {
        Name = 'Transparency',
        -- may have as many entries as the PLTE table, but who wants to see all that?
        ValueConv = function(_self, val)
            if length(val) > 6 then return { ref = 'SCALAR', value = val } end
            return join(' ', { unpack(PNG.colorType == 3 and 'C*' or 'n*', val) })
        end,
    },
    tXMP = {
        Name = 'XMP',
        Notes = 'obsolete location specified by a September 2001 XMP draft',
        NonStandard = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    vpAg = { -- private imagemagick chunk
        Name = 'VirtualPage',
        SubDirectory = { TagTable = 'lexiftool.PNG.VirtualPage' },
    },
    zTXt = {
        Name = 'CompressedText',
        SubDirectory = {
            TagTable = 'lexiftool.PNG.TextualData',
            ProcessProc = false, -- predeclaration, see below (ProcessPNG_Compressed)
        },
    },
    -- animated PNG (ref https://wiki.mozilla.org/APNG_Specification)
    acTL = {
        Name = 'AnimationControl',
        SubDirectory = {
            TagTable = 'lexiftool.PNG.AnimationControl',
        },
    },
    -- eXIf (ref 6)
    [stdCase.exif] = {
        Name = stdCase.exif,
        Notes = 'this is where ExifTool will create new EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            DirName = 'EXIF', -- (to write as a block)
            ProcessProc = false, -- predeclaration, see below (ProcessPNG_eXIf)
        },
    },
    -- zXIf
    [stdCase.zxif] = {
        Name = stdCase.zxif,
        Notes = 'a once-proposed chunk for compressed EXIF',
        NonStandard = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            DirName = 'EXIF', -- (to write as a block)
            ProcessProc = false, -- predeclaration, see below (ProcessPNG_eXIf)
        },
    },
    -- fcTL - animation frame control for each frame
    -- fdAT - animation data for each frame
    iDOT = { -- (ref NealKrawetz)
        Name = 'AppleDataOffsets',
        Binary = 1,
        -- Apple offsets into data relative to start of iDOT chunk:
        --    int32u Divisor  [only ever seen 2]
        --    int32u Unknown  [always 0]
        --    int32u TotalDividedHeight  [image height from IDHR/Divisor]
        --    int32u Size  [always 40 / 0x28; size of this chunk]
        --    int32u DividedHeight1
        --    int32u DividedHeight2
        --    int32u IDAT_Offset2 [location of IDAT with start of DividedHeight2 segment]
    },
    caBX = { -- C2PA metadata
        Name = 'JUMBF',
        Deletable = 1,
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main' },
    },
    cICP = {
        Name = 'CICodePoints',
        SubDirectory = {
            TagTable = 'lexiftool.PNG.CICodePoints',
        },
    },
    cpIp = { -- OLE information found in PNG Plus images written by Picture It!
        Name = 'OLEInfo',
        Condition = function(self)
            -- set FileType to "PNG Plus"
            if self.VALUE.FileType and self.VALUE.FileType == 'PNG' then
                self.VALUE.FileType = 'PNG Plus'
            end
            return 1
        end,
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.Main',
            -- (upstream names this proc as a string so FlashPix.pm is only
            --  loaded when the chunk is really there; a lazy require does the
            --  same here -- see the eager-require rule in CONTRIBUTING.md)
            ProcessProc = function(...) return require('lexiftool.FlashPix').ProcessFPX(...) end,
        },
    },
    meTa = { -- XML in UTF-16 BOM format written by Picture It!
        SubDirectory = {
            TagTable = 'lexiftool.XMP.XML',
            IgnoreProp = { meta = 1 }, -- ignore 'meta' container
        },
    },
    gdAT = {
        Name = 'GainMapImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    -- gmAP  - https://github.com/w3c/png/issues/380 does't correspond to my only sample
    seAl = {
        Name = 'SEAL',
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    },
    -- mkBF,mkTS,mkBS,mkBT ? - written by Adobe FireWorks
}

-- PNG IHDR chunk
PNG.ImageHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'ImageWidth',
        Format = 'int32u',
    },
    [4] = {
        Name = 'ImageHeight',
        Format = 'int32u',
    },
    [8] = 'BitDepth',
    [9] = {
        Name = 'ColorType',
        RawConv = function(_self, val) PNG.colorType = val return val end,
        PrintConv = {
            [0] = 'Grayscale',
            [2] = 'RGB',
            [3] = 'Palette',
            [4] = 'Grayscale with Alpha',
            [6] = 'RGB with Alpha',
        },
    },
    [10] = {
        Name = 'Compression',
        PrintConv = { [0] = 'Deflate/Inflate' },
    },
    [11] = {
        Name = 'Filter',
        PrintConv = { [0] = 'Adaptive' },
    },
    [12] = {
        Name = 'Interlace',
        PrintConv = { [0] = 'Noninterlaced', [1] = 'Adam7 Interlace' },
    },
}

-- PNG cHRM chunk
PNG.PrimaryChromaticities = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int32u',
    [0] = { Name = 'WhitePointX', ValueConv = function(_self, val) return val / 100000 end },
    [1] = { Name = 'WhitePointY', ValueConv = function(_self, val) return val / 100000 end },
    [2] = { Name = 'RedX',        ValueConv = function(_self, val) return val / 100000 end },
    [3] = { Name = 'RedY',        ValueConv = function(_self, val) return val / 100000 end },
    [4] = { Name = 'GreenX',      ValueConv = function(_self, val) return val / 100000 end },
    [5] = { Name = 'GreenY',      ValueConv = function(_self, val) return val / 100000 end },
    [6] = { Name = 'BlueX',       ValueConv = function(_self, val) return val / 100000 end },
    [7] = { Name = 'BlueY',       ValueConv = function(_self, val) return val / 100000 end },
}

-- PNG pHYs chunk
PNG.PhysicalPixel = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    GROUPS = { [1] = 'PNG-pHYs', [2] = 'Image' },
    WRITE_GROUP = 'PNG-pHYs',
    NOTES = [[
        These tags are found in the PNG pHYs chunk and belong to the PNG-pHYs family
        1 group.  They are all created together with default values if necessary
        when any of these tags is written, and may only be deleted as a group.
    ]],
    [0] = {
        Name = 'PixelsPerUnitX',
        Format = 'int32u',
        Notes = 'default 2834',
    },
    [4] = {
        Name = 'PixelsPerUnitY',
        Format = 'int32u',
        Notes = 'default 2834',
    },
    [8] = {
        Name = 'PixelUnits',
        PrintConv = { [0] = 'Unknown', [1] = 'meters' },
        Notes = 'default meters',
    },
}

-- PNG cICP chunk
PNG.CICodePoints = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'PNG-cICP', [2] = 'Image' },
    NOTES = [[
        These tags are found in the PNG cICP chunk and belong to the PNG-cICP family
        1 group.
    ]],
    -- (same as tags in QuickTime::ColorRep)
    [0] = {
        Name = 'ColorPrimaries',
        PrintConv = {
            [1] = 'BT.709',
            [2] = 'Unspecified',
            [4] = 'BT.470 System M (historical)',
            [5] = 'BT.470 System B, G (historical)',
            [6] = 'BT.601',
            [7] = 'SMPTE 240',
            [8] = 'Generic film (color filters using illuminant C)',
            [9] = 'BT.2020, BT.2100',
            [10] = 'SMPTE 428 (CIE 1921 XYZ)',
            [11] = 'SMPTE RP 431-2',
            [12] = 'SMPTE EG 432-1',
            [22] = 'EBU Tech. 3213-E',
        },
    },
    [1] = {
        Name = 'TransferCharacteristics',
        PrintConv = {
            [0] = 'For future use (0)',
            [1] = 'BT.709',
            [2] = 'Unspecified',
            [3] = 'For future use (3)',
            [4] = 'BT.470 System M (historical)',
            [5] = 'BT.470 System B, G (historical)',
            [6] = 'BT.601',
            [7] = 'SMPTE 240 M',
            [8] = 'Linear',
            [9] = 'Logarithmic (100 : 1 range)',
            [10] = 'Logarithmic (100 * Sqrt(10) : 1 range)',
            [11] = 'IEC 61966-2-4',
            [12] = 'BT.1361',
            [13] = 'sRGB or sYCC',
            [14] = 'BT.2020 10-bit systems',
            [15] = 'BT.2020 12-bit systems',
            [16] = 'SMPTE ST 2084, ITU BT.2100 PQ',
            [17] = 'SMPTE ST 428',
            [18] = 'BT.2100 HLG, ARIB STD-B67',
        },
    },
    [2] = {
        Name = 'MatrixCoefficients',
        PrintConv = {
            [0] = 'Identity matrix',
            [1] = 'BT.709',
            [2] = 'Unspecified',
            [3] = 'For future use (3)',
            [4] = 'US FCC 73.628',
            [5] = 'BT.470 System B, G (historical)',
            [6] = 'BT.601',
            [7] = 'SMPTE 240 M',
            [8] = 'YCgCo',
            [9] = 'BT.2020 non-constant luminance, BT.2100 YCbCr',
            [10] = 'BT.2020 constant luminance',
            [11] = 'SMPTE ST 2085 YDzDx',
            [12] = 'Chromaticity-derived non-constant luminance',
            [13] = 'Chromaticity-derived constant luminance',
            [14] = 'BT.2100 ICtCp',
        },
    },
    [3] = 'VideoFullRangeFlag',
}

-- PNG sCAL chunk
PNG.SubjectScale = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'SubjectUnits',
        PrintConv = { [1] = 'meters', [2] = 'radians' },
    },
    [1] = {
        Name = 'SubjectPixelWidth',
        Format = 'var_string',
    },
    [2] = {
        Name = 'SubjectPixelHeight',
        Format = 'var_string',
    },
}

-- PNG vpAg chunk
PNG.VirtualPage = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int32u',
    [0] = 'VirtualImageWidth',
    [1] = 'VirtualImageHeight',
    [2] = {
        Name = 'VirtualPageUnits',
        Format = 'int8u',
        -- what is the conversion for this?
    },
}

-- PNG sTER chunk
PNG.StereoImage = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'StereoMode',
        PrintConv = {
            [0] = 'Cross-fuse Layout',
            [1] = 'Diverging-fuse Layout',
        },
    },
}

-- (upstream `my %unreg = ( Notes => 'unregistered' );` is spelled out in
--  each entry below: Lua has no hash splicing)

-- Tags for PNG tEXt zTXt and iTXt chunks
-- (NOTE: ValueConv is set dynamically, so don't set it here!)
PNG.TextualData = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = ExifTool.DummyWriteProc,
    WRITABLE = 'string',
    PREFERRED = 1, -- always add these tags when writing
    GROUPS = { [2] = 'Image' },
    LANG_INFO = function(...) return GetLangInfo(...) end,
    NOTES = [[
        The PNG TextualData format allows arbitrary tag names to be used.  The tags
        listed below are the only ones that can be written (unless new user-defined
        tags are added via the configuration file), however ExifTool will extract
        any other TextualData tags that are found.  All TextualData tags (including
        tags not listed below) are removed when deleting all PNG tags.

        These tags may be stored as tEXt, zTXt or iTXt chunks in the PNG image.  By
        default ExifTool writes new string-value tags as as uncompressed tEXt, or
        compressed zTXt if the L<Compress|../ExifTool.html#Compress> (-z) option is used and Compress::Zlib is
        available.  Alternate language tags and values containing special characters
        (unless the Latin character set is used) are written as iTXt, and compressed
        if the L<Compress|../ExifTool.html#Compress> option is used and Compress::Zlib is available.  Raw profile
        information is always created as compressed zTXt if Compress::Zlib is
        available, or tEXt otherwise.  Standard XMP is written as uncompressed iTXt.
        User-defined tags may set an 'iTXt' flag in the tag definition to be written
        only as iTXt.

        Alternate languages are accessed by suffixing the tag name with a '-',
        followed by an RFC 3066 language code (eg. "PNG:Comment-fr", or
        "Title-en-US").  See L<http://www.ietf.org/rfc/rfc3066.txt> for the RFC 3066
        specification.

        Some of the tags below are not registered as part of the PNG specification,
        but are included here because they are generated by other software such as
        ImageMagick.
    ]],
    Title       = { },
    Author      = { Groups = { [2] = 'Author' } },
    Description = { },
    Copyright   = { Groups = { [2] = 'Author' } },
   ['Creation Time'] = {
        Name = 'CreationTime',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        Notes = 'stored in RFC-1123 format and converted to/from EXIF format by ExifTool',
        RawConv = function(self, val) return ConvertPNGDate(val, self) end,
        ValueConvInv = function(self, val) return InversePNGDate(val, self) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val, nil, 1) end,
    },
    Software    = { },
    Disclaimer  = { },
    -- change name to differentiate from ExifTool Warning
    Warning     = { Name = 'PNGWarning', },
    Source      = { },
    Comment     = { },
    Collection  = { }, -- (PNG extensions, 2004)
--
-- The following tags are not part of the original PNG specification,
-- but are written by ImageMagick and other software
--
    Artist      = { Notes = 'unregistered', Groups = { [2] = 'Author' } },
    Document    = { Notes = 'unregistered' },
    Label       = { Notes = 'unregistered' },
    Make        = { Notes = 'unregistered', Groups = { [2] = 'Camera' } },
    Model       = { Notes = 'unregistered', Groups = { [2] = 'Camera' } },
    parameters  = { Notes = 'unregistered' }, -- (written by Stable Diffusion)
    aesthetic_score = { Name = 'AestheticScore', Notes = 'unregistered' }, -- (written by Stable Diffusion)
   ['create-date'] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        Notes = 'unregistered',
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        ValueConvInv = function(_self, val) return require('lexiftool.XMP').FormatXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val, nil, 1) end,
    },
   ['modify-date'] = {
        Name = 'ModDate', -- (to distinguish from tIME chunk "ModifyDate")
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        Notes = 'unregistered',
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        ValueConvInv = function(_self, val) return require('lexiftool.XMP').FormatXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val, nil, 1) end,
    },
    TimeStamp   = { Notes = 'unregistered', Groups = { [2] = 'Time' }, Shift = 'Time' },
    URL         = { Notes = 'unregistered' },
   ['XML:com.adobe.xmp'] = {
        Name = 'XMP',
        Notes = [[
            unregistered, but this is the location according to the June 2002 or later
            XMP specification, and is where ExifTool will add a new XMP chunk if the
            image didn't already contain XMP
        ]],
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
   ['Raw profile type APP1'] = {
        {
            -- EXIF table must come first because we key on this in ProcessProfile()
            -- (No condition because this is just for BuildTagLookup)
            Name = 'APP1_Profile',
            Notes = 'unregistered',
            NonStandard = 'EXIF',
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = false, -- predeclaration, see below (ProcessProfile)
            },
        },
        {
            Name = 'APP1_Profile',
            NonStandard = 'XMP',
            SubDirectory = {
                TagTable = 'lexiftool.XMP.Main',
                ProcessProc = false, -- predeclaration, see below (ProcessProfile)
            },
        },
    },
   ['Raw profile type exif'] = {
        Name = 'EXIF_Profile',
        Notes = 'unregistered',
        NonStandard = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessProfile)
        },
    },
   ['Raw profile type icc'] = {
        Name = 'ICC_Profile',
        Notes = 'unregistered',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessProfile)
        },
    },
   ['Raw profile type icm'] = {
        Name = 'ICC_Profile',
        Notes = 'unregistered',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessProfile)
        },
    },
   ['Raw profile type iptc'] = {
        Name = 'IPTC_Profile',
        Notes = [[
            unregistered.  May be either IPTC IIM or Photoshop IRB format.  This is
            where ExifTool will add new IPTC, inside a Photoshop IRB container
        ]],
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessProfile)
        },
    },
   ['Raw profile type xmp'] = {
        Name = 'XMP_Profile',
        Notes = 'unregistered',
        NonStandard = 'XMP',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessProfile)
        },
    },
    ['Raw profile type 8bim'] = {
        Name = 'Photoshop_Profile',
        Notes = 'unregistered',
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.Main',
            ProcessProc = false, -- predeclaration, see below (ProcessProfile)
        },
    },
}

-- Animation control
PNG.AnimationControl = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int32u',
    NOTES = [[
        Tags found in the Animation Control chunk.  See
        L<https://wiki.mozilla.org/APNG_Specification> for details.
    ]],
    [0] = {
        Name = 'AnimationFrames',
        RawConv = function(self, val) self:OverrideFileType('APNG', nil, 'PNG') return val end,
    },
    [1] = {
        Name = 'AnimationPlays',
        PrintConv = function(_self, val) return truthy(val) and val or 'inf' end,
    },
}

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WritePNG.pl -- its subs are bound to
--  loader closures at their predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Get standard case for language code (this routine copied from XMP.pm)
-- Inputs: 0) Language code
-- Returns: Language code in standard case
local function StandardLangCase(lang)
    -- make 2nd subtag uppercase only if it is 2 letters
    local c1, c2, c3 = matches(lang, [[(?i)^([a-z]{2,3}|[xi])(-[a-z]{2})\b(.*)]])
    if c1 then return lc(c1) .. uc(c2) .. lc(c3) end
    return lc(lang)
end

--------------------------------------------------------------------------------
-- Convert date from PNG to EXIF format
-- Inputs: 0) Date/time in PNG format, 1) ExifTool ref
-- Returns: EXIF formatted date/time string
local monthNum = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10,Nov=11,Dec=12
}
local tzConv = {
    UT  = '+00:00',  GMT = '+00:00',  UTC = '+00:00', -- (UTC not in spec -- PH addition)
    EST = '-05:00',  EDT = '-04:00',
    CST = '-06:00',  CDT = '-05:00',
    MST = '-07:00',  MDT = '-06:00',
    PST = '-08:00',  PDT = '-07:00',
    A = '-01:00',    N = '+01:00',
    B = '-02:00',    O = '+02:00',
    C = '-03:00',    P = '+03:00',
    D = '-04:00',    Q = '+04:00',
    E = '-05:00',    R = '+05:00',
    F = '-06:00',    S = '+06:00',
    G = '-07:00',    T = '+07:00',
    H = '-08:00',    U = '+08:00',
    I = '-09:00',    V = '+09:00',
    K = '-10:00',    W = '+10:00',
    L = '-11:00',    X = '+11:00',
    M = '-12:00',    Y = '+12:00',
    Z = '+00:00',
}
function ConvertPNGDate(val, et)
    -- standard format is like "Mon, 1 Jan 2018 12:10:22 EST" (RFC-1123 section 5.2.14)
    -- (upstream's `while` runs at most once; `last` leaves it early)
    while true do -- luacheck: ignore 512
        local ok, day, mon, yr, hr, min, sec, tz = isMatch(val,
            [[(?i)(\d+)\s*(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s*(\d+)\s+(\d+):(\d{2})(:\d{2})?\s*(\S*)]])
        if not ok then break end
        yr = perl.num(yr)
        if yr < 100 then yr = yr + (yr > 70 and 1900 or 2000) end     -- boost year to 4 digits if necessary
        mon = monthNum[ucfirst(lc(mon))]
        if not mon then return val end
        if not truthy(tz) then
            tz = ''
        elseif tzConv[uc(tz)] then
            tz = tzConv[uc(tz)]
        else
            local t1, t2 = matches(tz, [[^([-+]\d+):?(\d{2})]])
            if t1 then
                tz = t1 .. ':' .. t2
            else
                break       -- (non-standard date)
            end
        end
        return sprintf('%.4d:%.2d:%.2d %.2d:%.2d%s%s', yr, mon, day, hr, min, truthy(sec) and sec or ':00', tz)
    end
    if (truthy(et:Options('StrictDate')) and not et.TAGS_FROM_FILE) or truthy(et:Options('Validate')) then
        et:Warn('Non standard PNG date/time format', 1)
    end
    return val
end

--------------------------------------------------------------------------------
-- Convert EXIF date/time to PNG format
-- Inputs: 0) Date/time in EXIF format, 1) ExifTool ref
-- Returns: PNG formatted date/time string
function InversePNGDate(val, et)
    if truthy(et:Options('StrictDate')) then
        local err
        local ok, yr, mon, day, hr, min, sec, tz = isMatch(val, [[^(\d{4}):(\d{2}):(\d{2}) (\d{2})(:\d{2})(:\d{2})?(?:\.\d*)?\s*(\S*)]])
        if ok then
            if not truthy(sec) then sec = '' end
            local monName = {}
            for k, v in pairs(monthNum) do monName[v] = k end
            mon = monName[perl.num(mon)]
            if not mon then err = 1 end
            if truthy(length(tz)) then
                if not isMatch(tz, [[^(Z|[-+]\d{2}:?\d{2})]]) then err = 1 end
                tz = tr(tz, ':', '', 'd')
                tz = ' ' .. tz
            end
            if not err then val = day .. ' ' .. mon .. ' ' .. yr .. ' ' .. hr .. min .. sec .. tz end
        end
        if err then
            -- (upstream `warn ...; undef $val`: a warning in a conversion is
            --  its error, which this port raises)
            error("Invalid date/time (use YYYY:mm:dd HH:MM:SS[.ss][+/-HH:MM|Z])\n", 0)
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Get localized version of tagInfo hash
-- Inputs: 0) tagInfo hash ref, 1) language code (eg. "x-default")
-- Returns: new tagInfo hash ref, or undef if invalid
function GetLangInfo(tagInfo, lang)
    lang = tr(lang, '_', '-')   -- RFC 3066 specifies '-' as a separator
    -- no alternate languages for XMP or raw profile directories
    if tagInfo.SubDirectory then return nil end
    -- language code must normalized for use in tag ID
    return Writer.GetLangInfo(tagInfo, StandardLangCase(lang))
end

--------------------------------------------------------------------------------
-- Found a PNG tag -- extract info from subdirectory or decompress data if necessary
-- Inputs: 0) ExifTool object reference, 1) Pointer to tag table,
--         2) Tag ID, 3) Tag value, 4) [optional] compressed data flag:
--            0=not compressed, 1=unknown compression, 2-N=compression with type N-2
--         5) optional output buffer ref, 6) character encoding (tEXt/zTXt/iTXt only)
--         6) optional language code
-- Returns: 1 on success
local function FoundPNG(et, tagTablePtr, tag, val, compressed, outBuff, enc, lang)
    if val == nil then return 0 end
    local verbose = et:Options('Verbose')
    local id = tag  -- generate tag ID which includes language code
    if truthy(lang) then
        -- case of language code must be normalized since they are case insensitive
        lang = StandardLangCase(lang)
        id = id .. '-' .. lang
    end
    local tagInfo = et:GetTagInfo(tagTablePtr, id) or
                    -- (some software forgets to capitalize first letter)
                    et:GetTagInfo(tagTablePtr, ucfirst(id))
    -- create alternate language tag if necessary
    if not tagInfo and truthy(lang) then
        tagInfo = et:GetTagInfo(tagTablePtr, tag) or
                  et:GetTagInfo(tagTablePtr, ucfirst(tag))
        if tagInfo then tagInfo = GetLangInfo(tagInfo, lang) end
    end
--
-- uncompress data if necessary
--
    local wasCompressed, deflateErr
    if truthy(compressed) and compressed > 1 then
        if compressed == 2 then -- Inflate/Deflate compression
            if et:hasZlib() then    -- (`eval { require Compress::Zlib }`)
                local v2, stat = et:inflate(val)
                if stat then        -- (`$stat == Compress::Zlib::Z_STREAM_END()`)
                    val = v2
                    compressed = 0
                    wasCompressed = 1
                else
                    deflateErr = 'Error inflating ' .. tag
                end
            elseif not noCompressLib then
                deflateErr = 'Install Compress::Zlib to read compressed information'
            else
                deflateErr = ''   -- flag deflate error but no warning
            end
        else
            compressed = compressed - 2
            deflateErr = 'Unknown compression method ' .. compressed .. ' for ' .. tag
        end
        if truthy(compressed) and truthy(verbose) and tagInfo and tagInfo.SubDirectory then
            et:VerboseDir('Unable to decompress ' .. tagInfo.Name, 0, length(val))
        end
        -- issue warning if relevant
        if truthy(deflateErr) and not outBuff then
            et:Warn(deflateErr)
            if isMatch(deflateErr, '^Install') then noCompressLib = 1 end
        end
    end
    -- translate character encoding if necessary (tEXt/zTXt/iTXt string values only)
    if enc and not truthy(compressed) and not (tagInfo and tagInfo.SubDirectory) then
        val = et:Decode(val, enc)
    end
--
-- extract information from subdirectory if available
--
    if tagInfo then
        local tagName = tagInfo.Name
        local processed
        if tagInfo.SubDirectory then
            if truthy(et.OPTIONS.Validate) and tagInfo.NonStandard then
                et:Warn('Non-standard ' .. tagInfo.NonStandard .. ' in PNG ' .. tag .. ' chunk', 1)
            end
            local subdir = tagInfo.SubDirectory
            local dirName = subdir.DirName or tagName
            if not truthy(compressed) then
                local len = length(val)
                if truthy(verbose) and et.INDENT ~= '  ' then
                    if wasCompressed and perl.num(verbose) > 2 then
                        local name = tagName
                        if wasCompressed then name = 'Decompressed ' .. name end
                        et:VerboseDir(name, 0, len)
                        et:VerboseDump(val)
                    end
                    -- don't indent next directory (since it is really the same data)
                    et.INDENT = subst(et.INDENT, '..$', '')
                end
                local processProc = subdir.ProcessProc
                -- nothing more to do if writing and subdirectory is not writable
                local subTable = GetTagTable(nil, subdir.TagTable)
                if outBuff and not subTable.WRITE_PROC then
                    if Writer.IsGroupDeleted(et, dirName) then
                        -- non-writable directories may be deleted as a group (eg. SEAL)
                        et:VPrint(0, '  Deleting ' .. dirName .. "\n")
                        outBuff.value = carray.new('char')
                        et.CHANGED = (et.CHANGED or 0) + 1
                    end
                    return 1
                end
                local subdirInfo = {
                    DataPt   = val,
                    DirStart = 0,
                    DataLen  = len,
                    DirLen   = len,
                    DirName  = dirName,
                    TagInfo  = tagInfo,
                    ReadOnly = 1, -- (used only by WriteXMP)
                    OutBuff  = outBuff,
                    IgnoreProp = subdir.IgnoreProp, -- (XML hack for meTa chunk)
                }
                -- no need to re-decompress if already done
                if wasCompressed and processProc and processProc == ProcessPNG_Compressed then processProc = nil end
                -- rewrite this directory if necessary (but always process TextualData normally)
                if outBuff and not processProc and subTable ~= PNG.TextualData then
                    if not (et.EDIT_DIRS and et.EDIT_DIRS[dirName]) then return 1 end
                    local newData = Writer.WriteDirectory(et, subdirInfo, subTable)
                    outBuff.value = newData and carray.new('char'):append(newData)
                    if tagName == 'XMP' and truthy(outBuff.value) then
                        -- make sure the XMP is marked as read-only
                        require('lexiftool.XMP').ValidateXMP(outBuff, 'r')
                    end
                    DoneDir(et, dirName, outBuff, tagInfo.NonStandard)
                else
                    processed = et:ProcessDirectory(subdirInfo, subTable, processProc)
                end
                compressed = 1    -- pretend this is compressed since it is binary data
            elseif outBuff then
                if Writer.IsGroupDeleted(et, dirName) or (dirName == 'EXIF' and Writer.IsGroupDeleted(et, 'IFD0')) then
                    outBuff.value = carray.new('char')
                    et.CHANGED = (et.CHANGED or 0) + 1
                    et:VPrint(0, '  Deleting ' .. tag .. ' chunk')
                else
                    if (et.EDIT_DIRS and et.EDIT_DIRS[dirName]) or
                        (dirName == 'EXIF' and et.EDIT_DIRS and et.EDIT_DIRS.IFD0)
                    then
                        et:Warn("Can't write " .. dirName .. '. Requires Compress::Zlib')
                    end
                    -- pretend we did this directory so we don't try to recreate it
                    DoneDir(et, dirName, outBuff, tagInfo.NonStandard)
                end
            end
        end
        if outBuff then
            local writable = tagInfo.Writable
            local isOverwriting
            if truthy(writable) or (tagTablePtr.WRITABLE and
                writable == nil and not tagInfo.SubDirectory)
            then
                -- write new value for this tag if necessary
                local newVal
                if Writer.IsGroupDeleted(et, 'PNG') then
                    -- remove this tag now, but keep in ADD_PNG list to add back later
                    isOverwriting = 1
                else
                    -- remove this from the list of PNG tags to add
                    -- (upstream autovivifies ADD_PNG, which AddChunks deletes)
                    if et.ADD_PNG then
                        et.ADD_PNG[id] = nil
                        -- (also handle case of tEXt tags written with lowercase first letter)
                        et.ADD_PNG[ucfirst(id)] = nil
                    end
                    local nvHash = Writer.GetNewValueHash(et, tagInfo)
                    isOverwriting = Writer.IsOverwriting(et, nvHash)
                    if deflateErr ~= nil then
                        newVal = et:GetNewValue(nvHash)
                        -- can only write tag now if always overwriting
                        if isOverwriting > 0 then
                            val = '<deflate error>'
                        elseif isOverwriting ~= 0 then
                            isOverwriting = 0 -- can't overwrite
                            if truthy(deflateErr) then et:Warn(deflateErr) end
                        end
                    else
                        if isOverwriting < 0 then
                            isOverwriting = Writer.IsOverwriting(et, nvHash, val)
                        end
                        -- (must get new value after IsOverwriting() in case it was shifted)
                        newVal = et:GetNewValue(nvHash)
                    end
                end
                if truthy(isOverwriting) then
                    outBuff.value = carray.new('char'):append(newVal ~= nil and perl.str(newVal) or '')
                    et.CHANGED = (et.CHANGED or 0) + 1
                    et:VerboseValue('- PNG:' .. tagName, val)
                    if newVal ~= nil then et:VerboseValue('+ PNG:' .. tagName, newVal) end
                end
            end
            if outBuff.value ~= nil and truthy(length(outBuff.value)) then
                if enc then -- must be tEXt/zTXt/iTXt if $enc is set
                    outBuff.value = carray.new('char'):append(BuildTextChunk(et, tag, tagInfo, outBuff.value:tostring(), lang))
                elseif wasCompressed then
                    -- re-compress the output data
                    local len = length(outBuff.value)
                    local deflate = ExifTool.deflateInit()
                    if deflate then
                        outBuff.value = deflate:deflate(outBuff.value, carray.new('char'))
                        if outBuff.value ~= nil then deflate:flush(outBuff.value) end
                    else
                        outBuff.value = nil
                    end
                    if not truthy(outBuff.value) then
                        et:Warn('PNG:' .. tagName .. ' not written (compress error)')
                    elseif lc(tag) == 'zxif' then
                        outBuff.value = carray.new('char'):append("\0" .. pack('N', len), outBuff.value)  -- add zXIf header
                    end
                end
            end
            return 1
        end
        if truthy(processed) then return 1 end
    elseif outBuff then
        if Writer.IsGroupDeleted(et, 'PNG') and tagTablePtr == PNG.TextualData then
            -- delete all TextualData tags if deleting the PNG group
            outBuff.value = carray.new('char')
            et.CHANGED = (et.CHANGED or 0) + 1
            et:VerboseValue('- PNG:' .. tag, val)
        end
        return 1
    else
        local name = subst(tag, [[\s+(.)]], function(c) return ucfirst(c) end, 'g') -- remove white space from tag name
        tagInfo = { Name = name }
        if truthy(lang) then tagInfo.LangCode = lang end
        -- make unknown profiles binary data type
        if isMatch(tag, '^Raw profile type ') then tagInfo.Binary = 1 end
        if truthy(verbose) then et:VPrint(0, '  [adding ' .. tag .. "]\n") end
        AddTagToTable(nil, tagTablePtr, tag, tagInfo)
    end
--
-- store this tag information
--
    if truthy(verbose) then
        -- temporarily remove subdirectory so it isn't printed in verbose information
        -- since we aren't decoding it anyway;
        local subdir = tagInfo.SubDirectory
        tagInfo.SubDirectory = nil
        et:VerboseInfo(tag, tagInfo, {
            Table  = tagTablePtr,
            DataPt = val,
        })
        if subdir then tagInfo.SubDirectory = subdir end
    end
    -- set the RawConv dynamically depending on whether this is binary or not
    local delRawConv
    if truthy(compressed) and tagInfo.ValueConv == nil then
        tagInfo.RawConv = function(_self, v) return { ref = 'SCALAR', value = v } end -- ('\$val')
        delRawConv = 1
    end
    et:FoundTag(tagInfo, val)
    if delRawConv then tagInfo.RawConv = nil end
    return 1
end

--------------------------------------------------------------------------------
-- Process encoded PNG profile information
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success
local function ProcessProfile(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local tagInfo = dirInfo.TagInfo
    local outBuff = dirInfo.OutBuff
    local tagName = tagInfo.Name

    -- ImageMagick 5.3.6 writes profiles with the following headers:
    -- "\nICC Profile\n", "\nIPTC profile\n", "\n\xaa\x01{generic prof\n"
    -- and "\ngeneric profile\n"
    local profileType, len, hex = matches(dataPt, [[(?s)^\n(.*?)\n\s*(\d+)\n(.*)]])
    if not profileType then return 0 end
    -- data is encoded in hex, so change back to binary
    local buff = pack('H*', join('', split(' ', hex)))
    local actualLen = length(buff)
    if len ~= perl.str(actualLen) then
        et:Warn(tagName .. ' is wrong size (should be ' .. len .. ' bytes but is ' .. actualLen .. ')')
        len = actualLen
    end
    len = perl.num(len)
    local verbose = et:Options('Verbose')
    if truthy(verbose) then
        if perl.num(verbose) > 2 then
            et:VerboseDir('Decoded ' .. tagName, 0, len)
            et:VerboseDump(buff)
        end
        -- don't indent next directory (since it is really the same data)
        et.INDENT = subst(et.INDENT, '..$', '')
    end
    local dirInfo_ = {   -- (upstream's inner `my %dirInfo`)
        Parent   = 'PNG',
        DataPt   = buff,
        DataLen  = len,
        DirStart = 0,
        DirLen   = len,
        Base     = 0,
        OutFile  = outBuff,
    }
    et.PROCESSED = { }    -- reset processed directory offsets
    local processed = 0
    local oldChanged = et.CHANGED
    local exifTable = GetTagTable(nil, 'lexiftool.Exif.Main')
    local editDirs = et.EDIT_DIRS or { }

    if tagTablePtr ~= exifTable then
        -- this is unfortunate, but the "IPTC" profile may be stored as either
        -- IPTC IIM or a Photoshop IRB resource, so we must test for this
        if tagName == 'IPTC_Profile' and isMatch(buff, [[^\x1c]]) then
            tagTablePtr = GetTagTable(nil, 'lexiftool.IPTC.Main')
        end
        -- process non-EXIF and non-APP1 profile as-is
        if outBuff then
            -- no need to rewrite this if not editing tags in this directory
            local dir = tagName
            if not isMatch(dir, '^ICC') then dir = subst(dir, '_Profile', '') end
            if not editDirs[dir] then return 1 end
            local newData = Writer.WriteDirectory(et, dirInfo_, tagTablePtr)
            outBuff.value = newData and carray.new('char'):append(newData)
            DoneDir(et, dir, outBuff, tagInfo.NonStandard)
        else
            processed = et:ProcessDirectory(dirInfo_, tagTablePtr)
        end
    elseif isMatchDyn(buff, '^' .. ExifTool.exifAPP1hdr) then
        -- APP1 EXIF information
        if outBuff and not editDirs.IFD0 then return 1 end
        local hdrLen = length(ExifTool.exifAPP1hdr)
        dirInfo_.DirStart = dirInfo_.DirStart + hdrLen
        dirInfo_.DirLen = dirInfo_.DirLen - hdrLen
        if outBuff then
            -- delete non-standard EXIF if recreating from scratch
            if Writer.IsGroupDeleted(et, 'EXIF') or Writer.IsGroupDeleted(et, 'IFD0') then
                outBuff.value = carray.new('char')
                et:VPrint(0, '  Deleting non-standard APP1 EXIF information')
                return 1
            end
            local newData = Writer.WriteDirectory(et, dirInfo_, tagTablePtr,
                                                  Writer.WriteTIFF)
            outBuff.value = newData and carray.new('char'):append(newData)
            if truthy(outBuff.value) then outBuff.value = carray.new('char'):append(ExifTool.exifAPP1hdr, outBuff.value) end
            DoneDir(et, 'IFD0', outBuff, tagInfo.NonStandard)
        else
            processed = et:ProcessTIFF(dirInfo_)
        end
    elseif isMatchDyn(buff, '^' .. ExifTool.xmpAPP1hdr) then
        -- APP1 XMP information
        local hdrLen = length(ExifTool.xmpAPP1hdr)
        local tagTablePtr_ = GetTagTable(nil, 'lexiftool.XMP.Main')   -- (upstream's inner `my $tagTablePtr`)
        dirInfo_.DirStart = dirInfo_.DirStart + hdrLen
        dirInfo_.DirLen = dirInfo_.DirLen - hdrLen
        if outBuff then
            if not editDirs.XMP then return 1 end
            local newData = Writer.WriteDirectory(et, dirInfo_, tagTablePtr_)
            outBuff.value = newData and carray.new('char'):append(newData)
            if truthy(outBuff.value) then outBuff.value = carray.new('char'):append(ExifTool.xmpAPP1hdr, outBuff.value) end
            DoneDir(et, 'XMP', outBuff, tagInfo.NonStandard)
        else
            processed = et:ProcessDirectory(dirInfo_, tagTablePtr_)
        end
    elseif isMatch(buff, [[^(MM\0\x2a|II\x2a\0)]]) then
        -- TIFF information
        if outBuff and not editDirs.IFD0 then return 1 end
        if outBuff then
            -- delete non-standard EXIF if recreating from scratch
            if Writer.IsGroupDeleted(et, 'EXIF') or Writer.IsGroupDeleted(et, 'IFD0') then
                outBuff.value = carray.new('char')
                et:VPrint(0, '  Deleting non-standard EXIF/TIFF information')
                return 1
            end
            local newData = Writer.WriteDirectory(et, dirInfo_, tagTablePtr,
                                                  Writer.WriteTIFF)
            outBuff.value = newData and carray.new('char'):append(newData)
            DoneDir(et, 'IFD0', outBuff, tagInfo.NonStandard)
        else
            processed = et:ProcessTIFF(dirInfo_)
        end
    else
        local profName = profileType
        profName = tr(profName, [[\x00-\x1f\x7f-\xff]], '.')
        et:Warn("Unknown raw profile '" .. profName .. "'")
    end
    if outBuff and outBuff.value ~= nil and truthy(length(outBuff.value)) then
        if et.CHANGED ~= oldChanged then
            local hdr = sprintf("\n%s\n%8d\n", profileType, length(outBuff.value))
            -- hex encode the data
            outBuff.value = carray.new('char'):append(hdr, HexEncode(outBuff.value))
        else
            outBuff.value = nil
        end
    end
    return processed
end

--------------------------------------------------------------------------------
-- Process PNG compressed zTXt or iCCP chunk
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success
-- Notes: writes new chunk data to ${$$dirInfo{OutBuff}} if writing tag
function ProcessPNG_Compressed(et, dirInfo, tagTablePtr)
    local fields = split([[\0]], dirInfo.DataPt, 2)
    local tag, val = fields[1], fields[2]
    if val == nil then return 0 end
    -- set compressed to 2 + compression method to decompress the data
    local compressed = 2 + perl.num((unpack('C', val)))
    local hdr = tag .. "\0" .. substr(val, 0, 1)
    val = substr(val, 1) -- remove compression method byte
    local success
    local outBuff = dirInfo.OutBuff
    local tagInfo = dirInfo.TagInfo
    -- use the PNG chunk tag instead of the embedded tag name for iCCP chunks
    if tagInfo and tagInfo.Name == 'ICC_Profile' then
        et:VerboseDir('iCCP')
        tagTablePtr = PNG.Main
        if truthy(length(tag)) and not outBuff then FoundPNG(et, tagTablePtr, 'iCCP-name', tag) end
        success = FoundPNG(et, tagTablePtr, 'iCCP', val, compressed, outBuff)
        if outBuff and truthy(outBuff.value) then
            local profileName = et:GetNewValue(PNG.Main['iCCP-name'])
            if profileName ~= nil then
                hdr = profileName .. substr(hdr, length(tag))
                et:VerboseValue('+ PNG:ProfileName', profileName)
            end
            outBuff.value = carray.new('char'):append(hdr, outBuff.value)
        end
    else
        success = FoundPNG(et, tagTablePtr, tag, val, compressed, outBuff, 'Latin')
    end
    return success
end

--------------------------------------------------------------------------------
-- Process PNG tEXt chunk
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success
-- Notes: writes new chunk data to ${$$dirInfo{OutBuff}} if writing tag
function ProcessPNG_tEXt(et, dirInfo, tagTablePtr)
    local fields = split([[\0]], dirInfo.DataPt, 2)
    local tag, val = fields[1], fields[2]
    local outBuff = dirInfo.OutBuff
    if truthy(et.OPTIONS.Verbose) then et.INDENT = substr(et.INDENT, 0, -2) end
    return FoundPNG(et, tagTablePtr, tag, val, nil, outBuff, 'Latin')
end

--------------------------------------------------------------------------------
-- Process PNG iTXt chunk
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success
-- Notes: writes new chunk data to ${$$dirInfo{OutBuff}} if writing tag
function ProcessPNG_iTXt(et, dirInfo, tagTablePtr)
    local fields = split([[\0]], dirInfo.DataPt, 2)
    local tag, dat = fields[1], fields[2]
    if not (dat ~= nil and length(dat) >= 4) then return 0 end
    local compressed, meth = unpack('CC', dat)
    local fields2 = split([[\0]], substr(dat, 2), 3)
    local lang, val = fields2[1], fields2[3]   -- (fields2[2] is upstream's unused $trans)
    -- set compressed flag so we will decompress it in FoundPNG()
    if truthy(compressed) then compressed = 2 + meth end
    local outBuff = dirInfo.OutBuff
    if truthy(et.OPTIONS.Verbose) then et.INDENT = substr(et.INDENT, 0, -2) end
    return FoundPNG(et, tagTablePtr, tag, val, compressed, outBuff, 'UTF8', lang)
end

--------------------------------------------------------------------------------
-- Process PNG eXIf/zXIf chunk
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success
-- Notes: writes new chunk data to ${$$dirInfo{OutBuff}} if writing tag
function ProcessPNG_eXIf(et, dirInfo, tagTablePtr)
    local outBuff = dirInfo.OutBuff
    local dataPt = dirInfo.DataPt
    local tagInfo = dirInfo.TagInfo
    local tag = tagInfo.TagID
    local del = outBuff and (Writer.IsGroupDeleted(et, 'EXIF') or Writer.IsGroupDeleted(et, 'IFD0'))
    local type_

    if isMatch(dataPt, [[^Exif\0\0]]) then
        et:Warn('Improper "Exif00" header in EXIF chunk')
        dataPt = substr(dataPt, 6)
        dirInfo.DataPt = dataPt     -- (upstream changes $$dataPt in place)
        dirInfo.DataLen = length(dataPt)
        if truthy(dirInfo.DirLen) then dirInfo.DirLen = dirInfo.DirLen - 6 end
    end
    local c1 = matches(dataPt, [[^(\0|II|MM)]])
    if c1 then
        type_ = c1
    elseif del then
        et:VPrint(0, '  Deleting invalid ' .. tag .. ' chunk')
        outBuff.value = carray.new('char')
        et.CHANGED = (et.CHANGED or 0) + 1
        return 1
    else
        et:Warn('Invalid ' .. tag .. ' chunk')
        return 0
    end
    if type_ == "\0" then   -- is this compressed EXIF?
        local buf = substr(dataPt, 5)
        -- go around again to uncompress the data
        tagTablePtr = GetTagTable(nil, 'lexiftool.PNG.Main')
        return FoundPNG(et, tagTablePtr, tagInfo.TagID, buf, 2, outBuff)   -- (upstream passes \$buf)
    elseif not outBuff then
        return et:ProcessTIFF(dirInfo)
    -- (zxIf was not adopted)
    --} elsif ($del and ($et->Options('Compress') xor lc($tag) eq 'zxif')) {
    elseif del and lc(tag) == 'zxif' then
        et:VPrint(0, '  Deleting ' .. tag .. ' chunk')
        outBuff.value = carray.new('char')
        et.CHANGED = (et.CHANGED or 0) + 1
    elseif et.EDIT_DIRS and et.EDIT_DIRS.IFD0 then
        local newData = Writer.WriteDirectory(et, dirInfo, tagTablePtr,
                                              Writer.WriteTIFF)
        outBuff.value = newData and carray.new('char'):append(newData)
        DoneDir(et, 'IFD0', outBuff, tagInfo.NonStandard)
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract meta information from a PNG image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PNG image, or -1 on write error
local function ProcessPNG(et, dirInfo)
    local outfile = dirInfo.OutFile
    local raf = dirInfo.RAF
    local datChunk = ''
    local datCount = 0
    local datBytes = 0
    local fastScan = et:Options('FastScan')
    local hash = rawget(et, 'ImageDataHash')   -- (the member, not the method of that name)
    local n, sig, err, hbuf, dbuf, cbuf
    local wasHdr, wasEnd, wasDat, doTxt, wasTrailer
    local txtOffset = {}

    -- check to be sure this is a valid PNG/MNG/JNG image
    n, sig = raf:Read(8)
    if not (n == 8 and pngLookup[sig]) then return 0 end

    if outfile then
        -- (upstream's Exif tables always carry WRITE_PROC => \&WriteExif; this
        --  port wires it when WriteExif is loaded)
        require('lexiftool.WriteExif')
        et.TextChunkType = nil
        if outfile and not Write(outfile, sig) then err = 1 end
        -- can only add tags in Main and TextualData tables
        et.ADD_PNG = Writer.GetNewTagInfoHash(et,
            PNG.Main,
            PNG.TextualData)
        -- initialize with same directories, with PNG tags taking priority
        Writer.InitWriteDirs(et, pngMap, 'PNG')
    else
        -- disable buffering in FastScan mode
        if truthy(fastScan) then raf.NoBuffer = 1 end
    end
    local fileType, hdrChunk, endChunk = table.unpack(pngLookup[sig])
    et:SetFileType(fileType)  -- set the FileType tag
    SetByteOrder('MM') -- PNG files are big-endian
    local tagTablePtr = GetTagTable(nil, 'lexiftool.PNG.Main')
    local mngTablePtr
    if fileType ~= 'PNG' then
        mngTablePtr = GetTagTable(nil, 'lexiftool.MNG.Main')
    end
    local verbose = et:Options('Verbose')
    local validate = et:Options('Validate')
    local out = et:Options('TextOut') or io.stdout   -- (TextOut defaults to STDOUT)

    -- scan ahead to find offsets of all text chunks after IDAT
    if outfile then
        while true do
            n, hbuf = raf:Read(8)
            if n ~= 8 then break end
            local len, chunk = unpack('Na4', hbuf)
            if len > 0x7fffffff then break end
            if wasDat then
                if noLeapFrog[chunk] then break end -- (don't move text across these chunks)
                if isTxtChunk[chunk] then txtOffset[#txtOffset + 1] = raf:Tell() - 8 end
            elseif isDatChunk[chunk] then
                wasDat = chunk
            end
            if not raf:Seek(len + 4, 1) then break end    -- skip chunk data
        end
        if not raf:Seek(8, 0) then et:Error('Error seeking in file') return -1 end
        wasDat = nil
    end

    -- process the PNG/MNG/JNG chunks
    noCompressLib = nil
    while true do
        if truthy(doTxt) then
            -- read text chunks that were found after IDAT so we can write them before
            if not raf:Seek(table.remove(txtOffset, 1), 0) then et:Error('Seek error') break end
            -- (this is the IDAT offset if @txtOffset is now empty)
            if #txtOffset == 0 then doTxt = nil end
        end
        n, hbuf = raf:Read(8)   -- read chunk header

        if wasEnd then
            if n == 0 then break end -- stop now if normal end of PNG
            et:Warn('Trailer data after ' .. fileType .. ' ' .. endChunk .. ' chunk', 1)
            wasTrailer = 1
            if n < 8 then break end
            et.SET_GROUP1 = 'Trailer'
        elseif n ~= 8 then
            if not wasEnd then et:Warn('Truncated ' .. fileType .. ' image') end
            break
        end
        local len, chunk = unpack('Na4', hbuf)
        if len > 0x7fffffff then
            if not wasEnd then et:Warn('Invalid ' .. fileType .. ' chunk size') end
            break
        end
        if truthy(verbose) then
            if truthy(doTxt) then out:write('  Moving ' .. chunk .. ' from after IDAT (' .. len .. " bytes)\n") end
            -- don't dump image data chunks in verbose mode (only give count instead)
            if datCount ~= 0 and chunk ~= datChunk then
                local s = datCount > 1 and 's' or ''
                out:write(fileType .. ' ' .. datChunk .. ' (' .. datCount .. ' chunk' .. s .. ', total ' .. datBytes .. " bytes)\n")
                if hash then out:write(et.INDENT .. '(ImageDataHash: ' .. datBytes .. ' bytes of ' .. datChunk .. " data)\n") end
                datCount = 0
                datBytes = 0
            end
        end
        if not wasHdr then
            if chunk == hdrChunk then
                wasHdr = 1
            elseif hdrChunk == 'IHDR' and chunk == 'CgBI' then
                et:Warn('Non-standard PNG image (Apple iPhone format)')
            else
                et:Warn(fileType .. ' image did not start with ' .. hdrChunk)
            end
        end
        if outfile and (isDatChunk[chunk] or chunk == endChunk) and #txtOffset > 0 then
            -- continue processing here after we move the text chunks from after IDAT
            txtOffset[#txtOffset + 1] = raf:Tell() - 8
            doTxt = 1     -- process text chunks now
            goto continue
        end
        if isDatChunk[chunk] then
            if truthy(fastScan) and perl.num(fastScan) >= 2 then
                et:VPrint(0, 'End processing at ' .. chunk .. ' chunk due to FastScan=' .. fastScan .. ' setting')
                break
            end
            datChunk = chunk
            datCount = datCount + 1
            datBytes = datBytes + len
            wasDat = chunk
        else
            datChunk = ''
        end
        if outfile then
            -- add text chunks (including XMP) before any data chunk end chunk
            if datChunk ~= '' or chunk == endChunk then
                -- write iCCP chunk now if requested because AddChunks will try
                -- to add it as a text profile chunk if this isn't successful
                -- (ie. if Compress::Zlib wasn't available)
                Add_iCCP(et, outfile)
                if not AddChunks(et, outfile) then err = 1 end           -- add all text chunks
                if not AddChunks(et, outfile, 'IFD0') then err = 1 end   -- and eXIf chunk
            elseif chunk == 'PLTE' then
                -- iCCP chunk must come before PLTE (and IDAT, handled above)
                -- (ignore errors -- will add later as text profile if this fails)
                Add_iCCP(et, outfile)
            end
        end
        if chunk == endChunk then
            -- read CRC
            n, cbuf = raf:Read(4)
            if n ~= 4 then
                if not wasEnd then et:Warn('Truncated ' .. fileType .. ' ' .. endChunk .. ' chunk') end
                break
            end
            if truthy(verbose) then out:write(fileType .. ' ' .. chunk .. " (end of image)\n") end
            wasEnd = 1
            if outfile then
                -- write the IEND/MEND chunk with CRC
                if not Write(outfile, hbuf, cbuf) then err = 1 end
                if Writer.IsGroupDeleted(et, 'Trailer') then
                    n = raf:Read(1)
                    if n ~= 0 then
                        if truthy(verbose) then out:write("  Deleting PNG trailer\n") end
                        et.CHANGED = (et.CHANGED or 0) + 1
                    end
                else
                    -- copy over any existing trailer data
                    local tot = 0
                    while true do
                        n, hbuf = raf:Read(65536)
                        if n == 0 then break end
                        tot = tot + n
                        if not Write(outfile, hbuf) then err = 1 end
                    end
                    if tot ~= 0 and truthy(verbose) then out:write('  Copying PNG trailer (' .. tot .. " bytes)\n") end
                end
                break
            end
            goto continue
        end
        if datChunk ~= '' then
            local chunkSizeLimit = 10000000  -- largest chunk to read into memory
            if outfile then
                -- avoid loading very large data chunks into memory
                if len > chunkSizeLimit then
                    if not Write(outfile, hbuf) then err = 1 end
                    if not Writer.CopyBlock(raf, outfile, len + 4) then et:Error('Error copying ' .. datChunk) end
                    goto continue
                end
            -- skip over data chunks if possible/necessary
            elseif not truthy(validate) or len > chunkSizeLimit then
                if hash then
                    et:ImageDataHash(raf, len)
                    n, cbuf = raf:Read(4)
                    if n ~= 4 then et:Warn('Truncated data') break end
                else
                    if not raf:Seek(len + 4, 1) then et:Warn('Seek error') break end
                end
                goto continue
            end
        elseif wasDat and isTxtChunk[chunk] then
            local msg
            if not outfile then
                msg = 'may be ignored by some readers'
            elseif doTxt ~= nil then   -- $doTxt == 0 if we crossed a noLeapFrog chunk
                msg = "can't be moved" -- (but could be deleted then added back again)
            else
                msg = 'fixed'
            end
            et:Warn('Text/EXIF chunk(s) found after ' .. perl.str(et.FileType) .. ' ' .. wasDat .. ' (' .. msg .. ')', 1)
        end
        -- read chunk data and CRC
        do
            local ok = false
            n, dbuf = raf:Read(len)
            if n == len then
                n, cbuf = raf:Read(4)
                ok = (n == 4)
            end
            if not ok then
                if not wasEnd then et:Warn('Corrupted ' .. fileType .. ' image') end
                break
            end
        end
        if hash and datChunk ~= '' then hash:add(dbuf) end  -- add to hash if necessary
        if truthy(verbose) or truthy(validate) or (outfile and not truthy(fastScan)) then
            -- check CRC when in verbose mode (since we don't care about speed)
            local crc = CalculateCRC(hbuf, nil, 4)
            crc = CalculateCRC(dbuf, crc)
            if crc ~= unpack('N', cbuf) then
                local msg = 'Bad CRC for ' .. chunk .. ' chunk'
                if outfile then et:Error(msg, 1) else et:Warn(msg) end
            end
            if datChunk ~= '' then
                if outfile and not Write(outfile, hbuf, dbuf, cbuf) then err = 1 end
                goto continue
            end
            -- just skip over any text chunk found after IDAT
            if outfile and wasDat then
                if isTxtChunk[chunk] and doTxt == nil then
                    if et.FORCE_WRITE and et.FORCE_WRITE.PNG then et.CHANGED = (et.CHANGED or 0) + 1 end
                    if truthy(verbose) then out:write('  Deleting ' .. chunk .. ' that was moved (' .. len .. " bytes)\n") end
                    goto continue
                end
                -- done moving text if we hit one of these chunks
                if noLeapFrog[chunk] then doTxt = 0 end
            end
            if truthy(verbose) then
                out:write(fileType .. ' ' .. chunk .. ' (' .. len .. " bytes):\n")
                if perl.num(verbose) > 2 then et:VerboseDump(dbuf, { Addr = raf:Tell() - len - 4 }) end
            end
        end
        -- translate case of chunk names that have changed since the first implementation
        if not tagTablePtr[chunk] and stdCase[lc(chunk)] then
            local stdChunk = stdCase[lc(chunk)]
            if outfile and ((et.EDIT_DIRS and et.EDIT_DIRS.IFD0) or not isMatch(stdChunk, '(?i)^[ez]xif$')) then
                et:Warn('Changed ' .. chunk .. ' chunk to ' .. stdChunk, 1)
                et.CHANGED = (et.CHANGED or 0) + 1
            else
                et:Warn(chunk .. ' chunk should be ' .. stdChunk, 1)
            end
            chunk = stdCase[lc(chunk)]
        end
        do
            -- only extract information from chunks in our tables
            local theBuff, outBuff
            if outfile then outBuff = { } end    -- (upstream `\$theBuff`; FoundPNG puts a carray in)
            if tagTablePtr[chunk] then
                FoundPNG(et, tagTablePtr, chunk, dbuf, nil, outBuff)
            elseif mngTablePtr and mngTablePtr[chunk] then
                FoundPNG(et, mngTablePtr, chunk, dbuf, nil, outBuff)
            end
            if outfile then
                theBuff = outBuff.value
                if theBuff ~= nil then
                    if not truthy(length(theBuff)) then goto continue end -- empty if we deleted the information
                    -- change chunk type if necessary
                    if et.TextChunkType then
                        chunk = et.TextChunkType
                        et.TextChunkType = nil
                    end
                    hbuf = pack('Na4', length(theBuff), chunk)
                    dbuf = theBuff:tostring()
                    local crc = CalculateCRC(hbuf, nil, 4)
                    crc = CalculateCRC(dbuf, crc)
                    cbuf = pack('N', crc)
                end
                if not Write(outfile, hbuf, dbuf, cbuf) then err = 1 end
            end
        end
        ::continue::
    end
    et.SET_GROUP1 = nil
    -- read Samsung trailer if it exists
    if wasTrailer and not outfile and raf:Seek(-8, 2) then
        n, dbuf = raf:Read(8)
        if n ~= 0 and isMatch(dbuf, [[\0\0(QDIOBS|SEFT)$]]) then -- (have only seen SEFT type)
            require('lexiftool.Samsung').ProcessSamsung(et, { DirName = 'Samsung', RAF = raf })
        end
    end
    if outfile and (err or not wasEnd) then return -1 end
    return 1   -- this was a valid PNG/MNG/JNG image
end

PNG.StandardLangCase = StandardLangCase
PNG.ConvertPNGDate = ConvertPNGDate
PNG.InversePNGDate = InversePNGDate
PNG.GetLangInfo = GetLangInfo
PNG.FoundPNG = FoundPNG
PNG.ProcessProfile = ProcessProfile
PNG.ProcessPNG_Compressed = ProcessPNG_Compressed
PNG.ProcessPNG_tEXt = ProcessPNG_tEXt
PNG.ProcessPNG_iTXt = ProcessPNG_iTXt
PNG.ProcessPNG_eXIf = ProcessPNG_eXIf
PNG.ProcessPNG = ProcessPNG

-- (ProcessProc/PROCESS_PROC of the tables above: the predeclared subs exist
--  only now, see the predeclaration placeholders)
PNG.Main.iCCP.SubDirectory.ProcessProc = ProcessPNG_Compressed
PNG.Main.iTXt.SubDirectory.ProcessProc = ProcessPNG_iTXt
PNG.Main.zTXt.SubDirectory.ProcessProc = ProcessPNG_Compressed
PNG.Main[stdCase.exif].SubDirectory.ProcessProc = ProcessPNG_eXIf
PNG.Main[stdCase.zxif].SubDirectory.ProcessProc = ProcessPNG_eXIf
PNG.TextualData.PROCESS_PROC = ProcessPNG_tEXt
PNG.TextualData['Raw profile type APP1'][1].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type APP1'][2].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type exif'].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type icc'].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type icm'].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type iptc'].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type xmp'].SubDirectory.ProcessProc = ProcessProfile
PNG.TextualData['Raw profile type 8bim'].SubDirectory.ProcessProc = ProcessProfile

return PNG
