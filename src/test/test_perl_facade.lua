--------------------------------------------------------------------------------
-- File:         test/test_perl_facade.lua
--
-- Description:  unit tests for the perl facade primitives (substr, length,
--               at, join, unpack, ...)
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local carray = require('carray')
local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok

is('he', perl.substr('hello', 0, 2), 'substr 0-based')
is('lo', perl.substr('hello', 3), 'substr to end')
is('ll', perl.substr('hello', -3, 2), 'substr negative offset')
is('hell', perl.substr('hello', 0, -1), 'substr negative len')
is('o', perl.substr('hello', -1), 'substr last char')
is('', perl.substr('hello', 5), 'substr at end')
is('', perl.substr('hello', 0, 0), 'substr zero len')
is(5, perl.length('hello'), 'length of string')

-- carray (mutable) arguments: substr read, substr replace (in-place, returns
-- the extracted substring), and length
local carr = carray.new('char'):append('hello')
is('ell', perl.substr(carr, 1, 3), 'substr carray read')
is(5, perl.length(carr), 'length carray')
local mut = carray.new('char'):append('hello')
is('el', perl.substr(mut, 1, 2, 'X'), 'substr carray replace returns extracted')
is('hXlo', mut:tostring(), 'substr carray replace mutates in place')

local list = { 'a', 'b', 'c' }
is('a', perl.at(list, 0), 'at 0-based')
is('c', perl.at(list, -1), 'at negative index')
is(nil, perl.at(list, 3), 'at out of range')
is('a,b,c', perl.join(',', list), 'join')
is('c,b,a', perl.join(',', { perl.reverse(table.unpack(list)) }), 'reverse list context')
is('', perl.join(',', { perl.reverse() }), 'reverse empty list')

is(true, perl.D(0), 'D defined nonzero')
is(false, perl.D(nil), 'D undefined')
local h = { x = 1 }
is(true, perl.E(h, 'x'), 'E exists')
is(false, perl.E(h, 'y'), 'E missing')

local v = perl.unpack('v', '\x00\x10')
is(0x1000, v, 'unpack v LE u16')
local n = perl.unpack('n', '\x00\x10')
is(0x0010, n, 'unpack n BE u16')
local V = perl.unpack('V', '\x00\x10\x00\x00')
is(0x1000, V, 'unpack V LE u32')
local N = perl.unpack('N', '\x00\x10\x00\x00')
is(0x00100000, N, 'unpack N BE u32')
-- (expectations from perl: data too short for a numeric code yields only the
--  values it holds, and a number is unpacked as its string form)
is(2, select('#', perl.unpack('N3', 'abcdefgh')), 'unpack N3 on 8 bytes is 2 values')
is(0, select('#', perl.unpack('N', 100)), 'unpack N on the number 100 is no value')
is(97, (perl.unpack('nC', 'a')), 'unpack nC on 1 byte skips n')
is(0x31303030, (perl.unpack('N', 1000)), 'unpack N stringifies a number')
local c, C = perl.unpack('cC', '\xff\x80')
is(-1, c, 'unpack c signed char')
is(128, C, 'unpack C unsigned char')
-- Perl's l/L are always 32 bits and q/Q always 64, regardless of the C
-- `long` width Lua's own 'l'/'L' codes follow (perl: unpack('L', "\x34\x12\0\0")
-- is 0x1234, and the 'LL' pair below consumes exactly 8 bytes)
local L = perl.unpack('L', '\x34\x12\x00\x00')
is(0x1234, L, 'unpack L native u32')
local l = perl.unpack('l', '\xff\xff\xff\xff')
is(-1, l, 'unpack l native i32')
local L1, L2 = perl.unpack('LL', '\x01\x00\x00\x00\x02\x00\x00\x00')
is(1, L1, 'unpack L is 4 bytes wide (first)')
is(2, L2, 'unpack L is 4 bytes wide (second)')
local Q = perl.unpack('Q', '\x01\x02\x00\x00\x00\x00\x00\x00')
is(0x0201, Q, 'unpack Q native u64')
local a, b, c2 = perl.unpack('c3', '\x01\x02\x03')
is(1, a, 'unpack repeat value 1')
is(2, b, 'unpack repeat value 2')
is(3, c2, 'unpack repeat value 3')

local hex = perl.unpack('H*', '\x01\x0a\xff')
is('010aff', hex, 'unpack H* hex')

local bytes = perl.unpack('a*', 'hello')
is('hello', bytes, 'unpack a* bytes')

local zs = perl.unpack('Z*', 'ab\0cd')
is('ab', zs, 'unpack Z* null-terminated')

-- 'Zn' is a fixed-width field: it always consumes n bytes, so the code after
-- it starts at n bytes on (perl: unpack('Z4N', "ab\0\0\0\0\0\7") is ('ab',7))
local zf, zn = perl.unpack('Z4N', 'ab\0\0\0\0\0\7')
is('ab', zf, 'unpack Zn null-terminated value')
is(7, zn, 'unpack Zn consumes the full field width')

local v1, p1 = perl.unpack('v', '\x00\x01\x00\x02', 0)
is(256, v1, 'unpack off-form value')
is(2, p1, 'unpack off-form returns next position')
local v2, p2 = perl.unpack('v', '\x00\x01\x00\x02', p1)
is(512, v2, 'unpack off-form second value')
is(4, p2, 'unpack off-form sequencing')

local skipped = perl.unpack('x4a2', 'xxxx01')
is('01', skipped, 'unpack x skip bytes')

local bounded = perl.unpack -- bind to a local alias
is(0x1000, bounded('v', '\x00\x10'), 'local binding works')

local ab = perl.unpack('@2a2', 'xxboggus')
is('bo', ab, 'unpack @ absolute position')

is('lua', perl.backend(), 'default backend is lua')

ok(perl.substr('abc', 0, 9) == 'abc', 'substr len beyond end clamps')

-- perl.matches / perl.matchesDyn
local g1, e1 = perl.matches('xax', '(x|y)')
is('x', g1, 'matches alternation returns first group')
is(1, e1, 'matches returns 0-based end offset')
local g2a, g2b = perl.matches('foo bar@baz', '(\\w+)@(\\w+)')
is('bar', g2a, 'matches multiple captures 1')
is('baz', g2b, 'matches multiple captures 2')
is(nil, perl.matches('abc', 'xyz'), 'matches no match returns nil')
local ok1, e2 = perl.matches('abc', 'b')
is(true, ok1, 'matches success without captures returns true')
is(2, e2, 'matches end offset without captures')
-- pos-continuation, like Perl's /g with pos()
local s = 'axbxcx'
local positions = {}
local pos = 0
while true do
    local m, e = perl.matches(s, 'x', pos)
    if not m then break end
    positions[#positions + 1] = e
    pos = e
end
is(3, #positions, 'matches pos-continue finds all matches')
is(2, positions[1], 'matches pos-continue match 1 end offset')
is(4, positions[2], 'matches pos-continue match 2 end offset')
is(6, positions[3], 'matches pos-continue match 3 end offset')
is('bar', (perl.matchesDyn('foo bar', '(\\w+)$')), 'matchesDyn matches like matches')

-- Groups that take no part in a match. Expectations from perl 5.42:
--   perl -e 'my @r = ($s =~ /$p/); ...'  (bool, list of $1.., $+[0])
-- A Perl undef capture is nil; the end offset after the captures never is.
-- (`#{ matches(...) }` is no match test when $1 may be undef: Lua 5.5 and
-- LuaJIT report 0 for a table that starts with nil.)
local UNSET = {
    -- s,     pattern,          matched, captures (n, values),  end
    { 'xb',  '(a)?b',          true,  1, {},                     2 },
    { 'ab',  '(a)?b',          true,  1, { 'a' },                2 },
    { 'xb',  '(a)?b(c)?',      true,  2, {},                     2 },
    { 'x',   '^x|(y)',         true,  1, {},                     1 },
    { 'y',   '^x|(y)',         true,  1, { 'y' },                1 },
    { 'b',   '(a)*b',          true,  1, {},                     1 },
    { 'aab', '(a)*b',          true,  1, { 'a' },                3 },
    { 'xb',  '(a){0,2}b',      true,  1, {},                     2 },
    { 'abc', '(a)(x)?(c)?',    true,  3, { 'a' },                1 },
    { 'zz',  '(a)?b',          false },
}
for _, uc in ipairs(UNSET) do
    local s_, p_, want = uc[1], uc[2], uc[3]
    local label = s_ .. ' =~ /' .. p_ .. '/'
    is(want, perl.isMatch(s_, p_), 'isMatch ' .. label)
    is(want, perl.isMatchDyn(s_, p_), 'isMatchDyn ' .. label)
    local r = table.pack(perl.matches(s_, p_))
    local bm = table.pack(perl.isMatch(s_, p_))
    if want then
        local ncap = uc[4]
        is(ncap + 1, r.n, 'matches value count ' .. label)
        is(uc[6], r[r.n], 'matches end offset ' .. label)
        is(ncap + 1, bm.n, 'isMatch value count ' .. label)
        for i = 1, ncap do
            is(uc[5][i], r[i], 'matches $' .. i .. ' ' .. label)
            is(uc[5][i], bm[i + 1], 'isMatch $' .. i .. ' ' .. label)
        end
    else
        is(nil, r[1], 'matches no match ' .. label)
        is(1, bm.n, 'isMatch no match is a single false ' .. label)
        is(0, #{ perl.matches(s_, p_) }, '{ matches() } empty on no match ' .. label)
    end
end
is(true, perl.isMatch('xb', 'b'), 'isMatch without groups is a bare true')
is(1, select('#', perl.isMatch('xb', 'b')), 'isMatch without groups returns one value')
is(false, perl.isMatch(nil, 'b'), 'isMatch of undef is false')
is(false, perl.isMatch('axbx', 'a', 1), 'isMatch honours the start offset')
-- eachMatch: an unset later group is nil, as in Perl ($2 undef)
local seen = {}
for m1, m2 in perl.eachMatch('ab a', '(a)(b)?') do seen[#seen + 1] = { m1, m2 } end
is(2, #seen, 'eachMatch with unset later group finds both matches')
is('b', seen[1][2], 'eachMatch later group set')
is(nil, seen[2][2], 'eachMatch later group unset is nil')

-- perl.eachMatch / perl.eachMatchDyn
local words = {}
for w in perl.eachMatch('foo bar  baz', [[\S+]]) do
    words[#words + 1] = w
end
is(3, #words, 'eachMatch finds all tokens')
is('foo', words[1], 'eachMatch token 1')
is('bar', words[2], 'eachMatch token 2')
is('baz', words[3], 'eachMatch token 3')
local letters, digits = {}, {}
for ma, mb in perl.eachMatch('a1b2c3', [[([a-z])(\d)]]) do
    letters[#letters + 1] = ma
    digits[#digits + 1] = mb
end
is(3, #letters, 'eachMatch multi-capture count')
is('b', letters[2], 'eachMatch multi-capture 1')
is('2', digits[2], 'eachMatch multi-capture 2')
local emptyCount = 0
for _ in perl.eachMatch('', [[x*]]) do
    emptyCount = emptyCount + 1
    if emptyCount > 5 then break end
end
is(1, emptyCount, 'eachMatch does not loop forever on empty matches')
local dynWords = {}
for w in perl.eachMatchDyn('one two', [[\S+]]) do
    dynWords[#dynWords + 1] = w
end
is(2, #dynWords, 'eachMatchDyn matches like eachMatch')

-- perl.findAll / perl.findAllDyn
is('foo,bar,baz', perl.join(',', perl.findAll('foo bar baz', [[\S+]])), 'findAll collects all tokens')
is('a,1,b,2,c,3', perl.join(',', perl.findAll('a1b2c3', [[([a-z])(\d)]])), 'findAll flattens multi-capture matches')
is(0, #perl.findAll('abc', 'xyz'), 'findAll returns empty array on no match')
is('one,two', perl.join(',', perl.findAllDyn('one two', [[\S+]])), 'findAllDyn matches like findAll')

-- perl.subst / perl.substDyn
is('bXnana', perl.subst('banana', 'a', 'X'), 'subst replaces first match only')
is('bXnXnX', perl.subst('banana', 'a', 'X', 'g'), 'subst g flag replaces all matches')
is('bXnXnX', perl.substDyn('banana', 'a', 'X', 'g'), 'substDyn matches like subst')

-- perl.split / perl.splitDyn
local parts = perl.split(',', 'a,b,c')
is(3, #parts, 'split basic count')
is('a', parts[1], 'split basic 1')
is('c', parts[3], 'split basic 3')
local trimmed = perl.split(',', 'a,b,,')
is(2, #trimmed, 'split strips trailing empty fields by default')
local capped = perl.split(',', 'a,b,c,d', 2)
is(2, #capped, 'split limit caps field count')
is('b,c,d', capped[2], 'split limit keeps remainder in last field')
local withCaps = perl.split('([0-9])', 'a1b2c')
is('a', withCaps[1], 'split with capture group section 1')
is('1', withCaps[2], 'split with capture group captured separator 1')
is('b', withCaps[3], 'split with capture group section 2')
is('2', withCaps[4], 'split with capture group captured separator 2')
is('c', withCaps[5], 'split with capture group section 3')
-- (expectations from perl: split //, "ab c" / split /x*/, "axxbc" /
--  split //, "abc", 2)
is('a|b| |c', perl.join('|', perl.split('', 'ab c')), 'split // yields the characters')
is('a|b|c', perl.join('|', perl.split('x*', 'axxbc')), 'split on a pattern that can match empty')
is('a|bc', perl.join('|', perl.split('', 'abc', 2)), 'split // with limit')
local dynParts = perl.splitDyn(',', 'a,b,c')
is(3, #dynParts, 'splitDyn matches like split')

-- perl.eachSplit / perl.eachSplitDyn (streaming form of perl.split, same
-- order/semantics, verified by collecting into an array and comparing)
local function collect(iter)
    local out = {}
    for part in iter do out[#out + 1] = part end
    return out
end

local isParts = collect(perl.eachSplit(',', 'a,b,c'))
is(perl.join(',', perl.split(',', 'a,b,c')), perl.join(',', isParts), 'eachSplit basic matches split')

local isTrimmed = collect(perl.eachSplit(',', 'a,b,,'))
is(#perl.split(',', 'a,b,,'), #isTrimmed, 'eachSplit strips trailing empty fields like split')

local isCapped = collect(perl.eachSplit(',', 'a,b,c,d', 2))
is(perl.join(',', perl.split(',', 'a,b,c,d', 2)), perl.join(',', isCapped), 'eachSplit limit matches split')

local isCaps = collect(perl.eachSplit('([0-9])', 'a1b2c'))
is(perl.join(',', perl.split('([0-9])', 'a1b2c')), perl.join(',', isCaps), 'eachSplit capture interspersion matches split')

local isDynParts = collect(perl.eachSplitDyn(',', 'a,b,c'))
is(perl.join(',', isParts), perl.join(',', isDynParts), 'eachSplitDyn matches like eachSplit')

-- perl.compileEdit: tr/s statements on $_, also with bracketing delimiters
-- (InsertTagValues' default expression for an empty "${TAG;}" is the
--  bracketed `tr(/\\?*:|"<>\0)()d`, Writer.pl:3254)
is('ABCd', perl.compileEdit('tr/a-c/A-C/')('abcd'), 'compileEdit tr///')
is('bXb', perl.compileEdit('s{a}{b}g')('aXa'), 'compileEdit s{}{} bracketed')
is('ABCd', perl.compileEdit('tr[a-c] [A-C]')('abcd'), 'compileEdit tr[][] with whitespace between the parts')
is('abcdefghij', perl.compileEdit([[tr(/\\?*:|"<>\0)()d]])([[a/b\c?d*e:f|g"h<i>j]]),
    'compileEdit default Windows filename filter')
is(nil, perl.compileEdit('$_ = uc'), 'compileEdit rejects code beyond tr/s')

-- perl.hex / perl.lc / pack 'H' (expectations from perl)
is(31, perl.hex('0x1F'), 'hex with 0x prefix')
-- (expectations from perl: oct("17"), oct("0x1F"), oct("0b101"), oct("789"))
is(15, perl.oct('17'), 'oct of an octal string')
is(31, perl.oct('0x1F'), 'oct with 0x prefix is hex')
is(5, perl.oct('0b101'), 'oct with 0b prefix is binary')
is(7, perl.oct('789'), 'oct stops at the first invalid digit')
is(65535, perl.hex('ff_ff'), 'hex ignores underscores')
is(0, perl.hex(''), 'hex of empty string is 0')
is(18, perl.hex('12zz'), 'hex stops at the first non-hex character')
is(16, perl.hex('x10'), 'hex with x prefix')
is('abc', perl.lc('AbC'), 'lc')
is('', perl.lc(nil), 'lc of undef')
-- (expectations from perl: ucfirst('abc def'), lcfirst('ABC'), ucfirst(undef))
is('Abc def', perl.ucfirst('abc def'), 'ucfirst')
is('aBC', perl.lcfirst('ABC'), 'lcfirst')
is('', perl.ucfirst(nil), 'ucfirst of undef')
-- (expectations from perl: rindex("abcabc","bc"), rindex("abcabc","bc",3),
--  rindex("abc","x"), rindex("a\0b\0","\0"), quotemeta("a.b|c_"))
is(4, perl.rindex('abcabc', 'bc'), 'rindex finds the last occurrence')
is(1, perl.rindex('abcabc', 'bc', 3), 'rindex with a start position')
is(-1, perl.rindex('abc', 'x'), 'rindex not found')
is(3, perl.rindex('a\0b\0', '\0'), 'rindex of a null byte')
is('a\\.b\\|c_', perl.quotemeta('a.b|c_'), 'quotemeta')
-- (expectations from perl: chomp with $/="\r\n" on "ab\r\n" and "ab\n",
--  chomp of "x\n\n" with the default $/)
is('ab', (perl.chomp('ab\r\n', '\r\n')), 'chomp with a multi-character $/')
is('ab\n', (perl.chomp('ab\n', '\r\n')), 'chomp leaves a partial $/')
is(2, select(2, perl.chomp('ab\r\n', '\r\n')), 'chomp returns the count removed')
is('x\n', (perl.chomp('x\n\n')), 'chomp removes one default newline')
is('0a1b', perl.unpack('H*', perl.pack('H*', '0a1B')), "pack 'H*' round trip")
-- bit strings (expectations from perl: unpack("b*","A\1"), unpack("B*","A"),
-- unpack("b3C","AB"))
is('1000001010000000', perl.unpack('b*', 'A\1'), "unpack 'b*' lsb first")
is('01000001', perl.unpack('B*', 'A'), "unpack 'B*' msb first")
local b3, c66 = perl.unpack('b3C', 'AB')
is('100', b3, "unpack 'b3' takes 3 bits")
is(66, c66, "unpack 'b3' consumes the whole byte")
is('171,192', perl.join(',', { perl.unpack('C*', perl.pack('H3', 'abc')) }), "pack 'H3' pads the odd nybble")
is('00', perl.unpack('H*', perl.pack('H*', 'g0')), "pack 'H' maps a non-hex letter like perl")
is('1,2', perl.join(',', perl.split(' ', 12 // 10 .. ' 2')), 'split stringifies its operand')
is('123', perl.join(',', perl.split(' ', 123)), 'split of a number')

-- index(), keys(), sort()
is(2, perl.index('abcabc', 'c'), 'index finds first occurrence')
is(5, perl.index('abcabc', 'c', 3), 'index from position')
is(-1, perl.index('abc', 'x'), 'index not found')
is(0, perl.index('abc', 'a', -5), 'index negative position counts as 0')
is(3, perl.index('abc', '', 7), 'index empty substr past end')
is('10,9,a', perl.join(',', perl.sort({ 9, 'a', 10 })), 'sort default is string order')
is('9,10', perl.join(',', perl.sort({ 10, 9 }, function(x, y) return x - y end)), 'sort with numeric cmp')
is('a,b', perl.join(',', perl.sort(perl.keys({ b = 1, a = 2 }))), 'sort keys')

-- `\\` in a replacement is a literal backslash, as in Perl
is('a\\"b', perl.subst('a"b', [[(")]], [[\\$1]]), 'subst replacement \\\\ is one backslash')

-- qx (backticks), system and $? (perl.CHILD_ERROR)
local lines = perl.qx('printf "a\\nb\\n"', true)
is(2, #lines, 'qx list context: one entry per line')
is('b\n', lines[2], 'qx keeps the newline')
is(0, perl.CHILD_ERROR, 'qx sets $? to 0 on success')
perl.qx('exit 3')
is(768, perl.CHILD_ERROR, 'qx sets $? to exit code << 8')
is(256, perl.system('false'), 'system returns $?')
local oldout, olderr = perl.redirectStdio('/dev/null', '/dev/null')
is(-1, perl.system('/nonexistent/program', 'arg'), 'system LIST of a missing program is -1')
perl.redirectStdio(oldout, olderr)

-- 4-arg substr on a carray (`substr($s, $off, $len) = $repl`)
local sb = carray.new('char'):append('hello')
perl.substr(sb, 1, 2, 'XY')
is('hXYlo', sb:tostring(), '4-arg substr replaces in the middle')
sb = carray.new('char'):append('li 10')
perl.substr(sb, -2, 2, '11')
is('li 11', sb:tostring(), '4-arg substr with a negative offset')
sb = carray.new('char'):append('abc')
perl.substr(sb, 3, 0, '!')
is('abc!', sb:tostring(), '4-arg substr inserts at the end')

-- regex, tr and stringification on a carray (Perl's mutable scalar)
sb = carray.new('char'):append('hello world')
ok(perl.isMatch(sb, [[o w]]), 'isMatch reads a carray')
is('w', (perl.matches(sb, [[(w)]])), 'matches reads a carray')
is(sb, perl.subst(sb, [[o]], '0', 'g'), 's///g on a carray returns the carray')
is('hell0 w0rld', sb:tostring(), 's///g on a carray edits it in place')
local _, trCount = perl.tr(sb, 'a-z', 'A-Z')
is(8, trCount, 'tr on a carray counts')
is('HELL0 W0RLD', perl.str(sb), 'tr on a carray edits it in place; str gives its bytes')

-- tr/// against Perl: { search, repl, flags, result, count } on trInput,
-- the results computed by perl 5.42 (`$v =~ tr{SEARCH}{REPL}FLAGS`) --
-- covers the compiled gsub path (no /s), the byte loop (/s) and the carray
-- form
local trInput = "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009"
local trVectors = {
    { "\092x01-\092x1f\092x7f", ".", '', "Hello, World....\000 aaabbb  zz--__??**^]%-\128\255\092x..", 5 },
    { "-_A-Za-z0-9*?", "", 'dc', "HelloWorldaaabbbzz--__??**-x", 18 },
    { "-_A-Za-z0-9", "", 'dc', "HelloWorldaaabbbzz--__-x", 22 },
    { "\0920", "", 'd', "Hello, World.\001\031\127 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 1 },
    { ",", "", 'd', "Hello World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 1 },
    { ".", " ", '', "Hello, World \001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 1 },
    { "a-z", "A-Z", '', "HELLO, WORLD.\001\031\127\000 AAABBB  ZZ--__??**^]%-\128\255\092X\010\009", 17 },
    { "\092\092", "/", '', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255/x\010\009", 1 },
    { "a-c", "x", '', "Hello, World.\001\031\127\000 xxxxxx  zz--__??**^]%-\128\255\092x\010\009", 6 },
    { "a-z", "A-C", 'd', "H, W.\001\031\127\000 AAABBB  --__??**^]%-\128\255\092\010\009", 17 },
    { "a-z", "", '', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 17 },
    { "a-z", "", 's', "Helo, World.\001\031\127\000 ab  z--__??**^]%-\128\255\092x\010\009", 17 },
    { "a-z", "x", 's', "Hx, Wx.\001\031\127\000 x  x--__??**^]%-\128\255\092x\010\009", 17 },
    { " ", "", 's', "Hello, World.\001\031\127\000 aaabbb zz--__??**^]%-\128\255\092x\010\009", 4 },
    { "a-zA-Z", "", 'cd', "HelloWorldaaabbbzzx", 27 },
    { "a-zA-Z", "_", 'c', "Hello__World______aaabbb__zz_______________x__", 27 },
    { "a-zA-Z", "_", 'cs', "Hello_World_aaabbb_zz_x_", 27 },
    { "^]%-", "X", '', "Hello, World.\001\031\127\000 aaabbb  zzXX__??**XXXX\128\255\092x\010\009", 6 },
    { "\092x80-\092xff", "?", '', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-??\092x\010\009", 2 },
    { "", "", 'c', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 46 },
    { "", "x", 'c', "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 46 },
    { "abc", "ab", '', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 6 },
    { "abc", "ab", 'd', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092x\010\009", 6 },
    { "aa", "xy", '', "Hello, World.\001\031\127\000 xxxbbb  zz--__??**^]%-\128\255\092x\010\009", 3 },
    { "\092-a", "+b", '', "Hello, World.\001\031\127\000 bbbbbb  zz++__??**^]%+\128\255\092x\010\009", 6 },
    { "a\092-z", "ABC", '', "Hello, World.\001\031\127\000 AAAbbb  CCBB__??**^]%B\128\255\092x\010\009", 8 },
    { "\092n\092t", "nt", '', "Hello, World.\001\031\127\000 aaabbb  zz--__??**^]%-\128\255\092xnt", 2 },
    { "\092x00-\092x1f", " ", 's', "Hello, World. \127  aaabbb  zz--__??**^]%-\128\255\092x ", 5 },
}
for i, tv in ipairs(trVectors) do
    local tr, trn = perl.tr(trInput, tv[1], tv[2], tv[3])
    is(tv[4], tr, 'tr vector ' .. i .. ' result')
    is(tv[5], trn, 'tr vector ' .. i .. ' count')
    local tb = carray.new('char'):append(trInput)
    local _, tbn = perl.tr(tb, tv[1], tv[2], tv[3])
    is(tv[4], tb:tostring(), 'tr vector ' .. i .. ' on a carray')
    is(tv[5], tbn, 'tr vector ' .. i .. ' count on a carray')
end
-- a cached translator is reused, and a number is stringified first
is('1.5', (perl.tr(1.5, ',', '.')), 'tr on a number')
is('a.b', (perl.tr('a,b', ',', '.')), 'tr again with the cached lists')

-- unpack/pack against Perl: { template, offset, values, end } on unpackInput
-- (offset nil = plain unpack; otherwise Perl's "x$off TEMPLATE" and the end
-- position from a trailing '.'), and { template, value, packed }, all
-- computed by perl 5.42 -- covers the compiled fast path (one numeric code,
-- a run of it, a leading 'x', '*'), the general token loop and the carray
-- form; 'A' strips trailing NULs and all whitespace, pack numifies a string
-- by its numeric prefix ("0x10" is 0)
local unpackInput = "\001\130\003\244\005\006\007\136\009\010\011"
local unpackVectors = {
    { "n", nil, { 386 }, nil },
    { "n", 1, { 33283 }, 3 },
    { "n", 9, { 2571 }, 11 },
    { "n", 11, {  }, 11 },
    { "N", nil, { 25297908 }, nil },
    { "N", 1, { 2181297157 }, 5 },
    { "N", 9, {  }, 9 },
    { "N", 11, {  }, 11 },
    { "v", nil, { 33281 }, nil },
    { "v", 1, { 898 }, 3 },
    { "v", 9, { 2826 }, 11 },
    { "v", 11, {  }, 11 },
    { "V", nil, { 4093870593 }, nil },
    { "V", 1, { 99877762 }, 5 },
    { "V", 9, {  }, 9 },
    { "V", 11, {  }, 11 },
    { "C", nil, { 1 }, nil },
    { "C", 1, { 130 }, 2 },
    { "C", 9, { 10 }, 10 },
    { "C", 11, {  }, 11 },
    { "c", nil, { 1 }, nil },
    { "c", 1, { -126 }, 2 },
    { "c", 9, { 10 }, 10 },
    { "c", 11, {  }, 11 },
    { "s", nil, { -32255 }, nil },
    { "s", 1, { 898 }, 3 },
    { "s", 9, { 2826 }, 11 },
    { "s", 11, {  }, 11 },
    { "S", nil, { 33281 }, nil },
    { "S", 1, { 898 }, 3 },
    { "S", 9, { 2826 }, 11 },
    { "S", 11, {  }, 11 },
    { "l", nil, { -201096703 }, nil },
    { "l", 1, { 99877762 }, 5 },
    { "l", 9, {  }, 9 },
    { "l", 11, {  }, 11 },
    { "L", nil, { 4093870593 }, nil },
    { "L", 1, { 99877762 }, 5 },
    { "L", 9, {  }, 9 },
    { "L", 11, {  }, 11 },
    { "n2", nil, { 386, 1012 }, nil },
    { "n2", 1, { 33283, 62469 }, 5 },
    { "n2", 9, { 2571 }, 11 },
    { "n2", 11, {  }, 11 },
    { "N2", nil, { 25297908, 84281224 }, nil },
    { "N2", 1, { 2181297157, 101156873 }, 9 },
    { "N2", 9, {  }, 9 },
    { "N2", 11, {  }, 11 },
    { "v3", nil, { 33281, 62467, 1541 }, nil },
    { "v3", 1, { 898, 1524, 1798 }, 7 },
    { "v3", 9, { 2826 }, 11 },
    { "v3", 11, {  }, 11 },
    { "C3", nil, { 1, 130, 3 }, nil },
    { "C3", 1, { 130, 3, 244 }, 4 },
    { "C3", 9, { 10, 11 }, 11 },
    { "C3", 11, {  }, 11 },
    { "c3", nil, { 1, -126, 3 }, nil },
    { "c3", 1, { -126, 3, -12 }, 4 },
    { "c3", 9, { 10, 11 }, 11 },
    { "c3", 11, {  }, 11 },
    { "CC", nil, { 1, 130 }, nil },
    { "CC", 1, { 130, 3 }, 3 },
    { "CC", 9, { 10, 11 }, 11 },
    { "CC", 11, {  }, 11 },
    { "NN", nil, { 25297908, 84281224 }, nil },
    { "NN", 1, { 2181297157, 101156873 }, 9 },
    { "NN", 9, {  }, 9 },
    { "NN", 11, {  }, 11 },
    { "nnn", nil, { 386, 1012, 1286 }, nil },
    { "nnn", 1, { 33283, 62469, 1543 }, 7 },
    { "nnn", 9, { 2571 }, 11 },
    { "nnn", 11, {  }, 11 },
    { "n*", nil, { 386, 1012, 1286, 1928, 2314 }, nil },
    { "n*", 1, { 33283, 62469, 1543, 34825, 2571 }, 11 },
    { "n*", 9, { 2571 }, 11 },
    { "n*", 11, {  }, 11 },
    { "N*", nil, { 25297908, 84281224 }, nil },
    { "N*", 1, { 2181297157, 101156873 }, 9 },
    { "N*", 9, {  }, 9 },
    { "N*", 11, {  }, 11 },
    { "C*", nil, { 1, 130, 3, 244, 5, 6, 7, 136, 9, 10, 11 }, nil },
    { "C*", 1, { 130, 3, 244, 5, 6, 7, 136, 9, 10, 11 }, 11 },
    { "C*", 9, { 10, 11 }, 11 },
    { "C*", 11, {  }, 11 },
    { "c*", nil, { 1, -126, 3, -12, 5, 6, 7, -120, 9, 10, 11 }, nil },
    { "c*", 1, { -126, 3, -12, 5, 6, 7, -120, 9, 10, 11 }, 11 },
    { "c*", 9, { 10, 11 }, 11 },
    { "c*", 11, {  }, 11 },
    { "v*", nil, { 33281, 62467, 1541, 34823, 2569 }, nil },
    { "v*", 1, { 898, 1524, 1798, 2440, 2826 }, 11 },
    { "v*", 9, { 2826 }, 11 },
    { "v*", 11, {  }, 11 },
    { "x4N", nil, { 84281224 }, nil },
    { "x4N", 1, { 101156873 }, 9 },
    { "x2nn", nil, { 1012, 1286 }, nil },
    { "x2nn", 1, { 62469, 1543 }, 7 },
    { "x2nn", 9, {  }, 11 },
    { "x10n", nil, {  }, nil },
    { "x10n", 1, {  }, 11 },
    { "x11C", nil, {  }, nil },
    { "x9N", nil, {  }, nil },
    { "x9N", 1, {  }, 10 },
    { "x3a4N", nil, { "\244\005\006\007", 2282293771 }, nil },
    { "x3a4N", 1, { "\005\006\007\136" }, 8 },
    { "a4", nil, { "\001\130\003\244" }, nil },
    { "a4", 1, { "\130\003\244\005" }, 5 },
    { "a4", 9, { "\010\011" }, 11 },
    { "a4", 11, { "" }, 11 },
    { "A4", nil, { "\001\130\003\244" }, nil },
    { "A4", 1, { "\130\003\244\005" }, 5 },
    { "A4", 9, { "" }, 11 },
    { "A4", 11, { "" }, 11 },
    { "a*", nil, { "\001\130\003\244\005\006\007\136\009\010\011" }, nil },
    { "a*", 1, { "\130\003\244\005\006\007\136\009\010\011" }, 11 },
    { "a*", 9, { "\010\011" }, 11 },
    { "a*", 11, { "" }, 11 },
    { "A*", nil, { "\001\130\003\244\005\006\007\136" }, nil },
    { "A*", 1, { "\130\003\244\005\006\007\136" }, 11 },
    { "A*", 9, { "" }, 11 },
    { "A*", 11, { "" }, 11 },
    { "Na4", nil, { 25297908, "\005\006\007\136" }, nil },
    { "Na4", 1, { 2181297157, "\006\007\136\009" }, 9 },
    { "Na4", 9, { "\010\011" }, 11 },
    { "Na4", 11, { "" }, 11 },
    { "nC", nil, { 386, 3 }, nil },
    { "nC", 1, { 33283, 244 }, 4 },
    { "nC", 9, { 2571 }, 11 },
    { "nC", 11, {  }, 11 },
    { "n6", nil, { 386, 1012, 1286, 1928, 2314 }, nil },
    { "n6", 1, { 33283, 62469, 1543, 34825, 2571 }, 11 },
    { "n6", 9, { 2571 }, 11 },
    { "n6", 11, {  }, 11 },
    { "N3", nil, { 25297908, 84281224 }, nil },
    { "N3", 1, { 2181297157, 101156873 }, 9 },
    { "N3", 9, {  }, 9 },
    { "N3", 11, {  }, 11 },
    { "x4n*", nil, { 1286, 1928, 2314 }, nil },
    { "x4n*", 1, { 1543, 34825, 2571 }, 11 },
    { "H2H2", nil, { "01", "82" }, nil },
    { "H2H2", 1, { "82", "03" }, 3 },
    { "H2H2", 9, { "0a", "0b" }, 11 },
    { "H2H2", 11, { "", "" }, 11 },
    { "x1 C2", nil, { 130, 3 }, nil },
    { "x1 C2", 1, { 3, 244 }, 4 },
    { "x1 C2", 9, { 11 }, 11 },
}
for _, uv in ipairs(unpackVectors) do
    local label = 'unpack ' .. uv[1] .. ' at ' .. tostring(uv[2])
    for _, src in ipairs({ unpackInput, carray.new('char'):append(unpackInput) }) do
        local r = table.pack(perl.unpack(uv[1], src, uv[2]))
        local nExp = #uv[3] + (uv[2] and 1 or 0)
        is(nExp, r.n, label .. ' value count (' .. type(src) .. ')')
        for k = 1, #uv[3] do is(uv[3][k], r[k], label .. ' value ' .. k .. ' (' .. type(src) .. ')') end
        if uv[2] then is(uv[4], r[nExp], label .. ' end position (' .. type(src) .. ')') end
    end
end
local packVectors = {
    { "n", 0, "\000\000" },
    { "n", 255, "\000\255" },
    { "n", 256, "\001\000" },
    { "n", 65536, "\000\000" },
    { "n", -1, "\255\255" },
    { "n", -129, "\255\127" },
    { "n", 4294967296, "\000\000" },
    { "n", 3.7, "\000\003" },
    { "n", -3.7, "\255\253" },
    { "n", '12', "\000\012" },
    { "n", "0x10", "\000\000" },
    { "n", '', "\000\000" },
    { "N", 0, "\000\000\000\000" },
    { "N", 255, "\000\000\000\255" },
    { "N", 256, "\000\000\001\000" },
    { "N", 65536, "\000\001\000\000" },
    { "N", -1, "\255\255\255\255" },
    { "N", -129, "\255\255\255\127" },
    { "N", 4294967296, "\000\000\000\000" },
    { "N", 3.7, "\000\000\000\003" },
    { "N", -3.7, "\255\255\255\253" },
    { "N", '12', "\000\000\000\012" },
    { "N", "0x10", "\000\000\000\000" },
    { "N", '', "\000\000\000\000" },
    { "v", 0, "\000\000" },
    { "v", 255, "\255\000" },
    { "v", 256, "\000\001" },
    { "v", 65536, "\000\000" },
    { "v", -1, "\255\255" },
    { "v", -129, "\127\255" },
    { "v", 4294967296, "\000\000" },
    { "v", 3.7, "\003\000" },
    { "v", -3.7, "\253\255" },
    { "v", '12', "\012\000" },
    { "v", "0x10", "\000\000" },
    { "v", '', "\000\000" },
    { "V", 0, "\000\000\000\000" },
    { "V", 255, "\255\000\000\000" },
    { "V", 256, "\000\001\000\000" },
    { "V", 65536, "\000\000\001\000" },
    { "V", -1, "\255\255\255\255" },
    { "V", -129, "\127\255\255\255" },
    { "V", 4294967296, "\000\000\000\000" },
    { "V", 3.7, "\003\000\000\000" },
    { "V", -3.7, "\253\255\255\255" },
    { "V", '12', "\012\000\000\000" },
    { "V", "0x10", "\000\000\000\000" },
    { "V", '', "\000\000\000\000" },
    { "C", 0, "\000" },
    { "C", 255, "\255" },
    { "C", 256, "\000" },
    { "C", 65536, "\000" },
    { "C", -1, "\255" },
    { "C", -129, "\127" },
    { "C", 4294967296, "\000" },
    { "C", 3.7, "\003" },
    { "C", -3.7, "\253" },
    { "C", '12', "\012" },
    { "C", "0x10", "\000" },
    { "C", '', "\000" },
    { "c", 0, "\000" },
    { "c", 255, "\255" },
    { "c", 256, "\000" },
    { "c", 65536, "\000" },
    { "c", -1, "\255" },
    { "c", -129, "\127" },
    { "c", 4294967296, "\000" },
    { "c", 3.7, "\003" },
    { "c", -3.7, "\253" },
    { "c", '12', "\012" },
    { "c", "0x10", "\000" },
    { "c", '', "\000" },
    { "s", 0, "\000\000" },
    { "s", 255, "\255\000" },
    { "s", 256, "\000\001" },
    { "s", 65536, "\000\000" },
    { "s", -1, "\255\255" },
    { "s", -129, "\127\255" },
    { "s", 4294967296, "\000\000" },
    { "s", 3.7, "\003\000" },
    { "s", -3.7, "\253\255" },
    { "s", '12', "\012\000" },
    { "s", "0x10", "\000\000" },
    { "s", '', "\000\000" },
    { "S", 0, "\000\000" },
    { "S", 255, "\255\000" },
    { "S", 256, "\000\001" },
    { "S", 65536, "\000\000" },
    { "S", -1, "\255\255" },
    { "S", -129, "\127\255" },
    { "S", 4294967296, "\000\000" },
    { "S", 3.7, "\003\000" },
    { "S", -3.7, "\253\255" },
    { "S", '12', "\012\000" },
    { "S", "0x10", "\000\000" },
    { "S", '', "\000\000" },
    { "l", 0, "\000\000\000\000" },
    { "l", 255, "\255\000\000\000" },
    { "l", 256, "\000\001\000\000" },
    { "l", 65536, "\000\000\001\000" },
    { "l", -1, "\255\255\255\255" },
    { "l", -129, "\127\255\255\255" },
    { "l", 4294967296, "\000\000\000\000" },
    { "l", 3.7, "\003\000\000\000" },
    { "l", -3.7, "\253\255\255\255" },
    { "l", '12', "\012\000\000\000" },
    { "l", "0x10", "\000\000\000\000" },
    { "l", '', "\000\000\000\000" },
    { "L", 0, "\000\000\000\000" },
    { "L", 255, "\255\000\000\000" },
    { "L", 256, "\000\001\000\000" },
    { "L", 65536, "\000\000\001\000" },
    { "L", -1, "\255\255\255\255" },
    { "L", -129, "\127\255\255\255" },
    { "L", 4294967296, "\000\000\000\000" },
    { "L", 3.7, "\003\000\000\000" },
    { "L", -3.7, "\253\255\255\255" },
    { "L", '12', "\012\000\000\000" },
    { "L", "0x10", "\000\000\000\000" },
    { "L", '', "\000\000\000\000" },
}
for _, pv in ipairs(packVectors) do
    is(pv[3], perl.pack(pv[1], pv[2]), 'pack ' .. pv[1] .. ' of ' .. tostring(pv[2]))
end

-- pack 'u' (uuencode, as Perl: 0 is written as '`')
is("#86)C\n", perl.pack('u', 'abc'), "pack 'u' of a short string")
is("!````\n", perl.pack('u', '\0'), "pack 'u' writes 0 as a backquote")
is('', perl.pack('u', ''), "pack 'u' of an empty string")

-- a replacement string unescapes backslashed punctuation, as Perl does
is(' \\d+', perl.subst(' 10', [[ \d+]], [[ \\d\+]]), 'subst replacement: \\+ is +')

-- sort with a block is stable, as Perl's mergesort
do
    local sorted = perl.sort({ 'b2', 'a1', 'b1', 'a2' }, function(x, y)
        return x:sub(1, 1) < y:sub(1, 1) and -1 or (x:sub(1, 1) > y:sub(1, 1) and 1 or 0)
    end)
    is('a1 a2 b2 b1', table.concat(sorted, ' '), 'sort block keeps the input order of equal elements')
end

-- file operations: rename, utime, link, symlink, Cwd::abs_path
do
    local dir = TestLib.TEST_DIR
    local fa, fb = dir .. '/facade_a.tmp', dir .. '/facade_b.tmp'
    os.remove(fa); os.remove(fb)
    local fh = io.open(fa, 'w'); fh:write('x'); fh:close()
    ok(perl.rename(fa, fb), 'rename returns true on success')
    ok(not perl.rename(fa, fb), 'rename returns false for a missing file')
    is(1, perl.utime(1000000000, 1000000000.7, fb), 'utime returns the number of files changed')
    is(1000000000, require('lfs').attributes(fb).modification, 'utime sets whole seconds')
    is(0, perl.utime(1, 1, io.stdout), 'utime of a filehandle is not supported (futimes)')
    ok(perl.link(fb, fa), 'link creates a hard link')
    os.remove(fa)
    ok(perl.symlink(fb, fa), 'symlink creates a symbolic link')
    -- Windows has no realpath(3) (Cwd.pm does not resolve NTFS reparse
    -- points there either, see perl.lua's abs_path): abs_path(fa) stays
    -- fa's own absolute path, not fb's; only POSIX resolves the symlink
    if package.config:sub(1, 1) == '\\' then
        ok(perl.abs_path(fa) ~= perl.abs_path(fb), 'abs_path on Windows does not resolve a symlink')
    else
        is(perl.abs_path(fb), perl.abs_path(fa), 'abs_path resolves a symlink to its target')
    end
    -- binmode(FILEHANDLE[, ':crlf']): a real no-op everywhere but Windows
    -- (sys.setmode), so this only confirms the plumbing (a genuine file
    -- handle, no crash) -- the CRLF translation itself only CI on Windows
    -- can confirm
    do
        local f = io.open(fb, 'wb')
        ok(perl.binmode(f) == true, 'binmode(FILEHANDLE) succeeds')
        ok(perl.binmode(f, ':crlf') == true, "binmode(FILEHANDLE, ':crlf') succeeds")
        f:close()
    end
    os.remove(fa); os.remove(fb)
    is(require('lfs').currentdir(), perl.abs_path('.'), "abs_path('.') is the current directory")
    is(nil, perl.abs_path(fa), 'abs_path of a missing file is undef')
end

-- list builtins: shift, unshift, push, grep, ref
do
    local items = { 'b', 'c' }
    is(3, perl.unshift(items, 'a'), 'unshift returns the new length')
    is('a', perl.shift(items), 'shift returns the first element')
    is(3, perl.push(items, 'd'), 'push returns the new length')
    is('b c d', table.concat(items, ' '), 'shift/unshift/push keep the order')
    is('b d', table.concat(perl.grep('^[bd]$', items), ' '), 'grep keeps the matching elements')
    is(nil, perl.shift({}), 'shift of an empty array is undef')
    is('ARRAY', perl.ref({ 1 }), 'ref of a list')
    is('HASH', perl.ref({ a = 1 }), 'ref of a hash')
    is('SCALAR', perl.ref({ ref = 'SCALAR', value = 'x' }), 'ref of a SCALAR reference')
    is('', perl.ref('x'), 'ref of a plain value')
    is('GLOB', perl.ref(io.stdout), 'ref of a file handle')
end

-- magic string increment (++$alpha in the exiftool script)
is('b', perl.increment('a'), 'increment a')
is('ba', perl.increment('az'), 'increment carries')
is('aaa', perl.increment('zz'), 'increment grows')
is('Ba0', perl.increment('Az9'), 'increment of letters and digits')
is('3', perl.increment('2'), 'increment of a digit string is a string increment')
is('100', perl.increment('99'), 'increment of digits carries')

-- eval of a Perl expression (the -if condition)
do
    local vars = { info = { FileType = 'JPEG', ISO = '100', Make = 'Canon' } }
    local function ev(code) return perl.str(perl.eval(code, vars)) end
    is('1', ev([[$info{'FileType'} eq "JPEG"]]), 'eval eq')
    is('', ev([[$info{'FileType'} ne "JPEG"]]), 'eval ne is false as the empty string')
    is('1', ev([[$info{'ISO'} > 50 and $info{'Make'} =~ /canon/i]]), 'eval numeric compare and regex')
    is('1', ev([[not defined $info{'Missing'}]]), 'eval not defined')
    is('1', ev([["$info{'Make'}" eq 'Canon' ? 1 : 0]]), 'eval interpolation and ?:')
    is('106', ev([[$info{'ISO'} + 2 * 3]]), 'eval precedence')
    is('1', ev([[length $info{'Make'} == 5]]), 'eval named unary operator binds tighter than ==')
    local okEval, err = pcall(perl.eval, [[$info{'FileType'} eq]], vars)
    ok(not okEval and perl.isDie(err) and err.msg:find('^syntax error') ~= nil, 'eval dies on a syntax error')
    local called
    perl.eval('End()', {}, { End = function() called = 1 return 1 end })
    is(1, called, 'eval calls a passed-in function')
end

-- eval of statements editing $_ (the advanced formatting expressions)
do
    local function ed(code, dollarUnderscore)
        local vars = { _ = dollarUnderscore }
        perl.eval(code, vars)
        return vars._
    end
    is('Exif', ed([[/^Test/ ? $_=undef : s/Tool$//]], 'ExifTool'), 'eval ?: with s/// on $_')
    is(nil, ed([[/^Test/ ? $_=undef : s/Tool$//]], 'Test'), 'eval ?: with an assignment of undef')
    is('(None)', ed([[s/n/N/;$_=undef if /Y/]], '(none)'), 'eval statements with an if modifier')
    is(nil, ed([[s/n/N/;$_=undef if /Y/]], 'YCbCr'), 'eval if modifier taken')
    is('a_b_c', ed([[tr/ /_/]], 'a b c'), 'eval tr///')
    is('x/y', ed([[s/\//\//g;s{-}{/}]], 'x-y'), 'eval s/// with escaped delimiters and s{}{}')
    is('ABC', ed([[$_ = uc]], 'abc'), 'eval assignment of a named unary operator on $_')
    is('ab', ed([[$_ = "a" unless 0; $_ = "c" if 0; $_ = $_ . "b"]], 'z'), 'eval unless modifier')
    local vars = { x = 'abc' }
    is(1, perl.eval([[$x =~ s/b/B/]], vars), 's/// returns the number of substitutions')
    is('aBc', vars.x, 'eval =~ s/// edits the bound variable')
end

-- eval: the constructs beyond plain expressions (lists, `my`, blocks,
-- builtins, captures, method calls) and the "unsupported" error
do
    local function ed(code, dollarUnderscore, funcs)
        local vars = { _ = dollarUnderscore }
        perl.eval(code, vars, funcs)
        return vars._
    end
    is('a/3', ed([[my @a = split /, /, $_; $_ = "$a[0]/" . scalar(@a)]], 'a, b, c'),
       'eval my @array = split, element, scalar(@array) and interpolation')
    is('c', ed([=[my @a = split /,/; $_ = $a[-1]]=], 'a,b,c'), 'eval split on $_ and a negative index')
    is('canon_005', ed([[$_ = lc($_) . sprintf("_%03d", length)]], 'Canon'),
       'eval lc() . sprintf() with length of $_')
    is('05/2004', ed([[my ($y, $m) = /^(\d+):(\d+)/; $_ = "$m/$y"]], '2004:05:06'),
       'eval my (list) = match in list context')
    is('06.05', ed([[/:(\d+):(\d+)$/ and $_ = "$2.$1"]], '2004:05:06'), 'eval $1/$2 after a match')
    is('C', ed([[if (/canon/i) { $_ = "C" } elsif (/nikon/i) { $_ = "N" } else { $_ = "?" }]], 'Canon'),
       'eval if block')
    is('N', ed([[if (/canon/i) { $_ = "C" } elsif (/nikon/i) { $_ = "N" } else { $_ = "?" }]], 'NIKON'),
       'eval elsif block')
    is('?', ed([[unless (/x/) { $_ = "?" }]], 'abc'), 'eval unless block')
    is('ABC', ed([[$_ = uc(substr($_, 0, 3))]], 'abcdef'), 'eval substr')
    is('a+b+c', ed([[$_ = join "+", split /, /]], 'a, b, c'), 'eval list operators without parentheses')
    is('Canon-5', ed([[$_ .= "-" . length]], 'Canon'), 'eval .= compound assignment')
    is('x2', ed([[my $n = 2; $n++; ++$n; $n -= 2; $_ = "x$n"]], ''), 'eval ++, -= on a my variable')
    is('b,c,a', ed([[my @a = (1, 2); push @a, "a"; @a = split /,/, "b,c"; push @a, "a"; $_ = join ",", @a]], ''),
       'eval push and list assignment')
    is(3, ed([[$_ = 6 & 3 | 1]], ''), 'eval bitwise operators')
    is(2, ed([[my @w = /(\w+)/g; $_ = @w]], 'ab cd'), 'eval /g in list context, array in scalar context')
    -- a method call on an object variable: $self->Method(ARGS)
    do
        local obj = setmetatable({ v = 'V' }, { __index = { Get = function(o, k) return o.v .. k end } })
        local vars = { _ = 'z', self = obj }
        perl.eval([[$_ = $self->Get('1') if $self->Get('')]], vars)
        is('V1', vars._, 'eval $self->Method(ARGS)')
    end
    -- my variables do not leak into the caller's variables
    do
        local vars = { _ = 'a', x = 'outer' }
        perl.eval([[my $x = "inner"; $_ = $x]], vars)
        is('inner', vars._, 'eval my variable is read')
        is('outer', vars.x, 'eval my variable shadows, not overwrites, the caller variable')
    end
    -- valid Perl outside the subset: a loud, specific error
    for _, case in ipairs({
        { [[foreach my $x (1) { $_ = $x }]], 'foreach loop' },
        { [[$_ = join ",", sort split //]], 'sort' },
        { [[grep { /x/ } $_]], 'grep' },
        { [[$_ = $h{$k}]], 'hash subscript with an expression' },
        { [[$_ = mystery($_)]], 'function mystery()' },
        { [[$_ = \$x]], 'reference \\' },
        { [[s/a/uc($&)/e]], 's///e flag' },
    }) do
        local okEval, err = pcall(perl.eval, case[1], { _ = 'a' })
        ok(not okEval and perl.isUnsupported(err) and err.unsupported == case[2] and
           err.msg:find('^Perl syntax unsupported in lexiftool: ', 1) ~= nil,
           'eval reports unsupported ' .. case[2] .. ': ' .. tostring(err))
    end
    -- a real syntax error stays Perl's syntax error, not "unsupported"
    local okEval, err = pcall(perl.eval, [[$_ = (1 + ]], { _ = 'a' })
    ok(not okEval and perl.isDie(err) and not perl.isUnsupported(err) and err.msg:find('^syntax error') ~= nil,
       'eval syntax error is not reported as unsupported')
end

-- print/printf with Perl stringification, and the autoflush flag
do
    local dir = TestLib.TEST_DIR
    local f = dir .. '/facade_print.tmp'
    local fh = io.open(f, 'w')
    is(1, perl.print(fh, 'a', 2.0, nil, 3), 'print returns 1')
    perl.printf(fh, '%5d|%s\n', 7, 1.5)
    is(0, perl.autoflush(fh, 1), 'autoflush returns the previous setting')
    is(1, perl.autoflush(fh), 'autoflush without a value reads the setting')
    fh:close()
    local rh = io.open(f, 'r')
    is('a23    7|1.5\n', rh:read('a'), 'print stringifies like Perl')
    rh:close()
    os.remove(f)
end

-- sysread from a growing file: the data so far, 0 at the end, more later
do
    local dir = TestLib.TEST_DIR
    local f = dir .. '/facade_sysread.tmp'
    local wh = io.open(f, 'w')
    wh:write('-S\n-Fi')
    wh:flush()
    local rh = io.open(f, 'r')
    local buff, got = perl.sysread(rh, '', 65536, 0)
    is(3, got, 'sysread returns a complete line first')
    buff = perl.sysread(rh, buff, 65536, #buff)
    is('-S\n-Fi', buff, 'sysread appends a partial last line')
    buff, got = perl.sysread(rh, buff, 65536, #buff)
    is(0, got, 'sysread returns 0 at the end of the file')
    wh:write('le\n')
    wh:close()
    buff = perl.sysread(rh, buff, 65536, #buff)
    is('-S\n-File\n', buff, 'sysread sees data appended after the end')
    rh:close()
    os.remove(f)
end

-- lexiftool.sys primitives (src/lexiftool/sys.c): $^O, $ENV{TZ} + tzset, chmod,
-- truncate, %SIG, Term::ReadKey, and the optional Brotli module
do
    local osname = perl.osname()
    ok(({ linux = 1, darwin = 1, MSWin32 = 1, cygwin = 1, msys = 1, freebsd = 1,
          openbsd = 1, netbsd = 1, solaris = 1 })[osname] ~= nil, 'osname is a $^O value: ' .. osname)
    if package.config:sub(1, 1) == '\\' then is('MSWin32', osname, 'osname on Windows') end

    -- the interpreter running this test, for the checks that need a child
    -- process of their own
    local lua = TestLib.LUA
    do
        local i = -1
        while arg and arg[i - 1] do i = i - 1; lua = arg[i] end
    end

    -- $ENV{TZ} = ...; tzset: os.getenv and localtime see the new zone at once,
    -- even after localtime has already run (the reason tzset is needed).
    -- In a child process: the change is process-wide and permanent (no
    -- unsetenv, as upstream), and the other tests share this one.
    if lua and osname ~= 'MSWin32' then
        local p = io.popen(lua .. [[ -e "local perl = require('lexiftool.perl'); local _ = os.date('*t', 0);]] ..
            [[ local r = perl.setenv('TZ', 'EST5EDT'); perl.tzset();]] ..
            [[ io.write(tostring(r), ' ', os.getenv('TZ'), ' ', os.date('*t', 0).hour, ' ',]] ..
            [[ perl.localtime(15552000)[9], ' '); perl.setenv('TZ', 3.0); io.write(os.getenv('TZ'))"]])
        local out = p:read('a')
        p:close()
        is('true EST5EDT 19 1 3', out, 'setenv TZ + tzset: getenv, localtime, DST, Perl stringification')
    end

    local dir = TestLib.TEST_DIR
    local f = dir .. '/facade_sys.tmp'
    local fh = io.open(f, 'w+b')
    fh:write(('x'):rep(100))
    is(1, perl.truncate(fh, 10), 'truncate returns 1')
    fh:close()
    is(10, require('lfs').attributes(f).size, 'truncate shortened the file')
    fh = io.open(f, 'rb')
    local t1, err = perl.truncate(fh, 0)
    ok(t1 == nil and type(err) == 'string', 'truncate of a read-only handle fails with a message')
    fh:close()

    if osname ~= 'MSWin32' then
        is(1, perl.chmod(tonumber('640', 8), f), 'chmod returns the count')
        is('rw-r-----', require('lfs').attributes(f).permissions, 'chmod set the mode')
        is(1, perl.chmod(tonumber('644', 8), f, dir .. '/facade_sys_missing.tmp'),
           'chmod counts only the files it changed')
    else
        is(1, perl.chmod(tonumber('444', 8), f), 'chmod read-only (Windows)')
        is(1, perl.chmod(tonumber('666', 8), f), 'chmod writable (Windows)')
    end
    -- chown(-1, -1, FILE) changes nothing and still counts the file, as in
    -- Perl (the only form that needs no privilege, so the only one tested)
    is(1, perl.chown(-1, -1, f), 'chown -1/-1 counts an existing file')
    is(0, perl.chown(-1, -1, dir .. '/facade_sys_missing.tmp'), 'chown skips a missing file')
    os.remove(f)

    -- $SIG{USR1} = handler: runs with the signal name, between two Lua
    -- instructions, after the signal arrives (POSIX only: no USR1 on Windows)
    if osname ~= 'MSWin32' then
        local got = {}
        perl.SIG.USR1 = function(name) got[#got + 1] = name end
        os.execute('(sleep 0.1; kill -USR1 ' .. perl.pid() .. ') &')
        local t0 = os.clock()
        while #got == 0 and os.clock() - t0 < 5 do end
        is('USR1', got[1], '%SIG handler called with the signal name')
        perl.SIG.USR1 = 'DEFAULT'
        is('DEFAULT', perl.SIG.USR1, '%SIG keeps the assigned value')
        perl.SIG.NOSUCHSIG = function() end    -- (Perl: ignored, no signal)
        ok(true, '%SIG accepts a name with no signal behind it')
        perl.SIG.NOSUCHSIG = nil
    end

    -- Term::ReadKey: ReadMode('cbreak') + ReadKey(0) reads one key; with
    -- STDIN not a terminal (here a pipe into a child interpreter) it reads
    -- the next byte
    ok(perl.evalRequire('Term::ReadKey'), 'Term::ReadKey is provided')
    if osname ~= 'MSWin32' then
        if lua then
            local p = io.popen("printf 'ab' | " .. lua .. " -e \"local T = require('lexiftool.perl').TermReadKey;" ..
                " T.ReadMode('cbreak'); io.write(T.ReadKey(0), '|', T.ReadKey(0)); T.ReadMode(0)\"")
            is('a|b', p:read('a'), 'ReadKey reads one key at a time')
            p:close()
        end
    end

    -- IO::Uncompress::Brotli / IO::Compress::Brotli (over lbrotli)
    local haveUnbro, IO_Uncompress_Brotli = perl.evalRequire('IO::Uncompress::Brotli')
    local haveBro, IO_Compress_Brotli = perl.evalRequire('IO::Compress::Brotli')
    if haveUnbro and haveBro then
        local data = ('lexiftool '):rep(1000)
        local packed = IO_Compress_Brotli.bro(data)
        ok(#packed < #data, 'bro compresses')
        ok(data == IO_Uncompress_Brotli.unbro(packed, 100000000), 'unbro(bro(x)) == x')
        ok(data == IO_Uncompress_Brotli.unbro(packed), 'unbro without max_size')
        local okSmall, msg = pcall(IO_Uncompress_Brotli.unbro, packed, 100)
        ok(not okSmall and tostring(msg):find('Error in BrotliDecoderDecompress', 1, true),
           'unbro beyond max_size dies like the XS')
        ok(not pcall(IO_Uncompress_Brotli.unbro, packed:sub(1, 5), 100000), 'unbro of truncated data dies')
        ok(not pcall(IO_Compress_Brotli.bro, data, 12), 'bro rejects quality 12')
        -- data compressed by the brotli(1) command line tool, where installed
        local bp = io.popen('printf "%s" "hello brotli" | brotli -c 2>/dev/null')
        local fromCli = bp and bp:read('a')
        if bp then bp:close() end
        if fromCli and #fromCli > 0 then
            is('hello brotli', IO_Uncompress_Brotli.unbro(fromCli, 1000), 'unbro reads brotli(1) output')
        end
    else
        ok(not haveUnbro and not haveBro, 'without lbrotli both Brotli modules are missing')
    end

    -- process/file helpers used by the CLI harness
    local sys = require('lexiftool.sys')
    local lfs = require('lfs')
    ok(type(sys.cpu_count()) == 'number' and sys.cpu_count() >= 1, 'cpu_count >= 1')
    ok(type(sys.getpid()) == 'number' and sys.getpid() > 0, 'getpid > 0')
    do
        local src = dir .. '/facade_spawn_src.tmp'
        local dst = dir .. '/facade_spawn_dst.tmp'
        local out = dir .. '/facade_spawn_out.tmp'
        local errFile = dir .. '/facade_spawn_err.tmp'
        local function read(p)
            local ioh = io.open(p, 'rb')
            if not ioh then return '' end
            local d = ioh:read('a')
            ioh:close()
            return d
        end
        local function write(p, d)
            local ioh = assert(io.open(p, 'wb'))
            ioh:write(d)
            ioh:close()
        end
        write(src, 'helper\n')
        ok(sys.copy_file(src, dst), 'copy_file copies')
        is('helper\n', read(dst), 'copy_file content')
        local fixed = 4102444800
        ok(sys.set_times(dst, fixed, fixed, fixed), 'set_times succeeds')
        is(fixed, math.floor(lfs.attributes(dst).modification), 'set_times set mtime')
        -- Windows-only helpers (Win32API::File and ExifTool::GetFileTime)
        if sys.get_file_attributes then
            ok(type(sys.get_file_attributes(dst)) == 'number',
               'get_file_attributes returns the attribute bits')
            is(nil, sys.get_file_attributes(dst .. '.missing'),
               'get_file_attributes of a missing path is nil')
        end
        if sys.get_full_path_name then
            local abs = sys.get_full_path_name(dst)
            ok(type(abs) == 'string' and abs:sub(1, 1) ~= '.',
               'get_full_path_name returns an absolute path')
        end
        if sys.get_file_time then
            local fth = assert(io.open(dst, 'rb'))
            local fa, fm, fc = sys.get_file_time(fth)
            ok(type(fa) == 'number' and type(fm) == 'number' and type(fc) == 'number',
               'get_file_time returns three times')
            is(fixed, math.floor(fm), 'get_file_time mtime matches set_times')
            fth:close()
            fth = assert(io.open(dst, 'r+b'))
            ok(sys.set_file_time(fth, nil, fixed + 60, nil), 'set_file_time succeeds')
            fa, fm = sys.get_file_time(fth)
            is(fixed + 60, math.floor(fm), 'set_file_time set mtime')
            is(fixed, math.floor(fa), 'set_file_time left atime unchanged')
            fth:close()
        end
        -- the wide Windows handle sys.open returns (io.type and the standard
        -- file methods must work on it)
        if sys.open then
            local opened = dir .. '/facade_open.tmp'
            local fw = sys.open(opened, '>')
            ok(io.type(fw) == 'file', 'sys.open returns a Lua file')
            fw:write('wide\n')
            fw:close()
            is('wide\n', read(opened), 'sys.open wrote the file')
            local fr = sys.open(opened, '<')
            is('wide\n', fr:read('a'), 'sys.open read the file back')
            fr:close()
            is(nil, sys.open(dir .. '/no_such_dir/x', '<'), 'sys.open of a bad path fails')
            sys.unlink(opened)
        end
        -- rename/unlink back the Windows wide operations (POSIX path here)
        local moved = dir .. '/facade_spawn_moved.tmp'
        local other = dir .. '/facade_spawn_other.tmp'
        write(other, 'other\n')
        ok(sys.rename(dst, moved), 'rename moves a file')
        is('helper\n', read(moved), 'rename moved the right file')
        ok(sys.rename(moved, other), 'rename replaces an existing target')
        is('helper\n', read(other), 'rename replaced the target')
        ok(sys.unlink(other), 'unlink removes a file')
        is(nil, lfs.attributes(other), 'unlink removed the file')
        is(nil, sys.unlink(other), 'unlink of a missing file fails')
        is(nil, sys.rename(other, moved), 'rename of a missing file fails')
        write(dst, 'perl\n')
        local made = dir .. '/facade_made_dir'
        ok(perl.mkdir(made, 511), 'perl.mkdir creates a directory')
        is('directory', require('lfs').attributes(made).mode, 'perl.mkdir made a directory')
        ok(not perl.mkdir(made, 511), 'perl.mkdir of an existing directory fails')
        require('lfs').rmdir(made)
        ok(perl.rename(dst, moved), 'perl.rename moves a file')
        is(1, perl.unlink(moved), 'perl.unlink counts deleted files')
        is(0, perl.unlink(moved), 'perl.unlink ignores missing files')
        -- File::Glob::bsd_glob (wildcard expansion, '**' crossing directories)
        do
            local gglob = dir .. '/facade_glob_dir'
            local gsub = gglob .. '/sub'
            local function rels(pattern)
                local found = {}
                for i, p in ipairs(perl.bsd_glob(pattern)) do
                    found[i] = p:sub(#gglob + 2)
                end
                return table.concat(found, ', ')
            end
            require('lfs').mkdir(gglob)
            require('lfs').mkdir(gsub)
            write(gglob .. '/a.jpg', 'a')
            write(gglob .. '/b.jpg', 'b')
            write(gglob .. '/c.txt', 'c')
            write(gsub .. '/d.jpg', 'd')
            write(gglob .. '/aXjpg', 'x')
            write(gglob .. '/.e.jpg', 'e')
            is('a.jpg, b.jpg', rels(gglob .. '/*.jpg'), 'bsd_glob matches one component and sorts')
            is('c.txt', rels(gglob .. '/*.txt'), 'bsd_glob matches by extension')
            is('a.jpg, b.jpg, sub/d.jpg', rels(gglob .. '/**/*.jpg'), "bsd_glob '**' crosses directories")
            is('a.jpg, b.jpg', rels(gglob .. '/?.jpg'), 'bsd_glob "?" matches a single character')
            is('a.jpg, b.jpg', rels(gglob .. '/[ab].jpg'), 'bsd_glob "[...]" matches a set')
            is('a.jpg', rels(gglob .. '/a.jpg'), 'bsd_glob resolves a literal name')
            is(0, #perl.bsd_glob(gglob .. '/nomatch*.jpg'), 'bsd_glob returns an empty list for no match')
            is('a.jpg, b.jpg', rels(gglob .. '/*.jpg'), "bsd_glob '.' is literal (no aXjpg)")
            is('a.jpg, aXjpg', rels(gglob .. '/a?jpg'), "bsd_glob '?' matches '.' and 'X'")
            is('.e.jpg', rels(gglob .. '/.*.jpg'), 'bsd_glob matches a leading dot explicitly')
            local dotted = {}
            for i, p in ipairs(perl.bsd_glob(gglob .. '/*.jpg', 1)) do dotted[i] = p:sub(#gglob + 2) end
            is('.e.jpg, a.jpg, b.jpg', table.concat(dotted, ', '), 'bsd_glob matchDot includes dot files')
            perl.unlink(gsub .. '/d.jpg')
            require('lfs').rmdir(gsub)
            for _, name in ipairs({ 'a.jpg', 'b.jpg', 'c.txt', 'aXjpg', '.e.jpg' }) do
                perl.unlink(gglob .. '/' .. name)
            end
            require('lfs').rmdir(gglob)
        end
        if lua then
            local p = sys.spawn({ lua, '-e', 'io.write("child")' },
                                { stdout = out, stderr = errFile })
            ok(p ~= nil, 'spawn returns a process')
            local code, _, timed = p:wait(10000)
            is(0, code, 'spawned interpreter exits 0')
            is(false, timed, 'spawned interpreter did not time out')
            is('child', read(out), 'spawn redirected stdout')
            is('', read(errFile), 'spawn redirected stderr')

            sys.setenv('LEXIFTOOL_TEST_SPAWN_ENV', 'inherited')
            local e = sys.spawn({ lua, '-e',
                'io.write(os.getenv("LEXIFTOOL_TEST_SPAWN_ENV") or "")' },
                { stdout = out })
            ok(e ~= nil, 'spawn after setenv')
            is(0, (e:wait(10000)), 'setenv child exits 0')
            is('inherited', read(out), 'spawn inherits setenv')

            local q = sys.spawn({ lua, '-e', 'io.write(io.read("l"))' },
                                { stdin = 'pipe', stdout = out })
            ok(q ~= nil, 'spawn with stdin pipe')
            q:write('piped\n')
            q:close_stdin()
            is(0, (q:wait(10000)), 'stdin-pipe process exits 0')
            is('piped', read(out), 'stdin pipe carried the data')

            local r = sys.spawn({ lua, '-e', 'while true do end' })
            ok(r ~= nil and r:alive(), 'alive() sees a running process')
            r:kill()
            r:wait(10000)
            ok(not r:alive(), 'alive() sees the killed process as gone')
        end
        for _, file in ipairs({ src, dst, out, errFile }) do os.remove(file) end
    end
end

-- a number (or a numeric string) read through substr/num as Perl does it
-- (expectations from perl: substr(1234,1,2), "inf"+0, "-INF"+0, "nan"+0,
--  " Infinity"+0, "info"+0)
is('23', perl.substr(1234, 1, 2), 'substr reads a number through its string form')
is(math.huge, perl.num('inf'), 'num of "inf" is Inf')
is(-math.huge, perl.num('-INF'), 'num of "-INF" is -Inf')
local nan = perl.num('nan')
ok(nan ~= nan, 'num of "nan" is NaN')
is(math.huge, perl.num(' Infinity'), 'num of " Infinity" is Inf')
is(math.huge, perl.num('info'), 'num of "info" is Inf (leading "inf")')
is(0, perl.num('undef'), 'num of "undef" is 0')

-- Perl's `use warnings` for numification: an operator-tagged perl.num and
-- perl.sprintf/perl.int warn through $SIG{'__WARN__'} with Perl's wording
-- (expectations from `LC_ALL=C perl -we '...'`, " at -e line 1." cut off)
do
    local got
    local oldWarn = perl.SIG.__WARN__
    perl.SIG.__WARN__ = function(msg) got = msg end
    local function warnOf(f)
        got = nil
        f()
        return got and (got:gsub(' at %(eval%) line 1%.\n$', ''))
    end
    is('Argument "undef" isn\'t numeric in division (/)',
       warnOf(function() return perl.num('undef', '/') / 2 end), 'num warns in division (/)')
    is('Argument "2.971 1" isn\'t numeric in addition (+)',
       warnOf(function() return perl.num('2.971 1', '+') end), 'num warns in addition (+)')
    is('Argument "undef" isn\'t numeric in multiplication (*)',
       warnOf(function() return perl.num('undef', '*') end), 'num warns in multiplication (*)')
    is('Argument "a" isn\'t numeric in numeric lt (<)',
       warnOf(function() return perl.num('a', '<') end), 'num warns in numeric lt (<)')
    is('Argument "a" isn\'t numeric in exponentiation (**)',
       warnOf(function() return perl.num('a', '**') end), 'num warns in exponentiation (**)')
    is('Argument "undef" isn\'t numeric in sprintf',
       warnOf(function() return perl.sprintf('%.1f', 'undef') end), 'sprintf warns for %f')
    is('Argument "a" isn\'t numeric in int',
       warnOf(function() return perl.int('a') end), 'int warns')
    is('Argument "M-l\\r\\0" isn\'t numeric in multiplication (*)',
       warnOf(function() return perl.num('\236\r\0', '*') end), 'high bytes and controls shown like Perl')
    is('Argument "' .. ('a'):rep(56) .. '..." isn\'t numeric in addition (+)',
       warnOf(function() return perl.num(('a'):rep(57), '+') end), 'long argument cut after 56 characters')
    is(nil, warnOf(function() return perl.num(' 12 ', '+') end), 'surrounding whitespace is numeric')
    is(nil, warnOf(function() return perl.num('1e5', '+') end), 'exponent is numeric')
    is(nil, warnOf(function() return perl.num('-Inf', '+') end), 'Inf is numeric')
    is(nil, warnOf(function() return perl.num('undef') end), 'num without an operator does not warn')
    is(0, perl.num('0x1A', '+'), 'a hex string numifies to 0')
    perl.SIG.__WARN__ = oldWarn
end

-- tell counts what perl.print wrote where the OS keeps no position (perl:
-- `print "x" x 100; tell STDOUT` is 100 on /dev/null and through a pipe),
-- and is the file position on a plain file
do
    local null = io.open('/dev/null', 'w')
    if null then
        perl.print(null, string.rep('x', 100))
        is(100, perl.tell(null), 'tell on /dev/null counts the printed bytes')
        perl.print(null, string.rep('y', 5000))
        is(5100, perl.tell(null), 'tell on /dev/null after a buffer flush')
        null:close()
    end
    local pipe = io.popen('cat >/dev/null', 'w')
    if pipe then
        perl.print(pipe, 'abc', carray.new('char'):append('de'))
        is(5, perl.tell(pipe), 'tell on a pipe counts the printed bytes')
        pipe:close()
    end
    local name = os.tmpname()
    local fh = io.open(name, 'w+b')
    fh:write('12345')
    perl.print(fh, 'abc')
    is(8, perl.tell(fh), 'tell on a plain file is the file position')
    fh:seek('set', 2)
    is(2, perl.tell(fh), 'tell on a plain file follows a seek')
    fh:close()
    os.remove(name)
end

-- A number as regex subject, and a number an /e replacement function
-- returns, read in their Perl string form (%.15g, '.' whatever the locale;
-- the suite runs under de_DE, where Lua's own conversion gives "1485,6...")
do
    is('1485.64892614286', perl.matches(1485.648926142857, [[((?=\d|\.\d)\d*(?:\.\d*)?)]]),
        'matches: a float subject is stringified like Perl')
    is(true, (perl.isMatch(0.5, [[^0\.5$]])), 'isMatch: a float subject is stringified like Perl')
    is(true, (perl.isMatch(2.0, [[^2$]])), 'isMatch: an integral float subject prints without .0')
    is('1.5 m', perl.subst(1.5, [[$]], ' m'), 'subst: a float subject is stringified like Perl')
    is('x0.25y', perl.subst('x1y', [[\d]], function() return 0.25 end),
        'subst: a float returned by the replacement function is stringified like Perl')
end

-- lc/uc/ucfirst/lcfirst change ASCII letters only and quotemeta escapes
-- every byte outside [A-Za-z0-9_], as Perl without `use locale` -- also under
-- a single-byte locale (de_DE ISO-8859-15, cp1252), where Lua's
-- string.lower/upper and %w take bytes >= 0x80 as letters
do
    is('\226abc', perl.ucfirst('\226abc'), 'ucfirst: a byte >= 0x80 keeps its case')
    is('\196x', perl.lc('\196X'), 'lc: changes ASCII letters only')
    is('\228X', perl.uc('\228x'), 'uc: changes ASCII letters only')
    is('\196Xy', perl.lcfirst('\196Xy'), 'lcfirst: a byte >= 0x80 keeps its case')
    is('Abc', perl.ucfirst('abc'), 'ucfirst: ASCII')
    is('abc\228', perl.lc('ABC\228'), 'lc: ASCII with a high byte')
    is('a\\\226b', perl.quotemeta('a\226b'), 'quotemeta: a byte >= 0x80 is escaped')
end

TestLib.done()
