--------------------------------------------------------------------------------
-- File:         test/test_vcard.lua
-- Ported from:  t/VCard.t
--
-- Description:  Lua port of tests 2-3 of the upstream VCard.t (the Perl
--               original): extracts information from t/images/VCard.vcf
--               and t/images/VCard.ics and compares against the vendored
--               standard output (t/VCard_2.out, t/VCard_3.out).
--
-- Port notes:   Read-only scope: tests 2-3 of the upstream numbering are
--               ported (the line-based vCard/iCalendar reader with
--               continuation lines, component/document tracking and
--               parameter parsing).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'VCard'

-- tests 2-3: Extract information from VCard.vcf and VCard.ics
for _, ext in ipairs({ 'vcf', 'ics' }) do
    local testnum = (ext == 'vcf' and 2) or 3
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/VCard.' .. ext)
    ok(check(exifTool, info, testname, testnum), ('test %d matches (VCard.%s)'):format(testnum, ext))
end

done() -- end
