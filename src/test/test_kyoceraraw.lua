--------------------------------------------------------------------------------
-- File:         test/test_kyoceraraw.lua
-- Ported from:  t/KyoceraRaw.t
--
-- Description:  Lua port of tests 1/2 of the upstream KyoceraRaw.t (the
--               Perl original): extracts information from
--               t/images/KyoceraRaw.raw and compares against the vendored
--               standard output (t/KyoceraRaw_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'KyoceraRaw'

-- test 2: Extract information from KyoceraRaw.raw
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/KyoceraRaw.raw')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
