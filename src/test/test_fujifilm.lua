--------------------------------------------------------------------------------
-- File:         test/test_fujifilm.lua
-- Ported from:  t/FujiFilm.t
--
-- Description:  Lua port of tests 1/2/4 of the upstream FujiFilm.t (the Perl
--               original): extracts information from t/images/FujiFilm.jpg
--               and t/images/FujiFilm.raf and compares against the vendored
--               standard output (t/FujiFilm_2.out, t/FujiFilm_4.out).
--
-- Port notes:   Tests 2-6 of the upstream numbering are ported.
--               Test 4's upstream call excludes -filename/-directory/
--               -filemodifydate/-fileaccessdate/-filecreatedate/
--               -fileinodechangedate/-filepermissions via the unported
--               ParseArguments/Exclude tag-filter engine (unlike MOI.t's
--               `-system:*`, this is a specific tag list, not a whole
--               family-1 group -- FileSize is also group System but stays
--               in the expected output); this test builds the same
--               filtered set by dropping exactly those tag names from the
--               full extraction result instead.  Test 6 writes into the
--               port's scalar-reference box `{ ref = 'SCALAR', value = '' }`.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local check = TestLib.check
local done = TestLib.done
local TEST_DIR = TestLib.TEST_DIR
local writeCheck = TestLib.writeCheck

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'FujiFilm'

-- test 2: Extract information from FujiFilm.jpg
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/FujiFilm.jpg')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Write some new information
do
    local writeInfo = {
        { 'CreateDate', '2005:01:06 11:51:09' },
        { 'WhiteBalance', 'day white', { Group = 'MakerNotes' } },
    }
    ok(writeCheck(writeInfo, testname, 3), 'test 3 matches')
end

-- test 4: Extract information from FujiFilm.raf
do
    local exifTool = lexiftool.new()
    local fullInfo = exifTool:ImageInfo(T_DIR .. '/images/FujiFilm.raf', { Duplicates = 1 })
    local excluded = {
        FileName = true, Directory = true, FileModifyDate = true, FileAccessDate = true,
        FileCreateDate = true, FileInodeChangeDate = true, FilePermissions = true,
    }
    local info = {}
    for tag, val in pairs(fullInfo) do
        if not excluded[tag] then info[tag] = val end
    end
    ok(check(exifTool, info, testname, 4), 'test 4 matches')
end

-- tests 5-6: Write writing a RAF and changing it back again in memory
do
    local exifTool = lexiftool.new()
    -- set IgnoreMinorErrors option to allow invalid JpgFromRaw to be written
    exifTool:SetNewValue('UserComment', 'test comment')
    local testfile = TEST_DIR .. '/' .. testname .. '_5_failed.raf'
    os.remove(testfile)
    exifTool:WriteInfo(T_DIR .. '/images/FujiFilm.raf', testfile)
    local info = exifTool:ImageInfo(testfile, 'UserComment')
    ok(check(exifTool, info, testname, 5), 'test 5 matches')

    local outfile = { ref = 'SCALAR', value = '' }
    -- pad out comment to make image the same size as the original
    exifTool:SetNewValue('UserComment', string.rep(' ', 248))
    exifTool:WriteInfo(testfile, outfile)
    info = exifTool:ImageInfo(outfile, { Duplicates = 1 })
    local success = check(exifTool, info, testname, 6, 4)
    if success then os.remove(testfile) end
    ok(success, 'test 6 matches')
end

done() -- end
