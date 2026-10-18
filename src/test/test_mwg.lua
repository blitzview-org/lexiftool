--------------------------------------------------------------------------------
-- File:         test/test_mwg.lua
-- Ported from:  t/MWG.t
--
-- Description:  Lua port of the upstream MWG.t (the Perl original): reads
--               the MWG composite tags of t/images/MWG.jpg and
--               t/images/ExifTool.jpg, the IPTC of ExifTool.jpg in strict MWG
--               mode, and writes MWG tags, comparing against the vendored
--               standard outputs (t/MWG_N.out).
--
-- Port notes:   All tests of MWG.t, block for block.
--
--               As upstream, test 1 loads the module explicitly
--               (`Image::ExifTool::MWG::Load()`).  MWG is not loaded by
--               default -- the CLI does it for `-use MWG` or an `MWG:` tag
--               request (main.lua), and a library caller does it itself, as
--               here.  `Load()` also turns on strict mode, which is what
--               test 5 observes.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

-- test 1: Load the module(s)
-- (everything Load() does globally ends with this test file: the runner
--  unloads the library before the next one, as each upstream t/*.t runs in
--  a Perl process of its own)
require('lexiftool.MWG').Load()
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MWG'
local testnum = 1

-- test 2: Extract MWG information from test image
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 0)
    local info = exifTool:ImageInfo(T_DIR .. '/images/MWG.jpg', 'MWG:*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- tests 3-4: Write some MWG tags
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('MWG:DateTimeOriginal', '2009:10:25 15:13:44.567-04:00')
    exifTool:SetNewValue('MWG:Creator', 'Creator One')
    exifTool:SetNewValue('MWG:Creator', 'Creator Two')
    exifTool:SetNewValue('MWG:City', 'Some city')
    local tags = {
        'EXIF:DateTimeOriginal', 'EXIF:SubSecTimeOriginal',
        'IPTC:DateCreated', 'IPTC:TimeCreated', 'XMP-photoshop:DateCreated',
        'EXIF:Artist', 'IPTC:By-line', 'XMP-dc:Creator', 'IPTC:City',
        'XMP-photoshop:City', 'XMP-iptcExt:LocationShownCity',
    }
    for _, src in ipairs({ 'MWG.jpg', 'Writer.jpg' }) do
        testnum = testnum + 1
        local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
        os.remove(testfile)
        exifTool:WriteInfo(T_DIR .. '/images/' .. src, testfile)
        local info = exifTool:GetInfo('Warning')
        if info.Warning then
            io.stderr:write('\n    Warning: ' .. tostring(info.Warning) .. '\n')
            ok(false, 'test ' .. testnum .. ' matches')
        else
            info = exifTool:ImageInfo(testfile, table.unpack(tags))
            if check(exifTool, info, testname, testnum) then
                os.remove(testfile)
                ok(true, 'test ' .. testnum .. ' matches')
            else
                ok(false, 'test ' .. testnum .. ' matches')
            end
        end
    end
end

-- test 5: Extract IPTC information from non-standard image while in strict MWG mode
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', 'IPTC:*', 'Warning')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 6: Copy a tag with MWG feature active
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/MWG.jpg', 'Creator')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:WriteInfo(nil, testfile)
    local info = exifTool:ImageInfo(testfile, 'Creator')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 7: Extract MWG information from ExifTool.jpg
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', 'MWG:*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
