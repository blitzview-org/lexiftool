--------------------------------------------------------------------------------
-- File:         lexiftool/XMPStruct.lua
-- Ported from:  lib/Image/ExifTool/XMPStruct.pl
--
-- Description:  XMP structure support
--
-- Revisions:    01/01/2011 - P. Harvey Created
--
-- Port notes:   All subs of XMPStruct.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::XMP package and
--               loads it with `require 'Image/ExifTool/XMPStruct.pl'` right
--               before a call; this port makes it a module of its own, and
--               XMP.lua binds every sub at its AUTOLOAD position to a closure
--               that loads this file on first use (XMP.ConvertStruct,
--               XMP.RestoreStruct, ... keep working for all callers).
--
--               Perl's HASH/ARRAY distinction: a structure built here
--               (InflateStruct, CheckStruct) carries the STRUCT_MARK key, so
--               an empty structure stays apart from an empty list; one built
--               by RestoreStruct is a plain table, which counts as a HASH when
--               it has keys but no [1].  isHashRef/isArrayRef below decide
--               this once for every `ref $x eq 'HASH'/'ARRAY'` of upstream,
--               and OrderedKeys leaves the marker out.  A SCALAR ref is
--               { ref = 'SCALAR', value = ... }, as everywhere in the port; the
--               string InflateStruct parses (upstream `\$val`) is the box
--               { value = <carray> } (doc/api.md §4), as in PDF.lua's
--               ExtractObject; DeleteStruct's path and change counter
--               (`\$path`, `\$changed`) are { value = ... } boxes that hold
--               the plain value (a string path, a number).
--
--               CheckXMP (a CHECK_PROC: the error and the possibly changed
--               value come back), ConformPathToNamespace and AddStructType
--               are WriteXMP.pl's, reached through XMP.lua's AUTOLOAD
--               closures; DeleteStruct is called from WriteXMP.
--------------------------------------------------------------------------------

local tconcat = table.concat

local perl = require('lexiftool.perl')
local tsort = perl.tsort
local carray = require('carray')
local substr = perl.substr
local length = perl.length
local subst, substDyn = perl.subst, perl.substDyn
local matches, matchesDyn = perl.matches, perl.matchesDyn
local isMatch, isMatchDyn = perl.isMatch, perl.isMatchDyn
local sprintf = perl.sprintf
local tr = perl.tr
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local ord = perl.ord
local truthy = perl.truthy
local perlStr = perl.str

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:Utils)`)
local XMP = require('lexiftool.XMP')    -- (upstream `use Image::ExifTool::XMP`)
local XMPStruct = {}

-- (upstream `use vars qw(%specialStruct %stdXlatNS)`: package variables of
--  XMP.pm, read here under their short names)
local specialStruct = XMP.specialStruct
local stdXlatNS = XMP.stdXlatNS
local EscapeXML = XMP.EscapeXML
local EncodeBase64 = XMP.EncodeBase64
local DecodeBase64 = XMP.DecodeBase64
-- (WriteXMP.pl subs, through XMP.lua's AUTOLOAD closures)
local CheckXMP = XMP.CheckXMP
local ConformPathToNamespace = XMP.ConformPathToNamespace
local AddStructType = XMP.AddStructType

-- (upstream's predeclarations `sub SerializeStruct($$;$);` ... are this block
--  of locals; the subs below assign to them)
local SerializeStruct, InflateStruct, DumpStruct, CheckStruct, AddNewStruct, ConvertStruct, EscapeJSON

-- (port helpers: the key that marks a structure built here, Perl's
--  `ref $x eq 'HASH'` / `ref $x eq 'ARRAY'` for the two kinds of structure
--  table, and Image::ExifTool::OrderedKeys without the marker -- see the Port
--  notes)
local STRUCT_MARK = '__struct'
local function isHashRef(obj)
    if type(obj) ~= 'table' or obj.ref ~= nil then return false end
    if obj[STRUCT_MARK] then return true end
    return obj[1] == nil and next(obj) ~= nil
end
local function isArrayRef(obj)
    if type(obj) ~= 'table' or obj.ref ~= nil or obj[STRUCT_MARK] then return false end
    return obj[1] ~= nil or next(obj) == nil
end
local function OrderedKeys(h)
    local keys = {}
    for _, k in ipairs(ExifTool.OrderedKeys(h)) do
        if k ~= STRUCT_MARK then keys[#keys + 1] = k end
    end
    return keys
end
XMPStruct.STRUCT_MARK = STRUCT_MARK
XMPStruct.isHashRef = isHashRef
XMPStruct.isArrayRef = isArrayRef

-- lookups for JSON characters that we escape specially
local jsonChar = { ['"'] = '"', ['\\'] = '\\', ["\b"] = 'b', ["\f"] = 'f', ["\n"] = 'n', ["\r"] = 'r', ["\t"] = 't' }
local jsonEsc  = { ['"'] = '"', ['\\'] = '\\', ['b'] = "\b", ['f'] = "\f", ['n'] = "\n", ['r'] = "\r", ['t'] = "\t" }

--------------------------------------------------------------------------------
-- Serialize a structure (or other object) into a simple string
-- Inputs: 0) ExifTool ref, 1) HASH ref, ARRAY ref, or SCALAR, 2) closing bracket (or undef)
-- Returns: serialized structure string (in format specified by StructFormat option)
-- eg) "{field=text with {braces|}|, and a comma, field2=val2,field3={field4=[a,b]}}"
function SerializeStruct(et, obj, ket)
    local vals, rtnVal = {}
    local sfmt = et:Options('StructFormat')

    if isHashRef(obj) then
        -- support hashes with ordered keys
        for _, key in ipairs(OrderedKeys(obj)) do
            local hdr = truthy(sfmt) and (EscapeJSON(key) .. ':') or (key .. '=')
            vals[#vals + 1] = hdr .. SerializeStruct(et, obj[key], '}')
        end
        rtnVal = '{' .. tconcat(vals, ',') .. '}'
    elseif isArrayRef(obj) then
        for _, val in ipairs(obj) do
            vals[#vals + 1] = SerializeStruct(et, val, ']')
        end
        rtnVal = '[' .. tconcat(vals, ',') .. ']'
    elseif obj ~= nil then
        if type(obj) == 'table' and obj.ref == 'SCALAR' then obj = obj.value end
        obj = perlStr(obj)
        -- escape necessary characters in string (closing bracket plus "," and "|")
        if truthy(sfmt) then
            rtnVal = EscapeJSON(obj, sfmt == 'JSONQ')
        else
            local pat = truthy(ket) and ('\\' .. ket .. '|,|\\|') or ',|\\|'
            rtnVal = substDyn(obj, '(' .. pat .. ')', '|$1', 'g')
            -- also must escape opening bracket or whitespace at start of string
            rtnVal = subst(rtnVal, [[^([\s\[\{])]], '|$1')
        end
    elseif truthy(sfmt) then
        rtnVal = 'null'
    else
        rtnVal = ''     -- allow undefined list items
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Inflate structure (or other object) from a serialized string
-- Inputs: 0) ExifTool ref, 1) reference to object in string form
--           (serialized using the '|' escape, or JSON)
--         2) extra delimiter for scalar values delimiters
-- Returns: 0) object as a SCALAR, HASH ref, or ARRAY ref (or undef on error),
--          1) warning string (or undef)
-- Notes: modifies input string to remove parsed objects
function InflateStruct(et, obj, delim)
    local val, warn, part
    local sfmt = et:Options('StructFormat')
    local ok, en

    ok, en = matches(obj.value, [[(?s)^\s*\{]])
    if ok then
        substr(obj.value, 0, en, '')
        local struct = { [STRUCT_MARK] = true }
        while true do
            local tag
            if truthy(sfmt) then
                tag, en = matches(obj.value, [[(?s)^\s*"(.*?)"\s*:]])
            else
                tag, en = matches(obj.value, [[(?s)^\s*([-\w:.]+#?)\s*=]])
            end
            if tag == nil then break end
            substr(obj.value, 0, en, '')
            local v, w = InflateStruct(et, obj, '}')
            if w and not warn then warn = w end
            if v == nil then return nil, warn end
            struct[tag] = v
            -- eat comma separator, or all done if there wasn't one
            ok, en = matches(obj.value, [[(?s)^\s*,]])
            if not ok then break end
            substr(obj.value, 0, en, '')
        end
        -- eat closing brace and warn if we didn't find one
        ok, en = matches(obj.value, [[(?s)^\s*\}]])
        if ok then
            substr(obj.value, 0, en, '')
        elseif not warn then
            if length(obj.value) > 0 then
                part = subst(obj.value:tostring(), [[(?s)^\s*]], '')
                part = subst(part, [[(?s)[\x0d\x0a].*]], '')
                if length(part) > 30 then part = substr(part, 0, 27) .. '...' end
                warn = "Invalid structure field at '" .. part .. "'"
            else
                warn = 'Missing closing brace for structure'
            end
        end
        val = struct
    else
        ok, en = matches(obj.value, [[(?s)^\s*\[]])
        if ok then
            substr(obj.value, 0, en, '')
            local list = {}
            while true do
                local v, w = InflateStruct(et, obj, ']')
                if w and not warn then warn = w end
                if v == nil then return nil, warn end
                list[#list + 1] = v
                ok, en = matches(obj.value, [[(?s)^\s*,]])
                if not ok then break end
                substr(obj.value, 0, en, '')
            end
            -- eat closing bracket and warn if we didn't find one
            ok, en = matches(obj.value, [=[(?s)^\s*\]]=])
            if ok then
                substr(obj.value, 0, en, '')
            elseif not warn then
                warn = 'Missing closing bracket for list'
            end
            val = list
        else
            obj.value = subst(obj.value, [[(?s)^\s+]], '')    -- remove leading whitespace
            if truthy(sfmt) then
                ok, en = matches(obj.value, [[^"]])
                if ok then
                    substr(obj.value, 0, en, '')
                    val = ''
                    while true do
                        -- ($$obj =~ s/(.*?)"//: the match need not start at 0)
                        local s1, en2 = matches(obj.value, [[(.*?)"]])
                        if s1 == nil then break end
                        substr(obj.value, en2 - length(s1) - 1, length(s1) + 1, '')
                        val = val .. s1
                        local bs = matches(val, [[([\\]+)$]])
                        if not (bs and length(bs) & 0x01 ~= 0) then break end
                        val = substr(val, 0, -1) .. '"'  -- (was an escaped quote)
                    end
                    local b64 = matches(val, [[(?s)^base64:(.*)]])
                    if b64 then
                        val = DecodeBase64(b64)
                    else
                        -- un-escape characters in JSON string
                        val = subst(val, [[(?s)\\(.)]], function(c) return jsonEsc[c] or ('\\' .. c) end, 'g')
                    end
                else
                    local tf, num
                    tf, en = matches(obj.value, [[^(true|false)\b]])
                    if tf then
                        substr(obj.value, 0, en, '')
                        val = '"' .. ucfirst(tf) .. '"'
                    else
                        num, en = matches(obj.value, [[^([+-]?(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?)]])
                        if num then
                            substr(obj.value, 0, en, '')
                            val = num
                        else
                            warn = 'Unknown JSON object'  -- (upstream `$warn or $warn = ...`: never set yet here)
                            val = '""'
                        end
                    end
                end
            else
                -- read scalar up to specified delimiter (or "," if not defined)
                delim = truthy(delim) and ('\\' .. delim .. '|,|\\||$') or ',|\\||$'
                val = ''
                while true do
                    local c1, c2, en3 = matchesDyn(obj.value, '(?s)^(.*?)(' .. delim .. ')')
                    if c1 == nil then break end
                    substr(obj.value, 0, en3, '')
                    val = val .. c1
                    if not truthy(c2) then break end
                    if c2 ~= '|' then
                        obj.value = carray.new('char'):append(c2, obj.value)
                        break
                    end
                    local c, en4 = matches(obj.value, [[(?s)^(.)]])
                    if c then  -- add escaped character
                        substr(obj.value, 0, en4, '')
                        val = val .. c
                    end
                end
            end
        end
    end
    return val, warn
end

--------------------------------------------------------------------------------
-- Escape string for JSON
-- Inputs: 0) string, 1) flag to force numbers to be quoted too
-- Returns: Escaped string (quoted if necessary)
function EscapeJSON(str, quote)
    if not truthy(quote) then
        if str == nil then return 'null' end
        -- JSON boolean (true or false)
        if isMatch(str, [[(?i)^(true|false)$]]) then return lc(str) end
        -- JSON number (see json.org for numerical format)
        -- return $str if $str =~ /^-?(\d|[1-9]\d+)(\.\d+)?(e[-+]?\d+)?$/i;
        -- (these big numbers caused problems for some JSON parsers, so be more conservative)
        if isMatch(str, [[(?i)^-?(\d|[1-9]\d{1,14})(\.\d{1,16})?(e[-+]?\d{1,3})?$]]) then return str end
    end
    if str == nil then return '""' end
    -- encode JSON string in base64 if necessary
    if ExifTool.IsUTF8(str) < 0 then return '"base64:' .. EncodeBase64(str, 1) .. '"' end
    -- escape special characters
    str = subst(str, [[(?s)(["\t\n\r\\])]], function(c) return '\\' .. jsonChar[c] end, 'g')
    str = tr(str, [[\0]], '', 'd')   -- remove all nulls
    -- escape other control characters with \u
    str = subst(str, [[([\0-\x1f])]], function(c) return sprintf('\\u%.4X', ord(c)) end, 'g')
    return '"' .. str .. '"'    -- return the quoted string
end

--------------------------------------------------------------------------------
-- Get XMP language code from tag name string
-- Inputs: 0) tag name string
-- Returns: 0) separated tag name, 1) language code (in standard case), or '' if
--          language code was 'x-default', or undef if the tag had no language code
function XMPStruct.GetLangCode(tag)
    local tg, lang, sub3 = matches(tag, [[(?i)^(\w+)[-_]([a-z]{2,3}|[xi])([-_][a-z\d]{2,8}([-_][a-z\d]{1,8})*)?$]])
    if tg then
        -- normalize case of language codes
        local langCode = lc(lang)
        if sub3 then
            if length(sub3) == 3 then langCode = langCode .. uc(sub3) else langCode = langCode .. lc(sub3) end
        end
        langCode = tr(langCode, '_', '-')   -- RFC 3066 specifies '-' as a separator
        if lc(langCode) == 'x-default' then langCode = '' end
        return tg, langCode
    else
        return tag, nil
    end
end
local GetLangCode = XMPStruct.GetLangCode

--------------------------------------------------------------------------------
-- Debugging routine to dump a structure, list or scalar
-- Inputs: 0) scalar, ARRAY ref or HASH ref, 1) indent (or undef)
function DumpStruct(obj, indent)
    if not truthy(indent) then indent = '' end
    if isHashRef(obj) then
        perl.print(io.stdout, "{\n")
        for _, k in ipairs(OrderedKeys(obj)) do
            perl.print(io.stdout, indent .. '  ' .. k .. ' = ')
            DumpStruct(obj[k], indent .. '  ')
        end
        perl.print(io.stdout, indent, "},\n")
    elseif isArrayRef(obj) then
        perl.print(io.stdout, "[\n")
        for _, v in ipairs(obj) do
            perl.print(io.stdout, indent .. '  ')
            DumpStruct(v, indent .. '  ')
        end
        perl.print(io.stdout, indent, "],\n")
    else
        perl.print(io.stdout, '"' .. perlStr(obj) .. "\",\n")
    end
end

--------------------------------------------------------------------------------
-- Recursively validate structure fields (tags)
-- Inputs: 0) ExifTool ref, 1) Structure ref, 2) structure table definition ref
-- Returns: 0) validated structure ref, 1) error string, or undef on success
-- Notes:
-- - fixes field names in structure and applies inverse conversions to values
-- - copies structure to avoid interdependencies with calling code on referenced values
-- - handles lang-alt tags, and '#' on field names
-- - resets UTF-8 flag of SCALAR values
-- - un-escapes for XML or HTML as per Escape option setting
function CheckStruct(et, struct, strTable)
    local strName = strTable.STRUCT_NAME or ('XMP ' .. (XMP.RegisterNamespace(strTable) or ''))
    if not isHashRef(struct) then return nil, 'Expecting ' .. strName .. ' structure' end

    local err, warn, rtnVal, val
    local copy = { [STRUCT_MARK] = true }
    -- copy the ordered keys if they exist
    if struct._ordered_keys_ then copy._ordered_keys_ = { } end
    local Writer = require('lexiftool.Writer')
    local ConvInv = Writer.ConvInv
    for _, key in ipairs(OrderedKeys(struct)) do
        local tag = key
        -- allow trailing '#' to disable print conversion on a per-field basis
        local type_, fieldInfo
        local t = matches(tag, [[(?s)^(.*)#$]])
        if t then
            tag = t
            type_ = 'ValueConv'
        end
        if not specialStruct[tag] then fieldInfo = strTable[tag] end
        -- fix case of field name if necessary
        if not fieldInfo then
            -- (sort in reverse to get lower case (not special) tags first)
            local fixes = {}
            for k in pairs(strTable) do
                if type(k) == 'string' and isMatchDyn(k, '(?i)^' .. tag .. '$') then fixes[#fixes + 1] = k end
            end
            tsort(fixes)
            local fix = fixes[#fixes]
            if fix and not specialStruct[fix] then
                tag = fix
                fieldInfo = strTable[tag]
            end
        end
        -- (upstream `until (ref $fieldInfo eq 'HASH') { ... }`, which is left
        --  through `last` or `next Key` in its first pass)
        if type(fieldInfo) ~= 'table' then
            -- generate wildcard fields on the fly (eg. mwg-rs:Extensions)
            if not truthy(strTable.NAMESPACE) then
                local grp, tg, langCode
                local m1, m2 = matches(tag, [[^(.+):(.+)]])
                if m1 then grp, tg = lc(m1), m2 else grp, tg = '', tag end
                if grp == 'XMP' then grp = nil end -- (a group of 'XMP' is implied)
                local TagLookup = require('lexiftool.TagLookup')
                local matchList = TagLookup.FindTagInfo(tg)
                -- also look for lang-alt tags
                if #matchList == 0 then
                    tg, langCode = GetLangCode(tg)
                    if langCode ~= nil then matchList = TagLookup.FindTagInfo(tg) end
                end
                local tagInfo, priority, g1
                -- find best matching tag
                for _, ti in ipairs(matchList) do
                    local grps = et:GetGroup(ti)
                    if grps[0] ~= 'XMP' then goto nextTi end
                    if truthy(grp) and grp ~= lc(grps[1]) then goto nextTi end
                    -- must be lang-alt tag if we are writing an alternate language
                    if langCode ~= nil and not (ti.Writable and ti.Writable == 'lang-alt') then goto nextTi end
                    do
                        local pri = ti.Priority or 1
                        if truthy(ti.Avoid) then pri = pri - 10 end
                        if priority ~= nil and priority >= pri then goto nextTi end
                        priority = pri
                        tagInfo = ti
                        g1 = grps[1]
                    end
                    ::nextTi::
                end
                if not tagInfo then
                    warn = "'" .. tag .. "' is not a writable XMP tag"
                    goto nextKey
                end
                XMP.GetPropertyPath(tagInfo)    -- make sure property path is generated for this tag
                tag = tagInfo.Name
                if truthy(grp) then tag = g1 .. ':' .. tag end
                if truthy(langCode) then tag = tag .. '-' .. langCode end
                fieldInfo = strTable[tag]
                -- create new structure field if necessary
                if not fieldInfo then
                    fieldInfo = {}
                    for k, v in pairs(tagInfo) do fieldInfo[k] = v end -- (also copies the necessary TagID and PropertyPath)
                    fieldInfo.Namespace = tagInfo.Namespace or tagInfo.Table.NAMESPACE
                    fieldInfo.LangCode = langCode
                    strTable[tag] = fieldInfo
                end
                -- delete stuff we don't need (shouldn't cause harm, but better safe than sorry)
                -- - need to keep StructType and Table in case we need to call AddStructType later
                fieldInfo.Description = nil
                fieldInfo.Groups = nil
                goto fieldOK -- write this dynamically-generated field
            end
            -- generate lang-alt fields on the fly (eg. Iptc4xmpExt:AOTitle)
            local tg, langCode = GetLangCode(tag)
            if langCode ~= nil then
                if not specialStruct[tg] then fieldInfo = strTable[tg] end
                if not fieldInfo then
                    local fixes = {}
                    for k in pairs(strTable) do
                        if type(k) == 'string' and isMatchDyn(k, '(?i)^' .. tg .. '$') then fixes[#fixes + 1] = k end
                    end
                    tsort(fixes)
                    local fix = fixes[#fixes]
                    if fix and not specialStruct[fix] then
                        tg = fix
                        fieldInfo = strTable[tg]
                    end
                end
                if type(fieldInfo) == 'table' and fieldInfo.Writable and
                    fieldInfo.Writable == 'lang-alt'
                then
                    local srcInfo = fieldInfo
                    if truthy(langCode) then tag = tg .. '-' .. langCode end
                    fieldInfo = strTable[tag]
                    -- create new structure field if necessary
                    if not fieldInfo then
                        fieldInfo = {}
                        for k, v in pairs(srcInfo) do fieldInfo[k] = v end
                        fieldInfo.TagID = tg
                        fieldInfo.LangCode = langCode
                        strTable[tag] = fieldInfo
                    end
                    goto fieldOK -- write this lang-alt field
                end
            end
            warn = "'" .. tag .. "' is not a field of " .. strName
            goto nextKey
        end
        ::fieldOK::
        if isHashRef(struct[key]) then
            if not fieldInfo.Struct then
                warn = tag .. ' is not a structure in ' .. strName
                goto nextKey
            end
            -- recursively check this structure
            val, err = CheckStruct(et, struct[key], fieldInfo.Struct)
            if err then
                warn = err
                goto nextKey
            end
            copy[tag] = val
        elseif isArrayRef(struct[key]) then
            if not fieldInfo.List then
                warn = tag .. ' is not a list in ' .. strName
                goto nextKey
            end
            -- check all items in the list
            local list = {}
            local i = 0
            for _, item in ipairs(struct[key]) do
                if type(item) ~= 'table' then
                    if item == nil then item = '' end -- use empty string for missing items
                    if fieldInfo.Struct then
                        -- (allow empty structures)
                        if not isMatch(perlStr(item), [[^\s*$]]) then
                            warn = tag .. ' items are not valid structures'
                            goto nextKey
                        end
                        list[i + 1] = { [STRUCT_MARK] = true } -- create hash for empty structure
                    else
                        item = Writer.Sanitize(et, item)
                        list[i + 1], err = ConvInv(et, item, fieldInfo, tag, strName, type_, '')
                        if list[i + 1] == nil then list[i + 1] = '' end    -- avoid undefined item
                        if err then
                            warn = err
                            goto nextKey
                        end
                        err, list[i + 1] = CheckXMP(et, fieldInfo, list[i + 1])
                        if err then
                            warn = err .. ' in ' .. strName .. ' ' .. tag
                            goto nextKey
                        end
                    end
                elseif isHashRef(item) then
                    if not fieldInfo.Struct then
                        warn = tag .. ' is not a structure in ' .. strName
                        goto nextKey
                    end
                    list[i + 1], err = CheckStruct(et, item, fieldInfo.Struct)
                    if err then
                        warn = err
                        goto nextKey
                    end
                else
                    warn = 'Invalid value for ' .. tag .. ' in ' .. strName
                    goto nextKey
                end
                i = i + 1
            end
            copy[tag] = list
        elseif fieldInfo.Struct then
            warn = 'Improperly formed structure in ' .. strName .. ' ' .. tag
            goto nextKey
        else
            struct[key] = Writer.Sanitize(et, struct[key])
            val, err = ConvInv(et, struct[key], fieldInfo, tag, strName, type_, '')
            if err then
                warn = err
                goto nextKey
            end
            if val == nil then goto nextKey end -- check for undefined
            err, val = CheckXMP(et, fieldInfo, val)
            if err then
                warn = err .. ' in ' .. strName .. ' ' .. tag
                goto nextKey
            end
            -- turn this into a list if necessary
            if fieldInfo.List then copy[tag] = { val } else copy[tag] = val end
        end
        if copy._ordered_keys_ then table.insert(copy._ordered_keys_, tag) end -- save ordered keys
        ::nextKey::
    end
    local hasCopy = false
    for k in pairs(copy) do
        if k ~= STRUCT_MARK then hasCopy = true break end
    end
    if hasCopy or not warn then
        rtnVal = copy
        err = nil
        if warn then et.CHECK_WARN = warn end
    else
        err = warn
    end
    return rtnVal, err
end

--------------------------------------------------------------------------------
-- Delete matching structures from existing linearized XMP
-- Inputs: 0) ExifTool ref, 1) capture hash ref, 2) structure path ref,
--         3) new value hash ref, 4) reference to change counter
-- Returns: 0) delete flag, 1) list index of deleted structure if adding to list
--          2) flag set if structure existed
-- Notes: updates path to new base path for structure to be added
function XMPStruct.DeleteStruct(et, capture, pathPt, nvHash, changed)
    local deleted, added, existed, pp, delPath
    local structPaths, matchingPaths, delPaths = {}, {}, {}

    -- find all existing elements belonging to this structure
    pp = subst(pathPt.value, [[ \d+]], [[ \\d+]], 'g')
    for p in pairs(capture) do
        if isMatchDyn(p, '^' .. pp .. '(/|$)') then structPaths[#structPaths + 1] = p end
    end
    tsort(structPaths)
    if #structPaths > 0 then existed = 1 end
    -- delete only structures with matching fields if necessary
    if nvHash.DelValue then
        if #nvHash.DelValue > 0 then
            local strTable = nvHash.TagInfo.Struct
            -- all fields must match corresponding elements in the same
            -- root structure for it to be deleted
            for _, val in ipairs(nvHash.DelValue) do
                if not isHashRef(val) then goto nextVal end
                do
                    local cap, match = {}, {}
                    if AddNewStruct(nil, nil, cap, pathPt.value, val, strTable) == 0 then goto nextVal end
                    for p in pairs(cap) do
                        if isMatch(p, ' ') then
                            local p2 = subst(p, [[ \d+]], [[ \\d+]], 'g')
                            matchingPaths = {}
                            for _, sp in ipairs(structPaths) do
                                if isMatchDyn(sp, '^' .. p2 .. '$') then matchingPaths[#matchingPaths + 1] = sp end
                            end
                            tsort(matchingPaths)
                        else
                            matchingPaths[#matchingPaths + 1] = p
                        end
                        for _, p2 in ipairs(matchingPaths) do
                            local root = matchesDyn(p2, '^(' .. pp .. ')')
                            if not root then goto nextP2 end
                            do
                                -- language attribute must also match if it exists
                                local attr = cap[p][2]
                                if attr['xml:lang'] then
                                    local a2 = capture[p2] and capture[p2][2] or {}
                                    if not (a2['xml:lang'] and a2['xml:lang'] == attr['xml:lang']) then goto nextP2 end
                                end
                                if capture[p2] and capture[p2][1] == cap[p][1] then
                                    -- ($1 contains root path for this structure)
                                    match[root] = (match[root] or 0) + 1
                                end
                            end
                            ::nextP2::
                        end
                    end
                    local num = 0
                    for _ in pairs(cap) do num = num + 1 end
                    for p in pairs(match) do
                        -- do nothing unless all fields matched the same structure
                        if match[p] == num then
                            -- delete all elements of this structure
                            for _, p2 in ipairs(structPaths) do
                                if isMatchDyn(p2, '^' .. p) then delPaths[#delPaths + 1] = p2 end
                            end
                            -- remember path of first deleted structure
                            if not delPath or perl.lt(p, delPath) then delPath = p end
                        end
                    end
                end
                ::nextVal::
            end
        end -- (else don't delete anything)
    elseif #structPaths > 0 then
        delPaths = structPaths  -- delete all
        delPath = matchesDyn(structPaths[1], '^(' .. pp .. ')')
    end
    if #delPaths > 0 then
        local verbose = et:Options('Verbose') or 0  -- (undef > 1 is false in Perl)
        if verbose > 1 then tsort(delPaths) end
        for _, p in ipairs(delPaths) do
            if verbose > 1 then
                local p2 = subst(p, [[^(\w+)]], function(ns) return stdXlatNS[ns] or ns end)
                et:VerboseValue('- XMP-' .. p2, capture[p][1])
            end
            capture[p] = nil
            deleted = 1
            changed.value = changed.value + 1
        end
        if not delPath then
            perl.print(io.stderr, "Internal error 1 in DeleteStruct\n")
            return nil, nil, existed
        end
        pathPt.value = delPath  -- return path of first element deleted
    elseif nvHash.TagInfo.List then
        -- NOTE: we don't yet properly handle lang-alt elements!!!!
        if #structPaths > 0 then
            local path = matchesDyn(structPaths[#structPaths], '^(' .. pp .. ')')
            if not path then
                perl.print(io.stderr, "Internal error 2 in DeleteStruct\n")
                return nil, nil, existed
            end
            -- delete any improperly formatted xmp
            if capture[path] then
                local cap = capture[path]
                -- an error unless this was an empty structure
                if type(cap) ~= 'table' or truthy(cap[1]) then
                    et:Error('Improperly structured XMP (' .. path .. ')', 1)
                end
                capture[path] = nil
            end
            -- (match last index to put in same lang-alt list for Bag of lang-alt items)
            local pos
            added, pos = matches(path, [[.* (\d+)]])
            if not added then
                perl.print(io.stderr, "Internal error 3 in DeleteStruct\n")
                return nil, nil, existed
            end
            -- add after last item in list
            local len = length(added)
            pos = pos - len
            local nxt = tonumber(substr(added, 1)) + 1
            path = substr(path, 0, pos) .. length(nxt) .. nxt .. substr(path, pos + len)
            pathPt.value = path
        else
            added = '10'
        end
    end
    return deleted, added, existed
end

--------------------------------------------------------------------------------
-- Add new element to XMP capture hash
-- Inputs: 0) ExifTool ref, 1) TagInfo ref, 2) capture hash ref,
--         3) resource path, 4) value ref, 5) hash ref for last used index numbers
-- (the value is passed as is: upstream's `\$val` only saves a copy)
function XMPStruct.AddNewTag(et, tagInfo, capture, path, valPtr, langIdx)
    local val = EscapeXML(perlStr(valPtr))
    local attrs = {}
    -- support writing RDF "resource" values
    if tagInfo.Resource then
        attrs['rdf:resource'] = val
        val = ''
    end
    if tagInfo.Writable and tagInfo.Writable == 'lang-alt' then
        -- write the lang-alt tag
        local langCode = tagInfo.LangCode
        -- add indexed lang-alt list properties
        local i = langIdx[path] or 0
        langIdx[path] = i + 1 -- save next list index
        if i ~= 0 then
            local idx = length(i) .. i
            path = subst(path, [[(.*) \d+]], '$1 ' .. idx)   -- set list index
        end
        attrs['xml:lang'] = truthy(langCode) and langCode or 'x-default'
    end
    capture[path] = { val, attrs }
    -- print verbose message
    if et and (et:Options('Verbose') or 0) > 1 then
        local p = subst(path, [[^(\w+)]], function(ns) return stdXlatNS[ns] or ns end)
        et:VerboseValue('+ XMP-' .. p, val)
    end
end
local AddNewTag = XMPStruct.AddNewTag

--------------------------------------------------------------------------------
-- Add new structure to capture hash for writing
-- Inputs: 0) ExifTool object ref (or undef for no warnings),
--         1) tagInfo ref (or undef if no ExifTool), 2) capture hash ref,
--         3) base path, 4) struct ref, 5) struct hash ref
-- Returns: number of tags changed
-- Notes: Escapes values for XML
function AddNewStruct(et, tagInfo, capture, basePath, struct, strTable)
    local verbose = et and et:Options('Verbose') or 0   -- (undef counts as 0)
    local langIdx = {}

    local ns = strTable.NAMESPACE or ''
    local changed = 0

    -- add dummy field to allow empty structures (name starts with '~' so it will come
    -- after all valid structure fields, which is necessary when serializing the XMP later)
    if #OrderedKeys(struct) == 0 then struct['~dummy~'] = '' end

    for _, tag in ipairs(OrderedKeys(struct)) do
        local fieldInfo = strTable[tag]
        if not fieldInfo then
            if tag ~= '~dummy~' then goto nextTag end -- check for dummy field
            fieldInfo = { } -- create dummy field info for dummy structure
        end
        do
            local val = struct[tag]
            local propPath = fieldInfo.PropertyPath
            if not propPath then
                propPath = (fieldInfo.Namespace or ns) .. ':' .. (fieldInfo.TagID or tag)
                if fieldInfo.List then
                    propPath = propPath .. '/rdf:' .. fieldInfo.List .. '/rdf:li 10'
                end
                if fieldInfo.Writable and fieldInfo.Writable == 'lang-alt' then
                    propPath = propPath .. '/rdf:Alt/rdf:li 10'
                end
                fieldInfo.PropertyPath = propPath   -- save for next time
            end
            local path = basePath .. '/' .. ConformPathToNamespace(et, propPath)
            local addedTag
            if isHashRef(val) then
                local subStruct = fieldInfo.Struct
                if not subStruct then goto nextTag end
                changed = changed + AddNewStruct(et, tagInfo, capture, path, val, subStruct)
            elseif isArrayRef(val) then
                if not fieldInfo.List then goto nextTag end
                local i = 0
                local p
                local level = #perl.findAll(propPath, [[ \d+]])
                -- loop through all list items (note: can't yet write multi-dimensional lists)
                for _, item in ipairs(val) do
                    if i ~= 0 then
                        -- update first index in field property (may be list of lang-alt lists)
                        p = ConformPathToNamespace(et, propPath)
                        local idx = length(i) .. i
                        p = subst(p, [[ \d+]], ' ' .. idx)
                        p = basePath .. '/' .. p
                    else
                        p = path
                    end
                    if isHashRef(item) then
                        local subStruct = fieldInfo.Struct
                        if not subStruct then goto nextItem end
                        if AddNewStruct(et, tagInfo, capture, p, item, subStruct) == 0 then goto nextItem end
                    -- don't write empty items in upper-level list
                    elseif truthy(length(item)) or (item ~= nil and level == 1) then
                        AddNewTag(et, fieldInfo, capture, p, item, langIdx)
                        addedTag = 1
                    end
                    changed = changed + 1
                    i = i + 1
                    ::nextItem::
                end
            else
                AddNewTag(et, fieldInfo, capture, path, val, langIdx)
                addedTag = 1
                changed = changed + 1
            end
            -- this is tricky, but we must add the rdf:type for contained structures
            -- in the case that a whole hierarchy was added at once by writing a
            -- flattened tag inside a variable-namespace structure
            if addedTag and fieldInfo.StructType and fieldInfo.Table then
                AddStructType(et, fieldInfo.Table, capture, propPath, basePath)
            end
        end
        ::nextTag::
    end
    -- add 'rdf:type' property if necessary
    if strTable.TYPE and changed ~= 0 then
        local path = basePath .. '/' .. ConformPathToNamespace(et, 'rdf:type')
        if not capture[path] then
            capture[path] = { '', { ['rdf:resource'] = strTable.TYPE } }
            if verbose > 1 then
                local p = subst(path, [[^(\w+)]], function(n) return stdXlatNS[n] or n end)
                et:VerboseValue('+ XMP-' .. p, strTable.TYPE)
            end
        end
    end
    return changed
end

--------------------------------------------------------------------------------
-- Convert structure field values for printing
-- Inputs: 0) ExifTool ref, 1) tagInfo ref for structure tag, 2) value,
--         3) conversion type: PrintConv, ValueConv or Raw (Both not allowed)
--         4) tagID of parent structure (needed only if there was no flattened tag)
-- Notes: Makes a copy of the hash so any applied escapes won't affect raw values
function ConvertStruct(et, tagInfo, value, type_, parentID)
    if isHashRef(value) then
        local struct = {}
        local tbl = tagInfo.Table
        if not truthy(parentID) then parentID = tagInfo.TagID end
        if value._ordered_keys_ then struct._ordered_keys_ = { } end
        for _, key in ipairs(OrderedKeys(value)) do
            local tagID = perlStr(parentID) .. ucfirst(key)
            local flatInfo = tbl and tbl[tagID]
            if not flatInfo then
                -- handle variable-namespace structures
                local m1, m2 = matches(key, [[^XMP-(.*?:)(.*)]])
                if m1 then
                    tagID = m1 .. perlStr(parentID) .. ucfirst(m2)
                    flatInfo = tbl and tbl[tagID]
                end
                if not flatInfo then flatInfo = tagInfo end
            end
            local v = value[key]
            if type(v) == 'table' and v.ref == nil then
                v = ConvertStruct(et, flatInfo, v, type_, tagID)
            else
                v = et:GetValue(flatInfo, type_, v)
            end
            if v ~= nil then
                struct[key] = v  -- save the converted value
                -- maintain ordered keys if necessary
                if struct._ordered_keys_ then table.insert(struct._ordered_keys_, key) end
            end
        end
        return struct
    elseif isArrayRef(value) then
        if et.OPTIONS.ListItem ~= nil then
            local li = et.OPTIONS.ListItem
            if value[li + 1] == nil then return nil end
            et.OPTIONS.ListItem = nil       -- only do top-level list
            local val = ConvertStruct(et, tagInfo, value[li + 1], type_, parentID)
            et.OPTIONS.ListItem = li
            return val
        else
            local list = {}
            for _, val in ipairs(value) do
                local v = ConvertStruct(et, tagInfo, val, type_, parentID)
                if v ~= nil then list[#list + 1] = v end
            end
            return list
        end
    else
        return et:GetValue(tagInfo, type_, value)
    end
end

--------------------------------------------------------------------------------
-- Restore XMP structures in extracted information
-- Inputs: 0) ExifTool object ref, 1) flag to keep original flattened tags
-- Notes: also restores lists (including multi-dimensional)
function XMPStruct.RestoreStruct(et, keepFlat)
    local structs, var, lists, listKeys, siList = {}, {}, {}, {}, {}
    -- Perl tells a freshly created empty ARRAY ref from an empty HASH ref;
    -- Lua cannot, so the lists this routine builds are tracked explicitly,
    -- together with the highest index written to each of them (a Lua array
    -- cannot hold the nil gaps a Perl array can, so the fill-in step at the
    -- end needs to be told how long the list really is)
    local isList, listLen = {}, {}
    local valueHash = et.VALUE
    local fileOrder = et.FILE_ORDER
    local tagExtra = et.TAG_EXTRA
    local function newListRef()
        local t = {}
        isList[t] = true
        listLen[t] = 0
        return t
    end
    local function setIdx(arr, idx, v)
        arr[idx + 1] = v
        if listLen[arr] < idx + 1 then listLen[arr] = idx + 1 end
        return v
    end
    -- (upstream iterates `keys %{$$et{TAG_INFO}}` in Perl's hash order; take
    --  the keys in sorted order instead, which is deterministic and matches
    --  the `lt` comparison used below to keep the lowest-numbered key)
    local allKeys = {}
    for k in pairs(et.TAG_INFO) do allKeys[#allKeys + 1] = k end
    tsort(allKeys)
    for _, key in ipairs(allKeys) do
        local extra = tagExtra[key]
        local structProps = extra and extra.Struct
        if structProps and et.TAG_INFO[key] then
            extra.Struct = nil              -- (don't re-use)
            local tagInfo = et.TAG_INFO[key] -- tagInfo for flattened tag
            local tbl = tagInfo.Table
            local prop = table.remove(structProps, 1)
            local tag = prop[1]
            -- get reference to structure tag (or normal list tag if not a structure)
            -- (Perl `@$structProps ? $$table{$tag} : $tagInfo`: spelt out, since
            --  `a and b or c` falls through to c when $$table{$tag} is nil --
            --  an unknown structure then passed for the flattened tag itself)
            local strInfo
            if #structProps > 0 then
                strInfo = tbl[tag]
            else
                strInfo = tagInfo
            end
            local skip = false
            if type(strInfo) == 'table' then
                if #structProps > 0 and not strInfo.Struct then
                    -- this could happen for invalid XMP containing mixed lists
                    if not et.NO_STRUCT_WARN then
                        et:Warn(perlStr(strInfo.Name) .. ' is not a structure!')
                    end
                    skip = true
                end
            elseif strInfo then
                skip = true                 -- (just to be safe)
            else
                -- create new entry in tag table for this structure
                local g1 = (tbl and tbl.GROUPS and tbl.GROUPS[0]) or 'XMP'
                local name = tag
                -- tag keys will have a group 1 prefix when coming from import of XML from -X option
                local pfx, nm = tag:match('^(.+):(.+)$')
                if pfx then
                    name = nm
                    local ns = pfx:gsub('^XMP%-', '') -- remove leading "XMP-" if it exists because we add it later
                    ns = stdXlatNS[ns] or ns
                    g1 = g1 .. '-' .. ns
                end
                strInfo = {
                    Name = ucfirst(name),
                    Groups = { [1] = g1 },
                    Struct = 'Unknown',
                }
                -- add Struct entry if this is a structure
                if #structProps > 0 then
                    strInfo.Struct = { STRUCT_NAME = 'XMP Unknown' }
                elseif tagInfo.LangCode then
                    -- this is lang-alt list
                    tag = tag .. '-' .. tagInfo.LangCode
                    strInfo.LangCode = tagInfo.LangCode
                end
                et:AddTagToTable(tbl, tag, strInfo)
            end
            if not skip then
                -- use strInfo ref for base key to avoid collisions
                tag = strInfo
                local struct = structs
                local oldStruct = structs[strInfo]
                -- (fyi: 'lang-alt' Writable type will be valid even if tag is not pre-defined)
                local writable = tagInfo.Writable or ''
                -- walk through the stored structure property information
                -- to rebuild this structure
                local err
                while true do
                    local index = prop[2]
                    if index and #structProps == 0 then
                        -- ignore this list if it is a simple lang-alt tag
                        if writable == 'lang-alt' then
                            prop[#prop] = nil   -- remove lang-alt index
                            if #prop < 2 then index = nil end
                        end
                        -- add language code if necessary
                        if tagInfo.LangCode and type(tag) ~= 'table' then
                            tag = tag .. '-' .. tagInfo.LangCode
                        end
                    end
                    local nextStruct = struct[tag]
                    if index ~= nil then
                        -- the field is a list
                        index = tonumber(substr(index, 1))  -- remove digit count
                        if nextStruct then
                            if not isList[nextStruct] then
                                err = 2
                                break
                            end
                            struct = nextStruct
                        else
                            local newList = newListRef()
                            struct[tag] = newList
                            struct = newList
                        end
                        nextStruct = struct[index + 1]
                        -- descend into multi-dimensional lists
                        local i = 3
                        while prop[i] do
                            if nextStruct then
                                if not isList[nextStruct] then break end
                                struct = nextStruct
                            else
                                lists[struct] = struct
                                local newList = newListRef()
                                setIdx(struct, index, newList)
                                struct = newList
                            end
                            nextStruct = struct[index + 1]
                            index = tonumber(substr(prop[i], 1))
                            i = i + 1
                        end
                        if type(nextStruct) == 'table' and not isList[nextStruct] then
                            struct = nextStruct     -- continue building sub-structure
                        elseif #structProps > 0 then
                            lists[struct] = struct
                            local newStruct = {}
                            setIdx(struct, index, newStruct)
                            struct = newStruct
                        else
                            lists[struct] = struct
                            setIdx(struct, index, valueHash[key])
                            break
                        end
                    else
                        if nextStruct then
                            if type(nextStruct) ~= 'table' or isList[nextStruct] then
                                err = 3
                                break
                            end
                            struct = nextStruct
                        elseif #structProps > 0 then
                            local newStruct = {}
                            struct[tag] = newStruct
                            struct = newStruct
                        else
                            struct[tag] = valueHash[key]
                            break
                        end
                    end
                    prop = table.remove(structProps, 1)
                    if not prop then break end
                    tag = prop[1]
                    local ns, nm = tag:match('^(.+):(.+)$')
                    if ns then
                        -- tag in variable-namespace tables will have a leading
                        -- XMP namespace on the tag name.  In this case, add
                        -- the corresponding group1 name to the tag ID.
                        ns = stdXlatNS[ns] or ns
                        tag = 'XMP-' .. ns .. ':' .. ucfirst(nm)
                    else
                        tag = ucfirst(tag)
                    end
                end
                if err then
                    -- this may happen if we have a structural error in the XMP
                    -- (like an improperly contained list for example)
                    if not et.NO_STRUCT_WARN then
                        local ns = tagInfo.Namespace or
                            (tagInfo.Table and tagInfo.Table.NAMESPACE) or ''
                        et:Warn('Error ' .. err .. ' placing ' .. ns .. ':' ..
                            perlStr(tagInfo.TagID) .. ' in structure or list', 1)
                    end
                    if not oldStruct then structs[strInfo] = nil end
                elseif tagInfo == strInfo then
                    -- just a regular list tag (or an empty structure)
                    local dropped = false
                    if oldStruct then
                        -- keep tag with lowest numbered key (well, not exactly, since
                        -- "Tag (10)" is lt "Tag (2)", but at least "Tag" is lt
                        -- everything else, and this is really what we care about)
                        local k = listKeys[oldStruct]
                        if k then   -- (k will be nil for an empty structure)
                            if perl.lt(k, key) then
                                -- keep lowest file order
                                if fileOrder[k] > fileOrder[key] then fileOrder[k] = fileOrder[key] end
                                et:DeleteTag(key)
                                dropped = true
                            else
                                if fileOrder[key] > fileOrder[k] then fileOrder[key] = fileOrder[k] end
                                et:DeleteTag(k)   -- remove tag with greater copy number
                            end
                        end
                    end
                    if not dropped then
                        -- replace existing value with new list
                        valueHash[key] = structs[strInfo]
                        listKeys[structs[strInfo]] = key -- save key for this list tag
                    end
                else
                    -- save strInfo ref and file order
                    if var[strInfo] then
                        -- set file order to just before the first associated flattened tag
                        if var[strInfo][2] > fileOrder[key] then
                            var[strInfo][2] = fileOrder[key] - 0.5
                        end
                    else
                        var[strInfo] = { strInfo, fileOrder[key] - 0.5 }
                    end
                    -- preserve original flattened tags if requested
                    if keepFlat then
                        -- restore list behaviour of this flattened tag
                        if extra.NoList then
                            valueHash[key] = extra.NoList
                            extra.NoList = nil
                        elseif extra.NoListDel then
                            -- delete this tag since its value was included another list
                            et:DeleteTag(key)
                        end
                    else
                        et:DeleteTag(key) -- delete the flattened tag
                    end
                end
            end
        end
    end
    -- fill in undefined items in lists.  In theory, undefined list items should
    -- be fine, but in practice the calling code may not check for this (and
    -- historically this wasn't necessary, so do this for backward compatibility)
    for si in pairs(lists) do
        for i = 1, listLen[si] do
            if si[i] == nil then si[i] = '' end
        end
    end
    -- make a list of all new structures we generated
    for si in pairs(structs) do
        if var[si] then siList[#siList + 1] = si end
    end
    -- save new structures in the same order they were read from file
    tsort(siList, function(a, b) return var[a][2] < var[b][2] end)
    for _, si in ipairs(siList) do
        -- test to see if a tag for this structure has already been generated
        -- (this could happen only if one of the structures in a list was empty)
        local key = var[si][1].Name
        local found
        if valueHash[key] then
            for k in pairs(valueHash) do
                if k == key or k:match('^' .. key:gsub('[^A-Za-z0-9]', '%%%0') .. ' %(%d+%)$') then
                    if valueHash[k] == structs[si] then
                        key = k
                        found = 1
                        break
                    end
                end
            end
        end
        if not found then
            -- otherwise, generate a new tag for this structure
            key = et:FoundTag(var[si][1], '')
            valueHash[key] = structs[si]
        end
        fileOrder[key] = var[si][2]
    end
end

-- (the predeclared subs, published for XMP.lua's AUTOLOAD closures)
XMPStruct.SerializeStruct = SerializeStruct
XMPStruct.InflateStruct = InflateStruct
XMPStruct.DumpStruct = DumpStruct
XMPStruct.CheckStruct = CheckStruct
XMPStruct.AddNewStruct = AddNewStruct
XMPStruct.ConvertStruct = ConvertStruct
XMPStruct.EscapeJSON = EscapeJSON

return XMPStruct  --end
