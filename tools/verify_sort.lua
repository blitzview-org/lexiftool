--------------------------------------------------------------------------------
-- File:         tools/verify_sort.lua
--
-- Description:  verify that ported code sorts through the perl facade
--               (perl.sort/perl.tsort), never through a raw table.sort
--------------------------------------------------------------------------------

-- doc/conventions.md §3a: Perl's sort and its string comparisons (cmp, lt,
-- gt, ...) order strings as unsigned bytes, whatever the locale (upstream
-- never uses `use locale`). Lua's `<` on two strings goes through strcoll, so
-- a raw table.sort follows the LC_COLLATE of the process's locale, which an
-- embedding host may have set (de_DE sorts "a A b B", Perl "A B a b").
-- perl.sort and perl.tsort sort strings bytewise; a comparator that orders
-- strings uses perl.lt/perl.cmp.
--
-- The check: no `table.sort` (a call or an alias of it) on a code line of the
-- library (src/lexiftool.lua, src/lexiftool/, and the Lua side of the C API
-- in capi/ and standalone/) outside src/lexiftool/perl.lua. Comment text is
-- ignored. String
-- comparisons inside comparators cannot be told apart from numeric ones
-- here; those are reviewed against the Perl line (`cmp` vs `<=>`).
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).
-- Exits 1 if any library file uses table.sort.

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

local REPO = walkUp(moduleDir())
if not io.open(REPO .. '/vendor/exiftool/t/ExifTool.t', 'r') then
    io.stderr:write('verify_sort.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

local failures = 0
local p = io.popen("find '" .. REPO .. "/src/lexiftool' '" .. REPO .. "/capi' '" .. REPO
    .. "/standalone' -name '*.lua' 2>/dev/null; ls '" .. REPO .. "/src/lexiftool.lua' 2>/dev/null")
for path in p:lines() do
    if not path:match('/src/lexiftool/perl%.lua$') then
        local src = readall(path) or ''
        local n = 0
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            local code = line:gsub('%-%-.*$', '')
            if code:find('%f[%w_]table%s*%.%s*sort%f[^%w_]') then
                print(('%s:%d: raw table.sort -- use perl.tsort/perl.sort: %s')
                    :format(path:sub(#REPO + 2), n, line:match('^%s*(.-)%s*$')))
                failures = failures + 1
            end
        end
    end
end
p:close()

if failures > 0 then
    print(('verify_sort: %d raw table.sort use(s) -- sort through perl.tsort/perl.sort'
        .. ' (doc/conventions.md §3a)'):format(failures))
    os.exit(1)
end
print('verify_sort: OK')
