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
-- Port notes:   only ProcessZIP's "process the ZIP file by hand" fallback
--               path was ported first; the Archive::Zip path now works too,
--               through ArchiveZip.lua -- a Lua stand-in for that CPAN
--               module (see its own Notes). With it, member data is
--               decompressed and the CaptureOne/iWork/OOXML/OpenDocument
--               sub-parsers are reached, as upstream does when the module is
--               installed. The hand-written fallback is kept for the case
--               where the central directory can't be read, exactly like
--               upstream's `last` out of the Archive::Zip loop.
--               Deferred there: upstream's IO::String dance for pipes and
--               scalar refs (this port hands its RandomAccess object
--               straight to ArchiveZip) and the retry for a Perl 5.6.2 bug.
--               ProcessGZIP and ProcessRAR have no Archive::Zip dependency
--               and are ported in full (RAR v4 and v5/7z).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local matches = perl.matches
local sprintf = perl.sprintf
local perlStr = perl.str
local RandomAccess = require('lexiftool.RandomAccess')
local ArchiveZip = require('lexiftool.ArchiveZip')
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

local ZIP = {}

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

local iWorkType = {
    NUMBERS = 'NUMBERS',
    PAGES   = 'PAGES',
    KEY     = 'KEY',
    KTH     = 'KTH',
    NMBTEMPLATE = 'NMBTEMPLATE',
}

-- ZIP metadata blocks (local file header, byte offsets in units of the
-- 2-byte default FORMAT)
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
        PrintConv = function(_self, val) return val ~= 0 and sprintf('0x%.4x', val) or val end,
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

--------------------------------------------------------------------------------
-- Extract information from a ZIP file (no Archive::Zip: hand-parsed local
-- file headers only)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid ZIP file
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Call HandleTags for attributes of an Archive::Zip member
-- Inputs: 0) ExifTool object ref, 1) member ref, 2) optional tag table ref
--------------------------------------------------------------------------------
function ZIP.HandleMember(et, member, tagTablePtr)
    if not tagTablePtr then tagTablePtr = et:GetTagTable('lexiftool.ZIP.Main') end
    et:HandleTag(tagTablePtr, 2, member:versionNeededToExtract())
    et:HandleTag(tagTablePtr, 3, member:bitFlag())
    et:HandleTag(tagTablePtr, 4, member:compressionMethod())
    et:HandleTag(tagTablePtr, 5, member:lastModFileDateTime())
    et:HandleTag(tagTablePtr, 7, member:crc32())
    et:HandleTag(tagTablePtr, 9, member:compressedSize())
    et:HandleTag(tagTablePtr, 11, member:uncompressedSize())
    et:HandleTag(tagTablePtr, 15, member:fileName())
    local com = member:fileComment()
    if com ~= nil and #com > 0 then et:HandleTag(tagTablePtr, '_com', com) end
end

--------------------------------------------------------------------------------
-- Extract file from ZIP archive
-- Inputs: 0) ExifTool ref, 1) Zip object ref, 2) file name
-- Returns: zip member or undef it it didn't exist
--------------------------------------------------------------------------------
function ZIP.ExtractFile(et, zip, file)
    local result = zip:memberNamed(file)
    et:VPrint(1, "  (Extracting '" .. file .. "' from zip archive)\n")
    return result
end

--------------------------------------------------------------------------------
function ZIP.ProcessZIP(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(30)
    if n ~= 30 or buff:sub(1, 4) ~= 'PK\3\4' then return 0 end

    local tagTablePtr = et:GetTagTable('lexiftool.ZIP.Main')
    local docNum = 0

    -- use Archive::Zip if available
    local zip
    repeat
        et:VPrint(1, '  --- using Archive::Zip ---\n')
        zip = ArchiveZip.new()
        -- catch all warnings! (Archive::Zip is bad for this)
        local status = zip:readFromFileHandle(raf)
        if status ~= 0 then
            zip = nil
            local err = ({ [1] = 'Stream end error', [3] = 'Format error',
                           [4] = 'IO error' })[status] or ('Error ' .. status)
            et:Warn(err .. ' reading ZIP file')
            break
        end
        -- extract zip file comment
        local comment = zip:zipfileComment()
        if comment ~= nil and #comment > 0 then et:FoundTag('Comment', comment) end

        dirInfo.ZIP = zip

        -- check for an Office Open file (DOCX, etc)
        -- --> read '[Content_Types].xml' to determine the file type
        local mime, members
        local cType = ZIP.ExtractFile(et, zip, '[Content_Types].xml')
        if cType then
            local buf2, st2 = zip:contents(cType)
            if st2 == 0 and buf2 then
                -- first look for the main document with the expected name
                -- (upstream's pattern on one line; split here only to stay
                --  inside this port's line-length limit)
                local mainPat = [==[\sPartName\s*=\s*['"]]==] ..
                    [==[(?:/ppt/presentation.xml|/word/document.xml|/xl/workbook.xml)]==] ..
                    [==[['"][^>]*\sContentType\s*=\s*(['"])([^"']+)\.main(\+xml)?\1]==]
                local m = { matches(buf2, mainPat) }
                -- then look for the main part
                if #m == 0 then
                    m = { matches(buf2, [==[<Override[^>]*\sPartName[^<]+\sContentType]==] ..
                        [==[\s*=\s*(['"])([^"']+)\.main(\+xml)?\1]==]) }
                end
                -- and if all else fails, use the default main
                if #m == 0 then
                    m = { matches(buf2, [==[ContentType\s*=\s*(['"])([^"']+)\.main(\+xml)?\1]==]) }
                end
                if #m > 0 then mime = m[2] end
            end
        end
        -- check for docProps if we couldn't find a MIME type
        if not mime then members = zip:membersMatching('^docProps/.*\\.(xml|XML)$') end
        if mime or (members and #members > 0) then
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
        local mType = ZIP.ExtractFile(et, zip, 'mimetype')
        if mType then
            local st3
            mime, st3 = zip:contents(mType)
            local mm = mime and { matches(mime, [[(?s)([\x21-\xfe]+)]]) } or {}
            if st3 == 0 and #mm > 0 then
                -- clean up MIME type just in case (note that MIME is case insensitive)
                mime = lc(mm[1])
                et:SetFileType(openDocType[mime] or 'ZIP', mime)
                if not openDocType[mime] then et:Warn('Unrecognized MIMEType ' .. mime) end
                -- extract Open Document metadata from "meta.xml"
                local meta = ZIP.ExtractFile(et, zip, 'meta.xml')
                -- IDML files have metadata in a different place (ref 6)
                if not meta then meta = ZIP.ExtractFile(et, zip, 'META-INF/metadata.xml') end
                if meta then
                    local buf3, st4 = zip:contents(meta)
                    if st4 == 0 then
                        local subDirInfo = {
                            DirName = 'XML',
                            DataPt  = buf3,
                            DirLen  = #buf3,
                            DataLen = #buf3,
                        }
                        -- (avoid structure warnings when copying from XML)
                        local oldWarn = et.NO_STRUCT_WARN
                        et.NO_STRUCT_WARN = 1
                        et:ProcessDirectory(subDirInfo, et:GetTagTable('lexiftool.XMP.Main'))
                        et.NO_STRUCT_WARN = oldWarn
                    end
                end
                -- (upstream also processes the rootfile of an EPUB container
                --  here; EPUB is not among the ported file types, so that loop
                --  has no reachable case yet -- see Port notes)
                if openDocType[mime] or meta then
                    -- extract preview image(s) from "Thumbnails" directory if they exist
                    local tag = { jpg = 'PreviewImage', png = 'PreviewPNG' }
                    for _, type_ in ipairs({ 'jpg', 'png' }) do
                        local thumb = ZIP.ExtractFile(et, zip, 'Thumbnails/thumbnail.' .. type_)
                        if thumb then
                            local buf4, st5 = zip:contents(thumb)
                            if st5 == 0 then et:FoundTag(tag[type_], buf4) end
                        end
                    end
                    break   -- all done since we recognized the MIME type or found metadata
                end
                -- continue on to list ZIP contents...
            end
        end

        -- otherwise just extract general ZIP information
        et:SetFileType()
        members = zip:members()
        local foundType
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
                local buf5, st6 = zip:contents(member)
                if st6 ~= 0 then
                    et:Warn('Error extracting ' .. file)
                elseif file == 'meta.json' then
                    et:ExtractInfo({ ref = 'SCALAR', value = buf5 }, { ReEntry = 1 })
                    if et.VALUE.App and matches(perlStr(et.VALUE.App), '(?i)sketch') then
                        et:OverrideFileType('SKETCH')
                    end
                else
                    et:FoundTag(extract[file], buf5)
                end
            elseif file == 'Index/Document.iwa' and not foundType then
                foundType = iWorkType[et.FILE_EXT or ''] or 'PAGES'
            elseif iWorkFile[file] then
                foundType = iWorkFile[file]
            end
        end
        if foundType then et:OverrideFileType(foundType) end
    until true

    -- all done if we processed this using Archive::Zip
    if zip then
        dirInfo.ZIP = nil
        et.DOC_NUM = nil
        if docNum > 1 and not perl.truthy(et.OPTIONS.Duplicates) then
            et:Warn('Use the Duplicates option to extract tags for all ' .. docNum .. ' files', true)
        end
        return 1
    end

    -- (the hand-written fallback below is upstream's own path for when
    --  Archive::Zip isn't available; it is reached here when the central
    --  directory could not be read)
    if et.FILE_EXT and et.FILE_EXT ~= 'ZIP' then
        et:Warn('Install Archive::Zip to decode compressed ZIP information')
    end

    et:SetFileType()
    ExifTool.SetByteOrder('II')
    if not raf:Seek(0, 0) then return 0 end
    n, buff = raf:Read(30)
    if n ~= 30 or buff:sub(1, 4) ~= 'PK\3\4' then return 0 end

    -- A. Local file header:
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
        local len = ExifTool.Get16u(buff, 26) + ExifTool.Get16u(buff, 28)
        local n2, buf2 = raf:Read(len)
        if n2 ~= len then break end

        docNum = docNum + 1
        et.DOC_NUM = docNum
        buff = buff .. buf2
        local subDirInfo = {
            DataPt = buff,
            DataPos = raf:Tell() - 30 - len,
            DataLen = 30 + len,
            DirStart = 0,
            DirLen = 30 + len,
        }
        et:ProcessDirectory(subDirInfo, tagTablePtr)
        local flags = ExifTool.Get16u(buff, 6)
        if flags & 0x08 ~= 0 then
            -- we don't yet support skipping stream mode data
            et:Warn('Stream mode data encountered, file list may be incomplete')
            break
        end
        len = ExifTool.Get32u(buff, 18) -- file data length
        if not raf:Seek(len, 1) then break end -- skip file data
        n, buff = raf:Read(30)
        if n ~= 30 or buff:sub(1, 4) ~= 'PK\3\4' then break end
    end
    et.DOC_NUM = nil
    if docNum > 1 and not perl.truthy(et.OPTIONS.Duplicates) then
        et:Warn('Use the Duplicates option to extract tags for all ' .. docNum .. ' files', true)
    end
    return 1
end

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
-- Extract information from a GNU ZIP file (ref 3)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid GZIP file
--------------------------------------------------------------------------------
function ZIP.ProcessGZIP(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(10)
    if n ~= 10 or buff:sub(1, 3) ~= '\31\139\8' then return 0 end

    et:SetFileType()
    ExifTool.SetByteOrder('II')

    local tagTablePtr = et:GetTagTable('lexiftool.ZIP.GZIP')
    et:HandleTag(tagTablePtr, 2, (ExifTool.Get8u(buff, 2)))
    local flags = ExifTool.Get8u(buff, 3)
    et:HandleTag(tagTablePtr, 3, flags)
    et:HandleTag(tagTablePtr, 4, (ExifTool.Get32u(buff, 4)))
    et:HandleTag(tagTablePtr, 8, (ExifTool.Get8u(buff, 8)))
    et:HandleTag(tagTablePtr, 9, (ExifTool.Get8u(buff, 9)))

    -- extract file name and comment if they exist
    if flags & 0x18 ~= 0 then
        if flags & 0x04 ~= 0 then
            -- skip extra field
            local n2, lbuf = raf:Read(2)
            if n2 ~= 2 then return 1 end
            local len = ExifTool.Get16u(lbuf, 0)
            local n3 = raf:Read(len)
            if n3 ~= len then return 1 end
        end
        local n4, buf4 = raf:Read(4096)
        if not n4 or n4 == 0 then return 1 end
        buff = buf4
        local pos = 0
        for _, tagID in ipairs({ 10, 11 }) do
            local mask = tagID == 10 and 0x08 or 0x10
            if flags & mask ~= 0 then
                local nul = buff:find('\0', pos + 1, true)
                local endPos = nul and (nul - 1) or #buff
                -- (the doc specifies the string should be ISO 8859-1, but in
                -- OS X it seems to be UTF-8, so don't translate it because
                -- it could just as easily be broken)
                local str = substr(buff, pos, endPos - pos)
                et:HandleTag(tagTablePtr, tagID, str)
                if endPos >= #buff then break end
                pos = endPos + 1
            end
        end
    end
    return 1
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

return ZIP
