--------------------------------------------------------------------------------
-- File:         lexiftool/RSRC.lua
-- Ported from:  lib/Image/ExifTool/RSRC.pm
--
-- Description:  Read Mac OS Resource information
--
-- Revisions:    2010/03/17 - P. Harvey Created
--
-- References:   1) http://developer.apple.com/legacy/mac/library/documentation/mac/MoreToolbox/MoreToolbox-99.html
--
-- Port notes:   read port: the Main table plus ProcessRSRC. Upstream RSRC.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local substr = require('lexiftool.perl').substr
local sprintf = require('lexiftool.perl').sprintf

local RSRC = {}

-- Information decoded from Mac OS resources
RSRC.Main = {
    GROUPS = { [2] = 'Document' },
    PROCESS_PROC = false, -- set below to RSRC.ProcessRSRC
    NOTES = [[
        Tags extracted from Mac OS resource files, DFONT files and "._" sidecar
        files.  These tags may also be extracted from the resource fork of any file
        in OS X, either by adding "/..namedfork/rsrc" to the filename to process the
        resource fork alone, or by using the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option to process
        the resource fork as a sub-document of the main file.  When writing,
        ExifTool preserves the Mac OS resource fork by default, but it may deleted
        with C<-rsrc:all=> on the command line.
    ]],
    ['8BIM'] = {
        Name = 'PhotoshopInfo',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Main' },
    },
    sfnt = {
        Name = 'Font',
        SubDirectory = { TagTable = 'lexiftool.Font.Name' },
    },
    -- my samples of postscript-type DFONT files have a POST resource
    -- with ID 0x1f5 and the same format as a PostScript file
    POST_0x01f5 = {
        Name = 'PostscriptFont',
        SubDirectory = { TagTable = 'lexiftool.PostScript.Main' },
    },
    usro_0x0000 = 'OpenWithApplication',
    vers_0x0001 = 'ApplicationVersion',
    ['STR _0xbff3'] = 'ApplicationMissingMsg',
    ['STR _0xbff4'] = 'CreatorApplication',
    -- the following written by Photoshop
    -- (ref http://www.adobe.ca/devnet/photoshop/psir/ps_image_resources.pdf)
    ['STR#_0x0080'] = 'Keywords',
    TEXT_0x0080 = 'Description',
    -- don't extract PICT's because the clip region isn't set properly
    -- in the PICT resource for some reason.  Also, a dummy 512-byte
    -- header would have to be added to create a valid PICT file.
    -- PICT => { Name => 'PreviewPICT', Binary => 1 },
}

--------------------------------------------------------------------------------
-- Read information from a Mac resource file (ref 1)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid resource file
--------------------------------------------------------------------------------
function RSRC.ProcessRSRC(et, dirInfo)
    local raf = dirInfo.RAF

    -- allow access with data reference
    if not raf then raf = require('lexiftool.RandomAccess').new(dirInfo.DataPt) end

    -- attempt to validate the format as thoroughly as practical
    local n, hdr = raf:Read(30)
    if n ~= 30 then return 0 end
    ExifTool.SetByteOrder('MM')
    local datOff = ExifTool.Get32u(hdr, 0)
    local mapOff = ExifTool.Get32u(hdr, 4)
    local datLen = ExifTool.Get32u(hdr, 8)
    local mapLen = ExifTool.Get32u(hdr, 12)
    if not raf:Seek(0, 2) then return 0 end
    local fLen = raf:Tell()
    if datOff < 0x10 or datOff + datLen > fLen then return 0 end
    if mapOff < 0x10 or mapOff + mapLen > fLen or mapLen < 30 then return 0 end
    if datOff < mapOff and datOff + datLen > mapOff then return 0 end
    if mapOff < datOff and mapOff + mapLen > datOff then return 0 end

    -- read the resource map
    if not raf:Seek(mapOff, 0) then return 0 end
    local n2, map = raf:Read(mapLen)
    if n2 ~= mapLen then return 0 end

    local typeOff = ExifTool.Get16u(map, 24)
    local nameOff = ExifTool.Get16u(map, 26)
    local numTypes = (ExifTool.Get16u(map, 28) + 1) & 0xffff

    -- validate offsets in the resource map
    if typeOff < 28 or nameOff < 30 then return 0 end

    if not et.IN_RESOURCE then et:SetFileType('RSRC') end
    local verbose = et.OPTIONS.Verbose
    local tagTablePtr = et:GetTagTable('lexiftool.RSRC.Main')
    et:VerboseDir('RSRC', numTypes)

    -- parse resource type list
    for i = 0, numTypes - 1 do
        local off = typeOff + 2 + 8 * i -- offset of entry in type list
        if off + 8 > mapLen then break end
        local resType = substr(map, off, 4) -- resource type
        local resNum = ExifTool.Get16u(map, off + 4) -- number of resources - 1
        local refOff = ExifTool.Get16u(map, off + 6) + typeOff -- offset to first resource reference
        -- loop through all resources
        for j = 0, resNum do
            local roff = refOff + 12 * j
            if roff + 12 > mapLen then break end
            -- read only the 24-bit resource data offset
            local id = ExifTool.Get16u(map, roff)
            local resOff = (ExifTool.Get32u(map, roff + 4) & 0x00ffffff) + datOff
            local resNameOff = ExifTool.Get16u(map, roff + 2) + nameOff + mapOff
            local tag, val, valLen
            local tagInfo = tagTablePtr[resType]
            if tagInfo then
                tag = resType
            else
                tag = sprintf('%s_0x%.4x', resType, id)
                tagInfo = tagTablePtr[tag]
            end
            -- read the resource data if necessary
            if tagInfo or verbose then
                local ok = raf:Seek(resOff, 0)
                local n3, lenBuff
                if ok then n3, lenBuff = raf:Read(4) end
                if ok and n3 == 4 then
                    valLen = ExifTool.Get32u(lenBuff, 0)
                end
                if ok and valLen and valLen < 100000000 then -- arbitrary size limit (100MB)
                    local n4, v = raf:Read(valLen)
                    if n4 == valLen then
                        val = v
                    else
                        ok = false
                    end
                else
                    ok = false
                end
                if not ok then
                    et:Warn(string.format('Error reading %s resource', resType))
                    goto continueRes
                end
            end
            if perlTruthy(verbose) then
                local resName = ''
                local nameLen
                local n5, lb = nil, nil
                if raf:Seek(resNameOff, 0) then n5, lb = raf:Read(1) end
                if n5 == 1 and lb:byte() ~= 0 then
                    nameLen = lb:byte()
                    local n6, nb = raf:Read(nameLen)
                    if n6 == nameLen then resName = nb end
                end
                et:VPrint(0, sprintf("%s resource ID 0x%.4x (offset 0x%.4x, %d bytes, name='%s'):\n",
                    resType, id, resOff, valLen or 0, resName))
            end
            if tagInfo then
                if resType == 'vers' then
                    -- parse the 'vers' resource to get the long version string
                    if valLen > 8 then
                        -- long version string is after short version
                        local p = 7 + val:byte(7)
                        if p < valLen then
                            local vlen = val:byte(p + 1)
                            p = p + 1
                            if p + vlen <= valLen then
                                val = et:Decode(substr(val, p, vlen), 'MacRoman')
                                et:HandleTag(tagTablePtr, tag, val)
                            end
                        end
                    end
                elseif resType == 'sfnt' then
                    -- parse the OTF font block
                    if raf:Seek(resOff + 4, 0) then
                        dirInfo.Base = resOff + 4
                        if not perlTruthy(require('lexiftool.Font').ProcessOTF(et, dirInfo)) then
                            et:Warn('Unrecognized sfnt resource format')
                        end
                        -- assume this is a DFONT file unless processing the rsrc fork
                        if not et.DOC_NUM then et:OverrideFileType('DFONT') end
                    end
                elseif resType == '8BIM' then
                    local ttPtr = et:GetTagTable('lexiftool.Photoshop.Main')
                    et:HandleTag(ttPtr, id, val, {
                        DataPt  = val,
                        DataPos = resOff + 4,
                        Size    = valLen,
                        Start   = 0,
                        Parent  = 'RSRC',
                    })
                elseif resType == 'STR ' and valLen > 1 then
                    -- extract Pascal string
                    local len = val:byte(1)
                    if valLen >= len + 1 then
                        et:HandleTag(tagTablePtr, tag, substr(val, 1, len))
                    end
                elseif resType == 'usro' and valLen > 4 then
                    local len = ExifTool.Get32u(val, 0)
                    if valLen >= len + 4 then
                        et:HandleTag(tagTablePtr, tag, (substr(val, 4, len):gsub('\0.*', '')))
                    end
                elseif resType == 'STR#' and valLen > 2 then
                    -- extract list of strings (ref http://simtech.sourceforge.net/tech/strings.html)
                    local num = ExifTool.Get16u(val, 0)
                    if num & 0xf000 == 0 then -- (ignore special-format STR# resources)
                        local vals = {}
                        local pos = 2
                        for _ = 1, num do
                            if pos >= valLen then break end
                            local len = val:byte(pos + 1)
                            pos = pos + 1
                            if pos + len > valLen then break end
                            vals[#vals + 1] = substr(val, pos, len)
                            pos = pos + len
                        end
                        et:HandleTag(tagTablePtr, tag, vals)
                    end
                elseif resType == 'POST' then
                    -- assume this is a DFONT file unless processing the rsrc fork
                    if not et.DOC_NUM then et:OverrideFileType('DFONT') end
                    et:HandleTag(tagTablePtr, tag, val:sub(3))
                elseif resType == 'TEXT' then
                    et:HandleTag(tagTablePtr, tag, val)
                end
            end
            ::continueRes::
        end
    end
    return 1
end

RSRC.Main.PROCESS_PROC = RSRC.ProcessRSRC

return RSRC
