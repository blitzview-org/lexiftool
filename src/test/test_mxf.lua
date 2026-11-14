--------------------------------------------------------------------------------
-- File:         test/test_mxf.lua
-- Ported from:  t/MXF.t
--
-- Description:  Lua port of test 2 of the upstream MXF.t (the Perl
--               original): extracts information from t/images/MXF.mxf
--               (KLV partition walk, Primer-driven local sets, track group
--               naming), comparing against the vendored standard output.
--
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MXF'

-- test 2: Extract information from MXF.mxf
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/MXF.mxf')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done()
