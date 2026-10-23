--------------------------------------------------------------------------------
-- File:         tools/verify_ctype.lua
--
-- Description:  reject Lua pattern classes and case changes that follow the
--               host's LC_CTYPE (gate)
--------------------------------------------------------------------------------

-- Perl's \s, \w, [[:alpha:]] and lc/uc on a byte string (no `use locale`)
-- mean ASCII only. Lua's pattern classes %a %l %u %w %s %p %c %g (and their
-- negations) go through isalpha()/isspace()/... and string.lower/upper
-- through tolower()/toupper(), i.e. the LC_CTYPE of the process's global C
-- locale: under a single-byte locale (Windows cp1252, Linux de_DE
-- ISO-8859-1) 0xE4 is a letter and tolower(0xC4) is 0xE4. So ported code
-- spells its classes as explicit ASCII sets ([ \t\n\r\f\v], [A-Za-z],
-- [A-Za-z0-9], ...) and changes case through perl.lc/perl.uc
-- (doc/conventions.md §3a). %d and %x are locale-independent by the C
-- standard and stay.
--
-- This lists, in the code of src/lexiftool.lua, src/lexiftool/*.lua (the
-- perl facade included), capi/*.lua, standalone/launcher.lua and the
-- launcher script `lexiftool`:
--   (a) every pattern argument of a find/match/gmatch/gsub call -- the
--       method form s:find(PAT), string.find(s, PAT) and a file-scope alias
--       (local sfind = string.find) -- whose string literals contain one of
--       %a %A %l %L %u %U %w %W %s %S %p %P %c %C %g %G (a '%%' is a literal
--       percent sign; the format strings of string.format/sprintf are not
--       patterns and are never looked at);
--   (b) every :lower(/:upper( method call, every string.lower/string.upper
--       and every call of a local alias of them, unless the enclosing
--       function is named in tools/verify_ctype_allowlist.lua (the facade's
--       asciiLower/asciiUpper/caseIsAscii).
-- Comments are skipped; strings, long strings and long comments are
-- tokenized, so a pattern spread over several lines is still seen.
--
-- Gate: exit status 1 when the list is not empty, with a count plus the
-- list (file: line numbers). --report-only prints the same list and exits 0.
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).

local REPORT_ONLY = false
for _, a in ipairs(arg or {}) do
    if a == '--report-only' then
        REPORT_ONLY = true
    else
        io.stderr:write('usage: lua tools/verify_ctype.lua [--report-only]\n')
        os.exit(2)
    end
end

local function walkUp(startDir)
    local repoDir = startDir
    while true do
        local marker = repoDir .. '/vendor/exiftool/t/ExifTool.t'
        local f = io.open(marker, 'r')
        if f then f:close(); return repoDir end
        local parent = repoDir:match('^(.*)/[^/]+$')
        if not parent then return repoDir end
        repoDir = parent
    end
end

local function moduleDir()
    local source = debug.getinfo(1, 'S').source
    if source:sub(1, 1) == '@' then source = source:sub(2) end
    source = source:gsub('\\', '/'):gsub('^%./', '')
    local ok, lfs = pcall(require, 'lfs')
    if ok and source:sub(1, 1) ~= '/' and not source:match('^[A-Za-z]:/') then
        local cwd = lfs.currentdir()
        if cwd then source = cwd:gsub('\\', '/') .. '/' .. source end
    end
    return source:match('^(.*)/[^/]+$') or '.'
end

local TOOLS = moduleDir()
local REPO = walkUp(TOOLS)
if not io.open(REPO .. '/vendor/exiftool/t/ExifTool.t', 'r') then
    io.stderr:write('verify_ctype.lua: repository root not found from ' .. TOOLS .. '\n')
    os.exit(2)
end

local ALLOW = dofile(TOOLS .. '/verify_ctype_allowlist.lua')

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

--------------------------------------------------------------------------------
-- Tokenizer: names, strings (raw source text between the delimiters, with
-- the line they start on), punctuation; comments and whitespace dropped.
--------------------------------------------------------------------------------
local function tokenize(src)
    local toks, i, n, line = {}, 1, #src, 1
    local function add(t, v, ln) toks[#toks + 1] = { t = t, v = v, line = ln } end
    local function countLines(a, b)
        local _, k = src:sub(a, b):gsub('\n', '')
        line = line + k
    end
    -- a long bracket [==[ ... ]==] at position p: its content and the end
    local function longBracket(p)
        local eq = src:match('^%[(=*)%[', p)
        if not eq then return nil end
        local close = ']' .. eq .. ']'
        local s = p + #eq + 2
        local e = src:find(close, s, true)
        if not e then e = n + 1 end
        return src:sub(s, e - 1), e + #close - 1
    end
    if src:sub(1, 2) == '#!' then i = (src:find('\n', 1, true) or n) end
    while i <= n do
        local c = src:sub(i, i)
        if c == '\n' then
            line = line + 1
            i = i + 1
        elseif c == ' ' or c == '\t' or c == '\r' or c == '\f' or c == '\v' then
            i = i + 1
        elseif src:sub(i, i + 1) == '--' then
            local _, e = longBracket(i + 2)
            if e then
                countLines(i, e)
                i = e + 1
            else
                i = src:find('\n', i, true) or (n + 1)
            end
        elseif c == '[' and src:match('^%[=*%[', i) then
            local body, e = longBracket(i)
            add('str', body, line)
            countLines(i, e)
            i = e + 1
        elseif c == '"' or c == "'" then
            local j, ln = i + 1, line
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then
                    if src:sub(j + 1, j + 1) == '\n' then line = line + 1 end
                    j = j + 2
                elseif d == c or d == '\n' then
                    break
                else
                    j = j + 1
                end
            end
            add('str', src:sub(i + 1, j - 1), ln)
            i = j + 1
        elseif c:match('[A-Za-z_]') then
            local w = src:match('^[A-Za-z_][A-Za-z0-9_]*', i)
            add('name', w, line)
            i = i + #w
        elseif c:match('[0-9]') or (c == '.' and src:match('^%.[0-9]', i)) then
            local num = src:match('^0[xX][0-9A-Fa-f%.]*[pP][-+]?[0-9]+', i)
                or src:match('^0[xX][0-9A-Fa-f%.]*', i)
                or src:match('^[0-9%.]*[eE][-+]?[0-9]+', i)
                or src:match('^[0-9%.]*', i)
            i = i + #num
        else
            local p = src:match('^%.%.%.', i) or src:match('^%.%.', i) or src:match('^::', i) or c
            add('p', p, line)
            i = i + #p
        end
    end
    return toks
end

-- the locale-dependent classes in a pattern's raw source text
local CLASS = {}
for k in ('aAlLuUwWsSpPcCgG'):gmatch('.') do CLASS[k] = true end
local function hasClass(s)
    local i = 1
    while true do
        i = s:find('%', i, true)
        if not i then return false end
        if CLASS[s:sub(i + 1, i + 1)] then return true end
        i = i + 2               -- (skips the escaped character: '%%s' is no class)
    end
end

local FIND = { find = true, match = true, gmatch = true, gsub = true }
local CASE = { lower = true, upper = true }
local OPEN = { ['('] = true, ['['] = true, ['{'] = true }
local CLOSE = { [')'] = true, [']'] = true, ['}'] = true }

-- the string tokens of argument #k of the call whose '(' is toks[i]
local function argStrings(toks, i, k)
    local depth, idx, out = 0, 1, {}
    for j = i, #toks do
        local t = toks[j]
        if t.t == 'p' and OPEN[t.v] then
            depth = depth + 1
        elseif t.t == 'p' and CLOSE[t.v] then
            depth = depth - 1
            if depth == 0 then break end
        elseif t.t == 'p' and t.v == ',' and depth == 1 then
            idx = idx + 1
            if idx > k then break end
        elseif t.t == 'str' and idx == k then
            out[#out + 1] = t
        end
    end
    return out
end

local function check(rel, src)
    local toks = tokenize(src)
    local classLines, caseLines, allowed = {}, {}, 0
    -- file-scope aliases: local sfind = string.find, local slower = string.lower
    local alias = {}
    for j = 1, #toks - 4 do
        local a, b, c, d, e = toks[j], toks[j + 1], toks[j + 2], toks[j + 3], toks[j + 4]
        if a.t == 'name' and b.v == '=' and c.v == 'string' and d.v == '.' and e.t == 'name'
            and (FIND[e.v] or CASE[e.v]) and toks[j - 1] and toks[j - 1].v == 'local'
            and not (toks[j + 5] and toks[j + 5].t == 'p' and toks[j + 5].v == '(') then
            alias[a.v] = e.v
        end
    end
    -- the enclosing function (for the allowlist): a stack of {name, depth}
    local depth, funcs = 0, {}
    local function current()
        return funcs[#funcs] and funcs[#funcs].name or '(main chunk)'
    end
    for j = 1, #toks do
        local t, prev, nxt = toks[j], toks[j - 1], toks[j + 1]
        if t.t == 'name' then
            local v = t.v
            local isField = prev and prev.t == 'p' and (prev.v == '.' or prev.v == ':')
            if v == 'function' then
                local name
                if nxt and nxt.t == 'name' then
                    local k = j + 1
                    name = toks[k].v
                    while toks[k + 1] and (toks[k + 1].v == '.' or toks[k + 1].v == ':')
                        and toks[k + 2] and toks[k + 2].t == 'name' do
                        name = name .. toks[k + 1].v .. toks[k + 2].v
                        k = k + 2
                    end
                elseif prev and prev.v == '=' and toks[j - 2] and toks[j - 2].t == 'name' then
                    name = toks[j - 2].v
                else
                    name = current()
                end
                depth = depth + 1
                funcs[#funcs + 1] = { name = name, depth = depth }
            elseif not isField and (v == 'do' or v == 'if' or v == 'repeat') then
                depth = depth + 1
            elseif not isField and (v == 'end' or v == 'until') then
                if funcs[#funcs] and funcs[#funcs].depth == depth then funcs[#funcs] = nil end
                depth = depth - 1
            end
            -- (a) pattern classes
            local argk
            if FIND[v] and prev and prev.v == ':' then
                argk = 1
            elseif FIND[v] and prev and prev.v == '.' and toks[j - 2] and toks[j - 2].v == 'string' then
                argk = 2
            elseif alias[v] and FIND[alias[v]] and not isField then
                argk = 2
            end
            if argk and nxt then
                local strs
                if nxt.t == 'str' and argk == 1 then
                    strs = { nxt }
                elseif nxt.v == '(' then
                    strs = argStrings(toks, j + 1, argk)
                end
                for _, s in ipairs(strs or {}) do
                    if hasClass(s.v) then classLines[#classLines + 1] = s.line end
                end
            end
            -- (b) case changes
            local isCase = (CASE[v] and prev and prev.v == ':')
                or (CASE[v] and prev and prev.v == '.' and toks[j - 2] and toks[j - 2].v == 'string'
                    -- (the alias declaration itself is not a use; its calls are)
                    and not (toks[j - 3] and toks[j - 3].v == '=' and toks[j - 5]
                        and toks[j - 5].v == 'local' and alias[toks[j - 4].v]))
                or (alias[v] and CASE[alias[v]] and not isField and nxt and nxt.v == '('
                    and not (prev and prev.v == 'local'))
            if isCase then
                if ALLOW[rel .. ':' .. current()] then
                    allowed = allowed + 1
                else
                    caseLines[#caseLines + 1] = t.line
                end
            end
        end
    end
    return classLines, caseLines, allowed
end

--------------------------------------------------------------------------------
-- The files to check (LuaFileSystem when present -- io.popen would go
-- through cmd.exe on Windows, which has no ls(1); dir /b is the fallback
-- there, ls elsewhere)
--------------------------------------------------------------------------------
local WINDOWS = package.config:sub(1, 1) == '\\'
local function luaFiles(dir)
    local out = {}
    local okLfs, lfs = pcall(require, 'lfs')
    if okLfs and lfs.dir then
        if lfs.attributes(dir, 'mode') == 'directory' then
            for name in lfs.dir(dir) do
                if name:match('%.lua$') then out[#out + 1] = name end
            end
        end
    else
        local cmd = WINDOWS and ('dir /b "' .. dir:gsub('/', '\\') .. '\\*.lua" 2>nul')
            or ("ls '" .. dir .. "' 2>/dev/null")
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                local name = line:gsub('\r$', '')
                if name:match('%.lua$') then out[#out + 1] = name end
            end
            p:close()
        end
    end
    table.sort(out)
    for k, name in ipairs(out) do out[k] = dir .. '/' .. name end
    return out
end

local paths = { REPO .. '/src/lexiftool.lua' }
for _, p in ipairs(luaFiles(REPO .. '/src/lexiftool')) do paths[#paths + 1] = p end
for _, p in ipairs(luaFiles(REPO .. '/capi')) do paths[#paths + 1] = p end
paths[#paths + 1] = REPO .. '/standalone/launcher.lua'
do  -- the launcher script, when it is Lua
    local s = readall(REPO .. '/lexiftool')
    if s and s:match('^#![^\n]*lua') then paths[#paths + 1] = REPO .. '/lexiftool' end
end
if #paths < 10 then
    io.stderr:write('verify_ctype.lua: no modules found in ' .. REPO .. '/src/lexiftool\n')
    os.exit(2)
end

local nClass, nCase, nAllowed, nFiles = 0, 0, 0, 0
local report = {}
for _, path in ipairs(paths) do
    local src = readall(path)
    if src then
        nFiles = nFiles + 1
        local rel = path:sub(#REPO + 2)
        local cl, ca, al = check(rel, src)
        nClass, nCase, nAllowed = nClass + #cl, nCase + #ca, nAllowed + al
        if #cl > 0 then
            report[#report + 1] = ('  %s classes (%d): %s'):format(rel, #cl, table.concat(cl, ' '))
        end
        if #ca > 0 then
            report[#report + 1] = ('  %s lower/upper (%d): %s'):format(rel, #ca, table.concat(ca, ' '))
        end
    end
end

if nClass + nCase == 0 then
    print(('verify_ctype: %d file(s), no locale-dependent pattern class or case change '
        .. '(%d allowlisted case change(s) in the facade) -- ok'):format(nFiles, nAllowed))
    os.exit(0)
end
print(('verify_ctype%s: %d file(s), %d find/match/gmatch/gsub pattern(s) with a locale-dependent '
    .. 'class (%%a %%l %%u %%w %%s %%p %%c %%g or a negation -- spell the ASCII set), %d '
    .. 'lower/upper call(s) outside the facade (use perl.lc/perl.uc; %d allowlisted) '
    .. '-- doc/conventions.md §3a:'):format(REPORT_ONLY and ' (report only)' or '',
    nFiles, nClass, nCase, nAllowed))
for _, l in ipairs(report) do print(l) end
os.exit(REPORT_ONLY and 0 or 1)
