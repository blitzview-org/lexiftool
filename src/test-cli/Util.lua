--------------------------------------------------------------------------------
-- File:         test-cli/Util.lua
--
-- Description:  Path, file, process and shell helpers shared by the CLI test
--               harness.
--
--               Nothing here knows anything about exiftool, lexiftool or the
--               test matrix -- these are the plumbing primitives the other
--               harness modules are built from.
--
--               Process control and file metadata go through the port's own
--               `lexiftool.sys` module and LuaFileSystem, so the harness runs
--               unchanged on POSIX and on Windows. The shell-string helpers
--               (`shquote`, string forms of run/capture) remain for callers
--               that drive a tool through a shell (POSIX only); the golden
--               harness itself passes argv tables.
--------------------------------------------------------------------------------

local okLfs, lfs = pcall(require, 'lfs')
if not okLfs then
    error('test-cli: LuaFileSystem (lfs) is required: ' .. tostring(lfs))
end
local sys = require('lexiftool.sys')

local Util = {}

Util.lfs = lfs
Util.sys = sys

local is_windows = package.config:sub(1, 1) == '\\'

-- Windows accepts forward slashes in every path used here; normalising keeps
-- the tree layout and the fingerprints identical regardless of where the
-- components came from.
local function norm(p)
    return is_windows and (p:gsub('\\', '/')) or p
end

function Util.shquote(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- Split a shell-like argument string into words. Quotes are removed, single
-- quotes are literal, double quotes honour the usual backslash escapes, and a
-- backslash outside quotes escapes the next character. There is deliberately
-- no variable expansion or globbing: the case matrix is a declarative list of
-- arguments, and the file names it names are substituted as whole words.
function Util.shellSplit(s)
    local out, cur, have = {}, {}, false
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == ' ' or c == '\t' or c == '\n' then
            if have then
                out[#out + 1] = table.concat(cur)
                cur, have = {}, false
            end
            i = i + 1
        elseif c == "'" then
            have = true
            local j = s:find("'", i + 1, true)
            if not j then error('unterminated single quote in: ' .. s) end
            cur[#cur + 1] = s:sub(i + 1, j - 1)
            i = j + 1
        elseif c == '"' then
            have = true
            i = i + 1
            local closed = false
            while i <= n do
                local d = s:sub(i, i)
                if d == '"' then
                    i = i + 1
                    closed = true
                    break
                elseif d == '\\' then
                    local e = s:sub(i + 1, i + 1)
                    if e == '"' or e == '\\' or e == '$' or e == '`' or e == '\n' then
                        cur[#cur + 1] = e
                        i = i + 2
                    else
                        cur[#cur + 1] = '\\'
                        i = i + 1
                    end
                else
                    cur[#cur + 1] = d
                    i = i + 1
                end
            end
            if not closed then error('unterminated double quote in: ' .. s) end
        elseif c == '\\' then
            have = true
            local e = s:sub(i + 1, i + 1)
            if e ~= '' then cur[#cur + 1] = e end
            i = i + 2
        else
            have = true
            cur[#cur + 1] = c
            i = i + 1
        end
    end
    if have then out[#out + 1] = table.concat(cur) end
    return out
end

-- Replace every literal occurrence of `needle` with `repl` (no pattern magic).
function Util.replaceLiteral(s, needle, repl)
    local out = {}
    local n = #needle
    local i = 1
    while i <= #s do
        local f = s:find(needle, i, true)
        if not f then
            out[#out + 1] = s:sub(i)
            break
        end
        out[#out + 1] = s:sub(i, f - 1)
        out[#out + 1] = repl
        i = f + n
    end
    return table.concat(out)
end

function Util.readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local d = f:read('a')
    f:close()
    return d
end

function Util.writeFile(path, content)
    local f = io.open(path, 'wb')
    if not f then return end
    f:write(content)
    f:close()
end

function Util.fileExists(path)
    return lfs.attributes(norm(path)) ~= nil
end

-- mkdir -p, including Windows drive roots and UNC prefixes.
function Util.ensureDir(d)
    d = norm(d):gsub('/+$', '')
    if d == '' then return end
    local prefix, rest
    local unc = d:match('^//[^/]+/[^/]+')
    if d:match('^%a:/') then
        prefix, rest = d:sub(1, 3), d:sub(4)
    elseif unc then
        prefix, rest = unc, d:sub(#unc + 1)
    elseif d:sub(1, 1) == '/' then
        prefix, rest = '/', d:sub(2)
    else
        prefix, rest = '', d
    end
    local cur = prefix
    for part in rest:gmatch('[^/]+') do
        if cur == '' then cur = part
        elseif cur == '/' then cur = '/' .. part
        else cur = cur .. '/' .. part end
        local a = lfs.attributes(cur)
        if not a then
            local ok, err = lfs.mkdir(cur)
            -- Another worker may have won the race between the check and the
            -- mkdir; only a missing/non-directory result is an error.
            if not ok and (lfs.attributes(cur) or {}).mode ~= 'directory' then
                error('mkdir ' .. cur .. ': ' .. tostring(err))
            end
        elseif a.mode ~= 'directory' then
            error('not a directory: ' .. cur)
        end
    end
end

-- lstat where lfs offers it. Not on Windows: there lfs.symlinkattributes
-- raises instead of returning nil for a missing path, and the trees hold no
-- symbolic links anyway.
function Util.symAttr(path)
    local f = (not is_windows and lfs.symlinkattributes) or lfs.attributes
    return f(path)
end
local symAttr = Util.symAttr

-- rm -rf. Read-only files (a Windows habit) are made writable first.
function Util.rmrf(d)
    d = norm(d)
    local a = symAttr(d)
    if not a then return end
    if a.mode == 'directory' then
        local ok, iter, obj = pcall(lfs.dir, d)
        if not ok or not iter then error('readdir ' .. d .. ': ' .. tostring(iter)) end
        local names = {}
        for f in iter, obj do
            if f ~= '.' and f ~= '..' then names[#names + 1] = f end
        end
        for _, f in ipairs(names) do Util.rmrf(d .. '/' .. f) end
        local ok2, err = lfs.rmdir(d)
        if not ok2 and lfs.attributes(d) then
            -- (what is left tells more than "not empty")
            local left = {}
            for f in lfs.dir(d) do if f ~= '.' and f ~= '..' then left[#left + 1] = f end end
            error('rmdir ' .. d .. ': ' .. tostring(err) .. ' (left: ' .. table.concat(left, ', ') .. ')')
        end
    else
        if not os.remove(d) then
            sys.chmod(438, d)
            if not os.remove(d) then error('remove ' .. d) end
        end
    end
end

function Util.copyFile(src, dst)
    local ok, err = sys.copy_file(src, dst)
    if not ok then error('copy ' .. src .. ' -> ' .. dst .. ': ' .. tostring(err)) end
end

-- Set atime/mtime and (where the OS has one) the creation time. The ctime
-- is pinned by the platform's stat interposer instead, see the Makefile.
function Util.setTimes(path, atime, mtime, creation)
    local ok, err = sys.set_times(path, atime, mtime, creation)
    if not ok then error('set_times ' .. path .. ': ' .. tostring(err)) end
end

function Util.sleep(seconds)
    return sys.sleep_ms(math.floor(seconds * 1000 + 0.5))
end

-- A unique path in the platform's temp directory. os.tmpname() is avoided: on
-- Windows it can return a bare "\sXXXX." rooted at the current drive, and the
-- temp directory from the environment is what the CI runners provide.
local tmpCounter = 0
function Util.tmpName()
    local dir = os.getenv('TMPDIR') or os.getenv('TEMP') or os.getenv('TMP') or '/tmp'
    dir = norm(dir):gsub('/+$', '')
    tmpCounter = tmpCounter + 1
    return ('%s/lexiftool-test-cli-%d-%d'):format(dir, sys.getpid(), tmpCounter)
end

-- List regular files directly under `dir`, sorted bytewise. `keep` receives
-- the basename. Missing/unreadable directories yield an empty list.
function Util.listFiles(dir, keep)
    local out = {}
    local ok, iter, obj = pcall(lfs.dir, norm(dir))
    if not ok or not iter then return out end
    for f in iter, obj do
        if f ~= '.' and f ~= '..' then
            local full = norm(dir) .. '/' .. f
            local a = lfs.attributes(full)
            if a and a.mode == 'file' and (not keep or keep(f)) then
                out[#out + 1] = full
            end
        end
    end
    table.sort(out)
    return out
end

-- Run argv, discard its output, return the exit code. stdin is /dev/null (or
-- NUL), so a tool waiting for input cannot hang the harness.
local function waitCode(proc, timeout)
    local code, _, timed = proc:wait(timeout or 300000)
    if timed then return 124 end
    return code
end

function Util.run(argv)
    local p, err = sys.spawn(argv, {})
    if not p then return -1, tostring(err) end
    return waitCode(p)
end

-- Capture stdout; stderr is discarded. Accepts an argv table (portable) or a
-- shell string (POSIX callers that go through a shell).
function Util.runCapture(cmd)
    if type(cmd) ~= 'table' then
        local pipe = io.popen(cmd .. ' 2>/dev/null < /dev/null')
        if not pipe then return '' end
        local out = pipe:read('a') or ''
        pipe:close()
        return out
    end
    local outF, errF = Util.tmpName(), Util.tmpName()
    local p = sys.spawn(cmd, { stdout = outF, stderr = errF })
    if not p then
        os.remove(outF); os.remove(errF)
        return ''
    end
    waitCode(p)
    local out = Util.readFile(outF) or ''
    os.remove(outF); os.remove(errF)
    return out
end

-- Full observation of a run: stdout, stderr and exit status. Accepts an argv
-- table (portable) or a shell string (POSIX callers that go through a shell).
-- An argv run is killed after `timeoutMs` (default 300 s) and reports 124,
-- as timeout(1) would.
function Util.runObserved(cmd, tmpBase, cwd, timeoutMs)
    local outF, errF = tmpBase .. '.stdout', tmpBase .. '.stderr'
    local code
    if type(cmd) == 'table' then
        local p, err = sys.spawn(cmd, { stdout = outF, stderr = errF, cwd = cwd })
        if not p then
            return '', tostring(err) .. '\n', -1
        end
        code = waitCode(p, timeoutMs)
    else
        local _, _, c = os.execute(cmd .. ' > ' .. Util.shquote(outF) ..
                                   ' 2> ' .. Util.shquote(errF) .. ' < /dev/null')
        code = tonumber(c) or -1
    end
    local out, err = Util.readFile(outF) or '', Util.readFile(errF) or ''
    os.remove(outF)
    os.remove(errF)
    return out, err, code
end

-- Split into lines, sort, reassemble (trailing newline preserved when there
-- was any content at all).
function Util.sortLines(text)
    local lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
    if #lines > 0 and lines[#lines] == '' then lines[#lines] = nil end
    table.sort(lines)
    return table.concat(lines, '\n') .. (#lines > 0 and '\n' or '')
end

function Util.cpuCount()
    local n = sys.cpu_count()
    return (n and n >= 1) and n or 1
end

return Util
