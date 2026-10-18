--------------------------------------------------------------------------------
-- File:         test/test_indesign.lua
-- Ported from:  t/InDesign.t
--
-- Description:  Lua port of the upstream InDesign.t (the Perl original):
--               extracts information from t/images/InDesign.indd (the XMP
--               stream embedded in the InDesign object database), then
--               writes XMP tags into it and deletes them again (tests 3-4),
--               comparing against the vendored standard output.
--
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local TEST_DIR = TestLib.TEST_DIR

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'InDesign'

-- test 2: Extract information from InDesign.indd
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/InDesign.indd')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- tests 3-4: Write some XMP tags then delete all XMP (writes empty XMP record)
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('Author', 'Phil Harvey')
    exifTool:SetNewValue('ImageDescription', 'A description')
    local testfile = TEST_DIR .. '/' .. testname .. '_3_failed.indd'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/InDesign.indd', testfile)
    local info = exifTool:ImageInfo(testfile)
    local notOk = not check(exifTool, info, testname, 3)
    ok(not notOk, 'test 3 matches')

    exifTool:Options('PrintConv', 0)
    exifTool:SetNewValue()
    exifTool:SetNewValue('XMP:*')
    local testfile2 = TEST_DIR .. '/' .. testname .. '_4_failed.indd'
    os.remove(testfile2)
    exifTool:WriteInfo(testfile, testfile2)
    info = exifTool:ImageInfo(testfile2)
    local success = check(exifTool, info, testname, 4)
    if success then
        if not notOk then os.remove(testfile) end
        os.remove(testfile2)
    end
    ok(success, 'test 4 matches')
end

done()
