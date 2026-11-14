--------------------------------------------------------------------------------
-- File:         lexiftool/Trailer.lua
-- Ported from:  lib/Image/ExifTool/Trailer.pm
--
-- Description:  Read JPEG trailer written by various makes of phone
--
-- Revisions:    2025-01-27 - P. Harvey Created
--
-- Port notes:   complete: Vivo, OnePlus and Google tables and their
--               trailer procs (ProcessVivo, ProcessOnePlus, ProcessGoogle);
--               the Google trailer is identified via the XMP-driven
--               ProcessGoogleTrailer flag (ExifTool:IdentifyTrailer and the
--               fallback at the end of ExifTool:ProcessTrailers).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local substr = perl.substr
local length = perl.length
local at = perl.at
local num = perl.num
local ucfirst = perl.ucfirst
local subst = perl.subst
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn

local Trailer = {}

-- Information written in JPEG trailer by some Vivo phones.
Trailer.Vivo = {
    GROUPS = { [0] = 'Trailer', [1] = 'Vivo', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Information written in JPEG trailer by some Vivo phones.',
    -- (don't know for sure what type of image this is, but it is in JPEG format)
    HDRImage = {
        Notes = 'highlights of HDR image',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    JSONInfo = { },
    HiddenData = {
        Notes = 'hidden in EXIF, not in trailer.  This data is lost if the file is edited',
        Groups = { [0] = 'EXIF' },
    },
}

Trailer.OnePlus = {
    GROUPS = { [0] = 'Trailer', [1] = 'OnePlus', [2] = 'Image' },
    NOTES = 'Information written in JPEG trailer by some OnePlus phones.',
    JSONInfo = { },
    ['private.emptyspace'] = { -- length of the entire OnePlus trailer
        Name = 'OnePlusTrailerLen',
        ValueConv = function(_self, val) if perl.length(val) == 4 then return (perl.unpack('N', val)) end return val end,
        Unknown = 1,
    },
    ['watermark.device'] = {
        Name = 'Device',
        ValueConv = function(_self, val) return '0x' .. perl.join(' ', { perl.unpack('H10Z*', val) }) end,
        Format = 'string',
    },
}

-- Google and/or Android information in JPEG trailer
Trailer.Google = {
    GROUPS = { [0] = 'Trailer', [1] = 'Google', [2] = 'Image' },
    NOTES = [[
        Google-defined information written in the trailer of JPEG images by some
        phones.  This information is referenced by DirectoryItem entries in the XMP.
        Note that some of this information may also be referenced from other
        metadata formats, and hence may be extracted twice.  For example,
        MotionPhotoVideo may also exist within a Samsung trailer as
        EmbbededVideoFile, or GainMapImage may also exist in an MPF trailer as
        MPImage2.
    ]],
    MotionPhoto        = { Name = 'MotionPhotoVideo',  Groups = { [2] = 'Video' } },
    GainMap            = { Name = 'GainMapImage',      Groups = { [2] = 'Preview' } },
    Depth              = { Name = 'DepthMapImage',     Groups = { [2] = 'Preview' } },
    Confidence         = { Name = 'ConfidenceMapImage',Groups = { [2] = 'Preview' } },
    ['android/depthmap'] = { Name = 'DepthMapImage',     Groups = { [2] = 'Preview' } },
    ['android/confidencemap'] = { Name = 'ConfidenceMapImage', Groups = { [2] = 'Preview' } },
}

--------------------------------------------------------------------------------
-- Process Vivo trailer
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 on failure, -1 if we must scan for the start
--          of the trailer to set the ExifTool TrailerStart member
-- - takes Offset as positive offset from end of trailer to end of file,
--   and returns DataPos and DirLen, and updates OutFile when writing
function Trailer.ProcessVivo(et, dirInfo)
    local raf = dirInfo.RAF
    local buff

    -- return now unless we are at a position to scan for the trailer
    -- (must scan because the trailer footer doesn't indicate the trailer length)
    if not dirInfo.ScanForTrailer then return -1 end

    local pos = et.TrailerStart
    if not perlTruthy(pos) then return 0 end
    local len = et.FileEnd - pos - dirInfo.Offset
    if not raf:Seek(pos, 0) then return 0 end
    -- (m//g, then pos(): matches hands back $1 and the end offset)
    local n, m1, gpos
    if len > 0 and len < 1e7 then n, buff = raf:Read(len) end
    if n == len and isMatch(buff, [[\xff{4}\x1b\*9HWfu\x84\x93\xa2\xb1$]]) then -- validate footer
        m1, gpos = matches(buff, [[(streamdata|vivo\{")]])  -- find start
    end
    if not m1 then return 0 end
    local start = gpos - length(m1)
    if perlTruthy(start) then
        pos = pos + start
        len = len - start
        buff = substr(buff, start)
    end
    -- set trailer position and length
    dirInfo.DataPos, dirInfo.DirLen = pos, len

    -- let ProcessTrailers copy or delete this trailer
    if dirInfo.OutFile then return -1 end

    if perlTruthy(et.OPTIONS.Verbose) or et.HTML_DUMP then et:DumpTrailer(dirInfo) end
    local tbl = et:GetTagTable('lexiftool.Trailer.Vivo')
    gpos = 0 -- rewind search to start of buffer
    local ok, p
    if isMatch(buff, [[^streamdata\xff\xd8\xff]]) then ok, p = matches(buff, [[\xff\xd9stream(info|coun)]], gpos) end
    if ok then
        gpos = p
        et:HandleTag(tbl, 'HDRImage', substr(buff, 10, gpos-20))
    else
        gpos = 0    -- (a failed m//g resets pos)
    end
    -- continue looking for Vivo JSON data
    ok, p = matches(buff, [[vivo\{"]], gpos)
    if ok then
        gpos = p
        local jsonStart = gpos - 2
        ok, p = matches(buff, [[\}\0]], gpos)
        if ok then
            gpos = p
            local jsonLen = gpos - 1 - jsonStart
            et:HandleTag(tbl, 'JSONInfo', substr(buff, jsonStart, jsonLen))
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process OnePlus trailer
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 on failure, -1 if we must scan for the start
--          of the trailer to set the ExifTool TrailerStart member
-- - takes Offset as positive offset from end of trailer to end of file,
--   and returns DataPos and DirLen, and updates OutFile when writing
function Trailer.ProcessOnePlus(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2, n

    -- return now unless we are at a position to scan for the trailer
    -- (must scan because the trailer footer doesn't indicate the entire trailer length)
    if not dirInfo.ScanForTrailer then return -1 end

    -- return -1 to let ProcessTrailers copy or delete the entire trailer
    if dirInfo.OutFile then return -1 end

    local start = et.TrailerStart
    if not perl.truthy(start) then return 0 end
    if not raf:Seek(-8 - (dirInfo.Offset or 0), 2) then return 0 end
    n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    local end_ = raf:Tell() -- (same as FileEnd - Offset)

    local dump = perl.truthy(et.OPTIONS.Verbose) or et.HTML_DUMP
    local tagTable = et:GetTagTable('lexiftool.Trailer.OnePlus')
    local trailLen = 0
    if isMatch(buff, [[^jxrs...\0$]]) then
        local jlen = perl.unpack('x4V', buff)
        local maxOff = 0
        if jlen < end_ - start and jlen > 8 and raf:Seek(end_ - jlen) then
            n, buff = raf:Read(jlen - 8)
            if n == jlen - 8 then
                buff = perl.subst(buff, [[\0+$]], '') -- remove trailing null(s)
                local list = require('lexiftool.Import').ReadJSONObject(nil, { data = buff })
                -- (`ref $list eq 'ARRAY'`: a JSON array is a plain list here, a
                --  JSON object carries _ordered_keys_)
                if type(list) == 'table' and not list._ordered_keys_ then
                    for _, e in ipairs(list) do
                        if perl.truthy(e.offset) and perl.num(e.offset) > maxOff then maxOff = perl.num(e.offset) end
                    end
                    trailLen = maxOff + jlen
                    if dump and trailLen ~= 0 then
                        et:DumpTrailer({
                            RAF     = raf,
                            DirName = 'OnePlus',
                            DataPos = end_ - trailLen,
                            DirLen  = trailLen,
                        })
                    end
                    et:HandleTag(tagTable, 'JSONInfo', buff)
                    for _, e in ipairs(list) do
                        local off, name, len = e.offset, e.name, e.length
                        if perl.truthy(off) and perl.truthy(name) and perl.truthy(len) then
                            -- (JSON numbers come back as strings here; Perl numifies)
                            off, len = perl.num(off), perl.num(len)
                            if raf:Seek(end_ - jlen - off) then
                                n, buf2 = raf:Read(len)
                                if n == len then
                                    et:HandleTag(tagTable, name, buf2, { DataPos = end_ - jlen - off, DataPt = buf2 })
                                end
                            end
                        end
                    end
                else
                    et:HandleTag(tagTable, 'JSONInfo', buff)
                    et:Warn('Error parsing OnePlus JSON information')
                end
            end
        end
    end
    dirInfo.DataPos, dirInfo.DirLen = end_ - trailLen, trailLen

    return 1
end

--------------------------------------------------------------------------------
-- Process Google trailer
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 on failure, -1 if we must scan for the start
--          of the trailer to set the ExifTool TrailerStart member
-- - this trailer won't be identified when writing because XMP isn't extracted then
function Trailer.ProcessGoogle(et, dirInfo)
    local raf = dirInfo.RAF
    local info = et.VALUE

    local tag, mime, len, pad = info.DirectoryItemSemantic, info.DirectoryItemMime,
                                info.DirectoryItemLength, info.DirectoryItemPadding

    if not (type(tag) == 'table' and type(mime) == 'table') then
        pad = nil
        tag, mime, len = info.ContainerDirectoryItemDataURI,
            info.ContainerDirectoryItemMime, info.ContainerDirectoryItemLength
        if not (type(mime) == 'table' and type(tag) == 'table') then
            et.ProcessGoogleTrailer = nil
            return 0
        end
    end
    -- we need to know TrailerStart to be able to read/write this trailer
    if not dirInfo.ScanForTrailer then return -1 end

    et.ProcessGoogleTrailer = nil   -- reset flag to process the Google trailer

    if dirInfo.OutFile then return -1 end   -- let caller handle the writing

    -- sometimes DirectoryItemLength is missing the Primary entry
    if type(len) ~= 'table' then len = { len } end
    while #len < #mime do table.insert(len, 1, 0) end

    local start = et.TrailerStart
    if not perlTruthy(start) then return 0 end
    local end_ = et.FileEnd -- (ignore Offset for now because some entries may run into other trailers)

    local dump = (perlTruthy(et.OPTIONS.Verbose) or et.HTML_DUMP)
    local tagTable = et:GetTagTable('lexiftool.Trailer.Google')

    -- (ignore first entry: "Primary" or "primary_image")
    -- (at() indexes the lists 0-based, as $$mime[$i] does; buff is the box
    --  \$buff, so every HandleTag below holds a reference to the same scalar,
    --  as upstream's does, and buff.value is $buff)
    local i, pos, buff, regex, grp, type_
    buff = { ref = 'SCALAR' }
    i, pos = 1, 0
    while at(mime, i) ~= nil do
        local more = end_ - start - pos
        if more < 16 then break end
        if not (perlTruthy(at(len, i)) and at(tag, i) ~= nil) then goto next_ end
        if num(at(len, i)) > more then break end
        do
            local n
            if raf:Seek(start+pos) then n, buff.value = raf:Read(16) end
            if not (n == 16 and raf:Seek(start+pos)) then break end
            if at(mime, i) == 'image/jpeg' then
                regex = [==[\xff\xd8\xff[\xdb\xe0\xe1]]==]
            elseif at(mime, i) == 'video/mp4' then
                regex = [[\0\0\0.ftyp(mp42|isom)]]
            else
                et:Warn('Google trailer ' .. at(tag, i) .. ' ' .. at(mime, i) .. ' not handled')
                goto next_
            end
            if isMatchDyn(buff.value, '(?s)^' .. regex) then
                n, buff.value = raf:Read(num(at(len, i)))
                if n ~= num(at(len, i)) then break end
            else
                if pos ~= 0 then break end  -- don't skip unknown information again
                n, buff.value = raf:Read(more)
                if n ~= more then break end
                local ok, m1 = isMatchDyn(buff.value, '(?s)(' .. regex .. ')')
                if not ok then break end
                -- (pos($buff) - length($1) is the match start: the first
                --  occurrence of the matched text, as the regex has no lookaround)
                pos = pos + perl.index(buff.value, m1)
                more = end_ - start - pos   -- luacheck: ignore 311 (dead as upstream)
                if num(at(len, i)) > end_ - start - pos then break end
                buff.value = substr(buff.value, pos, at(len, i))
            end
            if not tagTable[at(tag, i)] then
                local name = at(tag, i)
                -- capitalize words (overwritten on the next line, as upstream)
                name = subst(name, [[([^A-Za-z])([a-z])]], function(c1, c2) return c1 .. ucfirst(c2) end, 'g') -- luacheck: ignore 311
                name = ExifTool.MakeTagName(at(tag, i))
                if at(mime, i) == 'image/jpeg' then
                    type_, grp = 'Image', 'Preview'
                else
                    type_, grp = 'Video', 'Video'
                end
                et:VPrint(0, et.INDENT, '[adding Google:' .. name .. "]\n")
                ExifTool.AddTagToTable(et, tagTable, at(tag, i), { Name = name .. type_, Groups = { [2] = grp } })
            end
            if dump then et:DumpTrailer({
                RAF     = raf,
                DirName = at(tag, i),
                DataPos = start + pos,
                DirLen  = at(len, i),
            }) end
            et:HandleTag(tagTable, at(tag, i), buff, { DataPos = start + pos, DataPt = buff.value })
            -- (haven't seen non-zero padding, but I assume this is how it works
            pos = pos + at(len, i) + ((pad and perlTruthy(at(pad, i))) and at(pad, i) or 0)
        end
        ::next_::
        i = i + 1
    end
    if at(tag, i) ~= nil and at(mime, i) ~= nil then
        et:Warn('Error reading ' .. at(tag, i) .. ' ' .. at(mime, i) .. ' from trailer', 1)
    end
    if not perlTruthy(pos) then return 0 end

    dirInfo.DataPos, dirInfo.DirLen = start, pos

    return 1
end

return Trailer
