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
-- Port notes:   read subset: ProcessAPE (MAC header + trailing APEv1/v2 tag
--               block) and the Main/OldHeader/NewHeader/Composite tables.
--               Deferred: the leading `ProcessID3` check (upstream skips
--               straight to APE if an APE file has no ID3 header, so this
--               subset omits the check and always tries APE directly; ID3
--               itself is unported), and the composite Require entries'
--               `Group:Name` qualifiers (this port's simplified
--               BuildCompositeTags only matches bare tag names -- see
--               `lexiftool.lua`).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local subst = require('lexiftool.perl').subst
local matches = require('lexiftool.perl').matches
local lc = require('lexiftool.perl').lc
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst

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
-- Make tag info for a dynamically-discovered APE tag
-- Inputs: 0) et, 1) tag name, 2) tag table ref
--------------------------------------------------------------------------------
local function MakeTag(et, tag, tagTablePtr)
    local name = ucfirst(lc(tag))
    -- remove invalid characters in tag name and capitalize following letters
    name = subst(name, [[(?s)[^\w-]+(.?)]], function(c) return uc(c) end, 'g')
    name = subst(name, [[([a-z0-9])_([a-z])]], function(a, b) return a .. uc(b) end, 'g')
    local tagInfo = { Name = name }
    if tag:match('^Cover Art') and not tag:match('Desc$') then
        tagInfo.Groups = { [2] = 'Preview' }
    end
    et:AddTagToTable(tagTablePtr, tag, tagInfo)
end

--------------------------------------------------------------------------------
-- Extract information from an APE file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid APE file
--------------------------------------------------------------------------------
function APE.ProcessAPE(et, dirInfo)
    -- must first check for leading/trailing ID3 information
    if not et.DoneID3 then
        local ID3 = require('lexiftool.ID3')
        local id3rtn = ID3.ProcessID3(et, dirInfo)
        -- (Perl truthiness: ProcessID3 returns 0 for "no ID3 header", which
        --  is falsy in Perl but truthy in Lua)
        if id3rtn and id3rtn ~= 0 then return 1 end
    end
    local raf = dirInfo.RAF
    local header, buff

    et.DoneAPE = 1

    -- check APE signature and process audio information
    -- unless this is some other type of file
    if not et.FileType then
        local n
        n, buff = raf:Read(32)
        if n ~= 32 then return 0 end
        -- upstream: `$buff =~ /^(MAC |APETAGEX)/ or return 0` (PCRE2 via the
        -- facade -- Lua patterns have no alternation)
        if not matches(buff, '^(MAC |APETAGEX)') then return 0 end
        et:SetFileType()
        ExifTool.SetByteOrder('II')

        if buff:sub(1, 8) == 'APETAGEX' then
            -- we already read the APE header
            header = 1
        else
            -- process the MAC header
            local vers = ExifTool.Get16u(buff, 4)
            local table_
            if vers <= 3970 then
                local hdrBuf = buff:sub(5)
                table_ = et:GetTagTable('lexiftool.APE.OldHeader')
                if table_ then et:ProcessDirectory({ DataPt = hdrBuf }, table_) end
            else
                local dlen = ExifTool.Get32u(buff, 8)
                local hlen = ExifTool.Get32u(buff, 12)
                if dlen & 0x80000000 == 0 and hlen & 0x80000000 == 0 and raf:Seek(dlen, 0) then
                    local n2, hbuf = raf:Read(hlen)
                    if n2 == hlen then
                        table_ = et:GetTagTable('lexiftool.APE.NewHeader')
                        et:ProcessDirectory({ DataPt = hbuf }, table_)
                    end
                end
            end
        end
    end
    -- look for APE trailer unless we already found an APE header
    if not header then
        -- look for the APE trailer footer, but before the ID3v1 trailer if it
        -- exists (upstream: `$footPos = -32; $footPos -= $$et{DoneID3} if
        --  $$et{DoneID3} > 1` -- ID3.ProcessID3 sets DoneID3 to the ID3v1
        --  trailer size, 128, when an ID3v1 trailer is present)
        local footPos = -32
        if et.DoneID3 and et.DoneID3 > 1 then footPos = footPos - et.DoneID3 end
        if not raf:Seek(footPos, 2) then return 1 end
        local n
        n, buff = raf:Read(32)
        if n ~= 32 or buff:sub(1, 8) ~= 'APETAGEX' then return 1 end
        ExifTool.SetByteOrder('II')
    end

    -- Read the APE data (we have just read the APE header or footer into buff)
    local version = ExifTool.Get32u(buff, 8) / 1000
    local size = ExifTool.Get32u(buff, 12)
    local count = ExifTool.Get32u(buff, 16)
    -- (Get32u(buff, 20) is Flags; not used in this read subset)
    size = size - 32 -- get size of data only

    local verbose = et:Options('Verbose')
    local oldIndent
    local tagTablePtr, dataPos
    if size & 0x80000000 == 0 and (header or raf:Seek(-size - 32, 1)) then
        local n3, dbuf = raf:Read(size)
        if n3 == size then
            buff = dbuf
            if perlTruthy(verbose) then
                oldIndent = et.INDENT
                et.INDENT = et.INDENT .. '| '
                et:VerboseDir('APEv' .. ExifTool.NumStr(version), count, size)
                et:VerboseDump(buff, { DataPos = raf:Tell() - size })
            end
            tagTablePtr = et:GetTagTable('lexiftool.APE.Main')
            dataPos = raf:Tell() - size
        else
            count = -1
        end
    else
        count = -1
    end

    -- Process the APE tags
    local pos = 0
    local i = 0
    while i < count do
        -- read next APE tag
        if pos + 8 > size then break end
        local len = ExifTool.Get32u(buff, pos)
        local flags = ExifTool.Get32u(buff, pos + 4)
        local nulPos = buff:find('\0', pos + 9, true)
        if not nulPos then break end
        local tag = buff:sub(pos + 9, nulPos - 1)
        -- avoid conflicts with our special table entries
        if ExifTool.specialTags[tag] then tag = tag .. '.' end
        pos = nulPos -- (0-based position just after the NUL, i.e. Lua nulPos)
        if pos + len > size then break end
        local val = buff:sub(pos + 1, pos + len)
        if not tagTablePtr[tag] then MakeTag(et, tag, tagTablePtr) end
        -- handle binary-value tags
        if flags & 0x06 == 0x02 then
            -- extract cover art description separately (hackitty hack)
            if tag:match('^Cover Art') then
                local descEnd = 1
                while descEnd <= #val and val:byte(descEnd) >= 0x20 and val:byte(descEnd) <= 0x7e do
                    descEnd = descEnd + 1
                end
                if descEnd <= #val and val:byte(descEnd) == 0 then
                    local desc = val:sub(1, descEnd - 1)
                    val = val:sub(descEnd + 1) -- (upstream: the s/// strips the description in place)
                    if #desc > 0 then
                        local descTag = tag .. ' Desc'
                        if not tagTablePtr[descTag] then MakeTag(et, descTag, tagTablePtr) end
                        et:HandleTag(tagTablePtr, descTag, desc)
                    end
                end
            end
            val = { ref = 'SCALAR', value = val }
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
    if oldIndent then et.INDENT = oldIndent end

    return 1
end

return APE
