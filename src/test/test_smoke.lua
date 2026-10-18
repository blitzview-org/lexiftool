--------------------------------------------------------------------------------
-- File:         test/test_smoke.lua
--
-- Description:  smoke test for the base machinery: vendored test image,
--               perl facade primitives, ExifTool object and options, and a
--               first tag extraction from t/images/ExifTool.jpg
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

local img = T_DIR .. '/images/ExifTool.jpg'

local fh = io.open(img, 'rb')
ok(fh ~= nil, 'vendored test image readable')
local head = fh and fh:read(8) or ''
if fh then fh:close() end
is(0xFF, perl.ord(head, 1), 'JPEG magic byte 1')
is(0xD8, perl.ord(head, 2), 'JPEG magic byte 2')

local stat = perl.stat(img)
ok(stat ~= nil, 'stat vendored test image')
ok(stat.mode == 'file', 'stat mode is file')

local et = lexiftool.new()
ok(et ~= nil, 'ExifTool object created')
et:Options('Duplicates', 1)
is(1, et:Options('Duplicates'), 'Options set/get')

local info = et:ImageInfo(img)
is('26 kB', info.FileSize, 'FileSize formatted (26 kB)')
-- FileSize raw value (ValueConv) is the byte count
et:Options('PrintConv', 0)
is(tonumber(et:GetInfo().FileSize), stat.size, 'FileSize ValueConv matches stat')
et:Options('PrintConv', 1)

local sizes = { 'FileSize', 'FileType', 'FileTypeExtension', 'MIMEType', 'ExifToolVersion' }
for i = 1, #sizes do
    ok(perl.D(info[sizes[i]]), 'tag extracted: ' .. sizes[i])
end
is('JPEG', info.FileType, 'FileType is JPEG')
is('jpg', info.FileTypeExtension, 'FileTypeExtension is jpg')
is('image/jpeg', info.MIMEType, 'MIMEType is image/jpeg')

local gl = et:GetTagList(info, 'Group0')
ok(#gl >= 5, 'GetTagList returns the found tags')
local groups = et:GetGroups('FileSize')
is('File', groups[0], 'GetGroup 0 File')
is('System', groups[1], 'GetGroup 1 System')
is('Other', groups[2], 'GetGroup 2 Other')
is('FileSize', et:GetTagID('FileSize'), 'GetTagID FileSize')
is('File Size', et:GetDescription('FileSize'), 'GetDescription FileSize')

local g2 = et:GetGroups(2)
local hasOther = false
for i = 1, #g2 do
    if g2[i] == 'Other' then hasOther = true end
end
is(true, hasOther, 'GetGroups by family includes Other')

is('x.a', TestLib.formatValue('x.a'), 'formatValue scalar')
is('[1,ab]', TestLib.formatValue({ 1, 'ab' }), 'formatValue array')
is('{a=1,b=2}', TestLib.formatValue({ a = 1, b = 2 }), 'formatValue hash')
is('', TestLib.formatValue(nil), 'formatValue nil')
is('a.bc', TestLib.formatValue('a\001b\000c'), 'formatValue control chars')

local cmpA = TEST_DIR .. '/_cmp_a.tmp'
local cmpB = TEST_DIR .. '/_cmp_b.tmp'
local function writeTmp(name, contents)
    local w = io.open(name, 'wb')
    w:write(contents)
    w:close()
end
writeTmp(cmpA, 'one\ntwo\n')
writeTmp(cmpB, 'one\ntwo\n')
is(true, TestLib.testCompare(cmpA, cmpB), 'testCompare identical')
writeTmp(cmpB, 'one\nTWO\n')
is(false, TestLib.testCompare(cmpA, cmpB), 'testCompare differs')
-- the .out carries the upstream version; our current VERSION must match
writeTmp(cmpA, 'ExifToolVersion : 12.00\n')
writeTmp(cmpB, 'ExifToolVersion : ' .. lexiftool.VERSION .. '\n')
is(true, TestLib.testCompare(cmpA, cmpB), 'testCompare version tolerance (old .out)')
writeTmp(cmpB, 'ExifToolVersion : 99.99\n')
is(false, TestLib.testCompare(cmpA, cmpB), 'testCompare unrelated version rejected')
writeTmp(cmpA, 'ExifToolVersion : ' .. lexiftool.VERSION .. '\n')
writeTmp(cmpB, 'ExifToolVersion : ' .. lexiftool.VERSION .. '\n')
is(true, TestLib.testCompare(cmpA, cmpB), 'testCompare exact version match')
os.remove(cmpA)
os.remove(cmpB)

TestLib.check(et, info, 'Smoke', 1)
local seenFileSize = false
local seenVersion = false
local cf = io.open(TEST_DIR .. '/Smoke_1.failed', 'r')
if cf then
    for line in cf:lines() do
        if line:find('[File, System, Other] FileSize - File Size: ', 1, true) then
            seenFileSize = true
        end
        if line:find('[ExifTool, ExifTool, ExifTool] ExifToolVersion - ExifTool Version Number: ', 1, true) then
            seenVersion = true
        end
    end
    cf:close()
    os.remove(TEST_DIR .. '/Smoke_1.failed')
end
is(true, seenFileSize, 'check() line format FileSize')
is(true, seenVersion, 'check() line format ExifToolVersion')

-- Warn/FoundTag on a fresh object, before any ExtractInfo: Perl creates the
-- members on first access (expected values from Perl)
do
    local fresh = lexiftool.new()
    local okWarn = pcall(function() fresh:Warn('hello'); fresh:Warn('hello') end)
    is(true, okWarn, 'Warn on a fresh object')
    local warnInfo = fresh:GetInfo('Warning')
    is('hello', warnInfo and warnInfo.Warning, 'GetInfo Warning on a fresh object')
    local fresh2 = lexiftool.new()
    local okFound, key = pcall(function() return fresh2:FoundTag('Make', 'X') end)
    is('Make', okFound and key or nil, 'FoundTag on a fresh object')
    is('X', fresh2:GetValue('Make'), 'GetValue after FoundTag on a fresh object')
end

-- ThumbnailTIFF rebuilt by Exif GenerateTIFF: the StripOffsets entry (0x111)
-- is patched in its value field, not its count (expected values from Perl:
-- `exiftool -b -ThumbnailTIFF t/images/DNG.dng` holds count 1, offset 216)
do
    local dng = lexiftool.new()
    local tiffInfo = dng:ImageInfo(T_DIR .. '/images/DNG.dng', 'ThumbnailTIFF')
    local tiff = tiffInfo.ThumbnailTIFF
    tiff = type(tiff) == 'table' and tiff.value or ''
    is(408, #tiff, 'DNG ThumbnailTIFF length')
    -- (the 7th of 15 IFD entries, big-endian: 10 + 6 * 12 = 82)
    local tag, count, offset = perl.unpack('n x2 N N', perl.substr(tiff, 82, 12))
    is(0x111, tag, 'DNG ThumbnailTIFF entry 7 is StripOffsets')
    is(1, count, 'DNG ThumbnailTIFF StripOffsets count')
    is(216, offset, 'DNG ThumbnailTIFF StripOffsets value')
end

-- Exif ExtractImage takes the image from the EXIF block when it lies inside
-- (EXIF_POS, not the MRW segment position, is the base) -- expected value
-- from Perl: `exiftool -b -j t/images/Minolta.mrw`
do
    local mrw = lexiftool.new()
    mrw:Options('Binary', 1)
    local mrwInfo = mrw:ImageInfo(T_DIR .. '/images/Minolta.mrw')
    local preview = mrwInfo.PreviewImage
    is('<Dummy preview image data>', type(preview) == 'table' and preview.value or preview,
       'Minolta.mrw PreviewImage from the EXIF block')
end

TestLib.done()