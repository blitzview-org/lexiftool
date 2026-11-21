--------------------------------------------------------------------------------
-- File:         standalone/launcher.lua
--
-- Description:  Main chunk of the standalone executable -- the counterpart of
--               the `lexiftool` launcher script for a binary that carries all
--               modules inside (standalone/main.c runs it). The C host has
--               already put the linked-in C modules into package.preload and
--               a searcher for the embedded Lua modules into
--               package.searchers (module chunk names read
--               "@<embedded>/lexiftool/perl.lua"); nothing is read from the
--               file system to get going.
--
--               Run with no argument it starts the command-line tool, as the
--               `lexiftool` launcher does. An embedding host (the C API,
--               capi/lexiftool.c) passes true: the chunk then runs nothing
--               and returns the lexiftool.main module and the launch
--               information for its session (doc/capi.md).
--------------------------------------------------------------------------------

local embedded = ...

if not embedded then
    -- this process owns its signals, as `lexiftool` does (doc/capi.md
    -- "Signals"); an embedding host (capi/session.lua) already set this
    -- Lua state's default -- nosignals(true) -- before calling this chunk
    require('lexiftool.sys').nosignals(false)
end
local mainFn = require('lexiftool.main')
if embedded then return mainFn, { bytecode = true } end
os.exit(mainFn(arg, { bytecode = true }))
