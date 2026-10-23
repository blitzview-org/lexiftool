--------------------------------------------------------------------------------
-- File:         lexiftool/Palm.lua
-- Ported from:  lib/Image/ExifTool/Palm.pm
--
-- Description:  Read Palm Database files
--
-- Revisions:    2014/05/28 - P. Harvey Created
--
-- References: 1) http://wiki.mobileread.com/wiki/PDB
--             2) http://wiki.mobileread.com/wiki/MOBI
--
-- Port notes:   complete: ProcessPDB (the 86-byte header validation, the
--               Main-table pass, the MOBI-header pass with the BookName
--               string extraction, and the EXTH extended-header reader),
--               ProcessEXTH (the per-entry tag/length/value loop with the
--               Encoding recode), the Main/MOBI/EXTH tables, and the
--               palmTypes/dateTimeInfo lookups.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
-- (XMP is required at the point of use, not at the top: a top-level require
--  would load it for every file that loads this module, and
--  BuildCompositeTags derives its worklist from `package.loaded`)

local Palm = {}

-- type/creator ID's for Palm database files
local palmTypes = {
    ['.pdfADBE'] = 'Adobe Reader',
    ['TEXtREAd'] = 'PalmDOC',
    ['BVokBDIC'] = 'BDicty',
    ['DB99DBOS'] = 'DB (Database program)',
    ['PNRdPPrs'] = 'eReader',
    ['DataPPrs'] = 'eReader',
    ['vIMGView'] = 'FireViewer (ImageViewer)',
    ['PmDBPmDB'] = 'HanDBase',
    ['InfoINDB'] = 'InfoView',
    ['ToGoToGo'] = 'iSilo',
    ['SDocSilX'] = 'iSilo 3',
    ['JbDbJBas'] = 'JFile',
    ['JfDbJFil'] = 'JFile Pro',
    ['DATALSdb'] = 'LIST',
    ['Mdb1Mdb1'] = 'MobileDB',
    ['BOOKMOBI'] = 'Mobipocket',
    ['DataPlkr'] = 'Plucker',
    ['DataSprd'] = 'QuickSheet',
    ['SM01SMem'] = 'SuperMemo',
    ['TEXtTlDc'] = 'TealDoc',
    ['InfoTlIf'] = 'TealInfo',
    ['DataTlMl'] = 'TealMeal',
    ['DataTlPt'] = 'TealPaint',
    ['dataTDBP'] = 'ThinkDB',
    ['TdatTide'] = 'Tides',
    ['ToRaTRPW'] = 'TomeRaider',
    ['zTXTGPlm'] = 'Weasel',
    ['BDOCWrdS'] = 'WordSmith',
}

-- Palm date/time conversion (upstream %dateTimeInfo; like QuickTime the time
-- zero should be Jan 1, 1904, but not all software writes this, so assume a
-- time zero of Jan 1, 1970 if the date is before this)
local dateTimeInfo = {
    RawConv = function(_self, val)
        local offset = (66 * 365 + 17) * 24 * 3600
        if val >= offset then return val - offset end
        return val
    end,
    ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end, -- (UTC written by "EPUB Converter", ref PH)
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- Palm Database header information (upstream %Image::ExifTool::Palm::Main)
Palm.Main = {
    GROUPS = { [0] = 'Palm', [1] = 'Palm', [2] = 'Document' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int32u',
    NOTES = [[
        Information extracted from Palm database files (PDB and PRC extensions),
        Mobipocket electronic books (MOBI), and Amazon Kindle KF7 and KF8 books (AZW
        and AZW3).
    ]],
    [0] = { Name = 'DatabaseName', Format = 'string[32]' },
    -- 8 - int16u: file attributes (not very useful)
    -- 8.5 - int16u: version
    [9] = {
        Name = 'CreateDate', Groups = { [2] = 'Time' },
        RawConv = dateTimeInfo.RawConv, ValueConv = dateTimeInfo.ValueConv,
        PrintConv = dateTimeInfo.PrintConv,
    },
    [10] = {
        Name = 'ModifyDate', Groups = { [2] = 'Time' },
        RawConv = dateTimeInfo.RawConv, ValueConv = dateTimeInfo.ValueConv,
        PrintConv = dateTimeInfo.PrintConv,
    },
    [11] = {
        Name = 'LastBackupDate', Groups = { [2] = 'Time' },
        RawConv = dateTimeInfo.RawConv, ValueConv = dateTimeInfo.ValueConv,
        PrintConv = dateTimeInfo.PrintConv,
    },
    [12] = 'ModificationNumber',
    [15] = {
        Name = 'PalmFileType',
        Format = 'undef[8]',
        PrintConv = palmTypes,
    },
}

-- MOBI header tags (upstream %Image::ExifTool::Palm::MOBI)
Palm.MOBI = {
    GROUPS = { [0] = 'Palm', [1] = 'MOBI', [2] = 'Document' },
    NOTES = [[
        Information extracted from the MOBI header of Mobipocket and Amazon Kindle
        KF7 and KF8 files.
    ]],
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int32u',
    [0] = {
        Name = 'Compression',
        Format = 'int16u',
        PrintConv = {
            [1] = 'None',
            [2] = 'PalmDOC',
            [17480] = 'HUFF/CDIC',
        },
    },
    [1] = {
        Name = 'UncompressedTextLength',
        PrintConv = function(self, val) return ExifTool.ConvertFileSize(val, self) end,
    },
    [3] = {
        Name = 'Encryption',
        PrintConv = {
            [0] = 'None',
            [1] = 'Old Mobipocket',
            [2] = 'Mobipocket',
        },
    },
    [6] = {
        Name = 'MobiType',
        PrintConv = {
            [2] = 'Mobipocket Book',
            [3] = 'PalmDoc Book',
            [4] = 'Audio',
            [232] = 'mobipocket? generated by kindlegen1.2',
            [248] = 'KF8: generated by kindlegen2',
            [257] = 'News',
            [258] = 'News_Feed',
            [259] = 'News_Magazine',
            [513] = 'PICS',
            [514] = 'WORD',
            [515] = 'XLS',
            [516] = 'PPT',
            [517] = 'TEXT',
            [518] = 'HTML',
        },
    },
    [7] = {
        Name = 'CodePage',
        RawConv = function(self, val) self.CodePage = val return val end,
        PrintConv = {
            -- just define commonly used code pages
            -- (a much more complete list may be found in FlashPix.pm)
            [1252] = 'Windows Latin 1 (Western European)',
            [65001] = 'Unicode (UTF-8)',
        },
    },
    [9] = 'MobiVersion',
    [21] = 'BookName', -- this is actually an offset, but replace it with the string later
    [26] = 'MinimumVersion',
}

-- MOBI extended header tags (upstream %Image::ExifTool::Palm::EXTH)
Palm.EXTH = {
    GROUPS = { [0] = 'Palm', [1] = 'MOBI', [2] = 'Document' },
    FORMAT = 'string',
    NOTES = 'Information extracted from the MOBI extended header.',
    PROCESS_PROC = false, -- set below to Palm.ProcessEXTH
    [1] = 'DRMServerID',
    [2] = 'DRMCommerceID',
    [3] = 'DRM_E-BookBaseID',
    [100] = { Name = 'Author', Groups = { [2] = 'Author' } },
    [101] = 'Publisher',
    [102] = 'Imprint',
    [103] = 'Description',
    [104] = 'ISBN',
    [105] = { Name = 'Subject', List = 1 },
    [106] = {
        Name = 'PublishDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [107] = 'Review',
    [108] = 'Contributor',
    [109] = { Name = 'Rights', Groups = { [2] = 'Author' } },
    [110] = 'SubjectCode',
    [111] = 'BookType',
    [112] = 'Source',
    [113] = 'ASIN',
    [114] = 'BookVersion',
    [115] = { Name = 'SampleFlag', Format = 'int32u' },
    [116] = { Name = 'StartReading', Format = 'int32u' },
    [117] = 'Adult',
    [118] = 'RetailPrice',
    [119] = 'RetailPriceCurrency',
    -- 121 => 'KF8BoundaryOffset',
    [125] = { Name = 'ResourceCount', Format = 'int32u' },
    [129] = 'KF8CoverURI',
    [200] = 'DictionaryShortName',
    -- 201 => { Name => 'CoverOffset', Format => 'int32u' },
    -- 202 => { Name => 'ThumbOffset', Format => 'int32u' },
    -- 203 => 'HasFakeCover',
    [204] = {
        Name = 'CreatorSoftware',
        Format = 'int32u',
        PrintConv = {
            [1] = 'Mobigen',
            [2] = 'Mobipocket',
            [200] = 'Kindlegen (Windows)',
            [201] = 'Kindlegen (Linux)',
            [202] = 'Kindlegen (Mac)',
        },
    },
    [205] = { Name = 'CreatorMajorVersion', Format = 'int32u' },
    [206] = { Name = 'CreatorMinorVersion', Format = 'int32u' },
    [207] = { Name = 'CreatorBuildNumber', Format = 'int32u' },
    [208] = 'Watermark',
    [209] = 'Tamper-proofKeys',
    -- 300 => 'FontSignature',
    [401] = { Name = 'ClippingLimit', Format = 'int8u' },
    [402] = 'PublisherLimit',
    [404] = {
        Name = 'TextToSpeech',
        Format = 'int8u',
        PrintConv = { [0] = 'Enabled', [1] = 'Disabled' },
    },
    [405] = { Name = 'RentalFlag', Format = 'int8u' }, --?
    [406] = 'RentalExpirationDate',
    [501] = { Name = 'CDEType', Format = 'int32u' },
    [502] = 'LastUpdateTime',
    [503] = 'UpdatedTitle',
    [504] = 'ASIN2',
    [524] = 'Language',
    [525] = 'Alignment',
    [535] = 'CreatorBuildNumber2',
}

-- cpXXXX -> charset name (subset of upstream %charsetName, the code pages the
-- vendored test files use)
local charsetName = {
    [1252] = 'Latin',
    [65001] = 'UTF8',
}

--------------------------------------------------------------------------------
-- Process the MOBI extended header (upstream ProcessEXTH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 (EXTH should have already been validated)
--------------------------------------------------------------------------------
function Palm.ProcessEXTH(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local enc = dirInfo.Encoding or 'UTF8'
    local dirLen = #dataPt

    et:VerboseDir('EXTH', dirInfo.NumEntries, dirLen)

    -- process the EXTH entries
    local index = 0
    local pos = 0
    while true do
        if pos + 8 > dirLen then break end
        local tag = ExifTool.Get32u(dataPt, pos)
        local len = ExifTool.Get32u(dataPt, pos + 4)
        if len < 8 or pos + len > dirLen then break end
        local key = et:HandleTag(tagTablePtr, tag, nil, {
            DataPt = dataPt,
            DataPos = dataPos,
            Start = pos + 8,
            Size = len - 8,
            Index = index,
        })
        -- recode text if necessary
        if key then
            et.VALUE[key] = et:Decode(et.VALUE[key], enc)
        end
        pos = pos + len
        index = index + 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a Palm DB file (upstream ProcessPDB)
-- Inputs: 0) ExifTool ref, 1) dirInfo reference
-- Returns: 1 if this was a recognized PDB file, 0 otherwise
--------------------------------------------------------------------------------
function Palm.ProcessPDB(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, size, enc

    -- verify this is a valid Palm DB file
    local n0, b0 = raf:Read(86)
    if n0 ~= 86 then return 0 end
    buff = b0
    local type = palmTypes[substr(buff, 60, 8)]
    if not type then return 0 end
    --
    -- Read and process the Palm DB file header
    --
    et:SetFileType(type == 'Mobipocket' and 'MOBI' or 'PDB')
    ExifTool.SetByteOrder('MM')

    local tagTablePtr = et:GetTagTable('lexiftool.Palm.Main')
    et:ProcessDirectory({ DataPt = buff }, tagTablePtr)

    if not (type == 'Mobipocket' and ExifTool.Get16u(buff, 76)) then return 1 end
    --
    -- Read and process MOBI header (should be the first record)
    --
    local offset = ExifTool.Get32u(buff, 78) -- get offset to first record
    local n1, b1
    if raf:Seek(offset, 0) then
        n1, b1 = raf:Read(274)
    end
    if n1 ~= 274 then
        et:Warn('Truncated MOBI header')
        return 1
    end
    buff = b1
    if substr(buff, 16, 4) ~= 'MOBI' then
        et:Warn('Invalid MOBI header')
        return 1
    end
    tagTablePtr = et:GetTagTable('lexiftool.Palm.MOBI')
    et:ProcessDirectory({ DataPt = buff }, tagTablePtr)

    -- get text encoding
    if et.CodePage then
        enc = charsetName[et.CodePage]
    end
    enc = enc or 'UTF8'

    -- extract the BookName string
    local off = ExifTool.Get32u(buff, 84)
    local len = ExifTool.Get32u(buff, 88)
    local n2, b2
    if raf:Seek(offset + off, 0) then
        n2, b2 = raf:Read(len)
    end
    if n2 ~= len then
        b2 = '<err>'
    end
    et.VALUE.BookName = et:Decode(b2, enc)
    --
    -- Process the MOBI extended header if it exists
    --
    -- first, check the flag bit to see if the EXTH record should exist
    local flag = ExifTool.Get32u(buff, 128)
    if (flag & 0x40) == 0 then return 1 end -- check extended header flag

    len = ExifTool.Get32u(buff, 20) + 16 -- MOBI header length (including PalmDOC header)

    local n3, b3
    if raf:Seek(offset + len, 0) then
        n3, b3 = raf:Read(12)
    end
    if not (n3 == 12 and substr(b3, 0, 4) == 'EXTH' and ExifTool.Get32u(b3, 4) > 12) then
        et:Warn('Invalid MOBI extended header')
        return 1
    end
    size = ExifTool.Get32u(b3, 4)

    -- read and process the MOBI extended header
    size = size - 12
    local n4, b4 = raf:Read(size)
    if n4 ~= size then
        et:Warn('Truncated MOBI extended header')
        return 1
    end
    buff = b4
    local extDir = {
        DataPt = buff,
        DataPos = offset + len + 12,
        NumEntries = ExifTool.Get32u(b3, 8),
        Encoding = enc,
    }
    tagTablePtr = et:GetTagTable('lexiftool.Palm.EXTH')
    et:ProcessDirectory(extDir, tagTablePtr)

    return 1
end

-- (PROCESS_PROC set here so the table can reference ProcessEXTH)
Palm.EXTH.PROCESS_PROC = Palm.ProcessEXTH

return Palm