--------------------------------------------------------------------------------
-- File:         test/test_font.lua
-- Ported from:  t/Font.t
--
-- Description:  Lua port of tests 2-7 of the upstream Font.t (the Perl
--               original): extracts information from t/images/Font.{afm,dfont,
--               pfa,pfb,pfm,ttf} and compares against the vendored standard
--               outputs (t/Font_2.out .. t/Font_7.out).
--
-- Port notes:   Read-only scope: tests 2-7 of the upstream numbering are
--               ported. The TTC, WOFF and WOFF2 branches of ProcessFont are
--               deferred (no vendored fixtures reach them).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- Date/time tags in the goldens carry the host timezone offset; the test
-- harness tolerates timezone differences (see TestLib nearEnough), so no TZ
-- pinning is required and the tests pass regardless of the host timezone.
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Font'

-- tests 2-7: Extract information from various types of font files
-- (upstream Font.t calls ImageInfo with no options, so the default System
-- group tags -- FileName/FileSize/file dates -- are included like the
-- goldens; TestLib.check tolerates the per-machine file-date/permission and
-- ExifToolVersion differences)
local exts = { 'afm', 'dfont', 'pfa', 'pfb', 'pfm', 'ttf' }
local testnum = 1
for _, ext in ipairs(exts) do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Font.' .. ext)
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches (' .. ext .. ')')
end

done() -- end
