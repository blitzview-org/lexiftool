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
--               At the end, the port's own block: the sorted Composite tag
--               list BuildCompositeTags keeps between files
--               (compositeTagList) follows every
--               change of the Composite table -- keys added, removed,
--               replaced, special keys, AddCompositeTags between two files.
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
local exifTool = lexiftool:new()
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


-- not upstream: compositeTagList (BuildCompositeTags' `sort keys %$compTable`,
-- kept per key set) against TagTableKeys + tsort after each change
do
    local ExifTool = lexiftool
    local comp = ExifTool.GetTagTable('lexiftool.ExifTool.Composite')
    local listOf = ExifTool._compositeTagList
    local function fresh()
        local l = ExifTool.TagTableKeys(comp)
        perl.tsort(l)
        return table.concat(l, '\0')
    end
    local function same(what)
        local want = fresh()
        local list = table.concat(listOf(comp), '\0')
        ok(list == want, 'compositeTagList: ' .. what)
    end
    same('first call')
    same('unchanged table')
    comp['ZZZ-B1Test'] = { Name = 'ZZZB1Test' }
    same('key added')
    comp['ZZZ-B1Test'] = nil
    same('key removed')
    local first = listOf(comp)[1]
    local saved = comp[first]
    comp[first] = nil
    comp['AAA-B1Test'] = { Name = 'AAAB1Test' }    -- (as many keys as before)
    same('key replaced by another')
    comp['AAA-B1Test'] = nil
    comp[first] = saved
    same('table restored')
    local special
    for k in pairs(ExifTool.specialTags) do
        if comp[k] == nil then special = k break end
    end
    if special then
        comp[special] = 1
        same('special key ' .. tostring(special) .. ' added')
        comp[special] = nil
        same('special key removed')
    end

    -- a Composite tag added between two files is built for the second
    local image = T_DIR .. '/images/ExifTool.jpg'
    local et = lexiftool:new()
    local info1 = et:ImageInfo(image, 'B1TestTag')
    ok(info1.B1TestTag == nil, 'B1TestTag not there before AddCompositeTags')
    ExifTool.AddCompositeTags({
        B1TestTag = {
            Require = { [0] = 'FileType' },
            ValueConv = function(_, val) return 'B1:' .. val[0] end,
        },
    })
    same('after AddCompositeTags')
    local info2 = lexiftool:new():ImageInfo(image, 'B1TestTag')
    ok(info2.B1TestTag == 'B1:JPEG', 'B1TestTag built after AddCompositeTags (got ' .. tostring(info2.B1TestTag) .. ')')
end

done() -- end
