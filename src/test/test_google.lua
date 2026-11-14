--------------------------------------------------------------------------------
-- File:         test/test_google.lua
-- Ported from:  t/Google.t
--
-- Description:  Lua port of test 2 of the upstream Google.t (the Perl
--               original): extracts information from t/images/Google.jpg
--               (XMP GCamera HDR-Plus maker note -> base64/decrypt/gunzip ->
--               protobuf; plus the XMP-referenced GainMap JPEG in the
--               trailer), comparing against the vendored standard output.
--               Upstream skips the test without IO::Uncompress::Gunzip;
--               this port has it over the required rock compress.zlib.
--
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Google'

-- test 2: Extract information from Google.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Google.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done()
