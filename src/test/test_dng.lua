--------------------------------------------------------------------------------
-- File:         test/test_dng.lua
-- Ported from:  t/DNG.t
--
-- Description:  Lua port of tests 1/2 of the upstream DNG.t (the Perl
--               original): extracts information from t/images/DNG.dng and
--               compares against the vendored standard output
--               (t/DNG_2.out).
--
-- Port notes:   Tests 2 and 3 of the upstream numbering are ported.
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

local testname = 'DNG'

-- test 2: Extract information from DNG.dng
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/DNG.dng')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Test writing maker notes information
do
    local writeInfo = {
        { 'OwnerName', 'Just Me' },
        { 'OriginalDecisionData', "\xff\xff\xff\xff\x03\0\0\0\0\0\0\0\0\0\0\0\x08\0\0\0Test", { Protected = 1 } },
    }
    local tags = { 'OwnerName', 'OriginalDecisionData', 'Warning', 'Error' }
    ok(writeCheck(writeInfo, testname, 3, T_DIR .. '/images/DNG.dng', tags), 'test 3 matches')
end

done() -- end
