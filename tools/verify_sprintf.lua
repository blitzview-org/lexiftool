--------------------------------------------------------------------------------
-- File:         tools/verify_sprintf.lua
--
-- Description:  verify that ported code reaches Perl's sprintf through the
--               perl.sprintf facade, not through a raw string.format
--------------------------------------------------------------------------------

-- doc/conventions.md §3a: where the Perl line contains a builtin, the Lua line
-- uses the facade. For sprintf/printf that matters beyond style -- Lua's
-- string.format differs from Perl's sprintf (Inf/NaN spelling, %d of a
-- non-integral number raises, %s of 1.0 prints "1.0", no %u/%b/%v, ...).
--
-- Lines cannot be matched 1:1 between a Lua module and its Perl original, so
-- the check works on the format string: a raw `string.format('FMT', ...)` (or
-- `('FMT'):format(...)`) in a ported module is reported when FMT also occurs
-- as a string literal on a sprintf/printf line of the module's Perl original --
-- either verbatim, or with the same words once the conversions and Perl's
-- interpolated variables are stripped ("Error reading value for $dir entry
-- $index, ID 0x%.4x" matches "Error reading value for %s entry %d, ID
-- 0x%.4x"). Formats built at runtime and formatting that has no sprintf
-- behind it upstream (hex dumps standing in for unpack('H*'), interpolated
-- messages) are not reported. Comment lines are skipped.
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).
-- Exits 1 if any raw string.format mirrors an upstream sprintf.

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
    io.stderr:write('verify_sprintf.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local LIB = REPO .. '/vendor/exiftool/lib'
local SRC = REPO .. '/src/lexiftool'

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

-- The upstream file a Lua module is ported from (nil if it has none).
local function perlSource(luaName)
    if luaName == 'main' then return readall(REPO .. '/vendor/exiftool/exiftool') end
    if luaName == 'lexiftool' then return readall(LIB .. '/Image/ExifTool.pm') end
    return readall(LIB .. '/Image/ExifTool/' .. luaName .. '.pm')
        or readall(LIB .. '/Image/ExifTool/' .. luaName .. '.pl')
end

-- Read the quoted literal starting at position i of s (s:sub(i, i) is the
-- quote character); returns its raw body (escapes left as written) and the
-- position after the closing quote.
local function quoted(s, i)
    local q = s:sub(i, i)
    local j = i + 1
    while j <= #s do
        local c = s:sub(j, j)
        if c == '\\' then
            j = j + 2
        elseif c == q then
            return s:sub(i + 1, j - 1), j + 1
        else
            j = j + 1
        end
    end
end

-- Drop Perl interpolations ($x, $$x, ${x}, $x{...}, $$x{...}[...]).
local function stripInterp(s)
    local out, i = {}, 1
    while i <= #s do
        local a, b = s:find('%$%$?{?[%w_]+}?', i)
        if not a then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, a - 1) .. ' '
        i = b + 1
        while true do
            local c = s:sub(i, i)
            local close = (c == '{' and '}') or (c == '[' and ']')
            local e = close and s:find(close, i + 1, true)
            if not e then break end
            i = e + 1
        end
    end
    return table.concat(out)
end

-- The words of a format once its conversions are removed ('' if none).
local function skeleton(s, perlLiteral)
    if perlLiteral then s = stripInterp(s) end
    s = s:gsub('%%[-+ #0-9.*]*[%a%%]', ' ')
    local w = {}
    for word in s:gmatch('[%w_]+') do w[#w + 1] = word end
    return table.concat(w, ' ')
end

-- Add every quoted literal of s to the sets -- and the literals nested in
-- them, since upstream conversion code is itself a string
-- (PrintConv => 'sprintf("%.1f",$val)').
local function addLiterals(s, exact, skel)
    local i = 1
    while true do
        local q = s:find('["\']', i)
        if not q then break end
        local body, nxt = quoted(s, q)
        if not body then break end
        exact[(body:gsub('\\\\', '\\'))] = true
        local k = skeleton(body, true)
        if k ~= '' then skel[k] = true end
        addLiterals(body, exact, skel)
        i = nxt
    end
end

-- Literals on the sprintf/printf lines of a Perl source.
local function perlFormats(src)
    local exact, skel = {}, {}
    for line in src:gmatch('[^\n]*') do
        if line:find('printf', 1, true) then addLiterals(line, exact, skel) end
    end
    return exact, skel
end

local failures = 0
local p = io.popen("ls '" .. SRC .. "'/*.lua '" .. REPO .. "'/src/lexiftool.lua 2>/dev/null")
for path in p:lines() do
    local mod = path:match('([^/]+)%.lua$')
    local src = mod ~= 'perl' and readall(path)
    local perlSrc = src and perlSource(mod)
    if perlSrc then
        local exact, skel = perlFormats(perlSrc)
        local n = 0
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            if not line:match('^%s*%-%-') then
                local init = 1
                while true do
                    local a, b = line:find('string%.format%(%s*', init)
                    local litPos
                    if a then
                        litPos = b + 1
                    else
                        a, b = line:find('%(%s*[\'"]', init)
                        if a then
                            local _, after = quoted(line, b)
                            if after and line:find('^%)%s*:format%(', after) then
                                litPos = b
                            end
                        end
                    end
                    if not a then break end
                    init = b + 1
                    local c = litPos and line:sub(litPos, litPos)
                    if c == "'" or c == '"' then
                        local body = quoted(line, litPos)
                        if body then
                            local f = body:gsub('\\\\', '\\')
                            local k = skeleton(f)
                            if exact[f] or (k ~= '' and skel[k]) then
                                print(('%s:%d: raw string.format where upstream has sprintf: %s')
                                    :format(path:sub(#REPO + 2), n, line:match('^%s*(.-)%s*$')))
                                failures = failures + 1
                            end
                        end
                    end
                end
            end
        end
    end
end
p:close()

if failures > 0 then
    print(('verify_sprintf: %d raw string.format call(s) mirror an upstream sprintf'
        .. ' -- use the perl.sprintf facade (doc/conventions.md §3a)'):format(failures))
    os.exit(1)
end
print('verify_sprintf: OK')
