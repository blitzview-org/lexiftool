--------------------------------------------------------------------------------
-- File:         test/test_imageinfo_api.lua
--
-- Description:  The argument forms of ImageInfo, ExtractInfo and GetInfo
--               (ParseArguments): the function and the method form, a scalar
--               reference, a RandomAccess object, a file handle, a tag list
--               that is updated with the tags found, an options hash whose
--               options are restored afterwards, excluded tags, group names,
--               the return value of ExtractInfo, a second call on the same
--               object, a tag list passed to ExtractInfo itself, and an
--               argument of an unknown type. The expected lines are what the
--               same calls print with Image::ExifTool.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local RandomAccess = require('lexiftool.RandomAccess')
local perl = require('lexiftool.perl')
local TestLib = require('test.TestLib')
local is = TestLib.is
local done = TestLib.done

local T = TestLib.T_DIR .. '/images'
local TEST_DIR = TestLib.TEST_DIR

-- the file system tags that differ from one checkout to the next
local skip = {
    FileAccessDate = 1, FileModifyDate = 1, FileInodeChangeDate = 1,
    FileCreateDate = 1, FilePermissions = 1, Directory = 1,
}

-- "NAME: Tag=Value ..." for an info hash, sorted by tag key
local function dumpInfo(name, info)
    local keys = {}
    for k in pairs(info) do
        if not skip[k] then keys[#keys + 1] = k end
    end
    perl.tsort(keys)
    local out = name .. ':'
    for _, k in ipairs(keys) do
        out = out .. ' ' .. k .. '=' .. (type(info[k]) == 'table' and 'REF' or perl.str(info[k]))
    end
    return out
end

local function count(h)
    local n = 0
    for _ in pairs(h) do n = n + 1 end
    return n
end

local fh = io.open(T .. '/Canon.jpg', 'rb')
local data = fh:read('a')
fh:close()

-- function form with tag names
is('A: FileName=Canon.jpg Make=Canon Model=Canon EOS DIGITAL REBEL',
    dumpInfo('A', lexiftool.ImageInfo(T .. '/Canon.jpg', 'Make', 'Model', 'FileName')),
    'ImageInfo as a function')

-- scalar reference: no FileName
local et = lexiftool.new()
is('B: FileSize=2.7 kB Make=Canon',
    dumpInfo('B', et:ImageInfo({ ref = 'SCALAR', value = data }, 'FileSize', 'FileName', 'Make')),
    'ImageInfo of a scalar reference')

-- RandomAccess object
local raf = RandomAccess.new({ ref = 'SCALAR', value = data })
is('C: FileType=JPEG Make=Canon', dumpInfo('C', et:ImageInfo(raf, 'FileType', 'Make')),
    'ImageInfo of a RandomAccess object')

-- tag list reference, updated with the tags found
local tags = { 'make', 'model', 'nonexistent', 'imagesize' }
is('D: ImageSize=8x8 Make=Canon Model=Canon EOS DIGITAL REBEL',
    dumpInfo('D', et:ImageInfo(T .. '/Canon.jpg', tags)), 'ImageInfo with a tag list')
is('Make Model nonexistent (0) ImageSize', table.concat(tags, ' '), 'tag list updated')

-- options hash: applies to this call only
et:Options('PrintConv', 1)
is('E: ExposureTime=4 ExposureTime (1)=128',
    dumpInfo('E', et:ImageInfo(T .. '/Canon.jpg', { PrintConv = 0 }, 'ExposureTime')),
    'ImageInfo with an options hash')
is('1', perl.str(et:Options('PrintConv')), 'options restored after ImageInfo')

-- return value of ExtractInfo
et = lexiftool.new()
is('0 Error opening file', perl.str(et:ExtractInfo(T .. '/missing.jpg')) .. ' ' .. et:GetValue('Error'),
    'ExtractInfo of a missing file')
is('1 undef', perl.str(et:ExtractInfo(T .. '/Canon.jpg')) .. ' ' .. perl.str(et:GetValue('Error') or 'undef'),
    'ExtractInfo of a JPEG')
is('1 DIR', perl.str(et:ExtractInfo(T)) .. ' ' .. et:GetValue('FileType'), 'ExtractInfo of a directory')
local empty = TEST_DIR .. '/imageinfo_empty.tmp'
fh = io.open(empty, 'wb')
fh:close()
is('0 File is empty', perl.str(et:ExtractInfo(empty)) .. ' ' .. perl.str(et:GetValue('Error') or 'undef'),
    'ExtractInfo of an empty file')
os.remove(empty)

-- a second ImageInfo on the same object starts with a new tag list
et = lexiftool.new()
local info1 = et:ImageInfo(T .. '/Canon.jpg', 'Make')
local info2 = et:ImageInfo(T .. '/Canon.jpg')
is('1 many', count(info1) .. ' ' .. (count(info2) > 50 and 'many' or 'few'), 'second ImageInfo: all tags')

-- tags passed to ExtractInfo; GetInfo(undef) keeps them, GetInfo() does not
et = lexiftool.new()
et:ExtractInfo(T .. '/Canon.jpg', 'Make')
is('H1: Make=Canon', dumpInfo('H1', et:GetInfo(nil)), 'GetInfo(undef) after ExtractInfo with a tag')
is('many', count(et:GetInfo()) > 50 and 'many' or 'few', 'GetInfo() parses its (empty) arguments')

-- ExtractInfo reads the requested tags of the previous call before it
-- parses its own arguments (FileSequence is generated from the second call)
et = lexiftool.new()
et:ExtractInfo(T .. '/Canon.jpg', 'FileSequence')
is('undef', perl.str(et:GetValue('FileSequence') or 'undef'), 'ExtractInfo: FileSequence on the first call')
et:ExtractInfo(T .. '/Canon.jpg', 'FileSequence')
is('1', perl.str(et:GetValue('FileSequence') or 'undef'), 'ExtractInfo: FileSequence on the second call')

-- an argument of an unknown type
do
    local warning = ''
    local oldWarn = perl.SIG.__WARN__
    perl.SIG.__WARN__ = function(msg) warning = warning .. msg end
    et:ImageInfo(T .. '/Canon.jpg', function() return 1 end)
    perl.SIG.__WARN__ = oldWarn
    is("Don't understand ImageInfo argument CODE(ADDR)\n", (warning:gsub('0x[0-9a-f]+', 'ADDR')),
        'ImageInfo argument of an unknown type')
end

-- file handle: no FileName
fh = io.open(T .. '/Canon.jpg', 'rb')
is('K: FileSize=2.7 kB FileType=JPEG', dumpInfo('K', et:ImageInfo(fh, 'FileSize', 'FileName', 'FileType')),
    'ImageInfo of a file handle')
fh:close()

-- options passed to ExtractInfo are restored at its end
et = lexiftool.new()
et:ExtractInfo(T .. '/Canon.jpg', { Duplicates = 0 })
is('1', perl.str(et:Options('Duplicates')), 'options restored after ExtractInfo')

-- excluded tags, group names
is('M: Model=Canon EOS DIGITAL REBEL', dumpInfo('M', et:ImageInfo(T .. '/Canon.jpg', 'Make', '-Make', 'Model')),
    'ImageInfo with an excluded tag')
is('N: Model=Canon EOS DIGITAL REBEL',
    dumpInfo('N', et:ImageInfo(T .. '/Canon.jpg', { Exclude = 'Make' }, 'Make', 'Model')),
    'ImageInfo with the Exclude option')
is('O: Make=Canon Model=Canon EOS DIGITAL REBEL',
    dumpInfo('O', et:ImageInfo(T .. '/Canon.jpg', 'EXIF:Make', 'IFD0:Model')), 'ImageInfo with group names')
is('11', (et.REQ_TAG_LOOKUP['exif:'] and '1' or '0') .. (et.REQ_TAG_LOOKUP.make and '1' or '0'),
    'requested-tag lookup of group and tag names')

-- the RequestTags option
et = lexiftool.new()
et:Options('RequestTags', { 'FileSequence' })
is('Q: FileName=Canon.jpg FileSequence=0',
    dumpInfo('Q', et:ImageInfo(T .. '/Canon.jpg', 'FileName', 'FileSequence')), 'RequestTags option')
is('R: FileSequence=1', dumpInfo('R', et:ImageInfo(T .. '/Canon.jpg', 'FileSequence')),
    'RequestTags option, second file')

done()
