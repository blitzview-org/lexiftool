--------------------------------------------------------------------------------
-- File:         test/test_protobuf_walk.lua
--
-- Description:  unit tests for the protobuf walker (util.pbWalk in
--               src/lexiftool/util.c, ProcessProtobuf's top level without
--               Unknown/Verbose/HtmlDump) against the record loop of
--               Protobuf.lua (the Lua path, taken here with et.HTML_DUMP
--               set): the same HandleTag and Warn calls (tag, value, Start,
--               Size, DataPos, Format, data, $$et{INDENT}), the same tag
--               table afterwards (added tags, IsProtobuf flags), the same
--               ProtoPrefix, Pos and Bit0 -- for hand-built buffers
--               (nesting, .proto, flags set and reset over several calls,
--               VarInts of 10 and more bytes, a non-integer Pos, truncation,
--               DirStart/DirLen) and seeded random messages; nesting beyond
--               the walker's own levels (the Lua recursion takes over); odd
--               arguments and callback results of util.pbWalk (errors, no
--               crash).
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is = TestLib.is
local ok = TestLib.ok
local ExifTool = require('lexiftool')
local Protobuf = require('lexiftool.Protobuf')
local util = require('lexiftool.util')

local function show(v)
    if type(v) == 'string' then return string.format('%q', v) end
    if type(v) == 'number' then return math.type(v) .. ':' .. tostring(v) end
    return type(v) .. ':' .. tostring(v)
end

local function vi(n)    -- a minimal VarInt of n >= 0
    local t = {}
    repeat
        local b = n & 0x7f
        n = n >> 7
        if n ~= 0 then b = b | 0x80 end
        t[#t + 1] = string.char(b)
    until n == 0
    return table.concat(t)
end
local function hdr(id, type_) return vi(id * 8 + type_) end
local function lenField(id, payload) return hdr(id, 2) .. vi(#payload) .. payload end
local function hex(s) return (s:gsub('%s', ''):gsub('..', function(h) return string.char(tonumber(h, 16)) end)) end

-- the tag tables: a fresh copy per run (AddTagToTable and the IsProtobuf
-- flags change them), registered as module tables for GetTagTable
local tables = {}
package.loaded['lexiftool.PBWalkTest'] = tables
local nTables = 0
local function newTable()
    nTables = nTables + 1
    local name = 'T' .. nTables
    tables[name] = {
        GROUPS = { [0] = 'PBW', [1] = 'PBW', [2] = 'Other' },
        TAG_PREFIX = 'PBW',
        [1] = { Name = 'NumberKey' },
        ['2'] = { Name = 'Str', Format = 'string' },
        ['3'] = { Name = 'Plain' },
        ['3-1'] = { Name = 'Nested31' },
        ['3-2-1'] = { Name = 'Nested321' },
        ['4'] = { Name = 'Sub', SubDirectory = { TagTable = 'lexiftool.PBWalkTest.None' } },
        ['50'] = { Name = 'Rat', Format = 'rational' },
        ['6'] = { Name = 'Signed', Format = 'signed' },
        ['7'] = { Name = 'U7', Unknown = 1, IsProtobuf = true },
        ['8'] = { Name = 'U8', Unknown = 1, IsProtobuf = false },
        ['9'] = { Name = 'U9', Unknown = 1, IsProtobuf = true, Format = 'undef' },
        ['10'] = { Name = 'U10', Unknown = 1, IsProtobuf = true, SubDirectory = { TagTable = 'lexiftool.PBWalkTest.None' } },
        ['43'] = { Name = 'U43', Unknown = 1 },
        ['44'] = { Name = 'U44', Unknown = 1 },
        ['20-1'] = { Name = 'Deep1' },
        ['20-20-1'] = { Name = 'Deep2' },
        ['20-21-1'] = { Name = 'Deep3' },
        ['p_1'] = { Name = 'ProtoOne' },
        ['p_3-1'] = { Name = 'ProtoNested' },
    }
    return ExifTool.GetTagTable('lexiftool.PBWalkTest.' .. name)
end

-- HandleTag and Warn record their calls (the tag tables here have nothing
-- behind their SubDirectory entries)
local log
local origHandleTag, origWarn = ExifTool.HandleTag, ExifTool.Warn
local function record(...) log[#log + 1] = table.concat({ ... }, ' ') end
ExifTool.HandleTag = function(et, tagTbl, tag, val, parms)
    parms = parms or {}
    record('HandleTag', show(tag), show(val), show(parms.Start), show(parms.Size), show(parms.DataPos),
        show(parms.Extra), show(parms.Format), show(parms.DataPt), show(et.INDENT), tostring(tagTbl.TABLE_NAME ~= nil))
end
ExifTool.Warn = function(_, msg) record('Warn', msg) end

-- the walker's calls, counted (it is looked up in the module table per call)
local walks = 0
local pbWalk = util.pbWalk
util.pbWalk = function(...) walks = walks + 1; return pbWalk(...) end

-- a state per path: ExifTool object and tag table, kept over a sequence
local function newState()
    local et = ExifTool:new()
    et.INDENT = '  '
    return { et = et, tbl = newTable() }
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return show(a) < show(b) end)
    return keys
end

-- one ProcessProtobuf call on state st; lua: the Lua path; the result as a
-- comparable string
local function run(st, lua, data, dirInfoExtra)
    log = {}
    local et = st.et
    et.HTML_DUMP = lua or nil
    local dirInfo = { DataPt = data, DirName = 'PBW' }
    for k, v in pairs(dirInfoExtra or {}) do dirInfo[k] = v end
    local okCall, err = pcall(Protobuf.ProcessProtobuf, et, dirInfo, st.tbl, nil)
    et.HTML_DUMP = nil
    local out = { 'ok=' .. tostring(okCall) .. (okCall and '' or ' ' .. tostring(err):gsub('^.-:%d+: ', '')) }
    for _, l in ipairs(log) do out[#out + 1] = l end
    out[#out + 1] = 'Pos=' .. show(dirInfo.Pos) .. ' Bit0=' .. show(dirInfo.Bit0) .. ' INDENT=' .. show(et.INDENT)
    for _, k in ipairs(sortedKeys(et.ProtoPrefix or {})) do
        out[#out + 1] = 'ProtoPrefix ' .. show(k) .. '=' .. show(et.ProtoPrefix[k])
    end
    for _, k in ipairs(sortedKeys(st.tbl)) do
        local ti = st.tbl[k]
        if type(ti) == 'table' and (ti.Name or ti.Unknown) then
            out[#out + 1] = 'tag ' .. show(k) .. ' ' .. show(ti.Name) .. ' Unknown=' .. show(ti.Unknown) ..
                ' IsProtobuf=' .. show(ti.IsProtobuf)
        end
    end
    return table.concat(out, '\n')
end

-- a sequence of calls (buffers, or { data, dirInfoExtra }) on one state per
-- path: the same results after every call; returns the walker's calls
local function same(name, seq, quiet)
    local stC, stL = newState(), newState()
    local w0 = walks
    local allSame = true
    for i, item in ipairs(seq) do
        local data, extra = item, nil
        if type(item) == 'table' then data, extra = item[1], item[2] end
        local c = run(stC, false, data, extra)
        local l = run(stL, true, data, extra)
        if c ~= l then
            allSame = false
            if not quiet then is(l, c, name .. ' (call ' .. i .. '): walker = Lua') end
            break
        end
    end
    if not quiet and allSame then ok(true, name .. ': walker = Lua') end
    return allSame, walks - w0
end

local function nest(depth, inner, id)
    for _ = 1, depth do inner = lenField(id or 3, inner) end
    return inner
end

-- hand-built buffers -------------------------------------------------------

local leaf = hdr(1, 0) .. vi(5) .. lenField(2, 'text') .. hdr(3, 0) .. vi(7)
same('flat known and unknown records', { leaf .. hdr(11, 0) .. vi(1) .. hdr(12, 5) .. 'abcd' .. hdr(13, 1) .. '12345678' })
same('nested Unknown sub-messages', { lenField(20, leaf .. lenField(21, leaf)) .. lenField(22, '\1\2\3') })
same('known nested tags (3-1, 3-2-1)', { lenField(3, lenField(1, '\0\1') .. lenField(2, lenField(1, 'x\1')) .. hdr(1, 0) .. vi(3)) })
same('number key only for a bare field number', { hdr(1, 0) .. vi(9) .. lenField(30, hdr(1, 0) .. vi(9) .. '\8\1') })
same('.proto sets the prefix (and stays for the next call)', {
    lenField(15, 'p.proto') .. hdr(1, 0) .. vi(4) .. lenField(3, lenField(1, '\0\1')),
    hdr(1, 0) .. vi(4),
    lenField(15, 'q.proto\n') .. hdr(1, 0) .. vi(4),
    lenField(15, 'x.protox') .. hdr(1, 0) .. vi(4),
})
same('.proto inside a sub-message', { lenField(20, lenField(15, 'p.proto') .. '\8\1') .. hdr(1, 0) .. vi(2) })
same('flags: set, kept, reset over calls', {
    lenField(40, '\8\1\16\2'),             -- unknown tag 40 becomes IsProtobuf
    lenField(40, '\8\1\16\2'),             -- now entered directly
    lenField(40, 'no protobuf \255'),      -- reset to false
    lenField(40, '\8\1'),                  -- false: skipped
    lenField(41, 'printable only'),        -- added, flag stays nil
    lenField(41, '\8\1'),                  -- and is set now
    lenField(7, '\8\1') .. lenField(7, '\255\255'),   -- preset true: entered, then reset
    lenField(8, '\8\1'),                   -- preset false
    lenField(9, '\8\1'),                   -- true but Format: HandleTag
    lenField(10, '\8\1'),                  -- true but SubDirectory: HandleTag
})
same('wire types 3, 4, 6, 7', { hdr(11, 3) .. hdr(12, 4) .. hdr(1, 0) .. vi(1), hdr(11, 6) .. '\0', hdr(3, 7) })
same('signed and rational formats', { hdr(6, 0) .. vi(9) .. lenField(50, vi(3) .. vi(4)) .. lenField(50, vi(3)) })
same('10-byte VarInt values (skipped and handled)', {
    hdr(11, 0) .. hex('ffffffffffffffffff01') .. hdr(1, 0) .. vi(1),
    hdr(6, 0) .. hex('feffffffffffffffff01') .. hdr(3, 0) .. hex('80808080808080808001'),
    lenField(20, hdr(11, 0) .. hex('ffffffffffffffffff01') .. hdr(3, 0) .. vi(1)),
    hdr(11, 0) .. ('\x80'):rep(32) .. '\x01' .. hdr(1, 0) .. vi(1),     -- 34 bytes: upstream's maximum
    hdr(11, 0) .. ('\x80'):rep(33) .. '\x01' .. hdr(1, 0) .. vi(1),     -- 35: format error
})
same('10-byte header and length (Lua reader)', {
    hex('88808080808080808000') .. '\1' .. hdr(1, 0) .. vi(1),
    hdr(20, 2) .. hex('82808080808080808000') .. '\8\1' .. hdr(1, 0) .. vi(1),
    lenField(20, hdr(20, 2) .. hex('82808080808080808000') .. '\8\1') .. hdr(1, 0) .. vi(1),
})
same('truncated data', {
    hdr(1, 0), hdr(1, 0) .. '\x96', hdr(12, 5) .. 'ab', lenField(20, leaf):sub(1, -3),
    lenField(20, lenField(21, leaf):sub(1, -2)), hdr(20, 2) .. '\x85', '\x89\x80',
})
same('DirStart, DirLen, Base, DataPos', {
    { 'xx' .. leaf, { DirStart = 2 } },
    { leaf .. 'junk', { DirLen = #leaf } },
    { leaf, { DirLen = #leaf + 5 } },
    { leaf, { DirStart = #leaf + 3 } },
    { leaf, { DirStart = 3, DirLen = 0 } },
    { lenField(20, leaf), { Base = 100, DataPos = 7 } },
})
-- (43 and 44: Unknown tags without an IsProtobuf flag yet)
same('IsProtobuf: only bytes above 0x7e are non-printable', { lenField(43, '\x28\xa0\x20') .. lenField(43, '\x28\xa0\x20') })
same('IsProtobuf of a sub-message with a 10-byte header (Lua reader)', {
    lenField(44, hex('88808080808080808000') .. '\1') .. lenField(44, hex('88808080808080808000') .. '\1'),
})
same('DataPos of nested levels', {
    { lenField(20, hdr(1, 0) .. vi(3) .. lenField(20, hdr(1, 0) .. vi(4)) .. lenField(21, hdr(1, 0) .. vi(5))),
      { Base = 1000, DataPos = 17 } },
    { 'zz' .. lenField(20, 'x' .. lenField(21, '\8\1')), { DirStart = 2 } },
})
-- a non-minimal 11-byte length (11th byte 0): the Lua reader's Pos is a
-- float afterwards (0 times the double 2^70), the walker leaves the rest of
-- the level to Lua
local len3 = hex('8380808080808080808000')
same('Pos that is no integer (rest of the level in Lua)', {
    hdr(3, 2) .. len3 .. 'abc' .. hdr(1, 0) .. vi(2) .. lenField(20, '\8\1'),
    lenField(20, lenField(21, '\8\1') .. hdr(3, 2) .. len3 .. 'abc' .. lenField(21, '\8\1') .. hdr(1, 0) .. vi(2)
        .. lenField(20, '\8\1')) .. hdr(1, 0) .. vi(2),
})
local sameUsed, nWalks = same('walker is used', { leaf })
ok(sameUsed and nWalks == 1, 'walker is used: one pbWalk call (' .. nWalks .. ')')

-- nesting beyond the walker's levels (0..63): the Lua recursion goes on
-- there, with nested ProcessProtobuf calls from depth 64 on
local nested = 0
local ProcessProtobuf = Protobuf.ProcessProtobuf
Protobuf.ProcessProtobuf = function(et, dirInfo, tagTbl, prefix)
    if prefix then nested = nested + 1 end
    return ProcessProtobuf(et, dirInfo, tagTbl, prefix)
end
for _, d in ipairs({ 1, 62, 63, 64, 65, 66, 200 }) do
    nested = 0
    same('nesting depth ' .. d, { nest(d, leaf, 20) .. hdr(1, 0) .. vi(1), nest(d, leaf, 20) })
    -- (two buffers: d nested calls each on the Lua path, d - 63 with the walker)
    is(2 * d + 2 * math.max(0, d - 63), nested, 'nesting depth ' .. d .. ': nested Lua calls')
end
Protobuf.ProcessProtobuf = ProcessProtobuf
same('nesting depth 200 with known tags at the bottom', { nest(200, lenField(3, lenField(1, '\0\1')), 20) })

-- seeded random messages ----------------------------------------------------

local seed = 20261125
local function rnd(n)   -- a small LCG, independent of math.random's version
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end
local ids = { 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 15, 20, 21, 40 }
local function randomVarint()
    local k = rnd(10)
    if k == 0 then return hex('ffffffffffffffffff01') end          -- 10 bytes
    if k == 1 then return ('\x80'):rep(rnd(36)) .. '\x01' end        -- long, maybe too long
    if k == 2 then return '\x80\x80\x00' end                         -- non-minimal
    return vi(rnd(k < 6 and 300 or 1 << 40))
end
local message
local function randomPayload(depth)
    local k = rnd(9)
    if k <= 2 and depth < 6 then return message(depth + 1) end
    if k == 3 then return 'p.proto' end
    if k == 4 then return 'text' end
    if k == 5 then return '' end
    local t = {}
    for i = 1, rnd(8) do t[i] = string.char(rnd(256)) end
    return table.concat(t)
end
function message(depth)
    local parts = {}
    for i = 1, rnd(6) + 1 do
        local id = ids[rnd(#ids) + 1]
        local t = rnd(12)
        if t < 3 then parts[i] = hdr(id, 0) .. randomVarint()
        elseif t < 8 then parts[i] = lenField(id, randomPayload(depth))
        elseif t == 8 then parts[i] = hdr(id, 5) .. 'wxyz'
        elseif t == 9 then parts[i] = hdr(id, 1) .. '01234567'
        elseif t == 10 then parts[i] = hdr(id, rnd(8))
        else parts[i] = string.char(rnd(256)) end
    end
    return table.concat(parts)
end
local diffs, total = 0, 0
for _ = 1, 400 do
    local seq = {}
    for i = 1, rnd(4) + 1 do
        local m = message(0)
        if rnd(5) == 0 then m = m:sub(1, rnd(#m + 1)) end   -- truncated
        seq[i] = m
    end
    total = total + 1
    if not same('random', seq, true) then
        diffs = diffs + 1
        if diffs == 1 then same('random (first difference)', seq) end
    end
end
is(0, diffs, 'random messages: walker = Lua (' .. total .. ' sequences)')

-- odd arguments and results: Lua errors, no crash ----------------------------

local et = ExifTool:new()
et.ProtoPrefix = { PBW = '' }
local tbl = newTable()
local function cbPos(d, _, _, _, pos) d.Pos = pos; return pos + 1 end
local function walkErr(name, ...)
    local okCall = pcall(pbWalk, ...)
    ok(not okCall, name .. ': error')
end
walkErr('no string', 5, 0, 1, 0, {}, tbl, et, 'PBW', cbPos)
walkErr('negative start', 'ab', -1, 2, 0, {}, tbl, et, 'PBW', cbPos)
walkErr('no callback', 'ab', 0, 2, 0, {}, tbl, et, 'PBW', nil)
walkErr('no dirInfo', 'ab', 0, 2, 0, nil, tbl, et, 'PBW', cbPos)
walkErr('callback returns true', '\255', 0, 1, 0, {}, tbl, et, 'PBW', function() return true end)
walkErr('callback returns a string', '\255', 0, 1, 0, {}, tbl, et, 'PBW', function() return 'x' end)
walkErr('unasked sub-message', '\255', 0, 1, 0, {}, tbl, et, 'PBW', function() return 1, '1-' end)
-- a nil dirName, an et without ProtoPrefix, a non-table tag info: every
-- record goes to the callback
local seen = 0
local function cbCount(d, _, _, _, pos) seen = seen + 1; d.Pos = pos; return pos + 2 end
local data = hdr(11, 0) .. vi(1) .. hdr(12, 0) .. vi(1)
seen = 0; pbWalk(data, 0, #data, 0, {}, tbl, et, nil, cbCount)
is(2, seen, 'nil dirName: all records to Lua')
seen = 0; pbWalk(data, 0, #data, 0, {}, tbl, {}, 'PBW', cbCount)
is(2, seen, 'no ProtoPrefix: all records to Lua')
seen = 0; pbWalk(data, 0, #data, 0, {}, tbl, et, 'PBW', cbCount)
is(0, seen, 'unknown varints: skipped')
local odd = { ['11'] = 'a string', ['12'] = 42 }
seen = 0; pbWalk(data, 0, #data, 0, {}, odd, et, 'PBW', cbCount)
is(2, seen, 'tag info no table: to Lua')
local pos, bit0 = pbWalk(data, 0, #data, 0, {}, tbl, et, 'PBW', cbCount)
is('integer:4 integer:1', show(pos) .. ' ' .. show(bit0), 'Pos and Bit0 of skipped records')

ExifTool.HandleTag, ExifTool.Warn, util.pbWalk = origHandleTag, origWarn, pbWalk
TestLib.done()
