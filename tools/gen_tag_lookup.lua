--------------------------------------------------------------------------------
-- File:         tools/gen_tag_lookup.lua
--
-- Description:  Generate tag lookup for ExifTool writer -- the port's
--               counterpart of upstream's build_tag_lookup script, and just
--               as thin: all the work is in lexiftool.BuildTagLookup.
--
--               It rewrites the generated section of
--               src/lexiftool/TagLookup.lua (between the `Begin/End
--               automatically generated code` markers) from this port's own
--               tag tables, and writes the TagNames documentation, which this
--               repository does not carry: the POD to build/doc/TagNames.pod
--               and the HTML pages to build/doc/html/TagNames/ (build/ is not
--               checked in).
--
--               Why the index is generated and not copied from upstream's
--               TagLookup.pm: upstream does not hand-write it either -- it is
--               a projection of the tag tables, so a hand copy would state the
--               same facts twice and go stale with every table change, and
--               upstream's copy describes upstream's tables, not this port's.
--               Re-deriving it after a table change is one command.
--
-- Syntax:       <interp> tools/gen_tag_lookup.lua [-c] [-p] [-v]
--               (run from the repository root; package.path supplied by the
--               caller, as in tools/bench.lua)
--
-- Options:      -c  - check dates and only build if necessary
--               -p  - preserve existing revision date in html files
--               -v  - verbose mode
--------------------------------------------------------------------------------

local file = 'src/lexiftool/TagLookup.lua'
local podFile = 'build/doc/TagNames.pod'
local htmldir = 'build/doc/html'
local stampFile = 'build/.built_tag_lookup'
local verbose, check, preserve

for _, a in ipairs(arg or { }) do
    if a == '-p' then
        preserve = 1
    elseif a == '-v' then
        verbose = 1
    elseif a == '-c' then
        check = 1
    else
        io.stderr:write("Unknown option '" .. a .. "'\n")
        os.exit(1)
    end
end

local lfs = require('lfs')

if check and lfs.attributes(stampFile) then
    -- find most recent module file
    local latest = 0
    for f in lfs.dir('src/lexiftool') do
        local t = f:match('%.lua$') and lfs.attributes('src/lexiftool/' .. f, 'modification')
        if t and t > latest then latest = t end
    end
    if latest < lfs.attributes(stampFile, 'modification') then
        print('Tag Lookup is up-to-date')
        os.exit(0)
    end
end

print('Building tag lookup...')

local BuildTagLookup = require('lexiftool.BuildTagLookup')

local builder = BuildTagLookup.new()

if preserve then
    builder.PRESERVE_DATE = 1
    print('(preserving revision dates)')
end

local count = builder.COUNT
local function printCounts()
    local keys = { }
    for k in pairs(count) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        print(string.format('%5d %s', count[k], k))
    end
end
printCounts()

if verbose then
    local writePseudo = builder.WRITE_PSEUDO
    io.write(string.format('%5d writable pseudo tags:', #writePseudo))
    local len = 999
    local sorted = { }
    for i, v in ipairs(writePseudo) do sorted[i] = v end
    table.sort(sorted)
    for _, tag in ipairs(sorted) do
        if len + #tag > 78 then io.write('\n     ') len = 5 end
        io.write(' ', tag)
        len = len + #tag + 1
    end
    io.write('\n')
end

if builder:WriteTagLookup(file) == 1 then
    print('Tag lookup built OK')
else
    io.stderr:write('Error building tag lookup\n')
    os.exit(1)
end

-- (upstream writes into the existing lib/ and html/ trees; here the
--  documentation goes below build/, which may not exist yet)
for _, dir in ipairs({ 'build', 'build/doc', htmldir }) do lfs.mkdir(dir) end

if builder:WriteTagNames(podFile, htmldir) == 1 then
    print('TagNames written OK')
else
    io.stderr:write('Error writing TagNames\n')
    os.exit(1)
end

-- check to see if too many files changed
local diff = count['HTML files changed']
local same = count['HTML files unchanged']
if diff > same then
    io.stderr:write('WARNING: ' .. diff .. ' HTML files changed!!!! <<<<<<<<<<<<<<<<<<<\n')
else
    print(string.format('%5d HTML files changed', diff))
end

local stamp = io.open(stampFile, 'w')
if stamp then stamp:write(os.date() .. '\n') stamp:close() end

os.exit(0)
