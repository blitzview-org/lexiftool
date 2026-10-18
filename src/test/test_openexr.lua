--------------------------------------------------------------------------------
-- File:         test/test_openexr.lua
-- Ported from:  t/OpenEXR.t
--
-- Description:  Lua port of test 2 of the upstream OpenEXR.t (the Perl
--               original): extracts information from t/images/OpenEXR.exr
--               and compares against the vendored standard output
--               (t/OpenEXR_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is
--               ported (the OpenEXR header/attribute reader).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'OpenEXR'

-- test 2: Extract information from OpenEXR.exr
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/OpenEXR.exr')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
