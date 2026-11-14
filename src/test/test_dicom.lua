--------------------------------------------------------------------------------
-- File:         test/test_dicom.lua
-- Ported from:  t/DICOM.t
--
-- Description:  Lua port of test 2 of the upstream DICOM.t (the Perl
--               original): extracts information from t/images/DICOM.dcm
--               (DICM preamble + explicit-VR little-endian data elements),
--               comparing against the vendored standard output.
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

local testname = 'DICOM'

-- test 2: Extract information from DICOM.dcm
do
    local exifTool = lexiftool.new()
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/DICOM.dcm')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

done()
