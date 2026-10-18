--------------------------------------------------------------------------------
-- File:         test/test_html.lua
-- Ported from:  t/HTML.t
--
-- Description:  Lua port of test 2 of the upstream HTML.t (the Perl
--               original): extracts information from t/images/HTML.html and
--               compares against the vendored standard output
--               (t/HTML_2.out).
--
-- Port notes:   All upstream tests are ported -- HTML.t is read-only.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'HTML'
local testnum = 1

-- test 2: Extract information from HTML.html
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/HTML.html')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
