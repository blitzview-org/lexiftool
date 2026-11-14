--------------------------------------------------------------------------------
-- File:         test/test_motorola.lua
-- Ported from:  t/Motorola.t
--
-- Description:  Lua port of tests 1/2 of the upstream Motorola.t (the Perl
--               original): extracts information from t/images/Motorola.jpg
--               and compares against the vendored standard output
--               (t/Motorola_2.out).
--
-- Port notes:   upstream calls `$exifTool->ImageInfo('t/images/Motorola.jpg',
--               'MakerNotes:*')`, restricting the returned tags to the
--               MakerNotes group via the `ParseArguments` tag-filter
--               argument form (not ported yet); this
--               test sets the `Unknown` option and uses the
--               already-supported `GetInfo({ Group0 = 'MakerNotes' })`
--               selector instead, which selects the identical tag set.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Motorola'

-- test 2: Extract information from Motorola.jpg
do
    local exifTool = lexiftool.new()
    exifTool:Options('Unknown', 1)
    exifTool:ImageInfo(T_DIR .. '/images/Motorola.jpg')
    local info = exifTool:GetInfo({ Group0 = 'MakerNotes' })
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done() -- end
