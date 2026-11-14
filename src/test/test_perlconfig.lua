--------------------------------------------------------------------------------
-- File:         test/test_perlconfig.lua
--
-- Description:  exiftool config files written in Perl (lexiftool.PerlConfig,
--               doc/configuration.md "Perl config files"): ./lexiftool and
--               the Perl original (vendor/exiftool/exiftool) run with the
--               same Perl config file on the same command line, and their
--               stdout, stderr and exit status -- and the files they write --
--               must be equal.
--               1. the test config files in src/test/config/perl/: each has
--                  its command lines in "# test: ARGS" comment lines (OUT.ext
--                  is the file the command writes, one per program, LAST.ext
--                  the file Perl wrote in the command before);
--               2. the reject_*.config files there: constructs lexiftool does
--                  not run -- it warns the line and the construct, uses
--                  nothing of the file and runs on, where Perl loads the file
--                  (or fails to compile it, for the invalid ones);
--               3. upstream's config_files/: the files lexiftool reads give
--                  the same tag lists, written files and values -- of the
--                  conversions in Perl code too (age, frameCount, time_zone,
--                  and the region conversions on
--                  src/test/images/lex_MWG_Regions.xmp) -- as with Perl, the
--                  others are rejected at the line of their first construct
--                  outside the subset;
--               4. the values of the parser itself (PerlConfig.Load with a
--                  capturing apply function), without Perl.
--               The Perl comparisons are skipped where perl is not installed.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok
local PerlConfig = require('lexiftool.PerlConfig')

local REPO_DIR = TestLib.REPO_DIR
local T = 'vendor/exiftool/t/images/'
local FIXTURES = 'src/test/config/perl/'
local IMAGES = 'src/test/images/'
local BUNDLED = 'vendor/exiftool/config_files/'

local function shquote(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local data = fh:read('a')
    fh:close()
    return data
end

--------------------------------------------------------------------------------
-- 4. the parser's values (first: these need no Perl and no child process)
--------------------------------------------------------------------------------
do
    local function load(text)
        PerlConfig.symbols = { }
        local got
        local warned = { }
        local perl = require('lexiftool.perl')
        local saveWarn = perl.warn
        perl.warn = function(msg) warned[#warned + 1] = msg end
        local okLoad, err = pcall(PerlConfig.Load, text, 'unit.config', function(config) got = config end)
        perl.warn = saveWarn
        if not okLoad then error(err, 0) end
        return got, table.concat(warned)
    end
    local cfg, warn = load([[
%Image::ExifTool::UserDefined = (
    'Image::ExifTool::Exif::Main' => {
        0xd000 => { Name => 'A', Groups => { 2 => 'Camera' }, List => [ 'x', "y\t", q{z} ] },
        '0x10' => { Name => 'B', Values => [ qw(a b c) ], Num => 1.5, Neg => -2, Int => 2.0 },
        010 => { Name => Bare, Expr => 1 << 4 | 1, Cat => 'a' . 'b' },
    },
);
@Image::ExifTool::UserDefined::Lenses = ( 'L1', 'L2' );
$Image::ExifTool::UserDefined{'Image::ExifTool::Exif::Main'}{0xd000}{Extra} = 'e';
1;
]])
    is('', warn, 'unit: no warning')
    local main = cfg and cfg['Image::ExifTool::UserDefined'] and cfg['Image::ExifTool::UserDefined']['Image::ExifTool::Exif::Main']
    ok(main ~= nil, 'unit: UserDefined table handed over')
    if main then
        is('A', main[0xd000] and main[0xd000].Name, 'unit: hex key is the integer key')
        is('Camera', main[0xd000].Groups[2], 'unit: integer key in a nested hash')
        is('x|y\t|z', table.concat(main[0xd000].List, '|'), 'unit: array of strings')
        is('e', main[0xd000].Extra, 'unit: element assignment into the hash')
        is('B', main['0x10'] and main['0x10'].Name, 'unit: a quoted key stays a string')
        is('a b c', table.concat(main['0x10'].Values, ' '), 'unit: qw()')
        is(1.5, main['0x10'].Num, 'unit: float value')
        is(-2, main['0x10'].Neg, 'unit: negative value')
        is('Bare', main[8] and main[8].Name, 'unit: octal key, bareword value')
        is(17, main[8].Expr, 'unit: constant expression')
        is('ab', main[8].Cat, 'unit: concatenation')
    end
    is('L1 L2', table.concat(cfg and cfg['Image::ExifTool::UserDefined::Lenses'] or { }, ' '), 'unit: @Lenses')
    -- (a reference to a hash assigned later: the same table)
    cfg = load([[
%Image::ExifTool::UserDefined::t1 = ( Ref => \%Image::ExifTool::UserDefined::t2 );
%Image::ExifTool::UserDefined::t2 = ( X => 1 );
1;
]])
    local t1, t2 = cfg and cfg['Image::ExifTool::UserDefined::t1'], cfg and cfg['Image::ExifTool::UserDefined::t2']
    ok(t1 and t2 and t1.Ref == t2 and t2.X == 1, 'unit: reference to a hash defined later')
    -- (a rejection: nothing handed over)
    local captured
    PerlConfig.symbols = { }
    local perl = require('lexiftool.perl')
    local saveWarn, msg = perl.warn, nil
    perl.warn = function(m) msg = m end
    PerlConfig.Load("%Image::ExifTool::UserDefined::Shortcuts = ( A => 'B' );\nmy $x = 1;\n", 'r.config',
                    function(c) captured = c end)
    perl.warn = saveWarn
    is(nil, captured, 'unit: a rejected file hands nothing over')
    is('Config file not supported by lexiftool (Perl code at line 2: my): r.config\n', msg, 'unit: rejection message')
    is(nil, PerlConfig.symbols['%Image::ExifTool::UserDefined::Shortcuts'], 'unit: a rejected file leaves no variable')
    PerlConfig.symbols = { }
end

-- the interpreter running this test (the child processes use the same one)
local lua = TestLib.LUA
do
    local i = -1
    while arg and arg[i - 1] do i = i - 1; lua = arg[i] end
end

local tmpDir = os.tmpname()
os.remove(tmpDir)
local okDir = os.execute('mkdir ' .. shquote(tmpDir))

if not (lua and okDir and package.config:sub(1, 1) == '/') then
    ok(true, 'Perl config checks SKIPPED (no interpreter path or not a POSIX shell)')
    return
end

-- run a command in the repository directory without a default config file;
-- returns stdout, stderr and the exit status
local NO_HOME = '-u EXIFTOOL_HOME -u HOMEDRIVE -u HOMEPATH HOME=' .. shquote(tmpDir .. '/nohome')
os.execute('mkdir ' .. shquote(tmpDir .. '/nohome'))
local function run(cmd, args)
    local errFile = tmpDir .. '/stderr.txt'
    local p = io.popen('cd ' .. shquote(REPO_DIR) .. ' && env ' .. NO_HOME .. ' ' .. cmd .. ' ' .. args ..
                       ' 2>' .. shquote(errFile) .. ' </dev/null; echo "exit $?"')
    local out = p:read('a')
    p:close()
    local status = out:match('exit (%d+)\n$')
    out = out:gsub('exit %d+\n$', '')
    return out, readFile(errFile) or '', status
end
local LEXIFTOOL = lua .. ' ./lexiftool'
local PERL = 'perl -I vendor/exiftool/lib vendor/exiftool/exiftool'
local havePerl = os.execute('perl -e 1 2>/dev/null') and readFile(REPO_DIR .. '/vendor/exiftool/exiftool') ~= nil

-- the lines that differ from run to run or only by the program
-- (FileCreateDate needs the optional File::StatX module in Perl on Linux;
--  Perl names its own source file where a config file does not return a
--  true value)
local function normalize(s)
    s = s:gsub('[^\n]*File%s?Creat.-Date[^\n]*\n?', '')
    s = s:gsub('[^\n]*File%s?Access%s?Date[^\n]*\n?', '')
    s = s:gsub('(did not return a true value) at [^\n]* line %d+%.\n', '%1\n')
    return (s:gsub('_lua%.', '_X.'):gsub('_perl%.', '_X.'))
end

-- (TestLib.is prints both values: for long output only the first line that
--  differs is named)
local function same(exp, got, name)
    if exp == got then
        ok(true, name)
        return true
    end
    local line = 1
    local e, g = exp .. '\n', got .. '\n'
    for el in e:gmatch('([^\n]*)\n') do
        local gl = g:match('^([^\n]*)\n')
        if gl ~= el then
            ok(false, name .. (' (line %d: expected %q, got %q)'):format(line, el, tostring(gl)))
            return false
        end
        g = g:sub(#gl + 2)
        line = line + 1
    end
    ok(false, name .. (' (line %d: unexpected %q)'):format(line, g:match('^[^\n]*')))
    return false
end

-- run both programs with the config file on one command line (OUT.ext and
-- LAST.ext as described above)
local nSame, nCases = 0, 0
local last = { }
local function compare(name, config, args)
    if not havePerl then return end
    nCases = nCases + 1
    local base = tmpDir .. '/' .. name:gsub('[^%w]', '_')
    args = args:gsub('LAST%.(%w+)', function(ext) return shquote(last[ext] or 'missing') end)
    local ext = args:match('OUT%.(%w+)')
    local cfg = '-config ' .. shquote(config) .. ' '
    local lOut, lErr, lStatus = run(LEXIFTOOL, cfg .. args:gsub('OUT%.', base .. '_lua.'))
    local pOut, pErr, pStatus = run(PERL, cfg .. args:gsub('OUT%.', base .. '_perl.'))
    local equal = same(normalize(pOut), normalize(lOut), name .. ': stdout')
    equal = same(normalize(pErr), normalize(lErr), name .. ': stderr') and equal
    equal = same(pStatus, lStatus, name .. ': exit status') and equal
    if ext then
        local lFile, pFile = readFile(base .. '_lua.' .. ext), readFile(base .. '_perl.' .. ext)
        ok(pFile ~= nil and lFile == pFile, name .. ': written file identical')
        equal = equal and pFile ~= nil and lFile == pFile
        last[ext] = base .. '_perl.' .. ext
    end
    if equal then nSame = nSame + 1 end
end

--------------------------------------------------------------------------------
-- 1. the test config files
--------------------------------------------------------------------------------
local fixtures = { 'xmp_namespace', 'quotes', 'numbers', 'lists', 'modules', 'elements', 'mixin', 'pod',
                   'foreign', 'noreturn', 'undefsub', 'warnings', 'hashref', 'preload' }
for _, fixture in ipairs(fixtures) do
    local config = FIXTURES .. fixture .. '.config'
    local text = readFile(REPO_DIR .. '/' .. config)
    ok(text ~= nil, fixture .. ': test config file exists')
    local n = 0
    for args in (text or ''):gmatch('\n# test: ([^\n]*)') do
        n = n + 1
        compare(fixture .. ' ' .. n, config, args)
    end
    ok(n > 0, fixture .. ': has test command lines')
end

--------------------------------------------------------------------------------
-- 2. rejected constructs: line and construct, the command runs on
--------------------------------------------------------------------------------
local rejects = {
    { 'sub',              7, 'sub' },
    { 'named_sub',        3, 'sub' },
    { 'my',               3, 'my' },
    { 'if',               4, 'if' },
    { 'foreach',          3, 'foreach' },
    { 'print',            4, 'print' },
    { 'call',             5, 'call of Image::ExifTool::MWG::Load' },
    { 'method',           3, 'call of Image::ExifTool' },
    { 'variable',         6, 'variable %testDefaults' },
    { 'interpolation',    4, 'interpolation in "..."' },
    { 'heredoc',          4, 'heredoc' },
    { 'qr',               4, 'qr//' },
    { 'use_module',       3, 'use POSIX' },
    { 'package',          3, 'package' },
    { 'begin',            3, 'BEGIN' },
    { 'our',              3, 'our' },
    { 'modifier',         3, 'statement modifier if' },
    { 'map',              4, 'map' },
    { 'root_var',         5, 'variable $Image::ExifTool::evalWarning of package Image::ExifTool' },
    { 'other_package',    4, 'variable %Image::Exiftool::UserDefined' },
    { 'module_table',     4, 'assignment to %Image::ExifTool::XMP::dc of the module' },
    { 'undef_list',       3, 'undef in a list' },
    { 'wide',             3, 'wide character in a string' },
    { 'utf8',             3, 'use utf8 with non-ASCII text' },
    -- (not valid Perl: Perl does not compile these)
    { 'strict',           5, 'bareword Make under use strict', true },
    { 'pod_in_statement', 6, "unexpected '='", true },
    { 'syntax',           6, 'unexpected TestOther', true },
}
for _, r in ipairs(rejects) do
    local name, line, what, invalid = r[1], r[2], r[3], r[4]
    local config = FIXTURES .. 'reject_' .. name .. '.config'
    local out, err = run(LEXIFTOOL, '-config ' .. config .. ' -S -FileType -TestShort ' .. T .. 'GIF.gif')
    is('Config file not supported by lexiftool (Perl code at line ' .. line .. ': ' .. what .. '): ' ..
       config .. '\n', err, 'reject_' .. name .. ': warned with line and construct')
    is('FileType: GIF\n', out, 'reject_' .. name .. ': nothing of the file used, the command runs on')
    if havePerl then
        local _, pErr = run(PERL, '-config ' .. config .. ' -S -FileType ' .. T .. 'GIF.gif')
        if invalid then
            ok(pErr ~= '', 'reject_' .. name .. ': Perl does not compile it either')
        else
            is('', pErr, 'reject_' .. name .. ': valid Perl (Perl loads it)')
        end
    end
end

--------------------------------------------------------------------------------
-- 3. upstream's config_files
--------------------------------------------------------------------------------
local bundled = {
    -- (read: the commands of the file's own topic)
    { 'age',             { '-listx -Composite:Age',
                           -- (the conversions: Perl code with loops, return, references)
                           '-userParam Birthday=1975:06:07 -Age ' .. T .. 'ExifTool.jpg ' .. T .. 'Canon.jpg',
                           "-userParam Birthday=2003:11:30 -userParam 'AgeFormat=%d y %d m %d d' -Age " ..
                           T .. 'GPS.jpg' } },
    { 'bibble',          { '-listx -XMP-dmf:all', '-XMP-dmf:DMFCount=2 -XMP-dmf:DMFSettingsCurLayer=x -o OUT.xmp ' ..
                           T .. 'XMP.xmp', '-a -G1 -s -XMP-dmf:all LAST.xmp' } },
    { 'convert_regions', { '-listx -Composite:all', '-struct -j -Composite:all ' .. IMAGES .. 'lex_MWG_Regions.xmp' } },
    { 'cuepointlist',    { '-listx -Composite:CuePointList' } },
    { 'frameCount',      { '-listx -Composite:FrameCount', '-FrameCount ' .. T .. 'QuickTime.mov ' .. T .. 'Pentax.avi' } },
    { 'guano',           { '-listx -Composite:all' } },
    { 'local_time',      { '-listx -Composite:LocalTime' } },
    { 'nksc',            { '-listx -XMP-ast:all -XMP-sdc:all -XMP-nine:all' } },
    { 'novelty',         { '-listx -XMP-novelty:all', '-XMP-novelty:Concrescence=c -XMP-novelty:Frequency=f -o OUT.xmp ' ..
                           T .. 'XMP.xmp', '-a -G1 -s -XMP-novelty:all LAST.xmp' } },
    { 'onone',           { '-listx -XMP-onone:all', '-UserFlag=u -o OUT.jpg ' .. T .. 'Writer.jpg',
                           '-a -G1 -s -XMP-onone:all LAST.jpg' } },
    { 'pix4d',           { '-listx -XMP-Camera:all', '-XMP-Camera:Albedo=0.5 -XMP-Camera:CalibrationPicture=1 ' ..
                           '-o OUT.xmp ' .. T .. 'XMP.xmp', '-a -G1 -s -XMP-Camera:all LAST.xmp' } },
    { 'rotate_regions',  { '-listx -Composite:all', '-struct -j -Composite:all ' .. IMAGES .. 'lex_MWG_Regions.xmp' } },
    { 'time_zone',       { '-listx -Composite:TimeZone', '-TimeZone ' .. T .. 'GPS.jpg ' .. T .. 'Apple.jpg ' ..
                           T .. 'GoPro.jpg ' .. T .. 'ExifTool.jpg' } },
    -- (rejected: line and construct)
    { 'acdsee',          73, 'use Data::Dumper' },
    { 'depthmap',        14, 'sub' },
    { 'example',         222, 'sub' },
    { 'fotoware',        99, 'map' },
    { 'gps2utm',         26, 'my' },
    { 'photoshop_paths', 83, 'sub' },
    { 'picasa_faces',    73, 'my' },
    { 'tiff_version',    18, 'sub' },
}
for _, b in ipairs(bundled) do
    local config = BUNDLED .. b[1] .. '.config'
    if type(b[2]) == 'table' then
        local _, err = run(LEXIFTOOL, '-config ' .. config .. ' -ver')
        is('', err, b[1] .. '.config: read without a warning')
        for n, args in ipairs(b[2]) do compare(b[1] .. '.config ' .. n, config, args) end
    else
        local out, err = run(LEXIFTOOL, '-config ' .. config .. ' -S -FileType ' .. T .. 'GIF.gif')
        is('Config file not supported by lexiftool (Perl code at line ' .. b[2] .. ': ' .. b[3] .. '): ' ..
           config .. '\n', err, b[1] .. '.config: rejected at its first construct outside the subset')
        is('FileType: GIF\n', out, b[1] .. '.config: the command runs on')
    end
end

if havePerl then
    ok(nSame == nCases, nSame .. ' of ' .. nCases .. ' command lines identical to exiftool with the Perl config files')
else
    ok(true, 'comparison with exiftool SKIPPED (perl not installed)')
end

os.execute('rm -rf ' .. shquote(tmpDir))
