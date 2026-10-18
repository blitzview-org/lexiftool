--------------------------------------------------------------------------------
-- File:         test-cli/corpus.lua
--
-- Description:  Corpus run (`make test-corpus`): the CLI golden mechanics of
--               main.lua applied to every file of an external sample corpus --
--               by default Phil Harvey's sample images from
--               https://exiftool.org/sample_images.html, fetched into
--               vendor/exiftool-samples/ by `make corpus-fetch`
--               (tools/fetch_corpus.sh). See doc/cli-tests.md, "Corpus run".
--
--               Same two phases as main.lua, same building blocks: the Runner (parallel worker processes
--               spawned through lexiftool.sys, one progress file per worker,
--               run.txt manifest), Compare (two trees -> results) and Report.
--               Differences:
--
--                 * the comparison is sharded over the workers as well
--                   (phase 'compare': every n-th case through Compare.cases,
--                   the results come back as build/test-corpus/compare-<w>.lua
--                   and are merged in tree order) -- 430 000 small files per
--                   run, which a serial pass makes the longest phase on a
--                   host with slow metadata I/O;
--
--                 * the case list is generated from the corpus (one directory
--                   per manufacturer) instead of Cases.lua -- see
--                   CorpusCases below;
--                 * the driver is CorpusDriver (timeout per call, write +
--                   readback in one case, input copies dropped after the
--                   fingerprint, every call run from the tree root with
--                   relative paths); like the golden harness it needs no
--                   shell and runs on Linux, macOS and Windows;
--                 * BOTH trees are resumable: a tree without run.txt is an
--                   interrupted run and continues where it stopped; a complete
--                   test tree (run.txt present), or one left by the other
--                   tool, is started afresh. The reference keeps its run.txt
--                   across a narrowed selection (TEST_CORPUS_MAKES/_SAMPLE/
--                   _TRACK): only a run over the whole corpus rewrites it;
--                 * the report adds summary.md (CorpusReport.lua): deviations
--                   per Lua module, per case type, timeouts, and the first
--                   diff lines of every deviation.
--
--               Gate (as in main.lua): a worker that died, or a case that
--               exists in only one tree, exits 2; with
--               TEST_CORPUS_EXPECT_IDENTICAL=1 every deviation beyond the
--               exactly matching known ones (CorpusReport.KNOWN) exits 1 --
--               and for the Perl self-check (the same tool ran twice) even a
--               "known" one does. Otherwise the run is a report (exit 0).
--
--               Env (all optional; the Makefile sets TEST_CORPUS_DIR):
--                 TEST_CORPUS_DIR      the corpus: <dir>/<Make>/<file>
--                                      (default vendor/exiftool-samples)
--                 TEST_CORPUS_TOOL     profile in the test role (lexiftool |
--                                      exiftool-perl)
--                 TEST_CORPUS_REGEN    1 = only build/complete the reference
--                 TEST_CORPUS_TRACK    read | write | stay | all
--                 TEST_CORPUS_MAKES    glob list of manufacturer directories
--                 TEST_CORPUS_SAMPLE   N = reproducible sample of N files
--                 TEST_CORPUS_SEED     seed of that sample (default 1)
--                 TEST_CORPUS_TIMEOUT  seconds per tool call (default 60)
--                 TEST_CORPUS_JOBS     worker count, or 'auto'
--                 TEST_CORPUS_MODE     session (default): one -stay_open
--                                      session per manufacturer and tool,
--                                      every call a command in it;
--                                      process: one process per call
--                 TEST_CORPUS_EXPECT_IDENTICAL  1 = deviations are a failure
--               Worker processes get TEST_CLI_PHASE/_WORKER/_NWORKERS from
--               Runner.spawn, exactly as in main.lua, and append one byte per
--               finished case to <runDir>/progress-<worker>, which the parent
--               polls.
--
-- Usage:        <interp> src/test-cli/corpus.lua   (package.path from the
--               Makefile, as for main.lua; run from the repository root)
--------------------------------------------------------------------------------

local TestLib      = require('test.TestLib')
local Util         = require('test-cli.Util')
local Profiles     = require('test-cli.Profiles')
local Runner       = require('test-cli.Runner')
local Compare      = require('test-cli.Compare')
local Report       = require('test-cli.Report')
local CorpusDriver = require('test-cli.CorpusDriver')
local CorpusReport = require('test-cli.CorpusReport')

--------------------------------------------------------------------------------
-- The case list. Per file: four reads and two writes (each followed by a
-- readback of the written copy); per manufacturer: one -stay_open session
-- reading all of its files. `@@` is the case's file, `@OUT@` its written copy.
--------------------------------------------------------------------------------
local CorpusCases = {
    read = {
        { label = 'a-u-G1',   args = '-a -u -G1 @@' },
        { label = 'j-t',      args = '-j -t @@' },
        { label = 'v3',       args = '-v3 @@' },
        { label = 'X-struct', args = '-X -struct @@' },
    },
    write = {
        { label = 'w-Artist', args = '-Artist=x -o %OUT%/ @@', readback = '-a -u -G1 @OUT@' },
        { label = 'w-all',    args = '-all= -o %OUT%/ @@',     readback = '-a -u -G1 @OUT@' },
    },
}

-- 32-bit FNV-1a: a sample that depends on nothing but seed and path, not on
-- the Lua version's random generator.
local function fnv1a(s)
    local h = 2166136261
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff
    end
    return h
end

local function globList(pattern)
    if not pattern or pattern == '' then return nil end
    local pats = {}
    for w in pattern:gmatch('%S+') do
        pats[#pats + 1] = '^' .. w:gsub('[%.%-%+%?%(%)%[%]%^%$%%]', '%%%0'):gsub('%*', '.*') .. '$'
    end
    return pats
end

local function matchesAny(pats, s)
    for _, p in ipairs(pats) do if s:match(p) then return true end end
    return false
end

-- All corpus files as { path, make, base }, sorted bytewise by
-- "<make>/<base>". archives/ (the downloads) is not part of the corpus.
local function collectFiles(dir, makesPattern)
    local files = {}
    local pats = globList(makesPattern)
    local ok, iter, obj = pcall(Util.lfs.dir, dir)
    if not ok or not iter then return files end
    for make in iter, obj do
        if make ~= '.' and make ~= '..' and make ~= 'archives' and
           (Util.lfs.attributes(dir .. '/' .. make) or {}).mode == 'directory' and
           (not pats or matchesAny(pats, make)) then
            for _, path in ipairs(Util.listFiles(dir .. '/' .. make)) do
                local base = path:match('[^/]+$')
                files[#files + 1] = { path = path, make = make, base = base, key = make .. '/' .. base }
            end
        end
    end
    table.sort(files, function(a, b) return a.key < b.key end)
    return files
end

-- A reproducible sample of n files across all manufacturers: every make
-- contributes its lowest-ranked file first (so none is missing), the rest is
-- filled in global rank order. Rank = fnv1a(seed .. relative path).
local function sample(files, n, seed)
    if not n or n >= #files then return files end
    local ranked = {}
    for _, f in ipairs(files) do
        ranked[#ranked + 1] = { f = f, rank = fnv1a(seed .. ':' .. f.make .. '/' .. f.base) }
    end
    table.sort(ranked, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.f.path < b.f.path
    end)
    local chosen, firstOfMake = {}, {}
    for _, r in ipairs(ranked) do
        if not firstOfMake[r.f.make] then
            firstOfMake[r.f.make] = true
            chosen[r.f] = true
        end
    end
    local count = 0
    for _ in pairs(chosen) do count = count + 1 end
    for _, r in ipairs(ranked) do
        if count >= n then break end
        if not chosen[r.f] then chosen[r.f] = true; count = count + 1 end
    end
    local out = {}
    for _, f in ipairs(files) do if chosen[f] then out[#out + 1] = f end end
    return out
end

local function buildCases(files, track)
    local cases = {}
    local function want(g) return track == 'all' or track == g end
    for _, group in ipairs({ 'read', 'write' }) do
        if want(group) then
            for _, v in ipairs(CorpusCases[group]) do
                for _, f in ipairs(files) do
                    local name = f.make .. '~' .. f.base
                    cases[#cases + 1] = {
                        group = group, label = v.label, name = name,
                        args = v.args, readback = v.readback, images = { f.path },
                        prepare = 'file', over = 'each', make = f.make,
                        dir = group .. '/' .. v.label .. '/' .. name,
                    }
                end
            end
        end
    end
    if want('stay') then
        local byMake, order = {}, {}
        for _, f in ipairs(files) do
            if not byMake[f.make] then byMake[f.make] = {}; order[#order + 1] = f.make end
            table.insert(byMake[f.make], f)
        end
        for _, make in ipairs(order) do
            local feed, images = {}, {}
            for i, f in ipairs(byMake[make]) do
                images[i] = f.path
                feed[#feed + 1] = ('-a\n-u\n-G1\n%%IN%%/%s\n-execute%d\n'):format(f.base, i)
                feed[#feed + 1] = { ready = i }
            end
            feed[#feed + 1] = '-stay_open\nFalse\n'
            cases[#cases + 1] = {
                group = 'stay', label = 's-make', name = make,
                args = '-stay_open True -@ -', feed = feed, commands = #images,
                images = images, prepare = 'file', over = 'all', make = make,
                dir = 'stay/s-make/' .. make,
            }
        end
    end
    return cases
end

--------------------------------------------------------------------------------
-- Configuration (identical in the parent and every worker)
--------------------------------------------------------------------------------
local cfg = {}
do
    -- An absolute repository root, as in Config.load (a drive letter counts).
    local isWindows = package.config:sub(1, 1) == '\\'
    local function norm(p) return isWindows and (p:gsub('\\', '/')) or p end
    local repoDir = norm(TestLib.REPO_DIR)
    if repoDir:sub(1, 1) ~= '/' and not repoDir:match('^%a:/') then
        repoDir = norm(Util.lfs.currentdir()) .. '/' .. repoDir
    end
    cfg.repoDir = repoDir
    -- Trees and scratch belong to the repository, as in Config.load; the
    -- corpus (gitignored) defaults to vendor/exiftool-samples/ in it.
    local corpusDir = os.getenv('TEST_CORPUS_DIR')
    if corpusDir == nil or corpusDir == '' then corpusDir = repoDir .. '/vendor/exiftool-samples' end
    cfg.corpusDir = (norm(corpusDir):gsub('(.)/+$', '%1'))
    cfg.refTree = repoDir .. '/test-corpus-ref'
    cfg.outTree = repoDir .. '/test-corpus-out'
    cfg.runDir = repoDir .. '/build/test-corpus'
    cfg.mode = os.getenv('TEST_CORPUS_REGEN') and 'gen' or 'compare'
    cfg.track = os.getenv('TEST_CORPUS_TRACK') or 'all'
    cfg.timeout = tonumber(os.getenv('TEST_CORPUS_TIMEOUT') or '') or 60
    cfg.sampleN = tonumber(os.getenv('TEST_CORPUS_SAMPLE') or '')
    cfg.seed = os.getenv('TEST_CORPUS_SEED') or '1'
    cfg.corpusMode = os.getenv('TEST_CORPUS_MODE') or ''
    if cfg.corpusMode == '' then cfg.corpusMode = 'session' end
    if cfg.corpusMode ~= 'session' and cfg.corpusMode ~= 'process' then
        io.stderr:write('test-corpus: TEST_CORPUS_MODE must be session or process\n')
        os.exit(2)
    end

    cfg.phase = os.getenv('TEST_CLI_PHASE')
    cfg.workerId = tonumber(os.getenv('TEST_CLI_WORKER') or '')
    cfg.nworkers = math.max(1, tonumber(os.getenv('TEST_CLI_NWORKERS') or '') or 1)
    cfg.isWorker = cfg.workerId ~= nil
    local jobs = os.getenv('TEST_CORPUS_JOBS')
    if jobs == nil or jobs == '' or jobs == 'auto' then
        cfg.jobs = Util.cpuCount()
    else
        cfg.jobs = math.max(1, math.floor(tonumber(jobs) or 1))
    end
    cfg.luaBin = arg[-1] or 'lua'
    cfg.script = arg[0]

    cfg.profiles = Profiles.build({
        repoDir      = repoDir,
        luaBin       = cfg.luaBin,
        lexiftool    = repoDir .. '/lexiftool',
        perlBin      = os.getenv('TEST_CLI_PERL') ~= '' and os.getenv('TEST_CLI_PERL') or 'perl',
        perlLib      = repoDir .. '/vendor/exiftool/lib',
        perlExiftool = repoDir .. '/vendor/exiftool/exiftool',
    })
    local testName = os.getenv('TEST_CORPUS_TOOL')
    if testName == nil or testName == '' then testName = 'lexiftool' end
    cfg.test = cfg.profiles[testName]
    cfg.ref = cfg.profiles[Profiles.REFERENCE]
    if not cfg.test then
        io.stderr:write('test-corpus: unknown TEST_CORPUS_TOOL "' .. testName .. '"\n')
        os.exit(2)
    end

    local makes = os.getenv('TEST_CORPUS_MAKES')
    cfg.allFiles = collectFiles(cfg.corpusDir, makes)
    -- the whole corpus, every case type: only such a run (re)writes the
    -- reference's run.txt, a narrowed one keeps the manifest it found
    cfg.fullSelection = (makes == nil or makes == '') and not cfg.sampleN and cfg.track == 'all'
    cfg.files = sample(cfg.allFiles, cfg.sampleN, cfg.seed)
    cfg.cases = buildCases(cfg.files, cfg.track)
    cfg.driverCfg = {
        repoDir = repoDir, imagesDir = cfg.corpusDir,
        srcImage = repoDir .. '/vendor/exiftool/t/images/ExifTool.jpg',
        timeout = cfg.timeout,
    }
end

local function phaseSpec(name)
    if name == 'ref' then
        return { name = 'ref', tool = cfg.ref, tree = cfg.refTree, label = 'building reference' }
    end
    return { name = 'test', tool = cfg.test, tree = cfg.outTree, label = 'running ' .. cfg.test.name }
end

-- Session mode shards by manufacturer, not by case: each make is one
-- session and belongs to exactly one worker. Makes are dealt largest first
-- to the least loaded shard (deterministic, so every worker computes the
-- same assignment); the largest make bounds the wall time from below.
local function makeShards(nshards)
    local size, order = {}, {}
    for _, c in ipairs(cfg.cases) do
        if not size[c.make] then size[c.make] = 0; order[#order + 1] = c.make end
        size[c.make] = size[c.make] + 1
    end
    table.sort(order, function(a, b)
        if size[a] ~= size[b] then return size[a] > size[b] end
        return a < b
    end)
    local load, owner = {}, {}
    for s = 1, nshards do load[s] = 0 end
    for _, make in ipairs(order) do
        local best = 1
        for s = 2, nshards do if load[s] < load[best] then best = s end end
        owner[make] = best
        load[best] = load[best] + size[make]
    end
    return owner, #order
end

-- Runner.shard with the corpus driver; always resumes (skips cases whose
-- stat.txt exists).
local function shard(spec, shardNo, nshards, report)
    local driver = CorpusDriver.new(cfg.driverCfg)
    local function pendingCase(case)
        return not Util.fileExists(spec.tree .. '/' .. case.dir .. '/stat.txt')
    end
    if cfg.corpusMode == 'process' then
        for i, case in ipairs(cfg.cases) do
            if (i - 1) % nshards + 1 == shardNo and pendingCase(case) then
                driver:runCase(spec.tool, case, spec.tree .. '/' .. case.dir)
                report()
            end
        end
        return
    end
    local owner = makeShards(nshards)
    local byMake, makes = {}, {}
    for _, case in ipairs(cfg.cases) do
        if owner[case.make] == shardNo and pendingCase(case) then
            if not byMake[case.make] then byMake[case.make] = {}; makes[#makes + 1] = case.make end
            table.insert(byMake[case.make], case)
        end
    end
    -- the case list is grouped by type; a session goes file by file
    local typeRank = {}
    for g, group in pairs(CorpusCases) do
        for i, v in ipairs(group) do typeRank[g .. '/' .. v.label] = (g == 'read' and 0 or 10) + i end
    end
    for _, make in ipairs(makes) do
        local calls = {}
        for _, case in ipairs(byMake[make]) do
            if case.feed then
                -- the stay/s-make case is a scripted session of its own
                driver:runCase(spec.tool, case, spec.tree .. '/' .. case.dir)
                report()
            else
                calls[#calls + 1] = case
            end
        end
        table.sort(calls, function(a, b)
            if a.images[1] ~= b.images[1] then return a.images[1] < b.images[1] end
            return typeRank[a.group .. '/' .. a.label] < typeRank[b.group .. '/' .. b.label]
        end)
        if #calls > 0 then
            local scratch = cfg.runDir .. '/' .. spec.name .. '-' .. make
            Util.ensureDir(scratch)
            driver:runMake(spec.tool, calls, spec.tree, scratch, report)
            Util.rmrf(scratch)
        end
    end
end

--------------------------------------------------------------------------------
-- Worker mode
--------------------------------------------------------------------------------
-- Serialised results of a compare shard (Lua source, read back by the parent).
local function dumpResults(results)
    local out = { 'return {\n' }
    for _, r in ipairs(results) do
        local diffs = {}
        for i, d in ipairs(r.diffs) do diffs[i] = ('%q'):format(d) end
        out[#out + 1] = ('{ dir = %q, status = %q, effective = %s, refTimeout = %s, testTimeout = %s, diffs = { %s } },\n')
            :format(r.dir, r.status, tostring(r.effective), tostring(r.refTimeout),
                    tostring(r.testTimeout), table.concat(diffs, ', '))
    end
    out[#out + 1] = '}\n'
    return table.concat(out)
end

-- Shard `shardNo` of `nshards` of the comparison: every nshards-th case.
local function compareShard(shardNo, nshards, report)
    local dirs = {}
    for i, case in ipairs(cfg.cases) do
        if (i - 1) % nshards + 1 == shardNo then dirs[#dirs + 1] = case.dir end
    end
    return Compare.cases({ refTree = cfg.refTree, testTree = cfg.outTree, dirs = dirs,
                           onProgress = report })
end

if cfg.isWorker then
    local sink = io.open(cfg.runDir .. '/progress-' .. cfg.workerId, 'ab')
    local function report()
        if sink then sink:write('.'); sink:flush() end
    end
    local okRun, err
    if cfg.phase == 'compare' then
        local results
        okRun, results = xpcall(compareShard, debug.traceback, cfg.workerId, cfg.nworkers, report)
        if okRun then
            Util.writeFile(cfg.runDir .. '/compare-' .. cfg.workerId .. '.lua', dumpResults(results))
        else
            err = results
        end
    else
        okRun, err = xpcall(shard, debug.traceback, phaseSpec(cfg.phase), cfg.workerId, cfg.nworkers, report)
    end
    if sink then sink:close() end
    if not okRun then io.stderr:write('test-corpus worker: ' .. tostring(err) .. '\n') end
    os.exit(okRun and 0 or 1)
end

--------------------------------------------------------------------------------
-- Parent
--------------------------------------------------------------------------------
if #cfg.files == 0 then
    io.stderr:write('test-corpus: no files under ' .. cfg.corpusDir ..
                    ' (fetch them with: make corpus-fetch)\n')
    os.exit(2)
end
Util.rmrf(cfg.runDir)
Util.ensureDir(cfg.runDir)

local exiftoolVersion
do
    local argv = { table.unpack(cfg.ref.argv) }
    argv[#argv + 1] = '-ver'
    exiftoolVersion = (Util.runCapture(argv):gsub('%s+$', ''))
end

local function manifest(spec)
    local names = {}
    for _, f in ipairs(cfg.files) do names[#names + 1] = f.make .. '~' .. f.base end
    return Runner.manifest({ tool = spec.tool, cases = cfg.cases,
                             images = names, exiftoolVersion = exiftoolVersion })
        .. 'corpus: ' .. cfg.corpusDir .. '\n'
        .. 'track: ' .. cfg.track .. '\n'
        .. 'timeout: ' .. cfg.timeout .. '\n'
        .. 'mode: ' .. cfg.corpusMode .. '\n'
end

-- What makes a tree's cases incomparable with another's: the environment
-- and the reference tool. A reference tree is kept across selections (its
-- cases are per file, so a narrower TEST_CORPUS_MAKES just reuses some of
-- them) and wiped only when this changes. A test tree is continued only when
-- it is an interrupted run of the same tool over the same selection; a
-- complete one (run.txt present) or any other starts afresh.
local function envKey()
    return table.concat({
        'TZ: ' .. (os.getenv('TZ') or ''), 'LC_ALL: ' .. (os.getenv('LC_ALL') or ''),
        'exiftool: ' .. exiftoolVersion, 'timeout: ' .. cfg.timeout,
        -- Perl's own output depends on the mode (a session keeps module state
        -- across commands; doc/cli-tests.md), so a reference is per mode
        'mode: ' .. cfg.corpusMode,
        -- the layout of the case directories (2: relative paths from the
        -- tree root, md5 fingerprints); a tree in another layout is rebuilt
        'format: ' .. CorpusDriver.FORMAT,
    }, '\n') .. '\n'
end

local function prepareTree(spec)
    local runTxt = spec.tree .. '/run.txt'
    local startTxt = spec.tree .. '/.started'
    local want = spec.name == 'test' and manifest(spec) or envKey()
    local have = Util.readFile(startTxt)
    if (spec.name == 'test' and Util.fileExists(runTxt)) or (have and have ~= want) then
        Util.rmrf(spec.tree)
    end
    Util.ensureDir(spec.tree)
    Util.writeFile(startTxt, want)
    -- the reference's manifest only goes with the tree (wiped above) or when
    -- a full run replaces it at the end; a test tree's always goes
    if spec.name == 'test' then os.remove(runTxt) end
end

local function pending(tree)
    local n = 0
    for _, case in ipairs(cfg.cases) do
        if not Util.fileExists(tree .. '/' .. case.dir .. '/stat.txt') then n = n + 1 end
    end
    return n
end

local counts = { read = 0, write = 0, stay = 0 }
for _, c in ipairs(cfg.cases) do counts[c.group] = counts[c.group] + 1 end
if cfg.mode == 'gen' then
    io.stdout:write(('Corpus reference: %s\n'):format(cfg.ref.name))
else
    io.stdout:write(('Corpus comparison: %s vs %s (reference)\n'):format(cfg.test.name, cfg.ref.name))
end
io.stdout:write(('  corpus %s\n  %d cases: %d read, %d write, %d stay   (%d of %d files%s, timeout %d s, %s mode)\n\n')
    :format(cfg.corpusDir, #cfg.cases, counts.read, counts.write, counts.stay,
            #cfg.files, #cfg.allFiles,
            cfg.sampleN and (', sample seed ' .. cfg.seed) or '', cfg.timeout, cfg.corpusMode))
io.stdout:flush()

local phases = {}
-- The reference phase always runs; with a complete tree it only skips.
phases[#phases + 1] = phaseSpec('ref')
if cfg.mode == 'compare' then
    phases[#phases + 1] = phaseSpec('test')
    phases[#phases + 1] = { name = 'compare', label = 'comparing' }
end

local function progressLine(idx, label, done, total, suffix)
    local pct = total > 0 and math.floor(done / total * 100) or 100
    io.stdout:write(('\r  [%d/%d] %-26s %3d%% (%d/%d)%s'):format(
        idx, #phases, label, pct, done, total, suffix or ''))
    io.stdout:flush()
end

local results
for idx, spec in ipairs(phases) do
    if spec.name == 'compare' then
        local total = #cfg.cases
        local ok, err = Compare.comparable(cfg.refTree, cfg.outTree, 'make test-corpus-gen')
        if not ok then
            io.stderr:write('test-corpus: ' .. err .. '\n')
            os.exit(2)
        end
        progressLine(idx, spec.label, 0, total)
        local started = os.time()
        -- The comparison is file I/O over every case of both trees; it is
        -- sharded over the same workers as the runs (each case stands alone),
        -- which also keeps the files a worker just wrote in its own cache.
        local workers = math.min(cfg.jobs, math.max(1, total))
        if workers > 1 then
            local failed = Runner.spawn({
                jobs = workers, luaBin = cfg.luaBin, script = cfg.script,
                runDir = cfg.runDir, phase = 'compare',
                onProgress = function(done) progressLine(idx, spec.label, done, total) end,
            })
            if failed > 0 then
                io.stdout:write('\n')
                io.stderr:write(('test-corpus: %d of %d workers failed (%s/worker-*.err)\n')
                    :format(failed, workers, cfg.runDir))
                os.exit(2)
            end
            results = {}
            for w = 1, workers do
                local path = cfg.runDir .. '/compare-' .. w .. '.lua'
                local chunk = load(Util.readFile(path) or '', '=' .. path, 't', {})
                local part = chunk and chunk()
                if type(part) ~= 'table' then
                    io.stdout:write('\n')
                    io.stderr:write('test-corpus: no results from compare worker ' .. w .. ' (' .. path .. ')\n')
                    os.exit(2)
                end
                for _, r in ipairs(part) do
                    r.group, r.label, r.name = r.dir:match('^([^/]+)/([^/]+)/(.+)$')
                    results[#results + 1] = r
                end
            end
            -- tree order, as a scan of the reference would list the cases
            table.sort(results, function(a, b)
                if a.group ~= b.group then return a.group < b.group end
                if a.label ~= b.label then return a.label < b.label end
                return a.name < b.name
            end)
        else
            results = compareShard(1, 1, function(done)
                if done % 200 == 0 then progressLine(idx, spec.label, done, total) end
            end)
        end
        progressLine(idx, spec.label, total, total,
            ('   (%d worker%s, %d s)\n'):format(workers, workers == 1 and '' or 's', os.time() - started))
    else
        prepareTree(spec)
        local total = #cfg.cases
        -- one pass over the tree: the cases still to do and (session mode)
        -- the manufacturers they belong to -- a worker per manufacturer at most
        local skipped, makes, nmakes = 0, {}, 0
        for _, c in ipairs(cfg.cases) do
            if Util.fileExists(spec.tree .. '/' .. c.dir .. '/stat.txt') then
                skipped = skipped + 1
            elseif not makes[c.make] then
                makes[c.make] = true
                nmakes = nmakes + 1
            end
        end
        local started = os.time()
        progressLine(idx, spec.label, skipped, total)
        local units = cfg.corpusMode == 'session' and nmakes or (total - skipped)
        local workers = math.min(cfg.jobs, math.max(1, units))
        if total - skipped > 0 then
            if workers > 1 then
                -- A worker that died left its shard unfinished: a harness
                -- failure, not a result (as in main.lua's runPhase).
                local failed = Runner.spawn({
                    jobs = workers, luaBin = cfg.luaBin, script = cfg.script,
                    runDir = cfg.runDir, phase = spec.name,
                    onProgress = function(done) progressLine(idx, spec.label, skipped + done, total) end,
                })
                if failed > 0 then
                    io.stdout:write('\n')
                    io.stderr:write(('test-corpus: %d of %d workers failed (%s/worker-*.err)\n')
                        :format(failed, workers, cfg.runDir))
                    os.exit(2)
                end
            else
                local done = skipped
                shard(spec, 1, 1, function()
                    done = done + 1
                    progressLine(idx, spec.label, done, total)
                end)
            end
        end
        -- Only a phase that really completed gets its run.txt: an interrupted
        -- one (Ctrl-C) leaves cases without stat.txt and no manifest.
        if pending(spec.tree) > 0 then
            io.stdout:write('\n')
            io.stderr:write(('test-corpus: %s incomplete (%d cases left); run again to resume\n')
                :format(spec.tree, pending(spec.tree)))
            os.exit(1)
        end
        local runTxt = spec.tree .. '/run.txt'
        if spec.name == 'test' or cfg.fullSelection or not Util.fileExists(runTxt) then
            Util.writeFile(runTxt, manifest(spec))
        end
        progressLine(idx, spec.label, total, total,
            ('   (%d worker%s, %d s%s)\n'):format(workers, workers == 1 and '' or 's',
                os.time() - started, skipped > 0 and (', ' .. skipped .. ' resumed') or ''))
    end
end

if not results then
    io.stdout:write(('\n  reference complete in %s\n'):format(cfg.refTree))
    os.exit(0)
end

local sum = Report.write(results, {
    outDir = cfg.outTree, refTree = cfg.refTree, testTree = cfg.outTree,
    testName = cfg.test.name, refName = cfg.ref.name, regenTarget = 'test-corpus-gen',
})
local extra = CorpusReport.write(results, {
    outDir = cfg.outTree, refTree = cfg.refTree, testTree = cfg.outTree,
    testName = cfg.test.name, refName = cfg.ref.name, corpusDir = cfg.corpusDir,
    files = #cfg.files, allFiles = #cfg.allFiles, sampleN = cfg.sampleN, seed = cfg.seed,
    repoDir = cfg.repoDir, timeout = cfg.timeout,
})

local differing = sum.total - sum.ok - extra.known
io.stdout:write(('\n  %d/%d identical, %d known (Perl internals), %d differing\n'):format(
    sum.ok, sum.total, extra.known, differing))
if extra.timeouts > 0 then
    io.stdout:write(('  %d timeouts/hangs in %s\n'):format(extra.timeouts, cfg.test.name))
end
if sum.differs > 0 then
    io.stdout:write(('  details              -> %s/summary.md\n'):format(cfg.outTree))
end
-- A case that exists in only one tree is a failure of the harness or its
-- setup (a stale or incomplete reference), never a result: exit 2, as
-- main.lua does.
if sum.missing > 0 then
    io.stderr:write(('test-corpus: %d case(s) exist in only one tree; the trees are not comparable\n')
        :format(sum.missing))
    os.exit(2)
end
-- With TEST_CORPUS_EXPECT_IDENTICAL a deviation IS a failure. For lexiftool
-- the known cases (CorpusReport.KNOWN, matched to the byte) do not count; for
-- the Perl self-check nothing may differ at all -- the same tool ran twice,
-- so even a "known" difference means the harness is not deterministic.
if os.getenv('TEST_CORPUS_EXPECT_IDENTICAL') == '1' then
    if cfg.test.name == cfg.ref.name then
        if sum.differs > 0 then
            io.stderr:write(('test-corpus: %d difference(s) where none may be; the harness is not deterministic\n')
                :format(sum.differs))
            os.exit(1)
        end
    elseif differing > 0 then
        io.stderr:write(('test-corpus: %s differs from %s in %d case(s) beyond the known ones; see %s/summary.md\n')
            :format(cfg.test.name, cfg.ref.name, differing, cfg.outTree))
        os.exit(1)
    end
end
os.exit(0)
