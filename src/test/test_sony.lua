--------------------------------------------------------------------------------
-- File:         test/test_sony.lua
-- Ported from:  t/Sony.t
--
-- Description:  Lua port of the upstream Sony.t (the Perl original):
--               extracts information from t/images/Sony.jpg and
--               t/images/Sony.pmp and compares against the vendored
--               standard output; verifies the Sony MakerNotes decryption
--               algorithm.
--
-- Port notes:   Tests 2-5 of the upstream numbering are ported; a block of
--               the port's own at the end checks the lens ID sort of
--               Sony.lua (sortLensTypes) against the former one.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'Sony'

-- test 2: Extract information from Sony.jpg
do
    local exifTool = lexiftool:new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sony.jpg', { Unknown = 1 })
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'FlashFired', 'true' },
        { 'ISO', nil, n = 2 },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Test Sony decryption
do
    local Sony = require('lexiftool.Sony')
    local n = 0x34a290d3
    local data = string.char((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
    data = Sony.Decrypt(data, 0, 4, 0x12345678)
    local b1, b2, b3, b4 = data:byte(1, 4)
    local got = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    ok(got == 0x20677968, string.format('decryption returned expected value (got 0x%x)', got))
end

-- test 5: Extract information from a PMP image
do
    local exifTool = lexiftool:new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/Sony.pmp')
    ok(check(exifTool, info, testname, 5), 'test 5 matches')
end


-- (not upstream: the port's sort of the Minolta lens IDs for the
--  sonyLensTypes block, Sony.lua's sortLensTypes on precomputed keys,
--  against the former sort that called SortLensTypes in every comparison
--  (copied here as it was): the same order for the module's ID list, in
--  several start orders; the IDs have no ties, so the order is unique)
do
    local perl = require('lexiftool.perl')
    local Sony = require('lexiftool.Sony')
    local minoltaTypes = require('lexiftool.Minolta').minoltaLensTypes
    local is = TestLib.is
    local matches, split, at, num, str = perl.matches, perl.split, perl.at, perl.num, perl.str
    -- (the former Sony.SortLensTypes and its sort call)
    local function SortLensTypes(a, b)
        a, b = str(a), str(b)
        if not (matches(a, [[\.]]) and matches(b, [[\.]])) then
            return num(a) < num(b) and -1 or (num(a) > num(b) and 1 or 0)
        end
        local a_ = split([[\.]], a)
        local b_ = split([[\.]], b)
        local function cmp(x, y) return num(x) < num(y) and -1 or (num(x) > num(y) and 1 or 0) end
        local c = cmp(at(a_, 0), at(b_, 0))
        if c ~= 0 then return c end
        return cmp(at(a_, 1), at(b_, 1))
    end
    local function oldSort(ids) perl.tsort(ids, function(a, b) return SortLensTypes(a, b) < 0 end) end
    local ids = {}
    for id in pairs(minoltaTypes) do
        if id ~= 'Notes' and id ~= 'OTHER' then ids[#ids + 1] = id end
    end
    local ties = 0
    for i = 1, #ids do
        for j = i + 1, #ids do
            if SortLensTypes(ids[i], ids[j]) == 0 then ties = ties + 1 end
        end
    end
    is(0, ties, 'lens IDs: no two compare equal (' .. #ids .. ' IDs)')
    local function show(list)
        local t = {}
        for i, v in ipairs(list) do t[i] = (math.type(v) or type(v)) .. ':' .. tostring(v) end
        return table.concat(t, ' ')
    end
    local seed = 20261121
    local function rnd(n)   -- a small LCG, independent of math.random's version
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end
    local sorted = { table.unpack(ids) }
    oldSort(sorted)
    local want = show(sorted)
    for round = 1, 6 do
        -- 1: pairs() order, 2: sorted, 3: reversed, 4-6: shuffled
        local start = {}
        for i, v in ipairs(round == 1 and ids or sorted) do start[i] = v end
        if round == 3 then
            for i = 1, #start // 2 do start[i], start[#start + 1 - i] = start[#start + 1 - i], start[i] end
        elseif round > 3 then
            for i = #start, 2, -1 do local k = rnd(i) + 1; start[i], start[k] = start[k], start[i] end
        end
        local a, b = { table.unpack(start) }, { table.unpack(start) }
        oldSort(a)
        Sony._sortLensTypes(b)
        ok(show(a) == want, 'lens IDs, start order ' .. round .. ': former sort gives the same order')
        ok(show(b) == want, 'lens IDs, start order ' .. round .. ': sortLensTypes = former sort')
    end
end

done() -- end
