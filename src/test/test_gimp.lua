--------------------------------------------------------------------------------
-- File:         test/test_gimp.lua
-- Ported from:  t/GIMP.t
--
-- Description:  Lua port of test 2 of the upstream GIMP.t (the Perl
--               original): extracts information from t/images/GIMP.xcf
--               and compares against the vendored standard output
--               (t/GIMP_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'GIMP'

-- test 2: Extract information from GIMP.xcf
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/GIMP.xcf')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
