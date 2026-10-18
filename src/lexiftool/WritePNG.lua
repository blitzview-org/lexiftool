--------------------------------------------------------------------------------
-- File:         lexiftool/WritePNG.lua
-- Ported from:  lib/Image/ExifTool/WritePNG.pl
--
-- Description:  Write PNG meta information
--
-- Revisions:    09/16/2005 - P. Harvey Created
--
-- References:   1) http://www.libpng.org/pub/png/spec/1.2/
--
-- Port notes:   All subs of WritePNG.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::PNG package and
--               AUTOLOADs it on the first call of one of its subs; this port
--               makes it a module of its own, and PNG.lua binds every sub at
--               its predeclaration position to a closure that loads this
--               file on first use (PNG.CalculateCRC, PNG.AddChunks, ... keep
--               working for all callers).
--
--               Scalar references: a data reference is the string itself
--               (`$$dataPt` is dataPt), except where upstream edits through
--               it -- the iCCP profile name WriteProfile receives as a SCALAR
--               ref (`ref $rawType`, read only: a string in the box) and the
--               XMP packet ValidateXMP marks read-only (edited: a carray in
--               the box, doc/api.md §4) are { value = ... } boxes, as are
--               the chunk buffers PNG.lua's FoundPNG fills.  CalculateCRC walks the bytes in place
--               instead of building upstream's `unpack("x${pos}C$len")` list
--               (an IDAT chunk can hold megabytes).
--
--               Compress::Zlib is ExifTool.hasZlib/deflateInit (lua-zlib).
--               lua-zlib has no memLevel argument: Compress::Zlib deflates
--               with MAX_MEM_LEVEL (9), lua-zlib with zlib's default (8), so
--               compressed iCCP/zTXt/iTXt data beyond roughly 16k symbols
--               per deflate block differs byte-wise from upstream's (the
--               inflated content is the same).  When inflating a zTXt value
--               fails, Compress::Zlib has already consumed part of the
--               input; lua-zlib does not say how much, so PNG.lua keeps all
--               bytes of such a corrupt value (its rewritten length differs).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local length = perl.length
local substr = perl.substr
local carray = require('carray')
local substDyn = perl.substDyn
local isMatch = perl.isMatch
local pack, unpack = perl.pack, perl.unpack
local sprintf = perl.sprintf
local keys, sort = perl.keys, perl.sort
local str = perl.str
local truthy = perl.truthy
local byte = string.byte
local Write = Writer.Write
local GetTagTable = ExifTool.GetTagTable

local PNG = require('lexiftool.PNG')    -- (upstream `package Image::ExifTool::PNG`)
local WritePNG = {}

local stdCase = PNG.stdCase

-- (subs of this file upstream calls by their bare names before defining them)
local AddChunks

--------------------------------------------------------------------------------
-- Calculate CRC or update running CRC (ref 1)
-- Inputs: 0) data reference, 1) running crc to update (undef initially)
--         2) data position (undef for 0), 3) data length (undef for all data),
-- Returns: updated CRC
local crcTable = { }
local function CalculateCRC(dataPt, crc, pos, len)
    if crc == nil then crc = 0 end
    if pos == nil then pos = 0 end
    if len == nil then len = length(dataPt) - pos end
    crc = crc ~ 0xffffffff         -- undo 1's complement
    -- build lookup table unless done already
    if crcTable[0] == nil then
        local c
        for n = 0, 255 do
            c = n
            for _ = 0, 7 do
                if (c & 1) ~= 0 then c = 0xedb88320 ~ (c >> 1) else c = c >> 1 end
            end
            crcTable[n] = c
        end
    end
    -- calculate the CRC
    for i = pos + 1, pos + len do
        crc = crcTable[(crc ~ byte(dataPt, i)) & 0xff] ~ (crc >> 8)
    end
    return crc ~ 0xffffffff   -- return 1's complement
end

--------------------------------------------------------------------------------
-- Encode data in ASCII Hex
-- Inputs: 0) input data reference
-- Returns: Hex-encoded data (max 72 chars per line)
local function HexEncode(dataPt)
    local len = length(dataPt)
    local hex = carray.new('char')
    for pos = 0, len - 1, 36 do
        local n = len - pos
        if n > 36 then n = 36 end
        hex:append(unpack('H*', substr(dataPt, pos, n)) .. "\n")
    end
    return hex:tostring()
end

--------------------------------------------------------------------------------
-- Write profile chunk (possibly compressed if Zlib is available)
-- Inputs: 0) outfile, 1) Raw profile type (SCALAR ref for iCCP name), 2) data ref
--         3) profile header type (undef if not a text profile)
-- Returns: 1 on success
local function WriteProfile(outfile, rawType, dataPt, profile)
    local buff, prefix, chunk, deflate
    if rawType ~= stdCase.exif and ExifTool.hasZlib() then  -- (`eval { require Compress::Zlib }`)
        deflate = ExifTool.deflateInit()
    end
    if profile == nil then
        -- write ICC profile as compressed iCCP chunk if possible
        if type(rawType) == 'table' then
            if not deflate then return 0 end
            chunk = 'iCCP'
            prefix = rawType.value .. "\0\0"
        else
            chunk = rawType
            if rawType == stdCase.zxif then
                prefix = "\0" .. pack('N', length(dataPt)) -- (proposed compressed EXIF)
            else
                prefix = ''   -- standard EXIF
            end
        end
        if deflate then
            buff = deflate:deflate(dataPt)
            if buff == nil then return 0 end
            buff = buff .. deflate:flush()
            dataPt = buff
        end
    else
        -- write as ASCII-hex encoded profile in tEXt or zTXt chunk
        local txtHdr = sprintf("\n" .. profile .. " profile\n%8d\n", length(dataPt))
        buff = txtHdr .. HexEncode(dataPt)
        chunk = 'tEXt'         -- write as tEXt if deflate not available
        prefix = 'Raw profile type ' .. rawType .. "\0"
        dataPt = buff
        -- write profile as zTXt chunk if possible
        if deflate then
            local buf2 = deflate:deflate(buff)
            if buf2 ~= nil then
                buf2 = buf2 .. deflate:flush()
                dataPt = buf2
                chunk = 'zTXt'
                prefix = prefix .. "\0"    -- compression type byte (0=deflate)
            end
        end
    end
    local hdr = pack('Na4', length(prefix) + length(dataPt), chunk) .. prefix
    local crc = CalculateCRC(hdr, nil, 4)
    crc = CalculateCRC(dataPt, crc)
    return Write(outfile, hdr, dataPt, pack('N', crc))
end

--------------------------------------------------------------------------------
-- Add iCCP-related chunks to the PNG image if necessary (must come before PLTE and IDAT)
-- Inputs: 0) ExifTool object ref, 1) output file or scalar ref
-- Returns: true on success
local function Add_iCCP(et, outfile)
    if et.ADD_DIRS.ICC_Profile then
        -- write new ICC data
        local tagTablePtr = GetTagTable(nil, 'lexiftool.ICC_Profile.Main')
        local dirInfo = { Parent = 'PNG', DirName = 'ICC_Profile' }
        local buff = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
        if buff ~= nil and truthy(length(buff)) then
            local profileName = et:GetNewValue(PNG.Main['iCCP-name'])
            if profileName == nil then profileName = 'icm' end
            if truthy(WriteProfile(outfile, { value = profileName }, buff)) then
                et:VPrint(0, "Created ICC profile with name '" .. str(profileName) .. "'\n")
                et.ADD_DIRS.ICC_Profile = nil -- don't add it again
            end
        end
    end
    -- must also add sRGB and gAMA before PLTE and IDAT
    if et.ADD_PNG then
        local addBeforePLTE = { }
        for _, tag in ipairs({ 'sRGB', 'gAMA' }) do
            if et.ADD_PNG[tag] then
                addBeforePLTE[tag] = et.ADD_PNG[tag]
                et.ADD_PNG[tag] = nil
            end
        end
        if next(addBeforePLTE) then
            local save = et.ADD_PNG
            et.ADD_PNG = addBeforePLTE
            AddChunks(et, outfile)
            et.ADD_PNG = save
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- This routine is called after we edit an existing directory
-- Inputs: 0) ExifTool ref, 1) dir name, 2) output data ref
--         3) flag set if location is non-standard (to update, but not create from scratch)
-- - on return, $$outBuff is set to '' if the directory is to be deleted
local function DoneDir(et, dir, outBuff, nonStandard)
    local saveDir = dir
    if dir == 'IFD0' then dir = 'EXIF' end
    -- don't add this directory again unless this is in a non-standard location
    if not truthy(nonStandard) then
        et.ADD_DIRS[dir] = nil
        if dir == 'EXIF' then et.ADD_DIRS.IFD0 = nil end
    elseif et.DEL_GROUP[dir] or et.DEL_GROUP[saveDir] then
        et:VPrint(0, '  Deleting non-standard ' .. dir .. "\n")
        outBuff.value = carray.new('char')
    end
end

--------------------------------------------------------------------------------
-- Generate tEXt, zTXt or iTXt data for writing
-- Inputs: 0) ExifTool ref, 1) tagID, 2) tagInfo ref, 3) value string, 4) language code
-- Returns: chunk data (not including 8-byte chunk header)
-- Notes: Sets ExifTool TextChunkType member to the type of chunk written
local function BuildTextChunk(et, tag, tagInfo, val, lang)
    local xtra, compVal, iTXt, comp
    if tagInfo.SubDirectory then
        if tagInfo.Name == 'XMP' then
            iTXt = 2      -- write as iTXt but flag to avoid encoding
            -- (never compress XMP)
        else
            comp = 2      -- compress raw profile if possible
        end
    else
        -- compress if specified
        if truthy(et:Options('Compress')) then comp = 1 end
        if truthy(lang) then
            iTXt = 1      -- write as iTXt if it has a language code
            tag = substDyn(tag, '-' .. lang .. '$', '')    -- remove language code from tagID
        elseif et.OPTIONS.Charset ~= 'Latin' and isMatch(val, [=[[\x80-\xff]]=]) then
            iTXt = 1      -- write as iTXt if it contains non-Latin special characters
        elseif tagInfo.iTXt then
            iTXt = 1      -- write as iTXt if specified in user-defined tag
        end
    end
    if comp then
        local warn
        if ExifTool.hasZlib() then     -- (`eval { require Compress::Zlib }`)
            local deflate = ExifTool.deflateInit()
            if deflate then compVal = deflate:deflate(val) end
            if compVal ~= nil then
                compVal = compVal .. deflate:flush()
                -- only compress if it actually saves space
                if not (length(compVal) < length(val)) then -- luacheck: ignore 581 (upstream `unless (... < ...)`)
                    compVal = nil
                    warn = 'uncompressed data is smaller'
                end
            else
                warn = 'deflate error'
            end
        else
            warn = 'Compress::Zlib not available'
        end
        -- warn if any user-specified compression fails
        if warn and comp == 1 then
            et:Warn('PNG:' .. tagInfo.Name .. ' not compressed (' .. warn .. ')', 1)
        end
    end
    -- decide whether to write as iTXt, zTXt or tEXt
    if iTXt then
        et.TextChunkType = 'iTXt'
        xtra = (compVal ~= nil and "\x01\0" or "\0\0") .. (truthy(lang) and lang or '') .. "\0\0"
        -- iTXt is encoded as UTF-8 (but note that XMP is already UTF-8)
        if iTXt == 1 then val = et:Encode(val, 'UTF8') end
    elseif compVal ~= nil then
        et.TextChunkType = 'zTXt'
        xtra = "\0"
    else
        et.TextChunkType = 'tEXt'
        xtra = ''
    end
    return tag .. "\0" .. xtra .. (compVal ~= nil and compVal or val)
end

--------------------------------------------------------------------------------
-- Add any outstanding new chunks to the PNG image
-- Inputs: 0) ExifTool object ref, 1) output file or scalar ref
--         2-N) dirs to add (empty to add all except EXIF 'IFD0', including PNG tags)
-- Returns: true on success
function AddChunks(et, outfile, ...)
    local add = { ... }
    local addTags, err, tagTablePtr, specified

    if #add > 0 then
        addTags = { } -- don't add any PNG tags
        specified = 1
    else
        addTags = et.ADD_PNG or { }  -- add all PNG tags...
        et.ADD_PNG = nil             -- ...once
        -- add all directories
        add = sort(keys(et.ADD_DIRS))
    end
    -- write any outstanding PNG tags
    for _, tag in ipairs(sort(keys(addTags))) do
        local tagInfo = addTags[tag]
        if tagInfo.FakeTag then goto nextTag end -- (iCCP-name)
        do
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            -- (native PNG information is always preferred, so don't rely on just IsCreating)
            if not (truthy(nvHash.IsCreating) or Writer.IsOverwriting(et, nvHash) > 0) then goto nextTag end
            local val = et:GetNewValue(nvHash)
            if val ~= nil then
                if truthy(nvHash.EditOnly) then goto nextTag end
                local data
                if tagInfo.Table == PNG.TextualData then
                    data = BuildTextChunk(et, tag, tagInfo, val, tagInfo.LangCode)
                    data = et.TextChunkType .. data
                    et.TextChunkType = nil
                else
                    data = tag .. str(val)
                end
                local hdr = pack('N', length(data) - 4)
                local cbuf = pack('N', CalculateCRC(data, nil))
                if not Write(outfile, hdr, data, cbuf) then err = 1 end
                et:VerboseValue('+ PNG:' .. tagInfo.Name, val)
                et.CHANGED = (et.CHANGED or 0) + 1
            end
        end
        ::nextTag::
    end
    -- create any necessary directories
    for _, dir in ipairs(add) do
        if not et.ADD_DIRS[dir] then goto nextDir end -- make sure we want to add it first
        do
            local buff
            local dirInfo = {
                Parent = 'PNG',
                DirName = dir,
            }
            if dir == 'IFD0' then
                if not specified then goto nextDir end    -- wait until specifically asked to write EXIF 'IFD0'
                local chunk = stdCase.exif
                -- (zxIf was not adopted)
                --if ($et->Options('Compress')) {
                --    if (eval { require Compress::Zlib }) {
                --        $chunk = $stdCase{zxif};
                --    } else {
                --        $et->Warn("Creating uncompressed $stdCase{exif} chunk (Compress::Zlib not available)");
                --    }
                --}
                et:VPrint(0, 'Creating ' .. chunk .. " chunk:\n")
                et.TIFF_TYPE = 'APP1'
                tagTablePtr = GetTagTable(nil, 'lexiftool.Exif.Main')
                buff = Writer.WriteDirectory(et, dirInfo, tagTablePtr, Writer.WriteTIFF)
                if buff ~= nil and truthy(length(buff)) then
                    if not truthy(WriteProfile(outfile, chunk, buff)) then err = 1 end
                end
            elseif dir == 'XMP' then
                et:VPrint(0, "Creating XMP iTXt chunk:\n")
                tagTablePtr = GetTagTable(nil, 'lexiftool.XMP.Main')
                dirInfo.ReadOnly = 1
                buff = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
                -- (`\$buff`: ValidateXMP edits it in place, so the box holds a carray)
                local buffPt = { value = buff and carray.new('char'):append(buff) }
                if buff ~= nil and truthy(length(buff)) and
                    -- the packet is read-only (because of CRC)
                    truthy(require('lexiftool.XMP').ValidateXMP(buffPt, 'r'))
                then
                    -- (previously, XMP was created as a non-standard XMP profile chunk)
                    -- $buff = $Image::ExifTool::xmpAPP1hdr . $buff;
                    -- WriteProfile($outfile, 'APP1', \$buff, 'generic') or $err = 1;
                    -- (but now write XMP iTXt chunk according to XMP specification)
                    buff = "iTXtXML:com.adobe.xmp\0\0\0\0\0" .. buffPt.value:tostring()
                    local hdr = pack('N', length(buff) - 4)
                    local cbuf = pack('N', CalculateCRC(buff, nil))
                    if not Write(outfile, hdr, buff, cbuf) then err = 1 end
                end
            elseif dir == 'IPTC' then
                et:Warn('Creating non-standard IPTC in PNG', 1)
                et:VPrint(0, "Creating IPTC profile:\n")
                -- write new IPTC data (stored in a Photoshop directory)
                dirInfo.DirName = 'Photoshop'
                tagTablePtr = GetTagTable(nil, 'lexiftool.Photoshop.Main')
                buff = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
                if buff ~= nil and truthy(length(buff)) then
                    if not truthy(WriteProfile(outfile, 'iptc', buff, 'IPTC')) then err = 1 end
                end
            elseif dir == 'ICC_Profile' then
                et:VPrint(0, "Creating ICC profile:\n")
                -- write new ICC data (only done if we couldn't create iCCP chunk)
                tagTablePtr = GetTagTable(nil, 'lexiftool.ICC_Profile.Main')
                buff = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
                if buff ~= nil and truthy(length(buff)) then
                    if not truthy(WriteProfile(outfile, 'icm', buff, 'ICC')) then err = 1 end
                    et:Warn('Wrote ICC as a raw profile (no Compress::Zlib)')
                end
            elseif dir == 'PNG-pHYs' then
                et:VPrint(0, "Creating pHYs chunk (default 2834 pixels per meter):\n")
                tagTablePtr = GetTagTable(nil, 'lexiftool.PNG.PhysicalPixel')
                local blank = "\0\0\x0b\x12\0\0\x0b\x12\x01" -- 2834 pixels per meter (72 dpi)
                dirInfo.DataPt = blank
                buff = Writer.WriteDirectory(et, dirInfo, tagTablePtr)
                if buff ~= nil and truthy(length(buff)) then
                    buff = 'pHYs' .. buff -- CRC includes chunk name
                    local hdr = pack('N', length(buff) - 4)
                    local cbuf = pack('N', CalculateCRC(buff, nil))
                    if not Write(outfile, hdr, buff, cbuf) then err = 1 end
                end
            else
                goto nextDir
            end
            et.ADD_DIRS[dir] = nil  -- don't add again
        end
        ::nextDir::
    end
    return not err
end

-- (the subs above, for PNG.lua's AUTOLOAD closures)
WritePNG.CalculateCRC = CalculateCRC
WritePNG.HexEncode = HexEncode
WritePNG.WriteProfile = WriteProfile
WritePNG.Add_iCCP = Add_iCCP
WritePNG.DoneDir = DoneDir
WritePNG.BuildTextChunk = BuildTextChunk
WritePNG.AddChunks = AddChunks

return WritePNG -- end
