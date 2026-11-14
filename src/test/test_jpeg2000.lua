--------------------------------------------------------------------------------
-- File:         test/test_jpeg2000.lua
-- Ported from:  t/Jpeg2000.t
--
-- Description:  Lua port of the upstream Jpeg2000.t (the Perl original):
--               extracts information from t/images/Jpeg2000.jp2 and
--               t/images/Jpeg2000.j2c, writes new information into the JP2
--               and compares against the vendored standard output
--               (t/Jpeg2000_2.out .. t/Jpeg2000_5.out).
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

local testname = 'Jpeg2000'

-- test 2: Extract information from Jpeg2000.jp2
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Jpeg2000.jp2')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'IPTC:Keywords', 'test keyword' },
        { 'XMP:City', 'a city' },
        { 'EXIF:ImageDescription', 'a description' },
        { 'XML', '<test>Yippee</test>', { Protected = 1 } },
        { 'Jpeg2000:ColorSpace', 'Grayscale', { Protected = 1 } },
        { 'ColorSpecPrecedence', 1, { Protected = 1 } },
    }
    ok(writeCheck(writeInfo, testname, 3, T_DIR .. '/images/Jpeg2000.jp2'), 'test 3 matches')
end

-- test 4: Extract information from Jpeg2000.j2c
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Jpeg2000.j2c')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

-- test 5: Extract XML as a block from JP2 image
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Jpeg2000.jp2', 'xml')
    ok(check(exifTool, info, testname, 5), 'test 5 matches')
end

done() -- end
