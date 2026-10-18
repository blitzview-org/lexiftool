--------------------------------------------------------------------------------
-- File:         test/test_djvu.lua
-- Ported from:  t/DjVu.t
--
-- Description:  Lua port of test 2 of the upstream DjVu.t (the Perl
--               original): extracts information from t/images/DjVu.djvu
--               and compares against the vendored standard output
--               (t/DjVu_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'DjVu'

-- test 2: Extract information from DjVu.djvu
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/DjVu.djvu')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
