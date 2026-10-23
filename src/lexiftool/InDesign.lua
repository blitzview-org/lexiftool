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
-- Port notes:   complete.  The locals upstream's `goto DONE` jumps over are
--               declared up front (Lua's goto may not enter a local's
--               scope).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local carray = require('carray')
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local pack = perl.pack
local unpack = perl.unpack
local str = perl.str
local perlTruthy = perl.truthy
local Get8u = ExifTool.Get8u
local Get32u = ExifTool.Get32u
local Get64u = ExifTool.Get64u
local Set32u = ExifTool.Set32u -- (carray form: Set32u(dataPt, pos, val))
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local Writer = require('lexiftool.Writer')
local Write = Writer.Write

local InDesign = {}

-- map for writing metadata to InDesign files (currently only write XMP)
local indMap = {
    XMP = 'IND',
}

-- GUID's used in InDesign files
local masterPageGUID    = "\x06\x06\xed\xf5\xd8\x1d\x46\xe5\xbd\x31\xef\xe7\xfe\x74\xb7\x1d"
local objectHeaderGUID  = "\xde\x39\x39\x79\x51\x88\x4b\x6c\x8E\x63\xee\xf8\xae\xe0\xdd\x38"
local objectTrailerGUID = "\xfd\xce\xdb\x70\xf7\x86\x4b\x4f\xa4\xd3\xc7\x28\xb3\x41\x71\x06"

--------------------------------------------------------------------------------
-- Read or write meta information in an InDesign file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid InDesign file, or -1 on write error
--------------------------------------------------------------------------------
function InDesign.ProcessIND(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local hdr, buff, buf2, err, writeLen, foundXMP
    -- (declared up front: Lua's goto may not jump into the scope of a local)
    local n, seq1, seq2, curPage, streamInt32u, pages, pos, verbose, out

    -- validate the InDesign file
    n, hdr = raf:Read(16)
    if n ~= 16 then return 0 end
    if hdr ~= masterPageGUID then return 0 end
    n, buff = raf:Read(8)
    if n ~= 8 then return 0 end
    et:SetFileType(buff == 'DOCUMENT' and 'INDD' or 'IND')   -- set the FileType tag

    -- read the master pages
    if not raf:Seek(0, 0) then err = 'Seek error'; goto DONE end
    n, buff = raf:Read(4096)
    if n == 4096 then n, buf2 = raf:Read(4096) end
    if n ~= 4096
    then
        err = 'Unexpected end of file'
        goto DONE -- (goto's can be our friend)
    end
    SetByteOrder('II')
    if not isMatch(buf2, '^\\Q' .. masterPageGUID .. '\\E') then
        err = 'Second master page is invalid'
        goto DONE
    end
    seq1 = Get64u(buff, 264)
    seq2 = Get64u(buf2, 264)
    -- take the most current master page
    curPage = seq2 > seq1 and buf2 or buff
    -- byte order of stream data may be different than headers
    streamInt32u = Get8u(curPage, 24)
    if streamInt32u == 1 then
        streamInt32u = 'V' -- little-endian int32u
    elseif streamInt32u == 2 then
        streamInt32u = 'N' -- big-endian int32u
    else
        err = 'Invalid stream byte order'
        goto DONE
    end
    pages = Get32u(curPage, 280)
    if pages < 2 then err = 'Invalid page count'; goto DONE end
    pos = pages * 4096
    if pos > 0x7fffffff then
        if not perlTruthy(et:Options('LargeFileSupport')) then
            err = 'InDesign files larger than 2 GB not supported (LargeFileSupport not set)'
            goto DONE
        elseif str(et:Options('LargeFileSupport')) == '2' then
            et:Warn('Processing large file (LargeFileSupport is 2)')
        end
    end
    if outfile then
        -- make XMP the preferred group for writing
        Writer.InitWriteDirs(et, indMap, 'XMP')

        if not Write(outfile, buff, buf2) then err = 1; goto DONE end
        local result = Writer.CopyBlock(raf, outfile, pos - 8192)
        if not perlTruthy(result) then
            err = result ~= nil and 'Error reading InDesign database' or 1
            goto DONE
        end
        writeLen = 0
    else
        if not raf:Seek(pos, 0) then err = 'Seek error'; goto DONE end
    end
    -- scan through the contiguous objects for XMP
    verbose = et:Options('Verbose')
    out = et:Options('TextOut') or io.stdout
    while true do
        n, hdr = raf:Read(32)
        if not perlTruthy(n) then break end
        if not (length(hdr) == 32 and isMatch(hdr, '^\\Q' .. objectHeaderGUID .. '\\E')) then
            -- this must be null padding or we have a possible error
            if isMatch(hdr, [[^\0+$]]) then break end
            -- (could be up to 4095 bytes of non-null garbage plus 4095 null bytes from ExifTool)
            n, buff = raf:Read(8192)
            if perlTruthy(n) then hdr = hdr .. buff end
            local n2 = length(hdr)
            hdr = subst(hdr, [[\0+$]], '')   -- remove trailing nulls
            if n2 > 8190 or length(hdr) > 4095 then
                err = 'Corrupt file or unsupported InDesign version'
                break
            end
            local non = 'Non-null padding at end of file'
            if not outfile then
                et:Warn(non, 1)
            elseif not perlTruthy(et:Error(non, 1)) then
                if not Write(outfile, hdr) then err = 1 end
                writeLen = writeLen + length(hdr)
            end
            break
        end
        local len = Get32u(hdr, 24)
        if perlTruthy(verbose) then
            perl.printf(out, "Contiguous object at offset 0x%x (%d bytes):\n", raf:Tell(), len)
            if perl.num(verbose) > 2 then
                local len2 = len < 1024000 and len or 1024000
                n, buff = raf:Read(len2)
                if not raf:Seek(-n, 1) then err = 1 end
                et:VerboseDump(buff, { Addr = raf:Tell() })
            end
        end
        -- check for XMP if stream data is long enough
        -- (56 bytes is just enough for XMP header)
        if len > 56 then
            n, buff = raf:Read(56)
            if n ~= 56 then err = 'Unexpected end of file'; break end
            local lenWord = matches(buff, [[(?s)^(....)<\?xpacket begin=(['"])\xef\xbb\xbf\2 id=(['"])W5M0MpCehiHzreSzNTczkc9d\3]])
            if lenWord then   -- (save length word for writing later)
                len = len - 4          -- get length of XMP only
                foundXMP = 1
                -- I have a sample where the XMP is 107 MB, and ActivePerl may run into
                -- memory troubles (with its apparent 1 GB limit) if the XMP is larger
                -- than about 400 MB, so guard against this
                if len > 300 * 1024 * 1024 then
                    local msg = sprintf('Insanely large XMP (%.0f MiB)', len / (1024 * 1024))
                    if outfile then
                        if perlTruthy(et:Error(msg, 2)) then err = 1; break end
                    elseif perlTruthy(et:Options('IgnoreMinorErrors')) then
                        et:Warn(msg)
                    else
                        et:Warn(msg .. ". Ignored.", 1)
                        err = 1
                        break
                    end
                end
                -- load and parse the XMP data
                if raf:Seek(-52, 1) then n, buff = raf:Read(len) else n = nil end
                if n ~= len then
                    err = 'Error reading XMP stream'
                    break
                end
                local dirInfo2 = {
                    DataPt  = buff,
                    Parent  = 'IND',
                    NoDelete = 1, -- do not allow this to be deleted when writing
                    -- (port: NoDelete makes WriteDirectory fall through to
                    --  WriteXMP for a `-XMP:all=`, and this port's WriteXMP
                    --  wants the group delete flagged -- see the DelGroup
                    --  comment there -- so it empties the packet instead of
                    --  returning the existing data unchanged)
                    DelGroup = outfile and Writer.IsGroupDeleted(et, 'XMP') or nil,
                }
                -- validate xmp data length (should be same as length in header - 4)
                local xmpLen = unpack(streamInt32u, lenWord)
                if xmpLen ~= len then
                    if xmpLen < len then
                        dirInfo2.DirLen = xmpLen
                    else
                        err = 'Truncated XMP stream (missing ' .. (xmpLen - len) .. ' bytes)'
                    end
                end
                local tagTablePtr = GetTagTable(nil, 'lexiftool.XMP.Main')
                if outfile then
                    if err then break end
                    -- make sure that XMP is writable
                    local classID = Get32u(hdr, 20)
                    if classID & 0x40000000 == 0 then err = 'XMP stream is not writable'; break end
                    local xmp = Writer.WriteDirectory(et, dirInfo2, tagTablePtr)
                    if perlTruthy(xmp) and perlTruthy(length(xmp)) then
                        -- write new xmp with leading length word
                        buff = pack(streamInt32u, length(xmp)) .. xmp
                        -- update header with new length and invalid checksum
                        -- (port: the header becomes a carray so Set32u patches it in place)
                        local hdrStr = hdr
                        hdr = carray.new('char')
                        hdr:append(hdrStr)
                        Set32u(hdr, 24, length(buff))
                        Set32u(hdr, 28, 0xffffffff)
                    else
                        et.CHANGED = 0    -- didn't change anything
                        if xmp ~= nil then et:Warn("Can't delete XMP as a block from InDesign file") end
                        -- put length word back at start of stream
                        buff = lenWord .. buff
                    end
                else
                    et:ProcessDirectory(dirInfo2, tagTablePtr)
                end
                len = 0   -- we got the full stream (nothing left to read)
            else
                len = len - 56 -- we got 56 bytes of the stream
            end
        else
            buff = ''     -- must reset this for writing later
        end
        if outfile then
            -- write object header and data
            if not Write(outfile, hdr, buff) then err = 1; break end
            local result = Writer.CopyBlock(raf, outfile, len)
            if not perlTruthy(result) then
                err = result ~= nil and 'Truncated stream data' or 1
                break
            end
            writeLen = writeLen + 32 + length(buff) + len
        elseif len ~= 0 then
            -- skip over remaining stream data
            if not raf:Seek(len, 1) then err = 'Seek error'; break end
        end
        n, buff = raf:Read(32)
        if n ~= 32 then err = 'Unexpected end of file'; break end
        if not isMatch(buff, '^\\Q' .. objectTrailerGUID .. '\\E') then
            err = 'Invalid object trailer'
            break
        end
        if outfile then
            -- make sure object UID and ClassID are the same in the trailer
            if substr(hdr,16,8) ~= substr(buff,16,8) then err = 'Non-matching object trailer'; break end
            -- write object trailer
            if not Write(outfile, objectTrailerGUID, substr(hdr,16)) then err = 1; break end
            writeLen = writeLen + 32
        end
    end
    if outfile then
        -- write null padding if necessary
        -- (InDesign files must be an even number of 4096-byte blocks)
        local part = writeLen % 4096
        if part ~= 0 then if not Write(outfile, ("\0"):rep(4096 - part)) then err = 1 end end
    end
::DONE::
    if not err then
        if outfile and not foundXMP then et:Warn('No XMP stream to edit') end
        return 1       -- success!
    elseif not outfile then
        -- issue warning on read error
        if str(err) ~= '1' then et:Warn(err) end
    elseif str(err) ~= '1' then
        -- set error and return success code
        et:Error(err)
    else
        return -1      -- write error
    end
    return 1
end

return InDesign
