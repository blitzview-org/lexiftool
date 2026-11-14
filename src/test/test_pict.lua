--------------------------------------------------------------------------------
-- File:         test/test_pict.lua
-- Ported from:  t/PICT.t
--
-- Description:  Lua port of test 2 of the upstream PICT.t (the Perl
--               original): extracts information from t/images/PICT.pict and
--               compares against the vendored standard output
--               (t/PICT_2.out).
--
-- Port notes:   All upstream tests are ported -- PICT.t is read-only.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PICT'
local testnum = 1

-- test 2: Extract information from PICT.pict
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PICT.pict')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
