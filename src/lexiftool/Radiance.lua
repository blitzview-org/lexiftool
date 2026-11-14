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
-- Port notes:   read port: the Main table plus ProcessHDR. Upstream
--               Radiance.pm is read-only.
--------------------------------------------------------------------------------

local Radiance = {}
local perl = require('lexiftool.perl')
local lc, ucfirst = perl.lc, perl.ucfirst
local chomp, tr, length = perl.chomp, perl.tr, perl.length
local isMatch, substN = perl.isMatch, perl.substN
local perlTruthy = perl.truthy

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

--------------------------------------------------------------------------------
-- Extract information from a Radiance HDR file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid RGBE image
--------------------------------------------------------------------------------
function Radiance.ProcessHDR(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, n
    local RS = "\x0a"  -- set newline character for reading   (local $/)

    -- verify this is a valid RIFF file
    n, buff = raf:ReadLine(RS)
    if not (perlTruthy(n) and isMatch(buff, [[(?s)^#\?(RADIANCE|RGBE)\x0a]])) then return 0 end
    et:SetFileType()
    local tagTablePtr = et:GetTagTable('lexiftool.Radiance.Main')

    while true do
        n, buff = raf:ReadLine(RS)
        if not perlTruthy(n) then break end
        buff = chomp(buff, RS)
        if not (length(buff) > 0 and length(buff) < 4096) then break end
        local didSubst
        buff, didSubst = substN(buff, [[^#\s*]], '')
        if didSubst then
            if perlTruthy(length(buff)) then et:HandleTag(tagTablePtr, '_comment', buff) end
            goto next
        end
        local ok, c1, c2 = isMatch(buff, [[^(.*)?\s*=\s*(.*)]])
        if not ok then
            if perlTruthy(length(buff)) then et:HandleTag(tagTablePtr, '_command', buff) end
            goto next
        end
        -- use lower-case tag names to avoid conflicts with reserved tag table entries
        local tag, val = lc(c1), c2
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not tagInfo then
            local name = tag
            name = tr(name, '-_a-zA-Z0-9', '', 'dc')
            if length(name) <= 1 then goto next end
            name = ucfirst(name)
            tagInfo = { Name = name }
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        et:FoundTag(tagInfo, val)
        ::next::
    end
    -- get image dimensions
    n, buff = raf:ReadLine(RS)
    local ok, c1, c2, c3, c4
    if perlTruthy(n) then
        ok, c1, c2, c3, c4 = isMatch(buff, [[([-+][XY])\s*(\d+)\s*([-+][XY])\s*(\d+)]])
    end
    if ok then
        et:HandleTag(tagTablePtr, '_orient', c1 .. " " .. c3)
        et:FoundTag('ImageHeight', c2)
        et:FoundTag('ImageWidth', c4)
    end
    return 1
end

return Radiance
