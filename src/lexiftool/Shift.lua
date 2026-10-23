--------------------------------------------------------------------------------
-- File:         lexiftool/Shift.lua
-- Ported from:  lib/Image/ExifTool/Shift.pl
--
-- Description:  ExifTool time shifting routines
--
-- Revisions:    10/28/2005 - P. Harvey Created
--               03/13/2019 - PH Added single-argument form of ShiftTime()
--
-- Port notes:   ported subset: ApplyShift/ShiftTime/SplitTime/ShiftComponents/
--               ShiftNumber/CheckShift/DaysInMonth.  ShiftTime takes the
--               ShiftOffset hash (upstream's timegm/gmtime cache, which applies
--               the delta of the FIRST shifted value to all later ones -- so a
--               one-month shift moves every value by the same number of days,
--               as GlobalTimeShift needs, and ApplyShift per new-value hash).
--               ShiftTime returns the shifted string and the error (Lua has
--               no `$_[0]` alias), so in an advanced formatting expression
--               it is the `ShiftTime` helper that Writer.InsertTagValues
--               hands to perl.eval: the single-argument form
--               ("${TAG;ShiftTime(SHIFT)}") shifts the expression's `$_`,
--               the other one ("ShiftTime($_, SHIFT)") stores the result in
--               its first argument through perl.setArg, as `$_[0] = $val`.
--------------------------------------------------------------------------------

local Shift = {}

local perl = require('lexiftool.perl')
local sprintf = perl.sprintf

-- truncate toward zero (Perl int())
local function trunc(v)
    return v < 0 and math.ceil(v) or math.floor(v)
end

-- Perl `$v || 0`: the value unless it is false ('', '0' or undef)
local function perlOr0(v)
    if v == nil or v == '' or v == '0' then return 0 end
    return v
end

-- sign of a number (Perl <=> 0)
local function sgn(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

--------------------------------------------------------------------------------
-- apply shift to value in new value hash
-- Inputs: 0) ExifTool ref, 1) shift type ('Time' or 'Number'), 2) shift string,
--         3) raw date/time value, 4) new value hash ref
-- Returns: error string or nil on success and updates value in new value hash
function Shift.ApplyShift(et, func, shift, val, nvHash)
    -- get shift direction from first character in shift string
    local pre = perl.matches(shift, [[^([+-])]])
    local dir = 1
    if pre then
        shift = perl.subst(shift, [=[^[+-]]=], '')
        if pre == '-' then dir = -1 end
    end
    local tagInfo = nvHash.TagInfo
    local tag = tagInfo and tagInfo.Name
    local shiftOffset
    if nvHash.ShiftOffset then
        shiftOffset = nvHash.ShiftOffset
    else
        shiftOffset = { }
        nvHash.ShiftOffset = shiftOffset
    end

    -- shift is applied to ValueConv value, so we must ValueConv-Shift-ValueConvInv
    local err
    for _, stage in ipairs({ 'ValueConv', 'Shift', 'ValueConvInv' }) do
        if stage == 'Shift' then
            local shifted, serr = Shift['Shift' .. func](val, shift, dir, shiftOffset)
            if serr then
                err = serr
            else
                val = shifted
            end
        elseif tagInfo[stage] then
            local conv = tagInfo[stage]
            if type(conv) == 'function' then
                -- (upstream calls a CODE-ref conv as `&$conv($val, $self)`;
                --  this port's convs take (self, val) -- see conventions.md)
                val = conv(et, val)
            else
                return "Can't handle " .. stage .. " for " .. tag .. " in ApplyShift()"
            end
        else
            goto next_stage
        end
        if err then return err end
        ::next_stage::
    end
    -- update value in new value hash
    nvHash.Value = { val }
    return nil -- success
end

--------------------------------------------------------------------------------
-- Check date/time shift
-- Inputs: 0) shift type, 1) shift string (without sign)
-- Returns: updated shift string, or nil on error (and may update shift)
function Shift.CheckShift(type, shift)
    local err
    if type == 'Time' then
        local pre = perl.matches(shift, [[^([+-])]])
        if not pre then return "No shift direction" end
        -- do a test shift to validate the shift string
        local testTime = '2005:11:02 09:00:13.25-04:00'
        local _, serr = Shift.ShiftTime(testTime, perl.subst(shift, [=[^[+-]]=], ''),
                                       pre == '+' and 1 or -1)
        err = serr
    else
        err = "Unknown shift type (" .. type .. ")"
    end
    return err
end

--------------------------------------------------------------------------------
-- return the number of days in a month
-- Inputs: 0) month number (Jan=1, may be outside range), 1) year
-- Returns: number of days in month
function Shift.DaysInMonth(mon, year)
    -- (numbers as Perl's numeric operators see them: a caller's Perl code
    --  passes strings)
    mon, year = perl.num(mon), perl.num(year)
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    -- adjust to the range [1,12]
    while mon < 1 do
        mon = mon + 12
        year = year - 1
    end
    while mon > 12 do
        mon = mon - 12
        year = year + 1
    end
    -- return standard number of days unless february on a leap year
    if not (mon == 2 and year % 4 == 0) then return days[mon] end
    -- leap years don't occur on even centuries except every 400 years
    if year % 100 ~= 0 or year % 400 == 0 then return 29 end
    return 28
end

--------------------------------------------------------------------------------
-- split times into corresponding components: YYYY mm dd HH MM SS tzh tzm
-- Inputs: 0) date/time or shift string 1) table to receive components
--         2) optional table of time components (if shift string)
-- Returns: true on success
-- Returned components are 0-Y, 1-M, 2-D, 3-hr, 4-min, 5-sec, 6-tzhr, 7-tzmin
function Shift.SplitTime(val, vals, time)
    -- insert zeros if missing in shift string
    if time then
        val = perl.subst(val, [[(^|[-+:\s]):]], '${1}0:', 'g')
        val = perl.subst(val, [[:([:\s]|$)]], ':0$1', 'g')
    end
    -- change dashes to colons in date (for XMP dates)
    if perl.matches(val, [[^(\d{4})-(\d{2})-(\d{2})]]) then
        val = perl.subst(val, [[^(\d{4})-(\d{2})-(\d{2})]], '$1:$2:$3')
        val = perl.subst(val, 'T', ' ', 'g') -- change 'T' separator to ' '
    end
    -- add space before timezone to split it into a separate word
    val = perl.subst(val, [[(\+|-)]], ' $1')
    local words = perl.split(' ', val)
    local err = false
    local v = { }
    local wi = 1
    while true do
        local word = words[wi]
        if word == nil then break end
        wi = wi + 1
        -- split word into separate numbers (allow decimal points but no signs)
        local nums = perl.findAll(word, [[(?=\d|\.\d)\d*(?:\.\d*)?]])
        if #nums == 0 then break end
        local nextWord = words[wi]
        if perl.matches(word, [[^([+-])]]) then
            -- this is the timezone
            if v[6] ~= nil or #nums > 2 then err = true; break end
            local sign = word:sub(1, 1) ~= '-' and 1 or -1
            v[6] = sign * (tonumber(nums[1]) or 0)
            v[7] = sign * (tonumber(nums[2]) or 0)
        elseif (nextWord ~= nil and perl.matches(nextWord, [[^\d+]])) or
               (not time and perl.matches(nums[1] or '', [[^\d{3}]])) or
               (time and time[3] == nil and v[0] == nil) then
            -- this is a date (must come first)
            if next(v) ~= nil or #nums > 3 then err = true; break end
            if not time and #nums ~= 3 then err = true; break end
            -- (the components are stored as numbers here, where Perl keeps
            --  the strings; the year's string is kept as well because
            --  ShiftTime compares it with 'eq', which a year 0 read as a
            --  number could never satisfy, and all of Perl's strings in
            --  `_str`, which ShiftTime hands to timegm so that its croak
            --  quotes them like upstream: "Day '00' out of range 1..31")
            v._year = nums[#nums - 2]
            local s2 = table.remove(nums) -- day first if only one specified
            local s1 = perlOr0(table.remove(nums))
            local s0 = perlOr0(table.remove(nums))
            v._str = v._str or { }
            v._str[2], v._str[1], v._str[0] = s2, s1, s0
            v[2] = tonumber(s2) or 0
            v[1] = tonumber(s1) or 0
            v[0] = tonumber(s0) or 0
        else
            -- this is a time (can't come after timezone)
            if v[3] ~= nil or v[6] ~= nil or #nums > 3 then err = true; break end
            if not time and #nums ~= 3 and #nums ~= 2 then err = true; break end
            local sRaw = nums[#nums] -- save raw seconds string for decimal count
            local s3 = table.remove(nums, 1) -- hour first if only one specified
            local s4 = perlOr0(table.remove(nums, 1))
            local s5 = perlOr0(table.remove(nums, 1))
            v._str = v._str or { }
            v._str[3], v._str[4], v._str[5] = s3, s4, s5
            v[3] = tonumber(s3) or 0
            v[4] = tonumber(s4) or 0
            v[5] = tonumber(s5) or 0
            local sdec = sRaw and sRaw:match('%.(%d+)')
            if sdec then v._dec = #sdec end
        end
    end
    if err or next(v) == nil then return false end
    if time then
        -- zero any required shift entries which aren't yet defined
        if time[0] ~= nil and v[0] == nil then v[0], v[1], v[2] = 0, 0, 0 end
        if time[3] ~= nil and v[3] == nil then v[3], v[4], v[5] = 0, 0, 0 end
        if time[6] ~= nil and v[6] == nil then v[6], v[7] = 0, 0 end
    end
    for k, vv in pairs(v) do vals[k] = vv end -- return split time components
    return true
end

--------------------------------------------------------------------------------
-- shift date/time by components
-- Inputs: 0) split date/time table, 1) split shift table,
--         2) shift direction, 3) table to receive shifted components
--         4) number of decimal points in seconds
--         5) reference to return time difference due to rounding
--            (a table: the difference lands in rndPt[1], Perl's `$$rndPt`)
-- Returns: error string or nil on success
function Shift.ShiftComponents(time, shift, dir, toTime, dec, rndPt)
    -- min/max for Y, M, D, h, m, s
    local min = { [0] = 0, [1] = 1, [2] = 1, [3] = 0, [4] = 0, [5] = 0 }
    local max = { [0] = 10000, [1] = 12, [2] = 28, [3] = 24, [4] = 60, [5] = 60 }
    -- apply the shift
    local c = 0
    for i = 0, 7 do
        local v = (time[i] or 0) + dir * (shift[i] or 0) + c
        -- handle fractional values by propagating remainders downwards
        local iv, frac = math.modf(v)
        if frac ~= 0 and i < 5 then
            c = frac * max[i + 1]
            v = iv
        else
            c = 0
        end
        toTime[i] = v
    end
    -- round off seconds to the required number of decimal points
    local sec = toTime[5]
    if sec ~= nil then
        local _, sfrac = math.modf(sec)
        if sfrac ~= 0 then
            local mult = 10 ^ dec
            local rndSec = trunc(sec * mult + 0.5 * sgn(sec)) / mult
            if rndPt then rndPt[1] = sec - rndSec end
            toTime[5] = rndSec
        end
    end
    -- handle overflows, starting with least significant number first (seconds)
    c = 0
    for i = 5, 0, -1 do
        if time[i] == nil then
            c = 0
        else
            -- apply shift and adjust for previous overflow
            local v = toTime[i] + c
            c = 0 -- set carry to zero
            -- adjust for over/underflow
            local mmin, mmax = min[i], max[i]
            if v < mmin then
                if i == 2 then -- 2 = day of month
                    repeat
                        c = c - 1
                        local mon = toTime[i - 1] + c
                        v = v + Shift.DaysInMonth(mon, toTime[i - 2])
                    until v >= 1
                else
                    local fc = (v - mmin) / mmax
                    -- carry (c) must be largest integer equal to or less than fc
                    c = math.floor(fc)
                    if c > fc then c = c - 1 end
                    v = v - c * mmax
                end
            elseif v >= mmax + mmin then
                if i == 2 then
                    while true do
                        -- test against number of days in current month
                        local mon = toTime[i - 1] + c
                        local days = Shift.DaysInMonth(mon, toTime[i - 2])
                        if v <= days then break end
                        v = v - days
                        c = c + 1
                        if v <= 28 then break end
                    end
                else
                    local fc = (v - mmax - mmin) / mmax
                    -- carry (c) must be smallest integer greater than fc
                    c = math.floor(fc)
                    if c <= fc then c = c + 1 end
                    v = v - c * mmax
                end
            end
            toTime[i] = v -- save the new value
        end
    end
    -- handle overflows in timezone
    if toTime[6] ~= nil then
        local m = toTime[6] * 60 + toTime[7]
        m = m + 0.5 * sgn(m) -- avoid round-off errors
        toTime[6] = trunc(m / 60)
        toTime[7] = trunc(m - toTime[6] * 60)
    end
    return nil -- success
end

--------------------------------------------------------------------------------
-- Shift an integer or floating-point number
-- Inputs: 0) date/time string, 1) shift string, 2) shift direction (+1 or -1)
-- Returns: shifted value
function Shift.ShiftNumber(val, shift, dir)
    return tonumber(val) + tonumber(shift) * dir
end

--------------------------------------------------------------------------------
-- Shift date/time string
-- Inputs: 0) date/time string, 1) shift string, 2) shift direction (+1 or -1),
--            or 0 or undef to take shift direction from sign of shift,
--         3) reference to ShiftOffset hash (with Date, DateTime, Time, Timezone keys)
--   or    0) shift string (and operates on $_)
--            (port: the ShiftTime helper of Writer.InsertTagValues, see Port notes)
-- Returns: shifted value, or nil, error string
-- (upstream returns undef on success and shifts $_[0] in place; Lua strings
--  are values, so the shifted string is returned instead)
function Shift.ShiftTime(val, shift, dir, shiftOffset)
    local time = { }
    local shiftT = { }
    local toTime = { }
    local mode, needShiftOffset, dec

    -- take shift direction from sign of shift string if direction not specified
    if not dir or dir == 0 then
        local pre = perl.matches(shift, [[^([+-])]])
        if pre then
            shift = perl.subst(shift, [=[^[+-]]=], '')
            dir = pre == '-' and -1 or 1
        else
            dir = 1
        end
    end

    -- figure out what we are dealing with (time, date or date/time)
    if not Shift.SplitTime(val, time) then return nil, "Invalid time string (" .. val .. ")" end
    if time[0] ~= nil then
        if time._year == '0000' then return nil, "Can't shift from year 0000" end
        mode = time[3] ~= nil and 'DateTime' or 'Date'
    elseif time[3] ~= nil then
        mode = 'Time'
    else
        mode = ''
    end
    dec = time._dec or 0 -- number of digits after the seconds decimal point
    if shiftOffset then
        if shiftOffset[mode] == nil then needShiftOffset = true end
        if time[6] ~= nil and shiftOffset.Timezone == nil then needShiftOffset = true end
    else
        needShiftOffset = true
    end
    if needShiftOffset then
        --
        -- apply date/time shift the hard way
        --
        if not Shift.SplitTime(shift, shiftT, time) then
            return nil, "Invalid shift string (" .. shift .. ")"
        end
        -- change 'Z' timezone to '+00:00' only if necessary
        if shiftT[6] ~= nil and time[6] == nil then
            if val:sub(-1) == 'Z' then
                val = val:sub(1, -2) .. '+00:00'
                time[6] = 0
                time[7] = 0
            end
        end
        local rndDiff = { }
        local err = Shift.ShiftComponents(time, shiftT, dir, toTime, dec, rndDiff)
        if err then return nil, err end
        --
        -- calculate and save the shift offsets for next time
        --
        if shiftOffset then
            if time[0] ~= nil or time[3] ~= nil then
                -- (sec, min, hour, mday, mon, year as for Time::Local::timegm)
                local tm1 = { 0, 0, 0, 1, 0, 2000 }
                local tm2 = { 0, 0, 0, 1, 0, 2000 }
                if time[0] ~= nil then
                    -- @tm1[3..5] = reverse @time[0..2]
                    tm1[4], tm1[5], tm1[6] = time[2], time[1], time[0]
                    tm2[4], tm2[5], tm2[6] = toTime[2], toTime[1], toTime[0]
                    tm1[5] = tm1[5] - 1 -- month should start from 0
                    tm2[5] = tm2[5] - 1
                end
                local diff = 0
                if time[3] ~= nil then
                    -- @tm1[0..2] = reverse @time[3..5]
                    tm1[1], tm1[2], tm1[3] = time[5], time[4], time[3]
                    tm2[1], tm2[2], tm2[3] = toTime[5], toTime[4], toTime[3]
                    -- handle fractional seconds separately
                    diff = tm2[1] - trunc(tm2[1]) - (tm1[1] - trunc(tm1[1]))
                    if rndDiff[1] ~= nil then diff = diff + rndDiff[1] end -- un-do rounding
                    tm1[1] = trunc(tm1[1])
                    tm2[1] = trunc(tm2[1])
                end
                -- (upstream's `eval q{...}`: a croak of Time::Local::timegm
                --  is caught, a Lua error is not)
                local ok, res = pcall(function()
                    return diff + perl.timegm(table.unpack(tm2)) - perl.timegm(table.unpack(tm1))
                end)
                if not ok and not perl.isDie(res) then error(res, 0) end
                -- not a problem if we failed here since we'll just try again next time,
                -- so don't return error message
                if ok then
                    diff = res
                    local m
                    if time[0] ~= nil then
                        m = time[3] ~= nil and 'DateTime' or 'Date'
                    else
                        m = 'Time'
                    end
                    shiftOffset[m] = diff
                end
            end
            if time[6] ~= nil then
                shiftOffset.Timezone = (toTime[6] - time[6]) * 60 +
                                       toTime[7] - time[7]
            end
        end
    else
        --
        -- apply shift from previously calculated offsets
        --
        if shiftOffset.Timezone and shiftOffset.Timezone ~= 0 and time[6] == nil then
            -- change 'Z' timezone to '+00:00' only if necessary
            if val:sub(-1) == 'Z' then
                val = val:sub(1, -2) .. '+00:00'
                time[6] = 0
                time[7] = 0
            end
        end
        -- apply the previous date/time shift if necessary
        if mode ~= '' then
            local tm = { 0, 0, 0, 1, 0, 2000 }
            -- (@tm[3..5] = reverse @time[0..2] -- Perl's strings, see SplitTime)
            local str = time._str or { }
            if time[0] ~= nil then
                tm[4], tm[5], tm[6] = str[2] or time[2], time[1], str[0] or time[0]
                tm[5] = tm[5] - 1 -- month should start from 0
            end
            if time[3] ~= nil then tm[1], tm[2], tm[3] = time[5], str[4] or time[4], str[3] or time[3] end
            -- save fractional seconds
            local frac = tm[1] - trunc(tm[1])
            tm[1] = trunc(tm[1])
            -- (upstream's `eval q{...}`; its croak is returned as the error)
            local ok, t = pcall(function() return perl.timegm(table.unpack(tm)) + frac end)
            if not ok then
                if not perl.isDie(t) then error(t, 0) end
                return nil, require('lexiftool').CleanWarning(t.msg)
            end
            t = t + shiftOffset[mode] -- apply the shift
            -- save fractional seconds in shifted time
            frac = t - trunc(t)
            if frac == 0 then
                t = math.tointeger(t) or t
            else
                t = trunc(t)
                -- must account for any rounding that could occur
                if frac + 0.5 * 10 ^ (-dec) >= 1 then t = t + 1; frac = 0 end
            end
            local g = perl.gmtime(t)
            -- @toTime = reverse @tm[0..5]; $toTime[0] += 1900; ++$toTime[1]
            toTime[0], toTime[1], toTime[2] = g[6] + 1900, g[5] + 1, g[4]
            toTime[3], toTime[4], toTime[5] = g[3], g[2], g[1] + frac -- add the fractional seconds back in
        end
        -- apply the previous timezone shift if necessary
        if time[6] ~= nil then
            local m = time[6] * 60 + time[7]
            m = m + shiftOffset.Timezone
            m = m + 0.5 * sgn(m) -- avoid round-off errors
            toTime[6] = trunc(m / 60)
            toTime[7] = trunc(m - toTime[6] * 60)
        end
    end

    -- insert shifted time components back into original string
    local pos = 0 -- Perl pos (0-based)
    for i = 0, 7 do
        if time[i] ~= nil and toTime[i] ~= nil then
            local v, d, s, en
            if i ~= 6 then -- not timezone hours
                local cap1, cap2, en1 = perl.matches(val, [[((?=\d|\.\d)\d*(\.\d*)?)]], pos)
                if not cap1 then break end
                if toTime[i] == time[i] then
                    pos = en1
                    goto next_i
                end
                v = cap1
                d = cap2
                s = ''
                en = en1
            else
                if time[6] == toTime[6] and time[7] == toTime[7] then break end
                local cap1, cap2, en1 = perl.matches(val, [[((?:\+|-)(?=\d|\.\d)\d*(\.\d*)?)]], pos)
                if not cap1 then break end
                v = cap1
                d = cap2
                en = en1
                if toTime[6] >= 0 and toTime[7] >= 0 then
                    s = '+'
                else
                    s = '-'
                    toTime[6] = -toTime[6]
                    toTime[7] = -toTime[7]
                end
            end
            local nv = toTime[i]
            local len = #v
            local sig = len - #s
            local decd = d and (#d - 1) or 0
            local newNum
            if decd > 0 then
                newNum = s .. sprintf('%0' .. sig .. '.' .. decd .. 'f', nv)
            else
                newNum = s .. sprintf('%0' .. sig .. 'd', nv)
            end
            -- replace the matched number (0-based [en-len, en-1])
            val = val:sub(1, en - len) .. newNum .. val:sub(en + 1)
            pos = en + #newNum - len
        end
        ::next_i::
    end
    return val, nil
end

return Shift
