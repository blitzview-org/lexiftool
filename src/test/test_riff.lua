--------------------------------------------------------------------------------
-- File:         test/test_riff.lua
-- Ported from:  t/RIFF.t
--
-- Description:  Lua port of the upstream RIFF.t (the Perl original):
--               extracts information from t/images/RIFF.wav, RIFF.avi and
--               RIFF.webp (tests 2-4), edits EXIF and XMP in the WebP (5),
--               deletes all metadata from it (6) and adds it back (7).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local writeInfo = TestLib.writeInfo
local TEST_DIR = TestLib.TEST_DIR

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'RIFF'

-- tests 2-4: Extract information from RIFF.wav, RIFF.avi and RIFF.webp
local testnum = 2
for _, ext in ipairs({ 'wav', 'avi', 'webp' }) do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/RIFF.' .. ext)
    ok(check(exifTool, info, testname, testnum), ('test %d matches (RIFF.%s)'):format(testnum, ext))
    testnum = testnum + 1
end

-- test 5: Edit EXIF and XMP
local testfile
do
    testnum = 5
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('exif:usercomment', 'test comment')
    exifTool:SetNewValue('xmp:description', 'test description')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.webp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/RIFF.webp', testfile)
    local info = exifTool:ImageInfo(testfile)
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test 5 matches')
    else
        ok(false, 'test 5 matches')
    end
end

-- test 6: Delete all metadata from a WebP file
do
    testnum = 6
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('all')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.webp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/RIFF.webp', testfile)
    local info = exifTool:ImageInfo(testfile)
    ok(check(exifTool, info, testname, testnum), 'test 6 matches')
end

-- test 7: Add back WebP information
do
    testnum = 7
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('exif:usercomment', 'test comment 2')
    exifTool:SetNewValue('xmp:description', 'test description 2')
    local testfile2 = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.webp'
    os.remove(testfile2)
    writeInfo(exifTool, testfile, testfile2)
    local info = exifTool:ImageInfo(testfile2)
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        os.remove(testfile2)
        ok(true, 'test 7 matches')
    else
        ok(false, 'test 7 matches')
    end
end

done() -- end
