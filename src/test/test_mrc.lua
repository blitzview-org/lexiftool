--------------------------------------------------------------------------------
-- File:         test/test_mrc.lua
-- Ported from:  t/MRC.t
--
-- Description:  Lua port of test 2 of the upstream MRC.t (the Perl
--               original): extracts information from t/images/MRC.mrc and
--               compares against the vendored standard output (t/MRC_2.out).
--
-- Port notes:   Read-only scope: test 2 of the upstream numbering is ported
--               (the MRC header reader + the FEI1/FEI2 extended-header
--               reader with per-frame sub-document numbering).  The test
--               uses the upstream `ExtractEmbedded` option and the 4-group
--               check (topGroup 3) to capture the Doc1 sub-document.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MRC'

-- test 2: Extract information from MRC.mrc
do
    local exifTool = lexiftool.new()
    exifTool:Options('ExtractEmbedded', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/MRC.mrc')
    ok(check(exifTool, info, testname, 2, nil, 3), 'test 2 matches')
end

done() -- end
