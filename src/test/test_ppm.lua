--------------------------------------------------------------------------------
-- File:         test/test_ppm.lua
-- Ported from:  t/PPM.t
--
-- Description:  Lua port of test 2 of the upstream PPM.t (the Perl
--               original): extracts information from t/images/PPM.ppm and
--               compares against the vendored standard output
--               (t/PPM_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PPM'

-- test 2: Extract information from PPM.ppm
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PPM.ppm')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
