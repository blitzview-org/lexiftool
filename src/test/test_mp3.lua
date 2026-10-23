--------------------------------------------------------------------------------
-- File:         test/test_mp3.lua
-- Ported from:  t/MP3.t
--
-- Description:  Lua port of tests 1-2 of the upstream MP3.t (the Perl
--               original): extracts information from t/images/MP3.mp3 and
--               compares against the vendored standard output
--               (t/MP3_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is
--               ported (exercises the ID3v2.2 header + MPEG audio frame +
--               ID3v1 trailer path, via ID3.ProcessID3 and MPEG.
--               ParseMPEGAudio).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MP3'

-- test 2: Extract information from MP3.mp3
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/MP3.mp3')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
