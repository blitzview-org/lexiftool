--------------------------------------------------------------------------------
-- File:         test-cli/Runner.lua
--
-- Description:  Produces an observation tree: runs ONE tool over the case list
--               and writes what each case did. It never compares anything and
--               never looks at another tree.
--
--                   Runner.run{ tool = …, tree = …, cases = … }
--
--               Of the tool it knows `id`, `name` and `cmd` -- nothing more.
--               Which tool that is (the Perl reference or the Lua port) is
--               decided in main.lua and is invisible here, which is why the
--               same code produces both sides of the comparison.
--
--               Parallelism: the flat case list is split across N independent
--               OS processes by index modulo. Each worker re-executes
--               src/test-cli/main.lua in worker mode over its own shard. No
--               shared Lua state, and -- since every case owns its work/
--               directory -- no shared files either. Workers append one byte
--               per finished case to their own progress file; the parent polls
--               those files while it supervises the worker processes.
--------------------------------------------------------------------------------

local Util = require('test-cli.Util')
local Driver = require('test-cli.Driver')

local Runner = {}

-- A case is complete when its stat.txt exists -- Driver:runCase writes that
-- last. Used by a resumed run (the reference tree) to skip finished work.
local function isDone(tree, case)
    return Util.fileExists(tree .. '/' .. case.dir .. '/stat.txt')
end

-- The cases a run still has to do. With resume off that is all of them.
function Runner.pending(o)
    if not o.resume then return o.cases end
    local todo = {}
    for _, case in ipairs(o.cases) do
        if not isDone(o.tree, case) then todo[#todo + 1] = case end
    end
    return todo
end

-- The tree's identity card. Two trees may only be compared when these match,
-- because timezone, locale and the reference tool's version all change the
-- output, and a different image selection means different cases entirely.
function Runner.manifest(o)
    local imgs = {}
    for _, img in ipairs(o.images) do imgs[#imgs + 1] = img:match('[^/]+$') end
    table.sort(imgs)
    return table.concat({
        'tool: ' .. o.tool.id,
        'name: ' .. o.tool.name,
        'cmd: ' .. o.tool.cmd,
        'TZ: ' .. (os.getenv('TZ') or ''),
        'LC_ALL: ' .. (os.getenv('LC_ALL') or ''),
        'exiftool: ' .. o.exiftoolVersion,
        'cases: ' .. #o.cases,
        'images: ' .. table.concat(imgs, ' '),
    }, '\n') .. '\n'
end

--------------------------------------------------------------------------------
-- Worker side
--------------------------------------------------------------------------------

-- Runs shard `shard` of `nshards`. Serial mode is simply shard 1 of 1.
-- `report` is called once per case actually executed.
function Runner.shard(o)
    local driver = Driver.new(o.driverCfg)
    for i, case in ipairs(o.cases) do
        if (i - 1) % o.nshards + 1 == o.shard then
            if not (o.resume and isDone(o.tree, case)) then
                driver:runCase(o.tool, case, o.tree .. '/' .. case.dir)
                o.report()
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Parent side
--------------------------------------------------------------------------------

-- o: jobs, luaBin, script, runDir, phase, total, onProgress
--
-- Workers report progress by appending one byte per finished case to their own
-- file; the parent sums the file sizes while it polls. That replaces the FIFO
-- (whose shell plumbing does not exist on Windows) with plain files, and keeps
-- the no-shared-state property: each worker owns its own progress file.
function Runner.spawn(o)
    Util.ensureDir(o.runDir)
    local sys = Util.sys
    local lfs = Util.lfs
    local procs, errLogs = {}, {}
    for w = 1, o.jobs do
        os.remove(o.runDir .. '/progress-' .. w)
        local outLog = o.runDir .. '/worker-' .. w .. '.out'
        local errLog = o.runDir .. '/worker-' .. w .. '.err'
        errLogs[w] = errLog
        -- Workers inherit the environment at spawn time, so setting these
        -- three between spawns gives every worker its own identity.
        sys.setenv('TEST_CLI_PHASE', o.phase or '')
        sys.setenv('TEST_CLI_WORKER', tostring(w))
        sys.setenv('TEST_CLI_NWORKERS', tostring(o.jobs))
        local p, err = sys.spawn({ o.luaBin, o.script },
                                 { stdout = outLog, stderr = errLog })
        if not p then
            for _, q in ipairs(procs) do q:kill() end
            error('test-cli: could not spawn worker ' .. w .. ': ' .. tostring(err))
        end
        procs[w] = p
    end

    local done = 0
    while true do
        local running = false
        for w = 1, o.jobs do
            if procs[w]:alive() then running = true end
        end
        local n = 0
        for w = 1, o.jobs do
            local a = lfs.attributes(o.runDir .. '/progress-' .. w)
            if a then n = n + a.size end
        end
        if n ~= done then
            done = n
            if o.onProgress then o.onProgress(done) end
        end
        if not running then break end
        Util.sleep(0.05)
    end

    local failed = 0
    for w = 1, o.jobs do
        local code = procs[w]:wait(-1)
        if code ~= 0 then
            failed = failed + 1
            io.stderr:write(('test-cli: worker %d exited with %s (see %s)\n')
                :format(w, tostring(code), errLogs[w]))
        end
    end
    return failed
end

return Runner
