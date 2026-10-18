--------------------------------------------------------------------------------
-- File:         lexiftool/Radiance.lua
-- Ported from:  lib/Image/ExifTool/Radiance.pm
--
-- Description:  Read Radiance RGBE HDR meta information
--
-- Revisions:    2011/12/10 - P. Harvey Created
--
-- References:   1) http://www.graphics.cornell.edu/online/formats/rgbe/
--               2) http://radsite.lbl.gov/radiance/refer/filefmts.pdf
--
-- Port notes:   read port: the Main table plus ProcessHDR. The local chomp and
--               trimLeading helpers stand in for the Perl builtin and its
--               inline whitespace strip. Upstream Radiance.pm is read-only.
--------------------------------------------------------------------------------

local Radiance = {}
local perl = require('lexiftool.perl')
local lc, ucfirst = perl.lc, perl.ucfirst

-- Radiance tags
Radiance.Main = {
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        Information extracted from Radiance RGBE HDR images.  Tag ID's are all
        uppercase as stored in the file, but converted to lowercase by when
        extracting to avoid conflicts with internal ExifTool variables.  See
        L<http://radsite.lbl.gov/radiance/refer/filefmts.pdf> and
        L<http://www.graphics.cornell.edu/online/formats/rgbe/> for the
        specification.
    ]],
    _orient = {
        Name = 'Orientation',
        PrintConv = {
            ['-Y +X'] = 'Horizontal (normal)',
            ['-Y -X'] = 'Mirror horizontal',
            ['+Y -X'] = 'Rotate 180',
            ['+Y +X'] = 'Mirror vertical',
            ['+X -Y'] = 'Mirror horizontal and rotate 270 CW',
            ['+X +Y'] = 'Rotate 90 CW',
            ['-X +Y'] = 'Mirror horizontal and rotate 90 CW',
            ['-X -Y'] = 'Rotate 270 CW',
        },
    },
    _command = 'Command',
    _comment = 'Comment',
    software = 'Software',
    view = 'View',
    ['format'] = 'Format', -- <-- this is the one that caused the conflict when uppercase
    exposure = {
        Name = 'Exposure',
        Notes = 'divide pixel values by this to get watts/steradian/meter^2',
    },
    gamma = 'Gamma',
    colorcorr = 'ColorCorrection',
    pixaspect = 'PixelAspectRatio',
    primaries = 'ColorPrimaries',
}

-- strip a single trailing "\n" (upstream: local $/ = "\x0a"; chomp $buff)
local function chomp(s)
    if s:sub(-1) == '\n' then return s:sub(1, -2) end
    return s
end

local function trimLeading(s) return (s:gsub('^[ \t\n\r\f\v]+', '')) end

--------------------------------------------------------------------------------
-- Extract information from a Radiance HDR file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid RGBE image
--------------------------------------------------------------------------------
function Radiance.ProcessHDR(et, dirInfo)
    local raf = dirInfo.RAF

    -- verify this is a valid RGBE file
    local n, buff = raf:ReadLine()
    -- upstream: `$buff =~ /^#\?(RADIANCE|RGBE)\x0a/s` (PCRE2 via the facade
    -- -- Lua patterns have no alternation)
    if n == 0 or not perl.matches(buff, '^#\\?(RADIANCE|RGBE)\n') then return 0 end
    et:SetFileType()
    local tagTablePtr = et:GetTagTable('lexiftool.Radiance.Main')

    while true do
        local n2, line = raf:ReadLine()
        if n2 == 0 then break end
        line = chomp(line)
        if not (#line > 0 and #line < 4096) then break end
        local comment = line:match('^#[ \t\n\r\f\v]*(.*)$')
        if comment then
            if #comment > 0 then et:HandleTag(tagTablePtr, '_comment', comment) end
            goto continueLoop
        end
        local eq = nil
        for i = #line, 1, -1 do
            if line:sub(i, i) == '=' then eq = i; break end
        end
        if not eq then
            if #line > 0 then et:HandleTag(tagTablePtr, '_command', line) end
            goto continueLoop
        end
        do
            -- upstream's greedy (.*)?\s*=\s*(.*) backtracks to the LAST '='
            -- with zero chars consumed by the \s* before it, so any
            -- whitespace right before that '=' stays part of $1/tag - do
            -- not trim it here (a tag key with trailing spaces then misses
            -- the predefined table entry, same as upstream)
            local tag = lc(line:sub(1, eq - 1))
            local val = trimLeading(line:sub(eq + 1))
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if not tagInfo then
                local name = tag:gsub('[^A-Za-z0-9%-_]', '')
                if #name <= 1 then goto continueLoop end
                name = ucfirst(name)
                tagInfo = { Name = name }
                et:AddTagToTable(tagTablePtr, tag, tagInfo)
            end
            et:FoundTag(tagInfo, val)
        end
        ::continueLoop::
    end
    -- get image dimensions
    local n3, buff3 = raf:ReadLine()
    if n3 > 0 then
        local s1, h, s2, w = buff3:match('([%-%+][XY])[ \t\n\r\f\v]*(%d+)[ \t\n\r\f\v]*([%-%+][XY])[ \t\n\r\f\v]*(%d+)')
        if s1 then
            et:HandleTag(tagTablePtr, '_orient', s1 .. ' ' .. s2)
            et:FoundTag('ImageHeight', h)
            et:FoundTag('ImageWidth', w)
        end
    end
    return 1
end

return Radiance
