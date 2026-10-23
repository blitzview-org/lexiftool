--------------------------------------------------------------------------------
-- File:         lexiftool/FLIF.lua
-- Ported from:  lib/Image/ExifTool/FLIF.pm
--
-- Description:  Read/write FLIF meta information
--
-- Revisions:    2016/10/11 - P. Harvey Created
--               2016/10/14 - PH Added write support
--
-- References:   1) http://flif.info/
--               2) https://github.com/FLIF-hub/FLIF/blob/master/doc/metadata
--
-- Port notes:   complete (read and write).  IO::Uncompress::RawInflate
--               and IO::Compress::RawDeflate are ExifTool.inflateRaw/
--               deflateRaw over the required rock compress.zlib (the
--               `eval { require ... }` checks are ExifTool:hasZlib()).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local perlNum = require('lexiftool.perl').num
local lt = require('lexiftool.perl').lt
local Writer = require('lexiftool.Writer')
local Write = Writer.Write

local FLIF = {}

-- map of where information is stored in FLIF image
local flifMap = {
    EXIF         = 'FLIF',
    XMP          = 'FLIF',
    ICC_Profile  = 'FLIF',
    IFD0         = 'EXIF',
    IFD1         = 'IFD0',
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}

-- FLIF tags
FLIF.Main = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    VARS = { ID_FMT = 'dec' },
    NOTES = [[
        Information extracted from Free Lossless Image Format files.  See
        L<http://flif.info/> for more information.
    ]],
--
-- header information
--
    [0] = {
        Name = 'ImageType',
        PrintConv = {
            ['1'] = 'Grayscale (non-interlaced)',
            ['3'] = 'RGB (non-interlaced)',
            ['4'] = 'RGBA (non-interlaced)',
            A = 'Grayscale (interlaced)',
            C = 'RGB (interlaced)',
            D = 'RGBA (interlaced)',
            Q = 'Grayscale Animation (non-interlaced)',
            S = 'RGB Animation (non-interlaced)',
            T = 'RGBA Animation (non-interlaced)',
            a = 'Grayscale Animation (interlaced)',
            c = 'RGB Animation (interlaced)',
            d = 'RGBA Animation (interlaced)',
        },
    },
    [1] = {
        Name = 'BitDepth',
        PrintConv = {
            ['0'] = 'Custom',
            ['1'] = 8,
            ['2'] = 16,
        },
    },
    [2] = 'ImageWidth',
    [3] = 'ImageHeight',
    [4] = 'AnimationFrames',
    [5] = {
        Name = 'Encoding',
        PrintConv = {
            [0] = 'FLIF16',
        },
    },
--
-- metadata chunks
--
    iCCP = {
        Name = 'ICC_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    eXif = {
        Name = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            -- (upstream's Image::ExifTool::WriteTIFF is the *directory*
            --  writer; this port has it as Writer.WriteTIFF, because
            --  ExifTool.WriteTIFF is already the file-wide TIFF writer here)
            WriteProc = Writer.WriteTIFF,
            Start = 6, -- (skip "Exif\0\0" header)
            Header = "Exif\0\0",
        },
    },
    eXmp = {
        Name = 'XMP',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
        },
    },
    -- tRko - list of truncation offsets
    -- \0 - FLIF16-format image data
}

--------------------------------------------------------------------------------
-- Read variable-length FLIF integer
-- Inputs: 0) raf reference, 1) number to add to returned value
-- Returns: integer, or undef on EOF
--------------------------------------------------------------------------------
function FLIF.GetVarInt(raf, add)
    local val = 0
    while true do
        local n, buff = raf:Read(1)
        if n ~= 1 then return nil end
        local byte = buff:byte()
        val = (val << 7) | (byte & 0x7f)
        if byte & 0x80 == 0 then break end
    end
    return val + (add or 0)
end

--------------------------------------------------------------------------------
-- Construct variable-length FLIF integer
-- Inputs: 0) integer
-- Returns: FLIF variable-length integer byte stream
--------------------------------------------------------------------------------
function FLIF.SetVarInt(val)
    local buff = ''
    local high = 0
    while true do
        buff = string.char((val & 0x7f) | high) .. buff
        val = val >> 7
        if val == 0 then break end
        high = 0x80
    end
    return buff
end

--------------------------------------------------------------------------------
-- Read FLIF header
-- Inputs: 0) RAF ref, 1) flag to return the binary header block instead
-- Returns: header values table indexed from 0 (type, depth, width, height,
--          [frames]) -- upstream's list context -- or, with `scalar` set, the
--          binary header block (upstream's scalar context, used by WriteFLIF);
--          nil if this isn't a valid FLIF file header
--------------------------------------------------------------------------------
function FLIF.ReadFLIFHeader(raf, scalar)
    -- verify this is a valid FLIF file
    local n, buff = raf:Read(6)
    if n ~= 6 then return nil end
    -- (upstream pattern `/^FLIF([0-\x6f])([0-2])/`: the type char runs from
    -- '0' up through 0x6f; Lua character classes have no ranges, so match
    -- "not 0x70-0xff" instead -- every byte below '0' is excluded by the
    -- FLIF literal already consuming positions 1-4)
    local typeByte, depthByte = buff:match('^FLIF([^\x70-\xff])([0-2])')
    if not typeByte then return nil end

    -- decode header information ("FLIF" chunk)
    local vals = {}
    vals[0] = typeByte                                 -- type
    vals[1] = depthByte                                -- depth
    vals[2] = FLIF.GetVarInt(raf, 1)                   -- width (+1)
    vals[3] = FLIF.GetVarInt(raf, 1)                   -- height (+1)
    if lt('H', vals[0]) then                              -- frames (+2)
        vals[4] = FLIF.GetVarInt(raf, 2)
    end

    -- upstream: `return () unless defined $vals[-1];` -- every varint read
    -- that was made must have succeeded (GetVarInt returns undef on EOF)
    if vals[2] == nil or vals[3] == nil then return nil end
    if lt('H', vals[0]) and vals[4] == nil then return nil end
    if not scalar then return vals end      -- return the decoded header values

    -- return the binary header block
    local hdrLen = raf:Tell()
    if not raf:Seek(0, 0) then return nil end
    local n2, hdr = raf:Read(hdrLen)
    if n2 ~= hdrLen then return nil end
    return hdr
end

--------------------------------------------------------------------------------
-- WriteFLIF : Write FLIF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid FLIF file, or -1 if
--          an output file was specified and a write error occurred
--------------------------------------------------------------------------------
function FLIF.WriteFLIF(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, soi
    local addTags, doneTag = { }, { }

    -- verify FLIF header and copy it to the output file
    buff = FLIF.ReadFLIFHeader(raf, true)
    if not buff then return 0 end
    local outfile = dirInfo.OutFile
    if not Write(outfile, buff) then return -1 end

    Writer.InitWriteDirs(et, flifMap)
    local tagTablePtr = et:GetTagTable('lexiftool.FLIF.Main')

    -- loop through the FLIF chunks
    while true do
        local tag, size, inflated
        -- read new tag (or soi) unless we already hit the soi (start of image)
        if soi == nil then
            local n
            n, buff = raf:Read(4)
            if n ~= 4 then et:Error('Unexpected EOF') break end
            if lt(buff, ' ') then
                soi = buff  -- we have hit the start of image (no more metadata)
                -- make list of new tags to add
                for _, t in ipairs({ 'eXif', 'eXmp', 'iCCP' }) do
                    if et.ADD_DIRS[tagTablePtr[t].Name] and not doneTag[t] then
                        addTags[#addTags + 1] = t
                    end
                end
            end
        end
        if soi == nil then
            tag = buff
            size = FLIF.GetVarInt(raf)  -- read the data size
        elseif #addTags > 0 then
            tag = table.remove(addTags, 1)
            buff, size = '', 0          -- create metadata from scratch
        else
            -- finish copying file (no more metadata to add)
            if not Write(outfile, soi) then return -1 end
            while true do
                local n
                n, buff = raf:Read(65536)
                if n == 0 then break end
                if not Write(outfile, buff) then return -1 end
            end
            break   -- all done!
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo and tagInfo.SubDirectory and et.EDIT_DIRS[tagInfo.Name] then
            doneTag[tag] = 1            -- prevent adding this back again later
            if soi == nil then
                local n
                n, buff = raf:Read(size)
                if n ~= size then et:Error('Truncated FLIF ' .. tag .. ' chunk') break end
            end
            -- rewrite the compressed data
            if et:hasZlib() then   -- (`eval { require IO::Uncompress::RawInflate } and eval { require IO::Compress::RawDeflate }`)
                local ok
                if #buff == 0 then
                    inflated = buff     -- (creating from scratch, so no need to inflate)
                else
                    inflated, ok = ExifTool.inflateRaw(nil, buff)
                    if not ok then et:Error('Error inflating FLIF ' .. tag .. ' chunk') break end
                end
                local subdir = tagInfo.SubDirectory
                local subdirInfo = {
                    DirName  = tagInfo.Name,
                    DataPt   = inflated,
                    DirStart = #inflated > 0 and subdir.Start or nil,
                    ReadOnly = 1,       -- (used only by WriteXMP)
                }
                local subTable = et:GetTagTable(subdir.TagTable)
                inflated = Writer.WriteDirectory(et, subdirInfo, subTable, subdir.WriteProc)
                if inflated ~= nil then
                    if #inflated == 0 then goto continue end -- (delete directory if length is zero)
                    if subdir.Header then inflated = subdir.Header .. inflated end -- (add back header if necessary)
                    buff, ok = ExifTool.deflateRaw(nil, inflated)
                    if not ok then et:Error('Error deflating FLIF ' .. tag .. ' chunk') break end
                end
            else
                et:Warn('Install IO::Compress::RawDeflate to write FLIF metadata')
            end
            if not Write(outfile, tag, FLIF.SetVarInt(#buff), buff) then return -1 end
        elseif soi == nil then
            if not Write(outfile, tag, FLIF.SetVarInt(size)) then return -1 end
            if Writer.CopyBlock(raf, outfile, size) ~= 1 then return -1 end
        end
        ::continue::
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from an FLIF file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid FLIF file
--------------------------------------------------------------------------------
function FLIF.ProcessFLIF(et, dirInfo)
    local raf = dirInfo.RAF
    local inflated

    -- verify this is a valid FLIF file and read the header
    local vals = FLIF.ReadFLIFHeader(raf)
    if not vals then return 0 end

    et:SetFileType()
    local tagTablePtr = et:GetTagTable('lexiftool.FLIF.Main')
    local verbose = et.OPTIONS.Verbose

    -- save the header information
    if perlTruthy(verbose) then et:VPrint(0, 'FLIF header:\n') end
    for tag = 0, 4 do
        if vals[tag] == nil then break end
        et:HandleTag(tagTablePtr, tag, vals[tag])
    end

    -- loop through the FLIF chunks
    while true do
        local n, tbuff = raf:Read(4)
        if n ~= 4 then
            et:Warn('Unexpected EOF')
            break
        end
        local byte = tbuff:byte(1)
        -- all done if we arrived at the image chunk
        if byte < 32 then
            et:HandleTag(tagTablePtr, 5, byte)
            break
        end
        local size = FLIF.GetVarInt(raf)
        if perlTruthy(verbose) then et:VPrint(0, string.format('FLIF %s (%d bytes):\n', tbuff, size)) end
        if tagTablePtr[tbuff] then
            local n2, buff = raf:Read(size)
            if n2 ~= size then
                et:Warn(string.format('Truncated FLIF %s chunk', tbuff))
                break
            end
            if perlNum(verbose) > 2 then et:VerboseDump(buff, { Addr = raf:Tell() - size }) end
            -- inflate the compressed data
            if et:hasZlib() then   -- (`eval { require IO::Uncompress::RawInflate }`)
                local data, ok = ExifTool.inflateRaw(nil, buff)
                if ok then
                    inflated = data
                    et:HandleTag(tagTablePtr, tbuff, inflated, {
                        DataPt = inflated,
                        Size = #inflated,
                        Extra = ' inflated',
                    })
                else
                    et:Warn(string.format('Error inflating FLIF %s chunk', tbuff))
                end
            else
                et:Warn('Install IO::Uncompress::RawInflate to decode FLIF metadata')
            end
        else
            if not raf:Seek(size, 1) then
                et:Warn('Seek error')
                break
            end
        end
    end
    return 1
end

return FLIF
