--------------------------------------------------------------------------------
-- File:         test/test_ricoh.lua
-- Ported from:  t/Ricoh.t
--
-- Description:  Lua port of tests 1/2/4 of the upstream Ricoh.t (the Perl
--               original): extracts information from t/images/Ricoh.jpg and
--               t/images/Ricoh2.jpg (the APP5 RMETA format) and compares
--               against the vendored standard output (t/Ricoh_2.out,
--               t/Ricoh_4.out).
--
-- Port notes:   Tests 2-4 of the upstream numbering are ported.
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

local testname = 'Ricoh'

-- test 2: Extract information from Ricoh.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Ricoh.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'Ricoh:Sharpness', 'Soft' },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Test extracting Ricoh APP5 RMETA information
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Ricoh2.jpg')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

done() -- end
