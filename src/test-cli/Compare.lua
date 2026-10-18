--------------------------------------------------------------------------------
-- File:         test-cli/Compare.lua
--
-- Description:  Compares two observation trees and says, per case, whether they
--               agree.
--
--                   Compare.run{ refTree = …, testTree = … } -> results
--
--               It knows neither tool nor case list. Names and grouping come
--               from the paths, everything else from the files in the tree --
--               the trees are self-describing, so this is a standalone tool
--               that works on any two of them. Compare.cases{ dirs = … } is
--               the same comparison for a given list of case directories,
--               without scanning the trees: a worker's shard (corpus.lua).
--
--               `diff -r <refTree> <testTree>` is the manual fallback and gives
--               the same verdict; what this adds is structure: a per-case
--               status, WHICH file inside the case differs (and for files under
--               work/, whether it was the content, the size, the mtime or the
--               permissions), aggregation per variant, and the effectiveness
--               check below.
--
--               Files under work/ are not read: stat.txt already carries their
--               path, size, mtime class, permissions and content hash, so
--               comparing stat.txt compares work/ -- and does so including the
--               metadata `diff -r` cannot see.
--------------------------------------------------------------------------------

local Util = require('test-cli.Util')

local Compare = {}

-- Case directories are exactly <group>/<label>/<name>, so their own files sit
-- at depth 4 and everything under work/ is deeper. Walk the three directory
-- levels directly; no shell find(1), so this also runs on Windows.
local lfs = Util.lfs

local function names(dir)
    local out = {}
    local ok, iter, obj = pcall(lfs.dir, dir)
    if not ok or not iter then return out end
    for f in iter, obj do
        if f ~= '.' and f ~= '..' then out[#out + 1] = f end
    end
    table.sort(out)
    return out
end

local function scan(tree)
    local cases, order = {}, {}
    for _, group in ipairs(names(tree)) do
        local gdir = tree .. '/' .. group
        if (lfs.attributes(gdir) or {}).mode == 'directory' then
            for _, label in ipairs(names(gdir)) do
                local ldir = gdir .. '/' .. label
                if (lfs.attributes(ldir) or {}).mode == 'directory' then
                    for _, name in ipairs(names(ldir)) do
                        local cdir = ldir .. '/' .. name
                        if (lfs.attributes(cdir) or {}).mode == 'directory' then
                            local dir = group .. '/' .. label .. '/' .. name
                            local c = {}
                            for _, f in ipairs(names(cdir)) do
                                if (lfs.attributes(cdir .. '/' .. f) or {}).mode == 'file' then
                                    c[f] = true
                                end
                            end
                            cases[dir] = c
                            order[#order + 1] = dir
                        end
                    end
                end
            end
        end
    end
    return cases, order
end

-- stat.txt lines are "<path>\t<size> <mtime> <mode>\t<hash>".
local function statMap(text)
    local map, order = {}, {}
    for line in (text or ''):gmatch('[^\n]+') do
        local path, rest = line:match('^(.-)\t(.*)$')
        if path then
            path = path:gsub('^%./', '')
            map[path] = rest
            order[#order + 1] = path
        end
    end
    return map, order
end

local function whatChanged(a, b)
    local sa, ma, pa, ha = a:match('^(%S+) (%S+) (%S+)\t(%x+)$')
    local sb, mb, pb, hb = b:match('^(%S+) (%S+) (%S+)\t(%x+)$')
    if not sa or not sb then return 'differs' end
    local w = {}
    if ha ~= hb then w[#w + 1] = 'content' end
    if sa ~= sb then w[#w + 1] = 'size ' .. sa .. '/' .. sb end
    if ma ~= mb then w[#w + 1] = 'mtime ' .. ma .. '/' .. mb end
    if pa ~= pb then w[#w + 1] = 'mode ' .. pa .. '/' .. pb end
    return table.concat(w, ', ')
end

-- A differing stat file is reported per work/ entry rather than as one opaque
-- "stat.txt differs" -- that is the difference between "the tool wrote the
-- wrong bytes" and "the tool wrote nothing at all".
local function statDiffs(label, a, b)
    local ma, order = statMap(a)
    local mb = statMap(b)
    local out, seen = {}, {}
    for _, path in ipairs(order) do
        seen[path] = true
        if mb[path] == nil then
            out[#out + 1] = label .. ': work/' .. path .. ' (missing in test)'
        elseif mb[path] ~= ma[path] then
            out[#out + 1] = label .. ': work/' .. path .. ' (' .. whatChanged(ma[path], mb[path]) .. ')'
        end
    end
    for path in pairs(mb) do
        if not seen[path] then
            out[#out + 1] = label .. ': work/' .. path .. ' (only in test)'
        end
    end
    table.sort(out)
    return out
end

-- Two trees are only comparable when their environment (timezone, locale and
-- the reference tool's version) matches; the tool identity is of course
-- expected to differ. The case/image counts are informational: a narrowed run
-- (TEST_CLI_TRACK, TEST_CLI_IMAGES, TEST_CLI_LIMIT) compares the subset it
-- selected against a reference tree that may hold more cases.
local function comparableKey(tree)
    local keep = {}
    for line in (Util.readFile(tree .. '/run.txt') or ''):gmatch('[^\n]+') do
        local key = line:match('^(%S+):')
        if key == 'TZ' or key == 'LC_ALL' or key == 'exiftool' then
            keep[#keep + 1] = line
        end
    end
    return table.concat(keep, '\n')
end

-- o: refTree, testTree, onProgress (optional)
-- Returns results, or nil plus a message when the trees cannot be compared.
-- Exit codes are compared by outcome: both zero, or both non-zero. The
-- value of a non-zero code is the implementation's (Perl's `die` exits with
-- whatever errno was left over from an unrelated earlier failure, e.g. 2
-- from the @INC search for a module); what must agree is whether the call
-- failed at all.
local function sameOutcome(a, b)
    local x = tonumber((a or ''):match('^%s*(%S+)'))
    local y = tonumber((b or ''):match('^%s*(%S+)'))
    return x ~= nil and y ~= nil and (x == 0) == (y == 0)
end

-- Whether the two trees may be compared at all (see comparableKey); the
-- message names the manifests and the regen target `regen`.
function Compare.comparable(refTree, testTree, regen)
    if comparableKey(refTree) == comparableKey(testTree) then return true end
    return nil, 'the two trees were produced with a different environment or\n' ..
                '  image selection and cannot be compared:\n' ..
                '    ' .. refTree .. '/run.txt\n' ..
                '    ' .. testTree .. '/run.txt\n' ..
                '  Rebuild the reference with:  ' .. (regen or 'make test-cli-gen')
end

-- The files of one case directory (a set of names), or nil when the case
-- directory does not exist. Same rule as scan(): only plain files count,
-- work/ is covered by stat.txt.
local function caseFiles(cdir)
    if (lfs.attributes(cdir) or {}).mode ~= 'directory' then return nil end
    local c = {}
    for _, f in ipairs(names(cdir)) do
        if (lfs.attributes(cdir .. '/' .. f) or {}).mode == 'file' then c[f] = true end
    end
    return c
end

-- A call that hit the harness timeout: exit 124/137 (timeout(1) and SIGKILL
-- conventions, which the drivers reproduce) or a TIMEOUT mark in a session
-- feed. Computed from the files the comparison reads anyway, so the report
-- need not open them again.
local function timedOut(files)
    for _, f in ipairs({ 'exit.txt', 'readback-exit.txt' }) do
        local c = (files[f] or ''):match('%-?%d+')
        if c == '124' or c == '137' then return true end
    end
    return (files['feed.txt'] or ''):find('TIMEOUT', 1, true) ~= nil
end

-- One case: `refSet`/`testSet` are the file-name sets of its directory in
-- either tree (nil = the case is absent there). Returns the result record.
local function compareCase(o, dir, refSet, testSet)
    local group, label, name = dir:match('^([^/]+)/([^/]+)/(.+)$')
    label = label:gsub('~lc$', '')   -- (the directory's twin marker, see Cases.build)
    local r = { group = group, label = label, name = name, dir = dir, diffs = {} }

    -- Read the reference side once; the effectiveness check needs the same
    -- files the comparison does. A case absent from the reference is
    -- reported below, so guard the read.
    local refFiles = {}
    if refSet then
        for file in pairs(refSet) do
            refFiles[file] = Util.readFile(o.refTree .. '/' .. dir .. '/' .. file)
        end
    end

    -- Did the REFERENCE produce anything observable at all? Every channel
    -- the comparison looks at counts -- output, a complaint, a non-zero
    -- status, a touched file. Leaving stderr and the exit code out (as an
    -- earlier version did) mislabels a case like `-Model` on a PNG, where
    -- upstream prints nothing but does warn.
    --
    -- Silence can be entirely correct: `-GPS:all` on a file without GPS
    -- prints nothing and changes nothing, and the port matching that IS
    -- ported behaviour. The flag exists for the aggregate below: a variant
    -- whose reference stays silent for EVERY case is usually a broken
    -- matrix entry rather than a run of legitimate no-ops.
    r.effective = refSet ~= nil and (
           (#(refFiles['stdout.txt'] or '') > 0)
        or (#(refFiles['stderr.txt'] or '') > 0)
        or ((refFiles['exit.txt'] or '0\n'):match('^%s*(%S*)') ~= '0')
        or (refFiles['stat-before.txt'] ~= refFiles['stat.txt']))
    r.refTimeout = refSet ~= nil and timedOut(refFiles)

    if not refSet then
        r.status = 'missing-ref'
    elseif not testSet then
        r.status = 'missing-test'
    else
        local files = {}
        for file in pairs(refSet) do files[#files + 1] = file end
        for file in pairs(testSet) do
            if not refSet[file] then files[#files + 1] = file end
        end
        table.sort(files)
        local testFiles = {}
        for _, file in ipairs(files) do
            local a = refFiles[file]
            local b = Util.readFile(o.testTree .. '/' .. dir .. '/' .. file)
            testFiles[file] = b
            local same = a == b or (file == 'exit.txt' and sameOutcome(a, b))
            if not same then
                if file == 'stat.txt' or file == 'stat-before.txt' then
                    for _, d in ipairs(statDiffs(file, a, b)) do
                        r.diffs[#r.diffs + 1] = d
                    end
                else
                    r.diffs[#r.diffs + 1] = file
                end
            end
        end
        r.testTimeout = timedOut(testFiles)
        r.status = (#r.diffs == 0) and 'ok' or 'differs'
    end
    return r
end

-- o: refTree, testTree, onProgress (optional)
-- Returns results, or nil plus a message when the trees cannot be compared.
-- The case list is what the reference tree holds (scanned), so this works on
-- any two trees without knowing how they were made.
function Compare.run(o)
    local ok, err = Compare.comparable(o.refTree, o.testTree)
    if not ok then return nil, err end

    local ref, refOrder = scan(o.refTree)
    local test = scan(o.testTree)
    local order = refOrder
    if o.cases then
        order = {}
        for _, case in ipairs(o.cases) do order[#order + 1] = case.dir end
    end
    local results = {}
    local done, okCount = 0, 0

    for _, dir in ipairs(order) do
        local r = compareCase(o, dir, ref[dir], test[dir])
        if test[dir] then test[dir] = nil end
        results[#results + 1] = r
        done = done + 1
        if r.status == 'ok' then okCount = okCount + 1 end
        if o.onProgress then o.onProgress(done, okCount) end
    end

    -- Anything the test run produced that the reference does not have. Normally
    -- empty; it happens when the reference tree predates a new variant. With an
    -- explicit case list the list is the whole truth -- cases outside it are
    -- not part of this run.
    local extra = {}
    if not o.cases then
        for dir in pairs(test) do extra[#extra + 1] = dir end
    end
    table.sort(extra)
    for _, dir in ipairs(extra) do
        local group, label, name = dir:match('^([^/]+)/([^/]+)/(.+)$')
        label = label:gsub('~lc$', '')   -- (the directory's twin marker, see Cases.build)
        results[#results + 1] = { group = group, label = label, name = name, dir = dir,
                                  status = 'missing-ref', effective = true, diffs = {} }
    end

    return results
end

-- o: refTree, testTree, dirs (case directories, relative), onProgress
-- The same comparison for a known case list, without scanning the trees:
-- each case directory is listed on both sides when its turn comes, so a
-- file present on one side only is still seen, and a case absent from a
-- tree is still reported (missing-ref / missing-test). Independent of any
-- other case, so a worker can take a shard of the list (corpus.lua).
-- The caller has checked Compare.comparable.
function Compare.cases(o)
    local results = {}
    local done, okCount = 0, 0
    for _, dir in ipairs(o.dirs) do
        local r = compareCase(o, dir, caseFiles(o.refTree .. '/' .. dir),
                                      caseFiles(o.testTree .. '/' .. dir))
        results[#results + 1] = r
        done = done + 1
        if r.status == 'ok' then okCount = okCount + 1 end
        if o.onProgress then o.onProgress(done, okCount) end
    end
    return results
end

return Compare
