--------------------------------------------------------------------------------
-- File:         test/test_photoshop_layers.lua
--
-- Description:  Lua test for Photoshop.ProcessLayers -- the layer records of a
--               PSD file and the "additional layer info" blocks inside them.
--               The vendored t/images/Photoshop.psd has LayerCount 0, so this
--               path is not covered by any upstream test; the fixture is one
--               of this port's own test images -- see
--               src/test/images/README.md for its byte layout.
--
--               The expected values are the output of the vendored Perl
--               exiftool on exactly that file:
--
--                 [Photoshop] Layer Count         : 2
--                 [Photoshop] Layer Rectangles    : 0 0 8 8, 0 0 8 8
--                 [Photoshop] Layer Blend Modes   : Normal, Normal
--                 [Photoshop] Layer Opacities     : 100%, 100%
--                 [Photoshop] Layer Visible       : Yes, Yes
--                 [Photoshop] Layer Names         : Ebene 1, Hintergrund
--                 [Photoshop] Layer Unicode Names : Ebene 1, Hintergrund
--                 [Photoshop] Layer IDs           : 42, 43
--                 [Photoshop] Layer Sections      : Layer, Folder (open)
--
--               Where a perl is available the test does not trust those
--               transcribed values but asks the vendored original directly, so
--               they cannot drift silently.
--
--               Regression guard: before the fix in ProcessLayers, the two
--               length words before the layer name were each read twice (Perl
--               reads and checks in one `$raf->Read($buff,4) == 4`), so the
--               name length came from the wrong offset and everything from
--               LayerNames onwards was silently dropped. Without the fix 8 of
--               the 9 checks below fail.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local done = TestLib.done

local path = TestLib.REPO_DIR .. '/src/test/images/lex_PhotoshopLayers.psd'

local et = lexiftool.new()
local info = et:ImageInfo(path, { Unknown = 1 })

-- normalize list values: the extractor may hand back a table or a joined string
local function val(tag)
    local v = info[tag]
    if type(v) == 'table' then
        local out = {}
        for i = 1, #v do out[i] = tostring(v[i]) end
        return table.concat(out, ', ')
    end
    return tostring(v)
end

ok(val('LayerCount') == '2', 'LayerCount is 2')
ok(val('LayerRectangles') == '0 0 8 8, 0 0 8 8', 'LayerRectangles matches')
ok(val('LayerBlendModes') == 'Normal, Normal', 'LayerBlendModes matches')
ok(val('LayerOpacities') == '100%, 100%', 'LayerOpacities matches')
ok(val('LayerVisible') == 'Yes, Yes', 'LayerVisible matches')
-- the four below all sit behind the length words that were read twice
ok(val('LayerNames') == 'Ebene 1, Hintergrund', 'LayerNames matches')
ok(val('LayerUnicodeNames') == 'Ebene 1, Hintergrund', 'LayerUnicodeNames matches')
ok(val('LayerIDs') == '42, 43', 'LayerIDs matches')
-- the first layer has no lsct block, so upstream pads the list with a 0 entry
ok(val('LayerSections') == 'Layer, Folder (open)', 'LayerSections padded like upstream')

--------------------------------------------------------------------------------
-- Ask the vendored original directly where a perl is available. Without perl
-- the test simply ends here.
--------------------------------------------------------------------------------
local cmd = ("cd %s/vendor/exiftool 2>/dev/null && perl -Ilib exiftool -a -u -s -Photoshop:all '%s' 2>/dev/null")
    :format(TestLib.REPO_DIR, path)
local pipe = io.popen(cmd)
local perlOut = pipe and pipe:read('a') or ''
if pipe then pipe:close() end

if perlOut:find('LayerCount', 1, true) then
    local reference = {}
    for tag, v in perlOut:gmatch('([%w]+)%s*:%s*([^\n]-)%s*\n') do reference[tag] = v end
    for _, tag in ipairs({ 'LayerCount', 'LayerRectangles', 'LayerBlendModes',
                           'LayerOpacities', 'LayerVisible', 'LayerNames',
                           'LayerUnicodeNames', 'LayerIDs', 'LayerSections' }) do
        ok(reference[tag] == val(tag),
           ('%s equals the Perl original (%s)'):format(tag, tostring(reference[tag])))
    end
end

done() -- end
