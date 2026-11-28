--------------------------------------------------------------------------------
-- File:         test/test_protobuf.lua
--
-- Description:  unit tests for the native protobuf reader of lexiftool.util
--               (src/lexiftool/util.c: pbRecord, pbIsProtobuf) against the
--               Lua reader of Protobuf.lua (ReadRecordLua, a port of
--               Image::ExifTool::Protobuf::ReadRecord): payload, id, type,
--               Pos and Bit0 after every record of hand-built buffers --
--               VarInts of 9 and 10 bytes, non-minimal encodings, truncated
--               headers and lengths, lengths past the end, every wire type,
--               a carray -- and of seeded random data; the fallback (false,
--               nil) for VarInts of 10 or more bytes.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is = TestLib.is
local ok = TestLib.ok
local util = require('lexiftool.util')
local Protobuf = require('lexiftool.Protobuf')
local carray = require('carray')

local ReadRecord, ReadRecordLua = Protobuf._ReadRecord, Protobuf._ReadRecordLua

local function show(v)
    if type(v) == 'string' then return string.format('%q', v) end
    if type(v) == 'number' then return math.type(v) .. ':' .. tostring(v) end
    return type(v) .. ':' .. tostring(v)
end

-- one record read from dirInfo (Pos and Bit0 given), as a comparable string
local function record(reader, data, pos, bit0)
    local dirInfo = { DataPt = data, Pos = pos, Bit0 = bit0 }
    local buff, id, type_ = reader(dirInfo)
    return table.concat({ show(buff), show(id), show(type_),
        'Pos=' .. show(dirInfo.Pos), 'Bit0=' .. show(dirInfo.Bit0) }, ' ')
end

-- all records from pos 0 until an error or the end, as ProcessProtobuf
-- reads them (dirEnd = length)
local function records(reader, data)
    local dirInfo = { DataPt = data, Pos = 0 }
    local out = {}
    while dirInfo.Pos < #data do
        local buff, id, type_ = reader(dirInfo)
        out[#out + 1] = table.concat({ show(buff), show(id), show(type_),
            show(dirInfo.Pos), show(dirInfo.Bit0) }, ',')
        if buff == nil then break end
    end
    return table.concat(out, ' | ')
end

local function isProtobufLua(data)
    local dirInfo = { DataPt = data, Pos = 0 }
    while true do
        if ReadRecordLua(dirInfo) == nil then return false end
        if dirInfo.Pos == #data then return true end
    end
end

-- C path and Lua path agree; native says whether util.pbRecord reads the
-- record itself (true) or falls back (false)
local function same(name, data, pos, native, expect)
    pos = pos or 0
    local got = record(ReadRecord, data, pos, 7)
    is(record(ReadRecordLua, data, pos, 7), got, name .. ': C = Lua')
    if expect then is(expect, got, name .. ': expected') end
    local r = util.pbRecord(data, pos)
    if native then
        ok(r ~= false, name .. ': read natively')
    else
        is(false, r, name .. ': falls back to Lua')
    end
end

local function hex(s) return (s:gsub('%s', ''):gsub('..', function(h) return string.char(tonumber(h, 16)) end)) end

-- wire types --------------------------------------------------------------

same('type 0', hex('08 96 01'), 0, true, 'integer:150 integer:1 integer:0 Pos=integer:3 Bit0=integer:0')
same('type 1', hex('09 0102030405060708'), 0, true, '"\\1\\2\\3\\4\\5\\6\\7\\8" integer:1 integer:1 Pos=integer:9 Bit0=integer:1')
same('type 2', hex('12 03 616263'), 0, true, '"abc" integer:2 integer:2 Pos=integer:5 Bit0=integer:1')
same('type 2, length 0', hex('12 00 ff'), 0, true, '"" integer:2 integer:2 Pos=integer:2 Bit0=integer:0')
same('type 3', hex('1b ff'), 0, true, '"" integer:3 integer:3 Pos=integer:1 Bit0=integer:1')
same('type 4', hex('24'), 0, true, '"" integer:4 integer:4 Pos=integer:1 Bit0=integer:0')
same('type 5', hex('2d 01020304'), 0, true, '"\\1\\2\\3\\4" integer:5 integer:5 Pos=integer:5 Bit0=integer:1')
same('type 6', hex('36 01020304'), 0, true, 'nil:nil integer:6 integer:6 Pos=integer:1 Bit0=integer:0')
same('type 7', hex('3f 01020304'), 0, true, 'nil:nil integer:7 integer:7 Pos=integer:1 Bit0=integer:1')

-- truncation --------------------------------------------------------------

same('empty data', '', 0, true, 'nil:nil nil:nil nil:nil Pos=integer:0 Bit0=integer:7')
same('position at the end', hex('08 01'), 2, true, 'nil:nil nil:nil nil:nil Pos=integer:2 Bit0=integer:7')
same('position past the end', hex('08 01'), 5, true, 'nil:nil nil:nil nil:nil Pos=integer:5 Bit0=integer:7')
same('truncated header', hex('89 80'), 0, true, 'nil:nil nil:nil nil:nil Pos=integer:2 Bit0=integer:1')
same('truncated type 0 value', hex('08 96'), 0, true, 'nil:nil integer:1 integer:0 Pos=integer:2 Bit0=integer:0')
same('type 0 value missing', hex('08'), 0, true, 'nil:nil integer:1 integer:0 Pos=integer:1 Bit0=integer:0')
same('truncated type 1', hex('09 01020304'), 0, true, 'nil:nil integer:1 integer:1 Pos=integer:1 Bit0=integer:1')
same('truncated type 5', hex('2d 0102'), 0, true, 'nil:nil integer:5 integer:5 Pos=integer:1 Bit0=integer:1')
same('type 2, length missing', hex('12'), 0, true, '"" integer:2 integer:2 Pos=integer:1 Bit0=integer:0')
same('type 2, truncated length', hex('12 85'), 0, true, '"" integer:2 integer:2 Pos=integer:2 Bit0=integer:1')
same('type 2, length past the end', hex('12 05 6162'), 0, true, 'nil:nil integer:2 integer:2 Pos=integer:2 Bit0=integer:1')
same('type 2, length one past the end', hex('12 03 6162'), 0, true)
same('type 2, length exactly to the end', hex('12 02 6162'), 0, true)
-- a 9-byte length of 2^63 - 1: Perl's $pos + $n turns into a double,
-- GetBytes compares n > length - pos so the Lua integer cannot wrap
same('type 2, length 2^63 - 1', hex('12 ffffffffffffffff7f 61'), 0, true, 'nil:nil integer:2 integer:2 Pos=integer:10 Bit0=integer:1')
same('record in the middle', hex('08 01 12 02 6162 08 02'), 2, true, '"ab" integer:2 integer:2 Pos=integer:6 Bit0=integer:0')

-- VarInt lengths ----------------------------------------------------------

same('non-minimal VarInt', hex('08 8080808000'), 0, true, 'integer:0 integer:1 integer:0 Pos=integer:6 Bit0=integer:0')
same('non-minimal header', hex('88 80 00 05'), 0, true, 'integer:5 integer:1 integer:0 Pos=integer:4 Bit0=integer:1')
same('9-byte VarInt, 2^63 - 1', hex('08 ffffffffffffffff7f'), 0, true,
    'integer:9223372036854775807 integer:1 integer:0 Pos=integer:10 Bit0=integer:1')
same('9-byte VarInt, 2^56', hex('08 808080808080808001'), 0, true,
    'integer:72057594037927936 integer:1 integer:0 Pos=integer:10 Bit0=integer:0')
same('9-byte VarInt, truncated', hex('08 ffffffffffffffff'), 0, true)
same('10-byte VarInt, 10th byte 0x01', hex('08 ffffffffffffffffff01'), 0, false)
same('10-byte VarInt, 10th byte 0x02', hex('08 ffffffffffffffffff02'), 0, false)
same('10-byte VarInt, 2^63', hex('08 80808080808080808001'), 0, false)
same('10-byte VarInt truncated at the 10th byte', hex('08 ffffffffffffffffff'), 0, false)
same('10-byte VarInt length', hex('12 82808080808080808000 6162'), 0, false)
same('10-byte header', hex('88808080808080808000 01'), 0, false)
same('34-byte VarInt (over the limit)', hex('08') .. ('\x80'):rep(33) .. '\x01', 0, false)

-- carray input ------------------------------------------------------------
-- (util.pbRecord reads a carray like the string of its bytes; the Lua
--  reader itself takes a Lua string only -- # of a carray is not its
--  length -- so the string is its reference)

local function ca(s) return carray.new('char'):append(s) end
local function sameCarray(name, s, native)
    local got = record(ReadRecord, ca(s), 0, 7)
    is(record(ReadRecordLua, s, 0, 7), got, name .. ': C on carray = Lua on string')
    local r = util.pbRecord(ca(s), 0)
    if native then ok(r ~= false, name .. ': read natively')
    else is(false, r, name .. ': falls back to Lua') end
end
sameCarray('carray, type 2', hex('12 03 616263'), true)
sameCarray('carray, type 0', hex('08 96 01'), true)
sameCarray('carray, truncated', hex('2d 0102'), true)
sameCarray('carray, empty', '', true)
is(false, util.pbRecord(ca(hex('08 ffffffffffffffffff01')), 0), 'carray, 10-byte VarInt: falls back to Lua')

-- whole buffers and IsProtobuf -------------------------------------------

local function isPb(name, data, expectC, expect)
    is(expectC, util.pbIsProtobuf(data), name .. ': pbIsProtobuf')
    is(expect, Protobuf.IsProtobuf(data), name .. ': IsProtobuf')
    is(isProtobufLua(data), Protobuf.IsProtobuf(data), name .. ': IsProtobuf = Lua')
    is(records(ReadRecordLua, data), records(ReadRecord, data), name .. ': records C = Lua')
end
isPb('IsProtobuf, valid', hex('08 96 01 12 03 616263 2d 01020304 1b 24'), true, true)
isPb('IsProtobuf, empty', '', false, false)
isPb('IsProtobuf, trailing garbage', hex('08 01 ff'), false, false)
isPb('IsProtobuf, wire type 6', hex('08 01 36'), false, false)
isPb('IsProtobuf, truncated length ends the data', hex('08 01 12 85'), true, true)
isPb('IsProtobuf, text', 'Hello, world', false, false)
isPb('IsProtobuf, 10-byte VarInt (fallback)', hex('08 01 08 ffffffffffffffffff01'), nil, true)
isPb('IsProtobuf, 10-byte VarInt, then garbage', hex('08 ffffffffffffffffff01 ff'), nil, false)
is(true, util.pbIsProtobuf(ca(hex('08 96 01 12 01 61'))), 'IsProtobuf, carray: pbIsProtobuf')
is(false, util.pbIsProtobuf(ca(hex('08 96'))), 'IsProtobuf, truncated carray: pbIsProtobuf')
is(nil, util.pbIsProtobuf(ca(hex('08 ffffffffffffffffff01'))), 'IsProtobuf, carray, 10-byte VarInt: pbIsProtobuf')

-- seeded random data: C = Lua for every record and IsProtobuf ------------

local seed = 20261121
local function rnd(n)   -- a small LCG, independent of math.random's version
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end
local pool = { 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a, 0x0d, 0x12, 0x1b, 0x24, 0x2d, 0x36, 0x3f,
    0x7f, 0x80, 0x81, 0xff, 0x03, 0x05 }
local diffRec, diffPb, native = 0, 0, 0
for _ = 1, 3000 do
    local bytes = {}
    for i = 1, rnd(24) do
        bytes[i] = rnd(3) == 0 and rnd(256) or pool[rnd(#pool) + 1]
    end
    local data = string.char(table.unpack(bytes))
    if records(ReadRecordLua, data) ~= records(ReadRecord, data) then diffRec = diffRec + 1 end
    if isProtobufLua(data) ~= Protobuf.IsProtobuf(data) then diffPb = diffPb + 1 end
    if util.pbIsProtobuf(data) ~= nil then native = native + 1 end
end
is(0, diffRec, 'random data: records C = Lua (3000 buffers)')
is(0, diffPb, 'random data: IsProtobuf C = Lua (3000 buffers)')
ok(native > 2500, 'random data: most buffers checked natively (' .. native .. ')')

TestLib.done()
