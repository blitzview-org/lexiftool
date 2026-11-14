--------------------------------------------------------------------------------
-- File:         test/test_bigtiff.lua
-- Ported from:  t/BigTIFF.t
--
-- Description:  Lua port of the upstream BigTIFF.t (the Perl original):
--               extracts information from t/images/BigTIFF.btf and compares
--               against the vendored standard output (t/BigTIFF_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'BigTIFF'

-- test 2: Extract information from BigTIFF.btf
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/BigTIFF.btf')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
