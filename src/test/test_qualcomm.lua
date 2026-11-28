--------------------------------------------------------------------------------
-- File:         test/test_qualcomm.lua
--
-- Description:  The port's own test (no upstream counterpart): the tag
--               names and descriptions of the Qualcomm Main table, built at
--               load time by makeNameAndDescLoad (Lua patterns),
--               against the line-for-line port
--               MakeNameAndDesc (facade regexes) -- for every ID of the
--               table, for edge cases and for random IDs.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok, is = TestLib.ok, TestLib.is
local done = TestLib.done

local Qualcomm = require('lexiftool.Qualcomm')
local old, new = Qualcomm._MakeNameAndDesc, Qualcomm._makeNameAndDescLoad

local function result(fn, id)
    local tagInfo = { }
    local rtn = fn(id, tagInfo)
    return tostring(rtn and true or false) .. '|' .. tostring(tagInfo.Name) .. '|' .. tostring(tagInfo.Description)
end

-- every ID of the Main table: both functions, and the table as loaded
do
    local main = Qualcomm.Main
    local ids = lexiftool.TagTableKeys(main)
    local bad, badTable = { }, { }
    for _, id in ipairs(ids) do
        local want = result(old, id)
        if result(new, id) ~= want then bad[#bad + 1] = id end
        if 'true|' .. tostring(main[id].Name) .. '|' .. tostring(main[id].Description) ~= want then
            badTable[#badTable + 1] = id
        end
    end
    ok(#ids > 1100, 'Qualcomm Main: ' .. #ids .. ' IDs')
    is('', table.concat(bad, ' '), 'Qualcomm Main: makeNameAndDescLoad = MakeNameAndDesc for every ID')
    is('', table.concat(badTable, ' '), 'Qualcomm Main: loaded Name/Description = MakeNameAndDesc')
end

-- edge cases (some outside the fast path's character set)
do
    local cases = {
        '', '_', '__', '[', ']', '[1]', '[01]', '[123]', 'a[1]', 'a[1][2]', 'a[1]b',
        'a[]', 'a[x]', 'af_', 'af', 'afr', 'afr_x', 'af_x', 'tl', 'tl_a', 'r2_tl',
        'r2_tl_x', 'r2_t', 'la_', 'la', 'asf5_luma_filter[0]', 'awb', 'aec_a_b',
        'Abc', 'ABC_DEF', 'a_B_C', 'a__b', 'x_1', 'x_1_2', 'X_1', '1_a', '9_B',
        'a_Bc', 'a_BC', '_Ab', 'ab_cd_ef[10]', 'a[1]\n', 'a\n', 'a-b', 'a b',
        'a.b', 'a\xc3\xa9b', '\xe9t\xe9', 'a[1]_', 'tl[3]', '[1]x[2]',
    }
    local bad = { }
    for _, id in ipairs(cases) do
        if result(new, id) ~= result(old, id) then bad[#bad + 1] = string.format('%q', id) end
    end
    is('', table.concat(bad, ' '), 'Qualcomm: edge cases (' .. #cases .. ')')
end

-- random IDs over the characters of the table (plus a few others)
do
    local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789____[[]]-. '
    local prefixes = { '', '', 'af_', 'afr', 'asf', 'awb', 'aec', 'la_', 'r2_tl', 'tl' }
    local seed = 20261122
    local function rnd(n)   -- a small LCG, independent of math.random's version
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end
    local bad, n = { }, 0
    for _ = 1, 5000 do
        local t = { prefixes[rnd(#prefixes) + 1] }
        for _ = 1, rnd(16) do
            local k = rnd(#chars) + 1
            t[#t + 1] = chars:sub(k, k)
        end
        if rnd(4) == 0 then t[#t + 1] = '[' .. rnd(200) .. ']' end
        local id = table.concat(t)
        n = n + 1
        if result(new, id) ~= result(old, id) then bad[#bad + 1] = string.format('%q', id) end
    end
    is('', table.concat(bad, ' '), 'Qualcomm: ' .. n .. ' random IDs')
end

done()
