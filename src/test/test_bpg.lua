--------------------------------------------------------------------------------
-- File:         test/test_bpg.lua
-- Ported from:  t/BPG.t
--
-- Description:  Lua port of test 2 of the upstream BPG.t (the Perl
--               original): extracts information from t/images/BPG.bpg and
--               compares against the vendored standard output
--               (t/BPG_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'BPG'

-- test 2: Extract information from a BPG file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/BPG.bpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
