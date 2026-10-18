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
-- Port notes:   read subset: ProcessJP2 (the JP2 container reader),
--               ProcessJpeg2000Box (the box walker, incl. the RAF-based
--               path), the Main/FileType/ImageHeader/ColorSpec tables, the
--               UUID conditional list (EXIF/IPTC/XMP/GeoJP2 embedded
--               blocks), the `xml ` box (embedded XML via XMP.XML), the
--               JUMBF box parser (ProcessJUMD/ProcessJUMB), and the J2C
--               codestream branch of ProcessJP2 (mixes %j2cMarker into
--               ExifTool.jpegMarker and hands the file to ProcessJPEG, as
--               upstream), plus the WRITE half of ProcessJP2 and
--               ProcessJpeg2000Box: the box walker's copy-through/edit/
--               delete branches, CreateNewBoxes (uuid plus the JXL
--               `xml `/`Exif` boxes) and CreateColorSpec, with %jp2Map,
--               %jxlMap and %uuid; and ProcessJXL for both directions,
--               including wrapping a bare codestream in an ISO BMFF
--               container. ProcessJUMBF reads stand-alone C2PA/JUMBF files
--               (like ProcessJP2, from a whole-file DataPt rather than the
--               RAF-incremental reader). ProcessBrotli is complete (read,
--               write, and the Compress option's brob creation/removal in
--               ProcessJpeg2000Box and CreateNewBoxes); IO::Uncompress::
--               Brotli/IO::Compress::Brotli are the optional rock
--               lbrotli, and without it the warnings are
--               upstream's. ProcessBrotli is defined ahead of %Main, which
--               references it. ImageDataHash: the top-level walk (the one
--               ProcessJP2/ProcessJUMBF start, which carries the RAF as
--               upstream's does) hashes the %isImageData boxes from its
--               DataPt, with upstream's verbose message.  A truncated box is
--               not hashed: upstream's loop ends there, for a box it reads
--               unhashed, for a box it skips unread (no tag, no -v, e.g.
--               jbrd) after a partial digest and "Error reading" warning,
--               which this port does not reproduce.  Deferred:
--               writing J2C codestreams, GeoJP2
--               (upstream can't write it either), and the `uuid` boxes not
--               exercised by the vendored goldens.
--------------------------------------------------------------------------------

-- luacheck: ignore 211 213 512
--   (211: loop variables kept for parity with the upstream box loop; 213:
--    unused local boxID/valuePtr mirrors; 512: intentional single-iteration
--    `while` loops that mirror the upstream `for (;;)` loops)

-- Frequently used library functions as local aliases.
local ssub = string.sub

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local tsort = perl.tsort
local carray = require('carray')
local Write = Writer.Write
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local unpack = perl.unpack
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local perlTruthy = ExifTool.perlTruthy

local Jpeg2000 = {}

-- top-level boxes containing image data
local isImageData = { jp2c=1, jbrd=1, jxlp=1, jxlc=1 }

-- map of where information is written in a JP2 image (upstream %jp2Map)
local jp2Map = {
    IPTC         = 'UUID-IPTC',
    IFD0         = 'UUID-EXIF',
    XMP          = 'UUID-XMP',
    ['UUID-IPTC']= 'JP2',
    ['UUID-EXIF']= 'JP2',
    ['UUID-XMP'] = 'JP2',
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

-- map of where information is written in a JXL image (upstream %jxlMap)
local jxlMap = {
    IFD0         = 'Exif',
    XMP          = 'xml ',
    ['Exif']     = 'JP2',
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

-- The uuid box identifiers we can WRITE (upstream %uuid). The read side picks
-- its boxes apart with the Conditions in the Main table's `uuid` list instead;
-- this is only consulted when creating or editing one.
local uuid = {
    ['UUID-EXIF']     = 'JpgTiffExif->JP2',
    ['UUID-EXIF2']    = '',  -- (flags a warning when writing)
    ['UUID-EXIF_bad'] = '0', -- (flags a warning when reading and writing)
    ['UUID-IPTC']     = '\51\199\164\210\184\29\71\35\160\186\241\163\224\151\173\56',
    ['UUID-XMP']      = '\190\122\207\203\151\169\66\232\156\113\153\148\145\227\175\172',
    -- (can't yet write GeoJP2 information)
}

-- JPEG 2000 codestream markers (ProcessJP2 mixes them into
-- ExifTool.jpegMarker before handing a codestream to ProcessJPEG)
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

-- Hex-encode a byte string (upstream `unpack "H*", $val` via the facade).
local function hexConv(_self, val)
    return perl.unpack('H*', val)
end

-- Decode a hex string to bytes (upstream `pack 'H*', $val`; the facade has no
-- pack, so use the numeric reader directly).
local function hexToStr(s)
    local out = {}
    for i = 1, #s, 2 do
        out[#out + 1] = string.char(tonumber(ssub(s, i, i + 1), 16) or 0)
    end
    return table.concat(out)
end

-- Format a JUMD type value (upstream Jpeg2000.pm 'type' PrintConv): the 16
-- bytes are hex-encoded by the ValueConv, then split as 8-4-4-16 with the
-- first 4 ascii chars parenthesized when printable.
local function FormatJUMDType(_self, val)
    local a = { val:match('^(%x%x%x%x%x%x%x%x)(%x%x%x%x)(%x%x%x%x)(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)$') }
    if not a[1] then return val end
    local ascii = hexToStr(a[1])
    if ascii:match('^[a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9][a-zA-Z0-9]$') then
        a[1] = '(' .. ascii .. ')'
    end
    return table.concat(a, '-')
end

-- JPEG 2000 "box" (ie. atom) names
-- Note: only tags with a defined "Format" are extracted
-- (JUMBF-related entries only; the JPEG 2000 / JXL boxes are deferred)
-- Read/write Brotli-compressed metadata (upstream ProcessBrotli).
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, or nil when writing and the data can't be handled
-- (which makes WriteDirectory keep the original box), or the new box data
-- when writing.
-- (defined ahead of %Main, which references it; IO::Uncompress::Brotli and
--  IO::Compress::Brotli are the optional rock lbrotli)
local function ProcessBrotli(et, dirInfo, tagTablePtr)
    -- (upstream reads $$dataPt from offset 0: its ProcessJpeg2000Box gives
    --  each box its own buffer when walking a file, while this port passes the
    --  whole buffer plus DirStart/DirLen, so the slice has to happen here)
    local dataPt = dirInfo.DataPt
    if dirInfo.DirStart then
        dataPt = dataPt:sub(dirInfo.DirStart + 1, dirInfo.DirStart + (dirInfo.DirLen or #dataPt))
    end

    if #dataPt <= 4 then return 0 end

    local isWriting = dirInfo.IsWriting
    local type_ = dataPt:sub(1, 4)
    if not isWriting then et:VerboseDir("Decrypted Brotli '" .. type_ .. "'") end
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
        local haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli')
        if isWriting and not haveBro then
            et:Warn('Install IO::Compress::Brotli to write Brotli-compressed metadata')
            return nil
        end
        local compress = et:Options('Compress')
        local verbose = isWriting and 0 or et:Options('Verbose')
        local dat = substr(dataPt, 4)
        local ok, unbro = pcall(IO_Uncompress_Brotli.unbro, dat, 100000000)
        if ok then dat = unbro end
        if not ok then Jpeg2000.BrotliWarn(et, type_, 1) return 1 end
        if verbose > 2 then et:VerboseDump(dat, { Prefix = et.INDENT .. '  ' }) end
        -- (Base: upstream passes none, i.e. 0; without it this port's
        --  ProcessTIFF would derive one from DirStart)
        local subdirInfo = { DataPt = dat, Base = 0 }
        if type_ == 'xml ' then
            subdirInfo.DirName = 'XMP' -- (necessary for block read/write)
            local XMP = require('lexiftool.XMP')
            if isWriting then
                if perlTruthy(compress) then subdirInfo.Compact = 1 end -- (no need to add padding if writing compressed)
                dat = Writer.WriteDirectory(et, subdirInfo, tagTablePtr)
            else
                XMP.ProcessXMP(et, subdirInfo, tagTablePtr)
            end
        elseif type_ == 'Exif' then
            subdirInfo.DirName = 'EXIF' -- (necessary for block read/write)
            subdirInfo.DirStart = 4 + (length(dat) > 4 and unpack('N', dat) or 0)
            if subdirInfo.DirStart > length(dat) then
                et:Warn("Corrupted Brotli '" .. type_ .. "' data")
            elseif isWriting then
                dat = Writer.WriteDirectory(et, subdirInfo, tagTablePtr, Writer.WriteTIFF)
                -- add back header word
                if dat ~= nil and length(dat) > 0 then dat = "\0\0\0\0" .. dat end
            else
                et:ProcessTIFF(subdirInfo, tagTablePtr)
            end
        elseif type_ == 'jumb' then
            if isWriting then return nil end -- (can't yet write JUMBF)
            Jpeg2000.ProcessJUMB(et, subdirInfo, tagTablePtr) -- (untested)
        end
        if isWriting then
            if dat == nil then return nil end
            -- rewrite as uncompressed if Compress option is set to 0 (or '')
            if compress ~= nil and not perlTruthy(compress) then return dat end
            local ok2, bro = pcall(IO_Compress_Brotli.bro, dat)
            if ok2 then dat = bro end
            if not ok2 then Jpeg2000.BrotliWarn(et, type_) return nil end
            et:VPrint(0, "  Writing Brotli-compressed " .. type_ .. "\n")
            return type_ .. dat
        end
    else
        et:Warn('Install IO::Uncompress::Brotli to decode Brotli-compressed metadata')
        if isWriting then return nil end
    end
    return 1
end
Jpeg2000.ProcessBrotli = ProcessBrotli

Jpeg2000.Main = {
    PREFERRED = 1, -- always add these tags when writing
    GROUPS = { [2] = 'Image' },
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
    -- JPEG 2000 boxes (only tags with a defined "Format" are extracted)
    ['jP  '] = 'JP2Signature', -- (ref 1)
    ['jP\26\26'] = 'JP2Signature', -- (ref 2)
    prfl = 'Profile',
    ftyp = {
        Name = 'FileType',
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.FileType' },
    },
    rreq = 'ReaderRequirements',
    jp2h = {
        Name = 'JP2Header',
        SubDirectory = {},
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
        SubDirectory = {},
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
        SubDirectory = {},
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
        SubDirectory = {},
    },
    -- CompositingLayerHeader sub boxes...
    cgrp = 'ColorGroup',
    opct = 'Opacity',
    creg = 'CodestreamRegistration',
    dtbl = 'DataReference',
    ftbl = {
        Name = 'FragmentTable',
        Subdirectory = {},
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
        SubDirectory = {},
    },
    nlst = 'NumberList',
    bfil = 'BinaryFilter',
    drep = 'DesiredReproductions',
    -- DesiredReproductions sub boxes...
    gtso = 'GraphicsTechnologyStandardOutput',
    chck = 'DigitalSignature',
    mp7b = 'MPEG7Binary',
    free = 'Free',
    jp2c = {
        {
            Name = 'ContiguousCodestream',
            Condition = function(self) return not self.jumd_level end,
        },
        {
            Name = 'PreviewImage',
            Groups = { [2] = 'Preview' },
            Format = 'undef',
            Binary = 1,
        },
    },
    jp2i = {
        Name = 'IntellectualProperty',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    -- jbrd - JPEG Bitstream Reconstruction Data (allows lossless conversion
    -- back to original JPG; write-side only upstream, not ported)
    jxlc = {
        Name = 'JXLCodestream',
        Format = 'undef',
        Notes = [[
            Codestream in JPEG XL image.  Currently processed only to determine
            ImageSize
        ]],
        RawConv = function(self, val)
            Jpeg2000.ProcessJXLCodestream(self, val)
            return nil
        end,
    },
    jxlp = {
        Name = 'PartialJXLCodestream',
        Format = 'undef',
        Notes = [[
            Partial codestreams in JPEG XL image.  Currently processed only to determine
            ImageSize
        ]],
        RawConv = function(self, val)
            Jpeg2000.ProcessJXLCodestream(self, val)
            return nil
        end,
    },
    Exif = {
        Name = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            -- (upstream Image::ExifTool::WriteTIFF, the *directory* writer;
            --  this port has it as Writer.WriteTIFF)
            WriteProc = Writer.WriteTIFF,
            DirName = 'EXIF',
            -- upstream: '$valuePtr + 4 + (length($$dataPt)-$valuePtr > 4 ? unpack("N", $$dataPt) : 0)'
            -- (its $$dataPt is this box's own value; here that arrives as `val`)
            Start = function(_self, val, valuePtr)
                return valuePtr + 4 + (#val > 4 and ExifTool.Get32u(val, 0) or 0)
            end,
        },
    },
    hrgm = {
        Name = 'GainMapImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef',
        Binary = 1,
    },
    brob = { -- Brotli-encoded metadata (see https://libjxl.readthedocs.io/en/latest/api_decoder.html)
        {
            Name = 'BrotliXMP',
            Condition = function(_self, val) return val ~= nil and lc(val:sub(1, 4)) == 'xml ' end,
            SubDirectory = {
                TagTable = 'lexiftool.XMP.Main',
                ProcessProc = ProcessBrotli,
                WriteProc = ProcessBrotli,
                -- (don't set DirName to 'XMP' because this would enable a block write of raw XMP)
            },
        },{
            Name = 'BrotliEXIF',
            Condition = function(_self, val) return val ~= nil and lc(val:sub(1, 4)) == 'exif' end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ProcessBrotli,
                WriteProc = ProcessBrotli,
                -- (don't set DirName to 'EXIF' because this would enable a block write of raw EXIF)
            },
        },{
            Name = 'BrotliJUMB',
            Condition = function(_self, val) return val ~= nil and lc(val:sub(1, 4)) == 'jumb' end,
            SubDirectory = {
                TagTable = 'lexiftool.Jpeg2000.Main',
                ProcessProc = ProcessBrotli,
            },
        },
    },
   ['xml '] = { {
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
    }, {
        Name = 'XMP',
        Notes = 'used for XMP in JPEG XL files',
        -- NOTE: the hacked code relies on this being at index 1 of the tagInfo list!
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    } },
    uuid = {
        {
            Name = 'UUID-EXIF',
            -- (this is the EXIF that we create in JP2)
            Condition = function(_self, val)
                return perl.matches(val, '^JpgTiffExif->JP2(?!Exif\\0\\0)') ~= nil
            end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                WriteProc = Writer.WriteTIFF,
                DirName = 'EXIF',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-EXIF2',
            -- written by Photoshop 7.01+Adobe JPEG2000-plugin v1.5
            Condition = function(_self, val) return val and val:sub(1, 16) == '\5\55\205\171\157\12\68\49\167\42\250\86\31\42\17\62' end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                WriteProc = Writer.WriteTIFF,
                DirName = 'EXIF',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-EXIF_bad',
            -- written by Digikam
            Condition = function(_self, val)
                return perl.matches(val, '^JpgTiffExif->JP2') ~= nil
            end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                WriteProc = Writer.WriteTIFF,
                DirName = 'EXIF',
                Start = function(_et, _val, valuePtr) return valuePtr + 22 end,
            },
        },
        {
            Name = 'UUID-IPTC',
            -- (this is the IPTC that we create in JP2)
            Condition = function(_self, val) return val and val:sub(1, 16) == '\51\199\164\210\184\29\71\35\160\186\241\163\224\151\173\56' end,
            SubDirectory = {
                TagTable = 'lexiftool.IPTC.Main',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-IPTC2',
            -- written by Photoshop 7.01+Adobe JPEG2000-plugin v1.5
            Condition = function(_self, val) return val and val:sub(1, 16) == '\9\161\78\151\192\180\66\224\190\191\54\223\111\12\227\111' end,
            SubDirectory = {
                TagTable = 'lexiftool.IPTC.Main',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-XMP',
            Condition = function(_self, val) return val and val:sub(1, 16) == '\190\122\207\203\151\169\66\232\156\113\153\148\145\227\175\172' end,
            SubDirectory = {
                TagTable = 'lexiftool.XMP.Main',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-GeoJP2',
            Condition = function(_self, val) return val and val:sub(1, 16) == '\177\75\248\189\8\61\75\67\165\174\140\215\213\166\206\3' end,
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                ProcessProc = ExifTool.ProcessTIFF,
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-Photoshop',
            -- written by Photoshop 7.01+Adobe JPEG2000-plugin v1.5
            Condition = function(_self, val) return val and val:sub(1, 16) == '\44\76\1\0\133\4\64\185\160\62\86\33\72\214\223\235' end,
            SubDirectory = {
                TagTable = 'lexiftool.Photoshop.Main',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-C2PAClaimSignature',  -- (seen in incorrectly-formatted JUMB data of JPEG images)
            -- (may be able to remove this when JUMBF specification is finalized)
            Condition = function(_self, val) return val and val:sub(1, 16) == 'c2cs\0\17\0\16\128\0\0\170\0\56\155\113' end,
            SubDirectory = {
                TagTable = 'lexiftool.CBOR.Main',
                Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            },
        },
        {
            Name = 'UUID-Signature',  -- (seen in JUMB data of JPEG images)
            -- (may be able to remove this when JUMBF specification is finalized)
            Condition = function(_self, val) return val and val:sub(1, 16) == 'casg\0\17\0\16\128\0\0\170\0\56\155\113' end,
            Format = 'undef',
            ValueConv = function(_self, val) return perl.substr(val, 16) end,
        },
        {
            Name = 'UUID-Unknown',
        },
    },
    uinf = {
        Name = 'UUIDInfo',
        SubDirectory = {},
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
            ProcessProc = false, -- predeclaration, see below for implementation
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
            val = ssub(val, 2)
            val = val:gsub('\0+$', '')
            val = val:gsub('\0', ', ')
            return val
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
        ValueConv = hexConv,
        JUMBF_Suffix = 'Salt', -- (used when tag is renamed according to JUMDLabel)
    },
}

-- resolution units for the Capture/DisplayResolution boxes (upstream
-- %resolutionUnit; only the -3..6 entries -- not exercised by the JP2
-- golden's resolution-less fixture, kept for parity)
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

-- JP2 file-type box (upstream %Jpeg2000::FileType)
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
        ValueConv = function(_self, val)
            return sprintf('%x.%x.%x', val:byte(1) * 256 + val:byte(2), val:byte(3), val:byte(4))
        end,
    },
    [2] = {
        Name = 'CompatibleBrands',
        Format = 'undef[$size-8]',
        List = 1, -- (for documentation only)
        -- ignore any entry with a null, and return others as a list
        ValueConv = function(_self, val)
            local a = {}
            for b in val:gmatch('....') do
                if not b:find('\0', 1, true) then a[#a + 1] = b end
            end
            return a
        end,
    },
}

-- JP2 image header (upstream %Jpeg2000::ImageHeader)
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
            return ((val & 0x7f) + 1) .. ' Bits, ' .. sign
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

-- JP2 capture resolution (upstream %Jpeg2000::CaptureResolution)
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

-- JP2 display resolution (upstream %Jpeg2000::DisplayResolution)
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

-- JP2 color specification (upstream %Jpeg2000::ColorSpec, read subset)
Jpeg2000.ColorSpec = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = Writer.WriteBinaryData, -- (we don't actually call this)
    CHECK_PROC = Writer.CheckBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int8s',
    WRITABLE = 1,
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
        RawConv = function(self, val)
            self.ColorSpecMethod = val
            return val
        end,
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
                return self.ColorSpecMethod == 2 or self.ColorSpecMethod == 3
            end,
            Format = 'undef[$size-3]',
            SubDirectory = {
                TagTable = 'lexiftool.ICC_Profile.Main',
            },
        },
        {
            Name = 'ColorSpace',
            Condition = function(self) return self.ColorSpecMethod == 1 end,
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
                [15] = 'Bi-level(2)',
                [16] = 'sRGB',
                [17] = 'Grayscale',
                [18] = 'sYCC',
                [19] = 'CIEJab',
                [20] = 'e-sRGB',
                [21] = 'ROMM-RGB',
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
    type = {
        Name = 'JUMDType',
        ValueConv = hexConv,
        PrintConv = FormatJUMDType,
        -- seen:
        -- cacb/cast/caas/cacl/casg/json-00110010800000aa00389b71
        --   (also brob- but not yet tested)
        -- 6579d6fbdba2446bb2ac1b82feeb89d1 - JPEG image
    },
    label = { Name = 'JUMDLabel' },
    toggles = {
        Name = 'JUMDToggles',
        Unknown = 1,
        PrintConv = { BITMASK = {
            [0] = 'Requestable',
            [1] = 'Label',
            [2] = 'ID',
            [3] = 'Signature',
        } },
    },
    id      = { Name = 'JUMDID', Description = 'JUMD ID' },
    sig     = {
        Name = 'JUMDSignature',
        PrintConv = hexConv,
    },
}

-- (PROCESS_PROC/WRITE_PROC are set after the function definitions below)

--------------------------------------------------------------------------------
-- Warn about error in Brotli compression/decompression
-- Inputs: 0) ExifTool ref, 1) box type, 2) true for decoding (Uncompress)
--------------------------------------------------------------------------------
function Jpeg2000.BrotliWarn(et, type_, uncompress)
    local enc, mod
    if perl.truthy(uncompress) then enc, mod = 'decoding', 'Uncompress' else enc, mod = 'encoding', 'Compress' end
    et:Warn("Error " .. enc .. " '" .. type_ .. "' brob box")
    et:Warn("Try updating to IO::" .. mod .. "::Brotli 0.004 or later")
end

--------------------------------------------------------------------------------
-- Create new JPEG 2000 boxes for tags and directories that were not already
-- there (upstream CreateNewBoxes)
-- Inputs: 0) ExifTool ref, 1) output writer (anything with a `write` method)
-- Returns: true on success
--------------------------------------------------------------------------------
local function CreateNewBoxes(et, outfile)
    local addTags = et.AddJp2Tags or {}
    local addDirs = et.AddJp2Dirs or {}
    et.AddJp2Tags = nil
    et.AddJp2Dirs = nil
    -- add JPEG2000 tags
    local tags = {}
    for tag in pairs(addTags) do tags[#tags + 1] = tag end
    tsort(tags)
    for _, tag in ipairs(tags) do
        local tagInfo = addTags[tag]
        local nvHash = Writer.GetNewValueHash(et, tagInfo)
        -- (native JPEG2000 information is always preferred, so don't check IsCreating)
        if (tagInfo.List or (Writer.IsOverwriting(et, nvHash) or 0) > 0)
                and not (nvHash and nvHash.EditOnly) then
            for _, val in ipairs(et:GetNewValue(nvHash, true)) do
                local boxhdr = ExifTool.Put32u(#val + 8) .. tagInfo.TagID
                Write(outfile, boxhdr, val)
                et.CHANGED = (et.CHANGED or 0) + 1
                et:VerboseValue('+ Jpeg2000:' .. tagInfo.Name, val)
            end
        end
    end
    -- add UUID boxes (and/or JXL Exif/XML boxes)
    local dirs = {}
    for dirName in pairs(addDirs) do dirs[#dirs + 1] = dirName end
    tsort(dirs)
    for _, dirName in ipairs(dirs) do
        -- handle JPEG XL XMP and EXIF
        if dirName == 'xml ' or dirName == 'Exif' then
            local tag, dir = 'xml ', 'XMP'
            if dirName ~= 'xml ' then tag, dir = 'Exif', 'EXIF' end
            local tagInfo = Jpeg2000.Main[tag]
            if tagInfo[1] then tagInfo = tagInfo[2] end -- (hack for stupid JXL XMP)
            local subdir = tagInfo.SubDirectory
            local tagTable = et:GetTagTable(subdir.TagTable)
            if dir == 'XMP' then tagTable = et:GetTagTable('lexiftool.XMP.Main') end
            local dirInfo = {
                DirName = dir,
                Parent  = tag,
            }
            local compress = et:Options('Compress')
            if perlTruthy(et.IsJXL) and perlTruthy(compress) then dirInfo.Compact = 1 end
            local newdir = Writer.WriteDirectory(et, dirInfo, tagTable, subdir.WriteProc)
            if type(newdir) == 'string' and #newdir > 0 then
                -- not sure why, but EXIF box is padded with leading 0's in my sample
                local pad = dirName == 'Exif' and '\0\0\0\0' or ''
                if perlTruthy(et.IsJXL) and perlTruthy(compress) then
                    -- create as Brotli-compressed metadata
                    local haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli')
                    if haveBro then
                        local okBro, compressed = pcall(IO_Compress_Brotli.bro, pad .. newdir)
                        if not okBro or not perlTruthy(compressed) then
                            Jpeg2000.BrotliWarn(et, dirName)
                        else
                            et:VPrint(0, "  Writing Brotli-compressed " .. dir .. "\n")
                            newdir = compressed
                            pad = tag
                            tag = 'brob'
                        end
                    else
                        et:Warn('Install IO::Compress::Brotli to create Brotli-compressed metadata')
                    end
                end
                local boxhdr = ExifTool.Put32u(#newdir + #pad + 8) .. tag
                Write(outfile, boxhdr, pad, newdir)
                goto continueDir
            end
        end
        if uuid[dirName] then
            for _, tagInfo in ipairs(Jpeg2000.Main.uuid) do
                if tagInfo.Name == dirName then
                    local subdir = tagInfo.SubDirectory
                    local tagTable = et:GetTagTable(subdir.TagTable)
                    -- remove "UUID-" from start of directory name to allow
                    -- appropriate directories to be written as a block
                    local newdir = Writer.WriteDirectory(et, {
                        DirName = (subdir.DirName or dirName):gsub('^UUID%-', ''),
                        Parent  = 'JP2',
                    }, tagTable, subdir.WriteProc)
                    if type(newdir) == 'string' and #newdir > 0 then
                        local boxhdr = ExifTool.Put32u(#newdir + 24) .. 'uuid' .. uuid[dirName]
                        Write(outfile, boxhdr, newdir)
                        break
                    end
                end
            end
        end
        ::continueDir::
    end
    return true
end

--------------------------------------------------------------------------------
-- Create Color Specification Box (upstream CreateColorSpec)
-- Inputs: 0) ExifTool ref, 1) output writer
-- Returns: true on success
--------------------------------------------------------------------------------
local function CreateColorSpec(et, outfile)
    local meth   = et:GetNewValue('Jpeg2000:ColorSpecMethod')
    local prec   = et:GetNewValue('Jpeg2000:ColorSpecPrecedence') or 0
    local approx = et:GetNewValue('Jpeg2000:ColorSpecApproximation') or 0
    local icc    = et:GetNewValue('ICC_Profile')
    local space  = et:GetNewValue('Jpeg2000:ColorSpace')
    local cdata  = et:GetNewValue('Jpeg2000:ColorSpecData')
    if not meth or meth == 0 then
        if icc then
            meth = 2
        elseif space ~= nil then
            meth = 1
        elseif cdata ~= nil then
            meth = 4
        else
            et:Warn('Color space not defined')
            return false
        end
    end
    meth = tonumber(meth) or meth
    if meth == 1 then
        if space == nil then et:Warn('Must specify ColorSpace') return false end
        cdata = ExifTool.Put32u(space)
    elseif meth == 2 or meth == 3 then
        if icc == nil then et:Warn('Must specify ICC_Profile') return false end
        cdata = icc
    elseif meth == 4 then
        if cdata == nil then et:Warn('Must specify ColorSpecData') return false end
    else
        et:Warn('Unknown ColorSpecMethod')
        return false
    end
    local boxhdr = ExifTool.Put32u(#cdata + 11) .. 'colr'
    Write(outfile, boxhdr, string.char(meth, tonumber(prec) or 0, tonumber(approx) or 0), cdata)
    et.CHANGED = (et.CHANGED or 0) + 1
    et:VPrint(1, '    + Jpeg2000:ColorSpec\n')
    return true
end

--------------------------------------------------------------------------------
-- Read/write JPEG 2000 boxes
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function Jpeg2000.ProcessJpeg2000Box(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataLen = dirInfo.DataLen
    local dataPos = dirInfo.DataPos or 0
    local dirLen = dirInfo.DirLen or 0
    local dirStart = dirInfo.DirStart or 0
    local base = dirInfo.Base or 0
    local dirName = dirInfo.DirName or ''
    local dirEnd = dirStart + dirLen
    local outfile = dirInfo.OutFile
    local raf = dirInfo.RAF
    local verbose, doColour, hash

    -- This port's box walker is always the DataPt kind (see the module note on
    -- ProcessJP2), so writing always means upstream's buffered branch: collect
    -- the new boxes and hand them back as a string. `outBuff` is that buffer,
    -- upstream's `$outfile = \$outBuff` -- the box { value = <carray> }.
    local outBuff
    if outfile then
        outBuff = { value = carray.new('char') }
        -- determine if we will be writing colr box
        if dirName == 'JP2Header' then
            if et:GetNewValue('ColorSpecMethod') ~= nil or et:GetNewValue('ICC_Profile') or
               et:GetNewValue('ColorSpecPrecedence') ~= nil or et:GetNewValue('ColorSpace') ~= nil or
               et:GetNewValue('ColorSpecApproximation') ~= nil or et:GetNewValue('ColorSpecData') ~= nil then
                doColour = 2
            end
        end
    else
        -- (must not set verbose flag when writing!)
        verbose = et:Options('Verbose')
        if perl.truthy(verbose) then et:VerboseDir(dirName) end
        -- do hash if requested, but only for top-level image data
        -- (rawget: the member, not the method of that name)
        if raf then hash = rawget(et, 'ImageDataHash') end
    end

    if dataPt then
        -- save C2PA JUMBF as a block if requested
        if dirName == 'JUMBF' and et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP.jumbf and not dirInfo.NoBlockSave then
            if dirStart or dirLen ~= #dataPt then
                local dat = ssub(dataPt, dirStart + 1, dirStart + dirLen)
                et:FoundTag('JUMBF', dat)
            else
                et:FoundTag('JUMBF', dataPt)
            end
        end
    end

    -- loop through all contained boxes
    local pos = dirStart
    while true do
        local boxLen = et.Get32u(dataPt, pos)
        local boxID = ssub(dataPt, pos + 5, pos + 8)
        local hdrLen = 8 -- the box header length
        if pos + hdrLen > dirEnd then
            break -- (no more complete box headers in this directory)
        end
        -- (ftbl box contains flst boxes with absolute file offsets, not
        --  currently handled)
        if outfile and boxID == 'ftbl' then
            et:Error("Can't yet handle fragmented JPX files")
            return -1
        end
        -- remove old colr boxes if necessary
        local dropBox = false
        if doColour and boxID == 'colr' then
            if doColour == 1 then -- did we successfully write the new colr box?
                et:VPrint(1, '    - Jpeg2000:ColorSpec\n')
                et.CHANGED = (et.CHANGED or 0) + 1
                dropBox = true
            else
                et:Warn('Out-of-order colr box encountered')
                doColour = nil
            end
        end
        pos = pos + hdrLen -- move to end of box header
        if boxLen == 1 then
            -- box header contains an additional 8-byte integer for length
            hdrLen = hdrLen + 8
            if pos > dirEnd - 8 then break end
            local hi = et.Get32u(dataPt, pos)
            local lo = et.Get32u(dataPt, pos + 4)
            if hi ~= 0 then
                et:Warn("Can't currently handle JPEG 2000 boxes > 4 GB")
                return 1
            end
            pos = pos + 8
            boxLen = lo - hdrLen -- length of remaining box data
        elseif boxLen == 0 then
            boxLen = dirEnd - pos -- data runs to end of file
        else
            boxLen = boxLen - hdrLen -- length of remaining box data
        end
        if boxLen < 0 then
            et:Warn('Invalid JPEG 2000 box length')
            return 1
        end
        local truncated
        if pos + boxLen > dirEnd then
            boxLen = dirEnd - pos -- (truncated box)
            truncated = true
        end
        local valuePtr = pos
        local tagInfo = et:GetTagInfo(tagTablePtr, boxID)
        -- (upstream hashes the box data as it reads it from the RAF: in one
        --  piece -- `$hash->add($buff)` plus the verbose message -- or, for a
        --  box it skips or one that runs to the end of the file, through
        --  ImageDataHash, whose message has the same form; for a truncated
        --  box see the Port notes.  Here the box data is already in dataPt)
        if hash and isImageData[boxID] and not truncated then
            hash:add(ssub(dataPt, pos + 1, pos + boxLen))
            et:VPrint(0, et.INDENT .. '(ImageDataHash: ' .. boxLen .. ' bytes of ' .. boxID .. ' data)\n')
        end
        -- (unknown boxes without Verbose fall through without processing;
        --  the bottom-of-loop advance steps over them -- this port
        --  previously ALSO advanced inside the skip path, double-stepping
        --  every unknown box and desynchronizing the walk)
        -- (dropBox: the old colr box is dropped, neither read nor copied)
        if dropBox then goto continueBox end
        if tagInfo == nil and outfile then
            -- no need to process this box, copy it through unchanged
            Write(outBuff, ssub(dataPt, pos - hdrLen + 1, pos + boxLen))
        else
            if tagInfo == false then
                -- GetTagInfo() required the value for a Condition
                -- (`false` is this port's stand-in for upstream's '')
                local tmpVal = ssub(dataPt, valuePtr + 1, valuePtr + math.min(boxLen, 128))
                tagInfo = et:GetTagInfo(tagTablePtr, boxID, tmpVal)
            end
            -- delete all UUID boxes and any writable box if deleting all information
            if outfile and tagInfo then
                if boxID == 'uuid' and Writer.IsGroupDeleted(et, '*') then
                    et:VPrint(0, '  Deleting ' .. tagInfo.Name .. '\n')
                    et.CHANGED = (et.CHANGED or 0) + 1
                    goto continueBox
                elseif tagInfo.Writable then
                    local isOverwriting
                    if Writer.IsGroupDeleted(et, 'Jpeg2000') then
                        isOverwriting = 1
                    else
                        isOverwriting = Writer.IsOverwriting(et, Writer.GetNewValueHash(et, tagInfo))
                    end
                    if perlTruthy(isOverwriting) then
                        local val = ssub(dataPt, valuePtr + 1, valuePtr + boxLen)
                        et:VerboseValue('- Jpeg2000:' .. tagInfo.Name, val)
                        et.CHANGED = (et.CHANGED or 0) + 1
                        goto continueBox
                    elseif not tagInfo.List and et.AddJp2Tags then
                        et.AddJp2Tags[boxID] = nil
                    end
                end
            end
            if tagInfo then
                -- create new tag for JUMBF data values with name corresponding to JUMBFLabel
                if et.JUMBFLabel and (not tagInfo.SubDirectory or tagInfo.BlockExtract) then
                    local newTagInfo = {}
                    for k, v in pairs(tagInfo) do newTagInfo[k] = v end
                    newTagInfo.Name = et.JUMBFLabel .. (newTagInfo.JUMBF_Suffix or '')
                    newTagInfo.Description = (et.MakeDescription(newTagInfo.Name)):gsub('C2 PA', 'C2PA')
                    et:AddTagToTable(tagTablePtr, '_JUMBF_' .. et.JUMBFLabel, newTagInfo)
                    newTagInfo.Protected = nil -- (must do this so -j -b returns JUMBF binary data)
                    newTagInfo.TagID = boxID
                    tagInfo = newTagInfo
                end
            end
            if perl.truthy(verbose) then
                et:VerboseInfo(boxID, tagInfo, {
                    Table  = tagTablePtr,
                    DataPt = dataPt,
                    Size   = boxLen,
                    Start  = valuePtr,
                    Addr   = valuePtr + dataPos + base,
                })
            end
            if tagInfo then
                if tagInfo.SubDirectory then
                    local subdir = tagInfo.SubDirectory
                    local subdirStart = valuePtr
                    local subdirLen = boxLen
                    if subdir.Start then
                        -- #### eval Start ($valuePtr, $dataPt)
                        local off
                        if type(subdir.Start) == 'function' then
                            off = subdir.Start(et, ssub(dataPt, valuePtr + 1, valuePtr + boxLen), valuePtr)
                        else
                            local ok, val = pcall(assert(load('return ' .. subdir.Start, 'Start')))
                            if ok then off = val end
                        end
                        if off then
                            subdirStart = off
                            subdirLen = subdirLen - (subdirStart - valuePtr)
                            if subdirLen < 0 then
                                subdirStart = valuePtr
                                subdirLen = 0
                            end
                        end
                    end
                    local subdirInfo = {
                        Parent = 'JP2',
                        DataPt = dataPt,
                        DataPos = -subdirStart, -- (relative to Base)
                        DataLen = dataLen,
                        DirStart = subdirStart,
                        DirLen = subdirLen,
                        DirName = (subdir.DirName or tagInfo.Name):gsub('^UUID%-', ''),
                        OutFile = outfile,
                        Base = base + dataPos + subdirStart,
                    }
                    local subTable = subdir.TagTable and et:GetTagTable(subdir.TagTable) or tagTablePtr
                    if outfile then
                        -- (special case for brob box, which may be EXIF or XMP)
                        local fakeID = boxID
                        if boxID == 'brob' then
                            -- I have seen 'brob' ID's with funny cases, so standardize these
                            local head = lc(ssub(dataPt, valuePtr + 1, valuePtr + 4))
                            if head == 'xml ' then fakeID = 'xml ' end
                            if head == 'exif' then fakeID = 'Exif' end
                        end
                        local newdir
                        -- only edit writable UUID, Exif and jp2h boxes
                        if uuid[tagInfo.Name] or fakeID == 'Exif' or
                           (fakeID == 'xml ' and et.IsJXL) or
                           (boxID == 'jp2h' and et.EDIT_DIRS and et.EDIT_DIRS.jp2h) then
                            local compress = et:Options('Compress')
                            subdirInfo.Parent = fakeID
                            if perlTruthy(compress) and perlTruthy(et.IsJXL) then subdirInfo.Compact = 1 end
                            newdir = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                            -- next if deleting the box
                            if type(newdir) == 'string' and #newdir == 0 then goto continueBox end
                            -- compress JXL EXIF or XMP metadata if requested
                            if newdir ~= nil and perlTruthy(et.IsJXL) and compress ~= nil and
                                (fakeID == 'Exif' or fakeID == 'xml ')
                            then
                                if perlTruthy(compress) and boxID ~= 'brob' then
                                    -- rewrite as a Brotli-compressed 'brob' box
                                    local haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli')
                                    if haveBro then
                                        local pad = boxID == 'Exif' and "\0\0\0\0" or ''
                                        local okBro, compressed = pcall(IO_Compress_Brotli.bro, pad .. newdir)
                                        if not okBro or not perlTruthy(compressed) then
                                            Jpeg2000.BrotliWarn(et, boxID)
                                        else
                                            et:VPrint(0, "  Writing Brotli-compressed " .. boxID .. "\n")
                                            newdir = boxID .. compressed
                                            boxID = 'brob'
                                            subdirStart, valuePtr = 0, 0
                                            et.CHANGED = (et.CHANGED or 0) + 1
                                        end
                                    else
                                        et:Warn('Install IO::Compress::Brotli to write Brotli-compressed metadata')
                                    end
                                elseif not perlTruthy(compress) and boxID == 'brob' then
                                    -- (in this case, ProcessBrotli has returned uncompressed data,
                                    --  so change to the uncompressed 'xml ' or 'Exif' box type)
                                    et:VPrint(0, "  Writing uncompressed " .. fakeID .. "\n")
                                    boxID = fakeID
                                    subdirStart, valuePtr = 0, 0
                                    et.CHANGED = (et.CHANGED or 0) + 1
                                end
                            end
                        elseif uuid[tagInfo.Name] ~= nil then
                            et:Warn('Not editing ' .. tagInfo.Name .. ' box', 1)
                        end
                        -- remove this directory from our create list
                        if et.AddJp2Dirs then
                            et.AddJp2Dirs[fakeID] = nil             -- (eg. 'Exif' or 'xml ')
                            if boxID == 'brob' then
                                -- (can't make tag Name 'XMP' or 'Exif' for Brotli-compressed tags because it
                                --  would break the logic in WriteDirectory(), so we do a lookup here instead)
                                local name = (fakeID == 'xml ') and 'XMP' or
                                             (fakeID == 'Exif') and 'EXIF' or nil
                                if name then et.AddJp2Dirs[name] = nil end
                            else
                                et.AddJp2Dirs[tagInfo.Name] = nil   -- (eg. 'EXIF' or 'XMP')
                            end
                        end
                        -- use old box data if not changed
                        if type(newdir) ~= 'string' then
                            newdir = ssub(dataPt, subdirStart + 1, subdirStart + subdirLen)
                        end
                        local prefixLen = subdirStart - valuePtr
                        local boxhdr = ExifTool.Put32u(#newdir + 8 + prefixLen) .. boxID
                        if prefixLen > 0 then
                            boxhdr = boxhdr .. ssub(dataPt, valuePtr + 1, valuePtr + prefixLen)
                        end
                        Write(outBuff, boxhdr, newdir)
                        -- write new colr box immediately after ihdr
                        if doColour and boxID == 'ihdr' then
                            -- (shouldn't be multiple ihdr boxes, but just in case, write only 1)
                            doColour = (doColour == 2) and (CreateColorSpec(et, outBuff) and 1 or 0) or 0
                        end
                        goto continueBox
                    end
                    -- (extract as a block if specified)
                    if tagInfo.BlockExtract then subdirInfo.BlockInfo = tagInfo end
                    if not et:ProcessDirectory(subdirInfo, subTable, subdir.ProcessProc) then
                        if subTable == tagTablePtr then
                            et:Warn('JPEG 2000 format error')
                            return 1
                        end
                        et:Warn('Unrecognized ' .. tagInfo.Name .. ' box')
                    end
                elseif tagInfo.Format and not outfile then
                    -- only save tag values if Format was specified
                    local val = et.ReadValue(dataPt, valuePtr, tagInfo.Format, nil, boxLen)
                    if val ~= nil then
                        et:FoundTag(tagInfo, val)
                    end
                elseif outfile then
                    local boxhdr = ExifTool.Put32u(boxLen + 8) .. boxID
                    Write(outBuff, boxhdr, ssub(dataPt, valuePtr + 1, valuePtr + boxLen))
                end
            end
        end
        ::continueBox::
        pos = pos + boxLen -- move to next box
    end
    if outfile then
        -- Upstream creates the new boxes at end-of-file in its RAF branch;
        -- this port's top-level directory IS the DataPt one, so it happens
        -- here, once the last box of the file has been passed.
        if dirName == 'JP2' then CreateNewBoxes(et, outBuff) end
        return outBuff.value:tostring()
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read/write meta information from a C2PA/JUMBF file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JUMBF file
-- (like ProcessJP2 below, the box walker here takes the whole file as DataPt
-- instead of upstream's RAF-incremental reader)
--------------------------------------------------------------------------------
function Jpeg2000.ProcessJUMBF(et, dirInfo)
    local raf = dirInfo.RAF
    local hdr, n

    -- check to be sure this is a valid JPG2000 file
    n, hdr = raf:Read(20)
    if not (n == 20 and raf:Seek(0, 0)) then return 0 end
    local typ = perl.matches(hdr, [[(?s)^.{4}jumb\0.{3}jumd(.{4})]])
    if not typ then return 0 end
    et:SetFileType(typ == 'c2pa' and 'C2PA' or 'JUMBF')
    local size = raf:Length()
    local n2, buff = raf:Read(size)
    if n2 ~= size then return 0 end
    local dirInfo2 = {
        DataPt = buff,
        DataLen = size,
        DirStart = 0,
        DirLen = size,
        RAF = raf,
        DirName = 'JUMBF',
    }
    local tagTablePtr = et:GetTagTable('lexiftool.Jpeg2000.Main')
    return et:ProcessDirectory(dirInfo2, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Read information from a JPEG 2000 (JP2) file (upstream ProcessJP2, read
-- subset: reads the whole file into memory instead of the RAF-incremental
-- box reader, which is equivalent for the vendored test files)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid JP2 file
--------------------------------------------------------------------------------
function Jpeg2000.ProcessJP2(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    -- check to be sure this is a valid JPG2000 file
    local n, hdr = raf:Read(12)
    if n ~= 12 then return 0 end
    if hdr ~= '\0\0\0\12jP  \13\10\135\10' and       -- (ref 1)
       hdr ~= '\0\0\0\12jP\26\26\13\10\135\10' and -- (ref 2)
       not et.IsJXL
    then
        if not perl.matches(hdr, [[^\xff\x4f\xff\x51\0]]) then return 0 end -- check for JP2 codestream format
        if outfile then
            et:Error('Writing of J2C files is not yet supported')
            return 0
        end
        -- add J2C markers if not done already
        if not ExifTool.jpegMarker[0x4f] then
            for k, v in pairs(j2cMarker) do ExifTool.jpegMarker[k] = v end
        end
        et:SetFileType('J2C')
        raf:Seek(0, 0)
        return et:ProcessJPEG(dirInfo)    -- decode with JPEG processor
    end
    if outfile then
        -- (upstream writes the 12-byte signature box here, before entering the
        --  box loop at offset 12; this port walks the file from offset 0, so
        --  the signature box goes through the loop like every other box)
        if et.IsJXL then
            Writer.InitWriteDirs(et, jxlMap)
            et.AddJp2Tags = { } -- (don't add JP2 tags in JXL files)
        else
            Writer.InitWriteDirs(et, jp2Map)
            et.AddJp2Tags = Writer.GetNewTagInfoHash(et, Jpeg2000.Main)
        end
        -- save list of directories to create
        local addDirs = {}
        for k, v in pairs(et.ADD_DIRS or {}) do addDirs[k] = v end
        et.AddJp2Dirs = addDirs
    else
        local fileType
        -- recognize JPX and JPM as unique types of JP2
        local n2, buff = raf:Read(12)
        if n2 == 12 and buff:match('^....ftyp') then
            local brand = ssub(buff, 9, 12)
            if brand == 'jpx ' then fileType = 'JPX' end
            if brand == 'jpm ' then fileType = 'JPM' end
            if brand == 'jxl ' then fileType = 'JXL' end
            if brand == 'jph ' then fileType = 'JPH' end
        end
        et:SetFileType(fileType)
    end
    raf:Seek(0, 0)
    ExifTool.SetByteOrder('MM') -- JPEG 2000 files are big-endian
    local size = raf:Length()
    local n3, fullBuff = raf:Read(size)
    if n3 ~= size then return 0 end
    local dirInfo2 = {
        DataPt = fullBuff,
        DataLen = size,
        DirStart = 0,
        DirLen = size,
        RAF = raf,
        DirName = 'JP2',
        OutFile = outfile,
    }
    local tagTablePtr = et:GetTagTable('lexiftool.Jpeg2000.Main')
    local rtn = et:ProcessDirectory(dirInfo2, tagTablePtr)
    if outfile then
        if type(rtn) ~= 'string' then return -1 end
        Write(outfile, rtn)
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read JUMBF box to keep track of sub-document numbers
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function Jpeg2000.ProcessJUMB(et, dirInfo, tagTablePtr)
    if et.jumd_level then
        et.jumd_level[#et.jumd_level] = et.jumd_level[#et.jumd_level] + 1 -- increment current sub-document number
    else
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1 -- new top-level sub-document
        et.jumd_level = { et.DOC_COUNT }
        et.SET_GROUP0 = 'JUMBF'
    end
    et.DOC_NUM = table.concat(et.jumd_level, '-')
    et.jumd_level[#et.jumd_level + 1] = 0
    Jpeg2000.ProcessJpeg2000Box(et, dirInfo, tagTablePtr)
    et.DOC_NUM = nil
    et.JUMBFLabel = nil
    et.jumd_level[#et.jumd_level] = nil
    if #et.jumd_level < 2 then
        et.jumd_level = nil
        et.SET_GROUP0 = nil
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read JUMBF description box (ref https://github.com/thorfdbg/codestream-parser)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function Jpeg2000.ProcessJUMD(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local endPos = pos + dirInfo.DirLen
    et:VerboseDir('JUMD', 0, endPos - pos)
    et.JUMBFLabel = nil
    if dirInfo.DirLen < 17 then
        et:Warn('Truncated JUMD directory')
        return 0
    end
    local type_ = ssub(dataPt, pos + 1, pos + 4)
    et:HandleTag(tagTablePtr, 'type', ssub(dataPt, pos + 1, pos + 16))
    pos = pos + 16
    local flags = et.Get8u(dataPt, pos)
    pos = pos + 1
    et:HandleTag(tagTablePtr, 'toggles', flags)
    if flags & 0x02 ~= 0 then -- label exists?
        -- find the NUL terminator after the label
        local nullPos = dataPt:find('\0', pos + 1, true)
        if not nullPos then
            et:Warn('Missing JUMD label terminator')
            return 0
        end
        local len = nullPos - pos
        local name = ssub(dataPt, pos + 1, nullPos)
        -- (the upstream label value includes the trailing NUL; TestLib's
        --  formatValue strips NUL chars, so the value renders as "cai")
        et:HandleTag(tagTablePtr, 'label', name)
        pos = pos + len
        if len > 0 then
            name = name:gsub('[^A-Za-z0-9_-]([a-z])', function(c) return uc(c) end)
            name = name:gsub('[^A-Za-z0-9_-]', '')
            name = name:gsub('__', '_', 1) -- collapse first double underline only (upstream has no /g)
            name = ucfirst(name)
            name = name:gsub('C2pa', 'C2PA', 1) -- upstream has no /g
            if #name < 2 then name = 'Tag' .. name end
            et.JUMBFLabel = name
        end
    end
    if flags & 0x04 ~= 0 then -- ID exists?
        if pos + 4 > endPos then
            et:Warn('Missing JUMD ID')
            return 0
        end
        et:HandleTag(tagTablePtr, 'id', et.Get32u(dataPt, pos))
        pos = pos + 4
    end
    if flags & 0x08 ~= 0 then -- signature exists?
        if pos + 32 > endPos then
            et:Warn('Missing JUMD signature')
            return 0
        end
        et:HandleTag(tagTablePtr, 'sig', ssub(dataPt, pos + 1, pos + 32))
        pos = pos + 32
    end
    local more = endPos - pos
    if more > 0 then
        -- (may find c2sh box hiding after JUMD record)
        if more >= 8 then
            local subdirInfo = {
                DataPt   = dataPt,
                DataLen  = dirInfo.DataLen,
                DirStart = pos,
                DirLen   = more,
                DirName  = 'JUMDPrivate',
            }
            et:ProcessDirectory(subdirInfo, et:GetTagTable('lexiftool.Jpeg2000.Main'))
        else
            et:Warn('Extra data in JUMD box ' .. more .. ' bytes)', 1)
        end
    end
    return 1
end

-- (PROCESS_PROC and ProcessProc are set here so the tables above can reference
--  the functions defined above)
Jpeg2000.Main.PROCESS_PROC = Jpeg2000.ProcessJpeg2000Box
Jpeg2000.Main.WRITE_PROC = Jpeg2000.ProcessJpeg2000Box
Jpeg2000.JUMD.PROCESS_PROC = Jpeg2000.ProcessJUMD
Jpeg2000.Main.jumb.SubDirectory.ProcessProc = Jpeg2000.ProcessJUMB

--------------------------------------------------------------------------------
-- Extract parameters from JPEG XL codestream [unverified!]
-- Inputs: 0) ExifTool ref, 1) codestream string
-- Returns: 1 on success
--------------------------------------------------------------------------------
local function GetBits(a, n)
    -- (upstream GetBits: consume n bits LSB-first across a byte array,
    --  shifting the whole array right by n bits)
    local v = 0
    local bit = 1
    while n > 0 do
        n = n - 1
        for i = 0, #a - 1 do
            local set = a[i + 1] & 1
            a[i + 1] = a[i + 1] >> 1
            if i > 0 then
                if set ~= 0 then a[i] = a[i] | 0x80 end
            else
                if set ~= 0 then v = v | bit end
                bit = bit << 1
            end
        end
    end
    return v
end

function Jpeg2000.ProcessJXLCodestream(et, dataPt)
    -- validate codestream (upstream `/^(\0\0\0\0)?\xff\x0a/`; PCRE2 via the
    --  facade -- Lua patterns have no optional group, so the two alternatives
    --  are expressed as one literal pattern)
    if not perl.matches(dataPt, '^((\\0\\0\\0\\0)?\\xff\\x0a)') then return 0 end
    -- ignore if already extracted (ie. subsequent jxlp boxes)
    if et.ProcessedJXLCodestream then return 0 end
    et.ProcessedJXLCodestream = true
    -- work with first 64 bytes of codestream data
    -- (and add padding if necessary to avoid unpacking past end of data)
    local dat
    if #dataPt > 64 then
        dat = dataPt:sub(1, 64)
    elseif #dataPt < 18 then
        dat = dataPt .. ('\0'):rep(18) -- (so we'll have a minimum 14 bytes to work with)
    else
        dat = dataPt
    end
    dat = dat:gsub('^\0\0\0\0', '') -- remove jxlp header word
    local a = { perl.unpack('x2C12', dat) }
    local x, y
    local small = GetBits(a, 1)
    if small ~= 0 then
        y = (GetBits(a, 5) + 1) * 8
    else
        local sizes = { [0]=9, [1]=13, [2]=18, [3]=30 }
        y = GetBits(a, sizes[GetBits(a, 2)]) + 1
    end
    local ratio = GetBits(a, 3)
    if ratio == 0 then
        if small ~= 0 then
            x = (GetBits(a, 5) + 1) * 8
        else
            local sizes = { [0]=9, [1]=13, [2]=18, [3]=30 }
            x = GetBits(a, sizes[GetBits(a, 2)]) + 1
        end
    else
        local r = ({ {1,1}, {12,10}, {4,3}, {3,2}, {16,9}, {5,4}, {2,1} })[ratio]
        x = math.floor(y * r[1] / r[2])
    end
    et:FoundTag('ImageWidth', x)
    et:FoundTag('ImageHeight', y)
    return 1
end

--------------------------------------------------------------------------------
-- Read/write meta information in a JPEG XL image
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid JPEG XL file
--------------------------------------------------------------------------------
function Jpeg2000.ProcessJXL(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local buff

    local n, hdr = raf:Read(12)
    if n ~= 12 then return 0 end
    if hdr == '\0\0\0\x0cJXL \x0d\x0a\x87\x0a' then
        -- JPEG XL in ISO BMFF container
        et.IsJXL = 1
    elseif hdr:match('^\255\10') then
        -- JPEG XL codestream
        if outfile then
            if et:Options('IgnoreMinorErrors') then
                et:Warn('Wrapped JXL codestream in ISO BMFF container')
            else
                et:Error('Will wrap JXL codestream in ISO BMFF container for writing', 1)
                return 0
            end
            et.IsJXL = 2
            local wrap = "\0\0\0\x0cJXL \x0d\x0a\x87\x0a\0\0\0\x14ftypjxl \0\0\0\0jxl "
            -- add metadata to empty ISO BMFF container
            dirInfo.RAF = require('lexiftool.RandomAccess').new(wrap)
        else
            et:SetFileType('JXL Codestream', 'image/jxl', 'jxl')
            -- (rawget: the member, not the method of that name)
            if rawget(et, 'ImageDataHash') and raf:Seek(0, 0) then
                et:ImageDataHash(raf, nil, 'JXL')
            end
            return Jpeg2000.ProcessJXLCodestream(et, hdr)
        end
    else
        return 0
    end
    -- (upstream seeks the ORIGINAL RAF here, not the replacement one it may
    --  just have put in dirInfo -- that one is a fresh in-memory buffer)
    if not raf:Seek(0, 0) then
        et:Error('Seek error')
        return 0
    end

    local success = Jpeg2000.ProcessJP2(et, dirInfo)

    if outfile and success > 0 and et.IsJXL == 2 then
        -- attach the JXL codestream box to the ISO BMFF file
        if not raf:Seek(0, 2) then return -1 end
        local size = raf:Tell()
        if not raf:Seek(0, 0) then return -1 end
        ExifTool.SetByteOrder('MM')
        if not Write(outfile, ExifTool.Put32u(size + 8), 'jxlc') then return -1 end
        while true do
            local bn
            bn, buff = raf:Read(65536)
            if bn == 0 then break end
            if not Write(outfile, buff) then return -1 end
        end
    end
    return success
end

return Jpeg2000
