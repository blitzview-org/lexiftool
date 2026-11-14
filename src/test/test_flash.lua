--------------------------------------------------------------------------------
-- File:         test/test_flash.lua
-- Ported from:  t/Flash.t
--
-- Description:  Lua port of tests 2/3 of the upstream Flash.t (the Perl
--               original): extracts information from t/images/Flash.swf and
--               t/images/Flash.flv, comparing against the vendored standard
--               outputs (t/Flash_2.out, t/Flash_3.out).
--
-- Port notes:   All upstream tests are ported -- Flash.t is read-only.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Flash'
local testnum = 1

-- test 2: Extract information from Flash.swf
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Flash.swf')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Extract information from Flash.flv
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Flash.flv')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
