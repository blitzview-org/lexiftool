--------------------------------------------------------------------------------
-- File:         tools/verify_procs.lua
--
-- Description:  verify that a ported tag table carries the same
--               PROCESS_PROC / WRITE_PROC / CHECK_PROC as its Perl original
--------------------------------------------------------------------------------

-- A tag table's *_PROC entries are what the generic engines dispatch through:
-- Writer.WriteDirectory looks up WRITE_PROC, ProcessDirectory looks up
-- PROCESS_PROC, SetNewValue looks up CHECK_PROC. A table that carries the
-- function upstream but not here forces every container to call the writer
-- directly -- and with it to re-implement, once per container, the decisions
-- WriteDirectory makes centrally (group deletion, PROCESSED bookkeeping,
-- CHANGED handling). That is a bug factory, so it is checked.
--
-- Only the ACTIONABLE case is a failure: upstream names a function in the
-- *_PROC, and this port defines a function of that same name, but the port's
-- table doesn't reference it. A table whose proc simply isn't ported yet is
-- not reported at all -- that is ordinary port scope, documented in each
-- module's Port notes and already visible in verify_structure's MISSING list.
-- Known deliberate gaps live in tools/verify_procs_allowlist.lua (reported,
-- but not a failure).
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).
-- Exits 1 if any table is missing a proc whose function the port has.

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
        -- forward slashes: a Windows path (backslashes) would be eaten as
        -- escapes by Perl's glob in the runtime checks below
        if cwd then source = cwd:gsub('\\', '/') .. '/' .. source end
    end
    return source:match('^(.*)/[^/]+$') or '.'
end

local REPO = walkUp(moduleDir())
if not io.open(REPO .. '/vendor/exiftool/t/ExifTool.t', 'r') then
    io.stderr:write('verify_procs.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local LIB = REPO .. '/vendor/exiftool/lib/Image/ExifTool'
local SRC = REPO .. '/src/lexiftool'

local PROCS = { 'PROCESS_PROC', 'WRITE_PROC', 'CHECK_PROC' }

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

-- ---------------------------------------------------------------------------
-- Upstream: "%Image::ExifTool::Mod::Table = ( ... PROC => \&Func ... )"
-- ---------------------------------------------------------------------------
-- Returns { ['Mod.Table'] = { PROC = 'Func', ... }, ... }
local function perlTables()
    local tables = {}
    local p = io.popen("ls '" .. LIB .. "'/*.pm '" .. LIB .. "'/*.pl 2>/dev/null")
    if not p then return tables end
    for path in p:lines() do
        local src = readall(path) or ''
        local pos = 1
        while true do
            local s, e, name = src:find('%%Image::ExifTool::([%w:]+)%s*=%s*%(', pos)
            if not s then break end
            -- the table body ends at the first "\n);" (every upstream table
            -- closes that way, and a nested paren never starts a line)
            local stop = src:find('\n%);', e) or #src
            local body = src:sub(e + 1, stop)
            local entry
            for _, proc in ipairs(PROCS) do
                local func = body:match('\n%s*' .. proc .. '%s*=>%s*\\&([%w:]+)')
                if func then
                    entry = entry or {}
                    entry[proc] = func:match('([%w_]+)$')
                end
            end
            if entry then tables[(name:gsub('::', '.'))] = entry end
            pos = e + 1
        end
    end
    p:close()
    return tables
end

-- ---------------------------------------------------------------------------
-- Port: which tables already carry which procs, and which functions exist
-- ---------------------------------------------------------------------------
-- Include files that upstream compiles into another module's package (the
-- .pl files loaded by AUTOLOAD/require): their subs count for that package,
-- since upstream's `\&Func` in a table of the package resolves to them too
local INCLUDE_OF = {
    XMP2 = 'XMP', XMPStruct = 'XMP', WriteXMP = 'XMP',
    WriteIPTC = 'IPTC', WritePhotoshop = 'Photoshop',
    WritePNG = 'PNG', WriteRIFF = 'RIFF',
    WritePDF = 'PDF', WritePostScript = 'PostScript',
    WriteCanonRaw = 'CanonRaw',
    QuickTimeStream = 'QuickTime', WriteQuickTime = 'QuickTime',
}

local function portState()
    local has, funcs, tables = {}, {}, {}
    local p = io.popen("ls '" .. SRC .. "'/*.lua '" .. REPO .. "'/src/lexiftool.lua 2>/dev/null")
    if not p then return has, funcs end
    for path in p:lines() do
        local src = readall(path) or ''
        local mod = path:match('([^/]+)%.lua$')
        funcs[mod] = funcs[mod] or {}
        for name in src:gmatch('\nfunction%s+[%w_]+[.:]([%w_]+)%s*%(') do funcs[mod][name] = true end
        for name in src:gmatch('\nlocal%s+function%s+([%w_]+)%s*%(') do funcs[mod][name] = true end
        -- (a sub assigned to a predeclared local: `function ProcessMOV(...)`)
        for name in src:gmatch('\nfunction%s+([%w_]+)%s*%(') do funcs[mod][name] = true end
        local pkg = INCLUDE_OF[mod]
        if pkg then
            funcs[pkg] = funcs[pkg] or {}
            for name in pairs(funcs[mod]) do funcs[pkg][name] = true end
        end
        -- every table this port actually defines ("X.Table = {")
        for m1, m2 in src:gmatch('\n([%w_]+)%.([%w_]+)%s*=%s*[%w_]*%s*{') do
            tables[m1 .. '.' .. m2] = true
        end
        for _, proc in ipairs(PROCS) do
            -- "X.Table.PROC = ..." (assigned after the table literal)
            for tbl in src:gmatch('\n%s*([%w_]+%.[%w_]+)%.' .. proc .. '%s*=') do
                has[tbl] = has[tbl] or {}
                has[tbl][proc] = true
            end
            -- "PROC = ..." inside a "X.Table = {" literal
            local pos = 1
            while true do
                local s, e, m1, m2 = src:find('\n([%w_]+)%.([%w_]+)%s*=%s*[%w_]*%s*{', pos)
                if not s then break end
                local stop = src:find('\n}', e) or #src
                if src:sub(e + 1, stop):match('\n%s*' .. proc .. '%s*=') then
                    local tbl = m1 .. '.' .. m2
                    has[tbl] = has[tbl] or {}
                    has[tbl][proc] = true
                end
                pos = e + 1
            end
        end
        -- WriteExif.lua wires WRITE_PROC onto a list of MakerNote tables
        local list = src:match("for _, spec in ipairs%(%{(.-)%}%) do")
        if list then
            for a, b in list:gmatch("{%s*'([%w_]+)',%s*'([%w_]+)'%s*}") do
                has[a .. '.' .. b] = has[a .. '.' .. b] or {}
                has[a .. '.' .. b].WRITE_PROC = true
            end
        end
    end
    p:close()
    return has, funcs, tables
end

-- known deliberate gaps (reported, but not a failure)
local allowlist = dofile(moduleDir() .. '/verify_procs_allowlist.lua')

local upstream = perlTables()
local has, funcs, portTables = portState()

local names = {}
for name in pairs(upstream) do names[#names + 1] = name end
table.sort(names)

local checked, problems, allowed = 0, {}, {}
for _, name in ipairs(names) do
    local mod = name:match('^([%w_]+)%.')
    -- only tables this port actually defines (an unported table is ordinary
    -- port scope, already visible in verify_structure's MISSING list)
    if funcs[mod] and portTables[name] then
        for _, proc in ipairs(PROCS) do
            local func = upstream[name][proc]
            -- ...and only where the port defines the function upstream names
            if func and funcs[mod][func] then
                checked = checked + 1
                if not (has[name] and has[name][proc]) then
                    local line = string.format('%-34s %-13s -> %s', name, proc, func)
                    local why = allowlist[name .. ' ' .. proc]
                    if why then
                        allowed[#allowed + 1] = line .. '   (' .. why .. ')'
                    else
                        problems[#problems + 1] = line
                    end
                end
            end
        end
    end
end

io.write(string.format('%d table procs checked against the Perl originals\n', checked))
if #allowed > 0 then
    io.write(string.format('%d allowlisted gap(s):\n', #allowed))
    for _, line in ipairs(allowed) do io.write('  ' .. line .. '\n') end
end
if #problems > 0 then
    io.write('\nTable carries no proc although the port HAS the function:\n')
    for _, line in ipairs(problems) do io.write('  ' .. line .. '\n') end
    io.write(string.format('FAIL: %d table proc(s) not wired up\n', #problems))
    os.exit(1)
end
io.write('OK: every ported proc is wired to its table, as upstream\n')
os.exit(0)
