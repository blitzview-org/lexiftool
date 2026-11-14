--------------------------------------------------------------------------------
-- File:         lexiftool/7Z.lua
-- Ported from:  lib/Image/ExifTool/7Z.pm
--
-- Description:  Read 7z archive meta information
--
-- Revisions:    2023/04/28 - Amir Gooran (Cyberno)
--               2023-05-06 - PH Minor changes in ExifTool interfacing
--
-- References:   1) https://py7zr.readthedocs.io/en/latest/archive_format.html
--
-- Port notes:   Full port of 7Z.pm, sub for sub and in upstream order.  The
--               module defines no tag table of its own -- like upstream it
--               writes its tags through Image::ExifTool::ZIP::RAR5.
--
--               Module table name: upstream's package is Image::ExifTool::7Z,
--               and `local 7Z = {}` is not a valid Lua identifier.  The file
--               base name stays 7Z.lua (conventions.md §1: base names are
--               preserved), and the table takes the same word with a single
--               leading underscore, `local _7Z = {}` ... `return _7Z`, so the
--               module is still greppable under one identifier.  There was no
--               precedent for a non-identifier module name in this port; the
--               rule is now written down in conventions.md §1.
--
--               Perl's `$_[N]` positional parameters become named ones here
--               (upstream mixes `shift` with `$_[N]`, so several subs never
--               name their arguments at all); `$raf->Read($buff, N)`, which
--               returns the count and fills $buff, becomes the port's
--               `_, buff = raf:Read(N)`.
--
--               Perl arrays become 1-based Lua arrays, and the
--               `for (my $i = 0; ...)` loops become `for i = 1, N` -- except
--               where the loop variable is used as a value rather than as an
--               index (the ReadUInt64 length table, ReadFolder's/
--               ReadUnpackInfo's `Reading coder $i`/`Reading folder $i`
--               verbose output, and the stream indices stored in
--               "packed_indices"), which stay 0-based as upstream.
--               ReadBoolean returns Lua booleans instead of Perl's 1/'', so
--               its callers' `if ($x)` / `$x == 0` tests become `if x` /
--               `if not x`.
--
--               LZMA: the encoded (compressed) header is read through
--               Compress::Raw::Lzma's RawDecoder, which the perl facade
--               provides over compress.lzma (perl.evalRequire).  As upstream,
--               every block of at most 32 KB of the packed header gets a new
--               decoder with the default Lzma1 filter (the coder properties
--               are not used), so a header that is packed into more than one
--               block does not decode; the loop then never ends, in Perl as
--               here.  The buffers the decoder changes ($data in Decompress
--               and Decompress_Internal, $folder_data) are carrays.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local substr = perl.substr
local ord = perl.ord
local unpack_ = perl.unpack
local length = perl.length
local truthy = perl.truthy
local sprintf = perl.sprintf
local RandomAccess = require('lexiftool.RandomAccess')
local carray = require('carray')

local _7Z = {}

-- Compress::Raw::Lzma and the Lzma::Filter package that ships with it, set
-- by upstream's `eval { require Compress::Raw::Lzma }` in Process7Z
local CompressRawLzma, Lzma

function _7Z.ReadUInt32(raf)
    local buff, _

    _, buff = raf:Read(4)
    local output = unpack_('L', buff)
    return output
end

function _7Z.ReadUInt64(raf)
    local buff, _

    _, buff = raf:Read(1)
    local b = ord(buff)
    if b == 255 then  -- read real uint64
        _, buff = raf:Read(8)
        local output = unpack_('Q', buff)
        return output
    end
    local blen = { 0x7F, 0xBF, 0xDF, 0xEF, 0xF7, 0xFB, 0xFD, 0xFE }

    local mask = 0x80
    local vlen = 8

    for l = 0, #blen - 1 do
        local v = blen[l + 1]
        if b <= v then
            vlen = l
            break
        end
        mask = mask >> 1
    end
    if vlen == 0 then
        return b & (mask - 1)
    end
    _, buff = raf:Read(vlen)
    buff = buff .. "\0\0\0\0\0\0\0\0"

    local value = unpack_('Q', buff)
    local highpart = b & (mask - 1)
    return value + (highpart << (vlen * 8))
end

function _7Z.ReadRealUInt64(raf)
    local buff, _

    _, buff = raf:Read(8)
    local value = unpack_('Q', buff)
    return value
end

function _7Z.ReadBoolean(raf, count, checkall)
    local buff, _
    local result = {}

    if truthy(checkall) then
        _, buff = raf:Read(1)
        local all_defined = ord(buff)
        if all_defined ~= 0 then
            for i = 1, count do result[i] = true end
            return result
        end
    end

    local b = 0
    local mask = 0

    for _i = 1, count do -- luacheck: ignore _i
        if mask == 0 then
            _, buff = raf:Read(1)
            b = ord(buff)
            mask = 0x80
        end
        result[#result + 1] = (b & mask) ~= 0
        mask = mask >> 1
    end
    return result
end

function _7Z.ReadUTF16(raf)
    local val = ""
    local ch, _

    for _i = 1, 65536 do -- luacheck: ignore _i
        _, ch = raf:Read(2)
        if ch == "\0\0" then
            break
        end
        val = val .. ch
    end
    return val
end

function _7Z.ReadPackInfo(et, raf)
    local buff, _
    local out_packinfo = {}
    out_packinfo["packsizes"] = {}

    out_packinfo["packpos"] = _7Z.ReadUInt64(raf)
    local numstreams = _7Z.ReadUInt64(raf)
    et:VPrint(0, "Number Of Streams: " .. numstreams .. "\n")

    _, buff = raf:Read(1)
    local pid = ord(buff)

    local crcs
    if pid == 9 then  -- size
        for _i = 1, numstreams do -- luacheck: ignore _i
            local packsizes = out_packinfo["packsizes"]
            packsizes[#packsizes + 1] = _7Z.ReadUInt64(raf)
        end
        _, buff = raf:Read(1)
        pid = ord(buff)
        if pid == 10 then  -- crc
            crcs = {}
            local digestdefined = _7Z.ReadBoolean(raf, numstreams, 1)
            for _, crcexist in ipairs(digestdefined) do
                if crcexist then
                    crcs[#crcs + 1] = _7Z.ReadUInt32(raf)
                end
            end
            _, buff = raf:Read(1)
            pid = ord(buff)
        end
    end
    if pid ~= 0 then  -- end id expected
        return 0
    end
    return out_packinfo
end

function _7Z.findInBinPair(bindpairs, index)
    for i = 0, #bindpairs - 1 do
        if bindpairs[i + 1] == index then
            return i
        end
    end
    return -1
end

function _7Z.ReadFolder(et, raf)
    local buff, _
    local totalin = 0
    local totalout = 0
    local out_folder = {}
    out_folder["packed_indices"] = {}
    out_folder["bindpairs"] = {}
    out_folder["coders"] = {}

    local num_coders = _7Z.ReadUInt64(raf)
    et:VPrint(0, "Number of coders: " .. num_coders .. "\n")

    for i = 0, num_coders - 1 do
        local c = {}
        _, buff = raf:Read(1)
        local b = ord(buff)
        local methodsize = b & 0xF
        local iscomplex = (b & 0x10) == 0x10
        local hasattributes = (b & 0x20) == 0x20
        if methodsize > 0 then
           _, buff = raf:Read(methodsize)
           c["method"] = buff
        else
           c["method"] = "\0"
        end
        if iscomplex then
            c["numinstreams"] = _7Z.ReadUInt64(raf)
            c["numoutstreams"] = _7Z.ReadUInt64(raf)
        else
            c["numinstreams"] = 1
            c["numoutstreams"] = 1
        end
        totalin = totalin + c["numinstreams"]
        totalout = totalout + c["numoutstreams"]
        if hasattributes then
            local proplen = _7Z.ReadUInt64(raf)
            _, buff = raf:Read(proplen)
            c["properties"] = buff
        else
            c["properties"] = nil
        end
        et:VPrint(0, "Reading coder " .. i .. "\n")
        local coders = out_folder["coders"]
        coders[#coders + 1] = c
    end
    local num_bindpairs = totalout - 1
    for _i = 1, num_bindpairs do -- luacheck: ignore _i
        local bond = { _7Z.ReadUInt64(raf), _7Z.ReadUInt64(raf) }
        local bindpairs = out_folder["bindpairs"]
        bindpairs[#bindpairs + 1] = bond[1]
        bindpairs[#bindpairs + 1] = bond[2]
    end
    local num_packedstreams = totalin - num_bindpairs
    if num_packedstreams == 1 then
        for i = 0, totalin - 1 do
            if _7Z.findInBinPair(out_folder["bindpairs"], i) < 0 then
                local packed_indices = out_folder["packed_indices"]
                packed_indices[#packed_indices + 1] = i
            end
        end
    else
        for _i = 1, num_packedstreams do -- luacheck: ignore _i
            local packed_indices = out_folder["packed_indices"]
            packed_indices[#packed_indices + 1] = _7Z.ReadUInt64(raf)
        end
    end

    return out_folder
end

function _7Z.RetrieveCodersInfo(et, raf, folders)
    local buff, _

    _, buff = raf:Read(1)
    local pid = ord(buff)

    if pid ~= 0x0c then -- coders unpack size id expected
        return 0
    end
    for _, folder in ipairs(folders) do
        folder["unpacksizes"] = {}
        for _, c in ipairs(folder["coders"]) do
            for _i = 1, c["numoutstreams"] do -- luacheck: ignore _i
                local unpacksizes = folder["unpacksizes"]
                unpacksizes[#unpacksizes + 1] = _7Z.ReadUInt64(raf)
            end
        end
    end
    _, buff = raf:Read(1)
    pid = ord(buff)

    if pid == 0x0a then  --crc
        local numfolders = #folders
        et:VPrint(0, "Number of folders: " .. numfolders .. "\n")
        local defined = _7Z.ReadBoolean(raf, numfolders, 1)
        local crcs = {}
        for _, crcexist in ipairs(defined) do
            if crcexist then
                crcs[#crcs + 1] = _7Z.ReadUInt32(raf)
            end
        end
        for i = 1, numfolders do
            folders[i]["digestdefined"] = defined[i]
            folders[i]["crc"] = crcs[i]
        end
        _, buff = raf:Read(1)
        pid = ord(buff)
    end

    if pid ~= 0x00 then -- end id expected
        et:VPrint(0, "Invalid PID: " .. pid .. "\n")
        return 0
    end
    return 1
end

function _7Z.ReadUnpackInfo(et, raf)
    local buff, _
    local out_unpackinfo = {}

    _, buff = raf:Read(1)
    local pid = ord(buff)

    if pid ~= 0xb then  -- folder id expected
        return 0
    end

    out_unpackinfo["numfolders"] = _7Z.ReadUInt64(raf)
    out_unpackinfo["folders"] = {}

    _, buff = raf:Read(1)
    local external = ord(buff)

    if external == 0x00 then
        for i = 0, out_unpackinfo["numfolders"] - 1 do
            et:VPrint(0, "Reading folder " .. i .. "\n")
            local folder = _7Z.ReadFolder(et, raf)
            local folders = out_unpackinfo["folders"]
            folders[#folders + 1] = folder
        end
    end
    if not truthy(_7Z.RetrieveCodersInfo(et, raf, out_unpackinfo["folders"])) then return 0 end
    return out_unpackinfo
end

function _7Z.ReadSubstreamsInfo(et, raf, numfolders, folders)
    local buff, _
    local out_substreamsinfo = {}
    out_substreamsinfo["num_unpackstreams_folders"] = {}

    _, buff = raf:Read(1)
    local pid = ord(buff)
    if pid == 13 then  -- num unpack stream
        et:VPrint(0, "Num unpack stream detected.\n")
        for _i = 1, numfolders do -- luacheck: ignore _i
            local nuf = out_substreamsinfo["num_unpackstreams_folders"]
            nuf[#nuf + 1] = _7Z.ReadUInt64(raf)
        end
        _, buff = raf:Read(1)
        pid = ord(buff)
    else
        for i = 1, numfolders do out_substreamsinfo["num_unpackstreams_folders"][i] = 1 end
    end
    if pid == 9 then  -- size property
        et:VPrint(0, "Size property detected.\n")
        out_substreamsinfo["unpacksizes"] = {}
        for i = 1, #out_substreamsinfo["num_unpackstreams_folders"] do
            local totalsize = 0
            for _j = 1, out_substreamsinfo["num_unpackstreams_folders"][i] - 1 do -- luacheck: ignore _j
                local size = _7Z.ReadUInt64(raf)
                local unpacksizes = out_substreamsinfo["unpacksizes"]
                unpacksizes[#unpacksizes + 1] = size
                totalsize = totalsize + size
            end
            -- self.unpacksizes.append(folders[i].get_unpack_size() - totalsize)
        end
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    local num_digests = 0
    local num_digests_total = 0
    for i = 1, numfolders do
        local numsubstreams = out_substreamsinfo["num_unpackstreams_folders"][i]
        if numsubstreams ~= 1 or not folders[i]["digestdefined"] then
            num_digests = num_digests + numsubstreams
        end
        num_digests_total = num_digests_total + numsubstreams
    end
    et:VPrint(0, "Num Digests Total: " .. num_digests_total .. "\n")
    if pid == 10 then  -- crc property
        et:VPrint(0, "CRC property detected.\n")
        local crcs = {}
        local defined = _7Z.ReadBoolean(raf, num_digests, 1)
        for _ in ipairs(defined) do
            crcs[#crcs + 1] = _7Z.ReadUInt32(raf)
        end
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    if pid ~= 0x00 then -- end id expected
        return 0
    end
    return out_substreamsinfo
end

function _7Z.ReadStreamsInfo(et, raf)
    local buff, _
    local unpackinfo
    local out_streamsinfo = {}

    _, buff = raf:Read(1)
    local pid = ord(buff)
    if pid == 6 then  -- pack info
        local packinfo = _7Z.ReadPackInfo(et, raf)
        if not truthy(packinfo) then return 0 end
        out_streamsinfo["packinfo"] = packinfo
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    if pid == 7 then  -- unpack info
        et:VPrint(0, "Unpack info data detected.\n")
        unpackinfo = _7Z.ReadUnpackInfo(et, raf)
        if not truthy(unpackinfo) then return 0 end
        out_streamsinfo["unpackinfo"] = unpackinfo
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    if pid == 8 then  -- substreams info
        et:VPrint(0, "Substreams info data detected.\n")
        local substreamsinfo = _7Z.ReadSubstreamsInfo(et, raf, unpackinfo["numfolders"], unpackinfo["folders"])
        if not truthy(substreamsinfo) then return 0 end
        out_streamsinfo["substreamsinfo"] = substreamsinfo
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    if pid ~= 0x00 then -- end id expected
        et:VPrint(0, "Invalid PID: " .. pid .. "\n")
        return 0
    end
    return out_streamsinfo
end

function _7Z.IsNativeCoder(coder)
    if ord(substr(coder["method"], 0, 1)) == 3 then
        if ord(substr(coder["method"], 1, 1)) == 1 then
            if ord(substr(coder["method"], 2, 1)) == 1 then
                return "LZMA"
            end
        end
    elseif ord(substr(coder["method"], 0, 1)) == 6 then
        if ord(substr(coder["method"], 1, 1)) == 0xf1 then
            if ord(substr(coder["method"], 2, 1)) == 7 then
                if ord(substr(coder["method"], 3, 1)) == 1 then
                    return "7zAES"
                end
            end
        end
    end
end

function _7Z.GetDecompressor(et, folder, input_size)
    local out_decompressor = {}
    out_decompressor["chain"] = {}
    out_decompressor["input_size"] = input_size
    out_decompressor["_unpacksizes"] = folder["unpacksizes"]
    out_decompressor["_unpacked"] = {}
    for i = 1, #out_decompressor["_unpacksizes"] do out_decompressor["_unpacked"][i] = 0 end
    out_decompressor["consumed"] = 0
    out_decompressor["block_size"] = 32768
    out_decompressor["_unused"] = {}

    for _, coder in ipairs(folder["coders"]) do
       local algorithm = _7Z.IsNativeCoder(coder)
       if algorithm == "7zAES" then
           et:Warn("File is encrypted.", 0)
           return 0
       else
           local chain = out_decompressor["chain"]
           chain[#chain + 1] = algorithm
       end
    end

    return out_decompressor
end

function _7Z.ReadData(et, raf, decompressor)
    local rest_size = decompressor["input_size"] - decompressor["consumed"]
    local unused_s = #decompressor["_unused"]
    local read_size = rest_size - unused_s
    local data = ""
    if read_size > decompressor["block_size"] - unused_s then
        read_size = decompressor["block_size"] - unused_s
    end
    if read_size > 0 then
        local n
        n, data = raf:Read(read_size)
        decompressor["consumed"] = decompressor["consumed"] + n
        et:VPrint(0, "Compressed size: " .. read_size .. "\n")
    end
    return data
end

-- luacheck: push ignore status
function _7Z.Decompress_Internal(decompressor, input)
    local data = carray.new('char')
    for i = 1, #decompressor["chain"] do
        if decompressor["_unpacked"][i] < decompressor["_unpacksizes"][i] then
            local opts = {}
            opts["Filter"] = Lzma.Filter.Lzma1()
            local z, status = CompressRawLzma.RawDecoder.new(opts)
            status = z:code(input, data)
            decompressor["_unpacked"][i] = decompressor["_unpacked"][i] + length(data)
        end
    end
    return data
end
-- luacheck: pop

function _7Z.Decompress(et, raf, decompressor, max_length) -- luacheck: ignore max_length
    local data = carray.new('char'):append(_7Z.ReadData(et, raf, decompressor))
    local tmp = _7Z.Decompress_Internal(decompressor, data)
    return tmp
end

function _7Z.ReadName(raf, numfiles, files)
    for i = 1, numfiles do
        files[i]["filename"] = _7Z.ReadUTF16(raf)
    end
end

function _7Z.ReadTimes(et, raf, numfiles, name, files)
    local external, _

    local defined = _7Z.ReadBoolean(raf, numfiles, 1)
    _, external = raf:Read(1)
    if ord(external) ~= 0 then
        et:Warn("Invalid or corrupted file. (ReadTimes)")
        return 0
    end

    for i = 1, numfiles do
        if defined[i] then
            local value = _7Z.ReadRealUInt64(raf)
            value = value / 10000000.0 - 11644473600
            files[i][name] = value
        else
            files[i][name] = nil
        end
    end
end

function _7Z.ReadAttributes(raf, numfiles, defined, files)
    for i = 1, numfiles do
        if defined[i] then
            local value = _7Z.ReadUInt32(raf)
            files[i]["attributes"] = value >> 8
        else
            files[i]["attributes"] = nil
        end
    end
end

function _7Z.ReadFilesInfo(et, raf)
    local buff, _

    local numfiles = _7Z.ReadUInt64(raf)
    local out_files = {}
    for _i = 1, numfiles do -- luacheck: ignore _i
        local new_file = {}
        new_file["emptystream"] = 0
        out_files[#out_files + 1] = new_file
    end
    local numemptystreams = 0 -- luacheck: ignore numemptystreams
    et:VPrint(0, "Number of files: " .. numfiles .. "\n")
    while true do
        _, buff = raf:Read(1)
        local prop = ord(buff)
        if prop == 0 then  -- end
            return out_files
        end
        local size = _7Z.ReadUInt64(raf)
        if prop == 25 then  -- dummy
            raf:Seek(size, 1)
            goto continue
        end
        _, buff = raf:Read(size)
        local buffer = RandomAccess.new(buff)
        if prop == 14 then  -- empty stream
            local isempty = _7Z.ReadBoolean(buffer, numfiles, 0)
            local numemptystreams2 = 0 -- luacheck: ignore numemptystreams2
            for i = 1, numfiles do
                if not isempty[i] then
                    out_files[i]["emptystream"] = 0
                else
                    out_files[i]["emptystream"] = 1
                    numemptystreams2 = numemptystreams2 + 1
                end
            end
        -- luacheck: push ignore 542
        elseif prop == 15 then  -- empty file

        -- luacheck: pop
        elseif prop == 17 then  -- name
            et:VPrint(0, "Name prop detected.\n")
            local external
            _, external = buffer:Read(1)
            local is_external = ord(external)
            if is_external == 0 then
                _7Z.ReadName(buffer, numfiles, out_files)
            end
        elseif prop == 20 then  -- last write time
            et:VPrint(0, "Last write time detected.\n")
            _7Z.ReadTimes(et, buffer, numfiles, "lastwritetime", out_files)
        elseif prop == 21 then  -- attributes
            local external
            et:VPrint(0, "File attributes detected.\n")
            local defined = _7Z.ReadBoolean(buffer, numfiles, 1)
            _, external = raf:Read(1)
            if ord(external) == 0 then
                _7Z.ReadAttributes(buffer, numfiles, defined, out_files)
            else
                local dataindex = _7Z.ReadUINT64(buffer) -- luacheck: ignore dataindex
                --TODO: try to read external data
            end
        end
        ::continue::
    end
end

function _7Z.ExtractHeaderInfo(et, raf)
    local buff, _
    local out_headerinfo = {}
    out_headerinfo["files_info"] = {}
    local files_info

    _, buff = raf:Read(1)
    local pid = ord(buff)

    if pid == 0x04 then
        local mainstreams = _7Z.ReadStreamsInfo(et, raf)
        if mainstreams == 0 then
            et:Warn("Invalid or corrupted file. (ExtractHeaderInfo)")
            return 0
        end
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    if pid == 0x05 then
        et:VPrint(0, "File info pid reached.\n")
        files_info = _7Z.ReadFilesInfo(et, raf)
        local fi = out_headerinfo["files_info"]
        fi[#fi + 1] = files_info
        _, buff = raf:Read(1)
        pid = ord(buff)
    end
    if pid ~= 0x00 then -- end id expected
        et:VPrint(0, "Invalid PID: " .. pid .. "\n")
        return 0
    end
    return out_headerinfo
end

function _7Z.DisplayFiles(et, files)
   local docNum = 0
   local tagTablePtr = et:GetTagTable('lexiftool.ZIP.RAR5')

   for _, currentfile in ipairs(files) do
       docNum = docNum + 1
       et.DOC_NUM = docNum
       et:HandleTag(tagTablePtr, 'ModifyDate', currentfile["lastwritetime"])
       et:HandleTag(tagTablePtr, 'ArchivedFileName', currentfile["filename"])
   end
   et.DOC_NUM = nil
   if docNum > 1 and not truthy(et:Options('Duplicates')) then
      et:Warn("Use the Duplicates option to extract tags for all " .. docNum .. " files", 1)
   end
end

--------------------------------------------------------------------------------
-- Extract information from a 7z file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid 7z file
function _7Z.Process7Z(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, _

    local n
    n, buff = raf:Read(6)
    if not (n == 6 and buff == "7z\xbc\xaf\x27\x1c") then return 0 end

    et:SetFileType()

    _, buff = raf:Read(2)
    local major_version, minor_version = unpack_('cc', buff)
    local tagTablePtr = et:GetTagTable('lexiftool.ZIP.RAR5')
    et:HandleTag(tagTablePtr, 'FileVersion', sprintf('7z v%d.%.2d', major_version, minor_version))

    raf:Seek(4, 1)  -- skip Start Header CRC

    _, buff = raf:Read(20)
    local nextheaderoffset, nextheadersize = unpack_('QQx', buff)
    et:VPrint(0, "NextHeaderOffset: " .. nextheaderoffset .. ", NextHeaderSize: " .. nextheadersize .. "\n")

    raf:Seek(nextheaderoffset, 1)  -- going to next header offset
    _, buff = raf:Read(1)
    local pid = ord(buff)
    if pid == 1 then  -- normal header
        et:VPrint(0, "Normal header detected. trying to decode\n")
        local headerinfo = _7Z.ExtractHeaderInfo(et, raf)
        if headerinfo == 0 then
            et:Warn("Invalid or corrupted file.")
            return 1
        end
        -- (upstream flattens @{ $headerinfo->{"files_info"} }; its only
        --  element is the file list DisplayFiles then walks)
        _7Z.DisplayFiles(et, headerinfo["files_info"][1])
    elseif pid == 23 then  -- encoded header
        local haveLzma
        haveLzma, CompressRawLzma = perl.evalRequire('Compress::Raw::Lzma')
        if not haveLzma then
            et:Warn("Install Compress::Raw::Lzma to read encoded 7z information")
            return 1
        end
        Lzma = CompressRawLzma.Lzma
        et:VPrint(0, "Encoded Header detected. trying to decode\n")
        local streamsinfo = _7Z.ReadStreamsInfo(et, raf)
        if streamsinfo == 0 then
            et:Warn("Invalid or corrupted file.")
            return 1
        end
        local buffer2
        for _, folder in ipairs(streamsinfo["unpackinfo"]["folders"]) do
            local uncompressed = folder["unpacksizes"]
            local compressed_size = streamsinfo["packinfo"]["packsizes"][1]
            local uncompressed_size = uncompressed[#uncompressed]
            local decomporessor = _7Z.GetDecompressor(et, folder, compressed_size)
            if decomporessor == 0 then
                et:Warn("Invalid or corrupted file.")
                return 1
            end

            local src_start = 32
            src_start = src_start + streamsinfo["packinfo"]["packpos"]
            raf:Seek(src_start, 0)
            local remaining = uncompressed_size
            local folder_data = carray.new('char')
            while remaining > 0 do
                folder_data:append(_7Z.Decompress(et, raf, decomporessor, remaining))
                remaining = uncompressed_size - length(folder_data)
            end
            buffer2 = RandomAccess.new(folder_data)
        end
        buffer2:Seek(0, 0)
        _, buff = buffer2:Read(1)
        pid = ord(buff)
        if pid ~= 0x01 then -- header field expected
            return 0
        end
        local headerinfo = _7Z.ExtractHeaderInfo(et, buffer2)
        if headerinfo == 0 then
            et:Warn("Invalid or corrupted file.")
            return 1
        end
        _7Z.DisplayFiles(et, headerinfo["files_info"][1])
    else  -- Unknown header
        return 0
    end

    return 1
end

return _7Z
