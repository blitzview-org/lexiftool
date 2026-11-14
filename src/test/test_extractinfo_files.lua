--------------------------------------------------------------------------------
-- File:         test/test_extractinfo_files.lua
--
-- Description:  ExtractInfo closes the files it opens before it returns, as
--               Perl does through the reference count of its local file
--               handle: after a normal read, with FastScan 4 (which leaves
--               the loop before the explicit Close), for a file of an
--               unknown type, a missing file, a directory, and over many
--               files read with one object (the way a -stay_open session
--               reads them). A file handle the caller passes in stays open.
--               The open descriptors are counted in /proc/self/fd; where
--               that does not exist the counting tests are skipped.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok, is = TestLib.ok, TestLib.is
local done = TestLib.done

local T = TestLib.T_DIR .. '/images'

-- number of open file descriptors of this process, or nil
local function countFds()
    local ok_, lfs = pcall(require, 'lfs')
    if not ok_ or not lfs.attributes('/proc/self/fd') then return nil end
    local n = 0
    for name in lfs.dir('/proc/self/fd') do
        if name ~= '.' and name ~= '..' then n = n + 1 end
    end
    return n
end

local function noneLeft(name, fn)
    local before = countFds()
    if before == nil then
        ok(true, name .. ' (skipped: no /proc/self/fd)')
        return
    end
    fn()
    is(before, countFds(), name .. ': no file left open')
end

noneLeft('ImageInfo of a JPEG', function()
    lexiftool.new():ImageInfo(T .. '/Canon.jpg')
end)

noneLeft('ExtractInfo of a JPEG', function()
    lexiftool.new():ExtractInfo(T .. '/ExifTool.jpg')
end)

noneLeft('ExtractInfo with FastScan 4', function()
    local et = lexiftool.new()
    et:Options('FastScan', 4)
    et:ExtractInfo(T .. '/Canon.jpg')
    is('JPEG', et:GetValue('FileType'), 'FastScan 4 still sets the file type')
end)

noneLeft('ExtractInfo of a file of unknown type', function()
    local et = lexiftool.new()
    et:ExtractInfo(TestLib.TEST_DIR .. '/test_extractinfo_files.lua')
end)

noneLeft('ExtractInfo of a missing file', function()
    lexiftool.new():ExtractInfo(T .. '/missing.jpg')
end)

noneLeft('ExtractInfo of a directory', function()
    lexiftool.new():ExtractInfo(T)
end)

noneLeft('many files with one object', function()
    local et = lexiftool.new()
    local files = { 'Canon.jpg', 'ExifTool.jpg', 'ExifTool.tif', 'XMP.xmp', 'QuickTime.mov',
                    'PDF.pdf', 'PNG.png', 'Nikon.jpg', 'missing.jpg', 'FLAC.flac' }
    for _, f in ipairs(files) do
        et:ImageInfo(T .. '/' .. f, 'FileType')
        et:ImageInfo(T .. '/' .. f, { FastScan = 4 }, 'FileType')
        et:ImageInfo(T .. '/' .. f, { ExtractEmbedded = 1 })
    end
end)

-- a file handle passed by the caller is not closed
do
    local fh = io.open(T .. '/Canon.jpg', 'rb')
    local et = lexiftool.new()
    et:ImageInfo(fh, 'FileType')
    is('file', io.type(fh), 'caller handle still open after ImageInfo')
    et:Options('FastScan', 4)
    et:ExtractInfo(fh)
    is('file', io.type(fh), 'caller handle still open after ExtractInfo with FastScan 4')
    fh:seek('set', 0)
    is('\xff\xd8', fh:read(2), 'caller handle still readable')
    fh:close()
end

done()
