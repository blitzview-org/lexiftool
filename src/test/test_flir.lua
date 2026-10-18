--------------------------------------------------------------------------------
-- File:         test/test_flir.lua
-- Ported from:  t/FLIR.t
--
-- Description:  Lua port of tests 2 and 3 of the upstream FLIR.t (the Perl
--               original): extracts information from the APP1 FLIR segment
--               of t/images/FLIR.jpg and from the standalone FPF file
--               t/images/FLIR.fpf, comparing against the vendored standard
--               output. (Tests 4+ are write tests -- out of scope.)
--
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'FLIR'

-- test 2: Extract information from FLIR.jpg (APP1 FLIR segment + maker notes)
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FLIR.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from FLIR.fpf
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FLIR.fpf')
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

done()
