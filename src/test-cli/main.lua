--------------------------------------------------------------------------------
-- File:         test-cli/main.lua
--
-- Description:  CLI golden test. Runs a tool over the case matrix, writes what
--               every case did into an observation tree, and compares that tree
--               against the reference tree built the same way from the vendored
--               Perl exiftool.
--
--               Two separate phases, and that separation is the point:
--
--                 1. Runner   one tool -> one tree. Produces, never compares,
--                             and knows of the tool only its command line.
--                 2. Compare  two trees -> results. Knows neither tool nor case
--                             list; the trees are self-describing.
--
--               Which tool fills the test role is a profile name in
--               TEST_CLI_TOOL, so the self-test "Perl exiftool against its own
--               reference" is not a special mode but a different profile.
--
--               The reference tree is kept (test-cli-ref/): the vendored
--               exiftool is pinned, so its observations are a stable golden
--               reference. Missing cases are filled in as their own phase;
--               TEST_CLI_REGEN=1 (`make test-cli-gen`) rebuilds it from
--               scratch and stops there.
--
--               The test is a report only: it never blocks (not part of
--               `make check`). Errors on the test side are intentionally
--               tolerated so the report doubles as a gap map during porting.
--
-- Usage:        <interp> src/test-cli/main.lua
--               package.path/package.cpath are supplied by the caller (e.g. the
--               Makefile's `test-cli` target); this script touches neither.
--               See doc/cli-tests.md, and test-cli/Config.lua for the
--               environment variables.
--------------------------------------------------------------------------------

local Util    = require('test-cli.Util')
local Config  = require('test-cli.Config')
local Runner  = require('test-cli.Runner')
local Compare = require('test-cli.Compare')
local Report  = require('test-cli.Report')

local cfg = Config.load()

-- Which tool writes which tree. The only place the two roles are named.
local function phaseSpec(name)
    if name == 'ref' then
        return { name = 'ref', tool = cfg.ref, tree = cfg.refTree,
                 resume = cfg.mode ~= 'gen', label = 'building reference' }
    end
    return { name = 'test', tool = cfg.test, tree = cfg.outTree,
             resume = false, label = 'running ' .. cfg.test.name }
end

--------------------------------------------------------------------------------
-- Worker mode: run our shard of one phase, report one byte per finished case.
--------------------------------------------------------------------------------
if cfg.isWorker then
    local spec = phaseSpec(cfg.phase)
    local sink = io.open(cfg.runDir .. '/progress-' .. cfg.workerId, 'ab')
    -- (with a traceback: the worker's stderr is all a failed run leaves behind)
    local okRun, err = xpcall(Runner.shard, debug.traceback, {
        cases = cfg.cases, tree = spec.tree, tool = spec.tool, resume = spec.resume,
        driverCfg = cfg.driverCfg, shard = cfg.workerId, nshards = cfg.nworkers,
        report = function()
            if sink then sink:write('.'); sink:flush() end
        end,
    })
    -- Close cleanly even on error: the results so far were flushed one by one,
    -- and the parent must not block on a half-open pipe.
    if sink then sink:close() end
    if not okRun then io.stderr:write('test-cli worker: ' .. tostring(err) .. '\n') end
    os.exit(okRun and 0 or 1)
end

--------------------------------------------------------------------------------
-- Prerequisites
--------------------------------------------------------------------------------
if not Util.fileExists(cfg.perlExiftool) then
    io.stderr:write('test-cli: vendored Perl exiftool not found at ' .. cfg.perlExiftool .. '\n')
    os.exit(2)
end
Util.rmrf(cfg.runDir)
Util.ensureDir(cfg.runDir)
Util.ensureDir(cfg.refTree)

--------------------------------------------------------------------------------
-- Banner
--------------------------------------------------------------------------------
local counts, groupOrder = Config.groupCounts(cfg)
do
    local parts = {}
    for _, g in ipairs(groupOrder) do parts[#parts + 1] = counts[g] .. ' ' .. g end
    if cfg.mode == 'gen' then
        io.stdout:write(('Building reference: %s\n'):format(cfg.ref.name))
    else
        io.stdout:write(('CLI comparison: %s vs %s (reference)\n')
            :format(cfg.test.name, cfg.ref.name))
    end
    io.stdout:write(('  %d cases: %s   (%d images, %d as core selection%s)\n\n'):format(
        #cfg.cases, table.concat(parts, ', '), #cfg.images, #cfg.coreImages,
        cfg.allScope and ', TEST_CLI_SCOPE=all' or ''))
    io.stdout:flush()
end

--------------------------------------------------------------------------------
-- Phases
--------------------------------------------------------------------------------
local phases = {}
local refSpec = phaseSpec('ref')
refSpec.cases = Runner.pending({ cases = cfg.cases, tree = cfg.refTree,
                                 resume = refSpec.resume })
if #refSpec.cases > 0 then phases[#phases + 1] = refSpec end
if cfg.mode == 'compare' then
    local testSpec = phaseSpec('test')
    testSpec.cases = cfg.cases
    phases[#phases + 1] = testSpec
    phases[#phases + 1] = { name = 'compare', label = 'comparing', cases = cfg.cases }
end
local nphases = #phases

local function progressLine(idx, label, done, total, suffix)
    local pct = total > 0 and math.floor(done / total * 100) or 100
    io.stdout:write(('\r  [%d/%d] %-26s %3d%% (%d/%d)%s'):format(
        idx, nphases, label, pct, done, total, suffix or ''))
    io.stdout:flush()
end

local function runPhase(idx, spec)
    local total = #spec.cases
    local started = os.time()
    progressLine(idx, spec.label, 0, total)
    -- The test tree is this run's output, and a full reference rebuild must not
    -- keep cases from variants that no longer exist.
    if spec.name == 'test' or cfg.mode == 'gen' then
        Util.rmrf(spec.tree)
    end
    Util.ensureDir(spec.tree)

    local workers = math.min(cfg.jobs, total)
    if workers > 1 then
        -- A worker that died left its shard unfinished: that is a harness
        -- failure, not a result. No run.txt, so the tree stays unusable, and
        -- a non-zero exit, so a CI job goes red instead of reporting a
        -- comparison over whatever happened to be written.
        local failed = Runner.spawn({
            jobs = workers, luaBin = cfg.luaBin, script = cfg.script,
            runDir = cfg.runDir, phase = spec.name, total = total,
            onProgress = function(done) progressLine(idx, spec.label, done, total) end,
        })
        if failed > 0 then
            io.stdout:write('\n')
            io.stderr:write(('test-cli: %d of %d workers failed (%s/worker-*.err)\n')
                :format(failed, workers, cfg.runDir))
            os.exit(2)
        end
    else
        local done = 0
        Runner.shard({
            cases = cfg.cases, tree = spec.tree, tool = spec.tool, resume = spec.resume,
            driverCfg = cfg.driverCfg, shard = 1, nshards = 1,
            report = function()
                done = done + 1
                progressLine(idx, spec.label, done, total)
            end,
        })
    end

    -- Written last, so an interrupted build leaves a tree the comparison will
    -- refuse rather than silently mis-compare.
    Util.writeFile(spec.tree .. '/run.txt', Runner.manifest({
        tool = spec.tool, cases = cfg.cases, images = cfg.images,
        exiftoolVersion = Config.exiftoolVersion(cfg),
    }))
    progressLine(idx, spec.label, total, total,
        ('   (%d worker%s, %d s)\n'):format(workers, workers == 1 and '' or 's',
                                            os.time() - started))
end

local results
for idx, spec in ipairs(phases) do
    if spec.name == 'compare' then
        local total = #spec.cases
        -- The verdict so far, alongside the progress: a long comparison should
        -- show how it is going, not just how far it has got.
        local function tally(done, okCount)
            local bad = done - okCount
            local function pct(n) return total > 0 and math.floor(n / total * 100) or 0 end
            return ('   OK: %d%% (%d/%d), ERR: %d%% (%d/%d)'):format(
                pct(okCount), okCount, total, pct(bad), bad, total)
        end
        progressLine(idx, spec.label, 0, total, tally(0, 0))
        local lastOk = 0
        local err
        results, err = Compare.run({
            refTree = cfg.refTree, testTree = cfg.outTree, cases = cfg.cases,
            onProgress = function(done, okCount)
                lastOk = okCount
                progressLine(idx, spec.label, done, total, tally(done, okCount))
            end,
        })
        if not results then
            io.stdout:write('\n')
            io.stderr:write('test-cli: ' .. err .. '\n')
            os.exit(2)
        end
        progressLine(idx, spec.label, #results, total, tally(#results, lastOk) .. '\n')
    else
        runPhase(idx, spec)
    end
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------
if not results then
    io.stdout:write(('\n  reference complete in %s\n'):format(cfg.refTree))
    os.exit(0)
end

local sum = Report.write(results, {
    outDir = cfg.outTree, refTree = cfg.refTree, testTree = cfg.outTree,
    testName = cfg.test.name, refName = cfg.ref.name,
})

io.stdout:write(('\n  %d of %d identical (%d %%)\n'):format(
    sum.ok, sum.total, sum.total > 0 and math.floor(sum.ok / sum.total * 100) or 0))
if sum.differs > 0 then
    io.stdout:write(('  %d differences        -> %s/summary.txt\n')
        :format(sum.differs, cfg.outTree))
end
for _, key in ipairs(sum.inert) do
    io.stdout:write((
        '  WARNING: %s was silent in the reference for ALL of its cases --\n' ..
        '      likely a broken matrix entry rather than that many real no-ops\n')
        :format(key))
end
-- With TEST_CLI_EXPECT_IDENTICAL a difference IS a failure. For the Perl
-- self-check that means the harness is not deterministic (the same tool ran
-- twice); for lexiftool it means the port differs from the original -- CI
-- sets it there too, so that a regression cannot hide behind a green job.
if sum.differs > 0 and os.getenv('TEST_CLI_EXPECT_IDENTICAL') == '1' then
    if cfg.test.name == cfg.ref.name then
        io.stderr:write(('test-cli: %d difference(s) where none may be; the harness is not deterministic\n')
            :format(sum.differs))
    else
        io.stderr:write(('test-cli: %s differs from %s in %d case(s); see %s/summary.txt\n')
            :format(cfg.test.name, cfg.ref.name, sum.differs, cfg.outTree))
    end
    os.exit(1)
end
-- Differences between the tools are the report, never a failure. A case that
-- exists in only one tree is a failure of the harness or its setup (a worker
-- died, a stale reference): exit non-zero so that it cannot pass as green.
if sum.missing > 0 then
    io.stderr:write(('test-cli: %d case(s) exist in only one tree; the trees are not comparable\n')
        :format(sum.missing))
    os.exit(2)
end
os.exit(0)
