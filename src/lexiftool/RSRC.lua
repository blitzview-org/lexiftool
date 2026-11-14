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
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local substr = perl.substr
local sprintf = perl.sprintf
local unpack = perl.unpack
local ord = perl.ord
local str = perl.str
local subst = perl.subst
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder = ExifTool.SetByteOrder
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u

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
    local hdr, map, buff, i, j, num

    -- allow access with data reference
    if not raf then raf = require('lexiftool.RandomAccess').new(dirInfo.DataPt) end

    -- attempt to validate the format as thoroughly as practical
    num, hdr = raf:Read(30)
    if num ~= 30 then return 0 end
    local datOff, mapOff, datLen, mapLen = unpack('N*', hdr)
    if not raf:Seek(0, 2) then return 0 end
    local fLen = raf:Tell()
    if datOff < 0x10 or datOff + datLen > fLen then return 0 end
    if mapOff < 0x10 or mapOff + mapLen > fLen or mapLen < 30 then return 0 end
    if datOff < mapOff and datOff + datLen > mapOff then return 0 end
    if mapOff < datOff and mapOff + mapLen > datOff then return 0 end

    -- read the resource map
    if not raf:Seek(mapOff, 0) then return 0 end
    num, map = raf:Read(mapLen)
    if num ~= mapLen then return 0 end
    SetByteOrder('MM')
    local typeOff = Get16u(map, 24)
    local nameOff = Get16u(map, 26)
    local numTypes = (Get16u(map, 28) + 1) & 0xffff

    -- validate offsets in the resource map
    if typeOff < 28 or nameOff < 30 then return 0 end

    if not perlTruthy(et.IN_RESOURCE) then et:SetFileType('RSRC') end
    local verbose = et:Options('Verbose')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.RSRC.Main')
    et:VerboseDir('RSRC', numTypes)

    -- parse resource type list
    i = 0
    while i < numTypes do
        local off = typeOff + 2 + 8 * i    -- offset of entry in type list
        if off + 8 > mapLen then break end
        local resType = substr(map,off,4)  -- resource type
        local resNum = Get16u(map,off+4)  -- number of resources - 1
        local refOff = Get16u(map,off+6) + typeOff -- offset to first resource reference
        -- loop through all resources
        j = 0
        while j <= resNum do
            local roff = refOff + 12 * j
            if roff + 12 > mapLen then break end
            -- read only the 24-bit resource data offset
            local id = Get16u(map,roff)
            local resOff = (Get32u(map,roff+4) & 0x00ffffff) + datOff
            local resNameOff = Get16u(map,roff+2) + nameOff + mapOff
            local tag, val, valLen
            local tagInfo = tagTablePtr[resType]
            if tagInfo then
                tag = resType
            else
                tag = sprintf('%s_0x%.4x', resType, id)
                tagInfo = tagTablePtr[tag]
            end
            -- read the resource data if necessary
            if tagInfo or perlTruthy(verbose) then
                local ok = raf:Seek(resOff, 0)
                if ok then num, buff = raf:Read(4); ok = num == 4 end
                if ok then valLen = unpack('N', buff); ok = valLen < 100000000 end -- arbitrary size limit (100MB)
                if ok then num, val = raf:Read(valLen); ok = num == valLen end
                if not ok then
                    et:Warn('Error reading ' .. resType .. ' resource')
                    goto next
                end
            end
            if perlTruthy(verbose) then
                local resName, nameLen
                local ok = raf:Seek(resNameOff, 0)
                if ok then num, buff = raf:Read(1); ok = num ~= 0 end
                if ok then nameLen = ord(buff); ok = nameLen ~= 0 end
                if ok then num, resName = raf:Read(nameLen); ok = num == nameLen end
                if not ok then resName = '' end
                et:VPrint(0,sprintf("%s resource ID 0x%.4x (offset 0x%.4x, " .. str(valLen) .. " bytes, name='%s'):\n",
                    resType, id, resOff, resName))
                et:VerboseDump(val)
            end
            if not tagInfo then goto next end
            if resType == 'vers' then
                -- parse the 'vers' resource to get the long version string
                if valLen <= 8 then goto next end
                -- long version string is after short version
                local p = 7 + Get8u(val, 6)
                if p >= valLen then goto next end
                local vlen = Get8u(val, p)
                p = p + 1
                if p + vlen > valLen then goto next end
                local tagTablePtr = GetTagTable(nil, 'lexiftool.RSRC.Main') -- luacheck: ignore 211 421
                val = et:Decode(substr(val, p, vlen), 'MacRoman')
            elseif resType == 'sfnt' then
                -- parse the OTF font block
                if not raf:Seek(resOff + 4, 0) then goto next end
                dirInfo.Base = resOff + 4
                local Font = require('lexiftool.Font')
                if not perlTruthy(Font.ProcessOTF(et, dirInfo)) then
                    et:Warn('Unrecognized sfnt resource format')
                end
                -- assume this is a DFONT file unless processing the rsrc fork
                if not perlTruthy(et.DOC_NUM) then et:OverrideFileType('DFONT') end
                goto next
            elseif resType == '8BIM' then
                local ttPtr = GetTagTable(nil, 'lexiftool.Photoshop.Main')
                et:HandleTag(ttPtr, id, val, {
                    DataPt  = val,
                    DataPos = resOff + 4,
                    Size    = valLen,
                    Start   = 0,
                    Parent  = 'RSRC',
                })
                goto next
            elseif resType == 'STR ' and valLen > 1 then
                -- extract Pascal string
                local len = ord(val)
                if valLen < len + 1 then goto next end
                val = substr(val, 1, len)
            elseif resType == 'usro' and valLen > 4 then
                local len = unpack('N', val)
                if valLen < len + 4 then goto next end
                val = subst(substr(val, 4, len), [[\0.*]], '', 'g') -- truncate at null
            elseif resType == 'STR#' and valLen > 2 then
                -- extract list of strings (ref http://simtech.sourceforge.net/tech/strings.html)
                local num_ = unpack('n', val)
                if num_ & 0xf000 ~= 0 then goto next end -- (ignore special-format STR# resources)
                local vals = {}
                local pos = 2
                local k = 0
                while k < num_ do
                    if pos >= valLen then break end
                    local len = ord(substr(val, pos, 1))
                    pos = pos + 1
                    if pos + len > valLen then break end
                    vals[#vals + 1] = substr(val, pos, len)
                    pos = pos + len
                    k = k + 1
                end
                val = vals
            elseif resType == 'POST' then
                -- assume this is a DFONT file unless processing the rsrc fork
                if not perlTruthy(et.DOC_NUM) then et:OverrideFileType('DFONT') end
                val = substr(val, 2)
            elseif resType ~= 'TEXT' then
                goto next
            end
            et:HandleTag(tagTablePtr, tag, val)
            ::next::
            j = j + 1
        end
        i = i + 1
    end
    return 1
end

RSRC.Main.PROCESS_PROC = RSRC.ProcessRSRC

return RSRC
