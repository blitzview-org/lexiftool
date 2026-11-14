--------------------------------------------------------------------------------
-- File:         test/test_jxl.lua
-- Ported from:  t/JXL.t
--
-- Description:  Lua port of the upstream JXL.t (the Perl original):
--               extracts information from the raw JPEG XL codestream
--               t/images/JXL.jxl (2), writes some new information (3) and
--               reads compressed metadata from a partial codestream (4).
--
-- Port notes:   Test 4 reads the Brotli-compressed ('brob') EXIF/XMP boxes
--               of JXL2.jxl through IO::Uncompress::Brotli, i.e. the
--               required rock compress.brotli. Upstream skips the test
--               without the Perl module; here a missing module is a
--               failure, since the test status counts no skips as done.
--               (No version check: upstream's `VERSION >= 0.004` guards
--               against old Perl module releases, which have no Lua
--               counterpart.)
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local writeInfo = TestLib.writeInfo
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'JXL'

-- test 2: Extract information from JXL.jxl
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/JXL.jxl', '-system:all')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local testnum = 3
    local exifTool = lexiftool.new()
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jxl'
    os.remove(testfile)
    local writeInfoList = {
        { 'XMP:Subject', 'test subject' },
        { 'EXIF:Artist', 'test artist' },
    }
    exifTool:Options('IgnoreMinorErrors', 1)
    for _, v in ipairs(writeInfoList) do exifTool:SetNewValue(table.unpack(v)) end
    local wrote = writeInfo(exifTool, T_DIR .. '/images/JXL.jxl', testfile, nil, 1)
    local info = exifTool:ImageInfo(testfile, '-system:all')
    if check(exifTool, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test 3 matches')
    else
        ok(false, 'test 3 matches')
    end
end

-- test 4: Read compressed metadata and ImageSize from partial JXL codestream
do
    local testnum = 4
    if perl.evalRequire('IO::Uncompress::Brotli') then
        local exifTool = lexiftool.new()
        local info = exifTool:ImageInfo(T_DIR .. '/images/JXL2.jxl', 'imagesize', 'exif:all', 'xmp:all')
        ok(check(exifTool, info, testname, testnum), 'test 4 matches')
    else
        ok(false, 'test 4 matches (needs compress.brotli, see the port notes)')
    end
end

done()
