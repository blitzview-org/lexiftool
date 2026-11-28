--------------------------------------------------------------------------------
-- File:         test/test_util.lua
--
-- Description:  unit tests for the native module lexiftool.util
--               (src/lexiftool/util.c): base64decode, a one-pass stand-in
--               for Image::ExifTool::XMP::DecodeBase64 (XMP.pm) on both a
--               Lua string and a carray of bytes, and hdrpDecrypt, the key
--               stream of Image::ExifTool::Google::ProcessHDRP (Google.pm)
--               against the port's former Lua loop, and gmtime64,
--               Perl_gmtime64_r of Perl's time64.c, against the port's
--               former Lua version (perl.lua's T64.gmtime64_r), and
--               truthy, perl.truthy, against the port's former Lua version.
--               (pbRecord/pbIsProtobuf: test_protobuf.lua)
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is = TestLib.is
local util = require('lexiftool.util')
local carray = require('carray')

-- plain base64, no quirks ------------------------------------------------

is('', util.base64decode(''), 'base64decode: empty string')
is('Man', util.base64decode('TWFu'), 'base64decode: TWFu -> Man (full group)')
is('Ma', util.base64decode('TWE='), 'base64decode: TWE= -> Ma (one pad char)')
is('M', util.base64decode('TQ=='), 'base64decode: TQ== -> M (two pad chars)')

-- white space and '=' are ignored wherever they occur (the table's
-- B64_SKIP entries: ' ', '\t', '\n', '\r', '\f', '='); anything else
-- past the base64 alphabet ends the data (B64_END), the rest is dropped
is('Man', util.base64decode('TW\nFu'), 'base64decode: embedded newline ignored')
is('Man', util.base64decode('T W F u'), 'base64decode: embedded spaces ignored')
is('Man', util.base64decode('TWFu\r\n'), 'base64decode: trailing CRLF ignored')
is('Man', util.base64decode(' \t\f TWFu'), 'base64decode: leading white space ignored')
is('Man', util.base64decode('TWFu!!!garbage'), 'base64decode: data truncated at first non-base64, non-white-space byte')

-- a longer binary round trip, base64-encoded here in plain Lua (not via
-- lexiftool.util, so this exercises an independent encoding path)
local function base64encode(s)
    local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local out = {}
    local n = #s
    local i = 1
    while i <= n - 2 do
        local a, b, c = s:byte(i, i + 2)
        local v = a * 65536 + b * 256 + c
        out[#out + 1] = alphabet:sub((v >> 18) + 1, (v >> 18) + 1)
        out[#out + 1] = alphabet:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
        out[#out + 1] = alphabet:sub(((v >> 6) & 63) + 1, ((v >> 6) & 63) + 1)
        out[#out + 1] = alphabet:sub((v & 63) + 1, (v & 63) + 1)
        i = i + 3
    end
    local rem = n - i + 1
    if rem == 1 then
        local a = s:byte(i)
        local v = a * 65536
        out[#out + 1] = alphabet:sub((v >> 18) + 1, (v >> 18) + 1)
        out[#out + 1] = alphabet:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
        out[#out + 1] = '=='
    elseif rem == 2 then
        local a, b = s:byte(i, i + 1)
        local v = a * 65536 + b * 256
        out[#out + 1] = alphabet:sub((v >> 18) + 1, (v >> 18) + 1)
        out[#out + 1] = alphabet:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
        out[#out + 1] = alphabet:sub(((v >> 6) & 63) + 1, ((v >> 6) & 63) + 1)
        out[#out + 1] = '='
    end
    return table.concat(out)
end

-- 1000 bytes of pseudo-random binary data (0..255, including \0 and \255)
local bin = {}
math.randomseed(20261121)
for i = 1, 1000 do bin[i] = string.char(math.random(0, 255)) end
bin = table.concat(bin)
is(bin, util.base64decode(base64encode(bin)), 'base64decode: 1000-byte binary round trip (self-encoded)')

-- upstream's quirk (XMP.pm's detour through uuencode, see util.c): a
-- single base64 character left over after whole groups of four is NOT
-- simply dropped. upstream rewrites to the uuencode alphabet and unpacks
-- in 60-character chunks with unpack 'u'; a chunk's length byte is
-- (characters in that chunk * 3 / 4), integer division, so one leftover
-- character written a length byte of (1 * 3 / 4) = 0 for the correct
-- chunk -- but unpack 'u' then reads that single character AGAIN as the
-- *next* "line"'s length byte and decodes that many zero bytes from
-- whatever (non-existent) data follows: m2 = that character's 6-bit
-- value, 3/4 of it rounded down is the zero-byte count actually produced
-- (util.c's "for i2 = 0; i2 < q[0]; i2++" loop, q[0] being that value).
--
-- Exception: a leftover character that is itself the *first* character of
-- a new 60-character chunk (position 61, 121, ... i.e. the total count of
-- base64 characters taken is m with m % 60 == 1) starts its own chunk
-- whose length byte is ' ' (space, value 0), which ends unpack 'u' before
-- it reads any data -- so that case yields no extra bytes at all.

-- a single leftover character right at the start (m = 1) IS the first
-- character of its own chunk (1 % 60 == 1, the exception above), so it
-- contributes no bytes regardless of its value -- this is NOT yet the
-- quirk this section is about, it tests the exception on its own
is('', util.base64decode('A'), "base64decode: single char 'A' at m=1 (chunk of its own) -> no bytes")
is('', util.base64decode('B'), "base64decode: single char 'B' at m=1 (chunk of its own) -> no bytes")

-- the quirk itself needs the leftover character NOT at such a position:
-- a full group ('AAAA', 3 zero bytes) moves the leftover to m=5
-- (5 % 60 ~= 1); 'B' (value 1) -> 1 extra zero byte, 'C' (value 2) ->
-- 2 extra zero bytes, on top of the full group's 3
is(string.rep('\0', 4), util.base64decode('AAAAB'),
    "base64decode quirk: leftover 'B' (value 1) after a full group -> 3 + 1 zero bytes")
is(string.rep('\0', 5), util.base64decode('AAAAC'),
    "base64decode quirk: leftover 'C' (value 2) after a full group -> 3 + 2 zero bytes")
-- the chunk-of-its-own exception: exactly 60 characters (15 full groups,
-- m = 60) followed by one more character (m = 61, 61 % 60 == 1) -> the
-- leftover starts a chunk of its own and contributes no bytes
local chunk60 = string.rep('A', 60)
is(string.rep('\0', 45), util.base64decode(chunk60 .. 'B'),
    'base64decode quirk: leftover character at position 61 (chunk of its own) contributes no bytes')

-- a partial group of two or three characters (not one) is the ordinary
-- case, not the quirk: bits are simply zero-padded and truncated to
-- the number of whole bytes they fill
is('\x04', util.base64decode('BA'), 'base64decode: two-character partial group -> 1 byte (no quirk)')
is('\x04\x00', util.base64decode('BAA'), 'base64decode: three-character partial group -> 2 bytes (no quirk)')

-- carray input: base64decode also accepts the mutable buffer the port
-- uses for Perl's scalar references (lua-carray, read through
-- carray_capi.h), not only Lua strings
local buf = carray.new('char'):append('TWFu')
is('Man', util.base64decode(buf), 'base64decode: carray input (TWFu -> Man)')

local bufBin = carray.new('char'):append(base64encode(bin))
is(bin, util.base64decode(bufBin), 'base64decode: carray input, 1000-byte binary round trip')

local emptyBuf = carray.new('char')
is('', util.base64decode(emptyBuf), 'base64decode: empty carray')

-- hdrpDecrypt ------------------------------------------------------------

-- the former Lua loop of Google.ProcessHDRP (before util.hdrpDecrypt),
-- kept here as the reference: pad to 8 bytes, unpack 'V*', XOR each pair
-- of words with the low/high half of the next xorshift64* key, pack, cut
local perl = require('lexiftool.perl')
local function hdrpDecryptLua(valPt)
    local pad = (8 - (perl.length(valPt) % 8)) & 0x07
    if pad ~= 0 then valPt = valPt .. ('\0'):rep(pad) end
    local words = { perl.unpack('V*', valPt) }
    local key = 0x2515606b4a7791cd
    local i = 0
    while i < #words do
        key = key ~ (key >> 12)
        key = key ~ (key << 25)
        key = key ~ (key >> 27)
        key = key * 0x2545f4914f6cdd1d
        local hi, lo = key >> 32, key & 0xffffffff
        words[i + 1] = words[i + 1] ~ lo; i = i + 1
        words[i + 1] = words[i + 1] ~ hi; i = i + 1
    end
    local val = perl.pack('V*', table.unpack(words))
    if pad ~= 0 then val = perl.substr(val, 0, -pad) end
    return val
end

local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

is('', util.hdrpDecrypt(''), 'hdrpDecrypt: empty string')
is('', util.hdrpDecrypt(carray.new('char')), 'hdrpDecrypt: empty carray')

-- the key stream itself (zero input): the first two xorshift64* keys,
-- little-endian (the hex computed independently, with Python integers)
local keys16 = 'f0ef3d6d5e701e2ce81ca0ea3d1bf31d'
is(keys16, hex(util.hdrpDecrypt(('\0'):rep(16))), 'hdrpDecrypt: 16 zero bytes give the key stream')
is(keys16, hex(hdrpDecryptLua(('\0'):rep(16))), 'hdrpDecrypt: key stream of the Lua reference')
-- XOR is its own inverse
is(bin, util.hdrpDecrypt(util.hdrpDecrypt(bin)), 'hdrpDecrypt: applied twice is the identity (1000 bytes)')

-- lengths 1..17: every remainder of a partial last block, both sides of
-- the 8- and 16-byte boundaries; the bytes of a partial block are a
-- prefix of the full-length result
local full17 = util.hdrpDecrypt(bin:sub(1, 17))
for n = 1, 17 do
    local data = bin:sub(1, n)
    local got = util.hdrpDecrypt(data)
    is(hdrpDecryptLua(data), got, 'hdrpDecrypt: length ' .. n .. ' = Lua reference')
    is(full17:sub(1, n), got, 'hdrpDecrypt: length ' .. n .. ' is a prefix of length 17')
end

-- carray input
local hbuf = carray.new('char'):append(bin)
is(hdrpDecryptLua(bin), util.hdrpDecrypt(hbuf), 'hdrpDecrypt: carray input, 1000 bytes = Lua reference')
local hbuf13 = carray.new('char'):append(bin:sub(1, 13))
is(hdrpDecryptLua(bin:sub(1, 13)), util.hdrpDecrypt(hbuf13), 'hdrpDecrypt: carray input, 13 bytes = Lua reference')

-- random data of random length: C = Lua reference
local mismatch = 0
for _ = 1, 300 do
    local n = math.random(0, 2048)
    local t = {}
    for k = 1, n do t[k] = string.char(math.random(0, 255)) end
    local data = table.concat(t)
    if util.hdrpDecrypt(data) ~= hdrpDecryptLua(data) then mismatch = mismatch + 1 end
end
is(0, mismatch, 'hdrpDecrypt: 300 random buffers (0..2048 bytes) = Lua reference')

-- the HDRP block of vendor/exiftool/t/images/Google.jpg (XMP
-- HdrPlusMakernote, HDRP version 3): the bytes after the 5-byte header,
-- decrypted, are the gzip stream; expected values from the former Lua path
local fh = io.open('vendor/exiftool/t/images/Google.jpg', 'rb')
if fh then
    local jpg = fh:read('a'); fh:close()
    local raw = util.base64decode(jpg:match('HdrPlusMakernote="([^"]*)"') or '')
    is('HDRP\3', raw:sub(1, 5), 'hdrpDecrypt: Google.jpg block has the HDRP v3 header')
    local enc = raw:sub(6)
    is('ef64356d5e701e2ceae34c573a67e04a', hex(enc:sub(1, 16)), 'hdrpDecrypt: Google.jpg encrypted head')
    local dec = util.hdrpDecrypt(enc)
    is(28760, #dec, 'hdrpDecrypt: Google.jpg decrypted length')
    is('1f8b08000000000002ffecbd077c1357', hex(dec:sub(1, 16)), 'hdrpDecrypt: Google.jpg decrypted head (gzip magic)')
    is('79dfb472212b0100', hex(dec:sub(-8)), 'hdrpDecrypt: Google.jpg decrypted tail')
    local sum = 0
    for k = 1, #dec do sum = (sum * 31 + dec:byte(k)) & 0xffffffff end
    is(0x1561836b, sum, 'hdrpDecrypt: Google.jpg decrypted checksum')
    is(hdrpDecryptLua(enc), dec, 'hdrpDecrypt: Google.jpg = Lua reference')
    is(dec:sub(1, 1003), util.hdrpDecrypt(enc:sub(1, 1003)), 'hdrpDecrypt: Google.jpg, 1003-byte prefix')
else
    TestLib.ok(false, 'hdrpDecrypt: vendor/exiftool/t/images/Google.jpg readable')
end

-- gmtime64 ---------------------------------------------------------------

-- The former Lua version (perl.lua's T64.gmtime64_r, a line-for-line port
-- of Perl_gmtime64_r), the reference for util.gmtime64: its results as
-- sec, min, hour, mday, mon, year, wday, yday.
local function gmtime64Lua(time)
    local fmod, floor, ceil = math.fmod, math.floor, math.ceil
    local function int(x) return math.tointeger(x >= 0 and floor(x) or ceil(x)) end
    local function i32(v) return ((v + 0x80000000) & 0xffffffff) - 0x80000000 end
    local function IS_LEAP(n)
        local y = n + 1900
        return ((y % 400 == 0) or (y % 4 == 0 and y % 100 ~= 0)) and 1 or 0
    end
    local days_in_month = {
        { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
        { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
    }
    local julian_days_by_month = {
        { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 },
        { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 },
    }
    local length_of_year = { 365, 366 }
    local days_in_gregorian_cycle = (365 * 400) + 100 - 4 + 1
    local CHEAT_DAYS, CHEAT_YEARS = 1199145600 // 24 // 60 // 60, 108
    local year = 70

    local v_tm_sec = int(fmod(time, 60.0))
    time = time >= 0 and floor(time / 60.0) or ceil(time / 60.0)
    local v_tm_min = int(fmod(time, 60.0))
    time = time >= 0 and floor(time / 60.0) or ceil(time / 60.0)
    local v_tm_hour = int(fmod(time, 24.0))
    time = time >= 0 and floor(time / 24.0) or ceil(time / 24.0)
    local v_tm_tday = time

    if v_tm_sec < 0 then v_tm_min = v_tm_min - 1; v_tm_sec = v_tm_sec + 60 end
    if v_tm_min < 0 then v_tm_hour = v_tm_hour - 1; v_tm_min = v_tm_min + 60 end
    if v_tm_hour < 0 then v_tm_tday = v_tm_tday - 1; v_tm_hour = v_tm_hour + 24 end

    local v_tm_wday = int(fmod(v_tm_tday + 4.0, 7.0))
    if v_tm_wday < 0 then v_tm_wday = v_tm_wday + 7 end
    local m = v_tm_tday

    if m >= CHEAT_DAYS then
        year = CHEAT_YEARS
        m = m - CHEAT_DAYS
    end

    local leap, v_tm_mon
    if m >= 0 then
        local cycles = int(floor(m / (days_in_gregorian_cycle + 0.0)))
        if cycles ~= 0 then
            m = m - (cycles * (days_in_gregorian_cycle + 0.0))
            year = i32(year + cycles * 400)
        end
        leap = IS_LEAP(year)
        while m >= length_of_year[leap + 1] do
            m = m - length_of_year[leap + 1]
            year = year + 1
            leap = IS_LEAP(year)
        end
        v_tm_mon = 0
        while m >= days_in_month[leap + 1][v_tm_mon + 1] do
            m = m - days_in_month[leap + 1][v_tm_mon + 1]
            v_tm_mon = v_tm_mon + 1
        end
    else
        year = year - 1
        local cycles = int(ceil((m / (days_in_gregorian_cycle + 0.0)) + 1))
        if cycles ~= 0 then
            m = m - (cycles * (days_in_gregorian_cycle + 0.0))
            year = i32(year + cycles * 400)
        end
        leap = IS_LEAP(year)
        while m < -length_of_year[leap + 1] do
            m = m + length_of_year[leap + 1]
            year = year - 1
            leap = IS_LEAP(year)
        end
        v_tm_mon = 11
        while m < -days_in_month[leap + 1][v_tm_mon + 1] do
            m = m + days_in_month[leap + 1][v_tm_mon + 1]
            v_tm_mon = v_tm_mon - 1
        end
        m = m + days_in_month[leap + 1][v_tm_mon + 1]
    end
    return v_tm_sec, v_tm_min, v_tm_hour, int(m) + 1, v_tm_mon, year, v_tm_wday,
           julian_days_by_month[leap + 1][v_tm_mon + 1] + int(m)
end

-- (pp_gmtime's bounds, and the floor it applies before the call)
local T_LO, T_HI = -67768100567755200.0, 67767976233316800.0
local function gmtimeSame(t)
    t = math.floor(t) + 0.0
    if t < T_LO or t > T_HI then return true end
    local a = table.pack(util.gmtime64(t))
    local b = table.pack(gmtime64Lua(t))
    if a.n ~= 8 then return false end
    for k = 1, 8 do
        if a[k] ~= b[k] or math.type(a[k]) ~= 'integer' then return false end
    end
    return true
end

-- known dates (perl -e 'print join ",", gmtime(T)': sec, min, hour, mday,
-- mon, year, wday, yday)
local function gm(t) return table.concat({ util.gmtime64(t) }, ',') end
is('0,0,0,1,0,70,4,0', gm(0.0), 'gmtime64: the epoch')
is('59,59,23,31,11,69,3,364', gm(-1.0), 'gmtime64: one second before the epoch')
is('7,14,3,19,0,138,2,18', gm(2147483647.0), 'gmtime64: 2^31 - 1')
is('52,45,20,13,11,1,5,346', gm(-2147483648.0), 'gmtime64: -2^31')
is('40,26,12,13,8,120,0,256', gm(1600000000.0), 'gmtime64: 1600000000')
is('0,0,0,29,1,100,2,59', gm(951782400.0), 'gmtime64: 2000-02-29 (leap century)')
is('0,0,0,1,2,200,1,59', gm(4107542400.0), 'gmtime64: 2100-03-01 (no leap day)')
is('0,0,0,1,0,-1900,6,0', gm(-62167219200.0), 'gmtime64: year 0')
is('0,0,0,1,0,8100,6,0', gm(253402300800.0), 'gmtime64: year 10000')
TestLib.err(function() util.gmtime64(T_HI * 2) end, 'gmtime64: beyond the bounds raises')
TestLib.err(function() util.gmtime64(0 / 0) end, 'gmtime64: NaN raises')

-- against the Lua version: edges, every year boundary of 1600..2500,
-- every day of 1968..2040 and random times in several magnitudes
local gmMismatch, count = 0, 0
local function check(t)
    count = count + 1
    if not gmtimeSame(t) then gmMismatch = gmMismatch + 1 end
end
local edges = { 0, 1, -1, 59, 60, -60, -61, 86399, 86400, -86400, -86401, 2^31 - 1, 2^31, -2^31,
    -2^31 - 1, 2^32, -2^32, 2^53, -2^53, 2^55, -2^55, 1199145599, 1199145600, 951782400,
    946684800, 253402300800, -62167219200, -12219292800, T_LO, T_HI, T_LO + 86400, T_HI - 86400,
    146097 * 86400, -146097 * 86400 }
for _, e in ipairs(edges) do
    for d = -2, 2 do check(e + d) end
end
do
    -- 1600-01-01 00:00:00 UTC
    local t = -11676096000
    for y = 1600, 2500 do
        check(t - 1); check(t); check(t + 59 * 86400); check(t + 60 * 86400)
        local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
        t = t + (leap and 366 or 365) * 86400
    end
    for day = -730, 25567 + 730 * 4 do
        local s = day * 86400
        check(s); check(s + 86399)
    end
end
math.randomseed(20261125)
for _, mag in ipairs({ 1e4, 1e8, 4e9, 1e12, 1e15, 1e16, 6.7e16 }) do
    for _ = 1, 2000 do check((math.random() * 2 - 1) * mag) end
end
is(0, gmMismatch, 'gmtime64: ' .. count .. ' times = Lua reference')

-- truthy: perl.truthy (Perl truthiness) against the former Lua version ----

local function truthyLua(v)
    if v == nil or v == false or v == 0 or v == '0' or v == '' then return false end
    if type(v) == 'userdata' and getmetatable(v) == 'carray' then
        local n = v:len()
        return n > 1 or (n == 1 and v:get(1) ~= 48)
    end
    return true
end

local function bytes(s) return carray.new('char'):append(s) end
local function elems(t, ...)
    local a = carray.new(t)
    for _, x in ipairs({ ... }) do a:append(x) end
    return a
end
local nan = 0 / 0
local truthyCases = {
    { 0, 'integer 0' }, { 0.0, 'float 0.0' }, { -0.0, 'float -0.0' },
    { nan, 'NaN' }, { 1, 'integer 1' }, { -1, 'integer -1' }, { 0.5, '0.5' },
    { 1e-300, '1e-300' }, { math.huge, 'inf' }, { -math.huge, '-inf' },
    { math.maxinteger, 'maxinteger' }, { math.mininteger, 'mininteger' },
    { '', "''" }, { '0', "'0'" }, { '00', "'00'" }, { '0.0', "'0.0'" },
    { ' 0', "' 0'" }, { '0 ', "'0 '" }, { '\0', "'\\0'" }, { 'a', "'a'" },
    { false, 'false' }, { true, 'true' }, { {}, 'table' },
    { setmetatable({}, { __metatable = 'carray' }), "table posing as carray" },
    { print, 'C function' }, { truthyLua, 'Lua function' },
    { io.stdout, 'file handle (other userdata)' },
    { coroutine.create(print), 'thread' },
    { bytes(''), 'carray char size 0' }, { bytes('0'), 'carray char "0"' },
    { bytes('1'), 'carray char "1"' }, { bytes('\0'), 'carray char "\\0"' },
    { bytes('00'), 'carray char "00"' }, { bytes('01'), 'carray char "01"' },
    { bytes('10'), 'carray char "10"' }, { elems('uchar', 48), 'carray uchar 48' },
    { elems('uchar', 49), 'carray uchar 49' },
    { elems('short'), 'carray short size 0' }, { elems('short', 48), 'carray short 48' },
    { elems('short', 49), 'carray short 49' }, { elems('short', 48, 48), 'carray short 48,48' },
    { elems('int', 0), 'carray int 0' }, { elems('int', 48), 'carray int 48' },
    { elems('double', 48), 'carray double 48' }, { elems('double', 48.5), 'carray double 48.5' },
    { elems('double', 0), 'carray double 0' }, { elems('float', 48), 'carray float 48' },
}
for _, c in ipairs(truthyCases) do
    is(truthyLua(c[1]), util.truthy(c[1]), 'truthy: ' .. c[2] .. ' = Lua reference')
end
is(false, util.truthy(), 'truthy: no argument (nil)')
is(false, util.truthy(nil, 1), 'truthy: nil with an extra argument')
is(false, util.truthy(bytes('0'), 1), 'truthy: carray "0" with an extra argument')
is(false, util.truthy(elems('short', 48), 1), 'truthy: carray short 48 with an extra argument')
is(true, util.truthy(elems('short', 49), 'x'), 'truthy: carray short 49 with an extra argument')
is(util.truthy, require('lexiftool.perl').truthy, 'truthy: perl.truthy is util.truthy')

TestLib.done()
