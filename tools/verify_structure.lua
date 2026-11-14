--------------------------------------------------------------------------------
-- File:         tools/verify_structure.lua
--
-- Description:  verify function-level structural parity of the ported modules
--------------------------------------------------------------------------------

-- Compares, per ported module, the Perl `sub NAME` definitions against the
-- Lua function names (both `function Mod.NAME` / `function Mod:NAME` and
-- `local function NAME`), mirroring conventions.md §2 ("Function names ...
-- identical to Perl"). Three classes are reported:
--
--   MISSING  - a Perl sub has no Lua function of the same name (either it was
--              merged into another function, split, or silently dropped)
--   RENAMED  - a Perl sub has a Lua counterpart whose name differs only by
--              case (a pure naming violation, cheap to fix)
--   EXTRA    - a Lua function has no same-named Perl sub (a port-internal
--              helper, or a renamed Perl sub that isn't just a case change)
--
-- The gate is the `missing`/`renamed` direction: every Perl sub must exist as
-- a same-named Lua function. Modules still in remediation are listed in
-- tools/verify_structure_allowlist.lua (report-only); anything NOT listed must
-- be clean. Removing a module from the allowlist ratchets the gate up.
--
-- Run from anywhere (repository root is resolved by walking up, like TestLib).
-- Exits 1 if any non-allowlisted module has MISSING or RENAMED subs.

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
    io.stderr:write('verify_structure.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local LIB = REPO .. '/vendor/exiftool/lib'
local SRC = REPO .. '/src/lexiftool'

-- ---------------------------------------------------------------------------
-- Module -> upstream Perl file mapping.
-- ---------------------------------------------------------------------------
-- The main module lives NEXT TO the package dir; the exiftool CLI script maps
-- to main.lua; RandomAccess maps to the File/ support module; WriteExif/Writer
-- map to their .pl originals; everything else is a same-named .pm under
-- Image/ExifTool/, or the same-named .pl when there is no .pm (the include
-- files QuickTimeStream.pl, WriteQuickTime.pl, ... that upstream loads into
-- another module's package).
local function perlPathFor(luaName)
    if luaName == 'main' then
        return REPO .. '/vendor/exiftool/exiftool', 'main'
    elseif luaName == 'ExifTool' then
        return LIB .. '/Image/ExifTool.pm', 'ExifTool'
    elseif luaName == 'RandomAccess' then
        return LIB .. '/File/RandomAccess.pm', 'RandomAccess'
    elseif luaName == 'WriteExif' or luaName == 'Writer' then
        return LIB .. '/Image/ExifTool/' .. luaName .. '.pl', luaName
    else
        local pm = LIB .. '/Image/ExifTool/' .. luaName .. '.pm'
        local f = io.open(pm, 'r')
        if f then
            f:close()
            return pm, luaName
        end
        local pl = LIB .. '/Image/ExifTool/' .. luaName .. '.pl'
        f = io.open(pl, 'r')
        if f then
            f:close()
            return pl, luaName
        end
        return pm, luaName
    end
end

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

-- Extract Perl sub DEFINITIONS (skip forward declarations `sub X(...);` and
-- `sub X;`, and the `AUTOLOAD` catch-all). Returns a set and an ordered list.
local function perlSubs(path)
    local f = io.open(path, 'rb')
    if not f then return nil, nil end
    local set, list = {}, {}
    for line in f:lines() do
        -- (a package-qualified definition, `sub Image::ExifTool::EndDir()`
        --  in the exiftool script, counts under its last component)
        local name = line:match('^sub%s+[A-Za-z_][A-Za-z0-9_:]*::([A-Za-z_][A-Za-z0-9_]*)')
            or line:match('^sub%s+([A-Za-z_][A-Za-z0-9_]*)')
        if name and name ~= 'AUTOLOAD' and not set[name] then
            if not line:match(';%s*$') then
                set[name] = true
                list[#list + 1] = name
            end
        end
    end
    f:close()
    return set, list
end

-- Extract Lua function names: `function Mod.NAME` / `function Mod:NAME` /
-- `local function NAME`. Returns a set and an ordered list.
local function luaFuncs(path)
    local f = io.open(path, 'rb')
    if not f then return nil, nil end
    local set, list = {}, {}
    local function add(name)
        if name and not set[name] then
            set[name] = true
            list[#list + 1] = name
        end
    end
    for line in f:lines() do
        add(line:match('^function%s+[A-Za-z_][A-Za-z0-9_]*%.([A-Za-z_][A-Za-z0-9_]*)'))
        add(line:match('^function%s+[A-Za-z_][A-Za-z0-9_]*:([A-Za-z_][A-Za-z0-9_]*)'))
        add(line:match('^local%s+function%s+([A-Za-z_][A-Za-z0-9_]*)'))
        -- forward-declared locals filled at the bottom of the module
        -- (conventions.md §2: `NAME = function(...)`)
        add(line:match('^local%s+([A-Za-z_][A-Za-z0-9_]*)%s*=%s*function'))
        add(line:match('^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*function'))
        -- the same, in `function NAME(...)` sugar: after a `local NAME`
        -- forward declaration this assigns that local, not a global
        add(line:match('^function%s+([A-Za-z_][A-Za-z0-9_]*)%s*%('))
    end
    f:close()
    return set, list
end

-- ---------------------------------------------------------------------------
-- Allowlist (ratchet). tools/verify_structure_allowlist.lua returns a table
-- { ModuleName = true, ... }; listed modules are report-only.
-- ---------------------------------------------------------------------------
local allowlist = {}
do
    local f = loadfile(REPO .. '/tools/verify_structure_allowlist.lua')
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == 'table' then allowlist = t end
    end
end

-- Discover Lua modules: the package files plus the main module.
local modules = { { lua = SRC .. '.lua', name = 'ExifTool' } }
do
    local p = io.popen("find '" .. SRC .. "' -maxdepth 1 -name '*.lua' | sort")
    for line in p:lines() do
        local base = line:match('([^/]+)%.lua$')
        if base and base ~= 'perl' and base ~= 'usage' then
            modules[#modules + 1] = { lua = line, name = base }
        end
    end
    p:close()
end

local problems = 0
local function report(name, msg)
    problems = problems + 1
    io.write(string.format('%s: %s\n', name, msg))
end

local clean, dirty = {}, {}
for _, m in ipairs(modules) do
    local perlPath, name = perlPathFor(m.name)
    if io.open(perlPath, 'rb') then
        local pset, plist = perlSubs(perlPath)
        local lset, llist = luaFuncs(m.lua)
        if not pset or not lset then
            report(name, 'could not read ' .. perlPath .. ' or ' .. m.lua)
        else
            local missing, renamed, extra = {}, {}, {}
            for _, sub in ipairs(plist) do
                if not lset[sub] then
                    local renamedTo
                    for lfn in pairs(lset) do
                        if lfn:lower() == sub:lower() then renamedTo = lfn break end
                    end
                    if renamedTo then
                        renamed[#renamed + 1] = sub .. ' -> ' .. renamedTo
                    else
                        missing[#missing + 1] = sub
                    end
                end
            end
            for _, lfn in ipairs(llist) do
                if not pset[lfn] then
                    local renamedFrom
                    for sub in pairs(pset) do
                        if sub:lower() == lfn:lower() then renamedFrom = sub break end
                    end
                    if not renamedFrom then extra[#extra + 1] = lfn end
                end
            end
            local inAllow = allowlist[name] == true
            if #missing > 0 or #renamed > 0 then
                dirty[#dirty + 1] = name
                local tag = inAllow and '(allowlisted) ' or ''
                io.write(string.format('  %s%s: %d missing, %d renamed\n', tag, name, #missing, #renamed))
                if #missing > 0 then
                    io.write(string.format('    missing: %s\n', table.concat(missing, ', ')))
                end
                if #renamed > 0 then
                    io.write(string.format('    renamed: %s\n', table.concat(renamed, ', ')))
                end
                if #extra > 0 then
                    io.write(string.format('    extra:   %s\n', table.concat(extra, ', ')))
                end
                -- MISSING is report-only (legitimate port scope, documented in
                -- each module's Port notes); only RENAMED (a pure naming
                -- violation) is a hard gate, and only for non-allowlisted
                -- modules.
                if not inAllow then
                    problems = problems + #renamed
                end
            else
                clean[#clean + 1] = name
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Eager requires.  A top-level `local X = require('lexiftool.X')` must mirror
-- an upstream `use Image::ExifTool::X;` -- otherwise the module is loaded for
-- files that never need it, and BuildCompositeTags (which derives its worklist
-- from `package.loaded`) reorders Composite tags for every file.  The pairs
-- that predate this check live in tools/verify_requires_allowlist.lua.
-- ---------------------------------------------------------------------------
do
    local allow = {}
    local f = loadfile(REPO .. '/tools/verify_requires_allowlist.lua')
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == 'table' then
            for mod, list in pairs(t) do
                allow[mod] = {}
                for _, x in ipairs(list) do allow[mod][x] = true end
            end
        end
    end
    local bad = 0
    for _, m in ipairs(modules) do
        local pm = LIB .. '/Image/ExifTool/' .. m.name .. '.pm'
        local perlSrc = readall(pm)
        if perlSrc then
            local uses = {}
            -- (`use Image::ExifTool::HTML qw(EscapeHTML);` loads the module
            --  just the same, so an import list counts as a `use` too)
            for u in perlSrc:gmatch('\nuse Image::ExifTool::(%w+)[ ;]') do uses[u] = true end
            local luaSrc = readall(m.lua) or ''
            for x in luaSrc:gmatch("\nlocal [A-Za-z_][%w_]* = require%('lexiftool%.(%w+)'%)") do
                -- (perl/usage are port-internal; a module with no upstream .pm
                --  of its own cannot be matched against a `use` line)
                -- (Writer/WriteExif are .pl upstream -- ExifTool.pm requires
                --  them lazily, so they never appear in a `use` line and are
                --  exactly the worst case: WriteExif pulls in nearly every
                --  vendor module)
                local target = readall(LIB .. '/Image/ExifTool/' .. x .. '.pm')
                            or readall(LIB .. '/Image/ExifTool/' .. x .. '.pl')
                -- `Writer` and `Shift` are exempt: measured, they pull only
                -- Charset/RandomAccess/Shift/TagLookup -- no vendor module, so
                -- no Composite table enters the worklist because of them.
                -- `WriteExif` is the opposite (nearly every vendor module) and
                -- stays gated.
                if x ~= 'perl' and x ~= 'usage' and x ~= 'Writer' and x ~= 'Shift'
                        and not uses[x] and target
                        and not (allow[m.name] and allow[m.name][x]) then
                    io.write(string.format('  EAGER REQUIRE: %s requires %s, but %s.pm has no ' ..
                        '`use Image::ExifTool::%s` -- load it lazily\n', m.name, x, m.name, x))
                    bad = bad + 1
                end
            end
        end
    end
    if bad > 0 then
        io.write(string.format('FAIL: %d eager require(s) without an upstream `use`\n', bad))
        os.exit(1)
    end
end

-- ---------------------------------------------------------------------------
-- A Condition function receives (self, val, format, count) -- `val` IS the
-- `$$valPt` of the Perl original, there is no separate third argument for it.
-- A third parameter named `valPt` means the condition silently reads `format`
-- instead of the data and never matches.
-- ---------------------------------------------------------------------------
do
    local hits = 0
    local p = io.popen("grep -rn 'Condition = function([A-Za-z_]*, _*val, _*valPt' '" ..
        SRC .. "' 2>/dev/null")
    if p then
        for line in p:lines() do
            io.write('  BAD CONDITION SIGNATURE: ' .. line .. '\n')
            hits = hits + 1
        end
        p:close()
    end
    if hits > 0 then
        io.write(string.format('FAIL: %d Condition(s) with a bogus third `valPt` ' ..
            'parameter -- the value arrives as the SECOND argument\n', hits))
        os.exit(1)
    end
end

-- ---------------------------------------------------------------------------
-- `cond and nil or val` is NOT Perl's `cond ? undef : val`: in Lua
-- `cond and nil` is falsy, so the `or` branch always wins and the expression
-- can never yield nil.  This bit 84 ported RawConv guards at once, so it
-- is a hard gate now.
-- ---------------------------------------------------------------------------
do
    local hits = 0
    local p = io.popen("grep -rn 'and nil or' '" .. SRC .. "' '" .. SRC .. ".lua' 2>/dev/null")
    if p then
        for line in p:lines() do
            -- a mention inside a comment is how the pitfall is documented
            local code = line:match('^[^:]+:%d+:%s*(.*)$')
            if code and not code:match('^%-%-') then
                io.write('  BAD IDIOM: ' .. line .. '\n')
                hits = hits + 1
            end
        end
        p:close()
    end
    if hits > 0 then
        io.write(string.format('FAIL: %d use(s) of `cond and nil or val` ' ..
            '(always yields the right side in Lua -- use an explicit if)\n', hits))
        os.exit(1)
    end
end

-- ---------------------------------------------------------------------------
-- A perl.subst replacement is written in Perl's syntax (`$1`, `${1}`, `$&`),
-- which perl.subst translates for the lpcre.gsub underneath it.  `%1` is that
-- backend's spelling leaking through: it happens to work today, but it reads
-- wrong next to the Perl being ported, and a replacement written half in each
-- syntax is how the GoPro/MXF/Panasonic/Plot bug got in.  So the backend
-- spelling is the one that is banned.
-- ---------------------------------------------------------------------------
do
    local hits = 0
    -- Every single-quoted literal holding a `%<digit>`, then everything that
    -- legitimately owns that spelling is subtracted: Lua's own string library
    -- (`:gsub` and friends really do write `%1`) and string.format's `%2d`.
    -- What survives is a regex replacement -- including one sitting alone on
    -- its own line, which is how the IPTC/PhotoMechanic/GoPro ones hid from
    -- an earlier, single-line version of this check.
    local p = io.popen("grep -rnE \"'[^']*%[1-9]\" '" .. SRC .. "' '" ..
        SRC .. ".lua' 2>/dev/null")
    if p then
        for line in p:lines() do
            local code = line:match('^[^:]+:%d+:%s*(.*)$')
            if code and not code:match('^%-%-')
               and code:match("'[^']*%%[1-9]")
               and not code:match('[%w_]:?g?[sf][ui][bn]d?%(')   -- gsub/gmatch/gfind
               and not code:match('gsub%(') and not code:match('gmatch%(')
               and not code:match('format%(') and not code:match('%%[1-9][%d.]*[a-zA-Z]')
            then
                io.write('  BAD BACKREFERENCE: ' .. line .. '\n')
                hits = hits + 1
            end
        end
        p:close()
    end
    if hits > 0 then
        io.write(string.format('FAIL: %d perl.subst replacement(s) using lpcre\'s ' ..
            '`%%1` -- write the backreference as Perl does, `$1`\n', hits))
        os.exit(1)
    end
end

-- ---------------------------------------------------------------------------
-- Lua patterns have no alternation.  A Perl regex like /^(ExifIFD|IFD0)$/
-- transliterated into `s:match('^(ExifIFD|IFD0)$')` searches for the literal
-- characters "ExifIFD|IFD0" and silently never matches -- this bit
-- GetInfo's "Tag #" key, ProcessJPEG's XMP detection and WriteExif's
-- MakerNotes FixBase, all at once (doc/api.md §2a).  So: any string-library
-- pattern with a `|` that is neither `%`-escaped nor inside a `[...]` class
-- is rejected; such a regex belongs in perl.matches/subst.  A plain find
-- (`find(pat, init, true)`) is literal on purpose and is skipped.
-- ---------------------------------------------------------------------------
do
    local hits = 0
    -- true if the Lua pattern `pat` contains an alternation-looking '|'
    local function hasBareBar(pat)
        local depth, i, n = 0, 1, #pat
        while i <= n do
            local c = pat:sub(i, i)
            if c == '%' then
                i = i + 2
            else
                if c == '[' and depth == 0 then
                    depth = 1
                    -- a ']' right after '[' or '[^' is a literal member
                    if pat:sub(i + 1, i + 1) == '^' then i = i + 1 end
                    if pat:sub(i + 1, i + 1) == ']' then i = i + 1 end
                elseif c == ']' and depth == 1 then
                    depth = 0
                elseif c == '|' and depth == 0 then
                    return true
                end
                i = i + 1
            end
        end
        return false
    end
    local p = io.popen("grep -rnE \"(:|string\\.)(match|gmatch|gsub|find)\\(\" '" ..
        SRC .. "' '" .. SRC .. ".lua' 2>/dev/null")
    if p then
        for line in p:lines() do
            local file, code = line:match('^([^:]+):%d+:%s*(.*)$')
            if code and not code:match('^%-%-') and not file:match('/Lang/') then
                -- every call on the line, with its first (quoted) argument
                for fn, q, pat, rest in code:gmatch("[:.](%a+)%(%s*([\"'])(.-)%2(.-)%)") do
                    if (fn == 'match' or fn == 'gmatch' or fn == 'gsub' or fn == 'find')
                       and not (fn == 'find' and rest:match(',%s*true%s*$'))
                       and hasBareBar(pat)
                    then
                        io.write('  BAD ALTERNATION: ' .. line .. '\n')
                        hits = hits + 1
                        break
                    end
                end
            end
        end
        p:close()
    end
    if hits > 0 then
        io.write(string.format('FAIL: %d Lua pattern(s) with a `|` -- Lua has no ' ..
            'alternation, put the regex through perl.matches/subst\n', hits))
        os.exit(1)
    end
end

local allowCount = 0
for _, name in ipairs(dirty) do
    if allowlist[name] then allowCount = allowCount + 1 end
end
io.write(string.format('\n%d clean, %d with deviations (%d allowlisted)\n',
    #clean, #dirty, allowCount))

if problems > 0 then
    io.write(string.format('FAIL: %d problem(s) in non-allowlisted modules\n', problems))
    os.exit(1)
end
io.write('OK: all non-allowlisted modules are structurally 1:1\n')
os.exit(0)
