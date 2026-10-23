--------------------------------------------------------------------------------
-- File:         lexiftool/LigoGPS.lua
-- Ported from:  lib/Image/ExifTool/LigoGPS.pm
--
-- Description:  Read LIGOGPSINFO timed GPS records
--
-- Revisions:    2024-12-30 - P. Harvey Created
--
-- Port notes:   complete: all seven subs (CleanupCipher, UnfuzzLigoGPS,
--               DecryptLigoGPS, OrderCipherDigits, DecipherLigoGPS,
--               ParseLigoGPS, ProcessGKU, ProcessLigoGPS, ProcessLigoJSON).
--               Deviations forced by Lua:
--               - Perl's `pos($$dataPt)` is a property of the scalar, which
--                 ProcessGKU sets before handing the buffer to
--                 ProcessLigoJSON.  Lua strings carry no such state, so
--                 ProcessLigoJSON takes the search position as an extra
--                 (optional, defaulting to 0) 4th argument -- the same
--                 explicit-position idiom H264.lua and Trailer.lua use.
--               - `ConvertLatLon` modifies its two arguments in place
--                 upstream; the port's QuickTimeStream.ConvertLatLon returns
--                 the pair instead.
--               - `@in`/`shift @in` in DecryptLigoGPS become an array plus an
--                 explicit read index (`in` is a Lua keyword); each Perl
--                 `push @out, a, b, c, d` becomes one `push` per value, since
--                 Lua does not guarantee left-to-right evaluation of the
--                 arguments of a single call and the shifts must run in order.
--               Wiring: as upstream -- M2TS.lua (the type 6 / PID 0x0300
--                 branch of ParsePID and the LIGOGPSINFO trailer at the end
--                 of ProcessM2TS), QuickTime.lua (the 'skip' atom, the
--                 LigoGPSInfo/LigoJSON/GKUData 'udta' variants and the
--                 LigoGPS trailer) and QuickTimeStream.lua's ProcessFreeGPS.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local substr = perl.substr
local unpack_ = perl.unpack
local D = perl.D
local sprintf = perl.sprintf
local uc = perl.uc

local LigoGPS = {}

-- Perl `int()` truncates toward zero (unlike Lua's math.floor, which rounds
-- down for negative values)
local function int(v)
    if v >= 0 then return math.floor(v) end
    return math.ceil(v)
end

local knotsToKph = 1.852     -- knots --> km/h

--------------------------------------------------------------------------------
-- Clean up cipher variables and print warning if deciphering was unsuccessful
-- Inputs: 0) ExifTool ref
function LigoGPS.CleanupCipher(et)
    if et.LigoCipher and et.LigoCipher['next'] then
        et:Warn('Not enough GPS points to determine cipher for decoding LIGOGPSINFO')
    end
    et.LigoCipher = nil
end

--------------------------------------------------------------------------------
-- Un-do LIGOGPS fuzzing
-- Inputs: 0) fuzzed latitude, 1) fuzzed longitude, 2) scale factor
-- Returns: 0) latitude, 1) longitude
function LigoGPS.UnfuzzLigoGPS(lat, lon, scl)
    local lat2 = int(lat / 10) * 10
    local lon2 = int(lon / 10) * 10
    return lat2 + (lon - lon2) * scl, lon2 + (lat - lat2) * scl
end

--------------------------------------------------------------------------------
-- Decrypt LIGOGPSINFO record (starting with "####")
-- Inputs: 0) encrypted GPS record incuding 8-byte header
-- Returns: decrypted record including 4-byte uint32 header, or undef on error
function LigoGPS.DecryptLigoGPS(str)
    local num = unpack_('x4V', str)
    if num == nil or num < 4 then return nil end
    if num > 0x84 then num = 0x84 end -- (be safe)
    local in_ = { unpack_('x8C' .. ExifTool.NumStr(num), str) }
    local out = {}
    local ptr = 1 -- (Perl's `shift @in` becomes a read index into in_)
    local function shift_in() local v = in_[ptr] ptr = ptr + 1 return v end
    local function num_in() return #in_ - ptr + 1 end
    local function push(v) out[#out + 1] = v end
    while num_in() > 0 do
        local b = shift_in()  -- get next byte in data
        -- upper 3 bits steer the decryption for this round
        local steeringBits = b & 0xe0
        if steeringBits >= 0xc0 then
            if num_in() < 4 then return nil end    -- next 4 bytes are encrypted data
            push((shift_in() | b & 0x01) ~ 0x20)
            push((shift_in() | b & 0x02) ~ 0x20)
            push((shift_in() | b & 0x0c) ~ 0x20)
            push(shift_in() ~ 0x20 | b & 0x30)
        elseif steeringBits >= 0x40 then
            if num_in() < 3 then return nil end    -- next 3 bytes are encrypted data
            if steeringBits == 0x40 then
                push(0x20)
                push((shift_in() | b & 0x01) ~ 0x20)
                push((shift_in() | b & 0x06) ~ 0x20)
                push((shift_in() | b & 0x18) ~ 0x20)
            elseif steeringBits == 0x60 then
                push((shift_in() | b & 0x03) ~ 0x20)
                push(0x20)
                push((shift_in() | b & 0x04) ~ 0x20)
                push((shift_in() | b & 0x18) ~ 0x20)
            elseif steeringBits == 0x80 then
                push((shift_in() | b & 0x03) ~ 0x20)
                push((shift_in() | b & 0x0c) ~ 0x20)
                push(0x20)
                push((shift_in() | b & 0x10) ~ 0x20)
            else
                push((shift_in() | b & 0x01) ~ 0x20)
                push((shift_in() | b & 0x06) ~ 0x20)
                push((shift_in() | b & 0x18) ~ 0x20)
                push(0x20)
            end
        elseif steeringBits == 0x00 then
            if num_in() < 1 then return nil end    -- next byte is encrypted data
            push(shift_in() | b & 0x13)
        else
            return nil   -- (shouldn't happen)
        end
    end
    return perl.pack('C*', table.unpack(out))
end

--------------------------------------------------------------------------------
-- Determine correct ordering of enciphered digits (unit digits of seconds)
-- Inputs: 0) starting character code, 1) lookup for next character(s) in sequence
--         2) i/o list of ordered characters, 3) hash of used characters
-- Returns: true if a consistent ordering was found
-- - loops through all possible orders based on $next sequence until a complete
--   cycle is established
-- - this complexity is necessary because GPS may skip some seconds
function LigoGPS.OrderCipherDigits(ch, next_, order, did)
    if not did then did = { } end
    while next_[ch] do
        if #order < 10 then
            if did[ch] then break end
        else
            -- success if we have cycled through all 10 digits and back to the first
            if #order == 10 and ch == order[1] then return 1 end
            break
        end
        order[#order + 1] = ch
        did[ch] = 1
        -- continue with next character if there is only one possibility
        if #next_[ch] == 1 then
            ch = next_[ch][1]
        else
            -- otherwise, test all possibilities
            local n = #order
            for _, c in ipairs(next_[ch]) do
                local did2 = { }  -- make a copy of the used-character lookup
                for k, v in pairs(did) do did2[k] = v end
                if LigoGPS.OrderCipherDigits(c, next_, order, did2) == 1 then return 1 end
                for k = #order, n + 1, -1 do order[k] = nil end   -- restore order and try next possibility
            end
            break
        end
    end
    return 0 -- failure
end

--------------------------------------------------------------------------------
-- Decipher and parse LIGOGPSINFO record (starting with "####")
-- Inputs: 0) ExifTool ref, 1) enciphered string, 2) tag table ref
--         3) true if GPS coordinates don't need de-fuzzing
-- Returns: true if this looked like an enciphered string
-- Notes: handles contained tags, but may defer handling until full cipher is known
function LigoGPS.DecipherLigoGPS(et, str, tagTbl, noFuzz)

    -- (enciphered characters must be in the range 0x30-0x5f ('0' - '_'))
    local m1, m2, m3, m4 = matches(str,
        [[(?s)^####.{4}([0-_])[0-_]{3}/[0-_]{2}/[0-_]{2} ..([0-_])..([0-_]).([0-_]) ]])
    if m1 == nil then return nil end
    if m2 ~= m3 then return nil end   -- (colons in time string must be the same)

    local cipherInfo = et.LigoCipher
    if not cipherInfo then
        cipherInfo = { cache = { }, ['next'] = { } }
        et.LigoCipher = cipherInfo
        et:AddCleanup(LigoGPS.CleanupCipher)
    end
    local decipher = cipherInfo.decipher
    local cache = cipherInfo.cache

    -- determine the cipher code table based on the advancing 1's digit of seconds
    if not decipher then
        cache[#cache + 1] = str     -- cache records until we can decipher them
        local next_ = cipherInfo['next']
        local millennium, colon, ch2 = m1, m2, m4
        -- determine the cipher lookup table
        -- (only characters in range 0x30-0x5f are encrypted)
        local ch1 = cipherInfo.ch1
        cipherInfo.ch1 = ch2
        if not D(ch1) or ch1 == ch2 then return 1 end -- ignore duplicate sequential digits
        if next_[ch1] then
            for _, c in ipairs(next_[ch1]) do
                if c == ch2 then return 1 end       -- don't add twice
            end
            next_[ch1][#next_[ch1] + 1] = ch2
        else
            next_[ch1] = { ch2 }
        end
        -- must wait until the lookup contains all 10 digits
        local nKeys = 0
        for _ in pairs(next_) do nKeys = nKeys + 1 end
        if nKeys < 10 then return 1 end
        -- protect against trying to decipher bad data
        if nKeys > 10 then cipherInfo['next'] = { } return 1 end
        local order, two = { }, nil
        if LigoGPS.OrderCipherDigits(ch1, next_, order) == 0 then return 1 end
        -- get index of enciphered "2" in ordered array
        for _ = 0, 9 do
            if order[_ + 1] == millennium then two = _ break end
        end
        if not D(two) then et:Warn('Problem deciphering LIGOGPSINFO') return 1 end
        cipherInfo['next'] = nil            -- all done with 'next' lookup
        local decipherTbl = { [colon] = ':' }   -- (':' is the time separator)
        for _ = 0, 9 do
            local ch = order[(_ + two - 2 + 10) % 10 + 1]
            decipherTbl[ch] = string.char(_ + 0x30)
        end
        -- may also know the lat/lon quadrant from the signs of the coordinates
        local hasQuad, q1, q2, q3, q4 = isMatchDyn(str, ' ([0-_])' .. colon .. '(-?).*? ([0-_])' .. colon .. '(-?)')
        if hasQuad then
            decipherTbl[q1] = q2 ~= '' and 'S' or 'N'
            decipherTbl[q3] = q4 ~= '' and 'W' or 'E'
            if q2 == '' and q4 == '' then
                local ns, ew = q1, q3
                local quad = { matches(et.OPTIONS.GPSQuadrant or '', [[(?i)^([NS])([EW])$]]) }
                if ExifTool.perlTruthy(et.OPTIONS.GPSQuadrant) and #quad > 0 then
                    decipherTbl[ns] = uc(quad[1])
                    decipherTbl[ew] = uc(quad[2])
                else
                    et:Warn('May need to set API GPSQuadrant option (eg. "NW")')
                end
            end
        end
        -- fill in unknown entries with '?' (only chars 0x30-0x5f are enciphered)
        for _ = 0x30, 0x5f do
            local ch = string.char(_)
            if not D(decipherTbl[ch]) then decipherTbl[ch] = '?' end
        end
        decipher = decipherTbl
        cipherInfo.decipher = decipherTbl
        str = table.remove(cache, 1)   -- start deciphering at oldest cache entry
    end

    -- apply reverse cipher and extract GPS information
    repeat
        local pre = substr(str, 4, 4)                   -- save second 4 bytes of header
        str = subst(substr(str, 8), [[\0+$]], '')       -- remove 8-byte header and null padding
        str = subst(str, '([0-_])', function(c) return decipher[c] end, 'g')  -- decipher
        if perl.num(et.OPTIONS.Verbose) > 1 then
            et:VPrint(1, et.INDENT .. '(Deciphered: ' .. perl.unpack('H8', pre) .. ' ' .. str .. ')\n')
        end
        -- add back leading 4 bytes (int16u counter plus 2 unknown bytes), and parse
        LigoGPS.ParseLigoGPS(et, pre .. str, tagTbl, noFuzz)
        str = table.remove(cache, 1)
    until not str

    return 1
end

--------------------------------------------------------------------------------
-- Parse decrypted/deciphered (but not defuzzed) LIGOGPSINFO record
-- (record starts with 4-byte int32u counter followed by date/time, etc)
-- Inputs: 0) ExifTool ref, 1) GPS string, 2) tag table ref,
--         3) flags: 0x01=not fuzzed, 0x02=spd in km/h
-- Returns: nothing
function LigoGPS.ParseLigoGPS(et, str, tagTbl, flags)

    -- example string input
    -- "....2022/09/19 12:45:24 N:31.285065 W:124.759483 46.93 km/h x:-0.000 y:-0.000 z:-0.000"
    local time, latRef, latNeg, lat, lonRef, lonNeg, lon, spd = matches(str,
        [[(?s)^.{4}(\S+ \S+)\s+([NS?]):(-?)([.\d]+)\s+([EW?]):(-?)([\.\d]+)\s+([.\d]+)]])
    if time == nil then
        et:Warn('LIGOGPSINFO format error')
        return
    end
    if not flags then flags = 0 end
    local gpsScl = { [1] = 1.524855137, [2] = 1.456027985, [3] = 1.15368 }
    local spdScl = (flags & 0x01) ~= 0 and ((flags & 0x02) ~= 0 and 1 or knotsToKph) or 1.85407333
    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
    et.DOC_NUM = et.DOC_COUNT
    time = time:gsub('/', ':')
    -- convert from DDMM.MMMMMM to DD.DDDDDD if necessary
    -- (speed wasn't scaled in my 1 sample with this format)
    if matches(lat, [[^\d{3}]]) then
        lat, lon = require('lexiftool.QuickTimeStream').ConvertLatLon(perl.num(lat), perl.num(lon))
        spdScl = 1
    end
    lat, lon, spd = perl.num(lat), perl.num(lon), perl.num(spd)
    if (flags & 0x01) == 0 then -- unfuzz the coordinates if necessary
        local scl = ExifTool.perlTruthy(et.OPTIONS.LigoGPSScale) and et.OPTIONS.LigoGPSScale or et.LigoGPSScale or 1
        if gpsScl[tonumber(scl)] then scl = gpsScl[tonumber(scl)] end
        lat, lon = LigoGPS.UnfuzzLigoGPS(lat, lon, scl)
    end
    -- a final sanity check
    if lat > 90 or lon > 180 then et:Warn('LIGOGPSINFO coordinates out of range') return end
    et.SET_GROUP1 = 'LIGO'
    et:HandleTag(tagTbl, 'GPSDateTime',  time)
    -- (ignore N/S/E/W if coordinate is signed)
    et:HandleTag(tagTbl, 'GPSLatitude',  lat * ((latNeg ~= '' or latRef == 'S') and -1 or 1))
    et:HandleTag(tagTbl, 'GPSLongitude', lon * ((lonNeg ~= '' or lonRef == 'W') and -1 or 1))
    et:HandleTag(tagTbl, 'GPSSpeed',     spd * spdScl)
    local trk = (matches(str, [[\bA:(\S+)]]))
    if trk then et:HandleTag(tagTbl, 'GPSTrack', trk) end
    local alt = (matches(str, [[\bH:(\S+)]]))
    if alt then et:HandleTag(tagTbl, 'GPSAltitude', alt) end
    local mag = (matches(str, [[\bM:(\S+)]]))
    if mag then et:HandleTag(tagTbl, 'MagneticVariation', mag) end
    -- (have a sample where tab is used to separate acc components)
    local ax, ay, az = matches(str, [[x:(\S+)\sy:(\S+)\sz:(\S+)]])
    if ax then et:HandleTag(tagTbl, 'Accelerometer', ax .. ' ' .. ay .. ' ' .. az) end
    et.SET_GROUP1 = nil
end

--------------------------------------------------------------------------------
-- Process GKU dashcam trailer containing JSON-format LigoGPS
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function LigoGPS.ProcessGKU(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local pos = unpack_('V', dataPt)
    if pos + 13 > #dataPt or substr(dataPt, pos, 13) ~= 'LIGOGPSINFO {' then return 0 end
    -- (upstream sets pos($$dataPt) here; the port passes the position on)
    return LigoGPS.ProcessLigoJSON(et, dirInfo, tagTbl, pos)
end

--------------------------------------------------------------------------------
-- Process LIGOGPSINFO data (non-JSON format)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
--         3) 1=LIGOGPS lat/lon/spd weren't fuzzed
-- Returns: 1 on success
-- Notes:  The directory data should start with the string "LIGOGPSINFO\0"
function LigoGPS.ProcessLigoGPS(et, dirInfo, tagTbl, noFuzz)
    local dataPt = dirInfo.DataPt
    local pos = (dirInfo.DirStart or 0) + 0x14
    if pos > #dataPt then return nil end
    local cipherInfo = et.LigoCipher
    local dirName = dirInfo.DirName or 'LigoGPS'
    if not dirInfo.DirID then et.PATH[#et.PATH + 1] = dirName end
    -- not fuzzed if header =~ /LIGOGPSINFO\0\0\0\0[\x01\x14]/ (\x01=BlueSkySeaDV688)
    if matches(substr(dataPt, pos - 8, 4), [==[^\0\0\0[\x01\x14]]==]) then noFuzz = 1 end
    et:VerboseDir(dirName)
    while pos + 0x84 <= #dataPt do
        local dat = substr(dataPt, pos, 0x84)
        local skip = false
        if not matches(dat, [[^####]]) then
            -- (have seen blank records filled with zeros, so keep trying)
            if matches(dat, [[(?s)^.{4}\d{4}/\d{2}/\d{2} ]]) then
                -- non-encrypted format written by Redtiger F9 4K
                dat = subst(dat, [[\0+$]], '')   -- remove trailing nulls
                LigoGPS.ParseLigoGPS(et, dat, tagTbl, 0x03)
            end
            skip = true
        end
        if not skip then
            -- decipher if we already know the encryption
            if cipherInfo and cipherInfo.decipher and LigoGPS.DecipherLigoGPS(et, dat, tagTbl, noFuzz) then
                skip = true
            end
        end
        if not skip then
            local str = LigoGPS.DecryptLigoGPS(dat)
            if not D(str) then
                LigoGPS.DecipherLigoGPS(et, dat, tagTbl, noFuzz)   -- try to decipher
            else
                if perl.num(et.OPTIONS.Verbose) > 1 then
                    et:VPrint(1, et.INDENT .. '(Decrypted: ' .. ExifTool.NumStr(unpack_('V', str)) ..
                        ' ' .. substr(str, 4) .. ')\n')
                end
                LigoGPS.ParseLigoGPS(et, str, tagTbl, noFuzz)
            end
        end
        pos = pos + 0x84
    end
    if not dirInfo.DirID then table.remove(et.PATH) end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process LIGOGPSINFO JSON-format GPS (Yada RoadCam Pro 4K BT58189)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Sample data (chained 512-byte records starting like this):
-- 0000: 4c 49 47 4f 47 50 53 49 4e 46 4f 20 7b 22 48 6f [LIGOGPSINFO {"Ho]
-- 0010: 75 72 22 3a 20 22 32 33 22 2c 20 22 4d 69 6e 75 [ur": "23", "Minu]
-- 0020: 74 65 22 3a 20 22 31 30 22 2c 20 22 53 65 63 6f [te": "10", "Seco]
-- 0030: 6e 64 22 3a 20 22 32 32 22 2c 20 22 59 65 61 72 [nd": "22", "Year]
-- 0040: 22 3a 20 22 32 30 32 33 22 2c 20 22 4d 6f 6e 74 [": "2023", "Mont]
-- 0050: 68 22 3a 20 22 31 32 22 2c 20 22 44 61 79 22 3a [h": "12", "Day":]
-- 0060: 20 22 32 38 22 2c 20 22 73 74 61 74 75 73 22 3a [ "28", "status":]
function LigoGPS.ProcessLigoJSON(et, dirInfo, tagTbl, pos)
    local dataPt = dirInfo.DataPt
    local _ = dirInfo.DirLen  -- (upstream's $dirLen is unused as well)
    local Import = require('lexiftool.Import')
    pos = pos or 0
    et:VerboseDir('LIGO_JSON', nil, #dataPt - pos)
    et.SET_GROUP1 = 'LIGO'
    while true do
        local json, endPos = matches(dataPt, [[(?s)LIGOGPSINFO (\{.*?\})]], pos)
        if json == nil then break end
        pos = endPos
        local dbase = { }
        Import.ReadJSON({ ref = 'SCALAR', value = json }, dbase)
        local info = dbase['*']
        if info then
            -- my sample contains the following JSON fields (in this order):
            -- Hour Minute Second Year Month Day (GPS UTC time)
            -- status NS EW Latitude Longitude Speed (speed in knots)
            -- GsensorX GsensorY GsensorZ (units? - only seen "000" for all)
            -- MHour MMinute MSecond MYear MMonth MDay (local dashcam clock time)
            -- OLatitude OLongitude (? same values as Latitude/Longitude)
            if D(info.status) and info.status == 'A' then -- only read if GPS is active
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                local num = 0
                for _, k in ipairs({ 'Year', 'Month', 'Day', 'Hour', 'Minute', 'Second' }) do
                    if D(info[k]) then num = num + 1 end
                end
                if num == 6 then
                    -- this is the GPS time in UTC
                    local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', tonumber(info.Year),
                        tonumber(info.Month), tonumber(info.Day), tonumber(info.Hour),
                        tonumber(info.Minute), tonumber(info.Second))
                    et:HandleTag(tagTbl, 'GPSDateTime', time)
                end
                if ExifTool.perlTruthy(info.Latitude) and ExifTool.perlTruthy(info.Longitude) then
                    local lat = perl.num(info.Latitude)
                    if info.NS and info.NS == 'S' then lat = -lat end
                    local lon = perl.num(info.Longitude)
                    if info.EW and info.EW == 'W' then lon = -lon end
                    et:HandleTag(tagTbl, 'GPSLatitude', lat)
                    et:HandleTag(tagTbl, 'GPSLongitude', lon)
                end
                if D(info.Speed) then et:HandleTag(tagTbl, 'GPSSpeed', perl.num(info.Speed) * knotsToKph) end
                if D(info.GsensorX) and D(info.GsensorY) and D(info.GsensorZ) then
                    -- (don't know conversion factor for accel data, so leave it raw for now)
                    et:HandleTag(tagTbl, 'Accelerometer', info.GsensorX .. ' ' .. info.GsensorY .. ' ' .. info.GsensorZ)
                end
                num = 0
                for _, k in ipairs({ 'MYear', 'MMonth', 'MDay', 'MHour', 'MMinute', 'MSecond' }) do
                    if D(info[k]) then num = num + 1 end
                end
                if num == 6 then
                    -- this is the dashcam clock time (local time zone)
                    local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', tonumber(info.MYear),
                        tonumber(info.MMonth), tonumber(info.MDay), tonumber(info.MHour),
                        tonumber(info.MMinute), tonumber(info.MSecond))
                    et:HandleTag(tagTbl, 'DateTimeOriginal', time)
                end
                if D(info.OLatitude) and D(info.OLongitude) then
                    local lat = perl.num(info.OLatitude)
                    if info.NS and info.NS == 'S' then lat = -lat end
                    local lon = perl.num(info.OLongitude)
                    if info.EW and info.EW == 'W' then lon = -lon end
                    et:HandleTag(tagTbl, 'GPSLatitude2', lat)
                    et:HandleTag(tagTbl, 'GPSLongitude2', lon)
                end
                if not ExifTool.perlTruthy(et:Options('ExtractEmbedded')) then
                    et:Warn('Use the ExtractEmbedded option to extract all timed GPS', 3)
                    break
                end
            end
        end
    end
    et.DOC_NUM = nil
    et.SET_GROUP1 = nil
    return 1
end

return LigoGPS
