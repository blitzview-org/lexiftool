--------------------------------------------------------------------------------
-- File:         lexiftool/Vorbis.lua
-- Ported from:  lib/Image/ExifTool/Vorbis.pm
--
-- Description:  Read Ogg Vorbis audio meta information
--
-- Revisions:    2006/11/10 - P. Harvey Created
--               2011/07/12 - PH Moved Ogg to a separate module and added Theora
--
-- References:   1) http://www.xiph.org/vorbis/doc/
--               2) http://flac.sourceforge.net/ogg_mapping.html
--               3) http://www.theora.org/doc/Theora.pdf
--
-- Port notes:   complete: Main/Identification/Comments tables (including
--               the base64 COVERART and METADATA_BLOCK_PICTURE decodes, the
--               latter dispatched into FLAC.Picture), ProcessComments (the
--               comment-header walker) and the Duration composite. The
--               Theora tables live in Theora.lua, as upstream.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local lc = require('lexiftool.perl').lc
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst
local subst = require('lexiftool.perl').subst
local matches = require('lexiftool.perl').matches
local length = require('lexiftool.perl').length
local perlTruthy = require('lexiftool.perl').truthy
local Get32u = ExifTool.Get32u
local AddTagToTable = ExifTool.AddTagToTable

local Vorbis = {}

-- Vorbis header types (upstream %Image::ExifTool::Vorbis::Main)
Vorbis.Main = {
    NOTES = [[
        Information extracted from Ogg Vorbis files.  See
        L<http://www.xiph.org/vorbis/doc/> for the Vorbis specification.
    ]],
    [1] = {
        Name = 'Identification',
        SubDirectory = { TagTable = 'lexiftool.Vorbis.Identification' },
    },
    [3] = {
        Name = 'Comments',
        SubDirectory = { TagTable = 'lexiftool.Vorbis.Comments' },
    },
}

-- Vorbis identification header (upstream %Vorbis::Identification)
Vorbis.Identification = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    [0] = {
        Name = 'VorbisVersion',
        Format = 'int32u',
    },
    [4] = 'AudioChannels',
    [5] = {
        Name = 'SampleRate',
        Format = 'int32u',
    },
    [9] = {
        Name = 'MaximumBitrate',
        Format = 'int32u',
        RawConv = function(_self, val)
            -- (Perl truthiness: a 0 bitrate is dropped; ProcessBinaryData
            --  yields whole numbers that stringify without a decimal point)
            if val == 0 or val == '0' then return nil end
            return val
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
    [13] = {
        Name = 'NominalBitrate',
        Format = 'int32u',
        RawConv = function(_self, val)
            -- (Perl truthiness: a 0 bitrate is dropped; ProcessBinaryData
            --  yields whole numbers that stringify without a decimal point)
            if val == 0 or val == '0' then return nil end
            return val
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
    [17] = {
        Name = 'MinimumBitrate',
        Format = 'int32u',
        RawConv = function(_self, val)
            -- (Perl truthiness: a 0 bitrate is dropped; ProcessBinaryData
            --  yields whole numbers that stringify without a decimal point)
            if val == 0 or val == '0' then return nil end
            return val
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
}

-- Vorbis comment tags (upstream %Vorbis::Comments)
Vorbis.Comments = {
    PROCESS_PROC = false, -- set below to Vorbis.ProcessComments
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        The tags below are only some common tags found in the Vorbis comments of Ogg
        Vorbis and Ogg FLAC audio files, however ExifTool will extract values from
        any tag found, even if not listed here.
    ]],
    vendor = { Notes = 'from comment header' },
    TITLE = { Name = 'Title' },
    VERSION = { Name = 'Version' },
    ALBUM = { Name = 'Album' },
    TRACKNUMBER = { Name = 'TrackNumber' },
    ARTIST = { Name = 'Artist', Groups = { [2] = 'Author' }, List = 1 },
    PERFORMER = { Name = 'Performer', Groups = { [2] = 'Author' }, List = 1 },
    COPYRIGHT = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    LICENSE = { Name = 'License', Groups = { [2] = 'Author' } },
    ORGANIZATION = { Name = 'Organization', Groups = { [2] = 'Author' } },
    DESCRIPTION = { Name = 'Description' },
    GENRE = { Name = 'Genre' },
    DATE = { Name = 'Date', Groups = { [2] = 'Time' } },
    LOCATION = { Name = 'Location', Groups = { [2] = 'Location' } },
    CONTACT = { Name = 'Contact', Groups = { [2] = 'Author' }, List = 1 },
    ISRC = { Name = 'ISRCNumber' },
    COVERARTMIME = { Name = 'CoverArtMIMEType' },
    COVERART = {
        Name = 'CoverArt',
        Groups = { [2] = 'Preview' },
        Notes = 'base64-encoded image',
        ValueConv = function(_self, val)
            return { ref = 'SCALAR', value = require('lexiftool.XMP').DecodeBase64(val) }
        end,
    },
    REPLAYGAIN_TRACK_PEAK = { Name = 'ReplayGainTrackPeak' },
    REPLAYGAIN_TRACK_GAIN = { Name = 'ReplayGainTrackGain' },
    REPLAYGAIN_ALBUM_PEAK = { Name = 'ReplayGainAlbumPeak' },
    REPLAYGAIN_ALBUM_GAIN = { Name = 'ReplayGainAlbumGain' },
    ENCODED_USING = { Name = 'EncodedUsing' },
    ENCODED_BY = { Name = 'EncodedBy' },
    COMMENT = { Name = 'Comment' },
    DIRECTOR = { Name = 'Director' },
    PRODUCER = { Name = 'Producer' },
    COMPOSER = { Name = 'Composer' },
    ACTOR = { Name = 'Actor' },
    -- Opus tags
    ENCODER = { Name = 'Encoder' },
    ENCODER_OPTIONS = { Name = 'EncoderOptions' },
    METADATA_BLOCK_PICTURE = {
        Name = 'Picture',
        Binary = 1,
        RawConv = function(_self, val)
            return { ref = 'SCALAR', value = require('lexiftool.XMP').DecodeBase64(val) }
        end,
        SubDirectory = {
            TagTable = 'lexiftool.FLAC.Picture',
            ByteOrder = 'BigEndian',
        },
    },
}

-- Vorbis composite tags (upstream %Vorbis::Composite)
Vorbis.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
    Duration = {
        TagID = 'Vorbis-Duration',
        Require = {
            [0] = 'Vorbis:NominalBitrate',
            [1] = 'FileSize',
        },
        RawConv = function(_self, val)
            -- (Perl truthiness: a 0 NominalBitrate must not build)
            if not (val[0] and val[0] ~= 0) then return nil end
            return val[1] * 8 / val[0]
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) .. ' (approx)' end, -- (only approximate)
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.Vorbis', nil, Vorbis)

--------------------------------------------------------------------------------
-- Process Vorbis Comments (upstream ProcessComments)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
--------------------------------------------------------------------------------
function Vorbis.ProcessComments(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local pos = perlTruthy(dirInfo.DirStart) and dirInfo.DirStart or 0
    local endPos = perlTruthy(dirInfo.DirLen) and pos + dirInfo.DirLen or length(dataPt)
    local num, index

    ExifTool.SetByteOrder('II')
    while true do
        if pos + 4 > endPos then break end
        local len = Get32u(dataPt, pos)
        if pos + 4 + len > endPos then break end
        local start = pos + 4
        local buff = substr(dataPt, start, len)
        pos = start + len
        local tag, val
        if num ~= nil then
            local m1, m2 = matches(buff, [[(?s)(.*?)=(.*)]])
            if not m1 then break end
            tag, val = uc(m1), m2
            -- Vorbis tag ID's are all capitals, so they may conflict with our internal tags
            -- --> protect against this by adding a trailing underline if necessary
            if ExifTool.specialTags[tag] then tag = tag .. '_' end
        else
            tag = 'vendor'
            val = buff
            num = (pos + 4 < endPos) and Get32u(dataPt, pos) or 0
            et:VPrint(0, "  + [Vorbis comments with " .. num .. " entries]\n")
            pos = pos + 4
        end
        -- add tag to table unless it exists already
        if not tagTablePtr[tag] then
            local name = ucfirst(lc(tag))
            -- remove invalid characters in tag name and capitalize following letters
            name = subst(name, [[(?s)[^\w-]+(.?)]], function(c) return uc(c) end, 'g')
            name = subst(name, [[([a-z0-9])_([a-z])]], function(c1, c2) return c1 .. uc(c2) end, 'g')
            et:VPrint(0, "  | [adding " .. tag .. "]\n")
            AddTagToTable(nil, tagTablePtr, tag, { Name = name })
        end
        et:HandleTag(tagTablePtr, tag, et:Decode(val, 'UTF8'), {
            Index   = index,
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = start,
            Size    = len,
        })
        -- all done if this was our last tag
        local last = num
        num = num - 1
        if not perlTruthy(last) then return 1 end
        index = (index ~= nil) and index + 1 or 0
    end
    et:Warn('Format error in Vorbis comments')
    return 0
end

-- (PROCESS_PROC set here so the table can reference the function above)
Vorbis.Comments.PROCESS_PROC = Vorbis.ProcessComments

return Vorbis