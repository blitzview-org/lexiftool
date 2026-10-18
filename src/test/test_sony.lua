--------------------------------------------------------------------------------
-- File:         test/test_sony.lua
-- Ported from:  t/Sony.t
--
-- Description:  Lua port of the upstream Sony.t (the Perl original):
--               extracts information from t/images/Sony.jpg and
--               t/images/Sony.pmp and compares against the vendored
--               standard output; verifies the Sony MakerNotes decryption
--               algorithm.
--
-- Port notes:   Tests 2-5 of the upstream numbering are ported.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Sony'

-- test 2: Extract information from Sony.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sony.jpg', { Unknown = 1 })
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'FlashFired', 'true' },
        { 'ISO', nil, n = 2 },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Test Sony decryption
do
    local Sony = require('lexiftool.Sony')
    local n = 0x34a290d3
    local data = string.char((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
    data = Sony.Decrypt(data, 0, 4, 0x12345678)
    local b1, b2, b3, b4 = data:byte(1, 4)
    local got = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    ok(got == 0x20677968, string.format('decryption returned expected value (got 0x%x)', got))
end

-- test 5: Extract information from a PMP image
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sony.pmp')
    ok(check(exifTool, info, testname, 5), 'test 5 matches')
end

done() -- end
