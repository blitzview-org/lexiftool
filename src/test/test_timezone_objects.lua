--------------------------------------------------------------------------------
-- File:         test/test_timezone_objects.lua
--
-- Description:  The TimeZone option belongs to its ExifTool object (port:
--               upstream writes $ENV{TZ} and calls tzset, so in Perl the
--               zone set last applies to the whole process; see
--               doc/differences.md):
--                 1. two objects with different zones give their own local
--                    times -- localtime (FileModifyDate through
--                    ConvertUnixTime), mktime and %Z (DateFormat through
--                    strftime), %z (TimeLocal) -- also interleaved
--                 2. an object without the option, and a library function
--                    called outside any object, use the system's zone
--                 3. the environment (TZ) and the localtime of the process
--                    stay as they were
--                 4. a helper object without a zone, used inside the call of
--                    an object with one, takes that one (as the process-wide
--                    zone does in Perl)
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local ExifTool = require('lexiftool')

local is = TestLib.is

local T = 1720958400        -- 2024-07-14 12:00:00 UTC
local FMT = '%Y:%m:%d %H:%M:%S %z %Z'

-- the process before
local envBefore = os.getenv('TZ')
local dateBefore = os.date('%Y:%m:%d %H:%M:%S %z %Z', T)

-- a copy of an image whose mtime is T
local src = TestLib.T_DIR .. '/images/ExifTool.jpg'
local file = TestLib.TEST_DIR .. '/timezone_objects.jpg'
do
    local i = assert(io.open(src, 'rb'))
    local data = i:read('a')
    i:close()
    local o = assert(io.open(file, 'wb'))
    o:write(data)
    o:close()
    assert(require('lfs').touch(file, T, T))
end

-- (Windows reads a TZ value as its C runtime does: no zone IDs, the first
-- three letters name the zone, DST follows the US rules)
local isWin = require('lexiftool.perl').osname() == 'MSWin32'
local zoneB = isWin and 'CET-1CEST' or 'Europe/Berlin'
local summerB = isWin and 'CES' or 'CEST'

local etA = ExifTool:new()
etA:Options('TimeZone', 'EST5EDT')
local etB = ExifTool:new()
etB:Options('TimeZone', zoneB)
local etC = ExifTool:new()

-- the system's local time of t, as ConvertUnixTime writes it (the offset
-- from the local and UTC fields, as GetTimeZone takes it)
local function systemLocal(t)
    local l, u = os.date('*t', t), os.date('!*t', t)
    local min = (l.hour - u.hour) * 60 + (l.min - u.min)
    if l.day ~= u.day then min = min + ((l.year * 1000 + l.yday > u.year * 1000 + u.yday) and 1440 or -1440) end
    local a = math.abs(min)
    return os.date('%Y:%m:%d %H:%M:%S', t) ..
           ('%s%02d:%02d'):format(min < 0 and '-' or '+', a // 60, a % 60)
end

-- 1. each object its own zone, interleaved
local function fileDate(et)
    return et:ImageInfo(file, 'FileModifyDate').FileModifyDate
end
is('2024:07:14 08:00:00-04:00', fileDate(etA), 'EST5EDT object: FileModifyDate')
is('2024:07:14 14:00:00+02:00', fileDate(etB), zoneB .. ' object: FileModifyDate')
is(systemLocal(T), fileDate(etC), 'object without TimeZone: the system zone')
is('2024:07:14 08:00:00-04:00', fileDate(etA), 'EST5EDT object again, after the others')

for _, et in ipairs({ etA, etB, etC }) do et:Options('DateFormat', FMT) end
is('2024:07:14 12:00:00 -0400 EDT', etA:ConvertDateTime('2024:07:14 12:00:00'), 'EST5EDT: DateFormat %z %Z')
is('2024:01:15 12:00:00 +0100 CET', etB:ConvertDateTime('2024:01:15 12:00:00'), zoneB .. ': winter')
is('2024:07:14 12:00:00 +0200 ' .. summerB, etB:ConvertDateTime('2024:07:14 12:00:00'), zoneB .. ': summer')
-- (a summer of the US-wide rules: EST5EDT's other summers before 1967 depend
-- on the tzdata release -- those rules in the old one, New York's in the one
-- where it is a link)
is('1918:07:14 12:00:00 -0400 EDT', etA:ConvertDateTime('1918:07:14 12:00:00'), 'EST5EDT: before 1970')
is('2050:01:15 12:00:00 -0500 EST', etA:ConvertDateTime('2050:01:15 12:00:00'), 'EST5EDT: after 2038')
do
    local t = os.time({ year = 2024, month = 7, day = 14, hour = 12 })
    is('2024:07:14 12:00:00 ' .. os.date('%z %Z', t), etC:ConvertDateTime('2024:07:14 12:00:00'),
       'object without TimeZone: DateFormat in the system zone')
end
is('2024:07:14 08:00:00 -0400 EDT', etA:GetValue('FileModifyDate'),
   'EST5EDT: PrintConv in GetValue, after the other objects ran')

-- 2. a library function outside any object: the system zone
is(systemLocal(T), ExifTool.ConvertUnixTime(T, 1), 'ConvertUnixTime outside an object: the system zone')

-- 3. the process is untouched
is(envBefore, os.getenv('TZ'), 'TZ of the environment unchanged')
is(dateBefore, os.date('%Y:%m:%d %H:%M:%S %z %Z', T), 'localtime of the process unchanged')

-- 4. a helper object inside the call of an object with a zone: here a
--    conversion run for etA through a fresh object's method (as Geotag's
--    track reader runs inside the Geotag write of the object that set it)
do
    local helper = ExifTool:new()
    -- a method of etA (its self is etA) that calls into the helper object
    function etA.LexiftoolTestHook(self)
        return helper:ImageInfo(file, 'FileModifyDate').FileModifyDate, self
    end
    local got = etA:LexiftoolTestHook()
    etA.LexiftoolTestHook = nil
    is('2024:07:14 08:00:00-04:00', got, 'a helper object inside an EST5EDT call takes EST5EDT')
    is(systemLocal(T), helper:ImageInfo(file, 'FileModifyDate').FileModifyDate,
       'the same helper on its own: the system zone')
end

-- an object's zone can be replaced; TimeZone => undef keeps it (as tzset is
-- not called then)
etB:Options('TimeZone', 'UTC')
is('2024:07:14 12:00:00 +0000 UTC', etB:ImageInfo(file, 'FileModifyDate').FileModifyDate, 'TimeZone replaced by UTC')
etB:Options('TimeZone', nil)
is('2024:07:14 12:00:00 +0000 UTC', etB:ImageInfo(file, 'FileModifyDate').FileModifyDate, 'TimeZone undef keeps UTC')

os.remove(file)
