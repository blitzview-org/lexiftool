--------------------------------------------------------------------------------
-- File:         lexiftool/FlashPix.lua
-- Ported from:  lib/Image/ExifTool/FlashPix.pm
--
-- Description:  Read FlashPix meta information
--
-- Revisions:    05/29/2006 - P. Harvey Created
--
-- References:   1) http://www.exif.org/Exif2-2.PDF
--               2) http://www.graphcomp.com/info/specs/livepicture/fpx.pdf
--               3) http://search.cpan.org/~jdb/libwin32/
--               4) http://msdn.microsoft.com/en-us/library/aa380374.aspx
--               5) http://www.cpan.org/modules/by-authors/id/H/HC/HCARVEY/File-MSWord-0.1.zip
--               6) https://msdn.microsoft.com/en-us/library/cc313153(v=office.12).aspx
--               7) https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-oshared/3ef02e83-afef-4b6c-9585-c109edd24e07
--
-- Port notes:   Complete port of FlashPix.pm: every table, lookup and sub,
--               in upstream order (FlashPix.pm is read-only; it has no
--               write code).  Deviations forced by Lua:
--               - The predeclarations `sub ProcessFPX($$);` ...
--                 `sub ConvertDTTM($);` are one block of locals at the top;
--                 the subs assign to them (and are exported on the module
--                 table), the PROCESS_PROC entries of the tables are `false`
--                 placeholders filled in at the bottom of the file, and the
--                 SubDirectory ProcessProc / RawConv code refs are closures
--                 calling the local.
--               - The constant subs (`sub HDR_SIZE () { 512; }`) are local
--                 functions, called as `HDR_SIZE()`; VT_VARIANT is exported
--                 for Microsoft.pm's `Image::ExifTool::FlashPix::VT_VARIANT()`.
--               - ReadFPXValue updates its value-offset argument in place
--                 upstream (`$_[2] = $valPos`) and returns a list or a scalar
--                 depending on `wantarray`; here it takes `wantarray` as an
--                 extra last argument and returns (value-or-list, valPos).
--               - Perl's `$type`/`%type` and `$end` are `type_`/`end_`.
--               - Regex `/g` matches that carry on at pos() are `matches`
--                 calls that take and return the 0-based end offset.
--               - SetDocNum's `exists $$obj{DocNum}` for an undefined
--                 document number (the root) stores `false` instead of undef.
--               - ProcessContents' `$Image::ExifTool::static_vars{...}` hack
--                 writes ExifTool.static_vars, which the description form of
--                 GetFileType reads.
--               - `use Image::ExifTool::ASF` (for GetGUID) is a require at
--                 the two call sites: ASF loads RIFF, whose Composite table
--                 would otherwise join every later extraction.
--               - ProcessHyperlinks pushes '' for a missing address, where
--                 upstream pushes undef (a Lua array cannot hold nil).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')            -- (upstream `use Image::ExifTool::Exif`)
-- (upstream `use Image::ExifTool::ASF;   # for GetGUID()`: required at the
--  call sites, since ASF pulls in RIFF and its Composite tags)
local Microsoft = require('lexiftool.Microsoft')  -- for %codePage
local RandomAccess = require('lexiftool.RandomAccess')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local tr = perl.tr
local uc = perl.uc
local hex = perl.hex
local join = perl.join
local length = perl.length
local substr = perl.substr
local sprintf = perl.sprintf
local unpack = perl.unpack
local at = perl.at
local str = perl.str
local truthy = perl.truthy
local uv = perl.uv
local tsort = perl.tsort
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local Get64u = ExifTool.Get64u
local GetDouble = ExifTool.GetDouble
local SetByteOrder = ExifTool.SetByteOrder
local ToggleByteOrder = ExifTool.ToggleByteOrder
local ReadValue = ExifTool.ReadValue
local FormatSize = ExifTool.FormatSize
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ConvertUnixTime = ExifTool.ConvertUnixTime
local ConvertTimeSpan = ExifTool.ConvertTimeSpan

local FlashPix = {}

-- (upstream's predeclarations `sub ProcessFPX($$);` ... are this block of
--  locals; the subs below assign to them)
local ProcessFPX, ProcessFPXR, ProcessProperties, ReadFPXValue
local ProcessHyperlinks, ProcessContents, ProcessWordDocument
local ProcessDocumentTable, ProcessCommentBy, ProcessLastSavedBy
local SetDocNum, ConvertDTTM

-- sector type constants
local function HDR_SIZE           () return 512 end
local function DIF_SECT           () return 0xfffffffc end -- luacheck: ignore 211
local function FAT_SECT           () return 0xfffffffd end -- luacheck: ignore 211
local function END_OF_CHAIN       () return 0xfffffffe end
local function FREE_SECT          () return 0xffffffff end

-- format flags
local function VT_VECTOR          () return 0x1000 end
local function VT_ARRAY           () return 0x2000 end -- luacheck: ignore 211
local function VT_BYREF           () return 0x4000 end -- luacheck: ignore 211
local function VT_RESERVED        () return 0x8000 end -- luacheck: ignore 211

-- other constants
local function VT_VARIANT         () return 12 end
local function VT_LPSTR           () return 30 end -- luacheck: ignore 211
FlashPix.VT_VARIANT = VT_VARIANT

-- list of OLE format codes (unsupported codes commented out)
local oleFormat = {
    [0]  = nil,          -- VT_EMPTY
    [1]  = nil,          -- VT_NULL
    [2]  = 'int16s',     -- VT_I2
    [3]  = 'int32s',     -- VT_I4
    [4]  = 'float',      -- VT_R4
    [5]  = 'double',     -- VT_R8
    [6]  = nil,          -- VT_CY
    [7]  = 'VT_DATE',    -- VT_DATE (double, number of days since Dec 30, 1899)
    [8]  = 'VT_BSTR',    -- VT_BSTR (int32u count, followed by binary string)
--  [9]  = 'VT_DISPATCH',
    [10] = 'int32s',     -- VT_ERROR
    [11] = 'int16s',     -- VT_BOOL
    [12] = 'VT_VARIANT', -- VT_VARIANT
--  [13] = 'VT_UNKNOWN',
--  [14] = 'VT_DECIMAL',
    [16] = 'int8s',      -- VT_I1
    [17] = 'int8u',      -- VT_UI1
    [18] = 'int16u',     -- VT_UI2
    [19] = 'int32u',     -- VT_UI4
    [20] = 'int64s',     -- VT_I8
    [21] = 'int64u',     -- VT_UI8
--  [22] = 'VT_INT',
--  [23] = 'VT_UINT',
--  [24] = 'VT_VOID',
--  [25] = 'VT_HRESULT',
--  [26] = 'VT_PTR',
--  [27] = 'VT_SAFEARRAY',
--  [28] = 'VT_CARRAY',
--  [29] = 'VT_USERDEFINED',
    [30] = 'VT_LPSTR',   -- VT_LPSTR (int32u count, followed by string)
    [31] = 'VT_LPWSTR',  -- VT_LPWSTR (int32u word count, followed by Unicode string)
    [64] = 'VT_FILETIME',-- VT_FILETIME (int64u, 100 ns increments since Jan 1, 1601)
    [65] = 'VT_BLOB',    -- VT_BLOB
--  [66] = 'VT_STREAM',
--  [67] = 'VT_STORAGE',
--  [68] = 'VT_STREAMED_OBJECT',
--  [69] = 'VT_STORED_OBJECT',
--  [70] = 'VT_BLOB_OBJECT',
    [71] = 'VT_CF',      -- VT_CF
    [72] = 'VT_CLSID',   -- VT_CLSID
}

-- OLE flag codes (high nibble of property type)
local oleFlags = {
    [0x1000] = 'VT_VECTOR',
    [0x2000] = 'VT_ARRAY',  -- not yet supported
    [0x4000] = 'VT_BYREF',  -- ditto
    [0x8000] = 'VT_RESERVED',
}

-- byte sizes for supported VT_* format and flag types
local oleFormatSize = {
    VT_DATE     = 8,
    VT_BSTR     = 4,    -- (+ string length)
    VT_VARIANT  = 4,    -- (+ data length)
    VT_LPSTR    = 4,    -- (+ string length)
    VT_LPWSTR   = 4,    -- (+ string character length)
    VT_FILETIME = 8,
    VT_BLOB     = 4,    -- (+ data length)
    VT_CF       = 4,    -- (+ data length)
    VT_CLSID    = 16,
    VT_VECTOR   = 4,    -- (+ vector elements)
}

-- names for each type of directory entry
local dirEntryType = { [0] = 'INVALID', 'STORAGE', 'STREAM', 'LOCKBYTES', 'PROPERTY', 'ROOT' }

-- test for file extensions which may be variants of the FPX format
-- (have seen one password-protected DOCX file that is FPX-like, so assume
--  that all the rest could be as well)
local fpxFileType = {
    DOC = 1,  DOCX = 1,  DOCM = 1,
    DOT = 1,  DOTX = 1,  DOTM = 1,
    POT = 1,  POTX = 1,  POTM = 1,
    PPS = 1,  PPSX = 1,  PPSM = 1,
    PPT = 1,  PPTX = 1,  PPTM = 1,  THMX = 1,
    XLA = 1,  XLAM = 1,
    XLS = 1,  XLSX = 1,  XLSM = 1,  XLSB = 1,
    XLT = 1,  XLTX = 1,  XLTM = 1,
    -- non MSOffice types
    FLA = 1,  VSD  = 1,
}

FlashPix.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    VARS = { LONG_TAGS = 0 },
    NOTES = [[
        The FlashPix file format, introduced in 1996, was developed by Kodak,
        Hewlett-Packard and Microsoft.  Internally the FPX file structure mimics
        that of an old DOS disk with fixed-sized "sectors" (usually 512 bytes) and a
        "file allocation table" (FAT).  No wonder this image format never became
        popular.  However, some of the structures used in FlashPix streams are part
        of the EXIF specification, and are still being used in the APP2 FPXR segment
        of JPEG images by some digital cameras from manufacturers such as FujiFilm,
        Hewlett-Packard, Kodak and Sanyo.

        ExifTool extracts FlashPix information from both FPX images and the APP2
        FPXR segment of JPEG images.  As well, FlashPix information is extracted
        from DOC, PPT, XLS (Microsoft Word, PowerPoint and Excel) documents, VSD
        (Microsoft Visio) drawings, and FLA (Macromedia/Adobe Flash project) files
        since these are based on the same file format as FlashPix (the Windows
        Compound Binary File format).  Note that ExifTool identifies any
        unrecognized Windows Compound Binary file as a FlashPix (FPX) file.  See
        L<http://graphcomp.com/info/specs/livepicture/fpx.pdf> for the FlashPix
        specification.

        Note that Microsoft is not consistent with the time zone used for some
        date/time tags, and it may be either UTC or local time depending on the
        software used to create the file.
    ]],
    ["\x05SummaryInformation"] = {
        Name = 'SummaryInfo',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.SummaryInfo',
        },
    },
    ["\x05DocumentSummaryInformation"] = {
        Name = 'DocumentInfo',
        Multi = 1, -- flag to process UserDefined information after this
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.DocumentInfo',
        },
    },
    ["\x01CompObj"] = {
        Name = 'CompObj',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.CompObj',
            DirStart = 0x1c,    -- skip stream header
        },
    },
    ["\x05Image Info"] = {
        Name = 'ImageInfo',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.ImageInfo',
        },
    },
    ["\x05Image Contents"] = {
        Name = 'Image',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.Image',
        },
    },
    ["Contents"] = {
        Name = 'Contents',
        Notes = 'found in FLA files; may contain XMP',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
            ProcessProc = function(...) return ProcessContents(...) end,
        },
    },
    ["ICC Profile 0001"] = {
        Name = 'ICC_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
            DirStart = 0x1c,    -- skip stream header
        },
    },
    ["\x05Extension List"] = {
        Name = 'Extensions',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.Extensions',
        },
    },
    ['Subimage 0000 Header'] = {
        Name = 'SubimageHdr',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.SubimageHdr',
            DirStart = 0x1c,    -- skip stream header
        },
    },
--  'Subimage 0000 Data'
    ["\x05Data Object"] = {  -- plus instance number (eg. " 000000")
        Name = 'DataObject',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.DataObject',
        },
    },
--  ["\x05Data Object Store"] = { -- plus instance number (eg. " 000000")
    ["\x05Transform"] = {    -- plus instance number (eg. " 000000")
        Name = 'Transform',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.Transform',
        },
    },
    ["\x05Operation"] = {    -- plus instance number (eg. " 000000")
        Name = 'Operation',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.Operation',
        },
    },
    ["\x05Global Info"] = {
        Name = 'GlobalInfo',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.GlobalInfo',
        },
    },
    ["\x05Screen Nail"] = { -- plus class ID (eg. "_bd0100609719a180")
        Name = 'ScreenNail',
        Groups = { [2] = 'Other' },
        -- strip off stream header
        ValueConv = function(_self, val) if length(val) > 0x1c then val = substr(val, 0x1c) end return { ref = 'SCALAR', value = val } end,
    },
    ["\x05Audio Info"] = {
        Name = 'AudioInfo',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.AudioInfo',
        },
    },
    ['Audio Stream'] = { -- plus instance number (eg. " 000000")
        Name = 'AudioStream',
        Groups = { [2] = 'Audio' },
        -- strip off stream header
        ValueConv = function(_self, val) if length(val) > 0x1c then val = substr(val, 0x1c) end return { ref = 'SCALAR', value = val } end,
    },
    ['Current User'] = { --PH
        Name = 'CurrentUser',
        -- not sure what the rest of this data is, but extract ASCII name from it - PH
        ValueConv = function(_self, val)
            if length(val) < 12 then return nil end
            local size, pos = unpack('x4VV', val)
            local len = size - pos - 4
            if len < 0 or length(val) < size + 8 then return nil end
            return substr(val, 8 + pos, len)
        end,
    },
    ['WordDocument'] = {
        Name = 'WordDocument',
        SubDirectory = { TagTable = 'lexiftool.FlashPix.WordDocument' },
    },
    -- save these tables until after the WordDocument was processed
    ['0Table'] = {
        Name = 'Table0',
        Hidden = 2, -- (used only as temporary storage until table is processed)
        Binary = 1,
    },
    ['1Table'] = {
        Name = 'Table1',
        Hidden = 2, -- (used only as temporary storage until table is processed)
        Binary = 1,
    },
    Preview = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
        Notes = 'written by some FujiFilm models',
        -- skip 47-byte Fuji header
        RawConv = function(_self, val)
            if length(val) <= 47 then return nil end
            val = substr(val, 47)
            if isMatch(val, [[^\xff\xd8\xff]]) then return val end
            return nil
        end,
    },
    Property = {
        Name = 'PreviewInfo',
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.PreviewInfo',
            ByteOrder = 'BigEndian',
        },
    },
    -- recognize Autodesk Revit files by looking at BasicFileInfo
    -- (but don't yet support reading their metatdata)
    BasicFileInfo = {
        Name = 'BasicFileInfo',
        Binary = 1,
        RawConv = function(self, val)
            val = tr(val, [[\0]], '', 'd')   -- brute force conversion to ASCII
            local m1 = matches(val, [[\.(rfa|rft|rte|rvt)]])
            if m1 then
                self:OverrideFileType(uc(m1), 'application/' .. m1, m1)
            end
            return val
        end,
    },
    IeImg = {
        Name = 'EmbeddedImage',
        Notes = [[
            embedded images in Scene7 vignette VNT files.  The EmbeddedImage Class and
            Rectangle are also extracted for applicable images, and may be associated
            with the corresponding EmbeddedImage via the family 3 group name
        ]],
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    IeImg_class = {
        Name = 'EmbeddedImageClass',
        Notes = [[
            not a real tag.  This information is extracted if available for the
            corresponding EmbeddedImage from the Contents of a VNT file
        ]],
        -- eg. "Cache", "Mask"
    },
    IeImg_rect = { --
        Name = 'EmbeddedImageRectangle',
        Notes = [[
            not a real tag.  This information is extracted if available for the
            corresponding EmbeddedImage from the Contents of a VNT file
        ]],
    },
    _eeJPG = {
        Name = 'EmbeddedImage',
        Notes = [[
            Not a real tag. Extracted from stream content when the ExtractEmbedded
            option is used
        ]],
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    _eePNG = {
        Name = 'EmbeddedPNG',
        Notes = [[
            Not a real tag. Extracted from stream content when the ExtractEmbedded
            option is used
        ]],
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    _eeLink = {
        Name = 'LinkedFileName',
        Notes = [[
            Not a real tag. Extracted from stream content when the ExtractEmbedded
            option is used
        ]],
    },
}

-- Summary Information properties
FlashPix.SummaryInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        The Dictionary, CodePage and LocalIndicator tags are common to all FlashPix
        property tables, even though they are only listed in the SummaryInfo table.
    ]],
    [0x00] = { Name = 'Dictionary',     Groups = { [2] = 'Other' }, Binary = 1 },
    [0x01] = {
        Name = 'CodePage',
        Groups = { [2] = 'Other' },
        SeparateTable = 'Microsoft CodePage',
        PrintConv = Microsoft.codePage,
    },
    [0x02] = 'Title',
    [0x03] = 'Subject',
    [0x04] = { Name = 'Author',         Groups = { [2] = 'Author' } },
    [0x05] = 'Keywords',
    [0x06] = 'Comments',
    [0x07] = 'Template',
    [0x08] = { Name = 'LastModifiedBy', Groups = { [2] = 'Author' } },
    [0x09] = 'RevisionNumber',
    [0x0a] = { Name = 'TotalEditTime',  PrintConv = function(_self, val) return ConvertTimeSpan(val) end }, -- (in sec)
    [0x0b] = { Name = 'LastPrinted',    Groups = { [2] = 'Time' } },
    [0x0c] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x0d] = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x0e] = 'Pages',
    [0x0f] = 'Words',
    [0x10] = 'Characters',
    [0x11] = {
        Name = 'ThumbnailClip',
        -- (not a displayable format, so not in the "Preview" group)
        Binary = 1,
    },
    [0x12] = {
        Name = 'Software',
        RawConv = function(self, val) self.Software = val return val end, -- (use to determine file type)
    },
    [0x13] = {
        Name = 'Security',
        -- see http://msdn.microsoft.com/en-us/library/aa379255(VS.85).aspx
        PrintConv = {
            [0] = 'None',
            BITMASK = {
                [0] = 'Password protected',
                [1] = 'Read-only recommended',
                [2] = 'Read-only enforced',
                [3] = 'Locked for annotations',
            },
        },
    },
    [0x22] = { Name = 'CreatedBy', Groups = { [2] = 'Author' } }, --PH (guess) (MAX files)
    [0x23] = 'DocumentID', -- PH (guess) (MAX files)
  -- 0x25 ? seen values 1.0-1.97 (MAX files)
    [0x80000000] = { Name = 'LocaleIndicator', Groups = { [2] = 'Other' } },
}

-- Document Summary Information properties (ref 4)
FlashPix.DocumentInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        The DocumentSummaryInformation property set includes a UserDefined property
        set for which only the Hyperlinks and HyperlinkBase tags are pre-defined.
        However, ExifTool will also extract any other information found in the
        UserDefined properties.
    ]],
  -- 0x01 => 'CodePage', #7
    [0x02] = 'Category',
    [0x03] = 'PresentationTarget',
    [0x04] = 'Bytes',
    [0x05] = 'Lines',
    [0x06] = 'Paragraphs',
    [0x07] = 'Slides',
    [0x08] = 'Notes',
    [0x09] = 'HiddenSlides',
    [0x0a] = 'MMClips',
    [0x0b] = {
        Name = 'ScaleCrop',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x0c] = 'HeadingPairs',
    [0x0d] = {
        Name = 'TitleOfParts',
        -- look for "3ds Max" software name at beginning of TitleOfParts
        RawConv = function(self, val)
            local v = val
            if type(val) == 'table' and val.ref == nil then v = val[1] end
            local m1 = matches(v, [[^(3ds Max)]])
            if m1 then self.Software = m1 end
            return val
        end
    },
    [0x0e] = 'Manager',
    [0x0f] = 'Company',
    [0x10] = {
        Name = 'LinksUpToDate',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x11] = 'CharCountWithSpaces',
  -- 0x12 ? seen -32.1850395202637,-386.220672607422,-9.8100004196167,-9810,...
    [0x13] = { --PH (unconfirmed)
        Name = 'SharedDoc',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
  -- 0x14 ? seen -1
  -- 0x15 ? seen 1
    [0x16] = {
        Name = 'HyperlinksChanged',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x17] = { --PH (unconfirmed handling of lower 16 bits, not valid for MAX files)
        Name = 'AppVersion',
        ValueConv = function(_self, val) return sprintf('%d.%.4d', val >> 16, val & 0xffff) end,
    },
  -- 0x18 ? seen -1 (DigitalSignature, VtDigSig format, ref 7)
  -- 0x19 ? seen 0
  -- 0x1a ? seen 0
  -- 0x1b ? seen 0
  -- 0x1c ? seen 0,1
  -- 0x1d ? seen 1
    [0x1a] = 'ContentType', --7, github#217
    [0x1b] = 'ContentStatus', --7, github#217
    [0x1c] = 'Language', --7, github#217
    [0x1d] = 'DocVersion', --7, github#217
  -- 0x1e ? seen 1
  -- 0x1f ? seen 1,5
  -- 0x20 ? seen 0,5
  -- 0x21 ? seen -1
  -- 0x22 ? seen 0
   ['_PID_LINKBASE'] = {
        Name = 'HyperlinkBase',
        ValueConv = function(self, val) return self:Decode(val, 'UTF16', 'II') end,
    },
   ['_PID_HLINKS'] = {
        Name = 'Hyperlinks',
        RawConv = function(self, val) return ProcessHyperlinks(val, self) end,
    },
}

-- Image Information properties
FlashPix.ImageInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    [0x21000000] = {
        Name = 'FileSource',
        PrintConv = {
            [1] = 'Film Scanner',
            [2] = 'Reflection Print Scanner',
            [3] = 'Digital Camera',
            [4] = 'Video Capture',
            [5] = 'Computer Graphics',
        },
    },
    [0x21000001] = {
        Name = 'SceneType',
        PrintConv = {
            [1] = 'Original Scene',
            [2] = 'Second Generation Scene',
            [3] = 'Digital Scene Generation',
        },
    },
    [0x21000002] = 'CreationPathVector',
    [0x21000003] = 'SoftwareRelease',
    [0x21000004] = 'UserDefinedID',
    [0x21000005] = 'SharpnessApproximation',
    [0x22000000] = { Name = 'Copyright',                 Groups = { [2] = 'Author' } },
    [0x22000001] = { Name = 'OriginalImageBroker',       Groups = { [2] = 'Author' } },
    [0x22000002] = { Name = 'DigitalImageBroker',        Groups = { [2] = 'Author' } },
    [0x22000003] = { Name = 'Authorship',                Groups = { [2] = 'Author' } },
    [0x22000004] = { Name = 'IntellectualPropertyNotes', Groups = { [2] = 'Author' } },
    [0x23000000] = {
        Name = 'TestTarget',
        PrintConv = {
            [1] = 'Color Chart',
            [2] = 'Gray Card',
            [3] = 'Grayscale',
            [4] = 'Resolution Chart',
            [5] = 'Inch Scale',
            [6] = 'Centimeter Scale',
            [7] = 'Millimeter Scale',
            [8] = 'Micrometer Scale',
        },
    },
    [0x23000002] = 'GroupCaption',
    [0x23000003] = 'CaptionText',
    [0x23000004] = 'People',
    [0x23000007] = 'Things',
    [0x2300000A] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x2300000B] = 'Events',
    [0x2300000C] = 'Places',
    [0x2300000F] = 'ContentDescriptionNotes',
    [0x24000000] = { Name = 'Make',             Groups = { [2] = 'Camera' } },
    [0x24000001] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Groups = { [2] = 'Camera' },
    },
    [0x24000002] = { Name = 'SerialNumber',     Groups = { [2] = 'Camera' } },
    [0x25000000] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x25000001] = {
        Name = 'ExposureTime',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x25000002] = {
        Name = 'FNumber',
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x25000003] = {
        Name = 'ExposureProgram',
        Groups = { [2] = 'Camera' },
        -- use PrintConv of corresponding EXIF tag
        PrintConv = Exif.Main[0x8822].PrintConv,
    },
    [0x25000004] = 'BrightnessValue',
    [0x25000005] = 'ExposureCompensation',
    [0x25000006] = {
        Name = 'SubjectDistance',
        Groups = { [2] = 'Camera' },
        PrintConv = function(_self, val) return sprintf('%.3f m', val) end,
    },
    [0x25000007] = {
        Name = 'MeteringMode',
        Groups = { [2] = 'Camera' },
        PrintConv = Exif.Main[0x9207].PrintConv,
    },
    [0x25000008] = {
        Name = 'LightSource',
        Groups = { [2] = 'Camera' },
        PrintConv = Exif.Main[0x9208].PrintConv,
    },
    [0x25000009] = {
        Name = 'FocalLength',
        Groups = { [2] = 'Camera' },
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
    },
    [0x2500000A] = {
        Name = 'MaxApertureValue',
        Groups = { [2] = 'Camera' },
        ValueConv = function(_self, val) return 2 ^ (val / 2) end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x2500000B] = {
        Name = 'Flash',
        Groups = { [2] = 'Camera' },
        PrintConv = {
            [1] = 'No Flash',
            [2] = 'Flash Fired',
        },
    },
    [0x2500000C] = {
        Name = 'FlashEnergy',
        Groups = { [2] = 'Camera' },
    },
    [0x2500000D] = {
        Name = 'FlashReturn',
        Groups = { [2] = 'Camera' },
        PrintConv = {
            [1] = 'Subject Outside Flash Range',
            [2] = 'Subject Inside Flash Range',
        },
    },
    [0x2500000E] = {
        Name = 'Backlight',
        PrintConv = {
            [1] = 'Front Lit',
            [2] = 'Back Lit 1',
            [3] = 'Back Lit 2',
        },
    },
    [0x2500000F] = { Name = 'SubjectLocation', Groups = { [2] = 'Camera' } },
    [0x25000010] = 'ExposureIndex',
    [0x25000011] = {
        Name = 'SpecialEffectsOpticalFilter',
        PrintConv = {
            [1] = 'None',
            [2] = 'Colored',
            [3] = 'Diffusion',
            [4] = 'Multi-image',
            [5] = 'Polarizing',
            [6] = 'Split-field',
            [7] = 'Star',
        },
    },
    [0x25000012] = 'PerPictureNotes',
    [0x26000000] = {
        Name = 'SensingMethod',
        Groups = { [2] = 'Camera' },
        PrintConv = Exif.Main[0x9217].PrintConv,
    },
    [0x26000001] = { Name = 'FocalPlaneXResolution', Groups = { [2] = 'Camera' } },
    [0x26000002] = { Name = 'FocalPlaneYResolution', Groups = { [2] = 'Camera' } },
    [0x26000003] = {
        Name = 'FocalPlaneResolutionUnit',
        Groups = { [2] = 'Camera' },
        PrintConv = Exif.Main[0xa210].PrintConv,
    },
    [0x26000004] = 'SpatialFrequencyResponse',
    [0x26000005] = 'CFAPattern',
    -- (upstream defines 0x27000001 twice: this FilmCategory PrintConv first,
    --  then the bare 'FilmCategory' string below -- in Perl the later one
    --  wins, so the PrintConv never takes effect.  Kept here as a comment
    --  rather than as a second Lua key, which would read as a typo)
--  [0x27000001] = {
--      Name = 'FilmCategory',
--      PrintConv = {
--          [1] = 'Negative B&W',
--          [2] = 'Negative Color',
--          [3] = 'Reversal B&W',
--          [4] = 'Reversal Color',
--          [5] = 'Chromagenic',
--          [6] = 'Internegative B&W',
--          [7] = 'Internegative Color',
--      },
--  },
    [0x26000007] = 'ISO',
    [0x26000008] = 'Opto-ElectricConvFactor',
    [0x27000000] = 'FilmBrand',
    [0x27000001] = 'FilmCategory',
    [0x27000002] = 'FilmSize',
    [0x27000003] = 'FilmRollNumber',
    [0x27000004] = 'FilmFrameNumber',
    [0x29000000] = 'OriginalScannedImageSize',
    [0x29000001] = 'OriginalDocumentSize',
    [0x29000002] = {
        Name = 'OriginalMedium',
        PrintConv = {
            [1] = 'Continuous Tone Image',
            [2] = 'Halftone Image',
            [3] = 'Line Art',
        },
    },
    [0x29000003] = {
        Name = 'TypeOfOriginal',
        PrintConv = {
            [1] = 'B&W Print',
            [2] = 'Color Print',
            [3] = 'B&W Document',
            [4] = 'Color Document',
        },
    },
    [0x28000000] = 'ScannerMake',
    [0x28000001] = 'ScannerModel',
    [0x28000002] = 'ScannerSerialNumber',
    [0x28000003] = 'ScanSoftware',
    [0x28000004] = { Name = 'ScanSoftwareRevisionDate', Groups = { [2] = 'Time' } },
    [0x28000005] = 'ServiceOrganizationName',
    [0x28000006] = 'ScanOperatorID',
    [0x28000008] = {
        Name = 'ScanDate',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x28000009] = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x2800000A] = 'ScannerPixelSize',
}

-- Image Contents properties
FlashPix.Image = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    -- VARS storage is used as a hash lookup for tagID's which aren't constant.
    -- The key is a mask for significant bits of the tagID, and the value
    -- is a lookup for tagID's for which this mask is valid.
    VARS = {
        -- ID's are different for each subimage
        [0xff00ffff] = {
            [0x02000000]=1, [0x02000001]=1, [0x02000002]=1, [0x02000003]=1,
            [0x02000004]=1, [0x02000005]=1, [0x02000006]=1, [0x02000007]=1,
            [0x03000001]=1,
        },
    },
    [0x01000000] = 'NumberOfResolutions',
    [0x01000002] = 'ImageWidth',     -- width of highest resolution image
    [0x01000003] = 'ImageHeight',
    [0x01000004] = 'DefaultDisplayHeight',
    [0x01000005] = 'DefaultDisplayWidth',
    [0x01000006] = {
        Name = 'DisplayUnits',
        PrintConv = {
            [0] = 'inches',
            [1] = 'meters',
            [2] = 'cm',
            [3] = 'mm',
        },
    },
    [0x02000000] = 'SubimageWidth',
    [0x02000001] = 'SubimageHeight',
    [0x02000002] = {
        Name = 'SubimageColor',
        -- decode only component count and color space of first component
        ValueConv = function(_self, val) return sprintf('%.2x %.4x', unpack('x4vx4v', val)) end,
        PrintConv = {
            ['01 0000'] = 'Opacity Only',
            ['01 8000'] = 'Opacity Only (uncalibrated)',
            ['01 0001'] = 'Monochrome',
            ['01 8001'] = 'Monochrome (uncalibrated)',
            ['03 0002'] = 'YCbCr',
            ['03 8002'] = 'YCbCr (uncalibrated)',
            ['03 0003'] = 'RGB',
            ['03 8003'] = 'RGB (uncalibrated)',
            ['04 0002'] = 'YCbCr with Opacity',
            ['04 8002'] = 'YCbCr with Opacity (uncalibrated)',
            ['04 0003'] = 'RGB with Opacity',
            ['04 8003'] = 'RGB with Opacity (uncalibrated)',
        },
    },
    [0x02000003] = {
        Name = 'SubimageNumericalFormat',
        PrintConv = {
            [17] = '8-bit, Unsigned',
            [18] = '16-bit, Unsigned',
            [19] = '32-bit, Unsigned',
        },
    },
    [0x02000004] = {
        Name = 'DecimationMethod',
        PrintConv = {
            [0] = 'None (Full-sized Image)',
            [8] = '8-point Prefilter',
        },
    },
    [0x02000005] = 'DecimationPrefilterWidth',
    [0x02000007] = 'SubimageICC_Profile',
    [0x03000001] = { Name = 'JPEGTables', Binary = 1 },
    [0x03000002] = 'MaxJPEGTableIndex',
}

-- Extension List properties
FlashPix.Extensions = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Other' },
    VARS = {
        -- ID's are different for each extension type
        [0x0000ffff] = {
            [0x0001]=1, [0x0002]=1, [0x0003]=1, [0x0004]=1,
            [0x0005]=1, [0x0006]=1, [0x0007]=1, [0x1000]=1,
            [0x2000]=1, [0x2001]=1, [0x3000]=1, [0x4000]=1,
        },
        [0x0000f00f] = { [0x3001]=1, [0x3002]=1 },
    },
    [0x10000000] = 'UsedExtensionNumbers',
    [0x0001] = 'ExtensionName',
    [0x0002] = 'ExtensionClassID',
    [0x0003] = {
        Name = 'ExtensionPersistence',
        PrintConv = {
            [0] = 'Always Valid',
            [1] = 'Invalidated By Modification',
            [2] = 'Potentially Invalidated By Modification',
        },
    },
    [0x0004] = { Name = 'ExtensionCreateDate', Groups = { [2] = 'Time' } },
    [0x0005] = { Name = 'ExtensionModifyDate', Groups = { [2] = 'Time' } },
    [0x0006] = 'CreatingApplication',
    [0x0007] = 'ExtensionDescription',
    [0x1000] = 'Storage-StreamPathname',
    [0x2000] = 'FlashPixStreamPathname',
    [0x2001] = 'FlashPixStreamFieldOffset',
    [0x3000] = 'PropertySetPathname',
    [0x3001] = 'PropertySetIDCodes',
    [0x3002] = 'PropertyVectorElements',
    [0x4000] = 'SubimageResolutions',
}

-- Subimage Header tags
FlashPix.SubimageHdr = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int32u',
--  [0] = 'HeaderLength',
    [1] = 'SubimageWidth',
    [2] = 'SubimageHeight',
    [3] = 'SubimageTileCount',
    [4] = 'SubimageTileWidth',
    [5] = 'SubimageTileHeight',
    [6] = 'NumChannels',
--  [7] = 'TileHeaderOffset',
--  [8] = 'TileHeaderLength',
    -- ... followed by tile header table
}

-- Data Object properties
FlashPix.DataObject = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Other' },
    [0x00010000] = 'DataObjectID',
    [0x00010002] = 'LockedPropertyList',
    [0x00010003] = 'DataObjectTitle',
    [0x00010004] = 'LastModifier',
    [0x00010005] = 'RevisionNumber',
    [0x00010006] = { Name = 'DataCreateDate', Groups = { [2] = 'Time' } },
    [0x00010007] = { Name = 'DataModifyDate', Groups = { [2] = 'Time' } },
    [0x00010008] = 'CreatingApplication',
    [0x00010100] = {
        Name = 'DataObjectStatus',
        PrintConv = function(_self, val)
            return ((val & 0x0000ffff) ~= 0 and 'Exists' or 'Does Not Exist') ..
            ', ' .. ((val & 0xffff0000) ~= 0 and 'Not ' or '') .. 'Purgeable'
        end,
    },
    [0x00010101] = {
        Name = 'CreatingTransform',
        PrintConv = function(_self, val) return truthy(val) and val or 'Source Image' end,
    },
    [0x00010102] = 'UsingTransforms',
    [0x10000000] = 'CachedImageHeight',
    [0x10000001] = 'CachedImageWidth',
}

-- Transform properties
FlashPix.Transform = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Other' },
    [0x00010000] = 'TransformNodeID',
    [0x00010001] = 'OperationClassID',
    [0x00010002] = 'LockedPropertyList',
    [0x00010003] = 'TransformTitle',
    [0x00010004] = 'LastModifier',
    [0x00010005] = 'RevisionNumber',
    [0x00010006] = { Name = 'TransformCreateDate', Groups = { [2] = 'Time' } },
    [0x00010007] = { Name = 'TransformModifyDate', Groups = { [2] = 'Time' } },
    [0x00010008] = 'CreatingApplication',
    [0x00010100] = 'InputDataObjectList',
    [0x00010101] = 'OutputDataObjectList',
    [0x00010102] = 'OperationNumber',
    [0x10000000] = 'ResultAspectRatio',
    [0x10000001] = 'RectangleOfInterest',
    [0x10000002] = 'Filtering',
    [0x10000003] = 'SpatialOrientation',
    [0x10000004] = 'ColorTwistMatrix',
    [0x10000005] = 'ContrastAdjustment',
}

-- Operation properties
FlashPix.Operation = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    [0x00010000] = 'OperationID',
}

-- Global Info properties
FlashPix.GlobalInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    [0x00010002] = 'LockedPropertyList',
    [0x00010003] = 'TransformedImageTitle',
    [0x00010004] = 'LastModifier',
    [0x00010100] = 'VisibleOutputs',
    [0x00010101] = 'MaximumImageIndex',
    [0x00010102] = 'MaximumTransformIndex',
    [0x00010103] = 'MaximumOperationIndex',
}

-- Audio Info properties
FlashPix.AudioInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Audio' },
}

-- MacroMedia flash contents
FlashPix.Contents = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    OriginalFileName = { Name = 'OriginalFileName', Hidden = 1 }, -- (not a real tag -- extracted from Contents of VNT file)
}

-- CompObj tags
FlashPix.CompObj = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int32u',
    [0] = { Name = 'CompObjUserTypeLen' },
    [1] = {
        Name = 'CompObjUserType',
        Format = 'string[$val{0}]',
        RawConv = function(self, val) self.CompObjUserType = val return val end, -- (use to determine file type)
    },
}

-- decode Word document FIB header (ref [MS-DOC].pdf)
FlashPix.WordDocument = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int16u',
    NOTES = 'Tags extracted from the Microsoft Word document stream.',
    [0] = {
        Name = 'Identification',
        PrintHex = 1,
        PrintConv = {
            [0x6a62] = 'MS Word 97',
            [0x626a] = 'Word 98 Mac',
            [0xa5dc] = 'Word 6.0/7.0',
            [0xa5ec] = 'Word 8.0',
        },
    },
    [3] = {
        Name = 'LanguageCode',
        PrintHex = 1,
        PrintConv = {
            [0x0400] = 'None',
            [0x0401] = 'Arabic',
            [0x0402] = 'Bulgarian',
            [0x0403] = 'Catalan',
            [0x0404] = 'Traditional Chinese',
            [0x0804] = 'Simplified Chinese',
            [0x0405] = 'Czech',
            [0x0406] = 'Danish',
            [0x0407] = 'German',
            [0x0807] = 'German (Swiss)',
            [0x0408] = 'Greek',
            [0x0409] = 'English (US)',
            [0x0809] = 'English (British)',
            [0x0c09] = 'English (Australian)',
            [0x040a] = 'Spanish (Castilian)',
            [0x080a] = 'Spanish (Mexican)',
            [0x040b] = 'Finnish',
            [0x040c] = 'French',
            [0x080c] = 'French (Belgian)',
            [0x0c0c] = 'French (Canadian)',
            [0x100c] = 'French (Swiss)',
            [0x040d] = 'Hebrew',
            [0x040e] = 'Hungarian',
            [0x040f] = 'Icelandic',
            [0x0410] = 'Italian',
            [0x0810] = 'Italian (Swiss)',
            [0x0411] = 'Japanese',
            [0x0412] = 'Korean',
            [0x0413] = 'Dutch',
            [0x0813] = 'Dutch (Belgian)',
            [0x0414] = 'Norwegian (Bokmal)',
            [0x0814] = 'Norwegian (Nynorsk)',
            [0x0415] = 'Polish',
            [0x0416] = 'Portuguese (Brazilian)',
            [0x0816] = 'Portuguese',
            [0x0417] = 'Rhaeto-Romanic',
            [0x0418] = 'Romanian',
            [0x0419] = 'Russian',
            [0x041a] = 'Croato-Serbian (Latin)',
            [0x081a] = 'Serbo-Croatian (Cyrillic)',
            [0x041b] = 'Slovak',
            [0x041c] = 'Albanian',
            [0x041d] = 'Swedish',
            [0x041e] = 'Thai',
            [0x041f] = 'Turkish',
            [0x0420] = 'Urdu',
            [0x0421] = 'Bahasa',
            [0x0422] = 'Ukrainian',
            [0x0423] = 'Byelorussian',
            [0x0424] = 'Slovenian',
            [0x0425] = 'Estonian',
            [0x0426] = 'Latvian',
            [0x0427] = 'Lithuanian',
            [0x0429] = 'Farsi',
            [0x042d] = 'Basque',
            [0x042f] = 'Macedonian',
            [0x0436] = 'Afrikaans',
            [0x043e] = 'Malaysian',
        },
    },
    [5] = {
        Name = 'DocFlags',
        Mask = 0xff0f, -- ignore save count
        RawConv = function(self, val) self.DocFlags = val return val end,
        PrintConv = { BITMASK = {
            [0] = 'Template',
            [1] = 'AutoText only',
            [2] = 'Complex',
            [3] = 'Has picture',
            -- 4-7 = number of incremental saves
            [8] = 'Encrypted',
            [9] = '1Table',
            [10] = 'Read only',
            [11] = 'Passworded',
            [12] = 'ExtChar',
            [13] = 'Load override',
            [14] = 'Far east',
            [15] = 'Obfuscated',
        }},
    },
    [9.1] = {
        Name = 'System',
        Mask = 0x0001,
        PrintConv = {
            [0x0000] = 'Windows',
            [0x0001] = 'Macintosh',
        },
    },
    [9.2] = {
        Name = 'Word97',
        Mask = 0x0010,
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
}

-- tags decoded from Word document table
FlashPix.DocTable = {
    GROUPS = { [1] = 'MS-DOC', [2] = 'Document' },
    NOTES = 'Tags extracted from the Microsoft Word document table.',
    VARS = { ID_FMT = 'none' },
    CommentBy = {
        Groups = { [2] = 'Author' },
        Notes = 'enable L<Duplicates|../ExifTool.html#Duplicates> option to extract all entries',
    },
    LastSavedBy = {
        Groups = { [2] = 'Author' },
        Notes = 'enable L<Duplicates|../ExifTool.html#Duplicates> option to extract history of up to 10 entries',
    },
    DOP = { SubDirectory = { TagTable = 'lexiftool.FlashPix.DOP' } },
    ModifyDate = {
        Groups = { [2] = 'Time' },
        Format = 'int64u',
        Priority = 0,
        RawConv = function(_self, val)
            val = val * 1e-7 - 11644473600;   -- convert to seconds since 1970
            return val > 0 and val or nil
        end,
        ValueConv = function(_self, val) return ConvertUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
--
-- tags below are used internally in intermediate steps to extract the tags above
--
    TableOffsets = { Hidden = 2 }, -- stores offsets to extract data from document table
    CommentByBlock = {   -- entire block of CommentBy entries
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.DocTable',
            ProcessProc = function(...) return ProcessCommentBy(...) end,
        },
        Hidden = 2,
    },
    LastSavedByBlock = {   -- entire block of LastSavedBy entries
        SubDirectory = {
            TagTable = 'lexiftool.FlashPix.DocTable',
            ProcessProc = function(...) return ProcessLastSavedBy(...) end,
        },
        Hidden = 2,
    },
}

-- Microsoft Office Document Properties (ref [MS-DOC].pdf)
FlashPix.DOP = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'MS-DOC', [2] = 'Document' },
    NOTES = 'Microsoft office document properties.',
    [20] = {
        Name = 'CreateDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        Priority = 0,
        RawConv = function(_self, val) return ConvertDTTM(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [24] = {
        Name = 'ModifyDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        Priority = 0,
        RawConv = function(_self, val) return ConvertDTTM(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [28] = {
        Name = 'LastPrinted',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        RawConv = function(_self, val) return ConvertDTTM(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [32] = { Name = 'RevisionNumber', Format = 'int16u' },
    [34] = {
        Name = 'TotalEditTime',
        Format = 'int32u',
        PrintConv = function(_self, val) return ConvertTimeSpan(val, 60) end,
    },
    -- (according to the MS-DOC specification, the following are accurate only if
    -- flag 'X' is set, and flag 'u' specifies whether the main or subdoc tags are
    -- used, but in my tests it seems that both are filled in with reasonable values,
    -- so just extract the main counts and ignore the subdoc counts for now - PH)
    [38] = { Name = 'Words',      Format = 'int32u' },
    [42] = { Name = 'Characters', Format = 'int32u' },
    [46] = { Name = 'Pages',      Format = 'int16u' },
    [48] = { Name = 'Paragraphs', Format = 'int32u' },
    [56] = { Name = 'Lines',      Format = 'int32u' },
    --[60] = { Name = 'WordsWithSubdocs',      Format = 'int32u' },
    --[64] = { Name = 'CharactersWithSubdocs', Format = 'int32u' },
    --[68] = { Name = 'PagesWithSubdocs',      Format = 'int16u' },
    --[70] = { Name = 'ParagraphsWithSubdocs', Format = 'int32u' },
    --[74] = { Name = 'LinesWithSubdocs',      Format = 'int32u' },
}

-- FujiFilm "Property" information (ref PH)
FlashPix.PreviewInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'Preview information written by some FujiFilm models.',
    FIRST_ENTRY = 0,
    -- values are all constant for for my samples except the two decoded tags
    -- 0x0000: 01 01 00 00 02 01 00 00 00 00 00 00 00 xx xx 01
    -- 0x0010: 01 00 00 00 00 00 00 xx xx 00 00 00 00 00 00 00
    -- 0x0020: 00 00 00 00 00
    [0x0d] = {
        Name = 'PreviewImageWidth',
        Format = 'int16u',
    },
    [0x17] = {
        Name = 'PreviewImageHeight',
        Format = 'int16u',
    },
}

-- composite FlashPix tags
FlashPix.Composite = {
    GROUPS = { [2] = 'Image' },
    PreviewImage = {
        TagID = 'FlashPix-PreviewImage',
        Groups = { [2] = 'Preview' },
        -- extract JPEG preview from ScreenNail if possible
        Require = {
            [0] = 'ScreenNail',
        },
        Binary = 1,
        -- (upstream's `@grps = $self->GetGroup($$val{0})` is the SET_GROUP0/1
        --  side channel BuildCompositeTags hands to FoundTag)
        RawConv = function(self, val)
            local _, pos = matches(val[0], [[\xff\xd8\xff]])
            if not pos then return nil end
            self.SET_GROUP0 = self:GetGroup('ScreenNail', 0)  -- set groups from ScreenNail
            self.SET_GROUP1 = self:GetGroup('ScreenNail', 1)
            return substr(val[0], pos - 3)
        end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.FlashPix', nil, FlashPix)

--------------------------------------------------------------------------------
-- Convert Microsoft DTTM structure to date/time
-- Inputs: 0) DTTM value
-- Returns: EXIF-format date/time string ("0000:00:00 00:00:00" for zero date/time)
function ConvertDTTM(val)
    local yr  = (val >> 20) & 0x1ff
    local mon = (val >> 16) & 0x0f
    local day = (val >> 11) & 0x1f
    local hr  = (val >> 6)  & 0x1f
    local min = (val & 0x3f)
    if truthy(val) then yr = yr + 1900 end
    -- ExifTool 12.48 dropped the "Z" on the time here because a test .doc
    -- file written by Word 2011 on Mac certainly used local time here
    return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:00', yr, mon, day, hr, min)
end
FlashPix.ConvertDTTM = ConvertDTTM

--------------------------------------------------------------------------------
-- Process hyperlinks from PID_HYPERLINKS array
-- (ref http://msdn.microsoft.com/archive/default.asp?url=/archive/en-us/dnaro97ta/html/msdn_hyper97.asp)
-- Inputs: 0) value, 1) ExifTool ref
-- Returns: list of hyperlinks
function ProcessHyperlinks(val, et)

    -- process as an array of VT_VARIANT's
    local dirEnd = length(val)
    if dirEnd < 4 then return nil end
    local num = Get32u(val, 0)
    local valPos = 4
    local vals = {}
    for _ = 0, num - 1 do
        -- read VT_BLOB entries as an array of VT_VARIANT's
        local value
        value, valPos = ReadFPXValue(et, val, valPos, VT_VARIANT(), dirEnd)
        if value == nil then break end
        vals[#vals + 1] = value
    end
    -- filter values to extract only the links
    local links = {}
    for i = 0, #vals - 1, 6 do
        links[#links + 1] = at(vals, i + 4) or ''   -- get address
        if truthy(length(at(vals, i + 5))) then links[#links] = links[#links] .. '#' .. str(at(vals, i + 5)) end -- add subaddress
    end
    return links
end
FlashPix.ProcessHyperlinks = ProcessHyperlinks

--------------------------------------------------------------------------------
-- Read FlashPix value
-- Inputs: 0) ExifTool ref, 1) data ref, 2) value offset, 3) FPX format number,
--         4) end offset, 5) flag for no padding, 6) code page
--         7) (port: Lua has no wantarray -- true asks for upstream's list
--            context)
-- Returns: converted value (or list of values in list context) and updates
--          value offset to end of value if successful, or returns undef on error
--          (port: the updated value offset is returned as a second value,
--           where upstream assigns it to its argument through `$_[2]`)
function ReadFPXValue(et, dataPt, valPos, type_, dirEnd, noPad, codePage, wantarray)
    local vals = {}

    local format = oleFormat[type_ & 0x0fff]
    while format do -- luacheck: ignore 512 (single pass, as upstream)
        local count = 1
        -- handle VT_VECTOR types
        local flags = type_ & 0xf000
        if flags ~= 0 then
            if flags == VT_VECTOR() then
                noPad = 1     -- values sometimes aren't padded inside vectors!!
                local size = oleFormatSize.VT_VECTOR
                if valPos + size > dirEnd then
                    et:Warn('Incorrect FPX VT_VECTOR size')
                    break
                end
                count = Get32u(dataPt, valPos)
                if count == 0 then vals[#vals + 1] = '' end  -- allow zero-element vector
                valPos = valPos + 4
            else
                -- can't yet handle this property flag
                et:Warn('Unknown FPX property')
                break
            end
        end
        if not format:match('^VT_') then
            local size = FormatSize(format) * count
            if valPos + size > dirEnd then
                et:Warn('Incorrect FPX ' .. format .. ' size')
                break
            end
            vals = ReadValue(dataPt, valPos, format, count, size, nil, true)
            -- update position to end of value plus padding
            valPos = valPos + ((count * size + 3) & 0xfffffffc)
            break
        end
        local size = oleFormatSize[format]
        local val, len
        for item = 0, count - 1 do -- luacheck: ignore 213
            if valPos + size > dirEnd then
                et:Warn('Truncated FPX ' .. format .. ' value')
                break
            end
            -- sometimes VT_VECTOR items are padded to even 4-byte boundaries, and sometimes they aren't
            if truthy(noPad) and len ~= nil and (len & 0x03) ~= 0 then
                local pad = 4 - (len & 0x03)
                if valPos + pad + size <= dirEnd then
                    -- skip padding if all zeros
                    if substr(dataPt, valPos, pad) == ("\0"):rep(pad) then valPos = valPos + pad end
                end
            end
            len = nil
            if format == 'VT_VARIANT' then
                local subType = Get32u(dataPt, valPos)
                valPos = valPos + size
                val, valPos = ReadFPXValue(et, dataPt, valPos, subType, dirEnd, noPad, codePage)
                if val == nil then break end
                vals[#vals + 1] = val
                goto next_item  -- avoid adding $size to $valPos again
            elseif format == 'VT_FILETIME' then
                -- convert from time in 100 ns increments to time in seconds
                val = 1e-7 * Get64u(dataPt, valPos)
                -- print as date/time if value is greater than one year (PH hack)
                local secDay = 24 * 3600
                if val > 365 * secDay then
                    -- shift from Jan 1, 1601 to Jan 1, 1970
                    local unixTimeZero = 134774 * secDay
                    val = val - unixTimeZero
                    -- there are a lot of bad programmers out there...
                    local sec100yr = 100 * 365 * secDay
                    if val < 0 or val > sec100yr then
                        -- some software writes the wrong byte order (but the proper word order)
                        local w = { unpack('x' .. valPos .. 'NN', dataPt) }
                        local v2 = uv(w[1] + w[2] * 4294967296) * 1e-7 - unixTimeZero
                        if v2 > 0 and v2 < sec100yr then
                            val = v2
                        -- also check for wrong time base
                        elseif val < 0 and val + unixTimeZero > 0 then
                            val = val + unixTimeZero
                        end
                    end
                    val = ConvertUnixTime(val)
                end
            elseif format == 'VT_DATE' then
                val = GetDouble(dataPt, valPos)
                -- shift zero from Dec 30, 1899 to Jan 1, 1970 and convert to secs
                if val ~= 0 then val = (val - 25569) * 24 * 3600 end
                val = ConvertUnixTime(val)
            elseif format:match('STR$') then
                len = Get32u(dataPt, valPos)
                if format == 'VT_LPWSTR' then len = len * 2 end    -- convert to byte count
                if valPos + len + 4 > dirEnd then
                    et:Warn('Truncated ' .. format .. ' value')
                    break
                end
                val = substr(dataPt, valPos + 4, len)
                if format == 'VT_LPWSTR' then
                    -- convert wide string from Unicode
                    val = et:Decode(val, 'UTF16')
                elseif truthy(codePage) then
                    local charset = ExifTool.charsetName['cp' .. str(codePage)]
                    if charset then
                        val = et:Decode(val, charset)
                    elseif codePage == 1200 then   -- UTF-16, little endian
                        val = et:Decode(val, 'UTF16', 'II')
                    end
                end
                val = subst(val, [[(?s)\0.*]], '')  -- truncate at null terminator
                -- update position for string length
                -- (the spec states that strings should be padded to align
                --  on even 32-bit boundaries, but this isn't always the case)
                valPos = valPos + (truthy(noPad) and len or ((len + 3) & 0xfffffffc))
            elseif format == 'VT_BLOB' or format == 'VT_CF' then
                local len = Get32u(dataPt, valPos) -- luacheck: ignore 421 (use local $len because we always expect padding)
                if valPos + len + 4 > dirEnd then
                    et:Warn('Truncated ' .. format .. ' value')
                    break
                end
                val = substr(dataPt, valPos + 4, len)
                -- update position for data length plus padding
                -- (does this padding disappear in arrays too?)
                valPos = valPos + ((len + 3) & 0xfffffffc)
            elseif format == 'VT_CLSID' then
                val = require('lexiftool.ASF').GetGUID(substr(dataPt, valPos, size))
            end
            valPos = valPos + size   -- update value pointer to end of value
            vals[#vals + 1] = val
            ::next_item::
        end
        -- join VT_ values with commas unless we want an array
        if #vals > 1 and not wantarray then vals = { join(et:Options('ListSep'), vals) } end
        break   -- didn't really want to loop
    end
    -- (upstream: `$_[2] = $valPos;` -- the updated value position is the
    --  second return value here)

    if type_ == 0 then vals[#vals + 1] = '' end -- (VT_EMPTY)
    if wantarray then
        return vals, valPos
    elseif #vals > 1 then
        return join(' ', vals), valPos
    else
        return vals[1], valPos
    end
end
FlashPix.ReadFPXValue = ReadFPXValue

--------------------------------------------------------------------------------
-- Scan for XMP in FLA Contents (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Notes: FLA format is proprietary and I couldn't find any documentation,
--        so this routine is entirely based on observations from sample files
function ProcessContents(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local isFLA
    local pos   -- (port: Perl's pos($$dataPt), carried from match to match)

    -- all of my FLA samples contain "Contents" data, and no other FPX-like samples have
    -- this (except Scene7 VNT viles), but check the data for a familiar pattern to be
    -- sure this is FLA: the Contents of all of my FLA samples start with two bytes
    -- (0x29,0x38,0x3f,0x43 or 0x47, then 0x01) followed by a number of zero bytes
    -- (from 0x18 to 0x26 of them, related somehow to the value of the first byte),
    -- followed by the string "DocumentPage"
    local m1, m2
    if isMatch(dataPt, [[(?s)^..\0+\xff\xff\x01\0\x0d\0CDocumentPage]]) then
        isFLA = 1
    else
        m1, m2, pos = matches(dataPt, [[(?s)^\0{4}.(.{1,255})\x60\xa1\x3f\x22\0{5}(.{8})]])
        if m1 then
            -- this looks like a VNT file
            et:OverrideFileType('VNT', 'image/x-vignette')
            -- hack to set proper file description (extension is the same for V-Note files)
            ExifTool.static_vars.OverrideFileDescription = ExifTool.static_vars.OverrideFileDescription or {} -- (autovivify)
            ExifTool.static_vars.OverrideFileDescription.VNT = 'Scene7 Vignette'
            local name = m1
            local w, h = unpack('V2', m2)
            et:FoundTag('ImageWidth', w)
            et:FoundTag('ImageHeight', h)
            et:HandleTag(tagTablePtr, 'OriginalFileName', name)
            m1, pos = matches(dataPt, [[(?s)\G\x01\0{4}(.{12})]], pos)
            if m1 then
                -- (first 4 bytes seem to be number of objects, next 4 bytes are zero, then ICC size)
                local size = unpack('x8V', m1)
                -- (not useful?) $et->FoundTag(NumObjects => $num);
                if truthy(size) and pos + size < length(dataPt) then
                    local dat = substr(dataPt, pos, size)
                    et:FoundTag('ICC_Profile', dat)
                    pos = pos + size
                end
                et.IeImg_lkup = { }
                et.IeImg_class = { }
                -- - the byte before \x80 is 0x0d, 0x11 or 0x1f for separate images in my samples,
                --   and 0x1c or 0x23 for inline masks
                -- - the byte after \xff\xff is 0x3b in my samples for $1 containing 'VnMask' or 'VnCache'
                while true do
                    local c1, c2
                    c1, c2, pos = matches(dataPt, [[(?s)\x0bTargetRole1(?:.\x80|\xff\xff.\0.\0Vn(\w+))\0\0\x01.{4}(.{24})]], pos)
                    if not pos then break end
                    local coords = { unpack('Vx4V4', c2) }
                    local index = table.remove(coords, 1)
                    if index ~= 0xffffffff then
                        if et.IeImg_lkup[index] then et:Warn('Duplicate image index') end
                        et.IeImg_lkup[index] = join(' ', coords)
                        if truthy(c1) then et.IeImg_class[index] = c1 end
                    end
                end
            end
        end
    end

    -- do a brute-force scan of the "Contents" for UTF-16 XMP
    -- (this may always be little-endian, but allow for either endianness)
    -- (port: every failed `/g` match above reset pos($$dataPt), and the
    --  successful ones end in the failing `while`, so this scan starts at 0)
    local _
    _, pos = matches(dataPt, [[<\0\?\0x\0p\0a\0c\0k\0e\0t\0 \0b\0e\0g\0i\0n\0=\0['"](\0\xff\xfe|\xfe\xff)]])
    if pos then
        dirInfo.DirStart = pos - 36
        _, pos = matches(dataPt, [[<\0\?\0x\0p\0a\0c\0k\0e\0t\0 \0e\0n\0d\0=\0['"]\0[wr]\0['"]\0\?\0>\0?]], pos)
        if pos then
            dirInfo.DirLen = pos - dirInfo.DirStart
            require('lexiftool.XMP').ProcessXMP(et, dirInfo, tagTablePtr)
            -- override format if not already FLA but XMP-dc:Format indicates it is
            if et.FILE_TYPE ~= 'FLA' and truthy(et.VALUE.Format) and
                          et.VALUE.Format == 'application/vnd.adobe.fla' then isFLA = 1 end
        end
    end
    if isFLA then et:OverrideFileType('FLA') end
    return 1
end
FlashPix.ProcessContents = ProcessContents

--------------------------------------------------------------------------------
-- Process WordDocument stream of MSWord doc file (ref 6)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessWordDocument(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    if not dataPt then return 0 end
    local dirLen = length(dataPt)
    -- validate the FIB signature
    if not (dirLen > 2 and Get16u(dataPt, 0) == 0xa5ec) then
        et:Warn('Invalid FIB signature', 1)
        return 0
    end
    et:ProcessBinaryData(dirInfo, tagTablePtr) -- process FIB
    -- continue parsing the WordDocument stream until we find the FibRgFcLcb
    local pos = 32
    if pos + 2 > dirLen then return 0 end
    local n = Get16u(dataPt, pos)  -- read csw
    pos = pos + 2 + n * 2          -- skip fibRgW
    if pos + 2 > dirLen then return 0 end
    n = Get16u(dataPt, pos)        -- read cslw
    pos = pos + 2 + n * 4          -- skip fibRgLw
    if pos + 2 > dirLen then return 0 end
    n = Get16u(dataPt, pos)        -- read cbRgFcLcb
    pos = pos + 2  -- point to start of fibRgFcLcbBlob
    if pos + n * 8 > dirLen then return 0 end
    local tableOffsets = {}
    -- save necessary entries for later processing of document table
    -- (DOP, CommentBy, LastSavedBy)
    for _, off in ipairs({ 0xf8, 0x120, 0x238 }) do
        if off + 8 > n * 8 then break end
        tableOffsets[#tableOffsets + 1] = Get32u(dataPt, pos + off)
        tableOffsets[#tableOffsets + 1] = Get32u(dataPt, pos + off + 4)
    end
    local tbl = GetTagTable(nil, 'lexiftool.FlashPix.DocTable')
    -- extract ModifyDate if it exists
    et:HandleTag(tbl, 'ModifyDate', nil, {
        DataPt = dataPt,
        Start  = pos + 0x2b8,
        Size   = 8,
    })
    et:HandleTag(tbl, 'TableOffsets', tableOffsets)   -- save for later
    -- $pos += $n * 8;                 # skip fibRgFcLcbBlob
    -- return 0 if $pos + 2 > $dirLen;
    -- $n = Get16u($dataPt, $pos);     # read cswNew
    -- return 0 if $pos + 2 + $n * 2 > $dirLen;
    -- my $nFib = Get16u($dataPt, 2 + ($n ? $pos : 0));
    -- $pos += 2 + $n * 2;             # skip fibRgCswNew
    return 1
end
FlashPix.ProcessWordDocument = ProcessWordDocument

--------------------------------------------------------------------------------
-- Process Microsoft Word Document Table
-- Inputs: 0) ExifTool object ref
function ProcessDocumentTable(et)
    local value = et.VALUE
    local extra = et.TAG_EXTRA
    local tag
    -- loop through TableOffsets for each sub-document
    local i = 0
    while true do
        local key = 'TableOffsets' .. (i ~= 0 and (' (' .. i .. ')') or '')
        local offsets = value[key]
        if offsets == nil then break end
        local doc
        doc = extra[key] and extra[key].G3
        if not truthy(doc) then doc = '' end
        -- get DocFlags for this sub-document
        local docFlags, docTable
        local j = 0
        while true do
            local key = 'DocFlags' .. (j ~= 0 and (' (' .. j .. ')') or '') -- luacheck: ignore 421 (inner my $key, as upstream)
            if value[key] == nil then break end
            local tmp
            tmp = extra[key] and extra[key].G3
            if not truthy(tmp) then tmp = '' end
            if tmp == doc then
                docFlags = value[key]
                break
            end
            j = j + 1
        end
        if docFlags == nil then goto next_doc end
        tag = (docFlags & 0x200) ~= 0 and 'Table1' or 'Table0'
        -- get table for this sub-document
        j = 0
        while true do
            local key = tag .. (j ~= 0 and (' (' .. j .. ')') or '') -- luacheck: ignore 421 (inner my $key, as upstream)
            if value[key] == nil then break end
            local tmp
            tmp = extra[key] and extra[key].G3
            if not truthy(tmp) then tmp = '' end
            if tmp == doc then
                docTable = value[key]
                break
            end
            j = j + 1
        end
        if docTable == nil then goto next_doc end
        do
            -- extract DOP and LastSavedBy information from document table
            et.DOC_NUM = doc   -- use same document number
            local tagTablePtr = GetTagTable(nil, 'lexiftool.FlashPix.DocTable')
            for _, tag in ipairs({ 'DOP', 'CommentByBlock', 'LastSavedByBlock' }) do -- luacheck: ignore 421 (foreach reuses $tag upstream)
                if #offsets == 0 then break end
                local off = table.remove(offsets, 1)
                local len = table.remove(offsets, 1)
                if truthy(len) and off + len <= length(docTable) then
                    et:HandleTag(tagTablePtr, tag, nil, {
                        DataPt = docTable,
                        Start  = off,
                        Size   = len,
                    })
                end
            end
            et.DOC_NUM = nil
        end
        ::next_doc::
        i = i + 1
    end
    -- delete intermediate tags
    for _, tag in ipairs({ 'TableOffsets', 'Table0', 'Table1' }) do -- luacheck: ignore 421 (foreach reuses $tag upstream)
        i = 0
        while true do
            local key = tag .. (i ~= 0 and (' (' .. i .. ')') or '')
            if value[key] == nil then break end
            et:DeleteTag(key)
            i = i + 1
        end
    end
end
FlashPix.ProcessDocumentTable = ProcessDocumentTable

--------------------------------------------------------------------------------
-- Extract names of comment authors (ref 6)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessCommentBy(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local end_ = dirInfo.DirLen + pos
    et:VerboseDir(dirInfo.DirName)
    while pos + 2 < end_ do
        local len = Get16u(dataPt, pos)
        pos = pos + 2
        if pos + len * 2 > end_ then break end
        local author = et:Decode(substr(dataPt, pos, len*2), 'UTF16')
        pos = pos + len * 2
        et:HandleTag(tagTablePtr, 'CommentBy', author)
    end
    return 1
end
FlashPix.ProcessCommentBy = ProcessCommentBy

--------------------------------------------------------------------------------
-- Extract last-saved-by names (ref 5)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessLastSavedBy(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local end_ = dirInfo.DirLen + pos
    if pos + 6 > end_ then return 0 end
    et:VerboseDir(dirInfo.DirName)
    local num = Get16u(dataPt, pos+2)
    pos = pos + 6
    while num >= 2 do
        if pos + 2 > end_ then break end
        local len = Get16u(dataPt, pos)
        pos = pos + 2
        if pos + len * 2 > end_ then break end
        local author = et:Decode(substr(dataPt, pos, len*2), 'UTF16')
        pos = pos + len * 2
        if pos + 2 > end_ then break end
        len = Get16u(dataPt, pos)
        pos = pos + 2
        if pos + len * 2 > end_ then break end
        local path = et:Decode(substr(dataPt, pos, len*2), 'UTF16')
        pos = pos + len * 2
        et:HandleTag(tagTablePtr, 'LastSavedBy', author .. ' (' .. path .. ')')
        num = num - 2
    end
    return 1
end
FlashPix.ProcessLastSavedBy = ProcessLastSavedBy

--------------------------------------------------------------------------------
-- Check FPX byte order mark (BOM) and set byte order appropriately
-- Inputs: 0) data ref, 1) offset to BOM
-- Returns: true on success
local function CheckBOM(dataPt, pos)
    local bom = Get16u(dataPt, pos)
    if bom == 0xfffe then return 1 end
    if bom ~= 0xfeff then return 0 end
    ToggleByteOrder()
    return 1
end
FlashPix.CheckBOM = CheckBOM

--------------------------------------------------------------------------------
-- Process FlashPix properties
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessProperties(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen
    if not truthy(dirLen) then dirLen = length(dataPt) - pos end
    local dirEnd = pos + dirLen
    local verbose = et:Options('Verbose')

    if dirLen < 48 then
        et:Warn('Truncated FPX properties')
        return 0
    end
    -- check and set our byte order if necessary
    if not truthy(CheckBOM(dataPt, pos)) then
        et:Warn('Bad FPX property byte order mark')
        return 0
    end
    -- get position of start of section
    pos = Get32u(dataPt, pos + 44)
    if pos < 48 then
        et:Warn('Bad FPX property section offset')
        return 0
    end
    for n = 0, 1 do -- luacheck: ignore 213
        local dictionary = {}   -- dictionary to translate user-defined properties
        local codePage
        if pos + 8 > dirEnd then break end
        -- read property section header
        local size = Get32u(dataPt, pos)
        if size == 0 then break end
        local numEntries = Get32u(dataPt, pos + 4)
        if truthy(verbose) then et:VerboseDir('Property Info', numEntries, size) end
        if pos + 8 + 8 * numEntries > dirEnd then
            et:Warn('Truncated property list')
            break
        end
        local index = 0
        while index < numEntries do
            local entry = pos + 8 + 8 * index
            local tag = Get32u(dataPt, entry)
            local offset = Get32u(dataPt, entry + 4)
            local valStart = pos + 4 + offset
            if valStart >= dirEnd then break end
            local valPos = valStart
            local type_ = Get32u(dataPt, pos + offset)
            if tag == 0 then
                -- read dictionary to get tag name lookup for this property set
                for i = 0, type_ - 1 do -- luacheck: ignore 213
                    if valPos + 8 > dirEnd then break end
                    tag = Get32u(dataPt, valPos)
                    local len = Get32u(dataPt, valPos + 4)
                    valPos = valPos + 8 + len
                    if valPos > dirEnd then break end
                    local name = substr(dataPt, valPos - len, len)
                    name = subst(name, [[(?s)\0.*]], '')
                    if length(name) == 0 then goto next_name end
                    dictionary[tag] = name
                    if tagTablePtr[name] then goto next_name end
                    tag = name
                    name = subst(name, [[(^| )([a-z])]], function(_, c2) return uc(c2) end, 'g') -- start with uppercase
                    name = tr(name, '-_a-zA-Z0-9', '', 'dc')    -- remove illegal characters
                    if length(name) == 0 then goto next_name end
                    if truthy(verbose) then et:VPrint(0, et.INDENT .. '[adding ' .. name .. "]\n") end
                    AddTagToTable(nil, tagTablePtr, tag, { Name = name })
                    ::next_name::
                end
                goto next_entry
            end
            do
                -- use tag name from dictionary if available
                local custom, val
                if dictionary[tag] ~= nil then
                    tag = dictionary[tag]
                    custom = 1
                end
                local vals
                vals, valPos = ReadFPXValue(et, dataPt, valPos, type_, dirEnd, nil, codePage, true)
                if #vals == 0 then et:Warn('Error reading property value') end
                if #vals > 1 then val = vals else val = vals[1] end
                local format = type_ & 0x0fff
                local flags = type_ & 0xf000
                local formStr = oleFormat[format] or ('Type ' .. format)
                if flags ~= 0 then formStr = formStr .. '|' .. (oleFlags[flags] or sprintf('0x%x', flags)) end
                local tagInfo
                -- check for common tag ID's: Dictionary, CodePage and LocaleIndicator
                -- (must be done before masking because masked tags may overlap these ID's)
                if not custom and (tag == 1 or tag == 0x80000000) then
                    -- get tagInfo from SummaryInfo table
                    local summaryTable = GetTagTable(nil, 'lexiftool.FlashPix.SummaryInfo')
                    tagInfo = et:GetTagInfo(summaryTable, tag)
                    if tag == 1 then
                        if val ~= nil and val < 0 then val = val + 0x10000 end -- (may be incorrectly stored as int16s)
                        codePage = val            -- save code page for translating values
                    end
                elseif tagTablePtr[tag] then
                    tagInfo = et:GetTagInfo(tagTablePtr, tag)
                elseif tagTablePtr.VARS and not custom then
                    -- mask off insignificant bits of tag ID if necessary
                    local masked = tagTablePtr.VARS
                    for mask in pairs(masked) do
                        if masked[mask][tag & mask] then
                            tagInfo = et:GetTagInfo(tagTablePtr, tag & mask)
                            break
                        end
                    end
                end
                et:HandleTag(tagTablePtr, tag, val, {
                    DataPt  = dataPt,
                    Start   = valStart,
                    Size    = valPos - valStart,
                    Format  = formStr,
                    Index   = index,
                    TagInfo = tagInfo,
                    Extra   = ', type=' .. type_,
                })
            end
            ::next_entry::
            index = index + 1
        end
        -- issue warning if we hit end of property section prematurely
        if index < numEntries then et:Warn('Truncated property data') end
        if not dirInfo.Multi then break end
        pos = pos + size
    end

    return 1
end
FlashPix.ProcessProperties = ProcessProperties

--------------------------------------------------------------------------------
-- Load chain of sectors from file
-- Inputs: 0) RAF ref, 1) first sector number, 2) FAT ref, 3) sector size, 4) header size
local function LoadChain(raf, sect, fatPt, sectSize, hdrSize)
    if not raf then return nil end
    local chain = ''
    local buff, n
    local loadedSect = {}
    while true do
        if sect >= END_OF_CHAIN() then break end
        if loadedSect[sect] then return nil end -- avoid infinite loop
        loadedSect[sect] = 1
        local offset = sect * sectSize + hdrSize
        if not ((offset <= 0x7fffffff or truthy(raf.LargeFileSupport)) and
                raf:Seek(offset, 0)) then return nil end
        n, buff = raf:Read(sectSize)
        if n ~= sectSize then return nil end
        chain = chain .. buff
        -- step to next sector in chain
        if sect * 4 > length(fatPt) - 4 then return nil end
        sect = Get32u(fatPt, sect * 4)
    end
    return chain
end
FlashPix.LoadChain = LoadChain

--------------------------------------------------------------------------------
-- Extract information from a JPEG APP2 FPXR segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessFPXR(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    local verbose = et:Options('Verbose')

    if dirLen < 13 then
        et:Warn('FPXR segment too small')
        return 0
    end

    -- get version and segment type (version is 0 in all my samples)
    local vers, type_ = unpack('x5C2', dataPt)

    if type_ == 1 then   -- a "Contents List" segment

        if vers ~= 0 then et:Warn('Untested FPXR version ' .. vers) end
        if et.FPXR then
            et:Warn('Multiple FPXR contents lists')
            et.FPXR = nil
        end
        local numEntries = unpack('x7n', dataPt)
        local contents = {}
        if truthy(verbose) then et:VerboseDir('Contents List', numEntries) end
        local pos = 9
        for entry = 0, numEntries - 1 do
            if pos + 4 > dirLen then
                et:Warn('Truncated FPXR contents')
                return 0
            end
            local size, default = unpack('x' .. pos .. 'Na', dataPt)
            -- (port: pos($$dataPt) = $pos + 5 -- the start offset of the match below)
            -- according to the spec, this string is little-endian
            -- (very odd, since the size word is big-endian),
            -- and the first char must be '/'
            local m1, _, p = matches(dataPt, [[(?s)\G(/\0(..)*?)\0\0]], pos + 5)
            if not m1 then
                et:Warn('Invalid FPXR stream name')
                return 0
            end
            -- convert stream pathname to ascii
            local name = ExifTool.Decode(nil, m1, 'UTF16', 'II', 'Latin')
            if truthy(verbose) then
                local psize = (size == 0xffffffff) and 'storage' or (size .. ' bytes')
                et:VPrint(0, "  |  " .. entry .. ") Name: '" .. name .. "' [" .. psize .. "]\n")
            end
            -- remove directory specification
            name = subst(name, [[(?s).*/]], '')
            -- read storage class ID if necessary
            local classID
            if size == 0xffffffff then
                m1, p = matches(dataPt, [[(?s)(.{16})]], p)
                if not m1 then
                    et:Warn('Truncated FPXR storage class ID')
                    return 0
                end
                -- unpack class ID in case we want to use it sometime
                classID = require('lexiftool.ASF').GetGUID(m1)
            end
            -- find the tagInfo if available
            local tagInfo
            if not tagTablePtr[name] then
                -- remove instance number or class ID from tag if necessary
                m1 = matches(name, [[(?s)(.*) \d{6}$]])
                if not (m1 and tagTablePtr[m1]) then
                    m1 = matches(name, [[(?s)(.*)_[0-9a-f]{16}$]])
                    if not (m1 and tagTablePtr[m1]) then m1 = nil end
                end
                if m1 then tagInfo = et:GetTagInfo(tagTablePtr, m1) end
            end
            -- update position in list
            pos = p
            -- add to our contents list
            contents[#contents + 1] = {
                Name = name,
                Size = size,
                Default = default,
                ClassID = classID,
                TagInfo = tagInfo,
            }
        end
        -- save contents list as $et member variable
        -- (must do this last so we don't save list on error)
        et.FPXR = contents

    elseif type_ == 2 then  -- a "Stream Data" segment

        -- get the contents list index and stream data offset
        local index, offset = unpack('x7nN', dataPt)
        local fpxr = et.FPXR
        if fpxr and at(fpxr, index) then
            local obj = at(fpxr, index)
            -- extract stream data (after 13-byte header)
            if obj.Stream == nil then
                -- ignore offset for first segment of this type
                -- (in my sample images, this isn't always zero as one would expect)
                obj.Stream = substr(dataPt, dirStart+13)
            else
                -- add data at the proper offset to the stream
                local overlap = length(obj.Stream) - offset
                local start = dirStart + 13
                if overlap < 0 or dirLen - overlap < 13 then
                    et:Warn('Bad FPXR stream ' .. index .. ' offset', 1)
                else
                    -- ignore any overlapping data in this segment
                    -- (this seems to be the convention)
                    start = start + overlap
                end
                -- concatenate data with this stream
                obj.Stream = obj.Stream .. substr(dataPt, start)
            end
            -- save value for this tag if stream is complete
            local len = length(obj.Stream)
            if len >= obj.Size then
                if truthy(verbose) then et:VPrint(0, '  + [FPXR stream ' .. index .. ', ' .. len .. " bytes]\n") end
                if len > obj.Size then
                    et:Warn('Extra data in FPXR segment (truncated)')
                    obj.Stream = substr(obj.Stream, 0, obj.Size)
                end
                -- handle this tag
                et:HandleTag(tagTablePtr, obj.Name, obj.Stream, {
                    DataPt = obj.Stream,
                    TagInfo = obj.TagInfo,
                })
                obj.Stream = nil -- done with this stream
            end
        -- hack for improperly stored FujiFilm PreviewImage (stored with no contents list)
        elseif index == 512 and dirLen > 60 and (truthy(et.FujiPreview) or
            (dirLen > 64 and substr(dataPt, dirStart+60, 4) == "\xff\xd8\xff\xdb"))
        then
            if et.FujiPreview == nil then et.FujiPreview = '' end
            -- recombine PreviewImage, skipping 13-byte FPXR header + 47-byte Fuji header
            et.FujiPreview = et.FujiPreview .. substr(dataPt, dirStart+60)
        else
            -- (Kodak uses index 255 for a free segment in images from some cameras)
            if index ~= 255 then et:Warn('Unlisted FPXR segment (index ' .. index .. ')') end
        end

    elseif type_ ~= 3 then  -- not a "Reserved" segment

        et:Warn('Unknown FPXR segment (type ' .. type_ .. ')')

    end

    -- clean up if this was the last FPXR segment
    if dirInfo.LastFPXR then
        if et.FPXR then
            for _, obj in ipairs(et.FPXR) do
                if obj.Stream ~= nil and length(obj.Stream) ~= 0 then
                    -- parse it even though it isn't the proper length
                    et:HandleTag(tagTablePtr, obj.Name, obj.Stream, {
                        DataPt = obj.Stream,
                        TagInfo = obj.TagInfo,
                    })
                end
            end
            et.FPXR = nil    -- delete our temporary variables
        end
        if truthy(et.FujiPreview) then
            et:FoundTag('PreviewImage', et.FujiPreview)
            et.FujiPreview = nil
        end
    end
    return 1
end
FlashPix.ProcessFPXR = ProcessFPXR

--------------------------------------------------------------------------------
-- Set document number for objects
-- Inputs: 0) object hierarchy hash ref, 1) object index, 2) doc number list ref,
--         3) doc numbers used at each level, 4) flag set for metadata levels
function SetDocNum(hier, index, doc, used, meta)
    local obj = hier[index]
    if not obj then return end
    if obj.DocNum ~= nil then return end
    obj.DocNum = doc or false   -- (false: an existing but undefined DocNum)
    if truthy(obj.Left) then SetDocNum(hier, obj.Left, doc, used, meta) end
    if truthy(obj.Right) then SetDocNum(hier, obj.Right, doc, used, meta) end
    if obj.Child ~= nil then
        if not used then used = { } end
        local subDoc = {}
        if doc then for _, d in ipairs(doc) do subDoc[#subDoc + 1] = d end end
        -- we must dive down 2 levels for each sub-document, so use the
        -- $meta flag to add a sub-document level only for every 2nd generation
        -- (port: Perl's $$used[N] is used[N + 1])
        if meta then
            local subNum = (used[#subDoc + 1] or 0)
            used[#subDoc + 1] = subNum
            subDoc[#subDoc + 1] = subNum
        elseif #subDoc > 0 then
            used[#subDoc] = (used[#subDoc] or 0) + 1
            subDoc[#subDoc] = used[#subDoc]
        end
        SetDocNum(hier, obj.Child, subDoc, used, not meta)
    end
end
FlashPix.SetDocNum = SetDocNum

--------------------------------------------------------------------------------
-- Extract information from a FlashPix (FPX) file
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid FPX-format file
function ProcessFPX(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, out, oldIndent, miniStreamBuff, n
    local tag
    local hier, objIndex, loadedDifSect = {}, {}, {}

    -- handle FPX format in memory from PNG cpIp chunk
    if not raf then raf = RandomAccess.new(dirInfo.DataPt) end

    -- read header
    n, buff = raf:Read(HDR_SIZE())
    if n ~= HDR_SIZE() then return 0 end
    -- check signature
    if not isMatch(buff, [[^\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1]]) then return 0 end

    -- set FileType initially based on file extension (we may override this later)
    local fileType = et.FILE_EXT
    if not (fileType and fpxFileType[fileType]) then fileType = 'FPX' end
    et:SetFileType(fileType)
    SetByteOrder(substr(buff, 0x1c, 2) == "\xff\xfe" and 'MM' or 'II')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.FlashPix.Main')
    local verbose = et:Options('Verbose')
    -- copy LargeFileSupport option to RAF for use in LoadChain
    raf.LargeFileSupport = et:Options('LargeFileSupport')

    local sectSize = 1 << Get16u(buff, 0x1e)
    local miniSize = 1 << Get16u(buff, 0x20)
    local fatCount   = Get32u(buff, 0x2c)  -- number of FAT sectors
    local dirStart   = Get32u(buff, 0x30)  -- first directory sector
    local miniCutoff = Get32u(buff, 0x38)  -- minimum size for big-FAT streams
    local miniStart  = Get32u(buff, 0x3c)  -- first sector of mini-FAT
    local miniCount  = Get32u(buff, 0x40)  -- number of mini-FAT sectors
    local difStart   = Get32u(buff, 0x44)  -- first sector of DIF chain
    local difCount   = Get32u(buff, 0x48)  -- number of DIF sectors

    if truthy(verbose) then
        out = et:Options('TextOut') or io.stdout
        out:write('  Sector size=', sectSize, '\n  FAT: Count=', fatCount, '\n')
        out:write('  DIR: Start=', dirStart, '\n')
        out:write('  MiniFAT: Mini-sector size=', miniSize, ' Start=', miniStart, ' Count=', miniCount, ' Cutoff=', miniCutoff, '\n')
        out:write('  DIF FAT: Start=', difStart, ' Count=', difCount, '\n')
    end
--
-- load the FAT
--
    local pos = 0x4c
    local endPos = length(buff)
    local fat = ''
    local fatCountCheck = 0
    local difCountCheck = 0
    local hdrSize = sectSize > HDR_SIZE() and sectSize or HDR_SIZE()

    while true do
        while pos <= endPos - 4 do
            local sect = Get32u(buff, pos)
            pos = pos + 4
            if sect == FREE_SECT() then goto next_sect end
            do
                local offset = sect * sectSize + hdrSize
                local fatSect
                local ok = raf:Seek(offset, 0)
                if ok then n, fatSect = raf:Read(sectSize) ok = (n == sectSize) end
                if not ok then
                    et:Error('Error reading FAT from sector ' .. sect)
                    return 1
                end
                fat = fat .. fatSect
                fatCountCheck = fatCountCheck + 1
            end
            ::next_sect::
        end
        if difStart >= END_OF_CHAIN() then break end
        -- read next DIF (Dual Indirect FAT) sector
        difCountCheck = difCountCheck + 1
        if difCountCheck > difCount then
            et:Warn('Unterminated DIF FAT')
            break
        end
        if loadedDifSect[difStart] then
            et:Warn('Cyclical reference in DIF FAT')
            break
        end
        local offset = difStart * sectSize + hdrSize
        local ok = raf:Seek(offset, 0)
        if ok then n, buff = raf:Read(sectSize) ok = (n == sectSize) end
        if not ok then
            et:Error('Error reading DIF sector ' .. difStart)
            return 1
        end
        loadedDifSect[difStart] = 1
        -- set end of sector information in this DIF
        pos = 0
        endPos = sectSize - 4
        -- next time around we want to read next DIF in chain
        difStart = Get32u(buff, endPos)
    end
    if fatCountCheck ~= fatCount then
        et:Warn('Bad number of FAT sectors (expected ' .. fatCount .. ' but found ' .. fatCountCheck .. ')')
    end
--
-- load the mini-FAT and the directory
--
    local miniFat = LoadChain(raf, miniStart, fat, sectSize, hdrSize)
    local dir = LoadChain(raf, dirStart, fat, sectSize, hdrSize)
    if not (miniFat ~= nil and dir ~= nil) then
        et:Error('Error reading mini-FAT or directory stream')
        return 1
    end
    if truthy(verbose) then
        out:write('  FAT [', length(fat), ' bytes]:\n')
        et:VerboseDump(fat)
        out:write('  Mini-FAT [', length(miniFat), ' bytes]:\n')
        et:VerboseDump(miniFat)
        out:write('  Directory [', length(dir), ' bytes]:\n')
        et:VerboseDump(dir)
    end
--
-- process the directory
--
    if truthy(verbose) then
        oldIndent = et.INDENT
        et.INDENT = et.INDENT .. '| '
        et:VerboseDir('FPX', nil, length(dir))
    end
    local miniStream
    endPos = length(dir)
    local index = 0
    local ee -- name of next tag to extract if unknown
    if truthy(et:Options('ExtractEmbedded')) then ee = 0 end

    pos = 0
    while pos <= endPos - 128 do

        -- get directory entry type
        -- (0=invalid, 1=storage, 2=stream, 3=lockbytes, 4=property, 5=root)
        local type_ = Get8u(dir, pos + 0x42)
        if type_ == 0 then goto next_entry end -- skip invalid entries
        if type_ > 5 then
            et:Warn('Invalid directory entry type ' .. type_)
            break   -- rest of directory is probably garbage
        end
        do
        -- get entry name (note: this is supposed to be length in 2-byte
        -- characters but this isn't what is done in my sample FPX file, so
        -- be very tolerant of this count -- it's null terminated anyway)
        local len = Get16u(dir, pos + 0x40)
        if len > 32 then len = 32 end
        tag = ExifTool.Decode(nil, substr(dir, pos, len*2), 'UTF16', 'II', 'Latin')
        tag = subst(tag, [[(?s)\0.*]], '')  -- truncate at null (in case length was wrong)

        if tag == '0' and ee == nil then
            et:Warn('Use the ExtractEmbedded option to extract embedded information', 3)
        end
        local sect = Get32u(dir, pos + 0x74)  -- start sector number
        local size = Get32u(dir, pos + 0x78)  -- stream length

        -- load Ministream (referenced from first directory entry)
        if not miniStream then
            miniStreamBuff = LoadChain(raf, sect, fat, sectSize, hdrSize)
            if miniStreamBuff == nil then
                et:Warn('Error loading Mini-FAT stream')
                break
            end
            miniStream = RandomAccess.new(miniStreamBuff)
        end

        local tagInfo
        if tagTablePtr[tag] then
            tagInfo = et:GetTagInfo(tagTablePtr, tag)
        elseif ee ~= nil and tag == str(ee) then
            tagInfo = ''  -- won't know the actual tagID untile we read the stream
            ee = sprintf('%x', hex(ee)+1) -- tag to look for next
        else
            -- remove instance number or class ID from tag if necessary
            local m1 = matches(tag, [[(?s)(.*) \d{6}$]])
            if not (m1 and tagTablePtr[m1]) then
                m1 = matches(tag, [[(?s)(.*)_[0-9a-f]{16}$]])
                if not (m1 and tagTablePtr[m1]) then
                    m1 = matches(tag, [[(?s)(.*)_[0-9]{4}$]])  -- IeImg instances
                    if not (m1 and tagTablePtr[m1]) then m1 = nil end
                end
            end
            if m1 then tagInfo = et:GetTagInfo(tagTablePtr, m1) end
        end

        local lSib = Get32u(dir, pos + 0x44)  -- left sibling
        local rSib = Get32u(dir, pos + 0x48)  -- right sibling
        local chld = Get32u(dir, pos + 0x4c)  -- child directory

        -- save information about object hierarchy
        local obj, sub
        obj = hier[index]
        if not obj then obj = { } hier[index] = obj end
        if lSib ~= FREE_SECT() then obj.Left = lSib end
        if rSib ~= FREE_SECT() then obj.Right = rSib end
        if chld ~= FREE_SECT() then
            obj.Child = chld
            sub = hier[chld]
            if not sub then sub = { } hier[chld] = sub end
            sub.Parent = index
        end

        if not (tagInfo ~= nil or truthy(verbose)) then goto next_entry end

        -- load the data for stream types
        local extra = ''
        local typeStr = dirEntryType[type_] or type_
        if typeStr == 'STREAM' then
            if size >= miniCutoff then
                -- stream is in the main FAT
                buff = LoadChain(raf, sect, fat, sectSize, hdrSize)
            elseif size ~= 0 then
                -- stream is in the mini-FAT
                buff = LoadChain(miniStream, sect, miniFat, miniSize, 0)
            else
                buff = '' -- an empty stream
            end
            if buff == nil then
                local name = truthy(tagInfo) and tagInfo.Name or 'unknown'
                et:Warn('Error reading ' .. name .. ' stream')
                buff = ''
            end
        elseif typeStr == 'ROOT' then
            buff = miniStreamBuff
            extra = extra .. ' (Ministream)'
        else
            buff = ''
            size = nil
        end
        if truthy(verbose) then
            local flags = Get8u(dir, pos + 0x43)  -- 0=red, 1=black
            local col = ({ [0] = 'Red', [1] = 'Black' })[flags] or flags
            extra = extra .. ' Type=' .. typeStr .. ' Flags=' .. col
            if lSib ~= FREE_SECT() then extra = extra .. ' Left=' .. lSib end
            if rSib ~= FREE_SECT() then extra = extra .. ' Right=' .. rSib end
            if chld ~= FREE_SECT() then extra = extra .. ' Child=' .. chld end
            if size ~= nil then extra = extra .. ' Size=' .. size end
            local name
            if not truthy(tagInfo) and matches(tag, [[^[0-9a-f]{1,3}$]]) then name = 'Unknown_0x' .. tag end
            et:VerboseInfo(tag, tagInfo, {
                Index  = index,
                Value  = buff,
                DataPt = buff,
                Extra  = extra,
              -- Size   = $size, (moved to $extra so we can see the rest of the stream if larger)
                Name   = name,
            })
        end
        if tagInfo ~= nil and truthy(buff) then
            local num = et.NUM_FOUND
            if truthy(tagInfo) and tagInfo.SubDirectory then
                local subdir = tagInfo.SubDirectory
                local dirInfo = { -- luacheck: ignore 422 (inner my %dirInfo, as upstream)
                    DataPt   = buff,
                    DirStart = subdir.DirStart,
                    DirLen   = length(buff),
                    Multi    = tagInfo.Multi,
                }
                local subTablePtr = GetTagTable(nil, subdir.TagTable)
                et:ProcessDirectory(dirInfo, subTablePtr,  subdir.ProcessProc)
            elseif size ~= nil and size > length(buff) then
                et:Warn('Truncated object')
            else
                if size ~= nil and size < length(buff) then buff = substr(buff, 0, size) end
                local m1 = matches(tag, [[^IeImg_0*(\d+)$]])
                if m1 then
                    -- set document number for embedded images and their positions (if available, VNT files)
                    local num = tonumber(m1) -- luacheck: ignore 421 (inner my $num, as upstream)
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    et:FoundTag(tagInfo, buff)
                    if et.IeImg_lkup and et.IeImg_lkup[num] then
                        -- save position of this image
                        et:HandleTag(tagTablePtr, 'IeImg_rect', et.IeImg_lkup[num])
                        et.IeImg_lkup[num] = nil
                        if et.IeImg_class and et.IeImg_class[num] then
                            et:HandleTag(tagTablePtr, 'IeImg_class', et.IeImg_class[num])
                            et.IeImg_class[num] = nil
                        end
                    end
                    et.DOC_NUM = nil
                elseif not truthy(tagInfo) then
                    -- extract some embedded information from PNG Plus images
                    local c1, c2 = matches(buff, [[(?s)^(.{19,40})(\xff\xd8\xff\xe0|\x89PNG\r\n\x1a\n)]])
                    if c1 then
                        local id = c2 == "\xff\xd8\xff\xe0" and '_eeJPG' or '_eePNG'
                        et:HandleTag(tagTablePtr, id, substr(buff, length(c1)))
                    elseif matches(buff, [[^\0\x80\0\0\x01\0\0\0\x0e\0]]) and length(buff) > 18 then
                        local len = unpack('x17C', buff) -- luacheck: ignore 421 (inner my $len, as upstream)
                        if len + 18 > length(buff) then goto next_entry end
                        local filename = et:Decode(substr(buff,18,len), 'UTF16', 'II')
                        et:HandleTag(tagTablePtr, '_eeLink', filename)
                    else
                        goto next_entry
                    end
                else
                    et:FoundTag(tagInfo, buff)
                end
            end
            -- save object index number for all found tags
            local num2 = et.NUM_FOUND
            while num < num2 do num = num + 1 objIndex[num] = index end
        end
        end
        ::next_entry::
        pos = pos + 128
        index = index + 1
    end
    -- set document numbers for tags extracted from embedded documents
    if not truthy(et.DOC_NUM) then
        -- initialize document number for all objects, beginning at root (index 0)
        SetDocNum(hier, 0)
        -- set family 3 group name for all tags in embedded documents
        local order = et.FILE_ORDER
        local pri = {}
        for tag, num in pairs(order) do -- luacheck: ignore 421 (foreach reuses $tag upstream)
            if num == nil or not objIndex[num] then goto next_tag end
            do
                local obj = hier[objIndex[num]]
                if not obj then goto next_tag end
                local docNums = obj.DocNum
                if not (docNums and #docNums > 0) then goto next_tag end
                if not et.TAG_EXTRA[tag] then et.TAG_EXTRA[tag] = {} end
                et.TAG_EXTRA[tag].G3 = join('-', docNums)
                if not tag:find(' ', 1, true) then pri[#pri + 1] = tag end -- save keys for priority sub-doc tags
            end
            ::next_tag::
        end
        -- swap priority sub-document tags with main document tags if they exist
        for _, tag in ipairs(pri) do -- luacheck: ignore 421 (foreach reuses $tag upstream)
            local copy = 1
            while true do
                local key = tag .. ' (' .. copy .. ')'
                if et.VALUE[key] == nil then break end
                if not (et.TAG_EXTRA[key] and truthy(et.TAG_EXTRA[key].G3)) then -- not Main if family 3 group is set
                    for _, member in ipairs({ 'PRIORITY', 'VALUE', 'FILE_ORDER', 'TAG_INFO', 'TAG_EXTRA' }) do
                        local pHash = et[member]
                        local t = pHash[tag]
                        pHash[tag] = pHash[key]
                        pHash[key] = t
                    end
                    break
                end
                copy = copy + 1
            end
        end
    end
    if truthy(verbose) then et.INDENT = oldIndent end
    -- try to better identify the file type
    if et.FileType == 'FPX' then
        local val = et.CompObjUserType
        if not truthy(val) then val = et.Software end
        if truthy(val) then
            local type_ = { ['^3ds Max'] = 'MAX', Word = 'DOC', PowerPoint = 'PPT', Excel = 'XLS' }
            local pats = {}
            for pat in pairs(type_) do pats[#pats + 1] = pat end
            tsort(pats)
            for _, pat in ipairs(pats) do
                if isMatchDyn(val, pat) then
                    et:OverrideFileType(type_[pat])
                    break
                end
            end
        end
    end
    -- process Word document table
    ProcessDocumentTable(et)

    if et.IeImg_lkup and next(et.IeImg_lkup) ~= nil then
        et:Warn('Image positions exist without corresponding images')
    end

    return 1
end
FlashPix.ProcessFPX = ProcessFPX

-- (PROCESS_PROC of the tables above: the predeclared subs exist only now, see
--  the predeclaration placeholders)
FlashPix.Main.PROCESS_PROC = ProcessFPXR
FlashPix.SummaryInfo.PROCESS_PROC = ProcessProperties
FlashPix.DocumentInfo.PROCESS_PROC = ProcessProperties
FlashPix.ImageInfo.PROCESS_PROC = ProcessProperties
FlashPix.Image.PROCESS_PROC = ProcessProperties
FlashPix.Extensions.PROCESS_PROC = ProcessProperties
FlashPix.DataObject.PROCESS_PROC = ProcessProperties
FlashPix.Transform.PROCESS_PROC = ProcessProperties
FlashPix.Operation.PROCESS_PROC = ProcessProperties
FlashPix.GlobalInfo.PROCESS_PROC = ProcessProperties
FlashPix.AudioInfo.PROCESS_PROC = ProcessProperties
FlashPix.Contents.PROCESS_PROC = ProcessProperties
FlashPix.WordDocument.PROCESS_PROC = ProcessWordDocument

return FlashPix
