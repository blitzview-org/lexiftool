--------------------------------------------------------------------------------
-- File:         test/test_locale_port.lua
--
-- Description:  Numbers print with '.' and strings sort as bytes whatever
--               the process's C locale: Perl keeps LC_NUMERIC at "C" and
--               compares strings bytewise outside `use locale`, Lua's
--               string.format and string `<` follow the global locale, which
--               an embedding host may have set. A child process (the
--               simulated host) switches to de_DE.UTF-8 -- before loading
--               lexiftool, and after it (picked up by ExifTool.new) -- and
--               extracts the tags of Canon.jpg and GPS.jpg (values, and the
--               tag orders of GetTagList) plus a few perl.sprintf/perl.str/
--               perl.sort results; everything must be byte-identical to the
--               run under "C", and the host's locale must be left as it was.
--               A second child does the same under a single-byte locale
--               (de_DE ISO-8859-1/-15), where Lua's pattern classes and
--               string.lower/upper take 0xE4 for a letter: facade functions
--               built on Lua patterns (split, unpack 'A', quotemeta, lc/uc,
--               numification, the expression parser of perl.eval) and
--               Geolocation lookups with non-ASCII names must again match
--               "C". Skipped where the locales are not installed (or on
--               Windows, where they have other names; the Windows test run
--               itself uses cp1252).
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')

local is, ok = TestLib.is, TestLib.ok

-- the child: argv = images dir, locale ('C' = none), 'before' or 'after'.
-- Writes one line per value; the first says whether the locale is active
-- (Lua itself formats 1.5 with a comma), the last is os.setlocale(nil).
local child = [=[
local dir, loc, when = ...
local function setloc()
    if loc == 'C' then return true end
    local l = os.setlocale(loc) or os.setlocale((loc:gsub('UTF%-8', 'utf8')))
    return l and os.setlocale(l, 'collate')
end
if when == 'before' and not setloc() then io.write('SKIP\n') return end
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
if when == 'after' then
    perl.sprintf('%.2f', 1.5)   -- (a cached fast-path runner made under "C")
    if not setloc() then io.write('SKIP\n') return end
end
-- (byte order: Lua's < on strings is strcoll, which follows LC_COLLATE)
local function byteLess(a, b)
    for i = 1, math.min(#a, #b) do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end
-- (Lua's own number format and string order: they show the locale is active)
local native = { 'b', 'B', 'a', 'A', '\195\164', 'z' }
table.sort(native)
local out = { string.format('%.1f', 1.5) .. ' ' .. table.concat(native, ' ') }
local function add(v) out[#out + 1] = v end
for _, file in ipairs({ 'Canon.jpg', 'GPS.jpg' }) do
    local et = ExifTool.new()
    for _, conv in ipairs({ 1, 0 }) do
        et:Options('PrintConv', conv)
        local info = et:ImageInfo(dir .. '/' .. file)
        local keys = {}
        for k, v in pairs(info) do
            if type(v) ~= 'table' then keys[#keys + 1] = k end
        end
        table.sort(keys, byteLess)
        for _, k in ipairs(keys) do add(file .. ' ' .. k .. ': ' .. perl.str(info[k])) end
        -- the orders lexiftool sorts itself (-sort, -G1 grouping, -sort Descr)
        for _, order in ipairs({ { 'Alpha' }, { 'Group1', 'Tag' }, { 'Group0' }, { 'Descr' } }) do
            add(file .. ' ' .. order[1] .. ': ' ..
                table.concat(et:GetTagList(info, order[1], order[2]), ' '))
        end
    end
end
add('sort: ' .. table.concat(perl.sort({ 'b', 'B', 'a', 'A', '\195\164', 'z' }), ' '))
local list = { 'b', 'B', 'a', 'A', '\195\164', 'z' }
perl.tsort(list)
add('tsort: ' .. table.concat(list, ' '))
list = { 10, 9, 100, -1 }
perl.tsort(list)
add('tsort numbers: ' .. table.concat(list, ' '))
add('cmp: ' .. perl.cmp('a', 'B') .. ' ' .. perl.cmp('B', 'a') .. ' ' .. perl.cmp('a', 'a') ..
    ' ' .. perl.cmp(10, 9) .. ' ' .. tostring(perl.lt('\195\164', 'z')))
add('groups: ' .. table.concat(ExifTool.GetDeleteGroups(), ' '))
add(perl.sprintf('%.2f', 1.5))
add(perl.sprintf('%.2f %d %s', 1.5, 3, 'x'))
add(perl.sprintf('%.1f, %s; %g', 2.25, 'a,b', 0.5))
add(perl.sprintf('%e|%G|%08.3f', 1.5, 2.5e-7, -1.25))
add(perl.sprintf('%.2f', '1.5'))
add(perl.str(1.5))
add(perl.str(1 / 3))
add(perl.length(1.5))
add(os.setlocale(nil))
io.write(table.concat(out, '\n'), '\n')
]=]

-- the interpreter running this test, for the child process
local lua = TestLib.LUA
do
    local i = -1
    while arg and arg[i - 1] do i = i - 1; lua = arg[i] end
end

local function run(f, loc, when)
    local p = io.popen(lua .. " '" .. f .. "' '" .. TestLib.T_DIR .. "/images' " .. loc ..
                       ' ' .. when .. ' 2>&1')
    local out = p:read('a')
    p:close()
    local lines = {}
    for line in out:gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
    return lines
end

if lua and package.config:sub(1, 1) ~= '\\' then
    local f = TestLib.TEST_DIR .. '/locale_port.tmp'
    local fh = assert(io.open(f, 'wb'))
    fh:write(child)
    fh:close()
    local ref = run(f, 'C', 'before')
    ok(#ref > 100, 'C: tags extracted (' .. #ref .. ' lines)')
    is('1.5 A B a b z \195\164', ref[1], 'C: Lua formats with a point, sorts bytes')
    local idx = {}
    for _, line in ipairs(ref) do
        local tag = line:match('^([%w ]+): ')
        if tag then idx[tag] = line end
    end
    is('sort: A B a b z \195\164', idx.sort, 'C: perl.sort')
    is('tsort: A B a b z \195\164', idx.tsort, 'C: perl.tsort')
    is('tsort numbers: -1 9 10 100', idx['tsort numbers'], 'C: perl.tsort of numbers')
    is('cmp: 1 -1 0 -1 false', idx.cmp, 'C: perl.cmp/perl.lt')
    is('C', ref[#ref], 'C: process locale after')
    local n = #ref
    is('1.50', ref[n - 8], 'C: sprintf %.2f')
    is('1.50 3 x', ref[n - 7], 'C: sprintf mixed')
    is('2.2, a,b; 0.5', ref[n - 6], 'C: sprintf literal comma untouched')
    is('1.500000e+00|2.5E-07|-001.250', ref[n - 5], 'C: sprintf e/G/0-padded f')
    is('1.50', ref[n - 4], 'C: sprintf %.2f of a string')
    is('1.5', ref[n - 3], 'C: str')
    is('0.333333333333333', ref[n - 2], 'C: str 1/3')
    is('3', ref[n - 1], 'C: length')
    for _, when in ipairs({ 'before', 'after' }) do
        local got = run(f, 'de_DE.UTF-8', when)
        if got[1] == 'SKIP' then
            ok(true, 'de_DE.UTF-8 ' .. when .. ': locale not installed, skipped')
        else
            is('1,5 a A \195\164 b B z', got[1], 'de_DE.UTF-8 ' .. when ..
               ': Lua itself formats with a comma and sorts by LC_COLLATE')
            local loc = got[#got]
            ok(loc == 'de_DE.UTF-8' or loc == 'de_DE.utf8',
               'de_DE.UTF-8 ' .. when .. ': host locale left as it was (' .. tostring(loc) .. ')')
            is(#ref, #got, 'de_DE.UTF-8 ' .. when .. ': number of lines')
            local diff = 0
            for i = 2, #ref - 1 do
                if ref[i] ~= got[i] then
                    diff = diff + 1
                    if diff <= 10 then
                        is(ref[i], got[i], 'de_DE.UTF-8 ' .. when .. ': line ' .. i)
                    end
                end
            end
            is(0, diff, 'de_DE.UTF-8 ' .. when .. ': output identical to "C"')
        end
    end
    os.remove(f)
end

-- Character classes and case (LC_CTYPE). Lua's pattern classes %a %l %u %w
-- %s %p and string.lower/upper go through isalpha()/tolower()/... of the
-- global C locale; under a single-byte locale (glibc's de_DE is ISO-8859-1,
-- de_DE@euro ISO-8859-15) 0xE4 is a letter and tolower(0xC4) is 0xE4. Perl
-- means ASCII on a byte string. A second child (the simulated host)
-- switches to such a locale before loading lexiftool and runs facade
-- functions whose Lua patterns use classes, plus Geolocation lookups with
-- non-ASCII names; everything after the first line must equal the run under
-- "C". The first line documents why the classes are spelled as ASCII sets.
local ctypeChild = [=[
local dir, loc = ...
if loc ~= 'C' then
    local ok
    for name in loc:gmatch('[^,]+') do
        -- (accepted, and really single-byte: 0xE4 is a letter there)
        if os.setlocale(name) and ('\228'):find('%a') then ok = true break end
    end
    if not ok then os.setlocale('C') io.write('SKIP\n') return end
end
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local out = {}
local function add(v) out[#out + 1] = v end
local function hex(s)
    return (perl.str(s):gsub('[^ -~]', function(c) return ('\\x%02x'):format(c:byte()) end))
end
add('native: %a=' .. tostring(('\228'):find('%a') ~= nil) ..
    ' [A-Za-z]=' .. tostring(('\228'):find('[A-Za-z]') ~= nil) ..
    ' lower(C4)=' .. hex(('\196'):lower()))
-- awk-mode split: leading whitespace is [ \t\n\r\f\v], 0xA0 is a byte like any other
add('split: ' .. hex(table.concat(perl.split(' ', '\160a b\160 \tc\160'), '|')))
add('split \\s: ' .. hex(table.concat(perl.split('\\s+', 'a\160b c'), '|')))
-- unpack 'A' strips NUL and ASCII whitespace only
add('unpack A: ' .. hex(perl.unpack('A*', 'ab\160 \t\0')))
add('quotemeta: ' .. hex(perl.quotemeta('a\228.b')))
add('lc/uc: ' .. hex(perl.lc('\196Bc')) .. ' ' .. hex(perl.uc('\228bC')) .. ' ' ..
    hex(perl.ucfirst('\228b')))
add('num: ' .. perl.str(perl.num('\16012')) .. ' ' .. perl.str(perl.oct('\16012')))
-- the expression parser: whitespace, identifiers and string literals
local function ev(code, vars)
    local ok, v = pcall(perl.eval, code, vars or {})
    if ok then return 'ok ' .. hex(v) end
    return 'die ' .. hex(perl.isDie(v) and v.msg or v)
end
add('eval literal: ' .. ev('"\228b\160" . "c"'))
add('eval interp: ' .. ev('"x$v\228"', { v = 'y' }))
add('eval space: ' .. ev('1\160+ 2'))
add('eval name: ' .. ev('$\228 eq "a"', { ['\228'] = 'a' }))
add('eval regex: ' .. ev('$v =~ /^\\w+$/ ? 1 : 0', { v = 'a\228' }))
-- Geolocation by position and by name, with UTF-8 names
for _, g in ipairs({ '42.4637,1.4913', 'Sant Juli\195\160 de L\195\178ria', 'z\195\188rich',
                     'Z\195\156RICH', '47.3667,8.5501' }) do
    local et = ExifTool.new()
    et:Options('Geolocation', g)
    local info = et:ImageInfo(dir .. '/Canon.jpg')
    local keys = {}
    for k in pairs(info) do
        if perl.isMatch(k, '^(Geolocation|Warning)') then keys[#keys + 1] = k end
    end
    perl.tsort(keys)
    for _, k in ipairs(keys) do add('geo ' .. hex(g) .. ' ' .. k .. ': ' .. hex(info[k])) end
end
os.setlocale('C')
io.write(table.concat(out, '\n'), '\n')
]=]

if lua and package.config:sub(1, 1) ~= '\\' then
    local f = TestLib.TEST_DIR .. '/locale_ctype.tmp'
    local fh = assert(io.open(f, 'wb'))
    fh:write(ctypeChild)
    fh:close()
    local ref = run(f, 'C', '')
    is('native: %a=false [A-Za-z]=false lower(C4)=\\xc4', ref[1], 'C: 0xE4 is no letter')
    local idx = {}
    for _, line in ipairs(ref) do
        local tag = line:match('^([^:]+): ')
        if tag then idx[tag] = line end
    end
    is('split: \\xa0a|b\\xa0|c\\xa0', idx.split, 'C: awk-mode split keeps 0xA0')
    is('split \\s: a\\xa0b|c', idx['split \\s'], 'C: split on \\s keeps 0xA0')
    is('unpack A: ab\\xa0', idx['unpack A'], "C: unpack 'A' strips ASCII whitespace and NUL")
    is('quotemeta: a\\\\xe4\\.b', idx.quotemeta, 'C: quotemeta escapes 0xE4')
    is('lc/uc: \\xc4bc \\xe4BC \\xe4b', idx['lc/uc'], 'C: lc/uc/ucfirst leave 0xC4/0xE4')
    is('num: 0 0', idx.num, 'C: 0xA0 is no leading whitespace of a number')
    is('eval literal: ok \\xe4b\\xa0c', idx['eval literal'], 'C: eval keeps the literal bytes')
    is('eval regex: ok 0', idx['eval regex'], 'C: eval \\w is ASCII')
    ok(idx['eval name'] and idx['eval name']:match('^eval name: die ') ~= nil,
       'C: eval rejects 0xE4 in a variable name')
    local nGeo = 0
    for _, line in ipairs(ref) do
        if line:match('^geo ') then nGeo = nGeo + 1 end
    end
    ok(nGeo >= 30, 'C: Geolocation lookups (' .. nGeo .. ' lines)')
    ok(idx['geo 42.4637,1.4913 GeolocationCity'] ~= nil, 'C: Geolocation city by position')
    local got = run(f, 'de_DE.ISO-8859-15,de_DE@euro,de_DE.ISO8859-15,de_DE.ISO-8859-1,'
        .. 'de_DE.ISO8859-1,de_DE', '')
    if got[1] == 'SKIP' then
        ok(true, 'single-byte locale: none installed, SKIPPED')
    else
        is('native: %a=true [A-Za-z]=false lower(C4)=\\xe4', got[1],
           'single-byte locale: Lua\'s %a takes 0xE4 for a letter and lowers 0xC4, [A-Za-z] does not')
        is(#ref, #got, 'single-byte locale: number of lines')
        local diff = 0
        for i = 2, math.max(#ref, #got) do
            if ref[i] ~= got[i] then
                diff = diff + 1
                if diff <= 10 then
                    is(ref[i], got[i], 'single-byte locale: line ' .. i)
                end
            end
        end
        is(0, diff, 'single-byte locale: output identical to "C"')
    end
    os.remove(f)
end
