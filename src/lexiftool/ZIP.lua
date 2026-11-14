--------------------------------------------------------------------------------
-- File:         lexiftool/ZIP.lua
-- Ported from:  lib/Image/ExifTool/ZIP.pm
--
-- Description:  Read ZIP archive meta information
--
-- Revisions:    10/28/2007 - P. Harvey Created
--
-- References:   1) http://www.pkware.com/documents/casestudies/APPNOTE.TXT
--               2) http://www.cpanforum.com/threads/9046
--               3) http://www.gzip.org/zlib/rfc-gzip.html
--               4) http://DataCompression.info/ArchiveFormats/RAR202.txt
--               5) https://jira.atlassian.com/browse/CONF-21706
--               6) http://wwwimages.adobe.com/www.adobe.com/content/dam/Adobe/en/devnet/indesign/cs55-docs/IDML/idml-specification.pdf
--               7) https://www.rarlab.com/technote.htm
--
-- Port notes:   Archive::Zip is the Lua stand-in ArchiveZip.lua (see its own
--               Notes), which perl.evalRequire('Archive::Zip') loads; with it
--               member data is decompressed and the CaptureOne/iWork/OOXML/
--               OpenDocument/EPUB sub-parsers are reached, as upstream does
--               when the module is installed. IO::String (a ZIP read from a
--               pipe or a scalar reference) is a RandomAccess object over
--               the slurped buffer, also through perl.evalRequire.
--               Archive::Zip issues no warnings here, so WarnProc stays
--               unused.
--               ProcessGZIP and ProcessRAR are ported in full (RAR v4 and
--               v5/7z).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local matches = perl.matches
local sprintf = perl.sprintf
local perlStr = perl.str
local RandomAccess = require('lexiftool.RandomAccess')
local lc = perl.lc
local ord = perl.ord
local isMatch = perl.isMatch
local subst = perl.subst
local unpack = perl.unpack
local pack = perl.pack
local perlTruthy = perl.truthy
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder = ExifTool.SetByteOrder
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local AddTagToTable = ExifTool.AddTagToTable
local D = perl.D
local length = perl.length
local ucfirst = perl.ucfirst
local evalRequire = perl.evalRequire

local ZIP = {}

-- (port helper: copy the shared hash into the entry, as Perl's `%hash`
--  spread does)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

-- (upstream keeps the Archive::Zip warning in a file-scope $warnString that
--  ProcessZIP reads back; nothing in the ported path needs the text, but the
--  handler has to exist so the warnings stay caught)
-- luacheck: push ignore
local warnString
-- luacheck: pop
function ZIP.WarnProc(str) warnString = str end

-- file types for recognized Open Document "mimetype" values
local openDocType = {
    ['application/vnd.oasis.opendocument.database']     = 'ODB', --5
    ['application/vnd.oasis.opendocument.chart']        = 'ODC', --5
    ['application/vnd.oasis.opendocument.formula']      = 'ODF', --5
    ['application/vnd.oasis.opendocument.graphics']     = 'ODG', --5
    ['application/vnd.oasis.opendocument.image']        = 'ODI', --5
    ['application/vnd.oasis.opendocument.presentation'] = 'ODP',
    ['application/vnd.oasis.opendocument.spreadsheet']  = 'ODS',
    ['application/vnd.oasis.opendocument.text']         = 'ODT',
    ['application/vnd.adobe.indesign-idml-package']     = 'IDML', --6 (not open doc)
    ['application/epub+zip'] = 'EPUB', --PH (not open doc)
}

-- iWork file types based on names of files found in the zip archive
local iWorkFile = {
    ['Index/Slide.iwa'] = 'KEY',
    ['Index/Tables/DataList.iwa'] = 'NUMBERS',
}

local iWorkType_h = {
    NUMBERS = 'NUMBERS',
    PAGES   = 'PAGES',
    KEY     = 'KEY',
    KTH     = 'KTH',
    NMBTEMPLATE = 'NMBTEMPLATE',
}

-- ZIP metadata blocks
ZIP.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int16u',
    NOTES = [[
        The following tags are extracted from ZIP archives.  ExifTool also extracts
        additional meta information from compressed documents inside some ZIP-based
        files such Office Open XML (DOCX, PPTX and XLSX), Open Document (ODB, ODC,
        ODF, ODG, ODI, ODP, ODS and ODT), iWork (KEY, PAGES, NUMBERS), Capture One
        Enhanced Image Package (EIP), Adobe InDesign Markup Language (IDML),
        Electronic Publication (EPUB), and Sketch design files (SKETCH).  The
        ExifTool family 3 groups may be used to organize ZIP tags by embedded
        document number (ie. the exiftool C<-g3> option).
    ]],
    [2] = 'ZipRequiredVersion',
    [3] = {
        Name = 'ZipBitFlag',
        PrintConv = function(_self, val) if perlTruthy(val) then return sprintf('0x%.4x', val) end return val end,
    },
    [4] = {
        Name = 'ZipCompression',
        PrintConv = {
            [0] = 'None',
            [1] = 'Shrunk',
            [2] = 'Reduced with compression factor 1',
            [3] = 'Reduced with compression factor 2',
            [4] = 'Reduced with compression factor 3',
            [5] = 'Reduced with compression factor 4',
            [6] = 'Imploded',
            [7] = 'Tokenized',
            [8] = 'Deflated',
            [9] = 'Enhanced Deflate using Deflate64(tm)',
            [10] = 'Imploded (old IBM TERSE)',
            [12] = 'BZIP2',
            [14] = 'LZMA (EFS)',
            [18] = 'IBM TERSE (new)',
            [19] = 'IBM LZ77 z Architecture (PFS)',
            [96] = 'JPEG recompressed',
            [97] = 'WavPack compressed',
            [98] = 'PPMd version I, Rev 1',
        },
    },
    [5] = {
        Name = 'ZipModifyDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                (val >> 25) + 1980, -- year
                (val >> 21) & 0x0f, -- month
                (val >> 16) & 0x1f, -- day
                (val >> 11) & 0x1f, -- hour
                (val >> 5) & 0x3f, -- minute
                (val & 0x1f) * 2 -- second
            )
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [7] = { Name = 'ZipCRC', Format = 'int32u', PrintConv = function(_self, val) return sprintf('0x%.8x', val) end },
    [9] = { Name = 'ZipCompressedSize', Format = 'int32u' },
    [11] = { Name = 'ZipUncompressedSize', Format = 'int32u' },
    [13] = {
        Name = 'ZipFileNameLength',
        Hidden = 1,
        RawConv = function(self, val) self.ZipFileNameLength = val return nil end,
    },
    -- 14 => ZipExtraFieldLength
    [15] = {
        Name = 'ZipFileName',
        Format = 'string[$$self{ZipFileNameLength}]',
    },
    _com = 'ZipFileComment',
}

-- GNU ZIP tags (ref 3)
ZIP.GZIP = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    NOTES = [[
        These tags are extracted from GZIP (GNU ZIP) archives, but currently only
        for the first file in the archive.
    ]],
    [2] = {
        Name = 'Compression',
        PrintConv = { [8] = 'Deflated' },
    },
    [3] = {
        Name = 'Flags',
        PrintConv = { BITMASK = {
            [0] = 'Text',
            [1] = 'CRC16',
            [2] = 'ExtraFields',
            [3] = 'FileName',
            [4] = 'Comment',
        } },
    },
    [4] = {
        Name = 'ModifyDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [8] = {
        Name = 'ExtraFlags',
        PrintConv = {
            [0] = '(none)',
            [2] = 'Maximum Compression',
            [4] = 'Fastest Algorithm',
        },
    },
    [9] = {
        Name = 'OperatingSystem',
        PrintConv = {
            [0] = 'FAT filesystem (MS-DOS, OS/2, NT/Win32)',
            [1] = 'Amiga',
            [2] = 'VMS (or OpenVMS)',
            [3] = 'Unix',
            [4] = 'VM/CMS',
            [5] = 'Atari TOS',
            [6] = 'HPFS filesystem (OS/2, NT)',
            [7] = 'Macintosh',
            [8] = 'Z-System',
            [9] = 'CP/M',
            [10] = 'TOPS-20',
            [11] = 'NTFS filesystem (NT)',
            [12] = 'QDOS',
            [13] = 'Acorn RISCOS',
            [255] = 'unknown',
        },
    },
    [10] = 'ArchivedFileName',
    [11] = 'Comment',
}

-- RAR v4 tags (ref 4)
ZIP.RAR = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    NOTES = 'These tags are extracted from RAR archive files.',
    [0] = { Name = 'CompressedSize', Format = 'int32u' },
    [4] = { Name = 'UncompressedSize', Format = 'int32u' },
    [8] = {
        Name = 'OperatingSystem',
        PrintConv = {
            [0] = 'MS-DOS',
            [1] = 'OS/2',
            [2] = 'Win32',
            [3] = 'Unix',
        },
    },
    [13] = {
        Name = 'ModifyDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                (val >> 25) + 1980, -- year
                (val >> 21) & 0x0f, -- month
                (val >> 16) & 0x1f, -- day
                (val >> 11) & 0x1f, -- hour
                (val >> 5) & 0x3f, -- minute
                (val & 0x1f) * 2 -- second
            )
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [18] = {
        Name = 'PackingMethod',
        PrintHex = 1,
        PrintConv = {
            [0x30] = 'Stored',
            [0x31] = 'Fastest',
            [0x32] = 'Fast',
            [0x33] = 'Normal',
            [0x34] = 'Good Compression',
            [0x35] = 'Best Compression',
        },
    },
    [19] = {
        Name = 'FileNameLength',
        Format = 'int16u',
        Hidden = 1,
        RawConv = function(self, val) self.FileNameLength = val return nil end,
    },
    [25] = {
        Name = 'ArchivedFileName',
        Format = 'string[$$self{FileNameLength}]',
    },
}

-- RAR v5 tags (ref 7, github#203)
ZIP.RAR5 = {
    GROUPS = { [2] = 'Other' },
    VARS = { ID_FMT = 'none' },
    FileVersion = {},
    CompressedSize = {},
    ModifyDate = {
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    UncompressedSize = {},
    OperatingSystem = {
        PrintConv = { [0] = 'Win32', [1] = 'Unix' },
    },
    ArchivedFileName = {},
}

--------------------------------------------------------------------------------
-- Read unsigned LEB (Little Endian Base) from a RandomAccess
-- Inputs: 0) RandomAccess ref
-- Returns: integer value
--------------------------------------------------------------------------------
local function ReadULEB(raf)
    local i, buff, n
    local rtnVal = 0
    i = 0
    while true do
        n, buff = raf:Read(1)
        if n == 0 then break end
        local num = ord(buff)
        rtnVal = rtnVal + ((num & 0x7f) << (i * 7))
        if num & 0x80 == 0 then break end
        i = i + 1
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Extract information from a RAR file
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid RAR file
--------------------------------------------------------------------------------
function ZIP.ProcessRAR(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, n
    local docNum = 0

    n, buff = raf:Read(7)
    if not (n ~= 0 and isMatch(buff, "Rar!\x1a\x07[\\0\x01]")) then return 0 end

    if buff == "Rar!\x1a\x07\0" then -- RARv4 (ref 4)

        et:SetFileType()
        SetByteOrder('II')
        local tagTablePtr = GetTagTable(nil, 'lexiftool.ZIP.RAR5')
        et:HandleTag(tagTablePtr, 'FileVersion', 'RAR v4')
        tagTablePtr = GetTagTable(nil, 'lexiftool.ZIP.RAR')

        while true do
            -- read block header
            n, buff = raf:Read(7)
            if n ~= 7 then break end
            local type_, flags, size = unpack('xxCvv', buff)
            size = size - 7
            if flags & 0x8000 ~= 0 then
                n, buff = raf:Read(4)
                if n ~= 4 then break end
                size = size + unpack('V',buff) - 4
            end
            if size < 0 then break end
            if size == 0 then goto next end  -- ignore blocks with no data
            -- don't try to read very large blocks unless LargeFileSupport is enabled
            if size >= 0x80000000 then
                if not perlTruthy(et:Options('LargeFileSupport')) then
                    et:Warn('Large block encountered. Aborting.')
                    break
                elseif perlStr(et:Options('LargeFileSupport')) == '2' then
                    et:Warn('Processing large block (LargeFileSupport is 2)')
                end
            end
            -- process the block
            if type_ == 0x74 then -- file block
                -- read maximum 4 KB from a file block
                local rn = size > 4096 and 4096 or size
                n, buff = raf:Read(rn)
                if n ~= rn then break end
                -- add compressed size to start of data so we can extract it with the other tags
                buff = pack('V',size) .. buff
                docNum = docNum + 1
                et.DOC_NUM = docNum
                et:ProcessDirectory({ DataPt = buff }, tagTablePtr)
                size = size - rn
            elseif type_ == 0x75 and size > 6 then -- comment block
                n, buff = raf:Read(size)
                if n ~= size then break end
                -- save comment, only if "Stored" (this is untested)
                if Get8u(buff, 3) == 0x30 then
                    et:FoundTag('Comment', substr(buff, 6))
                end
                goto next
            end
            -- seek to the start of the next block
            if size ~= 0 then
                if not raf:Seek(size, 1) then break end
            end
            ::next::
        end

    else -- RARv5 (ref 7, github#203)

        n, buff = raf:Read(1)
        if not (n ~= 0 and buff == "\0") then return 0 end
        et:SetFileType()
        local tagTablePtr = GetTagTable(nil, 'lexiftool.ZIP.RAR5')
        et:HandleTag(tagTablePtr, 'FileVersion', 'RAR v5')
        et.INDENT = et.INDENT .. '| '

        -- loop through header blocks
        while true do
            raf:Seek(4, 1)                   -- skip header CRC
            local headSize = ReadULEB(raf)
            if headSize == 0 then break end
            -- read the header and create new RAF object for reading it
            local header
            n, header = raf:Read(headSize)
            if n ~= headSize then break end
            local rafHdr = RandomAccess.new(header)
            local headType = ReadULEB(rafHdr)   -- get header type

            if headType == 4 then  -- encryption block
                et:Warn("File is encrypted.", 0)
                break
            end
            -- skip over all headers except file or service header
            if not (headType == 2 or headType == 3) then goto next end
            if headType == 2 then et:VerboseDir('RAR5 file', nil, headSize) end

            do
                local headFlag = ReadULEB(rafHdr)
                ReadULEB(rafHdr)                  -- skip extraSize
                local dataSize
                if headFlag & 0x0002 ~= 0 then
                    dataSize = ReadULEB(rafHdr)  -- compressed data size
                    if headType == 2 then
                        et:HandleTag(tagTablePtr, 'CompressedSize', dataSize)
                    else
                        raf:Seek(dataSize, 1)   -- skip service data section
                        goto next
                    end
                else
                    if headType == 3 then goto next end         -- all done with service header
                    dataSize = 0
                end
                local fileFlag = ReadULEB(rafHdr)
                local uncompressedSize = ReadULEB(rafHdr)
                if fileFlag & 0x0008 == 0 then et:HandleTag(tagTablePtr, 'UncompressedSize', uncompressedSize) end
                ReadULEB(rafHdr)                  -- skip file attributes
                if fileFlag & 0x0002 ~= 0 then
                    n, buff = rafHdr:Read(4)
                    if n ~= 4 then break end
                    -- (untested)
                    et:HandleTag(tagTablePtr, 'ModifyDate', (unpack('V', buff)))
                end
                if fileFlag & 0x0004 ~= 0 then rafHdr:Seek(4, 1) end  -- skip CRC if present

                ReadULEB(rafHdr)                  -- skip compressionInfo

                -- get operating system
                local os = ReadULEB(rafHdr)
                et:HandleTag(tagTablePtr, 'OperatingSystem', os)

                -- get filename
                n, buff = rafHdr:Read(1)
                if n ~= 1 then break end
                local nameLen = ord(buff)
                n, buff = rafHdr:Read(nameLen)
                if n ~= nameLen then break end
                buff = subst(buff, [[\0+$]], '')  -- remove trailing nulls (if any)
                et:HandleTag(tagTablePtr, 'ArchivedFileName', buff)

                docNum = docNum + 1
                et.DOC_NUM = docNum

                raf:Seek(dataSize, 1)           -- skip data section
            end
            ::next::
        end
        et.INDENT = substr(et.INDENT, 0, -2)
    end

    et.DOC_NUM = 0
    if docNum > 1 and not perlTruthy(et:Options('Duplicates')) then
        et:Warn("Use the Duplicates option to extract tags for all " .. docNum .. " files", 1)
    end

    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a GNU ZIP file (ref 3)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid GZIP file
--------------------------------------------------------------------------------
function ZIP.ProcessGZIP(et, dirInfo)
    local raf = dirInfo.RAF
    local flags, buff, n

    n, buff = raf:Read(10)
    if not (perlTruthy(n) and isMatch(buff, [[^\x1f\x8b\x08]])) then return 0 end

    et:SetFileType()
    SetByteOrder('II')

    local tagTablePtr = GetTagTable(nil, 'lexiftool.ZIP.GZIP')
    et:HandleTag(tagTablePtr, 2, Get8u(buff, 2))
    flags = Get8u(buff, 3)
    et:HandleTag(tagTablePtr, 3, flags)
    et:HandleTag(tagTablePtr, 4, Get32u(buff, 4))
    et:HandleTag(tagTablePtr, 8, Get8u(buff, 8))
    et:HandleTag(tagTablePtr, 9, Get8u(buff, 9))

    -- extract file name and comment if they exist
    if (flags & 0x18) ~= 0 then
        if (flags & 0x04) ~= 0 then
            -- skip extra field
            n, buff = raf:Read(2)
            if n ~= 2 then return 1 end
            local len = Get16u(buff, 0)
            n = raf:Read(len)   -- (upstream reads into $buff, replaced below)
            if n ~= len then return 1 end
        end
        n, buff = raf:Read(4096)
        if not perlTruthy(n) then return 1 end
        local pos = 0
        local posG = 0      -- (pos($buff) of the /g match below)
        -- loop for ArchivedFileName (10) and Comment (11) tags
        for _, tagID in ipairs({ 10, 11 }) do
            local mask = tagID == 10 and 0x08 or 0x10
            if (flags & mask) == 0 then goto next end
            local m, e = matches(buff, [[\0]], posG)
            local end_
            if m then end_ = e - 1; posG = e else end_ = length(buff); posG = 0 end
            -- (the doc specifies the string should be ISO 8859-1,
            -- but in OS X it seems to be UTF-8, so don't translate
            -- it because I could just as easily screw it up)
            local str = substr(buff, pos, end_ - pos)
            et:HandleTag(tagTablePtr, tagID, str)
            if end_ >= length(buff) then break end
            pos = end_ + 1
            ::next::
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Call HandleTags for attributes of an Archive::Zip member
-- Inputs: 0) ExifTool object ref, 1) member ref, 2) optional tag table ref
--------------------------------------------------------------------------------
function ZIP.HandleMember(et, member, tagTablePtr)
    if not tagTablePtr then tagTablePtr = GetTagTable(nil, 'lexiftool.ZIP.Main') end
    et:HandleTag(tagTablePtr, 2, member:versionNeededToExtract())
    et:HandleTag(tagTablePtr, 3, member:bitFlag())
    et:HandleTag(tagTablePtr, 4, member:compressionMethod())
    et:HandleTag(tagTablePtr, 5, member:lastModFileDateTime())
    et:HandleTag(tagTablePtr, 7, member:crc32())
    et:HandleTag(tagTablePtr, 9, member:compressedSize())
    et:HandleTag(tagTablePtr, 11, member:uncompressedSize())
    et:HandleTag(tagTablePtr, 15, member:fileName())
    local com = member:fileComment()
    if D(com) and perlTruthy(length(com)) then et:HandleTag(tagTablePtr, '_com', com) end
end

--------------------------------------------------------------------------------
-- Extract file from ZIP archive
-- Inputs: 0) ExifTool ref, 1) Zip object ref, 2) file name
-- Returns: zip member or undef it it didn't exist
--------------------------------------------------------------------------------
local function ExtractFile(et, zip, file)
    local result = zip:memberNamed(file)
    et:VPrint(1, "  (Extracting '" .. file .. "' from zip archive)\n")
    return result
end
ZIP.ExtractFile = ExtractFile

--------------------------------------------------------------------------------
-- Extract information from a ZIP file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid ZIP file
--------------------------------------------------------------------------------
function ZIP.ProcessZIP(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2, zip
    local n, status

    n, buff = raf:Read(30)
    if not (n == 30 and isMatch(buff, [[^PK\x03\x04]])) then return 0 end

    local tagTablePtr = GetTagTable(nil, 'lexiftool.ZIP.Main')
    local docNum = 0

    -- use Archive::Zip if available
    while true do -- luacheck: ignore 512 (single pass, as upstream)
        local haveZip, ArchiveZip = evalRequire('Archive::Zip')
        if not (haveZip and evalRequire('IO::File')) then
            if perlTruthy(et.FILE_EXT) and et.FILE_EXT ~= 'ZIP' then
                et:Warn("Install Archive::Zip to decode compressed ZIP information")
            end
            break
        end
        -- Archive::Zip requires a seekable IO::File object
        local fh
        if raf.TESTED >= 0 then
            if not evalRequire('IO::File') then
                -- (this shouldn't happen because IO::File is a prerequisite of Archive::Zip)
                et:Warn("Install IO::File to decode compressed ZIP information")
                break
            end
            raf:Seek(0, 0)
            fh = raf.FILE_PT
            -- (bless $fh, 'IO::File': ArchiveZip reads the file handle itself)
        elseif evalRequire('IO::String') then
            -- read the whole file into memory (what else can I do?)
            raf:Slurp()
            local _, IOString = evalRequire('IO::String')
            fh = IOString.new(raf.BUFF_PT)
        else
            local type_ = raf.FILE_PT and 'pipe or socket' or 'scalar reference'
            et:Warn("Install IO::String to decode compressed ZIP information from a " .. type_)
            break
        end
        et:VPrint(1, "  --- using Archive::Zip ---\n")
        zip = ArchiveZip.new()
        -- catch all warnings! (Archive::Zip is bad for this)
        -- (local $SIG{'__WARN__'} = \&WarnProc: ArchiveZip issues no warnings)
        status = zip:readFromFileHandle(fh)
        if perlStr(status) == '4' and raf.TESTED >= 0 and evalRequire('IO::String') and
            raf:Seek(0, 2) and raf:Tell() < 100000000
        then
            -- try again, reading it ourself this time in an attempt to avoid
            -- a failed test with Perl 5.6.2 GNU/Linux 2.6.32-5-686 i686-linux-64int-ld
            raf:Seek(0, 0)
            raf:Slurp()
            local _, IOString = evalRequire('IO::String')
            fh = IOString.new(raf.BUFF_PT)
            zip = ArchiveZip.new()
            status = zip:readFromFileHandle(fh)
        end
        if perlTruthy(status) then
            zip = nil
            local err_h = { [1] = 'Stream end error', [3] = 'Format error', [4] = 'IO error' }
            local err = err_h[status] or ("Error " .. perlStr(status))
            et:Warn(err .. " reading ZIP file")
            break
        end
        -- extract zip file comment
        local comment = zip:zipfileComment()
        if D(comment) and perlTruthy(length(comment)) then et:FoundTag('Comment', comment) end

        dirInfo.ZIP = zip

        -- check for an Office Open file (DOCX, etc)
        -- --> read '[Content_Types].xml' to determine the file type
        local mime, members
        local cType = ExtractFile(et, zip, '[Content_Types].xml')
        if cType then
            local found, _, g2
            buff, status = zip:contents(cType)
            if not perlTruthy(status) then
                -- luacheck: push no max line length
                -- first look for the main document with the expected name
                found, _, g2 = isMatch(buff, [==[\sPartName\s*=\s*['"](?:/ppt/presentation.xml|/word/document.xml|/xl/workbook.xml)['"][^>]*\sContentType\s*=\s*(['"])([^"']+)\.main(\+xml)?\1]==])
                -- luacheck: pop
                -- then look for the main part
                if not found then found, _, g2 = isMatch(buff, [==[<Override[^>]*\sPartName[^<]+\sContentType\s*=\s*(['"])([^"']+)\.main(\+xml)?\1]==]) end
                -- and if all else fails, use the default main
                if not found then found, _, g2 = isMatch(buff, [==[ContentType\s*=\s*(['"])([^"']+)\.main(\+xml)?\1]==]) end
            end
            if found then
                mime = g2
            end
        end
        -- check for docProps if we couldn't find a MIME type
        if not perlTruthy(mime) then members = zip:membersMatching('^docProps/.*\\.(xml|XML)$') end
        if perlTruthy(mime) or (members and #members > 0) then
            dirInfo.MIME = mime
            require('lexiftool.OOXML').ProcessDOCX(et, dirInfo)
            dirInfo.MIME = nil
            break
        end

        -- check for an EIP file
        members = zip:membersMatching('^CaptureOne/.*\\.(cos|COS)$')
        if #members > 0 then
            require('lexiftool.CaptureOne').ProcessEIP(et, dirInfo)
            break
        end

        -- check for an iWork file
        members = zip:membersMatching('(?i)^(index\\.(xml|apxl)|QuickLook/Thumbnail\\.jpg|[^/]+\\.(pages|numbers|key)/Index.(zip|xml|apxl))$')
        if #members > 0 then
            require('lexiftool.iWork').Process_iWork(et, dirInfo)
            break
        end

        -- check for an Open Document, IDML or EPUB file
        local mType = ExtractFile(et, zip, 'mimetype')
        if mType then
            local g1
            mime, status = zip:contents(mType)
            if not perlTruthy(status) then g1 = matches(mime, [[(?s)([\x21-\xfe]+)]]) end
            if g1 ~= nil then
                -- clean up MIME type just in case (note that MIME is case insensitive)
                mime = lc(g1)
                et:SetFileType(openDocType[mime] or 'ZIP', mime)
                if not openDocType[mime] then et:Warn("Unrecognized MIMEType " .. mime) end
                -- extract Open Document metadata from "meta.xml"
                local meta = ExtractFile(et, zip, 'meta.xml')
                -- IDML files have metadata in a different place (ref 6)
                if not meta then meta = ExtractFile(et, zip, 'META-INF/metadata.xml') end
                if meta then
                    buff, status = zip:contents(meta)
                    if not perlTruthy(status) then
                        local dirInfo_h = {
                            DirName = 'XML',
                            DataPt  = buff,
                            DirLen  = length(buff),
                            DataLen = length(buff),
                        }
                        -- (avoid structure warnings when copying from XML)
                        local oldWarn = et.NO_STRUCT_WARN
                        et.NO_STRUCT_WARN = 1
                        et:ProcessDirectory(dirInfo_h, GetTagTable(nil, 'lexiftool.XMP.Main'))
                        et.NO_STRUCT_WARN = oldWarn
                    end
                end
                -- process rootfile of EPUB container if applicable
                while true do -- luacheck: ignore 512 (single pass, as upstream)
                    if meta and mime ~= 'application/epub+zip' then break end
                    local container = ExtractFile(et, zip, 'META-INF/container.xml')
                    buff, status = zip:contents(container)
                    if perlTruthy(status) then break end
                    local found, _, g2 = isMatch(buff, [[(?s)<rootfile\s+[^>]*?\bfull-path=(['"])(.*?)\1]])
                    if not found then break end
                    -- load the rootfile data (OPF extension; contains XML metadata)
                    local meta2 = zip:memberNamed(g2)
                    if not meta2 then break end
                    meta = meta2
                    buff, status = zip:contents(meta)
                    if perlTruthy(status) then break end
                    -- use opf:event to generate more meaningful tag names for dc:date
                    while true do
                        local c1 = matches(buff, [[(?s)<dc:date opf:event="(\w+)">([^<]+)</dc:date>]])
                        if c1 == nil then break end
                        buff = subst(buff, [[(?s)<dc:date opf:event="(\w+)">([^<]+)</dc:date>]], '<dc:${1}Date>$2</dc:${1}Date>')
                        local dcTable = GetTagTable(nil, 'lexiftool.XMP.dc')
                        local tag = c1 .. "Date"
                        if not dcTable[tag] then
                            AddTagToTable(nil, dcTable, tag, spread(require('lexiftool.XMP').dateTimeInfo) {
                                Name = ucfirst(tag),
                                Groups = { [2] = 'Time' },
                                List = 'Seq',
                            })
                        end
                    end
                    local dirInfo_h = {
                        DataPt = buff,
                        DirLen = length(buff),
                        DataLen = length(buff),
                        IgnoreProp = { ['package'] = 1, metadata = 1 },
                    }
                    -- (avoid structure warnings when copying from XML)
                    local oldWarn = et.NO_STRUCT_WARN
                    et.NO_STRUCT_WARN = 1
                    et:ProcessDirectory(dirInfo_h, GetTagTable(nil, 'lexiftool.XMP.XML'))
                    et.NO_STRUCT_WARN = oldWarn
                    break
                end
                if openDocType[mime] or meta then
                    -- extract preview image(s) from "Thumbnails" directory if they exist
                    local tag = { jpg = 'PreviewImage', png = 'PreviewPNG' }
                    for _, type_ in ipairs({ 'jpg', 'png' }) do
                        local thumb = ExtractFile(et, zip, "Thumbnails/thumbnail." .. type_)
                        if not thumb then goto next end
                        buff, status = zip:contents(thumb)
                        if not perlTruthy(status) then et:FoundTag(tag[type_], buff) end
                        ::next::
                    end
                    break   -- all done since we recognized the MIME type or found metadata
                end
                -- continue on to list ZIP contents...
            end
        end

        -- otherwise just extract general ZIP information
        et:SetFileType()
        members = zip:members()
        local iWorkType
        -- special files to extract
        local extract = {
            ['meta.json'] = 1,
            ['previews/preview.png'] = 'PreviewPNG',
            ['preview.jpg'] = 'PreviewImage', -- (iWork 2013 files)
            ['preview-web.jpg'] = 'OtherImage', -- (iWork 2013 files)
            ['preview-micro.jpg'] = 'ThumbnailImage', -- (iWork 2013 files)
            ['QuickLook/Thumbnail.jpg'] = 'ThumbnailImage', -- (iWork 2009 files)
            ['QuickLook/Preview.pdf'] = 'PreviewPDF', -- (iWork 2009 files)
        }
        for _, member in ipairs(members) do
            docNum = docNum + 1
            et.DOC_NUM = docNum
            ZIP.HandleMember(et, member, tagTablePtr)
            local file = member:fileName()
            -- extract things from Sketch files
            if extract[file] then
                buff, status = zip:contents(member)
                if perlTruthy(status) then et:Warn("Error extracting " .. file) goto next end
                if file == 'meta.json' then
                    et:ExtractInfo({ ref = 'SCALAR', value = buff }, { ReEntry = 1 })
                    if perlTruthy(et.VALUE.App) and isMatch(et.VALUE.App, '(?i)sketch') then
                        et:OverrideFileType('SKETCH')
                    end
                else
                    et:FoundTag(extract[file], buff)
                end
            elseif file == 'Index/Document.iwa' and not iWorkType then
                local type_ = iWorkType_h[et.FILE_EXT or '']
                iWorkType = type_ or 'PAGES'
            elseif iWorkFile[file] then
                iWorkType = iWorkFile[file]
            end
            ::next::
        end
        if iWorkType then et:OverrideFileType(iWorkType) end
        break
    end
    -- all done if we processed this using Archive::Zip
    if zip then
        dirInfo.ZIP = nil
        et.DOC_NUM = nil
        if docNum > 1 and not perlTruthy(et:Options('Duplicates')) then
            et:Warn("Use the Duplicates option to extract tags for all " .. docNum .. " files", 1)
        end
        return 1
    end
--
-- process the ZIP file by hand (funny, but this seems easier than using Archive::Zip)
--
    et:VPrint(1, "  -- processing as binary data --\n")
    raf:Seek(30, 0)
    et:SetFileType()
    SetByteOrder('II')

    --  A.  Local file header:
    --  local file header signature     0) 4 bytes  (0x04034b50)
    --  version needed to extract       4) 2 bytes
    --  general purpose bit flag        6) 2 bytes
    --  compression method              8) 2 bytes
    --  last mod file time             10) 2 bytes
    --  last mod file date             12) 2 bytes
    --  crc-32                         14) 4 bytes
    --  compressed size                18) 4 bytes
    --  uncompressed size              22) 4 bytes
    --  file name length               26) 2 bytes
    --  extra field length             28) 2 bytes
    while true do
        local len = Get16u(buff, 26) + Get16u(buff, 28)
        n, buf2 = raf:Read(len)
        if n ~= len then break end

        docNum = docNum + 1
        et.DOC_NUM = docNum
        buff = buff .. buf2
        local dirInfo_h = {
            DataPt = buff,
            DataPos = raf:Tell() - 30 - len,
            DataLen = 30 + len,
            DirStart = 0,
            DirLen = 30 + len,
            MixedTags = 1, -- (to ignore FileComment tag)
        }
        et:ProcessDirectory(dirInfo_h, tagTablePtr)
        local flags = Get16u(buff, 6)
        if flags & 0x08 ~= 0 then
            -- we don't yet support skipping stream mode data
            -- (when this happens, the CRC, compressed size and uncompressed
            --  sizes are set to 0 in the header.  Instead, they are stored
            --  after the compressed data with an optional header of 0x08074b50)
            et:Warn('Stream mode data encountered, file list may be incomplete')
            break
        end
        len = Get32u(buff, 18)          -- file data length
        if not raf:Seek(len, 1) then break end  -- skip file data
        n, buff = raf:Read(30)
        if not (n == 30 and isMatch(buff, [[^PK\x03\x04]])) then break end
    end
    et.DOC_NUM = nil
    if docNum > 1 and not perlTruthy(et:Options('Duplicates')) then
        et:Warn("Use the Duplicates option to extract tags for all " .. docNum .. " files", 1)
    end
    return 1
end

return ZIP
