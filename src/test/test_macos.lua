--------------------------------------------------------------------------------
-- File:         test/test_macos.lua
-- Ported from:  t/MacOS.t
--
-- Description:  Lua port of test 2 of the upstream MacOS.t (the Perl
--               original): extracts information from t/images/MacOS.macos
--               (a MacOS "._" AppleDouble sidecar file) and compares against
--               the vendored standard output (t/MacOS_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MacOS'

-- test 2: Extract information from MacOS.macos
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/MacOS.macos')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
