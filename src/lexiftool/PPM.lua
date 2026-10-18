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
-- Port notes:   read subset: single-pass ProcessPPM (reads one 1024-byte
--               chunk). Upstream re-enters its parse loop and reads more
--               data when a comment block or header spans more than the
--               current buffer; that growing-buffer retry is deferred (not
--               exercised by the vendored test image, which is 223 bytes).
--               The write path IS ported (Comment is the only writable tag
--               in a PPM, and the image data is copied straight through);
--               deferred there: upstream's deletion of a SEAL comment when
--               the SEAL group is deleted, since SEAL is not ported.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local Write = Writer.Write
local perlTruthy = ExifTool.perlTruthy

local PPM = {}

-- match a `\G ?(.*[\n\r]+(#.*[\n\r]+)*)\s*` comment block starting right
-- after the leading '#' (upstream's optional single space, then one or
-- more '#'-prefixed lines, then trailing whitespace)
-- Returns: comment text (including embedded "#" line prefixes, if any),
--          position right after the trailing whitespace; or nil if the
--          block doesn't terminate within the buffer (deferred: upstream
--          would read more data and retry)
local function commentBlock(buff, pos)
    if buff:sub(pos, pos) == ' ' then pos = pos + 1 end
    -- upstream's '.' has no /s flag, so it excludes only '\n' (not '\r');
    -- '[^\n]*' (greedy, backtracking) mirrors that, unlike Lua's '.' which
    -- matches '\n' too and '.-' which is non-greedy - either would wrongly
    -- stop at (or swallow past) an embedded lone '\r'
    local first, afterFirst = buff:match('^([^\n]*[\n\r]+)()', pos)
    if not first then return nil, pos end
    local comment, p = first, afterFirst
    while buff:sub(p, p) == '#' do
        local more, afterMore = buff:match('^([^\n]*[\n\r]+)()', p)
        if not more then return nil, pos end
        comment = comment .. more
        p = afterMore
    end
    local wsEnd = buff:match('^[ \t\n\r\f\v]*()', p)
    return comment, wsEnd
end

--------------------------------------------------------------------------------
-- Read information in a PPM/PGM/PBM image (read subset)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid PPM file
--------------------------------------------------------------------------------
function PPM.ProcessPPM(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local n, buff = raf:Read(1024)
    if n == 0 then return 0 end

    -- verify this is a valid PPM file
    local num, pos = buff:match('^P([1-6])[ \t\n\r\f\v]+()')
    if not num then return 0 end

    local info = {}
    if buff:sub(pos, pos) == '#' then
        local comment, newPos = commentBlock(buff, pos + 1)
        if not comment then return 0 end -- (need more data; deferred)
        info.Comment = comment
        pos = newPos
        if buff:sub(pos, pos) == '#' then return 0 end -- (deferred)
    end

    local w, h, afterWH = buff:match('^([^ \t\n\r\f\v]+)[ \t\n\r\f\v]+([^ \t\n\r\f\v]+)[ \t\n\r\f\v]+()', pos)
    if not w then return 0 end
    info.ImageWidth = w
    info.ImageHeight = h
    pos = afterWH

    local ftype = ({ [0] = 'PPM', [1] = 'PBM', [2] = 'PGM' })[tonumber(num) % 3]
    if ftype ~= 'PBM' then -- (no MaxVal for PBM images)
        local wsEnd = buff:match('^[ \t\n\r\f\v]*()', pos)
        if buff:sub(wsEnd, wsEnd) == '#' then
            local comment, newPos = commentBlock(buff, wsEnd + 1)
            if not comment then return 0 end -- (deferred)
            info.Comment = (info.Comment or '') .. comment
            pos = newPos
            if buff:sub(pos, pos) == '#' then return 0 end -- (deferred)
        end
        local maxVal, afterMax = buff:match('^([^ \t\n\r\f\v]+)[ \t\n\r\f\v]()', pos)
        if not maxVal then return 0 end
        info.MaxVal = maxVal
        pos = afterMax
    end

    -- validate numerical values
    for k, v in pairs(info) do
        if k ~= 'Comment' and not v:match('^%d+$') then return 0 end
    end
    if info.Comment then
        info.Comment = info.Comment:gsub('\n# ?', '\n') -- remove "# " at the start of each line
        info.Comment = info.Comment:gsub('[\n\r]+$', '') -- remove trailing newline
    end
    et:SetFileType(ftype)
    -- `pos` is upstream's `$len = pos($buff)`: everything from here on in the
    -- buffer is already image data
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
        else
            -- (upstream additionally deletes a SEAL comment here when the SEAL
            --  group is being deleted; SEAL is not ported)
            newComment = oldComment -- use existing comment
        end
        local hdr = 'P' .. num .. '\n'
        if newComment ~= nil then
            hdr = hdr .. '# ' .. newComment:gsub('\n', '\n# ') .. '\n'
        end
        hdr = hdr .. info.ImageWidth .. ' ' .. info.ImageHeight .. '\n'
        if ftype ~= 'PBM' then hdr = hdr .. info.MaxVal .. '\n' end
        -- write header and start of image
        if not Write(outfile, hdr, buff:sub(pos)) then return -1 end
        -- copy over the rest of the image
        while true do
            local n2, b2 = raf:Read(0x10000)
            if n2 == 0 then break end
            if not Write(outfile, b2) then return -1 end
        end
        return 1
    end

    -- save extracted information
    for _, tag in ipairs({ 'Comment', 'ImageWidth', 'ImageHeight', 'MaxVal' }) do
        if info[tag] ~= nil then et:FoundTag(tag, info[tag]) end
    end
    return 1
end

return PPM
