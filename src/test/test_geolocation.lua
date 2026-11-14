--------------------------------------------------------------------------------
-- File:         test/test_geolocation.lua
-- Ported from:  t/Geolocation.t
--
-- Description:  Lua port of the upstream Geolocation.t (the Perl original):
--               looks up geolocation information for t/images/GPS.jpg (2),
--               writes Geolocate with GPS (3), with a city name (4) and
--               together with Geotag (5), and -- for the remaining three --
--               looks up coordinates given directly via the Geolocation
--               option, with an empty in-memory file as the subject.
--               Compared against the vendored standard outputs
--               (t/Geolocation_<N>.out).
--
-- Port notes:   Tests 7/8 share one ExifTool object upstream and depend on
--               the AddEntry() call in test 7 still being in effect for
--               test 8 -- kept that way here.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local Geolocation = require('lexiftool.Geolocation')

local ok = TestLib.ok
local check = TestLib.check
local writeInfo = TestLib.writeInfo
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Geolocation'
local testnum = 1
local testfile

-- test 2: Test Geolocation option
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Geolocation', 1)
    exifTool:Options('GeolocMinPop', 5000)
    local info = exifTool:ImageInfo(T_DIR .. '/images/GPS.jpg', 'Geolocation*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Test writing Geolocate with GPS
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('GeolocMinPop', 1000000)
    exifTool:SetNewValue('Geolocate', '44,-72')
    exifTool:SetNewValue('IPTC:Geolocate', '48.338, 2.074')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, '-file:all')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 4: Test writing Geolocate with city name
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('Geolocate', 'Kingston,Ontario')
    exifTool:Options('Composite', 0)
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, '-file:all')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 5: Geotag with Geolocation
do
    local testTags = { 'Error', 'Warning', 'GPS:*', 'XMP:*', 'IPTC:*' }
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('IPTC:XMP:Geolocate', 'Geotag')
    exifTool:SetNewValue('Geotag', T_DIR .. '/images/Geotag.gpx')
    exifTool:SetNewValue('Geotime', '2003:05:24 17:09:31Z')
    exifTool:WriteInfo(T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, table.unpack(testTags))
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 6: Generate geolocation information from dummy file in memory,
--         returning the two nearest cities, avoiding PPLX features
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Geolocation', '48.1375,11.5755,num=2')
    exifTool:Options('GeolocFeature', '-PPLX')
    local dat = ''
    local info = exifTool:ImageInfo({ ref = 'SCALAR', value = dat }, 'geolocation*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- tests 7-8: Test regular expression with combined search with user-defined
--            database entry
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    Geolocation.AddEntry('Sinemorets', 'burgas', 'Obshtina Tsarevo',
        'BG', '', 'Europe/Sofia', '', 400, 42.06115, 27.97833, 'abcde,fghij,klmno')
    exifTool:Options('Geolocation', '1,2,co/Canada/')
    local dat = ''
    local info = exifTool:ImageInfo({ ref = 'SCALAR', value = dat }, 'geolocation*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    exifTool:Options('Geolocation', 'fghij')
    info = exifTool:ImageInfo({ ref = 'SCALAR', value = dat }, 'geolocation*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
