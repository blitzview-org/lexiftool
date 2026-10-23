--------------------------------------------------------------------------------
-- File:         test/test_casio.lua
-- Ported from:  t/Casio.t
--
-- Description:  Lua port of tests 1-4 of the upstream Casio.t (the Perl
--               original): extracts information from t/images/Casio.jpg,
--               t/images/Casio2.jpg and t/images/CasioQVCI.jpg and compares
--               against the vendored standard output (t/Casio_2.out,
--               t/Casio_3.out, t/Casio_4.out).
--
-- Port notes:   Tests 2-6 of the upstream numbering are ported.
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

local testname = 'Casio'

-- test 2: Extract information from Casio.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Casio.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from Casio2.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Casio2.jpg')
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

-- test 4: Extract information from CasioQVCI.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/CasioQVCI.jpg')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

-- test 5: Write some new information
do
    local writeInfo = {
        { 'MaxApertureValue', 4 },
        { 'FocusMode', 'Macro' },
    }
    ok(writeCheck(writeInfo, testname, 5), 'test 5 matches')
end

-- test 6: Write some new information in type 2 file
do
    local writeInfo = {
        { 'XResolution', 300 },
        { 'YResolution', 300 },
        { 'ObjectDistance', '3.5' },
    }
    ok(writeCheck(writeInfo, testname, 6, T_DIR .. '/images/Casio2.jpg'), 'test 6 matches')
end

done() -- end
