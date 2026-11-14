--------------------------------------------------------------------------------
-- File:         test/test_pentax.lua
-- Ported from:  t/Pentax.t
--
-- Description:  Lua port of tests 1/2/4 of the upstream Pentax.t (the Perl
--               original): extracts information from t/images/Pentax.jpg
--               and t/images/Pentax.avi and compares against the vendored
--               standard output (t/Pentax_2.out, t/Pentax_4.out).
--
-- Port notes:   Tests 2-4 of the upstream numbering are ported. Test 4
--               (Pentax.avi) drives the RIFF container port
--               (lexiftool/RIFF.lua) and its Pentax.AVI maker-note table.
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

local testname = 'Pentax'

-- test 2: Extract information from Pentax.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Pentax.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'ThumbnailImage', nil, n = 2 },    -- delete thumbnail image
        { 'WhiteBalance', 'Tungsten', { Group = 'MakerNotes' } },
        { 'FocalLength', 22 },
        { 'MaxAperture', 2.0 },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Extract information from a Pentax AVI video
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Pentax.avi')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

done() -- end
