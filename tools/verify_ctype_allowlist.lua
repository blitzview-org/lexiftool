--------------------------------------------------------------------------------
-- File:         tools/verify_ctype_allowlist.lua
--
-- Description:  functions allowed to call string.lower/string.upper
--------------------------------------------------------------------------------

-- tools/verify_ctype.lua rejects string.lower/string.upper (and :lower()/
-- :upper()) outside the perl facade's own case helpers: they follow the
-- LC_CTYPE of the host's C locale, while Perl's lc/uc on a byte string touch
-- A-Z/a-z only. Keyed by 'file:enclosing function' (the function's name as
-- declared; '(main chunk)' for file scope); every entry needs a reason. Add
-- an entry only for a function that checks the locale's case mapping or
-- falls back to ASCII tables when it is not plain ASCII -- everything else
-- calls perl.lc/perl.uc.

return {
    ['src/lexiftool/perl.lua:caseIsAscii'] = 'compares string.lower/upper of all 256 bytes with the '
        .. 'ASCII mapping (sets CASE_ASCII)',
    ['src/lexiftool/perl.lua:asciiLower']  = 'string.lower only when CASE_ASCII, else the ASCII table',
    ['src/lexiftool/perl.lua:asciiUpper']  = 'string.upper only when CASE_ASCII, else the ASCII table',
}
