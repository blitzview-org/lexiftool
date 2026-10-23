--------------------------------------------------------------------------------
-- File:         test/test_exif_robust.lua
--
-- Description:  Regression cases for EXIF (and ICC) parsing of malformed or
--               unusual camera files, found by comparing against Perl
--               ExifTool over camera sample images and rebuilt here as
--               small synthetic files (the sample images themselves carry
--               no license and stay out of the repo).
--
-- Notes:        Every expected value below is what Perl Image::ExifTool 13.59
--               returns for the same bytes (ImageInfo with Unknown => 1);
--               none is hand-written. Cases 1-4 used to end in a Lua error,
--               cases 5-6 gave values that differed from Perl,
--               case 7 wrote maker-note offsets 8 bytes too low.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local perl = require('lexiftool.perl')
local ok, is = TestLib.ok, TestLib.is
local done = TestLib.done

-- one big-endian IFD entry: tag, format, count and the 4-byte value field
local function ent(tag, fmt, count, val)
    return string.pack('>I2I2I4', tag, fmt, count) .. val
end

-- read a buffer like a file and return the info hash plus all warnings
local function readInfo(data, ...)
    local et = lexiftool.new()
    et:Options('Unknown', 1)
    local info = et:ImageInfo({ ref = 'SCALAR', value = data }, ...)
    local warnings = {}
    for tag, val in pairs(info) do
        if tag:match('^Warning') then warnings[#warnings + 1] = tostring(val) end
    end
    perl.tsort(warnings)
    return info, table.concat(warnings, '|'), et
end

-- 1) IFD0 -> ExifIFD with rationals of 0/0, single-byte undef values, a
--    zero-format padding entry, an Artist with trailing blanks, and a
--    next-IFD pointer far beyond the end of the file
do
    local t = 'MM\0\42' .. string.pack('>I4', 8)
    t = t .. string.pack('>I2', 2)
          .. ent(0x013b, 2, 6, string.pack('>I4', 38))
          .. ent(0x8769, 4, 1, string.pack('>I4', 44))
          .. string.pack('>I4', 0x00100000)
    t = t .. 'Me   \0'
    t = t .. string.pack('>I2', 5)
          .. ent(0x9201, 10, 1, string.pack('>I4', 110))
          .. ent(0x9202, 5, 1, string.pack('>I4', 118))
          .. ent(0x9286, 7, 1, '\0\0\0\0')
          .. ent(0xa000, 7, 1, '\0\0\0\0')
          .. ent(0x0000, 0, 0, '\0\0\0\0')
          .. string.pack('>I4', 0)
    t = t .. string.pack('>i4i4', 0, 0) .. string.pack('>I4I4', 0, 0)
    local info, warnings = readInfo(t)
    is('Me', info.Artist, 'Artist trailing blanks trimmed (RawConv)')
    is('0', tostring(info.ShutterSpeedValue), 'ShutterSpeedValue of undef (0/0) is 0 (IsFloat)')
    is('1.0', info.ApertureValue, 'ApertureValue of undef (0/0) numifies to 2**0')
    is('\0', info.UserComment, 'single undef byte read as undef, not int8u, under a Format override')
    is('0', tostring(info.FlashpixVersion), 'FlashpixVersion of one null byte')
    is('Bad IFD1 directory', warnings, 'unreadable IFD1 warns once, no "Bad format (0)" for padding')
end

-- 2) GE type 2 maker notes: the missing entry count is written into the
--    caller's buffer (Set16u on $$dataPt)
local function ge2(header)
    local mn = header .. '\0\0'
    for i = 0, 24 do mn = mn .. string.pack('<I2I2I4I2I2', 0x1001 + i, 3, 1, i, 0) end
    mn = mn .. '\0\0\0\0'
    local t = 'MM\0\42' .. string.pack('>I4', 8)
    t = t .. string.pack('>I2', 1) .. ent(0x8769, 4, 1, string.pack('>I4', 26)) .. string.pack('>I4', 0)
    t = t .. string.pack('>I2', 1) .. ent(0x927c, 7, #mn, string.pack('>I4', 44)) .. string.pack('>I4', 0)
    return t .. mn
end
do
    local info, warnings = readInfo(ge2('GE\x0c\0\0\0\x16\0\0\0\0\0'))
    is('-4 (softest)', info.Sharpness, 'GE2 maker notes: first entry decoded')
    is('24', tostring(info['FujiFilm_0x1019']), 'GE2 maker notes: all 25 entries read')
    is('', warnings, 'GE2 maker notes: no warning')
    -- shifted by two bytes, every entry points outside the file: minor
    -- warnings until the parse is aborted
    local _, warnings2 = readInfo(ge2('GE\x0c\0\0\0\x16\0\0\0'), 'Warning')
    ok(warnings2:find('[minor] Error reading value for MakerNotes entry 11, ID 0x0003', 1, true) and
       warnings2:find('[Minor] Too many warnings -- MakerNotes parsing aborted', 1, true),
       'GE2 maker notes, bad offsets: minor read errors, then parsing aborted')
end

-- 3) ExtractBinary returns the plain "Binary data N bytes" string (not a
--    reference), and binary PLIST conversion of a non-PLIST number is undef
do
    local et = lexiftool.new()
    et.RAF = require('lexiftool.RandomAccess').new(string.rep('x', 100))
    is('Binary data 10 bytes', et:ExtractBinary(0, 10, 'PreviewImage'), 'ExtractBinary stand-in is a string')
    is(nil, require('lexiftool.Apple').ConvertPLIST(0, et), 'ConvertPLIST of the number 0 is undef')
end

-- 4) an ICC profile whose ProfileDescription is a multiLocalizedUnicodeType
--    ('mluc', as in every recent Apple JPEG): one tag per language
do
    local function u16(str) return (str:gsub('.', function(c) return '\0' .. c end)) end
    local en, de = u16('Display P3'), u16('Anzeige')
    local mluc = 'mluc\0\0\0\0' .. string.pack('>I4I4', 2, 12)
    mluc = mluc .. 'enUS' .. string.pack('>I4I4', #en, 40) .. 'deDE' .. string.pack('>I4I4', #de, 40 + #en) .. en .. de
    local body = string.pack('>I4', 1) .. 'desc' .. string.pack('>I4I4', 144, #mluc) .. mluc
    local hdr = string.pack('>I4', 128 + #body) .. 'appl' .. string.pack('>I4', 0x04300000) .. 'mntrRGB XYZ '
        .. string.rep('\0', 12) .. 'acspAPPL' .. string.rep('\0', 4 + 4 + 4 + 8 + 4)
        .. string.pack('>i4i4i4', 63190, 65536, 54061) .. 'appl' .. string.rep('\0', 16 + 28)
    local info = readInfo(hdr .. body)
    is('Display P3', info.ProfileDescription, 'ICC mluc: default (en-US) string')
    is('Anzeige', info['ProfileDescription-de-DE'], 'ICC mluc: de-DE string as language variant')
end

-- 5) Fixup markers on 16-bit pointers (Ricoh's int16u PreviewImageStart):
--    SetMarkerPointers/GetMarkerPointers must also find the "MM2_" entries
do
    local Fixup = require('lexiftool.Fixup')
    local carray = require('carray')
    local order = lexiftool.GetByteOrder()
    lexiftool.SetByteOrder('MM')
    local f = Fixup.new()
    f:AddFixup(2, 'PreviewImage', 'int16u')
    f:AddFixup(4, 'PreviewImage')
    local buf = carray.new('char'):append(string.rep('\0', 8))
    f:SetMarkerPointers(buf, 'PreviewImage', 0x1234)
    is('\0\0\x12\x34\0\0\x12\x34', buf:tostring(), 'Fixup: 16- and 32-bit marker pointers set')
    local ptrs = f:GetMarkerPointers(buf, 'PreviewImage')
    is('4660,4660', table.concat(ptrs, ','), 'Fixup: 16- and 32-bit marker pointers read back')
    lexiftool.SetByteOrder(order)
end

-- 6) Composite Aperture gates on the *raw* FNumber/ApertureValue (RawConv):
--    FNumber 0/1 and ApertureValue 0/1 build no Aperture, although the
--    converted ApertureValue is 1.0
do
    local t = 'MM\0\42' .. string.pack('>I4', 8)
    t = t .. string.pack('>I2', 1) .. ent(0x8769, 4, 1, string.pack('>I4', 26)) .. string.pack('>I4', 0)
    t = t .. string.pack('>I2', 2)
          .. ent(0x829d, 5, 1, string.pack('>I4', 56))
          .. ent(0x9202, 5, 1, string.pack('>I4', 64))
          .. string.pack('>I4', 0)
    t = t .. string.pack('>I4I4', 0, 1) .. string.pack('>I4I4', 0, 1)
    local info = readInfo(t)
    is('1.0', info.ApertureValue, 'ApertureValue of 0/1 is 2**0')
    is(nil, info.Aperture, 'no Composite Aperture from raw zeros')
end

-- 7) Leica2 maker notes (M8 JPEG layout): value offsets count from the
--    "LEICA\0\0\0" header, 8 bytes before the IFD, so FixLeicaBase must
--    shift the base when LocateIFD re-finds the IFD on writing. Expected
--    bytes are Perl's `-Artist=x` output for the same file.
do
    local mn = 'LEICA\0\0\0' .. string.pack('>I2', 2)
          .. ent(0x0322, 5, 1, string.pack('>I4', 38))
          .. ent(0x0323, 5, 1, string.pack('>I4', 46))
          .. string.pack('>I4', 0)
          .. string.pack('>I4I4', 1000, 1024) .. string.pack('>I4I4', 2000, 1999)
    local t = 'MM\0\42' .. string.pack('>I4', 8)
    t = t .. string.pack('>I2', 2)
          .. ent(0x010f, 2, 16, string.pack('>I4', 38))
          .. ent(0x8769, 4, 1, string.pack('>I4', 54))
          .. string.pack('>I4', 0)
    t = t .. 'Leica Camera AG\0'
    t = t .. string.pack('>I2', 1) .. ent(0x927c, 7, #mn, string.pack('>I4', 72)) .. string.pack('>I4', 0)
    t = t .. mn
    local info = readInfo(t)
    is('1.00050025', tostring(info.WBGreenLevel), 'Leica2: WBGreenLevel read with the shifted base')
    local et = lexiftool.new()
    et:SetNewValue('Artist', 'x')
    local out = { ref = 'SCALAR' }
    is(1, et:WriteInfo({ ref = 'SCALAR', value = t }, out), 'Leica2: Artist written')
    local perlOut = ('4d4d002a000000080003010f00020000001000000032013b00020000000278000000876900040000000100000042' ..
        '000000004c656963612043616d657261204147000001927c00070000003600000054000000004c4549434100000000020322' ..
        '0005000000010000002603230005000000010000002e00000000000003e800000400000007d0000007cf'):gsub('%x%x',
        function(h) return string.char(tonumber(h, 16)) end)
    local got = out.value
    if type(got) ~= 'string' then got = got and got:tostring() end
    ok(got == perlOut, 'Leica2: written file identical to Perl (value offsets kept)')
end

done()
