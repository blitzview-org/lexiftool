--------------------------------------------------------------------------------
-- File:         tools/cmp_tag_lookup.lua
--
-- Description:  Compares the generated index in src/lexiftool/TagLookup.lua
--               against the one in the vendored
--               vendor/exiftool/lib/Image/ExifTool/TagLookup.pm.
--
--               tools/gen_tag_lookup.lua derives the index from this port's own
--               tag tables, so the only way to know the derivation rules are
--               upstream's is to hold the result against upstream's.  The two
--               indexes cannot be equal -- this port carries a subset of
--               upstream's tables -- so the check separates the two cases:
--
--               EXPECTED  a tag or table upstream indexes and this port simply
--                         does not have.  Not a finding.
--               FINDING   the port HAS the table, but the index disagrees with
--                         upstream about it: an entry missing, an extra entry,
--                         or a different set of tag IDs.  Those are the real
--                         results -- either the derivation rules are off, or
--                         the port's own table is (a missing WRITE_PROC, a
--                         dropped Writable, a tag ID that drifted).
--
--               Both halves are read from the machine-generated sections
--               between the `Begin/End automatically generated code` markers:
--               the Lua one is loaded as a chunk, the Perl one is parsed (it
--               is machine-written, so its line format is fixed).
--
--               Table names are mapped lexiftool.X.Y <-> Image::ExifTool::X::Y,
--               with two exceptions that are structural port deviations rather
--               than naming ones: lexiftool.ExifTool.Extra stands for
--               Image::ExifTool::Extra, and this port's per-module Composite
--               tables (lexiftool.Canon.Composite, ...) all stand for
--               upstream's single merged Image::ExifTool::Composite.
--
-- Usage:        <interp> tools/cmp_tag_lookup.lua
--               (package.path supplied by the caller, as in tools/bench.lua)
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')

local sformat = string.format

local LUA_FILE = 'src/lexiftool/TagLookup.lua'
local PM_FILE = 'vendor/exiftool/lib/Image/ExifTool/TagLookup.pm'

--------------------------------------------------------------------------------
-- Read a file's generated section
-- Inputs: 0) path, 1) Lua pattern matching the begin marker, 2) end marker
-- Returns: the lines between the markers
local function generatedSection(path, beginPat, endPat)
    local fh = assert(io.open(path, 'r'))
    local lines, on = {}, false
    for line in fh:lines('l') do
        if on then
            if line:match(endPat) then break end
            lines[#lines + 1] = line
        elseif line:match(beginPat) then
            on = true
        end
    end
    fh:close()
    assert(#lines > 0, 'no generated section found in ' .. path)
    return lines
end

--------------------------------------------------------------------------------
-- Load this port's index by running its generated section as a chunk
local function loadLuaIndex()
    local lines = generatedSection(LUA_FILE, '^%-%-%+%+%+%+ Begin', '^%-%-%+%+%+%+ End')
    local chunk = table.concat(lines, '\n') ..
                  '\nreturn tableList, tagLookup, tagExists, compositeModules\n'
    local fn = assert(load(chunk, '@' .. LUA_FILE))
    return fn()
end

--------------------------------------------------------------------------------
-- Scan one Perl tag-ID literal out of a %tagLookup entry
-- Inputs: 0) text, 1) 1-based position
-- Returns: normalized ID string, next position, isRootRef
local function scanID(s, pos)
    local root
    if s:sub(pos, pos) == '\\' then root = true pos = pos + 1 end
    local c = s:sub(pos, pos)
    if c == "'" or c == '"' then
        local i = pos + 1
        local buf = {}
        while i <= #s do
            local ch = s:sub(i, i)
            if ch == '\\' and c == '"' then
                local hex = s:match('^\\x(%x%x)', i)
                if hex then
                    buf[#buf + 1] = string.char(tonumber(hex, 16))
                    i = i + 4
                else
                    buf[#buf + 1] = s:sub(i + 1, i + 1)
                    i = i + 2
                end
            elseif ch == c then
                return table.concat(buf), i + 1, root
            else
                buf[#buf + 1] = ch
                i = i + 1
            end
        end
        error('unterminated string in: ' .. s)
    end
    -- a bare number (always hex in the generated file)
    local num = s:match('^0x%x+', pos) or s:match('^%d+', pos)
    assert(num, 'cannot scan tag ID at ' .. pos .. ' in: ' .. s)
    return sformat('%d', tonumber(num)), pos + #num, root
end

--------------------------------------------------------------------------------
-- Parse one `N => ENTRY` value of a %tagLookup line
-- Inputs: 0) text, 1) 1-based position
-- Returns: { ids = set, root = id or nil }, next position
local function scanEntry(s, pos)
    local entry = { ids = {}, n = 0 }
    if s:sub(pos, pos) == '[' then
        pos = pos + 1
        while s:sub(pos, pos) ~= ']' do
            local id, nxt, root = scanID(s, pos)
            pos = nxt
            if root then
                entry.root = id
            else
                entry.ids[id] = true
                entry.n = entry.n + 1
            end
            if s:sub(pos, pos) == ',' then pos = pos + 1 end
        end
        return entry, pos + 1
    end
    local id, nxt = scanID(s, pos)
    entry.ids[id] = true
    entry.n = 1
    return entry, nxt
end

--------------------------------------------------------------------------------
-- Parse the generated section of upstream's TagLookup.pm
-- Returns: tableList (array), tagLookup (tag -> tableName -> entry), tagExists
local function loadPmIndex()
    local lines = generatedSection(PM_FILE, '^#%+%+%+%+ Begin', '^#%+%+%+%+ End')
    local tableList, tagLookup, tagExists = {}, {}, {}
    local section
    for _, line in ipairs(lines) do
        if line:match('^my @tableList') then section = 'tableList'
        elseif line:match('^my %%tagLookup') then section = 'tagLookup'
        elseif line:match('^my %%tagExists') then section = 'tagExists'
        elseif line:match('^my %%compositeModules') then section = 'compositeModules'
        elseif line:match('^%);') then section = nil
        elseif section == 'tableList' then
            local name = line:match("^\t'(.-)',$")
            assert(name, 'cannot parse tableList line: ' .. line)
            tableList[#tableList + 1] = name
        elseif section == 'tagExists' then
            local tag = line:match("^\t'(.-)' => 1,$")
            assert(tag, 'cannot parse tagExists line: ' .. line)
            tagExists[tag] = true
        elseif section == 'tagLookup' then
            local tag, rest = line:match("^\t'(.-)' => { (.*) },$")
            assert(tag, 'cannot parse tagLookup line: ' .. line)
            local byTable = {}
            local pos = 1
            while pos <= #rest do
                local num, nxt = rest:match('^(%d+) => ()', pos)
                assert(num, 'cannot parse entry at ' .. pos .. ' in: ' .. line)
                local entry
                entry, pos = scanEntry(rest, nxt)
                local name = tableList[tonumber(num) + 1]
                assert(name, 'table number ' .. num .. ' out of range in: ' .. line)
                byTable[name] = entry
                if rest:sub(pos, pos + 1) == ', ' then pos = pos + 2 end
            end
            tagLookup[tag] = byTable
        end
    end
    return tableList, tagLookup, tagExists
end

--------------------------------------------------------------------------------
-- Map a port table name onto its upstream counterpart
local function upstreamName(name)
    if name == 'lexiftool.ExifTool.Extra' then return 'Image::ExifTool::Extra' end
    if name:match('%.Composite$') then return 'Image::ExifTool::Composite' end
    local rest = name:match('^lexiftool%.(.*)$')
    if not rest then return name end
    return 'Image::ExifTool::' .. rest:gsub('%.', '::')
end

--------------------------------------------------------------------------------
-- Normalize a port index entry into the same { ids = set, root = id } shape
local function luaEntry(v)
    local entry = { ids = {}, n = 0 }
    local function put(id)
        if type(id) == "number" then id = (id == math.floor(id)) and sformat("%d", id) or tostring(id) end
        entry.ids[id] = true
        entry.n = entry.n + 1
    end
    if type(v) == 'table' then
        for i, id in ipairs(v) do
            if i == 1 and type(id) == 'table' then
                local r = id[1]
                entry.root = (type(r) == 'number') and sformat('%d', r) or r
            else
                put(id)
            end
        end
    else
        put(v)
    end
    return entry
end

local function idsText(entry)
    local ids = {}
    for id in pairs(entry.ids) do ids[#ids + 1] = id end
    table.sort(ids)
    local s = table.concat(ids, ',')
    if entry.root then s = '\\' .. entry.root .. ',' .. s end
    return s
end

local function sameEntry(a, b)
    return idsText(a) == idsText(b)
end

--------------------------------------------------------------------------------
local luaTableList, luaTagLookup, luaTagExists = loadLuaIndex()
local pmTableList, pmTagLookup, pmTagExists = loadPmIndex()

-- every tag table this port has loaded (not just the writable ones), so a
-- difference can be told from a table the port simply does not carry
Writer.LoadAllTables()
-- ... and, per table, which tag IDs each tag NAME is defined under, so
-- "upstream indexes a tag (or a second ID for it) that this port's own table
-- simply does not define" -- a subset table, expected -- can be told from "the
-- port defines it but the index does not carry it", which is a finding
local portHasTable, portTagIDs = {}, {}
local nPortTables = 0
for name, tbl in pairs(ExifTool.GetAllTables()) do
    local up = upstreamName(name)
    portHasTable[up] = true
    -- (the flattened XMP structure fields are tags of the table too, once
    --  generated -- BuildTagLookup does the same before it indexes a table)
    if (tbl.GROUPS and tbl.GROUPS[0] == 'XMP') or (tbl.VARS and tbl.VARS.ADD_FLATTENED) then
        require('lexiftool.XMP').AddFlattenedTags(tbl)
    end
    nPortTables = nPortTables + 1
    local byName = portTagIDs[up] or {}
    portTagIDs[up] = byName
    for _, tagID in ipairs(ExifTool.TagTableKeys(tbl)) do
        local id = tagID
        if type(id) == 'number' then
            id = (id == math.floor(id)) and sformat('%d', id) or tostring(id)
        end
        for _, tagInfo in ipairs(ExifTool.GetTagInfoList(tbl, tagID)) do
            if type(tagInfo.Name) == 'string' then
                local lc = tagInfo.Name:lower()
                byName[lc] = byName[lc] or {}
                byName[lc][id] = true
            end
        end
    end
end

local nLuaTags, nPmTags = 0, 0
for _ in pairs(luaTagLookup) do nLuaTags = nLuaTags + 1 end
for _ in pairs(pmTagLookup) do nPmTags = nPmTags + 1 end
local nLuaExists, nPmExists = 0, 0
for _ in pairs(luaTagExists) do nLuaExists = nLuaExists + 1 end
for _ in pairs(pmTagExists) do nPmExists = nPmExists + 1 end

io.write('TagLookup index, port vs. upstream\n')
io.write(sformat('  tag tables loaded      port %5d    (upstream loads its full set)\n', nPortTables))
io.write(sformat('  tables in tableList    port %5d    upstream %5d\n', #luaTableList, #pmTableList))
io.write(sformat('  writable tag names     port %5d    upstream %5d\n', nLuaTags, nPmTags))
io.write(sformat('  further names (exists) port %5d    upstream %5d\n', nLuaExists, nPmExists))

-- tableList: does upstream index every table this port indexes?
local pmWritable = {}
for _, name in ipairs(pmTableList) do pmWritable[name] = true end
local tableFindings, tableExpected = {}, 0
for _, name in ipairs(luaTableList) do
    local up = upstreamName(name)
    if not pmWritable[up] then
        tableFindings[#tableFindings + 1] =
            sformat('  tableList: %s (%s) is writable here but not upstream', name, up)
    end
end
local portTablesNotIndexed = {}
for _, name in ipairs(pmTableList) do
    if portHasTable[name] then
        local found = false
        for _, l in ipairs(luaTableList) do
            if upstreamName(l) == name then found = true break end
        end
        if not found then portTablesNotIndexed[#portTablesNotIndexed + 1] = name end
    else
        tableExpected = tableExpected + 1
    end
end

-- tag by tag
local missing, extra, differ = {}, {}, {}
local expectedMissing = 0
-- a table the port has but does not index at all is one finding, not one per
-- tag in it; its tags are counted here and reported with the table
local perUnindexedTable, nInUnindexed = {}, 0
local luaIndexed = {}
for _, name in ipairs(luaTableList) do luaIndexed[upstreamName(name)] = true end
for tag, byTable in pairs(pmTagLookup) do
    local ours = luaTagLookup[tag]
    for name, entry in pairs(byTable) do
        if portHasTable[name] and not luaIndexed[name] then
            perUnindexedTable[name] = (perUnindexedTable[name] or 0) + 1
            nInUnindexed = nInUnindexed + 1
        elseif portHasTable[name] then
            local mine
            if ours then
                for num, v in pairs(ours) do
                    if upstreamName(luaTableList[num]) == name then mine = luaEntry(v) break end
                end
            end
            -- upstream's IDs, narrowed to the ones this port's table actually
            -- defines under this name: that is what the port index ought to say
            local defined = (portTagIDs[name] or {})[tag] or {}
            local want = { ids = {}, n = 0, root = entry.root }
            local nDropped = 0
            for id in pairs(entry.ids) do
                if defined[id] then
                    want.ids[id] = true
                    want.n = want.n + 1
                else
                    nDropped = nDropped + 1     -- the port's table is a subset
                end
            end
            expectedMissing = expectedMissing + nDropped
            if want.n == 0 then
                if mine then
                    extra[#extra + 1] = sformat('  %-40s %s %s (upstream %s)',
                                                tag, name, idsText(mine), idsText(entry))
                end
            elseif not mine then
                missing[#missing + 1] = sformat('  %-40s %s %s', tag, name, idsText(want))
            elseif not sameEntry(mine, want) then
                differ[#differ + 1] = sformat('  %-40s %s: port %s, expected %s',
                                              tag, name, idsText(mine), idsText(want))
            end
        else
            expectedMissing = expectedMissing + 1
        end
    end
end
for tag, ours in pairs(luaTagLookup) do
    local byTable = pmTagLookup[tag]
    for num, v in pairs(ours) do
        local name = upstreamName(luaTableList[num])
        if not (byTable and byTable[name]) then
            extra[#extra + 1] = sformat('  %-40s %s (%s) %s',
                                        tag, luaTableList[num], name, idsText(luaEntry(v)))
        end
    end
end

table.sort(missing) table.sort(extra) table.sort(differ)
table.sort(tableFindings) table.sort(portTablesNotIndexed)

io.write(sformat('\nEXPECTED (upstream tables/tags this port does not carry):\n' ..
                 '  %d tableList entries, %d tag/table entries\n',
                 tableExpected, expectedMissing))

local function report(title, list)
    io.write(sformat('\nFINDING %s: %d\n', title, #list))
    for _, l in ipairs(list) do io.write(l, '\n') end
end

io.write(sformat('\nFINDING tables the port HAS but does not index as writable: %d ' ..
                 '(%d upstream tag entries)\n', #portTablesNotIndexed, nInUnindexed))
-- name the reason: upstream's gate is `$writeProc and ...`, so a table without
-- a WRITE_PROC can contribute nothing no matter what its tags say
local portTableByUpstream = {}
for name, tbl in pairs(ExifTool.GetAllTables()) do
    local up = upstreamName(name)
    if not portTableByUpstream[up] then portTableByUpstream[up] = { name = name, tbl = tbl } end
end
for _, l in ipairs(portTablesNotIndexed) do
    local t = portTableByUpstream[l]
    local why = (t and t.tbl.WRITE_PROC) and 'no writable tag' or 'no WRITE_PROC'
    io.write(sformat('  %-48s %-24s %s (%d tags upstream)\n',
                     l, t and t.name or '?', why, perUnindexedTable[l] or 0))
end
report('tables indexed here but not upstream', tableFindings)
report('tag/table entries missing from the port index', missing)
report('tag/table entries in the port index only', extra)
report('tag/table entries with different tag IDs', differ)

os.exit((#missing + #extra + #differ + #tableFindings + #portTablesNotIndexed) == 0 and 0 or 1)
