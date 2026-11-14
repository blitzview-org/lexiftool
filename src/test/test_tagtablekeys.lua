--------------------------------------------------------------------------------
-- File:         test/test_tagtablekeys.lua
--
-- Description:  The keys of a tag table after the table has changed.
--               perl.keys keeps the sorted key list of a larger hash and
--               uses it again while the hash has the same keys; TagTableKeys
--               reads a tag table through it. A tag added to a table after
--               its keys were read (AddTagToTable, AddUserDefinedTags, a
--               plain assignment) must show up in TagTableKeys and be
--               written, and a removed one must go.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok, is = TestLib.ok, TestLib.is
local done = TestLib.done

local T_DIR, TEST_DIR = TestLib.T_DIR, TestLib.TEST_DIR

-- true when list holds v
local function has(list, v)
    for _, x in ipairs(list) do
        if x == v then return true end
    end
    return false
end

local exifMain = lexiftool.GetTagTable(nil, 'lexiftool.Exif.Main')
local before = lexiftool.TagTableKeys(exifMain)
ok(#before > 100 and not has(before, 0xfeed) and not has(before, 'GROUPS'),
    'TagTableKeys of Exif::Main without the special keys')
is(#before, #lexiftool.TagTableKeys(exifMain), 'TagTableKeys again: same count')

-- AddTagToTable
lexiftool.AddTagToTable(nil, exifMain, 0xfeed, 'LxTestOne')
local keys = lexiftool.TagTableKeys(exifMain)
ok(has(keys, 0xfeed), 'TagTableKeys after AddTagToTable')
is(#before + 1, #keys, 'TagTableKeys after AddTagToTable: one more')

-- one key replaces another (same count)
exifMain[0xfeed] = nil
exifMain[0xfeee] = { Name = 'LxTestTwo' }
keys = lexiftool.TagTableKeys(exifMain)
ok(not has(keys, 0xfeed) and has(keys, 0xfeee), 'TagTableKeys after one tag replaces another')
is(#before + 1, #keys, 'TagTableKeys after the replacement: same count')
exifMain[0xfeee] = nil
is(#before, #lexiftool.TagTableKeys(exifMain), 'TagTableKeys after the tag is removed')

-- the write path: a user-defined tag added after a write has read the
-- table's keys is written by the next one
do
    local testfile = TEST_DIR .. '/tagtablekeys_failed.jpg'
    local exifTool = lexiftool.new()
    exifTool:SetNewValue('EXIF:Artist', 'A')
    os.remove(testfile)
    is(1, exifTool:WriteInfo(T_DIR .. '/images/Writer.jpg', testfile), 'first write')
    os.remove(testfile)
    lexiftool.AddUserDefinedTags('lexiftool.Exif.Main', {
        [0xd00d] = { Name = 'LxTestTag', Writable = 'string', WriteGroup = 'IFD0' },
    })
    exifTool = lexiftool.new()
    exifTool:SetNewValue('EXIF:LxTestTag', 'written')
    is(1, exifTool:WriteInfo(T_DIR .. '/images/Writer.jpg', testfile), 'write of the added tag')
    local info = exifTool:ImageInfo(testfile, 'LxTestTag')
    is('written', info.LxTestTag, 'the added tag is in the written file')
    os.remove(testfile)
    -- (every test file shares this Lua state: take the tag out again)
    exifMain[0xd00d] = nil
    is(#before, #lexiftool.TagTableKeys(exifMain), 'TagTableKeys after the user-defined tag is removed')
end

done()
