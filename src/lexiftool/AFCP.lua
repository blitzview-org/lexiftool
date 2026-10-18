--------------------------------------------------------------------------------
-- File:         lexiftool/AFCP.lua
-- Ported from:  lib/Image/ExifTool/AFCP.pm
--
-- Description:  Read/write AFCP trailer
--
-- Revisions:    12/26/2005 - P. Harvey Created
--
-- References:   1) http://web.archive.org/web/20080828211305/http://www.tocarte.com/media/axs_afcp_spec.pdf
--
-- Port notes:   complete: ProcessAFCP (read/write, ScanForTrailer offset
--               scan with the `$fix` shift) and the Main table. The Nail/PrVw
--               RawConv strings are the Lua function afcpImage.
--------------------------------------------------------------------------------

local ssub = string.sub

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local matchesDyn = perl.matchesDyn
local substr = perl.substr
local length = perl.length
local carray = require('carray')

local AFCP = {}

-- Extract a thumbnail/preview image from an AFCP Nail/PrVw value: search for
-- the JPEG SOI marker starting at byte offset 10 (upstream `pos($val) = 10`),
-- falling back to a fixed 8 bytes of padding after the 10-byte header.
local function afcpImage(self, val, tag)
    local m = val:find('\255\216\255', 11, true)
    local start = m and (m - 1) or 18
    -- (upstream ValidateImage returns the image reference; the port's returns the data)
    local pt = self:ValidateImage(ssub(val, start + 1), tag)
    if pt == nil then return nil end
    return { ref = 'SCALAR', value = pt }
end

AFCP.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
AFCP stands for AXS File Concatenation Protocol, and is a poorly designed
protocol for appending information to the end of files.  This can be used as
an auxiliary technique to store IPTC information in images, but is
incompatible with some file formats.

ExifTool will read and write (but not create) AFCP IPTC information in JPEG
and TIFF images.

See
L<http://web.archive.org/web/20080828211305/http://www.tocarte.com/media/axs_afcp_spec.pdf>
for the AFCP specification.
    ]],
    IPTC = { SubDirectory = { TagTable = 'lexiftool.IPTC.Main' } },
    TEXT = 'Text',
    Nail = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        RawConv = afcpImage,
    },
    PrVw = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        RawConv = afcpImage,
    },
}

--------------------------------------------------------------------------------
-- Read/write AFCP information in a file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- (Set 'ScanForTrailer' member in dirInfo to scan from current position for AFCP)
-- Returns: 1 on success, 0 if this file didn't contain AFCP information
--          -1 on write error or if the offsets were incorrect on reading
-- - updates DataPos to point to actual AFCP start if ScanForTrailer is set
-- - updates DirLen to trailer length
-- - returns Fixup reference in dirInfo hash when writing
function AFCP.ProcessAFCP(et, dirInfo)
    local Writer = require('lexiftool.Writer')
    local raf = dirInfo.RAF
    local curPos = raf:Tell()
    local offset = dirInfo.Offset or 0    -- offset from end of file
    local rtnVal = 0

    -- (`NoAFCP: for (;;)`: every path leaves the loop, `last NoAFCP` is `goto noAFCP`)
    -- luacheck: ignore 512
    while true do
        local buff, fix, dirBuff, valBuff, fixup, vers
        local n, ok, hdr, mark
        -- look for AXS trailer
        if raf:Seek(-12-offset, 2) then n, buff = raf:Read(12) end
        if n == 12 then ok, hdr, mark = isMatch(buff, '^(AXS(!|\\*))') end
        if not ok then break end
        local endPos = raf:Tell()
        ExifTool.SetByteOrder(mark == '!' and 'MM' or 'II')
        local startPos = ExifTool.Get32u(buff, 4)
        n = nil
        if raf:Seek(startPos, 0) then n, buff = raf:Read(12) end
        if n == 12 and isMatchDyn(buff, '^' .. hdr) then
            fix = 0
        else
            rtnVal = -1
            -- look for start of AXS trailer if 'ScanForTrailer'
            if not (dirInfo.ScanForTrailer and raf:Seek(curPos, 0)) then break end
            local actualPos = curPos
            -- first look for header right at current position
            while true do
                n, buff = raf:Read(12)
                if n == 12 and isMatchDyn(buff, '^' .. hdr) then break end
                if actualPos ~= curPos then goto noAFCP end
                -- scan for AXS header (could be after preview image)
                while true do
                    local n2, buf2 = raf:Read(65536)
                    if not perlTruthy(n2) then goto noAFCP end
                    buff = buff .. buf2
                    local m, e = matchesDyn(buff, hdr)
                    if m then
                        actualPos = actualPos + e - length(hdr)
                        break   -- ok, now go back and re-read header
                    end
                    buf2 = substr(buf2, -3)  -- only need last 3 bytes for next test
                    actualPos = actualPos + length(buff) - length(buf2)
                    buff = buf2
                end
                if not raf:Seek(actualPos, 0) then break end  -- seek to start of AFCP
            end
            -- calculate shift for fixing AFCP offsets
            fix = actualPos - startPos
        end
        -- set variables returned in dirInfo hash
        dirInfo.DataPos = startPos + fix  -- actual start position
        dirInfo.DirLen = endPos - (startPos + fix)

        rtnVal = 1
        local verbose = et:Options('Verbose')
        local out = et:Options('TextOut')
        local outfile = dirInfo.OutFile
        if outfile then
            -- allow all AFCP information to be deleted
            if et.DEL_GROUP.AFCP then
                if perlTruthy(verbose) then out:write("  Deleting AFCP\n") end
                et.CHANGED = (et.CHANGED or 0) + 1
                break
            end
            dirBuff, valBuff = carray.new('char'), carray.new('char')
            local Fixup = require('lexiftool.Fixup')
            fixup = dirInfo.Fixup
            if not fixup then fixup = Fixup.new(); dirInfo.Fixup = fixup end
            vers = substr(buff, 4, 2) -- get version number
        else
            if perlTruthy(verbose) or et.HTML_DUMP then et:DumpTrailer(dirInfo) end
        end
        -- read AFCP directory data
        local numEntries = ExifTool.Get16u(buff, 6)
        local nDir, dir = raf:Read(12 * numEntries)
        if nDir ~= 12 * numEntries then
            et:Error('Error reading AFCP directory', 1)
            break
        end
        if verbose > 2 and not outfile then
            local dat = buff .. dir
            out:write("  AFCP Directory:\n")
            et:VerboseDump(dat, { Addr = dirInfo.DataPos, Width = 12 })
        end
        if perlTruthy(fix) then et:Warn('Adjusted AFCP offsets by ' .. fix, 1) end
--
-- process AFCP directory
--
        local tagTablePtr = et:GetTagTable('lexiftool.AFCP.Main')
        for index = 0, numEntries - 1 do
            local entry = 12 * index
            local tag = substr(dir, entry, 4)
            local size = ExifTool.Get32u(dir, entry + 4)
            local offset = ExifTool.Get32u(dir, entry + 8) -- luacheck: ignore 421
            n = nil
            if size < 0x80000000 and
                raf:Seek(offset+fix, 0)
            then
                n, buff = raf:Read(size)
            end
            if n == size then
                if outfile then
                    -- rewrite this information
                    local tagInfo = et:GetTagInfo(tagTablePtr, tag)
                    if tagInfo and tagInfo.SubDirectory then
                        local subdirInfo = {
                            DataPt = buff,
                            DirStart = 0,
                            DirLen = size,
                            DataPos = offset + fix,
                            Parent = 'AFCP',
                        }
                        local subTable = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                        local newDir = Writer.WriteDirectory(et, subdirInfo, subTable)
                        if newDir ~= nil then
                            size = length(newDir)
                            buff = newDir
                        end
                    end
                    fixup:AddFixup(length(dirBuff) + 8)
                    dirBuff:append(tag, ExifTool.Put32u(size), ExifTool.Put32u(length(valBuff)))
                    valBuff:append(buff)
                else
                    -- extract information
                    et:HandleTag(tagTablePtr, tag, buff, {
                        DataPt = buff,
                        Size = size,
                        Index = index,
                        DataPos = offset + fix,
                    })
                end
            else
                et:Warn('Bad AFCP directory')
                if outfile then rtnVal = -1 end
                break
            end
        end
        if outfile and length(dirBuff) > 0 then
            local outPos = Writer.Tell(outfile)    -- get current outfile position
            -- apply fixup to directory pointers
            local valPos = outPos + 12      -- start of value data
            fixup.Shift = fixup.Shift + valPos + length(dirBuff)
            fixup:ApplyFixup(dirBuff)
            -- write the AFCP header, directory, value data and EOF record (with zero checksums)
            if not perlTruthy(Writer.Write(outfile, hdr, vers, ExifTool.Put16u(length(dirBuff)/12), ExifTool.Put32u(0),
                  dirBuff, valBuff, hdr, ExifTool.Put32u(outPos), ExifTool.Put32u(0))) then rtnVal = -1 end
            -- complete fixup so the calling routine can apply further shifts
            fixup:AddFixup(length(dirBuff) + length(valBuff) + 4)
            fixup.Start = fixup.Start + valPos
            fixup.Shift = fixup.Shift - valPos
        end
        break
    end
    ::noAFCP::
    return rtnVal
end

-- (PROCESS_PROC is set here so the table can reference the function above)
AFCP.Main.PROCESS_PROC = AFCP.ProcessAFCP

return AFCP
