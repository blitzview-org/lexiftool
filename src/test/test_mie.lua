--------------------------------------------------------------------------------
-- File:         test/test_mie.lua
-- Ported from:  t/MIE.t
--
-- Description:  Lua port of the upstream MIE.t (the Perl original): extracts
--               information from t/images/MIE.mie (2), writes MIE
--               information with the Escape option (3), creates a MIE file
--               from scratch (4) and reads different Charsets (5-6),
--               comparing against the vendored standard output
--               (t/MIE_<N>.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MIE'
local testnum = 1

-- test 2: Extract information from MIE.mie
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/MIE.mie', '-filename', '-directory')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Write MIE information (also test Escape option when writing)
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('IgnoreMinorErrors', 1) -- to copy invalid thumbnail
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Nikon.jpg', '*:*')
    exifTool:SetNewValue('EXIF:XResolution', 200)
    exifTool:SetNewValue('MIE:FNumber', 11)
    exifTool:SetNewValue('XMP:Creator', 'phil')
    exifTool:SetNewValue('IPTC:Keywords', 'cool')
    exifTool:SetNewValue('MIE:GPSLongitude', -1.5)
    exifTool:Options('Escape', 'HTML')
    exifTool:SetNewValue('MIE:PhoneNumber', 'k&uuml;hl')
    exifTool:Options('Escape', nil)
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.mie'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/MIE.mie', testfile)
    local info = exifTool:ImageInfo(testfile)
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 4: Create a MIE file from scratch (also test Escape option when copying)
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('IgnoreMinorErrors', 1) -- to copy invalid thumbnail
    exifTool:Options('Escape', 'HTML')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/MIE.mie')
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.mie'
    os.remove(testfile)
    exifTool:WriteInfo(nil, testfile)
    exifTool:Options('Escape', nil) -- reset Escape option
    local info = exifTool:ImageInfo(testfile, '-filename', '-directory')
    if check(exifTool, info, testname, testnum, 2) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- tests 5-6: Test reading different Charsets
for _, charset in ipairs({ 'Latin', 'Cyrillic' }) do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Charset', charset)
    local info = exifTool:ImageInfo(T_DIR .. '/images/MIE.mie', 'comment-ru_ru')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
