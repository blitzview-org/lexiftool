--------------------------------------------------------------------------------
-- File:         test/test_mini.lua
-- Ported from:  t/Mini.t
--
-- Description:  Lua port of the upstream Mini.t (the Perl original):
--               extracts information from t/images/Mini.avif (2), writes
--               EXIF and deletes XMP (3), and compresses EXIF and XMP (4).
--               Compress::Zlib is the required rock compress.zlib
--               (ExifTool hasZlib).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil and require('lexiftool.Mini') ~= nil, 'module loaded')

local testname = 'Mini'

-- test 2: Extract information from Mini.avif
do
    local exifTool = lexiftool:new()
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/Mini.avif')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write EXIF and delete XMP
do
    local testnum = 3
    local exifTool = lexiftool:new()
    exifTool:SetNewValue('EXIF:Artist', 'you know who')
    exifTool:SetNewValue('XMP:all', nil)
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.avif'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/Mini.avif', testfile)
    local info = exifTool:ImageInfo(testfile, 'EXIF:*', 'XMP:*', 'FileSize')
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test 3 matches')
    else
        ok(false, 'test 3 matches')
    end
end

-- test 4: Compress EXIF and XMP
do
    local testnum = 4
    local exifTool = lexiftool:new()
    if exifTool:hasZlib() then  -- (`eval 'require Compress::Zlib'`)
        exifTool:Options('Compress', 1)
        exifTool:Options('Compact', 'all')
        exifTool:SetNewValue('ForceWrite', 'xmp')
        local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.avif'
        os.remove(testfile)
        exifTool:WriteInfo(T_DIR .. '/images/Mini.avif', testfile)
        exifTool:Options('Unknown', 1)
        local info = exifTool:ImageInfo(testfile, 'ExifXmpCompressedFlag', 'EXIF:*', 'XMP:*')
        if check(exifTool, info, testname, testnum) then
            os.remove(testfile)
            ok(true, 'test 4 matches')
        else
            ok(false, 'test 4 matches')
        end
    else
        ok(true, 'test 4 # skip Requires Compress::Zlib')
    end
end

done()
