--------------------------------------------------------------------------------
-- File:         test/test_time_local.lua
--
-- Description:  The library's Time::Local callers on out-of-range dates,
--               which the upstream tests do not reach. The expected values
--               are what `perl -I vendor/exiftool/lib` returns for the same
--               library calls (the croak text without its " at FILE line
--               N." tail, which differs by nature):
--                 1. GetUnixTime: timegm's result, fractional seconds and
--                    the time zone suffix, and its croak passed on to the
--                    caller (no eval of its own)
--                 2. ShiftTime: the "hard way" swallows a croak and keeps
--                    no offset; a shift from the saved offset returns the
--                    croak as its error, quoting the date's own strings
--                 3. Geotag: a track log with an impossible date stops at
--                    the croak (SetNewValue's error), and Geotime then
--                    finds an empty track
--               Only calls whose result does not depend on the local time
--               zone are used.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local Shift = require('lexiftool.Shift')

local is, ok = TestLib.is, TestLib.ok

-- the croak text as CleanWarning leaves it
local function croakText(e)
    if not perl.isDie(e) then return 'not a Perl die: ' .. tostring(e) end
    return ExifTool.CleanWarning(e.msg)
end

-- 1. GetUnixTime
do
    local rows = {
        { { '2007:01:01 12:00:01.25' }, 1167652801.25 },
        { { '2007:01:01 12:00:01.5+01:00', 1 }, 1167649201.5 },
        { { '2007:01:01 12:00:01Z', 1 }, 1167652801 },
        { { '2007:01:01 12:00:01', 2 }, 1167652801 },
        { { '2007:01:01 12:00:01 x-02:30', 1 }, 1167661801 },
        { { '0000:00:00 00:00:00' }, 0 },
        { { 'garbage' }, nil },
        { { '2007:02:30 00:00:00' }, "Day '30' out of range 1..28" },
        { { '2007:02:30 00:00:00', 1 }, "Day '30' out of range 1..28" },
        { { '2007:00:10 00:00:00' }, "Month '-1' out of range 0..11" },
        { { '2007-01-01 23:59:60' }, "Second '60' out of range 0..59" },
    }
    for i, row in ipairs(rows) do
        local okc, res = pcall(ExifTool.GetUnixTime, row[1][1], row[1][2])
        local name = 'GetUnixTime row ' .. i .. ' (' .. row[1][1] .. ')'
        if type(row[2]) == 'string' then
            ok(not okc, name .. ' croaks')
            is(row[2], okc and res or croakText(res), name .. ' message')
        elseif okc then
            is(row[2], res, name)
        else
            is(row[2], croakText(res), name)
        end
    end
    -- a two-digit year is Time::Local's: the rolling century window (this
    -- expectation holds while the window's breakpoint is 7 or more)
    local thisYear = os.date('*t').year - 1900
    if (thisYear + 50) % 100 >= 7 then
        is(1167609600, ExifTool.GetUnixTime('07:01:01 00:00:00'), 'GetUnixTime: two-digit year')
    end
end

-- 2. ShiftTime (date/time string, shift, direction, saved offsets)
do
    local rows = {
        -- from a saved offset: the croak is the error, the value unchanged
        { '2007-30-01', '0:0:1 0', { Date = 86400 }, nil, "Month '29' out of range 0..11", 'Date=86400' },
        { '7/18/05 2:33 PM', '1', { DateTime = 3600 }, nil, "Month '17' out of range 0..11", 'DateTime=3600' },
        { '2007:01:00 05:00:00', '1', { DateTime = 3600 }, nil, "Day '00' out of range 1..31", 'DateTime=3600' },
        { '2007:01:10 25:00:00', '1', { DateTime = 3600 }, nil, "Hour '25' out of range 0..23", 'DateTime=3600' },
        { '2007:01:10 05:00:00', '1', { DateTime = 3600 }, '2007:01:10 06:00:00', nil, 'DateTime=3600' },
        -- the hard way: shifted component by component, no offset saved
        { '2007:30:01', '0:0:1 0', { }, '2009:06:02', nil, '' },
        { '2007:01:00 05:00:00', '1', { }, '2006:12:31 06:00:00', nil, '' },
    }
    for i, row in ipairs(rows) do
        local off = row[3]
        local val, err = Shift.ShiftTime(row[1], row[2], 1, off)
        local keys = { }
        for k, v in pairs(off) do keys[#keys + 1] = k .. '=' .. perl.str(v) end
        perl.tsort(keys)
        local name = 'ShiftTime row ' .. i .. ' (' .. row[1] .. ')'
        is(row[4], val, name .. ' value')
        is(row[5], err, name .. ' error')
        is(row[6], table.concat(keys, ','), name .. ' saved offsets')
    end
end

-- 3. Geotag: SetNewValue's error for the track log, then Geotime's
do
    local rows = {
        { 'TP,D, 44.933666667, -93.186555556, 02/30/2011, 19:07:28, 0\n',
          0, "Day '30' out of range 1..28 in File:Geotag (ValueConvInv)",
          0, 'GPS track is empty in File:Geotime (ValueConvInv)' },
        { 'TP,D, 44.933666667, -93.186555556, 10/00/2011, 19:07:28, 0\n',
          0, "Day '00' out of range 1..31 in File:Geotag (ValueConvInv)",
          0, 'GPS track is empty in File:Geotime (ValueConvInv)' },
        { 'TP,D, 44.933666667, -93.186555556, 10/26/2011, 19:07:28, 0\n',
          1, nil, 1, nil },
    }
    for i, row in ipairs(rows) do
        local et = ExifTool.new()
        local n, err = et:SetNewValue('Geotag', row[1])
        local n2, err2 = et:SetNewValue('Geotime', '2011:10:26 19:07:28Z')
        local name = 'Geotag row ' .. i
        is(row[2], n, name .. ': Geotag count')
        is(row[3], err, name .. ': Geotag error')
        is(row[4], n2, name .. ': Geotime count')
        is(row[5], err2, name .. ': Geotime error')
    end
end

TestLib.done()
