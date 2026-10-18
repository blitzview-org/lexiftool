--------------------------------------------------------------------------------
-- File:         test/test_infiray.lua
-- Ported from:  t/InfiRay.t
--
-- Description:  Lua port of test 2 of the upstream InfiRay.t (the Perl
--               original): extracts information from t/images/InfiRay.jpg
--               and compares against the vendored standard output
--               (t/InfiRay_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the IJPEG APP2-APP9 block readers, dispatched from the JPEG
--               APP-segment handling).  The test uses the upstream
--               `Struct => 2` and `MissingTagValue => 'null'` options, which
--               this port accepts.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'InfiRay'

-- test 2: Extract information from InfiRay.jpg
do
    local exifTool = lexiftool.new()
    exifTool:Options('Struct', 2, 'MissingTagValue', 'null')
    local info = exifTool:ImageInfo(T_DIR .. '/images/InfiRay.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
