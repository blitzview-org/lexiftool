--------------------------------------------------------------------------------
-- File:         test-cli/CorpusReport.lua
--
-- Description:  summary.md of the corpus run: the comparison results sorted
--               the way the next porting step needs them.
--
--                 * per case type (a-u-G1, j-t, v3, X-struct, w-Artist,
--                   w-all, s-make): identical / differing / timeouts;
--                 * per Lua module: how many deviations it is blamed for;
--                 * timeouts and hangs, each by name (the most important
--                   finds: a hang is invisible to every diff);
--                 * the most frequent diff patterns;
--                 * every deviation with its first 3 diff lines.
--
--               Blaming a module is a heuristic, read off the REFERENCE side:
--
--                 - the first differing line of the first differing file;
--                 - in -G1 output (a-u-G1, readbacks, sessions) the family-1
--                   group "[Canon]", in -X output the element prefix
--                   "<Canon:...>", in -j output the tag name, looked up in the
--                   same file's -X reference to find its group;
--                 - in -v3 output the nearest enclosing "(SubDirectory) -->" or
--                   "+ [IFD0 directory" above the differing line;
--                 - a group is mapped to the module that defines its table
--                   (XMP-* -> XMP, IFD0/ExifIFD -> Exif, ICC-* -> ICC_Profile,
--                   File/System -> ExifTool, else the longest module name the
--                   group starts with: CanonCustom, Nikon, ...);
--                 - a Lua error (traceback on stderr) blames the module of its
--                   top frame instead -- the diff then only shows the output
--                   that is missing;
--                 - when nothing names a group (a differing written file, an
--                   exit code), the manufacturer directory stands in, marked
--                   "(make)".
--               A group no module name matches is shown as "<group>?".
--
--               Known deviations (KNOWN below, doc/cli-tests.md "Known
--               deviations") are cases whose difference comes from Perl
--               interpreter internals the port cannot reproduce. They are
--               marked, never suppressed: a case counts as "known" only while
--               its difference has exactly the recorded form (only the named
--               file differs, and only in the recorded lines); any other
--               difference in the same case makes it an ordinary deviation
--               again. The head line reads "n/m identical, k known", so a
--               new deviation shows up as a non-zero "differing" (which
--               TEST_CORPUS_EXPECT_IDENTICAL=1 turns into a failure). A known
--               case that has become identical is listed so its entry can go.
--------------------------------------------------------------------------------

local Util  = require('test-cli.Util')
local Known = require('test-cli.Known')

local CorpusReport = {}

local DIFF_LINES = 3

-- Groups whose table lives in a module of another name.
local GROUP_MODULE = {
    IFD0 = 'Exif', IFD1 = 'Exif', IFD2 = 'Exif', IFD3 = 'Exif', ExifIFD = 'Exif',
    InteropIFD = 'Exif', GlobParamIFD = 'Exif', ExifOffset = 'Exif',
    InteropOffset = 'Exif', SubIFD = 'Exif', ExifTool = 'ExifTool',
    File = 'ExifTool', System = 'ExifTool', Composite = 'Composite',
    GPSInfo = 'GPS', JFIF = 'JFIF', JFXX = 'JFIF', MPF0 = 'MPF',
    MakerNotes = false, ICC_Profile = 'ICC_Profile', Ducky = 'JPEG',
    Adobe = 'JPEG', Leica = 'Panasonic', FujiIFD = 'FujiFilm',
}

-- Known deviations of the corpus: case directory -> recorded form of its
-- difference (the entry's fields and the matching are in Known.lua).
local WHY_ORDER = '-v3 prints several Conv warnings in Perl hash order (keys %VALUE in GetInfo), ' ..
    'which depends on the interpreter\'s hash function and bucket layout'
local WHY_WRITERPL = 'an uncaught Perl warning on stderr names the Perl source file and line ' ..
    '(Writer.pl line 6163) and the input chunk'
local PAT_ORDER = '^  Warning = '
local PAT_WRITERPL = '^Use of uninitialized value in subtraction %(%-%) at <REPO>/vendor/exiftool/lib/' ..
    'Image/ExifTool/Writer%.pl line 6163, '
local KNOWN = {}
for _, name in ipairs({ 'Garmin~GarminDashCam55.jpg', 'Motorola~MotorolaC261.jpg',
                        'Reconyx~ReconyxHYPERFIRE_HP4K.jpg', 'Samsung~SamsungHMX-H300.jpg',
                        'Sony~SonyDPP-FP60.jpg' }) do
    KNOWN['read/v3/' .. name] = { file = 'stdout.txt', lines = PAT_ORDER, form = 'order', why = WHY_ORDER }
end
for _, name in ipairs({ 'Canon~CanonEOS-1D.jpg', 'Canon~CanonEOS-1DS.jpg',
                        'Canon~CanonEOS-1DSmkII.jpg', 'Canon~CanonEOS_D30.jpg' }) do
    KNOWN['read/v3/' .. name] = { file = 'stdout.txt', lines = Known.PAT_LENSMODEL, form = 'missing',
                                  why = Known.WHY_LENSMODEL }
end
for _, name in ipairs({ 'Leica~LeicaM.jpg', 'Leica~LeicaS2.jpg' }) do
    KNOWN['write/w-Artist/' .. name] = { file = 'stderr.txt', lines = PAT_WRITERPL, form = 'missing',
                                         why = WHY_WRITERPL }
end
CorpusReport.KNOWN = KNOWN

local modules
local function moduleList(repoDir)
    if modules then return modules end
    modules = {}
    for _, path in ipairs(Util.listFiles(repoDir .. '/src/lexiftool')) do
        local m = path:match('([^/]+)%.lua$')
        if m and #m >= 3 then modules[#modules + 1] = m end
    end
    table.sort(modules, function(a, b) return #a > #b end)
    return modules
end

local function moduleOf(group, repoDir)
    if not group or group == '' then return nil end
    local m = GROUP_MODULE[group]
    if m ~= nil then return m or nil end
    if group:match('^XMP') then return 'XMP' end
    if group:match('^ICC') then return 'ICC_Profile' end
    if group:match('^SubIFD%d*$') or group:match('^IFD%d+$') then return 'Exif' end
    if group:match('^MPImage%d*$') then return 'MPF' end
    if group:match('^APP%d+$') then return 'JPEG' end
    local inner = group:match('^MakerNote(%u%w+)$')
    if inner then return moduleOf(inner, repoDir) or (inner .. '?') end
    for _, name in ipairs(moduleList(repoDir)) do
        if group:sub(1, #name) == name then return name end
    end
    return group .. '?'
end

local function readLines(path)
    local t = {}
    for line in ((Util.readFile(path) or '') .. '\n'):gmatch('([^\n]*)\n') do t[#t + 1] = line end
    return t
end

-- The first hunk of a line diff of two files, in Lua (no diff(1) needed):
-- the line number where it starts on the reference side (as diff(1) names
-- it: for a pure insertion the line it follows), and its first DIFF_LINES
-- lines, removed ones ("-ref") before added ones ("+test"). After the
-- common head and tail, the hunk ends at the nearest pair of equal lines
-- (smallest combined distance, searched up to RESYNC lines) -- enough for
-- a report that shows where a difference starts.
local RESYNC = 400
local function diffLines(a, b)
    local A, B = readLines(a), readLines(b)
    local i = 1
    while i <= #A and i <= #B and A[i] == B[i] do i = i + 1 end
    local ea, eb = #A, #B
    while ea >= i and eb >= i and A[ea] == B[eb] do ea, eb = ea - 1, eb - 1 end
    local da, db = ea - i + 1, eb - i + 1
    for k = 1, math.min(RESYNC, da + db - 1) do
        local hit = false
        for x = 0, k do
            local y = k - x
            if i + x <= ea and i + y <= eb and A[i + x] == B[i + y] then
                da, db, hit = x, y, true
                break
            end
        end
        if hit then break end
    end
    local lines = {}
    for n = i, i + da - 1 do
        if #lines < DIFF_LINES then lines[#lines + 1] = '-' .. A[n] end
    end
    for n = i, i + db - 1 do
        if #lines < DIFF_LINES then lines[#lines + 1] = '+' .. B[n] end
    end
    return (da == 0) and (i - 1) or i, lines
end

-- The group a differing line belongs to, by output kind.
local function groupOfLine(line, label, o, r)
    if not line then return nil end
    local body = line:sub(2)
    local g = body:match('^%[([^%]]+)%]')
    if g then return g end
    g = body:match('^%s*<([%w%-_]+):') or body:match('^%s*</([%w%-_]+):')
    if g and g ~= 'rdf' and g ~= 'et' and g ~= 'x' then return g end
    if label == 'j-t' then
        local tag = body:match('^%s*"([^"]+)"')
        if tag then
            local x = Util.readFile(o.refTree .. '/read/X-struct/' .. r.name .. '/stdout.txt') or ''
            return x:match('<([%w%-_]+):' .. tag:gsub('%p', '%%%0') .. '[ >]')
        end
    end
    return nil
end

-- -v3: the nearest structure marker above line `n` of the reference output.
local function groupOfV3(refFile, n)
    if not n then return nil end
    local lines = readLines(refFile)
    for i = math.min(n, #lines), 1, -1 do
        local l = lines[i]
        local sub = l:match('%d+%)%s+(%S+) %(SubDirectory%) %-%->')
        if sub then return sub end
        local dir = l:match('%+ %[(%S+) directory')
        if dir and dir ~= 'BinaryData' and dir ~= 'SerialData' and dir ~= 'MakerNotes' then
            return dir
        end
        local seg = l:match('^JPEG (APP%d+)')
        if seg then return seg end
    end
    return nil
end

local TEXT_FILES = {
    'stdout.txt', 'readback-stdout.txt', 'stderr.txt', 'readback-stderr.txt',
    'exit.txt', 'readback-exit.txt', 'feed.txt',
}

-- A call that hit the harness timeout. Compare records the verdict from the
-- files it reads anyway (r.refTimeout / r.testTimeout); results from another
-- source are read from the tree.
local function isTimeout(tree, dir, flag)
    if flag ~= nil then return flag end
    for _, f in ipairs({ 'exit.txt', 'readback-exit.txt' }) do
        local c = (Util.readFile(tree .. '/' .. dir .. '/' .. f) or ''):match('%-?%d+')
        if c == '124' or c == '137' then return true end
    end
    local feed = Util.readFile(tree .. '/' .. dir .. '/feed.txt') or ''
    return feed:find('TIMEOUT', 1, true) ~= nil
end

-- A diff pattern: which line kind differs, without the values.
local function pattern(line)
    if not line then return '(no text difference: written file / exit code)' end
    local sign, body = line:sub(1, 1), line:sub(2)
    local g, tag = body:match('^%[([^%]]+)%]%s+(.-)%s*:')
    if g then return sign .. '[' .. g .. '] ' .. tag end
    local x = body:match('^%s*(</?[%w%-_]+:[%w%-_]+)')
    if x then return sign .. x end
    local j = body:match('^%s*("[^"]+"):')
    if j then return sign .. j end
    return sign .. body:gsub('%d+', '#'):sub(1, 60)
end

-- o: outDir, refTree, testTree, testName, refName, corpusDir, files, allFiles,
--    sampleN, seed, repoDir, timeout
function CorpusReport.write(results, o)
    local byLabel, labels = {}, {}
    local byModule = {}
    local patterns = {}
    local timeouts, refTimeouts, luaErrors = {}, {}, {}
    local devs = {}
    local knownCases, knownFixed, knownChanged = {}, {}, {}
    local total, ok = 0, 0

    for _, r in ipairs(results) do
        total = total + 1
        local t = byLabel[r.label]
        if not t then
            t = { total = 0, ok = 0, known = 0, differ = 0, timeout = 0 }
            byLabel[r.label] = t
            labels[#labels + 1] = r.label
        end
        t.total = t.total + 1
        if isTimeout(o.refTree, r.dir, r.refTimeout) then refTimeouts[#refTimeouts + 1] = r.dir end
        local k = KNOWN[r.dir]
        if r.status == 'ok' then
            t.ok = t.ok + 1
            ok = ok + 1
            if k then knownFixed[#knownFixed + 1] = r.dir end
        elseif k and Known.matches(r, k, o) then
            t.known = t.known + 1
            knownCases[#knownCases + 1] = { dir = r.dir, file = k.file, why = k.why }
        else
            if k then knownChanged[#knownChanged + 1] = r.dir end
            t.differ = t.differ + 1
            local dev = { r = r }
            if isTimeout(o.testTree, r.dir, r.testTimeout) then
                t.timeout = t.timeout + 1
                dev.timeout = true
                timeouts[#timeouts + 1] = r.dir
            end
            local errText = (Util.readFile(o.testTree .. '/' .. r.dir .. '/stderr.txt') or '') ..
                            (Util.readFile(o.testTree .. '/' .. r.dir .. '/readback-stderr.txt') or '')
            if errText:find('stack traceback', 1, true) then
                dev.luaError = true
                luaErrors[#luaErrors + 1] = r.dir
                -- the module the error was raised in (top frame)
                local m = errText:match('src[/\\]lexiftool[/\\]([%w_]+)%.lua:%d+')
                dev.errModule = m or (errText:find('src[/\\]lexiftool%.lua:%d+') and 'ExifTool') or nil
                dev.errLine = errText:match('^[^\n]*')
            end
            -- the first differing text file, and its first changed lines
            for _, f in ipairs(TEXT_FILES) do
                local a = o.refTree .. '/' .. r.dir .. '/' .. f
                local b = o.testTree .. '/' .. r.dir .. '/' .. f
                if Util.readFile(a) ~= Util.readFile(b) then
                    dev.file = f
                    local first
                    first, dev.lines = diffLines(a, b)
                    if r.label == 'v3' and f == 'stdout.txt' then
                        dev.group = groupOfV3(a, first)
                    else
                        for _, l in ipairs(dev.lines) do
                            dev.group = groupOfLine(l, f:match('^readback') and 'a-u-G1' or r.label, o, r)
                            if dev.group then break end
                        end
                    end
                    break
                end
            end
            if not dev.file then
                dev.file = r.diffs[1] or r.status
                dev.lines = {}
            end
            local make = r.name:match('^([^~]+)~') or r.name
            dev.module = dev.errModule or moduleOf(dev.group, o.repoDir)
            if not dev.module then
                local m = moduleOf(make, o.repoDir)
                dev.module = '(make) ' .. ((m and not m:match('%?$')) and m or make)
            end
            local mt = byModule[dev.module]
            if not mt then mt = { n = 0, labels = {} }; byModule[dev.module] = mt end
            mt.n = mt.n + 1
            mt.labels[r.label] = (mt.labels[r.label] or 0) + 1
            local pat = dev.errLine and ('Lua error: ' .. dev.errLine)
                or (r.label .. ': ' .. pattern(dev.lines[1]))
            patterns[pat] = (patterns[pat] or 0) + 1
            devs[#devs + 1] = dev
        end
    end

    local order = { 'a-u-G1', 'j-t', 'v3', 'X-struct', 'w-Artist', 'w-all', 's-make' }
    local known = {}
    for _, l in ipairs(order) do known[l] = true end
    for _, l in ipairs(labels) do if not known[l] then order[#order + 1] = l end end

    local nKnown = #knownCases
    local L = {}
    local function add(s) L[#L + 1] = s end
    local function pct(a, b) return b > 0 and ('%.1f'):format(a / b * 100) or '-' end

    add('# Corpus run: ' .. o.testName .. ' vs ' .. o.refName)
    add('')
    add('- Corpus: `' .. o.corpusDir .. '` -- ' .. o.files .. ' of ' .. o.allFiles .. ' files' ..
        (o.sampleN and (' (sample, seed ' .. o.seed .. ')') or ''))
    add(('- Cases: %d/%d identical, %d known (Perl internals), %d differing (%s %% identical)'):format(
        ok, total, nKnown, total - ok - nKnown, pct(ok, total)))
    add(('- Timeouts/hangs (%d s per call): %d in the tool under test, %d in the reference'):format(
        o.timeout, #timeouts, #refTimeouts))
    add(('- Lua errors with a traceback on stderr: %d'):format(#luaErrors))
    add('- Inspect a case: `diff -r ' .. o.refTree .. '/<case> ' .. o.testTree .. '/<case>`')
    add('')
    add('## Per case type')
    add('')
    add('| Case type | Cases | identical | % | known | differing | Timeouts |')
    add('|---|---:|---:|---:|---:|---:|---:|')
    for _, l in ipairs(order) do
        local t = byLabel[l]
        if t then
            add(('| %s | %d | %d | %s | %d | %d | %d |'):format(l, t.total, t.ok, pct(t.ok, t.total),
                t.known, t.differ, t.timeout))
        end
    end
    add('')
    add('## Per Lua module')
    add('')
    add('Heuristic attribution (see the head of src/test-cli/CorpusReport.lua); `(make) X` = attributed')
    add('through the manufacturer directory only, `X?` = a group no module is named after.')
    add('')
    local head, sep = { '| Module | Deviations' }, { '|---|---:' }
    for _, l in ipairs(order) do
        if byLabel[l] then head[#head + 1] = ' | ' .. l; sep[#sep + 1] = '|---:' end
    end
    add(table.concat(head) .. ' |')
    add(table.concat(sep) .. '|')
    local mods = {}
    for m in pairs(byModule) do mods[#mods + 1] = m end
    table.sort(mods, function(a, b)
        if byModule[a].n ~= byModule[b].n then return byModule[a].n > byModule[b].n end
        return a < b
    end)
    for _, m in ipairs(mods) do
        local row = { '| ' .. m .. ' | ' .. byModule[m].n }
        for _, l in ipairs(order) do
            if byLabel[l] then row[#row + 1] = ' | ' .. (byModule[m].labels[l] or '') end
        end
        add(table.concat(row) .. ' |')
    end
    add('')
    add('## Timeouts and hangs')
    add('')
    if #timeouts == 0 then add('none') end
    table.sort(timeouts)
    for _, d in ipairs(timeouts) do add('- `' .. d .. '`') end
    if #refTimeouts > 0 then
        add('')
        add('In the reference (Perl) itself:')
        table.sort(refTimeouts)
        for _, d in ipairs(refTimeouts) do add('- `' .. d .. '`') end
    end
    if #luaErrors > 0 then
        add('')
        add('## Lua errors (traceback on stderr)')
        add('')
        table.sort(luaErrors)
        for _, d in ipairs(luaErrors) do add('- `' .. d .. '`') end
    end
    add('')
    add('## Known (Perl internals)')
    add('')
    add('Not reproducible, reasons in doc/cli-tests.md "Known deviations"; counted only while the')
    add('difference has exactly the recorded form.')
    add('')
    if nKnown == 0 then add('none') end
    table.sort(knownCases, function(a, b) return a.dir < b.dir end)
    for _, e in ipairs(knownCases) do add('- `' .. e.dir .. '` (' .. e.file .. '): ' .. e.why) end
    if #knownChanged > 0 then
        add('')
        add('Known cases with a **different** difference than recorded (counted as deviations below):')
        table.sort(knownChanged)
        for _, d in ipairs(knownChanged) do add('- `' .. d .. '`') end
    end
    if #knownFixed > 0 then
        add('')
        add('Known cases that are identical now (remove their KNOWN entry):')
        table.sort(knownFixed)
        for _, d in ipairs(knownFixed) do add('- `' .. d .. '`') end
    end
    add('')
    add('## Most frequent diff patterns (first differing line, without values)')
    add('')
    add('| Count | Case type: pattern |')
    add('|---:|---|')
    local pats = {}
    for p, n in pairs(patterns) do pats[#pats + 1] = { p = p, n = n } end
    table.sort(pats, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.p < b.p end)
    for i = 1, math.min(40, #pats) do
        add(('| %d | `%s` |'):format(pats[i].n, (pats[i].p:gsub('|', '\\|'):gsub('`', "'"))))
    end
    add('')
    add('## Deviations (per module, with the first ' .. DIFF_LINES .. ' diff lines)')
    for _, m in ipairs(mods) do
        add('')
        add('### ' .. m .. ' (' .. byModule[m].n .. ')')
        for _, dev in ipairs(devs) do
            if dev.module == m then
                add('')
                add('`' .. dev.r.dir .. '` -- ' .. dev.file ..
                    (dev.timeout and ' **TIMEOUT**' or '') .. (dev.luaError and ' **Lua error**' or ''))
                if dev.errLine then add('`' .. dev.errLine:gsub('`', "'") .. '`') end
                if #dev.lines > 0 then
                    add('```')
                    for _, l in ipairs(dev.lines) do add((l:gsub('```', "'''"))) end
                    add('```')
                end
            end
        end
    end
    Util.writeFile(o.outDir .. '/summary.md', table.concat(L, '\n') .. '\n')
    return { timeouts = #timeouts, refTimeouts = #refTimeouts, luaErrors = #luaErrors, known = nKnown }
end

return CorpusReport
