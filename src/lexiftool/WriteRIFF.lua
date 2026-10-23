--------------------------------------------------------------------------------
-- File:         lexiftool/WriteRIFF.lua
-- Ported from:  lib/Image/ExifTool/WriteRIFF.pl
--
-- Description:  Write RIFF-format files
--
-- Revisions:    2020-09-26 - P. Harvey Created
--
-- Notes:        Currently writes only WEBP files
--
-- References:   https://developers.google.com/speed/webp/docs/riff_container
--
-- Port notes:   The whole of WriteRIFF.pl (the %webpMap/%deletableGroup
--               lookups and WriteRIFF).  Upstream compiles the file into the
--               Image::ExifTool::RIFF package and AUTOLOADs it on the first
--               call of WriteRIFF; this port makes it a module of its own,
--               and RIFF.lua binds RIFF.WriteRIFF to a closure that loads
--               this file on first use.
--
--               Scalar references: `$dataPt = \$buff` aliases the chunk
--               buffer, so where upstream then shortens $buff (the
--               incorrect "Exif\0\0" header) the port assigns dataPt again.
--               `Set32u($val, \$buff, $pos)` edits the RIFF header in place;
--               so the header and the VP8X buffer are carrays from the
--               Read on (Perl's mutable scalar, doc/api.md §4).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local length = perl.length
local substr = perl.substr
local carray = require('carray')
local isMatch = perl.isMatch
local tr = perl.tr
local pack, unpack = perl.pack, perl.unpack
local truthy = perl.truthy
local Get16u, Get32u = ExifTool.Get16u, ExifTool.Get32u
local Set32u = ExifTool.Put32u  -- (upstream's one-argument Set32u($val))
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local Write = Writer.Write

local RIFF = require('lexiftool.RIFF')  -- (upstream `package Image::ExifTool::RIFF`)
local WriteRIFF = {}

-- map of where information is stored in WebP image
local webpMap = {
   ['XMP ']      = 'RIFF', -- (the RIFF chunk name is 'XMP ')
    EXIF         = 'RIFF',
    ICCP         = 'RIFF',
    C2PA         = 'RIFF',
    JUMBF        = 'C2PA',
    XMP          = 'XMP ',
    IFD0         = 'EXIF',
    IFD1         = 'IFD0',
    ICC_Profile  = 'ICCP',
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}

local deletableGroup = {
    ["XMP\0"] = 'XMP', -- delete incorrectly written "XMP\0" tag with XMP group
    SEAL = 'SEAL',   -- delete SEAL tag with SEAL group
}

--------------------------------------------------------------------------------
-- Write RIFF file (currently WebP-type only)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid RIFF file, or -1 if
--          an output file was specified and a write error occurred
function WriteRIFF.WriteRIFF(et, dirInfo)
    if not et then return 1 end    -- allow dummy access to autoload this package
    local outfile = dirInfo.OutFile
    local outsize = 0
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local buff, err, has, dirDat, imageWidth, imageHeight
    has, dirDat = { }, { }

    -- do this in 2 passes so we can set the size of the containing RIFF chunk
    -- without having to buffer the output (also to set the WebP_Flags)
    local pass = 0
    while true do
        local doneDir = { }
        local n
        -- verify this is a valid RIFF file
        n, buff = raf:Read(12)
        if n ~= 12 then return 0 end
        buff = carray.new('char'):append(buff)    -- (Set32u edits it in place below)
        local isRIFF, m1, m2 = isMatch(buff, [[(?s)^(RIFF|RF64)....(.{4})]])
        if not isRIFF then return 0 end

        if not (m1 == 'RIFF' and m2 == 'WEBP') then
            local type = m2
            type = tr(type, '-_a-zA-Z', '', 'dc')
            et:Error("Can't currently write " .. m1 .. ' ' .. type .. ' files')
            return 1
        end
        SetByteOrder('II')

        -- determine which directories we must write for this file type
        if pass > 0 then et:Options('Verbose', 0) end   -- (avoid duplicate Verbose options here)
        Writer.InitWriteDirs(et, webpMap)
        local addDirs = et.ADD_DIRS
        local editDirs = et.EDIT_DIRS
        if addDirs.EXIF then addDirs.IFD0 = 'EXIF' end -- set flag to add IFD0 if adding EXIF (don't ask)
        local createVP8X, deleteVP8X

        -- write header
        if pass > 0 then
            et:Options('Verbose', verbose)
            local needsVP8X = (has.ANIM or has['XMP '] or has.EXIF or
                               has.ALPH or has.ICCP)
            if has.VP8X and not needsVP8X and truthy(et.CHANGED) then
                deleteVP8X = 1    -- delete the VP8X chunk
                outsize = outsize - 18     -- account for missing VP8X
            elseif needsVP8X and not has.VP8X then
                if imageWidth ~= nil then
                    et.CHANGED = (et.CHANGED or 0) + 1
                    createVP8X = 1    -- add VP8X chunk
                    outsize = outsize + 18     -- account for VP8X size
                else
                    et:Warn('Error getting image size for required VP8X chunk')
                end
            end
            -- finally we can set the overall RIFF chunk size:
            ExifTool.Set32u(buff, 4, outsize - 8)
            if not Write(outfile, buff) then err = 1 end
            -- create VP8X chunk if necessary
            if createVP8X then
                et:VPrint(0, "  Adding required VP8X chunk (Extended WEBP)\n")
                local flags = 0
                if has.ANIM then flags = flags | 0x02 end
                if has['XMP '] then flags = flags | 0x04 end
                if has.EXIF then flags = flags | 0x08 end
                if has.ALPH then flags = flags | 0x10 end
                if has.ICCP then flags = flags | 0x20 end
                Write(outfile, 'VP8X', pack('V3v', 10, flags,
                    (imageWidth - 1) | (((imageHeight - 1) & 0xff) << 24),
                    (imageHeight - 1) >> 8))
                -- write ICCP after VP8X
                if dirDat.ICCP then
                    if not Write(outfile, dirDat.ICCP) then err = 1 end
                end
            end
        else
            outsize = outsize + length(buff)
        end
        local pos = 12
--
-- Read chunks in RIFF image
--
        while true do
            local tag, len
            local num
            num, buff = raf:Read(8)
            if num < 8 then
                if num ~= 0 then et:Error('RIFF format error') return 1 end
                -- all done if we hit end of file unless we need to add EXIF or XMP
                if not (addDirs.EXIF or addDirs['XMP '] or addDirs.ICCP) then break end
                -- continue to add required EXIF or XMP chunks
                num, len = 0, 0 -- luacheck: ignore 311 (upstream `$num = $len = 0`)
                buff, tag = '', ''
            else
                pos = pos + 8
                tag, len = unpack('a4V', buff)
                if len <= 0 then
                    if len < 0 then
                        et:Error('Invalid chunk length')
                        return 1
                    elseif tag == "\0\0\0\0" then
                        -- avoid reading through corrupted files filled with nulls because it takes forever
                        et:Error('Encountered empty null chunk. Processing aborted')
                        return 1
                    else -- (just in case a tag may have no data)
                        if pass > 0 then
                            if not Write(outfile, buff) then err = 1 end
                        else
                            outsize = outsize + length(buff)
                        end
                        goto continue
                    end
                end
            end
            do
            -- RIFF chunks are padded to an even number of bytes
            local len2 = len + (len & 0x01)
            -- handle incorrect "XMP\0" chunk ID written by Google software
            if deletableGroup[tag] then
                if et.DEL_GROUP[deletableGroup[tag]] then
                    -- just ignore this chunk if deleting the associated group
                    if not raf:Seek(len2, 1) then et:Error('Seek error') break end
                    if pass > 0 then et:VPrint(0, '  Deleting ' .. deletableGroup[tag] .. "\n") end
                    et.CHANGED = (et.CHANGED or 0) + 1
                    goto continue
                elseif tag == "XMP\0" then
                    if pass > 0 then et:Warn('Incorrect XMP tag ID', 1) end
                end
            end
            -- edit/add/delete necessary metadata chunks (EXIF must come before XMP)
            if editDirs[tag] or tag == '' or (tag == 'XMP ' and addDirs.EXIF) then
                local handledTag
                if len2 ~= 0 then
                    if doneDir[tag] and pass == 0 then et:Warn("Duplicate '" .. tag .. "' chunk") end
                    doneDir[tag] = 1
                    local n2
                    n2, buff = raf:Read(len2)
                    if n2 ~= len2 then et:Error("Truncated '" .. tag .. "' chunk") break end
                    pos = pos + len2  -- update current position
                else
                    buff = ''
                end
--
-- add/edit/delete EXIF/XMP/ICCP (note: EXIF must come before XMP, and ICCP is written elsewhere)
--
                local dirName = { EXIF = 'IFD0', ['XMP '] = 'XMP', ICCP = 'ICC_Profile', C2PA = 'JUMBF' }
                local tblName = { EXIF = 'Exif', ['XMP '] = 'XMP', ICCP = 'ICC_Profile', C2PA = 'Jpeg2000' }
                for _, dir in ipairs({ 'EXIF', 'XMP ', 'ICCP', 'C2PA' }) do
                    if not (tag == dir or (addDirs[dir] and
                        (tag == '' or (tag == 'XMP ' and dir == 'EXIF')))) then goto nextDir end
                    do
                        local start
                        if pass == 0 then
                            -- write the EXIF and save the result for the next pass
                            local dataPt = buff
                            if tag == 'EXIF' then
                                -- (only need to set directory $start for EXIF)
                                if isMatch(buff, [[^Exif\0\0]]) then
                                    if et.DEL_GROUP.EXIF then
                                        -- remove incorrect header if rewriting anyway
                                        buff = substr(buff, 6)
                                        dataPt = buff
                                        len = len - 6
                                        len2 = len2 - 6
                                    else
                                        if pass == 0 then et:Warn('Improper EXIF header', 1) end
                                        start = 6
                                    end
                                else
                                    start = 0
                                end
                            elseif dir ~= tag then
                                -- create from scratch
                                local buf2 = ''
                                dataPt = buf2
                            end
                            -- write the new directory to memory
                            local subdirInfo = {   -- (upstream `my %dirInfo`; dirInfo is our argument)
                                DataPt   = dataPt,
                                DataPos  = 0,      -- (relative to Base)
                                DirStart = start,
                                Base     = pos - len2,
                                Parent   = dir,
                                DirName  = dirName[dir],
                            }
                            -- must pass the TagInfo to enable deletion of C2PA information
                            -- (`ref ... eq 'HASH'`: a conditional list is a Lua array)
                            if type(RIFF.Main[dir]) == 'table' and RIFF.Main[dir][1] == nil then
                                subdirInfo.TagInfo = RIFF.Main[dir]
                            end
                            local tagTablePtr = GetTagTable(nil, 'lexiftool.' .. tblName[dir] .. '.Main')
                            -- (override writeProc for EXIF because it has the TIFF header)
                            local writeProc = dir == 'EXIF' and Writer.WriteTIFF or nil
                            dirDat[dir] = Writer.WriteDirectory(et, subdirInfo, tagTablePtr, writeProc)
                        end
                        addDirs[dir] = nil -- (don't try to add again)
                        if dirDat[dir] ~= nil then
                            if dir == tag then
                                handledTag = 1    -- set flag indicating we edited this tag
                                -- increment CHANGED count if we are deleting the directory
                                if not truthy(length(dirDat[dir])) then et.CHANGED = (et.CHANGED or 0) + 1 end
                            end
                            if truthy(length(dirDat[dir])) then
                                if pass > 0 then
                                    -- write metadata chunk now (but not ICCP because it was added earlier)
                                    if dir ~= 'ICCP' then
                                        if not Write(outfile, dirDat[dir]) then err = 1 end
                                    end
                                else
                                    -- preserve (incorrect EXIF) header if it existed
                                    local hdr = truthy(start) and substr(buff, 0, start) or ''
                                    -- (don't overwrite $len here because it may be XMP length)
                                    local dirLen = length(dirDat[dir]) + length(hdr)
                                    -- add chunk header and padding
                                    local pad = (dirLen & 0x01) ~= 0 and "\0" or ''
                                    dirDat[dir] = dir .. Set32u(dirLen) .. hdr .. dirDat[dir] .. pad
                                    outsize = outsize + length(dirDat[dir])
                                    has[dir] = 1
                                end
                            end
                        end
                    end
                    ::nextDir::
                end
--
-- just copy XMP, EXIF or ICC if nothing changed
--
                if not handledTag and truthy(length(buff)) then
                    -- write the chunk without changes
                    if pass > 0 then
                        if not Write(outfile, tag, Set32u(len), buff) then err = 1 end
                    else
                        outsize = outsize + 8 + length(buff)
                        has[tag] = 1
                    end
                end
                goto continue
            end
            pos = pos + len2  -- set read position at end of chunk data
--
-- update necessary flags in VP8X chunk
--
            if tag == 'VP8X' then
                local buf2, n2
                if len2 >= 10 then n2, buf2 = raf:Read(len2) end
                if len2 < 10 or n2 ~= len2 then
                    et:Error('Truncated VP8X chunk')
                    return 1
                end
                buf2 = carray.new('char'):append(buf2)    -- (Set32u edits it in place below)
                if pass > 0 then
                    if deleteVP8X then
                        et:VPrint(0, "  Deleting unnecessary VP8X chunk (Standard WEBP)\n")
                        goto continue
                    end
                    -- ...but first set the VP8X flags
                    local flags = Get32u(buf2, 0)
                    flags = flags & ~0x2c -- (reset flags for everything we can write)
                    if has['XMP '] then flags = flags | 0x04 end
                    if has.EXIF then flags = flags | 0x08 end
                    if has.ICCP then flags = flags | 0x20 end
                    ExifTool.Set32u(buf2, 0, flags)
                    if not Write(outfile, buff, buf2) then err = 1 end
                else
                    -- get the image size
                    imageWidth  = (Get32u(buf2, 4) & 0xffffff) + 1
                    imageHeight = (Get32u(buf2, 6) >> 8) + 1
                    outsize = outsize + 8 + len2
                    has[tag] = 1
                end
                -- write ICCP after VP8X
                if dirDat.ICCP then
                    if not Write(outfile, dirDat.ICCP) then err = 1 end
                end
                goto continue
            end
--
-- just copy all other chunks
--
            if pass > 0 then
                -- write chunk header (still in $buff)
                if not Write(outfile, buff) then err = 1 end
            else
                outsize = outsize + length(buff)
                has[tag] = 1
            end
            if not (pass > 0 or imageWidth ~= nil) then
                -- get WebP image size from VP8 or VP8L header
                if tag == 'VP8 ' and len2 >= 16 then
                    local n2
                    n2, buff = raf:Read(16)
                    if n2 ~= 16 then et:Error('Truncated VP8 chunk') return 1 end
                    outsize = outsize + 16
                    if isMatch(buff, [[(?s)^...\x9d\x01\x2a]]) then
                        imageWidth  = Get16u(buff, 6) & 0x3fff
                        imageHeight = Get16u(buff, 8) & 0x3fff
                    end
                    len2 = len2 - 16
                elseif tag == 'VP8L' and len2 >= 6 then
                    local n2
                    n2, buff = raf:Read(6)
                    if n2 ~= 6 then et:Error('Truncated VP8L chunk') return 1 end
                    outsize = outsize + 6
                    if isMatch(buff, [[(?s)^\x2f]]) then
                        local word = Get32u(buff, 2)
                        imageWidth  =  (Get16u(buff, 1) & 0x3fff) + 1
                        imageHeight = ((word >> 6) & 0x3fff) + 1
                        if (word & 0x100000) ~= 0 then has.ALPH = 1 end -- set alpha flag if necessary
                    end
                    len2 = len2 - 6
                end
            end
            if pass > 0 then
                -- copy the chunk data in 64k blocks
                while len2 ~= 0 do
                    local num2 = len2
                    if num2 > 65536 then num2 = 65536 end
                    local n2
                    n2, buff = raf:Read(num2)
                    if n2 ~= num2 then et:Error('Truncated RIFF chunk') break end
                    if not Write(outfile, buff) then err = 1 break end
                    len2 = len2 - num2
                end
            else
                if not raf:Seek(len2, 1) then et:Error('Seek error') break end
                outsize = outsize + len2
            end
            end
            ::continue::
        end
        if pass > 0 then break end
        if not raf:Seek(0, 0) then et:Error('Seek error') break end
        pass = pass + 1
    end
    return err and -1 or 1
end

return WriteRIFF -- end
