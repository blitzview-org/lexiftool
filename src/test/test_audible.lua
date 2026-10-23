--------------------------------------------------------------------------------
-- File:         test/test_audible.lua
-- Ported from:  t/Audible.t
--
-- Description:  Lua port of the upstream Audible.t (the Perl original):
--               extracts information from t/images/Audible.aa and compares
--               against the vendored standard output.
--
-- Port notes:   Complete: test 2 is the only test of Audible.t.  The M4B
--               `tags`/`meta`/`cvrx`/`tseg` tables are ported too, but no
--               vendored test image exercises them.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Audible'
local testnum = 1

-- test 2: Extract information from test file
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Audible.aa')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
