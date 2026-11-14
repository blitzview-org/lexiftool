--------------------------------------------------------------------------------
-- File:         test/test_minolta.lua
-- Ported from:  t/Minolta.t
--
-- Description:  Lua port of test 2 of the upstream Minolta.t (the Perl
--               original): extracts information from t/images/Minolta.jpg
--               and compares against the vendored standard output
--               (t/Minolta_2.out).
--
-- Port notes:   Tests 2-4 of the upstream numbering are ported.
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

local testname = 'Minolta'

-- test 2: Extract information from Minolta.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Minolta.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'Caption-Abstract', 'A new caption/abstract' },
        { 'MinoltaDate', '2005:01:16' },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Write rewriting MRW image
do
    local writeInfo = {
        { 'FocusMode', 'MF' },
        { 'LastFileNumber', '123' },
    }
    ok(writeCheck(writeInfo, testname, 4, T_DIR .. '/images/Minolta.mrw'), 'test 4 matches')
end

done() -- end
