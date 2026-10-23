--------------------------------------------------------------------------------
-- File:         test-cli/Driver.lua
--
-- Description:  Runs ONE case with ONE tool and writes down everything it did.
--
--                   driver:runCase(tool, case, caseDir)
--
--               That is the whole interface, and it is deliberately symmetric:
--               the driver never learns whether `tool` is the Perl reference or
--               the Lua port. It prepares identical preconditions for both,
--               runs the command, and records the result -- so a difference in
--               what lands on disk is a difference in the tools, never in the
--               harness.
--
--               One case = one directory, self-contained and reproducible by
--               hand:
--
--                   <caseDir>/
--                       meta.txt          group, label, name, argument template
--                       stdout.txt
--                       stderr.txt
--                       exit.txt
--                       stat-before.txt   work/ right after prepare
--                       stat.txt          work/ after the run
--                       work/in/          what the tool operated on
--                       work/out/         where it was told to write
--                       work/src.jpg      the -tagsFromFile / -file1 source
--                       feed.txt          (-stay_open sessions only) the steps
--                                         the caller sent and whether each
--                                         {ready} wait was answered
--                       work/args.txt     (sessions over a growing ARGFILE)
--
--               There is no per-track special casing: every case goes through
--               the same prepare -> run -> observe path. What differs is only
--               HOW work/ is filled, and that is declared per case
--               (Cases.GROUPS) -- and, for a -stay_open session (a case with
--               a `feed`), that the arguments are not all on the command
--               line: runFed plays the caller who sends them command by
--               command and waits for each "{ready}".
--
--               Determinism is created, not normalised away: rather than
--               stripping dates from the output we make both runs see the same
--               stat(). ctime is pinned by the platform's stat interposer
--               on Linux and macOS (tools/ctime_fake*.c) and is the creation
--               time on Windows; mtime/atime/creation time by set_times. CRLF is deliberately NOT rewritten: the original
--               exiftool emits CRLF for some formats (-csv, RFC 4180) and the
--               port must reproduce that exactly.
--
--               See doc/cli-tests.md for the full rationale.
--------------------------------------------------------------------------------

local Util = require('test-cli.Util')

local replaceLiteral = Util.replaceLiteral
local lfs = Util.lfs
local sys = Util.sys
local symAttr = Util.symAttr

-- Fixed timestamp (far future) used for every copied input so that the
-- File/System group (atime/mtime/ctime, permissions) is identical between the
-- two tools and stable across runs. Under relatime/noatime (default Linux) a
-- future atime is never bumped by a read, so both tools observe the same stat.
local FIXED_EPOCH = os.time({ year = 2099, month = 1, day = 1, hour = 0, min = 0, sec = 0 })

local Driver = {}
Driver.__index = Driver

-- cfg: repoDir, workDir, imagesDir, srcImage
-- (repoDir: the project root; workDir: the directory holding the trees,
-- the project root unless a caller places them elsewhere)
function Driver.new(cfg)
    return setmetatable({
        repoDir = cfg.repoDir,
        workDir = cfg.workDir or cfg.repoDir,
        imagesDir = cfg.imagesDir,
        srcImage = cfg.srcImage,
    }, Driver)
end

--------------------------------------------------------------------------------
-- Preparation
--------------------------------------------------------------------------------

-- Wipe and rebuild the case directory: copy, pin the stat. This is the
-- harness' hot path -- every case pays it -- but copy_file/chmod/set_times
-- are direct syscalls through lexiftool.sys rather than one fork+exec per
-- step, which more than pays for the extra in-process calls.
-- atime, mtime and (where the OS has one) creation time; ctime is pinned by
-- build/ctime_fake.so on Linux and macOS instead (Windows reports the
-- creation time as ctime). atime is one second AFTER mtime: a
-- relatime mount (the Linux default) refreshes atime on read whenever it is
-- not newer than mtime, and both the fingerprint below and the tool read the
-- copy -- FileAccessDate would then be the wall clock in both trees.
local function pinTimes(path)
    Util.setTimes(path, FIXED_EPOCH + 1, FIXED_EPOCH, FIXED_EPOCH)
end
-- (CorpusDriver pins its input copies and written files the same way)
Driver.pinTimes = pinTimes

function Driver:prepare(case, caseDir)
    local work = caseDir .. '/work'
    Util.rmrf(caseDir)
    Util.ensureDir(work .. '/in')
    Util.ensureDir(work .. '/out')
    local function place(src, dst)
        Util.copyFile(src, dst)
        Util.sys.chmod(420, dst)
        pinTimes(dst)
    end
    local placed = {}
    for _, p in ipairs(case.images) do
        placed[#placed + 1] = work .. '/in/' .. (p:match('[^/\\]+$') or p)
        place(p, placed[#placed])
    end
    if case.prepare ~= 'file' then
        -- Named src.jpg regardless of which image it came from, so %SRC% is
        -- the same string in every case and in both trees.
        placed[#placed + 1] = work .. '/src.jpg'
        place(self.srcImage, placed[#placed])
    end
    return placed
end

--------------------------------------------------------------------------------
-- Placeholders
--
-- Substitution is literal, so exiftool's own %-formats (%Y, %%f, %%e) pass
-- through untouched even though they live in the same string.
--------------------------------------------------------------------------------
function Driver:expand(tool, case)
    -- The case runs with work/ as its cwd, so everything inside it is named
    -- relatively: the verbose Directory tag stays short (upstream snips it at
    -- 60 characters) and no tree-specific path can leak into the output.
    local subst = {
        ['%IN%'] = 'in',
        ['%ARGFILE%'] = 'args.txt',
        ['%OUT%'] = 'out',
        ['%SRC%'] = 'src.jpg',
        ['%AUX%'] = self.imagesDir,
        ['%REPO%'] = self.repoDir,
    }
    local argv = {}
    for _, a in ipairs(tool.argv) do argv[#argv + 1] = a end
    for _, tok in ipairs(Util.shellSplit(case.args or '')) do
        for needle, repl in pairs(subst) do
            tok = replaceLiteral(tok, needle, repl)
        end
        if case.over == 'each' then
            tok = replaceLiteral(tok, '@@', 'in/' .. case.name)
        end
        argv[#argv + 1] = tok
    end
    return argv
end

--------------------------------------------------------------------------------
-- Observation
--------------------------------------------------------------------------------

-- An mtime is only comparable if the tool decided it. Three cases:
--   fixed   -- untouched, still the copy's pinned 2099 stamp (e.g. under -P)
--   runtime -- the wall clock, i.e. a file this run created (-o, -w, backups);
--              the exact second differs between the two runs by construction
--   <epoch> -- deliberately set from tag data (-CreateDate>FileModifyDate),
--              which is precisely what such a call must be judged on
local function classifyMtime(m)
    local v = tonumber(m)
    if not v then return '?' end
    if v == FIXED_EPOCH then return 'fixed' end
    if math.abs(os.time() - v) < 86400 then return 'runtime' end
    return tostring(v)
end

-- The state of work/ as one sorted text block: relative path, size, mtime
-- (classified as above), permissions, content hash. This is what makes
-- timestamps comparable at all -- `diff -r` sees neither mtime nor permissions,
-- yet calls like -CreateDate>FileModifyDate change nothing else.
function Driver.fingerprint(root)
    local digest = require('digest')
    local lines = {}
    local function modeNumber(a)
        local perms = a.permissions or ''
        local m, bits = 0, { 4, 2, 1 }
        for i = 1, math.min(#perms, 9) do
            if perms:sub(i, i) ~= '-' then m = m + bits[(i - 1) % 3 + 1] end
        end
        return m
    end
    local function walk(rel)
        local dir = rel == '' and root or (root .. '/' .. rel)
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok or not iter then return end
        local names = {}
        for f in iter, obj do
            if f ~= '.' and f ~= '..' then names[#names + 1] = f end
        end
        for _, f in ipairs(names) do
            local r = rel == '' and f or (rel .. '/' .. f)
            local a = symAttr(dir .. '/' .. f)
            if a then
                if a.mode == 'directory' then
                    walk(r)
                elseif a.mode == 'file' then
                    local data = Util.readFile(dir .. '/' .. f) or ''
                    lines[#lines + 1] = ('./%s\t%d %s %o\t%s'):format(
                        r, a.size, classifyMtime(a.modification),
                        modeNumber(a), digest.md5hex(data):sub(1, 16))
                end
            end
        end
    end
    walk('')
    table.sort(lines)
    return table.concat(lines, '\n') .. (#lines > 0 and '\n' or '')
end

-- Each tool works in its own tree, so absolute paths in the output differ by
-- the tree root alone. Replacing the case directory (and the repo root, for
-- %AUX%/%REPO% inputs) keeps the comparison about content rather than about
-- where the run happened.
--
-- Sorting is only right for a call that scans a directory: readdir order is not
-- guaranteed. A call with a fixed subject has a deterministic output order,
-- where sorting would only destroy information.
--
-- KNOWN WART: this also sorts `d-fileorder`, whose whole point is the order --
-- so that variant currently proves less than it looks. Carried over unchanged;
-- worth revisiting whether the sort is needed at all now that each case builds
-- its own work/in with identical contents.
-- Both roots read as <REPO>, the project root first (should it lie inside
-- workDir, the longer path must win), so that a path under either reads the
-- same whichever of the two it sits in.
function Driver:rootless(text)
    local t = replaceLiteral(text, self.repoDir, '<REPO>')
    return (replaceLiteral(t, self.workDir, '<REPO>'))
end

function Driver:normalise(text, caseDir, sortLines)
    -- caseDir first: it lives under the roots, so the longer path must win.
    local t = replaceLiteral(text, caseDir, '<CASE>')
    t = self:rootless(t)
    -- The source location Perl appends to a `die`/`croak` message ("at
    -- FILE line N.") names Perl's own files; the port's counterpart names
    -- its own. The message before it must still agree byte for byte.
    t = t:gsub(' at (%S+) line (%d+)%.(\r?\n)', ' at <FILE> line <N>.%3')
    t = t:gsub(' at (%S+) line (%d+)%.$', ' at <FILE> line <N>.')
    if not sortLines then return t end
    return Util.sortLines(t)
end

--------------------------------------------------------------------------------
-- A -stay_open session (Cases.STAY): the caller's side of the protocol
--------------------------------------------------------------------------------

-- How long one `{ ready = N }` step waits for the tool's answer, and how
-- often it looks.
local READY_TIMEOUT = 20
local POLL = 0.05

-- Number of "{ready" markers the tool has written to its stdout file so far.
local function countReady(path)
    local text = Util.readFile(path) or ''
    local n = 0
    for _ in text:gmatch('{ready') do n = n + 1 end
    return n
end

-- Runs the tool with a writable pipe as its stdin and plays `case.feed` into
-- it -- or, with via = 'file', appends the feed to work/args.txt, the
-- growing ARGFILE the args name. stdout/stderr go to files (the {ready}
-- markers are read back from the stdout file, which is why a tool that does
-- not flush after them makes a step time out). The tool runs under timeout(1)
-- so a session that never ends cannot hang the harness, and the pipe is
-- drained after the tool exits (`cat >/dev/null`) so a write after an early
-- exit cannot kill the harness with SIGPIPE.
-- Returns stdout, stderr, exit code and the feed log (one line per step).
function Driver:runFed(tool, case, caseDir, work)
    local tmp = caseDir .. '/.run'
    local outF, errF = tmp .. '.stdout', tmp .. '.stderr'
    local argFile = work .. '/args.txt'
    -- The session runs in work/ and its feed names the files relative to it
    -- ('in/...'): the ARGFILE of a 'file' session lies in work/ and is
    -- compared like every other file there, so it must not contain the
    -- tree's own path.
    local inDir = 'in'
    local pipe, err = sys.spawn(self:expand(tool, case), {
        cwd = work, stdout = outF, stderr = errF, stdin = 'pipe',
    })
    if not pipe then
        return '', 'spawn failed: ' .. tostring(err) .. '\n', -1, ''
    end
    local log = {}
    for _, step in ipairs(case.feed) do
        if type(step) == 'string' then
            local text = replaceLiteral(step, '%IN%', inDir)
            if case.via == 'file' then
                local f = io.open(argFile, 'ab')
                f:write(text)
                f:close()
            else
                -- A tool that has already exited closes the pipe under us;
                -- the observation is its recorded output, not the write error.
                pipe:write(text)
            end
            -- (the step as written in Cases.lua, newlines shown as \n)
            log[#log + 1] = 'send ' .. (step:gsub('\n', '\\n'))
        elseif step.ready then
            local waited, got = 0, countReady(outF)
            while got < step.ready and waited < READY_TIMEOUT do
                Util.sleep(POLL)
                waited = waited + POLL
                got = countReady(outF)
            end
            log[#log + 1] = ('ready %d: %s'):format(step.ready,
                got >= step.ready and 'answered' or ('TIMEOUT (' .. got .. ' seen)'))
        elseif step.sleep then
            Util.sleep(step.sleep)
            log[#log + 1] = 'sleep ' .. step.sleep
        end
    end
    pipe:close_stdin()
    local code, _, timed = pipe:wait(60000)
    if timed then code = 124 end
    local out, errOut = Util.readFile(outF) or '', Util.readFile(errF) or ''
    os.remove(outF)
    os.remove(errF)
    return out, errOut, code, table.concat(log, '\n') .. '\n'
end

--------------------------------------------------------------------------------
-- The one entry point
--------------------------------------------------------------------------------
function Driver:runCase(tool, case, caseDir)
    local work = caseDir .. '/work'
    local placed = self:prepare(case, caseDir)

    -- Self-describing tree: identical in every tree, since it says nothing
    -- about the tool. The resolved command line is tool-specific and lives in
    -- the tree's run.txt instead.
    Util.writeFile(caseDir .. '/meta.txt', ('group: %s\nlabel: %s\nname: %s\nargs: %s\n')
        :format(case.group, case.label, case.name, case.args))
    -- a -stay_open session over a growing ARGFILE starts with an empty one
    if case.via == 'file' then Util.writeFile(work .. '/args.txt', '') end
    Util.writeFile(caseDir .. '/stat-before.txt', Driver.fingerprint(work))
    -- The fingerprint read the copies: pin again, so a filesystem that
    -- refreshes atime on every read (strictatime, or Windows with last-access
    -- updates on) still shows the tool the fixed stamp.
    for _, p in ipairs(placed) do pinTimes(p) end

    local out, err, code, feedLog
    if case.feed then
        out, err, code, feedLog = self:runFed(tool, case, caseDir, work)
        Util.writeFile(caseDir .. '/feed.txt', feedLog)
    else
        out, err, code = Util.runObserved(
            self:expand(tool, case), caseDir .. '/.run', work)
    end

    -- (a session names its files one by one: its output order is the
    --  protocol itself, so it is never sorted)
    local sortLines = (case.over == 'all') and not case.feed
    Util.writeFile(caseDir .. '/stdout.txt', self:normalise(out, caseDir, sortLines))
    Util.writeFile(caseDir .. '/stderr.txt', self:normalise(err, caseDir, sortLines))
    Util.writeFile(caseDir .. '/exit.txt', tostring(code) .. '\n')
    -- Written last: its presence is what marks the case as complete, which is
    -- how a resumed run knows what it may skip.
    Util.writeFile(caseDir .. '/stat.txt', Driver.fingerprint(work))
end

return Driver
