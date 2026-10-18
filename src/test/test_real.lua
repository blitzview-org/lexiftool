--------------------------------------------------------------------------------
-- File:         test/test_real.lua
-- Ported from:  t/Real.t
--
-- Description:  Lua port of tests 2-4 of the upstream Real.t (the Perl
--               original): extracts information from t/images/Real.rm,
--               Real.ra and Real.ram and compares against the vendored
--               standard outputs (t/Real_2.out, t/Real_3.out, t/Real_4.out).
--
-- Port notes:   Read-only scope: tests 2-4 of the upstream numbering are
--               ported (the RealMedia chunk reader + the RealAudio header
--               reader + the RealMedia Metafile line reader).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Real'

-- test 2: Extract information from a RealMedia file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Real.rm')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from a RealAudio file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Real.ra')
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

-- test 4: Extract information from a RealAudio Metafile
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Real.ram')
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

done() -- end
