--------------------------------------------------------------------------------
-- File:         test/test_perl_uv.lua
--
-- Description:  unit tests for perl.uv (Perl's unsigned 64-bit UVs) and the
--               64-bit readers built on it (Get64u, Get64s, GetFixed64s,
--               GetExtended)
--
-- Notes:        Every expectation below is the output of the real perl
--               (v5.42.2, x86_64-linux), printed with Perl's stringification
--               (`"$r"`) under `no warnings` -- none is hand-written. The
--               Perl expression of each case is the trailing comment; $u is
--               4294967295 * 4294967296 + 4294967295, $v 3220176896 *
--               4294967296, $w 2147483648 * 4294967296 and $i -5. The reader
--               cases are Image::ExifTool's own Get64u/Get64s/GetFixed64s
--               (Writer.pl) on the same bytes.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local ExifTool = require('lexiftool')
local TestLib = require('test.TestLib')
local is = TestLib.is
local uv = perl.uv

local u = uv(4294967295 * 4294967296 + 4294967295)
local v = uv(3220176896 * 4294967296)
local w = uv(2147483648 * 4294967296)
local i = -5

-- { Lua expression, perl output }
local CASES = {
    { function() return v end, '13830554455654793216' }, -- perl: $v
    { function() return u end, '18446744073709551615' }, -- perl: $u
    { function() return w end, '9223372036854775808' }, -- perl: $w
    { function() return v + 1 end, '13830554455654793217' }, -- perl: $v + 1
    { function() return u + 1 end, '1.84467440737096e+19' }, -- perl: $u + 1
    { function() return v - 1 end, '13830554455654793215' }, -- perl: $v - 1
    { function() return v - u end, '-4616189618054758399' }, -- perl: $v - $u
    { function() return w - 1 end, '9223372036854775807' }, -- perl: $w - 1
    { function() return i + v end, '13830554455654793211' }, -- perl: $i + $v
    { function() return -v end, '-1.38305544556548e+19' }, -- perl: -$v
    { function() return -w end, '-9223372036854775808' }, -- perl: -$w
    { function() return v * 2 end, '2.76611089113096e+19' }, -- perl: $v * 2
    { function() return w * 1 end, '9223372036854775808' }, -- perl: $w * 1
    { function() return v / 2 end, '6915277227827396608' }, -- perl: $v / 2
    { function() return v / 3 end, '4.6101848185516e+18' }, -- perl: $v / 3
    { function() return v / 1e3 end, '1.38305544556548e+16' }, -- perl: $v / 1e3
    { function() return v % 7 end, '3' }, -- perl: $v % 7
    { function() return v % -7 end, '-4' }, -- perl: $v % -7
    { function() return v * 1e-7 end, '1383055445565.48' }, -- perl: $v * 1e-7
    { function() return v & 0xff00000000000000 end, '13763000461244235776' }, -- perl: $v & 0xff00000000000000
    { function() return v | 1 end, '13830554455654793217' }, -- perl: $v | 1
    { function() return v ~ u end, '4616189618054758399' }, -- perl: $v ^ $u
    { function() return v >> 60 end, '11' }, -- perl: $v >> 60
    { function() return v << 1 end, '9214364837600034816' }, -- perl: $v << 1
    { function() return ~v end, '4616189618054758399' }, -- perl: ~$v
    { function() return uv(~0) end, '18446744073709551615' }, -- perl: ~0
    { function() return (v > 1e18) and 1 or 0 end, '1' }, -- perl: $v > 1e18 ? 1 : 0
    { function() return (v < 1e18) and 1 or 0 end, '0' }, -- perl: $v < 1e18 ? 1 : 0
    { function() return (v > i) and 1 or 0 end, '1' }, -- perl: $v > $i ? 1 : 0
    { function() return (v >= v) and 1 or 0 end, '1' }, -- perl: $v >= $v ? 1 : 0
    { function() return (v > u) and 1 or 0 end, '0' }, -- perl: $v > $u ? 1 : 0
    { function() return (u > 1.8446744073709552e19) and 1 or 0 end, '0' }, -- perl: $u > 1.8446744073709552e19 ? 1 : 0
    { function() return (u >= 1.8446744073709552e19) and 1 or 0 end, '1' }, -- perl: $u >= 1.8446744073709552e19 ? 1 : 0
    { function() return (w > 9223372036854775807) and 1 or 0 end, '1' }, -- perl: $w > 9223372036854775807 ? 1 : 0
    { function() return (v == v + 0) and 1 or 0 end, '1' }, -- perl: $v == $v + 0 ? 1 : 0
    { function() return perl.int(v) end, '13830554455654793216' }, -- perl: int($v)
    { function() return perl.length(v) end, '20' }, -- perl: length($v)
    { function() return v .. ' x' end, '13830554455654793216 x' }, -- perl: "$v x"
    { function() return perl.sprintf('%d|%u|%s|%x|%X|%o|%.3e|%g|%.1f', v, v, v, v, v, v, v, v, v) end,
      '-4616189618054758400|13830554455654793216|13830554455654793216|bff0000000000000|' ..
      'BFF0000000000000|1377600000000000000000|1.383e+19|1.38306e+19|13830554455654793216.0' },
      -- perl: sprintf('%d|%u|%s|%x|%X|%o|%.3e|%g|%.1f', $v, $v, $v, $v, $v, $v, $v, $v, $v)
    { function() return perl.sprintf('%x|%d', u, u) end, 'ffffffffffffffff|-1' }, -- perl: sprintf('%x|%d', $u, $u)
    { function() return u * 2 end, '3.68934881474191e+19' }, -- perl: $u * 2
    { function() return u + u end, '3.68934881474191e+19' }, -- perl: $u + $u
    { function() return i - u end, '-1.84467440737096e+19' }, -- perl: $i - $u
}

for n, c in ipairs(CASES) do
    is(c[2], perl.str(c[1]()), 'uv case ' .. n)
end

-- below 2^63 perl.uv changes nothing; the objects are interned
is(true, uv(5) == 5 and math.type(uv(5)) == 'integer', 'uv of a small integer')
is(true, rawequal(uv(3220176896 * 4294967296), v), 'uv interned')
is(true, perl.isUV(v) and not perl.isUV(5), 'isUV')
is(true, perl.truthy(v), 'uv is true')
is('', v.ref, 'ref of a uv')

-- { byte order, data (hex), Get64u, Get64s, GetFixed64s } from Perl
local READERS = {
    { 'MM', 'bff0000000000000', '13830554455654793216', '-4616189618054758400', '-1074790400' },
    { 'MM', 'fffffffffffffff8', '18446744073709551608', '-8', '-1.9e-09' },
    { 'MM', '0000000180000000', '6442450944', '6442450944', '1.5' },
    { 'MM', '8000000000000000', '9223372036854775808', '-9223372036854775808', '-2147483648' },
    { 'MM', 'fffffffe80000000', '18446744067267100672', '-6442450944', '-1.5' },
    { 'II', 'bff0000000000000', '61631', '61631', '1.43496e-05' },
    { 'II', 'fffffffffffffff8', '17942340915444056063', '-504403158265495553', '-117440512' },
    { 'II', '0000000180000000', '549772591104', '549772591104', '128.00390625' },
    { 'II', '8000000000000000', '128', '128', '2.98e-08' },
    { 'II', 'fffffffe80000000', '554034003967', '554034003967', '128.9960937498' },
}
local function unhex(h)
    return (h:gsub('..', function(x) return string.char(tonumber(x, 16)) end))
end
local saveOrder = ExifTool.GetByteOrder()
for _, c in ipairs(READERS) do
    ExifTool.SetByteOrder(c[1])
    local data = unhex(c[2])
    is(c[3], perl.str(ExifTool.Get64u(data, 0)), 'Get64u ' .. c[1] .. ' ' .. c[2])
    is(c[4], perl.str(ExifTool.Get64s(data, 0)), 'Get64s ' .. c[1] .. ' ' .. c[2])
    is(c[5], perl.str(ExifTool.GetFixed64s(data, 0)), 'GetFixed64s ' .. c[1] .. ' ' .. c[2])
    is(c[3], perl.str(ExifTool.ReadValue(data, 0, 'int64u', 1, 8)), 'ReadValue int64u ' .. c[2])
    is(c[4], perl.str(ExifTool.ReadValue(data, 0, 'int64s', 1, 8)), 'ReadValue int64s ' .. c[2])
end
-- perl: SetByteOrder('MM'); GetExtended(\"\x40\x0e\xbf\xf0\0\0\0\0\0\x01", 0)
ExifTool.SetByteOrder('MM')
is('49136', perl.str(ExifTool.GetExtended(unhex('400ebff0000000000001'), 0)), 'GetExtended')
ExifTool.SetByteOrder(saveOrder)
