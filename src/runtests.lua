--------------------------------------------------------------------------------
-- File:         runtests.lua
--
-- Description:  lexiftool test runner
--------------------------------------------------------------------------------

-- Searches for and executes the per-suite test scripts in
--   <LEXIFTOOL_REPO_DIR>/src/test/
--
-- The repository root is resolved by src/test/TestLib.lua (TestLib.REPO_DIR):
-- a caller-set global LEXIFTOOL_REPO_DIR wins, otherwise TestLib walks up the
-- filesystem from its own module directory until "vendor/exiftool/t" is found.
-- The runner therefore makes no assumptions about the current working
-- directory and never touches environment variables or package.path (which is
-- supplied by the caller, e.g. the Makefile). It does set the process's C
-- locale (see LEXIFTOOL_TEST_LOCALE below).

-- The modules are looked up via the externally supplied package.path.
local TestLib = require('test.TestLib')
TestLib.setRunner(true)

local dir = arg[1] or TestLib.TEST_DIR

-- The library must not depend on the process's C locale (doc/conventions.md
-- §3a: numbers print with '.', strings sort as bytes, whatever an embedding
-- host has set). So the suite runs under a locale with a decimal comma and a
-- collation of its own, which makes every place that formats or sorts past
-- the perl facade fail. The test-only global LEXIFTOOL_TEST_LOCALE (never
-- read by the library) names the locale, or a comma-separated list of
-- candidates of which the first one os.setlocale accepts wins; 'C' turns it
-- off. Default: the German locale under its glibc/macOS, its short and its
-- Windows CRT names. Set before each test file is loaded (a test may change
-- the locale itself). When none is accepted the run warns and goes on under
-- "C", unless the test-only global LEXIFTOOL_TEST_LOCALE_REQUIRED is set
-- (CI): then it stops with exit status 1.
-- Under Windows the single-byte code page comes first: cp1252 makes 0xE4 a
-- letter for Lua's pattern classes and string.lower/upper, which a UTF-8
-- locale does not, so the CI's Windows run covers the LC_CTYPE case too
-- (Linux and macOS take the UTF-8 locale; `make test-locales` adds
-- ISO-8859-15).
local LOCALE_CANDIDATES = package.config:sub(1, 1) == '\\'
    and 'German_Germany.1252,de-DE,de_DE.UTF-8'
    or 'de_DE.UTF-8,de_DE.utf8,de-DE,German_Germany.1252'
local testLocale = 'C'
do
    local want = rawget(_G, 'LEXIFTOOL_TEST_LOCALE')
    if want == nil or want == '' then want = LOCALE_CANDIDATES end
    for item in tostring(want):gmatch('[^,]+') do
        local name = item:match('^%s*(.-)%s*$')
        if name == 'C' or os.setlocale(name) then
            testLocale = name
            break
        end
    end
    os.setlocale('C')
    if testLocale == 'C' and want ~= 'C' then
        -- (LEXIFTOOL_TEST_LOCALE_REQUIRED, set by CI: no silent fallback)
        local required = rawget(_G, 'LEXIFTOOL_TEST_LOCALE_REQUIRED')
        if required ~= nil and required ~= '' and required ~= '0' and required ~= false then
            io.stderr:write('runtests.lua: none of the test locales (' .. want .. ') is available '
                .. 'and LEXIFTOOL_TEST_LOCALE_REQUIRED is set -- install one or set the list\n')
            os.exit(1)
        end
        print(':: WARNING: none of the test locales (' .. want .. ') is available, '
            .. 'running under "C" -- formatting and sorting past the perl facade go unnoticed')
    end
    print(':: test locale: ' .. testLocale)
end

local files = {}

-- (LuaFileSystem when present -- io.popen would go through cmd.exe on
--  Windows, which has no find(1); the shell pipeline remains the fallback)
local okLfs, lfs = pcall(require, 'lfs')
if okLfs and lfs.dir then
    for name in lfs.dir(dir) do
        if name:match('^test_.*%.lua$') then files[#files + 1] = dir .. '/' .. name end
    end
    table.sort(files)
else
    local pipe = io.popen("find '" .. dir .. "' -maxdepth 1 -name 'test_*.lua' | sort")
    if pipe then
        for line in pipe:lines() do
            files[#files + 1] = line
        end
        pipe:close()
    end
end

if #files == 0 then
    io.stderr:write('runtests.lua: no test files found in ' .. dir .. '\n')
    os.exit(1)
end

for i = 1, #files do
    local file = files[i]
    -- each upstream t/*.t runs in a Perl process of its own, so tag tables
    -- that the library edits in place (GetAddDirHash names SubDirectories,
    -- GetTagTable adds tags, ...) start fresh for every test family; unload
    -- the library modules so the next test file loads them anew
    for name in pairs(package.loaded) do
        if name == 'lexiftool' or name:match('^lexiftool%.') then package.loaded[name] = nil end
    end
    os.setlocale(testLocale)
    TestLib.setCurrentFile(file:match('[^/]+$'))
    local f, err = loadfile(file)
    if f then
        local ok, e = pcall(f)
        if not ok then
            TestLib.ok(false, 'execute error: ' .. tostring(e))
        end
    else
        TestLib.ok(false, 'load error: ' .. tostring(err))
    end
end

print((':: %d test(s), %d failed'):format(TestLib.total, TestLib.failed))
os.exit(TestLib.failed > 0 and 1 or 0)