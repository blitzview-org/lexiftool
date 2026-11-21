--------------------------------------------------------------------------------
-- File:         lexiftool/GeoLangData.lua
--
-- Description:  Read ExifTool's Geolocation language translation files,
--               GeoLang/<lang>.pm, as data
--
-- Notes:        A GeoLang file (Geolocation500 package of
--               https://exiftool.org/geolocation.html, or upstream's
--               build_geolocation utility) is a Perl module that only
--               assigns a hash of translations:
--
--                   # comment lines
--
--                   %Image::ExifTool::GeoLang::<lang>::Translate = (
--                       'English name' => 'translation',
--                       PPL => 'feature type translation',
--                   );
--
--                   1; #end
--
--               lexiftool never runs Perl code. Parse reads exactly this
--               shape -- comment and blank lines, one entry per line with a
--               single-quoted or bareword key, `=>`, one single-quoted value
--               and a comma; Perl's \' and \\ escapes in the strings -- and
--               refuses anything else (any other statement, double-quoted
--               or concatenated strings, heredocs, an entry spread over
--               lines, a missing terminator). Geolocation.GetEntry reads
--               the .pm files through it, tools/gen_geolang.lua converts
--               them into their Lua form GeoLang/<lang>.lua with it.
--------------------------------------------------------------------------------

local GeoLangData = {}

-- a Perl single-quoted string starting at position i of s (the opening
-- quote); returns its value (\' and \\ are the only escapes, any other
-- backslash stays) and the position after the closing quote, or nil
local function scanQuoted(s, i)
    local buf, len = {}, #s
    i = i + 1
    while i <= len do
        local c = s:sub(i, i)
        if c == '\\' and i < len then
            local n = s:sub(i + 1, i + 1)
            buf[#buf + 1] = (n == '\\' or n == "'") and n or c .. n
            i = i + 2
        elseif c == "'" then
            return table.concat(buf), i + 1
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    return nil
end

-- one entry line (without its indentation): `'key' => 'value',` or
-- `BAREWORD => 'value',`; returns key and value, or nil
local function parseEntry(rest)
    local key, pos
    if rest:sub(1, 1) == "'" then
        key, pos = scanQuoted(rest, 1)
        if not key then return nil end
    else
        key, pos = rest:match('^([A-Za-z_][A-Za-z0-9_]*)()')
        if not key then return nil end
    end
    pos = rest:match('^[ \t]*=>[ \t]*()', pos)
    if not pos or rest:sub(pos, pos) ~= "'" then return nil end
    local value
    value, pos = scanQuoted(rest, pos)
    if not value or not rest:match('^[ \t]*,[ \t]*$', pos) then return nil end
    return key, value
end

-- Parse the text of a GeoLang/<lang>.pm file.
-- Returns the lines in order and the language the file declares, or nil,
-- an error message and the line number. Each line is a table with `type`:
--   'comment' (text = after the '#', indent), 'blank',
--   'open' (the hash assignment), 'entry' (key, value, indent),
--   'close' (the closing `);`), 'end' (the `1;` true return value)
function GeoLangData.Parse(text)
    local lines, state, lang, lineNo = {}, 'head', nil, 0
    if text ~= '' and text:sub(-1) ~= '\n' then text = text .. '\n' end
    for rawLine in text:gmatch('([^\n]*)\n') do
        lineNo = lineNo + 1
        local line = rawLine
        if line:sub(-1) == '\r' then line = line:sub(1, -2) end
        local item
        local indent, rest = line:match('^([ \t]*)(.*)$')
        if rest == '' then
            item = { type = 'blank' }
        elseif rest:sub(1, 1) == '#' then
            item = { type = 'comment', indent = indent, text = rest:sub(2) }
        elseif state == 'head' then
            lang = line:match('^%%Image::ExifTool::GeoLang::([A-Za-z0-9_]+)::Translate[ \t]*=[ \t]*%([ \t]*$')
            if not lang then
                return nil, "expected %Image::ExifTool::GeoLang::<lang>::Translate = (", lineNo
            end
            item = { type = 'open' }
            state = 'body'
        elseif state == 'body' then
            if rest:match('^%);[ \t]*$') then
                item = { type = 'close' }
                state = 'tail'
            else
                local key, value = parseEntry(rest)
                if not key then return nil, "expected 'KEY' => 'VALUE',", lineNo end
                item = { type = 'entry', indent = indent, key = key, value = value }
            end
        elseif state == 'tail' and (line:match('^1;[ \t]*$') or line:match('^1;[ \t]*#')) then
            item = { type = 'end' }
            state = 'done'
        else
            return nil, 'unexpected statement after the table', lineNo
        end
        lines[#lines + 1] = item
    end
    if state ~= 'tail' and state ~= 'done' then
        return nil, 'incomplete translation table (no closing ");")', lineNo
    end
    return lines, lang
end

-- The translations of the parsed lines (GeoLangData.Parse), as the Perl
-- hash would hold them: key => value, a later entry replacing an earlier one
function GeoLangData.Translate(lines)
    local trans = {}
    for _, item in ipairs(lines) do
        if item.type == 'entry' then trans[item.key] = item.value end
    end
    return trans
end

return GeoLangData
