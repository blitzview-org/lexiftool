--------------------------------------------------------------------------------
-- File:         test/test_plist.lua
-- Ported from:  t/PLIST.t
--
-- Description:  Lua port of tests 2-4 of the upstream PLIST.t (the Perl
--               original): extracts information from t/images/PLIST-xml.plist,
--               t/images/PLIST-bin.plist and t/images/PLIST.aae and compares
--               against the vendored standard output (t/PLIST_2.out,
--               t/PLIST_3.out, t/PLIST_4.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PLIST'

-- tests 2-4: Extract information from PLIST files
local files = { 'PLIST-xml.plist', 'PLIST-bin.plist', 'PLIST.aae' }
for i, file in ipairs(files) do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/' .. file)
    ok(check(exifTool, info, testname, i + 1), 'test ' .. (i + 1) .. ' matches')
end

done() -- end
