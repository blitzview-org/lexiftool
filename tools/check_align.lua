--------------------------------------------------------------------------------
-- File:         tools/check_align.lua
--
-- Description:  compare table-entry alignment style between the vendored
--               upstream Perl files and their ported Lua counterparts
--------------------------------------------------------------------------------

-- For every run of consecutive table-entry lines (Perl `key => value`, Lua
-- `[key] = value`) the script records:
--   * whether the operator (`=>` / `=`) sits at a common column across the
--     run ("col<N>") or is ragged,
--   * whether entries use the packed single-space style ("single-spc"),
--   * whether trailing reference-cite comments start at a common column
--     ("cmt@<N>") or are ragged.
-- It prints a compact per-file run list (runs with a single entry carry no
-- alignment information and are skipped) so the P(perl) and L(ua) lists can
-- be scanned side by side: any style difference marks a spot where the port
-- drifted from the upstream layout. Tabs in the Lua files are flagged too.
--
-- Run from anywhere: the repository root is resolved by walking up from this
-- file until `vendor/exiftool/t/ExifTool.t` is found (same as TestLib).

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
    io.stderr:write('check_align.lua: repository root not found from ' .. moduleDir() .. '\n')
    os.exit(2)
end

local LIB = REPO .. '/vendor/exiftool/lib'
local SRC = REPO .. '/src'

-- File pairs: upstream .pm/.pl -> ported .lua (lexiftool.lua maps to ExifTool.pm)
local PAIRS = {
    { LIB .. '/Image/ExifTool.pm', SRC .. '/lexiftool.lua' },
    { LIB .. '/Image/ExifTool/APP12.pm', SRC .. '/lexiftool/APP12.lua' },
    { LIB .. '/Image/ExifTool/Canon.pm', SRC .. '/lexiftool/Canon.lua' },
    { LIB .. '/Image/ExifTool/BuildTagLookup.pm', SRC .. '/lexiftool/BuildTagLookup.lua' },
    { LIB .. '/Image/ExifTool/CanonRaw.pm', SRC .. '/lexiftool/CanonRaw.lua' },
    { LIB .. '/Image/ExifTool/DNG.pm', SRC .. '/lexiftool/DNG.lua' },
    { LIB .. '/Image/ExifTool/Audible.pm', SRC .. '/lexiftool/Audible.lua' },
    { LIB .. '/Image/ExifTool/Exif.pm', SRC .. '/lexiftool/Exif.lua' },
    { LIB .. '/Image/ExifTool/FlashPix.pm', SRC .. '/lexiftool/FlashPix.lua' },
    { LIB .. '/Image/ExifTool/Font.pm', SRC .. '/lexiftool/Font.lua' },
    { LIB .. '/Image/ExifTool/ICC_Profile.pm', SRC .. '/lexiftool/ICC_Profile.lua' },
    { LIB .. '/Image/ExifTool/IPTC.pm', SRC .. '/lexiftool/IPTC.lua' },
    { LIB .. '/Image/ExifTool/Import.pm', SRC .. '/lexiftool/Import.lua' },
    { LIB .. '/Image/ExifTool/JPEG.pm', SRC .. '/lexiftool/JPEG.lua' },
    { LIB .. '/Image/ExifTool/JPEGDigest.pm', SRC .. '/lexiftool/JPEGDigest.lua' },
    { LIB .. '/Image/ExifTool/JSON.pm', SRC .. '/lexiftool/JSON.lua' },
    { LIB .. '/Image/ExifTool/Jpeg2000.pm', SRC .. '/lexiftool/Jpeg2000.lua' },
    { LIB .. '/Image/ExifTool/Kodak.pm', SRC .. '/lexiftool/Kodak.lua' },
    { LIB .. '/Image/ExifTool/MIE.pm', SRC .. '/lexiftool/MIE.lua' },
    { LIB .. '/Image/ExifTool/MPEG.pm', SRC .. '/lexiftool/MPEG.lua' },
    { LIB .. '/Image/ExifTool/MPF.pm', SRC .. '/lexiftool/MPF.lua' },
    { LIB .. '/Image/ExifTool/MacOS.pm', SRC .. '/lexiftool/MacOS.lua' },
    { LIB .. '/Image/ExifTool/Microsoft.pm', SRC .. '/lexiftool/Microsoft.lua' },
    { LIB .. '/Image/ExifTool/Minolta.pm', SRC .. '/lexiftool/Minolta.lua' },
    { LIB .. '/Image/ExifTool/NikonCustom.pm', SRC .. '/lexiftool/NikonCustom.lua' },
    { LIB .. '/Image/ExifTool/NikonSettings.pm', SRC .. '/lexiftool/NikonSettings.lua' },
    { LIB .. '/Image/ExifTool/Olympus.pm', SRC .. '/lexiftool/Olympus.lua' },
    { LIB .. '/Image/ExifTool/PDF.pm', SRC .. '/lexiftool/PDF.lua' },
    { LIB .. '/Image/ExifTool/PNG.pm', SRC .. '/lexiftool/PNG.lua' },
    { LIB .. '/Image/ExifTool/Pentax.pm', SRC .. '/lexiftool/Pentax.lua' },
    { LIB .. '/Image/ExifTool/Photoshop.pm', SRC .. '/lexiftool/Photoshop.lua' },
    { LIB .. '/Image/ExifTool/PrintIM.pm', SRC .. '/lexiftool/PrintIM.lua' },
    { LIB .. '/Image/ExifTool/Qualcomm.pm', SRC .. '/lexiftool/Qualcomm.lua' },
    { LIB .. '/Image/ExifTool/Ricoh.pm', SRC .. '/lexiftool/Ricoh.lua' },
    { LIB .. '/Image/ExifTool/Samsung.pm', SRC .. '/lexiftool/Samsung.lua' },
    { LIB .. '/Image/ExifTool/Trailer.pm', SRC .. '/lexiftool/Trailer.lua' },
    { LIB .. '/Image/ExifTool/XMP.pm', SRC .. '/lexiftool/XMP.lua' },
    { LIB .. '/Image/ExifTool/XMP2.pl', SRC .. '/lexiftool/XMP2.lua' },
    { LIB .. '/Image/ExifTool/XMPStruct.pl', SRC .. '/lexiftool/XMPStruct.lua' },
    { LIB .. '/Image/ExifTool/WriteXMP.pl', SRC .. '/lexiftool/WriteXMP.lua' },
    { LIB .. '/Image/ExifTool/WriteIPTC.pl', SRC .. '/lexiftool/WriteIPTC.lua' },
    { LIB .. '/Image/ExifTool/WritePhotoshop.pl', SRC .. '/lexiftool/WritePhotoshop.lua' },
    { LIB .. '/Image/ExifTool/WritePNG.pl', SRC .. '/lexiftool/WritePNG.lua' },
    { LIB .. '/Image/ExifTool/WriteRIFF.pl', SRC .. '/lexiftool/WriteRIFF.lua' },
    { LIB .. '/Image/ExifTool/WritePDF.pl', SRC .. '/lexiftool/WritePDF.lua' },
    { LIB .. '/Image/ExifTool/WritePostScript.pl', SRC .. '/lexiftool/WritePostScript.lua' },
    { LIB .. '/Image/ExifTool/WriteCanonRaw.pl', SRC .. '/lexiftool/WriteCanonRaw.lua' },
}

local function readall(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a') or ''
    f:close()
    return s
end

-- Split a file into lines without the trailing newline
local function splitLines(text)
    local lines = {}
    for l in (text .. '\n'):gmatch('(.-)\n') do
        lines[#lines + 1] = l
    end
    return lines
end

-- Strip a trailing comment from a line, honouring quoted strings so that
-- '#'/'--' inside a value does not cut the line. Returns the code part.
local function stripComment(line, isPerl)
    local out = {}
    local i, n = 1, #line
    local quote
    while i <= n do
        local c = line:sub(i, i)
        if quote then
            out[#out + 1] = c
            if c == '\\' then -- skip escaped character inside the string
                i = i + 1
                out[#out + 1] = line:sub(i, i)
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
            out[#out + 1] = c
        elseif isPerl and c == '#' then
            break
        elseif not isPerl and c == '-' and line:sub(i + 1, i + 1) == '-' then
            break
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

-- A Perl table entry is any non-empty line whose code part contains `=>`
local function perlEntry(line)
    local code = stripComment(line, true)
    local col = code:find('=>', 1, true)
    if col and line:match('%S') then return col end
    return nil
end

-- A Lua table entry is an indented `key = value,` / `[key] = value,` line
-- (also accepting a closing `},`); `==` comparisons are not entries.
local function luaEntry(line)
    local s = line:match('^%s+(.-)$')
    if not s or s:sub(1, 2) == '--' then return nil end
    if not (s:sub(-1) == ',' or s:sub(-2) == '},') then return nil end
    local code = stripComment(s, false)
    local _, eq = code:find('^%[[^%]]*%]%s*=')
    if not eq then
        _, eq = code:find('^["%w][%w%.]*%s*=')
    end
    if not eq then return nil end
    if code:sub(eq + 1, eq + 1) == '=' then return nil end -- `==`, not assignment
    return #line - #s + eq -- absolute column of the `=`
end

-- Group consecutive entry lines into runs
local function collectRuns(lines, entryFn)
    local runs, cur = {}, {}
    for i, l in ipairs(lines) do
        local col = entryFn(l)
        if col then
            cur[#cur + 1] = { line = i, raw = l, col = col }
        elseif #cur > 0 then
            runs[#runs + 1] = cur
            cur = {}
        end
    end
    if #cur > 0 then runs[#runs + 1] = cur end
    return runs
end

-- Describe a run: operator column, spacing style, comment column
local function describe(run, isPerl)
    local cols, ccols, single = {}, {}, true
    for _, e in ipairs(run) do
        cols[e.col] = true
        local code = stripComment(e.raw, isPerl)
        local tail = isPerl and '=>' or '='
        if not code:gsub('%s+$', ''):match('%s' .. tail .. '$') then
            single = false -- operator not preceded by exactly one space
        end
        local cs = #code:gsub('%s+$', '')
        if cs > 0 and #e.raw > cs then
            ccols[cs + 1] = true -- trailing comment starts here
        end
    end
    local lo, hi = math.huge, -math.huge
    for c in pairs(cols) do
        if c < lo then lo = c end
        if c > hi then hi = c end
    end
    local op = lo == hi and string.format('col%d', lo)
        or string.format('ragged(%d..%d)', lo, hi)
    local cmt
    local first
    for c in pairs(ccols) do
        if not first or c < first then first = c end
    end
    if not next(ccols) then
        cmt = ''
    else
        local aligned = true
        for c in pairs(ccols) do
            if c ~= first then aligned = false end
        end
        cmt = aligned and string.format('cmt@%d', first) or 'cmt-ragged'
    end
    return run[1].line, run[#run].line, #run, op, single and 'single-spc' or '', cmt
end

local problems = 0

for _, pair in ipairs(PAIRS) do
    local pm, lua = pair[1], pair[2]
    local plines = splitLines(readall(pm) or '')
    local llines = splitLines(readall(lua) or '')
    io.write(string.format('=== %s  <->  %s\n', pm:sub(#REPO + 2), lua:sub(#REPO + 2)))
    io.write(string.format('    perl runs: %d   lua runs: %d\n',
        #collectRuns(plines, perlEntry), #collectRuns(llines, luaEntry)))
    for i, l in ipairs(llines) do
        if l:find('\t', 1, true) then
            io.write(string.format('    TAB in lua line %d\n', i))
            problems = problems + 1
        end
    end
    local lists = {
        { 'P', collectRuns(plines, perlEntry), true },
        { 'L', collectRuns(llines, luaEntry), false },
    }
    for _, item in ipairs(lists) do
        local tag, runs, isPerl = item[1], item[2], item[3]
        for _, run in ipairs(runs) do
            if #run >= 2 then
                local a, b, n, op, spc, cmt = describe(run, isPerl)
                io.write(string.format('    %s L%5d-%-5d n=%-3d %-16s %-10s %s\n',
                    tag, a, b, n, op, spc, cmt))
            end
        end
    end
    print()
end

os.exit(problems > 0 and 1 or 0)
