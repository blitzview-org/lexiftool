--------------------------------------------------------------------------------
-- File:         test/test_byteorder.lua
--
-- Description:  unit tests for the byte-order statics (SetByteOrder /
--               GetByteOrder) and the endian-aware primitive readers
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local is = TestLib.is

local MM = '\x01\x02\x03\x04\x05\x06'
local II = '\x02\x01\x04\x03\x06\x05'

lexiftool.SetByteOrder('MM')
is('MM', lexiftool.GetByteOrder(), 'GetByteOrder returns MM')
is('MM', lexiftool.SetByteOrder('II'), 'SetByteOrder II accepted, returns the previous order')
is('II', lexiftool.GetByteOrder(), 'GetByteOrder returns II')
is(false, lexiftool.SetByteOrder('bogus') and true or false, 'SetByteOrder rejects bogus')
is('II', lexiftool.GetByteOrder(), 'rejected SetByteOrder keeps state')

lexiftool.SetByteOrder('MM')
is(0x0102, lexiftool.Get16u(MM, 0), 'Get16u MM u16')
is(0x0304, lexiftool.Get16u(MM, 2), 'Get16u MM second u16')
is(0x01020304, lexiftool.Get32u(MM, 0), 'Get32u MM u32')
is(0x03040506, lexiftool.Get32u(MM, 2), 'Get32u MM second u32')
is(0x0201, lexiftool.Get16uRev(MM, 0), 'Get16uRev MM (reversed byte order)')
is(0x04030201, lexiftool.Get32uRev(MM, 0), 'Get32uRev MM (reversed byte order)')
is(258, lexiftool.Get16s(MM, 0), 'Get16s MM positive')
is(-2, lexiftool.Get16s('\xff\xfe', 0), 'Get16s MM negative')

lexiftool.SetByteOrder('II')
is(0x0102, lexiftool.Get16u(II, 0), 'Get16u II u16')
is(0x0304, lexiftool.Get16u(II, 2), 'Get16u II second u16')
is(0x03040102, lexiftool.Get32u(II, 0), 'Get32u II u32')
is(0x0201, lexiftool.Get16uRev(II, 0), 'Get16uRev II (reversed byte order)')
is(-2, lexiftool.Get16s('\xfe\xff', 0), 'Get16s II negative')

is(0x41, lexiftool.Get8u('A', 0), 'Get8u')
is(nil, lexiftool.Get8u('A', 1), 'Get8u out of range')
is(-1, lexiftool.Get8s('\xff', 0), 'Get8s')

is(nil, lexiftool.Get16u(MM, 5), 'Get16u offset 5 (out of range)')
is(nil, lexiftool.Get32u(MM, 5), 'Get32u offset 5 (out of range)')

is('1.23', lexiftool.RoundFloat(1.23456, 3), 'RoundFloat sig 3')
is('1.23e+03', lexiftool.RoundFloat(1234.56, 3), 'RoundFloat sig 3 integer scale')

-- (not upstream) the string.unpack fast path of Get8s .. Get32u against the
-- upstream chain it bypasses (DoUnpackStd/DoUnpack, still the fallback):
-- both byte orders, strings of 0-9 bytes and the same bytes as a carray,
-- every offset from -2 to past the end plus nil, integral and fractional
-- floats and Inf; result value, its number subtype, or the error message
do
    local carray = require('carray')
    local ref = {
        Get8s = function(d, p) return lexiftool.DoUnpackStd('c', d, p) end,
        Get8u = function(d, p) return lexiftool.DoUnpackStd('C', d, p) end,
        Get16s = function(d, p) return lexiftool.DoUnpack(2, 's', d, p) end,
        Get16u = function(d, p) return lexiftool.DoUnpackStd('S', d, p) end,
        Get32s = function(d, p) return lexiftool.DoUnpack(4, 'l', d, p) end,
        Get32u = function(d, p) return lexiftool.DoUnpackStd('L', d, p) end,
    }
    -- (the warnings of a read, e.g. DoUnpack's substr past the end, are part
    --  of its outcome)
    local perl = require('lexiftool.perl')
    local warned = {}
    local savedWarn = perl.SIG.__WARN__
    perl.SIG.__WARN__ = function(msg) warned[#warned + 1] = tostring(msg) end
    local function outcome(f, d, p)
        warned = {}
        local res = table.pack(pcall(f, d, p))
        local w = ' warn[' .. table.concat(warned, '|') .. ']'
        if not res[1] then return 'error ' .. tostring(res[2]) .. w end
        local out = { tostring(res.n - 1) }
        for i = 2, res.n do out[#out + 1] = tostring(res[i]) .. '/' .. tostring(math.type(res[i])) end
        return table.concat(out, ' ') .. w
    end
    math.randomseed(20261122)
    local cases, bad = 0, 0
    for _, order in ipairs({ 'MM', 'II' }) do
        lexiftool.SetByteOrder(order)
        for len = 0, 9 do
            for _ = 1, 4 do
                local bytes = {}
                for i = 1, len do bytes[i] = string.char(math.random(0, 255)) end
                local str = table.concat(bytes)
                local offsets = { 0.0, 1.0, 2.0, 0.5, 1.5, math.huge, -math.huge, 0 / 0 }
                for p = -2, len + 1 do offsets[#offsets + 1] = p end
                for _, data in ipairs({ str, carray.new('char'):append(str) }) do
                    for name, old in pairs(ref) do
                        -- (nil first: a table constructor would drop it)
                        local exp, got = outcome(old, data, nil), outcome(lexiftool[name], data, nil)
                        cases = cases + 1
                        if exp ~= got then bad = bad + 1 print('# ' .. name .. ' ' .. order .. ' nil: ' .. exp .. ' vs ' .. got) end
                        for _, p in ipairs(offsets) do
                            exp, got = outcome(old, data, p), outcome(lexiftool[name], data, p)
                            cases = cases + 1
                            if exp ~= got then
                                bad = bad + 1
                                print('# ' .. name .. ' ' .. order .. ' len ' .. len .. ' pos ' .. tostring(p) .. ': ' .. exp .. ' vs ' .. got)
                            end
                        end
                    end
                end
            end
        end
    end
    perl.SIG.__WARN__ = savedWarn
    is(0, bad, 'Get8s .. Get32u fast path agrees with DoUnpackStd/DoUnpack (' .. cases .. ' cases)')
    -- the fast path follows SetByteOrder, also for the signed readers
    lexiftool.SetByteOrder('II')
    is(0x0201, lexiftool.Get16u(MM, 0), 'Get16u II')
    is(0x04030201, lexiftool.Get32u(MM, 0), 'Get32u II')
    is(-257, lexiftool.Get16s('\xff\xfe', 0), 'Get16s II negative')
    is(-16842753, lexiftool.Get32s('\xff\xff\xfe\xfe', 0), 'Get32s II negative')
    lexiftool.SetByteOrder('MM')
    is(-2, lexiftool.Get16s('\xff\xfe', 0), 'Get16s MM negative after toggling back')
    is(-65538, lexiftool.Get32s('\xff\xfe\xff\xfe', 0), 'Get32s MM negative')
end

-- restore default byte order for the rest of the run
lexiftool.SetByteOrder('MM')
is('MM', lexiftool.GetByteOrder(), 'byte order restored')

TestLib.done()