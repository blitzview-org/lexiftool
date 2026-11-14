--------------------------------------------------------------------------------
-- File:         test/test_sanyo.lua
-- Ported from:  t/Sanyo.t
--
-- Description:  Lua port of the upstream Sanyo.t (the Perl original):
--               extracts information from t/images/Sanyo.jpg and writes
--               some new information, comparing against the vendored
--               standard output (t/Sanyo_2.out, t/Sanyo_3.out).
--
-- Port notes:   All tests are ported.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local writeCheck = TestLib.writeCheck
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Sanyo'

-- test 2: Extract information from Sanyo.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sanyo.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'SceneCaptureType', 'night' },
        { 'FlashMode', 'force', { Group = 'MakerNotes' } },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

done() -- end
