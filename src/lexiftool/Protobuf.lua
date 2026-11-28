--------------------------------------------------------------------------------
-- File:         lexiftool/Protobuf.lua
-- Ported from:  lib/Image/ExifTool/Protobuf.pm
--
-- Description:  Decode protocol buffer data
--
-- Revisions:    2024-12-04 - P. Harvey Created
--
-- Notes:        Tag definitions for Protobuf tags support 'signed', 'unsigned',
--               and 'int64s' formats for VARINT (type 0) values, 'int64u',
--               'int64s', 'rational64u', 'rational64s' and 'double' for I64
--               (type 1), 'undef', 'string' and 'rational' for LEN (type 2),
--               and 'int32u', 'int32s', 'rational32u', 'rational32s',
--               'fixed32u', 'fixed32s' and 'float' for I32 (type 5) values.
--
-- References:   1) https://protobuf.dev/programming-guides/encoding/
--
-- Port notes:   ported in full (GetBytes, VarInt, ReadRecord, IsProtobuf,
--               ProcessProtobuf). Tag definitions for Protobuf tags support
--               'signed', 'unsigned' and 'int64s' formats for VARINT
--               (type 0) values, 'int64u', 'int64s', 'rational64u',
--               'rational64s' and 'double' for I64 (type 1), 'undef',
--               'string' and 'rational' for LEN (type 2), and 'int32u',
--               'int32s', 'rational32u', 'rational32s', 'fixed32u',
--               'fixed32s' and 'float' for I32 (type 5) values.
--               VarInt's UV arithmetic goes through perl.uv (Perl's UVs
--               >= 2^63, doc/conventions.md §3b).
--               A tag ID that is the bare field number (no protocol prefix,
--               no parent IDs) also finds a number key, as Perl's string key
--               "1" does in the numbered sub-tables (DJI GPSInfo and others).
--               GetBytes and VarInt read a Lua string directly (string.sub,
--               string.byte; NextByte is VarInt's ord(GetBytes(.., 1))) and
--               go through the facade only for a carray: they run once per
--               byte of a protobuf and dominated the time of Google HDRP
--               data.
--               ReadRecord and IsProtobuf read through lexiftool.util
--               (pbRecord, pbIsProtobuf in src/lexiftool/util.c), which
--               implement upstream's reader for VarInts of up to 9 bytes
--               (values below 2^63, exact Lua integers) and leave Pos, Bit0
--               and the undef of an error as upstream does. A record with a
--               longer VarInt (UV/double arithmetic, the 33-byte limit) is
--               read by the Lua version kept here (ReadRecordLua, also the
--               VarInt of the rational checks), so those semantics live in
--               one place; IsProtobuf then checks the whole buffer in Lua.
--               ProcessProtobuf's record loop body is the local function
--               ProcessRecord (line for line; `next`/`last` are `return
--               true`/`return false`, so `my $val` is a fresh local per
--               record as upstream's), run by the loop and, at the top level
--               of a string without Unknown, Verbose or HtmlDump, by the
--               walker of lexiftool.util (util.pbWalk), which skips the
--               records the body would only read and enters the Unknown
--               sub-messages itself (see ProcessProtobuf and util.c).
--               GetBytes compares `n > length - pos` instead of upstream's
--               `pos + n > length`: the same test, but a Lua integer sum
--               would wrap for a 9-byte length near 2^63 where Perl's turns
--               into a double.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local perl = require('lexiftool.perl')
local ord = perl.ord
local sprintf = perl.sprintf
local str = perl.str
local int = perl.int
local uv = perl.uv
local truthy = perl.truthy
local util = require('lexiftool.util')
local pbRecord, pbIsProtobuf = util.pbRecord, util.pbIsProtobuf
local ssub, sbyte = string.sub, string.byte

local Protobuf = {}

-- largest unsigned integer on this system (2^32 or 2^64 - 1)
-- (uv: Perl's ~0 and the literal below are UVs, see perl.uv)
local intMax = uv(~0)

-- smallest unsigned integer that we interpret as int64s (0xffffffff00000000)
local int64sMin = uv(0xffffffff00000000)

-- formats that are protobuf only
local protoOnly = { ['signed'] = 1, ['unsigned'] = 1 }

--------------------------------------------------------------------------------
-- Read bytes from dirInfo object
-- Inputs: 0) dirInfo ref (with DataPt and Pos set), 1) number of bytes
-- Returns: binary data or undef on error
local function GetBytes(dirInfo, n)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.Pos
    -- (port: upstream's `$pos + $n > length`, rearranged so that a length
    --  near 2^63 cannot wrap the integer sum)
    if n > #dataPt - pos then return nil end
    dirInfo.Pos = pos + n
    -- (port: a Lua string is sliced directly, the facade's substr only for
    --  a carray -- this and NextByte are the hot path of every record)
    if type(dataPt) == 'string' then return ssub(dataPt, pos + 1, pos + n) end
    return substr(dataPt, pos, n)
end

-- (port: ord(GetBytes($dirInfo, 1)) of VarInt as one step -- the byte's
--  value, read without making a one-byte string)
local function NextByte(dirInfo)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.Pos
    if pos + 1 > #dataPt then return nil end
    dirInfo.Pos = pos + 1
    if type(dataPt) == 'string' then return sbyte(dataPt, pos + 1) end
    return ord(substr(dataPt, pos, 1))
end

--------------------------------------------------------------------------------
-- Read variable-length integer
-- Inputs: 0) dirInfo ref
-- Returns: integer value
-- - sets dirInfo.Bit0 according to bit 0 of returned value
--   (necessary for cases where a signed integer exceeds $intMax)
local function VarInt(dirInfo)
    local byte = NextByte(dirInfo)   -- (port: the value of GetBytes($dirInfo, 1))
    if byte == nil then return nil end
    local val = byte & 0x7f
    dirInfo.Bit0 = val & 0x01
    local mult = 128
    local i = 0
    while true do
        if byte & 0x80 == 0 then break end
        byte = NextByte(dirInfo)
        if byte == nil then return nil end
        val = val + (byte & 0x7f) * mult
        if byte & 0x80 == 0 then break end
        i = i + 1
        if i > 32 then return nil end -- set a reasonable limit
        mult = uv(mult * 128) -- (Note: don't use integer bit shift to avoid integer overflow)
    end
    return val
end

--------------------------------------------------------------------------------
-- Read protobuf record
-- Inputs: 0) dirInfo ref
-- Returns: 0) record payload (plus tag id and format type in list context) or undef on error
-- Notes: Updates dirInfo.Pos to start of next record, and sets dirInfo.Bit0
--        according to the least significant bit of type 0 (varInt) records
-- (port: the Lua reader, for the records lexiftool.util leaves to it)
local function ReadRecordLua(dirInfo)
    local val = VarInt(dirInfo)
    if val == nil then return nil end
    local id = val >> 3
    local type_ = val & 0x07
    local buff
    if type_ == 0 then -- varInt
        buff = VarInt(dirInfo)
    elseif type_ == 1 then -- 64-bit number
        buff = GetBytes(dirInfo, 8)
    elseif type_ == 2 then -- string, bytes or protobuf
        local len = VarInt(dirInfo)
        -- (upstream `if ($len)`: a length that can't be read gives an empty
        --  payload, not an error)
        if len ~= nil and len ~= 0 then
            buff = GetBytes(dirInfo, len)
        else
            buff = ''
        end
    elseif type_ == 3 then -- (deprecated start group)
        buff = ''
    elseif type_ == 4 then -- (deprecated end group)
        buff = ''
    elseif type_ == 5 then -- 32-bit number
        buff = GetBytes(dirInfo, 4)
    end
    return buff, id, type_
end

-- (port: the record read natively by util.pbRecord with the same results
--  and the same Pos and Bit0; false from it means a VarInt of 10 or more
--  bytes somewhere in the record, read by ReadRecordLua from the start)
local function ReadRecord(dirInfo)
    local buff, id, type_, newpos, bit0 = pbRecord(dirInfo.DataPt, dirInfo.Pos)
    if buff == false then return ReadRecordLua(dirInfo) end
    dirInfo.Pos = newpos
    if bit0 ~= nil then dirInfo.Bit0 = bit0 end
    return buff, id, type_
end

--------------------------------------------------------------------------------
-- Check to see if this could be a protobuf object
-- Inputs: 0) data reference
-- Retursn: true if this looks like a protobuf
function Protobuf.IsProtobuf(data)
    -- (port: natively unless a VarInt of 10 or more bytes needs the Lua
    --  reader, util.pbIsProtobuf then answers nil)
    local isPb = pbIsProtobuf(data)
    if isPb ~= nil then return isPb end
    local dirInfo = { DataPt = data, Pos = 0 }
    while true do
        local rec = ReadRecordLua(dirInfo)
        if rec == nil then return false end
        if dirInfo.Pos == #data then return true end
    end
end

--------------------------------------------------------------------------------
-- (port: the body of ProcessProtobuf's record loop, line for line, as a
--  function -- upstream's `next` is `return true`, `last` is `return
--  false` -- so that both the loop below and the walker of lexiftool.util
--  run it for one record. walk (set by the walker only): an Unknown
--  sub-message is not processed here but returned to the walker, which
--  enters it itself (second result: "$prefix$id-"), see ProcessProtobuf.)
local function ProcessRecord(et, dirInfo, tagTbl, prefix, dataPt, dirName, dirEnd, dataPos, unknown, unkPre, walk)
        local pos = dirInfo.Pos
        if pos >= dirEnd then return false end
        local buff, id, type_ = ReadRecord(dirInfo)
        if buff == nil then
            et:Warn('Protobuf format error')
            return false
        end
        if type_ == 2 and perl.matches(buff, [[\.proto$]]) then
            -- save protocol name separately for directory type
            et.ProtoPrefix[dirName] = substr(buff, 0, -6) .. '_'
            et:HandleTag(tagTbl, 'Protocol', buff)
        end
        local protoPre = et.ProtoPrefix[dirName]
        local tag = protoPre .. prefix .. id
        -- (the Perl hash key "1" is also the number key 1 of the numbered tag
        --  tables such as DJI GPSInfo; only a bare field number can be one)
        if prefix == '' and protoPre == '' and tagTbl[tag] == nil and tagTbl[id] ~= nil then tag = id end
        local tagInfo = tagTbl[tag]
        if tagInfo then
            if type_ ~= 2 and tagInfo.Unknown and not truthy(unknown) then
                return true
            end
        else
            if not (type_ == 2 or truthy(unknown)) then return true end
            tagInfo = ExifTool.AddTagToTable(tagTbl, tag, { Unknown = 1 })
        end
        -- set IsProtobuf flag (only for Unknown tags) if necessary
        if type_ == 2 and tagInfo.Unknown then
            if tagInfo.IsProtobuf then
                if not Protobuf.IsProtobuf(buff) then tagInfo.IsProtobuf = false end
            elseif tagInfo.IsProtobuf == nil and perl.matches(buff, '[^\\x20-\\x7e]') and
                Protobuf.IsProtobuf(buff) then
                tagInfo.IsProtobuf = true
            end
            if not (tagInfo.IsProtobuf or truthy(unknown)) then return true end
        end
        -- format binary payload into a useful value
        local val
        local format = tagInfo.Format
        if format then
            if type_ == 0 then
                val = buff
                if format == 'signed' then
                    if val > intMax then
                        -- use double math (15 decimal digits precision)
                        if dirInfo.Bit0 ~= 0 then
                            val = -int(val / 2) - 1
                        else
                            val = val / 2
                        end
                    else
                        -- use integer math (Lua's >> is a logical shift, as on a UV)
                        if (val & 1) ~= 0 then val = -(val >> 1) - 1 else val = val >> 1 end
                    end
                elseif format == 'int64s' and val >= int64sMin then
                    -- hack for DJI drones which store 64-bit signed integers improperly
                    -- (just toss upper 32 bits which should be all 1's anyway)
                    -- Note: do the two subtractions because int64sMin + 4294967296
                    -- is too large for a 64-bit integer
                    val = val - int64sMin - 4294967296
                end
            elseif type_ == 2 and format == 'rational' then
                local dir = { DataPt = buff, Pos = 0 }
                local num = VarInt(dir)
                local den = VarInt(dir)
                if num ~= nil and den ~= nil and den ~= 0 then
                    val = num / den
                else
                    val = 'err'
                end
            else
                if protoOnly[format] then format = 'undef' end -- (just in case)
                val = ExifTool.ReadValue(buff, 0, format, nil, #buff)
            end
        elseif type_ == 0 then -- varInt
            val = buff
            local hex = sprintf('%x', val)
            if val >= int64sMin then
                local s64 = val - int64sMin - 4294967296
                val = str(val) .. ' (0x' .. hex .. ', int64s ' .. str(s64) .. ')'
            else
                local signed
                if val > intMax then
                    if dirInfo.Bit0 ~= 0 then
                        signed = -int(val / 2) - 1
                    else
                        signed = val / 2
                    end
                else
                    if (val & 1) ~= 0 then signed = -(val >> 1) - 1 else signed = val >> 1 end
                end
                val = str(val) .. ' (0x' .. hex .. ', signed ' .. str(signed) .. ')'
            end
        elseif type_ == 1 then -- 64-bit number
            val = '0x' .. perl.unpack('H*', buff) ..
                ' (double ' .. ExifTool.NumStr(ExifTool.GetDouble(buff, 0)) .. ')'
        elseif type_ == 2 then -- string, bytes or protobuf
            -- (fall through to process known SubDirectory)
            if tagInfo.SubDirectory == nil and tagInfo.IsProtobuf then
                -- process Unknown protobuf directories
                if walk then return true, prefix .. id .. '-' end -- (port: the walker enters it)
                et:VPrint(1, et.INDENT, unkPre, tag, ' (', #buff, ' bytes)', ' -->\n')
                local addr = dataPos + dirInfo.Pos - #buff
                et:VerboseDump(buff, { Addr = addr, Prefix = et.INDENT })
                local subdir = { DataPt = buff, DataPos = addr, DirName = dirName }
                et.INDENT = et.INDENT .. '| '
                Protobuf.ProcessProtobuf(et, subdir, tagTbl, prefix .. id .. '-')
                et.INDENT = substr(et.INDENT, 0, -2)
                return true
            elseif tagInfo.SubDirectory == nil then
                -- check for rational value (2 varInt values)
                local rat
                local dir = { DataPt = buff, Pos = 0 }
                local num = VarInt(dir)
                if num ~= nil then
                    local denom = VarInt(dir)
                    if denom ~= nil and denom ~= 0 and dir.Pos == #buff then
                        rat = ' (rational ' .. str(num) .. '/' .. str(denom) .. ')'
                    end
                end
                -- upstream: `$buff !~ /[^\r\n\t\x20-\x7e]/` (nothing but
                -- printable ASCII plus CR/LF/TAB) means an ASCII string
                if not perl.matches(buff, '[^\\x0d\\x0a\\x09\\x20-\\x7e]') then
                    val = buff -- assume this is an ASCII string
                elseif #buff % 4 ~= 0 then
                    val = '0x' .. perl.unpack('H*', buff)
                else
                    -- (do this instead of '(H8)*' because older Perl version didn't support this)
                    local blocks = {}
                    for i = 1, #buff, 4 do -- (group in 4-byte blocks)
                        blocks[#blocks + 1] = perl.unpack('H8', buff:sub(i, i + 3))
                    end
                    val = '0x' .. table.concat(blocks, ' ')
                end
                if rat then val = val .. rat end
            end
        elseif type_ == 5 then -- 32-bit number
            val = '0x' .. perl.unpack('H*', buff) ..
                ' (int32u ' .. ExifTool.Get32u(buff, 0)
            if buff:byte(4) & 0x80 ~= 0 then
                val = val .. ', int32s ' .. ExifTool.Get32s(buff, 0)
            end
            val = val .. ', float ' .. ExifTool.NumStr(ExifTool.GetFloat(buff, 0)) .. ')'
        else
            val = buff
        end
        -- get length of data in the record
        local start = (type_ == 0) and pos + 1 or dirInfo.Pos - #buff
        et:HandleTag(tagTbl, tag, val, {
            DataPt = dataPt,
            DataPos = dataPos,
            Start = start,
            Size = dirInfo.Pos - start,
            Extra = ', type=' .. type_,
            Format = format,
        })
        return true
end

--------------------------------------------------------------------------------
-- Process protobuf data (eg. DJI djmd timed data from Action4 videos) (ref 1)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref with DataPt, DataPos, DirName and Base,
--         2) tag table ptr, 3) prefix of parent protobuf ID's
-- Returns: true on success
function Protobuf.ProcessProtobuf(et, dirInfo, tagTbl, prefix)
    local dataPt = dirInfo.DataPt
    local dirName = dirInfo.DirName
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (#dataPt - dirStart)
    local dirEnd = dirStart + dirLen
    local dataPos = (dirInfo.Base or 0) + (dirInfo.DataPos or 0)
    local unknown = truthy(et:Options('Unknown')) and et:Options('Unknown') or et:Options('Verbose')
    -- (port: the walker of lexiftool.util takes the top level of a string
    --  without Unknown, Verbose or HtmlDump, see below)
    local walk = not prefix and not truthy(unknown) and not et.HTML_DUMP and type(dataPt) == 'string' and
        math.type(dirStart) == 'integer' and dirStart >= 0 and math.type(dirEnd) == 'integer' and
        math.type(dataPos) == 'integer'

    dirInfo.Pos = dirStart -- initialize buffer Pos
    et:VerboseDir('Protobuf', nil, dirLen)
    if not prefix then
        prefix = ''
        et.ProtoPrefix = et.ProtoPrefix or {}
        if et.ProtoPrefix[dirName] == nil then et.ProtoPrefix[dirName] = '' end
        ExifTool.SetByteOrder('II')
    end
    -- prefix for unknown tags
    local unkPre = truthy(tagTbl.TAG_PREFIX) and tagTbl.TAG_PREFIX .. '_' or 'Protobuf '

    if walk then
        -- (port: the records and sub-messages in C, util.pbWalk, iteratively:
        --  a record that ProcessRecord would only read is skipped there, an
        --  Unknown sub-message it would process (IsProtobuf set and true, no
        --  Format or SubDirectory) is entered there, every other record
        --  comes here, to ProcessRecord, with its level's dirInfo (an
        --  upstream %subdir below the top), data, $dataPos, $dirEnd,
        --  prefix and $$et{INDENT}. Mode 1: a sub-message goes back to C
        --  (walk); 0: ProcessRecord recurses itself, the nested call takes
        --  the loop below (a 10-byte VarInt, or deeper than the walker's
        --  levels: there the Lua recursion goes on as before, so no new
        --  limit); -1: the rest of the level after a Pos that is no
        --  integer. Without Unknown and Verbose the skipped records have no
        --  effect but Pos and Bit0, which pbWalk returns, and the verbose
        --  calls of a recursion print nothing.)
        local baseIndent = et.INDENT
        local function record(d, data, dpos, dend, pos, pfx, depth, mode)
            if depth > 0 then et.INDENT = baseIndent .. ('| '):rep(depth) end
            local r, subPrefix
            if mode < 0 then
                while ProcessRecord(et, d, tagTbl, pfx, data, dirName, dend, dpos, unknown, unkPre) do end
                r = false
            else
                d.Pos = pos
                r, subPrefix = ProcessRecord(et, d, tagTbl, pfx, data, dirName, dend, dpos, unknown, unkPre, mode == 1)
            end
            et.INDENT = baseIndent
            if r == false then return false end
            return d.Pos, subPrefix
        end
        local pos, bit0 = util.pbWalk(dataPt, dirStart, dirEnd, dataPos, dirInfo, tagTbl, et, dirName, record)
        if pos ~= nil then dirInfo.Pos = pos end
        if bit0 ~= nil then dirInfo.Bit0 = bit0 end
    else
    while ProcessRecord(et, dirInfo, tagTbl, prefix, dataPt, dirName, dirEnd, dataPos, unknown, unkPre) do end -- loop through protobuf records
    end
    -- warn if we didn't finish exactly at the end of the buffer
    if not (truthy(prefix) or dirInfo.Pos == dirEnd) then
        et:Warn('Truncated protobuf data')
    end
    return true
end

-- (test hook: the readers, for src/test/test_protobuf.lua)
Protobuf._ReadRecord = ReadRecord
Protobuf._ReadRecordLua = ReadRecordLua

return Protobuf
