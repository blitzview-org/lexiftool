--------------------------------------------------------------------------------
-- File:         lexiftool.lua
-- Ported from:  lib/Image/ExifTool.pm
--
-- Description:  Read and write meta information
--
-- URL:          https://exiftool.org/
--
-- Revisions:    Nov. 12/2003 - P. Harvey Created
--               (See html/history.html for revision history)
--
-- Legal:        Copyright (c) 2003-2026, Phil Harvey (philharvey66 at gmail.com)
--               This library is free software; you can redistribute it and/or
--               modify it under the same terms as Perl itself.
--
-- Port notes:   read path subset; container/tag-table modules are loaded
--               lazily on first access, like upstream.
--               ProcessJPEG is ported in full, segment branch for segment
--               branch (incl. %markerLenBytes, the J2C markers, the
--               "Unknown ... segment" warning and the trailer/preview
--               scan) and the ImageDataHash of the image data.
--               %jpegMarker is published as ExifTool.jpegMarker, as
--               upstream's package hash, for Jpeg2000's %j2cMarker.
--               %readValueProc has every upstream format; Writer.pl's
--               Get64s/Get64u/GetFixed64s/GetExtended (Writer.lua) are
--               reached through AUTOLOAD stand-ins here, like the other
--               Writer.pl subs (SetNewValue, TimeNow, IsRawType, WriteInfo,
--               WriteJPEG, HexDump, VerboseInfo, ...): each stand-in calls
--               DoAutoLoad with the Perl name of the sub.
--               The :DataAccess readers go through DoUnpackStd/DoUnpack/
--               DoUnpackDbl with %unpackStd and $swapBytes as upstream; the
--               in-place Set8u/Set16u/Set32u take the buffer first
--               (Set16u(dataPt, pos, val)), the returning forms are Put*.
--               new() loads @availableOptions through ClearOptions;
--               %Image::ExifTool::UserDefined::Options is
--               ExifTool.UserDefinedOptions.  The Win32::API and
--               Win32API::File calls of the MSWin32 branches are made
--               natively by lexiftool.sys (names in UTF-8, widened there):
--               GetFullPathNameW for WindowsLongPath (get_full_path_name),
--               GetFileAttributesW for IsDirectory/FileAttributes/
--               ZoneIdentifier (get_file_attributes), CreateFileW for
--               Exists (create_file_read) and Open (open) and
--               GetFileTime on the open handle for GetFileTime's daylight
--               savings workaround (get_file_time), which ExtractInfo
--               applies to the stat times on MSWin32 as upstream.
--               Options('TimeZone') writes $ENV{TZ}
--               through perl.setenv and calls perl.tzset (lexiftool.sys),
--               a process-wide side effect exactly as upstream's.  The
--               NoWarning expression is validated by compiling it with
--               PCRE2, so an invalid one is warned in PCRE2's words.  Warn
--               follows upstream (NoWarning, the 0x04 no-count bit).
--               ExtractInfo generates the ExifTool tags Now, NewGUID,
--               NewUUID, FileSequence and ProcessingTime (Time::HiRes is the
--               facade's, over lexiftool.sys) and the System tags BaseName,
--               FilePath and those of the SystemTags option as upstream,
--               the MSWin32 FileAttributes/ZoneIdentifier, the Linux
--               File::StatX FileCreateDate, and (darwin only) ResourceForkSize
--               plus the MDItem/XAttr/FileCreateDate call into MacOS.lua
--               (upstream's $plainFile gate is this branch's stat succeeding,
--               since the port merged upstream's two stat-taking branches
--               into one); not yet: the macOS
--               write side (SetMacOSTags), and upstream's $isDir path for a
--               directory Open cannot open (Windows: it gets "Error opening
--               file" instead of FileType DIR).
--               DoProcessTIFF's write branch (`if ($outfile)`) is its own
--               function, processTIFFWrite; ProcessTIFF takes it when the
--               dirInfo carries an OutFile. EncodeFileName returns the
--               (possibly recoded) name as a second value instead of changing
--               its argument; on Windows it reports the wide name and applies
--               WindowsLongPath as upstream (the wide name stays UTF-8).
--               AddCompositeTags/AddTagsToLookup as upstream: a module adds
--               its Composite tags to the one %Composite table while it
--               loads (passing its module table, since it is not yet in
--               package.loaded); BuildCompositeTags makes sure of Exif.lua's,
--               which upstream always has.  BuildCompositeTags follows
--               ExifTool.pm line for line (passes with @deferredTags,
--               %notBuilt, the per-index Require/Desire/Inhibit loop, SubDoc
--               documents, alternate files) and stores the hash of tag keys
--               (%tagKey, with COMP_KEYS), which GetValue converts lazily as
--               upstream; FoundTag runs the Composite RawConv on it with the
--               raw values (@val) as its value argument and the hash after
--               the tag name, and a Composite ValueConv takes (self, @val,
--               @prt), its PrintConv (self, $val, @val, @prt).  FoundTag does
--               not take the hash-of-tag-keys values a Composite RawConv
--               hands it (PreviewImage's second preview, further
--               OtherImages).
--               The UserParam option is ported with its tag table and the
--               '#'-parameters DoneExtract turns into tags; GetFileType has
--               its description form (%fileDescription); FoundTag keeps
--               HAS_DOC.  Open() returns its handle instead of filling one
--               in, and opens STDIN/STDOUT for '-' as upstream's two-argument
--               open does.  The :Public functions of Writer.pl the exiftool
--               script imports (GetAllTags, GetWritableTags, GetAllGroups)
--               and IsWritable/GetNewValues are AUTOLOAD stand-ins here too.
--               The .ExifTool_config block (upstream file scope) is
--               ExifTool.LoadConfigFiles, run by main after its -config scan
--               or else by the first new(); it looks the file up as upstream
--               (EXIFTOOL_HOME/HOME/HOMEDRIVE+HOMEPATH via perl.getenv, the
--               exe directory, "Config file not found"), preferring
--               lexiftool's own .lexiftool_config.  A config file is Lua
--               (doc/configuration.md): a chunk returning upstream's
--               UserDefined package variables as one table, which it puts
--               where the port reads them (ExifTool.UserDefined keyed by the
--               port's table names, ExifTool.UserDefinedTables,
--               UserDefinedOptions, UserDefinedArguments); Perl expression
--               strings in its conversions run through perl.eval.  A Perl
--               config file warns "Config file not supported by lexiftool
--               (Perl code): FILE" instead of being loaded.  The user-defined
--               Lenses and FileTypes blocks after the loop are part of
--               LoadConfigFiles.  GetTagTable adds %UserDefined tags as
--               upstream, and warns "Can't find table" for every table it
--               cannot find, in upstream's spelling of the name.
--               ExtractInfo creates the ImageDataHash digest object for a
--               requested ImageDataHash as upstream (ImageHashType MD5,
--               SHA256 or SHA512) and DoneExtract stores its hex digest:
--               Digest::SHA->new is ExifTool.DigestSHA and Digest::MD5->new
--               is ExifTool.DigestMD5, both incremental digest objects of
--               the `digest` rock.  The member $$self{ImageDataHash}
--               shares its name with the ImageDataHash method: it is stored
--               through ExifTool.ImageDataHashMember, a wrapper that keeps
--               `self:ImageDataHash(...)` calling the method, and read with
--               rawget(self, 'ImageDataHash').
--------------------------------------------------------------------------------

-- Main module: the ExifTool object plus the shared read machinery
-- (FoundTag/GetValue/GetInfo, TIFF/EXIF dispatch, directory processing,
-- file system tags). Container/tag-table modules (Exif.lua, IPTC.lua,
-- ICC_Profile.lua) hold their own tables and processing routines and are
-- reached through the tag-table registry.
--
-- Call convention for primitives shared with the container modules: the
-- primitive readers (Get8u/Get16u/..., ReadValue, SetByteOrder) are module
-- statics. Ported modules call them as `et.Func(...)` (dot-style), which
-- resolves through the object metatable to the static without passing `self`;
-- the TestLib-facing statics keep their upstream dot-style signatures.

local perl = require('lexiftool.perl')
local tsort = perl.tsort
local sys = require('lexiftool.sys')
local unpack_ = perl.unpack
local pack = perl.pack
local substr = perl.substr
local carray = require('carray')
local sprintf = perl.sprintf
local localtime = perl.localtime
local gmtime = perl.gmtime
local strftime = perl.strftime
local RandomAccess = require('lexiftool.RandomAccess')
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst

-- Load a ported container module by its short name ('Exif', 'IPTC', ...).
-- Mirror of upstream's lazy `eval "require $module"` in GetTagTable: modules
-- load on first use (require caches them via package.loaded), and a name that
-- doesn't map to a ported module yields nil instead of an error.
local function loadModule(modName)
    local ok, mod = pcall(require, 'lexiftool.' .. modName)
    if ok then return mod end
    return nil
end

local ExifTool = {}
ExifTool.__index = ExifTool

-- Treat an option value as enabled only when it is a Perl-truthy value
-- (nil/false/0 are all off in Perl; 0 is truthy in Lua, so it must be mapped).
local function optOn(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- Perl truthiness lives in the facade (perl.truthy), like every other Perl
-- primitive. The local alias is kept because this file alone tests it dozens
-- of times, and ExifTool.perlTruthy because the ported modules reach it that
-- way -- the same shape as ExifTool.md5 or ExifTool.inflate.
local perlTruthy = perl.truthy
ExifTool.perlTruthy = perlTruthy

-- $Image::ExifTool::MWG::strict, as the Exif/IPTC/Photoshop/XMP readers
-- test it (Exif.pm:6316, IPTC.pm:1086, Photoshop.pm:1029, XMP.pm:4286).
-- A Perl package variable reads as undef while MWG.pm is not loaded; a
-- Lua module field only exists once the module is, and requiring
-- lexiftool.MWG from here would load it for every file and reorder the
-- Composite builds (BuildCompositeTags goes by package.loaded) -- so look
-- the module up instead of requiring it.
function ExifTool.MWGstrict()
    local MWG = package.loaded['lexiftool.MWG']
    return type(MWG) == 'table' and perlTruthy(MWG.strict)
end

local VERSION = '13.59'
local RELEASE = ''

-- Package-level version constants (mirror of $Image::ExifTool::VERSION /
-- $Image::ExifTool::RELEASE); used by the test harness tolerance rules.
ExifTool.VERSION = VERSION
ExifTool.RELEASE = ''

-- Port-only: the module's own release, the Lua convention (digest._VERSION,
-- lfs._VERSION, ...), independent of the ExifTool.VERSION/RELEASE pair
-- above. The build's git-describe identity, baked in by the launcher/build
-- script as _G.LEXIFTOOL_PORT_VERSION (CONTRIBUTING.md "Configuration",
-- src/lexiftool/main.lua's portVersion); "Unknown" when nothing set it (a
-- bare source checkout, or a rock install -- luarocks' "builtin" build
-- type has no step to bake a real identity in).
ExifTool._VERSION = _G.LEXIFTOOL_PORT_VERSION or 'Unknown'

-- Current byte order ('II' or 'MM'), module-level state as in the Perl
-- original (set with $swapBytes/%unpackStd in the :DataAccess block below)
local currentByteOrder

-- allGroupsExifTool (used for the ExifTool-family pseudo-tags)
local allGroupsExifTool = { [0]='ExifTool', [1]='ExifTool', [2]='ExifTool' }

-- (upstream %geoInfo, shared by all the Geolocation tags below)
local geoInfoGroups = { [0]='ExifTool', [1]='ExifTool', [2]='Location' }

-- tag information for preview image -- this should be used for all
-- PreviewImage tags so they are handled properly when reading/writing
-- (upstream is the hash %Image::ExifTool::previewImageTagInfo, spread into
--  a tag entry first; conventions.md §2 turns a spread hash into a helper
--  that fills in the shared entries the tag entry does not set itself, as
--  the entry's own keys come after the spread and win)
local previewImageTagInfo = {
    Name = 'PreviewImage',
    Writable = 'undef',
    -- a value of 'none' is ok...
    -- (Writer.pl:2995 evaluates WriteCheck with ($self, $tagInfo, $val))
    WriteCheck = function(self, _tagInfo, val) if val == 'none' then return nil end return self:CheckImage(val) end,
    DataTag = 'PreviewImage',
    -- accept either scalar or scalar reference
    RawConv = function(self, val, tag)
        -- (upstream hands ValidateImage a scalar reference and returns what it
        --  gives back -- also a reference, which is what makes the value print
        --  as "(Binary data N bytes)")
        val = self:ValidateImage(type(val) == 'table' and val.value or val, tag)
        if val == nil then return nil end
        return { ref = 'SCALAR', value = val }
    end,
    -- we allow preview image to be set to '', but we don't want a zero-length value
    -- in the IFD, so set it temporarily to 'none'.  Note that the length is <= 4,
    -- so this value will fit in the IFD so the preview fixup won't be generated.
    ValueConvInv = function(_self, val) if val == '' then val = 'none' end return val end,
}
function ExifTool.previewImageTagInfo(t)
    for k, v in pairs(previewImageTagInfo) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

function ExifTool.DummyWriteProc() return 1 end

-- (upstream @availableOptions, assigned with the other package lists below)
local availableOptions

-- memory purge variables
local purgeFlag = 0
local purgeTags = {}

-- (upstream %systemTagsNotes, spread into the System tags below; its one
--  entry is the Notes text)
local systemTagsNotes = [[
        extracted only if specifically requested or the API L<SystemTags|../ExifTool.html#SystemTags> or L<RequestAll|../ExifTool.html#RequestAll>
        option is set
    ]]

-- Extra tag table (mirror of the %Image::ExifTool::Extra subset used by the
-- File/ExifTool family pseudo-tags)
ExifTool.Extra = {
    GROUPS = { [0]='File', [1]='File', [2]='Image' },
    VARS = { ID_FMT = 'none' }, -- tag ID's aren't meaningful for these tags
    WRITE_PROC = ExifTool.DummyWriteProc,
    Error = {
        Priority = 0,
        Groups = allGroupsExifTool,
        Notes = [[
            returns errors that may have occurred while reading or writing a file.  Any
            Error will prevent the file from being processed.  Minor errors may be
            downgraded to warnings with the -m or L<IgnoreMinorErrors|../ExifTool.html#IgnoreMinorErrors> option
        ]],
    },
    Warning = {
        Priority = 0,
        Groups = allGroupsExifTool,
        Notes = [[
            returns warnings that may have occurred while reading or writing a file.
            Use the -a or L<Duplicates|../ExifTool.html#Duplicates> option to see all warnings if more than one
            occurred. Minor warnings may be ignored with the -m or L<IgnoreMinorErrors|../ExifTool.html#IgnoreMinorErrors>
            option.  Minor warnings with a capital "M" in the "[Minor]" designation
            indicate that the processing is affected by ignoring the warning.  Multiple
            identical warnings are indicated by a count after the warning message, eg.
            "[x2]" if the same warning occurred twice
        ]],
    },
    Comment = {
        Notes = 'comment embedded in JPEG, GIF89a or PPM/PGM/PBM image',
        Writable = 1,
        WriteGroup = 'Comment',
        Priority = 0, -- to preserve order of JPEG COM segments
    },
    Directory = {
        Groups = { [1]='System', [2]='Other' },
        Notes = [[
            the directory of the file as specified in the call to ExifTool, or "." if no
            directory was specified.  May be written to move the file to another
            directory that will be created if doesn't already exist
        ]],
        Writable = 1,
        WritePseudo = 1,
        Priority = 2,
        DelCheck = function() return "Can't delete" end,
        Protected = 1,
        RawConv = function(self, val) return self:ConvertFileName(val) end,
        -- translate backslashes in directory names and add trailing '/'
        ValueConvInv = function(self, val)
            val = self.InverseFileName(self, val)
            if not val:match('[^/]$') then return val end
            return val .. '/'
        end,
    },
    FileName = {
        Groups = { [1]='System', [2]='Other' },
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1,
        Priority = 2,
        Notes = [[
            may be written with a full path name to set FileName and Directory in one
            operation.  This is such a powerful feature that a TestName tag is provided
            to allow dry-run tests before actually writing the file name.  See
            L<filename.html|../filename.html> for more information on writing the
            FileName, Directory and TestName tags
        ]],
        RawConv = function(self, val) return self:ConvertFileName(val) end,
        ValueConvInv = function(self, val) return self.InverseFileName(self, val) end,
    },
    BaseName = {
        Groups = { [1]='System', [2]='Other' },
        Priority = 2,
        Notes = [[
            file name without extension. Not generated unless specifically requested or
            the API L<RequestAll|../ExifTool.html#RequestAll> option is set
        ]],
    },
    FilePath = {
        Groups = { [1]='System', [2]='Other' },
        Notes = [[
            absolute path of source file. Not generated unless specifically requested or
            the API L<RequestAll|../ExifTool.html#RequestAll> option is set.  Does not support Windows Unicode file
            names
        ]],
    },
    TestName = {
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1,
        WriteOnly = 1,
        Notes = [[
            this write-only tag may be used instead of FileName for dry-run tests of the
            file renaming feature.  Writing this tag prints the old and new file names
            to the console, but does not affect the file itself
        ]],
        ValueConvInv = function(self, val) return self.InverseFileName(self, val) end,
    },
    FileSequence = {
        Groups = { [0]='ExifTool', [1]='ExifTool', [2]='Other' },
        Notes = [[
            sequence number for each source file when extracting or copying information,
            including files that fail the -if condition of the command-line application,
            beginning at 0 for the first file.  Not generated unless specifically
            requested or the API L<RequestAll|../ExifTool.html#RequestAll> option is set
        ]],
    },
    FileSize = {
        Groups = { [1]='System', [2]='Other' },
        Notes = [[
            note that the print conversion for this tag uses SI prefixes by default:  1
            kB = 1000 bytes, etc.  Set the API ByteUnit option to "Binary" to use binary
            prefixes instead:  1 KiB = 1024 bytes, etc.
        ]],
        PrintConv = function(self, val) return ExifTool.ConvertFileSize(val, self) end,
    },
    ResourceForkSize = {
        Groups = { [1]='System', [2]='Other' },
        Notes = [[
            size of the file's resource fork if it contains data.  Mac OS only.  If this
            tag is generated the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option may be used to extract
            resource-fork information as a sub-document.  When writing, the resource
            fork is preserved by default, but it may be deleted with C<-rsrc:all=> on
            the command line
        ]],
        PrintConv = function(self, val) return ExifTool.ConvertFileSize(val, self) end,
    },
    ZoneIdentifier = {
        Groups = { [1] = 'System', [2] = 'Other' },
        Notes = [[
            Windows only.  Existence indicates that the file has a Zone.Identifier
            alternate data stream, which is used by some Windows browsers to mark
            downloaded files as possibly unsafe to run.  May be deleted to remove this
            stream.  Requires Win32API::File
        ]],
        Writable = 1,
        WritePseudo = 1,
        Protected = 1,
    },
    FileType = {
        Groups = { [2]='Other' },
        Priority = 2,
        Notes = [[
            a short description of the file type.  For many file types this is the just
            the uppercase file extension
        ]],
    },
    FileTypeExtension = {
        Groups = { [2]='Other' },
        Notes = [[
            a common lowercase extension for this file type, or uppercase with the -n
            option
        ]],
        PrintConv = function(_self, val) return lc(val) end,
    },
    HardLink = {
        Writable = 1,
        DelCheck = function() return "Can't delete" end,
        WriteOnly = 1,
        WritePseudo = 1,
        Protected = 1,
        Notes = [[
            this write-only tag is used to create a hard link with the specified name to
            the source file.  If the source file is edited, copied, renamed or moved in
            the same operation as writing HardLink, then the link is made to the updated
            file.  Note that subsequent editing of either hard-linked file by exiftool
            will break the link unless the -overwrite_original_in_place option is used
        ]],
        ValueConvInv = function(_self, val) return (perl.tr(val, '\\', '/')) end,
    },
    SymLink = {
        Writable = 1,
        DelCheck = function() return "Can't delete" end,
        WriteOnly = 1,
        WritePseudo = 1,
        Protected = 1,
        Notes = [[
            this write-only tag is used to create a symbolic link with the specified
            name to the source file.  If the source file is edited, copied, renamed or
            moved in the same operation as writing SymLink, then the link is made to the
            updated file.  The link uses an absolute path unless it is created in the
            current working directory.  Valid only for file systems that support
            symbolic links.  Note that subsequent editing of the file via the symbolic
            link by exiftool will cause the link to be replaced by the edited file
            without changing the original unless the -overwrite_original_in_place option
            is used
        ]],
        ValueConvInv = function(_self, val) return (perl.tr(val, '\\', '/')) end,
    },
    MIMEType = {
        Groups = { [2]='Other' },
        Notes = 'the MIME type of the source file',
    },
    ImageWidth = { Notes = 'the width of the image in number of pixels' },
    ImageHeight = { Notes = 'the height of the image in number of pixels' },
    XResolution = { Notes = 'the horizontal pixel resolution' },
    YResolution = { Notes = 'the vertical pixel resolution' },
    MaxVal = { Notes = 'maximum pixel value in PPM or PGM image' },
    EXIF = {
        Notes = [[
            the full EXIF data block from JPEG, PNG, JP2, MIE and MIFF images. This tag
            is generated only if specifically requested
        ]],
        Groups = { [0] = 'EXIF', [1] = 'EXIF' },
        Flags = { 'Writable', 'Protected', 'Binary', 'DelGroup' },
        WriteCheck = function(_self, _tagInfo, val)
            if perl.matches(val, [[^(II\x2a\0|MM\0\x2a)]]) then return nil end
            return 'Invalid EXIF data'
        end,
    },
    IPTC = {
        Notes = [[
            the full IPTC data block.  This tag is generated only if specifically
            requested
        ]],
        Groups = { [0] = 'IPTC', [1] = 'IPTC' },
        Flags = { 'Writable', 'Protected', 'Binary', 'DelGroup' },
        Priority = 0,  -- so main IPTC (which hopefully comes first) takes priority
        WriteCheck = function(_self, _tagInfo, val)
            if perl.matches(val, [[^(\x1c|\0+$)]]) then return nil end
            return 'Invalid IPTC data'
        end,
    },
    XMP = {
        Notes = [[
            the XMP data block, but note that extended XMP in JPEG images may be split
            into multiple blocks.  This tag is generated only if specifically requested
        ]],
        Groups = { [0] = 'XMP', [1] = 'XMP' },
        Flags = { 'Writable', 'Protected', 'Binary', 'DelGroup' },
        Priority = 0,  -- so main xmp (which usually comes first) takes priority
        WriteCheck = function(self, tagInfo, val)
            -- (Lua: the error, then the possibly changed value, as a CHECK_PROC)
            return require('lexiftool.XMP').CheckXMP(self, tagInfo, val)
        end,
    },
    FileModifyDate = {
        Description = 'File Modification Date/Time',
        Notes = [[
            the filesystem modification date/time.  Note that ExifTool may not be able
            to handle filesystem dates before 1970 depending on the limitations of the
            system's standard libraries
        ]],
        Groups = { [1]='System', [2]='Time' },
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        -- all writable pseudo-tags must be protected so -tagsfromfile fails with
        -- unrecognized files unless a pseudo tag is specified explicitly
        Protected = 1,
        Shift = 'Time',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        ValueConvInv = function(_self, val) return ExifTool.GetUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val)
            return require('lexiftool.Writer').InverseDateTime(self, val)
        end,
    },
    FileAccessDate = {
        Description = 'File Access Date/Time',
        Notes = [[
            the date/time of last access of the file.  Note that this access time is
            updated whenever any software, including ExifTool, reads the file
        ]],
        Groups = { [1]='System', [2]='Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    FileCreateDate = {
        Description = 'File Creation Date/Time',
        Notes = [[
            the filesystem creation date/time.  Windows/Mac/Linux only.  In Windows, the
            file creation date/time is preserved by default when writing if
            Win32API::File and Win32::API are available.  On Mac, this tag is extracted
            only if it or the MacOS group is specifically requested or the API
            L<RequestAll|../ExifTool.html#RequestAll> option is set to 2 or higher.  On
            Linux, this tag is read-only and extracted only if the filesystem supports
            btime and "File::StatX" is available.  Requires "setfile" for writing on
            Mac, which may be installed by typing C<xcode-select --install> in the
            Terminal
        ]],
        Groups = { [1]='System', [2]='Time' },
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1, -- all writable pseudo-tags must be protected!
        Shift = 'Time',
        ValueConv = function(_self, val)
            if perl.osname() == 'darwin' then return val end
            return ExifTool.ConvertUnixTime(val, 1)
        end,
        ValueConvInv = function(_self, val)
            if perl.osname() == 'MSWin32' then return ExifTool.GetUnixTime(val, 1) end
            if perl.osname() == 'darwin' then return val end
            perl.warn("This tag is Windows/Mac only\n")
            return nil
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val)
            return require('lexiftool.Writer').InverseDateTime(self, val)
        end,
    },
    FileInodeChangeDate = {
        Description = 'File Inode Change Date/Time',
        Notes = [[
            the date/time when the file's directory information was last changed.
            Non-Windows systems only
        ]],
        Groups = { [1]='System', [2]='Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    FilePermissions = {
        Groups = { [1]='System', [2]='Other' },
        Notes = [[
            r=read, w=write and x=execute permissions for the file owner, group and
            others.  The ValueConv value is an octal number so bit test operations on
            this value should be done in octal, eg. 'oct($filePermissions#) & 0200'
        ]],
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1, -- all writable pseudo-tags must be protected!
        ValueConvInv = function(_self, val) return perl.oct(perl.str(perl.int(val) & 4095)) end, -- (07777)
        -- Raw value is the numeric st_mode; ValueConv renders it octal (which
        -- is what -n prints), PrintConv turns that into "-rw-r--r--".
        -- ExifTool.pm:1516-1535.
        ValueConv = function(_self, val)
            local n = tonumber(val)
            return n and sprintf('%.3o', n) or perl.str(val)
        end,
        PrintConv = function(_self, val) return ExifTool.FormatFilePermissions(val) end,
        PrintConvInv = function(_self, str)
            local bit, val = 8, 0
            if perl.length(str) == 10 then str = perl.substr(str, 1) end
            if perl.length(str) ~= 9 then return nil end
            while bit >= 0 do
                for _, c in ipairs({ 'r', 'w', 'x' }) do
                    if perl.substr(str, 8 - bit, 1) == c then val = val | (1 << bit) end
                    bit = bit - 1
                end
            end
            return sprintf('%.3o', val)
        end,
    },
    FileAttributes = {
        Groups = { [1]='System', [2]='Other' },
        Notes = [[
            extracted only if specifically requested or the API L<SystemTags|../ExifTool.html#SystemTags> or L<RequestAll|../ExifTool.html#RequestAll>
            option is set.  2 or 3 values: 0. File type, 1. Attribute bits, 2. Windows
            attribute bits if Win32API::File is available
        ]],
        PrintHex = 1,
        PrintConvColumns = 2,
        PrintConv = { { -- stat device types (bitmask 0xf000)
            [0x0000] = 'Unknown',
            [0x1000] = 'FIFO',
            [0x2000] = 'Character',
            [0x3000] = 'Mux Character',
            [0x4000] = 'Directory',
            [0x5000] = 'XENIX Named',
            [0x6000] = 'Block',
            [0x7000] = 'Mux Block',
            [0x8000] = 'Regular',
            [0x9000] = 'VxFS Compressed',
            [0xa000] = 'Symbolic Link',
            [0xb000] = 'Solaris Shadow Inode',
            [0xc000] = 'Socket',
            [0xd000] = 'Solaris Door',
            [0xe000] = 'BSD Whiteout',
        },{ BITMASK = { -- stat attribute bits (bitmask 0x0e00)
            [9] = 'Sticky',
            [10] = 'Set Group ID',
            [11] = 'Set User ID',
        }},{ BITMASK = { -- Windows attribute bits
            [0] = 'Read Only',
            [1] = 'Hidden',
            [2] = 'System',
            [3] = 'Volume Label',
            [4] = 'Directory',
            [5] = 'Archive',
            [6] = 'Device',
            [7] = 'Normal',
            [8] = 'Temporary',
            [9] = 'Sparse File',
            [10] = 'Reparse Point',
            [11] = 'Compressed',
            [12] = 'Offline',
            [13] = 'Not Content Indexed',
            [14] = 'Encrypted',
        }} },
    },
    FileDeviceID = {
        Groups = { [1] = 'System', [2] = 'Other' },
        Notes = systemTagsNotes,
        PrintConv = function(_self, val) -- (major.minor)
            val = perl.int(val)
            return ((val >> 24) & 0xff) .. '.' .. (val & 0xffffff)
        end,
    },
    FileDeviceNumber = { Groups = { [1] = 'System', [2] = 'Other' }, Notes = systemTagsNotes },
    FileInodeNumber  = { Groups = { [1] = 'System', [2] = 'Other' }, Notes = systemTagsNotes },
    FileHardLinks    = { Groups = { [1] = 'System', [2] = 'Other' }, Notes = systemTagsNotes },
    FileUserID = {
        Groups = { [1] = 'System', [2] = 'Other' },
        Notes = [[
            extracted only if specifically requested or the API L<SystemTags|../ExifTool.html#SystemTags> or L<RequestAll|../ExifTool.html#RequestAll>
            option is set.  Returns user ID number with the -n option, or name
            otherwise.  May be written with either user name or number
        ]],
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1, -- all writable pseudo-tags must be protected!
        PrintConv = function(_self, val) return perl.getpwuid(val) or val end,
        PrintConvInv = function(_self, val)
            local uid = perl.getpwnam(val)
            if perlTruthy(uid) then return uid end
            if perl.isMatch(val, '[^0-9]') then return nil end
            return val
        end,
    },
    FileGroupID = {
        Groups = { [1] = 'System', [2] = 'Other' },
        Notes = [[
            extracted only if specifically requested or the API L<SystemTags|../ExifTool.html#SystemTags> or L<RequestAll|../ExifTool.html#RequestAll>
            option is set.  Returns group ID number with the -n option, or name
            otherwise.  May be written with either group name or number
        ]],
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1, -- all writable pseudo-tags must be protected!
        PrintConv = function(_self, val) return perl.getgrgid(val) or val end,
        PrintConvInv = function(_self, val)
            local gid = perl.getgrnam(val)
            if perlTruthy(gid) then return gid end
            if perl.isMatch(val, '[^0-9]') then return nil end
            return val
        end,
    },
    FileBlockSize    = { Groups = { [1] = 'System', [2] = 'Other' }, Notes = systemTagsNotes },
    FileBlockCount   = { Groups = { [1] = 'System', [2] = 'Other' }, Notes = systemTagsNotes },
    ExifByteOrder = {
        Writable = 1,
        DelCheck = function() return "Can't delete" end,
        Notes = [[
            represents the byte order of EXIF information.  May be written to set the
            byte order only for newly created EXIF segments
        ]],
        PrintConv = {
            II = 'Little-endian (Intel, II)',
            MM = 'Big-endian (Motorola, MM)',
        },
    },
    MakerNoteByteOrder = {
        Notes = 'byte order of maker notes.  Generated only if different from ExifByteOrder',
        PrintConv = {
            II = 'Little-endian (Intel, II)',
            MM = 'Big-endian (Motorola, MM)',
        },
    },
    ExifUnicodeByteOrder = {
        Writable = 1,
        WriteOnly = 1,
        DelCheck = function() return "Can't delete" end,
        Notes = [[
            specifies the byte order to use when writing EXIF Unicode text.  The EXIF
            specification is particularly vague about this byte ordering, and different
            applications use different conventions.  By default ExifTool writes Unicode
            text in EXIF byte order, but this write-only tag may be used to force a
            specific order.  Applies to the EXIF UserComment tag when writing special
            characters
        ]],
        PrintConv = {
            II = 'Little-endian (Intel, II)',
            MM = 'Big-endian (Motorola, MM)',
        },
    },
    Adobe = {
        Notes = [[
            the JPEG APP14 Adobe segment.  Extracted only if specified. See the
            L<JPEG Adobe Tags|JPEG.html#Adobe> for more information
        ]],
        Groups = { [0] = 'APP14', [1] = 'Adobe' },
        WriteGroup = 'Adobe',
        Flags = { 'Writable', 'Protected', 'Binary' },
    },
    CurrentIPTCDigest = {
        Notes = [[
            MD5 digest of existing IPTC data.  All zeros if IPTC exists but Digest::MD5
            is not installed.  Only calculated for IPTC in the standard location as
            specified by the L<MWG|http://www.metadataworkinggroup.org/>.  ExifTool
            automates the handling of this tag in the MWG module -- see the
            L<MWG Composite Tags|MWG.html> for details
        ]],
        ValueConv = function(_self, val) return (perl.unpack('H*', val)) end,
    },
    ExifToolVersion = {
        Description = 'ExifTool Version Number',
        Groups = allGroupsExifTool,
        Notes = 'the version of ExifTool currently running',
    },
    ICC_Profile = {
        Notes = [[
            the full ICC_Profile data block.  This tag is generated only if specifically
            requested
        ]],
        Groups = { [0] = 'ICC_Profile', [1] = 'ICC_Profile' },
        Flags = { 'Writable', 'Protected', 'Binary', 'DelGroup' },
        WriteCheck = function(_self, _tagInfo, val)
            return require('lexiftool.ICC_Profile').ValidateICC(val)
        end,
    },
    CanonVRD = {
        Notes = [[
            the full Canon DPP VRD trailer block.  This tag is generated only if
            specifically requested
        ]],
        Groups = { [0] = 'CanonVRD', [1] = 'CanonVRD' },
        Flags = { 'Writable', 'Protected', 'Binary', 'DelGroup' },
        Permanent = 0, -- (this is 1 by default for MakerNotes tags)
        WriteCheck = function(_self, _tagInfo, val)
            if perl.isMatch(val, [[^CANON OPTIONAL DATA\0]]) then return nil end
            return 'Invalid CanonVRD data'
        end,
    },
    CanonDR4 = {
        Notes = [[
            the full Canon DPP version 4 DR4 block.  This tag is generated only if
            specifically requested
        ]],
        Groups = { [0] = 'CanonVRD', [1] = 'CanonVRD' },
        Flags = { 'Writable', 'Protected', 'Binary' },
        Permanent = 0, -- (this is 1 by default for MakerNotes tags)
        WriteCheck = function(_self, _tagInfo, val)
            if perl.isMatch(val, [[^IIII[\x04|\x05]\0\x04\0]]) then return nil end
            return 'Invalid CanonDR4 data'
        end,
    },
    ProcessingTime = {
        Groups = { [0]='ExifTool', [1]='ExifTool', [2]='Other' },
        Notes = [[
            the clock time in seconds taken by ExifTool to extract information from this
            file.  Not generated unless specifically requested or the API L<RequestAll|../ExifTool.html#RequestAll>
            option is set.  Requires Time::HiRes
        ]],
        PrintConv = function(_self, val) return sprintf('%.3g s', val) end,
    },
    JPEGDigest = {
        Notes = [[
            an MD5 digest of the JPEG quantization tables is combined with the component
            sub-sampling values to generate the value of this tag.  The result is
            compared to known values in an attempt to deduce the originating software
            based only on the JPEG image data.  For performance reasons, this tag is
            generated only if specifically requested or the API L<RequestAll|../ExifTool.html#RequestAll> option is set
            to 3 or higher
        ]],
    },
    JPEGQualityEstimate = {
        Notes = [[
            an estimate of the IJG JPEG quality setting for the image, calculated from
            the quantization tables.  For performance reasons, this tag is generated
            only if specifically requested or the API L<RequestAll|../ExifTool.html#RequestAll> option is set to 3 or
            higher
        ]],
    },
    JPEGImageLength = {
        Notes = [[
            byte length of JPEG image without metadata.  For performance reasons, this
            tag is generated only if specifically requested or the API L<RequestAll|../ExifTool.html#RequestAll> option
            is set to 3 or higher
        ]],
    },
    Now = {
        Groups = { [0]='ExifTool', [1]='ExifTool', [2]='Time' },
        Notes = [[
            the current date/time.  Useful when setting the tag values, eg.
            C<"-modifydate<now">.  Not generated unless specifically requested or the
            API L<RequestAll|../ExifTool.html#RequestAll> option is set
        ]],
    },
    NewGUID = {
        Groups = { [0] = 'ExifTool', [1] = 'ExifTool', [2] = 'Other' },
        Notes = [[
            generates a new, random GUID with format
            YYYYmmdd-HHMM-SSNN-PPPP-RRRRRRRRRRRR, where Y=year, m=month, d=day, H=hour,
            M=minute, S=second, N=file sequence number in hex, P=process ID in hex, and
            R=random hex number; without dashes with the -n option.  Not generated
            unless specifically requested or the API L<RequestAll|../ExifTool.html#RequestAll> option is set
        ]],
        PrintConv = function(_self, val) return (perl.subst(val, [[(.{8})(.{4})(.{4})(.{4})]], '$1-$2-$3-$4-')) end,
    },
    NewUUID = {
        Groups = { [0] = 'ExifTool', [1] = 'ExifTool', [2] = 'Other' },
        Notes = [[
            generates a version 4 ("random"), variant 1 UUID as per RFC 9562, Section
            5.4.  Not generated unless specifically requested or the API L<RequestAll|../ExifTool.html#RequestAll>
            option is set
        ]],
        PrintConv = function(_self, val) return (perl.subst(val, [[(.{8})(.{4})(.{4})(.{4})]], '$1-$2-$3-$4-')) end,
    },
    PreviewImage = {
        Notes = 'JPEG-format embedded preview image',
        Groups = { [2] = 'Preview' },
        Writable = 1,
        WriteCheck = function(self, _tagInfo, val) return self:CheckImage(val) end,
        WriteGroup = 'All',
        -- can't delete, so set to empty string and return no error
        DelCheck = function(_self) return nil, '' end,
        -- accept either scalar or scalar reference
        RawConv = function(self, val, tag)
            val = self:ValidateImage(type(val) == 'table' and val.value or val, tag)
            if val == nil then return nil end
            return { ref = 'SCALAR', value = val }
        end,
    },
    ThumbnailImage = {
        Groups = { [2] = 'Preview' },
        Notes = 'JPEG-format embedded thumbnail image',
        RawConv = function(self, val, tag) return self:ValidateImage(val, tag) end,
    },
    OtherImage = {
        Groups = { [2] = 'Preview' },
        Notes = 'other JPEG-format embedded image',
        RawConv = function(self, val, tag) return self:ValidateImage(val, tag) end,
    },
    PreviewPNG = {
        Groups = { [2] = 'Preview' },
        Notes = 'PNG-format embedded preview image',
        Binary = 1,
    },
    PreviewWMF = {
        Groups = { [2] = 'Preview' },
        Notes = 'WMF-format embedded preview image',
        Binary = 1,
    },
    PreviewTIFF = {
        Groups = { [2] = 'Preview' },
        Notes = 'TIFF-format embedded preview image',
        Binary = 1,
    },
    PreviewPDF = {
        Groups = { [2] = 'Preview' },
        Notes = 'PDF-format embedded preview image',
        Binary = 1,
    },
    PreviewJXL = {
        Groups = { [2] = 'Preview' },
        Notes = 'JXL-format embedded preview image',
        Binary = 1,
    },
    ID3Size = { Notes = 'size of the ID3 data block' },
    Geotag = {
        Writable = 1,
        WriteOnly = 1,
        WriteNothing = 1,
        AllowGroup = '(exif|gps|xmp|xmp-exif)',
        Notes = [[
            this write-only tag is used to define the GPS track log data or track log
            file name.  Currently supported track log formats are GPX, NMEA RMC/GGA/GLL,
            KML, IGC, Garmin XML and TCX, Magellan PMGNTRK, Honeywell PTNTHPR, Winplus
            Beacon text, Bramor gEO, Google Takeout JSON, and CSV log files.  May be set
            to the special value of "DATETIMEONLY" (all caps) to set GPS date/time tags
            if no input track points are available.  See L<geotag.html|../geotag.html>
            for details
        ]],
        DelCheck = function(self, _tagInfo, wantGroup)
            local Geotag = require('lexiftool.Geotag')
            -- delete associated tags
            return Geotag.SetGeoValues(self, nil, wantGroup)
        end,
        ValueConvInv = function(self, val)
            local Geotag = require('lexiftool.Geotag')
            -- always warn because this tag is never set (warning is "\n" on success)
            local result = Geotag.LoadTrackLog(self, val)
            if result == nil then return '' end      -- deleting geo tags
            if type(result) == 'table' then return result end -- geotag data hash reference
            error(result .. '\n', 0)                 -- error string
        end,
    },
    Geotime = {
        Writable = 1,
        WriteOnly = 1,
        AllowGroup = '(exif|gps|xmp|xmp-exif|quicktime|keys|itemlist|userdata)',
        Notes = [[
            this write-only tag is used to define a date/time for interpolating a
            position in the GPS track specified by the Geotag tag.  Writing this tag
            causes GPS information to be written into the EXIF or XMP of the target
            files.  The local system timezone is assumed if the date/time value does not
            contain a timezone.  May be deleted to delete associated GPS tags.  A group
            name of "EXIF" or "XMP" may be specified to write or delete only EXIF or XMP
            GPS tags
        ]],
        DelCheck = function(self, _tagInfo, wantGroup)
            local Geotag = require('lexiftool.Geotag')
            -- delete associated tags
            return Geotag.SetGeoValues(self, nil, wantGroup)
        end,
        ValueConvInv = function(self, val, wantGroup)
            local Geotag = require('lexiftool.Geotag')
            error(Geotag.SetGeoValues(self, val, wantGroup) .. '\n', 0)
        end,
    },
    Geosync = {
        Writable = 1,
        WriteOnly = 1,
        WriteNothing = 1,
        AllowGroup = '(exif|gps|xmp|xmp-exif)',
        Shift = 'Time', -- enables "+=" syntax as well as "=+"
        Notes = [[
            this write-only tag specifies a time difference to add to Geotime for
            synchronization with the GPS clock.  For example, set this to "-12" if the
            camera clock is 12 seconds faster than GPS time.  Input format is
            "[+-][[[DD ]HH:]MM:]SS[.ss]".  Additional features allow calculation of time
            differences and time drifts, and extraction of synchronization times from
            image files.  See the L<geotagging documentation|../geotag.html> for details
        ]],
        ValueConvInv = function(self, val)
            local Geotag = require('lexiftool.Geotag')
            return Geotag.ConvertGeosync(self, val)
        end,
    },
    ForceWrite = {
        Groups = { [0] = '*', [1] = '*', [2] = '*' },
        Writable = 1,
        WriteOnly = 1,
        Notes = [[
            write-only tag used to force metadata in a file to be rewritten even if no
            tag values are changed.  May be set to "EXIF", "IPTC", "XMP" or "PNG" to
            force the corresponding metadata type to be rewritten, "FixBase" to cause
            EXIF to be rewritten only if the MakerNotes offset base was fixed, or "All"
            to rewrite all of these metadata types.  Values are case insensitive, and
            multiple values may be separated with commas, eg. C<-ForceWrite=exif,xmp>
        ]],
    },
    EmbeddedVideo = { Groups = { [0] = 'Trailer', [2] = 'Video' } },
    Trailer = {
        Groups = { [0] = 'Trailer' },
        Notes = [[
            the full JPEG trailer data block.  Extracted only if specifically requested
            or the API L<RequestAll|../ExifTool.html#RequestAll> option is set to 3 or higher
        ]],
        Writable = 1,
        Protected = 1,
    },
    PageCount = { Notes = 'the number of pages in a multi-page TIFF document' },
    SphericalVideoXML = {
        Groups = { [0] = 'QuickTime', [1] = 'GSpherical', [2] = 'Video' },
        -- (group 1 is 'GSpherical' to trigger creation of this tag when writing,
        -- but when reading the family 1 group is the track number)
        Flags = { 'Writable', 'Binary', 'Protected' },
        Notes = [[
            the SphericalVideoXML block from MP4/MOV videos.  This tag is generated only
            if specifically requested
        ]],
    },
    ImageDataHash = {
        Notes = [[
            Hash of image data. Generated only if specifically requested for JPEG, TIFF,
            PNG, CRW, CR3, MRW, RAF, X3F, IIQ, JP2, JXL, HEIC and AVIF images, MOV/MP4
            videos, and some RIFF-based files such as AVI, WAV and WEBP.  The hash
            algorithm is set by the API L<ImageHashType|../ExifTool.html#ImageHashType> option, and is 'MD5' by default.
            The hash includes the main image data, plus JpgFromRaw/OtherImage for some
            formats, but does not include ThumbnailImage or PreviewImage.  Includes
            video and audio data for MOV/MP4.  The L<XMP-et:OriginalImageHash and
            XMP-et:OriginalImageHashType tags|XMP.html#ExifTool> provide a way to store
            the this hash value and the hash type in the file.
        ]],
    },
    Geolocate = {
        Writable = 1,
        WriteOnly = 1,
        WriteNothing = 1,
        AllowGroup = '(exif|gps|xmp|xmp-exif|xmp-iptcext|xmp-iptccore|xmp-photoshop|iptc|quicktime|itemlist|keys|userdata)',
        Notes = [[
            this write-only tag may be used to write geolocation city, region, country
            code and country based in input GPS coordinates, or to write GPS
            coordinates based on geolocation name.  See the
            L<Writing section of the Geolocation page|../geolocation.html#Write> for
            details.  This tag is writable regardless of the API L<Geolocation|../ExifTool.html#Geolocation>
            option setting
        ]],
        DelCheck = function(self, _tagInfo, wantGroup)
            local tags = require('lexiftool.Writer').GetGeolocateTags(self, wantGroup)
            for _, tag in ipairs(tags) do self:SetNewValue(tag) end
            return ''
        end,
        ValueConvInv = function(self, val, wantGroup)
            local Geolocation = require('lexiftool.Geolocation')
            -- write this tag later if geotagging
            if perl.isMatch(val, [[(?i)\bgeotag\b]]) then return val end
            val = val .. ',both'
            local opts = self.OPTIONS
            local cities, dist = Geolocation.Geolocate(self:Encode(val, 'UTF8'), opts)
            if not cities then return '' end
            if #cities > 1 and perlTruthy(self:Warn('Multiple matching cities found', 2)) then
                perl.warn(self.VALUE.Warning .. "\n")
                return ''
            end
            local geo = table.pack(Geolocation.GetEntry(cities[1], opts.Lang))
            local tags = require('lexiftool.Writer').GetGeolocateTags(self, wantGroup, dist and 0 or 1)
            local geoNum = { City = 0, Province = 1, State = 1, Code = 3, Country = 4,
                             Coordinates = 89, Latitude = 8, Longitude = 9 }
            local value
            for _, tag in ipairs(tags) do
                local isGPS, g1 = perl.isMatch(tag, [[GPS(Coordinates|Latitude|Longitude)?]])
                local okCode, c1 = perl.isMatch(tag, [[(Code)]])
                local okName, n1 = perl.isMatch(tag, [[(City|Province|State|Country)]])
                if isGPS then
                    -- (geo[] is 1-based: upstream's $geo[N] is geo[N + 1])
                    if geoNum[g1] == 89 then
                        value = ExifTool.NumStr(geo[9]) .. ',' .. ExifTool.NumStr(geo[10])
                    else
                        value = geo[(geoNum[g1] or 0) + 1]
                    end
                elseif okCode or okName then
                    value = geo[geoNum[okCode and c1 or n1] + 1]
                    if value == nil then goto nextTag end
                    value = self:Decode(value, 'UTF8')
                    if tag == 'iptc:Country-PrimaryLocationCode' then value = value .. ' ' end -- (IPTC requires 3-char code)
                elseif perl.isMatch(tag, [[LocationName]]) then
                    value = geo[1]
                    if not perlTruthy(value) then goto nextTag end
                    if perlTruthy(geo[2]) then value = value .. ', ' .. geo[2] end
                    if perlTruthy(geo[5]) then value = value .. ', ' .. geo[5] end
                    value = self:Decode(value, 'UTF8')
                else
                    goto nextTag -- (shouldn't happen)
                end
                self:SetNewValue(tag, value, { Type = 'PrintConv' })
                ::nextTag::
            end
            return ''
        end,
        PrintConvInv = function(_self, val)
            local args = perl.split([[\s*,\s*]], val)
            local lat = 1
            for i, a in ipairs(args) do
                if perl.isMatch(a, [[^[-+]?\d]]) then
                    local reals = perl.findAll(a, [[\.\d+]])
                    if #reals <= 1 then -- (allow floating "lat lon" format)
                        args[i] = require('lexiftool.GPS').ToDegrees(a, 1, lat == 1 and 'lat' or 'lon')
                        lat = lat ~ 1
                    end
                end
            end
            return perl.join(',', args)
        end,
    },
    XML = {
        Notes = 'the XML data block, extracted for some file types',
        Groups = { [0]='XML', [1]='XML' },
        Binary = 1,
    },
    JUMBF = {
        Notes = 'the C2PA JUMBF data block, extracted only if specifically requested',
        Groups = { [0] = 'JUMBF', [1] = 'JUMBF' },
        Binary = 1,
    },
    NumPlanes   = { Notes = 'number of color planes' },
    GeolocationBearing  = { Groups = geoInfoGroups,
        Notes = [[
            compass bearing to GeolocationCity center. Geolocation tags are
            generated only if API L<Geolocation|../ExifTool.html#Geolocation> option is set
        ]],
    },
    -- (upstream keeps each of these on one line; the four with a ValueConv
    --  are wrapped here to stay inside this port's line-length limit)
    GeolocationCity     = { Groups = geoInfoGroups, Notes = 'name of city nearest to the current GPS coordinates',
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end },
    GeolocationRegion   = { Groups = geoInfoGroups, Notes = 'geolocation state, province or region',
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end },
    GeolocationSubregion= { Groups = geoInfoGroups, Notes = 'geolocation county or subregion',
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end },
    GeolocationCountry  = { Groups = geoInfoGroups, Notes = 'geolocation country name',
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end },
    GeolocationCountryCode={Groups = geoInfoGroups, Notes = 'geolocation country code' },
    GeolocationTimeZone = { Groups = geoInfoGroups, Notes = 'geolocation time zone ID' },
    GeolocationFeatureCode={Groups = geoInfoGroups, Notes = 'geolocation feature code, see L<http://www.geonames.org/export/codes.html#P>' },
    GeolocationFeatureType={Groups = geoInfoGroups, Notes = 'geolocation feature type' },
    GeolocationPopulation={ Groups = geoInfoGroups, Notes = 'city population rounded to 2 significant digits' },
    GeolocationDistance = { Groups = geoInfoGroups, Notes = 'distance in km from current GPS to city',
        PrintConv = function(_self, val) return val .. ' km' end },
    GeolocationPosition = { Groups = geoInfoGroups, Notes = 'approximate GPS coordinates of city',
        PrintConv = function(_self, val) return (perl.str(val):gsub(' ', ', ', 1)) end,
    },
    GeolocationWarning  = { Groups = geoInfoGroups },
}

-- Composite tags (accumulation of all Composite tag tables)
ExifTool.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite' },
    VARS = { ID_FMT = 'none' }, -- want empty tagID's for Composite tags
    WRITE_PROC = ExifTool.DummyWriteProc,
}

-- tags defined by UserParam option (added at runtime)
ExifTool.UserParam = {
    GROUPS = { [0] = 'UserParam', [1] = 'UserParam', [2] = 'Other' },
    PRIORITY = 0,
}

local compositeID = { }    -- lookup for new ID's of Composite tags based on original ID

-- User-defined tag tables: upstream's package Image::ExifTool::UserDefined
-- (e.g. `%Image::ExifTool::UserDefined::myXMPns` in XMP.t), which a config
-- file or the calling script fills.  Perl keeps these in the package's own
-- symbol table, apart from the `%Image::ExifTool::UserDefined` hash of tags to
-- add to existing tables (ExifTool.UserDefined, see TagLookup.lua); Lua has
-- one namespace, so they live here, and GetTagTable resolves the table name
-- 'lexiftool.UserDefined.<name>' to them.
ExifTool.UserDefinedTables = { }
-- (upstream %Image::ExifTool::UserDefined::Options, the default options a
--  config file sets; nil until something defines them)
ExifTool.UserDefinedOptions = nil
-- (port artifact: upstream's spelling of each table name a config file
--  named, keyed by the port's, for GetTagTable's "Can't find table")
local configTableNames = { }

-- JPEG APP1 EXIF header (upstream $exifAPP1hdr)
local exifAPP1hdr = 'Exif\0\0'
-- JPEG APP1 XMP header (upstream $xmpAPP1hdr)
local xmpAPP1hdr = 'http://ns.adobe.com/xap/1.0/\0'
-- (published as upstream's package variables $Image::ExifTool::exifAPP1hdr
--  and $Image::ExifTool::xmpAPP1hdr, which other modules read)
ExifTool.exifAPP1hdr = exifAPP1hdr
ExifTool.xmpAPP1hdr = xmpAPP1hdr
-- JPEG APP1 Extended-XMP header (upstream $xmpExtAPP1hdr)
local xmpExtAPP1hdr = 'http://ns.adobe.com/xmp/extension/\0'
-- JPEG APP13 Photoshop headers (upstream $psAPP13hdr, $psAPP13old)
local psAPP13hdr = 'Photoshop 3.0\0'
local psAPP13old = 'Adobe_Photoshop2.5:'
-- (published like the two above: Writer.pl's WriteJPEG reads them)
ExifTool.xmpExtAPP1hdr = xmpExtAPP1hdr
ExifTool.psAPP13hdr = psAPP13hdr

-- JPEG JFIF APP0 definitions (%Image::ExifTool::JFIF::Main)
ExifTool.JFIF = {
    Main = {
        PROCESS_PROC = false, -- predeclaration, see below for implementation
        WRITE_PROC = false,   -- predeclaration, see below for implementation
        CHECK_PROC = false,   -- predeclaration (Writer.CheckBinaryData, set in Writer.lua)
        GROUPS = { [0] = 'JFIF', [1] = 'JFIF', [2] = 'Image' },
        DATAMEMBER = { 2, 3, 5 },
        [0] = {
            Name = 'JFIFVersion',
            Format = 'int8u[2]',
            PrintConv = function(_self, val)
                local v1, v2 = val:match('(%d+) (%d+)')
                return sprintf('%d.%.2d', tonumber(v1), tonumber(v2))
            end,
            Mandatory = 1,
        },
        [2] = {
            Name = 'ResolutionUnit',
            Writable = 1,
            -- stash the raw unit so WriteExif can seed a new IFD0's
            -- ResolutionUnit from the JFIF density (upstream
            -- `$$self{JFIFResolutionUnit} = $val`)
            RawConv = function(self, val) self.JFIFResolutionUnit = val return val end,
            PrintConv = {
                [0] = 'None',
                [1] = 'inches',
                [2] = 'cm',
            },
            -- upstream: `Priority => -1` -- loses to any other same-named
            -- tag (e.g. IFD0's real ResolutionUnit, Priority 0) so a bogus
            -- JFIF density doesn't win over the EXIF value
            Priority = -1,
            Mandatory = 1,
        },
        [3] = {
            Name = 'XResolution',
            Format = 'int16u',
            Writable = 1,
            Priority = -1,
            -- stash the raw density so WriteExif can seed a new IFD0's
            -- XResolution from the JFIF density (upstream
            -- `$$self{JFIFXResolution} = $val`)
            RawConv = function(self, val) self.JFIFXResolution = val return val end,
            Mandatory = 1,
        },
        [5] = {
            Name = 'YResolution',
            Format = 'int16u',
            Writable = 1,
            Priority = -1,
            -- stash the raw density so WriteExif can seed a new IFD0's
            -- YResolution from the JFIF density (upstream
            -- `$$self{JFIFYResolution} = $val`)
            RawConv = function(self, val) self.JFIFYResolution = val return val end,
            Mandatory = 1,
        },
        [7] = {
            Name = 'ThumbnailWidth',
            RawConv = function(self, val)
                if perlTruthy(val) then self.JFIFThumbnailWidth = val return val end
                return nil
            end,
        },
        [8] = {
            Name = 'ThumbnailHeight',
            RawConv = function(self, val)
                if perlTruthy(val) then self.JFIFThumbnailHeight = val return val end
                return nil
            end,
        },
        [9] = {
            Name = 'ThumbnailTIFF',
            Groups = { [2] = 'Preview' },
            Format = 'undef[3*($val{7}||0)*($val{8}||0)]',
            Notes = 'raw RGB thumbnail data, extracted as a TIFF image',
            RawConv = function(_self, val) if perl.length(val) > 0 then return val end return nil end,
            ValueConv = function(self, val)
                local len = perl.length(val)
                if not perlTruthy(self:Options('Binary')) then
                    return { ref = 'SCALAR', value = 'Binary data ' .. len .. ' bytes' }
                end
                local img = ExifTool.MakeTiffHeader(self.JFIFThumbnailWidth, self.JFIFThumbnailHeight, 3, 8) .. val
                return { ref = 'SCALAR', value = img }
            end,
        },
    },
    Extension = {
        GROUPS = { [0] = 'JFIF', [1] = 'JFXX', [2] = 'Image' },
        NOTES = 'Thumbnail images extracted from the JFXX segment.',
        [0x10] = {
            Name = 'ThumbnailImage',
            Groups = { [2] = 'Preview' },
            Notes = 'JPEG-format thumbnail image',
            -- (ValidateImage takes and returns the image itself; the
            --  reference upstream's `\$val` makes is built here)
            RawConv = function(self, val, tag)
                local img = self:ValidateImage(val, tag)
                if img == nil then return nil end
                return { ref = 'SCALAR', value = img }
            end,
        },
        [0x11] = { -- (untested)
            Name = 'ThumbnailTIFF',
            Groups = { [2] = 'Preview' },
            Notes = 'raw palette-color thumbnail data, extracted as a TIFF image',
            RawConv = function(_self, val)
                if perl.length(val) > 770 and not perl.isMatch(val, [[^\0\0]]) then return val end
                return nil
            end,
            ValueConv = function(et, val)
                local len = perl.length(val)
                if not perlTruthy(et:Options('Binary')) then
                    return { ref = 'SCALAR', value = 'Binary data ' .. len .. ' bytes' }
                end
                local w, h = perl.unpack('CC', val)
                local img = ExifTool.MakeTiffHeader(w, h, 1, 8, nil, substr(val, 2, 768)) .. substr(val, 770)
                return { ref = 'SCALAR', value = img }
            end,
        },
        [0x13] = {
            Name = 'ThumbnailTIFF',
            Groups = { [2] = 'Preview' },
            Notes = 'raw RGB thumbnail data, extracted as a TIFF image',
            RawConv = function(_self, val)
                if perl.length(val) > 2 and not perl.isMatch(val, [[^\0\0]]) then return val end
                return nil
            end,
            ValueConv = function(et, val)
                local len = perl.length(val)
                if not perlTruthy(et:Options('Binary')) then
                    return { ref = 'SCALAR', value = 'Binary data ' .. len .. ' bytes' }
                end
                local w, h = perl.unpack('CC', val)
                local img = ExifTool.MakeTiffHeader(w, h, 3, 8) .. substr(val, 2)
                return { ref = 'SCALAR', value = img }
            end,
        },
    },
}

--------------------------------------------------------------------------------
-- Module statics: byte order + binary readers (Perl :DataAccess subset).
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Return true if this is a RAW image file type
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.IsRawType(self)
    return ExifTool.DoAutoLoad('Image::ExifTool::IsRawType', self)
end

--------------------------------------------------------------------------------
-- Make TIFF header for raw data
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.MakeTiffHeader(w, h, cols, bits, res, cmap)
    return ExifTool.DoAutoLoad('Image::ExifTool::MakeTiffHeader', w, h, cols, bits, res, cmap)
end

--------------------------------------------------------------------------------
-- Inverse date/time conversion (for writing date/time tags)
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.InverseDateTime(self, val, tzFlag, dateOnly)
    return ExifTool.DoAutoLoad('Image::ExifTool::InverseDateTime', self, val, tzFlag, dateOnly)
end

--------------------------------------------------------------------------------
-- Return current time in EXIF format
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.TimeNow(self, tzFlag)
    return ExifTool.DoAutoLoad('Image::ExifTool::TimeNow', self, tzFlag)
end

--------------------------------------------------------------------------------
-- Generate a new, random GUID
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.NewGUID()
    return ExifTool.DoAutoLoad('Image::ExifTool::NewGUID')
end

--------------------------------------------------------------------------------
-- Generate a version 4 ("random"), variant 1 UUID
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.NewUUID()
    return ExifTool.DoAutoLoad('Image::ExifTool::NewUUID')
end

--------------------------------------------------------------------------------
-- Add data to hash checksum
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.ImageDataHash(self, raf, size, type_, noMsg)
    return ExifTool.DoAutoLoad('Image::ExifTool::ImageDataHash', self, raf, size, type_, noMsg)
end

-- Perl-style integer truncation (int() truncates toward zero, unlike
-- math.floor which rounds down for negatives).
local function truncTowardZero(v)
    if v >= 0 then return math.floor(v) end
    return math.ceil(v)
end

-- Perl SV-style number stringification: integers print without a decimal
-- point, floats with Perl's %.15g, Inf/NaN as 'Inf'/'-Inf'/'NaN' -- the
-- facade's perl.str (a non-number is passed through tostring() as before).
function ExifTool.NumStr(v)
    if type(v) ~= 'number' then return perl.str(v) end
    return perl.str(v)
end

--------------------------------------------------------------------------------
-- Utilities to check for numerical types
-- Inputs: 0) value;  Returns: true if value is a numerical type
-- Notes: May change commas to decimals in floats for use in other locales
-- (port: Lua cannot change the caller's argument, so the comma form is only
--  accepted, not translated)
local function isFloatStr(s)
    if s == '' then return false end
    local sign, int, frac, exp = s:match('^([+-]?)(%d*)[%.]?(%d*)([Ee]?[+-]?%d*)$')
    if not sign then return false end
    if exp ~= '' and not exp:match('^[Ee][+-]?%d+$') then return false end
    return (int .. frac):find('%d') ~= nil
end

function ExifTool.IsFloat(val)
    local s = perl.str(val)
    if isFloatStr(s) then return true end
    return isFloatStr(s:gsub(',', '.'))
end

function ExifTool.IsInt(val)
    return perl.str(val):match('^[+-]?%d+$') ~= nil
end

function ExifTool.IsHex(val)
    local s = perl.str(val):gsub('^0x', '')
    return #s >= 1 and #s <= 8 and s:match('^[0-9a-fA-F]+$') ~= nil
end

function ExifTool.IsRational(val)
    return perl.str(val):match('^[-+]?%d+/%d+$') ~= nil
end

-- round floating point value to specified number of significant digits
-- Inputs: 0) value, 1) number of sig digits;  Returns: rounded number
function ExifTool.RoundFloat(val, sig)
    return sprintf('%.' .. perl.str(sig) .. 'g', val)
end

-- Convert strings to floating point numbers (or undef)
-- Inputs: 0-N) list of strings (may be undef)
-- Returns: last value converted
-- (port: one value in, the converted value out -- Lua cannot change the
--  caller's arguments the way upstream's `foreach (@_)` does)
function ExifTool.ToFloat(v)
    if v == nil then return nil end
    -- upstream matches the regex against the value and returns `$1 + 0` --
    -- i.e. it goes through Perl's own stringification even for a value that
    -- is already a number, and so loses everything past the 15th significant
    -- digit. That rounding is observable: Canon.jpg's FocalLength35efl is
    -- FocalLength times the *stringified* ScaleFactor35efl, not times its
    -- full double (visible in `-n` output).
    if type(v) == 'number' then v = ExifTool.NumStr(v) end
    -- upstream: /((?:[+-]?)(?=\d|\.\d)\d*(?:\.\d*)?(?:[Ee](?:[+-]?\d+))?)/
    -- (a leading optional sign then digits, with the lookahead ensuring at
    -- least one digit -- e.g. "8.6 mm" -> "8.6", "3.5e2" -> 350)
    local n = perl.str(v):match('^[ \t\n\r\f\v]*([+-]?%d+%.?%d*[eE][+-]?%d+)')
        or perl.str(v):match('^[ \t\n\r\f\v]*([+-]?%d+%.?%d*)')
        or perl.str(v):match('^[ \t\n\r\f\v]*([+-]?%.%d+)')
    if not n then return nil end
    local num = tonumber(n)
    if num == nil then return nil end
    -- Perl `$1 + 0` turns "0.0" into 0 (integer); match that for whole floats
    if num % 1 == 0 and math.abs(num) < 1e15 then num = math.floor(num) end
    return num
end

--------------------------------------------------------------------------------
-- Utility routines to for reading binary data values from file

local unpackMotorola = { S = 'n', L = 'N', C = 'C', c = 'c' }
local unpackIntel    = { S = 'v', L = 'V', C = 'C', c = 'c' }
local unpackRev = { N = 'V', V = 'N', C = 'C', n = 'v', v = 'n', c = 'c' }

-- the following 4 variables are defined in 'use vars' instead of using 'my'
-- because mod_perl 5.6.1 apparently has a problem with setting file-scope 'my'
-- variables from within subroutines (ref communication with Pavel Merdin):
-- $swapBytes - set if EXIF header is not native byte ordering
-- $swapWords - swap 32-bit words in doubles (ARM quirk)
local swapBytes, swapWords
currentByteOrder = 'MM' -- current byte ordering ('II' or 'MM')
local unpackStd = unpackMotorola

-- Swap bytes in data if necessary
-- Inputs: 0) data, 1) number of bytes
-- Returns: swapped data
function ExifTool.SwapBytes(val, bytes)
    if not swapBytes then return val end
    local newVal = ''
    -- (`$newVal .= substr($val, $bytes, 1) while $bytes--`)
    while bytes > 0 do bytes = bytes - 1 newVal = newVal .. substr(val, bytes, 1) end
    return newVal
end
-- Swap words.  Inputs: 8 bytes of data, Returns: swapped data
function ExifTool.SwapWords(val)
    if not (swapWords and perl.length(val) == 8) then return val end
    return substr(val,4,4) .. substr(val,0,4)
end

-- Unpack value, letting unpack() handle byte swapping
-- Inputs: 0) unpack template, 1) data reference, 2) offset
-- Returns: unpacked number
-- - uses value of %unpackStd to determine the unpack template
-- - can only be called for 'S' or 'L' templates since these are the only
--   templates for which you can specify the byte ordering.
-- (port: `x$_[2]` is the facade's offset argument, which returns the end
--  position after the values -- alone when the data is too short, so a
--  missing second result means no value)
function ExifTool.DoUnpackStd(t, dataPt, pos)
    if perlTruthy(pos) then
        local val, endPos = unpack_(unpackStd[t], dataPt, pos)
        if endPos == nil then return nil end
        return val
    end
    return (unpack_(unpackStd[t], dataPt))
end
-- same, but with reversed byte order
function ExifTool.DoUnpackRev(t, dataPt, pos)
    local fmt = unpackRev[unpackStd[t]]
    if perlTruthy(pos) then
        local val, endPos = unpack_(fmt, dataPt, pos)
        if endPos == nil then return nil end
        return val
    end
    return (unpack_(fmt, dataPt))
end
-- Pack value
-- Inputs: 0) template, 1) value, 2) data ref (or undef), 3) offset (if data ref)
-- Returns: packed value
function ExifTool.DoPackStd(t, v, dataPt, pos)
    local val = pack(unpackStd[t], v)
    if dataPt then substr(dataPt, pos, perl.length(val), val) end
    return val
end
-- same, but with reversed byte order
function ExifTool.DoPackRev(t, v, dataPt, pos)
    local val = pack(unpackRev[unpackStd[t]], v)
    if dataPt then substr(dataPt, pos, perl.length(val), val) end
    return val
end

-- Unpack value, handling the byte swapping manually
-- Inputs: 0) # bytes, 1) unpack template, 2) data reference, 3) offset
-- Returns: unpacked number
-- - uses value of $swapBytes to determine byte ordering
function ExifTool.DoUnpack(bytes, template, dataPt, pos)
    local val
    if swapBytes then
        val = ''
        -- (`$val .= substr($$dataPt,$pos+$bytes,1) while $bytes--`)
        while bytes > 0 do bytes = bytes - 1 val = val .. substr(dataPt,pos+bytes,1) end
    else
        val = substr(dataPt,pos,bytes)
    end
    if val == nil then return nil end
    return (unpack_(template,val))
end

-- Unpack double value
-- Inputs: 0) unpack template, 1) data reference, 2) offset
-- Returns: unpacked number
function ExifTool.DoUnpackDbl(template, dataPt, pos)
    local val = substr(dataPt,pos,8)
    if val == nil then return nil end
    -- swap bytes and 32-bit words (ARM quirk) if necessary, then unpack value
    return (unpack_(template, ExifTool.SwapWords(ExifTool.SwapBytes(val, 8))))
end

-- Inputs: 0) data reference, 1) offset into data
function ExifTool.Get8s(dataPt, pos)     return ExifTool.DoUnpackStd('c', dataPt, pos) end
function ExifTool.Get8u(dataPt, pos)     return ExifTool.DoUnpackStd('C', dataPt, pos) end
function ExifTool.Get16s(dataPt, pos)    return ExifTool.DoUnpack(2, 's', dataPt, pos) end
function ExifTool.Get16u(dataPt, pos)    return ExifTool.DoUnpackStd('S', dataPt, pos) end
function ExifTool.Get32s(dataPt, pos)    return ExifTool.DoUnpack(4, 'l', dataPt, pos) end
function ExifTool.Get32u(dataPt, pos)    return ExifTool.DoUnpackStd('L', dataPt, pos) end
function ExifTool.GetFloat(dataPt, pos)  return ExifTool.DoUnpack(4, 'f', dataPt, pos) end
function ExifTool.GetDouble(dataPt, pos) return ExifTool.DoUnpackDbl('d', dataPt, pos) end
function ExifTool.Get16uRev(dataPt, pos) return ExifTool.DoUnpackRev('S', dataPt, pos) end
function ExifTool.Get32uRev(dataPt, pos) return ExifTool.DoUnpackRev('L', dataPt, pos) end

-- Uncommon utility routines to for reading binary data values
-- (upstream AUTOLOADs these from Writer.pl; the bodies are in Writer.lua)
function ExifTool.Get64s(dataPt, pos)
    return ExifTool.DoAutoLoad('Image::ExifTool::Get64s', dataPt, pos)
end

function ExifTool.Get64u(dataPt, pos)
    return ExifTool.DoAutoLoad('Image::ExifTool::Get64u', dataPt, pos)
end

function ExifTool.GetFixed64s(dataPt, pos)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetFixed64s', dataPt, pos)
end

-- Decode extended 80-bit float used by Apple SANE and Intel 8087
-- (note: different than the IEEE standard 80-bit float)
function ExifTool.GetExtended(dataPt, pos)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetExtended', dataPt, pos)
end

local Charset = require('lexiftool.Charset')

-- rationals may be a floating point number, 'inf' or 'undef'
local ratNumer, ratDenom
function ExifTool.GetRational32s(dataPt, pos)
    ratNumer = ExifTool.Get16s(dataPt,pos)
    ratDenom = ExifTool.Get16s(dataPt, pos + 2)
    if not perlTruthy(ratDenom) then return perlTruthy(ratNumer) and 'inf' or 'undef' end
    -- round off to a reasonable number of significant figures
    return ExifTool.RoundFloat(ratNumer / ratDenom, 7)
end
function ExifTool.GetRational32u(dataPt, pos)
    ratNumer = ExifTool.Get16u(dataPt,pos)
    ratDenom = ExifTool.Get16u(dataPt, pos + 2)
    if not perlTruthy(ratDenom) then return perlTruthy(ratNumer) and 'inf' or 'undef' end
    return ExifTool.RoundFloat(ratNumer / ratDenom, 7)
end
function ExifTool.GetRational64s(dataPt, pos)
    ratNumer = ExifTool.Get32s(dataPt,pos)
    ratDenom = ExifTool.Get32s(dataPt, pos + 4)
    if not perlTruthy(ratDenom) then return perlTruthy(ratNumer) and 'inf' or 'undef' end
    return ExifTool.RoundFloat(ratNumer / ratDenom, 10)
end
function ExifTool.GetRational64u(dataPt, pos)
    ratNumer = ExifTool.Get32u(dataPt,pos)
    ratDenom = ExifTool.Get32u(dataPt, pos + 4)
    if not perlTruthy(ratDenom) then return perlTruthy(ratNumer) and 'inf' or 'undef' end
    return ExifTool.RoundFloat(ratNumer / ratDenom, 10)
end
function ExifTool.GetFixed16s(dataPt, pos)
    local val = ExifTool.Get16s(dataPt, pos) / 0x100
    return truncTowardZero(val * 1000 + (val<0 and -0.5 or 0.5)) / 1000
end
function ExifTool.GetFixed16u(dataPt, pos)
    return truncTowardZero((ExifTool.Get16u(dataPt, pos) / 0x100) * 1000 + 0.5) / 1000
end
function ExifTool.GetFixed32s(dataPt, pos)
    local val = ExifTool.Get32s(dataPt, pos) / 0x10000
    -- remove insignificant digits
    return truncTowardZero(val * 1e5 + (val>0 and 0.5 or -0.5)) / 1e5
end
function ExifTool.GetFixed32u(dataPt, pos)
    -- remove insignificant digits
    return truncTowardZero((ExifTool.Get32u(dataPt, pos) / 0x10000) * 1e5 + 0.5) / 1e5
end
-- Inputs: 0) value, 1) data ref, 2) offset
-- (port: the in-place forms take the buffer first -- Set16u(dataPt, pos,
--  val) -- and the returning one-argument forms are the Put* functions
--  below)
function ExifTool.Set8s(dataPt, pos, val)  return ExifTool.DoPackStd('c', val, dataPt, pos) end
function ExifTool.Set8u(dataPt, pos, val)  return ExifTool.DoPackStd('C', val, dataPt, pos) end
function ExifTool.Set16u(dataPt, pos, val) return ExifTool.DoPackStd('S', val, dataPt, pos) end
function ExifTool.Set32u(dataPt, pos, val) return ExifTool.DoPackStd('L', val, dataPt, pos) end
function ExifTool.Set16uRev(dataPt, pos, val) return ExifTool.DoPackRev('S', val, dataPt, pos) end

-- (Writer.pl's Set16s/Set32s, reached through AUTOLOAD like upstream)
function ExifTool.Set16s(dataPt, pos, val)
    return ExifTool.DoAutoLoad('Image::ExifTool::Set16s', dataPt, pos, val)
end

function ExifTool.Set32s(dataPt, pos, val)
    return ExifTool.DoAutoLoad('Image::ExifTool::Set32s', dataPt, pos, val)
end

-- Pack a value using the current byte order (upstream's returning
-- one-argument Set16u/Set32u/Set8u, `Set16u($val)`)
function ExifTool.Put16u(val)
    return ExifTool.DoPackStd('S', val)
end

function ExifTool.Put32u(val)
    return ExifTool.DoPackStd('L', val)
end

-- (upstream's returning one-argument Set64u: high and low words in the
--  current byte order)
function ExifTool.Put64u(val)
    local hi = math.floor(val / 4294967296)
    local lo = math.floor(val - hi * 4294967296)
    if currentByteOrder == 'MM' then
        return ExifTool.Put32u(hi) .. ExifTool.Put32u(lo)
    end
    return ExifTool.Put32u(lo) .. ExifTool.Put32u(hi)
end

-- (upstream's returning `Set8u`/`Set32s`/`SetFixed32s` -- the same
--  scalar-returning form as Put16u/Put32u above; Writer.pl:5260/5318)
function ExifTool.Put8u(val)
    return ExifTool.DoPackStd('C', val)
end

function ExifTool.Put32s(val)
    if val < 0 then val = val + 0xffffffff + 1 end
    return ExifTool.Put32u(val)
end

function ExifTool.PutFixed32s(val)
    return ExifTool.Put32s(truncTowardZero(val * 0x10000 + (val < 0 and -0.5 or 0.5)))
end

--------------------------------------------------------------------------------
-- Get current byte order ('II' or 'MM')
function ExifTool.GetByteOrder() return currentByteOrder end

--------------------------------------------------------------------------------
-- Set byte ordering
-- Inputs: 0) 'MM'=motorola, 'II'=intel (will translate 'BigEndian', 'LittleEndian')
-- Returns: 1 on success
function ExifTool.SetByteOrder(order)
    if type(order) == 'table' then
        -- tolerate the colon-method call form et:SetByteOrder(order)
        order = order[1]
    end

    if order == 'MM' then       -- big endian (Motorola)
        unpackStd = unpackMotorola
    elseif order == 'II' then   -- little endian (Intel)
        unpackStd = unpackIntel
    elseif perl.isMatch(order, '(?i)^Big') then
        order = 'MM'
        unpackStd = unpackMotorola
    elseif perl.isMatch(order, '(?i)^Little') then
        order = 'II'
        unpackStd = unpackIntel
    else
        -- (port: upstream returns 0; nil keeps the Lua callers' plain
        --  boolean tests -- `SetByteOrder(...) or return` -- reading as in Perl)
        return nil
    end
    local val = unpack_('S','A ')
    local nativeOrder
    if val == 0x4120 then       -- big endian
        nativeOrder = 'MM'
    elseif val == 0x2041 then   -- little endian
        nativeOrder = 'II'
    else
        perl.warn(sprintf("Unknown native byte order! (pattern %x)\n",val))
        return nil
    end
    currentByteOrder = order  -- save current byte order

    -- swap bytes if our native CPU byte ordering is not the same as the EXIF
    swapBytes = (order ~= nativeOrder)

    -- little-endian ARM has big-endian words for doubles (thanks Riku Voipio)
    -- (Note: Riku's patch checked for '0ff3', but I think it should be 'f03f' since
    -- 1 is '000000000000f03f' on an x86 -- so check for both, but which is correct?)
    local pack1d = pack('d', 1)
    swapWords = (pack1d == "\0\0\x0f\xf3\0\0\0\0" or
                 pack1d == "\0\0\xf0\x3f\0\0\0\0")
    return 1
end
-- (upstream initializes %unpackStd to Motorola order but leaves $swapBytes
--  unset until the first SetByteOrder call; the port sets both here)
ExifTool.SetByteOrder('MM')

local readValueProc = {
    ['int8s'] = ExifTool.Get8s,
    ['int8u'] = ExifTool.Get8u,
    ['int16s'] = ExifTool.Get16s,
    ['int16u'] = ExifTool.Get16u,
    ['int16uRev'] = ExifTool.Get16uRev,
    ['int32s'] = ExifTool.Get32s,
    ['int32u'] = ExifTool.Get32u,
    ['int32uRev'] = ExifTool.Get32uRev,
    ['int64s'] = ExifTool.Get64s,
    ['int64u'] = ExifTool.Get64u,
    ['rational32s'] = ExifTool.GetRational32s,
    ['rational32u'] = ExifTool.GetRational32u,
    ['rational64s'] = ExifTool.GetRational64s,
    ['rational64u'] = ExifTool.GetRational64u,
    ['fixed16s'] = ExifTool.GetFixed16s,
    ['fixed16u'] = ExifTool.GetFixed16u,
    ['fixed32s'] = ExifTool.GetFixed32s,
    ['fixed32u'] = ExifTool.GetFixed32u,
    ['fixed64s'] = ExifTool.GetFixed64s,
    ['float'] = ExifTool.GetFloat,
    ['double'] = ExifTool.GetDouble,
    ['extended'] = ExifTool.GetExtended,
    ['ifd'] = ExifTool.Get32u,
    ['ifd64'] = ExifTool.Get64u,
}

local isRational = {
    ['rational32u'] = 1,
    ['rational32s'] = 1,
    ['rational64u'] = 1,
    ['rational64s'] = 1,
}

-- byte size for each format NAME (upstream %formatSize in ExifTool.pm)
local formatSize = {
    ['int8s'] = 1,
    ['int8u'] = 1,
    ['int16s'] = 2,
    ['int16u'] = 2,
    ['int16uRev'] = 2,
    ['int32s'] = 4,
    ['int32u'] = 4,
    ['int32uRev'] = 4,
    ['int64s'] = 8,
    ['int64u'] = 8,
    ['rational32s'] = 4,
    ['rational32u'] = 4,
    ['rational64s'] = 8,
    ['rational64u'] = 8,
    ['fixed16s'] = 2,
    ['fixed16u'] = 2,
    ['fixed32s'] = 4,
    ['fixed32u'] = 4,
    ['fixed64s'] = 8,
    ['float'] = 4,
    ['double'] = 8,
    ['extended'] = 10,
    ['unicode'] = 2,
    ['complex'] = 8,
    ['string'] = 1,
    ['binary'] = 1,
    ['undef'] = 1,
    ['ifd'] = 4,
    ['ifd64'] = 8,
    ['ue7'] = 1,
    ['utf8'] = 1, -- (Exif 3.0)
}

-- Byte size of a value format name (upstream FormatSize)
function ExifTool.FormatSize(format)
    return formatSize[format]
end

--------------------------------------------------------------------------------
-- Change byte order
function ExifTool.ToggleByteOrder()
    ExifTool.SetByteOrder(ExifTool.GetByteOrder() == 'II' and 'MM' or 'II')
end

--------------------------------------------------------------------------------
-- Read value from binary data (with current byte ordering)
-- Inputs: 0) data reference, 1) value offset, 2) format string,
--         3) number of values (or undef to use all data),
--         4) valid data length relative to offset (or undef to use all data),
--         5) optional pointer to returned rational
--         6) (port: Lua has no wantarray -- true asks for upstream's list
--            context, see the return below)
-- Returns: converted value, or undefined if data isn't there
--          or list of values in list context
--          (port: the list is returned as an array; upstream's `return undef`
--           and `return ''` give the one-element lists (undef) and (''), so
--           those are {} and { '' })
function ExifTool.ReadValue(dataPt, offset, format, count, size, ratPt, wantarray)
    local len = formatSize[format]
    if not len then
        len = 1
    end
    if size == nil then
        size = #dataPt - offset
    end
    if count == nil or count == 0 then
        if count ~= nil or size < len then return wantarray and { '' } or '' end
        count = math.floor(size / len)
    end
    -- make sure entry is inside data
    if len * count > size then
        count = math.floor(size / len) -- shorten count if necessary
        if count < 1 then -- return undefined if no data
            if wantarray then return {} end
            return nil
        end
    end
    local vals = {}
    local proc = readValueProc[format]
    if not proc then
        -- handle undef/binary/string (also unsupported unicode/complex)
        local v = substr(dataPt, offset, count * len)
        if format == 'string' then
            v = v:gsub('\0.*', '')
        end
        vals[1] = v
    elseif isRational[format] and ratPt then
        for i = 1, count do
            vals[i] = proc(dataPt, offset + (i - 1) * len)
            if i == 1 then
                ratPt.rat = perl.str(ratNumer) .. '/' .. perl.str(ratDenom)
            else
                ratPt.rat = ratPt.rat .. ' ' .. perl.str(ratNumer) .. '/' .. perl.str(ratDenom)
            end
        end
    else
        for i = 1, count do
            vals[i] = proc(dataPt, offset + (i - 1) * len)
        end
    end
    if wantarray then return vals end
    if #vals > 1 then
        local out = {}
        for i = 1, #vals do out[i] = ExifTool.NumStr(vals[i]) end
        return table.concat(out, ' ')
    end
    return vals[1]
end

--------------------------------------------------------------------------------
-- Small string helpers
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Make description from a tag name
-- Inputs: 0) tag name 1) optional tagID to add at end of description
-- Returns: description
function ExifTool.MakeDescription(tag, tagID)
    local desc = ucfirst(tag)
    -- translate underlines to spaces
    desc = desc:gsub('_', ' ')
    -- remove hex TagID from name
    if not tagID then
        desc = desc:gsub(' (0x[%da-f]+)$', function(m)
            tagID = m
            return ''
        end)
    end
    -- put a space between lower/UPPER case and lower/number combinations
    desc = desc:gsub('([a-z])([A-Z%d])', '%1 %2')
    -- put a space between acronyms and words
    desc = desc:gsub('([A-Z])([A-Z][a-z])', '%1 %2')
    -- put spaces after numbers (if more than one character follows the number)
    desc = desc:gsub('(%d)([A-Z][^ \t\n\r\f\v])', '%1 %2')
    if tagID then desc = desc .. ' ' .. perl.str(tagID) end
    return desc
end

--------------------------------------------------------------------------------
-- Is this a valid tag name?
-- Inputs: 0) tag name
-- Returns: true if valid
function ExifTool.ValidTagName(tag)
    return perl.isMatch(tag, [[^(([-\w]*|\d*\*):)*[_a-zA-Z?*][-\w?*]*#?$]])
end

--------------------------------------------------------------------------------
-- Generate a valid tag name based on the tag ID or name
-- Inputs: 0) tag ID or name
-- Returns: valid tag name
function ExifTool.MakeTagName(name)
    name = perl.tr(name, '-_a-zA-Z0-9', '', 'dc')    -- remove illegal characters
    name = perl.ucfirst(name)          -- capitalize first letter
    -- must at least 2 characters long and not start with - or 0-9-
    if perl.length(name) < 2 or perl.isMatch(name, '^[-0-9]') then name = 'Tag' .. name end
    return name
end

--------------------------------------------------------------------------------
-- Get Composite tag information
-- Inputs: 0) Composite tag name
-- Returns: tagInfo hash ref or undef
function ExifTool.GetCompositeTagInfo(tag)
    if not compositeID[tag] then return nil end
    return ExifTool.Composite[compositeID[tag][1]]
end

--------------------------------------------------------------------------------
-- Return List ExifTool API options
-- Returns: 0) reference to list of available options -- each entry is a list
--            [0=option name, 1=default value, 2=description]
function ExifTool.AvailableOptions()
    return availableOptions
end

--------------------------------------------------------------------------------
-- Get tag name (removes copy index)
-- Inputs: 0) Tag key
-- Returns: Tag name
function ExifTool.GetTagName(tag)
    return perl.str(tag or ''):match('^([^ \t\n\r\f\v]+)')
end

--------------------------------------------------------------------------------
-- Return list of ordered keys if available, otherwise just sort alphabetically
-- Inputs: 0) hash ref
-- Returns: List of ordered/sorted keys
function ExifTool.OrderedKeys(h)
    local ordered = h._ordered_keys_
    if ordered then
        local list = {}
        for i = 1, #ordered do list[i] = ordered[i] end
        return list
    end
    local keys = {}
    for k in pairs(h) do keys[#keys + 1] = k end
    tsort(keys)
    return keys
end

--------------------------------------------------------------------------------
-- Patched timelocal() that fixes ActivePerl timezone bug
-- Inputs/Returns: same as timelocal()
-- Notes: must 'require Time::Local' before calling this routine.
-- Also note that year should be full year, and not relative to 1900 as with localtime
function ExifTool.TimeLocal(...)
    local tm = perl.timelocal(...)
    if perl.osname() == 'MSWin32' then
        -- patch for ActivePerl timezone bug
        local t2 = localtime(tm)
        t2[6] = t2[6] + 1900
        local t2v = perl.timelocal(table.unpack(t2, 1, 6))
        -- adjust timelocal() return value to be consistent with localtime()
        tm = tm + tm - t2v
    end
    return tm
end

--------------------------------------------------------------------------------
-- Get time zone in minutes
-- Inputs: 0) localtime array ref, 1) gmtime array ref
-- Returns: time zone offset in minutes
-- (both arrays are 1-based here, so Perl's $$tm[N] is tm[N+1] -- see perl.gmtime)
function ExifTool.GetTimeZone(tm, gm)
    -- compute the number of minutes between localtime and gmtime
    local min = tm[3] * 60 + tm[2] - (gm[3] * 60 + gm[2])
    if tm[4] ~= gm[4] then
        -- account for case where one date wraps to the first of the next month
        if math.abs(tm[4] - gm[4]) ~= 1 then gm[4] = tm[4] - (tm[4] == 1 and 1 or -1) end
        -- adjust for the +/- one day difference
        min = min + (tm[4] - gm[4]) * 24 * 60
    end
    return min
end

--------------------------------------------------------------------------------
-- Get time zone string
-- Inputs: 0) time zone offset in minutes
--     or  0) localtime array ref, 1) corresponding time value
-- Returns: time zone string ("+/-HH:MM")
--
-- Format a timezone offset given in minutes as '+HH:MM'/'-HH:MM' (upstream
-- TimeZoneString)
function ExifTool.TimeZoneString(min, time)
    if type(min) == 'table' then
        local gm = gmtime(time)
        min = ExifTool.GetTimeZone(min, gm)
    end
    local sign = '+'
    if min < 0 then sign = '-'; min = -min end
    min = math.floor(min + 0.5) -- round off to nearest minute
    local h = math.floor(min / 60)
    return sprintf('%s%.2d:%.2d', sign, h, min - h * 60)
end

--------------------------------------------------------------------------------
-- Convert Unix time to EXIF date/time string
-- Inputs: 0) Unix time value, 1) non-zero to convert to local time, 2) number of
--         digits after the decimal for fractional seconds, negative to trim
--         trailing zeros, or undef to use SystemTimeRes
-- Returns: EXIF date/time string (with timezone for local times)
--
function ExifTool.ConvertUnixTime(time, toLocal, dec)
    time = perl.num(time)
    if time == 0 then return '0000:00:00 00:00:00' end
    local tm, tz, trim
    if dec == nil then
        dec = ExifTool.static_vars.SystemTimeRes
        if not perlTruthy(dec) then dec = 0 end
    end
    dec = perl.num(dec)
    if dec < 0 then dec = -dec; trim = true end
    local itime = perl.int(time)
    local frac = time - itime
    if frac < 0 then frac = frac + 1; itime = itime - 1 end
    dec = sprintf('%.*f', dec, frac)
    -- remove number before decimal and increment integer time if necessary
    local lead = perl.matches(dec, [[^(\d)]])
    if lead then
        dec = perl.subst(dec, [[^(\d)]], '')
        if lead == '1' then itime = itime + 1 end
    end
    if trim then dec = perl.subst(dec, [[\.?0+$]], '') end    -- trim trailing zeros if specified
    if not perlTruthy(toLocal) then
        tm = gmtime(itime)
        tz = ''
    elseif perlTruthy(ExifTool.static_vars.KeepUTCTime) then
        tm = gmtime(itime)
        tz = 'Z'
    else
        tm = localtime(itime)
        tz = ExifTool.TimeZoneString(tm, itime)
    end
    local str = sprintf('%4d:%.2d:%.2d %.2d:%.2d:%.2d' .. dec .. '%s',
                        tm[6] + 1900, tm[5] + 1, tm[4], tm[3], tm[2], tm[1], tz)
    return str
end

--------------------------------------------------------------------------------
-- Convert date/time from Exif format
-- Inputs: 0) ExifTool object reference, 1) Date/time in EXIF format
-- Returns: Formatted date/time string
function ExifTool:ConvertDateTime(date)
    local fmt = self.OPTIONS.DateFormat
    local shift = self.OPTIONS.GlobalTimeShift
    if perlTruthy(shift) then
        -- (ExifTool.pm:6578-6620)
        shift = perl.str(shift)
        local offset = self.GLOBAL_TIME_OFFSET
        local g, t, dir, matches
        local Shift = require('lexiftool.Shift')
        local c1, _, c3, c4 = perl.matches(shift, [[(?i)^((\d?[A-Z][-\w]*\w:)*)([A-Z][-\w]*\w)([-+])]])
        if c1 then
            shift = perl.subst(shift, [[(?i)^((\d?[A-Z][-\w]*\w:)*)([A-Z][-\w]*\w)([-+])]], '')
            g, t, dir = c1, c3, (c4 == '-' and -1 or 1)
        else
            local sign = perl.matches(shift, [[^([-+])]])
            if sign then shift = shift:sub(2) end
            dir = (sign == '-') and -1 or 1
        end
        if not offset then
            offset = { }
            self.GLOBAL_TIME_OFFSET = offset
            -- (see forum16692 for a discussion about why this code was added)
            matches = { }
            if t then
                -- determine initial shift from specified tag
                for key in pairs(self.VALUE) do
                    if perl.isMatchDyn(key, '(?i)^' .. t .. '( \\(|$)') then matches[#matches + 1] = key end
                end
                tsort(matches)
                if g ~= '' and #matches > 0 then
                    g = g:gsub(':$', '')
                    matches = self:GroupMatches(g, matches)
                end
            end
            if #matches == 0 and self.TAGS_FROM_FILE and self.OPTIONS.RequestTags then
                -- determine initial shift from first requested date/time tag
                local reqDate = { }
                for _, r in ipairs(self.OPTIONS.RequestTags) do
                    if perl.matches(r, [[(?i)date]]) then reqDate[#reqDate + 1] = r end
                end
                while #reqDate > 0 do
                    t = table.remove(reqDate, 1)
                    matches = { }
                    for key in pairs(self.VALUE) do
                        if perl.isMatchDyn(key, '(?i)^' .. t .. '( \\(|$)') then matches[#matches + 1] = key end
                    end
                    tsort(matches)
                    local ti = self.TAG_INFO
                    while #matches > 0 do
                        -- select the first tag that calls this routine in its PrintConv
                        -- (upstream tests the PrintConv *string* against
                        --  /ConvertDateTime/; ported PrintConvs are Lua
                        --  functions, so the date/time ones carry no such
                        --  text -- a function PrintConv counts as a candidate)
                        local pc = ti[matches[1]] and ti[matches[1]].PrintConv
                        if pc and (type(pc) == 'function' or
                            (type(pc) == 'string' and pc:find('ConvertDateTime', 1, true))) then
                            reqDate = { }
                            break
                        end
                        table.remove(matches, 1)
                    end
                end
            end
            if #matches > 0 then
                local val = self:GetValue(matches[1], 'ValueConv')
                if val ~= nil then Shift.ShiftTime(perl.str(val), shift, dir, offset) end
            end
        end
        local shifted = Shift.ShiftTime(perl.str(date), shift, dir, offset)
        if shifted then date = shifted end
    end
    -- only convert date if a format was specified and the date is recognizable
    if perlTruthy(fmt) then
        -- separate time zone if it exists
        date = perl.str(date)
        local tz = perl.matches(date, [[([-+]\d{2}:\d{2}|Z)$]])
        if tz then date = perl.subst(date, [[([-+]\d{2}:\d{2}|Z)$]], '') end
        -- a few cameras use incorrect date/time formatting:
        -- - slashes instead of colons in date (RolleiD330, ImpressCam)
        -- - date/time values separated by colon instead of space (Polariod, Sanyo, Sharp, Vivitar)
        -- - single-digit seconds with leading space (HP scanners)
        local a = { perl.reverse(table.unpack(perl.findAll(date, [[\d+]]))) }  -- be very flexible about date/time format
        for i = 1, #a do a[i] = perl.num(a[i]) end     -- (numeric from here on, as Perl uses them)
        if #a > 0 and a[#a] >= 1000 and a[#a] < 3000 then
            while #a > 6 do table.remove(a, 1) end      -- remove superfluous entries
            while #a < 3 do table.insert(a, 1, 1) end   -- add month and day if necessary
            while #a < 6 do table.insert(a, 1, 0) end   -- add h,m,s if necessary
            a[5] = a[5] - 1                 -- base month is 1
            -- parse our %f fractional seconds first (and round up seconds if necessary)
            -- - if there are multiple %f codes, they all get the same number of digits as the first
            local neg, dig = perl.matches(fmt, [[%(-?)\.?(\d*)f]])
            if neg then
                local frac = perl.matches(date, [[(\.\d+)]]) or ''
                if not perlTruthy(frac) then
                    if perlTruthy(dig) then frac = '.' .. string.rep('0', perl.num(dig)) end
                elseif #dig > 0 then
                    if perl.num(dig) + 1 > #frac then
                        frac = frac .. string.rep('0', perl.num(dig) + 1 - #frac)
                    elseif perl.num(dig) + 1 < #frac then
                        frac = sprintf('%.' .. dig .. 'f', frac)
                        while true do -- luacheck: ignore 512 (upstream's while ends in `last` on every path)
                            local d = perl.matches(frac, [[^(\d)]])
                            if d then frac = perl.subst(frac, [[^(\d)]], '') end
                            if not (d and d ~= '0') then break end
                            -- this is a pain, but we must round up to the next second
                            a[1] = a[1] + 1
                            if a[1] < 60 then break end
                            a[1] = 0
                            a[2] = a[2] + 1
                            if a[2] < 60 then break end
                            a[2] = 0
                            a[3] = a[3] + 1
                            if a[3] < 24 then break end
                            a[3] = 0
                            local Shift = require('lexiftool.Shift')
                            a[4] = a[4] + 1
                            if a[4] <= Shift.DaysInMonth(a[5] + 1, a[6]) then break end
                            a[4] = 1
                            a[5] = a[5] + 1
                            if a[5] < 12 then break end
                            a[5] = 0
                            a[6] = a[6] + 1
                            break -- (this was a goto)
                        end
                    end
                end
                if perlTruthy(neg) then frac = perl.subst(frac, [[^\.]], '') end
                -- (function replacement: `$1$2$frac` interpolates a value, not
                --  a replacement template; the inner `(%%)` is non-capturing
                --  here, as below)
                fmt = perl.subst(fmt, [[(^|[^%])((?:%%)*)%-?\.?\d*f]],
                    function(c1, c2) return (c1 or '') .. (c2 or '') .. frac end, 'g')
            end
            -- parse %z and %s ourself (to handle time zones properly)
            if perl.isMatch(fmt, '%:?[sz]') then
                -- use system time zone unless otherwise specified
                if not perlTruthy(tz) then tz = ExifTool.TimeZoneString(a, ExifTool.TimeLocal(table.unpack(a, 1, 6))) end
                -- remove colon, setting to UTC if time zone is not numeric
                if not (perlTruthy(tz) and perl.isMatch(tz, [[^[-+]\d{2}:\d{2}$]])) then tz = '+00:00' end
                -- (function replacements: `$1$2$tz` interpolates a value, not a
                --  replacement template; upstream's inner `(%%)` is never used, so
                --  it is non-capturing here, which keeps every group set)
                local function insert(c1, c2) return (c1 or '') .. (c2 or '') .. tz end
                fmt = perl.subst(fmt, [[(^|[^%])((?:%%)*)%:z]], insert, 'g')     -- convert '%:z' format codes
                tz = perl.subst(tz, ':', '')
                fmt = perl.subst(fmt, [[(^|[^%])((?:%%)*)%z]], insert, 'g')      -- convert '%z' format codes
                if perl.isMatch(fmt, '%s') then
                    -- calculate seconds since the Epoch, UTC
                    local ntz = perl.num(tz)
                    local s = perl.timegm(table.unpack(a, 1, 6)) - 60 * (ntz - perl.int(ntz / 100) * 40)
                    fmt = perl.subst(fmt, [[(^|[^%])((?:%%)*)%s]],
                        function(c1, c2) return (c1 or '') .. (c2 or '') .. perl.str(s) end, 'g')   -- convert '%s' format codes
                end
            end
            a[6] = a[6] - 1900  -- strftime year starts from 1900
            date = strftime(fmt, table.unpack(a, 1, 6))  -- generate the formatted date/time
            -- apparently strftime can set the UTF-8 flag (argh!), so reset this if necessary
            if perl.isMatch(fmt, '[\x80-\xff]') then date = require('lexiftool.Writer').Sanitize(self, date) end
        elseif perlTruthy(self.OPTIONS.StrictDate) then
            date = nil
        end
    end
    return date
end

--------------------------------------------------------------------------------
-- Print conversion for file size
-- Inputs: 0) file size in bytes, 1) optional ExifTool ref
-- Returns: converted file size
function ExifTool.ConvertFileSize(val, et)
    local n = perl.num(val)    -- (Perl compares and divides numerically, but prints $val as is)
    if et and et.OPTIONS.ByteUnit == 'Binary' then
        if n < 2048 then return val .. ' bytes' end
        if n < 10240 then return sprintf('%.1f KiB', n / 1024) end
        if n < 2097152 then return sprintf('%.0f KiB', n / 1024) end
        if n < 10485760 then return sprintf('%.1f MiB', n / 1048576) end
        if n < 2147483648 then return sprintf('%.0f MiB', n / 1048576) end
        if n < 10737418240 then return sprintf('%.1f GiB', n / 1073741824) end
        return sprintf('%.0f GiB', n / 1073741824)
    end
    if n < 2000 then return val .. ' bytes' end
    if n < 10000 then return sprintf('%.1f kB', n / 1000) end
    if n < 2000000 then return sprintf('%.0f kB', n / 1000) end
    if n < 10000000 then return sprintf('%.1f MB', n / 1000000) end
    if n < 2000000000 then return sprintf('%.0f MB', n / 1000000) end
    if n < 10000000000 then return sprintf('%.1f GB', n / 1000000000) end
    return sprintf('%.0f GB', n / 1000000000)
end

--------------------------------------------------------------------------------
-- Limit length of long values (to be used in PrintConv)
-- Inputs: 0) string value, 1) ExifTool ref
-- Returns: length-limited value
function ExifTool.LimitLongValues(str, et)
    str = ExifTool.NumStr(str)
    local lim = et and et.OPTIONS.LimitLongValues
    if lim and #str > lim and lim >= 5 then
        str = substr(str, 0, lim - 5) .. '[...]'
    end
    return str
end

--------------------------------------------------------------------------------
-- Convert seconds to duration string (handles negative durations)
-- Inputs: 0) floating point seconds
-- Returns: duration string in form "S.SS s", "H:MM:SS" or "DD days HH:MM:SS"
function ExifTool.ConvertDuration(time)
    if not ExifTool.IsFloat(time) then return time end
    if time == 0 then return '0 s' end
    local sign = ''
    if time < 0 then
        time = -time
        sign = '-'
    end
    if time < 30 then return sprintf('%s%.2f s', sign, time) end
    time = time + 0.5 -- round off to nearest second
    local h = math.floor(time / 3600)
    time = time - h * 3600
    local m = math.floor(time / 60)
    time = time - m * 60
    if h > 24 then
        local d = math.floor(h / 24)
        h = h - d * 24
        sign = sign .. d .. ' days '
    end
    return sprintf('%s%d:%.2d:%.2d', sign, h, m, math.floor(time))
end

--------------------------------------------------------------------------------
-- Print conversion for bitrate values
-- Inputs: 0) bitrate in bits per second
-- Returns: human-readable bitrate string
-- Notes: returns input value without formatting if it isn't numerical
function ExifTool.ConvertBitrate(bitrate)
    if not ExifTool.IsFloat(bitrate) then return bitrate end
    local units = { 'bps', 'kbps', 'Mbps', 'Gbps' }
    local i = 1
    while true do
        local unit = units[i]
        i = i + 1
        if bitrate >= 1000 and units[i] then
            bitrate = bitrate / 1000
        else
            local fmt = bitrate < 100 and '%.3g %s' or '%.0f %s'
            return sprintf(fmt, bitrate, unit)
        end
    end
end

-- Convert a time span in seconds (or multiplied by a factor) to a
-- human-readable string (upstream ExifTool::ConvertTimeSpan)
-- Inputs: 0) value, 1) optional multiplier
-- Returns: human-readable time span string
function ExifTool.ConvertTimeSpan(val, mult)
    if ExifTool.IsFloat(val) and val ~= 0 then
        if mult then val = val * mult end
        if val < 60 then
            val = val .. ' seconds'
        elseif val < 3600 then
            local fmt = (mult and mult >= 60) and '%d' or '%.1f'
            local s = (val == 60 and mult) and '' or 's'
            val = sprintf(fmt .. ' minute' .. s, val / 60)
        elseif val < 24 * 3600 then
            val = sprintf('%.1f hours', val / 3600)
        else
            val = sprintf('%.1f days', val / (24 * 3600))
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Split file name into directory and name parts
-- Inptus: 0) file name
-- Returns: 0) directory, 1) filename
function ExifTool.SplitFileName(file)
    local name = perl.str(file):gsub('\\', '/')
    local dir = name:match('^(.*)/[^/]+$')
    if dir then
        dir = #dir > 0 and dir or '/'
    else
        dir = '.'
    end
    local n = perl.str(file):match('([^/\\]+)$')
    return dir, n or name
end

--------------------------------------------------------------------------------
-- Get standardized file extension
-- Inputs: 0) file name
-- Returns: standardized extension (all uppercase), or undefined if no extension
function ExifTool.GetFileExtension(filename)
    if filename then
        local fileExt = perl.str(filename):match('^.*%.([^%.]+)$')
        if fileExt then
            fileExt = uc(fileExt)
            -- convert TIF extension to TIFF (we use the extension as the type)
            if fileExt == 'TIF' then fileExt = 'TIFF' end
            return fileExt
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Convert file name for printing
-- Inputs: 0) ExifTool ref, 1) file name in CharsetFileName character set
-- Returns: converted file name in external character set
--
-- Convert a file name for the FileName/Directory tags (subset: no encoding
-- conversion; the value passes through).
function ExifTool.ConvertFileName(_self, val)
    return val
end

--------------------------------------------------------------------------------
-- Convert a file name back for writing (upstream ExifTool.pm InverseFileName)
-- Inputs: 0) ExifTool ref, 1) file name in external character set
-- Returns: file name in CharsetFileName character set
--
-- Subset: no encoding conversion (there is no CharsetFileName option here), so
-- only upstream's backslash-to-forward-slash translation remains.
function ExifTool.InverseFileName(_self, val)
    return (perl.str(val):gsub('\\', '/'))
end

--------------------------------------------------------------------------------
-- Get new file path name
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.GetNewFileName(oldName, newName)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetNewFileName', oldName, newName)
end

-- PrintConv for FilePermissions (ExifTool.pm:1518-1535): takes the octal
-- ValueConv string and renders the familiar "-rw-r--r--". Like upstream it
-- shows only the rwx bits; setuid/setgid/sticky are not marked.
local S_IFMT_CHAR = {
    [0x1000] = 'p', -- FIFO
    [0x2000] = 'c', -- character special
    [0x4000] = 'd', -- directory
    [0x6000] = 'b', -- block special
    [0xa000] = 'l', -- symlink
    [0xc000] = 's', -- socket
}

function ExifTool.FormatFilePermissions(val)
    local mode = tonumber(perl.str(val), 8)
    if not mode then return perl.str(val) end
    local str = S_IFMT_CHAR[mode & 0xf000] or '-'
    local mask = 0x100 -- 0400
    while mask > 0 do
        for _, bit in ipairs({ 'r', 'w', 'x' }) do
            str = str .. ((mode & mask) ~= 0 and bit or '-')
            mask = mask >> 1
        end
    end
    return str
end

--------------------------------------------------------------------------------
-- File type tables
--------------------------------------------------------------------------------

-- lookup for all recognized file types, in the order we test unknown files
-- Notes: 1) There is no need to test for like types separately.  Just check
-- for one type from each group and set the appropriate extension for the type
-- 2) Put types with weak file signatures at end of list to avoid false matches
-- 3) PLIST must be in this list for the binary PLIST format, although it may
--    cause a file to be checked twice for XML
local fileTypes = {
    'JPEG', 'EXV', 'CRW', 'DR4', 'TIFF', 'GIF', 'MRW', 'RAF', 'X3F', 'JP2',
    'PNG', 'MIE', 'MIFF', 'PS', 'PDF', 'PSD', 'XMP', 'BMP', 'WPG', 'BPG',
    'PPM', 'WV', 'RIFF', 'AIFF', 'ASF', 'MOV', 'MPEG', 'Real', 'SWF', 'PSP',
    'FLV', 'OGG', 'FLAC', 'APE', 'MPC', 'MKV', 'MXF', 'DV', 'PMP', 'IND',
    'PGF', 'ICC', 'ITC', 'FLIR', 'FLIF', 'FPF', 'LFP', 'HTML', 'VRD', 'RTF',
    'FIT', 'FITS', 'XISF', 'XCF', 'DSF', 'DSS', 'QTIF', 'FPX', 'PICT', 'ZIP',
    'GZIP', 'PLIST', 'RAR', '7Z', 'BZ2', 'CZI', 'TAR', 'EXE', 'EXR', 'HDR',
    'CHM', 'LNK', 'WMF', 'AVC', 'DEX', 'DPX', 'RAW', 'Font', 'JUMBF', 'RSRC',
    'M2TS', 'MacOS', 'PHP', 'PCX', 'DCX', 'DWF', 'DWG', 'DXF', 'WTV',
    'Torrent', 'VCard', 'LRI', 'R3D', 'AA', 'PDB', 'PFM2', 'MRC', 'LIF',
    'JXL', 'MOI', 'ISO', 'ALIAS', 'PCAP', 'JSON', 'MP3', 'KVAR', 'TNEF',
    'DICOM', 'PCD', 'NKA', 'ICO', 'TXT', 'AAC',
}

-- file types we can write (upstream @writeTypes; the port's own write path
-- covers only part of this list, but the list itself is what -listwf reports)
local writeTypes = {
    'JPEG', 'TIFF', 'GIF', 'CRW', 'MRW', 'ORF', 'RAF', 'RAW', 'PNG', 'MIE',
    'PSD', 'XMP', 'PPM', 'EPS', 'X3F', 'PS', 'PDF', 'ICC', 'VRD', 'DR4',
    'JP2', 'JXL', 'EXIF', 'AI', 'AIT', 'IND', 'MOV', 'EXV', 'FLIF', 'RIFF',
}

-- file extensions that we can't write for various base types
-- (See here for 3FR reason: https://exiftool.org/forum/index.php?msg=17570)
local noWriteFile = {
    TIFF = { '3FR', 'DCR', 'K25', 'KDC', 'SRF' },
    XMP  = { 'SVG', 'INX', 'NXD' },
    JP2  = { 'J2C', 'JPC' },
    MOV  = { 'INSV' },
}
-- file extensions that we can only write for various base types
local onlyWriteFile = { RIFF = { 'WEBP' } }

-- file types that we can create from scratch
-- - must update CanCreate() documentation if this list is changed!
local createTypes = { XMP = 1, ICC = 1, MIE = 1, VRD = 1, DR4 = 1, EXIF = 1, EXV = 1 }
-- (published like upstream's package variables @fileTypes and %noWriteFile,
--  which Writer.pl's WriteInfo reads)
ExifTool.fileTypes = fileTypes
ExifTool.noWriteFile = noWriteFile

-- module names for file types whose module has a different name, and for
-- types that are recognized but not supported (upstream %moduleName -- a 0
-- value marks the latter, which is what GetFileType's "supported" filter
-- keys off; an empty string means the type is handled in this file)
local moduleName = {
    AA          = 'Audible',
    ALIAS       = 0,
    AVC         = 0,
    BTF         = 'BigTIFF',
    BZ2         = 0,
    CRW         = 'CanonRaw',
    CHM         = 'EXE',
    COS         = 'CaptureOne',
    CZI         = 'ZISRAW',
    DEX         = 0,
    DOCX        = 'OOXML',
    DCX         = 0,
    DIR         = 0,
    DR4         = 'CanonVRD',
    DSS         = 'Olympus',
    DWF         = 0,
    DWG         = 0,
    DXF         = 0,
    EPS         = 'PostScript',
    EXIF        = '',
    EXR         = 'OpenEXR',
    EXV         = '',
    ICC         = 'ICC_Profile',
    IND         = 'InDesign',
    FIT         = 'Garmin',
    FLV         = 'Flash',
    FPF         = 'FLIR',
    FPX         = 'FlashPix',
    GZIP        = 'ZIP',
    HDR         = 'Radiance',
    JP2         = 'Jpeg2000',
    JPEG        = '',
    JUMBF       = 'Jpeg2000',
    JXL         = 'Jpeg2000',
    KVAR        = 'Kandao',
    LFP         = 'Lytro',
    LRI         = 0,
    MOV         = 'QuickTime',
    MKV         = 'Matroska',
    MP3         = 'ID3',
    MRW         = 'MinoltaRaw',
    NKA         = 'Nikon',
    OGG         = 'Ogg',
    ORF         = 'Olympus',
    PDB         = 'Palm',
    PCD         = 'PhotoCD',
    PFM2        = 'Other',
    PHP         = 0,
    PMP         = 'Sony',
    PS          = 'PostScript',
    PSD         = 'Photoshop',
    QTIF        = 'QuickTime',
    R3D         = 'Red',
    RAF         = 'FujiFilm',
    RAR         = 'ZIP',
    RAW         = 'KyoceraRaw',
    RWZ         = 'Rawzor',
    SWF         = 'Flash',
    TAR         = 0,
    TIFF        = '',
    TXT         = 'Text',
    VRD         = 'CanonVRD',
    WMF         = 0,
    WV          = 'WavPack',
    X3F         = 'SigmaRaw',
    XCF         = 'GIMP',
}

ExifTool.testLen = 1024    -- number of bytes to read when testing for magic number

-- quick "magic number" file test used to avoid loading module unnecessarily:
-- - regular expression evaluated on first $testLen bytes of file
-- - must match beginning at first byte in file
-- - this test must not be more stringent than module logic
-- (the patterns are carried over verbatim from upstream, so they are PCRE2,
--  not Lua patterns, and are matched through the perl facade; long-bracket
--  strings keep the backslashes readable exactly as in the Perl source)
local magicNumber = {
    AA   = [==[.{4}\x57\x90\x75\x36]==],
    AAC  = [==[\xff[\xf0\xf1]]==],
    AIFF = [==[(FORM....AIF[FC]|AT&TFORM)]==],
    ALIAS= [==[book\0\0\0\0mark\0\0\0\0]==],
    APE  = [==[(MAC |APETAGEX|ID3)]==],
    ASF  = [==[\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c]==],
    AVC  = [==[\+A\+V\+C\+]==],
    Torrent = [==[d\d+:\w+]==],
    BMP  = [==[BM]==],
    BPG  = [==[BPG\xfb]==],
    BTF  = [==[(II\x2b\0|MM\0\x2b)]==],
    BZ2  = [==[BZh[1-9]\x31\x41\x59\x26\x53\x59]==],
    CHM  = [==[ITSF.{20}\x10\xfd\x01\x7c\xaa\x7b\xd0\x11\x9e\x0c\0\xa0\xc9\x22\xe6\xec]==],
    CRW  = [==[(II|MM).{4}HEAP(CCDR|JPGM)]==],
    CZI  = [==[ZISRAWFILE\0{6}]==],
    DCX  = [==[\xb1\x68\xde\x3a]==],
    DEX  = [==[dex\n035\0]==],
    DICOM= [==[(.{128}DICM|\0[\x02\x04\x06\x08]\0[\0-\x20]|[\x02\x04\x06\x08]\0[\0-\x20]\0)]==],
    DOCX = [==[PK\x03\x04]==],
    DPX  = [==[(SDPX|XPDS)]==],
    DR4  = [==[IIII[\x04|\x05]\0\x04\0]==],
    DSF  = [==[DSD \x1c\0{7}.{16}fmt ]==],
    DSS  = [==[(\x02dss|\x03ds2)]==],
    DV   = [==[\x1f\x07\0[\x3f\xbf]]==], -- (not tested if extension recognized)
    DWF  = [==[\(DWF V\d]==],
    DWG  = [==[AC10\d{2}\0]==],
    DXF  = [==[\s*0\s+\0?\s*SECTION\s+2\s+HEADER]==],
    EPS  = [==[(%!PS|%!Ad|\xc5\xd0\xd3\xc6)]==],
    EXE  = [==[(MZ|\xca\xfe\xba\xbe|\xfe\xed\xfa[\xce\xcf]|[\xce\xcf]\xfa\xed\xfe|Joy!peff|\x7fELF|#!\s*/\S*bin/|!<arch>\x0a)]==],
    EXIF = [==[(II\x2a\0|MM\0\x2a)]==],
    EXR  = [==[\x76\x2f\x31\x01]==],
    EXV  = [==[\xff\x01Exiv2]==],
    FIT  = [==[.{8}\.FIT]==],
    FITS = [==[SIMPLE  = {20}T]==],
    FLAC = [==[(fLaC|ID3)]==],
    FLIF = [==[FLIF[0-\x6f][0-2]]==],
    FLIR = [==[[AF]FF\0]==],
    FLV  = [==[FLV\x01]==],
    Font = [==[((\0\x01\0\0|OTTO|true|typ1)[\0\x01]|ttcf\0[\x01\x02]\0\0|\0[\x01\x02]|]==] ..
           [==[(.{6})?%!(PS-(AdobeFont-|Bitstream )|FontType1-)|Start(Comp|Master)?FontMetrics|wOF[F2])]==],
    FPF  = [==[FPF Public Image Format\0]==],
    FPX  = [==[\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1]==],
    GIF  = [==[GIF8[79]a]==],
    GZIP = [==[\x1f\x8b\x08]==],
    HDR  = [==[#\?(RADIANCE|RGBE)\x0a]==],
    HTML = [==[(\xef\xbb\xbf)?\s*(?i)<(!DOCTYPE\s+HTML|HTML|\?xml)]==], -- (case insensitive)
    ICC  = [==[.{12}(scnr|mntr|prtr|link|spac|abst|nmcl|nkpf|cenc|mid |mlnk|mvis)]==] ..
           [==[(XYZ |Lab |Luv |YCbr|Yxy |RGB |GRAY|HSV |HLS |CMYK|CMY |[2-9A-F]CLR|nc..|\0{4}){2}]==],
    ICO  = [==[\0\0[\x01\x02]\0[^0]\0]==], -- (reasonably assume that the file contains less than 256 images)
    IND  = [==[\x06\x06\xed\xf5\xd8\x1d\x46\xe5\xbd\x31\xef\xe7\xfe\x74\xb7\x1d]==],
  -- ISO  =  signature is at byte 32768
    ITC  = [==[.{4}itch]==],
    JP2  = [==[(\0\0\0\x0cjP(  |\x1a\x1a)\x0d\x0a\x87\x0a|\xff\x4f\xff\x51\0)]==],
    JPEG = [==[\xff\xd8\xff]==],
    JSON = [==[(\xef\xbb\xbf)?\s*(\[\s*)?\{\s*"[^"]*"\s*:]==],
    JUMBF= [==[.{4}jumb\0.{3}jumd]==],
    JXL  = [==[(\xff\x0a|\0\0\0\x0cJXL \x0d\x0a......ftypjxl )]==],
    KVAR = [==[.{2}\0\0[A-Z].{31}(CHAR|BOOL|[US](8|16|32|64)|FLOAT|DOUBLE)\0]==],
    LFP  = [==[\x89LFP\x0d\x0a\x1a\x0a]==],
    LIF  = [==[\x70\0{3}.{4}\x2a.{4}<\0]==],
    LNK  = [==[(.{4}\x01\x14\x02\0{5}\xc0\0{6}\x46|\[[InternetShortcut\][\x0d\x0a])]==],
    LRI  = [==[LELR \0]==],
    M2TS = [==[.{0,191}?\x47(.{187}|.{191})\x47(.{187}|.{191})\x47]==],
    MacOS= [==[\0\x05\x16\x07\0.\0\0Mac OS X        ]==],
    MIE  = [==[~[\x10\x18]\x04.0MIE]==],
    MIFF = [==[id=ImageMagick]==],
    MKV  = [==[\x1a\x45\xdf\xa3]==],
    MOV  = [==[.{4}(free|skip|wide|ftyp|pnot|PICT|pict|moov|mdat|junk|uuid)]==], -- (duplicated in WriteQuickTime.pl !!)
  -- MP3  =  difficult to rule out
    MPC  = [==[(MP\+|ID3)]==],
    MOI  = [==[V6]==],
    MPEG = [==[\0\0\x01[\xb0-\xbf]]==],
    MRC  = [==[.{64}[\x01\x02\x03]\0\0\0[\x01\x02\x03]\0\0\0[\x01\x02\x03]\0\0\0.{132}MAP[\0 ](\x44\x44|\x44\x41|\x11\x11)\0\0]==],
    MRW  = [==[\0MR[MI]]==],
    MXF  = [==[\x06\x0e\x2b\x34\x02\x05\x01\x01\x0d\x01\x02]==], -- (not tested if extension recognized)
    NKA  = [==[NIKONADJ]==],
    OGG  = [==[(OggS|ID3)]==],
    ORF  = [==[(II|MM)]==],
    PCAP = [==[\xa1\xb2(\xc3\xd4|\x3c\x4d)\0.\0.|(\xd4\xc3|\x4d\x3c)\xb2\xa1.\0.\0|\x0a\x0d\x0d\x0a.{4}(\x1a\x2b\x3c\x4d|\x4d\x3c\x2b\x1a)|GMBU\0\x02]==],
  -- PCD  =  signature is at byte 2048
    PCX  = [==[\x0a[\0-\x05]\x01[\x01\x02\x04\x08].{64}[\0-\x02]]==],
    PDB  = [==[.{60}(\.pdfADBE|TEXtREAd|BVokBDIC|DB99DBOS|PNRdPPrs|DataPPrs|vIMGView|]==] ..
           [==[PmDBPmDB|InfoINDB|ToGoToGo|SDocSilX|JbDbJBas|JfDbJFil|DATALSdb|Mdb1Mdb1|]==] ..
           [==[BOOKMOBI|DataPlkr|DataSprd|SM01SMem|TEXtTlDc|InfoTlIf|DataTlMl|DataTlPt|]==] ..
           [==[dataTDBP|TdatTide|ToRaTRPW|zTXTGPlm|BDOCWrdS)]==],
    PDF  = [==[\s*%PDF-\d+\.\d+]==],
    PFM  = [==[P[Ff]\x0a\d+ \d+\x0a[-+0-9.]+\x0a]==],
    PGF  = [==[PGF]==],
    PHP  = [==[<\?php\s]==],
    PICT = [==[(.{10}|.{522})(\x11\x01|\x00\x11)]==],
    PLIST= [==[(bplist0|\s*<|\xfe\xff\x00)]==],
    PMP  = [==[.{8}\0{3}\x7c.{112}\xff\xd8\xff\xdb]==],
    PNG  = [==[(\x89P|\x8aM|\x8bJ)NG\r\n\x1a\n]==],
    PPM  = [==[P[1-6]\s+]==],
    PS   = [==[(%!PS|%!Ad|\xc5\xd0\xd3\xc6)]==],
    PSD  = [==[8BPS\0[\x01\x02]]==],
    PSP  = [==[Paint Shop Pro Image File\x0a\x1a\0{5}]==],
    QTIF = [==[.{4}(idsc|idat|iicc)]==],
    R3D  = [==[\0\0..RED(1|2)]==],
    RAF  = [==[FUJIFILM]==],
    RAR  = [==[Rar!\x1a\x07\x01?\0]==],
    RAW  = [==[(.{25}ARECOYK|II|MM)]==],
    Real = [==[(\.RMF|\.ra\xfd|pnm://|rtsp://|http://)]==],
    RIFF = [==[(RIFF|LA0[234]|OFR |LPAC|wvpk|RF64)]==], -- RIFF plus other variants
    RSRC = [==[(....)?\0\0\x01\0]==],
    RTF  = [==[[\n\r]*\{[\n\r]*\\rtf]==],
    RWZ  = [==[rawzor]==],
    SWF  = [==[[FC]WS[^\0]]==],
    TAR  = [==[.{257}ustar(  )?\0]==], -- (this doesn't catch old-style tar files)
    TNEF = [==[\x78\x9f\x3e\x22..\x01\x06\x90\x08\0]==],
    TXT  = [==[(\xff\xfe|(\0\0)?\xfe\xff|(\xef\xbb\xbf)?[\x07-\x0d\x20-\x7e\x80-\xfe]*$)]==],
    TIFF = [==[(II|MM)]==], -- don't test magic number (some raw formats are different)
    VCard= [==[(?i)BEGIN:(VCARD|VCALENDAR|VNOTE)\r\n]==],
    VRD  = [==[CANON OPTIONAL DATA\0]==],
    WMF  = [==[(\xd7\xcd\xc6\x9a\0\0|\x01\0\x09\0\0\x03)]==],
    WPG  = [==[\xff\x57\x50\x43]==],
    WTV  = [==[\xb7\xd8\x00\x20\x37\x49\xda\x11\xa6\x4e\x00\x07\xe9\x5e\xad\x8d]==],
    X3F  = [==[FOVb]==],
    XCF  = [==[gimp xcf ]==],
    XISF = [==[XISF0100]==],
    XMP  = [==[\0{0,3}(\xfe\xff|\xff\xfe|\xef\xbb\xbf)?\0{0,3}\s*<]==],
    ZIP  = [==[PK\x03\x04]==],
}
-- (published like upstream's package variable %magicNumber, see above)
ExifTool.magicNumber = magicNumber

-- upstream `$hdr =~ /^$magicNumber{$type}/s` in boolean context (isMatch,
-- not matches: in some of the patterns above the first group can stay unset,
-- e.g. XMP's BOM, and matches' first return value is then nil).  The pattern
-- is built from a fixed table, so the cached perl.isMatch is right for it.
local function testMagic(hdr, type_)
    local pat = magicNumber[type_]
    if not pat then return false end
    return perl.isMatch(hdr, '(?s)^' .. pat)
end

-- lookup for valid character set names (keys are all lower case)
-- (ExifTool.pm:1077; upstream %charsetName is a package variable read by
--  FlashPix.pm, Palm.pm, RTF.pm and TNEF.pm, so publish it the same way)
local charsetName = {
    --   Charset setting                       alias(es)
    -- -------------------------   --------------------------------------------
    utf8        = 'UTF8',        cp65001 = 'UTF8', ['utf-8'] = 'UTF8',
    latin       = 'Latin',       cp1252  = 'Latin', latin1 = 'Latin',
    latin2      = 'Latin2',      cp1250  = 'Latin2',
    cyrillic    = 'Cyrillic',    cp1251  = 'Cyrillic', russian = 'Cyrillic',
    greek       = 'Greek',       cp1253  = 'Greek',
    turkish     = 'Turkish',     cp1254  = 'Turkish',
    hebrew      = 'Hebrew',      cp1255  = 'Hebrew',
    arabic      = 'Arabic',      cp1256  = 'Arabic',
    baltic      = 'Baltic',      cp1257  = 'Baltic',
    vietnam     = 'Vietnam',     cp1258  = 'Vietnam',
    thai        = 'Thai',        cp874   = 'Thai',
    doslatinus  = 'DOSLatinUS',  cp437   = 'DOSLatinUS',
    doslatin1   = 'DOSLatin1',   cp850   = 'DOSLatin1',
    doscyrillic = 'DOSCyrillic', cp866   = 'DOSCyrillic',
    macroman    = 'MacRoman',    cp10000 = 'MacRoman', mac = 'MacRoman', roman = 'MacRoman',
    maclatin2   = 'MacLatin2',   cp10029 = 'MacLatin2',
    maccyrillic = 'MacCyrillic', cp10007 = 'MacCyrillic',
    macgreek    = 'MacGreek',    cp10006 = 'MacGreek',
    macturkish  = 'MacTurkish',  cp10081 = 'MacTurkish',
    macromanian = 'MacRomanian', cp10010 = 'MacRomanian',
    maciceland  = 'MacIceland',  cp10079 = 'MacIceland',
    maccroatian = 'MacCroatian', cp10082 = 'MacCroatian',
}
ExifTool.charsetName = charsetName

-- list of main tag tables to load in LoadAllTables() (sub-tables are recursed
-- automatically).  Note: They will appear in this order in the documentation
-- unless tweaked in BuildTagLookup::GetTableOrder().
-- (the entries are upstream's own, with '::' spelled '.' -- the port's table
--  names are 'lexiftool.BMP.OS2' where upstream has 'Image::ExifTool::BMP::OS2')
local loadAllTables = {
    'PhotoMechanic', 'Exif', 'GeoTiff', 'CanonRaw', 'KyoceraRaw', 'Lytro', 'MinoltaRaw', 'PanasonicRaw',
    'SigmaRaw', 'JPEG', 'GIMP', 'Jpeg2000', 'GIF', 'BMP', 'BMP.OS2', 'BMP.Extra', 'BPG', 'BPG.Extensions',
    'WPG', 'ICO', 'PICT', 'PNG', 'MNG', 'FLIF', 'DjVu', 'DPX', 'OpenEXR', 'ZISRAW', 'MRC', 'LIF', 'MRC.FEI12', 'MIFF',
    'PCX', 'PGF', 'PSP', 'PhotoCD', 'Radiance', 'Other.PFM', 'PDF', 'PostScript', 'Photoshop.Header',
    'Photoshop.Layers', 'Photoshop.ImageData', 'FujiFilm.RAFHeader', 'FujiFilm.RAF',
    'FujiFilm.IFD', 'FujiFilm.MRAW', 'Samsung.Trailer', 'Sony.SRF2', 'Sony.SR2SubIFD',
    'Sony.PMP', 'ITC', 'ID3', 'ID3.Lyrics3', 'FLAC', 'AAC', 'Ogg', 'Vorbis', 'DSF', 'WavPack', 'APE',
    'APE.NewHeader', 'APE.OldHeader', 'Audible', 'MPC', 'MPEG.Audio', 'MPEG.Video', 'MPEG.Xing',
    -- ('QuickTime.Stream' upstream: QuickTimeStream.pl is a separate FILE but
    --  the same PACKAGE there, while this port makes it a separate module --
    --  so the head is named for the module that actually holds it.
    --  'QuickTime.ImageFile' lives in the same upstream file and is not
    --  ported yet, so it stays spelled as upstream has it)
    'M2TS', 'QuickTime', 'QuickTime.ImageFile', 'QuickTimeStream.Stream', 'QuickTimeStream.Tags360Fly',
    'Matroska', 'Matroska.StdTag', 'MOI', 'MXF', 'DV', 'Flash', 'Flash.FLV', 'Real.Media',
    'Real.Audio', 'Real.Metafile', 'Red', 'RIFF', 'AIFF', 'ASF', 'TNEF', 'WTV', 'DICOM', 'Garmin.FIT',
    'FITS', 'XISF', 'MIE', 'JSON', 'HTML', 'XMP.SVG', 'Palm', 'Palm.MOBI', 'Palm.EXTH', 'Torrent', 'EXE',
    'EXE.PEVersion', 'EXE.PEString', 'EXE.DebugRSDS', 'EXE.DebugNB10', 'EXE.Misc',
    'EXE.MachO', 'EXE.PEF', 'EXE.ELF', 'EXE.AR', 'EXE.CHM', 'LNK', 'LNK.INI', 'PCAP', 'Font', 'VCard',
    'Text', 'VCard.VCalendar', 'VCard.VNote', 'RSRC', 'Rawzor', 'ZIP', 'ZIP.GZIP', 'ZIP.RAR',
    'ZIP.RAR5', 'RTF', 'OOXML', 'iWork', 'ISO', 'FLIR.AFF', 'FLIR.FPF', 'MacOS', 'MacOS.MDItem',
    'FlashPix.DocTable',
}
-- (upstream @loadAllTables is a package variable read by Writer.pl's
--  LoadAllTables, so publish it here the same way)
ExifTool.loadAllTables = loadAllTables

-- alphabetical list of current Lang modules
-- (upstream @langs/$defaultLang are package variables read by
--  TagInfoXML.pm's LoadLangModules and Write, so publish them the same way.
--  The list is upstream's -- it names the Lang modules that exist upstream,
--  not the ones this port has ported; LoadLangModules warns about the rest,
--  exactly as upstream would with a missing module)
ExifTool.langs = { 'cs', 'de', 'en', 'en_ca', 'en_gb', 'es', 'fi', 'fr', 'it', 'ja', 'ko', 'nl', 'pl', 'ru', 'sk', 'sv', 'tr', 'zh_cn', 'zh_tw' }

ExifTool.defaultLang = 'en'    -- default language

-- language names
-- (upstream package variable %langName, read by TagInfoXML.pm's
--  WriteLangModule -- published the same way as @langs)
ExifTool.langName = {
    cs = 'Czech (Čeština)',
    de = 'German (Deutsch)',
    en = 'English',
    en_ca = 'Canadian English',
    en_gb = 'British English',
    es = 'Spanish (Español)',
    fi = 'Finnish (Suomi)',
    fr = 'French (Français)',
    it = 'Italian (Italiano)',
    ja = 'Japanese (日本語)',
    ko = 'Korean (한국어)',
    nl = 'Dutch (Nederlands)',
    pl = 'Polish (Polski)',
    ru = 'Russian (Русский)',
    sk = 'Slovak (Slovenčina)',
    sv = 'Swedish (Svenska)',
   ['tr']= 'Turkish (Türkçe)',
    zh_cn = 'Simplified Chinese (简体中文)',
    zh_tw = 'Traditional Chinese (繁體中文)',
}

-- file type lookup for all recognized file extensions (upper case)
-- (if extension may be more than one type, the type is a list where
--  the writable type should come first if it exists)
-- (a value that is a plain string is an alias pointing at another key,
--  resolved recursively, as in upstream; otherwise it's {Type, Desc}, where
--  Type is a string or, for extensions with more than one type, a list)
local fileTypeLookup = {
    ['360']     = {'MOV',     'GoPro 360 video'},
    ['3FR']     = {'TIFF',    'Hasselblad RAW format'},
    ['3G2']     = {'MOV',     '3rd Gen. Partnership Project 2 audio/video'},
    ['3GP']     = {'MOV',     '3rd Gen. Partnership Project audio/video'},
    ['3GP2']    = '3G2',
    ['3GPP']    = '3GP',
    ['7Z']      = {'7Z',      '7z archive'},
    A           = {'EXE',     'Static library'},
    AA          = {'AA',      'Audible Audiobook'},
    AAC         = {'AAC',     'Advanced Audio Coding'},
    AAE         = {'PLIST',   'Apple edit information'},
    AAX         = {'MOV',     'Audible Enhanced Audiobook'},
    ACR         = {'DICOM',   'American College of Radiology ACR-NEMA'},
    ACFM        = {'Font',    'Adobe Composite Font Metrics'},
    AFM         = {'Font',    'Adobe Font Metrics'},
    AMFM        = {'Font',    'Adobe Multiple Master Font Metrics'},
    AI          = {{'PDF', 'PS'}, 'Adobe Illustrator'},
    AIF         = 'AIFF',
    AIFC        = {'AIFF',    'Audio Interchange File Format Compressed'},
    AIFF        = {'AIFF',    'Audio Interchange File Format'},
    AIT         = 'AI',
    ALIAS       = {'ALIAS',   'MacOS file alias'},
    APE         = {'APE',     'Monkey\'s Audio format'},
    APNG        = {'PNG',     'Animated Portable Network Graphics'},
    ARW         = {'TIFF',    'Sony Alpha RAW format'},
    ARQ         = {'TIFF',    'Sony Alpha Pixel-Shift RAW format'},
    ASF         = {'ASF',     'Microsoft Advanced Systems Format'},
    AVC         = {'AVC',     'Advanced Video Connection'},
    AVI         = {'RIFF',    'Audio Video Interleaved'},
    AVIF        = {'MOV',     'AV1 Image File Format'},
    AZW         = 'MOBI',
    AZW3        = 'MOBI',
    BMP         = {'BMP',     'Windows Bitmap'},
    BPG         = {'BPG',     'Better Portable Graphics'},
    BTF         = {'BTF',     'Big Tagged Image File Format'},
    BZ2         = {'BZ2',     'BZIP2 archive'},
    CAP         = 'PCAP',
    C2PA        = {'JUMBF',   'Coalition for Content Provenance and Authenticity'},
    CHM         = {'CHM',     'Microsoft Compiled HTML format'},
    CIFF        = {'CRW',     'Camera Image File Format'},
    COS         = {'COS',     'Capture One Settings'},
    CR2         = {'TIFF',    'Canon RAW 2 format'},
    CR3         = {'MOV',     'Canon RAW 3 format'},
    CRM         = {'MOV',     'Canon RAW Movie'},
    CRW         = {'CRW',     'Canon RAW format'},
    CS1         = {'PSD',     'Sinar CaptureShop 1-Shot RAW'},
    CSV         = {'TXT',     'Comma-Separated Values'},
    CUR         = {'ICO',     'Windows Cursor'},
    CZI         = {'CZI',     'Zeiss Integrated Software RAW'},
    DC3         = 'DICM',
    DCM         = 'DICM',
    DCP         = {'TIFF',    'DNG Camera Profile'},
    DCR         = {'TIFF',    'Kodak Digital Camera RAW'},
    DCX         = {'DCX',     'Multi-page PC Paintbrush'},
    DEX         = {'DEX',     'Dalvik Executable format'},
    DFONT       = {'Font',    'Macintosh Data fork Font'},
    DIB         = {'BMP',     'Device Independent Bitmap'},
    DIC         = 'DICM',
    DICM        = {'DICOM',   'Digital Imaging and Communications in Medicine'},
    DIR         = {'DIR',     'Directory'},
    DIVX        = {'ASF',     'DivX media format'},
    DJV         = 'DJVU',
    DJVU        = {'AIFF',    'DjVu image'},
    DLL         = {'EXE',     'Windows Dynamic Link Library'},
    DNG         = {'TIFF',    'Digital Negative'},
    DOC         = {'FPX',     'Microsoft Word Document'},
    DOCM        = {{'ZIP', 'FPX'}, 'Office Open XML Document Macro-enabled'},
    DOCX        = {{'ZIP', 'FPX'}, 'Office Open XML Document'},
    DOT         = {'FPX',     'Microsoft Word Template'},
    DOTM        = {{'ZIP', 'FPX'}, 'Office Open XML Document Template Macro-enabled'},
    DOTX        = {{'ZIP', 'FPX'}, 'Office Open XML Document Template'},
    DPX         = {'DPX',     'Digital Picture Exchange'},
    DR4         = {'DR4',     'Canon VRD version 4 Recipe'},
    DS2         = {'DSS',     'Digital Speech Standard 2'},
    DSF         = {'DSF',     'DSF Stream File'},
    DSS         = {'DSS',     'Digital Speech Standard'},
    DV          = {'DV',      'Digital Video'},
    DVB         = {'MOV',     'Digital Video Broadcasting'},
    ['DVR-MS']  = {'ASF',     'Microsoft Digital Video recording'},
    DWF         = {'DWF',     'Autodesk drawing (Design Web Format)'},
    DWG         = {'DWG',     'AutoCAD Drawing'},
    DYLIB       = {'EXE',     'Mach-O Dynamic Link Library'},
    DXF         = {'DXF',     'AutoCAD Drawing Exchange Format'},
    EIP         = {'ZIP',     'Capture One Enhanced Image Package'},
    EPS         = {'EPS',     'Encapsulated PostScript Format'},
    EPS2        = 'EPS',
    EPS3        = 'EPS',
    EPSF        = 'EPS',
    EPUB        = {'ZIP',     'Electronic Publication'},
    ERF         = {'TIFF',    'Epson Raw Format'},
    EXE         = {'EXE',     'Windows executable file'},
    EXR         = {'EXR',     'Open EXR'},
    EXIF        = {'EXIF',    'Exchangable Image File Metadata'},
    EXV         = {'EXV',     'Exiv2 metadata'},
    F4A         = {'MOV',     'Adobe Flash Player 9+ Audio'},
    F4B         = {'MOV',     'Adobe Flash Player 9+ audio Book'},
    F4P         = {'MOV',     'Adobe Flash Player 9+ Protected'},
    F4V         = {'MOV',     'Adobe Flash Player 9+ Video'},
    FFF         = {{'TIFF', 'FLIR'}, 'Hasselblad Flexible File Format'},
    FIT         = {'FIT',     'Garmin Flexible and Interoperable data Transfer'},
    FITS        = {'FITS',    'Flexible Image Transport System'},
    FLAC        = {'FLAC',    'Free Lossless Audio Codec'},
    FLA         = {'FPX',     'Macromedia/Adobe Flash project'},
    FLIF        = {'FLIF',    'Free Lossless Image Format'},
    FLIR        = {'FLIR',    'FLIR File Format'},
    FLV         = {'FLV',     'Flash Video'},
    FPF         = {'FPF',     'FLIR Public image Format'},
    FPX         = {'FPX',     'FlashPix'},
    GIF         = {'GIF',     'Compuserve Graphics Interchange Format'},
    GLV         = {'MOV',     'Garmin Low-resolution Video'},
    GPR         = {'TIFF',    'General Purpose RAW'},
    GZ          = 'GZIP',
    GZIP        = {'GZIP',    'GNU ZIP compressed archive'},
    HDP         = {'TIFF',    'Windows HD Photo'},
    HDR         = {'HDR',     'Radiance RGBE High Dynamic Range'},
    HEIC        = {'MOV',     'High Efficiency Image Format still image'},
    HEIF        = {'MOV',     'High Efficiency Image Format'},
    HIF         = 'HEIF',
    HTM         = 'HTML',
    HTML        = {'HTML',    'HyperText Markup Language'},
    ICAL        = 'ICS',
    ICC         = {'ICC',     'International Color Consortium'},
    ICM         = 'ICC',
    ICO         = {'ICO',     'Windows Icon'},
    ICS         = {'VCard',   'iCalendar Schedule'},
    IDML        = {'ZIP',     'Adobe InDesign Markup Language'},
    IIQ         = {'TIFF',    'Phase One Intelligent Image Quality RAW'},
    IND         = {'IND',     'Adobe InDesign'},
    INDD        = {'IND',     'Adobe InDesign Document'},
    INDT        = {'IND',     'Adobe InDesign Template'},
    INSV        = {'MOV',     'Insta360 Video'},
    INSP        = {'JPEG',    'Insta360 Picture'},
    INX         = {'XMP',     'Adobe InDesign Interchange'},
    ISO         = {'ISO',     'ISO 9660 disk image'},
    ITC         = {'ITC',     'iTunes Cover Flow'},
    J2C         = {'JP2',     'JPEG 2000 codestream'},
    J2K         = 'J2C',
    JNG         = {'PNG',     'JPG Network Graphics'},
    JP2         = {'JP2',     'JPEG 2000 file'},
    JPC         = 'J2C',
    JPE         = 'JPEG',
    JPEG        = {'JPEG',    'Joint Photographic Experts Group'},
    JPH         = {'JP2',     'High-throughput JPEG 2000'},
    JPF         = 'JP2',
    JPG         = 'JPEG',
    JPM         = {'JP2',     'JPEG 2000 compound image'},
    JPS         = {'JPEG',    'JPEG Stereo image'},
    JPX         = {'JP2',     'JPEG 2000 with extensions'},
    JSON        = {'JSON',    'JavaScript Object Notation'},
    JUMBF       = {'JUMBF',   'JPEG Universal Metadata Box Format'},
    JXL         = {'JXL',     'JPEG XL'},
    JXR         = {'TIFF',    'JPEG XR'},
    K25         = {'TIFF',    'Kodak DC25 RAW'},
    KDC         = {'TIFF',    'Kodak Digital Camera RAW'},
    KEY         = {'ZIP',     'Apple Keynote presentation'},
    KTH         = {'ZIP',     'Apple Keynote Theme'},
    KVAR        = {'KVAR',    'Kandao Video Asset Resource'},
    LA          = {'RIFF',    'Lossless Audio'},
    LFP         = {'LFP',     'Lytro Light Field Picture'},
    LFR         = 'LFP',
    LIF         = {'LIF',     'Leica Image File'},
    LNK         = {'LNK',     'Windows shortcut'},
    LRF         = {'MOV',     'Low-Resolution video File'},
    LRI         = {'LRI',     'Light RAW'},
    LRV         = {'MOV',     'Low-Resolution Video'},
    M2T         = 'M2TS',
    M2TS        = {'M2TS',    'MPEG-2 Transport Stream'},
    M2V         = {'MPEG',    'MPEG-2 Video'},
    M4A         = {'MOV',     'MPEG-4 Audio'},
    M4B         = {'MOV',     'MPEG-4 audio Book'},
    M4P         = {'MOV',     'MPEG-4 Protected'},
    M4V         = {'MOV',     'MPEG-4 Video'},
    MACOS       = {'MacOS',   'MacOS ._ sidecar file'},
    MAX         = {'FPX',     '3D Studio MAX'},
    MEF         = {'TIFF',    'Mamiya (RAW) Electronic Format'},
    MIE         = {'MIE',     'Meta Information Encapsulation format'},
    MIF         = 'MIFF',
    MIFF        = {'MIFF',    'Magick Image File Format'},
    MKA         = {'MKV',     'Matroska Audio'},
    MKS         = {'MKV',     'Matroska Subtitle'},
    MKV         = {'MKV',     'Matroska Video'},
    MNG         = {'PNG',     'Multiple-image Network Graphics'},
    MOBI        = {'PDB',     'Mobipocket electronic book'},
    MODD        = {'PLIST',   'Sony Picture Motion metadata'},
    MOI         = {'MOI',     'MOD Information file'},
    MOS         = {'TIFF',    'Creo Leaf Mosaic'},
    MOV         = {'MOV',     'Apple QuickTime movie'},
    MP3         = {'MP3',     'MPEG-1 Layer 3 audio'},
    MP4         = {'MOV',     'MPEG-4 video'},
    MPC         = {'MPC',     'Musepack Audio'},
    MPEG        = {'MPEG',    'MPEG-1 or MPEG-2 audio/video'},
    MPG         = 'MPEG',
    MPO         = {'JPEG',    'Extended Multi-Picture format'},
    MQV         = {'MOV',     'Sony Mobile Quicktime Video'},
    MRC         = {'MRC',     'Medical Research Council image'},
    MRW         = {'MRW',     'Minolta RAW format'},
    MTS         = 'M2TS',
    MXF         = {'MXF',     'Material Exchange Format'},
    NEF         = {'TIFF',    'Nikon (RAW) Electronic Format'},
    NEWER       = 'COS',
    NKA         = {'NKA',     'Nikon NX Studio Adjustments'},
    NKSC        = {'XMP',     'Nikon Sidecar'},
    NMBTEMPLATE = {'ZIP',     'Apple Numbers Template'},
    NRW         = {'TIFF',    'Nikon RAW (2)'},
    NUMBERS     = {'ZIP',     'Apple Numbers spreadsheet'},
    NXD         = {'XMP',     'Nikon NX-D Settings'},
    O           = {'EXE',     'Relocatable Object'},
    ODB         = {'ZIP',     'Open Document Database'},
    ODC         = {'ZIP',     'Open Document Chart'},
    ODF         = {'ZIP',     'Open Document Formula'},
    ODG         = {'ZIP',     'Open Document Graphics'},
    ODI         = {'ZIP',     'Open Document Image'},
    ODP         = {'ZIP',     'Open Document Presentation'},
    ODS         = {'ZIP',     'Open Document Spreadsheet'},
    ODT         = {'ZIP',     'Open Document Text file'},
    OFR         = {'RIFF',    'OptimFROG audio'},
    OGG         = {'OGG',     'Ogg Vorbis audio file'},
    OGV         = {'OGG',     'Ogg Video file'},
    ONP         = {'JSON',    'ON1 Presets'},
    OPUS        = {'OGG',     'Ogg Opus audio file'},
    ORF         = {'ORF',     'Olympus RAW format'},
    ORI         = 'ORF',
    OTF         = {'Font',    'Open Type Font'},
    PAC         = {'RIFF',    'Lossless Predictive Audio Compression'},
    PAGES       = {'ZIP',     'Apple Pages document'},
    PBM         = {'PPM',     'Portable BitMap'},
    PCAP        = {'PCAP',    'Packet Capture'},
    PCAPNG      = {'PCAP',    'Packet Capture Next Generation'},
    PCD         = {'PCD',     'Kodak Photo CD Image Pac'},
    PCT         = 'PICT',
    PCX         = {'PCX',     'PC Paintbrush'},
    PDB         = {'PDB',     'Palm Database'},
    PDF         = {'PDF',     'Adobe Portable Document Format'},
    PEF         = {'TIFF',    'Pentax (RAW) Electronic Format'},
    PFA         = {'Font',    'PostScript Font ASCII'},
    PFB         = {'Font',    'PostScript Font Binary'},
    PFM         = {{'Font', 'PFM2'}, 'Printer Font Metrics'},
    PGF         = {'PGF',     'Progressive Graphics File'},
    PGM         = {'PPM',     'Portable Gray Map'},
    PHP         = {'PHP',     'PHP Hypertext Preprocessor'},
    PHP3        = 'PHP',
    PHP4        = 'PHP',
    PHP5        = 'PHP',
    PHPS        = 'PHP',
    PHTML       = 'PHP',
    PICT        = {'PICT',    'Apple PICTure'},
    PLIST       = {'PLIST',   'Apple Property List'},
    PMP         = {'PMP',     'Sony DSC-F1 Cyber-Shot PMP'},
    PNG         = {'PNG',     'Portable Network Graphics'},
    POT         = {'FPX',     'Microsoft PowerPoint Template'},
    POTM        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Template Macro-enabled'},
    POTX        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Template'},
    PPAM        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Addin Macro-enabled'},
    PPAX        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Addin'},
    PPM         = {'PPM',     'Portable Pixel Map'},
    PPS         = {'FPX',     'Microsoft PowerPoint Slideshow'},
    PPSM        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Slideshow Macro-enabled'},
    PPSX        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Slideshow'},
    PPT         = {'FPX',     'Microsoft PowerPoint Presentation'},
    PPTM        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation Macro-enabled'},
    PPTX        = {{'ZIP', 'FPX'}, 'Office Open XML Presentation'},
    PRC         = {'PDB',     'Palm Database'},
    PS          = {'PS',      'PostScript'},
    PS2         = 'PS',
    PS3         = 'PS',
    PSB         = {'PSD',     'Photoshop Large Document'},
    PSD         = {'PSD',     'Photoshop Document'},
    PSDT        = {'PSD',     'Photoshop Document Template'},
    PSP         = {'PSP',     'Paint Shop Pro'},
    PSPFRAME    = 'PSP',
    PSPIMAGE    = 'PSP',
    PSPSHAPE    = 'PSP',
    PSPTUBE     = 'PSP',
    QIF         = 'QTIF',
    QT          = 'MOV',
    QTI         = 'QTIF',
    QTIF        = {'QTIF',    'QuickTime Image File'},
    R3D         = {'R3D',     'Redcode RAW Video'},
    RA          = {'Real',    'Real Audio'},
    RAF         = {'RAF',     'FujiFilm RAW Format'},
    RAM         = {'Real',    'Real Audio Metafile'},
    RAR         = {'RAR',     'RAR Archive'},
    RAW         = {{'RAW', 'TIFF'}, 'Kyocera Contax N Digital RAW or Panasonic RAW'},
    RIF         = 'RIFF',
    RIFF        = {'RIFF',    'Resource Interchange File Format'},
    RM          = {'Real',    'Real Media'},
    RMVB        = {'Real',    'Real Media Variable Bitrate'},
    RPM         = {'Real',    'Real Media Plug-in Metafile'},
    RSRC        = {'RSRC',    'Mac OS Resource'},
    RTF         = {'RTF',     'Rich Text Format'},
    RV          = {'Real',    'Real Video'},
    RW2         = {'TIFF',    'Panasonic RAW 2'},
    RWL         = {'TIFF',    'Leica RAW'},
    RWZ         = {'RWZ',     'Rawzor compressed image'},
    SEQ         = {'FLIR',    'FLIR image Sequence'},
    SKETCH      = {'ZIP',     'Sketch design file'},
    SO          = {'EXE',     'Shared Object file'},
    SR2         = {'TIFF',    'Sony RAW Format 2'},
    SRF         = {'TIFF',    'Sony RAW Format'},
    SRW         = {'TIFF',    'Samsung RAW format'},
    SVG         = {'XMP',     'Scalable Vector Graphics'},
    SWF         = {'SWF',     'Shockwave Flash'},
    TAR         = {'TAR',     'TAR archive'},
    THM         = {'JPEG',    'Thumbnail'},
    THMX        = {{'ZIP', 'FPX'}, 'Office Open XML Theme'},
    TIF         = 'TIFF',
    TIFF        = {'TIFF',    'Tagged Image File Format'},
    TNEF        = {'TNEF',    'Transport Neural Encapsulation Format'},
    TORRENT     = {'Torrent', 'BitTorrent description file'},
    TS          = 'M2TS',
    TTC         = {'Font',    'True Type Font Collection'},
    TTF         = {'Font',    'True Type Font'},
    TUB         = 'PSP',
    TXT         = {'TXT',     'Text file'},
    URL         = {'LNK',     'Windows shortcut URL'},
    VCARD       = {'VCard',   'Virtual Card'},
    VCF         = 'VCARD',
    VOB         = {'MPEG',    'Video Object'},
    VNT         = {{'FPX', 'VCard'}, 'Scene7 Vignette or V-Note text file'},
    VRD         = {'VRD',     'Canon VRD Recipe Data'},
    VSD         = {'FPX',     'Microsoft Visio Drawing'},
    WAV         = {'RIFF',    'WAVeform (Windows digital audio)'},
    WDP         = {'TIFF',    'Windows Media Photo'},
    WEBM        = {'MKV',     'Google Web Movie'},
    WEBP        = {'RIFF',    'Google Web Picture'},
    WMA         = {'ASF',     'Windows Media Audio'},
    WMF         = {'WMF',     'Windows Metafile Format'},
    WMV         = {'ASF',     'Windows Media Video'},
    WV          = {'WV',      'WavPack Audio'},
    WVP         = 'WV',
    X3F         = {'X3F',     'Sigma RAW format'},
    XCF         = {'XCF',     'GIMP native image format'},
    XHTML       = {'HTML',    'Extensible HyperText Markup Language'},
    XISF        = {'XISF',    'Extensible Image Serialization Format'},
    XLA         = {'FPX',     'Microsoft Excel Add-in'},
    XLAM        = {{'ZIP', 'FPX'}, 'Office Open XML Spreadsheet Add-in Macro-enabled'},
    XLS         = {'FPX',     'Microsoft Excel Spreadsheet'},
    XLSB        = {{'ZIP', 'FPX'}, 'Office Open XML Spreadsheet Binary'},
    XLSM        = {{'ZIP', 'FPX'}, 'Office Open XML Spreadsheet Macro-enabled'},
    XLSX        = {{'ZIP', 'FPX'}, 'Office Open XML Spreadsheet'},
    XLT         = {'FPX',     'Microsoft Excel Template'},
    XLTM        = {{'ZIP', 'FPX'}, 'Office Open XML Spreadsheet Template Macro-enabled'},
    XLTX        = {{'ZIP', 'FPX'}, 'Office Open XML Spreadsheet Template'},
    XMP         = {'XMP',     'Extensible Metadata Platform'},
    VSDX        = {'ZIP',     'Visio Diagram Document'},
    WOFF        = {'Font',    'Web Open Font Format'},
    WOFF2       = {'Font',    'Web Open Font Format 2'},
    WPG         = {'WPG',     'WordPerfect Graphics'},
    WTV         = {'WTV',     'Windows recorded TV show'},
    ZIP         = {'ZIP',     'ZIP archive'},
}
-- (upstream %fileTypeLookup is a package variable; Validate.pm reads it as
--  $Image::ExifTool::fileTypeLookup{$fileExt}, so publish it here too)
ExifTool.fileTypeLookup = fileTypeLookup

local fileDescription = {
    DICOM = 'Digital Imaging and Communications in Medicine',
    XML   = 'Extensible Markup Language',
    ['Win32 EXE'] = 'Windows 32-bit Executable',
    ['Win32 DLL'] = 'Windows 32-bit Dynamic Link Library',
    ['Win64 EXE'] = 'Windows 64-bit Executable',
    ['Win64 DLL'] = 'Windows 64-bit Dynamic Link Library',
    VNote = 'V-Note document',
}

-- MIME types for applicable file types above
-- (missing entries default to 'application/unknown', but note that other MIME
--  types may be specified by some modules, eg. QuickTime.pm and RIFF.pm)
local mimeType = {
    -- (binary PLIST format is 'application/x-plist', recognized at run time
    -- by ProcessPLIST via SetFileType())
    ['3FR']          = 'image/x-hasselblad-3fr',
    ['7Z']           = 'application/x-7z-compressed',
    AA               = 'audio/audible',
    AAC              = 'audio/aac',
    AAE              = 'application/vnd.apple.photos',
    AI               = 'application/vnd.adobe.illustrator',
    AIFF             = 'audio/x-aiff',
    ALIAS            = 'application/x-macos',
    APE              = 'audio/x-monkeys-audio',
    APNG             = 'image/apng',
    ASF              = 'video/x-ms-asf',
    ARW              = 'image/x-sony-arw',
    BMP              = 'image/bmp',
    BPG              = 'image/bpg',
    BTF              = 'image/x-tiff-big', -- #(NC) (ref http://www.asmail.be/msg0055371937.html)
    BZ2              = 'application/bzip2',
    C2PA             = 'application/c2pa',
    ['Canon 1D RAW'] = 'image/x-raw', -- # (uses .TIF file extension)
    CHM              = 'application/x-chm',
    COS              = 'application/octet-stream', -- #PH (NC)
    CR2              = 'image/x-canon-cr2',
    CR3              = 'image/x-canon-cr3',
    CRM              = 'video/x-canon-crm',
    CRW              = 'image/x-canon-crw',
    CSV              = 'text/csv',
    CUR              = 'image/x-cursor', -- #PH (NC)
    CZI              = 'image/x-zeiss-czi', -- #PH (NC)
    DCP              = 'application/octet-stream', -- #PH (NC)
    DCR              = 'image/x-kodak-dcr',
    DCX              = 'image/dcx',
    DEX              = 'application/octet-stream',
    DFONT            = 'application/x-dfont',
    DICOM            = 'application/dicom',
    DIVX             = 'video/divx',
    DJVU             = 'image/vnd.djvu',
    DNG              = 'image/x-adobe-dng',
    DOC              = 'application/msword',
    DOCM             = 'application/vnd.ms-word.document.macroEnabled.12',
    DOCX             = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    DOT              = 'application/msword',
    DOTM             = 'application/vnd.ms-word.template.macroEnabledTemplate',
    DOTX             = 'application/vnd.openxmlformats-officedocument.wordprocessingml.template',
    DPX              = 'image/x-dpx',
    DR4              = 'application/octet-stream', -- #PH (NC)
    DS2              = 'audio/x-ds2',
    DSF              = 'audio/x-dsf',
    DSS              = 'audio/x-dss',
    DV               = 'video/x-dv',
    ['DVR-MS']       = 'video/x-ms-dvr',
    DWF              = 'model/vnd.dwf',
    DWG              = 'image/vnd.dwg',
    DXF              = 'application/dxf',
    EIP              = 'application/x-captureone', -- #(NC)
    EPS              = 'application/postscript',
    ERF              = 'image/x-epson-erf',
    EXE              = 'application/octet-stream',
    EXR              = 'image/x-exr',
    EXV              = 'image/x-exv',
    FFF              = 'image/x-hasselblad-fff',
    FIT              = 'application/fit',
    FITS             = 'image/fits',
    FLA              = 'application/vnd.adobe.fla',
    FLAC             = 'audio/flac',
    FLIF             = 'image/flif',
    FLIR             = 'image/x-flir-fff', -- #PH (NC)
    FLV              = 'video/x-flv',
    Font             = 'application/x-font-type1', -- # covers PFA, PFB and PFM (not sure about PFM)
    FPF              = 'image/x-flir-fpf', -- #PH (NC)
    FPX              = 'image/vnd.fpx',
    GIF              = 'image/gif',
    GPR              = 'image/x-gopro-gpr',
    GZIP             = 'application/x-gzip',
    HDP              = 'image/vnd.ms-photo',
    HDR              = 'image/vnd.radiance',
    HTML             = 'text/html',
    ICC              = 'application/vnd.iccprofile',
    ICO              = 'image/x-icon', -- #PH (NC)
    ICS              = 'text/calendar',
    IDML             = 'application/vnd.adobe.indesign-idml-package',
    IIQ              = 'image/x-raw',
    IND              = 'application/x-indesign',
    INX              = 'application/x-indesign-interchange', -- #PH (NC)
    ISO              = 'application/x-iso9660-image',
    ITC              = 'application/itunes',
    J2C              = 'image/x-j2c', -- #PH (NC)
    JNG              = 'image/jng',
    JP2              = 'image/jp2',
    JPEG             = 'image/jpeg',
    JPH              = 'image/jph',
    JPM              = 'image/jpm',
    JPS              = 'image/x-jps',
    JPX              = 'image/jpx',
    JSON             = 'application/json',
    JUMBF            = 'application/octet-stream', -- #PH (invented format)
    JXL              = 'image/jxl', -- #PH (NC)
    JXR              = 'image/jxr',
    K25              = 'image/x-kodak-k25',
    KDC              = 'image/x-kodak-kdc',
    KEY              = 'application/x-iwork-keynote-sffkey',
    LFP              = 'image/x-lytro-lfp', -- #PH (NC)
    LIF              = 'image/x-lif',
    LNK              = 'application/octet-stream',
    LRI              = 'image/x-light-lri',
    M2T              = 'video/mpeg',
    M2TS             = 'video/m2ts',
    MAX              = 'application/x-3ds',
    MEF              = 'image/x-mamiya-mef',
    MIE              = 'application/x-mie',
    MIFF             = 'application/x-magick-image',
    MKA              = 'audio/x-matroska',
    MKS              = 'application/x-matroska',
    MKV              = 'video/x-matroska',
    MNG              = 'video/mng',
    MOBI             = 'application/x-mobipocket-ebook',
    MOI              = 'application/octet-stream', -- #PH (NC)
    MOS              = 'image/x-raw',
    MOV              = 'video/quicktime',
    MP3              = 'audio/mpeg',
    MP4              = 'video/mp4',
    MPC              = 'audio/x-musepack',
    MPEG             = 'video/mpeg',
    MRC              = 'image/x-mrc',
    MRW              = 'image/x-minolta-mrw',
    MXF              = 'application/mxf',
    NEF              = 'image/x-nikon-nef',
    NKSC             = 'application/x-nikon-nxstudio',
    NRW              = 'image/x-nikon-nrw',
    NUMBERS          = 'application/x-iwork-numbers-sffnumbers',
    ODB              = 'application/vnd.oasis.opendocument.database',
    ODC              = 'application/vnd.oasis.opendocument.chart',
    ODF              = 'application/vnd.oasis.opendocument.formula',
    ODG              = 'application/vnd.oasis.opendocument.graphics',
    ODI              = 'application/vnd.oasis.opendocument.image',
    ODP              = 'application/vnd.oasis.opendocument.presentation',
    ODS              = 'application/vnd.oasis.opendocument.spreadsheet',
    ODT              = 'application/vnd.oasis.opendocument.text',
    OGG              = 'audio/ogg',
    OGV              = 'video/ogg',
    ONP              = 'application/on1',
    ORF              = 'image/x-olympus-orf',
    OTF              = 'application/font-otf',
    PAGES            = 'application/x-iwork-pages-sffpages',
    PBM              = 'image/x-portable-bitmap',
    PCAP             = 'application/vnd.tcpdump.pcap',
    PCD              = 'image/x-photo-cd',
    PCX              = 'image/pcx',
    PDB              = 'application/vnd.palm',
    PDF              = 'application/pdf',
    PEF              = 'image/x-pentax-pef',
    PFA              = 'application/x-font-type1', -- # (needed if handled by PostScript module)
    PGF              = 'image/pgf',
    PGM              = 'image/x-portable-graymap',
    PHP              = 'application/x-httpd-php',
    PICT             = 'image/pict',
    PLIST            = 'application/xml', -- # (binary PLIST format is 'application/x-plist', recognized at run time)
    PMP              = 'image/x-sony-pmp', -- #PH (NC)
    PNG              = 'image/png',
    POT              = 'application/vnd.ms-powerpoint',
    POTM             = 'application/vnd.ms-powerpoint.template.macroEnabled.12',
    POTX             = 'application/vnd.openxmlformats-officedocument.presentationml.template',
    PPAM             = 'application/vnd.ms-powerpoint.addin.macroEnabled.12',
    PPAX             = 'application/vnd.openxmlformats-officedocument.presentationml.addin', -- # (NC, PH invented)
    PPM              = 'image/x-portable-pixmap',
    PPS              = 'application/vnd.ms-powerpoint',
    PPSM             = 'application/vnd.ms-powerpoint.slideshow.macroEnabled.12',
    PPSX             = 'application/vnd.openxmlformats-officedocument.presentationml.slideshow',
    PPT              = 'application/vnd.ms-powerpoint',
    PPTM             = 'application/vnd.ms-powerpoint.presentation.macroEnabled.12',
    PPTX             = 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    PS               = 'application/postscript',
    PSD              = 'application/vnd.adobe.photoshop',
    PSP              = 'image/x-paintshoppro', -- #(NC)
    QTIF             = 'image/x-quicktime',
    R3D              = 'video/x-red-r3d', -- #PH (invented)
    RA               = 'audio/x-pn-realaudio',
    RAF              = 'image/x-fujifilm-raf',
    RAM              = 'audio/x-pn-realaudio',
    RAR              = 'application/x-rar-compressed',
    RAW              = 'image/x-raw',
    RM               = 'application/vnd.rn-realmedia',
    RMVB             = 'application/vnd.rn-realmedia-vbr',
    RPM              = 'audio/x-pn-realaudio-plugin',
    RSRC             = 'application/ResEdit',
    RTF              = 'text/rtf',
    RV               = 'video/vnd.rn-realvideo',
    RW2              = 'image/x-panasonic-rw2',
    RWL              = 'image/x-leica-rwl',
    RWZ              = 'image/x-rawzor', -- #(duplicated in Rawzor.pm)
    SEQ              = 'image/x-flir-seq', -- #PH (NC)
    SKETCH           = 'application/sketch',
    SR2              = 'image/x-sony-sr2',
    SRF              = 'image/x-sony-srf',
    SRW              = 'image/x-samsung-srw',
    SVG              = 'image/svg+xml',
    SWF              = 'application/x-shockwave-flash',
    TAR              = 'application/x-tar',
    THMX             = 'application/vnd.ms-officetheme',
    TIFF             = 'image/tiff',
    TNEF             = 'application/vnd.ms-tnef',
    Torrent          = 'application/x-bittorrent',
    TTC              = 'application/font-ttf',
    TTF              = 'application/font-ttf',
    TXT              = 'text/plain',
    VCard            = 'text/vcard',
    VRD              = 'application/octet-stream', -- #PH (NC)
    VSD              = 'application/x-visio',
    VSDX             = 'application/vnd.ms-visio.drawing',
    WDP              = 'image/vnd.ms-photo',
    WEBM             = 'video/webm',
    WMA              = 'audio/x-ms-wma',
    WMF              = 'application/x-wmf',
    WMV              = 'video/x-ms-wmv',
    WPG              = 'image/x-wpg',
    WTV              = 'video/x-ms-wtv',
    WV               = 'audio/x-wavpack',
    X3F              = 'image/x-sigma-x3f',
    XCF              = 'image/x-xcf',
    XISF             = 'image/x-xisf',
    XLA              = 'application/vnd.ms-excel',
    XLAM             = 'application/vnd.ms-excel.addin.macroEnabled.12',
    XLS              = 'application/vnd.ms-excel',
    XLSB             = 'application/vnd.ms-excel.sheet.binary.macroEnabled.12',
    XLSM             = 'application/vnd.ms-excel.sheet.macroEnabled.12',
    XLSX             = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    XLT              = 'application/vnd.ms-excel',
    XLTM             = 'application/vnd.ms-excel.template.macroEnabled.12',
    XLTX             = 'application/vnd.openxmlformats-officedocument.spreadsheetml.template',
    XML              = 'application/xml',
    XMP              = 'application/rdf+xml',
    ZIP              = 'application/zip',
}

-- (upstream's %Image::ExifTool::mimeType is a package variable that other
--  modules read -- OOXML.pm builds its MIME-to-file-type reverse lookup from
--  it -- so it is exported here under the same name)
ExifTool.mimeType = mimeType

-- typical extension for each file type (if different than FileType)
-- - case is not significant
local fileTypeExt = {
    ['Canon 1D RAW'] = 'tif',
    DICOM            = 'dcm',
    FLIR             = 'fff',
    GZIP             = 'gz',
    JPEG             = 'jpg',
    M2TS             = 'mts',
    MPEG             = 'mpg',
    TIFF             = 'tif',
    VCard            = 'vcf',
}

--------------------------------------------------------------------------------
-- Get list of shortcuts
-- Returns: Shortcut list (sorted alphabetically)
function ExifTool.GetShortcuts()
    local Shortcuts = require('lexiftool.Shortcuts')
    local list = {}
    for k in pairs(Shortcuts.Main) do list[#list + 1] = k end
    tsort(list)
    return list
end

--------------------------------------------------------------------------------
-- Get file type for specified extension
-- Inputs: 0) file name or extension (case is not significant),
--            or FileType value if a description is requested
--         1) flag to return long description instead of type ('0' to return any recognized type)
-- Returns: File type (or desc) or undef if extension not supported or if
--          description is the same as the input FileType.  In list context,
--          may return more than one file type if the file may be different formats.
--          Returns list of all supported extensions if no file specified
--
-- Get file type by name (upstream GetFileType; subset returns the single
-- supported type for a file name, or a list of extensions when no file is
-- given: all supported ones, or all recognized ones when desc is '0'). The
-- description-returning form of the second argument is not ported.
function ExifTool.GetFileType(file, desc)
    if file == nil then
        local exts = {}
        for ext in pairs(fileTypeLookup) do
            if desc ~= nil and perl.str(desc) == '0' then
                -- return all recognized types
                exts[#exts + 1] = ext
            else
                -- return all supported types
                local module = moduleName[ext]
                if module == nil then
                    local t = fileTypeLookup[ext]
                    module = moduleName[type(t) == 'string' and t or nil]
                end
                if module ~= 0 then exts[#exts + 1] = ext end
            end
        end
        tsort(exts)
        return exts
    end
    local subType
    local fileExt = ExifTool.GetFileExtension(file)
    if not fileExt then
        if perl.isMatch(file, [[ \((.*)\)$]]) then
            subType = perl.matches(file, [[ \((.*)\)$]])
            file = perl.subst(file, [[ \((.*)\)$]], '')
            fileExt = ExifTool.GetFileExtension(file)
        end
        if not fileExt then fileExt = uc(file) end
    end
    -- follow alias chain (string values point at another key) to the entry
    local entry = fileExt and fileTypeLookup[fileExt]
    while type(entry) == 'string' do
        entry = fileTypeLookup[entry]
    end
    -- return description if specified
    -- (allow input $file to be a FileType for this purpose)
    if perlTruthy(desc) then
        local override = ExifTool.static_vars.OverrideFileDescription
        if entry then
            if override and override[fileExt] then
                desc = override[fileExt]
            else
                desc = entry[2]
            end
        else
            desc = fileDescription[file] or file
        end
        if perlTruthy(subType) then desc = desc .. ', ' .. subType end
        return desc
    elseif entry and (desc == nil or perl.str(desc) ~= '0') then
        -- return only supported file types
        local mod = type(entry[1]) == 'string' and moduleName[entry[1]] or nil
        if mod ~= nil and mod == 0 then entry = nil end
    end
    if not entry then return nil end
    local fileType = entry[1]      -- get file type (or list of types)
    -- (port: this is the scalar-context result; GetFileTypeList below is
    --  the list one)
    if type(fileType) == 'table' then fileType = fileExt end
    return fileType
end

--------------------------------------------------------------------------------
-- The same lookup as GetFileType, but in Perl's list context: an extension
-- that may be more than one type (PFM is a Font or a Portable FloatMap) yields
-- them all, in order.  Upstream is one function used both ways
-- (`$fileType = GetFileType($infile)` vs `@fileTypeList = GetFileType($infile)`).
--------------------------------------------------------------------------------
function ExifTool.GetFileTypeList(file)
    local fileExt = ExifTool.GetFileExtension(file)
    if not fileExt then fileExt = uc(file) end
    local entry = fileExt and fileTypeLookup[fileExt]
    while type(entry) == 'string' do
        entry = fileTypeLookup[entry]
    end
    if entry then
        -- return only supported file types
        local mod = type(entry[1]) == 'string' and moduleName[entry[1]] or nil
        if mod ~= nil and mod == 0 then entry = nil end
    end
    if not entry then return { } end
    local fileType = entry[1]
    if type(fileType) == 'table' then return { table.unpack(fileType) } end
    return { fileType }
end

--------------------------------------------------------------------------------
-- Return true if we can write the specified file type
-- Inputs: 0) file name or ext
-- Returns: true if writable, 0 if not writable, '' if not writable due to extension,
--          undef if unrecognized
function ExifTool.CanWrite(file)
    if not perlTruthy(file) then return nil end
    local type_ = ExifTool.GetFileTypeList(file)[1]
    if not type_ then return nil end
    if noWriteFile[type_] then
        -- can't write TIFF files with certain extensions (various RAW formats)
        local ext = ExifTool.GetFileExtension(file) or perl.uc(file)
        if perlTruthy(ext) then
            for _, e in ipairs(noWriteFile[type_]) do
                if e == ext then return '' end
            end
            return 1
        end
    end
    if onlyWriteFile[type_] then
        local ext = ExifTool.GetFileExtension(file) or perl.uc(file)
        if perlTruthy(ext) then
            for _, e in ipairs(onlyWriteFile[type_]) do
                if e == ext then return 1 end
            end
            return 0
        end
    end
    for _, t in ipairs(writeTypes) do
        if t == type_ then return 1 end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Return true if we can create the specified file type
-- Inputs: 0) file name or ext
-- Returns: true if creatable, 0 if not writable, undef if unrecognized
function ExifTool.CanCreate(file)
    if not perlTruthy(file) then return nil end
    local ext = ExifTool.GetFileExtension(file) or perl.uc(file)
    local type_ = ExifTool.GetFileType(file)
    if not type_ then return nil end
    if createTypes[ext] or createTypes[type_] then return 1 end
    return 0
end

--------------------------------------------------------------------------------
-- Escape all elements of a value
-- Inputs: 0) value, 1) escape proc
-- Returns: escaped value
-- (upstream DoEscape, ExifTool.pm:9665, escapes $_[0] in place; a Lua
--  string cannot be changed in place, so the escaped value is returned, and
--  lists and structures are copied rather than modified -- upstream's in-place
--  edit can reach the stored raw value, which this port's BOTH cache and
--  VALUE hash must not see escaped.  A binary value (SCALAR ref) is left
--  alone, as Perl's `ref` test does; the _ordered_keys_ list of a structure
--  holds field names, not values.)
function ExifTool.DoEscape(val, escapeProc)
    if type(val) ~= 'table' then
        if type(val) == 'number' then val = ExifTool.NumStr(val) end
        return escapeProc(val)
    elseif val.ref ~= nil then
        return val
    end
    local copy = {}
    for key, v in pairs(val) do
        if key == '_ordered_keys_' then
            copy[key] = v
        else
            copy[key] = ExifTool.DoEscape(v, escapeProc)
        end
    end
    return copy
end

--------------------------------------------------------------------------------
-- Set the FileType and MIMEType tags
-- Inputs: 0) ExifTool object reference
--         1) Optional file type (uses FILE_TYPE if not specified)
--         2) Optional MIME type (uses our lookup if not specified)
--         3) Optional recommended extension (converted to lower case; uses FileType if undef)
-- Notes:  Will NOT set file type twice (subsequent calls ignored)
function ExifTool:SetFileType(fileType, mime, normExt)
    if self.FileType and not perlTruthy(self.DOC_NUM) then return end
    local baseType = self.FILE_TYPE
    fileType = fileType or baseType
    -- handle sub-types which are identified by extension (upstream
    -- SetFileType's $ext ne $fileType check; the extension is stored
    -- upper-cased in FILE_EXT, so e.g. SVG/INX/XMP extensions match)
    local ext = self.FILE_EXT
    if ext and ext ~= fileType and not perlTruthy(self.DOC_NUM) then
        local f = fileTypeLookup[fileType]
        local e = fileTypeLookup[ext]
        if type(f) == 'table' and type(e) == 'table' and f[1] == e[1] then
            -- make sure fileType was a root type and not another sub-type
            if f[1] == fileType or not fileTypeLookup[f[1]] then
                fileType = ext
            end
        end
    end
    mime = mime or mimeType[fileType]
    if not mime then mime = mimeType[baseType] end
    if not normExt then
        normExt = fileTypeExt[fileType] or fileType
    end
    if not perlTruthy(self.DOC_NUM) then self.FileType = fileType end
    self:FoundTag('FileType', fileType)
    -- Stored UPPER case: the lower-case form is this tag's PrintConv
    -- (ExifTool.pm:1434 `lc $val`, and 9714 stores `uc $normExt`), so -n
    -- must show it uppercase -- as the tag's own Notes state.
    self:FoundTag('FileTypeExtension', uc(normExt))
    self:FoundTag('MIMEType', mime or 'application/unknown')
end

--------------------------------------------------------------------------------
-- Override the FileType and MIMEType tags
-- Inputs: 0) ExifTool object ref, 1) file type, 2) MIME type, 3) normal extension (lower case)
-- Notes:  does nothing if FileType was not previously defined (ie. when writing)
function ExifTool:OverrideFileType(fileType, mime, normExt)
    if self.VALUE.FileType == nil or fileType == self.VALUE.FileType then return end
    self.FileType = fileType
    self.VALUE.FileType = fileType
    if not normExt then
        normExt = fileTypeExt[fileType] or fileType
    end
    self.VALUE.FileTypeExtension = uc(normExt)  -- ExifTool.pm:9733
    mime = mime or mimeType[fileType]
    if mime then self.VALUE.MIMEType = mime end
    if perlTruthy(self.OPTIONS.Verbose) then
        self:VPrint(0, self.INDENT .. 'FileType [override] = ' .. fileType .. '\n')
        self:VPrint(0, self.INDENT .. 'FileTypeExtension [override] = ' .. self.VALUE.FileTypeExtension .. '\n')
        if mime then self:VPrint(0, self.INDENT .. 'MIMEType [override] = ' .. mime .. '\n') end
    end
end

--------------------------------------------------------------------------------
-- Modify the MIME type based on some outside information (eg. a MIE
-- subfile type). Combines the current MIMEType with the given one, e.g.
-- "application/x-mie" + "image/jpeg" -> "image/x-mie-jpeg"
-- Inputs: 0) ExifTool ref, 1) mime type or bare type name (looked up via
--         %mimeType if it contains no '/')
function ExifTool:ModifyMimeType(mime)
    if not mime:find('/', 1, true) then
        mime = mimeType[mime]
        if not mime then return end
    end
    local old = self.VALUE.MIMEType
    if old then
        local _, b = old:match('^([^/]*)/(.*)$')
        local c, d = mime:match('^([^/]*)/(.*)$')
        d = (d:gsub('^x%-', ''))
        self.VALUE.MIMEType = c .. '/' .. b .. '-' .. d
        self:VPrint(0, '  Modified MIMEType = ' .. c .. '/' .. b .. '-' .. d .. '\n')
    else
        self:FoundTag('MIMEType', mime)
    end
end

--------------------------------------------------------------------------------
-- Tag table registry (upstream GetTagTable / SetupTagTable / GetTagInfo)
--------------------------------------------------------------------------------

local allTables = {}   -- list of all tables loaded (except Composite tags)
local tableOrder = {}  -- order the tables were loaded
ExifTool.tableOrder = tableOrder -- (package variable, `@tableOrder` in :Vars: BuildTagLookup.pm reads it)

-- special table entries (upstream %specialTags); used by the JSON module to
-- avoid conflicts between JSON tag names and table meta keys.  The entries
-- are laid out in the same 5-column grid as the upstream `qw(...)` block
-- (left-aligned columns, one entry per cell).
ExifTool.specialTags = {}
do
    local names = {
        'TABLE_NAME',      'SHORT_NAME',  'PROCESS_PROC', 'WRITE_PROC', 'CHECK_PROC',
        'GROUPS',          'FORMAT',      'FIRST_ENTRY',  'TAG_PREFIX', 'PRINT_CONV',
        'WRITABLE',        'TABLE_DESC',  'NOTES',        'IS_OFFSET',  'IS_SUBDIR',
        'EXTRACT_UNKNOWN', 'NAMESPACE',   'PREFERRED',    'SRC_TABLE',  'PRIORITY',
        'AVOID',           'WRITE_GROUP', 'LANG_INFO',    'VARS',       'DATAMEMBER',
        'SET_GROUP1',      'PERMANENT',   'INIT_TABLE',
    }
    for i = 1, #names do ExifTool.specialTags[names[i]] = 1 end
end

--------------------------------------------------------------------------------
-- Add hash of Composite tags to our composites
-- Inputs: 0) hash reference to table of Composite tags to add or module name,
--         1) override existing tag definition
-- (port: a module adds its Composite tags while it is still being loaded,
--  i.e. before `require` has entered it in package.loaded, so with a module
--  name the caller passes its module table as 2) -- the stand-in for Perl's
--  symbolic reference to the package hash `%{"${add}::Composite"}`)
function ExifTool.AddCompositeTags(add, override, pkg)
    local module, prefix, tagID
    if type(add) ~= 'table' then
        prefix = add:gsub('.*%.', '')
        module = add
        add = (pkg or package.loaded[module]).Composite
        prefix = prefix .. '-'
    else
        prefix = 'UserDefined-'
    end
    local defaultGroups = add.GROUPS
    local compTable = ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.Composite')

    -- make sure default groups are defined in families 0 and 1
    if defaultGroups then
        if not defaultGroups[0] then defaultGroups[0] = 'Composite' end
        if not defaultGroups[1] then defaultGroups[1] = 'Composite' end
        if not defaultGroups[2] then defaultGroups[2] = 'Other' end
    else
        defaultGroups = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' }
        add.GROUPS = defaultGroups
    end
    ExifTool.SetupTagTable(add)    -- generate Name, TagID, etc
    for _, id in ipairs(perl.sort(ExifTool.TagTableKeys(add))) do
        tagID = id
        if ExifTool.specialTags[tagID] then goto nextTag end   -- must skip special tags
        do
            local tagInfo = add[tagID]
            local new = prefix .. tagID     -- new tag ID for Composite table
            if perlTruthy(tagInfo.Writable) then tagInfo.Module = module end
            if override and tagInfo.Override == nil then tagInfo.Override = 1 end
            tagInfo.IsComposite = 1
            -- handle Composite tags with the same name
            if compositeID[tagID] then
                -- determine if we want to override this tag
                -- (=0 keep both, >0 override, <0 keep existing)
                local over = (tagInfo.Override or 0) - (compTable[compositeID[tagID][1]].Override or 0)
                if over < 0 then goto nextTag end
                if over ~= 0 then
                    -- remove existing tags with this ID
                    for _, oldID in ipairs(compositeID[tagID]) do compTable[oldID] = nil end
                    compositeID[tagID] = nil
                end
            end
            -- make sure new TagID is unique by adding index if necessary
            -- (could only happen for UserDefined tags now that module name is added to tag ID)
            local n = 0
            while compTable[new] do
                if n ~= 0 then new = new:gsub('%-%d+$', '') end
                n = n + 1
                new = new .. '-' .. n
            end
            -- use new ID and save it so we can use it in TagLookup
            if tagID ~= new then tagInfo.NewTagID = new end

            -- add new ID to lookup of Composite tag ID's
            if not compositeID[tagID] then compositeID[tagID] = { } end
            table.insert(compositeID[tagID], 1, new)  -- (most recent one first)

            -- convert scalar Require/Desire/Inhibit entries
            local hashes, scalars, used = { }, { }, { }
            for _, type_ in ipairs({ 'Require', 'Desire', 'Inhibit' }) do
                local req = tagInfo[type_]
                if req then
                    local into = type(req) == 'table' and hashes or scalars
                    into[#into + 1] = type_
                end
            end
            if #scalars > 0 then
                -- make lookup for indices that are used
                for _, type_ in ipairs(hashes) do
                    for idx in pairs(tagInfo[type_]) do used[idx] = 1 end
                end
                local next_ = 0
                for _, type_ in ipairs(scalars) do
                    while used[next_] do next_ = next_ + 1 end
                    tagInfo[type_] = { [next_] = tagInfo[type_] }
                    next_ = next_ + 1
                end
            end
            -- add this Composite tag to our main Composite table
            tagInfo.Table = compTable
            -- (use the original TagID, even if we changed it, so don't do this:)
            tagInfo.TagID = new
            -- save tag under new ID in Composite table
            compTable[new] = tagInfo
            -- set all default groups in tag
            local groups = tagInfo.Groups
            if not groups then groups = { }; tagInfo.Groups = groups end
            -- fill in default groups
            for k, v in pairs(defaultGroups) do
                if not groups[k] then groups[k] = v end
            end
            -- set flag indicating group list was built
            tagInfo.GotGroups = 1
        end
        ::nextTag::
    end
end

--------------------------------------------------------------------------------
-- Add tags to TagLookup (used for writing)
-- Inputs: 0) source hash of tag definitions, 1) name of destination tag table
function ExifTool.AddTagsToLookup(tagHash, table_)
    local TagLookup = package.loaded['lexiftool.TagLookup']
    if TagLookup and TagLookup.AddTags then
        TagLookup.AddTags(tagHash, table_)
    elseif not ExifTool.pluginTagsAdded[tagHash] then
        -- queue these tags until TagLookup is loaded
        ExifTool.pluginTags = ExifTool.pluginTags or { }
        table.insert(ExifTool.pluginTags, { tagHash, table_ })
        -- set flag so we don't load same tags twice
        ExifTool.pluginTagsAdded[tagHash] = 1
    end
end
ExifTool.pluginTagsAdded = { }  -- (upstream %Image::ExifTool::pluginTags, the hash of the same name)

--------------------------------------------------------------------------------
-- Expand tagInfo Flags
-- Inputs: 0) tagInfo hash ref
-- Notes: $$tagInfo{Flags} must be defined to call this routine
-- (port: an ARRAY is a sequence table, a HASH any other table)
function ExifTool.ExpandFlags(tagInfo)
    local flags = tagInfo.Flags
    if type(flags) == 'table' and flags[1] ~= nil then
        for _, f in ipairs(flags) do
            tagInfo[f] = 1
        end
    elseif type(flags) == 'table' then
        for key, v in pairs(flags) do
            tagInfo[key] = v
        end
    else
        tagInfo[flags] = 1
    end
end

--------------------------------------------------------------------------------
-- Set up tag table (must be done once for each tag table used)
-- Inputs: 0) Reference to tag table
-- Notes: - generates 'Name' field from key if it doesn't exist
--        - stores 'Table' pointer and 'TagID' value
--        - expands 'Flags' for quick lookup
function ExifTool.SetupTagTable(table)
    if table._SETUP then return end
    local avoid = table.AVOID
    for tagID in pairs(table) do
        if not ExifTool.specialTags[tagID] then
            local infoArray = ExifTool.GetTagInfoList(table, tagID)
            for i = 1, #infoArray do
                local tagInfo = infoArray[i]
                tagInfo.Table = table
                if tagInfo.TagID == nil then tagInfo.TagID = tagID end
                if not tagInfo.Name then tagInfo.Name = ExifTool.MakeTagName(tagID) end
                if tagInfo.Flags then ExifTool.ExpandFlags(tagInfo) end
                if avoid ~= nil then tagInfo.Avoid = avoid end
                -- calculate BitShift from Mask if necessary (upstream SetupTagTable)
                if tagInfo.Mask and tagInfo.BitShift == nil then
                    local bitShift = 0
                    local m = tagInfo.Mask
                    while m & (1 << bitShift) == 0 do bitShift = bitShift + 1 end
                    tagInfo.BitShift = bitShift
                end
            end
            -- add an "Index" member to each tagInfo in a list
            if #infoArray > 1 then
                local index = 0
                for i = 1, #infoArray do
                    infoArray[i].Index = index
                    index = index + 1
                end
            end
        end
    end
    table._SETUP = 1
end

--------------------------------------------------------------------------------
-- Is this a PC system?
-- Returns: true for PC systems
-- uses lookup for O/S names which may use a backslash as a directory separator
-- (ref File::Spec of PathTools-3.2701)
local isPC = { MSWin32 = 1, os2 = 1, dos = 1, NetWare = 1, symbian = 1, cygwin = 1 }
function ExifTool.IsPC()
    return isPC[perl.osname()]
end

--------------------------------------------------------------------------------
-- Return list of tag table keys (ignoring special keys)
-- Inputs: 0) tag table reference
-- Returns: list of tag keys (unsorted)
function ExifTool.TagTableKeys(tagTablePtr)
    local keyList = {}
    for k in pairs(tagTablePtr) do
        -- '_SETUP' has no upstream counterpart -- it is this port's
        -- SetupTagTable marker, so it is filtered out here as well
        if not ExifTool.specialTags[k] and k ~= '_SETUP' then keyList[#keyList + 1] = k end
    end
    return keyList
end

--------------------------------------------------------------------------------
-- GetTagTable
-- Inputs: 0) table name
-- Returns: tag table reference, or undefined if not found
-- Notes: Always use this function instead of requiring module and using table
-- directly since this function also does the following the first time the table
-- is loaded:
-- - requires new module if necessary
-- - generates default GROUPS hash and Group 0 name from module name
-- - registers Composite tags if Composite table found
-- - saves descriptions for tags in specified table
-- - generates default TAG_PREFIX to be used for unknown tags
--
-- Resolve a tag table by name (upstream GetTagTable). Tables in the ported
-- container modules are referenced as 'lexiftool.Exif.Main' etc.
function ExifTool.GetTagTable(_self, tableName)
    if not perlTruthy(tableName) then return nil end
    local table_ = allTables[tableName]
    if not table_ then
        if tableName == 'lexiftool.ExifTool.Extra' then
            table_ = ExifTool.Extra
        elseif tableName == 'lexiftool.ExifTool.Composite' then
            table_ = ExifTool.Composite
        elseif tableName == 'lexiftool.ExifTool.UserParam' then
            table_ = ExifTool.UserParam
        else
            local modName, rest = tableName:match('^lexiftool%.([^%.]+)%.(.*)$')
            if modName == 'JFIF' then
                table_ = ExifTool.JFIF[rest]
            elseif modName == 'UserDefined' then
                -- the tables of upstream's package Image::ExifTool::UserDefined,
                -- which a config file or the calling script defines -- there is
                -- no module file behind them (see ExifTool.UserDefinedTables)
                table_ = ExifTool.UserDefinedTables[rest]
            else
                -- lazy-load the container module (upstream: eval "require $module")
                local mod = loadModule(modName)
                if mod then
                    table_ = mod[rest]
                    if not table_ then
                        -- load additional modules if required
                        -- (XMP2.pl fills the XMP package with more namespace
                        --  tables; QuickTimeStream.pl's tables are named after
                        --  their own module in this port, so only XMP is left)
                        if modName == 'XMP' then
                            loadModule('XMP2')
                            table_ = mod[rest]
                        end
                    end
                end
            end
        end
        if not table_ then
            -- (the name in upstream's spelling: as a config file names it,
            --  otherwise 'lexiftool.X.Y' is Image::ExifTool::X::Y)
            local perlName = configTableNames[tableName]
            if not perlName then
                local rest = tableName:match('^lexiftool%.(.*)$')
                if rest then
                    rest = rest:match('^ExifTool%.(.*)$') or rest
                    rest = rest:gsub('^QuickTimeStream%.', 'QuickTime.')
                    perlName = 'Image::ExifTool::' .. rest:gsub('%.', '::')
                else
                    perlName = tableName
                end
            end
            perl.warn("Can't find table " .. perlName .. "\n")
            return nil
        end
        if table_.INIT_TABLE then table_.INIT_TABLE(table_) end
        table_.TABLE_NAME = tableName   -- set table name
        -- (ExifTool.pm:8978: `($$table{SHORT_NAME} = $tableName) =~
        --  s/^Image::ExifTool:://`.  TABLE_NAME stays the Lua spelling
        --  ('lexiftool.Exif.Main'), but SHORT_NAME is what upstream hands out
        --  (GetTableName, -j/-X -t, Validate, TagInfoXML), so it gets the Perl
        --  spelling: 'Exif::Main', and 'Extra' for the tables ExifTool.pm itself
        --  defines, which this port registers as 'lexiftool.ExifTool.Extra')
        local shortName = tableName:match('^lexiftool%.(.*)$')
        if shortName then
            shortName = shortName:match('^ExifTool%.(.*)$') or shortName
            shortName = shortName:gsub('%.', '::')
            -- (a module's Composite table hands its tags to the one merged
            --  %Image::ExifTool::Composite in AddCompositeTags, SHORT_NAME
            --  'Composite' (ExifTool.pm:2305) -- looked up here, the module
            --  table carries that name too)
            if shortName:sub(-11) == '::Composite' then shortName = 'Composite' end
            -- (QuickTimeStream.pl fills the QuickTime package, so upstream's tables
            --  are 'QuickTime::Stream', 'QuickTime::tx3g', ...; this port makes the
            --  file its own module)
            shortName = shortName:gsub('^QuickTimeStream::', 'QuickTime::')
        end
        table_.SHORT_NAME = shortName or tableName
        -- set default group 0 and 1 from module name unless already specified
        local defaultGroups = table_.GROUPS
        if not defaultGroups then defaultGroups = {} table_.GROUPS = defaultGroups end
        if not (defaultGroups[0] and defaultGroups[1]) then
            local seg = tableName:match('^lexiftool%.([^%.]+)')
            -- (the QuickTimeStream.pl tables belong to package QuickTime upstream)
            if seg == 'QuickTimeStream' then seg = 'QuickTime' end
            if seg then
                if not defaultGroups[0] then defaultGroups[0] = seg end
                if not defaultGroups[1] then defaultGroups[1] = seg end
            end
        end
        if not defaultGroups[2] then defaultGroups[2] = 'Other' end
        -- initialize some XMP table defaults (ExifTool.pm:8992-8999: upstream
        -- calls RegisterNamespace for every XMP table; it only does something
        -- when NAMESPACE is a list or hash, as in a user-defined table, so it is
        -- called only then)
        if (table_.GROUPS and table_.GROUPS[0] == 'XMP') or table_.NAMESPACE then
            local XMP = loadModule('XMP')
            if type(table_.NAMESPACE) == 'table' then
                XMP.RegisterNamespace(table_) -- register all table namespaces
            end
            -- set default write/check procs
            if not table_.WRITE_PROC then table_.WRITE_PROC = XMP.WriteXMP end
            if not table_.CHECK_PROC then table_.CHECK_PROC = XMP.CheckXMP end
            if not table_.LANG_INFO then table_.LANG_INFO = XMP.GetLangInfo end
        end
        -- generate a tag prefix for unknown tags if necessary
        -- (upstream matches Image::.*?::(.*)::Main first, then Image::.*?::(.*),
        --  i.e. everything below the Image::ExifTool:: namespace with the
        --  trailing ::Main dropped and the remaining :: turned into _ --
        --  Canon::CameraSettings therefore prefixes its unknown tags with
        --  Canon_CameraSettings, not with Canon)
        if table_.TAG_PREFIX == nil then
            local seg = tableName:match('^lexiftool%.ExifTool%.(.*)$') or
                        tableName:match('^lexiftool%.(.*)$')
            if seg then
                -- (QuickTimeStream.pl's tables are in package QuickTime upstream)
                seg = seg:gsub('^QuickTimeStream%.', 'QuickTime.')
                seg = seg:gsub('%.Main$', ''):gsub('%.', '_')
            end
            table_.TAG_PREFIX = seg or tableName
        end
        -- set up the new table
        ExifTool.SetupTagTable(table_)
        -- add any user-defined tags (except Composite tags, which are handled specially)
        local UserDefined = ExifTool.UserDefined
        if UserDefined and next(UserDefined) ~= nil and UserDefined[tableName] and table_ ~= ExifTool.Composite then
            local tagID
            for _, id in ipairs(ExifTool.TagTableKeys(UserDefined[tableName])) do
                tagID = id
                if not ExifTool.specialTags[tagID] then
                    table_[tagID] = nil -- replace any existing entry
                    ExifTool.AddTagToTable(nil, table_, tagID, UserDefined[tableName][tagID], 1)
                end
            end
        end
        -- remember order we loaded the tables in
        tableOrder[#tableOrder + 1] = tableName
        -- insert newly loaded table into list
        allTables[tableName] = table_
    end
    -- must check each time to add UserDefined Composite tags because the Composite table
    -- may be loaded before the UserDefined tags are available
    local UserDefined = ExifTool.UserDefined
    if table_ == ExifTool.Composite and not (table_.VARS and table_.VARS.LOADED_USERDEFINED) and
        UserDefined and next(UserDefined) ~= nil and UserDefined[tableName]
    then
        local userComp = UserDefined[tableName]
        UserDefined[tableName] = nil         -- (must delete first to avoid infinite recursion)
        ExifTool.AddCompositeTags(userComp, 1)
        UserDefined[tableName] = userComp    -- (add back again for adding writable tags later)
        if not table_.VARS then table_.VARS = { } end
        table_.VARS.LOADED_USERDEFINED = 1   -- set flag to avoid doing this again
    end
    return table_
end

--------------------------------------------------------------------------------
-- Get the registry of all loaded tag tables (upstream %allTables, which
-- Writer.pl's LoadAllTables and BuildTagLookup walk).
function ExifTool.GetAllTables()
    return allTables
end

--------------------------------------------------------------------------------
-- Get list of tag information hashes for given tag ID
-- Inputs: 0) Tag table reference, 1) tag ID
-- Returns: Array of tag information references
-- Notes: Generates tagInfo hash if necessary
-- (port: upstream returns a fresh Perl list; every caller here only reads
--  the returned array -- a conditional list is the table's own array anyway
--  -- so the one-element list of a plain tagInfo hash is built once per hash
--  and reused (weak keys: it goes with its tagInfo), and "no tag" is one
--  shared empty list: no table per call. Callers must not modify the list)
local emptyInfoList = setmetatable({}, { __newindex = function()
    error('GetTagInfoList: the empty list is shared', 2)
end })
local singleInfoList = setmetatable({}, { __mode = 'k' })
local function singleList(tagInfo)
    local list = { tagInfo }
    singleInfoList[tagInfo] = list
    return list
end
function ExifTool.GetTagInfoList(tagTablePtr, tagID)
    local tagInfo = tagTablePtr[tagID]
    if type(tagInfo) == 'table' then
        if tagInfo[1] ~= nil then
            -- conditional list
            return tagInfo
        end
        return singleInfoList[tagInfo] or singleList(tagInfo)
    elseif tagInfo then
        -- bare string name: create hash
        tagTablePtr[tagID] = { Name = tagInfo }
        return singleList(tagTablePtr[tagID])
    end
    return emptyInfoList
end

--------------------------------------------------------------------------------
-- Find tag information, processing conditional tags
-- Inputs: 0) ExifTool object reference, 1) tagTable pointer, 2) tag ID
--         3) optional value reference (usually reference to binary data value, but
--            depends on information type), 4) optional format type, 5) optional value count
-- Returns: pointer to tagInfo hash, undefined if none found, or '' if $valPt needed
--          (this port returns `false` where upstream returns '': both are falsy,
--           and both are distinguishable from "not found" -- nil/undef)
-- Notes: You should always call this routine to find a tag in a table because
-- this routine will evaluate conditional tags.
-- Arguments 3-5 are only required if the information type allows $valPt, $format and/or
-- $count in a Condition, and if not given when needed this routine returns ''.
function ExifTool:GetTagInfo(tagTablePtr, tagID, val, format, count)
    local infoArray = ExifTool.GetTagInfoList(tagTablePtr, tagID)
    local options = self.OPTIONS
    for i = 1, #infoArray do
        local tagInfo = infoArray[i]
        local condition = tagInfo.Condition
        local ok = true
        if condition and type(condition) == 'function' then
            -- upstream: `return '' if $condition =~ /\$(valPt|format|count)\b/
            -- and not defined $valPt` -- the condition needs the value, so the
            -- caller has to ask again once it has one. This port's conditions
            -- are functions, so "needs the value" is read off the declared
            -- parameter list: `function(self)` decides from the object alone,
            -- `function(_self, val)` needs the value.
            if val == nil and debug.getinfo(condition, 'u').nparams >= 2 then
                return false
            end
            -- upstream: `unless (eval $condition) { next }` -- the condition
            -- is rejected on any FALSE value, so Perl's truthiness decides
            -- (undef, 0 and '' all reject). perlTruthy is that test; a plain
            -- `~= false` would let a condition that returns nil or 0 through.
            ok = perlTruthy(condition(self, val, format, count))
        end
        -- don't return Unknown tags unless the option is set (or we are
        -- writing, or Verbose/HtmlDump is on -- upstream GetTagInfo)
        if ok and tagInfo.Unknown and not optOn(options.Unknown) and not self.IsWriting and
            not (optOn(options.Verbose) or self.HTML_DUMP or
            (optOn(options.Validate) and not tagInfo.AddedUnknown)) then
            ok = false
        end
        if ok then
            tagInfo.Table = tagTablePtr
            return tagInfo
        end
    end
    -- generate information for unknown tags (numerical only) if required
    if (optOn(options.Unknown) or optOn(options.Verbose) or self.HTML_DUMP) and
        perl.str(tagID):match('^%d+$') and not self.NO_UNKNOWN then
        local hex = sprintf('0x%.4x', tonumber(tagID))
        local prefix = tagTablePtr.TAG_PREFIX
        -- limit length of printout (can be very long) unless the table
        -- defines its own default PRINT_CONV (upstream GetTagInfo)
        local printConv = tagTablePtr.PRINT_CONV
        if printConv == nil then
            printConv = function(self_, v) return ExifTool.LimitLongValues(v, self_) end
        end
        local newInfo = {
            Name = prefix .. '_' .. hex,
            Description = ExifTool.MakeDescription(prefix, hex),
            Unknown = 1,
            Writable = 0,
            PrintConv = printConv,
            AddedUnknown = 1,
        }
        self:AddTagToTable(tagTablePtr, tagID, newInfo)
        return newInfo
    end
    return nil
end

--------------------------------------------------------------------------------
-- Add new tag to table (must use this routine to add new tags to a table)
-- Inputs: 0) reference to tag table, 1) tag ID
--         2) [optional] tag name or reference to tag information hash
--         3) [optional] flag to avoid adding prefix when generating tag name
-- Returns: tagInfo ref
-- Notes: - will not override existing entry in table
-- - info need contain no entries when this routine is called
-- - tag name is cleaned if necessary
function ExifTool.AddTagToTable(_self, tagTablePtr, tagID, tagInfo, noPrefix)
    if not tagInfo then tagInfo = {} end
    if type(tagInfo) ~= 'table' then tagInfo = { Name = tagInfo } end
    -- fill in default groups from table GROUPS
    local tg = tagTablePtr.GROUPS or {}
    if tagInfo.Groups then
        for k, v in pairs(tg) do
            if tagInfo.Groups[k] == nil then tagInfo.Groups[k] = v end
        end
    else
        tagInfo.Groups = {}
        for k, v in pairs(tg) do tagInfo.Groups[k] = v end
    end
    if tagInfo.Flags then ExifTool.ExpandFlags(tagInfo) end
    tagInfo.GotGroups = 1
    tagInfo.Table = tagTablePtr
    tagInfo.TagID = tagID
    if tagInfo.Hidden == nil then tagInfo.Hidden = 1 end
    if tagTablePtr.AVOID ~= nil and tagInfo.Avoid == nil then
        tagInfo.Avoid = tagTablePtr.AVOID
    end
    local hadName = tagInfo.Name ~= nil
    local name = tagInfo.Name or perl.str(tagID)
    -- (the class is ASCII-explicit, as Perl's tr/-_a-zA-Z0-9//dc: Lua's %w
    --  follows LC_CTYPE and takes bytes >= 0x80 under a single-byte locale)
    name = name:gsub('[^A-Za-z0-9_-]', '')
    name = ucfirst(name)
    -- add tag-name prefix if specified and tag name not provided
    if not hadName and not noPrefix and tagTablePtr.TAG_PREFIX and tagTablePtr.TAG_PREFIX ~= '' then
        -- make description to prevent tagID from getting mangled by MakeDescription()
        tagInfo.Description = ExifTool.MakeDescription(tagTablePtr.TAG_PREFIX, name)
        name = tagTablePtr.TAG_PREFIX .. '_' .. name
    end
    -- tag names must be at least 2 characters long and prefer them to start
    -- with a letter (upstream AddTagToTable)
    if #name < 2 or not name:match('^[A-Za-z]') then
        name = 'Tag' .. name
    end
    tagInfo.Name = name
    -- add tag to table, but never override existing entries (could potentially happen
    -- if someone thinks there isn't any tagInfo because a condition wasn't satisfied)
    if tagTablePtr[tagID] == nil and not ExifTool.specialTags[tagID] then
        tagTablePtr[tagID] = tagInfo
        if perlTruthy(purgeFlag) and tagInfo.Unknown and not tagInfo.SubDirectory then
            purgeTags[#purgeTags + 1] = tagInfo
        end
    end
    if tagInfo.Unknown then tagInfo.AddedUnknown = 1 end
    return tagInfo
end

--------------------------------------------------------------------------------
-- FoundTag / DeleteTag / GetValue / GetInfo
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Handle simple extraction of new tag information
-- Inputs: 0) ExifTool object ref, 1) tag table reference, 2) tagID, 3) raw value,
--         4-N) parameters hash: Index, DataPt, DataPos, Base, Start, Size, Parent,
--              TagInfo, ProcessProc, RAF, Format, Count, MakeTagInfo
-- Returns: tag key or undef if tag not found
-- Notes: if value is not defined, it is extracted from DataPt using TagInfo
--        Format and Count if provided
-- - set MakeTagInfo to add tag info for unknown tags with name made from tag ID
function ExifTool:HandleTag(tagTablePtr, tag, val, parms)
    local dataPt = parms and parms.DataPt
    local tagInfo = parms and parms.TagInfo
    if not tagInfo then
        -- get binary data for Condition if necessary (upstream HandleTag:
        -- when val is nil, a conditional tag list may still need to see the
        -- raw bytes to pick the right alternative -- e.g. LNK.ItemID's
        -- `Condition => '$$valPt =~ /^.{5}\xff{3}/s'`; pre-extract a preview
        -- (capped like upstream's 1024 bytes) so Condition functions can
        -- inspect it, whether or not this particular tag's Condition uses it)
        local condVal = val
        if condVal == nil and dataPt then
            local start = (parms and parms.Start) or 0
            local psize = parms and parms.Size
            if not psize then psize = #dataPt - start end
            if psize > 1024 then psize = 1024 end
            if start >= 0 and start + psize <= #dataPt then
                condVal = substr(dataPt, start, psize)
            end
        end
        tagInfo = self:GetTagInfo(tagTablePtr, tag, condVal, parms and parms.Format, parms and parms.Count)
    end
    -- upstream HandleTag: when no tagInfo was found at all (every
    -- Condition in a conditional list failed, or the tag simply isn't in
    -- the table), either synthesize a permanent one (MakeTagInfo, e.g.
    -- PDF's per-dict-key fallback) or -- if the caller didn't ask for
    -- that -- bail out unless Verbose is set, in which case a *temporary*
    -- tagInfo is used just so VerboseInfo below has a Name/prefix to
    -- print (e.g. MPEG.Audio's `Bit26-27` when its Condition picked the
    -- sibling `Bit26`/`Bit27` alternative instead: never a real tag, but
    -- still shown as `MPEG_Audio_Bit26-27 = N` under `-v`)
    local noTagInfo = false
    if not tagInfo then
        if parms and parms.MakeTagInfo then
            if perlTruthy(self.OPTIONS.Verbose) then
                self:VPrint(0, self.INDENT .. '[adding ' .. perl.str(tag) .. ']\n')
            end
            local name = perl.str(tag)
            name = name:gsub('([A-Z]) ([A-Z][ A-Z])', '%1_%2') -- underline between acronyms
            name = name:gsub('([^A-Za-z])([a-z])', function(a, b) return a .. uc(b) end) -- capitalize words
            name = name:gsub('[^%-_a-zA-Z0-9]', '') -- remove illegal characters
            if #name < 2 or name:match('^[%-0-9]') then
                name = 'Tag' .. name
            end
            name = ucfirst(name)
            tagInfo = { Name = name }
            self:AddTagToTable(tagTablePtr, tag, tagInfo)
        elseif perlTruthy(self.OPTIONS.Verbose) then
            tagInfo = { Name = 'tag ' .. perl.str(tag) } -- create temporary tagInfo table
            noTagInfo = true
        else
            return nil
        end
    end
    local subdir = tagInfo and tagInfo.SubDirectory
    -- upstream HandleTag only ever assigns its local $format inside the
    -- `unless (defined $val or ($subdir and ...))` value-reading block
    -- below -- when the caller already supplied a value (e.g.
    -- CanonCustom.ProcessCanonCustom's `HandleTag(..., $val, Format =>
    -- 'int8u', Count => 1, Size => 1, ...)`), $format stays undef for the
    -- whole function, so the verbose section's `if ($format) { $parms{Format}
    -- = ... }` override never fires and the caller's own explicit Format/
    -- Count parms reach VerboseInfo untouched. Computing `format`
    -- unconditionally here (as an earlier version of this port did) made
    -- that override fire anyway, double-appending the count and printing
    -- "int8u[1][1]" instead of "int8u[1]".
    local format
    -- (upstream's `\$rational`: ReadValue fills in `.rat` for a rational
    --  format; only the verbose print below reads it)
    local rational = perlTruthy(self.OPTIONS.Verbose) and {} or nil
    -- read the value if not done already (not necessary for a subdirectory)
    if val == nil and not (subdir and not tagInfo.Writable and not tagInfo.RawConv) then
        format = tagInfo and (tagInfo.Format or tagTablePtr.FORMAT)
        -- upstream HandleTag: `$format = $pfmt if not $format and $pfmt and
        -- $formatSize{$pfmt}` -- a Format parm (e.g. Red's format-code-driven
        -- per-tag read format) fills in when neither the tag nor the table
        -- declares one
        if not format and parms and parms.Format and ExifTool.FormatSize(parms.Format) then
            format = parms.Format
        end
        local start = (parms and parms.Start) or 0
        local size = parms and parms.Size
        if not size and dataPt then size = #dataPt - start end
        if start >= 0 and dataPt and start + size <= #dataPt then
            if not format then
                val = substr(dataPt, start, size)
            elseif not (tagInfo and tagInfo.ByteOrder) then
                val = ExifTool.ReadValue(dataPt, start, format, tagInfo and tagInfo.Count, size, rational)
            else
                local oldOrder = ExifTool.GetByteOrder()
                ExifTool.SetByteOrder(tagInfo.ByteOrder)
                val = ExifTool.ReadValue(dataPt, start, format, tagInfo.Count, size, rational)
                ExifTool.SetByteOrder(oldOrder)
            end
        else
            self:Warn('Error extracting value for ' .. ((tagInfo and tagInfo.Name) or perl.str(tag)))
            return nil
        end
    end
    if tagInfo then
        -- do verbose print if necessary (upstream HandleTag's VerboseInfo)
        if perlTruthy(self.OPTIONS.Verbose) then
            local vparms = {}
            for k, v in pairs(parms or {}) do vparms[k] = v end
            vparms.Value = val
            if rational and rational.rat ~= nil then vparms.Value = perl.str(val) .. ' (' .. rational.rat .. ')' end
            vparms.Table = tagTablePtr
            if format then
                local cnt = math.floor((vparms.Size or 0) / (ExifTool.FormatSize(format) or 1))
                vparms.Format = format .. '[' .. cnt .. ']'
            end
            -- upstream HandleTag: `undef $tagInfo if $noTagInfo` runs right
            -- before this call, so VerboseInfo sees no Name and falls back
            -- to its own Table.TAG_PREFIX-based naming (e.g.
            -- `MPEG_Audio_Bit26-27`) instead of the literal `tag $tag`
            -- placeholder used only to reach this point
            local viTagInfo = tagInfo
            if noTagInfo then viTagInfo = nil end
            self:VerboseInfo(tag, viTagInfo, vparms)
        end
        -- upstream HandleTag: `undef $tagInfo if $noTagInfo` runs before
        -- VerboseInfo above, so the temporary tagInfo never reaches the
        -- SubDirectory/FoundTag handling below -- an unresolved tag is
        -- shown in verbose output but never stored
        if noTagInfo then return nil end
        if subdir then
            if tagInfo.MakerNotes and self.OPTIONS.FastScan and self.OPTIONS.FastScan > 1 then
                return nil      -- don't process maker note directories when FastScan > 1
            end
            -- apply RawConv if necessary (upstream: only a RawConv-driven
            -- subdirectory requires a non-nil value -- e.g. BPG.pm calls
            -- HandleTag with val=nil for a plain buffer-backed subdirectory,
            -- and that is not an error)
            local rawConvApplied = false
            if tagInfo.RawConv and not tagInfo.Writable then
                local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
                perl.SIG.__WARN__ = ExifTool.SetWarning
                ExifTool.evalWarning = nil
                val = tagInfo.RawConv(self, val, tag)
                perl.SIG.__WARN__ = oldWarn
                if perlTruthy(ExifTool.evalWarning) then
                    self:Warn('RawConv ' .. perl.str(tag) .. ': ' .. ExifTool.CleanWarning())
                end
                if val == nil then return nil end
                rawConvApplied = true
            end
            -- upstream HandleTag: `my $subdirStart = $parms{Start};` -- left
            -- undef (not defaulted to 0) when no Start parm was given at
            -- all, which matters for ProcessDirectory's cyclical-recursion
            -- guard (`defined $$dirInfo{DirStart}`): a subdirectory
            -- dispatched with no Start (e.g. LNK's outer ItemID-list tag)
            -- must NOT participate in the guard, or a first sub-item that
            -- happens to start at offset 0 collides with it. `start`
            -- (below) still defaults to 0 for the actual byte-offset math;
            -- `startDefined` tracks the separate defined-ness upstream cares
            -- about for DirStart.
            local startDefined = parms ~= nil and parms.Start ~= nil
            local start = (parms and parms.Start) or 0
            local size = parms and parms.Size
            -- upstream HandleTag: `$subdirLen = length($$dataPt) -
            -- $subdirStart unless defined $subdirLen` when a DataPt is given
            -- (e.g. Red's RED2 header with `HandleTag(..., undef, DataPt =>
            -- \$buff)`); only fall back to the value length when there is no
            -- separate buffer (e.g. a value-only subdirectory, WTV)
            if not size and dataPt then
                size = #dataPt - start
            elseif not size then
                size = #perl.str(val)
            end
            -- a RawConv that produced a new value (e.g. a base64-decoded
            -- block) replaces the data source for the subdirectory (upstream
            -- HandleTag: `$dataPt = ref $val eq 'SCALAR' ? $val : \$val;
            -- $subdirStart = 0; $subdirLen = length $$dataPt`)
            local subDataPt = dataPt
            if rawConvApplied then
                if type(val) == 'table' and val.ref == 'SCALAR' then
                    subDataPt = val.value
                else
                    subDataPt = perl.str(val)
                end
                start = 0
                startDefined = true
                size = #subDataPt
            elseif not subDataPt then
                -- a value-only subdirectory (no DataPt parm, e.g. WTV's
                -- table.0.entries.legacy_attrib -- upstream HandleTag:
                -- `elsif (not $dataPt) { $dataPt = ref $val eq 'SCALAR' ?
                -- $val : \$val; }` -- the tag's own value is the buffer)
                if type(val) == 'table' and val.ref == 'SCALAR' then
                    subDataPt = val.value
                    start = 0
                    size = #subDataPt
                elseif type(val) == 'table' then
                    -- (upstream: `\$val` wraps any Perl ref type -- an
                    -- array/hash ref included -- so the subdirectory's own
                    -- ProcessProc can pull it back out (e.g.
                    -- `ref $$dataPt eq 'ARRAY'`); Lua has no generic
                    -- reference wrapping, so pass the table through
                    -- directly instead of stringifying it, e.g. DjVu's
                    -- ProcessAnt hands ProcessMeta a parsed [tag,value]
                    -- entry list this way)
                    subDataPt = val
                    start = 0
                    size = 0
                else
                    subDataPt = perl.str(val)
                    start = 0
                    size = #subDataPt
                end
            end
            local subTable = self:GetTagTable(subdir.TagTable)
            -- apply SubDirectory.Start offset (upstream HandleTag: the
            -- `Start` eval is added to the value's position, e.g. Pentax
            -- AVI maker notes' `Start => 10` skipping a "PENTAX " header)
            if subdir.Start then
                local off
                if type(subdir.Start) == 'function' then
                    off = subdir.Start(self, val, start)
                else
                    off = tonumber(subdir.Start)
                end
                if off then
                    start = start + off
                    startDefined = true -- (upstream: `$subdirStart += $off` makes it defined even if it started undef)
                    size = size - off
                end
            end
            -- process the subdirectory from the containing data block (the
            -- value position is parms.Start within parms.DataPt, mirroring
            -- upstream HandleTag)
            local subInfo = {
                Name = tagInfo.Name,
                Base = parms and parms.Base,
                DataPt = subDataPt,
                DataPos = parms and parms.DataPos,
                DataLen = subDataPt and #subDataPt or 0,
                DirStart = startDefined and start or nil,
                DirLen = size,
                Parent = parms and parms.Parent,
                DirName = subdir.DirName or tagInfo.Name,
                TagInfo = tagInfo,
            }
            -- apply SubDirectory.ByteOrder around the recursion (upstream
            -- HandleTag; 'Unknown' auto-detects from the entry count, the
            -- same heuristic Exif.ProcessExif's inline dispatch uses)
            local oldOrder = ExifTool.GetByteOrder()
            if subdir.ByteOrder then
                if subdir.ByteOrder == 'Unknown' then
                    if start + 2 <= size then
                        -- attempt to determine the byte ordering of an IFD-style subdirectory
                        local num = ExifTool.Get16u(subDataPt, start)
                        if num & 0xff00 ~= 0 and (num >> 8) > (num & 0xff) then
                            ExifTool.SetByteOrder(oldOrder == 'II' and 'MM' or 'II')
                        end
                    end
                else
                    -- SetByteOrder takes 'II'/'MM' as well as 'Little-endian'/
                    -- 'Big-endian', so the value goes through unchanged -- this
                    -- used to pre-match only the spelled-out forms, which
                    -- silently dropped Parrot's ARCore `ByteOrder => 'II'`
                    ExifTool.SetByteOrder(subdir.ByteOrder)
                end
            end
            -- upstream HandleTag: `$self->ProcessDirectory(\%dirInfo,
            -- $subTablePtr, $$subdir{ProcessProc} || $parms{ProcessProc})`
            -- -- a caller-supplied ProcessProc parm fills in when the
            -- SubDirectory itself declares none (e.g. MXF's local sets)
            self:ProcessDirectory(subInfo, subTable,
                subdir.ProcessProc or (parms and parms.ProcessProc))
            ExifTool.SetByteOrder(oldOrder)
            -- return now unless directory is writable as a block
            if not perlTruthy(tagInfo.Writable) then return nil end
        end
        -- otherwise just save the tag value (upstream returns the tag KEY
        -- from FoundTag here, not the value - no existing caller in this
        -- port used the return value before BigTIFF.lua needed it for
        -- SetGroup, so this was previously untested)
        return self:FoundTag(tagInfo, val)
    end
    return nil
end

--------------------------------------------------------------------------------
-- Add tag to hash of extracted information
-- Inputs: 0) ExifTool object reference
--         1) reference to tagInfo hash or tag name
--         2) data value (or reference to require hash if Composite)
--         3) optional family 0 group, 4) optional family 1 group
-- Returns: tag key or undef if no value
--
-- Handle a found tag (upstream FoundTag; subset without verbose/validate).
-- Inputs: 0) ExifTool object, 1) tagInfo hash or tag name,
--         2) value, 3-N) optional group0, group1 overrides
-- Returns: the tag key used, or nil if the tag was ignored
-- noRawConv: skips the generic RawConv step below -- used by
-- BuildCompositeTags, which applies a Composite tag's RawConv itself (as a
-- gate against the Require/Desire `vals` table, matching upstream's
-- @val-based Composite RawConv) before calling FoundTag with the already-
-- computed ValueConv result; running the generic (scalar-value) RawConv a
-- second time here would both double-apply it and hand it the wrong shape
-- of argument.
function ExifTool:FoundTag(tagInfo, value, g0, g1, noRawConv)
    local tag
    local tbl
    if type(tagInfo) == 'table' then
        tag = tagInfo.Name
        if not tag then return nil end
        tbl = tagInfo.Table
    else
        tag = tagInfo
        tbl = self:GetTagTable('lexiftool.ExifTool.Extra')
        tagInfo = self:GetTagInfo(tbl, tag)
        if not tagInfo then
            tagInfo = { Name = tag, Groups = allGroupsExifTool }
        end
        -- print verbose tag information (upstream FoundTag: only for the
        -- string-name form, which skips the per-entry verbose of the
        -- tag-table call sites)
        if optOn(self.OPTIONS.Verbose) then
            self:VerboseInfo(nil, tagInfo, { Value = value })
        end
    end
    local priority = tagInfo.Priority
    if priority == nil then
        priority = tbl and tbl.PRIORITY
        if priority == nil and tagInfo.Avoid then priority = 0 end
    end
    -- increase 0-priority tags if this is the priority directory (upstream:
    -- `$priority = 1 if not $priority and $$self{DIR_NAME} and
    --  $$self{DIR_NAME} eq $$self{PRIORITY_DIR}`) -- e.g. a DNG SubIFD's
    -- ImageWidth/ImageHeight (priority 0) displaces IFD0's 8x8 thumbnail
    if priority == 0 and self.DIR_NAME and self.PRIORITY_DIR and self.DIR_NAME == self.PRIORITY_DIR then
        priority = 1
    end
    g0 = g0 or self.SET_GROUP0
    g1 = g1 or self.SET_GROUP1

    -- RawConv
    -- (upstream has $tag in scope for the RawConv expression, and several use
    --  it -- ValidateImage takes it to decide whether the tag was specifically
    --  requested; without it that call crashed on a Casio2.jpg preview)
    if tagInfo.RawConv and not noRawConv then
        -- initialize @val for use in Composite RawConv expressions
        -- (port: a Composite RawConv takes @val as its value argument and
        --  the hash of tag keys, upstream's $val, after $tag -- as
        --  BuildCompositeTags hands it over)
        local val, valKeys = value, nil
        if type(value) == 'table' and value.ref == 'HASH' and tagInfo.IsComposite then
            val, valKeys = { }, value
            for k, key in pairs(value) do
                if k ~= 'ref' then val[k] = self.VALUE[key] end
            end
        end
        local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
        perl.SIG.__WARN__ = ExifTool.SetWarning
        ExifTool.evalWarning = nil
        value = tagInfo.RawConv(self, val, tag, valKeys)
        perl.SIG.__WARN__ = oldWarn
        -- (a Composite RawConv sets upstream's @grps through SET_GROUP0/1;
        --  returning its @val argument is upstream's `$val`, the tag key hash,
        --  and false is the undef of a Lua `cond and x`)
        if valKeys then
            g0, g1 = self.SET_GROUP0 or g0, self.SET_GROUP1 or g1
            self.SET_GROUP0, self.SET_GROUP1 = nil, nil
            if value == val then
                value = valKeys
            elseif value == false then
                value = nil
            end
        end
        if perlTruthy(ExifTool.evalWarning) then
            self:Warn('RawConv ' .. perl.str(tag) .. ': ' .. ExifTool.CleanWarning())
        end
        if value == nil then return nil end
    end

    -- ignore specified tags (AFTER doing RawConv if necessary!)
    if self.OPTIONS.IgnoreTags then
        if self.OPTIONS.IgnoreTags.all then
            if not (self.REQ_TAG_LOOKUP and self.REQ_TAG_LOOKUP[lc(tag)]) then return nil end
        else
            if self.OPTIONS.IgnoreTags[lc(tag)] then return nil end
        end
    end

    local valueHash = self.VALUE

    -- handle duplicate tag names
    local noListDel
    if valueHash[tag] ~= nil then
        -- add to list if there is an active list for this tag
        if self.LIST_TAGS[tagInfo] and self.NO_LIST ~= nil then
            tag = self.LIST_TAGS[tagInfo] -- use key from previous list tag
            -- accumulate list in TAG_EXTRA "NoList" element
            if not self.TAG_EXTRA[tag] then self.TAG_EXTRA[tag] = {} end
            local extra = self.TAG_EXTRA[tag]
            if extra.NoList ~= nil then
                extra.NoList[#extra.NoList + 1] = value
            else
                extra.NoList = { valueHash[tag], value }
            end
            noListDel = 1 -- set flag to delete this tag if re-listed
        elseif self.LIST_TAGS[tagInfo] then
            -- accumulate in list
            local key = self.LIST_TAGS[tagInfo]
            if type(valueHash[key]) ~= 'table' or valueHash[key][1] == nil then
                -- (upstream `ref $valueHash{$tag} ne 'ARRAY'`: a scalar or a
                --  structured HASH value gets wrapped in a list.  Lua can't
                --  distinguish a table's ARRAY/HASH ref type, so a missing
                --  [1] element stands in for "not an ARRAY" -- a JSON object
                --  stored as a structured value has string keys only, while
                --  an accumulated list always has [1] set)
                valueHash[key] = { valueHash[key] }
            end
            valueHash[key][#valueHash[key] + 1] = value
            return key
        end
        local nextInd = (self.DUPL_TAG[tag] or 0) + 1
        self.DUPL_TAG[tag] = nextInd
        local nextTag = tag .. ' (' .. nextInd .. ')'
        -- take the tag with highest priority
        -- promote an existing 0-priority tag to 1 so it takes precedence
        -- over a new 0-priority tag (upstream: `unless ($oldPriority)`,
        -- Perl-falsy on nil AND 0 -- 0 is truthy in Lua, so this must be
        -- spelled out explicitly, unlike a plain `if not oldPriority`)
        -- upstream: `unless ($oldPriority) { if ($$self{DOC_NUM} or $tag eq
        -- 'Warning' or not $$self{TAG_EXTRA}{$tag}{G3}) { $oldPriority = 1 }
        -- else { $oldPriority = 0 } }` -- a sub-document tag (DOC_NUM set)
        -- whose first occurrence never got an explicit priority defaults to
        -- 0 (loses to a same-priority main-document tag found later),
        -- unlike a main-document tag which defaults to 1
        local oldPriority = self.PRIORITY[tag]
        if oldPriority == nil or oldPriority == 0 or oldPriority == false then
            if perlTruthy(self.DOC_NUM) or tag == 'Warning' or not (self.TAG_EXTRA[tag] and perlTruthy(self.TAG_EXTRA[tag].G3)) then
                oldPriority = 1
            else
                oldPriority = 0
            end
        end
        -- upstream: `elsif ($$self{LOW_PRIORITY_DIR}{'*'} or ($$self{DIR_NAME}
        -- and $$self{LOW_PRIORITY_DIR}{$$self{DIR_NAME}})) { $priority = 0 }
        -- else { $priority = 1 }` -- a tag with no declared priority of its
        -- own defaults to 0 (not 1) when found in a LOW_PRIORITY_DIR
        -- directory (e.g. IFD1/PreviewIFD), so a same-named tag from the
        -- main IFD keeps priority over the thumbnail's copy
        if priority == nil then
            if self.LOW_PRIORITY_DIR['*'] or (self.DIR_NAME and self.LOW_PRIORITY_DIR[self.DIR_NAME]) then
                priority = 0
            else
                priority = 1
            end
        end
        -- upstream: `(not $$self{DOC_NUM} or ($$self{TAG_EXTRA}{$tag}{G3} and
        -- $$self{DOC_NUM} eq $$self{TAG_EXTRA}{$tag}{G3}))` -- a tag found
        -- while processing an embedded sub-document (DOC_NUM set, e.g.
        -- PanasonicRaw's JpgFromRaw) never overrides the primary slot of a
        -- same-named tag from a DIFFERENT document (the main file, or a
        -- different sub-document), regardless of priority, so a maker-note
        -- vendor's tag name collision inside an embedded preview doesn't
        -- clobber the main file's own same-named tag (verified against
        -- Panasonic.t's WBRedLevel/WBGreenLevel/WBBlueLevel, which exist
        -- both in Panasonic.rw2's own IFD0 and inside JpgFromRaw's nested
        -- JPEG's MakerNotes).
        local sameDoc = not perlTruthy(self.DOC_NUM) or
            (self.TAG_EXTRA[tag] and perlTruthy(self.TAG_EXTRA[tag].G3) and self.DOC_NUM == self.TAG_EXTRA[tag].G3)
        if priority >= oldPriority and sameDoc and not noListDel then
            -- move existing tag out of the way since this tag is higher priority
            self.PRIORITY[nextTag] = self.PRIORITY[tag]
            valueHash[nextTag] = valueHash[tag]
            self.FILE_ORDER[nextTag] = self.FILE_ORDER[tag]
            self.TAG_INFO[nextTag] = self.TAG_INFO[tag]
            self.TAG_EXTRA[nextTag] = self.TAG_EXTRA[tag]
            self.TAG_EXTRA[tag] = {}
            self.BOTH[tag] = nil
            -- update this key if used in a Composite tag
            if self.COMP_KEYS[tag] then
                for _, ref in ipairs(self.COMP_KEYS[tag]) do ref[1][ref[2]] = nextTag end
                self.COMP_KEYS[nextTag] = self.COMP_KEYS[tag]
                self.COMP_KEYS[tag] = nil
            end
        else
            tag = nextTag -- don't override the existing tag
        end
        self.PRIORITY[tag] = priority
        if noListDel then
            if not self.TAG_EXTRA[tag] then self.TAG_EXTRA[tag] = {} end
            self.TAG_EXTRA[tag].NoListDel = 1
        end
    elseif priority ~= nil and priority ~= 0 then
        -- upstream: `elsif ($priority) { ... }` -- Perl-falsy on 0, unlike
        -- Lua where 0 is truthy; a tag's first occurrence with an explicit
        -- `Priority = 0` (e.g. Exif.pm's "so PRIORITY_DIR takes precedence"
        -- tags) must NOT get PRIORITY[tag] stored here, or a later same-name
        -- duplicate's own priority-0-vs-oldPriority-1 comparison sees the
        -- wrong oldPriority and resolves the wrong tag as primary
        self.PRIORITY[tag] = priority
    end

    -- save the raw value, file order and tag info
    valueHash[tag] = value
    self.NUM_FOUND = (self.NUM_FOUND or 0) + 1
    self.FILE_ORDER[tag] = self.NUM_FOUND
    self.TAG_INFO[tag] = tagInfo
    if not self.TAG_EXTRA[tag] then self.TAG_EXTRA[tag] = {} end
    -- set dynamic groups 0 and 1 if necessary
    if g0 then self.TAG_EXTRA[tag].G0 = g0 end
    if g1 then self.TAG_EXTRA[tag].G1 = g1 end
    -- record which sub-document this tag came from (family 3 group), so a
    -- later same-named tag from a DIFFERENT sub-document (or the main file)
    -- knows not to silently take over the primary slot (see the DOC_NUM/G3
    -- check above)
    if perlTruthy(self.DOC_NUM) then
        self.TAG_EXTRA[tag].G3 = self.DOC_NUM
        self.HAS_DOC[self.DOC_NUM] = 1
        local docTop = perl.matches(perl.str(self.DOC_NUM), [[^(\d+)]])
        if docTop ~= nil then
            -- keep track of maximum 1st-level sub-document number
            if (self.DOC_COUNT or 0) < perl.num(docTop) then self.DOC_COUNT = perl.num(docTop) end
        end
    end

    -- remember this tagInfo if we will be accumulating values in a list
    -- (Perl's `$$tagInfo{List}` is false for the `List => 0` of a struct
    --  field that must not accumulate, e.g. XMP crs CorrectionMask Dabs)
    -- (but don't override earlier list if this may be deleted by NoListDel flag)
    if perlTruthy(tagInfo.List) and not perlTruthy(self.NO_LIST) and not noListDel then
        self.LIST_TAGS[tagInfo] = tag
    end

    -- validate tag if requested (but only for simple values -- could result
    -- in infinite recursion if called for a Composite tag (HASH ref value)
    -- because FoundTag is called in the middle of building Composite tags
    if perlTruthy(self.OPTIONS.Validate) and type(value) ~= 'table' then
        require('lexiftool.Validate').ValidateRaw(self, tag, value)
    end

    return tag
end

--------------------------------------------------------------------------------
-- Delete specified tag
-- Inputs: 0) ExifTool object ref, 1) tag key
function ExifTool:DeleteTag(tag)
    self.VALUE[tag] = nil
    self.FILE_ORDER[tag] = nil
    self.TAG_INFO[tag] = nil
    self.TAG_EXTRA[tag] = nil
    self.PRIORITY[tag] = nil
    self.BOTH[tag] = nil
end

-- (xpcall handler for the conversions in GetValue: a perl.die passes through
--  untouched, a Lua error keeps its traceback)
local function convErrorHandler(e)
    if perl.isDie(e) then return e end
    return debug.traceback(tostring(e), 2)
end

--------------------------------------------------------------------------------
-- Get tag value
-- Inputs: 0) ExifTool object reference
--         1) tag key or tag name with optional group names (case insensitive)
--            (or flattened tagInfo for getting field values, not part of public API)
--         2) [optional] Value type: PrintConv, ValueConv, Both, Raw, Bin or Rational, the
--            default is PrintConv or ValueConv, depending on the PrintConv option setting
--         3) raw field value (not part of public API)
-- Returns: Scalar context: tag value or undefined
--          List context: list of values or empty list
function ExifTool:GetValue(tag, type_, fieldValue)
    if type_ == nil then
        type_ = optOn(self.OPTIONS.PrintConv) and 'PrintConv' or 'ValueConv'
    end
    local rawValue = self.VALUE
    -- get the value of a structure field: `tag` is a flattened tagInfo and the
    -- raw field value comes in as the third argument (not part of the public
    -- API; note that type "Both" is not allowed for structure fields)
    local fieldInfo
    if type(tag) == 'table' then
        fieldInfo = tag
        tag = fieldInfo.Name
    end
    if fieldInfo == nil and rawValue[tag] == nil and not perl.isMatch(tag, ' ') then
        -- fix case of tag name
        -- (the grep /^$tag$/i over all keys; a key of another length can not
        --  match, so only same-length keys are lower-cased -- Composite
        --  values look up each missing Desire'd tag here)
        local lcTag = lc(tag)
        local len = #lcTag
        for k in pairs(rawValue) do
            if #k == len and lc(k) == lcTag then
                tag = k
                break
            end
        end
    end
    local value = fieldInfo and fieldValue or rawValue[tag]
    if value == nil then return nil end
    local tagInfo = fieldInfo or self.TAG_INFO[tag]
    -- a structure (or list of structures) is converted field by field
    if fieldInfo == nil and tagInfo and tagInfo.Struct and
        type(value) == 'table' and value.ref == nil then
        local XMPmod = require('lexiftool.XMP')
        if type_ ~= 'Both' then
            -- (note: ConvertStruct handles the filtering and escaping too if necessary)
            return XMPmod.ConvertStruct(self, tagInfo, value, type_)
        end
        local vConv = XMPmod.ConvertStruct(self, tagInfo, value, 'ValueConv')
        local pConv = XMPmod.ConvertStruct(self, tagInfo, value, 'PrintConv')
        -- (must not save these in self.BOTH because the values may have been escaped)
        return vConv, pConv
    end
    local convTypes = {}
    local both, valueConv
    if fieldInfo == nil and type_ ~= 'Raw' then
        -- use values we calculated already if we stored them
        both = self.BOTH[tag]
    end
    if both then
        if type_ == 'PrintConv' then
            value = both[2]
        elseif type_ == 'ValueConv' then
            value = both[1]
            if value == nil then value = both[2] end
        else
            valueConv, value = both[1], both[2]
        end
    elseif type_ ~= 'Raw' then
        convTypes[#convTypes + 1] = 'ValueConv'
        if type_ ~= 'ValueConv' then convTypes[#convTypes + 1] = 'PrintConv' end
    end
    -- upstream: override with our localized language PrintConv if available
    -- (only ever applies to PrintConv, keyed by the tag's *English* PrintConv
    -- string -- looked up once per GetValue call, not per list element)
    local langPrintConv
    if self.CUR_LANG and tagInfo then
        local langEntry = self.CUR_LANG[tagInfo.Name]
        if type(langEntry) == 'table' and type(langEntry.PrintConv) == 'table' then
            langPrintConv = langEntry.PrintConv
        end
    end

    -- apply one ValueConv/PrintConv (function, lookup table with optional
    -- OTHER fallback, '$val' binary-ref marker, or nil passthrough) to a
    -- single scalar value
    -- (@val and @prt of a Composite tag: the ValueConv and PrintConv values
    --  of its Require'd/Desire'd tags, collected on the first conversion)
    local compVals, compPrts
    local function applyOneConv(conv, v, convType)
        if conv == nil then
            return v
        elseif conv == '$val' then
            return { ref = 'SCALAR', value = v }
        elseif type(conv) == 'table' then
            -- look up converted value in hash
            local mapped = conv[v]
            if mapped == nil and type(v) == 'number' then
                mapped = conv[ExifTool.NumStr(v)]
            elseif mapped == nil and type(v) == 'string' then
                local n = tonumber(v)
                if n then mapped = conv[n] end
            end
            if mapped == nil and type(conv.OTHER) == 'function' then
                local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
                perl.SIG.__WARN__ = ExifTool.SetWarning
                ExifTool.evalWarning = nil
                mapped = conv.OTHER(v, nil, conv)
                perl.SIG.__WARN__ = oldWarn
                if perlTruthy(ExifTool.evalWarning) then
                    self:Warn(convType .. ' ' .. perl.str(tag) .. ': ' .. ExifTool.CleanWarning())
                end
            end
            local usedBitmask = false
            if mapped == nil then
                if conv.BITMASK then
                    mapped = ExifTool.DecodeBits(v, conv.BITMASK, tagInfo and tagInfo.BitsPerWord)
                    usedBitmask = true
                elseif tagInfo and tagInfo.PrintHex and v ~= nil and tonumber(v) and
                    math.tointeger(tonumber(v)) then
                    -- upstream: `sprintf('Unknown (0x%x)',$val)` when the tag has
                    -- PrintHex set and the value is an integer
                    mapped = sprintf('Unknown (0x%x)', tonumber(v))
                else
                    mapped = 'Unknown (' .. perl.str(v) .. ')'
                end
            end
            if langPrintConv and convType == 'PrintConv' then
                if usedBitmask then
                    -- upstream: `my @vals = split ', ', $value; foreach { $_
                    -- = $$tmp{$_} if defined $$tmp{$_} }` -- translate each
                    -- decoded bit name independently
                    local parts = {}
                    for rawPart in perl.str(mapped):gmatch('[^,]+') do
                        local part = rawPart:match('^[ \t\n\r\f\v]*(.-)[ \t\n\r\f\v]*$')
                        parts[#parts + 1] = langPrintConv[part] or part
                    end
                    mapped = table.concat(parts, ', ')
                else
                    -- (upstream's `$$tmp{$value}` stringifies a numeric
                    -- PrintConv result on the way into the hash, e.g.
                    -- CanonVRD's Rotation, whose PrintConv maps 1 => 90)
                    local key = type(mapped) == 'number' and ExifTool.NumStr(mapped) or mapped
                    if langPrintConv[key] ~= nil then
                        mapped = self:Decode(langPrintConv[key], 'UTF8')
                    end
                end
            end
            return mapped
        elseif type(conv) == 'function' then
            -- (upstream evals a conversion string: a Perl die inside it, e.g.
            --  log(0), leaves the value undefined and warns.  The port's
            --  stand-in is perl.die; any other error is a port bug and
            --  propagates with its traceback)
            local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
            perl.SIG.__WARN__ = ExifTool.SetWarning
            ExifTool.evalWarning = nil
            local ok, res
            if compVals == nil then
                ok, res = xpcall(conv, convErrorHandler, self, v, tag) -- (upstream's eval also sees $tag)
            elseif convType == 'ValueConv' then
                -- (a Composite ValueConv takes @val and @prt: `v` is @val)
                ok, res = xpcall(conv, convErrorHandler, self, v, compPrts)
            else
                -- (a Composite PrintConv takes $val, @val and @prt)
                ok, res = xpcall(conv, convErrorHandler, self, v, compVals, compPrts)
            end
            perl.SIG.__WARN__ = oldWarn
            if not ok then
                if not perl.isDie(res) then error(res, 0) end
                ExifTool.evalWarning = res.msg      -- ($@ and $evalWarning = $@)
                res = nil
            end
            if perlTruthy(ExifTool.evalWarning) then
                self:Warn(convType .. ' ' .. perl.str(tag) .. ': ' .. ExifTool.CleanWarning())
            end
            return res
        end
        return v
    end

    local val = value
    -- initialize array so we can iterate over values in list
    -- (RawJoin turns the list back into one space-separated string before the
    --  conversions run, the way the corresponding EXIF tag is converted)
    if type(val) == 'table' and val.ref == nil and tagInfo and tagInfo.RawJoin ~= nil then
        val = perl.join(' ', val)
    end
    for _, convType in ipairs(convTypes) do
        -- don't convert a scalar reference (binary value) unless the tag
        -- explicitly opts in (upstream: `last if ref $value eq 'SCALAR' and
        -- not $$tagInfo{ConvertBinary}`)
        if type(val) == 'table' and val.ref == 'SCALAR' and not (tagInfo and tagInfo.ConvertBinary) then
            break
        end
        local conv
        if convType == 'ValueConv' then
            conv = tagInfo and tagInfo.ValueConv
            if conv == nil and tagInfo and (tagInfo.ValueConvRef or tagInfo.Binary) then
                conv = '$val' -- return scalar reference for binary values
            end
        else
            conv = tagInfo and tagInfo.PrintConv
            if conv == false then
                -- explicitly no PrintConv (upstream `PrintConv => undef` present
                -- key suppresses the table PRINT_CONV default)
                conv = nil
            elseif conv == nil and tagInfo and tagInfo.Table then
                conv = tagInfo.Table.PRINT_CONV
            end
        end
        -- get values of required tags if this is a Composite tag
        if conv ~= nil and compVals == nil and type(val) == 'table' and val.ref == 'HASH' then
            -- disable escape of source values so we don't double escape them
            local oldEscape = self.ESCAPE_PROC
            self.ESCAPE_PROC = nil
            -- temporarily delete filter so it isn't applied to the Require'd values
            local oldFilter = self.OPTIONS.Filter
            self.OPTIONS.Filter = nil
            compVals, compPrts = {}, {}
            for k, key in pairs(val) do
                compVals[k], compPrts[k] = self:GetValue(key, 'Both')
                if compVals[k] == nil and tagInfo.Require and tagInfo.Require[k] then
                    self.OPTIONS.Filter = oldFilter
                    self.ESCAPE_PROC = oldEscape
                    return nil
                end
            end
            self.OPTIONS.Filter = oldFilter
            self.ESCAPE_PROC = oldEscape
            -- set $val to \@val for a ValueConv (the port's Composite
            -- conversions take the @val table), or $val[0]
            if convType == 'ValueConv' then val = compVals else val = compVals[0] end
        end
        local convList
        -- split into list if conversion is an array
        -- (upstream `ref $conv eq 'ARRAY'`; a Lua table whose first element is
        -- a table, a function or `false` (upstream undef) is the
        -- array-of-conversions form -- a plain lookup table maps its keys to
        -- strings or numbers only)
        local first
        if type(conv) == 'table' then first = conv[1] end
        if first == false or type(first) == 'table' or type(first) == 'function' then
            convList = conv
            conv = convList[1]
            local valList = {}
            if type(val) == 'table' and val.ref == nil then
                for i = 1, #val do valList[i] = val[i] end
            else
                for w in perl.str(val):gmatch('[^ \t\n\r\f\v]+') do valList[#valList + 1] = w end
            end
            -- reorganize list if specified (Note: The writer currently doesn't
            -- relist values, so they may be grouped but the order must not change)
            local relist = tagInfo and tagInfo.Relist
            if relist then
                local newList = {}
                for _, oldIndex in ipairs(relist) do
                    local newVal
                    if type(oldIndex) == 'table' then
                        local join = {}
                        for _, ix in ipairs(oldIndex) do
                            -- (upstream's Relist indices are 0-based)
                            if valList[ix + 1] ~= nil then join[#join + 1] = valList[ix + 1] end
                        end
                        if #join > 0 then newVal = table.concat(join, ' ') end
                    else
                        newVal = valList[oldIndex + 1]
                    end
                    if newVal ~= nil then newList[#newList + 1] = newVal end
                end
                val = newList
            else
                val = valList
            end
            if val[1] == nil then return nil end
        end
        -- List tags store their raw value as a plain array (upstream: `ref
        -- $value eq 'ARRAY'`); apply the conversion to each element rather
        -- than to the whole array
        if type(val) == 'table' and val.ref == nil and val[1] ~= nil and val ~= compVals then
            local mappedList = {}
            for i = 1, #val do
                if convList and i > 1 then
                    -- step to the conversion for this list position
                    local nextConv = convList[i]
                    if nextConv == 'REPEAT' then
                        convList = nil
                    else
                        conv = nextConv
                    end
                end
                mappedList[i] = applyOneConv(conv, val[i], convType)
            end
            value = mappedList
        else
            value = applyOneConv(conv, val, convType)
        end
        -- upstream GetValue: `return () unless defined $value;` -- once a
        -- conversion (typically ValueConv) yields undef, the whole function
        -- bails immediately instead of feeding nil into the next conversion
        -- (e.g. PrintConv), which would crash a PrintConv function written
        -- to assume a concrete raw value (H264 Camera1's Focus bitwise math)
        if value == nil then return nil end
        -- join back into single value if split for conversion list
        if convList and type(value) == 'table' and value.ref == nil then
            for i = 1, #value do
                if type(value[i]) == 'number' then value[i] = ExifTool.NumStr(value[i]) end
            end
            value = table.concat(value, convType == 'PrintConv' and '; ' or ' ')
        end
        if convType == 'ValueConv' then valueConv = value end
        -- chain the conversions: the next conversion sees this value
        val = value
    end
    if type_ == 'Both' then
        -- save both (unescaped) values because we often need them again
        -- (Composite tags need "Both" and often Require one tag for various Composite tags)
        if not both then self.BOTH[tag] = { valueConv or value, value } end
        -- escape values if necessary
        if self.ESCAPE_PROC then
            value = ExifTool.DoEscape(value, self.ESCAPE_PROC)
            if valueConv ~= nil then
                valueConv = ExifTool.DoEscape(valueConv, self.ESCAPE_PROC)
            else
                valueConv = value
            end
        elseif valueConv == nil then
            -- $valueConv is undefined if there was no print conversion done
            valueConv = value
        end
        local _
        _, value = self:Filter(self.OPTIONS.Filter, value)
        -- return Both values as a list (ValueConv, PrintConv)
        return valueConv, value
    end
    -- escape value if necessary
    if self.ESCAPE_PROC then value = ExifTool.DoEscape(value, self.ESCAPE_PROC) end

    -- filter if necessary
    if self.OPTIONS.Filter ~= nil and type_ == 'PrintConv' then
        local _
        _, value = self:Filter(self.OPTIONS.Filter, value)
    end
    -- join list values into a delimited string (unless List option is used)
    if type(value) == 'table' and value.ref == nil then
        -- the ListItem option returns one specific item instead
        -- (upstream: `$value = $$value[$$self{OPTIONS}{ListItem}]`)
        local listItem = self.OPTIONS.ListItem
        if listItem ~= nil then
            -- (upstream's index is 0-based, and a negative one counts from
            --  the end of the list, as any Perl array index does)
            local idx = tonumber(listItem) or 0
            idx = idx < 0 and math.ceil(idx) or math.floor(idx) -- (Perl int())
            if idx < 0 then idx = #value + idx end
            value = value[idx + 1]
            if type(value) == 'number' then value = ExifTool.NumStr(value) end
            return value
        end
        local hasRef = false
        for i = 1, #value do
            if type(value[i]) == 'table' then hasRef = true break end
        end
        if type_ == 'PrintConv' and not optOn(self.OPTIONS.List) and not hasRef then
            -- stringify each element Perl-style (a whole-number float list
            -- element, e.g. KeyFramePositions' 1463.0, must print as "1463",
            -- matching `join $listSep, @$val` in the upstream exiftool script)
            for i = 1, #value do
                if type(value[i]) == 'number' then value[i] = ExifTool.NumStr(value[i]) end
            end
            value = table.concat(value, self.OPTIONS.ListSep or ', ')
        end
    end
    -- Perl-style number stringification for the returned value
    if type(value) == 'number' then
        value = ExifTool.NumStr(value)
    end
    return value
end

-- vendored Lang/*.pm translation tables, loaded lazily (mirrors Charset.LoadCharset);
-- all of `langs` except the default 'en' are ported, generated by
-- tools/gen_lang.pl
local langCache = {}

local function loadLang(name)
    if langCache[name] ~= nil then return langCache[name] end
    local ok, mod = pcall(require, 'lexiftool.Lang.' .. name)
    local tbl = (ok and mod) or false
    langCache[name] = tbl
    return tbl
end

--------------------------------------------------------------------------------
-- Decode string with specified encoding
-- Inputs: 0) ExifTool object ref, 1) string to decode
--         2) source character set name (undef for current Charset)
--         3) optional source byte order (2-byte and 4-byte fixed-width sets only)
--         4) optional destination character set (defaults to Charset setting)
--         5) optional destination byte order (2-byte and 4-byte fixed-width only)
-- Returns: string in destination encoding
-- Note: ExifTool ref may be undef if character both character sets are provided
--       (but in this case no warnings will be issued)
-- luacheck: ignore 212
function ExifTool.Decode(self, val, from, fromOrder, to, toOrder)
    if not from then from = self.OPTIONS.Charset end
    if not to then to = self and self.OPTIONS.Charset end
    local len = perl.length(val)
    if from ~= to and len and len > 0 then
        local cs1 = Charset.csType[from]
        local cs2 = Charset.csType[to]
        if cs1 and cs2 and (cs2 & 0x002) == 0 then
            -- treat as straight ASCII if no character will need remapping
            if (cs1 | cs2) & 0x680 ~= 0 or perl.matches(val, [=[[\x80-\xff]]=]) then
                local uni = Charset.Decompose(self, val, from, fromOrder)
                val = Charset.Recompose(self, uni, to, toOrder)
            end
        elseif self then
            local set = cs1 and to or from
            if not self['DecodeWarn' .. set] then
                self:Warn('Unsupported character set (' .. set .. ')')
                self['DecodeWarn' .. set] = 1
            end
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Encode string (in Charset encoding) to specified encoding
-- Inputs: 0) ExifTool object ref, 1) string, 2) destination character set name,
--         3) optional destination byte order (2-byte and 4-byte fixed-width sets only)
-- Returns: string in specified encoding
function ExifTool.Encode(self, val, to, toOrder)
    return self:Decode(val, nil, nil, to, toOrder)
end

--------------------------------------------------------------------------------
-- Decode bit mask
-- Inputs: 0) value to decode, 1) Reference to hash for decoding (or undef)
--         2) optional bits per word (defaults to 32)
function ExifTool.DecodeBits(vals, lookup, bits)
    bits = bits or 32
    local bitList = {}
    local num = 0
    for w in perl.str(vals):gmatch('[^ \t\n\r\f\v]+') do
        -- (Perl's `$val & (1 << $i)` numifies the word: leading digits of a
        --  non-numeric string count, the rest is 0)
        local wval = perl.int(w)
        for i = 0, bits - 1 do
            if wval & (1 << i) ~= 0 then
                local n = i + num
                if not lookup then
                    bitList[#bitList + 1] = perl.str(n)
                elseif lookup[n] then
                    bitList[#bitList + 1] = lookup[n]
                else
                    bitList[#bitList + 1] = '[' .. n .. ']'
                end
            end
        end
        num = num + bits
    end
    if #bitList == 0 then return '(none)' end
    return table.concat(bitList, lookup and ', ' or ',')
end

--------------------------------------------------------------------------------
-- Validate an extracted image and repair if necessary
-- Inputs: 0) ExifTool object reference, 1) image reference, 2) tag name or key
-- Returns: image reference or undef if it wasn't valid
-- Note: should be called from RawConv, not ValueConv
function ExifTool:ValidateImage(imageData, tag)
    if imageData == 'none' then return nil end
    -- the first byte of the preview of some Minolta cameras is wrong, so check
    -- for this and set it back to 0xff if necessary
    imageData = imageData:gsub('^.(\216\255\219)', '\255%1', 1)
    if not (imageData:match('^Binary data') or imageData:sub(1, 3) == '\255\216\255' or
            optOn(self.OPTIONS.IgnoreMinorErrors)) then
        -- issue warning only if the tag was specifically requested
        -- (a caller that passes no tag can't have been requested by name --
        --  upstream always has $tag in scope in a RawConv, so this guards
        --  against a port-side call site that forgot to pass it on)
        local tagName = tag and ExifTool.GetTagName(tag)
        if tagName and self.REQ_TAG_LOOKUP and self.REQ_TAG_LOOKUP[lc(tagName)] then
            self:Warn(tag .. ' is not a valid JPEG image', 1)
            return nil
        end
    end
    return imageData
end

--------------------------------------------------------------------------------
-- Parse function arguments and set member variables accordingly
-- Inputs: 0) ExifTool object reference, 1-N) list of arguments
-- (Perl tells a tag list from an options hash by its reference type; a Lua
--  table is both, so a table with a [1] entry -- or an empty one -- is taken
--  as the tag list and any other table as the options hash. The file forms
--  are this port's: a file handle is userdata, a RandomAccess object a table
--  with that metatable.)
function ExifTool:ParseArguments(...)
    local options = self.OPTIONS
    local oldGroupOpts = {}
    for k in pairs(options) do
        if perl.matches(k, '^Group') then oldGroupOpts[#oldGroupOpts + 1] = k end
    end
    local exclude, wasExcludeOpt = {}, false

    self.REQUESTED_TAGS = {}
    if not self.ReqTagAlreadySet then self.REQ_TAG_LOOKUP = {} end
    self.EXCL_TAG_LOOKUP = {}
    self.IO_TAG_LIST = nil
    self.EXCL_XMP_LOOKUP = nil

    -- handle our input arguments
    for n = 1, select('#', ...) do
        local arg = select(n, ...)
        if type(arg) == 'table' and getmetatable(arg) == RandomAccess then
            self.RAF = arg
            self.FILENAME = ''
        elseif type(arg) == 'table' and (arg[1] ~= nil or next(arg) == nil) then
            self.IO_TAG_LIST = arg
            for _, t in ipairs(arg) do
                local excl = perl.matches(t, '^-(.*)')
                if excl then
                    exclude[#exclude + 1] = excl
                else
                    self.REQUESTED_TAGS[#self.REQUESTED_TAGS + 1] = t
                end
            end
        elseif type(arg) == 'table' then
            -- (upstream iterates `keys %$arg` in hash order; sorted here so
            --  the options are applied the same way every run)
            local opts = {}
            for opt in pairs(arg) do opts[#opts + 1] = opt end
            tsort(opts)
            for _, opt in ipairs(opts) do
                -- a single new group option overrides all old group options
                if #oldGroupOpts > 0 and perl.matches(opt, '^Group') then
                    for _, g in ipairs(oldGroupOpts) do options[g] = nil end
                    oldGroupOpts = {}
                end
                self:Options(opt, arg[opt])
                if opt == 'Exclude' then wasExcludeOpt = true end
            end
        elseif type(arg) == 'userdata' then
            if self.RAF == nil then
                self.RAF = RandomAccess.new(arg)
                -- set filename to empty string to indicate that
                -- we have a file but we didn't open it
                self.FILENAME = ''
            end
        elseif self.FILENAME ~= nil then
            local excl = perl.matches(arg, '^-(.*)')
            if excl then
                exclude[#exclude + 1] = excl
            else
                self.REQUESTED_TAGS[#self.REQUESTED_TAGS + 1] = arg
            end
        else
            self.FILENAME = arg
        end
    end
    -- add additional requested tags to lookup
    if options.RequestTags then
        for _, t in ipairs(options.RequestTags) do self.REQ_TAG_LOOKUP[t] = 1 end
    end
    -- expand shortcuts in tag arguments if provided
    self:setRequestedTags(self.REQUESTED_TAGS)
    if #exclude > 0 or wasExcludeOpt then
        -- must add existing excluded tags
        if options.Exclude then
            for _, e in ipairs(options.Exclude) do exclude[#exclude + 1] = e end
        end
        options.Exclude = exclude
        -- expand shortcuts in new exclude list
        ExifTool.ExpandShortcuts(options.Exclude, 1) -- (also remove '#' suffix)
    end
    -- generate lookup for excluded tags
    if options.Exclude then
        for _, e in ipairs(options.Exclude) do
            local name = perl.matches(e, [[([-\w]+)#?$]])
            if name then self.EXCL_TAG_LOOKUP[lc(name)] = 1 end
            local xmp = perl.matches(e, [[(?i)(xmp-.*:[-\w]+)#?]])
            if xmp then
                if not self.EXCL_XMP_LOOKUP then self.EXCL_XMP_LOOKUP = {} end
                self.EXCL_XMP_LOOKUP[lc(xmp)] = 1
            end
        end
        -- exclude list is used only for EXCL_TAG_LOOKUP when TAGS_FROM_FILE is set
        if self.TAGS_FROM_FILE then options.Exclude = nil end
    end
end

--------------------------------------------------------------------------------
-- Remove specified tags from returned tag list, updating indices in other lists
-- Inputs: 0) tag list ref, 1) index list ref, 2) index list ref, 3) hash ref,
--         4) true to include tags from hash instead of excluding
-- Returns: nothing, but updates input lists
-- (upstream replaces the caller's list through `$_[0]`; Lua has no aliased
--  arguments, so the filtered list is returned instead, and the two index
--  lists -- 0-based like upstream's -- are updated in place)
function ExifTool.RemoveTagsFromList(tags, list1, list2, exclude, inv)
    local filteredTags = {}
    local function xor(a, b) return (a and not b) or (b and not a) end

    if #list1 > 0 or #list2 > 0 then
        for i = #tags - 1, 0, -1 do
            local tag = tags[i + 1]
            if xor(exclude[tag] ~= nil, inv) then
                -- remove index of excluded tag from each list
                for _, list in ipairs({ list1, list2 }) do
                    local new = {}
                    for _, x in ipairs(list) do
                        if x < i then
                            new[#new + 1] = x
                        elseif x ~= i then
                            new[#new + 1] = x - 1
                        end
                    end
                    for k = #list, 1, -1 do list[k] = nil end
                    for k, x in ipairs(new) do list[k] = x end
                end
            else
                table.insert(filteredTags, 1, tag)
            end
        end
    else
        for _, tag in ipairs(tags) do
            if not xor(exclude[tag] ~= nil, inv) then filteredTags[#filteredTags + 1] = tag end
        end
    end
    return filteredTags     -- update tag list
end

--------------------------------------------------------------------------------
-- Copy tags from alternate input file
-- Inputs: 0) ExifTool ref, 1) family 8 group, 2) list ref for tag keys to copy
-- - updates tag key list to match keys newly added to self
function ExifTool:CopyAltInfo(g8, tags)
    local num = g8:match('(%d+)')
    if not num then return end
    local et = self.ALT_EXIFTOOL[g8]
    if not et then return end
    local altOrder = (tonumber(num) + 1) * 100000   -- increment file order
    for i, tag in ipairs(tags) do
        local vtag = perl.subst(tag, '( |$)', ' #[' .. g8 .. ']')
        if self.VALUE[vtag] == nil then
            self.VALUE[vtag] = et.VALUE[tag]
            self.TAG_INFO[vtag] = et.TAG_INFO[tag]
            self.TAG_EXTRA[vtag] = et.TAG_EXTRA[tag] or {}
            self.FILE_ORDER[vtag] = (et.FILE_ORDER[tag] or 0) + altOrder
            -- Upstream has no equivalent line, because it stores a Composite
            -- tag's VALUE as a map of the tag keys it was built from and only
            -- resolves that map when the value is read -- after this copy that
            -- resolution happens against the MAIN file, so upstream's
            -- "File1:all" really does print the main file's ImageSize/Aperture/
            -- LightValue under the alternate file's keys. This port stores the
            -- finished ValueConv/PrintConv pair in BOTH instead, so the pair
            -- has to travel with the value: without it a copied Composite tag
            -- would re-run its PrintConv against the main file's tags, which
            -- for GPSPosition means reading a GPSLatitude that isn't there.
            -- The result is that a copied Composite tag keeps the alternate
            -- file's own value here.
            self.BOTH[vtag] = et.BOTH[tag]
        end
        tags[i] = vtag
    end
end

--------------------------------------------------------------------------------
-- Set list of found tags from previously requested tags
-- Inputs: 0) ExifTool object reference
-- Returns: 0) Reference to list of found tag keys (in order of requested tags)
--          1) Reference to list of indices for tags requested by value
--          2) Reference to list of indices for tags specified by wildcard or "all"
-- Notes: index lists are returned in increasing order
-- (Lua has no wantarray: all three are always returned; the indices are
--  0-based like upstream's.  Where upstream takes `keys %$tagHash` in hash
--  order, the keys are sorted by file order here so the result is the same
--  every run.)
function ExifTool:SetFoundTags()
    local options = self.OPTIONS
    local reqTags = self.REQUESTED_TAGS or {}
    local duplicates = options.Duplicates
    local exclude = options.Exclude
    local fileOrder = self.FILE_ORDER
    local groupOptions = {}
    -- ignore empty group options
    local optNames = {}
    for opt in pairs(options) do
        if perl.matches(opt, '^Group') then optNames[#optNames + 1] = opt end
    end
    tsort(optNames)
    for _, opt in ipairs(optNames) do
        if perlTruthy(options[opt]) then groupOptions[#groupOptions + 1] = opt end
    end
    local doDups = perlTruthy(duplicates) or exclude ~= nil or #groupOptions > 0
    local tag, rtnTags
    local byValue, wildTags = {}, {}

    -- (`keys %$tagHash`, see above)
    local function sortedKeys(tagHash, order)
        local keys = {}
        for k in pairs(tagHash) do keys[#keys + 1] = k end
        tsort(keys, function(a, b)
            local fa, fb = order[a] or 999, order[b] or 999
            if fa ~= fb then return fa < fb end
            return perl.lt(a, b)
        end)
        return keys
    end

    -- only return requested tags if specified
    if #reqTags > 0 then
        rtnTags = {}
        -- scan through the requested tags and generate a list of tags we found
        local tagHash = self.VALUE
        for _, reqTag in ipairs(reqTags) do
            local matches, group, allGrp, allTag, byVal, g8 = {}, nil, false, false, false, nil
            local et = self
            local g, t = perl.matches(reqTag, '^(.*):(.+)')
            if g then
                group, tag = g, t
                if perl.matches(group, [[(?i)^(\*|all)$]]) then
                    allGrp = true
                else
                    local num = perl.matches(reqTag, [[(?i)\bfile(\d+):]])
                    if num then
                        g8 = 'File' .. num
                        et = self.ALT_EXIFTOOL[g8] or self
                        fileOrder = et.FILE_ORDER
                        tagHash = et.VALUE
                    elseif not perl.matches(group, [[^[-\w:]*$]]) then
                        self:Warn("Invalid group name '" .. group .. "'")
                        group = 'invalid'
                    end
                end
            else
                tag = reqTag
            end
            if perl.matches(tag, '#$') then
                tag = perl.subst(tag, '#$', '')
                if perlTruthy(options.PrintConv) then byVal = true end
            end
            if tagHash[reqTag] ~= nil and not doDups then
                matches[1] = tag
            elseif perl.matches(tag, [[(?i)^(\*|all)$]]) then
                -- tag name of '*' or 'all' matches all tags
                for k in pairs(tagHash) do
                    if doDups or allGrp then
                        if not k:find('#', 1, true) then matches[#matches + 1] = k end
                    elseif not k:find(' ', 1, true) then
                        matches[#matches + 1] = k
                    end
                end
                if #matches == 0 then goto nextReqTag end -- don't want entry in list for '*' tag
                allTag = true
            elseif perl.matches(tag, '[*?]') then
                -- allow wildcards in tag names
                tag = perl.tr(tag, '-_A-Za-z0-9*?', '', 'dc') -- sterilize
                tag = perl.subst(tag, [[\*]], '[-\\w]*', 'g')
                tag = perl.subst(tag, [[\?]], '[-\\w]', 'g')
                if doDups or allGrp then tag = tag .. '( \\(.*)?' end
                for k in pairs(tagHash) do
                    if perl.isMatchDyn(k, '(?i)^' .. tag .. '$') then matches[#matches + 1] = k end
                end
                if #matches == 0 then goto nextReqTag end -- don't want entry in list for wildcard tags
                allTag = true
            elseif doDups or group ~= nil then
                tag = perl.tr(tag, '-_A-Za-z0-9', '', 'dc') -- sterilize
                -- must also look for tags like "Tag (1)"
                -- (but be sure not to match temporary ValueConv entries like "Tag #")
                for k in pairs(tagHash) do
                    if perl.isMatchDyn(k, '(?i)^' .. tag .. [[( \(|$)]]) then matches[#matches + 1] = k end
                end
            elseif perl.matches(tag, [[^[-\w]+$]]) then
                -- find first matching value
                -- (use in list context to return value instead of count)
                for k in pairs(tagHash) do
                    if perl.isMatchDyn(k, '(?i)^' .. tag .. '$') then matches[1] = k break end
                end
            else
                self:Warn("Invalid tag name '" .. tag .. "'")
            end
            if group ~= nil and not allGrp then
                -- keep only specified group
                matches = et:GroupMatches(group, matches)
                if not (#matches > 0 or not allTag) then goto nextReqTag end
            end
            if #matches > 1 then
                -- maintain original file order for multiple tags
                tsort(matches, function(a, b)
                    local fa, fb = fileOrder[a] or 999, fileOrder[b] or 999
                    if fa ~= fb then return fa < fb end
                    return perl.lt(a, b)
                end)
                -- return only the highest priority tag unless duplicates wanted
                if not (doDups or allTag or allGrp) then
                    tag = table.remove(matches, 1)
                    local oldPriority = et.PRIORITY[tag] or 1
                    if oldPriority == 0 then oldPriority = 1 end
                    for _, m in ipairs(matches) do
                        local priority = et.PRIORITY[m]
                        if priority == nil then priority = 1 end
                        if priority >= oldPriority then
                            tag = m
                            oldPriority = priority
                            if oldPriority == 0 then oldPriority = 1 end
                        end
                    end
                    matches = { tag }
                end
            elseif #matches == 0 then
                -- put entry in return list even without value (value is undef)
                matches[1] = byVal and (tag .. ' #(0)') or (tag .. ' (0)')
                -- bogus file order entry to avoid warning if sorting in file order
                self.FILE_ORDER[matches[1]] = 999999999
            end
            -- copy over necessary information for tags from alternate files
            if g8 then
                self:CopyAltInfo(g8, matches)
                -- restore variables to original values for main file
                fileOrder = self.FILE_ORDER
                tagHash = self.VALUE
            end
            -- save indices of tags extracted by value
            if byVal then
                for i = #rtnTags, #rtnTags + #matches - 1 do byValue[#byValue + 1] = i end
            end
            -- save indices of wildcard tags
            if allTag then
                for i = #rtnTags, #rtnTags + #matches - 1 do wildTags[#wildTags + 1] = i end
            end
            for _, m in ipairs(matches) do rtnTags[#rtnTags + 1] = m end
            ::nextReqTag::
        end
    else
        -- no requested tags, so we want all tags
        local allTags = {}
        if doDups then
            allTags = sortedKeys(self.VALUE, fileOrder)
        else
            -- only include tag if it doesn't end in a copy number
            for _, k in ipairs(sortedKeys(self.VALUE, fileOrder)) do
                if not k:find(' ', 1, true) then allTags[#allTags + 1] = k end
            end
        end
        rtnTags = allTags
    end

    -- filter excluded tags and group options
    -- (the port also publishes the excluded keys as EXCLUDED_TAGS, for the
    --  CLI's own duplicate handling -- see main.lua)
    -- (upstream's `while (...) { ... last; }` is a block to break out of;
    --  here an `if` with a goto to its end)
    self.EXCLUDED_TAGS = nil
    if (exclude ~= nil or #groupOptions > 0) and #rtnTags > 0 then
        if exclude ~= nil then
            local excludeHash = {}
            for _, pat in ipairs(exclude) do
                local group
                local g, t = perl.matches(pat, '^(.*):(.+)')
                if g then
                    group, tag = g, t
                    if perl.matches(group, [[(?i)^(\*|all)$]]) then
                        group = nil
                    elseif not perl.matches(group, [[^[-\w:]*$]]) then
                        self:Warn("Invalid group name '" .. group .. "'")
                        group = 'invalid'
                    end
                else
                    tag = pat
                end
                local matches = {}
                if perl.matches(tag, [[(?i)^(\*|all)$]]) then
                    for k, m in ipairs(rtnTags) do matches[k] = m end
                else
                    -- allow wildcards in tag names
                    tag = perl.subst(tag, [[\*]], '[-\\w]*', 'g')
                    tag = perl.subst(tag, [[\?]], '[-\\w]', 'g')
                    for _, m in ipairs(rtnTags) do
                        if perl.isMatchDyn(m, '(?i)^' .. tag .. '( |$)') then matches[#matches + 1] = m end
                    end
                end
                if perlTruthy(group) and #matches > 0 then
                    matches = self:GroupMatches(group, matches)
                end
                for _, m in ipairs(matches) do excludeHash[m] = 1 end
            end
            self.EXCLUDED_TAGS = excludeHash
            if next(excludeHash) then
                -- remove excluded tags from return list(s)
                rtnTags = ExifTool.RemoveTagsFromList(rtnTags, byValue, wildTags, excludeHash)
                if #rtnTags == 0 then goto doneFilter end -- all done if nothing left
            end
            if perlTruthy(duplicates) and #groupOptions == 0 then goto doneFilter end
        end
        -- filter groups if requested, or to remove duplicates
        local keepTags, wantGroup = {}, {}
        local allGroups = 1
        -- build hash of requested/excluded group names for each group family
        local wantOrder = 0
        local families = {}   -- (upstream's `keys %wantGroup`, in the order first seen)
        for _, groupOpt in ipairs(groupOptions) do
            local family = perl.matches(groupOpt, [[^Group(\d*(:\d+)*)]])
            if family then
                if family == '' then family = '0' end
                if not wantGroup[family] then
                    wantGroup[family] = {}
                    families[#families + 1] = family
                end
                local groupList = options[groupOpt]
                if type(groupList) ~= 'table' then groupList = { groupList } end
                for _, g in ipairs(groupList) do
                    -- groups have priority in order they were specified
                    wantOrder = wantOrder + 1
                    local groupName, want
                    local neg = perl.matches(g, '^-(.*)')
                    if neg then
                        -- excluded group begins with '-'
                        groupName = neg
                        want = 0            -- we don't want tags in this group
                    else
                        groupName = g
                        want = wantOrder    -- we want tags in this group
                        allGroups = 0       -- don't want all groups if we requested one
                    end
                    wantGroup[family][groupName] = want
                end
            end
        end
        -- loop through all tags and decide which ones we want
        local bestTag = {}
        for _, t in ipairs(rtnTags) do
            tag = t
            local wantTag = allGroups   -- want tag by default if want all groups
            for _, family in ipairs(families) do
                local fam = tonumber(family) or family
                local group = self:GetGroup(tag, fam)
                local wanted = wantGroup[family][group]
                if wanted ~= nil then
                    if wanted == 0 then goto nextGrTag end  -- skip tag if group excluded
                    -- take lowest non-zero want flag
                    if not (wantTag ~= 0 and wantTag < wanted) then wantTag = wanted end
                end
            end
            if wantTag == 0 then goto nextGrTag end
            if perlTruthy(duplicates) then
                keepTags[tag] = 1
                goto nextGrTag
            end
            do
                -- determine which tag we want to keep
                local tagName = ExifTool.GetTagName(tag)
                local best = bestTag[tagName]
                if best ~= nil then
                    if wantTag > keepTags[best] then goto nextGrTag end
                    if wantTag == keepTags[best] then
                        -- want two tags with the same name -- keep the latest one
                        local tagNum = perl.matches(tag, [[ \((\d+)\)$]])
                        if tagNum then
                            local bestNum = perl.matches(best, [[ \((\d+)\)$]])
                            if not bestNum or tonumber(bestNum) > tonumber(tagNum) then goto nextGrTag end
                        end
                    end
                    -- this tag is better, so delete old best tag
                    keepTags[best] = nil
                end
                keepTags[tag] = wantTag     -- keep this tag (for now...)
                bestTag[tagName] = tag      -- this is our current best tag
            end
            ::nextGrTag::
        end
        -- include only tags we want to keep in return lists
        rtnTags = ExifTool.RemoveTagsFromList(rtnTags, byValue, wildTags, keepTags, 1)
    end
    ::doneFilter::
    self.FOUND_TAGS = rtnTags     -- save found tags

    -- return reference to found tag keys (and list of indices of tags to extract by value)
    return rtnTags, byValue, wildTags
end

--------------------------------------------------------------------------------
-- Get list of found tags in specified sort order
-- Inputs: 0) ExifTool object reference, 1) sort order ('File', 'Input', ...)
--         2) secondary sort order
-- Returns: List of tag keys in specified order
-- Notes: If not specified, sort order is taken from OPTIONS
function ExifTool:GetFoundTags(sort, sort2)
    local foundTags = self.FOUND_TAGS or self:SetFoundTags()
    if not foundTags then return nil end
    return self:GetTagList(foundTags, sort, sort2)
end

--------------------------------------------------------------------------------
-- Get list of requested tags
-- Inputs: 0) ExifTool object reference
-- Returns: List of requested tag keys
function ExifTool:GetRequestedTags()
    return self.REQUESTED_TAGS or {}
end

--------------------------------------------------------------------------------
-- Inputs: 0) ExifTool object reference
--         1) [optional] reference to info hash or tag list ref (default is found tags)
--         2) [optional] sort order ('File', 'Input', ...)
--         3) [optional] secondary sort order
-- Returns: List of tags in specified order
--
-- Return a list of found tags in the specified sort order (upstream
-- GetTagList subset: 'GroupN' sort by group order then file order)
--
-- (Perl tells the info hash from the tag list by its reference type; here a
--  table with a [1] entry is the list.  Upstream returns a hash's keys in
--  hash order when no sort order is given; this port sorts them by file
--  order instead, so the result is the same every run.)
function ExifTool:GetTagList(info, sort, sort2)
    local foundTags
    local isList = false
    if type(info) == 'table' and info[1] ~= nil then
        foundTags = info
        isList = true
    elseif type(info) == 'table' then
        foundTags = {}
        for k in pairs(info) do foundTags[#foundTags + 1] = k end
    end
    local fileOrder = self.FILE_ORDER

    if foundTags then
        -- make sure a FILE_ORDER entry exists for all tags
        -- (note: already generated bogus entries for FOUND_TAGS case below)
        for _, t in ipairs(foundTags) do
            if fileOrder[t] == nil then fileOrder[t] = 999 end
        end
    else
        if info and not sort then sort = info end
        foundTags = self.FOUND_TAGS or self:SetFoundTags()
        if not foundTags then return nil end
        isList = true
    end
    if not sort then sort = self.OPTIONS.Sort end

    -- return original list if no sort order specified
    if isList and not (sort and sort ~= 'Input') then
        local list = {}
        for k, t in ipairs(foundTags) do list[k] = t end
        return list
    end
    if isList then
        -- (sorted below: work on a copy, the caller's list stays as it is)
        local list = {}
        for k, t in ipairs(foundTags) do list[k] = t end
        foundTags = list
    end

    if not sort or sort == 'Input' then
        tsort(foundTags, function(a, b)
            return (fileOrder[a] or 999) < (fileOrder[b] or 999)
        end)
        return foundTags
    end

    if sort == 'Tag' or sort == 'Alpha' then
        tsort(foundTags)
        return foundTags
    end
    -- 'Descr': alphabetical by the DESCRIPTION rather than the tag name, which
    -- is what -sort uses for the description-based output formats
    -- (exiftool:1598). Ties keep file order so the result stays stable.
    if sort == 'Descr' then
        local desc = {}
        for _, t in ipairs(foundTags) do desc[t] = self:GetDescription(t) end
        tsort(foundTags, function(a, b)
            if desc[a] ~= desc[b] then return perl.lt(desc[a], desc[b]) end
            return (fileOrder[a] or 999) < (fileOrder[b] or 999)
        end)
        return foundTags
    end
    local family = perl.matches(sort, [[^Group(\d*(:\d+)*)]])
    if family then
        -- (`$1 || 0`: '' and '0' both select family 0; a string like '0:1'
        --  is passed on to GetGroup as it is)
        if family == '' or family == '0' then family = 0 end
        -- order groups by first appearance in file order
        local groupCount = {}
        local groupOrder = {}
        local numGroups = 0
        tsort(foundTags, function(a, b)
            return (fileOrder[a] or 999) < (fileOrder[b] or 999)
        end)
        for _, tag in ipairs(foundTags) do
            local group = self:GetGroup(tag, family)
            local num = groupCount[group]
            if not num then
                numGroups = numGroups + 1
                num = numGroups
                groupCount[group] = num
            end
            groupOrder[tag] = num
        end
        if not sort2 then sort2 = self.OPTIONS.Sort2 end
        if sort2 then
            if sort2 == 'Tag' or sort2 == 'Alpha' then
                tsort(foundTags, function(a, b)
                    local ga, gb = groupOrder[a], groupOrder[b]
                    if ga ~= gb then return ga < gb end
                    return perl.lt(a, b)
                end)
                return foundTags
            elseif sort2 == 'Descr' then
                local desc = {}
                for _, t in ipairs(foundTags) do desc[t] = self:GetDescription(t) end
                tsort(foundTags, function(a, b)
                    local ga, gb = groupOrder[a], groupOrder[b]
                    if ga ~= gb then return ga < gb end
                    if desc[a] ~= desc[b] then return perl.lt(desc[a], desc[b]) end
                    -- (Perl's sort is stable; table.sort is not)
                    return (fileOrder[a] or 999) < (fileOrder[b] or 999)
                end)
                return foundTags
            end
        end
        tsort(foundTags, function(a, b)
            local ga, gb = groupOrder[a], groupOrder[b]
            if ga ~= gb then return ga < gb end
            return (fileOrder[a] or 999) < (fileOrder[b] or 999)
        end)
        return foundTags
    end
    -- file order
    tsort(foundTags, function(a, b)
        return (fileOrder[a] or 999) < (fileOrder[b] or 999)
    end)
    return foundTags
end

--------------------------------------------------------------------------------
-- Get group name for specified tag
-- Inputs: 0) ExifTool object reference
--         1) tag key (or reference to tagInfo hash, not part of the public API)
--         2) [optional] group family (-1 to get extended group list, or multiple
--            families separated by colons to return multiple groups as a string)
-- Returns: Scalar context: group name (for family 0 if not otherwise specified)
--          List context: group name if family specified, otherwise list of
--          group names for each family.  Returns '' for undefined tag.
-- Notes: Multiple families may be specified with ':' in family argument (eg. '1:2')
-- (upstream GetGroup, ExifTool.pm:3810)
-- (port: the families GetGroup's fast path handles, number or string, with
--  the TAG_EXTRA key of each)
local fastFamily = { [0] = 'G0', [1] = 'G1', [2] = 'G2', ['0'] = 'G0', ['1'] = 'G1', ['2'] = 'G2' }
function ExifTool:GetGroup(tag, family)
    local tagInfo, groups, families, simplify, byTagInfo, ex, noID
    local grp = {}  -- (upstream @groups, 0-based; $groups is the tagInfo hash)
    if type(tag) == 'table' then
        tagInfo = tag
        tag = tagInfo.Name
        -- set flag so we don't get extra information for an extracted tag
        byTagInfo = true
        ex = { }
    else
        tagInfo = self.TAG_INFO[tag] or { }
        ex = self.TAG_EXTRA[tag] or { }
    end
    groups = tagInfo.Groups
    -- fill in default groups unless already done
    -- (after this, Groups 0-2 in tagInfo are guaranteed to be defined)
    if not tagInfo.GotGroups then
        local tagTablePtr = tagInfo.Table or { GROUPS = { } }
        -- construct our group list
        if not groups then groups = { } tagInfo.Groups = groups end
        -- fill in default groups
        for i = 0, 2 do
            if not perlTruthy(groups[i]) then groups[i] = (tagTablePtr.GROUPS or {})[i] or '' end
        end
        -- set flag indicating group list was built
        tagInfo.GotGroups = 1
    end
    -- (port fast path for the bulk of all calls, one plain family 0, 1 or 2:
    --  the same results as the general code below -- for 0 and 2 its
    --  `return($$ex{"G$family"} || $$groups{$family}) if $family == 0 or
    --  $family == 2`, for 1 its `$groups[1] = $$ex{G1} =~ /^\+(.*)/ ? ...`
    --  plus `return $groups[$family] || '' if $family > 0` -- without the
    --  regex test of the family, the group list and the tag ID group)
    local exKey = fastFamily[family]
    if exKey then
        local g
        if exKey == 'G1' then
            g = groups[1]
            local g1 = ex.G1
            if perlTruthy(g1) then
                local m = perl.matches(perl.str(g1), [[^\+(.*)]])
                if m then g = g .. m else g = g1 end
            end
            if perlTruthy(g) then return g end
            return ''
        end
        g = ex[exKey]
        if perlTruthy(g) then return g end
        return groups[exKey == 'G0' and 0 or 2]
    end
    -- (Perl `$$ex{X} || $y`)
    local function exOr(k, y)
        if perlTruthy(ex[k]) then return ex[k] end
        return y
    end
    if family ~= nil and family ~= -1 and family ~= '-1' then  -- (Perl `$family ne '-1'`)
        if perl.matches(perl.str(family), [=[[^\d]]=]) then
            families = perl.findAll(perl.str(family), [[\d+]])
            for i = 1, #families do families[i] = tonumber(families[i]) end
            if #families == 0 then return exOr('G0', groups[0]) end
            if not perl.matches(perl.str(family), [[^:]]) then simplify = true end
            family = nil
            for i = 0, 2 do grp[i] = groups[i] end
            if #families == 1 and families[1] ~= 7 then noID = true end
        else
            family = tonumber(family)
            if family == 0 or family == 2 then return exOr('G' .. family, groups[family]) end
            grp[1] = groups[1]
        end
    else
        -- (Lua has no wantarray: upstream's scalar-context
        --  `return($$ex{G0} || $$groups{0}) unless wantarray` is GetGroup(tag, 0))
        for i = 0, 2 do grp[i] = groups[i] end
    end
    grp[3] = 'Main'
    local copyNum = perl.matches(perl.str(tag), [[\((\d+)\)$]])
    grp[4] = (copyNum and copyNum ~= '0') and ('Copy' .. copyNum) or ''
    -- handle dynamic group names if necessary
    if not byTagInfo then
        if perlTruthy(ex.G0) then grp[0] = ex.G0 end
        if perlTruthy(ex.G1) then
            local m = perl.matches(perl.str(ex.G1), [[^\+(.*)]])
            if m then grp[1] = grp[1] .. m else grp[1] = ex.G1 end
        end
        if perlTruthy(ex.G3) then grp[3] = 'Doc' .. ex.G3 end
        if ex.G5 ~= nil then grp[5] = exOr('G5', grp[1]) end
        if ex.G6 ~= nil then
            if grp[5] == nil then grp[5] = '' end  -- (can't leave a hole in the array)
            grp[6] = ex.G6
        end
        if perlTruthy(ex.G8) then
            grp[7] = ''
            grp[8] = ex.G8
        end
        -- generate tag ID group names unless obviously not needed
        if not noID then
            local id = tagInfo.KeysID or tagInfo.TagID
            if id == nil then
                id = ''   -- (just to be safe)
            elseif (math.type(id) == 'integer' and id >= 0) or perl.matches(perl.str(id), [[^\d+$]]) then
                -- (a non-negative integer ID always matches; the regex is for strings)
                if perlTruthy(self.OPTIONS.HexTagIDs) then id = sprintf('0x%x', tonumber(id)) end
            else
                id = perl.subst(perl.str(id), [[([^-_A-Za-z0-9])]],
                    function(c) return sprintf('%.2x', c:byte()) end, 'g')
            end
            grp[7] = 'ID-' .. perl.str(id)
            for _, f in ipairs({ 5, 6 }) do
                if grp[f] == nil then grp[f] = '' end
            end
        end
    end
    if family ~= nil and family ~= 0 then  -- (Perl `if ($family)`; -1 is true)
        if tonumber(family) > 0 then
            if perlTruthy(grp[family]) then return grp[family] end
            return ''
        end
        -- add additional matching group names to list
        -- eg) for MIE-Doc, also add MIE1, MIE1-Doc, MIE-Doc1 and MIE1-Doc1
        -- and for MIE2-Doc3, also add MIE2, MIE-Doc3, MIE2-Doc and MIE-Doc
        local m1, m2, m3 = perl.matches(grp[1], [[^MIE(\d*)-(.+?)(\d*)$]])
        if m1 then
            grp[#grp + 1] = 'MIE' .. (m1 ~= '' and m1 or '1')
            grp[#grp + 1] = 'MIE' .. (m1 ~= '' and '' or '1') .. '-' .. m2 .. m3
            grp[#grp + 1] = 'MIE' .. m1 .. '-' .. m2 .. (m3 ~= '' and '' or '1')
            grp[#grp + 1] = 'MIE' .. (m1 ~= '' and '' or '1') .. '-' .. m2 .. (m3 ~= '' and '' or '1')
        end
    end
    if families then
        local grps = {}
        -- create list of group names (without identical adjacent groups if simplifying)
        for _, f in ipairs(families) do
            local g = grp[f]
            local skip = false
            if not perlTruthy(g) then
                if simplify then skip = true else g = '' end
            end
            if not skip and not (simplify and #grps > 0 and g == grps[#grps]) then
                grps[#grps + 1] = g
            end
        end
        -- remove leading "Main:" if simplifying
        if simplify and #grps > 1 and grps[1] == 'Main' then table.remove(grps, 1) end
        -- return colon-separated string of group names
        return table.concat(grps, ':')
    end
    return grp
end

--------------------------------------------------------------------------------
-- Is this a tag ID?
-- Inputs: 0) tag ID, 1) group name (with leading "ID-" removed)
-- Returns: true if group name matches tag ID
function ExifTool.IsSameID(id, grp)
    id = perl.str(id)
    while true do
        if grp == id then return 1 end    -- decimal ID's or raw ID's
        if perl.matches(id, [[^\d+$]]) then -- numerical numerical ID's may be in hex
            if perl.matches(grp, [[^0x0*]]) then
                grp = perl.subst(grp, [[^0x0*]], '')
                if grp == sprintf('%x', tonumber(id)) then return 1 end
            end
        else                        -- other ID's may conform to ExifTool group name conventions
            local tmp = perl.subst(id, [[([^-_A-Za-z0-9])]],
                function(c) return sprintf('%.2x', c:byte()) end, 'g')
            if tmp ~= id and grp == tmp then return 1 end
        end
        if not perl.matches(id, [[-]]) then break end
        id = perl.subst(id, [[-.*]], '') -- remove language code if it exists
    end
    return 0
end

-- (port: GroupMatches' parse of the group spec, kept per spec string in
--  groupSpecs -- it depends on the string alone, and BuildCompositeTags
--  asks once per qualified Require/Desire and file)
local groupSpecs = { }
local function groupSpec(group)
    local spec = groupSpecs[group]
    if spec then return spec[1], spec[2] end
    -- check each group name individually (eg. "Author:1IPTC")
    local grps = perl.split(':', group)
    local fmys = { }
    local skipLc = { }
    for g = 1, #grps do
        local num, idPre = perl.matches(grps[g], [[(?i)^(\d*)(id-)?]])
        if num then
            grps[g] = perl.subst(grps[g], [[(?i)^(\d*)(id-)?]], '')
            if #num > 0 then fmys[g] = tonumber(num) end
            if idPre then
                fmys[g] = 7
                skipLc[g] = true   -- (don't convert tag ID's to lower case)
            end
        end
        if not skipLc[g] then
            grps[g] = lc(grps[g])
            if grps[g] == 'copy0' then grps[g] = '' end -- accept 'Copy0' for primary tag
        end
    end
    groupSpecs[group] = { grps, fmys }
    return grps, fmys
end

--------------------------------------------------------------------------------
-- Get list of tags in specified group
-- Inputs: 0) ExifTool ref, 1) group spec, 2) tag key or reference to list of tag keys
-- Returns: list of matching tags in list context, or first match in scalar context
-- Notes: Group spec may contain multiple groups separated by colons, each
--        possibly with a leading family number
-- (Lua has no wantarray: this always returns the list; callers wanting
--  upstream's scalar form take the first element)
function ExifTool:GroupMatches(group, tagList)
    if type(tagList) ~= 'table' then tagList = { tagList } end
    local matches = { }
    -- (port: the group names and families, parsed once per spec by groupSpec)
    local grps, fmys = groupSpec(group)
    for _, tag in ipairs(tagList) do
        local groups = self:GetGroup(tag, -1)
        local g = 1
        while g <= #grps do
            local grp = grps[g]
            if not (grp == '*' or grp == 'all') then
                local f = fmys[g]
                if f ~= nil then
                    if groups[f] == nil then break end
                    if f == 7 then
                        if ExifTool.IsSameID(self:GetTagID(tag), grp) == 0 then break end
                    elseif grp ~= lc(groups[f]) then
                        break
                    end
                else
                    local found = false
                    for i = 0, #groups do
                        if groups[i] ~= nil and lc(groups[i]) == grp then found = true break end
                    end
                    if not found then break end
                end
            end
            g = g + 1
        end
        if g > #grps then matches[#matches + 1] = tag end
    end
    return matches
end

--------------------------------------------------------------------------------
-- Get group names for specified tags
-- Inputs: 0) ExifTool object reference
--         1) [optional] information hash reference (default all extracted info)
--         2) [optional] group family (default 0)
-- Returns: List of group names in alphabetical order
function ExifTool:GetGroups(x, family)
    -- upstream: `GetGroups([$info], [$family])` -- a leading HASH is the info
    -- to scan, anything else is the family and the whole VALUE hash is used
    local info
    if type(x) == 'table' then
        info = x
    elseif type(x) == 'number' or (type(x) == 'string' and x:match('^%d+[%d:]*$')) then
        info, family = self.VALUE, x
    end
    if info then
        if family == nil then family = 0 end
        local seen = {}
        local list = {}
        for tag in pairs(info) do
            local g = self:GetGroup(tag, family)
            if g and not seen[g] then
                seen[g] = true
                list[#list + 1] = g
            end
        end
        tsort(list)
        return list
    end
    -- (a port addition, with no upstream counterpart: given a TAG KEY,
    --  return its groups for all four families at once -- used by
    --  TestLib.check and test_smoke)
    local g0 = self:GetGroup(x, 0)
    local g1 = self:GetGroup(x, 1)
    local g2 = self:GetGroup(x, 2)
    local g3 = self:GetGroup(x, 3)
    return { [0]=g0, [1]=g1, [2]=g2, [3]=g3 }
end

-- +-----------------------------------------------------+
-- ! DON'T FORGET!!  When adding any new option, must    !
-- ! decide how it is handled in SetNewValuesFromFile()  !
-- +-----------------------------------------------------+
-- (Note: All options must exist in this lookup, even if undefined,
-- to facilitate case-insensitive options. 'Group#' is handled specially)
-- (item 3 is a flag indicating the option is undocumented)
availableOptions = {
    { 'Binary',           nil,    'flag to extract binary values even if tag not specified' },
    { 'ByteOrder',        nil,    'default byte order when creating EXIF information' },
    { 'ByteUnit',         'SI',   'units for byte conversions (SI or Binary)' },
    { 'Charset',          'UTF8', 'character set for converting Unicode characters' },
    { 'CharsetEXIF',      nil,    'internal EXIF "ASCII" string encoding' },
    { 'CharsetFileName',  nil,    'external encoding for file names' },
    { 'CharsetID3',       'Latin','internal ID3v1 character set' },
    { 'CharsetIPTC',      'Latin','fallback IPTC character set if no CodedCharacterSet' },
    { 'CharsetPhotoshop', 'Latin','internal encoding for Photoshop resource names' },
    { 'CharsetQuickTime', 'MacRoman', 'internal QuickTime string encoding' },
    { 'CharsetRIFF',      0,      'internal RIFF string encoding (0=default to Latin)' },
    { 'Compact',          { },    'write compact XMP' },
    { 'Composite',        1,      'flag to calculate Composite tags' },
    { 'Compress',         nil,    'flag to write new values as compressed if possible' },
    { 'CoordFormat',      nil,    'GPS lat/long coordinate format' },
    { 'DateFormat',       nil,    'format for date/time' },
    { 'Debug',            nil,    'enable debugging output', 1 }, -- (undocumented)
    { 'Duplicates',       1,      'flag to save duplicate tag values' },
    -- ("require Encode" hangs on my Windows 10 virtual machine running under MacOS if
    --  the current working directory has a long path name.  This problem hasn't been
    --  seen on other Windows systems, so I'm leaving this option undocumented for now)
    { 'EncodeHangs',      nil,    'flag set to avoid using Encode if it hangs on your system', 1 }, -- (undocumented)
    { 'Escape',           nil,    'escape special characters' },
    { 'Exclude',          nil,    'tags to exclude' },
    { 'ExtendedXMP',      1,      'strategy for reading extended XMP' },
    { 'ExtractEmbedded',  nil,    'flag to extract information from embedded documents' },
    { 'FastScan',         nil,    'flag to avoid scanning for trailer' },
    { 'Filter',           nil,    'output filter for all tag values' },
    { 'FilterW',          nil,    'input filter when writing tag values' },
    { 'FixBase',          nil,    'fix maker notes base offsets' },
    { 'Geolocation',      nil,    'generate geolocation tags' },
    { 'GeolocAltNames',   1,      'search alternate city names if available' },
    { 'GeolocFeature',    nil,    'regular expression of geolocation features to match' },
    { 'GeolocMinPop',     nil,    'minimum geolocation population' },
    { 'GeolocMaxDist',    nil,    'maximum geolocation distance' },
    { 'GeoMaxIntSecs',    1800,   'geotag maximum interpolation time (secs)' },
    { 'GeoMaxExtSecs',    1800,   'geotag maximum extrapolation time (secs)' },
    { 'GeoMaxHDOP',       nil,    'geotag maximum HDOP' },
    { 'GeoMaxPDOP',       nil,    'geotag maximum PDOP' },
    { 'GeoMinSats',       nil,    'geotag minimum satellites' },
    { 'GeoHPosErr',       nil,    'geotag GPSHPositioningError based on $GPSDOP' },
    { 'GeoSpeedRef',      nil,    'geotag GPSSpeedRef' },
    { 'GeoUserTag',       nil,    'user-defined tags for geotagging' },
    { 'GlobalTimeShift',  nil,    'apply time shift to all extracted date/time values' },
    { 'GPSQuadrant',      nil,    'quadrant for GPS if not otherwise known' },
    { 'Group#',           nil,    'return tags for specified groups in family #' },
    { 'HexTagIDs',        0,      'use hex tag ID\'s in family 7 group names' },
    { 'HtmlDump',         0,      'HTML dump (0-3, higher # = bigger limit)' },
    { 'HtmlDumpBase',     nil,    'base address for HTML dump' },
    { 'IgnoreGroups',     nil,    'list of groups to ignore when extracting' },
    { 'IgnoreMinorErrors',nil,    'ignore minor errors when reading/writing' },
    { 'IgnoreTags',       nil,    'list of tags to ignore when extracting' },
    { 'ImageHashType',    'MD5',  'image hash algorithm' },
    { 'KeepUTCTime',      nil,    'do not convert times stored as UTC' },
    { 'Lang',       ExifTool.defaultLang, 'localized language for descriptions etc' },
    { 'LargeFileSupport', 1,      'flag indicating support of 64-bit file offsets' },
    { 'LimitLongValues',  60,     'length limit for long values' },
    { 'List',             nil,    '[deprecated, use ListSplit and ListJoin instead]', 1 },
    { 'ListItem',         nil,    'used to return a specific item from lists' },
    { 'ListJoin',         ', ',   'join lists together with this separator' },
    { 'ListSep',          ', ',   '[deprecated, use ListSplit and ListJoin instead]', 1 },
    { 'ListSplit',        nil,    'regex for splitting list-type tag values when writing' },
    --  LigoGPSScale - undocumented scale for unfuzzing LIGO GPS: 1,2,3 for standard scales (1 default), or scale value
    { 'MakerNotes',       nil,    'extract maker notes as a block' },
    { 'MDItemTags',       nil,    'extract MacOS metadata item tags' },
    { 'MissingTagValue',  nil,    'value for missing tags when expanded in expressions' },
    { 'NoMandatory',      nil,    'bypass writing of mandatory EXIF tags' },
    { 'NoMultiExif',      nil,    'raise error when writing multi-segment EXIF' },
    { 'NoPDFList',        nil,    'flag to avoid splitting PDF List-type tag values' },
    { 'NoWarning',        nil,    'regular expression for warnings to suppress' },
    { 'Password',         nil,    'password for password-protected PDF documents' },
    { 'Plot',             nil,    'SVG plot settings' },
    { 'PrintCSV',         nil,    'flag to print CSV directly (selected metadata types only)' },
    { 'PrintConv',        1,      'flag to enable print conversion' },
    { 'QuickTimeHandler', 1,      'flag to add mdir Handler to newly created Meta box' },
    { 'QuickTimePad',     nil,    'flag to preserve padding of QuickTime CR3 tags' },
    { 'QuickTimeUTC',     nil,    'assume that QuickTime date/time tags are stored as UTC' },
    { 'RequestAll',       nil,    'extract all tags that must be specifically requested' },
    { 'RequestTags',      nil,    'extra tags to request (on top of those in the tag list)' },
    { 'SaveBin',          nil,    'save binary values of tags' },
    { 'SaveFormat',       nil,    'save family 6 tag TIFF format' },
    { 'SavePath',         nil,    'save family 5 location path' },
    { 'ScanForXMP',       nil,    'flag to scan for XMP information in all files' },
    { 'Sort',             'Input','order to sort found tags (Input, File, Tag, Descr, Group#)' },
    { 'Sort2',            'File', 'secondary sort order for tags in a group (File, Tag, Descr)' },
    { 'StrictDate',       nil,    'flag to return undef for invalid date conversions' },
    { 'Struct',           nil,    'return structures as hash references' },
    { 'StructFormat',     nil,    'format for structure serialization when reading/writing' },
    { 'SystemTags',       nil,    'extract additional File System tags' },
    { 'SystemTimeRes',    0,      'number of sub-second digits in system and epoch times' },
    { 'TextOut',        io.stdout, 'file for Verbose/HtmlDump output' },
    { 'TimeZone',         nil,    'local time zone' },
    { 'UndefTags',        nil,    'leave undef tags in -if conditions when -m or -f are used' },
    { 'Unknown',          0,      'flag to get values of unknown tags (0-2)' },
    { 'UserParam',        { },    'user parameters for additional user-defined tag values' },
    { 'Validate',         nil,    'perform additional validation' },
    { 'Verbose',          0,      'print verbose messages (0-5, higher # = more verbose)' },
    { 'WindowsLongPath',  0,      'enable support for long pathnames (enables WindowsWideFile)' },
    { 'WindowsWideFile',  nil,    'force the use of Windows wide-character file routines' }, -- (see forum15208)
    { 'WriteMode',        'wcg',  'enable all write modes by default' },
    { 'XAttrTags',        nil,    'extract MacOS extended attribute tags' },
    { 'XMPAutoConv',      1,      'automatic conversion of unknown XMP tag values' },
    { 'XMPShorthand',     0,      '[deprecated, use Compact=Shorthand instead]', 1 },
}

-- default groups for writing (upstream @defaultWriteGroups, ExifTool.pm:1221)
local defaultWriteGroups = {
    'EXIF', 'IPTC', 'XMP', 'MakerNotes', 'QuickTime', 'Photoshop', 'ICC_Profile',
    'CanonVRD', 'Adobe',
}

--------------------------------------------------------------------------------
-- Set priority for group where new values are written (upstream SetNewGroups,
-- ExifTool.pm:3951) -- higher number is higher priority
-- Inputs: 0) ExifTool object reference, 1-N) group names (reset to default if none)
--------------------------------------------------------------------------------
function ExifTool:SetNewGroups(...)
    local groups = { ... }
    if #groups == 0 then
        groups = defaultWriteGroups
    end
    local count = #groups * 10
    local priority = {}
    for _, g in ipairs(groups) do
        priority[lc(g)] = count
        count = count - 10
    end
    priority.file = 500      -- 'File' group is always written (Comment)
    priority.composite = 500 -- 'Composite' group is always written
    self.WRITE_PRIORITY = priority
    self.WRITE_GROUPS = groups
end

--------------------------------------------------------------------------------
-- Get tag identification number
-- Inputs: 0) ExifTool object reference, 1) tag key
-- Returns: Scalar context: tag ID if available, otherwise ''
--          List context: 0) tag ID (or ''), 1) language code (or undef)
-- (Lua has no wantarray: the language code is always returned as the second
--  value, and a caller that wants only the ID simply ignores it)
function ExifTool:GetTagID(tag)
    local tagInfo = self.TAG_INFO[tag]
    if not (tagInfo and tagInfo.TagID ~= nil) then return '' end
    local id = tagInfo.KeysID or tagInfo.TagID
    return id, tagInfo.LangCode
end

--------------------------------------------------------------------------------
-- Get description for specified tag
-- Inputs: 0) ExifTool object reference, 1) tag key
-- Returns: Tag description
-- Notes: Will always return a defined value, even if description isn't available
function ExifTool:GetDescription(tag)
    local desc, name
    local tagInfo = self.TAG_INFO[tag]
    -- ($tagInfo won't be defined for missing tags extracted with -f)
    if tagInfo then
        -- use alternate language description if available
        -- (upstream `while ($$self{CUR_LANG})`: every path through the body
        --  ends in `last` or `return`, so it runs at most once -- ported as
        --  an `if`, with `found` false where upstream says `last`)
        if self.CUR_LANG then
            local found
            desc = self.CUR_LANG[tagInfo.Name]
            if perlTruthy(desc) then
                -- must look up Description if this tag also has a PrintConv
                if type(desc) == 'table' then desc = desc.Description end
                found = perlTruthy(desc)
            -- look up default language of lang-alt tag
            -- (ExifTool.pm:3777-3779: `($name = $$tagInfo{Name}) =~
            --  s/-$$tagInfo{LangCode}$//` -- a pattern built at runtime)
            elseif perlTruthy(tagInfo.LangCode) and
                perl.isMatchDyn(tagInfo.Name, '-' .. tagInfo.LangCode .. '$')
            then
                name = perl.substDyn(tagInfo.Name, '-' .. tagInfo.LangCode .. '$', '')
                desc = self.CUR_LANG[name]
                if type(desc) == 'table' then desc = desc.Description end
                if perlTruthy(desc) then
                    desc = desc .. ' (' .. tagInfo.LangCode .. ')'
                    found = true
                end
            end
            if found then
                -- escape description if necessary
                if self.ESCAPE_PROC then desc = ExifTool.DoEscape(desc, self.ESCAPE_PROC) end
                -- return description in proper Charset
                return self:Decode(desc, 'UTF8')
            end
        end
        desc = tagInfo.Description
    end
    -- just make the tag more readable if description doesn't exist
    if not perlTruthy(desc) then
        desc = ExifTool.MakeDescription(ExifTool.GetTagName(tag))
        -- save description in tag information
        if tagInfo then tagInfo.Description = desc end
    end
    return desc
end

--------------------------------------------------------------------------------
-- Get tag table name
-- Inputs: 0) ExifTool object reference, 1) tag key
-- Returns: Table name if available, otherwise ''
-- (SHORT_NAME carries upstream's spelling, 'Exif::Main' -- see SetupTagTable)
function ExifTool:GetTableName(tag)
    local tagInfo = self.TAG_INFO[tag]
    if not tagInfo then return '' end
    -- (Perl reads $$tagInfo{Table}{SHORT_NAME} as undef for a tag without a
    --  Table; Lua would raise on the nil index)
    local tbl = tagInfo.Table
    return tbl and tbl.SHORT_NAME
end

--------------------------------------------------------------------------------
-- Get tag index number
-- Inputs: 0) ExifTool object reference, 1) tag key
-- Returns: Table index number, or undefined if this tag isn't indexed
function ExifTool:GetTagIndex(tag)
    local tagInfo = self.TAG_INFO[tag]
    if not tagInfo then return nil end
    return tagInfo.Index
end

--------------------------------------------------------------------------------
-- Find value for specified tag
-- Inputs: 0) ExifTool ref, 1) tag name, 2) tag group (family 1)
-- Returns: value or undef
function ExifTool:FindValue(tag, grp)
    local value = self.VALUE
    local i = 0
    while true do
        local key = tag .. (i > 0 and (' (' .. i .. ')') or '')
        if value[key] == nil then break end
        if self:GetGroup(key, 1) == grp then
            return value[key]
        end
        i = i + 1
    end
    return nil
end

--------------------------------------------------------------------------------
-- Get tag key for next existing tag
-- Inputs: 0) ExifTool ref, 1) tag key or case-sensitive tag name
-- Returns: Key of next existing tag, or undef if no more
-- Notes: This routine is provided for iterating through duplicate tags in the
--        ValueConv of Composite tags.
function ExifTool:NextTagKey(tag)
    local base, n = tag:match('^(.*) %((%d+)%)$')
    local i = base and (tonumber(n) + 1) or 1
    tag = (base or tag) .. ' (' .. i .. ')'
    if self.VALUE[tag] ~= nil then return tag end
    return nil
end

--------------------------------------------------------------------------------
-- Does a string contain valid UTF-8 characters?
-- Inputs: 0) string reference, 1) true to allow last character to be truncated
-- Returns: 0=regular ASCII, -1=invalid UTF-8, 1=valid UTF-8 with maximum 16-bit
--          wide characters, 2=valid UTF-8 requiring 32-bit wide characters
-- Notes: Changes current string position
-- (see http://www.fileformat.info/info/unicode/utf8.htm for help understanding this)
-- (port: takes the string itself -- or a carray -- instead of a reference; the
--  string position is the local `pos`, Perl's pos($$strPt))
-- (the `\G([\x80-\xbf]{$n})` match for the n = 1..3 continuation bytes, one
--  literal pattern per count so each stays in the pattern cache)
local utf8Cont = { [[\G([\x80-\xbf]{1})]], [[\G([\x80-\xbf]{2})]], [[\G([\x80-\xbf]{3})]] }
function ExifTool.IsUTF8(strPt, trunc)
    local c, pos = perl.matches(strPt, [=[([\x80-\xff])]=], 0) -- start at beginning of string
    if not c then return 0 end
    local rtnVal = 1
    while true do
        local ch = perl.ord(c)
        -- minimum lead byte for 2-byte sequence is 0xc2 (overlong sequences
        -- not allowed), 0xf8-0xfd are restricted by RFC 3629 (no 5 or 6 byte
        -- sequences), and 0xfe and 0xff are not valid in UTF-8 strings
        if ch < 0xc2 or ch >= 0xf8 then return -1 end
        -- determine number of bytes remaining in sequence
        local n
        if ch < 0xe0 then
            n = 1
        elseif ch < 0xf0 then
            n = 2
        else
            n = 3
            -- character code is greater than 0xffff if more than 2 extra bytes
            -- were required in the UTF-8 character
            rtnVal = 2
        end
        local p = pos
        c, pos = perl.matches(strPt, utf8Cont[n], p)
        if not c then
            if trunc and p + n > perl.length(strPt) then return rtnVal end
            return -1
        end
        -- the following is ref https://www.cl.cam.ac.uk/%7Emgk25/ucs/utf8_check.c
        if n == 2 then
            if (ch == 0xe0 and (perl.ord(c) & 0xe0) == 0x80) or
               (ch == 0xed and (perl.ord(c) & 0xe0) == 0xa0) or
               (ch == 0xef and perl.ord(c) == 0xbf and
                  (perl.ord(substr(c, 1)) & 0xfe) == 0xbe) then
                return -1
            end
        else
            if (ch == 0xf0 and (perl.ord(c) & 0xf0) == 0x80) or
               (ch == 0xf4 and perl.ord(c) > 0x8f) or ch > 0xf4 then
                return -1
            end
        end
        c, pos = perl.matches(strPt, [=[([\x80-\xff])]=], pos)
        if not c then break end
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Get descriptions for all tags in an array
-- Inputs: 0) ExifTool ref, 1) reference to list of tag keys
-- Returns: reference to hash lookup for descriptions
-- Note: Returned descriptions are NOT escaped by ESCAPE_PROC
function ExifTool:GetDescriptions(foundTags)
    local desc = {}
    for i = 1, #foundTags do
        desc[foundTags[i]] = self:GetDescription(foundTags[i])
    end
    return desc
end

--------------------------------------------------------------------------------
-- Apply filter to value(s) if necessary
-- Inputs: 0) ExifTool ref, 1) filter expression, 2) value to filter
-- Returns: true unless a filter returned undef; and the (possibly changed) value
-- (upstream changes the value through a reference, `\$value`; Lua passes
--  strings by value, so the new value is returned as the second result)
--
-- Upstream evals the filter as Perl code with the value in $_. The port
-- understands two forms: a Lua function (called with the value and the
-- ExifTool object -- the counterpart of `#### eval Filter ($_, $self)` --
-- returning the new value, or nil for undef), and a string of Perl code in
-- the subset perl.compileEdit translates (tr///, y///, s/// statements, the
-- form the exiftool documentation uses). Any other Perl code is treated
-- like an eval that fails to compile: $_ keeps its value.
function ExifTool:Filter(filter, val)
    if filter == nil or val == nil then return true, val end
    local rtnVal
    if type(val) ~= 'table' then
        local v = val
        if type(v) == 'number' then v = ExifTool.NumStr(v) end
        local fn = filter
        if type(filter) ~= 'function' then fn = perl.compileEdit(perl.str(filter)) end
        if fn then
            local ok, res = pcall(fn, v, self)
            -- (a failing eval leaves $_ as it was)
            if ok then v = res end
        end
        if v ~= nil then
            val = v
            rtnVal = true
        end
    elseif val.ref == 'SCALAR' then
        -- make a copy to avoid filtering twice
        local r, v = self:Filter(filter, val.value)
        rtnVal = r
        local copy = {}
        for k, x in pairs(val) do copy[k] = x end
        copy.value = v
        val = copy
    elseif val.ref == nil then
        -- (ARRAY) make a copy to avoid filtering twice
        local copy = {}
        for k = 1, #val do
            local r, v = self:Filter(filter, val[k])
            if r then rtnVal = true end
            copy[k] = v
        end
        val = copy
    else
        rtnVal = true
    end
    return rtnVal, val
end

--------------------------------------------------------------------------------
-- Get hash of extracted meta information
-- Inputs: 0) ExifTool object reference
--         1-N) options hash reference, tag list reference or tag names
-- Returns: Reference to information hash
-- Notes: - pass an undefined value to avoid parsing arguments
--        - If groups are specified, first groups take precedence if duplicate
--          tags found but Duplicates option not set.
--        - tag names may end in '#' to extract ValueConv value
-- (Lua can tell `GetInfo()` from `GetInfo(nil)` only by the argument count,
--  which is what upstream's `@_ and not defined $_[0]` tests as well)
function ExifTool:GetInfo(...)
    local saveOptions, saveMembers, savedMembers

    -- save necessary members to allow GetInfo to be called from within ExtractInfo
    if self.InExtract then
        saveMembers = { 'REQUESTED_TAGS', 'REQ_TAG_LOOKUP', 'IO_TAG_LIST' }
        savedMembers = {}
        for i, m in ipairs(saveMembers) do savedMembers[i] = self[m] end
    end
    if not (select('#', ...) > 0 and (...) == nil) then
        saveOptions = {}    -- save original options
        for k, v in pairs(self.OPTIONS) do saveOptions[k] = v end
        -- must set FILENAME so it isn't parsed from the arguments
        if self.FILENAME == nil then self.FILENAME = '' end
        self:ParseArguments(...)
    end

    -- get reference to list of tags for which we will return info
    local rtnTags, byValue, wildTags = self:SetFoundTags()

    -- build hash of tag information
    local info, ignored = {}, {}
    local conv = perlTruthy(self.OPTIONS.PrintConv) and 'PrintConv' or 'ValueConv'
    for _, tag in ipairs(rtnTags) do
        local val = self:GetValue(tag, conv)
        if val == nil then
            ignored[tag] = 1
        else
            info[tag] = val
        end
    end

    -- override specified tags with ValueConv value if necessary
    if #byValue > 0 then
        -- first determine the number of times each non-ValueConv value is used
        local nonVal = {}
        for _, tag in ipairs(rtnTags) do nonVal[tag] = (nonVal[tag] or 0) + 1 end
        for _, i in ipairs(byValue) do
            local tag = rtnTags[i + 1]
            nonVal[tag] = nonVal[tag] - 1
        end
        -- loop through ValueConv tags, updating tag keys and returned values
        for _, i in ipairs(byValue) do
            local tag = rtnTags[i + 1]
            local val = self:GetValue(tag, 'ValueConv')
            if val ~= nil then
                -- generate a new tag key like "Tag #" or "Tag #(1)"
                -- (through the facade: a Lua pattern has no alternation, and
                --  `( |$)` there would be the three literal characters " |$")
                local vtag = perl.subst(tag, '( |$)', ' #')
                if self.VALUE[vtag] == nil then
                    self.VALUE[vtag] = self.VALUE[tag]
                    self.TAG_INFO[vtag] = self.TAG_INFO[tag]
                    self.TAG_EXTRA[vtag] = self.TAG_EXTRA[tag]
                    self.FILE_ORDER[vtag] = self.FILE_ORDER[tag]
                    -- remove existing PrintConv entry unless we are using it too
                    if not perlTruthy(nonVal[tag]) then info[tag] = nil end
                end
                rtnTags[i + 1] = vtag   -- store ValueConv value with new tag key
                info[vtag] = val        -- return ValueConv value
            end
        end
    end

    -- remove ignored tags from the list
    local reqTags = self.REQUESTED_TAGS or {}
    if next(ignored) then
        if #reqTags == 0 then
            local goodTags = {}
            for _, tag in ipairs(rtnTags) do
                if not ignored[tag] then goodTags[#goodTags + 1] = tag end
            end
            rtnTags = goodTags
            self.FOUND_TAGS = goodTags
        elseif #wildTags > 0 then
            -- only remove tags specified by wildcard
            local goodTags = {}
            local w = 1
            for i, tag in ipairs(rtnTags) do
                if wildTags[w] ~= nil and i - 1 == wildTags[w] then
                    w = w + 1
                    if not ignored[tag] then goodTags[#goodTags + 1] = tag end
                else
                    goodTags[#goodTags + 1] = tag
                end
            end
            rtnTags = goodTags
            self.FOUND_TAGS = goodTags
        end
    end

    -- return sorted tag list if provided with a list reference
    if self.IO_TAG_LIST then
        -- use file order by default if no tags specified
        -- (no such thing as 'Input' order in this case)
        local sort = self.OPTIONS.Sort
        if not (#reqTags > 0 or (sort and sort ~= 'Input')) then sort = 'File' end
        -- return tags in specified sort order
        -- (upstream assigns to the caller's array; a Lua table is filled in place)
        local ioTagList = self.IO_TAG_LIST
        local sorted = self:GetTagList(rtnTags, sort, self.OPTIONS.Sort2)
        for k = #ioTagList, 1, -1 do ioTagList[k] = nil end
        for k, tag in ipairs(sorted) do ioTagList[k] = tag end
    end

    -- restore original options and member variables
    if saveOptions then self.OPTIONS = saveOptions end
    if saveMembers then
        for i, m in ipairs(saveMembers) do self[m] = savedMembers[i] end
    end

    return info
end

--------------------------------------------------------------------------------
-- Directory processing (ProcessDirectory / ProcessBinaryData)
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Process an image directory
-- Inputs: 0) ExifTool object reference, 1) directory information reference
--         2) tag table reference, 3) optional reference to processing procedure
-- Returns: Result from processing (1=success)
function ExifTool:ProcessDirectory(dirInfo, tagTablePtr, proc)
    if not (tagTablePtr and dirInfo) then return 0 end
    proc = proc or tagTablePtr.PROCESS_PROC or loadModule('Exif').ProcessExif
    -- set directory name from default group0 name if not done already
    local dirName = dirInfo.DirName
    if not dirName then
        local tg = tagTablePtr.GROUPS or {}
        dirName = tg[0]
        if dirName and dirName:match('^APP%d+$') then dirName = tg[1] end
        dirInfo.DirName = dirName
    end
    -- guard against cyclical recursion into the same directory
    if dirInfo.DirStart ~= nil and dirInfo.DataPos ~= nil and
        (dirInfo.DirLen or dirInfo.DirLen == nil) then
        local addr = dirInfo.DirStart + dirInfo.DataPos + (dirInfo.Base or 0) + (self.BASE or 0)
        if self.PROCESSED[addr] and not dirInfo.NotDup then
            self:Warn(dirName .. ' pointer references previous ' .. self.PROCESSED[addr] .. ' directory')
            if not (dirName == 'GPS' and self.PROCESSED[addr] == 'InteropIFD') then return 0 end
        end
        if not (tagTablePtr.VARS and tagTablePtr.VARS.ALLOW_REPROCESS) then
            self.PROCESSED[addr] = dirName
        end
    end
    local oldOrder = ExifTool.GetByteOrder()
    local saveDirName = self.DIR_NAME
    local saveIndent = self.INDENT
    self.INDENT = (self.INDENT or '  ') .. '| '
    self.LIST_TAGS = {}
    self.DIR_NAME = dirName
    self.FOUND_DIR = self.FOUND_DIR or {}
    self.FOUND_DIR[dirName] = 1
    if not self.PATH then self.PATH = {} end
    self.PATH[#self.PATH + 1] = dirName
    local rtnVal = proc(self, dirInfo, tagTablePtr)
    self.PATH[#self.PATH] = nil
    self.DIR_NAME = saveDirName
    self.INDENT = saveIndent
    ExifTool.SetByteOrder(oldOrder)
    return rtnVal
end

-- Process binary data with a fixed-offset tag table (upstream
-- ProcessBinaryData subset; used by the ICC binary sub-tables)
-- Decode UTF-16 (big-endian) bytes to a Latin-1 string (subset for ASCII/
-- Latin-1 Photoshop resource strings; surrogate pairs are not handled).
local function decodeUTF16BE(s)
    local out = {}
    for i = 1, math.floor(#s / 2) do
        local c = s:byte(2 * i - 1) * 256 + s:byte(2 * i)
        out[#out + 1] = string.char(c % 256)
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Process binary data
-- Inputs: 0) ExifTool object ref, 1) directory information ref, 2) tag table ref
-- Returns: 1 on success
-- Notes: dirInfo may contain VarFormatData (reference to empty list) to return
--        details about any variable-length-format tags in the table (used when writing)
function ExifTool.ProcessBinaryData(self, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataLen = #dataPt
    local dirStart = dirInfo.DirStart or 0
    local maxLen = dataLen - dirStart
    local size = dirInfo.DirLen
    local unknown = self.OPTIONS.Unknown
    size = size and math.min(size, maxLen) or maxLen
    local verbose = self.OPTIONS.Verbose
    if dirInfo.DataMember then
        verbose = 0   -- no verbose output of extracted values when writing
    end
    -- print verbose directory information (upstream ProcessBinaryData)
    if verbose and verbose > 0 then
        self:VerboseDir('BinaryData', nil, size, self.GetByteOrder())
    end
    local defaultFormat = tagTablePtr.FORMAT or 'int8u'
    local increment = formatSize[defaultFormat] or 1
    -- prepare list of tag numbers to extract
    local tags = {}
    local topIndex
    if unknown and unknown > 1 and tagTablePtr.FIRST_ENTRY ~= nil then
        -- don't create a stupid number of tags if data is huge
        local sizeLimit = size < 65536 and size or 65536
        -- scan through entire binary table
        topIndex = math.floor(sizeLimit / increment)
        for i = tagTablePtr.FIRST_ENTRY, topIndex - 1 do
            tags[#tags + 1] = { key = i, num = i }
        end
        -- add in floating point tag ID's if they exist
        local hasFloat
        for k in pairs(tagTablePtr) do
            if not ExifTool.specialTags[k] and tonumber(k) ~= nil and perl.str(k):find('.', 1, true) then
                tags[#tags + 1] = { key = k, num = tonumber(k) }
                hasFloat = true
            end
        end
        if hasFloat then
            tsort(tags, function(a, b) return a.num < b.num end)
        end
    elseif dirInfo.DataMember then
        -- extract only the DataMember tags (upstream ProcessBinaryData's
        -- `$$dirInfo{DataMember}` branch, used by WriteBinaryData to stash
        -- the data-member values -- e.g. Canon LensType/FocalUnits -- before
        -- the write conversions need them)
        for _, idx in ipairs(dirInfo.DataMember) do
            tags[#tags + 1] = { key = idx, num = idx }
        end
    else
        -- extract known tags in numerical order
        for k in pairs(tagTablePtr) do
            if not ExifTool.specialTags[k] and tonumber(k) ~= nil then
                tags[#tags + 1] = { key = k, num = tonumber(k) }
            end
        end
        tsort(tags, function(a, b)
            return (a.num < 0 and a.num + 1e9 or a.num) < (b.num < 0 and b.num + 1e9 or b.num)
        end)
    end
    -- avoid creating unknown tags for tags that fail condition if Unknown is 1
    -- (upstream `$unknown < 2`, with an undefined Unknown counting as 0)
    if not (unknown and unknown > 1) then self.NO_UNKNOWN = 1 end
    local nextIndex = 0
    local varSize = 0
    local val_h = {}    -- (upstream's %val, next to $val: the values found so far by index)
    for _, tagEntry in ipairs(tags) do
        local index = tagEntry.num
        -- (the original table key is used for lookup so string keys like "0.1"
        --  resolve correctly; the numeric value drives the entry offset)
        local tagInfo
        local saveNextIndex
        if tagTablePtr[tagEntry.key] ~= nil then
            tagInfo = self:GetTagInfo(tagTablePtr, tagEntry.key)
            if not tagInfo then
                -- a Condition that inspects the raw value (e.g. FujiFilm RAF's
                -- RAFCompression, gated on "$$valPt =~ /^\0\0\0/") can't match
                -- without a value; peek up to 128 raw bytes at this entry's
                -- position and retry, mirroring upstream ProcessBinaryData's
                -- two-step GetTagInfo lookup
                local entryPeek = math.floor(index) * increment + varSize
                if entryPeek < 0 then entryPeek = entryPeek + size end
                if entryPeek >= 0 and entryPeek < size then
                    local morePeek = size - entryPeek
                    if morePeek > 128 then morePeek = 128 end
                    local v = dataPt:sub(dirStart + entryPeek + 1, dirStart + entryPeek + morePeek)
                    tagInfo = self:GetTagInfo(tagTablePtr, tagEntry.key, v)
                end
                if not tagInfo then goto continueBinTag end
            end
            if tagInfo.Unknown and (tagInfo.Unknown > (unknown or 0) or index < nextIndex) then
                goto continueBinTag
            end
        elseif topIndex and tagTablePtr[index - topIndex] ~= nil then
            tagInfo = self:GetTagInfo(tagTablePtr, index - topIndex)
            if not tagInfo then goto continueBinTag end
        else
            -- don't generate unknown tags in binary tables unless Unknown > 1
            if not (unknown and unknown > 1) then goto continueBinTag end
            if index < nextIndex then goto continueBinTag end -- skip if data already used
            tagInfo = self:GetTagInfo(tagTablePtr, tagEntry.key)
            if not tagInfo then goto continueBinTag end
            tagInfo.Unknown = 2 -- set unknown to 2 for binary unknowns
        end
        -- record the byte offset as the tag ID (upstream ProcessBinaryData)
        tagInfo.TagID = index
        -- get relative offset of this entry
        local entry = math.floor(index) * increment + varSize
        if entry < 0 then
            entry = entry + size
        end
        local more = size - entry
        if more <= 0 then break end -- all done if we reached the end of data
        local count = 1
        local format = tagInfo.Format
        local val
        -- upstream sets $wasVar for every var_XXX branch: used below to
        -- skip the "next valid index" step-by-count math for Unknown>1
        -- scanning, since a variable-length value's own varSize update
        -- already accounts for the bytes it consumed
        local wasVar = false
        local readNow = false
        if format == 'var_ustr32' then
            -- variable-length UTF-16 string: 4-byte length (in characters)
            -- followed by the UTF-16 (big-endian) data
            wasVar = true
            if more < 4 then break end
            local n = ExifTool.Get32u(dataPt, entry + dirStart)
            entry = entry + 4
            more = more - 4
            -- increment next index for the int32u length word (upstream:
            -- "$nextIndex += 4 / $increment"), independent of and prior to
            -- the Unknown>1 step-by-count math below -- this is what lets a
            -- following fixed-index tag (e.g. Photoshop VersionInfo's
            -- ReaderName right after WriterName) resume at its real byte
            -- position instead of the scan spraying unknown tags across the
            -- string's own bytes
            nextIndex = nextIndex + 4 / increment
            local bytes = n * 2
            if bytes > more then bytes = more end
            val = decodeUTF16BE(substr(dataPt, entry + dirStart, bytes))
            varSize = varSize + bytes
            -- upstream strips the `var_` prefix and sets `$count` to the
            -- resolved byte length for every var_XXX branch (used both by
            -- ProcessBinaryData's own VerboseInfo call below and by
            -- Unknown>1's step-by-count math) -- without this, -v2 showed
            -- the raw declared `var_ustr32[1]` instead of the resolved
            -- `ustr32[N]`
            format = 'ustr32'
            count = bytes
            if dirInfo.VarFormatData then
                dirInfo.VarFormatData[#dirInfo.VarFormatData + 1] = { index, varSize, 'ustr32' }
            end
        elseif format == 'var_ue7' then
            -- BPG's variable-length "ue7" integer (1-5 bytes)
            wasVar = true
            local ue7Val, ue7Count = loadModule('BPG').Get_ue7(dataPt, entry + dirStart)
            if ue7Val == nil then break end
            val = ue7Val
            -- (count includes the base size of 1 byte already covered by increment)
            varSize = varSize + (ue7Count - 1)
            format = 'ue7'
            count = ue7Count
            if dirInfo.VarFormatData then
                dirInfo.VarFormatData[#dirInfo.VarFormatData + 1] = { index, varSize, 'ue7' }
            end
        elseif format == 'var_pstr32' then
            -- variable-length Pascal string: 4-byte length followed by
            -- that many bytes (upstream ProcessBinaryData's `var_pstr32`
            -- branch; used by FLAC.Picture's MIME type/description)
            wasVar = true
            if more < 4 then break end
            local n = ExifTool.Get32u(dataPt, entry + dirStart)
            entry = entry + 4
            more = more - 4
            -- increment next index for the int32u length word (see the
            -- var_ustr32 branch above for why)
            nextIndex = nextIndex + 4 / increment
            if n > more then n = more end
            val = substr(dataPt, entry + dirStart, n)
            varSize = varSize + n
            format = 'pstr32'
            count = n
            if dirInfo.VarFormatData then
                dirInfo.VarFormatData[#dirInfo.VarFormatData + 1] = { index, varSize, 'pstr32' }
            end
        elseif format == 'var_int16u' then
            -- int16u size of binary data to follow (upstream
            -- ProcessBinaryData's `var_int16u` branch; used by CanonVRD's
            -- CustomPictureStyleData)
            wasVar = true
            if more < 2 then break end
            local n = ExifTool.Get16u(dataPt, entry + dirStart) + 2
            varSize = varSize - 2   -- ($count includes size word)
            if n > more then n = more end
            varSize = varSize + n   -- shift subsequent indices
            val = substr(dataPt, entry + dirStart, n)
            format = 'undef'
            count = n
            if dirInfo.VarFormatData then
                dirInfo.VarFormatData[#dirInfo.VarFormatData + 1] = { index, varSize, 'undef' }
            end
        elseif format == 'var_string' then
            -- variable-length null-terminated ASCII string (upstream
            -- ProcessBinaryData's generic `var_XXX` fallback: scan
            -- forward for the first NUL, clamp to the block's remaining
            -- bytes; used by LNK's TrackerData MachineID)
            wasVar = true
            local nul = dataPt:find('\0', entry + dirStart + 1, true)
            local n = nul and (nul - (entry + dirStart + 1)) or more
            if n > more then n = more end
            val = substr(dataPt, entry + dirStart, n)
            varSize = varSize + n
            format = 'string'
            count = n
            if dirInfo.VarFormatData then
                dirInfo.VarFormatData[#dirInfo.VarFormatData + 1] = { index, varSize, 'string' }
            end
        else
            if not format then
                format = defaultFormat
            elseif format == 'string' then
                -- string with no specified count runs to end of block
                count = more
            elseif not formatSize[format] then
                local fm, fc = format:match('^(.*)%[(.*)%]$')
                if fm then
                    -- handle format count field
                    format = fm
                    count = tonumber(fc)
                    if count == nil then
                        -- a `[$val{N}]` count reference resolves against the
                        -- named tag's already-extracted value in this
                        -- directory (upstream ProcessBinaryData evaluates
                        -- `$val{N}` from the values found so far, e.g.
                        -- FLAC.Picture's `undef[$val{7}]`)
                        local refIndex = fc and fc:match('^%$val%{(%d+)%}$')
                        -- a literal `[$$self{Key}]` count reference resolves
                        -- against a value the table's own RawConv previously
                        -- stashed directly on the ExifTool object (upstream's
                        -- `$$self{Key}` -- distinct from `$val{N}` above,
                        -- which reads a found tag's value instead, e.g.
                        -- ZIP.Main's `string[$$self{ZipFileNameLength}]`)
                        local selfKey = fc and fc:match('^%$%$self%{([A-Za-z0-9]+)%}$')
                        if not refIndex and not selfKey then
                            -- a `N*$val{K}` multiplier form (FLIR.PaletteInfo's
                            -- `undef[3*$$self{PaletteColors}]` uses $$self,
                            -- but keep both spellings working)
                            local mult, ref2
                            if fc then mult, ref2 = fc:match('^(%d+)%*%$val%{(%d+)%}$') end
                            if mult and ref2 then
                                local refTag = tagTablePtr[tonumber(ref2)]
                                local refName = type(refTag) == 'table' and refTag.Name or nil
                                local refVal = refName and self.VALUE[refName]
                                count = (refVal and tonumber(refVal) or 1) * tonumber(mult)
                            end
                        end
                        if refIndex then
                            local refTag = tagTablePtr[tonumber(refIndex)]
                            local refName = type(refTag) == 'table' and refTag.Name or nil
                            local refVal = refName and self.VALUE[refName]
                            count = refVal and tonumber(refVal) or 1
                        elseif selfKey then
                            local refVal = self[selfKey]
                            count = refVal and tonumber(refVal) or 1
                        else
                            -- a `[$size-N]`, `[$size-0xNN]` or
                            -- `[$size-N-$varSize]` count expression resolves
                            -- against the directory's total size (upstream
                            -- `eval $count` with `$size`/`$varSize` in
                            -- scope, e.g. LNK.TargetInfo's `undef[$size-14]`,
                            -- LNK.Beef0004's `undef[$size-20-$varSize]` and
                            -- FLIR.RawData's `undef[$size-0x20]`,
                            -- "read to end of block")
                            local sizeSub = fc and fc:match('^%$size%-(%d+)%-%$varSize$')
                            local withVarSize = sizeSub ~= nil
                            if not sizeSub then sizeSub = fc and fc:match('^%$size%-0x(%x+)$') end
                            if sizeSub and fc:match('^%$size%-0x') then
                                count = size - tonumber(sizeSub, 16) - (withVarSize and varSize or 0)
                            else
                                if not sizeSub then sizeSub = fc and fc:match('^%$size%-(%d+)$') end
                                if sizeSub then
                                    count = size - tonumber(sizeSub) - (withVarSize and varSize or 0)
                                end
                            end
                        end
                    end
                    if count == nil then
                        -- evaluate count to allow count to be based on previous values
                        --### eval Format size (%val, $size, $varSize, $self)
                        local ok, res = pcall(perl.eval, fc, { val = val_h, size = size, varSize = varSize, self = self })
                        if not ok then
                            perl.warn('Format ' .. tagInfo.Name .. ': ' .. tostring(res))
                            goto continueBinTag
                        end
                        count = perl.num(res)
                        if count < 0 then goto continueBinTag end
                    end
                end
            end
            readNow = true
        end
        -- hook to allow format, etc to be set dynamically (upstream
        -- ProcessBinaryData's `$$tagInfo{Hook}` eval, which has $format,
        -- $varSize and $size in scope; evaluated before this tag's value
        -- is read, as upstream, so a new format (QuickTime's
        -- `$format = "int64u"`) applies to this tag, while the $varSize
        -- change only shifts the position of *subsequent* entries, e.g.
        -- Pentax AEInfo's `'$size > 20 and $varSize += 1'`. The Lua
        -- function returns the $varSize delta and, optionally, the new
        -- format.)
        local offAdj
        if tagInfo.Hook then
            local oldVarSize = varSize
            local delta, newFormat = tagInfo.Hook(self, format, varSize, size, dataPt, entry + dirStart)
            if delta and delta ~= 0 then varSize = varSize + delta end
            if newFormat then format = newFormat end
            -- save variable size data if required for writing (in case changed by Hook)
            if dirInfo.VarFormatData then
                if wasVar then table.remove(dirInfo.VarFormatData) end -- remove previous entry for this tag
                dirInfo.VarFormatData[#dirInfo.VarFormatData + 1] = { index, varSize, format }
            elseif varSize ~= oldVarSize and verbose and verbose > 2 then
                local tmp, sign = varSize, '+'
                if tmp < 0 then tmp = -tmp; sign = '-' end
                offAdj = sprintf('%s[offsets adjusted by %s0x%.4x after 0x%.4x %s]\n', self.INDENT, sign, tmp, index, tagInfo.Name)
            end
        end
        -- read value now if necessary
        if readNow then
            val = ExifTool.ReadValue(dataPt, entry + dirStart, format, count, more)
        end
        if unknown and unknown > 1 then
            -- calculate next valid index for unknown tag
            local ni = math.floor(index)
            if not wasVar then
                ni = ni + ((formatSize[format] or 1) * count) / increment
            end
            saveNextIndex = nextIndex
            if nextIndex <= ni then nextIndex = ni end
        end
        if val ~= nil then
            -- apply Mask/BitShift if specified (upstream ProcessBinaryData)
            if tagInfo.Mask then
                val = (val & tagInfo.Mask) >> (tagInfo.BitShift or 0)
            end
            -- print verbose tag information (upstream ProcessBinaryData's
            -- per-entry VerboseInfo call)
            if verbose and verbose > 0 and not perlTruthy(tagInfo.Hidden) then
                local len = more
                if not (tagInfo.SubDirectory and not tagInfo.Format) then
                    len = count * (formatSize[format] or 1)
                    if len > more then len = more end
                end
                self:VerboseInfo(index, tagInfo, {
                    Table  = tagTablePtr,
                    Value  = val,
                    DataPt = dataPt,
                    Size   = len,
                    Start  = entry + dirStart,
                    Addr   = entry + dirStart + (dirInfo.Base or 0) + (dirInfo.DataPos or 0),
                    Format = format,
                    Count  = count,
                    Extra  = tagInfo.Mask and sprintf(', mask 0x%.2x', tagInfo.Mask) or nil,
                })
            end
            if offAdj then self:VPrint(2, offAdj) end
            -- parse nested BinaryData directories
            if tagInfo.SubDirectory then
                local subdir = tagInfo.SubDirectory
                local subTablePtr = self:GetTagTable(subdir.TagTable)
                -- use specified subdirectory length if given (upstream
                -- ProcessBinaryData: a tag with its own Format/count, like
                -- Canon ColorData1's `undef[120]` ColorCalib, bounds the
                -- subdirectory to that many bytes instead of handing it
                -- the rest of the enclosing directory's data)
                local len
                if tagInfo.Format and formatSize[format] then
                    len = count * formatSize[format]
                    if len > more then len = more end
                else
                    len = more -- directory size is all of remaining data
                    if subTablePtr.PROCESS_PROC == ExifTool.ProcessBinaryData then
                        -- the rest of the data will be printed in the subdirectory
                        nextIndex = size / increment
                    end
                end
                local subdirBase = dirInfo.Base or 0
                if subdir.Base ~= nil then
                    -- (upstream: eval Base with $start, $base)
                    subdirBase = subdir.Base(self, val, entry + dirStart + (dirInfo.DataPos or 0)) + (dirInfo.Base or 0)
                end
                local start = subdir.Start or 0
                local notDup
                if type(start) == 'function' then
                    -- (upstream: a Start containing `$` is evaluated)
                    -- ignore directories with a zero offset (ie. missing Nikon ShotInfo entries)
                    if not perlTruthy(val) then goto continueBinTag end
                    -- (eval Start with $val, $dirStart)
                    start = start(self, val, dirStart)
                    if start < dirStart or start > dataLen then goto continueBinTag end
                    len = subdir.DirLen
                    if not (perlTruthy(len) and len <= dataLen - start) then len = dataLen - start end
                else
                    start = start + dirStart + entry
                    notDup = 1
                end
                self.NO_UNKNOWN = nil
                self:ProcessDirectory({
                    DataPt = dataPt,
                    DataPos = dirInfo.DataPos,
                    DataLen = dataLen,
                    DirStart = start,
                    DirLen = len,
                    Base = subdirBase,
                    NotDup = notDup,
                }, subTablePtr, subdir.ProcessProc)
                if not (unknown and unknown > 1) then self.NO_UNKNOWN = 1 end
                goto continueBinTag
            end
            if tagInfo.IsOffset and perl.str(tagInfo.IsOffset) ~= '3' then
                local et = self
                --#### eval IsOffset ($val, $et)
                -- (an IsOffset condition string is a Lua function(et, val)
                --  in the port; the only string condition left is MPF's '$val')
                local isOffset = tagInfo.IsOffset
                if type(isOffset) == 'function' then
                    isOffset = isOffset(et, val)
                elseif isOffset == '$val' then
                    isOffset = val
                end
                if perlTruthy(isOffset) then val = val + (dirInfo.Base or 0) + (self.BASE or 0) end
            end
            val_h[ExifTool.NumStr(index)] = val
            local oldBase   -- (false: not saved; Perl tests `defined $oldBase`)
            if perlTruthy(tagInfo.SetBase) then
                oldBase = self.BASE or 0
                self.BASE = (self.BASE or 0) + (dirInfo.Base or 0)
            end
            local key = self:FoundTag(tagInfo, val)
            if oldBase then self.BASE = oldBase end
            if not key and saveNextIndex ~= nil then
                -- don't increment nextIndex if we didn't extract a tag
                nextIndex = saveNextIndex
            end
        end
        ::continueBinTag::
    end
    self.NO_UNKNOWN = nil
    return 1
end

-- (PROCESS_PROC is set here so the JFIF table can reference ProcessBinaryData,
--  which is defined above)
ExifTool.JFIF.Main.PROCESS_PROC = ExifTool.ProcessBinaryData

--..............................................................................
-- (port artifacts for the config file, see doc/configuration.md: a config
--  file for lexiftool is Lua, a chunk that returns a table whose keys are
--  upstream's package variables -- 'UserDefined' (or
--  'Image::ExifTool::UserDefined'), 'Shortcuts', 'Options', 'Lenses',
--  'FileTypes', 'Arguments', 'Geolocation' (or the same names below
--  'Image::ExifTool::UserDefined::'), and 'Image::ExifTool::UserDefined::NAME'
--  for a tag table of the UserDefined package.  Loading it does what the
--  Perl assignments in an .ExifTool_config do: it fills ExifTool.UserDefined
--  (keyed by the port's table names), ExifTool.UserDefinedTables,
--  ExifTool.UserDefinedOptions and ExifTool.UserDefinedArguments, which the
--  ported code reads where upstream reads the package variables)

-- the names below Image::ExifTool::UserDefined:: that are not tag tables
-- (Options and Arguments have their own fields, the others are entries of
--  ExifTool.UserDefinedTables, as Shortcuts.lua reads them)
local configVars = { Shortcuts = 1, Lenses = 1, FileTypes = 1, Geolocation = 1 }

-- the port's name of a table named as upstream names it
-- ('Image::ExifTool::Exif::Main' -> 'lexiftool.Exif.Main', and the tables
--  ExifTool.pm itself defines: 'Image::ExifTool::Composite' ->
--  'lexiftool.ExifTool.Composite'); nil for a name outside Image::ExifTool
local function configTableName(name)
    local rest = type(name) == 'string' and name:match('^Image::ExifTool::(.+)$')
    if not rest then return nil end
    if not rest:find('::', 1, true) then return 'lexiftool.ExifTool.' .. rest end
    return 'lexiftool.' .. rest:gsub('::', '.')
end

-- Perl expression strings in a config file's conversions go through the
-- perl.eval subset (doc/differences.md); like upstream's eval in package
-- Image::ExifTool they can call the ExifTool functions (GetFileType, ...)
local evalFuncs = setmetatable({ }, { __index = function(_, name)
    local func = ExifTool[name]
    if type(func) == 'function' then return func end
    return nil
end })
-- (a Composite tag's @val/@prt: 0-based tables -> 1-based sequences)
local function evalList(t)
    local list, n = { }, -1
    for k in pairs(t or { }) do
        if math.type(k) == 'integer' and k > n then n = k end
    end
    for i = 0, n do list[i + 1] = t[i] end
    return list
end
-- a conversion given as a Perl expression string, as a function with the
-- port's calling convention for that field
local function configConv(code, field, isComposite)
    if isComposite and (field == 'ValueConv' or field == 'PrintConv') then
        -- ($val is $val[0] in a Composite ValueConv string, as upstream's
        --  GetValue sets it; @val and @prt are the Require'd/Desire'd values)
        local evalCode = '@val = @lexiftoolVal; @prt = @lexiftoolPrt; ' .. code
        if field == 'ValueConv' then
            return function(self, vals, prts)
                return perl.eval(evalCode, { val = vals[0], self = self, lexiftoolVal = evalList(vals),
                                             lexiftoolPrt = evalList(prts) }, evalFuncs)
            end
        end
        return function(self, val, vals, prts)
            return perl.eval(evalCode, { val = val, self = self, lexiftoolVal = evalList(vals),
                                         lexiftoolPrt = evalList(prts) }, evalFuncs)
        end
    elseif field == 'RawConvInv' then
        return function(self, val, tagInfo)
            return perl.eval(code, { val = val, self = self, tagInfo = tagInfo }, evalFuncs)
        end
    elseif field == 'ValueConvInv' or field == 'PrintConvInv' then
        return function(self, val, wantGroup)
            return perl.eval(code, { val = val, self = self, wantGroup = wantGroup }, evalFuncs)
        end
    elseif field == 'Condition' then
        -- (GetTagInfo reads "needs the value" off the parameter list)
        if perl.isMatch(code, [[\$(valPt|format|count)\b]]) then
            return function(self, val, format, count)
                return perl.eval(code, { self = self, valPt = val, format = format, count = count }, evalFuncs)
            end
        end
        return function(self)
            return perl.eval(code, { self = self }, evalFuncs)
        end
    end
    return function(self, val, tag)
        return perl.eval(code, { val = val, self = self, tag = tag }, evalFuncs)
    end
end
local configConvFields = { 'Condition', 'RawConv', 'ValueConv', 'PrintConv', 'RawConvInv',
                           'ValueConvInv', 'PrintConvInv' }
-- prepare a tag information hash of a config file: Perl expression strings
-- become functions, SubDirectory table names the port's names
local function configTagInfo(tagInfo, isComposite)
    if type(tagInfo) ~= 'table' then return end
    if type(tagInfo[1]) == 'table' then     -- (a list of conditional tags)
        for _, info in ipairs(tagInfo) do configTagInfo(info, isComposite) end
        return
    end
    for _, field in ipairs(configConvFields) do
        if type(tagInfo[field]) == 'string' then
            tagInfo[field] = configConv(tagInfo[field], field, isComposite)
        end
    end
    local subdir = tagInfo.SubDirectory
    if type(subdir) == 'table' and configTableName(subdir.TagTable) then
        configTableNames[configTableName(subdir.TagTable)] = subdir.TagTable
        subdir.TagTable = configTableName(subdir.TagTable)
    end
    -- (structure fields are tag information hashes too)
    if type(tagInfo.Struct) == 'table' then
        for field, fieldInfo in pairs(tagInfo.Struct) do
            if field ~= 'NAMESPACE' then configTagInfo(fieldInfo) end
        end
    end
end

-- take over the package variables a config file defines
local function applyConfig(config, file)
    for key, val in pairs(config) do
        local name = type(key) == 'string' and (key:match('^Image::ExifTool::UserDefined::(.+)$') or key)
        if key == 'UserDefined' or key == 'Image::ExifTool::UserDefined' then
            local userDefined = { }
            for perlName, tags in pairs(val) do
                local tableName = configTableName(perlName)
                if not tableName then
                    perl.warn("Bad table name '" .. perl.str(perlName) .. "' in config file " .. file .. "\n")
                else
                    configTableNames[tableName] = perlName
                    for _, tagInfo in pairs(tags) do
                        configTagInfo(tagInfo, tableName == 'lexiftool.ExifTool.Composite')
                    end
                    userDefined[tableName] = tags
                end
            end
            ExifTool.UserDefined = userDefined
        elseif name == 'Options' then
            ExifTool.UserDefinedOptions = val
        elseif name == 'Arguments' then
            ExifTool.UserDefinedArguments = val
        elseif name and configVars[name] then
            ExifTool.UserDefinedTables[name] = val
            -- (Shortcuts.lua takes them over when it loads, as upstream's)
            if name == 'Shortcuts' and package.loaded['lexiftool.Shortcuts'] then
                package.loaded['lexiftool.Shortcuts'].LoadShortcuts(val)
            end
        elseif name and name ~= key and type(val) == 'table' then
            -- a tag table of the UserDefined package
            for tagID, tagInfo in pairs(val) do
                if not ExifTool.specialTags[tagID] then configTagInfo(tagInfo) end
            end
            ExifTool.UserDefinedTables[name] = val
        else
            perl.warn("Unknown entry '" .. perl.str(key) .. "' in config file " .. file .. "\n")
        end
    end
end

-- a config file sees the Lua basics and the lexiftool modules, nothing of
-- os/io (it is trusted code like upstream's, the environment only keeps it
-- from depending on the host program's globals)
local function configRequire(name)
    if name == 'lexiftool' or (type(name) == 'string' and name:match('^lexiftool%.')) then
        return require(name)
    end
    error("module '" .. perl.str(name) .. "' is not available in a lexiftool config file", 2)
end
local function configEnv()
    local env = { require = configRequire, _VERSION = _VERSION }
    for _, k in ipairs({ 'assert', 'error', 'getmetatable', 'ipairs', 'next', 'pairs', 'pcall',
                         'rawequal', 'rawget', 'rawlen', 'rawset', 'select', 'setmetatable',
                         'tonumber', 'tostring', 'type', 'xpcall' }) do
        env[k] = _G[k]
    end
    for _, lib in ipairs({ 'math', 'string', 'table', 'utf8' }) do
        local copy = { }
        for k, v in pairs(_G[lib]) do copy[k] = v end
        env[lib] = copy
    end
    return env
end

-- is this config file Lua?  (a name ending in .lua, lexiftool's own
-- .lexiftool_config, or a first line "-- lexiftool config"; anything else
-- is an exiftool config file, i.e. Perl)
local function isLuaConfig(file, text)
    if file:match('%.lua$') or file:match('[^/\\]*$') == '.lexiftool_config' then return true end
    return text:match('^%-%-[ \t\n\r\f\v]*lexiftool config') ~= nil
end

-- load a Lua config file: errors are warned with file:line, as upstream
-- warns a config file's $@, and the file then defines nothing
-- (the chunk gets a placeholder name that the messages then spell as the
--  file name, since Lua shortens a long chunk name with "...")
local function loadLuaConfig(text, file)
    local chunk, err = load(text, '=lexiftool_config', 't', configEnv())
    local ok, config = false, nil
    if chunk then
        ok, config = pcall(chunk)
        if not ok then err = config end
    end
    if not ok then
        err = tostring(err):gsub('lexiftool_config:', (file:gsub('%%', '%%%%')) .. ':')
        perl.warn(err .. "\n")
    elseif type(config) ~= 'table' then
        perl.warn("Config file " .. file .. " did not return a table\n")
    else
        applyConfig(config, file)
    end
end

-- (the directory of the program, upstream's $exeDir; Perl's $0 is Lua's
--  arg[0], as main.lua reads it)
local function getExeDir()
    if ExifTool.exeDir == nil then
        local script = _G.arg and _G.arg[0]
        ExifTool.exeDir = script and perl.matches(script, [=[(.*)[\\\/]]=]) or '.'
    end
    return ExifTool.exeDir
end

--..............................................................................
-- Load .ExifTool_config file from user's home directory
-- (use of noConfig is now deprecated, use configFile = '' instead)
-- (port: upstream runs this block at file scope, when `use Image::ExifTool`
--  loads the module -- after the exiftool script's BEGIN block has pushed
--  the -config files onto @configFiles.  Lua has no BEGIN that runs before
--  a require, so here the block is ExifTool.LoadConfigFiles and runs once:
--  from main right after its -config scan (where upstream's `use` stands),
--  else from the first ExifTool.new(), so that a library user can still set
--  ExifTool.configFile/noConfig after the require, as upstream's BEGIN
--  does.  The file lookup, the "Config file not found" warning and the
--  %ENV reads are upstream's; the default file is lexiftool's own
--  .lexiftool_config where there is one, else .ExifTool_config.  Where
--  upstream loads the file (`eval { require $file }`, `eval $buff`), a Lua
--  config file is loaded (loadLuaConfig above); a Perl one, which lexiftool
--  cannot run, warns "Config file not supported by lexiftool (Perl code):
--  FILE" and is skipped, as with -config "")
ExifTool.configFiles = ExifTool.configFiles or { }
local configLoaded
function ExifTool.LoadConfigFiles()
    if configLoaded then return end
    configLoaded = true
    local configFiles = ExifTool.configFiles
    if ExifTool.configFile ~= nil then perl.push(configFiles, ExifTool.configFile) end
    while not perlTruthy(ExifTool.noConfig) do
        local config = perl.shift(configFiles)
        local file, wasConfig
        if config == nil then
            config = '.ExifTool_config'
            -- get our home directory (HOMEDRIVE and HOMEPATH are used in Windows cmd shell)
            local home = perl.getenv('EXIFTOOL_HOME')
            if not perlTruthy(home) then home = perl.getenv('HOME') end
            if not perlTruthy(home) then
                local drive, path = perl.getenv('HOMEDRIVE'), perl.getenv('HOMEPATH')
                if not perlTruthy(drive) then drive = '' end
                if not perlTruthy(path) then path = '' end
                home = drive .. path
            end
            if not perlTruthy(home) then home = '.' end
            -- (port: lexiftool's own .lexiftool_config, in the same places,
            --  takes the place of .ExifTool_config)
            if perl.filetest('r', home .. '/.lexiftool_config') or
                perl.filetest('r', getExeDir() .. '/.lexiftool_config')
            then
                config = '.lexiftool_config'
            end
            -- look for the config file in 1) the home directory, 2) the program dir
            file = home .. '/' .. config
        else
            config = perl.str(config)
            if perl.length(config) == 0 then break end -- filename of "" disables configuration
            file = config
            wasConfig = 1
        end
        if file == '-' then
            -- (upstream reads the piped config file from STDIN and evals it)
            local buff = io.stdin:read(100000000) or ''
            local n = #buff
            if n == 100000000 then
                perl.warn("Piped config file is too large\n")
            elseif n > 0 then
                if isLuaConfig(file, buff) then
                    loadLuaConfig(buff, file)
                else
                    perl.warn("Config file not supported by lexiftool (Perl code): -\n")
                end
            end
        else
            -- also check executable directory unless path is absolute
            if not perl.filetest('r', file) and not perl.isMatch(config, '^/') then
                file = getExeDir() .. '/' .. config
            end
            if not perl.filetest('r', file) then
                if wasConfig then perl.warn("Config file not found\n") end
                break
            end
            -- (upstream: `eval { require $file }`)
            local fh = io.open(file, 'rb')
            local text = fh and fh:read('a') or ''
            if fh then fh:close() end
            if isLuaConfig(file, text) then
                loadLuaConfig(text, file)
            else
                perl.warn("Config file not supported by lexiftool (Perl code): " .. file .. "\n")
            end
        end
        if #configFiles == 0 then break end
    end
    -- read user-defined lenses (may have been defined by script instead of config file)
    local lenses = ExifTool.UserDefinedTables.Lenses
    if lenses and #lenses > 0 then
        if not ExifTool.userLens then ExifTool.userLens = { } end
        for _, lens in ipairs(lenses) do
            ExifTool.userLens[lens] = 1
        end
    end
    -- add user-defined file types
    local userFileTypes = ExifTool.UserDefinedTables.FileTypes
    if userFileTypes and next(userFileTypes) ~= nil then
        local keys = { }
        for k in pairs(userFileTypes) do keys[#keys + 1] = k end
        for _, k in ipairs(perl.sort(keys)) do
            local fileInfo = userFileTypes[k]
            local type_ = perl.uc(k)
            if type(fileInfo) ~= 'table' then
                fileTypeLookup[type_] = fileInfo
                goto nextType
            end
            do
                local baseType = fileInfo.BaseType
                if perlTruthy(baseType) then
                    if perlTruthy(fileInfo.Description) then
                        fileTypeLookup[type_] = { baseType, fileInfo.Description }
                    else
                        fileTypeLookup[type_] = baseType
                    end
                    if fileInfo.Writable ~= nil and not perlTruthy(fileInfo.Writable) then
                        -- first make sure we are using an actual base type and not a derived type
                        while perlTruthy(baseType) and type(fileTypeLookup[baseType]) ~= 'table' do
                            baseType = fileTypeLookup[baseType]
                        end
                        baseType = baseType or ''
                        -- mark this type as not writable
                        if not noWriteFile[baseType] then noWriteFile[baseType] = { } end
                        perl.push(noWriteFile[baseType], type_)
                    end
                else
                    fileTypeLookup[type_] = { type_, perlTruthy(fileInfo.Description) and fileInfo.Description or type_ }
                    moduleName[type_] = 0 -- not supported
                    if perlTruthy(fileInfo.Magic) then
                        magicNumber[type_] = fileInfo.Magic
                        local found
                        for _, t in ipairs(fileTypes) do
                            if t == type_ then found = true break end
                        end
                        if not found then perl.push(fileTypes, type_) end
                    end
                end
                if fileInfo.MIMEType ~= nil then mimeType[type_] = fileInfo.MIMEType end
            end
            ::nextType::
        end
    end
end

-- WriteBinaryData (the write-side counterpart of ProcessBinaryData) lives in
-- lexiftool.Writer, matching the upstream module layout (Writer.pl).

--------------------------------------------------------------------------------
-- TIFF / EXIF dispatch
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Extract metadata from an Exiv2 EXV file
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref with RAF set
-- Returns: 1 on success, 0 if this wasn't a valid JPEG file
function ExifTool:ProcessEXV(dirInfo)
    return self:ProcessJPEG(dirInfo)
end

--------------------------------------------------------------------------------
-- Process EXIF file
-- Inputs/Returns: same as ProcessTIFF
function ExifTool:ProcessEXIF(dirInfo, tagTablePtr)
    return self:ProcessTIFF(dirInfo, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Process TIFF data as a sub-document (upstream ProcessSubTIFF)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) optional tag table ref
-- Returns: 1 if this looked like a valid EXIF block, 0 otherwise
function ExifTool.ProcessSubTIFF(self, dirInfo, tagTablePtr)
    self.DOC_COUNT = (self.DOC_COUNT or 0) + 1
    self.DOC_NUM = self.DOC_COUNT
    local rtnVal = self:ProcessTIFF(dirInfo, tagTablePtr)
    self.DOC_NUM = nil
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process TIFF data (wrapper for DoProcessTIFF to allow re-entry)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) optional tag table ref
-- Returns: 1 if this looked like a valid EXIF block, 0 otherwise, or -1 on write error
function ExifTool:ProcessTIFF(dirInfo, tagTablePtr)
    local exifData = self.EXIF_DATA
    local exifPos = self.EXIF_POS
    local rtnVal = self:DoProcessTIFF(dirInfo, tagTablePtr)
    -- restore original EXIF information (in case ProcessTIFF is nested)
    if exifData ~= nil then
        self.EXIF_DATA = exifData
        self.EXIF_POS = exifPos
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process TIFF data
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) optional tag table ref
-- Returns: 1 if this looked like a valid EXIF block, 0 otherwise, or -1 on write error
-- (read subset of upstream DoProcessTIFF)
local processTIFFWrite   -- (DoProcessTIFF's write branch, defined below)
function ExifTool:DoProcessTIFF(dirInfo, tagTablePtr)
    -- (upstream DoProcessTIFF writes the file when $$dirInfo{OutFile} is set;
    --  the port keeps that branch in its own function)
    if dirInfo.OutFile then return processTIFFWrite(self, dirInfo) end
    local fileType = dirInfo.Parent or ''
    local raf = dirInfo.RAF
    local base = dirInfo.Base or 0
    local dataStr
    -- upstream DoProcessTIFF: `$$self{EXIF_POS} = $base + $$self{BASE};` --
    -- needed so HtmlDump's per-entry "Actual offset"/"Offset base" tooltip
    -- math (Exif.pm ProcessExif) resolves to the same offset as the raw
    -- stored one for ordinary (non-rebased) tags
    self.EXIF_POS = base + (self.BASE or 0)
    -- upstream: `$$self{FIRST_EXIF_POS} = $$self{EXIF_POS} unless defined
    -- $$self{FIRST_EXIF_POS};` -- remembers the position of the *first*
    -- TIFF/EXIF block found in the file, used as the HtmlDump address-column
    -- zero point (ExifTool.pm:3163) so bytes before it (e.g. the JPEG SOI/
    -- APP1 segment header) get negative address labels
    if self.FIRST_EXIF_POS == nil then self.FIRST_EXIF_POS = self.EXIF_POS end

    if raf then
        self.EXIF_DATA = ''
        raf:Seek(base, 0)
        local n
        n, dataStr = raf:Read(8)
        if n < 8 then return 0 end
        self.EXIF_DATA = dataStr
    elseif dirInfo.DataPt then
        -- in-memory EXIF block (e.g. an APP1 segment, already sliced to the
        -- TIFF header by the caller)
        local dirStart = dirInfo.DirStart or 0
        local dirLen = dirInfo.DirLen or (#dirInfo.DataPt - dirStart)
        dataStr = dirInfo.DataPt:sub(dirStart + 1, dirStart + dirLen)
        self.EXIF_DATA = dataStr
        -- upstream ProcessTIFF: `length($$self{INDENT}) > 2` -- only print
        -- the "+ [TIFF directory]" header when this isn't the top-level
        -- EXIF/TIFF of the whole file (INDENT is still just "  " there),
        -- e.g. Photoshop's embedded EXIFInfo block
        if optOn(self.OPTIONS.Verbose) and #self.INDENT > 2 then
            self:VerboseDir('TIFF')
        end
    else
        return 0
    end
    -- set byte ordering
    local byteOrder = dataStr:sub(1, 2)
    if not ExifTool.SetByteOrder(byteOrder) then return 0 end

    -- identifier is 0x2a for plain TIFF, but varies for some RAW/BigTIFF
    -- formats (upstream ExifTool.pm ProcessTIFF: TIFF=0x2a, RW2/RWL=0x55,
    -- HDP=0xbc, BTF=0x2b, ORF=0x4f52/0x5352). Only BigTIFF is ported here.
    local identifier = ExifTool.Get16u(dataStr, 2)
    -- (fileType is dirInfo.Parent, which for a TIFF-signature file is the file
    --  EXTENSION -- so a .btf arrives as 'BTF' and a name-less buffer as
    --  'TIFF'. Upstream needs no such test at all: it reaches ProcessBTF
    --  straight from its file-type loop, while this port branches here.)
    if identifier == 0x2b and (fileType == 'TIFF' or fileType == 'BTF') and raf then
        raf:Seek(base, 0)
        return require('lexiftool.BigTIFF').ProcessBTF(self, dirInfo)
    end

    -- identifier is 0x2a for TIFF (but varies for some RAW formats)
    local offset = ExifTool.Get32u(dataStr, 4)
    if offset < 8 then return 0 end

    -- check for canon or EXIF signature (upstream DoProcessTIFF; Canon CR2
    -- images should have an offset of 16, but it may be greater if edited by
    -- PhotoMechanic). This is what makes TIFF_TYPE 'CR2' rather than plain
    -- 'TIFF', which several Exif.Main conditional tags key off (0x111/0x117
    -- are PreviewImageStart/Length in a CR2's IFD0, not Strip*).
    if raf and identifier == 0x2a and offset >= 16 then
        local n, sig = raf:Read(8)
        if n ~= 8 then return 0 end
        dataStr = dataStr .. sig
        self.EXIF_DATA = dataStr
        local sigMatched = true
        if sig == 'ExifMeta' then
            fileType = 'EXIF'
            self:SetFileType(fileType)
        elseif sig:sub(1, 4) == 'CR\2\0' then
            fileType = 'CR2'
        elseif sig:sub(1, 4) == '\186\176\172\187' then
            fileType = 'Canon 1D RAW'
        else
            sigMatched = false
        end
        if sigMatched and self.HTML_DUMP then
            self:HDump(base + 8, 8, '[' .. fileType .. ' header]')
        end
    end

    if fileType ~= '' and not self.VALUE.FileType then
        -- set file type (TIFF base)
        self:SetFileType(fileType)
    end
    -- set ExifByteOrder only for EXIF tables (upstream DoProcessTIFF)
    if not tagTablePtr or (tagTablePtr.GROUPS and tagTablePtr.GROUPS[0] == 'EXIF') then
        self:FoundTag('ExifByteOrder', byteOrder)
    end
    self.ExifByteOrder = byteOrder
    self.TIFF_TYPE = fileType

    tagTablePtr = tagTablePtr or self:GetTagTable('lexiftool.Exif.Main')

    -- directory name (upstream DoProcessTIFF: an explicit ExifIFD/GPS
    -- DirName from the caller wins, MakerNotes overrides, other non-EXIF
    -- tables take their group 1 name)
    local dirName
    if dirInfo.DirName == 'ExifIFD' or dirInfo.DirName == 'GPS' then
        dirName = dirInfo.DirName
    else
        dirName = 'IFD0'
    end
    if tagTablePtr.GROUPS then
        local g0 = tagTablePtr.GROUPS[0]
        if g0 == 'MakerNotes' then
            dirName = 'MakerNotes'
        elseif g0 ~= 'EXIF' then
            dirName = tagTablePtr.GROUPS[1] or 'IFD0'
        end
    end

    if self.HTML_DUMP then
        local tip = sprintf('Byte order: %s endian\nIdentifier: 0x%.4x\n%s offset: 0x%.4x',
            byteOrder == 'II' and 'Little' or 'Big', identifier, dirName, offset)
        self:HDump(base, 8, 'TIFF header', tip, 0)
    end

    -- Base: honor an explicitly-supplied dirInfo.Base verbatim (upstream
    -- DoProcessTIFF: `Base => $base, DataPos => 0`) -- callers are expected
    -- to pre-compute the true absolute Base themselves, mirroring upstream's
    -- DirStart($dirInfo, $start, $base) helper (Base = DataPos_before +
    -- $base) before calling ProcessTIFF (e.g. MIFF's hard-coded Base=12
    -- "usual position for EXIF data", or JPEG's APP1 EXIF segPos+hdrLen).
    -- Callers that don't set Base explicitly (nil) fall back to the same
    -- DataPos+DirStart auto-derivation this function used before, so any
    -- caller not (yet) updated to set Base explicitly keeps working.
    local dirInfo2 = {
        Base = dirInfo.Base ~= nil and dirInfo.Base or ((dirInfo.DataPos or 0) + (dirInfo.DirStart or 0)),
        DataPt = dataStr,
        DataLen = #dataStr,
        DataPos = 0,
        DirStart = offset,
        DirLen = #dataStr - offset,
        RAF = raf,
        DirName = dirName,
        Parent = fileType,
        ImageData = 'Main',
        Multi = dirInfo.Multi,
    }
    -- extract information from the image
    self:ProcessDirectory(dirInfo2, tagTablePtr)
    -- process GeoTiff information if available (upstream ExifTool.pm
    -- ProcessTIFF, after the main directory walk)
    if self.VALUE.GeoTiffDirectory then
        require('lexiftool.GeoTiff').ProcessGeoTiff(self)
    end
    -- process information in recognized trailers
    if raf then
        local trailInfo = self:IdentifyTrailer(raf)
        if trailInfo then
            -- scan to find AFCP if necessary (Note: we are scanning
            -- from a random file position in the TIFF)
            trailInfo.ScanForTrailer = 1
            self:ProcessTrailers(trailInfo)
        end
        -- dump any other known trailer (eg. A100 RAW Data)
        if self.HTML_DUMP and self.KnownTrailer then
            local known = self.KnownTrailer
            raf:Seek(0, 2)
            local len = raf:Tell() - known.Start
            if trailInfo then len = len - trailInfo.Offset end  -- account for other trailers
            if len > 0 then self:HDump(known.Start, len, '[' .. known.Name .. ']') end
        end
    end
    if rawget(self, 'ImageDataHash') and perlTruthy(self.A100DataOffset) and raf:Seek(self.A100DataOffset, 0) then
        self:ImageDataHash(raf, nil, 'A100')
    end
    return 1
end

--------------------------------------------------------------------------------
-- Identify trailer ending at specified offset from end of file
-- Inputs: 0) RAF reference, 1) offset from end of file (0 by default)
-- Returns: Trailer info hash (with RAF and DirName set),
--          or undef if no recognized trailer was found
-- Notes: leaves file position unchanged
function ExifTool:IdentifyTrailer(raf, offset)
    if not perlTruthy(offset) then offset = 0 end
    local pos = raf:Tell()
    local buff, type_, len
    while raf:Seek(-offset, 2) do -- luacheck: ignore 512 (upstream `while (...) { ...; last; }`)
        len = raf:Tell()
        if len <= 0 then break end
        -- read up to 64 bytes before specified offset from end of file
        if len > 64 then len = 64 end
        local n
        if raf:Seek(-len, 1) then n, buff = raf:Read(len) end
        if n ~= len then break end
        if perl.isMatch(buff, [[(?s)AXS(!|\*).{8}$]]) then
            type_ = 'AFCP'
        elseif perl.isMatch(buff, [[\xa1\xb2\xc3\xd4$]]) then
            type_ = 'FotoStation'
        elseif perl.isMatch(buff, [[cbipcbbl$]]) then
            type_ = 'PhotoMechanic'
        elseif perl.isMatch(buff, [[^CANON OPTIONAL DATA\0]]) then
            type_ = 'CanonVRD'
        elseif perl.isMatch(buff, [[(?s)~\0\x04\0zmie~\0\0\x06.{4}[\x10\x18]\x04$]]) or
               perl.isMatch(buff, [[(?s)~\0\x04\0zmie~\0\0\x0a.{8}[\x10\x18]\x08$]])
        then
            type_ = 'MIE'
        elseif perl.isMatch(buff, [[\0\0(QDIOBS|SEFT)$]]) then
            type_ = 'Samsung'
        elseif perl.isMatch(buff, [[(?s)8db42d694ccc418790edff439fe026bf$]]) then
            type_ = 'Insta360'
        elseif perl.isMatch(buff, [[\0{6}/NIKON APP$]]) then
            type_ = 'NikonApp'
        elseif perl.isMatch(buff, [[\xff{4}\x1b\*9HWfu\x84\x93\xa2\xb1$]]) then
            type_ = 'Vivo'
        elseif perl.isMatch(buff, [[(?s)jxrs...\0$]]) then
            type_ = 'OnePlus'
        elseif perlTruthy(self.ProcessGoogleTrailer) then
            -- check for Google trailer information if specific XMP tags exist
            type_ = 'Google'
        end
        break
    end
    raf:Seek(pos, 0)    -- restore original file position
    if type_ then return { RAF = raf, DirName = type_ } end
    return nil
end

--------------------------------------------------------------------------------
-- Read/rewrite trailer information (including multiple trailers)
-- Inputs: 0) ExifTool object ref, 1) DirInfo ref:
-- - requires RAF and DirName
-- - OutFile is a scalar reference for writing
-- - scans from current file position for each trailer if ScanForTrailer is set
--   (current file position is just after JPEG EOF for a JPEG image)
-- Returns: 1 if trailer was processed or couldn't be processed (or written OK)
--          0 if trailer was recognized but offsets need fixing (or write error)
-- - DirName, DirLen, DataPos, Offset, Fixup and OutFile are updated
-- - preserves current file position and byte order
function ExifTool:ProcessTrailers(dirInfo)
    local dirName = dirInfo.DirName
    local outfile = dirInfo.OutFile
    local offset = dirInfo.Offset or 0
    local fixup = dirInfo.Fixup
    local raf = dirInfo.RAF
    local pos = raf:Tell()
    local byteOrder = ExifTool.GetByteOrder()
    local success = 1
    local path = self.PATH

    -- get position of end of file
    raf:Seek(0,2)
    self.FileEnd = raf:Tell()

    while true do -- loop through all trailers
        raf:Seek(pos)
        -- (outBuff is the box \$outBuff; its value is Perl's $outBuff)
        local proc, outBuff
        -- trailer-processing procs residing in modules of a different name
        local module = ({
            Insta360 = 'QuickTimeStream.pl',
            NikonApp = 'Nikon.pm',
            Vivo     = 'Trailer.pm',
            OnePlus  = 'Trailer.pm',
            Google   = 'Trailer.pm',
        })[dirName] or dirName .. '.pm'
        require('lexiftool.' .. perl.subst(module, [[\..*]], ''))  -- (require "Image/ExifTool/$module")
        module = perl.subst(module, [[(Stream)?\..*]], '')   -- remove extension and change QuickTimeStream to QuickTime
        -- (package Image::ExifTool::$module is the Lua module lexiftool.$module)
        proc = require('lexiftool.' .. module)['Process' .. dirName]
        if outfile then
            -- write to local buffer so we can add trailer in proper order later
            if perlTruthy(outfile.value) then outBuff = { value = carray.new('char') }; dirInfo.OutFile = outBuff end
            -- must generate new fixup if necessary so we can shift
            -- the old fixup separately after we prepend this trailer
            dirInfo.Fixup = nil
        end
        dirInfo.DirLen = nil        -- reset trailer length
        dirInfo.Offset = offset     -- set offset from end of file
        dirInfo.Trailer = 1         -- set Trailer flag in case proc cares
        -- add trailer and DirName to SubDirectory PATH
        path[#path + 1] = 'Trailer'
        path[#path + 1] = dirName
--
-- Call proc to read or write this trailer
--
-- Proc inputs:
--   0) ExifTool ref, with FileEnd set, and TrailerStart possibly set (start of all trailers)
--   1) DirInfo with the following elements:
--        DirName - name of this trailer
--        RAF     - RAF reference
--        Offset  - positive offset from end of this trailer to the end of file
--        OutFile - (write mode) scalar reference for output buffer consisting of an empty string
--        Trailer - flag set so proc knows we are processing a trailer (if it cares)
--        Fixup   - optional fixup for pointers in trailer
--        ScanForTrailer - set if we should now scan for the trailer start.  For JPEG
--           images the ExifTool TrailerStart member will also be set, but for TIFF
--           images TrailerStart will only be set when writing, so the proc should
--           scan from the current file position when reading in a TIFF image.
-- Proc returns in read mode (OutFile not set):
--   1 = success
--   0 = error processing trailer (no warning will be issued and remaining trailers will be ignored)
--  -1 = must scan from TrailerStart since length can not be determined
--       (in which case this routine will be called again later when TrailerStart is known)
-- Proc returns in write mode:
--   1 = success (and proc updates OutFile with the trailer to write, or empty string to delete)
--   0 = error processing trailer (will issue minor error)
--  -1 = caller to copy or delete the trailer as-is (from TrailerStart if DataPos isn't set)
--   - TrailerStart will always be set in write mode
--   - the write routine will not be called if all trailers are being deleted
-- Proc sets the following elements of $dirInfo in both read and write mode:
--   DataPos - file position for start of this trailer
--   DirLen  - length of this trailer (subsequent trailers are not processed if this is not set)
--   Fixup   - for any pointers in the trailer that need adjusting
--
        local result = proc(self, dirInfo)

        -- restore PATH (pop last 2 items)
        path[#path] = nil
        path[#path] = nil

        local dataPos, dirLen = dirInfo.DataPos, dirInfo.DirLen
        if outfile then
            if result < 0 then
                -- copy or delete the trailer ourself
                result = 1
                if perlTruthy(self.TrailerStart) then
                    if not perlTruthy(dataPos) then dataPos = self.TrailerStart end
                    if not perlTruthy(dirLen) then dirLen = self.FileEnd - offset - dataPos end
                end
                if self.DEL_GROUP.Trailer or self.DEL_GROUP[dirName] then
                    local bytes = perlTruthy(dirLen) and ' (' .. dirLen .. ' bytes)' or ''
                    self:VPrint(0, 'Deleting ' .. dirName .. ' trailer' .. bytes .. "\n")
                    self.CHANGED = (self.CHANGED or 0) + 1
                elseif perlTruthy(dataPos) and perlTruthy(dirLen) then
                    self:VPrint(0, 'Copying ' .. dirName .. ' trailer (' .. dirLen .. " bytes)\n")
                    -- (Read into ${$$dirInfo{OutFile}}: the box takes the bytes read)
                    local n, buff
                    if raf:Seek(dataPos) then
                        n, buff = raf:Read(dirLen)
                        dirInfo.OutFile.value = carray.new('char'):append(buff)
                    end
                    if n ~= dirLen then result = 0 end
                else
                    result = 0
                end
            end
            if result > 0 then
                if outBuff and perlTruthy(outBuff.value) then
                    -- write trailers to OutFile in original order
                    outfile.value = carray.new('char'):append(outBuff.value, outfile.value)
                    -- must adjust old fixup start if it exists
                    if fixup then fixup.Start = fixup.Start + perl.length(outBuff.value) end
                    outBuff.value = carray.new('char')  -- free memory
                end
                if dirInfo.Fixup then
                    if fixup then
                        -- add fixup for subsequent trailers to the fixup for this trailer
                        -- (but first we must adjust for the new start position)
                        fixup.Shift = fixup.Shift + dirInfo.Fixup.Start
                        fixup.Start = fixup.Start - dirInfo.Fixup.Start
                        dirInfo.Fixup:AddFixup(fixup)
                    end
                    fixup = dirInfo.Fixup   -- save fixup
                end
            else
                if perlTruthy(self:Error('Error rewriting ' .. dirName .. ' trailer', 2)) then success = 0 end
                break
            end
        elseif result < 0 then
            -- can't continue if we must scan for this trailer
            success = 0
            break
        end
        if not (result > 0 and perlTruthy(dirLen)) then break end
        offset = offset + dirLen
        if perlTruthy(dataPos) and perlTruthy(self.TrailerStart) and dataPos <= self.TrailerStart then break end
        -- look for next trailer
        local nextTrail = self:IdentifyTrailer(raf, offset)
        -- process Google trailer after all others if necessary and not done already
        if not nextTrail then
            if not perlTruthy(self.ProcessGoogleTrailer) then break end
            nextTrail = { DirName = 'Google', RAF = raf }
        end
        dirName = nextTrail.DirName
        dirInfo.DirName = dirName
    end
    ExifTool.SetByteOrder(byteOrder)    -- restore original byte order
    raf:Seek(pos)                       -- restore original file position
    dirInfo.OutFile = outfile           -- restore original outfile
    dirInfo.Offset = offset             -- return offset from EOF to start of first trailer
    dirInfo.Fixup = fixup               -- return fixup information
    return success
end

--------------------------------------------------------------------------------
-- JPEG constants

-- JPEG marker names
-- (published like upstream's package hash %Image::ExifTool::jpegMarker,
--  because Jpeg2000.lua's ProcessJP2 mixes in its %j2cMarker names)
ExifTool.jpegMarker = {
    [0x00] = 'NULL',
    [0x01] = 'TEM',
    [0xc0] = 'SOF0', -- to SOF15, with a few exceptions below
    [0xc4] = 'DHT',
    [0xc8] = 'JPGA',
    [0xcc] = 'DAC',
    [0xd0] = 'RST0', -- to RST7
    [0xd8] = 'SOI',
    [0xd9] = 'EOI',
    [0xda] = 'SOS',
    [0xdb] = 'DQT',
    [0xdc] = 'DNL',
    [0xdd] = 'DRI',
    [0xde] = 'DHP',
    [0xdf] = 'EXP',
    [0xe0] = 'APP0', -- to APP15
    [0xf0] = 'JPG0',
    [0xfe] = 'COM',
}
local jpegMarker = ExifTool.jpegMarker

-- lookup for size of JPEG marker length word
-- (2 bytes assumed unless specified here)
local markerLenBytes = {
    [0x00] = 0,  [0x01] = 0,
    [0xd0] = 0,  [0xd1] = 0,  [0xd2] = 0,  [0xd3] = 0,  [0xd4] = 0,  [0xd5] = 0,  [0xd6] = 0,  [0xd7] = 0,
    [0xd8] = 0,  [0xd9] = 0,  [0xda] = 0,
    -- J2C
    [0x30] = 0,  [0x31] = 0,  [0x32] = 0,  [0x33] = 0,  [0x34] = 0,  [0x35] = 0,  [0x36] = 0,  [0x37] = 0,
    [0x38] = 0,  [0x39] = 0,  [0x3a] = 0,  [0x3b] = 0,  [0x3c] = 0,  [0x3d] = 0,  [0x3e] = 0,  [0x3f] = 0,
    [0x4f] = 0,
    [0x92] = 0,  [0x93] = 0,
    -- J2C extensions
    [0x74] = 4, [0x75] = 4, [0x77] = 4,
}

--------------------------------------------------------------------------------
-- Get JPEG marker name
-- Inputs: 0) Jpeg number
-- Returns: marker name
function ExifTool.JpegMarkerName(marker)
    local markerName = jpegMarker[marker]
    if not markerName then
        markerName = jpegMarker[marker & 0xf0]
        local prefix = markerName and markerName:match('^([A-Z]+)%d+$')
        if prefix then
            markerName = prefix .. (marker & 0x0f)
        else
            markerName = sprintf('marker 0x%.2x', marker)
        end
    end
    return markerName
end

--------------------------------------------------------------------------------
-- Adjust directory start position
-- Inputs: 0) dirInfo ref, 1) start offset
--         2) Base for offsets (relative to DataPos, defaults to absolute Base of 0)
function ExifTool.DirStart(dirInfo, start, base)
    dirInfo.DirStart = start
    dirInfo.DirLen = dirInfo.DirLen - start
    if base ~= nil then
        dirInfo.Base = dirInfo.DataPos + base
        dirInfo.DataPos = -base    -- (relative to Base!)
    end
end
local DirStart = ExifTool.DirStart

-- Highest index of a Perl array that is kept here as a Lua table with 0-based
-- keys and holes (Perl's `$#array`, -1 when empty) -- the chunk lists below
-- are such arrays, filled by chunk number
local function lastIndex(array)
    local last = -1
    for i in pairs(array) do
        if type(i) == 'number' and i > last then last = i end
    end
    return last
end

--------------------------------------------------------------------------------
-- Extract metadata from a jpg image
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref with RAF set
--         2) tag table ref to process JPEG-like metadata
-- Returns: 1 on success, 0 if this wasn't a valid JPEG file
-- (Perl keeps the parameter $dirInfo and the per-segment hash %dirInfo apart
--  by sigil; here both are `dirInfo`, the hash shadowing the parameter after
--  its last use, so the shadowing warning is silenced for this function)
-- luacheck: push ignore 42
function ExifTool:ProcessJPEG(dirInfo, optionalTagTable)
    local options = self.OPTIONS
    local verbose = options.Verbose or 0
    local out = options.TextOut or io.stdout
    local fast = options.FastScan or 0
    local raf = dirInfo.RAF
    local req = self.REQ_TAG_LOOKUP or {}
    local htmlDump = self.HTML_DUMP
    local dumpParms = { Out = out, Prefix = self.INDENT }
    local ch, s, length, hash, hashsize, indent
    local success, wantTrailer, trailInfo, foundSOS, gotSize, jumbfChunk = nil, nil, nil, nil, nil, {}
    local iccChunk, iccChunkCount, iccChunksTotal, flirChunk, flirCount, flirTotal = {}, nil, nil, {}, nil, nil
    local preview, scalado, dqt, subSampling, dumpEnd, extendedXMP = nil, nil, {}, nil, nil, {}

    indent = (self.INDENT:gsub('  $', ''))
    if not raf then
        raf = RandomAccess.new(dirInfo.DataPt)
        self:VerboseDir('JPEG', nil, #dirInfo.DataPt)
    end
    -- get pointer to hash object if it exists and we are the top-level JPEG or JP2
    -- (rawget: ExifTool.ImageDataHash is also the name of the method)
    if perl.matches(self.FILE_TYPE, [[^(JPEG|JP2)$]]) and not perlTruthy(self.DOC_NUM) then
        hash = rawget(self, 'ImageDataHash')
        hashsize = 0
    end
    -- check to be sure this is a valid JPG (or J2C, or EXV) file
    local n
    n, s = raf:Read(2)
    if n == 2 and perl.matches(s, [=[^\xff[\xd8\x4f\x01]]=]) then
        optionalTagTable = nil
    else
        if not (optionalTagTable and perl.matches(s, [=[^\xff[\xe0-\xef]]=])) then return 0 end
        if not raf:Seek(-2, 1) then self:Error('Seek error') return 1 end
    end
    if s == '\255\1' then
        n, s = raf:Read(5)
        if not (n == 5 and s == 'Exiv2') then return 0 end
        self.FILE_TYPE = 'EXV'
    end
    local appBytes = 0
    local calcImageLen = req.jpegimagelength
    if options.RequestAll and perl.num(options.RequestAll) > 2 then
        calcImageLen = 1
    end
    if not self.VALUE.FileType or (perlTruthy(self.DOC_NUM) and perlTruthy(options.ExtractEmbedded)) then
        self:SetFileType()                  -- set FileType tag
        if fast > 2 then return 1 end       -- don't process file when FastScan > 2
        self.LOW_PRIORITY_DIR.IFD1 = 1      -- lower priority of IFD1 tags
    end
    if perlTruthy(self:Options('FastScan')) then raf.NoBuffer = 1 end -- disable buffering in FastScan mode

    if verbose < 4 then dumpParms.MaxLen = 128 end
    if htmlDump and not optionalTagTable then
        dumpEnd = raf:Tell()
        local t, m
        if s == 'Exiv2' then n, t, m = 7, 'EXV', 'TEM' else n, t, m = 2, 'JPEG', 'SOI' end
        local pos = dumpEnd - n
        if pos ~= 0 then self:HDump(0, pos, '[unknown header]') end
        self:HDump(pos, n, t .. ' header', m .. ' Marker')
    end
    local path = self.PATH
    local pn = #path

    -- (upstream sets the input record separator $/ to 0xff (the JPEG marker)
    --  to make reading quicker; here it is passed to each ReadLine call)

    local nextMarker, nextSegDataPt, nextSegPos, combinedSegData, firstSegPos, skipData
    skipData = {}

    -- read file until we reach an end of image (EOI) or start of scan (SOS)
    while true do
        -- set marker and data pointer for current segment
        local marker = nextMarker
        if marker and marker < 0 then break end
        local segDataPt = nextSegDataPt
        local segPos = nextSegPos
        local skipped
        nextMarker = nil
        nextSegDataPt = nil
--
-- read ahead to the next segment unless we have reached EOI, SOS or SOD
--
        if not (marker and (marker == 0xd9 or (marker == 0xda and not wantTrailer and not hash) or
            marker == 0x93))
        then
            -- (upstream's `until` loop always leaves its body via last/next,
            --  so it runs at most once)
            repeat
                -- read up to next marker (JPEG markers begin with 0xff)
                local buff
                n, buff = raf:ReadLine('\255')
                if n == 0 then
                    if not optionalTagTable then goto lastMarker end
                    nextMarker = -1
                    success = 1
                    break
                end
                skipped = #buff - 1
                -- JPEG markers can be padded with unlimited 0xff's
                while true do
                    n, ch = raf:Read(1)
                    if n == 0 then goto lastMarker end
                    nextMarker = perl.ord(ch)
                    if nextMarker ~= 0xff then break end
                    skipped = skipped + 1
                end
                -- read segment data if it exists
                if markerLenBytes[nextMarker] == nil then
                    -- read record length word
                    n, s = raf:Read(2)
                    if n ~= 2 then goto lastMarker end
                    local len = unpack_('n', s)     -- get data length
                    if not (len ~= nil and len >= 2) then goto lastMarker end
                    nextSegPos = raf:Tell()
                    len = len - 2   -- subtract size of length word
                    n, buff = raf:Read(len)
                    if n ~= len then goto lastMarker end
                    nextSegDataPt = buff    -- set pointer to our next data
                elseif markerLenBytes[nextMarker] == 4 then
                    -- handle J2C extensions with 4-byte length word
                    n, s = raf:Read(4)
                    if n ~= 4 then goto lastMarker end
                    local len = unpack_('N', s)     -- get data length
                    if not (len ~= nil and len >= 4) then goto lastMarker end
                    nextSegPos = raf:Tell()
                    len = len - 4   -- subtract size of length word
                    if not raf:Seek(len, 1) then goto lastMarker end
                elseif hash and marker ~= nil and (marker == 0x00 or marker == 0xda or
                    (marker >= 0xd0 and marker <= 0xd7))
                then
                    -- calculate hash for image data (includes leading ff d9 but not trailing ff da)
                    hash:add('\255' .. perl.chr(marker))
                    local nx = skipped - (#buff - 1)    -- number of extra 0xff's
                    if nx == 0 then
                        buff = substr(buff, 0, -1)      -- remove trailing 0xff
                    elseif nx > 1 then
                        buff = buff .. string.rep('\255', nx - 1)   -- add back extra 0xff's
                    end
                    hash:add(buff)
                    hashsize = hashsize + skipped + 2
                end
                -- read second segment too if this was the first
                if marker == nil then goto nextMarker end
            until true
        end
        do
            -- set some useful variables for the current segment
            local markerName = ExifTool.JpegMarkerName(marker)
            path[pn + 1] = markerName
            -- issue warning if we skipped some garbage
            if perlTruthy(skipped) and not foundSOS and markerName ~= 'SOS' then
                self:Warn('Skipped unknown ' .. skipped .. ' bytes after JPEG ' .. markerName .. ' segment', 1)
                if htmlDump then
                    self:HDump((nextSegPos or 0) - 4 - skipped, skipped, '[unknown ' .. skipped .. ' bytes]', nil, 0x08)
                    dumpEnd = (nextSegPos or 0) - 4
                end
            end
--
-- parse the current segment
--
            -- handle SOF markers: SOF0-SOF15, except DHT(0xc4), JPGA(0xc8) and DAC(0xcc)
            if (marker & 0xf0) == 0xc0 and (marker == 0xc0 or marker & 0x03 ~= 0) then
                length = #segDataPt
                if verbose ~= 0 then
                    out:write(indent .. 'JPEG ' .. markerName .. ' (' .. length .. ' bytes):\n')
                    if verbose > 2 then
                        local opts = { Addr = segPos }
                        for k, v in pairs(dumpParms) do opts[k] = v end
                        ExifTool.HexDump(segDataPt, nil, opts)
                    end
                elseif htmlDump then
                    self:HDump(segPos - 4, length + 4, '[JPEG ' .. markerName .. ']', nil, 0x08)
                    dumpEnd = segPos + length
                end
                if length < 6 or gotSize then goto nextMarker end
                gotSize = 1 -- (ignore subsequent SOF segments in probably corrupted JPEG)
                -- extract some useful information
                local p, h, w, nc = unpack_('Cn2C', segDataPt)
                local sof = self:GetTagTable('lexiftool.JPEG.SOF')
                self:HandleTag(sof, 'ImageWidth', w)
                self:HandleTag(sof, 'ImageHeight', h)
                self:HandleTag(sof, 'EncodingProcess', marker - 0xc0)
                self:HandleTag(sof, 'BitsPerSample', p)
                self:HandleTag(sof, 'ColorComponents', nc)
                if not (nc == 3 and length >= 15) then goto nextMarker end
                local hmin, hmax, vmin, vmax
                -- loop through all components to determine sampling frequency
                subSampling = ''
                for i = 0, nc - 1 do
                    local sf = ExifTool.Get8u(segDataPt, 7 + 3 * i)
                    subSampling = subSampling .. sprintf('%.2x', sf)
                    -- isolate horizontal and vertical components
                    local hf, vf = sf >> 4, sf & 0x0f
                    if i == 0 then
                        hmin, hmax = hf, hf
                        vmin, vmax = vf, vf
                    else
                        -- determine min/max frequencies
                        if hf < hmin then hmin = hf end
                        if hf > hmax then hmax = hf end
                        if vf < vmin then vmin = vf end
                        if vf > vmax then vmax = vf end
                    end
                end
                if hmin ~= 0 and vmin ~= 0 then
                    local hs, vs = hmax / hmin, vmax / vmin
                    self:HandleTag(sof, 'YCbCrSubSampling', ExifTool.NumStr(hs) .. ' ' .. ExifTool.NumStr(vs))
                end
                goto nextMarker
            elseif marker == 0xd9 then          -- EOI
                path[#path] = nil
                if verbose ~= 0 then out:write(indent .. 'JPEG EOI\n') end
                local pos = raf:Tell()
                if not perlTruthy(self.DOC_NUM) then self.TrailerStart = pos end
                if htmlDump and perlTruthy(dumpEnd) then
                    self:HDump(dumpEnd, pos - 2 - dumpEnd, '[JPEG Image Data]', nil, 0x08)
                    self:HDump(pos - 2, 2, 'JPEG EOI', nil)
                    dumpEnd = 0 -- luacheck: ignore 311 (dead here as upstream: EOI ends the loop)
                end
                if foundSOS or self.FILE_TYPE == 'EXV' then
                    success = 1
                else
                    self:Warn('Missing JPEG SOS')
                end
                if req.trailer then
                    -- read entire trailer into memory
                    if raf:Seek(0, 2) then
                        local len = raf:Tell() - pos
                        if len ~= 0 then
                            local buff
                            raf:Seek(pos, 0)
                            n, buff = raf:Read(len)
                            if n == len then self:FoundTag('Trailer', { ref = 'SCALAR', value = buff }) end
                            raf:Seek(pos, 0)
                        end
                    else
                        self:Warn('Error seeking in file')
                    end
                end
                -- we are here because we are looking for trailer information
                if wantTrailer then
                    local start = self.PreviewImageStart
                    if perlTruthy(start) or perlTruthy(options.ExtractEmbedded) then
                        local buff
                        -- most previews start right after the JPEG EOI, but the Olympus E-20
                        -- preview is 508 bytes into the trailer, the K-M Maxxum 7D preview is
                        -- 979 bytes in, and Sony previews can start up to 32 kB into the trailer.
                        -- (and Minolta and Sony previews can have a random first byte...)
                        local scanLen = perl.matches(self.Make, [[(?i)Sony]]) and 65536 or 1024
                        n, buff = raf:Read(scanLen)
                        if n ~= 0 then
                            local found, en
                            if perl.matches(buff, [[(?s)^.{4}ftyp]]) then
                                local val
                                if raf:Seek(0, 2) then
                                    local len = raf:Tell() - pos
                                    if perlTruthy(options.Binary) then
                                        if raf:Seek(pos, 0) then
                                            n, buff = raf:Read(len)
                                            if n == len then val = { ref = 'SCALAR', value = buff } end
                                        end
                                    else
                                        val = { ref = 'SCALAR', value = 'Binary data ' .. len .. ' bytes' }
                                    end
                                    if val then
                                        self:FoundTag('EmbeddedVideo', val)
                                    else
                                        self:Warn('Error reading trailer')
                                    end
                                else
                                    self:Warn('Error seeking to end of file')
                                end
                            else
                                found, en = perl.matches(buff, [[\xff\xd8\xff.]])
                                if not found and perl.matches(self.Make, [[(?i)(Minolta|Sony)]]) then
                                    found, en = perl.matches(buff, [[.\xd8\xff\xdb]])
                                end
                            end
                            if found then
                                -- adjust PreviewImageStart to this location
                                local actual = pos + en - 4
                                if perlTruthy(start) and start ~= actual and verbose > 1 then
                                    out:write(indent .. '(Fixed PreviewImage location: ' .. start .. ' -> ' .. actual .. ')\n')
                                end
                                -- update preview image offsets
                                if perlTruthy(start) then
                                    if perlTruthy(self.VALUE.PreviewImageStart) then self.VALUE.PreviewImageStart = actual end
                                    self.PreviewImageStart = actual
                                end
                                -- load preview now if we tried and failed earlier
                                if self.PreviewError and perlTruthy(self.PreviewImageLength) then
                                    if raf:Seek(actual, 0) then
                                        n, buff = raf:Read(self.PreviewImageLength)
                                        if n ~= 0 then
                                            self:FoundTag('PreviewImage', buff)
                                            self.PreviewError = nil
                                        end
                                    end
                                end
                            end
                        end
                        raf:Seek(pos, 0)
                    end
                end
                -- process trailer now or finish processing trailers
                -- and scan for AFCP if necessary
                local fromEnd = 0
                if trailInfo then
                    trailInfo.ScanForTrailer = 1   -- scan now if necessary
                    self:ProcessTrailers(trailInfo)
                    -- save offset from end of file to start of first trailer
                    fromEnd = trailInfo.Offset
                    trailInfo = nil -- luacheck: ignore 311 (dead here as upstream: EOI ends the loop)
                end
                if self.LeicaTrailer then
                    raf:Seek(0, 2)
                    self.LeicaTrailer.TrailPos = pos
                    self.LeicaTrailer.TrailLen = raf:Tell() - pos - fromEnd
                    loadModule('Panasonic').ProcessLeicaTrailer(self)
                end
                -- finally, dump remaining information in JPEG trailer
                if verbose ~= 0 or htmlDump then
                    local endPos = self.LeicaTrailerPos
                    if not perlTruthy(endPos) then
                        raf:Seek(0, 2)
                        endPos = raf:Tell() - fromEnd
                    end
                    if endPos > pos then
                        self:DumpUnknownTrailer({
                            RAF = raf,
                            DataPos = pos,
                            DirLen = endPos - pos
                        })
                    end
                end
                if calcImageLen then self:FoundTag('JPEGImageLength', pos - appBytes) end
                break       -- all done parsing file
            elseif marker == 0xda then          -- SOS
                path[#path] = nil
                foundSOS = 1
                -- all done with meta information unless we have a trailer
                if verbose ~= 0 then out:write(indent .. 'JPEG SOS\n') end
                -- process extended XMP now if it existed
                -- (must do this before trailers because XMP is required to process Google trailer)
                if next(extendedXMP) then
                    -- GUID indicated by the last main XMP segment
                    local goodGuid = self.VALUE.HasExtendedXMP or ''
                    -- GUID of the extended XMP that we will process ('2' for all)
                    local readGuid = options.ExtendedXMP or 0
                    if perl.str(readGuid) == '1' then readGuid = goodGuid end
                    local guids = {}
                    for guid in pairs(extendedXMP) do guids[#guids + 1] = guid end
                    tsort(guids)
                    for _, guid in ipairs(guids) do
                        if #guid ~= 32 then goto nextGuid end  -- ignore other (internal) keys
                        do
                            local extXMP = extendedXMP[guid]
                            local off, offsets, warn = 0, {}, nil
                            -- make sure we have all chunks, and create a list of sorted offsets
                            while off < extXMP.Size do
                                if extXMP[off] == nil then break end
                                offsets[#offsets + 1] = off
                                off = off + #extXMP[off]
                            end
                            if off ~= extXMP.Size then
                                self:Warn('Incomplete extended XMP (GUID ' .. guid .. ')')
                                goto nextGuid
                            end
                            if guid == readGuid or perl.str(readGuid) == '2' then
                                if guid ~= goodGuid then warn = 'Reading non-' end
                                local buff = {}
                                -- assemble XMP all together
                                for _, o in ipairs(offsets) do buff[#buff + 1] = extXMP[o] end
                                local tagTablePtr = self:GetTagTable('lexiftool.XMP.Main')
                                local dirInfo = {
                                    DataPt      = table.concat(buff),
                                    Parent      = 'APP1',
                                    IsExtended  = 1,
                                }
                                path[pn + 1] = 'APP1'
                                self:ProcessDirectory(dirInfo, tagTablePtr)
                                path[#path] = nil
                            else
                                warn = 'Ignored '
                                if guid ~= goodGuid then warn = warn .. 'non-' end
                            end
                            if warn then self:Warn(warn .. 'standard extended XMP (GUID ' .. guid .. ')') end
                            extendedXMP[guid] = nil
                        end
                        ::nextGuid::
                    end
                end
                if not perlTruthy(fast) then
                    trailInfo = self:IdentifyTrailer(raf)
                    -- process trailer now unless we are doing verbose dump
                    if trailInfo and verbose < 3 and not htmlDump then
                        -- process trailers (keep trailInfo to finish processing later
                        -- only if we can't finish without scanning from JPEG EOF)
                        if perlTruthy(self:ProcessTrailers(trailInfo)) then trailInfo = nil end
                    end
                    if wantTrailer and perlTruthy(self.PreviewImageStart) then
                        -- seek ahead and validate preview image
                        local buff
                        local curPos = raf:Tell()
                        if raf:Seek(self.PreviewImageStart, 0) then
                            n, buff = raf:Read(4)
                            if n == 4 and perl.matches(buff, [=[(?s)^.\xd8\xff[\xc4\xdb\xe0-\xef]]=]) then
                                wantTrailer = nil
                            end
                        end
                        if not raf:Seek(curPos, 0) then break end
                    end
                    -- seek ahead and process Leica trailer
                    if self.LeicaTrailer then
                        loadModule('Panasonic').ProcessLeicaTrailer(self)
                        if self.LeicaTrailer then wantTrailer = 1 end
                    elseif perlTruthy(options.ExtractEmbedded) or (perlTruthy(self.VALUE.HiddenDataOffset) and
                        perlTruthy(self.VALUE.HiddenDataLength) and (perlTruthy(options.Validate) or req.hiddendata))
                    then
                        wantTrailer = 1
                    end
                    if trailInfo or wantTrailer or verbose > 2 or htmlDump then goto nextMarker end
                end
                -- must scan to EOI if Validate or JpegCompressionFactor used
                if perlTruthy(options.Validate) or calcImageLen or req.trailer or hash then goto nextMarker end
                -- nothing interesting to parse after start of scan (SOS)
                success = 1
                break   -- all done parsing file
            elseif marker == 0x93 then
                path[#path] = nil
                if verbose ~= 0 then out:write(indent .. 'JPEG SOD\n') end
                success = 1
                if hash and self.FILE_TYPE == 'JP2' then
                    local pos = raf:Tell()
                    self:ImageDataHash(raf, nil, 'SOD')
                    raf:Seek(pos, 0)
                end
                if verbose > 2 or htmlDump then goto nextMarker end
                break   -- all done parsing file
            elseif markerLenBytes[marker] ~= nil then
                -- handle other stand-alone markers and segments we skipped over
                if verbose ~= 0 and marker ~= 0 then
                    if verbose < 4 and (marker & 0xf8) == 0xd0 then goto nextMarker end
                    out:write(indent .. 'JPEG ' .. markerName .. '\n')
                end
                goto nextMarker
            elseif marker == 0xdb and #segDataPt ~= 0 and   -- DQT
                -- save the DQT data only if JPEGDigest has been requested
                -- (Note: since we aren't checking the API RequestAll option here, the application
                --  must use the RequestTags option to generate these tags if they have not been
                --  specifically requested.  The reason is that there is too much overhead involved
                --  in the calculation of this tag to make this worth the CPU time.)
                (req.jpegdigest or req.jpegqualityestimate
                or (options.RequestAll and perl.num(options.RequestAll) > 2))
            then
                local num = unpack_('C', segDataPt) & 0x0f   -- get table index
                if num < 4 then dqt[num] = segDataPt end     -- save for hash calculation
            end
            -- handle all other markers
            local dumpType = ''
            local desc, tip, xtra, useJpegMain
            length = #segDataPt
            if (marker & 0xf0) == 0xe0 then appBytes = appBytes + length + 4 end  -- total size of APP segments
            if verbose ~= 0 then
                out:write(indent .. 'JPEG ' .. markerName .. ' (' .. length .. ' bytes):\n')
                if verbose > 2 then
                    local extraParms = { Addr = segPos }
                    if verbose == 4 then extraParms.MaxLen = 128 end
                    local opts = {}
                    for k, v in pairs(dumpParms) do opts[k] = v end
                    for k, v in pairs(extraParms) do opts[k] = v end
                    ExifTool.HexDump(segDataPt, nil, opts)
                end
            end
            -- prepare dirInfo hash for processing this information
            local dirInfo = {
                Parent   = markerName,
                DataPt   = segDataPt,
                DataPos  = segPos,
                DataLen  = length,
                DirStart = 0,
                DirLen   = length,
                Base     = 0,
            }
            if marker == 0xe0 then              -- APP0 (JFIF, JFXX, CIFF, AVI1, Ocad)
                -- (Perl's $1 of the elsif chain: each match is kept here)
                local c1 = perl.matches(segDataPt, [[^JFXX\0(\x10|\x11|\x13)]])
                local c2 = perl.matches(segDataPt, [[^(AVI1|Ocad)]])
                if perl.matches(segDataPt, [[^JFIF\0]]) then
                    dumpType = 'JFIF'
                    DirStart(dirInfo, 5) -- start at byte 5
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = self:GetTagTable('lexiftool.JFIF.Main')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif c1 then
                    local tag = perl.ord(c1)
                    dumpType = 'JFXX'
                    local tagTablePtr = self:GetTagTable('lexiftool.JFIF.Extension')
                    local tagInfo = self:GetTagInfo(tagTablePtr, tag)
                    self:FoundTag(tagInfo, substr(segDataPt, 6))
                elseif perl.matches(segDataPt, [[(?s)^(II|MM).{4}HEAPJPGM]]) then
                    if fast > 1 then goto nextMarker end    -- skip processing for very fast
                    dumpType = 'CIFF'
                    local dirInfo = { RAF = RandomAccess.new(segDataPt) }
                    self.SET_GROUP1 = 'CIFF'
                    self.PATH[#self.PATH + 1] = 'CIFF'
                    loadModule('CanonRaw').ProcessCRW(self, dirInfo)
                    self.PATH[#self.PATH] = nil
                    self.SET_GROUP1 = nil
                elseif c2 then
                    dumpType = c2
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.' .. dumpType)
                    DirStart(dirInfo, 4)
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                end
            elseif marker == 0xe1 then          -- APP1 (EXIF, XMP, QVCI, PARROT)
                -- (some Kodak cameras don't put a second "\0", and I have seen an
                --  example where there was a second 4-byte APP1 segment header)
                local c1 = perl.matches(segDataPt, [[(?is)^(.{0,4})Exif\0.]])
                if c1 then
                    -- luacheck: ignore 311 (dumpType: dead here as upstream, the branch ends with `next`)
                    dumpType = nil      -- (will be dumped here)
                    -- this is EXIF data --
                    -- get the data block (into a common variable)
                    local hdrLen = #exifAPP1hdr
                    if #c1 ~= 0 then
                        hdrLen = hdrLen + #c1
                        self:Warn('Unknown garbage at start of EXIF segment', 1)
                    elseif not perl.matches(segDataPt, [[^Exif\0]]) then
                        self:Warn('Incorrect EXIF segment identifier', 1)
                    end
                    if htmlDump then
                        self:HDump(segPos - 4, 4, 'APP1 header', 'Data size: ' .. length .. ' bytes')
                        self:HDump(segPos, hdrLen, 'Exif header', 'APP1 data type: Exif')
                        dumpEnd = segPos + length
                    end
                    local dataPt = segDataPt
                    if combinedSegData ~= nil then
                        skipData[#skipData + 1] = { segPos - 4, segPos + hdrLen }
                        combinedSegData = combinedSegData .. substr(segDataPt, hdrLen)
                        dataPt = combinedSegData
                        segPos = firstSegPos
                    end
                    -- peek ahead to see if the next segment is extended EXIF
                    if nextMarker == marker and
                        perl.isMatchDyn(nextSegDataPt, '^' .. exifAPP1hdr .. [[(?!(MM\0\x2a|II\x2a\0))]])
                    then
                        -- initialize combined data if necessary
                        if combinedSegData == nil then
                            combinedSegData = segDataPt
                            firstSegPos = segPos
                            self:Warn('File contains multi-segment EXIF', 1)
                            self.ExtendedEXIF = 1
                        end
                        goto nextMarker
                    end
                    dirInfo.DataPt = dataPt
                    dirInfo.DataPos = segPos
                    dirInfo.DataLen = #dataPt
                    dirInfo.DirLen = #dataPt
                    DirStart(dirInfo, hdrLen, hdrLen)
                    if #skipData > 0 then self.SkipData = skipData end
                    -- extract the EXIF information (it is in standard TIFF format)
                    if not perlTruthy(self:ProcessTIFF(dirInfo)) then self:Warn('Malformed APP1 EXIF segment') end
                    -- scan for Vivo HiddenData if necessary
                    if self.Make == 'vivo' and
                        -- (stored as UserComment by some models)
                        not (self.VALUE.UserComment and perl.matches(self.VALUE.UserComment, [[^filter:]]))
                    then
                        local hidden, en = perl.matches(dataPt, [[(?s)(filter: .*?; \n)\0]])
                        if hidden then
                            if htmlDump then
                                local nh = #hidden + 1
                                self:HDump(segPos + en - nh, nh, '[Vivo HiddenData]', nil, 0x08)
                            end
                            local tbl = self:GetTagTable('lexiftool.Trailer.Vivo')
                            self:HandleTag(tbl, 'HiddenData', hidden)
                        end
                    end
                    -- avoid looking for preview unless necessary because it really slows
                    -- us down -- only look for it if we found pointer, and preview is
                    -- outside EXIF, and PreviewImage is specifically requested
                    local start = self:GetValue('PreviewImageStart', 'ValueConv')
                    local plen = self:GetValue('PreviewImageLength', 'ValueConv')
                    if not perlTruthy(start) or (not perlTruthy(plen) and self.PreviewError) then
                        start = self.PreviewImageStart
                        plen = self.PreviewImageLength
                    end
                    if perlTruthy(start) and perlTruthy(plen) and ExifTool.IsInt(start) and ExifTool.IsInt(plen) and
                        start + plen > (self.EXIF_POS or 0) + #(self.EXIF_DATA or '') and
                        (req.previewimage or
                        -- (extracted normally, so check Binary option)
                        (perlTruthy(options.Binary) and not (self.EXCL_TAG_LOOKUP and self.EXCL_TAG_LOOKUP.previewimage)))
                    then
                        self.PreviewImageStart = start
                        self.PreviewImageLength = plen
                        wantTrailer = 1
                    end
                    if #skipData > 0 then
                        skipData = {}
                        self.SkipData = nil
                    end
                    -- (upstream: `undef $$dataPt` -- when the data was combined,
                    --  this is what resets $combinedSegData)
                    combinedSegData = nil
                    goto nextMarker
                elseif perl.isMatchDyn(segDataPt, '^' .. xmpExtAPP1hdr) then
                    -- off len -- extended XMP header (75 bytes total):
                    --   0  35 bytes - signature
                    --  35  32 bytes - GUID (MD5 hash of full extended XMP data in ASCII)
                    --  67   4 bytes - total size of extended XMP data
                    --  71   4 bytes - offset for this XMP data portion
                    dumpType = 'Extended XMP'
                    if length > 75 then
                        local size, off = unpack_('x67N2', segDataPt)
                        local guid = substr(segDataPt, 35, 32)
                        if perl.matches(guid, [=[[^A-Za-z0-9]]=]) then -- (technically, should be uppercase)
                            tip = 'Invalid extended XMP GUID'
                            self:Warn(tip)
                        else
                            local extXMP = extendedXMP[guid]
                            if not extXMP then
                                extXMP = { }
                                extendedXMP[guid] = extXMP
                            elseif size ~= extXMP.Size then
                                self:Warn('Inconsistent extended XMP size')
                            end
                            extXMP.Size = size
                            extXMP[off] = substr(segDataPt, 75)
                            tip = 'Full length: ' .. size .. '\nChunk offset: ' .. off .. '\nChunk length: ' ..
                                (length - 75) .. '\nGUID: ' .. guid
                            -- (delay processing extended XMP until after reading all segments)
                        end
                    else
                        tip = 'Invalid extended XMP segment'
                        self:Warn(tip)
                    end
                elseif perl.matches(segDataPt, [[^QVCI\0]]) then
                    dumpType = 'QVCI'
                    local tagTablePtr = self:GetTagTable('lexiftool.Casio.QVCI')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^FLIR\0]]) and length >= 8 then
                    dumpType = 'FLIR'
                    -- must concatenate FLIR chunks (note: handle the case where
                    -- some software erroneously writes zeros for the chunk counts)
                    local chunkNum = ExifTool.Get8u(segDataPt, 6)
                    local chunksTot = ExifTool.Get8u(segDataPt, 7) + 1 -- (note the "+ 1"!)
                    if verbose ~= 0 then
                        out:write(sprintf(indent .. 'FLIR chunk %d of %d\n', chunkNum + 1, chunksTot))
                    end
                    if flirTotal ~= nil then
                        -- abort parsing FLIR if the total chunk count is inconsistent
                        if chunksTot ~= flirTotal then flirCount = nil end
                    else
                        flirCount = 0
                        flirTotal = chunksTot
                    end
                    if flirCount ~= nil then
                        if flirChunk[chunkNum] ~= nil then
                            self:Warn('Duplicate FLIR chunk number(s)')
                            flirChunk[chunkNum] = flirChunk[chunkNum] .. substr(segDataPt, 8)
                        else
                            flirChunk[chunkNum] = substr(segDataPt, 8)
                        end
                        -- process the FLIR information if we have all of the chunks
                        flirCount = flirCount + 1
                        if flirCount >= flirTotal then
                            local flir = ''
                            for i = 0, lastIndex(flirChunk) do
                                if flirChunk[i] ~= nil then flir = flir .. flirChunk[i] end
                            end
                            flirChunk = {}  -- free memory
                            local tagTablePtr = self:GetTagTable('lexiftool.FLIR.FFF')
                            local dirInfo = {
                                DataPt   = flir,
                                Parent   = markerName,
                                DirName  = 'FLIR',
                            }
                            self:ProcessDirectory(dirInfo, tagTablePtr)
                            flirCount = nil   -- prevent reprocessing
                        end
                    else
                        self:Warn('Invalid or extraneous FLIR chunk(s)')
                    end
                elseif perl.matches(segDataPt, [[^PARROT\0(II\x2a\0|MM\0\x2a)]]) then
                    -- (don't know if this could span multiple segments)
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.Main')
                    self:HandleTag(tagTablePtr, 'APP1', segDataPt)
                    dumpType = 'Parrot'
                else
                    -- Hmmm.  Could be XMP, let's see
                    local processed
                    if perl.matches(segDataPt, [[^(http|XMP\0)]]) or perl.matches(segDataPt, [[<(exif:|\?xpacket)]]) then
                        dumpType = 'XMP'
                        -- also try to parse XMP with a non-standard header
                        -- (note: this non-standard XMP is ignored when writing)
                        local start = perl.matchesDyn(segDataPt, '^' .. xmpAPP1hdr) and #xmpAPP1hdr or 0
                        local tagTablePtr = self:GetTagTable('lexiftool.XMP.Main')
                        DirStart(dirInfo, start)
                        dirInfo.DirName = start ~= 0 and 'XMP' or 'XML'
                        processed = perlTruthy(self:ProcessDirectory(dirInfo, tagTablePtr))
                        if processed and start == 0 then
                            self:Warn('Non-standard header for APP1 XMP segment')
                        end
                    end
                    if verbose ~= 0 and not processed then
                        self:Warn('Ignored APP1 segment length ' .. length .. ' (unknown header)')
                    end
                end
            elseif marker == 0xe2 then          -- APP2 (ICC Profile, FPXR, MPF, InfiRay, URN, PreviewImage)
                local c1
                if perl.matches(segDataPt, [[^ICC_PROFILE\0]]) and length >= 14 then
                    dumpType = 'ICC_Profile'
                    -- must concatenate profile chunks (note: handle the case where
                    -- some software erroneously writes zeros for the chunk counts)
                    local chunkNum = ExifTool.Get8u(segDataPt, 12)
                    local chunksTot = ExifTool.Get8u(segDataPt, 13)
                    if verbose ~= 0 then
                        out:write(indent .. 'ICC_Profile chunk ' .. chunkNum .. ' of ' .. chunksTot .. '\n')
                    end
                    if iccChunksTotal ~= nil then
                        -- abort parsing ICC_Profile if the total chunk count is inconsistent
                        if chunksTot ~= iccChunksTotal then iccChunkCount = nil end
                    else
                        iccChunkCount = 0
                        iccChunksTotal = chunksTot
                        if chunksTot == 0 then self:Warn('ICC_Profile chunk count is zero') end
                    end
                    if iccChunkCount ~= nil then
                        if iccChunk[chunkNum] ~= nil then
                            self:Warn('Duplicate ICC_Profile chunk number(s)')
                            iccChunk[chunkNum] = iccChunk[chunkNum] .. substr(segDataPt, 14)
                        else
                            iccChunk[chunkNum] = substr(segDataPt, 14)
                        end
                        -- process profile if we have all of the chunks
                        iccChunkCount = iccChunkCount + 1
                        if iccChunkCount >= iccChunksTotal then
                            local icc_profile = ''
                            for i = 0, lastIndex(iccChunk) do
                                if iccChunk[i] ~= nil then icc_profile = icc_profile .. iccChunk[i] end
                            end
                            iccChunk = {}  -- free memory
                            local tagTablePtr = self:GetTagTable('lexiftool.ICC_Profile.Main')
                            local dirInfo = {
                                DataPt   = icc_profile,
                                DataPos  = segPos + 14,
                                DataLen  = #icc_profile,
                                DirStart = 0,
                                DirLen   = #icc_profile,
                                Parent   = markerName,
                            }
                            self:ProcessDirectory(dirInfo, tagTablePtr)
                            iccChunkCount = nil     -- prevent reprocessing
                        end
                    else
                        self:Warn('Invalid or extraneous ICC_Profile chunk(s)')
                    end
                elseif perl.matches(segDataPt, [[^FPXR\0]]) then
                    if fast > 1 then goto nextMarker end    -- skip processing for very fast
                    dumpType = 'FPXR'
                    local tagTablePtr = self:GetTagTable('lexiftool.FlashPix.Main')
                    -- set flag if this is the last FPXR segment
                    dirInfo.LastFPXR = not (nextMarker == marker and perl.matches(nextSegDataPt, [[^FPXR\0]]))
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^MPF\0]]) then
                    dumpType = nil      -- (will be dumped here)
                    DirStart(dirInfo, 4, 4)
                    dirInfo.Multi = 1   -- the MP Attribute IFD will be MPF1
                    if htmlDump then
                        self:HDump(segPos - 4, 4, 'APP2 header', 'Data size: ' .. length .. ' bytes')
                        self:HDump(segPos, 4, 'MPF header', 'APP2 data type: MPF')
                        dumpEnd = segPos + length
                    end
                    -- extract the MPF information (it is in standard TIFF format)
                    local tagTablePtr = self:GetTagTable('lexiftool.MPF.Main')
                    self:ProcessTIFF(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[(?s)^....IJPEG\0]]) then
                    dumpType = 'InfiRay Version'
                    self.HasIJPEG = 1
                    ExifTool.SetByteOrder('II')
                    local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.Version')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                else
                    c1 = perl.matches(segDataPt, [=[^(|QVGA\0|BGTH)\xff\xd8\xff[\xdb\xe0\xe1]]=])
                    if c1 then
                        -- Samsung/GE/GoPro="", BenQ DC C1220/Pentacon/Polaroid="QVGA\0",
                        -- Digilife DDC-690/Rollei="BGTH"
                        dumpType = 'Preview Image'
                        preview = substr(segDataPt, #c1)
                    elseif perl.matches(segDataPt, [[^urn:]]) then  -- (found in Apple HDR images)
                        dumpType = 'URN'
                        useJpegMain = 1
                    elseif perlTruthy(preview) then
                        dumpType = 'Preview Image'
                        preview = preview .. segDataPt
                    end
                end
                if perlTruthy(preview) and nextMarker ~= marker then
                    self:FoundTag('PreviewImage', preview)
                    preview = nil
                end
            elseif marker == 0xe3 then          -- APP3 (Kodak "Meta", Stim)
                if perl.matches(segDataPt, [[^(Meta|META|Exif)\0\0]]) then
                    dumpType = nil      -- (will be dumped here)
                    DirStart(dirInfo, 6, 6)
                    if htmlDump then
                        self:HDump(segPos - 4, 10, 'APP3 Meta header')
                        dumpEnd = segPos + length
                    end
                    local tagTablePtr = self:GetTagTable('lexiftool.Kodak.Meta')
                    self:ProcessTIFF(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^Stim\0]]) then
                    dumpType = nil      -- (will be dumped here)
                    DirStart(dirInfo, 6, 6)
                    if htmlDump then
                        self:HDump(segPos - 4, 4, 'APP3 header', 'Data size: ' .. length .. ' bytes')
                        self:HDump(segPos, 5, 'Stim header', 'APP3 data type: Stim')
                        dumpEnd = segPos + length
                    end
                    -- extract the Stim information (it is in standard TIFF format)
                    local tagTablePtr = self:GetTagTable('lexiftool.Stim.Main')
                    self:ProcessTIFF(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^_JPSJPS_]]) then
                    dumpType = 'JPS'
                    if self.FILE_TYPE == 'JPEG' then self:OverrideFileType('JPS') end
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.JPS')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif self.HasIJPEG or self.Make == 'DJI' then
                    dumpType = self.HasIJPEG and 'InfiRay ImagingData' or 'DJI ThermalData'
                    -- add this data to the combined data if it exists
                    local dataPt = segDataPt
                    if combinedSegData ~= nil then
                        combinedSegData = combinedSegData .. segDataPt
                        dataPt = combinedSegData
                    end
                    if nextMarker == marker then
                        if combinedSegData == nil then combinedSegData = segDataPt end
                    else
                        -- process InfiRay/DJI thermal data
                        local tagTablePtr = self:GetTagTable('lexiftool.JPEG.Main')
                        self:HandleTag(tagTablePtr, 'APP3', dataPt)
                        combinedSegData = nil
                    end
                elseif perl.matches(segDataPt, [[^\xff\xd8\xff\xdb]]) then
                    dumpType = 'PreviewImage' -- (Samsung, HP, BenQ)
                    preview = segDataPt
                end
                if perlTruthy(preview) and nextMarker ~= 0xe4 then -- this preview continues in APP4
                    self:FoundTag('PreviewImage', preview)
                    preview = nil
                end
            elseif marker == 0xe4 then          -- APP4 (InfiRay, "SCALADO", FPXR, DJI, PreviewImage)
                local c1
                if perl.matches(segDataPt, [[^SCALADO\0]]) and length >= 16 then
                    dumpType = 'SCALADO'
                    local num, idx, len = unpack_('x8n2N', segDataPt)
                    -- assume that the segments are in order and just concatinate them
                    if scalado == nil then scalado = '' end
                    scalado = scalado .. substr(segDataPt, 16)
                    if idx == num - 1 then
                        if len ~= #scalado then
                            self:Warn('Possibly corrupted APP4 SCALADO data', 1)
                        end
                        local dirInfo = {
                            Parent = markerName,
                            DataPt = scalado,
                        }
                        local tagTablePtr = self:GetTagTable('lexiftool.Scalado.Main')
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                        scalado = nil
                    end
                elseif perl.matches(segDataPt, [[^Qualcomm Dual Camera Attributes]]) then
                    dumpType = 'Qualcomm Dual Camera'
                    local tagTablePtr = self:GetTagTable('lexiftool.Qualcomm.DualCamera')
                    DirStart(dirInfo, 31)
                    dirInfo.DirName = 'Qualcomm Dual Camera'
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^FPXR\0]]) then
                    if fast > 1 then goto nextMarker end    -- skip processing for very fast
                    dumpType = 'FPXR'
                    local tagTablePtr = self:GetTagTable('lexiftool.FlashPix.Main')
                    -- set flag if this is the last FPXR segment
                    dirInfo.LastFPXR = not (nextMarker == marker and perl.matches(nextSegDataPt, [[^FPXR\0]]))
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif self.Make == 'DJI' and perl.matches(segDataPt, [[^\xaa\x55\x12\x06]]) then
                    dumpType = 'DJI ThermalParams'
                    DirStart(dirInfo, 0, 0)
                    local tagTablePtr = self:GetTagTable('lexiftool.DJI.ThermalParams')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif self.Make == 'DJI' and perl.isMatch(segDataPt, [[(?s)^(.{32})?.{32}\x2c\x01\x20\0]]) then
                    c1 = perl.matches(segDataPt, [[(?s)^(.{32})?.{32}\x2c\x01\x20\0]])
                    dumpType = 'DJI ThermalParams2'
                    DirStart(dirInfo, perlTruthy(c1) and 32 or 0, 0)
                    local tagTablePtr = self:GetTagTable('lexiftool.DJI.ThermalParams2')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif self.Make == 'DJI' and perl.matches(segDataPt, [[(?s)^.{32}\xaa\x55\x38\0]]) then
                    dumpType = 'DJI ThermalParams3'
                    DirStart(dirInfo, 32, 0)
                    local tagTablePtr = self:GetTagTable('lexiftool.DJI.ThermalParams3')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif self.HasIJPEG and length >= 120 then
                    dumpType = 'InfiRay Factory'
                    ExifTool.SetByteOrder('II')
                    local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.Factory')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perlTruthy(preview) then
                    -- continued Samsung S1060 preview from APP3
                    dumpType = 'PreviewImage'
                    preview = preview .. segDataPt
                end
                -- (also seen "QTI Debug Metadata\0" segment in some newer Samsung images)
                -- BenQ DC E1050 continues preview in APP5
                if perlTruthy(preview) and nextMarker ~= 0xe5 then
                    self:FoundTag('PreviewImage', preview)
                    preview = nil
                end
            elseif marker == 0xe5 then          -- APP5 (InfiRay, Ricoh "RMETA")
                if perl.matches(segDataPt, [[^RMETA\0]]) then
                    -- (NOTE: apparently these may span multiple segments, but I haven't seen
                    -- a sample like this, so multi-segment support hasn't yet been implemented)
                    dumpType = 'Ricoh RMETA'
                    DirStart(dirInfo, 6, 6)
                    local tagTablePtr = self:GetTagTable('lexiftool.Ricoh.RMETA')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^ssuniqueid\0]]) then
                    local tagTablePtr = self:GetTagTable('lexiftool.Samsung.APP5')
                    self:HandleTag(tagTablePtr, 'ssuniqueid', substr(segDataPt, 11))
                elseif self.Make == 'DJI' then
                    dumpType = 'DJI ThermalCal'
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.Main')
                    self:HandleTag(tagTablePtr, 'APP5', segDataPt)
                elseif self.HasIJPEG and length >= 38 then
                    dumpType = 'InfiRay Picture'
                    ExifTool.SetByteOrder('II')
                    local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.Picture')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perlTruthy(preview) then
                    dumpType = 'PreviewImage'
                    preview = preview .. segDataPt
                    self:FoundTag('PreviewImage', preview)
                    preview = nil
                end
            elseif marker == 0xe6 then          -- APP6 (InfiRay, Toshiba EPPIM, NITF, HP_TDHD)
                if perl.matches(segDataPt, [[^EPPIM\0]]) then
                    dumpType = nil      -- (will be dumped here)
                    DirStart(dirInfo, 6, 6)
                    if htmlDump then
                        self:HDump(segPos - 4, 10, 'APP6 EPPIM header')
                        dumpEnd = segPos + length
                    end
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.EPPIM')
                    self:ProcessTIFF(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^NITF\0]]) then
                    dumpType = 'NITF'
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.NITF')
                    DirStart(dirInfo, 5)
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^TDHD\x01\0\0\0]]) and length > 12 then
                    -- HP Photosmart R837 APP6 "TDHD" segment
                    dumpType = 'TDHD'
                    local tagTablePtr = self:GetTagTable('lexiftool.HP.TDHD')
                    -- (ignore first TDHD element because size includes 12-byte tag header)
                    DirStart(dirInfo, 12)
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^GoPro\0]]) then
                    -- GoPro segment
                    dumpType = 'GoPro'
                    local tagTablePtr = self:GetTagTable('lexiftool.GoPro.GPMF')
                    DirStart(dirInfo, 6)
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[(?s)^DTAT\0\0.\{]]) then
                    dumpType = 'DJI_DTAT'
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.Main')
                    self:HandleTag(tagTablePtr, 'APP6', segDataPt)
                elseif self.HasIJPEG and length >= 129 then
                    dumpType = 'InfiRay MixMode'
                    ExifTool.SetByteOrder('II')
                    local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.MixMode')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                end
            elseif marker == 0xe7 then          -- APP7 (InfiRay, Pentax, Huawei, Qualcomm)
                local c1, c2 = perl.matches(segDataPt, [[^(PENTAX |RICOH)\0(II|MM)]])
                if c1 then
                    -- found in K-3 and Ricoh GR_IV images (is this multi-segment??)
                    ExifTool.SetByteOrder(c2)
                    dumpType = nil -- (dump this ourself)
                    local hdrLen = #c1 + 3
                    local tagTablePtr = self:GetTagTable('lexiftool.Pentax.Main')
                    DirStart(dirInfo, hdrLen, 0)
                    dirInfo.DirName = 'Pentax APP7'
                    if htmlDump then
                        self:HDump(segPos - 4, 4, 'APP7 header', 'Data size: ' .. length .. ' bytes')
                        self:HDump(segPos, hdrLen, 'Pentax header', 'APP7 data type: Pentax')
                        dumpEnd = segPos + length
                    end
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                else
                    c1 = perl.matches(segDataPt, [[^HUAWEI\0\0(II|MM)]])
                    if c1 then
                        ExifTool.SetByteOrder(c1)
                        dumpType = nil -- (dump this ourself)
                        local hdrLen = 16
                        local tagTablePtr = self:GetTagTable('lexiftool.Unknown.Main')
                        DirStart(dirInfo, hdrLen, 8)
                        dirInfo.DirName = 'Huawei APP7'
                        if htmlDump then
                            self:HDump(segPos - 4, 4, 'APP7 header', 'Data size: ' .. length .. ' bytes')
                            self:HDump(segPos, hdrLen, 'Huawei header', 'APP7 data type: Huawei')
                            dumpEnd = segPos + length
                        end
                        self.SET_GROUP0 = 'APP7'
                        self.SET_GROUP1 = 'Huawei'
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                        self.SET_GROUP0 = nil
                        self.SET_GROUP1 = nil
                    elseif perl.matches(segDataPt, [[^DJI-DBG\0]]) then
                        dumpType = 'DJI Info'
                        local tagTablePtr = self:GetTagTable('lexiftool.DJI.Info')
                        DirStart(dirInfo, 8, 0)
                        self.SET_GROUP0 = 'APP7'
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                        self.SET_GROUP0 = nil
                    elseif perl.matches(segDataPt, [[^\x1aQualcomm Camera Attributes]]) then
                        -- found in HP iPAQ_VoiceMessenger
                        dumpType = 'Qualcomm'
                        local tagTablePtr = self:GetTagTable('lexiftool.Qualcomm.Main')
                        DirStart(dirInfo, 27)
                        dirInfo.DirName = 'Qualcomm'
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                    elseif self.HasIJPEG and length >= 32 then
                        dumpType = 'InfiRay OpMode'
                        ExifTool.SetByteOrder('II')
                        local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.OpMode')
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                    end
                end
            elseif marker == 0xe8 then          -- APP8 (InfiRay, SPIFF)
                -- my sample SPIFF has 32 bytes of data, but spec states 30
                if perl.matches(segDataPt, [[^SPIFF\0]]) and length == 32 then
                    dumpType = 'SPIFF'
                    DirStart(dirInfo, 6)
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.SPIFF')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif self.HasIJPEG and length >= 32 then
                    dumpType = 'InfiRay Isothermal'
                    ExifTool.SetByteOrder('II')
                    local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.Isothermal')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^SEAL\0]]) then
                    dumpType = 'SEAL'
                    DirStart(dirInfo, 5)
                    self:ProcessDirectory(dirInfo, self:GetTagTable('lexiftool.XMP.SEAL'))
                end
            elseif marker == 0xe9 then          -- APP9 (InfiRay, Media Jukebox)
                if perl.matches(segDataPt, [[^Media Jukebox\0]]) and length > 22 then
                    dumpType = 'MediaJukebox'
                    -- (start parsing after the "<MJMD>")
                    DirStart(dirInfo, 22)
                    dirInfo.DirName = 'MediaJukebox'
                    local XMP = loadModule('XMP')
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.MediaJukebox')
                    self:ProcessDirectory(dirInfo, tagTablePtr, XMP.ProcessXMP)
                elseif self.HasIJPEG and length >= 768 then
                    dumpType = 'InfiRay Sensor'
                    ExifTool.SetByteOrder('II')
                    local tagTablePtr = self:GetTagTable('lexiftool.InfiRay.Sensor')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                elseif perl.matches(segDataPt, [[^SEAL\0]]) then
                    dumpType = 'SEAL'
                    DirStart(dirInfo, 5)
                    self:ProcessDirectory(dirInfo, self:GetTagTable('lexiftool.XMP.SEAL'))
                end
            elseif marker == 0xea then          -- APP10 (PhotoStudio Unicode comments, HDR gain curve)
                if perl.matches(segDataPt, [[^UNICODE\0]]) then
                    dumpType = 'PhotoStudio'
                    local comment = self:Decode(substr(segDataPt, 8), 'UTF16', 'MM')
                    self:FoundTag('Comment', comment)
                elseif perl.matches(segDataPt, [[(?s)^AROT\0\0.{4}]]) then
                    dumpType = 'AROT' -- (HDR gain curve? PH guess)
                    useJpegMain = 1
                end
            elseif marker == 0xeb then          -- APP11 (JPEG-HDR, JUMBF)
                local c1
                if perl.matches(segDataPt, [[^HDR_RI ]]) then
                    dumpType = 'JPEG-HDR'
                    local dataPt = segDataPt
                    if combinedSegData ~= nil then
                        local found, en = perl.matches(segDataPt, [[~\0]])
                        if found then
                            combinedSegData = combinedSegData .. substr(segDataPt, en)
                        else
                            self:Warn('Invalid format for JPEG-HDR extended segment')
                        end
                        dataPt = combinedSegData
                    end
                    if nextMarker == marker and perl.matches(nextSegDataPt, [[^HDR_RI ]]) then
                        if combinedSegData == nil then combinedSegData = segDataPt end
                    else
                        local tagTablePtr = self:GetTagTable('lexiftool.JPEG.HDR')
                        local dirInfo = { DataPt = dataPt }
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                        combinedSegData = nil
                    end
                else
                    c1 = perl.matches(segDataPt, [[(?s)^(JP..)]])
                    if c1 and #segDataPt >= 16 then
                        -- JUMBF extension marker
                        local hdr = c1  -- luacheck: ignore 211 (unused upstream too)
                        dumpType = 'JUMBF'
                        ExifTool.SetByteOrder('MM')
                        -- (sequence should start from 1, but some software incorrectly writes 0)
                        local seq = ExifTool.Get32u(segDataPt, 4)
                        local len = ExifTool.Get32u(segDataPt, 8)
                        local type = substr(segDataPt, 12, 4)
                        -- a Microsoft bug writes $len and $type incorrectly as little-endian
                        if type == 'bmuj' then
                            self:Warn('Wrong byte order in C2PA APP11 JUMBF header')
                            type = 'jumb'
                            len = unpack_('x8V', segDataPt)
                            -- fix the header
                            segDataPt = substr(segDataPt, 0, 8) .. ExifTool.Put32u(len) .. type .. substr(segDataPt, 16)
                        end
                        local hdrLen
                        if len == 1 and #segDataPt >= 24 then
                            -- (haven't seen this with the Microsoft bug)
                            len = ExifTool.Get64u(segDataPt, 16)
                            hdrLen = 16
                        else
                            hdrLen = 8
                        end
                        if not jumbfChunk[type] then jumbfChunk[type] = { [0] = '' } end
                        if len < hdrLen then
                            self:Warn('Invalid JUMBF segment')
                        elseif jumbfChunk[type][seq] ~= nil and #jumbfChunk[type][seq] ~= 0 then
                            self:Warn('Duplicate JUMBF sequence number')
                        else
                            if seq == 0 then self:Warn('Incorrect JUMBF sequence numbering (should start from 0, not 1)') end
                            -- add to list of JUMBF chunks
                            jumbfChunk[type][seq] = substr(segDataPt, 8 + hdrLen)
                            -- check to see if we have a complete JUMBF box
                            local size = hdrLen
                            for i = 0, lastIndex(jumbfChunk[type]) do
                                if jumbfChunk[type][i] == nil then size = 0 break end
                                size = size + #jumbfChunk[type][i]
                            end
                            if size == len then
                                local buff = { substr(segDataPt, 8, hdrLen) }
                                for i = 0, lastIndex(jumbfChunk[type]) do buff[#buff + 1] = jumbfChunk[type][i] end
                                buff = table.concat(buff)
                                dirInfo.DataPt = buff
                                dirInfo.DataPos = segPos + 8 -- (shows correct offsets for single-segment JUMBF)
                                dirInfo.DataLen = size
                                dirInfo.DirLen = size
                                dirInfo.DirName = 'JUMBF'
                                local tagTablePtr = self:GetTagTable('lexiftool.Jpeg2000.Main')
                                self:ProcessDirectory(dirInfo, tagTablePtr)
                                jumbfChunk[type] = nil
                            end
                        end
                    end
                end
            elseif marker == 0xec then          -- APP12 (Ducky, Picture Info)
                if perl.matches(segDataPt, [[^Ducky]]) then
                    dumpType = 'Ducky'
                    DirStart(dirInfo, 5)
                    local tagTablePtr = self:GetTagTable('lexiftool.APP12.Ducky')
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                else
                    local tagTablePtr = self:GetTagTable('lexiftool.APP12.PictureInfo')
                    if perlTruthy(self:ProcessDirectory(dirInfo, tagTablePtr)) then dumpType = 'Picture Info' end
                end
            elseif marker == 0xed then          -- APP13 (Photoshop, Adobe_CM)
                local isOld
                -- (upstream sets $isOld inside the condition:
                --  `/^$psAPP13hdr/ or (/^$psAPP13old/ and $isOld=1)`)
                if not perl.isMatchDyn(segDataPt, '^' .. psAPP13hdr) and
                    perl.isMatchDyn(segDataPt, '^' .. psAPP13old) then isOld = 1 end
                if perl.isMatchDyn(segDataPt, '^' .. psAPP13hdr) or isOld then
                    dumpType = 'Photoshop'
                    -- add this data to the combined data if it exists
                    local dataPt = segDataPt
                    if combinedSegData ~= nil then
                        combinedSegData = combinedSegData .. substr(segDataPt, #psAPP13hdr)
                        dataPt = combinedSegData
                    end
                    -- peek ahead to see if the next segment is photoshop data too
                    if nextMarker == marker and perl.isMatchDyn(nextSegDataPt, '^' .. psAPP13hdr) then
                        -- initialize combined data if necessary
                        if combinedSegData == nil then combinedSegData = segDataPt end
                        -- (will handle the Photoshop data the next time around)
                    else
                        local hdrLen = isOld and 27 or 14
                        -- process APP13 Photoshop record
                        local tagTablePtr = self:GetTagTable('lexiftool.Photoshop.Main')
                        local dirInfo = {
                            DataPt   = dataPt,
                            DataPos  = segPos,
                            DataLen  = #dataPt,
                            DirStart = hdrLen,  -- directory starts after identifier
                            DirLen   = #dataPt - hdrLen,
                            Parent   = markerName,
                        }
                        self:ProcessDirectory(dirInfo, tagTablePtr)
                        combinedSegData = nil
                    end
                elseif perl.matches(segDataPt, [[^Adobe_CM]]) then
                    dumpType = 'Adobe_CM'
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.AdobeCM')
                    DirStart(dirInfo, 8)
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                end
            elseif marker == 0xee then          -- APP14 (Adobe)
                if perl.matches(segDataPt, [[^Adobe]]) then
                    -- extract as a block if requested, or if copying tags from file
                    if req.adobe or
                        -- (not extracted normally, so check TAGS_FROM_FILE)
                        (self.TAGS_FROM_FILE and not (self.EXCL_TAG_LOOKUP and self.EXCL_TAG_LOOKUP.adobe))
                    then
                        self:FoundTag('Adobe', segDataPt)
                    end
                    dumpType = 'Adobe'
                    ExifTool.SetByteOrder('MM')
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.Adobe')
                    DirStart(dirInfo, 5)
                    self:ProcessDirectory(dirInfo, tagTablePtr)
                end
            elseif marker == 0xef then          -- APP15 (GraphicConverter)
                local q = perl.matches(segDataPt, [[^Q\s*(\d+)]])
                if q and length == 4 then
                    dumpType = 'GraphicConverter'
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.GraphConv')
                    self:HandleTag(tagTablePtr, 'Q', q)
                end
            elseif marker == 0xfe then          -- COM (JPEG comment)
                dumpType = 'Comment'
                segDataPt = perl.subst(segDataPt, [[\0+$]], '')    -- some dumb softwares add null terminators
                self:FoundTag('Comment', segDataPt)
            elseif marker == 0x64 then          -- CME (J2C comment and extension)
                dumpType = 'Comment'
                if length > 2 then
                    local reg = unpack_('n', segDataPt) -- get registration value
                    local val = substr(segDataPt, 2)
                    if reg == 1 then val = self:Decode(val, 'Latin') end
                    -- (actually an extension for $reg==65535, but store as binary comment)
                    self:FoundTag('Comment', (reg == 0 or reg == 65535) and { ref = 'SCALAR', value = val } or val)
                end
            elseif marker == 0x51 then          -- SIZ (J2C)
                local w, h = unpack_('x2N2', segDataPt)
                if not gotSize then
                    gotSize = 1
                    self:FoundTag('ImageWidth', w)
                    self:FoundTag('ImageHeight', h)
                end
            elseif (marker & 0xf0) ~= 0xe0 then
                dumpType = markerName .. ' segment'
                desc = '[JPEG ' .. markerName .. ']'   -- (other known JPEG segments)
            end
            if dumpType ~= nil then
                if useJpegMain then
                    local tagTablePtr = self:GetTagTable('lexiftool.JPEG.Main')
                    self:HandleTag(tagTablePtr, markerName, segDataPt)
                end
                if dumpType == '' and (perlTruthy(options.Unknown) or perlTruthy(options.Validate)) then
                    local c1 = perl.matches(segDataPt, [[^([\x20-\x7e]{1,20})\0]])
                    local str = c1 and (" '" .. c1 .. "'") or ''
                    -- luacheck: ignore 321 (upstream never sets $xtra either)
                    if not xtra then xtra = 'segment' end
                    self:Warn('Unknown ' .. markerName .. str .. ' ' .. xtra, 1)
                end
                if htmlDump then
                    if not desc then desc = markerName .. (dumpType ~= '' and (' ' .. dumpType) or '') .. ' segment' end
                    self:HDump(segPos - 4, length + 4, desc, tip, 0x08)
                    dumpEnd = segPos + length
                end
            end
        end
        ::nextMarker::
    end
    ::lastMarker::
    -- print verbose hash message if necessary
    if perlTruthy(hashsize) and verbose ~= 0 then
        out:write(indent .. '(ImageDataHash: ' .. hashsize .. ' bytes of JPEG image data)\n')
    end
    -- calculate JPEGDigest if requested
    if next(dqt) then
        require('lexiftool.JPEGDigest').Calculate(self, dqt, subSampling)
    end
    -- issue necessary warnings
    if next(jumbfChunk) then self:Warn('Invalid JUMBF size or missing JUMBF chunk') end
    if iccChunkCount ~= nil then self:Warn('Incomplete ICC_Profile record', 1) end
    if flirCount ~= nil then self:Warn('Incomplete FLIR record', 1) end
    if self.PreviewError then self:Warn('Error reading PreviewImage', 1) end
    if not success then self:Warn('JPEG format error') end
    if #path > pn then path[#path] = nil end
    return 1
end
-- luacheck: pop

--------------------------------------------------------------------------------
-- Composite tags
--------------------------------------------------------------------------------
-- (the value BuildCompositeTags stores for a Composite tag: upstream's
--  \%tagKey, the hash of Require/Desire index => tag key, which GetValue
--  recognizes as `ref $val eq 'HASH'` -- here the `ref` of this metatable)
local CompositeKeys = { __index = { ref = 'HASH' } }
--------------------------------------------------------------------------------
-- Build Composite tags from Require'd/Desire'd tags
-- Inputs: 0) ExifTool object reference, 1) flag to build only tags that require
--         tags from alternate files (without this, these tags are ignored)
-- Note: Tag values are calculated in alphabetical order unless a tag Require's
--       or Desire's another Composite tag, in which case the calculation is
--       deferred until after the other tag is calculated.
-- (port: a Lua `goto nextTag` is upstream's `next COMPOSITE_TAG`; the value
--  stored for a Composite tag is %tagKey with the CompositeKeys metatable, and
--  FoundTag evaluates a Composite RawConv on it as upstream's does)
function ExifTool:BuildCompositeTags(altOnly)
    self.BuildingComposite = 1

    -- (port: upstream always has Exif.pm and its Composite tags loaded; this
    --  port loads Exif.lua only when a file needs it, so it is made sure of
    --  here -- loading it adds its Composite tags, see AddCompositeTags)
    require('lexiftool.Exif')
    local compTable = ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.Composite')
    local tagList = ExifTool.TagTableKeys(compTable)
    tsort(tagList)
    local rawValue = self.VALUE
    local compKeys = self.COMP_KEYS
    local cache, allBuilt = { }, nil

    while true do
        local notBuilt, deferredTags = { }, { }
        for _, t in ipairs(tagList) do
            if not ExifTool.specialTags[t] then notBuilt[compTable[t].Name] = 1 end
        end
        for _, tag in ipairs(tagList) do
            if ExifTool.specialTags[tag] then goto nextTag end
            local tagInfo = self:GetTagInfo(compTable, tag)
            if not tagInfo then goto nextTag end
            local tagName = compTable[tag].Name
            -- put required tags into array and make sure they all exist
            local subDoc = (perlTruthy(tagInfo.SubDoc) and perlTruthy(self.DOC_COUNT))
            local require = tagInfo.Require or { }
            local desire  = tagInfo.Desire  or { }
            local inhibit = tagInfo.Inhibit or { }
            -- loop through sub-documents if necessary
            local docNum = 0
            while true do
                local tagKey, found, requireAlt = setmetatable({ }, CompositeKeys), nil, nil
                -- save Require'd and Desire'd tag values in list
                local index = 0
                while true do
                    local reqTag = require[index] or desire[index] or inhibit[index]
                    if not reqTag then
                        -- allow Composite with no Require'd or Desire'd tags
                        if index == 0 then found = 1 end
                        break
                    end
                    if subDoc then
                        -- handle SubDoc tags specially to cache tag keys for faster
                        -- processing when there are a large number of sub-documents
                        -- - get document number from the tag groups if specified,
                        --   otherwise we are looping through all documents for this tag
                        local doc
                        local docMatch, _, docN = perl.isMatch(reqTag, [[\b(Main|Doc(\d+)):]])
                        if docMatch then
                            reqTag = perl.subst(reqTag, [[\b(Main|Doc(\d+)):]], '')
                            doc = perlTruthy(docN) and perl.num(docN) or 0
                        else
                            doc = docNum
                        end
                        -- make fast lookup for keys of this tag with specified groups other than doc group
                        -- (similar to code in InsertTagValues(), but this is case-sensitive)
                        local cacheTag = cache[reqTag]
                        if not cacheTag then
                            cacheTag = { }
                            cache[reqTag] = cacheTag
                            local reqGroup = perl.matches(reqTag, [[^(.*):]])
                            if reqGroup then reqTag = perl.subst(reqTag, [[^(.*):]], '') end
                            local i, key
                            local keys = { }
                            -- build list of tag keys in order of precedence
                            key, i = reqTag, self.DUPL_TAG[reqTag] or 0
                            while true do
                                if rawValue[key] ~= nil then keys[#keys + 1] = key end
                                if i <= 0 then break end
                                key = reqTag .. ' (' .. i .. ')'
                                i = i - 1
                            end
                            if reqGroup ~= nil then keys = self:GroupMatches(reqGroup, keys) end
                            -- loop through tags in reverse order of precedence so the higher
                            -- priority tag will win in the case of duplicates within a doc
                            for j = #keys, 1, -1 do
                                local k = keys[j]
                                local g3 = self.TAG_EXTRA[k] and self.TAG_EXTRA[k].G3
                                cacheTag[perlTruthy(g3) and perl.num(g3) or 0] = k
                            end
                        end
                        -- (set $reqTag to a bogus key if not found)
                        reqTag = cacheTag[doc] or (reqTag .. ' (0)')
                    else
                        local m, reqGroup, name = perl.isMatch(reqTag, [[^(.*):(.+)]])
                        if m then
                            if reqGroup == 'Composite' and notBuilt[name] then
                                -- defer only until all other tags are built if
                                -- we are inhibiting based on another Composite tag
                                if not (inhibit[index] and allBuilt) then
                                    deferredTags[#deferredTags + 1] = tag
                                    goto nextTag
                                end
                            end
                            local i, key, altFile
                            local keys = { }
                            local et = self
                            -- get tags from alternate file if a family 8 group was specified
                            local fileGroup = perl.matches(reqTag, [[(?i)\b(File\d+):]])
                            if fileGroup and self.ALT_EXIFTOOL[fileGroup] then
                                et = self.ALT_EXIFTOOL[fileGroup]
                                altFile = fileGroup
                                -- set flags indicating we require tags from alternate files
                                self.DoAltComposite = 1
                                requireAlt = 1
                            end
                            -- (CAREFUL! keys may not be sequential if one was deleted)
                            key, i = name, et.DUPL_TAG[name] or 0
                            while true do
                                if et.VALUE[key] ~= nil then keys[#keys + 1] = key end
                                if i <= 0 then break end
                                key = name .. ' (' .. i .. ')'
                                i = i - 1
                            end
                            -- make sure the necessary information is available from the alternate file
                            if altFile then self:CopyAltInfo(altFile, keys) end
                            -- find first matching tag
                            key = self:GroupMatches(reqGroup, keys)[1]
                            reqTag = key or (name .. ' (0)')
                        elseif notBuilt[reqTag] and not inhibit[index] then
                            -- calculate this tag later if it relies on another
                            -- Composite tag which hasn't been calculated yet
                            deferredTags[#deferredTags + 1] = tag
                            goto nextTag
                        end
                    end
                    if rawValue[reqTag] ~= nil then
                        if inhibit[index] then
                            found = 0
                            break
                        else
                            found = 1
                        end
                    elseif require[index] then
                        found = 0
                        break   -- don't continue since we require this tag
                    end
                    tagKey[index] = reqTag
                    index = index + 1
                end
                -- stop now if this requires alternate tags and we aren't building them
                if perlTruthy(requireAlt) ~= perlTruthy(altOnly) then break end
                if docNum ~= 0 then
                    if found == 1 then
                        self.DOC_NUM = docNum
                        -- save pointers to all used tag keys
                        for k, key in pairs(tagKey) do
                            if not compKeys[key] then compKeys[key] = { } end
                            compKeys[key][#compKeys[key] + 1] = { tagKey, k }
                        end
                        self:FoundTag(tagInfo, tagKey)
                        self.DOC_NUM = nil
                    end
                    docNum = docNum + 1
                    if docNum > perl.num(self.DOC_COUNT) then break end
                    goto nextDoc
                elseif found == 1 then
                    notBuilt[tagName] = nil -- this tag is OK to build now
                    -- keep track of all Require'd tag keys
                    for _, key in pairs(tagKey) do -- luacheck: ignore 512
                        -- only tag keys with same name as a Composite tag
                        -- can be replaced (also eliminates keys with
                        -- instance numbers which can't be replaced either)
                        if not compositeID[key] then goto nextKey end
                        ::nextKey::
                    end
                    -- save pointers to all used tag keys
                    for k, key in pairs(tagKey) do
                        if not compKeys[key] then compKeys[key] = { } end
                        compKeys[key][#compKeys[key] + 1] = { tagKey, k }
                    end
                    -- save reference to tag key lookup as value for Composite tag
                    self:FoundTag(tagInfo, tagKey)
                elseif found == nil then
                    notBuilt[tagName] = nil -- tag can't be built anyway
                end
                if not subDoc then break end
                -- don't process sub-documents if there is no chance to build this tag
                -- (can be very time-consuming if there are many docs)
                if next(require) ~= nil then
                    for _, r in pairs(require) do
                        local reqTag = perl.subst(r, [[.*:]], '')
                        if rawValue[reqTag] == nil then goto nextTag end
                    end
                    docNum = 1   -- go ahead and process the 1st sub-document
                else
                    local try = type(tagInfo.SubDoc) == 'table' and tagInfo.SubDoc or ExifTool.TagTableKeys(desire)
                    -- at least one of the specified desire tags must exist
                    for _, t in ipairs(try) do
                        local desTag = desire[t]
                        if desTag then
                            desTag = perl.subst(desTag, [[.*:]], '')
                            if rawValue[desTag] ~= nil then docNum = 1 break end
                        end
                    end
                    if docNum == 0 then break end
                end
                ::nextDoc::
            end
            ::nextTag::
        end
        if #deferredTags == 0 then break end
        if #deferredTags == #tagList then
            if allBuilt then
                -- everything was deferred in the last pass,
                -- must be a circular dependency
                perl.warn("Circular dependency in Composite tags\n")
                break
            end
            allBuilt = 1  -- try once more, ignoring Composite Inhibit tags
        end
        tagList = deferredTags -- calculate deferred tags now
    end
    self.BuildingComposite = nil
end

--------------------------------------------------------------------------------
-- Utility to load our write routines if required (called via AUTOLOAD)
-- Inputs: 0) autoload function, 1-N) function arguments
-- Returns: result of function or dies if function not available
-- (port: Lua has no AUTOLOAD -- the stand-ins for the Write*.pl subs call this
--  with the Perl name of the sub; `require $file` loads the matching Lua
--  module (Image/ExifTool/WriteExif.pl -> lexiftool.WriteExif, Writer.pl ->
--  lexiftool.Writer) and `&$autoload` is that module's function of the name)
function ExifTool.DoAutoLoad(autoload, ...)
    local callInfo = perl.split('::', autoload)
    local file = 'Image/ExifTool/Write'

    if callInfo[#callInfo] == 'DESTROY' then return end
    if #callInfo == 4 then
        -- load Image/ExifTool/WriteMODULE.pl
        file = file .. callInfo[3] .. '.pl'
    elseif callInfo[#callInfo] == 'ShiftTime' then
        file = 'Image/ExifTool/Shift.pl'  -- load Shift.pl
    else
        -- load Image/ExifTool/Writer.pl
        file = file .. 'r.pl'
    end
    -- attempt to load the package
    local ok, module = pcall(require, 'lexiftool.' .. file:match('^Image/ExifTool/(.*)%.pl$'))
    if not ok then perl.die("Error while attempting to call " .. autoload .. "\n" .. tostring(module) .. "\n") end
    local func = module[callInfo[#callInfo]]
    if func == nil then
        -- reproduce Perl's standard 'undefined subroutine' message:
        perl.die("Undefined subroutine " .. autoload .. " called\n")
    end
    return func(...)     -- call the function
end

--------------------------------------------------------------------------------
-- Add cleanup routine to call before returning from Extract
-- Inputs: 0) ExifTool ref, 1) code ref to routine with ExifTool ref as an argument
function ExifTool:AddCleanup(sub)
    if not self.Cleanup then self.Cleanup = { } end
    self.Cleanup[#self.Cleanup + 1] = sub
end

--------------------------------------------------------------------------------
-- Warnings / errors / verbose
--------------------------------------------------------------------------------
-- Warning handler routines (warning string stored in $evalWarning)
-- (Lua: $evalWarning is the module field ExifTool.evalWarning; a caller sets
--  perl.SIG.__WARN__ = ExifTool.SetWarning where upstream localizes
--  $SIG{'__WARN__'})
--
-- Set warning message
-- Inputs: 0) warning string (undef to reset warning)
function ExifTool.SetWarning(str) ExifTool.evalWarning = str end

-- Get warning message
function ExifTool.GetWarning() return ExifTool.evalWarning end

-- Clean unnecessary information (line number, LF) from warning
-- Inputs: 0) warning string or undef to use $evalWarning
-- Returns: cleaned warning
function ExifTool.CleanWarning(str)
    if str == nil then
        if ExifTool.evalWarning == nil then return nil end
        str = ExifTool.evalWarning
    end
    -- truncate at first " at " for warnings like "syntax error at (eval 80) line 1, at EOF"
    local m = perl.matches(str, [[(?s)(.*?) at ]])
    if m then str = m end
    str = perl.subst(str, [[(?s)\s+$]], '')
    return str
end

--------------------------------------------------------------------------------
-- Add warning tag
-- Inputs: 0) ExifTool object reference, 1) warning message
--         2) 0=normal warning, 1=minor, 2=minor with behavioural change when
--            ignored, 3=warning shouldn't be issued with Validate option,
--            bit 0x04 set causes warning count to not be incremented
-- Returns: true if warning tag was added
-- (port: a Lua `true` for $ignorable is Perl's 1)
function ExifTool:Warn(str, ignorable)
    str = perl.str(str)
    local noWarn = self.OPTIONS.NoWarning
    local noCount
    if ignorable == true then ignorable = 1 end
    -- (eval { $str =~ /$noWarn/ }: a pattern that does not compile matches nothing)
    local function noWarnMatches()
        local ok, m = pcall(perl.isMatchDyn, str, noWarn)
        return ok and m
    end
    while perlTruthy(ignorable) do -- luacheck: ignore 512
        ignorable = perl.num(ignorable)
        if ignorable & 0x04 ~= 0 then
            noCount = 1
            ignorable = ignorable & 0x03
            if ignorable == 0 then break end
        end
        local ign = ignorable & 0x03
        if optOn(self.OPTIONS.IgnoreMinorErrors) then return 0 end
        if ign == 3 and perlTruthy(self.OPTIONS.Validate) then return 0 end
        if noWarn ~= nil and noWarnMatches() then return 1 end
        str = (ign == 2 and '[Minor] ' or '[minor] ') .. str
        break
    end
    if not (noWarn ~= nil and noWarnMatches()) then
        -- add each warning only once but count number of occurrences
        if self.WAS_WARNED[str] then
            if not noCount then self.WAS_WARNED[str] = self.WAS_WARNED[str] + 1 end
        else
            self:FoundTag('Warning', str)
            self.WAS_WARNED[str] = 1
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Add error tag
-- Inputs: 0) ExifTool object reference, 1) error message, 2) true if minor
-- Returns: true if error tag was added, otherwise warning was added
function ExifTool:Error(msg, ignorable)
    msg = perl.str(msg)
    if self.DemoteErrors then
        if self:Warn(msg) then self.DemoteErrors = self.DemoteErrors + 1 end
        return 1
    elseif ignorable and perlTruthy(ignorable) then
        if optOn(self.OPTIONS.IgnoreMinorErrors) then
            self:Warn(msg)
            return 0
        end
        msg = '[minor] ' .. msg
    end
    self:FoundTag('Error', msg)
    return 1
end

--------------------------------------------------------------------------------
-- Print verbose output
-- Inputs: 0) ExifTool ref, 1) verbose level (prints if level > this), 2-N) print args
function ExifTool.VPrint(self, level, ...)
    if optOn(self.OPTIONS.Verbose) and self.OPTIONS.Verbose > level then
        local out = self.OPTIONS.TextOut or io.stdout
        local args = { ... }
        out:write(table.concat(args))
        if not perl.str(args[#args] or ''):match('\n$') then out:write('\n') end
    end
end

--------------------------------------------------------------------------------
-- Print verbose value while writing
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.VerboseValue(self, str, val, xtra)
    return ExifTool.DoAutoLoad('Image::ExifTool::VerboseValue', self, str, val, xtra)
end

--------------------------------------------------------------------------------
-- Pack Unicode numbers into UTF8 string
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.PackUTF8(...)
    return ExifTool.DoAutoLoad('Image::ExifTool::PackUTF8', ...)
end

--------------------------------------------------------------------------------
-- Return printable value
-- Inputs: 0) ExifTool object reference
--         1) value to print, 2) line length limit (undef defaults to 60, 0=unlimited)
-- Returns: Printable string
function ExifTool:Printable(outStr, maxLen)
    if outStr == nil then return '(undef)' end
    if type(outStr) == 'table' and outStr.ref == 'SCALAR' then
        return '(Binary data ' .. #outStr.value .. ' bytes)'
    end
    outStr = (type(outStr) == 'number' and ExifTool.NumStr(outStr) or perl.str(outStr)):gsub('[\1-\31\127-\255]', '.')
    outStr = outStr:gsub('\0', '')
    local verbose = self.OPTIONS.Verbose or 0
    if verbose < 4 then
        if perlTruthy(maxLen) then
            if maxLen < 20 then maxLen = 20 end -- minimum length is 20
        elseif maxLen ~= nil then
            maxLen = #outStr -- 0 is unlimited
        else
            maxLen = 60 -- default maximum is 60
        end
    else
        maxLen = #outStr
        -- limit to 2048 characters if verbose < 5
        if maxLen > 2048 and verbose < 5 then maxLen = 2048 end
    end
    -- limit length if necessary
    if #outStr > maxLen then outStr = substr(outStr, 0, maxLen - 6) .. '[snip]' end
    return outStr
end

--------------------------------------------------------------------------------
-- Print verbose directory information
-- Inputs: 0) ExifTool object reference, 1) directory name or dirInfo ref
--         2) number of entries in directory (or 0 if unknown)
--         3) optional size of directory in bytes, 4) optional byte order for -v3 output
function ExifTool:VerboseDir(name, entries, size, byteOrder)
    if not optOn(self.OPTIONS.Verbose) then return end
    if size == nil and type(name) == 'table' then
        size = name.DirLen
        name = name.Name or name.DirName
    end
    local indent = substr(self.INDENT, 0, -2)
    local out = self.OPTIONS.TextOut or io.stdout
    local str = (perlTruthy(entries) or (entries ~= nil and not perlTruthy(size))) and (' with ' .. entries .. ' entries') or ''
    if perlTruthy(size) then str = str .. ', ' .. size .. ' bytes' end
    if byteOrder and self.OPTIONS.Verbose > 2 then
        str = str .. ', ' .. (ExifTool.GetByteOrder() == 'II' and 'Little-endian' or 'Big-endian')
    end
    out:write(indent .. '+ [' .. name .. ' directory' .. str .. ']\n')
end

--------------------------------------------------------------------------------
-- Dump data in hex and ASCII to console
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.HexDump(dataPt, len, opts)
    return ExifTool.DoAutoLoad('Image::ExifTool::HexDump', dataPt, len, opts)
end

--------------------------------------------------------------------------------
-- Verbose dump
-- Inputs: 0) ExifTool ref, 1) data ref, 2-N) HexDump options
function ExifTool:VerboseDump(dataPt, ...)
    local verbose = self.OPTIONS.Verbose or 0
    if verbose > 2 then
        local opts = { Prefix = self.INDENT, Out = self.OPTIONS.TextOut or io.stdout }
        if verbose < 4 then opts.MaxLen = 96
        elseif verbose < 5 then opts.MaxLen = 2048 end
        local extra = { ... }
        if extra[1] and type(extra[1]) == 'table' then
            for k, v in pairs(extra[1]) do opts[k] = v end
        end
        ExifTool.HexDump(dataPt, nil, opts)
    end
end

--------------------------------------------------------------------------------
-- Save information for HTML dump
-- Inputs: 0) ExifTool ref, 1) start offset, 2) data size,
--         3) comment string, 4) tool tip (or SAME), 5) flags, 6) IFD name
function ExifTool:HDump(pos, len, com, tip, flg, ifd)
    if not self.HTML_DUMP then return end
    if self.BASE and self.BASE ~= 0 then pos = pos + self.BASE end
    -- skip structural data blocks which have been removed from the middle of
    -- this dump (SkipData list contains ordered [start,end+1] offsets to skip)
    if self.SkipData then
        local endB = pos + len
        for _, skip in ipairs(self.SkipData) do
            if endB <= skip[1] then break end
            if pos >= skip[2] then
                pos = pos + (skip[2] - skip[1])
            else
                if pos ~= skip[1] then
                    self.HTML_DUMP:Add(pos, skip[1] - pos, com, tip, flg, ifd)
                    len = len - (skip[1] - pos)
                    tip = 'SAME'
                end
                pos = skip[2]
            end
        end
    end
    self.HTML_DUMP:Add(pos, len, com, tip, flg, ifd)
end

--------------------------------------------------------------------------------
-- Dump trailer information
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:DumpTrailer(dirInfo)
    return ExifTool.DoAutoLoad('Image::ExifTool::DumpTrailer', self, dirInfo)
end

--------------------------------------------------------------------------------
-- Dump unknown trailer information
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:DumpUnknownTrailer(dirInfo)
    return ExifTool.DoAutoLoad('Image::ExifTool::DumpUnknownTrailer', self, dirInfo)
end

--------------------------------------------------------------------------------
-- Print verbose tag information
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:VerboseInfo(tagID, tagInfo, parms)
    return ExifTool.DoAutoLoad('Image::ExifTool::VerboseInfo', self, tagID, tagInfo, parms)
end


-- MD5 availability, matching the harness HAS_MD5 flag (Digest::MD5 in
-- upstream); backed by the `digest` rock.
function ExifTool.hasMD5(_self)
    return true
end

-- Raw 16-byte MD5 digest of s (matching Perl's Digest::MD5::md5()), over
-- the `digest` rock; s may be a string or a byte carray.
function ExifTool.md5(_self, s)
    local digest = require('digest')
    return digest.md5(s)
end

-- SHA-256 availability, matching upstream's `eval { require Digest::SHA }`
-- (PDF.pm, for AESV3's Rev-5/6 GetHash path); backed by the `digest` rock.
function ExifTool.hasSHA256(_self)
    return true
end

-- Raw SHA-256/SHA-384/SHA-512 digests of s (matching Perl's
-- Digest::SHA::sha256()/sha384()/sha512()), over the `digest` rock;
-- s may be a string or a byte carray.
function ExifTool.sha256(_self, s)
    local digest = require('digest')
    return digest.sha256(s)
end

function ExifTool.sha384(_self, s)
    local digest = require('digest')
    return digest.sha384(s)
end

function ExifTool.sha512(_self, s)
    local digest = require('digest')
    return digest.sha512(s)
end

-- Digest::SHA->new($alg) for the one upstream caller that hashes
-- incrementally with a run-time algorithm choice (PDF.pm GetHash) and for
-- ExtractInfo's ImageDataHash object. The `digest` rock's digest object has
-- Digest::SHA's interface: add($data, ...), digest() and hexdigest(), which
-- reset the object as upstream's do.
-- Inputs: 0) algorithm (256, 384 or 512)
-- Returns: digest object with add(), digest(), hexdigest() and reset() methods
function ExifTool.DigestSHA(alg)
    local digest = require('digest')
    return digest.new(alg)
end

-- Digest::MD5->new, for ExtractInfo's ImageDataHash object: the `digest`
-- rock's incremental MD5 object, with Digest::MD5's add($data, ...),
-- digest()/hexdigest() (both reset the object) and reset().
-- Returns: digest object with add(), digest(), hexdigest() and reset() methods
function ExifTool.DigestMD5()
    local digest = require('digest')
    return digest.new('md5')
end

-- $$self{ImageDataHash}, the digest object of the ImageDataHash tag, has the
-- name of the ImageDataHash method (Writer.pl).  A field of the object
-- would hide the method, so the digest is stored wrapped: the wrapper
-- forwards add/hexdigest/digest to the digest, and a call through it
-- (`$self->ImageDataHash($raf, ...)` -> `self:ImageDataHash(raf, ...)`) runs
-- the method.  Readers of the member take it with rawget(self, 'ImageDataHash').
-- Inputs: 0) digest object (ExifTool.DigestMD5 or ExifTool.DigestSHA)
-- Returns: the object to store in self.ImageDataHash
local HashMember = {
    __index = {
        add = function(member, ...) member.digest:add(...) return member end,
        digest = function(member) return member.digest:digest() end,
        hexdigest = function(member) return member.digest:hexdigest() end,
    },
    __call = function(_member, self, ...) return ExifTool.ImageDataHash(self, ...) end,
}
function ExifTool.ImageDataHashMember(digest)
    return setmetatable({ digest = digest }, HashMember)
end

-- zlib availability, matching upstream Compress::Zlib's optional-module
-- pattern (`eval { require Compress::Zlib }` -- e.g. PDF.pm's FlateDecode
-- filter, Google.pm's ProcessHDRP gunzip); backed by the `lua-zlib` rock,
-- which is OPTIONAL: callers degrade gracefully (warn + skip) when this
-- returns false, exactly like their upstream counterparts.
local zlibAvailable
function ExifTool.hasZlib(_self)
    if zlibAvailable == nil then
        zlibAvailable = (pcall(require, 'zlib')) and true or false
    end
    return zlibAvailable
end

-- Inflate zlib-format (RFC 1950, with header) compressed data -- the
-- Compress::Zlib::inflateInit()->inflate() equivalent upstream modules use
-- for e.g. PDF FlateDecode streams. Returns (decompressed, true) on
-- success, or (nil, false) if s isn't valid zlib-compressed data.
function ExifTool.inflate(_self, s)
    local zlib = require('zlib')
    local ok, out, eof = pcall(function() return (zlib.inflate())(s) end)
    if not ok or not eof then return nil, false end
    return out, true
end

-- Compress::Zlib status codes and window size, as upstream spells them
-- (`Compress::Zlib::Z_OK()`, `Z_STREAM_END()`, `MAX_WBITS()`).
ExifTool.Z_OK = 0
ExifTool.Z_STREAM_END = 1
ExifTool.Z_DATA_ERROR = -3
ExifTool.MAX_WBITS = 15

-- Compress::Zlib::inflateInit(-WindowBits => $wbits) equivalent: an inflate
-- stream object for upstream callers that feed compressed data piece by
-- piece (Flash.pm ReadCompressed, DICOM.pm's deflated transfer syntax).
-- Its inflate($data) returns ($out, $status) like Compress::Zlib's: Z_OK
-- while more input is needed, Z_STREAM_END once the stream is complete (and
-- on every later call, with no output), Z_DATA_ERROR for corrupt data (and
-- from then on).  Unlike Compress::Zlib, the input argument is not consumed
-- in place -- no upstream caller of this object reads it back.
-- Inputs: 0) optional { WindowBits = N } (default MAX_WBITS = zlib header;
--         negative = raw deflate without header)
-- Returns: inflate object, or nil if the stream can't be initialized
function ExifTool.inflateInit(opts)
    local zlib = require('zlib')
    local wbits = opts and opts.WindowBits or ExifTool.MAX_WBITS
    local ok, stream = pcall(zlib.inflate, wbits)
    if not ok then return nil end
    local status = ExifTool.Z_OK
    return {
        inflate = function(_self, s)
            if status == ExifTool.Z_STREAM_END then return '', status end
            if status ~= ExifTool.Z_OK then return nil, status end
            local ok2, out, eof = pcall(stream, s)
            if not ok2 then
                status = ExifTool.Z_DATA_ERROR
                return nil, status
            end
            if eof then status = ExifTool.Z_STREAM_END end
            return out, eof and ExifTool.Z_STREAM_END or ExifTool.Z_OK
        end,
    }
end

-- Deflate to zlib format (RFC 1950, with header) -- the
-- Compress::Zlib::deflateInit()->deflate()/flush() equivalent (e.g.
-- WritePNG.pl's compressed zTXt profile chunks). Same optional-module
-- pattern as inflate above; returns (compressed, true), or (nil, false).
function ExifTool.deflate(_self, s)
    local zlib = require('zlib')
    local ok, out = pcall(function() return (zlib.deflate())(s, 'finish') end)
    if not ok or out == nil then return nil, false end
    return out, true
end

-- Compress::Zlib::deflateInit() equivalent: a deflate stream object whose
-- deflate($data) returns the compressed output so far (undef on error) and
-- flush() the rest (e.g. WritePNG.pl's iCCP/zTXt/iTXt chunks, which feed
-- the data and flush separately).  Same optional-module pattern as above.
-- lua-zlib takes no memLevel argument: Compress::Zlib deflates with
-- MAX_MEM_LEVEL (9), lua-zlib with zlib's default (8), so beyond roughly
-- 16k symbols per deflate block the compressed bytes differ from upstream's
-- (the inflated data is the same).
function ExifTool.deflateInit()
    local zlib = require('zlib')
    local ok, stream = pcall(zlib.deflate)
    if not ok then return nil end
    return {
        deflate = function(_self, s)
            local ok2, out = pcall(stream, s)
            if not ok2 then return nil end
            return out
        end,
        -- (upstream appends flush() to the deflate() output, where an undef
        --  appends nothing: '' on error here)
        flush = function(_self)
            local ok2, out = pcall(stream, '', 'finish')
            if not ok2 or out == nil then return '' end
            return out
        end,
    }
end

-- Inflate RAW-deflate (RFC 1951, no header) compressed data -- the
-- IO::Uncompress::RawInflate equivalent (e.g. FLIF.pm's metadata chunks).
-- Same optional-module pattern as inflate above; lua-zlib exposes raw mode
-- through a negative windowBits argument.
function ExifTool.inflateRaw(_self, s)
    local zlib = require('zlib')
    local ok, out, eof = pcall(function() return (zlib.inflate(-15))(s) end)
    if not ok or not eof then return nil, false end
    return out, true
end

-- IO::Uncompress::RawInflate::rawinflate(\$in => \$out) equivalent, with
-- that function's defaults (Transparent => 1, BlockSize => 16384, no
-- MultiStream): the first block of input decides whether the data is raw
-- deflate at all -- if it fails to inflate, or the input ends there without
-- completing the stream, the input is passed through unchanged (and the
-- call succeeds); a failure after the first block is an error.  Data after
-- the end of the stream is ignored.
-- Returns (output, true) on success, or (nil, false) on error.
function ExifTool.rawinflate(_self, s)
    local zlib = require('zlib')
    local blockSize = 16384
    local ok, stream = pcall(zlib.inflate, -15)
    if not ok then return nil, false end
    local ok2, out, eof = pcall(stream, s:sub(1, blockSize))
    if not ok2 or (not eof and #s <= blockSize) then
        return s, true      -- not raw deflate data: read it transparently
    end
    if eof then return out, true end
    local ok3, out2, eof2 = pcall(stream, s:sub(blockSize + 1))
    if not ok3 or not eof2 then return nil, false end
    return out .. out2, true
end

-- Deflate to RAW deflate (RFC 1951, no header) -- the
-- IO::Compress::RawDeflate equivalent (e.g. FLIF.pm's metadata chunks).
-- Same negative-windowBits raw mode as inflateRaw above; the default level
-- matches IO::Compress::RawDeflate's Z_DEFAULT_COMPRESSION, so the output is
-- byte-for-byte what upstream writes.
function ExifTool.deflateRaw(_self, s)
    local zlib = require('zlib')
    local ok, out = pcall(function() return (zlib.deflate(-1, -15))(s, 'finish') end)
    if not ok or out == nil then return nil, false end
    return out, true
end

-- Gunzip gzip-format (RFC 1952) compressed data -- the
-- IO::Uncompress::Gunzip::gunzip($in, $out) equivalent (e.g. Google.pm's
-- ProcessHDRP). Unlike Compress::Zlib's strict inflate above, upstream's
-- IO::Uncompress layer tolerates trailing data after the gzip stream has
-- completed (the decrypted HDRP container may carry slack past the gzip
-- footer), so only the decompressed payload is required here.
-- Returns the decompressed string, or nil on error.
function ExifTool.gunzip(_self, s)
    local zlib = require('zlib')
    local ok, out = pcall(function() return ((zlib.inflate())(s)) end)
    if not ok or not out then return nil end
    return out
end
--------------------------------------------------------------------------------
-- Make current directory the priority directory if not set already
-- Inputs: 0) ExifTool object reference
function ExifTool:SetPriorityDir()
    if not self.PRIORITY_DIR then self.PRIORITY_DIR = self.DIR_NAME end
end

--------------------------------------------------------------------------------
-- Set family 0 or 1 group name specific to this tag instance
-- Inputs: 0) ExifTool ref, 1) tag key, 2) group name, 3) family (default 1)
function ExifTool:SetGroup(tagKey, extra, fam)
    local key = fam and ('G' .. fam) or 'G1'
    if not self.TAG_EXTRA[tagKey] then self.TAG_EXTRA[tagKey] = {} end
    self.TAG_EXTRA[tagKey][key] = extra
end

--------------------------------------------------------------------------------
-- Get Metadata path
-- Inputs: 0) ExifTool object ref
-- Return: Metadata path string
function ExifTool:MetadataPath()
    return table.concat(self.PATH or {}, '-')
end

-- Compact/XMPShorthand option settings
local compactOpt = {
    nopadding = 'NoPadding', noindent = 'NoIndent', nonewline = 'NoNewline',
    shorthand = 'Shorthand', onedesc = 'OneDesc',
    all = { 'NoPadding','NoIndent','NoNewline','Shorthand','OneDesc' },
    allspace = { 'NoPadding','NoIndent','NoNewline' }, allformat = { 'Shorthand','OneDesc' },
    -- aliases to cover anticipated user typos
    nonewlines = 'NoNewline', nospace = 'NoIndent', nospaces = 'NoIndent',
    nopad = 'NoPadding', onedescr = 'OneDesc',
    -- allow numerical settings for backward compatibility
    ['0'] = 'None',
    ['1'] = 'NoPadding',
    ['2'] = { 'NoPadding','NoIndent' },
    ['3'] = { 'NoPadding','NoIndent','OneDesc' },
    ['4'] = { 'NoPadding','NoIndent','OneDesc','NoNewline' },
    ['5'] = { 'NoPadding','NoIndent','OneDesc','NoNewline','Shorthand' },
}
local xmpShorthandOpt = { ['0'] = 'None', ['1'] = 'Shorthand', ['2'] = { 'Shorthand','OneDesc' } }

--------------------------------------------------------------------------------
-- Object lifecycle
--------------------------------------------------------------------------------
--=============================================================================
-- New - create new ExifTool object
-- Inputs: 0) reference to exiftool object or ExifTool class name
-- Returns: blessed ExifTool object ref
function ExifTool.new()
    ExifTool.LoadConfigFiles()  -- (port: upstream loads it with the module)
    perl.localeRefresh()        -- (port: numbers print with '.' and strings
                                --  sort as bytes whatever the host's locale,
                                --  see perl.lua DECPT and BYTE_ORDER)
    local self = setmetatable({}, ExifTool)

    self:ClearOptions()      -- create default options hash
    self.VALUE = { }        -- must initialize this for warning messages
    self.PATH = { }         -- (this too)
    self.DEL_GROUP = { }    -- lookup for groups to delete when writing
    self.SAVE_COUNT = 0     -- count calls to SaveNewValues()
    self.NV_COUNT = 0       -- count of NEW_VALUE entries
    self.FILE_SEQUENCE = 0  -- sequence number for files when reading
    self.FILES_WRITTEN = 0  -- count of files successfully written
    self.INDENT2 = ''       -- indentation of verbose messages from SetNewValue
    self.ALT_EXIFTOOL = { } -- alternate exiftool objects
    -- (port: Lua has no autovivification -- Warn/FoundTag/GetValue on an
    --  object that has not extracted anything yet use these members of Init
    --  (ExifTool.pm:4344-4356), which Perl creates on first access)
    self.FILE_ORDER = { }   -- * hash of tag order in file
    self.BOTH       = { }   -- * hash for Value/PrintConv values of Require'd tags
    self.TAG_INFO   = { }   -- * hash of tag information
    self.TAG_EXTRA  = { }   -- * hash of extra tag information (dynamic group names)
    self.PRIORITY   = { }   -- * priority of current tags
    self.LIST_TAGS  = { }   -- hash of tagInfo refs for active List-type tags
    self.DUPL_TAG   = { }   -- last-used index for duplicate-tag keys
    self.WAS_WARNED = { }   -- number of times each warning was issued
    self.COMP_KEYS  = { }   -- lookup for tag keys used in Composite tags
    self.INDENT = '  '      -- initial indent for verbose messages

    -- initialize our new groups for writing
    self:SetNewGroups(table.unpack(defaultWriteGroups))

    return self
end

--=============================================================================
-- Functions below this are not part of the public API

-- (upstream %static_vars: package-level variables reset for each new file;
--  published on the module table since FlashPix.pm writes
--  $static_vars{OverrideFileDescription}, read by the description form of
--  GetFileType)
ExifTool.static_vars = {}

-- Initialize member variables before reading or writing a new file
-- Inputs: 0) ExifTool object reference
function ExifTool:Init()
    -- MAKER_NOTE_BYTE_ORDER must survive a write's Init() call (upstream's
    -- Init only deletes DataMember variables, i.e. lowercase names, and
    -- clears MAKER_NOTE_BYTE_ORDER explicitly at the start of each
    -- ExtractInfo instead -- see that function); SetNewValuesFromFile
    -- transfers it to the destination object so a later fresh-EXIF write
    -- follows the source file's byte order (Writer.t test 19).
    -- REQ_TAG_LOOKUP survives too when ReqTagAlreadySet is set, which is how
    -- DoneExtract hands the main file's requested tags to an alternate-file
    -- object (upstream ParseArguments: `$$self{REQ_TAG_LOOKUP} = { } unless
    -- $$self{ReqTagAlreadySet}`).
    -- ALT_FILE and DID_EXTRACT belong to the alternate-file object itself, not
    -- to the file it is about to read: SetAlternateFile compares ALT_FILE to
    -- decide whether an already-extracted object can be reused, and DoneExtract
    -- reads DID_EXTRACT to avoid extracting the same alternate file twice.
    -- NO_SORT is a flag the caller sets on the object (TestLib's "hack to
    -- avoid sorting", ExifTool.t test 26); upstream's Init leaves it alone
    -- because it deletes only the lower-case DataMember keys plus a fixed
    -- list (ExifTool.pm:4332-4338).  ESCAPE_PROC is kept in sync with the
    -- Escape option by Options(), and like CUR_LANG it must outlive Init.
    local reqTagAlreadySet = self.ReqTagAlreadySet
    for k in pairs(self) do
        if k ~= 'OPTIONS' and k ~= 'ALT_EXIFTOOL' and k ~= 'NEW_VALUE' and
            k ~= 'ALT_FILE' and k ~= 'DID_EXTRACT' and
            k ~= 'MAKER_NOTE_BYTE_ORDER' and k ~= 'CUR_LANG' and k ~= 'ESCAPE_PROC' and
            k ~= 'DEL_GROUP' and k ~= 'SAVE_COUNT' and k ~= 'NV_COUNT' and
            k ~= 'PDF_CAPTURE' and k ~= 'NO_SORT' and
            k ~= 'FILE_SEQUENCE' and k ~= 'FILES_WRITTEN' and
            -- (set by ParseArguments before ExtractInfo's Init, which upstream
            --  leaves alone: it deletes only the lower-case members)
            k ~= 'TAGS_FROM_FILE' and k ~= 'EXCL_TAG_LOOKUP' and k ~= 'EXCL_XMP_LOOKUP' and
            not (reqTagAlreadySet and (k == 'REQ_TAG_LOOKUP' or k == 'ReqTagAlreadySet')) then
            self[k] = nil
        end
    end
    -- reset static variables
    ExifTool.static_vars = {
        KeepUTCTime = self.OPTIONS.KeepUTCTime,
        SystemTimeRes = self.OPTIONS.SystemTimeRes,
    }
    self.VALUE = {}
    self.TAG_INFO = {}
    self.TAG_EXTRA = {}
    self.FILE_ORDER = {}
    self.BOTH = {}
    self.PRIORITY = {}
    self.DUPL_TAG = {}
    self.LIST_TAGS = {}
    self.PROCESSED = {}
    self.DIR_COUNT = {}
    self.WAS_WARNED = {}
    -- PreviewIFD tags (Nikon/Samsung) are priority 0 by default (upstream:
    -- `$$self{LOW_PRIORITY_DIR} = { PreviewIFD => 1 };`, Image::ExifTool.pm:4368)
    self.LOW_PRIORITY_DIR = { PreviewIFD = 1 }
    self.PATH = {}
    self.FOUND_DIR = {}
    self.COMP_KEYS = {}     -- lookup for tag keys used in Composite tags
    self.NUM_FOUND = 0
    self.INDENT = '  ' -- initial indent for verbose messages
    self.TIFF_TYPE = '' -- type of TIFF data (APP1, TIFF, NEF, ...); set in ProcessTIFF
    self.HAS_DOC = {}   -- lookup for all document numbers in this file
    self.DEL_GROUP = self.DEL_GROUP or {}   -- lookup for groups to delete when writing
    self.SAVE_COUNT = self.SAVE_COUNT or 0   -- count calls to SaveNewValues()
    self.NV_COUNT = self.NV_COUNT or 0     -- count of NEW_VALUE entries
    self.INDENT2 = ''     -- indentation of verbose messages from SetNewValue
    -- initialize our new groups for writing
    self:SetNewGroups()
    if perlTruthy(self:Options('HtmlDump')) then
        self.HTML_DUMP = require('lexiftool.HtmlDump').new()
    end
    return self
end

-- (names of all available options, standing in for Perl's `exists` test
--  on the OPTIONS hash below)
local optionExists = { }
for _, o in ipairs(availableOptions) do optionExists[o[1]] = true end
-- (and the same names by their lower-case form: for a plain name the grep
--  /^$param$/i below is a case-insensitive comparison, so it is a lookup
--  here instead of one dynamic regex per option -- a name that is no option,
--  e.g. XMP's Options('BlockExtract'), would otherwise run ~100 regexes on
--  every call; the option names are distinct in lower case; built on the
--  first such call, not at load time, where it would cost every start)
local optionLc

--------------------------------------------------------------------------------
-- Get/set ExifTool options
-- Inputs: 0) ExifTool object reference,
--         1) Parameter name (case insensitive), 2) Value to set the option
--         3-N) More parameter/value pairs
-- Returns: original value of last option specified
function ExifTool:Options(...)
    -- upstream: `while (@_) { my $param = shift; ...; last unless @_; my
    -- $newVal = shift; ...}` -- pops name/value pairs off the argument list
    -- until it runs out, stopping *without* setting only when a trailing
    -- name has no paired value. Consuming pairs purely by count (not by
    -- testing the value for nil/falsy) matters: `Options('List', nil,
    -- 'Composite', 0)` must still reach and set 'Composite' even though
    -- the 'List' value is nil.
    local args = { ... }
    local n = select('#', ...)
    local oldVal
    local i = 1
    while i <= n do
        local param = args[i]
        if param == nil then break end
        local plus
        -- fix parameter case if necessary
        -- (`exists $$options{$param}`: every available option is a key of
        --  the Perl hash even while undef, a Lua table has no nil-valued
        --  keys, so the option list stands in for those; a non-string
        --  name -- Perl would stringify a reference -- can match no option
        --  and is left as it is)
        if type(param) == 'string' and self.OPTIONS[param] == nil and not optionExists[param] then
            plus = perl.isMatch(param, [[\+$]])
            param = perl.subst(param, [[\+$]], '')
            local fixed
            if param:find('^[A-Za-z0-9_]+$') then
                -- plain name: the available options by lower case, then the
                -- other keys of OPTIONS (set by the caller, not available)
                local lcParam = lc(param)
                if not optionLc then
                    optionLc = { }
                    for _, o in ipairs(availableOptions) do optionLc[lc(o[1])] = o[1] end
                end
                fixed = optionLc[lcParam]
                if not fixed then
                    for k in pairs(self.OPTIONS) do
                        if not optionExists[k] and type(k) == 'string' and lc(k) == lcParam then
                            fixed = k
                            break
                        end
                    end
                end
            else
                for _, o in ipairs(availableOptions) do
                    if perl.isMatchDyn(o[1], '(?i)^' .. param .. '$') then fixed = o[1] break end
                end
                if not fixed then
                    for k in pairs(self.OPTIONS) do
                        if perl.isMatchDyn(k, '(?i)^' .. param .. '$') then fixed = k break end
                    end
                end
            end
            if fixed then
                param = fixed
            else
                param = perl.subst(param, [[(?i)^Group(\d*)$]], 'Group$1')
            end
        end
        oldVal = self.OPTIONS[param]
        if type(oldVal) == 'table' and (param == 'Compact' or param == 'XMPShorthand') then
            -- get previous Compact/XMPShorthand setting
            oldVal = oldVal[param]
        end
        if i + 1 > n then break end -- get-only: no value given for this param
        local newVal = args[i + 1]
        if param == 'Lang' then
            -- upstream: setting Lang to undef/'en' selects the default
            -- language (self.CUR_LANG cleared); any other value only takes
            -- effect if the module actually loads and its Translate table
            -- is non-empty, otherwise the current language is left alone
            newVal = newVal or 'en'
            if newVal == 'en' then
                self.OPTIONS.Lang = newVal
                self.CUR_LANG = nil
            else
                local xlat = loadLang(newVal)
                if xlat and next(xlat) then
                    self.CUR_LANG = xlat
                    self.OPTIONS.Lang = newVal
                end
            end
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'UserParam' then
            -- clear options if $newVal is undef
            if newVal == nil then
                self.OPTIONS[param] = {}
                i = i + 2
                goto continueOptionsLoop
            end
            local table_ = ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.UserParam')
            -- allow initialization of entire UserParam hash
            if type(newVal) == 'table' then
                local newParams = {}
                local names = {}
                for k in pairs(newVal) do names[#names + 1] = k end
                tsort(names)
                for _, k in ipairs(names) do
                    local lcTag = lc(k)
                    newParams[lcTag] = newVal[k]
                    table_[lcTag] = nil
                    ExifTool.AddTagToTable(nil, table_, lcTag, k)
                end
                self.OPTIONS[param] = newParams
                i = i + 2
                goto continueOptionsLoop
            end
            local force, paramName
            -- set/reset single UserParam parameter
            local pn, nv = perl.matches(newVal, [[(?s)(.*?)=(.*)]])
            if pn then
                paramName = pn
                newVal = nv
                if perl.isMatch(paramName, [[\^$]]) then
                    paramName = perl.subst(paramName, [[\^$]], '')
                    force = 1
                end
                paramName = perl.tr(paramName, '-_a-zA-Z0-9#', '', 'dc')
                param = lc(paramName)
            else
                param = perl.tr(perl.lc(newVal), '-_a-zA-Z0-9#', '', 'dc')
                newVal = nil
            end
            table_[param] = nil
            oldVal = self.OPTIONS.UserParam[param]
            if newVal ~= nil then
                if #perl.str(newVal) > 0 or force then
                    self.OPTIONS.UserParam[param] = newVal
                    ExifTool.AddTagToTable(nil, table_, param, paramName)
                else
                    self.OPTIONS.UserParam[param] = nil
                end
            end
            -- remove alternate version of tag
            if perl.isMatch(param, '#$') then param = perl.subst(param, '#$', '') else param = param .. '#' end
            table_[param] = nil
            self.OPTIONS.UserParam[param] = nil
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'Exclude' and newVal ~= nil then
            -- clone Exclude list and expand shortcuts
            local exclude
            if type(newVal) == 'table' then
                exclude = {}
                for j = 1, #newVal do exclude[j] = newVal[j] end
            else
                exclude = { newVal }
            end
            ExifTool.ExpandShortcuts(exclude, 1)  -- (also remove '#' suffix)
            self.OPTIONS[param] = exclude
            i = i + 2
            goto continueOptionsLoop
        elseif param:find('^Charset') or param == 'IPTCCharset' then
            -- only allow valid character sets to be set
            if perlTruthy(newVal) then
                local charset = charsetName[lc(newVal)]
                if charset then
                    self.OPTIONS[param] = charset
                    -- maintain backward-compatibility with old IPTCCharset option
                    if param == 'IPTCCharset' then self.OPTIONS.CharsetIPTC = charset end
                else
                    -- (upstream: Perl warn(), which the exiftool script
                    --  catches with $SIG{'__WARN__'} -- exiftool:921)
                    io.stderr:write('Invalid Charset ' .. perl.str(newVal) .. '\n')
                end
            elseif param == 'CharsetEXIF' or param == 'CharsetFileName' or param == 'CharsetRIFF' then
                self.OPTIONS[param] = newVal    -- only these may be set to a false value
            elseif param == 'CharsetQuickTime' then
                self.OPTIONS[param] = 'MacRoman' -- QuickTime defaults to MacRoman
            else
                self.OPTIONS[param] = 'Latin'   -- all others default to Latin
            end
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'RequestTags' then
            -- (upstream ExifTool.pm:2539-2549; ExpandShortcuts not ported)
            if newVal ~= nil then
                local reqList = type(newVal) == 'table' and newVal or perl.findAll(newVal, [[[-\w?*:]+]])
                -- add to existing list
                self.OPTIONS[param] = self.OPTIONS[param] or { }
                for _, e in ipairs(reqList) do
                    local nm = perl.matches(e, [[^(?:.*:)?([-\w?*]*)#?$]])
                    if nm and nm ~= '' then
                        self.OPTIONS[param][#self.OPTIONS[param] + 1] = lc(nm)
                    end
                end
            else
                self.OPTIONS[param] = nil
            end
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'IgnoreTags' or param == 'IgnoreGroups' then
            -- (upstream ExifTool.pm:2556-2571; the ExpandShortcuts step for
            --  IgnoreTags is not ported)
            if newVal ~= nil then
                if type(newVal) == 'table' and newVal[1] == nil then
                    self.OPTIONS[param] = newVal
                else
                    local ignoreList = type(newVal) == 'table' and newVal or perl.findAll(newVal, [[[-\w?*:#]+]])
                    -- add to existing tags/groups to ignore
                    self.OPTIONS[param] = self.OPTIONS[param] or { }
                    for _, e in ipairs(ignoreList) do
                        local nm = perl.matches(e, [[^(?:.*:)?([-\w?*]+)#?$]])
                        if nm then self.OPTIONS[param][lc(nm)] = 1 end
                    end
                end
            else
                self.OPTIONS[param] = nil   -- clear the option
            end
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'Escape' then
            -- set ESCAPE_PROC
            if newVal ~= nil and newVal == 'XML' then
                self.ESCAPE_PROC = require('lexiftool.XMP').EscapeXML
            elseif newVal ~= nil and newVal == 'HTML' then
                self.ESCAPE_PROC = require('lexiftool.HTML').EscapeHTML
            else
                self.ESCAPE_PROC = nil
            end
            -- must forget saved values since they depend on Escape method
            self.BOTH = { }
        elseif param == 'Compact' or param == 'XMPShorthand' then
            -- set Compact and XMPShorthand options, preserving backward compatibility
            local compact = { }
            for _, p in ipairs({ 'Compact', 'XMPShorthand' }) do
                -- (allow setting from a HASH (undocumented)
                if type(newVal) == 'table' then
                    for k, v in pairs(newVal) do compact[k] = v end
                    goto nextP
                end
                do
                    local val
                    if param == p then val = newVal else val = (self.OPTIONS.Compact or { })[p] end
                    if val ~= nil then
                        local opt = (p == 'Compact') and compactOpt or xmpShorthandOpt
                        for _, v in ipairs(perl.findAll(perl.str(val), [[\w+]])) do
                            local set = opt[perl.lc(v)]
                            if not set then
                                io.stderr:write('Invalid ' .. p .. " setting '" .. v .. "'\n")
                                return oldVal
                            end
                            if type(set) ~= 'table' then
                                compact[set] = 1
                            else
                                for _, o in ipairs(set) do compact[o] = 1 end
                            end
                        end
                    end
                    compact[p] = val -- preserve most recent setting
                end
                ::nextP::
            end
            self.OPTIONS.Compact = compact
            self.OPTIONS.XMPShorthand = compact
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'NoWarning' then
            -- validate regular expression
            ExifTool.evalWarning = nil
            if newVal ~= nil then
                local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
                perl.SIG.__WARN__ = ExifTool.SetWarning
                local ok, err = pcall(perl.isMatchDyn, param, newVal)
                if not ok then ExifTool.evalWarning = err end
                perl.SIG.__WARN__ = oldWarn
            end
            if ExifTool.evalWarning then
                perl.warn('NoWarning: ' .. ExifTool.CleanWarning() .. "\n")
                i = i + 2
                goto continueOptionsLoop
            end
            -- add to existing expression if specified
            if plus and oldVal ~= nil then
                if newVal ~= nil then newVal = oldVal .. '|' .. newVal else newVal = oldVal end
            end
            self.OPTIONS[param] = newVal
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'ImageHashType' then
            if newVal == nil then
                perl.warn("Can't set " .. param .. " to undef\n")
            elseif perl.isMatch(newVal, [[(?i)^(MD5|SHA256|SHA512)$]]) then
                self.OPTIONS[param] = perl.uc(newVal)
            else
                perl.warn('Invalid ' .. param .. " setting '" .. perl.str(newVal) .. "'\n")
            end
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'StructFormat' then
            if newVal ~= nil then
                if not perl.isMatch(newVal, [[(?i)^(JSON|JSONQ)$]]) then
                    perl.warn('Invalid ' .. param .. " setting '" .. perl.str(newVal) .. "'\n")
                    i = i + 2
                    goto continueOptionsLoop
                end
                newVal = perl.uc(newVal)
            end
            self.OPTIONS[param] = newVal
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'ByteUnit' then
            if newVal ~= nil then
                -- (allow "Metric" or "SI" for SI, and "IT" or "Binary" for Binary)
                local goodVal = (perl.isMatch(newVal, [[(?i)^S|M]]) and 'SI' or
                                (perl.isMatch(newVal, [[(?i)^I|B]]) and 'Binary' or nil))
                if not goodVal then
                    perl.warn('Invalid ' .. param .. " setting '" .. perl.str(newVal) .. "'\n")
                    i = i + 2
                    goto continueOptionsLoop
                end
                self.OPTIONS[param] = goodVal
            else
                perl.warn("Can't set " .. param .. " to undef\n")
            end
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'KeepUTCTime' or param == 'SystemTimeRes' then
            self.OPTIONS[param] = newVal
            ExifTool.static_vars[param] = newVal
            i = i + 2
            goto continueOptionsLoop
        elseif param == 'GlobalTimeShift' then
            self.GLOBAL_TIME_OFFSET = nil  -- reset our calculated offset
        elseif param == 'TimeZone' and newVal ~= nil and perl.length(newVal) > 0 then
            perl.setenv('TZ', newVal)   -- $ENV{TZ} = $newVal
            if perl.osname() == 'MSWin32' then
                if perl.evalRequire('Time::Piece') then
                    pcall(perl.tzset)   -- Time::Piece::_tzset()
                else
                    perl.warn("Install Time::Piece to set time zone in Windows\n")
                end
            else
                pcall(perl.tzset)       -- require POSIX; POSIX::tzset()
            end
        elseif param == 'Validate' then
            -- load Validate module if Validate option enabled
            if perlTruthy(newVal) then require('lexiftool.Validate') end
        end
        self.OPTIONS[param] = newVal
        -- upstream ExifTool.pm: 'ListJoin'/'List' are two faces of the same
        -- underlying ListSep/List pair (kept for backward compatibility with
        -- the deprecated List/ListSep options) -- setting one updates the
        -- other so GetValue's join logic (which only ever looks at List and
        -- ListSep) sees the effect either way.
        if param == 'ListJoin' then
            if newVal ~= nil then
                self.OPTIONS.List = 0
                self.OPTIONS.ListSep = newVal
            else
                self.OPTIONS.List = 1
            end
        elseif param == 'List' then
            -- (`... and nil or ...` would always yield the right side in Lua)
            if newVal and newVal ~= 0 then
                self.OPTIONS.ListJoin = nil
            else
                self.OPTIONS.ListJoin = self.OPTIONS.ListSep
            end
        end
        i = i + 2
        ::continueOptionsLoop::
    end
    return oldVal
end

--------------------------------------------------------------------------------
-- ClearOptions - set options to default values
-- Inputs: 0) ExifTool object reference
function ExifTool:ClearOptions()
    local opts = { }  -- clear all options
    self.OPTIONS = opts

    -- load default options
    for _, o in ipairs(availableOptions) do opts[o[1]] = o[2] end

    -- enable WindowsLongPath if Win32::API is available
    -- (the port has the wide path handling natively in lexiftool.sys)
    if perl.osname() == 'MSWin32' then opts.WindowsLongPath = 1 end

    -- keep necessary member variables in sync with options
    self.CUR_LANG = nil
    self.ESCAPE_PROC = nil

    -- load user-defined default options
    if ExifTool.UserDefinedOptions and next(ExifTool.UserDefinedOptions) then
        for k, v in pairs(ExifTool.UserDefinedOptions) do
            self:Options(k, v)
        end
    end
end

--------------------------------------------------------------------------------
-- Finish generating tags after extracting information from a file
-- Inputs: 0) ExifTool ref
-- Notes: The sequencing here is a bit tricky because tags from the main file
--        may be used in the names of alternate files, so we finish generating
--        all main file tags first (including all Composite tags which don't
--        rely on alternate files) before extracting tags from alternate files,
--        then we finish by generating the remaingin Composite tags.
function ExifTool:DoneExtract()
    -- generate ImageDataHash if requested
    -- (rawget: the member, not the method of that name)
    if rawget(self, 'ImageDataHash') then
        local digest = rawget(self, 'ImageDataHash'):hexdigest()
        -- (don't store empty digest)
        if not (digest == 'd41d8cd98f00b204e9800998ecf8427e' or
            digest == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' or
            digest == 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e')
        then
            self:FoundTag('ImageDataHash', digest)
        end
    end
    -- generate Validate tag if requested
    if perlTruthy(self.OPTIONS.Validate) then
        require('lexiftool.Validate').FinishValidate(self, self.REQ_TAG_LOOKUP and self.REQ_TAG_LOOKUP.validate)
    end
    -- generate geolocation tags if requested
    if perlTruthy(self.OPTIONS.Geolocation) then
        local arg, defaults, tags, coord, ref, city, doneCity, both
        defaults, tags, coord, ref, city = {}, {}, {}, {}, {}
        for _, a in ipairs(perl.split('\\s*,\\s*', perl.str(self.OPTIONS.Geolocation))) do
            if lc(a) == 'both' then
                both = 1
            elseif a:sub(1, 1) ~= '$' then
                defaults[#defaults + 1] = a
            else
                tags[#tags + 1] = a:sub(2)  -- argument is a tag name
            end
        end
        if #tags == 0 then
            -- default tags to read if not specified
            tags = { 'GPSLatitude', 'GPSLongitude', 'GPSLatitudeRef', 'GPSLongitudeRef',
                     'GPSCoordinates', 'LocationShownGPSLatitude', 'LocationShownGPSLongitude',
                     'XMP:City', 'State', 'CountryCode', 'Country',
                     'IPTC:City', 'Province-State', 'Country-PrimaryLocationCode', 'Country-PrimaryLocationName',
                     'LocationShownCity', 'LocationShownProvinceState', 'LocationShownCountryCode', 'LocationShownCountryName' }
        end
        -- get information for specified tags
        local info = self:GetInfo(tags, { PrintConv = 0, Duplicates = 0 }) -- (returns tags in proper case)
        for _, tag in ipairs(tags) do
            local val = info[tag]
            if val ~= nil then
                self:VPrint(0, 'Found ' .. tag .. ' (' .. perl.str(val) .. ')\n')
                if tag:find('Coordinates') then
                    if not (coord[1] ~= nil and coord[2] ~= nil) then
                        coord = perl.split(' ', perl.str(val))
                    end
                else
                    local n = tag:find('Latitude') and 1 or (tag:find('Longitude') and 2 or nil)
                    if n then
                        if tag:match('Ref$') then
                            if not perlTruthy(ref[n]) then ref[n] = val end
                        else
                            if coord[n] == nil then coord[n] = val end
                        end
                    elseif tag:find('City') then
                        -- handle city tags (save info for first city found)
                        if #city > 0 then
                            doneCity = 1
                        else
                            city[#city + 1] = val
                        end
                    elseif #city > 0 then
                        if not doneCity then city[#city + 1] = val end
                    end
                end
            end
        end
        if coord[1] ~= nil and coord[2] ~= nil then
            if perlTruthy(ref[1]) and perl.num(coord[1], '>') > 0 and ref[1] == 'S' then coord[1] = -perl.num(coord[1]) end
            if perlTruthy(ref[2]) and perl.num(coord[2], '>') > 0 and ref[2] == 'W' then coord[2] = -perl.num(coord[2]) end
            arg = perl.join(',', coord)
        elseif #city > 0 then
            arg = perl.join(',', city)
        end
        if arg == nil then
            -- use specified default values if no tags found
            arg = perl.join(',', defaults)
            if arg == '1' then arg = nil end
            both = 1    -- use 'both' GPS and place names if provided
        end
        if perlTruthy(arg) then
            if both then arg = arg .. ',both' end
            arg = self:Encode(arg, 'UTF8')
            local Geolocation = require('lexiftool.Geolocation')
            if perlTruthy(self.OPTIONS.Verbose) then
                Geolocation.init()
                if Geolocation.dbInfo then
                    io.stdout:write('Loaded ' .. Geolocation.dbInfo .. '\n')
                else
                    io.stdout:write('Error loading Geolocation.dat\n')
                end
            end
            local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
            perl.SIG.__WARN__ = ExifTool.SetWarning
            ExifTool.evalWarning = nil
            self.OPTIONS.GeolocMulti = self.OPTIONS.Duplicates
            self:VPrint(0, "Geolocation arguments: '" .. arg .. "'\n")
            local cities, dist = Geolocation.Geolocate(arg, self.OPTIONS)
            self.OPTIONS.GeolocMulti = nil
            if cities and (#cities < 2 or dist or
                not perlTruthy(self:Warn('Multiple Geolocation cities are possible', 2)))
            then
                if #cities > 1 then
                    self:FoundTag('GeolocationWarning', 'Search matched ' .. #cities .. ' cities')
                end
                for ci, cityNum in ipairs(cities) do
                    if ci > 1 then
                        self.DOC_COUNT = (self.DOC_COUNT or 0) + 1
                        self.DOC_NUM = self.DOC_COUNT
                    end
                    local geo = table.pack(Geolocation.GetEntry(cityNum, self.OPTIONS.Lang))
                    self:FoundTag('GeolocationCity', geo[1])
                    if geo[2] and geo[2] ~= '' then self:FoundTag('GeolocationRegion', geo[2]) end
                    if geo[3] and geo[3] ~= '' then self:FoundTag('GeolocationSubregion', geo[3]) end
                    self:FoundTag('GeolocationCountryCode', geo[4])
                    if geo[5] and geo[5] ~= '' then self:FoundTag('GeolocationCountry', geo[5]) end
                    if geo[6] and geo[6] ~= '' then self:FoundTag('GeolocationTimeZone', geo[6]) end
                    self:FoundTag('GeolocationFeatureCode', geo[7])
                    if geo[11] and geo[11] ~= '' then self:FoundTag('GeolocationFeatureType', geo[11]) end
                    self:FoundTag('GeolocationPopulation', geo[8])
                    self:FoundTag('GeolocationPosition', geo[9] .. ' ' .. geo[10])
                    if dist then
                        self:FoundTag('GeolocationDistance', dist[1][1])
                        self:FoundTag('GeolocationBearing', dist[1][2])
                        table.remove(dist, 1)
                    end
                    if not perlTruthy(self.OPTIONS.Duplicates) then break end
                end
                self.DOC_NUM = nil
            elseif perlTruthy(ExifTool.evalWarning) then
                self:Warn(ExifTool.CleanWarning())
            end
            perl.SIG.__WARN__ = oldWarn
        end
    end
    -- generate tags for user-defined parameters that ended with '#'
    if next(self.OPTIONS.UserParam or {}) then
        local doMsg = self.OPTIONS.Verbose
        local table_ = ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.UserParam')
        local names = {}
        for k in pairs(self.OPTIONS.UserParam) do names[#names + 1] = k end
        tsort(names)
        for _, k in ipairs(names) do
            if perl.isMatch(k, '#$') then
                if perlTruthy(doMsg) then
                    self:VPrint(0, "UserParam tags:\n")
                    doMsg = nil
                end
                self:HandleTag(table_, k, self.OPTIONS.UserParam[k])
            end
        end
    end
    if optOn(self.OPTIONS.Composite) and (not self.OPTIONS.FastScan or self.OPTIONS.FastScan < 5) then
        -- build all composite tags except those requiring tags from alternate files
        self:BuildCompositeTags()
    end
    local g8s = {}
    for g8 in pairs(self.ALT_EXIFTOOL or {}) do g8s[#g8s + 1] = g8 end
    tsort(g8s)
    for _, g8 in ipairs(g8s) do
        local altExifTool = self.ALT_EXIFTOOL[g8]
        if not altExifTool.DID_EXTRACT then -- avoid extracting twice
            altExifTool.OPTIONS = self.OPTIONS
            altExifTool.GLOBAL_TIME_OFFSET = self.GLOBAL_TIME_OFFSET
            local fileName = altExifTool.ALT_FILE
            -- allow tags from the main file to be used in the alternate file names
            -- (eg. -file1 '$originalfilename')
            if fileName:find('%$') then
                fileName = self:InsertTagValues(fileName, nil, 'Warn')
            end
            if fileName then
                -- (upstream sets REQ_TAG_LOOKUP and ReqTagAlreadySet on the
                --  alternate object directly, which its ParseArguments then
                --  leaves alone; this port builds the lookup from the tag list
                --  inside ExtractInfo instead, so it is passed in the same way
                --  the main object gets it -- see setRequestedTags)
                altExifTool.ReqTagAlreadySet = 1
                altExifTool.REQ_TAG_LOOKUP = self.REQ_TAG_LOOKUP
                altExifTool:ExtractInfo(fileName)
                local err = altExifTool.VALUE.Error
                if err then self:Warn(err .. ' "' .. fileName .. '"') end
                -- set family 8 group name for all tags
                for tag in pairs(altExifTool.VALUE) do
                    local ex = altExifTool.TAG_EXTRA[tag]
                    if not ex then ex = {} altExifTool.TAG_EXTRA[tag] = ex end
                    ex.G8 = g8
                end
                -- prepare our sorted list of found tags
                altExifTool.FoundTags = altExifTool:SetFoundTags()
                altExifTool.DID_EXTRACT = 1
            end
        end
    end
    -- if necessary, build composite tags that rely on tags from alternate files
    if self.DoAltComposite then self:BuildCompositeTags(1) end
    -- add numbers to warnings with multiple occurrences
    local tag = 'Warning'
    local i = 1
    while self.VALUE[tag] do
        local n = self.WAS_WARNED[self.VALUE[tag]]
        if n and n > 1 then self.VALUE[tag] = self.VALUE[tag] .. ' [x' .. n .. ']' end
        tag = 'Warning (' .. i .. ')'
        i = i + 1
    end
end

--------------------------------------------------------------------------------
-- Print data in hex
-- Inputs: 0) data
-- Returns: hex string
-- (this is a convenience function for use in debugging PrintConv statements)
function ExifTool.PrintHex(val)
    return perl.join(' ', { perl.unpack(string.rep('H2', perl.length(val)), val) })
end

--------------------------------------------------------------------------------
-- Extract binary data from file
-- 0) ExifTool object reference, 1) offset, 2) length, 3) tag name if conditional
-- Returns: binary data, or undef on error
-- Notes: Returns "Binary data #### bytes" instead of data unless tag is
--        specifically requested or the Binary option is set
function ExifTool.ExtractBinary(self, offset, length, tag)
    local isPreview
    if tag then
        if tag == 'PreviewImage' then
            -- save PreviewImage start/length in case we want to dump trailer
            self.PreviewImageStart = offset
            self.PreviewImageLength = length
            isPreview = 1
        end
        local lcTag = lc(tag)
        local options = self.OPTIONS
        if (not optOn(options.Binary) or (self.EXCL_TAG_LOOKUP and self.EXCL_TAG_LOOKUP[lcTag])) and
            not optOn(options.Verbose) and not optOn(options.Validate) and
            not (self.REQ_TAG_LOOKUP and self.REQ_TAG_LOOKUP[lcTag]) then
            return 'Binary data ' .. length .. ' bytes'
        end
    end
    local raf = self.RAF
    if raf and raf:Seek(offset, 0) then
        local n, data = raf:Read(length)
        if n == length then return data end
    end
    -- (fall through to the error path below)
    if isPreview and not self.BuildingComposite then
        self.PreviewError = 1
    else
        -- (upstream passes $isPreview as the minor flag: a failed preview
        --  read is a [minor] warning, any other failed read is not)
        self:Warn('Error reading ' .. (tag or 'binary data') .. ' from file', isPreview)
    end
    return nil
end

--------------------------------------------------------------------------------
-- File extraction
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Extract meta information from image
-- Inputs: 0) ExifTool object reference
--         1-N) Same as ImageInfo()
-- Returns: 1 if this was a valid image, 0 otherwise
-- Notes: pass an undefined value to avoid parsing arguments
-- Internal 'ReEntry' option allows this routine to be called recursively
function ExifTool:ExtractInfo(file, opts)
    -- internal 'ReEntry' option allows recursive extraction from an
    -- in-memory buffer (e.g. PGF's embedded PNG metadata image), accumulating
    -- into the same self.VALUE rather than starting a fresh extraction
    if opts and opts.ReEntry and type(file) == 'table' and file.ref == 'SCALAR' then
        local saved = {
            RAF = self.RAF,
            PROCESSED = self.PROCESSED,
            EXIF_DATA = self.EXIF_DATA,
            EXIF_POS = self.EXIF_POS,
            FILE_TYPE = self.FILE_TYPE,
        }
        local saveOrder = ExifTool.GetByteOrder()
        local raf = RandomAccess.new(file.value)
        self.RAF = raf
        self.PROCESSED = {}
        self.EXIF_DATA = nil
        self.EXIF_POS = nil
        self:DetectAndProcess(raf, nil)
        self.RAF = saved.RAF
        self.PROCESSED = saved.PROCESSED
        self.EXIF_DATA = saved.EXIF_DATA
        self.EXIF_POS = saved.EXIF_POS
        self.FILE_TYPE = saved.FILE_TYPE
        ExifTool.SetByteOrder(saveOrder)
        return 1
    end
    local options = self.OPTIONS
    if opts then
        for k, v in pairs(opts) do options[k] = v end
    end
    -- ignore all tags and set ExtractEmbedded if outputting CSV directly
    if ExifTool.perlTruthy(self:Options('PrintCSV')) then
        self.OPTIONS.IgnoreTags = { all = 1 }
        self:Options('ExtractEmbedded', 1)
    end
    self:Init()
    self.InExtract = 1
    -- delete maker note byte order before each new extraction (upstream
    -- ExifTool.pm:2776); re-set when a MakerNotes subdirectory is read
    -- (Exif.lua), and transferred to the destination by SetNewValuesFromFile
    -- so a subsequent write's fresh-EXIF byte order follows this file
    self.MAKER_NOTE_BYTE_ORDER = nil
    self:FoundTag('ExifToolVersion', VERSION .. RELEASE)
    -- consume any requested-tag list passed via the options hash (upstream
    -- ParseArguments, run after Init so its member assignments survive)
    if opts and opts.RequestedTags then
        self:setRequestedTags(opts.RequestedTags)
    end
    -- (upstream ParseArguments always leaves a lookup behind, `$$self{
    --  REQ_TAG_LOOKUP} = { } unless $$self{ReqTagAlreadySet}`; here Init has
    --  just removed it when ExtractInfo was called without a tag list)
    if self.REQ_TAG_LOOKUP == nil then self.REQ_TAG_LOOKUP = {} end
    -- add tags from the RequestTags option (upstream ExifTool.pm:5157-5158)
    if self.OPTIONS.RequestTags then
        self.REQ_TAG_LOOKUP = self.REQ_TAG_LOOKUP or {}
        for _, t in ipairs(self.OPTIONS.RequestTags) do self.REQ_TAG_LOOKUP[t] = 1 end
    end
    -- enable Validate option if Validate tag is requested
    -- (upstream ExifTool.pm:2757, in ParseArguments)
    if self.REQ_TAG_LOOKUP and self.REQ_TAG_LOOKUP.validate then self:Options('Validate', 1) end
    local req = self.REQ_TAG_LOOKUP
    local reqAll = options.RequestAll or 0
    local startTime

    -- (upstream ExifTool.pm:2780-2810, right after the ExifToolVersion tag,
    --  which takes no FoundTag in between here)
    if req.now or perlTruthy(reqAll) then self:FoundTag('Now', self:TimeNow()) end
    if req.newguid or perlTruthy(reqAll) then self:FoundTag('NewGUID', ExifTool.NewGUID()) end
    if req.newuuid or perlTruthy(reqAll) then self:FoundTag('NewUUID', ExifTool.NewUUID()) end
    -- generate sequence number if necessary
    if req.filesequence or perlTruthy(reqAll) then self:FoundTag('FileSequence', self.FILE_SEQUENCE) end

    if req.processingtime or perlTruthy(reqAll) then
        local ok, HiRes = perl.evalRequire('Time::HiRes')
        if ok then startTime = HiRes.gettimeofday() end
        if not startTime and req.processingtime then
            self:Warn('Install Time::HiRes to generate ProcessingTime')
        end
    end

    -- create Hash object if ImageDataHash is requested
    -- (rawget: the member shares its name with the ImageDataHash method; the
    --  object is stored through ExifTool.ImageDataHashMember for that reason)
    if req.imagedatahash and not rawget(self, 'ImageDataHash') then
        local imageHashType = self:Options('ImageHashType')
        local isSHA, bits = perl.isMatch(imageHashType, [[(?i)^SHA(256|512)$]])
        if isSHA then
            if ExifTool.hasSHA256(self) then
                self.ImageDataHash = ExifTool.ImageDataHashMember(ExifTool.DigestSHA(tonumber(bits)))
            else
                self:Warn('Install Digest::SHA to calculate image data SHA' .. bits)
            end
        elseif ExifTool.hasMD5(self) then
            self.ImageDataHash = ExifTool.ImageDataHashMember(ExifTool.DigestMD5())
        else
            self:Warn('Install Digest::MD5 to calculate image data MD5')
        end
    end
    self.FILE_SEQUENCE = self.FILE_SEQUENCE + 1   -- count files read

    -- Note: This should be the only tag generated after BuildCompositeTags,
    -- and as such it can't be used in user-defined Composite tags
    -- (port: called where upstream's loop ends, on every way out of it)
    local function foundProcessingTime()
        if startTime then
            self:FoundTag('ProcessingTime', select(2, perl.evalRequire('Time::HiRes')).tv_interval(startTime))
        end
    end

    local filename
    local raf
    if type(file) == 'string' then
        filename = file
    elseif type(file) == 'userdata' then
        raf = RandomAccess.new(file)
    elseif type(file) == 'table' and getmetatable(file) == RandomAccess then
        -- an already-open RandomAccess reader (upstream ParseArguments,
        -- ExifTool.pm:5140 `UNIVERSAL::isa($arg, 'File::RandomAccess')`);
        -- Geotag's LoadTrackLog hands one over to read GPS metadata from a
        -- file it has already sniffed for track-log formats
        raf = file
    elseif type(file) == 'table' and file.ref == 'SCALAR' then
        -- in-memory image data (upstream `\$scalar` reference); reuses the
        -- { ref = 'SCALAR', value = ... } shape already used for binary
        -- placeholder values elsewhere in the port
        raf = RandomAccess.new(file.value)
    end

    local stat, rsize, zid
    if filename then
        stat = perl.stat(filename)
        if stat then
            local dir, name = ExifTool.SplitFileName(filename)
            self:FoundTag('FileName', name)
            if req.basename or
               (perlTruthy(reqAll) and not (self.EXCL_TAG_LOOKUP and self.EXCL_TAG_LOOKUP.basename))
            then
                self:FoundTag('BaseName', perl.matches(name, [[(.*)\.]]) or name)
            end
            if dir and #dir > 0 then self:FoundTag('Directory', dir) end
            if req.filepath or
               (perlTruthy(reqAll) and not (self.EXCL_TAG_LOOKUP and self.EXCL_TAG_LOOKUP.filepath))
            then
                -- (Cwd::abs_path is perl.abs_path; on MSWin32 with the
                --  WindowsLongPath option upstream uses GetFullPathNameW
                --  through Win32::API instead)
                local path
                if perl.osname() == 'MSWin32' and perlTruthy(options.WindowsLongPath) then
                    path = self:WindowsLongPath(filename)
                else
                    path = perl.abs_path(filename)
                end
                if path ~= nil then
                    if perl.osname() == 'MSWin32' then
                        path = perl.tr(path, [[\\]], '/') -- return forward slashes
                    end
                    self:FoundTag('FilePath', path)
                elseif req.filepath then
                    self:Warn('The Perl Cwd module must be installed to use FilePath')
                end
            end
            -- get size of resource fork on Mac OS
            if perl.osname() == 'darwin' and not self.IN_RESOURCE then rsize = perl.filetest('s', filename .. '/..namedfork/rsrc') end
            -- check to see if Zone.Identifier file exists in Windows
            -- (Win32API::File is lexiftool.sys here, always present)
            if perl.osname() == 'MSWin32' then
                local wattr, wide
                local zfile = filename .. ':Zone.Identifier'
                wide, zfile = self:EncodeFileName(zfile)
                if perlTruthy(wide) then
                    wattr = sys.get_file_attributes(zfile)
                else
                    -- (port: GetFileAttributes is the same lexiftool.sys call,
                    --  which widens the name itself)
                    wattr = sys.get_file_attributes(zfile)
                end
                if wattr ~= nil then zid = 1 end    -- (nil: INVALID_FILE_ATTRIBUTES)
            end
        end
    end

    if not raf and filename then
        -- open the file
        local fh = self:Open(filename)
        if fh then
            -- create random access file object
            raf = RandomAccess.new(fh)
            raf.OWNED = true
            -- patch to force pipe to be buffered because seek returns success
            -- in Windows cmd shell pipe even though it really failed
            if filename == '-' or perl.isMatch(filename, [[\|$]]) then raf.TESTED = -1 end
        end
    end

    if not raf then
        self:Error('Error opening file')
        self:DoneExtract()
        foundProcessingTime()
        self.InExtract = nil
        return 0
    end
    self.RAF = raf -- (used by ExtractBinary, e.g. for MPF PreviewImage)

    -- extract file tags
    if stat then
        -- hack to patch Windows daylight savings time bug
        if stat.mode == 'file' and raf.FILE_PT and perl.osname() == 'MSWin32' then
            stat.atime, stat.mtime, stat.ctime = self:GetFileTime(raf.FILE_PT)
        end
        if stat.size then self:FoundTag('FileSize', stat.size) end
        if rsize then self:FoundTag('ResourceForkSize', rsize) end
        if zid then self:FoundTag('ZoneIdentifier', 'Exists') end
        if stat.mtime then self:FoundTag('FileModifyDate', stat.mtime) end
        if stat.atime then self:FoundTag('FileAccessDate', stat.atime) end
        local cTag = perl.osname() == 'MSWin32' and 'FileCreateDate' or 'FileInodeChangeDate'
        if stat.ctime then self:FoundTag(cTag, stat.ctime) end
        -- (upstream needs the optional File::StatX module here; lexiftool.sys
        --  provides statx() natively on Linux)
        if perl.osname() == 'linux' and sys.get_btime and filename then
            local btime = sys.get_btime(filename)
            if btime then self:FoundTag('FileCreateDate', btime) end
        end
        if stat.modeNum then
            self:FoundTag('FilePermissions', stat.modeNum)
        end
        -- extract more system info if SystemTags option is set
        local sysTags = perlTruthy(options.SystemTags) or (perlTruthy(reqAll) and options.SystemTags == nil)
        if sysTags or req.fileattributes then
            local attr = { stat.modeNum & 0xf000, stat.modeNum & 0x0e00 }
            -- add Windows file attributes if available (upstream: only with
            -- Win32API::File, here through lexiftool.sys)
            if perl.osname() == 'MSWin32' and filename ~= nil and filename ~= '' and filename ~= '-' then
                local wattr, wide
                local file = filename -- luacheck: ignore 422
                wide, file = self:EncodeFileName(file)
                if perlTruthy(wide) then
                    wattr = sys.get_file_attributes(file)
                else
                    -- (port: GetFileAttributes is the same lexiftool.sys call,
                    --  which widens the name itself)
                    wattr = sys.get_file_attributes(file)
                end
                if wattr ~= nil and wattr ~= 0xffffffff then perl.push(attr, wattr) end
            end
            self:FoundTag('FileAttributes', perl.join(' ', attr))
        end
        if sysTags or req.filedevicenumber then self:FoundTag('FileDeviceNumber', stat.dev) end
        if sysTags or req.fileinodenumber then self:FoundTag('FileInodeNumber', stat.ino) end
        if sysTags or req.filehardlinks then self:FoundTag('FileHardLinks', stat.nlink) end
        if sysTags or req.fileuserid then self:FoundTag('FileUserID', stat.uid) end
        if sysTags or req.filegroupid then self:FoundTag('FileGroupID', stat.gid) end
        if sysTags or req.filedeviceid then self:FoundTag('FileDeviceID', stat.rdev) end
        if sysTags or req.fileblocksize then self:FoundTag('FileBlockSize', stat.blksize) end
        if sysTags or req.fileblockcount then self:FoundTag('FileBlockCount', stat.blocks) end
        -- extract MDItem tags if requested (only on plain files; this
        -- port's stat branch above already covers upstream's $plainFile
        -- case, a real on-disk file stat succeeded for)
        if perl.osname() == 'darwin' and filename and filename ~= '' then
            local reqMacOS = perl.num(reqAll) > 1 or req['macos:']
            local crDate = reqMacOS or req.filecreatedate
            local mdItem = reqMacOS or options.MDItemTags
            local xattr = reqMacOS or options.XAttrTags
            if not mdItem then
                for k in pairs(req) do
                    if k:sub(1, 6) == 'mditem' then mdItem = true break end
                end
            end
            if not xattr then
                for k in pairs(req) do
                    if k:sub(1, 5) == 'xattr' then xattr = true break end
                end
            end
            if crDate or mdItem or xattr then
                local MacOS = require('lexiftool.MacOS')
                if crDate then MacOS.GetFileCreateDate(self, filename) end
                if mdItem then MacOS.ExtractMDItemTags(self, filename) end
                if xattr then MacOS.ExtractXAttrTags(self, filename) end
            end
        end
    elseif raf.FILE_PT then
        -- file handle: size via seek; date/permission values are OS-dependent
        -- pseudo-tags that the harness tolerance ignores (see TestLib nearEnough)
        local size = raf:Length()
        self:FoundTag('FileSize', size)
        local now = os.time()
        self:FoundTag('FileModifyDate', now)
        self:FoundTag('FileAccessDate', now)
        self:FoundTag('FileInodeChangeDate', now)
        self:FoundTag('FilePermissions', 0x81a4)  -- 0100644, a plain rw-r--r-- file
        raf:Seek(0, 0)
    else
        -- in-memory buffer (upstream: RAF with no FILE_PT gets only FileSize)
        self:FoundTag('FileSize', raf:Length())
    end

    -- do whatever else we can with directories, then return
    if stat and stat.mode == 'directory' then
        self:FoundTag('FileType', 'DIR')
        self:FoundTag('FileTypeExtension', '')
        self:DoneExtract()
        if raf.OWNED then raf:Close() end
        foundProcessingTime()
        self.InExtract = nil
        return 1
    end

    -- detect the file type and process the file
    self:DetectAndProcess(raf, filename)

    -- extract binary EXIF data block only if requested (ExifTool.pm:3147-3154)
    -- (EXCL_TAG_LOOKUP is read nil-safe: Perl autovivifies it on the read)
    if self.EXIF_DATA ~= nil and #self.EXIF_DATA > 16 and
        (self.REQ_TAG_LOOKUP.exif or
        -- (not extracted normally, so check TAGS_FROM_FILE)
        (self.TAGS_FROM_FILE and not (self.EXCL_TAG_LOOKUP and self.EXCL_TAG_LOOKUP.exif)))
    then
        self:FoundTag('EXIF', self.EXIF_DATA)
    end

    self.PATH = {} -- reset PATH
    self:DoneExtract()
    -- do our HTML dump if requested (upstream ExifTool.pm:3157-3170). For
    -- most files HDump() offsets are absolute file positions, so passing
    -- dataPt=nil and letting Print() always re-read blocks via raf gives the
    -- identical bytes. That breaks down for a nested in-memory TIFF whose
    -- HDump offsets are relative to its own buffer, not the file (e.g.
    -- Photoshop's embedded EXIFInfo IRB resource, processed via ProcessTIFF
    -- from a DataPt slice with Base=0) -- for that case upstream instead
    -- feeds Print() the tracked EXIF_DATA buffer at EXIF_POS, so addresses
    -- inside it resolve against the buffer, not raw file bytes at that
    -- literal offset. ExtendedEXIF (multi-segment EXIF) isn't ported, so
    -- that extra guard is omitted (equivalent to it always being false).
    if self.HTML_DUMP then
        raf:Seek(0, 2) -- seek to end of file
        self.HTML_DUMP:FinishTiffDump(self, raf:Tell())
        local pos = self.OPTIONS.HtmlDumpBase
        if pos == nil then pos = self.FIRST_EXIF_POS or 0 end
        local dataPt = self.EXIF_DATA
        if self.EXIF_POS ~= nil and pos ~= self.EXIF_POS then dataPt = nil end
        local title = filename and ('HTML Dump (' .. filename .. ')') or 'HTML Dump'
        local success = self.HTML_DUMP:Print(raf, dataPt, pos, self.OPTIONS.TextOut,
            self.OPTIONS.HtmlDump, title)
        if success < 0 then
            self:Warn('Error reading ' .. perl.str(self.HTML_DUMP.ERROR))
        end
    end
    if raf.OWNED then raf:Close() end
    foundProcessingTime()
    -- call cleanup routines if necessary (upstream does this at the very end of
    -- ExtractInfo, after the warning de-duplication -- so a warning issued from
    -- a cleanup routine is appended last, as it is here)
    if self.Cleanup then
        for _, sub in ipairs(self.Cleanup) do sub(self) end
        self.Cleanup = nil
    end
    self.InExtract = nil
    return 1
end

-- Detect the file type for the given RAF and dispatch to the matching
-- ProcessXxx (factored out of ExtractInfo so the ReEntry path above can
-- reuse it without re-running Init()/file-tag extraction/DoneExtract)
function ExifTool:DetectAndProcess(raf, filename)
    -- initialize the input file for seeking in binary data
    raf:BinMode()       -- set binary mode before we start reading
    local fileType = self:DetectFileType(raf, filename)
    if not fileType then
        -- if we were given a single image with a known type there
        -- must be a format error since we couldn't read it, otherwise
        -- it is likely we don't support images of this type
        -- (upstream ExtractInfo; $buff is the first 1024 bytes of the file)
        local err
        raf:Seek(0, 0)
        local _, buff = raf:Read(1024)
        local ftype = filename and ExifTool.GetFileType(filename) or ''
        if not perl.truthy(ftype) then ftype = '' end
        if #buff == 0 then
            err = 'File is empty'
        else
            local ch = substr(buff, 0, 1)
            if #buff < 16 or perl.isMatchDyn(buff, '[^' .. perl.quotemeta(ch) .. ']') then
                if ftype == 'RAW' then
                    err = 'Unsupported RAW file type'
                elseif ftype ~= '' then
                    err = 'File format error'
                else
                    err = 'Unknown file type'
                end
            else
                -- provide some insight into the content of some corrupted files
                if perl.truthy(self.OPTIONS.FastScan) then
                    err = 'File header is all'
                else
                    local num = 0
                    raf:Seek(0, 0)
                    while true do
                        local n
                        n, buff = raf:Read(65536)
                        if n == 0 then num = nil break end
                        -- (`$buff =~ /[^\Q$ch\E]/g and $num += pos($buff) - 1`)
                        local at = buff:find('[^' .. ch:gsub('[^A-Za-z0-9]', '%%%0') .. ']')
                        if at then num = num + at - 1 break end
                        num = num + #buff
                    end
                    if perl.truthy(num) then
                        err = 'First ' .. ExifTool.ConvertFileSize(num) .. ' of file is'
                    else
                        err = 'Entire file is'
                    end
                end
                if ch == "\0" then
                    err = err .. ' binary zeros'
                elseif ch == ' ' then
                    err = err .. ' ASCII spaces'
                elseif perl.isMatch(ch, '[a-zA-Z0-9]') then
                    err = err .. " ASCII '" .. ch .. "' characters"
                else
                    err = err .. sprintf(" binary 0x%.2x's", perl.ord(ch))
                end
            end
        end
        self:Error(err)
    else
        self.FILE_TYPE = fileType
        -- (upstream derives FILE_EXT from the file NAME in ParseArguments, so
        --  a ReEntry call on an in-memory buffer keeps the container's
        --  extension -- don't overwrite it when there is no name)
        if filename then
            self.FILE_EXT = ExifTool.GetFileExtension(filename)
        elseif self.FILE_EXT == nil then
            self.FILE_EXT = fileType
        end
        -- upstream: `$dirInfo{Parent} = ($type eq 'TIFF') ? $tiffType : $type`,
        -- where $tiffType is the FILE EXTENSION whenever the name gave any type
        -- candidate at all. ProcessTIFF copies Parent into TIFF_TYPE, so a
        -- TIFF-signature file is remembered by its extension (CR2, NEF, IIQ,
        -- EIP, ...) rather than as plain 'TIFF' -- which is what Composite
        -- tags like Exif:ImageSize test (`TIFF_TYPE =~ /^(CR2|...|IIQ|EIP)$/`).
        -- It matters most for an embedded file read through the ReEntry path,
        -- where the extension is still that of the CONTAINER: the IIQ inside a
        -- CaptureOne .eip is seen as TIFF_TYPE 'EIP'.
        local tiffType = self.FILE_EXT or 'TIFF'
        -- (upstream's %dirInfo carries TestBuff, the first $testLen bytes the
        --  file type tests read; ProcessTXT starts from it)
        local pos = raf:Tell()
        local _, testBuff = raf:Read(ExifTool.testLen)
        raf:Seek(pos, 0)
        local dirInfo = { RAF = raf, Base = 0, TestBuff = testBuff,
                          Parent = (fileType == 'TIFF') and tiffType or fileType }
        self.PATH[#self.PATH + 1] = fileType -- save file type in metadata PATH
        if fileType == 'TIFF' then
            -- RW2 (upstream %fileTypeLookup: RW2 => ['TIFF', ...], identifier
            -- 0x55 instead of the plain-TIFF 0x2a) -- Panasonic/Leica RAW's
            -- own IFD0 tag table (Image::ExifTool::PanasonicRaw::Main) is
            -- passed explicitly instead of the default Exif::Main, mirroring
            -- upstream's `$tagTablePtr = GetTagTable('...PanasonicRaw::Main')`
            -- in the identifier==0x55 branch; this port uses the file
            -- extension rather than the magic-number/offset probe to decide
            -- RW2 vs. plain RAW/RWL, sufficient for the read subset (same
            -- extension-based simplification as NEF below). Parent is set to
            -- 'RW2' (matching upstream's `$fileType = 'RW2'` reassignment
            -- before DoProcessTIFF) so ProcessTIFF's own SetFileType call and
            -- TIFF_TYPE (used by RawDataOffset's IsOffset condition) see
            -- 'RW2' directly; self.FILE_TYPE (set above from DetectFileType)
            -- stays 'TIFF', matching upstream's $$self{FILE_TYPE}.
            if self.FILE_EXT == 'RW2' then
                self:ProcessTIFF({ RAF = raf, Base = 0, Parent = 'RW2' },
                    self:GetTagTable('lexiftool.PanasonicRaw.Main'))
            else
                self:ProcessTIFF(dirInfo)
                -- NEF (upstream %fileTypeLookup: NEF => ['TIFF', ...]) -- a
                -- TIFF-signature file read with the TIFF reader (self.FILE_TYPE
                -- stays 'TIFF', matching upstream's $$self{FILE_TYPE}, so
                -- format-keyed logic like IPTC's IsStandardIPTC path-matching
                -- keeps working), but reported under its own FileType/MIMEType
                -- via OverrideFileType (upstream picks this up from the
                -- Make/Model or NEFLinearizationTable; this port uses the file
                -- extension, sufficient for the read subset). Other TIFF-based
                -- RAW extensions (CR2, ARW, ORF, ...) are out of scope until a
                -- test needs them.
                if self.FILE_EXT == 'NEF' then
                    self:OverrideFileType('NEF', 'image/x-nikon-nef')
                -- IIQ (upstream %fileTypeLookup: IIQ => ['TIFF', ...]) --
                -- Phase One's own maker-note-dispatch check (`$count >
                -- 1000000` in the MakerNotePhaseOne Condition) is the
                -- upstream trigger for the IIQ FileType override; this port
                -- uses the file extension, sufficient for the read subset
                -- (same extension-based simplification as NEF)
                elseif self.FILE_EXT == 'IIQ' then
                    self:OverrideFileType('IIQ', 'image/x-raw')
                -- DNG (upstream %fileTypeLookup: DNG => ['TIFF', ...]) --
                -- upstream detects DNG by the DNGVersion tag after reading
                -- IFD0 (`if $$self{DNGVersion} and $$self{FILE_TYPE} eq
                -- 'TIFF' ... OverrideFileType('DNG')`); this port checks the
                -- DNGVersion value instead of the extension, since a .dng
                -- file is a normal TIFF-signature file
                elseif self.DNGVersion then
                    self:OverrideFileType('DNG', 'image/x-adobe-dng')
                end
            end
        elseif fileType == 'JPEG' then
            self:ProcessJPEG(dirInfo)
        elseif fileType == 'EXV' then
            self:ProcessEXV(dirInfo)
        elseif fileType == 'EXIF' then
            self:ProcessEXIF(dirInfo)
        elseif fileType == 'PNG' then
            loadModule('PNG').ProcessPNG(self, dirInfo)
        elseif fileType == 'BMP' then
            loadModule('BMP').ProcessBMP(self, dirInfo)
        elseif fileType == 'GIF' then
            loadModule('GIF').ProcessGIF(self, dirInfo)
        elseif fileType == 'AAC' then
            loadModule('AAC').ProcessAAC(self, dirInfo)
        elseif fileType == 'AA' then
            loadModule('Audible').ProcessAA(self, dirInfo)
        elseif fileType == 'APE' then
            loadModule('APE').ProcessAPE(self, dirInfo)
        elseif fileType == 'ASF' then
            loadModule('ASF').ProcessASF(self, dirInfo)
        elseif fileType == 'WV' then
            loadModule('WavPack').ProcessWV(self, dirInfo)
        elseif fileType == 'RIFF' then
            loadModule('RIFF').ProcessRIFF(self, dirInfo)
        elseif fileType == 'WTV' then
            loadModule('WTV').ProcessWTV(self, dirInfo)
        elseif fileType == 'R3D' then
            loadModule('Red').ProcessR3D(self, dirInfo)
        elseif fileType == 'MRC' then
            loadModule('MRC').ProcessMRC(self, dirInfo)
        elseif fileType == 'MOI' then
            loadModule('MOI').ProcessMOI(self, dirInfo)
        elseif fileType == 'ICO' then
            loadModule('ICO').ProcessICO(self, dirInfo)
        elseif fileType == 'PCX' then
            loadModule('PCX').ProcessPCX(self, dirInfo)
        elseif fileType == 'HDR' then
            loadModule('Radiance').ProcessHDR(self, dirInfo)
        elseif fileType == 'PPM' then
            loadModule('PPM').ProcessPPM(self, dirInfo)
        elseif fileType == 'DSF' then
            loadModule('DSF').ProcessDSF(self, dirInfo)
        elseif fileType == 'FLAC' then
            loadModule('FLAC').ProcessFLAC(self, dirInfo)
        elseif fileType == 'OGG' then
            loadModule('Ogg').ProcessOGG(self, dirInfo)
        elseif fileType == 'MP3' then
            -- (ID3-prefixed audio files: the ID3 module processes the
            --  ID3v2 header, then the following audio data and ID3v1
            --  trailer -- upstream %moduleName maps MP3 => ID3)
            loadModule('ID3').ProcessMP3(self, dirInfo)
        elseif fileType == 'MPEG' then
            loadModule('MPEG').ProcessMPEG(self, dirInfo)
        elseif fileType == 'JP2' then
            loadModule('Jpeg2000').ProcessJP2(self, dirInfo)
        elseif fileType == 'EXR' then
            loadModule('OpenEXR').ProcessEXR(self, dirInfo)
        elseif fileType == 'RTF' then
            loadModule('RTF').ProcessRTF(self, dirInfo)
        elseif fileType == 'PSP' then
            loadModule('PSP').ProcessPSP(self, dirInfo)
        elseif fileType == 'VCard' then
            loadModule('VCard').ProcessVCard(self, dirInfo)
        elseif fileType == 'TNEF' then
            loadModule('TNEF').ProcessTNEF(self, dirInfo)
        elseif fileType == 'PFM' then
            loadModule('Other').ProcessPFM2(self, dirInfo)
        elseif fileType == 'WPG' then
            loadModule('WPG').ProcessWPG(self, dirInfo)
        elseif fileType == 'ITC' then
            loadModule('ITC').ProcessITC(self, dirInfo)
        elseif fileType == 'DPX' then
            loadModule('DPX').ProcessDPX(self, dirInfo)
        elseif fileType == 'DV' then
            loadModule('DV').ProcessDV(self, dirInfo)
        elseif fileType == 'Torrent' then
            loadModule('Torrent').ProcessTorrent(self, dirInfo)
        elseif fileType == 'PDB' then
            loadModule('Palm').ProcessPDB(self, dirInfo)
        elseif fileType == 'PCD' then
            loadModule('PhotoCD').ProcessPCD(self, dirInfo)
        elseif fileType == 'Real' then
            loadModule('Real').ProcessReal(self, dirInfo)
        elseif fileType == 'CZI' then
            loadModule('ZISRAW').ProcessCZI(self, dirInfo)
        elseif fileType == 'XCF' then
            loadModule('GIMP').ProcessXCF(self, dirInfo)
        elseif fileType == 'MacOS' then
            loadModule('MacOS').ProcessMacOS(self, dirInfo)
        elseif fileType == 'PS' then
            loadModule('PostScript').ProcessPS(self, dirInfo)
        elseif fileType == 'AIFF' then
            loadModule('AIFF').ProcessAIFF(self, dirInfo)
        elseif fileType == 'BPG' then
            loadModule('BPG').ProcessBPG(self, dirInfo)
        elseif fileType == 'FITS' then
            loadModule('FITS').ProcessFITS(self, dirInfo)
        elseif fileType == 'FIT' then
            loadModule('Garmin').ProcessFIT(self, dirInfo)
        elseif fileType == 'PGF' then
            loadModule('PGF').ProcessPGF(self, dirInfo)
        elseif fileType == 'FLIF' then
            loadModule('FLIF').ProcessFLIF(self, dirInfo)
        elseif fileType == 'LIF' then
            loadModule('LIF').ProcessLIF(self, dirInfo)
        elseif fileType == 'RWZ' then
            loadModule('Rawzor').ProcessRWZ(self, dirInfo)
        elseif fileType == 'RSRC' then
            loadModule('RSRC').ProcessRSRC(self, dirInfo)
        elseif fileType == 'FONT' or fileType == 'Font' then
            loadModule('Font').ProcessFont(self, dirInfo)
        elseif fileType == 'EXE' then
            loadModule('EXE').ProcessEXE(self, dirInfo)
        elseif fileType == 'CHM' then
            loadModule('EXE').ProcessCHM(self, dirInfo)
        elseif fileType == 'MOV' then
            loadModule('QuickTime').ProcessMOV(self, dirInfo)
        elseif fileType == 'MKV' then
            loadModule('Matroska').ProcessMKV(self, dirInfo)
        elseif fileType == 'M2TS' then
            loadModule('M2TS').ProcessM2TS(self, dirInfo)
        elseif fileType == 'MXF' then
            loadModule('MXF').ProcessMXF(self, dirInfo)
        elseif fileType == 'IND' then
            loadModule('InDesign').ProcessIND(self, dirInfo)
        elseif fileType == 'FPX' then
            loadModule('FlashPix').ProcessFPX(self, dirInfo)
        elseif fileType == 'DICOM' then
            loadModule('DICOM').ProcessDICOM(self, dirInfo)
        elseif fileType == 'JXL' then
            loadModule('Jpeg2000').ProcessJXL(self, dirInfo)
        elseif fileType == 'JUMBF' then
            loadModule('Jpeg2000').ProcessJUMBF(self, dirInfo)
        elseif fileType == 'FPF' then
            loadModule('FLIR').ProcessFPF(self, dirInfo)
        elseif fileType == 'XISF' then
            loadModule('XISF').ProcessXISF(self, dirInfo)
        elseif fileType == 'ISO' then
            loadModule('ISO').ProcessISO(self, dirInfo)
        elseif fileType == 'LFP' then
            loadModule('Lytro').ProcessLFP(self, dirInfo)
        elseif fileType == 'MIFF' then
            loadModule('MIFF').ProcessMIFF(self, dirInfo)
        elseif fileType == 'PCAP' then
            loadModule('PCAP').ProcessPCAP(self, dirInfo)
        elseif fileType == 'PLIST' then
            loadModule('PLIST').ProcessPLIST(self, dirInfo)
        elseif fileType == 'VRD' then
            loadModule('CanonVRD').ProcessVRD(self, dirInfo)
        elseif fileType == 'CRW' then
            loadModule('CanonRaw').ProcessCRW(self, dirInfo)
        elseif fileType == 'PMP' then
            loadModule('Sony').ProcessPMP(self, dirInfo)
        elseif fileType == 'NKA' then
            loadModule('Nikon').ProcessNKA(self, dirInfo)
        elseif fileType == 'RAF' then
            loadModule('FujiFilm').ProcessRAF(self, dirInfo)
        elseif fileType == 'RAW' then
            loadModule('KyoceraRaw').ProcessRAW(self, dirInfo)
        elseif fileType == 'X3F' then
            loadModule('SigmaRaw').ProcessX3F(self, dirInfo)
        elseif fileType == 'TXT' then
            loadModule('Text').ProcessTXT(self, dirInfo)
        elseif fileType == 'PICT' then
            loadModule('PICT').ProcessPICT(self, dirInfo)
        elseif fileType == 'DSS' then
            loadModule('Olympus').ProcessDSS(self, dirInfo)
        elseif fileType == 'SWF' then
            loadModule('Flash').ProcessSWF(self, dirInfo)
        elseif fileType == 'FLV' then
            loadModule('Flash').ProcessFLV(self, dirInfo)
        elseif fileType == 'MRW' then
            loadModule('MinoltaRaw').ProcessMRW(self, dirInfo)
        elseif fileType == 'DR4' then
            loadModule('CanonVRD').ProcessDR4(self, dirInfo)
        elseif fileType == 'XMP' then
            loadModule('XMP').ProcessXMP(self, dirInfo)
        elseif fileType == 'COS' then
            loadModule('CaptureOne').ProcessCOS(self, dirInfo)
        elseif fileType == 'JSON' then
            loadModule('JSON').ProcessJSON(self, dirInfo)
        elseif fileType == 'KVAR' then
            loadModule('Kandao').ProcessKVAR(self, dirInfo)
        elseif fileType == 'HTML' then
            loadModule('HTML').ProcessHTML(self, dirInfo)
        elseif fileType == 'URL' or fileType == 'LNK' then
            loadModule('LNK').ProcessLNK(self, dirInfo)
        elseif fileType == 'MIE' then
            loadModule('MIE').ProcessMIE(self, dirInfo)
        elseif fileType == 'ICC' then
            loadModule('ICC_Profile').ProcessICC(self, dirInfo)
        elseif fileType == 'PSD' then
            loadModule('Photoshop').ProcessPSD(self, dirInfo)
        elseif fileType == 'ZIP' then
            loadModule('ZIP').ProcessZIP(self, dirInfo)
        elseif fileType == 'GZIP' then
            loadModule('ZIP').ProcessGZIP(self, dirInfo)
        elseif fileType == 'RAR' then
            loadModule('ZIP').ProcessRAR(self, dirInfo)
        elseif fileType == '7Z' then
            loadModule('7Z').Process7Z(self, dirInfo)
        elseif fileType == 'PDF' then
            loadModule('PDF').ProcessPDF(self, dirInfo)
        end
        self.PATH[#self.PATH] = nil
    end
end

-- TXT/CSV weak-signature test (upstream %magicNumber's TXT entry): a UTF-16/
-- UTF-32 BOM prefix, or an entirely printable-range/high-byte body,
-- optionally after a UTF-8 BOM. Matches almost any non-binary file, so it's
-- tried last for an unrecognized extension, but first (ahead of stronger
-- signatures it could otherwise collide with, e.g. PLIST's UTF-16 'bplist'-
-- adjacent check) when the extension itself is already TXT/CSV -- matching
-- upstream's extension-recognized types being tried before the generic
-- scan-all-types fallback order.
local function isWeakText(buff)
    if #buff == 0 then return false end
    if buff:sub(1, 2) == '\255\254' or buff:sub(1, 2) == '\254\255' or
        buff:sub(1, 4) == '\0\0\254\255' then
        return true
    end
    local body = buff
    if body:sub(1, 3) == '\239\187\191' then body = body:sub(4) end
    return not body:find('[^\7-\13\32-\126\128-\254]')
end

-- XMP/XML weak-signature test (upstream %magicNumber's XMP entry
-- `\0{0,3}(\xfe\xff|\xff\xfe|\xef\xbb\xbf)?\0{0,3}\s*<`): optional leading
-- NULs, an optional UTF-16/32/8 BOM, more optional NULs, then whitespace and
-- '<'.  Tested before PLIST's own '<'-led alternatives, matching upstream
-- @fileTypes order (XMP before PLIST); ProcessXMP disambiguates the actual
-- file type (XMP/INX/SVG/XML/PLIST) by content, so this also catches genuine
-- PLIST files.
local function isXMLMagic(buff)
    local i = 1
    while i <= 3 and buff:sub(i, i) == '\0' do i = i + 1 end
    local bom = buff:sub(i, i + 1) == '\254\255' or buff:sub(i, i + 1) == '\255\254'
    local bom3 = buff:sub(i, i + 2) == '\239\187\191'
    i = i + (bom and 2 or (bom3 and 3 or 0))
    local j = i
    while j - i < 3 and buff:sub(j, j) == '\0' do j = j + 1 end
    return buff:sub(j):match('^[ \t\n\r\f\v]*<') ~= nil
end

-- Detect the file type for a file name or random access handle.
-- Returns: file type string, or nil if unknown
function ExifTool.DetectFileType(_self, raf, filename)
    if filename then
        local ext = ExifTool.GetFileExtension(filename)
        if ext == 'TIFF' or ext == 'JPEG' then return ext end
        -- ISO 9660 has no reliable signature at offset 0 (its "CD001"
        -- signature is at byte 32768); upstream has no %magicNumber entry
        -- for it either, relying on the extension plus ProcessISO's own
        -- internal validation (which returns 0 for a non-ISO .iso file)
        if ext == 'ISO' then return 'ISO' end
        -- PCD (Kodak Photo CD): its `PCD_IPI` signature is at byte 2048,
        -- so upstream has no %magicNumber entry and relies on the extension
        -- plus ProcessPCD's own internal validation (same as ISO)
        if ext == 'PCD' then return 'PCD' end
        -- PDF: upstream has no %magicNumber entry for it either (PDF.pm's
        -- own ReadPDF validates the `%PDF-x.y` header itself, returning 0
        -- if not found); relies on the extension, same as ISO/PCD above
        if ext == 'PDF' then return 'PDF' end
        -- COS (Capture One Settings): XML, so upstream has no %magicNumber
        -- entry for it either -- the extension-derived type dispatches to
        -- %moduleName{COS} = 'CaptureOne', whose ProcessCOS then hands the
        -- file to XMP.ProcessXMP with its own AttrProc/FoundProc hooks
        if ext == 'COS' then return 'COS' end
        -- EXE family (Windows PE / Mach-O / ELF / static libraries): upstream
        -- has no %magicNumber entries for these either -- the extension-derived
        -- type dispatches straight to EXE.ProcessEXE, which validates the real
        -- signature itself (MZ/PE, Mach-O magics, \x7fELF, !<arch>) and falls
        -- back through DOS-EXE-style type strings for anything else
        if ext == 'EXE' or ext == 'DLL' or ext == 'DYLIB' or ext == 'SO'
            or ext == 'A' or ext == 'O' then
            return 'EXE'
        end
        -- QuickTime/MP4 family: upstream has no %magicNumber entry either; the
        -- extension-derived type (fileTypeLookup maps .mov/.m4a/.mp4/... to
        -- 'MOV') dispatches to QuickTime.ProcessMOV, which validates the 'ftyp'
        -- atom and overrides the display FileType via SetFileType.
        if ExifTool.GetFileType(filename) == 'MOV' then
            return 'MOV'
        end
        if ext == 'TXT' or ext == 'CSV' then
            raf:Seek(0, 0)
            local _, extBuff = raf:Read(1024)
            raf:Seek(0, 0)
            if isWeakText(extBuff) then return 'TXT' end
        end
        -- FPX-family (Windows Compound Binary): no %magicNumber entry
        -- upstream either; the extension routes to ProcessFPX, which
        -- validates the OLE header signature itself. The display FileType
        -- comes from the extension via SetFileType inside ProcessFPX.
        if ext == 'PPT' or ext == 'DOC' or ext == 'XLS' or ext == 'DOT'
            or ext == 'POT' or ext == 'PPS' or ext == 'THM' or ext == 'THMX'
            or ext == 'XLA' or ext == 'XLT' or ext == 'VSD' or ext == 'FLA'
            or ext == 'PPTX' or ext == 'PPTM' or ext == 'PPSX' or ext == 'PPSM'
            or ext == 'DOCX' or ext == 'DOCM' or ext == 'DOTX' or ext == 'DOTM'
            or ext == 'XLSX' or ext == 'XLSM' or ext == 'XLSB'
            or ext == 'XLTX' or ext == 'XLTM' or ext == 'XLAM' then
            raf:Seek(0, 0)
            local _, extBuff = raf:Read(8)
            raf:Seek(0, 0)
            if extBuff == '\208\207\17\224\161\177\26\225' then
                return 'FPX'
            end
        end
        -- IND/INDD/INDT (Adobe InDesign; no %magicNumber entry upstream --
        -- ProcessIND validates the master-page GUID itself)
        if ext == 'IND' or ext == 'INDD' or ext == 'INDT' then
            raf:Seek(0, 0)
            local _, extBuff = raf:Read(16)
            raf:Seek(0, 0)
            if extBuff == '\6\6\237\245\216\29\70\229\189\49\239\231\254\116\183\29' then
                return 'IND'
            end
        end
    end
    raf:Seek(0, 0)
    local n, buff = raf:Read(256)
    raf:Seek(0, 0)
    -- PDF: upstream has no %magicNumber entry either and reaches ProcessPDF
    -- from the extension, or -- when there is no filename, as when WritePDF
    -- re-reads the file from a buffer -- by falling through its
    -- try-each-candidate dispatch loop. This port has no such loop, so it
    -- routes the unambiguous "%PDF-" header directly (ReadPDF re-validates
    -- it, and tolerates leading whitespace the same way)
    if buff:match('^[ \t\n\r\f\v]*%%PDF%-%d+%.%d+') then return 'PDF' end
    -- CHM (Microsoft Compiled HTML) and PEF (classic MacOS executable, one
    -- alternative of upstream's EXE magicNumber): distinctive signatures,
    -- routed to EXE.ProcessCHM / EXE.ProcessEXE
    if perl.isMatch(buff, [==[(?s)^ITSF.{20}\x10\xfd\x01\x7c\xaa\x7b\xd0\x11\x9e\x0c\0\xa0\xc9\x22\xe6\xec]==]) then return 'CHM' end
    if perl.isMatch(buff, '^Joy!peff') then return 'EXE' end
    -- Kyocera Contax N Digital RAW: 'ARECOYK' ("KYOCERA" reversed) at byte
    -- offset 25 -- upstream's magicNumber `(.{25}ARECOYK|II|MM)` for the
    -- ambiguous '.raw' extension (also used by plain-TIFF-based Panasonic
    -- RAW, handled by the generic TIFF signature check below); gated on the
    -- extension since this 7-byte signature isn't distinctive enough to
    -- probe unconditionally
    local ext = filename and ExifTool.GetFileExtension(filename)
    if ext == 'RAW' and n >= 32 and buff:sub(26, 32) == 'ARECOYK' then
        return 'RAW'
    end
    -- DFONT (Macintosh data-fork font): the file IS a Mac resource fork, so
    -- it matches upstream's weak RSRC magicNumber `(....)?\0\0\x01\0` (the
    -- 00 00 01 00 data-offset field); gated on the extension since that
    -- signature isn't distinctive enough to probe unconditionally. Upstream
    -- reaches RSRC.ProcessRSRC by falling through its try-each-candidate
    -- dispatch loop (the extension's own Font module declines a dfont
    -- header), this port routes the extension directly.
    if (ext == 'DFONT' or ext == 'RSRC') and n >= 4 then
        if buff:sub(1, 4) == '\0\0\x01\0' or buff:sub(5, 8) == '\0\0\x01\0' then
            return 'RSRC'
        end
    end
    -- TTF/OTF (upstream recognizes these by EXTENSION only -- no
    -- %magicNumber entry; `next if defined $moduleName{$type} and not
    -- $moduleName{$type}` skips pure-extension candidates during magic
    -- probing -- but then still processes them when the extension matched);
    -- gated on the font extensions for the same weak-signature reason
    if (ext == 'TTF' or ext == 'OTF') and n >= 5 then
        local sig = buff:sub(1, 4)
        local b5 = buff:byte(5)
        if (sig == '\0\x01\0\0' or sig == 'OTTO' or sig == 'true' or sig == 'typ1')
            and (b5 == 0 or b5 == 1) then
            return 'FONT'
        end
    end
    -- WOFF/WOFF2: the `wOF[F2]` alternative of upstream's %magicNumber
    -- 'Font', distinctive enough to probe without the extension
    -- (ProcessWOFF sets FileType/MIMEType itself)
    if perl.isMatch(buff, '^wOF[F2]') then return 'Font' end
    -- PFA/PFB (PostScript font files): upstream %magicNumber 'Font'
    -- alternative `(.{6})?%!(PS-(AdobeFont-|Bitstream )|FontType1-)`;
    -- gated on the extension since the bare '%!'-led form already belongs
    -- to the generic PS magic checked below and the 6-byte-prefixed form
    -- isn't distinctive enough to probe unconditionally (this port has no
    -- candidate-list dispatch loop to recover from a wrong claim;
    -- ProcessFont itself re-validates the signature either way). Returns
    -- upstream's exact type string ('Font', the %magicNumber key) so that
    -- SetFileType's baseType MIME fallback finds mimeType['Font'] for the
    -- sub-types (PFB/PFM) that have no %mimeType entry of their own.
    if ext == 'PFA' or ext == 'PFB' or ext == 'AFM' or ext == 'PFM' then
        local fontSig = n >= 16 and (buff:sub(7):match('^%%!PS%-AdobeFont%-')
            or buff:sub(7):match('^%%!Bitstream ') or buff:sub(7):match('^%%!FontType1%-'))
        fontSig = fontSig or buff:match('^%%!PS%-AdobeFont%-')
            or buff:match('^%%!Bitstream ') or buff:match('^%%!FontType1%-')
        -- (the Start(Comp|Master)?FontMetrics alternative of upstream's
        --  'Font' magicNumber covers AFM; ProcessAFM re-validates)
        fontSig = fontSig or buff:match('^StartCompFontMetrics[ \t\n\r\f\v]+%d')
            or buff:match('^StartMasterFontMetrics[ \t\n\r\f\v]+%d') or buff:match('^StartFontMetrics[ \t\n\r\f\v]+%d')
        -- (the `\0[\x01\x02]` alternative covers PFM; far too weak to probe
        --  unconditionally, so extension-gated like the rest here --
        --  ProcessFont re-validates size and DeviceType string)
        if ext == 'PFM' then
            fontSig = fontSig or (n >= 2 and buff:byte(1) == 0
                and (buff:byte(2) == 1 or buff:byte(2) == 2))
        end
        if fontSig then return 'Font' end
    end
    -- Mach-O / ELF / static-archive signatures: upstream has no %magicNumber
    -- entries for the EXE family -- when the extension is unrecognized it
    -- scans ALL process types, calling EXE.ProcessEXE, which validates its
    -- own signature (the .macho/.elf test files have no recognized extension).
    -- This port routes these unambiguous binary magics directly; ProcessEXE
    -- re-validates and distinguishes the sub-formats.
    if n >= 4 then
        local sig4 = buff:sub(1, 4)
        -- (cafebabe | feedface | feedfacf | cefaedfe | cffaedfe)
        if sig4 == '\202\254\186\190'
            or buff:match('^\254\237\250[\206\207]')
            or buff:match('^[\206\207]\250\237\254')
            or sig4 == '\127ELF'
            or (n >= 8 and buff:sub(1, 8) == '!<arch>\n') then
            return 'EXE'
        end
    end
    -- FPF (FLIR Public image Format, upstream %magicNumber
    -- `FPF Public Image Format\0`)
    if n >= 24 and buff:sub(1, 24) == 'FPF Public Image Format\0' then return 'FPF' end
    -- DICOM (upstream %magicNumber `(.{128}DICM|...)` -- only the 128-byte
    -- preamble + 'DICM' alternative is ported; the other alternatives are
    -- ACR-NEMA headerless forms handled by the deferred ACR branch);
    -- ProcessDICOM re-validates everything
    if n >= 132 and buff:sub(129, 132) == 'DICM' then return 'DICOM' end
    if ext == 'DCM' or ext == 'DIC' or ext == 'DC3' then
        raf:Seek(0, 0)
        local nd2, dcmBuff = raf:Read(132)
        raf:Seek(0, 0)
        if nd2 and nd2 >= 132 and dcmBuff:sub(129, 132) == 'DICM' then
            return 'DICOM'
        end
    end
    -- MKV (Matroska, upstream %magicNumber `\x1a\x45\xdf\xa3`; also MKA/
    -- MKS/WEBM -- ProcessMKV overrides the file type via DocType/tracks)
    if n >= 4 and buff:sub(1, 4) == '\26\69\223\163' then return 'MKV' end
    -- MXF (Material Exchange Format; upstream %magicNumber
    -- `\x06\x0e\x2b\x34\x02\x05\x01\x01\x0d\x01\x02` -- the partition-pack
    -- key prefix, after any run-in bytes; ProcessMXF locates its real start)
    if n >= 12 and buff:sub(1, 11) == '\6\14\43\52\2\5\1\1\13\1\2' then
        return 'MXF'
    end
    -- M2TS/M2T (MPEG-2 transport stream; upstream %magicNumber
    -- `.{0,191}?\x47(.{187}|.{191})\x47(.{187}|.{191})\x47` -- three 0x47
    -- sync bytes separated by two 187- or 191-byte gaps; ProcessM2TS
    -- re-validates and distinguishes the timecode variants)
    if n >= 256 then
        -- (the default probe buffer above holds only 256 bytes; the pattern
        --  spans up to five packet periods, so read a larger window here)
        raf:Seek(0, 0)
        local n2, buff2 = raf:Read(1024)
        if n2 and n2 >= 964 then
            local g = buff2:find('\71', 1, true) -- first 0x47 ('G'), 1-based
            while g and g <= 192 do
                -- (the 187-byte gap is tried first, matching the regex order)
                local d1
                if buff2:byte(g + 188) == 0x47 then d1 = 188 end
                if not d1 and buff2:byte(g + 192) == 0x47 then d1 = 192 end
                if d1 then
                    -- upstream leaves the accept/reject decision to
                    -- ProcessM2TS falling through its try-each-candidate
                    -- loop (this port has none); approximate it by requiring
                    -- three MORE sync bytes at the packet period, which
                    -- random matches in text files and other formats' boxes
                    -- practically never satisfy
                    local okSync = true
                    -- (a real stream keeps one constant packet period; a
                    --  mixed-gap layout matches the loose regex but is
                    --  rejected by ProcessM2TS all the same)
                    for k = 3, 5 do
                        if buff2:byte(g + k * d1) ~= 0x47 then
                            okSync = false
                            break
                        end
                    end
                    if okSync then
                        raf:Seek(0, 0) -- (leave the RAF rewound for ProcessM2TS)
                        return 'M2TS'
                    end
                end
                g = buff2:find('\71', g + 1, true)
            end
        end
        raf:Seek(0, 0)
    end
    -- JXL (JPEG XL, upstream %magicNumber `(\xff\x0a|\0\0\0\x0cJXL \x0d\x0a
    --  ......ftypjxl )`: the raw codestream and the ISO BMFF container)
    if n >= 2 and buff:sub(1, 2) == '\255\10' then return 'JXL' end
    if n >= 20 and buff:sub(1, 12) == '\0\0\0\12JXL \13\10\135\10' then return 'JXL' end
    -- X3F (Sigma/Foveon RAW): "FOVb" magic (upstream %magicNumber)
    if n >= 4 and buff:sub(1, 4) == 'FOVb' then return 'X3F' end
    -- CZI (Zeiss ZISRAW): "ZISRAWFILE\0\0\0\0\0\0" magic (upstream %magicNumber)
    if n >= 16 and buff:sub(1, 10) == 'ZISRAWFILE' and buff:sub(11, 16) == '\0\0\0\0\0\0' then
        return 'CZI'
    end
    -- XCF (GIMP native format): "gimp xcf " magic (upstream %magicNumber)
    if n >= 9 and buff:sub(1, 9) == 'gimp xcf ' then return 'XCF' end
    -- PS/EPS/AI (PostScript family): "%!PS", "%!Ad" or the DOS-binary-EPS
    -- `\xc5\xd0\xd3\xc6` header (upstream %magicNumber EPS entry)
    if n >= 4 and (buff:sub(1, 4) == '%!PS' or buff:sub(1, 4) == '%!Ad' or
        buff:sub(1, 4) == '\xc5\xd0\xd3\xc6') then return 'PS' end
    -- MacOS ("._" AppleDouble sidecar file): upstream %magicNumber (note the
    -- mixed-case 'MacOS' key here, distinct from %fileTypeLookup's uppercase
    -- 'MACOS' extension key -- SetFileType's ext-vs-type substitution logic
    -- depends on that case difference to leave FileType as 'MacOS')
    if n >= 24 and buff:match('^\0\5\22\7\0.\0\0Mac OS X        ') then return 'MacOS' end
    -- FPX (Windows Compound Binary; upstream %magicNumber
    -- `\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1`): any other extension (.fpx, .vnt,
    -- .max, an unrecognized one) -- "ExifTool identifies any unrecognized
    -- Windows Compound Binary file as a FlashPix (FPX) file"
    if n >= 8 and buff:sub(1, 8) == '\208\207\17\224\161\177\26\225' then return 'FPX' end
    -- EXV (Exiv2 metadata, upstream %magicNumber `\xff\x01Exiv2`)
    if n >= 7 and buff:sub(1, 7) == '\255\1Exiv2' then return 'EXV' end
    if n >= 2 then
        if buff:sub(1, 1) == '\255' and buff:sub(2, 2) == '\216' then return 'JPEG' end
        -- CRW: (II|MM).{4}HEAP(CCDR|JPGM) -- must be checked before the
        -- generic TIFF "II"/"MM" signature, since CRW also starts with a
        -- byte-order mark (upstream tests CRW before TIFF in @fileTypes)
        if n >= 14 and (buff:sub(1, 2) == 'II' or buff:sub(1, 2) == 'MM') and
            buff:sub(7, 10) == 'HEAP' and (buff:sub(11, 14) == 'CCDR' or buff:sub(11, 14) == 'JPGM') then
            return 'CRW'
        end
        -- DR4 (Canon VRD version 4 Recipe, upstream %magicNumber
        -- `IIII[\x04\x05]\0\x04\0`) -- must be checked before the generic
        -- TIFF "II" signature, since a DR4 file also starts with "II"
        if n >= 8 and buff:sub(1, 4) == 'IIII' and
            (buff:byte(5) == 0x04 or buff:byte(5) == 0x05) and
            buff:sub(6, 8) == '\0\4\0' then
            return 'DR4'
        end
        -- EXIF (upstream %magicNumber `(II\x2a\0|MM\0\x2a)`, tried first for
        -- the .exif extension, which %fileTypeLookup maps to EXIF)
        if ext == 'EXIF' and (buff:sub(1, 4) == 'II\42\0' or buff:sub(1, 4) == 'MM\0\42') then
            return 'EXIF'
        end
        if buff:sub(1, 2) == 'II' or buff:sub(1, 2) == 'MM' then return 'TIFF' end
    end
    -- PNG/MNG/JNG (upstream %magicNumber `(\x89P|\x8aM|\x8bJ)NG\r\n\x1a\n` --
    --  one entry for all three, so all three dispatch to PNG.ProcessPNG,
    --  which reads the signature again and sets the real FileType)
    if n >= 8 and buff:sub(3, 8) == 'NG\13\10\26\10' and
        (buff:sub(1, 2) == '\137P' or buff:sub(1, 2) == '\138M' or buff:sub(1, 2) == '\139J') then
        return 'PNG'
    end
    -- JPEG 2000 (upstream %magicNumber `(\0\0\0\x0cjP(  |\x1a\x1a)\x0d\x0a\x87\x0a|
    --  \xff\x4f\xff\x51\0)`: the JP2 container or a raw J2C codestream, which
    --  ProcessJP2 hands on to ProcessJPEG)
    if n >= 12 and buff:sub(1, 4) == '\0\0\0\12' and
        (buff:sub(5, 6) == 'jP' and (buff:sub(7, 8) == '  ' or buff:sub(7, 8) == '\26\26')) and
        buff:sub(9, 12) == '\13\10\135\10' then
        return 'JP2'
    end
    if n >= 5 and buff:sub(1, 5) == '\255\79\255\81\0' then return 'JP2' end
    -- JUMBF/C2PA (upstream %magicNumber `.{4}jumb\0.{3}jumd`; Jpeg2000's
    -- ProcessJUMBF sets C2PA or JUMBF from the description box type)
    if perl.isMatch(buff, [==[(?s)^.{4}jumb\0.{3}jumd]==]) then return 'JUMBF' end
    -- OpenEXR: \x76\x2f\x31\x01 (upstream %magicNumber)
    if n >= 4 and buff:sub(1, 4) == '\118\47\49\1' then return 'EXR' end
    -- RTF: {\rtf (upstream %magicNumber `\s*\{\\rtf`, optional leading
    --  newlines/spaces, the '\' escapes a literal '{' in the Lua pattern)
    if buff:match('^[ \t\n\r\f\v]*{[ \t\n\r\f\v]*\\rtf[^a-zA-Z]') then return 'RTF' end
    -- PSP: Paint Shop Pro (upstream %magicNumber
    --  `Paint Shop Pro Image File\x0a\x1a\0{5}`, the 32-byte file header)
    if n >= 32 and buff:sub(1, 25) == 'Paint Shop Pro Image File' and
        buff:byte(26) == 10 and buff:byte(27) == 26 and
        buff:sub(28, 32) == '\0\0\0\0\0' then
        return 'PSP'
    end
    -- VCard/iCalendar: BEGIN:(VCARD|VCALENDAR|VNOTE) (upstream %magicNumber
    --  `(?i)BEGIN:(VCARD|VCALENDAR|VNOTE)\r\n`; PCRE2 via the facade -- Lua
    --  patterns have no alternation, so the /i flag and alternation go through
    --  one literal pattern)
    if perl.matches(buff, '(?i)^BEGIN:(VCARD|VCALENDAR|VNOTE)\\r\\n') then return 'VCard' end
    -- TNEF (Transport Neutral Encapsulation Format): the TNEFHeader + version
    if n >= 0x15 and buff:sub(1, 4) == '\120\159\62\34' and buff:byte(7) == 1 and
        buff:sub(8, 9) == '\6\144' and buff:byte(10) == 8 and buff:byte(11) == 0 then
        return 'TNEF'
    end
    -- WTV (Windows recorded TV show): the 16-byte WTV GUID (upstream
    -- %magicNumber `\xb7\xd8\x00\x20\x37\x49\xda\x11\xa6\x4e\x00\x07\xe9\x5e\xad\x8d`)
    if n >= 16 and buff:sub(1, 16) == '\183\216\0\32\55\73\218\17\166\78\0\7\233\94\173\141' then
        return 'WTV'
    end
    -- R3D (Redcode RAW Video): `\0\0..RED(1|2)` (upstream %magicNumber)
    if n >= 8 and buff:match('^\0\0..RED[12]') then return 'R3D' end
    -- MRC (Medical Research Council image): upstream %magicNumber
    --  `.{64}[\x01\x02\x03]\0\0\0[\x01\x02\x03]\0\0\0[\x01\x02\x03]\0\0\0
    --   .{132}MAP[\0 ](\x44\x44|\x44\x41|\x11\x11)\0\0` -- PCRE2 via the
    --   facade (Lua patterns have no alternation)
    if n >= 217 and perl.matches(buff, '(?s).{64}[\\x01\\x02\\x03]\\0\\0\\0[\\x01\\x02\\x03]\\0\\0\\0' ..
            '[\\x01\\x02\\x03]\\0\\0\\0.{132}MAP[\\0 ](\\x44\\x44|\\x44\\x41|\\x11\\x11)\\0\\0') then
        return 'MRC'
    end
    -- Palm Database / Mobipocket: the 8-byte type/creator ID at byte 61
    -- (upstream %magicNumber `.{60}(\.pdfADBE|TEXtREAd|...)`; PCRE2 via the
    --  facade -- Lua patterns have no alternation)
    if n >= 68 then
        local palmType = buff:sub(61, 68)
        if perl.matches(palmType, '^(\\.pdfADBE|TEXtREAd|BVokBDIC|DB99DBOS|PNRdPPrs|DataPPrs|vIMGView|' ..
                'PmDBPmDB|InfoINDB|ToGoToGo|SDocSilX|JbDbJBas|JfDbJFil|DATALSdb|Mdb1Mdb1|BOOKMOBI|' ..
                'DataPlkr|DataSprd|SM01SMem|TEXtTlDc|InfoTlIf|DataTlMl|DataTlPt|dataTDBP|TdatTide|' ..
                'ToRaTRPW|zTXTGPlm|BDOCWrdS)$') then
            return 'PDB'
        end
    end
    -- Real Media/Audio/Metafile: `(\.RMF|\.ra\xfd|pnm://|rtsp://|http://)`
    -- (upstream %magicNumber; PCRE2 via the facade -- Lua patterns have no
    --  alternation)
    if perl.matches(buff, '^(\\.RMF|\\.ra\\xfd|pnm://|rtsp://|http://)') then
        return 'Real'
    end
    -- FLAC: "fLaC" magic (upstream %magicNumber `(fLaC|ID3)`)
    if n >= 4 and buff:sub(1, 4) == 'fLaC' then return 'FLAC' end
    -- OGG: "OggS" magic (upstream %magicNumber `(OggS|ID3)`; an ID3-prefixed
    -- Ogg file falls through to ID3.v2 which re-dispatches)
    if n >= 4 and buff:sub(1, 4) == 'OggS' then return 'OGG' end
    -- ID3v2 header (upstream %magicNumber for MP3 and the ID3-prefixed Ogg/
    -- FLAC alternatives): an ID3-prefixed file dispatches to ID3.ProcessID3,
    -- which processes the ID3v2 header, then the following audio data
    -- (MPEG/APE/MPC/FLAC/OGG) and any ID3v1 trailer
    if n >= 3 and buff:sub(1, 3) == 'ID3' then return 'MP3' end
    -- PSD/PSB: 8BPS\0[\x01\x02] (upstream %magicNumber PSD entry)
    if n >= 6 and buff:sub(1, 4) == '8BPS' and buff:sub(5, 5) == '\0' and
        (buff:byte(6) == 1 or buff:byte(6) == 2) then
        return 'PSD'
    end
    if n >= 2 and buff:sub(1, 2) == 'BM' then return 'BMP' end
    if n >= 6 and buff:sub(1, 3) == 'GIF' then return 'GIF' end
    if n >= 2 and buff:sub(1, 1) == '\255' and (buff:sub(2, 2) == '\240' or buff:sub(2, 2) == '\241') then
        return 'AAC'
    end
    -- Audible .AA: .{4}\x57\x90\x75\x36 (4 arbitrary bytes then the magic)
    if n >= 8 and buff:sub(5, 8) == '\87\144\117\54' then return 'AA' end
    if n >= 4 and (buff:sub(1, 4) == 'MAC ' or buff:sub(1, 8) == 'APETAGEX') then return 'APE' end
    -- ASF top-level header GUID (75B22630-668E-11CF-A6D9-00AA0062CE6C), binary form
    if n >= 16 and buff:sub(1, 16) == '\48\38\178\117\142\102\207\17\166\217\0\170\0\98\206\108' then
        return 'ASF'
    end
    -- RIFF container (upstream %magicNumber
    -- `(RIFF|LA0[234]|OFR |LPAC|wvpk|RF64)`, RIFF plus other variants) --
    -- ProcessRIFF reads the 4-byte type word and reports the real subtype
    -- (WAV/AVI/WEBP/...) via SetFileType; the RF64 (MBWF) variant is not
    -- ported and is deliberately excluded here
    if n >= 4 then
        local riffSig = buff:sub(1, 4)
        -- 'wvpk' is a WavPack block header: upstream reaches WavPack.pm for it
        -- through the file NAME (its %magicNumber has no WV entry, so the .wv
        -- extension decides) but reports FileType WV either way, since
        -- RIFF.pm's %riffType maps 'wvpk' to WV as well. Naming it here keeps
        -- both paths on ProcessWV, which reads the WavPack header and then
        -- hands the file to ProcessRIFF itself.
        if riffSig == 'wvpk' then return 'WV' end
        if riffSig == 'RIFF' or riffSig == 'LA02' or riffSig == 'LA03' or
            riffSig == 'LA04' or riffSig == 'OFR ' or riffSig == 'LPAC' then
            return 'RIFF'
        end
    end
    -- ICO/CUR: \0\0[\x01\x02]\0[^0]\0 (reasonably assume <256 images)
    if n >= 6 and buff:sub(1, 2) == '\0\0' and (buff:byte(3) == 1 or buff:byte(3) == 2) and
        buff:byte(4) == 0 and buff:byte(5) ~= 0x30 and buff:byte(6) == 0 then
        return 'ICO'
    end
    -- PCX: \x0a[\0-\x05]\x01[\x01\x02\x04\x08].{64}[\0-\x02]
    if n >= 69 and buff:byte(1) == 0x0a and buff:byte(2) <= 0x05 and buff:byte(3) == 0x01 and
        (buff:byte(4) == 1 or buff:byte(4) == 2 or buff:byte(4) == 4 or buff:byte(4) == 8) and
        buff:byte(69) <= 0x02 then
        return 'PCX'
    end
    -- Radiance RGBE HDR: #?RADIANCE\x0a or #?RGBE\x0a
    if buff:match('^#%?RADIANCE\n') or buff:match('^#%?RGBE\n') then return 'HDR' end
    -- PPM/PGM/PBM: P[1-6]\s+
    if n >= 3 and buff:byte(1) == 0x50 and buff:byte(2) >= 0x31 and buff:byte(2) <= 0x36 and
        (buff:byte(3) == 0x20 or buff:byte(3) == 0x09 or buff:byte(3) == 0x0a or buff:byte(3) == 0x0d) then
        return 'PPM'
    end
    -- PFM (Portable FloatMap, upstream %magicNumber
    -- `P[Ff]\x0a\d+ \d+\x0a[-+0-9.]+\x0a` -- P[Ff] followed by a newline,
    -- distinguishing a FloatMap image from Printer Font Metrics .pfm files)
    if buff and buff:match('^P[Ff]\n%d+ %d+\n[%-%+0-9%.]+\n') then return 'PFM' end
    -- WPG: \xff\x57\x50\x43 ("WPC")
    if n >= 4 and buff:byte(1) == 0xff and buff:sub(2, 4) == 'WPC' then return 'WPG' end
    -- ITC: .{4}itch (4 arbitrary bytes then the literal "itch")
    if n >= 8 and buff:sub(5, 8) == 'itch' then return 'ITC' end
    -- DSF (DSD Stream File, upstream %magicNumber `DSD \x1c\0{7}.{16}fmt `)
    if n >= 32 and buff:sub(1, 4) == 'DSD ' and buff:sub(5, 12) == '\28\0\0\0\0\0\0\0' and
        buff:sub(29, 32) == 'fmt ' then
        return 'DSF'
    end
    -- DSS/DS2 (Olympus voice recorder audio, upstream %magicNumber
    -- `(\x02dss|\x03ds2)`); ProcessDSS re-reads and validates the header
    if n >= 4 and (buff:sub(1, 4) == '\2dss' or buff:sub(1, 4) == '\3ds2') then return 'DSS' end
    -- SWF (Shockwave Flash, upstream %magicNumber `[FC]WS[^\0]`)
    if n >= 4 and (buff:sub(1, 1) == 'F' or buff:sub(1, 1) == 'C') and
        buff:sub(2, 3) == 'WS' and buff:byte(4) ~= 0 then
        return 'SWF'
    end
    -- FLV (Flash Video, upstream %magicNumber `FLV\x01`)
    if n >= 4 and buff:sub(1, 4) == 'FLV\1' then return 'FLV' end
    -- MRW (Konica-Minolta RAW, upstream %magicNumber `\0MR[MI]` --
    -- "\0MRM" big-endian MRW images, "\0MRI" little-endian MRWInfo in ARW)
    if n >= 4 and buff:sub(1, 1) == '\0' and buff:sub(2, 3) == 'MR' and
        (buff:sub(4, 4) == 'M' or buff:sub(4, 4) == 'I') then
        return 'MRW'
    end
    -- DPX: (SDPX|XPDS)
    if n >= 4 and (buff:sub(1, 4) == 'SDPX' or buff:sub(1, 4) == 'XPDS') then return 'DPX' end
    -- NKA: NIKONADJ
    if n >= 8 and buff:sub(1, 8) == 'NIKONADJ' then return 'NKA' end
    -- DV: \x1f\x07\0[\x3f\xbf] (quick check; ProcessDV also does a slower
    -- fallback scan for files where the first DIF isn't at the very start)
    if n >= 4 and buff:sub(1, 3) == '\31\7\0' and (buff:byte(4) == 0x3f or buff:byte(4) == 0xbf) then
        return 'DV'
    end
    -- weak signature (upstream keeps it last in the file-type test order)
    if n >= 2 and buff:sub(1, 2) == 'V6' then return 'MOI' end
    -- Torrent (bencoded dictionary): d\d+:\w+
    do
        local dpos = buff:match('^d()%d')
        if dpos then
            local digitsEnd = buff:match('^%d+()', dpos)
            if digitsEnd and buff:sub(digitsEnd, digitsEnd) == ':' and buff:sub(digitsEnd + 1, digitsEnd + 1):match('[A-Za-z0-9]') then
                return 'Torrent'
            end
        end
    end
    -- AIFF / DjVu (both use the IFF/FORM container, disambiguated by
    -- AIFF.ProcessAIFF itself): (FORM....AIF[FC]|AT&TFORM)
    if n >= 12 and buff:sub(1, 4) == 'FORM' and (buff:sub(9, 12) == 'AIFF' or buff:sub(9, 12) == 'AIFC') then
        return 'AIFF'
    end
    if n >= 8 and buff:sub(1, 8) == 'AT&TFORM' then return 'AIFF' end
    -- BPG: "BPG\xfb"
    if n >= 4 and buff:sub(1, 4) == 'BPG\251' then return 'BPG' end
    -- FITS: "SIMPLE  =" + 20 spaces + "T"
    if n >= 30 and buff:sub(1, 9) == 'SIMPLE  =' and buff:sub(10, 29) == string.rep(' ', 20) and
        buff:byte(30) == 0x54 then
        return 'FITS'
    end
    -- FIT: 8 arbitrary header bytes then ".FIT" (upstream %magicNumber
    -- `.{8}\.FIT`; tested after FITS since FITS files may also carry a
    -- .FIT extension)
    if n >= 12 and buff:sub(9, 12) == '.FIT' then return 'FIT' end
    if n >= 3 and buff:sub(1, 3) == 'PGF' then return 'PGF' end
    -- FLIF (upstream %magicNumber `FLIF[0-\x6f][0-2]`; Lua classes have no
    -- ranges, so the type byte is matched as "not 0x70-0xff" and the depth
    -- digit separately)
    if n >= 6 and buff:sub(1, 4) == 'FLIF'
        and not buff:sub(5, 5):match('[\x70-\xff]')
        and buff:sub(6, 6):match('^[0-2]$') then
        return 'FLIF'
    end
    if n >= 8 and buff:sub(1, 8) == 'XISF0100' then return 'XISF' end
    if n >= 8 and buff:sub(1, 8) == '\137LFP\13\10\26\10' then return 'LFP' end
    if n >= 14 and buff:sub(1, 14) == 'id=ImageMagick' then return 'MIFF' end
    -- RWZ (Rawzor compressed image, upstream %magicNumber `rawzor`): upstream
    -- reaches Rawzor.pm through the file NAME (RWZ is not in its @fileTypes
    -- list), this port's content-based detection stands in for that
    if n >= 6 and buff:sub(1, 6) == 'rawzor' then return 'RWZ' end
    -- LIF (Leica Image File, upstream %magicNumber `\x70\0{3}.{4}\x2a.{4}<\0`)
    if n >= 15 and buff:sub(1, 4) == '\112\0\0\0' and buff:sub(9, 9) == '\42' and
        buff:sub(14, 15) == '<\0' then
        return 'LIF'
    end
    -- PCAP/PCAPNG/CAP: upstream %magicNumber
    --  `\xa1\xb2(\xc3\xd4|\x3c\x4d)\0.\0.|(\xd4\xc3|\x4d\x3c)\xb2\xa1.\0.\0|
    --   \x0a\x0d\x0d\x0a.{4}(\x1a\x2b\x3c\x4d|\x4d\x3c\x2b\x1a)|GMBU\0\x02`
    --  -- PCRE2 via the facade (Lua patterns have no alternation operator)
    if n >= 8 and perl.matches(buff, '^(\\xa1\\xb2(\\xc3\\xd4|\\x3c\\x4d)\\0.\\0.|(\\xd4\\xc3|\\x4d\\x3c)\\xb2\\xa1.\\0.\\0|' ..
            '\\x0a\\x0d\\x0d\\x0a.{4}(\\x1a\\+\\x3c\\x4d|\\x4d\\x3c\\+\\x1a)|GMBU\\0\\x02)') then
        return 'PCAP'
    end
    -- XMP (also matches generic XML/INX/SVG/PLIST files, which ProcessXMP
    -- then disambiguates by content; must be tested before PLIST since both
    -- share the '<'-led signature, and upstream tests XMP first)
    -- HTML: (upstream %magicNumber
    -- `(\xef\xbb\xbf)?\s*(?i)<(!DOCTYPE\s+HTML|HTML|\?xml)`, case
    -- insensitive) -- must be tested before the generic '<'-led XMP magic,
    -- which would otherwise catch a <!DOCTYPE HTML/<HTML file and then fail
    -- to parse it as XMP
    do
        local h = buff
        if h:sub(1, 3) == '\239\187\191' then h = h:sub(4) end
        local ht = h:match('^[ \t\n\r\f\v]*<(%?xml)')
        if ht then
            ht = '?xml'
        else
            ht = h:match('^[ \t\n\r\f\v]*<([A-Za-z]+)')
            if ht then ht = lc(ht) end
        end
        if ht == 'html' or ht == '!doctype' or ht == '?xml' then
            -- (upstream's `(?i)` -- the DOCTYPE/HTML element may be any
            --  case; the generic XMP/XML magic would catch a '<'-led
            --  file, so HTML is disambiguated here first)
            if ht ~= '?xml' or lc(h):match('<!DOCTYPE[ \t\n\r\f\v]+html') or lc(h):match('<html[ \t\n\r\f\v>]') then
                return 'HTML'
            end
        end
    end
    if isXMLMagic(buff) then return 'XMP' end
    -- PLIST: (bplist0|\xfe\xff\x00) (upstream %magicNumber
    --  `(bplist0|\s*<|\xfe\xff\x00)`; the `\s*<` alternative is intentionally
    --  not tested here -- any '<'-led file is matched by the XMP magic above
    --  instead, mirroring upstream @fileTypes order where XMP is tested before
    --  PLIST, and ProcessXMP disambiguates genuine XMP from PLIST/SVG/INX/XML
    --  by content. PCRE2 via the facade -- Lua patterns have no alternation)
    if perl.matches(buff, '^(bplist0|\\xfe\\xff\\x00)') then return 'PLIST' end
    -- ICC: .{12}(scnr|mntr|prtr|link|spac|abst|nmcl|nkpf|cenc|mid |mlnk|mvis)
    --      (XYZ |Lab |Luv |YCbr|Yxy |RGB |GRAY|HSV |HLS |CMYK|CMY |[2-9A-F]CLR|
    --       nc..|\0{4}){2} (upstream %magicNumber ICC entry; PCRE2 via the
    --       facade -- Lua patterns have no alternation)
    if n >= 24 and perl.matches(buff, '(?s)^.{12}(scnr|mntr|prtr|link|spac|abst|nmcl|nkpf|cenc|mid |mlnk|mvis)' ..
            '(XYZ |Lab |Luv |YCbr|Yxy |RGB |GRAY|HSV |HLS |CMYK|CMY |[2-9A-F]CLR|nc..|\\0{4}){2}') then
        return 'ICC'
    end
    -- MIE: ~[\x10\x18]\x04.0MIE (upstream %magicNumber MIE entry)
    if n >= 8 and buff:sub(1, 1) == '~' and (buff:byte(2) == 0x10 or buff:byte(2) == 0x18) and
        buff:byte(3) == 0x04 and buff:sub(5, 8) == '0MIE' then
        return 'MIE'
    end
    -- CanonVRD: "CANON OPTIONAL DATA\0"
    if n >= 20 and buff:sub(1, 20) == 'CANON OPTIONAL DATA\0' then return 'VRD' end
    -- PMP: .{8}\0{3}\x7c.{112}\xff\xd8\xff\xdb (Sony DSC-F1 PMP header)
    if n >= 128 and buff:sub(9, 11) == '\0\0\0' and buff:sub(12, 12) == '\124' and
        buff:sub(125, 128) == '\255\216\255\219' then
        return 'PMP'
    end
    -- RAF: "FUJIFILM" (FujiFilm RAW Format)
    if n >= 8 and buff:sub(1, 8) == 'FUJIFILM' then return 'RAF' end
    -- PICT (Apple Picture): (.{10}|.{522})(\x11\x01|\x00\x11) -- opcode
    -- 0x1101 (version 1) or 0x0011 (version 2) either right at the start
    -- (a PICT resource) or after the file's 512-byte header (a PICT file);
    -- only the no-header form is checked here since our 256-byte read
    -- buffer doesn't reach byte 522 -- ProcessPICT itself falls back to
    -- seeking past a 512-byte header when the no-header form doesn't parse
    if n >= 12 and (buff:sub(11, 12) == '\17\1' or buff:sub(11, 12) == '\0\17') then return 'PICT' end
    -- JSON: (\xef\xbb\xbf)?\s*(\[\s*)?\{\s*"[^"]*"\s*: (upstream
    -- %magicNumber JSON entry; the optional BOM and '[' are handled by the
    -- one Lua pattern since `%[?` is a single optional character)
    do
        local j = buff
        if j:sub(1, 3) == '\239\187\191' then j = j:sub(4) end
        if j:match('^[ \t\n\r\f\v]*%[?[ \t\n\r\f\v]*{[ \t\n\r\f\v]*"[^"]*"[ \t\n\r\f\v]*:') then return 'JSON' end
    end
    -- LNK/.URL (Windows shortcut; upstream %magicNumber
    -- `(.{4}\x01\x14\x02\0{5}\xc0\0{6}\x46|\[[InternetShortcut\][\x0d\x0a])`
    -- -- the first alternative is the binary .lnk header, the second the
    --  INI-format .URL signature, which must be tested before the generic
    --  text/TXT fallback since a .url file is plain text)
    if n >= 20 and buff:match('^....\1\20\2\0\0\0\0\0\192\0\0\0\0\0\0\70') then return 'LNK' end
    if buff and buff:match('^%[InternetShortcut%][\r\n]') then return 'URL' end
    -- ZIP (upstream %magicNumber `PK\x03\x04`)
    if n >= 4 and buff:sub(1, 4) == 'PK\3\4' then return 'ZIP' end
    -- GZIP (upstream %magicNumber `\x1f\x8b\x08`)
    if n >= 3 and buff:sub(1, 3) == '\31\139\8' then return 'GZIP' end
    -- RAR (upstream %magicNumber `Rar!\x1a\x07[\x00\x01]`)
    if n >= 7 and buff:match('^Rar!\26\7[\0\1]') then return 'RAR' end
    -- 7Z: upstream has no %magicNumber and no %moduleName entry for it, so
    -- `$module = $type` and it reaches Image::ExifTool::7Z::Process7Z from
    -- the extension-derived candidate list, with Process7Z validating the
    -- 6-byte signature itself.  This port has no such candidate loop, so the
    -- unambiguous signature is routed directly (Process7Z re-checks it)
    if n >= 6 and buff:sub(1, 6) == '7z\188\175\39\28' then return '7Z' end
    -- KVAR (Kandao Video Asset Resource, upstream %magicNumber
    -- `.{2}\0\0[A-Z].{31}(CHAR|BOOL|[US](8|16|32|64)|FLOAT|DOUBLE)\0` -- an
    -- entry count, then the first record's 32-byte tag name and its format
    -- code; tested late, like upstream's @fileTypes order, since the leading
    -- bytes are unconstrained)
    if n >= 0x2d and testMagic(buff, 'KVAR') then return 'KVAR' end
    -- TXT/CSV (Text.pm) fallback for an unrecognized extension: no strong
    -- signature, so tried last since it matches almost any non-binary file;
    -- ProcessTXT does the real detailed encoding analysis.
    if isWeakText(buff) then return 'TXT' end
    return nil
end
--------------------------------------------------------------------------------
-- ImageInfo - return specified information from image file
-- Inputs: 0) [optional] ExifTool object reference
--         1) filename, file reference, RAF reference, or scalar data reference
--         2-N) list of tag names to find (or tag list reference or options reference)
-- Returns: reference to hash of tag/value pairs (with "Error" entry on error)
-- Notes:
--   - if no tags names are specified, the values of all tags are returned
--   - tags may be specified with leading '-' to exclude, or trailing '#' for ValueConv
--   - can pass a reference to list of tags to find, in which case the list will
--     be updated with the tags found in the proper case and in the specified order.
--   - can pass reference to hash specifying options
--   - returned tag values may be scalar references indicating binary data
--   - see ClearOptions() below for a list of options and their default values
-- Examples:
--   use Image::ExifTool 'ImageInfo';
--   my $info = ImageInfo($file, 'DateTimeOriginal', 'ImageSize');
--    - or -
--   my $et = Image::ExifTool->new;
--   my $info = $et->ImageInfo($file, \@tagList, {Sort=>'Group0'} );
--
-- upstream ImageInfo($;@): usable either as a method (`et:ImageInfo(file,
-- opts)`) or as a standalone function (`lexiftool.ImageInfo(file, opts)`,
-- which creates a throwaway ExifTool object) -- upstream distinguishes by
-- whether the first argument is a blessed ExifTool object; here that's
-- "is selfOrFile an ExifTool instance".
function ExifTool.ImageInfo(selfOrFile, ...)
    -- get our ExifTool object (self) or create one if necessary
    local self, args
    if type(selfOrFile) == 'table' and getmetatable(selfOrFile) == ExifTool then
        self = selfOrFile
        args = table.pack(...)
    else
        self = ExifTool.new()
        args = table.pack(selfOrFile, ...)
    end
    local saveOptions = {}      -- save original options
    for k, v in pairs(self.OPTIONS) do saveOptions[k] = v end

    -- parse our function arguments
    -- (upstream ParseArguments, ExifTool.pm:5084.  The port's ExtractInfo
    --  takes the file itself and starts with an Init that wipes every member,
    --  so the file is the first argument here, the requested tags travel to
    --  ExtractInfo in its options hash, and IO_TAG_LIST is set after it.
    --  A table with a [1] entry -- or an empty one -- is a tag list, any
    --  other table the options hash; see ParseArguments.)
    local file = args[1]
    local options = self.OPTIONS
    local oldGroupOpts = {}
    for k in pairs(options) do
        if perl.matches(k, '^Group') then oldGroupOpts[#oldGroupOpts + 1] = k end
    end
    local requestedTags, exclude, ioTagList = {}, {}, nil
    local wasExcludeOpt = false
    for i = 2, args.n do
        local arg = args[i]
        if type(arg) == 'table' and (arg[1] ~= nil or next(arg) == nil) then
            ioTagList = arg
            for _, t in ipairs(arg) do
                local excl = perl.matches(t, '^-(.*)')
                if excl then
                    exclude[#exclude + 1] = excl
                else
                    requestedTags[#requestedTags + 1] = t
                end
            end
        elseif type(arg) == 'table' then
            local opts = {}
            for opt in pairs(arg) do opts[#opts + 1] = opt end
            tsort(opts)
            for _, opt in ipairs(opts) do
                -- a single new group option overrides all old group options
                if #oldGroupOpts > 0 and perl.matches(opt, '^Group') then
                    for _, g in ipairs(oldGroupOpts) do options[g] = nil end
                    oldGroupOpts = {}
                end
                self:Options(opt, arg[opt])
                if opt == 'Exclude' then wasExcludeOpt = true end
            end
        elseif type(arg) == 'string' then
            local excl = perl.matches(arg, '^-(.*)')
            if excl then
                exclude[#exclude + 1] = excl
            else
                requestedTags[#requestedTags + 1] = arg
            end
        end
    end
    if #exclude > 0 or wasExcludeOpt then
        -- must add existing excluded tags
        if options.Exclude then
            for _, e in ipairs(options.Exclude) do exclude[#exclude + 1] = e end
        end
        options.Exclude = exclude
        -- expand shortcuts in new exclude list
        ExifTool.ExpandShortcuts(options.Exclude, 1) -- (also remove '#' suffix)
    end
    -- generate lookup for excluded tags
    self.EXCL_TAG_LOOKUP = {}
    self.EXCL_XMP_LOOKUP = nil
    if options.Exclude then
        for _, e in ipairs(options.Exclude) do
            local name = perl.matches(e, [[([-\w]+)#?$]])
            if name then self.EXCL_TAG_LOOKUP[lc(name)] = 1 end
            local xmp = perl.matches(e, [[(?i)(xmp-.*:[-\w]+)#?]])
            if xmp then
                if not self.EXCL_XMP_LOOKUP then self.EXCL_XMP_LOOKUP = {} end
                self.EXCL_XMP_LOOKUP[lc(xmp)] = 1
            end
        end
        -- exclude list is used only for EXCL_TAG_LOOKUP when TAGS_FROM_FILE is set
        if self.TAGS_FROM_FILE then options.Exclude = nil end
    end

    -- extract meta information from image
    local extractOpts
    if #requestedTags > 0 then extractOpts = { RequestedTags = requestedTags } end
    self:ExtractInfo(file, extractOpts)
    self.IO_TAG_LIST = ioTagList
    local info = self:GetInfo(nil)      -- get requested information

    self.OPTIONS = saveOptions          -- restore original options

    return info     -- return requested information
end

-- The requested-tag half of upstream ParseArguments (ExifTool.pm:5160-5169),
-- split out because this port's ExtractInfo sets REQUESTED_TAGS itself after
-- its Init (which wipes every member) -- see ImageInfo.  Also used by
-- ParseArguments, so both routes build the same list and lookup.
function ExifTool:setRequestedTags(requestedTags)
    self.REQUESTED_TAGS = requestedTags
    if not self.REQ_TAG_LOOKUP then self.REQ_TAG_LOOKUP = {} end
    -- expand shortcuts in tag arguments if provided
    if #requestedTags > 0 then
        ExifTool.ExpandShortcuts(requestedTags)
        -- initialize lookup for requested tags
        for _, t in ipairs(requestedTags) do
            local grp, name = perl.matches(t, [[^(.*:)?([-\w?*]*)#?$]])
            if name then
                if name ~= '' then self.REQ_TAG_LOOKUP[lc(name)] = 1 end
                if grp then
                    for _, g in ipairs(perl.split(':', grp)) do
                        self.REQ_TAG_LOOKUP[lc(g) .. ':'] = 1
                    end
                end
            end
        end
    end
end

-- Set alternate file for extracting information (upstream Writer.pl
-- SetAlternateFile). Same aliasing rationale as ExifTool:SetNewValue above.
-- Inputs: 0) ExifTool ref, 1) family 8 group name ("File#"), 2) file name
-- Returns: 1 on success, or 0 on invalid group name
function ExifTool:SetAlternateFile(g8, file)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetAlternateFile', self, g8, file)
end

--------------------------------------------------------------------------------
-- Purge temporary tags from memory and set purge flag for next time
-- Inputs: 0) false=disable purging, true=enable purging, and
--            purge now if number of digits in tags to purge >= flag
function ExifTool.Purge(flag)
    purgeFlag = perlTruthy(flag) and flag or 0
    if #purgeTags > 0 and perl.length(#purgeTags) >= purgeFlag then
        for _, t in ipairs(purgeTags) do
            if t.IsProtobuf == nil then t.Table[t.TagID] = nil end
        end
        purgeTags = {}
    end
end

--------------------------------------------------------------------------------
-- Combine information from a list of info hashes
-- Unless Duplicates is enabled, first entry found takes priority
-- Inputs: 0) ExifTool object reference, 1-N) list of info hash references
-- Returns: Combined information hash reference
function ExifTool:CombineInfo(...)
    local combined = {}
    if perlTruthy(self.OPTIONS.Duplicates) then
        for i = 1, select('#', ...) do
            local info = select(i, ...)
            if type(info) == 'table' then
                for tag, v in pairs(info) do
                    combined[tag] = v
                end
            end
        end
    else
        local haveInfo = {}
        for i = 1, select('#', ...) do
            local info = select(i, ...)
            if type(info) == 'table' then
                -- upstream iterates `keys %$info` in Perl's hash order; sort
                -- so a duplicate pair inside ONE info hash resolves the same
                -- way every run (the cross-hash priority is the argument
                -- order, which is what the caller controls)
                local tags = {}
                for tag in pairs(info) do tags[#tags + 1] = tag end
                tsort(tags, function(a, b)
                    return (self.FILE_ORDER[a] or 0) < (self.FILE_ORDER[b] or 0)
                end)
                for _, tag in ipairs(tags) do
                    local tagName = ExifTool.GetTagName(tag)
                    if not haveInfo[tagName] then
                        haveInfo[tagName] = 1
                        combined[tag] = info[tag]
                    end
                end
            end
        end
    end
    return combined
end

-- Convert tag names to values or variables in a string (upstream Writer.pl
-- InsertTagValues). Same aliasing rationale as ExifTool:SetNewValue below.
-- Inputs: 0) ExifTool object ref, 1) string with embedded tag names,
--         2) reference to list of found tags or undef to use FOUND_TAGS,
--         3) options, 4) document group name, 5) tag key cache
-- Returns: string with embedded tag values
function ExifTool:InsertTagValues(line, foundTags, opt, docGrp, cache)
    return ExifTool.DoAutoLoad('Image::ExifTool::InsertTagValues', self, line, foundTags, opt, docGrp, cache)
end

-- Add user-defined tags at run time (upstream Writer.pl AddUserDefinedTags;
-- the table name is the port's, e.g. 'lexiftool.ExifTool.Composite' for
-- upstream's 'Image::ExifTool::Composite', and %addTags a table)
function ExifTool.AddUserDefinedTags(tableName, addTags)
    return ExifTool.DoAutoLoad('Image::ExifTool::AddUserDefinedTags', tableName, addTags)
end

--------------------------------------------------------------------------------
-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm)
local function daysFromCivil(year, month, day)
    year = year - (month <= 2 and 1 or 0)
    local era = (year >= 0 and year // 400) or ((year - 399) // 400)
    local yoe = year - era * 400
    local doy = ((153 * (month + (month > 2 and -3 or 9))) + 2) // 5 + day - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

--------------------------------------------------------------------------------
-- Get Unix time from EXIF-formatted date/time string with optional timezone
-- Inputs: 0) EXIF date/time string, 1) non-zero if time is local, or 2 to assume UTC
-- Returns: Unix time (seconds since 0:00 GMT Jan 1, 1970) or undefined on error
--------------------------------------------------------------------------------
function ExifTool.GetUnixTime(timeStr, isLocal)
    if timeStr == '0000:00:00 00:00:00' then return 0 end
    local y, mo, d, h, mi, s, tz = perl.str(timeStr):match('^(%d+)[%-:](%d+)[%-:](%d+)[ \t\n\r\f\v]+(%d+):(%d+):(%d+%.?%d*)(.*)')
    if not y then return nil end
    local tzSec = 0
    -- (upstream regex `/^(Z|([-+])(\d+):(\d+))/`; PCRE2 via the facade --
    --  Lua patterns have no alternation operator. The `(?i:...)` keeps the
    --  case-insensitive Z that the original Lua `[Zz]` check allowed)
    local cap1, sign, tzh, tzm = perl.matches(tz, '^(?i)(Z|([-+])([0-9]+):([0-9]+))')
    local z = cap1 or sign
    if isLocal then
        if z then
            if sign then
                tzSec = (tonumber(tzh) * 60 + tonumber(tzm)) * (sign == '-' and -60 or 60)
            end
            isLocal = nil
        elseif isLocal == '2' then
            isLocal = nil
        end
    end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    local val
    if isLocal then
        -- upstream calls Time::Local::timelocal(), which lets mktime() decide
        -- whether the given local time falls in DST. Leaving `isdst` out of
        -- the table does the same in Lua (an absent field means -1 =
        -- "unknown, work it out"); passing `isdst = false` forced standard
        -- time and put every summer timestamp one hour off.
        val = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
    else
        val = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - tzSec
    end
    local frac = tz and tz:match('^(%.%d+)') or nil
    if frac then val = val + tonumber(frac) end
    return val
end

--------------------------------------------------------------------------------
-- Write path: the routines upstream AUTOLOADs from Writer.pl are reached
-- through these thin methods; their bodies live in Writer.lua.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Get list of all deletable group names
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool.GetDeleteGroups()
    return ExifTool.DoAutoLoad('Image::ExifTool::GetDeleteGroups')
end

-- Set the value to write for a tag. Upstream has no separate ExifTool::
-- SetNewValue -- SetNewValue lives in Image::ExifTool::Writer -- so this is a
-- thin alias for the faithful Writer.SetNewValue port (Writer.lua). The CLI
-- (main.lua), the test harness and SetNewValuesFromFile all call through this
-- method, so keeping it on ExifTool preserves those call sites unchanged.
function ExifTool:SetNewValue(tag, value, opts)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetNewValue', self, tag, value, opts)
end

-- Save new values for subsequent restore
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:SaveNewValues()
    return ExifTool.DoAutoLoad('Image::ExifTool::SaveNewValues', self)
end

-- Restore new values to last saved state
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:RestoreNewValues()
    return ExifTool.DoAutoLoad('Image::ExifTool::RestoreNewValues', self)
end

-- Get new value(s) for tag
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua, which
--  returns the new value hash as second result and takes `wantarray`)
function ExifTool:GetNewValue(tag, wantarray)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetNewValue', self, tag, wantarray)
end

-- Validate an image for writing (upstream Writer.pl CheckImage), likewise a
-- thin alias; WriteCheck calls it as `$self->CheckImage(\$val)`.
function ExifTool:CheckImage(valPtr)
    return ExifTool.DoAutoLoad('Image::ExifTool::CheckImage', self, valPtr)
end

-- Count the number of new values set. Upstream has this in Writer.pl, so this
-- is the same thin alias pattern as SetNewValue above.
-- Returns: 0) number of new values, 1) number of WritePseudo tags among them
function ExifTool:CountNewValues()
    return ExifTool.DoAutoLoad('Image::ExifTool::CountNewValues', self)
end

-- Set the filesystem time from the FileModifyDate tag (upstream Writer.pl
-- SetFileModifyDate), likewise a thin alias.
function ExifTool:SetFileModifyDate(file, originalTime, tag, isUnixTime)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetFileModifyDate', self, file, originalTime, tag, isUnixTime)
end

-- Set file permissions, group/user id and various MDItem tags from new tag
-- values (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:SetSystemTags(file)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetSystemTags', self, file)
end

-- Check to see if these are the same file
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:IsSameFile(file, file2)
    return ExifTool.DoAutoLoad('Image::ExifTool::IsSameFile', self, file, file2)
end

-- Change file name and/or directory from the FileName and Directory tags
-- (upstream Writer.pl SetFileName), likewise a thin alias.
function ExifTool:SetFileName(file, newName, opt, usedFlag)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetFileName', self, file, newName, opt, usedFlag)
end

-- Maintain backward compatibility for old GetNewValues function name
-- (upstream Writer.pl GetNewValues; the exiftool script calls it by this name)
function ExifTool:GetNewValues(tag, wantarray)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetNewValues', self, tag, wantarray)
end

-- Check to see if a tag is writable (upstream Writer.pl IsWritable)
-- Returns: true if writable, 0 if not writable, undef if unknown tag
function ExifTool.IsWritable(tag)
    return ExifTool.DoAutoLoad('Image::ExifTool::IsWritable', tag)
end

-- Get list of tag names (upstream Writer.pl GetAllTags, one of the :Public
-- functions the exiftool script imports)
-- Inputs: 0) [optional] group from which tags are required
-- Returns: tag list (sorted alphabetically)
function ExifTool.GetAllTags(group)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetAllTags', group)
end

-- Get list of writable tag names (upstream Writer.pl GetWritableTags, :Public)
-- Inputs: 0) [optional] group from which writable tags are required
-- Returns: tag list (sorted alphabetically)
function ExifTool.GetWritableTags(group)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetWritableTags', group)
end

-- Get list of all group names (upstream Writer.pl GetAllGroups, :Public; the
-- exiftool script calls it as a method, `$mt->GetAllGroups($family)`)
-- Inputs: 0) [optional] ExifTool ref, 1) Group family number
-- Returns: List of group names (sorted alphabetically)
function ExifTool:GetAllGroups(family)
    return ExifTool.DoAutoLoad('Image::ExifTool::GetAllGroups', self, family)
end

--------------------------------------------------------------------------------
-- Encode file name for calls to system i/o routines
-- Inputs: 0) ExifTool ref, 1) file name in CharsetFileName encoding,
--         2) flag to force conversion even if no special characters
-- Returns: true if Windows Unicode routines should be used (in which case
--          the file name will be encoded as a null-terminated UTF-16LE string)
-- (upstream recodes the name in place, `$_[1] = ...`; here the possibly
--  recoded name is the second return value. A true first value means the
--  caller should use the Windows wide calls; this port's lexiftool.sys
--  functions take UTF-8 and widen it themselves, so the wide name is UTF-8
--  rather than UTF-16LE.)
function ExifTool:EncodeFileName(file, force)
    if file == '-' then return 0, file end   -- special case for stdin pipe
    local enc = self.OPTIONS.CharsetFileName
    local hasSpecialChars
    if perl.isMatch(file, [=[[\x80-\xff]]=]) then
        hasSpecialChars = 1
        if not perlTruthy(enc) and perl.osname() == 'MSWin32' then
            if ExifTool.IsUTF8(file) < 0 then
                if enc == nil then self:Warn('FileName encoding must be specified') end
                return 0, file
            else
                enc = 'UTF8'  -- assume UTF8
            end
        end
    end
    if hasSpecialChars or force or perlTruthy(self.OPTIONS.WindowsLongPath) or
        perlTruthy(self.OPTIONS.WindowsWideFile)
    then
        if not perlTruthy(enc) then enc = 'UTF8' end
        if perl.osname() == 'MSWin32' then
            -- (Win32API::File is lexiftool.sys here, always present)
            if perlTruthy(self.OPTIONS.WindowsLongPath) then file = self:WindowsLongPath(file) end
            -- recode as UTF-8 (upstream: UTF-16LE plus a null terminator;
            -- lexiftool.sys takes UTF-8 and widens it itself)
            if enc ~= 'UTF8' then file = self:Decode(file, enc, nil, 'UTF8') end
            return 1, file
        elseif enc ~= 'UTF8' then
            -- recode as UTF-8 for other platforms if necessary
            file = self:Decode(file, enc, nil, 'UTF8')
        end
    end
    return 0, file
end

--------------------------------------------------------------------------------
-- Rebuild a path as an absolute long path to be usable in Windows system calls
-- Inputs: 0) ExifTool ref, 1) path string (CharsetFileName)
-- Returns: normalized long path (CharsetFileName)
-- Note: this should only be called for Windows systems
-- References:
-- - https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats
-- - https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
-- GetFullPathName supported by Windows XP and later. It handles:
-- full path names                EG: c:\foto\sub\abc.jpg
-- relative                       EG: .\abc.jpg,  ..\abc.jpg
-- full UNC paths                 EG: \\server\share\abc.jpg
-- relative UNC paths             EG: .\abc.jpg,  ..\abc.jpg
-- Dos device paths               EG: \\.\c:\fotoabc.jpg
-- relative path on other drives  EG: z:abc.jpg (working dir on z: z:\foto called from c:\foto)
-- Wide chars                     EG: Chars that need UTF8.
-- (port: Win32::API's GetFullPathNameW is lexiftool.sys.get_full_path_name,
--  the same call made natively)
local k32GetFullPathName
function ExifTool:WindowsLongPath(path)
    local debug = self.OPTIONS.Debug
    local out = self.OPTIONS.TextOut
    local suffix = ''
    local longPath

    -- remove common suffixes to make cache more effective
    local found, sfx = perl.isMatch(path, [[(_original|_exiftool_tmp|:Zone\.Identifier)$]])
    if found then
        path = perl.subst(path, [[(_original|_exiftool_tmp|:Zone\.Identifier)$]], '')
        suffix = sfx
        if #path == 0 or perl.isMatch(path, [=[[:./\\]$]=]) then
            -- don't remove suffix if it could be the whole file name
            path = path .. suffix
            suffix = ''
        end
    end
    if self.LONG_PATH_IN ~= nil and self.LONG_PATH_IN == path then return self.LONG_PATH_OUT .. suffix end

    if perlTruthy(debug) then out:write('WindowsLongPath input : ' .. path .. suffix .. '\n') end

    repeat -- (cheap goto)
        longPath = perl.tr(path, '/', [[\\]]) -- convert slashes to backslashes
        if perl.isMatch(longPath, [[^\\\\\?\\]]) then break end   -- already a device path in the format we want

        if not perlTruthy(k32GetFullPathName) then  -- need to import (once) GetFullPathNameW
            if k32GetFullPathName ~= nil then break end
            k32GetFullPathName = sys.get_full_path_name -- lexiftool.sys, native
            if not k32GetFullPathName then
                k32GetFullPathName = 0
                self:Warn('Install Win32::API to use WindowsLongPath option')
                break
            end
        end
        local enc = perlTruthy(self.OPTIONS.CharsetFileName) and self.OPTIONS.CharsetFileName or 'UTF8'
        local encPath = longPath -- lexiftool.sys takes and returns UTF-8
        if enc ~= 'UTF8' then encPath = self:Decode(longPath, enc, nil, 'UTF8') end
        local fullPath = k32GetFullPathName(encPath)
        if not fullPath then break end  -- (port: a failed call returns nil; upstream decodes the empty buffer)
        longPath = enc ~= 'UTF8' and self:Decode(fullPath, 'UTF8', nil, enc) or fullPath

        if #longPath <= 247 - #suffix then break end

        if perl.isMatch(longPath, [[^\\\\]]) then
            longPath = '\\\\?\\UNC' .. substr(longPath, 1)
        else
            longPath = '\\\\?\\' .. longPath
        end
    until true
    -- this may be called repeatedly for the same file file (exists, stat, open),
    -- so cache the last return value (without any of the suffixes that we use)
    self.LONG_PATH_IN = path
    self.LONG_PATH_OUT = longPath
    if perlTruthy(debug) then out:write('WindowsLongPath return: ' .. longPath .. suffix .. '\n') end
    return longPath .. suffix
end

--------------------------------------------------------------------------------
-- Modified perl open() routine to properly handle special characters in file names
-- Inputs: 0) ExifTool ref, 1) filehandle, 2) filename,
--         3) mode: '<' or undef = read, '>' = write, '+<' = update
-- Returns: true on success
-- Note: Must call like "$et->Open(\*FH,$file)", not "$et->Open(FH,$file)" to avoid
--       "unopened filehandle" errors due to a change in scope of the filehandle
-- (Lua cannot fill a filehandle argument: the handle is returned instead, so
--  input 1 is dropped. The Windows Unicode branch is lexiftool.sys.open,
--  which makes upstream's CreateFileW/OsFHandleOpenFd calls with the same
--  access, share and creation flags.)
local openMode = { ['<'] = 'rb', ['>'] = 'wb', ['>>'] = 'ab', ['+<'] = 'r+b' }
function ExifTool:Open(file, mode)

    file = perl.subst(file, [[^([\s&])]], './$1') -- protect leading whitespace or ampersand
    -- default to read mode ('<') unless input is a trusted pipe
    if not mode then
        mode = (perl.isMatch(file, [[\|$]]) and self.TRUST_PIPE) and '' or '<'
    end
    self.TRUST_PIPE = nil
    if mode ~= '' then
        -- (upstream's two-argument open: "<-" is STDIN and ">-" STDOUT)
        if file == '-' then
            if mode == '<' then return io.stdin end
            if mode == '>' then return io.stdout end
        end
        local wide
        wide, file = self:EncodeFileName(file)
        if perlTruthy(wide) then
            -- handle Windows Unicode file name
            return sys.open(file, mode)
        end
        return io.open(file, openMode[mode] or 'rb')
    end
    return io.popen(perl.subst(file, [[\|$]], ''), 'r')
end

--------------------------------------------------------------------------------
-- Check to see if a file exists (with Windows Unicode support)
-- Inputs: 0) ExifTool ref, 1) file name, 2) flag if we are writing this file
-- Returns: true if file exists
-- (Lua: returns true/false, since a Perl 0 would be true in Lua)
function ExifTool:Exists(file, writing)
    local wide
    wide, file = self:EncodeFileName(file)
    if perlTruthy(wide) then
        -- (Win32API::File::CreateFileW($file, GENERIC_READ, FILE_SHARE_READ,
        --  [], OPEN_EXISTING, 0, []) + CloseHandle: false for a directory too)
        local wh = sys.create_file_read(file)
        if not wh then return false end
    elseif writing then
        -- (named pipes already exist, but we pretend that they don't
        --  so we will be able to write them, so test for pipe with -p)
        return perl.filetest('e', file) and not perl.filetest('p', file)
    else
        return perl.filetest('e', file)
    end
    return true
end

--------------------------------------------------------------------------------
-- Return true if file is a directory (with Windows Unicode support)
-- Inputs: 0) ExifTool ref, 1) file name
-- Returns: true if file is a directory (false if file isn't, or doesn't exist)
-- (Win32API::File::FILE_ATTRIBUTE_DIRECTORY, winnt.h)
local FILE_ATTRIBUTE_DIRECTORY = 0x10
function ExifTool.IsDirectory(et, file)
    local wide
    wide, file = et:EncodeFileName(file)
    if perlTruthy(wide) then
        local attrs = sys.get_file_attributes(file)
        local dirBit = FILE_ATTRIBUTE_DIRECTORY
        if attrs and attrs ~= 0xffffffff and attrs & dirBit ~= 0 then return true end
    else
        return perl.filetest('d', file)
    end
    return false
end

--------------------------------------------------------------------------------
-- Create the directory for the specified file (upstream ExifTool.pm
-- CreateDirectory)
-- Inputs: 0) ExifTool ref, 1) complete file name including path
-- Returns: nil if there was nothing to create, '' if a directory was created,
--          or an error string
function ExifTool:CreateDirectory(file)
    local err, dir
    dir = file:gsub('[^/]*$', '') -- remove filename from path specification
    if dir ~= '' and not self:IsDirectory(dir) then
        local parts = perl.split('/', dir, -1)
        dir = ''
        for _, part in ipairs(parts) do
            dir = dir .. part
            if #part > 0 and not self:IsDirectory(dir) and
                -- don't try to create a network drive root directory
                not (ExifTool.IsPC() and perl.isMatch(dir, '^//[^/]*$'))
            then
                -- create directory since it doesn't exist
                if not perl.mkdir(dir, 511) then   -- 0777 (wide on Windows)
                    err = 'Error creating directory ' .. dir
                    break
                end
                err = ''
            end
            dir = dir .. '/'
        end
    end
    return err
end

--------------------------------------------------------------------------------
-- Get file times
-- Inputs: 0) ExifTool ref, 1) file name or ref
-- Returns: 0) access time, 1) modification time, 2) creation time (or undefs on error)
-- (Lua: a ref is an open Lua file; Perl's `stat` of a handle has no
--  luafilesystem counterpart, so the fallback stats the name -- for a file
--  passed in as a handle there is none, and nothing is returned)
local k32GetFileTime    -- (Win32::API GetFileTime is lexiftool.sys.get_file_time)
function ExifTool:GetFileTime(file)
    local name = type(file) == 'string' and file or nil  -- (port: for the stat below)
    local fh

    -- open file by name if necessary
    if type(file) == 'string' then
        fh = self:Open(file)
        if not fh then
            if self:IsDirectory(file) then
                local st = perl.stat(file)
                if st and st.atime ~= nil then return st.atime, st.mtime, st.ctime end
            end
            self:Warn("GetFileTime error for '" .. file .. "'")
            return
        end
        file = fh   -- (port: closed below, where upstream's *FH goes out of scope)
    end
    -- on Windows, try to work around incorrect file times when daylight saving time is in effect
    if perl.osname() == 'MSWin32' then
        -- (Win32::API and Win32API::File are lexiftool.sys here, always present)
        -- get Win32 handle, needed for GetFileTime
        if io.type(file) ~= 'file' then
            self:Warn("Win32API::File::GetOsFHandle returned invalid handle")
            return
        end
        -- get FILETIME structs
        if not k32GetFileTime then k32GetFileTime = sys.get_file_time end
        local atime, mtime, ctime = k32GetFileTime(file)
        if fh and name ~= '-' then fh:close() end
        if atime == nil then
            self:Warn("Win32::API GetFileTime returned " .. perl.str(ctime))
            return
        end
        -- (FILETIME structs converted to Unix seconds by lexiftool.sys)
        return atime, mtime, ctime
    end
    if fh and name ~= '-' then fh:close() end
    -- other os (or Windows fallback)
    local st = name and perl.stat(name)
    if not st then return end
    return st.atime, st.mtime, st.ctime
end

--------------------------------------------------------------------------------
-- Set file times (Unix seconds since the epoch)
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:SetFileTime(file, atime, mtime, ctime, noWarn)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetFileTime', self, file, atime, mtime, ctime, noWarn)
end

-- Inputs: 0) ExifTool ref, 1) tag name
-- Returns: true if SetNewValue was called for this tag (even to delete it)
function ExifTool:IsNewValueSet(tag)
    for _, tagInfo in ipairs(require('lexiftool.TagLookup').FindTagInfo(tag)) do
        if self.NEW_VALUE and self.NEW_VALUE[tagInfo] then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Expand shortcuts
-- Inputs: 0) reference to list of tags, 1) set to remove trailing '#'
-- Notes: Handles leading '-' for excluded tags, trailing '#' for ValueConv,
--        multiple group names, and redirected tags
-- (upstream ExifTool.pm:5668; the list is rewritten in place as upstream's
--  `@$tagList = @expandedTags`, and also returned for convenience)
function ExifTool.ExpandShortcuts(tagList, removeSuffix)
    if not (tagList and #tagList > 0) then return tagList end

    local Shortcuts = require('lexiftool.Shortcuts')

    -- (upstream: `grep /^\Q$tag\E$/i, keys %Image::ExifTool::Shortcuts::Main`)
    local function findShortcut(name)
        local lcName = lc(name)
        for k in pairs(Shortcuts.Main) do
            if lc(k) == lcName then return k end
        end
        return nil
    end

    -- expand shortcuts
    local suffix = removeSuffix and '' or '#'
    local expandedTags = {}
    for _, entry in ipairs(tagList) do
        -- skip things like options hash references in list
        if type(entry) ~= 'string' then
            expandedTags[#expandedTags + 1] = entry
            goto nextEntry
        end
        do
            -- remove leading '-'
            local excl, tag = perl.matches(entry, '(?s)^(-?)(.*)')
            local post, pre, v
            local post2 = {}
            -- handle redirection
            local t1, p1
            if excl == '' then t1, p1 = perl.matches(tag, '(?s)(.+?)([-+]?[<>].+)') end
            if t1 then
                tag, post = t1, p1
                if perl.matches(post, '^[-+]?>') or not perl.matches(post, [[\$]]) then
                    -- expand shortcuts in postfix (rhs of redirection)
                    local op, p2, t2 = perl.matches(post, '([-+]?[<>])(.+:)?(.+)')
                    if not p2 then p2 = '' end
                    if perl.matches(t2, '#$') then  -- ValueConv suffix
                        t2 = perl.subst(t2, '#$', '')
                        v = suffix
                    else
                        v = ''
                    end
                    local match = findShortcut(t2)
                    if match then
                        for _, st in ipairs(Shortcuts.Main[match]) do
                            if not perl.matches(st, '^-') then  -- ignore excluded tags
                                if p2 ~= '' and perl.matches(st, '(.+:)(.+)') then
                                    post2[#post2 + 1] = op .. st .. v
                                else
                                    post2[#post2 + 1] = op .. p2 .. st .. v
                                end
                            end
                        end
                        if #post2 == 0 then goto nextEntry end
                        post = table.remove(post2, 1)
                    end
                end
            else
                post = ''
            end
            -- handle group names
            local g, t = perl.matches(tag, '(?s)(.+:)(.+)')
            if g then
                pre, tag = g, t
            else
                pre = ''
            end
            if perl.matches(tag, '#$') then  -- ValueConv suffix
                tag = perl.subst(tag, '#$', '')
                v = suffix
            else
                v = ''
            end
            -- loop over all postfixes
            while true do
                -- expand the tag name
                local match = findShortcut(tag)
                if match then
                    if excl ~= '' then
                        -- entry starts with '-', so exclude all tags in this shortcut
                        for _, st in ipairs(Shortcuts.Main[match]) do
                            if not perl.matches(st, '^-') then  -- ignore excluded exclude tags
                                -- group of expanded tag takes precedence
                                if pre ~= '' and perl.matches(st, '(.+:)(.+)') then
                                    expandedTags[#expandedTags + 1] = excl .. st
                                else
                                    expandedTags[#expandedTags + 1] = excl .. pre .. st
                                end
                            end
                        end
                    elseif #pre > 0 or #post > 0 or v ~= '' then
                        for _, st in ipairs(Shortcuts.Main[match]) do
                            local m1, m2, m3 = perl.matches(st, '(-?)(.+:)?(.+)')
                            if m2 then
                                -- group from expanded tag takes precedence
                                expandedTags[#expandedTags + 1] = st .. v .. post
                            else
                                expandedTags[#expandedTags + 1] = m1 .. pre .. m3 .. v .. post
                            end
                        end
                    else
                        for _, st in ipairs(Shortcuts.Main[match]) do
                            expandedTags[#expandedTags + 1] = st
                        end
                    end
                else
                    expandedTags[#expandedTags + 1] = excl .. pre .. tag .. v .. post
                end
                if #post2 == 0 then break end
                post = table.remove(post2, 1)
            end
        end
        ::nextEntry::
    end
    for k = #tagList, 1, -1 do tagList[k] = nil end
    for k, t in ipairs(expandedTags) do tagList[k] = t end
    return tagList
end

-- set new values from information in specified file
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:SetNewValuesFromFile(srcFile, ...)
    return ExifTool.DoAutoLoad('Image::ExifTool::SetNewValuesFromFile', self, srcFile, ...)
end

--------------------------------------------------------------------------------
-- WriteJPEG : Write JPEG image
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:WriteJPEG(dirInfo)
    return ExifTool.DoAutoLoad('Image::ExifTool::WriteJPEG', self, dirInfo)
end

-- Rewrite a TIFF file: the write branch of upstream ExifTool.pm
-- DoProcessTIFF (`if ($outfile)`), which ProcessTIFF takes when dirInfo
-- carries an OutFile (WriteInfo for TIFF/ORF/RAW files). The TIFF header +
-- IFD0 + sub-IFDs are rewritten by the generic WriteExif engine and the image
-- data blocks -- strips/tiles -- are copied after the directory data.
-- Inputs: 0) ExifTool ref, 1) dirInfo (RAF, OutFile)
-- Returns: 1 on success, 0 if this wasn't a valid TIFF file, -1 on error
function processTIFFWrite(self, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local data = raf:ReadFile()
    -- (upstream: a TIFF at $$dirInfo{Base} inside a bigger file -- the
    --  preview of a DOS EPS -- has the bytes before it written to the output
    --  first, and its offsets count from Base; the port writes it from a
    --  reader over the bytes from Base on, which also stands in for
    --  $$self{RAF} while the image data is copied)
    local base = dirInfo.Base or 0
    if base ~= 0 then
        if #data < base then return 0 end
        if not require('lexiftool.Writer').Write(outfile, data:sub(1, base)) then return -1 end
        local subInfo = { }
        for k, v in pairs(dirInfo) do subInfo[k] = v end
        subInfo.Base = nil
        subInfo.RAF = RandomAccess.new(data:sub(base + 1))
        local oldRAF = self.RAF
        self.RAF = subInfo.RAF
        local rtn = processTIFFWrite(self, subInfo)
        self.RAF = oldRAF
        return rtn
    end
    if not data or #data < 8 then
        if (data and #data > 0) or not outfile or dirInfo.Parent ~= 'EXIF' then return 0 end
        -- create EXIF file from scratch
        -- (upstream: delete $$self{EXIF_DATA}; undef $raf -- and the header
        --  comes from SetPreferredByteOrder below)
        if require('lexiftool.Writer').SetPreferredByteOrder(self) == 'MM' then
            data = "MM\0\x2a\0\0\0\x08"
        else
            data = "II\x2a\0\x08\0\0\0"
        end
        raf = nil
    end
    local savedOrder = currentByteOrder
    if not ExifTool.SetByteOrder(data:sub(1, 2)) then
        ExifTool.SetByteOrder(savedOrder)
        return 0
    end
    -- TIFF magic number (0x2a for plain TIFF; RW2/RWL and friends differ)
    local identifier = ExifTool.Get16u(data, 2)
    -- get offset to IFD0
    local offset = ExifTool.Get32u(data, 4)
    -- BigTIFF: upstream never gets here -- its write path dispatches on the
    -- type derived from the file NAME ('BTF'), which has no writer, so it
    -- reports the generic "not yet supported".  This port detects by content
    -- and would hand the file to the TIFF writer, so decline here with the
    -- same message.
    if identifier == 0x2b then
        ExifTool.SetByteOrder(savedOrder)
        self:Error('Writing of BTF files is not yet supported')
        return 0
    end
    local fileType = dirInfo.Parent or ''
    -- check for canon or EXIF signature (upstream ExifTool.pm ProcessTIFF)
    -- (Canon CR2 images should have an offset of 16, but it may be
    --  greater if edited by PhotoMechanic)
    local canonSig
    local otherSig
    local panasonicRaw
    if identifier == 0x2a and offset >= 16 then
        local sig = data:sub(9, 16)
        if sig:sub(1, 4) == 'CR\2\0' or sig:sub(1, 4) == '\186\176\172\187' or sig == 'ExifMeta' then
            if sig == 'ExifMeta' then
                -- (upstream writes these back with the signature preserved in the
                --  header; that otherSig branch is not ported yet)
                ExifTool.SetByteOrder(savedOrder)
                self:Error('Writing this RAW TIFF format is not yet supported')
                return 0
            else
                fileType = (sig:sub(1, 2) == 'CR') and 'CR2' or 'Canon 1D RAW'
                canonSig = sig
            end
        end
    elseif identifier == 0x55 and perl.isMatch(fileType, [[^(RAW|RW2|RWL|TIFF)$]]) then
        -- panasonic RAW, RW2 or RWL file
        -- test for RW2/RWL magic number
        local magic = data:sub(9, 24)
        if offset >= 0x18 and magic == '\136\231\116\216\248\37\29\77\148\122\110\119\130\43\93\106' then
            if fileType ~= 'RWL' then fileType = 'RW2' end
            otherSig = magic -- save signature for writing
        else
            fileType = 'RAW'
        end
        panasonicRaw = true
    end
    -- we have a valid TIFF (or whatever) file
    if fileType ~= '' and not self.VALUE.FileType then
        local lookup = fileTypeLookup[fileType]
        if lookup and type(lookup) ~= 'table' then lookup = fileTypeLookup[lookup] end
        -- use file extension to pre-determine type if extension is TIFF-based or type is RAW
        local baseType = ''
        if lookup then baseType = type(lookup[1]) == 'table' and lookup[1][1] or lookup[1] end
        local t
        if baseType == 'TIFF' or perl.isMatch(fileType, 'RAW') then t = fileType end
        self:SetFileType(t)
    end
    -- remember where we found the TIFF data (APP1, APP3, TIFF, NEF, etc...)
    self.TIFF_TYPE = fileType
    local Writer = require('lexiftool.Writer')
    -- Panasonic RAW/RW2/RWL keeps IFD0 in its own table (upstream
    -- ExifTool.pm:8659) -- that is where RawDataOffset and its PanasonicHack
    -- offset pairing live, without which the raw data cannot be copied
    local tagTablePtr = self:GetTagTable(
        panasonicRaw and 'lexiftool.PanasonicRaw.Main'
        or 'lexiftool.Exif.Main')
    local err
    if dirInfo.NoTiffEnd then
        self.TIFF_END = nil
    else
        -- initialize TIFF_END so it will be updated by WriteExif()
        self.TIFF_END = 0
    end
    if canonSig then
        -- write Canon CR2 specially because it has a header we want to preserve,
        -- and possibly trailers added by the Canon utilities and/or PhotoMechanic
        local CanonRaw = require('lexiftool.CanonRaw')
        local rtn = CanonRaw.WriteCR2(self, {
            Base = 0,
            DataPt = data:sub(1, 16),
            DataLen = 16,
            DataPos = 0,
            DirStart = offset,
            DirLen = 16 - offset,
            RAF = raf,
            DirName = 'IFD0',
            Parent = self.TIFF_TYPE,
            ImageData = 'Main',
            OutFile = outfile,
        }, tagTablePtr)
        if rtn ~= 1 then err = 1 end
    else
        -- write TIFF header (8 bytes [plus optional signature] followed by IFD)
        if fileType == 'EXIF' then
            otherSig = 'ExifMeta' -- force this signature for all EXIF files
        elseif otherSig == nil then
            otherSig = ''
        end
        local hdrOffset = 8 + #otherSig
        -- construct tiff header
        local header = carray.new('char'):append(substr(data, 0, 4), ExifTool.Put32u(hdrOffset), otherSig)
        -- (upstream reads only the 8-byte header, plus the 8-byte signature of
        --  an offset-16 TIFF, into $$self{EXIF_DATA}; the IFDs come from $raf)
        local exifData = data:sub(1, (identifier == 0x2a and offset >= 16) and 16 or 8)
        local dirInfo2 = {
            Base     = 0,
            DataPt   = exifData,
            DataLen  = #exifData,
            DataPos  = 0,
            DirStart = offset,
            DirLen   = #exifData - offset,
            RAF      = raf,
            DirName  = 'IFD0',
            Parent   = fileType,
            ImageData= 'Main', -- set flag to get information to copy main image data later
            Multi    = dirInfo.Multi,
            NewDataPos = hdrOffset,
            HeaderPtr = header,
        }
        -- preserve padding between image data blocks in ORF images
        -- (otherwise dcraw has problems because it assumes fixed block spacing)
        if fileType == 'ORF' or identifier ~= 0x2a then dirInfo2.PreserveImagePadding = 1 end
        local newData = Writer.WriteDirectory(self, dirInfo2, tagTablePtr)
        if newData == nil then
            err = 1
        elseif #newData > 0 then
            -- update header length in case more was added
            local hdrLen = perl.length(header)
            if hdrLen ~= 8 then
                ExifTool.Set32u(header, 4, hdrLen)
                -- also update preview fixup if necessary
                local pi = self.PREVIEW_INFO
                if pi and pi.Fixup then pi.Fixup.Start = pi.Fixup.Start + hdrLen - 8 end
            end
            if not Writer.Write(outfile, header, newData) then err = 1 end
        end
        -- copy over image data now if necessary
        if type(dirInfo2.ImageData) == 'table' and not err then
            if Writer.CopyImageData(self, dirInfo2.ImageData, outfile) ~= 1 then err = 1 end
            dirInfo2.ImageData = nil
        end
    end
    ExifTool.SetByteOrder(savedOrder)
    -- make local copy of TIFF_END now (it may be reset when processing trailers)
    local tiffEnd = self.TIFF_END
    self.TIFF_END = nil

    -- rewrite trailers if they exist
    if raf and tiffEnd and tiffEnd ~= 0 and not err then
        local trailInfo
        if not raf:Seek(0, 2) then err = 1 end
        local extra = raf:Tell() - tiffEnd
        -- check for trailer and process if possible
        if extra > 12 then
            raf:Seek(tiffEnd, 0)   -- seek back to end of image
            trailInfo = self:IdentifyTrailer(raf)
            if trailInfo then
                trailInfo.OutFile = { value = carray.new('char') }  -- rewrite trailer(s)
                trailInfo.ScanForTrailer = 1        -- scan for AFCP if necessary
                self.TrailerStart = tiffEnd
                -- rewrite all trailers to buffer
                if perlTruthy(self:ProcessTrailers(trailInfo)) then
                    -- calculate unused bytes before trailer
                    extra = (trailInfo.DataPos or 0) - tiffEnd    -- (undef DataPos numifies to 0)
                else
                    trailInfo = nil
                    err = 1
                end
            end
        end
        -- ignore a single zero byte if used for padding
        if extra > 0 and tiffEnd % 2 == 1 then
            if not raf:Seek(tiffEnd, 0) then err = 1 end
            local n, buf = raf:Read(1)
            if n == 1 and buf == '\0' then extra = extra - 1; tiffEnd = tiffEnd + 1 end
        end
        if extra > 0 then
            local known = self.KnownTrailer
            if self.DEL_GROUP.Trailer and not known then
                self:VPrint(0, '  Deleting unknown trailer (' .. extra .. ' bytes)\n')
                self.CHANGED = (self.CHANGED or 0) + 1
            elseif known then
                self:VPrint(0, '  Copying ' .. known.Name .. ' (' .. extra .. ' bytes)\n')
                if not raf:Seek(tiffEnd, 0) then err = 1 end
                if not perlTruthy(Writer.CopyBlock(raf, outfile, extra)) then err = 1 end
            else
                if not raf:Seek(tiffEnd, 0) then err = 1 end
                -- preserve unknown trailer only if it contains non-null data
                -- (Photoshop CS adds a trailer with 2 null bytes)
                local n, buf = raf:Read(extra)
                if n ~= extra then
                    err = 1
                elseif buf:match('[^%z]') then
                    self:VPrint(0, '  Preserving unknown trailer (' .. extra .. ' bytes)\n')
                    if not Writer.Write(outfile, buf) then err = 1 end
                else
                    self:VPrint(0, '  Deleting blank trailer (' .. extra .. ' bytes)\n')
                end
            end
        end
        -- write trailer buffer if necessary
        if trailInfo and not perlTruthy(Writer.WriteTrailerBuffer(self, trailInfo, outfile)) then err = 1 end
        -- add any new trailers we are creating
        local trailPt = Writer.AddNewTrailers(self)
        if trailPt and not Writer.Write(outfile, trailPt.value) then err = 1 end
    end
    return err and -1 or 1
end

--------------------------------------------------------------------------------
-- Write information back to file
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:WriteInfo(infile, outfile, outType)
    return ExifTool.DoAutoLoad('Image::ExifTool::WriteInfo', self, infile, outfile, outType)
end

--------------------------------------------------------------------------------
-- Copy file attributes from one file to another
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:CopyFileAttrs(src, dst)
    return ExifTool.DoAutoLoad('Image::ExifTool::CopyFileAttrs', self, src, dst)
end

--------------------------------------------------------------------------------
-- Write TIFF as a directory
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:WriteTIFF(dirInfo, tagTablePtr)
    return ExifTool.DoAutoLoad('Image::ExifTool::WriteTIFF', self, dirInfo, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Add trailers as a block
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:AddNewTrailers(...)
    return ExifTool.DoAutoLoad('Image::ExifTool::AddNewTrailers', self, ...)
end

--------------------------------------------------------------------------------
-- Rename a file (with patch for Windows Unicode file names, and other problem)
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:Rename(old, new)
    return ExifTool.DoAutoLoad('Image::ExifTool::Rename', self, old, new)
end

--------------------------------------------------------------------------------
-- Delete a file (with patch for Windows Unicode file names)
-- (upstream AUTOLOADs it from Writer.pl; the body is in Writer.lua)
function ExifTool:Unlink(...)
    return ExifTool.DoAutoLoad('Image::ExifTool::Unlink', self, ...)
end

return ExifTool
