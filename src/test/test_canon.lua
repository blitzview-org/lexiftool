--------------------------------------------------------------------------------
-- File:         test/test_canon.lua
-- Ported from:  t/Canon.t
--
-- Description:  Lua port of the upstream Canon.t (the Perl original):
--               extracts information from t/images/Canon1DmkIII.jpg and
--               compares against the vendored standard output
--               (t/Canon_2.out).
--
-- Port notes:   Tests 2 and 3 of the upstream numbering are ported (test 3
--               writes the CanonCustom2 ISOSpeedRange/TimerLength values).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Canon'

-- test 2: Extract information from a Canon EXIF MakerNotes JPEG
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon1DmkIII.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write CanonCustom2 information
do
    local writeInfo = {
        { 'ISOSpeedRange', 'Enable; 1600; 200' },
        { 'TimerLength', 'Enable; 6 sec: 5; 16 sec: 20; After release: 6' },
    }
    local check_ = { 'ISOSpeedRange', 'TimerLength', 'OriginalDecisionData', 'Warning' }
    ok(writeCheck(writeInfo, testname, 3, T_DIR .. '/images/Canon1DmkIII.jpg', check_), 'test 3 matches')
end

done() -- end
