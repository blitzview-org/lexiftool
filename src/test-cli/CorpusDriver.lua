--------------------------------------------------------------------------------
-- File:         test-cli/CorpusDriver.lua
--
-- Description:  The case driver of the corpus run (`make test-corpus`,
--               test-cli/corpus.lua). A Driver (test-cli/Driver.lua)
--               with three differences, all forced by the corpus being
--               thousands of files from outside the repository rather than 195
--               curated ones:
--
--                 1. Every tool call has a time limit (TEST_CORPUS_TIMEOUT).
--                    A hang on one of 7000 files must cost one case, not the
--                    run: a call that exceeds it is killed and recorded with
--                    exit code 124 (what timeout(1) would report), and that
--                    exit code is the observation.
--                 2. A case may have a second command, `readback`, run by the
--                    SAME tool after the first: the write cases read the file
--                    they wrote back with `-a -u -G1`. Its output lands in
--                    readback-stdout.txt / readback-stderr.txt /
--                    readback-exit.txt. Before it runs, the written files'
--                    times are pinned like an input copy's, so that
--                    File:System dates in the readback are comparable; the
--                    work/ fingerprint (stat.txt) is taken BEFORE that, so it
--                    still records what the write itself did.
--                 3. The input copies (work/in/) are deleted once stat.txt has
--                    their hashes -- 7000 files x 7 cases x 2 trees would
--                    otherwise fill the disk with duplicates of the corpus.
--                    work/out/ (what a write case produced) is kept; empty
--                    directories are removed (a read case keeps no work/).
--
--               Everything runs without a shell, like the golden harness:
--               processes are argv tables spawned through lexiftool.sys
--               (stdout/stderr into files, stdin a pipe for sessions),
--               preparation and fingerprints are Driver:prepare and
--               Driver.fingerprint (lfs + digest), cleanup is Util.rmrf -- so the
--               same code runs on Linux, macOS and Windows.
--
--               Paths: every call runs with the TREE ROOT as its working
--               directory and names its files relative to it
--               ("read/v3/Canon~X.jpg/work/in/X.jpg"). A session serves the
--               cases of a whole manufacturer, so a per-case working
--               directory (Driver:expand's work/) is not possible there;
--               process mode and the scripted `stay` session use the same
--               convention, so that every tree reads alike and no
--               tree-specific path can reach the output.
--
--               Case names are "<Make>~<file>" (the corpus has equal
--               basenames in different manufacturer directories); the file in
--               work/in/ keeps its own basename, which `@@` expands to.
--------------------------------------------------------------------------------

local Util   = require('test-cli.Util')
local Driver = require('test-cli.Driver')

local replaceLiteral = Util.replaceLiteral
local sys, lfs = Util.sys, Util.lfs
local symAttr = Util.symAttr
local pinTimes = Driver.pinTimes

-- A {ready} wait inside the scripted session.
local READY_TIMEOUT = 20
-- Poll interval while waiting for a tool: starts short (a session command
-- typically answers within milliseconds) and backs off to POLL_MAX.
local POLL_MIN, POLL_MAX = 0.001, 0.02

local CorpusDriver = setmetatable({}, { __index = Driver })
CorpusDriver.__index = CorpusDriver

-- The layout of what a case records (part of a tree's key in corpus.lua):
-- 2 = paths relative to the tree root, md5 fingerprints (Driver.fingerprint).
CorpusDriver.FORMAT = 2

-- cfg: Driver's (repoDir, imagesDir, srcImage) plus timeout (seconds per call)
function CorpusDriver.new(cfg)
    local self = Driver.new(cfg)
    self.timeout = cfg.timeout or 60
    return setmetatable(self, CorpusDriver)
end

-- Wall clock in seconds (fractional), for the time limits.
local function now()
    local s, us = sys.gettimeofday()
    return s + us / 1e6
end

local function sleep(seconds) Util.sleep(seconds) end

-- The tree root of a case directory.
local function treeRoot(case, caseDir)
    return caseDir:sub(1, #caseDir - #case.dir - 1)
end

--------------------------------------------------------------------------------
-- Placeholders
--
-- `args` (default: the case's template) as an argv, the tool's own prefix
-- first when `tool` is given. Placeholders are relative to the tree root
-- (the working directory of every call): `%IN%` is <case>/work/in, `@@` the
-- case's one file in it (by its basename, not the case name, which carries
-- the make), `@OUT@` the file of that name in work/out/ (where `-o %OUT%/`
-- puts a written copy). Substitution is literal, so exiftool's own
-- %-formats pass through untouched.
--------------------------------------------------------------------------------
function CorpusDriver:argv(tool, case, args)
    local work = case.dir .. '/work'
    local base = case.images[1]:match('[^/\\]+$')
    local subst = {
        { '%IN%', work .. '/in' }, { '%ARGFILE%', work .. '/args.txt' },
        { '%OUT%', work .. '/out' }, { '%SRC%', work .. '/src.jpg' },
        { '%AUX%', self.imagesDir }, { '%REPO%', self.repoDir },
    }
    if case.over == 'each' then
        subst[#subst + 1] = { '@@', work .. '/in/' .. base }
        subst[#subst + 1] = { '@OUT@', work .. '/out/' .. base }
    end
    local list = {}
    if tool then
        for _, a in ipairs(tool.argv) do list[#list + 1] = a end
    end
    for _, tok in ipairs(Util.shellSplit(args or case.args)) do
        for _, s in ipairs(subst) do tok = replaceLiteral(tok, s[1], s[2]) end
        list[#list + 1] = tok
    end
    return list
end

--------------------------------------------------------------------------------
-- Process plumbing
--------------------------------------------------------------------------------

-- Writes to a tool's stdin pipe. A tool that has already exited closes the
-- pipe under us; on POSIX that would be a SIGPIPE for the harness, so the
-- signal is ignored for the duration of the write (and only then: spawned
-- tools must not inherit an ignored SIGPIPE). The write error itself is no
-- observation -- the tool's recorded output and exit code are.
local function send(proc, text)
    local ignored = sys.signal('PIPE', 'IGNORE')    -- nil on Windows
    local ok, err = proc:write(text)
    if ignored then sys.signal('PIPE', 'DEFAULT') end
    return ok, err
end

-- Follows a file another process is writing: each read() returns what was
-- appended since the last one. Binary mode, explicit offset (a reopened or
-- re-seeked handle never serves stale buffered data, on any C library).
local Follower = {}
Follower.__index = Follower

local function follow(path)
    return setmetatable({ path = path, pos = 0 }, Follower)
end

function Follower:read()
    if not self.h then
        self.h = io.open(self.path, 'rb')
        if not self.h then return '' end
    end
    self.h:seek('set', self.pos)
    local chunk = self.h:read('a') or ''
    self.pos = self.pos + #chunk
    return chunk
end

function Follower:close()
    if self.h then self.h:close() end
    self.h = nil
end

-- One process-mode call: stdout, stderr, exit code (124 on timeout).
function CorpusDriver:runObserved(argv, tmpBase, cwd)
    return Util.runObserved(argv, tmpBase, cwd, self.timeout * 1000)
end

--------------------------------------------------------------------------------
-- Preparation and cleanup
--------------------------------------------------------------------------------

-- Pins the times of the files a write case produced (work/out/*), as
-- Driver:prepare pins an input copy's, so that the readback's File:System
-- dates do not show the wall clock.
local function pinOutputs(outDir)
    for _, f in ipairs(Util.listFiles(outDir)) do pinTimes(f) end
end

-- Removes every directory below and including `dir` that is (or becomes)
-- empty, depth first.
local function removeEmptyDirs(dir)
    local a = symAttr(dir)
    if not a or a.mode ~= 'directory' then return end
    local names = {}
    for f in lfs.dir(dir) do
        if f ~= '.' and f ~= '..' then names[#names + 1] = f end
    end
    local left = #names
    for _, f in ipairs(names) do
        local p = dir .. '/' .. f
        local pa = symAttr(p)
        if pa and pa.mode == 'directory' then
            removeEmptyDirs(p)
            if not symAttr(p) then left = left - 1 end
        end
    end
    if left == 0 then lfs.rmdir(dir) end
end

-- The input copies go; so does every directory left empty (a read case
-- leaves none of work/ -- each directory is a disk block, times 50000).
local function cleanup(work)
    Util.rmrf(work .. '/in')
    removeEmptyDirs(work)
end

local function writeMeta(case, caseDir)
    Util.writeFile(caseDir .. '/meta.txt', ('group: %s\nlabel: %s\nname: %s\nargs: %s\n%s')
        :format(case.group, case.label, case.name, case.args,
                case.readback and ('readback: ' .. case.readback .. '\n') or ''))
end

local function writeResult(self, caseDir, prefix, out, err, code)
    Util.writeFile(caseDir .. '/' .. prefix .. 'stdout.txt', self:normalise(out, caseDir, false))
    Util.writeFile(caseDir .. '/' .. prefix .. 'stderr.txt', self:normalise(err, caseDir, false))
    Util.writeFile(caseDir .. '/' .. prefix .. 'exit.txt', tostring(code) .. '\n')
end

--------------------------------------------------------------------------------
-- The scripted -stay_open session (case.feed, the `stay` group)
--
-- Played like Driver:runFed, with a time limit scaled to the session's size
-- (TEST_CORPUS_TIMEOUT plus 2 s per command, from the start), a reader that
-- follows stdout incrementally instead of re-reading it per poll, and waits
-- that stop as soon as the tool has exited (otherwise a session that died
-- on file 3 of 700 would wait 20 s for each of the remaining {ready}s).
--------------------------------------------------------------------------------
function CorpusDriver:runFed(tool, case, caseDir, root)
    local tmp = caseDir .. '/.run'
    local outF, errF = tmp .. '.stdout', tmp .. '.stderr'
    local deadline = now() + self.timeout + 2 * (case.commands or 1)
    local proc, spawnErr = sys.spawn(self:argv(tool, case), {
        cwd = root, stdout = outF, stderr = errF, stdin = 'pipe',
    })
    if not proc then
        return '', 'spawn failed: ' .. tostring(spawnErr) .. '\n', -1, ''
    end
    local inDir = case.dir .. '/work/in'

    -- Counts "{ready" markers in stdout as it grows. A marker split across
    -- two reads is caught by keeping the tail.
    local reader, seen, tail = follow(outF), 0, ''
    local function poll()
        local chunk = reader:read()
        if #chunk > 0 then
            local text = tail .. chunk
            for _ in text:gmatch('{ready') do seen = seen + 1 end
            -- keep a few bytes that cannot hold a whole marker
            tail = text:sub(-5)
            if tail:find('{ready', 1, true) then tail = '' end
        end
        return seen
    end

    local log, dead, killed = {}, false, false
    for _, step in ipairs(case.feed) do
        if type(step) == 'string' then
            if not dead then send(proc, replaceLiteral(step, '%IN%', inDir)) end
            log[#log + 1] = 'send ' .. (step:gsub('\n', '\\n'))
        elseif step.ready then
            local waited, got, pause = 0, poll(), POLL_MIN
            while got < step.ready and waited < READY_TIMEOUT and not dead do
                sleep(pause)
                waited = waited + pause
                pause = math.min(pause * 2, POLL_MAX)
                got = poll()
                if got < step.ready then
                    if not killed and now() > deadline then
                        proc:kill()
                        killed = true
                    end
                    if not proc:alive() then
                        got = poll()
                        dead = got < step.ready
                    end
                end
            end
            log[#log + 1] = ('ready %d: %s'):format(step.ready,
                got >= step.ready and 'answered'
                or (dead and 'EXITED' or 'TIMEOUT') .. ' (' .. got .. ' seen)')
        end
    end
    proc:close_stdin()
    local remaining = math.max(0, math.floor((deadline - now()) * 1000))
    local code, _, timed = proc:wait(remaining)
    if timed or killed then code = 124 end
    reader:close()
    local out, err = Util.readFile(outF) or '', Util.readFile(errF) or ''
    os.remove(outF)
    os.remove(errF)
    return out, err, code, table.concat(log, '\n') .. '\n'
end

--------------------------------------------------------------------------------
-- Process mode: the one entry point per case
--------------------------------------------------------------------------------
function CorpusDriver:runCase(tool, case, caseDir)
    local work = caseDir .. '/work'
    local root = treeRoot(case, caseDir)
    local placed = self:prepare(case, caseDir)
    writeMeta(case, caseDir)
    Util.writeFile(caseDir .. '/stat-before.txt', Driver.fingerprint(work))
    -- The fingerprint read the copies: pin again (see Driver:runCase).
    for _, p in ipairs(placed) do pinTimes(p) end

    if case.feed then
        local out, err, code, feedLog = self:runFed(tool, case, caseDir, root)
        Util.writeFile(caseDir .. '/feed.txt', feedLog)
        writeResult(self, caseDir, '', out, err, code)
    else
        writeResult(self, caseDir, '',
            self:runObserved(self:argv(tool, case), caseDir .. '/.run', root))
    end
    local stat = Driver.fingerprint(work)

    if case.readback then
        pinOutputs(work .. '/out')
        writeResult(self, caseDir, 'readback-',
            self:runObserved(self:argv(tool, case, case.readback), caseDir .. '/.run', root))
    end

    cleanup(work)
    -- Written last: marks the case complete for a resumed run.
    Util.writeFile(caseDir .. '/stat.txt', stat)
end

--------------------------------------------------------------------------------
-- Session mode (TEST_CORPUS_MODE=session, the default): all read/write cases
-- of one manufacturer as commands of ONE -stay_open session per tool, instead
-- of one process per call. Per command the harness sends
--
--     -echo4
--     {done<ID>:${status}}
--     <the case's arguments, one per line>
--     -execute<ID>
--
-- and splits the session's two streams back into per-case files:
--
--   stdout  everything up to the line that ends in "{ready<ID>}" (the
--           marker itself and its line end are dropped; a command whose
--           output lacks a final newline gets the marker appended to its
--           last line, which is why it is searched for, not compared);
--   stderr  everything up to "{done<ID>:<status>}", which -echo4 prints to
--           stderr after the command and BEFORE {ready} (upstream's command
--           loop: echo3, echo4, then flush STDERR, then {ready});
--   exit    <status>, the command's $rtnVal that -echo4 substitutes for
--           ${status} -- the same value the process would have exited with
--           (exiftool exits with $rtnValApp, i.e. its one command's $rtnVal).
--
-- (Both markers may end in CRLF: Perl's STDOUT/STDERR on Windows.)
--
-- -echo4 goes first, so that it is registered even if a later argument makes
-- the command abort ($badCmd still runs the echo at the top of the loop).
-- Nothing else is shared between commands: the corpus cases use neither
-- -common_args nor -charset/-config, and every per-command option is reset by
-- the tool itself at the top of its command loop (upstream's long `undef`
-- list, $mt recreated) -- what does survive (loaded modules, tables built on
-- first use) is precisely what the session-vs-process comparison measures.
--
-- The tool is spawned through lexiftool.sys with a pipe as its stdin and
-- files as stdout/stderr; the harness follows both files, polling. The poll
-- loop also enforces the per-command time limit: a command that has not
-- answered within TEST_CORPUS_TIMEOUT seconds gets the session killed, is
-- recorded with exit 124 (what timeout(1) reports), and the next command
-- starts a fresh session. A tool that dies by itself (a Lua error, a Perl
-- die) is recorded the same way with its real exit code and the stderr
-- tail. Should the harness itself fail (or be interrupted), the session is
-- killed before the error travels on.
--
-- The cases are run per chunk of files: a chunk prepares all of its cases,
-- runs all of their commands, fingerprints, then runs the readbacks of its
-- write cases (in the same session); stat.txt is written last per case, so
-- an interrupted chunk is simply redone.
--------------------------------------------------------------------------------

-- Files per chunk (x6 cases each).
local CHUNK_FILES = 25

local Session = {}
Session.__index = Session

-- dir: a private scratch directory (stdout and stderr files); root: the
-- tree root, the session's working directory.
function CorpusDriver:openSession(tool, dir, root)
    Util.rmrf(dir)
    Util.ensureDir(dir)
    local s = setmetatable({
        dir = dir, outF = dir .. '/stdout', errF = dir .. '/stderr',
        timeout = self.timeout, outBuf = '', errBuf = '',
    }, Session)
    local argv = {}
    for _, a in ipairs(tool.argv) do argv[#argv + 1] = a end
    for _, a in ipairs({ '-stay_open', 'True', '-@', '-' }) do argv[#argv + 1] = a end
    local proc, err = sys.spawn(argv, {
        cwd = root, stdout = s.outF, stderr = s.errF, stdin = 'pipe',
    })
    if not proc then error('test-corpus: cannot start a session: ' .. tostring(err), 0) end
    s.proc = proc
    s.out, s.err = follow(s.outF), follow(s.errF)
    return s
end

-- Ends the session; returns the tool's exit code (124 when the harness
-- killed it). Whatever the tool still wrote to stderr is left in errBuf.
function Session:close(polite)
    if polite and self.proc:alive() then
        send(self.proc, '-stay_open\nFalse\n')
    end
    self.proc:close_stdin()
    local code, _, timed = self.proc:wait(polite and 10000 or -1)
    if timed or self.killed then code = 124 end
    self.errBuf = self.errBuf .. self.err:read()
    self.out:close()
    self.err:close()
    self.closed = true
    Util.rmrf(self.dir)
    return code
end

-- Kills the session (harness failure, interruption) without recording.
function Session:abort()
    if self.closed then return end
    self.proc:kill()
    self.proc:wait(-1)
    self.out:close()
    self.err:close()
    self.closed = true
end

-- Finds the line-ending marker `marker` (plain text) in `buf`: returns the
-- text before it and after its line end, or nil when it is not (yet)
-- complete there.
local function splitAt(buf, marker)
    local s = buf:find(marker, 1, true)
    if not s then return nil end
    local e = s + #marker
    local nl = buf:sub(e, e + 1)
    if nl:sub(1, 1) == '\n' then
        return buf:sub(1, s - 1), buf:sub(e + 1)
    elseif nl == '\r\n' then
        return buf:sub(1, s - 1), buf:sub(e + 2)
    end
    return nil    -- the line end has not arrived yet
end

-- Runs one command; returns stdout, stderr, exit code. A dead session
-- (crash or timeout) is closed and reported through self.closed.
function Session:exec(id, argv)
    send(self.proc, '-echo4\n{done' .. id .. ':${status}}\n' ..
                    table.concat(argv, '\n') .. '\n-execute' .. id .. '\n')
    local marker = '{ready' .. id .. '}'
    local start, pause = now(), POLL_MIN
    local out
    while true do
        self.outBuf = self.outBuf .. self.out:read()
        local before, after = splitAt(self.outBuf, marker)
        if before then
            out, self.outBuf = before, after
            break
        end
        local alive = self.proc:alive()
        if alive and now() - start >= self.timeout then
            self.proc:kill()
            self.killed = true
            alive = false
        end
        if not alive then
            -- the tool is gone: what it said so far is this command's output
            self.outBuf = self.outBuf .. self.out:read()
            out = self.outBuf
            self.outBuf = ''
            local code = self:close(false)
            local err = self.errBuf
            self.errBuf = ''
            return out, err, code
        end
        sleep(pause)
        pause = math.min(pause * 2, POLL_MAX)
    end
    -- echo4 was written before {ready}; allow a moment in case it was not
    local pat = '{done' .. id .. ':(%-?%d*)}\r?\n'
    local waited = 0
    self.errBuf = self.errBuf .. self.err:read()
    while not self.errBuf:find(pat) and waited < 5 do
        sleep(0.01)
        waited = waited + 0.01
        self.errBuf = self.errBuf .. self.err:read()
    end
    local s, e, status = self.errBuf:find(pat)
    local err
    if s then
        err = self.errBuf:sub(1, s - 1)
        self.errBuf = self.errBuf:sub(e + 1)
    else
        err, status = self.errBuf, ''
        self.errBuf = ''
    end
    return out, err, tonumber(status) or -1
end

--------------------------------------------------------------------------------
-- One manufacturer: `cases` are its pending read/write cases, run in chunks
-- through one session that is restarted only when a command killed it.
--------------------------------------------------------------------------------
function CorpusDriver:runMake(tool, cases, root, scratch, report)
    local session, nextId = nil, 0
    local sessions, hangs = 0, 0
    local function exec(argv)
        if not session or session.closed then
            session = self:openSession(tool, scratch .. '/session', root)
            sessions = sessions + 1
        end
        nextId = nextId + 1
        local out, err, code = session:exec(nextId, argv)
        if code == 124 and session.closed then hangs = hangs + 1 end
        return out, err, code
    end

    -- chunks of whole files, in case order
    local byFile, files = {}, {}
    for _, case in ipairs(cases) do
        local key = case.images[1]
        if not byFile[key] then byFile[key] = {}; files[#files + 1] = key end
        table.insert(byFile[key], case)
    end

    local function runChunk(first)
        local entries = {}
        for i = first, math.min(#files, first + CHUNK_FILES - 1) do
            for _, case in ipairs(byFile[files[i]]) do
                local caseDir = root .. '/' .. case.dir
                entries[#entries + 1] = { case = case, caseDir = caseDir, work = caseDir .. '/work' }
            end
        end
        for _, e in ipairs(entries) do
            e.placed = self:prepare(e.case, e.caseDir)
            writeMeta(e.case, e.caseDir)
            Util.writeFile(e.caseDir .. '/stat-before.txt', Driver.fingerprint(e.work))
        end
        -- the fingerprints read the copies: pin again (see Driver:runCase)
        for _, e in ipairs(entries) do
            for _, p in ipairs(e.placed) do pinTimes(p) end
        end
        for _, e in ipairs(entries) do
            writeResult(self, e.caseDir, '', exec(self:argv(nil, e.case)))
        end
        for _, e in ipairs(entries) do e.stat = Driver.fingerprint(e.work) end
        -- pin the written copies' times before they are read back
        for _, e in ipairs(entries) do
            if e.case.readback then pinOutputs(e.work .. '/out') end
        end
        for _, e in ipairs(entries) do
            if e.case.readback then
                writeResult(self, e.caseDir, 'readback-',
                    exec(self:argv(nil, e.case, e.case.readback)))
            end
        end
        for _, e in ipairs(entries) do
            cleanup(e.work)
            Util.writeFile(e.caseDir .. '/stat.txt', e.stat)
            report()
        end
    end

    local ok, err = pcall(function()
        for first = 1, #files, CHUNK_FILES do runChunk(first) end
    end)
    if not ok then
        if session then session:abort() end
        error(err, 0)
    end
    if session and not session.closed then session:close(true) end
    return sessions, hangs
end

return CorpusDriver
