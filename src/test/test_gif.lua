--------------------------------------------------------------------------------
-- File:         test/test_gif.lua
-- Ported from:  t/GIF.t
--
-- Description:  Lua port of test 2 of the upstream GIF.t (the Perl
--               original): reads t/images/GIF.gif into memory and calls
--               the standalone ImageInfo() (not a method call, matching
--               upstream's `ImageInfo(\$gifImage)`), then compares against
--               the vendored standard output (t/GIF_2.out). Tests 3-5 of
--               the upstream suite are write-path tests and out of scope
--               for the read subset.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'GIF'

-- test 2: GIF file using data in memory
do
    local f = io.open(T_DIR .. '/images/GIF.gif', 'rb')
    local gifImage = f:read('a')
    f:close()
    local info = lexiftool.ImageInfo({ ref = 'SCALAR', value = gifImage })
    ok(check(nil, info, testname, 2), 'test 2 matches')
end

done() -- end
