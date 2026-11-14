--------------------------------------------------------------------------------
-- File:         test/test_lytro.lua
-- Ported from:  t/Lytro.t
--
-- Description:  Lua port of test 2 of the upstream Lytro.t (the Perl
--               original): extracts information from t/images/Lytro.lfp
--               and compares against the vendored standard output
--               (t/Lytro_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Lytro'

-- test 2: Extract information from a Lytro LFP file
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Lytro.lfp')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
