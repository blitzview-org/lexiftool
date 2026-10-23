--------------------------------------------------------------------------------
-- File:         test/test_exe.lua
-- Ported from:  t/EXE.t
--
-- Description:  Lua port of tests 2-7 of the upstream EXE.t (the Perl
--               original): extracts information from t/images/EXE.{exe,macho,
--               elf,a,so,dylib} and compares against the vendored standard
--               outputs (t/EXE_2.out .. t/EXE_7.out).
--
-- Port notes:   Read-only scope: tests 2-7 of the upstream numbering are
--               ported (the Windows PE COFF header + version resource reader,
--               the Mach-O header reader, the ELF reader, the .a archive walk
--               and the shebang script detection). The PEF (classic MacOS) and
--               CHM branches of ProcessEXE are deferred (no vendored fixture
--               reaches them).
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

-- Date/time tags in the goldens carry the host timezone offset; the test
-- harness tolerates timezone differences (see TestLib nearEnough), so no TZ
-- pinning is required and the tests pass regardless of the host timezone.
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'EXE'

-- tests 2-7: Extract information from various types of executable files and libraries
local exts = { 'exe', 'macho', 'elf', 'a', 'so', 'dylib' }
local testnum = 1
for _, ext in ipairs(exts) do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    -- upstream EXE.t passes '-system:all' so only the System group plus the
    -- file's native group are extracted (the port models the file-info tags
    -- FileName/Directory/FileSize/... as the System group, so this drops them)
    local info = exifTool:ImageInfo(T_DIR .. '/images/EXE.' .. ext, '-system:all')
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches (' .. ext .. ')')
end

done() -- end
