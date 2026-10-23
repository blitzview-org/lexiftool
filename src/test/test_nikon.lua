--------------------------------------------------------------------------------
-- File:         test/test_nikon.lua
-- Ported from:  t/Nikon.t
--
-- Description:  Lua port of the upstream Nikon.t (the Perl original):
--               extracts information from t/images/Nikon.jpg,
--               t/images/NikonD2Hs.jpg and t/images/Nikon.nef and compares
--               against the vendored standard output; verifies the Nikon
--               decryption algorithm and validates the nikonLensIDs table.
--
-- Port notes:   Tests 2-9 of the upstream numbering are ported. Test 7
--               (Nikon.nef) exercises the SubIFD 0x14a fan-out
--               (SubIFD/SubIFD1), the D70 maker-notes variants
--               (ColorBalance0103 -> ColorBalance3, LensData0101), the
--               NikonCapture data block (NikonCapture.lua) with its
--               embedded IPTC (the golden's IPTC2 block) and the NikonScan
--               IFD.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local TEST_DIR = TestLib.TEST_DIR
local writeCheck = TestLib.writeCheck
local perl = require('lexiftool.perl')

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Nikon'

-- test 2: Extract information from Nikon.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Nikon.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'Creator', 'Phil' },
        { 'ImageAdjustment', 'Yes, lots of it' },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Test writing all D70 image information
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/NikonD70.jpg')
    local testfile = TEST_DIR .. '/' .. testname .. '_4_failed.jpg'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, 4)
    if success then os.remove(testfile) end
    ok(success, 'test 4 matches')
end

-- test 5: Extract information from a D2Hs image
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/NikonD2Hs.jpg')
    ok(check(exifTool, info, testname, 5), 'test 5 matches')
end

-- test 7: Test reading NEF image
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/Nikon.nef')
    ok(check(exifTool, info, testname, 7), 'test 7 matches')
end

-- test 6: Test Nikon decryption
do
    local Nikon = require('lexiftool.Nikon')
    local n = 0x34a290d3
    local data = string.char((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
    data = Nikon.Decrypt(data, nil, nil, 0x12345678, 0x00000123)
    local b1, b2, b3, b4 = data:byte(1, 4)
    local got = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    ok(got == 0xcae17d2f, string.format('decryption returned expected value (got 0x%x)', got))
end

-- test 8: Test writing Nikon Capture information in NEF image
do
    local exifTool = lexiftool.new()
    exifTool:Options('IgnoreMinorErrors', 1)
    exifTool:SetNewValue('PhotoEffects', 'Off')
    exifTool:SetNewValue('Caption-abstract', 'A new caption')
    exifTool:SetNewValue('VignetteControlIntensity', '70')
    local testfile = TEST_DIR .. '/' .. testname .. '_8_failed.nef'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/Nikon.nef', testfile)
    local info = exifTool:ImageInfo(testfile, 'PhotoEffects', 'Caption-abstract', 'VignetteControlIntensity')
    local success = check(exifTool, info, testname, 8)
    if success then os.remove(testfile) end
    ok(success, 'test 8 matches')
end

-- test 9: Validate Nikon LensID values (internal check)
do
    local Nikon = require('lexiftool.Nikon')
    local lensIDs = Nikon.Composite.LensID.PrintConv
    local allValid = true
    local keys = {}
    for k in pairs(lensIDs) do keys[#keys + 1] = k end
    perl.tsort(keys)
    for _, k in ipairs(keys) do
        if k ~= 'Notes' and k ~= 'OTHER' then
            if not perl.matches(k, [[^(([0-9A-F]{2} ){7}[0-9A-F]{2}(\.\d+)?)$]]) then
                allValid = false
                io.stderr:write(string.format("\n  Bad LensID '%s' in test 9\n", tostring(k)))
                break
            end
        end
    end
    ok(allValid, 'nikonLensIDs keys are well-formed')
end

done() -- end
