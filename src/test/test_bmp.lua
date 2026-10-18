--------------------------------------------------------------------------------
-- File:         test/test_bmp.lua
-- Ported from:  t/BMP.t
--
-- Description:  Lua port of the upstream BMP.t (the Perl original):
--               extracts information from t/images/BMP.bmp and compares
--               against the vendored standard output (t/BMP_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'BMP'

-- test 2: Extract information from BMP.bmp
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/BMP.bmp')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
