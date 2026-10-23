--------------------------------------------------------------------------------
-- File:         lexiftool/WriteExif.lua
-- Ported from:  lib/Image/ExifTool/WriteExif.pl
--
-- Description:  Write EXIF meta information
--
-- Revisions:    12/13/2004 - P. Harvey Created
--
-- Port notes:   all subs of WriteExif.pl, in upstream order.  WriteExif
--               follows the Perl line by line: $newData is a carray (the
--               Set32u/SetMarkerPointers/ApplyFixup calls edit it in place),
--               $newValuePt -- a reference to $newValue or $oldValue -- is a
--               flag read through valPt()/setValPt(), the GOTOs NoWrite/
--               NoOverwrite are flags, and $$dirInfo{HeaderPtr} is the box
--               { value = <appended part> } with the fixed header length in
--               HeaderLen.  The eval'd FixOffsets/ChangeBase/WriteCondition/
--               WrongBase/Start/Base are functions; `$$subdir{Start} =~
--               /\$valuePtr/` is told by the name of the Start function's
--               third parameter.
--------------------------------------------------------------------------------

local WriteExif = {}

local ExifTool = require('lexiftool')
local perlTruthy = ExifTool.perlTruthy
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local tsort = perl.tsort
local Writer = require('lexiftool.Writer')

local Exif = require('lexiftool.Exif')
local MakerNotes = require('lexiftool.MakerNotes')
local Fixup = require('lexiftool.Fixup')
local carray = require('carray')
local substr = require('lexiftool.perl').substr
local length = perl.length
local split = perl.split
local perlStr = perl.str
local lc = perl.lc

-- Format-name / number / size lookup tables (Image::ExifTool package-level in
-- the Perl source). Mirror them locally for readability.
local formatName = Exif.formatName
local formatNumber = Exif.formatNumber
local formatSize = Exif.formatSize

-- Decide when to delete info stored in another IFD while writing it to the
-- preferred IFD (upstream %crossDelete).
local crossDelete = {
    ExifIFD = 'IFD0',
    IFD0 = 'ExifIFD',
}

-- mandatory tag default values (upstream %mandatory)
local mandatory = {
    IFD0 = {
        [0x0213] = 1,        -- YCbCrPositioning (centered)
    },
    IFD1 = {
        [0x0103] = 6,        -- Compression (JPEG)
        [0x011a] = 72,       -- XResolution
        [0x011b] = 72,       -- YResolution
        [0x0128] = 2,        -- ResolutionUnit (inches)
    },
    ExifIFD = {
        [0x9000] = '0232',   -- ExifVersion
        [0x9101] = '1 2 3 0',-- ComponentsConfiguration
        [0xa001] = 0xffff,   -- ColorSpace (uncalibrated)
    },
    GPS = {
        [0x0000] = '2 3 0 0',-- GPSVersionID
    },
    InteropIFD = {
        [0x0002] = '0100',   -- InteropVersion
    },
}

-- Inverse print conversion for OffsetTime tags (upstream WriteExif.pl InverseOffsetTime)
function WriteExif.InverseOffsetTime(et, val)
    if lc(val) == 'now' then val = et:TimeNow() end
    if val:match('Z$') then return '+00:00' end
    local s, h, m = val:match('([-+])(%d%d?):?(%d%d)')
    if s then return sprintf('%s%.2d:%.2d', s, tonumber(h), tonumber(m)) end
    return nil
end

-- Inverse print conversion for LensInfo (upstream WriteExif.pl ConvertLensInfo)
function WriteExif.ConvertLensInfo(val)
    local a = { Exif.GetLensInfo(val, 1) } -- (allow unknown "?" values)
    if #a > 0 then return perl.join(' ', a) end
    return val
end

-- Get binary CFA Pattern from a text string (upstream WriteExif.pl GetCFAPattern)
function WriteExif.GetCFAPattern(val)
    local s = val:gsub('^%[', ''):gsub('%]$', '')
    local rows = { }
    for r in (s:gsub('%][ \t\n\r\f\v]*%[', '\0')):gmatch('[^%z]+') do rows[#rows + 1] = r end
    if #rows == 0 then return nil end
    local cols = { }
    for c in rows[1]:gmatch('[^,]+') do cols[#cols + 1] = c end
    if #cols == 0 then return nil end
    local ny = #cols
    local a = { #rows, ny }
    local cfaLookup = { red = 0, green = 1, blue = 2, cyan = 3, magenta = 4, yellow = 5, white = 6 }
    for _, row in ipairs(rows) do
        local rcols = { }
        for c in row:gmatch('[^,]+') do rcols[#rcols + 1] = c end
        if #rcols ~= ny then return nil end
        for _, col in ipairs(rcols) do
            col = col:gsub('[%]%[ \t\n\r\f\v]', '')
            local c = cfaLookup[lc(col)]
            if c == nil then return nil end
            a[#a + 1] = c
        end
    end
    return table.concat(a, ' ')
end

-- validate raw values for writing (upstream WriteExif.pl CheckExif)
-- (Lua: the value instead of its reference; a modified value comes back as
--  the second result)
function WriteExif.CheckExif(_et, tagInfo, val)
    local format = tagInfo.Format or tagInfo.Writable or (tagInfo.Table and tagInfo.Table.WRITABLE)
    if not perlTruthy(format) or perlStr(format) == '1' then
        if tagInfo.Groups and tagInfo.Groups[0] == 'MakerNotes' then
            return nil  -- OK to have no format for makernotes
        else
            return 'No writable format'
        end
    end
    return Writer.CheckValue(val, format, tagInfo.Count)
end

-- encode exif ASCII/Unicode text from UTF8 or Latin (upstream WriteExif.pl EncodeExifText)
-- Note: MUST be called at Raw conversion time so the EXIF byte order is known!
function WriteExif.EncodeExifText(et, val)
    local hasHigh = false
    for i = 1, #val do
        if val:byte(i) >= 0x80 then hasHigh = true; break end
    end
    if hasHigh then
        local order = Writer.GetNewValue(et, 'ExifUnicodeByteOrder')
        return 'UNICODE\0' .. ExifTool.Encode(et, val, 'UTF16', order)
    else
        return 'ASCII\0\0\0' .. val
    end
end

--------------------------------------------------------------------------------
-- rebuild maker notes to properly contain all value data
-- (some manufacturers put value data outside maker notes!!)
-- Inputs: 0) ExifTool object ref, 1) tag table ref, 2) dirInfo ref
-- Returns: new maker note data (and creates MAKER_NOTE_FIXUP), or undef on error
function WriteExif.RebuildMakerNotes(et, dirInfo, tagTablePtr)
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos or 0
    local rtnValue
    local subdirInfo = {}
    for k, v in pairs(dirInfo) do subdirInfo[k] = v end

    et.MAKER_NOTE_FIXUP = nil

    -- don't need to rebuild text, BinaryData or PreviewImage maker notes
    local tagInfo = dirInfo.TagInfo
    local subdir = tagInfo.SubDirectory
    local proc = subdir.ProcessProc or tagTablePtr.PROCESS_PROC or Exif.ProcessExif
    if (proc ~= Exif.ProcessExif and perl.isMatch(tagInfo.Name, 'Text')) or
        proc == ExifTool.ProcessBinaryData or
        (tagInfo.PossiblePreview and dirLen > 6 and
         substr(dataPt, dirStart, 3) == '\xff\xd8\xff')
    then
        return substr(dataPt, dirStart, dirLen)
    end
    local saveOrder = ExifTool.GetByteOrder()
    local loc = MakerNotes.LocateIFD(et, subdirInfo)
    if loc ~= nil then
        local makerFixup = Fixup.new()
        subdirInfo.Fixup = makerFixup
        -- create new exiftool object to rewrite the directory without changing it
        local newTool = ExifTool.new()
        newTool:Options(
            'IgnoreMinorErrors', et.OPTIONS.IgnoreMinorErrors,
            'FixBase',           et.OPTIONS.FixBase
        )
        newTool:Init()   -- must do this before calling WriteDirectory()!
        -- don't copy over preview image
        newTool:SetNewValue('PreviewImage', '')
        -- copy all transient members over in case they are used for writing
        -- (Make, Model, etc)
        for k, v in pairs(et) do
            if type(k) == 'string' and k:find('[a-z]') then newTool[k] = v end
        end
        -- fix base offsets if specified
        newTool:Options('FixBase', et:Options('FixBase'))
        -- set GENERATE_PREVIEW_INFO flag so PREVIEW_INFO will be generated
        newTool.GENERATE_PREVIEW_INFO = 1
        -- drop any large tags
        newTool.DropTags = 1
        -- initialize other necessary data members
        newTool.FILE_TYPE = et.FILE_TYPE
        newTool.TIFF_TYPE = et.TIFF_TYPE
        -- rewrite maker notes
        rtnValue = Writer.WriteDirectory(newTool, subdirInfo, tagTablePtr)
        if rtnValue ~= nil and length(rtnValue) > 0 then
            local buf = carray.new('char'):append(rtnValue)
            -- add the dummy/empty preview image if necessary
            if newTool.PREVIEW_INFO then
                makerFixup:SetMarkerPointers(buf, 'PreviewImage', buf:len())
                buf:append(newTool.PREVIEW_INFO.Data)
                newTool.PREVIEW_INFO = nil
            end
            -- add makernote header
            if loc ~= 0 then
                local hdr = substr(dataPt, dirStart, loc)
                -- special case: convert Pentax/Samsung DNG maker notes to JPEG style
                -- (in JPEG, Pentax makernotes are absolute and start with "AOC\0" for some
                -- models, but in DNG images they are stored in tag 0xc634 of IFD0 and
                -- start with either "PENTAX \0" or "SAMSUNG\0")
                if dirInfo.Parent == 'IFD0' and perl.isMatch(hdr, [[^(PENTAX |SAMSUNG)\0]]) then
                    -- convert to JPEG-style AOC maker notes if used by this model
                    -- (Note: this expression also appears in Exif.pm)
                    if perl.isMatch(et.Model, [[\b(K(-[57mrx]|(10|20|100|110|200)D|2000)|GX(10|20))\b]]) then
                        hdr = perl.subst(hdr, [[^(PENTAX |SAMSUNG)\0]], 'AOC\0')
                        -- save fixup because AOC maker notes have absolute offsets
                        et.MAKER_NOTE_FIXUP = makerFixup
                    end
                end
                buf = carray.new('char'):append(hdr, buf)
                -- adjust fixup for shift in start position
                makerFixup.Start = makerFixup.Start + length(hdr)
            end
            -- shift offsets according to original position of maker notes,
            -- and relative to the makernotes Base
            makerFixup.Shift = makerFixup.Shift + dataPos + dirStart +
                               dirInfo.Base - subdirInfo.Base
            -- repair incorrect offsets if offsets were fixed
            makerFixup.Shift = makerFixup.Shift + (subdirInfo.FixedBy or 0)
            -- fix up pointers to the specified offset
            buf = makerFixup:ApplyFixup(buf)
            rtnValue = buf:tostring()
            -- save fixup information unless offsets were relative
            if not perlTruthy(subdirInfo.Relative) then
                -- set shift so offsets are all relative to start of maker notes
                makerFixup.Shift = makerFixup.Shift - (dataPos + dirStart)
                et.MAKER_NOTE_FIXUP = makerFixup    -- save fixup for later
            end
        end
    end
    ExifTool.SetByteOrder(saveOrder)

    return rtnValue
end

-- Sort IFD directory entries (upstream WriteExif.pl SortIFD)
-- (dataPt is a carray: the sorted directory replaces the old one in place)
function WriteExif.SortIFD(dataPt, dirStart, numEntries, allowZero)
    local entries = { }
    for index = 0, numEntries - 1 do
        local entry = dirStart + 2 + 12 * index
        local tagID = ExifTool.Get16u(dataPt, entry)
        local entryData = substr(dataPt, entry, 12)
        -- silly software can pad directories with zero entries -- put these at the end
        if not (tagID ~= 0 or index == 0 or perlTruthy(allowZero)) then tagID = 0x10000 end
        if entries[tagID] then
            entries[tagID] = entries[tagID] .. entryData
        else
            entries[tagID] = entryData
        end
    end
    local sortedTags = { }
    for k in pairs(entries) do sortedTags[#sortedTags + 1] = k end
    tsort(sortedTags)
    local newDir = carray.new('char')
    for _, k in ipairs(sortedTags) do newDir:append(entries[k]) end
    -- replace original directory with new, sorted one
    substr(dataPt, dirStart + 2, 12 * numEntries, newDir)
end

-- Validate IFD entries (upstream WriteExif.pl ValidateIFD)
function WriteExif.ValidateIFD(dirInfo, dirStart)
    local raf = dirInfo.RAF
    if not raf then return 0 end
    local base = dirInfo.Base or 0
    dirStart = dirStart or dirInfo.DirStart or 0
    local offset = dirStart + (dirInfo.DataPos or 0)
    if not raf:Seek(offset + base, 0) then return 0 end
    local n, buff = raf:Read(2)
    if n ~= 2 then return 0 end
    local numEntries = ExifTool.Get16u(buff, 0)
    if numEntries <= 1 or numEntries >= 64 then return 0 end
    local len = 12 * numEntries
    local n2, buff2 = raf:Read(len)
    if n2 ~= len then return 0 end
    buff = buff2
    local lastID = -1
    for index = 0, numEntries - 1 do
        local entry = 12 * index
        local tagID = ExifTool.Get16u(buff, entry)
        if tagID <= lastID and not dirInfo.AllowOutOfOrderTags then return 0 end
        local format = ExifTool.Get16u(buff, entry + 2)
        if format <= 0 or format > 13 then return 0 end
        local count = ExifTool.Get32u(buff, entry + 4)
        if count <= 0 then return 0 end
        lastID = tagID
    end
    return 1
end

-- Get sorted list of offsets used in IFD (upstream WriteExif.pl GetOffList)
function WriteExif.GetOffList(dataPt, dirStart, dataPos, numEntries, tagTablePtr)
    local ifdEnd = dirStart + 2 + 12 * numEntries + dataPos
    local offHash = { }
    for index = 0, numEntries - 1 do
        local entry = dirStart + 2 + 12 * index
        local format = ExifTool.Get16u(dataPt, entry + 2)
        if format >= 1 and format <= 13 then
            local count = ExifTool.Get16u(dataPt, entry + 4)
            local size = formatSize[format] * count
            if size <= 4 then
                local tagID = ExifTool.Get16u(dataPt, entry)
                if not (type(tagTablePtr[tagID]) == 'table' and tagTablePtr[tagID].FixCount) then
                    goto continue
                end
            end
            local offset = ExifTool.Get16u(dataPt, entry + 8)
            if offset >= ifdEnd then offHash[offset] = 1 end
        end
        ::continue::
    end
    -- set offset hash values to indices in list
    local offList = perl.sort(perl.keys(offHash))
    local i = 0
    for _, offset in ipairs(offList) do offHash[offset] = i; i = i + 1 end
    return offList, offHash
end

-- Update TIFF_END member if defined (upstream WriteExif.pl UpdateTiffEnd)
function WriteExif.UpdateTiffEnd(et, end_)
    if et.TIFF_END ~= nil and et.TIFF_END < end_ then et.TIFF_END = end_ end
end

--------------------------------------------------------------------------------
-- Validate image data size (upstream WriteExif.pl ValidateImageData)
-- Inputs: 0) ExifTool ref, 1) validate info table, 2) directory name,
--         3) flag to issue an error (ie. we're writing)
-- Issues a warning or an error if problems are found. The entries are the
-- %saveForValidate tags: a plain value string for a new one, or
-- { tagInfo, values } for one read from the file.
--------------------------------------------------------------------------------
function WriteExif.ValidateImageData(et, vInfo, dirName, errFlag)
    local function valOf(v) return type(v) == 'table' and v[2] or v end
    -- determine the expected size of the image data for an uncompressed image
    -- (0x102 BitsPerSample, 0x103 Compression and 0x115 SamplesPerPixel
    --  all default to a value of 1 if they don't exist)
    local compression = valOf(vInfo[0x103])
    if not (compression == nil or perlStr(compression) == '1') then return end
    if not (vInfo[0x100] and vInfo[0x101] and (vInfo[0x117] or vInfo[0x145])) then return end

    local samplesPerPix = tonumber(valOf(vInfo[0x115])) or 1
    local bitsPerSample = { }
    if vInfo[0x102] then
        for v in perlStr(valOf(vInfo[0x102])):gmatch('[^ \t\n\r\f\v]+') do
            bitsPerSample[#bitsPerSample + 1] = tonumber(v)
        end
    else
        for i = 1, samplesPerPix do bitsPerSample[i] = 1 end
    end
    local byteCountInfo = vInfo[0x117] or vInfo[0x145]
    local totalBytes = 0
    for v in perlStr(valOf(byteCountInfo)):gmatch('[^ \t\n\r\f\v]+') do
        totalBytes = totalBytes + (tonumber(v) or 0)
    end
    local minor
    if et.DOC_NUM or et.FILE_TYPE ~= 'TIFF' then minor = 1 end
    if #bitsPerSample ~= samplesPerPix then
        if not (et.FILE_TYPE == 'EPS' and #bitsPerSample == 1) then
            -- (just a warning for this problem)
            local sfx = (samplesPerPix == 1) and '' or 's'
            et:Warn(dirName .. ' BitsPerSample should have ' .. samplesPerPix ..
                    ' value' .. sfx, minor)
        end
        while #bitsPerSample < samplesPerPix do
            bitsPerSample[#bitsPerSample + 1] = bitsPerSample[1]
        end
        for _, b in ipairs(bitsPerSample) do
            if b ~= bitsPerSample[1] then
                et:Warn(dirName .. ' BitsPerSample values are different', minor)
            end
            if b < 1 or b > 32 then
                et:Warn('Invalid ' .. dirName .. ' BitsPerSample value', minor)
            end
        end
    end
    local bitsPerPixel = 0
    for _, b in ipairs(bitsPerSample) do bitsPerPixel = bitsPerPixel + b end
    local expectedBytes = math.floor(((tonumber(valOf(vInfo[0x100])) or 0) *
        (tonumber(valOf(vInfo[0x101])) or 0) * bitsPerPixel + 7) / 8)
    -- (this problem seems normal for certain types of RAW files...)
    local tt = et.TIFF_TYPE or ''
    if expectedBytes ~= totalBytes and
       not (tt == 'K25' or tt == 'KDC' or tt == 'MEF' or tt == 'ORF' or tt == 'SRF') then
        local adj
        minor = nil
        if expectedBytes > totalBytes then
            adj = 'Under' -- undersized is a bigger problem because we may lose data
            if not errFlag then minor = 0 end
        else
            adj = 'Over'
            minor = 1
        end
        local name = (type(byteCountInfo) == 'table' and byteCountInfo[1] and
                      byteCountInfo[1].Name) or 'StripByteCounts'
        local msg = adj .. 'sized ' .. dirName .. ' ' .. name .. ' (' .. totalBytes ..
                    ' bytes, but expected ' .. expectedBytes .. ')'
        if minor == nil then
            -- this is a serious error if we are writing the file and there
            -- is a chance that we may not copy all of the image data
            -- (but make it minor to allow the file to be written anyway)
            et:Error(msg, 1)
        else
            et:Warn(msg, minor)
        end
    end
end

--------------------------------------------------------------------------------
-- Add specified image data to ImageDataHash hash
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) lookup for [tagInfo,value] based on tagID
function WriteExif.AddImageDataHash(et, dirInfo, offsetInfo)
    local verbose = et:Options('Verbose')
    local raf = dirInfo.RAF

    local tagIDs = { }
    for tagID in pairs(offsetInfo) do tagIDs[#tagIDs + 1] = tagID end
    tsort(tagIDs, function(a, b) return perl.lt(a, b) end)
    for _, tagID in ipairs(tagIDs) do
        if type(offsetInfo[tagID]) ~= 'table' then goto next_tag end -- ignore scalar tag values used for Validate
        do
            local tagInfo = offsetInfo[tagID][1]
            if not tagInfo.IsImageData then goto next_tag end     -- only consider image data
            local sizeID = tagInfo.OffsetPair
            local sizes
            if tagInfo.NotRealPair then
                sizes = { 999999999 }     -- (Panasonic hack: raw data runs to end of file)
            elseif sizeID and offsetInfo[sizeID] then
                sizes = split(' ', offsetInfo[sizeID][2])
            else
                goto next_tag
            end
            local offsets = split(' ', offsetInfo[tagID][2])
            if tagInfo.NotRealPair then sizes[1] = 999999999 end
            local total = 0
            for _, offset in ipairs(offsets) do
                local size = table.remove(sizes, 1)
                if perl.isMatch(offset, [[^\d+$]]) and perlTruthy(size) and perl.isMatch(size, [[^\d+$]]) and
                    perlTruthy(size) and raf:Seek(tonumber(offset), 0) -- (offset is absolute)
                then
                    total = total + et:ImageDataHash(raf, tonumber(size))
                end
            end
            if perlTruthy(verbose) then
                local name = dirInfo.DirName .. ":" .. tagInfo.Name
                name = perl.subst(name, [[Offsets?|Start$]], '')
                et:VPrint(0, et.INDENT .. "(ImageDataHash: " .. total .. " bytes of " .. name .. " data)\n")
            end
        end
        ::next_tag::
    end
end

--------------------------------------------------------------------------------
-- Handle error while writing EXIF
-- Inputs: 0) ExifTool ref, 1) error string, 2) tag table ref
-- Returns: undef on fatal error, or '' if minor error is ignored
function WriteExif.ExifErr(et, errStr, tagTablePtr)
    -- MakerNote errors are minor by default
    local minor = (tagTablePtr.GROUPS and tagTablePtr.GROUPS[0] == 'MakerNotes') or et.FILE_TYPE == 'MOV'
    if tagTablePtr.VARS and tagTablePtr.VARS.MINOR_ERRORS then
        if minor and perlTruthy(et:Warn(errStr .. '. IFD dropped.')) then return '' end
        minor = 1
    end
    if perlTruthy(et:Error(errStr, minor)) then return nil end
    return ''
end

--------------------------------------------------------------------------------
-- Read/Write IFD with TIFF-like header (upstream WriteExif.pl ProcessTiffIFD)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: Reading: 1 on success, otherwise returns 0 and sets a Warning
--          Writing: new data block or undef on error
function WriteExif.ProcessTiffIFD(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access
    local raf = dirInfo.RAF
    local base = dirInfo.Base or 0
    local dirName = dirInfo.DirName
    local magic = dirInfo.Subdir and dirInfo.Subdir.Magic or 0x002a
    local buff

    -- structured with a TIFF-like header and relative offsets
    local n
    if raf:Seek(base, 0) then n, buff = raf:Read(8) end
    if n ~= 8 then return 0 end
    if not (ExifTool.SetByteOrder(substr(buff,0,2)) and ExifTool.Get16u(buff, 2) == magic) then
        local msg = "Invalid " .. dirName .. " header"
        if dirInfo.IsWriting then
            et:Error(msg)
            return nil
        else
            et:Warn(msg)
            return 0
        end
    end
    local offset = ExifTool.Get32u(buff, 4)
    local newDirInfo = {
        DirName  = dirInfo.DirName,
        Parent   = dirInfo.Parent,
        Base     = base,
        DataPt   = buff,
        DataLen  = length(buff),
        DataPos  = 0,
        DirStart = offset,
        DirLen   = length(buff) - offset,
        RAF      = raf,
        NewDataPos = 8,
    }
    if dirInfo.IsWriting then
        -- rewrite the Camera Profile IFD
        local newDir = WriteExif.WriteExif(et, newDirInfo, tagTablePtr)
        -- don't add header if error writing directory ($newDir is undef)
        -- or if directory is being deleted ($newDir is empty)
        if not perlTruthy(newDir) then return newDir end
        -- return directory with TIFF-like header
        return ExifTool.GetByteOrder() .. ExifTool.Put16u(magic) .. ExifTool.Put32u(8) .. newDir
    end
    if et.HTML_DUMP then
        local tip = sprintf("Byte order: %s endian\nIdentifier: 0x%.4x\n%s offset: 0x%.4x",
                          (ExifTool.GetByteOrder() == 'II') and 'Little' or 'Big', magic, dirName, offset)
        et:HDump(base, 8, dirName .. " header", tip, 0)
    end
    return Exif.ProcessExif(et, newDirInfo, tagTablePtr)
end

-- (port: Fixup:ApplyFixup/SetMarkerPointers work on a carray -- upstream
--  passes a reference to the string; these wrap a Lua string)
-- (port: upstream tests `$$subdir{Start} =~ /\$valuePtr/` on the eval
--  string; the ported Start is a function($self, $val, $valuePtr), which
--  uses $valuePtr exactly when its third parameter is named, ie. not
--  '_'-prefixed)
local function usesValuePtr(start)
    if type(start) ~= 'function' then return false end
    local pname = debug.getlocal(start, 3)
    return pname ~= nil and pname:sub(1, 1) ~= '_'
end

--------------------------------------------------------------------------------
-- Write EXIF directory
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: Exif data block (may be empty if no Exif data) or undef on error
-- Notes: Increments ExifTool CHANGED flag for each tag changed.  Also updates
--        TIFF_END if defined with location of end of original TIFF image.
-- Returns IFD data in the following order:
--   1. IFD0 directory followed by its data
--   2. SubIFD directory followed by its data, thumbnail and image
--   3. GlobalParameters, EXIF, GPS, Interop IFD's each with their data
--   4. IFD1,IFD2,... directories each followed by their data
--   5. Thumbnail and/or image data for each IFD, with IFD0 image last
-- (port: $newData is a carray, so the Set32u/SetMarkerPointers/ApplyFixup
--  calls change it in place as upstream, and so are $dirBuff/$valBuff; the
--  values are Lua strings.  $newValuePt, a reference to either $newValue or
--  $oldValue, is the flag newValuePtIsNew read through valPt()/setValPt().
--  $$dirInfo{HeaderPtr} is the TIFF header itself, a carray)
function WriteExif.WriteExif(et, dirInfo, tagTablePtr)
    if not et then return 1 end      -- allow dummy access to autoload this package
    local origDirInfo = dirInfo -- save original dirInfo
    local dataPt = dirInfo.DataPt
    if not dataPt then
        local emptyData = ''
        dataPt = emptyData
    end
    local dataPos = dirInfo.DataPos or 0
    local dirStart = dirInfo.DirStart or 0
    local dataLen = perlTruthy(dirInfo.DataLen) and dirInfo.DataLen or length(dataPt)
    local dirLen = perlTruthy(dirInfo.DirLen) and dirInfo.DirLen or (dataLen - dirStart)
    local base = dirInfo.Base or 0
    local firstBase = base
    local raf = dirInfo.RAF
    local dirName = dirInfo.DirName or 'unknown'
    local fixup = dirInfo.Fixup or Fixup.new()
    local imageDataFlag = dirInfo.ImageData or ''
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local noMandatory = et:Options('NoMandatory')
    local nextIfdPos, offsetData, inMakerNotes = nil, { }, nil
    local offsetInfo, validateInfo, xDelete, strEnc = { }, { }, { }, nil
    local lastOffsetInfo = -1   -- ($#offsetInfo)
    local deleteAll = 0
    local newData = carray.new('char')   -- initialize buffer to receive new directory data
    local imageData = { }   -- image data blocks to copy later if requested
    local name = dirInfo.Name
    if not (perlTruthy(name) and dirName == 'MakerNotes' and not perl.isMatch(name, '^MakerNote')) then
        name = dirName
    end

    -- save byte order of existing EXIF
    if dirName == 'IFD0' or dirName == 'ExifIFD' then et.SaveExifByteOrder = ExifTool.GetByteOrder() end

    -- set encoding for strings
    if tagTablePtr.GROUPS[0] == 'EXIF' then strEnc = et:Options('CharsetEXIF') end

    -- allow multiple IFD's in IFD0-IFD1-IFD2... chain
    if (dirName == 'IFD0' or dirName == 'SubIFD') and dirInfo.Multi == nil then dirInfo.Multi = 1 end
    if tagTablePtr.GROUPS[0] == 'MakerNotes' then inMakerNotes = 1 end
    local ifd

    -- the entry being written ($newValuePt points at $newValue or $oldValue)
    local oldValue, newValue, newValuePtIsNew
    local function valPt()
        if newValuePtIsNew then return newValue end
        return oldValue
    end
    local function setValPt(v)
        if newValuePtIsNew then newValue = v else oldValue = v end
    end

--~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- loop through each IFD
--
    ifd = 0
    while true do  -- loop through multiple IFD's

        -- make sure that Compression and SubfileType are defined for this IFD (for Condition's)
        et.Compression = ''
        et.SubfileType = ''

        -- save pointer to start of this IFD within the newData
        local newStart = newData:len()
        local subdirs = { }    -- list of subdirectory data and tag table pointers
        -- determine if directory is contained within our data
        local mustRead
        if dirStart < 0 or dirStart > dataLen-2 then
            mustRead = 1
        elseif dirLen >= 2 then
            local len = 2 + 12 * ExifTool.Get16u(dataPt, dirStart)
            if dirStart + len > dataLen then mustRead = 1 end
        end
        -- read IFD from file if necessary
        if mustRead then
            if raf then
                -- read the count of entries in this IFD
                local offset = dirStart + dataPos
                local buff, buf2, n
                if raf:Seek(offset + base, 0) then n, buff = raf:Read(2) end
                if n ~= 2 then
                    return WriteExif.ExifErr(et, "Bad IFD or truncated file in " .. name, tagTablePtr)
                end
                local len = 12 * ExifTool.Get16u(buff,0)
                -- (also read next IFD pointer if available)
                n, buf2 = raf:Read(len+4)
                if n < len then
                    return WriteExif.ExifErr(et, "Error reading " .. name, tagTablePtr)
                end
                buff = buff .. buf2
                -- make copy of dirInfo since we're going to modify it
                local newDirInfo = { }
                for k, v in pairs(dirInfo) do newDirInfo[k] = v end
                dirInfo = newDirInfo
                -- update directory parameters for the newly loaded IFD
                dataPt = buff;  dirInfo.DataPt = dataPt
                dirStart = 0;   dirInfo.DirStart = dirStart
                dataPos = offset;  dirInfo.DataPos = dataPos
                dataLen = length(buff);  dirInfo.DataLen = dataLen
                dirLen = dataLen;  dirInfo.DirLen = dirLen
                -- only account for nextIFD pointer if we are going to use it
                if dataLen==len+6 and (dirInfo.Multi or perl.isMatch(buff, [[\0{4}$]])) then len = len + 4 end
                WriteExif.UpdateTiffEnd(et, offset+base+2+len)
            elseif perlTruthy(dirLen) and dirStart + 4 >= dataLen then
                -- error if we can't load IFD (unless we are creating
                -- from scratch, in which case dirLen will be zero)
                local str = perlTruthy(et:Options('IgnoreMinorErrors')) and 'Deleted bad' or 'Bad'
                et:Error(str .. " " .. name .. " directory", 1)
            end
        end
        local index, dirEnd, numEntries, unsorted
        local hasOldID = { }
        if dirStart + 4 < dataLen then
            numEntries = ExifTool.Get16u(dataPt, dirStart)
            dirEnd = dirStart + 2 + 12 * numEntries
            if dirEnd > dataLen then
                local n = perl.int((dataLen - dirStart - 2) / 12)
                local rtn = WriteExif.ExifErr(et, "Truncated " .. name .. " directory", tagTablePtr)
                if not (perlTruthy(n) and rtn ~= nil) then return nil end
                numEntries = n   -- continue processing the entries we have
            end
            -- create lookup for existing tag ID's and determine if directory is sorted
            local lastID = -1
            for idx = 0, numEntries - 1 do
                local tagID = ExifTool.Get16u(dataPt, dirStart + 2 + 12 * idx)
                hasOldID[tagID] = 1
                -- check for proper sequence (but ignore null entries at end)
                if tagID < lastID and (tagID ~= 0 or tagTablePtr[0]) then unsorted = 1 end
                lastID = tagID
            end
            -- sort entries if out-of-order (but not in maker notes IFDs or RAW files)
            if unsorted and not (inMakerNotes or perlTruthy(et:IsRawType())) then
                -- (SortIFD edits a carray in place; the code that reads the
                --  directory and its subdirectories below takes a string)
                local sortPt = carray.new('char'):append(dataPt)
                WriteExif.SortIFD(sortPt, dirStart, numEntries, tagTablePtr[0])
                dataPt = sortPt:tostring()
                et:Warn("Entries in " .. name .. " were out of sequence. Fixed.",1)
                unsorted = nil
            end
        else
            numEntries = 0
            dirEnd = dirStart
        end

        -- loop through new values and accumulate all information for this IFD
        local set, mayDelete, hasNewID = { }, { }, { }
        local wrongDir = crossDelete[dirName]
        local newTagInfo = Writer.GetNewTagInfoList(et, tagTablePtr)
        for _, tagInfo in ipairs(newTagInfo) do
            local tagID = tagInfo.TagID
            hasNewID[tagID] = 1
            -- must evaluate Condition later when we have all DataMember's available
            -- (port: '' is the "evaluate later" marker, a Perl false value)
            if (type(tagTablePtr[tagID]) == 'table' and tagTablePtr[tagID][1] ~= nil) or tagInfo.Condition then
                set[tagID] = ''
            else
                set[tagID] = tagInfo
            end
        end

        -- fix base offsets (some cameras incorrectly write maker notes in IFD0)
        if dirName == 'MakerNotes' and perl.isMatch(dirInfo.Parent, [[^(ExifIFD|IFD0)$]]) and
            not perl.isMatch(et.TIFF_TYPE, [[^(ARW|SR2)$]]) and not perlTruthy(et.LeicaTrailerPos) and
            perlTruthy(MakerNotes.FixBase(et, dirInfo))
        then
            -- update local variables from fixed values
            base = dirInfo.Base
            dataPos = dirInfo.DataPos
            -- changed if ForceWrite tag was was set to "FixBase"
            if et.FORCE_WRITE and et.FORCE_WRITE.FixBase then et.CHANGED = (et.CHANGED or 0) + 1 end
            if et.TIFF_TYPE == 'SRW' and et.Make == 'SAMSUNG' and et.Model == 'EK-GN120' then
                et:Error("EK-GN120 SRW files are too buggy to write")
            end
        end

        -- initialize variables to handle mandatory tags
        local mandatoryTbl, allMandatory, addMandatory
        if not perlTruthy(noMandatory) then mandatoryTbl = mandatory[dirName] end
        if mandatoryTbl then
            -- use X/Y resolution values from JFIF if available
            if dirName == 'IFD0' and et.JFIFYResolution ~= nil then
                local ifd0Vals = { }
                for k, v in pairs(mandatoryTbl) do ifd0Vals[k] = v end
                ifd0Vals[0x011a] = et.JFIFXResolution
                ifd0Vals[0x011b] = et.JFIFYResolution
                ifd0Vals[0x0128] = et.JFIFResolutionUnit + 1
                mandatoryTbl = ifd0Vals
            end
            allMandatory = 0; addMandatory = 0 -- initialize to zero
            -- add mandatory tags if creating a new directory
            if numEntries == 0 then
                for k in pairs(mandatoryTbl) do
                    if set[k] == nil then set[k] = tagTablePtr[k] end
                end
            end
        else
            deleteAll = nil   -- don't remove directory (no mandatory entries)
        end
        local addDirs
        local newTags = { }
        if inMakerNotes then
            addDirs = { }     -- can't currently add new directories in MakerNotes
            -- allow non-permanent makernotes tags to be added
            -- (note: we may get into trouble if there are too many of these
            --  because we allow out-of-order tags in MakerNote IFD's but our
            --  logic to add new tags relies on ordered entries)
            for k, v in pairs(set) do
                if perlTruthy(v) then
                    local perm = v.Permanent
                    if perm ~= nil and not perlTruthy(perm) then newTags[#newTags + 1] = k end
                end
            end
            if #newTags > 1 then tsort(newTags) end
        else
            -- get a hash of directories we will be writing in this one
            addDirs = Writer.GetAddDirHash(et, tagTablePtr, dirName)
            -- make a union of tags & dirs (can set whole dirs, like MakerNotes)
            local allTags = { }
            for k, v in pairs(set) do allTags[k] = v end
            for k, v in pairs(addDirs) do allTags[k] = v end
            -- make sorted list of new tags to be added
            for k in pairs(allTags) do newTags[#newTags + 1] = k end
            tsort(newTags)
        end
        local dirBuff = carray.new('char')   -- buffer for directory data
        local valBuff = carray.new('char')   -- buffer for value data
        local valFixups = { }      -- list of fixups for offsets in valBuff
        -- fixup for offsets in dirBuff
        local dirFixup = Fixup.new()
        local entryBasedFixup
        local lastTagID = -1
        local oldInfo, oldFormat, oldFormName, oldCount, oldSize, oldImageData
        local readFormat, readFormName, readCount -- format for reading old value(s)
        local entry, valueDataPt, valueDataPos, valueDataLen, valuePtr, valEnd
        local offList, offHash, ignoreCount, fixCount
        local oldID = -1
        local newID = -1

        -- patch for Canon EOS 40D firmware 1.0.4 bug (incorrect directory counts)
        if inMakerNotes and et.Model == 'Canon EOS 40D' then
            local fmt = ExifTool.Get16u(dataPt, dirStart + 2 + 12 * (numEntries - 1) + 2)
            if fmt < 1 or fmt > 13 then
                -- adjust the number of directory entries
                numEntries = numEntries - 1
                dirEnd = dirEnd - 12
                ignoreCount = 1
            end
        end
--..............................................................................
-- loop through entries in new directory
--
        index = 0
        while true do -- Entry:

            if oldID ~= nil and oldID == newID then
--
-- read next entry from existing directory
--
                if index < numEntries then
                    entry = dirStart + 2 + 12 * index
                    oldID = ExifTool.Get16u(dataPt, entry)
                    oldFormat = ExifTool.Get16u(dataPt, entry+2);  readFormat = oldFormat
                    oldCount = ExifTool.Get32u(dataPt, entry+4);  readCount = oldCount
                    oldImageData = nil
                    if (oldFormat < 1 or oldFormat > 13) and oldFormat ~= 129 and not (oldFormat == 16 and et.Make == 'Apple' and inMakerNotes) then
                        local msg = "Bad format (" .. oldFormat .. ") for " .. name .. " entry " .. index
                        -- patch to preserve invalid directory entries in SubIFD3 of
                        -- various Kodak Z-series cameras (Z812, Z1085IS, Z1275)
                        -- and some Sony cameras such as the DSC-P10
                        if dirName == 'MakerNotes' and ((perl.isMatch(et.Make, '(?i)KODAK') and
                            dirInfo.Name and dirInfo.Name == 'SubIFD3') or
                            (numEntries == 12 and et.Make == 'SONY' and index >= 8))
                        then
                            dirBuff:append(substr(dataPt, entry, 12))
                            index = index + 1
                            newID = oldID    -- we wrote this
                            et:Warn(msg, 1)
                            goto continue_entry
                        end
                        -- don't write out null directory entry
                        if oldFormat==0 and index ~= 0 and oldCount==0 then
                            ignoreCount = (ignoreCount or 0) + 1
                            -- must keep same directory size to avoid messing up our fixed offsets
                            if dirInfo.FixBase then dirBuff:append(string.rep("\0", 12)) end
                            index = index + 1
                            newID = oldID    -- pretend we wrote this
                            goto continue_entry
                        end
                        return WriteExif.ExifErr(et, msg, tagTablePtr)
                    end
                    oldFormName = formatName[oldFormat];  readFormName = oldFormName
                    valueDataPt = dataPt
                    valueDataPos = dataPos
                    valueDataLen = dataLen
                    valuePtr = entry + 8
                    -- try direct method first for speed
                    oldInfo = tagTablePtr[oldID]
                    if type(oldInfo) ~= 'table' or oldInfo[1] ~= nil or oldInfo.Condition then
                        -- must get unknown tags too
                        -- (necessary so we don't miss a tag we want to Drop)
                        local unk = et:Options('Unknown', 1)
                        oldInfo = et:GetTagInfo(tagTablePtr, oldID)
                        et:Options('Unknown', unk)
                    end
                    -- patch incorrect count in Kodak SubIFD3 tags
                    if oldCount < 2 and oldInfo and oldInfo.FixCount then
                        if not offList then
                            offList, offHash = WriteExif.GetOffList(dataPt, dirStart, dataPos,
                                                                    numEntries, tagTablePtr)
                        end
                        local i = offHash[ExifTool.Get32u(dataPt, valuePtr)]
                        if i ~= nil and i < #offList - 1 then
                            oldCount = perl.int((offList[i+2] - offList[i+1]) / formatSize[oldFormat])
                            if oldCount ~= readCount then fixCount = (fixCount or 0) + 1 end
                        end
                    end
                    oldSize = oldCount * formatSize[oldFormat]
                    local readFromFile
                    if oldSize > 4 then
                        valuePtr = ExifTool.Get32u(dataPt, valuePtr)
                        -- fix valuePtr if necessary
                        if dirInfo.FixOffsets then
                            if not perlTruthy(valEnd) then valEnd = dataPos + dirStart + 2 + 12 * numEntries + 4 end
                            local tagID, size, wFlag = oldID, oldSize, 1
                            --### eval FixOffsets ($valuePtr, $valEnd, $size, $tagID, $wFlag)
                            valuePtr, valEnd = dirInfo.FixOffsets(valuePtr, valEnd, size, tagID, wFlag)
                            if valuePtr == nil then
                                if not et.DropTags then
                                    local tagStr = oldInfo and oldInfo.Name or sprintf("tag 0x%.4x",oldID)
                                    if perlTruthy(et:Error("Bad " .. name .. " offset for " .. tagStr, inMakerNotes)) then return nil end
                                end
                                index = index + 1;  oldID = newID;  goto continue_entry  -- drop this tag
                            end
                        end
                        -- offset shouldn't point into TIFF or IFD header
                        local suspect = (valuePtr < 8)
                        -- convert offset to pointer in $$dataPt
                        if perlTruthy(dirInfo.EntryBased) or (type(tagTablePtr[oldID]) == 'table' and
                            tagTablePtr[oldID][1] == nil and perlTruthy(tagTablePtr[oldID].EntryBased))
                        then
                            valuePtr = valuePtr + entry
                        else
                            valuePtr = valuePtr - dataPos
                        end
                        -- value shouldn't overlap our directory
                        if valuePtr < dirEnd and valuePtr+oldSize > dirStart then suspect = true end
                        -- get value by seeking in file if we are allowed
                        if valuePtr < 0 or valuePtr+oldSize > dataLen then
                            local pos, tagStr, invalidPreview, tmpInfo, leicaTrailer
                            if oldInfo then
                                tagStr = oldInfo.Name
                                leicaTrailer = oldInfo.LeicaTrailer
                            elseif oldInfo ~= nil then
                                tmpInfo = et:GetTagInfo(tagTablePtr, oldID, '', oldFormName, oldCount)
                                if tmpInfo then
                                    tagStr = tmpInfo.Name
                                    leicaTrailer = tmpInfo.LeicaTrailer
                                end
                            end
                            if not tagStr then tagStr = sprintf("tag 0x%.4x",oldID) end
                            -- allow PreviewImage to run outside EXIF segment in JPEG images
                            if not raf then
                                if tagStr == 'PreviewImage' then
                                    raf = et.RAF
                                    if raf then
                                        pos = raf:Tell()
                                        if oldInfo and oldInfo.ChangeBase then
                                            -- adjust base offset for this tag only
                                            --### eval ChangeBase ($dirStart,$dataPos)
                                            local newBase = oldInfo.ChangeBase(dirStart, dataPos)
                                            valuePtr = valuePtr + newBase
                                        end
                                    else
                                        invalidPreview = 1
                                    end
                                elseif leicaTrailer then
                                    -- save information about Leica makernote trailer
                                    et.LeicaTrailer = {
                                        TagInfo = oldInfo or tmpInfo,
                                        Offset  = base + valuePtr + dataPos,
                                        Size    = oldSize,
                                        Fixup   = Fixup.new(),
                                    }
                                    invalidPreview = 2
                                    -- remove SubDirectory to prevent processing (for now)
                                    local copy = { }
                                    for k, v in pairs(oldInfo or tmpInfo) do copy[k] = v end
                                    copy.SubDirectory = nil
                                    copy.MakerNotes = nil
                                    oldInfo = copy
                                end
                            end
                            if oldSize > Exif.BINARY_DATA_LIMIT() and origDirInfo.ImageData and
                                (oldInfo == nil or (oldInfo and
                                (not oldInfo.SubDirectory or oldInfo.ReadFromRAF)))
                            then
                                -- copy huge data blocks later instead of loading into memory
                                oldValue = '' -- dummy empty value
                                -- copy this value later unless writing a new value
                                if set[oldID] == nil then
                                    local pad = (oldSize & 0x01 ~= 0) and 1 or 0
                                    -- save block information to copy later (set directory offset later)
                                    oldImageData = { base+valuePtr+dataPos, oldSize, pad }
                                end
                            elseif raf then
                                local success = raf:Seek(base+valuePtr+dataPos, 0)
                                if success then
                                    local n
                                    n, oldValue = raf:Read(oldSize)
                                    success = (n == oldSize)
                                end
                                if pos ~= nil then
                                    raf:Seek(pos, 0)
                                    raf = nil
                                    -- (sony A700 has 32-byte header on PreviewImage)
                                    if not (success and perl.isMatch(oldValue, [[(?s)^(\xff\xd8\xff|(.|.{33})\xd8\xff\xdb)]])) then
                                        invalidPreview = 1
                                        success = true   -- continue writing directory anyway
                                    end
                                end
                                if not success then
                                    local wrn = sprintf("Error reading value for " .. name .. " entry " .. index .. ", ID 0x%.4x", oldID)
                                    local truncOK
                                    if oldInfo and not oldInfo.Unknown then
                                        wrn = wrn .. " " .. oldInfo.Name
                                        truncOK = oldInfo.TruncateOK
                                    end
                                    if perlTruthy(et:Error(wrn, inMakerNotes or truncOK)) then return nil end
                                    if not truncOK then
                                        index = index + 1;  oldID = newID;  goto continue_entry  -- drop this tag
                                    end
                                end
                            elseif not invalidPreview then
                                if perlTruthy(et:Error("Bad " .. name .. " offset for " .. tagStr, inMakerNotes)) then return nil end
                                index = index + 1;  oldID = newID;  goto continue_entry  -- drop this tag
                            end
                            if invalidPreview then
                                -- set value for invalid preview
                                if et.FILE_TYPE == 'JPEG' then
                                    -- define dummy value for preview (or Leica MakerNote) to write later
                                    -- (value must be larger than 4 bytes to generate PREVIEW_INFO,
                                    -- and an even number of bytes so it won't be padded)
                                    oldValue = 'LOAD_PREVIEW'
                                else
                                    oldValue = 'none'
                                    oldSize = length(oldValue)
                                end
                                valuePtr = 0
                            else
                                WriteExif.UpdateTiffEnd(et, base+valuePtr+dataPos+oldSize)
                            end
                            -- update pointers for value just read from file
                            valueDataPt = oldValue
                            valueDataPos = valuePtr + dataPos
                            valueDataLen = oldSize
                            valuePtr = 0
                            readFromFile = 1
                        end
                        if suspect then
                            local tagStr = oldInfo and oldInfo.Name or sprintf('tag 0x%.4x', oldID)
                            local str = "Suspicious " .. name .. " offset for " .. tagStr
                            if inMakerNotes then
                                et:Warn(str, 1)
                            else
                                if perlTruthy(et:Error(str, 1)) then return nil end
                            end
                        end
                    end
                    -- read value if we haven't already
                    if not readFromFile then oldValue = substr(valueDataPt, valuePtr, oldSize) end
                    -- get tagInfo using value if necessary
                    if oldInfo == false then
                        local unk = et:Options('Unknown', 1)
                        oldInfo = et:GetTagInfo(tagTablePtr, oldID, oldValue, oldFormName, oldCount)
                        et:Options('Unknown', unk)
                        -- now that we have the value, we can resolve the Condition to finally
                        -- determine whether we want to delete this tag or not
                        if mayDelete[oldID] and oldInfo and (#newTags == 0 or newTags[1] ~= oldID) then
                            local nvHash = Writer.GetNewValueHash(et, oldInfo, dirName)
                            if not nvHash and wrongDir then
                                -- delete from wrong directory if necessary
                                nvHash = Writer.GetNewValueHash(et, oldInfo, wrongDir)
                                if nvHash then xDelete[oldID] = 1 end
                            end
                            if nvHash then
                                -- we want to delete this tag after all, so insert it into our list
                                set[oldID] = oldInfo
                                table.insert(newTags, 1, oldID)
                            end
                        end
                    end
                    -- make sure we are handling the 'ifd' format properly
                    if (oldFormat == 13 or oldFormat == 18) and
                        (not oldInfo or not oldInfo.SubIFD)
                    then
                        local str = sprintf('%s tag 0x%.4x IFD format not handled', name, oldID)
                        et:Error(str, inMakerNotes)
                    end
                    -- override format we use to read the value if specified
                    if oldInfo then
                        -- check for tags which must be integers
                        if (oldInfo.IsOffset or oldInfo.SubIFD) and
                            not Exif.intFormat[oldFormName]
                        then
                            et:Error("Invalid format (" .. oldFormName .. ") for " .. name .. " " .. oldInfo.Name, inMakerNotes)
                            index = index + 1;  oldID = newID;  goto continue_entry  -- drop this tag
                        end
                        if oldInfo.Drop and et.DropTags and
                            (oldInfo.Drop == 1 or oldInfo.Drop < oldSize)
                        then
                            index = index + 1;  oldID = newID;  goto continue_entry  -- drop this tag
                        end
                        if oldInfo.Format then
                            readFormName = oldInfo.Format
                            readFormat = formatNumber[readFormName]
                            if not readFormat then
                                -- we aren't reading in a standard EXIF format, so rewrite in old format
                                readFormName = oldFormName
                                readFormat = oldFormat
                            end
                            if oldInfo.FixedSize then
                                if oldInfo.FixedSize then oldSize = oldInfo.FixedSize end
                                oldValue = substr(valueDataPt, valuePtr, oldSize)
                            end
                            -- adjust number of items to read if format size changed
                            readCount = oldSize / formatSize[readFormat]
                        end
                    end
                    if oldID <= lastTagID and not (inMakerNotes or perlTruthy(et:IsRawType())) then
                        local str = oldInfo and (oldInfo.Name .. " tag") or sprintf('tag 0x%x',oldID)
                        if oldID == lastTagID then
                            et:Warn("Duplicate " .. str .. " in " .. name)
                            -- put this tag back into the newTags list if necessary
                            if set[oldID] ~= nil then table.insert(newTags, 1, oldID) end
                        else
                            et:Warn(perl.ucfirst(str) .. " out of sequence in " .. name)
                        end
                    end
                    lastTagID = oldID
                    index = index + 1               -- increment index for next time
                else
                    oldID = nil           -- no more existing entries
                end
            end
--
-- write out all new tags, up to and including this one
--
            newID = newTags[1]
            local isNew  -- -1=tag is old, 0=tag same as existing, 1=tag is new
            if oldID == nil then
                if newID == nil then break end
                isNew = 1
            elseif newID == nil then
                -- maker notes will have no new tags defined
                if set[oldID] ~= nil then
                    newID = oldID
                    isNew = 0
                else
                    isNew = -1
                end
            else
                isNew = (oldID > newID) and 1 or (oldID < newID and -1 or 0)
                -- special logic needed if directory has out-of-order entries
                if unsorted and isNew ~= 0 then
                    if isNew > 0 and hasOldID[newID] then
                        -- we wanted to create the new tag, but an old tag
                        -- does exist with this ID, so defer writing the new tag
                        isNew = -1
                    end
                    if isNew < 0 and hasNewID[oldID] then
                        -- we wanted to write the old tag, but we have
                        -- a new tag with this ID, so move it up in the order
                        local tmpTags = { oldID }
                        for _, t in ipairs(newTags) do
                            if t ~= oldID then tmpTags[#tmpTags + 1] = t end
                        end
                        newTags = tmpTags
                        newID = oldID
                        isNew = 0
                    end
                end
            end
            local newInfo = oldInfo
            local newFormat = oldFormat
            local newFormName = oldFormName
            local newCount = oldCount
            local ifdFormName
            newValue = nil
            newValuePtIsNew = (isNew >= 0)
            local isOverwriting
            local noWrite, noOverwrite   -- (port: the targets of upstream's GOTOs)

            if isNew >= 0 then
                -- add, edit or delete this tag
                table.remove(newTags, 1) -- remove from list
                local curInfo = set[newID]
                -- don't allow MakerNotes to be added to ExifIFD of CR3 file
                if newID == 0x927c and isNew > 0 and et.FileType == 'CR3' then goto continue_entry end
                if not (perlTruthy(curInfo) or addDirs[newID]) then
                    -- we can finally get the specific tagInfo reference for this tag
                    -- (because we can now evaluate the Condition statement since all
                    --  DataMember's have been obtained for tags up to this one)
                    curInfo = et:GetTagInfo(tagTablePtr, newID)
                    if curInfo == false then
                        -- need value to evaluate the condition
                        -- (tricky because we need the tagInfo ref to get the value,
                        --  so we must loop through all new tagInfo's...)
                        for _, tagInfo in ipairs(newTagInfo) do
                            if tagInfo.TagID ~= newID then goto continue_ti end
                            do
                                local val = et:GetNewValue(tagInfo)
                                if val == nil then mayDelete[newID] = 1; goto continue_ti end
                                -- must convert to binary for evaluating in Condition
                                local fmt = tagInfo.Format or tagInfo.Writable
                                if fmt then
                                    val = Writer.WriteValue(val, fmt, tagInfo.Count)
                                    if val == nil then mayDelete[newID] = 1; goto continue_ti end
                                end
                                curInfo = et:GetTagInfo(tagTablePtr, newID, val, oldFormName, oldCount)
                                if curInfo then
                                    if curInfo == tagInfo then break end
                                    curInfo = nil
                                end
                            end
                            ::continue_ti::
                        end
                        -- may want to delete this, but we need to see the old value first
                        if not curInfo then mayDelete[newID] = 1 end
                    end
                    -- don't set this tag unless valid for the current condition
                    if curInfo and et.NEW_VALUE and et.NEW_VALUE[curInfo] then
                        set[newID] = curInfo
                    else
                        if isNew > 0 then goto continue_entry end
                        isNew = -1
                        curInfo = nil
                    end
                end
                if curInfo then
                    repeat -- (port: `goto NoWrite` is noWrite = true + break)
                        if curInfo.WriteCondition then
                            local self = et   -- set $self to be used in eval
                            --### eval WriteCondition ($self)
                            if not perlTruthy(curInfo.WriteCondition(self)) then
                                noWrite = true; break   -- GOTO !
                            end
                        end
                        local nvHash
                        if isNew >= 0 then nvHash = Writer.GetNewValueHash(et, curInfo, dirName) end
                        if not (nvHash or (mandatoryTbl and mandatoryTbl[newID] ~= nil and not perlTruthy(noMandatory))) then
                            if not wrongDir then noWrite = true; break end  -- GOTO !
                            -- delete stuff from the wrong directory if setting somewhere else
                            nvHash = Writer.GetNewValueHash(et, curInfo, wrongDir)
                            -- don't cross delete if not overwriting
                            if not perlTruthy(Writer.IsOverwriting(et, nvHash)) then noWrite = true; break end  -- GOTO !
                            -- don't cross delete if specifically deleting from the other directory
                            -- (Note: don't call GetValue() here because it shouldn't be called
                            --  if IsOverwriting returns < 0 -- eg. when shifting)
                            if nvHash.Value == nil and perlTruthy(nvHash.WantGroup) and
                                    perl.lc(nvHash.WantGroup) == perl.lc(wrongDir)
                            then
                                noWrite = true; break   -- GOTO !
                            else
                                -- remove this tag if found in this IFD
                                xDelete[newID] = 1
                            end
                        end
                    until true
                elseif not addDirs[newID] then
                    noWrite = true
                end
                if noWrite then
                    -- NoWrite:
                    if isNew > 0 then goto continue_entry end
                    set[newID] = nil
                    isNew = -1
                end
                if perlTruthy(set[newID]) then
--
-- set the new tag value (or 'next' if deleting tag)
--
                    newInfo = set[newID]
                    newCount = newInfo.Count
                    local val, newVal
                    local nvHash = Writer.GetNewValueHash(et, newInfo, dirName)
                    if isNew > 0 then
                        -- don't create new entry unless requested
                        if nvHash then
                            if not perlTruthy(nvHash.IsCreating) then goto continue_entry end
                            if newInfo.IsOverwriting then
                                local proc = newInfo.IsOverwriting
                                -- (port: the proc returns $$newValuePt as second result)
                                isOverwriting, newVal = proc(et, nvHash, val) -- luacheck: ignore 321 (upstream passes the undef $val)
                            else
                                isOverwriting = Writer.IsOverwriting(et, nvHash)
                            end
                        else
                            if xDelete[newID] then goto continue_entry end       -- don't create if cross deleting
                            newVal = mandatoryTbl[newID]  -- get value for mandatory tag
                            isOverwriting = 1
                        end
                        -- convert using new format
                        if newInfo.Format then
                            newFormName = newInfo.Format
                            -- use Writable flag to specify IFD format code
                            ifdFormName = newInfo.Writable
                        else
                            newFormName = newInfo.Writable
                            if not newFormName then
                                perl.warn("No format for " .. name .. " " .. newInfo.Name .. "\n")
                                goto continue_entry
                            end
                        end
                        newFormat = formatNumber[newFormName]
                    elseif nvHash or xDelete[newID] then
                        if not nvHash then
                            nvHash = Writer.GetNewValueHash(et, newInfo, wrongDir)
                        end
                        -- read value
                        if length(oldValue) >= oldSize then
                            val = ExifTool.ReadValue(oldValue, 0, readFormName, readCount, oldSize)
                        else
                            val = ''
                        end
                        -- determine write format (by default, use 'Writable' format)
                        local writable = newInfo.Writable
                        -- (or use existing format if 'Writable' not specified)
                        if not (perlTruthy(writable) and writable ~= '1' and writable ~= 1) then writable = oldFormName end
                        -- (and override write format with 'Format' if specified)
                        local writeForm = newInfo.Format or writable
                        if writeForm ~= newFormName then
                            -- write in specified format
                            newFormName = writeForm
                            newFormat = formatNumber[newFormName]
                            -- use different IFD format code if necessary
                            if inMakerNotes then
                                -- always preserve IFD format in maker notes
                                ifdFormName = oldFormName
                            elseif writable ~= newFormName then
                                -- use specified IFD format
                                ifdFormName = writable
                            end
                        end
                        if inMakerNotes and readFormName ~= 'string' and readFormName ~= 'undef' then
                            -- keep same size in maker notes unless string or binary
                            newCount = oldCount * formatSize[oldFormat] / formatSize[newFormat]
                        end
                        if newInfo.IsOverwriting then
                            local proc = newInfo.IsOverwriting
                            isOverwriting, newVal = proc(et, nvHash, val)
                        else
                            isOverwriting = Writer.IsOverwriting(et, nvHash, val)
                        end
                    end
                    if perlTruthy(isOverwriting) then
                        repeat -- (port: `goto NoOverwrite` is noOverwrite = true + break)
                            if newVal == nil then newVal = Writer.GetNewValue(et, nvHash) end
                            -- value undefined if deleting this tag
                            -- (also delete tag if cross-deleting and this isn't a date/time shift)
                            if newVal == nil or (xDelete[newID] and nvHash.Shift == nil) then
                                if newVal == nil and newInfo.RawConvInv and nvHash.Value ~= nil then
                                    -- error in RawConvInv, so rewrite existing tag
                                    noOverwrite = true; break -- GOTO!
                                end
                                if isNew == 0 then
                                    et.CHANGED = (et.CHANGED or 0) + 1
                                    et:VerboseValue("- " .. dirName .. ":" .. newInfo.Name, val)
                                end
                                goto continue_entry
                            end
                            if newCount and newCount < 0 then
                                -- set count to number of values if variable
                                local vals = split(' ',newVal)
                                newCount = #vals
                            end
                            -- convert to binary format
                            newValue = Writer.WriteValue(newVal, newFormName, newCount)
                            if newValue == nil then
                                et:Warn("Invalid value for " .. dirName .. ":" .. newInfo.Name)
                                noOverwrite = true; break -- GOTO!
                            end
                            if length(newValue) > 0 then
                                -- limit maximum value length in JPEG images
                                -- (max segment size is 65533 bytes and the min EXIF size is 96 incl an additional IFD entry)
                                if et.FILE_TYPE == 'JPEG' and length(newValue) > 65436 and
                                    newInfo.Name ~= 'PreviewImage'
                                then
                                    local nm = newInfo.MakerNotes and 'MakerNotes' or newInfo.Name
                                    et:Warn("Writing large value for " .. nm,1)
                                end
                                -- re-code if necessary
                                if newFormName == 'utf8' then
                                    newValue = et:Encode(newValue, 'UTF8')
                                elseif perlTruthy(strEnc) and newFormName == 'string' then
                                    newValue = et:Encode(newValue, strEnc)
                                end
                            else
                                et:Warn("Can't write zero length " .. newInfo.Name .. " in " .. tagTablePtr.GROUPS[1])
                                noOverwrite = true; break -- GOTO!
                            end
                            if isNew >= 0 then
                                newCount = length(newValue) / formatSize[newFormat]
                                et.CHANGED = (et.CHANGED or 0) + 1
                                if allMandatory ~= nil then
                                    -- not all mandatory if we are writing any tag specifically
                                    if nvHash then
                                        allMandatory = nil
                                        deleteAll = nil
                                    else
                                        addMandatory = addMandatory + 1    -- count mandatory tags that we added
                                    end
                                end
                                if perl.num(verbose) > 1 then
                                    if isNew == 0 then et:VerboseValue("- " .. dirName .. ":" .. newInfo.Name, val) end
                                    if newInfo.OffsetPair and perlStr(newVal) == '4277010157' then -- (0xfeedfeed)
                                        et.OPTIONS.TextOut:write("    + " .. dirName .. ":" .. newInfo.Name .. " = <tbd>\n")
                                    else
                                        local str = nvHash and '' or ' (mandatory)'
                                        et:VerboseValue("+ " .. dirName .. ":" .. newInfo.Name, newVal, str)
                                    end
                                end
                            end
                        until true
                    else
                        noOverwrite = true
                    end
                    if noOverwrite then
                        -- NoOverwrite:
                        if isNew > 0 then goto continue_entry end
                        isNew = -1        -- rewrite existing tag
                    end
                    -- set format for EXIF IFD if different than conversion format
                    if ifdFormName then
                        newFormName = ifdFormName
                        newFormat = formatNumber[newFormName]
                    end

                elseif isNew > 0 then
--
-- create new subdirectory
--
                    -- newInfo may not be defined if we try to add a mandatory tag
                    -- to a directory that doesn't support it (eg. IFD1 in RW2 images)
                    newInfo = addDirs[newID]
                    if not newInfo then goto continue_entry end
                    -- make sure we don't try to generate a new MakerNotes directory
                    -- or a SubIFD
                    if newInfo.MakerNotes or newInfo.Name == 'SubIFD' then goto continue_entry end
                    local subTable
                    if newInfo.SubDirectory and newInfo.SubDirectory.TagTable then
                        subTable = et:GetTagTable(newInfo.SubDirectory.TagTable)
                    else
                        subTable = tagTablePtr
                    end
                    -- create empty source directory
                    local sourceDir = {
                        Parent = dirName,
                        Fixup = Fixup.new(),
                    }
                    if newInfo.SubIFD then sourceDir.DirName = newInfo.Groups[1] end
                    newValue = Writer.WriteDirectory(et, sourceDir, subTable)
                    -- only add new directory if it isn't empty
                    if not (newValue ~= nil and length(newValue) > 0) then goto continue_entry end
                    -- set the fixup start location
                    if newInfo.SubIFD then
                        -- subdirectory is referenced by an offset in value buffer
                        local subdir = newValue
                        newValue = ExifTool.Put32u(0xfeedf00d)
                        subdirs[#subdirs + 1] = {
                            DataPt = subdir,
                            Table = subTable,
                            Fixup = sourceDir.Fixup,
                            Offset = length(dirBuff) + 8,
                            Where = 'dirBuff',
                        }
                        newFormName = 'int32u'
                        newFormat = formatNumber[newFormName]
                    else
                        -- subdirectory goes directly into value buffer
                        sourceDir.Fixup.Start = sourceDir.Fixup.Start + length(valBuff)
                        -- use Writable to set format, otherwise 'undef'
                        newFormName = newInfo.Writable
                        if not (perlTruthy(newFormName) and formatNumber[newFormName]) then
                            newFormName = 'undef'
                        end
                        newFormat = formatNumber[newFormName]
                        valFixups[#valFixups + 1] = sourceDir.Fixup
                    end
                elseif newInfo.Format and perlTruthy(newInfo.Writable) and newInfo.Writable ~= '1' and newInfo.Writable ~= 1 then
                    -- use specified write format
                    newFormName = newInfo.Writable
                    newFormat = formatNumber[newFormName]
                elseif addDirs[newID] and newInfo ~= addDirs[newID] then
                    -- this can happen if we are trying to add a directory that doesn't exist
                    -- in this type of file (eg. try adding a SubIFD tag to an A100 image)
                    isNew = -1
                end
            end
            if isNew < 0 then
                -- just rewrite existing tag
                newID = oldID
                newValue = oldValue
                newFormat = oldFormat -- (just in case it changed)
                newFormName = oldFormName
                -- set offset of this entry in the directory so we can update the pointer
                -- and save block information to copy this large block later
                if oldImageData then
                    oldImageData[4] = newStart + length(dirBuff) + 2
                    imageData[#imageData + 1] = oldImageData
                    origDirInfo.ImageData = imageData
                end
            end
            if newInfo then
--
-- load necessary data for this tag (thumbnail image, etc)
--
                if newInfo.DataTag and isNew >= 0 then
                    local dataTag = newInfo.DataTag
                    -- load data for this tag
                    if not (offsetData[dataTag] ~= nil or dataTag == 'LeicaTrailer') then
                        -- prefer tag from Composite table if it exists (otherwise
                        -- PreviewImage data would be taken from Extra tag)
                        local compInfo = ExifTool.GetCompositeTagInfo(dataTag)
                        offsetData[dataTag] = et:GetNewValue(compInfo or dataTag)
                        local err
                        if offsetData[dataTag] ~= nil then
                            local len = length(offsetData[dataTag])
                            if dataTag == 'PreviewImage' then
                                -- must set DEL_PREVIEW flag now if preview fit into IFD
                                if len <= 4 then et.DEL_PREVIEW = 1 end
                            end
                        else
                            err = dataTag .. " not found"
                        end
                        if err then
                            if newInfo.IsOffset then et:Warn(err) end
                            set[newID] = nil    -- remove from list of tags we are setting
                            goto continue_entry
                        end
                    end
                end
--
-- write maker notes
--
                if newInfo.MakerNotes then
                    -- don't write new makernotes if we are deleting this group
                    if et.DEL_GROUP.MakerNotes and
                       (et.DEL_GROUP.MakerNotes ~= 2 or isNew <= 0)
                    then
                        if perlTruthy(et:IsRawType()) and not (et:IsRawType() == 2 and dirName == 'ExifIFD') then
                            et:Warn("Can't delete MakerNotes from " .. perlStr(et.FileType),1)
                        else
                            if isNew <= 0 then
                                et.CHANGED = (et.CHANGED or 0) + 1
                                if perlTruthy(verbose) then out:write("  Deleting MakerNotes\n") end
                            end
                            goto continue_entry
                        end
                    end
                    local saveOrder = ExifTool.GetByteOrder()
                    if isNew >= 0 and set[newID] ~= nil then
                        -- we are writing a whole new maker note block
                        -- --> add fixup information if necessary
                        local nvHash = Writer.GetNewValueHash(et, newInfo, dirName)
                        if nvHash and nvHash.MAKER_NOTE_FIXUP then
                            -- must clone fixup because we will be shifting it
                            local makerFixup = nvHash.MAKER_NOTE_FIXUP:Clone()
                            local valLen = length(valBuff)
                            makerFixup.Start = makerFixup.Start + valLen
                            valFixups[#valFixups + 1] = makerFixup
                        end
                    else
                        -- update maker notes if possible
                        local subdirInfo = {
                            Base     = base,
                            DataPt   = valueDataPt,
                            DataPos  = valueDataPos,
                            DataLen  = valueDataLen,
                            DirStart = valuePtr,
                            DirLen   = oldSize,
                            DirName  = 'MakerNotes',
                            Name     = newInfo.Name,
                            Parent   = dirName,
                            TagInfo  = newInfo,
                            RAF      = raf,
                        }
                        local subTable, subdir, loc, writeProc, notIFD
                        if newInfo.SubDirectory then
                            local sub = newInfo.SubDirectory
                            if sub.FixBase then subdirInfo.FixBase = 1 end
                            subdirInfo.FixOffsets = sub.FixOffsets
                            subdirInfo.EntryBased = sub.EntryBased
                            if sub.Base ~= nil then subdirInfo.NoFixBase = 1 end
                            subdirInfo.AutoFix = sub.AutoFix
                            if sub.ByteOrder then ExifTool.SetByteOrder(sub.ByteOrder) end
                        end
                        -- get the proper tag table for these maker notes
                        if oldInfo and oldInfo.SubDirectory then
                            subTable = oldInfo.SubDirectory.TagTable
                            if subTable then subTable = et:GetTagTable(subTable) end
                            writeProc = oldInfo.SubDirectory.WriteProc
                            notIFD = oldInfo.NotIFD
                        else
                            et:Warn('Internal problem getting maker notes tag table')
                        end
                        if subTable and not writeProc then writeProc = subTable.WRITE_PROC end
                        if not subTable then subTable = tagTablePtr end
                        if writeProc and
                            writeProc == MakerNotes.WriteUnknownOrPreview and
                            perl.isMatch(oldValue, [[^\xff\xd8\xff]])
                        then
                            loc = 0
                        elseif not notIFD then
                            -- look for IFD-style maker notes
                            loc = MakerNotes.LocateIFD(et,subdirInfo)
                        end
                        if loc ~= nil then
                            -- we need fixup data for this subdirectory
                            subdirInfo.Fixup = Fixup.new()
                            -- rewrite maker notes
                            local changed = et.CHANGED
                            subdir = Writer.WriteDirectory(et, subdirInfo, subTable, writeProc)
                            if changed == et.CHANGED and subdirInfo.Fixup:IsEmpty() then
                                -- return original data if nothing changed and no fixups
                                subdir = nil
                            end
                        elseif subTable.PROCESS_PROC and
                                 subTable.PROCESS_PROC == ExifTool.ProcessBinaryData
                        then
                            local sub = oldInfo.SubDirectory
                            if sub.Start ~= nil then
                                --### eval Start ($valuePtr)
                                local start = sub.Start(et, nil, valuePtr)
                                loc = start - valuePtr
                                subdirInfo.DirStart = start
                                subdirInfo.DirLen = subdirInfo.DirLen - loc
                            else
                                loc = 0
                            end
                            -- rewrite maker notes
                            subdir = Writer.WriteDirectory(et, subdirInfo, subTable)
                        elseif notIFD then
                            if writeProc then
                                loc = 0
                                subdir = Writer.WriteDirectory(et, subdirInfo, subTable)
                            end
                        else
                            local msg = 'Maker notes could not be parsed'
                            if et.FILE_TYPE == 'JPEG' then
                                et:Warn(msg, 1)
                            else
                                et:Error(msg, 1)
                            end
                        end
                        if subdir ~= nil then
                            if length(subdir) == 0 then ExifTool.SetByteOrder(saveOrder); goto continue_entry end
                            local valLen = length(valBuff)
                            -- restore existing header and substitute the new
                            -- maker notes for the old value
                            -- (a carray while the fixups edit it, a string again below)
                            newValue = carray.new('char'):append(substr(oldValue, 0, loc), subdir)
                            local makerFixup = subdirInfo.Fixup
                            -- (Perl autovivifies the hash below when no Fixup was made)
                            if not makerFixup then makerFixup = Fixup.new(); subdirInfo.Fixup = makerFixup end
                            local previewInfo = et.PREVIEW_INFO
                            if perlTruthy(subdirInfo.Relative) then
                                -- apply a one-time fixup to $loc since offsets are relative
                                makerFixup.Start = makerFixup.Start + loc
                                -- shift all offsets to be relative to new base
                                local baseShift = valueDataPos + valuePtr + base - subdirInfo.Base
                                makerFixup.Shift = makerFixup.Shift + baseShift
                                makerFixup:ApplyFixup(newValue)
                                if previewInfo then
                                    -- remove all but PreviewImage fixup (since others shouldn't change)
                                    for k in pairs(makerFixup.Pointers or { }) do
                                        if not perl.isMatch(k, [[_PreviewImage$]]) then makerFixup.Pointers[k] = nil end
                                    end
                                    -- zero pointer so we can see how it gets shifted later
                                    makerFixup:SetMarkerPointers(newValue, 'PreviewImage', 0)
                                    -- set the pointer to the start of the EXIF information
                                    -- add preview image fixup to list of value fixups
                                    makerFixup.Start = makerFixup.Start + valLen
                                    valFixups[#valFixups + 1] = makerFixup
                                    previewInfo.BaseShift = baseShift
                                    previewInfo.Relative = 1
                                end
                            -- don't shift anything if relative flag set to zero (Pentax patch)
                            elseif subdirInfo.Relative == nil then
                                -- shift offset base if shifted in the original image or if FixBase
                                -- was used, but be careful of automatic FixBase with negative shifts
                                -- since they may lead to negative (invalid) offsets (casio_edit_problem.jpg)
                                local baseShift = base - subdirInfo.Base
                                if subdirInfo.AutoFix then
                                    baseShift = 0
                                elseif subdirInfo.FixBase and baseShift < 0 and
                                    -- allow negative base shift if offsets are bigger (PentaxOptioWP.jpg)
                                    (not perlTruthy(subdirInfo.MinOffset) or subdirInfo.MinOffset + baseShift < 0)
                                then
                                    local fixBase = et:Options('FixBase')
                                    if fixBase == nil then
                                        local str = perlTruthy(et:Options('IgnoreMinorErrors')) and 'ignored' or 'fix or ignore?'
                                        et:Error("MakerNotes offsets may be incorrect (" .. str .. ")", 1)
                                    elseif fixBase == '' then
                                        et:Warn('Fixed incorrect MakerNotes offsets')
                                        baseShift = 0
                                    end
                                end
                                makerFixup.Start = makerFixup.Start + valLen + loc
                                makerFixup.Shift = makerFixup.Shift + baseShift
                                -- permanently fix makernote offset errors
                                makerFixup.Shift = makerFixup.Shift + (subdirInfo.FixedBy or 0)
                                valFixups[#valFixups + 1] = makerFixup
                                if previewInfo and not previewInfo.NoBaseShift then
                                    previewInfo.BaseShift = baseShift
                                end
                            end
                            newValue = newValue:tostring()
                            newValuePtIsNew = true   -- write new value
                        end
                    end
                    ExifTool.SetByteOrder(saveOrder)

                -- process existing subdirectory unless we are overwriting it entirely
                elseif newInfo.SubDirectory and isNew <= 0 and not perlTruthy(isOverwriting)
                    -- don't edit directory if Writable is set to 0
                    and (newInfo.Writable == nil or perlTruthy(newInfo.Writable)) and
                    not newInfo.ReadFromRAF
                then

                    local subdir = newInfo.SubDirectory
                    if newInfo.SubIFD then
--
-- rewrite existing sub IFD's
--
                        local subTable = tagTablePtr
                        if subdir.TagTable then
                            subTable = et:GetTagTable(subdir.TagTable)
                        end
                        -- determine directory name for this IFD
                        local subdirName = newInfo.Groups and newInfo.Groups[1] or newInfo.Name
                        -- all makernotes directory names must be 'MakerNotes'
                        if subTable.GROUPS[0] == 'MakerNotes' then subdirName = 'MakerNotes' end
                        -- must handle sub-IFD's specially since the values
                        -- are actually offsets to subdirectories
                        if not perlTruthy(readCount) then   -- can't have zero count
                            if perlTruthy(et:Error(name .. " entry " .. index .. " has zero count", 2)) then return nil end
                            goto continue_entry
                        end
                        local writeCount = 0
                        newValue = carray.new('char')    -- reset value because we regenerate it below
                        for i = 0, readCount - 1 do
                            local off = i * formatSize[readFormat]
                            local val = ExifTool.ReadValue(valueDataPt, valuePtr + off,
                                                readFormName, 1, oldSize - off)
                            local subdirStart = val - dataPos
                            local subdirBase = base
                            local hdrLen
                            if subdir.Start ~= nil then
                                --### eval Start ($val)
                                local newStart = subdir.Start(et, val, valuePtr) -- luacheck: ignore 421 (as upstream)
                                if not ExifTool.IsInt(newStart) then
                                    et:Error("Bad subdirectory start for " .. newInfo.Name)
                                    goto continue_subifd
                                end
                                newStart = newStart - dataPos
                                hdrLen = newStart - subdirStart
                                subdirStart = newStart
                            end
                            if subdir.Base then
                                local start = subdirStart + dataPos
                                --### eval Base ($start,$base)
                                subdirBase = subdirBase + subdir.Base(et, val, start, base)
                            end
                            -- add IFD number if more than one
                            if i ~= 0 then subdirName = perl.subst(subdirName, [[\d*$]], perlStr(i)) end
                            do
                                local subdirInfo = {
                                    Base     = subdirBase,
                                    DataPt   = dataPt,
                                    DataPos  = dataPos - subdirBase + base,
                                    DataLen  = dataLen,
                                    DirStart = subdirStart,
                                    DirName  = subdirName,
                                    Name     = newInfo.Name,
                                    TagInfo  = newInfo,
                                    Parent   = dirName,
                                    Fixup    = Fixup.new(),
                                    RAF      = raf,
                                    Subdir   = subdir,
                                    -- set ImageData only for 1st level SubIFD's
                                    ImageData= imageDataFlag == 'Main' and 'SubIFD' or nil,
                                }
                                -- pass on header pointer only for certain sub IFD's
                                if newInfo.SubIFD == 2 then
                                    subdirInfo.HeaderPtr = dirInfo.HeaderPtr
                                end
                                if subdir.RelativeBase then
                                    -- apply one-time fixup if offsets are relative (Sony IDC hack)
                                    subdirInfo.Fixup = nil
                                    subdirInfo.ImageData = nil
                                end
                                -- is the subdirectory outside our current data?
                                if subdirStart < 0 or subdirStart + 2 > dataLen then
                                    if raf then
                                        -- reset SubDirectory buffer (we will load it later)
                                        local buff = ''
                                        subdirInfo.DataPt = buff
                                        subdirInfo.DataLen = 0
                                    else
                                        local err = { "Can't read " .. subdirName .. " data", inMakerNotes }
                                        if subTable.VARS and subTable.VARS.MINOR_ERRORS then
                                            et:Warn(err[1] .. '. Ignored.')
                                        elseif perlTruthy(et:Error(err[1], err[2])) then
                                            return nil
                                        end
                                        goto continue_entry -- don't write this directory
                                    end
                                end
                                local subdirData = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                                if subdirData == nil then
                                    -- WriteDirectory should have issued an error, but check just in case
                                    if not et.VALUE.Error then et:Error("Error writing " .. subdirName) end
                                    return nil
                                end
                                -- add back original header if necessary (eg. Ricoh GR)
                                if hdrLen and hdrLen > 0 and subdirStart <= dataLen then
                                    subdirData = substr(dataPt, subdirStart - hdrLen, hdrLen) .. subdirData
                                    subdirInfo.Fixup.Start = subdirInfo.Fixup.Start + hdrLen
                                end
                                if length(subdirData) == 0 then
                                    if not inMakerNotes then goto continue_subifd end
                                    -- don't delete MakerNote Sub-IFD's, write empty IFD instead
                                    subdirData = string.rep("\0", 6)
                                    -- reset SubIFD ImageData and Fixup just to be safe
                                    subdirInfo.ImageData = nil
                                    subdirInfo.Fixup = nil
                                end
                                -- handle data blocks that we will transfer later
                                if type(subdirInfo.ImageData) == 'table' then
                                    for _, blk in ipairs(subdirInfo.ImageData) do imageData[#imageData + 1] = blk end
                                    origDirInfo.ImageData = imageData
                                end
                                -- temporarily set value to subdirectory index
                                -- (will set to actual offset later when we know what it is)
                                newValue:append(ExifTool.Put32u(0xfeedf00d))
                                local offset, where
                                if readCount > 1 then
                                    offset = length(valBuff) + i * 4
                                    where = 'valBuff'
                                else
                                    offset = length(dirBuff) + 8
                                    where = 'dirBuff'
                                end
                                -- add to list of subdirectories we will append later
                                subdirs[#subdirs + 1] = {
                                    DataPt    = subdirData,
                                    Table     = subTable,
                                    Fixup     = subdirInfo.Fixup,
                                    Offset    = offset,
                                    Where     = where,
                                    ImageData = subdirInfo.ImageData,
                                }
                                writeCount = writeCount + 1  -- count number of subdirs written
                            end
                            ::continue_subifd::
                        end
                        newValue = newValue:tostring()  -- (a string again for the entry code below)
                        if length(newValue) == 0 then goto continue_entry end
                        -- must change location of subdir offset if we deleted
                        -- a directory and only one remains
                        if writeCount < readCount and writeCount == 1 then
                            subdirs[#subdirs].Where = 'dirBuff'
                            subdirs[#subdirs].Offset = length(dirBuff) + 8
                        end
                        -- set new format to int32u for IFD
                        newFormName = newInfo.FixFormat or 'int32u'
                        newFormat = formatNumber[newFormName]
                        newValuePtIsNew = true

                    elseif (subdir.Start == nil or
                             usesValuePtr(subdir.Start)) and
                             subdir.TagTable
                    then
--
-- rewrite other existing subdirectories ('$valuePtr' type only)
--
                        -- set subdirectory Start and Base
                        local subdirStart = valuePtr
                        if perlTruthy(subdir.Start) then
                            --### eval Start ($valuePtr)
                            subdirStart = subdir.Start(et, nil, valuePtr)
                            -- must adjust directory size if start changed
                            oldSize = oldSize - (subdirStart - valuePtr)
                        end
                        local subdirBase = base
                        if subdir.Base then
                            local start = subdirStart + valueDataPos
                            --### eval Base ($start,$base)
                            subdirBase = subdirBase + subdir.Base(et, nil, start, base)
                        end
                        local subFixup = Fixup.new()
                        local subdirInfo = {
                            Base     = subdirBase,
                            DataPt   = valueDataPt,
                            DataPos  = valueDataPos - subdirBase + base,
                            DataLen  = valueDataLen,
                            DirStart = subdirStart,
                            DirName  = subdir.DirName,
                            DirLen   = oldSize,
                            Parent   = dirName,
                            Fixup    = subFixup,
                            RAF      = raf,
                            TagInfo  = newInfo,
                        }
                        if not perlTruthy(oldSize) then
                            -- replace with dummy data if empty to prevent WriteDirectory
                            -- routines from accessing data they shouldn't
                            local tmp = ''
                            subdirInfo.DataPt = tmp
                            subdirInfo.DataLen = 0
                            subdirInfo.DirStart = 0
                            subdirInfo.DataPos = subdirInfo.DataPos + subdirStart
                        end
                        local subTable = et:GetTagTable(subdir.TagTable)
                        local oldOrder = ExifTool.GetByteOrder()
                        if subdir.ByteOrder then ExifTool.SetByteOrder(subdir.ByteOrder) end
                        newValue = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                        ExifTool.SetByteOrder(oldOrder)
                        if newValue ~= nil then
                            local hdrLen = subdirStart - valuePtr
                            if hdrLen ~= 0 then
                                newValue = substr(valueDataPt, valuePtr, hdrLen) .. newValue
                                subFixup.Start = subFixup.Start + hdrLen
                            end
                            newValuePtIsNew = true
                        else
                            newValuePtIsNew = false
                        end
                        if length(valPt()) == 0 then
                            -- don't delete a previously empty makernote directory
                            if perlTruthy(oldSize) or not inMakerNotes then goto continue_entry end
                        end
                        if subFixup.Pointers and subdirInfo.Base == base then
                            subFixup.Start = subFixup.Start + length(valBuff)
                            valFixups[#valFixups + 1] = subFixup
                        else
                            -- apply fixup in case we added a header ($hdrLen above)
                            -- (on a carray of the value, a string again afterwards)
                            if newValue ~= nil then
                                newValue = carray.new('char'):append(newValue)
                                subFixup:ApplyFixup(newValue)
                                newValue = newValue:tostring()
                            end
                        end
                    end

                elseif newInfo.OffsetPair then
--
-- keep track of offsets
--
                    local dataTag = newInfo.DataTag or ''
                    if dataTag == 'CanonVRD' then
                        -- must decide now if we will write CanonVRD information
                        local hasVRD
                        if et.NEW_VALUE and et.NEW_VALUE[ExifTool.Extra.CanonVRD] then
                            -- adding or deleting as a block
                            hasVRD = perlTruthy(et:GetNewValue('CanonVRD')) and 1 or 0
                        elseif et.DEL_GROUP.CanonVRD or
                                 et.DEL_GROUP.Trailer
                        then
                            hasVRD = 0    -- deleting as a group
                        else
                            hasVRD = (valPt() ~= "\0\0\0\0") and 1 or 0
                        end
                        if hasVRD == 1 then
                            -- add a fixup, and set this offset later
                            dirFixup:AddFixup(length(dirBuff) + 8, dataTag)
                        else
                            -- there is (or will soon be) no VRD information, so set pointer to zero
                            newValue = string.rep("\0", length(valPt()))
                            newValuePtIsNew = true
                        end
                    elseif dataTag == 'OriginalDecisionData' then
                        -- handle Canon OriginalDecisionData (no associated length tag)
                        -- - I'm going out of my way here to preserve data which is
                        --   invalidated anyway by our edits
                        local odd
                        local oddInfo = ExifTool.GetCompositeTagInfo('OriginalDecisionData')
                        if oddInfo and et.NEW_VALUE and et.NEW_VALUE[oddInfo] then
                            odd = et:GetNewValue(dataTag)
                            if perl.num(verbose) > 1 then
                                if valPt() ~= "\0\0\0\0" then out:write("    - " .. dirName .. ":" .. dataTag .. "\n") end
                                if perlTruthy(odd) then out:write("    + " .. dirName .. ":" .. dataTag .. "\n") end
                            end
                            et.CHANGED = (et.CHANGED or 0) + 1
                        elseif valPt() ~= "\0\0\0\0" then
                            if length(valPt()) == 4 then
                                local offset = ExifTool.Get32u(valPt(),0)
                                -- absolute offset in JPEG images only
                                if et.FILE_TYPE ~= 'JPEG' then offset = offset + base end
                                odd = require('lexiftool.Canon').ReadODD(et, offset)
                                if type(odd) == 'table' then odd = odd.value end
                            else
                                et:Error("Invalid " .. newInfo.Name,1)
                            end
                        end
                        if perlTruthy(odd) then
                            local newOffset = length(valBuff)
                            -- (ODD offset is absolute in JPEG, so add base offset!)
                            if et.FILE_TYPE == 'JPEG' then newOffset = newOffset + base end
                            newValue = ExifTool.Put32u(newOffset)
                            dirFixup:AddFixup(length(dirBuff) + 8, dataTag)
                            valBuff:append(odd)   -- add original decision data
                        else
                            newValue = "\0\0\0\0"
                        end
                        newValuePtIsNew = true
                    else
                        local offInfo = offsetInfo[ifd]
                        -- save original values (for updating TIFF_END later)
                        local vals = { }
                        if isNew <= 0 then
                            local oldOrder = ExifTool.GetByteOrder()
                            -- Minolta A200 stores these in the wrong byte order!
                            if newInfo.ByteOrder then ExifTool.SetByteOrder(newInfo.ByteOrder) end
                            vals = ExifTool.ReadValue(oldValue, 0, readFormName, readCount, oldSize, nil, true)
                            ExifTool.SetByteOrder(oldOrder)
                            if not newInfo.IsOffset then validateInfo[newID] = { newInfo, perl.join(' ',vals) } end
                        end
                        -- only support int32 pointers (for now)
                        if formatSize[newFormat] ~= 4 and newInfo.IsOffset then
                            if isNew > 0 then perl.warn("Internal error (Offset not int32)"); return nil end
                            if newCount ~= readCount then perl.warn("Wrong count!"); return nil end
                            -- change to int32
                            newFormName = 'int32u'
                            newFormat = formatNumber[newFormName]
                            newValue = Writer.WriteValue(perl.join(' ',vals), newFormName, newCount)
                            if newValue == nil then
                                perl.warn("Internal error writing offsets for " .. newInfo.Name .. "\n")
                                return nil
                            end
                            newValuePtIsNew = true
                        end
                        if not offInfo then
                            offInfo = { }
                            offsetInfo[ifd] = offInfo
                            if ifd > lastOffsetInfo then lastOffsetInfo = ifd end
                        end
                        -- save location of valuePtr in new directory
                        -- (notice we add 10 instead of 8 for valuePtr because
                        -- we will put a 2-byte count at start of directory later)
                        local ptr = newStart + length(dirBuff) + 10
                        if not perlTruthy(newCount) then newCount = 1 end -- make sure count is set for offsetInfo
                        -- save value pointer and value count for each tag
                        offInfo[newID] = { newInfo, ptr, newCount, vals, newFormat }
                    end

                elseif newInfo.DataMember then

                    -- save any necessary data members (Make, Model, etc)
                    local formatStr = newFormName
                    local count = newCount
                    -- change to specified format if necessary
                    if newInfo.Format and newInfo.Format ~= formatStr then
                        formatStr = newInfo.Format
                        local format = formatNumber[formatStr]
                        -- adjust number of items for new format size
                        if format then count = perl.int(length(valPt()) / formatSize[format]) end
                    end
                    local val = ExifTool.ReadValue(valPt(),0,formatStr,count,length(valPt()))
                    local conv = newInfo.RawConv
                    if conv then
                        -- let the RawConv store the (possibly converted) data member
                        -- (port: the ported RawConv is a function taking ($self, $val))
                        conv(et, val)
                    else
                        et[newInfo.DataMember] = val
                    end
                end
            end
--
-- write out the directory entry
--
            do
                local newSize = length(valPt())
                local fsize = formatSize[newFormat]
                local offsetVal
                -- set proper count
                if not (oldInfo and oldInfo.FixedSize) then newCount = perl.int((newSize + fsize - 1) / fsize) end
                if Exif.saveForValidate[newID] and tagTablePtr == Exif.Main then
                    local vals = ExifTool.ReadValue(newValue, 0, newFormName, newCount, newSize, nil, true)
                    validateInfo[newID] = perl.join(' ',vals)
                end
                if newSize > 4 then
                    -- zero-pad to an even number of bytes (required by EXIF standard)
                    -- and make sure we are a multiple of the format size
                    while newSize & 0x01 ~= 0 or newSize < newCount * fsize do
                        setValPt(valPt() .. "\0")
                        newSize = newSize + 1
                    end
                    local entryBased
                    if perlTruthy(dirInfo.EntryBased) or (newInfo and perlTruthy(newInfo.EntryBased)) then
                        entryBased = 1
                        offsetVal = ExifTool.Put32u(length(valBuff) - length(dirBuff))
                    else
                        offsetVal = ExifTool.Put32u(length(valBuff))
                    end
                    local dataTag, putFirst
                    if newInfo then dataTag, putFirst = newInfo.DataTag, newInfo.PutFirst end
                    if dataTag then
                        if dataTag == 'PreviewImage' and (et.FILE_TYPE == 'JPEG' or
                            et.GENERATE_PREVIEW_INFO)
                        then
                            -- hold onto the PreviewImage until we can determine if it fits
                            if not et.PREVIEW_INFO then
                                et.PREVIEW_INFO = {
                                    Data = valPt(),
                                    Fixup = Fixup.new(),
                                }
                            end
                            if newInfo.ChangeBase then et.PREVIEW_INFO.ChangeBase = 1 end
                            if newInfo.IsOffset and perlStr(newInfo.IsOffset) == '2' then
                                et.PREVIEW_INFO.NoBaseShift = 1
                            end
                            -- use original preview size if we will attempt to load it later
                            if valPt() == 'LOAD_PREVIEW' then newCount = oldCount end
                            setValPt('')
                        elseif dataTag == 'LeicaTrailer' and et.LeicaTrailer then
                            setValPt('')
                        end
                    end
                    if putFirst and dirInfo.HeaderPtr then
                        local hdrPtr = dirInfo.HeaderPtr
                        -- place this value immediately after the TIFF header (eg. IIQ maker notes)
                        offsetVal = ExifTool.Put32u(length(hdrPtr))
                        hdrPtr:append(valPt())
                    else
                        valBuff:append(valPt())       -- add value data to buffer
                        -- must save a fixup pointer for every pointer in the directory
                        if entryBased then
                            if not entryBasedFixup then entryBasedFixup = Fixup.new() end
                            entryBasedFixup:AddFixup(length(dirBuff) + 8, dataTag)
                        else
                            dirFixup:AddFixup(length(dirBuff) + 8, dataTag)
                        end
                    end
                else
                    offsetVal = valPt()      -- save value in offset if 4 bytes or less
                    -- must pad value with zeros if less than 4 bytes
                    if newSize < 4 then offsetVal = offsetVal .. string.rep("\0", 4 - newSize) end
                end
                -- write the directory entry
                dirBuff:append(ExifTool.Put16u(newID) .. ExifTool.Put16u(newFormat) ..
                            ExifTool.Put32u(newCount) .. offsetVal)
                -- update flag to keep track of mandatory tags
                while allMandatory ~= nil do
                    if mandatoryTbl[newID] ~= nil then
                        -- values must correspond to mandatory values
                        local form = newInfo.Format or newFormName
                        local mandVal = Writer.WriteValue(mandatoryTbl[newID], form, newCount)
                        if mandVal ~= nil and mandVal == valPt() then
                            allMandatory = allMandatory + 1        -- count mandatory tags
                            break
                        end
                    end
                    deleteAll = nil
                    allMandatory = nil
                end
            end
            ::continue_entry::
        end
        if next(validateInfo) ~= nil then
            WriteExif.ValidateImageData(et, validateInfo, dirName, 1)
            validateInfo = { }
        end
        if ignoreCount then
            local y = ignoreCount > 1 and 'ies' or 'y'
            local verb = dirInfo.FixBase and 'Ignored' or 'Removed'
            et:Warn(verb .. " " .. ignoreCount .. " invalid entr" .. y .. " from " .. name, 1)
        end
        if fixCount then
            local s = fixCount > 1 and 's' or ''
            et:Warn("Fixed invalid count" .. s .. " for " .. fixCount .. " " .. name .. " tag" .. s, 1)
        end
--..............................................................................
-- write directory counts and nextIFD pointer and add value data to end of IFD
--
        -- determine now if there is or will be another IFD after this one
        local nextIfdOffset
        if dirEnd + 4 <= dataLen then
            nextIfdOffset = ExifTool.Get32u(dataPt, dirEnd)
        else
            nextIfdOffset = 0
        end
        local isNextIFD = (dirInfo.Multi and (nextIfdOffset ~= 0 or
                        -- account for the case where we will create the next IFD
                        -- (IFD1 only, but not in TIFF-format images)
                        (dirName == 'IFD0' and et.ADD_DIRS and et.ADD_DIRS['IFD1'] and
                         et.FILE_TYPE ~= 'TIFF')))
        -- calculate number of entries in new directory
        local newEntries = length(dirBuff) / 12
        -- delete entire directory if we deleted a tag and only mandatory tags remain or we
        -- attempted to create a directory with only mandatory tags and there is no nextIFD
        if perlTruthy(allMandatory) and not isNextIFD and (newEntries < numEntries or numEntries == 0) then
            newEntries = 0
            dirBuff = carray.new('char')
            valBuff = carray.new('char')
            dirFixup = nil    -- no fixups in this directory
            if deleteAll ~= nil then deleteAll = deleteAll + 1 end
            if perl.num(verbose) > 1 then out:write("    - " .. allMandatory .. " mandatory tag(s)\n") end
            et.CHANGED = (et.CHANGED or 0) - addMandatory    -- didn't change these after all
        end
        if ifd ~= 0 and newEntries == 0 then
            if perlTruthy(verbose) then out:write("  Deleting IFD1\n") end
            break   -- don't write IFD1 if empty
        end
        -- apply one-time fixup for entry-based offsets
        if entryBasedFixup then
            entryBasedFixup.Shift = length(dirBuff) + 4
            entryBasedFixup:ApplyFixup(dirBuff)
            entryBasedFixup = nil -- luacheck: ignore 311 (as upstream)
        end
        -- initialize next IFD pointer to zero
        local nextIFD = ExifTool.Put32u(0)
        -- some cameras use a different amount of padding after the makernote IFD
        if dirName == 'MakerNotes' and perl.isMatch(dirInfo.Parent, [[^(ExifIFD|IFD0)$]]) then
            local _, offs = MakerNotes.GetMakerNoteOffset(et)
            local pad = offs and offs[1]
            if pad ~= nil and (pad==0 or (pad>4 and pad<=32)) then nextIFD = string.rep("\0", pad) end
        end
        -- add directory entry count to start of IFD and next IFD pointer to end
        newData:append(ExifTool.Put16u(newEntries), dirBuff, nextIFD)
        -- get position of value data in newData
        local valPos = newData:len()
        -- go back now and set next IFD pointer if this isn't the first IFD
        if perlTruthy(nextIfdPos) then
            -- set offset to next IFD
            ExifTool.Set32u(newData, nextIfdPos, newStart)
            fixup:AddFixup(nextIfdPos,'NextIFD')    -- add fixup for this offset in newData
        end
        -- remember position of 'next IFD' pointer so we can set it next time around
        if length(nextIFD) > 0 then nextIfdPos = valPos - length(nextIFD) else nextIfdPos = nil end
        -- add value data after IFD
        newData:append(valBuff)
--
-- add any subdirectories, adding fixup information
--
        if #subdirs > 0 then
            for _, subdir in ipairs(subdirs) do
                local len = newData:len()         -- position of subdirectory in data
                local subdirFixup = subdir.Fixup
                if subdirFixup then
                    subdirFixup.Start = subdirFixup.Start + len
                    fixup:AddFixup(subdirFixup)
                end
                local subImageData = subdir.ImageData
                local blockSize = 0
                -- must also update start position for ImageData fixups
                if type(subImageData) == 'table' then
                    for _, blockInfo in ipairs(subImageData) do
                        local size, pad, subFix = blockInfo[2], blockInfo[3], blockInfo[5]
                        if subFix then
                            subFix.Start = subFix.Start + len
                            -- save expected image data offset for calculating shift later
                            subFix.BlockLen = length(subdir.DataPt) + blockSize
                        end
                        blockSize = blockSize + size + pad
                    end
                end
                newData:append(subdir.DataPt)    -- add subdirectory to our data
                subdir.DataPt = nil          -- free memory now
                -- set the pointer
                local offset = subdir.Offset
                -- if offset is in valBuff, it was added to the end of dirBuff
                -- (plus 4 bytes for nextIFD pointer)
                if subdir.Where == 'valBuff' then offset = offset + length(dirBuff) + 4 end
                offset = offset + newStart + 2           -- get offset in newData
                -- check to be sure we got the right offset
                if ExifTool.Get32u(newData, offset) ~= 0xfeedf00d then
                    et:Error("Internal error while rewriting " .. name)
                    return nil
                end
                -- set the offset to the subdirectory data
                ExifTool.Set32u(newData, offset, len)
                fixup:AddFixup(offset)  -- add fixup for this offset in newData
            end
        end
        -- add fixup for all offsets in directory according to value data position
        -- (which is at the end of this directory)
        if dirFixup then
            dirFixup.Start = newStart + 2
            dirFixup.Shift = valPos - dirFixup.Start
            fixup:AddFixup(dirFixup)
        end
        -- add valueData fixups, adjusting for position of value data
        for _, valFixup in ipairs(valFixups) do
            valFixup.Start = valFixup.Start + valPos
            fixup:AddFixup(valFixup)
        end
        -- stop if no next IFD pointer
        if not isNextIFD then break end   -- stop unless scanning for multiple IFD's
        if nextIfdOffset ~= 0 then
            -- continue with next IFD
            dirStart = nextIfdOffset - dataPos
        else
            -- create IFD1 if necessary
            if perlTruthy(verbose) then out:write("  Creating IFD1\n") end
            local ifd1 = string.rep("\0", 2)  -- empty IFD1 data (zero entry count)
            dataPt = ifd1
            dirStart = 0
            dirLen = 2;  dataLen = 2
        end
        -- increment IFD name
        do
            local ifdNum = 0
            local found, num = perl.isMatch(dirName, [[(\d+)$]])
            if found then
                ifdNum = tonumber(num)
                dirName = perl.subst(dirName, [[(\d+)$]], '')
            end
            dirName = dirName .. (ifdNum + 1)
            name = perl.subst(name, [[\d+$]], '')
            name = name .. (ifdNum + 1)
        end
        et.DIR_NAME = dirName;  et.PATH[#et.PATH] = dirName
        if nextIfdOffset == 0 then goto continue_ifd end

        -- guard against writing the same directory twice
        do
            local addr = nextIfdOffset + base
            if et.PROCESSED[addr] then
                et:Error(name .. " pointer references previous " .. et.PROCESSED[addr] .. " directory", 1)
                break
            end
            et.PROCESSED[addr] = name
        end

        if dirName == 'SubIFD1' and not perlTruthy(WriteExif.ValidateIFD(dirInfo, dirStart)) then
            if et.TIFF_TYPE == 'TIFF' then
                et:Error('Ignored bad IFD linked from SubIFD', 1)
            elseif perlTruthy(verbose) then
                et:Warn('Ignored bad IFD linked from SubIFD')
            end
            break   -- don't write bad IFD
        end
        if perlTruthy(et.DEL_GROUP[dirName]) then
            if perlTruthy(verbose) then out:write("  Deleting " .. dirName .. "\n") end
            if raf then et:Error("Deleting " .. dirName .. " also deletes subsequent" ..
                                      " IFD's and possibly image data", 1) end
            et.CHANGED = (et.CHANGED or 0) + 1
            if et.DEL_GROUP[dirName] == 2 and
                et.ADD_DIRS[dirName]
            then
                local emptyIFD = string.rep("\0", 2)    -- start with empty IFD
                dataPt = emptyIFD
                dirStart = 0
                dirLen = 2;  dataLen = 2
            else
                break   -- don't write this IFD (or any subsequent IFD)
            end
        else
            if perlTruthy(verbose) then out:write("  Rewriting " .. name .. "\n") end
        end
        ::continue_ifd::
        ifd = ifd + 1
    end
--~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    -- do our fixups now so we can more easily calculate offsets below
    fixup:ApplyFixup(newData)
    -- write Sony HiddenData now if this is an ARW file
    if et.HiddenData and not dirInfo.Fixup and et.FILE_TYPE == 'TIFF' then
        fixup:SetMarkerPointers(newData, 'HiddenData', newData:len())
        local hbuf
        local hd = et.HiddenData
        local ok = raf:Seek(hd.Offset, 0)
        if ok then
            local n
            n, hbuf = raf:Read(hd.Size)
            ok = (n == hd.Size) and perl.isMatch(hbuf, [[^\x55\x26\x11\x05\0]])
        end
        if ok then
            newData:append(hbuf)
        else
            et:Error('Error copying hidden data', 1)
        end
    end
--
-- determine total block size for deferred data
--
    local numBlocks = #imageData  -- save this so we scan only existing blocks later
    local blockSize = 0  -- total size of blocks to copy later
    for _, blockInfo in ipairs(imageData) do
        local size, pad = blockInfo[2], blockInfo[3]
        blockSize = blockSize + size + pad
    end
--
-- copy over image data for IFD's, starting with the last IFD first
--
    if lastOffsetInfo >= 0 then
        local ttwLen     -- length of MRW TTW segment
        local writeLater = { } -- write image data last
        ifd = lastOffsetInfo
        while ifd >= -1 do
            -- build list of offsets to process
            local offsetList = { }
            if ifd >= 0 then
                dirName = dirInfo.DirName or 'unknown'
                if ifd ~= 0 then
                    dirName = perl.subst(dirName, [[\d+$]], '')
                    dirName = dirName .. ifd
                end
                local offInfo = offsetInfo[ifd]
                if not offInfo then goto continue_offifd end
                if offInfo[0x111] and offInfo[0x144] then
                    -- SubIFD may contain double-referenced data as both strips and tiles
                    -- for Sony ARW files when SonyRawFileType is "Lossless Compressed RAW 2"
                    if dirName == 'SubIFD' and et.TIFF_TYPE == 'ARW' and
                        offInfo[0x117] and offInfo[0x145] and
                        offInfo[0x111][3]==1 -- (must be a single strip or the tile offsets could get out of sync)
                    then
                        -- check the start offsets to see if they are the same
                        if tonumber(offInfo[0x111][4][1]) == tonumber(offInfo[0x144][4][1]) then
                            -- some Sony ARW images contain double-referenced raw data stored as both strips
                            -- and tiles.  Copy the data using only the strip tags, but store the TileOffets
                            -- information for updating later (see PanasonicRaw:PatchRawDataOffset for a
                            -- description of offsetInfo elements)
                            offInfo[0x111][6] = offInfo[0x144] -- hack to save TileOffsets
                            -- delete tile information from offsetInfo because we will copy as strips
                            offInfo[0x144] = nil
                            offInfo[0x145] = nil
                        end
                    else
                        et:Error("TIFF " .. dirName .. " contains both strip and tile data")
                    end
                end
                -- patch Panasonic RAW/RW2 StripOffsets/StripByteCounts if necessary
                local stripOffsets = offInfo[0x111]
                local rawDataOffset = offInfo[0x118]
                if stripOffsets and stripOffsets[1].PanasonicHack or
                    rawDataOffset and rawDataOffset[1].PanasonicHack
                then
                    local err = require('lexiftool.PanasonicRaw').PatchRawDataOffset(offInfo, raf, ifd)
                    if err then et:Error(err) end
                end
                -- loop through all tags in reverse numerical order so we save thumbnail
                -- data before main image data if both exist in the same IFD
                local tagIDs = { }
                for tagID in pairs(offInfo) do tagIDs[#tagIDs + 1] = tagID end
                tsort(tagIDs, function(a, b) return a > b end)
                for _, tagID in ipairs(tagIDs) do
                    local tagInfo = offInfo[tagID][1]
                    if not tagInfo.IsOffset then goto continue_tag end -- handle byte counts with offsets
                    do
                        local sizeInfo = offInfo[tagInfo.OffsetPair]
                        if not sizeInfo then
                            et:Error("No size tag for " .. dirName .. ":" .. tagInfo.Name)
                            goto continue_tag
                        end
                        local dataTag = tagInfo.DataTag
                        -- write TIFF image data (strips or tiles) later if requested
                        if raf and origDirInfo.ImageData ~= nil and
                            (tagID == 0x111 or tagID == 0x144 or
                              -- also defer writing of other big data such as JpgFromRaw in NEF
                              (perlTruthy(sizeInfo[4][1]) and
                               -- (calculate approximate combined size of all blocks)
                               sizeInfo[4][1] * #sizeInfo[4] > 1000000)) and
                            -- but don't defer writing if replacing with new value
                            (dataTag == nil or offsetData[dataTag] == nil)
                        then
                            writeLater[#writeLater + 1] = { offInfo[tagID], sizeInfo }
                        else
                            offsetList[#offsetList + 1] = { offInfo[tagID], sizeInfo }
                        end
                    end
                    ::continue_tag::
                end
            else
                if #writeLater == 0 then break end
                -- finally, copy all deferred data
                offsetList = writeLater
            end
            for _, offsetPair in ipairs(offsetList) do
                local tagInfo, offsets, count, oldOffset = offsetPair[1][1], offsetPair[1][2], offsetPair[1][3], offsetPair[1][4]
                local cntInfo, byteCounts, count2, oldSz, format = offsetPair[2][1], offsetPair[2][2], offsetPair[2][3], offsetPair[2][4], offsetPair[2][5]
                -- must be the same number of offset and byte count values
                if count ~= count2 then
                    et:Error("Offsets/ByteCounts disagree on count for " .. tagInfo.Name)
                    return nil
                end
                local formatStr = formatName[format]
                -- follow pointer to value data if necessary
                if count > 1 then offsets = ExifTool.Get32u(newData, offsets) end
                local n = count * formatSize[format]
                if n > 4 then byteCounts = ExifTool.Get32u(newData, byteCounts) end
                if byteCounts < 0 or byteCounts + n > newData:len() then
                    et:Error("Error reading " .. tagInfo.Name .. " byte counts")
                    return nil
                end
                -- get offset base and data pos (abnormal for some preview images)
                local dbase, dpos, wrongBase, subIfdDataFixup
                if perlStr(tagInfo.IsOffset) == '2' then
                    dbase = firstBase
                    dpos = dataPos + base - firstBase
                else
                    dbase = base
                    dpos = dataPos
                end
                -- use different base if necessary for some offsets (Minolta A200)
                if tagInfo.WrongBase then
                    local self = et
                    --### eval WrongBase ($self)
                    wrongBase = tagInfo.WrongBase(self) or 0
                    dbase = dbase + wrongBase
                    dpos = dpos - wrongBase
                else
                    wrongBase = 0
                end
                local oldOrder = ExifTool.GetByteOrder()
                local dataTag = tagInfo.DataTag
                -- use different byte order for values of this offset pair if required (Minolta A200)
                if tagInfo.ByteOrder then ExifTool.SetByteOrder(tagInfo.ByteOrder) end
                -- transfer the data referenced by all offsets of this tag
                n = 0
                while n < count do
                    local oldEnd, size
                    if #oldOffset > 0 and #oldSz > 0 then
                        -- calculate end offset of this block
                        oldEnd = oldOffset[n+1] + oldSz[n+1]
                        -- update TIFF_END as if we read this data from file
                        WriteExif.UpdateTiffEnd(et, oldEnd + dbase)
                    end
                    local offsetPos = offsets + n * 4
                    local byteCountPos = byteCounts + n * formatSize[format]
                    if tagInfo.PanasonicHack then
                        -- use actual raw data length (may be different than StripByteCounts!)
                        size = oldSz[n+1]
                    else
                        -- use size of new data
                        size = ExifTool.ReadValue(newData, byteCountPos, formatStr, 1, 4)
                    end
                    local offset = oldOffset[n+1]
                    if offset ~= nil then
                        offset = offset - dpos
                    elseif size ~= 0xfeedfeed then
                        et:Error('Internal error (no offset)')
                        return nil
                    end
                    local newOffset = newData:len() - wrongBase
                    local buff
                    -- (port: `$raf->Read($buff,$size) == $size` inside the elsif chain)
                    local function readBuff(sz)
                        local nr
                        nr, buff = raf:Read(sz)
                        return nr == sz
                    end
                    -- look for 'feed' code to use our new data
                    if size == 0xfeedfeed then
                        if dataTag == nil then
                            et:Error("No DataTag defined for " .. tagInfo.Name)
                            return nil
                        end
                        if offsetData[dataTag] == nil then
                            et:Error("Internal error (no " .. dataTag .. ")")
                            return nil
                        end
                        if count > 1 then
                            et:Error("Can't modify " .. tagInfo.Name .. " with count " .. count)
                            return nil
                        end
                        buff = offsetData[dataTag]
                        if formatSize[format] ~= 4 then
                            et:Error(cntInfo.Name .. " is not int32")
                            return nil
                        end
                        -- set the data size
                        size = length(buff)
                        ExifTool.Set32u(newData, byteCountPos, size)
                    elseif ifd < 0 then
                        -- hack for fixed-offset data (Panasonic GH6)
                        if offsetPair[1][7] then
                            if count > 1 then
                                et:Error("Can't handle fixed offsets with count > 1")
                            else
                                local fixedOffset = ExifTool.Get32u(newData, offsets)
                                local padToFixedOffset = fixedOffset - (newOffset + dpos)
                                -- account for blocks that come before this (Pansonic DC-S1RM2, forum17319)
                                for _, blk in ipairs(imageData) do padToFixedOffset = padToFixedOffset - (blk[2] + blk[3]) end
                                if padToFixedOffset < 0 then
                                    et:Error('Metadata too large to fit before fixed-offset image data')
                                else
                                    -- add necessary padding before raw data
                                    imageData[#imageData + 1] = { offset+dbase+dpos, 0, padToFixedOffset }
                                    newOffset = newOffset + padToFixedOffset
                                    et:Warn("Adding " .. padToFixedOffset .. " bytes of padding before fixed-offset image data", 1)
                                end
                            end
                        end
                        -- pad if necessary (but don't pad contiguous image blocks)
                        local pad = 0
                        if (blockSize + size) & 0x01 ~= 0 and (n+1 >= count or
                                  not perlTruthy(oldEnd) or oldEnd ~= oldOffset[n+2]) then
                            pad = pad + 1
                        end
                        -- preserve original image padding if specified
                        if origDirInfo.PreserveImagePadding and n+1 < count and
                            perlTruthy(oldEnd) and oldOffset[n+2] > oldEnd
                        then
                            pad = oldOffset[n+2] - oldEnd
                        end
                        -- copy data later
                        imageData[#imageData + 1] = { offset+dbase+dpos, size, pad }
                        newOffset = newOffset + blockSize   -- data comes after other deferred data
                        -- create fixup for SubIFD ImageData
                        if imageDataFlag == 'SubIFD' and not subIfdDataFixup then
                            subIfdDataFixup = Fixup.new()
                            imageData[#imageData][5] = subIfdDataFixup
                        end
                        size = size + pad -- account for pad byte if necessary
                        -- return ImageData list
                        origDirInfo.ImageData = imageData
                    elseif offset >= 0 and offset+size <= dataLen then
                        -- take data from old dir data buffer
                        buff = substr(dataPt, offset, size)
                    elseif et.TIFF_TYPE == 'MRW' then
                        -- TTW segment must be an even 4 bytes long, so pad now if necessary
                        local nn = newData:len()
                        buff = (nn & 0x03 ~= 0) and string.rep("\0", 4 - (nn & 0x03)) or ''
                        size = length(buff)
                        -- data exists after MRW TTW segment
                        if ttwLen == nil then ttwLen = newData:len() + size end
                        newOffset = offset + dpos + ttwLen - dataLen
                    elseif raf and raf:Seek(offset+dbase+dpos,0) and
                             readBuff(size)
                    then
                        -- (data was read OK)
                        -- patch incorrect ThumbnailOffset in Sony A100 1.00 ARW images
                        if et.TIFF_TYPE == 'ARW' and tagInfo.Name == 'ThumbnailOffset' and
                            et.Model == 'DSLR-A100' and not perl.isMatch(buff, [[^\xff\xd8\xff]])
                        then
                            local pos = offset + dbase + dpos
                            local try
                            local ok = pos < 0x10000 and raf:Seek(pos+0x10000,0)
                            if ok then
                                local nr
                                nr, try = raf:Read(size)
                                ok = nr == size and perl.isMatch(try, [[^\xff\xd8\xff]])
                            end
                            if ok then
                                buff = try
                                et:Warn('Adjusted incorrect A100 ThumbnailOffset', 1)
                            else
                                et:Error('Invalid ThumbnailImage')
                            end
                        end
                    elseif tagInfo.Name == 'ThumbnailOffset' and offset>=0 and offset<dataLen then
                        -- Grrr.  The Canon 350D writes the thumbnail with an incorrect byte count
                        local diff = offset + size - dataLen
                        et:Warn("ThumbnailImage runs outside EXIF data by " .. diff .. " bytes (truncated)",1)
                        -- set the size to the available data
                        size = size - diff
                        if not Writer.WriteValue(size, formatStr, 1, newData, byteCountPos) then
                            perl.warn('Internal error writing thumbnail size')
                        end
                        -- get the truncated image
                        buff = substr(dataPt, offset, size)
                    elseif tagInfo.Name == 'PreviewImageStart' and et.FILE_TYPE == 'JPEG' then
                        -- try to load the preview image using the specified offset
                        buff = nil
                        local r = et.RAF
                        if r and not raf then
                            local tell = r:Tell()
                            -- read and validate
                            local ok = r:Seek(offset+base+dataPos,0)
                            if ok then
                                local nr
                                nr, buff = r:Read(size)
                                ok = nr == size and perl.isMatch(buff, [==[(?s)^.\xd8\xff[\xc4\xdb\xe0-\xef]]==])
                            end
                            if not ok then buff = nil end
                            if not r:Seek(tell, 0) then et:Error('Seek error'); return nil end
                        end
                        -- set flag if we must load PreviewImage
                        if buff == nil then buff = 'LOAD_PREVIEW' end
                    else
                        local dataName = dataTag or tagInfo.Name
                        if perlTruthy(et:Error("Error reading " .. dataName .. " data in " .. name, inMakerNotes)) then return nil end
                        buff = ''
                    end
                    if tagInfo.Name == 'PreviewImageStart' then
                        if et.FILE_TYPE == 'JPEG' and not tagInfo.MakerPreview then
                            if perlTruthy(size) then
                                -- hold onto the PreviewImage until we can determine if it fits
                                if not et.PREVIEW_INFO then
                                    et.PREVIEW_INFO = {
                                        Data = buff,
                                        Fixup = Fixup.new(),
                                    }
                                end
                                if tagInfo.IsOffset and perlStr(tagInfo.IsOffset) == '2' then
                                    et.PREVIEW_INFO.NoBaseShift = 1
                                end
                                if offset >= 0 and offset+size <= dataLen then
                                    -- set flag indicating this preview wasn't in a trailer
                                    et.PREVIEW_INFO.WasContained = 1
                                end
                            end
                            buff = ''
                        elseif et.TIFF_TYPE == 'ARW' and et.Model  == 'DSLR-A100' then
                            -- the A100 double-references the same preview, so ignore the
                            -- second one (the offset and size will be patched later)
                            if et.A100PreviewLength then goto continue_n end
                            if buff ~= nil then et.A100PreviewLength = length(buff) end
                        end
                    end
                    -- update offset accordingly and add to end of new data
                    ExifTool.Set32u(newData, offsetPos, newOffset)
                    -- add a pointer to fix up this offset value (marked with DataTag name)
                    fixup:AddFixup(offsetPos, dataTag)
                    -- also add to subIfdDataFixup if necessary
                    if subIfdDataFixup then subIfdDataFixup:AddFixup(offsetPos, dataTag) end
                    -- must also (sometimes) update StripOffsets in Panasonic RW2 images
                    -- and TileOffsets in Sony ARW images
                    do
                        local otherPos = offsetPair[1][6]
                        if otherPos then
                            if tagInfo.PanasonicHack then
                                ExifTool.Set32u(newData, otherPos, newOffset)
                                fixup:AddFixup(otherPos, dataTag)
                            elseif type(otherPos) == 'table' then
                                -- the image data was copied as one large strip, and is double-referenced
                                -- as tile data, so all we need to do now is properly update the tile offsets
                                local oldRawDataOffset = offsetPair[1][4][1]
                                local cnt = otherPos[3]
                                -- point to offsets in value data if more than one pointer
                                if cnt > 1 then otherPos[2] = ExifTool.Get32u(newData, otherPos[2]) end
                                for i = 0, cnt - 1 do
                                    local oldTileOffset = otherPos[4][i+1]
                                    local ptrPos = otherPos[2] + 4 * i
                                    ExifTool.Set32u(newData, ptrPos, newOffset + oldTileOffset - oldRawDataOffset)
                                    fixup:AddFixup(ptrPos, dataTag)
                                    if subIfdDataFixup then subIfdDataFixup:AddFixup(ptrPos, dataTag) end
                                end
                            end
                        end
                    end
                    if ifd >= 0 then
                        -- buff length must be even (Note: may have changed since $size was set)
                        if length(buff) & 0x01 ~= 0 then buff = buff .. "\0" end
                        newData:append(buff)      -- add this strip to the data
                    else
                        blockSize = blockSize + size    -- keep track of total size
                    end
                    ::continue_n::
                    n = n + 1
                end
                ExifTool.SetByteOrder(oldOrder)
            end
            ::continue_offifd::
            ifd = ifd - 1
        end
        -- verify that nothing else got written after determining TTW length
        if ttwLen ~= nil and ttwLen ~= newData:len() then
            et:Error('Internal error writing MRW TTW')
        end
    end
--
-- set offsets and generate fixups for tag values which were too large for memory
--
    blockSize = 0
    for _, blockInfo in ipairs(imageData) do
        local size, pad, entry, subFix = blockInfo[2], blockInfo[3], blockInfo[4], blockInfo[5]
        if entry ~= nil then
            local format = ExifTool.Get16u(newData, entry + 2)
            if format < 1 or format > 13 then
                et:Error('Internal error copying huge value')
                break
            else
                -- set count and offset in directory entry
                ExifTool.Set32u(newData, entry + 4, size / formatSize[format])
                ExifTool.Set32u(newData, entry + 8, newData:len()+blockSize)
                fixup:AddFixup(entry + 8)
                -- create special fixup for SubIFD data
                if imageDataFlag == 'SubIFD' then
                    local subIfdDataFixup = Fixup.new()
                    subIfdDataFixup:AddFixup(entry + 8)
                    -- save fixup in imageData list
                    blockInfo[5] = subIfdDataFixup
                end
                -- must reset entry pointer so we don't use it again in a parent IFD!
                blockInfo[4] = nil
            end
        end
        -- apply additional shift required for contained SubIFD image data offsets
        if subFix and subFix.BlockLen ~= nil and numBlocks > 0 then
            -- our offset expects the data at the end of the SubIFD block (BlockLen + Start),
            -- but it will actually be at length($newData) + $blockSize.  So adjust
            -- accordingly (and subtract an extra Start because this shift is applied later)
            subFix.Shift = subFix.Shift + newData:len() - subFix.BlockLen - 2 * subFix.Start + blockSize
            subFix:ApplyFixup(newData)
        end
        blockSize = blockSize + size + pad
        numBlocks = numBlocks - 1
    end
--
-- apply final shift to new data position if this is the top level IFD
--
    if not dirInfo.Fixup then
        local hdrPtr = dirInfo.HeaderPtr
        local newDataPos = hdrPtr and length(hdrPtr) or dirInfo.NewDataPos or 0
        -- adjust CanonVRD offset to point to end of regular TIFF if necessary
        -- (NOTE: This will be incorrect if multiple trailers exist,
        --  but it is unlikely that it could ever be correct in this case anyway.
        --  Also, this doesn't work for JPEG images (but CanonDPP doesn't set
        --  this when editing JPEG images anyway))
        fixup:SetMarkerPointers(newData, 'CanonVRD', newData:len() + blockSize)
        if newDataPos ~= 0 then
            fixup.Shift = fixup.Shift + newDataPos
            fixup:ApplyFixup(newData)
        end
        -- save fixup for adjusting Leica trailer and Sony HiddenData offsets if necessary
        if et.LeicaTrailer then et.LeicaTrailer.Fixup:AddFixup(fixup) end
        if et.HiddenData then et.HiddenData.Fixup:AddFixup(fixup) end
        -- save fixup for PreviewImage in JPEG file if necessary
        local previewInfo = et.PREVIEW_INFO
        if previewInfo then
            local pt = previewInfo.Data -- image data or 'LOAD_PREVIEW' flag
            -- now that we know the size of the EXIF data, first test to see if our new image fits
            -- inside the EXIF segment (remember about the TIFF and EXIF headers: 8+6 bytes)
            if (pt ~= 'LOAD_PREVIEW' and length(pt) + newData:len() + 14 <= 0xfffd and
                not previewInfo.IsTrailer) or
                previewInfo.IsShort -- must fit in this segment if using short pointers
            then
                -- It fits! (or must exist in EXIF segment), so fixup the
                -- PreviewImage pointers and stuff the preview image in here
                local newPos = newData:len() + newDataPos
                newPos = newPos + (previewInfo.BaseShift or 0)
                if previewInfo.Relative then
                    -- calculate our base by looking at how far the pointer got shifted
                    newPos = newPos - (fixup:GetMarkerPointers(newData, 'PreviewImage')[1] or 0)
                end
                fixup:SetMarkerPointers(newData, 'PreviewImage', newPos)
                newData:append(pt)
                -- set flag to delete old preview unless it was contained in the EXIF
                if not et.PREVIEW_INFO.WasContained then et.DEL_PREVIEW = 1 end
                et.PREVIEW_INFO = nil   -- done with our preview data
            else
                -- Doesn't fit, or we still don't know, so save fixup information
                -- and put the preview at the end of the file
                if not previewInfo.Fixup then previewInfo.Fixup = Fixup.new() end
                previewInfo.Fixup:AddFixup(fixup)
            end
        elseif newData and perlTruthy(deleteAll) then
            newData = carray.new('char')  -- delete both IFD0 and IFD1 since only mandatory tags remain
        elseif et.A100PreviewLength then
            -- save preview image start for patching A100 quirks later
            et.A100PreviewStart = fixup:GetMarkerPointers(newData, 'PreviewImage')[1]
        end
        -- save location of last IFD for use in Canon RAW header
        if newDataPos == 16 then
            local ifdPos = fixup:GetMarkerPointers(newData,'NextIFD')
            origDirInfo.LastIFD = table.remove(ifdPos)
        end
        -- recrypt SR2 SubIFD data if necessary
        local key = et.SR2SubIFDKey
        if key then
            local start = fixup:GetMarkerPointers(newData, 'SR2SubIFDOffset')[1]
            local len = et.SR2SubIFDLength
            -- (must subtract 8 for size of TIFF header)
            if perlTruthy(start) and start - 8 + len <= newData:len() then
                local Sony = require('lexiftool.Sony')
                newData = carray.new('char'):append(
                    Sony.Decrypt(newData:tostring(), start - 8, len, key))
            end
        end
    end
    -- return empty string if no entries in directory
    -- (could be up to 10 bytes and still be empty)
    if newData and newData:len() < 12 then newData = carray.new('char') end

    -- set changed if ForceWrite tag was set to "EXIF"
    if newData and newData:len() > 0 and et.FORCE_WRITE and et.FORCE_WRITE.EXIF then
        et.CHANGED = (et.CHANGED or 0) + 1
    end

    return newData:tostring()    -- return our directory data
end

return WriteExif
