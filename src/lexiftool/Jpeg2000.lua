--------------------------------------------------------------------------------
-- File:         lexiftool/Jpeg2000.lua
-- Ported from:  lib/Image/ExifTool/Jpeg2000.pm
--
-- Description:  Read JPEG 2000 meta information
--
-- Revisions:    02/11/2005 - P. Harvey Created
--               06/22/2007 - PH Added write support (EXIF, IPTC and XMP only)
--
-- References:   1) http://www.jpeg.org/public/fcd15444-2.pdf
--               2) ftp://ftp.remotesensing.org/jpeg2000/fcd15444-1.pdf
--
-- Port notes:   Complete port of Jpeg2000.pm: every table and sub, in
--               upstream order.  Like upstream, writing covers EXIF, IPTC
--               and XMP (and the colr box, the XML tag and Brotli-
--               compressed EXIF/XMP in JXL); a J2C codestream is not
--               writable ("Writing of J2C files is not yet supported"),
--               GeoJP2 and the other read-only uuid boxes are copied with
--               upstream's "Not editing" warning, and JUMBF is not written.
--               Deviations forced by Lua:
--               - Subdirectory Start expressions and Conditions are Lua
--                 functions; a Start function gets ($et, $dataPt,
--                 $valuePtr), the variables upstream's eval sees.
--               - Upstream's `$outfile = \$outBuff` is the box
--                 { value = <carray> } of doc/api.md §4; the buffered
--                 directory comes back as a string.
--               - In the RAF branch of ProcessJpeg2000Box, `$dataPt = \$buff`
--                 makes later reads into $buff visible through $dataPt; the
--                 Lua strings are reassigned to dataPt after each read.
--               - IO::Uncompress::Brotli/IO::Compress::Brotli are the rock
--                 compress.brotli (perl.evalRequire).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local carray = require('carray')
local Write = Writer.Write
local perlTruthy = ExifTool.perlTruthy
local Get8u = ExifTool.Get8u
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local ReadValue = ExifTool.ReadValue
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local unpack = perl.unpack
local pack = perl.pack
local join = perl.join
local matches = perl.matches
local isMatch = perl.isMatch
local findAll = perl.findAll
local subst = perl.subst
local tr = perl.tr
local int = perl.int
local str = perl.str
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst

-- (upstream's GetTagTable, a plain function there)
local function GetTagTable(tableName) return ExifTool.GetTagTable(nil, tableName) end

-- (port helper: Perl's `$a || $b`, which tests $a for Perl truth)
local function perlOr(a, b)
    if perlTruthy(a) then return a end
    return b
end

local Jpeg2000 = {}

-- ExifTool Jpeg2000 version (mirror of $Image::ExifTool::Jpeg2000::VERSION)
Jpeg2000.VERSION = '1.43'

-- (upstream's predeclarations of ProcessJpeg2000Box and ProcessJUMD; the
--  subs below assign to these locals, and so does ProcessBrotli, which the
--  Main table references before its definition)
local ProcessJpeg2000Box
local ProcessJUMD
local ProcessJUMB
local ProcessBrotli

local resolutionUnit = {
    [-3] = 'km',
    [-2] = '100 m',
    [-1] = '10 m',
     [0] = 'm',
     [1] = '10 cm',
     [2] = 'cm',
     [3] = 'mm',
     [4] = '0.1 mm',
     [5] = '0.01 mm',
     [6] = 'um',
}

-- top-level boxes containing image data
local isImageData = { jp2c=1, jbrd=1, jxlp=1, jxlc=1 }

-- map of where information is written in JPEG2000 image
local jp2Map = {
    IPTC         = 'UUID-IPTC',
    IFD0         = 'UUID-EXIF',
    XMP          = 'UUID-XMP',
   ['UUID-IPTC'] = 'JP2',
   ['UUID-EXIF'] = 'JP2',
   ['UUID-XMP']  = 'JP2',
    jp2h         = 'JP2',
    colr         = 'jp2h',
    ICC_Profile  = 'colr',
    IFD1         = 'IFD0',
    EXIF         = 'IFD0', -- to write EXIF as a block
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}

-- map of where information is written in a JXL image
local jxlMap = {
    IFD0         = 'Exif',
    XMP          = 'xml ',
   ['Exif']      = 'JP2',
    IFD1         = 'IFD0',
    EXIF         = 'IFD0', -- to write EXIF as a block
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}

-- UUID's for writable UUID directories (by tag name)
local uuid = {
    ['UUID-EXIF']   = 'JpgTiffExif->JP2',
    ['UUID-EXIF2']  = '',    -- (flags a warning when writing)
    ['UUID-EXIF_bad'] = '0', -- (flags a warning when reading and writing)
    ['UUID-IPTC']   = '\x33\xc7\xa4\xd2\xb8\x1d\x47\x23\xa0\xba\xf1\xa3\xe0\x97\xad\x38',
    ['UUID-XMP']    = '\xbe\x7a\xcf\xcb\x97\xa9\x42\xe8\x9c\x71\x99\x94\x91\xe3\xaf\xac',
  -- (can't yet write GeoJP2 information)
  -- ['UUID-GeoJP2'] = '\xb1\x4b\xf8\xbd\x08\x3d\x4b\x43\xa5\xae\x8c\xd7\xd5\xa6\xce\x03',
}

-- JPEG2000 codestream markers (ref ISO/IEC FCD15444-1/2)
local j2cMarker = {
    [0x4f] = 'SOC', -- start of codestream
  -- 0x50 - seen in JPH codestream
    [0x51] = 'SIZ', -- image and tile size
    [0x52] = 'COD', -- coding style default
    [0x53] = 'COC', -- coding style component
    [0x55] = 'TLM', -- tile-part lengths
    [0x57] = 'PLM', -- packet length, main header
    [0x58] = 'PLT', -- packet length, tile-part header
  -- 0x59 - seen in JPH codestream
    [0x5c] = 'QCD', -- quantization default
    [0x5d] = 'QCC', -- quantization component
    [0x5e] = 'RGN', -- region of interest
    [0x5f] = 'POD', -- progression order default
    [0x60] = 'PPM', -- packed packet headers, main
    [0x61] = 'PPT', -- packed packet headers, tile-part
    [0x63] = 'CRG', -- component registration
    [0x64] = 'CME', -- comment and extension
    [0x90] = 'SOT', -- start of tile-part
    [0x91] = 'SOP', -- start of packet
    [0x92] = 'EPH', -- end of packet header
    [0x93] = 'SOD', -- start of data
    -- extensions (ref ISO/IEC FCD15444-2)
    [0x70] = 'DCO', -- variable DC offset
    [0x71] = 'VMS', -- visual masking
    [0x72] = 'DFS', -- downsampling factor style
    [0x73] = 'ADS', -- arbitrary decomposition style
  -- 0x72 => 'ATK', -- arbitrary transformation kernels ?
    [0x78] = 'CBD', -- component bit depth
    [0x74] = 'MCT', -- multiple component transformation definition
    [0x75] = 'MCC', -- multiple component collection
    [0x77] = 'MIC', -- multiple component intermediate collection
    [0x76] = 'NLT', -- non-linearity point transformation
}

-- JPEG 2000 "box" (ie. atom) names
-- Note: only tags with a defined "Format" are extracted
Jpeg2000.Main = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false, -- predeclaration, see below for implementation
    PREFERRED = 1, -- always add these tags when writing
    NOTES = [[
        The tags below are found in JPEG 2000 images and the C2PA CAI JUMBF metadata
        in various file types (see below).  Note that ExifTool currently writes only
        EXIF, IPTC and XMP tags in Jpeg2000 images, and EXIF and XMP in JXL images.
        ExifTool will read/write Brotli-compressed EXIF and XMP in JXL images, but
        the API L<Compress|../ExifTool.html#Compress> option must be set to create new EXIF and XMP in compressed
        format.

        C2PA (Coalition for Content Provenance and Authenticity) CAI (Content
        Authenticity Initiative) JUMBF (JPEG Universal Metadata Box Format) metdata
        is currently extracted from JPEG, PNG, TIFF-based (eg. TIFF, DNG),
        QuickTime-based (eg. MP4, MOV, HEIF, AVIF), RIFF-based (eg. WAV, AVI, WebP),
        PDF, SVG and GIF files, and ID3v2 metadata.  The suggested ExifTool
        command-line arguments for reading C2PA metadata are C<-jumbf:all -G3 -b -j
        -u -struct>.  This metadata may be deleted from writable JPEG, PNG, WebP,
        TIFF-based, and QuickTime-based files by deleting the JUMBF group with
        C<-jumbf:all=>.  The C2PA JUMBF metadata may be extracted as a block via the
        JUMBF tag.  See L<https://c2pa.org/specifications/> for the C2PA
        specification.
    ]],
--
-- NOTE: ONLY TAGS WITH "Format" DEFINED ARE EXTRACTED!
--
   ['jP  '] = 'JP2Signature', -- (ref 1)
   ['jP\x1a\x1a'] = 'JP2Signature', -- (ref 2)
    prfl = 'Profile',
    ftyp = {
        Name = 'FileType',
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.FileType' },
    },
    rreq = 'ReaderRequirements',
    jp2h = {
        Name = 'JP2Header',
        SubDirectory = { },
    },
        -- JP2Header sub boxes...
        ihdr = {
            Name = 'ImageHeader',
            SubDirectory = {
                TagTable = 'lexiftool.Jpeg2000.ImageHeader',
            },
        },
        bpcc = 'BitsPerComponent',
        colr = {
            Name = 'ColorSpecification',
            SubDirectory = {
                TagTable = 'lexiftool.Jpeg2000.ColorSpec',
            },
        },
        pclr = 'Palette',
        cdef = 'ComponentDefinition',
       ['res '] = {
            Name = 'Resolution',
            SubDirectory = { },
        },
            -- Resolution sub boxes...
            resc = {
                Name = 'CaptureResolution',
                SubDirectory = {
                    TagTable = 'lexiftool.Jpeg2000.CaptureResolution',
                },
            },
            resd = {
                Name = 'DisplayResolution',
                SubDirectory = {
                    TagTable = 'lexiftool.Jpeg2000.DisplayResolution',
                },
            },
    jpch = {
        Name = 'CodestreamHeader',
        SubDirectory = { },
    },
        -- CodestreamHeader sub boxes...
       ['lbl '] = {
            Name = 'Label',
            Format = 'string',
        },
        cmap = 'ComponentMapping',
        roid = 'ROIDescription',
    jplh = {
        Name = 'CompositingLayerHeader',
        SubDirectory = { },
    },
        -- CompositingLayerHeader sub boxes...
        cgrp = 'ColorGroup',
        opct = 'Opacity',
        creg = 'CodestreamRegistration',
    dtbl = 'DataReference',
    ftbl = {
        Name = 'FragmentTable',
        Subdirectory = { },
    },
        -- FragmentTable sub boxes...
        flst = 'FragmentList',
    cref = 'Cross-Reference',
    mdat = 'MediaData',
    comp = 'Composition',
    copt = 'CompositionOptions',
    inst = 'InstructionSet',
    asoc = {
        Name = 'Association',
        SubDirectory = { },
    },
        -- (Association box may contain any other sub-box)
    nlst = 'NumberList',
    bfil = 'BinaryFilter',
    drep = 'DesiredReproductions',
        -- DesiredReproductions sub boxes...
        gtso = 'GraphicsTechnologyStandardOutput',
    chck = 'DigitalSignature',
    mp7b = 'MPEG7Binary',
    free = 'Free',
    jp2c = {{
        Name = 'ContiguousCodestream',
        Condition = function(self) return not perlTruthy(self.jumd_level) end,
    },{
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef',
        Binary = 1,
    }},
    jp2i = {
        Name = 'IntellectualProperty',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
   ['xml '] = {{
        Name = 'XML',
        Condition = function(self) return not perlTruthy(self.IsJXL) end,
        Writable = 'undef',
        Flags = { 'Binary', 'Protected', 'BlockExtract' },
        List = 1,
        Notes = [[
            by default, the XML data in this tag is parsed using the ExifTool XMP module
            to to allow individual tags to be accessed when reading, but it may also be
            extracted as a block via the "XML" tag, which is also how this tag is
            written and copied.  It may also be extracted as a block by setting the API
            BlockExtract option.  This is a List-type tag because multiple XML blocks
            may exist
        ]],
        -- (note: extracting as a block was broken in 11.04, and finally fixed in 12.14)
        SubDirectory = { TagTable = 'lexiftool.XMP.XML' },
    },{
        Name = 'XMP',
        Notes = 'used for XMP in JPEG XL files',
        -- NOTE: the hacked code relies on this being at index 1 of the tagInfo list!
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    }},
    uuid = {
        {
            Name = 'UUID-EXIF',
            -- (this is the EXIF that we create in JP2)
            Condition = function(_self, valPt) return isMatch(valPt, [[^JpgTiffExif->JP2(?!Exif\0\0)]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                WriteProc = Writer.WriteTIFF,
                DirName = 'EXIF',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-EXIF2',
            -- written by Photoshop 7.01+Adobe JPEG2000-plugin v1.5
            Condition = function(_self, valPt) return isMatch(valPt, [[^\x05\x37\xcd\xab\x9d\x0c\x44\x31\xa7\x2a\xfa\x56\x1f\x2a\x11\x3e]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                WriteProc = Writer.WriteTIFF,
                DirName = 'EXIF',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-EXIF_bad',
            -- written by Digikam
            Condition = function(_self, valPt) return isMatch(valPt, [[^JpgTiffExif->JP2]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                WriteProc = Writer.WriteTIFF,
                DirName = 'EXIF',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 22 end,
            },
        },
        {
            Name = 'UUID-IPTC',
            -- (this is the IPTC that we create in JP2)
            Condition = function(_self, valPt) return isMatch(valPt, [[^\x33\xc7\xa4\xd2\xb8\x1d\x47\x23\xa0\xba\xf1\xa3\xe0\x97\xad\x38]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.IPTC.Main',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-IPTC2',
            -- written by Photoshop 7.01+Adobe JPEG2000-plugin v1.5
            Condition = function(_self, valPt) return isMatch(valPt, [[^\x09\xa1\x4e\x97\xc0\xb4\x42\xe0\xbe\xbf\x36\xdf\x6f\x0c\xe3\x6f]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.IPTC.Main',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-XMP',
            -- ref http://www.adobe.com/products/xmp/pdfs/xmpspec.pdf
            Condition = function(_self, valPt) return isMatch(valPt, [[^\xbe\x7a\xcf\xcb\x97\xa9\x42\xe8\x9c\x71\x99\x94\x91\xe3\xaf\xac]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.XMP.Main',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-GeoJP2',
            -- ref http://www.remotesensing.org/jpeg2000/
            Condition = function(_self, valPt) return isMatch(valPt, [[^\xb1\x4b\xf8\xbd\x08\x3d\x4b\x43\xa5\xae\x8c\xd7\xd5\xa6\xce\x03]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-Photoshop',
            -- written by Photoshop 7.01+Adobe JPEG2000-plugin v1.5
            Condition = function(_self, valPt) return isMatch(valPt, [[^\x2c\x4c\x01\x00\x85\x04\x40\xb9\xa0\x3e\x56\x21\x48\xd6\xdf\xeb]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.Photoshop.Main',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-C2PAClaimSignature',  -- (seen in incorrectly-formatted JUMB data of JPEG images)
            -- (may be able to remove this when JUMBF specification is finalized)
            Condition = function(_self, valPt) return isMatch(valPt, [[^c2cs\x00\x11\x00\x10\x80\x00\x00\xaa\x00\x38\x9b\x71]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.CBOR.Main',
                Start = function(_et, _dataPt, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-Signature',  -- (seen in JUMB data of JPEG images)
            -- (may be able to remove this when JUMBF specification is finalized)
            Condition = function(_self, valPt) return isMatch(valPt, [[^casg\x00\x11\x00\x10\x80\x00\x00\xaa\x00\x38\x9b\x71]]) end,
            Format = 'undef',
            ValueConv = function(_self, val) return substr(val, 16) end,
        },
        {
            Name = 'UUID-Unknown',
        },
        -- also written by Adobe JPEG2000 plugin v1.5:
        -- 3a 0d 02 18 0a e9 41 15 b3 76 4b ca 41 ce 0e 71 - 1 byte (01)
        -- 47 c9 2c cc d1 a1 45 81 b9 04 38 bb 54 67 71 3b - 1 byte (01)
        -- bc 45 a7 74 dd 50 4e c6 a9 f6 f3 a1 37 f4 7e 90 - 4 bytes (00 00 00 32)
        -- d7 c8 c5 ef 95 1f 43 b2 87 57 04 25 00 f5 38 e8 - 4 bytes (00 00 00 32)
    },
    uinf = {
        Name = 'UUIDInfo',
        SubDirectory = { },
    },
        -- UUIDInfo sub boxes...
        ulst = 'UUIDList',
       ['url '] = {
            Name = 'URL',
            Format = 'string',
        },
    -- JUMBF boxes (ref https://github.com/thorfdbg/codestream-parser)
    jumd = {
        Name = 'JUMBFDescr',
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.JUMD' },
    },
    jumb = {
        Name = 'JUMBFBox',
        SubDirectory = {
            TagTable = 'lexiftool.Jpeg2000.Main',
            ProcessProc = function(...) return ProcessJUMB(...) end,
        },
    },
    json = {
        Name = 'JSONData',
        Flags = { 'Binary', 'Protected', 'BlockExtract' },
        Notes = [[
            by default, data in this tag is parsed using the ExifTool JSON module to to
            allow individual tags to be accessed when reading, but it may also be
            extracted as a block via the "JSONData" tag or by setting the API
            BlockExtract option
        ]],
        SubDirectory = { TagTable = 'lexiftool.JSON.Main' },
    },
    cbor = {
        Name = 'CBORData',
        Flags = { 'Binary', 'Protected' },
        SubDirectory = { TagTable = 'lexiftool.CBOR.Main' },
    },
    bfdb = { -- used in JUMBF
        Name = 'BinaryDataType',
        Notes = 'JUMBF, MIME type and optional file name',
        Format = 'undef',
        -- (ignore "toggles" byte and just extract MIME type and file name)
        ValueConv = function(_self, val)
            local _ = substr(val, 1); _ = subst(_, [[\0+$]], ''); _ = subst(_, [[\0]], ', '); return _
        end,
        JUMBF_Suffix = 'Type', -- (used when tag is renamed according to JUMDLabel)
    },
    bidb = { -- used in JUMBF
        Name = 'BinaryData',
        Notes = 'JUMBF',
        Groups = { [2] = 'Preview' },
        Format = 'undef',
        Binary = 1,
        JUMBF_Suffix = 'Data', -- (used when tag is renamed according to JUMDLabel)
    },
    c2sh = { -- used in JUMBF
        Name = 'C2PASaltHash',
        Format = 'undef',
        ValueConv = function(_self, val) return unpack('H*', val) end,
        JUMBF_Suffix = 'Salt', -- (used when tag is renamed according to JUMDLabel)
    },
--
-- stuff seen in JPEG XL images:
--
  -- jbrd - JPEG Bitstream Reconstruction Data (allows lossless conversion back to original JPG)
    jxlc = {
        Name = 'JXLCodestream',
        Format = 'undef',
        Notes = [[
            Codestream in JPEG XL image.  Currently processed only to determine
            ImageSize
        ]],
        RawConv = function(self, val) Jpeg2000.ProcessJXLCodestream(self, val); return nil end,
    },
    jxlp = {
        Name = 'PartialJXLCodestream',
        Format = 'undef',
        Notes = [[
            Partial codestreams in JPEG XL image.  Currently processed only to determine
            ImageSize
        ]],
        RawConv = function(self, val) Jpeg2000.ProcessJXLCodestream(self, val); return nil end,
    },
    Exif = {
        Name = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            WriteProc = Writer.WriteTIFF,
            DirName = 'EXIF',
            Start = function(_et, dataPt, valuePtr) return valuePtr + 4 + (length(dataPt)-valuePtr > 4 and unpack('N', dataPt) or 0) end,
        },
    },
    hrgm = {
        Name = 'GainMapImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef',
        Binary = 1,
    },
    brob = {{ -- Brotli-encoded metadata (see https://libjxl.readthedocs.io/en/latest/api_decoder.html)
        Name = 'BrotliXMP',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?i)^xml ]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
            ProcessProc = function(...) return ProcessBrotli(...) end,
            WriteProc = function(...) return ProcessBrotli(...) end,
            -- (don't set DirName to 'XMP' because this would enable a block write of raw XMP)
        },
    },{
        Name = 'BrotliEXIF',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?i)^exif]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = function(...) return ProcessBrotli(...) end,
            WriteProc = function(...) return ProcessBrotli(...) end,
            -- (don't set DirName to 'EXIF' because this would enable a block write of raw EXIF)
        },
    },{
        Name = 'BrotliJUMB',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?i)^jumb]]) end,
        SubDirectory = {
            TagTable = 'lexiftool.Jpeg2000.Main',
            ProcessProc = function(...) return ProcessBrotli(...) end,
        },
    }},
}

Jpeg2000.ImageHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'ImageHeight',
        Format = 'int32u',
    },
    [4] = {
        Name = 'ImageWidth',
        Format = 'int32u',
    },
    [8] = {
        Name = 'NumberOfComponents',
        Format = 'int16u',
    },
    [10] = {
        Name = 'BitsPerComponent',
        PrintConv = function(_self, val)
            if val == 0xff then return 'Variable' end
            local sign = (val & 0x80) ~= 0 and 'Signed' or 'Unsigned'
            return str((val & 0x7f) + 1) .. ' Bits, ' .. sign
        end,
    },
    [11] = {
        Name = 'Compression',
        PrintConv = {
            [0] = 'Uncompressed',
            [1] = 'Modified Huffman',
            [2] = 'Modified READ',
            [3] = 'Modified Modified READ',
            [4] = 'JBIG',
            [5] = 'JPEG',
            [6] = 'JPEG-LS',
            [7] = 'JPEG 2000',
            [8] = 'JBIG2',
        },
    },
}

-- (ref fcd15444-1/2/6.pdf)
-- (also see http://developer.apple.com/mac/library/documentation/QuickTime/QTFF/QTFFChap1/qtff1.html)
Jpeg2000.FileType = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    [0] = {
        Name = 'MajorBrand',
        Format = 'undef[4]',
        PrintConv = {
            ['jp2 '] = 'JPEG 2000 Image (.JP2)',           -- image/jp2
            ['jpm '] = 'JPEG 2000 Compound Image (.JPM)',  -- image/jpm
            ['jpx '] = 'JPEG 2000 with extensions (.JPX)', -- image/jpx
            ['jxl '] = 'JPEG XL Image (.JXL)',             -- image/jxl
            ['jph '] = 'High-throughput JPEG 2000 (.JPH)', -- image/jph
        },
    },
    [1] = {
        Name = 'MinorVersion',
        Format = 'undef[4]',
        ValueConv = function(_self, val) return sprintf('%x.%x.%x', unpack('nCC', val)) end,
    },
    [2] = {
        Name = 'CompatibleBrands',
        Format = 'undef[$size-8]',
        List = 1, -- (for documentation only)
        -- ignore any entry with a null, and return others as a list
        ValueConv = function(_self, val)
            local a = findAll(val, [[(?s).{4}]])
            -- (grep(!/\0/,@a))
            local b = { }
            for _, v in ipairs(a) do if not isMatch(v, [[\0]]) then b[#b + 1] = v end end
            return b
        end,
    },
}

Jpeg2000.CaptureResolution = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int8s',
    [0] = {
        Name = 'CaptureYResolution',
        Format = 'rational32u',
    },
    [4] = {
        Name = 'CaptureXResolution',
        Format = 'rational32u',
    },
    [8] = {
        Name = 'CaptureYResolutionUnit',
        SeparateTable = 'ResolutionUnit',
        PrintConv = resolutionUnit,
    },
    [9] = {
        Name = 'CaptureXResolutionUnit',
        SeparateTable = 'ResolutionUnit',
        PrintConv = resolutionUnit,
    },
}

Jpeg2000.DisplayResolution = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int8s',
    [0] = {
        Name = 'DisplayYResolution',
        Format = 'rational32u',
    },
    [4] = {
        Name = 'DisplayXResolution',
        Format = 'rational32u',
    },
    [8] = {
        Name = 'DisplayYResolutionUnit',
        SeparateTable = 'ResolutionUnit',
        PrintConv = resolutionUnit,
    },
    [9] = {
        Name = 'DisplayXResolutionUnit',
        SeparateTable = 'ResolutionUnit',
        PrintConv = resolutionUnit,
    },
}

Jpeg2000.ColorSpec = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData, -- (we don't actually call this)
    CHECK_PROC = Writer.CheckBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int8s',
    WRITABLE = 1,
    -- (Note: 'colr' is not a real group, but is used as a hack to write the
    --  necessary colr box.  This hack necessitated another hack in TagInfoXML.pm
    --  to avoid reporting this fake group in the XML output)
    WRITE_GROUP = 'colr',
    DATAMEMBER = { 0 },
    IS_SUBDIR = { 3 },
    NOTES = [[
        The table below contains tags in the color specification (colr) box.  This
        box may be rewritten by writing either ICC_Profile, ColorSpace or
        ColorSpecData.  When writing, any existing colr boxes are replaced with the
        newly created colr box.

        B<NOTE>: Care must be taken when writing this color specification because
        writing a specification that is incompatible with the image data may make
        the image undisplayable.
    ]],
    [0] = {
        Name = 'ColorSpecMethod',
        RawConv = function(self, val) self.ColorSpecMethod = val; return val end,
        Protected = 1,
        Notes = [[
            default for writing is 2 when writing ICC_Profile, 1 when writing
            ColorSpace, or 4 when writing ColorSpecData
        ]],
        PrintConv = {
            [1] = 'Enumerated',
            [2] = 'Restricted ICC',
            [3] = 'Any ICC',
            [4] = 'Vendor Color',
        },
    },
    [1] = {
        Name = 'ColorSpecPrecedence',
        Notes = 'default for writing is 0',
        Protected = 1,
    },
    [2] = {
        Name = 'ColorSpecApproximation',
        Notes = 'default for writing is 0',
        Protected = 1,
        PrintConv = {
            [0] = 'Not Specified',
            [1] = 'Accurate',
            [2] = 'Exceptional Quality',
            [3] = 'Reasonable Quality',
            [4] = 'Poor Quality',
        },
    },
    [3] = {
        {
            Name = 'ICC_Profile',
            Condition = function(self)
                return perl.num(self.ColorSpecMethod) == 2 or
                       perl.num(self.ColorSpecMethod) == 3
            end,
            Format = 'undef[$size-3]',
            SubDirectory = {
                TagTable = 'lexiftool.ICC_Profile.Main',
            },
        },
        {
            Name = 'ColorSpace',
            Condition = function(self) return perl.num(self.ColorSpecMethod) == 1 end,
            Format = 'int32u',
            Protected = 1,
            PrintConv = { -- ref 15444-2 2002-05-15
                [0] = 'Bi-level',
                [1] = 'YCbCr(1)',
                [3] = 'YCbCr(2)',
                [4] = 'YCbCr(3)',
                [9] = 'PhotoYCC',
                [11] = 'CMY',
                [12] = 'CMYK',
                [13] = 'YCCK',
                [14] = 'CIELab',
                [15] = 'Bi-level(2)', -- (incorrectly listed as 18 in 15444-2 2000-12-07)
                [16] = 'sRGB',
                [17] = 'Grayscale',
                [18] = 'sYCC',
                [19] = 'CIEJab',
                [20] = 'e-sRGB',
                [21] = 'ROMM-RGB',
                -- incorrect in 15444-2 2000-12-07
                --[22] = 'sRGB based YCbCr',
                --[23] = 'YPbPr(1125/60)',
                --[24] = 'YPbPr(1250/50)',
                [22] = 'YPbPr(1125/60)',
                [23] = 'YPbPr(1250/50)',
                [24] = 'e-sYCC',
            },
        },
        {
            Name = 'ColorSpecData',
            Format = 'undef[$size-3]',
            Protected = 1,
            Binary = 1,
        },
    },
}

-- JUMBF description box
Jpeg2000.JUMD = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'JUMBF', [1] = 'JUMBF', [2] = 'Image' },
    NOTES = 'Information extracted from the JUMBF description box.',
    ['type'] = {
        Name = 'JUMDType',
        ValueConv = function(_self, val) return unpack('H*', val) end,
        PrintConv = function(_self, val)
            local a = { matches(val, [[^(\w{8})(\w{4})(\w{4})(\w{16})$]]) }
            a[5] = nil  -- (the end offset perl.matches returns after the captures)
            if #a == 0 then return val end
            local ascii = pack('H*', a[1])
            if isMatch(ascii, [[^[a-zA-Z0-9]{4}$]]) then a[1] = '(' .. ascii .. ')' end
            return join('-', a)
        end,
        -- seen:
        -- cacb/cast/caas/cacl/casg/json-00110010800000aa00389b71
        --   (also brob- but not yet tested)
        -- 6579d6fbdba2446bb2ac1b82feeb89d1 - JPEG image
    },
    ['label'] = { Name = 'JUMDLabel' },
    ['toggles'] = {
        Name = 'JUMDToggles',
        Unknown = 1,
        PrintConv = { BITMASK = {
            [0] = 'Requestable',
            [1] = 'Label',
            [2] = 'ID',
            [3] = 'Signature',
        }},
    },
    ['id']    = { Name = 'JUMDID', Description = 'JUMD ID' },
    ['sig']   = { Name = 'JUMDSignature', PrintConv = function(_self, val) return unpack('H*', val) end },
}

--------------------------------------------------------------------------------
-- Read JUMBF box to keep track of sub-document numbers
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessJUMB(et, dirInfo, tagTablePtr)
    if et.jumd_level then
        et.jumd_level[#et.jumd_level] = et.jumd_level[#et.jumd_level] + 1 -- increment current sub-document number
    else
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.jumd_level = { et.DOC_COUNT } -- new top-level sub-document
        et.SET_GROUP0 = 'JUMBF'
    end
    et.DOC_NUM = join('-', et.jumd_level)
    perl.push(et.jumd_level, 0)
    ProcessJpeg2000Box(et, dirInfo, tagTablePtr)
    et.DOC_NUM = nil
    et.JUMBFLabel = nil
    et.jumd_level[#et.jumd_level] = nil    -- (pop)
    if #et.jumd_level < 2 then
        et.jumd_level = nil
        et.SET_GROUP0 = nil
    end
    return 1
end
Jpeg2000.ProcessJUMB = ProcessJUMB

--------------------------------------------------------------------------------
-- Read JUMBF description box (ref https://github.com/thorfdbg/codestream-parser)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessJUMD(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos    = dirInfo.DirStart
    local end_   = pos + dirInfo.DirLen
    et:VerboseDir('JUMD', 0, end_-pos)
    et.JUMBFLabel = nil
    if dirInfo.DirLen < 17 then et:Warn('Truncated JUMD directory') return 0 end
    local type_ = substr(dataPt, pos, 4) -- luacheck: ignore 211 (unused upstream too)
    et:HandleTag(tagTablePtr, 'type', substr(dataPt, pos, 16))
    pos = pos + 16
    local flags = Get8u(dataPt, pos); pos = pos + 1
    et:HandleTag(tagTablePtr, 'toggles', flags)
    if flags & 0x02 ~= 0 then  -- label exists?
        -- (pos($$dataPt) = $pos; $$dataPt =~ /\0/g)
        local found, endPos = matches(dataPt, [[\0]], pos)
        if not found then et:Warn('Missing JUMD label terminator') return 0 end
        local len = endPos - pos
        local name = substr(dataPt, pos, len)
        et:HandleTag(tagTablePtr, 'label', name)
        pos = pos + len
        if len ~= 0 then
            name = subst(name, [[[^-_a-zA-Z0-9]([a-z])]], function(c) return uc(c) end, 'g') -- capitalize characters after illegal characters
            name = tr(name, '-_a-zA-Z0-9', '', 'dc')    -- remove other illegal characters
            name = subst(name, '__', '_')               -- collapse double underlines
            name = ucfirst(name)                        -- capitalize first letter
            name = subst(name, 'C2pa', 'C2PA')          -- capitalize C2PA
            if length(name) < 2 then name = 'Tag' .. name end -- must at least 2 characters long
            et.JUMBFLabel = name
        end
    end
    if flags & 0x04 ~= 0 then  -- ID exists?
        if pos + 4 > end_ then et:Warn('Missing JUMD ID') return 0 end
        et:HandleTag(tagTablePtr, 'id', Get32u(dataPt, pos))
        pos = pos + 4
    end
    if flags & 0x08 ~= 0 then  -- signature exists?
        if pos + 32 > end_ then et:Warn('Missing JUMD signature') return 0 end
        et:HandleTag(tagTablePtr, 'sig', substr(dataPt, pos, 32))
        pos = pos + 32
    end
    local more = end_ - pos
    if more ~= 0 then
        -- (may find c2sh box hiding after JUMD record)
        if more >= 8 then
            local dirInfo2 = {
                DataPt   = dataPt,
                DataLen  = dirInfo.DataLen,
                DirStart = pos,
                DirLen   = more,
                DirName  = 'JUMDPrivate',
            }
            et:ProcessDirectory(dirInfo2, GetTagTable('lexiftool.Jpeg2000.Main'))
        else
            et:Warn('Extra data in JUMD box ' .. more .. ' bytes)', 1)
        end
    end
    return 1
end
Jpeg2000.ProcessJUMD = ProcessJUMD

--------------------------------------------------------------------------------
-- Warn about error in Brotli compression/decompression
-- Inputs: 0) ExifTool ref, 1) box type, 2) true for decoding (Uncompress)
local function BrotliWarn(et, type_, uncompress)
    local enc, mod
    if perlTruthy(uncompress) then enc, mod = 'decoding', 'Uncompress' else enc, mod = 'encoding', 'Compress' end
    et:Warn('Error ' .. enc .. " '" .. type_ .. "' brob box")
    et:Warn('Try updating to IO::' .. mod .. '::Brotli 0.004 or later')
end
Jpeg2000.BrotliWarn = BrotliWarn

--------------------------------------------------------------------------------
-- Create new JPEG 2000 boxes when writing
-- (Currently only supports adding top-level Writable JPEG2000 tags and certain UUID boxes)
-- Inputs: 0) ExifTool object ref, 1) Output file or scalar ref
-- Returns: 1 on success
local function CreateNewBoxes(et, outfile)
    local addTags = et.AddJp2Tags or { }
    local addDirs = et.AddJp2Dirs or { }
    et.AddJp2Tags = nil
    et.AddJp2Dirs = nil
    -- add JPEG2000 tags
    for _, tag in ipairs(perl.sort(perl.keys(addTags))) do
        local tagInfo = addTags[tag]
        local nvHash = Writer.GetNewValueHash(et, tagInfo)
        -- (native JPEG2000 information is always preferred, so don't check IsCreating)
        if not (tagInfo.List or Writer.IsOverwriting(et, nvHash) > 0) then goto nextTag end
        if nvHash and nvHash.EditOnly then goto nextTag end
        do
            local vals = et:GetNewValue(nvHash, true)
            for _, val in ipairs(vals) do
                local boxhdr = pack('N', length(val) + 8) .. tagInfo.TagID
                if not Write(outfile, boxhdr, val) then return 0 end
                et.CHANGED = (et.CHANGED or 0) + 1
                et:VerboseValue('+ Jpeg2000:' .. tagInfo.Name, val)
            end
        end
        ::nextTag::
    end
    -- add UUID boxes (and/or JXL Exif/XML boxes)
    for _, dirName in ipairs(perl.sort(perl.keys(addDirs))) do
        -- handle JPEG XL XMP and EXIF
        if dirName == 'xml ' or dirName == 'Exif' then
            local tag, dir
            if dirName == 'xml ' then tag, dir = 'xml ', 'XMP' else tag, dir = 'Exif', 'EXIF' end
            local tagInfo = Jpeg2000.Main[tag]
            if tagInfo[1] then tagInfo = tagInfo[2] end -- (hack for stupid JXL XMP)
            local subdir = tagInfo.SubDirectory
            local tagTable = GetTagTable(subdir.TagTable)
            if dir == 'XMP' then tagTable = GetTagTable('lexiftool.XMP.Main') end
            local dirInfo = {
                DirName = dir,
                Parent = tag,
            }
            local compress = et:Options('Compress')
            if perlTruthy(et.IsJXL) and perlTruthy(compress) then dirInfo.Compact = 1 end
            local newdir = Writer.WriteDirectory(et, dirInfo, tagTable, subdir.WriteProc)
            if newdir ~= nil and length(newdir) > 0 then
                -- not sure why, but EXIF box is padded with leading 0's in my sample
                local pad = dirName == 'Exif' and '\0\0\0\0' or ''
                if perlTruthy(et.IsJXL) and perlTruthy(compress) then
                    -- create as Brotli-compressed metadata
                    local haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli')
                    if haveBro then
                        local compressed
                        local ok, res = pcall(IO_Compress_Brotli.bro, pad .. newdir)
                        if ok then compressed = res end
                        if not ok or not perlTruthy(compressed) then
                            BrotliWarn(et, dirName)
                        else
                            et:VPrint(0, '  Writing Brotli-compressed ' .. dir .. "\n")
                            newdir = compressed
                            pad = tag
                            tag = 'brob'
                        end
                    else
                        et:Warn('Install IO::Compress::Brotli to create Brotli-compressed metadata')
                    end
                end
                local boxhdr = pack('N', length(newdir) + length(pad) + 8) .. tag
                if not Write(outfile, boxhdr, pad, newdir) then return 0 end
                goto nextDir
            end
        end
        if not perlTruthy(uuid[dirName]) then goto nextDir end
        for _, tagInfo in ipairs(Jpeg2000.Main.uuid) do
            if tagInfo.Name ~= dirName then goto nextInfo end
            do
                local subdir = tagInfo.SubDirectory
                local tagTable = GetTagTable(subdir.TagTable)
                local dirInfo = {
                    DirName = perlOr(subdir.DirName, dirName),
                    Parent = 'JP2',
                }
                -- remove "UUID-" from start of directory name to allow appropriate
                -- directories to be written as a block
                dirInfo.DirName = subst(dirInfo.DirName, [[^UUID-]], '')
                local newdir = Writer.WriteDirectory(et, dirInfo, tagTable, subdir.WriteProc)
                if newdir ~= nil and length(newdir) > 0 then
                    local boxhdr = pack('N', length(newdir) + 24) .. 'uuid' .. uuid[dirName]
                    if not Write(outfile, boxhdr, newdir) then return 0 end
                    break
                end
            end
            ::nextInfo::
        end
        ::nextDir::
    end
    return 1
end

--------------------------------------------------------------------------------
-- Create Color Specification Box
-- Inputs: 0) ExifTool object ref, 1) Output file or scalar ref
-- Returns: 1 on success
local function CreateColorSpec(et, outfile)
    local meth   = et:GetNewValue('Jpeg2000:ColorSpecMethod')
    local prec   = perlOr(et:GetNewValue('Jpeg2000:ColorSpecPrecedence'), 0)
    local approx = perlOr(et:GetNewValue('Jpeg2000:ColorSpecApproximation'), 0)
    local icc    = et:GetNewValue('ICC_Profile')
    local space  = et:GetNewValue('Jpeg2000:ColorSpace')
    local cdata  = et:GetNewValue('Jpeg2000:ColorSpecData')
    if not perlTruthy(meth) then
        if perlTruthy(icc) then
            meth = 2
        elseif space ~= nil then
            meth = 1
        elseif cdata ~= nil then
            meth = 4
        else
            et:Warn('Color space not defined') return 0
        end
    end
    if str(meth) == '1' then
        if space == nil then et:Warn('Must specify ColorSpace') return 0 end
        cdata = pack('N', space)
    elseif str(meth) == '2' or str(meth) == '3' then
        if icc == nil then et:Warn('Must specify ICC_Profile') return 0 end
        cdata = icc
    elseif str(meth) == '4' then
        if cdata == nil then et:Warn('Must specify ColorSpecData') return 0 end
    else
        et:Warn('Unknown ColorSpecMethod') return 0
    end
    local boxhdr = pack('N', length(cdata) + 11) .. 'colr'
    if not Write(outfile, boxhdr, pack('CCC',meth,prec,approx), cdata) then return 0 end
    et.CHANGED = (et.CHANGED or 0) + 1
    et:VPrint(1, "    + Jpeg2000:ColorSpec\n")
    return 1
end

--------------------------------------------------------------------------------
-- Process JPEG 2000 box
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success when reading, or -1 on write error
--          (or JP2 box or undef when writing from buffer)
function ProcessJpeg2000Box(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataLen = dirInfo.DataLen
    local dataPos = dirInfo.DataPos or 0
    local dirLen = dirInfo.DirLen or 0
    local dirStart = dirInfo.DirStart or 0
    local base = dirInfo.Base or 0
    local outfile = dirInfo.OutFile
    local dirName = dirInfo.DirName or ''
    local dirEnd = dirStart + dirLen
    local err, outBuff, verbose, doColour, hash, raf

    if dataPt then
        -- save C2PA JUMBF as a block if requested
        if dirName == 'JUMBF' and et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP.jumbf and not dirInfo.NoBlockSave then
            if perlTruthy(dirStart) or dirLen ~= length(dataPt) then
                local dat = substr(dataPt, dirStart, dirLen)
                et:FoundTag('JUMBF', dat)
            else
                et:FoundTag('JUMBF', dataPt)
            end
        end
    else
        raf = dirInfo.RAF  -- read from RAF
    end

    if outfile then
        if not raf then
            -- buffer output to be used for return value
            outBuff = { value = carray.new('char') }
            outfile = outBuff
        end
        -- determine if we will be writing colr box
        if dirName == 'JP2Header' then
            if et:GetNewValue('ColorSpecMethod') ~= nil or perlTruthy(et:GetNewValue('ICC_Profile')) or
               et:GetNewValue('ColorSpecPrecedence') ~= nil or et:GetNewValue('ColorSpace') ~= nil or
               et:GetNewValue('ColorSpecApproximation') ~= nil or et:GetNewValue('ColorSpecData') ~= nil
            then
                doColour = 2
            end
        end
    else
        -- (must not set verbose flag when writing!)
        verbose = et.OPTIONS.Verbose
        if perlTruthy(verbose) then et:VerboseDir(dirName) end
        -- do hash if requested, but only for top-level image data
        -- (rawget: the member, not the method of that name)
        if raf then hash = rawget(et, 'ImageDataHash') end
    end
    -- loop through all contained boxes
    local pos, boxLen, lastBox -- luacheck: ignore 231 (lastBox: unused upstream too)
    pos = dirStart
    while true do
        local boxID, buff, valuePtr
        local hdrLen = 8     -- the box header length
        if raf then
            dataPos = raf:Tell() - base
            local n
            n, buff = raf:Read(hdrLen)
            if n ~= hdrLen then
                if n ~= 0 then err = '' break end
                if outfile and not perlTruthy(CreateNewBoxes(et, outfile)) then err = 1 end
                break
            end
            dataPt = buff
            dirEnd = hdrLen; dirLen = dirEnd -- luacheck: ignore 311
            pos = 0
        elseif pos >= dirEnd - hdrLen then
            if pos ~= dirEnd then err = '' end
            break
        end
        boxLen = unpack('x' .. pos .. ' N',dataPt)   -- (length includes header and data)
        boxID = substr(dataPt, pos+4, 4)
        -- (ftbl box contains flst boxes with absolute file offsets, not currently handled)
        if outfile and boxID == 'ftbl' then
            et:Error("Can't yet handle fragmented JPX files")
            return -1
        end
        -- remove old colr boxes if necessary
        if perlTruthy(doColour) and boxID == 'colr' then
            if doColour == 1 then -- did we successfully write the new colr box?
                et:VPrint(1,"    - Jpeg2000:ColorSpec\n")
                et.CHANGED = (et.CHANGED or 0) + 1
                goto nextBox
            end
            et:Warn('Out-of-order colr box encountered')
            doColour = nil
        end
        lastBox = boxID
        pos = pos + hdrLen                -- move to end of box header
        if boxLen == 1 then
            -- box header contains an additional 8-byte integer for length
            hdrLen = hdrLen + 8
            if raf then
                local n, buf2 = raf:Read(8)
                if n == 8 then
                    buff = buff .. buf2
                    dataPt = buff   -- ($dataPt is \$buff)
                    dirEnd = hdrLen; dirLen = dirEnd -- luacheck: ignore 311
                end
            end
            if pos > dirEnd - 8 then err = '' break end
            local hi, lo = unpack('x' .. pos .. ' N2',dataPt)
            if perlTruthy(hi) then err = "Can't currently handle JPEG 2000 boxes > 4 GB" break end
            pos = pos + 8                  -- move to end of extended-length box header
            boxLen = lo - hdrLen    -- length of remaining box data
        elseif boxLen == 0 then
            if raf then
                if outfile then
                    if not perlTruthy(CreateNewBoxes(et, outfile)) then err = 1 end
                    -- copy over the rest of the file
                    if not Write(outfile, dataPt) then err = 1 end
                    while true do
                        local n
                        n, buff = raf:Read(65536)
                        if n == 0 then break end
                        if not Write(outfile, buff) then err = 1 end
                    end
                else
                    if perlTruthy(verbose) then
                        local msg = sprintf('offset 0x%.4x to end of file', dataPos + base + pos)
                        et:VPrint(0, et.INDENT .. "- Tag '" .. boxID .. "' (" .. msg .. ")\n")
                    end
                    if hash and isImageData[boxID] then
                        et:ImageDataHash(raf, nil, boxID)
                    end
                end
                break   -- (ignore the rest of the file when reading)
            end
            boxLen = dirEnd - pos   -- data runs to end of file
        else
            boxLen = boxLen - hdrLen         -- length of remaining box data
        end
        if boxLen < 0 then err = 'Invalid JPEG 2000 box length' break end
        do
            local tagInfo = et:GetTagInfo(tagTablePtr, boxID)
            if not (tagInfo ~= nil or perlTruthy(verbose)) then
                -- no need to process this box
                if raf then
                    if outfile then
                        if not Write(outfile, dataPt) then err = 1 end
                        local n
                        n, buff = raf:Read(boxLen)
                        if n ~= boxLen then err = '' break end
                        if not Write(outfile, buff) then err = 1 end
                    elseif hash and isImageData[boxID] then
                        et:ImageDataHash(raf, boxLen, boxID)
                    else
                        if not raf:Seek(boxLen, 1) then err = 'Seek error' break end
                    end
                elseif outfile then
                    if not Write(outfile, substr(dataPt, pos-hdrLen, boxLen+hdrLen)) then err = '' break end
                end
                goto nextBox
            end
            if raf then
                -- read the box data
                dataPos = raf:Tell() - base
                local n
                n, buff = raf:Read(boxLen)
                dataPt = buff   -- ($dataPt is \$buff)
                if n ~= boxLen then err = '' break end
                if hash and isImageData[boxID] then
                    hash:add(buff)
                    et:VPrint(0, et.INDENT .. '(ImageDataHash: ' .. boxLen .. ' bytes of ' .. boxID .. " data)\n")
                end
                valuePtr = 0
                dataLen = boxLen
            elseif pos + boxLen > dirEnd then
                err = ''
                break
            else
                valuePtr = pos
            end
            if tagInfo ~= nil and not tagInfo then
                -- GetTagInfo() required the value for a Condition
                -- (`false` is this port's stand-in for upstream's '')
                local tmpVal = substr(dataPt, valuePtr, boxLen < 128 and boxLen or 128)
                tagInfo = et:GetTagInfo(tagTablePtr, boxID, tmpVal)
            end
            -- delete all UUID boxes and any writable box if deleting all information
            if outfile and tagInfo then
                if boxID == 'uuid' and et.DEL_GROUP['*'] then
                    et:VPrint(0, '  Deleting ' .. tagInfo.Name .. "\n")
                    et.CHANGED = (et.CHANGED or 0) + 1
                    goto nextBox
                elseif tagInfo.Writable then
                    local isOverwriting
                    if et.DEL_GROUP.Jpeg2000 then
                        isOverwriting = 1
                    else
                        local nvHash = Writer.GetNewValueHash(et, tagInfo)
                        isOverwriting = Writer.IsOverwriting(et, nvHash)
                    end
                    if perlTruthy(isOverwriting) then
                        local val = substr(dataPt, valuePtr, boxLen)
                        et:VerboseValue('- Jpeg2000:' .. tagInfo.Name, val)
                        et.CHANGED = (et.CHANGED or 0) + 1
                        goto nextBox
                    elseif not tagInfo.List then
                        if et.AddJp2Tags then et.AddJp2Tags[boxID] = nil end
                    end
                end
            end
            -- create new tag for JUMBF data values with name corresponding to JUMBFLabel
            if tagInfo and et.JUMBFLabel and (not tagInfo.SubDirectory or tagInfo.BlockExtract) then
                local newInfo = { }  -- ({ %$tagInfo, Name => ... })
                for k, v in pairs(tagInfo) do newInfo[k] = v end
                newInfo.Name = et.JUMBFLabel .. perlOr(tagInfo.JUMBF_Suffix, '')
                tagInfo = newInfo
                tagInfo.Description = subst(ExifTool.MakeDescription(tagInfo.Name), 'C2 PA', 'C2PA')
                et:AddTagToTable(tagTablePtr, '_JUMBF_' .. et.JUMBFLabel, tagInfo)
                tagInfo.Protected = nil -- (must do this so -j -b returns JUMBF binary data)
                tagInfo.TagID = boxID
            end
            if perlTruthy(verbose) then
                et:VerboseInfo(boxID, tagInfo, {
                    Table  = tagTablePtr,
                    DataPt = dataPt,
                    Size   = boxLen,
                    Start  = valuePtr,
                    Addr   = valuePtr + dataPos + base,
                })
                if not tagInfo then goto nextBox end
            end
            if tagInfo.SubDirectory then
                local subdir = tagInfo.SubDirectory
                local subdirStart = valuePtr
                local subdirLen = boxLen
                if subdir.Start ~= nil then
                    --### eval Start ($valuePtr, $dataPt)
                    subdirStart = subdir.Start(et, dataPt, valuePtr)
                    subdirLen = subdirLen - (subdirStart - valuePtr)
                    if subdirLen < 0 then
                        subdirStart = valuePtr
                        subdirLen = 0
                    end
                end
                local subdirInfo = {
                    Parent = 'JP2',
                    DataPt = dataPt,
                    DataPos = -subdirStart, -- (relative to Base)
                    DataLen = dataLen,
                    DirStart = subdirStart,
                    DirLen = subdirLen,
                    DirName = perlOr(subdir.DirName, tagInfo.Name),
                    OutFile = outfile,
                    Base = base + dataPos + subdirStart,
                }
                local uuid_ = uuid[tagInfo.Name]
                -- remove "UUID-" prefix to allow appropriate directories to be written as a block
                subdirInfo.DirName = subst(subdirInfo.DirName, [[^UUID-]], '')
                local subTable = GetTagTable(subdir.TagTable) or tagTablePtr
                if outfile then
                    -- (special case for brob box, which may be EXIF or XMP)
                    local fakeID = boxID
                    if boxID == 'brob' then
                        -- I have seen 'brob' ID's with funny cases, so standardize these
                        if isMatch(dataPt, [[(?i)^xml ]]) then fakeID = 'xml ' end
                        if isMatch(dataPt, [[(?i)^Exif]]) then fakeID = 'Exif' end
                    end
                    local newdir
                    -- only edit writable UUID, Exif and jp2h boxes
                    if perlTruthy(uuid_) or fakeID == 'Exif' or (fakeID == 'xml ' and perlTruthy(et.IsJXL)) or
                        (boxID == 'jp2h' and et.EDIT_DIRS and et.EDIT_DIRS.jp2h)
                    then
                        local compress = et:Options('Compress')
                        subdirInfo.Parent = fakeID
                        if perlTruthy(compress) and perlTruthy(et.IsJXL) then subdirInfo.Compact = 1 end
                        newdir = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                        if newdir ~= nil and length(newdir) == 0 then goto nextBox end -- next if deleting the box
                        -- compress JXL EXIF or XMP metadata if requested
                        if newdir ~= nil and perlTruthy(et.IsJXL) and compress ~= nil and
                            (fakeID == 'Exif' or fakeID == 'xml ')
                        then
                            if perlTruthy(compress) and boxID ~= 'brob' then
                                -- rewrite as a Brotli-compressed 'brob' box
                                local haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli')
                                if haveBro then
                                    local pad = boxID == 'Exif' and '\0\0\0\0' or ''
                                    local compressed
                                    local ok, res = pcall(IO_Compress_Brotli.bro, pad .. newdir)
                                    if ok then compressed = res end
                                    if not ok or not perlTruthy(compressed) then
                                        BrotliWarn(et, boxID)
                                    else
                                        et:VPrint(0, '  Writing Brotli-compressed ' .. boxID .. "\n")
                                        newdir = boxID .. compressed
                                        boxID = 'brob'
                                        valuePtr = 0; subdirStart = valuePtr
                                        et.CHANGED = (et.CHANGED or 0) + 1
                                    end
                                else
                                    et:Warn('Install IO::Compress::Brotli to write Brotli-compressed metadata')
                                end
                            elseif not perlTruthy(compress) and boxID == 'brob' then
                                -- (in this case, ProcessBrotli has returned uncompressed data,
                                --  so change to the uncompressed 'xml ' or 'Exif' box type)
                                et:VPrint(0, '  Writing uncompressed ' .. fakeID .. "\n")
                                boxID = fakeID
                                valuePtr = 0; subdirStart = valuePtr
                                et.CHANGED = (et.CHANGED or 0) + 1
                            end
                        end
                    elseif uuid_ ~= nil then
                        et:Warn('Not editing ' .. tagInfo.Name .. ' box', 1)
                    end
                    -- remove this directory from our create list
                    -- (Perl autovivifies $$et{AddJp2Dirs} for these deletes)
                    et.AddJp2Dirs = et.AddJp2Dirs or { }
                    et.AddJp2Dirs[fakeID] = nil               -- (eg. 'Exif' or 'xml ')
                    if boxID == 'brob' then
                        -- (can't make tag Name 'XMP' or 'Exif' for Brotli-compressed tags because it
                        --  would break the logic in WriteDirectory(), so we do a lookup here instead)
                        et.AddJp2Dirs[({ ['xml ']='XMP', ['Exif']='EXIF' })[fakeID] or ''] = nil
                    else
                        et.AddJp2Dirs[tagInfo.Name] = nil   -- (eg. 'EXIF' or 'XMP')
                    end
                    -- use old box data if not changed
                    if newdir == nil then newdir = substr(dataPt, subdirStart, subdirLen) end
                    local prefixLen = subdirStart - valuePtr
                    local boxhdr = pack('N', length(newdir) + 8 + prefixLen) .. boxID
                    if prefixLen ~= 0 then boxhdr = boxhdr .. substr(dataPt, valuePtr, prefixLen) end
                    if not Write(outfile, boxhdr, newdir) then err = 1 end
                    -- write new colr box immediately after ihdr
                    if perlTruthy(doColour) and boxID == 'ihdr' then
                        -- (shouldn't be multiple ihdr boxes, but just in case, write only 1)
                        if doColour == 2 then doColour = CreateColorSpec(et, outfile) else doColour = 0 end
                    end
                else
                    -- extract as a block if specified
                    if tagInfo.BlockExtract then subdirInfo.BlockInfo = tagInfo end
                    if uuid_ ~= nil and uuid_ == '0' then et:Warn('Reading non-standard ' .. tagInfo.Name .. ' box') end
                    if not perlTruthy(et:ProcessDirectory(subdirInfo, subTable, subdir.ProcessProc)) then
                        if subTable == tagTablePtr then
                            err = 'JPEG 2000 format error'
                            break
                        end
                        et:Warn('Unrecognized ' .. tagInfo.Name .. ' box')
                    end
                end
            elseif tagInfo.Format and not outfile then
                -- only save tag values if Format was specified
                local rational = { }
                local val = ReadValue(dataPt, valuePtr, tagInfo.Format, nil, boxLen, rational)
                if val ~= nil then
                    local key = et:FoundTag(tagInfo, val)
                    -- save Rational value
                    if rational.rat ~= nil and key ~= nil then et.TAG_EXTRA[key].Rational = rational.rat end
                end
            elseif outfile then
                local boxhdr = pack('N', boxLen + 8) .. boxID
                if not Write(outfile, boxhdr, substr(dataPt, valuePtr, boxLen)) then err = 1 end
            end
        end
        ::nextBox::
        pos = pos + boxLen
    end
    if err ~= nil then
        if not perlTruthy(err) then err = 'Truncated JPEG 2000 box' end
        if outfile then
            if str(err) ~= '1' then et:Error(err) end
            if raf then return -1 end
            return nil
        end
        et:Warn(err)
    end
    if outfile and not raf then return outBuff.value:tostring() end
    return 1
end
Jpeg2000.ProcessJpeg2000Box = ProcessJpeg2000Box

--------------------------------------------------------------------------------
-- Return bits from a bitstream object
-- Inputs: 0) array ref, 1) number of bits
-- Returns: specified number of bits as an integer, and shifts input bitstream
-- (the array is a 1-based Lua list; $$a[$i] is a[i+1])
local function GetBits(a, n)
    local v = 0
    local bit = 1
    while n > 0 do
        n = n - 1
        for i = 0, #a - 1 do
            -- consume bits LSB first
            local set = a[i+1] & 1
            a[i+1] = a[i+1] >> 1
            if i ~= 0 then
                if set ~= 0 then a[i] = a[i] | 0x80 end
            else
                if set ~= 0 then v = v | bit end
                bit = bit << 1
            end
        end
    end
    return v
end

--------------------------------------------------------------------------------
-- Read/write Brotli-encoded metadata
-- Inputs: 0) ExifTool ref, 1) dirInfoRef, 2) tag table ref
-- Returns: 1 on success when reading, or new data when writing (undef if unchanged)
-- (ref https://libjxl.readthedocs.io/en/latest/api_decoder.html)
function ProcessBrotli(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt

    if length(dataPt) <= 4 then return 0 end -- (return 0 unless length > 4)

    local isWriting = dirInfo.IsWriting
    local type_ = substr(dataPt, 0, 4)
    if not perlTruthy(isWriting) then et:VerboseDir("Decrypted Brotli '" .. type_ .. "'") end
    local knownType = { exif = 'Exif', ['xml '] = 'xml ', jumb = 'jumb' }
    local stdType = knownType[lc(type_)]
    if not stdType then
        et:Warn('Unknown Brotli box type', 1)
        return 1
    end
    if type_ ~= stdType then
        et:Warn("Incorrect case for Brotli '" .. type_ .. "' data (should be '" .. stdType .. "')")
        type_ = stdType
    end
    local haveUnbro, IO_Uncompress_Brotli = perl.evalRequire('IO::Uncompress::Brotli')
    if haveUnbro then
        local haveBro, IO_Compress_Brotli
        if perlTruthy(isWriting) then haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli') end
        if perlTruthy(isWriting) and not haveBro then
            et:Warn('Install IO::Compress::Brotli to write Brotli-compressed metadata')
            return nil
        end
        local compress = et:Options('Compress')
        local verbose = perlTruthy(isWriting) and 0 or et:Options('Verbose')
        local dat = substr(dataPt, 4)
        local ok, res = pcall(IO_Uncompress_Brotli.unbro, dat, 100000000)
        if ok then dat = res end
        if not ok then BrotliWarn(et, type_, 1) return 1 end
        if perl.num(verbose) > 2 then et:VerboseDump(dat, { Prefix = et.INDENT .. '  ' }) end
        local dirInfo2 = { DataPt = dat }
        if type_ == 'xml ' then
            dirInfo2.DirName = 'XMP' -- (necessary for block read/write)
            local XMP = require('lexiftool.XMP')
            if perlTruthy(isWriting) then
                if perlTruthy(compress) then dirInfo2.Compact = 1 end  -- (no need to add padding if writing compressed)
                dat = Writer.WriteDirectory(et, dirInfo2, tagTablePtr)
            else
                XMP.ProcessXMP(et, dirInfo2, tagTablePtr)
            end
        elseif type_ == 'Exif' then
            dirInfo2.DirName = 'EXIF' -- (necessary for block read/write)
            dirInfo2.DirStart = 4 + (length(dat) > 4 and unpack('N', dat) or 0)
            if dirInfo2.DirStart > length(dat) then
                et:Warn("Corrupted Brotli '" .. type_ .. "' data")
            elseif perlTruthy(isWriting) then
                dat = Writer.WriteDirectory(et, dirInfo2, tagTablePtr, Writer.WriteTIFF)
                -- add back header word
                if dat ~= nil and length(dat) > 0 then dat = '\0\0\0\0' .. dat end
            else
                et:ProcessTIFF(dirInfo2, tagTablePtr)
            end
        elseif type_ == 'jumb' then
            if perlTruthy(isWriting) then return nil end -- (can't yet write JUMBF)
            ProcessJUMB(et, dirInfo2, tagTablePtr) -- (untested)
        end
        if perlTruthy(isWriting) then
            if dat == nil then return nil end
            -- rewrite as uncompressed if Compress option is set to 0 (or '')
            if compress ~= nil and not perlTruthy(compress) then return dat end
            local ok2, res2 = pcall(IO_Compress_Brotli.bro, dat)
            if ok2 then dat = res2 end
            if not ok2 then BrotliWarn(et, type_) return nil end
            et:VPrint(0, '  Writing Brotli-compressed ' .. type_ .. "\n")
            return type_ .. dat
        end
    else
        et:Warn('Install IO::Uncompress::Brotli to decode Brotli-compressed metadata')
        if perlTruthy(isWriting) then return nil end
    end
    return 1
end
Jpeg2000.ProcessBrotli = ProcessBrotli

--------------------------------------------------------------------------------
-- Extract parameters from JPEG XL codestream [unverified!]
-- Inputs: 0) ExifTool ref, 1) codestream ref
-- Returns: 1 on success
function Jpeg2000.ProcessJXLCodestream(et, dataPt)

    if not isMatch(dataPt, [[^(\0\0\0\0)?\xff\x0a]]) then return 0 end -- validate codestream
    -- ignore if already extracted (ie. subsequent jxlp boxes)
    if et.ProcessedJXLCodestream then return 0 end
    et.ProcessedJXLCodestream = 1
    -- work with first 64 bytes of codestream data
    -- (and add padding if necessary to avoid unpacking past end of data)
    local dat
    if length(dataPt) > 64 then
        dat = substr(dataPt, 0, 64)
    elseif length(dataPt) < 18 then
        dat = dataPt .. ('\0'):rep(18) -- (so we'll have a minimum 14 bytes to work with)
    else
        dat = dataPt
    end
    dat = subst(dat, [[^\0\0\0\0]], '')  -- remove jxlp header word
    local a = { unpack('x2C12', dat) }
    local x, y
    local small = GetBits(a, 1)
    if small ~= 0 then
        y = (GetBits(a, 5) + 1) * 8
    else
        y = GetBits(a, ({ [0] = 9, 13, 18, 30 })[GetBits(a, 2)]) + 1
    end
    local ratio = GetBits(a, 3)
    if ratio == 0 then
        if small ~= 0 then
            x = (GetBits(a, 5) + 1) * 8
        else
            x = GetBits(a, ({ [0] = 9, 13, 18, 30 })[GetBits(a, 2)]) + 1
        end
    else
        -- (inner pairs 1-based: $$r[0] is r[1])
        local r = ({ [0] = {1,1},{12,10},{4,3},{3,2},{16,9},{5,4},{2,1} })[ratio-1]
        x = int(y * r[1] / r[2])
    end
    et:FoundTag('ImageWidth', x)
    et:FoundTag('ImageHeight', y)
    return 1
end

--------------------------------------------------------------------------------
-- Read/write meta information from a C2PA/JUMBF file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JUMBF file
function Jpeg2000.ProcessJUMBF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, hdr

    -- check to be sure this is a valid JPG2000 file
    n, hdr = raf:Read(20)
    if not (n == 20 and raf:Seek(0,0)) then return 0 end
    local found, type_ = isMatch(hdr, [[^.{4}jumb\0.{3}jumd(.{4})]])
    if not found then return 0 end
    et:SetFileType(type_ == 'c2pa' and 'C2PA' or 'JUMBF')
    local dirInfo2 = {
        RAF = raf,
        DirName = 'JUMBF',
    }
    local tagTablePtr = GetTagTable('lexiftool.Jpeg2000.Main')
    return et:ProcessDirectory(dirInfo2, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Read/write meta information from a JPEG 2000 image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JPEG 2000 file, or -1 on write error
function Jpeg2000.ProcessJP2(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local n, hdr

    -- check to be sure this is a valid JPG2000 file
    n, hdr = raf:Read(12)
    if n ~= 12 then return 0 end
    if not (hdr == '\0\0\0\x0cjP  \x0d\x0a\x87\x0a' or       -- (ref 1)
            hdr == '\0\0\0\x0cjP\x1a\x1a\x0d\x0a\x87\x0a' or -- (ref 2)
            perlTruthy(et.IsJXL))
    then
        if not isMatch(hdr, [[^\xff\x4f\xff\x51\0]]) then return 0 end  -- check for JP2 codestream format
        if outfile then
            et:Error('Writing of J2C files is not yet supported')
            return 0
        end
        -- add J2C markers if not done already
        if not ExifTool.jpegMarker[0x4f] then
            for _, k in ipairs(perl.keys(j2cMarker)) do ExifTool.jpegMarker[k] = j2cMarker[k] end
        end
        et:SetFileType('J2C')
        raf:Seek(0,0)
        return et:ProcessJPEG(dirInfo)    -- decode with JPEG processor
    end
    if outfile then
        if not Write(outfile, hdr) then return -1 end
        if perlTruthy(et.IsJXL) then
            Writer.InitWriteDirs(et, jxlMap)
            et.AddJp2Tags = { } -- (don't add JP2 tags in JXL files)
        else
            Writer.InitWriteDirs(et, jp2Map)
            et.AddJp2Tags = Writer.GetNewTagInfoHash(et, Jpeg2000.Main)
        end
        -- save list of directories to create
        local addDirs = { } -- (make a copy)
        for k, v in pairs(et.ADD_DIRS) do addDirs[k] = v end
        et.AddJp2Dirs = addDirs
    else
        local buff, fileType
        -- recognize JPX and JPM as unique types of JP2
        n, buff = raf:Read(12)
        local found, brand = isMatch(buff, [[(?s)^.{4}ftyp(.{4})]])
        if n == 12 and found then
            if brand == 'jpx ' then fileType = 'JPX' end
            if brand == 'jpm ' then fileType = 'JPM' end
            if brand == 'jxl ' then fileType = 'JXL' end
            if brand == 'jph ' then fileType = 'JPH' end
        end
        if buff ~= nil then raf:Seek(-length(buff), 1) end
        et:SetFileType(fileType)
    end
    SetByteOrder('MM') -- JPEG 2000 files are big-endian
    local dirInfo2 = {
        RAF = raf,
        DirName = 'JP2',
        OutFile = dirInfo.OutFile,
    }
    local tagTablePtr = GetTagTable('lexiftool.Jpeg2000.Main')
    return et:ProcessDirectory(dirInfo2, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Read/write meta information in a JPEG XL image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JPEG XL file, -1 on write error
function Jpeg2000.ProcessJXL(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local n, hdr, buff

    n, hdr = raf:Read(12)
    if n ~= 12 then return 0 end
    if hdr == '\0\0\0\x0cJXL \x0d\x0a\x87\x0a' then
        -- JPEG XL in ISO BMFF container
        et.IsJXL = 1
    elseif isMatch(hdr, [[^\xff\x0a]]) then
        -- JPEG XL codestream
        if outfile then
            if perlTruthy(et.OPTIONS.IgnoreMinorErrors) then
                et:Warn('Wrapped JXL codestream in ISO BMFF container')
            else
                et:Error('Will wrap JXL codestream in ISO BMFF container for writing',1)
                return 0
            end
            et.IsJXL = 2
            local buff2 = '\0\0\0\x0cJXL \x0d\x0a\x87\x0a\0\0\0\x14ftypjxl \0\0\0\0jxl '
            -- add metadata to empty ISO BMFF container
            dirInfo.RAF = require('lexiftool.RandomAccess').new(buff2)
        else
            et:SetFileType('JXL Codestream','image/jxl', 'jxl')
            -- (rawget: the member, not the method of that name)
            if rawget(et, 'ImageDataHash') and raf:Seek(0,0) then
                et:ImageDataHash(raf, nil, 'JXL')
            end
            return Jpeg2000.ProcessJXLCodestream(et, hdr)
        end
    else
        return 0
    end
    if not raf:Seek(0,0) then et:Error('Seek error') return 0 end

    local success = Jpeg2000.ProcessJP2(et, dirInfo)

    if outfile and success > 0 and et.IsJXL == 2 then
        -- attach the JXL codestream box to the ISO BMFF file
        if not raf:Seek(0,2) then return -1 end
        local size = raf:Tell()
        if not raf:Seek(0,0) then return -1 end
        SetByteOrder('MM')
        if not Write(outfile, ExifTool.Set32u(size + 8), 'jxlc') then return -1 end
        while true do
            n, buff = raf:Read(65536)
            if n == 0 then break end
            if not Write(outfile, buff) then return -1 end
        end
    end
    return success
end

Jpeg2000.Main.PROCESS_PROC = ProcessJpeg2000Box
Jpeg2000.Main.WRITE_PROC = ProcessJpeg2000Box
Jpeg2000.JUMD.PROCESS_PROC = ProcessJUMD

return Jpeg2000
