--------------------------------------------------------------------------------
-- File:         test/test_segments.lua
--
-- Description:  Lua test for the small JPEG APP-segment tag tables.
--               Compares the tags of the listed group-0 families from
--               t/images/ExifTool.jpg against the corresponding lines of the
--               vendored standard output (t/ExifTool_2.out).  The test only
--               checks the families listed in `families` below, so it stays
--               green while the other JPEG segments of test 2 are still being
--               ported; it uses only standard output data from the vendored
--               upstream tree.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local perl = require('lexiftool.perl')
local ok = TestLib.ok
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- group-0 families covered by this test (add families as they are ported).
-- A family may instead name a group-1 value when only part of a group-0
-- family is ported (e.g. Qualcomm shares group0 "MakerNotes" with CIFF).
local families = {
    ['APP8'] = true,    -- SPIFF
    ['APP6'] = true,    -- NITF
    ['Meta'] = true,    -- Kodak MetaIFD (APP3)
    ['PrintIM'] = true, -- EPPIM (APP6)
    ['XML'] = true,     -- MediaJukebox (APP9)
    ['Ducky'] = true,   -- (APP12)
    ['APP12'] = true,   -- PictureInfo (APP12)
    ['APP5'] = true,    -- Ricoh RMETA
    ['Qualcomm'] = true, -- (APP7, group-1 match)
    ['CIFF'] = true,    -- (APP0, group-1 match)
    ['AVI1'] = true,    -- (APP0, group-1 match)
    ['JPEG-HDR'] = true, -- (APP11, group-1 match)
    ['JFXX'] = true,    -- (APP0 JFIF extension, group-1 match)
    ['FlashPix'] = true, -- (APP2 FPXR, group-1 match)
    ['JUMBF'] = true,   -- (APP11 JUMBF box: JUMD type/label, group-0 match)
    ['JSON'] = true,    -- (APP11 JUMBF json box tags, group-1 match)
    ['Trailer'] = true, -- (Vivo trailer, group-0 match)
    ['Samsung'] = true, -- (SEFT trailer, group-1 match)
    ['MIE'] = true,     -- (zmie trailer)
    ['PhotoMechanic'] = true, -- (cbipcbbl trailer)
    ['CanonVRD'] = true, -- (CANON OPTIONAL DATA trailer)
    ['FotoStation'] = true, -- (FSHDR trailer)
    ['IPTC2'] = true, -- (non-standard IPTC block, group-1 match; FotoStation trailer)
    ['IPTC3'] = true, -- (non-standard IPTC block, group-1 match; AFCP trailer)
}

-- does a golden line belong to a covered family? (group0, group1)
local function covered(g0, g1)
    return families[g0] or families[g1] or false
end

-- collect the golden lines for the covered families
-- (the tag ID may contain spaces, e.g. "Sign type", so it is matched lazily)
local golden = {}
for line in io.lines(T_DIR .. '/ExifTool_2.out') do
    local g0, g1, _, id, rest =
        line:match('^%[([^,]+), ([^,]+), ([^%]]+)%] (.-) %- (.*)$')
    if covered(g0, g1) then
        golden[#golden + 1] = g0 .. '|' .. g1 .. ' ' .. id .. ' - ' .. rest
    end
end
ok(#golden > 0, 'found golden lines for the tested families in ExifTool_2.out (got ' .. #golden .. ')')

-- the golden output orders groups by their first appearance in the whole
-- file, which depends on segments that may not be ported yet (e.g. the CIFF
-- tags shift the MakerNotes group); compare both sides sorted instead
perl.tsort(golden)

-- extract the tags of the covered families from the test image
local exifTool = lexiftool.new()
local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg')
local tags = exifTool:GetTagList(info, 'Group0')
local got = {}
for i = 1, #tags do
    local tag = tags[i]
    local g0 = exifTool:GetGroup(tag, 0)
    local g1 = exifTool:GetGroup(tag, 1)
    if covered(g0, g1) then
        local val = TestLib.formatValue(info[tag])
        local tagID = tostring(exifTool:GetTagID(tag)):gsub('([\000-\031\127-\255])', function(c)
            return string.format('\\x%.2x', c:byte())
        end)
        got[#got + 1] = g0 .. '|' .. g1 .. ' ' ..
            tagID .. ' - ' ..
            tostring(exifTool:GetDescription(tag)) .. ': ' .. val
    end
end

ok(#got == #golden, 'segment tag count matches golden (expected ' .. #golden .. ', got ' .. #got .. ')')
perl.tsort(got)
for i = 1, math.max(#golden, #got) do
    local exp = golden[i]
    local act = got[i]
    ok(act == exp, 'segment line ' .. i .. ' matches' ..
        (act == exp and '' or (' (expected ' .. tostring(exp) .. ', got ' .. tostring(act) .. ')')))
end

done() -- end
