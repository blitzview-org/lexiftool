--------------------------------------------------------------------------------
-- File:         test/test_perl_parity.lua
--
-- Description:  behaviours the upstream test images and .out files do not
--               reach, checked against the Perl original: each case runs
--               ./lexiftool and vendor/exiftool/exiftool on the same command
--               line and compares stdout, stderr, exit status and the
--               written file; the fixed expectations next to them are
--               exiftool's output for the same command line.
--                 1. Composite build order: GPSPosition from XMP GPS tags is
--                    built after GPSLatitudeRef/GPSLongitudeRef (XMP.pm loads
--                    GPS.pm, whose Composite GPSLatitude defers it)
--                 2. QuickTime Keys: a new Keys tag in an existing Keys box,
--                    and a Meta/Keys/ItemList created in a file without one
--                 3. the API options NoWarning, ImageHashType, StructFormat
--                    and ByteUnit (validation messages, NoWarning+=)
--                 4. the ExifTool and System tags Now, NewGUID, NewUUID,
--                    FileSequence, ProcessingTime, BaseName, FilePath and
--                    the SystemTags (values that differ from run to run are
--                    compared by their form)
--                 5. GetTagTable warns "Can't find table" for every table it
--                    cannot find
--               The Perl comparisons are skipped where perl is not installed;
--               the fixed expectations run everywhere.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok

local REPO_DIR = TestLib.REPO_DIR
local T = 'vendor/exiftool/t/images/'

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
    ok(true, 'Perl parity checks SKIPPED (no interpreter path or not a POSIX shell)')
    return
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local data = fh:read('a')
    fh:close()
    return data
end

-- run a command in the repository directory without a config file; returns
-- stdout, stderr and the exit status
local ENV = '-u EXIFTOOL_HOME -u HOMEDRIVE -u HOMEPATH HOME=' .. shquote(tmpDir)
local function run(cmd, args)
    local errFile = tmpDir .. '/stderr.txt'
    local p = io.popen('cd ' .. shquote(REPO_DIR) .. ' && env ' .. ENV .. ' ' .. cmd .. ' ' .. args ..
                       ' 2>' .. shquote(errFile) .. ' </dev/null; echo "exit $?"')
    local out = p:read('a')
    p:close()
    local status = out:match('exit (%d+)\n$')
    out = out:gsub('exit %d+\n$', '')
    return out, readFile(errFile) or '', status
end
local LUA = lua .. ' ./lexiftool'
local PERL = 'perl -I vendor/exiftool/lib vendor/exiftool/exiftool'
local havePerl = os.execute('perl -e 1 2>/dev/null') and readFile(REPO_DIR .. '/vendor/exiftool/exiftool') ~= nil

-- the values that differ from run to run, replaced where they have their form
local X = '%x%x%x%x'
local volatile = {
    { 'Now', '%d%d%d%d:%d%d:%d%d %d%d:%d%d:%d%d[+-]%d%d:%d%d' },
    { 'NewGUID', '%d%d%d%d%d%d%d%d%-%d%d%d%d%-' .. X .. '%-' .. X .. '%-' .. X .. X .. X },
    { 'NewUUID', X .. X .. '%-' .. X .. '%-4%x%x%x%-[89AB]%x%x%x%-' .. X .. X .. X },
    { 'ProcessingTime', '%d[%d.e%-]* s' },
}
local sysname = require('lexiftool.sys').platform()
local function normalize(s)
    -- Linux FileCreateDate needs the host Perl's optional File::StatX module;
    -- lexiftool.sys has statx() natively, so the line may be present on only
    -- one side (the rest of the system tags are compared below)
    if sysname == 'linux' then s = s:gsub('[^\n]*File%s?Creat.-Date[^\n]*\n?', '') end
    for _, v in ipairs(volatile) do
        s = s:gsub('(' .. v[1] .. '[">: ]+)' .. v[2], '%1<' .. v[1] .. '>')
    end
    return (s:gsub('_lua%.', '_X.'):gsub('_perl%.', '_X.'))
end

-- compare ./lexiftool with exiftool on one command line (OUT.<ext> names the
-- output file, written as <name>_lua/<name>_perl and compared); returns
-- lexiftool's stdout and stderr for the fixed expectations
local nSame, nCases = 0, 0
local function compare(name, args)
    local base = tmpDir .. '/' .. name
    local ext = args:match('OUT%.(%w+)')
    local lOut, lErr, lStatus = run(LUA, (args:gsub('OUT%.', base .. '_lua.')))
    if not havePerl then return lOut, lErr end
    nCases = nCases + 1
    local pOut, pErr, pStatus = run(PERL, (args:gsub('OUT%.', base .. '_perl.')))
    local equal = true
    local function same(exp, got, what)
        is(exp, got, name .. ': ' .. what)
        if exp ~= got then equal = false end
    end
    same(normalize(pOut), normalize(lOut), 'stdout as exiftool')
    same(normalize(pErr), normalize(lErr), 'stderr as exiftool')
    same(pStatus, lStatus, 'exit status as exiftool')
    if ext then
        local lFile, pFile = readFile(base .. '_lua.' .. ext), readFile(base .. '_perl.' .. ext)
        same(true, pFile ~= nil and lFile == pFile, 'written file identical')
    end
    if equal then nSame = nSame + 1 end
    return lOut, lErr
end

--------------------------------------------------------------------------------
-- 1. Composite build order
--------------------------------------------------------------------------------
do
    compare('w-xmpgps', '-xmp:gpslatitude=10 -xmp:gpslongitude=20 -o OUT.jpg ' .. T .. 'Writer.jpg')
    local file = tmpDir .. '/w-xmpgps_lua.jpg'
    local out = compare('r-xmpgps', '-a -G1 -s -Composite:all ' .. shquote(file))
    is('[Composite]     ImageSize                       : 8x8\n' ..
       '[Composite]     Megapixels                      : 0.000064\n' ..
       '[Composite]     GPSLatitudeRef                  : North\n' ..
       '[Composite]     GPSLongitudeRef                 : East\n' ..
       [[[Composite]     GPSPosition                     : 10 deg 0' 0.00" N, 20 deg 0' 0.00" E]] .. '\n',
       out, 'GPSPosition from XMP is built after GPSLatitudeRef/GPSLongitudeRef')
end

--------------------------------------------------------------------------------
-- 2. QuickTime Keys
--------------------------------------------------------------------------------
do
    compare('w-keys', '-keys:LocationName=Foo -Keys:Title=Bar -o OUT.mov ' .. T .. 'QuickTime.mov')
    local out = compare('r-keys', '-a -G1 -s -Keys:all ' .. shquote(tmpDir .. '/w-keys_lua.mov'))
    is('[Keys]          Album                           : ålbum\n' ..
       '[Keys]          Artist                          : årtist\n' ..
       '[Keys]          Comment                         : çømménts\n' ..
       '[Keys]          LocationName                    : Foo\n' ..
       '[Keys]          Title                           : Bar\n',
       out, 'new Keys tags are added to the existing Keys box')
    -- (a movie without Meta: Meta with mdta handler, Keys and ItemList are created)
    run(LUA, '-quicktime:all= -o ' .. shquote(tmpDir .. '/nometa.mov') .. ' ' .. T .. 'QuickTime.mov')
    local nometa = shquote(tmpDir .. '/nometa.mov')
    compare('w-keys-new', '-Keys:LocationName=here -Keys:Comment=c -ItemList:Title=t -o OUT.mov ' .. nometa)
    out = compare('r-keys-new', '-a -G1 -s -Keys:all -ItemList:all ' .. shquote(tmpDir .. '/w-keys-new_lua.mov'))
    is('[Keys]          Comment                         : c\n' ..
       '[Keys]          LocationName                    : here\n' ..
       '[ItemList]      Title                           : t\n',
       out, 'Keys tags are created in a movie without Meta')
    compare('w-keys-del', '-Keys:all= -Keys:Title=x -o OUT.mov ' .. T .. 'QuickTime.mov')
end

--------------------------------------------------------------------------------
-- 3. options
--------------------------------------------------------------------------------
do
    local gif = T .. 'GIF.gif'
    for _, case in ipairs({
        { 'ImageHashType=foo', "Invalid ImageHashType setting 'foo'\n" },
        { 'ImageHashType=', "Can't set ImageHashType to undef\n" },
        { 'StructFormat=xx', "Invalid StructFormat setting 'xx'\n" },
        { 'ByteUnit=xx', "Invalid ByteUnit setting 'xx'\n" },
        { 'ByteUnit=', "Can't set ByteUnit to undef\n" },
        { 'ImageHashType=sha256', '' },
        { 'StructFormat=jsonq', '' },
        { 'ByteUnit=metric', '' },
    }) do
        local _, err = compare('api-' .. case[1], '-api ' .. case[1] .. ' -S -FileType ' .. gif)
        is(case[2], err, '-api ' .. case[1] .. ': stderr')
    end
    -- (an invalid NoWarning expression: exiftool's message is Perl's regex
    --  compiler's, lexiftool's PCRE2's -- doc/differences.md)
    local _, err = run(LUA, "-api 'NoWarning=(' -S -FileType " .. gif)
    is('NoWarning: missing closing parenthesis in regex; marked by <-- HERE in m/( <-- HERE /\n', err,
       'an invalid NoWarning expression is warned')
    local jpg = T .. 'GE.jpg'
    for _, opts in ipairs({ '-api NoWarning=minor', '-api NoWarning=xyz -api NoWarning+=minor',
                            '-api IgnoreMinorErrors -api NoWarning=xyz', '-api NoWarning=xyz' }) do
        compare('nowarning ' .. opts, opts .. ' -a -G1 -s -Warning ' .. jpg)
    end
    local out = run(LUA, '-api NoWarning=xyz -api NoWarning+=minor -a -G1 -s -Warning ' .. jpg)
    is('', out, 'NoWarning+= adds to the expression')
    out = run(LUA, '-api NoWarning=xyz -a -G1 -s -Warning ' .. jpg)
    ok(out:find('Warning', 1, true) ~= nil, 'NoWarning leaves the other warnings')
    compare('bytes-binary', '-api ByteUnit=Binary -FileSize ' .. T .. 'Canon.jpg')
    compare('structformat', '-api StructFormat=JSONQ -struct -j -XMP:all ' .. T .. 'XMP.jpg')
end

--------------------------------------------------------------------------------
-- 4. ExifTool and System tags
--------------------------------------------------------------------------------
do
    local files = T .. 'GIF.gif ' .. T .. 'PNG.png'
    local out = compare('extra', '-G1 -s -Now -NewGUID -NewUUID -FileSequence -ProcessingTime ' ..
                                 '-BaseName -FileName ' .. files)
    out = normalize(out)
    ok(out:find('\n%[ExifTool%]%s+Now%s+: <Now>\n%[ExifTool%]%s+NewGUID%s+: <NewGUID>\n' ..
                '%[ExifTool%]%s+NewUUID%s+: <NewUUID>\n%[ExifTool%]%s+FileSequence%s+: 0\n' ..
                '%[ExifTool%]%s+ProcessingTime%s+: <ProcessingTime>\n%[System%]%s+BaseName%s+: GIF\n' ..
                '%[System%]%s+FileName%s+: GIF%.gif\n') ~= nil, 'the ExifTool tags of the first file: ' .. out)
    ok(out:find('FileSequence%s+: 1\n') ~= nil, 'FileSequence counts the files')
    compare('filepath', '-G1 -s -FilePath ' .. files)
    out = run(LUA, '-s -s -FilePath ' .. T .. 'GIF.gif')
    is('FilePath: ' .. REPO_DIR:gsub('/$', '') .. '/' .. T .. 'GIF.gif\n', out, 'FilePath is the absolute path')
    compare('requestall', '-api RequestAll=3 -a -G1 -s ' .. files)
    compare('systemtags', '-api SystemTags -n -System:all ' .. T .. 'GIF.gif')
    compare('systemtags-off', '-api RequestAll=3 -api SystemTags=0 -a -G1 -s ' .. T .. 'GIF.gif')
    compare('fileseq-p', [[-p '$FileSequence $BaseName' ]] .. files)
    -- (an unreadable file: one Error tag, and ProcessingTime as exiftool)
    local unreadable = tmpDir .. '/unreadable.txt'
    local fh = io.open(unreadable, 'w')
    fh:write('x')
    fh:close()
    os.execute('chmod 000 ' .. shquote(unreadable))
    compare('unreadable', '-a -G1 -s -ProcessingTime ' .. shquote(unreadable))
end

--------------------------------------------------------------------------------
-- 5. "Can't find table"
--------------------------------------------------------------------------------
do
    local ExifTool = require('lexiftool')
    local perl = require('lexiftool.perl')
    local warned = { }
    local oldWarn = perl.SIG.__WARN__
    perl.SIG.__WARN__ = function(msg) warned[#warned + 1] = msg end
    local tbl = ExifTool.GetTagTable(nil, 'lexiftool.Exif.NoSuchTable')
    local tbl2 = ExifTool.GetTagTable(nil, 'lexiftool.ExifTool.NoSuchTable')
    perl.SIG.__WARN__ = oldWarn
    is(nil, tbl, 'a missing table is undef')
    is(nil, tbl2, 'a missing ExifTool.pm table is undef')
    is("Can't find table Image::ExifTool::Exif::NoSuchTable\n", warned[1], 'a missing table warns')
    is("Can't find table Image::ExifTool::NoSuchTable\n", warned[2], 'a missing ExifTool.pm table warns')
    if havePerl then
        local _, err = run('perl', [[-I vendor/exiftool/lib -MImage::ExifTool -e ']] ..
                                   [[Image::ExifTool::GetTagTable("Image::ExifTool::Exif::NoSuchTable");]] ..
                                   [[Image::ExifTool::GetTagTable("Image::ExifTool::NoSuchTable")']])
        is(err, warned[1] .. warned[2], 'the warnings are exiftool\'s')
    end
end

if havePerl then
    ok(nSame == nCases, nSame .. ' of ' .. nCases .. ' command lines identical to exiftool')
else
    ok(true, 'comparison with exiftool SKIPPED (perl not installed)')
end

os.execute('chmod -R u+rw ' .. shquote(tmpDir) .. '; rm -rf ' .. shquote(tmpDir))
