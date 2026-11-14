--------------------------------------------------------------------------------
-- File:         test-cli/Report.lua
--
-- Description:  Turns the comparison results into summary.txt, failures.txt and
--               results.json, and returns the totals for the terminal.
--
--               There are no failure artifacts to write: the observation trees
--               ARE the artifacts. A failing case names its own directory, and
--               the two sides sit at the same path in the two trees:
--
--                   diff -u test-cli-ref/read/csv/PDF.pdf/stdout.txt \
--                           test-cli-out/read/csv/PDF.pdf/stdout.txt
--------------------------------------------------------------------------------

local Util  = require('test-cli.Util')
local Known = require('test-cli.Known')

local Report = {}

local MAX_SHOWN = 10  -- failing cases listed per variant in summary.txt

-- o: outDir, refTree, testTree, testName, refName, regenTarget (the make
--    target that rebuilds the reference; default test-cli-gen), known (the
--    known deviations, Known.GOLDEN; nil = none: every difference counts)
function Report.write(results, o)
    local byLabel, order = {}, {}
    local total, ok, missing = 0, 0, 0
    local knownCases, knownFixed, knownChanged = {}, {}, {}

    for _, r in ipairs(results) do
        local key = r.group .. '/' .. r.label
        local t = byLabel[key]
        if not t then
            t = { ok = 0, total = 0, eff = 0, known = 0, fails = {} }
            byLabel[key] = t
            order[#order + 1] = key
        end
        local good = (r.status == 'ok')
        t.total = t.total + 1
        total = total + 1
        if r.effective then t.eff = t.eff + 1 end
        -- a known deviation counts as such only in exactly its recorded form
        local k = o.known and o.known[r.dir]
        if good then
            t.ok = t.ok + 1
            ok = ok + 1
            if k then knownFixed[#knownFixed + 1] = r.dir end
        elseif k and r.status == 'differs' and Known.matches(r, k, o) then
            t.known = t.known + 1
            knownCases[#knownCases + 1] = { dir = r.dir, file = k.file, why = k.why }
        else
            if k then knownChanged[#knownChanged + 1] = r.dir end
            t.fails[#t.fails + 1] = r
            if r.status ~= 'differs' then missing = missing + 1 end
        end
    end

    -- Results arrive in tree order, but sorting the failures per variant keeps
    -- the report diffable between runs.
    for _, t in pairs(byLabel) do
        table.sort(t.fails, function(a, b) return a.name < b.name end)
    end
    -- Worst variants first: that is where the porting gaps are.
    table.sort(order, function(a, b)
        local ta, tb = byLabel[a], byLabel[b]
        local ra = ta.total > 0 and ta.ok / ta.total or 0
        local rb = tb.total > 0 and tb.ok / tb.total or 0
        if ra ~= rb then return ra < rb end
        return a < b
    end)

    -- Complete failure list as TSV, separate from the summary so the latter
    -- stays scannable: variant, case, status, and the first differing file.
    local failLines = {}
    for _, key in ipairs(order) do
        for _, r in ipairs(byLabel[key].fails) do
            failLines[#failLines + 1] = table.concat({
                key, r.name, r.status, r.diffs[1] or '', r.dir }, '\t')
        end
    end
    Util.writeFile(o.outDir .. '/failures.txt',
        table.concat(failLines, '\n') .. (#failLines > 0 and '\n' or ''))

    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(o.testName .. ' vs. ' .. o.refName .. ' - CLI comparison')
    add('  test      : ' .. o.testTree)
    add('  reference : ' .. o.refTree)
    add('  inspect a case with:  diff -r ' .. o.refTree .. '/<case> ' .. o.testTree .. '/<case>')
    add(string.rep('-', 72))
    add(('Grand total: %d/%d identical (%d%%)%s'):format(
        ok, total, total > 0 and math.floor(ok / total * 100) or 0,
        #knownCases > 0 and (', %d known (Perl internals)'):format(#knownCases) or ''))
    if missing > 0 then
        add(('  %d case(s) exist in only one tree -- rebuild with: make %s')
            :format(missing, o.regenTarget or 'test-cli-gen'))
    end
    add(string.rep('-', 72))

    local inert = {}
    for _, key in ipairs(order) do
        local t = byLabel[key]
        -- One silent case is unremarkable; a variant that is silent throughout
        -- is the signal -- see the note at r.effective in Compare.lua.
        local mark = ''
        if t.eff == 0 and t.total > 0 then
            mark = '   <- SILENT: reference produced nothing, in every case'
            inert[#inert + 1] = key
        end
        local known = t.known > 0 and (' (+%d known)'):format(t.known) or ''
        add(('%-26s : %d/%d OK%s%s'):format(key, t.ok, t.total, known, mark))
    end
    if #inert > 0 then
        add('')
        add(('%d variant(s) were SILENT: the reference produced no output, no'):format(#inert))
        add('complaint and no file change for a single one of their cases. One such')
        add('case is unremarkable -- a tag the file does not have. ALL of them is')
        add('usually a broken matrix entry: a $TAG the shell expanded away, a')
        add('missing "=" that turns a write into a mere tag selection, or an option')
        add('combination the tool rejects outright. Run the variant by hand to tell')
        add('the two apart.')
        add('  ' .. table.concat(inert, ', '))
    end
    if #knownCases + #knownChanged + #knownFixed > 0 then
        add('')
        add(string.rep('-', 72))
        add('Known deviations (Perl internals; doc/cli-tests.md "Known deviations")')
        add(string.rep('-', 72))
        table.sort(knownCases, function(a, b) return a.dir < b.dir end)
        for _, e in ipairs(knownCases) do
            add(('  %-40s %s: %s'):format(e.dir, e.file, e.why))
        end
        if #knownChanged > 0 then
            table.sort(knownChanged)
            add('  with a DIFFERENT difference than recorded (counted as differences):')
            for _, d in ipairs(knownChanged) do add('    ' .. d) end
        end
        if #knownFixed > 0 then
            table.sort(knownFixed)
            add('  identical now (remove their entry in Known.lua):')
            for _, d in ipairs(knownFixed) do add('    ' .. d) end
        end
    end
    if #failLines > 0 then
        add('')
        add(string.rep('-', 72))
        add('Differences (case, then what differs; full list in failures.txt)')
        add(string.rep('-', 72))
        for _, key in ipairs(order) do
            local t = byLabel[key]
            if #t.fails > 0 then
                add(('%s (%d of %d):'):format(key, #t.fails, t.total))
                for i, r in ipairs(t.fails) do
                    if i > MAX_SHOWN then
                        add(('  ... and %d more'):format(#t.fails - MAX_SHOWN))
                        break
                    end
                    local what = r.diffs[1] or r.status
                    if #r.diffs > 1 then
                        what = what .. (' (+%d more)'):format(#r.diffs - 1)
                    end
                    add(('  %-40s %s'):format(r.dir, what))
                end
            end
        end
    end
    Util.writeFile(o.outDir .. '/summary.txt', table.concat(lines, '\n') .. '\n')

    local function jstr(s)
        return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    end
    local jparts = {}
    for _, r in ipairs(results) do
        jparts[#jparts + 1] = table.concat({
            '{"group":' .. jstr(r.group),
            '"label":' .. jstr(r.label),
            '"case":' .. jstr(r.name),
            '"status":' .. jstr(r.status),
            '"diffs":' .. tostring(#r.diffs),
        }, ',') .. '}'
    end
    Util.writeFile(o.outDir .. '/results.json',
        '[\n' .. table.concat(jparts, ',\n') .. '\n]\n')

    return { total = total, ok = ok, known = #knownCases,
             differs = total - ok - #knownCases, missing = missing, inert = inert }
end

return Report
