--------------------------------------------------------------------------------
-- File:         test/test_sigma.lua
-- Ported from:  t/Sigma.t
--
-- Description:  Lua port of tests 1/2/4 of the upstream Sigma.t (the Perl
--               original): extracts information from t/images/Sigma.jpg and
--               t/images/Sigma.x3f and compares against the vendored
--               standard output (t/Sigma_2.out, t/Sigma_4.out).
--
-- Port notes:   Tests 2-5 of the upstream numbering are ported.
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

local testname = 'Sigma'

-- test 2: Extract information from Sigma.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sigma.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'IPTCPixelWidth', 200 },
        { 'Sharpness', 2, { Group = 'MakerNotes' } },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Test reading X3F image
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sigma.x3f')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

-- test 5: Test writing X3F image
do
    local writeInfo = {
        { 'Artist', 'Phil Harvey' },
        { 'XMP:Title', 'A title' },
        { 'Keywords', { 'one', 'two' } },
    }
    ok(writeCheck(writeInfo, testname, 5, T_DIR .. '/images/SigmaDP2.x3f'), 'test 5 matches')
end

done() -- end
