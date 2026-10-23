#!/usr/bin/env lua
--------------------------------------------------------------------------------
-- File:         rockspecs/update_modules.lua
--
-- Description:  Regenerates the list of Lua modules in every
--               rockspecs/lexiftool-*.rockspec. LuaRocks' "builtin" build
--               type needs each module named explicitly (a rockspec is a
--               sandboxed Lua chunk and cannot scan directories itself), so
--               the block between the "-- BEGIN LUA MODULES" and
--               "-- END LUA MODULES" marker lines is rewritten from the
--               files actually present: src/lexiftool.lua and every .lua
--               file below src/lexiftool/ (test code lives in src/test/ and
--               is never part of the rock). Run it after adding, removing
--               or renaming a module:
--                   lua rockspecs/update_modules.lua
--               Needs luafilesystem (lfs), a dependency of lexiftool anyway.
--------------------------------------------------------------------------------

local lfs = require('lfs')

-- the repository root is the parent of the directory holding this script
local scriptDir = (arg and arg[0] or ''):match('^(.*)[/\\][^/\\]+$') or '.'
local rockDir = scriptDir
local rootDir = scriptDir .. '/..'

-- Collect module name -> source path (relative to the repository root).
local modules = {}
local function scan(relDir, modPrefix)
    for entry in lfs.dir(rootDir .. '/' .. relDir) do
        if entry ~= '.' and entry ~= '..' then
            local rel = relDir .. '/' .. entry
            local mode = lfs.attributes(rootDir .. '/' .. rel, 'mode')
            if mode == 'directory' then
                scan(rel, modPrefix .. entry .. '.')
            elseif mode == 'file' and entry:match('%.lua$') then
                modules[#modules + 1] = { name = modPrefix .. entry:sub(1, -5), path = rel }
            end
        end
    end
end
modules[1] = { name = 'lexiftool', path = 'src/lexiftool.lua' }
scan('src/lexiftool', 'lexiftool.')
table.sort(modules, function(a, b) return a.name < b.name end)

-- Format the block, aligned like the rest of the rockspec.
local width = 0
for _, m in ipairs(modules) do
    local w = #m.name + 6               -- ["name"]
    if w > width then width = w end
end
local lines = {}
for _, m in ipairs(modules) do
    local key = '["' .. m.name .. '"]'
    lines[#lines + 1] = '    ' .. key .. string.rep(' ', width - #key) .. ' = "' .. m.path .. '",'
end
local block = table.concat(lines, '\n')

-- Rewrite each rockspec between the marker lines.
local count = 0
for entry in lfs.dir(rockDir) do
    if entry:match('^lexiftool%-.*%.rockspec$') then
        local fileName = rockDir .. '/' .. entry
        local inFile = assert(io.open(fileName, 'rb'))
        local text = inFile:read('a')
        inFile:close()
        -- keep everything up to and including the BEGIN line and from the
        -- END line on; replace the lines in between
        local out, state = {}, 'head'
        for line in (text .. (text:sub(-1) == '\n' and '' or '\n')):gmatch('([^\n]*)\n') do
            if state == 'head' then
                out[#out + 1] = line
                if line:match('^%s*%-%- BEGIN LUA MODULES') then
                    out[#out + 1] = block
                    state = 'block'
                end
            elseif state == 'block' then
                if line:match('^%s*%-%- END LUA MODULES') then
                    out[#out + 1] = line
                    state = 'tail'
                end
            else
                out[#out + 1] = line
            end
        end
        assert(state == 'tail', fileName .. ': marker lines not found')
        local newText = table.concat(out, '\n') .. '\n'
        if newText ~= text then
            local outFile = assert(io.open(fileName, 'wb'))
            outFile:write(newText)
            outFile:close()
            print(string.format('%-34s %d modules (updated)', entry, #modules))
        else
            print(string.format('%-34s %d modules (unchanged)', entry, #modules))
        end
        count = count + 1
    end
end
assert(count > 0, 'no lexiftool-*.rockspec found in ' .. rockDir)
