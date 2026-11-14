--------------------------------------------------------------------------------
-- File:         test/test_iso.lua
-- Ported from:  t/ISO.t
--
-- Description:  Lua port of test 2 of the upstream ISO.t (the Perl
--               original): extracts information from t/images/ISO.iso and
--               compares against the vendored standard output
--               (t/ISO_2.out).
--
-- Port notes:   upstream calls `$exifTool->ImageInfo('t/images/ISO.iso',
--               '-system:all')`, excluding the System (family 1) group via
--               the `ParseArguments`/`REQUESTED_TAGS` tag-filter engine
--               (not ported yet). This test uses the
--               already-supported `GetInfo({ Group1 = {...} })` selector
--               instead, allow-listing every group1 the golden output
--               actually contains (i.e. everything except System).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'ISO'

-- test 2: Extract information from an ISO file
do
    local exifTool = lexiftool.new()
    exifTool:ImageInfo(T_DIR .. '/images/ISO.iso')
    local info = exifTool:GetInfo({ Group1 = { 'ExifTool', 'File', 'ISO', 'Composite' } })
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
