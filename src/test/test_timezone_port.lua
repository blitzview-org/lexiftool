--------------------------------------------------------------------------------
-- File:         test/test_timezone_port.lua
--
-- Description:  Time zone handling the upstream tests do not cover, found by
--               comparing against the Perl original (the expected values
--               below are what `perl -I vendor/exiftool/lib` returns for the
--               same library calls under the same TimeZone options):
--                 1. ConvertUnixTime derives the zone from localtime/gmtime
--                    (TimeZoneString) instead of strftime('%z'), which the
--                    Windows C runtime answers with a zone name; also the
--                    fractional-second digits and the KeepUTCTime branch
--                 2. ConvertDateTime inserts %z, %:z and %s itself before
--                    strftime runs, from the date's own zone or the local
--                    one at that date (summer/winter time, DST gap/overlap)
--                 3. DateFormat in the LC_TIME locale of the environment
--                    (LC_ALL=C and de_DE.UTF-8): strftime, ConvertDateTime,
--                    InverseDateTime through Time::Piece's use_locale and a
--                    write to a copy, read back -- with the process locale
--                    of the Lua state left as it was ("C")
--               The TimeZone option writes $ENV{TZ} for the whole process
--               (no unsetenv, as upstream), and the test files share one Lua
--               state, so the calls run in a child process (3: one per
--               locale, which is read once per Lua state, as Perl does).
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')

local is, ok = TestLib.is, TestLib.ok

-- Perl reference, per TimeZone option value:
--   ConvertUnixTime($t, 1), ($t), ($t, 1, 3), ($t, 1, -3) for each $t in
--   1720958400, 1705320000, 1720958400.9996, -1.25; then
--   ConvertUnixTime(1720958400, 1) with KeepUTCTime; then ConvertDateTime
--   of 7 dates under each of 3 DateFormat values (see `child` below)
local expected = {
    ['EST5EDT'] = {
        '2024:07:14 08:00:00-04:00',
        '2024:07:14 12:00:00',
        '2024:07:14 08:00:00.000-04:00',
        '2024:07:14 08:00:00-04:00',
        '2024:01:15 07:00:00-05:00',
        '2024:01:15 12:00:00',
        '2024:01:15 07:00:00.000-05:00',
        '2024:01:15 07:00:00-05:00',
        '2024:07:14 08:00:01-04:00',
        '2024:07:14 12:00:01',
        '2024:07:14 08:00:01.000-04:00',
        '2024:07:14 08:00:01-04:00',
        '1969:12:31 18:59:59-05:00',
        '1969:12:31 23:59:59',
        '1969:12:31 18:59:58.750-05:00',
        '1969:12:31 18:59:58.75-05:00',
        '2024:07:14 12:00:00Z',
        '2024:07:14 12:00:00 -0400|-04:00|1720972800',
        '2024:01:15 12:00:00 -0500|-05:00|1705338000',
        '2024:07:14 12:00:00 +0530|+05:30|1720938600',
        '2024:01:15 12:00:00 +0000|+00:00|1705320000',
        '2024:03:31 02:30:00 -0400|-04:00|1711866600',
        '2024:10:27 02:30:00 -0400|-04:00|1730010600',
        '2024:11:03 01:30:00 -0400|-04:00|1730611800',
        '2024-07-14 12:00:00',
        '2024-01-15 12:00:00',
        '2024-07-14 12:00:00',
        '2024-01-15 12:00:00',
        '2024-03-31 02:30:00',
        '2024-10-27 02:30:00',
        '2024-11-03 01:30:00',
        '%z %-0400 1720972800%s',
        '%z %-0500 1705338000%s',
        '%z %+0530 1720938600%s',
        '%z %+0000 1705320000%s',
        '%z %-0400 1711866600%s',
        '%z %-0400 1730010600%s',
        '%z %-0400 1730611800%s',
    },
    ['Europe/Berlin'] = {
        '2024:07:14 14:00:00+02:00',
        '2024:07:14 12:00:00',
        '2024:07:14 14:00:00.000+02:00',
        '2024:07:14 14:00:00+02:00',
        '2024:01:15 13:00:00+01:00',
        '2024:01:15 12:00:00',
        '2024:01:15 13:00:00.000+01:00',
        '2024:01:15 13:00:00+01:00',
        '2024:07:14 14:00:01+02:00',
        '2024:07:14 12:00:01',
        '2024:07:14 14:00:01.000+02:00',
        '2024:07:14 14:00:01+02:00',
        '1970:01:01 00:59:59+01:00',
        '1969:12:31 23:59:59',
        '1970:01:01 00:59:58.750+01:00',
        '1970:01:01 00:59:58.75+01:00',
        '2024:07:14 12:00:00Z',
        '2024:07:14 12:00:00 +0200|+02:00|1720951200',
        '2024:01:15 12:00:00 +0100|+01:00|1705316400',
        '2024:07:14 12:00:00 +0530|+05:30|1720938600',
        '2024:01:15 12:00:00 +0000|+00:00|1705320000',
        '2024:03:31 03:30:00 +0100|+01:00|1711848600',
        '2024:10:27 02:30:00 +0200|+02:00|1729989000',
        '2024:11:03 01:30:00 +0100|+01:00|1730593800',
        '2024-07-14 12:00:00',
        '2024-01-15 12:00:00',
        '2024-07-14 12:00:00',
        '2024-01-15 12:00:00',
        '2024-03-31 03:30:00',
        '2024-10-27 02:30:00',
        '2024-11-03 01:30:00',
        '%z %+0200 1720951200%s',
        '%z %+0100 1705316400%s',
        '%z %+0530 1720938600%s',
        '%z %+0000 1705320000%s',
        '%z %+0100 1711848600%s',
        '%z %+0200 1729989000%s',
        '%z %+0100 1730593800%s',
    },
    ['UTC'] = {
        '2024:07:14 12:00:00+00:00',
        '2024:07:14 12:00:00',
        '2024:07:14 12:00:00.000+00:00',
        '2024:07:14 12:00:00+00:00',
        '2024:01:15 12:00:00+00:00',
        '2024:01:15 12:00:00',
        '2024:01:15 12:00:00.000+00:00',
        '2024:01:15 12:00:00+00:00',
        '2024:07:14 12:00:01+00:00',
        '2024:07:14 12:00:01',
        '2024:07:14 12:00:01.000+00:00',
        '2024:07:14 12:00:01+00:00',
        '1969:12:31 23:59:59+00:00',
        '1969:12:31 23:59:59',
        '1969:12:31 23:59:58.750+00:00',
        '1969:12:31 23:59:58.75+00:00',
        '2024:07:14 12:00:00Z',
        '2024:07:14 12:00:00 +0000|+00:00|1720958400',
        '2024:01:15 12:00:00 +0000|+00:00|1705320000',
        '2024:07:14 12:00:00 +0530|+05:30|1720938600',
        '2024:01:15 12:00:00 +0000|+00:00|1705320000',
        '2024:03:31 02:30:00 +0000|+00:00|1711852200',
        '2024:10:27 02:30:00 +0000|+00:00|1729996200',
        '2024:11:03 01:30:00 +0000|+00:00|1730597400',
        '2024-07-14 12:00:00',
        '2024-01-15 12:00:00',
        '2024-07-14 12:00:00',
        '2024-01-15 12:00:00',
        '2024-03-31 02:30:00',
        '2024-10-27 02:30:00',
        '2024-11-03 01:30:00',
        '%z %+0000 1720958400%s',
        '%z %+0000 1705320000%s',
        '%z %+0530 1720938600%s',
        '%z %+0000 1705320000%s',
        '%z %+0000 1711852200%s',
        '%z %+0000 1729996200%s',
        '%z %+0000 1730597400%s',
    },
}

-- the calls, mirroring the Perl reference script
local child = [=[
local ExifTool = require('lexiftool')
for _, tz in ipairs({ 'EST5EDT', 'Europe/Berlin', 'UTC' }) do
    local et = ExifTool.new()
    et:Options('TimeZone', tz)
    local r = {}
    for _, t in ipairs({ 1720958400, 1705320000, 1720958400.9996, -1.25 }) do
        r[#r + 1] = ExifTool.ConvertUnixTime(t, 1)
        r[#r + 1] = ExifTool.ConvertUnixTime(t)
        r[#r + 1] = ExifTool.ConvertUnixTime(t, 1, 3)
        r[#r + 1] = ExifTool.ConvertUnixTime(t, 1, -3)
    end
    et:Options('KeepUTCTime', 1)
    r[#r + 1] = ExifTool.ConvertUnixTime(1720958400, 1)
    et:Options('KeepUTCTime', 0)
    for _, fmt in ipairs({ '%Y:%m:%d %H:%M:%S %z|%:z|%s', '%Y-%m-%d %H:%M:%S', '%%z %%%z %s%%s' }) do
        et:Options('DateFormat', fmt)
        for _, d in ipairs({ '2024:07:14 12:00:00', '2024:01:15 12:00:00', '2024:07:14 12:00:00+05:30',
                             '2024:01:15 12:00:00Z', '2024:03:31 02:30:00', '2024:10:27 02:30:00',
                             '2024:11:03 01:30:00' }) do
            r[#r + 1] = et:ConvertDateTime(d)
        end
    end
    io.write(tz, '\t', table.concat(r, '\t'), '\n')
end
]=]

-- the interpreter running this test, for the child process
local lua = TestLib.LUA
do
    local i = -1
    while arg and arg[i - 1] do i = i - 1; lua = arg[i] end
end

if lua and package.config:sub(1, 1) ~= '\\' then
    local f = TestLib.TEST_DIR .. '/timezone_port.tmp'
    local fh = assert(io.open(f, 'wb'))
    fh:write(child)
    fh:close()
    local p = io.popen(lua .. " '" .. f .. "' 2>&1")
    local out = p:read('a')
    p:close()
    os.remove(f)
    local seen = 0
    for line in out:gmatch('[^\n]+') do
        local fields = {}
        for v in (line .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = v end
        local tz = table.remove(fields, 1)
        local exp = expected[tz]
        ok(exp ~= nil, 'child output line for a known zone: ' .. line)
        if exp then
            seen = seen + 1
            is(#exp, #fields, tz .. ': number of values')
            for i = 1, #exp do
                is(exp[i], fields[i], tz .. ': value ' .. i)
            end
        end
    end
    is(3, seen, 'all three zones reported')
end

-- 3. DateFormat in the locale of the environment.  Perl reference, per
--   LC_ALL value (perl -I vendor/exiftool/lib, without POSIX::strptime, so
--   InverseDateTime uses Time::Piece and its use_locale like the port):
--   POSIX::strftime('%A %d %B %Y', 0, 0, 12, 14, 6, 124); with DateFormat
--   '%A %d %B %Y %H:%M': $s = ConvertDateTime('2024:07:14 18:30:00'),
--   InverseDateTime($s), of 'Mittwoch 04 Dezember 2003 06:46' and of
--   'Wednesday 04 December 2003 06:46' (undef when it fails); then
--   SetNewValue('DateTimeOriginal', $s) + WriteInfo to a copy of Canon.jpg,
--   and DateTimeOriginal read back with that DateFormat and without one
local expectedLocale = {
    ['C'] = {
        'Sunday 14 July 2024',
        'Sunday 14 July 2024 18:30',
        '2024:07:14 18:30:00',
        'undef',
        '2003:12:04 06:46:00',
        '1',
        'Sunday 14 July 2024 18:30',
        '2024:07:14 18:30:00',
    },
    ['de_DE.UTF-8'] = {
        'Sonntag 14 Juli 2024',
        'Sonntag 14 Juli 2024 18:30',
        '2024:07:14 18:30:00',
        '2003:12:04 06:46:00',
        'undef',
        '1',
        'Sonntag 14 Juli 2024 18:30',
        '2024:07:14 18:30:00',
    },
}

-- the calls; the line starts and ends with the process locale (all
-- categories, then LC_TIME), and closes with whether the system has the
-- locale at all (asked last, as it switches LC_TIME of the child)
local childLocale = [=[
local src, dst, loc = ...
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local r = { os.setlocale(nil), os.setlocale(nil, 'time') }
local function add(v) r[#r + 1] = v == nil and 'undef' or tostring(v) end
local et = ExifTool.new()
et:Options('DateFormat', '%A %d %B %Y %H:%M')
local s = et:ConvertDateTime('2024:07:14 18:30:00')
add(perl.strftime('%A %d %B %Y', 0, 0, 12, 14, 6, 124))
add(s)
add(et:InverseDateTime(s))
add(et:InverseDateTime('Mittwoch 04 Dezember 2003 06:46'))
add(et:InverseDateTime('Wednesday 04 December 2003 06:46'))
os.remove(dst)
et:SetNewValue('DateTimeOriginal', s)
add(et:WriteInfo(src, dst))
local et2 = ExifTool.new()
et2:Options('DateFormat', '%A %d %B %Y %H:%M')
add(et2:ImageInfo(dst, 'DateTimeOriginal').DateTimeOriginal)
et2:Options('DateFormat', nil)
add(et2:ImageInfo(dst, 'DateTimeOriginal').DateTimeOriginal)
os.remove(dst)
add(os.setlocale(nil))
add(os.setlocale(nil, 'time'))
add(os.setlocale(loc, 'time') ~= nil)
io.write(table.concat(r, '\t'), '\n')
]=]

if lua and package.config:sub(1, 1) ~= '\\' then
    local f = TestLib.TEST_DIR .. '/timezone_port_locale.tmp'
    local dst = TestLib.TEST_DIR .. '/timezone_port_locale.jpg'
    local fh = assert(io.open(f, 'wb'))
    fh:write(childLocale)
    fh:close()
    for _, loc in ipairs({ 'C', 'de_DE.UTF-8' }) do
        local p = io.popen('LC_ALL=' .. loc .. ' ' .. lua .. " '" .. f .. "' '" .. TestLib.T_DIR ..
                           "/images/Canon.jpg' '" .. dst .. "' " .. loc .. ' 2>/dev/null')
        local out = p:read('a')
        p:close()
        local fields = {}
        for v in (out:gsub('\n$', '') .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = v end
        local exp = expectedLocale[loc]
        is(#exp + 5, #fields, loc .. ': number of values')
        is('C', fields[1], loc .. ': process locale before')
        is('C', fields[2], loc .. ': LC_TIME before')
        is('C', fields[#exp + 3], loc .. ': process locale after')
        is('C', fields[#exp + 4], loc .. ': LC_TIME after')
        if fields[#exp + 5] == 'true' then
            for i = 1, #exp do
                is(exp[i], fields[i + 2], loc .. ': value ' .. i)
            end
        else
            ok(true, loc .. ': locale not installed, values skipped')
        end
    end
    os.remove(f)
end
