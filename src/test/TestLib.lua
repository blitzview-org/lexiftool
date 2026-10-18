--------------------------------------------------------------------------------
-- File:         test/TestLib.lua
-- Ported from:  t/TestLib.pm
--
-- Description:  Utility routines for testing lexiftool modules
--
-- Revisions:    carried over from t/TestLib.pm for structural parity
--               Feb. 19/04 - P. Harvey Created
--               Feb. 26/04 - P. Harvey Name temporary file ".failed" and erase
--                            it if the test passes
--               Feb. 27/04 - P. Harvey Change print format and allow ExifTool
--                            object to be passed instead of tags hash ref.
--               Oct. 30/04 - P. Harvey Split testCompare() into separate sub.
--               May  18/05 - P. Harvey Tolerate round-off errors in floats.
--               Feb. 02/08 - P. Harvey Allow different timezones in time values
--               Sep. 16/08 - P. Harvey Improve timezone testing
--               Jul. 14/10 - P. Harvey Added writeInfo()
--               Jan. 06/12 - P. Harvey Patched MirBSD leap second "feature"
--               Jun. 08/21 - PH Patched float compare to fix quadmath test failure
--
-- Port notes:   mirror of upstream t/TestLib.pm; the repository root is
--               resolved by walking up until vendor/exiftool/t is found and
--               published as REPO_DIR / TEST_DIR / T_DIR.
--------------------------------------------------------------------------------

-- This is harness code and the single place that resolves the repository root
-- (published as TestLib.REPO_DIR / TEST_DIR / T_DIR). Resolution:
--   1. the caller-stated global _G.LEXIFTOOL_REPO_DIR
--      (`lua -e "LEXIFTOOL_REPO_DIR=..."`) wins when present;
--   2. otherwise the root is located by walking up the filesystem from this
--      module's own directory until a directory containing "vendor/exiftool/t"
--      is found. When the optional lfs module is available the module path is
--      first made absolute (lfs.realpath), which also makes the walk survive an
--      unusual current working directory; without lfs the walk starts from the
--      module path as given (relative to the cwd) and stopping at a directory
--      with "vendor/exiftool/t" is the pure-Lua fallback marker.
-- No environment variables are read, no cwd is assumed, and no package.path is
-- touched here. Module lookup is provided externally (see the Makefile).

local luatable = table
local lexiftool = require('lexiftool')
-- (Perl's stringification and byte-order sort: the suite runs under a
--  locale with a decimal comma and a collation of its own, see runtests.lua)
local perl = require('lexiftool.perl')

local TestLib = {}
TestLib.VERSION = '1.25'

-- Documented platform divergences from t/TestLib.pm:
--   * this is a read-only harness (writeInfo/writeCheck exist for parity but
--     require future write support);
--   * Digest::MD5 is available via the `digest` rock, so the zero-digest
--     IPTCDigest tolerance below is a fallback, not the normal case;
--   * the FileCreateDate tolerance follows the host OS (it is Linux-only, as
--     upstream's `$^O ne 'linux'`); the MirBSD leap-second workaround is
--     wired to a constant below;
--   * Time::Local is always available (via lexiftool.GetUnixTime), so the
--     "ignore times if Time::Local is not installed" branch never fires.
local HAS_MD5 = true
-- (Linux is the only Unix among the targets where FileCreateDate is optional;
--  on Windows and macOS the tag is always there, as upstream expects)
local OS_IS_LINUX = package.config:sub(1, 1) == '/' and (function()
    -- (no shell: a child process is not always welcome where the tests run;
    --  the plist exists on every macOS and nowhere else)
    local f = io.open('/System/Library/CoreServices/SystemVersion.plist', 'rb')
    if f then f:close() return false end
    return true
end)()
local OS_IS_MIRBSD = false
local HAS_TIME_LOCAL = true

local rtnCode = 0

--------------------------------------------------------------------------------
-- Resolve the repository root.
-- Returns the path of this module's directory. The loader reports the module
-- path relative to the current directory; when lfs is present it is made
-- absolute by prefixing the current directory, so the walk below is immune to
-- odd invocation directories. Without lfs the relative (or already absolute)
-- path is used as given - walking up still finds the marker when the process
-- was started from a directory below the repository root.
--------------------------------------------------------------------------------
local function moduleDir()
    local source = debug.getinfo(1, 'S').source
    if source:sub(1, 1) == '@' then source = source:sub(2) end
    local ok, lfs = pcall(require, 'lfs')
    if ok and source:sub(1, 1) ~= '/' then
        local cwd = lfs.currentdir()
        if cwd then
            source = source:gsub('^%./', '')
            return cwd .. '/' .. source
        end
    end
    return source or '.'
end

-- Walk up towards the root until a repository root is found (a directory that
-- contains "vendor/exiftool/t"). The search ends at the filesystem root.
local function walkUp(startDir)
    local repoDir = startDir
    while true do
        local marker = repoDir .. '/vendor/exiftool/t/ExifTool.t'
        local m = io.open(marker, 'r')
        if m then
            m:close()
            return repoDir
        end
        local parent = repoDir:match('^(.*)/[^/]+$')
        if not parent then
            -- a single trailing segment (e.g. a bare 'src/test' path): step to '.'
            if repoDir:find('/') then
                parent = '.'
            else
                -- absolute path at the filesystem root, or a '.' path with no marker:
                -- give up and report the module directory so the error is descriptive.
                return repoDir
            end
        end
        repoDir = parent
    end
end

local REPO_DIR = _G.LEXIFTOOL_REPO_DIR or walkUp(moduleDir())
TestLib.REPO_DIR = REPO_DIR
TestLib.TEST_DIR = REPO_DIR .. '/src/test'
TestLib.T_DIR = REPO_DIR .. '/vendor/exiftool/t'

-- The Lua interpreter running the suite, for tests that start a child
-- process: the lowest negative index of the standalone interpreter's arg
-- table (arg[-1] is an option's value when the runner is started with
-- `lua -e "..." src/runtests.lua`), nil when not run by the interpreter.
do
    local i = 0
    while arg and arg[i - 1] ~= nil do i = i - 1 end
    TestLib.LUA = i < 0 and arg[i] or nil
end

local TEST_DIR = TestLib.TEST_DIR
local T_DIR = TestLib.T_DIR

-- Assertion state (shared across all test files when run by the runner; the
-- runner reads TestLib.total/TestLib.failed after executing all files).
TestLib.total, TestLib.failed = 0, 0
local currentFile = nil
local running = false -- true while executed under src/runtests.lua

function TestLib.setRunner(r)
    running = r and true or false
end

--------------------------------------------------------------------------------
-- Report one assertion result. In runner mode counting/output is handled here
-- and the runner reads TestLib.total/TestLib.failed at the end; standalone the
-- runner is absent and done() exits with the failure status.
--------------------------------------------------------------------------------
local function printOk(cond, name)
    TestLib.total = TestLib.total + 1
    local prefix = currentFile and (currentFile .. ': ') or ''
    if cond then
        io.write(('ok %d - %s%s\n'):format(TestLib.total, prefix, name))
    else
        TestLib.failed = TestLib.failed + 1
        if rtnCode ~= 1 then rtnCode = 1 end
        io.write(('not ok %d - %s%s\n'):format(TestLib.total, prefix, name))
    end
end

-------------------------------------------------------------------------------
-- Assertion interface made available to the test scripts
-- (Perl TestLib.pm prints bare `ok $testnum` itself; here the numbering is
-- centralised so the runner and standalone modes behave identically).
-------------------------------------------------------------------------------
function TestLib.ok(cond, name)
    printOk(cond and true or false, name or 'ok')
end

function TestLib.is(exp, got, name)
    printOk(exp == got,
        (name or 'is') .. (' (expected %s, got %s)'):format(tostring(exp), tostring(got)))
end

function TestLib.err(fn, name)
    local ok = pcall(fn)
    printOk(not ok, name or 'error expected')
end

-------------------------------------------------------------------------------
-- Runner hooks (used by src/runtests.lua)
-------------------------------------------------------------------------------
function TestLib.setRunner(r)
    running = r and true or false
end

function TestLib.setCurrentFile(name)
    currentFile = name
    -- (the runner unloads the library before each test file, as each upstream
    --  t/*.t runs in a Perl process of its own -- pick up the fresh instance)
    lexiftool = require('lexiftool')
    perl = require('lexiftool.perl')
end

-- Forward declarations (Lua analogue of the Perl `sub nearEnough($$);`
-- prototype declarations).
local nearEnough
local nearTime
local formatValue

--------------------------------------------------------------------------------
-- Compare 2 binary files
-- Inputs: 0) file name 1, 1) file name 2
-- Returns: 1 if files are identical
--------------------------------------------------------------------------------
function TestLib.binaryCompare(file1, file2)
    local f1 = io.open(file1, 'rb')
    if not f1 then return 0 end
    local f2 = io.open(file2, 'rb')
    if not f2 then
        f1:close()
        return 0
    end
    local success = true
    local buf1, buf2
    while true do
        buf1 = f1:read(65536)
        if not buf1 then break end
        buf2 = f2:read(65536)
        if not buf2 then
            success = false
            break
        end
        if buf1 ~= buf2 then
            success = false
            break
        end
    end
    if success then
        buf2 = f2:read(65536)
        if buf2 then success = false end
    end
    f1:close()
    f2:close()
    return success and 1 or 0
end

--------------------------------------------------------------------------------
-- Compare 2 files and return true and erase the 2nd file if they are the same
-- Inputs: 0) file1, 1) file2, 2) test number, 3) flag to not erase test file
-- Returns: true if files are the same
--------------------------------------------------------------------------------
function TestLib.testCompare(stdFile, testFile, testnum, keep)
    local success = false
    local line1, line2
    local f1 = io.open(stdFile, 'rb')
    if f1 then
        local f2 = io.open(testFile, 'rb')
        if f2 then
            success = true
            local linenum = 0
            local retry = 0
            while true do
                if retry ~= 1 and retry ~= 3 then line1 = f1:read('l') end
                if line1 == nil then break end
                linenum = linenum + 1
                if retry ~= 2 and retry ~= 3 then line2 = f2:read('l') end
                retry = 0
                if line2 ~= nil then
                    if line1 == line2 then
                        goto nextline
                    elseif nearEnough(line1, line2) then
                        goto nextline
                    elseif os.getenv('LEXIFTOOL_TEST_DEBUG') then
                        io.stderr:write('MISMATCH line ' .. linenum .. ':\n  std:  ' .. tostring(line1) .. '\n  test: ' .. tostring(line2) .. '\n')
                    -- ignore IPTCDigest warning if Digest::MD5 isn't available
                    elseif line1:find('Warning: IPTCDigest is not current', 1, true) and not HAS_MD5 then
                        retry = 2
                        goto nextline
                    elseif line2:find('Warning: IPTCDigest is not current', 1, true) and not HAS_MD5 then
                        retry = 1
                        goto nextline
                    -- FileCreateDate may be extracted on Linux if File::StatX is available
                    -- (so a line the .out does not have is skipped there only)
                    elseif OS_IS_LINUX and line1:match('File%s?Creat.*Date') then
                        if not line2:match('File%s?Creat.*Date') then
                            retry = 2
                            goto nextline
                        end
                    elseif line2:match('File%s?Creat.*Date') then
                        retry = 1
                        goto nextline
                    -- Composite tag build order (dependency-pass timing) differs
                    -- from upstream's global merged-table order; compare this
                    -- contiguous run as a sorted set instead of line-for-line
                    -- The run is every line in group family 0 'Composite',
                    -- whatever its family 1 is: a module that brings its own
                    -- Composite table (FLIR, Nikon, ...) lands in the middle
                    -- of the others, and which side of it a tag falls on is
                    -- exactly the ordering this rung exists to ignore.
                    elseif line1:match('^%[Composite,') and line2:match('^%[Composite,') then
                        local block1, block2 = { line1 }, { line2 }
                        local next1 = f1:read('l')
                        while next1 and next1:match('^%[Composite,') do
                            block1[#block1 + 1] = next1
                            next1 = f1:read('l')
                        end
                        local next2 = f2:read('l')
                        while next2 and next2:match('^%[Composite,') do
                            block2[#block2 + 1] = next2
                            next2 = f2:read('l')
                        end
                        perl.tsort(block1)
                        perl.tsort(block2)
                        local blockOk = #block1 == #block2
                        if blockOk then
                            for bi = 1, #block1 do
                                if block1[bi] ~= block2[bi] and not nearEnough(block1[bi], block2[bi]) then
                                    blockOk = false
                                    break
                                end
                            end
                        end
                        if blockOk then
                            line1, line2 = next1, next2
                            retry = 3
                            goto nextline
                        end
                    end
                end
                success = false
                break
                ::nextline::
            end
            if success then
                -- make sure there is nothing left in file2
                line2 = f2:read('l')
                if line2 then
                    linenum = linenum + 1
                    success = false
                end
            end
            if not success then
                io.stderr:write('\n  Test ')
                io.stderr:write(tostring(testnum))
                io.stderr:write(' differs beginning at line ')
                io.stderr:write(tostring(linenum))
                io.stderr:write(':\n')
                if line1 == nil then line1 = '(null)' end
                if line2 == nil then line2 = '(null)' end
                line1 = line1:gsub('[\r\n]+$', '')
                line2 = line2:gsub('[\r\n]+$', '')
                io.stderr:write('    Test gave: "' .. tostring(line2) .. '"\n')
                io.stderr:write('    Should be: "' .. tostring(line1) .. '"\n')
            end
            f2:close()
        end
        f1:close()
    end

    -- erase .failed file if test was successful
    if success and not keep then
        os.remove(testFile)
    end

    return success
end

--------------------------------------------------------------------------------
-- Return true if two test lines are close enough
-- Inputs: 0) line1, 1) line2
-- Returns: true if lines are similar enough to pass test
--------------------------------------------------------------------------------
nearEnough = function(line1, line2)
    -- of course, the version number will change...
    -- ($Image::ExifTool::VERSION and ::RELEASE are exported on the module)
    local s = line1:find('ExifTool', 1, true)
    if s then
        local from = s + 8
        while true do
            -- look for a version number \b\d{1,2}\.\d{2}\b after the ExifTool token
            local vs, ve = line1:find('%d%d?%.%d%d', from)
            if not vs then break end
            local good = true
            if vs > 1 and line1:sub(vs - 1, vs - 1):match('%w') then good = false end
            if good and ve < #line1 and line1:sub(ve + 1, ve + 1):match('%w') then good = false end
            if good then
                local prefix = line1:sub(1, vs - 1)
                local suffix = line1:sub(ve + 1)
                if line2 == prefix .. lexiftool.VERSION .. lexiftool.RELEASE .. suffix or
                      line2 == prefix .. lexiftool.VERSION .. suffix then
                    return true
                end
            end
            from = ve + 1
        end
    end

  -- allow different FileModifyDate, FileAccessDate, FileCreateDate/FileInodeChangeDate
  -- and FilePermissions (note that FileInodeChangeDate is FileCreateDate on Windows,
  -- and FileCreateDate may or may not be extracted on Linux)
  -- (Lua patterns have no alternation operator, so the upstream regex
  --  File\s?(Modif.*Date|Access\s?Date|Inode\s?Change\s?Date|Permissions)
  --  is checked one alternative at a time)
  local m = line1:match('File%s?Modif.*Date')
    or line1:match('File%s?Access%s?Date')
    or line1:match('File%s?Inode%s?Change%s?Date')
    or line1:match('File%s?Permissions')
  if m then
    if line2:find(m, 1, true) then
      return true
    end
    if not OS_IS_LINUX and line2:match('File%s?Creat.*Date') then
      return true
    end
  end

  -- allow Directory to differ: the value is the invocation path, so it only
  -- matches the upstream `.out` if the tests run from the same directory
  -- (handles the check() format `Directory - Directory: path`, the
  --  verbose-format `  Directory = path`, and the no-et check() format
  --  `Directory: path` used by tests that call check() without an
  --  ExifTool ref, e.g. Writer.t, and the `Directory : path` lines that
  --  ExifTool.t test 16 prints itself)
  if (line1:match('Directory %- Directory: ') and
      line2:match('Directory %- Directory: ')) or
     (line1:match('^%s*Directory = ') and line2:match('^%s*Directory = ')) or
     (line1:match('^Directory: ') and line2:match('^Directory: ')) or
     (line1:match('^Directory : ') and line2:match('^Directory : ')) then
    return true
  end

    -- allow CurrentIPTCDigest to be zero if Digest::MD5 isn't installed
    if line1:find('Current IPTC Digest', 1, true) then
        local digest = line2:match('Current IPTC Digest: ([0#]+)')
        if digest and #digest >= 32 and not HAS_MD5 then
            return true
        end
    end

    -- analyze every token in the line, and allow rounding
    -- or format differences in floating point numbers
    local toks1 = {}
    for t in line1:gmatch('%S+') do toks1[#toks1 + 1] = t end
    local toks2 = {}
    for t in line2:gmatch('%S+') do toks2[#toks2 + 1] = t end
    local lenChanged = false
    local idx = 0
    while true do
        if idx >= #toks1 and idx >= #toks2 then return true end -- all tokens were OK
        local tok1 = toks1[idx + 1]
        local tok2 = toks2[idx + 1]
        if not (tok1 and tok2) then break end
        local viaNext = false
        local advance = 1
        if tok1 == tok2 then
            -- matched exactly (a "next" in the Perl original: lenChanged not checked)
            viaNext = true
        else
            -- can't compare any more if either line was truncated (ie. ends with '[...]' or '[snip]')
            -- (Lua patterns have no alternation operator, so the upstream
            --  regex /\[(\.\.\.|snip)\]$/ is checked as two separate patterns)
            local function isTruncated(tok) return tok:match('%[%.%.%.%]$') or tok:match('%[snip%]$') end
            if isTruncated(tok1) or isTruncated(tok2) then
                if tok1:match('^[-+]?%d+%.') or tok2:match('^[-+]?%d+%.') then return true end -- check for float
                return lenChanged
            end
            if tok1:match('^%d%d:%d%d:%d%d') and tok2:match('^%d%d:%d%d:%d%d') and not HAS_TIME_LOCAL then
                -- (times are ignored if Time::Local is not installed, but it always is here)
                viaNext = true
            else
                -- (Lua patterns have no alternation operator, so the upstream
                --  regex /^(\d{2}:\d{2}:\d{2}(\.\d*)?)(Z|[-+]\d{2}:\d{2})$/ is
                --  checked as two separate patterns: a literal Z/z suffix, or
                --  a numeric +HH:MM/-HH:MM offset suffix)
                local function matchTimeTok(tok)
                    local t, tz = tok:match('^(%d%d:%d%d:%d%d%.?%d*)([Zz])$')
                    if t then return t, tz end
                    return tok:match('^(%d%d:%d%d:%d%d%.?%d*)([-+]%d%d:%d%d)$')
                end
                local time1 = matchTimeTok(tok1)
                if time1 then
                    -- account for different timezones
                    local time2 = matchTimeTok(tok2)
                    if time2 and time1 == time2 then
                        -- timezone may be wrong if writing date/time value in a different timezone
                        viaNext = true
                    else
                        -- date/time may be wrong too if converting GMT value to local time
                        local datPat = '^%d%d%d%d:%d%d:%d%d$'
                        if not (idx > 0 and toks1[idx]:match(datPat) and toks2[idx]:match(datPat)) then
                            break
                        end
                        local dt1 = toks1[idx] .. ' ' .. tok1 -- add date to give date/time value
                        local dt2 = toks2[idx] .. ' ' .. tok2
                        if not nearTime(dt1, dt2, line1, line2) then break end
                    end
                    -- date may be different if timezone shifted into next day
                elseif tok1:match('^%d%d%d%d:%d%d:%d%d$') and tok2:match('^%d%d%d%d:%d%d:%d%d$') and
                        toks1[idx + 2] and toks2[idx + 2] and
                        matchTimeTok(toks1[idx + 2]) and
                        matchTimeTok(toks2[idx + 2]) then
                    advance = 2
                    tok1 = tok1 .. ' ' .. toks1[idx + 2] -- add time to give date/time value
                    tok2 = tok2 .. ' ' .. toks2[idx + 2]
                    if not nearTime(tok1, tok2, line1, line2) then break end
                else
                    -- handle floating point numbers filtered by ExifTool test 29
                    -- ($tok1 =~ s/(\.#)#*(e[-+]\#+)?/$1/g or $tok2 =~ s/(\.#)#*(e[-+]\#+)?/$1/g
                    --  then $tok2 =~ s/(\.#)#*(e[-+]\#+)?/$1/g; last if $tok1 ne $tok2)
                    local h1, c1 = tok1:gsub('(%.%#)%#*(e[-+]%#+)?', '%1')
                    local h2, c2 = tok2:gsub('(%.%#)%#*(e[-+]%#+)?', '%1')
                    if c1 > 0 or c2 > 0 then
                        tok1, tok2 = h1, h2
                        if tok1 ~= tok2 then break end
                    else
                        -- check to see if both tokens are floating point numbers (with decimal points!)
                        local unit = tok1:match('([^%d%.]+)$')
                        if unit then -- remove trailing units
                            tok1 = tok1:sub(1, #tok1 - #unit)
                            if tok2:sub(-#unit) ~= unit then break end
                            tok2 = tok2:sub(1, #tok2 - #unit)
                        end
                        local hhmm = tok1:match('^(%d+:%d+:)')
                        if hhmm then -- remove leading HH:MM:
                            tok1 = tok1:sub(#hhmm + 1)
                            if tok2:sub(1, #hhmm) ~= hhmm then break end
                            tok2 = tok2:sub(#hhmm + 1)
                        end
                        if tok1:sub(1, 1) == "'" then -- remove leading quote
                            tok1 = tok1:sub(2)
                            if tok2:sub(1, 1) ~= "'" then break end
                            tok2 = tok2:sub(2)
                        end
                        if not (lexiftool.IsFloat(tok1) and lexiftool.IsFloat(tok2)) then break end
                        local n1 = tonumber(tok1)
                        local n2 = tonumber(tok2)
                        if n1 == 0 or n2 == 0 then break end
                        -- numbers are bad if not the same to 5 significant figures
                        if math.abs((n1 - n2) / (n1 + n2)) > 1e-5 then
                            -- (but allow last digit to be different due to round-off errors)
                            local int1 = tok1:gsub('%D', '')
                            local int2 = tok2:gsub('%D', '')
                            local dlen = #int1 - #int2
                            if dlen > 0 then
                                int2 = int2 .. string.rep('0', dlen)
                            elseif dlen < 0 then
                                int1 = int1 .. string.rep('0', -dlen)
                            end
                            if math.abs((tonumber(int1) or 0) - (tonumber(int2) or 0)) > 1.00001 then break end
                        end
                    end
                end
            end
        end
        -- set flag if length changed
        if not viaNext and #tok1 ~= #tok2 then lenChanged = true end
        idx = idx + advance
    end
    return false
end

--------------------------------------------------------------------------------
-- Check two time strings to see if they are the same
-- Inputs: 0) time1, 1) time2, 2) line1, 3) line2
-- Returns: true on success
--------------------------------------------------------------------------------
nearTime = function(tok1, tok2, line1, line2)
    local t1 = lexiftool.GetUnixTime(tok1, 'local')
    if t1 == nil or t1 == 0 then return false end
    local t2 = lexiftool.GetUnixTime(tok2, 'local')
    if t2 == nil or t2 == 0 then return false end
    local td = t2 - t1
    if math.abs(td) > 0.0001 then -- (allow for round-off errors in fractional seconds)
        -- patch for the MirBSD leap-second unconformity
        -- (120 leap seconds should cover us until _well_ into the future)
        if not (OS_IS_MIRBSD and td < 0 and td > -120) then
            return false
        end
        io.stderr:write('\n  Ignoring ' .. tostring(td) .. ' second error due to MirBSD leap-second "feature":\n')
        io.stderr:write('    Test gave: "' .. tostring(line2) .. '"\n')
        io.stderr:write('    Should be: "' .. tostring(line1) .. '"\n')
    end
    return true
end

--------------------------------------------------------------------------------
-- Format value for printing
-- Inputs: 0) value
-- Returns: string for printing
--------------------------------------------------------------------------------
formatValue = function(val)
    local t = type(val)
    local str
    if t == 'table' then
        -- (a Perl SCALAR ref is represented by a lexiftool binary value; a
        --  2-element {ref='SCALAR', value=...} tuple - see the binary value model)
        if val.ref == 'SCALAR' then
            local bin = perl.str(val.value)
            if bin:match('^Binary data') then
                str = '(' .. bin .. ')'
            else
                str = '(Binary data ' .. #bin .. ' bytes)'
            end
        elseif val[1] ~= nil then
            -- ARRAY
            local a = {}
            for i = 1, #val do
                a[#a + 1] = formatValue(val[i])
            end
            str = '[' .. luatable.concat(a, ',') .. ']'
        else
            -- HASH
            local a = {}
            local keys = lexiftool.OrderedKeys(val)
            for i = 1, #keys do
                local key = keys[i]
                a[#a + 1] = key .. '=' .. formatValue(val[key])
            end
            str = '{' .. luatable.concat(a, ',') .. '}'
        end
    elseif t == 'string' or t == 'number' then
        -- make sure there are no linefeeds in output
        str = perl.str(val):gsub('[\013\010]', ';')
        -- translate unknown characters
        -- (the \x80-\xff line is commented out in the original, as here)
        str = str:gsub('[\001-\031\127]', '.')
        -- remove NULL chars
        str = str:gsub('\0', '')
    else
        str = ''
    end
    return str
end
-- (formatValue stays module-private in Perl; exposed for parity with the
--  future value model.)
TestLib.formatValue = formatValue

--------------------------------------------------------------------------------
-- Compare extracted information against a standard output file
-- Inputs: 0) [optional] ExifTool object reference
--         1) tag hash reference, 2) test name, 3) test number
--         4) test number for comparison file (if different than this test)
--         5) top group number to test (2 by default)
-- Returns: 1 if check passed
--------------------------------------------------------------------------------
-- Test verbose output (mirror of upstream TestLib testVerbose): captures the
-- -vN ImageInfo output written to TextOut into a file, normalizes newlines,
-- and compares against the vendored .out via testCompare.
-- Inputs: 0) test name, 1) test number, 2) input file, 3) verbose level
-- Returns: true if test passed
function TestLib.testVerbose(testname, testnum, infile, verbose)
    local testfile = T_DIR .. '/' .. testname .. '_' .. testnum
    local tmpname = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '.tmp'
    local failedname = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '.failed'
    local fh = io.open(tmpname, 'w')
    if not fh then return false end
    local exifTool = lexiftool.new()
    exifTool:Options('Verbose', verbose, 'TextOut', fh)
    exifTool:ImageInfo(infile)
    fh:close()
    -- re-write output file to change newlines to be same as standard test file
    local inH = io.open(tmpname, 'rb')
    local data = inH and inH:read('*a') or ''
    if inH then inH:close() end
    data = data:gsub('\r\n', '\n')
    -- 'wb': a text-mode write on Windows would turn the '\n' the gsub just
    -- normalized to right back into '\r\n'
    local outH = io.open(failedname, 'wb')
    outH:write(data)
    outH:close()
    os.remove(tmpname)
    return TestLib.testCompare(testfile .. '.out', failedname, testnum)
end

function TestLib.check(et, info, testname, testnum, stdnum, topGroup)
    if not info then return false end
    stdnum = stdnum or testnum
    topGroup = topGroup or 2
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '.failed'
    local stdfile = T_DIR .. '/' .. testname .. '_' .. stdnum .. '.out'
    -- 'wb': a text-mode write on Windows would turn every '\n' below into
    -- '\r\n', which testCompare's 'rb' + read('l') would then never match
    -- against the vendored .out's bare '\n' (format 'l' strips only the
    -- final '\n', leaving the '\r' in the line)
    local fh = io.open(testfile, 'wb')
    if not fh then return false end

    -- get a list of found tags
    local tags
    if et then
        if et.NO_SORT then
            tags = et:GetFoundTags()
        else
            -- sort tags by group to make it a bit prettier
            tags = et:GetTagList(info, 'Group0')
        end
    else
        tags = {}
        for tag in pairs(info) do
            tags[#tags + 1] = tag
        end
        perl.tsort(tags)
    end

    -- Write information to file (with filename "TESTNAME_#.failed"), one
    -- "\x0a"-terminated line per tag
    for i = 1, #tags do
        local tag = tags[i]
        local val = formatValue(info[tag])
        if et then
            local groups = et:GetGroups(tag)
            local g = {}
            for n = 0, topGroup do
                g[#g + 1] = groups and groups[n] or ''
            end
            local tagID = et:GetTagID(tag)
            if tagID then
                tagID = perl.str(tagID):gsub('([\000-\031\127-\255])', function(c)
                    return string.format('\\x%.2x', c:byte())
                end)
            end
            local desc = et:GetDescription(tag)
            -- Perl string interpolation of an undef TagID silently produces
            -- '' (e.g. dynamically-created ExifTool::Extra tags like Make/
            -- Model set via a bare FoundTag('Make', ...) call, which have no
            -- TagID); perl.str(nil) does the same.
            local line = '[' .. luatable.concat(g, ', ') .. '] ' .. perl.str(tagID) ..
                ' - ' .. perl.str(desc) .. ': ' .. val .. '\n'
            fh:write(line)
        else
            fh:write(perl.str(tag) .. ': ' .. val .. '\n')
        end
    end
    fh:close()

    -- Compare the output file to the output from the standard test (TESTNAME_#.out)
    return TestLib.testCompare(stdfile, testfile, testnum)
end

--------------------------------------------------------------------------------
-- Test writing feature by writing specified information to JPEG file
-- Inputs: 0) list reference to lists of SetNewValue arguments
--         1) test name, 2) test number, 3) optional source file name,
--         4) true to only check tags which were written (or list ref for tags to check)
--         5) flag set if nothing is expected to change in the output file
--         6) true to ignore warnings
-- Returns: 1 if check passed
--------------------------------------------------------------------------------
function TestLib.writeCheck(writeInfo, testname, testnum, srcfile, onlyWritten, same, ignore)
    srcfile = srcfile or (T_DIR .. '/images/' .. testname .. '.jpg')
    local ext = srcfile:match('%.([^%.]+)$')
    local testfile = TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.' .. ext
    local et = lexiftool.new()
    local tags = {}
    if type(onlyWritten) == 'table' then
        for i = 1, #onlyWritten do
            tags[#tags + 1] = onlyWritten[i]
        end
        onlyWritten = nil
    end
    for i = 1, #writeInfo do
        -- (an entry carries `n` when its value is nil, Perl's undef in the list)
        et:SetNewValue(luatable.unpack(writeInfo[i], 1, writeInfo[i].n or #writeInfo[i]))
        if onlyWritten then
            tags[#tags + 1] = writeInfo[i][1]
        end
    end
    os.remove(testfile)
    local ok = TestLib.writeInfo(et, srcfile, testfile, same, ignore)
    local info = et:ImageInfo(testfile, { Duplicates = 1, Unknown = 1 }, tags)
    local rtnVal = TestLib.check(et, info, testname, testnum)
    if not (ok and rtnVal) then return false end
    os.remove(testfile)
    return true
end

--------------------------------------------------------------------------------
-- Call Image::ExifTool::WriteInfo with error checking
-- Inputs: 0) ExifTool ref, 1) src file, 2) dst file, 3) true if nothing should change
--         4) true to ignore warnings
-- Return: true on success
--------------------------------------------------------------------------------
function TestLib.writeInfo(et, src, dst, same, ignore)
    -- erase temporary file created by WriteInfo() if no destination file is given
    -- (may be left over from previous crashed tests)
    if not dst and type(src) == 'string' then
        os.remove(src .. '_exiftool_tmp')
    end
    local result = et:WriteInfo(src, dst)
    local err = ''
    if result ~= (same and 2 or 1) then
        err = err .. '  Error: WriteInfo() returned ' .. tostring(result) .. '\n'
    end
    local info = et:GetInfo('Warning', 'Error')
    local names = {}
    for tag in pairs(info) do
        names[#names + 1] = tag
    end
    perl.tsort(names)
    for i = 1, #names do
        if not (ignore and names[i]:match('^Warning')) then
            local tag = lexiftool.GetTagName(names[i])
            err = err .. '  ' .. perl.str(tag) .. ': ' .. perl.str(info[names[i]]) .. '\n'
        end
    end
    if err == '' then return true end
    io.stderr:write('\n' .. err)
    return false
end

--------------------------------------------------------------------------------
-- One of the tests failed (mirror of t/TestLib.pm; the modern assertion
-- interface above records failures via printOk instead).
--------------------------------------------------------------------------------
function TestLib.notOK()
    io.write('not ')
    rtnCode = 1
end

--------------------------------------------------------------------------------
-- Done tests. Under the runner this is a no-op (the runner reports the
-- summary and sets the process exit status); standalone it exits with code 1
-- if any assertion failed, else 0.
--------------------------------------------------------------------------------
function TestLib.done()
    if not running then
        os.exit(rtnCode)
    end
end

return TestLib