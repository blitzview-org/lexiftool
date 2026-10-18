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
--               Exif.ProcessExif. Deferred: LargeFileSupport option gating
--               (huge offsets/counts beyond 0x7fffffff - not exercised by
--               the small vendored test image), HTML dump output,
--               the write path (`OutFile` upstream errors out on write
--               anyway - BigTIFF write was never supported).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local Exif = require('lexiftool.Exif')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local str = perl.str

local BigTIFF = {}

local maxOffset = 0x7fffffff -- currently supported maximum data offset/size

--------------------------------------------------------------------------------
-- Process Big IFD directory (upstream ProcessBigIFD)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
--------------------------------------------------------------------------------
function BigTIFF.ProcessBigIFD(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local dirName = dirInfo.DirName
    local dirStart = dirInfo.DirStart

    -- loop through IFD chain
    while true do
        if dirStart > maxOffset and not et:Options('LargeFileSupport') then
            et:Warn('Huge offsets not supported (LargeFileSupport not set)')
            break
        end
        if not raf:Seek(dirStart, 0) then
            et:Warn('Bad ' .. dirName .. ' offset')
            return 0
        end
        local n, dirBuff = raf:Read(8)
        if n ~= 8 then
            et:Warn('Truncated ' .. dirName .. ' count')
            return 0
        end
        local numEntries = ExifTool.Get64u(dirBuff, 0)
        if (et:Options('Verbose') or 0) > 0 then et:VerboseDir(dirName, numEntries) end
        local bsize = numEntries * 20
        if bsize > maxOffset then
            et:Warn('Huge directory counts not yet supported')
            break
        end
        local bufPos = raf:Tell()
        local n2, dirBuff2 = raf:Read(bsize)
        if n2 ~= bsize then
            et:Warn('Truncated ' .. dirName .. ' directory')
            return 0
        end
        dirBuff = dirBuff2
        local n3, nextIFD = raf:Read(8)
        if n3 ~= 8 then nextIFD = nil end -- try to read next IFD pointer

        -- loop through all entries in this BigTIFF IFD
        for index = 0, numEntries - 1 do
            local entry = 20 * index
            local tagID = ExifTool.Get16u(dirBuff, entry)
            local format = ExifTool.Get16u(dirBuff, entry + 2)
            local count = ExifTool.Get64u(dirBuff, entry + 4)
            local formatStr = Exif.formatName[format]
            local formatSize = formatStr and ExifTool.FormatSize(formatStr)
            if not formatSize then
                et:Warn(sprintf('Unknown format (%d) for %s tag 0x%x', format, dirName, tagID))
                return 0 -- assume corrupted IFD
            end
            local size = count * formatSize
            local tagInfo = et:GetTagInfo(tagTablePtr, tagID)
            if tagInfo ~= nil or perl.truthy(et.OPTIONS.Verbose) then
                local valuePtr = entry + 12
                local valBuff, valBase
                if size > 8 then
                    if size > maxOffset then
                        et:Warn(string.format("Can't handle %s entry %d (huge size)", dirName, index))
                        goto continueEntry
                    end
                    valuePtr = ExifTool.Get64u(dirBuff, valuePtr)
                    if valuePtr > maxOffset and not et:Options('LargeFileSupport') then
                        et:Warn(string.format("Can't handle %s entry %d (LargeFileSupport not set)", dirName, index))
                        goto continueEntry
                    end
                    if not raf:Seek(valuePtr, 0) then
                        et:Warn(string.format('Error reading %s entry %d', dirName, index))
                        goto continueEntry
                    end
                    local nv, vb = raf:Read(size)
                    if nv ~= size then
                        et:Warn(string.format('Error reading %s entry %d', dirName, index))
                        goto continueEntry
                    end
                    valBuff = vb
                    valBase = 0
                else
                    valBuff = substr(dirBuff, valuePtr, size)
                    valBase = bufPos
                end
                if tagInfo == nil then
                    -- GetTagInfo() may need the value for a Condition
                    tagInfo = et:GetTagInfo(tagTablePtr, tagID, valBuff)
                end
                local val = ExifTool.ReadValue(valBuff, 0, formatStr, count, size)
                if tagInfo and tagInfo.SubIFD then
                    -- process all SubIFD's as BigTIFF
                    local offsets = {}
                    for tok in str(val):gmatch('[^ \t\n\r\f\v]+') do offsets[#offsets + 1] = tonumber(tok) end
                    for i = 1, #offsets do
                        local subdirName = tagInfo.Name
                        if i > 1 then subdirName = subdirName .. (i - 1) end
                        local subdirInfo = {
                            RAF = raf,
                            DataPos = 0,
                            DirStart = offsets[i],
                            DirName = subdirName,
                            Parent = dirName,
                        }
                        et:ProcessDirectory(subdirInfo, tagTablePtr, BigTIFF.ProcessBigIFD)
                    end
                elseif tagInfo then
                    local tagKey = et:HandleTag(tagTablePtr, tagID, val, {
                        Index = index,
                        DataPt = valBuff,
                        DataPos = valBase + valuePtr,
                        Start = 0,
                        Size = size,
                        Format = formatStr,
                        TagInfo = tagInfo,
                        RAF = raf,
                    })
                    if tagKey then et:SetGroup(tagKey, dirName) end
                end
            end
            ::continueEntry::
        end
        -- upstream: `$dirName =~ /^(IFD|SubIFD)(\d*)$/` (PCRE2 via the facade
        -- -- Lua patterns have no alternation)
        local nextName, nextNum = perl.matches(dirName, '^(IFD|SubIFD)(\\d*)$')
        if not nextName then break end
        dirName = nextName .. ((tonumber(nextNum) or 0) + 1)
        if not nextIFD then
            et:Warn('Bad ' .. dirName .. ' pointer')
            return 0
        end
        dirStart = ExifTool.Get64u(nextIFD, 0)
        if dirStart == 0 then break end
        -- protect against infinite loop
        if et.PROCESSED[dirStart] then
            et:Warn(dirName .. ' pointer references previous ' .. et.PROCESSED[dirStart] .. ' directory')
            break
        else
            et.PROCESSED[dirStart] = dirName
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract meta information from a BigTIFF image (upstream ProcessBTF)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid BigTIFF image
--------------------------------------------------------------------------------
function BigTIFF.ProcessBTF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(16)
    if n ~= 16 then return 0 end
    if not (buff:sub(1, 8) == 'MM\0\43\0\8\0\0' or buff:sub(1, 8) == 'II\43\0\8\0\0\0') then
        return 0
    end
    if dirInfo.OutFile then
        et:Error('ExifTool does not support writing of BigTIFF images')
        return 1
    end
    et:SetFileType('BTF') -- set the FileType tag
    ExifTool.SetByteOrder(substr(buff, 0, 2))
    local offset = ExifTool.Get64u(buff, 8)
    local subDirInfo = {
        RAF = raf,
        DataPos = 0,
        DirStart = offset,
        DirName = 'IFD0',
        Parent = 'BigTIFF',
    }
    local tagTablePtr = et:GetTagTable('lexiftool.Exif.Main')
    et:ProcessDirectory(subDirInfo, tagTablePtr, BigTIFF.ProcessBigIFD)
    return 1
end

return BigTIFF
