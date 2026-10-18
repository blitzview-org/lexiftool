--------------------------------------------------------------------------------
-- File:         test/test_moi.lua
-- Ported from:  t/MOI.t
--
-- Description:  Lua port of test 2 of the upstream MOI.t (the Perl
--               original): extracts information from t/images/MOI.moi and
--               compares against the vendored standard output
--               (t/MOI_2.out).
--
-- Port notes:   upstream calls `ImageInfo(file, '-system:*')`, excluding
--               the System group via the unported ParseArguments/Exclude
--               tag-filter engine (not ported yet). This test
--               builds the same filtered set by dropping family-1 System
--               tags from the full extraction result instead.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MOI'

-- test 2: Extract information from a MOI file
do
    local exifTool = lexiftool.new()
    local fullInfo = exifTool:ImageInfo(T_DIR .. '/images/MOI.moi')
    local info = {}
    for tag, val in pairs(fullInfo) do
        if exifTool:GetGroup(tag, 1) ~= 'System' then info[tag] = val end
    end
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
