--------------------------------------------------------------------------------
-- File:         standalone/genembed.lua
--
-- Description:  Collects everything the standalone executable embeds into
--               one binary blob plus a C index table (build step of
--               standalone/build.sh, run under the builder image's native
--               Lua 5.5.1 -- the same release the executable links, so the
--               bytecode it dumps is loadable there).
--
-- Usage:        lua55 genembed.lua OUTDIR PROJECTDIR STRIP [CODEC TOOL] IDENTITY
--
--               OUTDIR/blob.bin             all entries back to back
--               OUTDIR/embedded_index.c     struct lx_entry lx_entries[]
--               OUTDIR/embedded_codec.h     #define LX_CODEC (main.c)
--
--               IDENTITY is the build's git-describe identity (computed on
--               the host, which has .git -- the builder image does not;
--               standalone/build.sh, capi/build-linux.sh). It is baked into
--               the embedded launcher chunk as a one-line prelude setting
--               _G.LEXIFTOOL_PORT_VERSION, so it is in place before the
--               launcher requires lexiftool.main (CONTRIBUTING.md
--               "Configuration").
--
--               Entries (all names relative to the virtual root
--               "<embedded>", see standalone/main.c):
--                 main    standalone/launcher.lua, as bytecode
--                 module  src/lexiftool.lua and src/lexiftool/**.lua
--                         (module name from the path, `lexiftool.X.Y`); as
--                         bytecode with the chunk name "@<embedded>/<path>",
--                         so tracebacks
--                         read "<embedded>/lexiftool/perl.lua:123:"
--                 file    data files the modules open by path: the source
--                         text of lexiftool/QuickTime.lua (read back by
--                         WriteQuickTime's ConditionUUID). Geolocation.dat
--                         is not one of these: its bundled content ships as
--                         the ordinary module GeolocationData.lua instead
--                         (src/lexiftool/Geolocation.lua's Port notes), so
--                         it is embedded the same way every other module is
--
--               STRIP=1 dumps the bytecode without debug information
--               (luac -s), except for the modules in KEEP_DEBUG, which
--               need their chunk name at run time. The build uses STRIP=0
--               (see the size notes in standalone/README.md).
--
--               CODEC (zstd) and TOOL, the path of that codec's
--               command-line tool, compress every entry on its own
--               (zstd --ultra -22 without checksum; the index records the
--               uncompressed length): main.c decodes an entry only when it
--               is used, so a run decompresses just the modules it
--               requires. Without CODEC (or empty, or "none") the entries
--               are stored as they are (uncompressed length 0 in the
--               index). embedded_codec.h tells main.c which decoder to
--               compile in (LX_CODEC_NONE / _ZSTD).
--
--               Output is deterministic: entries are sorted, nothing
--               depends on time or on the build directory.
--------------------------------------------------------------------------------

local outdir, project, strip = arg[1], arg[2], arg[3] == '1'
local codec = (arg[4] == nil or arg[4] == '') and 'none' or arg[4]
local tool = arg[5]
local identity = (arg[6] == nil or arg[6] == '') and 'Unknown' or arg[6]
assert(outdir and project, 'usage: genembed.lua OUTDIR PROJECTDIR STRIP [CODEC TOOL] IDENTITY')
-- per codec: its macro for main.c, the tool's options (it writes FILE.ext
-- next to every FILE it is given) and that extension
local CODECS = {
    none   = { macro = 'LX_CODEC_NONE' },
    -- --single-thread: the output must not depend on the worker setup;
    -- --no-check: no xxhash per entry to store and to verify on decoding
    zstd   = { macro = 'LX_CODEC_ZSTD', opts = '-q --ultra -22 --single-thread --no-check -f',
               ext = '.zst' },
}
local cdef = assert(CODECS[codec], 'unknown CODEC ' .. codec .. ' (none | zstd)')
assert(codec == 'none' or (tool and tool ~= ''), 'CODEC ' .. codec .. ' needs TOOL')
local compress = codec ~= 'none'
assert(_VERSION == 'Lua 5.5', 'genembed.lua must run under Lua 5.5 (got ' .. _VERSION .. ')')

local VROOT = '<embedded>'

-- modules whose chunk name is looked at while running (debug.getinfo
-- source -> path), so their debug information is kept even with STRIP=1
local KEEP_DEBUG = {
    -- geoDir's default value and the AltNames.dat sibling-file lookup only;
    -- the bundled Geolocation.dat itself no longer goes through this (see
    -- the FILES comment above and Geolocation.lua's Port notes)
    ['lexiftool/Geolocation.lua'] = true,
    ['lexiftool/QuickTime.lua'] = true,     -- ConditionUUID reads the source
}
-- data files opened by path relative to a module's chunk name
local FILES = {
    'lexiftool/QuickTime.lua',
}

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local data = f:read('a')
    f:close()
    return data
end

local function compile(path, rel)
    local chunk = assert(load(slurp(path), '@' .. VROOT .. '/' .. rel, 't'))
    return string.dump(chunk, strip and not KEEP_DEBUG[rel])
end

local entries = {}

-- the launcher (main chunk): IDENTITY is baked in as a one-line prelude
-- before the chunk's own source, so _G.LEXIFTOOL_PORT_VERSION is set
-- before launcher.lua requires lexiftool.main (shifts its line numbers by
-- one; not source held to Perl line-for-line parity, so that is fine)
do
    local rel = 'launcher.lua'
    local src = string.format('_G.LEXIFTOOL_PORT_VERSION = %q\n', identity) ..
        slurp(project .. '/standalone/launcher.lua')
    local chunk = assert(load(src, '@' .. VROOT .. '/' .. rel, 't'))
    entries[#entries + 1] = { kind = 'LX_MAIN', name = 'launcher',
        data = string.dump(chunk, strip) }
end

-- the library modules: sorted list of src/lexiftool.lua + src/lexiftool/**.lua
local list = {}
local pipe = assert(io.popen('cd "' .. project .. '/src" && ' ..
    'find lexiftool.lua lexiftool -type f -name "*.lua" | LC_ALL=C sort'))
for rel in pipe:lines() do list[#list + 1] = rel end
assert(pipe:close())
assert(#list > 100, 'too few modules found under ' .. project .. '/src')
for _, rel in ipairs(list) do
    local name = rel:gsub('%.lua$', ''):gsub('/', '.')
    entries[#entries + 1] = { kind = 'LX_MODULE', name = name,
        data = compile(project .. '/src/' .. rel, rel) }
end

-- the data files
for _, rel in ipairs(FILES) do
    entries[#entries + 1] = { kind = 'LX_FILE', name = rel,
        data = slurp(project .. '/src/' .. rel) }
end

-- compress: every entry into a file of its own, the codec's tool on 16
-- files per run, as many runs at a time as there are processors (the
-- output does not depend on the order); the compressed bytes replace the
-- data, the index keeps the uncompressed length
if compress then
    local dir = outdir .. '/entries'
    assert(os.execute('rm -rf "' .. dir .. '" && mkdir -p "' .. dir .. '"'))
    for i, e in ipairs(entries) do
        local f = assert(io.open(string.format('%s/%04d', dir, i), 'wb'))
        f:write(e.data)
        f:close()
    end
    assert(os.execute('cd "' .. dir .. '" && ls | xargs -P "$(nproc)" -n 16 "' ..
        tool .. '" ' .. cdef.opts))
    for i, e in ipairs(entries) do
        e.ulen = #e.data
        e.data = slurp(string.format('%s/%04d%s', dir, i, cdef.ext))
    end
    assert(os.execute('rm -rf "' .. dir .. '"'))
end

-- write blob + index
local blob = assert(io.open(outdir .. '/blob.bin', 'wb'))
local c = assert(io.open(outdir .. '/embedded_index.c', 'wb'))
c:write('/* generated by standalone/genembed.lua - do not edit */\n',
        '#include "embedded.h"\n\n',
        'const struct lx_entry lx_entries[] = {\n')
local offset = 0
local sizes = { LX_MAIN = 0, LX_MODULE = 0, LX_FILE = 0 }     -- uncompressed
local stored = { LX_MAIN = 0, LX_MODULE = 0, LX_FILE = 0 }    -- in the blob
for _, e in ipairs(entries) do
    blob:write(e.data)
    c:write(string.format('    { %-9s, "%s", %d, %d, %d },\n',
        e.kind, e.name, offset, #e.data, e.ulen or 0))
    offset = offset + #e.data
    sizes[e.kind] = sizes[e.kind] + (e.ulen or #e.data)
    stored[e.kind] = stored[e.kind] + #e.data
end
c:write('    { 0, NULL, 0, 0, 0 }\n};\n\n',
        string.format('const size_t lx_blob_size = %d;\n', offset))
blob:close()
c:close()

local h = assert(io.open(outdir .. '/embedded_codec.h', 'wb'))
h:write('/* generated by standalone/genembed.lua - do not edit */\n',
        '#define LX_CODEC_NONE   0\n',
        '#define LX_CODEC_ZSTD   2\n',
        '#define LX_CODEC ', cdef.macro, '\n')
h:close()

local function sz(kind1, kind2)
    local u = sizes[kind1] + (kind2 and sizes[kind2] or 0)
    local b = stored[kind1] + (kind2 and stored[kind2] or 0)
    return compress and string.format('%d bytes, %d %s-compressed', u, b, codec)
                   or string.format('%d bytes', u)
end
print(string.format('genembed: %d modules (%s bytecode%s), %d files (%s), blob %d bytes',
    #list + 1, sz('LX_MODULE', 'LX_MAIN'), strip and ', stripped' or '',
    #FILES, sz('LX_FILE'), offset))
