--------------------------------------------------------------------------------
-- File:         test/test_flif.lua
-- Ported from:  t/FLIF.t
--
-- Description:  Lua port of the upstream FLIF.t (the Perl original):
--               extracts information from t/images/FLIF.flif (2), edits
--               (3), deletes (4), adds back (5) and deletes all then adds
--               back in one step (6).  IO::(Un)Compress::Raw*flate is the
--               optional lua-zlib rock (ExifTool hasZlib).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'FLIF'

local checkTags = { 'Artist', 'Creator', 'XResolution', 'ProfileCMMType', 'XMP' }

-- test 2: Extract information from FLIF.flif
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FLIF.flif')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Edit FLIF information
do
    local testnum = 3
    local exifTool = lexiftool.new()
    if exifTool:hasZlib() then  -- (`eval { require IO::Uncompress::RawInflate and require IO::Compress::RawDeflate }`)
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.jpg', 'ICC_Profile')
        exifTool:SetNewValue('EXIF:XResolution', 234)
        exifTool:SetNewValue('XMP:Creator', 'just me')
        local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.flif'
        os.remove(testfile)
        exifTool:WriteInfo(T_DIR .. '/images/FLIF.flif', testfile)
        local info = exifTool:ImageInfo(testfile, table.unpack(checkTags))
        if check(exifTool, info, testname, testnum) then
            os.remove(testfile)
            ok(true, 'test 3 matches')
        else
            ok(false, 'test 3 matches')
        end
    else
        ok(true, 'test 3 # skip Requires IO::Compress::RawDeflate')
    end
end

-- test 4: Delete FLIF information
local testfile
do
    local testnum = 4
    local exifTool = lexiftool.new()
    if exifTool:hasZlib() then
        exifTool:SetNewValue('ICC_Profile', nil, { Protected = 1 })
        exifTool:SetNewValue('EXIF', nil, { Protected = 1 })
        exifTool:SetNewValue('XMP:all', nil)
        testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.flif'
        os.remove(testfile)
        exifTool:WriteInfo(T_DIR .. '/images/FLIF.flif', testfile)
        local info = exifTool:ImageInfo(testfile)
        if check(exifTool, info, testname, testnum) then
            ok(true, 'test 4 matches')
        else
            testfile = nil
            ok(false, 'test 4 matches')
        end
    else
        ok(true, 'test 4 # skip Requires IO::Compress::RawDeflate')
    end
end

-- test 5: Add back FLIF information
do
    local testnum = 5
    if testfile ~= nil then
        local exifTool = lexiftool.new()
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/Photoshop.psd', 'ICC_Profile')
        exifTool:SetNewValue('EXIF:XResolution', 123)
        exifTool:SetNewValue('XMP:Creator', 'me again')
        local testfile2 = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.flif'
        os.remove(testfile2)
        exifTool:WriteInfo(testfile, testfile2)
        local info = exifTool:ImageInfo(testfile2, table.unpack(checkTags))
        if check(exifTool, info, testname, testnum) then
            os.remove(testfile)
            os.remove(testfile2)
            ok(true, 'test 5 matches')
        else
            ok(false, 'test 5 matches')
        end
    else
        ok(true, 'test 5 # skip Requires test 4 pass')
    end
end

-- test 6: Delete all then add back in one step
do
    local testnum = 6
    local exifTool = lexiftool.new()
    if exifTool:hasZlib() then
        exifTool:SetNewValue('all', nil)
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/Photoshop.psd', 'ICC_Profile')
        exifTool:SetNewValue('EXIF:XResolution', 456)
        exifTool:SetNewValue('XMP:Creator', 'me too')
        testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.flif'
        os.remove(testfile)
        exifTool:WriteInfo(T_DIR .. '/images/FLIF.flif', testfile)
        local info = exifTool:ImageInfo(testfile, table.unpack(checkTags))
        if check(exifTool, info, testname, testnum) then
            os.remove(testfile)
            ok(true, 'test 6 matches')
        else
            ok(false, 'test 6 matches')
        end
    else
        ok(true, 'test 6 # skip Requires IO::Compress::RawDeflate')
    end
end

done()
