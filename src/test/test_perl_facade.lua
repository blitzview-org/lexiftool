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
        { [[sub f { 1 } $_ = f()]], 'sub' },
        { [[local $_ = 1]], 'local' },
        { [[$_ = wantarray]], 'wantarray' },
        { [[$_ = $h{a}->()]], 'code reference call ->(...)' },
        { [[$_ = mystery($_)]], 'function mystery()' },
        { [[$_ = \(@a)]], 'reference \\ to a list' },
        { [[$_ = shift]], 'shift without an array' },
        { [[$_ = 1 if 1 .. 2]], 'range operator .. in scalar context (flip-flop)' },
        { [[require Foo::Bar]], 'require' },
        { [[s/a/$&/ee]], 's///ee' },
        -- commands are never run, whichever delimiter qx takes
        { [[$_ = `ls`]], '`command`' },
        { [[$_ = qx(ls)]], 'qx(...) command' },
        { [[$_ = qx{ls}]], 'qx{...} command' },
        { [[$_ = qx/ls/]], 'qx/.../ command' },
        { [[$_ = qx'ls']], "qx'...' command" },
        { [[system("ls")]], 'system' },
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

-- eval: case modifiers, $&, list slices, regex interpolation, sort, reverse,
-- package-qualified functions (results as Perl gives them)
do
    local function ed(code, dollarUnderscore, extra, funcs)
        local vars = { _ = dollarUnderscore }
        for k, val in pairs(extra or {}) do vars[k] = val end
        perl.eval(code, vars, funcs)
        return vars._
    end
    is('Canon Eos Rebel', ed([[s/(\w+)/\u\L$1/g]], 'CANON EOS rebel'), 'eval \\u\\L in a replacement')
    is('aBC dEF', ed([[s/(\w)(\w*)/\l$1\U$2/g]], 'Abc Def'), 'eval \\l and \\U in a replacement')
    is('abc\\.defGH', ed([[$_ = "\LAB\QC.D\EEF\EGH"]], ''), 'eval \\L and \\Q stack, \\E ends the last one')
    is('a\\.b!', ed([[$_ = "\Q$_\E!"]], 'a.b'), 'eval \\Q quotes an interpolated variable')
    is('a[b]c[b]', ed([[s/b/[$&]/g]], 'abcb'), 'eval $& in a replacement')
    is('-a--c-', ed([[s/b*/-/g]], 'abc'), 'eval s///g with empty matches')
    is('2003:12:04', ed([[$_ = (split / /)[0] ]], '2003:12:04 06:46:52'), 'eval list slice of split')
    is('c', ed([[$_ = (split /:/)[-1] ]], 'a:b:c'), 'eval list slice with a negative index')
    is('a,c,d', ed([[$_ = join ",", (split //)[0, 2, -1] ]], 'abcd'), 'eval list slice with several indexes')
    is(4, ed([[$_ = (4, 5, 6)[1, 0] ]], ''), 'eval list slice in scalar context is its last element')
    is(2, ed([[my @r = (1, 2)[1, 5]; $_ = scalar(@r)]], ''), 'eval list slice past the end gives undef elements')
    is(0, ed([[$_ = defined((())[0]) ? 1 : 0]], ''), 'eval slice of an empty list is empty')
    is(1, perl.eval([[$_ =~ /$m/i]], { _ = 'Canon EOS', m = 'eos' }), 'eval variable in a regex')
    is('Canon X', ed([[s/$m/X/i]], 'Canon EOS', { m = 'eos' }), 'eval variable in a s/// pattern')
    is(1, perl.eval([[$info{'Model'} =~ /^$info{'Make'} /]], { info = { Make = 'Canon', Model = 'Canon EOS' } }),
       'eval hash element in a regex')
    is(1, perl.eval([[/a$|b/]], { _ = 'xa' }), 'eval $ before | is the anchor')
    is(1, perl.eval([[/^\Q$x\E$/]], { _ = 'a.b', x = 'a.b' }), 'eval \\Q in a regex')
    is('', perl.eval([[/^\Q$x\E$/]], { _ = 'axb', x = 'a.b' }), 'eval \\Q in a regex quotes the metacharacters')
    is('a|b|c', ed([[$_ = join "|", split /$sep/]], 'a,b,c', { sep = ',' }), 'eval variable in a split pattern')
    is('9,10,100', ed([[$_ = join ",", sort { $a <=> $b } split /,/]], '10,9,100'), 'eval sort with a block')
    is('10,100,9', ed([[$_ = join ",", sort split /,/]], '10,9,100'), 'eval sort in string order')
    is('c,b,A', ed([[$_ = join(",", reverse sort { lc($a) cmp lc($b) } "b", "A", "c")]], ''),
       'eval reverse of a sort')
    is('cba', ed([[$_ = reverse]], 'abc'), 'eval scalar reverse of $_')
    is('dcba', ed([[$_ = reverse "ab", "cd"]], ''), 'eval scalar reverse of a list')
    is('x!', ed([[$_ = Image::ExifTool::Foo($_)]], 'x', nil,
                { ['Image::ExifTool::Foo'] = function(arg) return arg .. "!" end }), 'eval package-qualified function')
    local okEval, err = pcall(perl.eval, [[A::B($_)]], { _ = 'x' })
    is('Undefined subroutine &A::B called at (eval 1) line 1.\n', not okEval and perl.isDie(err) and err.msg,
       'eval missing package function dies like Perl')
end

-- eval: Perl's -w warnings for undef and non-numeric operands
do
    local function warnings(code, vars)
        local got = {}
        local oldWarn = perl.SIG.__WARN__
        perl.SIG.__WARN__ = function(msg) got[#got + 1] = msg end
        pcall(perl.eval, code, vars)
        perl.SIG.__WARN__ = oldWarn
        return table.concat(got)
    end
    local info = { Make = 'Canon' }
    is('Use of uninitialized value $info{"X"} in numeric ne (!=) at (eval 1) line 1.\n',
       warnings([[$info{'X'} != 1]], { info = info }), 'eval warns for an undef hash element')
    is('Argument "Canon" isn\'t numeric in numeric ne (!=) at (eval 1) line 1.\n',
       warnings([[$info{'Make'} != 1]], { info = info }), 'eval warns for a non-numeric string')
    is('Use of uninitialized value $u in pattern match (m//) at (eval 1) line 1.\n',
       warnings([[$u !~ /x/]], {}), 'eval warns for an undef match subject')
    is('Use of uninitialized value $u in string at (eval 1) line 1.\n', warnings([["$u"]], {}),
       'eval warns for an undef string')
    is('Use of uninitialized value $u in concatenation (.) or string at (eval 1) line 1.\n',
       warnings([["a$u"]], {}), 'eval warns for an undef interpolated variable')
    is('Use of uninitialized value $v in addition (+) at (eval 1) line 1.\n' ..
       'Use of uninitialized value $u in addition (+) at (eval 1) line 1.\n',
       warnings([[$u + $v]], {}), 'eval numifies the right operand first')
    is('Use of uninitialized value in addition (+) at (eval 1) line 1.\n',
       warnings([[$$self{X} + 1]], { self = {} }), 'eval does not name an element through a reference')
    is('Use of uninitialized value $u in regexp compilation at (eval 1) line 1.\n',
       warnings([[$_ =~ /a$u/]], { _ = 'a' }), 'eval warns for an undef variable in a regex')
    is('', warnings([[my $r = defined $u || !$u; my $q; $q .= "x"; my $p; $p += 1]], {}),
       'eval boolean context and .= += on undef do not warn')
    is('-foo', perl.eval([[-$_]], { _ = 'foo' }), 'eval negates a non-numeric string as a string')
    is('substr outside of string at (eval 1) line 1.\n', warnings([[$_ = substr($_, 4)]], { _ = 'abc' }),
       'eval warns for substr beyond the end')
    is('Use of uninitialized value $u in substitution (s///) at (eval 1) line 1.\n',
       warnings([[s/a/$u/e]], { _ = 'a' }), 'eval s///e names a plain variable as s/// does')
    is('Use of uninitialized value in substitution iterator at (eval 1) line 1.\n',
       warnings([[s/a/undef/e]], { _ = 'a' }), 'eval s///e with other code warns in the iterator')
    is('Integer overflow in srand at (eval 1) line 1.\n', warnings([[srand("abc")]], {}),
       'eval srand of a non-number')
end

-- eval: Perl's compile-time "Useless use of ... in void context" (texts
-- and order as perl -w gives them)
do
    local function warnings(code, vars, opts)
        local got = {}
        local oldWarn = perl.SIG.__WARN__
        perl.SIG.__WARN__ = function(msg) got[#got + 1] = msg end
        local okEval, err = pcall(perl.eval, code, vars or {}, { f = function() end }, nil, opts)
        perl.SIG.__WARN__ = oldWarn
        if not okEval then got[#got + 1] = 'DIE: ' .. (perl.isDie(err) and err.msg or tostring(err)) end
        return table.concat(got)
    end
    local function void(what) return 'Useless use of ' .. what .. ' in void context at (eval 1) line 1.\n' end
    local info = { info = { Model = 'X', Make = 'Canon' } }
    is(void('hash element'), warnings([[$info{Model}; $info{Make} eq "Canon"]], info),
       'eval void: a hash element')
    is(void('hash element'), warnings([[$info{Model}, $info{Make} eq "Canon"]], info),
       'eval void: the left operand of a comma in scalar context')
    is('', warnings([[$info{Model}, $info{Make} eq "Canon"]], info, { void = true }),
       'eval void: nothing for the last statement of a void-context eval')
    is('', warnings([[$info{Model}]], info), 'eval void: nothing for the last statement')
    is(void('private variable') .. void('a variable') .. void('private array') .. void('private hash'),
       warnings([[$v; $_; @a; %h; 1]], { v = 1 }), 'eval void: variables, `my` and package ones')
    is(void('a variable'), warnings([[$g; 1]], {}, { globals = { g = true } }), 'eval void: a caller\'s package variable')
    is(void('a constant ("abc")') .. void('a constant (5)') .. void('a constant ("1")') .. void('a constant (0.5)'),
       warnings([["abc"; 5; "1"; 0.5; 0; 1; 1]]), 'eval void: constants, 0 and 1 exempt')
    is(void('a constant ("a\\"b\\\\c\\n\\t\\1x\\0015\\377")'), warnings([["a\"b\\c\n\t\x01x\x015\xff"; 1]]),
       'eval void: a constant string escaped as pv_pretty does')
    is(void('a constant ("abcdefghijklmnopqrstuvwxyz012345"...)'),
       warnings([["abcdefghijklmnopqrstuvwxyz0123456789"; 1]]), 'eval void: a long constant is cut at 32 characters')
    is(void('a constant (3)') .. void('a constant ("AB")') .. void('a constant ("+foo")') .. void('a constant (-1)'),
       warnings([[1 + 2; uc "a" . "b"; -"-foo"; 1 <=> 2; 1 == 2; !1; 1]]),
       'eval void: constant folding, comparisons exempt')
    is(void('addition (+)') .. 'Argument "abc" isn\'t numeric in addition (+) at (eval 1) line 1.\n',
       warnings([["abc" + 1; 1]]), 'eval void: no folding when it warns, compile time before run time')
    is(void('numeric eq (==)') .. void('string eq') .. void('concatenation (.) or string') .. void('not') ..
       void('negation (-)') .. void('repeat (x)') .. void('logical xor'),
       warnings([[$v == 1; $v eq 1; $v . 1; !$v; -$v; $v x 2; $v xor 1; 1]], { v = 1 }), 'eval void: operators')
    is(void('lc') .. void('defined operator') .. void('join or string') .. void('sprintf') .. void('split') ..
       void('sort') .. void('reverse') .. void('list slice') .. void('array element') ..
       void('single ref constructor') .. void('negative pattern binding (!~)') ..
       void('non-destructive substitution (s///r)'),
       warnings([[lc $v; defined $v; join ",", @a; sprintf("%s", $v); split /,/; sort @a; reverse @a; (1, 2)[0];
                  $a[0]; \$v; $v !~ /a/; s/a/b/r; 1]], { v = 'a', a = { 'x' }, _ = 'a' }), 'eval void: builtins and terms')
    is(void('string') .. void('join or string') .. void('uc'), warnings([["a$v"; "@a"; "\U$v"; 1]], { v = 'a', a = { 'x' } }),
       'eval void: interpolated strings')
    is('', warnings([[f(); $v = 1; $v =~ /a/; s/a/b/; $v++; my $w; undef; scalar($v); rand; push @a, 1;
                      map { $_ } @a; 1 if $v; $v || 0; 1]], { v = 'a', a = { 'x' }, _ = 'a' }),
       'eval void: no warning for side effects and the exempt constants')
    is(void('a variable') .. void('a constant ("z")') .. void('a constant (3)'),
       warnings([[$v && $_; $v || "z"; $v ? 1 : 3; 0 || "q"; 1 && "q"; 1]], { v = 1 }),
       'eval void: the right operand of && ||, the branches of ?:, folded short-circuits exempt')
    is(void('a variable'), warnings([[$_ if 1; "a" if 1; $_ if 0; if (0) { $_ } 1]]),
       'eval void: nothing for code a literal condition makes unreachable or folds')
    is(void('hash element') .. void('a variable'), warnings([[$_; if ($v) { $info{Make}; 1 } 1]], { v = 1, info = {} }),
       'eval void: a block warns when it is closed, the code at the end')
    local got = warnings([[{ $info{Make}; 1 } )]], { info = {} })
    is(void('hash element') .. 'DIE: syntax error', got:sub(1, #void('hash element') + 17),
       'eval void: a closed block warns before a syntax error')
end

-- eval: substr bounds, rand/srand, map/grep, keys/values, s///e, references,
-- the caller's $1, arguments assigned through perl.setArg
do
    local function ev(code, vars, funcs, outer)
        local oldWarn = perl.SIG.__WARN__
        perl.SIG.__WARN__ = function() end
        local okEval, r = pcall(perl.eval, code, vars or {}, funcs, outer)
        perl.SIG.__WARN__ = oldWarn
        if not okEval then error(r, 0) end
        return r
    end
    -- (substr as Perl_translate_substr_offsets decides: 'U' for undef)
    local grid = {
        { 'abc', -5, nil, 'abc' }, { 'abc', -5, -1, 'ab' }, { 'abc', -5, 1, 'U' }, { 'abc', -5, 5, 'abc' },
        { 'abc', -4, 1, '' }, { 'abc', -3, -5, '' }, { 'abc', -1, nil, 'c' }, { 'abc', 3, nil, '' },
        { 'abc', 4, nil, 'U' }, { 'abc', 2, 5, 'c' }, { '', -1, 1, '' }, { '', -1, 0, 'U' }, { '', 0, nil, '' },
        { '', 2, nil, 'U' }, { '', -5, 5, '' }, { '', -1, -1, 'U' },
    }
    for _, g in ipairs(grid) do
        local code = g[3] and ('substr($s, ' .. g[2] .. ', ' .. g[3] .. ')') or ('substr($s, ' .. g[2] .. ')')
        local r = ev('my $r = ' .. code .. '; defined $r ? $r : "U"', { s = g[1] })
        is(g[4], r, 'eval ' .. code .. ' of "' .. g[1] .. '"')
    end
    is('74 0.342701478718908', ev([[srand(42); int(rand(100)) . ' ' . rand()]]), 'eval rand after srand is Perl\'s sequence')
    is('0 but true', ev([[srand(0)]]), 'eval srand(0)')
    is(1, ev([[srand(-1.5)]]), 'eval srand drops the sign and the fraction')
    is('2,4,6', ev([[my @a = (1, 2, 3); join ',', map { $_ * 2 } @a]]), 'eval map BLOCK')
    is(6, ev([[my @a = (1, 2, 3); scalar(map { ($_, $_) } @a)]]), 'eval map in scalar context')
    is('a,b', ev([[join ',', map lc, 'A', 'B']]), 'eval map EXPR, LIST')
    is('bb', ev([[join ',', grep { length > 1 } 'a', 'bb', 'c']]), 'eval grep BLOCK')
    is('bb', ev([[join ',', grep /b/, 'a', 'bb', 'c']]), 'eval grep EXPR, LIST')
    is('a,xb,c', ev([[my @a = ('a', 'bb', 'c'); map { s/b/x/ } @a; join ',', @a]]), 'eval map aliases $_ to the elements')
    is('keep', ev([[$_ = 'keep'; map { 1 } (1, 2); $_]]), 'eval map restores $_')
    is('a2b44', ev([[$_ = 'a1b22'; s/(\d+)/$1*2/ge; $_]]), 'eval s///ge')
    is('aB!c', ev([[$_ = 'abc'; s/b/uc($&) . "!"/e; $_]]), 'eval s///e with $&')
    is('a,b', ev([[join ',', sort keys %h]], { h = { b = 1, a = 2 } }), 'eval keys')
    is('2,1', ev([[join ',', values %h]], { h = { b = 1, a = 2 } }), 'eval values in key order')
    is(3, ev([[scalar(keys %$h)]], { h = { b = 1, a = 2, c = 3 } }), 'eval keys of a dereferenced hash')
    is('a,2,b,1', ev([[join ',', %h]], { h = { b = 1, a = 2 } }), 'eval a hash in list context')
    is(1, ev([["" . \$y =~ /^SCALAR\(0x[0-9a-f]+\)$/ ? 1 : 0]]), 'eval reference stringifies as Perl')
    is('m/(\\d{4|;m/(\\d{4}', ev([[/(\d{5})/; "$1|$&"]], { _ = 'x' }, nil, { 'm/(\\d{4', amp = ';m/(\\d{4}' }),
       'eval sees the caller\'s $1 and $& until it matches')
    local funcs = { Bump = function(arg) perl.setArg(0, arg .. '!') return 1 end }
    is('x!', ev([[my $t = 'x'; Bump($t); $t]], {}, funcs), 'eval perl.setArg assigns to the argument variable')
    local okEval, err = pcall(perl.eval, [[Bump('x')]], {}, funcs)
    is('Modification of a read-only value attempted at (eval 1) line 1.\n', not okEval and perl.isDie(err) and err.msg,
       'eval perl.setArg on a constant dies like Perl')
end

-- eval: return, the loops (foreach with aliasing, C-style for, while/until,
-- the statement modifiers, next/last with labels), references and
-- dereferencing (autovivification, Perl's strict-refs errors), anonymous
-- arrays and hashes, ref, my %h, exists/delete/each, shift/pop/splice,
-- slices, ranges, list repetition, qw, chomp/chop, die/warn, the
-- interpolation of element expressions.  Each expected result -- the value
-- (dumped: undef, 'string', [list], {key=>value}, \scalar), $@ and the
-- warnings -- is what `perl -w` gave for the code under `use strict`, run by
-- `eval` with $_ set to the first field
do
    local function dump(val)
        if val == nil then return 'undef' end
        local r = perl.ref(val)
        if r == '' then return "'" .. perl.str(val) .. "'" end
        if r == 'ARRAY' then
            local t = {}
            for i = 1, #val do t[i] = dump(val[i]) end
            return '[' .. table.concat(t, ',') .. ']'
        end
        if r == 'HASH' then
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = perl.str(k) end
            local t = {}
            for i, k in ipairs(perl.sort(keys, perl.cmp)) do t[i] = k .. '=>' .. dump(val[k]) end
            return '{' .. table.concat(t, ',') .. '}'
        end
        if r == 'SCALAR' then return '\\' .. dump(val.value) end
        return '<' .. r .. '>'
    end
    local function esc(str) return (str:gsub('\n', '\\n')) end
    for _, case in ipairs({
        { [[x]], [[return 4; 5]],
          [['4']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2); return @a]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[return (7,8,9)]],
          [['9']],
          [[]],
          [[]] },
        { [[x]], [[return]],
          [[undef]],
          [[]],
          [[]] },
        { [[x]], [[my $x = 1 or return undef; 2]],
          [['2']],
          [[]],
          [[Found = in conditional, should be == at (eval 1) line 1.\n]] },
        { [[x]], [[return $_ if /x/; 3]],
          [['x']],
          [[]],
          [[]] },
        { [[y]], [[return $_ if /x/; 3]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[return unless /y/; 3]],
          [[undef]],
          [[]],
          [[]] },
        { [[x]], [[my $s = 0; for my $i (1..4) { $s += $i } $s]],
          [['10']],
          [[]],
          [[]] },
        { [[x]], [[my $s = ''; foreach my $c ('a','b','c') { $s .= $c } $s]],
          [['abc']],
          [[]],
          [[]] },
        { [[x]], [[my $s = 0; for (my $i=0; $i<5; ++$i) { $s += $i } $s]],
          [['10']],
          [[]],
          [[]] },
        { [[x]], [[my ($i, $s); for ($i=10; $i>0; $i-=3) { $s .= $i } $s]],
          [['10741']],
          [[]],
          [[]] },
        { [[x]], [[my $n = 0; while ($n < 3) { $n++ } $n]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $n = 5; until ($n <= 2) { $n-- } $n]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); for my $x (@a) { $x *= 2 } "@a"]],
          [['2 4 6']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); $_ *= 3 for @a; "@a"]],
          [['3 6 9']],
          [[]],
          [[]] },
        { [[x]], [[my @a=('a1','b2'); s/\d// foreach @a; "@a"]],
          [['a b']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1..5); my $s = 0; for (@a) { next if $_ == 2; last if $_ == 4; $s += $_ } $s]],
          [['4']],
          [[]],
          [[]] },
        { [[x]], [[my $s = 0; OUTER: for my $i (1..3) { for my $j (1..3) { next OUTER if $j == 2; $s += $j } } $s]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $s = 0; OUTER: for my $i (1..3) { for my $j (1..3) { last OUTER if $i == 2; $s += 10*$i+$j } } $s]],
          [['36']],
          [[]],
          [[]] },
        { [[x]], [[for (1..3) {}]],
          [['']],
          [[]],
          [[]] },
        { [[x]], [[my $x = 5; while ($x > 3) { $x-- }]],
          [['']],
          [[]],
          [[]] },
        { [[x]], [[my $x = 2; while ($x) { $x-- }]],
          [['0']],
          [[]],
          [[]] },
        { [[x]], [[for (1,2) { last }]],
          [[undef]],
          [[]],
          [[]] },
        { [[x]], [[my $x=0; $x++ while $x < 4; $x]],
          [['4']],
          [[]],
          [[]] },
        { [[x]], [[my $i=0; do { $i++ } until $i >= 3; $i]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $i=10; do { $i++ } while $i < 3; $i]],
          [['11']],
          [[]],
          [[]] },
        { [[x]], [[my $v; for (@{[1,'',3]}) { if ($_ eq '') { $v = 'empty'; last } } $v]],
          [['empty']],
          [[]],
          [[]] },
        { [[x]], [[last;]],
          [[undef]],
          [[Can't "last" outside a loop block at (eval 1) line 1.\n]],
          [[Exiting eval via last at (eval 1) line 1.\n]] },
        { [[x]], [[for (1) { last FOO }]],
          [[undef]],
          [[Label not found for "last FOO" at (eval 1) line 1.\n]],
          [[Exiting eval via last at (eval 1) line 1.\n]] },
        { [[x]], [[{ 5; last; 6 }]],
          [[undef]],
          [[]],
          [[Useless use of a constant (5) in void context at (eval 1) line 1.\n]] },
        { [[x]], [[my $x = 1; { $x = 2; next; $x = 3 } $x]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[for my $i (1,2) { $i = 5 }]],
          [[undef]],
          [[Modification of a read-only value attempted at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my $x="a"; for ($x) { s/a/b/ } $x]],
          [['b']],
          [[]],
          [[]] },
        { [[x]], [[my %h=(a=>1,b=>2); for (values %h) { $_ *= 10 } join ",", map {"$_=$h{$_}"} sort keys %h]],
          [['a=10,b=20']],
          [[]],
          [[]] },
        { [[x]], [[my ($a1,$b1) = ('x','y'); s/./Z/ for $a1, $b1; "$a1$b1"]],
          [['ZZ']],
          [[]],
          [[]] },
        { [[x]], [[my @r; for my $i (0..2) { push @r, $i*2 } "@r"]],
          [['0 2 4']],
          [[]],
          [[]] },
        { [[x]], [[my $c = 0; $c++ for 1..3; $c]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [1,2,3]; "$$r[1] $r->[2] ${$r}[0] @$r @{$r} $#$r $#{$r}"]],
          [['2 3 1 1 2 3 1 2 3 2 2']],
          [[]],
          [[]] },
        { [[x]], [[my $h = {a=>{b=>[5,6]}}; "$h->{a}{b}[1] $$h{a}{b}->[0]"]],
          [['6 5']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [1,[2,3],{x=>4}]; $r->[1][0] + $r->[2]{x}]],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2); my $r = \@a; push @$r, 3; "@a"]],
          [['1 2 3']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a=>1); my $r = \%h; $r->{b} = 2; join ",", sort keys %h]],
          [['a,b']],
          [[]],
          [[]] },
        { [[x]], [[my $x = 5; my $r = \$x; $$r = 6; $x]],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my $x = 5; my $r = \$x; $x = 7; $$r]],
          [['7']],
          [[]],
          [[]] },
        { [[x]], [[ref([])]],
          [['ARRAY']],
          [[]],
          [[]] },
        { [[x]], [[ref({})]],
          [['HASH']],
          [[]],
          [[]] },
        { [[x]], [[ref(\1)]],
          [['SCALAR']],
          [[]],
          [[]] },
        { [[x]], [[ref(5)]],
          [['']],
          [[]],
          [[]] },
        { [[x]], [[my @a; ref(\@a)]],
          [['ARRAY']],
          [[]],
          [[]] },
        { [[x]], [[my $x; push @$x, 1; ref($x)]],
          [['ARRAY']],
          [[]],
          [[]] },
        { [[x]], [[my $x; $x->{a}{b} = 1; ref($x->{a})]],
          [['HASH']],
          [[]],
          [[]] },
        { [[x]], [[my $x; my $y = $x->{a}; ref($x)]],
          [['HASH']],
          [[]],
          [[]] },
        { [[x]], [[my $x; my @y = @$x; 1]],
          [[undef]],
          [[Can't use an undefined value as an ARRAY reference at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my $x = "abc"; $x->{a}]],
          [[undef]],
          [[Can't use string ("abc") as a HASH ref while "strict refs" in use at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my $x = [1]; $x->{a}]],
          [[undef]],
          [[Not a HASH reference at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [==[my $x = {}; $$x[0]]==],
          [[undef]],
          [[Not an ARRAY reference at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my $x; $$x]],
          [[undef]],
          [[Can't use an undefined value as a SCALAR reference at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my $x = 3; $$x]],
          [[undef]],
          [[Can't use string ("3") as a SCALAR ref while "strict refs" in use at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my $x = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"; $x->{a}]],
          [[undef]],
          [[Can't use string ("abcdefghijklmnopqrstuvwxyzABCDEF"...) as a HASH ref while "strict refs" in use]] ..
          [[ at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[my @a; push @{$a[2]}, 1; scalar(@a)]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my %h; $h{a}{b} = 1; join ",", keys %h]],
          [['a']],
          [[]],
          [[]] },
        { [[x]], [[my $r = {a=>1,b=>2}; join ",", sort keys %$r]],
          [['a,b']],
          [[]],
          [[]] },
        { [[x]], [[my $r = {a=>1,b=>2}; my %c = %$r; join ",", map {"$_$c{$_}"} sort keys %c]],
          [['a1,b2']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [3,1,2]; join ",", sort { $a <=> $b } @$r]],
          [['1,2,3']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [3,1,2]; join ",", map { $_ * 2 } @{$r}]],
          [['6,2,4']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [3,1,2]; scalar(@$r)]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [3,1,2]; scalar(grep { $_ > 1 } @$r)]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my @list = ref $_ eq 'ARRAY' ? @$_ : ($_); scalar(@list)]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my $r = { list => [1,2] }; push @{$r->{list}}, 3; "@{$r->{list}}"]],
          [['1 2 3']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [ [1,2], [3,4] ]; my $s = 0; for my $row (@$r) { $s += $_ for @$row } $s]],
          [['10']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (x => [1,2], y => { z => 'q' }); "$h{x}[1] $h{y}{z}"]],
          [['2 q']],
          [[]],
          [[]] },
        { [[x]], [[{ a => 1, b => 2 }->{b}]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [==[[5,6,7]->[1]]==],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my $h = { gpsdatetime => 2, createdate => 6 }->{lc 'CreateDate'}; $h]],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a=>1, b=>2); join ",", map { "$_=$h{$_}" } sort keys %h]],
          [['a=1,b=2']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a=>1, b=>2); scalar(keys %h)]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a=>1); exists $h{a} ? 1 : 0]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a=>1); exists $h{b} ? 1 : 0]],
          [['0']],
          [[]],
          [[]] },
        { [[x]], [[my %h=(a=>1); my $v = delete $h{a}; "$v ". scalar(keys %h)]],
          [['1 0']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); delete $a[2]; scalar(@a)]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); exists $a[1] ? 1 : 0]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); exists $a[5] ? 1 : 0]],
          [['0']],
          [[]],
          [[]] },
        { [[x]], [[my $x; exists $x->{a}{b}; ref($x->{a})]],
          [['HASH']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); my $x = shift @a; "$x @a"]],
          [['1 2 3']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); my $x = pop @a; "$x @a"]],
          [['3 1 2']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2,3); unshift @a, 0, -1; "@a"]],
          [['0 -1 1 2 3']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1..5); my @r = splice(@a, 1, 2); "@r|@a"]],
          [['2 3|1 4 5']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1..5); splice(@a, 1, 2, 'x', 'y', 'z'); "@a"]],
          [['1 x y z 4 5']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1..5); my $r = splice(@a, -2); "$r|@a"]],
          [['5|1 2 3']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1..5); "@a[1,2] @a[-1]"]],
          [['2 3 5']],
          [[]],
          [[Scalar value @a[-1] better written as $a[-1] at (eval 1) line 1.\n]] },
        { [[x]], [[my %h = (a=>1,b=>2,c=>3); my @v = @h{'a','c'}; "@v"]],
          [['1 3']],
          [[]],
          [[]] },
        { [[x]], [[my $r = {X=>1,Y=>2,W=>3,H=>4}; my @rect = @{$r}{'X','Y','W','H'}; "@rect"]],
          [['1 2 3 4']],
          [[]],
          [[]] },
        { [[x]], [[my $r = {X=>1,Y=>2,W=>3,H=>4}; my @rect = @$r{qw(X Y)}; "@rect"]],
          [['1 2']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (0) x 3; "@a"]],
          [['0 0 0']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2) x 2; scalar(@a)]],
          [['4']],
          [[]],
          [[]] },
        { [[x]], [[my @a = qw(a b c) x 2; "@a"]],
          [['a b c a b c']],
          [[]],
          [[]] },
        { [[x]], [[my $x = "ab" x 2.7]],
          [['abab']],
          [[]],
          [[]] },
        { [[x]], [[my @l = ("a".."e"); "@l"]],
          [['a b c d e']],
          [[]],
          [[]] },
        { [[x]], [[my @l = (1.5..4); "@l"]],
          [['1 2 3 4']],
          [[]],
          [[]] },
        { [[x]], [[my @l = ("08".."11"); "@l"]],
          [['08 09 10 11']],
          [[]],
          [[]] },
        { [[x]], [[my @l = ("aa".."ad"); "@l"]],
          [['aa ab ac ad']],
          [[]],
          [[]] },
        { [[x]], [[my @l = ("x".."ab"); "@l"]],
          [['x y z aa ab']],
          [[]],
          [[]] },
        { [[x]], [[my @l = (3..1); scalar(@l)]],
          [['0']],
          [[]],
          [[]] },
        { [[x]], [[my @l = qw(a b c); "$l[1] $#l"]],
          [['b 2']],
          [[]],
          [[]] },
        { [[x]], [[my $s = "abc\n"; chomp $s; $s]],
          [['abc']],
          [[]],
          [[]] },
        { [[x]], [[my $s = "abc\n"; my $n = chomp($s); "$n$s"]],
          [['1abc']],
          [[]],
          [[]] },
        { [[x]], [[chomp; $_]],
          [['x']],
          [[]],
          [[]] },
        { [[x]], [[my $s = "abc"; chop $s; $s]],
          [['ab']],
          [[]],
          [[]] },
        { [[x]], [[my $s = "abc"; my $c = chop($s); "$c"]],
          [['c']],
          [[]],
          [[]] },
        { [[x]], [[die "oops\n"]],
          [[undef]],
          [[oops\n]],
          [[]] },
        { [[x]], [[die "oops"]],
          [[undef]],
          [[oops at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[die]],
          [[undef]],
          [[Died at (eval 1) line 1.\n]],
          [[]] },
        { [[x]], [[warn "w1\n"; 5]],
          [['5']],
          [[]],
          [[w1\n]] },
        { [[x]], [[warn "w2"; 5]],
          [['5']],
          [[]],
          [[w2 at (eval 1) line 1.\n]] },
        { [[x]], [[sprintf("%vd", "1.22.333")]],
          [['49.46.50.50.46.51.51.51']],
          [[]],
          [[]] },
        { [[x]], [[sprintf("%d-%s", 3, "x")]],
          [['3-x']],
          [[]],
          [[]] },
        { [[x]], [[my @t = (5, 1); sprintf("%s:%s", @t)]],
          [['5:1']],
          [[]],
          [[]] },
        { [[x]], [[my ($a1, $b1) = (1, 2); ($a1, $b1) = ($b1, $a1); "$a1$b1"]],
          [['21']],
          [[]],
          [[]] },
        { [[x]], [[my @r = (1,2,3,4); ($r[2], $r[3]) = ($r[3], $r[2]); "@r"]],
          [['1 2 4 3']],
          [[]],
          [[]] },
        { [[x]], [[my @d = (5, -3); $d[1] < 0 and $d[1] += 12, --$d[0]; "@d"]],
          [['4 9']],
          [[]],
          [[]] },
        { [[x]], [[my %h; $h{x}++; $h{x} += 2; $h{y} .= "a"; "$h{x}$h{y}"]],
          [['3a']],
          [[]],
          [[]] },
        { [[x]], [[my $r = {}; $r->{n}++; $r->{n} *= 5; $r->{n}]],
          [['5']],
          [[]],
          [[]] },
        { [[x]], [==[my @a = (3); $a[0]++; $a[0] **= 2; $a[0]]==],
          [['16']],
          [[]],
          [[]] },
        { [[x]], [[my $x = "aa9"; $x++; $x]],
          [['ab0']],
          [[]],
          [[]] },
        { [[x]], [[my $x = "Az"; $x++; $x]],
          [['Ba']],
          [[]],
          [[]] },
        { [[x]], [[my @w = ("abc" =~ /(\w)/g); scalar(@w)]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $bday = "1990:01:02 03:04:05+02:00"; ($bday) =~ s/[-+].*//; $bday]],
          [['1990:01:02 03:04:05']],
          [[]],
          [[]] },
        { [[x]], [[my $b; ($b = "2020-01-01+05") =~ s/[-+]\d+$//; $b]],
          [['2020-01-01']],
          [[]],
          [[]] },
        { [[x]], [[(my $t = "a.b.c") =~ tr/./_/; $t]],
          [['a_b_c']],
          [[]],
          [[]] },
        { [[x]], [[my @t0 = ("2020:01:02" =~ /\d+/g); "@t0"]],
          [['2020 01 02']],
          [[]],
          [[]] },
        { [[x]], [[my $base = \@{[7,8]}; "$$base[1]"]],
          [['8']],
          [[]],
          [[]] },
        { [[x]], [[my @t1 = (1,2); my @t0 = (3,4); my $base = 1 < 0 ? \@t1 : \@t0; "$$base[0]"]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my @diff = (1,2,3); my $s = "a1b2c3"; $s =~ s/\d+/sprintf '%.2d', shift @diff/ge; $s]],
          [['a01b02c03']],
          [[]],
          [[]] },
        { [[x]], [[my $fmt = "%s/%s"; my $val = "12 34"; sprintf($fmt, $val =~ /\d+/g)]],
          [['12/34']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2,3); "$#a"]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2,3); $#a = 0; scalar(@a)]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [1,2,3]; "@$r[0,1]"]],
          [['1 2']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (k => 'v'); "$h{k} $h{'k'} @{[ scalar(keys %h) ]}"]],
          [['v v 1']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2,3); my $i = 1; "$a[$i] $a[$i+1] $a[-1]"]],
          [['2 3 3']],
          [[]],
          [[]] },
        { [[x]], [[my $h = {a=>{b=>'c'}}; "x$h->{a}{b}y"]],
          [['xcy']],
          [[]],
          [[]] },
        { [[x]], [[my @a = map { { name => $_ } } qw(a b); $a[1]{name}]],
          [['b']],
          [[]],
          [[]] },
        { [[x]], [[my @a = map { +{ name => $_ } } qw(a b); $a[1]{name}]],
          [['b']],
          [[]],
          [[]] },
        { [[x]], [[my @s = sort { $a->{n} <=> $b->{n} } ({n=>2},{n=>1}); $s[0]{n}]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my @k = grep { defined } (1, undef, 2); scalar(@k)]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my $str = join ",", map { sprintf "%02d", $_ } (1..3); $str]],
          [['01,02,03']],
          [[]],
          [[]] },
        { [[x]], [[my $x = { list => [ { a => 1 }, { a => 2 } ] }; my $s = 0; $s += $_->{a} foreach @{$x->{list}}; $s]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (); $h{$_}++ for qw(a b a); join ",", map { "$_$h{$_}" } sort keys %h]],
          [['a2,b1']],
          [[]],
          [[]] },
        { [[x]], [[my $r = \my @a; push @$r, 5; "@a"]],
          [['5']],
          [[]],
          [[]] },
        { [[x]], [[my %seen; my @u = grep { !$seen{$_}++ } qw(a b a c b); "@u"]],
          [['a b c']],
          [[]],
          [[]] },
        { [[x]], [[my ($x, $y) = (10, 3); my @r = ($x % $y, int($x / $y)); "@r"]],
          [['1 3']],
          [[]],
          [[]] },
        { [[x]], [[scalar(localtime(0)) =~ /^\w{3} \w{3} [ \d]\d \d\d:\d\d:\d\d 1970$/ ? 1 : 0]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my @t = gmtime(86400*365); "$t[5] $t[4] $t[3]"]],
          [['71 0 1']],
          [[]],
          [[]] },
        { [[x]], [[unpack("N", "\0\0\1\2")]],
          [['258']],
          [[]],
          [[]] },
        { [[x]], [[my @v = unpack("nn", "\0\1\0\2"); "@v"]],
          [['1 2']],
          [[]],
          [[]] },
        { [[x]], [[my $x = pack("N", 258); length($x)]],
          [['4']],
          [[]],
          [[]] },
        { [[x]], [[ref \my %h]],
          [['HASH']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2,3); my @b = reverse @a; "@b"]],
          [['3 2 1']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1,2,3); my $last = $a[$#a]; $last]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a=>1); my %g = (%h, b=>2); join ",", sort keys %g]],
          [['a,b']],
          [[]],
          [[]] },
        { [[x]], [[my $s = 0; my @a = (1,2,3); while (my $x = shift @a) { $s += $x } $s]],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my @l = (1,2,3); my ($first, @rest) = @l; "$first|@rest"]],
          [['1|2 3']],
          [[]],
          [[]] },
        { [[x]], [[my ($p, $q) = split /,/, "a,b"; "$q$p"]],
          [['ba']],
          [[]],
          [[]] },
        { [[x]], [[my $h = {}; keys %$h; ref $h]],
          [['HASH']],
          [[]],
          [[]] },
        { [[x]], [[my $a1 = [1,2]; my @c = @$a1; push @c, 3; scalar(@$a1)]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my $x = 'str'; my $r = \$x; ref $r]],
          [['SCALAR']],
          [[]],
          [[]] },
        { [[x]], [[my $v; my $r = \$v; $$r = 5; $v]],
          [['5']],
          [[]],
          [[]] },
        { [[x]], [[my $n = () = "aXbXc" =~ /X/g; $n]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my @val = (undef, '1998:05:01 21:33:18', ''); my $v; for (@val){ if (defined $_ && $_ ne "" && $_]] ..
          [[ !~ /^0000/){ $v = $_; last } } $v]],
          [['1998:05:01 21:33:18']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a => 1); my $r = \$h{a}; $$r = 5; $h{a}]],
          [['5']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1, 2); my $r = \$a[1]; $$r .= 'x'; "@a"]],
          [['1 2x']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (s => 'Ab'); \$h{s} =~ /ab/i ? 1 : 0]],
          [['0']],
          [[]],
          [[]] },
        { [[x]], [==[my $x = [1]; my $r = \$$x[0]; $$r = 9; $x->[0]]==],
          [['9']],
          [[]],
          [[]] },
        { [[x]], [[my @val = ('a', undef, 'c'); my $s = ''; for my $v (@val) { next unless defined $v; $s .= $v } $s]],
          [['ac']],
          [[]],
          [[]] },
        { [[x]], [[my @val = ('1998:05:01', '2000-01-01 10:00:00+01:00'); my $oldest; for my $date (@val) { next if]] ..
          [[ not defined $date or $date lt '1970:01:02'; $date =~ s/([+-]\d{2}:\d{2}$)|([A-Z]{3}$)|([Z]$)//;]] ..
          [[ $date =~ s/-/:/g; if ($date && (!$oldest || $date lt $oldest)) { $oldest = $date } } return]] ..
          [[ $oldest;]],
          [['1998:05:01']],
          [[]],
          [[]] },
        { [[x]], [[my $val = ['a_x.pdf', 'b']; my @list = ref $val eq 'ARRAY' ? @$val : ($val); s/_\w+\.pdf//i foreach]] ..
          [[ @list; return \@list;]],
          [==[['a','b']]==],
          [[]],
          [[]] },
        { [[x]], [[my $val = 'c_y.PDF'; my @list = ref $val eq 'ARRAY' ? @$val : ($val); s/_\w+\.pdf//i foreach @list;]] ..
          [[ return \@list;]],
          [==[['c']]==],
          [[]],
          [[]] },
        { [[x]], [[my @val = (undef, undef, undef, undef, undef, undef, '-5 3'); if (defined $val[6]) { my $tzh =]] ..
          [[ $val[6]; $tzh =~ s/ .*//; return sprintf('%+d', $tzh * 60); } return undef;]],
          [['-300']],
          [[]],
          [[]] },
        { [[x]], [[my @loc = split /[: ]/, '2020:01:02 03:04:05'; my @gmt = split /[: ]/, ('' ||]] ..
          [==[ "$loc[0]:$loc[1]:$loc[2]") . " 01:04:05"; join ',', @loc[5,4,3,2], '|', @gmt[5,4,3,2]]==],
          [['05,04,03,02,|,05,04,01,02']],
          [[]],
          [[]] },
        { [[x]], [[my $x = '2004:02:26 09:36:46'; if ($x && $x =~ /(\d{4}):(\d{2})/) { return $1 * 60 + $2 } 0]],
          [['120242']],
          [[]],
          [[]] },
        { [[x]], [[my ($i, $tag, $ptr); my $key = 'HandlerType'; my @val = ('Audio Track'); for ($i=1; defined]] ..
          [[ $val[0]; ++$i) { last if $val[0] eq 'Video Track'; $key = "HandlerType ($i)"; $val[0] = $i < 3 ?]] ..
          [[ 'x' : 'Video Track'; } $key]],
          [['HandlerType (3)']],
          [[]],
          [[]] },
        { [[x]], [[my ($rgn, @newRgns); my @val = ({ Regions => [ { PersonDisplayName => 'A', Rectangle => '0.1, 0.2,]] ..
          [[ 0.3, 0.4' } ] }); foreach $rgn (@{$val[0]{Regions}}) { my @rect = split /\s*,\s*/,]] ..
          [[ $$rgn{Rectangle}; my $temp = $rect[0]; $rect[0] = 1-$rect[1]-$rect[3]; $rect[1] = $temp;]] ..
          [[ ($rect[2], $rect[3]) = ($rect[3],$rect[2]); push @newRgns, { PersonDisplayName =>]] ..
          [[ $$rgn{PersonDisplayName}, Rectangle => join(', ', @rect) }; } return { Regions => \@newRgns };]],
          [[{Regions=>[{PersonDisplayName=>'A',Rectangle=>'0.4, 0.1, 0.4, 0.3'}]}]],
          [[]],
          [[]] },
        { [[x]], [[my ($rgn, @newRgns); my @val = ({ RegionList => [ { Area => { X => 0.5, Y => 0.4, W => 0.1, H =>]] ..
          [[ 0.2 }, Name => 'A' } ] }); foreach $rgn (@{$val[0]{RegionList}}) { my @rect =]] ..
          [[ @{$$rgn{Area}}{'X','Y','W','H'}; my %newRgn = ( Area => { X => 1-$rect[1], Y => $rect[0], W =>]] ..
          [[ $rect[3], H => $rect[2], Unit => 'normalized' }, Name => $$rgn{Name}, Type => 'Face' ); push]] ..
          [[ @newRgns, \%newRgn; } return { RegionList => \@newRgns };]],
          [[{RegionList=>[{Area=>{H=>'0.1',Unit=>'normalized',W=>'0.2',X=>'0.6',Y=>'0.5'},Name=>'A',Type=>'Face']] ..
          [[}]}]],
          [[]],
          [[]] },
        { [[x]], [[my @r; for my $i (1..2) { my %h = (n => $i); push @r, \%h } join ",", map { $_->{n} } @r]],
          [['1,2']],
          [[]],
          [[]] },
        { [[x]], [[my @r; for my $i (1..2) { my @a = ($i, $i); push @r, \@a } join ",", map { "@$_" } @r]],
          [['1 1,2 2']],
          [[]],
          [[]] },
        { [[x]], [[my $pref = 'CreateDate'; my $num = { gpsdatetime => 2, createdate => 6 }->{lc $pref}; $num]],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my $s = "x"; for (my $i = 0; $i < 3; $i++) { $s .= $i } $s]],
          [['x012']],
          [[]],
          [[]] },
        { [[x]], [[my $r = [1, 2]; "n=@{[ scalar @$r ]} last=$$r[-1] $r->[0]"]],
          [['n=2 last=2 1']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (a => [1, 2]); "$h{a}[1] $h{a}->[0] @{$h{a}}"]],
          [['2 1 1 2']],
          [[]],
          [[]] },
        { [[x]], [[my @a = ([1, 2], [3]); "$a[0][1] $a[1]->[0] $#{$a[0]}"]],
          [['2 3 1']],
          [[]],
          [[]] },
        { [[x]], [[my $h = { k => 'v' }; my $k = 'k'; "$h->{$k} $$h{k} ${$h}{k}"]],
          [['v v v']],
          [[]],
          [[]] },
        { [[x]], [[my @t = (1, 2, 3); my $i = 0; "$t[$i] $t[$i+1] $t[-1]"]],
          [['1 2 3']],
          [[]],
          [[]] },
        { [[x]], [[my @w = ('a'); "@w[0] x"]],
          [['a x']],
          [[]],
          [[Scalar value @w[0] better written as $w[0] at (eval 1) line 1.\n]] },
        { [[x]], [[my %h; $h{lc 'A'} = 1; join ',', keys %h]],
          [['a']],
          [[]],
          [[]] },
        { [[x]], [[my %h = (-foo => 1, bar => 2); join ',', sort keys %h]],
          [['-foo,bar']],
          [[]],
          [[]] },
        { [[x]], [[my %h; $h{foo} = 1; $h{'foo'} + $h{"foo"}]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my $x = 0; $x += $_ for 1..10; $x]],
          [['55']],
          [[]],
          [[]] },
        { [[x]], [[my @s = (5, 3, 9); my ($min) = sort { $a <=> $b } @s; $min]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my ($x, $y) = (undef, 2); $x //= 7; $y ||= 8; "$x $y"]],
          [['7 2']],
          [[]],
          [[]] },
        { [[x]], [[my $c = () = (1, 2, 3); $c]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1) x 0; scalar @a]],
          [['0']],
          [[]],
          [[]] },
        { [[x]], [[my $str = sprintf('%.2d', 5); $str]],
          [['05']],
          [[]],
          [[]] },
        { [[x]], [[my @list = (3, 1, 2); my @sorted = sort { $b <=> $a } @list; "@sorted[0..1]"]],
          [['3 2']],
          [[]],
          [[]] },
        { [[x]], [==[my @a = (1..3); my @b = map { [$_, $_ * 2] } @a; $b[2][1]]==],
          [['6']],
          [[]],
          [[]] },
        { [[x]], [[my %h = map { $_ => length } qw(aa bbb); join ',', map { "$_$h{$_}" } sort keys %h]],
          [['aa2,bbb3']],
          [[]],
          [[]] },
        { [[x]], [[my @lines = ("a\n", "b\n"); chomp(@lines); join '|', @lines]],
          [['a|b']],
          [[]],
          [[]] },
        { [[x]], [[my $t = time; $t > 1000000 ? 1 : 0]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my @l = localtime(0); scalar(@l)]],
          [['9']],
          [[]],
          [[]] },
        { [[x]], [[my $n = @{[1, 2, 3]}; $n]],
          [['3']],
          [[]],
          [[]] },
        { [[x]], [[my $x = { a => 1 }; delete $x->{a}; exists $x->{a} ? 'y' : 'n']],
          [['n']],
          [[]],
          [[]] },
        { [[x]], [[my @a = (1, 2, 3); my @b = splice(@a, 1); "@a|@b"]],
          [['1|2 3']],
          [[]],
          [[]] },
        { [[x]], [[my $s = 'abc'; my @c = split //, $s; $#c]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my $r = \@ARGV; ref $r]],
          [['ARRAY']],
          [[]],
          [[]] },
        { [[x]], [[my @a=(1,2); my @x = @a[ 1 ];]],
          [['1']],
          [[]],
          [[Scalar value @a[1] better written as $a[1] at (eval 1) line 1.\n]] },
        { [[x]], [[my %h; my @x = @h{"a"};]],
          [['1']],
          [[]],
          [[Scalar value @h{"a"} better written as $h{"a"} at (eval 1) line 1.\n]] },
        { [[x]], [[my %h; my @x = @h{'a'};]],
          [['1']],
          [[]],
          [[Scalar value @h{"a"} better written as $h{"a"} at (eval 1) line 1.\n]] },
        { [[x]], [[my %h; my @x = @h{a};]],
          [['1']],
          [[]],
          [[Scalar value @h{"a"} better written as $h{"a"} at (eval 1) line 1.\n]] },
        { [[x]], [[my @a; my $i=0; my @x = @a[$i+1];]],
          [['1']],
          [[]],
          [[Scalar value @a[...] better written as $a[...] at (eval 1) line 1.\n]] },
        { [[x]], [[my @a; my @x = @a[0,1];]],
          [['2']],
          [[]],
          [[]] },
        { [[x]], [[my $r=[1]; my @x = @$r[0];]],
          [['1']],
          [[]],
          [[]] },
        { [[x]], [[my @a; my @x = @a[ $#a ];]],
          [['1']],
          [[]],
          [[Scalar value @a[...] better written as $a[...] at (eval 1) line 1.\n]] },
        { [[x]], [[my @a = (1..5); "@a[1,2] @a[-1]"]],
          [['2 3 5']],
          [[]],
          [[Scalar value @a[-1] better written as $a[-1] at (eval 1) line 1.\n]] },
        { [[x]], [[my @w = ('a'); "@w[0] x"]],
          [['a x']],
          [[]],
          [[Scalar value @w[0] better written as $w[0] at (eval 1) line 1.\n]] },
    }) do
        local w = {}
        local oldWarn = perl.SIG.__WARN__
        perl.SIG.__WARN__ = function(m) w[#w + 1] = m end
        local okEval, r = pcall(perl.eval, case[2], { _ = case[1] ~= 'undef' and case[1] or nil }, {})
        perl.SIG.__WARN__ = oldWarn
        local out, err = 'undef', ''
        if okEval then
            out = dump(r)
        elseif perl.isDie(r) then
            err = r.msg
        else
            err = 'Lua error ' .. tostring(r)
        end
        is('R:' .. case[3] .. ' E:' .. case[4] .. ' W:' .. case[5],
           'R:' .. out .. ' E:' .. esc(err) .. ' W:' .. esc(table.concat(w, '|')), 'eval ' .. case[2])
    end
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
-- truncate, %SIG, Term::ReadKey, and the Brotli module (compress.brotli)
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

    -- IO::Uncompress::Brotli / IO::Compress::Brotli (over compress.brotli)
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
        ok(false, 'IO::Uncompress::Brotli and IO::Compress::Brotli load (compress.brotli)')
    end

    -- Compress::Raw::Lzma (over compress.lzma): RawDecoder with Perl's
    -- in/out semantics (ConsumeInput, AppendOutput)
    local haveLzma, CompressRawLzma = perl.evalRequire('Compress::Raw::Lzma')
    if haveLzma then
        local lzma = require('compress.lzma')
        local data = ('lexiftool lzma '):rep(200)
        local packed = lzma.compress(data, { format = 'raw', filter = 'lzma1' })  -- (with end marker)
        local z, status = CompressRawLzma.RawDecoder.new({ Filter = CompressRawLzma.Lzma.Filter.Lzma1() })
        is(CompressRawLzma.LZMA_OK, status, 'RawDecoder->new returns LZMA_OK')
        local input = carray.new('char'):append(packed, 'TRAILING')
        local output = carray.new('char'):append('old')
        status = z:code(input, output)
        is(CompressRawLzma.LZMA_STREAM_END, status, 'code: LZMA_STREAM_END at the end marker')
        ok(data == output:tostring(), 'code replaces the output (AppendOutput 0)')
        is('TRAILING', input:tostring(), 'code removes the consumed input (ConsumeInput 1)')
        z = CompressRawLzma.RawDecoder.new({ Filter = { CompressRawLzma.Lzma.Filter.Lzma1() }, AppendOutput = 1 })
        output = carray.new('char'):append('old')
        z:code(packed, output)
        ok('old' .. data == output:tostring(), 'AppendOutput 1 appends; a filter list of one is accepted')
        -- without end marker (as 7-Zip writes it): LZMA_OK for all of the input
        z = CompressRawLzma.RawDecoder.new({ Filter = CompressRawLzma.Lzma.Filter.Lzma1() })
        input = carray.new('char'):append(packed:sub(1, #packed - 6))
        output = carray.new('char')
        is(CompressRawLzma.LZMA_OK, z:code(input, output), 'code: LZMA_OK while the stream goes on')
        is(0, input:len(), 'all of the input is consumed')
        ok(output:len() > 0 and output:len() <= #data, 'the output so far')
    else
        ok(false, 'Compress::Raw::Lzma loads (compress.lzma)')
    end

    -- IO::Uncompress::Bunzip2::bunzip2 (over compress.bzip2), one-shot
    -- defaults: MultiStream 0, Transparent 1
    local haveBunzip2, IO_Uncompress_Bunzip2 = perl.evalRequire('IO::Uncompress::Bunzip2')
    if haveBunzip2 then
        local bzip2 = require('compress.bzip2')
        local data = ('lexiftool bzip2 '):rep(200)
        local packed = bzip2.compress(data)
        local out = {}
        is(1, IO_Uncompress_Bunzip2.bunzip2({ value = packed }, out), 'bunzip2 succeeds')
        ok(data == out.value:tostring(), 'bunzip2(bzip2(x)) == x (output box holds a carray)')
        IO_Uncompress_Bunzip2.bunzip2(packed .. packed, out)
        ok(data == out.value:tostring(), 'MultiStream 0: data after the first stream is ignored')
        is(1, IO_Uncompress_Bunzip2.bunzip2('not bzip2', out), 'Transparent: bunzip2 of plain data succeeds')
        is('not bzip2', out.value:tostring(), 'Transparent: plain data is copied')
        IO_Uncompress_Bunzip2.bunzip2('', out)
        is('', out.value:tostring(), 'empty input gives empty output')
        is(nil, IO_Uncompress_Bunzip2.bunzip2('BZh9 corrupt data', out), 'corrupt bzip2 data fails')
        ok(IO_Uncompress_Bunzip2.Bunzip2Error ~= '', 'Bunzip2Error is set: ' .. IO_Uncompress_Bunzip2.Bunzip2Error)
        is(nil, IO_Uncompress_Bunzip2.bunzip2(packed:sub(1, 20), out), 'truncated bzip2 data fails')
    else
        ok(false, 'IO::Uncompress::Bunzip2 loads (compress.bzip2)')
    end

    -- Unicode::GCString->new($str)->columns (the facade's, over the character
    -- data of Unicode-LineBreak); expected values from the Perl module
    -- (Unicode::GCString of Unicode-LineBreak 2019.001)
    local haveGCString, UnicodeGCString = perl.evalRequire('Unicode::GCString')
    if haveGCString then
        local function cols(...)
            local t = {}
            for i, cp in ipairs({ ... }) do t[i] = utf8.char(cp) end
            return UnicodeGCString.new(table.concat(t)):columns()
        end
        is(0, cols(), 'columns: empty string')
        is(4, UnicodeGCString.new('Make'):columns(), 'columns: ASCII')
        is(10, cols(0x30D5, 0x30A1, 0x30A4, 0x30EB, 0x540D), 'columns: wide (Katakana, Han)')
        is(1, cols(0x65, 0x301), 'columns: combining mark extends its base')
        is(1, cols(0x20, 0x301), 'columns: SP takes no combining mark (no LegacyCM)')
        is(2, cols(0x1100, 0x1161, 0x11A8), 'columns: Hangul jamo sequence is one wide cluster')
        is(2, cols(0x1161), 'columns: isolated jamo V is wide')
        is(2, cols(0x1F1E9, 0x1F1EA), 'columns: regional indicator pair')
        is(0, cols(0x0D, 0x0A), 'columns: CR LF')
        is(2, cols(0x0915, 0x094D, 0x0937), 'columns: virama does not join (no ViramaAsJoiner)')
        is(2, cols(0x20000), 'columns: Han beyond U+20000')
        is(0, cols(0xE0100), 'columns: variation selector')
        is(1, cols(0xF0000), 'columns: private use (ambiguous is narrow)')
        is(1, cols(0xE0080), 'columns: reserved')
        is(2, cols(0xFF21), 'columns: fullwidth')
        is(1, cols(0xA1), 'columns: ambiguous')
        is(1, cols(0x0600, 0x31), 'columns: prepend joins the next character')
        is(2, cols(0x61, 0x07, 0x62), 'columns: control character')
        ok(UnicodeGCString.UNICODE_VERSION ~= nil, 'Unicode version of the data')
    else
        ok(false, 'Unicode::GCString loads (lexiftool.GCStringData)')
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

-- Time::Local::timegm (version 1.35, the one Perl ships), expectations from
-- `perl -MTime::Local -e 'eval { timegm(...) }'`: the result, or the croak
-- message without its " at FILE line N." tail. Covers month 0..11 and out
-- of range, the days of each month in leap and common years, hour/minute/
-- second limits, fractional seconds, Time::Local's year rules (two-digit
-- years in the rolling century window, 100..999 and negative years as an
-- offset from 1900, 1000 and up as the full year), strings as regex
-- captures give them (quoted as given in the message), and the $MaxDay
-- limit. The rows run in this order on purpose: the last one hits the
-- month-start cache entry of year 1899 (pack('ss') keys are 16 bits wide),
-- as in Perl.
do
    local rows = {
        { { 0, 0, 0, 0, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 1, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 28, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 29, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 30, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 31, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 32, -1, 2000 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 0, 0, 2000 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 0, 2000 }, 946684800 },
        { { 0, 0, 0, 28, 0, 2000 }, 949017600 },
        { { 0, 0, 0, 29, 0, 2000 }, 949104000 },
        { { 0, 0, 0, 30, 0, 2000 }, 949190400 },
        { { 0, 0, 0, 31, 0, 2000 }, 949276800 },
        { { 0, 0, 0, 32, 0, 2000 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 1, 2000 }, "Day '0' out of range 1..29" },
        { { 0, 0, 0, 1, 1, 2000 }, 949363200 },
        { { 0, 0, 0, 28, 1, 2000 }, 951696000 },
        { { 0, 0, 0, 29, 1, 2000 }, 951782400 },
        { { 0, 0, 0, 30, 1, 2000 }, "Day '30' out of range 1..29" },
        { { 0, 0, 0, 31, 1, 2000 }, "Day '31' out of range 1..29" },
        { { 0, 0, 0, 32, 1, 2000 }, "Day '32' out of range 1..29" },
        { { 0, 0, 0, 0, 2, 2000 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 2, 2000 }, 951868800 },
        { { 0, 0, 0, 28, 2, 2000 }, 954201600 },
        { { 0, 0, 0, 29, 2, 2000 }, 954288000 },
        { { 0, 0, 0, 30, 2, 2000 }, 954374400 },
        { { 0, 0, 0, 31, 2, 2000 }, 954460800 },
        { { 0, 0, 0, 32, 2, 2000 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 11, 2000 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 11, 2000 }, 975628800 },
        { { 0, 0, 0, 28, 11, 2000 }, 977961600 },
        { { 0, 0, 0, 29, 11, 2000 }, 978048000 },
        { { 0, 0, 0, 30, 11, 2000 }, 978134400 },
        { { 0, 0, 0, 31, 11, 2000 }, 978220800 },
        { { 0, 0, 0, 32, 11, 2000 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 1, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 28, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 29, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 30, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 31, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 32, 12, 2000 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 0, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 1, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 28, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 29, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 30, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 31, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 32, -1, 1900 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 0, 0, 1900 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 0, 1900 }, -2208988800 },
        { { 0, 0, 0, 28, 0, 1900 }, -2206656000 },
        { { 0, 0, 0, 29, 0, 1900 }, -2206569600 },
        { { 0, 0, 0, 30, 0, 1900 }, -2206483200 },
        { { 0, 0, 0, 31, 0, 1900 }, -2206396800 },
        { { 0, 0, 0, 32, 0, 1900 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 1, 1900 }, "Day '0' out of range 1..28" },
        { { 0, 0, 0, 1, 1, 1900 }, -2206310400 },
        { { 0, 0, 0, 28, 1, 1900 }, -2203977600 },
        { { 0, 0, 0, 29, 1, 1900 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 30, 1, 1900 }, "Day '30' out of range 1..28" },
        { { 0, 0, 0, 31, 1, 1900 }, "Day '31' out of range 1..28" },
        { { 0, 0, 0, 32, 1, 1900 }, "Day '32' out of range 1..28" },
        { { 0, 0, 0, 0, 2, 1900 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 2, 1900 }, -2203891200 },
        { { 0, 0, 0, 28, 2, 1900 }, -2201558400 },
        { { 0, 0, 0, 29, 2, 1900 }, -2201472000 },
        { { 0, 0, 0, 30, 2, 1900 }, -2201385600 },
        { { 0, 0, 0, 31, 2, 1900 }, -2201299200 },
        { { 0, 0, 0, 32, 2, 1900 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 11, 1900 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 11, 1900 }, -2180131200 },
        { { 0, 0, 0, 28, 11, 1900 }, -2177798400 },
        { { 0, 0, 0, 29, 11, 1900 }, -2177712000 },
        { { 0, 0, 0, 30, 11, 1900 }, -2177625600 },
        { { 0, 0, 0, 31, 11, 1900 }, -2177539200 },
        { { 0, 0, 0, 32, 11, 1900 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 1, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 28, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 29, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 30, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 31, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 32, 12, 1900 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 0, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 1, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 28, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 29, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 30, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 31, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 32, -1, 2004 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 0, 0, 2004 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 0, 2004 }, 1072915200 },
        { { 0, 0, 0, 28, 0, 2004 }, 1075248000 },
        { { 0, 0, 0, 29, 0, 2004 }, 1075334400 },
        { { 0, 0, 0, 30, 0, 2004 }, 1075420800 },
        { { 0, 0, 0, 31, 0, 2004 }, 1075507200 },
        { { 0, 0, 0, 32, 0, 2004 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 1, 2004 }, "Day '0' out of range 1..29" },
        { { 0, 0, 0, 1, 1, 2004 }, 1075593600 },
        { { 0, 0, 0, 28, 1, 2004 }, 1077926400 },
        { { 0, 0, 0, 29, 1, 2004 }, 1078012800 },
        { { 0, 0, 0, 30, 1, 2004 }, "Day '30' out of range 1..29" },
        { { 0, 0, 0, 31, 1, 2004 }, "Day '31' out of range 1..29" },
        { { 0, 0, 0, 32, 1, 2004 }, "Day '32' out of range 1..29" },
        { { 0, 0, 0, 0, 2, 2004 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 2, 2004 }, 1078099200 },
        { { 0, 0, 0, 28, 2, 2004 }, 1080432000 },
        { { 0, 0, 0, 29, 2, 2004 }, 1080518400 },
        { { 0, 0, 0, 30, 2, 2004 }, 1080604800 },
        { { 0, 0, 0, 31, 2, 2004 }, 1080691200 },
        { { 0, 0, 0, 32, 2, 2004 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 11, 2004 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 11, 2004 }, 1101859200 },
        { { 0, 0, 0, 28, 11, 2004 }, 1104192000 },
        { { 0, 0, 0, 29, 11, 2004 }, 1104278400 },
        { { 0, 0, 0, 30, 11, 2004 }, 1104364800 },
        { { 0, 0, 0, 31, 11, 2004 }, 1104451200 },
        { { 0, 0, 0, 32, 11, 2004 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 1, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 28, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 29, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 30, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 31, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 32, 12, 2004 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 0, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 1, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 28, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 29, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 30, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 31, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 32, -1, 2001 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 0, 0, 2001 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 0, 2001 }, 978307200 },
        { { 0, 0, 0, 28, 0, 2001 }, 980640000 },
        { { 0, 0, 0, 29, 0, 2001 }, 980726400 },
        { { 0, 0, 0, 30, 0, 2001 }, 980812800 },
        { { 0, 0, 0, 31, 0, 2001 }, 980899200 },
        { { 0, 0, 0, 32, 0, 2001 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 1, 2001 }, "Day '0' out of range 1..28" },
        { { 0, 0, 0, 1, 1, 2001 }, 980985600 },
        { { 0, 0, 0, 28, 1, 2001 }, 983318400 },
        { { 0, 0, 0, 29, 1, 2001 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 30, 1, 2001 }, "Day '30' out of range 1..28" },
        { { 0, 0, 0, 31, 1, 2001 }, "Day '31' out of range 1..28" },
        { { 0, 0, 0, 32, 1, 2001 }, "Day '32' out of range 1..28" },
        { { 0, 0, 0, 0, 2, 2001 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 2, 2001 }, 983404800 },
        { { 0, 0, 0, 28, 2, 2001 }, 985737600 },
        { { 0, 0, 0, 29, 2, 2001 }, 985824000 },
        { { 0, 0, 0, 30, 2, 2001 }, 985910400 },
        { { 0, 0, 0, 31, 2, 2001 }, 985996800 },
        { { 0, 0, 0, 32, 2, 2001 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 11, 2001 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 11, 2001 }, 1007164800 },
        { { 0, 0, 0, 28, 11, 2001 }, 1009497600 },
        { { 0, 0, 0, 29, 11, 2001 }, 1009584000 },
        { { 0, 0, 0, 30, 11, 2001 }, 1009670400 },
        { { 0, 0, 0, 31, 11, 2001 }, 1009756800 },
        { { 0, 0, 0, 32, 11, 2001 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 1, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 28, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 29, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 30, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 31, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 32, 12, 2001 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 0, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 1, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 28, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 29, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 30, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 31, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 32, -1, 2023 }, "Month '-1' out of range 0..11" },
        { { 0, 0, 0, 0, 0, 2023 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 0, 2023 }, 1672531200 },
        { { 0, 0, 0, 28, 0, 2023 }, 1674864000 },
        { { 0, 0, 0, 29, 0, 2023 }, 1674950400 },
        { { 0, 0, 0, 30, 0, 2023 }, 1675036800 },
        { { 0, 0, 0, 31, 0, 2023 }, 1675123200 },
        { { 0, 0, 0, 32, 0, 2023 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 1, 2023 }, "Day '0' out of range 1..28" },
        { { 0, 0, 0, 1, 1, 2023 }, 1675209600 },
        { { 0, 0, 0, 28, 1, 2023 }, 1677542400 },
        { { 0, 0, 0, 29, 1, 2023 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 30, 1, 2023 }, "Day '30' out of range 1..28" },
        { { 0, 0, 0, 31, 1, 2023 }, "Day '31' out of range 1..28" },
        { { 0, 0, 0, 32, 1, 2023 }, "Day '32' out of range 1..28" },
        { { 0, 0, 0, 0, 2, 2023 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 2, 2023 }, 1677628800 },
        { { 0, 0, 0, 28, 2, 2023 }, 1679961600 },
        { { 0, 0, 0, 29, 2, 2023 }, 1680048000 },
        { { 0, 0, 0, 30, 2, 2023 }, 1680134400 },
        { { 0, 0, 0, 31, 2, 2023 }, 1680220800 },
        { { 0, 0, 0, 32, 2, 2023 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 11, 2023 }, "Day '0' out of range 1..31" },
        { { 0, 0, 0, 1, 11, 2023 }, 1701388800 },
        { { 0, 0, 0, 28, 11, 2023 }, 1703721600 },
        { { 0, 0, 0, 29, 11, 2023 }, 1703808000 },
        { { 0, 0, 0, 30, 11, 2023 }, 1703894400 },
        { { 0, 0, 0, 31, 11, 2023 }, 1703980800 },
        { { 0, 0, 0, 32, 11, 2023 }, "Day '32' out of range 1..31" },
        { { 0, 0, 0, 0, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 1, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 28, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 29, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 30, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 31, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, 0, 32, 12, 2023 }, "Month '12' out of range 0..11" },
        { { 0, 0, -1, 1, 0, 2007 }, "Hour '-1' out of range 0..23" },
        { { 0, 0, 0, 1, 0, 2007 }, 1167609600 },
        { { 0, 0, 23, 1, 0, 2007 }, 1167692400 },
        { { 0, 0, 24, 1, 0, 2007 }, "Hour '24' out of range 0..23" },
        { { 0, -1, 0, 1, 0, 2007 }, "Minute '-1' out of range 0..59" },
        { { 0, 0, 0, 1, 0, 2007 }, 1167609600 },
        { { 0, 59, 0, 1, 0, 2007 }, 1167613140 },
        { { 0, 60, 0, 1, 0, 2007 }, "Minute '60' out of range 0..59" },
        { { -1, 0, 0, 1, 0, 2007 }, "Second '-1' out of range 0..59" },
        { { -0.5, 0, 0, 1, 0, 2007 }, 1167609599.5 },
        { { 0, 0, 0, 1, 0, 2007 }, 1167609600 },
        { { 0.25, 0, 0, 1, 0, 2007 }, 1167609600.25 },
        { { 59, 0, 0, 1, 0, 2007 }, 1167609659 },
        { { 59.5, 0, 0, 1, 0, 2007 }, 1167609659.5 },
        { { 59.999, 0, 0, 1, 0, 2007 }, 1167609659.999 },
        { { 60, 0, 0, 1, 0, 2007 }, "Second '60' out of range 0..59" },
        { { 60.5, 0, 0, 1, 0, 2007 }, "Second '60' out of range 0..59" },
        { { 56, 34, 12, 29, 1, 0 }, 951827696, two = true },
        { { 0, 0, 0, 1, 0, 0 }, 946684800, two = true },
        { { 56, 34, 12, 29, 1, 10 }, "Day '29' out of range 1..28", two = true },
        { { 0, 0, 0, 1, 0, 10 }, 1262304000, two = true },
        { { 56, 34, 12, 29, 1, 69 }, "Day '29' out of range 1..28", two = true },
        { { 0, 0, 0, 1, 0, 69 }, 3124224000, two = true },
        { { 56, 34, 12, 29, 1, 70 }, "Day '29' out of range 1..28", two = true },
        { { 0, 0, 0, 1, 0, 70 }, 3155760000, two = true },
        { { 56, 34, 12, 29, 1, 99 }, "Day '29' out of range 1..28", two = true },
        { { 0, 0, 0, 1, 0, 99 }, 915148800, two = true },
        { { 56, 34, 12, 29, 1, 100 }, 951827696 },
        { { 0, 0, 0, 1, 0, 100 }, 946684800 },
        { { 56, 34, 12, 29, 1, 101 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 101 }, 978307200 },
        { { 56, 34, 12, 29, 1, 999 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 999 }, 29316470400 },
        { { 56, 34, 12, 29, 1, 1000 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 1000 }, -30610224000 },
        { { 56, 34, 12, 29, 1, 1899 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 1899 }, -2240524800 },
        { { 56, 34, 12, 29, 1, 1900 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 1900 }, -2208988800 },
        { { 56, 34, 12, 29, 1, 1969 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 1969 }, -31536000 },
        { { 56, 34, 12, 29, 1, 1970 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 1970 }, 0 },
        { { 56, 34, 12, 29, 1, 2038 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 2038 }, 2145916800 },
        { { 56, 34, 12, 29, 1, 2100 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 2100 }, 4102444800 },
        { { 56, 34, 12, 29, 1, 9999 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 9999 }, 253370764800 },
        { { 56, 34, 12, 29, 1, -1 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, -1 }, -2240524800 },
        { { 56, 34, 12, 29, 1, -70 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, -70 }, -4417977600 },
        { { 56, 34, 12, 29, 1, -1900 }, -62161989904 },
        { { 0, 0, 0, 1, 0, -1900 }, -62167132800 },
        { { 56, 34, 12, 29, 1, -1901 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, -1901 }, -62198668800 },
        { { 56, 34, 12, 29, 1, -2000 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, -2000 }, -65322806400 },
        { { 56, 34, 12, 29, 1, -5000 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, -5000 }, -159993619200 },
        { { 56, 34, 12, 29, 1, 12345 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 12345 }, 327403382400 },
        { { 56, 34, 12, 29, 1, 40000 }, 1200116003696 },
        { { 0, 0, 0, 1, 0, 40000 }, 1200110860800 },
        { { 56, 34, 12, 29, 1, 99999 }, "Day '29' out of range 1..28" },
        { { 0, 0, 0, 1, 0, 99999 }, 3093496444800 },
        { { '05', '07', '09', '00', '01', 2007 }, "Day '00' out of range 1..28" },
        { { '00', '00', '00', '05', 1, 2007 }, 1170633600 },
        { { 30, '00', 25, '01', 0, 2007 }, "Hour '25' out of range 0..23" },
        { { '00', 60, '00', '01', 0, 2007 }, "Minute '60' out of range 0..59" },
        { { 61, '00', '00', '01', 0, 2007 }, "Second '61' out of range 0..59" },
        { { 0, 0, 0, 31, 3, 2007 }, "Day '31' out of range 1..30" },
        { { 0, 0, 0, 1, 13, 2007 }, "Month '13' out of range 0..11" },
        { { 0, 0, 0, '01', '00', '07' }, 1167609600, two = true },
        { { 1.5, 0, 0, 1, 0, 2007 }, 1167609601.5 },
        { { 0, 0, 0, 1.5, 0, 2007 }, 1167652800 },
        { { 0, 0, 0, 1, 0, 3000000000 }, "Day too big - abs(1095726780472) > 783831531520\nCannot handle date (0, 0, 0, 1, 0, 3000000000)" },
        { { 0, 0, 0, 1, 0, -3000000000 }, "Day too big - abs(-1095727525566) > 783831531520\nCannot handle date (0, 0, 0, 1, 0, -2999998100)" },
        { { 0, 0, 0, 1, 0, 2147485547 }, -2240524800 },
    }
    -- the two-digit rows hold while the window's breakpoint lies in 70..98
    -- (it moves with the current year, as Time::Local computes it)
    local thisYear = os.date('*t').year - 1900
    local breakpoint = (thisYear + 50) % 100
    local twoDigitOk = breakpoint >= 70 and breakpoint <= 98
    for i, row in ipairs(rows) do
        if twoDigitOk or not row.two then
            local args = row[1]
            local ok2, res = pcall(function() return perl.timegm(table.unpack(args, 1, 6)) end)
            local name = 'timegm row ' .. i .. ' (' .. perl.join(', ', args) .. ')'
            if type(row[2]) == 'number' then
                is(row[2], ok2 and res or (perl.isDie(res) and res.msg or tostring(res)), name)
            else
                ok(not ok2 and perl.isDie(res), name .. ' croaks')
                is(row[2], (not ok2 and perl.isDie(res)) and res.msg:gsub(' at %S+ line %d+%.\n$', '') or res, name .. ' message')
            end
        end
    end

    -- the croak names the first caller outside the facade, as Carp::croak
    -- names the first caller outside Time::Local (CleanWarning strips it;
    -- the parentheses keep the calls from being tail calls, whose frame Lua
    -- would drop)
    local function where(f)
        local ok2, e = pcall(f)
        if ok2 or not perl.isDie(e) then return nil end
        return e.msg:match(' at (%S+) line (%d+)%.\n$')
    end
    local thisFile = debug.getinfo(1, 'S').source:sub(2)
    local line = debug.getinfo(1, 'l').currentline
    local src, ln = where(function() return (perl.timegm(0, 0, 0, 30, 1, 2007)) end)
    is(thisFile, src, 'timegm croak names the calling file')
    is(tostring(line + 1), ln, 'timegm croak names the calling line')
    src, ln = where(function() return (perl.timelocal(0, 0, 0, 30, 1, 2007)) end)
    is(thisFile, src, 'timelocal croak names the caller of timelocal')
    is(tostring(line + 4), ln, 'timelocal croak names the calling line')

    -- timelocal shares the checks; it inverts localtime(), with strings too
    local ok2, e = pcall(perl.timelocal, 0, 0, '24', '01', 0, 2007)
    is("Hour '24' out of range 0..23", not ok2 and e.msg:gsub(' at %S+ line %d+%.\n$', ''), 'timelocal croaks like timegm')
    for _, t in ipairs({ 0, 1167609600, 1679794200, 1698539400, -2240524800 }) do
        local lt = perl.localtime(t)
        is(t, perl.timelocal(lt[1], lt[2], lt[3], lt[4], lt[5], lt[6] + 1900), 'timelocal inverts localtime ' .. t)
    end
    local lt = perl.localtime(1167609600)
    is(1167609600.25, perl.timelocal(lt[1] + 0.25, perl.str(lt[2]), perl.str(lt[3]), perl.str(lt[4]),
        perl.str(lt[5]), perl.str(lt[6] + 1900)), 'timelocal: string fields and fractional seconds')
end

-- localtime/gmtime for any time, as Perl's own (time64.c): the system
-- localtime within the range Perl's build gives it, the safe-year mapping
-- outside it, the empty tlist beyond Perl's bounds. The expected values come
-- from the Perl found at test time, run on the same machine (same zone
-- data, same C library): `perl`, or the test-only global
-- LEXIFTOOL_TEST_PERL (make TEST_PERL=..., set by the Windows CI job to
-- Strawberry Perl -- Git Bash's own perl is an msys build with a range of
-- its own). Without a Perl the comparisons are skipped; with
-- LEXIFTOOL_TEST_PERL set, a Perl that does not run is a failure.
do
    local isWin = package.config:sub(1, 1) == '\\'
    local wantPerl = rawget(_G, 'LEXIFTOOL_TEST_PERL')
    if wantPerl == '' then wantPerl = nil end
    local perlCmd = wantPerl or 'perl'
    if isWin then
        perlCmd = '"' .. perlCmd .. '"'
    elseif perlCmd:find('[^%w_./+-]') then
        perlCmd = "'" .. perlCmd:gsub("'", [['\'']]) .. "'"
    end

    -- run a command line through the shell (cmd.exe drops the outer quotes
    -- of `cmd /c "..."`, so on Windows the whole line gets a pair of its own)
    local function shell(line)
        if isWin then line = '"' .. line .. '"' end
        local p = io.popen(line)
        if not p then return '' end
        local out = p:read('a')
        p:close()
        return out
    end
    -- Perl's localtime and gmtime of each time, one 'LOCAL|GM' line per time
    -- (prefix: an environment assignment for the command, or '')
    local SCRIPT = '-le "print join(q(,), localtime(shift)), q(|), join(q(,), gmtime(shift)) while @ARGV" --'
    local function perlTimes(times, prefix)
        local args = { }
        for _, t in ipairs(times) do
            local arg1 = string.format('%d', t)
            args[#args + 1] = arg1
            args[#args + 1] = arg1
        end
        local plist = { }
        for line in shell((prefix or '') .. perlCmd .. ' ' .. SCRIPT .. ' ' .. table.concat(args, ' ')):gmatch('[^\r\n]*') do
            if line ~= '' then plist[#plist + 1] = line end
        end
        return plist
    end
    local function luaTimes(t)
        return table.concat(perl.localtime(t), ',') .. '|' .. table.concat(perl.gmtime(t), ',')
    end

    -- Perl's localtime fields with the year moved by `years` (a multiple of
    -- 400: the same calendar, and the same safe year, see below)
    local function shiftYear(line, years)
        local f = { }
        for x in (line:match('^([^|]*)')):gmatch('[^,]+') do f[#f + 1] = x end
        if f[6] then f[6] = string.format('%d', math.tointeger(tonumber(f[6])) + years) end
        return table.concat(f, ',')
    end
    local CYCLE = 146097 * 86400          -- seconds in 400 Gregorian years

    local probe = shell(perlCmd .. ' -e "print 42"')
    if probe ~= '42' then
        ok(wantPerl == nil, 'localtime vs Perl SKIPPED: no Perl (' .. perlCmd .. ') to compare with')
    else
        -- the system range is the one this Perl was built with
        -- (Config sLOCALTIME_min/max); a maximum beyond Perl's upper bound
        -- (POSIX) is never reached, the exact value does not matter there
        local cfg = shell(perlCmd .. ' "-V:sLOCALTIME_m.."')
        local cmin = tonumber(cfg:match("sLOCALTIME_min='(%-?%d+)'"))
        local cmax = tonumber(cfg:match("sLOCALTIME_max='(%-?%d+)'"))
        local smin, smax = perl.localtimeSystemRange()
        -- (a Perl whose Config does not carry the probed range -- the bounds
        --  are then only in its config.h -- is checked by the comparisons
        --  below alone, whose times sit on both sides of the bounds)
        if not (cmin and cmax) then
            ok(true, 'localtime system range: SKIPPED, no sLOCALTIME_min/max in Perl\'s Config (' ..
                (cfg:gsub('%s+', ' ')) .. ')')
        else
        is(cmin, smin and math.tointeger(smin), 'localtime system range: minimum as in Perl\'s Config')
        if cmax and cmax > 67767976233316800 then
            ok(smax > 67767976233316800, 'localtime system range: maximum beyond Perl\'s bound, as in Perl\'s Config')
        else
            is(cmax, smax and math.tointeger(smax), 'localtime system range: maximum as in Perl\'s Config')
        end
        end

        -- the host's zone: before 1970, after 2038 and 3000, before the
        -- year 0 (the safe-year path on every platform), Perl's bounds,
        -- fractions (floored), the empty tlist beyond the bounds
        local times = {
            0, -1, 86399, -86401, -2240524800, -2208988800, -631152000, 2147483647, 2147483648,
            4102444800, 32535215999, 32535244799, 32535244800, 40000000000,
            -62167219200, -62167219201, -62167305600, -62198755200, -70000000000,
            -1e15, 1e15, -67768100567755200, 67767976233316800,
            -67768100567755201, 67767976233316801, 1e18, -1e18,
        }
        local plist = perlTimes(times)
        for i, t in ipairs(times) do
            is(plist[i], luaTimes(t), 'localtime|gmtime as in Perl: ' .. string.format('%d', t))
        end
        is(plist[1], luaTimes(0.75), 'localtime|gmtime floor a fraction (0.75)')
        is(plist[2], luaTimes(-0.25), 'localtime|gmtime floor a fraction (-0.25)')
        is(plist[2], luaTimes('-0.25'), 'localtime|gmtime of a string')
        is(0, #perl.localtime(0 / 0), 'localtime of NaN is the empty tlist')
        is(0, #perl.gmtime(1 / 0), 'gmtime of Inf is the empty tlist')

        -- Perl on Windows (LOCALTIME_MIN/MAX 0 and 2147483647) takes the
        -- safe-year path for every time before 1970 and after 2038; the
        -- facade takes it as well with that range. Expected: Perl's own
        -- result for the same time moved back by whole 400-year cycles into
        -- the years before 0 -- the safe-year path on any Perl -- with the
        -- year moved forward again: the 400-year cycle repeats the calendar,
        -- and time64.c's safe_year() maps both years to the same safe year
        -- (the offset of its exception centuries grows by 3 * 16 per cycle,
        -- 400 + 48 = 16 * 28), so the system localtime sees the same time.
        local function windowsRange(tlist, prefix, lua, label)
            local shifted, cycles = { }, { }
            for i, t in ipairs(tlist) do
                local year = perl.gmtime(t)[6] + 1900
                cycles[i] = (year + 400) // 400 + 1
                shifted[i] = t - cycles[i] * CYCLE
            end
            local plines = perlTimes(shifted, prefix)
            local got = lua(tlist)
            for i, t in ipairs(tlist) do
                if t < 0 or t > 2147483647 then
                    is(shiftYear(plines[i] or '', 400 * cycles[i]), got[i],
                       'localtime, Windows range, as Perl' .. label .. ': ' .. string.format('%d', t))
                end
            end
        end
        local winTimes = { -1, -86400, -2240524800, -2208988801, -631152000, 2147483648,
                           4102444800, 4133980799, 4133980800, 32535215999, 40000000000 }
        local oldMin, oldMax = perl.localtimeSystemRange(0, 2147483647)
        windowsRange(winTimes, nil, function(tlist)
            local out = { }
            for i, t in ipairs(tlist) do out[i] = table.concat(perl.localtime(t), ',') end
            return out
        end, '')
        perl.localtimeSystemRange(oldMin, oldMax)
        is(oldMin, (perl.localtimeSystemRange()), 'localtime system range restored')

        -- zones with daylight saving time, in a child process each (a TZ of
        -- its own for Lua and Perl alike): the switches of years mapped to a
        -- safe year (before 1970 and after 2037 with Perl's Windows range,
        -- before the year 0 everywhere), and the turn of the year on both
        -- sides of UTC, a non-leap xx00 year among them (time64.c's tm_yday
        -- correction). POSIX TZ strings, which glibc and macOS read alike;
        -- not on Windows, whose CRT knows only the US rules and whose
        -- child Lua would need a Windows path of the interpreter.
        local lua = TestLib.LUA
        do
            local i = -1
            while arg and arg[i - 1] do i = i - 1; lua = arg[i] end
        end
        if lua and not isWin then
            local script = TestLib.TEST_DIR .. '/facade_localtime.tmp'
            local fh = io.open(script, 'w')
            fh:write("local perl = require('lexiftool.perl')\n",
                     "if arg[1] == 'win' then perl.localtimeSystemRange(0, 2147483647) end\n",
                     "for i = 2, #arg do print(table.concat(perl.localtime(math.tointeger(tonumber(arg[i]))), ',')) end\n")
            fh:close()
            -- (proleptic Gregorian day number, only to pick the times)
            local function days(y, m, d)
                y = y - (m <= 2 and 1 or 0)
                local era = y // 400
                local yoe = y - era * 400
                local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
                return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
            end
            local function lastSunday(y, m, mdays)
                local d = days(y, m, mdays)
                return d - (d + 4) % 7
            end
            local zones = {
                { 'CET-1CEST,M3.5.0,M10.5.0/3', 3600 },
                { 'EST5EDT,M3.2.0,M11.1.0', -18000 },
            }
            for _, zone in ipairs(zones) do
                local tz, off = zone[1], zone[2]
                local tlist = { }
                for _, y in ipairs({ -500, -1, 1900, 1969, 2038, 2100, 3001 }) do
                    -- switches (CET: last Sundays of March/October, 01:00 UTC;
                    -- EST5EDT: 02:00 local), one second and one hour around them
                    local spring = (tz:find('CET') and lastSunday(y, 3, 31) * 86400 + 3600)
                        or ((days(y, 3, 1) + (7 - (days(y, 3, 1) + 4) % 7) % 7 + 7) * 86400 + 7200 - off)
                    local fall = (tz:find('CET') and lastSunday(y, 10, 31) * 86400 + 3600)
                        or ((days(y, 11, 1) + (7 - (days(y, 11, 1) + 4) % 7) % 7) * 86400 + 7200 - off - 3600)
                    for _, d in ipairs({ -3600, -1, 0, 3600 }) do
                        tlist[#tlist + 1] = spring + d
                        tlist[#tlist + 1] = fall + d
                    end
                    -- the turn of the year, in UTC and locally
                    local newYear = days(y + 1, 1, 1) * 86400
                    tlist[#tlist + 1] = newYear - 1
                    tlist[#tlist + 1] = newYear - off - 1
                    tlist[#tlist + 1] = newYear - off
                    tlist[#tlist + 1] = newYear + 1800
                end
                local function child(mode, ts)
                    local args = { }
                    for i, t in ipairs(ts) do args[i] = string.format('%d', t) end
                    local out = { }
                    for line in shell("TZ='" .. tz .. "' " .. lua .. ' ' .. script .. ' ' .. mode .. ' ' ..
                                      table.concat(args, ' ')):gmatch('[^\n]+') do
                        out[#out + 1] = line
                    end
                    return out
                end
                -- the platform's own range
                local plines = perlTimes(tlist, "TZ='" .. tz .. "' ")
                local got = child('own', tlist)
                for i, t in ipairs(tlist) do
                    is((plines[i] or ''):match('^[^|]*'), got[i], 'localtime as in Perl, TZ ' .. tz .. ': ' .. string.format('%d', t))
                end
                -- Perl's Windows range
                windowsRange(tlist, "TZ='" .. tz .. "' ", function(ts) return child('win', ts) end, ', TZ ' .. tz)
            end
            os.remove(script)
        end
    end
end

TestLib.done()
