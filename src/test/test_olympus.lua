--------------------------------------------------------------------------------
-- File:         test/test_olympus.lua
-- Ported from:  t/Olympus.t
--
-- Description:  Lua port of the upstream Olympus.t (the Perl original):
--               extracts information from t/images/Olympus.jpg,
--               t/images/OlympusE1.jpg, t/images/Olympus2.jpg and
--               t/images/Olympus.dss and compares against the vendored
--               standard output.
--
-- Port notes:   Tests 2-8 of the upstream numbering are ported.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local testVerbose = TestLib.testVerbose
local TEST_DIR = TestLib.TEST_DIR
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Olympus'

-- test 2: Extract information from Olympus.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Olympus.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'Software', 'ExifTool', { Group = 'XMP' } },
        { 'Macro', 'On' },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Extract information from OlympusE1.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/OlympusE1.jpg')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

-- test 5: Rewrite Olympus E1 image
do
    local writeInfo = {
        { 'LensSerialNumber', '012345678' },
        { 'CoringFilter', 0 },
    }
    ok(writeCheck(writeInfo, testname, 5, T_DIR .. '/images/OlympusE1.jpg'), 'test 5 matches')
end

-- test 6: Test reading Olympus type 2 maker notes
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Olympus2.jpg')
    ok(check(exifTool, info, testname, 6), 'test 6 matches')
end

-- test 7: Rewrite type 2 maker notes
-- (write path, out of scope)

-- test 7: Rewrite type 2 maker notes
do
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_7_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('FocusDistance', 100)
    exifTool:SetNewValue('Macro', 'On')
    exifTool:WriteInfo(T_DIR .. '/images/Olympus2.jpg', testfile)
    local success = testVerbose(testname, 7, testfile, 2)
    if success then os.remove(testfile) end
    ok(success, 'test 7 matches')
end

-- test 8: Extract information from Olympus.dss
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Olympus.dss')
    ok(check(exifTool, info, testname, 8), 'test 8 matches')
end

done() -- end
