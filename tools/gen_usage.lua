--------------------------------------------------------------------------------
-- File:         tools/gen_usage.lua
--
-- Description:  Generates src/lexiftool/usage.lua -- the help text lexiftool
--               prints -- from the vendored Perl exiftool's own help output,
--               using the rules in tools/usage_rules.lua.
--
--               The text is not maintained by hand: it is the upstream
--               documentation with this port's names substituted, so it stays
--               in sync when the vendored exiftool is updated (`make usage`).
--
-- Usage:        make usage
--               (or: lua tools/gen_usage.lua)
--------------------------------------------------------------------------------

local scriptDir = arg[0]:match('^(.*)[/\\][^/\\]+$') or '.'
package.path = scriptDir .. '/?.lua;' .. package.path
local rules = require('usage_rules')

-- Relative to the script, so the tool works from any working directory (and
-- `scriptDir` is plain "tools" when invoked as `lua tools/gen_usage.lua`,
-- which a suffix-strip would miss).
local repoDir = scriptDir .. '/..'
local perlExifTool = repoDir .. '/vendor/exiftool/exiftool'
local perlLib = repoDir .. '/vendor/exiftool/lib'
local outPath = repoDir .. '/src/lexiftool/usage.lua'

local function shquote(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local pipe = io.popen('perl -I ' .. shquote(perlLib) .. ' ' .. shquote(perlExifTool) ..
                      ' --help 2>/dev/null < /dev/null')
if not pipe then
    io.stderr:write('gen_usage.lua: cannot run the vendored Perl exiftool\n')
    os.exit(2)
end
local original = pipe:read('a') or ''
pipe:close()

if #original < 1000 then
    io.stderr:write('gen_usage.lua: upstream help output is suspiciously short (' ..
                    #original .. ' bytes) -- is perl/exiftool available?\n')
    os.exit(2)
end

local text, warn = rules.transform(original)
if warn then
    io.stderr:write('gen_usage.lua: WARNING: ' .. warn .. '\n')
end

-- Pick a long-bracket level the text cannot terminate early.
local level = 0
while text:find(']' .. string.rep('=', level) .. ']', 1, true) do
    level = level + 1
end
local eq = string.rep('=', level)

local out = assert(io.open(outPath, 'wb'))
out:write(
    '-- GENERATED FILE -- do not edit.\n' ..
    '--\n' ..
    '-- lexiftool\'s help text, derived from the vendored exiftool\'s own help\n' ..
    '-- output by tools/gen_usage.lua using the rules in tools/usage_rules.lua.\n' ..
    '-- Regenerate with `make usage` after updating vendor/exiftool.\n' ..
    '\nreturn [' .. eq .. '[\n' .. text .. ']' .. eq .. ']\n')
out:close()

io.stdout:write(('gen_usage.lua: wrote %s (%d bytes, %d lines)\n')
    :format(outPath, #text, select(2, text:gsub('\n', '\n'))))
