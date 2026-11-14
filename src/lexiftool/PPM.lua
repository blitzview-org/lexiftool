--------------------------------------------------------------------------------
-- File:         lexiftool/PPM.lua
-- Ported from:  lib/Image/ExifTool/PPM.pm
--
-- Description:  Read and write PPM meta information
--
-- Revisions:    09/03/2005 - P. Harvey Created
--
-- References:   1) http://netpbm.sourceforge.net/doc/ppm.html
--               2) http://netpbm.sourceforge.net/doc/pgm.html
--               3) http://netpbm.sourceforge.net/doc/pbm.html
--
-- Port notes:   ProcessPPM in full (read and write).  Perl's `for (;;)` with
--               `next` is a `while true` loop with a `goto continue` at its
--               end.  pos($buff) is the local `pos`: a `/g` match continues
--               at it, a failed `/g` match without /c resets it, and the
--               `.=`/Read at the top of every pass resets it as well (so each
--               pass parses the grown buffer from the start).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local Write = Writer.Write
local perlTruthy = ExifTool.perlTruthy
local GetTagTable = ExifTool.GetTagTable
local perl = require('lexiftool.perl')
local matches, isMatch, subst = perl.matches, perl.isMatch, perl.subst
local substr = perl.substr
local print = perl.print

local PPM = {}

--------------------------------------------------------------------------------
-- Read or write information in a PPM/PGM/PBM image
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid PPM file, -1 on write error
function PPM.ProcessPPM(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local buff, num, type_, seal
    local info = {}
    local pos, c1, c2, e, _ -- (pos($buff); the captures and end of the last match)
--
-- read as much of the image as necessary to extract the header and comments
--
    while true do -- (upstream `for (;;)`)
        if buff ~= nil then
            -- need to read some more data
            local n, tmp = raf:Read(1024)
            if n == 0 then return 0 end
            buff = buff .. tmp
        else
            local n
            n, buff = raf:Read(1024)
            if n == 0 then return 0 end
        end
        -- verify this is a valid PPM file
        num, pos = matches(buff, [[^P([1-6])\s+]])
        if not num then return 0 end
        -- note: may contain comments starting with '#'
        c1, e = matches(buff, [[\G#]], pos)
        if c1 then
            pos = e
            -- must read more if we are in the middle of a comment
            c1, _, e = matches(buff, [[\G ?(.*[\n\r]+(#.*[\n\r]+)*)\s*]], pos)
            if not c1 then goto continue end
            pos = e
            info.Comment = c1
            if isMatch(buff, [[\G#]], pos) then goto continue end
        else
            info.Comment = nil
        end
        c1, c2, e = matches(buff, [[\G(\S+)\s+(\S+)\s+]], pos)
        if not c1 then goto continue end
        pos = e
        info.ImageWidth = c1
        info.ImageHeight = c2
        type_ = ({ 'PPM', 'PBM', 'PGM' })[num % 3 + 1]
        if type_ == 'PBM' then break end -- (no MaxVal for PBM images)
        c1, e = matches(buff, [[\G\s*#]], pos)
        if c1 then
            pos = e
            c1, _, e = matches(buff, [[\G ?(.*[\n\r]+(#.*[\n\r]+)*)\s*]], pos)
            if not c1 then goto continue end
            pos = e
            if info.Comment == nil then info.Comment = '' end
            info.Comment = info.Comment .. c1
            if isMatch(buff, [[\G#]], pos) then goto continue end
        end
        c1, e = matches(buff, [[\G(\S+)\s]], pos)
        if not c1 then goto continue end
        pos = e
        info.MaxVal = c1
        break
        ::continue::
    end
    -- validate numerical values
    for k in pairs(info) do
        if k ~= 'Comment' then
            if not isMatch(info[k], [[^\d+$]]) then return 0 end
        end
    end
    if info.Comment ~= nil then
        info.Comment = subst(info.Comment, [[(?m)^# ?]], '', 'g')  -- remove "# " at the start of each line
        info.Comment = subst(info.Comment, [[[\n\r]+$]], '') -- remove trailing newline
        if isMatch(info.Comment, [[^<seal seal=]]) then seal = 1 end
    end
    et:SetFileType(type_)
    local len = pos
--
-- rewrite the file if requested
--
    if outfile then
        local newComment, nvHash = et:GetNewValue('Comment')
        local oldComment = info.Comment
        if perlTruthy(Writer.IsOverwriting(et, nvHash, oldComment)) then
            et.CHANGED = (et.CHANGED or 0) + 1
            if oldComment ~= nil then et:VerboseValue('- Comment', oldComment) end
            if newComment ~= nil then et:VerboseValue('+ Comment', newComment) end
        elseif seal and et.DEL_GROUP.SEAL then
            -- delete SEAL comment
            et:VerboseValue('- Comment', oldComment)
            et.CHANGED = (et.CHANGED or 0) + 1
        else
            newComment = oldComment  -- use existing comment
        end
        local hdr = 'P' .. num .. '\n'
        if newComment ~= nil then
            newComment = subst(newComment, [[\n]], '\n# ', 'g')
            hdr = hdr .. '# ' .. newComment .. '\n'
        end
        hdr = hdr .. info.ImageWidth .. ' ' .. info.ImageHeight .. '\n'
        if type_ ~= 'PBM' then hdr = hdr .. info.MaxVal .. '\n' end
        -- write header and start of image
        if not Write(outfile, hdr, substr(buff, len)) then return -1 end
        -- copy over the rest of the image
        while true do
            local n
            n, buff = raf:Read(0x10000)
            if n == 0 then break end
            if not Write(outfile, buff) then return -1 end
        end
        return 1
    end
--
-- save extracted information
--
    if perl.num(verbose) > 2 then
        print(out, type_ .. ' header (' .. len .. " bytes):\n")
        et:VerboseDump(buff, { Len = len })
    end
    if seal then
        et:ProcessDirectory({ DataPt = info.Comment }, GetTagTable(nil, 'lexiftool.XMP.SEAL'))
        info.Comment = nil
    end
    for _, tag in ipairs({ 'Comment', 'ImageWidth', 'ImageHeight', 'MaxVal' }) do
        if info[tag] ~= nil then et:FoundTag(tag, info[tag]) end
    end
    return 1
end

return PPM
