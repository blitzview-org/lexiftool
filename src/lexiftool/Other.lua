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
    local _, buff = raf:Read(256)
    -- (upstream: `$buff =~ /^(P[Ff])\x0a(\d+) (\d+)\x0a([-+0-9.]+)\x0a/` -- the
    --  PFM header is the P[Ff] signature, a newline, width, space, height,
    --  newline, scale, newline.  Note: the match must be assigned directly
    --  (not via `buff and buff:match(...)`, which would truncate the
    --  multi-return to the first capture))
    local cs, w, h, scale
    if buff then
        cs, w, h, scale = buff:match('^(P[Ff])\n(%d+) (%d+)\n([%-%+0-9%.]+)\n')
    end
    if not cs then return 0 end
    et:SetFileType('PFM', 'image/x-pfm')
    local tagTablePtr = et:GetTagTable('lexiftool.Other.PFM')
    et:HandleTag(tagTablePtr, 'ColorSpace', cs)
    et:HandleTag(tagTablePtr, 'ImageWidth', w)
    et:HandleTag(tagTablePtr, 'ImageHeight', h)
    et:HandleTag(tagTablePtr, 'ByteOrder', scale)
    return 1
end

return Other
