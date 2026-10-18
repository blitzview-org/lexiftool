--------------------------------------------------------------------------------
-- File:         test/test_m2ts.lua
-- Ported from:  t/M2TS.t
--
-- Description:  Lua port of test 2 of the upstream M2TS.t (the Perl
--               original): extracts information from t/images/M2TS.mts
--               (MPEG-2 transport stream: PAT/PMT walk, AC-3 audio
--               descriptor, H.264 SPS image size and MDPM camera data)
--               with the Unknown option on, comparing against the vendored
--               standard output.
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

local testname = 'M2TS'

-- test 2: Extract information from M2TS.mts
do
    local exifTool = lexiftool.new()
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/M2TS.mts')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done()
