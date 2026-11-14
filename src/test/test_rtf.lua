--------------------------------------------------------------------------------
-- File:         test/test_rtf.lua
-- Ported from:  t/RTF.t
--
-- Description:  Lua port of test 2 of the upstream RTF.t (the Perl
--               original): extracts information from t/images/RTF.rtf and
--               compares against the vendored standard output (t/RTF_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is
--               ported (the RTF \info-group and \userprops readers).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'RTF'

-- test 2: Extract information from RTF.rtf
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/RTF.rtf')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
