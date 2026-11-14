--------------------------------------------------------------------------------
-- File:         test/test_asf.lua
-- Ported from:  t/ASF.t
--
-- Description:  Lua port of the upstream ASF.t (the Perl original):
--               extracts information from t/images/ASF.wmv and compares
--               against the vendored standard output (t/ASF_2.out).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'ASF'

-- test 2: Extract information from ASF.wmv
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ASF.wmv')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
