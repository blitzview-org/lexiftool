--------------------------------------------------------------------------------
-- File:         capi/session.lua
--
-- Description:  Lua side of a C API session (capi/lexiftool.c). Opens the
--               session of lexiftool.main (the script as a library, see
--               the end of src/lexiftool/main.lua) and offers the C host
--               three calls on it:
--                 execute(argv)     one command, as a -stay_open client
--                                   writes it before "-execute" (argv: a
--                                   list, verbatim) -> stdout, stderr,
--                                   status, state, message
--                                   (main.execute; argv nil ends the
--                                   session)
--                 imageInfo(path, argv)  the tags of one file as values,
--                                   straight from the library (ImageInfo/
--                                   GetGroup/GetTagName, the values as -j
--                                   gets them), no text formatting
--                 setTags(path, names, values)  SetNewValue + WriteInfo
--
--               Called by the host with:
--                 launcher  embedded variant: the standalone launcher chunk
--                           (standalone/launcher.lua: wraps io.open for the
--                           embedded data files; with its third argument
--                           true it returns lexiftool.main instead of
--                           running it); nil for the rock variant (modules
--                           on package.path/cpath)
--                 vroot, getFile   the launcher's two arguments
--                 config    -config FILE, or nil
--                 commonArgs  list of arguments for -common_args
--               Returns the table of the three calls, or raises an error.
--------------------------------------------------------------------------------

local launcher, vroot, getFile, config, commonArgs = ...

-- a library must not take over the process's signals: main.lua sets
-- $SIG{INT}/$SIG{CONT} when it is loaded (lexiftool.sys.nosignals)
require('lexiftool.sys').nosignals(true)

-- `arg` as lua.c sets it up for a script (-ver -v, the config file lookup)
local prog = 'lexiftool'
arg = { [-1] = prog, [0] = prog } -- luacheck: ignore 121

local main, launch
if launcher then
    main, launch = launcher(vroot, getFile, true)
else
    main, launch = require('lexiftool.main'), { bytecode = false }
end

local session = main.session({
    config = config and { config } or nil,
    commonArgs = commonArgs,
    launch = launch,
})
if session.state ~= 'ok' then
    error(session.message or 'lexiftool ended at its start', 0)
end

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local ref = perl.ref

-- Options of imageInfo: the subset of the command-line options that
-- selects and converts values. Each entry: number of arguments, handler.
local function apiOption(o, arg_)
    local opt, val = arg_:match('^([^=]*)=(.*)$')
    if opt == nil then opt, val = arg_, 1 end
    o.options[#o.options + 1] = { opt, val }
end
local infoOptions = {
    ['-a']      = { 0, function(o) o.dups = true end },
    ['-b']      = { 0, function(o) o.binary = true end },
    ['-e']      = { 0, function(o) o.options[#o.options + 1] = { 'Composite', 0 } end },
    ['-ee']     = { 0, function(o) o.options[#o.options + 1] = { 'ExtractEmbedded', 1 } end },
    ['-n']      = { 0, function(o) o.options[#o.options + 1] = { 'PrintConv', 0 } end },
    ['-u']      = { 0, function(o) o.options[#o.options + 1] = { 'Unknown', 1 } end },
    ['-U']      = { 0, function(o) o.options[#o.options + 1] = { 'Unknown', 2 } end },
    ['-fast']   = { 0, function(o) o.options[#o.options + 1] = { 'FastScan', 1 } end },
    ['-fast2']  = { 0, function(o) o.options[#o.options + 1] = { 'FastScan', 2 } end },
    ['-api']    = { 1, apiOption },
    ['-c']      = { 1, function(o, a) o.options[#o.options + 1] = { 'CoordFormat', a } end },
    ['-d']      = { 1, function(o, a) o.options[#o.options + 1] = { 'DateFormat', a } end },
    ['-lang']   = { 1, function(o, a) o.options[#o.options + 1] = { 'Lang', a } end },
    ['-sep']    = { 1, function(o, a) o.sep = a end },
    ['-x']      = { 1, function(o, a) o.exclude[#o.exclude + 1] = a end },
}

local function parseInfoArgs(argv)
    local o = { options = { }, tags = { }, exclude = { }, sep = ', ' }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        i = i + 1
        local entry = infoOptions[a]
        local g = a:match('^%-G([%d:]*)$')
        if entry then
            if entry[1] > 0 then
                if argv[i] == nil then return nil, 'Expecting argument for ' .. a .. ' option' end
                entry[2](o, argv[i])
                i = i + 1
            else
                entry[2](o)
            end
        elseif g then
            o.showGroup = g ~= '' and g or 0    -- (as -G: its number, 0 by default)
        elseif a:match('^%-%-.') then
            o.exclude[#o.exclude + 1] = a:sub(3)
        elseif a:match('^%-.') then
            o.tags[#o.tags + 1] = a:sub(2)
        else
            return nil, 'Unexpected argument ' .. a .. ' (options and -TAG only)'
        end
    end
    return o
end

-- a value as text: SCALAR (binary) and ARRAY (list) values the way -j
-- turns them into one value, structures serialized as for -s output
local function valueOf(et, val, o)
    if ref(val) == 'SCALAR' then
        local data = perl.str(val.value)
        if o.binary then return data, true end
        if data:match('^Binary data %d+ bytes$') then
            return '(' .. data .. ', use -b option to extract)'
        end
        return '(Binary data ' .. #data .. ' bytes, use -b option to extract)'
    elseif ref(val) == 'ARRAY' then
        local items, binary = { }, false
        for i = 1, #val do
            local v, b = valueOf(et, val[i], o)
            items[i] = v
            binary = binary or b
        end
        return table.concat(items, o.sep), binary
    elseif ref(val) == 'HASH' then
        return perl.str(require('lexiftool.XMP').SerializeStruct(et, val)), false
    end
    return perl.str(val), false
end

-- the Warning/Error tags of the last call as messages (as PrintErrors)
local function messagesOf(et, list)
    local errs = et:GetInfo('Warning', 'Error')
    local status = 0
    for _, tag in ipairs({ 'Warning', 'Error' }) do
        if errs[tag] ~= nil then
            local keys = { tag }
            if perl.truthy(et:Options('Duplicates')) then
                local more = { }
                for k in pairs(errs) do
                    if k:sub(1, #tag + 1) == tag .. ' ' then more[#more + 1] = k end
                end
                perl.tsort(more)
                for _, k in ipairs(more) do keys[#keys + 1] = k end
            end
            for _, key in ipairs(keys) do
                list[#list + 1] = { tag, perl.str(errs[key]) }
            end
            if tag == 'Error' then status = 1 end
        end
    end
    return status
end

-- imageInfo(path, argv) -> tags, messages, status
--   tags: list of { name, group or nil, value, binary }; messages: list of
--   { 'Warning'|'Error', text }; status: 0, or 1 when there was an Error
--   (file not found, unknown format, ...). For a bad argument: nil and
--   the message.
local function imageInfo(path, argv)
    local o, err = parseInfoArgs(argv)
    if not o then return nil, err end
    local et = ExifTool.new()
    -- (as -j: all duplicates from the library, suppressed below unless -a)
    et:Options('Duplicates', 1)
    if o.binary then et:Options('Binary', 1, 'NoPDFList', 1) end
    -- (as the script: sorted by group with -G, unless tags were requested)
    if o.showGroup ~= nil and #o.tags == 0 then et:Options('Sort', 'Group' .. o.showGroup) end
    for _, opt in ipairs(o.options) do et:Options(opt[1], opt[2]) end
    if #o.exclude > 0 then et:Options('Exclude', o.exclude) end
    local messages = { }
    if not et:Exists(path) then
        messages[1] = { 'Error', 'File not found' }
        return { }, messages, 1
    end
    local found = { }
    for i, t in ipairs(o.tags) do found[i] = t end
    local info = et:ImageInfo(path, found)
    local tags, seen = { }, { }
    for _, key in ipairs(found) do
        local val = info[key]
        if val == nil then goto nextTag end
        do
            local group = o.showGroup ~= nil and et:GetGroup(key, o.showGroup) or nil
            if not o.dups then
                -- as -j: a duplicate the library kept ("TAG (1)") is dropped
                -- when its priority tag is there (in the same group)
                local base = key:match('^(.-) ?%(')
                if base and info[base] ~= nil and
                   (group == nil or group == et:GetGroup(base, o.showGroup)) then
                    goto nextTag
                end
            end
            local name = ExifTool.GetTagName(key)
            if not o.dups then
                -- (and the first of two tags of the same group and name)
                local tok = (group or '') .. ':' .. name
                if seen[tok] then goto nextTag end
                seen[tok] = true
            end
            local value, binary = valueOf(et, val, o)
            tags[#tags + 1] = { name, group, value, binary }
        end
        ::nextTag::
    end
    local status = messagesOf(et, messages)
    return tags, messages, status
end

-- setTags(path, names, values, n) -> messages, status
--   values[i] nil deletes the tag (-TAG=); the file is rewritten in place
--   (WriteInfo without a destination). status: 0 written or nothing to
--   change, 1 error.
local function setTags(path, names, values, n)
    local et = ExifTool.new()
    local messages = { }
    local status = 0
    for i = 1, n do
        local _, err = et:SetNewValue(names[i], values[i])
        if err then
            messages[#messages + 1] = { 'Warning', perl.str(err) }
        end
    end
    if not et:Exists(path) then
        messages[#messages + 1] = { 'Error', 'File not found' }
        return messages, 1
    end
    local result = et:WriteInfo(path)
    if messagesOf(et, messages) ~= 0 or not perl.truthy(result) then status = 1 end
    return messages, status
end

return {
    -- (the session's ExifTool object lives across commands, so the decimal
    --  point and the collation of the host's current locale are re-read
    --  here; imageInfo and setTags do it through ExifTool.new)
    execute = function(argv)
        perl.localeRefresh()
        return main.execute(session, argv)
    end,
    imageInfo = imageInfo,
    setTags = setTags,
}
