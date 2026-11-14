--------------------------------------------------------------------------------
-- File:         test/test_geolocation_port.lua
--
-- Description:  Geolocation cases the upstream Geolocation.t does not cover,
--               found by comparing against the Perl original (the expected
--               values below are what `perl -I vendor/exiftool/lib` returns
--               for the same library calls):
--                 1. option names are case-insensitive (Options fixes the
--                    case against the known option names, including those
--                    whose default is undef, and maps groupN to GroupN), so
--                    `-api geolocation=1` really enables Geolocation
--                 2. empty GPS coordinates (InfiRay.jpg) and list-type city
--                    tags (XMP7.xmp) end in the Geolocate warning, now a
--                    Warning tag, instead of a Lua error
--                 3. the Geolocate write tag turns Geolocate's warnings into
--                    the SetNewValue error message, and Warn's 0 return under
--                    IgnoreMinorErrors is false (Perl), so an ambiguous city
--                    is written with the first match
--                 4. an ambiguous Geolocation option warns once per file
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local is, ok = TestLib.is, TestLib.ok
local T_DIR = TestLib.T_DIR

-- 1. case-insensitive option names
do
    local et = lexiftool.new()
    et:Options('geolocation', 1)
    is(1, et:Options('Geolocation'), 'geolocation sets Geolocation')
    local info = et:ImageInfo(T_DIR .. '/images/GPS.jpg', 'GeolocationCity', 'GeolocationPosition')
    is('Prudhoe', info.GeolocationCity, 'GPS.jpg GeolocationCity')
    is('54.9615, -1.8515', info.GeolocationPosition, 'GPS.jpg GeolocationPosition')

    et = lexiftool.new()
    et:Options('group0', 'EXIF')
    is('EXIF', et:Options('Group0'), 'group0 sets Group0')
end

-- 2. insufficient or unusable location tags
do
    local et = lexiftool.new()
    et:Options('Geolocation', 1)
    local info = et:ImageInfo(T_DIR .. '/images/InfiRay.jpg', 'Geolocation*', 'Warning')
    is('Insufficient information to determine geolocation', info.Warning, 'InfiRay.jpg empty GPS')
    is(nil, info.GeolocationCity, 'InfiRay.jpg no city')
    info = et:ImageInfo(T_DIR .. '/images/XMP7.xmp', 'Geolocation*', 'Warning')
    is('No such city in Geolocation database', info.Warning, 'XMP7.xmp list-type city')
end

-- 3. writing Geolocate
do
    local et = lexiftool.new()
    local n, err = et:SetNewValue('Geolocate', 'Xyzzyq')
    is(0, n, 'unknown city not set')
    is('No such city in Geolocation database in File:Geolocate (ValueConvInv)', err, 'unknown city error')
    n, err = et:SetNewValue('Geolocate', 'Springfield')
    is(0, n, 'ambiguous city not set')
    is('[Minor] Multiple matching cities found in File:Geolocate (ValueConvInv)', err, 'ambiguous city error')
    et:Options('ignoreminorerrors', 1)
    n, err = et:SetNewValue('Geolocate', 'Springfield')
    is(1, n, 'ambiguous city set with IgnoreMinorErrors')
    is(nil, err, 'ambiguous city no error with IgnoreMinorErrors')
    is('37 12 55.0799999999969', et:GetNewValue('GPS:GPSLatitude'), 'first Springfield latitude')
    is('W\0', et:GetNewValue('GPS:GPSLongitudeRef'), 'first Springfield longitude ref')
end

-- 4. ambiguous Geolocation option
do
    local et = lexiftool.new()
    et:Options('Geolocation', 'Springfield')
    local info = et:ImageInfo({ ref = 'SCALAR', value = '' }, 'Geolocation*', 'Warning')
    is('[Minor] Multiple Geolocation cities are possible', info.Warning, 'ambiguous option warning')
    is(nil, info.GeolocationCity, 'ambiguous option no city')
end

ok(true, 'done')
TestLib.done()
