--------------------------------------------------------------------------------
-- File:         lexiftool/Geolocation.lua
-- Ported from:  lib/Image/ExifTool/Geolocation.pm
--
-- Description:  Determine geolocation from GPS and visa-versa
--
-- Revisions:    2024-03-03 - P. Harvey Created
--               2024-03-21 - PH Significant restructuring and addition of
--                            several new features.
--
-- References:   https://download.geonames.org/export/
--
-- Notes:        Set $Image::ExifTool::Geolocation::geoDir to override the
--               default directory containing the database file Geolocation.dat
--               and the GeoLang directory with the alternate language files.
--               If set, this directory is
--
--               AltNames.dat may be loaded from a different directory by
--               specifying $Image::ExifTool::Geolocation::altDir.  This
--               database and has entries in the same order as Geolocation.dat,
--               and each entry is a newline-separated list of alternate names
--               terminated by a null byte.  These alternate names are used
--               only when searching for a city by name (eg. "Big Apple").
--
--               Databases are based on data from geonames.org with a
--               Creative Commons license, reformatted as follows in the
--               Geolocation.dat file:
--
--   Header:
--       "GeolocationV.VV\tNNNN\n"  (V.VV=version, NNNN=num city entries)
--       "# <comment>\n"
--   NNNN City entries:
--     Offset Format   Description
--        0   int16u - latitude high 16 bits (converted to 0-0x100000 range)
--        2   int8u  - latitude low 4 bits, longitude low 4 bits
--        3   int16u - longitude high 16 bits
--        5   int8u  - index of country in country list
--        6   int8u  - 0xf0 = population E exponent (in format "N.Fe+0E"), 0x0f = population N digit
--        7   int16u - 0xf000 = population F digit, 0x0fff = index in region list (admin1)
--        9   int16u - v1.02: 0x7fff = index in subregion (admin2), 0x8000 = high bit of time zone
--        9   int16u - v1.03: index in subregion (admin2)
--       11   int8u  - low byte of time zone index
--       12   int8u  - 0x3f = feature code index (see below), v1.03: 0x80 = high bit of time zone
--       13   string - UTF8 City name, terminated by newline
--   "\0\0\0\0\x01"
--   Country entries:
--       1. 2-character country code
--       2. Country name, terminated by newline
--   "\0\0\0\0\x02"
--   Region entries:
--       1. Region name, terminated by newline
--   "\0\0\0\0\x03"
--   Subregion entries:
--       1. Subregion name, terminated by newline
--   "\0\0\0\0\x04"
--   Time zone entries:
--       1. Time zone name, terminated by newline
--   "\0\0\0\0\x05" (feature codes added in v1.03)
--   Feature codes:
--       1. Feature code, optional space-followed-by-feature-name, then newline
--   "\0\0\0\0\0"
--
-- Feature Codes v1.02: (see http://www.geonames.org/export/codes.html#P for descriptions)
--
--       0. Other    3. PPLA2    6. PPLA5    9. PPLF    12. PPLR   15. PPLX
--       1. PPL      4. PPLA3    7. PPLC    10. PPLG    13. PPLS
--       2. PPLA     5. PPLA4    8. PPLCH   11. PPLL    14. STLMT
--
-- Port notes:   database half of Geolocation.pm: ReadDatabase, ReadAltNames,
--               ClearLastMatches, SortDatabase, AddEntry, GetEntry and
--               GetAltNames and Geolocate, i.e. the whole module.
--
--               The GeoLang translation tables GeoLang/<lang>.pm are Perl
--               modules that only assign a hash; GetEntry reads them as data
--               (lexiftool.GeoLangData, never running Perl: a .pm in any
--               other form warns and gives no translations, like a failed
--               require) or their Lua form GeoLang/<lang>.lua
--               (tools/gen_geolang.lua), which comes first at each location
--               -- a deliberate difference: a user's Lua file overrides the
--               .pm beside it. Locations as upstream's require: geoDir,
--               then package.path in place of @INC (GeoLangTranslate).
--
--               The module-level statement sequence of the original (read the
--               database at load time, then set geoDir/altDir, then add the
--               user-defined entries) sits in Geolocation.init() rather than
--               at chunk level: this port's modules are `require`d from tag
--               tables, so a 3 MB read at load time would hit every file type
--               and not just the ones asking for geolocation. init() is
--               idempotent and called by every entry point below.  The
--               user-defined entries (@Image::ExifTool::UserDefined::
--               Geolocation) are the Geolocation entry of a config file, kept
--               in ExifTool.UserDefinedTables.
--
--               Upstream finds the database next to the .pm file via
--               $INC{'Image/ExifTool/Geolocation.pm'}; the bundled (default,
--               geoDir unset) database is instead a plain Lua module,
--               GeolocationData.lua (tools/gen_geolocation_data.lua, a
--               verbatim-byte copy of Geolocation.dat quoted as a Lua
--               string), loaded the same way every other module is
--               (require), so there is no file path to get wrong on any
--               platform or build (rock, standalone, C API). A caller-set
--               geoDir (Image::ExifTool::Geolocation::directory) still
--               names a real directory and Geolocation.dat is still read
--               from there by path, exactly as upstream does -- that path
--               is the caller's, never derived from this chunk's own
--               location, so it was never exposed to the bug the module
--               form fixes (see ReadDatabase, Geolocation.init). The
--               chunk-name trick survives only for geoDir's *default
--               value* and the sibling AltNames.dat lookup (defaultDir,
--               below), which upstream's %INC equivalent also drives.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local tsort = perl.tsort

-- (upstream's @Image::ExifTool::UserDefined::Geolocation: the config file's
--  Geolocation entry, which lexiftool.lua keeps in ExifTool.UserDefinedTables;
--  the core module is loaded when this one is, so the require only looks it up)
local function UserDefinedGeolocation()
    return require('lexiftool').UserDefinedTables.Geolocation
end
local sprintf = perl.sprintf
local isMatch = perl.isMatch

local Geolocation = {}

-- Perl's warn(), which the caller intercepts with `local $SIG{'__WARN__'}`
-- (perl.SIG.__WARN__): ExifTool.pm does so around its Geolocate call to turn
-- these warnings into a Warning tag, and SetNewValue around the Geolocate
-- tag's ValueConvInv to turn them into a write error.
local warn = perl.warn
local perlStr = perl.str
local perlTruthy = perl.truthy
local lc, uc = perl.lc, perl.uc

local VERSION = '1.10'  -- (this is the module version number, not the database version)

local cityList, countryList, regionList, subregionList, timezoneList
local countryNum, regionNum, subregionNum, timezoneNum -- reverse lookups
local sortOrder, altNames, langLookup, nCity, featureCodes, featureTypes
local lastArgs, lastFound, lastByPop, lastByLat -- luacheck: ignore 231
local dbVer = '1.03'        -- database version number
local sortedBy = 'Latitude'
local pi = 3.1415926536
local earthRadius = 6371    -- earth radius in km
-- hard-coded feature codes for v1.02 database
local featureCodesList = {
    'Other', 'PPL', 'PPLA', 'PPLA2', 'PPLA3', 'PPLA4', 'PPLA5', 'PPLC',
    'PPLCH', 'PPLF', 'PPLG', 'PPLL', 'PPLR', 'PPLS', 'STLMT', 'PPLX',
}

-- (port: geoDir's default value and the AltNames.dat sibling-file lookup
--  only -- the bundled Geolocation.dat itself no longer goes through this,
--  see Geolocation.init below. require() builds a module's chunk name by
--  substituting package.config's own directory separator for the dots in
--  the module name into a template that is otherwise written with forward
--  slashes (the Makefile's LUA_PATH); on Windows that separator is '\',
--  so the match must accept either one, not just '/')
local defaultDir = debug.getinfo(1, 'S').source:match('^@(.*)[/\\]Geolocation%.lua$')
if not defaultDir then
    defaultDir = '.'
    warn('Error getting Geolocation.lua directory\n')
end

Geolocation.VERSION = VERSION
Geolocation.geoDir = nil
Geolocation.altDir = nil
Geolocation.dbInfo = nil

--------------------------------------------------------------------------------
-- Read Geolocation database
-- Inputs: 0) database file name, or (with isData true) the database's raw
--            bytes directly -- the bundled default, loaded from the Lua
--            module GeolocationData.lua by Geolocation.init(), never from a
--            file; a caller-set geoDir still names a real file (see the
--            module banner's Port notes)
--         1) isData: true if the first argument is raw bytes, not a path
-- Returns: true on success
function Geolocation.ReadDatabase(datfile, isData)
    -- open geolocation database and verify header (isData: nothing to
    -- open, the bytes are already in memory -- readLine/closeFile below
    -- read a line at a time from them exactly as DATFILE:read('L') would)
    local DATFILE, data, pos
    if isData then
        data, pos = datfile, 1
    else
        DATFILE = io.open(datfile, 'rb')
        if not DATFILE then
            warn('Error reading ' .. datfile .. '\n')
            return 0
        end
    end
    -- (upstream reads the entries with Perl's line-input operator, which
    --  stops at a newline: a city name may contain one, so it reads more
    --  until the record is at least 14 bytes long -- the same loop is here)
    local function readLine()
        if DATFILE then return DATFILE:read('L') end
        if pos > #data then return nil end
        local stop = data:find('\n', pos, true) or #data
        local s = data:sub(pos, stop)
        pos = stop + 1
        return s
    end
    local function closeFile()
        if DATFILE then DATFILE:close() end
    end
    local line = readLine()
    -- (`line and line:match(...)` would truncate the match to one value)
    local v, n
    if line then v, n = line:match('^Geolocation(%d+%.%d+)\t(%d+)') end
    if not v then
        warn('Bad format Geolocation database\n')
        closeFile()
        return 0
    end
    dbVer, nCity = v, tonumber(n)
    if not dbVer:match('^1%.0[23]$') then
        local which = tonumber(dbVer) < 1.03 and 'database' or 'ExifTool'
        warn('Incompatible Geolocation database (update your ' .. which .. ')\n')
        closeFile()
        return 0
    end
    local comment = readLine()
    local pop = comment and comment:match(' (%d+) ')
    if not pop then closeFile() return 0 end
    Geolocation.dbInfo = (isData and '<bundled>' or datfile) .. ' v' .. dbVer .. ': ' .. nCity ..
        ' cities with population > ' .. pop
    local isUserDefined = UserDefinedGeolocation() and #UserDefinedGeolocation() > 0

    altNames = nil      -- reset altNames

    local function isEnd(s)
        return s and #s == 6 and s:find('\0\0\0\0', 1, true) ~= nil
    end
    -- Perl's chomp: remove one trailing newline, if present
    local function chomp(s)
        return (s:gsub('\n$', ''))
    end

    -- read city database
    cityList = {}
    for _ = 1, math.huge do
        line = readLine()
        if isEnd(line) then break end
        if line == nil then break end
        while #line < 14 do
            local more = readLine()
            if more == nil then break end
            line = line .. more
        end
        cityList[#cityList + 1] = chomp(line)
    end
    if #cityList ~= nCity then
        warn('Bad number of entries in Geolocation database\n')
        closeFile()
        return 0
    end
    countryList, regionList, subregionList, timezoneList = {}, {}, {}, {}
    countryNum, regionNum, subregionNum, timezoneNum = {}, {}, {}, {}
    -- read countries
    while true do
        line = readLine()
        if isEnd(line) or line == nil then break end
        countryList[#countryList + 1] = chomp(line)
        if isUserDefined then countryNum[lc(chomp(line):sub(1, 2))] = #countryList - 1 end
    end
    -- read regions
    while true do
        line = readLine()
        if isEnd(line) or line == nil then break end
        regionList[#regionList + 1] = chomp(line)
        if isUserDefined then regionNum[lc(chomp(line))] = #regionList - 1 end
    end
    -- read subregions
    while true do
        line = readLine()
        if isEnd(line) or line == nil then break end
        subregionList[#subregionList + 1] = chomp(line)
        if isUserDefined then subregionNum[lc(chomp(line))] = #subregionList - 1 end
    end
    -- read time zones
    while true do
        line = readLine()
        if isEnd(line) or line == nil then break end
        timezoneList[#timezoneList + 1] = chomp(line)
        if isUserDefined then timezoneNum[lc(chomp(line))] = #timezoneList - 1 end
    end
    -- read feature codes if available
    featureTypes = {}
    if line == '\0\0\0\0\x05\n' then
        featureCodesList = {}
        while true do
            line = readLine()
            if isEnd(line) or line == nil then break end
            line = chomp(line)
            local code, name = line:match('^(.-) (.*)$')
            if code then
                featureTypes[code] = name
                line = code
            end
            featureCodesList[#featureCodesList + 1] = line
        end
    end
    closeFile()
    -- initialize featureCodes lookup
    featureCodes = {}
    for i = 1, #featureCodesList do
        featureCodes[lc(featureCodesList[i])] = i - 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read alternate-names database
-- Returns: True on success
-- Notes: Must be called after ReadDatabase(). Resets $altDir on exit.
function Geolocation.ReadAltNames()
    local success
    if Geolocation.altDir and nCity then
        local ALTFILE = io.open(Geolocation.altDir .. '/AltNames.dat', 'rb')
        if ALTFILE then
            -- (upstream sets `local $/ = "\0"`, i.e. reads NUL-terminated
            --  records; Lua has no record separator, so the whole file is
            --  split on NUL here -- entries never contain one)
            local buff = ALTFILE:read('a')
            ALTFILE:close()
            altNames = {}
            local i = 0
            for rec in buff:gmatch('([^%z]*)%z') do
                altNames[i] = rec
                i = i + 1
            end
            if i == nCity then
                success = 1
            else
                warn('Bad number of entries in AltNames database\n')
                altNames = nil
            end
        else
            warn('Error reading ' .. Geolocation.altDir .. '/AltNames.dat\n')
        end
        Geolocation.altDir = nil
    end
    return success
end

--------------------------------------------------------------------------------
-- Clear last city matches cache
function Geolocation.ClearLastMatches()
    lastArgs = nil      -- arguments in last call to Geolocate
    lastFound = nil     -- keys are last matching city numbers, values are population codes
    lastByPop = nil     -- last matching city numbers ordered by population
    lastByLat = nil     -- last matching city numbers ordered by latitude
end

--------------------------------------------------------------------------------
-- Sort database by specified field
-- Inputs: 0) Field name to sort (Latitude,City,Country)
-- Returns: 1 on success
function Geolocation.SortDatabase(field)
    Geolocation.init()
    if field == sortedBy then return 1 end  -- already sorted?
    sortOrder = nil
    local order = {}
    for i = 0, #cityList - 1 do order[#order + 1] = i end
    if field == 'Latitude' then
        tsort(order, function(a, b) return perl.lt(cityList[a + 1], cityList[b + 1]) end)
    elseif field == 'City' then
        tsort(order, function(a, b)
            return perl.lt(cityList[a + 1]:sub(14), cityList[b + 1]:sub(14))
        end)
    elseif field == 'Country' then
        local lkup = {}
        for _, i in ipairs(order) do
            local city = cityList[i + 1]:sub(14)
            local ctry = countryList[cityList[i + 1]:byte(6) + 1]:sub(3)
            lkup[i] = ctry .. ' ' .. city
        end
        tsort(order, function(a, b) return perl.lt(lkup[a], lkup[b]) end)
    else
        return 0
    end
    sortOrder = order
    sortedBy = field
    Geolocation.ClearLastMatches()
    return 1
end

--------------------------------------------------------------------------------
-- Add cities to the Geolocation database
-- Inputs: 0-8) city,region,subregion,country_code,country,timezone,feature_code,population,lat,lon,altNames
-- eg. AddEntry('Sinemorets','Burgas','Obshtina Tsarevo','BG','Bulgaria','Europe/Sofia','',400,42.06115,27.97833)
-- Returns: true on success, otherwise issues warning
function Geolocation.AddEntry(...)
    local args = table.pack(...)
    local city, region, subregion, cc, country, timezone, fc, pop, lat, lon, altNamesArg =
        args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11]
    if args.n < 10 then
        warn('Too few arguments in ' .. perlStr(city) ..
            ' definition (check for updated format)\n')
        return 0
    end
    if #cc ~= 2 then
        warn("Country code '" .. cc .. "' is not 2 characters\n")
        return 0
    end
    local code, name = fc:match('^(.-) (.*)$')
    if code then
        featureTypes[code] = name
        fc = code
    end
    local fn = featureCodes[lc(fc)]
    if fn == nil then
        if dbVer == '1.02' or #featureCodesList > 0x3f or #fc == 0 then
            fn = 0
        else
            featureCodesList[#featureCodesList + 1] = uc(fc)
            fn = #featureCodesList - 1
            featureCodes[lc(fc)] = fn
        end
    end
    lon = perlStr(lon):gsub('\n$', '') -- (just in case it was read from file)
    -- create reverse lookups for country/region/subregion/timezone if not done already
    -- (eg. if the entries are being added manually instead of via UserDefined::Geolocation)
    if next(countryNum) == nil then
        for i = 1, #countryList do countryNum[lc(countryList[i]:sub(1, 2))] = i - 1 end
        for i = 1, #regionList do regionNum[lc(regionList[i])] = i - 1 end
        for i = 1, #subregionList do subregionNum[lc(subregionList[i])] = i - 1 end
        for i = 1, #timezoneList do timezoneNum[lc(timezoneList[i])] = i - 1 end
    end
    local cn = countryNum[lc(cc)]
    if cn == nil then
        if #countryList - 1 >= 0xff then
            warn('AddEntry: Too many countries\n')
            return 0
        end
        countryList[#countryList + 1] = cc .. country
        cn = #countryList - 1
        countryNum[lc(cc)] = cn
    elseif country and #country > 0 then
        countryList[cn + 1] = cc .. country -- (override existing country name)
    end
    local tn = timezoneNum[lc(timezone)]
    if tn == nil then
        if #timezoneList - 1 >= 0x1ff then
            warn('AddEntry: Too many time zones\n')
            return 0
        end
        timezoneList[#timezoneList + 1] = timezone
        tn = #timezoneList - 1
        timezoneNum[lc(timezone)] = tn
    end
    local rn = regionNum[lc(region)]
    if rn == nil then
        if #regionList - 1 >= 0xfff then
            warn('AddEntry: Too many regions\n')
            return 0
        end
        regionList[#regionList + 1] = region
        rn = #regionList - 1
        regionNum[lc(region)] = rn
    end
    local sn = subregionNum[lc(subregion)]
    if sn == nil then
        local max = dbVer == '1.02' and 0x7fff or 0xffff
        if #subregionList - 1 >= max then
            warn('AddEntry: Too many subregions\n')
            return 0
        end
        subregionList[#subregionList + 1] = subregion
        sn = #subregionList - 1
        subregionNum[lc(subregion)] = sn
    end
    pop = sprintf('%.1e', pop) -- format: "3.1e+04" or "3.1e+004"
    -- pack CC index, population and region index into a 32-bit integer
    local packed = (cn << 24) | (tonumber(pop:sub(-1, -1)) << 20) |
        (tonumber(pop:sub(1, 1)) << 16) | (tonumber(pop:sub(3, 3)) << 12) | rn
    -- store high bit of timezone index
    if tn > 255 then
        if dbVer == '1.02' then
            sn = sn | 0x8000
        else
            fn = fn | 0x80
        end
        tn = tn - 256
    end
    lat = math.floor((tonumber(lat) + 90) / 180 * 0x100000 + 0.5) & 0xfffff
    lon = math.floor((tonumber(lon) + 180) / 360 * 0x100000 + 0.5) & 0xfffff
    local hdr = perl.pack('nCnNnCC', lat >> 4, ((lat & 0x0f) << 4) | (lon & 0x0f),
        lon >> 4, packed, sn, tn, fn)
    cityList[#cityList + 1] = hdr .. city
    -- add altNames entry if provided
    if altNamesArg then
        local alt = altNamesArg:gsub('\n$', '') -- (just in case)
        alt = alt:gsub(',', '\n')
        -- add any more arguments in case altNames were passed separately (undocumented)
        for i = 12, args.n do
            alt = alt .. '\n' .. (args[i]:gsub('\n$', ''))
        end
        altNames = altNames or {}
        altNames[#cityList - 1] = alt
    end
    sortedBy = ''
    lastArgs = nil      -- (faster than ClearLastArgs)
    return 1
end

-- (port: upstream's `eval "require 'GeoLang/$lang.pm'"` with $geoDir put
--  first in @INC, then %Image::ExifTool::GeoLang::${lang}::Translate. The
--  locations are those of the require: geoDir, then the templates of
--  package.path (the counterpart of @INC). At each location GeoLang/<lang>.lua,
--  a data file returning the Translate table (tools/gen_geolang.lua writes
--  it from the .pm), comes first and runs with an empty environment; then
--  GeoLang/<lang>.pm itself, read as data by lexiftool.GeoLangData (a .pm
--  is never run as Perl). The first file found decides, as require stops
--  at the first file: a .pm that is not a pure data table warns and, like a
--  failed require, gives no translations. Returns the table, or nil.)
local function GeoLangTranslate(geoDir, lang)
    local candidates = {}   -- { path or template, isPm, isTemplate } in search order
    if geoDir and geoDir ~= '' then
        local base = geoDir .. '/GeoLang/' .. lang
        candidates[#candidates + 1] = { base .. '.lua' }
        candidates[#candidates + 1] = { base .. '.pm', true }
    end
    local pathSep, mark = package.config:sub(3, 3), package.config:sub(5, 5)
    local name = 'GeoLang.' .. lang
    local searchPath, pos = package.path, 1
    while pos <= #searchPath + 1 do
        local stop = searchPath:find(pathSep, pos, true) or #searchPath + 1
        local template = searchPath:sub(pos, stop - 1)
        pos = stop + 1
        if template ~= '' then
            candidates[#candidates + 1] = { template, false, true }
            -- (a `?.lua` template names the .pm sibling `?.pm`)
            if template:sub(-#mark - 4) == mark .. '.lua' then
                candidates[#candidates + 1] = { template:sub(1, -5) .. '.pm', true, true }
            end
        end
    end
    for _, c in ipairs(candidates) do
        local path, isPm = c[1], c[2]
        if c[3] then
            path = package.searchpath(name, path)
        elseif not perl.filetest('e', path) then
            path = nil
        end
        if path then
            if not isPm then
                local chunk = loadfile(path, 't', {})
                if not chunk then return nil end
                local ok, trans = pcall(chunk)
                if not ok or type(trans) ~= 'table' then return nil end
                return trans
            end
            local fh = io.open(path, 'rb')
            if not fh then return nil end
            local text = fh:read('a')
            fh:close()
            local GeoLangData = require('lexiftool.GeoLangData')
            local lines, declared = GeoLangData.Parse(text)
            if not lines then
                -- (to stderr past the $SIG{__WARN__} of the caller, which
                --  collects warnings it only reports when no city is found)
                local oldWarn = perl.SIG.__WARN__
                perl.SIG.__WARN__ = nil
                warn('GeoLang file not supported by lexiftool (Perl code, not a pure data table): ' ..
                     path .. "\n")
                perl.SIG.__WARN__ = oldWarn
                return nil
            end
            -- (a file declaring another language's hash leaves this one's empty)
            if declared ~= lang then return nil end
            return GeoLangData.Translate(lines)
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Unpack entry in database
-- Inputs: 0) entry number or index into sorted database,
--         1) optional language code, 2) flag to use index into sorted database
-- Returns: 0-10) city,region,subregion,country_code,country,timezone,
--                feature_code,pop,lat,lon,feature_type
function Geolocation.GetEntry(entryNum, lang, sort)
    Geolocation.init()
    if entryNum > #cityList - 1 then return nil end
    if sort and sortOrder and #sortOrder > entryNum then entryNum = sortOrder[entryNum + 1] end
    local entry = cityList[entryNum + 1]
    local lt, f, ln, code, sn, tn, fn = perl.unpack('nCnNnCC', entry)
    local city = entry:sub(14)
    local ctry = countryList[(code >> 24) + 1]
    local rgn = regionList[(code & 0x0fff) + 1]
    if dbVer == '1.02' then
        if sn & 0x8000 ~= 0 then tn = tn + 256 sn = sn & 0x7fff end
    else
        if fn & 0x80 ~= 0 then tn = tn + 256 end
    end
    local sub = subregionList[sn + 1]
    -- convert population digits back into exponent format
    local pop = tonumber((code >> 16 & 0x0f) .. '.' .. (code >> 12 & 0x0f) ..
        'e+' .. (code >> 20 & 0x0f))
    lt = sprintf('%.4f', ((lt << 4) | (f >> 4)) * 180 / 0x100000 - 90)
    ln = sprintf('%.4f', ((ln << 4) | (f & 0x0f)) * 360 / 0x100000 - 180)
    local fc = featureCodesList[(fn & 0x3f) + 1] or 'Other'
    local cc = ctry:sub(1, 2)
    local country = ctry:sub(3)
    local ft = featureTypes[fc]
    if lang and lang ~= 'en' then
        local xlat = langLookup[lang]
        -- load language lookups if  not done already
        if xlat == nil then
            -- make sure $geoDir is first in path
            -- (Lua: GeoLang/<lang>.lua, else GeoLang/<lang>.pm read as data,
            --  looked up in $geoDir first and then along package.path, as
            --  upstream's require looks in $geoDir and then @INC)
            local trans = GeoLangTranslate(Geolocation.geoDir, lang)
            if trans and next(trans) ~= nil then xlat = trans end
            -- read user-defined language translations
            local userLang = Geolocation.geoLang and Geolocation.geoLang[lang]
            if type(userLang) == 'table' then
                if xlat then
                    -- add user-defined entries to main lookup
                    for k, v in pairs(userLang) do xlat[k] = v end
                else
                    xlat = userLang
                end
            end
            langLookup[lang] = xlat or false
        end
        if xlat then
            local r2 = rgn
            -- City-specific: "CCRgn,Sub,City", "CCRgn,City", "CC,City", ",City"
            -- Subregion-specific: "CCRgn,Sub,"
            -- Region-specific: "CCRgn,"
            -- Country-specific: "CC,"
            city = xlat[cc .. r2 .. ',' .. sub .. ',' .. city] or xlat[cc .. r2 .. ',' .. city] or
                   xlat[cc .. ',' .. city] or xlat[',' .. city] or xlat[city] or city
            sub = xlat[cc .. rgn .. ',' .. sub .. ','] or xlat[sub] or sub
            rgn = xlat[cc .. rgn .. ','] or xlat[rgn] or rgn
            country = xlat[cc .. ','] or xlat[country] or country
            if xlat[fc] then ft = xlat[fc] end
        end
    end
    return city, rgn, sub, cc, country, timezoneList[tn + 1], fc, pop, lt, ln, ft
end

--------------------------------------------------------------------------------
-- Get alternate names for specified database entry
-- Inputs: 0) entry number or index into sorted database, 1) sort flag
-- Returns: comma-separated list of alternate names, or empty string if no names
-- Notes: ReadAltNames() must be called before this
function Geolocation.GetAltNames(entryNum, sort)
    if sort and sortOrder and #sortOrder > entryNum then entryNum = sortOrder[entryNum + 1] end
    local alt = altNames and altNames[entryNum]
    if not alt or alt == '' then return '' end
    return (alt:gsub('\n', ','))
end

--------------------------------------------------------------------------------
-- Look up lat,lon or city in geolocation database
-- Inputs: 0) "lat,lon", "city,region,country", etc, (city must be first)
--         1) options hash reference (or undef for no options)
-- Options: GeolocMinPop, GeolocMaxDist, GeolocMulti, GeolocFeature, GeolocAltNames,
--          GeolocNearby
-- Returns: 0) Reference to list of indices for matching cities, or undef for no matches
--          1) Reference to list of distance/bearing pairs, or undef if no GPS
--          In scalar context returns list of indices only
-- Port note: Perl's `wantarray` has no Lua counterpart, so both lists are
-- always returned and the caller ignores the second one if it has no use for
-- it. The `next Entry` label of the search loop becomes a `goto nextEntry`.
function Geolocation.Geolocate(arg, opts)
    Geolocation.init()
    local city, other, idx
    local exact, regex, cargs = {}, {}, {}
    local minPop, minDistU, minDistC, matchParms, coords, fcOK, both
    coords, fcOK, matchParms = {}, {}, nil
    -- (`multi` is GeolocMulti, which upstream unpacks here but never uses in
    --  this sub either -- only its caller does)
    local pop, maxDist, multi, fcodes, altNamesOpt -- luacheck: ignore 211 multi

    if opts then
        pop, maxDist, multi, fcodes, altNamesOpt =
            opts.GeolocMinPop, opts.GeolocMaxDist, opts.GeolocMulti,
            opts.GeolocFeature, opts.GeolocAltNames
    end

    if #cityList == 0 then
        warn('No Geolocation database')
        return nil
    end
    -- make population code for comparing with 2 bytes at offset 6 in database
    if perlTruthy(pop) then
        pop = sprintf('%.1e', pop)
        minPop = string.char((tonumber(pop:sub(-1, -1)) << 4) | tonumber(pop:sub(1, 1))) ..
                 string.char(tonumber(pop:sub(3, 3)) << 4)
    end
    if perlTruthy(fcodes) then
        local neg = perlStr(fcodes):sub(1, 1) == '-'
        if neg then fcodes = perlStr(fcodes):sub(2) end
        -- (allow leading dash on subsequent codes)
        local list = perl.split('\\s*,-?\\s*', lc(fcodes))
        if neg then
            for i = 0, #featureCodesList - 1 do fcOK[i] = 1 end
            for _, c in ipairs(list) do
                if featureCodes[c] ~= nil then fcOK[featureCodes[c]] = nil end
            end
        else
            for _, c in ipairs(list) do
                if featureCodes[c] ~= nil then fcOK[featureCodes[c]] = 1 end
            end
        end
    end
--
-- process input argument
--
    local num = 1
    arg = arg:gsub('^[ \t\n\r\f\v]+', ''):gsub('[ \t\n\r\f\v]+$', '') -- remove leading/trailing spaces
    local args = perl.split('\\s*,\\s*', arg)
    local ri = { cc = 0, co = 1, re = 2, sr = 3, ci = 8, [''] = 9 }
    for _, a in ipairs(args) do
        -- allow regular expressions optionally prefixed by "ci", "cc", "co", "re" or "sr"
        local ok, neg, pfx, re, ci = isMatch(a, [[^(-)?(\w{2})?/(.*)/(i?)$]])
        if ok then
            -- (Perl's /im and /m flags become PCRE2's inline (?im)/(?m))
            local rx = ((ci ~= '' and '(?im)' or '(?m)') .. re)
            idx = ri[pfx or '']
            if idx ~= nil then
                cargs[#cargs + 1] = a
                if idx < 5 then other = 1 end
                if neg then idx = idx + 10 end  -- add 10 for negative matches
                regex[idx] = regex[idx] or {}
                table.insert(regex[idx], rx)
                if city == nil then city = '' end
            end
        elseif isMatch(a, [[^[-+]?\d+(\.\d+)?$]]) then    -- coordinate format
            if #coords < 2 then coords[#coords + 1] = tonumber(a) end
        elseif perl.matches(a, [[(?i)^([-+]?\d+(?:\.\d+)?) *(([NS])[A-Z]*)? +([-+]?\d+(?:\.\d+)?) *(([EW])[A-Z]*)?]]) then -- "lat lon" format
            if #coords == 0 then
                local c1, _, c3, c4, _, c6 = perl.matches(a, [[(?i)^([-+]?\d+(?:\.\d+)?) *(([NS])[A-Z]*)? +([-+]?\d+(?:\.\d+)?) *(([EW])[A-Z]*)?]])
                local lat, lon = tonumber(c1), tonumber(c4)
                if c3 and uc(c3) == 'S' then lat = -math.abs(lat) end
                if c6 and uc(c6) == 'W' then lon = -math.abs(lon) end
                coords[#coords + 1] = lat
                coords[#coords + 1] = lon
            end
        elseif lc(a) == 'both' then
            both = 1
        elseif perl.matches(a, [[(?i)^num=(\d+)$]]) then
            num = tonumber((perl.matches(a, [[(?i)^num=(\d+)$]])))
        elseif a ~= '' then
            cargs[#cargs + 1] = a
            if city and city ~= '' then
                exact[#exact + 1] = lc(a)
            else
                city = lc(a)
            end
        end
    end
    if city == nil and #coords ~= 2 then
        warn('Insufficient information to determine geolocation\n')
        return nil
    end
    -- sort database by logitude if finding entry based on coordinates
    if #coords == 2 and (both or city == nil) then Geolocation.SortDatabase('Latitude') end
--
-- perform reverse Geolocation lookup to determine GPS based on city, country, etc.
--
    -- (upstream's `while`, left through `last` or `return` in every path)
    while city ~= nil and (#coords ~= 2 or both) do -- luacheck: ignore 512
        local cargsStr = table.concat(cargs, ',') .. ',' .. (perlTruthy(pop) and pop or '') .. ',' ..
                         perlStr(perlTruthy(maxDist) and maxDist or '') .. ',' .. perlStr(perlTruthy(fcodes) and fcodes or '')
        local i = 0
        if lastArgs and lastArgs == cargsStr then
            i = #cityList   -- bypass search
        else
            Geolocation.ClearLastMatches()
            lastArgs = cargsStr
        end
        lastFound = lastFound or {}
        lastByLat = lastByLat or {}
        lastByPop = lastByPop or {}
        -- read alternate names database if an exact city match is specified
        local altNamesTbl
        if perlTruthy(altNamesOpt) then
            if city ~= '' and Geolocation.altDir then Geolocation.ReadAltNames() end
            altNamesTbl = altNames or {}
        else
            altNamesTbl = {}    -- (don't search alt names)
        end
        while i < #cityList do
            local entry = cityList[i + 1]
            local cty = entry:sub(14)
            local skip = false
            if city ~= '' and city ~= lc(cty) then -- test exact city name first
                local alt = altNamesTbl[i]
                if not (alt and perl.isMatchDyn(alt, '(?im)^' .. city .. '$')) then
                    skip = true
                end
            end
            -- test with city-specific regexes
            if not skip and regex[8] then
                for _, r in ipairs(regex[8]) do
                    if not perl.isMatchDyn(cty, r) then skip = true break end
                end
            end
            if not skip and regex[18] then
                for _, r in ipairs(regex[18]) do
                    if perl.isMatchDyn(cty, r) then skip = true break end
                end
            end
            if not skip then
                -- test other arguments
                local cd, sn = perl.unpack('x5Nn', entry)
                local ct = countryList[(cd >> 24) + 1]
                if dbVer == '1.02' then sn = sn & 0x7fff end
                local geo = { ct:sub(1, 2), ct:sub(3), regionList[(cd & 0x0fff) + 1],
                              subregionList[sn + 1] }
                if #exact > 0 then
                    -- make quick lookup for all names at this location
                    local geoLkup = {}
                    for _, g in ipairs(geo) do
                        if g and g ~= '' then geoLkup[lc(g)] = 1 end
                    end
                    for _, e in ipairs(exact) do
                        if not geoLkup[e] then skip = true break end
                    end
                end
                -- test with cc, co, re and sr regexes
                if not skip and other then
                    for j = 0, 3 do
                        if regex[j] then
                            for _, r in ipairs(regex[j]) do
                                if not perl.isMatchDyn(geo[j + 1], r) then skip = true break end
                            end
                        end
                        if not skip and regex[j + 10] then
                            for _, r in ipairs(regex[j + 10]) do
                                if perl.isMatchDyn(geo[j + 1], r) then skip = true break end
                            end
                        end
                        if skip then break end
                    end
                end
                -- test regexes for any place name
                if not skip and (regex[9] or regex[19]) then
                    local str = cty .. '\n' .. table.concat(geo, '\n')
                    for _, r in ipairs(regex[9] or {}) do
                        if not perl.isMatchDyn(str, r) then skip = true break end
                    end
                    if not skip then
                        for _, r in ipairs(regex[19] or {}) do
                            if perl.isMatchDyn(str, r) then skip = true break end
                        end
                    end
                end
                -- test feature code and population
                if not skip and perlTruthy(fcodes) and not fcOK[entry:byte(13) & 0x3f] then skip = true end
                if not skip then
                    local pc = entry:sub(7, 8)
                    if minPop == nil or not perl.lt(pc, minPop) then
                        lastFound[i] = pc
                        if #coords == 2 then lastByLat[#lastByLat + 1] = i end
                    end
                end
            end
            i = i + 1
        end
        if next(lastFound) ~= nil then
            if #coords == 2 then break end  -- continue to use coords with last city matches
            local nFound = 0
            for _ in pairs(lastFound) do nFound = nFound + 1 end
            if nFound > 200 then
                warn('Too many matching cities\n')
                return nil
            end
            -- return nearby cities if "num=" is used and only one match found
            if num > 1 and nFound == 1 then
                local one = next(lastFound)
                local entry = table.pack(Geolocation.GetEntry(one))
                coords = { tonumber(entry[9]), tonumber(entry[10]) }
                Geolocation.SortDatabase('Latitude')    -- (make sure we are sorted by latitude)
                break
            end
            if #lastByPop == 0 then
                for k in pairs(lastFound) do lastByPop[#lastByPop + 1] = k end
                tsort(lastByPop, function(a, b)
                    if lastFound[a] ~= lastFound[b] then return perl.lt(lastFound[b], lastFound[a]) end
                    return perl.lt(cityList[a + 1], cityList[b + 1])
                end)
            end
            return lastByPop
        end
        warn('No such city in Geolocation database\n')
        return nil
    end
--
-- determine Geolocation based on GPS coordinates
--
    local lat, lon = coords[1], coords[2]
    if perlTruthy(maxDist) then
        minDistU = perl.num(maxDist) / (2 * earthRadius)              -- min distance on unit sphere
        minDistC = perl.num(maxDist) * 0x100000 / (pi * earthRadius)  -- min distance in coordinate units
    else
        minDistU = pi
        minDistC = 0x200000
    end
    -- luacheck: push ignore 211
    local cos = math.cos(lat * pi / 180) -- cosine factor for longitude distances
    -- luacheck: pop
    -- (upstream computes $cos here and never reads it -- kept for parity)
    -- reduce lat/lon to the range 0-0x100000
    lat = math.floor((lat + 90) / 180 * 0x100000 + 0.5) & 0xfffff
    lon = math.floor((lon + 180) / 360 * 0x100000 + 0.5) & 0xfffff
    -- (zero latitude is a problem for our calculations)
    if lat == 0 then lat = coords[1] < 0 and 1 or 0xfffff end
    local coord = perl.pack('nCn', lat >> 4, ((lat & 0x0f) << 4) | (lon & 0x0f), lon >> 4)
    -- start from cached city matches if also using city information
    local numEntries = (lastByLat and #lastByLat > 0) and #lastByLat or #cityList
    -- binary search to find closest longitude
    local n0, n1 = 0, numEntries - 1
    local sorted
    if lastByLat and #lastByLat > 0 then
        sorted = lastByLat
    elseif sortOrder and #sortOrder > 0 then
        sorted = sortOrder
    end
    while n1 - n0 > 1 do
        local n = (n0 + n1) // 2
        if perl.lt(coord, cityList[(sorted and sorted[n + 1] or n) + 1]) then
            n1 = n
        else
            n0 = n
        end
    end
    -- step backward then forward through database to find nearest city
    local inc, endN, n = -1, -1, n0 + 1
    local p0, t0 = lat * pi / 0x100000 - pi / 2, lon * pi / 0x080000 - pi
    local cp0 = math.cos(p0)
    local matches, rtnList, dist = {}, {}, {}

    while true do
        n = n + inc
        if n == endN then
            if inc == 1 or n0 == n1 then break end
            inc, endN, n = 1, numEntries, n1
        end
        local i = sorted and sorted[n + 1] or n
        local entry = cityList[i + 1]
        -- get city latitude/longitude
        local lt, f, ln = perl.unpack('nCn', entry)
        lt = (lt << 4) | (f >> 4)
        -- searched far enough if latitude alone is further than best distance
        if math.abs(lt - lat) > minDistC then
            n = endN - inc
            goto nextCity
        end
        -- ignore if population is below threshold
        if minPop ~= nil and not perl.lt(minPop, entry:sub(7, 8)) then goto nextCity end
        if perlTruthy(fcodes) and not fcOK[entry:byte(13) & 0x3f] then goto nextCity end
        ln = (ln << 4) | (f & 0x0f)
        do
            -- calculate great circle distance to this city on unit sphere
            local p1, t1 = lt * pi / 0x100000 - pi / 2, ln * pi / 0x080000 - pi
            local sp, st = math.sin((p1 - p0) / 2), math.sin((t1 - t0) / 2)
            local a = sp * sp + cp0 * math.cos(p1) * st * st
            local distU = math.atan(math.sqrt(a), math.sqrt(1 - a)) -- distance on unit sphere
            if distU > minDistU then goto nextCity end
            matchParms = { i, p1, t1, distU }
            if num <= 1 then
                minDistU = distU
            else
                local j = 1
                -- add this entry into list of matching cities ordered by closest first
                while j <= #matches do
                    if distU < matches[j][4] then break end
                    j = j + 1
                end
                if j < #matches then
                    table.insert(matches, j, { table.unpack(matchParms) })
                else
                    matches[j] = { table.unpack(matchParms) }
                end
                -- restrict list to the specified number of nearest cities
                if #matches > num then matches[#matches] = nil end
                -- update minimum distance with furthest match if we satisfied our quota
                if #matches >= num then minDistU = matches[#matches][4] end
            end
            minDistC = minDistU * 0x200000 / pi  -- distance in scaled coordinate units
        end
        ::nextCity::
    end
    if not matchParms then
        warn('No suitable location in Geolocation database\n')
        return nil
    end
    num = #matches

    while true do
        if num > 1 then
            if #matches == 0 then break end
            matchParms = matches[1]
            table.remove(matches, 1)
        end
        -- calculate distance in km and bearing to matching city
        local ii, p1, t1, distU = matchParms[1], matchParms[2], matchParms[3], matchParms[4]
        local km = sprintf('%.2f', 2 * earthRadius * distU)
        local be = math.atan(math.sin(t1 - t0) * math.cos(p1 - p0),
                             cp0 * math.sin(p1) - math.sin(p0) * math.cos(p1) * math.cos(t1 - t0))
        be = math.floor(be * 180 / pi + 360.5) % 360 -- convert from radians to integer degrees
        rtnList[#rtnList + 1] = ii
        dist[#dist + 1] = { km, be }
        if num <= 1 then break end
    end
    return rtnList, dist
end

--------------------------------------------------------------------------------
-- Module initialization (upstream runs these statements at the end of the
-- module's chunk; see this module's Port notes for why they live in a
-- function here). Idempotent.
function Geolocation.init()
    if cityList then return end
    cityList = {} -- (marks init as done even if the read below fails)
    -- read the Geolocation database unless $geoDir set to empty string
    if not (Geolocation.geoDir ~= nil and Geolocation.geoDir == '') then
        if not (Geolocation.geoDir and
            Geolocation.ReadDatabase(Geolocation.geoDir .. '/Geolocation.dat') == 1)
        then
            -- (port: the bundled database, GeolocationData.lua -- a Lua
            --  module, not a file, see this module's Port notes; require()
            --  rather than ReadDatabase(path) so it works identically via
            --  the rock, the standalone executable and the C API)
            local ok, data = pcall(require, 'lexiftool.GeolocationData')
            if ok then
                Geolocation.ReadDatabase(data, true)
            else
                warn('Error reading the bundled Geolocation database\n')
            end
        end
    end
    -- set directory for language files and alternate names
    if Geolocation.geoDir == nil then Geolocation.geoDir = defaultDir end
    if Geolocation.altDir == nil and Geolocation.geoDir and
        perl.stat(Geolocation.geoDir .. '/AltNames.dat')
    then
        Geolocation.altDir = Geolocation.geoDir
    end
    langLookup = langLookup or {}
    -- add user-defined entries to the database
    if UserDefinedGeolocation() and #UserDefinedGeolocation() > 0 then
        for _, e in ipairs(UserDefinedGeolocation()) do Geolocation.AddEntry(table.unpack(e)) end
    end
end

return Geolocation
