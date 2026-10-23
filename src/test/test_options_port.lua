--------------------------------------------------------------------------------
-- File:         test/test_options_port.lua
--
-- Description:  Library-level option handling the upstream tests and the CLI
--               golden cases do not reach (list arguments, the values the
--               options hold, GetValue's Rational/Bin types). The expected
--               values are what `perl -I vendor/exiftool/lib` returns for
--               the same library calls:
--                 1. RequestTags: shortcuts expanded (ExpandShortcuts),
--                    group prefixes added as "group:" entries, a list
--                    argument appended to the existing list and left as
--                    the caller passed it
--                 2. IgnoreTags: shortcuts expanded, group prefix and '#'
--                    suffix dropped
--                 3. Plot: settings accumulate over several calls
--                 4. SaveBin: GetValue(tag, 'Rational') and (tag, 'Bin')
--                    return the saved components; no Bin value for a tag
--                    that did not come from a value read
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')

local is, ok = TestLib.is, TestLib.ok
local T_DIR = TestLib.T_DIR

local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

-- 1. RequestTags
local et = lexiftool.new()
et:Options('RequestTags', 'System:ls-l XMP-dc:Title')
is(table.concat(et:Options('RequestTags'), ','),
   'filepermissions,system:,filehardlinks,system:,fileuserid,system:,filegroupid,system:,' ..
   'filesize,system:,filemodifydate,system:,filename,system:,title,xmp-dc:',
   'RequestTags: shortcut and group prefixes from a string')
local list = { 'CommonIFD0' }
et:Options('RequestTags', list)
is(table.concat(et:Options('RequestTags'), ','),
   'filepermissions,system:,filehardlinks,system:,fileuserid,system:,filegroupid,system:,' ..
   'filesize,system:,filemodifydate,system:,filename,system:,title,xmp-dc:,' ..
   'imagedescription,ifd0:,make,ifd0:,model,ifd0:,software,ifd0:,modifydate,ifd0:,' ..
   'artist,ifd0:,copyright,ifd0:,rating,ifd0:,ratingpercent,ifd0:,dnglensinfo,ifd0:,' ..
   'panasonictitle,ifd0:,panasonictitle2,ifd0:,xptitle,ifd0:,xpcomment,ifd0:,' ..
   'xpauthor,ifd0:,xpkeywords,ifd0:,xpsubject,ifd0:',
   'RequestTags: a list argument is appended')
is(table.concat(list, ','), 'CommonIFD0', 'RequestTags: the caller\'s list is left as it was')
et:Options('RequestTags', nil)
is(et:Options('RequestTags'), nil, 'RequestTags: undef clears the list')

-- 2. IgnoreTags
et:Options('IgnoreTags', { 'CommonIFD0', 'XMP:Title#' })
local keys = {}
for k in pairs(et:Options('IgnoreTags')) do keys[#keys + 1] = k end
table.sort(keys)
is(table.concat(keys, ','),
   'artist,copyright,dnglensinfo,imagedescription,make,model,modifydate,panasonictitle,' ..
   'panasonictitle2,rating,ratingpercent,software,title,xpauthor,xpcomment,xpkeywords,' ..
   'xpsubject,xptitle',
   'IgnoreTags: shortcut expanded, group and suffix dropped')

-- 3. Plot
et:Options('Plot', 'Size=300x200')
et:Options('Plot', 'Title=T')
is(et:Options('Plot'), 'Size=300x200,Title=T', 'Plot: settings accumulate')

-- 4. SaveBin and GetValue's Rational/Bin types
local et2 = lexiftool.new()
et2:Options('SaveBin', 1)
et2:ExtractInfo(T_DIR .. '/images/Canon.jpg')
is(et2:GetValue('XResolution', 'Rational'), '180/1', 'GetValue Rational')
is(hex(et2:GetValue('XResolution', 'Bin') or ''), 'b400000001000000', 'GetValue Bin (rational64u)')
is(hex(et2:GetValue('Make', 'Bin') or ''), '43616e6f6e00', 'GetValue Bin (string)')
ok(et2:GetValue('FileName', 'Bin') == nil, 'GetValue Bin: none for a generated tag')
