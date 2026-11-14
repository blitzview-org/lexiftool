--------------------------------------------------------------------------------
-- File:         tools/gen_geolang.lua
--
-- Description:  Convert ExifTool's Geolocation language translation files,
--               GeoLang/<lang>.pm, into their Lua form GeoLang/<lang>.lua
--               (written next to each .pm file).
--
--               The .pm files come with the larger geolocation database
--               (Geolocation500-<date>.zip from
--               https://exiftool.org/geolocation.html, directory
--               Geolocation500/GeoLang) or from upstream's build_geolocation
--               utility. Each one is Perl code that only assigns a hash of
--               translations,
--
--                   %Image::ExifTool::GeoLang::<lang>::Translate = (
--                       'English name' => 'translation',
--                       PPL => 'feature type translation',
--                   );
--                   1; #end
--
--               lexiftool reads these files itself, as data (the parser
--               lexiftool.GeoLangData, which this converter uses as well:
--               single-quoted strings with Perl's \' and \\ escapes,
--               bareword keys, comments and blank lines, anything else is
--               refused), so converting them is optional. The Lua form is
--               for editing: lexiftool takes GeoLang/<lang>.lua before a
--               GeoLang/<lang>.pm in the same directory. It returns the same
--               table,
--
--                   return {
--                       ['English name'] = 'translation',
--                       PPL = 'feature type translation',
--                   }
--
--               keeping the entries, their order and the comments.
--
-- Syntax:       <interp> tools/gen_geolang.lua FILE.pm ... | DIR ...
--               (any Lua 5.4/5.5, from any working directory; a DIR
--               argument converts DIR/*.pm, or DIR/GeoLang/*.pm when DIR
--               holds a GeoLang directory, and needs the luafilesystem
--               module)
--------------------------------------------------------------------------------

-- the parser is the library's (src/, the sibling of this script's directory)
local scriptDir = arg[0]:match('^(.*)[/\\][^/\\]+$') or '.'
package.path = scriptDir .. '/../src/?.lua;' .. package.path
local GeoLangData = require('lexiftool.GeoLangData')

-- the files to convert, from the arguments
local function pmFiles(args)
    local files = {}
    for _, a in ipairs(args) do
        if a:match('%.pm$') then
            files[#files + 1] = a
        else
            local ok, lfs = pcall(require, 'lfs')
            if not ok then error('a directory argument needs luafilesystem (lfs): ' .. a, 0) end
            local dir = a:gsub('[/\\]+$', '')
            if lfs.attributes(dir .. '/GeoLang', 'mode') == 'directory' then dir = dir .. '/GeoLang' end
            if lfs.attributes(dir, 'mode') ~= 'directory' then error('not a .pm file or directory: ' .. a, 0) end
            local found = {}
            for f in lfs.dir(dir) do
                if f:match('%.pm$') then found[#found + 1] = dir .. '/' .. f end
            end
            table.sort(found)
            for _, f in ipairs(found) do files[#files + 1] = f end
        end
    end
    return files
end

-- a Lua string literal for the bytes of s
local function quoteLua(s)
    return "'" .. s:gsub("[\\'%c]", function(c)
        if c == '\\' or c == "'" then return '\\' .. c end
        return string.format('\\%03d', c:byte())
    end) .. "'"
end

local LUA_KEYWORDS = {}
for w in ([[and break do else elseif end false for function goto if in local nil not or
            repeat return then true until while]]):gmatch('%a+') do LUA_KEYWORDS[w] = true end

-- a Lua table key for the string k
local function luaKey(k)
    if k:match('^[A-Za-z_][A-Za-z0-9_]*$') and not LUA_KEYWORDS[k] then return k end
    return '[' .. quoteLua(k) .. ']'
end

-- convert one file; returns the number of entries
local function convert(pm)
    local fh = assert(io.open(pm, 'rb'))
    local text = fh:read('a')
    fh:close()
    local lines, err, lineNo = GeoLangData.Parse(text)
    if not lines then
        error(string.format('%s:%d: not a GeoLang translation table (%s)', pm, lineNo, err), 0)
    end
    local out, n = {}, 0
    for _, item in ipairs(lines) do
        local t = item.type
        if t == 'comment' then
            out[#out + 1] = item.indent .. '--' .. item.text
        elseif t == 'blank' then
            out[#out + 1] = ''
        elseif t == 'open' then
            out[#out + 1] = 'return {'
        elseif t == 'entry' then
            out[#out + 1] = item.indent .. luaKey(item.key) .. ' = ' .. quoteLua(item.value) .. ','
            n = n + 1
        elseif t == 'close' then
            out[#out + 1] = '}'
            -- (what follows -- the module's true return value `1;` and
            -- comments -- is not needed in Lua)
            break
        end
    end
    local lua = pm:gsub('%.pm$', '.lua')
    local base = pm:match('([^/\\]+)$')
    -- (after the file's own header comment)
    local i = 1
    while out[i] and out[i]:match('^%-%-') do i = i + 1 end
    table.insert(out, i, '-- (converted from GeoLang/' .. base .. ' by lexiftool\'s tools/gen_geolang.lua)')
    local of = assert(io.open(lua, 'wb'))
    of:write(table.concat(out, '\n'), '\n')
    of:close()
    return n, lua
end

local files = pmFiles(arg)
if #files == 0 then
    io.stderr:write('usage: tools/gen_geolang.lua FILE.pm ... | DIR ...\n',
                    '  writes GeoLang/<lang>.lua next to each GeoLang/<lang>.pm (optional: lexiftool\n',
                    '  reads the .pm files as they are; a .lua takes precedence over the .pm)\n')
    os.exit(2)
end
for _, pm in ipairs(files) do
    local ok, n, lua = pcall(convert, pm)
    if not ok then
        io.stderr:write(n, '\n')
        os.exit(1)
    end
    print(string.format('%s: %d entries', lua, n))
end
