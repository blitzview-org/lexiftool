--------------------------------------------------------------------------------
-- File:         test/test_getvalue_api.lua
--
-- Description:  GetValue as a library call: a tag key, a tag name in another
--               case, a group name in front of it (Perl's GroupMatches over
--               the duplicates), a missing tag, the value types PrintConv,
--               ValueConv, Raw, Both, Rational and Bin, a Composite tag (its
--               raw value is the hash of tag keys), a list-type tag, a binary
--               value, the list context (the 4th argument; Perl's wantarray)
--               and the options PrintConv, ListItem, List and ListSep. The
--               expected lines are what the same calls print with
--               Image::ExifTool; Perl's scalar context of a 'Both' call is the
--               last of its two values, here the second.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local is = TestLib.is
local done = TestLib.done

local T = TestLib.T_DIR .. '/images'

-- a value as the Perl side prints it: undef, 'string', ARRAY(...),
-- SCALAR(length) and HASH(key=value,...) with sorted keys
local function show(v)
    if v == nil then return 'undef' end
    local r = perl.ref(v)
    if r == 'ARRAY' then
        local t = {}
        for i = 1, #v do t[i] = show(v[i]) end
        return 'ARRAY(' .. table.concat(t, ',') .. ')'
    elseif r == 'SCALAR' then
        return 'SCALAR(' .. perl.length(v.value) .. ')'
    elseif r == 'HASH' then
        local t = {}
        for _, k in ipairs(perl.sort(perl.keys(v))) do t[#t + 1] = perl.str(k) .. '=' .. show(v[k]) end
        return 'HASH(' .. table.concat(t, ',') .. ')'
    end
    return "'" .. perl.str(v) .. "'"
end

-- the returned list, undef elements included
local function list(...)
    local t = {}
    for i = 1, select('#', ...) do t[i] = show((select(i, ...))) end
    return '(' .. table.concat(t, ',') .. ')'
end

local et = lexiftool.new()
et:Options('Duplicates', 1)
et:ExtractInfo(T .. '/ExifTool.jpg')

-- { tag, type, expected line }
local cases = {
    { 'Make', nil, [[scalar 'Canon' list ('Canon')]] },
    { 'make', nil, [[scalar 'Canon' list ('Canon')]] },
    { 'MAKE', 'Raw', [[scalar 'Canon' list ('Canon')]] },
    { 'Make (1)', nil, [[scalar 'FUJIFILM' list ('FUJIFILM')]] },
    { 'IFD0:Make', nil, [[scalar 'FUJIFILM' list ('FUJIFILM')]] },
    { 'CIFF:Make', nil, [[scalar 'Canon' list ('Canon')]] },
    { 'EXIF:make', nil, [[scalar 'FUJIFILM' list ('FUJIFILM')]] },
    { 'XMP:Make', nil, [[scalar undef list ()]] },
    { 'NoSuchTag', nil, [[scalar undef list ()]] },
    { 'ciff:nosuchtag', nil, [[scalar undef list ()]] },
    { 'Flash', nil, [[scalar 'Fired' list ('Fired')]] },
    { 'Flash', 'ValueConv', [[scalar '1' list ('1')]] },
    { 'Flash', 'Raw', [[scalar '1' list ('1')]] },
    { 'Flash', 'PrintConv', [[scalar 'Fired' list ('Fired')]] },
    { 'ApertureValue', 'ValueConv', [[scalar '6.16884330163176' list ('6.16884330163176')]] },
    { 'ApertureValue', 'Both', [[scalar '6.2' list ('6.16884330163176','6.2')]] },
    { 'ExifIFD:ApertureValue', 'Both', [[scalar '3.5' list ('3.4822022531845','3.5')]] },
    { 'Aperture', nil, [[scalar '3.5' list ('3.5')]] },
    { 'Aperture', 'ValueConv', [[scalar '3.5' list ('3.5')]] },
    { 'Aperture', 'Both', [[scalar '3.5' list ('3.5','3.5')]] },
    { 'Aperture', 'Raw', [[scalar HASH(0='FNumber',1='ApertureValue') list (HASH(0='FNumber',1='ApertureValue'))]] },
    { 'ImageSize', nil, [[scalar '8x8' list ('8x8')]] },
    { 'Composite:ImageSize', 'Both', [[scalar '8x8' list ('8 8','8x8')]] },
    { 'ImageSize (1)', 'ValueConv', [[scalar '1280-960' list ('1280-960')]] },
    { 'Subject', nil, [[scalar 'ExifTool, Test, XMP' list ('ExifTool','Test','XMP')]] },
    { 'Subject', 'ValueConv', [[scalar ARRAY('ExifTool','Test','XMP') list ('ExifTool','Test','XMP')]] },
    { 'Subject', 'Raw', [[scalar ARRAY('ExifTool','Test','XMP') list ('ExifTool','Test','XMP')]] },
    { 'Subject', 'Both', [[scalar ARRAY('ExifTool','Test','XMP') list (ARRAY('ExifTool','Test','XMP'),ARRAY('ExifTool','Test','XMP'))]] },
    { 'XMP-dc:Subject', nil, [[scalar 'ExifTool, Test, XMP' list ('ExifTool','Test','XMP')]] },
    { 'Keywords', nil, [[scalar 'jambalaya' list ('jambalaya')]] },
    { 'Keywords', 'ValueConv', [[scalar 'jambalaya' list ('jambalaya')]] },
    { 'ThumbnailImage', nil, [[scalar SCALAR(1558) list (SCALAR(1558))]] },
    { 'ThumbnailImage', 'ValueConv', [[scalar SCALAR(1558) list (SCALAR(1558))]] },
    { 'ThumbnailImage', 'Raw', [[scalar SCALAR(1558) list (SCALAR(1558))]] },
    { 'ThumbnailImage', 'Both', [[scalar SCALAR(1558) list (SCALAR(1558),SCALAR(1558))]] },
    { 'ExposureTime', 'Rational', [[scalar undef list (undef)]] },
    { 'ExposureTime', 'Bin', [[scalar undef list (undef)]] },
    { 'FileType', 'Both', [[scalar 'JPEG' list ('JPEG','JPEG')]] },
    { 'MPImageType', 'Both', [[scalar 'Large Thumbnail (full HD equivalent)' list ('65538','Large Thumbnail (full HD equivalent)')]] },
}
for _, c in ipairs(cases) do
    local s = et:GetValue(c[1], c[2])
    if c[2] == 'Both' then s = select(2, et:GetValue(c[1], c[2])) end
    is(c[3], 'scalar ' .. show(s) .. ' list ' .. list(et:GetValue(c[1], c[2], nil, true)),
        'GetValue ' .. c[1] .. ' ' .. (c[2] or ''))
end

-- options
et:Options('PrintConv', 0)
is([['1']], show(et:GetValue('Flash')), 'PrintConv 0')
is([[ARRAY('ExifTool','Test','XMP')]], show(et:GetValue('Subject')), 'PrintConv 0, list-type tag')
et:Options('PrintConv', 1)
et:Options('ListItem', 1)
is([['Test' list ('Test')]], show(et:GetValue('Subject')) .. ' list ' .. list(et:GetValue('Subject', nil, nil, true)),
    'ListItem 1')
et:Options('ListItem', -1)
is([['XMP']], show(et:GetValue('Subject', 'ValueConv')), 'ListItem -1')
et:Options('ListItem', nil)
et:Options('List', 1)
is([[ARRAY('ExifTool','Test','XMP')]], show(et:GetValue('Subject')), 'List 1')
et:Options('List', 0)
et:Options('ListSep', ' | ')
is([['ExifTool | Test | XMP']], show(et:GetValue('Subject')), 'ListSep')

done()
