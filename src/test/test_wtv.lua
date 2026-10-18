--------------------------------------------------------------------------------
-- File:         test/test_wtv.lua
-- Ported from:  t/WTV.t
--
-- Description:  Lua port of test 2 of the upstream WTV.t (the Perl
--               original): extracts information from t/images/WTV.wtv and
--               compares against the vendored standard output (t/WTV_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the WTV-directory reader + the metadata-record reader).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'WTV'

-- test 2: Extract information from WTV.wtv
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/WTV.wtv')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
