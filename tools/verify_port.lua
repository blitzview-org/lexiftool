--------------------------------------------------------------------------------
-- File:         tools/verify_port.lua
--
-- Description:  verify structural parity of the ported modules
--------------------------------------------------------------------------------

-- Compares the Lua port against the vendored upstream Perl original:
--   1. header banners (verbatim `#` -> `--`, File: adapted to the src path,
--      plus our `Ported from:` line and a `Port notes:` section)
--   2. tag tables (Name/Description/Notes/Groups per ported tag ID)
--   3. lookup maps (value + reference cite per entry, subset-consistent)
--   4. IPTC.Main / ICC sub-tables / inline PrintConv maps
--   5. NikonCustom's custom-settings lookups and its ProcessBinaryData tag
--      tables (full two-way compare incl. Mask/Format and every PrintConv pair)
--   6. conditional lists (length and Name order of every tag ID whose entry
--      is a list, read at runtime from Perl and from the port's own modules;
--      needs LUA_PATH/LUA_CPATH, supplied by `make verify`)
--   7. conversion shapes (PrintConv/ValueConv and their inverses of every
--      ported tag: missing/undef/hash/list/code as upstream, hash keys and
--      values; read at runtime like 6., allowlist in verify_conv_allowlist.lua)
--   8. full field comparison (every key of every ported tag info and table
--      head, nested hashes/arrays included, missing/extra/differing/shape;
--      same Perl dump as 7., allowlist = work list in
--      verify_fields_allowlist.lua)
--
-- Run from anywhere: the repository root is resolved by walking up from this
-- file until `vendor/exiftool/t/ExifTool.t` is found (same as TestLib).
-- Exits 1 if any check fails.

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
    -- when lfs is present, make the path absolute so the walk survives any cwd
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
    io.stderr:write('verify_port.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local LIB = REPO .. '/vendor/exiftool/lib'
local SRC = REPO .. '/src/lexiftool'

local problems = 0
local function report(file, msg)
    problems = problems + 1
    io.write(string.format('%s: %s\n', file, msg))
end

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

local function lines(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local t = {}
    for line in f:lines() do t[#t + 1] = line end
    f:close()
    return t
end

-- Escape every pattern metacharacter in a plain string.
local function esc(s)
    return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?%%\\]', '%%%1'))
end

-- The banner separator is a '#' (or '--') line of 6+ dashes.
local function isBannerSep(line)
    if #line < 8 then return false end
    local c = line:sub(1, 1)
    if c ~= '#' and c ~= '-' then return false end
    return line:sub(2):match('^%-+$') ~= nil
end

-- Normalize a cite comment for comparison (strip leading --/# and spaces).
local function normCite(s)
    if not s then return '' end
    s = s:gsub('^%s+', ''):gsub('%s+$', '') -- outer trim
    s = s:gsub('^%-%-', '')                 -- strip the Lua '--' marker
    s = s:gsub('^%s+', ''):gsub('^#', '')   -- then a space, then the Perl '#' marker
    return s:gsub('^%s+', ''):gsub('%s+$', '')
end

------------------------------------------------------------------------------
-- 1. Header banners
------------------------------------------------------------------------------

-- Extract the upstream banner comment block (a dash-delimited `#` block that
-- carries a `File:` line). Returns its lines or nil.
local function perlBanner(path)
    local l = lines(path)
    if not l then return nil end
    for i = 1, #l do
        if isBannerSep(l[i]) then
            local j = i
            while j < #l and not isBannerSep(l[j + 1]) do j = j + 1 end
            for k = i, j do
                if l[k]:find('File:', 1, true) then
                    return l, i, j
                end
            end
        end
    end
    return nil
end

-- Path of an upstream file relative to vendor/exiftool (for Ported from:).
local function portedFrom(perlPath)
    return (perlPath:gsub('^' .. esc(REPO) .. '/vendor/exiftool/', ''))
end

-- Discover every ported module: each `src/lexiftool/**.lua` whose banner
-- carries a `Ported from:` line names its own upstream counterpart, so the
-- set of header checks grows with the port instead of being hand-maintained.
-- Returns an array of { lua = path, perl = path, base = 'X.lua' }.
local function portedModules()
    local out = {}
    local p = io.popen("find '" .. SRC .. "' -name '*.lua' | sort")
    if not p then return out end
    for luaPath in p:lines() do
        local l = lines(luaPath)
        for i = 1, math.min(#l, 40) do
            local rel = l[i]:match('^%-%- Ported from:%s+(%S+)$')
            if rel then
                out[#out + 1] = {
                    lua = luaPath,
                    perl = REPO .. '/vendor/exiftool/' .. rel,
                    base = luaPath:gsub('^' .. esc(SRC) .. '/', ''),
                }
                break
            end
        end
    end
    p:close()
    return out
end

local function checkHeader(luaPath, perlPath, luaBase)
    local lua = readall(luaPath)
    if not lua then report(luaPath, 'Header: Lua file not found'); return end
    local bl, from, to = perlBanner(perlPath)
    if not bl then
        report(luaPath, 'Header: upstream banner not found')
        return
    end
    -- convert each '#...' banner line to '--...', adapt the File: line to the
    -- src-relative module path and insert our Ported from: line after it; the
    -- Lua banner additionally carries a Port notes: section before the final
    -- separator (checked for presence only, its wording is ours)
    local exp = {}
    for i = from, to do
        local line = bl[i]
        if line:sub(1, 1) == '#' then line = '--' .. line:sub(2) end
        if line:find('File:         ', 1, true) then
            -- the upstream name may be a .pm, a .pl (Writer.pl, WriteExif.pl,
            -- Shift.pl, QuickTimeStream.pl) or the extension-less `exiftool`
            -- script, so match the whole name rather than a .pm suffix
            line = line:gsub('File:         %S+', 'File:         lexiftool/' .. luaBase)
            exp[#exp + 1] = line
            exp[#exp + 1] = '-- Ported from:  ' .. portedFrom(perlPath)        else
            exp[#exp + 1] = line
        end
    end
    -- the upstream closing separator terminates the expected block
    local closeSep = bl[to + 1]
    if closeSep:sub(1, 1) == '#' then closeSep = '--' .. closeSep:sub(2) end
    exp[#exp + 1] = closeSep
    -- locate the banner region in the Lua file (first separator pair)
    local luaLines = lines(luaPath)
    local start, finish
    for i = 1, #luaLines do
        if isBannerSep(luaLines[i]) then
            start = i
            for j = i + 1, #luaLines do
                if isBannerSep(luaLines[j]) then finish = j break end
            end
            break
        end
    end
    if not start or not finish then
        report(luaPath, 'Header: banner not found in Lua')
        return
    end
    -- head must match expected line by line (everything before the closing sep)
    for n = 1, #exp - 1 do
        local actual = luaLines[start + n - 1] or '<EOF>'
        if actual ~= exp[n] then
            report(luaPath, string.format('Header: differs at banner line %d:\n    perl: %q\n    lua : %q', n, exp[n], actual))
            return
        end
    end
    -- closing separator must match the upstream one
    if luaLines[finish] ~= exp[#exp] then
        report(luaPath, string.format('Header: closing separator differs:\n    perl: %q\n    lua : %q', exp[#exp], luaLines[finish]))
        return
    end
    -- require our Port notes: section between upstream content and closing sep
    for i = start + #exp - 1, finish - 1 do
        if luaLines[i]:find('-- Port notes:', 1, true) then
            print(string.format('  [%s] Header OK', luaBase))
            return
        end
    end
    report(luaPath, 'Header: Port notes section missing')
end

------------------------------------------------------------------------------
-- Table-body extraction
------------------------------------------------------------------------------

-- Body lines of a Lua table (`VAR = {` ... top-level `}`).
local function luaTableBody(path, var)
    local l = lines(path)
    if not l then return nil end
    local out, on = {}, false
    for i = 1, #l do
        if not on and l[i]:find(var .. '%s*=', 1) then
            on = true
        elseif on then
            if l[i]:match('^}%s*$') then break end
            out[#out + 1] = l[i]
        end
    end
    return out
end

-- Body lines of a Perl hash (`START` ... `);`), where START is the plain text
-- up to (but not including) the opening `(`.
local function perlTableBody(path, start)
    local l = lines(path)
    if not l then return nil end
    local pat = '^' .. esc(start) .. '%s*='
    local out, on = {}, false
    for i = 1, #l do
        if not on and l[i]:match(pat) then
            on = true
        elseif on then
            -- `);` closes a hash literal; Nikon's %MenuSettingsZ6III ends on
            -- `),` instead (upstream quirk -- still valid Perl, the comma just
            -- chains the next statement), so both spellings terminate here
            if l[i]:match('^%)[;,]') then break end
            out[#out + 1] = l[i]
        end
    end
    return out
end

-- (key, value, cite) from a Lua table entry line. Only top-level entries
-- (indent 2-5) are accepted, so nested sub-tables like `BITMASK = { ... }`
-- are ignored -- the same filter perlEntry below applies to the Perl side.
local function luaEntry(line)
    local lead = line:match('^( *)')
    local n = lead and #lead or 0
    if n < 2 or n > 5 then return nil end
    local key = line:match('^%s*%[([^%]]+)%]%s*=')
    if not key then
        key = line:match('^%s*([%w_]+)%s*=')
    end
    if not key then return nil end
    key = key:gsub("^['\"]", ''):gsub("['\"]$", '')
    local val = line:match("=%s*'([^']*)'")
    if not val then
        val = line:match('=%s*(%d+)')
        if not val then val = line:match('=%s*(0x[0-9a-fA-F]+)') end
    end
    local cmt = line:match("',%s*(%-%-.*)$") or line:match('%d+,%s*(%-%-.*)$') or ''
    return key, val, normCite(cmt)
end

-- (key, value, cite) from a Perl table entry line. Only top-level entries
-- (indent 2-4) are accepted, so nested sub-tables like `BITMASK => { ... }`
-- are ignored.
local function perlEntry(line)
    local lead = line:match('^( *)')
    local n = lead and #lead or 0
    if n < 2 or n > 5 then return nil end -- only top-level entries (indent 2-5)
    -- a quoted key may contain spaces (e.g. 'HP  ', 'mid ')
    local key = line:match("^%s*'([^']*)'%s*=>")
    if not key then
        key = line:match('^%s*([^%s=]+)%s*=>')
        if key then key = key:gsub("^['\"]", ''):gsub("['\"]$", '') end
    end
    if not key then
        -- Perl's comma is a `=>` (Sigma's `0x10, 'Sigma 50mm F2.8 EX DG MACRO'`)
        local k2, v2 = line:match("^%s*(0x[0-9a-fA-F]+),%s*'([^']*)'")
        if k2 then
            local c2 = line:match('#(.*)$')
            return k2, v2, normCite(c2 and ('#' .. c2) or nil)
        end
        return nil
    end
    -- a value may be a scalar ref (`=> \\ 'text'`, e.g. %metabonesID)
    local val = line:match("=>%s*\\?%s*'([^']*)'")
    if not val then
        val = line:match('=>%s*(%d+)')
        if not val then val = line:match('=>%s*(0x[0-9a-fA-F]+)') end
    end
    local cmt = line:match("',%s*(#.*)$") or line:match('%d+,%s*(#.*)$') or ''
    return key, val, normCite(cmt)
end

------------------------------------------------------------------------------
-- 2. Tag tables
------------------------------------------------------------------------------

-- Extract a single-quoted field value from a block of lines.
local function fieldValue(block, name, perl)
    local pat = perl and (esc(name) .. '%s*=>%s*\'([^\']*)\'') or (esc(name) .. '%s*=%s*\'([^\']*)\'')
    for i = 1, #block do
        local m = block[i]:match(pat)
        if m then return m end
    end
    return nil
end

-- Extract the Groups table (family -> name) from a block of lines.
local function groupsOf(block, perl)
    local startPat = perl and ('Groups%s*=>%s*{') or ('Groups%s*=%s*{')
    for i = 1, #block do
        if block[i]:match(startPat) then
            local g = {}
            local sep = perl and '=>' or '='
            for j = i, #block do
                if block[j]:find('}', 1, true) then break end
                local fam, name = block[j]:match('(%d+)%s*' .. sep .. "%s*'([^']*)'")
                if fam then g[tonumber(fam)] = name end
            end
            return g
        end
    end
    return nil
end

-- Block of one tagged entry, given the plain key. Lua keys may be bare or
-- quoted/bracketed (`EncodingProcess`, `['cprt']`); Perl conditional lists
-- open with `[`.
local function entryBlock(linesArr, key, lua)
    local openP
    if lua then
        -- a `[N] = helperName { ... }` entry (conventions.md §2: a spread
        -- defaults hash becomes a helper call) opens the same block
        openP = '^%s*%[?[\'"]?' .. key .. '[\'"]?%]?%s*=%s*[%w_.]*%s*[%[{]'
    else
        openP = '^%s*[\'"]?' .. key .. '[\'"]?%s*=>%s*[%[{]'
    end
    -- A Perl hash may list the same key twice (GoPro::GPMF's MUID, ICC's
    -- 0x27000001); the LATER definition is the one that survives, so scan
    -- the top-level (4-space) entries from the back.  Anything else keeps
    -- the first match, so a nested PrintConv key cannot displace it.
    local topP
    if lua then
        topP = '^    %[?[\'"]?' .. key .. '[\'"]?%]?%s*=%s*[%w_.]*%s*[%[{]'
    else
        topP = '^    [\'"]?' .. key .. '[\'"]?%s*=>%s*[%[{]'
    end
    local order = { }
    for i = #linesArr, 1, -1 do
        if linesArr[i]:match(topP) then order[#order + 1] = i end
    end
    if #order == 0 then
        for i = 1, #linesArr do order[#order + 1] = i end
    end
    for _, i in ipairs(order) do
        if linesArr[i]:match(openP) then
            local blk = { linesArr[i] }
            local openC, closeC
            if linesArr[i]:find('[', 1, true) and linesArr[i]:match('=>%s*%[') then
                openC, closeC = '[', ']'
            else
                openC, closeC = '{', '}'
            end
            local depth = 0
            for c in linesArr[i]:gmatch('.') do
                if c == openC then depth = depth + 1 elseif c == closeC then depth = depth - 1 end
            end
            local j = i + 1
            while depth > 0 and j <= #linesArr do
                blk[#blk + 1] = linesArr[j]
                for c in linesArr[j]:gmatch('.') do
                    if c == openC then depth = depth + 1 elseif c == closeC then depth = depth - 1 end
                end
                j = j + 1
            end
            return blk
        end
    end
    return nil
end

local function checkTagTable(name, luapath, luavar, perlpath, perlStart)
    local lb = luaTableBody(luapath, luavar)
    local pb = perlTableBody(perlpath, perlStart)
    if not lb or not pb then
        report(name, 'Tag table body not found')
        return
    end
    local count = 0
    for i = 1, #lb do
        local lead = lb[i]:match('^(%s*)')
        if #(lead or '') == 4 then -- only top-level entries (4-space indent)
        local key = lb[i]:match('^%s*%[([^%]]+)%]%s*=%s*[%w_.]*%s*{')
        local bareKey, scalarVal
        local META = { PROCESS_PROC=1, WRITE_PROC=1, CHECK_PROC=1, GROUPS=1,
            VARS=1, NOTES=1, FORMAT=1, WRITABLE=1, WRITE_GROUP=1, SET_GROUP1=1,
            TAG_PREFIX=1, FIRST_ENTRY=1, PRIORITY=1, PRINT_CONV=1, DATAMEMBER=1,
            _ordered_keys_=1, TABLE_NAME=1, SHORT_NAME=1, INIT_TABLE=1,
            TABLE_DESC=1 }
        if not key then
            key, bareKey = lb[i]:match('^%s*([%w_]+)%s*=%s*[%w_.]*%s*{')
        end
        if not key then
            local b, sv = lb[i]:match("^%s*%[?([%w_]+)%]?%s*=%s*'([^']*)'")
            if b then key, scalarVal = b, sv end
        end
        if key then
            key = key:gsub("^['\"]", ''):gsub("['\"]$", '')
            if META[key] then goto nextline end -- skip table meta keys
            -- a computed key: upstream spells it `$hash{member}`, the port
            -- `[hash.member]` (PNG's %stdCase for the eXIf/zxIf chunks)
            local perlKey = key:gsub('^([%a_][%w_]*)%.([%a_][%w_]*)$', '$%1{%2}')
            count = count + 1
            if scalarVal then
                -- scalar entry: compare value with the upstream KEY => 'value'
                -- (use a lenient match that accepts any indentation, since
                --  some upstream tables nest scalar members under a
                --  documentation sub-directory, e.g. Jpeg2000.pm's jp2h/
                --  jpch sub-boxes are still flat keys of %Main)
                -- a top-level (4-space) entry wins over the lenient search, so
                -- a nested PrintConv key that happens to have the same number
                -- (e.g. Samsung::PictureWizard's `1 => 'Vivid'` inside tag 0's
                -- PrintConv vs the top-level `1 => 'PictureWizardColor'`)
                -- cannot be mistaken for the entry being checked
                local pv = nil
                for _, pl in ipairs(pb) do
                    local pk, pval = pl:match("^    '?([%w%-]+)'?%s*=>%s*'([^']*)'")
                    if pk == perlKey then pv = pval break end
                end
                if pv == nil then
                    for _, pl in ipairs(pb) do
                        local pk, pval = pl:match("^%s*'?([%w%-]+)'?%s*=>%s*'([^']*)'")
                        if pk == perlKey then pv = pval break end
                    end
                end
                if pv == nil then
                    report(name, string.format('Tag %s: upstream entry not found', key))
                elseif pv ~= scalarVal then
                    report(name, string.format('Tag %s: perl=%q lua=%q', key, pv, scalarVal))
                end
            else
            local lblock = entryBlock(lb, key:gsub('([^%w_])', '%%%1'), true)
            -- (a dotted key may also be a plain quoted string upstream,
            --  e.g. QuickTime::VideoKeys 'camera.framereadouttimeinmicroseconds')
            local pblock = entryBlock(pb, esc(perlKey), false) or entryBlock(pb, esc(key), false)
            if not pblock then
                report(name, string.format('Tag %s: upstream entry not found', key))
            else
                for _, f in ipairs({ 'Name', 'Description', 'Notes' }) do
                    local pv = fieldValue(pblock, f, true)
                    local lv = fieldValue(lblock, f, false)
                    if pv ~= nil and lv ~= nil and pv ~= lv then
                        report(name, string.format('Tag %s: %s: perl=%q lua=%q', key, f, pv, lv))
                    end
                end
                local pg = groupsOf(pblock, true)
                local lg = groupsOf(lblock, false)
                if pg then
                    if not lg then
                        report(name, string.format('Tag %s: Groups missing in Lua', key))
                    else
                        for fam, gname in pairs(pg) do
                            if lg[fam] ~= gname then
                                report(name, string.format('Tag %s: Groups[%d]: perl=%q lua=%q', key, fam, gname, lg[fam]))
                            end
                        end
                        end
                    end
                end
            end
        end
        ::nextline:: ; -- (top-level indent guard / meta-key skip)
        end
    end
    print(string.format('  [%s] %d tags checked', name, count))
end

------------------------------------------------------------------------------
-- 3. Lookup maps (subset-consistent)
------------------------------------------------------------------------------

local function checkMap(name, luapath, luavar, perlpath, perlStart)
    local lb = luaTableBody(luapath, luavar)
    local pb = perlTableBody(perlpath, perlStart)
    local perls = {}
    for _, line in ipairs(pb or {}) do
        local k, v, c = perlEntry(line)
        if k then perls[k] = { v, c } end
    end
    local count = 0
    -- luacheck's 160-column limit forces long upstream cite comments onto their
    -- own line(s) above the entry (conventions.md §10).  Collect those, so a
    -- wrapped cite still compares equal to the upstream trailing comment.
    local carried = {}
    for _, line in ipairs(lb or {}) do
        local k, v, c = luaEntry(line)
        if k then
            local wrapped = #carried > 0 and normCite(table.concat(carried, ' ')) or nil
            local wrappedLast = #carried > 0 and normCite(carried[#carried]) or nil
            carried = {}
            count = count + 1
            if not perls[k] then
                report(name, string.format('EXTRA (not in upstream): %s = %s', k, v or '?'))
            elseif perls[k][1] == v and c == '' and
                   (wrapped == perls[k][2] or wrappedLast == perls[k][2]) then
                -- cite carried on the preceding comment line(s): fine
            elseif perls[k][1] ~= v or perls[k][2] ~= c then
                report(name, string.format('DIFF %s: perl={%s,%q} lua={%s,%q}', k, perls[k][1], perls[k][2], v, c))
            end
        else
            local only = line:match('^%s*(%-%-.*)$')
            if only then carried[#carried + 1] = only else carried = {} end
        end
    end
    print(string.format('  [%s] %d entries OK (subset-consistent)', name, count))
end

------------------------------------------------------------------------------
-- 3a. %fileTypeLookup-style maps: values are either an alias (a plain quoted
-- string) or an arrayref of [Type(s), Desc] (Perl `[...]` / Lua `{...}`,
-- Type(s) itself a single string or a nested list). Full two-way compare
-- (extra AND missing keys), unlike checkMap's Lua-side-only subset check.
------------------------------------------------------------------------------

-- All quoted string literals in a fragment, in order, dequoting \x escapes.
local function extractQuoted(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "'" or c == '"' then
            local q, j, buf = c, i + 1, {}
            while j <= n do
                local cj = s:sub(j, j)
                if cj == '\\' then
                    buf[#buf + 1] = s:sub(j + 1, j + 1)
                    j = j + 2
                elseif cj == q then
                    j = j + 1
                    break
                else
                    buf[#buf + 1] = cj
                    j = j + 1
                end
            end
            out[#out + 1] = table.concat(buf)
            i = j
        else
            i = i + 1
        end
    end
    return out
end

-- (key, {alias=...} or {types={...}, desc=...}) from a fileTypeLookup-style
-- table entry line, Perl (`KEY => value,`) or Lua (`KEY = value,`).
local function ftlEntry(line, isPerl)
    local code = isPerl and line:gsub('%s*#.*$', '') or line:gsub('%s*%-%-.*$', '')
    if not code:match('%S') then return nil end
    local keyPart, rest = code:match(isPerl and "^%s*(.-)%s*=>%s*(.-)%s*$" or '^%s*(.-)%s*=%s*(.-)%s*$')
    if not keyPart or rest == '' then return nil end
    local key = keyPart:gsub('^%[', ''):gsub('%]$', ''):gsub("^'", ''):gsub("'$", '')
    rest = rest:gsub(',%s*$', '')
    if rest == '' then return nil end
    if rest:sub(1, 1) == '[' or rest:sub(1, 1) == '{' then
        local quoted = extractQuoted(rest)
        if #quoted == 0 then return nil end
        local desc = quoted[#quoted]
        local types = {}
        for i = 1, #quoted - 1 do types[i] = quoted[i] end
        return key, { types = types, desc = desc }
    end
    local alias = rest:match("^'([^']*)'$") or rest:match('^"([^"]*)"$')
    if not alias then return nil end
    return key, { alias = alias }
end

local function checkFileTypeLookup(name, luapath, luavar, perlpath, perlStart)
    local lb = luaTableBody(luapath, luavar)
    local pb = perlTableBody(perlpath, perlStart)
    local perls, porder = {}, {}
    for _, line in ipairs(pb or {}) do
        local k, v = ftlEntry(line, true)
        if k then perls[k] = v; porder[#porder + 1] = k end
    end
    local seen, count = {}, 0
    for _, line in ipairs(lb or {}) do
        local k, v = ftlEntry(line, false)
        if k then
            count = count + 1
            seen[k] = true
            local p = perls[k]
            if not p then
                report(name, string.format('EXTRA (not in upstream): %s', k))
            elseif v.alias or p.alias then
                if v.alias ~= p.alias then
                    report(name, string.format('DIFF %s: perl alias=%s lua alias=%s', k, tostring(p.alias), tostring(v.alias)))
                end
            else
                if #p.types ~= #v.types then
                    report(name, string.format('DIFF %s: type count perl=%d lua=%d', k, #p.types, #v.types))
                else
                    for i = 1, #p.types do
                        if p.types[i] ~= v.types[i] then
                            report(name, string.format('DIFF %s: Type[%d] perl=%q lua=%q', k, i, p.types[i], v.types[i]))
                        end
                    end
                end
                if p.desc ~= v.desc then
                    report(name, string.format('DIFF %s: Desc perl=%q lua=%q', k, p.desc, v.desc))
                end
            end
        end
    end
    for _, k in ipairs(porder) do
        if not seen[k] then
            report(name, string.format('MISSING (present upstream, not ported): %s', k))
        end
    end
    print(string.format('  [%s] %d entries OK (full comparison)', name, count))
end

------------------------------------------------------------------------------
-- 3b. Nested PrintConv maps (indent 8-12), e.g. the ICC `tech` table
------------------------------------------------------------------------------

-- Parse entries in a deep (indent 8-12) map block.
local function deepEntry(line, lua)
    local key, val, cmt
    if lua then
        key = line:match('^%s*%[([^%]]+)%]%s*=%s*\'([^\']*)\'')
        if key then val, cmt = key:match("^%s*%[([^%]]+)%]%s*=%s*'([^']*)',?%s*(%-%-.*)$") end
        key = key
        if not val then
            key, val = line:match("^%s*%[([^%]]+)%]%s*=%s*'([^']*)'")
            cmt = line:match("',?%s*(%-%-.*)$")
        end
        if key then key = key:gsub("^['\"]", ''):gsub("['\"]$", '') end
    else
        key, val = line:match("^%s*'([^']*)'%s*=>%s*'([^']*)'")
        if not key then
            key, val = line:match("^%s*(%w+)%s*=>%s*'([^']*)'")
        end
        cmt = line:match("',?%s*(#.*)$")
    end
    if not key then return nil end
    return key, val, normCite(cmt or '')
end

-- Compare the PrintConv of one nested tag entry (`VAR[key]` in Lua, `KEY` in
-- the Perl table) between the two files.
local function checkNestedMap(name, luapath, luaVar, luaKey, perlpath, perlStart, perlKey)
    local lb = luaTableBody(luapath, luaVar)
    local pb = perlTableBody(perlpath, perlStart)
    local lblock = entryBlock(lb, luaKey, true)
    local pblock = entryBlock(pb, perlKey, false)
    if not lblock or not pblock then
        report(name, 'tech entry not found')
        return
    end
    local function grab(block, perl)
        local out, on = {}, false
        local startPat = perl and 'PrintConv%s*=>%s*{' or 'PrintConv%s*=%s*{'
        local depth = 0
        for i = 1, #block do
            if not on and block[i]:match(startPat) then
                on = true; depth = 0
                for c in block[i]:gmatch('.') do
                    if c == '{' then depth = depth + 1 elseif c == '}' then depth = depth - 1 end
                end
            elseif on then
                for c in block[i]:gmatch('.') do
                    if c == '{' then depth = depth + 1 elseif c == '}' then depth = depth - 1 end
                end
                if depth <= 0 then break end
                out[#out + 1] = block[i]
            end
        end
        return out
    end
    local lp = grab(lblock, false)
    local pp = grab(pblock, true)
    local perls = {}
    for _, line in ipairs(pp) do
        local k, v, c = deepEntry(line, false)
        if k then perls[k] = { v, c } end
    end
    local count = 0
    for _, line in ipairs(lp) do
        local k, v, c = deepEntry(line, true)
        if k then
            count = count + 1
            if not perls[k] then
                report(name, string.format('EXTRA: %s = %s', k, v or '?'))
            elseif perls[k][1] ~= v or perls[k][2] ~= c then
                report(name, string.format('DIFF %s: perl={%s,%q} lua={%s,%q}', k, perls[k][1], perls[k][2], v, c))
            end
        end
    end
    print(string.format('  [%s] %d entries OK (PrintConv)', name, count))
end

------------------------------------------------------------------------------
-- 3c. Custom-settings lookups and binary-data tag tables
------------------------------------------------------------------------------
-- checkMap/checkTagTable are deliberately shallow: checkMap only looks at
-- top-level (indent 2-5) entries, and checkTagTable only compares Name,
-- Description, Notes and Groups. NikonCustom.pm needs more than that -- its
-- lookups are indented 8 spaces inside a `PrintConv => { ... }`, one of them
-- is spread into two others, and its tag entries carry their whole meaning in
-- `Mask`, `Format` and an inline `PrintConv` hash. The two checkers below
-- therefore do a full two-way compare: every key, every value, every cite
-- comment, and for tag entries additionally Mask/Format/Notes/
-- PrintConvColumns plus the presence of each of the four conversions.

-- Split a source line into its code part and its trailing comment, ignoring
-- comment markers that appear inside a single-quoted string ('90%', 'A#B').
local function splitComment(line, isLua)
    local i, n, inStr = 1, #line, false
    while i <= n do
        local c = line:sub(i, i)
        if c == "'" then
            inStr = not inStr
        elseif not inStr then
            if isLua and c == '-' and line:sub(i + 1, i + 1) == '-' then
                return line:sub(1, i - 1), line:sub(i)
            elseif not isLua and c == '#' then
                return line:sub(1, i - 1), line:sub(i)
            end
        end
        i = i + 1
    end
    return line, ''
end

-- (key, value) of a `KEY => value` / `[KEY] = value` pair, value dequoted.
local function pairOf(code, isLua)
    local key, rest
    if isLua then
        key, rest = code:match('^%s*%[([^%]]+)%]%s*=%s*(.*)$')
    else
        key, rest = code:match('^%s*(%-?[%w_%.]+)%s*=>%s*(.*)$')
        if not key then key, rest = code:match("^%s*'([^']*)'%s*=>%s*(.*)$") end
    end
    if not key then return nil end
    key = key:gsub("^['\"]", ''):gsub("['\"]$", '')
    rest = rest:gsub('%s*,%s*$', ''):gsub('%s+$', '')
    local q = rest:match("^'(.*)'$")
    return key, q or rest
end

-- Body lines of a named block: a Lua `local X = {` / `function X(t)` or a
-- Perl `my %X = (` / `%Image::ExifTool::...::X = (`, up to its closing line.
-- A one-line Perl hash (`my %offOn = ( 0 => 'Off', 1 => 'On' );`) is returned
-- as its own single line, with the braces stripped.
local function blockBody(path, anchor)
    local l = lines(path)
    if not l then return nil end
    local openP = '^' .. esc(anchor)
    for i = 1, #l do
        if l[i]:match(openP) then
            local head = l[i]:match('^.-[%({](.*)$')
            -- a one-line hash, as opposed to a `function X(t)` header: split
            -- it into one pair per line, so the parsers below see it like any
            -- other block
            if head and head:match('[%)}];?%s*$') and (head:match('=>') or head:match('%]%s*=')) then
                local body, buf, inStr = {}, {}, false
                for c in head:gsub('[%)}];?%s*$', ''):gmatch('.') do
                    if c == "'" then inStr = not inStr end
                    if c == ',' and not inStr then
                        body[#body + 1] = table.concat(buf)
                        buf = {}
                    else
                        buf[#buf + 1] = c
                    end
                end
                body[#body + 1] = table.concat(buf)
                return body
            end
            local out = {}
            for j = i + 1, #l do
                if l[j]:match('^%);') or l[j]:match('^}%s*$') or l[j]:match('^end%s*$') then break end
                out[#out + 1] = l[j]
            end
            return out
        end
    end
    return nil
end

-- All flat `key => value` pairs of a block, at any indentation, plus the
-- block's SeparateTable and the name of any hash spread into it.
local function flatPairs(body, isLua)
    local map, order, sep, spread = {}, {}, nil, nil
    for _, line in ipairs(body) do
        local code, cmt = splitComment(line, isLua)
        local s = isLua and code:match("SeparateTable%s*=%s*'([^']*)'")
            or code:match("SeparateTable%s*=>%s*'([^']*)'")
        if s then
            sep = s
        else
            local sp = isLua and code:match('^%s*[%w_%.]*%s*=%s*with([%w_]+){%s*$')
                or code:match('^%s*%%([%w_]+),%s*$')
            if sp then
                spread = isLua and (sp:sub(1, 1):lower() .. sp:sub(2)) or sp
            else
                local k, v = pairOf(code, isLua)
                if k and v ~= '' and not v:match('^[{(]') then
                    if map[k] == nil then order[#order + 1] = k end
                    map[k] = { v, normCite(cmt) }
                end
            end
        end
    end
    return map, order, sep, spread
end

-- Compare one lookup hash (`name`) between the port and the upstream file.
-- `luaAnchor`/`perlAnchor` are the literal starts of the two declarations.
local function checkCustomMap(name, luapath, luaAnchor, perlpath, perlAnchor, luaSpreads, perlSpreads)
    local lb = blockBody(luapath, luaAnchor)
    local pb = blockBody(perlpath, perlAnchor)
    if not lb or not pb then
        report(name, 'Lookup block not found')
        return
    end
    local lmap, lorder, lsep, lspread = flatPairs(lb, true)
    local pmap, porder, psep, pspread = flatPairs(pb, false)
    if lsep ~= psep then
        report(name, string.format('SeparateTable: perl=%s lua=%s', tostring(psep), tostring(lsep)))
    end
    if lspread ~= pspread then
        report(name, string.format('Spread: perl=%s lua=%s', tostring(pspread), tostring(lspread)))
    elseif lspread then
        -- fold the spread hash in on both sides, so the totals are comparable
        for k, v in pairs(luaSpreads[lspread] or {}) do if lmap[k] == nil then lmap[k] = v; lorder[#lorder + 1] = k end end
        for k, v in pairs(perlSpreads[pspread] or {}) do if pmap[k] == nil then pmap[k] = v; porder[#porder + 1] = k end end
    end
    if #lorder ~= #porder then
        report(name, string.format('entry count: perl=%d lua=%d', #porder, #lorder))
    end
    for _, k in ipairs(lorder) do
        if not pmap[k] then
            report(name, string.format('EXTRA (not in upstream): %s', k))
        elseif pmap[k][1] ~= lmap[k][1] or pmap[k][2] ~= lmap[k][2] then
            report(name, string.format('DIFF %s: perl={%s,%q} lua={%s,%q}', k,
                pmap[k][1], pmap[k][2], lmap[k][1], lmap[k][2]))
        end
    end
    for _, k in ipairs(porder) do
        if not lmap[k] then report(name, string.format('MISSING (not ported): %s', k)) end
    end
    print(string.format('  [%s] %d entries OK (full comparison)', name, #lorder))
    return lmap, pmap
end

-- Bracket bookkeeping ignores anything inside a single-quoted string, so a
-- pattern like [[D3[SX]?\b]] or a Perl /D3[SX]?\b/ cannot unbalance it.
local function stripStrings(code)
    return (code:gsub("'[^']*'", "''"))
end

-- Parse the field lines of one tag info (the lines of a `{ ... }` block).
local function parseTagInfo(ls, isLua)
    local e = { fields = {}, pc = nil, pcMap = nil, convs = {} }
    local depth, inPC, pcBase = 0, false, 0
    local skipFnEnd -- (indent of an open multi-line function in a PrintConv map)
    for _, line in ipairs(ls) do
        local code, ccmt = splitComment(line, isLua)
        if inPC and skipFnEnd then
            -- inside a multi-line `OTHER = function(...)` body: its statements
            -- (`val = subst(...)`) are not PrintConv entries
            if code:match('^' .. skipFnEnd .. 'end[,%s]*$') then skipFnEnd = nil end
        elseif inPC then
            local k, v = pairOf(code, isLua)
            if isLua and code:match('=%s*function%s*%b()%s*$') then
                skipFnEnd = code:match('^(%s*)')
            end
            if not k and isLua then
                -- a bare identifier key inside a PrintConv map (`BITMASK = {`),
                -- which the Perl side reads through its own `KEY => ...` branch
                k, v = code:match('^%s*([%a_][%w_]*)%s*=%s*(.*)$')
                if v then v = v:gsub('%s*,%s*$', ''):gsub('%s+$', '') end
            end
            if k then e.pcMap[k] = { v, normCite(ccmt) }; e.pcOrder[#e.pcOrder + 1] = k end
            for c in code:gmatch('[{}]') do depth = depth + (c == '{' and 1 or -1) end
            if depth <= pcBase then inPC = false end
        else
            for _, f in ipairs({ 'Name', 'Format', 'Notes', 'SeparateTable' }) do
                local v = isLua and code:match(f .. "%s*=%s*'([^']*)'") or code:match(f .. "%s*=>%s*'([^']*)'")
                if v then e.fields[f] = v end
            end
            for _, f in ipairs({ 'Mask', 'PrintConvColumns' }) do
                local v = isLua and code:match(f .. '%s*=%s*([%w]+)') or code:match(f .. '%s*=>%s*([%w]+)')
                if v then e.fields[f] = v end
            end
            for _, f in ipairs({ 'ValueConv', 'ValueConvInv', 'PrintConvInv' }) do
                if code:match('%f[%w]' .. f .. '%s*=[>%s]') then e.convs[f] = true end
            end
            local pcRest = isLua and code:match('^%s*PrintConv%s*=%s*(.*)$') or code:match('^%s*PrintConv%s*=>%s*(.*)$')
            if pcRest then
                e.convs.PrintConv = true
                -- (a Perl `%hash` spread inside the map is a `spread(hash) {`
                --  prefix on the Lua side, see Sony.lua)
                if pcRest:match('^{') or (isLua and pcRest:match('^spread%([%w_.]+%)%s*{')) then
                    e.pc, e.pcMap, e.pcOrder = 'map', {}, {}
                    inPC, pcBase = true, depth
                elseif isLua then
                    -- (a module-field lookup, `Sony.sonyLensTypes2`, is the
                    --  package hash `\%sonyLensTypes2` upstream)
                    local ref = pcRest:match('^([%w_.]+),?%s*$')
                    if ref then ref = ref:match('([%w_]+)$') end
                    e.pc = ref and ('ref:' .. ref) or 'code'
                else
                    -- (`\%name ,` and the package-qualified
                    --  `\%Image::ExifTool::Nikon::name` are references too)
                    local ref = pcRest:match('^\\%%([%w_:]+)%s*,?%s*$')
                    if ref then ref = ref:match('([%w_]+)$') end
                    e.pc = ref and ('ref:' .. ref) or 'code'
                end
            end
            for c in code:gmatch('[{}]') do depth = depth + (c == '{' and 1 or -1) end
        end
    end
    -- A Perl hash literal that repeats a key (Nikon's WBBracketingSteps lists
    -- 0x22..0x28 twice) holds it only once, at the last occurrence's value --
    -- the earlier line is dead. The port carries the dead line commented out,
    -- so drop the earlier occurrences here too and compare the live sets.
    if e.pcOrder then
        local seen, out = {}, {}
        for n = #e.pcOrder, 1, -1 do
            local k = e.pcOrder[n]
            if not seen[k] then seen[k] = true; table.insert(out, 1, k) end
        end
        e.pcOrder = out
    end
    return e
end

-- One tag entry of a binary-data table: its fields, its cite comment and its
-- PrintConv (a reference by name, an inline map, or ported code).
-- Perl's list of conditional tag infos (`N => [ {...}, {...} ]`, or its packed
-- `N => [{...},{...}]` spelling; Lua: `[N] = { {...}, {...} }`) becomes the
-- empty entry `N` plus one sub-entry per list member, keyed `N[1]`, `N[2]`, ...
local function binEntries(body, isLua)
    local out, order = {}, {}
    -- The Lua side may prefix the tag info with a helper call where the Perl
    -- spreads a hash into the entry (`103 => { Name => 'Func1Button',
    -- %buttonsZ6III }` <-> `[103] = buttonsZ6III { Name = 'Func1Button' }`).
    -- the key is decimal (`586.1`) or hexadecimal (`0x2b5`) -- both start with
    -- a digit, which is what keeps an all-caps table field (`GROUPS => {`)
    -- out of the match
    local openP = isLua and '^    %[(%-?%d[%w%.]*)%]%s*=%s*([%w_%.]*%s*{.*)$' or '^    (%-?%d[%w%.]*)%s*=>%s*([{%[].*)$'
    local i = 1
    while i <= #body do
        local key, rest = body[i]:match(openP)
        if key then
            local _, cmt = splitComment(body[i], isLua)
            -- A cite comment longer than the 160 column lint limit all by
            -- itself (NikonCustom's CmdDialsReverseRotExposureComp) is
            -- continued verbatim on the next line, at the entry's own indent
            -- (4 spaces + `-- `). Field comments sit at the field indent and
            -- commented-out entries carry no space after the `--`, so neither
            -- is picked up here.
            -- (only after a line that ran up to the limit: a full-line
            --  comment after a short entry is upstream's own, e.g. Canon's
            --  `# 0x1b, 0x1c, 0x1d - same as FileInfo 0x10 - PH`)
            if isLua and cmt ~= '' and #body[i] > 120 then
                local cont = body[i + 1] and body[i + 1]:match('^    %-%- (.*)$')
                if cont then cmt = cmt .. ' ' .. cont end
            end
            local restCode = (splitComment(rest, isLua))
            -- a list of conditional tag infos, or a single tag info?
            local isList
            if isLua then
                -- (comment-only lines between `[N] = {` and the first member
                --  carry upstream's continued cite comment)
                local n1 = i + 1
                while body[n1] and (splitComment(body[n1], true)):match('^%s*$') do n1 = n1 + 1 end
                local nxt = body[n1] and (splitComment(body[n1], true))
                -- (a list member may carry a spread helper, `afStatusInfo {`)
                isList = restCode:match('^{%s*[%w_]*%s*{') ~= nil or (nxt and nxt:match('^%s*[%w_]*%s*{%s*$')) ~= nil
            else
                isList = restCode:match('^%[') ~= nil
            end
            -- walk the entry bracket by bracket, cutting it into list members
            -- at every depth 1 <-> 2 transition
            local groups, cites, cur = {}, {}, nil
            local flat, depth, j = {}, 0, i
            local line, code = body[i], restCode
            while true do
                local d, sawStart, sawEnd = depth, false, false
                for c in stripStrings(code):gmatch('[%[%]{}]') do
                    local nd = d + ((c == '{' or c == '[') and 1 or -1)
                    if d <= 1 and nd >= 2 then
                        sawStart = true
                    elseif d >= 2 and nd <= 1 then
                        sawEnd = true
                    end
                    d = nd
                end
                if isList then
                    if sawEnd then
                        cur = cur or {}
                        cur[#cur + 1] = line
                        groups[#groups + 1] = cur
                        cur = nil
                    end
                    if sawStart then
                        cur = { line }
                        local _, c2 = splitComment(line, isLua)
                        cites[#groups + 1] = normCite(c2)
                    elseif not sawEnd and cur then
                        cur[#cur + 1] = line
                    end
                else
                    flat[#flat + 1] = line
                end
                depth = d
                j = j + 1
                if depth <= 0 or j > #body then break end
                line = body[j]
                code = (splitComment(line, isLua))
            end
            local function add(k, e)
                e.key = k
                -- A repeated key is a Perl hash overwrite: the earlier entry is
                -- dead code (NikonCustom's SettingsD5100 23.1 is one), and the
                -- port carries it commented out. Drop the dead occurrence here
                -- so both sides list the key once, at its final position.
                if out[k] then
                    for n = 1, #order do
                        if order[n] == k then
                            table.remove(order, n)
                            break
                        end
                    end
                end
                out[k] = e
                order[#order + 1] = k
            end
            if isList then
                add(key, { cite = normCite(cmt), fields = {}, convs = {} })
                for n, g in ipairs(groups) do
                    local e = parseTagInfo(g, isLua)
                    e.cite = cites[n] or ''
                    add(string.format('%s[%d]', key, n), e)
                end
            else
                local e = parseTagInfo(flat, isLua)
                e.cite = normCite(cmt)
                add(key, e)
            end
            i = j
        else
            i = i + 1
        end
    end
    return out, order
end

-- Compare a whole ProcessBinaryData tag table, entry for entry.
local function checkBinaryTagTable(name, luapath, luavar, perlpath, perlStart)
    local lb = luaTableBody(luapath, luavar)
    local pb = perlTableBody(perlpath, perlStart)
    if not lb or not pb then
        report(name, 'Tag table body not found')
        return
    end
    local lmap, lorder = binEntries(lb, true)
    local pmap, porder = binEntries(pb, false)
    if #lorder ~= #porder then
        report(name, string.format('entry count: perl=%d lua=%d', #porder, #lorder))
    end
    local pcPairs = 0
    for n = 1, math.max(#lorder, #porder) do
        if lorder[n] ~= porder[n] then
            report(name, string.format('order at position %d: perl=%s lua=%s',
                n, tostring(porder[n]), tostring(lorder[n])))
            break
        end
    end
    for _, key in ipairs(porder) do
        local p, l = pmap[key], lmap[key]
        if not l then
            report(name, string.format('Tag %s: not ported', key))
        else
            if p.cite ~= l.cite then
                report(name, string.format('Tag %s: comment: perl=%q lua=%q', key, p.cite, l.cite))
            end
            for _, f in ipairs({ 'Name', 'Format', 'Notes', 'SeparateTable', 'Mask', 'PrintConvColumns' }) do
                if p.fields[f] ~= l.fields[f] then
                    report(name, string.format('Tag %s: %s: perl=%s lua=%s', key, f,
                        tostring(p.fields[f]), tostring(l.fields[f])))
                end
            end
            for _, f in ipairs({ 'ValueConv', 'ValueConvInv', 'PrintConv', 'PrintConvInv' }) do
                if (p.convs[f] or false) ~= (l.convs[f] or false) then
                    report(name, string.format('Tag %s: %s: perl=%s lua=%s', key, f,
                        tostring(p.convs[f] or false), tostring(l.convs[f] or false)))
                end
            end
            if p.pc ~= l.pc then
                report(name, string.format('Tag %s: PrintConv kind: perl=%s lua=%s', key, tostring(p.pc), tostring(l.pc)))
            elseif p.pc == 'map' then
                if #p.pcOrder ~= #l.pcOrder then
                    report(name, string.format('Tag %s: PrintConv entries: perl=%d lua=%d', key, #p.pcOrder, #l.pcOrder))
                end
                for _, k in ipairs(p.pcOrder) do
                    pcPairs = pcPairs + 1
                    local lv = l.pcMap[k]
                    -- an OTHER code ref (`sub { shift }`) is ported code, and a
                    -- spread BITMASK (`{ %afPoints79 }`) a `spread(afPoints79) {}`:
                    -- for these only the cite is compared
                    local pv1 = p.pcMap[k][1]
                    local codeVal = k == 'OTHER' or (k == 'BITMASK' and pv1 and pv1:match('^{%s*%%'))
                    if not lv then
                        report(name, string.format('Tag %s: PrintConv %s missing', key, k))
                    elseif (not codeVal and lv[1] ~= pv1) or lv[2] ~= p.pcMap[k][2] then
                        report(name, string.format('Tag %s: PrintConv %s: perl={%s,%q} lua={%s,%q}',
                            key, k, p.pcMap[k][1], p.pcMap[k][2], lv[1], lv[2]))
                    end
                end
                for _, k in ipairs(l.pcOrder) do
                    if not p.pcMap[k] then report(name, string.format('Tag %s: PrintConv %s EXTRA', key, k)) end
                end
            end
        end
    end
    for _, key in ipairs(lorder) do
        if not pmap[key] then report(name, string.format('Tag %s: EXTRA (not in upstream)', key)) end
    end
    print(string.format('  [%s] %d tags, %d PrintConv pairs OK (full comparison)', name, #lorder, pcPairs))
end

------------------------------------------------------------------------------
-- 3d. Conditional lists (tag IDs whose entry is a list of tagInfo hashes)
------------------------------------------------------------------------------
-- A tag ID whose upstream entry is an array ref `[ {Name=>...}, {...} ]` is
-- a conditional list: GetTagInfo walks it in order and takes the first entry
-- whose Condition holds, and `-t` (GetTagIndex) prints the position of the
-- chosen entry. A list that is shorter or ordered differently than upstream
-- therefore changes both which entry matches and the printed index, so this
-- check holds every such list to upstream entry for entry (by Name, in
-- order). The text-based checkers above cannot see it -- a list entry's
-- fields sit one level deeper than they look -- so both sides are read at
-- runtime instead: upstream by letting Perl load every module and dump each
-- list's Name sequence, the port by requiring its own modules (this needs
-- LUA_PATH/LUA_CPATH from the Makefile, like the test suite).
--
-- Scope rules: a table the port does not have, and a tag ID the port's table
-- does not carry, are ordinary port scope and not reported. Reported is an
-- ID the port HAS where the shape disagrees: a list of different length or
-- Name order, a single entry where upstream has a list, or a list where
-- upstream has none.

-- Perl side: every hash (and array, for @MakerNotes::Main) in every
-- Image::ExifTool package; one line per conditional list:
--   <package>::<table> TAB <tag ID> TAB <Name> US <Name> ...
local PERL_LIST_DUMP = [=[
use strict; no strict 'refs';
my $lib = shift;
unshift @INC, $lib;
require Image::ExifTool;
local $SIG{__WARN__} = sub {};
for my $f (sort glob "$lib/Image/ExifTool/*.pm") {
    my ($m) = $f =~ m{/(\w+)\.pm$};
    eval { require "Image/ExifTool/$m.pm" };
}
# QuickTimeStream.pl is an include of QuickTime.pm (loaded on demand); its
# tables live in the Image::ExifTool::QuickTime package
eval { require 'Image/ExifTool/QuickTimeStream.pl' };
# XMP2.pl likewise fills the Image::ExifTool::XMP package
eval { require 'Image/ExifTool/XMP2.pl' };
my %seen;
sub isList { my $v = shift; ref $v eq 'ARRAY' and @$v and ref $v->[0] eq 'HASH' and exists $v->[0]{Name} }
sub names { join "\x1f", map { ref $_ eq 'HASH' ? ($$_{Name} // '?') : '?' } @{$_[0]} }
sub walk {
    my $pkg = shift;
    for my $sym (sort keys %{"${pkg}::"}) {
        if ($sym =~ /^(\w+)::$/) {
            walk("${pkg}::$1") unless $1 eq 'SUPER' or $seen{"${pkg}::$1"}++;
            next;
        }
        my $glob = ${"${pkg}::"}{$sym};
        next unless ref \$glob eq 'GLOB';
        if (my $h = *{$glob}{HASH}) {
            for my $id (sort keys %$h) {
                print "${pkg}::$sym\t$id\t", names($$h{$id}), "\n" if isList($$h{$id});
            }
        }
        # a list that is a named array of its own (@MakerNotes::Main), used
        # by reference from several tag IDs; tag ID "" marks it
        if (my $a = *{$glob}{ARRAY}) {
            print "${pkg}::$sym\t\t", names($a), "\n" if isList($a);
        }
    }
}
walk('Image::ExifTool');
]=]

local function checkConditionalLists()
    local tmp = os.tmpname()
    local fh = assert(io.open(tmp, 'w'))
    fh:write(PERL_LIST_DUMP)
    fh:close()
    local p = io.popen("perl '" .. tmp .. "' '" .. LIB .. "'")
    local perlLists = {}     -- ['Mod.Table'][id] = { names }
    local count = 0
    for line in p:lines() do
        local pkg, id, nm = line:match('^([^\t]+)\t([^\t]*)\t(.*)$')
        local mod, tbl = (pkg or ''):match('^Image::ExifTool::([%w_]+)::([%w_]+)$')
        if mod then
            local key = mod .. '.' .. tbl
            perlLists[key] = perlLists[key] or {}
            local names = {}
            for n in (nm .. '\31'):gmatch('([^\31]*)\31') do names[#names + 1] = n end
            perlLists[key][id] = names
            count = count + 1
        end
    end
    p:close()
    os.remove(tmp)
    if count == 0 then
        report('Conditional Lists', 'no lists read from Perl (perl not callable?)')
        return
    end
    -- a conditional list in the port: an array of tagInfo tables
    local function isLuaList(e)
        return type(e) == 'table' and e.Name == nil and type(e[1]) == 'table' and e[1].Name ~= nil
    end
    local function luaNames(e)
        local t = {}
        for i, x in ipairs(e) do t[i] = type(x) == 'table' and (x.Name or '?') or '?' end
        return t
    end
    -- tag ID as Perl stringifies the hash key
    local function idString(id)
        if math.type(id) == 'integer' then return string.format('%d', id) end
        return tostring(id)
    end
    local checked = 0
    local pm = io.popen("ls '" .. SRC .. "'/*.lua")
    for path in pm:lines() do
        local mod = path:match('([^/]+)%.lua$')
        local ok, M = pcall(require, 'lexiftool.' .. mod)
        -- (XMP2.lua fills the XMP module table, as XMP2.pl fills the XMP
        --  package, so its tables are checked together with XMP's)
        if ok and mod == 'XMP' then pcall(require, 'lexiftool.XMP2') end
        if not ok then
            report(mod .. '.lua', 'Conditional Lists: module not loadable: ' .. tostring(M))
        elseif type(M) == 'table' then
            local tnames = {}
            for tn, T in pairs(M) do
                if type(tn) == 'string' and type(T) == 'table' then tnames[#tnames + 1] = tn end
            end
            table.sort(tnames)
            for _, tn in ipairs(tnames) do
                local T = M[tn]
                local key = mod .. '.' .. tn
                -- (QuickTimeStream.pl defines its tables in the QuickTime
                --  package; the port names the module after the file)
                local pkey = mod == 'QuickTimeStream' and ('QuickTime.' .. tn) or key
                local pl = perlLists[pkey] or {}
                local ids = {}
                if pl[''] then
                    -- upstream's table is a named list itself (@MakerNotes::
                    -- Main); a plain `isLuaList(T)` cannot tell, since a
                    -- binary-data table with a tag at ID 1 looks the same
                    ids[1] = ''
                else
                    for id in pairs(T) do
                        if type(id) ~= 'table' and type(id) ~= 'boolean' then ids[#ids + 1] = id end
                    end
                    table.sort(ids, function(a, b) return idString(a) < idString(b) end)
                end
                for _, id in ipairs(ids) do
                    local e = id == '' and T or T[id]
                    local sid = idString(id)
                    local pn = pl[sid]
                    if isLuaList(e) then
                        checked = checked + 1
                        local ln = luaNames(e)
                        if not pn then
                            report(key, string.format('Tag %s: conditional list (%d), upstream no list', sid, #ln))
                        elseif table.concat(pn, ',') ~= table.concat(ln, ',') then
                            report(key, string.format('Tag %s: conditional list differs\n    perl %d: %s\n    lua  %d: %s',
                                sid, #pn, table.concat(pn, ','), #ln, table.concat(ln, ',')))
                        end
                    elseif pn and type(e) == 'table' and e.Name ~= nil then
                        checked = checked + 1
                        report(key, string.format('Tag %s: single entry, upstream conditional list with %d entries (%s)',
                            sid, #pn, table.concat(pn, ',')))
                    end
                end
            end
        end
    end
    pm:close()
    print(string.format('  %d conditional lists checked (%d upstream)', checked, count))
end

------------------------------------------------------------------------------
-- 3e. Conversion shapes (PrintConv/ValueConv and their inverses, per tag)
------------------------------------------------------------------------------
-- A conversion's *form* carries behaviour beyond what it computes: only a
-- hash PrintConv can be translated by -lang and inverted for writing, a list
-- conversion is applied per space-separated value and joined with '; ', and
-- `PrintConv => undef` switches off a table's PRINT_CONV default. Folding a
-- list or a hash into a Lua function -- or inventing a conversion upstream
-- does not have -- therefore changes output, even when the default output
-- happens to agree. This check holds the form of every conversion of every
-- tag the port carries to upstream, read at runtime on both sides like 3d:
--
--   upstream (Perl)          port (Lua)
--   missing                  nil              must match
--   undef                    false            must match
--   HASH                     lookup table     must match; keys compared both
--                                             ways, string values compared
--   ARRAY                    list (first      must match; same length, each
--                            element is a     element compared recursively
--                            table/function/
--                            false)
--   CODE / string of Perl    function         either form on either side
--   code
--
-- Scope: ValueConv and PrintConv are checked in full (the read path).
-- ValueConvInv and PrintConvInv belong to the write path, which is ported
-- tag by tag; an inverse the port does not carry yet is counted, not
-- reported. One the port does carry is held to upstream like the read
-- conversions -- in particular, an inverse upstream does not have is an
-- invented one. Tables and tag IDs the port does not have are port scope
-- (as in 3d). Known, deliberate gaps live in tools/verify_conv_allowlist.lua;
-- an allowlist entry that no longer matches a finding is reported as stale,
-- so the list can only shrink.

-- Perl side: one line per tag info (`T`) and per conversion it has:
--   <package>::<table> TAB <tag ID> TAB <list index or 0> TAB <path> TAB
--   <shape> TAB <extra>
-- where path is the conversion name, `[N]` appended per list level, shape is
-- U(ndef)/S(tring)/H(ASH)/A(RRAY)/C(ODE)/R(other ref), and extra is the
-- element count of an ARRAY or the `key RS value` pairs (US-separated) of a
-- HASH, a non-scalar value given as its <shape>. Control and non-ASCII
-- bytes are written as \xNN on both sides.
local PERL_CONV_DUMP = [=[
use strict; no strict 'refs';
my $lib = shift;
unshift @INC, $lib;
require Image::ExifTool;
local $SIG{__WARN__} = sub {};
for my $f (sort glob "$lib/Image/ExifTool/*.pm") {
    my ($m) = $f =~ m{/(\w+)\.pm$};
    eval { require "Image/ExifTool/$m.pm" };
}
# the .pl includes (QuickTimeStream.pl, XMP2.pl, Write*.pl, ...) fill their
# host packages and some adjust tag infos when loaded (WriteQuickTime.pl
# sets Preferred); the port requires all its modules, so load them all
for my $f (sort glob "$lib/Image/ExifTool/*.pl") {
    my ($m) = $f =~ m{/(\w+)\.pl$};
    eval { require "Image/ExifTool/$m.pl" };
}
my @convs = qw(ValueConv PrintConv ValueConvInv PrintConvInv);
my %seen;
# 3f: keys not compared field by field -- the conversions (compared above,
# with their own allowlist) and the reserved keys GetTagTable/AddTagToTable
# fill in at run time (README "[reserved]")
my %skipField = map { $_ => 1 } @convs, qw(TagID NewTagID Index Table
    PropertyPath SrcTagInfo OtherLang RootTagInfo Module LangCode AddedUnknown);
my %skipHead = map { $_ => 1 } qw(TABLE_NAME SHORT_NAME SRC_TABLE);
print "S\t$_\n" for sort keys %Image::ExifTool::specialTags;
# one line per node of a field value:
#   F TAB <table> TAB <tag ID> TAB <list index, or H for the table head> TAB
#   <path> TAB <shape> TAB <scalar value / element count>
# path segments are separated by US; hashes and arrays recurse (cut at a
# cycle or below depth 8, shape X)
sub fld {
    my ($rec, $path, $v, $depth, $stk) = @_;
    my $s = shape($v);
    if ($s eq 'H' or $s eq 'A') {
        if ($depth > 8 or $$stk{$v}) { print "$rec\t$path\tX\t\n"; return }
        $$stk{$v} = 1;
        if ($s eq 'H') {
            print "$rec\t$path\tH\t", scalar(keys %$v), "\n";
            fld($rec, "$path\x1f" . esc($_), $$v{$_}, $depth + 1, $stk) for sort keys %$v;
        } else {
            print "$rec\t$path\tA\t", scalar(@$v), "\n";
            fld($rec, "$path\x1f" . ($_ + 1), $$v[$_], $depth + 1, $stk) for 0 .. $#$v;
        }
        delete $$stk{$v};
    } else {
        print "$rec\t$path\t$s\t", ($s eq 'S' ? esc($v) : $s eq 'R' ? ref $v : ''), "\n";
    }
}
sub fields {
    my ($tbl, $id, $idx, $ti) = @_;
    my $rec = join "\t", 'F', $tbl, esc($id), $idx;
    $ti = { Name => $ti } unless ref $ti;    # plain Name string (GetTagInfo)
    return unless ref $ti eq 'HASH';
    print "$rec\t\tH\t", scalar(keys %$ti), "\n";    # the info itself (may be empty)
    $skipField{$_} or fld($rec, esc($_), $$ti{$_}, 1, {}) for sort keys %$ti;
}
sub esc { my $s = shift; $s =~ s/([\x00-\x1f\\\x7f-\xff])/sprintf('\\x%02x',ord $1)/ge; $s }
sub shape {
    my $v = shift;
    return 'U' unless defined $v;
    my $r = ref $v;
    return $r eq '' ? 'S' : $r eq 'HASH' ? 'H' : $r eq 'ARRAY' ? 'A' : $r eq 'CODE' ? 'C' : 'R';
}
sub pairs {
    my $h = shift;
    join "\x1f", map { esc($_) . "\x1e" . (ref $$h{$_} ? '<' . shape($$h{$_}) . '>' :
        defined $$h{$_} ? esc($$h{$_}) : '<U>') } sort keys %$h;
}
sub conv {
    my ($tbl, $id, $idx, $path, $v) = @_;
    my $s = shape($v);
    my $extra = $s eq 'H' ? pairs($v) : $s eq 'A' ? scalar(@$v) : '';
    print join("\t", $tbl, esc($id), $idx, $path, $s, $extra), "\n";
    if ($s eq 'A') {
        conv($tbl, $id, $idx, "$path\[" . ($_ + 1) . ']', $$v[$_]) for 0 .. $#$v;
    }
}
sub info {
    my ($tbl, $id, $idx, $ti) = @_;
    print join("\t", $tbl, esc($id), $idx, 'T', '', ''), "\n";
    fields($tbl, $id, $idx, $ti);
    return unless ref $ti eq 'HASH';
    exists $$ti{$_} and conv($tbl, $id, $idx, $_, $$ti{$_}) for @convs;
}
sub isTagTable {
    for (values %{$_[0]}) {
        return 1 if ref $_ eq 'HASH' and exists $$_{Name};
        return 1 if ref $_ eq 'ARRAY' and @$_ and ref $$_[0] eq 'HASH' and exists $$_[0]{Name};
    }
    return 0;
}
sub walk {
    my $pkg = shift;
    for my $sym (sort keys %{"${pkg}::"}) {
        if ($sym =~ /^(\w+)::$/) {
            walk("${pkg}::$1") unless $1 eq 'SUPER' or $seen{"${pkg}::$1"}++;
            next;
        }
        my $glob = ${"${pkg}::"}{$sym};
        next unless ref \$glob eq 'GLOB';
        my $h = *{$glob}{HASH} or next;
        next unless isTagTable($h);
        for my $k (sort keys %$h) {
            next unless $Image::ExifTool::specialTags{$k} and not $skipHead{$k};
            fld(join("\t", 'F', "${pkg}::$sym", '', 'H'), $k, $$h{$k}, 1, {});
        }
        for my $id (sort keys %$h) {
            next if $Image::ExifTool::specialTags{$id};
            my $v = $$h{$id};
            if (ref $v eq 'HASH') {   # (Name may default to the tag ID)
                info("${pkg}::$sym", $id, 0, $v);
            } elsif (ref $v eq 'ARRAY' and @$v and ref $$v[0] eq 'HASH') {
                ref $$v[$_] eq 'HASH' and info("${pkg}::$sym", $id, $_ + 1, $$v[$_]) for 0 .. $#$v;
            } elsif (not ref $v and $id !~ /^[A-Z_]+$/) {
                info("${pkg}::$sym", $id, 0, $v);   # plain Name string: no conversions
            }
        }
    }
}
walk('Image::ExifTool');
]=]

-- The dump above serves both 3e and 3f; Perl runs once and its lines are
-- kept (3f's `F`/`S` records do not match 3e's line shape and are skipped
-- there).
local perlDumpLines
local function perlTableDump()
    if perlDumpLines then return perlDumpLines end
    local tmp = os.tmpname()
    local fh = assert(io.open(tmp, 'w'))
    fh:write(PERL_CONV_DUMP)
    fh:close()
    local p = io.popen("perl '" .. tmp .. "' '" .. LIB .. "'")
    perlDumpLines = {}
    for line in p:lines() do perlDumpLines[#perlDumpLines + 1] = line end
    p:close()
    os.remove(tmp)
    return perlDumpLines
end

local function checkConvShapes()
    local CONVS = { 'ValueConv', 'PrintConv', 'ValueConvInv', 'PrintConvInv' }
    local INV = { ValueConvInv = true, PrintConvInv = true }
    local function esc(s)
        return (s:gsub('[%z\1-\31\\\127-\255]', function(c) return string.format('\\x%02x', c:byte()) end))
    end
    -- a hash key or value as Perl stringifies it
    local function str(v)
        if math.type(v) == 'integer' then return string.format('%d', v) end
        if math.type(v) == 'float' then
            if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
            return string.format('%.15g', v)
        end
        return tostring(v)
    end
    -- shape of a port conversion, classified the way GetValue does
    local function shape(v)
        if v == nil then return '-' end
        if v == false then return 'U' end
        local t = type(v)
        if t == 'string' then return 'S' end
        if t == 'function' then return 'C' end
        if t == 'table' then
            local f = v[1]
            if f == false or type(f) == 'table' or type(f) == 'function' then return 'A' end
            return 'H'
        end
        return 'R'
    end
    local function pairsOf(h)
        local t = {}
        for k, v in pairs(h) do
            local vs
            if type(v) == 'table' or type(v) == 'function' then vs = '<' .. shape(v) .. '>'
            elseif v == false then vs = '<U>'
            else vs = esc(str(v)) end
            t[esc(str(k))] = vs
        end
        return t
    end
    -- Notes inside a lookup are documentation; compare them modulo layout
    local function norm(k, v)
        if k ~= 'Notes' then return v end
        return (v:gsub('\\x0a', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
    end

    -- read the Perl dump
    local perlInfo = {}    -- ['Mod.Table'][id .. '#' .. idx] = { [path] = { shape, extra } }
    local count = 0
    for _, line in ipairs(perlTableDump()) do
        local tbl, id, idx, path, s, extra = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$')
        local mod, tn = (tbl or ''):match('^Image::ExifTool::([%w_]+)::([%w_]+)$')
        if not mod and tbl then
            -- tables of the main module (%Image::ExifTool::Extra, ...)
            tn = tbl:match('^Image::ExifTool::([%w_]+)$')
            mod = tn and 'ExifTool'
        end
        if mod then
            local key = mod .. '.' .. tn
            perlInfo[key] = perlInfo[key] or {}
            local k = id .. '#' .. idx
            perlInfo[key][k] = perlInfo[key][k] or {}
            if path == 'T' then
                count = count + 1
            else
                perlInfo[key][k][path] = { s, extra }
            end
        end
    end
    if count == 0 then
        report('Conv Shapes', 'no tags read from Perl (perl not callable?)')
        return
    end

    local allowlist = dofile(moduleDir() .. '/verify_conv_allowlist.lua')
    local used = {}
    local findings = {}
    local function finding(where, msg)
        local why = allowlist[where]
        if why then
            used[where] = true
        else
            findings[#findings + 1] = where .. ': ' .. msg
        end
    end
    local function compatible(ps, ls)
        return ps == ls or ((ps == 'S' or ps == 'C') and (ls == 'S' or ls == 'C'))
    end
    local infos, missingInv = 0, 0
    local function cmpConv(where, P, path, lv)
        local pc = P[path]
        local ps, ls = pc and pc[1] or '-', shape(lv)
        if INV[path:match('^%a+')] and ls == '-' then
            if ps ~= '-' then missingInv = missingInv + 1 end
            return
        end
        local names = { ['-'] = 'missing', U = 'undef', S = 'Code', C = 'Code', H = 'Hash', A = 'List', R = 'Ref' }
        if not compatible(ps, ls) then
            finding(where .. ' ' .. path, string.format('upstream %s, Port %s', names[ps], names[ls]))
            return
        end
        if ps == 'H' then
            local pp = {}
            for e in (pc[2] .. '\31'):gmatch('([^\31]*)\31') do
                local k, v = e:match('^(.-)\30(.*)$')
                if k then pp[k] = v end
            end
            local lp = pairsOf(lv)
            local miss, extra, diff = {}, {}, {}
            for k, v in pairs(pp) do
                if lp[k] == nil then miss[#miss + 1] = k
                elseif norm(k, lp[k]) ~= norm(k, v) then diff[#diff + 1] = k .. ' => ' .. v .. ' / ' .. lp[k] end
            end
            for k in pairs(lp) do if pp[k] == nil then extra[#extra + 1] = k end end
            table.sort(miss); table.sort(extra); table.sort(diff)
            local function list(t)
                if #t <= 8 then return table.concat(t, ', ') end
                return table.concat(t, ', ', 1, 8) .. string.format(', ... (%d)', #t)
            end
            if #miss > 0 then finding(where .. ' ' .. path .. ' missing', 'hash keys missing: ' .. list(miss)) end
            if #extra > 0 then finding(where .. ' ' .. path .. ' extra', 'hash keys not upstream: ' .. list(extra)) end
            if #diff > 0 then finding(where .. ' ' .. path .. ' values', 'hash values differ: ' .. list(diff)) end
        elseif ps == 'A' then
            local n = 0
            while lv[n + 1] ~= nil do n = n + 1 end
            if tostring(n) ~= pc[2] then
                finding(where .. ' ' .. path .. ' length', string.format('list upstream %s, port %d entries', pc[2], n))
            end
            for i = 1, tonumber(pc[2]) do
                cmpConv(where, P, path .. '[' .. i .. ']', lv[i])
            end
        end
    end
    local function cmpInfo(key, sid, idx, ti)
        local P = perlInfo[key] and perlInfo[key][sid .. '#' .. idx]
        if not P then return end
        infos = infos + 1
        local where = key .. ' ' .. sid .. (idx > 0 and ('[' .. idx .. ']') or '')
        for _, c in ipairs(CONVS) do cmpConv(where, P, c, ti[c]) end
    end

    local mods = {}
    local pm = io.popen("ls '" .. SRC .. "'/*.lua")
    for path in pm:lines() do mods[#mods + 1] = path:match('([^/]+)%.lua$') end
    pm:close()
    mods[#mods + 1] = 'ExifTool'
    for _, mod in ipairs(mods) do
        local ok, M = pcall(require, mod == 'ExifTool' and 'lexiftool' or 'lexiftool.' .. mod)
        if ok and type(M) == 'table' then
            for tn, T in pairs(M) do
                local key = mod .. '.' .. tostring(tn)
                if type(tn) == 'string' and type(T) == 'table' and perlInfo[key] then
                    for id, e in pairs(T) do
                        if type(id) == 'number' or type(id) == 'string' then
                            local sid = esc(str(id))
                            if type(e) == 'table' and e.Name ~= nil then
                                cmpInfo(key, sid, 0, e)
                            elseif type(e) == 'table' and type(e[1]) == 'table' and e[1].Name ~= nil then
                                for i, x in ipairs(e) do
                                    if type(x) == 'table' then cmpInfo(key, sid, i, x) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(findings)
    for _, f in ipairs(findings) do report('Conv Shapes', f) end
    local stale, nAllowed = {}, 0
    for k in pairs(allowlist) do
        nAllowed = nAllowed + 1
        if not used[k] then stale[#stale + 1] = k end
    end
    table.sort(stale)
    for _, k in ipairs(stale) do
        report('verify_conv_allowlist.lua', 'entry no longer applies (remove): ' .. k)
    end
    print(string.format('  %d tag infos checked (%d upstream), %d allowlist entries, '
        .. '%d Inv conversions upstream not yet ported', infos, count, nAllowed - #stale, missingInv))
end

------------------------------------------------------------------------------
-- 3f. Full field comparison (every tag-info key and every table-head key)
------------------------------------------------------------------------------
-- The checks above compare a selection of fields (Name, Notes, Groups, the
-- conversions); a tag that lost its PrintHex, SeparateTable, RawConv or
-- Count, or gained a Format or a WRITE_PROC upstream does not have, passes
-- them unseen and only shows up as wrong output. This check compares the
-- complete key set instead -- whatever keys upstream's tag info / table head
-- has, and whatever keys the port's has -- read at runtime from the same
-- Perl dump as 3e (one Perl run for both) and from the port's own modules.
--
-- Compared per tag info of every tag ID the port carries (list entries by
-- index, a plain Name string counts as { Name = ... } on either side), and
-- per table head (the %specialTags keys, minus TABLE_NAME/SHORT_NAME/
-- SRC_TABLE, which GetTagTable fills in):
--   * every key: present on both sides, else `missing` (upstream only) or
--     `extra` (port only)
--   * hash values (SubDirectory, Groups, Flags hashes, Struct, VARS, ...)
--     and array values (Flags lists, DATAMEMBER, IS_OFFSET, ...) recurse,
--     their keys / elements are compared the same way
--   * scalars compare by value as Perl stringifies them (Lua true = 1,
--     Lua false = undef, 'lexiftool.X.Y' = 'Image::ExifTool::X::Y'; Notes,
--     Description, NOTES and TABLE_DESC modulo whitespace), else `differs`
--   * code: the port spells Perl code (a CODE ref or a string of Perl code
--     such as Condition, RawConv, Hook, SubDirectory Start/Base, ...) as a
--     Lua function, so code is checked for presence and form only -- a Lua
--     function counts as matching a Perl CODE ref, and as matching a Perl
--     string where the key holds Perl code (CODE_KEYS); anything else is
--     `shape` (shape differs)
-- Not compared here: ValueConv/PrintConv and their inverses (3e) and the
-- reserved keys GetTagTable/AddTagToTable add at run time. Tables and tag
-- IDs the port does not have are port scope (as in 3d/3e). Known findings
-- live in tools/verify_fields_allowlist.lua -- that file is the work list;
-- a stale entry fails the gate, so it can only shrink.

-- keys whose upstream string value is Perl code (evaluated, not data)
local CODE_KEYS = {
    Condition = true, RawConv = true, RawConvInv = true, Hook = true,
    WriteCheck = true, DelCheck = true, Validate = true, Start = true,
    Base = true, OffsetPt = true, SetBase = true, ChangeBase = true,
    ProcessProc = true, WriteProc = true, ByteOrder = true, DirName = true,
    MaxSubdirs = true, RawJoin = true, WriteHook = true, IsOffset = true,
    FixOffsets = true, WriteCondition = true, PRINT_CONV = true, WrongBase = true,
    PROCESS_PROC = true, WRITE_PROC = true, CHECK_PROC = true,
    INIT_TABLE = true, LANG_INFO = true,
    -- conversions nested below the top level (XMP Struct fields, ...); the
    -- top-level ones are 3e's
    ValueConv = true, PrintConv = true, ValueConvInv = true, PrintConvInv = true,
}
-- keys whose every value is Perl code (WriteAlso: tag name => expression)
local CODE_CONTAINERS = { WriteAlso = true }
-- documentation text, compared modulo whitespace
local TEXT_KEYS = { Notes = true, Description = true, NOTES = true, TABLE_DESC = true }
-- reserved tag-info keys filled in at run time (mirrors %skipField in Perl)
local RESERVED = {
    ValueConv = true, PrintConv = true, ValueConvInv = true, PrintConvInv = true,
    TagID = true, NewTagID = true, Index = true, Table = true, PropertyPath = true,
    SrcTagInfo = true, OtherLang = true, RootTagInfo = true, Module = true,
    LangCode = true, AddedUnknown = true,
}
local SKIP_HEAD = { TABLE_NAME = true, SHORT_NAME = true, SRC_TABLE = true }

local function checkFields()
    local function esc(s)
        return (s:gsub('[%z\1-\31\\\127-\255]', function(c) return string.format('\\x%02x', c:byte()) end))
    end
    local function str(v)
        if math.type(v) == 'integer' then return string.format('%d', v) end
        if math.type(v) == 'float' then
            if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
            return string.format('%.15g', v)
        end
        return tostring(v)
    end

    -- rebuild upstream's field trees from the dump:
    --   perlTree['Mod.Table'][id .. '#' .. idx] = { s = 'H', k = { key = node } }
    -- (idx 'H' is the table head); node = { s = shape, v = value, k = children }
    local special = {}
    local perlTree = {}
    local nodes = 0
    for _, line in ipairs(perlTableDump()) do
        local c = line:sub(1, 1)
        if c == 'S' and line:sub(2, 2) == '\t' then
            special[line:sub(3)] = true
        elseif c == 'F' and line:sub(2, 2) == '\t' then
            local tbl, id, idx, path, s, v = line:match('^F\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$')
            local mod, tn = (tbl or ''):match('^Image::ExifTool::([%w_]+)::([%w_]+)$')
            if not mod and tbl then
                tn = tbl:match('^Image::ExifTool::([%w_]+)$')
                mod = tn and 'ExifTool'
            end
            if mod then
                local key = mod .. '.' .. tn
                local T = perlTree[key]
                if not T then T = {}; perlTree[key] = T end
                local rk = id .. '#' .. idx
                local node = T[rk]
                if not node then node = { s = 'H', k = {} }; T[rk] = node end
                if path == '' then goto continue end   -- the info itself
                local segs = {}
                for seg in (path .. '\31'):gmatch('([^\31]*)\31') do segs[#segs + 1] = seg end
                for i = 1, #segs - 1 do
                    node = node.k[segs[i]]
                end
                node.k[segs[#segs]] = { s = s, v = v, k = {} }
                nodes = nodes + 1
            end
        end
        ::continue::
    end
    if nodes == 0 then
        report('Fields', 'no fields read from Perl (perl not callable?)')
        return
    end

    local allowlist = dofile(moduleDir() .. '/verify_fields_allowlist.lua')
    local used, findings, all = {}, {}, {}
    local byModule, byKind, nAllowed = {}, {}, 0
    -- kind = the top-level key (SubDirectory and Flags one level deeper)
    local function finding(key, where, path, what, msg)
        local kind = path[1] or '?'
        if (kind == 'SubDirectory' or kind == 'Flags') and path[2] then kind = kind .. '.' .. path[2] end
        local fk = what .. ' ' .. kind
        byKind[fk] = (byKind[fk] or 0) + 1
        local mod = key:match('^([^.]+)')
        byModule[mod] = (byModule[mod] or 0) + 1
        local id = where .. ' ' .. table.concat(path, '.') .. ' ' .. what
        all[id] = msg or ''
        if allowlist[id] then
            used[id] = true
            nAllowed = nAllowed + 1
        else
            findings[#findings + 1] = { id, msg }
        end
    end

    -- shape of a port value, the Perl shape as the hint for tables
    local function lshape(v, hint)
        if v == nil then return '-' end
        if v == false then return 'U' end
        local t = type(v)
        if t == 'string' or t == 'number' or v == true then return 'S' end
        if t == 'function' then return 'C' end
        if t == 'table' then
            if hint == 'H' or hint == 'A' then return hint end
            return v[1] ~= nil and 'A' or 'H'
        end
        return 'R'
    end
    local function lstr(v)
        if v == true then return '1' end
        local s = str(v)
        if s:match('^lexiftool[%.%w_]*$') then
            s = s:gsub('^lexiftool', 'Image::ExifTool'):gsub('%.', '::')
                 :gsub('^Image::ExifTool::QuickTimeStream::', 'Image::ExifTool::QuickTime::')
        end
        return esc(s)
    end
    local function normText(v)
        return (v:gsub('\\x0a', ' '):gsub('\\x09', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
    end
    local function short(v)
        v = v or ''
        if #v > 40 then v = v:sub(1, 37) .. '...' end
        return "'" .. v .. "'"
    end
    local names = { ['-'] = 'missing', U = 'undef', S = 'Scalar', C = 'Code', H = 'Hash', A = 'List', R = 'Ref' }

    local cmp
    -- compare the children of a hash node (upstream) with a Lua table
    local function cmpHash(key, where, path, pk, lt, skip)
        -- the port's keys as Perl stringifies them (Groups' [0] is '0')
        local lmap = {}
        for k, v in pairs(lt) do
            if type(k) == 'string' or type(k) == 'number' then lmap[esc(str(k))] = v end
        end
        for k, pn in pairs(pk) do
            if not (skip and skip[k]) then
                local p2 = { table.unpack(path) }
                p2[#p2 + 1] = k
                cmp(key, where, p2, pn, lmap[k])
            end
        end
        for sk, v in pairs(lmap) do
            if pk[sk] == nil and not (skip and skip[sk]) then
                local p2 = { table.unpack(path) }
                p2[#p2 + 1] = sk
                local ls = lshape(v)
                finding(key, where, p2, 'extra', ls == 'S' and short(lstr(v)) or names[ls])
            end
        end
    end
    cmp = function(key, where, path, pn, lv)
        local ps = pn.s
        if ps == 'X' then return end
        local ls = lshape(lv, ps)
        local leaf = path[#path]
        if ls == '-' then
            finding(key, where, path, 'missing', ps == 'S' and short(pn.v) or names[ps])
            return
        end
        if ps == 'S' then
            if ls == 'S' then
                local a, b = pn.v, lstr(lv)
                if TEXT_KEYS[leaf] then a, b = normText(a), normText(b) end
                if a ~= b then
                    -- show both from the first differing character on
                    local i = 1
                    while a:sub(i, i) == b:sub(i, i) do i = i + 1 end
                    i = math.max(1, i - 10)
                    finding(key, where, path, 'differs', 'upstream ' .. short(a:sub(i)) .. ', port ' .. short(b:sub(i))
                        .. (i > 1 and string.format(' (from char %d)', i) or ''))
                end
            elseif not (ls == 'C' and (CODE_KEYS[leaf] or CODE_CONTAINERS[path[#path - 1]]
                    -- a Format with a Perl expression ('undef[$$self{N}*2]')
                    or (leaf == 'Format' and pn.v:find('$', 1, true)))) then
                finding(key, where, path, 'shape', 'upstream scalar ' .. short(pn.v) .. ', port ' .. names[ls])
            end
        elseif ps == 'C' then
            if ls ~= 'C' and ls ~= 'S' then
                finding(key, where, path, 'shape', 'upstream code, port ' .. names[ls])
            end
        elseif ps == 'U' then
            if ls ~= 'U' then finding(key, where, path, 'shape', 'upstream undef, port ' .. names[ls]) end
        elseif ps == 'H' then
            if type(lv) ~= 'table' then
                finding(key, where, path, 'shape', 'upstream hash, port ' .. names[ls])
            else
                cmpHash(key, where, path, pn.k, lv)
            end
        elseif ps == 'A' then
            if type(lv) ~= 'table' then
                finding(key, where, path, 'shape', 'upstream list, port ' .. names[ls])
            else
                local n = tonumber(pn.v) or 0
                for i = 1, n do
                    local p2 = { table.unpack(path) }
                    p2[#p2 + 1] = tostring(i)
                    cmp(key, where, p2, pn.k[tostring(i)] or { s = 'X' }, lv[i])
                end
                local m = n
                while lv[m + 1] ~= nil do m = m + 1 end
                if m > n then
                    local p2 = { table.unpack(path) }
                    p2[#p2 + 1] = tostring(n + 1)
                    finding(key, where, p2, 'extra', string.format('list upstream %d, port %d entries', n, m))
                end
            end
        end
        -- R (other ref): presence only
    end

    local infos, heads = 0, 0
    local function cmpInfo(key, sid, idx, ti)
        local P = perlTree[key] and perlTree[key][sid .. '#' .. idx]
        if not P then return end
        infos = infos + 1
        if type(ti) == 'string' then ti = { Name = ti } end
        local where = key .. ' ' .. sid .. (idx > 0 and ('[' .. idx .. ']') or '')
        cmpHash(key, where, {}, P.k, ti, RESERVED)
    end
    local function tagLike(v)
        if type(v) == 'string' then return true end
        if type(v) ~= 'table' then return false end
        if v.Name ~= nil then return true end
        return type(v[1]) == 'table' and v[1].Name ~= nil
    end

    local mods = {}
    local pm = io.popen("ls '" .. SRC .. "'/*.lua")
    for path in pm:lines() do mods[#mods + 1] = path:match('([^/]+)%.lua$') end
    pm:close()
    mods[#mods + 1] = 'ExifTool'
    local done = {}
    for _, mod in ipairs(mods) do
        local ok, M = pcall(require, mod == 'ExifTool' and 'lexiftool' or 'lexiftool.' .. mod)
        if ok and mod == 'XMP' then pcall(require, 'lexiftool.XMP2') end
        local pmod = mod == 'QuickTimeStream' and 'QuickTime' or mod
        if ok and type(M) == 'table' then
            for tn, T in pairs(M) do
                local key = pmod .. '.' .. tostring(tn)
                local PT = perlTree[key]
                if type(tn) == 'string' and type(T) == 'table' and PT and not done[key] then
                    done[key] = true
                    -- table head
                    heads = heads + 1
                    local PH = PT['#H'] or { s = 'H', k = {} }
                    local lh = {}
                    for k, v in pairs(T) do
                        if type(k) == 'string' and k:match('^[A-Z][A-Z0-9_]*$') and not SKIP_HEAD[k]
                                and (special[k] or (PT[esc(k) .. '#0'] == nil and PT[esc(k) .. '#1'] == nil
                                    and not tagLike(v))) then
                            lh[k] = v
                        end
                    end
                    cmpHash(key, key .. ' HEAD', {}, PH.k, lh)
                    -- tag infos
                    for id, e in pairs(T) do
                        if (type(id) == 'number' or type(id) == 'string') and not lh[id] then
                            local sid = esc(str(id))
                            -- (a tag info may lack Name, which then defaults
                            --  to the tag ID; upstream's shape decides)
                            if PT[sid .. '#0'] and (type(e) == 'string' or type(e) == 'table') then
                                cmpInfo(key, sid, 0, e)
                            elseif PT[sid .. '#1'] and type(e) == 'table' and type(e[1]) == 'table' then
                                for i, x in ipairs(e) do
                                    if type(x) == 'table' then cmpInfo(key, sid, i, x) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(findings, function(a, b) return a[1] < b[1] end)
    for _, f in ipairs(findings) do report('Fields', f[1] .. (f[2] and (': ' .. f[2]) or '')) end
    local stale, nList = {}, 0
    for k in pairs(allowlist) do
        nList = nList + 1
        if not used[k] then stale[#stale + 1] = k end
    end
    table.sort(stale)
    for _, k in ipairs(stale) do
        report('verify_fields_allowlist.lua', 'entry no longer applies (remove): ' .. k)
    end
    -- the work list at a glance: findings (allowlisted or not) per module
    -- and per kind of field
    local total = #findings + nAllowed
    local function top(t, n)
        local a = {}
        for k, v in pairs(t) do a[#a + 1] = { k, v } end
        table.sort(a, function(x, y) return x[2] > y[2] or (x[2] == y[2] and x[1] < y[1]) end)
        local out = {}
        for i = 1, math.min(n, #a) do out[#out + 1] = string.format('%s %d', a[i][1], a[i][2]) end
        return table.concat(out, ', ')
    end
    print(string.format('  %d tag infos and %d table heads checked, %d findings (%d on the allowlist, %d new)',
        infos, heads, total, nAllowed, #findings))
    if total > 0 then
        print('  by module: ' .. top(byModule, 20))
        print('  by field kind: ' .. top(byKind, 20))
    end
    if arg and arg[1] == '--fields-allowlist' and arg[2] then
        -- regenerate the allowlist from today's findings (allowlisted or
        -- not) into the file named by arg[2]; the head comment of the
        -- current allowlist is carried over, each entry's value is the
        -- finding's message, so the file reads as the work list
        local cur = readall(moduleDir() .. '/verify_fields_allowlist.lua') or ''
        local head = cur:match('^(.-\n)return {') or ''
        local out = assert(io.open(arg[2], 'w'))
        out:write(head, 'return {\n')
        local keys = {}
        for k in pairs(all) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do out:write(string.format('    [%q] = %q,\n', k, all[k])) end
        out:write('}\n')
        out:close()
    end
end

------------------------------------------------------------------------------
-- Run
------------------------------------------------------------------------------

print('=== Header Banner ===')
for _, m in ipairs(portedModules()) do
    checkHeader(m.lua, m.perl, m.base)
end

print('=== Tag Tables ===')
checkTagTable('Exif.Main', SRC .. '/Exif.lua', 'Exif.Main',
    LIB .. '/Image/ExifTool/Exif.pm', '%Image::ExifTool::Exif::Main')
checkTagTable('ICC.Main', SRC .. '/ICC_Profile.lua', 'ICC.Main',
    LIB .. '/Image/ExifTool/ICC_Profile.pm', '%Image::ExifTool::ICC_Profile::Main')
checkTagTable('IPTC.ApplicationRecord', SRC .. '/IPTC.lua', 'IPTC.ApplicationRecord',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::ApplicationRecord')
checkTagTable('IPTC.Main', SRC .. '/IPTC.lua', 'IPTC.Main',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::Main')
checkTagTable('IPTC.EnvelopeRecord', SRC .. '/IPTC.lua', 'IPTC.EnvelopeRecord',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::EnvelopeRecord')
checkTagTable('IPTC.NewsPhoto', SRC .. '/IPTC.lua', 'IPTC.NewsPhoto',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::NewsPhoto')
checkTagTable('IPTC.PreObjectData', SRC .. '/IPTC.lua', 'IPTC.PreObjectData',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::PreObjectData')
checkTagTable('IPTC.ObjectData', SRC .. '/IPTC.lua', 'IPTC.ObjectData',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::ObjectData')
checkTagTable('IPTC.PostObjectData', SRC .. '/IPTC.lua', 'IPTC.PostObjectData',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::PostObjectData')
checkTagTable('IPTC.FotoStation', SRC .. '/IPTC.lua', 'IPTC.FotoStation',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::FotoStation')
checkTagTable('IPTC.Composite', SRC .. '/IPTC.lua', 'IPTC.Composite',
    LIB .. '/Image/ExifTool/IPTC.pm', '%Image::ExifTool::IPTC::Composite')
checkTagTable('JPEG.SOF', SRC .. '/JPEG.lua', 'JPEG.SOF',
    LIB .. '/Image/ExifTool.pm', '%Image::ExifTool::JPEG::SOF')
checkTagTable('JPEG.Adobe', SRC .. '/JPEG.lua', 'JPEG.Adobe',
    LIB .. '/Image/ExifTool/JPEG.pm', '%Image::ExifTool::JPEG::Adobe')
checkTagTable('JPEG.AdobeCM', SRC .. '/JPEG.lua', 'JPEG.AdobeCM',
    LIB .. '/Image/ExifTool/JPEG.pm', '%Image::ExifTool::JPEG::AdobeCM')
checkTagTable('Photoshop.Main', SRC .. '/Photoshop.lua', 'Photoshop.Main',
    LIB .. '/Image/ExifTool/Photoshop.pm', '%Image::ExifTool::Photoshop::Main')

local IC = LIB .. '/Image/ExifTool/ICC_Profile.pm'
checkTagTable('ICC.Header', SRC .. '/ICC_Profile.lua', 'ICC.Header', IC, '%Image::ExifTool::ICC_Profile::Header')
checkTagTable('ICC.ViewingConditions', SRC .. '/ICC_Profile.lua', 'ICC.ViewingConditions',
    IC, '%Image::ExifTool::ICC_Profile::ViewingConditions')
checkTagTable('ICC.Measurement', SRC .. '/ICC_Profile.lua', 'ICC.Measurement',
    IC, '%Image::ExifTool::ICC_Profile::Measurement')
checkTagTable('ICC.ColorRep', SRC .. '/ICC_Profile.lua', 'ICC.ColorRep',
    IC, '%Image::ExifTool::ICC_Profile::ColorRep')
checkTagTable('ICC.Chromaticity', SRC .. '/ICC_Profile.lua', 'ICC.Chromaticity',
    IC, '%Image::ExifTool::ICC_Profile::Chromaticity')
checkTagTable('ICC.ColorantTable', SRC .. '/ICC_Profile.lua', 'ICC.ColorantTable',
    IC, '%Image::ExifTool::ICC_Profile::ColorantTable')
checkTagTable('ICC.Metadata', SRC .. '/ICC_Profile.lua', 'ICC.Metadata',
    IC, '%Image::ExifTool::ICC_Profile::Metadata')

local PG = LIB .. '/Image/ExifTool/PNG.pm'
checkTagTable('PNG.Main', SRC .. '/PNG.lua', 'PNG.Main', PG, '%Image::ExifTool::PNG::Main')
checkTagTable('PNG.ImageHeader', SRC .. '/PNG.lua', 'PNG.ImageHeader',
    PG, '%Image::ExifTool::PNG::ImageHeader')
checkTagTable('PNG.PrimaryChromaticities', SRC .. '/PNG.lua', 'PNG.PrimaryChromaticities',
    PG, '%Image::ExifTool::PNG::PrimaryChromaticities')
checkTagTable('PNG.CICodePoints', SRC .. '/PNG.lua', 'PNG.CICodePoints',
    PG, '%Image::ExifTool::PNG::CICodePoints')
checkTagTable('PNG.SubjectScale', SRC .. '/PNG.lua', 'PNG.SubjectScale',
    PG, '%Image::ExifTool::PNG::SubjectScale')
checkTagTable('PNG.VirtualPage', SRC .. '/PNG.lua', 'PNG.VirtualPage',
    PG, '%Image::ExifTool::PNG::VirtualPage')
checkTagTable('PNG.StereoImage', SRC .. '/PNG.lua', 'PNG.StereoImage',
    PG, '%Image::ExifTool::PNG::StereoImage')
checkTagTable('PNG.AnimationControl', SRC .. '/PNG.lua', 'PNG.AnimationControl',
    PG, '%Image::ExifTool::PNG::AnimationControl')

local AP = LIB .. '/Image/ExifTool/Apple.pm'
checkTagTable('Apple.Main', SRC .. '/Apple.lua', 'Apple.Main', AP, '%Image::ExifTool::Apple::Main')
checkTagTable('Apple.RunTime', SRC .. '/Apple.lua', 'Apple.RunTime',
    AP, '%Image::ExifTool::Apple::RunTime')

local FL = LIB .. '/Image/ExifTool/FLIR.pm'
checkTagTable('FLIR.Main', SRC .. '/FLIR.lua', 'FLIR.Main',
    FL, '%Image::ExifTool::FLIR::Main')
checkTagTable('FLIR.FFF', SRC .. '/FLIR.lua', 'FLIR.FFF',
    FL, '%Image::ExifTool::FLIR::FFF')
checkTagTable('FLIR.Header', SRC .. '/FLIR.lua', 'FLIR.Header',
    FL, '%Image::ExifTool::FLIR::Header')
checkTagTable('FLIR.RawData', SRC .. '/FLIR.lua', 'FLIR.RawData',
    FL, '%Image::ExifTool::FLIR::RawData')
checkTagTable('FLIR.GainDeadData', SRC .. '/FLIR.lua', 'FLIR.GainDeadData',
    FL, '%Image::ExifTool::FLIR::GainDeadData')
checkTagTable('FLIR.CoarseData', SRC .. '/FLIR.lua', 'FLIR.CoarseData',
    FL, '%Image::ExifTool::FLIR::CoarseData')
checkTagTable('FLIR.PaintData', SRC .. '/FLIR.lua', 'FLIR.PaintData',
    FL, '%Image::ExifTool::FLIR::PaintData')
checkTagTable('FLIR.EmbeddedImage', SRC .. '/FLIR.lua', 'FLIR.EmbeddedImage',
    FL, '%Image::ExifTool::FLIR::EmbeddedImage')
checkTagTable('FLIR.CameraInfo', SRC .. '/FLIR.lua', 'FLIR.CameraInfo',
    FL, '%Image::ExifTool::FLIR::CameraInfo')
checkTagTable('FLIR.MeasInfo', SRC .. '/FLIR.lua', 'FLIR.MeasInfo',
    FL, '%Image::ExifTool::FLIR::MeasInfo')
checkTagTable('FLIR.PaletteInfo', SRC .. '/FLIR.lua', 'FLIR.PaletteInfo',
    FL, '%Image::ExifTool::FLIR::PaletteInfo')
checkTagTable('FLIR.TextInfo', SRC .. '/FLIR.lua', 'FLIR.TextInfo',
    FL, '%Image::ExifTool::FLIR::TextInfo')
checkTagTable('FLIR.ParamInfo', SRC .. '/FLIR.lua', 'FLIR.ParamInfo',
    FL, '%Image::ExifTool::FLIR::ParamInfo')
checkTagTable('FLIR.PiP', SRC .. '/FLIR.lua', 'FLIR.PiP',
    FL, '%Image::ExifTool::FLIR::PiP')
checkTagTable('FLIR.GPSInfo', SRC .. '/FLIR.lua', 'FLIR.GPSInfo',
    FL, '%Image::ExifTool::FLIR::GPSInfo')
checkTagTable('FLIR.MeterLink', SRC .. '/FLIR.lua', 'FLIR.MeterLink',
    FL, '%Image::ExifTool::FLIR::MeterLink')
checkTagTable('FLIR.FPF', SRC .. '/FLIR.lua', 'FLIR.FPF',
    FL, '%Image::ExifTool::FLIR::FPF')
checkTagTable('FLIR.UserData', SRC .. '/FLIR.lua', 'FLIR.UserData',
    FL, '%Image::ExifTool::FLIR::UserData')
checkTagTable('FLIR.Parts', SRC .. '/FLIR.lua', 'FLIR.Parts',
    FL, '%Image::ExifTool::FLIR::Parts')
checkTagTable('FLIR.SerialNums', SRC .. '/FLIR.lua', 'FLIR.SerialNums',
    FL, '%Image::ExifTool::FLIR::SerialNums')
checkTagTable('FLIR.Params', SRC .. '/FLIR.lua', 'FLIR.Params',
    FL, '%Image::ExifTool::FLIR::Params')
checkTagTable('FLIR.UnknownUUID', SRC .. '/FLIR.lua', 'FLIR.UnknownUUID',
    FL, '%Image::ExifTool::FLIR::UnknownUUID')
checkTagTable('FLIR.GPS_UUID', SRC .. '/FLIR.lua', 'FLIR.GPS_UUID',
    FL, '%Image::ExifTool::FLIR::GPS_UUID')
checkTagTable('FLIR.MoreInfo', SRC .. '/FLIR.lua', 'FLIR.MoreInfo',
    FL, '%Image::ExifTool::FLIR::MoreInfo')
checkTagTable('FLIR.AFF', SRC .. '/FLIR.lua', 'FLIR.AFF',
    FL, '%Image::ExifTool::FLIR::AFF')
checkTagTable('FLIR.AFF1', SRC .. '/FLIR.lua', 'FLIR.AFF1',
    FL, '%Image::ExifTool::FLIR::AFF1')
checkTagTable('FLIR.AFF5', SRC .. '/FLIR.lua', 'FLIR.AFF5',
    FL, '%Image::ExifTool::FLIR::AFF5')
checkTagTable('FLIR.Composite', SRC .. '/FLIR.lua', 'FLIR.Composite',
    FL, '%Image::ExifTool::FLIR::Composite')

local GP = LIB .. '/Image/ExifTool/GoPro.pm'
checkTagTable('GoPro.GPMF', SRC .. '/GoPro.lua', 'GoPro.GPMF',
    GP, '%Image::ExifTool::GoPro::GPMF')
checkTagTable('GoPro.GPS5', SRC .. '/GoPro.lua', 'GoPro.GPS5',
    GP, '%Image::ExifTool::GoPro::GPS5')
checkTagTable('GoPro.GPS9', SRC .. '/GoPro.lua', 'GoPro.GPS9',
    GP, '%Image::ExifTool::GoPro::GPS9')
checkTagTable('GoPro.GPRI', SRC .. '/GoPro.lua', 'GoPro.GPRI',
    GP, '%Image::ExifTool::GoPro::GPRI')
checkTagTable('GoPro.GLPI', SRC .. '/GoPro.lua', 'GoPro.GLPI',
    GP, '%Image::ExifTool::GoPro::GLPI')
checkTagTable('GoPro.KBAT', SRC .. '/GoPro.lua', 'GoPro.KBAT',
    GP, '%Image::ExifTool::GoPro::KBAT')
checkTagTable('GoPro.fdsc', SRC .. '/GoPro.lua', 'GoPro.fdsc',
    GP, '%Image::ExifTool::GoPro::fdsc')

local SG = LIB .. '/Image/ExifTool/Sigma.pm'
checkTagTable('Sigma.Main', SRC .. '/Sigma.lua', 'Sigma.Main', SG, '%Image::ExifTool::Sigma::Main')
checkTagTable('Sigma.WBSettings', SRC .. '/Sigma.lua', 'Sigma.WBSettings',
    SG, '%Image::ExifTool::Sigma::WBSettings')
checkTagTable('Sigma.WBSettings2', SRC .. '/Sigma.lua', 'Sigma.WBSettings2',
    SG, '%Image::ExifTool::Sigma::WBSettings2')
checkMap('sigmaLensTypes', SRC .. '/Sigma.lua', 'sigmaLensTypes', SG, '%sigmaLensTypes')

local QT = LIB .. '/Image/ExifTool/QuickTime.pm'
checkTagTable('QuickTime.UserData', SRC .. '/QuickTime.lua', 'QuickTime.UserData',
    QT, '%Image::ExifTool::QuickTime::UserData')
checkTagTable('QuickTime.Video', SRC .. '/QuickTime.lua', 'QuickTime.Video',
    QT, '%Image::ExifTool::QuickTime::Video')
checkTagTable('QuickTime.HintInfo', SRC .. '/QuickTime.lua', 'QuickTime.HintInfo',
    QT, '%Image::ExifTool::QuickTime::HintInfo')
checkTagTable('QuickTime.HTCBinary', SRC .. '/QuickTime.lua', 'QuickTime.HTCBinary',
    QT, '%Image::ExifTool::QuickTime::HTCBinary')
for _, t in ipairs({ 'Profile', 'FileProf', 'AudioProf', 'VideoProf',
                     'GenMediaHeader', 'GenMediaInfo', 'TimeCode', 'TCMediaInfo',
                     'ProtectionInfo', 'SchemeType', 'SchemeInfo', 'Rights',
                     'MediaInfo', 'HintHeader', 'AudioKeys', 'VideoKeys', 'cbmp', 'MetaData' }) do
    checkTagTable('QuickTime.' .. t, SRC .. '/QuickTime.lua', 'QuickTime.' .. t,
        QT, '%Image::ExifTool::QuickTime::' .. t)
end

for _, t in ipairs({ 'Stream', 'RoveGPS', 'camm0', 'camm1', 'camm2', 'camm3', 'camm4',
                     'camm5', 'camm6', 'camm7', 'PreviewInfo', 'RVMI_gReV', 'RVMI_sReV',
                     'tx3g', 'INSV_MakerNotes', 'Tags360Fly', 'Accel360Fly', 'Gyro360Fly',
                     'Mag360Fly', 'GPS360Fly', 'Rot360Fly', 'Fusion360Fly' }) do
    checkTagTable('QuickTimeStream.' .. t, SRC .. '/QuickTimeStream.lua', 'QuickTimeStream.' .. t,
        LIB .. '/Image/ExifTool/QuickTimeStream.pl', '%Image::ExifTool::QuickTime::' .. t)
end

-- XMP2.pl is an include of XMP.pm (loaded on demand by GetTagTable) and fills
-- the XMP package, so its tables keep their XMP names but live in XMP2.lua
for _, t in ipairs({ 'crd', 'xmpDM', 'iptcExt', 'prism', 'prl', 'pur', 'pmi', 'prm', 'DICOM',
                     'PixelLive', 'extensis', 'ics', 'acdsee', 'ACDSeeRegions', 'xmpPLUS',
                     'panorama', 'cc', 'dex', 'MediaPro', 'ExpressionMedia', 'digiKam', 'swf',
                     'cell', 'aas', 'creatorAtom', 'fpv', 'apple_fi', 'GettyImages', 'LImage',
                     'hdr', 'hdrgm', 'HDRGainMap', 'apdi', 'SVG', 'otherSVG', 'seal', 'SEAL' }) do
    checkTagTable('XMP2.' .. t, SRC .. '/XMP2.lua', 'XMP.' .. t,
        LIB .. '/Image/ExifTool/XMP2.pl', '%Image::ExifTool::XMP::' .. t)
end

local CN = LIB .. '/Image/ExifTool/Canon.pm'
local CNL = SRC .. '/Canon.lua'
for _, t in ipairs({ 'CameraSettings', 'FocalLength', 'ShotInfo', 'Panorama', 'UnknownD30',
                     'CameraInfo1D', 'CameraInfo1DmkII', 'CameraInfo1DmkIIN',
                     'CameraInfo1DmkIII', 'CameraInfo1DmkIV', 'CameraInfo1DX', 'CameraInfo5D',
                     'CameraInfo5DmkII', 'CameraInfo5DmkIII', 'CameraInfo6D', 'CameraInfo7D',
                     'CameraInfo40D', 'CameraInfo50D', 'CameraInfo60D', 'CameraInfoR6',
                     'CameraInfoR6m2', 'CameraInfoR6m3', 'CameraInfoG5XII', 'CameraInfo70D',
                     'CameraInfo80D', 'CameraInfo450D', 'CameraInfo500D', 'CameraInfo550D',
                     'CameraInfo600D', 'CameraInfo650D', 'CameraInfo750D', 'CameraInfo1000D',
                     'CameraInfoPowerShot', 'CameraInfoPowerShot2', 'CameraInfoUnknown32',
                     'CameraInfoUnknown16', 'CameraInfoUnknown', 'PSInfo', 'PSInfo2',
                     'MovieInfo', 'AFInfo', 'AFInfo2', 'ContrastInfo', 'TimeInfo', 'MyColors',
                     'FaceDetect1', 'FaceDetect2', 'WBInfo', 'FaceDetect3', 'FileInfo',
                     'SerialInfo', 'CropInfo', 'AspectInfo', 'Processing', 'ColorBalance',
                     'MeasuredColor', 'Flags', 'ModifiedInfo', 'PreviewImageInfo',
                     'SensorInfo', 'ColorData1', 'ColorData2', 'ColorData3', 'ColorData4',
                     'ColorCoefs', 'ColorCoefs2', 'ColorCalib', 'ColorCalib2', 'ColorData5',
                     'ColorData6', 'ColorData7', 'ColorData8', 'ColorData9', 'ColorData10',
                     'ColorData11', 'ColorData12', 'ColorDataUnknown', 'ColorInfo',
                     'AFMicroAdj', 'VignettingCorr', 'VignettingCorrUnknown',
                     'VignettingCorr2', 'LightingOpt', 'LensInfo', 'Ambience', 'MultiExp',
                     'HDRInfo', 'LogInfo', 'AFConfig', 'RawBurstInfo', 'LevelInfo',
                     'FocusBracketingInfo', 'CMP1', 'CDI1', 'IAD1', 'FocalInfo', 'ExposureInfo'
                     }) do
    checkBinaryTagTable('Canon.' .. t, CNL, 'Canon.' .. t,
        CN, '%Image::ExifTool::Canon::' .. t)
end
for _, t in ipairs({ 'Main', 'uuid', 'uuid2', 'UnknownIFD', 'CCTP', 'CTMD', 'ExifInfo', 'CNTH',
                     'CNOP', 'Skip', 'Composite', 'FilterInfo' }) do
    checkTagTable('Canon.' .. t, CNL, 'Canon.' .. t,
        CN, '%Image::ExifTool::Canon::' .. t)
end
for _, m in ipairs({ 'flashModel', 'canonQuality', 'canonImageSize', 'canonWhiteBalance',
                     'pictureStyles', 'userDefStyles', 'filterConv' }) do
    checkMap('Canon.' .. m, CNL, 'local ' .. m, CN, 'my %' .. m)
end
checkMap('Canon.canonLensTypes', CNL, 'Canon.canonLensTypes', CN, '%canonLensTypes')
checkMap('Canon.canonModelID', CNL, 'Canon.canonModelID', CN, '%canonModelID')

for _, t in ipairs({ 'Main', 'Type2' }) do
    checkTagTable('Casio.' .. t, SRC .. '/Casio.lua', 'Casio.' .. t,
        LIB .. '/Image/ExifTool/Casio.pm', '%Image::ExifTool::Casio::' .. t)
end
for _, t in ipairs({ 'Main', 'Type2', 'FaceInfo1', 'FaceInfo2', 'QVCI', 'AVI' }) do
    checkBinaryTagTable('Casio.' .. t .. '(voll)', SRC .. '/Casio.lua', 'Casio.' .. t,
        LIB .. '/Image/ExifTool/Casio.pm', '%Image::ExifTool::Casio::' .. t)
end

checkTagTable('MacOS.Main', SRC .. '/MacOS.lua', 'MacOS.Main',
    LIB .. '/Image/ExifTool/MacOS.pm', '%Image::ExifTool::MacOS::Main')

local CC = LIB .. '/Image/ExifTool/CanonCustom.pm'
for _, t in ipairs({ 'Functions1D', 'Functions5D', 'Functions10D', 'Functions20D',
                     'Functions30D', 'Functions350D', 'Functions400D', 'FunctionsD30',
                     'FuncsUnknown', 'PersonalFuncs', 'PersonalFuncValues', 'Functions2' }) do
    checkTagTable('CanonCustom.' .. t, SRC .. '/CanonCustom.lua', 'CanonCustom.' .. t,
        CC, '%Image::ExifTool::CanonCustom::' .. t)
end

local RI = LIB .. '/Image/ExifTool/Ricoh.pm'
for _, t in ipairs({ 'Main', 'Type2', 'ImageInfo', 'Subdir', 'ThetaSubdir',
                     'FaceInfo', 'FirmwareInfo', 'SerialInfo', 'Text', 'RMETA',
                     'AVI', 'RDTA', 'RDTB', 'RDTC', 'RDTG', 'RDTL', 'Composite' }) do
    checkTagTable('Ricoh.' .. t, SRC .. '/Ricoh.lua', 'Ricoh.' .. t,
        RI, '%Image::ExifTool::Ricoh::' .. t)
end
checkMap('ricohLensIDs', SRC .. '/Ricoh.lua', 'local ricohLensIDs', RI, 'my %ricohLensIDs')

checkTagTable('ExifTool.Extra', REPO .. '/src/lexiftool.lua', 'ExifTool.Extra',
    LIB .. '/Image/ExifTool.pm', '%Image::ExifTool::Extra')

local FP = LIB .. '/Image/ExifTool/FlashPix.pm'
checkTagTable('FlashPix.Main', SRC .. '/FlashPix.lua', 'FlashPix.Main',
    FP, '%Image::ExifTool::FlashPix::Main')
checkTagTable('FlashPix.SummaryInfo', SRC .. '/FlashPix.lua', 'FlashPix.SummaryInfo',
    FP, '%Image::ExifTool::FlashPix::SummaryInfo')
checkTagTable('FlashPix.Extensions', SRC .. '/FlashPix.lua', 'FlashPix.Extensions',
    FP, '%Image::ExifTool::FlashPix::Extensions')
checkTagTable('FlashPix.Composite', SRC .. '/FlashPix.lua', 'FlashPix.Composite',
    FP, '%Image::ExifTool::FlashPix::Composite')
checkTagTable('FlashPix.DocumentInfo', SRC .. '/FlashPix.lua', 'FlashPix.DocumentInfo',
    FP, '%Image::ExifTool::FlashPix::DocumentInfo')
checkTagTable('FlashPix.ImageInfo', SRC .. '/FlashPix.lua', 'FlashPix.ImageInfo',
    FP, '%Image::ExifTool::FlashPix::ImageInfo')
checkTagTable('FlashPix.Image', SRC .. '/FlashPix.lua', 'FlashPix.Image',
    FP, '%Image::ExifTool::FlashPix::Image')
checkTagTable('FlashPix.SubimageHdr', SRC .. '/FlashPix.lua', 'FlashPix.SubimageHdr',
    FP, '%Image::ExifTool::FlashPix::SubimageHdr')
checkTagTable('FlashPix.DataObject', SRC .. '/FlashPix.lua', 'FlashPix.DataObject',
    FP, '%Image::ExifTool::FlashPix::DataObject')
checkTagTable('FlashPix.Transform', SRC .. '/FlashPix.lua', 'FlashPix.Transform',
    FP, '%Image::ExifTool::FlashPix::Transform')
checkTagTable('FlashPix.Operation', SRC .. '/FlashPix.lua', 'FlashPix.Operation',
    FP, '%Image::ExifTool::FlashPix::Operation')
checkTagTable('FlashPix.GlobalInfo', SRC .. '/FlashPix.lua', 'FlashPix.GlobalInfo',
    FP, '%Image::ExifTool::FlashPix::GlobalInfo')
checkTagTable('FlashPix.CompObj', SRC .. '/FlashPix.lua', 'FlashPix.CompObj',
    FP, '%Image::ExifTool::FlashPix::CompObj')
checkTagTable('FlashPix.AudioInfo', SRC .. '/FlashPix.lua', 'FlashPix.AudioInfo',
    FP, '%Image::ExifTool::FlashPix::AudioInfo')
checkTagTable('FlashPix.Contents', SRC .. '/FlashPix.lua', 'FlashPix.Contents',
    FP, '%Image::ExifTool::FlashPix::Contents')
checkTagTable('FlashPix.WordDocument', SRC .. '/FlashPix.lua', 'FlashPix.WordDocument',
    FP, '%Image::ExifTool::FlashPix::WordDocument')
checkTagTable('FlashPix.DocTable', SRC .. '/FlashPix.lua', 'FlashPix.DocTable',
    FP, '%Image::ExifTool::FlashPix::DocTable')
checkTagTable('FlashPix.DOP', SRC .. '/FlashPix.lua', 'FlashPix.DOP',
    FP, '%Image::ExifTool::FlashPix::DOP')
checkTagTable('FlashPix.PreviewInfo', SRC .. '/FlashPix.lua', 'FlashPix.PreviewInfo',
    FP, '%Image::ExifTool::FlashPix::PreviewInfo')

local JP2 = LIB .. '/Image/ExifTool/Jpeg2000.pm'
checkTagTable('Jpeg2000.Main', SRC .. '/Jpeg2000.lua', 'Jpeg2000.Main',
    JP2, '%Image::ExifTool::Jpeg2000::Main')
checkTagTable('Jpeg2000.JUMD', SRC .. '/Jpeg2000.lua', 'Jpeg2000.JUMD',
    JP2, '%Image::ExifTool::Jpeg2000::JUMD')

checkTagTable('JSON.Main', SRC .. '/JSON.lua', 'JSON.Main',
    LIB .. '/Image/ExifTool/JSON.pm', '%Image::ExifTool::JSON::Main')

for _, t in ipairs({ 'Main', 'v1', 'v1_Enh', 'v2_2', 'GEOB', 'v2_3', 'v2_4', 'SynLyrics',
                     'Private', 'Composite' }) do
    checkTagTable('ID3.' .. t, SRC .. '/ID3.lua', 'ID3.' .. t,
        LIB .. '/Image/ExifTool/ID3.pm', '%Image::ExifTool::ID3::' .. t)
end

local KD = LIB .. '/Image/ExifTool/Kodak.pm'
local KDL = SRC .. '/Kodak.lua'
for _, t in ipairs({ 'Main', 'Type3', 'Type8', 'Type10', 'Type11', 'SubIFD0', 'SubIFD1',
                     'SubIFD2', 'SubIFD3', 'SubIFD4', 'SubIFD5', 'SubIFD6', 'CameraInfo',
                     'Unknown', 'IFD', 'KDC_IFD', 'TextualInfo', 'Meta',
                     'SpecialEffects', 'Borders', 'DcMD', 'DcME', 'DcEM', 'frea', 'Scrn',
                     'pose', 'Composite' }) do
    checkTagTable('Kodak.' .. t, KDL, 'Kodak.' .. t, KD, '%Image::ExifTool::Kodak::' .. t)
end
checkBinaryTagTable('Kodak.Processing', KDL, 'Kodak.Processing',
    KD, '%Image::ExifTool::Kodak::Processing')
for _, t in ipairs({ 'Main', 'Type2', 'Type3', 'Type4', 'Type5', 'Type6', 'Type7', 'Type8', 'Type9',
                     'Type10', 'Type11', 'SubIFD0', 'SubIFD1', 'SubIFD2', 'SubIFD3', 'SubIFD4',
                     'SubIFD5', 'SubIFD6', 'CameraInfo', 'Unknown', 'IFD', 'KDC_IFD',
                     'TextualInfo', 'Meta', 'SpecialEffects', 'Borders', 'MOV', 'DcMD', 'DcME',
                     'DcEM', 'Free', 'frea', 'Scrn', 'pose', 'Composite' }) do
    checkBinaryTagTable('Kodak.' .. t .. '(voll)', KDL, 'Kodak.' .. t, KD, '%Image::ExifTool::Kodak::' .. t)
end
checkMap('Kodak.sceneModeUsed', KDL, 'local sceneModeUsed', KD, 'my %sceneModeUsed')

local CV = LIB .. '/Image/ExifTool/CanonVRD.pm'
local CVL = SRC .. '/CanonVRD.lua'
for _, t in ipairs({ 'Main', 'Edit', 'Edit4', 'IHL', 'Ver1', 'StampTool', 'Ver2', 'DLOInfo',
                     'DR4', 'DR4Header', 'ToneCurve', 'GammaInfo', 'CropInfo', 'StampInfo',
                     'DustInfo' }) do
    checkBinaryTagTable('CanonVRD.' .. t, CVL, 'CanonVRD.' .. t, CV, '%Image::ExifTool::CanonVRD::' .. t)
end
checkMap('CanonVRD.vrdFormat', CVL, 'local vrdFormat', CV, 'my %vrdFormat')

local OL = LIB .. '/Image/ExifTool/Olympus.pm'
local OLL = SRC .. '/Olympus.lua'
for _, t in ipairs({ 'Main', 'TextInfo', 'Equipment', 'CameraSettings', 'AFTargetInfo',
                     'SubjectDetectInfo', 'RawDevelopment', 'RawDevelopment2', 'RawDevSubIFD',
                     'ImageProcessing', 'FocusInfo', 'AFInfo', 'RawInfo', 'UnknownInfo',
                     'FETags', 'MOV1', 'MOV2', 'MP4', 'MOV3', 'OLYM2', 'prms', 'thmb2',
                     'scrn2', 'MovableInfo', 'Thumbnail', 'thmb', 'scrn', 'OLYM', 'AVI',
                     'WAV', 'DSS', 'Composite' }) do
    checkTagTable('Olympus.' .. t, OLL, 'Olympus.' .. t, OL, '%Image::ExifTool::Olympus::' .. t)
end

local PX = LIB .. '/Image/ExifTool/Pentax.pm'
local PXL = SRC .. '/Pentax.lua'
for _, t in ipairs({ 'Main', 'SRInfo', 'SRInfo2', 'FaceInfo', 'AWBInfo', 'TimeInfo', 'LensCorr',
                     'CameraSettings', 'AEInfo', 'AEInfo2', 'AEInfo3', 'LensRec', 'LensInfo',
                     'LensInfo2', 'LensInfo3', 'LensInfo4', 'LensInfo5', 'LensData', 'FlashInfo',
                     'CameraInfo', 'BatteryInfo', 'AFInfo', 'CAFPointInfo', 'KelvinWB', 'ColorInfo',
                     'EVStepInfo', 'ShotInfo', 'FacePos', 'FaceSize', 'FilterInfo', 'LevelInfo',
                     'LevelInfoK3III', 'FaceInfoK3III', 'AFInfoK3III', 'WBLevels', 'LensInfoQ',
                     'PixelShiftInfo', 'AFPointInfo', 'TempInfo', 'UnknownInfo', 'Type2', 'Type4',
                     'MOV', 'AVI', 'S1', 'Junk', 'PXTH', 'PENT', 'Junk2',
                     'CameraSettingsUnknown', 'AEInfoUnknown', 'FlashInfoUnknown' }) do
    checkTagTable('Pentax.' .. t, PXL, 'Pentax.' .. t, PX, '%Image::ExifTool::Pentax::' .. t)
end

local MN = LIB .. '/Image/ExifTool/Minolta.pm'
local MNL = SRC .. '/Minolta.lua'
for _, t in ipairs({ 'Main', 'CameraSettings', 'CameraSettings7D', 'CameraSettings5D',
                     'CameraInfoA100', 'ISInfoA100', 'CameraSettingsA100', 'WBInfoA100',
                     'MOV1', 'MOV2', 'MMA' }) do
    checkTagTable('Minolta.' .. t, MNL, 'Minolta.' .. t, MN, '%Image::ExifTool::Minolta::' .. t)
end

local GM_ = LIB .. '/Image/ExifTool/Garmin.pm'
local GML = SRC .. '/Garmin.lua'
for _, t in ipairs({ 'FIT', 'Common', 'Dev', 'FileID', 'FileCreator', 'TimeStampCorrelation', 'Software', 'SlaveDevice',
                      'Capabilities', 'FileCapabilities', 'MesgCapabilities', 'FieldCapabilities',
                      'DeviceSettings', 'UserProfile', 'HRMProfile', 'SDMProfile', 'BikeProfile',
                      'Connectivity', 'WatchfaceSettings', 'OHRSettings', 'TimeInZone',
                      'ZonesTarget', 'Sport', 'HRZone', 'SpeedZone', 'CadenceZone', 'PowerZone',
                      'MetZone', 'TrainingSettings', 'DiveSettings', 'DiveAlarm', 'DiveApneaAlarm',
                      'DiveGas', 'Goal', 'Activity', 'Session', 'Lap', 'Length', 'Record', 'Event',
                      'DeviceInfo', 'DeviceAuxBatteryInfo', 'TrainingFile', 'WeatherConditions',
                      'WeatherAlert', 'GPS', 'CameraEvent', 'GyroscopeData', 'AccelerometerData',
                      'MagnetometerData', 'BarometerData', 'ThreeDSensorCalibration',
                      'OneDSensorCalibration', 'VideoFrame', 'OBDIIData', 'NMEASentence',
                      'AviationAttitude', 'Video', 'VideoTitle', 'VideoDescription', 'VideoClip',
                      'Set', 'Jump', 'Split', 'SplitSummary', 'ClimbPro', 'FieldDescription',
                      'DeveloperDataID', 'Course', 'CoursePoint', 'SegmentID',
                      'SegmentLeaderboardEntry', 'SegmentPoint', 'SegmentLap', 'SegmentFile',
                      'Workout', 'WorkoutSession', 'WorkoutStep', 'ExerciseTitle', 'Schedule',
                      'Totals', 'WeightScale', 'BloodPressure', 'MonitoringInfo', 'Monitoring',
                      'MonitoringHRData', 'SPO2Data', 'HR', 'StressLevel', 'MaxMetData',
                      'HSABodyBatteryData', 'HSAEvent', 'HSAAccelerometerData', 'HSAGyroscopeData',
                      'HSAStepData', 'HSA_SPO2Data', 'HSAStressData', 'HSARespirationData',
                      'HSAHeartRateData', 'HSAConfigurationData', 'HSAWristTemperatureData',
                      'MemoGlob', 'SleepLevel', 'AntChannelID', 'AntRx', 'AntTx',
                      'ExdScreenConfiguration', 'ExdDataFieldConfiguration',
                      'ExdDataConceptConfiguration', 'DiveSummary', 'AADAccelFeatures', 'HRV',
                      'BeatIntervals', 'HRVStatusSummary', 'HRVValue', 'RawBBI', 'RespirationRate',
                      'ChronoShotSession', 'ChronoShotData', 'TankUpdate', 'TankSummary',
                      'SleepAssessment', 'SleepDisruptionSeverityPeriod',
                      'SleepDisruptionOvernightSeverity', 'NapEvent', 'SkinTempOvernight',
                      'DataScreen', 'Alert', 'RangeAlert', 'DeviceUsed', 'Location', 'MapLayer',
                      'Routing', 'UserMetrics', 'DeviceStatus', 'BestEffort', 'PersonalRecord',
                      'ActivityMetrics', 'MultisportSettings', 'MultisportActivity',
                      'SensorSettings', 'Metronome', 'ConnectIQField', 'Clubs', 'WaypointHandling',
                      'GolfCourse', 'GolfStats', 'Score', 'Hole', 'Shot', 'AlarmSettings',
                      'MusicInfo', 'SleepDataInfo', 'MtbCx', 'Race', 'SplitTime', 'PowerMode',
                      'GPSEvent', 'FunctionalMetrics', 'RaceEvent', 'TrainingReadiness',
                      'TrainingLoad', 'SleepSchedule', 'SleepRestlessMoments', 'WorkoutSchedule',
                      'EPOStatus', 'OpenWaterEvent', 'ECGSummary', 'ECGRawSample',
                      'ECGSmoothSample', 'CPEStatus', 'HillScore', 'EnduranceScore' }) do
    checkTagTable('Garmin.' .. t, GML, 'Garmin.' .. t, GM_, '%Image::ExifTool::Garmin::' .. t)
end
for _, m in ipairs({ 'file', 'mesgNum', 'fileFlags', 'mesgCount', 'gender', 'language', 'displayMeasure', 'displayHeart',
                      'displayPower', 'displayPosition', 'switch', 'sportEnum', 'subSport',
                      'sportEvent', 'activityEnum', 'intensity', 'sessionTrigger', 'lapTrigger',
                      'backlightMode', 'dateMode', 'backlightTimeout', 'eventEnum', 'eventType',
                      'tone', 'activityClass', 'hRZoneCalc', 'pwrZoneCalc', 'wktStepDuration',
                      'wktStepTarget', 'goalEnum', 'goalRecurrence', 'goalSource', 'scheduleEnum',
                      'coursePointEnum', 'manufacturer', 'antNetwork', 'workoutCapabilities',
                      'batteryStatus', 'hRType', 'courseCapabilities', 'bpStatus', 'swimStroke',
                      'activityType', 'activitySubtype', 'activityLevel', 'side', 'lengthType',
                      'dayOfWeek', 'connectivityCapabilities', 'weatherReport', 'weatherStatus',
                      'weatherSeverity', 'weatherSevereType', 'strokeType', 'bodyLocation',
                      'segmentLapStatus', 'segmentLeaderboardType', 'segmentDeleteStatus',
                      'segmentSelectionType', 'sourceType', 'displayOrientation',
                      'workoutEquipment', 'watchfaceMode', 'cameraEventType', 'sensorType',
                      'cameraOrientationType', 'autoSyncFrequency', 'exdLayout', 'exdDisplayType',
                      'exdDataUnits', 'exdQualifiers', 'exdDescriptors', 'fitBaseType',
                      'fitBaseUnit', 'setType', 'maxMetCategory', 'exerciseCategory', 'waterType',
                      'tissueModelType', 'diveGasStatus', 'diveAlarmType', 'diveBacklightMode',
                      'sleepLevelEnum', 'sPO2MeasurementType', 'cCRSetpointSwitchMode',
                      'diveGasMode', 'projectileType', 'splitType', 'climbProEvent',
                      'gasConsumptionRateType', 'tapSensitivity', 'radarThreatLevelType',
                      'sleepDisruptionSeverity', 'napPeriodFeedback', 'napSource',
                      'maxMetSpeedSource', 'maxMetHeartRateSource', 'hRVStatus', 'noFlyTimeMode',
                      'alarmLabel', 'alarmRepeat', 'alertMetric', 'alertZone', 'allow',
                      'autoLapMode', 'autoPauseSetting', 'autoScrollMode', 'avoidances', 'benefit',
                      'calculationMethod', 'climbDetection', 'climbProMode', 'climbProTerrain',
                      'connectionType', 'courseRecalculation', 'courses', 'dataFields',
                      'enduranceScoreLevel', 'ePOCPEStatus', 'fairway', 'genderX', 'gPSType',
                      'guideText', 'hillScoreLevel', 'lightSectorsStatus', 'mapSymbol',
                      'navigationPrompt', 'openWaterEventType', 'orientation', 'powerAveraging',
                      'powerSaveTimeout', 'recordMetric', 'reliefShading', 'routeRecalculation',
                      'routingMode', 'routingType', 'runningPowerMode', 'satellites', 'screenType',
                      'selfEvaluationStatus', 'soundAndVibe', 'sportChange', 'touchStatus',
                      'trainingReadinessLevel', 'useStatus', 'visibilityStatus', 'volume',
                      'waypointAction', 'windDataStatus', 'yesNo', 'zoneMetric' }) do
    checkMap(m, GML, 'local ' .. m, GM_, 'my %' .. m)
end

local SY = LIB .. '/Image/ExifTool/Sony.pm'
for _, t in ipairs({ 'Main', 'Ericsson', 'MoreInfo', 'SRF', 'SRF2', 'SR2Private', 'SR2SubIFD',
                     'SR2DataIFD', 'PIC', 'rtmd', 'Composite' }) do
    checkTagTable('Sony.' .. t, SRC .. '/Sony.lua', 'Sony.' .. t, SY, '%Image::ExifTool::Sony::' .. t)
end
for _, t in ipairs({ 'CameraInfo', 'CameraInfo2', 'CameraInfo3', 'CameraInfoUnknown', 'FocusInfo',
                     'MoreInfo0201', 'MoreInfo0401', 'MoreSettings', 'FaceInfo', 'FaceInfoA',
                     'CameraSettings', 'CameraSettings2', 'CameraSettings3', 'CameraSettingsUnknown',
                     'ExtraInfo', 'ExtraInfo2', 'ExtraInfo3', 'HiddenInfo', 'ShotInfo',
                     'Tag2010a', 'Tag2010b', 'Tag2010c', 'Tag2010d', 'Tag2010e', 'Tag2010f',
                     'Tag2010g', 'Tag2010h', 'Tag2010i', 'Tag202a', 'MeterInfo', 'MeterInfo9',
                     'Tag900b', 'Tag9050a', 'Tag9050b', 'Tag9050c', 'Tag9050d', 'Tag9400a',
                     'Tag9400b', 'Tag9400c', 'Tag9401', 'ISOInfo', 'Tag9402', 'Tag9403',
                     'Tag9404a', 'Tag9404b', 'Tag9404c', 'Tag9405a', 'Tag9405b', 'Tag9406',
                     'Tag9406b', 'Tag940a', 'Tag940c', 'AFInfo', 'Tag940e', 'AFStatus15',
                     'AFStatus19', 'AFStatus79', 'Tag9416', 'FaceInfo1', 'FaceInfo2', 'Panorama',
                     'PMP' }) do
    checkBinaryTagTable('Sony.' .. t, SRC .. '/Sony.lua', 'Sony.' .. t, SY, '%Image::ExifTool::Sony::' .. t)
end

local FJ = LIB .. '/Image/ExifTool/FujiFilm.pm'
for _, t in ipairs({ 'Main', 'FaceRecInfo', 'RAF', 'IFD', 'MRAW' }) do
    checkTagTable('FujiFilm.' .. t, SRC .. '/FujiFilm.lua', 'FujiFilm.' .. t, FJ, '%Image::ExifTool::FujiFilm::' .. t)
end
for _, t in ipairs({ 'PrioritySettings', 'FocusSettings', 'AFCSettings', 'DriveSettings', 'RAFHeader',
                     'RAFData', 'FFMV', 'MOV' }) do
    checkBinaryTagTable('FujiFilm.' .. t, SRC .. '/FujiFilm.lua', 'FujiFilm.' .. t, FJ, '%Image::ExifTool::FujiFilm::' .. t)
end
checkMap('testedRAF', SRC .. '/FujiFilm.lua', 'local testedRAF', FJ, 'my %testedRAF')

for _, t in ipairs({ 'Main', 'Leica2', 'Leica3', 'SerialInfo', 'Leica4', 'Subdir', 'TimeInfo',
                     'Data1', 'Data2', 'Leica5', 'ShotInfo', 'FocusInfo', 'Leica6', 'Leica9',
                     'Type2', 'FaceDetInfo', 'FaceRecInfo', 'PANA', 'DSA' }) do
    checkTagTable('Panasonic.' .. t, SRC .. '/Panasonic.lua', 'Panasonic.' .. t,
        LIB .. '/Image/ExifTool/Panasonic.pm', '%Image::ExifTool::Panasonic::' .. t)
end
checkMap('leicaLensTypes', SRC .. '/Panasonic.lua', 'local leicaLensTypes',
    LIB .. '/Image/ExifTool/Panasonic.pm', '%leicaLensTypes')
checkMap('frameSelectorBits', SRC .. '/Panasonic.lua', 'local frameSelectorBits',
    LIB .. '/Image/ExifTool/Panasonic.pm', 'my %frameSelectorBits')

checkTagTable('PICT.Main', SRC .. '/PICT.lua', 'PICT.Main',
    LIB .. '/Image/ExifTool/PICT.pm', '%Image::ExifTool::PICT::Main')

checkTagTable('MXF.Main', SRC .. '/MXF.lua', 'MXF.Main',
    LIB .. '/Image/ExifTool/MXF.pm', '%Image::ExifTool::MXF::Main')

checkTagTable('DICOM.Main', SRC .. '/DICOM.lua', 'DICOM.Main',
    LIB .. '/Image/ExifTool/DICOM.pm', '%Image::ExifTool::DICOM::Main')

for _, t in ipairs({ 'Main', 'IFD', 'Type2', 'OrientationInfo', 'PictureWizard', 'INFO',
                     'MP4', 'Thumbnail', 'sec', 'smta', 'svss', 'Thumbnail2', 'APP5',
                     'DualShotExtra', 'SingleShotMeta', 'ReEditData', 'ClipInfo',
                     'ToneInfo', 'EffectInfo', 'PortraitEffect', 'PEgInfo',
                     'Composite' }) do
    checkTagTable('Samsung.' .. t, SRC .. '/Samsung.lua', 'Samsung.' .. t,
        LIB .. '/Image/ExifTool/Samsung.pm', '%Image::ExifTool::Samsung::' .. t)
end

checkTagTable('Samsung.Trailer', SRC .. '/Samsung.lua', 'Samsung.Trailer',
    LIB .. '/Image/ExifTool/Samsung.pm', '%Image::ExifTool::Samsung::Trailer')

checkTagTable('Trailer.Vivo', SRC .. '/Trailer.lua', 'Trailer.Vivo',
    LIB .. '/Image/ExifTool/Trailer.pm', '%Image::ExifTool::Trailer::Vivo')
checkTagTable('Trailer.OnePlus', SRC .. '/Trailer.lua', 'Trailer.OnePlus',
    LIB .. '/Image/ExifTool/Trailer.pm', '%Image::ExifTool::Trailer::OnePlus')
checkTagTable('Photoshop.DocumentData', SRC .. '/Photoshop.lua', 'Photoshop.DocumentData',
    LIB .. '/Image/ExifTool/Photoshop.pm', '%Image::ExifTool::Photoshop::DocumentData')
checkTagTable('Microsoft.Stitch', SRC .. '/Microsoft.lua', 'Microsoft.Stitch',
    LIB .. '/Image/ExifTool/Microsoft.pm', '%Image::ExifTool::Microsoft::Stitch')
checkTagTable('Sanyo.Thumbnail', SRC .. '/Sanyo.lua', 'Sanyo.Thumbnail',
    LIB .. '/Image/ExifTool/Sanyo.pm', '%Image::ExifTool::Sanyo::Thumbnail')
for _, t in ipairs({ 'Main', 'CameraIFD', 'Composite' }) do
    checkTagTable('PanasonicRaw.' .. t, SRC .. '/PanasonicRaw.lua', 'PanasonicRaw.' .. t,
        LIB .. '/Image/ExifTool/PanasonicRaw.pm', '%Image::ExifTool::PanasonicRaw::' .. t)
end
for _, t in ipairs({ 'Main', 'WBInfo', 'WBInfo2', 'DistortionInfo', 'CameraIFD', 'Composite' }) do
    checkBinaryTagTable('PanasonicRaw.' .. t .. '(voll)', SRC .. '/PanasonicRaw.lua', 'PanasonicRaw.' .. t,
        LIB .. '/Image/ExifTool/PanasonicRaw.pm', '%Image::ExifTool::PanasonicRaw::' .. t)
end
checkMap('jpgFromRawMap', SRC .. '/PanasonicRaw.lua', 'local jpgFromRawMap',
    LIB .. '/Image/ExifTool/PanasonicRaw.pm', 'my %jpgFromRawMap')
checkMap('panasonicWhiteBalance', SRC .. '/PanasonicRaw.lua', 'local panasonicWhiteBalance',
    LIB .. '/Image/ExifTool/PanasonicRaw.pm', 'my %panasonicWhiteBalance')
for _, t in ipairs({ 'OriginalRaw', 'ImageSeq', 'ProfileDynamicRange' }) do
    checkTagTable('DNG.' .. t, SRC .. '/DNG.lua', 'DNG.' .. t,
        LIB .. '/Image/ExifTool/DNG.pm', '%Image::ExifTool::DNG::' .. t)
end

local PSP = LIB .. '/Image/ExifTool/PSP.pm'
checkTagTable('PSP.Main', SRC .. '/PSP.lua', 'PSP.Main',
    PSP, '%Image::ExifTool::PSP::Main')
checkTagTable('PSP.Image', SRC .. '/PSP.lua', 'PSP.Image',
    PSP, '%Image::ExifTool::PSP::Image')
checkTagTable('PSP.Creator', SRC .. '/PSP.lua', 'PSP.Creator',
    PSP, '%Image::ExifTool::PSP::Creator')
checkTagTable('PSP.Ext', SRC .. '/PSP.lua', 'PSP.Ext',
    PSP, '%Image::ExifTool::PSP::Ext')

local IR = LIB .. '/Image/ExifTool/InfiRay.pm'
checkTagTable('InfiRay.Version', SRC .. '/InfiRay.lua', 'InfiRay.Version',
    IR, '%Image::ExifTool::InfiRay::Version')
checkTagTable('InfiRay.Factory', SRC .. '/InfiRay.lua', 'InfiRay.Factory',
    IR, '%Image::ExifTool::InfiRay::Factory')
checkTagTable('InfiRay.Picture', SRC .. '/InfiRay.lua', 'InfiRay.Picture',
    IR, '%Image::ExifTool::InfiRay::Picture')
checkTagTable('InfiRay.MixMode', SRC .. '/InfiRay.lua', 'InfiRay.MixMode',
    IR, '%Image::ExifTool::InfiRay::MixMode')
checkTagTable('InfiRay.OpMode', SRC .. '/InfiRay.lua', 'InfiRay.OpMode',
    IR, '%Image::ExifTool::InfiRay::OpMode')
checkTagTable('InfiRay.Isothermal', SRC .. '/InfiRay.lua', 'InfiRay.Isothermal',
    IR, '%Image::ExifTool::InfiRay::Isothermal')
checkTagTable('InfiRay.Sensor', SRC .. '/InfiRay.lua', 'InfiRay.Sensor',
    IR, '%Image::ExifTool::InfiRay::Sensor')

local WT = LIB .. '/Image/ExifTool/WTV.pm'
checkTagTable('WTV.Main', SRC .. '/WTV.lua', 'WTV.Main',
    WT, '%Image::ExifTool::WTV::Main')
checkTagTable('WTV.Metadata', SRC .. '/WTV.lua', 'WTV.Metadata',
    WT, '%Image::ExifTool::WTV::Metadata')

local RD = LIB .. '/Image/ExifTool/Red.pm'
checkTagTable('Red.Main', SRC .. '/Red.lua', 'Red.Main',
    RD, '%Image::ExifTool::Red::Main')
checkTagTable('Red.RED1', SRC .. '/Red.lua', 'Red.RED1',
    RD, '%Image::ExifTool::Red::RED1')
checkTagTable('Red.RED2', SRC .. '/Red.lua', 'Red.RED2',
    RD, '%Image::ExifTool::Red::RED2')

local MC = LIB .. '/Image/ExifTool/MRC.pm'
checkTagTable('MRC.Main', SRC .. '/MRC.lua', 'MRC.Main',
    MC, '%Image::ExifTool::MRC::Main')
checkTagTable('MRC.FEI12', SRC .. '/MRC.lua', 'MRC.FEI12',
    MC, '%Image::ExifTool::MRC::FEI12')

local PL = LIB .. '/Image/ExifTool/Palm.pm'
checkTagTable('Palm.Main', SRC .. '/Palm.lua', 'Palm.Main',
    PL, '%Image::ExifTool::Palm::Main')
checkTagTable('Palm.MOBI', SRC .. '/Palm.lua', 'Palm.MOBI',
    PL, '%Image::ExifTool::Palm::MOBI')
checkTagTable('Palm.EXTH', SRC .. '/Palm.lua', 'Palm.EXTH',
    PL, '%Image::ExifTool::Palm::EXTH')

checkTagTable('PhotoCD.Main', SRC .. '/PhotoCD.lua', 'PhotoCD.Main',
    LIB .. '/Image/ExifTool/PhotoCD.pm', '%Image::ExifTool::PhotoCD::Main')

local RL = LIB .. '/Image/ExifTool/Real.pm'
checkTagTable('Real.Media', SRC .. '/Real.lua', 'Real.Media',
    RL, '%Image::ExifTool::Real::Media')
checkTagTable('Real.Audio', SRC .. '/Real.lua', 'Real.Audio',
    RL, '%Image::ExifTool::Real::Audio')
checkTagTable('Real.Metafile', SRC .. '/Real.lua', 'Real.Metafile',
    RL, '%Image::ExifTool::Real::Metafile')
checkTagTable('Real.Properties', SRC .. '/Real.lua', 'Real.Properties',
    RL, '%Image::ExifTool::Real::Properties')
checkTagTable('Real.MediaProps', SRC .. '/Real.lua', 'Real.MediaProps',
    RL, '%Image::ExifTool::Real::MediaProps')
checkTagTable('Real.FileInfo', SRC .. '/Real.lua', 'Real.FileInfo',
    RL, '%Image::ExifTool::Real::FileInfo')
checkTagTable('Real.ContentDescr', SRC .. '/Real.lua', 'Real.ContentDescr',
    RL, '%Image::ExifTool::Real::ContentDescr')
checkTagTable('Real.Metadata', SRC .. '/Real.lua', 'Real.Metadata',
    RL, '%Image::ExifTool::Real::Metadata')
checkTagTable('Real.AudioV3', SRC .. '/Real.lua', 'Real.AudioV3',
    RL, '%Image::ExifTool::Real::AudioV3')
checkTagTable('Real.AudioV4', SRC .. '/Real.lua', 'Real.AudioV4',
    RL, '%Image::ExifTool::Real::AudioV4')
checkTagTable('Real.AudioV5', SRC .. '/Real.lua', 'Real.AudioV5',
    RL, '%Image::ExifTool::Real::AudioV5')

local NI = LIB .. '/Image/ExifTool/Nintendo.pm'
checkTagTable('Nintendo.Main', SRC .. '/Nintendo.lua', 'Nintendo.Main',
    NI, '%Image::ExifTool::Nintendo::Main')
checkTagTable('Nintendo.CameraInfo', SRC .. '/Nintendo.lua', 'Nintendo.CameraInfo',
    NI, '%Image::ExifTool::Nintendo::CameraInfo')
checkTagTable('SonyIDC.Main', SRC .. '/SonyIDC.lua', 'SonyIDC.Main',
    LIB .. '/Image/ExifTool/SonyIDC.pm', '%Image::ExifTool::SonyIDC::Main')
checkTagTable('NikonSettings.Main', SRC .. '/NikonSettings.lua', 'NikonSettings.Main',
    LIB .. '/Image/ExifTool/NikonSettings.pm', '%Image::ExifTool::NikonSettings::Main')

local NC = LIB .. '/Image/ExifTool/NikonCustom.pm'
local NCL = SRC .. '/NikonCustom.lua'
for _, t in ipairs({ 'SettingsD80', 'SettingsD40', 'SettingsD90',
                     'SettingsD3', 'SettingsD700', 'SettingsD800',
                     'SettingsD5', 'SettingsD500', 'SettingsD610', 'SettingsD810',
                     'SettingsD850', 'SettingsD5000', 'SettingsD5100', 'SettingsD5200',
                     'SettingsD7000', 'SettingsD4',
                     'SettingsZ6III', 'SettingsZ8', 'SettingsZ9', 'SettingsZ9v4' }) do
    checkBinaryTagTable('NikonCustom.' .. t, NCL, 'NikonCustom.' .. t,
        NC, '%Image::ExifTool::NikonCustom::' .. t)
end

local NCP = LIB .. '/Image/ExifTool/NikonCapture.pm'
local NCPL = SRC .. '/NikonCapture.lua'
checkTagTable('NikonCapture.Main', NCPL, 'NikonCapture.Main', NCP, '%Image::ExifTool::NikonCapture::Main')
for _, t in ipairs({ 'UnsharpData', 'DLightingHS', 'DLightingHQ', 'ColorBoost', 'WBAdjData',
                     'PhotoEffects', 'Brightness', 'NoiseReduction', 'CropData', 'PictureCtrl',
                     'RedEyeData', 'Exposure', 'HighlightData' }) do
    checkBinaryTagTable('NikonCapture.' .. t, NCPL, 'NikonCapture.' .. t,
        NCP, '%Image::ExifTool::NikonCapture::' .. t)
end
checkMap('NikonCapture.unsharpColor', NCPL, 'local unsharpColor', NCP, 'my %unsharpColor')

local NK = LIB .. '/Image/ExifTool/Nikon.pm'
local NKL = SRC .. '/Nikon.lua'
for _, t in ipairs({ 'ShotInfo', 'ShotInfoD40', 'ShotInfoD80', 'ShotInfoD90',
                     'ShotInfoD3a', 'ShotInfoD3b', 'ShotInfoD3X', 'ShotInfoD3S',
                     'ShotInfoD300a', 'ShotInfoD300b', 'ShotInfoD300S',
                     'ShotInfoD700', 'ShotInfoD780', 'ShotInfoD5000',
                     'ShotInfoD5100', 'ShotInfoD5200', 'ShotInfoD7000',
                     'ShotInfoD7500', 'ShotInfoD800', 'ShotInfoD500',
                     'ShotInfoD6', 'ShotInfoD610', 'ShotInfoD810',
                     'ShotInfoD850', 'ShotInfoD4', 'ShotInfoD4S',
                     'ShotInfoZ6III', 'ShotInfoZ7II', 'ShotInfoZ8',
                     'ShotInfoZ9',
                     'RotationInfoD500', 'JPGInfoD500', 'BracketingInfoD500',
                     'ShootingMenuD500', 'CustomSettingsD500', 'OtherInfoD500',
                     'SeqInfoD6', 'IntervalInfoD6',
                     'SettingsInfoD810', 'BracketingInfoD810', 'ISOAutoInfoD810',
                     'MenuSettingsD850', 'MoreSettingsD850',
                     'IntervalInfoZ7II', 'PortraitInfoZ7II', 'MenuInfoZ7II',
                     'SeqInfoZ9', 'Offset13InfoZ9', 'MenuInfoZ8', 'MenuInfoZ9',
                     'AutoCaptureInfo', 'OrientationInfo', 'MenuSettingsZ6III',
                     'MenuSettingsZ7II', 'MenuSettingsZ8', 'MenuSettingsZ8v1',
                     'MenuSettingsZ8v2', 'MenuSettingsZ9', 'MenuSettingsZ9v3',
                     'MenuSettingsZ9v4',
                     'LensData00', 'LensData01', 'LensData0204', 'LensData0400',
                     'LensData0402', 'LensData0403', 'LensData0800', 'LensDataUnknown',
                     'FlashInfo0100', 'FlashInfo0102', 'FlashInfo0103', 'FlashInfo0106',
                     'FlashInfo0107', 'FlashInfo0300', 'FlashInfoUnknown',
                     'DistortionInfo', 'VignetteInfo',
                     'ROC', 'GEM', 'VRInfo', 'FaceDetect', 'PictureControl', 'PictureControl2',
                     'PictureControl3', 'PictureControlUnknown', 'WorldTime', 'ISOInfo',
                     'DistortInfo', 'UnknownInfo', 'UnknownInfo2', 'AFInfo',
                     'AFInfo2V0100', 'AFInfo2V0101', 'AFInfo2V0200', 'AFInfo2V0300', 'AFInfo2V0400',
                     'AFTune', 'RetouchInfo', 'FileInfo', 'BarometerInfo', 'CaptureOutput',
                     'ColorBalanceA', 'ColorBalanceB', 'ColorBalanceC', 'ColorBalance1',
                     'ColorBalance2', 'ColorBalance3', 'ColorBalance4', 'ColorBalanceUnknown',
                     'ColorBalanceUnknown2', 'MultiExposure', 'MultiExposure2', 'HDRInfo',
                     'HDRInfo2', 'LocationInfo', 'MakerNotes0x51', 'MakerNotes0x56', 'MOV',
                     'NCDT', 'NCDB' }) do
    checkBinaryTagTable('Nikon.' .. t, NKL, 'Nikon.' .. t,
        NK, '%Image::ExifTool::Nikon::' .. t)
end
for _, t in ipairs({ 'Main', 'Scan', 'CaptureOffsets', 'PreviewIFD', 'NCTG',
                     'Type2', 'NEFInfo', 'AVI', 'AVIVers', 'AVITags' }) do
    checkTagTable('Nikon.' .. t, NKL, 'Nikon.' .. t,
        NK, '%Image::ExifTool::Nikon::' .. t)
end

print('=== Lookup Maps ===')
for _, m in ipairs({ 'flashFirmware', 'flashGNDistance', 'flashColorFilter', 'flashControlMode',
                     'activeDLightingZ7', 'aFAreaModeCD', 'aFAreaModePD', 'aFAreaModeZ9',
                     'aFDetectionMethod', 'banksZ9', 'bracketIncrementZ9', 'bracketSetZ9',
                     'bracketProgramZ9', 'dialsFrameAdvanceZoomPositionZ9', 'dynamicAfAreaModesZ9',
                     'flashControlModeZ7', 'flashRemoteControlZ7', 'flashWirelessOptionZ7',
                     'focusModeZ7', 'hDMIOutputResolutionZ9', 'hdrLevelZ8', 'highFrameRateZ9',
                     'imageAreaD6', 'imageAreaZ9', 'imageAreaZ9b', 'iSOAutoHiLimitZ6III',
                     'iSOAutoShutterTimeZ9', 'languageZ9', 'meteringModeZ7', 'monitorBrightnessZ9',
                     'movieFlickerReductionZ9', 'movieFrameRateZ6III', 'movieFrameRateZ7',
                     'movieFrameSizeZ9', 'movieSlowMotion', 'movieToneMapZ9', 'movieTypeZ9',
                     'multipleExposureModeZ9', 'offLowNormalHighZ7', 'pixelShiftDelay',
                     'pixelShiftNumberShots', 'portraitImpressionBalanceZ8', 'releaseModeZ7',
                     'secondarySlotFunctionZ9', 'subjectDetectionAreaMZ6III', 'subjectDetectionZ9',
                     'timeZoneZ9', 'vRModeZ9', 'retouchValues', 'afPoints11', 'afPoints51',
                     'afPoints39', 'afPoints105', 'afPoints135', 'afPoints153', 'afPoints81',
                     'cropHiSpeed', 'flashGroupOptionsMode', 'nefCompression' }) do
    checkMap('Nikon.' .. m, NKL, 'local ' .. m, NK, 'my %' .. m)
end
checkMap('Nikon.nikonTextEncoding', NKL, 'Nikon.nikonTextEncoding', NK, '%nikonTextEncoding')
checkMap('Nikon.nikonLensIDs', NKL, 'Nikon.nikonLensIDs', NK, '%nikonLensIDs')
local E = LIB .. '/Image/ExifTool/Exif.pm'
local I = LIB .. '/Image/ExifTool/ICC_Profile.pm'
checkMap('compression', SRC .. '/Exif.lua', 'Exif.compression', E, '%compression')
checkMap('photometric', SRC .. '/Exif.lua', 'Exif.photometricInterpretation', E, '%photometricInterpretation')
checkMap('orientation', SRC .. '/Exif.lua', 'Exif.orientation', E, '%orientation')
checkMap('subfileType', SRC .. '/Exif.lua', 'Exif.subfileType', E, '%subfileType')
checkMap('formatNumber', SRC .. '/Exif.lua', 'Exif.formatNumber', E, '%formatNumber')
checkMap('intFormat', SRC .. '/Exif.lua', 'Exif.intFormat', E, '%intFormat')
checkMap('manuSig', SRC .. '/ICC_Profile.lua', 'manuSig', I, 'my %manuSig')
checkMap('profileClass', SRC .. '/ICC_Profile.lua', 'profileClass', I, 'my %profileClass')
checkMap('illuminantType', SRC .. '/ICC_Profile.lua', 'illuminantType', I, 'my %illuminantType')
checkMap('yCbCrSubSampling', SRC .. '/JPEG.lua', 'JPEG.yCbCrSubSampling',
    LIB .. '/Image/ExifTool.pm', '%Image::ExifTool::JPEG::yCbCrSubSampling')
checkMap('GraphConv', SRC .. '/JPEG.lua', 'JPEG.GraphConv',
    LIB .. '/Image/ExifTool/JPEG.pm', '%Image::ExifTool::JPEG::GraphConv')
checkMap('PrintConv', SRC .. '/JPEGDigest.lua', 'local PrintConv',
    LIB .. '/Image/ExifTool/JPEGDigest.pm', 'my %PrintConv')
checkMap('codePage', SRC .. '/Microsoft.lua', 'Microsoft.codePage',
    LIB .. '/Image/ExifTool/Microsoft.pm', '%codePage')
local NS = LIB .. '/Image/ExifTool/NikonSettings.pm'
for _, m in ipairs({ 'funcButtonZ6', 'funcButtonZ7m2', 'flickUpDownD6', 'flickUpDownRatingD6',
                     'groupAreaCustom', 'iSOAutoHiLimitD6', 'iSOAutoHiLimitZ7', 'lensFuncButtonZ7m2',
                     'limtReleaseModeSel', 'menuBank', 'previewButtonD6', 'releaseFocus',
                     'tagMultiSelector', 'tagSecondarySlotFunction', 'tagSubSelector', 'thirdHalfFull',
                     'times4s10s20s1m5m20m' }) do
    checkMap(m, SRC .. '/NikonSettings.lua', m, NS, 'my %' .. m)
end
for _, m in ipairs({ 'olympusLensTypes', 'olympusCameraTypes' }) do
    checkMap(m, SRC .. '/Olympus.lua', 'local ' .. m, LIB .. '/Image/ExifTool/Olympus.pm', 'my %' .. m)
end
-- (%minoltaLensTypes/%minoltaTeleconverters/%minoltaSceneMode are used by
--  Sony.lua as well, so they are module fields)
for _, m in ipairs({ 'metabonesID', 'minoltaLensTypes', 'minoltaTeleconverters', 'minoltaSceneMode' }) do
    checkMap(m, SRC .. '/Minolta.lua', 'Minolta.' .. m, LIB .. '/Image/ExifTool/Minolta.pm', '%' .. m)
end
checkMap('sonyLensTypes2', SRC .. '/Sony.lua', 'Sony.sonyLensTypes2',
    LIB .. '/Image/ExifTool/Sony.pm', '%sonyLensTypes2')
for _, m in ipairs({ 'sonyExposureProgram', 'sonyExposureProgram2', 'sonyExposureProgram3',
                     'whiteBalanceSetting', 'afPoint15', 'afPoint19', 'isoSetting2010' }) do
    checkMap(m, SRC .. '/Sony.lua', 'local ' .. m, LIB .. '/Image/ExifTool/Sony.pm', 'my %' .. m)
end
checkMap('uid', SRC .. '/DICOM.lua', 'local uid',
    LIB .. '/Image/ExifTool/DICOM.pm', '%uid')
-- BuildTagLookup's own maps (%riffSpec and %xmpSpec pack several entries per
-- line, as upstream does, so those two are compared by each line's first one)
for _, m in ipairs({ 'tweakOrder', 'formatOK', 'riffSpec', 'xmpSpec' }) do
    checkMap('BuildTagLookup.' .. m, SRC .. '/BuildTagLookup.lua', 'local ' .. m,
        LIB .. '/Image/ExifTool/BuildTagLookup.pm', 'my %' .. m)
end

-- %minoltaColorMode/%sonyColorMode are exported (MinoltaRaw.lua uses them),
-- so they are module fields
checkMap('minoltaColorMode', SRC .. '/Minolta.lua', 'Minolta.minoltaColorMode',
    LIB .. '/Image/ExifTool/Minolta.pm', '%minoltaColorMode')
checkMap('sonyColorMode', SRC .. '/Minolta.lua', 'Minolta.sonyColorMode',
    LIB .. '/Image/ExifTool/Minolta.pm', '%sonyColorMode')
for _, m in ipairs({ 'exposureIndicator' }) do
    checkMap(m, SRC .. '/Minolta.lua', 'local ' .. m, LIB .. '/Image/ExifTool/Minolta.pm', 'my %' .. m)
end

-- NikonCustom's lookups: %buttonsCommonZ8Z9 is spread into %buttonsZ8 and
-- %buttonsZ9, so it is compared first and then handed to the two as the
-- spread source; %buttonsZ8/%buttonsZ9/%buttonsZ6III/%powerOffDelayTimesZ9
-- are spread into tag entries and are helper functions in the port.
local luaSpreads, perlSpreads = {}, {}
luaSpreads.buttonsCommonZ8Z9, perlSpreads.buttonsCommonZ8Z9 =
    checkCustomMap('NikonCustom.buttonsCommonZ8Z9', NCL, 'local buttonsCommonZ8Z9 = {',
        NC, 'my %buttonsCommonZ8Z9 = (', luaSpreads, perlSpreads)
for _, s in ipairs({
    { 'buttonsZ8',               'function NikonCustom.buttonsZ8(t)',    '%buttonsZ8 = (' },
    { 'buttonsZ9',               'function NikonCustom.buttonsZ9(t)',    '%buttonsZ9= (' },
    { 'buttonsZ6III',            'local function buttonsZ6III(t)',       'my %buttonsZ6III= (' },
    { 'dialsZ9',                 'local dialsZ9 = {',                    'my %dialsZ9 = (' },
    { 'dialsVideoZ9',            'local dialsVideoZ9 = {',               'my %dialsVideoZ9 = (' },
    { 'evfGridsZ9',              'local evfGridsZ9 = {',                 'my %evfGridsZ9 = (' },
    { 'flicksZ9',                'local flicksZ9 = {',                   'my %flicksZ9 = (' },
    { 'focusModeRestrictionsZ9', 'local focusModeRestrictionsZ9 = {',    'my %focusModeRestrictionsZ9 = (' },
    { 'powerOffDelayTimesZ9',    'local function powerOffDelayTimesZ9(t)', 'my %powerOffDelayTimesZ9 = (' },
    { 'thirdHalfFull',           'local thirdHalfFull = {',              'my %thirdHalfFull = (' },
    { 'touchFnAreaZ6III',        'local touchFnAreaZ6III = {',           'my %touchFnAreaZ6III = (' },
    { 'limitNolimit',            'local limitNolimit = {',               'my %limitNolimit = (' },
    { 'offOn',                   'local offOn = {',                      'my %offOn = (' },
    { 'onOff',                   'local onOff = {',                      'my %onOff = (' },
    { 'noYes',                   'local noYes = {',                      'my %noYes = (' },
}) do
    checkCustomMap('NikonCustom.' .. s[1], NCL, s[2], NC, s[3], luaSpreads, perlSpreads)
end

print('=== File Type Tables ===')
checkFileTypeLookup('fileTypeLookup', REPO .. '/src/lexiftool.lua', 'fileTypeLookup',
    LIB .. '/Image/ExifTool.pm', '%fileTypeLookup')
checkMap('mimeType', REPO .. '/src/lexiftool.lua', 'mimeType',
    LIB .. '/Image/ExifTool.pm', '%mimeType')
checkMap('fileTypeExt', REPO .. '/src/lexiftool.lua', 'fileTypeExt',
    LIB .. '/Image/ExifTool.pm', 'my %fileTypeExt')

print('=== Nested PrintConvs ===')
checkNestedMap('tech.PrintConv', SRC .. '/ICC_Profile.lua', 'ICC.Main', 'tech',
    I, '%Image::ExifTool::ICC_Profile::Main', 'tech')

print('=== Conditional Lists ===')
checkConditionalLists()

print('=== Conv Shapes ===')
checkConvShapes()

print('=== Fields ===')
checkFields()

if problems > 0 then
    print(string.format('\nProblems: %d', problems))
    os.exit(1)
end
print('\nAll checks passed.')
