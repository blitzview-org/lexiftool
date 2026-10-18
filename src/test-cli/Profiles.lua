--------------------------------------------------------------------------------
-- File:         test-cli/Profiles.lua
--
-- Description:  Tool profiles -- the ONE place that knows a concrete command
--               line.
--
--               The harness is symmetric: it runs "a tool" over "a case list"
--               and compares the resulting trees. Which tool that is comes from
--               here and nowhere else, so neither the runner, the driver nor
--               the comparison ever asks "am I looking at Perl or at Lua?".
--
--               A profile is nothing but:
--                 id    short name, also recorded in the tree manifest
--                 name  label for the banner
--                 cmd   the command prefix, ready for the shell
--
--               There is deliberately no hook for per-tool output rewriting.
--               The one case that used to need it was the help text, where
--               lexiftool differs from upstream on purpose; that is a freshness
--               check on a generated file, not a compatibility question, and it
--               lives in src/test/test_usage.lua where it gates `make check`.
--------------------------------------------------------------------------------

local Util = require('test-cli.Util')

local Profiles = {}

-- cfg: repoDir, luaBin, lexiftool, perlBin, perlLib, perlExiftool
function Profiles.build(cfg)
    local q = Util.shquote
    local perlBin = cfg.perlBin or 'perl'
    local perlArgv = { perlBin, '-I', cfg.perlLib, cfg.perlExiftool }
    local luaArgv = { cfg.luaBin, cfg.lexiftool }
    local function shell(argv)
        local parts = {}
        for i, a in ipairs(argv) do parts[i] = q(a) end
        return table.concat(parts, ' ')
    end
    return {
        ['exiftool-perl'] = {
            id   = 'exiftool-perl',
            name = 'Perl exiftool',
            argv = perlArgv,
            cmd  = shell(perlArgv),
        },
        ['lexiftool'] = {
            id   = 'lexiftool',
            name = 'lexiftool',
            -- Invoked with the same interpreter the harness runs under rather
            -- than via its shebang, so C modules resolved through the
            -- Makefile-supplied LUA_CPATH match the running Lua ABI.
            argv = luaArgv,
            cmd  = shell(luaArgv),
        },
    }
end

-- The tool the reference tree is built from. Fixed: the vendored Perl exiftool
-- is the definition of "correct" for this project.
Profiles.REFERENCE = 'exiftool-perl'

return Profiles
