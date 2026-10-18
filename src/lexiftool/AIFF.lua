--------------------------------------------------------------------------------
-- File:         lexiftool/AIFF.lua
-- Ported from:  lib/Image/ExifTool/AIFF.pm
--
-- Description:  Read AIFF meta information
--
-- Revisions:    01/06/2006 - P. Harvey Created
--               09/22/2008 - PH Added DjVu support
--
-- References:   1) http://developer.apple.com/documentation/QuickTime/INMAC/SOUND/imsoundmgr.30.htm#pgfId=3190
--               2) http://astronomy.swin.edu.au/~pbourke/dataformats/aiff/
--               3) http://www.mactech.com/articles/mactech/Vol.06/06.01/SANENormalized/
--
-- Port notes:   read port: the Main/Common/FormatVers/Comment/Composite tables
--               plus ProcessAIFF and ProcessComment. Upstream AIFF.pm is read-
--               only, so nothing of the write path is missing here.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local ID3 = require('lexiftool.ID3')
local perl = require('lexiftool.perl')
local matches = perl.matches

local AIFF = {}

-- information for time/date-based tags (time zero is Jan 1, 1904)
local function timeValueConv(_self, val)
    return ExifTool.ConvertUnixTime(val - ((66 * 365 + 17) * 24 * 3600))
end
local function timePrintConv(self, val)
    return self:ConvertDateTime(val)
end

-- AIFF info
AIFF.Main = {
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        Tags extracted from Audio Interchange File Format (AIFF) files.  See
        L<http://www-mmsp.ece.mcgill.ca/Documents/AudioFormats/AIFF/AIFF.html> for
        the AIFF specification.
    ]],
    FVER = {
        Name = 'FormatVersion',
        SubDirectory = { TagTable = 'lexiftool.AIFF.FormatVers' },
    },
    COMM = {
        Name = 'Common',
        SubDirectory = { TagTable = 'lexiftool.AIFF.Common' },
    },
    COMT = {
        Name = 'Comment',
        SubDirectory = { TagTable = 'lexiftool.AIFF.Comment' },
    },
    NAME = {
        Name = 'Name',
        ValueConv = function(self, val) return self:Decode(val, 'MacRoman') end,
    },
    AUTH = {
        Name = 'Author',
        Groups = { [2] = 'Author' },
        ValueConv = function(self, val) return self:Decode(val, 'MacRoman') end,
    },
    ['(c) '] = {
        Name = 'Copyright',
        Groups = { [2] = 'Author' },
        ValueConv = function(self, val) return self:Decode(val, 'MacRoman') end,
    },
    ANNO = {
        Name = 'Annotation',
        ValueConv = function(self, val) return self:Decode(val, 'MacRoman') end,
    },
    ['ID3 '] = {
        Name = 'ID3',
        SubDirectory = {
            TagTable = 'lexiftool.ID3.Main',
            ProcessProc = ID3.ProcessID3,
        },
    },
    APPL = 'ApplicationData', -- (first 4 bytes are the application signature)
}

AIFF.Common = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'int16u',
    [0] = 'NumChannels',
    [1] = { Name = 'NumSampleFrames', Format = 'int32u' },
    [3] = 'SampleSize',
    [4] = { Name = 'SampleRate', Format = 'extended' },
    [9] = {
        Name = 'CompressionType',
        Format = 'string[4]',
        PrintConv = {
            NONE = 'None',
            ACE2 = 'ACE 2-to-1',
            ACE8 = 'ACE 8-to-3',
            MAC3 = 'MAC 3-to-1',
            MAC6 = 'MAC 6-to-1',
            sowt = 'Little-endian, no compression',
            alaw = 'a-law',
            ALAW = 'A-law',
            ulaw = 'mu-law',
            ULAW = 'Mu-law',
            ['GSM '] = 'GSM',
            G722 = 'G722',
            G726 = 'G726',
            G728 = 'G728',
        },
    },
    [11] = {
        Name = 'CompressorName',
        Format = 'pstring',
        ValueConv = function(self, val) return self:Decode(val, 'MacRoman') end,
    },
}

AIFF.FormatVers = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int32u',
    [0] = { Name = 'FormatVersionTime', Groups = { [2] = 'Time' }, ValueConv = timeValueConv, PrintConv = timePrintConv },
}

AIFF.Comment = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Audio' },
    [0] = { Name = 'CommentTime', Groups = { [2] = 'Time' }, ValueConv = timeValueConv, PrintConv = timePrintConv },
    [1] = 'MarkerID',
    [2] = {
        Name = 'Comment',
        ValueConv = function(self, val) return self:Decode(val, 'MacRoman') end,
    },
}

AIFF.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    Duration = {
        TagID = 'AIFF-Duration',
        Require = { [0] = 'AIFF:SampleRate', [1] = 'AIFF:NumSampleFrames' },
        RawConv = function(_self, val)
            local rate = tonumber(val[0])
            local frames = tonumber(val[1])
            if rate and rate ~= 0 and frames and frames ~= 0 then return frames / rate end
            return nil
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.AIFF', nil, AIFF)

--------------------------------------------------------------------------------
-- Process AIFF Comment chunk
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function AIFF.ProcessComment(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    if dirLen <= 2 then return 0 end
    local numComments = ExifTool.Get16u(dataPt, 0)
    local pos = 2
    if perl.truthy(et:Options('Verbose')) then et:VerboseDir('Comment', numComments) end
    for _ = 1, numComments do
        if pos + 8 > dirLen then break end
        local time = ExifTool.Get32u(dataPt, pos)
        local markerID = ExifTool.Get16u(dataPt, pos + 4)
        local size = ExifTool.Get16u(dataPt, pos + 6)
        et:HandleTag(tagTablePtr, 0, time)
        if markerID ~= 0 then et:HandleTag(tagTablePtr, 1, markerID) end
        pos = pos + 8
        if pos + size > dirLen then break end
        local val = dataPt:sub(pos + 1, pos + size)
        et:HandleTag(tagTablePtr, 2, val)
        if size & 0x01 ~= 0 then size = size + 1 end -- account for padding byte if necessary
        pos = pos + size
    end
    return 1
end
AIFF.Comment.PROCESS_PROC = AIFF.ProcessComment

--------------------------------------------------------------------------------
-- Extract information from a AIFF file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid AIFF file
--------------------------------------------------------------------------------
function AIFF.ProcessAIFF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(12)
    if n ~= 12 then return 0 end
    local pos = 12
    local tagTablePtr
    if buff:sub(1, 8) == 'AT&TFORM' then
        -- http://www.djvu.org/
        local n2, buf2 = raf:Read(4)
        if n2 ~= 4 or not matches(buf2, [[^(DJVU|DJVM)]]) then return 0 end
        pos = pos + 4
        et:SetFileType('DJVU')
        tagTablePtr = et:GetTagTable('lexiftool.DjVu.Main')
        -- modify FileType to indicate a multi-page document
        if buf2:sub(1, 4) == 'DJVM' and et.VALUE.FileType then
            et.VALUE.FileType = et.VALUE.FileType .. ' (multi-page)'
        end
    else
        local subType = buff:sub(9, 12)
        if not (buff:sub(1, 4) == 'FORM' and (subType == 'AIFF' or subType == 'AIFC')) then
            return 0
        end
        et:SetFileType(subType)
        tagTablePtr = et:GetTagTable('lexiftool.AIFF.Main')
    end
    ExifTool.SetByteOrder('MM')
    --
    -- Read through the IFF chunks
    --
    local page = 0
    local n2 = 0
    while true do
        local rn, rbuff = raf:Read(8)
        if rn ~= 8 then break end
        pos = pos + 8
        local tag = rbuff:sub(1, 4)
        local len = ExifTool.Get32u(rbuff, 4)
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        et:VPrint(0, "AIFF '" .. tag .. "' chunk (" .. len .. ' bytes of data): ' .. raf:Tell() .. '\n')
        -- AIFF chunks are padded to an even number of bytes
        local len2 = len + (len & 0x01)
        local err = false
        if tagInfo then
            if tagInfo.TypeOnly then
                len = 4
                len2 = 4
                page = page + 1
                et:VPrint(0, et.INDENT .. 'Page ' .. page .. ':\n')
            end
            local dn, dbuff = raf:Read(len2)
            if dn < len then
                err = true
            else
                if not (tagInfo.SubDirectory or tagInfo.Binary) then
                    dbuff = dbuff:gsub('\0+$', '') -- remove trailing nulls
                end
                et:HandleTag(tagTablePtr, tag, dbuff, {
                    DataPt = dbuff,
                    DataPos = pos,
                    Start = 0,
                    Size = len,
                })
            end
        elseif len == 0 then
            n2 = n2 + 1
            if n2 >= 100 then
                et:Warn('Aborting scan.  Too many empty chunks')
                err = true
            end
        else
            if not raf:Seek(len2, 1) then err = true end
        end
        if err then break end
        if tagInfo or len ~= 0 then n2 = 0 end
        pos = pos + len2
    end
    return 1
end

return AIFF
