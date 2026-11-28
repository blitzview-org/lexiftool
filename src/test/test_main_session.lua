--------------------------------------------------------------------------------
-- File:         test/test_main_session.lua
--
-- Description:  lexiftool.main's session/execute/executeText entry points
--               (doc/capi.md; the mapping in capi/session.lua): the C API's own
--               Lua side opens exactly this. Everything a command prints
--               -- its ordinary output, -v3/-htmlDump verbose output,
--               warnings, and -b binary data -- must come back in
--               execute()'s own result strings, never on the process's
--               real stdout/stderr (the redirection perl.redirect sets up
--               around the session's coroutine, doc/conventions.md §3a).
--               At the end: EscapeJSON's ASCII shortcut against the former
--               function, through the script's file scope.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok
local T_DIR = TestLib.T_DIR

local main = require('lexiftool.main')
local jpg = T_DIR .. '/images/ExifTool.jpg'

local s = main.session({})
is('ok', s.state, 'session starts ok')

do
    local out, err, status, state = main.execute(s, { '-j', jpg })
    is('ok', state, 'execute -j: session stays ok')
    is(0, status, 'execute -j: status 0')
    ok(out:find('"Make"', 1, true) ~= nil, 'execute -j: tag value in the returned stdout')
    is('', err, 'execute -j: nothing on the returned stderr')
end

do
    -- -v3: the library's own verbose output (TextOut, print(out, ...) call
    -- sites the port converted to the facade) must land in the result too,
    -- not just ordinary tag output.
    local out, err, status, state = main.execute(s, { '-v3', jpg })
    is('ok', state, 'execute -v3: session stays ok')
    is(0, status, 'execute -v3: status 0')
    ok(out:find('JPEG APP1', 1, true) ~= nil or out:find('JFIF', 1, true) ~= nil,
        'execute -v3: verbose segment trace in the returned stdout')
    is('', err, 'execute -v3: nothing on the returned stderr')
end

do
    -- -htmlDump: HtmlDump.lua's own output function (dumpText -> print)
    local out, err, status, state = main.execute(s, { '-htmlDump', jpg })
    is('ok', state, 'execute -htmlDump: session stays ok')
    is(0, status, 'execute -htmlDump: status 0')
    ok(out:find('<html', 1, true) ~= nil, 'execute -htmlDump: HTML dump in the returned stdout')
    is('', err, 'execute -htmlDump: nothing on the returned stderr')
end

do
    -- -b: binary tag value, byte for byte (perl.redirect keeps the bytes
    -- as they are)
    local out, err, status, state = main.execute(s, { '-b', '-ThumbnailImage', jpg })
    is('ok', state, 'execute -b: session stays ok')
    is(0, status, 'execute -b: status 0')
    ok(#out > 100 and out:sub(1, 2) == '\xff\xd8', 'execute -b: JPEG thumbnail bytes in the returned stdout')
    ok(err == '' or err:find('Warning', 1, true) ~= nil,
        'execute -b: nothing on the returned stderr but a well-formed warning (never process stderr)')
end

do
    -- a warning (an invalid tag name on the command line) must come back on
    -- the returned stderr, not the process's real one
    local _, err, _, state = main.execute(s, { '-NoSuchTagAtAll', jpg })
    is('ok', state, 'execute with a bad tag: session stays ok')
    ok(err:find('Warning', 1, true) ~= nil, 'execute with a bad tag: warning in the returned stderr')
end

do
    -- executeText: argfile text, filtered line by line as ReadStayOpen
    -- filters a -stay_open ARGFILE (comments, #[CSTR], white space); a
    -- -execute separates commands, one on the last line ends the command
    local text = '# comment\n  -echo\n  one\n\n#[CSTR]-echo\n#[CSTR]a\\tb\n-execute\n-echo\nlast\n-execute\n'
    local out, err, status, state = main.executeText(s, text)
    is('ok', state, 'executeText: session stays ok')
    is(0, status, 'executeText: status 0')
    is('one\na\tb\nlast\n', out, 'executeText: argfile rules, two commands')
    is('', err, 'executeText: nothing on the returned stderr')
    out = main.executeText(s, '-echo\nno newline at the end')
    is('no newline at the end\n', out, 'executeText: last line without a newline')
end

do
    -- ending the session: "-stay_open False", as a client sends it
    local _, _, _, state = main.execute(s, nil)
    is('ended', state, 'execute(s, nil): session ends like -stay_open False')
end

do
    -- (not upstream: EscapeJSON's shortcut for printable ASCII without '"'
    --  and '\', main.lua -- against the former function, copied here as it
    --  was, under every JSON/PHP, -b, alternate encoding and quote setting:
    --  all 256 single bytes, alone and inside text, UTF-8 and broken UTF-8,
    --  numbers and booleans, long strings, seeded random bytes.  The script's
    --  file scope is the _ENV upvalue of the module's functions)
    local perl = require('lexiftool.perl')
    local lexiftool = require('lexiftool')
    local env
    for i = 1, math.huge do
        local name, v = debug.getupvalue(main.session, i)
        if name == nil then break end
        if name == '_ENV' then env = v break end
    end
    ok(type(env) == 'table' and type(rawget(env, 'EscapeJSON')) == 'function', 'EscapeJSON: main.lua file scope found')
    local isMatch, subst, sprintf, lc = perl.isMatch, perl.subst, perl.sprintf, perl.lc
    local function oldEscapeJSON(str, quote)
        local json, binaryOutput, altEnc, isBinary = env.json, env.binaryOutput, env.altEnc, env.isBinary
        local jsonChar = env.jsonChar
        str = perl.str(str)
        if not perl.truthy(quote) then
            if isMatch(str, [[(?i)^(true|false)$]]) and json < 2 then return lc(str) end
            if isMatch(str, [[(?i)^-?(\d|[1-9]\d{1,14})(\.\d{1,16})?(e[-+]?\d{1,3})?$]]) then return str end
        end
        if json < 2 and binaryOutput ~= nil and lexiftool.IsUTF8(str) < 0 then
            return '"base64:' .. require('lexiftool.XMP').EncodeBase64(str, 1) .. '"'
        end
        str = subst(str, [[(?s)(["\t\n\r\\])]], function(c) return "\\" .. jsonChar[c] end, 'g')
        if json < 2 then
            str = perl.tr(str, "\0", '', 'd')
            str = subst(str, [[(?s)([\0-\x1f\x7f])]], function(c) return sprintf("\\u%.4X", perl.ord(c)) end, 'g')
            if not altEnc then str = select(2, require('lexiftool.XMP').FixUTF8(str)) end
        else
            if not isBinary then str = subst(str, [[\0+$]], '') end
            str = subst(str, [[(?s)\$]], [[\\\$]], 'g')
            str = subst(str, [[(?s)([\0-\x1f\x7f])]], function(c) return sprintf("\\x%.2X", perl.ord(c)) end, 'g')
        end
        return '"' .. str .. '"'
    end
    local inputs = { '', 'a', 'Hello, World!', ' leading and trailing ', '~!@#$%^&*()_+{}|:<>?`-=[];,./',
        'true', 'FALSE', 'True ', '0', '-1', '12', '012', '1.5', '1e5', '-0.25E-3', '1234567890123456',
        '1.12345678901234567', '0x1F', '+1', 'caf\195\169', '\226\130\172 99', '\240\159\152\128',
        '\195', '\195\40', '\237\160\128', '\239\191\190', '\244\144\128\128', '\192\175', '\255\254',
        'a"b', 'a\\b', 'tab\there', 'line\nnext', 'cr\r', 'nul\0in\0side', 'trailing nul\0\0', 'del\127',
        'esc\27[0m', 'dollar $x', 'slash / and \\/', string.rep('x', 100000), string.rep('x', 99999) .. '"',
        string.rep('\195\169', 30000), 42, 1.5, -7 }
    for c = 0, 255 do
        local ch = string.char(c)
        inputs[#inputs + 1] = ch
        inputs[#inputs + 1] = 'ab' .. ch .. 'cd'
    end
    local seed = 20261121
    local function rnd(n)   -- a small LCG, independent of math.random's version
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end
    for _ = 1, 2000 do
        local t = {}
        for i = 1, rnd(48) do
            t[i] = rnd(2) == 0 and string.char(rnd(256)) or string.char(32 + rnd(95))
        end
        inputs[#inputs + 1] = table.concat(t)
    end
    local saved = { env.json, env.binaryOutput, env.altEnc, env.isBinary }
    local cases, diffs, first = 0, 0, nil
    for _, json in ipairs({ 1, 2 }) do
        for _, binaryOutput in ipairs({ false, 1 }) do
            for _, altEnc in ipairs({ false, 'Latin' }) do
                for _, isBinary in ipairs({ false, 1 }) do
                    env.json = json
                    env.binaryOutput = binaryOutput or nil
                    env.altEnc = altEnc or nil
                    env.isBinary = isBinary or nil
                    for _, quote in ipairs({ false, 1 }) do
                        for _, str in ipairs(inputs) do
                            local q = quote or nil
                            cases = cases + 1
                            if env.EscapeJSON(str, q) ~= oldEscapeJSON(str, q) then
                                diffs = diffs + 1
                                first = first or string.format('json=%s -b=%s altEnc=%s isBinary=%s quote=%s %q',
                                    json, binaryOutput, altEnc, isBinary, quote, tostring(str):sub(1, 40))
                            end
                        end
                    end
                end
            end
        end
    end
    env.json, env.binaryOutput, env.altEnc, env.isBinary = saved[1], saved[2], saved[3], saved[4]
    is(0, diffs, 'EscapeJSON = former function (' .. cases .. ' cases)' .. (first and ', first: ' .. first or ''))
end
