--------------------------------------------------------------------------------
-- File:         lexiftool/InDesign.lua
-- Ported from:  lib/Image/ExifTool/InDesign.pm
--
-- Description:  Read/write meta information in Adobe InDesign files
--
-- Revisions:    2009-06-17 - P. Harvey Created
--
-- References:   1) http://www.adobe.com/devnet/xmp/pdfs/XMPSpecificationPart3.pdf
--
-- Port notes:   complete apart from LargeFileSupport gating (>2 GB files) and
--               the verbose>2 stream dump.  Upstream's `goto DONE` cleanup is
--               expressed as nested ifs, so the locals it jumps over are all
--               declared up front.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local Writer = require('lexiftool.Writer')
local Write = Writer.Write

local InDesign = {}

-- map for writing metadata to InDesign files (currently only write XMP)
local indMap = {
    XMP = 'IND',
}

-- unpack a 4-byte length word in the stream's byte order ('V' little /
-- 'N' big -- upstream packs/unpacks with the same templates)
local function perl_unpack_len(pack, s)
    return (perl.unpack(pack, s))
end

-- GUID's used in InDesign files
local masterPageGUID = "\x06\x06\xed\xf5\xd8\x1d\x46\xe5\xbd\x31\xef\xe7\xfe\x74\xb7\x1d"
local objectHeaderGUID = "\xde\x39\x39\x79\x51\x88\x4b\x6c\x8e\x63\xee\xf8\xae\xe0\xdd\x38"
local objectTrailerGUID = "\xfd\xce\xdb\x70\xf7\x86\x4b\x4f\xa4\xd3\xc7\x28\xb3\x41\x71\x06"

-- match upstream's XMP-packet header regex against a 56-byte stream prefix:
--   /^(....)<\?xpacket begin=(['"])\xef\xbb\xbf\2 id=(['"])W5M0MpCehiHzreSzNTczkc9d\3/
-- Returns the leading length word on success (Lua patterns can't express
-- the backreferenced quotes, so the structure is checked step by step)
local function matchXMPHeader(buff)
    local head = '<?xpacket begin='
    if buff:sub(5, 4 + #head) ~= head then return nil end
    local q1 = buff:byte(5 + #head) -- opening quote of the begin attribute
    if q1 ~= 0x22 and q1 ~= 0x27 then return nil end
    local pos = 6 + #head
    if buff:sub(pos, pos + 2) ~= '\xef\xbb\xbf' then return nil end -- UTF-8 BOM
    pos = pos + 3
    if buff:byte(pos) ~= q1 then return nil end -- closing begin quote
    pos = pos + 1
    if buff:sub(pos, pos + 3) ~= ' id=' then return nil end
    pos = pos + 4
    local q2 = buff:byte(pos) -- opening quote of the id attribute
    if q2 ~= 0x22 and q2 ~= 0x27 then return nil end
    pos = pos + 1
    if buff:sub(pos, pos + 23) ~= 'W5M0MpCehiHzreSzNTczkc9d' then return nil end
    pos = pos + 24
    if buff:byte(pos) ~= q2 then return nil end -- closing id quote
    return buff:sub(1, 4) -- the length word
end

--------------------------------------------------------------------------------
-- Read or write meta information in an InDesign file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid InDesign file, or -1 on write error
function InDesign.ProcessIND(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    -- (all locals shared across the structured cleanup jump are declared up
    --  front -- Lua gotos must not enter a later local's scope)
    local hdr, buff, buf2
    local err, writeLen, foundXMP
    local n
    local seq1, seq2, curPage, streamInt32u, streamPack, pages, pos
    local verbose, out
    local len, lenWord

    -- validate the InDesign file
    n, hdr = raf:Read(16)
    if n ~= 16 then return 0 end
    if hdr ~= masterPageGUID then return 0 end
    n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    et:SetFileType(buff == 'DOCUMENT' and 'INDD' or 'IND') -- set the FileType tag

    -- read the master pages
    if not raf:Seek(0, 0) then
        err = 'Seek error'
    else
        n, buff = raf:Read(4096)
        if n ~= 4096 then
            err = 'Unexpected end of file'
        else
            n, buf2 = raf:Read(4096)
            if n ~= 4096 then
                err = 'Unexpected end of file'
            elseif not ExifTool.SetByteOrder('II') then
                err = 'Invalid byte order'
            else
                if buf2:sub(1, #masterPageGUID) ~= masterPageGUID then
                    err = 'Second master page is invalid'
                end
            end
        end
    end

    if not err then
        seq1 = ExifTool.Get64u(buff, 264)
        seq2 = ExifTool.Get64u(buf2, 264)
        -- take the most current master page
        curPage = (seq2 > seq1) and buf2 or buff
        -- byte order of stream data may be different than headers
        streamInt32u = curPage:byte(25) -- Get8u(curPage, 24)
        if streamInt32u == 1 then
            streamPack = 'V' -- little-endian int32u
        elseif streamInt32u == 2 then
            streamPack = 'N' -- big-endian int32u
        else
            err = 'Invalid stream byte order'
        end
    end

    if not err then
        pages = ExifTool.Get32u(curPage, 280)
        if pages < 2 then
            err = 'Invalid page count'
        else
            -- (upstream gates >2 GB files on LargeFileSupport; deferred)
            pos = pages * 4096
            if outfile then
                -- make XMP the preferred group for writing
                Writer.InitWriteDirs(et, indMap, 'XMP')

                if not Write(outfile, buff, buf2) then err = 1 end
                if not err then
                    local result = Writer.CopyBlock(raf, outfile, pos - 8192)
                    if result ~= 1 then
                        err = 'Error reading InDesign database'
                    end
                    writeLen = 0
                end
            else
                if not raf:Seek(pos, 0) then err = 'Seek error' end
            end
        end
    end

    if not err then
        do
            verbose = et:Options('Verbose')
            out = et:Options('TextOut') or io.stdout

            -- scan through the contiguous objects for XMP
            while true do
                n, hdr = raf:Read(32)
                if not n or n == 0 then break end
                if not (#hdr == 32 and hdr:sub(1, #objectHeaderGUID) == objectHeaderGUID) then
                    -- this must be null padding or we have a possible error
                    if hdr:match('^%z+$') then break end
                    -- (could be up to 4095 bytes of non-null garbage plus
                    --  4095 null bytes from ExifTool)
                    local n2, b2 = raf:Read(8192)
                    if n2 and n2 > 0 then hdr = hdr .. b2 end
                    local total = #hdr
                    hdr = hdr:gsub('%z+$', '') -- remove trailing nulls
                    if total > 8190 or #hdr > 4095 then
                        err = 'Corrupt file or unsupported InDesign version'
                        break
                    end
                    local non = 'Non-null padding at end of file'
                    if not outfile then
                        et:Warn(non, 1)
                    elseif not et:Error(non, 1) then
                        if not Write(outfile, hdr) then err = 1 end
                        writeLen = writeLen + #hdr
                    end
                    break
                end
                len = ExifTool.Get32u(hdr, 24)
                if perl.truthy(verbose) then
                    out:write(sprintf(
                        'Contiguous object at offset 0x%x (%d bytes):\n',
                        raf:Tell(), len))
                end
                -- check for XMP if stream data is long enough
                -- (56 bytes is just enough for XMP header)
                if len > 56 then
                    n, buff = raf:Read(56)
                    if n ~= 56 then
                        err = 'Unexpected end of file'
                        break
                    end
                    lenWord = matchXMPHeader(buff)
                    if lenWord then
                        len = len - 4 -- get length of XMP only
                        foundXMP = 1
                        -- (upstream also guards against an insanely large XMP
                        --  here -- a Perl memory limit this port doesn't have)
                        -- load and parse the XMP data
                        if not raf:Seek(-52, 1) then
                            err = 'Error reading XMP stream'
                            break
                        end
                        n, buff = raf:Read(len)
                        if n ~= len then
                            err = 'Error reading XMP stream'
                            break
                        end
                        local xmpDir = {
                            DataPt = buff,
                            Parent = 'IND',
                            NoDelete = 1, -- do not allow this to be deleted when writing
                            -- NoDelete makes WriteDirectory fall through to
                            -- WriteXMP for a `-XMP:all=`, and this port's
                            -- WriteXMP wants the group delete flagged (see the
                            -- DelGroup comment there) so it empties the packet
                            -- instead of returning the existing data unchanged
                            DelGroup = outfile and Writer.IsGroupDeleted(et, 'XMP') or nil,
                        }
                        -- validate xmp data length (should be the same as
                        -- the length in the header minus 4)
                        local xmpLen = perl_unpack_len(streamPack, lenWord)
                        if xmpLen ~= len then
                            if xmpLen < len then
                                xmpDir.DirLen = xmpLen
                            else
                                err = 'Truncated XMP stream (missing ' ..
                                    (xmpLen - len) .. ' bytes)'
                            end
                        end
                        local tagTablePtr = et:GetTagTable('lexiftool.XMP.Main')
                        if outfile then
                            if err then break end
                            -- make sure that XMP is writable
                            local classID = ExifTool.Get32u(hdr, 20)
                            if classID & 0x40000000 == 0 then
                                err = 'XMP stream is not writable'
                                break
                            end
                            local xmp = Writer.WriteDirectory(et, xmpDir, tagTablePtr)
                            if xmp and #xmp > 0 then
                                -- write new xmp with leading length word
                                buff = perl.pack(streamPack, #xmp) .. xmp
                                -- update header with new length and invalid checksum
                                -- (upstream Set32u()s in place at offsets 24 and 28)
                                hdr = hdr:sub(1, 24) .. ExifTool.Put32u(#buff) ..
                                      ExifTool.Put32u(0xffffffff)
                            else
                                et.CHANGED = 0    -- didn't change anything
                                if xmp ~= nil then
                                    et:Warn("Can't delete XMP as a block from InDesign file")
                                end
                                -- put length word back at start of stream
                                buff = lenWord .. buff
                            end
                        elseif not err then
                            et:ProcessDirectory(xmpDir, tagTablePtr)
                        end
                        len = 0 -- we got the full stream (nothing left to read)
                    else
                        len = len - 56 -- we got 56 bytes of the stream
                    end
                else
                    buff = ''       -- must reset this for writing later
                end
                if outfile then
                    -- write object header and data
                    if not Write(outfile, hdr, buff) then err = 1 break end
                    local result = Writer.CopyBlock(raf, outfile, len)
                    if result ~= 1 then
                        err = 'Truncated stream data'
                        break
                    end
                    writeLen = writeLen + 32 + #buff + len
                elseif len > 0 then
                    -- skip over remaining stream data
                    if not raf:Seek(len, 1) then
                        err = 'Seek error'
                        break
                    end
                end
                n, buff = raf:Read(32)
                if n ~= 32 then
                    err = 'Unexpected end of file'
                    break
                end
                if buff:sub(1, #objectTrailerGUID) ~= objectTrailerGUID then
                    err = 'Invalid object trailer'
                    break
                end
                if outfile then
                    -- make sure object UID and ClassID are the same in the trailer
                    if hdr:sub(17, 24) ~= buff:sub(17, 24) then
                        err = 'Non-matching object trailer'
                        break
                    end
                    -- write object trailer
                    if not Write(outfile, objectTrailerGUID, hdr:sub(17)) then err = 1 break end
                    writeLen = writeLen + 32
                end
            end
            if outfile then
                -- write null padding if necessary
                -- (InDesign files must be an even number of 4096-byte blocks)
                local part = writeLen % 4096
                if part ~= 0 then
                    if not Write(outfile, string.rep('\0', 4096 - part)) then err = 1 end
                end
            end
        end
    end

    -- (upstream's goto DONE cleanup is expressed as nested ifs above)
    if not err then
        if outfile and not foundXMP then et:Warn('No XMP stream to edit') end
        return 1        -- success!
    elseif not outfile then
        -- issue warning on read error
        if err ~= 1 then et:Warn(err) end
    elseif err ~= 1 then
        -- set error and return success code
        et:Error(err)
    else
        return -1       -- write error
    end
    return 1
end

return InDesign
