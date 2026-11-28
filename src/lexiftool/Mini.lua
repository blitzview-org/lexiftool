--------------------------------------------------------------------------------
-- File:         lexiftool/Mini.lua
-- Ported from:  lib/Image/ExifTool/Mini.pm
--
-- Description:  Read/write mif3 low-overhead SlimHEIF 'mini' information
--
-- Revisions:    2026-11-06 - P. Harvey Created
--
-- References:   1) https://github.com/MediaArea/MediaInfoLib
--
-- Port notes:   Complete port of Mini.pm: the Main table and every sub, in
--               upstream order.  Deviations forced by Lua:
--               - The predeclarations `sub Process_mini($$$);` and
--                 `sub Write_mini($$$);` are `false` placeholders for
--                 PROCESS_PROC/WRITE_PROC, filled in at the bottom of the
--                 file.
--               - Compress::Zlib is ExifTool hasZlib/inflateInit/
--                 deflateInit (the required rock compress.zlib).
--               - Scalar references: the chunk data of the block hashes of
--                 Inflate/Deflate are plain strings; the 'mini' header that
--                 Write_mini rebuilds through SetBits is a carray; a new
--                 chunk in the size list is the box { value = <data> } that
--                 Write_mini tests where upstream tests `ref`.  The chunk
--                 offset and size lists keep upstream's order in 1-based
--                 Lua arrays (chunk i is element i + 1).
--               - Upstream refers to %Image::ExifTool::Exif::orientation
--                 without a `use` of its own (QuickTime, which loads this
--                 module, has one); the port requires Exif for the table.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')     -- (for %Image::ExifTool::Exif::orientation)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local carray = require('carray')
local substr = perl.substr
local length = perl.length
local int = perl.int
local chr = perl.chr
local perlTruthy = ExifTool.perlTruthy
local Get8u = ExifTool.Get8u
local Set8u = ExifTool.Set8u
local GetTagTable = ExifTool.GetTagTable

local Mini = {}

Mini.VERSION = '1.01'

-- SlimHEIF 'mini' tags
Mini.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false, -- predeclaration, see below for implementation
    WRITE_GROUP = 'Mini',
    GROUPS = { [0] = 'QuickTime', [1] = 'Mini', [2] = 'Image' },
    TAG_PREFIX = '',
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Tags extracted by default from a mif3 low-overhead SlimHEIF 'mini' box. More
        tags (flags, etc.) are extracted from the mini header when the Unknown
        option is used. The family 1 group name for these tags is "Mini".

        When writing, by default new EXIF and XMP blocks are not compressed unless
        compressed data already exists, but EXIF and XMP are compressed if the API
        Compress option is set to 1, or uncompressed if set to 0. Compress::Zlib
        is required to enable this feature.
    ]],
    width_minus1 = { Name = 'ImageWidth', ValueConv = function(_self, val) return val + 1 end },
    height_minus1 = { Name = 'ImageHeight', ValueConv = function(_self, val) return val + 1 end },
    orientation_minus1 = {
        Name = 'Orientation',
        Writable = 1,
        ValueConv = function(_self, val) return val + 1 end,
        ValueConvInv = function(_self, val) return val - 1 end,
        PrintConv = Exif.orientation,
        SeparateTable = 'EXIF Orientation',
    },
    chroma_subsampling = {
        Name = 'ChromaSubsampling',
        PrintConv = {
            [0] = '4:0:0',
            [1] = '4:2:0',
            [2] = '4:2:2',
            [3] = '4:4:4',
        },
    },
    icc = {
        Name = 'ICC_Profile',
        Index = 4, -- (chunk number in 'mini' box)
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    exif = {
        Name = 'EXIF',
        Index = 10, -- (chunk number in 'mini' box)
        Compressible = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            WriteProc = Writer.WriteTIFF,
        },
    },
    xmp = {
        Name = 'XMP',
        Index = 11, -- (chunk number in 'mini' box)
        Compressible = 1,
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

--------------------------------------------------------------------------------
-- Get bits from current position in data block
-- Inputs: 0) Bits object (Pos,DataPt,Vars,ExifTool), 1) number of bits to read,
--         2) tag id (undef to skip bits)
-- Returns: true on success and stores as tag in $$bits{Vars} and as an ExifTool
--          tag if the ExifTool element set in %$bits
local function GetBits(bits, num, id)
    local end_ = int((bits.Pos + num - 1) / 8) -- end byte
    if end_ >= length(bits.DataPt) then
        bits.Error = 1
        return 0
    end
    local i = int(bits.Pos / 8)   -- index to current byte in data block
    local b = bits.Pos - i * 8    -- position of current bit (0=msb, 7=lsb)
    bits.Pos = bits.Pos + num
    local byte = Get8u(bits.DataPt, i)
    local val = 0
    while true do
        local n = num
        if n + b > 8 then n = 8 - b end -- num bits available in this byte
        local mask = 0xff >> b
        local shft = 8 - n - b
        val = (val << n) | ((byte & mask) >> shft)
        num = num - n
        if num == 0 then break end
        i = i + 1
        byte = Get8u(bits.DataPt, i)  -- get next byte
        b = 0
    end
    if id then
        bits.Vars[id] = val
        if bits.ExifTool then
            bits.ExifTool:HandleTag(bits.Table, id, val, { MakeTagInfo = 2 })
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Set bits at current position in data block
-- Inputs: 0) Bits object (Pos,DataPt,Vars), 1) number of bits to set,
--         2) tag id (undef to zero bits)
-- Returns: true on success and writes the bit stream to DataPt
local function SetBits(bits, num, id)
    local i = int(bits.Pos / 8)
    local b = bits.Pos - i * 8
    bits.Pos = bits.Pos + num
    local dataPt = bits.DataPt
    local byte = i < length(dataPt) and Get8u(dataPt, i) or 0
    local val = 0
    if id then val = bits.Vars[id] or 0 end   -- (undef numifies to 0)
    while true do
        local n = num
        if n + b > 8 then n = 8 - b end     -- num bits to write in this byte
        num = num - n                       -- num bits remaining to write
        local mask = 0xff >> (8 - n)        -- mask for bits to use
        -- add bits to current byte
        byte = byte | (((val >> num) & mask) << (8 - n - b))
        if i < length(dataPt) then
            Set8u(byte, dataPt, i)
        else
            dataPt:append(chr(byte))
        end
        if num == 0 then break end
        i = i + 1
        byte = 0
        b = 0
    end
    return 1
end

--------------------------------------------------------------------------------
-- Inflate data block
-- Inputs: 0) ExifTool ref, 1) block info ref (Name, DataPt, Start, Size)
-- Returns: true on success and updates block info, otherwise sets Size to 0
local function Inflate(et, block)
    if ExifTool.hasZlib() then  -- (`eval { require Compress::Zlib }`)
        local inflate = ExifTool.inflateInit()
        if inflate then
            et:VPrint(0, et.INDENT .. '[Inflating compressed ' .. block.Name .. "]\n")
            if perlTruthy(block.Start) then
                local dat = substr(block.DataPt, block.Start, block.Size)
                block.DataPt = dat
            end
            local buff, stat = inflate:inflate(block.DataPt)
            if stat == ExifTool.Z_STREAM_END then
                block.DataPt = buff
                block.Start = 0
                block.Size = length(buff)
                return 1
            end
        end
        et:Warn('Error inflating ' .. block.Name)
    else
        et:Warn('Install Compress::Zlib to process compressed ' .. block.Name)
    end
    block.Size = 0
    return 0
end

--------------------------------------------------------------------------------
-- Deflate data block
-- Inputs: 0) ExifTool ref, 1) block info ref (Name, DataPt)
-- Returns: true on success and updates block DataPt
local function Deflate(et, block)
    if ExifTool.hasZlib() then  -- (`eval { require Compress::Zlib }`)
        local deflate = ExifTool.deflateInit()
        if deflate then
            et:VPrint(0, et.INDENT .. '[Deflating ' .. block.Name .. " metadata]\n")
            local buff = deflate:deflate(block.DataPt)
            if buff ~= nil then
                buff = buff .. deflate:flush()
                block.DataPt = buff
                return 1
            end
        end
        et:Warn('Error deflating ' .. block.Name)
    else
        et:Warn('Install Compress::Zlib to write compressed ' .. block.Name)
    end
    return 0
end

--------------------------------------------------------------------------------
-- Read SlimHEIC 'mini' box from mif3 file, or write 'mini' box header
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- The dirInfo inputs are:
--   DataPt      - input 'mini' data or output when writing
--   HeaderOnly  - process only the header (not metadata chunks)
--   Vars        - input header variables for writing
--   BitsProc    - set to \&SetBits when writing
-- The dirInfo outputs are (returned only when HeaderOnly is set):
--   Vars        - bitstream header variable keyed by name
--   Offsets     - metadata chunk offsets (chunk 0 is the bitstream header)
--   Sizes       - metadata chunk sizes
function Mini.Process_mini(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    if not dirInfo.HeaderOnly then et:VerboseDir('Mini', nil, length(dataPt)) end
    -- initialize "bits" object for reading bitstream
    local vars = dirInfo.Vars or { }
    local bits = {
        DataPt = dataPt,
        Pos    = 0,
        Table  = tagTbl,
        Vars   = vars,
    }
    if not dirInfo.HeaderOnly then
        -- need documentation for the msf3 mini box
        if et.FileType == 'MSF3' then et:Warn("Can't yet read msf3 mini metadata") return 1 end
        bits.ExifTool = et
    end
    local proc = dirInfo.BitsProc or GetBits
    proc(bits, 2, 'mini_version')
    proc(bits, 1, 'explicit_codec_types_flag')
    proc(bits, 1, 'float_flag')
    proc(bits, 1, 'full_range_flag')
    proc(bits, 1, 'alpha_flag')
    proc(bits, 1, 'explicit_cicp_flag')
    proc(bits, 1, 'hdr_flag')
    proc(bits, 1, 'icc_flag')
    proc(bits, 1, 'exif_flag')
    proc(bits, 1, 'xmp_flag')
    proc(bits, 2, 'chroma_subsampling')
    proc(bits, 3, 'orientation_minus1')
    if not perlTruthy(proc(bits, 1, 'large_dimensions_flag')) then return 0 end
    proc(bits, perlTruthy(vars.large_dimensions_flag) and 15 or 7, 'width_minus1')
    proc(bits, perlTruthy(vars.large_dimensions_flag) and 15 or 7, 'height_minus1')
    if vars.chroma_subsampling == 1 or vars.chroma_subsampling == 2 then proc(bits, 1) end
    if vars.chroma_subsampling == 1 then proc(bits, 1) end
    if perlTruthy(vars.float_flag) then
        proc(bits, 2, 'bit_depth_log2_minus4')
    else
        proc(bits, 1, 'high_bit_depth_flag')
        if perlTruthy(vars.high_bit_depth_flag) then proc(bits, 3, 'bit_depth_minus_9') end
    end
    if perlTruthy(vars.alpha_flag) then proc(bits, 1, 'alpha_is_premultiplied') end
    if perlTruthy(vars.explicit_cicp_flag) then
        proc(bits, 8, 'colour_primaries')
        proc(bits, 8, 'transfer_characteristics')
        if perlTruthy(vars.chroma_subsampling) then proc(bits, 8, 'matrix_coefficients') end
    end
    if perlTruthy(vars.explicit_codec_types_flag) then
        proc(bits, 32, 'infe_type')
        proc(bits, 32, 'codec_config_type')
    end
    if perlTruthy(vars.hdr_flag) then
        proc(bits, 1, 'gainmap_flag')
        if perlTruthy(vars.gainmap_flag) then
            proc(bits, perlTruthy(vars.large_dimensions_flag) and 15 or 7, 'gainmap_width_minus1')
            proc(bits, perlTruthy(vars.large_dimensions_flag) and 15 or 7, 'gainmap_height_minus1')
            proc(bits, 8, 'gainmap_matrix_coefficients')
            proc(bits, 1, 'gainmap_full_range_flag')
            proc(bits, 2, 'gainmap_chroma_subsampling')
            if vars.gainmap_chroma_subsampling == 1 or vars.gainmap_chroma_subsampling == 2 then proc(bits, 1) end
            if vars.gainmap_chroma_subsampling == 1 then proc(bits, 1) end
            proc(bits, 1, 'gainmap_float_flag')
            if perlTruthy(vars.gainmap_float_flag) then
                proc(bits, 2, 'gainmap_bit_depth_log2_minus4')
            else
                proc(bits, 1, 'gainmap_high_bit_depth_flag')
                if perlTruthy(vars.gainmap_high_bit_depth_flag) then proc(bits, 3, 'gainmap_bit_depth_minus9') end
            end
            proc(bits, 1, 'tmap_icc_flag')
            proc(bits, 1, 'tmap_explicit_cicp_flag')
            if perlTruthy(vars.tmap_explicit_cicp_flag) then
                proc(bits, 8, 'tmap_colour_primaries')
                proc(bits, 8, 'tmap_transfer_characteristics')
                proc(bits, 8, 'tmap_matrix_coefficients')
                proc(bits, 1, 'tmap_full_range_flag')
            end
        end
    end
    if perlTruthy(vars.icc_flag) or perlTruthy(vars.exif_flag) or perlTruthy(vars.xmp_flag) or perlTruthy(vars.gainmap_flag) then
        proc(bits, 1, 'large_metadata_flag')
    else
        vars.large_metadata_flag = 0
    end
    proc(bits, 1, 'large_codec_config_flag')
    proc(bits, 1, 'large_item_data_flag')
    local metadataSize = perlTruthy(vars.large_metadata_flag) and 20 or 10
    local codecConfigSize = perlTruthy(vars.large_codec_config_flag) and 12 or 3
    local itemDataSize = perlTruthy(vars.large_item_data_flag) and 28 or 15
    if perlTruthy(vars.icc_flag) then proc(bits, metadataSize, 'icc_data_size_minus1') end
    if perlTruthy(vars.tmap_icc_flag) then proc(bits, metadataSize, 'tmap_icc_data_size_minus1') end
    if perlTruthy(vars.gainmap_flag) then
        local gainItemData -- luacheck: ignore 211 (unused upstream too)
        proc(bits, metadataSize, 'gainmap_metadata_size')
        proc(bits, itemDataSize, 'gainmap_item_data_size')
        if perlTruthy(vars.gainmap_item_data_size) then
            proc(bits, codecConfigSize, 'gainmap_item_codec_config_size')
        end
    end
    proc(bits, codecConfigSize, 'main_item_codec_config_size')
    if not perlTruthy(proc(bits, itemDataSize, 'main_item_data_size_minus1')) then return 0 end
    if perlTruthy(vars.alpha_flag) then
        proc(bits, itemDataSize, 'alpha_item_data_size')
        if perlTruthy(vars.alpha_item_data_size) then
            proc(bits, codecConfigSize, 'alpha_item_codec_config_size')
        end
    end
    if perlTruthy(vars.exif_flag) or perlTruthy(vars.xmp_flag) then
        proc(bits, 1, 'exif_xmp_compressed_flag')
    else
        vars.exif_xmp_compressed_flag = 0
    end
    if perlTruthy(vars.exif_flag) then proc(bits, metadataSize, 'exif_data_size_minus1') end
    if perlTruthy(vars.xmp_flag) then proc(bits, metadataSize, 'xmp_data_size_minus1') end
    local sizes = { -- chunk sizes
        int((bits.Pos + 7) / 8),                        -- 0) header chunk
        vars.main_item_codec_config_size,               -- 1) main item codec config chunk
        vars.alpha_item_codec_config_size or 0,         -- 2) alpha codec config chunk
        vars.gainmap_item_codec_config_size or 0,       -- 3) gainmap coded config chunk
        vars.icc_data_size_minus1 ~= nil and vars.icc_data_size_minus1 + 1 or 0, -- 4) icc profile chunk
        vars.tmap_icc_data_size_minus1 ~= nil and vars.tmap_icc_data_size_minus1 + 1 or 0, -- 5) tmap icc chunk
        vars.gainmap_metadata_size or 0,                -- 6) gainmap metadata chunk
        vars.alpha_item_data_size or 0,                 -- 7) alpha chunk
        vars.gainmap_item_data_size or 0,               -- 8) gainmap chunk
        vars.main_item_data_size_minus1 + 1,            -- 9) main item data chunk
        vars.exif_data_size_minus1 ~= nil and vars.exif_data_size_minus1 + 1 or 0, -- 10) exif chunk
        vars.xmp_data_size_minus1 ~= nil and vars.xmp_data_size_minus1 + 1 or 0, -- 11) xmp chunk
    }
    -- calculate chunk offsets
    local offsets = { }
    local offset = 0
    for i = 0, #sizes - 1 do
        offsets[i + 1] = offset
        offset = offset + sizes[i + 1]
    end
    -- exit here if processing only the 'mini' bitstream header and return
    -- information about the header variables and chunk Offsets and Sizes
    if dirInfo.HeaderOnly then
        dirInfo.Vars = bits.Vars
        dirInfo.Offsets = offsets
        dirInfo.Sizes = sizes
        if not dirInfo.BitsProc then
            if offsets[#offsets] + sizes[#sizes] ~= length(dataPt) then return 0 end
        end
        return 1
    end
--
-- process the metadata chunks (icc, exif and xmp)
--
    for _, tagID in ipairs({ 'icc', 'exif', 'xmp' }) do
        local tagInfo = tagTbl[tagID]
        local i = tagInfo.Index  -- get chunk number in 'mini' box
        if not (perlTruthy(sizes[i + 1]) and offsets[i + 1] + sizes[i + 1] <= length(dataPt)) then goto continue end
        do
            local parms = {
                Name   = tagInfo.Name,
                DataPt = dataPt,
                Start  = offsets[i + 1],
                Size   = sizes[i + 1],
            }
            if tagInfo.Compressible and perlTruthy(vars.exif_xmp_compressed_flag) then
                if not perlTruthy(Inflate(et, parms)) then goto continue end
            end
            et.PROCESSED = { } -- (bypass recursion protection)
            et:HandleTag(tagTbl, tagID, nil, parms)
        end
        ::continue::
    end
    if offset ~= length(dataPt) then et:Warn('Unexpected mini box size') end
    return 1
end

--------------------------------------------------------------------------------
-- Write SlimHEIC 'mini' box
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function Mini.Write_mini(et, dirInfo, tagTbl)
    if not et then return 1 end   -- allow dummy access to autoload this package
    local editDirs = et.EDIT_DIRS
    if not editDirs.Mini then return nil end
    local addDirs = et.ADD_DIRS
    dirInfo.HeaderOnly = 1  -- read only the bitstream header
    if not perlTruthy(Mini.Process_mini(et, dirInfo, tagTbl)) then
        et:Warn('Format error in mif3 mini box')
        return nil
    end
    local dataPt = dirInfo.DataPt
    local vars = dirInfo.Vars           -- header variable values
    local offsets = dirInfo.Offsets     -- metadata chunk offsets
    local sizes = dirInfo.Sizes         -- metadata chunk sizes
    local has = { }
    local isCompressed = vars.exif_xmp_compressed_flag
    local wasCompressed = isCompressed
    -- set compressed flag according to Compress option setting
    if et.OPTIONS.Compress ~= nil then
        vars.exif_xmp_compressed_flag = perlTruthy(et.OPTIONS.Compress) and 1 or 0
        isCompressed = vars.exif_xmp_compressed_flag
    end
    -- set Orientation if specified
    local val, nvHash = et:GetNewValue(Mini.Main.orientation_minus1)
    if val ~= nil then
        local isOverwriting = Writer.IsOverwriting(et, nvHash, vars.orientation_minus1)
        if perlTruthy(isOverwriting) and perl.num(val, '!=') ~= vars.orientation_minus1 then
            vars.orientation_minus1 = val
            et.CHANGED = (et.CHANGED or 0) + 1
        end
    end
    local maxSize = perlTruthy(vars.large_metadata_flag) and 0x100000 or 0x400
    -- edit ICC, EXIF and XMP chunks
    -- (this is fairly straightforward, but dealing with changing the compression
    --  flag and/or compression/decompression failures complicates things somewhat)
    for _, tagID in ipairs({ 'icc', 'exif', 'xmp' }) do
        local tagInfo = tagTbl[tagID]
        local subdir = tagInfo.SubDirectory
        local name = tagInfo.Name
        local i = tagInfo.Index
        local editDir = editDirs[name]
        -- edit this chunk if compressible and the compression changed
        if tagInfo.Compressible and isCompressed ~= wasCompressed then editDir = 1 end
        if not (addDirs[name] or (perlTruthy(sizes[i + 1]) and editDir)) then goto continue end
        do
            local old, oldPt, new, newPt
            old = perlTruthy(sizes[i + 1]) and substr(dataPt, offsets[i + 1], sizes[i + 1]) or ''
            if tagInfo.Compressible and perlTruthy(wasCompressed) and length(old) > 0 then
                local block = { Name = name, DataPt = old }
                if not perlTruthy(Inflate(et, block)) then goto continue end
                oldPt = block.DataPt
            else
                oldPt = old
            end
            local tbl = GetTagTable(subdir.TagTable)
            local subdirInfo = { DataPt = oldPt }   -- (upstream's inner `my %dirInfo`)
            local oldChanged = et.CHANGED
            if editDirs[name] then new = Writer.WriteDirectory(et, subdirInfo, tbl, subdir.WriteProc) end
            -- re-use original data if nothing changed (eg. avoid unnecessary restructuring)
            if et.CHANGED == oldChanged then new = oldPt end
            et.CHANGED = oldChanged -- (we'll handle this later)
            if new == nil or new == oldPt then
                -- the data for this chunk didn't change, so unless the
                -- compression changed, just rewrite the original data
                if not (tagInfo.Compressible and isCompressed ~= wasCompressed) then goto continue end
                -- fall through using old data if necessary to change compression
                if new == nil then new = old end
            end
            if tagInfo.Compressible and perlTruthy(isCompressed) and length(new) > 0 then
                local block = { DataPt = new, Name = name }
                if perlTruthy(Deflate(et, block)) then
                    newPt = block.DataPt
                else
                    -- write as uncompressed and reset compression flag
                    vars.exif_xmp_compressed_flag = 0
                    isCompressed = 0
                    newPt = new -- write uncompressed data
                end
            else
                newPt = new
            end
            if length(newPt) > maxSize then
                if length(newPt) > 0x100000 then
                    local str = perlTruthy(isCompressed) and '' or ', try using the Compress option'
                    et:Warn(name .. ' too large to write' .. str)
                    goto continue
                end
                et:VPrint(0, et.INDENT .. '[Setting large_metadata_flag due to ' .. name .. "]\n")
                vars.large_metadata_flag = 1
                maxSize = 0x100000
            end
            if length(newPt) > 0 then
                vars[tagID .. '_flag'] = 1
                vars[tagID .. '_data_size_minus1'] = length(newPt) - 1
                sizes[i + 1] = { value = newPt }   -- set size to new data ref
                if tagInfo.Compressible then has[perlTruthy(isCompressed) and 'Compressed' or 'Uncompressed'] = 1 end
            else
                vars[tagID .. '_flag'] = 0
                sizes[i + 1] = 0
            end
            et.CHANGED = (et.CHANGED or 0) + 1    -- success!
        end
        ::continue::
    end
    if not perlTruthy(et.CHANGED) then return nil end  -- rewrite original data if nothing changed
    -- account for unedited EXIF or XMP in $has compression flags
    for _, i in ipairs({ 10, 11 }) do
        if type(sizes[i + 1]) == 'table' or not perlTruthy(sizes[i + 1]) then goto nextChunk end
        -- this chunk wasn't changed, so the compression state is same as original
        has[perlTruthy(wasCompressed) and 'Compressed' or 'Uncompressed'] = 1
        ::nextChunk::
    end
    -- verify the compression status of EXIF and XMP (it is possible to be
    -- inconsistent if we had an inflate/deflate error in one of the types)
    if has.Compressed and not perlTruthy(isCompressed) or has.Uncompressed and perlTruthy(isCompressed) then
        et:Error('Compression error when writing Mini box')
    end
    -- rebuild mini box header from $bits data
    local outBuff = carray.new('char')
    dirInfo.DataPt = outBuff
    dirInfo.BitsProc = SetBits
    if not perlTruthy(Mini.Process_mini(et, dirInfo, tagTbl)) then return nil end
    -- add back all blocks (block 0 header is already there)
    for i = 1, #sizes - 1 do
        -- ($sizes holds the new data if it is scalar reference)
        if type(sizes[i + 1]) == 'table' then
            outBuff:append(sizes[i + 1].value)
        else
            outBuff:append(substr(dataPt, offsets[i + 1], sizes[i + 1]))
        end
    end
    return outBuff:tostring()
end

-- (PROCESS_PROC/WRITE_PROC of the table above: the predeclared subs exist only
--  now, see the predeclaration placeholders)
Mini.Main.PROCESS_PROC = Mini.Process_mini
Mini.Main.WRITE_PROC = Mini.Write_mini

return Mini
