--------------------------------------------------------------------------------
-- File:         lexiftool/MIFF.lua
-- Ported from:  lib/Image/ExifTool/MIFF.pm
--
-- Description:  Read Magick Image File Format meta information
--
-- Revisions:    06/10/2005 - P. Harvey Created
--
-- References:   1) http://www.imagemagick.org/script/miff.php
--               2) http://www.cs.uni.edu/Help/ImageMagick/www/miff.html
--
-- Port notes:   read port: the Main table plus ProcessMIFF. The local
--               readUntilMarker helper replaces Perl's incremental buffer scan
--               for the ':' terminator. Upstream MIFF.pm is read-only.
--------------------------------------------------------------------------------

local MIFF = {}

-- APP1 segment headers (upstream $Image::ExifTool::exifAPP1hdr / $xmpAPP1hdr)
local exifAPP1hdr = 'Exif\0\0'
local xmpAPP1hdr = 'http://ns.adobe.com/xap/1.0/\0'

-- MIFF chunks
MIFF.Main = {
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        The MIFF (Magick Image File Format) format allows aribrary tag names to be
        used.  Only the standard tag names are listed below, however ExifTool will
        decode any tags found in the image.
    ]],
    ['background-color'] = 'BackgroundColor',
    ['blue-primary'] = 'BluePrimary',
    ['border-color'] = 'BorderColor',
    ['matt-color'] = 'MattColor',
    class = 'Class',
    colors = 'Colors',
    colorspace = 'ColorSpace',
    columns = 'ImageWidth',
    compression = 'Compression',
    delay = 'Delay',
    depth = 'Depth',
    dispose = 'Dispose',
    gamma = 'Gamma',
    ['green-primary'] = 'GreenPrimary',
    id = 'ID',
    iterations = 'Iterations',
    label = 'Label',
    matte = 'Matte',
    montage = 'Montage',
    packets = 'Packets',
    page = 'Page',
    -- (profile-* tags are handled specially by ProcessMIFF and never looked
    -- up via this table; upstream documents their SubDirectory here purely
    -- for TagNames documentation purposes -- not ported)
    ['red-primary'] = 'RedPrimary',
    ['rendering-intent'] = 'RenderingIntent',
    resolution = 'Resolution',
    rows = 'ImageHeight',
    scene = 'Scene',
    signature = 'Signature',
    units = 'Units',
    ['white-point'] = 'WhitePoint',
}

--------------------------------------------------------------------------------
-- Read from `raf` up to and including the literal 2-byte `marker`, or to EOF
-- if the marker is never found (mirror of upstream's `local $/ = ":\x1a"`
-- custom input-record-separator trick for $raf->ReadLine()).
-- Returns: the data read, including the marker if found
--------------------------------------------------------------------------------
local function readUntilMarker(raf, marker)
    local out = {}
    local mlen = #marker
    while true do
        local n, b = raf:Read(1)
        if n == 0 then break end
        out[#out + 1] = b
        if #out >= mlen then
            local tail = table.concat(out, '', #out - mlen + 1, #out)
            if tail == marker then break end
        end
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Extract meta information from a MIFF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid MIFF image
--------------------------------------------------------------------------------
function MIFF.ProcessMIFF(et, dirInfo)
    local raf = dirInfo.RAF

    -- validate the MIFF file (note: MIFF files _may_ begin with other
    -- characters, but this starting sequence is strongly suggested.)
    local n, hdr = raf:Read(14)
    if not (n == 14 and hdr == 'id=ImageMagick') then return 0 end
    et:SetFileType() -- set the FileType tag

    -- set end-of-line character sequence to read to end of the TEXT
    -- section for new-type MIFF files (text ends with Colon+Ctrl-Z)
    -- Old MIFF files end with Colon+Linefeed, so this will likely
    -- slurp those entire files, which will be slower, but will work
    -- OK except that the profile information won't be decoded
    local marker = ':\26'

    local profiles = {}
    local buff = readUntilMarker(raf, marker)
    if #buff > 0 then
        if buff:sub(-#marker) == marker then buff = buff:sub(1, -#marker - 1) end -- chomp
        local tagTablePtr = et:GetTagTable('lexiftool.MIFF.Main')
        local entries = { hdr } -- put the ID back in
        for w in buff:gmatch('[^ \t\n\r\f\v]+') do entries[#entries + 1] = w end

        local mode = ''
        local tag, val
        for _, entry in ipairs(entries) do
            if mode == 'com' then
                if entry:match('}$') then mode = '' end
                goto continueEntry
            elseif entry:match('^{') then
                mode = 'com' -- read to the end of the comment
                goto continueEntry
            end
            if mode == 'val' then
                val = val .. ' ' .. entry -- join back together with a space
                if not entry:match('}$') then goto continueEntry end
                mode = ''
                val = (val:gsub('^{', ''):gsub('}$', '')) -- remove braces
            elseif entry:match('^.+=.+$') then
                tag, val = entry:match('^(.+)=(.+)$')
                if val:match('^{') then
                    mode = 'val' -- read to the end of the value data
                    goto continueEntry
                end
            elseif entry:match('^:') then
                -- this could be the end of an old-style MIFF file
                break
            else
                -- something we don't recognize -- stop parsing here
                et:Warn('Unrecognized MIFF data')
                break
            end
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if not tagInfo then
                tagInfo = { Name = tag }
                et:AddTagToTable(tagTablePtr, tag, tagInfo)
            end
            -- handle profile tags specially
            local ptype = tag:match('^profile%-(.*)')
            if ptype then
                profiles[#profiles + 1] = { ptype, val }
            else
                et:FoundTag(tagInfo, val)
            end
            ::continueEntry::
        end
    end

    -- process profile information
    for _, prof in ipairs(profiles) do
        local ptype, lenStr = prof[1], prof[2]
        if not lenStr:match('^%d+$') then
            et:Warn('Invalid length for ' .. ptype .. ' profile')
            break -- don't try to read the rest
        end
        local len = tonumber(lenStr)
        local n2, pbuff = raf:Read(len)
        if n2 ~= len then
            et:Warn('Error reading ' .. ptype .. ' profile (' .. len .. ' bytes)')
        else
            local processed = false
            local pDirInfo = {
                Parent = 'PNG',
                DataPt = pbuff,
                DataPos = raf:Tell() - len,
                DataLen = len,
                DirStart = 0,
                DirLen = len,
            }
            if ptype == 'icc' then
                -- ICC Profile information
                local tagTablePtr = et:GetTagTable('lexiftool.ICC_Profile.Main')
                processed = et:ProcessDirectory(pDirInfo, tagTablePtr) ~= 0
            elseif ptype == 'iptc' then
                if pbuff:sub(1, 4) == '8BIM' then
                    -- Photoshop information
                    local tagTablePtr = et:GetTagTable('lexiftool.Photoshop.Main')
                    processed = et:ProcessDirectory(pDirInfo, tagTablePtr) ~= 0
                end
            -- I haven't seen 'exif' or 'xmp' profile types yet, but I have seen them
            -- in newer PNG files so presumably they are possible here as well - PH
            elseif ptype == 'APP1' or ptype == 'exif' or ptype == 'xmp' then
                if pbuff:sub(1, #exifAPP1hdr) == exifAPP1hdr then
                    -- APP1 EXIF
                    pDirInfo.DirStart = pDirInfo.DirStart + #exifAPP1hdr
                    pDirInfo.DirLen = pDirInfo.DirLen - #exifAPP1hdr
                    -- use the usual position for EXIF data: 12 bytes from start of file
                    -- (this may be wrong, but I can't see where the PNG stores this information)
                    pDirInfo.Base = 12 -- this is the usual value
                    processed = et:ProcessTIFF(pDirInfo) ~= 0
                elseif pbuff:sub(1, #xmpAPP1hdr) == xmpAPP1hdr then
                    -- APP1 XMP
                    local tagTablePtr = et:GetTagTable('lexiftool.XMP.Main')
                    pDirInfo.DirStart = pDirInfo.DirStart + #xmpAPP1hdr
                    pDirInfo.DirLen = pDirInfo.DirLen - #xmpAPP1hdr
                    processed = et:ProcessDirectory(pDirInfo, tagTablePtr) ~= 0
                end
            end
            if not processed then
                et:Warn('Unknown MIFF ' .. ptype .. ' profile data')
            end
        end
    end
    return 1
end

return MIFF
