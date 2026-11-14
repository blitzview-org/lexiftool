--------------------------------------------------------------------------------
-- File:         tools/verify_tostring.lua
--
-- Description:  reject tostring() calls outside the perl facade that may
--               stringify a number (gate)
--------------------------------------------------------------------------------

-- Perl stringifies a number with %.15g and always with '.' as the decimal
-- point (LC_NUMERIC stays "C" outside `use locale`). perl.str does the same
-- whatever the process's locale; Lua's tostring() does not: it uses %.14g,
-- adds '.0' to an integral float, and prints the decimal point of the global
-- C locale an embedding host may have set ("1,5"); it also prints undef
-- (nil) as "nil" where Perl prints ''. So ported code stringifies with
-- perl.str (doc/conventions.md §3a), and tostring() is left for error
-- objects (the second value of a failed pcall).
--
-- This lists every tostring(ARG) call in src/lexiftool.lua and
-- src/lexiftool/*.lua (perl.lua excluded) whose ARG is not recognizably a
-- string or an integer: a string literal, a concatenation, a length (#x),
-- a byte or math.floor/tointeger result, an error object in one of the
-- port's idioms (`isDie(X) and X.msg or tostring(X)`, an argument of
-- debug.traceback), or an expression named in
-- tools/verify_tostring_allowlist.lua. Method calls (buf:tostring()) and
-- comment lines are skipped.
--
-- Gate: exit status 1 when the list is not empty, with a count plus the
-- list (module: line numbers).
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).

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
    source = source:gsub('^%./', '')
    local ok, lfs = pcall(require, 'lfs')
    if ok and source:sub(1, 1) ~= '/' then
        local cwd = lfs.currentdir()
        if cwd then source = cwd:gsub('\\', '/') .. '/' .. source end
    end
    return source:match('^(.*)/[^/]+$') or '.'
end

local TOOLS = moduleDir()
local REPO = walkUp(TOOLS)
if not io.open(REPO .. '/vendor/exiftool/t/ExifTool.t', 'r') then
    io.stderr:write('verify_tostring.lua: repository root not found from ' .. TOOLS .. '\n')
    os.exit(2)
end

local SRC = REPO .. '/src/lexiftool'
local ALLOW = dofile(TOOLS .. '/verify_tostring_allowlist.lua')

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

-- The argument of the call whose '(' is at position i of line (balanced
-- parentheses, quotes skipped), or nil when it does not close on the line.
local function argument(line, i)
    local depth, j = 0, i
    while j <= #line do
        local c = line:sub(j, j)
        if c == "'" or c == '"' then
            local k = j + 1
            while k <= #line do
                local d = line:sub(k, k)
                if d == '\\' then k = k + 1 elseif d == c then break end
                k = k + 1
            end
            j = k
        elseif c == '(' then
            depth = depth + 1
        elseif c == ')' then
            depth = depth - 1
            if depth == 0 then return line:sub(i + 1, j - 1) end
        end
        j = j + 1
    end
end

-- Is the argument recognizably a string or an integer (or an error object)?
local function isStringy(arg, code, at)
    -- (an error object: Perl's die message or a die object's text)
    local x = arg:match('^[%w_]+$')
    if x and code:find('isDie%(' .. x .. '%) and ' .. x .. '%.msg or tostring%(' .. x .. '%)') then
        return true
    end
    local tb = code:find('debug.traceback(', 1, true)
    if tb and tb < at then return true end
    if arg:match('^[\'"][^\'"]*[\'"]$') then return true end   -- literal
    if arg:find('..', 1, true) and not arg:find('%d%.%.') then
        -- (a concatenation is a string already; "1..2" is no concatenation)
        local stripped = arg:gsub('%b()', '')
        if stripped:find('%.%.') then return true end
    end
    if arg:match('^#') then return true end                      -- a length
    if arg:match(':byte%(') or arg:match('^string%.byte%(') then return true end
    if arg:match('^math%.floor%(') or arg:match('^math%.tointeger%(') then return true end
    return ALLOW[arg] ~= nil
end

-- The files to check (LuaFileSystem when present -- io.popen would go
-- through cmd.exe on Windows, which has no ls(1); the shell is the fallback)
local paths = {}
local okLfs, lfs = pcall(require, 'lfs')
if okLfs and lfs.dir then
    for name in lfs.dir(SRC) do
        if name:match('%.lua$') then paths[#paths + 1] = SRC .. '/' .. name end
    end
    table.sort(paths)
    paths[#paths + 1] = REPO .. '/src/lexiftool.lua'
else
    local p = io.popen("ls '" .. SRC .. "'/*.lua '" .. REPO .. "'/src/lexiftool.lua 2>/dev/null")
    for path in p:lines() do paths[#paths + 1] = path end
    p:close()
end
if #paths < 2 then
    io.stderr:write('verify_tostring.lua: no modules found in ' .. SRC .. '\n')
    os.exit(2)
end

local total, allowed, listed = 0, 0, 0
local byModule, order = {}, {}
for _, path in ipairs(paths) do
    local mod = path:match('([^/]+%.lua)$')
    local src = mod ~= 'perl.lua' and readall(path)
    if src then
        local n = 0
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            if not line:match('^%s*%-%-') then
                local code = line:gsub('%s*%-%-[^\'"]*$', '')
                local init = 1
                while true do
                    local a, b = code:find('tostring%(', init)
                    if not a then break end
                    init = b + 1
                    local prev = a > 1 and code:sub(a - 1, a - 1) or ''
                    if not prev:match('[%w_:.]') then
                        total = total + 1
                        local arg = argument(code, b)
                        arg = arg and arg:gsub('%s+', ' '):match('^%s*(.-)%s*$')
                        if arg and isStringy(arg, code, a) then
                            allowed = allowed + 1
                        else
                            listed = listed + 1
                            local rel = path:sub(#REPO + 2)
                            if not byModule[rel] then
                                byModule[rel] = {}
                                order[#order + 1] = rel
                            end
                            local t = byModule[rel]
                            t[#t + 1] = n
                        end
                    end
                end
            end
        end
    end
end

if listed == 0 then
    print(('verify_tostring: %d tostring() call(s) outside perl.lua, all on strings, integers '
        .. 'or error objects -- ok'):format(total))
    os.exit(0)
end
print(('verify_tostring: %d tostring() call(s) outside perl.lua, %d recognizably string/integer/error, '
    .. '%d may stringify a number -- use perl.str (doc/conventions.md §3a), or name an error '
    .. 'object in tools/verify_tostring_allowlist.lua:'):format(total, allowed, listed))
for _, rel in ipairs(order) do
    local lines = byModule[rel]
    -- one line per module: the line numbers (duplicates for several calls on a line)
    print(('  %s (%d): %s'):format(rel, #lines, table.concat(lines, ' ')))
end
os.exit(1)
