--------------------------------------------------------------------------------
-- File:         test/test_taglist_order.lua
--
-- Description:  The tag orders of GetTagList and SetFoundTags against a
--               plain stable sort written out here: by file order (and the
--               group order of a Group sort as the outer level), a tie in
--               input order as Perl's mergesort keeps it; SetFoundTags'
--               list of all tags by file order, a tie by name (perl.lt),
--               a tag without a file order at 999. The port deals the tags
--               out by order value (byOrder, sortedKeys), which must give
--               exactly this order -- also with many ties, with tags that
--               have no file order, and with integer and float order values.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local is = TestLib.is

local T_DIR = TestLib.T_DIR

-- stable sort of list by key(tag) (numbers), ties in input order
local function stableBy(list, key)
    local idx = {}
    for i, t in ipairs(list) do idx[t] = i end
    local out = table.move(list, 1, #list, 1, {})
    table.sort(out, function(a, b)
        local ka, kb = key(a), key(b)
        if ka ~= kb then return ka < kb end
        return idx[a] < idx[b]
    end)
    return out
end
local function join(list) return table.concat(list, ',') end

-- GetTagList of an extracted file: file order, Group0/Group1 sorts, and the
-- FOUND_TAGS path, where a tag without a file order counts as 0
for _, file in ipairs({ 'Canon.jpg', 'Nikon.jpg', 'ExifTool.jpg' }) do
    local et = lexiftool:new()
    et:ImageInfo(T_DIR .. '/images/' .. file)
    local fo = et.FILE_ORDER
    local found = et.FOUND_TAGS
    -- many ties: every third tag shares the order value of its neighbour,
    -- some as a float, a few have none
    for i, tag in ipairs(found) do
        if i % 3 == 0 then fo[tag] = fo[found[i - 1]] end
        if i % 7 == 0 then fo[tag] = (fo[tag] or 0) + 0.0 end
        if i % 11 == 0 then fo[tag] = nil end
    end
    local function key(t) return fo[t] or 0 end
    is(join(stableBy(found, key)), join(et:GetTagList(nil, 'File')),
       file .. ': GetTagList by file order, ties in input order')
    for _, fam in ipairs({ 0, 1 }) do
        local fileSorted = stableBy(found, key)
        local gorder, ng = {}, 0
        for _, tag in ipairs(fileSorted) do
            local g = et:GetGroup(tag, fam)
            if not gorder[g] then ng = ng + 1 gorder[g] = ng end
        end
        local function gkey(t) return gorder[et:GetGroup(t, fam)] * 1e9 + key(t) end
        is(join(stableBy(found, gkey)), join(et:GetTagList(nil, 'Group' .. fam)),
           file .. ': GetTagList by Group' .. fam .. ' then file order')
    end
    -- a tag list: a tag without a file order gets 999
    local list = {}
    for i = #found, 1, -2 do list[#list + 1] = found[i] end
    local sorted = et:GetTagList(list, 'File')
    is(join(stableBy(list, function(t) return fo[t] end)), join(sorted),
       file .. ': GetTagList of a list, ties in list order')
end

-- SetFoundTags without requested tags: all tags by file order, a tie by
-- name, no file order = 999
do
    local et = lexiftool:new()
    local value, fo = {}, {}
    local names = {}
    for i = 1, 60 do
        local name = string.format('T%02d', (i * 37) % 61)
        if i % 5 == 0 then name = name .. ' (1)' end   -- a copy
        names[#names + 1] = name
        value[name] = i
        if i % 9 ~= 0 then fo[name] = (i % 4 == 0) and 7 or ((i % 6 == 0) and 7.0 or i) end
    end
    fo['T99'] = 999 value['T99'] = 0 names[#names + 1] = 'T99'
    et.VALUE, et.FILE_ORDER = value, fo
    et.OPTIONS.Duplicates = 1
    local exp = table.move(names, 1, #names, 1, {})
    table.sort(exp, function(a, b)
        local oa, ob = fo[a] or 999, fo[b] or 999
        if oa ~= ob then return oa < ob end
        return perl.lt(a, b)
    end)
    is(join(exp), join((et:SetFoundTags())), 'SetFoundTags: by file order, ties by name, none = 999')
    et.OPTIONS.Duplicates = 0
    local noCopy = {}
    for _, n in ipairs(exp) do if not n:find(' ', 1, true) then noCopy[#noCopy + 1] = n end end
    is(join(noCopy), join((et:SetFoundTags())), 'SetFoundTags without duplicates: same order, no copies')
    -- no tie at all, and a single tag
    et.VALUE, et.FILE_ORDER = { B = 1, A = 1, C = 1 }, { B = 2, A = 3, C = 1 }
    is('C,B,A', join((et:SetFoundTags())), 'SetFoundTags without ties')
    et.VALUE, et.FILE_ORDER = { A = 1 }, {}
    is('A', join((et:SetFoundTags())), 'SetFoundTags of a single tag without file order')
end

TestLib.done()
