--------------------------------------------------------------------------------
-- File:         lexiftool/PDF.lua
-- Ported from:  lib/Image/ExifTool/PDF.pm
--
-- Description:  Read PDF meta information
--
-- Revisions:    07/11/2005 - P. Harvey Created
--               07/25/2005 - P. Harvey Add support for encrypted documents
--
-- References:   1) http://www.adobe.com/devnet/pdf/pdf_reference.html
--               2) http://search.cpan.org/dist/Crypt-RC4/
--               3) http://www.adobe.com/devnet/acrobat/pdfs/PDF32000_2008.pdf
--               4) http://www.adobe.com/content/dam/Adobe/en/devnet/pdf/pdfs/adobe_supplement_iso32000.pdf
--               5) http://tools.ietf.org/search/rfc3454
--               6) http://www.armware.dk/RFC/rfc/rfc4013.html
--
-- Port notes:   Complete port of PDF.pm: every table, lookup and sub, in
--               upstream order (xref tables and PDF-1.5 xref streams,
--               object streams, all filters, RC4/AESV2/AESV3 decryption
--               incl. the Rev 6 hardened hash, ExtractEmbedded sub-
--               documents and joined AIPrivateData streams).  Deviations
--               forced by Lua:
--               - The predeclarations `sub FetchObject($$$$);` ... are one
--                 block of locals at the top; the subs assign to them (and
--                 are exported on the module table), and the PROCESS_PROC
--                 of the AcroForm/AF tables is filled in after the subs.
--               - PDF objects: a dictionary is a table with a `_tags` list
--                 (as upstream), an array a plain sequence, and an indirect
--                 reference (upstream's scalar ref) `{ ref = 'SCALAR',
--                 value = 'N G R' }`; the local `ref()` stands in for
--                 Perl's builtin on these three shapes.  %xref keys object
--                 numbers as Lua integers (Perl stringifies them), and an
--                 entry upstream sets to undef ("null object") is `false`.
--               - `\$data` arguments that a sub both reads and updates
--                 (ExtractObject, ReadToNested, DecodeLZW) are boxes
--                 `{ value = <carray> }` (doc/api.md §4); RC4Crypt and Crypt return the new
--                 string instead (as AES.Crypt does), and Crypt hands the
--                 data back unchanged where upstream leaves it untouched.
--               - Perl's `$/`, set with `local` in ReadPDF, is the module
--                 local RS that RandomAccess:ReadLine is called with.
--               - Regex `/g` matches that carry on at pos() are `matches`
--                 calls that take and return the 0-based end offset.
--               - Digest::SHA->new is ExifTool.DigestSHA (the `digest` rock).
--               - Perl names that clash with a Lua builtin or one of the
--                 aliases here take a trailing underscore (`$ref`,
--                 `$length`, `$next`, `%join`, `$type`, `@table`, ...), as
--                 do inner `my` variables that shadow an outer one.
--               - An undef element of a parsed array (an empty nested
--                 dictionary) is dropped: a Lua array cannot hold nil.
--               - The package variable $lastFetched (`use vars`), which
--                 WritePDF.pl resets too, is the module field
--                 PDF.lastFetched; the local ref() is exported as PDF.ref.
--               - The write-include WritePDF.pl is lexiftool/WritePDF.lua;
--                 its subs are bound here as AUTOLOAD closures (see the
--                 predeclarations).
--------------------------------------------------------------------------------

local PDF = {}
-- safe here: lexiftool.lua only lazy-loads this module from inside its
-- functions (GetTagTable/loadModule), so it is fully loaded by then
-- (same pattern as Garmin.lua)
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local carray = require('carray')
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local tr = perl.tr
local substr = perl.substr
local length = perl.length
local pack = perl.pack
local unpack = perl.unpack
local join = perl.join
local hex = perl.hex
local lc = perl.lc
local ucfirst = perl.ucfirst
local chr = perl.chr
local ord = perl.ord
local int = perl.int
local truthy = perl.truthy
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ConvertTimeSpan = ExifTool.ConvertTimeSpan

-- (upstream's predeclarations `sub FetchObject($$$$);` ... are this block of
--  locals; the subs below assign to them.  CheckPDF is a sub of WritePDF.pl,
--  which upstream AUTOLOADs -- DoAutoLoad loads it on the first call.  Here
--  every sub of WritePDF.pl is bound to a closure that loads WritePDF.lua on
--  first use)
local FetchObject, ExtractObject, ReadToNested, ProcessDict
local ProcessAcroForm, ExpandArray, ReadPDFValue, CheckPDF
for _, name in ipairs({ 'CheckPDF', 'WritePDFValue', 'EncodeString', 'CryptObject',
                        'GetFreeEntries', 'WriteObject', 'WritePDF' }) do
    PDF[name] = function(...) return require('lexiftool.WritePDF')[name](...) end
end
CheckPDF = PDF.CheckPDF
-- (and these, which Perl resolves at run time although they are called
--  above their definition)
local DecodeStream, Crypt, CryptStream

-- $lastFetched - last fetched object reference (used for decryption)
--                (undefined if fetched object was already decrypted, eg. object from stream)
-- (upstream `use vars qw($lastFetched)`: a package variable, which WritePDF.pl
--  resets too -- here the module field PDF.lastFetched)

local cryptInfo      -- encryption object reference (plus additional information)
local cryptString    -- flag that strings are encrypted
local cryptStream    -- flag that streams are encrypted
local lastOffset     -- last fetched object offset
local streamObjs = {} -- hash of stream objects
local fetched = {}    -- dicts fetched in verbose mode (to avoid cyclical recursion)
local pdfVer         -- version of PDF file being processed (from header)

-- (Perl's input record separator `$/`, which ReadPDF sets with `local`;
--  passed to every ReadLine below)
local RS = "\n"

-- Perl's ref() on a PDF object: 'HASH' for a dictionary (a `_tags` list, or
-- any other table with keys but no first element, like a hash built by hand),
-- 'SCALAR' for an indirect reference, 'ARRAY' for an array, '' for a plain
-- value
local function ref(val)
    if type(val) ~= 'table' then return '' end
    if val._tags then return 'HASH' end
    if val.ref == 'SCALAR' then return 'SCALAR' end
    if val[1] == nil and next(val) ~= nil then return 'HASH' end
    return 'ARRAY'
end
PDF.ref = ref     -- (for WritePDF.lua)

-- filters supported in DecodeStream()
local supportedFilter = {
    ['/FlateDecode'] = 1,
    ['/Crypt'] = 1,
    ['/Identity'] = 1,  -- (not filtered)
    ['/DCTDecode'] = 1, -- (JPEG image - not filtered)
    ['/JPXDecode'] = 1, -- (Jpeg2000 image - not filtered)
    ['/LZWDecode'] = 1, -- (usually a bitmapped image)
    ['/ASCIIHexDecode'] = 1,
    ['/ASCII85Decode'] = 1,
    -- other standard filters that we currently don't support
    --['/JBIG2Decode'] = 0, -- (JBIG2 image format not supported)
    --['/CCITTFaxDecode'] = 0,
    --['/RunLengthDecode'] = 0,
}

-- tags in main PDF directories
PDF.Main = {
    GROUPS = { [2] = 'Document' },
    VARS = { CAPTURE = { 'Main', 'Prev' } },
    Info = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Info' },
        -- Adobe Acrobat 10.1.5 will create a duplicate Info dictionary with
        -- a different object number when metadata is edited.  This flag
        -- is part of a patch to ignore this duplicate information (unless
        -- the IgnoreMinorErrors option is used)
        IgnoreDuplicates = 1,
    },
    Root = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Root' },
    },
    Encrypt = {
        NoProcess = 1, -- don't process normally (processed in advance)
        SubDirectory = { TagTable = 'lexiftool.PDF.Encrypt' },
    },
    _linearized = {
        Name = 'Linearized',
        Notes = 'flag set if document is linearized for fast web display; not a real Tag ID',
        PrintConv = { ['true'] = 'Yes', ['false'] = 'No' },
    },
}

-- tags in PDF Info dictionary
PDF.Info = {
    GROUPS = { [2] = 'Document' },
    VARS = { CAPTURE = { 'Info' } },
    EXTRACT_UNKNOWN = 1, -- extract all unknown tags in this directory
    WRITE_PROC = ExifTool.DummyWriteProc,
    CHECK_PROC = CheckPDF,
    WRITABLE = 'string',
    -- set PRIORITY to 0 so most recent Info dictionary takes precedence
    -- (Acrobat Pro bug? doesn't use same object/generation number for
    --  new Info dictionary when doing incremental update)
    PRIORITY = 0,
    NOTES = [[
        As well as the tags listed below, the PDF specification allows for
        user-defined tags to exist in the Info dictionary.  These tags, which should
        have corresponding XMP-pdfx entries in the XMP of the PDF XML Metadata
        object, are also extracted by ExifTool.

        B<Writable> specifies the value format, and may be C<string>, C<date>,
        C<integer>, C<real>, C<boolean> or C<name> for PDF tags.
    ]],
    Title       = { },
    Author      = { Groups = { [2] = 'Author' } },
    Subject     = { },
    Keywords    = {
        List = 'string',  -- this is a string list
        Notes = [[
            stored as a string but treated as a comma- or semicolon-separated list of
            items when reading if the string contains commas or semicolons, whichever is
            more numerous, otherwise it is treated a space-separated list of items.  The
            list behaviour may be defeated by setting the API NoPDFList option.  Written
            as a comma-separated string.  Note that the corresponding XMP-pdf:Keywords
            tag is not treated as a list, so the NoPDFList option should be used when
            copying between these two.
        ]],
    },
    Creator     = { },
    Producer    = { },
    CreationDate = {
        Name = 'CreateDate',
        Writable = 'date',
        PDF2 = 1,  -- not deprecated in PDF 2.0
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    ModDate = {
        Name = 'ModifyDate',
        Writable = 'date',
        PDF2 = 1,  -- not deprecated in PDF 2.0
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    SourceModified = {
        Name = 'SourceModified',
        Writable = 'date',
        PDF2 = 1,
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    Trapped = {
        Protected = 1,
        -- remove leading '/' from '/True' or '/False'
        ValueConv = function(_self, val) val = subst(val, '^/', '') return val end,
        ValueConvInv = function(_self, val) return '/' .. val end,
    },
    ['AAPL:Keywords'] = { --PH
        Name = 'AppleKeywords',
        List = 'array', -- this is an array of values
        Notes = [[
            keywords written by Apple utilities, although they seem to use PDF:Keywords
            when reading
        ]],
    },
}

-- tags in the PDF Root document catalog
PDF.Root = {
    GROUPS = { [2] = 'Document' },
    -- note: can't capture previous versions of Root since they are not parsed
    VARS = { CAPTURE = { 'Root' } },
    NOTES = 'This is the PDF document catalog.',
    MarkInfo = {
        SubDirectory = { TagTable = 'lexiftool.PDF.MarkInfo' },
    },
    Metadata = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Metadata' },
    },
    Pages = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Pages' },
    },
    Perms = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Perms' },
    },
    AcroForm = {
        SubDirectory = { TagTable = 'lexiftool.PDF.AcroForm' },
    },
    AF = {
        SubDirectory = { TagTable = 'lexiftool.PDF.AF' },
    },
    Lang       = 'Language',
    PageLayout = { },
    PageMode   = { },
    Version    = {
        Name = 'PDFVersion',
        RawConv = function(self, val) if perl.num(self.PDFVersion) < perl.num(val) then self.PDFVersion = val end return val end,
    },
}

-- tags extracted from the PDF Encrypt dictionary
PDF.Encrypt = {
    GROUPS = { [2] = 'Document' },
    NOTES = 'Tags extracted from the document Encrypt dictionary.',
    Filter = {
        Name = 'Encryption',
        Notes = [[
            extracted value is actually a combination of the Filter, SubFilter, V, R and
            Length information from the Encrypt dictionary
        ]],
    },
    P = {
        Name = 'UserAccess',
        ValueConv = function(_self, val) return int(val) & 0x0f3c end,  -- ignore reserved bits
        PrintConvColumns = 2,
        PrintConv = { BITMASK = {
            [2] = 'Print',
            [3] = 'Modify',
            [4] = 'Copy',
            [5] = 'Annotate',
            [8] = 'Fill forms',
            [9] = 'Extract',
            [10] = 'Assemble',
            [11] = 'Print high-res',
        }},
    },
}

-- tags in PDF Pages dictionary
PDF.Pages = {
    GROUPS = { [2] = 'Document' },
    Count = 'PageCount',
    Kids = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Kids' },
    },
    MediaBox = { Name = 'MediaBox', List = 1 },
}

-- tags in PDF Perms dictionary
PDF.Perms = {
    NOTES = 'Additional document permissions imposed by digital signatures.',
    DocMDP = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Signature' },
    },
    FieldMDP = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Signature' },
    },
    UR3 = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Signature' },
    },
}

-- tags in PDF Perms dictionary
PDF.AcroForm = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    _has_xfa = {
        Name = 'HasXFA',
        Notes = [[
            this tag is defined if a document contains form fields, and is true if it
            uses XML Forms Architecture; not a real Tag ID
        ]],
        PrintConv = { ['true'] = 'Yes', ['false'] = 'No' },
    },
}

-- tags extracted from AF dictionary
PDF.AF = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'Processed only for C2PA information if AFRelationship is "/C2PA_Manifest".',
    EF = {
        SubDirectory = { TagTable = 'lexiftool.PDF.EF' },
    },
}

-- tags extracted from EF dictionary
PDF.EF = {
    F = {
        Name = 'F_', -- (don't want single-letter tag names)
        SubDirectory = { TagTable = 'lexiftool.PDF.F' },
    },
}

-- tags extracted from F dictionary
PDF.F = {
    NOTES = 'C2PA JUMBF metadata extracted from "/C2PA_Manifest" file.',
    _stream = {
        Name = 'JUMBF',
        Condition = function(self) return self.AFRelationship == '/C2PA_Manifest' end,
        SubDirectory = {
            TagTable  = 'lexiftool.Jpeg2000.Main',
            DirName   = 'JUMBF',
            ByteOrder = 'BigEndian',
        },
    },
}

-- tags in PDF Kids dictionary
PDF.Kids = {
    Metadata = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Metadata' },
    },
    PieceInfo = {
        SubDirectory = { TagTable = 'lexiftool.PDF.PieceInfo' },
    },
    Resources = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Resources' },
    },
    Kids = {
        Condition = function(self) return self:Options('ExtractEmbedded') end,
        SubDirectory = { TagTable = 'lexiftool.PDF.Kids' },
    },
}

-- tags in PDF Resources dictionary
PDF.Resources = {
    ColorSpace = {
        SubDirectory = { TagTable = 'lexiftool.PDF.ColorSpace' },
    },
    XObject = {
        Condition = function(self) return self:Options('ExtractEmbedded') end,
        SubDirectory = { TagTable = 'lexiftool.PDF.XObject' },
    },
    Properties = {
        Condition = function(self) return self:Options('ExtractEmbedded') end,
        SubDirectory = { TagTable = 'lexiftool.PDF.Properties' },
    },
}

-- tags in PDF ColorSpace dictionary
PDF.ColorSpace = {
    DefaultRGB = {
        SubDirectory = { TagTable = 'lexiftool.PDF.DefaultRGB' },
        ConvertToDict = 1, -- (not seen yet, but just in case)
    },
    DefaultCMYK = {
        SubDirectory = { TagTable = 'lexiftool.PDF.DefaultRGB' },
        -- hack: this is stored as an array instead of a dictionary in my
        -- sample, so convert to a dictionary to extract the ICCBased element
        ConvertToDict = 1,
    },
    Cs1 = {
        SubDirectory = { TagTable = 'lexiftool.PDF.DefaultRGB' },
        ConvertToDict = 1, -- (just in case)
    },
    CS0 = {
        SubDirectory = { TagTable = 'lexiftool.PDF.DefaultRGB' },
        ConvertToDict = 1, -- (just in case)
    },
}

-- tags in PDF DefaultRGB dictionary
PDF.DefaultRGB = {
    ICCBased = {
        SubDirectory = { TagTable = 'lexiftool.PDF.ICCBased' },
    },
}

-- tags in PDF ICCBased, Cs1 and CS0 dictionaries
PDF.ICCBased = {
    _stream = {
        Name = 'ICC_Profile',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
}

-- tags in PDF XObject dictionary (parsed only if ExtractEmbedded is enabled)
PDF.XObject = {
    EXTRACT_UNKNOWN = 0,   -- extract known but numbered tags (Im1, Im2, etc)
    Im = {
        Notes = [[
            the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option enables information to be extracted from these
            embedded images
        ]],
        SubDirectory = { TagTable = 'lexiftool.PDF.Im' },
    },
}

-- tags in PDF Im# dictionary
PDF.Im = {
    NOTES = [[
        Information extracted from embedded images with the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option.
        The EmbeddedImage and its metadata are extracted only for JPEG and Jpeg2000
        image formats.
    ]],
    Width = 'EmbeddedImageWidth',
    Height = 'EmbeddedImageHeight',
    Filter = { Name = 'EmbeddedImageFilter', List = 1 },
    ColorSpace = {
        Name = 'EmbeddedImageColorSpace',
        List = 1,
        RawConv = function(_self, val) if type(val) == 'table' then return nil end return val end, -- (ignore color space data)
    },
    Image_stream = {
        Name = 'EmbeddedImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
}

-- tags in PDF Properties dictionary
PDF.Properties = {
    EXTRACT_UNKNOWN = 0,   -- extract known but numbered tags (MC0, MC1, etc)
    MC = {
        Notes = [[
            the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option enables information to be extracted from these
            embedded metadata dictionaries
        ]],
        SubDirectory = { TagTable = 'lexiftool.PDF.MC' },
    }
}

-- tags in PDF MC# dictionary
PDF.MC = {
    Metadata = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Metadata' },
    }
}

-- tags in PDF PieceInfo dictionary
PDF.PieceInfo = {
    AdobePhotoshop = {
        SubDirectory = { TagTable = 'lexiftool.PDF.AdobePhotoshop' },
    },
    Illustrator = {
        -- assume this is an illustrator file if it contains this directory
        -- and doesn't have a ".PDF" extension
        Condition = function(self)
            if not (self.FILE_EXT and self.FILE_EXT == 'PDF') then self:OverrideFileType('AI') end
            return 1
        end,
        SubDirectory = { TagTable = 'lexiftool.PDF.Illustrator' },
    },
}

-- tags in PDF AdobePhotoshop dictionary
PDF.AdobePhotoshop = {
    Private = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Private' },
    },
}

-- tags in PDF Illustrator dictionary
PDF.Illustrator = {
    Private = {
        SubDirectory = { TagTable = 'lexiftool.PDF.AIPrivate' },
    },
}

-- tags in PDF Private dictionary
PDF.Private = {
    ImageResources = {
        SubDirectory = { TagTable = 'lexiftool.PDF.ImageResources' },
    },
}

-- tags in PDF AI Private dictionary
PDF.AIPrivate = {
    GROUPS = { [2] = 'Document' },
    EXTRACT_UNKNOWN = 0,   -- extract known but numbered tags
    AIMetaData = {
        SubDirectory = { TagTable = 'lexiftool.PDF.AIMetaData' },
    },
    AIPrivateData = {
        Notes = [[
            the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option enables information to be extracted from embedded
            PostScript documents in the AIPrivateData# and AIPDFPrivateData# streams
        ]],
        JoinStreams = 1,   -- join streams from numbered tags and process as one
        SubDirectory = { TagTable = 'lexiftool.PostScript.Main' },
    },
    AIPDFPrivateData = {
        JoinStreams = 1,   -- join streams from numbered tags and process as one
        SubDirectory = { TagTable = 'lexiftool.PostScript.Main' },
    },
    RoundTripVersion = { },
    ContainerVersion = { },
    CreatorVersion = { },
}

-- tags in PDF AIMetaData dictionary
PDF.AIMetaData = {
    _stream = {
        Name = 'AIStream',
        SubDirectory = { TagTable = 'lexiftool.PostScript.Main' },
    },
}

-- tags in PDF ImageResources dictionary
PDF.ImageResources = {
    _stream = {
        Name = 'PhotoshopStream',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Main' },
    },
}

-- tags in PDF MarkInfo dictionary
PDF.MarkInfo = {
    GROUPS = { [2] = 'Document' },
    Marked = {
        Name = 'TaggedPDF',
        Notes = 'not a Tagged PDF if this tag is missing',
        PrintConv = { ['true'] = 'Yes', ['false'] = 'No' },
    },
}

-- tags in PDF Metadata dictionary
PDF.Metadata = {
    GROUPS = { [2] = 'Document' },
    XML_stream = { -- this is the stream for a Subtype /XML dictionary (not a real tag)
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

-- tags in PDF signature directories (DocMDP, FieldMDP or UR3)
PDF.Signature = {
    GROUPS = { [2] = 'Document' },
    ContactInfo = 'SignerContactInfo',
    Location = 'SigningLocation',
    M = {
        Name = 'SigningDate',
        Format = 'date',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Name     = 'SigningAuthority',
    Reason   = 'SigningReason',
    Reference = {
        SubDirectory = { TagTable = 'lexiftool.PDF.Reference' },
    },
    Prop_AuthTime = {
        Name = 'AuthenticationTime',
        PrintConv = function(_self, val) return ConvertTimeSpan(val) .. ' ago' end,
    },
    Prop_AuthType = 'AuthenticationType',
}

-- tags in PDF Reference dictionary
PDF.Reference = {
    TransformParams = {
        SubDirectory = { TagTable = 'lexiftool.PDF.TransformParams' },
    },
}

-- tags in PDF TransformParams dictionary
PDF.TransformParams = {
    GROUPS = { [2] = 'Document' },
    Annots = {
        Name = 'AnnotationUsageRights',
        Notes = [[
            possible values are Create, Delete, Modify, Copy, Import and Export;
            additional values for UR3 signatures are Online and SummaryView
        ]],
        List = 1,
    },
    Document = {
        Name = 'DocumentUsageRights',
        Notes = 'only possible value is FullSave',
        List = 1,
    },
    Form = {
        Name = 'FormUsageRights',
        Notes = [[
            possible values are FillIn, Import, Export, SubmitStandalone and
            SpawnTemplate; additional values for UR3 signatures are BarcodePlaintext and
            Online
        ]],
        List = 1,
    },
    FormEX = {
        Name = 'FormExtraUsageRights',
        Notes = 'UR signatures only; only possible value is BarcodePlaintext',
        List = 1,
    },
    Signature = {
        Name = 'SignatureUsageRights',
        Notes = 'only possible value is Modify',
        List = 1,
    },
    EF = {
        Name = 'EmbeddedFileUsageRights',
        Notes = 'possible values are Create, Delete, Modify and Import',
        List = 1,
    },
    Msg = 'UsageRightsMessage',
    P = {
        Name = 'ModificationPermissions',
        Notes = [[
            1-3 for DocMDP signatures, default 2; true/false for UR3 signatures, default
            false
        ]],
        PrintConv = {
            [1] = 'No changes permitted',
            [2] = 'Fill forms, Create page templates, Sign',
            [3] = 'Fill forms, Create page templates, Sign, Create/Delete/Edit annotations',
            ['true'] = 'Restrict all applications to reader permissions',
            ['false'] = 'Do not restrict applications to reader permissions',
        },
    },
    Action = {
        Name = 'FieldPermissions',
        Notes = 'FieldMDP signatures only',
        PrintConv = {
            ['All'] = 'Disallow changes to all form fields',
            ['Include'] = 'Disallow changes to specified form fields',
            ['Exclude'] = 'Allow changes to specified form fields',
        },
    },
    Fields = {
        Notes = 'FieldMDP signatures only',
        Name = 'FormFields',
        List = 1,
    },
}

-- unknown tags for use in verbose option
PDF.Unknown = {
    GROUPS = { [2] = 'Unknown' },
}

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WritePDF.pl -- its subs are bound to
--  loader closures at their predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Convert from PDF to EXIF-style date/time
-- Inputs: 0) PDF date/time string (D:YYYYmmddHHMMSS+HH'MM')
-- Returns: EXIF date string (YYYY:mm:dd HH:MM:SS+HH:MM)
local function ConvertPDFDate(date)
    -- remove optional 'D:' prefix
    date = subst(date, '^D:', '')
    -- fill in default values if necessary
    --              YYYYmmddHHMMSS
    local default = '00000101000000'
    if length(date) < length(default) then
        date = date .. substr(default, length(date))
    end
    local c1, c2, c3, c4, c5, c6, c7 = matches(date, [[^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(.*)]])
    if not c1 then return date end
    date = c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4 .. ':' .. c5 .. ':' .. c6
    if truthy(c7) then
        local tz = c7
        if isMatch(tz, [[(?i)^\s*Z]]) then
            -- ignore any "HH'mm'" after the Z (OS X 10.6 does this)
            date = date .. 'Z'
        -- tolerate some improper formatting in timezone specification
        else
            local d1, d2, d3 = matches(tz, [[^\s*([-+])\s*(\d+)[': ]+(\d*)]])
            if d1 then
                date = date .. d1 .. d2 .. ':' .. (truthy(d3) and d3 or '00')
            end
        end
    end
    return date
end

--------------------------------------------------------------------------------
-- Locate any object in the XRef tables (including compressed objects)
-- Inputs: 0) XRef reference, 1) object reference string (or free object number)
-- Returns: offset to object in file or compressed object reference string,
--          0 if object is free, or undefined on error
local function LocateAnyObject(xref, ref_)
    if not xref then return nil end
    if xref[ref_] ~= nil then return xref[ref_] or nil end -- (false: entry exists but is undef)
    -- get the object number
    local objNum = matches(ref_, [[^(\d+)]])
    if not objNum then return nil end
    objNum = tonumber(objNum)   -- (%xref keys object numbers as integers)
    -- return 0 if the object number has been reused (old object is free)
    if xref[objNum] ~= nil then return 0 end
--
-- scan our XRef stream dictionaries for this object
--
    if not xref.dicts then return nil end
    for _, dict in ipairs(xref.dicts) do
        -- quick check to see if the object is in the range for this xref stream
        if objNum >= perl.num(dict.Size) then goto continue end
        local index = dict.Index
        if objNum < perl.num(index[1]) then goto continue end
        -- scan the tables for the specified object
        local size = dict._entry_size
        local num = #index / 2
        local tot = 0
        local i = 0
        while i < num do
            local start = perl.num(index[i*2 + 1])
            local count = perl.num(index[i*2 + 2])
            -- table is in ascending order, so quit if we have passed the object
            if objNum < start then break end
            if objNum < start + count then
                local offset = size * (objNum - start + tot)
                if offset + size > length(dict._stream) then break end
                local c = { unpack('x' .. offset .. ' C' .. size, dict._stream) }
                -- extract values from this table entry
                -- (can be 1, 2, 3, 4, etc.. bytes per value)
                local t = {}
                local w = dict.W
                for j = 0, 2 do
                    -- use default value if W entry is 0 (as per spec)
                    -- - 0th element defaults to 1, others default to 0
                    if not truthy(w[j + 1]) then
                        t[j] = (j ~= 0 and 0 or 1)
                    else
                        t[j] = table.remove(c, 1)
                        for _ = 1, perl.num(w[j + 1]) - 1 do
                            t[j] = 256 * t[j] + table.remove(c, 1)
                        end
                    end
                end
                -- by default, use "o g R" as the xref key
                -- (o = object number, g = generation number)
                local ref2 = objNum .. ' ' .. t[2] .. ' R'
                if t[0] == 1 then
                    -- normal object reference:
                    -- $t[1]=offset of object from start, $t[2]=generation number
                    xref[ref2] = t[1]
                elseif t[0] == 2 then
                    -- compressed object reference:
                    -- $t[1]=stream object number, $t[2]=index of object in stream
                    ref2 = objNum .. ' 0 R'
                    xref[ref2] = 'I' .. t[2] .. ' ' .. t[1] .. ' 0 R'
                elseif t[0] == 0 then
                    -- free object:
                    -- $t[1]=next free object in linked list, $t[2]=generation number
                    xref[ref2] = 0
                else
                    -- treat as a null object
                    xref[ref2] = false
                end
                xref[objNum] = t[1]    -- remember offsets by object number too
                if ref_ == ref2 then return xref[ref_] or nil end
                return 0   -- object is free or was reused
            end
            tot = tot + count
            i = i + 1
        end
        ::continue::
    end
    return nil
end

--------------------------------------------------------------------------------
-- Locate a regular object in the XRef tables (does not include compressed objects)
-- Inputs: 0) XRef reference, 1) object reference string (or free object number)
-- Returns: offset to object in file, 0 if object is free,
--          or undef on error or if object was compressed
local function LocateObject(xref, ref_)
    local offset = LocateAnyObject(xref, ref_)
    if truthy(offset) and isMatch(offset, '^I') then return nil end
    return offset
end

--------------------------------------------------------------------------------
-- Check that the correct object is located at the specified file offset
-- Inputs: 0) ExifTool ref, 1) object name, 2) object reference string, 3) file offset
-- Returns: first non-blank line at start of object, or undef on error
local function CheckObject(et, tag, ref_, offset)
    local data, obj, dat, pat
    local nRead

    local raf = et.RAF
    if not raf:Seek(offset + et.PDFBase, 0) then et:Warn('Bad ' .. tag .. ' offset') return nil end
    -- verify that we are reading the expected object
    obj = subst(ref_, 'R', 'obj')
    while true do
        nRead, data = raf:ReadLine(RS)
        if nRead == 0 then et:Warn('Error reading ' .. tag .. ' data') return nil end
        if isMatchDyn(data, '^' .. obj) then
            data = perl.substDyn(data, '^' .. obj, '')
            break
        end
        if not isMatch(data, [[^\s+$]]) then    -- keep reading if this was a blank line
            -- handle cases where other whitespace characters are used in the object ID string
            while isMatch(data, [[^\d+(\s+\d+)?\s*$]]) do
                dat = select(2, raf:ReadLine(RS))
                data = data .. dat
            end
            pat = subst(obj, ' ', [[\\s+]], 'g')
            if not isMatchDyn(data, pat) then
                tag = ucfirst(tag)
                et:Warn(tag .. ' object (' .. obj .. ') not found at offset ' .. offset)
                return nil
            end
            data = perl.substDyn(data, pat, '')
            break
        end
    end
    -- read the first line of data from the object (ignoring blank lines and comments)
    while true do
        if isMatch(data, [[\S]]) and not isMatch(data, [[^\s*%]]) then break end
        nRead, data = raf:ReadLine(RS)
        if nRead == 0 then et:Warn('Error reading ' .. tag .. ' data') return nil end
    end
    return data
end

--------------------------------------------------------------------------------
-- Fetch indirect object from file (from inside a stream if required)
-- Inputs: 0) ExifTool object reference, 1) object reference string,
--         2) xref lookup, 3) object name (for warning messages)
-- Returns: object data or undefined on error
-- Notes: sets $lastFetched to the object reference, or undef if the object
--        was extracted from an encrypted stream
function FetchObject(et, ref_, xref, tag)
    PDF.lastFetched = ref_    -- save this for decoding if necessary
    local offset = LocateAnyObject(xref, ref_)
    lastOffset = offset
    if not truthy(offset) then
        if offset == nil then et:Warn('Bad ' .. tag .. ' reference') end
        return nil
    end
    local data, obj
    local index = matches(offset, [[^I(\d+) ]])
    if index then
        offset = subst(offset, [[^I(\d+) ]], '')
        index = tonumber(index) -- object index in stream
        local objNum = split(' ', ref_)[1] -- save original object number
        ref_ = offset -- now a reference to the containing stream object
        obj = streamObjs[ref_]
        if not truthy(obj) then
            -- don't try to load the same object stream twice
            if obj ~= nil then return nil end
            streamObjs[ref_] = ''
            -- load the parent object stream
            obj = FetchObject(et, ref_, xref, tag)
            -- make sure it contains everything we need
            if not (obj ~= nil and ref(obj) == 'HASH') then return nil end
            if not (truthy(obj.First) and truthy(obj.N)) then return nil end
            if not truthy(DecodeStream(et, obj)) then return nil end
            -- add a special '_table' entry to this dictionary which contains
            -- the list of object number/offset pairs from the stream header
            local num = perl.num(obj.N) * 2
            local table_ = split(' ', obj._stream, num)
            if #table_ ~= num then return nil end
            -- remove everything before first object in stream
            obj._stream = substr(obj._stream, perl.num(obj.First))
            table_[num] = subst(table_[num], [[(?s)^(\d+).*]], '$1') -- trim excess from last number
            obj._table = table_
            -- save the object stream so we don't have to re-load it later
            streamObjs[ref_] = obj
        end
        -- verify that we have the specified object
        local i = 2 * index
        local table_ = obj._table
        if not (index < perl.num(obj.N) and perl.num(table_[i + 1]) == perl.num(objNum)) then
            et:Warn('Bad index for stream object ' .. tag)
            return nil
        end
        -- extract the object at the specified index in the stream
        -- (offsets in table are in sequential order, so we can subtract from
        --  the next offset to get the object length)
        offset = perl.num(table_[i + 2])
        local len = (truthy(table_[i + 4]) and perl.num(table_[i + 4]) or length(obj._stream)) - offset
        data = substr(obj._stream, offset, len)
        -- avoid re-decrypting data in already decrypted streams
        if truthy(cryptStream) then PDF.lastFetched = nil end
        return ExtractObject(et, { value = carray.new('char'):append(data) })
    end
    -- load the start of the object
    data = CheckObject(et, tag, ref_, offset)
    if data == nil then return nil end

    return ExtractObject(et, { value = carray.new('char'):append(data) }, et.RAF, xref)
end

--------------------------------------------------------------------------------
-- Convert PDF value to something readable
-- Inputs: 0) PDF object data
-- Returns: converted object
function ReadPDFValue(str)
    -- decode all strings in an array
    if ref(str) == 'ARRAY' then
        -- create new list to not alter the original data when rewriting
        local vals = {}
        for _, val in ipairs(str) do
            vals[#vals + 1] = ReadPDFValue(val)
        end
        return vals
    end
    -- (a dictionary or reference stringifies in Perl, so it starts with no
    --  delimiter and comes back unchanged)
    if type(str) == 'table' then return str end
    if not truthy(length(str)) then return str end
    local delim = substr(str, 0, 1)
    if delim == '(' then    -- literal string
        local c1 = matches(str, [[(?s)^.*?\((.*)\)]])
        if c1 then str = c1 end   -- remove brackets
        -- decode escape sequences in literal strings
        local pos = 0
        while true do
            local c, en = matches(str, [[(?s)\\(.)]], pos)
            if not c then break end
            local n = en - 2
            local r
            if isMatch(c, '[0-7]') then
                -- get up to 2 more octal digits
                local d = matches(str, [[\G([0-7]{1,2})]], en)
                if d then c = c .. d end
                -- convert octal escape code
                r = chr(tonumber(c, 8) & 0xff)
            elseif c == "\x0d" then
                -- the string is continued if the line ends with '\'
                -- (also remove "\x0d\x0a")
                local d = matches(str, [[\G(\x0a)]], en)
                if d then c = c .. d end
                r = ''
            elseif c == "\x0a" then
                r = ''
            else
                -- convert escaped characters
                r = tr(c, 'nrtbf', [[\n\r\t\b\f]])
            end
            str = substr(str, 0, n) .. r .. substr(str, n + length(c) + 1)
            -- continue search after this character
            pos = n + length(r)
        end
        if truthy(cryptString) then str = Crypt(str, PDF.lastFetched) end
    elseif delim == '<' then   -- hex string
        -- decode hex data
        str = tr(str, '0-9A-Fa-f', '', 'dc')
        if (length(str) & 0x01) ~= 0 then str = str .. '0' end -- (by the spec)
        str = pack('H*', str)
        if truthy(cryptString) then str = Crypt(str, PDF.lastFetched) end
    elseif delim == '/' then   -- name
        str = substr(str, 1)
        -- convert escape codes (PDF 1.2 or later)
        if perl.num(pdfVer) >= 1.2 then
            str = subst(str, [[(?si)#([0-9a-f]{2})]], function(h) return chr(hex(h)) end, 'g')
        end
    end
    return str
end

--------------------------------------------------------------------------------
-- Extract PDF object from combination of buffered data and file
-- Inputs: 0) ExifTool object reference, 1) data reference,
--         2) optional raf reference, 3) optional xref table
-- Returns: converted PDF object or undef on error
--          a) dictionary object --> hash reference
--          b) array object --> array reference
--          c) indirect reference --> scalar reference
--          d) string, name, integer, boolean, null --> scalar value
-- - updates $$dataPt on return to contain unused data
-- - creates two bogus entries ('_stream' and '_tags') in dictionaries to represent
--   the stream data and a list of the tags (not including '_stream' and '_tags')
--   in their original order
function ExtractObject(et, dataPt, raf, xref)
    local tags, data, objData = {}
    local dict = { }
    local delim
    local nRead

    while true do
        local c1 = matches(dataPt.value, [[(?s)^\s*(<{1,2}|\[|\()]])
        if c1 then
            delim = c1
            dataPt.value = subst(dataPt.value, [[^\s+]], '')   -- remove leading white space
            objData = ReadToNested(dataPt, raf)
            if objData == nil then return nil end
            break
        end
        local c2, en = matches(dataPt.value, [[(?s)^\s*(\S[^[(/<>\s]*)\s*]])
        if c2 then
            substr(dataPt.value, 0, en, '')
--
-- extract boolean, numerical, string, name, null object or indirect reference
--
            objData = c2
            -- look for an indirect reference
            if isMatch(objData, [[^\d+$]]) then
                local d, en2 = matches(dataPt.value, [[(?s)^(\d+)\s+R]])
                if d then
                    substr(dataPt.value, 0, en2, '')
                    objData = objData .. d .. ' R'
                    objData = { ref = 'SCALAR', value = objData }   -- return scalar reference
                end
            end
            return objData    -- return simple scalar or scalar reference
        end
        if not raf then return nil end
        nRead, data = raf:ReadLine(RS)
        if nRead == 0 then return nil end
        dataPt.value:append(data)
    end
--
-- return literal string or hex string without parsing
--
    if delim == '(' or delim == '<' then
        return objData
--
-- extract array
--
    elseif delim == '[' then
        local data_ = matches(objData, [=[(?s)^.*?\[(.*)\]]=])
        if not data_ then return nil end
        data = data_    -- brackets removed
        local list = {}
        local pos = 0
        while true do
            local val, en = matches(data, [[(?s)\s*(\S[^[(/<>\s]*)]], pos)
            if not val then break end
            pos = en
            if isMatch(val, [[^(<{1,2}|\[|\()]]) then
                local pos2 = pos - length(val)
                -- nested dict, array, literal string or hex string
                local buff = { value = carray.new('char'):append(substr(data, pos2)) }
                val = ReadToNested(buff)
                if val == nil then break end
                pos = pos2 + length(val)
                val = ExtractObject(et, { value = carray.new('char'):append(val) })
            elseif isMatch(val, [[^\d]]) then
                local d, en2 = matches(data, [[(?s)\G\s+(\d+)\s+R]], pos)
                if d then
                    val = { ref = 'SCALAR', value = val .. ' ' .. d .. ' R' }   -- make a reference
                    pos = en2
                end
            end
            list[#list + 1] = val
        end
        return list
    end
--
-- extract dictionary
--
    -- Note: entries are not necessarily separated by whitespace (doh!)
    -- eg) "/Tag/Name", "/Tag(string)", "/Tag[array]", etc are legal!
    -- Also, they may be separated by a comment (eg. "/Tag%comment\nValue"),
    -- but comments have already been removed
    local pos = 0
    while true do
        local _, tag, val, en = matches(objData, [[(?s)(\s*)/([^/[\]()<>{}\s]+)\s*(\S[^[(/<>\s]*)]], pos)
        if not tag then break end
        pos = en
        if isMatch(val, [[^(<{1,2}|\[|\()]]) then
            -- nested dict, array, literal string or hex string
            local objDataPt = { value = carray.new('char'):append(substr(objData, pos - length(val))) }
            val = ReadToNested(objDataPt, raf)
            objData = objDataPt.value:tostring()   -- (matched with pos() below)
            if val == nil then break end
            val = ExtractObject(et, { value = carray.new('char'):append(val) })
            pos = 0
        elseif isMatch(val, [[^\d]]) then
            local d, en2 = matches(objData, [[(?s)\G\s+(\d+)\s+R]], pos)
            if d then
                val = { ref = 'SCALAR', value = val .. ' ' .. d .. ' R' }   -- make a reference
                pos = en2
            end
        end
        if truthy(dict[tag]) then
            -- duplicate dictionary entries are not allowed
            et:Warn("Duplicate '" .. tag .. "' entry in dictionary (ignored)")
        else
            -- save the entry
            tags[#tags + 1] = tag
            dict[tag] = val
        end
    end
    if #tags == 0 then return nil end
    dict._tags = tags
    if not raf then return dict end   -- direct objects can not have streams
--
-- extract the stream object
--
    -- dictionary must specify stream Length
    local length_ = dict.Length
    if not truthy(length_) then return dict end
    if ref(length_) ~= '' then
        length_ = length_.value
        local oldpos = raf:Tell()
        -- get the location of the object specifying the length
        -- (compressed objects are not allowed)
        local offset = LocateObject(xref, length_)
        if not truthy(offset) then return dict end
        if not truthy(offset) then et:Warn('Bad stream Length object') return dict end
        data = CheckObject(et, 'stream Length', length_, offset)
        if data == nil then return dict end
        local c = matches(data, [[^\s*(\d+)]])
        if not c then et:Warn('Stream Length not found') return dict end
        length_ = c
        raf:Seek(oldpos, 0) -- restore position to start of stream
    end
    length_ = perl.num(length_)
    -- extract the trailing stream data
    while true do
        -- find the stream token
        local c = matches(dataPt.value, [[(\S+)]])
        if c then
            if c ~= 'stream' then break end
            -- read an extra line because it may contain our \x0a
            nRead, data = raf:ReadLine(RS)
            if nRead ~= 0 then dataPt.value:append(data) end
            -- remove our stream header
            dataPt.value = subst(dataPt.value, [[(?s)^\s*stream(\x0a|\x0d\x0a)]], '')
            local more = length_ - length(dataPt.value)
            if more > 0 then
                nRead, data = raf:Read(more)
                if nRead ~= more then
                    et:Warn('Error reading stream data')
                    dataPt.value = carray.new('char')
                    return dict
                end
                dict._stream = dataPt.value:tostring() .. data
                dataPt.value = carray.new('char')
            elseif more < 0 then
                dict._stream = substr(dataPt.value, 0, length_)
                substr(dataPt.value, 0, length_, '')
            else
                dict._stream = dataPt.value:tostring()
                dataPt.value = carray.new('char')
            end
            break
        end
        nRead, data = raf:ReadLine(RS)
        if nRead == 0 then break end
        dataPt.value:append(data)
    end
    return dict
end

--------------------------------------------------------------------------------
-- Read to nested delimiter
-- Inputs: 0) data reference, 1) optional raf reference
-- Returns: data up to and including matching delimiter (or undef on error)
-- - updates data reference with trailing data
-- - unescapes characters in literal strings
local closingDelim = {    -- lookup for matching delimiter
    ['('] = ')',
    ['['] = ']',
    ['<'] = '>',
   ['<<'] = '>>',
}
function ReadToNested(dataPt, raf)
    local delim = { '' }   -- closing delimiter list, most deeply nested first
    local pos = 0          -- begin at start of data
    while true do
        local c1, c2, en = matches(dataPt.value, [[(\\*)(\(|\)|<{1,2}|>{1,2}|\[|\]|%)]], pos)
        if not c1 then
            -- must read some more data
            if not raf then break end
            local nRead, buff = raf:ReadLine(RS)
            if nRead == 0 then break end
            dataPt.value:append(buff)
            pos = length(dataPt.value) - length(buff)
            goto continue
        end
        pos = en
        -- are we in a literal string?
        if delim[1] == ')' then
            -- ignore escaped delimiters (preceded by odd number of \'s)
            if (length(c1) & 0x01) ~= 0 then goto continue end
            -- ignore all delimiters but unescaped braces
            if not (c2 == '(' or c2 == ')') then goto continue end
        elseif c2 == '%' then
            -- ignore the comment
            local pos2 = pos - 1
            -- remove everything from '%' up to but not including newline
            local _, end_ = matches(dataPt.value, '.*', pos)
            substr(dataPt.value, pos2, end_ - pos2, '')
            pos = pos2
            goto continue
        end
        if closingDelim[c2] then
            -- push the corresponding closing delimiter
            table.insert(delim, 1, closingDelim[c2])
            goto continue
        end
        if c2 ~= delim[1] then
            -- handle the case where we find a ">>>" and interpret it
            -- as ">> >" instead of "> >>"
            if not (c2 == '>>' and delim[1] == '>') then goto continue end
            pos = pos - 1
        end
        table.remove(delim, 1)              -- remove from nesting list
        if truthy(delim[1]) then goto continue end -- keep going if we have more nested delimiters
        do
            local buff = substr(dataPt.value, 0, pos)
            substr(dataPt.value, 0, pos, '')
            return buff   -- success!
        end
        ::continue::
    end
    return nil   -- didn't find matching delimiter
end

--------------------------------------------------------------------------------
-- Decode LZW-encoded data (ref 1)
-- Inputs: 0) data reference
-- Returns: true on success and data is decoded, or false and data is untouched
local function DecodeLZW(dataPt)
    if length(dataPt.value) < 4 then return 0 end
    local lzw = {}   -- LZW code table
    for i = 0, 255 do lzw[i] = chr(i) end
    local nlzw = 258 -- (scalar @lzw: map(chr, 0..255), undef, undef)
    local mask = 0x01ff  -- mask for least-significant 9 bits
    local dat = { unpack('n*', dataPt.value:tostring() .. "\0") }
    local word = (dat[1] << 16) | dat[2]
    local bit, pos, bits, out = 0, 2, 9, {}
    local lastVal
    while true do
        -- bits are packed MSB first in PDF LZW (the PDF spec doesn't mention this)
        local shift = 32 - (bit + bits)
        if shift < 0 then
            if pos >= #dat then return 0 end -- missing EOD marker
            word = ((word & 0xffff) << 16) | dat[pos + 1] -- read next word
            pos = pos + 1
            bit = bit - 16
            shift = shift + 16
        end
        local code = (word >> shift) & mask
        bit = bit + bits
        local val = lzw[code]
        if val ~= nil then
            -- store new code as previous sequence plus 1st char of new sequence
            if lastVal ~= nil then
                lzw[nlzw] = lastVal .. substr(val, 0, 1)
                nlzw = nlzw + 1
            end
        elseif code == nlzw then -- new code
            if lastVal == nil then return 0 end
            -- we are using the code that we are about to generate, so the last
            -- character in the new sequence must be the same as the first
            -- character in the previous sequence (makes sense if you think about it)
            val = lastVal .. substr(lastVal, 0, 1)
            lzw[nlzw] = val
            nlzw = nlzw + 1
        elseif code == 256 then -- clear table
            for i = 258, nlzw - 1 do lzw[i] = nil end
            nlzw = 258
            bits = 9
            mask = 0x1ff
            lastVal = nil
            goto continue
        elseif code == 257 then -- EOD marker
            break   -- all done!
        else
            return 0
        end
        out[#out + 1] = val   -- add this byte sequence to the output
        -- we added a new entry to the LZW table, so we must increase
        -- the bit width if necessary, up to a maximum of 12
        if nlzw >= mask and bits < 12 then
            bits = bits + 1
            mask = mask | (mask << 1)
        end
        lastVal = val
        ::continue::
    end
    dataPt.value = carray.new('char'):append(table.concat(out))    -- return decompressed data
    return 1
end

--------------------------------------------------------------------------------
-- Decode filtered stream
-- Inputs: 0) ExifTool object reference, 1) dictionary reference
-- Returns: true if stream has been decoded OK
function DecodeStream(et, dict)
    if not truthy(dict._stream) then return 0 end -- no stream to decode

    -- get list of filters
    local filters, decodeParms_ = {}
    if ref(dict.Filter) == 'ARRAY' then
        filters = { table.unpack(dict.Filter) }
    elseif dict.Filter ~= nil then
        filters = { dict.Filter }
    end
    -- be sure we can process all the filters before we take the time to do the decryption
    for _, filter in ipairs(filters) do
        if not supportedFilter[filter] then
            et:Warn('Unsupported Filter ' .. perl.str(filter))
            return 0
        end
    end
    -- apply decryption first if required (and if the default encryption
    -- has not been overridden by a Crypt filter. Note: the Crypt filter
    -- must be first in the Filter array: ref 3, page 38)
    if not (dict._decrypted ~= nil or (truthy(filters[1]) and filters[1] == '/Crypt')) then
        CryptStream(dict, PDF.lastFetched)
    end
    if not truthy(dict.Filter) then return 1 end   -- Filter entry is mandatory
    if dict._filtered ~= nil then return 0 end     -- avoid double-filtering
    dict._filtered = 1                             -- set flag to prevent double-filtering

    -- get array of DecodeParms dictionaries
    if ref(dict.DecodeParms) == 'ARRAY' then
        decodeParms_ = { table.unpack(dict.DecodeParms) }
    else
        decodeParms_ = { dict.DecodeParms }
    end

    for i, filter in ipairs(filters) do
        local decodeParms = decodeParms_[i]

        if filter == '/FlateDecode' then
            -- make sure we support the predictor (if used) before decoding
            local pre
            if ref(decodeParms) == 'HASH' then
                pre = decodeParms.Predictor
                if truthy(pre) and pre ~= '1' and pre ~= '12' then
                    et:Warn('FlateDecode Predictor ' .. perl.str(pre) .. ' currently not supported')
                    return 0
                end
            end
            if et:hasZlib() then   -- (`eval { require Compress::Zlib }`)
                local buff, stat = et:inflate(dict._stream)
                if stat then   -- (Z_STREAM_END)
                    dict._stream = buff
                else
                    et:Warn('Error inflating stream')
                    return 0
                end
            else
                et:Warn('Install Compress::Zlib to process filtered streams')
                return 0
            end
            if not (truthy(pre) and pre == '12') then goto continue end  -- 12 = 'up' prediction

            -- apply anti-predictor
            local cols = decodeParms.Columns
            if not truthy(cols) then
                -- currently only support 'up' prediction
                et:Warn('No Columns for decoding stream')
                return 0
            end
            cols = perl.num(cols)
            local bytes = { unpack('C*', dict._stream) }
            local pre_ = {}   -- initialize predictor array
            for k = 1, cols do pre_[k] = 0 end
            local buff = {}
            local b = 1       -- (next byte: upstream shifts @bytes)
            while #bytes - b + 1 > cols do
                local v = bytes[b]
                b = b + 1
                if v ~= 2 then
                    et:Warn('Unsupported PNG filter ' .. v) -- (yes, PNG)
                    return 0
                end
                for k = 1, cols do
                    pre_[k] = (pre_[k] + bytes[b]) & 0xff
                    b = b + 1
                end
                buff[#buff + 1] = pack('C*', table.unpack(pre_))
            end
            dict._stream = table.concat(buff)

        elseif filter == '/Crypt' then

            -- (we shouldn't have to check the _decrypted flag since we
            --  already checked the _filtered flag, but what the heck...)
            if dict._decrypted ~= nil then goto continue end
            -- assume Identity filter (the default) if DecodeParms are missing
            if ref(decodeParms) ~= 'HASH' then goto continue end
            local name = decodeParms.Name
            if not (name ~= nil or name == 'Identity') then goto continue end
            if name ~= 'StdCF' then
                et:Warn('Unsupported Crypt Filter ' .. perl.str(name))
                return 0
            end
            if not cryptInfo then
                et:Warn('Missing Encrypt StdCF entry')
                return 0
            end
            -- decrypt the stream manually because we want to:
            -- 1) ignore $cryptStream (StmF) setting
            -- 2) ignore EncryptMetadata setting (I can't find mention of how to
            --    reconcile this in the spec., but this would make sense)
            -- 3) avoid adding the crypt key extension (ref 3, page 58, Algorithm 1b)
            -- 4) set _decrypted flag so we will recrypt according to StmF when
            --    writing (since we don't yet write Filter'd streams)
            dict._stream = Crypt(dict._stream, 'none')
            dict._decrypted = (truthy(cryptStream) and 1 or 0)

        elseif filter == '/LZWDecode' then

            -- make sure we don't have any unsupported decoding parameters
            if ref(decodeParms) == 'HASH' then
                if truthy(decodeParms.Predictor) then
                    et:Warn('LZWDecode Predictor ' .. perl.str(decodeParms.Predictor) .. ' currently not supported')
                    return 0
                elseif truthy(decodeParms.EarlyChange) then
                    et:Warn('LZWDecode EarlyChange currently not supported')
                    return 0
                end
            end
            local streamPt = { value = carray.new('char'):append(dict._stream) }
            if not truthy(DecodeLZW(streamPt)) then
                et:Warn('LZW decompress error')
                return 0
            end
            dict._stream = streamPt.value:tostring()

        elseif filter == '/ASCIIHexDecode' then

            dict._stream = subst(dict._stream, '>.*', '')   -- truncate at '>' (end of data mark)
            dict._stream = tr(dict._stream, '0-9a-zA-Z', '', 'd') -- remove illegal characters
            dict._stream = pack('H*', dict._stream)

        elseif filter == '/ASCII85Decode' then

            local err, out = nil, {}
            local n, val = 0, 0
            for _, c in ipairs(split('', dict._stream)) do
                if not perl.lt(c, '!') and not perl.lt('u', c) then
                    val = 85 * val + ord(c) - 33
                    n = n + 1
                    if n ~= 5 then goto nextChar end
                elseif c == '~' then
                    if n == 1 then err = 1 end   -- error to have a single char in the last group of 5
                    for _ = n, 4 do val = val * 85 end
                elseif c == 'z' then
                    if n ~= 0 then err = 2 break end -- error if 'z' isn't the first char
                    n = 5
                else
                    if isMatch(c, [[^\s$]]) then goto nextChar end -- ignore white space
                    err = 3 break                    -- any other character is an error
                end
                val = unpack('V', pack('N', val)) -- reverse byte order
                n = n - 1
                while n > 0 do
                    out[#out + 1] = chr(val & 0xff)
                    val = val >> 8
                    n = n - 1
                end
                if c == '~' then break end
                -- (both $n and $val are zero again now)
                ::nextChar::
            end
            if err then et:Warn('ASCII85Decode error ' .. err) end
            dict._stream = table.concat(out)
        end
        ::continue::
    end
    return 1
end

--------------------------------------------------------------------------------
-- Initialize state for RC4 en/decryption (ref 2)
-- Inputs: 0) RC4 key string
-- Returns: RC4 key hash reference
local function RC4Init(keyStr)
    local key = { unpack('C*', keyStr) }
    local state = {}
    for k = 0, 255 do state[k] = k end
    local i, j = 0, 0
    while i < 256 do
        local st = state[i]
        j = (j + st + key[i % #key + 1]) & 0xff
        state[i] = state[j]
        i = i + 1
        state[j] = st
    end
    return { State = state, XY = { 0, 0 } }
end

--------------------------------------------------------------------------------
-- Apply RC4 en/decryption (ref 2)
-- Inputs: 0) data reference, 1) RC4 key hash reference or RC4 key string
-- - can call this method directly with a key string, or with with the key
--   reference returned by RC4Init
-- - RC4 is a symmetric algorithm, so encryption is the same as decryption
-- (returns the en/decrypted data, see the port notes)
local function RC4Crypt(data, key)
    if type(key) ~= 'table' then key = RC4Init(key) end
    local state = key.State
    local x, y = key.XY[1], key.XY[2]

    local data_ = { unpack('C*', data) }
    for k, v in ipairs(data_) do
         x = (x + 1) & 0xff
         local stx = state[x]
         y = (stx + y) & 0xff
         state[x] = state[y]
         local sty = state[x]
         state[y] = stx
         data_[k] = chr(v ~ state[(stx + sty) & 0xff])
     end
     key.XY = { x, y }
     return table.concat(data_)
end

--------------------------------------------------------------------------------
-- Update AES cipher with a bit of data
-- Inputs: 0) data
-- Returns: encrypted data
local cipherMore
local function CipherUpdate(dat)
    local pos = 0
    if truthy(length(dat)) then dat = cipherMore .. dat end
    while pos + 16 <= length(dat) do
        dat = substr(dat, 0, pos) .. require('lexiftool.AES').Cipher(substr(dat, pos, 16)) .. substr(dat, pos + 16)
        pos = pos + 16
    end
    if pos < length(dat) then
        cipherMore = substr(dat, pos)
        dat = substr(dat, 0, pos)
    else
        cipherMore = ''
    end
    return dat
end

--------------------------------------------------------------------------------
-- Get encrypted hash
-- Inputs: 0) Password, 1) salt, 2) vector, 3) encryption revision
-- Returns: hash
local function GetHash(password, salt, vector, rev)

    -- return Rev 5 hash
    if perl.num(rev) == 5 then return ExifTool.sha256(nil, password .. salt .. vector) end

    -- compute Rev 6 hardened hash
    -- (ref http://code.google.com/p/origami-pdf/source/browse/lib/origami/encryption.rb)
    local blockSize = 32
    local input = ExifTool.sha256(nil, password .. salt .. vector) .. ("\0"):rep(32)
    local key = substr(input, 0, 16)
    local iv = substr(input, 16, 16)
    local h
    local x = ''
    local i = 0
    while i < 64 or i < ord(substr(x, -1, 1)) + 32 do

        local block = substr(input, 0, blockSize)
        x = ''
        x = require('lexiftool.AES').Crypt(x, key, iv, 1)
        cipherMore = ''

        local digest
        for j = 0, 63 do
            x = ''
            if truthy(length(password)) then x = x .. CipherUpdate(password) end
            x = x .. CipherUpdate(block)
            if truthy(length(vector)) then x = x .. CipherUpdate(vector) end
            if j == 0 then
                local a = { unpack('C16', x) }
                local sum = 0
                for _, v in ipairs(a) do sum = sum + v end
                -- set SHA block size (32, 48 or 64 bytes = SHA-256, 384 or 512)
                blockSize = 32 + (sum % 3) * 16
                digest = ExifTool.DigestSHA(blockSize * 8)
            end
            digest:add(x)
        end

        h = digest:digest()
        key = substr(h, 0, 16)
        input = h .. substr(input, 16)
        iv = substr(h, 16, 16)
        i = i + 1
    end
    return substr(h, 0, 32)
end

--------------------------------------------------------------------------------
-- Initialize decryption
-- Inputs: 0) ExifTool object reference, 1) Encrypt dictionary reference,
--         2) ID from file trailer dictionary
-- Returns: error string or undef on success (and sets $cryptInfo)
local function DecryptInit(et, encrypt, id)
    cryptInfo = nil
    if not (truthy(encrypt) and ref(encrypt) == 'HASH') then
        return 'Error loading Encrypt object'
    end
    local filt = encrypt.Filter
    if not (truthy(filt) and isMatch(filt, [[^\/]])) then
        return 'Encrypt dictionary has no Filter!'
    end
    filt = subst(filt, [[^\/]], '')
    -- extract some interesting tags
    local ver = truthy(encrypt.V) and encrypt.V or 0
    local rev = truthy(encrypt.R) and encrypt.R or 0
    local enc = filt .. ' V' .. ver
    if filt == 'Standard' then enc = enc .. '.' .. rev end
    if truthy(encrypt.SubFilter) then
        local c1 = matches(encrypt.SubFilter, [[^\/(.*)]])
        if c1 then enc = enc .. ' (' .. c1 .. ')' end
    end
    if filt == 'Standard' then enc = enc .. ' (' .. (truthy(encrypt.Length) and encrypt.Length or 40) .. '-bit)' end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.PDF.Encrypt')
    et:HandleTag(tagTablePtr, 'Filter', enc)
    if filt ~= 'Standard' then
        return 'Encryption filter ' .. filt .. ' currently not supported'
    elseif encrypt.R == nil then
        return 'Standard security handler missing revision'
    end
    if not (truthy(encrypt.O) and truthy(encrypt.P) and truthy(encrypt.U)) then
        return 'Incomplete Encrypt specification'
    end
    if perl.num(ver .. '.' .. rev) >= 5.6 then
        -- apologize for poor performance (AES is a pure Perl implementation)
        et:Warn('Decryption is very slow for encryption V5.6 or higher', 3)
    end
    et:HandleTag(tagTablePtr, 'P', encrypt.P)

    local parm = {}  -- optional parameters extracted from Encrypt dictionary

    if perl.num(ver) == 1 or perl.num(ver) == 2 then
        cryptString = 1
        cryptStream = 1
    elseif perl.num(ver) == 4 or perl.num(ver) == 5 then
        -- initialize our $cryptString and $cryptStream flags
        for _, v in ipairs({ 'StrF', 'StmF' }) do
            local flag = encrypt[v]   -- (upstream `$$flagPt`, a ref to the flag)
            if truthy(flag) and flag == '/Identity' then flag = nil end
            if v == 'StrF' then cryptString = flag else cryptStream = flag end
            if truthy(flag) and flag ~= '/StdCF' then return 'Unsupported ' .. v .. ' encryption ' .. perl.str(flag) end
        end
        if truthy(cryptString) or truthy(cryptStream) then
            if not (ref(encrypt.CF) == 'HASH' and
                ref(encrypt.CF.StdCF) == 'HASH' and truthy(encrypt.CF.StdCF.CFM)) then
                return 'Missing or invalid Encrypt StdCF entry'
            end
            local cryptMeth = encrypt.CF.StdCF.CFM
            if not isMatch(cryptMeth, [[^\/(V2|AESV2|AESV3)$]]) then
                return 'Unsupported encryption method ' .. perl.str(cryptMeth)
            end
            -- set "_aesv2" or "_aesv3" flag in %$encrypt hash if AES encryption was used
            local m = matches(cryptMeth, [[^\/(AESV2|AESV3)$]])
            if m then encrypt['_' .. lc(m)] = 1 end
        end
        if perl.num(ver) == 5 then
            -- validate OE and UE entries
            for _, v in ipairs({ 'OE', 'UE' }) do
                if not truthy(encrypt[v]) then return 'Missing Encrypt ' .. v .. ' entry' end
                parm[v] = ReadPDFValue(encrypt[v])
                if length(parm[v]) ~= 32 then return 'Invalid Encrypt ' .. v .. ' entry' end
            end
            -- (upstream `require Image::ExifTool::AES;   # will need this later`:
            --  required where it is used)
        end
    else
        return 'Encryption version ' .. ver .. ' currently not supported'
    end
    if not truthy(id) then return "Can't decrypt (no document ID)" end

    -- make sure we have the necessary libraries available
    if perl.num(ver) < 5 then
        if not ExifTool.hasMD5(et) then
            return 'Install Digest::MD5 to process encrypted PDF'
        end
    else
        if not ExifTool.hasSHA256(et) then
            return 'Install Digest::SHA to process AES-256 encrypted PDF'
        end
    end

    -- calculate file-level en/decryption key
    local pad = "\x28\xBF\x4E\x5E\x4E\x75\x8A\x41\x64\x00\x4E\x56\xFF\xFA\x01\x08" ..
                "\x2E\x2E\x00\xB6\xD0\x68\x3E\x80\x2F\x0C\xA9\xFE\x64\x53\x69\x7A"
    local o = ReadPDFValue(encrypt.O)
    local u = ReadPDFValue(encrypt.U)

    -- set flag indicating whether metadata is encrypted
    -- (in version 4 and higher, metadata streams may not be encrypted)
    if perl.num(ver) < 4 or not truthy(encrypt.EncryptMetadata) or not isMatch(encrypt.EncryptMetadata, '(?i)false') then
        encrypt._meta = 1
    end
    -- try no password first, then try provided password if available
    local try, key = 0
    while true do
        local password
        if try == 0 then
            password = ''
        elseif try == 1 then
            password = et:Options('Password')
            if password == nil then return 'Document is password protected (use Password option)' end
            -- make sure there is no UTF-8 flag on the password
            -- (Lua strings are plain bytes: there is no UTF-8 flag to remove)
        else
            return 'Incorrect password'
        end
        if perl.num(ver) < 5 then
            if truthy(length(password)) then
                -- password must be encoding in PDFDocEncoding (ref iso32000)
                password = et:Encode(password, 'PDFDoc')
                -- truncate or pad the password to exactly 32 bytes
                if length(password) > 32 then
                    password = substr(password, 0, 32)
                elseif length(password) < 32 then
                    password = password .. substr(pad, 0, 32 - length(password))
                end
            else
                password = pad
            end
            key = password .. o .. pack('V', encrypt.P) .. id
            local rep = 1
            if perl.num(rev) == 3 or perl.num(rev) == 4 then
                -- must add this if metadata not encrypted
                if not encrypt._meta then key = key .. "\xff\xff\xff\xff" end
                rep = rep + 50 -- repeat MD5 50 more times if revision is 3 or greater
            end
            local len, dat
            if perl.num(ver) == 1 then
                len = 5
            else
                len = truthy(encrypt.Length) and perl.num(encrypt.Length) or 40
                if len < 40 then return 'Bad Encrypt Length' end
                len = int(len / 8)
            end
            for _ = 1, rep do
                key = substr(ExifTool.md5(et, key), 0, len)
            end
            -- decrypt U to see if a user password is required
            if perl.num(rev) >= 3 then
                dat = ExifTool.md5(et, pad .. id)
                dat = RC4Crypt(dat, key)
                for i = 1, 19 do
                    local key_ = { unpack('C*', key) }
                    for k = 1, #key_ do key_[k] = key_[k] ~ i end
                    dat = RC4Crypt(dat, pack('C*', table.unpack(key_)))
                end
                dat = dat .. substr(u, 16)
            else
                dat = pad
                dat = RC4Crypt(dat, key)
            end
            if dat == u then break end -- all done if this was the correct key
        else
            if length(o) < 48 or length(u) < 48 then return 'Invalid O or U Encrypt entries' end
            if truthy(length(password)) then
                -- Note: this should be good for passwords containing reasonable characters,
                -- but to be bullet-proof we need to apply the SASLprep (IETF RFC 4013) profile
                -- of stringprep (IETF RFC 3454) to the password before encoding in UTF-8
                password = et:Encode(password, 'UTF8')
                if length(password) > 127 then password = substr(password, 0, 127) end
            end
            -- test for the owner password
            local sha = GetHash(password, substr(o, 32, 8), substr(u, 0, 48), rev)
            if sha == substr(o, 0, 32) then
                key = GetHash(password, substr(o, 40, 8), substr(u, 0, 48), rev)
                local dat = ("\0"):rep(16) .. parm.OE
                -- decrypt with no padding
                local err
                dat, err = require('lexiftool.AES').Crypt(dat, key, 0, 1)
                if err then return err end
                key = dat   -- use this as the file decryption key
                break
            end
            -- test for the user password
            sha = GetHash(password, substr(u, 32, 8), '', rev)
            if sha == substr(u, 0, 32) then
                key = GetHash(password, substr(u, 40, 8), '', rev)
                local dat = ("\0"):rep(16) .. parm.UE
                local err
                dat, err = require('lexiftool.AES').Crypt(dat, key, 0, 1)
                if err then return err end
                key = dat   -- use this as the file decryption key
                break
            end
        end
        try = try + 1
    end
    encrypt._key = key  -- save the file-level encryption key
    cryptInfo = encrypt -- save reference to the file-level Encrypt object
    return nil          -- success!
end

--------------------------------------------------------------------------------
-- Decrypt/Encrypt data
-- Inputs: 0) data ref
--         1) PDF object reference to use as crypt key extension (may be 'none' to
--            avoid extending the encryption key, as for streams with Crypt Filter)
--         2) encrypt flag (false for decryption)
-- (returns the de/encrypted data, see the port notes)
function Crypt(data, keyExt, encrypt)
    if not cryptInfo then return data end
    -- do not decrypt if the key extension object is undefined
    -- (this doubles as a flag to disable decryption/encryption)
    if keyExt == nil then return data end
    local key = cryptInfo._key
    -- apply the necessary crypt key extension
    if not cryptInfo._aesv3 then
        if keyExt ~= 'none' then
            -- extend crypt key using object and generation number
            local ok, _, c2, c3 = isMatch(keyExt, [[^(I\d+ )?(\d+) (\d+)]])
            if not ok then
                cryptInfo._error = 'Invalid object reference for encryption'
                return data
            end
            key = key .. substr(pack('V', c2), 0, 3) .. substr(pack('V', c3), 0, 2)
        end
        -- add AES-128 salt if necessary (this little gem is conveniently
        -- omitted from the Adobe PDF 1.6 documentation, causing me to
        -- waste 12 hours trying to figure out why this wasn't working --
        -- it appears in ISO32000 though, so I should have been using that)
        if cryptInfo._aesv2 then key = key .. 'sAlT' end
        local len = length(key)
        key = ExifTool.md5(nil, key)                -- get 16-byte MD5 digest
        if len < 16 then key = substr(key, 0, len) end -- trim if necessary
    end
    -- perform the decryption/encryption
    if cryptInfo._aesv2 or cryptInfo._aesv3 then
        local out, err = require('lexiftool.AES').Crypt(data, key, encrypt)
        if err then cryptInfo._error = err else data = out end
    else
        data = RC4Crypt(data, key)
    end
    return data
end

--------------------------------------------------------------------------------
-- Decrypt/Encrypt stream data
-- Inputs: 0) dictionary ref, 1) PDF object reference to use as crypt key extension
function CryptStream(dict, keyExt)
    if not truthy(cryptStream) then return end
    local type_ = truthy(dict.Type) and dict.Type or ''
    -- XRef streams are not encrypted (ref 3, page 50),
    -- and Metadata may or may not be encrypted
    if cryptInfo and type_ ~= '/XRef' and
        (cryptInfo._meta or type_ ~= '/Metadata')
    then
        dict._stream = Crypt(dict._stream, keyExt, dict._decrypted)
        -- toggle _decrypted flag
        if truthy(dict._decrypted) then dict._decrypted = nil else dict._decrypted = 1 end
    else
        dict._decrypted = 0 -- stream should never be encrypted
    end
end

--------------------------------------------------------------------------------
-- Generate a new PDF tag (based on its ID) and add it to a tag table
-- Inputs: 0) tag table ref, 1) tag ID
-- Returns: tag info ref
local function NewPDFTag(tagTablePtr, tag)
    local name = tag
    -- translate URL-like escape sequences
    name = subst(name, [[(?i)#([0-9a-f]{2})]], function(h) return chr(hex(h)) end, 'g')
    name = subst(name, [[[^-\w]+]], '_', 'g')          -- translate invalid characters to an underline
    name = subst(name, [[(^|_)([a-z])]], function(_, c) return perl.uc(c) end, 'g') -- start words with upper case
    local tagInfo = { Name = name }
    AddTagToTable(nil, tagTablePtr, tag, tagInfo)
    return tagInfo
end

--------------------------------------------------------------------------------
-- Process AcroForm dictionary to set HasXMLFormsArchitecture flag
-- Inputs: Same as ProcessDict
function ProcessAcroForm(et, tagTablePtr, dict, xref, nesting, type_)
    et:HandleTag(tagTablePtr, '_has_xfa', truthy(dict.XFA) and 'true' or 'false')
    if not truthy(et:Options('Verbose')) then return 1 end
    return ProcessDict(et, tagTablePtr, dict, xref, nesting, type_)
end

--------------------------------------------------------------------------------
-- Process AF dictionary to extract C2PA manifest
-- Inputs: Same as ProcessDict
local function ProcessAF(et, tagTablePtr, dict, xref, nesting, type_)
    et.AFRelationship = truthy(dict.AFRelationship) and dict.AFRelationship or ''
    -- go no further unless Verbose or this is the C2PA_Manifest item
    if not (truthy(et:Options('Verbose')) or et.AFRelationship == '/C2PA_Manifest') then return 1 end
    return ProcessDict(et, tagTablePtr, dict, xref, nesting, type_)
end

--------------------------------------------------------------------------------
-- Expand array into a string
-- Inputs: 0) array ref
-- Return: string
function ExpandArray(val)
    local list = { table.unpack(val) }
    for i = 1, #list do
        if ref(list[i]) == 'SCALAR' then
            list[i] = 'ref(' .. list[i].value .. ')'
        elseif ref(list[i]) == 'ARRAY' then
            list[i] = ExpandArray(list[i])
        elseif list[i] == nil then
            list[i] = '<undef>'
        end
    end
    return '[' .. join(',', list) .. ']'
end

--------------------------------------------------------------------------------
-- Process PDF dictionary extract tag values
-- Inputs: 0) ExifTool object reference, 1) tag table reference
--         2) dictionary reference, 3) cross-reference table reference,
--         4) nesting depth, 5) dictionary capture type
function ProcessDict(et, tagTablePtr, dict, xref, nesting, type_)
    local verbose = et:Options('Verbose')
    local unknown = tagTablePtr.EXTRACT_UNKNOWN
    local embedded = (unknown ~= nil and not truthy(unknown) and truthy(et:Options('ExtractEmbedded')))
    local tags = { table.unpack(dict._tags) }
    local next_, join_, validInfo = nil, {}
    local index = 0

    nesting = (nesting or 0) + 1
    if nesting > 50 then
        et:Warn('Nesting too deep (directory ignored)')
        return
    end
    -- save entire dictionary for rewriting if specified
    if et.PDF_CAPTURE and tagTablePtr.VARS and
        tagTablePtr.VARS.CAPTURE
    then
        for _, name in ipairs(tagTablePtr.VARS.CAPTURE) do
            if et.PDF_CAPTURE[name] then goto continue end
            -- make sure we load the right type if indicated
            if type_ and type_ ~= name then goto continue end
            et.PDF_CAPTURE[name] = dict
            do break end
            ::continue::
        end
    end
    validInfo = (truthy(et:Options('Validate')) and tagTablePtr == PDF.Info)
--
-- extract information from all tags in the dictionary
--
    while true do
        local tag, isSubDoc
        if #tags > 0 then
            tag = table.remove(tags, 1)
        elseif next_ ~= nil and not truthy(next_) then
            tag = 'Next'
            next_ = 1
        else
            break
        end
        local val = dict[tag]
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo then
            if tagInfo.NoProcess then tagInfo = nil end
        elseif embedded then
            local name, num = matches(tag, [[^(.*?)(\d+)$]])
            if name and tagTablePtr[name] and (ref(val) ~= 'SCALAR' or not fetched[val.value]) then
                tagInfo = et:GetTagInfo(tagTablePtr, name)
                if type(tagInfo) == 'table' and tagInfo.JoinStreams then
                    fetched[val.value] = 1
                    local obj = FetchObject(et, val.value, xref, tag)
                    if not join_[name] then join_[name] = {} end
                    if not (ref(obj) == 'HASH' and truthy(obj._stream)) then goto continue end
                    -- save all the stream data to join later
                    DecodeStream(et, obj)
                    join_[name][tonumber(num)] = obj._stream
                    tagInfo = nil    -- don't process
                else
                    isSubDoc = 1  -- treat as a sub-document
                end
            end
        end
        if validInfo and perl.num(et.PDFVersion) >= 2.0 and (not tagInfo or not tagInfo.PDF2) then
            local name = tagInfo and (':' .. tagInfo.Name) or (" Info tag '" .. tag .. "'")
            et:Warn('PDF' .. name .. ' is deprecated in PDF 2.0')
        end
        if truthy(verbose) then
            local val2, extra
            if ref(val) == 'SCALAR' then
                extra = ', indirect object (' .. val.value .. ')'
                if fetched[val.value] then
                    val2 = 'ref(' .. val.value .. ')'
                elseif tag == 'Next' and not truthy(next_) then
                    -- handle 'Next' links after all others
                    next_ = 0
                    goto continue
                else
                    fetched[val.value] = 1
                    val = FetchObject(et, val.value, xref, tag)
                    if val == nil then
                        local str
                        if lastOffset ~= nil then
                            val2 = '<free>'
                            str = 'Object was freed'
                        else
                            val2 = '<err>'
                            str = 'Error reading object'
                        end
                        et:VPrint(0, et.INDENT .. str .. ":\n")
                    end
                end
            elseif ref(val) == 'HASH' then
                extra = ', direct dictionary'
            elseif ref(val) == 'ARRAY' then
                extra = ', direct array of ' .. #val .. ' objects'
            else
                extra = ', direct object'
            end
            local isSubdir
            if ref(val) == 'HASH' then
                isSubdir = 1
            elseif ref(val) == 'ARRAY' then
                -- recurse into objects in arrays only if they are lists of
                -- dictionaries or indirect objects which could be dictionaries
                if #val > 0 then isSubdir = 1 end
                for _, v in ipairs(val) do
                    if not (ref(v) == 'HASH' or ref(v) == 'SCALAR') then
                        isSubdir = nil
                        break
                    end
                end
            end
            if isSubdir then
                -- create bogus subdirectory to recurse into this dict
                if not tagInfo then
                    tagInfo = {
                        Name = tag,
                        SubDirectory = { TagTable = 'lexiftool.PDF.Unknown' },
                    }
                end
            else
                if ref(val) == 'ARRAY' then val2 = ExpandArray(val) end
                -- generate tag info if we will use it later
                if not tagInfo and val ~= nil and truthy(unknown) then
                    tagInfo = NewPDFTag(tagTablePtr, tag)
                end
            end
            et:VerboseInfo(tag, tagInfo, {
                Value = truthy(val2) and val2 or val,
                Extra = extra,
                Index = index,
            })
            index = index + 1
            if val == nil then goto continue end
        end
        if not tagInfo then
            -- add any tag found in Info dictionary to table
            if not truthy(unknown) then goto continue end
            tagInfo = NewPDFTag(tagTablePtr, tag)
        end
        -- increment document number if necessary
        local oldDocNum, oldNumTags
        if isSubDoc then
            oldDocNum = et.DOC_NUM
            oldNumTags = et.NUM_FOUND
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
        end
        if tagInfo.SubDirectory then
            -- process the subdirectory
            local subDicts
            if ref(val) == 'ARRAY' then
                -- hack to convert array to dictionary if necessary
                if tagInfo.ConvertToDict and #val == 2 and ref(val[1]) == '' then
                    local tg = val[1]
                    tg = subst(tg, '^/', '')   -- remove name
                    local dict_ = { _tags = { tg }, [tg] = val[2] }
                    subDicts = { dict_ }
                else
                    subDicts = { table.unpack(val) }
                end
            else
                subDicts = { val }
            end
            -- loop through all values of this tag
            while true do
                local subDict = table.remove(subDicts, 1)
                if not truthy(subDict) then break end
                -- save last fetched object in case we fetch another one here
                local prevFetched = PDF.lastFetched
                if ref(subDict) == 'SCALAR' then
                    -- only fetch once (other copies are obsolete)
                    if fetched[subDict.value] then goto nextSubDict end
                    if tagInfo.IgnoreDuplicates then
                        local flag = 'ProcessedPDF_' .. tag
                        if et[flag] then
                            if truthy(et:Warn('Ignored duplicate ' .. tag .. ' dictionary', 2)) then goto nextSubDict end
                        else
                            et[flag] = 1
                        end
                    end
                    -- load dictionary via an indirect reference
                    fetched[subDict.value] = 1
                    local obj = FetchObject(et, subDict.value, xref, tag)
                    if obj == nil then
                        if lastOffset == nil then
                            et:Warn('Error reading ' .. tag .. ' object (' .. subDict.value .. ')')
                        end
                        goto nextSubDict
                    end
                    subDict = obj
                end
                if ref(subDict) == 'ARRAY' then
                    -- convert array of key/value pairs to a hash
                    if #subDict < 2 then goto nextSubDict end
                    local hash = { _tags = {} }
                    while #subDict >= 2 do
                        local key = table.remove(subDict, 1)
                        key = subst(key, [[^\/]], '')
                        hash._tags[#hash._tags + 1] = key
                        hash[key] = table.remove(subDict, 1)
                    end
                    subDict = hash
                else
                    if ref(subDict) ~= 'HASH' then goto nextSubDict end
                end
                -- set flag to re-crypt all strings when rewriting if the dictionary
                -- came from an encrypted stream
                if not truthy(PDF.lastFetched) then
                    if not subDict._needCrypt then subDict._needCrypt = {} end
                    subDict._needCrypt['*'] = 1
                end
                do
                    local subTablePtr = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                    if not truthy(verbose) then
                        local proc = subTablePtr.PROCESS_PROC or ProcessDict
                        proc(et, subTablePtr, subDict, xref, nesting)
                    elseif truthy(next_) then
                        -- handle 'Next' links at this level to avoid deep recursion
                        next_ = nil
                        index = 0
                        tagTablePtr = subTablePtr
                        dict = subDict
                        tags = { table.unpack(subDict._tags) }
                        et:VerboseDir(tag, #tags)
                    else
                        local oldIndent = et.INDENT
                        local oldDir = et.DIR_NAME
                        et.INDENT = et.INDENT .. '| '
                        et.DIR_NAME = tag
                        et:VerboseDir(tag, #subDict._tags)
                        local proc = subTablePtr.PROCESS_PROC or ProcessDict
                        proc(et, subTablePtr, subDict, xref, nesting)
                        et.INDENT = oldIndent
                        et.DIR_NAME = oldDir
                    end
                end
                PDF.lastFetched = prevFetched
                ::nextSubDict::
            end
        else
            -- fetch object if necessary
            -- (OS X 10.6 writes indirect objects in the Info dictionary!)
            if ref(val) == 'SCALAR' then
                local prevFetched = PDF.lastFetched
                -- (note: fetching the same object multiple times is OK here)
                val = FetchObject(et, val.value, xref, tag)
                if val ~= nil then
                    val = ReadPDFValue(val)
                    -- set flag to re-encrypt if necessary if rewritten
                    if truthy(cryptString) then
                        if not dict._needCrypt then dict._needCrypt = {} end
                        dict._needCrypt[tag] = (truthy(PDF.lastFetched) and 0 or 1)
                    end
                    PDF.lastFetched = prevFetched -- restore last fetched object reference
                end
            else
                val = ReadPDFValue(val)
            end
            if ref(val) ~= '' then
                if ref(val) == 'ARRAY' then
                    if tagInfo.List then et.LIST_TAGS[tagInfo] = nil end
                    for _, v in ipairs(val) do
                        et:FoundTag(tagInfo, v)
                    end
                end
            elseif val ~= nil then
                -- convert from UTF-16 (big endian) to UTF-8 or Latin if necessary
                -- unless this is binary data (hex-encoded strings would not have been converted)
                local format = tagInfo.Format or tagInfo.Writable or 'string'
                if format == 'date' then val = ConvertPDFDate(val) end
                if not tagInfo.Binary and isMatch(val, [=[[\x18-\x1f\x80-\xff]]=]) then
                    -- text string is already in Unicode if it starts with "\xfe\xff",
                    -- otherwise we must first convert from PDFDocEncoding
                    local from = 'PDFDoc'
                    if isMatch(val, [[^\xfe\xff]]) then
                        val = subst(val, [[^\xfe\xff]], '')
                        from = 'UTF16'
                    end
                    val = et:Decode(val, from, 'MM')
                end
                if tagInfo.List and not truthy(et.OPTIONS.NoPDFList) then
                    -- separate tokens in comma or whitespace delimited lists
                    local _, comma = tr(val, ',', ',')
                    local _, semi = tr(val, ';', ';')
                    local split_
                    if comma ~= 0 or semi ~= 0 then
                        split_ = comma > semi and [[,+\s*]] or [[;+\s*]]
                    else
                        split_ = ' '
                    end
                    local values = perl.splitDyn(split_, val)
                    for _, v in ipairs(values) do et:FoundTag(tagInfo, v) end
                else
                    -- a simple tag value
                    et:FoundTag(tagInfo, val)
                end
            end
        end
        if isSubDoc then
            -- restore original document number
            et.DOC_NUM = oldDocNum
            if oldNumTags == et.NUM_FOUND then et.DOC_COUNT = et.DOC_COUNT - 1 end
        end
        ::continue::
    end
--
-- extract information from joined streams if necessary
--

    if next(join_) ~= nil then
        for _, tag in ipairs(perl.sort(perl.keys(join_))) do
            local list = join_[tag]
            if list[1] == nil then break end
            local ok, c1 = isMatch(list[1], [[^%.*?([\x0d\x0a]*)]])
            if not ok then break end
            local buff = '%!PS-Adobe-3.0' .. c1  -- add PS header with same line break
            local i = 1
            while list[i] ~= nil do
                buff = buff .. list[i]
                list[i] = nil    -- free memory
                i = i + 1
            end
            -- increment document number for tags extracted from embedded EPS
            local oldDocNum = et.DOC_NUM
            local oldNumTags = et.NUM_FOUND
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            -- extract PostScript information
            et:HandleTag(tagTablePtr, tag, buff)
            et.DOC_NUM = oldDocNum
            -- revert document counter if we didn't add any new tags
            if oldNumTags == et.NUM_FOUND then et.DOC_COUNT = et.DOC_COUNT - 1 end
            et.DOC_NUM = nil
        end
    end
--
-- extract information from stream object if it exists (eg. Metadata stream)
--
    repeat -- (cheap goto)
        if not truthy(dict._stream) then break end
        local tag = '_stream'
        -- add Subtype (if it exists) to stream name and remove leading '/'
        if truthy(dict.Subtype) then tag = subst(dict.Subtype .. tag, '^/', '') end
        if not tagTablePtr[tag] then break end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not tagInfo then break end
        local subdir = tagInfo.SubDirectory
        if not subdir then
            -- don't build filter lists across different images
            if tagTablePtr.Filter ~= nil then et.LIST_TAGS[tagTablePtr.Filter] = nil end
            -- we arrive here only when extracting embedded images
            -- - only extract known image types and ignore others
            local filter = truthy(dict.Filter) and dict.Filter or ''
            if ref(filter) == 'ARRAY' then filter = filter[#filter] end -- (get last Filter type)
            local result
            if filter == '/DCTDecode' or filter == '/JPXDecode' then
                if not truthy(DecodeStream(et, dict)) then break end
                -- save the image itself
                et:FoundTag(tagInfo, { ref = 'SCALAR', value = dict._stream })
                -- extract information from embedded image
                result = et:ExtractInfo({ ref = 'SCALAR', value = dict._stream }, { ReEntry = 1 })
            end
            if not truthy(result) then
                et:FoundTag('FileType', result ~= nil and '(unknown)' or '(unsupported)')
            end
            break
        end
        -- decode stream if necessary
        if cryptInfo and (cryptInfo._aesv2 or cryptInfo._aesv3 and
            truthy(dict.Length) and perl.num(dict.Length) > 10000) and not truthy(dict._decrypted) and
            not et.PDF_CAPTURE -- (capturing PDF for writing?)
        then
            type_ = truthy(dict.Type) and dict.Type or ''    -- (upstream: a new `my $type`)
            if type_ ~= '/Metadata' or perl.num(dict.Length) > 100000 then
                if truthy(et.OPTIONS.IgnoreMinorErrors) then
                    et:Warn('Decrypting large ' .. tagInfo.Name .. ' (will be slow)')
                else
                    et:Warn('Skipping large AES-encrypted ' .. tagInfo.Name, 2)
                    break
                end
            end
        end
        if not truthy(DecodeStream(et, dict)) then break end
        if perl.num(verbose) > 2 then
            et:VPrint(2, et.INDENT .. perl.str(et.DIR_NAME) .. " stream data\n")
            et:VerboseDump(dict._stream)
        end
        -- extract information from stream
        local dirInfo = {
            DataPt   = dict._stream,
            DataLen  = length(dict._stream),
            DirStart = 0,
            DirLen   = length(dict._stream),
            Parent   = 'PDF',
            DirName  = subdir.DirName,
        }
        local subTablePtr = GetTagTable(nil, subdir.TagTable)
        if not truthy(et:ProcessDirectory(dirInfo, subTablePtr)) then
            et:Warn('Error processing ' .. tagInfo.Name .. ' information')
        end
    until true
end

--------------------------------------------------------------------------------
-- Extract information from PDF file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 0 if not a PDF file, 1 on success, otherwise a negative error number
local function ReadPDF(et, dirInfo)
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local buff, encrypt, id
    local nRead
--
-- validate PDF file
--
    -- (linearization dictionary must be in the first 1024 bytes of the file)
    nRead, buff = raf:Read(1024)
    if nRead < 8 then return 0 end
    local c1, c2 = matches(buff, [[^(\s*)%PDF-(\d+\.\d+)]])
    if not c1 then return 0 end
    et.PDFBase = length(c1)
    if truthy(et.PDFBase) then et:Warn('PDF header is not at start of file', 1) end
    et.PDFVersion = c2
    pdfVer = et.PDFVersion
    et:SetFileType()   -- set the FileType tag
    -- store PDFVersion tag
    local tagTablePtr = GetTagTable(nil, 'lexiftool.PDF.Root')
    et:HandleTag(tagTablePtr, 'Version', pdfVer)
    tagTablePtr = GetTagTable(nil, 'lexiftool.PDF.Main')
--
-- check for a linearized PDF (only if reading)
--
    local capture = et.PDF_CAPTURE
    if not capture then
        local lin = 'false'
        local _, en = matches(buff, '<<')
        if en then
            buff = substr(buff, en - 2)
            local dict = ExtractObject(et, { value = carray.new('char'):append(buff) })
            if ref(dict) == 'HASH' and truthy(dict.Linearized) and truthy(dict.L) then
                if not truthy(et.VALUE.FileSize) then
                    lin = nil -- can't determine if it is linearized
                elseif perl.num(dict.L) == perl.num(et.VALUE.FileSize) - et.PDFBase then
                    lin = 'true'
                end
            end
        end
        if lin then et:HandleTag(tagTablePtr, '_linearized', lin) end
    end
--
-- read the xref tables referenced from startxref at the end of the file
--
    local xrefOffsets = {}
    if not raf:Seek(0, 2) then return -2 end
    -- the %%EOF must occur within the last 1024 bytes of the file (PDF spec, appendix H)
    local len = raf:Tell()
    if len > 1024 then len = 1024 end
    if not raf:Seek(-len, 2) then return -2 end
    nRead, buff = raf:Read(len)
    if nRead ~= len then return -3 end
    -- find the LAST xref table in the file (may be multiple %%EOF marks,
    -- and comments between "startxref" and "%%EOF")
    local d1, d2, d3, d4 = matches(buff, [[(?s)^.*startxref(\s+)(\d+)(\s+)((%[^\x0d\x0a]*\s+)*)%%EOF]])
    if not d1 then return -4 end
    -- parse comments to read SEAL information
    if truthy(d4) then
        local com = split([=[[\x0d\x0d]+]=], d4)
        for _, v in ipairs(com) do
            local e1 = matches(v, [[^(%+\s*)<seal seal=]])
            if e1 then
                local dat = substr(v, length(e1))
                local tbl = GetTagTable(nil, 'lexiftool.XMP.SEAL')
                et:ProcessDirectory({ DataPt = dat }, tbl)
            end
        end
    end
    local ws = d1 .. d3
    local xr = d2
    xrefOffsets[#xrefOffsets + 1] = xr
    xrefOffsets[#xrefOffsets + 1] = 'Main'
    -- set input record separator
    -- (upstream `local $/`; RS is module-local, so it needs no restoring)
    RS = matches(ws, [[(\x0d\x0a|\x0d|\x0a)]]) or "\x0a"
    local xref, mainDicts, loaded, mainFree = {}, {}, {}, nil
    local xrefSize, mainDictSize = 0, 0
    -- initialize variables to capture when rewriting
    if capture then
        capture.startxref = xr
        capture.xref = xref
        capture.newline = RS
        mainFree = { }
        capture.mainFree = mainFree
    end
    while #xrefOffsets > 0 do   -- (XRef:)
        local offset = table.remove(xrefOffsets, 1)
        local type_ = table.remove(xrefOffsets, 1)
        if loaded[offset] then goto nextXRef end   -- avoid infinite recursion
        if not raf:Seek(perl.num(offset) + et.PDFBase, 0) then
            if next(loaded) == nil then return -5 end
            et:Warn('Bad offset for secondary xref table')
            goto nextXRef
        end
        -- Note: care must be taken because ReadLine may read more than we want if
        -- the newline sequence for this table is different than the rest of the file
        while true do
            nRead, buff = raf:ReadLine(RS)
            if nRead == 0 then
                if next(loaded) == nil then return -6 end
                et:Warn('Bad offset for secondary xref table')
                goto nextXRef
            end
            if isMatch(buff, [[\S]]) then break end   -- skip blank lines
        end
        do
            local loadXRefStream
            if isMatch(buff, [[(?s)^\s*xref\s+]]) then
                buff = subst(buff, [[(?s)^\s*xref\s+]], '')
                -- load xref table
                while true do
                    -- read another line if necessary (skipping blank lines)
                    while not isMatch(buff, [[\S]]) do
                        nRead, buff = raf:ReadLine(RS)
                        if nRead == 0 then return -6 end
                    end
                    if isMatch(buff, [[(?s)^\s*trailer([\s<[(])]]) then
                        buff = subst(buff, [[(?s)^\s*trailer([\s<[(])]], '$1')
                        break
                    end
                    local e1, e2, en = matches(buff, [[(?s)^\s*(\d+)\s+(\d+)\s+]])
                    if not e1 then return -4 end
                    buff = substr(buff, en)
                    local start, num = perl.num(e1), perl.num(e2)
                    if not raf:Seek(-length(buff), 1) then return -4 end
                    for i = 0, num - 1 do
                        nRead, buff = raf:Read(20)
                        if nRead ~= 20 then return -6 end
                        local f1, f2, f3 = matches(buff, [[(?s)^\s*(\d{10}) (\d{5}) (f|n)]])
                        if not f1 then return -4 end
                        local num_ = start + i   -- (upstream's inner `my $num`)
                        if num_ > xrefSize then xrefSize = num_ end
                        -- locate object to generate entry from stream if necessary
                        -- (must do this before we test $xref{$num})
                        if xref.dicts then LocateAnyObject(xref, num_) end
                        -- save offset for newest copy of all objects
                        -- (or next object number for free objects)
                        if xref[num_] == nil then
                            local offset_, gen = int(f1), int(f2)   -- (upstream's inner `my $offset`)
                            xref[num_] = offset_
                            if f3 == 'f' then
                                -- save free objects in last xref table for rewriting
                                if mainFree then mainFree[num_] = { offset_, gen, 'f' } end
                                goto nextEntry
                            end
                            -- also save offset keyed by object reference string
                            xref[num_ .. ' ' .. gen .. ' R'] = offset_
                        end
                        ::nextEntry::
                    end
                    -- (I have a sample from Adobe which has an empty xref table)
                    -- %xref or return -4; # xref table may not be empty
                    buff = ''
                end
                mainFree = nil  -- only do this for the last xref table
            elseif isMatch(buff, [[(?s)^\s*(\d+)\s+(\d+)\s+obj]]) then
                buff = subst(buff, [[(?s)^\s*(\d+)\s+(\d+)\s+obj]], '')
                -- this is a PDF-1.5 cross-reference stream dictionary
                loadXRefStream = 1
            else
                if next(loaded) == nil then return -4 end
                et:Warn('Invalid secondary xref table')
                goto nextXRef
            end
            local mainDict = ExtractObject(et, { value = carray.new('char'):append(buff) }, raf, xref)
            if ref(mainDict) ~= 'HASH' then
                if next(loaded) == nil then return -8 end
                et:Warn('Error loading secondary dictionary')
                goto nextXRef
            end
            -- keep track of total trailer dictionary Size
            if truthy(mainDict.Size) and perl.num(mainDict.Size) > mainDictSize then mainDictSize = perl.num(mainDict.Size) end
            if loadXRefStream then
                -- decode and save our XRef stream from PDF-1.5 file
                -- (but parse it later as required to save time)
                -- Note: this technique can potentially result in an old object
                -- being used if the file was incrementally updated and an older
                -- object from an xref table was replaced by a newer object in an
                -- xref stream.  But doing so isn't a good idea (if allowed at all)
                -- because a PDF 1.4 consumer would also make this same mistake.
                if mainDict.Type == '/XRef' and truthy(mainDict.W) and
                    #mainDict.W > 2 and truthy(mainDict.Size) and
                    truthy(DecodeStream(et, mainDict))
                then
                    -- create Index entry if it doesn't exist
                    if not truthy(mainDict.Index) then mainDict.Index = { 0, mainDict.Size } end
                    -- create '_entry_size' entry for internal use
                    local w = mainDict.W
                    local size = 0
                    for _, v in ipairs(w) do size = size + perl.num(v) end
                    mainDict._entry_size = size
                    -- save this stream dictionary to use later if required
                    if not xref.dicts then xref.dicts = {} end
                    xref.dicts[#xref.dicts + 1] = mainDict
                else
                    if next(loaded) == nil then return -9 end
                    et:Warn('Invalid xref stream in secondary dictionary')
                end
            end
            loaded[offset] = 1
            -- load XRef stream in hybrid file if it exists
            if truthy(mainDict.XRefStm) then
                xrefOffsets[#xrefOffsets + 1] = mainDict.XRefStm
                xrefOffsets[#xrefOffsets + 1] = 'XRefStm'
            end
            if truthy(mainDict.Encrypt) then encrypt = mainDict.Encrypt end
            if truthy(encrypt) and encrypt == 'null' then encrypt = nil end -- (have seen "null")
            if truthy(mainDict.ID) and ref(mainDict.ID) == 'ARRAY' then
                id = ReadPDFValue(mainDict.ID[1])
            end
            mainDicts[#mainDicts + 1] = mainDict
            mainDicts[#mainDicts + 1] = type_
            -- load previous xref table if it exists
            if truthy(mainDict.Prev) then
                xrefOffsets[#xrefOffsets + 1] = mainDict.Prev
                xrefOffsets[#xrefOffsets + 1] = 'Prev'
            end
        end
        ::nextXRef::
    end
    if xrefSize > mainDictSize then
        local str = 'Objects in xref table (' .. xrefSize .. ') exceed trailer dictionary Size (' .. mainDictSize .. ')'
        if capture then et:Error(str) else et:Warn(str) end
    end
--
-- extract encryption information if necessary
--
    if truthy(encrypt) then
        if ref(encrypt) == 'SCALAR' then
            encrypt = FetchObject(et, encrypt.value, xref, 'Encrypt')
        end
        -- generate Encryption tag information
        local err = DecryptInit(et, encrypt, id)
        if err then
            et:Warn(err)
            if capture then capture.Error = err end
            return -1
        end
    end
--
-- extract the information beginning with each of the main dictionaries
--
    local i = 0
    local num = #mainDicts // 2
    while #mainDicts > 0 do
        local dict = table.remove(mainDicts, 1)
        local type_ = table.remove(mainDicts, 1)
        if truthy(verbose) then
            i = i + 1
            local n = #dict._tags
            et:VPrint(0, 'PDF dictionary (' .. i .. ' of ' .. num .. ') with ' .. n .. " entries:\n")
        end
        ProcessDict(et, tagTablePtr, dict, xref, 0, type_)
    end
    -- handle any decryption errors
    if truthy(encrypt) then
        local err = encrypt._error
        if err then
            et:Warn(err)
            if capture then capture.Error = err end
            return -1
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- ReadPDF() warning strings for each error return value
local pdfWarning = {
    -- -1 is reserved as error return value with no associated warning
    [-2] = 'Error seeking in file',
    [-3] = 'Error reading file',
    [-4] = 'Invalid xref table',
    [-5] = 'Invalid xref offset',
    [-6] = 'Error reading xref table',
    [-7] = 'Error reading trailer',
    [-8] = 'Error reading main dictionary',
    [-9] = 'Invalid xref stream in main dictionary',
}

--------------------------------------------------------------------------------
-- Extract information from PDF file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 if this was a valid PDF file
local function ProcessPDF(et, dirInfo)

    cryptInfo = nil     -- (must not delete after returning so writer can use it)
    cryptStream = nil
    cryptString = nil
    local result = ReadPDF(et, dirInfo)
    if result < 0 then
        if pdfWarning[result] then et:Warn(pdfWarning[result]) end
        result = 1
    end
    -- clean up and return
    streamObjs = {}
    fetched = {}
    return result
end

-- (PROCESS_PROC of the tables above: the predeclared subs exist only now, see
--  the predeclaration placeholders)
PDF.AcroForm.PROCESS_PROC = ProcessAcroForm
PDF.AF.PROCESS_PROC = ProcessAF

PDF.ConvertPDFDate = ConvertPDFDate
PDF.LocateAnyObject = LocateAnyObject
PDF.LocateObject = LocateObject
PDF.CheckObject = CheckObject
PDF.FetchObject = FetchObject
PDF.ReadPDFValue = ReadPDFValue
PDF.ExtractObject = ExtractObject
PDF.ReadToNested = ReadToNested
PDF.DecodeLZW = DecodeLZW
PDF.DecodeStream = DecodeStream
PDF.RC4Init = RC4Init
PDF.RC4Crypt = RC4Crypt
PDF.CipherUpdate = CipherUpdate
PDF.GetHash = GetHash
PDF.DecryptInit = DecryptInit
PDF.Crypt = Crypt
PDF.CryptStream = CryptStream
PDF.NewPDFTag = NewPDFTag
PDF.ProcessAcroForm = ProcessAcroForm
PDF.ProcessAF = ProcessAF
PDF.ExpandArray = ExpandArray
PDF.ProcessDict = ProcessDict
PDF.ReadPDF = ReadPDF
PDF.ProcessPDF = ProcessPDF

return PDF -- end
