--------------------------------------------------------------------------------
-- File:         test/test_writer.lua
-- Ported from:  t/Writer.t
--
-- Description:  Lua port of the upstream Writer.t (the Perl original): the
--               write-path test suite, asserted against the vendored
--               goldens (Writer_N.out); a few own do-blocks add coverage of
--               single write mechanisms.
--
-- Port notes:   Asserted: tests 2-61 (test 21 truncates through
--               perl.truncate, i.e. lexiftool.sys.ftruncate).
--               Test 61 parses with the facade's Time::Piece strptime
--               (perl.TimePieceStrptime).
--               `SetNewValuesFromFile` (Writer.pl:1254) is ported in full;
--               the own SetNewValuesFromFile do-block below stays as extra
--               coverage.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local perl = require('lexiftool.perl')
local ok = TestLib.ok
local check = TestLib.check
local writeInfo = TestLib.writeInfo
local binaryCompare = TestLib.binaryCompare
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Writer'

-- tests 2/3: Test writing new comment to JPEG file and removing it again
do
    local exifTool = lexiftool.new()
    local testfile1 = TEST_DIR .. '/' .. testname .. '_2_failed.jpg'
    os.remove(testfile1)
    exifTool:SetNewValue('Comment', 'New comment in JPG file')
    local wrote2 = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile1)
    local info = exifTool:ImageInfo(testfile1)
    ok(wrote2 and check(nil, info, testname, 2), 'test 2 matches')

    local testfile2 = TEST_DIR .. '/' .. testname .. '_3_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue('Comment')
    local wrote3 = writeInfo(exifTool, testfile1, testfile2)
    local same = wrote3 and binaryCompare(testfile2, T_DIR .. '/images/Canon.jpg')
    if same then
        os.remove(testfile1)
        os.remove(testfile2)
    end
    ok(same, 'test 3 matches (binary identical to original after removing comment)')
end

-- tests 4/5: Test editing a TIFF in memory then changing it back again
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1, 'Unknown', 1)
    local newtiff = { ref = 'SCALAR' }
    exifTool:SetNewValue('Headline', 'A different headline')
    exifTool:SetNewValue('ImageDescription', 'Modified TIFF')
    exifTool:SetNewValue('Keywords', 'another keyword', { AddValue = 1 })
    exifTool:SetNewValue('xmp:SupplementalCategories', 'new XMP info')
    local wrote4 = exifTool:WriteInfo(T_DIR .. '/images/ExifTool.tif', newtiff) == 1
    local info = exifTool:ImageInfo(newtiff)
    ok(wrote4 and check(exifTool, info, testname, 4), 'test 4 matches')

    local newtiff2 = { ref = 'SCALAR' }
    exifTool:SetNewValue() -- clear all the changes
    exifTool:SetNewValue('Headline', 'headline')
    exifTool:SetNewValue('ImageDescription', 'The picture caption')
    exifTool:SetNewValue('Keywords', 'another keyword', { DelValue = 1 })
    exifTool:SetNewValue('SupplementalCategories')
    local wrote5 = exifTool:WriteInfo(newtiff, newtiff2) == 1
    local testfile = TEST_DIR .. '/' .. testname .. '_5_failed.tif'
    if wrote5 then
        local fh = io.open(testfile, 'wb')
        fh:write(newtiff2.value:tostring())  -- (the written scalar is a carray, doc/api.md §4)
        fh:close()
    end
    local same5 = wrote5 and binaryCompare(testfile, T_DIR .. '/images/ExifTool.tif')
    if same5 then os.remove(testfile) end
    ok(same5, 'test 5 matches (binary identical to original after reverting changes)')
end

-- Multi-IFD JPEG Exif rewrite: not itself a full Writer.t test -- tests 6/7
-- need five more features on top of this (TimeCodes conv, several per-tag
-- Writable-format edits, IPTC length limits, JPEG-embedded XMP) -- but real coverage for the new WriteExif engine
-- and WriteJPEGExifSegment: write IFD0:DateTimeOriginal (Canon.jpg only has
-- one originally, in ExifIFD) and confirm it lands in the requested group
-- while InteropIFD and MakerNotes survive the multi-IFD rewrite unchanged;
-- then revert with no explicit group and confirm the IFD0 copy is gone
-- again, leaving only ExifIFD's. Per Writer.t's own tests 6/7 golden for
-- this same tag/scenario, a write with an explicit Group doesn't just add a
-- copy there -- it's "exactly one occurrence, in the requested or default
-- group", so the original ExifIFD occurrence is expected to disappear here
-- too (Writer_6.out has only a single "Date/Time Original" line, in IFD0).
do
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_multiifd_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('IFD0:DateTimeOriginal', '2005:01:01 00:00:00')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    ok(wrote, 'multi-IFD test: write succeeded')

    local ifd0Info = exifTool:ImageInfo(testfile, { Group1 = 'IFD0' })
    ok(ifd0Info.DateTimeOriginal == '2005:01:01 00:00:00', 'multi-IFD test: IFD0 copy set')
    local exifIfdInfo = exifTool:ImageInfo(testfile, { Group1 = 'ExifIFD' })
    ok(exifIfdInfo.DateTimeOriginal == nil, 'multi-IFD test: ExifIFD copy removed (exactly one occurrence)')
    local interopInfo = exifTool:ImageInfo(testfile, { Group1 = 'InteropIFD' })
    ok(interopInfo.InteropIndex == 'THM - DCF thumbnail file', 'multi-IFD test: InteropIFD preserved')
    local makerInfo = exifTool:ImageInfo(testfile, { Group1 = 'Canon' })
    ok(makerInfo.CanonModelID == 'EOS Digital Rebel / 300D / Kiss Digital', 'multi-IFD test: MakerNotes preserved')

    local testfile2 = TEST_DIR .. '/' .. testname .. '_multiifd2_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue() -- clear all the changes (matches Writer.t test 7's own SetNewValue())
    exifTool:SetNewValue('DateTimeOriginal', '2003:12:04 06:46:52') -- no group: default (ExifIFD)
    local wrote2 = writeInfo(exifTool, testfile, testfile2)
    ok(wrote2, 'multi-IFD test: revert write succeeded')
    local ifd0Info2 = exifTool:ImageInfo(testfile2, { Group1 = 'IFD0' })
    ok(ifd0Info2.DateTimeOriginal == nil, 'multi-IFD test: IFD0 copy removed on revert')
    local exifIfdInfo2 = exifTool:ImageInfo(testfile2, { Group1 = 'ExifIFD' })
    ok(exifIfdInfo2.DateTimeOriginal == '2003:12:04 06:46:52', 'multi-IFD test: ExifIFD copy restored')

    if wrote and wrote2 then
        os.remove(testfile)
        os.remove(testfile2)
    end
end

-- IPTC dataset max-length enforcement (Writer.t tests 6/7 gap #5): Category
-- (record 2:15) is declared Format => 'string[0,3]' in IPTC.lua, and
-- upstream silently truncates an oversized write rather than erroring --
-- Writer_6.out's golden shows the 9-character input 'IPTC test' truncated
-- to 'IPT'.
do
    local exifTool = lexiftool.new()
    local newtiff = { ref = 'SCALAR' }
    exifTool:SetNewValue('Category', 'IPTC test')
    local wrote = exifTool:WriteInfo(T_DIR .. '/images/ExifTool.tif', newtiff) == 1
    local info = exifTool:ImageInfo(newtiff)
    ok(wrote, 'IPTC length limit test: write succeeded')
    ok(info.Category == 'IPT', 'IPTC length limit test: Category truncated to declared max length')
end

-- IPTC embedded directly in a JPEG APP13 (Photoshop) segment: found while
-- running the real Writer.t test 6/7 sequence below -- the IPTC length
-- test above only exercised IPTC.WriteIPTC via ExifTool.tif's TIFF
-- ApplicationRecord path (WriteTIFF), never a standalone JPEG APP13
-- segment (WriteJPEG had no APP13/'8BIM' resource-block support at all).
-- Canon.jpg has no existing APP13 segment, so this also exercises
-- "insert a brand-new one" (the SOS-time fallback in WriteJPEG, same
-- pattern as the JPEG XMP case above), plus reverting removes the whole
-- segment again (not just leaving an empty '8BIM' resource block behind --
-- a real bug caught by the combined test 6/7 sequence: IPTC.WriteIPTC
-- returns an empty string, not nil, when every dataset was deleted).
do
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_jpegiptc_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('Category', 'IPTC test')
    -- (ignore warnings: upstream's FormatIPTC warns "[Minor] IPTC:Category
    --  exceeds length limit (truncated)" here, as perl 5.42 confirms)
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile, nil, true)
    ok(wrote, 'JPEG IPTC test: write succeeded')
    local info = exifTool:ImageInfo(testfile)
    ok(info.Category == 'IPT', 'JPEG IPTC test: Category readable back from JPEG APP13')

    local testfile2 = TEST_DIR .. '/' .. testname .. '_jpegiptc2_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue('Category')
    local wrote2 = writeInfo(exifTool, testfile, testfile2)
    ok(wrote2, 'JPEG IPTC test: revert write succeeded')
    local info2 = exifTool:ImageInfo(testfile2)
    ok(info2.Category == nil and info2.CurrentIPTCDigest == nil,
        'JPEG IPTC test: APP13 segment fully removed on revert, not left empty')

    if wrote and wrote2 then
        os.remove(testfile)
        os.remove(testfile2)
    end
end

-- XMP embedded directly in a JPEG APP1 segment (Writer.t tests 6/7 gap #6):
-- previously WriteJPEG only had EXIF-in-APP1 and TIFF-ApplicationNotes
-- (embedded-in-TIFF) XMP write support, not a JPEG's own standalone APP1
-- XMP packet (upstream's $xmpAPP1hdr-prefixed segment). Canon.jpg has no
-- existing XMP segment at all, so this also exercises "insert a brand-new
-- APP1-XMP segment" (via the newly added SOS-time fallback in WriteJPEG),
-- not just "edit an existing one" -- see XMP.WriteXMP's own from-scratch
-- packet builder (already used by the TIFF ApplicationNotes case).
do
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_jpegxmp_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('xmp:Description', 'New description')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    ok(wrote, 'JPEG XMP test: write succeeded')
    local info = exifTool:ImageInfo(testfile, { Group1 = 'XMP-dc' })
    ok(info.Description == 'New description', 'JPEG XMP test: dc:Description readable back from JPEG APP1')
    if wrote then os.remove(testfile) end
end

-- Per-tag Writable-format write pipeline (Writer.t tests 6/7 gap #3):
-- rational (ExposureCompensation), enum PrintConvInverse (LightSource,
-- FocalPlaneResolutionUnit), an explicit ValueConv-bypass via the Type
-- option (Flash) and via the '#' tag-name suffix (Orientation). Canon.jpg
-- also has a MakerNotes:Canon tag literally named "ExposureCompensation"
-- (a real duplicate-tag-name collision, not a test bug), so this reads back with an explicit Group1
-- selector to disambiguate rather than a plain info.ExposureCompensation
-- lookup.
do
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_writable_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('EXIF:ExposureCompensation', 999)
    exifTool:SetNewValue('LightSource', 'cloud')
    exifTool:SetNewValue('EXIF:Flash', '0x1', { Type = 'ValueConv' })
    exifTool:SetNewValue('Orientation#', 3)
    exifTool:SetNewValue('FocalPlaneResolutionUnit', 'mm')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    ok(wrote, 'Writable-format test: write succeeded')

    local exifIfdInfo = exifTool:ImageInfo(testfile, { Group1 = 'ExifIFD' })
    -- Canon.jpg's own MakerNotes also has a tag literally named
    -- "ExposureCompensation" (a real duplicate-name collision, not ours);
    -- since that's found first, ours lands under the numbered-duplicate
    -- key this port's GetInfo always assigns a same-named tag found in a
    -- different group (independent of the Duplicates option, which only
    -- affects whether GetInfo *exposes* duplicates, not this internal
    -- storage key).
    ok(exifIfdInfo['ExposureCompensation (1)'] == '+999', 'Writable-format test: rational ExposureCompensation')
    ok(exifIfdInfo.LightSource == 'Cloudy', 'Writable-format test: PrintConvInverse LightSource')
    ok(exifIfdInfo.Flash == 'Fired', 'Writable-format test: ValueConv-bypass Flash (Type option)')
    ok(exifIfdInfo.FocalPlaneResolutionUnit == 'mm', 'Writable-format test: PrintConvInverse FocalPlaneResolutionUnit')
    local ifd0Info = exifTool:ImageInfo(testfile, { Group1 = 'IFD0' })
    ok(ifd0Info.Orientation == 'Rotate 180', "Writable-format test: ValueConv-bypass Orientation ('#' suffix)")

    if wrote then os.remove(testfile) end
end

-- TimeCodes (Writer.t tests 6/7 gap #2): the only vendored test exercising
-- Exif.pm's bespoke BCD/SMPTE timecode conversion (tag 0xc763) -- ported
-- for both reading and writing in Exif.lua (timeCodesValueConv/
-- ValueConvInv/PrintConv/PrintConvInv). This is exactly Writer.t's own
-- test value/golden pair (`Writer_6.out`'s "Time Codes" line), split into
-- its own assertion here since this port's write path doesn't yet cover
-- the other tags needed for the real tests 6/7 end-to-end.
do
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_timecodes_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('TimeCodes', '02:53:49:07 2009-11-19T12:38:35:21-03:00')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    ok(wrote, 'TimeCodes test: write succeeded')
    local info = exifTool:ImageInfo(testfile, { Group1 = 'IFD0' })
    ok(info.TimeCodes == '02:53:49.07 2009-11-19T12:38:35.21-03:00', 'TimeCodes test: matches Writer_6.out golden text exactly')

    local testfile2 = TEST_DIR .. '/' .. testname .. '_timecodes2_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue('TimeCodes')
    local wrote2 = writeInfo(exifTool, testfile, testfile2)
    ok(wrote2, 'TimeCodes test: revert write succeeded')
    local info2 = exifTool:ImageInfo(testfile2, { Group1 = 'IFD0' })
    ok(info2.TimeCodes == nil, 'TimeCodes test: removed on revert')

    if wrote and wrote2 then
        os.remove(testfile)
        os.remove(testfile2)
    end
end

-- Writer.t tests 6/7 (the real vendored test numbers, all ten SetNewValue
-- edits): rewrite a JPEG file, then revert every edit. Test 6's golden
-- includes the exact FileSize, so it needs upstream's own byte layout
-- (since the Writer.pl WriteJPEG port it has it); test 7 reads test 6's
-- output, exactly like the real Writer.t.
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1, 'Unknown', 1)
    local testfile1 = TEST_DIR .. '/' .. testname .. '_6_failed.jpg'
    os.remove(testfile1)
    exifTool:SetNewValue('IFD0:DateTimeOriginal', '2005:01:01 00:00:00')
    exifTool:SetNewValue('xmp:Contrast', '+2')
    exifTool:SetNewValue('EXIF:ExposureCompensation', 999)
    exifTool:SetNewValue('LightSource', 'cloud')
    exifTool:SetNewValue('EXIF:Flash', '0x1', { Type = 'ValueConv' })
    exifTool:SetNewValue('Orientation#', 3)
    exifTool:SetNewValue('FocalPlaneResolutionUnit', 'mm')
    exifTool:SetNewValue('Category', 'IPTC test')
    exifTool:SetNewValue('xmp:Description', 'New description')
    exifTool:SetNewValue('TimeCodes', '02:53:49:07 2009-11-19T12:38:35:21-03:00')
    local wrote6 = writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile1, nil, true)
    local info6 = wrote6 and exifTool:ImageInfo(testfile1)
    ok(wrote6 and check(exifTool, info6, testname, 6), 'test 6 matches (real Writer_6.out golden)')

    exifTool:SetNewValue() -- clear all the changes
    exifTool:SetNewValue('DateTimeOriginal', '2003:12:04 06:46:52')
    exifTool:SetNewValue('xmp:Contrast')
    exifTool:SetNewValue('EXIF:ExposureCompensation', 0)
    exifTool:SetNewValue('LightSource')
    exifTool:SetNewValue('EXIF:Flash', '0x0', { Type = 'ValueConv' })
    exifTool:SetNewValue('Orientation#', 1)
    exifTool:SetNewValue('FocalPlaneResolutionUnit', 'in')
    exifTool:SetNewValue('Category')
    exifTool:SetNewValue('xmp:Description')
    exifTool:SetNewValue('TimeCodes')
    local image = { ref = 'SCALAR' }
    local wrote7 = exifTool:WriteInfo(testfile1, image) == 1
    exifTool:Options('Composite', 0)
    local info = exifTool:ImageInfo(image, '-filesize')
    ok(wrote7 and check(exifTool, info, testname, 7), 'test 7 matches (real Writer_7.out golden)')

    if wrote6 then os.remove(testfile1) end
end

-- Writer.t test 8: Test rewriting everything in a JPEG file. Reads every
-- tag out of Canon.jpg (Duplicates=>1, Binary=>1, ListJoin=>undef, i.e.
-- this port's List=>1, which returns unjoined array values instead of a
-- joined string per GetValue's own `not optOn(self.OPTIONS.List)` join
-- gate), calls SetNewValue(tag, value, Group=>group) for literally every
-- tag returned (round-tripping each value back unchanged), writes the
-- whole file out, then re-reads and compares against the real vendored
-- Writer_7.out (not a typo -- upstream's own `check($exifTool, $info,
-- $testname, $testnum, 7)` call passes 7 as an explicit $stdnum override,
-- since re-writing every tag back to its own original value should
-- reproduce exactly the same canonical decode of Canon.jpg that test 7
-- already ends up at after undoing its ten edits).
do
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1, 'Binary', 1, 'List', 1)
    local info = exifTool:ImageInfo(T_DIR .. '/images/Canon.jpg')
    for tag, val in pairs(info) do
        local group = exifTool:GetGroup(tag, 1)
        exifTool:SetNewValue(tag, val, { Group = group })
    end

    local image = { ref = 'SCALAR' }
    local wrote8 = exifTool:WriteInfo(T_DIR .. '/images/Canon.jpg', image) == 1
    -- (must drop Composite tags because their order may change; must
    -- ignore filesize because it changes as null padding is discarded)
    exifTool:Options('Unknown', 1, 'Binary', 0, 'List', nil, 'ListSep', ', ', 'Composite', 0)
    local info2 = wrote8 and exifTool:ImageInfo(image, '-filesize')
    ok(wrote8 and check(exifTool, info2, testname, 8, 7), 'test 8 matches (real Writer_7.out golden)')
end

-- Writer.t tests 11/12: "Try creating something from nothing and removing
-- it again (also test ListSplit and ListJoin options)". Writer.jpg is a
-- minimal fixture with NO Exif/IPTC/XMP/Ducky segments at all (bare
-- SOI/DQT/DQT/SOF0/DHT/SOS), so this exercises building a whole APP1 Exif
-- segment (with IFD0 -> ExifIFD/GPS sub-IFDs and their mandatory tags),
-- IPTC record 1 (EnvelopeRecord, previously unported -- FileVersion) and
-- record 2, an XMP dc:Contributor property, and a brand-new APP12 "Ducky"
-- segment, all completely from scratch, then reverting every edit and
-- binary-comparing back to the untouched original (test 12) -- which only
-- round-trips byte-identically because each write mechanism above also
-- knows how to cascade-delete its own auto-added mandatory/default tags
-- once nothing real is left (see fillAndPruneMandatory in lexiftool.lua
-- and fillAndPruneMandatoryRecords in IPTC.lua).
--
-- Upstream's own calls use `Group => 'EXIF'/'IPTC'/'XMP'/'GPS'` options on
-- SetNewValue; this port's SetNewValue only supports a "Group:Tag" name
-- prefix, so every group
-- option below is translated to that prefix form instead, matching the
-- convention already used throughout this file.
do
    local exifTool = lexiftool.new()
    exifTool:Options('ListSplit', ';\\s*')
    exifTool:Options('ListJoin', ' <<separator>> ')
    exifTool:SetNewValue('EXIF:DateTimeOriginal', '2005:01:19 13:37:22')
    exifTool:SetNewValue('IPTC:FileVersion', 12)
    exifTool:SetNewValue('XMP:Contributor', 'Guess who')
    exifTool:SetNewValue('GPS:GPSLatitude', "44 deg 14' 12.25\"")
    exifTool:SetNewValue('Ducky:Quality', 50)
    exifTool:SetNewValue('Keywords', 'this; that')
    local testfile1 = TEST_DIR .. '/' .. testname .. '_11_failed.jpg'
    os.remove(testfile1)
    local wrote11 = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile1)
    ok(wrote11, 'test 11 write succeeded')
    local info = wrote11 and exifTool:ImageInfo(testfile1)
    local success = wrote11 and check(exifTool, info, testname, 11)
    ok(success, 'test 11 matches (real Writer_11.out golden)')

    exifTool:SetNewValue('DateTimeOriginal')
    exifTool:SetNewValue('FileVersion')
    exifTool:SetNewValue('Contributor')
    exifTool:SetNewValue('GPSLatitude')
    exifTool:SetNewValue('Ducky:Quality')
    exifTool:SetNewValue('Keywords')
    local testfile2 = TEST_DIR .. '/' .. testname .. '_12_failed.jpg'
    os.remove(testfile2)
    local wrote12 = wrote11 and writeInfo(exifTool, testfile1, testfile2)
    ok(wrote12 and binaryCompare(T_DIR .. '/images/Writer.jpg', testfile2), 'test 12: revert matches Writer.jpg byte-for-byte')

    if wrote11 and success then os.remove(testfile1) end
    if wrote12 then os.remove(testfile2) end
end

-- SetNewValuesFromFile (Writer.pl:1254): own coverage, not a
-- vendored Writer.t test number -- see the file-header comment above for
-- why tests 9/10/13/15-18 (the real vendored tests that call it) still
-- can't pass their real goldens even with this ported.
do
    -- "transfer everything" (no tag list): copy every found tag from
    -- Canon.jpg onto a fresh ExifTool, then write it into Writer.jpg
    -- (which starts with no Exif segment at all). Only the tags this
    -- port's EXIF_WRITE_TAGS table actually knows how to write land; the
    -- rest are silently no-ops (matches upstream's own "delete this tag
    -- if we couldn't set it" -- SetNewValue's return value just isn't
    -- checked for tags this port doesn't recognize).
    local exifTool = lexiftool.new()
    local rtn = exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg')
    ok(rtn.DateTimeOriginal ~= nil, 'SetNewValuesFromFile (no tag list): DateTimeOriginal reported as set')
    ok(exifTool:IsNewValueSet('DateTimeOriginal'), 'SetNewValuesFromFile (no tag list): DateTimeOriginal pending')
    ok(exifTool:IsNewValueSet('Orientation'), 'SetNewValuesFromFile (no tag list): Orientation pending')

    local image = { ref = 'SCALAR' }
    local wrote = exifTool:WriteInfo(T_DIR .. '/images/Writer.jpg', image) == 1
    ok(wrote, 'SetNewValuesFromFile (no tag list): write succeeded')
    local info = wrote and exifTool:ImageInfo(image)
    ok(info and info.DateTimeOriginal == '2003:12:04 06:46:52',
        'SetNewValuesFromFile (no tag list): DateTimeOriginal round-tripped from Canon.jpg')
    ok(info and info.Orientation == 'Horizontal (normal)',
        'SetNewValuesFromFile (no tag list): Orientation round-tripped from Canon.jpg')
    ok(info and info.Flash == 'No Flash',
        'SetNewValuesFromFile (no tag list): Flash round-tripped from Canon.jpg')
    ok(info and info.FocalPlaneResolutionUnit == 'inches',
        'SetNewValuesFromFile (no tag list): FocalPlaneResolutionUnit round-tripped from Canon.jpg')

    -- plain bare tag-list (no group/wildcard/redirection): only the named
    -- tag(s) get copied, nothing else.
    local exifTool2 = lexiftool.new()
    local rtn2 = exifTool2:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg', 'Orientation')
    ok(exifTool2:IsNewValueSet('Orientation'), 'SetNewValuesFromFile (tag list): Orientation pending')
    ok(not exifTool2:IsNewValueSet('DateTimeOriginal'), 'SetNewValuesFromFile (tag list): DateTimeOriginal NOT pending (not requested)')
    ok(rtn2.DateTimeOriginal == nil, 'SetNewValuesFromFile (tag list): return table only has the requested tag')

    -- source given as an already-populated ExifTool instance rather than
    -- a filename (upstream: `UNIVERSAL::isa($srcFile,'Image::ExifTool')`)
    local srcEt = lexiftool.new()
    srcEt:ImageInfo(T_DIR .. '/images/Canon.jpg')
    local exifTool3 = lexiftool.new()
    exifTool3:SetNewValuesFromFile(srcEt, 'Flash')
    ok(exifTool3:IsNewValueSet('Flash'), 'SetNewValuesFromFile (ExifTool-instance source): Flash pending')
    ok(not exifTool3:IsNewValueSet('Orientation'), 'SetNewValuesFromFile (ExifTool-instance source): Orientation NOT pending (not requested)')
end

-- Writer.t tests 16-18: "Test SetNewValuesFromFile() order of operations"
do
    local argsList = {
        { 'ifd0:xresolution>xmp:*', 'ifd1:xresolution>xmp:*' },
        { 'ifd1:xresolution>xmp:*', 'ifd0:xresolution>xmp:*' },
        { '*:xresolution', '-ifd0:xresolution', 'xresolution>xmp:*' },
    }
    for k, args in ipairs(argsList) do
        local testnum = 15 + k
        local exifTool = lexiftool.new()
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/GPS.jpg', table.unpack(args))
        local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
        os.remove(testfile)
        writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
        local info = exifTool:ImageInfo(testfile, 'xresolution')
        local success = check(exifTool, info, testname, testnum)
        ok(success, 'test ' .. testnum .. ' matches')
        if success then os.remove(testfile) end
    end
end

-- Writer.t test 24: "Test redirection with expressions"
do
    local testnum = 24
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/FujiFilm.jpg',
        'Comment<ISO=$ISO Aperture=${EXIF:fnumber} Exposure=${shutterspeed}'
    )
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, 'Comment')
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t test 34: "copy list tag to list and non-list tags with different options"
do
    local testnum = 34
    local exifTool = lexiftool.new()
    exifTool:Options('ListJoin', nil)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/IPTC.jpg',
            { Replace = 1 },
            'xmp:subject<filename',
            'xmp:subject<iptc:keywords',
            'comment<iptc:keywords',
            { Replace = 0 },
            'xmp:HierarchicalSubject<filename',
            'xmp:HierarchicalSubject<iptc:keywords'
    )
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, 'xmp:subject', 'comment', 'HierarchicalSubject')
    local err
    if check(exifTool, info, testname, testnum) then
        -- make sure it was an array reference
        local val = info.Subject or ''
        if type(val) ~= 'table' then
            err = "Subject is not an ARRAY: '" .. tostring(val) .. "'"
        elseif #val ~= 3 then
            err = "Subject does not contain 3 values: '" .. table.concat(val, ', ') .. "'"
        end
        if err then
            io.stderr:write('\n  ' .. err .. '\n')
        else
            os.remove(testfile)
        end
    else
        err = 1
    end
    ok(not err, 'test ' .. testnum .. ' matches')
end

-- Writer.t test 9: "Test copying over information with SetNewValuesFromFile()
-- (including a transfer of the ICC_Profile record)"
do
    local testnum = 9
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/ExifTool.tif', 'ICC_Profile')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Nikon.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t test 10: Another SetNewValuesFromFile() test (the Pentax maker
-- notes with their preview image go into a Canon JPEG: WriteExif's
-- PREVIEW_INFO path)
do
    local testnum = 10
    local exifTool = lexiftool.new()
    exifTool:Options('IgnoreMinorErrors', 1)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Pentax.jpg')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t test 13: "Copy tags from CRW file to JPG"
do
    local testnum = 13
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/CanonRaw.crw')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t test 15: "Copy a specific set of tags"
do
    local testnum = 15
    local exifTool = lexiftool.new()
    local copyTags = { 'exififd:all', '-lightSource', 'ifd0:software' }
    -- also test new regular expression feature (ExifTool 9.15)
    copyTags[#copyTags + 1] = 'comment<${ make ; tr{ ,.}{_}; s{__}{_} } {cool, huh?}'
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Olympus.jpg', table.unpack(copyTags))
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t test 35: "Add back all information after deleting everything"
do
    local testnum = 35
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('*')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/ExifTool.jpg', 'all:all',
                                  'icc_profile', 'canonvrd')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/ExifTool.jpg', testfile, nil, 1)
    exifTool:Options('Composite', 0)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t test 42: "Test SetNewValuesFromFile with wildcards"
do
    local testnum = 42
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/ExifTool.jpg', 'ifd0:*<jfif:?resolution')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    exifTool:Options('Composite', 0)
    local info = exifTool:ImageInfo(testfile, '-file:all')
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches')
    if success then os.remove(testfile) end
end

-- Writer.t tests 28-30: "Check cross delete behaviour when deleting tags".
-- Writes ISO into both IFD0 and ExifIFD of the same file at once (an
-- otherwise-nonstandard duplicate -- ISO is normally ExifIFD-only), then
-- for each of 'EXIF'/'IFD0'/'ExifIFD' deletes ISO scoped to that group and
-- checks what survives: an unqualified/module-level delete ('EXIF:ISO')
-- removes both copies, but an explicit-physical-group delete
-- ('IFD0:ISO'/'ExifIFD:ISO') only removes that one copy, leaving the
-- sibling group's own value alone (applyExifTreeEdits in lexiftool.lua).
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('IFD0:ISO', 100)
    exifTool:SetNewValue('ExifIFD:ISO', 200)
    local tmpfile = TEST_DIR .. '/tmp.jpg'
    os.remove(tmpfile)
    local wroteTmp = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', tmpfile)
    ok(wroteTmp, 'test 28-30 setup: dual-group ISO write succeeded')

    local groups, testnums = { 'EXIF', 'IFD0', 'ExifIFD' }, { 28, 29, 30 }
    for i, group in ipairs(groups) do
        local testnum = testnums[i]
        exifTool:SetNewValue() -- reset values
        exifTool:SetNewValue(group .. ':ISO')
        local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
        os.remove(testfile)
        local wrote = wroteTmp and writeInfo(exifTool, tmpfile, testfile)
        local info = wrote and exifTool:ImageInfo(testfile, 'FileName', 'ISO')
        local success = wrote and check(exifTool, info, testname, testnum)
        ok(success, ('test %d matches (real Writer_%d.out golden)'):format(testnum, testnum))
        if success then os.remove(testfile) end
    end
    if wroteTmp then os.remove(tmpfile) end
end

-- Writer.t test 45: "Test writing different EXIF string encoding". With
-- Options(CharsetEXIF => 'Latin'), an EXIF ASCII-format string is
-- transcoded from UTF-8 to cp1252/Latin-1 bytes at write time (upstream
-- WriteExif.pl:585 `$strEnc = $et->Options('CharsetEXIF')`, applied per
-- ASCII tag with `$et->Encode($newValue, $strEnc)`, WriteExif.pl:1294) --
-- so writing UTF-8 "P\xc3\xaaro" (Pêro) lands as the raw byte "P\xearo"
-- in the file, which is what a *default* (no CharsetEXIF) read then
-- returns unchanged.
do
    local exifTool = lexiftool.new()
    exifTool:Options('CharsetEXIF', 'Latin')
    local testfile = TEST_DIR .. '/' .. testname .. '_45_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('EXIF:Artist', 'P\xc3\xaaro')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    exifTool:Options('CharsetEXIF', nil)
    local info = wrote and exifTool:ImageInfo(testfile, 'artist')
    local success = wrote and check(exifTool, info, testname, 45)
    ok(success, 'test 45 matches (real Writer_45.out golden)')
    -- (port-only addition) the read side of the same option: with
    -- CharsetEXIF => 'Latin' the Latin byte is decoded back to UTF-8
    -- (Exif.pm:6313/6789)
    exifTool:Options('CharsetEXIF', 'Latin')
    local info2 = wrote and exifTool:ImageInfo(testfile, 'artist')
    exifTool:Options('CharsetEXIF', nil)
    ok(info2 and info2.Artist == 'P\xc3\xaaro', 'test 45: CharsetEXIF read decodes Latin to UTF-8')
    if success then os.remove(testfile) end
end

-- Writer.t tests 32/33: "Read/Write ICC Profile tags". AsShotICCProfile
-- (0xc68f) and CurrentICCProfile (0xc691) are raw ('undef'-format) EXIF
-- IFD0 tags -- previously unread and unwritten by this port -- and
-- ICC_Profile itself (0x8773, already readable) gets a first write path
-- too. All three are Protected=1 in upstream (raw bytes in, no
-- PrintConvInverse), which this port's 'undef' EXIF_WRITE_TAGS kind
-- matches by construction (no PrintConv/ValueConv path at all).
do
    local exifTool = lexiftool.new()
    exifTool:Options('IgnoreMinorErrors', 1)
    local hdr = '\0\0\0\24ADBE\2\16\0\0mntrRGB XYZ '
    exifTool:SetNewValue('AsShotICCProfile', hdr .. '<dummy>', { Protected = 1 })
    exifTool:SetNewValue('CurrentICCProfile', hdr .. '<dummy 2>', { Protected = 1 })
    local testfile32 = TEST_DIR .. '/' .. testname .. '_32_failed.tif'
    os.remove(testfile32)
    local tags = { 'ICC_Profile', 'AsShotICCProfile', 'CurrentICCProfile' }
    local wrote32 = writeInfo(exifTool, T_DIR .. '/images/ExifTool.tif', testfile32)
    local info32 = wrote32 and exifTool:ImageInfo(testfile32, table.unpack(tags))
    ok(wrote32 and check(exifTool, info32, testname, 32), 'test 32 matches (real Writer_32.out golden)')

    exifTool:SetNewValue()
    exifTool:SetNewValue('ICC_Profile', hdr .. '<another dummy>', { Protected = 1 })
    local testfile33 = TEST_DIR .. '/' .. testname .. '_33_failed.tif'
    os.remove(testfile33)
    local wrote33 = writeInfo(exifTool, testfile32, testfile33)
    local info33 = wrote33 and exifTool:ImageInfo(testfile33, table.unpack(tags))
    local success33 = wrote33 and check(exifTool, info33, testname, 33)
    ok(success33, 'test 33 matches (real Writer_33.out golden)')
    if success33 then
        os.remove(testfile32)
        os.remove(testfile33)
    end
end

-- Writer.t test 36: "Test adding and deleting from the same list". A single
-- write call chains two ops on the same List tag (IPTC:Keywords) -- a
-- DelValue for a value that was never there (no-op, matches upstream's own
-- silent "not found" behaviour) followed by an AddValue -- exercising the
-- NEW_VALUE-as-per-tag-list refactor (commit 4580980): GetPendingEdits
-- already returned every op for a tag in call order, and IPTC.WriteIPTC
-- already looped over all of them, so this needed no new write-side
-- plumbing at all. It did surface a real read-side gap: ImageInfo's
-- 'GROUP:all' selector (e.g. 'IPTC:all') was being matched as a literal
-- tag named "all" instead of "every tag in that group" (GetInfo's
-- REQUESTED_TAGS loop in lexiftool.lua) -- fixed with a dedicated
-- reqGroup + bareReq=='all' branch ahead of the wildcard/exact-name checks.
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('IPTC:Keywords', 'out', { DelValue = 1 })
    exifTool:SetNewValue('IPTC:Keywords', 'in', { AddValue = 1 })
    local testfile = TEST_DIR .. '/' .. testname .. '_36_failed.jpg'
    os.remove(testfile)
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = wrote and exifTool:ImageInfo(testfile, 'IPTC:all')
    local success = wrote and check(exifTool, info, testname, 36)
    ok(success, 'test 36 matches (real Writer_36.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t tests 39-40: "Test writing only if the tag didn't already
-- exist". Each write call chains a "Tag => '', DelValue=>1" marker (never a
-- real delete by itself -- it removes nothing) with a plain set on the same
-- tag: upstream's IsOverwriting treats an empty DelValue list as
-- conditioning the whole edit on the tag's *old* value being empty/absent,
-- so the later set only lands when the tag isn't already there
-- (applyExifTreeEdits' conditionalCreate handling in lexiftool.lua, added
-- for this test). Ported directly against both real
-- Writer_39.out/Writer_40.out goldens: Writer.jpg has none of these three
-- tags yet (test 39 -- everything gets written), Canon.jpg already has real
-- values for all three (test 40 -- nothing changes). Upstream's own
-- writeCheck() also asserts WriteInfo() returns 2 ("nothing changed") for
-- test 40's `same` flag; this port's WriteInfo has no changed/unchanged
-- tracking (always returns 1 on success), so that specific return-code
-- assertion isn't reproduced, only the golden tag-value comparison.
do
    local writeOps = {
        { 'DateTimeOriginal', '', { DelValue = 1 } },
        { 'DateTimeOriginal#', '1999:99:99 99:99:99' },
        { 'XResolution', '', { DelValue = 1 } },
        { 'XResolution', '123' },
        { 'ResolutionUnit', '', { DelValue = 1 } },
        { 'ResolutionUnit', 'cm' },
    }
    local checkTags = { 'FileName', 'DateTimeOriginal', 'XResolution', 'ResolutionUnit' }

    local exifTool = lexiftool.new()
    for _, op in ipairs(writeOps) do exifTool:SetNewValue(table.unpack(op)) end
    local testfile39 = TEST_DIR .. '/' .. testname .. '_39_failed.jpg'
    os.remove(testfile39)
    local wrote39 = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile39)
    local info39 = wrote39 and exifTool:ImageInfo(testfile39, { Duplicates = 1, Unknown = 1 }, checkTags)
    local success39 = wrote39 and check(exifTool, info39, testname, 39)
    ok(success39, 'test 39 matches (real Writer_39.out golden)')
    if success39 then os.remove(testfile39) end

    local exifTool2 = lexiftool.new()
    for _, op in ipairs(writeOps) do exifTool2:SetNewValue(table.unpack(op)) end
    local testfile40 = TEST_DIR .. '/' .. testname .. '_40_failed.jpg'
    os.remove(testfile40)
    -- `same` now that WriteInfo tracks changed/unchanged: Canon.jpg already
    -- has all three values, so nothing changes and WriteInfo returns 2 (but
    -- still writes the byte-identical output file)
    local wrote40 = writeInfo(exifTool2, T_DIR .. '/images/Canon.jpg', testfile40, true)
    local info40 = wrote40 and exifTool2:ImageInfo(testfile40, { Duplicates = 1, Unknown = 1 }, checkTags)
    local success40 = wrote40 and check(exifTool2, info40, testname, 40)
    ok(success40, 'test 40 matches (real Writer_40.out golden)')
    if success40 then os.remove(testfile40) end
end

-- Writer.t test 59: "Test writing empty list elements". Writes
-- XMP-dc:Subject as a scalar with Options(ListSplit=>',') into Writer.jpg
-- (no pre-existing XMP), which must split ',a,,' into four items --
-- including the two trailing empty ones -- not the two non-empty pieces a
-- naive split would keep; reading back with Options(ListJoin=>';') then
-- rejoins them into 'Subject: ;a;;'. This needed three real fixes, not
-- just a namespace/tag addition:
--  - XMP.WriteXMP's ListSplit handling used perl.splitDyn with no limit
--    argument (defaults to stripping trailing empty fields); upstream's
--    own ConvInv passes limit -1 to keep them. Fixed here (and the same
--    latent bug in IPTC.WriteIPTC, not exercised by any IPTC fixture yet).
--  - GetPendingEdits' "Group:Tag" prefix regex didn't allow a hyphen in
--    the group name, so a real family-1 XMP namespace group like
--    'XMP-dc' (as opposed to the plain module name 'XMP') was never even
--    recognized as a group prefix at all -- the whole "XMP-dc:Subject"
--    string was treated as one literal (unmatched) tag name. Fixed, plus
--    a new '^xmp%-' branch so any 'XMP-*' prefix routes to the XMP writer
--    the same way EXIF_PHYSICAL_GROUPS routes 'IFD0'/'ExifIFD'/etc to EXIF.
--  - GetInfo's REQUESTED_TAGS group filter ('xmp:all' in this test's own
--    ImageInfo call) compared the requested group case-sensitively against
--    GetGroup's PascalCase output ('XMP'), so a lowercase request never
--    matched anything -- fixed to compare case-insensitively (matches
--    upstream, where group names in tag selectors are case-insensitive).
do
    local exifTool = lexiftool.new()
    exifTool:Options('ListSplit', ',')
    exifTool:Options('ListJoin', ';')
    exifTool:SetNewValue('XMP-dc:Subject', ',a,,')
    local testfile = TEST_DIR .. '/' .. testname .. '_59_failed.jpg'
    os.remove(testfile)
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = wrote and exifTool:ImageInfo(testfile, 'xmp:all')
    local success = wrote and check(exifTool, info, testname, 59)
    ok(success, 'test 59 matches (real Writer_59.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 19: "Test SaveNewValues()/RestoreNewValues()". Now the full
-- vendored golden (Writer_19.out): the Sharpness (0xa40a) blocker is fixed
-- (the root cause was never Sharpness's own ConvertParameter() PrintConvInv, which was
-- right all along; SetNewValue's Group option was silently a no-op, so
-- test 8's bare "rewrite everything" loop lost each tag's group scoping
-- and a same-named MakerNotes Canon:Sharpness edit collided with the newly
-- EXIF_WRITE_TAGS-registered Exif:Sharpness). Also exercises the real
-- SetNewValue Group option (now implemented, not just the 'Group:Tag'
-- name-prefix form used elsewhere in this file).
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('ISO', 25)
    exifTool:SetNewValue('Sharpness', '+1')
    exifTool:SetNewValue('Artist', 'Phil', { Group = 'IFD0' })
    exifTool:SetNewValue('Artist', 'Harvey', { Group = 'ExifIFD' })
    exifTool:SetNewValue('DateTimeOriginal', '2006:03:27 16:25:00')
    exifTool:SetNewValue('Keywords', 'one')
    exifTool:SetNewValue('Keywords', 'two', { AddValue = 1 })
    exifTool:SaveNewValues()
    exifTool:SetNewValue('Artist', 'nobody')
    exifTool:SetNewValue('Keywords', 'three')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/FujiFilm.jpg')
    ok(exifTool:GetNewValue('Orientation') ~= nil, 'SaveNewValues: SetNewValuesFromFile pending before restore')
    exifTool:RestoreNewValues()
    ok(exifTool:GetNewValue('Orientation') == nil, 'RestoreNewValues: SetNewValuesFromFile edits discarded')
    ok(exifTool:GetNewValue('Keywords') == 'one', 'RestoreNewValues: Keywords back to pre-save state')

    local testfile = TEST_DIR .. '/' .. testname .. '_19_failed.jpg'
    os.remove(testfile)
    local wrote19 = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    ok(wrote19, 'test 19 write succeeded')
    local info = wrote19 and exifTool:ImageInfo(testfile)
    local testOK = wrote19 and check(exifTool, info, testname, 19)
    ok(testOK, 'test 19 matches (real Writer_19.out golden)')

    -- test 20/21: Test edit in place (using the file from the last test)
    local size
    if testOK then
        local et = lexiftool.new()
        local newComment = 'This is a new test comment'
        et:SetNewValue('Comment', newComment)
        local wrote = writeInfo(et, testfile)
        local info20 = et:ImageInfo(testfile, 'Comment')
        if info20.Comment and info20.Comment == newComment and wrote then
            size = require('lfs').attributes(testfile).size
        else
            testOK = false
        end
    end
    ok(testOK, 'test 20 matches (edit in place)')

    -- test in-place edit of file passed by handle
    -- (truncate() is perl.truncate over lexiftool.sys.ftruncate, which every
    --  supported system has, so upstream's "# skip truncate() not supported
    --  on this system" counts as a failure here)
    if testOK then
        local et = lexiftool.new()
        local shortComment = 'short comment'
        et:SetNewValue('Comment', shortComment)
        local fh = io.open(testfile, 'r+b')   -- open test file for update
        et:WriteInfo(fh)
        fh:close()
        local info21 = et:ImageInfo(testfile, 'Comment')
        if info21.Comment and info21.Comment == shortComment then
            local newSize = require('lfs').attributes(testfile).size
            if newSize >= size then
                -- test to see if the file got shorter as it should have
                testOK = false
            end
        else
            testOK = false
        end
    end
    ok(testOK, 'test 21 matches (in-place edit by handle)')

    -- test 23: Test renaming a file from the value of DateTimeOriginal
    -- (upstream runs it only if test 21 passed)
    if testOK then
        local newfile = TEST_DIR .. '/' .. testname .. '_23_20060327_failed.jpg'
        os.remove(newfile)
        local et = lexiftool.new()
        et:Options('DateFormat', testname .. '_23_%Y%m%d_failed.jpg')
        et:SetNewValuesFromFile(testfile, 'FileName<DateTimeOriginal')
        writeInfo(et, testfile)
        local renamed = require('lfs').attributes(newfile) ~= nil and
                        require('lfs').attributes(testfile) == nil
        ok(renamed, 'test 23 matches (renamed from DateTimeOriginal)')
        if renamed then os.remove(newfile) end
    end
    if testOK then os.remove(testfile) end
end

-- (port-only addition) Exif ConvertParameter, the PrintConvInv of
-- Contrast/Saturation/Sharpness, matches /\bn/i etc. as upstream
-- (Exif.pm:5647): the printed values themselves ("Normal", "Hard") are
-- capitalized, and a word need not come first ("very high")
do
    local ConvertParameter = require('lexiftool.Exif').ConvertParameter
    local want = { Normal = 0, Soft = 1, Low = 1, Hard = 2, High = 2, ['very high'] = 2,
                   ['0.00'] = 0, ['-2'] = 1, ['+1'] = 2 }
    local good = true
    for val, code in pairs(want) do
        if ConvertParameter(nil, val) ~= code then good = false end
    end
    ok(good and ConvertParameter(nil, 'xyz') == nil, 'ConvertParameter as upstream')
end

-- (port-only addition) WriteCheck is called as ($self, $tagInfo, $val)
-- (Writer.pl:2995), CheckImage (Writer.pl:6845) rejects a non-JPEG and
-- previewImageTagInfo lets 'none' through.  Expected results from Perl:
-- SetNewValue on the same tags returns these errors.  (Checked on ConvInv
-- directly, the call SetNewValue makes.)
do
    local Writer = require('lexiftool.Writer')
    local et = lexiftool.new()
    local jpeg = '\255\216\255\219xx'
    local cases = {
        -- table, tag ID, write group, value, expected error (nil = accepted)
        { 'lexiftool.Olympus.Main', 0x100, 'Olympus', 'notajpeg', '[Minor] Not a valid image for Olympus:ThumbnailImage' },
        { 'lexiftool.Olympus.Main', 0x100, 'Olympus', 'none', '[Minor] Not a valid image for Olympus:ThumbnailImage' },
        { 'lexiftool.Olympus.Main', 0x100, 'Olympus', jpeg, nil },
        { 'lexiftool.Olympus.Main', 0x280, 'Olympus', 'notajpeg', '[Minor] Not a valid image for Olympus:PreviewImage' },
        { 'lexiftool.Olympus.Main', 0x280, 'Olympus', 'none', nil },
        { 'lexiftool.Minolta.Main', 0x81, 'Minolta', 'notajpeg', '[Minor] Not a valid image for Minolta:PreviewImage' },
        { 'lexiftool.Minolta.Main', 0x81, 'Minolta', jpeg, nil },
        { 'lexiftool.Panasonic.Leica6', 0x300, 'Leica', 'notajpeg', 'Not a valid image for Leica:PreviewImage' },
        { 'lexiftool.Panasonic.Leica6', 0x300, 'Leica', 'none', nil },
        { 'lexiftool.Panasonic.Leica6', 0x300, 'Leica', jpeg, nil },
    }
    local good = true
    for _, c in ipairs(cases) do
        local tagInfo = et:GetTagTable(c[1])[c[2]]
        local val, err = Writer.ConvInv(et, c[4], tagInfo, tagInfo.Name, c[3], 'ValueConv')
        if err ~= c[5] or (c[5] == nil and val ~= c[4]) then good = false end
    end
    ok(good, 'WriteCheck ($self, $tagInfo, $val) and CheckImage as upstream')
end

-- Writer.t test 14: Delete all information in a group
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('All', nil, { Group = 'MakerNotes' })
    local testfile = TEST_DIR .. '/' .. testname .. '_14_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, 14)
    ok(success, 'test 14 matches (real Writer_14.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 22: Test time shift feature
do
    local writeInfoList = {
        { 'DateTimeOriginal', '1:2', { Shift = 1 } },
        { 'ModifyDate', '2:1: 3:4', { Shift = 1 } },
        { 'CreateDate', '200 0', { Shift = -1 } },
        { 'DateCreated', '20:', { Shift = -1 } },
    }
    ok(TestLib.writeCheck(writeInfoList, testname, 22, T_DIR .. '/images/XMP.jpg', 1),
        'test 22 matches (real Writer_22.out golden)')
end

-- Writer.t tests 25/26: Test order of delete operations
for i = 0, 1 do
    local testnum = 25 + i
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Nikon.jpg', 'all:all', '-makernotes:all')
    if i == 1 then exifTool:SetNewValue('fnumber', 26) end
    exifTool:SetNewValue('exififd:all') -- delete all exifIFD
    if i == 0 then exifTool:SetNewValue('fnumber', 25) end
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches (real Writer_' .. testnum .. '.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 27: Check that mandatory EXIF resolution tags get taken from JFIF
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('exif:all') -- delete all EXIF
    local testfile = TEST_DIR .. '/' .. testname .. '_27_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/ExifTool.jpg', testfile)
    exifTool:SetNewValue()
    exifTool:SetNewValue('exif:datetimeoriginal', '2000:01:02 03:04:05')
    local wrote = writeInfo(exifTool, testfile)
    local info = exifTool:ImageInfo(testfile, 'XResolution', 'YResolution', 'DateTimeOriginal')
    local success = check(exifTool, info, testname, 27) and wrote
    ok(success, 'test 27 matches (real Writer_27.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t tests 37-38: Create EXIF file from EXIF block and individual tags
for i = 0, 1 do
    local testnum = 37 + i
    local exifTool = lexiftool.new()
    local tags = { }
    if i == 0 then
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/Sony.jpg', 'EXIF')
        exifTool:Options('PrintConv', 0)
        tags = { 'FileSize', 'Compression' }
    else
        exifTool:SetNewValuesFromFile(T_DIR .. '/images/Sony.jpg')
        exifTool:Options('PrintConv', 1, 'Unknown', 1)
    end
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.exif'
    os.remove(testfile)
    writeInfo(exifTool, nil, testfile)
    local info = exifTool:ImageInfo(testfile, table.unpack(tags))
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test ' .. testnum .. ' matches (real Writer_' .. testnum .. '.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 41: Test writing Kodak APP3 and Canon CIFF Meta information
do
    local writeInfoList = {
        { 'Meta:SerialNumber', '12345' },
        { 'CIFF:OwnerName', 'CIFF Write Test' },
    }
    local check41 = { 'SerialNumber', 'OwnerName' }
    ok(TestLib.writeCheck(writeInfoList, testname, 41, T_DIR .. '/images/ExifTool.jpg', check41),
        'test 41 matches (real Writer_41.out golden)')
end

-- Writer.t test 43: Test increment feature EXIF
do
    local writeInfoList = {
        { 'ExposureTime', '1.5', { Shift = 1 } },
        { 'SerialNumber', '-9', { Shift = -1 } }, -- (two negatives make a positive)
        { 'MeteringMode', '1', { Shift = 0, AddValue = 1 } },
    }
    ok(TestLib.writeCheck(writeInfoList, testname, 43, T_DIR .. '/images/Canon.jpg', 1),
        'test 43 matches (real Writer_43.out golden)')
end

-- Writer.t test 44: Test increment feature with XMP
do
    local writeInfoList = {
        { 'XMP:ApertureValue', '-0.1', { Shift = 1 } }, -- increment
        { 'XMP:FNumber', '28/10', { DelValue = 1 } }, -- conditional delete
        { 'XMP:DateTimeOriginal', '3', { Shift = 0, AddValue = 1 } }, -- shift
    }
    ok(TestLib.writeCheck(writeInfoList, testname, 44, T_DIR .. '/images/XMP.xmp', 1),
        'test 44 matches (real Writer_44.out golden)')
end

-- Writer.t test 31: Delete all but EXIF (excluding IFD1) and IPTC information
do
    local testnum = 31
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('*')
    exifTool:SetNewValue('EXIF:*', nil, { Replace = 2 })
    exifTool:SetNewValue('ifd1:all')
    exifTool:SetNewValue('IPTC:*', nil, { Replace = 2 })
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/ExifTool.jpg', testfile, nil, true)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    if success then os.remove(testfile) end
    ok(success, 'test 31 matches (real Writer_31.out golden)')
end

-- Writer.t test 46: Test writing with wildcards
do
    local testnum = 46
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValue('A*', '7')
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    if success then os.remove(testfile) end
    ok(success, 'test 46 matches (real Writer_46.out golden)')
end

-- Writer.t test 47: Test various WriteMode settings
do
    local testnum = 47
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)                                 -- Should the tag be written?
    exifTool:Options('WriteMode', 'w')                  -- --- write existing tags only:
    exifTool:SetNewValue('ISO', 150)                    -- yes (already exists)
    exifTool:SetNewValue('ImageDescription', 'N')       -- no  (doesn't already exist)
    exifTool:Options('WriteMode', 'c')                  -- --- create new tags only:
    exifTool:SetNewValue('ApertureValue', 8.0)          -- no  (already exists)
    exifTool:SetNewValue('UserComment', 'No')           -- no  (exists, albeit empty)
    exifTool:SetNewValue('Artist', 'Phil')              -- yes (doesn't already exist)
    exifTool:SetNewValue('XMP:Subject', 'No')           -- no  (shouldn't create new group)
    exifTool:Options('WriteMode', 'cg')                 -- --- also create new groups:
    exifTool:SetNewValue('IPTC:Keywords', 'Y')          -- yes (should create new group)
    exifTool:Options('Composite', 0, 'FastScan', 2)
    writeInfo(exifTool, T_DIR .. '/images/Canon.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, '-time:all')
    local success = check(exifTool, info, testname, testnum)
    if success then os.remove(testfile) end
    ok(success, 'test 47 matches (real Writer_47.out golden)')
end

-- Writer.t tests 48-50: More WriteMode 'cg' tests, and test AddUserDefinedTags()
do
    local testnum = 48
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    local exifTool = lexiftool.new()
    exifTool:Options('WriteMode', 'cg')
    exifTool:SetNewValue('XMP-dc:Title', 'A')
    exifTool:SetNewValue('XMP:Subject', 'A')
    exifTool:SetNewValue('XMP:LocationCreated', '{city=A}')
    exifTool:SetNewValue('XMP:Flash', '{fired=true}')
    exifTool:SetNewValue('IPTC:Keywords', 'A')
    exifTool:SetNewValue('IPTC:City', 'A')
    exifTool:SetNewValue('EXIF:Artist', 'A')
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, '-time:all', '-filename')
    ok(check(exifTool, info, testname, testnum), 'test 48 matches (real Writer_48.out golden)')
    -- (not upstream: every test file shares this Lua state.  Writing the
    --  LocationCreated structure makes AddNewStruct cache a PropertyPath in
    --  the shared sLocationDetails field definitions, which a later flattening
    --  copies into LocationShownCity -- perl 5.42 shows the same "no list
    --  index" error when XMP.t test 47 follows in one process -- so the cache
    --  is taken out again)
    for _, fieldInfo in pairs(lexiftool.GetTagTable(nil, 'lexiftool.XMP.iptcExt').LocationCreated.Struct) do
        if type(fieldInfo) == 'table' then fieldInfo.PropertyPath = nil end
    end

    testnum = 49
    local testfile2 = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile2)
    exifTool:SetNewValue()
    exifTool:SetNewValue('XMP-dc:Title', 'B')
    exifTool:SetNewValue('XMP:Subject', 'B')
    exifTool:SetNewValue('XMP:LocationCreated', '{city=B}')
    exifTool:SetNewValue('XMP:Flash', '{fired=false}')
    exifTool:SetNewValue('IPTC:Keywords', 'B')
    exifTool:SetNewValue('IPTC:City', 'B')
    exifTool:SetNewValue('EXIF:Artist', 'B')
    local same = writeInfo(exifTool, testfile, testfile2, 1)
    if same then
        os.remove(testfile)
        os.remove(testfile2)
    else
        info = exifTool:ImageInfo(testfile2, '-time:all', '-filename')
        check(exifTool, info, testname, testnum, testnum - 1)
    end
    ok(same, 'test 49 matches (file unchanged by WriteMode cg)')

    testnum = 50
    testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    lexiftool.AddUserDefinedTags('lexiftool.XMP.dc', { test = { } })
    exifTool:SetNewValue()
    exifTool:SetNewValue('XMP-dc:Title', 'A')
    exifTool:SetNewValue('XMP-dc:Test', 'B')
    writeInfo(exifTool, nil, testfile)
    info = exifTool:ImageInfo(testfile, 'xmp:all')
    local success = check(exifTool, info, testname, testnum)
    ok(success, 'test 50 matches (real Writer_50.out golden)')
    if success then os.remove(testfile) end
    -- (not upstream: every test file shares this Lua state, so the
    --  user-defined tag is taken out again -- upstream's process ends here)
    lexiftool.GetTagTable(nil, 'lexiftool.XMP.dc').test = nil
end

-- Writer.t test 51: Delete a unknown JPEG APP segment
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('APP6:*', nil)
    local testfile = TEST_DIR .. '/' .. testname .. '_51_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/ExifTool.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, 51)
    ok(success, 'test 51 matches (real Writer_51.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 52: Delete groups by family 2 group name
do
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('Image:*')
    exifTool:SetNewValue('Camera:*')
    local testfile = TEST_DIR .. '/' .. testname .. '_52_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/XMP.xmp', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, 52)
    ok(success, 'test 52 matches (real Writer_52.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 53: Exclude groups when copying
do
    local testnum = 53
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg', '-Exif:All', '-Canon:All')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile)
    local success = check(exifTool, info, testname, testnum)
    if success then os.remove(testfile) end
    ok(success, 'test 53 matches (real Writer_53.out golden)')
end

-- Writer.t test 54: Specify multiple groups when copying, excluding a single tag
do
    local testnum = 54
    local exifTool = lexiftool.new()
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg', 'Exif:Time:All', '-createdate')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, 'exif:*', '-image:all')
    local success = check(exifTool, info, testname, testnum)
    if success then os.remove(testfile) end
    ok(success, 'test 54 matches (real Writer_54.out golden)')
end

-- Writer.t tests 55-56: Create and edit EXV file
do
    local testnum = 55
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('Artist', 'me')
    exifTool:SetNewValue('Keywords', { 'one', 'two' })
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.exv'
    os.remove(testfile)
    writeInfo(exifTool, nil, testfile)
    local info = exifTool:ImageInfo(testfile, 'exif:*', 'iptc:*', 'xmp:*')
    ok(check(exifTool, info, testname, testnum), 'test 55 matches (real Writer_55.out golden)')

    testnum = 56
    exifTool:SetNewValue()
    exifTool:SetNewValue('Artist')
    exifTool:SetNewValue('Title', 'Test')
    local testfile2 = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.exv'
    os.remove(testfile2)
    writeInfo(exifTool, testfile, testfile2)
    info = exifTool:ImageInfo(testfile2, 'exif:*', 'iptc:*', 'xmp:*')
    local success = check(exifTool, info, testname, testnum)
    if success then
        os.remove(testfile)
        os.remove(testfile2)
    end
    ok(success, 'test 56 matches (real Writer_56.out golden)')
end

-- Writer.t test 57: Test setting Composite PreviewImage using various groups
do
    local okAll = true
    local exifTool = lexiftool.new()
    exifTool:Options('IgnoreMinorErrors', 1)
    local try = {
        ['previewimage']              = 1,
        ['composite:previewimage']    = 0,   -- (shouldn't be in the Composite group)
        ['composite:thumbnailimage']  = 0,
        ['composite:jpgfromraw']      = 0,
        ['composite:otherimage']      = 0,
        ['ifd0:previewimage']         = 1,
        ['0ifd0:previewimage']        = 0,
        ['1ifd0:previewimage']        = 1,
        ['2ifd0:previewimage']        = 0,
        ['exif:previewimage']         = 1,
        ['0exif:previewimage']        = 1,
        ['1exif:previewimage']        = 0,
        ['2exif:previewimage']        = 0,
        ['preview:previewimage']      = 1,
        ['0preview:previewimage']     = 0,
        ['1preview:previewimage']     = 0,
        ['2preview:previewimage']     = 1,
        ['makernotes:previewimage']   = 1,
        ['0makernotes:previewimage']  = 1,
        ['1makernotes:previewimage']  = 0,
        ['2makernotes:previewimage']  = 0,
        ['xxx:previewimage']          = 0,
        ['0xxx:previewimage']         = 0,
        ['1xxx:previewimage']         = 0,
        ['2xxx:previewimage']         = 0,
        ['ifd0:exif:preview:previewimage']    = 1,
        ['0ifd0:exif:preview:previewimage']   = 0,
        ['1ifd0:exif:preview:previewimage']   = 1,
        ['2ifd0:exif:preview:previewimage']   = 0,
        ['ifd0:0exif:preview:previewimage']   = 1,
        ['ifd0:1exif:preview:previewimage']   = 0,
        ['ifd0:2exif:preview:previewimage']   = 0,
        ['ifd0:exif:0preview:previewimage']   = 0,
        ['ifd0:exif:1preview:previewimage']   = 0,
        ['ifd0:exif:2preview:previewimage']   = 1,
        ['1ifd0:0exif:2preview:previewimage'] = 1,
        ['exif:makernotes:previewimage']      = 1,   -- (but wouldn't write anything)
    }
    local tags = { }
    for tag in pairs(try) do tags[#tags + 1] = tag end
    perl.tsort(tags)
    for _, tag in ipairs(tags) do
        local num = exifTool:SetNewValue(tag, 'test')
        if ((num or 0) ~= 0) ~= (try[tag] ~= 0) then
            io.stderr:write('\nError setting ' .. tag .. '\n')
            okAll = false
        end
    end
    ok(okAll, 'test 57 matches')
end

-- Writer.t test 58: Set ICC_Profile from an external file
do
    local fh = io.open(T_DIR .. '/images/ICC_Profile.icc', 'rb')
    local buff = fh:read(1000)
    fh:close()
    local writeInfoList = {
        { 'ICC_Profile', { ref = 'SCALAR', value = buff }, { Protected = 1 } },
    }
    ok(TestLib.writeCheck(writeInfoList, testname, 58), 'test 58 matches (real Writer_58.out golden)')
end

-- Writer.t test 60: Test SetAlternateFile() feature with SetNewValuesFromFile()
do
    local exifTool = lexiftool.new()
    exifTool:SetAlternateFile('File1', T_DIR .. '/images/Nikon.jpg')
    exifTool:SetAlternateFile('File2', T_DIR .. '/images/FujiFilm.jpg')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/Canon.jpg',
        'subject<file1:make', '+subject<make', '+subject<$file2:make',
        'contributor<file1:make', 'contributor<make', 'contributor<$file2:make',
        '+xmp-dc:type<file1:me*')
    local testfile = TEST_DIR .. '/' .. testname .. '_60_failed.jpg'
    os.remove(testfile)
    writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, 'subject', 'contributor', 'type')
    local success = check(exifTool, info, testname, 60)
    ok(success, 'test 60 matches (real Writer_60.out golden)')
    if success then os.remove(testfile) end
end

-- Writer.t test 61: Test the %f and %z date/time format codes for writing
do
    local testnum = 61
    if perl.evalRequire('POSIX::strptime') or perl.evalRequire('Time::Piece') then
        local exifTool = lexiftool.new()
        exifTool:Options('DateFormat', '%H:%M:%S%f%:z %m-%d-%Y')
        exifTool:SetNewValue('XMP:CreateDate', '09:11:12.345-07:00 01-02-2024')
        local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.xmp'
        os.remove(testfile)
        local success = writeInfo(exifTool, nil, testfile)
        if success then
            exifTool:Options('DateFormat', nil)
            local info = exifTool:ImageInfo(testfile, '-system:all')
            success = check(exifTool, info, testname, testnum)
        end
        if success then os.remove(testfile) end
        ok(success, 'test 61 matches (real Writer_61.out golden)')
    else
        ok(false, 'test 61: POSIX::strptime or Time::Piece not installed')
    end
end

-- own: a Photoshop APP13 split over two segments shifts the AFCP trailer by
-- 18 bytes; writing must rescan for it (AFCP.pm ScanForTrailer, "Adjusted
-- AFCP offsets by 18") and ProcessTrailers must stop on a zero DirLen
-- (ExifTool.pm `$dirLen or ...`, `$dataPos and $dirLen`) -- this used to loop
do
    local fh = io.open(T_DIR .. '/images/ExifTool.jpg', 'rb')
    local data = fh:read('a')
    fh:close()
    -- rebuild the file with its APP13 Photoshop record split in two halves
    local hdr = 'Photoshop 3.0\0'
    local split
    local pos = 3   -- (1-based, after SOI)
    while data:byte(pos) == 0xff and data:byte(pos + 1) ~= 0xda do
        local len = data:byte(pos + 2) * 256 + data:byte(pos + 3)
        if data:byte(pos + 1) == 0xed and data:sub(pos + 4, pos + 17) == hdr then
            local ps = data:sub(pos + 18, pos + 1 + len)
            local half = #ps // 2
            local function seg(part)
                return '\255\237' .. string.pack('>I2', 2 + #hdr + #part) .. hdr .. part
            end
            split = data:sub(1, pos - 1) .. seg(ps:sub(1, half)) .. seg(ps:sub(half + 1)) ..
                    data:sub(pos + 2 + len)
            break
        end
        pos = pos + 2 + len
    end
    local function hasValue(info, name, pat)
        for tag, val in pairs(info) do
            if tag:match('^' .. name) and tostring(val):find(pat, 1, true) then return true end
        end
        return false
    end
    local exifTool = lexiftool.new()
    local inInfo = split and exifTool:ImageInfo({ ref = 'SCALAR', value = split }, 'Warning')
    exifTool:SetNewValue('Artist', 'x')
    local out = { ref = 'SCALAR' }
    local rtn = split and exifTool:WriteInfo({ ref = 'SCALAR', value = split }, out)
    local info = rtn == 1 and exifTool:ImageInfo(out, 'Artist', 'Caption-Abstract', 'Warning')
    ok(split and hasValue(inInfo, 'Warning', 'Adjusted AFCP offsets by 18') and info and info.Artist == 'x' and
       hasValue(info, 'Caption%-Abstract', 'ExifTool AFCP test') and not hasValue(info, 'Warning', 'Adjusted AFCP'),
       'own: split APP13 + shifted AFCP trailer rewritten (no endless trailer loop)')
end

done() -- end
