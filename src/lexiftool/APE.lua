--------------------------------------------------------------------------------
-- File:         lexiftool/APE.lua
-- Ported from:  lib/Image/ExifTool/APE.pm
--
-- Description:  Read Monkey's Audio meta information
--
-- Revisions:    11/13/2006 - P. Harvey Created
--
-- References:   1) http://www.monkeysaudio.com/
--               2) http://www.personal.uni-jena.de/~pfk/mpp/sv8/apetag.html
--
-- Port notes:   Complete port of APE.pm (read-only upstream as well):
--               the Main/OldHeader/NewHeader/Composite tables, MakeTag and
--               ProcessAPE including the leading ProcessID3 check.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local subst = require('lexiftool.perl').subst
local matches = require('lexiftool.perl').matches
local lc = require('lexiftool.perl').lc
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst
local isMatch = require('lexiftool.perl').isMatch
local substr = require('lexiftool.perl').substr
local unpack = require('lexiftool.perl').unpack
local str = require('lexiftool.perl').str
local perl = require('lexiftool.perl')
local SetByteOrder = ExifTool.SetByteOrder
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable

local APE = {}

-- APE metadata blocks
APE.Main = {
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        Tags found in Monkey's Audio (APE) information.  Only a few common tags are
        listed below, but ExifTool will extract any tag found.  ExifTool supports
        APEv1 and APEv2 tags, as well as ID3 information in APE files, and will also
        read APE metadata from MP3 and MPC files.
    ]],
    Album = {},
    Artist = {},
    Genre = {},
    Title = {},
    Track = {},
    Year = {},
    DURATION = {
        Name = 'Duration',
        ValueConv = function(_self, val)
            if val < 0 and val >= -2147483648 then val = val + 4294967296 end
            return val * 1e-7
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    ['Tool Version'] = { Name = 'ToolVersion' },
    ['Tool Name'] = { Name = 'ToolName' },
}

-- APE MAC header version 3.97 or earlier
APE.OldHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'MAC', [2] = 'Audio' },
    FORMAT = 'int16u',
    NOTES = 'APE MAC audio header for version 3.97 or earlier.',
    [0] = {
        Name = 'APEVersion',
        ValueConv = function(_self, val) return val / 1000 end,
    },
    [1] = 'CompressionLevel',
    -- 2 => 'FormatFlags',
    [3] = 'Channels',
    [4] = { Name = 'SampleRate', Format = 'int32u' },
    -- 6 => HeaderBytes (WAV header bytes), 8 => TerminatingBytes
    [10] = { Name = 'TotalFrames', Format = 'int32u' },
    [12] = { Name = 'FinalFrameBlocks', Format = 'int32u' },
}

-- APE MAC header version 3.98 or later
APE.NewHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'MAC', [2] = 'Audio' },
    FORMAT = 'int16u',
    NOTES = 'APE MAC audio header for version 3.98 or later.',
    [0] = 'CompressionLevel',
    -- 1 => 'FormatFlags',
    [2] = { Name = 'BlocksPerFrame', Format = 'int32u' },
    [4] = { Name = 'FinalFrameBlocks', Format = 'int32u' },
    [6] = { Name = 'TotalFrames', Format = 'int32u' },
    [8] = 'BitsPerSample',
    [9] = 'Channels',
    [10] = { Name = 'SampleRate', Format = 'int32u' },
}

-- APE Composite tags
APE.Composite = {
    GROUPS = { [2] = 'Audio' },
    Duration = {
        TagID = 'APE-Duration',
        Require = {
            [0] = 'APE:SampleRate',
            [1] = 'APE:TotalFrames',
            [2] = 'APE:BlocksPerFrame',
            [3] = 'APE:FinalFrameBlocks',
        },
        RawConv = function(_self, val)
            if not (perlTruthy(val[0]) and perlTruthy(val[1])) then return nil end
            return ((val[1] - 1) * val[2] + val[3]) / val[0]
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.APE', nil, APE)

--------------------------------------------------------------------------------
-- Make tag info hash for specified tag
-- Inputs: 0) tag name, 1) tag table ref
-- - must only call if tag doesn't exist
--------------------------------------------------------------------------------
local function MakeTag(tag, tagTablePtr)
    local name = ucfirst(lc(tag))
    -- remove invalid characters in tag name and capitalize following letters
    name = subst(name, [[(?s)[^\w-]+(.?)]], function(c) return uc(c) end, 'g')
    name = subst(name, [[([a-z0-9])_([a-z])]], function(c1, c2) return c1 .. uc(c2) end, 'g')
    local tagInfo = { Name = name }
    if isMatch(tag, '^Cover Art') and not isMatch(tag, 'Desc$') then tagInfo.Groups = { [2] = 'Preview' } end
    AddTagToTable(nil, tagTablePtr, tag, tagInfo)
end

--------------------------------------------------------------------------------
-- Extract information from an APE file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- - Just looks for APE trailer if FileType is already set
-- Returns: 1 on success, 0 if this wasn't a valid APE file
--------------------------------------------------------------------------------
function APE.ProcessAPE(et, dirInfo)

    -- must first check for leading/trailing ID3 information
    if not perlTruthy(et.DoneID3) then
        local ID3 = require('lexiftool.ID3')
        if perlTruthy(ID3.ProcessID3(et, dirInfo)) then return 1 end
    end
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local buff, i, header, tagTablePtr, dataPos, oldIndent, n

    et.DoneAPE = 1

    -- check APE signature and process audio information
    -- unless this is some other type of file
    if not perlTruthy(et.FileType) then
        n, buff = raf:Read(32)
        if n ~= 32 then return 0 end
        if not isMatch(buff, '^(MAC |APETAGEX)') then return 0 end
        et:SetFileType()
        SetByteOrder('II')

        if isMatch(buff, '^APETAGEX') then
            -- we already read the APE header
            header = 1
        else
            -- process the MAC header
            local vers = Get16u(buff, 4)
            local table_
            if vers <= 3970 then
                buff = substr(buff, 4)
                table_ = GetTagTable(nil, 'lexiftool.APE.OldHeader')
            else
                local dlen = Get32u(buff, 8)
                local hlen = Get32u(buff, 12)
                if not (dlen & 0x80000000 ~= 0 or hlen & 0x80000000 ~= 0) then
                    if raf:Seek(dlen, 0) then
                        n, buff = raf:Read(hlen)
                        if n == hlen then
                            table_ = GetTagTable(nil, 'lexiftool.APE.NewHeader')
                        end
                    end
                end
            end
            if table_ then et:ProcessDirectory({ DataPt = buff }, table_) end
        end
    end
    -- look for APE trailer unless we already found an APE header
    if not header then
        -- look for the APE trailer footer...
        local footPos = -32
        -- (...but before the ID3v1 trailer if it exists)
        if perl.num(et.DoneID3) > 1 then footPos = footPos - et.DoneID3 end
        if not raf:Seek(footPos, 2) then return 1 end
        n, buff = raf:Read(32)
        if n ~= 32 then return 1 end
        if not isMatch(buff, '^APETAGEX') then return 1 end
        SetByteOrder('II')
    end
--
-- Read the APE data (we have just read the APE header or footer into $buff)
--
    local version, size, count, flags = unpack('x8V4', buff) -- luacheck: ignore 211
    version = version / 1000
    size = size - 32    -- get size of data only
    local ok = (size & 0x80000000) == 0 and
        (header or raf:Seek(-size - 32, 1))
    if ok then n, buff = raf:Read(size) ok = n == size end
    if ok then
        if perlTruthy(verbose) then
            oldIndent = et.INDENT
            et.INDENT = et.INDENT .. '| '
            et:VerboseDir("APEv" .. str(version), count, size)
            et:VerboseDump(buff, { DataPos = raf:Tell() - size })
        end
        tagTablePtr = GetTagTable(nil, 'lexiftool.APE.Main')
        dataPos = raf:Tell() - size
    else
        count = -1
    end
--
-- Process the APE tags
--
    local pos = 0
    i = 0
    while i < count do
        -- read next APE tag
        if pos + 8 > size then break end
        local len = Get32u(buff, pos)
        local flags_ = Get32u(buff, pos + 4)
        local m1, posBuff = matches(buff, [[(?s)\G(.*?)\0]], pos + 8)
        if m1 == nil then break end
        local tag = m1
        -- avoid conflicts with our special table entries
        if ExifTool.specialTags[tag] then tag = tag .. '.' end
        pos = posBuff
        if pos + len > size then break end
        local val = substr(buff, pos, len)
        if not tagTablePtr[tag] then MakeTag(tag, tagTablePtr) end
        -- handle binary-value tags
        if (flags_ & 0x06) == 0x02 then
            local buf2 = val
            -- extract cover art description separately (hackitty hack)
            if isMatch(tag, '^Cover Art') then
                local c1 = m1   -- ($1 keeps the last successful match if the s/// fails)
                buf2 = subst(buf2, [[^([\x20-\x7e]*)\0]], function(d) c1 = d return '' end)
                if perlTruthy(c1) then
                    local t = tag .. " Desc"
                    local v = c1
                    if not tagTablePtr[t] then MakeTag(t, tagTablePtr) end
                    et:HandleTag(tagTablePtr, t, v)
                end
            end
            val = { ref = 'SCALAR', value = buf2 }
        end
        et:HandleTag(tagTablePtr, tag, val, {
            Index = i,
            DataPt = buff,
            DataPos = dataPos,
            Start = pos,
            Size = len,
        })
        pos = pos + len
        i = i + 1
    end
    if i ~= count then et:Warn('Bad APE trailer') end
    if oldIndent ~= nil then et.INDENT = oldIndent end
    return 1
end

return APE
