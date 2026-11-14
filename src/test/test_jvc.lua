--------------------------------------------------------------------------------
-- File:         test/test_jvc.lua
-- Ported from:  t/JVC.t
--
-- Description:  Lua port of the upstream JVC.t (the Perl original): extracts
--               information from t/images/JVC.jpg and compares against the
--               vendored standard output (t/JVC_2.out, t/JVC_3.out).
--
-- Port notes:   All tests are ported.  Upstream's tests 2 and 3 make the
--               identical ImageInfo call on the identical image (their
--               goldens are identical too), although the comments name
--               EXIF-based and text-based maker notes -- both are kept, as
--               upstream has them.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'JVC'

-- test 2: Extract information from EXIF-based JVC maker notes
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/JVC.jpg', { Group1 = 'JVC', Unknown = 1 })
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract information from text-based JVC maker notes
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/JVC.jpg', { Group1 = 'JVC', Unknown = 1 })
    ok(check(exifTool, info, testname, 3), 'test 3 matches')
end

done() -- end
