--------------------------------------------------------------------------------
-- File:         test/test_afcp.lua
-- Ported from:  t/AFCP.t
--
-- Description:  Lua port of the upstream AFCP.t (the Perl original):
--               extracts information from t/images/AFCP.jpg and compares
--               against the vendored standard output.
--
-- Port notes:   Read-only scope: test 2 is ported; test 3 (write path:
--               writing a bunch of information via the AFCP trailer) is out
--               of scope until the write path is ported.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'AFCP'
local testnum = 1

-- test 2: Extract information from AFCP.jpg
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/AFCP.jpg')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
