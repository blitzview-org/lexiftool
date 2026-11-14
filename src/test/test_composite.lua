--------------------------------------------------------------------------------
-- File:         test/test_composite.lua
--
-- Description:  Lua test for the EXIF Composite tags (Exif.lua's
--               Exif.Composite table) against t/images/ExifTool.jpg. Compares
--               the ported subset of Composite tag IDs against the
--               corresponding lines of the vendored standard output
--               (t/ExifTool_2.out, test 2 of the upstream suite). The test is
--               keyed by an explicit tag-ID whitelist and compared sorted
--               rather than as the whole Composite group in file order: the
--               camera-lens tags' upstream build order depends on the
--               unported Canon Composite:DigitalZoom tag, so their FILE_ORDER (and therefore
--               golden line position) doesn't match ours even though every
--               value is correct; it uses only standard output data from the
--               vendored upstream tree.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local perl = require('lexiftool.perl')
local ok = TestLib.ok
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- Composite tag IDs covered by this test (add tag IDs as they are ported).
local tagIDs = {
    ['Exif-ImageSize'] = true,
    ['Exif-Megapixels'] = true,
    ['Exif-ShutterSpeed'] = true,
    ['Exif-Aperture'] = true,
    ['Exif-LightValue'] = true,
    ['Exif-ScaleFactor35efl'] = true,
    ['Exif-FocalLength35efl'] = true,
    ['Exif-CircleOfConfusion'] = true,
    ['Exif-FOV'] = true,
    ['Exif-HyperfocalDistance'] = true,
}

-- collect the golden Composite lines for the covered tag IDs
local golden = {}
for line in io.lines(T_DIR .. '/ExifTool_2.out') do
    -- luacheck: ignore 211
    local g0, g1, g2, id, rest =
        line:match('^%[([^,]+), ([^,]+), ([^%]]+)%] (%S+) %- (.*)$')
    if g0 == 'Composite' and tagIDs[id] then
        golden[#golden + 1] = g2 .. ' ' .. id .. ' - ' .. rest
    end
end
ok(#golden == 10, 'found golden Composite lines in ExifTool_2.out (got ' .. #golden .. ')')

-- extract the Composite tags from the test image
local exifTool = lexiftool.new()
local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg')
local tags = exifTool:GetTagList(info, 'Group0')
local got = {}
for i = 1, #tags do
    local tag = tags[i]
    local g0 = exifTool:GetGroup(tag, 0)
    local id = exifTool:GetTagID(tag)
    if g0 == 'Composite' and tagIDs[id] then
        local val = TestLib.formatValue(info[tag])
        local g2 = exifTool:GetGroup(tag, 2)
        local desc = exifTool:GetDescription(tag)
        got[#got + 1] = tostring(g2) .. ' ' .. tostring(id) .. ' - ' .. tostring(desc) .. ': ' .. val
    end
end

ok(#got == #golden, 'Composite tag count matches golden (expected ' .. #golden .. ', got ' .. #got .. ')')
perl.tsort(golden)
perl.tsort(got)
for i = 1, math.max(#golden, #got) do
    local exp = golden[i]
    local act = got[i]
    ok(act == exp, 'Composite line ' .. i .. ' matches' ..
        (act == exp and '' or (' (expected ' .. tostring(exp) .. ', got ' .. tostring(act) .. ')')))
end

done() -- end
