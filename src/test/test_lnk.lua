--------------------------------------------------------------------------------
-- File:         test/test_lnk.lua
-- Ported from:  t/LNK.t
--
-- Description:  Lua port of tests 2-3 of the upstream LNK.t (the Perl
--               original): extracts information from t/images/LNK.lnk and
--               t/images/LNK.url, comparing against the vendored standard
--               output (t/LNK_2.out, t/LNK_3.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'LNK'

-- test 2: Extract information from LNK.lnk
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/LNK.lnk')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from LNK.url
-- (upstream calls `ImageInfo('t/images/LNK.url', '-system:all')`, excluding
-- the System family-1 group via the unported ParseArguments tag-filter
-- engine; this test uses the already-supported `GetInfo({Group1={...}})`
-- selector instead, matching the ISO.t precedent)
do
    local exifTool = lexiftool.new()
    exifTool:ImageInfo(T_DIR .. '/images/LNK.url')
    local info = exifTool:GetInfo({ Group1 = { 'ExifTool', 'File', 'LNK' } })
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

done() -- end
