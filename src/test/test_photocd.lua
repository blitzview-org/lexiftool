--------------------------------------------------------------------------------
-- File:         test/test_photocd.lua
-- Ported from:  t/PhotoCD.t
--
-- Description:  Lua port of test 2 of the upstream PhotoCD.t (the Perl
--               original): extracts information from t/images/PhotoCD.pcd
--               and compares against the vendored standard output
--               (t/PhotoCD_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the PhotoCD header reader).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PhotoCD'

-- test 2: Extract information from PhotoCD.pcd
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PhotoCD.pcd')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
