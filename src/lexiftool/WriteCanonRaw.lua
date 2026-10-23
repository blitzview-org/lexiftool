--------------------------------------------------------------------------------
-- File:         lexiftool/WriteCanonRaw.lua
-- Ported from:  lib/Image/ExifTool/WriteCanonRaw.pl
--
-- Description:  Write Canon RAW (CRW and CR2) meta information
--
-- Revisions:    01/25/2005 - P. Harvey Created
--               09/16/2010 - PH Added ability to write XMP in CRW images
--
-- Port notes:   All subs of WriteCanonRaw.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::CanonRaw package
--               and AUTOLOADs it on the first call of one of its subs; this
--               port makes it a module of its own, and CanonRaw.lua binds
--               every sub at its predeclaration position to a closure that
--               loads this file on first use (CanonRaw.WriteCRW,
--               CanonRaw.WriteCR2, CanonRaw.BuildMakerNotes, ... keep working
--               for all callers, DNG.lua and the core included).
--
--               Scalar references: BuildMakerNotes gets the value string
--               itself; CheckCanonRaw is a CHECK_PROC and follows the port's
--               convention for those (value in; error and the possibly
--               changed value out).  `Set32u($val, \$header, $pos)` is
--               the in-place Set32u on a carray header.  A memory output
--               (`\$buff`, `\$outbuff`) is the port's scalar box
--               { value = <carray> }, which Write() and AddNewTrailers() take.
--               `keys %$newTags` is perl.keys, so @addTags has no defined
--               order -- as upstream, which does not sort it either.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `package Image::ExifTool::CanonRaw`, Image::ExifTool's subs)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local length = perl.length
local substr = perl.substr
local carray = require('carray')
local isMatch = perl.isMatch
local sprintf = perl.sprintf
local keys, sort = perl.keys, perl.sort
local int = perl.int
local truthy = perl.truthy
local warn = perl.warn
local Get16u, Get32u = ExifTool.Get16u, ExifTool.Get32u
local Set16u = ExifTool.Put16u  -- (upstream's one-argument Set16u($val))
local Set32u = ExifTool.Put32u  -- (upstream's one-argument Set32u($val))
local GetByteOrder, SetByteOrder = ExifTool.GetByteOrder, ExifTool.SetByteOrder
local ReadValue = ExifTool.ReadValue
local WriteValue = Writer.WriteValue
local GetTagTable = ExifTool.GetTagTable
local Write = Writer.Write

local CanonRaw = require('lexiftool.CanonRaw')  -- (upstream `package Image::ExifTool::CanonRaw`)
local crwTagFormat = CanonRaw.crwTagFormat      -- (upstream `use vars qw(%crwTagFormat)`)
local WriteCanonRaw = {}

-- map for adding directories to CRW
local crwMap = {
    XMP      = 'CanonVRD',
    CanonVRD = 'Trailer',
}

-- mappings to from RAW tagID to MakerNotes tagID
-- (Note: upper two bits of RawTagID are zero)
local mapRawTag = {
  -- RawTagID => Canon TagID
    [0x080b] = 0x07, -- CanonFirmwareVersion
    [0x0810] = 0x09, -- OwnerName
    [0x0815] = 0x06, -- CanonImageType
    [0x1028] = 0x03, -- (unknown if no tag name specified)
    [0x1029] = 0x02, -- FocalLength
    [0x102a] = 0x04, -- CanonShotInfo
    [0x102d] = 0x01, -- CanonCameraSettings
    [0x1033] = 0x0f, -- CanonCustomFunctions (only verified for 10D)
    [0x1038] = 0x12, -- CanonAFInfo
    [0x1039] = 0x13,
    [0x1093] = 0x93,
    [0x10a8] = 0xa8,
    [0x10a9] = 0xa9, -- WhiteBalanceTable
    [0x10aa] = 0xaa,
    [0x10ae] = 0xae, -- ColorTemperature
    [0x10b4] = 0xb4, -- ColorSpace
    [0x10b5] = 0xb5,
    [0x10c0] = 0xc0,
    [0x10c1] = 0xc1,
    [0x180b] = 0x0c, -- SerialNumber
    [0x1817] = 0x08, -- FileNumber
    [0x1834] = 0x10,
    [0x183b] = 0x15,
}
-- translation from Rotation to Orientation values
local mapRotation = {
    [0] = 1,
    [90] = 6,
    [180] = 3,
    [270] = 8,
}


--------------------------------------------------------------------------------
-- Initialize buffers for building MakerNotes from RAW data
-- Inputs: 0) ExifTool object reference
local function InitMakerNotes(et)
    et.MAKER_NOTE_INFO = {
        Entries = { },     -- directory entries keyed by tagID
        ValBuff = carray.new('char'):append("\0\0\0\0"), -- value data buffer (start with zero nextIFD pointer)
        FixupTags = { },   -- flags for tags with data in value buffer
    }
end

--------------------------------------------------------------------------------
-- Build maker notes from CanonRaw information
-- Inputs: 0) ExifTool object reference, 1) raw tag ID, 2) reference to tagInfo
--         3) reference to value, 4) format name, 5) count
-- Notes: This will build the directory in the order the tags are found in the CRW
-- file, which isn't sequential (but Canon's version isn't sequential either...)
local function BuildMakerNotes(et, rawTag, tagInfo, valuePt, formName, count)
    local tagID = mapRawTag[rawTag]
    if not truthy(tagID) then return end
    if not truthy(formName) then warn(sprintf("No format for tag 0x%x!\n", rawTag)) return end
    -- special case: ignore user comment because it gets saved in EXIF
    -- (and has the same raw tagID as CanonFileDescription)
    if tagInfo and tagInfo.Name == 'UserComment' then return end
    local Exif = require('lexiftool.Exif')
    local format = Exif.formatNumber[formName]
    local fsiz = Exif.formatSize[format]
    local size = length(valuePt)
    local value
    if truthy(count) and size ~= count * fsiz then
        if size < count * fsiz then
            warn(sprintf("Value too short for raw tag 0x%x\n", rawTag))
            return
        end
        -- shorten value appropriately
        size = count * fsiz
        value = substr(valuePt, 0, size)
    else
        count = size / fsiz
        value = valuePt
    end
    local offsetVal
    local makerInfo = et.MAKER_NOTE_INFO
    if size > 4 then
        local len = length(makerInfo.ValBuff)
        offsetVal = Set32u(len)
        makerInfo.ValBuff:append(value)
        -- pad to an even number of bytes
        if size & 0x01 ~= 0 then makerInfo.ValBuff:append("\0") end
        -- set flag indicating that this tag needs a fixup
        makerInfo.FixupTags[tagID] = 1
    else
        offsetVal = value
        if size < 4 then offsetVal = offsetVal .. ("\0"):rep(4 - size) end
    end
    makerInfo.Entries[tagID] = Set16u(tagID) .. Set16u(format) ..
                               Set32u(int(count)) .. offsetVal
end

--------------------------------------------------------------------------------
-- Finish building and save MakerNotes
-- Inputs: 0) ExifTool object reference
local function SaveMakerNotes(et)
    -- save maker notes
    local makerInfo = et.MAKER_NOTE_INFO
    et.MAKER_NOTE_INFO = nil
    local dirEntries = makerInfo.Entries
    local numEntries = #keys(dirEntries)
    local fixup = require('lexiftool.Fixup').new()
    if not truthy(numEntries) then return end
    -- build the MakerNotes directory
    local makerNotes = carray.new('char'):append(Set16u(numEntries))
    -- write the entries in proper tag order (even though Canon doesn't do this...)
    for _, tagID in ipairs(sort(keys(dirEntries), function(a, b) return a - b end)) do
        makerNotes:append(dirEntries[tagID])
        if makerInfo.FixupTags[tagID] then
            -- add fixup for this pointer
            fixup:AddFixup(length(makerNotes) - 4)
        end
    end
    -- save position of maker notes for pointer fixups
    fixup.Shift = fixup.Shift + length(makerNotes)
    et.MAKER_NOTE_BYTE_ORDER = GetByteOrder()
    -- add value data
    makerNotes:append(makerInfo.ValBuff)
    makerNotes = makerNotes:tostring()  -- (GetTagInfo and FoundTag take the value)
    -- get MakerNotes tag info
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Exif.Main')
    local tagInfo = et:GetTagInfo(tagTablePtr, 0x927c, makerNotes)
    -- save the MakerNotes
    local key = et:FoundTag(tagInfo, makerNotes)
    et.TAG_EXTRA[key] = et.TAG_EXTRA[key] or { }
    et.TAG_EXTRA[key].Fixup = fixup
    -- save the garbage collection some work later
    makerInfo.Entries = nil
    makerInfo.ValBuff = nil
    makerInfo.FixupTags = nil
    -- also generate Orientation tag since Rotation isn't transferred from RAW info
    local rotation = et:GetValue('Rotation', 'ValueConv')
    if rotation ~= nil and mapRotation[tonumber(rotation)] ~= nil then
        tagInfo = et:GetTagInfo(tagTablePtr, 0x112)
        et:FoundTag(tagInfo, mapRotation[tonumber(rotation)])
    end
end

--------------------------------------------------------------------------------
-- Check CanonRaw information
-- Inputs: 0) ExifTool object reference, 1) tagInfo hash reference,
--         2) raw value reference
-- Returns: error string or undef (and may change value) on success
local function CheckCanonRaw(et, tagInfo, valPtr)
    local tagName = tagInfo.Name
    if tagName == 'JpgFromRaw' or tagName == 'ThumbnailImage' then
        if not (isMatch(valPtr, [[^\xff\xd8]]) or truthy(et:Options('IgnoreMinorErrors'))) then
            return '[Minor] Not a valid image'
        end
    else
        local format = tagInfo.Format
        local count = tagInfo.Count
        if not truthy(format) then
            local tagType = (tagInfo.TagID >> 8) & 0x38
            format = crwTagFormat[tagType]
        end
        if truthy(format) then return Writer.CheckValue(valPtr, format, count) end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Write CR2 file
-- Inputs: 0) ExifTool ref, 1) dirInfo reference (must have read first 16 bytes)
--         2) tag table reference
-- Returns: true on success
local function WriteCR2(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    if not dataPt then return 0 end
    local outfile = dirInfo.OutFile
    if not outfile then return 0 end
    if not dirInfo.RAF then return 0 end

    -- check CR2 signature
    if not isMatch(dataPt, [[(?s)^.{8}CR\x02\0]]) then
        local msg, minor
        if isMatch(dataPt, [[(?s)^.{8}CR]]) then
            msg = 'Unsupported Canon RAW file. May cause problems if rewritten'
            minor = 1
        elseif isMatch(dataPt, [[(?s)^.{8}\xba\xb0\xac\xbb]]) then
            msg = 'Can not currently write Canon 1D RAW images'
        else
            msg = 'Unrecognized Canon RAW file'
        end
        if truthy(et:Error(msg, minor)) then return 0 end
    end

    -- CR2 has a 16-byte header
    dirInfo.NewDataPos = 16
    local newData = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
    if newData == nil then return 0 end
    if not truthy(dirInfo.LastIFD) then
        et:Error("CR2 image IFD may not be deleted")
        return 0
    end

    if truthy(length(newData)) then
        -- build 16 byte header for Canon RAW file
        local header = carray.new('char'):append(substr(dataPt, 0, 16))
        -- set IFD0 pointer (may not be 16 if edited by PhotoMechanic)
        ExifTool.Set32u(header, 4, 16)
        -- last 4 bytes of header is pointer to last IFD
        ExifTool.Set32u(header, 12, dirInfo.LastIFD)
        if not Write(outfile, header, newData) then return 0 end
        newData = nil -- luacheck: ignore 311 -- free memory

        -- copy over image data now if necessary
        if type(dirInfo.ImageData) == 'table' then
            if not truthy(Writer.CopyImageData(et, dirInfo.ImageData, outfile)) then return 0 end
            dirInfo.ImageData = nil
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Write CanonRaw (CRW) information
-- Inputs: 0) ExifTool object reference, 1) source dirInfo reference,
--         2) tag table reference
-- Returns: true on success
-- Notes: Increments ExifTool CHANGED flag for each tag changed This routine is
-- different from all of the other write routines because Canon RAW files are
-- designed well!  So it isn't necessary to buffer the data in memory before
-- writing it out.  Therefore this routine doesn't return the directory data as
-- the rest of the Write routines do.  Instead, it writes to the dirInfo
-- OutFile on the fly --> much faster, efficient, and less demanding on memory!
function WriteCanonRaw.WriteCanonRaw(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package
    local blockStart = dirInfo.DirStart
    local blockSize = dirInfo.DirLen
    local raf = dirInfo.RAF
    if not raf then return 0 end
    local outfile = dirInfo.OutFile
    if not outfile then return 0 end
    local outPos = dirInfo.OutPos
    if not truthy(outPos) then return 0 end
    local outBase = outPos
    local verbose = perl.num(et:Options('Verbose'))
    local out = et:Options('TextOut') or io.stdout  -- (unset option: upstream's default \*STDOUT)
    local buff, n

    -- 4 bytes at end of block give directory position within block
    if not raf:Seek(blockStart+blockSize-4, 0) then return 0 end
    n, buff = raf:Read(4)
    if n ~= 4 then return 0 end
    local dirOffset = Get32u(buff,0) + blockStart
    -- avoid infinite recursion
    if not et.ProcessedCanonRaw then et.ProcessedCanonRaw = { } end
    if et.ProcessedCanonRaw[dirOffset] then
        et:Error("Double-referenced " .. perl.str(dirInfo.DirName) .. " directory")
        return 0
    end
    et.ProcessedCanonRaw[dirOffset] = 1
    if not raf:Seek(dirOffset, 0) then return 0 end
    n, buff = raf:Read(2)
    if n ~= 2 then return 0 end
    local entries = Get16u(buff,0)             -- get number of entries in directory
    -- read the directory (10 bytes per entry)
    n, buff = raf:Read(10 * entries)
    if n ~= 10 * entries then return 0 end
    local newDir = carray.new('char')

    -- get hash of new information keyed by tagID
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)

    -- generate list of tags to add or delete (currently, we only allow JpgFromRaw
    -- and ThumbnailImage, to be added or deleted from the root CanonRaw directory)
    local addTags, delTag = { }, { }
    if dirInfo.Nesting == 0 then
        for _, tagID in ipairs(keys(newTags)) do
            local permanent = newTags[tagID].Permanent
            if permanent ~= nil and not truthy(permanent) then addTags[#addTags + 1] = tagID end
        end
    end

    local index = 0
    while true do
        local pt, tag, size, valuePtr, ptr, value
        if index<entries then
            pt = 10 * index
            tag = Get16u(buff, pt)
            size = Get32u(buff, pt+2)
            valuePtr = Get32u(buff, pt+6)
            ptr = valuePtr + blockStart        -- all pointers relative to block start
        end
        -- add any required new tags
        -- NOTE: can't currently add tags where value is stored in directory
        if #addTags > 0 and (tag == nil or tag >= addTags[1]) then
            local addTag = table.remove(addTags, 1)
            local tagInfo = newTags[addTag]
            local newVal = et:GetNewValue(tagInfo)
            if newVal ~= nil then
                -- pad value to an even length (Canon ImageBrowser and ZoomBrowser
                -- version 6.1.1 have problems with odd-sized embedded JPEG images
                -- even if the value is padded to maintain alignment, so do this
                -- before calculating the size for the directory entry)
                if length(newVal) & 0x01 ~= 0 then newVal = newVal .. "\0" end
                -- add new directory entry
                newDir:append(Set16u(addTag) .. Set32u(length(newVal)) ..
                           Set32u(outPos - outBase))
                -- write new value data
                if not Write(outfile, newVal) then return 0 end
                outPos = outPos + length(newVal)     -- update current position
                if verbose > 1 then out:write("    + CanonRaw:" .. tagInfo.Name .. "\n") end
                et.CHANGED = (et.CHANGED or 0) + 1
            end
            -- set flag to delete this tag if found later
            delTag[addTag] = 1
        end
        if tag == nil then break end           -- all done if no more directory entries
        if tag & 0x8000 ~= 0 then return 0 end -- top bit should not be set
        local tagID = tag & 0x3fff          -- get tag ID
        local tagType = (tag >> 8) & 0x38   -- get tag type
        local valueInDir = (tag & 0x4000)   -- flag for value in directory

        local tagInfo = et:GetTagInfo(tagTablePtr,tagID)
        local format = crwTagFormat[tagType]
        local count, subdir
        if tagInfo then
            subdir = tagInfo.SubDirectory
            if tagInfo.Format then format = tagInfo.Format end
            count = tagInfo.Count
        end
        if valueInDir ~= 0 then
            size = 8
            value = substr(buff, pt+2, size)
            -- set count to 1 by default for normal values in directory
            if count == nil and format and
                          format ~= 'string' and not subdir then count = 1 end
        else
            if tagType==0x28 or tagType==0x30 then
                -- this type of tag specifies a raw subdirectory
                local name
                if tagInfo then name = tagInfo.Name end
                if not truthy(name) then name = sprintf("CanonRaw_0x%.4x", tagID) end
                local subdirInfo = {
                    DirName  = name,
                    DataLen  = 0,
                    DirStart = ptr,
                    DirLen   = size,
                    Nesting  = dirInfo.Nesting + 1,
                    RAF      = raf,
                    Parent   = dirInfo.DirName,
                    OutFile  = outfile,
                    OutPos   = outPos,
                }
                local result = Writer.WriteDirectory(et, subdirInfo, tagTablePtr)
                if not truthy(result) then return 0 end
                -- set size and pointer for this new directory
                size = subdirInfo.OutPos - outPos
                valuePtr = outPos - outBase
                outPos = subdirInfo.OutPos
            else
                -- verify that the value data is within this block
                if valuePtr + size > blockSize then return 0 end
                -- read value from file
                if not raf:Seek(ptr, 0) then return 0 end
                n, value = raf:Read(size)
                if n ~= size then return 0 end
            end
        end
        -- set count from tagInfo count if necessary
        if format and not truthy(count) then
            -- set count according to format and size
            local Exif = require('lexiftool.Exif')
            local fnum = Exif.formatNumber[format]
            local fsiz = Exif.formatSize[fnum]
            count = int(size / fsiz)
        end
        -- edit subdirectory if necessary
        if tagInfo then
            if subdir and subdir.TagTable then
                local name = tagInfo.Name
                local newTagTable = GetTagTable(nil, subdir.TagTable)
                if not newTagTable then return 0 end
                local subdirStart = 0
                --### eval Start ()
                if subdir.Start then subdirStart = subdir.Start(et) end
                local dirData = value
                local subdirInfo = {
                    Name     = name,
                    DataPt   = dirData,
                    DataLen  = size,
                    DirStart = subdirStart,
                    DirLen   = size - subdirStart,
                    Nesting  = dirInfo.Nesting + 1,
                    RAF      = raf,
                    Parent   = dirInfo.DirName,
                }
                --### eval Validate ($dirData, $subdirStart, $size)
                if subdir.Validate ~= nil and not subdir.Validate(et, nil, dirData, subdirStart, size) then
                    et:Warn("Invalid " .. name .. " data")
                else
                    subdir = Writer.WriteDirectory(et, subdirInfo, newTagTable)
                    if subdir ~= nil and truthy(length(subdir)) then
                        if truthy(subdirStart) then
                            -- add header before data directory
                            value = substr(value, 0, subdirStart) .. subdir
                        else
                            value = subdir
                        end
                    end
                end
            elseif newTags[tagID] then
                if delTag[tagID] then
                    if verbose > 1 then out:write("    - CanonRaw:" .. tagInfo.Name .. "\n") end
                    et.CHANGED = (et.CHANGED or 0) + 1
                    goto next   -- next since we already added this tag
                end
                local oldVal
                if format then
                    oldVal = ReadValue(value, 0, format, count, size)
                else
                    oldVal = value
                end
                local nvHash = Writer.GetNewValueHash(et, tagInfo)
                if truthy(Writer.IsOverwriting(et, nvHash, oldVal)) then
                    local newVal = Writer.GetNewValue(et, nvHash)
                    local verboseVal
                    if verbose > 1 then verboseVal = newVal end
                    -- convert to specified format if necessary
                    if newVal ~= nil and format then
                        newVal = WriteValue(newVal, format, count)
                    end
                    if newVal ~= nil then
                        value = newVal
                        et.CHANGED = (et.CHANGED or 0) + 1
                        et:VerboseValue("- CanonRaw:" .. tagInfo.Name, oldVal)
                        et:VerboseValue("+ CanonRaw:" .. tagInfo.Name, verboseVal)
                    end
                end
            end
        end
        if valueInDir ~= 0 then
            local len = length(value)
            if len < 8 then
                -- pad with original garbage in case it contained something useful
                value = value .. substr(buff, pt+2+8-len, 8-len)
            elseif len > 8 then   -- this shouldn't happen
                warn("Value too long! -- truncated\n")
                value = substr(value, 0, 8)
            end
            -- create new directory entry
            newDir:append(Set16u(tag) .. value)
            goto next   -- all done this entry
        end
        if value ~= nil then
            -- don't allow value to change length unless Writable is 'resize'
            local writable = tagInfo and tagInfo.Writable
            local diff = length(value) - size
            if diff ~= 0 then
                if truthy(writable) and writable == 'resize' then
                    size = size + diff -- allow size to change
                elseif diff > 0 then
                    value = value .. ("\0"):rep(diff)
                else
                    value = substr(value, 0, size)
                end
            end
            -- pad value if necessary to align on even-byte boundary (as per CIFF spec)
            if size & 0x01 ~= 0 then value = value .. "\0" end
            valuePtr = outPos - outBase
            -- write out value data
            if not Write(outfile, value) then return 0 end
            outPos = outPos + length(value)  -- update current position in outfile
        end
        -- create new directory entry
        newDir:append(Set16u(tag) .. Set32u(size) .. Set32u(valuePtr))
        ::next::
        index = index + 1
    end
    -- add the directory counts and offset to the directory start,
    entries = length(newDir) // 10
    newDir = carray.new('char'):append(Set16u(entries), newDir, Set32u(outPos - outBase))
    -- write directory data
    if not Write(outfile, newDir) then return 0 end

    -- update current output file position in dirInfo
    dirInfo.OutPos = outPos + length(newDir)
    -- save outfile directory start (needed for rewriting VRD trailer)
    dirInfo.OutDirStart = outPos - outBase

    return 1
end

--------------------------------------------------------------------------------
-- write Canon RAW (CRW) file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid CRW file,
--          or -1 if a write error occurred
local function WriteCRW(et, dirInfo)
    local outfile = dirInfo.OutFile
    local raf = dirInfo.RAF
    local rtnVal = 0
    local buff, err, sig, n

    n, buff = raf:Read(2)
    if n ~= 2                  then return 0 end
    if not SetByteOrder(buff)  then return 0 end
    n, buff = raf:Read(4)
    if n ~= 4                  then return 0 end
    n, sig = raf:Read(8)
    if n ~= 8                  then return 0 end   -- get file signature
    local isSig, type = isMatch(sig, [[^HEAP(CCDR|JPGM)]])
    if not isSig               then return 0 end   -- validate signature
    local hlen = Get32u(buff, 0)   -- get header length

    if truthy(et.DEL_GROUP.MakerNotes) then
        if type == 'CCDR' then
            et:Error("Can't delete MakerNotes from CRW")
            return 0
        else
            et.CHANGED = (et.CHANGED or 0) + 1
            return 1
        end
    end
    -- make XMP the preferred group for CRW files
    if et.FILE_TYPE == 'CRW' then
        Writer.InitWriteDirs(et, crwMap, 'XMP')
    end

    -- write header
    if not raf:Seek(0, 0)      then return 0 end
    n, buff = raf:Read(hlen)
    if n ~= hlen then return 0 end
    if not Write(outfile, buff) then err = 1 end

    if not raf:Seek(0, 2)      then return 0 end   -- seek to end of file
    local filesize = raf:Tell()
    if not truthy(filesize) then return 0 end

    -- build directory information for main raw directory
    local dirInfo_ = {
        DataLen  = 0,
        DirStart = hlen,
        DirLen   = filesize - hlen,
        Nesting  = 0,
        RAF      = raf,
        Parent   = 'CRW',
        OutFile  = outfile,
        OutPos   = hlen,
    }
    -- process the raw directory
    local tagTablePtr = GetTagTable(nil, 'lexiftool.CanonRaw.Main')
    local success = Writer.WriteDirectory(et, dirInfo_, tagTablePtr)

    local trailPt
    while truthy(success) do -- luacheck: ignore 512 (upstream `while ... { ... last; }`)
        -- check to see if trailer(s) exist(s)
        local trailInfo = et:IdentifyTrailer(raf)
        if not trailInfo then break end
        -- rewrite the trailer(s)
        buff = carray.new('char')
        trailInfo.OutFile = { value = buff }
        success = et:ProcessTrailers(trailInfo)
        if not truthy(success) then break end
        trailPt = trailInfo.OutFile
        -- nothing to write if trailers were deleted
        if length(trailPt.value) < 4 then trailPt = nil end
        break
    end
    if truthy(success) then
        -- add CanonVRD trailer if writing as a block
        trailPt = et:AddNewTrailers(trailPt,'CanonVRD')
        if not trailPt and truthy(et.ADD_DIRS.CanonVRD) then
            -- create CanonVRD from scratch if necessary
            local outbuff = carray.new('char')
            local saveOrder = GetByteOrder()
            local CanonVRD = require('lexiftool.CanonVRD')
            if CanonVRD.ProcessCanonVRD(et, { OutFile = { value = outbuff } }) > 0 then
                trailPt = { value = outbuff }
            end
            SetByteOrder(saveOrder)
        end
        -- write trailer
        if trailPt then
            -- must append DirStart pointer to end of trailer
            local newDirStart = Set32u(dirInfo_.OutDirStart)
            local len = length(trailPt.value)
            local pad = (len & 0x01 ~= 0) and ' ' or '' -- add pad byte if necessary
            if not Write(outfile, pad, substr(trailPt.value,0,len-4), newDirStart) then err = 1 end
        end
        rtnVal = err and -1 or 1
    else
        et:Error('Error rewriting CRW file')
    end
    return rtnVal
end

-- (the subs above, for CanonRaw.lua's AUTOLOAD closures)
WriteCanonRaw.InitMakerNotes = InitMakerNotes
WriteCanonRaw.BuildMakerNotes = BuildMakerNotes
WriteCanonRaw.SaveMakerNotes = SaveMakerNotes
WriteCanonRaw.CheckCanonRaw = CheckCanonRaw
WriteCanonRaw.WriteCR2 = WriteCR2
WriteCanonRaw.WriteCRW = WriteCRW

return WriteCanonRaw -- end
