--------------------------------------------------------------------------------
-- File:         test/test_filedescription.lua
--
-- Description:  Lua test for the description form of GetFileType
--               (`GetFileType($type, 1)`): the long description of a file
--               type or extension, a FileType with a sub-type in brackets,
--               a type known only to %fileDescription, and the
--               per-file override in %static_vars{OverrideFileDescription}
--               that FlashPix.ProcessContents sets for a Scene7 Vignette.
--               The fixture is one of this port's own test images -- see
--               src/test/images/README.md (lex_FlashPix_Vignette.vnt).
--
--               The expected values are those of the vendored Perl
--               ExifTool. Where a perl is available the test asks the
--               vendored original directly as well.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local is = TestLib.is
local done = TestLib.done

local path = TestLib.REPO_DIR .. '/src/test/images/lex_FlashPix_Vignette.vnt'
local args = { 'VNT', 'DIR', 'XYZ (Sub)', 'TIFF (BigTIFF)', 'x.vnt' }

local function descriptions(list)
    local out = {}
    for i = 1, #list do out[i] = lexiftool.GetFileType(list[i], 1) end
    return table.concat(out, '|')
end

-- before any file is read: the descriptions of %fileTypeLookup/%fileDescription
local before = descriptions(args)
is('Scene7 Vignette or V-Note text file|Directory|XYZ, Sub|Tagged Image File Format, BigTIFF|'
   .. 'Scene7 Vignette or V-Note text file', before, 'descriptions before reading a file')

-- after reading a Scene7 Vignette, the override names the VNT type
local et = lexiftool.new()
et:ExtractInfo(path)
local after = descriptions({ 'VNT', 'x.vnt' })
is('Scene7 Vignette|Scene7 Vignette', after, 'description overridden by the VNT file')

--------------------------------------------------------------------------------
-- Ask the vendored original directly where a perl is available.
--------------------------------------------------------------------------------
local script = 'print join("|", map {Image::ExifTool::GetFileType($_,1)} @ARGV[1..5]), "\\n";'
    .. ' $e = Image::ExifTool->new; $e->ExtractInfo($ARGV[0]);'
    .. ' print join("|", map {Image::ExifTool::GetFileType($_,1)} "VNT", "x.vnt"), "\\n"'
local cmd = ("cd %s/vendor/exiftool 2>/dev/null && perl -Ilib -MImage::ExifTool -e '%s' '%s' %s 2>/dev/null")
    :format(TestLib.REPO_DIR, script, path, "VNT DIR 'XYZ (Sub)' 'TIFF (BigTIFF)' x.vnt")
local pipe = io.popen(cmd)
local perlOut = pipe and pipe:read('a') or ''
if pipe then pipe:close() end

local perlBefore, perlAfter = perlOut:match('^([^\n]*)\n([^\n]*)\n$')
if perlBefore then
    is(perlBefore, before, 'descriptions before reading equal the Perl original')
    is(perlAfter, after, 'overridden description equals the Perl original')
end

done() -- end
