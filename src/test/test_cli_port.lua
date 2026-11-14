--------------------------------------------------------------------------------
-- File:         test/test_cli_port.lua
--
-- Description:  the command-line behaviours where lexiftool deliberately
--               differs from upstream exiftool (doc/differences.md), which
--               a CLI comparison against the Perl original
--               therefore cannot check:
--                 1. config files are Perl code: `-config FILE` and an
--                    .ExifTool_config found via EXIFTOOL_HOME / HOME /
--                    HOMEDRIVE+HOMEPATH that hold Perl beyond data (here a
--                    sub) warn "Config file not supported by lexiftool
--                    (Perl code at line N: CONSTRUCT): FILE" and the command
--                    runs on without configuration (the Perl data configs
--                    lexiftool reads: test_perlconfig.lua)
--                 2. a -if condition in Perl syntax that perl.eval does not
--                    interpret is reported even without -v
--                 3. -ver -v lists the Lua counterparts of the optional Perl
--                    modules and a line for the port itself; -ver alone is
--                    upstream's
--                 4. the launcher starts in a shell whose LUA_PATH/LUA_CPATH
--                    point at another Lua version's rock tree
--                 5. the launcher prefers the source tree next to it
--                 6. a Geolocation language file GeoLang/<lang>.lua comes
--                    before the GeoLang/<lang>.pm beside it (exiftool reads
--                    only the .pm); a .pm along LUA_PATH is found; a .pm
--                    that is not a pure data table warns and is not used.
--                    The reference output is lexiftool's on the .pm alone,
--                    which the CLI golden case geolang-ru-pm checks
--                    against exiftool
--               Each check runs ./lexiftool in a child process with the
--               interpreter running this test.
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local is, ok = TestLib.is, TestLib.ok

local REPO_DIR = TestLib.REPO_DIR
local IMAGE = TestLib.T_DIR .. '/images/GIF.gif'

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

-- run ./lexiftool with an environment prefix (`env ...` arguments) and
-- command-line arguments (already quoted); returns stdout, stderr
local function run(envArgs, args)
    local errFile = tmpDir .. '/stderr.txt'
    local cmd = 'cd ' .. shquote(REPO_DIR) .. ' && env ' .. envArgs .. ' ' .. lua ..
                ' ./lexiftool ' .. args .. ' 2>' .. shquote(errFile) .. ' </dev/null'
    local p = io.popen(cmd)
    local out = p:read('a')
    p:close()
    local fh = io.open(errFile, 'rb')
    local err = fh and fh:read('a') or ''
    if fh then fh:close() end
    return out, err
end

local function writeFile(path, text)
    local fh = io.open(path, 'wb')
    fh:write(text)
    fh:close()
end

if not (lua and okDir and package.config:sub(1, 1) == '/') then
    ok(true, 'CLI port checks SKIPPED (no interpreter path or not a POSIX shell)')
    return
end

local SUPPORTED = 'Config file not supported by lexiftool (Perl code at line 1: sub): '
local fileType = 'FileType: GIF\n'

--------------------------------------------------------------------------------
-- 1. config files
--------------------------------------------------------------------------------
do
    local home = tmpDir .. '/home'
    os.execute('mkdir ' .. shquote(home))
    local config = home .. '/.ExifTool_config'
    writeFile(config, 'sub Helper { }\n%Image::ExifTool::UserDefined = ( );\n1;  #end\n')
    local empty = tmpDir .. '/empty'
    os.execute('mkdir ' .. shquote(empty))
    local noHome = '-u EXIFTOOL_HOME -u HOMEDRIVE -u HOMEPATH'

    local out, err = run(noHome .. ' HOME=' .. shquote(empty),
                         '-config ' .. shquote(config) .. ' -S -FileType ' .. shquote(IMAGE))
    is(SUPPORTED .. config .. '\n', err, '-config FILE warns that config files are not supported')
    is(fileType, out, '-config FILE: the command runs on without configuration')

    out, err = run(noHome .. ' HOME=' .. shquote(home), '-S -FileType ' .. shquote(IMAGE))
    is(SUPPORTED .. home .. '/.ExifTool_config\n', err, '$HOME/.ExifTool_config is found and warned about')
    is(fileType, out, '$HOME/.ExifTool_config: the command runs on')

    out, err = run(noHome .. ' HOME=' .. shquote(home), '-config "" -S -FileType ' .. shquote(IMAGE))
    is('', err, '-config "" disables the configuration (no warning)')
    is(fileType, out, '-config "": the command runs')

    out, err = run('-u HOMEDRIVE -u HOMEPATH EXIFTOOL_HOME=' .. shquote(empty) .. ' HOME=' .. shquote(home),
                   '-S -FileType ' .. shquote(IMAGE))
    is('', err, 'EXIFTOOL_HOME takes precedence over HOME')
    is(fileType, out, 'EXIFTOOL_HOME: the command runs')

    out, err = run('-u EXIFTOOL_HOME HOME= HOMEDRIVE=' .. shquote(tmpDir) .. ' HOMEPATH=/home',
                   '-S -FileType ' .. shquote(IMAGE))
    is(SUPPORTED .. home .. '/.ExifTool_config\n', err, 'HOMEDRIVE . HOMEPATH when HOME is empty')
    is(fileType, out, 'HOMEDRIVE . HOMEPATH: the command runs')

    out, err = run(noHome .. ' HOME=' .. shquote(empty),
                   '-config ' .. shquote(tmpDir .. '/missing.config') .. ' -S -FileType ' .. shquote(IMAGE))
    is('Config file not found\n', err, '-config with a missing file warns as upstream')
    is(fileType, out, '-config with a missing file: the command runs')
end

--------------------------------------------------------------------------------
-- 2. -if with Perl syntax perl.eval does not interpret
--------------------------------------------------------------------------------
do
    local out, err = run('-u EXIFTOOL_HOME HOME=' .. shquote(tmpDir .. '/empty'),
                         [[-S -FileType -if 'local $x = 1; $FileType' ]] .. shquote(IMAGE))
    ok(err:find('^Condition: Perl syntax unsupported in lexiftool: local %(near "') ~= nil,
       '-if with unsupported Perl syntax is reported without -v: ' .. err)
    ok(out:find('1 files failed condition', 1, true) ~= nil, '-if with unsupported syntax fails the file')
end

--------------------------------------------------------------------------------
-- 3. -ver and -ver -v
--------------------------------------------------------------------------------
do
    local env = '-u EXIFTOOL_HOME HOME=' .. shquote(tmpDir .. '/empty')
    local out = run(env, '-ver')
    is('13.59\n', out, '-ver prints the upstream version alone')
    out = run(env, '-ver -v')
    -- the identity is whatever the launcher/build set as
    -- _G.LEXIFTOOL_PORT_VERSION, "Unknown" for this plain source checkout
    ok(out:find('\nlexiftool port Unknown, Lua 5%.%d+%.%d+, bytecode %a+\n') ~= nil,
       '-ver -v has the port line: ' .. (out:match('\n(lexiftool port[^\n]*)') or 'missing'))
    ok(out:find('\n  Compress::Zlib               compress%.zlib %S+ %(zlib [%d.]+%)\n') ~= nil,
       '-ver -v lists compress.zlib for Compress::Zlib')
    ok(out:find('\n  IO::Compress::Brotli         compress%.brotli %S+ %(libbrotli [%d.]+%)\n') ~= nil,
       '-ver -v lists compress.brotli for IO::Compress::Brotli')
    ok(out:find('\n  IO::Compress::Bzip2          compress%.bzip2 %S+ %(libbz2 [%d.]+%)\n') ~= nil,
       '-ver -v lists compress.bzip2 for IO::Compress::Bzip2')
    ok(out:find('\n  Compress::Raw::Lzma          compress%.lzma %S+ %(liblzma [%d.]+%)\n') ~= nil,
       '-ver -v lists compress.lzma for Compress::Raw::Lzma')
    if pcall(require, 'digest') then
        ok(out:find('\n  Digest::MD5                  digest %S+\n') ~= nil, '-ver -v lists digest for Digest::MD5')
        ok(out:find('\n  Digest::SHA                  digest %S+\n') ~= nil, '-ver -v lists digest for Digest::SHA')
    end
    ok(out:find('\n  Time::Piece                  lexiftool.perl', 1) ~= nil,
       '-ver -v lists the facade for POSIX::strptime/Time::Piece')
    ok(out:find('\n  Unicode::LineBreak           lexiftool.perl (GCString, Unicode-LineBreak ', 1, true) ~= nil,
       '-ver -v lists the facade for Unicode::LineBreak')
end

--------------------------------------------------------------------------------
-- 4. the launcher in a shell set up for another Lua version
--------------------------------------------------------------------------------
do
    -- a rock tree of "Lua 5.1" whose lpcre.so cannot be loaded, first in
    -- the unversioned LUA_CPATH, as `luarocks path` for 5.1 leaves it
    local foreign = tmpDir .. '/rocks/lib/lua/5.1'
    os.execute('mkdir -p ' .. shquote(foreign))
    writeFile(foreign .. '/lpcre.so', 'not a shared object')
    local cpath = foreign .. '/?.so;' .. (os.getenv('LUA_CPATH') or package.cpath)
    local env = '-u LUA_CPATH_5_4 -u LUA_CPATH_5_5 -u EXIFTOOL_HOME HOME=' .. shquote(tmpDir .. '/empty') ..
                ' LUA_CPATH=' .. shquote(cpath)
    local out, err = run(env, '-S -FileType ' .. shquote(IMAGE))
    is(fileType, out, 'the launcher skips another Lua version\'s rock tree: ' .. err:sub(1, 200))
end

--------------------------------------------------------------------------------
-- 5. the launcher prefers the source tree next to it over an installed copy
--------------------------------------------------------------------------------
do
    -- a lexiftool.main earlier in LUA_PATH (as a system or rock install
    -- would be); the script's own src/ must still win
    local installed = tmpDir .. '/installed'
    os.execute('mkdir -p ' .. shquote(installed .. '/lexiftool'))
    writeFile(installed .. '/lexiftool/main.lua',
              'return function() io.write("installed copy\n") end\n')
    local lpath = installed .. '/?.lua;' .. (os.getenv('LUA_PATH') or package.path)
    local env = '-u EXIFTOOL_HOME HOME=' .. shquote(tmpDir .. '/empty') ..
                ' LUA_PATH=' .. shquote(lpath)
    local out, err = run(env, '-S -FileType ' .. shquote(IMAGE))
    is(fileType, out, 'the launcher prefers its own source tree: ' .. err:sub(1, 200))
end

--------------------------------------------------------------------------------
-- 6. GeoLang/<lang>.lua before GeoLang/<lang>.pm
--------------------------------------------------------------------------------
do
    local images = TestLib.TEST_DIR .. '/images'
    local env = '-u EXIFTOOL_HOME HOME=' .. shquote(tmpDir .. '/empty')
    local function geo(geoDir, envExtra)
        return run(env .. (envExtra or ''), '-api GeoDir=' .. shquote(geoDir) ..
                   ' -api Geolocation=1 -lang ru -G1 "-Geolocation*" ' ..
                   shquote(TestLib.T_DIR .. '/images/Google.jpg'))
    end
    local function readFile(path)
        local fh = io.open(path, 'rb')
        local text = fh:read('a')
        fh:close()
        return text
    end
    -- the full extract as a .pm alone (golden case geolang-ru-pm)
    local fromPm = geo(images .. '/lex_Geolocation_GeoDirPm')
    ok(fromPm:find('Испания', 1, true) ~= nil, 'GeoLang/ru.pm alone is read: ' .. fromPm)

    -- lex_Geolocation_GeoDirLua: the full extract as ru.lua, a shorter ru.pm
    local out = geo(images .. '/lex_Geolocation_GeoDirLua')
    is(fromPm, out, 'GeoLang/ru.lua is taken before the ru.pm beside it')
    local onlyPm = tmpDir .. '/geo-pm'
    os.execute('mkdir -p ' .. shquote(onlyPm .. '/GeoLang'))
    writeFile(onlyPm .. '/GeoLang/ru.pm', readFile(images .. '/lex_Geolocation_GeoDirLua/GeoLang/ru.pm'))
    ok(geo(onlyPm) ~= fromPm, 'the ru.pm beside the ru.lua translates differently')

    -- a .pm along LUA_PATH (the counterpart of @INC), none in the GeoDir
    local lp = tmpDir .. '/geo-path'
    os.execute('mkdir -p ' .. shquote(lp .. '/GeoLang'))
    writeFile(lp .. '/GeoLang/ru.pm', readFile(images .. '/lex_Geolocation_GeoDirPm/GeoLang/ru.pm'))
    local noGeoLang = tmpDir .. '/geo-none'
    os.execute('mkdir -p ' .. shquote(noGeoLang))
    local lpath = lp .. '/?.lua;' .. (os.getenv('LUA_PATH') or package.path)
    is(fromPm, geo(noGeoLang, ' LUA_PATH=' .. shquote(lpath)), 'GeoLang/ru.pm along LUA_PATH is read')

    -- a .pm with a statement besides the table
    local bad = tmpDir .. '/geo-bad'
    os.execute('mkdir -p ' .. shquote(bad .. '/GeoLang'))
    writeFile(bad .. '/GeoLang/ru.pm', (readFile(images .. '/lex_Geolocation_GeoDirPm/GeoLang/ru.pm'):gsub(
              '\n1; #end\n', '\nprint "code";\n1; #end\n')))
    local untranslated = geo(noGeoLang)
    local err
    out, err = geo(bad)
    is(untranslated, out, 'a .pm that is not a pure data table gives no translations')
    ok(err:find('GeoLang file not supported by lexiftool (Perl code, not a pure data table): ' ..
                bad .. '/GeoLang/ru.pm\n', 1, true) ~= nil, 'and warns with its file name: ' .. err)
end

os.execute('rm -rf ' .. shquote(tmpDir))
