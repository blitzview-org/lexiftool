--------------------------------------------------------------------------------
-- File:         test/test_xmp.lua
-- Ported from:  t/XMP.t
--
-- Description:  Lua port of the upstream XMP.t (the Perl original).  The
--               structure mirrors the original block for block: same
--               comments, same test numbers (they select t/XMP_<N>.out) and
--               same call shapes.  Standard output data comes exclusively
--               from the vendored upstream tree via TestLib.T_DIR.
--
-- Port notes:   All tests are ported except 6 and 46, which keep a
--               placeholder block naming the reason (neither in the XMP
--               writer: the WriteAlso of the writable Composite:Flash, the
--               '@' expressions of InsertTagValues), so the numbering stays
--               upstream's.  Write entries whose value is nil carry `n` for
--               TestLib.writeCheck's unpack.  Test 3 iterates the info hash
--               in Lua's pairs() order, as upstream iterates in Perl's hash
--               order.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local writeInfo = TestLib.writeInfo
local writeCheck = TestLib.writeCheck
local testCompare = TestLib.testCompare
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR
local testfile

-- definitions for user-defined tag test (#26)
-- (upstream assigns these to %Image::ExifTool::UserDefined, which GetTagTable
--  folds into XMP::Main when test 2 first loads it -- upstream runs each .t in
--  a fresh process.  This port's runner shares one Lua state across all test
--  files, where XMP.Main is usually loaded already, so the same tags go in
--  through AddUserDefinedTags (Writer.pl:2893), upstream's run-time way of
--  adding them, and come out again at the end of this file.)
local UserDefined = {
    ['lexiftool.XMP.Main'] = {
        myXMPns = {
            SubDirectory = {
                TagTable = 'lexiftool.UserDefined.myXMPns',
                -- (see the definition of this table below)
            },
        },
    },
}
-- (upstream %Image::ExifTool::UserDefined::myXMPns, see
--  ExifTool.UserDefinedTables in lexiftool.lua)
lexiftool.UserDefinedTables.myXMPns = {
    GROUPS    = { [0] = 'XMP', [1] = 'XMP-myXMPns' },
    NAMESPACE = { myXMPns = 'http://ns.exiftool.org/t/XMP.t' },
    WRITABLE  = 'string',
    ATestTag  = { List = 'Bag', Resource = 1 },
    BTestTag  = {
        Struct = {
            TYPE = 'myXMPns:SomeFunnyType',
            Field1 = { Writable = 'lang-alt', List = 'Bag' },
        }
    },
    BTestTagField1 = { Name = 'Renamed', Flat = 1 },
}
for tableName, tags in pairs(UserDefined) do
    lexiftool.AddUserDefinedTags(tableName, tags)
end

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'XMP'
local testnum = 1

-- test 2: Extract information from XMP.jpg
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP.jpg', { Duplicates = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 3: Test rewriting everything with slightly different values
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1, 'Binary', 1, 'ListJoin', nil)
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP.jpg')
    for tag, val in pairs(info) do
        local group = exifTool:GetGroup(tag, 0)  -- (scalar context: family 0)
        if type(val) == 'table' and val.ref == nil then
            val[#val + 1] = 'v2'
        elseif type(val) == 'table' and val.ref == 'SCALAR' then
            val = 'v2'
        elseif perl.isMatch(val, [[^\d+(\.\d*)?$]]) then
            -- (add extra .001 to avoid problem with aperture of 4.85
            --  getting rounded to 4.8 or 4.9 and causing failed tests)
            local frac = perl.matches(val, [[^\d+(\.\d*)?$]])
            val = perl.num(val)
            val = val + (val / 10) + 1.001
            if not perl.truthy(frac) then val = perl.int(val) end
        else
            val = val .. '-v2'
        end
        -- eat return values so warning don't get printed
        exifTool:SetNewValue(tag, val, { Group = group, Replace = 1 })
    end
    -- also try writing a few specific tags
    exifTool:SetNewValue('CreatorCountry', 'Canada')
    exifTool:SetNewValue('CodedCharacterSet', 'UTF8', { Protected = 1 })
    info = nil -- luacheck: ignore 311 (upstream `undef $info`)
    local image = { ref = 'SCALAR' }
    local wrote = writeInfo(exifTool, T_DIR .. '/images/XMP.jpg', image)
    -- this is effectively what the RHEL 3 UTF8 LANG problem does:
    -- $image = pack("U*", unpack("C*", $image));

    local exifTool2 = lexiftool.new()
    exifTool2:Options('Duplicates', 1)
    info = exifTool2:ImageInfo(image)
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    if check(exifTool2, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        -- save bad file
        local fh = io.open(testfile, 'wb')
        if fh and image.value then fh:write(image.value:tostring()) fh:close() end
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- tests 4/5: Test extracting then reading XMP data as a block
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP.jpg', 'XMP')
    ok(info.XMP ~= nil, 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    local pass
    if info.XMP then
        info = exifTool:ImageInfo(info.XMP)
        pass = check(exifTool, info, testname, testnum)
    end
    ok(pass, 'test ' .. testnum .. ' matches')
end

-- test 6: Test copying information to a new XMP data file
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.jpg')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    local wrote = writeInfo(exifTool, nil, testfile)
    local info = exifTool:ImageInfo(testfile)
    if check(exifTool, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 7: Test rewriting CS2 XMP information
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValue('Label', 'Blue')
    exifTool:SetNewValue('Rating', 3)
    exifTool:SetNewValue('Subject', [[char test: & > < ' "]], { AddValue = 1 })
    exifTool:SetNewValue('Rights', '\xc2\xa9 Copyright Someone Else')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/XMP.xmp', testfile)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum) and wrote,
       'test ' .. testnum .. ' matches')
end

-- test 8-11: Test reading/writing XMP with blank nodes and some problems that need correcting
do
    for _, file in ipairs({ 'XMP2.xmp', 'XMP3.xmp' }) do
        testnum = testnum + 1
        local exifTool = lexiftool.new()
        local info = exifTool:ImageInfo(T_DIR .. '/images/' .. file, { Duplicates = 1 })
        ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')

        testnum = testnum + 1
        testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
        os.remove(testfile)
        exifTool:SetNewValue('XMP:Creator', 'Phil', { AddValue = 1 })
        exifTool:SetNewValue('manifestplacedXResolution', 1)
        exifTool:SetNewValue('attributionname', 'something else')
        exifTool:WriteInfo(T_DIR .. '/images/' .. file, testfile)
        local err = exifTool:GetValue('Error')
        if err then io.stderr:write('\n  ' .. tostring(err) .. '\n') end
        ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')
    end
end

-- tests 12-17: Test writing/deleting XMP alternate languages
do
    local writeList = {
        { { 'Rights-x-default', '\xc2\xa9 Copyright Another One' } }, -- should overwrite x-default only
        { { 'Rights-de-DE', '\xc2\xa9 Urheberrecht Phil Harvey' } },  -- should create de-DE only
        { { 'Rights-x-default', nil, n = 2 } },  -- should delete x-default only
        { { 'Rights-fr', nil, n = 2 } },         -- should delete fr only
        { { 'Title-fr', 'Test fr title' } },-- should not create x-default
        { { 'Title-fr', 'Test fr title' },
          { 'Title-x-default', 'dTitle' } },-- should create x-default before fr
    }
    for _, writeListRef in ipairs(writeList) do
        testnum = testnum + 1
        ok(writeCheck(writeListRef, testname, testnum, T_DIR .. '/images/XMP.xmp', { 'XMP-dc:*' }),
           'test ' .. testnum .. ' matches')
    end
end

-- test 18: Delete some family 1 XMP groups
do
    testnum = testnum + 1
    local writeInfoList = {
        { 'xmp-xmpmm:all', nil, n = 2 },
        { 'XMP-PHOTOSHOP:all', nil, n = 2 },
    }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/XMP.jpg', { 'XMP:all' }),
       'test ' .. testnum .. ' matches')
end

-- test 19-20: Copy from XMP to EXIF with and without PrintConv enabled
do
    local exifTool = lexiftool.new()
    while testnum < 20 do
        testnum = testnum + 1
        testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
        os.remove(testfile)
        exifTool:SetNewValue()
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.xmp', 'XMP:all>EXIF:all')
        local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
        local info = exifTool:ImageInfo(testfile, 'EXIF:all')
        if check(exifTool, info, testname, testnum) and wrote then
            os.remove(testfile)
            ok(true, 'test ' .. testnum .. ' matches')
        else
            ok(false, 'test ' .. testnum .. ' matches')
        end
        exifTool:Options('PrintConv', 0)
    end
end

-- test 21-22: Copy from EXIF to XMP with and without PrintConv enabled
do
    local exifTool = lexiftool.new()
    while testnum < 22 do
        testnum = testnum + 1
        testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
        os.remove(testfile)
        exifTool:SetNewValue()
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg', 'EXIF:* > XMP:*')
        local wrote = writeInfo(exifTool, nil, testfile)
        local info = exifTool:ImageInfo(testfile, 'XMP:*')
        if check(exifTool, info, testname, testnum) and wrote then
            os.remove(testfile)
            ok(true, 'test ' .. testnum .. ' matches')
        else
            ok(false, 'test ' .. testnum .. ' matches')
        end
        exifTool:Options('PrintConv', 0)
    end
end

-- test 23: Delete all tags except two specific XMP family 1 groups
do
    testnum = testnum + 1
    local writeInfoList = {
        { 'all', nil, n = 2 },
        { 'xmp-dc:all', nil, { Replace = 2 }, n = 3 },
        { 'xmp-xmprights:all', nil, { Replace = 2 }, n = 3 },
    }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/XMP.jpg', { 'XMP:all' }, nil, 1),
       'test ' .. testnum .. ' matches')
end

-- test 24: Delete all tags except XMP
do
    testnum = testnum + 1
    local writeInfoList = {
        { 'all', nil, n = 2 },
        { 'xmp:all', nil, { Replace = 2 }, n = 3 },
    }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/XMP.jpg', { '-file:all' }, nil, 1),
       'test ' .. testnum .. ' matches')
end

-- test 25: Extract information from SVG image
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP.svg', { Duplicates = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 26: Test creating a variety of XMP information
--          (including x:xmptk, rdf:about and rdf:resource attributes)
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    local writeInfoList = {
        { 'XMP-x:XMPToolkit', "What's this?", { Protected = 1 } },
        { 'XMP-rdf:About', 'http://www.exiftool.org/t/' .. testname .. '.t#' .. testnum, { Protected = 1 } },
        { 'XMP:ImageType', 'Video' },
        { 'LicenseeImageNotes-en', 'english notes' },
        { 'LicenseeImageNotes-de', 'deutsche anmerkungen' },
        { 'LicenseeImageNotes', 'default notes' },
        { 'LicenseeName', 'Phil' },
        { 'CopyrightStatus', 'public' },
        { 'Custom1-en', 'a' },
        { 'Custom1-en', 'b' },
        { 'ATestTag', 'http://www.exiftool.org/t/' .. testname .. '.t#' .. testnum .. '-one' },
        { 'ATestTag', 'http://www.exiftool.org/t/' .. testname .. '.t#' .. testnum .. '-two' },
    }
    for _, w in ipairs(writeInfoList) do exifTool:SetNewValue(table.unpack(w)) end
    local wrote = writeInfo(exifTool, nil, testfile)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum) and wrote,
       'test ' .. testnum .. ' matches')
end

-- test 27: Extract information from exiftool RDF/XML output file
-- (file created by application with this command line:
--  "exiftool -X -D t/images/Nikon.jpg > t/image/XMP.xml")
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP.xml', { Duplicates = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 28: Write information to exiftool RDF/XML output file
do
    testnum = testnum + 1
    local writeInfoList = {
        { 'all', nil, n = 2 },
        { 'ifd0:all', nil, { Replace = 2 }, n = 3 },
        { 'XML-file:all', nil, { Replace = 2 }, n = 3 },
        { 'author', 'Phil' },
    }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/XMP.xml'), 'test ' .. testnum .. ' matches')
end

-- test 29: Rewrite extended XMP segment
do
    testnum = testnum + 1
    local writeInfoList = { { 'author', 'Test' } }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/ExtendedXMP.jpg'),
       'test ' .. testnum .. ' matches')
end

-- test 30: Test mass copy with deletion of specific XMP family 1 groups in shorthand format
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('XMPShorthand', 1)
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.out'
    os.remove(testfile)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.jpg')
    exifTool:SetNewValue('xmp-exif:all')
    exifTool:SetNewValue('XMP-TIFF:*')
    exifTool:WriteInfo(nil, testfile, 'XMP') --(also test output file type option)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')
end

-- test 31: Extract structured information
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP4.xmp', { Struct = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- tests 32-34: Conditionally add XMP lang-alt tag
do
    -- write title only if it doesn't exist
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('XMP-dc:Title-de', '', { DelValue = 1 })
    exifTool:SetNewValue('XMP-dc:Title-de', 'A')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, 'XMP:*')
    ok(check(exifTool, info, testname, testnum) and wrote, 'test ' .. testnum .. ' matches')

    -- try again when title already exists
    testnum = testnum + 1
    local testfile2 = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue('XMP-dc:Title-de', 'B')
    exifTool:WriteInfo(testfile, testfile2)
    info = exifTool:ImageInfo(testfile2, 'XMP:*')
    if check(exifTool, info, testname, testnum, 32) then
        os.remove(testfile2)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end

    -- one final time replacing an existing title
    testnum = testnum + 1
    testfile2 = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue('XMP-dc:Title-de', 'A', { DelValue = 1 })
    exifTool:SetNewValue('XMP-dc:Title-de', 'C')
    wrote = writeInfo(exifTool, testfile, testfile2)
    info = exifTool:ImageInfo(testfile2, 'XMP:*')
    if check(exifTool, info, testname, testnum) and wrote then
        os.remove(testfile)
        os.remove(testfile2)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 35: Test various features of writing structured information
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    local writeInfoList = {
        -- write as flattened string
        { 'HierarchicalKeywords', '{keyWORD=A-1,childREN={keyword=A-2}}' },
        -- write as HASH reference
        { 'HierarchicalKeywords', { { kEyWoRd = 'B-1', cHiLdReN = { keyword = 'B-2' } }, { keyword = 'C-1' } } },
        -- write a type'd structure
        { 'licensee', { licenseename = 'Phil' } },
        -- write a region, including a 'seeAlso' resource
        { 'RegionList', {
            Area = { X = 0, Y = 0, W = 8, H = 8 },
            Name = 'Region 1',
            type = 'Face',
            seeAlso = 'plus:Licensee',
        } },
        -- write alternate language structure elements
        { 'ArtworkOrObject', '{AOTitle=test,aotitle-de=pr\xc3\xbcfung,AOTitle_FR=\xc3\xa9preuve}' },
        -- disable print conversion for a single structure element
        { 'XMP:Flash', '{Return=no,mode#=2}' },
        -- write a complex user-defined lang-alt structure
        { 'BTestTag', '{Field1-en-CA=[eh?],Field1-en-US=[huh?,groovy],Field1-fr=[,ing\xc3\xa9nieux]}' },
        -- write some dynamic structure elements
        { 'RegionList', { Extensions = {
            -- may mix-and-match flattened and structured tags when writing!...
           ['XMP-exif:FlashReturn'] = 'not', -- flattened tag with group name
            Flash = { ['Mode#'] = 1 },      -- structured tag with disabled conversion
           ['UsageTerms-fr'] = 'libre',      -- lang-alt tag
           ['ArtworkTitle-de'] = 'verf\xc3\xa4nglich', -- renamed lang-alt tag in a list
            Renamed = 'this is wild',      -- user-defined renamed flattened tag with TYPE
        } } },
    }
    for _, w in ipairs(writeInfoList) do exifTool:SetNewValue(table.unpack(w)) end
    local wrote = writeInfo(exifTool, nil, testfile)
    ok(testCompare(T_DIR .. '/images/XMP5.xmp', testfile, testnum) and wrote, 'test ' .. testnum .. ' matches')
end

-- tests 36-37: Test reading structures with and without the Struct option
do
    for i = 0, 1 do
        testnum = testnum + 1
        local exifTool = lexiftool.new()
        exifTool:Options('Struct', 1 - i)
        exifTool:Options('Escape', 'HTML')  -- test escaping of structure fields too
        local info = exifTool:ImageInfo(T_DIR .. '/images/XMP5.xmp')
        ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
    end
end

-- test 38: Copy complex structured information
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP5.xmp', 'xmp:all')
    local wrote = writeInfo(exifTool, nil, testfile)
    ok(testCompare(T_DIR .. '/images/XMP5.xmp', testfile, testnum) and wrote, 'test ' .. testnum .. ' matches')
end

-- test 39: Extract information from an INX file
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP.inx', { Duplicates = 1 })
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 40: Copy by flattened tag name and structure at the same time
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP5.xmp', 'HierarchicalKeywords1', 'Licensee')
    local wrote = writeInfo(exifTool, nil, testfile)
    local info = exifTool:ImageInfo(testfile, 'XMP:*')
    if check(exifTool, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 41: Rest writing/reading all DarwinCore tags
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValue('xmp-dwc:*', 2013)
    local wrote = writeInfo(exifTool, nil, testfile)
    local info = exifTool:ImageInfo(testfile, { Duplicates = 1 })
    if check(exifTool, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 42: Read extended XMP
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ExtendedXMP.jpg', 'xmp:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 43: Read XMP with unusual namespace prefixes
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/XMP6.xmp', 'xmp:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

-- test 44: Write XMP with unusual namespace prefixes
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValue('xmp-dc:subject', 'changed')
    exifTool:WriteInfo(T_DIR .. '/images/XMP6.xmp', testfile)
    local err = exifTool:GetValue('Error')
    if err then io.stderr:write('\n  ' .. tostring(err) .. '\n') end
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')
end

-- test 45: Write empty structures
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValue('regioninfo', '{RegionList=[,]}')
    exifTool:SetNewValue('xmp:flash', '{}')
    exifTool:WriteInfo(nil, testfile)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')
end

-- test 46: Test the advanced-formatting '@' feature and "All" in the source group
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('ListSplit', ', ')
    local subj = 'subject<${subject@;/^Test/ ? $_=undef : s/Tool$//}'
    local keyw = 'creator<${Adobe:all:all@;s/n/N/;$_=undef if /Y/}'
    -- (exclude Adobe tag because the Adobe segment would be extracted as a block when copying)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.jpg', subj, '-adobe', keyw)
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, nil, testfile)
    exifTool:Options('ListSep', ' // ')
    local info = exifTool:ImageInfo(testfile, 'Subject', 'Creator')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- tests 47-49: Test replacing specific elements in list of structures
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('ListSplit', ',')
    exifTool:Options('Struct', 1)
    exifTool:SetNewValue('LocationShownCity', 'Manchester,Lyon,Frankfurt')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/XMP7.xmp', testfile)
    local info = exifTool:ImageInfo(testfile, 'XMP:all')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end

    testnum = testnum + 1
    exifTool:SetNewValue()
    exifTool:SetNewValue('LocationShownCity', 'London,Berlin', { DelValue = 1 })
    exifTool:SetNewValue('LocationShownCity', 'Oxford,Munich')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/XMP7.xmp', testfile)
    info = exifTool:ImageInfo(testfile, 'XMP:all')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end

    testnum = testnum + 1
    exifTool:SetNewValue()
    exifTool:SetNewValue('AboutCvTermName', 'one,three', { DelValue = 1 })
    exifTool:SetNewValue('AboutCvTermName', 'a,b,c')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/XMP8.xmp', testfile)
    info = exifTool:ImageInfo(testfile, 'XMP:all')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 50-53: Test replacing/creating elements in nested lang-alt list
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP9.xmp', '*:*')
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/XMP9.xmp', testfile)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:WriteInfo(nil, testfile)
    ok(testCompare(T_DIR .. '/XMP_50.out', testfile, testnum), 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:SetNewValue()
    exifTool:SetNewValue('Custom1', 'test', { DelValue = 1 })
    exifTool:SetNewValue('Custom1', 'new')
    exifTool:WriteInfo(T_DIR .. '/images/XMP9.xmp', testfile)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')

    testnum = testnum + 1
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    exifTool:Options('ListSplit', ',')
    exifTool:SetNewValue()
    exifTool:SetNewValue('Custom1', 'a,b,c', { AddValue = 1 })
    exifTool:SetNewValue('Custom1-fr', 'a-fr,,c-fr,d-fr,,f-fr', { AddValue = 1 })
    exifTool:WriteInfo(T_DIR .. '/images/XMP9.xmp', testfile)
    ok(testCompare(T_DIR .. '/XMP_' .. testnum .. '.out', testfile, testnum), 'test ' .. testnum .. ' matches')
end

-- test 54: Write flattened tag and extension in a variable-namespace structure
do
    testnum = testnum + 1
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('ImageRegionCtypeIdentifier', 'x')
    exifTool:SetNewValue('ImageRegion', '{Flash={Fired=True,Return#=3}}')
    exifTool:WriteInfo(nil, testfile)
    exifTool:Options('Struct', 1)
    local info = exifTool:ImageInfo(testfile, 'XMP-iptcExt:all')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- (not upstream: every test file shares this Lua state, so take the
--  user-defined tags out again -- upstream's process ends here)
lexiftool.GetTagTable(nil, 'lexiftool.XMP.Main').myXMPns = nil
lexiftool.GetAllTables()['lexiftool.UserDefined.myXMPns'] = nil
lexiftool.UserDefinedTables.myXMPns = nil
do
    local XMP = require('lexiftool.XMP')
    XMP.nsURI.myXMPns = nil
    XMP.uri2ns['http://ns.exiftool.org/t/XMP.t'] = nil
end

done() -- end
