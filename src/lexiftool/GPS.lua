--------------------------------------------------------------------------------
-- File:         lexiftool/GPS.lua
-- Ported from:  lib/Image/ExifTool/GPS.pm
--
-- Description:  EXIF GPS meta information tags
--
-- Revisions:    12/09/2003  - P. Harvey Created
--
-- Port notes:   All tables and subs of GPS.pm.  The Composite tags
--               GPSLatitude/GPSLongitude are writable (WriteAlso to the GPS
--               tags) and join the one Composite table through
--               AddCompositeTags; their tag IDs carry the "GPS-" prefix.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Exif = require('lexiftool.Exif')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local isMatch = perl.isMatch
local perlTruthy = perl.truthy
local perlStr = perl.str
local uc = perl.uc

local GPS = {}

local printConvLatRef = {
    -- extract N/S if written from Composite:GPSLatitude
    -- (also allow writing from a signed number)
    OTHER = function(val, inv)
        if not inv then return nil end
        local _, ns = perl.matches(val, [[(?i)(^|[^A-Z])([NS])(orth|outh)?\b]])
        if ns then return uc(ns) end
        local sign = perl.matches(val, [[([-+]?)\d+]])
        if sign then return sign == '-' and 'S' or 'N' end
        return nil
    end,
    N = 'North',
    S = 'South',
}

local printConvLonRef = {
    -- extract E/W if written from Composite:GPSLongitude
    -- (also allow writing from a signed number)
    OTHER = function(val, inv)
        if not inv then return nil end
        local _, ew = perl.matches(val, [[(?i)(^|[^A-Z])([EW])(ast|est)?\b]])
        if ew then return uc(ew) end
        local sign = perl.matches(val, [[([-+]?)\d+]])
        if sign then return sign == '-' and 'W' or 'E' end
        return nil
    end,
    E = 'East',
    W = 'West',
}

-- common conversion for coordinate tags (upstream %coordConv)
local coordConv = {
    ValueConv = function(_self, val) return GPS.ToDegrees(val) end,
    ValueConvInv = function(self, val) return GPS.ToDMS(self, val) end,
    PrintConv = function(self, val) return GPS.ToDMS(self, val, 1) end,
}

GPS.Main = {
    GROUPS = { [0] = 'EXIF', [1] = 'GPS', [2] = 'Location' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = 1,
    WRITE_GROUP = 'GPS',
    [0x0000] = {
        Name = 'GPSVersionID',
        Writable = 'int8u',
        Mandatory = 1,
        Count = 4,
        PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '.')) end,
        PrintConvInv = function(_self, val) return (perlStr(val):gsub('%.', ' ')) end,
    },
    [0x0001] = {
        Name = 'GPSLatitudeRef',
        Writable = 'string',
        Notes = [[
            tags 0x0001-0x0006 used for camera location according to MWG 2.0. ExifTool
            will also accept a number when writing GPSLatitudeRef, positive for north
            latitudes or negative for south, or a string containing N, North, S or South
        ]],
        Count = 2,
        PrintConv = printConvLatRef,
    },
    [0x0002] = {
        Name = 'GPSLatitude',
        Writable = 'rational64u',
        Count = 3,
        ValueConv = coordConv.ValueConv,
        ValueConvInv = coordConv.ValueConvInv,
        PrintConv = coordConv.PrintConv,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, nil, 'lat') end,
    },
    [0x0003] = {
        Name = 'GPSLongitudeRef',
        Writable = 'string',
        Count = 2,
        Notes = [[
            ExifTool will also accept a number when writing this tag, positive for east
            longitudes or negative for west, or a string containing E, East, W or West
        ]],
        PrintConv = printConvLonRef,
    },
    [0x0004] = {
        Name = 'GPSLongitude',
        Writable = 'rational64u',
        Count = 3,
        ValueConv = coordConv.ValueConv,
        ValueConvInv = coordConv.ValueConvInv,
        PrintConv = coordConv.PrintConv,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, nil, 'lon') end,
    },
    [0x0005] = {
        Name = 'GPSAltitudeRef',
        Writable = 'int8u',
        Notes = [[
            ExifTool will also accept number when writing this tag, with negative
            numbers indicating below sea level
        ]],
        PrintConv = {
            OTHER = function(val, inv)
                if not inv then return nil end
                local sign = perl.matches(val, [[^([-+0-9])]])
                if not sign then return nil end
                return sign == '-' and 1 or 0
            end,
            [0] = 'Above Sea Level', -- (ellipsoidal surface, Exif 3.0)
            [1] = 'Below Sea Level', -- (ellipsoidal surface, Exif 3.0)
            [2] = 'Positive Sea Level (sea-level ref)', -- sea-level reference, Exif 3.0
            [3] = 'Negative Sea Level (sea-level ref)', -- sea-level reference, Exif 3.0
        },
    },
    [0x0006] = {
        Name = 'GPSAltitude',
        Writable = 'rational64u',
        -- extricate unsigned decimal number from string
        ValueConvInv = function(_self, val) return (perl.matches(val, [[((?=\d|\.\d)\d*(?:\.\d*)?)]])) end,
        PrintConv = function(_self, val) return isMatch(val, '^(inf|undef)$') and val or perl.str(val) .. ' m' end,
        PrintConvInv = function(_self, val) return (perl.subst(val, [[\s*m$]], '')) end,
    },
    [0x0007] = {
        Name = 'GPSTimeStamp',
        Groups = { [2] = 'Time' },
        Writable = 'rational64u',
        Count = 3,
        Shift = 'Time',
        Notes = [[
            UTC time of GPS fix.  When writing, date is stripped off if present, and
            time is adjusted to UTC if it includes a timezone
        ]],
        ValueConv = function(_self, val) return GPS.ConvertTimeStamp(val) end,
        ValueConvInv = function(_self, val) return (perl.tr(val, ':', ' ')) end,
        PrintConv = function(_self, val) return GPS.PrintTimeStamp(val) end,
        PrintConvInv = function(et, v)
            if perl.lc(v) == 'now' then v = et:TimeNow() end
            local tz
            local s1, h, m = perl.matches(v, [[(?i)([-+])(\d{1,2}):?(\d{2})\s*(DST)?$]])
            if s1 then    -- remove timezone
                v = perl.subst(v, [[(?i)([-+])(\d{1,2}):?(\d{2})\s*(DST)?$]], '')
                local s = s1 == '-' and 1 or -1 -- opposite sign to convert back to UTC
                tz = { s * h, s * m }
            end
            -- (note: we must allow '.' as a time separator, eg. '10.30.00', with is tricky due to decimal seconds)
            -- YYYYmmddHHMMSS[.ss] format
            local a = { perl.matches(v, [[^[^\d]*\d{4}[^\d]*\d{1,2}[^\d]*\d{1,2}[^\d]*(\d{1,2})[^\d]*(\d{2})[^\d]*(\d{2}(?:\.\d+)?)[^\d]*$]]) }
            -- HHMMSS[.ss] format
            if a[1] == nil then a = { perl.matches(v, [[^[^\d]*(\d{1,2})[^\d]*(\d{2})[^\d]*(\d{2}(?:\.\d+)?)[^\d]*$]]) } end
            if a[1] == nil then error('Invalid time (use HH:MM:SS[.ss][+/-HH:MM|Z])', 0) end
            a = { a[1], a[2], a[3] }  -- (perl.matches also returns the match end)
            if tz then
                -- adjust to UTC
                a[2] = a[2] + tz[2]
                a[1] = a[1] + tz[1]
                while a[2] >= 60 do a[2] = a[2] - 60; a[1] = a[1] + 1 end
                while a[2] < 0   do a[2] = a[2] + 60; a[1] = a[1] - 1 end
                a[1] = (a[1] + 24) % 24
            end
            return perl.join(':', a)
        end,
    },
    [0x0008] = {
        Name = 'GPSSatellites',
        Writable = 'string',
    },
    [0x0009] = {
        Name = 'GPSStatus',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            A = 'Measurement Active', -- Exif2.2 "Measurement in progress"
            V = 'Measurement Void',   -- Exif2.2 "Measurement Interoperability" (WTF?)
            -- (meaning for 'V' taken from status code in NMEA GLL and RMC sentences)
        },
    },
    [0x000a] = {
        Name = 'GPSMeasureMode',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            [2] = '2-Dimensional Measurement',
            [3] = '3-Dimensional Measurement',
        },
    },
    [0x000b] = {
        Name = 'GPSDOP',
        Description = 'GPS Dilution Of Precision',
        Writable = 'rational64u',
    },
    [0x000c] = {
        Name = 'GPSSpeedRef',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            K = 'km/h',
            M = 'mph',
            N = 'knots',
        },
    },
    [0x000d] = {
        Name = 'GPSSpeed',
        Writable = 'rational64u',
    },
    [0x000e] = {
        Name = 'GPSTrackRef',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0x000f] = {
        Name = 'GPSTrack',
        Writable = 'rational64u',
    },
    [0x0010] = {
        Name = 'GPSImgDirectionRef',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0x0011] = {
        Name = 'GPSImgDirection',
        Writable = 'rational64u',
    },
    [0x0012] = {
        Name = 'GPSMapDatum',
        Writable = 'string',
    },
    [0x0013] = {
        Name = 'GPSDestLatitudeRef',
        Writable = 'string',
        Notes = 'tags 0x0013-0x001a used for subject location according to MWG 2.0',
        Count = 2,
        PrintConv = printConvLatRef,
    },
    [0x0014] = {
        Name = 'GPSDestLatitude',
        Writable = 'rational64u',
        Count = 3,
        ValueConv = coordConv.ValueConv,
        ValueConvInv = coordConv.ValueConvInv,
        PrintConv = coordConv.PrintConv,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, nil, 'lat') end,
    },
    [0x0015] = {
        Name = 'GPSDestLongitudeRef',
        Writable = 'string',
        Count = 2,
        PrintConv = printConvLonRef,
    },
    [0x0016] = {
        Name = 'GPSDestLongitude',
        Writable = 'rational64u',
        Count = 3,
        ValueConv = coordConv.ValueConv,
        ValueConvInv = coordConv.ValueConvInv,
        PrintConv = coordConv.PrintConv,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, nil, 'lon') end,
    },
    [0x0017] = {
        Name = 'GPSDestBearingRef',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            M = 'Magnetic North',
            T = 'True North',
        },
    },
    [0x0018] = {
        Name = 'GPSDestBearing',
        Writable = 'rational64u',
    },
    [0x0019] = {
        Name = 'GPSDestDistanceRef',
        Writable = 'string',
        Count = 2,
        PrintConv = {
            K = 'Kilometers',
            M = 'Miles',
            N = 'Nautical Miles',
        },
    },
    [0x001a] = {
        Name = 'GPSDestDistance',
        Writable = 'rational64u',
    },
    [0x001b] = {
        Name = 'GPSProcessingMethod',
        Writable = 'undef',
        Notes = 'values of "GPS", "CELLID", "WLAN" or "MANUAL" by the EXIF spec.',
        RawConv = function(self, val) return Exif.ConvertExifText(self, val, '1', 'GPSProcessingMethod') end,
        RawConvInv = function(self, val) return require('lexiftool.WriteExif').EncodeExifText(self, val) end,
    },
    [0x001c] = {
        Name = 'GPSAreaInformation',
        Writable = 'undef',
        RawConv = function(self, val, tag) return Exif.ConvertExifText(self, val, 1, tag) end,
        RawConvInv = function(self, val) return require('lexiftool.WriteExif').EncodeExifText(self, val) end,
    },
    [0x001d] = {
        Name = 'GPSDateStamp',
        Groups = { [2] = 'Time' },
        Writable = 'string',
        Format = 'undef', -- (Casio EX-H20G uses "\0" instead of ":" as a separator)
        Count = 11,
        Shift = 'Time',
        Notes = [[
            when writing, time is stripped off if present, after adjusting date/time to
            UTC if time includes a timezone.  Format is YYYY:mm:dd
        ]],
        RawConv = function(_self, val) return (perlStr(val):gsub('\0+$', '')) end,
        ValueConv = function(_self, val) return GPS.ExifDate(val) end,
        ValueConvInv = function(_self, val) return val end,
        PrintConvInv = function(self, val)
            local secs
            if perl.lc(val) == 'now' then val = self:TimeNow() end
            if perl.isMatch(val, '[-+]') then
                secs = ExifTool.GetUnixTime(val, 1)
                if perl.truthy(secs) then val = ExifTool.ConvertUnixTime(secs) end
            end
            local y, m, d = perl.matches(val, [[(\d{4}).*?(\d{2}).*?(\d{2})]])
            if y then return y .. ':' .. m .. ':' .. d end
            return nil
        end,
    },
    [0x001e] = {
        Name = 'GPSDifferential',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'No Correction',
            [1] = 'Differential Corrected',
        },
    },
    [0x001f] = {
        Name = 'GPSHPositioningError',
        Description = 'GPS Horizontal Positioning Error',
        Writable = 'rational64u',
        PrintConv = function(_self, val) return perl.str(val) .. ' m' end,
        PrintConvInv = function(_self, val) return (perl.subst(val, [[\s*m$]], '')) end,
    },
}

-- Composite GPS tags (read subset: only the four tags exercised by
-- `Ricoh2.jpg`'s golden output)
GPS.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Location' },
    GPSDateTime = {
        TagID = 'GPS-GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        SubDoc = 1, -- generate for all sub-documents
        Require = {
            [0] = 'GPS:GPSDateStamp',
            [1] = 'GPS:GPSTimeStamp',
        },
        ValueConv = function(_self, val) return perl.str(val[0]) .. ' ' .. perl.str(val[1]) .. 'Z' end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- Note: The following tags are used by other modules
    -- which must therefore require this module as necessary
    GPSLatitude = {
        TagID = 'GPS-GPSLatitude',
        SubDoc = 1,    -- generate for all sub-documents
        Writable = 1,
        Avoid = 1,
        Priority = 1, -- (necessary because Avoid sets default Priority to 0)
        Require = {
            [0] = 'GPS:GPSLatitude',
            [1] = 'GPS:GPSLatitudeRef',
        },
        WriteAlso = {
            ['GPS:GPSLatitude'] = function(_self, val) return val end,
            ['GPS:GPSLatitudeRef'] = function(_self, val) return (val ~= nil and perl.num(val) < 0) and "S" or "N" end,
        },
        ValueConv = function(_self, val)
            return isMatch(val[1], [[(?i)^S]]) and -perl.num(val[0]) or val[0]
        end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, "lat") end,
    },
    GPSLongitude = {
        TagID = 'GPS-GPSLongitude',
        SubDoc = 1,    -- generate for all sub-documents
        Writable = 1,
        Avoid = 1,
        Priority = 1,
        Require = {
            [0] = 'GPS:GPSLongitude',
            [1] = 'GPS:GPSLongitudeRef',
        },
        WriteAlso = {
            ['GPS:GPSLongitude'] = function(_self, val) return val end,
            ['GPS:GPSLongitudeRef'] = function(_self, val) return (val ~= nil and perl.num(val) < 0) and "W" or "E" end,
        },
        ValueConv = function(_self, val)
            return isMatch(val[1], [[(?i)^W]]) and -perl.num(val[0]) or val[0]
        end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
        PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, "lon") end,
    },
    GPSAltitude = {
        TagID = 'GPS-GPSAltitude',
        SubDoc = { 1, 3 }, -- generate for sub-documents if Desire 1 or 3 has a chance to exist
        Desire = {
            [0] = 'GPS:GPSAltitude',
            [1] = 'GPS:GPSAltitudeRef',
            [2] = 'XMP:GPSAltitude',
            [3] = 'XMP:GPSAltitudeRef',
        },
        -- Require either GPS:GPSAltitudeRef or XMP:GPSAltitudeRef
        RawConv = function(_self, val)
            return (val[1] ~= nil or val[3] ~= nil) and val or nil
        end,
        ValueConv = function(_self, val)
            for _, i in ipairs({ 0, 2 }) do
                if val[i] ~= nil and ExifTool.IsFloat(val[i]) and val[i + 1] ~= nil then
                    if perlTruthy(val[i + 1]) then return -math.abs(perl.num(val[i])) end
                    return val[i]
                end
            end
            return nil
        end,
        PrintConv = function(_self, val, vals, prt)
            for _, i in ipairs({ 0, 2 }) do
                if vals[i] ~= nil and ExifTool.IsFloat(vals[i]) and
                    prt[i + 1] ~= nil and isMatch(prt[i + 1], 'Sea') then
                    return perlStr(perl.int(perl.num(vals[i]) * 10) / 10) .. ' m ' .. perlStr(prt[i + 1])
                end
            end
            val = perlStr(perl.int(perl.num(val) * 10) / 10)
            local stripped = perl.subst(val, '^-', '')
            return (stripped ~= val and stripped .. ' m Below' or val .. ' m Above') .. ' Sea Level'
        end,
    },
    GPSDestLatitude = {
        TagID = 'GPS-GPSDestLatitude',
        Require = {
            [0] = 'GPS:GPSDestLatitude',
            [1] = 'GPS:GPSDestLatitudeRef',
        },
        ValueConv = function(_self, val)
            return isMatch(val[1], [[(?i)^S]]) and -perl.num(val[0]) or val[0]
        end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    GPSDestLongitude = {
        TagID = 'GPS-GPSDestLongitude',
        SubDoc = 1,    -- generate for all sub-documents
        Require = {
            [0] = 'GPS:GPSDestLongitude',
            [1] = 'GPS:GPSDestLongitudeRef',
        },
        ValueConv = function(_self, val)
            return isMatch(val[1], [[(?i)^W]]) and -perl.num(val[0]) or val[0]
        end,
        PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.GPS', nil, GPS)

--------------------------------------------------------------------------------
-- Convert GPS timestamp value
-- Inputs: 0) raw timestamp value string
-- Returns: EXIF-formatted time string
--------------------------------------------------------------------------------
function GPS.ConvertTimeStamp(val)
    local h, m, s = table.unpack(perl.split(' ', val))
    local f = (perl.num(perlTruthy(h) and h or 0, '*') * 60 +
               perl.num(perlTruthy(m) and m or 0, '+')) * 60 + perl.num(perlTruthy(s) and s or 0, '+')
    h = perl.int(f / 3600); f = f - h * 3600
    m = perl.int(f / 60);   f = f - m * 60
    local ss = sprintf('%012.9f', f)
    if perl.num(ss) >= 60 then
        ss = '00'
        m = m + 1
        if m >= 60 then m = m - 60; h = h + 1 end
    else
        ss = perl.subst(ss, [[\.?0+$]], '')  -- trim trailing zeros + decimal
    end
    return sprintf('%.2d:%.2d:%s', h, m, ss)
end

--------------------------------------------------------------------------------
-- Print GPS timestamp
-- Inputs: 0) EXIF-formatted time string
-- Returns: time rounded to the nearest microsecond
--------------------------------------------------------------------------------
function GPS.PrintTimeStamp(val)
    val = perlStr(val)
    if not val:match(':(%d%d%.%d+)$') then return val end
    local pre, sec = val:match('^(.*):(%d%d%.%d+)$')
    local s = math.floor(tonumber(sec) * 1000000 + 0.5) / 1000000
    if s < 10 then s = '0' .. perlStr(s) end
    return pre .. ':' .. perlStr(s)
end

--------------------------------------------------------------------------------
-- Convert degrees to DMS, or whatever the current settings are
-- Inputs: 0) ExifTool reference, 1) Value in degrees,
--         2) format code (0=no format, 1=CoordFormat, 2=XMP format, 3=signed unformatted)
--         3) 'N' or 'E' if sign is significant and N/S/E/W should be added
-- Returns: DMS string
--------------------------------------------------------------------------------
function GPS.ToDMS(et, val, doPrintConv, ref)
    local num, neg, rtnVal
    -- (upstream compares `$doPrintConv eq 'N'` strings; callers pass the
    -- numeric codes 0-3, so stringify for the comparison)
    doPrintConv = doPrintConv ~= nil and perlStr(doPrintConv) or nil

    if #perlStr(val) == 0 then
        -- don't convert an empty value
        if doPrintConv and doPrintConv == '1' then return val end -- avoid hiding existing tag when extracting
        return nil -- avoid writing empty value
    end
    local sign, minus
    if ref then
        if tonumber(val) < 0 then
            val = -tonumber(val)
            ref = (ref == 'N' and 'S') or (ref == 'E' and 'W') or ref
            sign, minus = '-', '-'
        else
            sign, minus = '+', ''
        end
        if not (doPrintConv and doPrintConv == '2') then ref = ' ' .. ref end
    else
        if doPrintConv and doPrintConv == '3' then
            if tonumber(val) < 0 then neg = 1 end
            doPrintConv = 0
        end
        val = math.abs(tonumber(val))
        ref = ''
    end
    local fmt
    local fmts = {} -- the individual format specifiers of `fmt` (max 3)
    if perlTruthy(doPrintConv) then
        if doPrintConv == '1' then
            fmt = et and et.OPTIONS and et.OPTIONS.CoordFormat
            if not fmt or fmt == '' then
                fmt = '%d deg %d\' %.2f"' .. ref
            elseif ref ~= '' then
                -- use signed value instead of reference direction if specified
                local n
                fmt, n = fmt:gsub('%%%+', sign .. '%%')
                if n == 0 then
                    fmt, n = fmt:gsub('%%%-', minus == '' and '%%' or (minus .. '%%'))
                    if n == 0 then fmt = fmt .. ref end
                end
            else
                fmt = fmt:gsub('%%%+', '%%') -- don't know sign, so don't print it
            end
        else
            fmt = '%d,%.8f' .. ref -- use XMP format with 8 decimal minutes
        end
        -- count (and capture) the format specifiers (max 3)
        local pos = 1
        while #fmts < 3 do
            local a, b = fmt:find('%%[-+ #0-9.]*[diouxXDOUeEfFgGcs%%]', pos)
            if not a then break end
            local spec = fmt:sub(a, b)
            pos = b + 1
            if spec ~= '%%' then fmts[#fmts + 1] = spec end
        end
        num = #fmts
    else
        num = 3
    end
    local c = {}
    c[0] = val
    if num > 1 then
        c[0] = math.floor(c[0])
        c[1] = (val - c[0]) * 60
        if num > 2 then
            c[1] = math.floor(c[1])
            c[2] = (val - c[0] - c[1] / 60) * 3600
        end
        -- handle round-off errors to ensure minutes and seconds are
        -- less than 60 (eg. convert "72 59 60.00" to "73 0 0.00")
        if perlTruthy(doPrintConv) then
            c[num - 1] = sprintf(fmts[num], c[num - 1])
        else
            c[num - 1] = perlStr(c[num - 1])
        end
        if tonumber(c[num - 1]) >= 60 then
            c[num - 1] = tonumber(c[num - 1]) - 60
            c[num - 2] = c[num - 2] + 1
            if num > 2 and c[num - 2] >= 60 then
                c[num - 2] = c[num - 2] - 60
                c[num - 3] = c[num - 3] + 1
            end
        end
    end
    if perlTruthy(doPrintConv) then
        rtnVal = sprintf(fmt, table.unpack(c, 0, num - 1))
        -- trim trailing zeros in XMP
        if doPrintConv == '2' then
            rtnVal = rtnVal:gsub('(%d)0+' .. ref:gsub('[^A-Za-z0-9]', '%%%0') .. '$', '%1' .. ref)
        end
    else
        if neg then
            for i = 0, num - 1 do c[i] = perl.num(c[i]) * -1 end
        end
        local parts = {}
        for i = 0, num - 1 do parts[#parts + 1] = perlStr(c[i]) end
        rtnVal = table.concat(parts, ' ') .. ref
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Convert to decimal degrees
-- Inputs: 0) a string containing 1-3 decimal numbers and any amount of other garbage
--         1) true if value should be negative if coordinate ends in 'S' or 'W',
--         2) 'lat' or 'lon' to extract lat or lon from GPSCoordinates string
-- Returns: Coordinate in degrees, or '' on error
--------------------------------------------------------------------------------
function GPS.ToDegrees(val, doSign, coord)
    val = perlStr(val)
    if perl.matches(val, [[\b(inf|undef)\b]]) then return '' end -- ignore invalid values
    -- use only lat or lon part of combined GPSCoordinates inputs
    if coord and (coord == 'lat' or coord == 'lon') and
        -- (two formatted coordinate values with cardinal directions, separated by a comma)
        -- (upstream `$val =~ /.../i`: the alternation, optional groups and /i
        --  flag have no Lua-pattern equivalent, so the literal Perl pattern
        --  goes through the perl facade)
        perl.matches(val, [[(?i)^(.*(?:N(?:orth)?|S(?:outh)?)),\s*(.*(?:E(?:ast)?|W(?:est)?))$]]) then
        local a, b = perl.matches(val, [[(?i)^(.*(?:N(?:orth)?|S(?:outh)?)),\s*(.*(?:E(?:ast)?|W(?:est)?))$]])
        val = (coord == 'lat') and a or b
    end
    -- extract decimal or floating point values out of any other garbage
    -- (upstream `my ($d, $m, $s) = ($val =~ /.../g)` -- the alternation,
    --  lookahead and optional groups have no Lua-pattern equivalent, so the
    --  literal Perl pattern goes through the perl facade; findAll collects
    --  the captures from the first three matches)
    local nums = perl.findAll(val, [[((?:[+-]?)(?=\d|\.\d)\d*(?:\.\d*)?(?:[Ee][+-]\d+)?)]])
    local d = nums[1]
    if not d then return '' end
    if d == 'inf' or d == 'undef' then return '' end
    local deg = tonumber(d) + ((tonumber(nums[2]) or 0) + (tonumber(nums[3]) or 0) / 60) / 60
    -- make negative if S or W coordinate
    -- (upstream `$val =~ /.../i`: alternation + optional groups + /i have no
    --  Lua-pattern equivalent, so the literal Perl pattern goes through the
    --  perl facade)
    if doSign then
        if perl.matches(val, [[(?i)[^A-Z](S(outh)?|W(est)?)\s*$]]) then deg = -deg end
    elseif deg < 0 then
        deg = -deg
    end
    return deg
end

--------------------------------------------------------------------------------
-- Convert a date string to YYYY:MM:DD (upstream Exif::ExifDate).
--------------------------------------------------------------------------------
function GPS.ExifDate(date)
    date = perlStr(date)
    date = date:gsub('\0$', '') -- remove any null terminator
    -- separate year:month:day with colons
    -- (have seen many other characters, including nulls, used erroneously)
    date = date:gsub('(%d%d%d%d)[^%d]*(%d%d)[^%d]*(%d%d)$', '%1:%2:%3')
    return date
end

return GPS
