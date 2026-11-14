--------------------------------------------------------------------------------
-- File:         test/test_text.lua
-- Ported from:  t/Text.t
--
-- Description:  Lua port of tests 2-7 of the upstream Text.t (the Perl
--               original): extracts information from t/images/Text1.txt ..
--               Text5.txt and t/images/Text.csv, comparing against the
--               vendored standard outputs (t/Text_2.out .. t/Text_7.out).
--
-- Port notes:   All upstream tests are ported -- Text.t is read-only.  Like
--               upstream, the System group is excluded ('-system:all'), so
--               the goldens carry only the format's own tags.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Text'
local testnum = 1

-- tests 2-7: Test various types of text files
do
    for i = 1, 6 do
        testnum = testnum + 1
        local fname = T_DIR .. '/images/' .. (i < 6 and ('Text' .. i .. '.txt') or 'Text.csv')
        local exifTool = lexiftool.new()
        local info = exifTool:ImageInfo(fname, '-system:all')
        ok(check(exifTool, info, testname, testnum),
           'test ' .. testnum .. ' matches (' .. fname:match('[^/]+$') .. ')')
    end
end

done() -- end
