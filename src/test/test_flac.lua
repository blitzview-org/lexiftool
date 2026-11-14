--------------------------------------------------------------------------------
-- File:         test/test_flac.lua
-- Ported from:  t/FLAC.t
--
-- Description:  Lua port of tests 1-3 of the upstream FLAC.t (the Perl
--               original): extracts information from t/images/FLAC.flac
--               and t/images/FLAC.ogg and compares against the vendored
--               standard output (t/FLAC_2.out, t/FLAC_3.out).
--
-- Port notes:   Read-only scope: tests 2-3 of the upstream numbering are
--               ported (test 3 exercises the Ogg-FLAC container path).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'FLAC'

-- test 2: Extract information from FLAC.flac
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FLAC.flac')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from FLAC.ogg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FLAC.ogg')
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

done() -- end
