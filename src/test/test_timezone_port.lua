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
--                 4. "slim" and "fat" time zone files and "posixrules"
--                    (TZDIR on a copy in src/test/zoneinfo): the hour a DST
--                    period ends (it exists twice) and the one it begins
--                    (it does not exist) before, between and after the last
--                    explicit transitions, through TimeLocal and strftime's
--                    mktime
--               The calls run in a child process (3: one per locale, which
--               is read once per Lua state, as Perl does); the TimeZone
--               option belongs to its object (test_timezone_objects.lua).
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

-- 2024-03-31 02:30 does not exist in Berlin (values 22 and 29). Perl's
-- strftime runs the libc mktime on the fields as given (POSIX.xs isdst -1,
-- locale.c ints_to_tm): glibc's moves them on to 03:30, and so does
-- macOS's (tzcode time1 built with PCTS: the time taken as standard time,
-- then shifted into DST); %z/%s come from TimeLocal. On macOS the two
-- values are also compared with the Perl of the test run below.
local GAP_VALUES = { 22, 29 }
local isDarwin = require('lexiftool.perl').osname() == 'darwin'

-- the calls, mirroring the Perl reference script
local child = [=[
local ExifTool = require('lexiftool')
-- (the calls run inside a function whose first argument is the object, so
-- the library functions without one take its TimeZone, as in a method)
local function run(et, tz)
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
for _, tz in ipairs({ 'EST5EDT', 'Europe/Berlin', 'UTC' }) do
    local et = ExifTool:new()
    et:Options('TimeZone', tz)
    run(et, tz)
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
    local seen, berlin = 0, nil
    for line in out:gmatch('[^\n]+') do
        local fields = {}
        for v in (line .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = v end
        local tz = table.remove(fields, 1)
        if tz == 'Europe/Berlin' then berlin = fields end
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

    -- the time in the gap against the Perl of the test run (macOS only: the
    -- values above are those of Perl 5.42.1+, whose strftime lets the
    -- libc's mktime normalise the fields; a Perl before 5.42 normalises them
    -- by mini_mktime and keeps 02:30 -- so this assumes a current Perl).
    -- LEXIFTOOL_TEST_PERL set: a Perl that does not run is a failure
    if isDarwin then
        local wantPerl = rawget(_G, 'LEXIFTOOL_TEST_PERL')
        if wantPerl == '' then wantPerl = nil end
        local perlCmd = wantPerl or 'perl'
        if perlCmd:find('[^%w_./+-]') then
            perlCmd = "'" .. perlCmd:gsub("'", [['\'']]) .. "'"
        end
        local script = 'my $et = Image::ExifTool->new; $et->Options(TimeZone => "Europe/Berlin"); ' ..
                       'for my $f ("%Y:%m:%d %H:%M:%S %z|%:z|%s", "%Y-%m-%d %H:%M:%S") { ' ..
                       '$et->Options(DateFormat => $f); print $et->ConvertDateTime("2024:03:31 02:30:00"), "\\t" }'
        local p2 = io.popen(perlCmd .. " -I'" .. TestLib.REPO_DIR .. "/vendor/exiftool/lib' -MImage::ExifTool -e '" ..
                            script .. "' 2>/dev/null")
        local pout = p2 and p2:read('a') or ''
        if p2 then p2:close() end
        local pv = {}
        for v in pout:gmatch('([^\t]*)\t') do pv[#pv + 1] = v end
        if #pv == 2 then
            for i, n in ipairs(GAP_VALUES) do
                is(pv[i], berlin and berlin[n], 'Europe/Berlin: value ' .. n .. ' as the Perl of this run')
            end
        else
            ok(wantPerl == nil, 'Europe/Berlin: gap vs Perl SKIPPED: no Perl (' .. perlCmd .. ') to compare with')
        end
    end
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
local et = ExifTool:new()
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
local et2 = ExifTool:new()
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

-- 4. Time zone data as distributions ship it, with TZDIR pointing at a copy
--   of its own (src/test/zoneinfo, zic output of the tz database for
--   America/New_York and Europe/Berlin, New York also as "posixrules"):
--   "slim" files list the transitions only up to the last rule change and
--   leave the later years to the POSIX rule in their footer, "fat" ones list
--   them up to 2037; the fat copy has no EST5EDT, so that name is a POSIX
--   string taking the transitions of "posixrules" (as on a system without
--   the legacy names), and so is AAA3BBB in both. The years lie before the
--   last explicit transition of either kind (2005), between them (2024) and
--   after both (2040); the days are those of the US and the EU changes.
--   Perl reference (perl -I vendor/exiftool/lib, TZDIR set the same way, per
--   TimeZone value and year one ExifTool object with DateFormat '%H%M%z%Z'):
--   C: ConvertDateTime of, per day, a winter date, 01:30 and 02:30 of the
--      day, a summer date, 01:30, 02:30, 00:30 and 03:30 -- the hour that
--      exists twice and the one that does not exist, after a date with
--      either offset, as mktime starts from the offset of its previous call;
--      %z (from TimeLocal) and %H%M%Z (from strftime's mktime) both count
--   L: localtime from 00:00 UTC of each day in half-hour steps to 12:00,
--      each change of (UTC offset in minutes)/isdst with the time it starts
--      (the glibc reading, so taken from the "gnu" flavor on every Unix)
local expectedZoneinfo = {
    ['slim'] = {
        ['C EST5EDT 2005'] = {
            '1200-0500EST 0130-0500EST 0230-0500EST 1200-0400EDT 0130-0500EST 0230-0500EST 0030-0500EST 0330-0500EST',
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C EST5EDT 2024'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C EST5EDT 2040'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C America/New_York 2005'] = {
            '1200-0500EST 0130-0500EST 0230-0500EST 1200-0400EDT 0130-0500EST 0230-0500EST 0030-0500EST 0330-0500EST',
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C America/New_York 2024'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C America/New_York 2040'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C Europe/Berlin 2005'] = {
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
        },
        ['C Europe/Berlin 2024'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C Europe/Berlin 2040'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C CET-1CEST,M3.5.0,M10.5.0/3 2005'] = {
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
        },
        ['C CET-1CEST,M3.5.0,M10.5.0/3 2024'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C CET-1CEST,M3.5.0,M10.5.0/3 2040'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C AAA3BBB 2005'] = {
            '1200-0300AAA 0130-0300AAA 0230-0300AAA 1200-0200BBB 0130-0300AAA 0230-0300AAA 0030-0300AAA 0330-0300AAA',
            '1200-0300AAA 0130-0300AAA 0230-0300AAA 1200-0200BBB 0130-0300AAA 0230-0300AAA 0030-0300AAA 0330-0300AAA',
            '1200-0300AAA 0130-0200BBB 0230-0200BBB 1200-0200BBB 0130-0200BBB 0230-0200BBB 0030-0200BBB 0330-0200BBB',
        },
        ['C AAA3BBB 2024'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C AAA3BBB 2040'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['L EST5EDT 2005'] = {
            '-300/0@0000',
            '-300/0@0000 -240/1@0700',
            '-240/1@0000 -300/0@0600',
        },
        ['L EST5EDT 2024'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L EST5EDT 2040'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L America/New_York 2005'] = {
            '-300/0@0000',
            '-300/0@0000 -240/1@0700',
            '-240/1@0000 -300/0@0600',
        },
        ['L America/New_York 2024'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L America/New_York 2040'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L Europe/Berlin 2005'] = {
            '60/0@0000 120/1@0100',
            '120/1@0000',
            '120/1@0000 60/0@0100',
        },
        ['L Europe/Berlin 2024'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L Europe/Berlin 2040'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L CET-1CEST,M3.5.0,M10.5.0/3 2005'] = {
            '60/0@0000 120/1@0100',
            '120/1@0000',
            '120/1@0000 60/0@0100',
        },
        ['L CET-1CEST,M3.5.0,M10.5.0/3 2024'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L CET-1CEST,M3.5.0,M10.5.0/3 2040'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L AAA3BBB 2005'] = {
            '-180/0@0000',
            '-180/0@0000 -120/1@0900',
            '-120/1@0000 -180/0@0600',
        },
        ['L AAA3BBB 2024'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L AAA3BBB 2040'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
    },
    ['fat'] = {
        ['C EST5EDT 2005'] = {
            '1200-0500EST 0130-0500EST 0230-0500EST 1200-0400EDT 0130-0500EST 0230-0500EST 0030-0500EST 0330-0500EST',
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C EST5EDT 2024'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C EST5EDT 2040'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C America/New_York 2005'] = {
            '1200-0500EST 0130-0500EST 0230-0500EST 1200-0400EDT 0130-0500EST 0230-0500EST 0030-0500EST 0330-0500EST',
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C America/New_York 2024'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C America/New_York 2040'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['C Europe/Berlin 2005'] = {
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
        },
        ['C Europe/Berlin 2024'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C Europe/Berlin 2040'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C CET-1CEST,M3.5.0,M10.5.0/3 2005'] = {
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
        },
        ['C CET-1CEST,M3.5.0,M10.5.0/3 2024'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C CET-1CEST,M3.5.0,M10.5.0/3 2040'] = {
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
            '1200+0100CET 0130+0100CET 0330+0100CEST 1200+0200CEST 0130+0100CET 0330+0100CEST 0030+0100CET 0330+0200CEST',
            '1200+0100CET 0130+0200CEST 0230+0200CEST 1200+0200CEST 0130+0200CEST 0230+0200CEST 0030+0200CEST 0330+0100CET',
            '1200+0100CET 0130+0100CET 0230+0100CET 1200+0200CEST 0130+0100CET 0230+0100CET 0030+0100CET 0330+0100CET',
        },
        ['C AAA3BBB 2005'] = {
            '1200-0300AAA 0130-0300AAA 0230-0300AAA 1200-0200BBB 0130-0300AAA 0230-0300AAA 0030-0300AAA 0330-0300AAA',
            '1200-0300AAA 0130-0300AAA 0230-0300AAA 1200-0200BBB 0130-0300AAA 0230-0300AAA 0030-0300AAA 0330-0300AAA',
            '1200-0300AAA 0130-0200BBB 0230-0200BBB 1200-0200BBB 0130-0200BBB 0230-0200BBB 0030-0200BBB 0330-0200BBB',
        },
        ['C AAA3BBB 2024'] = {
            '1200-0300AAA 0130-0300AAA 0230-0300AAA 1200-0200BBB 0130-0300AAA 0230-0300AAA 0030-0300AAA 0330-0300AAA',
            '1200-0300AAA 0130-0200BBB 0230-0200BBB 1200-0200BBB 0130-0200BBB 0230-0200BBB 0030-0200BBB 0330-0200BBB',
            '1200-0300AAA 0130-0200BBB 0230-0200BBB 1200-0200BBB 0130-0200BBB 0230-0200BBB 0030-0200BBB 0330-0200BBB',
            '1200-0300AAA 0130-0200BBB 0230-0200BBB 1200-0200BBB 0130-0200BBB 0230-0200BBB 0030-0200BBB 0330-0200BBB',
        },
        ['C AAA3BBB 2040'] = {
            '1200-0500EST 0130-0500EST 0330-0500EDT 1200-0400EDT 0130-0500EST 0330-0500EDT 0030-0500EST 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EDT 0230-0400EDT 1200-0400EDT 0130-0400EDT 0230-0400EDT 0030-0400EDT 0330-0400EDT',
            '1200-0500EST 0130-0400EST 0230-0500EST 1200-0400EDT 0130-0400EDT 0230-0500EST 0030-0400EDT 0330-0500EST',
        },
        ['L EST5EDT 2005'] = {
            '-300/0@0000',
            '-300/0@0000 -240/1@0700',
            '-240/1@0000 -300/0@0600',
        },
        ['L EST5EDT 2024'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L EST5EDT 2040'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L America/New_York 2005'] = {
            '-300/0@0000',
            '-300/0@0000 -240/1@0700',
            '-240/1@0000 -300/0@0600',
        },
        ['L America/New_York 2024'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L America/New_York 2040'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
        ['L Europe/Berlin 2005'] = {
            '60/0@0000 120/1@0100',
            '120/1@0000',
            '120/1@0000 60/0@0100',
        },
        ['L Europe/Berlin 2024'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L Europe/Berlin 2040'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L CET-1CEST,M3.5.0,M10.5.0/3 2005'] = {
            '60/0@0000 120/1@0100',
            '120/1@0000',
            '120/1@0000 60/0@0100',
        },
        ['L CET-1CEST,M3.5.0,M10.5.0/3 2024'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L CET-1CEST,M3.5.0,M10.5.0/3 2040'] = {
            '60/0@0000',
            '60/0@0000 120/1@0100',
            '120/1@0000 60/0@0100',
            '60/0@0000',
        },
        ['L AAA3BBB 2005'] = {
            '-180/0@0000',
            '-180/0@0000 -120/1@0900',
            '-120/1@0000 -180/0@0600',
        },
        ['L AAA3BBB 2024'] = {
            '-180/0@0000 -120/1@0900',
            '-120/1@0000',
            '-120/1@0000',
            '-120/1@0000 -180/0@0600',
        },
        ['L AAA3BBB 2040'] = {
            '-300/0@0000 -240/1@0700',
            '-240/1@0000',
            '-240/1@0000',
            '-240/1@0000 -300/0@0600',
        },
    },
}

local childZoneinfo = [=[
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sys = require('lexiftool.sys')
local withChain = ...
local dates = {
    [2005] = { '03:27', '04:03', '10:30' },
    [2024] = { '03:10', '03:31', '10:27', '11:03' },
    [2040] = { '03:11', '03:25', '10:28', '11:04' },
}
for _, tz in ipairs({ 'EST5EDT', 'America/New_York', 'Europe/Berlin', 'CET-1CEST,M3.5.0,M10.5.0/3', 'AAA3BBB' }) do
    for _, y in ipairs({ 2005, 2024, 2040 }) do
        if withChain == '1' then
            local et = ExifTool:new()
            et:Options('TimeZone', tz)
            et:Options('DateFormat', '%H%M%z%Z')
            local r = {}
            for _, d in ipairs(dates[y]) do
                local g = {}
                for _, t in ipairs({ '01:15 12:00', d .. ' 01:30', d .. ' 02:30', '07:15 12:00', d .. ' 01:30',
                                     d .. ' 02:30', d .. ' 00:30', d .. ' 03:30' }) do
                    g[#g + 1] = et:ConvertDateTime(y .. ':' .. t .. ':00')
                end
                r[#r + 1] = table.concat(g, ' ')
            end
            io.write('C ', tz, ' ', y, '\t', table.concat(r, '\t'), '\n')
        end
        local z = sys.tz_new(tz, 'gnu')
        local r = {}
        for _, d in ipairs(dates[y]) do
            local m, dd = d:match('^(%d+):(%d+)$')
            local t0 = perl.timegm(0, 0, 0, tonumber(dd), tonumber(m) - 1, y)
            local g, prev = {}, ''
            for t = t0, t0 + 12 * 3600, 1800 do
                local _, _, _, _, _, _, _, _, isdst, gmtoff = sys.tz_localtime(z, t)
                local v = (gmtoff // 60) .. '/' .. isdst
                if v ~= prev then
                    g[#g + 1] = ('%s@%02d%02d'):format(v, (t - t0) // 3600, (t - t0) % 3600 // 60)
                end
                prev = v
            end
            r[#r + 1] = table.concat(g, ' ')
        end
        io.write('L ', tz, ' ', y, '\t', table.concat(r, '\t'), '\n')
    end
end
]=]

if lua and package.config:sub(1, 1) ~= '\\' then
    -- (macOS reads TZ through its own tzcode, which takes no TZDIR: the
    -- library calls there do not see this data, the "gnu" flavor does)
    local withChain = require('lexiftool.perl').osname() ~= 'darwin'
    local f = TestLib.TEST_DIR .. '/timezone_port_zoneinfo.tmp'
    local fh = assert(io.open(f, 'wb'))
    fh:write(childZoneinfo)
    fh:close()
    for _, kind in ipairs({ 'slim', 'fat' }) do
        local p = io.popen("TZDIR='" .. TestLib.TEST_DIR .. '/zoneinfo/' .. kind .. "' " .. lua .. " '" .. f ..
                           "' " .. (withChain and '1' or '0') .. ' 2>&1')
        local out = p:read('a')
        p:close()
        local seen = { C = 0, L = 0 }
        for line in out:gmatch('[^\n]+') do
            local fields = {}
            for v in (line .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = v end
            local key = table.remove(fields, 1)
            local exp = expectedZoneinfo[kind][key]
            ok(exp ~= nil, kind .. ': child output line for a known case: ' .. line)
            if exp then
                seen[key:sub(1, 1)] = seen[key:sub(1, 1)] + 1
                is(#exp, #fields, kind .. ' ' .. key .. ': number of days')
                for i = 1, #exp do
                    is(exp[i], fields[i], kind .. ' ' .. key .. ': day ' .. i)
                end
            end
        end
        is(withChain and 15 or 0, seen.C, kind .. ': all library cases reported')
        is(15, seen.L, kind .. ': all localtime cases reported')
    end
    os.remove(f)
end
