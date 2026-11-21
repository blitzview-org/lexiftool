--------------------------------------------------------------------------------
-- File:         tools/compile_tree.lua
--
-- Description:  Lays the Lua module tree of src/ down as bytecode for a
--               system-wide installation (`make install`, INSTALL_BYTECODE=1):
--               every *.lua below SRCDIR is compiled and written under the
--               same relative name below DESTDIR, *.dat files are copied
--               as they are. Lua loads a
--               binary chunk whatever the file is called, so the installed
--               modules are found and loaded exactly like the sources, only
--               without parsing them on every start.
--
--               The chunk name of each module is "@CHUNKDIR/<rel>": the
--               path the module will have once installed (DESTDIR may
--               include a staging prefix, CHUNKDIR must not). Geolocation.lua
--               reads its chunk name: it takes the default directory of
--               Geolocation.dat and AltNames.dat from it. Debug
--               information is kept (tracebacks name file and line;
--               perl.lua compares chunk names in TL.croak).
--
--               Run with the Lua the modules are installed for: bytecode is
--               bound to the Lua version that produced it. Each file is
--               written to a temporary name and renamed, so an interrupted
--               run leaves no truncated module behind.
--
-- Syntax:       lua tools/compile_tree.lua SRCDIR DESTDIR CHUNKDIR
--               (needs no package.path; uses `find` and `mkdir -p`)
--------------------------------------------------------------------------------

local srcdir, destdir, chunkdir = arg[1], arg[2], arg[3]
if not (srcdir and destdir and chunkdir) then
    io.stderr:write('usage: compile_tree.lua SRCDIR DESTDIR CHUNKDIR\n')
    os.exit(2)
end

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local data = f:read('a')
    f:close()
    return data
end

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function write(path, data)
    local dir = path:match('^(.*)/[^/]*$')
    if dir then assert(os.execute('mkdir -p ' .. shellQuote(dir))) end
    local tmp = path .. '.tmp'
    local f = assert(io.open(tmp, 'wb'))
    assert(f:write(data))
    f:close()
    assert(os.rename(tmp, path))
end

-- the files, relative to SRCDIR: lexiftool.lua and everything below
-- lexiftool/ that is a module or a data file (sys.c and the like stay out)
local list = assert(io.popen('cd ' .. shellQuote(srcdir) ..
    " && find lexiftool.lua lexiftool -type f \\( -name '*.lua' -o -name '*.dat' \\) | LC_ALL=C sort"))
local compiled, copied = 0, 0
for rel in list:lines() do
    local data = slurp(srcdir .. '/' .. rel)
    if rel:sub(-4) == '.lua' then
        local chunk, err = load(data, '@' .. chunkdir .. '/' .. rel, 't')
        if not chunk then
            io.stderr:write('compile_tree.lua: ', err, '\n')
            os.exit(1)
        end
        data = string.dump(chunk)
        compiled = compiled + 1
    else
        copied = copied + 1
    end
    write(destdir .. '/' .. rel, data)
end
list:close()
print(string.format('compile_tree.lua: %d modules compiled for %s, %d files copied, into %s',
                    compiled, _VERSION, copied, destdir))
