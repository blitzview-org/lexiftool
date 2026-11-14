--------------------------------------------------------------------------------
-- File:         test/test_canonvrd.lua
-- Ported from:  t/CanonVRD.t
--
-- Description:  Lua port of the read tests of the upstream CanonVRD.t (the
--               Perl original): extracts information from
--               t/images/CanonVRD.vrd and t/images/CanonVRD.dr4 and compares
--               against the vendored standard output (t/CanonVRD_2.out,
--               t/CanonVRD_13.out).
--
-- Port notes:   Read-only scope: tests 2 and 13 are ported.  Tests 3-12 and
--               14-24 are write-path tests (SetNewValue/WriteInfo), not
--               applicable to this read-only port.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'CanonVRD'

-- test 2: Extract information from CanonVRD.vrd
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/CanonVRD.vrd')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- tests 3-12: writing, deleting and creating VRD information
-- (write path, out of scope)

-- test 13: Extract information from CanonVRD.dr4
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/CanonVRD.dr4')
    ok(check(exifTool, info, testname, 13), 'test 13 matches')
end

-- tests 14-24: writing, deleting and creating DR4 information
-- (write path, out of scope)

done() -- end
