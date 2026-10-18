--------------------------------------------------------------------------------
-- File:         lexiftool/ArchiveZip.lua
--
-- Description:  Read members of a ZIP archive
--
-- Notes:        This file has no counterpart in the upstream tree: it stands in
--               for the optional CPAN module Archive::Zip, which ZIP.pm uses to
--               walk the member list and decompress member data. Without it,
--               upstream falls back to reading the local file headers by hand
--               and never reaches the CaptureOne/iWork/OOXML/OpenDocument
--               sub-parsers -- ZIP.lua had only that fallback until now.
--
--               The API mirrors the small part of Archive::Zip that ZIP.pm
--               actually calls, so the ported ZIP.lua reads like the original:
--
--                 ArchiveZip.new()                -> Archive::Zip->new
--                 zip:readFromFileHandle(raf)     -> $zip->readFromFileHandle
--                 zip:zipfileComment()            -> $zip->zipfileComment
--                 zip:members()                   -> $zip->members
--                 zip:membersMatching(pat)        -> $zip->membersMatching
--                 zip:memberNamed(name)           -> $zip->memberNamed
--                 zip:contents(member)            -> $zip->contents
--                 member:fileName() etc.          -> the member accessors
--                                                    HandleMember reads
--
--               readFromFileHandle returns Archive::Zip's status codes, since
--               ProcessZIP maps them to messages: 0 = AZ_OK, 1 = stream end
--               error, 3 = format error, 4 = IO error.
--
--               Only the two compression methods that occur in practice are
--               decoded: stored (0) and deflated (8), the latter through
--               ExifTool.inflateRaw (zlib in raw mode, which is what a ZIP
--               member holds -- no zlib wrapper). Any other method makes
--               contents() report a non-zero status, exactly as Archive::Zip
--               does for a method it cannot handle.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')

local ArchiveZip = {}

-- ZIP structures are always little-endian, independent of whatever byte order
-- the surrounding extraction happens to have set, so they are read explicitly
-- rather than through ExifTool.Get16u/Get32u
local function Get16le(s, pos) return (perl.unpack('v', s, pos)) end
local function Get32le(s, pos) return (perl.unpack('V', s, pos)) end

-- Archive::Zip status codes (AZ_OK, AZ_STREAM_END, AZ_ERROR, AZ_FORMAT_ERROR, AZ_IO_ERROR)
local AZ_OK           = 0
local AZ_FORMAT_ERROR = 3
local AZ_IO_ERROR     = 4

local Member = {}
Member.__index = Member

function Member:fileName() return self.fileName_ end
function Member:versionNeededToExtract() return self.versionNeeded end
function Member:bitFlag() return self.bitFlag_ end
function Member:compressionMethod() return self.compressionMethod_ end
function Member:lastModFileDateTime() return self.lastModFileDateTime_ end
function Member:crc32() return self.crc32_ end
function Member:compressedSize() return self.compressedSize_ end
function Member:uncompressedSize() return self.uncompressedSize_ end
function Member:fileComment() return self.fileComment_ end

local Zip = {}
Zip.__index = Zip

--------------------------------------------------------------------------------
-- Create a new (empty) archive object
--------------------------------------------------------------------------------
function ArchiveZip.new()
    return setmetatable({ members_ = {}, byName = {}, comment = nil }, Zip)
end

-- Find the end-of-central-directory record, searching backwards from the end of
-- the file for its signature (it is followed by a variable-length comment, so
-- its position is not fixed). Returns the EOCD data and its offset, or nil.
local function findEOCD(raf)
    if not raf:Seek(0, 2) then return nil end
    local fileEnd = raf:Tell()
    -- the EOCD is 22 bytes plus up to 64 kB of archive comment
    local scan = 22 + 0xffff
    if scan > fileEnd then scan = fileEnd end
    if not raf:Seek(fileEnd - scan, 0) then return nil end
    local n, buff = raf:Read(scan)
    if not n or n < 22 then return nil end
    -- search backwards so a signature inside the comment can't win
    for i = #buff - 21, 1, -1 do
        if buff:sub(i, i + 3) == 'PK\5\6' then
            return buff:sub(i), fileEnd - scan + i - 1
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Read the central directory of an archive
-- Inputs: 0) archive object, 1) RandomAccess object
-- Returns: an Archive::Zip status code (0 on success)
--------------------------------------------------------------------------------
function Zip:readFromFileHandle(raf)
    self.raf = raf
    local eocd = findEOCD(raf)
    if not eocd then return AZ_FORMAT_ERROR end
    local numEntries = Get16le(eocd, 10)
    local cdSize = Get32le(eocd, 12)
    local cdStart = Get32le(eocd, 16)
    local comLen = Get16le(eocd, 20)
    if comLen > 0 then self.comment = eocd:sub(23, 22 + comLen) end
    if not raf:Seek(cdStart, 0) then return AZ_IO_ERROR end
    local n, cd = raf:Read(cdSize)
    if not n or n < cdSize then return AZ_IO_ERROR end
    local pos = 0
    for _ = 1, numEntries do
        if pos + 46 > #cd then return AZ_FORMAT_ERROR end
        if cd:sub(pos + 1, pos + 4) ~= 'PK\1\2' then return AZ_FORMAT_ERROR end
        local nameLen = Get16le(cd, pos + 28)
        local extraLen = Get16le(cd, pos + 30)
        local comLen2 = Get16le(cd, pos + 32)
        local member = setmetatable({
            versionNeeded        = Get16le(cd, pos + 6),
            bitFlag_             = Get16le(cd, pos + 8),
            compressionMethod_   = Get16le(cd, pos + 10),
            lastModFileDateTime_ = Get32le(cd, pos + 12),
            crc32_               = Get32le(cd, pos + 16),
            compressedSize_      = Get32le(cd, pos + 20),
            uncompressedSize_    = Get32le(cd, pos + 24),
            localOffset          = Get32le(cd, pos + 42),
            fileName_            = cd:sub(pos + 47, pos + 46 + nameLen),
        }, Member)
        if comLen2 > 0 then
            local cs = pos + 46 + nameLen + extraLen
            member.fileComment_ = cd:sub(cs + 1, cs + comLen2)
        end
        self.members_[#self.members_ + 1] = member
        self.byName[member.fileName_] = member
        pos = pos + 46 + nameLen + extraLen + comLen2
    end
    return AZ_OK
end

--------------------------------------------------------------------------------
-- Archive comment, or nil if there is none
--------------------------------------------------------------------------------
function Zip:zipfileComment()
    return self.comment
end

--------------------------------------------------------------------------------
-- All members, in central-directory order
--------------------------------------------------------------------------------
function Zip:members()
    return self.members_
end

--------------------------------------------------------------------------------
-- Members whose name matches a pattern (a PCRE2 pattern, as the ported
-- ZIP.lua passes upstream's own regexps straight through)
--------------------------------------------------------------------------------
function Zip:membersMatching(pat)
    local matched = {}
    for _, member in ipairs(self.members_) do
        if perl.isMatchDyn(member.fileName_, pat) then
            matched[#matched + 1] = member
        end
    end
    return matched
end

--------------------------------------------------------------------------------
-- The member with this exact name, or nil
--------------------------------------------------------------------------------
function Zip:memberNamed(name)
    return self.byName[name]
end

--------------------------------------------------------------------------------
-- Uncompressed contents of a member
-- Inputs: 0) archive object, 1) member
-- Returns: contents and an Archive::Zip status code (0 on success)
--------------------------------------------------------------------------------
function Zip:contents(member)
    if not member then return nil, AZ_FORMAT_ERROR end
    local raf = self.raf
    -- the local header repeats the name and extra field, whose lengths may
    -- differ from the central directory's, so read it rather than assume
    if not raf:Seek(member.localOffset, 0) then return nil, AZ_IO_ERROR end
    local n, hdr = raf:Read(30)
    if n ~= 30 or hdr:sub(1, 4) ~= 'PK\3\4' then return nil, AZ_FORMAT_ERROR end
    local nameLen = Get16le(hdr, 26)
    local extraLen = Get16le(hdr, 28)
    if not raf:Seek(member.localOffset + 30 + nameLen + extraLen, 0) then
        return nil, AZ_IO_ERROR
    end
    local size = member.compressedSize_
    local data
    if size > 0 then
        local n2
        n2, data = raf:Read(size)
        if n2 ~= size then return nil, AZ_IO_ERROR end
    else
        data = ''
    end
    if member.compressionMethod_ == 0 then   -- stored
        return data, AZ_OK
    elseif member.compressionMethod_ == 8 then -- deflated
        local out = ExifTool.inflateRaw(nil, data)
        if out == nil then return nil, AZ_FORMAT_ERROR end
        return out, AZ_OK
    end
    -- (Archive::Zip reports an error for a method it has no decoder for)
    return nil, AZ_FORMAT_ERROR
end

return ArchiveZip
