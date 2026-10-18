--------------------------------------------------------------------------------
-- File:         test/test_json.lua
-- Ported from:  t/JSON.t
--
-- Description:  Lua port of test 2 of the upstream JSON.t (the Perl
--               original): extracts information from t/images/JSON.json and
--               compares against the vendored standard output
--               (t/JSON_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'JSON'

-- test 2: Extract information from a JSON file
do
    local exifTool = lexiftool.new()
    exifTool:Options('Struct', 2)
    exifTool:Options('MissingTagValue', 'null')
    local info = exifTool:ImageInfo(T_DIR .. '/images/JSON.json')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
