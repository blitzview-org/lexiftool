--------------------------------------------------------------------------------
-- File:         lexiftool/Audible.lua
-- Ported from:  lib/Image/ExifTool/Audible.pm
--
-- Description:  Read metadata from Audible audio books
--
-- Revisions:    2015/04/05 - P. Harvey Created
--
-- References:   1) https://github.com/jteeuwen/audible
--               2) https://code.google.com/p/pyaudibletags/
--               3) http://wiki.multimedia.cx/index.php?title=Audible_Audio
--
-- Port notes:   Complete port of Audible.pm: every table and sub, in
--               upstream order (Audible.pm is read-only; it has no write
--               code).  Deviations forced by Lua:
--               - The predeclarations `sub ProcessAudible_meta($$$);` and
--                 `sub ProcessAudible_cvrx($$$);` are locals at the top; the
--                 PROCESS_PROC entries of the `meta`/`cvrx` tables are
--                 `false` placeholders filled in at the bottom of the file.
--               - `require Image::ExifTool::HTML` (for UnescapeHTML) stays a
--                 require at the point of use, as upstream.
--               - Perl's `$type` is `type_`; the `next`/`last` of the
--                 ProcessAA TOC loop are `goto continue`/`break`.
--               No vendored test image has an Audible M4B `tags` atom, so
--               the `tags`/`meta`/`cvrx`/`tseg` path is checked only with a
--               synthetic file.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local length = perl.length
local lc = perl.lc
local uc = perl.uc
local subst = perl.subst
local isMatch = perl.isMatch
local unpack = perl.unpack
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable

local Audible = {}

-- (upstream's predeclarations; the subs below assign to them)
local ProcessAudible_meta
local ProcessAudible_cvrx

Audible.Main = {
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        ExifTool will extract any information found in the metadata dictionary of
        Audible .AA files, even if not listed in the table below.
    ]],
    -- tags found in the metadata dictionary (chunk 2)
    pubdate    = { Name = 'PublishDate', Groups = { [2] = 'Time' } },
    pub_date_start = { Name = 'PublishDateStart', Groups = { [2] = 'Time' } },
    author     = { Name = 'Author',      Groups = { [2] = 'Author' } },
    copyright  = { Name = 'Copyright',   Groups = { [2] = 'Author' } },
    -- also seen (ref PH):
    -- product_id, parent_id, title, provider, narrator, price, description,
    -- long_description, short_title, is_aggregation, title_id, codec, HeaderSeed,
    -- EncryptedBlocks, HeaderKey, license_list, CPUType, license_count, <12 hex digits>,
    -- parent_short_title, parent_title, aggregation_id, short_description, user_alias

    -- information extracted from other chunks
    _chapter_count = { Name = 'ChapterCount' },       -- from chunk 6
    _cover_art = { -- from chunk 11
        Name = 'CoverArt',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
}

-- 'tags' atoms observed in Audible .m4b audio books (ref PH)
Audible.tags = {
    GROUPS = { [0] = 'QuickTime', [2] = 'Audio' },
    NOTES = 'Information found in "tags" atom of Audible M4B audio books.',
    meta = {
        Name = 'Audible_meta',
        SubDirectory = { TagTable = 'lexiftool.Audible.meta' },
    },
    cvrx = {
        Name = 'Audible_cvrx',
        SubDirectory = { TagTable = 'lexiftool.Audible.cvrx' },
    },
    tseg = {
        Name = 'Audible_tseg',
        SubDirectory = { TagTable = 'lexiftool.Audible.tseg' },
    },
}

-- 'meta' information observed in Audible .m4b audio books (ref PH)
Audible.meta = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'QuickTime', [2] = 'Audio' },
    NOTES = 'Information found in Audible M4B "meta" atom.',
    Album       = 'Album',
    ALBUMARTIST = { Name = 'AlbumArtist', Groups = { [2] = 'Author' } },
    Artist      = { Name = 'Artist',      Groups = { [2] = 'Author' } },
    Comment     = 'Comment',
    Genre       = 'Genre',
    itunesmediatype = { Name = 'iTunesMediaType', Description = 'iTunes Media Type' },
    SUBTITLE    = 'Subtitle',
    Title       = 'Title',
    TOOL        = 'CreatorTool',
    Year        = { Name = 'Year', Groups = { [2] = 'Time' } },
    track       = 'ChapterName', -- (found in 'meta' of 'tseg' atom)
}

-- 'cvrx' information observed in Audible .m4b audio books (ref PH)
Audible.cvrx = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'QuickTime', [2] = 'Audio' },
    NOTES = 'Audible cover art information in M4B audio books.',
    VARS = { ID_FMT = 'none' },
    CoverArtType = 'CoverArtType',
    CoverArt     = {
        Name = 'CoverArt',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
}

-- 'tseg' information observed in Audible .m4b audio books (ref PH)
Audible.tseg = {
    GROUPS = { [0] = 'QuickTime', [2] = 'Audio' },
    tshd = {
        Name = 'ChapterNumber',
        Format = 'int32u',
        ValueConv = function(_self, val) return val + 1 end,    -- start counting from 1
    },
    meta = {
        Name = 'Audible_meta2',
        SubDirectory = { TagTable = 'lexiftool.Audible.meta' },
    },
}

--------------------------------------------------------------------------------
-- Process Audible 'meta' tags from M4B files (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessAudible_meta(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirLen = length(dataPt)
    if dirLen < 4 then return 0 end
    local num = Get32u(dataPt, 0)
    et:VerboseDir('Audible_meta', num)
    local pos = 4
    local index = 0
    while index < num do
        if pos + 3 > dirLen then break end
        local unk = Get8u(dataPt, pos)             -- ? (0x80 or 0x00)
        if not (unk == 0x80 or unk == 0x00) then break end
        local len = Get16u(dataPt, pos + 1)        -- tag length
        pos = pos + 3
        if pos + len + 6 > dirLen or len == 0 then break end
        local tag = substr(dataPt, pos, len)       -- tag ID
        local ver = Get16u(dataPt, pos + len)      -- version?
        if ver ~= 0x0001 then break end
        local size = Get32u(dataPt, pos + len + 2) -- data size
        pos = pos + len + 6
        if pos + size > dirLen then break end
        local val = et:Decode(substr(dataPt, pos, size), 'UTF8')
        if not tagTablePtr[tag] then
            local name = ExifTool.MakeTagName((isMatch(tag, '[a-z]')) and tag or lc(tag))
            AddTagToTable(nil, tagTablePtr, tag, { Name = name })
        end
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = pos,
            Size    = size,
            Index   = index,
        })
        pos = pos + size
        index = index + 1
    end
    return 1
end
Audible.ProcessAudible_meta = ProcessAudible_meta

--------------------------------------------------------------------------------
-- Process Audible 'cvrx' cover art atom from M4B files (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessAudible_cvrx(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirLen = length(dataPt)
    if 0x0a > dirLen then return 0 end
    local len = Get16u(dataPt, 0x08)
    if 0x0a + len + 6 > dirLen then return 0 end
    local size = Get32u(dataPt, 0x0a + len + 2)
    if 0x0a + len + 6 + size > dirLen then return 0 end
    et:VerboseDir('Audible_cvrx', nil, dirLen)
    et:HandleTag(tagTablePtr, 'CoverArtType', nil, {
        DataPt  = dataPt,
        DataPos = dataPos,
        Start   = 0x0a,
        Size    = len,
    })
    et:HandleTag(tagTablePtr, 'CoverArt', nil, {
        DataPt  = dataPt,
        DataPos = dataPos,
        Start   = 0x0a + len + 6,
        Size    = size,
    })
    return 1
end
Audible.ProcessAudible_cvrx = ProcessAudible_cvrx

--------------------------------------------------------------------------------
-- Read information from an Audible .AA file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid AA file
function Audible.ProcessAA(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff, toc

    -- check magic number
    n, buff = raf:Read(16)
    if not (n == 16 and isMatch(buff, [[(?s)^.{4}\x57\x90\x75\x36]])) then return 0 end
    -- check file size
    if et.VALUE.FileSize ~= nil then
        -- first 4 bytes of the file should be the filesize
        if unpack('N', buff) ~= et.VALUE.FileSize then return 0 end
    end
    et:SetFileType()
    SetByteOrder('MM')
    local bytes = 12 * Get32u(buff, 8) -- table of contents size in bytes
    if bytes > 0xc00 then et:Warn('Invalid TOC') return 1 end
    -- read the table of contents
    n, toc = raf:Read(bytes)
    if n ~= bytes then et:Warn('Truncated TOC') return 1 end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Audible.Main')
    -- parse table of contents (in $toc)
    for entry = 0, bytes - 1, 12 do
        local type_ = Get32u(toc, entry)
        if not (type_ == 2 or type_ == 6 or type_ == 11) then goto continue end
        local offset = Get32u(toc, entry + 4)
        local length_ = Get32u(toc, entry + 8)
        if length_ == 0 then goto continue end
        if not raf:Seek(offset, 0) then et:Warn("Chunk " .. type_ .. " seek error") break end
        if type_ == 6 then  -- offset table
            if length_ < 4 then goto continue end
            n, buff = raf:Read(4)
            if n ~= 4 then goto continue end -- only read the chapter count
            et:HandleTag(tagTablePtr, '_chapter_count', Get32u(buff, 0))
            goto continue
        end
        -- read the chunk
        if length_ > 100000000 then et:Warn("Chunk " .. type_ .. " too big") goto continue end
        n, buff = raf:Read(length_)
        if n ~= length_ then et:Warn("Chunk " .. type_ .. " read error") break end
        if type_ == 11 then  -- cover art
            if length_ < 8 then goto continue end
            local len = Get32u(buff, 0)
            local off = Get32u(buff, 4)
            if off < offset + 8 or off - offset + len > length_ then goto continue end
            et:HandleTag(tagTablePtr, '_cover_art', substr(buff, off-offset, len))
            goto continue
        end
        do
            -- parse metadata dictionary (in $buff)
            if length_ < 4 then et:Warn('Bad dictionary') goto continue end
            local num = Get32u(buff, 0)
            if num > 0x200 then et:Warn('Bad dictionary count') goto continue end
            local pos = 4    -- dictionary starts immediately after count
            local HTML = require('lexiftool.HTML')  -- (for UnescapeHTML)
            et:VerboseDir('Audible Metadata', num)
            for i = 0, num - 1 do
                local tagPos = pos + 9                  -- position of tag string
                if tagPos > length_ then et:Warn('Truncated dictionary') break end
                -- (1 unknown byte ignored at start of each dictionary entry)
                local tagLen = Get32u(buff, pos + 1)  -- tag string length
                local valLen = Get32u(buff, pos + 5)  -- value string length
                local valPos = tagPos + tagLen         -- position of value string
                local nxtPos = valPos + valLen         -- position of next entry
                if nxtPos > length_ then et:Warn('Bad dictionary entry') break end
                local tag = substr(buff, tagPos, tagLen)
                local val = substr(buff, valPos, valLen)
                if not tagTablePtr[tag] then
                    local name = ExifTool.MakeTagName(tag)
                    name = subst(name, '_(.)', function(c) return uc(c) end, 'g') -- change from underscore-separated to mixed case
                    AddTagToTable(nil, tagTablePtr, tag, { Name = name })
                end
                -- unescape HTML character references and convert from UTF-8
                val = et:Decode(HTML.UnescapeHTML(val), 'UTF8')
                et:HandleTag(tagTablePtr, tag, val, {
                    DataPos = offset,
                    DataPt  = buff,
                    Start   = valPos,
                    Size    = valLen,
                    Index   = i,
                })
                pos = nxtPos -- step to next dictionary entry
            end
        end
        ::continue::
    end
    return 1
end

-- (PROCESS_PROC of the tables above: the predeclared subs exist only now, see
--  the predeclaration placeholders)
Audible.meta.PROCESS_PROC = ProcessAudible_meta
Audible.cvrx.PROCESS_PROC = ProcessAudible_cvrx

return Audible
