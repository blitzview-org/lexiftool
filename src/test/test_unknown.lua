--------------------------------------------------------------------------------
-- File:         test/test_unknown.lua
-- Ported from:  t/Unknown.t
--
-- Description:  Lua port of test 2 of the upstream Unknown.t (the Perl
--               original): extracts information from t/images/Unknown.jpg
--               with the Unknown option set and compares against the
--               vendored standard output (t/Unknown_2.out).
--
-- Port notes:   Tests 2 and 3 of the upstream numbering are ported.
--
--               This is the port's only fixture with *entry-based* maker-note
--               offsets, so it is what covers `Exif::ProcessExif`'s
--               `$$dirInfo{EntryBased}` branch (Exif.pm:6541) and the
--               `FixBase` detection that sets it.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Unknown'
local testnum = 1

-- test 2: Extract information from Unknown.jpg
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Unknown.jpg', { Unknown = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Write some new information
do
    local writeInfo = { { 'FocalLength', 200 } }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

done() -- end
