--------------------------------------------------------------------------------
-- File:         test/test_pfm.lua
-- Ported from:  t/PFM.t
--
-- Description:  Lua port of test 2 of the upstream PFM.t (the Perl
--               original): extracts information from t/images/PFM.pfm and
--               compares against the vendored standard output (t/PFM_2.out).
--
-- Port notes:   All upstream tests are ported -- PFM.t is read-only.  The
--               format lives in `Other.pm` upstream (`use
--               Image::ExifTool::Other`), which this port has folded into
--               the ordinary file-type dispatch, so there is no separate
--               module to require here.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PFM'
local testnum = 1

-- test 2: Extract information from PFM.pfm
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PFM.pfm')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
