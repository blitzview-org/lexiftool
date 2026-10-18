--------------------------------------------------------------------------------
-- File:         test/test_tnef.lua
-- Ported from:  t/TNEF.t
--
-- Description:  Lua port of test 2 of the upstream TNEF.t (the Perl
--               original): extracts information from t/images/TNEF.tnef
--               and compares against the vendored standard output
--               (t/TNEF_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is
--               ported (the TNEF attribute reader + message-properties
--               reader + RTF decompressor).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'TNEF'

-- test 2: Extract information from TNEF.tnef
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/TNEF.tnef')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
