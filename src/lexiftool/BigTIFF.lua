--------------------------------------------------------------------------------
-- File:         lexiftool/BigTIFF.lua
-- Ported from:  lib/Image/ExifTool/BigTIFF.pm
--
-- Description:  Read Big TIFF meta information
--
-- Revisions:    07/03/2007 - P. Harvey Created
--
-- References:   1) http://www.awaresystems.be/imaging/tiff/bigtiff.html
--
-- Port notes:   read subset. BigTIFF has its own standalone IFD walker
--               (ProcessBigIFD: 8-byte entry count, 20-byte IFD entries,
--               8-byte value/offset fields) reusing the ordinary
--               lexiftool.Exif.Main tag table - it does NOT go through
--               Exif.ProcessExif. Complete for reading, including the
--               LargeFileSupport gating of offsets beyond 0x7fffffff and
--               the HTML dump; writing is refused with an error, as
--               upstream.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local isMatch = perl.isMatch
local matches = perl.matches
local split = perl.split
local tr = perl.tr
local perlTruthy = perl.truthy
local str = perl.str
local Get16u = ExifTool.Get16u
local Get64u = ExifTool.Get64u
local ReadValue = ExifTool.ReadValue
local SetByteOrder = ExifTool.SetByteOrder
local GetByteOrder = ExifTool.GetByteOrder
local GetTagTable = ExifTool.GetTagTable

local BigTIFF = {}

local maxOffset = 0x7fffffff -- currently supported maximum data offset/size

--------------------------------------------------------------------------------
-- Process Big IFD directory
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
--------------------------------------------------------------------------------
function BigTIFF.ProcessBigIFD(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local verbose = et.OPTIONS.Verbose
    local htmlDump = et.HTML_DUMP
    local dirName = dirInfo.DirName
    local dirStart = dirInfo.DirStart
    local offName, nextOffName

    if htmlDump then
        verbose = -1  -- mix htmlDump into verbose so we can test for both at once
        offName = dirInfo.OffsetName
    end

    -- loop through IFD chain
    while true do
        if dirStart > maxOffset and not perlTruthy(et:Options('LargeFileSupport')) then
            et:Warn('Huge offsets not supported (LargeFileSupport not set)')
            break
        end
        if not raf:Seek(dirStart, 0) then
            et:Warn("Bad " .. dirName .. " offset")
            return 0
        end
        local dirBuff, index, n
        n, dirBuff = raf:Read(8)
        if n ~= 8 then
            et:Warn("Truncated " .. dirName .. " count")
            return 0
        end
        local numEntries = Get64u(dirBuff, 0)
        if perl.num(verbose) > 0 then et:VerboseDir(dirName, numEntries) end
        local bsize = numEntries * 20
        if bsize > maxOffset then
            et:Warn('Huge directory counts not yet supported')
            break
        end
        local bufPos = raf:Tell()
        n, dirBuff = raf:Read(bsize)
        if n ~= bsize then
            et:Warn("Truncated " .. dirName .. " directory")
            return 0
        end
        local nextIFD
        n, nextIFD = raf:Read(8)
        if n ~= 8 then nextIFD = nil end -- try to read next IFD pointer
        if htmlDump then
            et:HDump(bufPos-8, 8, dirName .. " entries", "Entry count: " .. str(numEntries), nil, offName)
            if nextIFD ~= nil then
                local off = Get64u(nextIFD, 0)
                local tip = sprintf("Offset: 0x%.8x", off)
                local id = offName
                if off ~= 0 then nextOffName, id = Exif.NextOffsetName(et, id) end
                et:HDump(bufPos + 20 * numEntries, 8, "Next IFD", tip, 0, id)
            end
        end
        -- loop through all entries in this BigTIFF IFD
        index = 0
        while index < numEntries do
            local entry = 20 * index
            local tagID = Get16u(dirBuff, entry)
            local format = Get16u(dirBuff, entry+2)
            local count = Get64u(dirBuff, entry+4)
            local formatSize = Exif.formatSize[format]
            if formatSize == nil then
                et:HDump(bufPos+entry,20,"[invalid IFD entry]",
                           "Bad format value: " .. format, 1, offName)
                -- warn unless the IFD was just padded with zeros
                et:Warn(sprintf("Unknown format (" .. format .. ") for " .. dirName .. " tag 0x%x",tagID))
                return 0 -- assume corrupted IFD
            end
            local formatStr = Exif.formatName[format]
            local size = count * formatSize
            local tagInfo = et:GetTagInfo(tagTablePtr, tagID)
            if not (tagInfo ~= nil or perlTruthy(verbose)) then goto next end
            do
                local valuePtr = entry + 12
                local valBuff, valBase, rational, subOffName
                if size > 8 then
                    if size > maxOffset then
                        et:Warn("Can't handle " .. dirName .. " entry " .. index .. " (huge size)")
                        goto next
                    end
                    valuePtr = Get64u(dirBuff, valuePtr)
                    if valuePtr > maxOffset and not perlTruthy(et:Options('LargeFileSupport')) then
                        et:Warn("Can't handle " .. dirName .. " entry " .. index .. " (LargeFileSupport not set)")
                        goto next
                    end
                    if raf:Seek(valuePtr, 0) then n, valBuff = raf:Read(size) else n = nil end
                    if n ~= size then
                        et:Warn("Error reading " .. dirName .. " entry " .. index)
                        goto next
                    end
                    valBase = 0
                else
                    valBuff = substr(dirBuff, valuePtr, size)
                    valBase = bufPos
                end
                if tagInfo ~= nil and not tagInfo then
                    -- GetTagInfo() required the value for a Condition
                    tagInfo = et:GetTagInfo(tagTablePtr, tagID, valBuff)
                end
                local ratPt = {}
                local val = ReadValue(valBuff, 0, formatStr, count, size, ratPt)
                rational = ratPt.rat
                if htmlDump then
                    local tval = val
                    -- show numerator/denominator separately for rational numbers
                    if rational ~= nil then tval = str(tval) .. " (" .. rational .. ")" end
                    local tagName, colName
                    if tagID == 0x927c and dirName == 'ExifIFD' then
                        tagName = 'MakerNotes'
                    elseif tagInfo then
                        tagName = tagInfo.Name
                    else
                        tagName = sprintf("Tag 0x%.4x",tagID)
                    end
                    local dname = sprintf(dirName .. "-%.2d", index)
                    -- build our tool tip
                    local tip = sprintf("Tag ID: 0x%.4x\n", tagID) ..
                              "Format: " .. formatStr .. "[" .. str(count) .. "]\nSize: " .. str(size) .. " bytes\n"
                    if size > 8 then
                        tip = tip .. sprintf("Value offset: 0x%.8x\n", valuePtr)
                        colName = "<span class=H>" .. tagName .. "</span>"
                    else
                        colName = tagName
                    end
                    if length(tval) > 32 then tval = substr(tval,0,28) .. '[...]' end
                    if isMatch(formatStr, [[^(string|undef|binary)]]) then
                        -- translate non-printable characters
                        tval = tr(tval, '\x00-\x1f\x7f-\xff', '.')
                    elseif tagInfo and ExifTool.IsInt(tval) then
                        if perlTruthy(tagInfo.IsOffset) then
                            tval = sprintf('0x%.4x', tval)
                        elseif perlTruthy(tagInfo.PrintHex) then
                            tval = sprintf('0x%x', tval)
                        end
                    end
                    tip = tip .. "Value: " .. str(tval)
                    local id, sid
                    if tagInfo and tagInfo.SubIFD then
                        subOffName, id, sid = Exif.NextOffsetName(et, offName)
                    else
                        id = offName
                    end
                    et:HDump(entry+bufPos, 20, dname .. " " .. colName, tip, 1, id)
                    if size > 8 then
                        -- add value data block
                        local flg = (tagInfo and tagInfo.SubDirectory and tagInfo.MakerNotes) and 4 or 0
                        et:HDump(valuePtr,size,tagName .. " value",'SAME', flg, sid)
                    end
                end
                if tagInfo and tagInfo.SubIFD then
                    -- process all SubIFD's as BigTIFF
                    if perl.num(verbose) > 0 then et:VerboseInfo(tagID, tagInfo, {
                        Table   = tagTablePtr,
                        Index   = index,
                        Value   = val,
                        DataPt  = valBuff,
                        DataPos = valBase + valuePtr,
                        Start   = 0,
                        Size    = size,
                        Format  = formatStr,
                        Count   = count,
                    }) end
                    local offsets = split(' ', val)
                    local i = 0
                    while i < #offsets do
                        local subdirName = tagInfo.Name
                        if i ~= 0 then subdirName = subdirName .. i end
                        local subdirInfo = {
                            RAF        = raf,
                            DataPos    = 0,
                            DirStart   = perl.num(offsets[i+1]),
                            DirName    = subdirName,
                            Parent     = dirName,
                            OffsetName = subOffName,
                        }
                        et:ProcessDirectory(subdirInfo, tagTablePtr, BigTIFF.ProcessBigIFD)
                        i = i + 1
                    end
                else
                    local tagKey = et:HandleTag(tagTablePtr, tagID, val, {
                        Index   = index,
                        DataPt  = valBuff,
                        DataPos = valBase + valuePtr,
                        Start   = 0,
                        Size    = size,
                        Format  = formatStr,
                        TagInfo = tagInfo,
                        RAF     = raf,
                    })
                    if tagKey then et:SetGroup(tagKey, dirName) end
                end
            end
            ::next::
            index = index + 1
        end
        local m1, m2 = matches(dirName, [[^(IFD|SubIFD)(\d*)$]])
        if not m1 then break end
        dirName = m1 .. ((perlTruthy(m2) and perl.num(m2) or 0) + 1)
        if nextIFD == nil then et:Warn("Bad " .. dirName .. " pointer"); return 0 end
        dirStart = Get64u(nextIFD, 0)
        if dirStart == 0 then break end
        offName = nextOffName
        -- protect against infinite loop
        if et.PROCESSED[dirStart] then
            et:Warn(dirName .. " pointer references previous " .. et.PROCESSED[dirStart] .. " directory")
            break
        else
            et.PROCESSED[dirStart] = dirName
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract meta information from a BigTIFF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid BigTIFF image
--------------------------------------------------------------------------------
function BigTIFF.ProcessBTF(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, n

    n, buff = raf:Read(16)
    if n ~= 16 then return 0 end
    if not isMatch(buff, [[^(MM\0\x2b\0\x08\0\0|II\x2b\0\x08\0\0\0)]]) then return 0 end
    if dirInfo.OutFile then
        et:Error('ExifTool does not support writing of BigTIFF images')
        return 1
    end
    et:SetFileType('BTF') -- set the FileType tag
    SetByteOrder(substr(buff, 0, 2))
    local offset = Get64u(buff, 8)
    if et.HTML_DUMP then
        local o = (GetByteOrder() == 'II') and 'Little' or 'Big'
        et:HDump(0, 8, "BigTIFF header", "Byte order: " .. o .. " endian", 0)
        et:HDump(8, 8, "IFD0 pointer", sprintf("Offset: 0x%.8x",offset), 0)
    end
    local dirInfo2 = {
        RAF      = raf,
        DataPos  = 0,
        DirStart = offset,
        DirName  = 'IFD0',
        Parent   = 'BigTIFF',
    }
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Exif.Main')
    et:ProcessDirectory(dirInfo2, tagTablePtr, BigTIFF.ProcessBigIFD)
    return 1
end

return BigTIFF
