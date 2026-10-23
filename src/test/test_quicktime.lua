--------------------------------------------------------------------------------
-- File:         test/test_quicktime.lua
-- Ported from:  t/QuickTime.t
--
-- Description:  Lua port of tests 2-3 of the upstream QuickTime.t (the Perl
--               original): extracts information from t/images/QuickTime.mov and
--               t/images/QuickTime.m4a and compares against the vendored
--               standard outputs (t/QuickTime_2.out / t/QuickTime_3.out).
--
-- Port notes:   Read-only scope: the MOV/M4A atom parser. Embedded Pentax
--               MakerNotes, XMP and Composite tags are deferred, so the goldens
--               will only be partially matched until those slices land.
--               Plus a port-only check of the Binary exception to the
--               trailing-NUL strip of string 'data' atoms.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'QuickTime'

local files = { 'mov', 'm4a' }
local testnum = 1
for _, ext in ipairs(files) do
    testnum = testnum + 1
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/QuickTime.' .. ext)
    ok(check(exifTool, info, testname, testnum), 'test ' .. testnum .. ' matches (' .. ext .. ')')
end

-- (port-only addition) a trailing NUL of a string 'data' atom is removed
-- unless the tag is Binary (QuickTime.pm:10400 `s/\0$// unless
-- $$tagInfo{Binary}`): in a copy of QuickTime.m4a the '\xa9alb' entry is
-- renamed to 'covr' (CoverArt, Binary) and the last byte of its UTF-8 value
-- "album" becomes a NUL; the same is done to '\xa9wrt' (Composer).
do
    local fh = assert(io.open(T_DIR .. '/images/QuickTime.m4a', 'rb'))
    local data = fh:read('a')
    fh:close()
    local i = assert(data:find('\xa9alb', 1, true))
    local j = assert(data:find('album', i, true))
    data = data:sub(1, i - 1) .. 'covr' .. data:sub(i + 4, j + 3) .. '\0' .. data:sub(j + 5)
    i = assert(data:find('\xa9wrt', 1, true))
    j = assert(data:find('Composer', i, true))
    data = data:sub(1, j + 6) .. '\0' .. data:sub(j + 8)
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_binary_nul.m4a'
    fh = assert(io.open(testfile, 'wb'))
    fh:write(data)
    fh:close()
    local exifTool = lexiftool.new()
    exifTool:Options('Duplicates', 1)
    local info = exifTool:ImageInfo(testfile, 'CoverArt', 'Composer')
    os.remove(testfile)
    local cover = info['CoverArt (1)']
    cover = type(cover) == 'table' and cover.value or cover
    ok(cover == 'albu\0', 'Binary tag keeps its trailing NUL')
    ok(info.Composer == 'Compose', 'string tag loses its trailing NUL')
end

done() -- end
