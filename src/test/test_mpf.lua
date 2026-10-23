--------------------------------------------------------------------------------
-- File:         test/test_mpf.lua
--
-- Description:  Lua test for the MPF (Multi-Picture Format) read path.
--               Extracts the MPF tags from t/images/ExifTool.jpg and compares
--               them against the MPF lines of the vendored standard output
--               (t/ExifTool_2.out, test 2 of the upstream suite).  The test is
--               focused on the MPF subset so it can stay green while the other
--               JPEG segments of test 2 (CIFF, FlashPix, ...) are still being
--               ported; it uses only standard output data from the vendored
--               upstream tree.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local perl = require('lexiftool.perl')
local ok = TestLib.ok
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- collect the golden MPF lines from the upstream test-2 standard output
-- (group family 0 is "MPF", e.g. "MPF0", "MPImage1", "MPImage2")
local golden = {}
for line in io.lines(T_DIR .. '/ExifTool_2.out') do
    local g0, g1, _, id, rest =
        line:match('^%[([^,]+), ([^,]+), ([^%]]+)%] (%S+) %- (.*)$')
    if g0 == 'MPF' then
        golden[#golden + 1] = g1 .. ' ' .. id .. ' - ' .. rest
    end
end
ok(#golden > 0, 'found golden MPF lines in ExifTool_2.out (got ' .. #golden .. ')')

-- extract the MPF tags from the test image
local exifTool = lexiftool.new()
local info = exifTool:ImageInfo(T_DIR .. '/images/ExifTool.jpg')
local tags = exifTool:GetTagList(info, 'Group0')
local got = {}
for i = 1, #tags do
    local tag = tags[i]
    if exifTool:GetGroup(tag, 0) == 'MPF' then
        local val = TestLib.formatValue(info[tag])
        got[#got + 1] = perl.str(exifTool:GetGroup(tag, 1)) .. ' ' ..
            perl.str(exifTool:GetTagID(tag)) .. ' - ' ..
            perl.str(exifTool:GetDescription(tag)) .. ': ' .. val
    end
end

ok(#got == #golden, 'MPF tag count matches golden (expected ' .. #golden .. ', got ' .. #got .. ')')
for i = 1, math.max(#golden, #got) do
    local exp = golden[i]
    local act = got[i]
    ok(act == exp, 'MPF line ' .. i .. ' matches' ..
        (act == exp and '' or (' (expected ' .. tostring(exp) .. ', got ' .. tostring(act) .. ')')))
end

done() -- end
