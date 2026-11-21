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
