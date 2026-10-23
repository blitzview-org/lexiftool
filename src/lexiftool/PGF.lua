--------------------------------------------------------------------------------
-- File:         lexiftool/PGF.lua
-- Ported from:  lib/Image/ExifTool/PGF.pm
--
-- Description:  Read Progressive Graphics File meta information
--
-- Revisions:    2011/01/25 - P. Harvey Created
--
-- References:   1) http://www.libpgf.org/
--               2) http://www.exiv2.org/
--
-- Port notes:   read port: the Main table plus ProcessPGF. Upstream PGF.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf

local PGF = {}

-- PGF header information
PGF.Main = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    PRIORITY = 2, -- (to take precedence over PNG tags from embedded image)
    NOTES = [[
        The following table lists information extracted from the header of
        Progressive Graphics File (PGF) images.  As well, information is extracted
        from the embedded PNG metadata image if it exists.  See
        L<http://www.libpgf.org/> for the PGF specification.
    ]],
    [3] = {
        Name = 'PGFVersion',
        PrintConv = function(_self, val) return sprintf('0x%.2x', val) end,
        -- this is actually a bitmask (ref digikam PGFtypes.h):
        -- 0x02 - data structure PGFHeader of major version 2
        -- 0x04 - 32-bit values
        -- 0x08 - supports regions of interest
        -- 0x10 - new coding scheme since major version 5
        -- 0x20 - new HeaderSize: 32 bits instead of 16 bits
    },
    [8] = { Name = 'ImageWidth', Format = 'int32u' },
    [12] = { Name = 'ImageHeight', Format = 'int32u' },
    [16] = 'PyramidLevels',
    [17] = 'Quality',
    [18] = 'BitsPerPixel',
    [19] = 'ColorComponents',
    [20] = {
        Name = 'ColorMode',
        RawConv = function(self, val) self.PGFColorMode = val; return val end,
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Bitmap',
            [1] = 'Grayscale',
            [2] = 'Indexed',
            [3] = 'RGB',
            [4] = 'CMYK',
            [7] = 'Multichannel',
            [8] = 'Duotone',
            [9] = 'Lab',
        },
    },
    [21] = { Name = 'BackgroundColor', Format = 'int8u[3]' },
}

--------------------------------------------------------------------------------
-- Extract information from a PGF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PGF file
--------------------------------------------------------------------------------
function PGF.ProcessPGF(et, dirInfo)
    local raf = dirInfo.RAF
    -- read header and check magic number
    local n, buff = raf:Read(24)
    if not (n == 24 and buff:sub(1, 3) == 'PGF') then return 0 end
    local ver = buff:byte(4)
    et:SetFileType()
    ExifTool.SetByteOrder('II')

    -- currently support only version 0x36
    if ver ~= 0x36 then
        et:Error(sprintf('Unsupported PGF version 0x%.2x', ver))
        return 1
    end
    -- extract information from the PGF header
    local tagTablePtr = et:GetTagTable('lexiftool.PGF.Main')
    et:ProcessDirectory({ DataPt = buff, DataPos = 0 }, tagTablePtr)

    local len = ExifTool.Get32u(buff, 4) - 16 -- length of post-header data

    -- skip colour table if necessary
    if et.PGFColorMode == 2 then
        if raf:Seek(1024, 1) then
            len = len - 1024
        else
            len = 0
        end
    end

    -- extract information from the embedded metadata image (PNG format)
    if len > 0 and len < 0x1000000 then
        local n2, buff2 = raf:Read(len)
        if n2 == len then
            et:ExtractInfo({ ref = 'SCALAR', value = buff2 }, { ReEntry = 1 })
        end
    end
    return 1
end

return PGF
