--------------------------------------------------------------------------------
-- File:         test-cli/Known.lua
--
-- Description:  Known deviations: cases whose difference comes from internals
--               of the Perl interpreter the port cannot reproduce
--               (doc/cli-tests.md, "Known deviations"). Shared by the CLI
--               golden test (Known.GOLDEN, read by Report.lua) and the corpus
--               run (CorpusReport.KNOWN).
--
--               An entry is never a suppression: a case counts as "known" only
--               while its difference has exactly the recorded form -- only the
--               named file differs, and in it only the recorded lines (missing
--               from the test side, or reordered). Any other difference in the
--               same case makes it an ordinary difference again; a known case
--               that has become identical is reported so its entry can go.
--------------------------------------------------------------------------------

local Util = require('test-cli.Util')

local Known = {}

-- An entry, keyed by case directory:
--   file  the only file that may differ;
--   lines Lua pattern for the only lines that may differ;
--   form  'missing' -- the lines are in the reference only (Perl prints a
--         warning the port cannot), 'order' -- the same lines in another
--         order (Perl hash order);
--   why   the reason, one sentence.

-- Perl's `use warnings` on an undef $lensModel in Canon.pm PrintLensID
-- (`$lensModel =~ / \+ ((EXTENDER )?RF)?.../`), shown by -v as a Conv warning.
Known.WHY_LENSMODEL = 'Perl reads the variable name in "Use of uninitialized value $lensModel" from ' ..
    'its op tree; the facade sees only the value (perl.num rule: undef does not warn)'
Known.PAT_LENSMODEL = '^  Warning = PrintConv LensID: Use of uninitialized value %$lensModel in pattern match'

-- The golden cases (Cases.lua): Sigma.x3f has no LensModel, so every -v level
-- that prints the conversions carries the warning.
Known.GOLDEN = {}
for _, label in ipairs({ 'dump-v', 'dump-v2', 'dump-v3', 'dump-v5' }) do
    Known.GOLDEN['read/' .. label .. '/Sigma.x3f'] = { file = 'stdout.txt', lines = Known.PAT_LENSMODEL,
                                                       form = 'missing', why = Known.WHY_LENSMODEL }
end

local function splitLines(text)
    local t = {}
    for line in (text or ''):gmatch('([^\n]*)\n') do t[#t + 1] = line end
    return t
end

-- Does the difference of result `r` (Compare) have exactly the recorded form
-- `k`? `o.refTree`/`o.testTree` are the two trees.
function Known.matches(r, k, o)
    if #r.diffs ~= 1 or r.diffs[1] ~= k.file then return false end
    local ref = splitLines(Util.readFile(o.refTree .. '/' .. r.dir .. '/' .. k.file))
    local test = splitLines(Util.readFile(o.testTree .. '/' .. r.dir .. '/' .. k.file))
    if k.form == 'missing' then
        local kept = {}
        for _, l in ipairs(ref) do
            if not l:find(k.lines) then kept[#kept + 1] = l end
        end
        if #kept ~= #test then return false end
        for i = 1, #kept do
            if kept[i] ~= test[i] then return false end
        end
        return true
    end
    -- 'order': same lines, and every line at a changed position is a recorded one
    if #ref ~= #test then return false end
    for i = 1, #ref do
        if ref[i] ~= test[i] and not (ref[i]:find(k.lines) and test[i]:find(k.lines)) then
            return false
        end
    end
    table.sort(ref)
    table.sort(test)
    for i = 1, #ref do
        if ref[i] ~= test[i] then return false end
    end
    return true
end

return Known
