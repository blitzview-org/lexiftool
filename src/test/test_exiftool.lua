--------------------------------------------------------------------------------
-- File:         test/test_exiftool.lua
-- Ported from:  t/ExifTool.t
--
-- Description:  Lua port of the upstream ExifTool.t (the Perl original).
--               The structure mirrors the original block for block: same
--               comments, same test numbers and same call shapes. Tests that
--               are not yet ported are marked TODO. Standard output data comes
--               exclusively from the vendored upstream tree via TestLib.T_DIR
--               (the equivalent of the original `t` directory).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local perl = require('lexiftool.perl')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR


-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'ExifTool'
local testnum = 1

-- test 2: extract information from JPG file using name
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg')
    ok(check(exifTool, info, testname, testnum),
          'test ' .. testnum .. ' matches')
end

-- test 3: TIFF file using file reference and ExifTool object with options
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1, 'Unknown', 1)
    local TESTFILE = io.open(T_DIR .. '/images/ExifTool.tif', 'rb')
    local info = exifTool:ImageInfo(TESTFILE)
    TESTFILE:close()
    ok(check(exifTool, info, testname, testnum),
          'test ' .. testnum .. ' matches')
end

-- test 4: test the Group option to extract EXIF info only
do
    testnum = testnum + 1
    local info = lexiftool.ImageInfo(T_DIR .. '/images/Canon.jpg', { Group0 = 'EXIF' })
    -- upstream check($info, $testname, $testnum): no ExifTool object, so
    -- TestLib.check takes its plain "Tag: Value" branch
    ok(check(nil, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 5: extract specified tags only
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    -- don't test DateFormat because strftime output varies with locale
    --   exifTool:Options('DateFormat', '%H:%M:%S %a. %b. %e, %Y');
    local tags = { 'CreateDate', 'DateTimeOriginal', 'ModifyDate', 'Orientation#', '?Resolution' }
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', tags)
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 6: test the 5 different ways to exclude tags...
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Exclude', 'ImageWidth')
    local tagList = { '-ImageHeight', '-Make' }
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', '-FileSize', '-*resolution',
        tagList, { Group0 = '-MakerNotes' })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- tests 7/8: test ExtractInfo(), GetInfo(), CombineInfo()
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 0) -- don't allow duplicates
    exifTool:ExtractInfo(T_DIR .. '/images/Canon.jpg')
    local info1 = exifTool:GetInfo({ Group0 = 'MakerNotes' })
    local info2 = exifTool:GetInfo({ Group0 = 'EXIF' })

    testnum = testnum + 1
    local info = exifTool:CombineInfo(info1, info2)
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')

    -- combine information in different order
    testnum = testnum + 1
    info = exifTool:CombineInfo(info2, info1)
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 9: test group options across different families
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg',
        { Group1 = 'Canon', Group2 = '-Camera' })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- tests 10/11: test ExtractInfo() and GetInfo()
-- (uses output from test 5 for comparison)
do
    local exifTool = lexiftool.new()
    -- don't test DateFormat because strftime output is system dependent
    --   exifTool:Options('DateFormat', '%H:%M:%S %a. %b. %e, %Y');
    exifTool:ExtractInfo(T_DIR .. '/images/Canon.jpg')
    local tags = { 'createdate', 'datetimeoriginal', 'modifydate', 'orientation#', '?resolution' }
    local info = exifTool:GetInfo(tags)

    testnum = testnum + 1
    -- upstream overwrites @tags with @expectedTags here and only fails if
    -- an expected name is falsy, so the assertion is really "there are at
    -- least as many expected names as requested tags"
    local expectedTags = { 'CreateDate', 'DateTimeOriginal', 'ModifyDate', 'Orientation',
                           'XResolution', 'YResolution' }
    local good = true
    for i = 1, #tags do
        if not expectedTags[i] then good = false end
        tags[i] = expectedTags[i]
    end
    ok(good, 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    ok(check(exifTool, info, testname, testnum, 5), 'test ' .. testnum .. ' matches')
end

-- tests 12/13: check precedence of tags extracted from groups
-- (Note: these tests should produce the same output as 7/8,
--  so the .out files from tests 7/8 are used)
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 0) -- don't allow duplicates

    testnum = testnum + 1
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg',
        { Group0 = { 'MakerNotes', 'EXIF' } })
    ok(check(exifTool, info, testname, testnum, 7), 'test ' .. testnum .. ' matches')

    -- combine information in different order
    testnum = testnum + 1
    info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg',
        { Group0 = { 'EXIF', 'MakerNotes' } })
    ok(check(exifTool, info, testname, testnum, 8), 'test ' .. testnum .. ' matches')
end

-- tests 14/15/16: test GetGroups()
do
    local exifTool = lexiftool.new()
    exifTool:ExtractInfo(T_DIR .. '/images/Canon.jpg')

    testnum = testnum + 1
    local groups = exifTool:GetGroups(2)
    local notOk = false
    local expect = { 'Camera', 'ExifTool', 'Image', 'Other', 'Time' }
    for i, want in ipairs(expect) do
        if groups[i] ~= want then notOk = true end
    end
    if #groups ~= #expect then notOk = true end
    ok(not notOk, 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    local info = exifTool:GetInfo({ Group0 = 'EXIF' })
    groups = exifTool:GetGroups(info, 0)
    ok(#groups == 1 and groups[1] == 'EXIF', 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    local testfile = TestLib.TEST_DIR .. '/ExifTool_' .. testnum
    local goodfile = T_DIR .. '/ExifTool_' .. testnum
    local TESTFILE = io.open(testfile .. '.failed', 'wb')
    exifTool:ExtractInfo(T_DIR .. '/images/Canon.jpg')
    local family = '1:2'
    groups = exifTool:GetGroups(family)
    for _, group in ipairs(groups) do
        if group ~= 'ExifTool' then
            TESTFILE:write('---- ' .. group .. ' ----\n')
            info = exifTool:GetInfo({ ['Group' .. family] = group })
            local tags = exifTool:GetTagList(info)
            perl.tsort(tags)
            for _, tag in ipairs(tags) do
                local val = info[tag]
                if type(val) == 'number' then val = lexiftool.NumStr(val) end
                TESTFILE:write(tag .. ' : ' .. perl.str(val) .. '\n')
            end
        end
    end
    TESTFILE:close()
    ok(TestLib.testCompare(goodfile .. '.out', testfile .. '.failed', testnum),
          'test ' .. testnum .. ' matches')
end

-- test 17: Test verbose output
do
    testnum = testnum + 1
    ok(TestLib.testVerbose(testname, testnum, T_DIR .. '/images/Canon.jpg', 3),
          'test ' .. testnum .. ' matches')
end

-- tests 18/19: Test Group# option with multiple groups and no duplicates
-- (same shape as 12/13, and likewise compared against the 7/8 goldens)
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 0) -- don't allow duplicates

    testnum = testnum + 1
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg',
        { Group0 = { 'MakerNotes', 'EXIF' } })
    ok(check(exifTool, info, testname, testnum, 7), 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg',
        { Group0 = { 'EXIF', 'MakerNotes' } })
    ok(check(exifTool, info, testname, testnum, 8), 'test ' .. testnum .. ' matches')
end

-- test 20: Test extracting a single, non-priority tag with duplicates set to 0
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 0)
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', 'EXIF:WhiteBalance')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 21: Test extracting ICC_Profile as a block
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.tif', 'ICC_Profile')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 22: Test InsertTagValues
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local foundTags = {}
    exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', foundTags)
    local str = exifTool:InsertTagValues('${ifd0:model;tr/i/_/} - $1ciff:3main:model', foundTags)
    -- (the .failed file goes to the port's test directory, the golden
    --  stays in the vendored t/ directory)
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum
    local TESTFILE = io.open(testfile .. '.failed', 'wb')
    TESTFILE:write(str, '\x0a')
    TESTFILE:close()
    ok(TestLib.testCompare(T_DIR .. '/' .. testname .. '_' .. testnum .. '.out',
        testfile .. '.failed', testnum), 'test ' .. testnum .. ' matches')
end

-- test 23: Test the multi-group feature in a tag name
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', 'main:Author:IPTC3:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 24: Test a shortcut with multiple group names and a ValueConv suffix
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', 'exififd:camera:common#')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 25: Test GlobalTimeShift option
do
    testnum = testnum + 1
    -- (upstream skips this without Time::Local; Lua needs no extra module)
    local exifTool = lexiftool.new()
    exifTool:Options('GlobalTimeShift', '-0:1:0 0:0:0')
    -- Note: can't extract system times because this could result in a different
    -- calculated global time offset (since I am shifting by 1 month)
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', 'time:all', '-system:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 26: Test wildcards using '#' suffix with duplicate PrintConv tags and exclusions
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    -- (hack to avoid sorting in TestLib.pm because order of duplicate tags would be indeterminate)
    exifTool.NO_SORT = 1
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', 'encodingprocess', 'E*#', 'exposureMode',
                                    '-ExifVersion')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 27: Test ListItem option
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('ListItem', -3)
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', 'Subject', 'SupplementalCategories')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 28: Test FastScan = 3
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('FastScan', 3)
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 29: Test Filter
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Filter', 'tr/ /_/;tr/0-9/#/')
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg', '-ExifToolVersion')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 30: Calculate JPEGDigest and JPEGQualityEstimate
do
    testnum = testnum + 1
    -- (upstream skips this without Digest::MD5; this port is backed by the
    --  digest rock -- TestLib.HAS_MD5 -- so it runs)
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Writer.jpg',
        'JPEGDigest', 'JPEGQualityEstimate')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 31: Test Validate feature
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/CanonRaw.cr2',
        'Validate', 'Warning', 'Error')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 32: Read JPS file
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jps', 'jps:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 33: Test SetAlternateFile()
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:SetAlternateFile('File1', T_DIR .. '/images/Nikon.jpg')
    exifTool:SetAlternateFile('File3', T_DIR .. '/images/FujiFilm.jpg')
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg',
        'file3:make', 'make', 'file1:make', 'file1:mo*')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 34: Test SetAlternateFile() with InsertTagValues()
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local foundTags = {}
    exifTool:SetAlternateFile('File010', T_DIR .. '/images/Nikon.jpg')
    exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', foundTags)
    local val = exifTool:InsertTagValues('$file010:make - $make', foundTags)
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '.failed'
    local goodfile = T_DIR .. '/' .. testname .. '_' .. testnum .. '.out'
    local OUT = io.open(testfile, 'wb')
    OUT:write(val, '\n')
    OUT:close()
    ok(TestLib.testCompare(goodfile, testfile, testnum), 'test ' .. testnum .. ' matches')
end

-- test 35: Test SetAlternateFile() with user-defined tags
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local tags = {
        TestTag = {
            Require = {
                [0] = 'Model',
                [1] = 'File1:Model',
            },
            -- (upstream: ValueConv => '"$val[0] -- $val[1]"' -- the port's
            --  conversions are Lua functions)
            ValueConv = function(_self, val) return val[0] .. ' -- ' .. val[1] end,
        },
    }
    lexiftool.AddUserDefinedTags('lexiftool.ExifTool.Composite', tags)
    exifTool:SetAlternateFile('File1', T_DIR .. '/images/Nikon.jpg')
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg', 'TestTag')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
    -- (not upstream: every test file shares this Lua state, so take the
    --  user-defined Composite tag out again -- upstream's process ends here)
    lexiftool.GetTagTable(nil, 'lexiftool.ExifTool.Composite').TestTag = nil
end

done() -- end
