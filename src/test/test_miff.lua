--------------------------------------------------------------------------------
-- File:         test/test_miff.lua
-- Ported from:  t/MIFF.t
--
-- Description:  Lua port of test 2 of the upstream MIFF.t (the Perl
--               original): extracts information from t/images/MIFF.miff
--               and compares against the vendored standard output
--               (t/MIFF_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MIFF'

-- test 2: Extract information from a MIFF file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/MIFF.miff')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
