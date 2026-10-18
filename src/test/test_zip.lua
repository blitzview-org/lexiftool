--------------------------------------------------------------------------------
-- File:         test/test_zip.lua
-- Ported from:  t/ZIP.t
--
-- Description:  Lua port of tests 2-8 of the upstream ZIP.t (the Perl
--               original): extracts information from t/images/ZIP.{zip,gz,rar}
--               and from the four ZIP-based container formats
--               (OOXML.docx, CaptureOne.eip, iWork.numbers, OpenDoc.ods),
--               comparing against the vendored standard outputs
--               (t/ZIP_2.out .. t/ZIP_8.out).
--
-- Port notes:   All eight upstream tests are ported.  Upstream guards tests
--               4-7 with `eval 'require Archive::Zip'` and skips them when
--               that module is absent; this port reads the central directory
--               itself (ZIP.lua's ProcessZIP), so there is nothing to skip
--               and the four run unconditionally.  The trailing
--               module-version diagnostics of the original (Archive::Zip /
--               Compress::Raw::Zlib / IO::String) have no counterpart here
--               for the same reason.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'ZIP'
local testnum = 1

-- tests 2-3: Extract information from test ZIP and GZIP files
do
    for _, type_ in ipairs({ 'zip', 'gz' }) do
        testnum = testnum + 1
        local exifTool = lexiftool.new()
        local info = exifTool:ImageInfo(T_DIR .. '/images/ZIP.' .. type_)
        ok(check(exifTool, info, testname, testnum),
           'test ' .. testnum .. ' matches (' .. type_ .. ')')
    end
end

-- tests 4-7: Extract information from other ZIP-based files (requires Archive::Zip)
do
    for _, file in ipairs({ 'OOXML.docx', 'CaptureOne.eip', 'iWork.numbers', 'OpenDoc.ods' }) do
        testnum = testnum + 1
        local exifTool = lexiftool.new()
        local info = exifTool:ImageInfo(T_DIR .. '/images/' .. file)
        ok(check(exifTool, info, testname, testnum),
           'test ' .. testnum .. ' matches (' .. file .. ')')
    end
end

-- test 8: Extract information from test RAR version 5.0 file
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/ZIP.rar')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches')
end

done() -- end
