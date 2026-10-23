--------------------------------------------------------------------------------
-- File:         lexiftool/Geotag.lua
-- Ported from:  lib/Image/ExifTool/Geotag.pm
--
-- Description:  Geotagging utility routines
--
-- Revisions:    2009/04/01 - P. Harvey Created
--               2009/09/27 - PH Added Geosync feature
--               2009/06/25 - PH Read Garmin TCX track logs
--               2009/09/11 - PH Read ITC GPS track logs
--               2012/01/08 - PH Extract orientation information from PTNTHPR
--               2012/05/08 - PH Read Winplus Beacon .TXT files
--               2015/05/30 - PH Read Bramor gEO log files
--               2016/07/13 - PH Added ability to geotag date/time only
--               2019/07/02 - PH Added ability to read IMU CSV files
--               2019/11/10 - PH Also write pitch to CameraElevationAngle
--               2020/12/01 - PH Added ability to read DJI CSV log files
--               2022/06/21 - PH Added ability to read Google Takeout JSON files
--               2024/04/23 - PH Added ability to read more OpenTracks GPS tags
--               2024/08/28 - PH Added support for new Google Takeout JSON format
--               2024/11/26 - PH Also write GPSMeasureMode and GPSDOP
--               2024/11/05 - PH Added support for Google Maps "Export timeline data"
--                               JSON format
--               2025/09/22 - PH Added ability to read Columbus CSV  log files
--               2026/01/24 - PH Added GeoUserTag feature
--
-- References:   1) http://www.topografix.com/GPX/1/1/
--               2) http://www.gpsinformation.org/dale/nmea.htm#GSA
--               3) http://code.google.com/apis/kml/documentation/kmlreference.html
--               4) http://www.fai.org/gliding/system/files/tech_spec_gnss.pdf
--
-- Port notes:   the whole module is ported: SplitCSV, LoadTrackLog (XML/GPX/
--               KML/Garmin, NMEA RMC/GGA/GLL/GSA/ZDA/PMGNTRK/PTNTHPR, IGC,
--               Winplus, Bramor, CSV, Google JSON, and the "read GPS from an
--               image/video file" fallback), GetTime, ApplySyncCorr,
--               ScanOutwards, FindFix, SetGeoValues, ConvertGeosync,
--               PrintFixTime, PrintFix and InitUserTags.
--
--               Deviations forced by Lua:
--               * Perl's `$_` inside LoadTrackLog becomes the local `line`,
--                 and its `%fix`/`$fix` pair (one namespace in Lua) becomes
--                 `fixHash`/`fix`.
--               * `goto DoneFix` jumps into a sibling `elsif` block, which
--                 Lua's goto cannot do; the shared tail is reached through
--                 the `doneFix` flag instead, at the same place in the loop.
--               * Perl's `$/` (input record separator) is a global that
--                 File::RandomAccess::ReadLine reads; here the separator is
--                 passed to `RandomAccess:ReadLine(rs)` explicitly.
--               * `Time::Local::timegm`, Perl's `gmtime`, its scalar
--                 numification and `\Q` become `perl.timegm`, `perl.gmtime`,
--                 `perl.num` and the local `quotemeta` (timegm is handed the
--                 captured strings as upstream does, so its croak quotes
--                 them alike: "Day '00' out of range 1..31").
--               * `$et->Open(\*FH, $val)` (which applies the FileName
--                 character set) has no counterpart in this port yet, so the
--                 track file is opened with `io.open` directly.
--               * The GeoHPosErr option's `eval` of a user-supplied Perl
--                 expression in SetGeoValues runs through perl.eval, with
--                 $GPSDOP as its variable.
--
--               The Geotag/Geotime DelCheck entries in %Extra are called by
--               SetNewValue as upstream, and the GPS values SetGeoValues
--               sets are written through the regular write path (a GPS IFD
--               is created where the file has none).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local tsort = perl.tsort
local GPS = require('lexiftool.GPS')
local RandomAccess = require('lexiftool.RandomAccess')

local matches, isMatch = perl.matches, perl.isMatch
local subst, split, findAll, eachMatch = perl.subst, perl.split, perl.findAll, perl.eachMatch
local substr = perl.substr
local perlStr = perl.str
local timegm, gmtime, localtime, num = perl.timegm, perl.gmtime, perl.localtime, perl.num
local lc = perl.lc
local perlTruthy = ExifTool.perlTruthy

local Geotag = {}

-- Perl `\Q$var` (quotemeta): escape every non-word character so the value is
-- matched literally
local function quotemeta(s)
    return (perlStr(s):gsub('([^A-Za-z0-9])', '\\%1'))
end

-- Perl file test `-f $path`
local function isFile(path)
    local st = perl.stat(path)
    return st ~= nil and st.mode == 'file'
end

-- Perl's bare `split` / `split ' ', $_`: strip leading whitespace, then split
-- on runs of whitespace
local function splitSpace(s)
    return split([[\s+]], subst(s, [[^\s+]], ''))
end

-- Perl int(): truncate toward zero (math.floor rounds down for negatives)
local function int(v)
    return v < 0 and math.ceil(v) or math.floor(v)
end

Geotag.VERSION = '1.88'

local function JITTER() return 2 end     -- maximum time jitter

-- XML tags that we recognize (keys are forced to lower case)
local xmlTag = {
    lat         = 'lat',        -- GPX
    latitude    = 'lat',        -- Garmin
    latitudedegrees = 'lat',    -- Garmin TCX
    lon         = 'lon',        -- GPX
    longitude   = 'lon',        -- Garmin
    longitudedegrees = 'lon',   -- Garmin TCX
    ele         = 'alt',        -- GPX
    elevation   = 'alt',        -- PH
    alt         = 'alt',        -- PH
    altitude    = 'alt',        -- Garmin
    altitudemeters = 'alt',     -- Garmin TCX
    ['time']    = 'time',       -- GPX/Garmin
    fix         = 'fixtype',    -- GPX
    hdop        = 'hdop',       -- GPX
    vdop        = 'vdop',       -- GPX
    pdop        = 'pdop',       -- GPX
    sat         = 'nsats',      -- GPX
    atemp       = 'atemp',      -- GPX (Garmin 550t)
    when        = 'time',       -- KML
    coordinates = 'coords',     -- KML
    coord       = 'coords',     -- KML, as written by Google Location History
    begin       = 'begin',      -- KML TimeSpan
    ['end']     = 'time',       -- KML TimeSpan
    course      = 'dir',        -- (written by Arduino)
    pitch       = 'pitch',      -- (written by Arduino)
    roll        = 'roll',       -- (written by Arduino)
    speed       = 'speed',      -- (OpenTrack gpx)
    accuracy_horizontal = 'err',--(OpenTrack gpx)
    -- XML containers (fix is reset at the opening tag of these properties)
    wpt         = '',           -- GPX
    trkpt       = '',           -- GPX
    rtept       = '',           -- GPX
    trackpoint  = '',           -- Garmin
    placemark   = '',           -- KML
}

local userTag = { }             -- user-defined XML tags

-- fix information keys which must be interpolated around a circle
local cyclical = { lon = 1, track = 1, dir = 1, pitch = 1, roll = 1 }
local cyc180 = { lon = 1, pitch = 1, roll = 1 } -- wraps from 180 to -180

-- fix information keys for each of our general categories
local fixInfoKeys = {
    ['pos'] = { 'lat', 'lon' },
    track  = { 'track', 'speed' },
    alt    = { 'alt' },
    orient = { 'dir', 'pitch', 'roll' },
    atemp  = { 'atemp' },
    err    = { 'err' },
    dop    = { 'hdop', 'vdop', 'pdop' },
}

-- category for select keys
local keyCategory = {
    track = 'track',
    speed = 'track',
    alt   = 'alt',
    dir   = 'orient',
    pitch = 'orient',
    roll  = 'orient',
    hdop  = 'dop',
    pdop  = 'dop',
    vdop  = 'dop',
}

-- list of tags used when geotagging from image/video files,
-- and the corresponding fix information key
local tagKey = {
    GPSDateTime  = 'time',
    GPSLatitude  = 'lat',
    GPSLongitude = 'lon',
    GPSTrack     = 'track',
    GPSSpeed     = 'speed',
    GPSAltitude  = 'alt',
    TimeStamp    = 'time',
    -- the following are needed to generate Composite GPSDateTime tag
    -- since any tag not listed here is ignored
    GPSTimeStamp = '',
    GPSDateStamp = '',
}

-- tags which may exist separately in some formats (eg. CSV)
local sepTags = {
    dir = 1, pitch = 1, roll = 1, track = 1, speed = 1,
    -- (plus other tags we don't want to scan outwards for)
    hdop = 1, pdop = 1, vdop = 1,
}

-- conversion factors for GPSSpeed (standard EXIF units only)
local speedConv = {
    ['K'] = 1.852,          -- km/h per knot
    ['M'] = 1.150779448,    -- mph per knot
    ['k'] = 'K',            -- (allow lower case)
    ['m'] = 'M',
    ['km/h'] = 'K',         -- (allow other formats)
    ['mph'] = 'M',
}

-- all recognized speed conversion factors (non-EXIF included)
local otherConv = {
    ['km/h'] = 1.852,
    ['mph']  = 1.150779448,
    ['m/s']  = 0.514444,
}

local secPerDay = 24 * 3600 -- a useful constant

--------------------------------------------------------------------------------
-- Split a line of CSV
-- Inputs: 0) line to split, 1) delimiter
-- Returns: list of items
function Geotag.SplitCSV(line, delim)
    local toks = split(quotemeta(delim), line)
    local vals = { }
    local v
    local it = 1
    while it <= #toks do
        v = toks[it]; it = it + 1
        v = subst(v, [[^ +]], '')       -- remove leading spaces
        local n
        v, n = v:gsub('^"', '')
        if n > 0 then
            -- quoted value must end in an odd number of quotes
            while true do
                local q = matches(v, [[("+)\s*$]])
                if q and (#q & 1) ~= 0 then break end
                if it > #toks then break end
                v = v .. delim .. toks[it]; it = it + 1
            end
            v = subst(v, [["\s*$]], '') -- remove trailing quote and whitespace
            v = subst(v, '""', '"', 'g')-- un-escape quotes
        end
        vals[#vals + 1] = v
    end
    return vals
end

--------------------------------------------------------------------------------
-- Load GPS track log file or read GPS from image/video file
-- Inputs: 0) ExifTool ref, 1) track log data or file name
-- Returns: geotag hash data reference or error string
-- - the geotag hash has the following members:
--       Points - hash of GPS fix information hashes keyed by Unix time
--       Times  - list of sorted Unix times (keys of Points hash)
--       NoDate - flag if some points have no date (ie. referenced to 1970:01:01)
--       IsDate - flag if some points have date
--       Has    - hash of flags for available information (track, orient, alt)
-- - the fix information hash may contain:
--       lat    - signed latitude (required)
--       lon    - signed longitude (required)
--       alt    - signed altitude (m)
--       time   - fix time in UTC as XML string
--       fixtype- type of fix ('none'|'2d'|'3d'|'dgps'|'pps')
--       pdop   - dilution of precision
--       hdop   - horizontal DOP
--       vdop   - vertical DOP
--       sats   - comma-separated list of active satellites
--       nsats  - number of active satellites
--       track  - track heading (deg true)
--       dir    - image direction (deg true)
--       pitch  - pitch angle (deg)
--       roll   - roll angle (deg)
--       speed  - speed (knots)
--       first  - flag set for first fix of track
-- - concatenates new data with existing track data stored in ExifTool NEW_VALUE
--   for the Geotag tag
function Geotag.LoadTrackLog(et, val)
    local line, RS
    local raf, from, time, isDate, noDate, noDateChanged, lastDate, dateFlarm
    local nmeaStart, fixSecs, fixTimes, lastFix, nmea, csvHeadings, sortFixes
    local canCut, cutPDOP, cutHDOP, cutSats, e0, e1, tmp, trackFile, trackTime
    local scaleSpeed, startTime
    fixTimes, nmea, csvHeadings = { }, { }, { }

    Geotag.InitUserTags(et)

    -- add data to existing track
    local geotag = et:GetNewValue('Geotag') or { }

    -- initialize track points lookup
    local points = geotag.Points
    if not points then points = { }; geotag.Points = points end

    -- get lookup for available information types
    local has = geotag.Has
    if not has then has = { ['pos'] = 1 }; geotag.Has = has end

    local format = ''
    -- is val track log data?
    if isMatch(val, [==[^(\xef\xbb\xbf)?<(\?xml|gpx)[\s>]]==]) then
        format = 'XML'
        RS = '>'    -- set input record separator to '>' for XML/GPX data
    elseif matches(val, [[(\x0d\x0a|\x0d|\x0a)]]) then
        RS = (matches(val, [[(\x0d\x0a|\x0d|\x0a)]]))
    else
        -- val is track file name
        local fh = io.open(val, 'rb')
        if fh then
            trackFile = val
            raf = RandomAccess.new(fh)
            local nRead, buff = raf:Read(256)
            if nRead == 0 then
                fh:close()
                return "Empty track file '" .. val .. "'"
            end
            -- look for XML or GPX header (might as well allow UTF-8 BOM)
            if isMatch(buff, [==[^(\xef\xbb\xbf)?<(\?xml|gpx)[\s>]]==]) then
                format = 'XML'
                RS = '>'    -- set input record separator to '>' for XML/GPX data
            elseif matches(buff, [[(\x0d\x0a|\x0d|\x0a)]]) then
                RS = (matches(buff, [[(\x0d\x0a|\x0d|\x0a)]]))
            else
                fh:close()
                return "Invalid track file '" .. val .. "'"
            end
            raf:Seek(0, 0)
            from = "file '" .. val .. "'"
        elseif val == 'DATETIMEONLY' then
            geotag.DateTimeOnly = 1
            geotag.IsDate = 1
            et:VPrint(0, 'Geotagging date/time only')
            return geotag
        else
            return "Error opening GPS file '" .. val .. "'"
        end
    end
    if not from then
        -- set up RAF for reading log file in memory
        raf = RandomAccess.new(val)
        from = 'data'
    end

    -- initialize cuts
    local maxHDOP = et:Options('GeoMaxHDOP')
    local maxPDOP = et:Options('GeoMaxPDOP')
    local minSats = et:Options('GeoMinSats')
    local isCut = perlTruthy(maxHDOP) or perlTruthy(maxPDOP) or perlTruthy(minSats)

    local numPoints = 0
    local skipped = 0
    local lastSecs = 0
    local fix = { }
    local csvDelim = et:Options('CSVDelim')
    if csvDelim == nil then csvDelim = ',' end
    local saveFix, saveTime, timeSpan = { }, { }, nil
    while true do
        local nRead
        nRead, line = raf:ReadLine(RS)
        if nRead == 0 then break end
        local doneFix = false
        -- determine file format
        if format == '' then
            line = subst(line, [[^\xef\xbb\xbf]], '')   -- remove leading BOM if it exists
            if matches(line, [[^(\xff\xfe|\xfe\xff)]]) then
                return "ExifTool doesn't yet read UTF16-format track logs"
            end
            -- (Perl tests each alternative inline; Lua has no assignment in an
            --  expression, so the two capturing tests are pre-computed here)
            local nmeaS = { matches(line, [[^.*\$([A-Z]{2}(RMC|GGA|GLL|ZDA)|PMGNTRK),]]) }
            local hfdte = { matches(line, [[^HFDTE(?:DATE:)?(\d{2})(\d{2})(\d{2})]]) }
            tmp = matches(line, [[^\s*\d+\s+.*\sypr\s*$]]) and splitSpace(line) or nil
            if matches(line, [==[^<(\?xml|gpx)[\s>]]==]) then -- look for XML or GPX header
                format = 'XML'
            -- check for NMEA sentence
            -- (must ONLY start with ones that have timestamps! eg. not GSA or PTNTHPR!)
            elseif #nmeaS > 0 then
                format = 'NMEA'
                nmeaStart = perlTruthy(nmeaS[2]) and nmeaS[2] or nmeaS[1] -- save type of first sentence
            elseif matches(line, [[^A(FLA|XSY|FIL)]]) then
                -- (don't set format yet because we want to read HFDTE first)
                nmeaStart = 'B'
                goto continueLine
            elseif #hfdte > 0 then
                local year = tonumber(hfdte[3]) + (tonumber(hfdte[3]) >= 70 and 1900 or 2000)
                dateFlarm = timegm(0, 0, 0, hfdte[1], num(hfdte[2]) - 1, year)
                nmeaStart = 'B'
                format = 'IGC'
                goto continueLine
            elseif nmeaStart and matches(line, [[^B]]) then
                -- parse IGC fixes without a date
                format = 'IGC'
            elseif matches(line, [[^TP,D,]]) then
                format = 'Winplus'
            elseif tmp and #tmp == 12 then
                format = 'Bramor'
            elseif ((isMatch(line, [[(?i)\b(GPS)?Date]]) and isMatch(line, [[(?i)\b(GPS)?(Date)?Time]])) or
                    matches(line, [[(?i)\bTime\(seconds\)]])) and line:find(csvDelim, 1, true) then
                line = subst(line, [[[\x0d\x0a]+$]], '')    -- chomp
                csvHeadings = Geotag.SplitCSV(line, csvDelim)
                local isColumbus = (csvHeadings[1] and csvHeadings[1] == 'INDEX') -- (Columbus GPS logger)
                format = 'CSV'
                -- convert recognized headings to our parameter names
                for ci = 1, #csvHeadings do
                    local col = csvHeadings[ci]
                    local head = col
                    local param
                    local xtra = ''
                    col = subst(col, [[^GPS ?]], '')    -- remove leading "GPS" to simplify regex patterns
                    if matches(col, [[(?i)^Time ?\(seconds\)$]]) then -- DJI
                        -- DJI CSV log files have a column "Time(seconds)" which is seconds since
                        -- the start of the flight.  The date/time is obtained from the file name.
                        param = 'runtime'
                        local d = trackFile and { matches(trackFile, [[(\d{4})-(\d{2})-(\d{2})[^\/]+(\d{2})-(\d{2})-(\d{2})[^\/]*$]]) } or { }
                        if #d > 0 then
                            trackTime = ExifTool.TimeLocal(tonumber(d[6]), tonumber(d[5]), tonumber(d[4]),
                                                           tonumber(d[3]), tonumber(d[2]) - 1, tonumber(d[1]))
                            local utc = Geotag.PrintFixTime(trackTime)
                            local tzs = ExifTool.TimeZoneString({ tonumber(d[6]), tonumber(d[5]), tonumber(d[4]),
                                                                  tonumber(d[3]), tonumber(d[2]) - 1, tonumber(d[1]) - 1900 }, trackTime)
                            et:VPrint(2, '  DJI start time:  ' .. utc .. ' (local timezone is ' .. tzs .. ')\n')
                        else
                            return 'Error getting start time from file name for DJI CSV track file'
                        end
                    elseif matches(col, [[(?i)^Date ?Time]]) then   -- ExifTool addition
                        param = 'datetime'
                    elseif matches(col, [[(?i)^Date]]) then
                        param = 'date'
                    elseif matches(col, [[(?i)^Time(?! ?\(text\))]]) then -- (ignore DJI "Time(text)" column)
                        param = 'time'
                    elseif isMatch(col, [[(?i)^(Pos)?Lat]]) then
                        param = 'lat'
                        if matches(col, [[(?i)ref$]]) then param = param .. 'ref' end
                    elseif isMatch(col, [[(?i)^(Pos)?Lon]]) then
                        param = 'lon'
                        if matches(col, [[(?i)ref$]]) then param = param .. 'ref' end
                    elseif isMatch(col, [[(?i)^(Pos)?(Alt|Height)]]) then
                        param = 'alt'
                    elseif matches(col, [[(?i)^Speed]]) then
                        param = 'speed'
                        -- (recognize units in brackets)
                        local u = matches(col, [[\((mph|km/h|m/s)\)]])
                        if u then
                            scaleSpeed = otherConv[u]
                            xtra = ' in ' .. u
                        elseif isColumbus then -- (Columbus GPS logger)
                            scaleSpeed = otherConv['km/h']
                            xtra = ' in km/h'
                        else
                            xtra = ' in knots'
                        end
                    elseif isMatch(col, [[(?i)^(Angle)?(Heading|Track|Bearing)]]) then
                        param = 'track'
                    elseif isMatch(col, [[(?i)^(Angle)?Pitch]]) or matches(col, [[(?i)^Camera ?Elevation ?Angle]]) then
                        param = 'pitch'
                    elseif isMatch(col, [[(?i)^(Angle)?Roll]]) then
                        param = 'roll'
                    elseif matches(col, [[(?i)^Img ?Dir]]) then
                        param = 'dir'
                    elseif userTag[lc(col)] then
                        param = userTag[lc(col)]
                    end
                    if param then
                        et:VPrint(2, "CSV column '" .. head .. "' is " .. param .. xtra .. '\n')
                        csvHeadings[ci] = param
                    else
                        et:VPrint(2, "CSV column '" .. head .. "' ignored\n")
                        csvHeadings[ci] = ''    -- ignore this column
                    end
                end
                goto continueLine
            elseif matches(line, [["(timelineObjects|placeVisit|activitySegment|latitudeE7)"\s*:]]) then
                -- Google Takeout JSON format
                format = 'JSON'
                sortFixes = 1   -- (fixes are not all in order for this format)
            elseif matches(line, [["(durationMinutesOffsetFromStartTime|startTime)"\s*:]]) then
                format = 'JSON' -- new Google Takeout JSON format (fixes seem to be in order)
                raf:Seek(0, 0)  -- rewind to start of file
            elseif matches(line, [[\0]]) then
                break -- (could be an image file)
            else
                -- search only first 50 lines of file for a valid fix
                skipped = skipped + 1
                if skipped > 50 then break end
                goto continueLine
            end
        end
--
-- XML format (GPX, KML, Garmin XML/TCX etc)
--
        if format == 'XML' then
            local args = { }
            local arg, tok, td
            if matches(line, [[^([^<]+<\/[^>]+>)]]) then
                -- handle simple property
                line = subst(line, [[^\s+<]], '<')  -- remove whitespace if only whitespace before "<"
                -- Workaround for KML generated by Google Location History:
                -- lat/lon/alt are space-separated; we want commas.
                line = subst(line, [[(\S+)\s+(\S+)\s+(\S+)(</gx:coord>)]], '$1,$2,$3$4')
                args[#args + 1] = line
            else
                -- handle property with attributes
                line = subst(line, [[\s*=\s*(['"])\s*]], '=$1', 'g')    -- remove unnecessary white space in attributes
                args = splitSpace(line)
            end
            for ai = 1, #args do
                arg = args[ai]
                -- parse attributes (eg. GPX 'lat' and 'lon')
                -- (note: ignore namespace prefixes if they exist)
                local isAttr, _, a2, _, a4 = isMatch(arg, [[^(\w+:)?(\w+)=(['"])(.*?)\3]])
                if isAttr then
                    local tag = xmlTag[lc(a2)]
                    if tag == nil then tag = userTag[lc(a2)] end
                    if perlTruthy(tag) then
                        fix[tag] = a4
                        if keyCategory[tag] then
                            has[keyCategory[tag]] = 1
                        elseif tag == 'alt' then
                            -- validate altitude
                            if fix.alt ~= nil and not matches(fix.alt, [[^[+-]?\d+\.?\d*]]) then fix.alt = nil end
                            if perlTruthy(fix.alt) then has.alt = 1 end -- set "has altitude" flag if appropriate
                        elseif tag == 'atemp' or tag == 'speed' or tag == 'err' then
                            has[tag] = 1
                        end
                    end
                end
                -- loop through XML elements
                for c1, c2, _, c4 in eachMatch(arg, [[([^<>]*)<(/)?(\w+:)?(\w+)(>|$)]]) do
                    tok = lc(c4)
                    local tag = xmlTag[tok]
                    if tag == nil then tag = userTag[tok] end
                    -- parse as a simple property if this element has a value
                    if tag ~= nil and not perlTruthy(tag) then
                        -- a containing property was opened or closed
                        if not perlTruthy(c2) then
                            -- opened: start a new fix
                            fix = { }
                            lastFix = fix
                            saveFix = { }
                            goto continueElem
                        elseif fix and lastFix and next(fix) then
                            -- closed: transfer additional tags from current fix
                            for k, v in pairs(fix) do
                                if lastFix[k] == nil then lastFix[k] = v end
                            end
                            lastFix = nil
                        end
                    end
                    if #c1 > 0 then
                        if perlTruthy(tag) then
                            if tag == 'coords' then
                                -- save other fixes if there are more than one
                                if fix.lon ~= nil and fix.lat ~= nil and fix.alt ~= nil then
                                    saveFix[#saveFix + 1] = { fix.lon, fix.lat, fix.alt }
                                end
                                -- read KML "Point" coordinates
                                local co = split(',', c1)
                                fix.lon, fix.lat, fix.alt = co[1], co[2], co[3]
                                if perlTruthy(fix.alt) then has.alt = 1 end
                            else
                                if tok == 'when' and perlTruthy(fix['time']) then
                                    saveTime[#saveTime + 1] = c1 -- flightaware KML stores times in array
                                else
                                    fix[tag] = c1
                                end
                                if keyCategory[tag] then
                                    has[keyCategory[tag]] = 1
                                elseif tag == 'alt' then
                                    -- validate altitude
                                    if fix.alt ~= nil and not matches(fix.alt, [[^[+-]?\d+\.?\d*]]) then fix.alt = nil end
                                    if perlTruthy(fix.alt) then has.alt = 1 end -- set "has altitude" flag if appropriate
                                elseif tag == 'atemp' or tag == 'speed' or tag == 'err' then
                                    has[tag] = 1
                                end
                            end
                        end
                        goto continueElem
                    elseif tok == 'td' then
                        td = 1
                    end
                    -- validate and store GPS fix
                    if fix.lat == nil or fix.lon == nil then goto continueElem end
                    if fix['time'] == nil then
                        if #saveTime == 0 then goto continueElem end
                        fix['time'] = table.remove(saveTime, 1) -- get next time in flightaware KML list
                    end
                    if not (matches(fix.lat, [[^[+-]?\d+\.?\d*]]) and matches(fix.lon, [[^[+-]?\d+\.?\d*]])) then
                        if not e0 then et:VPrint(0, 'Coordinate format error in ' .. from .. '\n'); e0 = 1 end
                        goto continueElem
                    end
                    time = Geotag.GetTime(fix['time'])
                    if time == nil then
                        if not e1 then et:VPrint(0, 'Timestamp format error in ' .. from .. '\n'); e1 = 1 end
                        goto continueElem
                    end
                    isDate = 1
                    if fix.pdop ~= nil or fix.hdop ~= nil or fix.nsats ~= nil then canCut = 1 end
                    -- generate extra fixes assuming an equally spaced track
                    if perlTruthy(fix.begin) then
                        local begin = Geotag.GetTime(fix.begin)
                        fix.begin = nil
                        if begin ~= nil and begin < time then
                            timeSpan = (timeSpan or 0) + 1
                            fix.span = timeSpan
                            -- duplicate the fix if there is only one so we will have
                            -- a fix and the start and end of the TimeSpan
                            if #saveFix == 0 then saveFix[#saveFix + 1] = { fix.lon, fix.lat, fix.alt } end
                            for i = 0, #saveFix - 1 do
                                local t = begin + (time - begin) * (i / #saveFix)
                                local f = { }
                                f.lon, f.lat, f.alt = saveFix[i + 1][1], saveFix[i + 1][2], saveFix[i + 1][3]
                                if i == 0 and points[t] then t = t + 0.001 end -- (avoid dupicates)
                                f.span = timeSpan
                                points[t] = f
                                fixTimes[#fixTimes + 1] = t
                            end
                        end
                    end
                    points[time] = fix
                    fixTimes[#fixTimes + 1] = time  -- save times of all fixes in order
                    fix = { }
                    saveFix = { }
                    numPoints = numPoints + 1
                    ::continueElem::
                end
            end
            -- last ditch check KML description for timestamp (assume it is UTC)
            if td and not perlTruthy(fix['time']) then
                local d1, d2 = matches(line, [[[\s>](\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2}(\.\d+)?)]])
                if d1 then fix['time'] = d1 .. 'T' .. d2 .. 'Z' end
            end
            goto continueLine
--
-- Winplus Beacon text file
--
        elseif format == 'Winplus' then
            -- TP,D, 44.933666667, -93.186555556, 10/26/2011, 19:07:28, 0
            --       latitude      longitude      date        time
            local w = { matches(line, [[^TP,D,\s*([-+]?\d+\.\d*),\s*([-+]?\d+\.\d*),\s*(\d+)\/(\d+)\/(\d{4}),\s*(\d+):(\d+):(\d+)]]) }
            if #w == 0 then goto continueLine end
            fix.lat = w[1]
            fix.lon = w[2]
            time = timegm(w[8], w[7], w[6], w[4], num(w[3]) - 1, w[5])
            doneFix = true
--
-- Bramor gEO log file
--
        elseif format == 'Bramor' then
            --   1 0015   18.723675   50.672752  149 169.31 22/04/2015 07:06:55 169.31    8.88   28.07 ypr
            --   ? index  latitude    longitude  alt track  date       time     dir       pitch  roll
            local parts = splitSpace(line)
            if not (#parts == 12 and parts[12] == 'ypr') then goto continueLine end
            local d = split('/', parts[7])  -- date (dd/mm/YYYY)
            local t = split(':', parts[8])  -- time (HH:MM:SS)
            if not (#d == 3 and #t == 3) then goto continueLine end
            fix.lat, fix.lon, fix.alt, fix.track, fix.dir, fix.pitch, fix.roll =
                parts[3], parts[4], parts[5], parts[6], parts[9], parts[10], parts[11]
            -- (add the seconds afterwards in case some models have decimal seconds)
            time = timegm(0, t[2], t[1], d[1], num(d[2]) - 1, d[3]) + num(t[3])
            -- set necessary flags for extra available information
            has.alt, has.track, has.orient = 1, 1, 1
            doneFix = true  -- save this fix
        elseif format == 'CSV' then
            line = subst(line, [[[\x0d\x0a]+$]], '')    -- chomp
            local vals = Geotag.SplitCSV(line, csvDelim)
--
-- CSV format output of GPS/IMU POS system
--   Date*           - date in DD/MM/YYYY format
--   Time*           - time in HH:MM:SS.SSS format
--   [Pos]Lat*       - latitude in decimal degrees
--   [Pos]Lon*       - longitude in decimal degrees
--   [Pos]Alt*       - altitude in m relative to sea level
--   [Angle]Heading* - GPSTrack in degrees true
--   [Angle]Pitch*   - pitch angle in degrees
--   [Angle]Roll*    - roll angle in degrees
-- (ExifTool enhancements allow for standard tag names or descriptions as the column headings,
--  add support for time zones and flexible coordinates, and allow new DateTime and Shift columns)
--
            local param, date, secs
            local neg = { }
            local vi = 1
            for hi = 1, #csvHeadings do
                param = csvHeadings[hi]
                local v = vals[vi]; vi = vi + 1
                if v == nil or #v == 0 then break end
                if param ~= '' then
                    if param == 'datetime' then
                        -- (fix formats like "24.07.2016 13:47:30")
                        v = subst(v, [[^(\d{2})[^\d](\d{2})[^\d](\d{4}) ]], '$3:$2:$1 ')
                        local oldWarn = perl.SIG.__WARN__
                        perl.SIG.__WARN__ = function() end
                        local dateTime = require('lexiftool.Writer').InverseDateTime(et, v)
                        perl.SIG.__WARN__ = oldWarn
                        if perlTruthy(dateTime) then
                            date = ExifTool.GetUnixTime(v, 2)
                            secs = 0
                        end
                    elseif param == 'date' then
                        local d = { matches(v, [[^(\d{2})/(\d{2})/(\d{4})$]]) }
                        if #d > 0 then
                            date = timegm(0, 0, 0, d[1], num(d[2]) - 1, d[3])
                        else
                            d = { matches(v, [[(\d{4}).*?(\d{2}).*?(\d{2})]]) }
                            if #d > 0 then
                                date = timegm(0, 0, 0, d[3], num(d[2]) - 1, d[1])
                            else
                                d = { matches(v, [[^(\d{2})(\d{2})(\d{2})$]]) } -- (Columbus GPS logger)
                                if #d > 0 then
                                    date = timegm(0, 0, 0, d[3], num(d[2]) - 1, num(d[1]) + 2000)
                                end
                            end
                        end
                    elseif param == 'time' then
                        local t = { matches(v, [[^(\d{1,2}):(\d{2}):(\d{2}(\.\d+)?).*?(([-+])(\d{1,2}):?(\d{2}))?]]) }
                        if #t > 0 then
                            secs = ((tonumber(t[1]) * 60) + tonumber(t[2])) * 60 + tonumber(t[3])
                            -- adjust for time zone if specified
                            if perlTruthy(t[5]) then
                                secs = secs + (tonumber(t[7]) * 60 + tonumber(t[8])) * (t[6] == '-' and 60 or -60)
                            end
                        else
                            t = { matches(v, [[^(\d{2})(\d{2})(\d{2})$]]) } -- (Columbus GPS logger)
                            if #t > 0 then
                                secs = ((tonumber(t[1]) * 60) + tonumber(t[2])) * 60 + tonumber(t[3])
                            end
                        end
                    elseif param == 'lat' or param == 'lon' then
                        fix[param] = GPS.ToDegrees(v, 1)
                    elseif param == 'latref' then
                        if matches(v, [[(?i)^S]]) then neg.lat = 1 end
                    elseif param == 'lonref' then
                        if matches(v, [[(?i)^W]]) then neg.lon = 1 end
                    elseif param == 'runtime' then
                        date = trackTime
                        secs = tonumber(v)
                    elseif matches(param, [[^_]]) then
                        fix[param] = v
                    else
                        if scaleSpeed and param == 'speed' then v = tonumber(v) / scaleSpeed end
                        fix[param] = v
                        if sepTags[param] then has[param] = 1 end
                    end
                end
            end
            -- make coordinate negative according to reference direction if necessary
            for p in pairs(neg) do
                if fix[p] ~= nil then fix[p] = -math.abs(tonumber(fix[p])) end
            end
            if perlTruthy(date) and secs ~= nil and fix.lat ~= nil and fix.lon ~= nil then
                time = date + secs
                if fix.alt ~= nil then has.alt = 1 end
                if fix.track ~= nil then has.track = 1 end
                if fix.pitch ~= nil then has.orient = 1 end
                doneFix = true
            else
                goto continueLine
            end
        elseif format == 'JSON' then
            -- Google Takeout JSON format
            local j = { matches(line,
    [==["(latitudeE7|longitudeE7|latE7|lngE7|timestamp|startTime|point|durationMinutesOffsetFromStartTime|time)"\s*:\s*"?(.*?)"?,?\s*[\x0d\x0a]]==]) }
            if #j > 0 then
                if j[1] == 'timestamp' or j[1] == 'time' then
                    time = Geotag.GetTime(j[2])
                    if perlTruthy(time) and perlTruthy(fix.lat) and perlTruthy(fix.lon) then doneFix = true end
                elseif j[1] == 'startTime' then -- (new format)
                    startTime = Geotag.GetTime(j[2])
                elseif j[1] == 'latitudeE7' or j[1] == 'latE7' then
                    fix.lat = num(j[2]) * 1e-7
                elseif j[1] == 'longitudeE7' or j[1] == 'lngE7' then
                    fix.lon = num(j[2]) * 1e-7
                elseif j[1] == 'point' then -- (new format)
                    local point = j[2]
                    local coords = findAll(point, [[[-+]?\d+\.\d+]])
                    if #coords == 2 then fix.lat, fix.lon = coords[1], coords[2] end
                elseif j[1] == 'durationMinutesOffsetFromStartTime' and startTime ~= nil then -- (new format)
                    time = startTime + num(j[2]) * 60
                    -- note: this assumes that "point" comes first, which it does in my sample
                    if perlTruthy(time) and perlTruthy(fix.lat) and perlTruthy(fix.lon) then doneFix = true end
                end
            end
            if not doneFix then goto continueLine end
        end
        if doneFix then
            -- DoneFix:
            isDate = 1
            points[time] = fix
            fixTimes[#fixTimes + 1] = time
            fix = { }
            numPoints = numPoints + 1
            goto continueLine
        end
        do
        local fixHash, secs, date, nm = { }, nil, nil, nil
        if format == 'NMEA' then
            -- ignore unrecognized NMEA sentences
            -- (first 2 characters: GP=GPS, GL=GLONASS, GA=Gallileo, GN=combined, BD=Beidou)
            local n = { matches(line, [[^(.*)\$([A-Z]{2}(RMC|GGA|GLL|GSA|ZDA)|PMGNTRK|PTNTHPR),]]) }
            if #n == 0 then goto continueLine end
            nm = perlTruthy(n[3]) and n[3] or n[2]
            if #n[1] > 0 then line = substr(line, #n[1]) end
        end
--
-- IGC (flarm) (ref 4)
--
        if format == 'IGC' then
            -- B0939564531208N00557021EA007670089100207
            -- BHHMMSSDDMMmmmNDDDMMmmmEAaaaaaAAAAAxxyy
            --    HH     MM     SS     DD     MM     mmm          DDD    MM     mmm                aaaaa AAAAA
            --    1      2      3      4      5      6      7     8      9      10     11    12    13    14
            local b = { matches(line, [[^B(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{3})([NS])(\d{3})(\d{2})(\d{3})([EW])([AV])(\d{5})(\d{5})]]) }
            if #b == 0 then goto continueLine end
            fixHash.lat = (tonumber(b[4]) + (tonumber(b[5]) + tonumber(b[6]) / 1000) / 60) * (b[7] == 'N' and 1 or -1)
            fixHash.lon = (tonumber(b[8]) + (tonumber(b[9]) + tonumber(b[10]) / 1000) / 60) * (b[11] == 'E' and 1 or -1)
            fixHash.alt = b[12] == 'A' and b[14] or nil
            secs = ((tonumber(b[1]) * 60) + tonumber(b[2])) * 60 + tonumber(b[3])
            -- wrap to next day if necessary
            if perlTruthy(dateFlarm) then
                if secs < (lastSecs or 0) - JITTER() then dateFlarm = dateFlarm + secPerDay end
                date = dateFlarm
            end
            nm = 'B'
--
-- NMEA RMC sentence (contains date)
--
        elseif nm == 'RMC' then
            --  $GPRMC,092204.999,A,4250.5589,S,14718.5084,E,0.00,89.68,211200,,*25
            --  $GPRMC,093657.007,,3652.835020,N,01053.104094,E,1.642,,290913,,,A*0F
            --  $GPRMC,hhmmss.sss,A/V,ddmm.mmmm,N/S,dddmm.mmmm,E/W,spd(knots),dir(deg),DDMMYY,,*cs
            local r = { matches(line,
    [[^\$[A-Z]{2}RMC,(\d{2})(\d{2})(\d+(\.\d*)?),A?,(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]]) }
            if #r == 0 then goto continueLine end
            if tonumber(r[13]) > 31 or tonumber(r[14]) > 12 or tonumber(r[15]) > 99 then goto continueLine end -- validate day/month/year
            fixHash.lat = ((tonumber(r[5]) or 0) + tonumber(r[6]) / 60) * (r[7] == 'N' and 1 or -1)
            fixHash.lon = ((tonumber(r[8]) or 0) + tonumber(r[9]) / 60) * (r[10] == 'E' and 1 or -1)
            if #r[11] > 0 then fixHash.speed = r[11] end
            if #r[12] > 0 then fixHash.track = r[12] end
            local year = tonumber(r[15]) + (tonumber(r[15]) >= 70 and 1900 or 2000)
            secs = ((tonumber(r[1]) * 60) + tonumber(r[2])) * 60 + tonumber(r[3])
            date = timegm(0, 0, 0, r[13], num(r[14]) - 1, year)
--
-- NMEA GGA sentence (no date)
--
        elseif nm == 'GGA' then
            --  $GPGGA,092204.999,4250.5589,S,14718.5084,E,1,04,24.4,19.7,M,,,,0000*1F
            --  $GPGGA,093657.000,3652.835020,N,01053.104094,E,,8,,166.924,M,40.9,M,,*77
            --  $GPGGA,hhmmss.sss,ddmm.mmmm,N/S,dddmm.mmmm,E/W,0=invalid,sats,hdop,alt,M,...
            local g = { matches(line,
    [[^\$[A-Z]{2}GGA,(\d{2})(\d{2})(\d+(\.\d*)?),(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),[1-6]?,(\d+)?,(\.\d+|\d+\.?\d*)?,(-?\d+\.?\d*)?,M?]]) }
            if #g == 0 then goto continueLine end
            fixHash.lat = ((tonumber(g[5]) or 0) + tonumber(g[6]) / 60) * (g[7] == 'N' and 1 or -1)
            fixHash.lon = ((tonumber(g[8]) or 0) + tonumber(g[9]) / 60) * (g[10] == 'E' and 1 or -1)
            fixHash.nsats, fixHash.hdop, fixHash.alt = g[11] or nil, g[12] or nil, g[13] or nil
            secs = ((tonumber(g[1]) * 60) + tonumber(g[2])) * 60 + tonumber(g[3])
            canCut = 1
--
-- NMEA GLL sentence (no date)
--
        elseif nm == 'GLL' then
            --  $GPGLL,4250.5589,S,14718.5084,E,092204.999,A*2D
            --  $GPGLL,ddmm.mmmm,N/S,dddmm.mmmm,E/W,hhmmss.sss,A/V*cs
            local g = { matches(line, [[^\$[A-Z]{2}GLL,(\d*?)(\d{1,2}\.\d+),([NS]),(\d*?)(\d{1,2}\.\d+),([EW]),(\d{2})(\d{2})(\d+(\.\d*)?),A]]) }
            if #g == 0 then goto continueLine end
            fixHash.lat = ((tonumber(g[1]) or 0) + tonumber(g[2]) / 60) * (g[3] == 'N' and 1 or -1)
            fixHash.lon = ((tonumber(g[4]) or 0) + tonumber(g[5]) / 60) * (g[6] == 'E' and 1 or -1)
            secs = ((tonumber(g[7]) * 60) + tonumber(g[8])) * 60 + tonumber(g[9])
--
-- NMEA GSA sentence (satellite status, no date)
--
        elseif nm == 'GSA' then
            -- $GPGSA,A,3,04,05,,,,,,,,,,,pdop,hdop,vdop*HH
            local g = { matches(line, [[^\$[A-Z]{2}GSA,[AM],([23]),((?:\d*,){11}(?:\d*)),(\d+\.?\d*|\.\d+)?,(\d+\.?\d*|\.\d+)?,(\d+\.?\d*|\.\d+)?\*]]) }
            if #g == 0 then goto continueLine end
            fixHash.fixtype, fixHash.sats, fixHash.pdop, fixHash.hdop, fixHash.vdop =
                g[1] .. 'd', g[2], g[3] or nil, g[4] or nil, g[5] or nil
            -- count the number of acquired satellites
            local a = findAll(fixHash.sats, [[\d+]])
            fixHash.nsats = #a
            canCut = 1
--
-- NMEA ZDA sentence (date/time, contains date)
--
        elseif nm == 'ZDA' then
            --  $GPZDA,093655.000,29,09,2013,,*58
            --  $GPZDA,hhmmss.ss,DD,MM,YYYY,tzh,tzm (hhmmss in UTC)
            local z = { matches(line, [[^\$[A-Z]{2}ZDA,(\d{2})(\d{2})(\d{2}(\.\d*)?),(\d+),(\d+),(\d+)]]) }
            if #z == 0 then goto continueLine end
            secs = ((tonumber(z[1]) * 60) + tonumber(z[2])) * 60 + tonumber(z[3])
            date = timegm(0, 0, 0, z[5], num(z[6]) - 1, z[7])
--
-- Magellan eXplorist PMGNTRK (Proprietary MaGellaN TRacK) sentence (optional date)
--
        elseif nm == 'PMGNTRK' then
            -- $PMGNTRK,4415.026,N,07631.091,W,00092,M,185031.06,A,,020409*65
            -- $PMGNTRK,ddmm.mmm,N/S,dddmm.mmm,E/W,alt,F/M,hhmmss.ss,A/V,trkname,DDMMYY*cs
            local p = { matches(line,
    [[^\$PMGNTRK,(\d+)(\d{2}\.\d+),([NS]),(\d+)(\d{2}\.\d+),([EW]),(-?\d+\.?\d*),([MF]),(\d{2})(\d{2})(\d+(\.\d*)?),A,(?:[^,]*,(\d{2})(\d{2})(\d+))?]]) }
            if #p == 0 then goto continueLine end
            fixHash.lat = (tonumber(p[1]) + tonumber(p[2]) / 60) * (p[3] == 'N' and 1 or -1)
            fixHash.lon = (tonumber(p[4]) + tonumber(p[5]) / 60) * (p[6] == 'E' and 1 or -1)
            fixHash.alt = p[8] == 'M' and p[7] or tonumber(p[7]) * 12 * 0.0254
            secs = ((tonumber(p[9]) * 60) + tonumber(p[10])) * 60 + tonumber(p[11])
            if p[15] then
                if tonumber(p[13]) > 31 or tonumber(p[14]) > 12 or tonumber(p[15]) > 99 then goto continueLine end -- validate day/month/year
                -- optional date is available in PMGNTRK sentence
                local year = tonumber(p[15]) + (tonumber(p[15]) >= 70 and 1900 or 2000)
                date = timegm(0, 0, 0, p[13], num(p[14]) - 1, year)
            end
--
-- Honeywell HMR3000 PTNTHPR (Heading Pitch Roll) sentence (no date)
-- (ref http://www.gpsarea.com/uploadfile/download/introduce/hmr3000_manual.pdf)
--
        elseif nm == 'PTNTHPR' then
            -- $PTNTHPR,85.9,N,-0.9,N,0.8,N*HH
            -- $PTNTHPR,heading,heading status,pitch,pitch status,roll,roll status,*cs
            -- status: L=low alarm, M=low warning, N=normal, O=high warning
            --         P=high alarm, C=tuning analog circuit
            -- (ignore this information on any alarm status)
            local h = { matches(line, [==[^\$PTNTHPR,(-?[\d.]+),[MNO],(-?[\d.]+),[MNO],(-?[\d.]+),[MNO]]==]) }
            if #h == 0 then goto continueLine end
            fixHash.dir, fixHash.pitch, fixHash.roll = h[1], h[2], h[3]

        else
            goto continueLine   -- this shouldn't happen
        end
        -- remember the NMEA formats we successfully read
        nmea[nm] = 1
        -- use last date if necessary (and appropriate)
        if secs ~= nil and date == nil and lastDate ~= nil then
            -- wrap to next day if necessary
            if secs < lastSecs - JITTER() then
                lastSecs = lastSecs - secPerDay
                lastDate = lastDate + secPerDay
            end
            -- use earlier date only if we are within 10 seconds
            if secs - lastSecs < 10 then
                -- last date is close, use it for this fix
                date = lastDate
            else
                -- last date is old, discard it
                lastDate = nil
                lastSecs = nil
            end
        end
        -- save our last date/time
        if date ~= nil then
            lastDate = date
            lastSecs = secs
        end
--
-- Add NMEA/IGC fix to our lookup
-- (this is much more complicated than it needs to be because
--  the stupid NMEA format provides no end-of-fix indication)
--
        -- assumptions for each NMEA sentence:
        -- - we only parse a time if we get a lat/lon
        -- - we always get a time if we have a date
        if nm == nmeaStart or (secs ~= nil and (fixSecs == nil or
            -- don't combine sentences that are outside 10 seconds apart
            (secs >= fixSecs and secs - fixSecs >= 10) or
            (secs <  fixSecs and secs + secPerDay - fixSecs >= 10))) then
            -- start a new fix
            fix = fixHash
            fixSecs = secs
            noDateChanged = nil
            -- does this fix have a date/time or time stamp?
            if date ~= nil then
                fixHash.isDate = 1; isDate = 1
                time = date + secs
            elseif secs ~= nil then
                time = secs
                noDate = 1; noDateChanged = 1
            else
                goto continueLine   -- wait until we have a time before adding to lookup
            end
        else
            -- add new data to existing fix (but don't overwrite earlier values to
            -- keep the coordinates in sync with the fix time)
            for k, v in pairs(fixHash) do
                if fix[k] == nil then fix[k] = v end
            end
            if date ~= nil then
                if perlTruthy(fix.isDate) then goto continueLine end
                -- move this fix to the proper date
                if fixSecs ~= nil then
                    points[fixSecs] = nil
                    if #fixTimes > 0 and fixTimes[#fixTimes] == fixSecs then fixTimes[#fixTimes] = nil end
                    numPoints = numPoints - 1
                    -- if we wrapped to the next day since the start of this fix,
                    -- we must shift the date back to the day of fixSecs
                    if secs < fixSecs then date = date - secPerDay end
                else
                    fixSecs = secs
                end
                time = date + fixSecs
                fix.isDate = 1; isDate = 1
                -- revert noDate flag if it was set for this fix
                if noDateChanged then noDate = 0 end
            elseif secs ~= nil and fixSecs == nil then
                fixSecs = secs; time = secs
                noDate = 1; noDateChanged = 1
            else
                goto continueLine   -- wait until we have a time
            end
        end
        -- add fix to our lookup
        points[time] = fix
        fixTimes[#fixTimes + 1] = time  -- save time of all fixes in order
        numPoints = numPoints + 1
        end
        ::continueLine::
    end
--
-- If the file wasn't a recognized track log, it could be one of the file types
-- supported for reading metadata, so try to extract GPS tags from it
--
    if format == '' then
        raf:Seek(0, 0)
        -- load track from metadata in file
        local et2 = ExifTool.new()
        local requestTags = { }
        for k in pairs(tagKey) do requestTags[#requestTags + 1] = k end
        et2:Options(
            'Sort', 'File',
            'IgnoreTags', 'All',
            'RequestTags', table.concat(requestTags, ','),
            'PrintConv', 0,
            'KeepUTCTime', 1,
            'ExtractEmbedded', 3,
            'QuickTimeUTC', et:Options('QuickTimeUTC')
        )
        if not perlTruthy(et2:ExtractInfo(raf)) then
            raf:Close()
            return "Unrecognized file format '" .. val .. "'"
        end
        local tags = et2:GetTagList()
        local tag, fx, tm, name
        local lastGrp, lastTag = '', ''
        if #tags > 0 then
            tags[#tags + 1] = tags[#tags]   -- duplicate last tag to act as an end marker
            isDate = 1
            sortFixes = 1   -- (fixes may not be in order)
        end
        fx = { }
        for ti = 1, #tags do
            tag = tags[ti]
            local grp = et2:GetGroup(tag, 3)
            if grp ~= lastGrp or tag == lastTag then
                -- add fix to our lookup
                if perlTruthy(tm) and perlTruthy(fx.lat) and perlTruthy(fx.lon) then
                    if points[tm] then
                        -- could possibly happen if time jumps around
                        for k, v in pairs(fx) do points[tm][k] = v end
                    else
                        points[tm] = fx
                        -- convert speed to knots
                        if perlTruthy(fx.speed) then fx.speed = tonumber(fx.speed) / speedConv['K'] end
                        fixTimes[#fixTimes + 1] = tm    -- save time of all fixes in order
                        numPoints = numPoints + 1
                    end
                end
                lastGrp = grp
                tm = nil
                fx = { }
            end
            lastTag = tag
            name = subst(tag, ' .*', '')
            local key = tagKey[name]
            if not perlTruthy(key) then
                if key == nil then et:Warn('Internal error with tag name ' .. perlStr(key) .. ' ' .. name .. ' (' .. tag .. ')') end
            else
                local v = et2:GetValue(tag)
                if key == 'time' then
                    if not perlTruthy(tm) then tm = ExifTool.GetUnixTime(v) end
                elseif fx[key] == nil then
                    fx[key] = v
                    if keyCategory[key] then has[keyCategory[key]] = 1 end
                end
            end
        end
    end
    raf:Close()

    -- set date flags
    if perlTruthy(noDate) and not perlTruthy(geotag.NoDate) then
        if perlTruthy(isDate) then
            et:Warn('Fixes are date-less -- will use time-only interpolation')
        else
            et:Warn('Some fixes are date-less -- may use time-only interpolation')
        end
        geotag.NoDate = 1
    end
    if perlTruthy(isDate) then geotag.IsDate = 1 end

    -- cut bad fixes if necessary
    if isCut and perlTruthy(canCut) then
        cutPDOP, cutHDOP, cutSats = 0, 0, 0
        local goodTimes = { }
        for _, t in ipairs(fixTimes) do
            local f = points[t]
            if f then
                if perlTruthy(maxPDOP) and perlTruthy(f.pdop) and num(f.pdop) > num(maxPDOP) then
                    points[t] = nil
                    cutPDOP = cutPDOP + 1
                elseif perlTruthy(maxHDOP) and perlTruthy(f.hdop) and num(f.hdop) > num(maxHDOP) then
                    points[t] = nil
                    cutHDOP = cutHDOP + 1
                elseif perlTruthy(minSats) and f.nsats ~= nil and f.nsats ~= '' and
                    num(f.nsats) < num(minSats) then
                    points[t] = nil
                    cutSats = cutSats + 1
                else
                    goodTimes[#goodTimes + 1] = t
                end
            end
        end
        fixTimes = goodTimes    -- update fix times
        numPoints = numPoints - cutPDOP
        numPoints = numPoints - cutHDOP
        numPoints = numPoints - cutSats
    end
    -- sort fixes if necessary
    if sortFixes then tsort(fixTimes, function(a, b) return a < b end) end
    -- mark first fix of the track
    while #fixTimes > 0 do
        local f = points[fixTimes[1]]
        if not f then
            table.remove(fixTimes, 1)
        else
            f.first = 1
            break
        end
    end
    local verbose = et:Options('Verbose')
    if perlTruthy(verbose) then
        local out = et:Options('TextOut') or io.stdout
        if format == '' then format = 'unknown' end
        out:write('Loaded ' .. numPoints .. ' points from ' .. format .. '-format GPS track log ' .. from .. '\n')
        if perlTruthy(cutPDOP) then out:write('Ignored ' .. cutPDOP .. ' points due to GeoMaxPDOP cut\n') end
        if perlTruthy(cutHDOP) then out:write('Ignored ' .. cutHDOP .. ' points due to GeoMaxHDOP cut\n') end
        if perlTruthy(cutSats) then out:write('Ignored ' .. cutSats .. ' points due to GeoMinSats cut\n') end
        if numPoints ~= 0 and num(verbose) > 1 then
            local lbl = { 'start:', 'end:  ' }
            -- (fixes may be in reverse order in GPX files)
            if fixTimes[1] > fixTimes[#fixTimes] then lbl = { lbl[2], lbl[1] } end
            out:write('  GPS track ' .. lbl[1] .. ' ' .. Geotag.PrintFixTime(fixTimes[1]) .. '\n')
            if num(verbose) > 3 then
                for _, t in ipairs(fixTimes) do out:write(Geotag.PrintFix(points, t)) end
            end
            out:write('  GPS track ' .. lbl[2] .. ' ' .. Geotag.PrintFixTime(fixTimes[#fixTimes]) .. '\n')
        end
    end
    if numPoints ~= 0 then
        -- reset timestamp list to force it to be regenerated
        geotag.Times = nil
        -- set flags for available information
        if nmea.GGA or nmea.PMGNTRK or nmea.B then has.alt = 1 end  -- alt
        if nmea.RMC then has.track = 1 end                          -- track, speed
        if nmea.PTNTHPR then has.orient = 1 end                     -- dir, pitch, roll
        return geotag       -- success!
    end
    return 'No track points found in GPS ' .. from
end


--------------------------------------------------------------------------------
-- Get floating point UTC time
-- Inputs: 0) XML time string
-- Returns: floating point time or undef on error
function Geotag.GetTime(timeStr)
    local m = { matches(timeStr, [[^(\d{4})-(\d+)-(\d+)T(\d+):(\d+):(\d+)(\.\d+)?(.*)]]) }
    if #m == 0 then return nil end
    local time = timegm(m[6], m[5], m[4], m[3], num(m[2]) - 1, m[1])
    if perlTruthy(m[7]) then time = time + tonumber(m[7]) end   -- add fractional seconds
    local tz = m[8]
    -- adjust for time zone (otherwise assume UTC)
    -- - allow timezone of +-HH:MM, +-H:MM, +-HHMM or +-HH since
    --   the spec is unclear about timezone format
    local z = { matches(tz, [[^([-+])(\d+):(\d{2})\b]]) }
    if #z == 0 then z = { matches(tz, [[^([-+])(\d{2})(\d{2})?\b]]) } end
    if #z > 0 then
        local off = (tonumber(z[2]) * 60 + (tonumber(z[3]) or 0)) * 60
        if z[1] == '+' then off = off * -1 end  -- opposite sign to change back to UTC
        time = time + off
    end
    return time
end

--------------------------------------------------------------------------------
-- Apply Geosync time correction
-- Inputs: 0) ExifTool ref, 1) Unix UTC time value
-- Returns: sync time difference (and the corrected time), or undef if no sync
function Geotag.ApplySyncCorr(et, time)
    local sync = et:GetNewValue('Geosync')
    if type(sync) == 'table' then
        local syncTimes = sync.Times
        if syncTimes then
            -- find the nearest 2 sync points
            local i0, i1 = 0, #syncTimes - 1
            while i1 > i0 + 1 do
                local pt = int((i0 + i1) / 2)
                if time < syncTimes[pt + 1] then i1 = pt else i0 = pt end
            end
            local t0, t1 = syncTimes[i0 + 1], syncTimes[i1 + 1]
            -- interpolate/extrapolate to account for linear camera clock drift
            local syncPoints = sync.Points
            local f = (t1 == t0) and 0 or ((time - t0) / (t1 - t0))
            sync = syncPoints[t1] * f + syncPoints[t0] * (1 - f)
        else
            sync = sync.Offset  -- use fixed time offset
        end
        return sync, time + sync
    end
    return nil, time
end

--------------------------------------------------------------------------------
-- Scan outwards for a fix containing the requested parameter
-- Inputs: 0) name of fix parameter, 1) reference to list of fix times,
--         2) reference to fix points hash, 3) index of starting time,
--         4) direction to scan (-1 or +1), 5) maximum time difference
-- Returns: 0) time for fix containing requested information (or undef)
--          1) the corresponding fix, 2) the value of the requested fix parameter
function Geotag.ScanOutwards(key, times, points, i, dir, maxSecs)
    local t0 = times[i + 1]
    while true do
        i = i + dir
        if i < 0 or i >= #times then break end
        local t = times[i + 1]
        if math.abs(t - t0) > num(maxSecs) then break end    -- don't look too far
        local p = points[t]
        local v = p[key]
        if v ~= nil then return t, p, v end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Find nearest fix containing the specified parameter
-- Inputs: 0) ExifTool ref, 1) name of fix parameter, 2) reference to list of fix times,
--         3) reference to fix points hash, 4) index of starting time,
--         5) direction to scan (-1, +1 or undef), 6) maximum time difference
-- Returns: reference to fix hash or undef
function Geotag.FindFix(et, key, times, points, i, dir, maxSecs)
    local t, p
    if dir then
        t, p = Geotag.ScanOutwards(key, times, points, i, dir, maxSecs)
    else
        local t1, p1 = Geotag.ScanOutwards(key, times, points, i, -1, maxSecs)
        local t2, p2 = Geotag.ScanOutwards(key, times, points, i, 1, maxSecs)
        if t1 ~= nil then
            if t2 ~= nil then
                -- both surrounding points are valid, so take the closest one
                -- ($t is still undef at this point in the Perl, i.e. 0, so the
                --  comparison is really `-$t1 < $t2`; kept as upstream has it)
                if -t1 < t2 then t, p = t1, p1 else t, p = t2, p2 end
            else
                t, p = t1, p1
            end
        elseif t2 ~= nil then
            t, p = t2, p2
        end
    end
    if p ~= nil and num(et.OPTIONS.Verbose) > 2 then
        et:VPrint(2, '  Taking ' .. key .. ' from fix:\n', Geotag.PrintFix(points, t))
    end
    return p
end

--------------------------------------------------------------------------------
-- Set new geotagging values according to date/time
-- Inputs: 0) ExifTool object ref, 1) date/time value (or undef to delete tags)
--         2) optional write group
-- Returns: error string, or '' on success
-- Notes: Uses track data stored in ExifTool NEW_VALUE for Geotag tag
function Geotag.SetGeoValues(et, val, writeGroup)
    local geotag = et:GetNewValue('Geotag')
    local verbose = et:Options('Verbose')
    local fix, time, fsec, noDate, secondTry, iExt, iDir

    -- remove date if none of our fixes had date information
    if perlTruthy(val) and geotag and not perlTruthy(geotag.IsDate) then val = subst(val, [[^\S+\s+]], '') end

    -- maximum time (sec) from nearest GPS fix when position is still considered valid
    local geoMaxIntSecs = et:Options('GeoMaxIntSecs')
    local geoMaxExtSecs = et:Options('GeoMaxExtSecs')

    -- use 30 minutes for a default
    if geoMaxIntSecs == nil then geoMaxIntSecs = 1800 end
    if geoMaxExtSecs == nil then geoMaxExtSecs = 1800 end

    -- (reading `$$geotag{Times}` autovivifies an undefined $geotag into an
    --  empty hash, so the 'No GPS track loaded' test below never fires
    --  upstream and a missing track reports 'GPS track is empty')
    if geotag == nil then geotag = { } end
    local times = geotag.Times
    local points = geotag.Points
    local has = geotag.Has
    local err = ''
    -- loop to try date/time value first, then time-only value
    while val ~= nil do
        if geotag == nil then
            err = 'No GPS track loaded'
            break
        end
        if not times then
            -- generate sorted timestamp list for binary search
            local t = { }
            for k in pairs(points or { }) do t[#t + 1] = k end    -- (keys %$points of undef: none)
            tsort(t, function(a, b) return a < b end)
            times = t
            geotag.Times = t
        end
        if not ((times and #times > 0) or perlTruthy(geotag.DateTimeOnly)) then
            err = 'GPS track is empty'
            break
        end
        -- convert date/time to UTC
        local year, mon, day, hr, min, sec, fs, tz, t0, t1, t2
        local d = { matches(val, [[^(\d{4}):(\d+):(\d+)\s+(\d+):(\d+):(\d+)(\.\d*)?(Z|([-+])(\d+):(\d+))?]]) }
        if #d > 0 then
            -- valid date/time value
            year, mon, day, hr, min, sec, fs, tz, t0, t1, t2 =
                d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11]
        else
            d = { matches(val, [[^(\d{2}):(\d+):(\d+)(\.\d*)?(Z|([-+])(\d+):(\d+))?]]) }
            if #d > 0 then
                -- valid time-only value
                hr, min, sec, fs, tz, t0, t1, t2 = d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8]
                -- use Jan. 2 to avoid going negative after tz adjustment
                year, mon, day = 1970, 1, 2
                noDate = 1
            else
                err = 'Invalid date/time (use YYYY:mm:dd HH:MM:SS[.ss][+/-HH:MM|Z])'
                break
            end
        end
        if perlTruthy(tz) then
            time = timegm(sec, min, hr, day, num(mon) - 1, year)
            -- use timezone from date/time value
            if tz ~= 'Z' then
                local tzmin = tonumber(t1) * 60 + tonumber(t2)
                time = time - (t0 == '-' and -tzmin or tzmin) * 60
            end
        else
            -- assume local timezone
            time = ExifTool.TimeLocal(sec, min, hr, day, num(mon) - 1, year)
        end
        -- (the date/time fields as numbers from here on; Perl numifies the
        --  captured strings where they are used)
        year, mon, day = tonumber(year), tonumber(mon), tonumber(day)
        hr, min, sec = tonumber(hr), tonumber(min), tonumber(sec)
        -- add fractional seconds
        if perlTruthy(fs) and fs ~= '.' then time = time + tonumber(fs) end

        -- bring UTC time back to Jan. 1 if no date is given
        -- (don't use '%' operator here because it drops fractional seconds)
        if noDate then time = time - int(time / secPerDay) * secPerDay end

        -- apply time synchronization if available
        local sync
        sync, time = Geotag.ApplySyncCorr(et, time)

        -- save fractional seconds string
        fsec = matches(ExifTool.NumStr(time), [[(\.\d+)$]]) or ''

        if num(verbose) > 1 and not secondTry then
            local out = et:Options('TextOut') or io.stdout
            local str = ''
            if sync ~= nil then str = str .. sprintf(' (incl. Geosync offset of %+.3f sec)', sync) end
            if not perlTruthy(tz) then
                local tzs = ExifTool.TimeZoneString({ sec, min, hr, day, mon - 1, year - 1900 }, time)
                str = str .. ' (local timezone is ' .. tzs .. ')'
            end
            out:write('  Geotime value:   ' .. Geotag.PrintFixTime(time) .. str .. '\n')
        end
        if not times or #times == 0 then
            fix = { }   -- dummy fix to geotag date/time only
        -- interpolate GPS track at time
        elseif time < times[1] then
            if time < times[1] - num(geoMaxExtSecs) then
                if not perlTruthy(err) then err = 'Time is too far before track' end
                if num(verbose) > 2 then et:VPrint(2, '  Track start:     ', Geotag.PrintFixTime(times[1]), '\n') end
                if perlTruthy(geotag.DateTimeOnly) then fix = { } end
            else
                fix = points[times[1]]
                iExt = 0; iDir = 1
                if num(verbose) > 2 then
                    et:VPrint(2, '  Taking pos from fix:\n', Geotag.PrintFix(points, times[1]))
                end
            end
        elseif time > times[#times] then
            if time > times[#times] + num(geoMaxExtSecs) then
                if not perlTruthy(err) then err = 'Time is too far beyond track' end
                if num(verbose) > 2 then et:VPrint(2, '  Track end:       ', Geotag.PrintFixTime(times[#times]), '\n') end
                if perlTruthy(geotag.DateTimeOnly) then fix = { } end
            else
                fix = points[times[#times]]
                iExt = #times - 1; iDir = -1
                if num(verbose) > 2 then
                    et:VPrint(2, '  Taking pos from fix:\n', Geotag.PrintFix(points, times[#times]))
                end
            end
        else
            -- find nearest 2 points in time
            local i0, i1 = 0, #times - 1
            while i1 > i0 + 1 do
                local pt = int((i0 + i1) / 2)
                if time < times[pt + 1] then i1 = pt else i0 = pt end
            end
            -- do linear interpolation for position
            local tt0 = times[i0 + 1]
            local tt1 = times[i1 + 1]
            local p1 = points[tt1]
            -- check to see if we are extrapolating before the first entry in a track
            local maxSecs = (perlTruthy(p1.first) and perlTruthy(geoMaxIntSecs)) and geoMaxExtSecs or geoMaxIntSecs
            local tn -- find time of nearest fix
            if time - tt0 < tt1 - time then
                tn = tt0
                iExt = i0
            else
                tn = tt1
                iExt = i1
            end
            -- don't interpolate if fixes are too far apart
            -- (but always interpolate fixes inside the same TimeSpan)
            if tt1 - tt0 > num(maxSecs) and (not perlTruthy(p1.span) or not perlTruthy(points[tt0].span) or
                p1.span ~= points[tt0].span) then
                -- treat as an extrapolation -- use nearest fix if close enough
                if math.abs(time - tn) > num(geoMaxExtSecs) then
                    if not perlTruthy(err) then err = 'Time is too far from nearest GPS fix' end
                    if num(verbose) > 2 then
                        et:VPrint(2, '  Nearest fix:     ', Geotag.PrintFixTime(tn), ' (',
                                  ExifTool.NumStr(int(math.abs(time - tn))), ' sec away)\n')
                    end
                    if perlTruthy(geotag.DateTimeOnly) then fix = { } end
                else
                    fix = points[tn]
                    if num(verbose) > 2 then
                        et:VPrint(2, '  Taking pos from fix:\n', Geotag.PrintFix(points, tn))
                    end
                end
            else
                local f0 = (tt1 == tt0) and 0 or ((time - tt0) / (tt1 - tt0))
                local p0 = points[tt0]
                if num(verbose) > 2 then
                    et:VPrint(2, '  Interpolating between fixes (f=' .. ExifTool.NumStr(f0) .. '):\n',
                              Geotag.PrintFix(points, tt0, tt1))
                end
                fix = { }
                -- copy user-defined tags from nearest fix
                for _, u in pairs(userTag) do fix[u] = points[tn][u] end
                -- loop through available fix information categories
                -- (pos, track, alt, orient)
                for _, category in ipairs({ 'pos', 'track', 'alt', 'orient', 'atemp', 'err', 'dop' }) do
                    if has[category] then
                        local f, p0b, p1b, f0b
                        -- loop through specific fix information keys
                        -- (lat, lon, alt, track, speed, dir, pitch, roll)
                        for _, key in ipairs(fixInfoKeys[category]) do
                            local v0 = p0[key]
                            local v1 = p1[key]
                            if v0 ~= nil and v1 ~= nil then
                                f = f0
                            elseif f0b ~= nil then
                                v0 = p0b[key]
                                v1 = p1b[key]
                                if v0 == nil or v1 == nil then goto nextKey end
                                f = f0b
                            else
                                if sepTags[key] then goto nextKey end -- (don't scan outwards for some formats, eg. CSV)
                                -- scan outwards looking for fixes with the required information
                                -- (NOTE: SHOULD EVENTUALLY DO THIS FOR EXTRAPOLATION TOO!)
                                local t0b, t1b
                                if v0 ~= nil then
                                    t0b = tt0; p0b = p0
                                else
                                    t0b, p0b, v0 = Geotag.ScanOutwards(key, times, points, i0, -1, maxSecs)
                                    if t0b == nil then goto nextCategory end
                                end
                                if v1 ~= nil then
                                    t1b = tt1; p1b = p1
                                else
                                    t1b, p1b, v1 = Geotag.ScanOutwards(key, times, points, i1, 1, maxSecs)
                                    if t1b == nil then goto nextCategory end
                                end
                                -- re-calculate the interpolation factor
                                f0b = (t1b == t0b) and 0 or ((time - t0b) / (t1b - t0b))
                                f = f0b
                                if num(verbose) > 2 then
                                    et:VPrint(2, '  Interpolating ' .. category .. ' between fixes (f=' .. ExifTool.NumStr(f) .. '):\n',
                                              Geotag.PrintFix(points, t0b, t1b))
                                end
                            end
                            v0, v1 = tonumber(v0), tonumber(v1)
                            -- must interpolate cyclical values differently
                            if cyclical[key] and math.abs(v1 - v0) > 180 then
                                -- the acute angle spans the discontinuity, so add
                                -- 360 degrees to the smaller angle before interpolating
                                if v0 < v1 then v0 = v0 + 360 else v1 = v1 + 360 end
                                fix[key] = v1 * f + v0 * (1 - f)
                                -- some ranges are -180 to 180, others are 0 to 360
                                local max = cyc180[key] and 180 or 360
                                if fix[key] >= max then fix[key] = fix[key] - 360 end
                            else
                                -- simple linear interpolation
                                fix[key] = v1 * f + v0 * (1 - f)
                            end
                            ::nextKey::
                        end
                    end
                    ::nextCategory::
                end
            end
        end
        if fix then
            err = ''    -- success!
        elseif perlTruthy(geotag.NoDate) and not noDate and matches(val, [[^\S+\s+]]) then
            -- try again with no date since some of our track points are date-less
            val = subst(val, [[^\S+\s+]], '')
            secondTry = 1
            goto continueTry
        end
        break
        ::continueTry::
    end
    if fix then
        local gpsDate, gpsAlt, gpsAltRef
        local t = gmtime(int(time))
        local gpsTime = sprintf('%.2d:%.2d:%.2d', t[3], t[2], t[1]) .. fsec
        -- write GPSDateStamp if date included in track log, otherwise delete it
        if not noDate then gpsDate = sprintf('%.4d:%.2d:%.2d', t[6] + 1900, t[5] + 1, t[4]) end
        -- write GPSAltitude tags if altitude included in track log, otherwise delete them
        local alt = fix.alt
        if alt == nil and perlTruthy(has.alt) and iExt ~= nil then
            local tFix = Geotag.FindFix(et, 'alt', times, points, iExt, iDir, geoMaxExtSecs)
            if tFix then alt = tFix.alt end
        end
        -- set new GPS tag values (EXIF, or XMP if write group is 'xmp')
        local xmp, exif, qt
        local opts = { Type = 'ValueConv' }  -- write ValueConv values
        if perlTruthy(writeGroup) then
            opts.Group = writeGroup
            xmp = matches(writeGroup, [[(?i)xmp]])
            exif = matches(writeGroup, [[(?i)^(exif|gps)$]])
            qt = matches(writeGroup, [[(?i)^(quicktime|keys|itemlist|userdata)$]])
        end
        -- set QuickTime GPSCoordinates
        local coords = ExifTool.NumStr(fix.lat) .. ' ' .. ExifTool.NumStr(fix.lon)
        if alt ~= nil then
            gpsAlt = math.abs(tonumber(alt))
            gpsAltRef = (tonumber(alt) < 0) and 1 or 0
            coords = coords .. ' ' .. ExifTool.NumStr(alt)
        end
        et:SetNewValue('GPSCoordinates', coords, opts)
        -- also Geolocate if specified
        local geoloc, nvHash = et:GetNewValue('Geolocate')
        if perlTruthy(geoloc) and matches(geoloc, [[(?i)\bgeotag\b]]) then
            local tag = ((nvHash and perlTruthy(nvHash.WantGroup)) and (nvHash.WantGroup .. ':') or '') .. 'Geolocate'
            -- pass along any regular expressions to qualify geolocation search
            local parms = { }
            for _, p in ipairs(split([[\s*,\s*]], geoloc)) do
                if p:find('/', 1, true) then parms[#parms + 1] = p end
            end
            local parmStr = table.concat(parms, ',')
            if parmStr ~= '' then parmStr = ',' .. parmStr .. ',both' end
            et:SetNewValue(tag, ExifTool.NumStr(fix.lat) .. ',' .. ExifTool.NumStr(fix.lon) .. parmStr)
            -- (the Geolocate tag will be restored to its original value
            -- by RestoreNewValues before the next file in batch processing)
        end
        if qt then return err end   -- all done if writing to QuickTime only
        -- (capture error messages by calling SetNewValue in list context)
        et:SetNewValue('GPSLatitude', fix.lat, opts)
        et:SetNewValue('GPSLongitude', fix.lon, opts)
        et:SetNewValue('GPSAltitude', gpsAlt, opts)
        et:SetNewValue('GPSAltitudeRef', gpsAltRef, opts)
        if perlTruthy(has.track) or perlTruthy(has.speed) then
            local type_ = perlTruthy(has.track) and 'track' or 'speed'
            local tFix = fix
            if fix[type_] == nil and iExt ~= nil then
                local p = Geotag.FindFix(et, type_, times, points, iExt, iDir, geoMaxExtSecs)
                if p then tFix = p end
            end
            et:SetNewValue('GPSTrack', tFix.track, opts)
            et:SetNewValue('GPSTrackRef', tFix.track ~= nil and 'T' or nil, opts)
            local spd, ref
            spd = tFix.speed
            if spd ~= nil then
                -- convert to specified units if necessary
                ref = et.OPTIONS.GeoSpeedRef
                if perlTruthy(ref) and speedConv[ref] ~= nil then
                    if speedConv[speedConv[ref]] then ref = speedConv[ref] end
                    spd = tonumber(spd) * speedConv[ref]
                else
                    ref = 'N'   -- knots by default
                end
            end
            et:SetNewValue('GPSSpeed', spd, opts)
            et:SetNewValue('GPSSpeedRef', ref, opts)
        end
        if perlTruthy(has.orient) then
            local tFix = fix
            if fix.dir == nil and iExt ~= nil then
                local p = Geotag.FindFix(et, 'dir', times, points, iExt, iDir, geoMaxExtSecs)
                if p then tFix = p end
            end
            et:SetNewValue('GPSImgDirection', tFix.dir, opts)
            et:SetNewValue('GPSImgDirectionRef', tFix.dir ~= nil and 'T' or nil, opts)
            et:SetNewValue('CameraElevationAngle', tFix.pitch, opts)
            -- Note: GPSPitch and GPSRoll are non-standard, and must be user-defined
            et:SetNewValue('GPSPitch', tFix.pitch, opts)
            et:SetNewValue('GPSRoll', tFix.roll, opts)
        end
        if perlTruthy(has.atemp) then
            local tFix = fix
            if fix.atemp == nil and iExt ~= nil then
                -- (not all fixes have atemp, so try interpolating specifically for this)
                local p = Geotag.FindFix(et, 'atemp', times, points, iExt, iDir, geoMaxExtSecs)
                if p then tFix = p end
            end
            et:SetNewValue('AmbientTemperature', tFix.atemp, opts)
        end
        if perlTruthy(has.err) then
            et:SetNewValue('GPSHPositioningError', fix.err, opts)
        end
        if perlTruthy(has.dop) then
            local dop, mm
            if fix.pdop ~= nil then
                dop = fix.pdop
                mm = 3
            elseif fix.hdop ~= nil then
                if fix.vdop ~= nil then
                    dop = math.sqrt(num(fix.hdop) * num(fix.hdop) + num(fix.vdop) * num(fix.vdop))
                    mm = 3
                else
                    dop = fix.hdop
                    mm = 2
                end
            end
            if dop ~= nil then
                et:SetNewValue('GPSMeasureMode', mm, opts)
                et:SetNewValue('GPSDOP', dop, opts)
                -- also set GPSHPositioningError if specified
                local hposErr = et.OPTIONS.GeoHPosErr
                if perlTruthy(hposErr) then
                    hposErr = subst(hposErr, '(?i)gpsdop', 'GPSDOP')
                    local GPSDOP = dop
                    local oldWarn = perl.SIG.__WARN__   -- (local $SIG{'__WARN__'})
                    perl.SIG.__WARN__ = ExifTool.SetWarning
                    ExifTool.evalWarning = nil
                    --### eval GeoHPosErr ($GPSDOP)
                    -- (Lua: perl.eval runs the expression; a die is caught
                    --  as upstream's eval sets $@, leaving the result undef)
                    local ok, res = pcall(perl.eval, hposErr, { GPSDOP = GPSDOP }, ExifTool.evalFuncs())
                    local evalErr = ''  -- ($@)
                    if ok then
                        hposErr = res
                    else
                        hposErr = nil
                        evalErr = perl.isDie(res) and res.msg or tostring(res)
                    end
                    local err = ExifTool.GetWarning()   -- luacheck: ignore 421 (as upstream's `my $err`)
                    if not perlTruthy(err) then err = evalErr end
                    if perlTruthy(err) then
                        err = ExifTool.CleanWarning(err)
                        et:Warn('Error calculating GPSHPositioningError: ' .. err, 1)
                    else
                        et:SetNewValue('GPSHPositioningError', hposErr, opts)
                    end
                    perl.SIG.__WARN__ = oldWarn
                end
            end
        end
        if not xmp then
            local latRef, lonRef
            if fix.lat ~= nil then latRef = (tonumber(fix.lat) > 0) and 'N' or 'S' end
            if fix.lon ~= nil then lonRef = (tonumber(fix.lon) > 0) and 'E' or 'W' end
            et:SetNewValue('GPSLatitudeRef', latRef, opts)
            et:SetNewValue('GPSLongitudeRef', lonRef, opts)
            et:SetNewValue('GPSDateStamp', gpsDate, opts)
            et:SetNewValue('GPSTimeStamp', gpsTime, opts)
            -- set options to edit XMP:GPSDateTime only if it already exists
            opts.EditOnly = 1
            opts.Group = 'XMP'
        end
        if not exif then
            et:SetNewValue('GPSDateTime', (gpsDate or '') .. ' ' .. gpsTime, opts)
        end
        -- set user-defined tags
        local userVals = { }
        for _, u in pairs(userTag) do userVals[#userVals + 1] = u end
        tsort(userVals)
        for _, u in ipairs(userVals) do
            if fix[u] ~= nil then et:SetNewValue(u:sub(2), fix[u]) end
        end
    else
        local opts = { IgnorePermanent = 1 }
        if val ~= nil then opts.Replace = 2 end -- remove existing new values
        -- reset user-defined GPX tags
        Geotag.InitUserTags(et)  -- (won't be set yet because we didn't read a GPX file)
        for _, u in pairs(userTag) do
            et:SetNewValue(u:sub(2), nil, opts)
        end
        if perlTruthy(writeGroup) then opts.Group = writeGroup end
        -- reset any GPS values we might have already set
        for _, tag in ipairs({ 'GPSLatitude', 'GPSLatitudeRef', 'GPSLongitude', 'GPSLongitudeRef',
                    'GPSAltitude', 'GPSAltitudeRef', 'GPSDateStamp', 'GPSTimeStamp', 'GPSDateTime',
                    'GPSTrack', 'GPSTrackRef', 'GPSSpeed', 'GPSSpeedRef', 'GPSImgDirection',
                    'GPSImgDirectionRef', 'GPSPitch', 'GPSRoll', 'CameraElevationAngle',
                    'AmbientTemperature', 'GPSHPositioningError', 'GPSCoordinates',
                    'GPSMeasureMode', 'GPSDOP' }) do
            et:SetNewValue(tag, nil, opts)
        end
    end
    return err
end

--------------------------------------------------------------------------------
-- Convert Geotagging time synchronization value
-- Inputs: 0) exiftool object ref,
--         1) time difference string ("[+-]DD MM:HH:SS.ss"), geosync'd file name,
--            "GPSTIME@IMAGETIME", or "GPSTIME@FILENAME"
-- Returns: geosync hash:
--           Offset = Offset in seconds for latest synchronization (GPS - image time)
--           Points = hash of all sync offsets keyed by image times in seconds
--           Times = sorted list of image synchronization times (keys in Points hash)
-- Notes: calling this routine with more than one geosync'd file causes time drift
--        correction to be implemented
-- (Lua: upstream's `warn(...), return undef` is error(msg, 0) -- the eval
--  warning ConvInv collects from the calling ValueConvInv)
function Geotag.ConvertGeosync(et, val)
    local sync = et:GetNewValue('Geosync') or { }
    local syncFile, gpsTime, imgTime

    local m = { matches(val, [[(.*?)\@(.*)]]) }
    if #m > 0 then
        gpsTime = m[1]
        if isFile(m[2]) then syncFile = m[2] else imgTime = m[2] end
    -- (take care because "-f '1:30'" crashes ActivePerl 5.10)
    elseif not matches(val, [[^\d]]) or not matches(val, [[:]]) then
        if isFile(val) then syncFile = val end
    end
    if perlTruthy(gpsTime) or syncFile ~= nil then
        -- (this is a time synchronization vector)
        if syncFile ~= nil then
            -- check the following tags in order to obtain the image timestamp
            local timeTags = { 'SubSecDateTimeOriginal', 'SubSecCreateDate', 'SubSecModifyDate',
                               'DateTimeOriginal', 'CreateDate', 'ModifyDate', 'FileModifyDate' }
            local reqTags = { }
            for _, t in ipairs(timeTags) do reqTags[#reqTags + 1] = t end
            reqTags[#reqTags + 1] = 'GPSDateTime'
            reqTags[#reqTags + 1] = 'GPSTimeStamp'
            local et2 = ExifTool.new()
            et2:Options('PrintConv', 0)
            local info = et2:ImageInfo(syncFile, table.unpack(reqTags))
            if perlTruthy(info.Error) then error(perlStr(info.Err) .. '\n', 0) end
            if not perlTruthy(gpsTime) then
                gpsTime = info.GPSDateTime or info.GPSTimeStamp
                if perlTruthy(gpsTime) and not perlTruthy(info.GPSDateTime) then gpsTime = gpsTime .. 'Z' end
            end
            if not perlTruthy(gpsTime) then error("No GPSTimeStamp in '" .. syncFile .. '\n', 0) end
            for _, tag in ipairs(timeTags) do
                if perlTruthy(info[tag]) then
                    imgTime = info[tag]
                    et:VPrint(2, 'Geosyncing with ' .. tag .. " from '" .. syncFile .. "'\n")
                    break
                end
            end
            if not perlTruthy(imgTime) then error("No image timestamp in '" .. syncFile .. "'\n", 0) end
        end
        -- add date to date-less timestamps
        local imgDateTime, gpsDateTime, noDate
        local i = matches(imgTime, [[^(\d+:\d+:\d+)\s+\d+]])
        if i then
            imgDateTime = imgTime
            local date = i
            if matches(gpsTime, [[^\d+:\d+:\d+\s+\d+]]) then
                gpsDateTime = gpsTime
            else
                gpsDateTime = date .. ' ' .. gpsTime
            end
        else
            local g = matches(gpsTime, [[^(\d+:\d+:\d+)\s+\d+]])
            if g then
                imgDateTime = g .. ' ' .. imgTime
                gpsDateTime = gpsTime
            else
                -- use a today's date (so hopefully the DST setting will be intuitive)
                local tm = localtime()
                local date = sprintf('%.4d:%.2d:%.2d', tm[6] + 1900, tm[5] + 1, tm[4])
                gpsDateTime = date .. ' ' .. gpsTime
                imgDateTime = date .. ' ' .. imgTime
                noDate = 1
            end
        end
        -- calculate Unix seconds since the epoch
        local imgSecs = ExifTool.GetUnixTime(imgDateTime, 1)
        if imgSecs == nil then error("Invalid image time '" .. imgTime .. "'\n", 0) end
        local gpsSecs = ExifTool.GetUnixTime(gpsDateTime, 1)
        if gpsSecs == nil then error("Invalid GPS time '" .. gpsTime .. "'\n", 0) end
        -- add fractional seconds
        local gf = matches(gpsTime, [[(\.\d+)]])
        if gf then gpsSecs = gpsSecs + tonumber(gf) end
        local imf = matches(imgTime, [[(\.\d+)]])
        if imf then imgSecs = imgSecs + tonumber(imf) end
        -- shift dates within 12 hours of each other if either timestamp was date-less
        if gpsDateTime ~= gpsTime or imgDateTime ~= imgTime then
            local diff = (imgSecs - gpsSecs) % (24 * 3600)
            if diff > 12 * 3600 then diff = diff - 24 * 3600 end
            if diff < -12 * 3600 then diff = diff + 24 * 3600 end
            if gpsDateTime ~= gpsTime then
                gpsSecs = imgSecs - diff
            else
                imgSecs = gpsSecs + diff
            end
        end
        -- save the synchronization offset
        sync.Offset = gpsSecs - imgSecs
        -- save this synchronization point if either timestamp had a date
        if not noDate then
            if not sync.Points then sync.Points = { } end
            sync.Points[imgSecs] = sync.Offset
            -- print verbose output
            if num(et:Options('Verbose')) > 1 then
                -- print GPS and image timestamps in UTC
                et:VPrint(1, 'Added Geosync point:\n',
                             '  GPS time stamp:  ', Geotag.PrintFixTime(gpsSecs), '\n',
                             '  Image date/time: ', Geotag.PrintFixTime(imgSecs), '\n')
            end
            -- save sorted list of image sync times if we have more than one
            local times = { }
            for k in pairs(sync.Points) do times[#times + 1] = k end
            if #times > 1 then
                tsort(times, function(a, b) return a < b end)
                sync.Times = times
            end
        end
    else
        -- (this is a simple time difference)
        local vals = findAll(val, [[(?=\d|\.\d)\d*(?:\.\d*)?]])  -- (allow decimal values too)
        if #vals == 0 then error('Invalid value (please refer to geotag documentation)\n', 0) end
        local secs = 0
        for _, mult in ipairs({ 1, 60, 3600, secPerDay }) do
            secs = secs + mult * (tonumber(table.remove(vals)) or 0)
            if #vals == 0 then break end
        end
        -- set constant sync offset
        sync.Offset = matches(val, [[^\s*-]]) and -secs or secs
    end
    return sync
end

--------------------------------------------------------------------------------
-- Print fix time
-- Inputs: 0) time since the epoch
-- Returns: UTC time string with fractional seconds
function Geotag.PrintFixTime(time)
    return ExifTool.ConvertUnixTime(time, nil, 3) .. ' UTC'
end

--------------------------------------------------------------------------------
-- Print fix information
-- Inputs: 0) lookup for all fix points, 1-n) list of fix times
-- Returns: fix string (including leading indent and trailing newline)
function Geotag.PrintFix(points, ...)
    local args = { ... }
    local str = ''
    for _, time in ipairs(args) do
        str = str .. '    ' .. Geotag.PrintFixTime(time) .. ' -'
        local fix = points[time]
        if fix then
            local keys = { }
            for k in pairs(fix) do keys[#keys + 1] = k end
            tsort(keys)
            for _, k in ipairs(keys) do
                if k ~= 'time' and fix[k] ~= nil then
                    str = str .. ' ' .. k .. '=' .. ExifTool.NumStr(fix[k])
                end
            end
        end
        str = str .. '\n'
    end
    return str
end

--------------------------------------------------------------------------------
-- Initialize %userTag for reading user-defined GPX tags
-- Inputs: 0) ExifTool ref
function Geotag.InitUserTags(et)
    userTag = { }
    if perlTruthy(et.OPTIONS.GeoUserTag) then
        for _, s in ipairs(split([[\s*,\s*]], et.OPTIONS.GeoUserTag)) do
            local m = { matches(s, [[^(.+)=(.+)$]]) }
            if #m > 0 then
                if xmlTag[lc(m[2])] then
                    et:Warn("User-defined GPX tag '" .. m[2] .. "' conflicts with existing tag")
                else
                    userTag[lc(m[2])] = '_' .. m[1]  -- (leading underline prevents conflicts)
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
return Geotag  -- end
