--------------------------------------------------------------------------------
-- File:         lexiftool/Shift.lua
-- Ported from:  lib/Image/ExifTool/Shift.pl
--
-- Description:  ExifTool time shifting routines
--
-- Revisions:    10/28/2005 - P. Harvey Created
--               03/13/2019 - PH Added single-argument form of ShiftTime()
--
-- Port notes:   complete.  ShiftTime and ShiftNumber return the shifted
--               value and the error (Lua has no `$_[0]` alias), so in an
--               advanced formatting expression it is the `ShiftTime` helper
--               that Writer.InsertTagValues hands to perl.eval: the
--               single-argument form ("${TAG;ShiftTime(SHIFT)}") shifts the
--               expression's `$_`, the other one ("ShiftTime($_, SHIFT)")
--               stores the result in its first argument through
--               perl.setArg, as `$_[0] = $val`.  The split components keep
--               Perl's strings (a year '0000', seconds '13.25', the '00'
--               that Time::Local's croak quotes); arithmetic on them goes
--               through the facade's Perl numification.  ApplyShift's
--               conversions are Lua functions called as conv(self, val), its
--               `eval` a perl.pcall.
--------------------------------------------------------------------------------

local Shift = {}

local perl = require('lexiftool.perl')
local carray = require('carray')
local sprintf = perl.sprintf
local matches, isMatch, findAll = perl.matches, perl.isMatch, perl.findAll
local subst, substN = perl.subst, perl.substN
local split, shift, pop = perl.split, perl.shift, table.remove
local length, int, num = perl.length, perl.int, perl.num
local perlTruthy = perl.truthy

-- (port: the number of elements of a Perl array of time components, i.e.
--  the highest defined index plus one -- `@$time`, `@v`, `scalar @toTime`)
local function alen(t)
    for i = 7, 0, -1 do
        if t[i] ~= nil then return i + 1 end
    end
    return 0
end

-- (port: Perl's `$x || 0`)
local function or0(v)
    if perlTruthy(v) then return v end
    return 0
end

-- (port: Perl's `$x <=> 0`)
local function cmp0(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

--------------------------------------------------------------------------------
-- apply shift to value in new value hash
-- Inputs: 0) ExifTool ref, 1) shift type, 2) shift string, 3) raw date/time value,
--         4) new value hash ref
-- Returns: error string or undef on success and updates value in new value hash
function Shift.ApplyShift(self, func, shift_, val, nvHash)
    local ExifTool = require('lexiftool')

    -- get shift direction from first character in shift string
    local m1 = matches(shift_, [[^(\+|-)]])
    if m1 ~= nil then shift_ = subst(shift_, [[^(\+|-)]], '') end
    local pre = m1 ~= nil and m1 or '+'
    local dir = (pre == '+') and 1 or -1
    local tagInfo = nvHash.TagInfo
    local tag = tagInfo.Name
    local shiftOffset
    if perlTruthy(nvHash.ShiftOffset) then
        shiftOffset = nvHash.ShiftOffset
    else
        shiftOffset = { }
        nvHash.ShiftOffset = shiftOffset
    end

    -- initialize handler for eval warnings
    local oldWarn = perl.SIG.__WARN__   -- (local $SIG{'__WARN__'})
    perl.SIG.__WARN__ = ExifTool.SetWarning
    ExifTool.SetWarning(nil)

    -- shift is applied to ValueConv value, so we must ValueConv-Shift-ValueConvInv
    local err
    for _, type_ in ipairs({ 'ValueConv', 'Shift', 'ValueConvInv' }) do
        local evalErr
        if type_ == 'Shift' then
            --### eval ShiftXxx function
            local ok, res, res2 = perl.pcall(Shift['Shift' .. func], val, shift_, dir, shiftOffset)
            if ok then
                if res ~= nil then val = res end
                err = res2
            else
                evalErr = res
            end
        elseif perlTruthy(tagInfo[type_]) then
            local conv = tagInfo[type_]
            if type(conv) == 'function' then
                -- (a conversion is called as conv($self, $val), and the
                --  ported string conversion is a function too: its `eval`
                --  is the pcall)
                local ok, res = perl.pcall(conv, self, val)
                if ok then val = res else val, evalErr = nil, res end
            else
                perl.SIG.__WARN__ = oldWarn
                return "Can't handle " .. type_ .. " for " .. tag .. " in ApplyShift()"
            end
        else
            goto next_type
        end
        -- handle errors
        if perlTruthy(err) then perl.SIG.__WARN__ = oldWarn return err end
        if evalErr ~= nil then
            if not perl.isDie(evalErr) then perl.SIG.__WARN__ = oldWarn error(evalErr, 0) end
            ExifTool.SetWarning(evalErr.msg)
        end
        if perlTruthy(ExifTool.GetWarning()) then perl.SIG.__WARN__ = oldWarn return ExifTool.CleanWarning() end
        ::next_type::
    end
    perl.SIG.__WARN__ = oldWarn
    -- update value in new value hash
    nvHash.Value = { val }
    return nil  -- success
end

--------------------------------------------------------------------------------
-- Check date/time shift
-- Inputs: 0) shift type, 1) shift string (without sign)
-- Returns: updated shift string, or undef on error (and may update shift)
function Shift.CheckShift(type_, shift_)
    local err
    if type_ == 'Time' then
        local m1 = matches(shift_, [[^(\+|-)]])
        if m1 == nil then return "No shift direction" end
        shift_ = subst(shift_, [[^(\+|-)]], '')
        -- do a test shift to validate the shift string
        local testTime = '2005:11:02 09:00:13.25-04:00'
        local _
        _, err = Shift.ShiftTime(testTime, shift_, m1 == '+' and 1 or -1)
    else
        err = "Unknown shift type (" .. type_ .. ")"
    end
    return err
end

--------------------------------------------------------------------------------
-- return the number of days in a month
-- Inputs: 0) month number (Jan=1, may be outside range), 1) year
-- Returns: number of days in month
function Shift.DaysInMonth(mon, year)
    local days = { [0] = 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    -- adjust to the range [0,11]
    while mon < 1  do mon = mon + 12; year = year - 1 end
    while mon > 12 do mon = mon - 12; year = year + 1 end
    -- return standard number of days unless february on a leap year
    if not (num(mon, '==') == 2 and year % 4 == 0) then return days[int(mon - 1)] end
    -- leap years don't occur on even centuries except every 400 years
    if year % 100 ~= 0 or year % 400 == 0 then return 29 end
    return 28
end

--------------------------------------------------------------------------------
-- split times into corresponding components: YYYY mm dd HH MM SS tzh tzm
-- Inputs: 0) date/time or shift string 1) reference to list for returned components
--         2) optional reference to list of time components (if shift string)
-- Returns: true on success
-- Returned components are 0-Y, 1-M, 2-D, 3-hr, 4-min, 5-sec, 6-tzhr, 7-tzmin
-- (port: the lists are Lua tables indexed from 0, as Perl's arrays)
function Shift.SplitTime(val, vals, time)
    -- insert zeros if missing in shift string
    if time then
        val = subst(val, [[(^|[-+:\s]):]], '${1}0:', 'g')
        val = subst(val, [[:([:\s]|$)]], ':0$1', 'g')
    end
    -- change dashes to colons in date (for XMP dates)
    local n
    val, n = substN(val, [[^(\d{4})-(\d{2})-(\d{2})]], '$1:$2:$3')
    if n then
        val = perl.tr(val, 'T', ' ')    -- change 'T' separator to ' '
    end
    -- add space before timezone to split it into a separate word
    val = subst(val, [[(\+|-)]], ' $1')
    local words = split(' ', val)
    local err = 1
    local v = { }
    while true do
        local word = shift(words)
        if word == nil then break end
        -- split word into separate numbers (allow decimal points but no signs)
        -- (port: Perl's @vals, beside the argument $vals)
        local vals_ = findAll(word, [[(?=\d|\.\d)\d*(?:\.\d*)?]])
        if #vals_ == 0 then break end
        local m1 = matches(word, [[^(\+|-)]])
        if m1 ~= nil then
            -- this is the timezone
            if v[6] ~= nil or #vals_ > 2 then err = 1 break end
            local sign = (m1 ~= '-') and 1 or -1
            -- apply sign to both minutes and seconds
            v[6] = sign * shift(vals_)
            v[7] = sign * or0(shift(vals_))
        elseif (#words > 0 and isMatch(words[1], [[^\d+]])) or -- there is a time word to follow
            (not time and isMatch(vals_[1], [[^\d{3}]])) or -- first value is year (3 or more digits)
            (time and time[3] == nil and v[0] == nil) -- we don't have a time
        then
            -- this is a date (must come first)
            if alen(v) > 0 or #vals_ > 3 then err = 1 break end
            if not time and #vals_ ~= 3 then err = 1 break end
            v[2] = pop(vals_)       -- take day first if only one specified
            v[1] = or0(pop(vals_))
            v[0] = or0(pop(vals_))
        else
            -- this is a time (can't come after timezone)
            if v[3] ~= nil or v[6] ~= nil or #vals_ > 3 then err = 1 break end
            if not time and #vals_ ~= 3 and #vals_ ~= 2 then err = 1 break end
            v[3] = shift(vals_)     -- take hour first if only one specified
            v[4] = or0(shift(vals_))
            v[5] = or0(shift(vals_))
        end
        err = 0
    end
    if err ~= 0 or alen(v) == 0 then return 0 end
    if time then
        -- zero any required shift entries which aren't yet defined
        if time[0] ~= nil and v[0] == nil then v[0], v[1], v[2] = 0, 0, 0 end
        if time[3] ~= nil and v[3] == nil then v[3], v[4], v[5] = 0, 0, 0 end
        if time[6] ~= nil and v[6] == nil then v[6], v[7] = 0, 0 end
    end
    -- return split time components
    for i = 0, 7 do vals[i] = v[i] end
    return 1
end

--------------------------------------------------------------------------------
-- shift date/time by components
-- Inputs: 0) split date/time list ref, 1) split shift list ref,
--         2) shift direction, 3) reference to output list of shifted components
--         4) number of decimal points in seconds
--         5) reference to return time difference due to rounding
--            (port: a box, the difference lands in rndPt.value)
-- Returns: error string or undef on success
function Shift.ShiftComponents(time, shift_, dir, toTime, dec, rndPt)
    -- min/max for Y, M, D, h, m, s
    local min = { [0] =     0,  1,  1,  0,  0,  0 }
    local max = { [0] = 10000, 12, 28, 24, 60, 60 }
    local i
--
-- apply the shift
--
    local c = 0
    i = 0
    while i < alen(time) do
        local v = or0(time[i]) + dir * or0(shift_[i]) + c
        -- handle fractional values by propagating remainders downwards
        if v ~= int(v) and i < 5 then
            local iv = int(v)
            c = (v - iv) * max[i + 1]
            v = iv
        else
            c = 0
        end
        toTime[i] = v
        i = i + 1
    end
    -- round off seconds to the required number of decimal points
    local sec = toTime[5]
    if sec ~= nil and sec ~= int(sec) then
        local mult = 10 ^ dec
        local rndSec = int(sec * mult + 0.5 * cmp0(sec)) / mult
        if rndPt then rndPt.value = sec - rndSec end
        toTime[5] = rndSec
    end
--
-- handle overflows, starting with least significant number first (seconds)
--
    c = 0
    i = 5
    while i >= 0 do
        if time[i] == nil then c = 0 goto next_i end
        do
            -- apply shift and adjust for previous overflow
            local v = toTime[i] + c
            c = 0   -- set carry to zero
            -- adjust for over/underflow
            local min_, max_ = min[i], max[i]
            if v < min_ then
                if i == 2 then  -- 2 = day of month
                    repeat
                        -- add number of days in previous month
                        c = c - 1
                        local mon = toTime[i - 1] + c
                        v = v + Shift.DaysInMonth(mon, toTime[i - 2])
                    until v >= 1
                else
                    local fc = (v - min_) / max_
                    -- carry ($c) must be largest integer equal to or less than $fc
                    c = int(fc)
                    if c > fc then c = c - 1 end
                    v = v - c * max_
                end
            elseif v >= max_ + min_ then
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
                    local fc = (v - max_ - min_) / max_
                    -- carry ($c) must be smallest integer greater than $fc
                    c = int(fc)
                    if c <= fc then c = c + 1 end
                    v = v - c * max_
                end
            end
            toTime[i] = v   -- save the new value
        end
        ::next_i::
        i = i - 1
    end
    -- handle overflows in timezone
    if toTime[6] ~= nil then
        local m = toTime[6] * 60 + toTime[7]
        m = m + 0.5 * cmp0(m)       -- avoid round-off errors
        toTime[6] = int(m / 60)
        toTime[7] = int(m - toTime[6] * 60)
    end
    return nil  -- success
end

--------------------------------------------------------------------------------
-- Shift an integer or floating-point number
-- Inputs: 0) date/time string, 1) shift string, 2) shift direction (+1 or -1)
--         3) (unused)
-- Returns: undef and updates input value
-- (port: returns the shifted value, then undef)
function Shift.ShiftNumber(val, shift_, dir)
    return val + shift_ * dir, nil  -- return shifted value; success!
end

--------------------------------------------------------------------------------
-- Shift date/time string
-- Inputs: 0) date/time string, 1) shift string, 2) shift direction (+1 or -1),
--            or 0 or undef to take shift direction from sign of shift,
--         3) reference to ShiftOffset hash (with Date, DateTime, Time, Timezone keys)
--   or    0) shift string (and operates on $_)
--            (port: the ShiftTime helper of Writer.InsertTagValues, see Port notes)
-- Returns: error string or undef on success and date/time string is updated
-- (port: returns the shifted string and undef, or undef and the error string)
function Shift.ShiftTime(val, shift_, dir, shiftOffset)
    local time, shiftT, toTime = { }, { }, { }
    local mode, needShiftOffset, dec

    if not perlTruthy(dir) then
        local m1 = matches(shift_, [[^(\+|-)]])
        if m1 ~= nil then shift_ = subst(shift_, [[^(\+|-)]], '') end
        dir = (m1 ~= nil and m1 == '-') and -1 or 1
    end
--
-- figure out what we are dealing with (time, date or date/time)
--
    if not perlTruthy(Shift.SplitTime(val, time)) then return nil, "Invalid time string (" .. val .. ")" end
    if time[0] ~= nil then
        if perl.str(time[0]) == '0000' then return nil, "Can't shift from year 0000" end
        mode = time[3] ~= nil and 'DateTime' or 'Date'
    elseif time[3] ~= nil then
        mode = 'Time'
    else
        mode = ''
    end
    -- get number of digits after the seconds decimal point
    local d1
    if time[5] ~= nil then d1 = matches(time[5], [[\.(\d+)]]) end
    if d1 ~= nil then
        dec = length(d1)
    else
        dec = 0
    end
    if shiftOffset then
        if shiftOffset[mode] == nil then needShiftOffset = 1 end
        if time[6] ~= nil and shiftOffset.Timezone == nil then needShiftOffset = 1 end
    else
        needShiftOffset = 1
    end
    if needShiftOffset then
--
-- apply date/time shift the hard way
--
        if not perlTruthy(Shift.SplitTime(shift_, shiftT, time)) then
            return nil, "Invalid shift string (" .. shift_ .. ")"
        end

        -- change 'Z' timezone to '+00:00' only if necessary
        if alen(shiftT) > 6 and alen(time) <= 6 then
            local n
            val, n = substN(val, [[Z$]], '+00:00')
            if n then time[6], time[7] = 0, 0 end
        end
        local rndDiff = { }
        local err = Shift.ShiftComponents(time, shiftT, dir, toTime, dec, rndDiff)
        if perlTruthy(err) then return nil, err end
--
-- calculate and save the shift offsets for next time
--
        if shiftOffset then
            if time[0] ~= nil or time[3] ~= nil then
                -- (port: Perl's 0-based @tm1/@tm2 are 1-based lists here,
                --  in Time::Local::timegm's argument order)
                local tm1 = { 0, 0, 0, 1, 0, 2000 }
                local tm2 = { 0, 0, 0, 1, 0, 2000 }
                if time[0] ~= nil then
                    tm1[4], tm1[5], tm1[6] = time[2], time[1], time[0]          -- @tm1[3..5] = reverse @time[0..2]
                    tm2[4], tm2[5], tm2[6] = toTime[2], toTime[1], toTime[0]    -- @tm2[3..5] = reverse @toTime[0..2]
                    tm1[5] = tm1[5] - 1 -- month should start from 0
                    tm2[5] = tm2[5] - 1
                end
                local diff = 0
                if time[3] ~= nil then
                    tm1[1], tm1[2], tm1[3] = time[5], time[4], time[3]          -- @tm1[0..2] = reverse @time[3..5]
                    tm2[1], tm2[2], tm2[3] = toTime[5], toTime[4], toTime[3]    -- @tm2[0..2] = reverse @toTime[3..5]
                    -- handle fractional seconds separately
                    diff = tm2[1] - int(tm2[1]) - (tm1[1] - int(tm1[1]))
                    if rndDiff.value ~= nil then diff = diff + rndDiff.value end -- un-do rounding
                    tm1[1] = int(tm1[1])
                    tm2[1] = int(tm2[1])
                end
                local ok, res = perl.pcall(function()
                    return diff + perl.timegm(table.unpack(tm2, 1, 6)) - perl.timegm(table.unpack(tm1, 1, 6))
                end)
                if not ok and not perl.isDie(res) then error(res, 0) end
                -- not a problem if we failed here since we'll just try again next time,
                -- so don't return error message
                if ok then
                    diff = res
                    local mode_
                    if time[0] ~= nil then
                        mode_ = time[3] ~= nil and 'DateTime' or 'Date'
                    else
                        mode_ = 'Time'
                    end
                    shiftOffset[mode_] = diff
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
        if perlTruthy(shiftOffset.Timezone) and alen(time) <= 6 then
            -- change 'Z' timezone to '+00:00' only if necessary
            local n
            val, n = substN(val, [[Z$]], '+00:00')
            if n then time[6], time[7] = 0, 0 end
        end
        -- apply the previous date/time shift if necessary
        if perlTruthy(mode) then
            local tm = { 0, 0, 0, 1, 0, 2000 }
            if time[0] ~= nil then
                tm[4], tm[5], tm[6] = time[2], time[1], time[0]     -- @tm[3..5] = reverse @time[0..2]
                tm[5] = tm[5] - 1 -- month should start from 0
            end
            if time[3] ~= nil then tm[1], tm[2], tm[3] = time[5], time[4], time[3] end -- @tm[0..2] = reverse @time[3..5]
            -- save fractional seconds
            local frac = tm[1] - int(tm[1])
            tm[1] = int(tm[1])
            local ok, tm_ = perl.pcall(function()
                return perl.timegm(table.unpack(tm, 1, 6)) + frac
            end)
            if not ok then
                if not perl.isDie(tm_) then error(tm_, 0) end
                return nil, require('lexiftool').CleanWarning(tm_.msg)
            end
            tm_ = tm_ + shiftOffset[mode]   -- apply the shift
            -- save fractional seconds in shifted time
            frac = tm_ - int(tm_)
            if frac ~= 0 then
                tm_ = int(tm_)
                -- must account for any rounding that could occur
                if frac + 0.5 * 10 ^ (-dec) >= 1 then tm_ = tm_ + 1; frac = 0 end
            end
            tm = perl.gmtime(tm_)
            -- @toTime = reverse @tm[0..5]
            toTime[0], toTime[1], toTime[2] = tm[6], tm[5], tm[4]
            toTime[3], toTime[4], toTime[5] = tm[3], tm[2], tm[1]
            toTime[0] = toTime[0] + 1900
            toTime[1] = toTime[1] + 1
            toTime[5] = toTime[5] + frac    -- add the fractional seconds back in
        end
        -- apply the previous timezone shift if necessary
        if time[6] ~= nil then
            local m = time[6] * 60 + time[7]
            m = m + shiftOffset.Timezone
            m = m + 0.5 * cmp0(m)       -- avoid round-off errors
            toTime[6] = int(m / 60)
            toTime[7] = int(m - toTime[6] * 60)
        end
    end
--
-- insert shifted time components back into original string
--
    -- (port: the substr assignment needs Perl's mutable scalar, a carray;
    --  pos is the 0-based end of the last match)
    val = carray.new('char'):append(val)
    local pos = 0
    local i = 0
    while i < alen(toTime) do
        if not (time[i] ~= nil and toTime[i] ~= nil) then goto next_i end
        do
            local v, d, s, en
            if i ~= 6 then  -- not timezone hours
                local c1, c2, e = matches(val, [[((?=\d|\.\d)\d*(\.\d*)?)]], pos)
                if c1 == nil then break end
                if num(toTime[i], '==') == num(time[i], '==') then pos = e goto next_i end
                v = c1      -- value
                d = c2      -- decimal part of value
                s = ''      -- no sign
                en = e
            else
                if num(time[i], '==') == num(toTime[i], '==') and
                   num(time[i + 1], '==') == num(toTime[i + 1], '==') then break end
                local c1, c2, e = matches(val, [[((?:\+|-)(?=\d|\.\d)\d*(\.\d*)?)]], pos)
                if c1 == nil then break end
                v = c1
                d = c2
                en = e
                if toTime[6] >= 0 and toTime[7] >= 0 then
                    s = '+'
                else
                    s = '-'
                    toTime[6] = -toTime[6]
                    toTime[7] = -toTime[7]
                end
            end
            local nv = toTime[i]
            local len = length(v)
            local sig = len - length(s)
            local dec_ = perlTruthy(d) and length(d) - 1 or 0
            local newNum = sprintf(dec_ ~= 0 and (s .. '%0' .. sig .. '.' .. dec_ .. 'f') or (s .. '%0' .. sig .. 'd'), nv)
            perl.substr(val, en - len, len, newNum)
            pos = en + length(newNum) - len
        end
        ::next_i::
        i = i + 1
    end
    return val:tostring(), nil  -- success!
end

return Shift
