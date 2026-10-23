--------------------------------------------------------------------------------
-- File:         test/test_phaseone.lua
-- Ported from:  t/PhaseOne.t
--
-- Description:  Lua port of tests 1/2 of the upstream PhaseOne.t (the Perl
--               original): extracts information from t/images/PhaseOne.iiq
--               and compares against the vendored standard output
--               (t/PhaseOne_2.out).
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

local testname = 'PhaseOne'

-- test 2: Extract information from PhaseOne.iiq
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PhaseOne.iiq')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'SerialNumber', '1234' },
    }
    ok(writeCheck(writeInfo, testname, 3, T_DIR .. '/images/PhaseOne.iiq'), 'test 3 matches')
end

done() -- end
