--------------------------------------------------------------------------------
-- File:         test/test_panasonic.lua
-- Ported from:  t/Panasonic.t
--
-- Description:  Lua port of tests 1/2/4 of the upstream Panasonic.t (the
--               Perl original): extracts information from
--               t/images/Panasonic.jpg and t/images/Panasonic.rw2 and
--               compares against the vendored standard output
--               (t/Panasonic_2.out, t/Panasonic_4.out).
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

local testname = 'Panasonic'

-- test 2: Extract information from Panasonic.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Panasonic.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'Keywords', 'cool' },
        { 'ShootingMode', 'Panning' },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Extract information from Panasonic.rw2
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Panasonic.rw2', { Duplicates = 1 })
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

-- test 5: Write to RW2 image
do
    local writeInfo = {
        { 'XMP:Title', 'new title' },
        { 'IPTC:Keywords', 'a keyword' },
        { 'ModifyDate', '2009:03:25 12:11:46' },
    }
    ok(writeCheck(writeInfo, testname, 5, T_DIR .. '/images/' .. testname .. '.rw2'), 'test 5 matches')
end

done() -- end
