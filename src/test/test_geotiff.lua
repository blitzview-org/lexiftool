--------------------------------------------------------------------------------
-- File:         test/test_geotiff.lua
-- Ported from:  t/GeoTiff.t
--
-- Description:  Lua port of the upstream GeoTiff.t (the Perl original):
--               extracts information from t/images/GeoTiff.tif and compares
--               against the vendored standard output (t/GeoTiff_2.out).
--               Test 3 (writeCheck) is ported too; test 4 (copying the
--               GeoTiff tags with SetNewValuesFromFile) is still open.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'GeoTiff'

-- test 2: Extract information from GeoTiff.tif
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/GeoTiff.tif')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = { { 'ResolutionUnit', 'cm' } }
    ok(writeCheck(writeInfo, testname, 3, T_DIR .. '/images/GeoTiff.tif'), 'test 3 matches')
end

-- test 4: Copy GeoTiff information
do
    local testnum = 4
    local exifTool = lexiftool.new()
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.out'
    os.remove(testfile)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/GeoTiff.tif', 'GeoTiff*')
    local wrote = TestLib.writeInfo(exifTool, T_DIR .. '/images/ExifTool.tif', testfile)
    local info = exifTool:ImageInfo(testfile, 'GeoTiff:*')
    if check(exifTool, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test 4 matches')
    else
        ok(false, 'test 4 matches')
    end
end

done() -- end
