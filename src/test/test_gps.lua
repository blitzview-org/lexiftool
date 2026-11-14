--------------------------------------------------------------------------------
-- File:         test/test_gps.lua
-- Ported from:  t/GPS.t
--
-- Description:  Lua port of the upstream GPS.t (the Perl original):
--               extracts information from t/images/GPS.jpg with a specified
--               coordinate format, and writes GPS tags, comparing against the
--               vendored standard outputs (t/GPS_N.out).
--
-- Port notes:   All tests of GPS.t, block for block.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local writeCheck = TestLib.writeCheck
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'GPS'
local testnum = 1

-- test 2: Extract information from GPS.jpg with specified coordinate format
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('CoordFormat', '%d degrees %.2f minutes')
    local info = exifTool:ImageInfo(T_DIR .. '/images/GPS.jpg')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Write some new information
do
    testnum = testnum + 1
    local writeInfo = {
        { 'GPSLatitude', "12 deg 21' 23.345" },
        { 'GPSLatitudeRef', 'south' },
        { 'GPSTimeStamp', '2007:03:02 18:46:10.55-05:30' },
        { 'GPSDateStamp', '2007:03:02 18:46:10.55-05:30' },
    }
    ok(writeCheck(writeInfo, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
