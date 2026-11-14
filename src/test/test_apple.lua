--------------------------------------------------------------------------------
-- File:         test/test_apple.lua
-- Ported from:  t/Apple.t
--
-- Description:  Lua port of tests 1/2 of the upstream Apple.t (the Perl
--               original): extracts information from t/images/Apple.jpg and
--               compares against the vendored standard output
--               (t/Apple_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is
--               ported; there is no test 3 (write path) in Apple.t.
--               Upstream calls `ImageInfo(file, '-file:all')`, excluding
--               the File family-0 group via the unported
--               ParseArguments/Exclude tag-filter engine (not ported
--               yet); this test builds the same filtered
--               set by dropping family-0 File tags from the full
--               extraction result instead (ExifToolVersion stays, since it
--               is family-0 ExifTool, not File).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Apple'

-- test 2: Extract information from Apple.jpg
do
    local exifTool = lexiftool.new()
    exifTool:Options('Unknown', 1, 'Composite', 0)
    local fullInfo = exifTool:ImageInfo(T_DIR .. '/images/Apple.jpg')
    local info = {}
    for tag, val in pairs(fullInfo) do
        if exifTool:GetGroup(tag, 0) ~= 'File' then info[tag] = val end
    end
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
