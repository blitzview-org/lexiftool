--------------------------------------------------------------------------------
-- File:         test/test_plus.lua
-- Ported from:  t/PLUS.t
--
-- Description:  Lua port of test 2 of the upstream PLUS.t (the Perl
--               original): extracts the XMP tags from t/images/PLUS.xmp and
--               compares against the vendored standard output (t/PLUS_2.out).
--
-- Port notes:   Tests 2 and 3 of the upstream numbering are ported (test 3
--               copies PLUS.xmp into a new .xmp created from scratch,
--               WriteInfo(undef, $file), compared against PLUS_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local writeInfo = TestLib.writeInfo
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PLUS'
local testnum = 1

-- test 2: Extract information from PLUS.xmp
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PLUS.xmp', 'xmp:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Copy PLUS information to a new file
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/PLUS.xmp', 'all:all')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    local wrote = writeInfo(exifTool, nil, testfile)
    local info = exifTool:ImageInfo(testfile, 'xmp:all')
    local success = check(exifTool, info, testname, testnum, 2) and wrote
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

done() -- end
