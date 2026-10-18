--------------------------------------------------------------------------------
-- File:         lexiftool/WritePhotoshop.lua
-- Ported from:  lib/Image/ExifTool/WritePhotoshop.pl
--
-- Description:  Write Photoshop IRB meta information
--
-- Revisions:    12/17/2004 - P. Harvey Created
--
-- Port notes:   All subs of WritePhotoshop.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::Photoshop
--               package and AUTOLOADs it on the first call of one of its
--               subs; this port makes it a module of its own, and
--               Photoshop.lua binds both subs at its predeclaration position
--               to closures that load this file on first use (the
--               WRITE_PROC of Photoshop::Main and ProcessPSD's call
--               included).
--
--               Scalar references: SetResourceName updates the resource
--               name through $_[1] and the value through a ref upstream;
--               here both come back as return values (name, valPt).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local substr = perl.substr
local carray = require('carray')
local length = perl.length
local matches, isMatch = perl.matches, perl.isMatch
local chr = perl.chr
local truthy = perl.truthy
local Get8u, Get16u, Get32u = ExifTool.Get8u, ExifTool.Get16u, ExifTool.Get32u
local Set16u, Set32u = ExifTool.Put16u, ExifTool.Put32u -- (upstream's one-argument Set16u($val)/Set32u($val))
local SetByteOrder = ExifTool.SetByteOrder

local Photoshop = require('lexiftool.Photoshop')    -- (upstream `package Image::ExifTool::Photoshop`)
local WritePhotoshop = {}

--------------------------------------------------------------------------------
-- Strip resource name from value prepare resource name for writing into IRB
-- Inputs: 0) tagInfo ref, 1) resource name (padded pascal string), 2) new value ref
-- Returns: none (updates name and value if necessary)
-- (Lua: returns the -- possibly updated -- name and value)
local function SetResourceName(tagInfo, name, valPt)
    local setName = tagInfo.SetResourceName
    if setName ~= nil then
        -- extract resource name from value
        local m = matches(valPt, [[(?s).*/#(.{0,255})#/$]])
        if m then
            name = m
            -- strip name from value
            valPt = substr(valPt, 0, -4 - length(name))
        elseif perl.str(setName) == '1' then
            return name, valPt     -- use old name
        else
            name = setName
        end
        -- convert to padded pascal string
        name = chr(length(name)) .. name
        if length(name) & 0x01 ~= 0 then name = name .. "\0" end
        -- (upstream `$_[1] = $name;  # return new name`)
    end
    return name, valPt
end

--------------------------------------------------------------------------------
-- Write Photoshop IRB resource
-- Inputs: 0) ExifTool object reference, 1) source dirInfo reference,
--         2) tag table reference
-- Returns: IRB resource data (may be empty if no Photoshop data)
-- Notes: Increments ExifTool CHANGED flag for each tag changed
function WritePhotoshop.WritePhotoshop(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package
    local iptcDigestInfo = Photoshop.iptcDigestInfo
    local dataPt = dirInfo.DataPt
    if not dataPt then
        local emptyData = ''
        dataPt = emptyData
    end
    local start = dirInfo.DirStart or 0
    local dirLen = truthy(dirInfo.DirLen) and dirInfo.DirLen or (length(dataPt) - start)
    local dirEnd = start + dirLen
    local newData = carray.new('char')

    -- make a hash of new tag info, keyed on tagID
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)

    local addDirs, editDirs = Writer.GetAddDirHash(et, tagTablePtr)

    SetByteOrder('MM')     -- Photoshop is always big-endian
--
-- rewrite existing tags in the old directory, deleting ones as necessary
-- (the Photoshop directory entries aren't in any particular order)
--
    -- Format: 0) Type, 4 bytes - '8BIM' (or the rare 'PHUT', 'DCSR', 'AgHg' or 'MeSa')
    --         1) TagID,2 bytes
    --         2) Name, pascal string padded to even no. bytes
    --         3) Size, 4 bytes - N
    --         4) Data, N bytes
    local pos, value, size, tagInfo, tagID
    pos = start
    while pos + 8 < dirEnd do
        -- each entry must be on same even byte boundary as directory start
        if (pos ~ start) & 0x01 ~= 0 then pos = pos + 1 end
        local type_ = substr(dataPt, pos, 4)
        if not isMatch(type_, [[^(8BIM|PHUT|DCSR|AgHg|MeSa)$]]) then
            et:Error('Bad Photoshop IRB resource')
            newData = nil
            break
        end
        tagID = Get16u(dataPt, pos + 4)
        -- get resource block name (pascal string padded to an even # of bytes)
        local namelen = 1 + Get8u(dataPt, pos + 6)
        if namelen & 0x01 ~= 0 then namelen = namelen + 1 end
        if pos + namelen + 10 > dirEnd then
            et:Error('Bad APP13 resource block')
            newData = nil
            break
        end
        local name = substr(dataPt, pos + 6, namelen)
        size = Get32u(dataPt, pos + 6 + namelen)
        pos = pos + namelen + 10
        if size + pos > dirEnd then
            et:Error('Bad APP13 resource data size ' .. size)
            newData = nil
            break
        end
        if newTags[tagID] and type_ == '8BIM' then
            tagInfo = newTags[tagID]
            newTags[tagID] = nil
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            -- check to see if we are overwriting this tag
            value = substr(dataPt, pos, size)
            local isOverwriting = Writer.IsOverwriting(et, nvHash, value)
            -- handle special 'new' and 'old' values for IPTCDigest
            if not truthy(isOverwriting) and tagInfo == iptcDigestInfo then
                local new, old = false, false
                for _, v in ipairs(nvHash.DelValue or {}) do
                    if isMatch(v, [[^new$]]) then new = true end
                    if isMatch(v, [[^old$]]) then old = true end
                end
                if new then
                    if truthy(et.NewIPTCDigest) and
                                          et.NewIPTCDigest == value then isOverwriting = 1 end
                end
                if old then
                    if truthy(et.OldIPTCDigest) and
                                          et.OldIPTCDigest == value then isOverwriting = 1 end
                end
            end
            if truthy(isOverwriting) then
                et:VerboseValue('- Photoshop:' .. tagInfo.Name, value)
                -- handle IPTCDigest specially because we want to write it last
                -- so the new IPTC digest will be known
                if tagInfo == iptcDigestInfo then
                    newTags[tagID] = tagInfo   -- add later
                    value = nil
                else
                    value = et:GetNewValue(nvHash)
                end
                et.CHANGED = (et.CHANGED or 0) + 1
                if value == nil then goto continue end     -- next if tag is being deleted
                -- set resource name if necessary
                name, value = SetResourceName(tagInfo, name, value)
                et:VerboseValue('+ Photoshop:' .. tagInfo.Name, value)
            end
        else
            if type_ == '8BIM' then
                tagInfo = editDirs[tagID]
                if not tagInfo then
                    -- process subdirectory anyway if writable (except EXIF to avoid recursion)
                    -- --> this allows IPTC to be processed if found here in TIFF images
                    -- (but allow EXIF to be written in PSD files if XMP or IPTC tags are
                    --  being written because I have seen cases of XMP in PSD-EXIFInfo-IFD0
                    --  and IPTC in PSD-EXIFInfo-IFD0-IPTC, see forum10768 and forum13198)
                    local tmpInfo = et:GetTagInfo(tagTablePtr, tagID)
                    if tmpInfo and tmpInfo.SubDirectory and
                        (tmpInfo.SubDirectory.TagTable ~= 'lexiftool.Exif.Main' or
                         (et.FILE_TYPE == 'PSD' and (editDirs[0x0404] or editDirs[0x0424])))
                    then
                        local tbl = ExifTool.GetTagTable(nil, tmpInfo.SubDirectory.TagTable)
                        if tbl.WRITE_PROC then tagInfo = tmpInfo end
                    end
                end
            end
            if tagInfo then
                if addDirs[tagID] then addDirs[tagID] = nil end
                local subdirInfo = {
                    DataPt = dataPt,
                    DirStart = pos,
                    DataLen = dirLen,
                    DirLen = size,
                    Parent = dirInfo.DirName,
                }
                local subTable = ExifTool.GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                local writeProc = tagInfo.SubDirectory.WriteProc
                local newValue = Writer.WriteDirectory(et, subdirInfo, subTable, writeProc)
                if newValue ~= nil then
                    if length(newValue) == 0 then goto continue end   -- remove subdirectory entry
                    value = newValue
                    name, value = SetResourceName(tagInfo, name, value)
                else
                    value = substr(dataPt, pos, size) -- rewrite old directory
                end
            else
                value = substr(dataPt, pos, size)
            end
        end
        do
            local newSize = length(value)
            -- write this directory entry
            newData:append(type_ .. Set16u(tagID) .. name .. Set32u(newSize) .. value)
            if newSize & 0x01 ~= 0 then newData:append("\0") end    -- must null pad to even byte
        end
        ::continue::
        pos = pos + size
    end
--
-- write any remaining entries we didn't find in the old directory
-- (might as well write them in numerical tag order)
--
    local tagsLeft = {}
    for k in pairs(newTags) do tagsLeft[#tagsLeft + 1] = k end
    for k in pairs(addDirs) do tagsLeft[#tagsLeft + 1] = k end
    tagsLeft = perl.sort(tagsLeft, function(a, b) return a - b end)
    for _, t in ipairs(tagsLeft) do
        tagID = t
        local name = "\0\0"
        if newTags[tagID] then
            tagInfo = newTags[tagID]
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            value = et:GetNewValue(nvHash)
            -- handle new IPTCDigest value specially
            if tagInfo == iptcDigestInfo and value ~= nil then
                if value == 'new' then
                    value = et.NewIPTCDigest
                elseif value == 'old' then
                    value = et.OldIPTCDigest
                end
                -- (we already know we want to create this tag)
            else
                -- don't add this tag unless specified
                if not truthy(nvHash.IsCreating) then goto nextTag end
            end
            if value == nil then goto nextTag end     -- next if tag is being deleted
            et:VerboseValue('+ Photoshop:' .. tagInfo.Name, value)
            et.CHANGED = (et.CHANGED or 0) + 1
        else
            tagInfo = addDirs[tagID]
            -- create new directory
            local subdirInfo = {
                Parent = dirInfo.DirName,
            }
            local subTable = ExifTool.GetTagTable(nil, tagInfo.SubDirectory.TagTable)
            local writeProc = tagInfo.SubDirectory.WriteProc
            value = Writer.WriteDirectory(et, subdirInfo, subTable, writeProc)
            if not truthy(value) then goto nextTag end
        end
        -- set resource name if necessary
        name, value = SetResourceName(tagInfo, name, value)
        size = length(value)
        -- write the new directory entry
        newData = (newData or carray.new('char')):append('8BIM' .. Set16u(tagID) .. name .. Set32u(size) .. value)
        if size & 0x01 ~= 0 then newData:append("\0") end   -- must null pad to even numbered byte
        et.CHANGED = (et.CHANGED or 0) + 1
        ::nextTag::
    end
    return newData and newData:tostring()
end

-- (the sub above, for Photoshop.lua's AUTOLOAD closures)
WritePhotoshop.SetResourceName = SetResourceName

return WritePhotoshop -- end
