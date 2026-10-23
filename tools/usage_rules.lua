--------------------------------------------------------------------------------
-- File:         tools/usage_rules.lua
--
-- Description:  The single definition of how lexiftool's help text differs
--               from the upstream exiftool help text.
--
--               lexiftool prints the same documentation as upstream, with the
--               tool and library names adapted to this port plus a header and
--               a copyright note. Rather than maintaining that text by hand,
--               it is DERIVED from the original by the search-and-replace
--               rules below, and two places use them:
--
--                 * tools/gen_usage.lua generates src/lexiftool/usage.lua
--                   (what lexiftool actually prints),
--                 * a comparison against the Perl original can apply the
--                   same rules to its help output before comparing.
--
--               So when the vendored exiftool is updated and its help text
--               changes, the CLI test turns red -- the transformed reference
--               no longer matches the generated text -- and `make usage`
--               regenerates it. Without this the divergence would go
--               unnoticed, since a hand-written help text never fails.
--
-- Usage:        local rules = require('usage_rules')  -- from tools/
--               local ported = rules.transform(originalHelpText)
--------------------------------------------------------------------------------

local M = {}

-- Prepended to the generated text: names the port, since every other mention
-- of "exiftool" in the body is rewritten to "lexiftool" and the reader would
-- otherwise have no hint that this is a port at all.
M.PREAMBLE = [[
LEXIFTOOL
    lexiftool is a Lua port of exiftool, the Perl application by Phil Harvey
    (https://exiftool.org/). It aims to be a drop-in replacement: same
    command-line syntax, same output, byte for byte.

    The documentation below is the original exiftool documentation with the
    tool and library names adapted to this port.

]]

-- Appended to the AUTHOR section, right after upstream's licence sentence.
M.COPYRIGHT_ANCHOR = [[
    This is free software; you can redistribute it and/or modify it under
    the same terms as Perl itself.
]]

M.COPYRIGHT_NOTE = [[

    Copyright 2026, Oliver Schmidt -- lexiftool, the Lua port, is derived
    from that work and is distributed under the same terms. All credit for
    exiftool itself belongs to Phil Harvey.

    lexiftool home page: https://github.com/blitzview-org/lexiftool
]]

-- Replacements applied in order. They are all literal (no patterns), so the
-- rules stay readable and cannot misfire on magic characters.
--
-- Order matters, hence the placeholder: rewriting "exiftool" to "lexiftool"
-- first would make later rules match the RESULT again ("lexiftool" contains
-- "exiftool"), turning it into "llexiftool". Every rule therefore produces a
-- placeholder, and only the final pass turns those into the real name.
local LEX = '\1LEX\1'
local LEX_UPPER = '\1LEXUP\1'
local URL = '\1URL\1'

M.RULES = {
    -- 0. The config file: lexiftool's is Lua (doc/configuration.md), an
    --    exiftool config file is Perl code it does not run, so the pointer to
    --    upstream's syntax description is replaced.
    { from = '""). See <https://exiftool.org/config.html> and\n' ..
             '         config_files/example.config in the full ExifTool distribution for\n' ..
             '         details about the configuration file syntax.\n',
      to   = '""). The config file is Lua (a Perl config file is not run), see\n' ..
             '         doc/configuration.md in the ' .. LEX .. ' distribution for its syntax.\n' },
    -- 1. Protect the project's URLs -- exiftool.org is the upstream site and
    --    must not become "lexiftool.org", which does not exist.
    { from = 'https://exiftool.org', to = URL },
    -- 2. The Perl module name. "Image::ExifTool::TagNames" becomes
    --    "lexiftool.TagNames", matching how the Lua modules are required.
    { from = 'Image::ExifTool::', to = LEX .. '.' },
    { from = 'Image::ExifTool', to = LEX },
    -- 3. The distribution is named with a hyphen in the install instructions.
    { from = 'Image-ExifTool', to = LEX },
    -- 4. Section headings are upper case.
    { from = 'EXIFTOOL', to = LEX_UPPER },
    -- 5. The product name and the command name.
    { from = 'ExifTool', to = LEX },
    { from = 'exiftool', to = LEX },
    -- 6. Resolve the placeholders.
    { from = LEX_UPPER, to = 'LEXIFTOOL' },
    { from = LEX, to = 'lexiftool' },
    { from = URL, to = 'https://exiftool.org' },
}

-- Literal (non-pattern) replace-all.
local function replaceLiteral(s, needle, repl)
    local out, i = {}, 1
    while true do
        local a, b = s:find(needle, i, true)
        if not a then
            out[#out + 1] = s:sub(i)
            break
        end
        out[#out + 1] = s:sub(i, a - 1)
        out[#out + 1] = repl
        i = b + 1
    end
    return table.concat(out)
end

-- Upstream closes with a SEE ALSO section listing its Perl manpages
-- (Image::ExifTool(3pm) and friends). Those do not exist for this port and
-- renaming them would only invent references, so the section is dropped
-- entirely -- everything from the heading to the end of the text.
M.DROP_FROM = '\nSEE ALSO\n'

-- Turn upstream's help text into lexiftool's. Returns the text plus an error
-- message when the copyright anchor is missing, which means upstream reworded
-- its AUTHOR section and the note below needs a new home.
function M.transform(text)
    local out = text
    local cut = out:find(M.DROP_FROM, 1, true)
    if cut then out = out:sub(1, cut) end
    for _, rule in ipairs(M.RULES) do
        out = replaceLiteral(out, rule.from, rule.to)
    end
    -- The anchor survives the rules unchanged (it mentions Perl, not exiftool),
    -- so it can be searched for verbatim.
    local anchor = M.COPYRIGHT_ANCHOR
    if not out:find(anchor, 1, true) then
        return M.PREAMBLE .. out, 'copyright anchor not found in upstream text'
    end
    out = replaceLiteral(out, anchor, anchor .. M.COPYRIGHT_NOTE)
    return M.PREAMBLE .. out, nil
end

return M
