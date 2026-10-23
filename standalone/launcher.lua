--------------------------------------------------------------------------------
-- File:         standalone/launcher.lua
--
-- Description:  Main chunk of the standalone executable -- the counterpart of
--               the `lexiftool` launcher script for a binary that carries all
--               modules inside (standalone/main.c runs it). The C host has
--               already put the linked-in C modules into package.preload and
--               a searcher for the embedded Lua modules into
--               package.searchers; it passes this chunk two values:
--                 VROOT     the virtual root of the embedded entries,
--                           "<embedded>" (module chunk names read
--                           "@<embedded>/lexiftool/perl.lua")
--                 getFile   getFile(rel) -> contents of the embedded data
--                           file rel ("lexiftool/QuickTime.lua"), or nil
--
--               Data files: a module finds its data file next to its own
--               chunk name (WriteQuickTime's ConditionUUID: the directory
--               of its source, plus "/QuickTime.lua", read back as its own
--               source text), so it opens a path below VROOT. io.open is
--               wrapped to serve exactly those paths, read-only,
--               from memory; every other path goes to the real io.open. The
--               handle returned for an embedded file is a small Lua object
--               with the methods of a Lua file handle that reading needs
--               (read with all formats, lines, seek, close, setvbuf, flush);
--               io.type() does not know it, writing to it is an error.
--               Nothing here changes the library: it sees the same
--               io.open semantics as with the files on disk.
--
--               A third value, true, is passed by an embedding host (the C
--               API, capi/lexiftool.c): the chunk then sets up io.open as
--               above but runs nothing, and returns the lexiftool.main
--               module and the launch information for its session
--               (doc/capi.md).
--------------------------------------------------------------------------------

local VROOT, getFile, embedded = ...

local realOpen = io.open
local prefix = VROOT .. '/'

-- read-only in-memory file handle ------------------------------------------
local MemFile = {}
MemFile.__index = MemFile
MemFile.__name = 'lexiftool.embedded_file'

local function checkOpen(self)
    if self.closed then error('attempt to use a closed file', 3) end
end

-- one read format, Lua's io semantics (lua 5.4/5.5 liolib g_read)
local function readOne(self, fmt)
    local data, pos = self.data, self.pos
    if type(fmt) == 'number' then
        fmt = math.tointeger(fmt) or error("bad argument to 'read' (number has no integer representation)", 3)
        if fmt == 0 then return pos <= #data and '' or nil end
        if pos > #data then return nil end
        local s = data:sub(pos, pos + fmt - 1)
        self.pos = pos + #s
        return s
    end
    fmt = tostring(fmt):gsub('^%*', ''):sub(1, 1)
    if fmt == 'a' then
        local s = data:sub(pos)
        self.pos = #data + 1
        return s
    elseif fmt == 'l' or fmt == 'L' then
        if pos > #data then return nil end
        local nl = data:find('\n', pos, true)
        local stop = nl or #data
        self.pos = stop + 1
        if fmt == 'l' and nl then stop = stop - 1 end
        return data:sub(pos, stop)
    elseif fmt == 'n' then
        local s, e = data:find('^[ \t\n\r\f\v]*[-+]?[A-Za-z0-9%.]+', pos)
        if not s then return nil end
        local n = tonumber((data:sub(s, e):gsub('^[ \t\n\r\f\v]+', '')))
        if n then self.pos = e + 1 end
        return n
    end
    error("bad argument to 'read' (invalid format)", 3)
end

function MemFile:read(...)
    checkOpen(self)
    local n = select('#', ...)
    if n == 0 then return readOne(self, 'l') end
    local out = {}
    for i = 1, n do
        local v = readOne(self, (select(i, ...)))
        out[i] = v
        if v == nil then return table.unpack(out, 1, i) end
    end
    return table.unpack(out, 1, n)
end

function MemFile:lines(...)
    checkOpen(self)
    local fmts = table.pack(...)
    if fmts.n == 0 then fmts = { 'l', n = 1 } end
    return function()
        return self:read(table.unpack(fmts, 1, fmts.n))
    end
end

function MemFile:seek(whence, offset)
    checkOpen(self)
    whence, offset = whence or 'cur', offset or 0
    local base
    if whence == 'set' then base = 0
    elseif whence == 'cur' then base = self.pos - 1
    elseif whence == 'end' then base = #self.data
    else error("bad argument #1 to 'seek' (invalid option '" .. tostring(whence) .. "')", 2) end
    local p = base + offset
    if p < 0 then return nil, 'Invalid argument', 22 end
    self.pos = p + 1
    return p
end

function MemFile:close()
    checkOpen(self)
    self.closed = true
    self.data = ''
    return true
end

function MemFile:write()
    checkOpen(self)
    return nil, 'Bad file descriptor', 9
end

function MemFile:flush() checkOpen(self) return self end
function MemFile:setvbuf() checkOpen(self) return true end
MemFile.__close = function(self) if not self.closed then self:close() end end
MemFile.__tostring = function(self)
    return self.closed and 'file (closed)' or 'file (embedded ' .. self.name .. ')'
end

-- io.open for paths below VROOT -----------------------------------------------
function io.open(name, mode) -- luacheck: ignore 122
    if type(name) == 'string' and name:sub(1, #prefix) == prefix then
        local m = mode == nil and 'r' or tostring(mode)
        local data = getFile(name:sub(#prefix + 1))
        if data == nil then
            return nil, name .. ': No such file or directory', 2
        end
        if not m:match('^r') or m:find('+', 1, true) then
            return nil, name .. ': Read-only file system', 30
        end
        return setmetatable({ data = data, pos = 1, name = name }, MemFile)
    end
    return realOpen(name, mode)
end

-- run the command-line tool, exactly as the `lexiftool` launcher does --------
local mainFn = require('lexiftool.main')
if embedded then return mainFn, { bytecode = true } end
os.exit(mainFn(arg, { bytecode = true }))
