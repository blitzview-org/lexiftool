--------------------------------------------------------------------------------
-- File:         lexiftool/MIE.lua
-- Ported from:  lib/Image/ExifTool/MIE.pm
--
-- Description:  Read/write MIE meta information
--
-- Revisions:    11/18/2005 - P. Harvey Created
--
-- Port notes:   Complete port of MIE.pm: every table, lookup and sub, in
--               upstream order, read and write (stand-alone files and the
--               MIE trailer, compressed elements included).  Deviations
--               forced by Lua:
--               - The predeclarations `sub ProcessMIE($$);` ... are one
--                 block of locals at the top; the subs assign to them (and
--                 are exported on the module table).
--               - `%tableDefaults,` (hash splicing) at the top of a table is
--                 the local `tableDefaults` call; its procs are `false` until
--                 the subs exist and are filled into every such table after
--                 them.  `%binaryConv`/`%dateInfo` are spelled out in each
--                 entry.  The `%offOn` that upstream splices into the
--                 ImageStabilization entry itself goes through the local
--                 `spread`, which copies its keys as strings (Perl hash
--                 keys): a Lua table with a numeric [1] key would read as
--                 a conditional list.
--               - An output file (`\$buff`) is a box `{ value = <carray> }`,
--                 written with Writer.Write; CheckMIE returns the changed
--                 value after its (nil) error, as this port's CHECK_PROC
--                 contract allows.
--               - The `MieElement:` loop label is the `nextMieElement` /
--                 `lastMieElement` goto labels.
--               - Compress::Zlib is ExifTool hasZlib/inflate/deflate.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')    -- (upstream `use Image::ExifTool::Exif`)
local GPS = require('lexiftool.GPS')      -- (upstream `use Image::ExifTool::GPS`)
local Writer = require('lexiftool.Writer')
local RandomAccess = require('lexiftool.RandomAccess')
local carray = require('carray')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local tr = perl.tr
local join = perl.join
local length = perl.length
local substr = perl.substr
local pack = perl.pack
local unpack = perl.unpack
local chr = perl.chr
local ord = perl.ord
local truthy = perl.truthy
local tsort = perl.tsort
local str = perl.str
local GetByteOrder = ExifTool.GetByteOrder
local SetByteOrder = ExifTool.SetByteOrder
local Get32u = ExifTool.Get32u
local Get64u = ExifTool.Get64u
local Set16u = ExifTool.Put16u
local Set32u = ExifTool.Put32u
local ReadValue = ExifTool.ReadValue
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local Write = Writer.Write
local WriteValue = Writer.WriteValue

local MIE = {}

-- (upstream's predeclarations `sub ProcessMIE($$);` ... are this block of
--  locals; the subs below assign to them)
local ProcessMIE, ProcessMIEGroup, WriteMIEGroup, CheckMIE, GetLangInfo

-- local variables
local hasZlib        -- 1=Zlib available, 0=no Zlib
local mieCode = {}   -- reverse lookup for MIE format names
local doneMieMap     -- flag indicating we added user-defined groups to %mieMap

-- MIE format codes
local mieFormat = {
    [0x00] = 'undef',
    [0x10] = 'MIE',
    [0x18] = 'MIE',
    [0x20] = 'string', -- ASCII (ISO 8859-1)
    [0x28] = 'utf8',
    [0x29] = 'utf16',
    [0x2a] = 'utf32',
    [0x30] = 'string_list',
    [0x38] = 'utf8_list',
    [0x39] = 'utf16_list',
    [0x3a] = 'utf32_list',
    [0x40] = 'int8u',
    [0x41] = 'int16u',
    [0x42] = 'int32u',
    [0x43] = 'int64u',
    [0x48] = 'int8s',
    [0x49] = 'int16s',
    [0x4a] = 'int32s',
    [0x4b] = 'int64s',
    [0x52] = 'rational32u',
    [0x53] = 'rational64u',
    [0x5a] = 'rational32s',
    [0x5b] = 'rational64s',
    [0x61] = 'fixed16u',
    [0x62] = 'fixed32u',
    [0x69] = 'fixed16s',
    [0x6a] = 'fixed32s',
    [0x72] = 'float',
    [0x73] = 'double',
    [0x80] = 'free',
}

-- map of MIE directory locations
local mieMap = {
   ['MIE-Meta']        = 'MIE',
   ['MIE-Audio']       = 'MIE-Meta',
   ['MIE-Camera']      = 'MIE-Meta',
   ['MIE-Doc']         = 'MIE-Meta',
   ['MIE-Geo']         = 'MIE-Meta',
   ['MIE-Image']       = 'MIE-Meta',
   ['MIE-MakerNotes']  = 'MIE-Meta',
   ['MIE-Preview']     = 'MIE-Meta',
   ['MIE-Thumbnail']   = 'MIE-Meta',
   ['MIE-Video']       = 'MIE-Meta',
   ['MIE-Flash']       = 'MIE-Camera',
   ['MIE-Lens']        = 'MIE-Camera',
   ['MIE-Orient']      = 'MIE-Camera',
   ['MIE-Extender']    = 'MIE-Lens',
   ['MIE-GPS']         = 'MIE-Geo',
   ['MIE-UTM']         = 'MIE-Geo',
   ['MIE-Canon']       = 'MIE-MakerNotes',
    EXIF               = 'MIE-Meta',
    XMP                = 'MIE-Meta',
    IPTC               = 'MIE-Meta',
    ICC_Profile        = 'MIE-Meta',
    ID3                = 'MIE-Meta',
    CanonVRD           = 'MIE-Canon',
    IFD0               = 'EXIF',
    IFD1               = 'IFD0',
    ExifIFD            = 'IFD0',
    GPS                = 'IFD0',
    SubIFD             = 'IFD0',
    GlobParamIFD       = 'IFD0',
    PrintIM            = 'IFD0',
    InteropIFD         = 'ExifIFD',
    MakerNotes         = 'ExifIFD',
}

-- convenience variables for common tagInfo entries
-- (upstream's %binaryConv = ( Writable => 'undef', Binary => 1 ) and
--  %dateInfo = ( Shift => 'Time', PrintConv => ..., PrintConvInv => ... ):
--  spelled out in each entry below -- Lua has no hash splicing)
local noYes = { [0] = 'No', [1] = 'Yes' }
local offOn = { [0] = 'Off', [1] = 'On' }

-- (port helper: Perl's `%hash` spread into a tag information hash -- its
--  keys become hash keys, i.e. strings, so `%offOn` cannot turn the entry
--  into a conditional list; explicit fields of the entry win)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            local key = str(k)
            if t[key] == nil then t[key] = v end
        end
        return t
    end
end

-- default entries for MIE tag tables
MIE.tableDefaults = {
    PROCESS_PROC = false, -- predeclaration, see below (ProcessMIE)
    WRITE_PROC   = false, -- predeclaration, see below (ProcessMIE)
    CHECK_PROC   = false, -- predeclaration, see below (CheckMIE)
    LANG_INFO    = false, -- predeclaration, see below (GetLangInfo)
    WRITABLE     = 'string',
    PREFERRED    = 1,
}
-- (`%tableDefaults,` at the top of a table: the defaults first, the table's
--  own entries after them -- see the Port notes)
local defaultedTables = {}
local function tableDefaults(t)
    for k, v in pairs(MIE.tableDefaults) do
        if t[k] == nil then t[k] = v end
    end
    defaultedTables[#defaultedTables + 1] = t
    return t
end

-- MIE info
MIE.Main = tableDefaults {
    GROUPS = { [1] = 'MIE-Main' },
    WRITE_GROUP = 'MIE-Main',
    NOTES = [[
        MIE is a flexible format which may be used as a stand-alone meta information
        format, for encapsulation of other files and information, or as a trailer
        appended to other file formats.  The tables below represent currently
        defined MIE tags, however ExifTool will also extract any other information
        present in a MIE file.

        When writing MIE information, some special features are supported:

        1) String values may be written as ASCII (ISO 8859-1) or UTF-8.  ExifTool
        automatically detects the presence of wide characters and treats the string
        appropriately. Internally, UTF-8 text may be converted to UTF-16 or UTF-32
        and stored in this format in the file if it is more compact.

        2) All MIE string-value tags support localized text.  Localized values are
        written by adding a language/country code to the tag name in the form
        C<TAG-xx_YY>, where C<TAG> is the tag name, C<xx> is a 2-character lower
        case ISO 639-1 language code, and C<YY> is a 2-character upper case ISO
        3166-1 alpha 2 country code (eg. C<Title-en_US>).  But as usual, the user
        interface is case-insensitive, and ExifTool will write the correct case to
        the file.

        3) Some numerical MIE tags allow units of measurement to be specified.  For
        these tags, units may be added in brackets immediately following the value
        (eg. C<55(mi/h)>).  If no units are specified, the default units are
        written.

        4) ExifTool writes compressed metadata to MIE files if the L<Compress|../ExifTool.html#Compress> (-z)
        option is used and Compress::Zlib is available.

        See L<https://exiftool.org/MIE1.1-20070121.pdf> for the official MIE
        specification.
    ]],
   ['0Type'] = {
        Name = 'SubfileType',
        Notes = [[
            the capitalized common extension for this type of file.  If the extension
            has a dot-3 abbreviation, then the longer version is used here. For
            instance, JPEG and TIFF are used, not JPG and TIF
        ]],
    },
   ['0Vers'] = {
        Name = 'MIEVersion',
        Notes = 'version 1.1 is assumed if not specified',
    },
   ['1Directory'] = {
        Name = 'SubfileDirectory',
        Notes = 'original directory for the file',
    },
   ['1Name']      = {
        Name = 'SubfileName',
        Notes = 'the file name, including extension if it exists',
    },
   ['2MIME']      = { Name = 'SubfileMIMEType' },
    Meta = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Meta',
            DirName = 'MIE-Meta',
        },
    },
    data = {
        Name = 'SubfileData',
        Notes = 'the subfile data',
        Writable = 'undef', Binary = 1,
    },
    rsrc = {
        Name = 'SubfileResource',
        Notes = 'subfile resource fork if it exists',
        Writable = 'undef', Binary = 1,
    },
    zmd5 = {
        Name = 'MD5Digest',
        Notes = [[
            16-byte MD5 digest written in binary form or as a 32-character hex-encoded
            ASCII string. Value is an MD5 digest of the entire 0MIE group as it would be
            with the digest value itself set to all null bytes
        ]],
    },
    zmie = {
        Name = 'TrailerSignature',
        Writable = 'undef',
        Notes = [[
            used as the last element in the main "0MIE" group to identify a MIE trailer
            when appended to another type of file.  ExifTool will create this tag if set
            to any value, but always with an empty data block
        ]],
        ValueConvInv = function(_self, _val) return '' end,   -- data block must be empty
    },
}

-- MIE meta information group
MIE.Meta = tableDefaults {
    GROUPS = { [1] = 'MIE-Meta', [2] = 'Image' },
    WRITE_GROUP = 'MIE-Meta',
    Audio = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Audio',
            DirName = 'MIE-Audio',
        },
    },
    Camera = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Camera',
            DirName = 'MIE-Camera',
        },
    },
    Document = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Doc',
            DirName = 'MIE-Doc',
        },
    },
    EXIF = {
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            WriteProc = Writer.WriteTIFF,
        },
    },
    Geo = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Geo',
            DirName = 'MIE-Geo',
        },
    },
    ICCProfile  = {
        Name = 'ICC_Profile',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    ID3  = { SubDirectory = { TagTable = 'lexiftool.ID3.Main' } },
    IPTC = { SubDirectory = { TagTable = 'lexiftool.IPTC.Main' } },
    Image = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Image',
            DirName = 'MIE-Image',
        },
    },
    MakerNotes = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.MakerNotes',
            DirName = 'MIE-MakerNotes',
        },
    },
    Preview = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Preview',
            DirName = 'MIE-Preview',
        },
    },
    Thumbnail = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Thumbnail',
            DirName = 'MIE-Thumbnail',
        },
    },
    Video = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Video',
            DirName = 'MIE-Video',
        },
    },
    XMP = { SubDirectory = { TagTable = 'lexiftool.XMP.Main' } },
}

-- MIE document information
MIE.Doc = tableDefaults {
    GROUPS = { [1] = 'MIE-Doc', [2] = 'Document' },
    WRITE_GROUP = 'MIE-Doc',
    NOTES = 'Information describing the main document, image or file.',
    Author      = { Groups = { [2] = 'Author' } },
    Comment     = { },
    Contributors= { Groups = { [2] = 'Author' }, List = 1 },
    Copyright   = { Groups = { [2] = 'Author' } },
    CreateDate  = { Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val) end,
    },
    EMail       = { Name = 'Email', Groups = { [2] = 'Author' } },
    Keywords    = { List = 1 },
    ModifyDate  = { Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val) end,
    },
    OriginalDate= {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val) end,
    },
    Phone       = { Name = 'PhoneNumber', Groups = { [2] = 'Author' } },
    References  = { List = 1 },
    Software    = { },
    Title       = { },
    URL         = { },
}

-- MIE geographic information
MIE.Geo = tableDefaults {
    GROUPS = { [1] = 'MIE-Geo', [2] = 'Location' },
    WRITE_GROUP = 'MIE-Geo',
    NOTES = 'Information related to geographic location.',
    Address     = { },
    City        = { },
    Country     = { },
    GPS = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.GPS',
            DirName = 'MIE-GPS',
        },
    },
    PostalCode  = { },
    State       = { Notes = 'state or province' },
    UTM = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.UTM',
            DirName = 'MIE-UTM',
        },
    },
}

-- MIE GPS information
MIE.GPS = tableDefaults {
    GROUPS = { [1] = 'MIE-GPS', [2] = 'Location' },
    WRITE_GROUP = 'MIE-GPS',
    Altitude   = {
        Name = 'GPSAltitude',
        Writable = 'rational64s',
        Units = { 'm', 'ft' },
        Notes = [['m' above sea level unless 'ft' specified]],
    },
    Bearing = {
        Name = 'GPSDestBearing',
        Writable = 'rational64s',
        Units = { 'deg', 'deg{mag}' },
        Notes = [['deg' CW from true north unless 'deg{mag}' specified]],
    },
    Datum   = { Name = 'GPSMapDatum', Notes = 'WGS-84 assumed if not specified' },
    Differential = {
        Name = 'GPSDifferential',
        Writable = 'int8u',
        PrintConv = {
            [0] = 'No Correction',
            [1] = 'Differential Corrected',
        },
    },
    Distance = {
        Name = 'GPSDestDistance',
        Writable = 'rational64s',
        Units = { 'km', 'mi', 'nmi' },
        Notes = [['km' unless 'mi' or 'nmi' specified]],
    },
    Heading  = {
        Name = 'GPSTrack',
        Writable = 'rational64s',
        Units = { 'deg', 'deg{mag}' },
        Notes = [['deg' CW from true north unless 'deg{mag}' specified]],
    },
    Latitude = {
        Name = 'GPSLatitude',
        Writable = 'rational64s',
        Count = -1,
        Notes = [[
            1 to 3 numbers: degrees, minutes then seconds.  South latitudes are stored
            as all negative numbers, but may be entered as positive numbers with a
            trailing 'S' for convenience.  For example, these are all equivalent: "-40
            -30", "-40.5", "40 30 0.00 S"
        ]],
        ValueConv    = function(_self, val) return GPS.ToDegrees(val, 1) end,
        ValueConvInv = function(self, val) return GPS.ToDMS(self, val, 3) end,
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lat') end,
    },
    Longitude = {
        Name = 'GPSLongitude',
        Writable = 'rational64s',
        Count = -1,
        Notes = [[
            1 to 3 numbers: degrees, minutes then seconds.  West longitudes are
            negative, but may be entered as positive numbers with a trailing 'W'
        ]],
        ValueConv    = function(_self, val) return GPS.ToDegrees(val, 1) end,
        ValueConvInv = function(self, val) return GPS.ToDMS(self, val, 3) end,
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lon') end,
    },
    MeasureMode = {
        Name = 'GPSMeasureMode',
        Writable = 'int8u',
        PrintConv = { [2] = '2-D', [3] = '3-D' },
    },
    Satellites = 'GPSSatellites',
    Speed = {
        Name = 'GPSSpeed',
        Writable = 'rational64s',
        Units = { 'km/h', 'mi/h', 'm/s', 'kn' },
        Notes = [['km/h' unless 'mi/h', 'm/s' or 'kn' specified]],
    },
    DateTime = { Name = 'GPSDateTime', Groups = { [2] = 'Time' },
        Shift = 'Time',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return Writer.InverseDateTime(self, val) end,
    },
}

-- MIE UTM information
MIE.UTM = tableDefaults {
    GROUPS = { [1] = 'MIE-UTM', [2] = 'Location' },
    WRITE_GROUP = 'MIE-UTM',
    Datum    = { Name = 'UTMMapDatum', Notes = 'WGS-84 assumed if not specified' },
    Easting  = { Name = 'UTMEasting' },
    Northing = { Name = 'UTMNorthing' },
    Zone     = { Name = 'UTMZone', Writable = 'int8s' },
}

-- MIE image information
MIE.Image = tableDefaults {
    GROUPS = { [1] = 'MIE-Image', [2] = 'Image' },
    WRITE_GROUP = 'MIE-Image',
   ['0Type']          = { Name = 'FullSizeImageType', Notes = 'JPEG if not specified' },
   ['1Name']          = { Name = 'FullSizeImageName' },
    BitDepth        = { Name = 'BitDepth', Writable = 'int16u' },
    ColorSpace      = { Notes = 'standard ColorSpace values are "sRGB" and "Adobe RGB"' },
    Components      = {
        Name = 'ComponentsConfiguration',
        Notes = 'string composed of R, G, B, Y, Cb and Cr',
    },
    Compression     = { Name = 'CompressionRatio', Writable = 'rational32u' },
    OriginalImageSize = { -- PH added 2022-09-28
        Writable = 'int16u',
        Count = -1,
        Notes = 'size of original image before cropping',
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        PrintConvInv = function(_self, val) val = tr(val, 'x', ' ') return val end,
    },
    ImageSize       = {
        Writable = 'int16u',
        Count = -1,
        Notes = '2 or 3 values, for number of XY or XYZ pixels',
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        PrintConvInv = function(_self, val) val = tr(val, 'x', ' ') return val end,
    },
    Resolution      = {
        Writable = 'rational64u',
        Units = { '/in', '/cm', '/deg', '/arcmin', '/arcsec', '' },
        Count = -1,
        Notes = [[
            1 to 3 values.  A single value for equal resolution in all directions, or
            separate X, Y and Z values if necessary.  Units are '/in' unless '/cm',
            '/deg', '/arcmin', '/arcsec' or '' specified
        ]],
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        PrintConvInv = function(_self, val) val = tr(val, 'x', ' ') return val end,
    },
    data = {
        Name = 'FullSizeImage',
        Groups = { [2] = 'Preview' },
        Writable = 'undef', Binary = 1,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

-- MIE preview image
MIE.Preview = tableDefaults {
    GROUPS = { [1] = 'MIE-Preview', [2] = 'Image' },
    WRITE_GROUP = 'MIE-Preview',
   ['0Type']  = { Name = 'PreviewImageType', Notes = 'JPEG if not specified' },
   ['1Name']  = { Name = 'PreviewImageName' },
    ImageSize = {
        Name = 'PreviewImageSize',
        Writable = 'int16u',
        Count = -1,
        Notes = '2 or 3 values, for number of XY or XYZ pixels',
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        PrintConvInv = function(_self, val) val = tr(val, 'x', ' ') return val end,
    },
    data = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Writable = 'undef', Binary = 1,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

-- MIE thumbnail image
MIE.Thumbnail = tableDefaults {
    GROUPS = { [1] = 'MIE-Thumbnail', [2] = 'Image' },
    WRITE_GROUP = 'MIE-Thumbnail',
   ['0Type']  = { Name = 'ThumbnailImageType', Notes = 'JPEG if not specified' },
   ['1Name']  = { Name = 'ThumbnailImageName' },
    ImageSize = {
        Name = 'ThumbnailImageSize',
        Writable = 'int16u',
        Count = -1,
        Notes = '2 or 3 values, for number of XY or XYZ pixels',
        PrintConv = function(_self, val) val = tr(val, ' ', 'x') return val end,
        PrintConvInv = function(_self, val) val = tr(val, 'x', ' ') return val end,
    },
    data = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Writable = 'undef', Binary = 1,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

-- MIE audio information
MIE.Audio = tableDefaults {
    GROUPS = { [1] = 'MIE-Audio', [2] = 'Audio' },
    WRITE_GROUP = 'MIE-Audio',
    NOTES = [[
        For the Audio group (and any other group containing a 'data' element), tags
        refer to the contained data if present, otherwise they refer to the main
        SubfileData.  The C<0Type> and C<1Name> elements should exist only if C<data>
        is present.
    ]],
   ['0Type']      = { Name = 'RelatedAudioFileType', Notes = 'MP3 if not specified' },
   ['1Name']      = { Name = 'RelatedAudioFileName' },
    SampleBits  = { Writable = 'int16u' },
    Channels    = { Writable = 'int8u' },
    Compression = { Name = 'AudioCompression' },
    Duration    = { Writable = 'rational64u', PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end },
    SampleRate  = { Writable = 'int32u' },
    data        = { Name = 'RelatedAudioFile', Writable = 'undef', Binary = 1 },
}

-- MIE video information
MIE.Video = tableDefaults {
    GROUPS = { [1] = 'MIE-Video', [2] = 'Video' },
    WRITE_GROUP = 'MIE-Video',
   ['0Type']      = { Name = 'RelatedVideoFileType', Notes = 'MOV if not specified' },
   ['1Name']      = { Name = 'RelatedVideoFileName' },
    Codec       = { },
    Duration    = { Writable = 'rational64u', PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end },
    data        = { Name = 'RelatedVideoFile', Writable = 'undef', Binary = 1 },
}

-- MIE camera information
MIE.Camera = tableDefaults {
    GROUPS = { [1] = 'MIE-Camera', [2] = 'Camera' },
    WRITE_GROUP = 'MIE-Camera',
    Brightness      = { Writable = 'int8s' },
    ColorTemperature= { Writable = 'int32u' },
    ColorBalance    = {
        Writable = 'rational64u',
        Count = 3,
        Notes = 'RGB scaling factors',
    },
    Contrast        = { Writable = 'int8s' },
    DigitalZoom     = { Writable = 'rational64u' },
    ExposureComp    = { Name = 'ExposureCompensation', Writable = 'rational64s' },
    ExposureMode    = { },
    ExposureTime    = {
        Writable = 'rational64u',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    Flash = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Flash',
            DirName = 'MIE-Flash',
        },
    },
    FirmwareVersion = { },
    FocusMode       = { },
    ISO             = { Writable = 'int16u' },
    ISOSetting      = {
        Writable = 'int16u',
        Notes = '0 = Auto, otherwise manual ISO speed setting',
    },
    ImageNumber     = { Writable = 'int32u' },
    ImageQuality    = { Notes = 'Economy, Normal, Fine, Super Fine or Raw' },
    ImageStabilization = spread(offOn) { Writable = 'int8u' },
    Lens = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Lens',
            DirName = 'MIE-Lens',
        },
    },
    Make            = { },
    MeasuredEV      = { Writable = 'rational64s' },
    Model           = { },
    OwnerName       = { },
    Orientation     = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Orient',
            DirName = 'MIE-Orient',
        },
    },
    Saturation      = { Writable = 'int8s' },
    SensorSize      = {
        Writable = 'rational64u',
        Count = 2,
        Notes = 'width and height of active sensor area in mm',
    },
    SerialNumber    = { },
    Sharpness       = { Writable = 'int8s' },
    ShootingMode    = { },
}

-- Camera orientation information
MIE.Orient = tableDefaults {
    GROUPS = { [1] = 'MIE-Orient', [2] = 'Camera' },
    WRITE_GROUP = 'MIE-Orient',
    NOTES = 'These tags describe the camera orientation.',
    Azimuth     = {
        Writable = 'rational64s',
        Units = { 'deg', 'deg{mag}' },
        Notes = [['deg' CW from true north unless 'deg{mag}' specified]],
    },
    Declination = { Writable = 'rational64s' },
    Elevation   = { Writable = 'rational64s' },
    RightAscension = { Writable = 'rational64s' },
    Rotation = {
        Writable = 'rational64s',
        Notes = 'CW rotation angle of camera about lens axis',
    },
}

-- MIE camera lens information
MIE.Lens = tableDefaults {
    GROUPS = { [1] = 'MIE-Lens', [2] = 'Camera' },
    WRITE_GROUP = 'MIE-Lens',
    NOTES = [[
        All recorded lens parameters (focal length, aperture, etc) include the
        effects of the extender if present.
    ]],
    Extender = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Extender',
            DirName = 'MIE-Extender',
        },
    },
    FNumber         = { Writable = 'rational64u' },
    FocalLength     = { Writable = 'rational64u', Notes = 'all focal lengths in mm' },
    FocusDistance   = {
        Writable = 'rational64u',
        Units = { 'm', 'ft' },
        Notes = [['m' unless 'ft' specified]],
    },
    Make            = { Name = 'LensMake' },
    MaxAperture     = { Writable = 'rational64u' },
    MaxApertureAtMaxFocal = { Writable = 'rational64u' },
    MaxFocalLength  = { Writable = 'rational64u' },
    MinAperture     = { Writable = 'rational64u' },
    MinFocalLength  = { Writable = 'rational64u' },
    Model           = { Name = 'LensModel' },
    OpticalZoom     = { Writable = 'rational64u' },
    SerialNumber    = { Name = 'LensSerialNumber' },
}

-- MIE lens extender information
MIE.Extender = tableDefaults {
    GROUPS = { [1] = 'MIE-Extender', [2] = 'Camera' },
    WRITE_GROUP = 'MIE-Extender',
    Magnification   = { Name = 'ExtenderMagnification', Writable = 'rational64s' },
    Make            = { Name = 'ExtenderMake' },
    Model           = { Name = 'ExtenderModel' },
    SerialNumber    = { Name = 'ExtenderSerialNumber' },
}

-- MIE camera flash information
MIE.Flash = tableDefaults {
    GROUPS = { [1] = 'MIE-Flash', [2] = 'Camera' },
    WRITE_GROUP = 'MIE-Flash',
    ExposureComp    = { Name = 'FlashExposureComp', Writable = 'rational64s' },
    Fired           = { Name = 'FlashFired', Writable = 'int8u', PrintConv = noYes },
    GuideNumber     = { Name = 'FlashGuideNumber' },
    Make            = { Name = 'FlashMake' },
    Mode            = { Name = 'FlashMode' },
    Model           = { Name = 'FlashModel' },
    SerialNumber    = { Name = 'FlashSerialNumber' },
    Type            = { Name = 'FlashType', Notes = '"Internal" or "External"' },
}

-- MIE maker notes information
MIE.MakerNotes = tableDefaults {
    GROUPS = { [1] = 'MIE-MakerNotes' },
    WRITE_GROUP = 'MIE-MakerNotes',
    NOTES = [[
        MIE maker notes are contained within separate groups for each manufacturer
        to avoid name conflicts.
    ]],
    Canon = {
        SubDirectory = {
            TagTable = 'lexiftool.MIE.Canon',
            DirName = 'MIE-Canon',
        },
    },
    Casio       = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    FujiFilm    = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Kodak       = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    KonicaMinolta={ SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Nikon       = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Olympus     = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Panasonic   = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Pentax      = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Ricoh       = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Sigma       = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
    Sony        = { SubDirectory = { TagTable = 'lexiftool.MIE.Unknown' } },
}

-- MIE Canon-specific information
MIE.Canon = tableDefaults {
    GROUPS = { [1] = 'MIE-Canon' },
    WRITE_GROUP = 'MIE-Canon',
    VRD = {
        Name = 'CanonVRD',
        SubDirectory = { TagTable = 'lexiftool.CanonVRD.Main' },
    },
}

MIE.Unknown = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [1] = 'MIE-Unknown' },
}

--------------------------------------------------------------------------------
-- Add user-defined MIE groups to %mieMap
-- Inputs: none;  Returns: nothing, but sets $doneMieMap flag
local function UpdateMieMap()
    doneMieMap = 1    -- set flag so we only do this once
    if not (ExifTool.UserDefined and next(ExifTool.UserDefined) ~= nil) then return end
    local tables, doneTable = {}, {}
    -- get list of top-level MIE tables with user-defined tags
    for tableName in pairs(ExifTool.UserDefined) do
        if not isMatch(tableName, [[^lexiftool\.MIE\.]]) then goto continue end
        do
            local userTable = ExifTool.UserDefined[tableName]
            local tagTablePtr = GetTagTable(nil, tableName)
            if not tagTablePtr then goto continue end
            -- copy the WRITE_GROUP from the actual table
            userTable.WRITE_GROUP = tagTablePtr.WRITE_GROUP
            -- add to list of tables to process
            doneTable[tableName] = 1
            tables[#tables + 1] = { tableName, userTable }
        end
        ::continue::
    end
    -- recursively add all user-defined groups to MIE map
    while #tables > 0 do
        local tableName, tagTablePtr = table.unpack(table.remove(tables, 1))
        local parent = tagTablePtr.WRITE_GROUP
        if not parent then perl.print(io.stderr, 'No WRITE_GROUP for ' .. tableName .. "\n") goto nextTable end
        if not mieMap[parent] then perl.print(io.stderr, parent .. " is not in MIE map\n") goto nextTable end
        for _, tagID in ipairs(ExifTool.TagTableKeys(tagTablePtr)) do
            local tagInfo = tagTablePtr[tagID]
            if not (type(tagInfo) == 'table' and tagInfo.SubDirectory) then goto nextTag end
            do
                local subTableName = tagInfo.SubDirectory.TagTable
                local subTablePtr = GetTagTable(nil, subTableName)
                if not subTablePtr then goto nextTag end
                -- only care about MIE tables
                if not (subTablePtr.PROCESS_PROC and
                        subTablePtr.PROCESS_PROC == ProcessMIE) then goto nextTag end
                local group = subTablePtr.WRITE_GROUP
                if not group then perl.print(io.stderr, 'No WRITE_GROUP for ' .. subTableName .. "\n") goto nextTag end
                if mieMap[group] and mieMap[group] ~= parent then
                    perl.print(io.stderr, group .. ' already has different parent (' .. mieMap[group] .. ")\n")
                    goto nextTag
                end
                mieMap[group] = parent  -- add to map
                -- process tables within this one too
                if doneTable[subTableName] then goto nextTag end
                doneTable[subTableName] = 1
                tables[#tables + 1] = { subTableName, subTablePtr }
            end
            ::nextTag::
        end
        ::nextTable::
    end
end

--------------------------------------------------------------------------------
-- Get localized version of tagInfo hash
-- Inputs: 0) tagInfo hash ref, 1) locale code (eg. "en_CA")
-- Returns: new tagInfo hash ref, or undef if invalid
function GetLangInfo(tagInfo, langCode)
    -- check for properly formatted language code
    local sep = matches(langCode, '^[a-z]{2}([-_])[A-Z]{2}$')
    if not sep then return nil end
    -- use '_' as a separator, but recognize '_' or '-'
    if sep == '-' then langCode = tr(langCode, '-', '_') end
    -- can only set locale on string types
    if tagInfo.Writable and tagInfo.Writable ~= 'string' then return nil end
    return Writer.GetLangInfo(tagInfo, langCode)
end

--------------------------------------------------------------------------------
-- return true if we have Zlib::Compress
-- Inputs: 0) ExifTool object ref, 1) verb for what you want to do with the info
-- Returns: 1 if Zlib available, 0 otherwise
local function HasZlib(et, verb)
    if hasZlib == nil then
        hasZlib = et:hasZlib() and 1 or 0   -- (`eval { require Compress::Zlib }`)
        if not truthy(hasZlib) then
            hasZlib = 0
            et:Warn('Install Compress::Zlib to ' .. verb .. ' compressed information')
        end
    end
    return hasZlib
end

--------------------------------------------------------------------------------
-- Get format code for MIE group element with current byte order
-- Inputs: 0) [optional] true to convert result to chr()
-- Returns: format code
local function MIEGroupFormat(chr_)
    local format = GetByteOrder() == 'MM' and 0x10 or 0x18
    if truthy(chr_) then return chr(format) end
    return format
end

--------------------------------------------------------------------------------
-- ReadValue() with added support for UTF formats (utf8, utf16 and utf32)
-- Inputs: 0) data reference, 1) value offset, 2) format string,
--         3) number of values (or undef to use all data)
--         4) valid data length relative to offset, 5) returned rational ref
-- Returns: converted value, or undefined if data isn't there
--          or list of values in list context
-- Notes: all string formats are converted to UTF8
local function ReadMIEValue(dataPt, offset, format, count, size, ratPt)
    local val
    local c1 = matches(format, [[^(utf(8|16|32)|string)]])
    if c1 then
        if c1 == 'utf8' or c1 == 'string' then
            -- read the 8-bit string
            val = substr(dataPt, offset, size)
            -- (as of ExifTool 7.62, leave string values unconverted)
        else
            -- convert to UTF8
            local fmt
            if GetByteOrder() == 'MM' then
                fmt = (c1 == 'utf16') and 'n' or 'N'
            else
                fmt = (c1 == 'utf16') and 'v' or 'V'
            end
            local unpk = { unpack('x' .. offset .. fmt .. size, dataPt) }
            val = pack('C0U*', table.unpack(unpk))
        end
        -- truncate at null unless this is a list
        -- (strings shouldn't have a null, but just in case)
        if not isMatch(format, '_list$') then val = subst(val, [[(?s)\0.*]], '') end
    else
        if format == 'free' then format = 'undef' end -- read 'free' as 'undef'
        return ReadValue(dataPt, offset, format, count, size, ratPt)
    end
    return val
end

--------------------------------------------------------------------------------
-- validate raw values for writing
-- Inputs: 0) ExifTool object ref, 1) tagInfo hash ref, 2) raw value ref
-- Returns: error string or undef (and possibly changes value) on success
-- (the changed value is the second return value, see the Port notes)
function CheckMIE(et, tagInfo, valPtr)
    local format = tagInfo.Writable or tagInfo.Table.WRITABLE
    local err

    if not truthy(format) or format == '1' or format == 1 then return 'No writable format' end
    -- handle units if supported by this tag
    local ulist = tagInfo.Units
    local val, units
    if ulist then val, units = matches(valPtr, [[(.*)\((.*)\)$]]) end
    if ulist and val then
        local found
        for _, u in ipairs(ulist) do
            if isMatchDyn(u, '(?i)^' .. units .. '$') then found = u break end
        end
        units = found
        if units == nil then return 'Allowed units: (' .. join('|', ulist) .. ')' end
        local v2
        err, v2 = Writer.CheckValue(val, format, tagInfo.Count)
        if v2 ~= nil then val = v2 end
        -- add units back onto value
        if not err then valPtr = val .. '(' .. units .. ')' end
    elseif not isMatch(format, '^(utf|string|undef)') and isMatch(valPtr, [[\)$]]) then
        return 'Units not supported'
    else
        if format == 'string' and et.OPTIONS.Charset ~= 'UTF8' and
            isMatch(valPtr, [=[[\x80-\xff]]=])
        then
            -- convert from Charset to UTF-8
            valPtr = et:Encode(valPtr, 'UTF8')
        end
        local v2
        err, v2 = Writer.CheckValue(valPtr, format, tagInfo.Count)
        if v2 ~= nil then valPtr = v2 end
    end
    return err, valPtr
end

--------------------------------------------------------------------------------
-- Rewrite a MIE directory
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) tag table ptr
-- Returns: undef on success, otherwise error message (empty message if nothing to write)
function WriteMIEGroup(et, dirInfo, tagTablePtr)
    local outfile = dirInfo.OutFile
    local dirName = dirInfo.DirName
    local toWrite = dirInfo.ToWrite or ''
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local optCompress = et:Options('Compress')
    local out = et:Options('TextOut') or io.stdout   -- (TextOut defaults to STDOUT)
    local msg, err, ok, sync, delGroup
    local tag = ''
    local deletedTag = ''

    -- count each MIE directory found and make name for this specific instance
    local grp1
    local isWriting = {}
    local cnt = et.MIE_COUNT
    local grp = tagTablePtr.GROUPS[1]
    local n = cnt['MIE-Main'] or 0
    if grp == 'MIE-Main' then
        n = n + 1
        cnt[grp] = n
        grp1 = subst(grp, 'MIE-', 'MIE' .. n .. '-')
    else
        grp1 = subst(grp, 'MIE-', 'MIE' .. n .. '-')
        cnt[grp1] = (cnt[grp1] or 0) + 1
        local m = cnt[grp1]
        isWriting[grp .. m] = 1     -- eg. 'MIE-Doc2'
        isWriting[grp1] = 1         -- eg. 'MIE1-Doc'
        grp1 = grp1 .. m
    end
    -- build lookup for all valid group names for this MIE group
    isWriting[grp] = 1              -- eg. 'MIE-Doc'
    isWriting[grp1] = 1             -- eg. 'MIE1-Doc2'
    isWriting['MIE' .. n] = 1       -- eg. 'MIE1'

    -- determine if we are deleting this group
    if et.DEL_GROUP and next(et.DEL_GROUP) ~= nil then
        if Writer.IsGroupDeleted(et, 'MIE') or
           Writer.IsGroupDeleted(et, grp) or
           Writer.IsGroupDeleted(et, grp1) or
           Writer.IsGroupDeleted(et, 'MIE' .. n)
        then
            delGroup = 1
        end
    end

    -- prepare lookups and lists for writing
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
    local addDirs, editDirs = Writer.GetAddDirHash(et, tagTablePtr, dirName)
    local editTags = {}
    for k in pairs(newTags) do editTags[#editTags + 1] = k end
    for k in pairs(editDirs) do editTags[#editTags + 1] = k end
    tsort(editTags)    -- (`sort keys %$newTags, keys %$editDirs`)
    if truthy(verbose) then out:write(raf and 'Writing' or 'Creating', ' ', grp1, ":\n") end

    -- loop through elements in MIE group
    while true do  -- (MieElement:)
        local format, tagLen, valLen, units, oldHdr, buff
        local lastTag = tag
        if raf then
            -- read first 4 bytes of element header
            local n_
            n_, oldHdr = raf:Read(4)
            if n_ ~= 4 then
                if n_ ~= 0 or sync ~= nil then goto lastMieElement end
                raf = nil -- all done reading
                ok = 1
            end
        end
        if raf then
            sync, format, tagLen, valLen = unpack('aC3', oldHdr)
            if sync ~= '~' then msg = 'Invalid sync byte' goto lastMieElement end

            -- read tag name
            if truthy(tagLen) then
                local n_
                n_, tag = raf:Read(tagLen)
                if n_ ~= tagLen then goto lastMieElement end
                oldHdr = oldHdr .. tag  -- add tag to element header
                if perl.lt(tag, lastTag) then et:Warn("MIE tag '" .. tag .. "' out of sequence") end
                -- separate units from tag name if they exist
                local u = matches(tag, [[\((.*)\)$]])
                if u then
                    units = u
                    tag = subst(tag, [[\((.*)\)$]], '')
                end
            else
                tag = ''
            end

            -- get multi-byte value length if necessary
            if valLen > 252 then
                -- calculate number of bytes in extended DataLength
                local n_ = 1 << (256 - valLen)
                local nRead
                nRead, buff = raf:Read(n_)
                if nRead ~= n_ then goto lastMieElement end
                oldHdr = oldHdr .. buff -- add to old header
                local fmt = 'int' .. (n_ * 8) .. 'u'
                valLen = ReadValue(buff, 0, fmt, 1, n_)
                if valLen > 0x7fffffff then
                    msg = "Can't write " .. tag .. ' (DataLength > 2GB not yet supported)'
                    goto lastMieElement
                end
            end
            -- don't rewrite free bytes or information in deleted groups
            if format == 0x80 or (delGroup and truthy(tagLen) and (format & 0xf0) ~= 0x10) then
                if not raf:Seek(valLen, 1) then msg = 'Seek error' goto lastMieElement end
                if perl.num(verbose) > 1 then
                    local free = (format == 0x80) and ' free' or ''
                    out:write('    - ', grp1, ':', tag, ' (', valLen, free, " bytes)\n")
                end
                if delGroup then et.CHANGED = (et.CHANGED or 0) + 1 end
                goto nextMieElement
            end
        else
            -- no more elements to read
            tagLen = 0
            valLen = 0
            tag = ''
        end
--
-- write necessary new tags and process directories
--
        while #editTags > 0 do
            if truthy(tagLen) and perl.lt(tag, editTags[1]) then break end
            -- we are writing the new tag now
            local newVal, writable, oldVal, newFormat, compress
            local newTag = table.remove(editTags, 1)
            if length(newTag) > 255 then et:Warn('Tag name too long') goto nextEditTag end -- (just to be safe)
            do
                local newInfo = editDirs[newTag]
                if newInfo then
                    -- create the new subdirectory or rewrite existing non-MIE directory
                    local subTablePtr = GetTagTable(nil, newInfo.SubDirectory.TagTable)
                    if not subTablePtr then
                        et:Warn('No tag table for ' .. newTag .. ' ' .. newInfo.Name)
                        goto nextEditTag
                    end
                    local subdirInfo = {}
                    local isMieGroup = (subTablePtr.WRITE_PROC and
                                        subTablePtr.WRITE_PROC == ProcessMIE)

                    if newTag == tag then
                        -- make sure that either both or neither old and new tags are MIE groups
                        if (isMieGroup and true or false) ~= ((format & 0xf3) == 0x10) then
                            et:Warn("Tag '" .. tag .. "' not expected type")
                            goto nextEditTag   -- don't write our new tag
                        end
                        -- uncompress existing directory into $oldVal since we are editing it
                        if (format & 0x04) ~= 0 then
                            if not truthy(HasZlib(et, 'edit')) then break end
                            local n_
                            n_, oldVal = raf:Read(valLen)
                            if n_ ~= valLen then goto lastMieElement end
                            local stat
                            oldVal, stat = et:inflate(oldVal)
                            if not stat then   -- (`$stat == Compress::Zlib::Z_STREAM_END()`)
                                msg = 'Error inflating ' .. tag
                                goto lastMieElement
                            end
                            compress = 1
                            valLen = length(oldVal)    -- uncompressed value length
                        end
                    else
                        -- don't create this directory unless necessary
                        if not addDirs[newTag] then goto nextEditTag end
                    end

                    if isMieGroup then
                        local hdr
                        if newTag == tag then
                            -- rewrite existing directory later unless it was compressed
                            if not compress then break end
                            -- rewrite directory to '$newVal'
                            newVal = { value = carray.new('char') }   -- (handed out as \$newVal)
                            subdirInfo = {
                                OutFile = newVal,
                                RAF = RandomAccess.new(oldVal),
                            }
                        elseif truthy(optCompress) and not dirInfo.IsCompressed then
                            -- write to memory so we can compress the new MIE group
                            compress = 1
                            newVal = { value = nil }  -- (handed out as \$newVal)
                            subdirInfo = {
                                OutFile = newVal,
                            }
                        else
                            hdr = '~' .. MIEGroupFormat(1) .. chr(length(newTag)) ..
                                  "\0" .. newTag
                            subdirInfo = {
                                OutFile = outfile,
                                ToWrite = toWrite .. hdr,
                            }
                        end
                        subdirInfo.DirName = newInfo.SubDirectory.DirName or newTag
                        subdirInfo.Parent = dirName
                        -- don't compress elements of an already compressed group
                        subdirInfo.IsCompressed = dirInfo.IsCompressed or compress
                        msg = WriteMIEGroup(et, subdirInfo, subTablePtr)
                        if truthy(msg) then goto lastMieElement end
                        -- message is defined but empty if nothing was written
                        if msg ~= nil then
                            msg = nil -- not a problem if nothing was written
                            goto nextEditTag
                        elseif not compress then
                            -- group was written already
                            toWrite = ''
                            goto nextEditTag
                        end
                        newVal = newVal.value   -- (the written group, a carray -- or undef)
                        if newVal ~= nil then newVal = newVal:tostring() end
                        if newVal == nil or length(newVal) <= 4 then    -- terminator only?
                            if truthy(verbose) then out:write('Deleted compressed ', grp1, " (empty)\n") end
                            if newTag == tag then goto nextMieElement end -- deleting the directory
                            goto nextEditTag       -- not creating the new directory
                        end
                        writable = 'undef'
                        newFormat = MIEGroupFormat()
                    else
                        if newTag == tag then
                            if not compress then
                                -- read and edit existing directory
                                local n_
                                n_, oldVal = raf:Read(valLen)
                                if n_ ~= valLen then goto lastMieElement end
                            end
                            subdirInfo = {
                                DataPt  = oldVal,
                                DataLen = valLen,
                                DirName = newInfo.Name,
                                DirStart= 0,
                                DirLen  = valLen,
                            }
                            if not dirInfo.IsCompressed then subdirInfo.DataPos = raf:Tell() - valLen end
                            -- write Compact subdirectories if we will compress the data
                            if (compress or truthy(optCompress) or dirInfo.IsCompressed) and
                                et:hasZlib()   -- (`eval { require Compress::Zlib }`)
                            then
                                subdirInfo.Compact = 1
                                subdirInfo.ReadOnly = 1  -- because XMP is not writable in place
                            end
                        end
                        subdirInfo.Parent = dirName
                        local writeProc = newInfo.SubDirectory.WriteProc
                        -- reset processed lookup to avoid errors in case of multiple EXIF blocks
                        et.PROCESSED = { }
                        newVal = Writer.WriteDirectory(et, subdirInfo, subTablePtr, writeProc)
                        if newVal ~= nil then
                            if newVal == '' then
                                if newTag == tag then goto nextMieElement end -- deleting the directory
                                goto nextEditTag       -- not creating the new directory
                            end
                        else
                            if oldVal == nil then goto nextEditTag end
                            newVal = oldVal  -- just copy over the old directory
                        end
                        writable = 'undef'
                        newFormat = 0x00  -- all other directories are 'undef' format
                    end
                else

                    -- get the new tag information
                    newInfo = newTags[newTag]
                    local nvHash = Writer.GetNewValueHash(et, newInfo)
                    local newVals = {}

                    -- write information only to specified group
                    local writeGroup = nvHash.WriteGroup
                    if not isWriting[writeGroup] then break end

                    -- if tag existed, must decide if we want to overwrite the value
                    if newTag == tag then
                        local isOverwriting
                        local isList = newInfo.List
                        if isList then
                            if nvHash.CreateOnly then break end
                            isOverwriting = -1    -- force processing list elements individually
                        else
                            isOverwriting = Writer.IsOverwriting(et, nvHash)
                            if not truthy(isOverwriting) then break end
                        end
                        local val, cmpVal
                        if isOverwriting < 0 or perl.num(verbose) > 1 then
                            -- check to be sure we can uncompress the value if necessary
                            if (format & 0x04) ~= 0 and not truthy(HasZlib(et, 'edit')) then break end
                            -- read the old value
                            local n_
                            n_, oldVal = raf:Read(valLen)
                            if n_ ~= valLen then goto lastMieElement end
                            -- uncompress if necessary
                            if (format & 0x04) ~= 0 then
                                local stat
                                -- must save original compressed value in case we decide
                                -- not to overwrite it later
                                cmpVal = oldVal
                                oldVal, stat = et:inflate(oldVal)
                                if not stat then   -- (`$stat == Compress::Zlib::Z_STREAM_END()`)
                                    msg = 'Error inflating ' .. tag
                                    goto lastMieElement
                                end
                                valLen = length(oldVal)    -- update value length
                            end
                            -- convert according to specified format
                            local formatStr = mieFormat[format & 0xfb] or 'undef'
                            val = ReadMIEValue(oldVal, 0, formatStr, nil, valLen)
                            if isOverwriting < 0 and val ~= nil then
                                -- handle list values individually
                                if isList then
                                    local vals
                                    if isMatch(formatStr, '_list$') then
                                        vals = split([[\0]], val)
                                    else
                                        vals = { val }
                                    end
                                    -- keep any list items that we aren't overwriting
                                    for _, v in ipairs(vals) do
                                        if not truthy(Writer.IsOverwriting(et, nvHash, v)) then
                                            newVals[#newVals + 1] = v
                                        end
                                    end
                                else
                                    -- test to see if we really want to overwrite the value
                                    isOverwriting = Writer.IsOverwriting(et, nvHash, val)
                                end
                            end
                        end
                        if truthy(isOverwriting) then
                            -- skip the old value if we didn't read it already
                            if oldVal == nil then
                                if not raf:Seek(valLen, 1) then msg = 'Seek error' end
                            end
                            if perl.num(verbose) > 1 then
                                if units ~= nil then val = perl.str(val) .. '(' .. units .. ')' end
                                et:VerboseValue('- ' .. grp1 .. ':' .. newInfo.Name, val)
                            end
                            deletedTag = tag       -- remember that we deleted this tag
                            et.CHANGED = (et.CHANGED or 0) + 1 -- we deleted the old value
                        else
                            if oldVal ~= nil then
                                -- write original compressed value
                                if cmpVal ~= nil then oldVal = cmpVal end
                            else
                                local n_
                                n_, oldVal = raf:Read(valLen)
                                if n_ ~= valLen then goto lastMieElement end
                            end
                            -- write the old value now
                            if not Write(outfile, toWrite, oldHdr, oldVal) then err = 1 end
                            toWrite = ''
                            goto nextMieElement
                        end
                        if #newVals == 0 then
                            -- unshift the new tag info to write it later
                            table.insert(editTags, 1, newTag)
                            goto nextMieElement    -- get next element from file
                        end
                    else
                        -- write new value if creating, or if List and list existed, or
                        -- if tag was previously deleted
                        if not (truthy(nvHash.IsCreating) or
                            (newTag == lastTag and (newInfo.List or deletedTag == lastTag)))
                        then
                            goto nextEditTag
                        end
                    end
                    -- get the new value to write (undef to delete)
                    -- (GetNewValue in list context: all the values)
                    for _, v in ipairs(et:GetNewValue(nvHash, true)) do
                        newVals[#newVals + 1] = v
                    end
                    if #newVals == 0 then goto nextEditTag end
                    writable = newInfo.Writable or tagTablePtr.WRITABLE
                    if writable == 'string' then
                        -- join multiple values into a single string
                        newVal = join("\0", newVals)
                        -- write string as UTF-8,16 or 32 if value contains valid UTF-8 codes
                        local isUTF8 = ExifTool.IsUTF8(newVal)
                        if isUTF8 > 0 then
                            writable = 'utf8'
                            -- write UTF-16 or UTF-32 if it is more compact
                            local to = isUTF8 > 1 and 'UCS4' or 'UTF16'
                            local tmp = ExifTool.Decode(nil, newVal, 'UTF8', nil, to)
                            if length(tmp) < length(newVal) then
                                newVal = tmp
                                writable = (isUTF8 > 1) and 'utf32' or 'utf16'
                            end
                        end
                        -- write as a list if we have multiple values
                        if #newVals > 1 then writable = writable .. '_list' end
                    else
                        -- should only be one element in the list
                        newVal = table.remove(newVals, 1)
                    end
                    newFormat = mieCode[writable]
                    if newFormat == nil then
                        msg = "Bad format '" .. writable .. "' for " .. newInfo.Name
                        goto nextMieElement
                    end
                end

                -- write the new or edited element
                while newFormat ~= nil do -- luacheck: ignore 512
                    local valPt = newVal
                    -- remove units from value and add to tag name if supported by this tag
                    if newInfo.Units then
                        local val2
                        local c1, c2 = matches(valPt, [[(.*)\((.*)\)$]])
                        if c1 then
                            val2 = c1
                            newTag = newTag .. '(' .. c2 .. ')'
                        else
                            val2 = valPt
                            -- add default units
                            local ustr = '(' .. newInfo.Units[1] .. ')'
                            newTag = newTag .. ustr
                            newVal = newVal .. ustr
                        end
                        valPt = val2
                    end
                    -- convert value if necessary
                    if not isMatch(writable, '^(utf|string|undef)') then
                        local val3 = WriteValue(valPt, writable, newInfo.Count)
                        if val3 == nil then et:Warn('Error writing ' .. newTag) break end
                        valPt = val3
                    end
                    local len = length(valPt)
                    -- compress value before writing if required
                    if (compress or truthy(optCompress)) and not dirInfo.IsCompressed and
                        truthy(HasZlib(et, 'write'))
                    then
                        local val4 = et:deflate(valPt) -- (deflateInit/deflate/flush)
                        if val4 ~= nil then
                            local len4 = length(val4)
                            local saved = len - len4
                            -- only use compressed data if it is smaller
                            if saved > 0 then
                                if truthy(verbose) then out:write('  [', newTag, ' compression saved ', saved, " bytes]\n") end
                                newFormat = newFormat | 0x04 -- set compressed bit
                                len = len4       -- set length
                                valPt = val4     -- set value pointer
                            elseif truthy(verbose) then
                                out:write('  [', newTag, ' compression saved ', saved, " bytes -- written uncompressed]\n")
                            end
                        else
                            et:Warn('Error deflating ' .. newTag .. ' (written uncompressed)')
                        end
                    end
                    -- calculate the DataLength code
                    local extLen
                    if len < 253 then
                        extLen = ''
                    elseif len < 65536 then
                        extLen = Set16u(len)
                        len = 255
                    elseif len <= 0x7fffffff then
                        extLen = Set32u(len)
                        len = 254
                    else
                        et:Warn("Can't write " .. newTag .. ' (DataLength > 2GB not yet supported)')
                        break -- don't write this tag
                    end
                    -- write this element (with leading MIE group element if not done already)
                    local hdr = toWrite .. '~' .. chr(newFormat) .. chr(length(newTag))
                    if not Write(outfile, hdr, chr(len), newTag, extLen, valPt) then err = 1 end
                    toWrite = ''
                    -- we changed a tag unless just editing a subdirectory
                    if not editDirs[newTag] then
                        et:VerboseValue('+ ' .. grp1 .. ':' .. newInfo.Name, newVal)
                        et.CHANGED = (et.CHANGED or 0) + 1
                    end
                    break   -- didn't want to loop anyway
                end
                if oldVal ~= nil then goto nextMieElement end
            end
            ::nextEditTag::
        end
--
-- rewrite existing element or descend into uncompressed MIE group
--
        -- all done this MIE group if we reached the terminator element
        if not truthy(tagLen) then
            -- skip over existing terminator data (if any)
            if truthy(valLen) and not raf:Seek(valLen, 1) then goto lastMieElement end
            ok = 1
            -- write group terminator if necessary
            if not truthy(toWrite) then
                -- write end-of-group terminator element
                local term = "~\0\0\0"
                if not dirInfo.Parent then
                    -- write extended terminator for file-level group
                    local len = Writer.Tell(outfile)
                    -- include length of terminator itself minus original $outfile position
                    len = len + 10 - (dirInfo.OutPos or 0)
                    if truthy(len) and len <= 0x7fffffff then
                        term = "~\0\0\x06" .. Set32u(len) .. MIEGroupFormat(1) .. "\x04"
                    end
                end
                if not Write(outfile, term) then err = 1 end
            end
            goto lastMieElement
        end

        -- descend into existing uncompressed MIE group
        if format == 0x10 or format == 0x18 then
            local subTablePtr, dirName_   -- (upstream's inner `my $dirName`)
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if tagInfo and tagInfo.SubDirectory then
                dirName_ = tagInfo.SubDirectory.DirName
                local subTable = tagInfo.SubDirectory.TagTable
                subTablePtr = subTable and GetTagTable(nil, subTable) or tagTablePtr
            else
                subTablePtr = GetTagTable(nil, 'lexiftool.MIE.Unknown')
            end
            local hdr = '~' .. chr(format) .. chr(length(tag)) .. "\0" .. tag
            local subdirInfo = {
                DirName = dirName_ or tag,
                RAF     = raf,
                ToWrite = toWrite .. hdr,
                OutFile = outfile,
                Parent  = dirName_,
                IsCompressed = dirInfo.IsCompressed,
            }
            local oldOrder = GetByteOrder()
            SetByteOrder((format & 0x08) ~= 0 and 'II' or 'MM')
            msg = WriteMIEGroup(et, subdirInfo, subTablePtr)
            SetByteOrder(oldOrder)
            if truthy(msg) then goto lastMieElement end
            if msg ~= nil then
                msg = nil -- no problem if nothing written
            else
                toWrite = ''
            end
            goto nextMieElement
        end
        do
            -- just copy existing element
            local n_, oldVal = raf:Read(valLen)
            if n_ ~= valLen then goto lastMieElement end
            if truthy(toWrite) then
                if not Write(outfile, toWrite) then err = 1 end
                toWrite = ''
            end
            if not Write(outfile, oldHdr, oldVal) then err = 1 end
        end
        ::nextMieElement::
    end
    ::lastMieElement::
    -- return error message
    if err then
        msg = 'Error writing file'
    elseif not ok and not msg then
        msg = 'Unexpected end of file'
    elseif not msg and truthy(toWrite) then
        msg = ''  -- flag for nothing written
        if truthy(verbose) then out:write('Deleted ', grp1, " (empty)\n") end
    end
    return msg
end

--------------------------------------------------------------------------------
-- Process MIE directory
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) tag table ref
-- Returns: undef on success, or error message if there was a problem
-- Notes: file pointer is positioned at the MIE end on entry
function ProcessMIEGroup(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout   -- (TextOut defaults to STDOUT)
    local notUTF8 = (et.OPTIONS.Charset ~= 'UTF8')
    local msg, buff, ok, oldIndent, mime
    local lastTag = ''

    -- get group 1 names: $grp doesn't have numbers (eg. 'MIE-Doc'),
    -- and $grp1 does (eg. 'MIE1-Doc1')
    local cnt = et.MIE_COUNT
    local grp1 = tagTablePtr.GROUPS[1]
    local n = cnt['MIE-Main'] or 0
    if grp1 == 'MIE-Main' then
        n = n + 1
        cnt[grp1] = n
        if n > 1 then grp1 = subst(grp1, 'MIE-', 'MIE' .. n .. '-') end
    else
        if n > 1 then grp1 = subst(grp1, 'MIE-', 'MIE' .. n .. '-') end
        cnt[grp1] = (cnt[grp1] or 0) + 1
        if cnt[grp1] > 1 then grp1 = grp1 .. cnt[grp1] end
    end
    -- set group1 name for all tags extracted from this group
    et.SET_GROUP1 = grp1

    if truthy(verbose) then
        oldIndent = et.INDENT
        et.INDENT = et.INDENT .. '| '
        et:VerboseDir(grp1)
    end
    local wasCompressed = dirInfo.WasCompressed

    -- process all MIE elements
    while true do
        local nRead
        nRead, buff = raf:Read(4)
        if nRead ~= 4 then break end
        local sync, format, tagLen, valLen = unpack('aC3', buff)
        if sync ~= '~' then msg = 'Invalid sync byte' break end

        -- read tag name
        local tag, units
        if truthy(tagLen) then
            nRead, tag = raf:Read(tagLen)
            if nRead ~= tagLen then break end
            if perl.lt(tag, lastTag) then et:Warn("MIE tag '" .. tag .. "' out of sequence") end
            lastTag = tag
            -- separate units from tag name if they exist
            local u = matches(tag, [[\((.*)\)$]])
            if u then
                units = u
                tag = subst(tag, [[\((.*)\)$]], '')
            end
        else
            tag = ''
        end

        -- get multi-byte value length if necessary
        if valLen > 252 then
            local n_ = 1 << (256 - valLen)
            nRead, buff = raf:Read(n_)
            if nRead ~= n_ then break end
            local fmt = 'int' .. (n_ * 8) .. 'u'
            valLen = ReadValue(buff, 0, fmt, 1, n_)
            if valLen > 0x7fffffff then
                msg = "Can't read " .. tag .. ' (DataLength > 2GB not yet supported)'
                break
            end
        end

        -- all done if we reached the group terminator
        if not truthy(tagLen) then
            -- skip over terminator data block
            if not (truthy(valLen) and not raf:Seek(valLen, 1)) then ok = 1 end
            break
        end

        -- get tag information hash unless this is free space
        local tagInfo, value
        while format ~= 0x80 do -- luacheck: ignore 512
            tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if tagInfo then break end
            -- extract tags with locale code
            if isMatch(tag, [[\W]]) then
                local baseTag, langCode = matches(tag, [[^(\w+)-([a-z]{2}_[A-Z]{2})$]])
                if baseTag then
                    tagInfo = et:GetTagInfo(tagTablePtr, baseTag)
                    if tagInfo then tagInfo = GetLangInfo(tagInfo, langCode) end
                    if tagInfo then break end
                else
                    et:Warn('Invalid MIE tag name')
                    break
                end
            end
            -- extract unknown tags if specified
            tagInfo = {
                Name = tag,
                Writable = 0,
                PrintConv = function(self, val) return ExifTool.LimitLongValues(val, self) end,
            }
            AddTagToTable(nil, tagTablePtr, tag, tagInfo)
            break
        end

        -- read value and uncompress if necessary
        local formatStr = mieFormat[format & 0xfb] or 'undef'
        if tagInfo or (formatStr == 'MIE' and (format & 0x04) ~= 0) then
            nRead, value = raf:Read(valLen)
            if nRead ~= valLen then break end
            if (format & 0x04) ~= 0 then
                if truthy(verbose) then
                    out:write(et.INDENT, "[Tag '", tag, "' ", valLen, " bytes compressed]\n")
                end
                if not truthy(HasZlib(et, 'decode')) then goto continue end
                local stat
                value, stat = et:inflate(value)
                if not stat then   -- (`$stat == Compress::Zlib::Z_STREAM_END()`)
                    et:Warn('Error inflating ' .. tag)
                    goto continue
                end
                valLen = length(value)
                wasCompressed = 1
            end
        end

        -- process this tag
        if formatStr == 'MIE' then
            -- process MIE directory
            local subTablePtr, dirName
            if tagInfo and tagInfo.SubDirectory then
                dirName = tagInfo.SubDirectory.DirName
                local subTable = tagInfo.SubDirectory.TagTable
                subTablePtr = subTable and GetTagTable(nil, subTable) or tagTablePtr
            else
                subTablePtr = GetTagTable(nil, 'lexiftool.MIE.Unknown')
            end
            if truthy(verbose) then
                local order = ', byte order ' .. GetByteOrder()
                et:VerboseInfo(tag, tagInfo, { Size = valLen, Extra = order })
            end
            local subdirInfo = {
                DirName = dirName or tag,
                RAF     = raf,
                Parent  = dirInfo.DirName,
                WasCompressed = wasCompressed,
            }
            -- read from uncompressed data instead if necessary
            if truthy(valLen) then subdirInfo.RAF = RandomAccess.new(value) end

            local oldOrder = GetByteOrder()
            SetByteOrder((format & 0x08) ~= 0 and 'II' or 'MM')
            msg = ProcessMIEGroup(et, subdirInfo, subTablePtr)
            SetByteOrder(oldOrder)
            et.SET_GROUP1 = grp1   -- restore this group1 name
            if msg then break end
        else
            -- process MIE data format types
            if tagInfo then
                local rational, binVal
                -- extract tag value
                local ratPt = { }   -- (upstream `\$rational`)
                local val = ReadMIEValue(value, 0, formatStr, nil, valLen, ratPt)
                rational = ratPt.rat
                if truthy(et.OPTIONS.SaveBin) then binVal = substr(value, 0, valLen) end
                if val == nil then
                    et:Warn('Error reading ' .. tag .. ' value')
                    val = '<err>'
                end
                -- save type or mime type
                if tag == '0Type' or tag == '2MIME' then mime = val end
                if truthy(verbose) then
                    local count
                    local s = ExifTool.FormatSize(formatStr)
                    if truthy(s) and not isMatch(formatStr, '^(utf|string|undef)') then
                        count = valLen / s
                    end
                    local dataPos
                    if not wasCompressed then dataPos = raf:Tell() - valLen end
                    et:VerboseInfo(lastTag, tagInfo, {
                        DataPt  = value,
                        DataPos = dataPos,
                        Size    = valLen,
                        Format  = formatStr,
                        Value   = val,
                        Count   = count,
                    })
                end
                if tagInfo.SubDirectory then
                    local subTablePtr = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                    local subdirInfo = {
                        DirName = tagInfo.Name,
                        DataPt  = value,
                        DataLen = valLen,
                        DirStart= 0,
                        DirLen  = valLen,
                        Parent  = dirInfo.DirName,
                        WasCompressed = wasCompressed,
                    }
                    -- set DataPos and Base for uncompressed information only
                    if not wasCompressed then
                        subdirInfo.DataPos = 0 -- (relative to Base)
                        subdirInfo.Base    = raf:Tell() - valLen
                    end
                    -- reset PROCESSED lookup for each MIE directory
                    -- (there is no possibility of double-processing a MIE directory)
                    et.PROCESSED = { }
                    local processProc = tagInfo.SubDirectory.ProcessProc
                    et.SET_GROUP1 = nil
                    et.NO_LIST = nil
                    et:ProcessDirectory(subdirInfo, subTablePtr, processProc)
                    et.SET_GROUP1 = grp1
                    et.NO_LIST = 1
                else
                    -- convert to specified character set if necessary
                    if notUTF8 and isMatch(formatStr, '^(utf|string)') then
                        val = et:Decode(val, 'UTF8')
                    end
                    if isMatch(formatStr, '_list$') then
                        -- split list value into separate strings
                        local vals = split([[\0]], val)
                        val = vals
                    end
                    if units ~= nil then
                        if type(val) == 'table' then val = join(' ', val) end -- convert string list to number list
                        -- add units to value if specified
                        if units ~= nil then val = perl.str(val) .. '(' .. units .. ')' end
                    end
                    local key = et:FoundTag(tagInfo, val)
                    if key ~= nil then
                        local ex = et.TAG_EXTRA[key]
                        if ex == nil then ex = {} et.TAG_EXTRA[key] = ex end
                        if rational ~= nil then ex.Rational = rational end
                        if binVal ~= nil then ex.BinVal = binVal end
                        if truthy(et.OPTIONS.SaveFormat) then ex.G6 = formatStr end
                    end
                end
            else
                -- skip over unknown information or free bytes
                if not raf:Seek(valLen, 1) then msg = 'Seek error' break end
                if truthy(verbose) then et:VerboseInfo(tag, nil, { Size = valLen }) end
            end
        end
        ::continue::
    end
    -- modify MIME type if necessary
    if mime and not dirInfo.Parent then et:ModifyMimeType(mime) end

    if not (ok or msg) then msg = 'Unexpected end of file' end
    if truthy(verbose) then et.INDENT = oldIndent end
    return msg
end

--------------------------------------------------------------------------------
-- Read/write a MIE file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid MIE file, or -1 on write error
-- - process as a trailer if "Trailer" flag set in dirInfo
function ProcessMIE(et, dirInfo)
    if et == nil then return 1 end
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local buff, err, msg, pos, end_, isCreating
    local numDocs = 0
--
-- process as a trailer (from end of file) if specified
--
    if dirInfo.Trailer then
        local offset = dirInfo.Offset or 0    -- offset from end of file
        if not raf:Seek(-10 - offset, 2) then return 0 end
        while true do
            -- read and validate last 10 bytes
            local nRead
            nRead, buff = raf:Read(10)
            if nRead ~= 10 then break end
            local c1, c2 = matches(buff, [[(?s)~\0\0\x06.{4}(\x10|\x18)(\x04)$]])
            if not c1 then c1, c2 = matches(buff, [[(?s)(\x10|\x18)(\x08)$]]) end
            if not c1 then break end
            SetByteOrder(c1 == "\x10" and 'MM' or 'II')
            local len = (c2 == "\x04") and Get32u(buff, 4) or Get64u(buff, 0)
            local curPos = raf:Tell()
            if not truthy(curPos) then break end
            if len < 12 or len > curPos then break end
            -- validate element header if 8-byte offset was used
            if c2 == "\x08" then
                if len < 14 then break end
                if not raf:Seek(curPos - 14, 0) then break end
                nRead, buff = raf:Read(4)
                if not truthy(nRead) then break end
                if buff ~= "~\0\0\x0a" then break end
            end
            -- looks like a good group, so remember start position
            pos = curPos - len
            if not end_ then end_ = curPos end
            -- seek to 10 bytes from end of previous group
            if not raf:Seek(pos - 10, 0) then break end
        end
        -- seek to start of first MIE group
        if not (pos ~= nil and raf:Seek(pos, 0)) then return 0 end
        -- update DataPos and DirLen for ProcessTrailers()
        dirInfo.DataPos = pos
        dirInfo.DirLen = end_ - pos
        if outfile and Writer.IsGroupDeleted(et, 'MIE') then
            -- delete the trailer
            et:VPrint(0, "  Deleting MIE trailer\n")
            et.CHANGED = (et.CHANGED or 0) + 1
            return 1
        elseif truthy(et:Options('Verbose')) or et.HTML_DUMP then
            et:DumpTrailer(dirInfo)
        end
    end
--
-- loop through all documents in MIE file
--
    while true do
        -- look for "0MIE" group element
        local num
        num, buff = raf:Read(8)
        if num == 8 then
            -- verify file identifier
            local c1, c2 = matches(buff, [[(?s)^~(\x10|\x18)\x04(.)0MIE]])
            if c1 then
                SetByteOrder(c1 == "\x10" and 'MM' or 'II')
                local len = ord(c2)
                -- skip extended DataLength if it exists
                if len > 252 and not raf:Seek(1 << (256 - len), 1) then
                    msg = 'Seek error' -- luacheck: ignore 311 (unused upstream too)
                    break
                end
            else
                if numDocs == 0 then return 0 end   -- not a MIE file
                if isMatch(buff, '^~') then
                    msg = 'Non-standard file-level MIE element'
                else
                    msg = 'Invalid MIE file-level data'
                end
            end
        elseif numDocs ~= 0 then
            if num == 0 then break end   -- OK, all done with file
            msg = 'Truncated MIE element header'
        else
            if num ~= 0 or not outfile then return 0 end
            -- we have the ability to create a MIE file from scratch
            buff = '' -- luacheck: ignore 311 (start from nothing)
            -- set byte order according to preferences
            Writer.SetPreferredByteOrder(et)
            isCreating = 1
        end
        if msg then
            if dirInfo.Trailer then break end -- allow other trailers after MIE
            if outfile then
                et:Error(msg)
            else
                et:Warn(msg)
            end
            break
        end
        -- this is a new MIE document -- increment document count
        if numDocs == 0 then
            -- this is a valid MIE file (unless a trailer on another file)
            et:SetFileType()
            et.NO_LIST = 1   -- handle lists ourself
            et.MIE_COUNT = { }
            hasZlib = nil
        end
        numDocs = numDocs + 1

        do
            -- process the MIE groups recursively, beginning with the main MIE group
            local tagTablePtr = GetTagTable(nil, 'lexiftool.MIE.Main')

            local subdirInfo = {
                DirName = 'MIE',
                RAF = raf,
                OutFile = outfile,
                -- don't define Parent so WriteMIEGroup() writes extended terminator
            }
            if outfile then
                -- save start position in $outfile
                subdirInfo.OutPos = Writer.Tell(outfile)
                -- generate lookup for MIE format codes if not done already
                if next(mieCode) == nil then
                    for k, v in pairs(mieFormat) do
                        mieCode[v] = k
                    end
                end
                -- update %mieMap with user-defined MIE groups
                if not doneMieMap then UpdateMieMap() end
                -- initialize write directories, with MIE tags taking priority
                -- (note that this may re-initialize directories when writing trailer
                --  to another type of image, but this is OK because we are done writing
                --  the other format by the time we start writing the trailer)
                Writer.InitWriteDirs(et, mieMap, 'MIE')
                subdirInfo.ToWrite = '~' .. MIEGroupFormat(1) .. "\x04\xfe0MIE\0\0\0\0"
                msg = WriteMIEGroup(et, subdirInfo, tagTablePtr)
                if truthy(msg) then
                    et:Error(msg)
                    err = 1
                    break
                elseif msg ~= nil and isCreating then
                    break
                end
            else
                msg = ProcessMIEGroup(et, subdirInfo, tagTablePtr)
                if msg then
                    et:Warn(msg)
                    break
                end
            end
        end
    end
    et.NO_LIST = nil
    et.MIE_COUNT = nil
    et.SET_GROUP1 = nil
    if err then return -1 end
    return 1
end

MIE.UpdateMieMap = UpdateMieMap
MIE.GetLangInfo = GetLangInfo
MIE.HasZlib = HasZlib
MIE.MIEGroupFormat = MIEGroupFormat
MIE.ReadMIEValue = ReadMIEValue
MIE.CheckMIE = CheckMIE
MIE.WriteMIEGroup = WriteMIEGroup
MIE.ProcessMIEGroup = ProcessMIEGroup
MIE.ProcessMIE = ProcessMIE

-- (PROCESS_PROC/WRITE_PROC/CHECK_PROC/LANG_INFO of the tables above: the
--  %tableDefaults procs exist only now, see the predeclaration placeholders)
MIE.tableDefaults.PROCESS_PROC = ProcessMIE
MIE.tableDefaults.WRITE_PROC   = ProcessMIE
MIE.tableDefaults.CHECK_PROC   = CheckMIE
MIE.tableDefaults.LANG_INFO    = GetLangInfo
for _, t in ipairs(defaultedTables) do
    for k, v in pairs(MIE.tableDefaults) do
        if t[k] == false then t[k] = v end
    end
end
MIE.Unknown.PROCESS_PROC = ProcessMIE

return MIE
