--------------------------------------------------------------------------------
-- File:         test/test_gopro.lua
-- Ported from:  t/GoPro.t
--
-- Description:  Lua port of test 2 of the upstream GoPro.t (the Perl
--               original): extracts information from the APP6 "GoPro"
--               segment of t/images/GoPro.jpg with the Unknown option on,
--               comparing against the vendored standard output. (There is no
--               upstream test 3+ -- GoPro.t ends at test 2.)
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

local testname = 'GoPro'

-- test 2: Extract information from GoPro.jpg (APP6 "GoPro" segment)
do
    local exifTool = lexiftool.new()
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/GoPro.jpg', 'gopro:all')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done()
