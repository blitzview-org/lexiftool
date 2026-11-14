--------------------------------------------------------------------------------
-- File:         test/test_postscript.lua
-- Ported from:  t/PostScript.t
--
-- Description:  Lua port of the upstream PostScript.t (the Perl original):
--               test 2 extracts information from t/images/PostScript.eps and
--               compares against the vendored standard output
--               (t/PostScript_2.out); test 3 writes EPS information copied
--               from IPTC.jpg/XMP.jpg and reads it back with ExtractEmbedded.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PostScript'

-- test 2: Extract information from PostScript.eps
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PostScript.eps')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write EPS information (and test ExtractEmbedded option)
do
    local testnum = 3
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/IPTC.jpg', '*:*')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/XMP.jpg', '*:*')
    exifTool:SetNewValue('Title', 'new title')
    exifTool:SetNewValue('Copyright', 'my copyright')
    exifTool:SetNewValue('Creator', 'phil made it', { Replace = 1 })
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.eps'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/PostScript.eps', testfile)
    local info = exifTool:ImageInfo(testfile, { ExtractEmbedded = 1 })
    if check(exifTool, info, testname, testnum, testnum, 3) then
        os.remove(testfile)
        ok(true, 'test 3 matches')
    else
        ok(false, 'test 3 matches')
    end
end

done() -- end
