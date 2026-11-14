--------------------------------------------------------------------------------
-- File:         test/test_ape.lua
-- Ported from:  t/APE.t
--
-- Description:  Lua port of tests 2-3 of the upstream APE.t (the Perl
--               original): extracts information from t/images/APE.ape and
--               t/images/APE.mpc and compares against the vendored standard
--               output (t/APE_2.out, t/APE_3.out).
--
-- Port notes:   Read-only scope: tests 2-3 of the upstream numbering are
--               ported. Test 3 (APE.mpc, a Musepack file with ID3v1/ID3v2/
--               APE tags) exercises the ID3.ProcessID3 tail-scan dispatch
--               through MPC.ProcessMPC plus the APE trailer reader.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'APE'

-- test 2: Extract information from APE test file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/APE.ape')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from APE.mpc (ID3v1 + ID3v2 + APE)
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/APE.mpc')
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

done() -- end
