--------------------------------------------------------------------------------
-- File:         test/test_geolocation_geodir.lua
--
-- Description:  Port-only: $Image::ExifTool::Geolocation::geoDir (geoDir)
--               names a real directory with its own Geolocation.dat, read
--               by path exactly as upstream reads it -- neither upstream's
--               own t/Geolocation.t nor test_geolocation_port.lua exercise
--               this at all. Added with the GeolocationData.lua refactor
--               (the bundled default database is now the Lua module
--               lexiftool.GeolocationData, loaded without any file path;
--               geoDir keeps reading a real file, see
--               src/lexiftool/Geolocation.lua's Port notes) to cover the
--               ReadDatabase(path) branch that refactor kept:
--                 1. geoDir names a real file: used instead of the bundled
--                    default (dbInfo names the external path)
--                 2. geoDir names a directory without a Geolocation.dat:
--                    falls back to the bundled default (dbInfo names it)
--                 3. geoDir = '': the database is not loaded at all
--
--               Each case reloads lexiftool.Geolocation fresh (cityList/
--               dbInfo are set once by Geolocation.init() and then
--               cached): geoDir must be set before the first geolocation
--               lookup, as it always is in real use (Options('GeoDir',
--               ...) before the first file).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local lfs = require('lfs')

local is, ok = TestLib.is, TestLib.ok
local T_DIR = TestLib.T_DIR
local TEST_DIR = TestLib.TEST_DIR
local REPO_DIR = TestLib.REPO_DIR

local function freshGeolocation()
    package.loaded['lexiftool.Geolocation'] = nil
    return require('lexiftool.Geolocation')
end

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local data = f:read('a')
    f:close()
    return data
end

local function spit(path, data)
    local f = assert(io.open(path, 'wb'))
    f:write(data)
    f:close()
end

local geoDir = TEST_DIR .. '/lex_geodir'

local function rmGeoDir()
    os.remove(geoDir .. '/Geolocation.dat')
    lfs.rmdir(geoDir)
end

-- 1. geoDir names a real file: used instead of the bundled default
do
    rmGeoDir()
    assert(lfs.mkdir(geoDir))
    spit(geoDir .. '/Geolocation.dat', slurp(REPO_DIR .. '/src/lexiftool/Geolocation.dat'))

    local Geolocation = freshGeolocation()
    Geolocation.geoDir = geoDir
    local et = lexiftool.new()
    et:Options('Geolocation', 1)
    local info = et:ImageInfo(T_DIR .. '/images/GPS.jpg', 'GeolocationCity')
    is('Prudhoe', info.GeolocationCity, 'geoDir file: GeolocationCity')
    is(geoDir .. '/Geolocation.dat v1.03: 116054 cities with population > 2000',
        Geolocation.dbInfo, 'geoDir file: dbInfo names the external path')

    rmGeoDir()
end

-- 2. geoDir names a directory without a Geolocation.dat: falls back to the
--    bundled default
do
    assert(lfs.mkdir(geoDir))

    local Geolocation = freshGeolocation()
    Geolocation.geoDir = geoDir
    local et = lexiftool.new()
    et:Options('Geolocation', 1)
    local info = et:ImageInfo(T_DIR .. '/images/GPS.jpg', 'GeolocationCity')
    is('Prudhoe', info.GeolocationCity, 'geoDir without Geolocation.dat: falls back, GeolocationCity')
    is('<bundled> v1.03: 116054 cities with population > 2000', Geolocation.dbInfo,
        'geoDir without Geolocation.dat: dbInfo names the bundled default')

    rmGeoDir()
end

-- 3. geoDir = '': the database is not loaded at all
do
    local Geolocation = freshGeolocation()
    Geolocation.geoDir = ''
    local et = lexiftool.new()
    et:Options('Geolocation', 1)
    local info = et:ImageInfo(T_DIR .. '/images/GPS.jpg', 'GeolocationCity', 'Warning')
    is(nil, info.GeolocationCity, "geoDir = '': no city")
    is('No Geolocation database', info.Warning, "geoDir = '': warning")
end

ok(true, 'done')
TestLib.done()
