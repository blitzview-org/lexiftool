--------------------------------------------------------------------------------
-- File:         lexiftool/IPTC.lua
-- Ported from:  lib/Image/ExifTool/IPTC.pm
--
-- Description:  Read IPTC meta information
--
-- Revisions:    Jan. 08/2003 - P. Harvey Created
--               Feb. 05/2004 - P. Harvey Added support for records other than 2
--
-- References:   1) http://www.iptc.org/IIM/
--
-- Port notes:   all nine tag tables are ported in upstream order (Main,
--               EnvelopeRecord, ApplicationRecord, NewsPhoto, PreObjectData,
--               ObjectData, PostObjectData, FotoStation, Composite) and are
--               entry-complete.  The subs of WriteIPTC.pl (WriteIPTC,
--               CheckIPTC, PrintInvCodedCharset, IptcDate, ...) live in
--               WriteIPTC.lua and are bound here as AUTOLOAD closures at the
--               predeclaration position, so the tables name them directly.
--               TranslateCodedString returns the value and the character
--               set instead of updating them through refs.  ProcessIPTC does
--               not extract the whole block as the IPTC tag (no
--               ExifTool.Extra entry for it yet).
--------------------------------------------------------------------------------

local IPTC = {}
local matches = require('lexiftool.perl').matches
local substr = require('lexiftool.perl').substr
local length = require('lexiftool.perl').length
local print = require('lexiftool.perl').print
local str = require('lexiftool.perl').str
local subst = require('lexiftool.perl').subst
local truthy = require('lexiftool.perl').truthy
local num = require('lexiftool.perl').num
local pack = require('lexiftool.perl').pack
local unpack = require('lexiftool.perl').unpack
local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf


IPTC.iptcCharset = {
    ["\x1b%G"]  = 'UTF8',
   -- don't translate these (at least until we handle ISO 2022 shift codes)
   -- because the sets are only designated and not invoked
   -- ["\x1b,A"]  = 'Latin',  -- G0 = ISO 8859-1 (similar to Latin1, but codes 0x80-0x9f are missing)
   -- ["\x1b-A"]  = 'Latin',  -- G1     "
   -- ["\x1b.A"]  = 'Latin',  -- G2
   -- ["\x1b/A"]  = 'Latin',  -- G3
}

-- (upstream's predeclarations `sub ProcessIPTC($$$);` ... `sub
--  PrintInvCodedCharset($);`: WriteIPTC, CheckIPTC and PrintInvCodedCharset
--  are subs of WriteIPTC.pl, which upstream AUTOLOADs -- DoAutoLoad loads it on
--  the first call, also for the conversions the tables name as strings
--  (IptcDate, IptcTime, ...).  Here every sub of WriteIPTC.pl is bound to a
--  closure that loads WriteIPTC.lua on first use)
for _, name in ipairs({ 'PrintInvCodedCharset', 'CheckIPTC', 'FormatIPTC', 'IptcDate', 'IptcTime',
                        'InverseDateOrTime', 'ConvertPictureNumber', 'InvConvertPictureNumber',
                        'DoWriteIPTC', 'WriteIPTC' }) do
    IPTC[name] = function(...) return require('lexiftool.WriteIPTC')[name](...) end
end

-- standard IPTC locations
-- (MWG specifies locations only for JPEG, TIFF and PSD -- the rest are ExifTool-defined)
local isStandardIPTC = {
    ['JPEG-APP13-Photoshop-IPTC'] = 1,
    ['TIFF-IFD0-IPTC']            = 1,
    ['PSD-IPTC']                  = 1,
    ['MIE-IPTC']                  = 1,
    ['EPS-Photoshop-IPTC']        = 1,
    ['PS-Photoshop-IPTC']         = 1,
    ['EXV-APP13-Photoshop-IPTC']  = 1,
    -- set file types to 0 if they have a standard location
    JPEG = 0,
    TIFF = 0,
    PSD  = 0,
    MIE  = 0,
    EPS  = 0,
    PS   = 0,
    EXV  = 0,
}

local fileFormat = {
    [0] = 'No ObjectData',
    [1] = 'IPTC-NAA Digital Newsphoto Parameter Record',
    [2] = 'IPTC7901 Recommended Message Format',
    [3] = 'Tagged Image File Format (Adobe/Aldus Image data)',
    [4] = 'Illustrator (Adobe Graphics data)',
    [5] = 'AppleSingle (Apple Computer Inc)',
    [6] = 'NAA 89-3 (ANPA 1312)',
    [7] = 'MacBinary II',
    [8] = 'IPTC Unstructured Character Oriented File Format (UCOFF)',
    [9] = 'United Press International ANPA 1312 variant',
    [10] = 'United Press International Down-Load Message',
    [11] = 'JPEG File Interchange (JFIF)',
    [12] = 'Photo-CD Image-Pac (Eastman Kodak)',
    [13] = 'Bit Mapped Graphics File [.BMP] (Microsoft)',
    [14] = 'Digital Audio File [.WAV] (Microsoft & Creative Labs)',
    [15] = 'Audio plus Moving Video [.AVI] (Microsoft)',
    [16] = 'PC DOS/Windows Executable Files [.COM][.EXE]',
    [17] = 'Compressed Binary File [.ZIP] (PKWare Inc)',
    [18] = 'Audio Interchange File Format AIFF (Apple Computer Inc)',
    [19] = 'RIFF Wave (Microsoft Corporation)',
    [20] = 'Freehand (Macromedia/Aldus)',
    [21] = 'Hypertext Markup Language [.HTML] (The Internet Society)',
    [22] = 'MPEG 2 Audio Layer 2 (Musicom), ISO/IEC',
    [23] = 'MPEG 2 Audio Layer 3, ISO/IEC',
    [24] = 'Portable Document File [.PDF] Adobe',
    [25] = 'News Industry Text Format (NITF)',
    [26] = 'Tape Archive [.TAR]',
    [27] = 'Tidningarnas Telegrambyra NITF version (TTNITF DTD)',
    [28] = 'Ritzaus Bureau NITF version (RBNITF DTD)',
    [29] = 'Corel Draw [.CDR]',
}

-- main IPTC tag table
-- Note: ALL entries in main IPTC table (except PROCESS_PROC) must be SubDirectory
-- entries, each specifying a TagTable.
IPTC.Main = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = IPTC.WriteIPTC,
    [1] = {
        Name = 'IPTCEnvelope',
        SubDirectory = { TagTable = 'lexiftool.IPTC.EnvelopeRecord' },
    },
    [2] = {
        Name = 'IPTCApplication',
        SubDirectory = { TagTable = 'lexiftool.IPTC.ApplicationRecord' },
    },
    [3] = {
        Name = 'IPTCNewsPhoto',
        SubDirectory = { TagTable = 'lexiftool.IPTC.NewsPhoto' },
    },
    [7] = {
        Name = 'IPTCPreObjectData',
        SubDirectory = { TagTable = 'lexiftool.IPTC.PreObjectData' },
    },
    [8] = {
        Name = 'IPTCObjectData',
        SubDirectory = { TagTable = 'lexiftool.IPTC.ObjectData' },
    },
    [9] = {
        Name = 'IPTCPostObjectData',
        Groups = { [1] = 'IPTC#' }, -- #(just so this shows up in group list)
        SubDirectory = { TagTable = 'lexiftool.IPTC.PostObjectData' },
    },
    [240] = {
        Name = 'IPTCFotoStation',
        SubDirectory = { TagTable = 'lexiftool.IPTC.FotoStation' },
    },
}

-- Record 1 -- EnvelopeRecord
IPTC.EnvelopeRecord = {
    GROUPS = { [2] = 'Other' },
    WRITE_PROC = IPTC.WriteIPTC,
    CHECK_PROC = IPTC.CheckIPTC,
    WRITABLE = 1,
    [0] = {
        Name = 'EnvelopeRecordVersion',
        Format = 'int16u',
        Mandatory = 1,
    },
    [5] = {
        Name = 'Destination',
        Flags = 'List',
        Groups = { [2] = 'Location' },
        Format = 'string[0,1024]',
    },
    [20] = {
        Name = 'FileFormat',
        Groups = { [2] = 'Image' },
        Format = 'int16u',
        PrintConv = fileFormat,
    },
    [22] = {
        Name = 'FileVersion',
        Groups = { [2] = 'Image' },
        Format = 'int16u',
    },
    [30] = {
        Name = 'ServiceIdentifier',
        Format = 'string[0,10]',
    },
    [40] = {
        Name = 'EnvelopeNumber',
        Format = 'digits[8]',
    },
    [50] = {
        Name = 'ProductID',
        Flags = 'List',
        Format = 'string[0,32]',
    },
    [60] = {
        Name = 'EnvelopePriority',
        Format = 'digits[1]',
        PrintConv = {
            [0] = '0 (reserved)',
            [1] = '1 (most urgent)',
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = '5 (normal urgency)',
            [6] = 6,
            [7] = 7,
            [8] = '8 (least urgent)',
            [9] = '9 (user-defined priority)',
        },
    },
    [70] = {
        Name = 'DateSent',
        Groups = { [2] = 'Time' },
        Format = 'digits[8]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcDate(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [80] = {
        Name = 'TimeSent',
        Groups = { [2] = 'Time' },
        Format = 'string[11]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifTime(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcTime(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [90] = {
        Name = 'CodedCharacterSet',
        Notes = [[
            values are entered in the form "ESC X Y[, ...]".  The escape sequence for
            UTF-8 character coding is "ESC % G", but this is displayed as "UTF8" for
            convenience.  Either string may be used when writing.  The value of this tag
            affects the decoding of string values in the Application and NewsPhoto
            records.  This tag is marked as "unsafe" to prevent it from being copied by
            default in a group operation because existing tags in the destination image
            may use a different encoding.  When creating a new IPTC record from scratch,
            it is suggested that this be set to "UTF8" if special characters are a
            possibility
        ]],
        Protected = 1,
        Format = 'string[0,32]',
        ValueConvInv = function(_self, val)
            if matches(val, [[(?i)^UTF-?8$]]) then return "\x1b%G" end
            return val
        end,
        -- convert ISO 2022 escape sequences to a more readable format
        PrintConv = function(_self, val) return IPTC.PrintCodedCharset(val) end,
        PrintConvInv = function(_self, val) return IPTC.PrintInvCodedCharset(val) end,
    },
    [100] = {
        Name = 'UniqueObjectName',
        Format = 'string[14,80]',
    },
    [120] = {
        Name = 'ARMIdentifier',
        Format = 'int16u',
    },
    [122] = {
        Name = 'ARMVersion',
        Format = 'int16u',
    },
}

-- Record 2 -- ApplicationRecord
IPTC.ApplicationRecord = {
    GROUPS = { [2] = 'Other' },
    WRITE_PROC = IPTC.WriteIPTC,
    CHECK_PROC = IPTC.CheckIPTC,
    WRITABLE = 1,
    [0] = {
        Name = 'ApplicationRecordVersion',
        Format = 'int16u',
        Mandatory = 1,
    },
    [3] = {
        Name = 'ObjectTypeReference',
        Format = 'string[3,67]',
    },
    [4] = {
        Name = 'ObjectAttributeReference',
        Flags = 'List',
        Format = 'string[4,68]',
    },
    [5] = {
        Name = 'ObjectName',
        Format = 'string[0,64]',
    },
    [7] = {
        Name = 'EditStatus',
        Format = 'string[0,64]',
    },
    [8] = {
        Name = 'EditorialUpdate',
        Format = 'digits[2]',
        PrintConv = { ['01'] = 'Additional language' },
    },
    [10] = {
        Name = 'Urgency',
        Format = 'digits[1]',
        PrintConv = {
            [0] = '0 (reserved)',
            [1] = '1 (most urgent)',
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = '5 (normal urgency)',
            [6] = 6,
            [7] = 7,
            [8] = '8 (least urgent)',
            [9] = '9 (user-defined priority)',
        },
    },
    [12] = {
        Name = 'SubjectReference',
        Flags = 'List',
        Format = 'string[13,236]',
    },
    [15] = {
        Name = 'Category',
        Format = 'string[0,3]',
    },
    [20] = {
        Name = 'SupplementalCategories',
        Flags = 'List',
        Format = 'string[0,32]',
    },
    [22] = {
        Name = 'FixtureIdentifier',
        Format = 'string[0,32]',
    },
    [25] = {
        Name = 'Keywords',
        Flags = 'List',
        Format = 'string[0,64]',
    },
    [26] = {
        Name = 'ContentLocationCode',
        Flags = 'List',
        Groups = { [2] = 'Location' },
        Format = 'string[3]',
    },
    [27] = {
        Name = 'ContentLocationName',
        Flags = 'List',
        Groups = { [2] = 'Location' },
        Format = 'string[0,64]',
    },
    [30] = {
        Name = 'ReleaseDate',
        Groups = { [2] = 'Time' },
        Format = 'digits[8]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcDate(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [35] = {
        Name = 'ReleaseTime',
        Groups = { [2] = 'Time' },
        Format = 'string[11]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifTime(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcTime(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [37] = {
        Name = 'ExpirationDate',
        Groups = { [2] = 'Time' },
        Format = 'digits[8]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcDate(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [38] = {
        Name = 'ExpirationTime',
        Groups = { [2] = 'Time' },
        Format = 'string[11]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifTime(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcTime(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [40] = {
        Name = 'SpecialInstructions',
        Format = 'string[0,256]',
    },
    [42] = {
        Name = 'ActionAdvised',
        Format = 'digits[2]',
        PrintConv = {
            [''] = '',
            ['01'] = 'Object Kill',
            ['02'] = 'Object Replace',
            ['03'] = 'Object Append',
            ['04'] = 'Object Reference',
        },
    },
    [45] = {
        Name = 'ReferenceService',
        Flags = 'List',
        Format = 'string[0,10]',
    },
    [47] = {
        Name = 'ReferenceDate',
        Groups = { [2] = 'Time' },
        Flags = 'List',
        Format = 'digits[8]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcDate(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [50] = {
        Name = 'ReferenceNumber',
        Flags = 'List',
        Format = 'digits[8]',
    },
    [55] = {
        Name = 'DateCreated',
        Groups = { [2] = 'Time' },
        Format = 'digits[8]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcDate(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
        PrintConv = function(self, val)
            if truthy(self:Options('DateFormat')) then
                return self:ConvertDateTime(val .. ' 00:00:00')
            end
            return val
        end,
    },
    [60] = {
        Name = 'TimeCreated',
        Groups = { [2] = 'Time' },
        Format = 'string[11]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifTime(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcTime(val) end,
        PrintConv = function(self, val)
            if truthy(self:Options('DateFormat')) then
                return self:ConvertDateTime('1970:01:01 ' .. val)
            end
            return val
        end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [62] = {
        Name = 'DigitalCreationDate',
        Groups = { [2] = 'Time' },
        Format = 'digits[8]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifDate(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcDate(val) end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
        PrintConv = function(self, val)
            if truthy(self:Options('DateFormat')) then
                return self:ConvertDateTime(val .. ' 00:00:00')
            end
            return val
        end,
    },
    [63] = {
        Name = 'DigitalCreationTime',
        Groups = { [2] = 'Time' },
        Format = 'string[11]',
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifTime(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcTime(val) end,
        PrintConv = function(self, val)
            if truthy(self:Options('DateFormat')) then
                return self:ConvertDateTime('1970:01:01 ' .. val)
            end
            return val
        end,
        PrintConvInv = function(self, val) return IPTC.InverseDateOrTime(self, val) end,
    },
    [65] = {
        Name = 'OriginatingProgram',
        Format = 'string[0,32]',
    },
    [70] = {
        Name = 'ProgramVersion',
        Format = 'string[0,10]',
    },
    [75] = {
        Name = 'ObjectCycle',
        Format = 'string[1]',
        PrintConv = { a = 'Morning', p = 'Evening', b = 'Both Morning and Evening' },
    },
    [80] = {
        Name = 'By-line',
        Flags = 'List',
        Format = 'string[0,32]',
        Groups = { [2] = 'Author' },
    },
    [85] = {
        Name = 'By-lineTitle',
        Flags = 'List',
        Format = 'string[0,32]',
        Groups = { [2] = 'Author' },
    },
    [90] = {
        Name = 'City',
        Format = 'string[0,32]',
        Groups = { [2] = 'Location' },
    },
    [92] = {
        Name = 'Sub-location',
        Format = 'string[0,32]',
        Groups = { [2] = 'Location' },
    },
    [95] = {
        Name = 'Province-State',
        Format = 'string[0,32]',
        Groups = { [2] = 'Location' },
    },
    [100] = {
        Name = 'Country-PrimaryLocationCode',
        Format = 'string[3]',
        Groups = { [2] = 'Location' },
    },
    [101] = {
        Name = 'Country-PrimaryLocationName',
        Format = 'string[0,64]',
        Groups = { [2] = 'Location' },
    },
    [103] = {
        Name = 'OriginalTransmissionReference',
        Format = 'string[0,32]',
        Notes = 'now used as a job identifier',
    },
    [105] = {
        Name = 'Headline',
        Format = 'string[0,256]',
    },
    [110] = {
        Name = 'Credit',
        Groups = { [2] = 'Author' },
        Format = 'string[0,32]',
    },
    [115] = {
        Name = 'Source',
        Groups = { [2] = 'Author' },
        Format = 'string[0,32]',
    },
    [116] = {
        Name = 'CopyrightNotice',
        Groups = { [2] = 'Author' },
        Format = 'string[0,128]',
    },
    [118] = {
        Name = 'Contact',
        Flags = 'List',
        Groups = { [2] = 'Author' },
        Format = 'string[0,128]',
    },
    [120] = {
        Name = 'Caption-Abstract',
        Format = 'string[0,2000]',
    },
    [121] = {
        Name = 'LocalCaption',
        Format = 'string[0,256]', -- (guess)
        Notes = [[
            I haven't found a reference for the format of tags 121, 184-188 and
            225-232, so I have just make them writable as strings with
            reasonable length.  Beware that if this is wrong, other utilities
            may not be able to read these tags as written by ExifTool
        ]],
    },
    [122] = {
        Name = 'Writer-Editor',
        Flags = 'List',
        Groups = { [2] = 'Author' },
        Format = 'string[0,32]',
    },
    [125] = {
        Name = 'RasterizedCaption',
        Format = 'undef[7360]',
        Binary = 1,
    },
    [130] = {
        Name = 'ImageType',
        Groups = { [2] = 'Image' },
        Format = 'string[2]',
    },
    [131] = {
        Name = 'ImageOrientation',
        Groups = { [2] = 'Image' },
        Format = 'string[1]',
        PrintConv = { P = 'Portrait', L = 'Landscape', S = 'Square' },
    },
    [135] = {
        Name = 'LanguageIdentifier',
        Format = 'string[2,3]',
    },
    [150] = {
        Name = 'AudioType',
        Format = 'string[2]',
        PrintConv = {
            ['1A'] = 'Mono Actuality',
            ['2A'] = 'Stereo Actuality',
            ['1C'] = 'Mono Question and Answer Session',
            ['2C'] = 'Stereo Question and Answer Session',
            ['1M'] = 'Mono Music',
            ['2M'] = 'Stereo Music',
            ['1Q'] = 'Mono Response to a Question',
            ['2Q'] = 'Stereo Response to a Question',
            ['1R'] = 'Mono Raw Sound',
            ['2R'] = 'Stereo Raw Sound',
            ['1S'] = 'Mono Scener',
            ['2S'] = 'Stereo Scener',
            ['0T'] = 'Text Only',
            ['1V'] = 'Mono Voicer',
            ['2V'] = 'Stereo Voicer',
            ['1W'] = 'Mono Wrap',
            ['2W'] = 'Stereo Wrap',
        },
    },
    [151] = {
        Name = 'AudioSamplingRate',
        Format = 'digits[6]',
    },
    [152] = {
        Name = 'AudioSamplingResolution',
        Format = 'digits[2]',
    },
    [153] = {
        Name = 'AudioDuration',
        Format = 'digits[6]',
    },
    [154] = {
        Name = 'AudioOutcue',
        Format = 'string[0,64]',
    },
    [184] = {
        Name = 'JobID',
        Format = 'string[0,64]', -- (guess)
    },
    [185] = {
        Name = 'MasterDocumentID',
        Format = 'string[0,256]', -- (guess)
    },
    [186] = {
        Name = 'ShortDocumentID',
        Format = 'string[0,64]', -- (guess)
    },
    [187] = {
        Name = 'UniqueDocumentID',
        Format = 'string[0,128]', -- (guess)
    },
    [188] = {
        Name = 'OwnerID',
        Format = 'string[0,128]', -- (guess)
    },
    [200] = {
        Name = 'ObjectPreviewFileFormat',
        Groups = { [2] = 'Image' },
        Format = 'int16u',
        PrintConv = fileFormat,
    },
    [201] = {
        Name = 'ObjectPreviewFileVersion',
        Groups = { [2] = 'Image' },
        Format = 'int16u',
    },
    [202] = {
        Name = 'ObjectPreviewData',
        Groups = { [2] = 'Preview' },
        Format = 'undef[0,256000]',
        Binary = 1,
    },
    [221] = {
        Name = 'Prefs',
        Groups = { [2] = 'Image' },
        Format = 'string[0,64]',
        Notes = 'PhotoMechanic preferences',
        PrintConv = function(_self, val)
            return subst(str(val),
                [[\s*(\d+):\s*(\d+):\s*(\d+):\s*(\S*)]],
                'Tagged:$1, ColorClass:$2, Rating:$3, FrameNum:$4')
        end,
        PrintConvInv = function(_self, val)
            return subst(str(val),
                [[(?is)Tagged:\s*(\d+).*ColorClass:\s*(\d+).*Rating:\s*(\d+).*FrameNum:\s*(\S*)]],
                '$1:$2:$3:$4')
        end,
    },
    [225] = {
        Name = 'ClassifyState',
        Format = 'string[0,64]', -- (guess)
    },
    [228] = {
        Name = 'SimilarityIndex',
        Format = 'string[0,32]', -- (guess)
    },
    [230] = {
        Name = 'DocumentNotes',
        Format = 'string[0,1024]', -- (guess)
    },
    [231] = {
        Name = 'DocumentHistory',
        Format = 'string[0,256]', -- (guess)
        -- upstream: `$val =~ s/\0+/\n/g; $val` (have seen embedded nulls)
        ValueConv = function(_self, val) return subst(str(val), [[\0+]], '\n', 'g') end,
        ValueConvInv = function(_self, val) return val end,
    },
    [232] = {
        Name = 'ExifCameraInfo',
        Format = 'string[0,4096]', -- (guess)
    },
    [255] = { -- PH
        Name = 'CatalogSets',
        List = 1,
        Format = 'string[0,256]', -- (guess)
        Notes = 'written by iView MediaPro',
    },
}

-- Record 3 -- News photo
IPTC.NewsPhoto = {
    GROUPS = { [2] = 'Image' },
    WRITE_PROC = IPTC.WriteIPTC,
    CHECK_PROC = IPTC.CheckIPTC,
    WRITABLE = 1,
    [0] = {
        Name = 'NewsPhotoVersion',
        Format = 'int16u',
        Mandatory = 1,
    },
    [10] = {
        Name = 'IPTCPictureNumber',
        Format = 'string[16]',
        Notes = '4 numbers: 1-Manufacturer ID, 2-Equipment ID, 3-Date, 4-Sequence',
        PrintConv = function(_self, val) return IPTC.ConvertPictureNumber(val) end,
        PrintConvInv = function(_self, val) return IPTC.InvConvertPictureNumber(val) end,
    },
    [20] = {
        Name = 'IPTCImageWidth',
        Format = 'int16u',
    },
    [30] = {
        Name = 'IPTCImageHeight',
        Format = 'int16u',
    },
    [40] = {
        Name = 'IPTCPixelWidth',
        Format = 'int16u',
    },
    [50] = {
        Name = 'IPTCPixelHeight',
        Format = 'int16u',
    },
    [55] = {
        Name = 'SupplementalType',
        Format = 'int8u',
        PrintConv = {
            [0] = 'Main Image',
            [1] = 'Reduced Resolution Image',
            [2] = 'Logo',
            [3] = 'Rasterized Caption',
        },
    },
    [60] = {
        Name = 'ColorRepresentation',
        Format = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x000] = 'No Image, Single Frame',
            [0x100] = 'Monochrome, Single Frame',
            [0x300] = '3 Components, Single Frame',
            [0x301] = '3 Components, Frame Sequential in Multiple Objects',
            [0x302] = '3 Components, Frame Sequential in One Object',
            [0x303] = '3 Components, Line Sequential',
            [0x304] = '3 Components, Pixel Sequential',
            [0x305] = '3 Components, Special Interleaving',
            [0x400] = '4 Components, Single Frame',
            [0x401] = '4 Components, Frame Sequential in Multiple Objects',
            [0x402] = '4 Components, Frame Sequential in One Object',
            [0x403] = '4 Components, Line Sequential',
            [0x404] = '4 Components, Pixel Sequential',
            [0x405] = '4 Components, Special Interleaving',
        },
    },
    [64] = {
        Name = 'InterchangeColorSpace',
        Format = 'int8u',
        PrintConv = {
            [1] = 'X,Y,Z CIE',
            [2] = 'RGB SMPTE',
            [3] = 'Y,U,V (K) (D65)',
            [4] = 'RGB Device Dependent',
            [5] = 'CMY (K) Device Dependent',
            [6] = 'Lab (K) CIE',
            [7] = 'YCbCr',
            [8] = 'sRGB',
        },
    },
    [65] = {
        Name = 'ColorSequence',
        Format = 'int8u',
    },
    [66] = {
        Name = 'ICC_Profile',
        -- ...could add SubDirectory support to read into this (if anybody cares)
        Writable = 0,
        Binary = 1,
    },
    [70] = {
        Name = 'ColorCalibrationMatrix',
        Writable = 0,
        Binary = 1,
    },
    [80] = {
        Name = 'LookupTable',
        Writable = 0,
        Binary = 1,
    },
    [84] = {
        Name = 'NumIndexEntries',
        Format = 'int16u',
    },
    [85] = {
        Name = 'ColorPalette',
        Writable = 0,
        Binary = 1,
    },
    [86] = {
        Name = 'IPTCBitsPerSample',
        Format = 'int8u',
    },
    [90] = {
        Name = 'SampleStructure',
        Format = 'int8u',
        PrintConv = {
            [0] = 'OrthogonalConstangSampling',
            [1] = 'Orthogonal4-2-2Sampling',
            [2] = 'CompressionDependent',
        },
    },
    [100] = {
        Name = 'ScanningDirection',
        Format = 'int8u',
        PrintConv = {
            [0] = 'L-R, Top-Bottom',
            [1] = 'R-L, Top-Bottom',
            [2] = 'L-R, Bottom-Top',
            [3] = 'R-L, Bottom-Top',
            [4] = 'Top-Bottom, L-R',
            [5] = 'Bottom-Top, L-R',
            [6] = 'Top-Bottom, R-L',
            [7] = 'Bottom-Top, R-L',
        },
    },
    [102] = {
        Name = 'IPTCImageRotation',
        Format = 'int8u',
        PrintConv = {
            [0] = 0,
            [1] = 90,
            [2] = 180,
            [3] = 270,
        },
    },
    [110] = {
        Name = 'DataCompressionMethod',
        Format = 'int32u',
    },
    [120] = {
        Name = 'QuantizationMethod',
        Format = 'int8u',
        PrintConv = {
            [0] = 'Linear Reflectance/Transmittance',
            [1] = 'Linear Density',
            [2] = 'IPTC Ref B',
            [3] = 'Linear Dot Percent',
            [4] = 'AP Domestic Analogue',
            [5] = 'Compression Method Specific',
            [6] = 'Color Space Specific',
            [7] = 'Gamma Compensated',
        },
    },
    [125] = {
        Name = 'EndPoints',
        Writable = 0,
        Binary = 1,
    },
    [130] = {
        Name = 'ExcursionTolerance',
        Format = 'int8u',
        PrintConv = {
            [0] = 'Not Allowed',
            [1] = 'Allowed',
        },
    },
    [135] = {
        Name = 'BitsPerComponent',
        Format = 'int8u',
    },
    [140] = {
        Name = 'MaximumDensityRange',
        Format = 'int16u',
    },
    [145] = {
        Name = 'GammaCompensatedValue',
        Format = 'int16u',
    },
}

-- Record 7 -- Pre-object Data
IPTC.PreObjectData = {
    -- (not actually writable, but used in BuildTagLookup to recognize IPTC tables)
    WRITE_PROC = IPTC.WriteIPTC,
    [10] = {
        Name = 'SizeMode',
        Format = 'int8u',
        PrintConv = {
            [0] = 'Size Not Known',
            [1] = 'Size Known',
        },
    },
    [20] = {
        Name = 'MaxSubfileSize',
        Format = 'int32u',
    },
    [90] = {
        Name = 'ObjectSizeAnnounced',
        Format = 'int32u',
    },
    [95] = {
        Name = 'MaximumObjectSize',
        Format = 'int32u',
    },
}

-- Record 8 -- ObjectData
IPTC.ObjectData = {
    WRITE_PROC = IPTC.WriteIPTC,
    [10] = {
        Name = 'SubFile',
        Flags = 'List',
        Binary = 1,
    },
}

-- Record 9 -- PostObjectData
IPTC.PostObjectData = {
    WRITE_PROC = IPTC.WriteIPTC,
    [10] = {
        Name = 'ConfirmedObjectSize',
        Format = 'int32u',
    },
}

-- Record 240 -- FotoStation proprietary data (ref PH)
IPTC.FotoStation = {
    GROUPS = { [2] = 'Other' },
    WRITE_PROC = IPTC.WriteIPTC,
    CHECK_PROC = IPTC.CheckIPTC,
    WRITABLE = 1,
}

-- IPTC Composite tags
IPTC.Composite = {
    GROUPS = { [2] = 'Image' },
    DateTimeCreated = {
        TagID = 'IPTC-DateTimeCreated',
        Description = 'Date/Time Created',
        Groups = { [2] = 'Time' },
        Require = { [0] = 'IPTC:DateCreated', [1] = 'IPTC:TimeCreated' },
        ValueConv = function(_self, val) return str(val[0]) .. ' ' .. str(val[1]) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    DigitalCreationDateTime = {
        TagID = 'IPTC-DigitalCreationDateTime',
        Description = 'Digital Creation Date/Time',
        Groups = { [2] = 'Time' },
        Require = { [0] = 'IPTC:DigitalCreationDate', [1] = 'IPTC:DigitalCreationTime' },
        ValueConv = function(_self, val) return str(val[0]) .. ' ' .. str(val[1]) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.IPTC', nil, IPTC)

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WriteIPTC.pl -- its subs are bound to
--  loader closures at their predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Print conversion for CodedCharacterSet
-- Inputs: 0) value
function IPTC.PrintCodedCharset(val)
    if IPTC.iptcCharset[val] then return IPTC.iptcCharset[val] end
    val = subst(val, [[(.)]], ' $1', 'g')
    val = subst(val, [[ \x1b]], ', ESC', 'g')
    val = subst(val, [[^,? ]], '')
    return val
end

--------------------------------------------------------------------------------
-- Handle CodedCharacterSet
-- Inputs: 0) ExifTool ref, 1) CodedCharacterSet value
-- Returns: IPTC character set if translation required (or 'bad' if unknown)
-- (IPTC.pm:994)
function IPTC.HandleCodedCharset(et, val)
    local xlat = IPTC.iptcCharset[val]
    if not xlat then
        if matches(val, [[^\x1b\x25]]) then
            -- some unknown character set invoked
            xlat = 'bad' -- flag unsupported coding
        else
            xlat = et:Options('CharsetIPTC')
        end
    end
    -- no need to translate if Charset is the same
    if xlat == et:Options('Charset') then xlat = nil end
    return xlat
end

--------------------------------------------------------------------------------
-- Encode or decode coded string
-- Inputs: 0) ExifTool ref, 1) value, 2) IPTC charset (or 'bad')
--         3) flag set to decode (read) value from IPTC
-- Returns: 1) the translated value, 2) the IPTC charset for the next call
-- (IPTC.pm:1016; upstream updates $$valPtr and $$xlatPtr through the two
--  refs -- Lua has no scalar refs, so both come back as return values)
function IPTC.TranslateCodedString(et, val, xlat, read)
    if xlat == 'bad' then
        et:Warn('Some IPTC characters not converted (unsupported CodedCharacterSet)')
        xlat = nil
    elseif not truthy(read) then
        val = et:Decode(val, nil, nil, xlat)
    elseif not matches(val, [=[[\x14\x15\x1b]]=]) then
        val = et:Decode(val, xlat)
    else
        -- don't yet support reading ISO 2022 shifted character sets
        et:Warn('Some IPTC characters not converted (ISO 2022 shifting not supported)')
    end
    return val, xlat
end

--------------------------------------------------------------------------------
-- Is this IPTC in a standard location?
-- Inputs: 0) Current metadata path string
-- Returns: true if path is standard, 0 if file type doesn't have standard IPTC,
--          or undef if IPTC is non-standard
function IPTC.IsStandardIPTC(path)
    if isStandardIPTC[path] then return 1 end
    local m = matches(path, [[^(\w+)]])
    if not (m and isStandardIPTC[m] ~= nil) then return 0 end
    return nil   -- non-standard
end

--------------------------------------------------------------------------------
-- get IPTC info
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
--         2) reference to tag table
-- Returns: 1 on success, 0 otherwise
function IPTC.ProcessIPTC(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or 0
    local dirEnd = pos + dirLen
    local success = 0
    local lastRec
    local recordPtr
    local recordName
    local seen = {}
    local verbose = et:Options('Verbose')
    local validate = et:Options('Validate')

    if truthy(verbose) and dirInfo then et:VerboseDir('IPTC', 0, dirInfo.DirLen) end

    if tagTablePtr == IPTC.Main then
        local path = et:MetadataPath()
        local isStd = IPTC.IsStandardIPTC(path)
        if isStd ~= nil and not et.DIR_COUNT.STD_IPTC then
            -- set flag to ensure we only have one family 1 "IPTC" group
            et.DIR_COUNT.STD_IPTC = 1
            -- calculate MD5 if Digest::MD5 is available (truly standard IPTC only)
            -- (isStd may be 0, which is defined-but-falsy in Perl but truthy
            -- in Lua -- check explicitly rather than `if isStd then`)
            if isStd ~= nil and isStd ~= 0 then
                local md5
                if et:hasMD5() then
                    md5 = et:md5(substr(dataPt, pos, dirLen))
                else
                    -- a zero digest indicates IPTC exists but we don't have Digest::MD5
                    md5 = string.rep('\0', 16)
                end
                et:FoundTag('CurrentIPTCDigest', md5)
            end
        else
            if (ExifTool.MWGstrict() or truthy(validate)) and
                matches(et.FILE_TYPE, [[^(JPEG|TIFF|PSD)$]])
            then
                if ExifTool.MWGstrict() then
                    -- ignore non-standard IPTC while in strict MWG compatibility mode
                    et:Warn('Ignored non-standard IPTC at ' .. path)
                    return 1
                else
                    et:Warn('Non-standard IPTC at ' .. path, 1)
                end
            end
            -- extract non-standard IPTC
            local count = (et.DIR_COUNT.IPTC or 0) + 1 -- count non-standard IPTC
            et.DIR_COUNT.IPTC = count
            et.LOW_PRIORITY_DIR.IPTC = 1 -- lower priority of non-standard IPTC
            et.SET_GROUP1 = '+' .. (count + 1) -- add number to family 1 group name
        end
    end
    -- begin by assuming default IPTC encoding
    local xlat = et:Options('CharsetIPTC')
    if xlat == et:Options('Charset') then xlat = nil end

    -- quick check for improperly byte-swapped IPTC
    if dirLen >= 4 and substr(dataPt, pos, 1) ~= '\x1c' and
                       substr(dataPt, pos + 3, 1) == '\x1c'
    then
        et:Warn('IPTC data was improperly byte-swapped')
        local newData = pack('N*', unpack('V*', substr(dataPt, pos, dirLen) .. '\0\0\0'))
        dataPt = newData
        pos = 0
        dirEnd = pos + dirLen
        -- NOTE: MUST NOT access $dirInfo DataPt, DirStart or DataLen after this!
    end
    -- extract IPTC as a block if specified
    -- (EXCL_TAG_LOOKUP is read nil-safe: Perl autovivifies it on the read)
    if et.REQ_TAG_LOOKUP.iptc or (et.TAGS_FROM_FILE and
        not (et.EXCL_TAG_LOOKUP and et.EXCL_TAG_LOOKUP.iptc))
    then
        if pos ~= 0 or dirLen ~= length(dataPt) then
            et:FoundTag('IPTC', substr(dataPt, pos, dirLen))
        else
            et:FoundTag('IPTC', dataPt)
        end
    end

    while pos + 5 <= dirEnd do
        local buff = substr(dataPt, pos, 5)
        local id, rec, tag, len = unpack('CCCn', buff)
        if id ~= 0x1c then
            if id == 0 then
                -- scan the rest of the data an give warning unless all zeros
                -- (iMatch pads the IPTC block with nulls for some reason)
                local remaining = substr(dataPt, pos, dirEnd - pos)
                if not matches(remaining, [=[[^\0]]=]) then break end
            end
            et:Warn(sprintf('Bad IPTC data tag (marker 0x%x)', id))
            break
        end
        pos = pos + 5 -- step to after field header
        -- handle extended IPTC entry if necessary
        if len & 0x8000 ~= 0 then
            local n = len & 0x7fff -- get num bytes in length field
            if pos + n > dirEnd or n > 8 then
                et:VPrint(0, 'Invalid extended IPTC entry (dataset ' .. rec .. ':' .. tag .. ', len ' .. len .. ')\n')
                success = 0
                break
            end
            -- determine length (a big-endian, variable sized int)
            len = 0
            while n > 0 do
                len = len * 256 + substr(dataPt, pos, 1):byte()
                pos = pos + 1
                n = n - 1
            end
        end
        if pos + len > dirEnd then
            et:VPrint(0, 'Invalid IPTC entry (dataset ' .. rec .. ':' .. tag .. ', len ' .. len .. ')\n')
            success = 0
            break
        end
        if lastRec == nil or lastRec ~= rec then
            if truthy(validate) and lastRec ~= nil and rec < lastRec then
                et:Warn("IPTC doesn't conform to spec: Records out of sequence", 1)
            end
            local tableInfo = tagTablePtr[rec]
            if not tableInfo then
                et:Warn('Unrecognized IPTC record ' .. rec .. ' (ignored)')
                pos = pos + len
                goto continue -- ignore this entry
            end
            local tableName = tableInfo.SubDirectory and tableInfo.SubDirectory.TagTable
            if not tableName then
                et:Warn('No table for IPTC record ' .. rec .. '!')
                break -- this shouldn't happen
            end
            recordName = tableInfo.Name
            recordPtr = et:GetTagTable(tableName)
            et:VPrint(0, et.INDENT .. '-- ' .. recordName .. ' record --\n')
            lastRec = rec
        end
        do
            local val = substr(dataPt, pos, len)

            -- add tagInfo for all unknown tags:
            if not recordPtr[tag] then
                -- - no Format so format is auto-detected
                -- - no Name so name is generated automatically with decimal tag number
                et:AddTagToTable(recordPtr, tag, { Unknown = 1 })
            end
            local tagInfo = et:GetTagInfo(recordPtr, tag)
            -- (Perl's `$$tagInfo{List}` below autovivifies an empty hash for a
            --  missing tagInfo, which FoundTag then rejects with "No tag name")
            if truthy(validate) and not tagInfo then tagInfo = {} end
            if truthy(validate) and not tagInfo.List and not tagInfo.Unknown then
                if seen[tagInfo] then et:Warn('Multiple IPTC ' .. tagInfo.Name .. ' tags') end
                seen[tagInfo] = 1
            end
            local format
            -- (could use $$recordPtr{FORMAT} if no Format below, but don't do this to
            --  be backward compatible with improperly written PhotoMechanic tags)
            if tagInfo then format = tagInfo.Format end
            if not format then
                -- guess at "int" format if not specified
                if len <= 4 and len ~= 3 and matches(val, [=[[\0-\x08]]=]) then format = 'int' end
            elseif truthy(validate) then
                local fmt, min, max
                local f, n1, _, n2 = matches(format, [==[(.*)\[(\d+)(,(\d+))?\]]==])
                if f then
                    fmt = f
                    min = num(n1)
                    max = truthy(n2) and num(n2) or num(n1)
                else
                    fmt = format
                    min, max = 1, 1
                end
                local siz = ExifTool.FormatSize(fmt) or 1
                min = min * siz max = max * siz
                if len < min or len > max then
                    local should = (min == max) and str(min) or
                        (len < min and (min .. ' min') or (max .. ' max'))
                    local what = (len < siz * min) and 'short' or 'long'
                    et:Warn('IPTC ' .. tagInfo.Name .. ' too ' .. what ..
                            ' (' .. len .. ' bytes; should be ' .. should .. ')', 1)
                end
            end
            if format then
                if matches(format, [[^int]]) then
                    if len <= 8 then -- limit integer conversion to 8 bytes long
                        val = 0
                        for i = 0, len - 1 do
                            val = val * 256 + substr(dataPt, pos + i, 1):byte()
                        end
                    end
                elseif matches(format, [[^string]]) then
                    -- some braindead softwares add null terminators
                    -- (the facade's subst returns no count, so test first)
                    local nulTerm = matches(val, [[\0+$]])
                    val = subst(val, [[\0+$]], '')
                    if nulTerm and truthy(validate) then
                        et:Warn('IPTC ' .. tagInfo.Name .. ' improperly terminated', 1)
                    end
                    if rec == 1 then
                        -- handle CodedCharacterSet tag
                        if tag == 90 then xlat = IPTC.HandleCodedCharset(et, val) end
                    -- translate characters if necessary and special characters exist
                    elseif xlat and rec < 7 and matches(val, [=[[\x80-\xff]]=]) then
                        -- translate to specified character set
                        val, xlat = IPTC.TranslateCodedString(et, val, xlat, 1)
                    end
                elseif matches(format, [[^digits]]) then
                    -- (the facade's subst returns no count, so test first)
                    local nulTerm = matches(val, [[\0+$]])
                    val = subst(val, [[\0+$]], '')
                    if nulTerm and truthy(validate) then
                        et:Warn('IPTC ' .. tagInfo.Name .. ' improperly terminated', 1)
                    end
                elseif not matches(format, [[^undef]]) then
                    -- (this would be a programming error)
                    print(io.stderr, 'Invalid IPTC format: ' .. format .. '\n')
                end
            end
            if truthy(verbose) then
                et:VerboseInfo(tag, tagInfo, {
                    Table   = tagTablePtr,
                    Value   = val,
                    DataPt  = dataPt,
                    DataPos = dirInfo.DataPos,
                    Size    = len,
                    Start   = pos,
                    Extra   = ', ' .. recordName .. ' record',
                    Format  = format,
                })
            end
            if tagInfo then et:FoundTag(tagInfo, val) end
            success = 1

            pos = pos + len -- increment to next field
        end
        ::continue::
    end
    et.SET_GROUP1 = nil
    et.LOW_PRIORITY_DIR.IPTC = nil
    return success
end

-- (PROCESS_PROC is set here so the table can reference the function below)
IPTC.Main.PROCESS_PROC = IPTC.ProcessIPTC

return IPTC
