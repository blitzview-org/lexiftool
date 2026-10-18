--------------------------------------------------------------------------------
-- File:         test/test_ge.lua
-- Ported from:  t/GE.t
--
-- Description:  Lua port of the upstream GE.t (the Perl original):
--               extracts information from t/images/GE.jpg and writes some
--               new information, comparing against the vendored standard
--               output (t/GE_2.out, t/GE_3.out).
--
-- Port notes:   All tests are ported (test 2 with the same `Unknown => 1`
--               option the upstream test uses).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'GE'

-- test 2: Extract information from GE.jpg
do
    local exifTool = lexiftool.new()
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/GE.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local testnum = 3
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('GEModel', 'test model')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/GE.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, { Duplicates = 1, Unknown = 1 })
    local success = check(exifTool, info, testname, testnum)
    if success then os.remove(testfile) end
    ok(success, 'test 3 matches')
end

done() -- end
