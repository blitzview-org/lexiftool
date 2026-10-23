--------------------------------------------------------------------------------
-- File:         test/test_garmin.lua
-- Ported from:  t/Garmin.t
--
-- Description:  Lua port of Garmin.t: extracts information from
--               t/images/Garmin.fit and compares against the vendored
--               standard output (t/Garmin_2.out), with the upstream
--               test's ExtractEmbedded and Unknown options enabled.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Garmin'

-- test 2: Extract information from Garmin.fit (ExtractEmbedded + Unknown)
do
    local exifTool = lexiftool.new()
    exifTool:Options('ExtractEmbedded', 1)
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/Garmin.fit')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
