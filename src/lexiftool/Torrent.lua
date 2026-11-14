--------------------------------------------------------------------------------
-- File:         lexiftool/Torrent.lua
-- Ported from:  lib/Image/ExifTool/Torrent.pm
--
-- Description:  Read information from BitTorrent file
--
-- Revisions:    2013/08/27 - P. Harvey Created
--
-- References:   1) https://wiki.theory.org/BitTorrentSpecification
--
-- Port notes:   Complete port of Torrent.pm: every table and sub, in upstream
--               order.  Deviations forced by Lua:
--               - The buffer ref with its pos() is a table { data, pos }
--                 (pos nil = Perl's undef pos), as in Import.lua; the
--                 BencodeEOF/BencodeError members are set on the RAF object
--                 as upstream.
--               - A bencoded list is a Lua array and a dictionary a table
--                 with string keys (isArray/isHash stand for Perl's
--                 `ref $val eq 'ARRAY'/'HASH'`); an empty dictionary is
--                 indistinguishable from an empty list and is treated as one
--                 (both yield no tags), and a byte string value is
--                 { ref = 'SCALAR', value = ... } where upstream returns a
--                 SCALAR ref.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local tr = perl.tr
local join = perl.join
local ucfirst = perl.ucfirst
local length = perl.length
local substr = perl.substr
local truthy = perl.truthy
local tsort = perl.tsort
local str = perl.str
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ConvertUnixTime = ExifTool.ConvertUnixTime
local ConvertFileSize = ExifTool.ConvertFileSize

local Torrent = {}

-- (upstream's predeclarations; the subs below assign to them)
local ReadBencode
local ExtractTags

-- (port helpers: Perl's `ref $val eq 'ARRAY'` / `ref $val eq 'HASH'`)
local function isArray(v)
    return type(v) == 'table' and v.ref == nil and (v[1] ~= nil or next(v) == nil)
end
local function isHash(v)
    return type(v) == 'table' and v.ref == nil and not isArray(v)
end

-- tags extracted from BitTorrent files
-- tags extracted from BitTorrent files
Torrent.Main = {
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        Below are tags commonly found in BitTorrent files.  As well as these tags,
        any other existing tags will be extracted.  For convenience, list items are
        expanded into individual tags with an index in the tag name, but only the
        tags with index "1" are listed in the tables below.  See
        L<https://wiki.theory.org/BitTorrentSpecification> for the BitTorrent
        specification.
    ]],
    ['announce']      = { },
    ['announce-list'] = { Name = 'AnnounceList1' },
    ['comment']       = { },
    ['created by']    = { Name = 'Creator' }, -- software used to create the torrent
    ['creation date'] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['encoding']      = { },
    ['info']          = {
        SubDirectory = { TagTable = 'lexiftool.Torrent.Info' },
        Notes = 'extracted as a structure with the Struct option',
    },
    ['url-list']      = { Name = 'URLList1' },
}

Torrent.Info = {
    GROUPS = { [2] = 'Document' },
    ['file-duration'] = { Name = 'File1Duration' },
    ['file-media']    = { Name = 'File1Media' },
    ['files']         = { SubDirectory = { TagTable = 'lexiftool.Torrent.Files' } },
    ['length']        = { },
    ['md5sum']        = { Name = 'MD5Sum' },
    ['name']          = { },
    ['name.utf-8']    = { Name = 'NameUTF-8' },
    ['piece length']  = { Name = 'PieceLength' },
    ['pieces']        = {
        Name = 'Pieces',
        Notes = 'concatenation of 20-byte SHA-1 digests for each piece',
    },
    ['private']       = { },
    ['profiles']      = { SubDirectory = { TagTable = 'lexiftool.Torrent.Profiles' } },
}

Torrent.Profiles = {
    GROUPS = { [2] = 'Document' },
    ['width']         = { Name = 'Profile1Width' },
    ['height']        = { Name = 'Profile1Height' },
    ['acodec']        = { Name = 'Profile1AudioCodec' },
    ['vcodec']        = { Name = 'Profile1VideoCodec' },
}

Torrent.Files = {
    GROUPS = { [2] = 'Document' },
    ['length']        = { Name = 'File1Length', PrintConv = function(_self, val) return ConvertFileSize(val) end },
    ['md5sum']        = { Name = 'File1MD5Sum'  },
    ['path']          = { Name = 'File1Path', JoinPath = 1 },
    ['path.utf-8']    = { Name = 'File1PathUTF-8', JoinPath = 1 },
}

--------------------------------------------------------------------------------
-- Read 64kB more data into buffer
-- Inputs: 0) RAF ref, 1) buffer ref
-- Returns: number of bytes read
-- Notes: Sets BencodeEOF element of RAF on end of file
function Torrent.ReadMore(raf, dataPt)
    local n, buf2 = raf:Read(65536)
    if n ~= 65536 then raf.BencodeEOF = 1 end
    if truthy(n) then
        dataPt.data = substr(dataPt.data, dataPt.pos or 0) .. buf2
        dataPt.pos = 0  -- (a new string starts with pos 0)
    end
    return n
end

--------------------------------------------------------------------------------
-- Read bencoded value
-- Inputs: 0) ExifTool ref, 1) input file, 2) buffer (pos must be set to current position)
-- Returns: HASH ref, ARRAY ref, SCALAR ref, SCALAR, or undef on error or end of data
-- Notes: Sets BencodeError element of RAF on any error
function ReadBencode(et, raf, dataPt)
    -- read more if necessary (keep a minimum of 64 bytes in the buffer)
    local pos = dataPt.pos
    if pos == nil then return nil end
    local remaining = length(dataPt.data) - pos
    if remaining < 64 and not raf.BencodeEOF then Torrent.ReadMore(raf, dataPt) end

    -- read next token
    local tok, e = matches(dataPt.data, '(?s)(.)', dataPt.pos)
    if e == nil then dataPt.pos = nil return nil end
    dataPt.pos = e

    local val
    if tok == 'i' then      -- integer
        local v, e2 = matches(dataPt.data, [[\G(-?\d+)e]], dataPt.pos)
        if e2 == nil then dataPt.pos = nil return nil end
        dataPt.pos = e2
        val = v
    elseif tok == 'd' then -- dictionary
        val = { }
        while true do
            local k = ReadBencode(et, raf, dataPt)
            if k == nil then break end
            -- the key must be a byte string
            if type(k) == 'table' then
                if k.ref ~= 'SCALAR' then raf.BencodeError = 'Bad dictionary key' break end
                k = k.value
            end
            local v = ReadBencode(et, raf, dataPt)
            if v == nil then break end
            val[k] = v
        end
    elseif tok == 'l' then -- list
        val = { }
        while true do
            local v = ReadBencode(et, raf, dataPt)
            if v == nil then break end
            val[#val + 1] = v
        end
    elseif tok == 'e' then -- luacheck: ignore 542
        -- (end of dictionary or list)
        -- return undef (no error)
    elseif isMatch(tok, [[^\d$]]) and (function()
                local d, e3 = matches(dataPt.data, [[\G(\d*):]], dataPt.pos)
                if e3 == nil then dataPt.pos = nil return false end
                dataPt.pos = e3
                tok = tok .. d   -- (my $len = $tok . $1)
                return true
            end)() then -- byte string
        local len = perl.num(tok)
        local more = len - (length(dataPt.data) - dataPt.pos)
        local value
        if more <= 0 then
            value = substr(dataPt.data, dataPt.pos, len)
            dataPt.pos = dataPt.pos + len
        elseif more > 10000000 then
            -- just skip over really long values
            if raf:Seek(more, 1) then val = { ref = 'SCALAR', value = "(Binary data " .. len .. " bytes)" } end
        else
            -- need to read more from file
            local n, buff = raf:Read(more)
            if n == more then
                value = substr(dataPt.data, dataPt.pos) .. buff
                dataPt.data = ''
                dataPt.pos = 0
            end
        end
        if value ~= nil then
            -- return as binary data unless it is a reasonable-length ASCII string
            if length(value) > 256 then
                val = { ref = 'SCALAR', value = value }
            elseif isMatch(value, [=[[^\t\x20-\x7e]]=]) then
                if ExifTool.IsUTF8(value) >= 0 then
                    val = et:Decode(value, 'UTF8')
                else
                    val = { ref = 'SCALAR', value = value }
                end
            else
                val = value
            end
        elseif val == nil then
            raf.BencodeError = 'Truncated byte string'
        end
    else
        raf.BencodeError = 'Bad format'
    end
    return val
end
Torrent.ReadBencode = ReadBencode

--------------------------------------------------------------------------------
-- Extract tags from dictionary hash
-- Inputs: 0) ExifTool ref, 1) dictionary hash reference, 2) tag table ref,
--         3) parent hash ID, 4) parent hash name, 5-N) list indices
-- Returns: number of tags extracted
function ExtractTags(et, hashPtr, tagTablePtr, baseID, baseName, ...)
    local index = { ... }
    local count = 0
    local keys = { }
    for k in pairs(hashPtr) do keys[#keys + 1] = k end
    tsort(keys)
    for _, tag in ipairs(keys) do
        local val = hashPtr[tag]
        local i, more = nil, { }
        while val ~= nil do
            local id = baseID ~= nil and baseID .. "/" .. tag or tag
            if not tagTablePtr[id] then
                local name = ucfirst(tag)
                -- capitalize all words in tag name and remove illegal characters
                name = subst(name, '[^-_a-zA-Z0-9]+(.?)', function(c) return perl.uc(c) end, 'g')
                if length(name) < 2 or not isMatch(name, '^[A-Z]') then name = "Tag" .. name end
                if baseName ~= nil then name = baseName .. name end -- add base name if necessary
                AddTagToTable(nil, tagTablePtr, id, { Name = name })
                et:VPrint(0, "  [adding " .. id .. " '" .. name .. "']\n")
            end
            local tagInfo = et:GetTagInfo(tagTablePtr, id)
            if not tagInfo then goto next_ end
            if isArray(val) then
                if truthy(tagInfo.JoinPath) then
                    local parts = { }
                    for k = 1, #val do parts[k] = type(val[k]) == 'table' and '(Binary data)' or val[k] end
                    val = join('/', parts)
                else
                    if #val == 0 then goto next_ end  -- ignore empty arrays
                    for k = 1, #val do more[#more + 1] = val[k] end
                    if isArray(more[1]) then goto next_ end -- continue expanding nested lists
                    val = table.remove(more, 1)
                    if not truthy(i) then
                        i = 0
                        index[#index + 1] = i
                    end
                end
            end
            if i ~= nil then
                i = i + 1
                index[#index] = i
            end
            if #index > 0 then
                id = id .. join('_', index)   -- add instance number(s) to tag ID
                if not tagTablePtr[id] then
                    local name = tagInfo.Name
                    -- embed indices at position of '1' in tag name
                    local n
                    name, n = tr(name, '1', '#')
                    local j = 0
                    while j < n do
                        local idx = truthy(index[j + 1]) and index[j + 1] or ''
                        name = subst(name, '#', str(idx))
                        j = j + 1
                    end
                    -- put remaining indices at end of tag name
                    while j < #index do
                        if isMatch(name, [[\d$]]) then name = name .. '_' end
                        name = name .. index[j + 1]
                        j = j + 1
                    end
                    local newInfo = { }
                    for k, v in pairs(tagInfo) do newInfo[k] = v end
                    newInfo.Name = name
                    AddTagToTable(nil, tagTablePtr, id, newInfo)
                end
                tagInfo = et:GetTagInfo(tagTablePtr, id)
                if not tagInfo then goto next_ end
            end
            if isHash(val) then
                if truthy(et:Options('Struct')) and tagInfo and tagInfo.Name == 'Info' then
                    et:FoundTag(tagInfo, val)
                    count = count + 1
                    goto next_
                end
                -- extract tags from this dictionary
                local table_, rootID, rootName
                if tagInfo.SubDirectory then
                    table_ = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                else
                    table_ = tagTablePtr
                    -- use hash ID and Name as base for contained tags to avoid conflicts
                    rootID = id
                    rootName = tagInfo.Name
                end
                count = count + ExtractTags(et, val, table_, rootID, rootName, table.unpack(index))
            else
                -- handle this simple tag value
                et:HandleTag(tagTablePtr, id, val)
                count = count + 1
            end
            ::next_::
            val = table.remove(more, 1)
        end
        if i ~= nil then index[#index] = nil end
    end
    return count
end
Torrent.ExtractTags = ExtractTags

--------------------------------------------------------------------------------
-- Process BitTorrent file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference (with RAF set)
-- Returns: 1 on success, 0 if this wasn't a valid BitTorrent file
function Torrent.ProcessTorrent(et, dirInfo)
    local success = 0
    local raf = dirInfo.RAF
    local buff = { data = '' }
    buff.pos = 0
    local dict = ReadBencode(et, raf, buff)
    local err = raf.BencodeError
    if err then et:Warn("Bencode error: " .. err) end
    if isHash(dict) and (truthy(dict.announce) or truthy(dict['created by']) or truthy(dict.info)) then
        et:SetFileType()
        local tagTablePtr = GetTagTable(nil, 'lexiftool.Torrent.Main')
        if truthy(ExtractTags(et, dict, tagTablePtr)) then success = 1 end
    end
    return success
end

return Torrent
