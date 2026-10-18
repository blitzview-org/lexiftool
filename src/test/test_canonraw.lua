--------------------------------------------------------------------------------
-- File:         test/test_canonraw.lua
-- Ported from:  t/CanonRaw.t
--
-- Description:  Lua port of the upstream CanonRaw.t (the Perl original):
--               extracts information from t/images/CanonRaw.crw and compares
--               against the vendored standard output (t/CanonRaw_2.out).
--
-- Port notes:   All tests of CanonRaw.t, block for block.  Upstream's
--               `if (eval { require Time::Local })` guard is dropped (the
--               port's date conversions need no extra module).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local writeCheck = TestLib.writeCheck
local testVerbose = TestLib.testVerbose
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'CanonRaw'

-- test 2: Extract information from CRW
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/CanonRaw.crw')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Extract JpgFromRaw from CRW
do
    local exifTool = lexiftool.new()
    exifTool:Options('PrintConv', 0, 'IgnoreMinorErrors', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/CanonRaw.crw', 'JpgFromRaw')
    local val = info.JpgFromRaw
    ok(type(val) == 'table' and val.ref == 'SCALAR' and val.value == '<Dummy JpgFromRaw image data>',
        'test 3 matches')
end

-- test 4: Write a whole pile of tags to a CRW
do
    local testnum = 4
    local exifTool = lexiftool.new()
    -- set IgnoreMinorErrors option to allow invalid JpgFromRaw to be written
    exifTool:Options('IgnoreMinorErrors', 1)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg')
    exifTool:SetNewValue('SerialNumber', 1234)
    exifTool:SetNewValue('OwnerName', 'Phil Harvey')
    exifTool:SetNewValue('JpgFromRaw', 'not a real image')
    exifTool:SetNewValue('ROMOperationMode', 'CDN')
    exifTool:SetNewValue('FocalPlaneXSize', '35 mm')
    exifTool:SetNewValue('FocalPlaneYSize', '24 mm')
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.crw'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/CanonRaw.crw', testfile)
    local info = exifTool:ImageInfo(testfile)
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test 4 matches')
    else
        ok(false, 'test 4 matches')
    end
end

-- test 5: Test verbose output
ok(testVerbose(testname, 5, T_DIR .. '/images/CanonRaw.crw', 1), 'test 5 matches')

-- test 6: Write to CR2 file
do
    local testnum = 6
    local exifTool = lexiftool.new()
    -- set IgnoreMinorErrors option to allow invalid JpgFromRaw to be written
    exifTool:SetNewValue('Keywords', 'CR2 test')
    exifTool:SetNewValue('OwnerName', 'Phil Harvey')
    exifTool:SetNewValue('FocalPlaneXSize', '35mm')
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.cr2'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/CanonRaw.cr2', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum) and 1 or 0
    -- make sure file suffix was copied properly
    while success ~= 0 do -- luacheck: ignore 512 (upstream `while ($success) { ... last; }`)
        local fh = io.open(testfile, 'rb')
        if not fh then break end
        local endStr = '<Dummy preview image data>Non-TIFF data test'
        local len = #endStr
        if not fh:seek('end', -len) then fh:close() break end
        local buff = fh:read(len)
        fh:close()
        if buff == endStr then
            os.remove(testfile)
            success = 2
        else
            io.stderr:write('\n  Test ' .. testnum .. ' failed to copy file suffix:\n')
            io.stderr:write("    Test gave: '" .. tostring(buff) .. "'\n")
            io.stderr:write("    Should be: '" .. endStr .. "'\n")
            success = 0
        end
        break
    end
    if success == 1 then io.stderr:write('\n  Test ' .. testnum .. ': Error reading file suffix\n') end
    ok(success == 2, 'test 6 matches')
end

-- test 7: Test copying all information from a CR2 image to a JPEG
do
    local testnum = 7
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/CanonRaw.cr2')
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/Writer.jpg', testfile)
    exifTool:Options('Unknown', 1)
    local info = exifTool:ImageInfo(testfile)
    if check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test 7 matches')
    else
        ok(false, 'test 7 matches')
    end
end

-- test 8: Extract information from a CR3 image
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/CanonRaw.cr3')
    ok(check(exifTool, info, testname, 8), 'test 8 matches')
end

-- test 9: Write to CR3 file
do
    local writeInfo = {
        { 'Subject', 'CR3 test' },
        { 'ExposureCompensation', -1.3 },
    }
    ok(writeCheck(writeInfo, testname, 9, T_DIR .. '/images/CanonRaw.cr3'), 'test 9 matches')
end

done() -- end
