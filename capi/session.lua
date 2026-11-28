--------------------------------------------------------------------------------
-- File:         capi/session.lua
--
-- Description:  Lua side of a C API session (capi/lexiftool.c). Opens the
--               session of lexiftool.main (the script as a library, see
--               the end of src/lexiftool/main.lua) plus one ExifTool object
--               of the session, and offers the C host these calls:
--                 execute(argv)      one command, as a -stay_open client
--                                    writes it before "-execute" (argv: a
--                                    list, verbatim) -> stdout, stderr,
--                                    status, state, message (main.execute;
--                                    argv nil ends the session)
--                 executeText(text)  the same with argfile text
--                                    (main.executeText)
--                 setOption(name, value)  Options of the session's object
--                 imageInfo(file, tags, binary)  ImageInfo of the session's
--                                    object -> list of tag entries
--                 setNewValue(tag, value)  SetNewValue (tag nil: clear all)
--                 writeInfo(file, outfile)  WriteInfo -> result, error,
--                                    warning
--
--               Called by the host with:
--                 launcher  embedded variant: the standalone launcher chunk
--                           (standalone/launcher.lua; called with true it
--                           returns lexiftool.main instead of running it);
--                           nil for the rock variant (modules on
--                           package.path/cpath)
--                 config    -config FILE, or nil
--                 commonArgs  list of arguments for -common_args
--               Returns the table of the calls, or raises an error.
--
--               How the C functions map onto the inside:
--                 lexiftool_open     a Lua state (luaL_openlibs; embedded:
--                                    lx_setup of standalone/main.c), then
--                                    this chunk: main.session starts the
--                                    script in a coroutine as
--                                    main({-config F, -stay_open, True, -@,
--                                    -, -common_args, ...}, {readArgs =
--                                    coroutine.yield}); its command loop
--                                    runs up to ReadStayOpen, which yields
--                                 -> et = ExifTool:new()
--                 lexiftool_execute  main.execute(session, argv): stdout and
--                                    stderr switched into the session's
--                                    buffers (perl.redirect), resume with
--                                    argv + "-execute" until the loop
--                                    yields the command's status again
--                 lexiftool_execute_text  main.executeText: the lines
--                                    filtered by the script's own
--                                    FilterArgfileLine, then main.execute
--                 lexiftool_set_option / image_info / set_new_value /
--                 write_info         Options / ImageInfo (+ GetTagName,
--                                    GetGroup, GetDescription, GetTagID,
--                                    GetValue ValueConv per key) /
--                                    SetNewValue / WriteInfo of `et`, with
--                                    the library's own output dropped
--                                    (quiet below)
--                 lexiftool_close    main.execute(session, nil): a
--                                    "-stay_open False" ends the loop,
--                                    Exit() returns; then lua_close
--               The commands run in main.lua's own, structurally unchanged
--               -stay_open loop, so everything that outlives a command
--               (config, loaded modules, the Composite order) behaves as for
--               a -stay_open client. `et` is apart from the objects of that
--               loop: its options and new values are only those set through
--               the C API, as for an Image::ExifTool object in a Perl program.
--------------------------------------------------------------------------------

local launcher, config, commonArgs = ...

-- a library must not take over the process's signals: main.lua sets
-- $SIG{INT}/$SIG{CONT} when it is loaded (lexiftool.sys.nosignals), which
-- is already this Lua state's default (true, set by luaopen_lexiftool_sys)
-- -- kept explicit here so a session stays correct even if that default
-- ever changed.
require('lexiftool.sys').nosignals(true)

-- `arg` as lua.c sets it up for a script (-ver -v, the config file lookup)
local prog = 'lexiftool'
arg = { [-1] = prog, [0] = prog } -- luacheck: ignore 121

local main, launch
if launcher then
    main, launch = launcher(true)
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

-- the session's ExifTool object (the script's command loop has its own)
local et = ExifTool:new()

-- Runs f(...) with everything the library prints (Verbose output to
-- TextOut, a warn) collected and dropped instead of reaching the process's
-- streams; a Lua error is raised again with its traceback.
local function quiet(f, ...)
    local sink = { }
    perl.localeRefresh()
    perl.redirect(io.stdout, sink)
    perl.redirect(io.stderr, sink)
    local res = table.pack(xpcall(f, debug.traceback, ...))
    perl.redirect(io.stdout, nil)
    perl.redirect(io.stderr, nil)
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

-- an option value from C: a decimal integer as a number (Perl's "0" is
-- false, a Lua string never is), anything else as the string
local function optionValue(value)
    if value ~= nil and (value == '0' or value:find('^%-?[1-9][0-9]*$')) then
        return math.tointeger(tonumber(value)) or value
    end
    return value
end

-- A value of the info hash or of GetValue as bytes, as exiftool's text
-- output shows it (the script's ConvertBinary, lists joined with ListSep,
-- structures serialized). Returns: text, binary kind (0 no binary value,
-- 1 placeholder, 2 the data), length of the binary data
local function valueOf(val, wantBin)
    local r = ref(val)
    if r == 'SCALAR' then
        local data = perl.str(val.value)
        local n = data:match('^Binary data ([0-9]+) bytes$')
        if n then
            return '(' .. data .. ', use -b option to extract)', 1, math.tointeger(tonumber(n))
        elseif wantBin then
            return data, 2, #data
        end
        return '(Binary data ' .. #data .. ' bytes, use -b option to extract)', 1, #data
    elseif r == 'ARRAY' then
        local items = { }
        for i = 1, #val do items[i] = (valueOf(val[i], wantBin)) end
        return table.concat(items, perl.str(et:Options('ListSep'))), 0, 0
    elseif r == 'HASH' then
        return perl.str(require('lexiftool.XMP').SerializeStruct(et, val)), 0, 0
    end
    return perl.str(val), 0, 0
end

-- imageInfo(file, tags, binary) -> list of entries
--   { name, group0, group1, group2, desc, id, value, num, copyNum,
--     binaryKind, binaryLen }
-- in the order of ImageInfo's tag list (file order, or the requested
-- order; the Sort option changes it). tags: list of requested tags
-- (empty: all); binary: deliver every binary value (Binary option for
-- this call), otherwise only those of tags requested by name.
local function imageInfo(file, tags, binary)
    local found = { }
    for i, t in ipairs(tags) do found[i] = t end
    local info
    if binary then
        info = et:ImageInfo(file, found, { Binary = 1 })
    else
        info = et:ImageInfo(file, found)
    end
    local req = et.REQ_TAG_LOOKUP or { }
    local list = { }
    for _, key in ipairs(found) do
        local val = info[key]
        if val ~= nil then
            local name = ExifTool.GetTagName(key)
            local wantBin = binary or req[perl.lc(name)] ~= nil
            local value, kind, len = valueOf(val, wantBin)
            local num = et:GetValue(key, 'ValueConv')
            num = num ~= nil and (valueOf(num, wantBin)) or value
            local copy = perl.str(et:GetGroup(key, 4)):match('^Copy([0-9]+)$')
            list[#list + 1] = {
                name,
                perl.str(et:GetGroup(key, 0)),
                perl.str(et:GetGroup(key, 1)),
                perl.str(et:GetGroup(key, 2)),
                perl.str(et:GetDescription(key)),
                perl.str((et:GetTagID(key))),
                value, num,
                copy and math.tointeger(tonumber(copy)) or 0,
                kind, len,
            }
        end
    end
    return list
end

-- writeInfo(file, outfile) -> WriteInfo's result (1 written, 2 unchanged,
-- 0 error), the Error and the Warning of the write (or nil)
local function writeInfo(file, outfile)
    local result = et:WriteInfo(file, outfile)
    local err, warn = et:GetValue('Error'), et:GetValue('Warning')
    return math.tointeger(tonumber(result)) or 0,
           err ~= nil and perl.str(err) or nil, warn ~= nil and perl.str(warn) or nil
end

return {
    -- (the script's ExifTool object lives across commands, so the decimal
    --  point and the collation of the host's current locale are re-read
    --  before each command, and before each call on the session's object)
    execute = function(argv)
        perl.localeRefresh()
        return main.execute(session, argv)
    end,
    executeText = function(text)
        perl.localeRefresh()
        return main.executeText(session, text)
    end,
    setOption = function(name, value)
        return quiet(function() et:Options(name, optionValue(value)) end)
    end,
    imageInfo = function(file, tags, binary)
        return quiet(imageInfo, file, tags, binary)
    end,
    setNewValue = function(tag, value)
        return quiet(function()
            if tag == nil then
                et:SetNewValue()
                return 0
            end
            local n, err = et:SetNewValue(tag, value)
            return math.tointeger(tonumber(n)) or 0, err ~= nil and perl.str(err) or nil
        end)
    end,
    writeInfo = function(file, outfile)
        return quiet(writeInfo, file, outfile)
    end,
}
