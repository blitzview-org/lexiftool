--------------------------------------------------------------------------------
-- File:         test/test_aac.lua
-- Ported from:  t/AAC.t
--
-- Description:  Lua port of test 2 of the upstream AAC.t (the Perl
--               original): extracts information from t/images/AAC.aac and
--               compares against the vendored standard output
--               (t/AAC_2.out).
--
-- Port notes:   upstream calls `$exifTool->ImageInfo('t/images/AAC.aac',
--               'aac:*')`, restricting the returned tags to the AAC group
--               via the `ParseArguments`/`REQUESTED_TAGS` tag-filter engine
--               (not ported yet). This test uses the
--               already-supported `GetInfo({ Group0 = 'AAC' })` selector
--               instead, which selects the identical tag set for this
--               single-group test file.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'AAC'

-- test 2: Extract information from AAC test file
do
    local exifTool = lexiftool.new()
    exifTool:ImageInfo(T_DIR .. '/images/AAC.aac')
    local info = exifTool:GetInfo({ Group0 = 'AAC' })
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
