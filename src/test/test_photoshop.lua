--------------------------------------------------------------------------------
-- File:         test/test_photoshop.lua
-- Ported from:  t/Photoshop.t
--
-- Description:  Lua port of the upstream Photoshop.t (the Perl original):
--               extracts information from t/images/Photoshop.psd (test 2)
--               and writes new information to it (test 3), compared against
--               the vendored standard output (t/Photoshop_2.out/_3.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Photoshop'

-- test 2: Extract information from a PSD file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Photoshop.psd')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'XResolution', '120' },
        { 'YResolution', '120' },
        { 'Creator', 'Phil Harvey' },
        { 'By-Line', 'Phil Again' },
        { 'PhotoMechanic:Tagged', 'No' },
    }
    ok(TestLib.writeCheck(writeInfo, testname, 3, T_DIR .. '/images/Photoshop.psd'), 'test 3 matches')
end

done() -- end
