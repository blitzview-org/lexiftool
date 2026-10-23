--------------------------------------------------------------------------------
-- File:         lexiftool/Other.lua
-- Ported from:  lib/Image/ExifTool/Other.pm
--
-- Description:  Read meta information from other uncommon formats
--
-- Revisions:    2021/07/16 - P. Harvey Created
--
-- References:   1) PFM - http://www.pauldebevec.com/Research/HDR/PFM/
--
-- Port notes:   read subset: only the Portable FloatMap (PFM) reader is
--               ported (the only other format in Other.pm).  The file-type
--               magic for a PFM image is `P[Ff]\x0a\d+ \d+\x0a[-+0-9.]+\x0a`
--               -- distinguished from Printer Font Metrics (.pfm) files by
--               the magic's leading `P[Ff]\n`.
--------------------------------------------------------------------------------

local Other = {}

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local perlTruthy = perl.truthy

-- Other info
Other.PFM = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Tags extracted from Portable FloatMap images. See
        http://www.pauldebevec.com/Research/HDR/PFM/ for the specification.
    ]],
    ColorSpace  = { PrintConv = { PF = 'RGB', Pf = 'Monochrome' } },
    ImageWidth  = { },
    ImageHeight = { },
    ByteOrder   = { PrintConv = function(_self, val) return tonumber(val) > 0 and 'Big-endian' or 'Little-endian' end },
}

-- Extract information from a Portable FloatMap image (upstream ProcessPFM2)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PFM file
function Other.ProcessPFM2(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(256)
    local m1, m2, m3, m4
    if perlTruthy(n) then
        m1, m2, m3, m4 = matches(buff, [[^(P[Ff])\x0a(\d+) (\d+)\x0a([-+0-9.]+)\x0a]])
    end
    if not m1 then return 0 end
    et:SetFileType('PFM', 'image/x-pfm')
    local tagTablePtr = et:GetTagTable('lexiftool.Other.PFM')
    et:HandleTag(tagTablePtr, 'ColorSpace', m1)
    et:HandleTag(tagTablePtr, 'ImageWidth', m2)
    et:HandleTag(tagTablePtr, 'ImageHeight', m3)
    et:HandleTag(tagTablePtr, 'ByteOrder', m4)
    -- hack to set proper file description (extension is the same for Printer Font Metrics files)
    ExifTool.static_vars.OverrideFileDescription = ExifTool.static_vars.OverrideFileDescription or {} -- (autovivify)
    ExifTool.static_vars.OverrideFileDescription.PFM = 'Portable FloatMap'
    return 1
end

return Other
