--------------------------------------------------------------------------------
-- File:         lexiftool/Real.lua
-- Ported from:  lib/Image/ExifTool/Real.pm
--
-- Description:  Read Real audio/video meta information
--
-- Revisions:    05/16/2006 - P. Harvey Created
--
-- References:   1) http://www.getid3.org/
--               2) https://common.helixcommunity.org/nonav/2003/HCS_SDK_r5/htmfiles/rmff.htm
--
-- Port notes:   read subset. Ported: ProcessReal (the .RMF/.ra\xfd/pnm|rtsp|
--               http signature dispatch, the RA header read, the RM chunk
--               loop with the MIME-type tracking + the MIMEType override,
--               and the RMJE footer with its RJMD metadata + ID3v1 read),
--               ProcessRealMeta (the fixed-structure metadata reader with
--               the sub-property recursion and the date-type ValueConv/
--               PrintConv injection), ProcessRealProperties (the
--               name/value property reader with dynamic tag creation), and
--               the Media/Audio/Metafile/Properties/MediaProps/FileInfo/
--               ContentDescr/Metadata/AudioV3/AudioV4/AudioV5 tables.  The
--               serial-stream tables are driven by Canon.ProcessSerialData
--               (already ported), which evaluates the Perl
--               `string[$val{N}]` format expressions as upstream.  Deferred
--               (unexercised): the verbose dumps and the FastScan path.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local Canon = require('lexiftool.Canon')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local str = perl.str
local ucfirst = perl.ucfirst

local Real = {}

-- Real property types (ref PH)
local propertyType = {
    [0] = 'int32u',
    [2] = 'string',
}

-- Real Metadata property types
local metadataFormat = {
    [1] = 'string', -- text
    [2] = 'string', -- text list
    [3] = 'flag', -- 1 or 4 byte integer
    [4] = 'int32u', -- 4-byte integer
    [5] = 'undef', -- binary data
    [6] = 'string', -- URL
    [7] = 'string', -- date
    [8] = 'string', -- file name
    [9] = false, -- grouping
    [10] = false, -- reference
}

-- tags used in RealMedia (RM, RV and RMVB) files (upstream %Real::Media)
Real.Media = {
    GROUPS = { [2] = 'Video' },
    CONT = { SubDirectory = { TagTable = 'lexiftool.Real.ContentDescr' } },
    MDPR = { SubDirectory = { TagTable = 'lexiftool.Real.MediaProps' } },
    PROP = { SubDirectory = { TagTable = 'lexiftool.Real.Properties' } },
    RJMD = { SubDirectory = { TagTable = 'lexiftool.Real.Metadata' } },
}

-- pseudo-tags used in RealAudio (RA) files (upstream %Real::Audio)
Real.Audio = {
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        Tags in the following table reference information extracted from various
        versions of RealAudio (RA) files.
    ]],
    ['.ra3'] = { Name = 'RA3', SubDirectory = { TagTable = 'lexiftool.Real.AudioV3' } },
    ['.ra4'] = { Name = 'RA4', SubDirectory = { TagTable = 'lexiftool.Real.AudioV4' } },
    ['.ra5'] = { Name = 'RA5', SubDirectory = { TagTable = 'lexiftool.Real.AudioV5' } },
}

-- pseudo-tags used in RealMedia Metafiles (RAM and RPM) (upstream %Real::Metafile)
Real.Metafile = {
    GROUPS = { [2] = 'Video' },
    txt = 'Text',
    url = 'URL',
}

Real.Properties = {
    GROUPS = { [1] = 'Real-PROP', [2] = 'Video' },
    PROCESS_PROC = Canon.ProcessSerialData,
    VARS = { ID_LABEL = 'Sequence' },
    FORMAT = 'int32u',
    [0] = { Name = 'MaxBitrate', PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    [1] = { Name = 'AvgBitrate', PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    [2] = 'MaxPacketSize',
    [3] = 'AvgPacketSize',
    [4] = 'NumPackets',
    [5] = {
        Name = 'Duration',
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [6] = {
        Name = 'Preroll',
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [7] = { Name = 'IndexOffset', Unknown = 1 },
    [8] = { Name = 'DataOffset', Unknown = 1 },
    [9] = { Name = 'NumStreams', Format = 'int16u' },
    [10] = {
        Name = 'Flags',
        Format = 'int16u',
        PrintConv = {
            BITMASK = {
                [0] = 'Allow Recording',
                [1] = 'Perfect Play',
                [2] = 'Live',
                [3] = 'Allow Download', -- PH (from rmeditor dump)
            },
        },
    },
}

Real.MediaProps = {
    GROUPS = { [1] = 'Real-MDPR', [2] = 'Video' },
    PROCESS_PROC = Canon.ProcessSerialData,
    VARS = { ID_LABEL = 'Sequence' },
    FORMAT = 'int32u',
    PRIORITY = 0, -- first stream takes priority
    [0] = { Name = 'StreamNumber', Format = 'int16u' },
    [1] = { Name = 'StreamMaxBitrate', PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    [2] = { Name = 'StreamAvgBitrate', PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    [3] = { Name = 'StreamMaxPacketSize' },
    [4] = { Name = 'StreamAvgPacketSize' },
    [5] = { Name = 'StreamStartTime' },
    [6] = {
        Name = 'StreamPreroll',
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [7] = {
        Name = 'StreamDuration',
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [8] = { Name = 'StreamNameLen', Format = 'int8u', Unknown = 1 },
    [9] = { Name = 'StreamName', Format = 'string[$val{8}]' },
    [10] = { Name = 'StreamMimeLen', Format = 'int8u', Unknown = 1 },
    [11] = {
        Name = 'StreamMimeType',
        Format = 'string[$val{10}]',
        RawConv = function(self, val) self.RealStreamMime = val return val end,
    },
    [12] = { Name = 'FileInfoLen', Unknown = 1 },
    [13] = {
        Name = 'FileInfoLen2',
        -- if this condition fails, subsequent tags will not be processed
        Condition = function(self) return str(self.RealStreamMime) == 'logical-fileinfo' end,
        Unknown = 1,
    },
    [14] = { Name = 'FileInfoVersion', Format = 'int16u' },
    [15] = { Name = 'PhysicalStreams', Format = 'int16u', Unknown = 1 },
    [16] = { Name = 'PhysicalStreamNumbers', Format = 'int16u[$val{15}]', Unknown = 1 },
    [17] = { Name = 'DataOffsets', Format = 'int32u[$val{15}]', Unknown = 1 },
    [18] = { Name = 'NumRules', Format = 'int16u', Unknown = 1 },
    [19] = { Name = 'PhysicalStreamNumberMap', Format = 'int16u[$val{18}]', Unknown = 1 },
    [20] = { Name = 'NumProperties', Format = 'int16u', Unknown = 1 },
    [21] = {
        Name = 'FileInfoProperties',
        Format = 'undef[$val{13}-$val{15}*6-$val{18}*2-12]',
        SubDirectory = { TagTable = 'lexiftool.Real.FileInfo' },
    },
}

-- Observed FileInfo properties (ref PH) (upstream %Real::FileInfo)
Real.FileInfo = {
    GROUPS = { [1] = 'Real-MDPR', [2] = 'Video' },
    PROCESS_PROC = false, -- set below to Real.ProcessRealProperties
    NOTES = [[
        The following tags have been observed in the FileInfo properties, but any
        other existing information will also be extracted.
    ]],
    Indexable = { PrintConv = { [0] = 'False', [1] = 'True' } },
    Keywords = {},
    Description = {},
    ['File ID'] = { Name = 'FileID' },
    ['Content Rating'] = {
        Name = 'ContentRating',
        PrintConv = {
            [0] = 'No Rating',
            [1] = 'All Ages',
            [2] = 'Older Children',
            [3] = 'Younger Teens',
            [4] = 'Older Teens',
            [5] = 'Adult Supervision Recommended',
            [6] = 'Adults Only',
        },
    },
    Audiences = {},
    audioMode = { Name = 'AudioMode' },
    ['Creation Date'] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            -- (upstream `$val =~ m{(\d+)/(\d+)/(\d+)\s+(\d+):(\d+):(\d+)} ?
            --  sprintf("%.4d:%.2d:%.2d %.2d:%.2d:%.2d",$3,$2,$1,$4,$5,$6) : $val`)
            local m1, m2, m3, h, mi, s = str(val):match('(%d+)/(%d+)/(%d+)[ \t\n\r\f\v]+(%d+):(%d+):(%d+)')
            if m1 then
                return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                    tonumber(m3), tonumber(m2), tonumber(m1), tonumber(h), tonumber(mi), tonumber(s))
            end
            return val
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['Generated By'] = { Name = 'Software' },
    ['Modification Date'] = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            local m1, m2, m3, h, mi, s = str(val):match('(%d+)/(%d+)/(%d+)[ \t\n\r\f\v]+(%d+):(%d+):(%d+)')
            if m1 then
                return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                    tonumber(m3), tonumber(m2), tonumber(m1), tonumber(h), tonumber(mi), tonumber(s))
            end
            return val
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['Target Audiences'] = { Name = 'TargetAudiences' },
    ['Audio Format'] = { Name = 'AudioFormat' },
    ['Video Quality'] = { Name = 'VideoQuality' },
    videoMode = { Name = 'VideoMode' },
}

Real.ContentDescr = {
    GROUPS = { [1] = 'Real-CONT', [2] = 'Video' },
    PROCESS_PROC = Canon.ProcessSerialData,
    VARS = { ID_LABEL = 'Sequence' },
    FORMAT = 'int16u',
    [0] = { Name = 'TitleLen', Unknown = 1 },
    [1] = { Name = 'Title', Format = 'string[$val{0}]' },
    [2] = { Name = 'AuthorLen', Unknown = 1 },
    [3] = { Name = 'Author', Format = 'string[$val{2}]', Groups = { [2] = 'Author' } },
    [4] = { Name = 'CopyrightLen', Unknown = 1 },
    [5] = { Name = 'Copyright', Format = 'string[$val{4}]', Groups = { [2] = 'Author' } },
    [6] = { Name = 'CommentLen', Unknown = 1 },
    [7] = { Name = 'Comment', Format = 'string[$val{6}]' },
}

-- Real RJMD meta information (ref PH) (upstream %Real::Metadata)
Real.Metadata = {
    GROUPS = { [1] = 'Real-RJMD', [2] = 'Video' },
    PROCESS_PROC = false, -- set below to Real.ProcessRealMeta
    ['Album/Name'] = 'AlbumName',
    ['Track/Category'] = 'TrackCategory',
    ['Track/Comments'] = 'TrackComments',
    ['Track/Lyrics'] = 'TrackLyrics',
}

Real.AudioV3 = {
    GROUPS = { [1] = 'Real-RA3', [2] = 'Audio' },
    PROCESS_PROC = Canon.ProcessSerialData,
    VARS = { ID_LABEL = 'Sequence' },
    FORMAT = 'int8u',
    [0] = { Name = 'Channels', Format = 'int16u' },
    [1] = { Name = 'Unknown', Format = 'int16u[3]', Unknown = 1 },
    [2] = { Name = 'BytesPerMinute', Format = 'int16u' },
    [3] = { Name = 'AudioBytes', Format = 'int32u' },
    [4] = { Name = 'TitleLen', Unknown = 1 },
    [5] = { Name = 'Title', Format = 'string[$val{4}]' },
    [6] = { Name = 'ArtistLen', Unknown = 1 },
    [7] = { Name = 'Artist', Format = 'string[$val{6}]', Groups = { [2] = 'Author' } },
    [8] = { Name = 'CopyrightLen', Unknown = 1 },
    [9] = { Name = 'Copyright', Format = 'string[$val{8}]', Groups = { [2] = 'Author' } },
    [10] = { Name = 'CommentLen', Unknown = 1 },
    [11] = { Name = 'Comment', Format = 'string[$val{10}]' },
}

Real.AudioV4 = {
    GROUPS = { [1] = 'Real-RA4', [2] = 'Audio' },
    PROCESS_PROC = Canon.ProcessSerialData,
    VARS = { ID_LABEL = 'Sequence' },
    FORMAT = 'int16u',
    [0] = { Name = 'FourCC1', Format = 'undef[4]', Unknown = 1 },
    [1] = { Name = 'AudioFileSize', Format = 'int32u', Unknown = 1 },
    [2] = { Name = 'Version2', Unknown = 1 },
    [3] = { Name = 'HeaderSize', Format = 'int32u', Unknown = 1 },
    [4] = { Name = 'CodecFlavorID', Unknown = 1 },
    [5] = { Name = 'CodedFrameSize', Format = 'int32u', Unknown = 1 },
    [6] = { Name = 'AudioBytes', Format = 'int32u' },
    [7] = { Name = 'BytesPerMinute', Format = 'int32u' },
    [8] = { Name = 'Unknown', Format = 'int32u', Unknown = 1 },
    [9] = { Name = 'SubPacketH', Unknown = 1 },
    [10] = 'AudioFrameSize',
    [11] = { Name = 'SubPacketSize', Unknown = 1 },
    [12] = { Name = 'Unknown', Unknown = 1 },
    [13] = 'SampleRate',
    [14] = { Name = 'Unknown', Unknown = 1 },
    [15] = 'BitsPerSample',
    [16] = 'Channels',
    [17] = { Name = 'FourCC2Len', Format = 'int8u', Unknown = 1 },
    [18] = { Name = 'FourCC2', Format = 'undef[4]', Unknown = 1 },
    [19] = { Name = 'FourCC3Len', Format = 'int8u', Unknown = 1 },
    [20] = { Name = 'FourCC3', Format = 'undef[4]', Unknown = 1 },
    [21] = { Name = 'Unknown', Format = 'int8u', Unknown = 1 },
    [22] = { Name = 'Unknown', Unknown = 1 },
    [23] = { Name = 'TitleLen', Format = 'int8u', Unknown = 1 },
    [24] = { Name = 'Title', Format = 'string[$val{23}]' },
    [25] = { Name = 'ArtistLen', Format = 'int8u', Unknown = 1 },
    [26] = { Name = 'Artist', Format = 'string[$val{25}]', Groups = { [2] = 'Author' } },
    [27] = { Name = 'CopyrightLen', Format = 'int8u', Unknown = 1 },
    [28] = { Name = 'Copyright', Format = 'string[$val{27}]', Groups = { [2] = 'Author' } },
    [29] = { Name = 'CommentLen', Format = 'int8u', Unknown = 1 },
    [30] = { Name = 'Comment', Format = 'string[$val{29}]' },
}

Real.AudioV5 = {
    GROUPS = { [1] = 'Real-RA5', [2] = 'Audio' },
    PROCESS_PROC = Canon.ProcessSerialData,
    VARS = { ID_LABEL = 'Sequence' },
    FORMAT = 'int16u',
    [0] = { Name = 'FourCC1', Format = 'undef[4]', Unknown = 1 },
    [1] = { Name = 'AudioFileSize', Format = 'int32u', Unknown = 1 },
    [2] = { Name = 'Version2', Unknown = 1 },
    [3] = { Name = 'HeaderSize', Format = 'int32u', Unknown = 1 },
    [4] = { Name = 'CodecFlavorID', Unknown = 1 },
    [5] = { Name = 'CodedFrameSize', Format = 'int32u', Unknown = 1 },
    [6] = { Name = 'AudioBytes', Format = 'int32u' },
    [7] = { Name = 'BytesPerMinute', Format = 'int32u' },
    [8] = { Name = 'Unknown', Format = 'int32u', Unknown = 1 },
    [9] = { Name = 'SubPacketH', Unknown = 1 },
    [10] = { Name = 'FrameSize', Unknown = 1 },
    [11] = { Name = 'SubPacketSize', Unknown = 1 },
    [12] = 'SampleRate',
    [13] = { Name = 'SampleRate2', Unknown = 1 },
    [14] = { Name = 'BitsPerSample', Format = 'int32u' },
    [15] = 'Channels',
    [16] = { Name = 'Genr', Format = 'int32u', Unknown = 1 },
    [17] = { Name = 'FourCC3', Format = 'undef[4]', Unknown = 1 },
}

-- (Lua has no ucfirst builtin; a small helper)
--------------------------------------------------------------------------------
-- Process Real NameValueProperties (upstream ProcessRealProperties)
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function Real.ProcessRealProperties(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local pos = dirInfo.DirStart

    while pos + 6 <= dirLen do
        -- get property size and version
        local size = ExifTool.Get32u(dataPt, pos)
        local vers = ExifTool.Get16u(dataPt, pos + 4)
        if size < 6 then break end
        if vers ~= 0 then
            pos = pos + size
            goto continue
        end
        pos = pos + 6

        local tagLen = dataPt:byte(pos + 1)
        pos = pos + 1

        if pos + tagLen > dirLen then break end
        local tag = substr(dataPt, pos, tagLen)
        pos = pos + tagLen

        if pos + 6 > dirLen then break end
        local type = ExifTool.Get32u(dataPt, pos)
        local valLen = ExifTool.Get16u(dataPt, pos + 4)
        pos = pos + 6

        if pos + valLen > dirLen then break end
        local format = propertyType[type] or 'undef'
        local count = math.floor(valLen / (ExifTool.FormatSize(format) or 1))
        local v = ExifTool.ReadValue(dataPt, pos, format, count, dirLen - pos)

        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not tagInfo then
            local tagName = tag:gsub('[ \t\n\r\f\v]+', '')
            if not tagName:match('^[A-Za-z0-9]+$') then
                pos = pos + valLen
                goto continue
            end
            tagInfo = { Name = ucfirst(tagName) }
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        et:FoundTag(tagInfo, v)
        pos = pos + valLen
        ::continue::
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process Real metadata properties (upstream ProcessRealMeta)
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function Real.ProcessRealMeta(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local pos = dirInfo.DirStart
    local dirEnd = pos + dirInfo.DirLen
    local prefix = dirInfo.Prefix or ''
    if prefix ~= '' then prefix = prefix .. '/' end

    while true do
        if pos + 28 > dirEnd then break end
        -- extract fixed-position metadata structure members
        local size = ExifTool.Get32u(dataPt, pos)
        local type = ExifTool.Get32u(dataPt, pos + 4)
        local flags = ExifTool.Get32u(dataPt, pos + 8)
        local valuePos = ExifTool.Get32u(dataPt, pos + 12)
        local numSubProps = ExifTool.Get32u(dataPt, pos + 20)
        local nameLen = ExifTool.Get32u(dataPt, pos + 24)
        -- make pointers relative to data start
        valuePos = valuePos + pos
        -- validate what we have read so far
        if pos + size > dirEnd then break end
        if pos + 28 + nameLen > dirEnd then break end
        if valuePos < pos + 28 + nameLen then break end
        if valuePos + 4 > dirEnd then break end
        local tag = substr(dataPt, pos + 28, nameLen)
        tag = tag:gsub('\0.*', '') -- truncate at null
        tag = prefix .. tag
        local valueLen = ExifTool.Get32u(dataPt, valuePos)
        valuePos = valuePos + 4 -- point at value itself
        if valuePos + valueLen > dirEnd then break end

        local format = metadataFormat[type]
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not tagInfo then
            local tagName = tag:gsub('[^A-Za-z0-9]', '')
            tagInfo = { Name = ucfirst(tagName) }
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        if valueLen and format then
            -- (a flag can be 1 or 4 bytes)
            if format == 'flag' then
                format = (valueLen == 4) and 'int32u' or 'int8u'
            elseif type == 7 and tagInfo then
                -- add PrintConv and ValueConv for "date" type
                if not tagInfo.ValueConv then
                    tagInfo.ValueConv = function(_self, val)
                        -- (upstream `$val =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/ ?
                        --  sprintf("%.4d:%.2d:%.2d %.2d:%.2d:%.2d",$1,$2,$3,$4,$5,$6) : $val`)
                        local y, mo, d, h, mi, s = str(val):match('^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)')
                        if y then
                            return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
                                tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
                        end
                        return val
                    end
                end
                if not tagInfo.PrintConv then
                    tagInfo.PrintConv = function(self, val) return self:ConvertDateTime(val) end
                end
            end
            local count = math.floor(valueLen / (ExifTool.FormatSize(format) or 1))
            local v = ExifTool.ReadValue(dataPt, valuePos, format, count, dirEnd - valuePos)
            et:HandleTag(tagTablePtr, tag, v, {
                DataPt = dataPt,
                DataPos = dataPos,
                Start = valuePos,
                Size = valueLen,
                Format = 'type=' .. type .. ', flags=' .. str(flags),
            })
        end
        -- extract sub-properties
        if numSubProps then
            local dirStart = valuePos + valueLen + numSubProps * 8
            local subInfo = {
                DataPt = dataPt,
                DataPos = dataPos,
                DirStart = dirStart,
                DirLen = pos + size - dirStart,
                Prefix = tag,
            }
            et:ProcessDirectory(subInfo, tagTablePtr)
        end
        pos = pos + size -- step to next Metadata structure
    end
    if pos ~= dirEnd then
        et:Warn('Format error in Real Metadata')
        return 0
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read information from a Real file (upstream ProcessReal)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid Real file
--------------------------------------------------------------------------------
function Real.ProcessReal(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, tag, vers
    local mimeTypes = {}
    local dirCount = {}

    local n0, b0 = raf:Read(8)
    if n0 ~= 8 then return 0 end
    buff = b0
    -- upstream: `$buff =~ m{^(\.RMF|\.ra\xfd|pnm://|rtsp://|http://)}`
    -- (PCRE2 via the facade -- Lua patterns have no alternation)
    local sig = perl.matches(buff, '^(\\.RMF|\\.ra\\xfd|pnm://|rtsp://|http://)')
    if not sig then return 0 end

    local type, tagTablePtr
    if sig == '.RMF' then
        tagTablePtr = et:GetTagTable('lexiftool.Real.Media')
        type = 'RM'
    elseif sig == '.ra\253' then
        tagTablePtr = et:GetTagTable('lexiftool.Real.Audio')
        type = 'RA'
    else
        tagTablePtr = et:GetTagTable('lexiftool.Real.Metafile')
        local ext = et.FILE_EXT
        type = (ext and ext == 'RPM') and 'RPM' or 'RAM'
        raf:Seek(0, 0)
        while true do
            local n, line = raf:ReadLine()
            if n == 0 then break end
            if #line > 256 then break end
            line = line:gsub('[\r\n]+$', '')
            if type then
                -- must be a Real file type if protocol is http
                -- upstream: `$buff !~ /\.(ra|rm|rv|rmvb|smil)$/i` (PCRE2 via
                -- the facade -- Lua patterns have no alternation)
                if line:match('^http') and not perl.matches(line, '(?i)\\.(ra|rm|rv|rmvb|smil)$') then return 0 end
                et:SetFileType(type)
                type = nil
            end
            -- save URL or Text from RAM file
            local t = line:match('^[a-z][a-z]?[a-z]?[a-z]?://') and 'url' or 'txt'
            et:HandleTag(tagTablePtr, t, line)
        end
        return 1
    end

    et:SetFileType(type)
    ExifTool.SetByteOrder('MM')
    --
    -- Process RealAudio file
    --
    if type == 'RA' then
        vers = ExifTool.Get16u(buff, 4)
        tag = '.ra' .. vers
        local fpos = raf:Tell()
        local n1, b1 = raf:Read(512)
        if n1 == 0 then
            et:Warn('Error reading audio header')
            return 1
        end
        buff = b1
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo then
            local subTablePtr = et:GetTagTable(tagInfo.SubDirectory.TagTable)
            local d = {
                DataPt = buff,
                DataPos = fpos,
                DirLen = #buff,
                DirStart = 0,
            }
            et:ProcessDirectory(d, subTablePtr)
        else
            et:Warn('Unsupported RealAudio version')
        end
        return 1
    end
    --
    -- Process RealMedia file
    --
    -- skip the rest of the RM header
    local size = ExifTool.Get32u(buff, 4)
    if not raf:Seek(size - 8, 1) then
        et:Warn('Error seeking in file')
        return 0
    end

    -- Process RealMedia chunks
    while true do
        local n2, b2 = raf:Read(10)
        if n2 ~= 10 then break end
        buff = b2
        tag = buff:sub(1, 4)
        size = ExifTool.Get32u(buff, 4)
        if tag == '\0\0\0\0' then break end
        if tag == 'DATA' then break end -- stop normal parsing at DATA tag
        if (size & 0x80000000) ~= 0 or size < 10 then
            et:Warn('Bad chunk header')
            break
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo and tagInfo.SubDirectory then
            local fpos = raf:Tell()
            local n3, b3 = raf:Read(size - 10)
            if n3 ~= size - 10 then
                et:Warn('Error reading ' .. tag .. ' chunk')
                break
            end
            buff = b3
            local subTablePtr = et:GetTagTable(tagInfo.SubDirectory.TagTable)
            local d = {
                DataPt = buff,
                DataPos = fpos,
                DirLen = #buff,
                DirStart = 0,
            }
            if dirCount[tag] then
                dirCount[tag] = dirCount[tag] + 1
                et.SET_GROUP1 = '+' .. dirCount[tag]
            else
                dirCount[tag] = 1
            end
            et:ProcessDirectory(d, subTablePtr)
            et.SET_GROUP1 = nil
            -- keep track of stream MIME types
            local mime = et.RealStreamMime
            if mime then
                et.RealStreamMime = nil
                mime = mime:gsub('\0.*', '')
                if not mime:match('^logical-') then
                    mimeTypes[#mimeTypes + 1] = mime
                end
            end
        else
            if not raf:Seek(size - 10, 1) then
                et:Warn('Error seeking in file')
                break
            end
        end
    end
    -- override MIMEType with stream MIME type if we only have one stream
    if #mimeTypes == 1 and #mimeTypes[1] > 0 then
        et.VALUE.MIMEType = mimeTypes[1]
    end
    --
    -- Process footer containing Real metadata and ID3 information
    --
    if raf:Seek(-140, 2) and (function() local nn, bb = raf:Read(12) buff = bb return nn == 12 end)() and
        buff:sub(1, 4) == 'RMJE' then
        local metaSize = ExifTool.Get32u(buff, 8)
        local n4, b4
        if raf:Seek(-metaSize - 12, 1) then n4, b4 = raf:Read(metaSize) end
        if n4 == metaSize and b4:sub(1, 4) == 'RJMD' then
            local d = {
                DataPt = b4,
                DataPos = raf:Tell() - metaSize,
                DirStart = 8,
                DirLen = #b4 - 8,
            }
            local metaTable = et:GetTagTable('lexiftool.Real.Metadata')
            et:ProcessDirectory(d, metaTable)
        else
            et:Warn('Bad metadata footer')
        end
        local n5, b5
        if raf:Seek(-128, 2) then n5, b5 = raf:Read(128) end
        if n5 == 128 and b5:sub(1, 3) == 'TAG' then
            local d = {
                DataPt = b5,
                DirStart = 0,
                DirLen = #b5,
            }
            local id3Table = et:GetTagTable('lexiftool.ID3.v1')
            et:ProcessDirectory(d, id3Table)
        end
    end
    return 1
end

-- (PROCESS_PROC set here so the tables can reference the process functions)
Real.FileInfo.PROCESS_PROC = Real.ProcessRealProperties
Real.Metadata.PROCESS_PROC = Real.ProcessRealMeta

return Real