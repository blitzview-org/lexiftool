--------------------------------------------------------------------------------
-- File:         test/test_psp.lua
-- Ported from:  t/PSP.t
--
-- Description:  Lua port of test 2 of the upstream PSP.t (the Perl
--               original): extracts information from t/images/PSP.psp and
--               compares against the vendored standard output (t/PSP_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the main-block reader + image/creator/extended readers).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PSP'

-- test 2: Extract information from PSP.psp
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PSP.psp')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
