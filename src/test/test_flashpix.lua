--------------------------------------------------------------------------------
-- File:         test/test_flashpix.lua
-- Ported from:  t/FlashPix.t
--
-- Description:  Lua port of test 2 of the upstream FlashPix.t (the Perl
--               original): extracts information from t/images/FlashPix.ppt
--               (the Windows Compound Binary reader -- FAT/mini-FAT chains,
--               directory walk, SummaryInformation/DocumentSummaryInformation/
--               CompObj/CurrentUser streams), comparing against the vendored
--               standard output.
--
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'FlashPix'

-- test 2: Extract information from FlashPix.ppt
-- (upstream's own test has no -filesize exclude, but its 11.78-era golden
--  predates FileSize being added to default output -- the vendored 13.59
--  binary emits it, so the golden is stale here; exclude FileSize to
--  compare everything else against the reference)
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FlashPix.ppt', '-filesize')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done()
