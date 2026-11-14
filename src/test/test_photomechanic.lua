--------------------------------------------------------------------------------
-- File:         test/test_photomechanic.lua
-- Ported from:  t/PhotoMechanic.t
--
-- Description:  Lua port of test 2 of the upstream PhotoMechanic.t (the Perl
--               original): extracts information from
--               t/images/PhotoMechanic.jpg and compares against the vendored
--               standard output (t/PhotoMechanic_2.out).
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

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PhotoMechanic'
local testnum = 1

-- test 2: Extract information from PhotoMechanic.jpg
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PhotoMechanic.jpg', { Duplicates = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Test writing some information
do
    local writeInfo = {
        { 'Rotation', 90 },
        { 'Keywords', 'PhotoMechanic' },
    }
    ok(writeCheck(writeInfo, testname, 3, nil, 1), 'test 3 matches')
end

done() -- end
