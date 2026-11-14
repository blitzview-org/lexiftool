--------------------------------------------------------------------------------
-- File:         test/test_iptc.lua
-- Ported from:  t/IPTC.t
--
-- Description:  Lua port of the upstream IPTC.t (the Perl original). The
--               structure mirrors the original block for block: same
--               comments, same test numbers and same call shapes. Standard
--               output data comes exclusively from the vendored upstream tree
--               via TestLib.T_DIR (the equivalent of the original `t` directory).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local writeInfo = TestLib.writeInfo
local writeCheck = TestLib.writeCheck
local done = TestLib.done
local perl = require('lexiftool.perl')

local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'IPTC'
local testnum = 1

-- test 2: Extract information from IPTC.jpg
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/IPTC.jpg', { Duplicates = 1 })
    ok(check(exifTool, info, testname, testnum),
       'test ' .. testnum .. ' matches')
end

-- test 3: Test GetValue() in list context
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:ExtractInfo(T_DIR .. '/images/IPTC.jpg', { JoinLists = 0 })
    -- (Lua has no wantarray: a list value comes back as a table)
    local values = exifTool:GetValue('Keywords', 'ValueConv')
    if type(values) ~= 'table' then values = { values } end
    values = table.concat(values, '-')
    local expected = 'ExifTool-Test-IPTC'
    if values ~= expected then
        io.stderr:write('\n  Test ' .. testnum .. ' differs with "' .. tostring(values) .. '"\n')
    end
    ok(values == expected, 'test ' .. testnum .. ' matches')
end

-- test 4: Test rewriting everything with slightly different values
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1, 'Binary', 1, 'ListJoin', nil)
    local info = exifTool:ImageInfo(T_DIR .. '/images/IPTC.jpg')
    for tag, val in pairs(info) do
        local group = exifTool:GetGroup(tag, 0)  -- (scalar context: family 0)
        if type(val) == 'table' and val.ref == nil then
            val[#val + 1] = 'v2'
        elseif type(val) == 'table' and val.ref == 'SCALAR' then
            val = 'v2'
        elseif perl.isMatch(val, [[^\d+(\.\d*)?$]]) then
            -- (add extra .001 to avoid problem with aperture of 4.85
            --  getting rounded to 4.8 or 4.9 and causing failed tests)
            local frac = perl.matches(val, [[^\d+(\.\d*)?$]])
            val = perl.num(val)
            val = val + (val / 10) + 1.001
            if not perl.truthy(frac) then val = perl.int(val) end
        else
            val = val .. '-v2'
        end
        -- eat return values so warnings don't get printed
        exifTool:SetNewValue(tag, val, { Group = group, Replace = 1 })
    end
    -- also try writing a few specific tags
    exifTool:SetNewValue('CreatorCountry', 'Canada')
    exifTool:SetNewValue('CodedCharacterSet', 'UTF8', { Protected = 1 })
    info = nil -- luacheck: ignore 311 (upstream `undef $info`)
    local image = { ref = 'SCALAR' }
    local wrote = writeInfo(exifTool, T_DIR .. '/images/IPTC.jpg', image, nil, true)
    -- this is effectively what the RHEL 3 UTF8 LANG problem does:
    -- $image = pack("U*", unpack("C*", $image));

    local exifTool2 = lexiftool.new()
    exifTool2:Options('Duplicates', 1)
    info = exifTool2:ImageInfo(image)
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    if check(exifTool2, info, testname, testnum) and wrote then
        os.remove(testfile)
        ok(true, 'test ' .. testnum .. ' matches')
    else
        -- save bad file
        local fh = io.open(testfile, 'wb')
        if fh and image.value then fh:write(image.value:tostring()) fh:close() end
        ok(false, 'test ' .. testnum .. ' matches')
    end
end

-- test 5: Test IPTC special characters
do
    testnum = testnum + 1
    local writeInfoList = {
        -- (don't put special character hex codes in string in an attempt to patch failed
        -- test by dcollins on Perl 5.95 and i686-linux-thread-multi 2.6.28-11-generic)
        -- ['IPTC:CopyrightNotice' => chr(0xc2) . chr(0xa9) . " 2008 Phil Harvey"],
        -- - didn't fix it, so change it back again:
        -- (dcollins is the only tester with this problem)
        { 'IPTC:CopyrightNotice', "\xc2\xa9 2008 Phil Harvey" },
    }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/Writer.jpg', 1),
       'test ' .. testnum .. ' matches')
end

-- test 6: Write and read using different default IPTC encoding
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:Options('Charset', 'Cyrillic')
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/MIE.mie', 'Comment-ru_RU>Caption-Abstract')
    exifTool:Options('IPTCCharset', 'Cyrillic')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    exifTool:Options('Charset', 'UTF8')
    local info = exifTool:ImageInfo(testfile, 'IPTC:*')
    local success = check(exifTool, info, testname, testnum) and wrote
    if success then os.remove(testfile) end
    ok(success, 'test ' .. testnum .. ' matches')
end

-- test 7: Replace an entry in a list
do
    testnum = testnum + 1
    local writeInfoList = {
        { 'IPTC:Keywords', 'Test', { DelValue = 1 } },
        { 'IPTC:Keywords', 'One' },
        { 'IPTC:Keywords', 'Two' },
    }
    ok(writeCheck(writeInfoList, testname, testnum, T_DIR .. '/images/IPTC.jpg', 1),
       'test ' .. testnum .. ' matches')
end

-- test 8: Write IPTC as a block
do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.jpg'
    os.remove(testfile)
    exifTool:SetNewValuesFromFile(T_DIR .. '/images/IPTC.jpg', 'IPTC')
    local wrote = writeInfo(exifTool, T_DIR .. '/images/Writer.jpg', testfile)
    local info = exifTool:ImageInfo(testfile, 'IPTC:*')
    local success = check(exifTool, info, testname, testnum) and wrote
    if success then os.remove(testfile) end
    ok(success, 'test ' .. testnum .. ' matches')
end

-- Port-only tests (not in IPTC.t): HandleCodedCharset/TranslateCodedString
-- (IPTC.pm:994/1016).  Every expected value was produced by calling the
-- upstream subs with perl 5.42 on the same inputs, e.g.
--   perl -w -Ivendor/exiftool/lib -MImage::ExifTool -MImage::ExifTool::IPTC -e
--   'my $et=Image::ExifTool->new; my ($v,$l)=("Gr\xfc\xdfe","Latin");
--    Image::ExifTool::IPTC::TranslateCodedString($et,\$v,\$l,1);
--    print unpack("H*",$v)," $l\n"'
do
    local IPTC = require('lexiftool.IPTC')
    local is = TestLib.is
    local exifTool = lexiftool.new()
    -- (Warn is caught on this instance only, so no global state changes;
    --  a fresh object has no WAS_WARNED to count warnings in)
    local warned = {}
    exifTool.Warn = function(_self, msg) warned[#warned + 1] = msg end

    -- HandleCodedCharset: perl gives undef, bad, Latin, Latin, Cyrillic, undef
    is(nil,        IPTC.HandleCodedCharset(exifTool, '\x1b%G'), 'CodedCharset UTF8 needs no translation')
    is('bad',      IPTC.HandleCodedCharset(exifTool, '\x1b%X'), 'CodedCharset unknown ESC % set')
    is('Latin',    IPTC.HandleCodedCharset(exifTool, '\x1b-A'), 'CodedCharset designated only: CharsetIPTC')
    is('Latin',    IPTC.HandleCodedCharset(exifTool, ''),       'CodedCharset empty: CharsetIPTC')
    exifTool:Options('CharsetIPTC', 'Cyrillic')
    is('Cyrillic', IPTC.HandleCodedCharset(exifTool, ''),       'CodedCharset follows CharsetIPTC')
    exifTool:Options('Charset', 'Cyrillic')
    is(nil,        IPTC.HandleCodedCharset(exifTool, ''),       'CodedCharset same as Charset')
    exifTool:Options('Charset', 'UTF8')

    -- TranslateCodedString (value as hex, then the returned charset)
    local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
    local function translate(val, xlat, read)
        local v, x = IPTC.TranslateCodedString(exifTool, val, xlat, read)
        return hex(v) .. ' ' .. tostring(x)
    end
    is('4772c3bcc39f65 Latin',  translate('Gr\xfc\xdfe', 'Latin', 1),    'read Latin')
    is('d09fd180d0b8 Cyrillic', translate('\xcf\xf0\xe8', 'Cyrillic', 1), 'read Cyrillic')
    is('4772fc1b2d41 Latin',    translate('Gr\xfc\x1b-A', 'Latin', 1),   'read ISO 2022 shift: untouched')
    is('4772fc nil',            translate('Gr\xfc', 'bad', 1),           'read bad charset: untouched, xlat cleared')
    is('4772fcdf65 Latin',      translate('Gr\xc3\xbc\xc3\x9fe', 'Latin', 0), 'write Latin')
    is('Some IPTC characters not converted (ISO 2022 shifting not supported)|' ..
       'Some IPTC characters not converted (unsupported CodedCharacterSet)',
       table.concat(warned, '|'), 'TranslateCodedString warnings')
end

-- the whole IPTC/EXIF block as the IPTC/EXIF tag, extracted only when
-- requested (IPTC.pm:1117-1125, ExifTool.pm:3147-3154); sizes from Perl
do
    local et = lexiftool.new()
    local info = et:ImageInfo(T_DIR .. '/images/IPTC.jpg', 'IPTC')
    local iptc = info.IPTC
    TestLib.is(359, type(iptc) == 'table' and #iptc.value or -1, 'IPTC block extracted when requested')
    TestLib.is('\x1c', type(iptc) == 'table' and iptc.value:sub(1, 1) or '', 'IPTC block starts with 0x1c')
    info = et:ImageInfo(T_DIR .. '/images/IPTC.jpg')
    TestLib.is(nil, info.IPTC, 'IPTC block not extracted unless requested')
    info = et:ImageInfo(T_DIR .. '/images/ExifTool.jpg', 'EXIF')
    local exif = info.EXIF
    -- (840 bytes: the APP1 block, not the nested one ProcessTIFF restores from)
    TestLib.is(840, type(exif) == 'table' and #exif.value or -1, 'EXIF block extracted when requested')
end

done() -- end
