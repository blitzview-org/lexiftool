--------------------------------------------------------------------------------
-- File:         test/test_config.lua
--
-- Description:  the Lua config file (doc/configuration.md) against exiftool
--               with its Perl config file: ./lexiftool runs with
--               src/test/config/example_config.lua, the Perl original
--               (vendor/exiftool/exiftool) with the upstream
--               config_files/example.config it translates, both on the same
--               command line, and their stdout, stderr and exit status -- and
--               for writing commands the written files -- must be equal.
--               The cases are the config features example.config shows:
--               user-defined EXIF, GPS, IPTC, XMP (existing and new
--               namespace, lang-alt, list, structure, flattened Flat tag),
--               PNG, MIE (new group) and Composite tags (Perl expression
--               strings and a Lua function), read and written, in
--               -list/-listx/-X/-j, Shortcuts (also with -tagsFromFile),
--               Options (CoordFormat, Duplicates), Lenses (LensID),
--               FileTypes, Arguments (-i HIDDEN) and the QuickTime Keys
--               PREFERRED level set from the config.  Then the cases only
--               lexiftool has: the lookup of .lexiftool_config and of an
--               .ExifTool_config holding Lua, and the errors of a Lua config
--               file (syntax error, unknown entry, a module outside lexiftool,
--               a chunk returning no table, Perl syntax outside perl.eval in a
--               conversion string), plus an unknown table name, again against
--               Perl.
--               The user-defined Geolocation city of example.config is
--               looked up by name and by position.  example.config sets
--               RequestAll 3, so the command lines that print all tags show
--               the ExifTool tags Now, NewGUID, NewUUID and ProcessingTime,
--               whose values differ from run to run: they are compared by
--               their form only (date/time, GUID and UUID format, seconds).
--               The Perl comparisons are skipped where perl is not
--               installed.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok

local REPO_DIR = TestLib.REPO_DIR
local T = 'vendor/exiftool/t/images/'
local LUA_CONFIG = 'src/test/config/example_config.lua'
local PERL_CONFIG = 'vendor/exiftool/config_files/example.config'

local function shquote(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
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
    ok(true, 'config checks SKIPPED (no interpreter path or not a POSIX shell)')
    return
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local data = fh:read('a')
    fh:close()
    return data
end

local function writeFile(path, text)
    local fh = io.open(path, 'wb')
    fh:write(text)
    fh:close()
end

-- run a command in the repository directory with an environment prefix
-- (`env ...` arguments); returns stdout, stderr and the exit status
local NO_HOME = '-u EXIFTOOL_HOME -u HOMEDRIVE -u HOMEPATH HOME=' .. shquote(tmpDir .. '/nohome')
os.execute('mkdir ' .. shquote(tmpDir .. '/nohome'))
local function run(envArgs, cmd, args)
    local errFile = tmpDir .. '/stderr.txt'
    local p = io.popen('cd ' .. shquote(REPO_DIR) .. ' && env ' .. envArgs .. ' ' .. cmd .. ' ' .. args ..
                       ' 2>' .. shquote(errFile) .. ' </dev/null; echo "exit $?"')
    local out = p:read('a')
    p:close()
    local status = out:match('exit (%d+)\n$')
    out = out:gsub('exit %d+\n$', '')
    return out, readFile(errFile) or '', status
end
local function lexiftool(args, envArgs)
    return run(envArgs or NO_HOME, lua .. ' ./lexiftool', args)
end
local PERL = 'perl -I vendor/exiftool/lib vendor/exiftool/exiftool'
local havePerl = os.execute('perl -e 1 2>/dev/null') and readFile(REPO_DIR .. '/vendor/exiftool/exiftool') ~= nil

-- the values that differ from run to run, replaced where they have their
-- form (in -s/-G output "Name : value", in -X "<G:Name>value", in -j
-- "Name": "value"); a value of another form stays and shows as a difference
local X = '%x%x%x%x'
local volatile = {
    { 'Now', '%d%d%d%d:%d%d:%d%d %d%d:%d%d:%d%d[+-]%d%d:%d%d' },
    { 'NewGUID', '%d%d%d%d%d%d%d%d%-%d%d%d%d%-' .. X .. '%-' .. X .. '%-' .. X .. X .. X },
    { 'NewUUID', X .. X .. '%-' .. X .. '%-4%x%x%x%-[89AB]%x%x%x%-' .. X .. X .. X },
    { 'ProcessingTime', '%d[%d.e%-]* s' },
}
local function maskVolatile(s)
    for _, v in ipairs(volatile) do
        s = s:gsub('(' .. v[1] .. '[">: ]+)' .. v[2], '%1<' .. v[1] .. '>')
    end
    return s
end

-- (the two config files' names, and the output files' names, differ)
-- FileCreateDate on Linux is only extracted when the host Perl has the
-- optional File::StatX module, while lexiftool.sys always has statx(); the
-- config tests are about config semantics, so drop that line.
local function normalize(s)
    s = s:gsub('[^\n]*File%s?Creat.-Date[^\n]*\n?', '')
    return (maskVolatile(s):gsub(LUA_CONFIG:gsub('%p', '%%%0'), 'CONFIG')
             :gsub(PERL_CONFIG:gsub('%p', '%%%0'), 'CONFIG')
             :gsub('_lua%.', '_X.'):gsub('_perl%.', '_X.'))
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

-- run lexiftool with the Lua config and exiftool with the Perl config
-- (`args` may name the output file as OUT.<ext>: OUT becomes <name>_lua and
--  <name>_perl in the temporary directory, and the two files are compared);
-- `filter` edits Perl's stderr for a line only Perl has
local nSame, nCases = 0, 0
local function compare(name, args, filter)
    if not havePerl then return end
    nCases = nCases + 1
    local base = tmpDir .. '/' .. name
    local ext = args:match('OUT%.(%w+)')
    local lOut, lErr, lStatus = lexiftool('-config ' .. LUA_CONFIG .. ' ' .. args:gsub('OUT%.', base .. '_lua.'))
    local pOut, pErr, pStatus = run(NO_HOME, PERL, '-config ' .. PERL_CONFIG .. ' ' .. args:gsub('OUT%.', base .. '_perl.'))
    if filter then pErr = filter(pErr) end
    local equal = same(normalize(pOut), normalize(lOut), name .. ': stdout')
    equal = same(normalize(pErr), normalize(lErr), name .. ': stderr') and equal
    equal = same(pStatus, lStatus, name .. ': exit status') and equal
    if ext then
        local lFile, pFile = readFile(base .. '_lua.' .. ext), readFile(base .. '_perl.' .. ext)
        ok(pFile ~= nil and lFile == pFile, name .. ': written file identical')
        equal = equal and pFile ~= nil and lFile == pFile
    end
    if equal then nSame = nSame + 1 end
end

--------------------------------------------------------------------------------
-- 1. writing and reading the user-defined tags
--------------------------------------------------------------------------------
compare('w1', '-NewEXIFTag=123 -GPSPitch=1.5 -XMP-exif:GPSRoll=2.5 -NewIPTCTag=hello -NewXMPxxxTag1=foo ' ..
              '-NewXMPxxxTag2=bar -NewXMPxxxTag3=a -NewXMPxxxTag3=b -XMP-xmp:NewXMPxmpTag=xm -o OUT.jpg ' ..
              T .. 'Writer.jpg')
local W1 = tmpDir .. '/w1_perl.jpg'
compare('r1', '-a -G1 -s ' .. shquote(W1))
compare('r1-tags', '-a -G1 -s -NewEXIFTag -GPSPitch -GPSRoll -NewIPTCTag -XMP-xxx:all -NewXMPxmpTag ' .. shquote(W1))
compare('r1-X', '-X ' .. shquote(W1))
compare('w2', [['-NewXMPxxxStruct={X=1,Y=2,Things=[{What=a,Where=b},{What=c}]}' -SomeOtherName=5 ]] ..
              '-o OUT.jpg ' .. T .. 'Writer.jpg')
compare('r2-json', '-j -struct -XMP:all ' .. shquote(tmpDir .. '/w2_perl.jpg'))
compare('r2-flat', '-G1 -s -XMP-xxx:all ' .. shquote(tmpDir .. '/w2_perl.jpg'))
compare('w3-lang', '-NewXMPxxxTag1-de=hallo -NewXMPxxxTag1=hi -GPSRoll=-1.25 -o OUT.jpg ' .. T .. 'Writer.jpg')
compare('w4-delete', '-NewEXIFTag= -GPSPitch= -XMP-xxx:all= -o OUT.jpg ' .. shquote(W1))
compare('w5-mie', '-NewMieTag1=1.5 -NewMieTag2=hello -o OUT.mie ' .. T .. 'MIE.mie')
compare('r5-mie', '-a -G1 -s ' .. shquote(tmpDir .. '/w5-mie_perl.mie'))
compare('w6-png', '-NewPngTag1=one -NewPngTag2=two -NewPngTag3=three -o OUT.png ' .. T .. 'PNG.png')
compare('r6-png', '-G1 -s -PNG:all ' .. shquote(tmpDir .. '/w6-png_perl.png'))
-- (QuickTime Keys PREFERRED 3, set by the config: Artist goes to Keys too)
compare('w7-keys', '-Artist=me -o OUT.mov ' .. T .. 'QuickTime.mov')
compare('w7-keys-title', '-Keys:Title=title -Keys:LocationName=here -o OUT.mov ' .. T .. 'QuickTime.mov')
compare('r7-keys', '-a -G1 -s -Keys:all ' .. shquote(tmpDir .. '/w7-keys-title_perl.mov'))

--------------------------------------------------------------------------------
-- 2. Composite tags, Shortcuts, Options, Lenses
--------------------------------------------------------------------------------
compare('composite', '-G1 -s -FileExtension -CircleOfConfusion -FileTypeDescription -PhysicalImageSize ' ..
                     T .. 'Canon.jpg ' .. T .. 'Nikon.jpg ' .. T .. 'ExifTool.jpg')
compare('bigimage', '-s -BigImage ' .. T .. 'DNG.dng ' .. T .. 'Nikon.jpg ' .. T .. 'CanonRaw.cr2')
compare('bigimage-b', '-b -BigImage ' .. T .. 'CanonRaw.cr2')
compare('shortcuts', '-s -MyShortcut -MyAlias ' .. T .. 'Canon.jpg')
compare('w8-shortcut', '-tagsFromFile ' .. T .. 'Canon.jpg -MyShortcut -o OUT.jpg ' .. T .. 'Writer.jpg')
compare('w9-alias', '-tagsFromFile ' .. T .. [[Canon.jpg '-NewXMPxxxTag2<MyAlias' '-NewIPTCTag<Model' -o OUT.jpg ]] ..
                    T .. 'Writer.jpg')
compare('coordformat', '-s -GPSLatitude -GPSPosition ' .. T .. 'GPS.jpg')
compare('duplicates', '-G1 -s ' .. T .. 'Canon.jpg')
compare('lenses', '-s -LensID ' .. T .. 'Pentax.jpg ' .. T .. 'Canon.jpg ' .. T .. 'Nikon.jpg')
-- (the user-defined Geolocation city, by name and by position)
compare('geolocation', '-api Geolocation=Sinemorets -G1 -s -Geolocation* ' .. T .. 'GIF.gif')
compare('geolocation-pos', '-api Geolocation=42.06,27.97 -G1 -s -Geolocation* ' .. T .. 'GIF.gif')

--------------------------------------------------------------------------------
-- 3. FileTypes and Arguments
--------------------------------------------------------------------------------
do
    local dir = tmpDir .. '/types'
    os.execute('mkdir ' .. shquote(dir))
    writeFile(dir .. '/a.xxx', readFile(REPO_DIR .. '/' .. T .. 'ExifTool.tif'))
    writeFile(dir .. '/b.ttt', readFile(REPO_DIR .. '/' .. T .. 'Writer.jpg'))
    writeFile(dir .. '/c.yyy', '0123abcdefgh')
    writeFile(dir .. '/d.zzz', 'hello')
    writeFile(dir .. '/.hidden.gif', readFile(REPO_DIR .. '/' .. T .. 'GIF.gif'))
    compare('filetypes', '-s -FileType -FileTypeExtension -MIMEType -FileTypeDescription ' ..
                         shquote(dir .. '/a.xxx') .. ' ' .. shquote(dir .. '/b.ttt') .. ' ' ..
                         shquote(dir .. '/c.yyy') .. ' ' .. shquote(dir .. '/d.zzz'))
    compare('filetype-nowrite', '-Artist=x ' .. shquote(dir .. '/a.xxx'))
    -- (the default arguments -i HIDDEN skip .hidden.gif)
    compare('arguments', '-s -FileName ' .. shquote(dir))
end

--------------------------------------------------------------------------------
-- 4. the tag lists
--------------------------------------------------------------------------------
for _, args in ipairs({ '-list', '-listw', '-listf', '-listwf', '-listg1', '-listx -XMP-xxx:all' }) do
    compare(args, args)
end

--------------------------------------------------------------------------------
-- 5. an unknown table name (against Perl, whose `require` of the missing
--    module warns a Perl message first)
--------------------------------------------------------------------------------
do
    local luaConfig, perlConfig = tmpDir .. '/unknown.lua', tmpDir .. '/unknown.config'
    writeFile(luaConfig, "return {\n    UserDefined = {\n" ..
                         "        ['Image::ExifTool::Foo::Bar'] = { Baz = { Writable = 'string' } },\n    },\n}\n")
    writeFile(perlConfig, "%Image::ExifTool::UserDefined = (\n" ..
                          "    'Image::ExifTool::Foo::Bar' => { Baz => { Writable => 'string' } },\n);\n1;\n")
    if havePerl then
        local args = ' -Baz=1 -o ' .. shquote(tmpDir .. '/unknown_%s.gif') .. ' ' .. T .. 'GIF.gif'
        local lOut, lErr = lexiftool('-config ' .. shquote(luaConfig) .. args:format('lua'))
        local pOut, pErr = run(NO_HOME, PERL, '-config ' .. shquote(perlConfig) .. args:format('perl'))
        pErr = pErr:gsub("Can't locate Image/ExifTool/Foo%.pm[^\n]*\n", '')
        same(pErr, lErr, 'unknown table: stderr as Perl ("Can\'t find table ...")')
        same(pOut, lOut, 'unknown table: stdout as Perl')
    end
end

--------------------------------------------------------------------------------
-- 6. lookup of the default config file
--------------------------------------------------------------------------------
do
    local IMAGE = T .. 'GIF.gif'
    local luaHome, bothHome = tmpDir .. '/luahome', tmpDir .. '/bothhome'
    os.execute('mkdir ' .. shquote(luaHome) .. ' ' .. shquote(bothHome))
    local shortcut = "return { Shortcuts = { MyType = 'FileType' } }\n"
    -- (an .ExifTool_config whose first line marks it as Lua)
    writeFile(luaHome .. '/.ExifTool_config', '-- lexiftool config\n' .. shortcut)
    local out, err = lexiftool('-S -MyType ' .. IMAGE, '-u EXIFTOOL_HOME HOME=' .. shquote(luaHome))
    is('FileType: GIF\n', out, '.ExifTool_config with the "-- lexiftool config" line is loaded as Lua')
    is('', err, '.ExifTool_config with Lua: no warning')
    -- (.lexiftool_config takes the place of a Perl .ExifTool_config)
    writeFile(bothHome .. '/.ExifTool_config', '%Image::ExifTool::UserDefined = ( );\n1;  #end\n')
    writeFile(bothHome .. '/.lexiftool_config', shortcut)
    out, err = lexiftool('-S -MyType ' .. IMAGE, '-u EXIFTOOL_HOME HOME=' .. shquote(bothHome))
    is('FileType: GIF\n', out, '.lexiftool_config is loaded')
    is('', err, '.lexiftool_config is preferred to the Perl .ExifTool_config')
    out, err = lexiftool('-S -MyType ' .. IMAGE, '-u HOME EXIFTOOL_HOME=' .. shquote(bothHome))
    is('FileType: GIF\n', out, '.lexiftool_config in EXIFTOOL_HOME')
    is('', err, '.lexiftool_config in EXIFTOOL_HOME: no warning')
    -- (a Perl config file named with -config still only warns)
    out, err = lexiftool('-config ' .. shquote(bothHome .. '/.ExifTool_config') .. ' -S -FileType ' .. IMAGE)
    is('Config file not supported by lexiftool (Perl code): ' .. bothHome .. '/.ExifTool_config\n', err,
       'a Perl config file warns')
    is('FileType: GIF\n', out, 'a Perl config file: the command runs on')
end

--------------------------------------------------------------------------------
-- 7. errors in a Lua config file (lexiftool only: the message is Lua's,
--    with file:line, and the command runs on without the configuration)
--------------------------------------------------------------------------------
do
    local IMAGE = T .. 'GIF.gif'
    local function config(name, text)
        local file = tmpDir .. '/' .. name .. '.lua'
        writeFile(file, text)
        return lexiftool('-config ' .. shquote(file) .. ' -S -FileType -MyTest ' .. IMAGE)
    end
    local file = tmpDir .. '/syntax.lua'
    local out, err = config('syntax', 'return {\n    UserDefined = {\n')
    is(file .. ':3: unexpected symbol near <eof>\n', err, 'syntax error: warned with file:line')
    is('FileType: GIF\n', out, 'syntax error: the command runs on')
    out, err = config('entry', 'return { Bogus = 1 }\n')
    is("Unknown entry 'Bogus' in config file " .. tmpDir .. '/entry.lua\n', err, 'unknown entry warns')
    is('FileType: GIF\n', out, 'unknown entry: the command runs on')
    out, err = config('module', "local os = require('os')\nreturn { }\n")
    is(tmpDir .. "/module.lua:1: module 'os' is not available in a lexiftool config file\n", err,
       'only lexiftool modules can be required')
    is('FileType: GIF\n', out, 'module outside lexiftool: the command runs on')
    out, err = config('global', "io.write('x')\nreturn { }\n")
    ok(err:find(tmpDir .. "/global.lua:1: attempt to index a nil value (global 'io')", 1, true) ~= nil,
       'io is not visible: ' .. err)
    is('FileType: GIF\n', out, 'io not visible: the command runs on')
    out, err = config('number', 'return 42\n')
    is('Config file ' .. tmpDir .. '/number.lua did not return a table\n', err, 'a chunk returning no table')
    is('FileType: GIF\n', out, 'a chunk returning no table: the command runs on')
    local unsupported = tmpDir .. '/unsupported.lua'
    writeFile(unsupported, "return { UserDefined = { ['Image::ExifTool::Composite'] = {\n" ..
              "    MyTest = { Require = 'FileName', ValueConv = 'join(\",\", map { uc } split //, $val)' },\n" ..
              "} } }\n")
    out, err = lexiftool('-config ' .. shquote(unsupported) .. ' -S -MyTest ' .. IMAGE)
    is('Warning: ValueConv MyTest: Perl syntax unsupported in lexiftool: map (near "map { uc } split //,") - ' ..
       IMAGE .. '\n', err, 'Perl syntax outside perl.eval in a conversion string warns at use')
    is('', out, 'the tag with the unsupported conversion has no value')
    out = config('luaconv', "return { UserDefined = { ['Image::ExifTool::Composite'] = {\n" ..
                 "    MyTest = { Require = { [0] = 'FileType', [1] = 'FileName' },\n" ..
                 "               ValueConv = function(self, val) return val[0] .. '/' .. val[1] end,\n" ..
                 "               PrintConv = 'lc $val' },\n} } }\n")
    is('FileType: GIF\nMyTest: gif/gif.gif\n', out, 'Lua function ValueConv and Perl string PrintConv')
end

if havePerl then
    ok(nSame == nCases, nSame .. ' of ' .. nCases .. ' command lines identical to exiftool with example.config')
else
    ok(true, 'comparison with exiftool SKIPPED (perl not installed)')
end

os.execute('rm -rf ' .. shquote(tmpDir))
