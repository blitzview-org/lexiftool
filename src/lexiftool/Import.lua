--------------------------------------------------------------------------------
-- File:         lexiftool/Import.lua
-- Ported from:  lib/Image/ExifTool/Import.pm
--
-- Description:  Import CSV and JSON database files
--
-- Revisions:    2011-03-05 - P. Harvey Created
--
-- Port notes:   Complete port of Import.pm: every lookup and sub, in
--               upstream order.  Deviations forced by Lua:
--               - The scalar ref with its pos() that ReadJSONObject shares
--                 with its recursive calls is a table { data = ..., pos = ... }
--                 (pos nil = Perl's undef pos); matchG stands for
--                 `$$buffPt =~ /.../g` in scalar context, which resets pos
--                 on failure as Perl does.
--               - A JSON object is a table with the `_ordered_keys_` list (as
--                 upstream), an array a plain Lua array.
--               - `$file` may be a RandomAccess object, an io file handle
--                 (upstream's GLOB), (ReadJSON) a SCALAR-ref box
--                 `{ ref = 'SCALAR', value = ... }` or a file name.
--               - `local $/` of ReadCSV is the RS argument of ReadLine.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local splitDyn = perl.splitDyn
local quotemeta = perl.quotemeta
local lc = perl.lc
local hex = perl.hex
local length = perl.length
local substr = perl.substr
local truthy = perl.truthy
local ref, keys, grep = perl.ref, perl.keys, perl.grep
local RandomAccess = require('lexiftool.RandomAccess')

local Import = {}

-- (upstream's predeclaration; the sub below assigns to it)
local ReadJSONObject

local unescapeJSON = { ['t'] = "\t", ['n'] = "\n", ['r'] = "\r", ['b'] = "\b", ['f'] = "\f" }
local charset

-- (port helper: Perl's `$$buffPt =~ /pat/g` in scalar context -- match from
--  pos(), set pos() past the match, or reset it to undef on failure)
local function matchG(buffPt, pat)
    local c, e = matches(buffPt.data, pat, buffPt.pos)
    if e == nil then
        buffPt.pos = nil
        return nil
    end
    buffPt.pos = e
    return c
end

--------------------------------------------------------------------------------
-- Read CSV file
-- Inputs: 0) CSV file name, file ref or RAF ref, 1) database hash ref,
--         2) missing tag value, 3) delimiter if other than ','
-- Returns: undef on success, or error string
-- Notes: There are various flavours of CSV, but here we assume that only
--        double quotes are escaped, and they are escaped by doubling them
function Import.ReadCSV(file, database, missingValue, delim)
    local RS        -- (local $/)
    local buff, found, err, raf, openedFile, n
    local tags = {}

    if type(file) == 'table' and getmetatable(file) == RandomAccess then
        raf = file
        file = 'CSV file'
    elseif io.type(file) == 'file' then     -- (ref $file eq 'GLOB')
        raf = RandomAccess.new(file)
        file = 'CSV file'
    else
        openedFile = io.open(file, 'rb')    -- (open CSVFILE, $file; binmode CSVFILE)
        if not openedFile then return "Error opening CSV file '" .. file .. "'" end
        raf = RandomAccess.new(openedFile)
    end
    if delim == nil then delim = ',' end
    -- set input record separator by first newline found in the file
    -- (safe because first line should contain only tag names)
    while true do
        n, buff = raf:Read(65536)
        if not truthy(n) then break end
        local isNL, nl = isMatch(buff, [[(\x0d\x0a|\x0d|\x0a)]])
        if isNL then RS = nl break end
    end
    raf:Seek(0, 0)
    while true do
        n, buff = raf:ReadLine(RS)
        if not truthy(n) then break end
        local vals, v = {}
        local fileInfo = {}
        local toks = splitDyn(quotemeta(delim), buff)
        while #toks > 0 do
            v = table.remove(toks, 1)
            v = subst(v, '^ +', '')  -- remove leading spaces
            if isMatch(v, '^"') then
                v = subst(v, '^"', '')
                -- quoted value must end in an odd number of quotes
                while true do
                    local isQ, q1 = isMatch(v, [[("+)\s*$]])
                    if isQ and (length(q1) & 1) ~= 0 then break end
                    if #toks > 0 then
                        v = v .. delim .. table.remove(toks, 1)
                    else
                        -- read another line from the file
                        n, buff = raf:ReadLine(RS)
                        if not truthy(n) then break end
                        toks = splitDyn(quotemeta(delim), buff)
                        if #toks == 0 then break end
                        v = v .. table.remove(toks, 1)
                    end
                end
                v = subst(v, [["\s*$]], '')     -- remove trailing quote and whitespace
                v = subst(v, '""', '"', 'g')     -- un-escape quotes
            else
                v = subst(v, '[ \n\r]+$', '')  -- remove trailing spaces/newlines
            end
            vals[#vals + 1] = v
        end
        if #tags > 0 then
            -- save values for each tag
            fileInfo._ordered_keys_ = { }
            for i = 1, #vals do
                if i > #tags then break end
                -- ignore empty entries unless missingValue is empty too
                if truthy(length(vals[i])) or (missingValue ~= nil and missingValue == '') then
                    -- delete tag (set value to undef) if value is same as missing tag
                    if missingValue ~= nil and vals[i] == missingValue then
                        fileInfo[tags[i]] = nil
                    else
                        fileInfo[tags[i]] = vals[i]
                    end
                    fileInfo._ordered_keys_[#fileInfo._ordered_keys_ + 1] = tags[i]
                end
            end
            -- figure out the file name to use
            if truthy(fileInfo.SourceFile) then
                database[fileInfo.SourceFile] = fileInfo
                found = 1
            end
        else
            -- the first row should be the tag names
            for _, tag in ipairs(vals) do
                -- terminate at first blank tag name (eg. extra comma at end of line)
                if not truthy(length(tag)) then break end
                if #tags == 0 then tag = subst(tag, [[^\xef\xbb\xbf]], '') end -- remove UTF-8 BOM if it exists
                if not isMatch(tag, [[(?i)^([-_0-9A-Z]+:)*[-_0-9A-Z]+#?$]]) then
                    if isMatch(tag, [[\0]]) then err = "Format error in " .. file .. " (doesn't look like UTF-8)" break end
                    err = "Invalid tag name '" .. tag .. "' in " .. file
                    break
                end
                tags[#tags + 1] = tag
            end
            if err then break end
            if #tags == 0 then err = "No tags found in " .. file break end
            -- fix "SourceFile" case if necessary
            if lc(tags[1]) == 'sourcefile' then tags[1] = 'SourceFile' end
        end
    end
    if openedFile then openedFile:close() end
    raf = nil -- luacheck: ignore 311
    if not (found or err) then err = "No SourceFile column in " .. file end
    return err
end

--------------------------------------------------------------------------------
-- Convert unicode code point to UTF-8
-- Inputs: 0) integer Unicode character
-- Returns: UTF-8 bytes
local function ToUTF8(cp)
    local Charset = require('lexiftool.Charset')
    return Charset.Recompose(nil, { cp }, charset)
end
Import.ToUTF8 = ToUTF8

--------------------------------------------------------------------------------
-- Read JSON object from file
-- Inputs: 0) RAF reference or undef, 1) optional scalar reference for data
--            to read before reading from file (ie. the file read buffer)
-- Returns: JSON object (scalar, hash ref, or array ref), or undef on EOF or
--          empty object or array (and sets $$buffPt to empty string on EOF)
-- Notes: position in buffer is significant
function ReadJSONObject(raf, buffPt)
    -- initialize buffer if necessary
    local pos, readMore, rtnVal, tok, key, didBOM, n, c
    if buffPt then
        pos = buffPt.pos
        if pos == nil then
            buffPt.pos = 0
            pos = 0
        end
    else
        local buff = ''
        buffPt = { data = buff }
        pos = 0
    end
    while true do   -- Tok:
        -- (didn't spend the time to understand how $pos could be undef, but
        --  put a test here to be safe because one user reported this problem)
        if pos == nil then break end
        if pos >= length(buffPt.data) or truthy(readMore) then
            if raf == nil then break end
            -- read another 64kB and add to unparsed data
            local offset = length(buffPt.data) - pos
            if offset ~= 0 then
                local buff
                n, buff = raf:Read(65536)
                if not truthy(n) then buffPt.data = '' break end
                buffPt.data = substr(buffPt.data, pos) .. buff
            else
                n, buffPt.data = raf:Read(65536)
                if not truthy(n) then buffPt.data = '' break end
            end
            if not didBOM then
                buffPt.data = subst(buffPt.data, [[^\xef\xbb\xbf]], '')  -- remove UTF-8 BOM if it exists
                didBOM = 1
            end
            buffPt.pos = 0
            pos = 0
            readMore = 0
        end
        if not tok then
            -- skip white space and find next character
            c = matchG(buffPt, [[(\S)]])
            if c == nil then
                pos = length(buffPt.data)
                goto next_
            end
            tok = c
            pos = buffPt.pos
        end
        -- see what type of object this is
        if tok == '{' then      -- object (hash)
            if rtnVal == nil then rtnVal = { _ordered_keys_ = { } } end
            while true do
                -- read "KEY":"VALUE" pairs
                if key == nil then
                    key = ReadJSONObject(raf, buffPt)
                    pos = buffPt.pos
                end
                -- ($key may be undef for empty JSON object)
                if key ~= nil then
                    -- scan to delimiting ':'
                    c = matchG(buffPt, [[(\S)]])
                    if c == nil then readMore = 1 goto next_ end
                    if c ~= ':' then return nil end  -- error if not a colon
                    local val = ReadJSONObject(raf, buffPt)
                    pos = buffPt.pos
                    if val == nil then return nil end
                    rtnVal[key] = val
                    rtnVal._ordered_keys_[#rtnVal._ordered_keys_ + 1] = key
                    key = nil
                end
                -- scan to delimiting ',' or bounding '}'
                c = matchG(buffPt, [[(\S)]])
                if c == nil then readMore = 1 goto next_ end
                if c == '}' then break end          -- check for end of object
                if c ~= ',' then return nil end     -- error if not a comma
            end
        elseif tok == '[' then  -- array
            if rtnVal == nil then rtnVal = { } end
            while true do
                local item = ReadJSONObject(raf, buffPt)
                pos = buffPt.pos
                -- ($item may be undef for empty array)
                if item ~= nil then rtnVal[#rtnVal + 1] = item end
                -- scan to delimiting ',' or bounding ']'
                c = matchG(buffPt, [[(\S)]])
                if c == nil then readMore = 1 goto next_ end
                if c == ']' then break end          -- check for end of array
                if c ~= ',' then return nil end     -- error if not a comma
            end
        elseif tok == '"' then  -- quoted string
            while true do
                c = matchG(buffPt, [[(\\*)"]])
                if c == nil then readMore = 1 goto next_ end
                if (length(c) & 1) == 0 then break end -- check for escaped quote
            end
            rtnVal = substr(buffPt.data, pos, buffPt.pos - pos - 1)
            -- unescape characters
            rtnVal = subst(rtnVal, [[(?i)\\u([0-9a-f]{4})]], function(h) return ToUTF8(hex(h)) end, 'g')
            rtnVal = subst(rtnVal, [[(?s)\\(.)]], function(e) return truthy(unescapeJSON[e]) and unescapeJSON[e] or e end, 'g')
            -- decode base64 (binary data) values
            if isMatch(rtnVal, [[^base64:[A-Za-z0-9+\/]*={0,2}$]]) and length(rtnVal) % 4 == 3 then
                rtnVal = require('lexiftool.XMP').DecodeBase64(substr(rtnVal, 7))
            end
        elseif tok == ']' or tok == '}' or tok == ',' then
            -- return undef for empty object, array, or list item
            -- (empty list item actually not valid JSON)
            buffPt.pos = buffPt.pos - 1
        else                    -- number, 'true', 'false', 'null'
            c = matchG(buffPt, [=[([\s:,\}\]])]=])
            if c == nil then readMore = 1 goto next_ end
            buffPt.pos = buffPt.pos - 1
            rtnVal = tok .. substr(buffPt.data, pos, buffPt.pos - pos)
        end
        break
        ::next_::
    end
    return rtnVal
end
Import.ReadJSONObject = ReadJSONObject

--------------------------------------------------------------------------------
-- Read JSON file
-- Inputs: 0) JSON file name, file ref, RAF ref or SCALAR ref, 1) database hash ref,
--         2) flag to delete "-" tags, 3) character set
-- Returns: undef on success, or error string
function Import.ReadJSON(file, database, missingValue, chset)
    local raf, openedFile, buff, n

    -- initialize character set for converting "\uHHHH" chars
    charset = truthy(chset) and chset or 'UTF8'
    if type(file) == 'table' and getmetatable(file) == RandomAccess then
        raf = file
        file = 'JSON file'
    elseif io.type(file) == 'file' then     -- (ref $file eq 'GLOB')
        raf = RandomAccess.new(file)
        file = 'JSON file'
    elseif type(file) == 'table' and file.ref == 'SCALAR' then
        raf = RandomAccess.new(file.value)
        file = 'JSON in memory'
    else
        openedFile = io.open(file, 'rb')    -- (open JSONFILE, $file; binmode JSONFILE)
        if not openedFile then return "Error opening JSON file '" .. file .. "'" end
        raf = RandomAccess.new(openedFile)
    end
    local obj = ReadJSONObject(raf)
    if openedFile then openedFile:close() end
    if ref(obj) ~= 'ARRAY' then
        if ref(obj) ~= 'HASH' then
            local err = "Format error in " .. file
            if raf:Seek(0,0) then
                n, buff = raf:Read(64)
                if truthy(n) and isMatch(buff, [[\0]]) then
                    err = err .. " (doesn't look like UTF-8)"
                end
            end
            return err
        end
        obj = { obj }
    end
    local found
    for _, info in ipairs(obj) do
        if ref(info) ~= 'HASH' then goto next end
        -- fix "SourceFile" case, or assume '*' if SourceFile not specified
        if info.SourceFile == nil then
            local key = grep('(?i)^SourceFile$', keys(info))[1]
            if truthy(key) then
                info.SourceFile = info[key]
                info[key] = nil
            else
                info.SourceFile = '*'
            end
        end
        if missingValue ~= nil then
            for _, k in ipairs(keys(info)) do
                if info[k] == missingValue then info[k] = nil end
            end
        end
        database[info.SourceFile] = info
        found = 1
        ::next::
    end
    if found then return nil end
    return "No valid JSON objects in " .. file
end

return Import
