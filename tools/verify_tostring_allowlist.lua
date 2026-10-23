--------------------------------------------------------------------------------
-- File:         tools/verify_tostring_allowlist.lua
--
-- Description:  tostring() arguments known to be error objects (or strings)
--------------------------------------------------------------------------------

-- tools/verify_tostring.lua rejects the tostring() calls outside the perl
-- facade whose argument may be a number: ported code stringifies with
-- perl.str. tostring() stays for error objects -- the message (a string or a
-- die object) a failed pcall returns, printed or passed on as Lua has it.
-- Arguments listed here are counted, not rejected. Keyed by the argument
-- expression exactly as written (whitespace collapsed); every entry needs a
-- reason. Add an entry only when the value is an error object (or cannot be
-- a number) -- otherwise the call belongs on perl.str.

return {
    ['e']      = 'error object of a failed pcall (main.lua, Writer.lua, lexiftool.lua traceback handlers)',
    ['err']    = 'error object of a failed pcall (Validate, Writer utime, config file loading)',
    ['err2']   = 'error object of a failed pcall (Writer DelCheck)',
    ['res']    = 'error object of a failed pcall (Format size eval)',
    ['what']   = 'error object of a failed coroutine.resume (main.lua -stay_open session)',
    ['module'] = 'error object of a failed pcall(require) (lexiftool.lua AUTOLOAD)',
}
