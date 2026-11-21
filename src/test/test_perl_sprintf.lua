--------------------------------------------------------------------------------
-- File:         test/test_perl_sprintf.lua
--
-- Description:  unit tests for perl.sprintf and perl.str (Perl sprintf and
--               stringification semantics)
--
-- Notes:        Every expectation below is the output of the real perl
--               (v5.42.2, x86_64-linux) for the same format and arguments,
--               captured with `sprintf(FMT, ARGS)` under `no warnings` --
--               none is hand-written. Inf/NaN arguments were 9**9**9,
--               -9**9**9 and -sin(9**9**9), undef is nil here; the integer
--               (IV) vs. float (NV) distinction of each argument is kept
--               (42 vs. 3.0).
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local is = TestLib.is

-- (the cases pass non-numeric strings on purpose; Perl warns "Argument ...
--  isn't numeric in sprintf" for them, which test_perl_facade.lua checks --
--  here the warnings are caught so they do not clutter the test output)
local oldWarn = perl.SIG.__WARN__
perl.SIG.__WARN__ = function() end

-- { format, arguments, argument count (the list may hold nils), perl output }
local CASES = {
    { '%d', { 42 }, 1, '42' },
    { '%5d|%-5d|%05d', { 42, 42, -42 }, 3, '   42|42   |-0042' },
    { '%x|%X|%#x|%.4x|%o', { 255, 255, 255, 10, 8 }, 5, 'ff|FF|0xff|000a|10' },
    { '%.2f|%g|%e|%.3g', { 3.14159, 0.0001, 12345, 1234567.0 }, 4, '3.14|0.0001|1.234500e+04|1.23e+06' },
    { '%s-%s', { 'abc', 7 }, 2, 'abc-7' },
    { '%c%c', { 65, 66 }, 2, 'AB' },
    { '100%%', {  }, 0, '100%' },
    { '%s', { 'a\0b' }, 1, 'a\000b' },
    { '%g|%f|%e|%d|%s', { 1/0, 1/0, -1/0, 1/0, 1/0 }, 5, 'Inf|Inf|-Inf|Inf|Inf' },
    { '%g|%f|%e|%d|%s|%x', { 0/0, 0/0, 0/0, 0/0, 0/0, 0/0 }, 6, 'NaN|NaN|NaN|NaN|NaN|NaN' },
    { '%.2f|%-6d|%+f|% f|%+d|% d', { 1/0, 1/0, 0/0, 1/0, 0/0, 1/0 }, 6, 'Inf|Inf   |NaN|+Inf|NaN|+Inf' },
    { '%06d|%-06d|%+06d|%5s|%-6s|%05g', { -1/0, -1/0, 1/0, 1/0, -1/0, 1/0 }, 6, '00-Inf|-Inf  |00+Inf|  Inf|-Inf  |00Inf' },
    { '%d|%x|%o|%u|%X|%b|%i', { 3.7, 3.7, 9.9, -3.7, 255.9, 5.5, -2.5 }, 7, '3|3|11|18446744073709551613|FF|101|-2' },
    { '%d|%d|%x|%x|%o|%u', { 1e19, 9.3e18, -1e20, -3.7, -2.5, -1e20 }, 6,
      '-8446744073709551616|-9146744073709551616|8000000000000000|fffffffffffffffd|1777777777777777777776|9223372036854775808' },
    { '%d|%d|%u|%x', { 1e20, -1e20, 1e20, 1e20 }, 4, '-1|-9223372036854775808|18446744073709551615|ffffffffffffffff' },
    { '%d', { 3.0 }, 1, '3' },
    { '%s|%s|%s|%s|%s|%s', { 1.0, 1e20, 0.3, 1e15, 123456789012345678, 1e100 }, 6, '1|1e+20|0.3|1e+15|123456789012345678|1e+100' },
    { '%s|%s|%s', { 0.3333333333333333, 1e-05, 123456789.123456789 }, 3, '0.333333333333333|1e-05|123456789.123457' },
    { '%s|%s', { 9007199254740992.0, 18446744073709551616.0 }, 2, '9.00719925474099e+15|1.84467440737096e+19' },
    { '%.3s|%s', { 3.14159, 1e-300 }, 2, '3.1|1e-300' },
    { '%d|%d|%d|%x|%d', { '12abc', ' 12', '0x1A', '1e3', '-12.9xyz' }, 5, '12|12|0|3e8|-12' },
    { '%e|%g|%d|%.1f', { 'abc', nil, '', '1.5e' }, 4, '0.000000e+00|0|0|1.5' },
    { '%s|%s|%d', { 'inf', 'NaN', 'Infinity' }, 3, 'inf|NaN|Inf' },
    { '%u|%x|%o|%b', { -1, -1, -1, -1 }, 4,
      '18446744073709551615|ffffffffffffffff|1777777777777777777777|1111111111111111111111111111111111111111111111111111111111111111' },
    { '%b|%B|%#b|%#B|%.8b|%#b', { 5, 5, 5, 5, 5, 0 }, 6, '101|101|0b101|0B101|00000101|0' },
    { '%+u|% u|%+x|%u', { 5, 5, 5, 9223372036854775807 }, 4, '5|5|5|9223372036854775807' },
    { '%+d|% d|%+x|%#x|%#o|%#X|%#x', { 5, 5, 255, 255, 8, 255, 0 }, 7, '+5| 5|ff|0xff|010|0XFF|0' },
    { '%-05d|%+ d|%#5x|%-#8o|', { 42, 42, 255, 8 }, 4, '42   |+42| 0xff|010     |' },
    { '%.3d|%5.3d|%-5.3x|%.0d|%.0x|%#.3o|%#5.0o', { 7, 7, 10, 0, 0, 8, 0 }, 7, '007|  007|00a  |||010|    0' },
    { '%010.3f|%-10.3e|%+010.2f|%.0g|%#g', { -3.14159, 31415.9, 2.5, 0.5, 1 }, 5, '-00003.142|3.142e+04 |+000002.50|0.5|1.00000' },
    { '%#.3g|%-08.3f|%+.2e|%08.3f', { 1, 3.14159, 12345, -3.14159 }, 4, '1.00|3.142   |+1.23e+04|-003.142' },
    { '%.0f|%.0f|%.0f|%.2f', { 0.5, 1.5, 2.5, 2.675 }, 4, '0|2|2|2.67' },
    { '%F|%a|%E|%G', { 1.5, 1, 12345.678, 0.00001234 }, 4, '1.500000|0x1p+0|1.234568E+04|1.234E-05' },
    { '%05s|%-5s|%.2s|%5.1s|%06.2s|%-06s|', { 'ab', 'ab', 'abcdef', 'xyz', 'abc', 'ab' }, 6, '000ab|ab   |ab|    x|0000ab|ab    |' },
    { '%3c|%-3c|%03c|', { 65, 66, 67 }, 3, '  A|B  |00C|' },
    { '%c|%c|%c', { 65.9, '66', 48 }, 3, 'A|B|0' },
    { '%5s|%-5s|', { 'a\0b', 'a\0b' }, 2, '  a\000b|a\000b  |' },
    { '%120d|', { 5 }, 1, '                                                                                                                       5|' },
    { '%*d|%-*d|%.*f|%*d', { 5, 42, 5, 42, 2, 3.14159, -5, 42 }, 8, '   42|42   |3.14|42   ' },
    { '%0*d|%-*s|%.*s|%.*d', { -5, 42, 3, 'ab', -1, 'abc', -1, 5 }, 8, '42   |ab |abc|5' },
    { '%2$s %1$s', { 'a', 'b' }, 2, 'b a' },
    { '%1$s%1$s|%1$s|%s', { 'x', 'y' }, 2, 'xx|x|x' },
    { '%2$*1$d|', { 5, 42 }, 2, '   42|' },
    { '%hd|%ld|%lld|%qd|%lu|%hhd|%Lf|%hx', { 70000, 5, 6, 7, 8, 300, 1.5, -1 }, 8, '4464|5|6|7|8|44|1.500000|ffff' },
    { '%D|%U|%O', { -5, 5, 8 }, 3, '-5|5|10' },
    { '%vd|%*vX|%vd', { '1.22.333', ':', 'abc', '' }, 4, '49.46.50.50.46.51.51.51|61:62:63|' },
    { '%v02x|%v3d|%-v3d|%v.3d|%0*v2x|%#vx|%+vd', { '1.2.3', '1.2', '1.2', '1.2', ':', 'ab', '1.2', '1.2' }, 8,
      '31.2e.32.2e.33| 49. 46. 50|49 .46 .50 |049.046.050|61:62|0x31.0x2e.0x32|+49.46.50' },
    { '[%s][%d][%f][%x]', {  }, 0, '[][0][0.000000][0]' },
    { '%s %s %s', { 1, 2 }, 2, '1 2 ' },
    { '[%5s][%-5d][%.2d]', { nil, nil, nil }, 3, '[     ][0    ][00]' },
    { '%y|%|%5%|%-5%|%05%|%%|%3vd|%vs', {  }, 0, '%y|%|    %|%    |0000%|%|%3vd|%vs' },
    { 'abc%', {  }, 0, 'abc%' },
    { '%5', {  }, 0, '%5' },
}

for _, c in ipairs(CASES) do
    local fmt, args, n, want = c[1], c[2], c[3], c[4]
    is(want, perl.sprintf(fmt, table.unpack(args, 1, n)), 'sprintf ' .. fmt)
    -- the parsed plan is cached per format; a second call must agree
    is(want, perl.sprintf(fmt, table.unpack(args, 1, n)), 'sprintf (cached) ' .. fmt)
end

-- perl.str: Perl's stringification (perl: print 1.0, 1e20, 0.1+0.2, 2**53
-- gives 1, 1e+20, 0.3, 9.00719925474099e+15; -0.0 prints as 0)
is('1', perl.str(1.0), 'str integral float')
is('1e+20', perl.str(1e20), 'str 1e20')
is('0.3', perl.str(0.1 + 0.2), 'str 15 significant digits')
is('9.00719925474099e+15', perl.str(2.0 ^ 53), 'str 2**53')
is('0', perl.str(-1e-300 * 1e-300), 'str negative zero')
is('Inf', perl.str(1 / 0), 'str Inf')
is('-Inf', perl.str(-1 / 0), 'str -Inf')
is('NaN', perl.str(0 / 0), 'str NaN')
is('', perl.str(nil), 'str undef')
is('abc', perl.str('abc'), 'str string')

perl.SIG.__WARN__ = oldWarn
