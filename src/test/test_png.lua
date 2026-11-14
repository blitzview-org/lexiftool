--------------------------------------------------------------------------------
-- File:         test/test_png.lua
-- Ported from:  t/PNG.t
--
-- Description:  Lua port of the upstream PNG.t (the Perl original): extracts
--               information from t/images/PNG.png (2), deletes groups and
--               writes alternate languages (4), moves XMP from after IDAT
--               with -v2 output (5), writes EXIF (6) and a named ICC
--               profile as iCCP chunk (7).  Test 3 is open.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local testCompare = TestLib.testCompare

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PNG'

-- test 2: Extract information from PNG.png
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PNG.png')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write a bunch of new information to a PNG in memory
do
    local testnum = 3
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/IPTC.jpg')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.jpg')
    exifTool:SetNewValue('PNG:Comment')  -- and delete a tag
    exifTool:SetNewValue('PixelsPerUnitX', 1234)
    local image = { ref = 'SCALAR' }
    exifTool:WriteInfo(T_DIR .. '/images/PNG.png', image)
    -- must ignore FileSize because size is variable (depends on Zlib availability)
    local info = exifTool:ImageInfo(image, '-filesize')
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.png'
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)   -- erase results of any bad test
        ok(true, 'test 3 matches')
    else
        -- save the bad image
        local fh = io.open(testfile, 'wb')
        if fh then fh:write(image.value and image.value:tostring() or '') fh:close() end
        ok(false, 'test 3 matches')
    end
end

-- test 4: Test group delete, alternate languages and special characters
do
    local testnum = 4
    local exifTool = lexiftool.new()
    exifTool:Options('Charset', 'Latin')
    exifTool:SetNewValue('PNG:*')
    exifTool:SetNewValue('XMP:*')
    exifTool:SetNewValue('PNG:Comment-fr', "Commentaire fran\xe7aise")
    exifTool:SetNewValue('PNG:Copyright', "\xa9 2010 Phil Harvey")
    exifTool:SetNewValue('XMP:Description-bar', "A Br\xfcn is a Gst\xf6")
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.png'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/PNG.png', testfile)
    exifTool:Options('Charset', 'UTF8')
    local info = exifTool:ImageInfo(testfile, 'PNG:*', 'XMP:*')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)   -- erase results of any bad test
        ok(true, 'test 4 matches')
    else
        ok(false, 'test 4 matches')
    end
end

-- test 5: Try moving XMP from after IDAT to before
do
    local testnum = 5
    local exifTool = lexiftool.new()
    local image = { ref = 'SCALAR' }
    -- delete all XMP then copy back again (should move to before IDAT)
    exifTool:SetNewValue()
    local txtfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '.failed'
    local PNG_TEST_5 = io.open(txtfile, 'wb')
    if not PNG_TEST_5 then io.stderr:write('Error opening ' .. txtfile .. '\n') end
    exifTool:Options('Verbose', 2)
    exifTool:Options('TextOut', PNG_TEST_5)
    exifTool:SetNewValue('xmp:all')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/PNG.png', 'all:all<xmp:all')
    exifTool:WriteInfo(T_DIR .. '/images/PNG.png', image)
    if PNG_TEST_5 then PNG_TEST_5:close() end
    -- (upstream runs from the distribution directory, so its verbose output
    --  names the file as t/images/PNG.png; T_DIR is absolute here)
    local fh = io.open(txtfile, 'rb')
    local data = fh and fh:read('a') or ''
    if fh then fh:close() end
    fh = io.open(txtfile, 'wb')
    if fh then
        fh:write((data:gsub(T_DIR:gsub('%p', '%%%0') .. '/', function() return 't/' end)))
        fh:close()
    end
    if testCompare(T_DIR .. '/PNG_5.out', txtfile, testnum) then
        os.remove(txtfile)
        ok(true, 'test 5 matches')
    else
        ok(false, 'test 5 matches')
    end
end

-- test 6: Write EXIF
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('EXIF:Artist', 'me')
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_6_failed.png'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/PNG.png', testfile)
    exifTool:Options('Charset', 'UTF8')
    local info = exifTool:ImageInfo(testfile, 'EXIF:*')
    if check(exifTool, info, testname, 6) then
        os.remove(testfile)
        ok(true, 'test 6 matches')
    else
        ok(false, 'test 6 matches')
    end
end

-- test 7: Write ICC_Profile with a name
do
    local testnum = 7
    local exifTool = lexiftool.new()
    if exifTool:hasZlib() then   -- (`eval 'require Compress::Zlib'`)
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/ICC_Profile.icc', 'ICC_Profile')
        exifTool:SetNewValue('PNG:ProfileName', 'Adobe RGB (1998)')
        local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.png'
        os.remove(testfile)
        exifTool:WriteInfo(T_DIR .. '/images/PNG.png', testfile)
        local info = exifTool:ImageInfo(testfile, 'ProfileName', 'ProfileCMMType')
        if check(exifTool, info, testname, testnum) then
            os.remove(testfile)
            ok(true, 'test 7 matches')
        else
            ok(false, 'test 7 matches')
        end
    else
        ok(true, 'test 7 # skip Requires Compress::Zlib')
    end
end

done() -- end
