--------------------------------------------------------------------------------
-- File:         test/test_palm.lua
-- Ported from:  t/Palm.t
--
-- Description:  Lua port of test 2 of the upstream Palm.t (the Perl
--               original): extracts information from t/images/Palm.mobi and
--               compares against the vendored standard output (t/Palm_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the Palm DB header reader + the MOBI header reader + the
--               EXTH extended-header reader).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Palm'

-- test 2: Extract information from Palm.mobi
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Palm.mobi')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
