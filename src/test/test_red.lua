--------------------------------------------------------------------------------
-- File:         test/test_red.lua
-- Ported from:  t/Red.t
--
-- Description:  Lua port of test 2 of the upstream Red.t (the Perl
--               original): extracts information from t/images/Red.r3d and
--               compares against the vendored standard output (t/Red_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the R3D block reader with the version-1/version-2 header
--               dispatch and the Red-directory tag walker).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Red'

-- test 2: Extract information from Red.r3d
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Red.r3d')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
