--------------------------------------------------------------------------------
-- File:         test/test_opus.lua
-- Ported from:  t/Opus.t
--
-- Description:  Lua port of tests 1-2 of the upstream Opus.t (the Perl
--               original): extracts information from t/images/Opus.opus
--               and compares against the vendored standard output
--               (t/Opus_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is
--               ported (exercises the Ogg container + Opus + Vorbis
--               comments + embedded FLAC.Picture block path).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Opus'

-- test 2: Extract information from Opus.opus
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Opus.opus')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
