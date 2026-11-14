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
-- Port notes:   read port: the Main table plus ProcessMIFF. Upstream
--               MIFF.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local isMatch = perl.isMatch
local matches = perl.matches
local subst = perl.subst
local split = perl.split
local chomp = perl.chomp
local GetTagTable = ExifTool.GetTagTable

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
    -- profile tags.  Note the SubDirectory is not used by ProcessMIFF(),
    -- but is inserted for documentation purposes only
    ['profile-APP1'] = {
        -- [this list is just for the sake of the documentation]
        {
            Name = 'APP1_Profile',
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
            },
        },
        {
            Name = 'APP1_Profile',
            SubDirectory = {
                TagTable = 'lexiftool.XMP.Main',
            },
        },
    },
    ['profile-exif'] = { -- haven't seen this, but it would make sense - PH
        Name = 'EXIF_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
        },
    },
    ['profile-icc'] = {
        Name = 'ICC_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    ['profile-iptc'] = {
        Name = 'IPTC_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.Main',
        },
    },
    ['profile-xmp'] = { -- haven't seen this, but it would make sense - PH
        Name = 'XMP_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
        },
    },
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
-- Extract meta information from a MIFF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid MIFF image
--------------------------------------------------------------------------------
function MIFF.ProcessMIFF(et, dirInfo)
    local raf = dirInfo.RAF
    local verbose = et.OPTIONS.Verbose
    local hdr, buff, n

    -- validate the MIFF file (note: MIFF files _may_ begin with other
    -- characters, but this starting sequence is strongly suggested.)
    n, hdr = raf:Read(14)
    if n ~= 14 then return 0 end
    if hdr ~= 'id=ImageMagick' then return 0 end
    et:SetFileType()   -- set the FileType tag

    -- set end-of-line character sequence to read to end of the TEXT
    -- section for new-type MIFF files (text ends with Colon+Ctrl-Z)
    -- Old MIFF files end with Colon+Linefeed, so this will likely
    -- slurp those entire files, which will be slower, but will work
    -- OK except that the profile information won't be decoded
    local rs = ':\x1a'    -- (local $/)

    local mode = ''
    local profiles = {}
    n, buff = raf:ReadLine(rs)
    if perlTruthy(n) then
        buff = chomp(buff, rs)    -- remove end-of-line chars
        local tagTablePtr = GetTagTable(nil, 'lexiftool.MIFF.Main')
        local entries = split(' ', buff)
        table.insert(entries, 1, hdr) -- put the ID back in
        local tag, val
        for _, entry in ipairs(entries) do
            if mode == 'com' then
                if isMatch(entry, [[\}$]]) then mode = '' end
                goto next
            elseif isMatch(entry, [[^\{]]) then
                mode = 'com'  -- read to the end of the comment
                goto next
            end
            if mode == 'val' then
                val = val .. ' ' .. entry  -- join back together with a space
                if not isMatch(entry, [[\}$]]) then goto next end
                mode = ''
                val = subst(val, [[(^\{|\}$)]], '', 'g') -- remove braces
            elseif isMatch(entry, [[(.+)=(.+)]]) then
                tag, val = matches(entry, [[(.+)=(.+)]])
                if isMatch(val, [[^\{]]) then
                    mode = 'val'      -- read to the end of the value data
                    goto next
                end
            elseif isMatch(entry, '^:') then
                -- this could be the end of an old-style MIFF file
                break
            else
                -- something we don't recognize -- stop parsing here
                et:Warn('Unrecognized MIFF data')
                break
            end
            do
                local tagInfo = et:GetTagInfo(tagTablePtr, tag)
                if not tagInfo then
                    tagInfo = { Name = tag }
                    et:AddTagToTable(tagTablePtr, tag, tagInfo)
                end
                if perlTruthy(verbose) then
                    et:VerboseInfo(tag, tagInfo, {
                        Table  = tagTablePtr,
                        DataPt = val,
                    })
                end
                -- handle profile tags specially
                local ok, ptype = isMatch(tag, '^profile-(.*)')
                if ok then
                    profiles[#profiles + 1] = { ptype, val }
                else
                    et:FoundTag(tagInfo, val)
                end
            end
            ::next::
        end
    end

    -- process profile information
    for _, prof in ipairs(profiles) do
        local type_, len = prof[1], prof[2]
        if not isMatch(len, [[^\d+$]]) then
            et:Warn('Invalid length for ' .. type_ .. ' profile')
            break   -- don't try to read the rest
        end
        len = perl.num(len)
        n, buff = raf:Read(len)
        if n ~= len then
            et:Warn('Error reading ' .. type_ .. ' profile (' .. len .. ' bytes)')
            goto nextProfile
        end
        do
            local processed = 0
            local dirInfo2 = {
                Parent   = 'PNG',
                DataPt   = buff,
                DataPos  = raf:Tell() - len,
                DataLen  = len,
                DirStart = 0,
                DirLen   = len,
            }
            if type_ == 'icc' then
                -- ICC Profile information
                local tagTablePtr = GetTagTable(nil, 'lexiftool.ICC_Profile.Main')
                processed = et:ProcessDirectory(dirInfo2, tagTablePtr)
            elseif type_ == 'iptc' then
                if isMatch(buff, '^8BIM') then
                    -- Photoshop information
                    local tagTablePtr = GetTagTable(nil, 'lexiftool.Photoshop.Main')
                    processed = et:ProcessDirectory(dirInfo2, tagTablePtr)
                end
            -- I haven't seen 'exif' or 'xmp' profile types yet, but I have seen them
            -- in newer PNG files so presumably they are possible here as well - PH
            elseif type_ == 'APP1' or type_ == 'exif' or type_ == 'xmp' then
                if buff:sub(1, #exifAPP1hdr) == exifAPP1hdr then
                    -- APP1 EXIF
                    local hdrLen = #exifAPP1hdr
                    dirInfo2.DirStart = dirInfo2.DirStart + hdrLen
                    dirInfo2.DirLen = dirInfo2.DirLen - hdrLen
                    -- use the usual position for EXIF data: 12 bytes from start of file
                    -- (this may be wrong, but I can't see where the PNG stores this information)
                    dirInfo2.Base = 12 -- this is the usual value
                    processed = et:ProcessTIFF(dirInfo2)
                elseif buff:sub(1, #xmpAPP1hdr) == xmpAPP1hdr then
                    -- APP1 XMP
                    local hdrLen = #xmpAPP1hdr
                    local tagTablePtr = GetTagTable(nil, 'lexiftool.XMP.Main')
                    dirInfo2.DirStart = dirInfo2.DirStart + hdrLen
                    dirInfo2.DirLen = dirInfo2.DirLen - hdrLen
                    processed = et:ProcessDirectory(dirInfo2, tagTablePtr)
                end
            end
            if not perlTruthy(processed) then
                et:Warn('Unknown MIFF ' .. type_ .. ' profile data')
                if perlTruthy(verbose) then
                    et:VerboseDir(type_, 0, len)
                    et:VerboseDump(buff)
                end
            end
        end
        ::nextProfile::
    end
    return 1
end

return MIFF
