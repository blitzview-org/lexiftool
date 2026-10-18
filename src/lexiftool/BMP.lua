--------------------------------------------------------------------------------
-- File:         lexiftool/BMP.lua
-- Ported from:  lib/Image/ExifTool/BMP.pm
--
-- Description:  Read BMP meta information
--
-- Revisions:    07/16/2005 - P. Harvey Created
--
-- References:   1) http://www.fortunecity.com/skyscraper/windows/364/bmpffrmt.html
--               2) http://www.fourcc.org/rgb.php
--               3) https://msdn.microsoft.com/en-us/library/dd183381(v=vs.85).aspx
--
-- Port notes:   read subset: ProcessBMP and the Main/OS2/Extra tables.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local subst, ord = perl.subst, perl.ord
local pack, unpack = perl.pack, perl.unpack
local num = perl.num
local str = perl.str

local BMP = {}

-- conversions for fixed-point 2.30 format values
local function fixed2_30ValueConv(_self, val)
    local out = {}
    for v in str(val):gmatch('[^ \t\n\r\f\v]+') do out[#out + 1] = tonumber(v) / 0x40000000 end
    return table.concat(out, ' ')
end
local function fixed2_30PrintConv(_self, val)
    local out = {}
    for v in str(val):gmatch('[^ \t\n\r\f\v]+') do out[#out + 1] = sprintf('%.6f', tonumber(v)) end
    return table.concat(out, ' ')
end

-- BMP chunks
BMP.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = [[
        There really isn't much meta information in a BMP file as such, just a bit
        of image related information.
    ]],
    [0] = {
        Name = 'BMPVersion',
        Format = 'int32u',
        Notes = [[
            this is actually the size of the BMP header, but used to determine the BMP
            version
        ]],
        RawConv = function(self, val) self.BMPVersion = val; return val end,
        PrintConv = {
            [40] = 'Windows V3',
            [68] = 'AVI BMP structure?', -- (seen in AVI movies from some Casio and Nikon cameras)
            [108] = 'Windows V4',
            [124] = 'Windows V5',
        },
    },
    [4] = {
        Name = 'ImageWidth',
        Format = 'int32u',
    },
    [8] = {
        Name = 'ImageHeight',
        Format = 'int32s', -- (negative when stored in top-to-bottom order)
        ValueConv = function(_self, val) return math.abs(val) end,
    },
    [12] = {
        Name = 'Planes',
        Format = 'int16u',
    },
    [14] = {
        Name = 'BitDepth',
        Format = 'int16u',
    },
    [16] = {
        Name = 'Compression',
        Format = 'int32u',
        RawConv = function(self, val) self.BMPCompression = val; return val end,
        -- (formatted as string[4] for some values in AVI images)
        ValueConv = function(_self, val)
            if val > 256 then return (unpack('A4', pack('V', val))) end
            return val
        end,
        PrintConv = {
            [0] = 'None',
            [1] = '8-Bit RLE',
            [2] = '4-Bit RLE',
            [3] = 'Bitfields',
            [4] = 'JPEG', --2
            [5] = 'PNG', --2
            -- pass through ASCII video compression codec ID's
            OTHER = function(val)
                -- convert non-ascii characters
                val = subst(val, [[([\0-\x1f\x7f-\xff])]], function(c) return sprintf('\\x%.2x', ord(c)) end, 'g')
                return val
            end,
        },
    },
    [20] = {
        Name = 'ImageLength',
        Format = 'int32u',
        RawConv = function(self, val) self.BMPImageLength = val; return val end,
    },
    [24] = {
        Name = 'PixelsPerMeterX',
        Format = 'int32u',
    },
    [28] = {
        Name = 'PixelsPerMeterY',
        Format = 'int32u',
    },
    [32] = {
        Name = 'NumColors',
        Format = 'int32u',
        PrintConv = function(_self, val) return val ~= 0 and val or 'Use BitDepth' end,
    },
    [36] = {
        Name = 'NumImportantColors',
        Format = 'int32u',
        Hook = function(self, _format, _varSize, size) -- (the rest is invalid for AVI BMP's)
            if num(self.BMPVersion) == 68 then return size end
        end,
        PrintConv = function(_self, val) return val ~= 0 and val or 'All' end,
    },
    [40] = {
        Name = 'RedMask',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf('0x%.8x', val) end,
    },
    [44] = {
        Name = 'GreenMask',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf('0x%.8x', val) end,
    },
    [48] = {
        Name = 'BlueMask',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf('0x%.8x', val) end,
    },
    [52] = {
        Name = 'AlphaMask',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf('0x%.8x', val) end,
    },
    [56] = {
        Name = 'ColorSpace',
        Format = 'undef[4]',
        RawConv = function(self, val)
            self.BMPColorSpace = val:find('\0', 1, true) and self.Get32u(val, 0) or val
            return val
        end,
        PrintConv = {
            [0] = 'Calibrated RGB',
            [1] = 'Device RGB',
            [2] = 'Device CMYK',
            LINK = 'Linked Color Profile',
            MBED = 'Embedded Color Profile',
            sRGB = 'sRGB',
            ['Win '] = 'Windows Color Space',
        },
    },
    [60] = {
        Name = 'RedEndpoint',
        Condition = function(self) return str(self.BMPColorSpace) == '0' end,
        Format = 'int32u[3]',
        ValueConv = fixed2_30ValueConv,
        PrintConv = fixed2_30PrintConv,
    },
    [72] = {
        Name = 'GreenEndpoint',
        Condition = function(self) return str(self.BMPColorSpace) == '0' end,
        Format = 'int32u[3]',
        ValueConv = fixed2_30ValueConv,
        PrintConv = fixed2_30PrintConv,
    },
    [84] = {
        Name = 'BlueEndpoint',
        Condition = function(self) return str(self.BMPColorSpace) == '0' end,
        Format = 'int32u[3]',
        ValueConv = fixed2_30ValueConv,
        PrintConv = fixed2_30PrintConv,
    },
    [96] = {
        Name = 'GammaRed',
        Condition = function(self) return str(self.BMPColorSpace) == '0' end,
        Format = 'fixed32u',
    },
    [100] = {
        Name = 'GammaGreen',
        Condition = function(self) return str(self.BMPColorSpace) == '0' end,
        Format = 'fixed32u',
    },
    [104] = {
        Name = 'GammaBlue',
        Condition = function(self) return str(self.BMPColorSpace) == '0' end,
        Format = 'fixed32u',
    },
    [108] = {
        Name = 'RenderingIntent',
        Format = 'int32u',
        PrintConv = {
            [1] = 'Graphic (LCS_GM_BUSINESS)',
            [2] = 'Proof (LCS_GM_GRAPHICS)',
            [4] = 'Picture (LCS_GM_IMAGES)',
            [8] = 'Absolute Colorimetric (LCS_GM_ABS_COLORIMETRIC)',
        },
    },
    [112] = {
        Name = 'ProfileDataOffset',
        Condition = function(self)
            return str(self.BMPColorSpace) == 'LINK' or str(self.BMPColorSpace) == 'MBED'
        end,
        Format = 'int32u',
        RawConv = function(self, val) self.BMPProfileOffset = val; return val end,
    },
    [116] = {
        Name = 'ProfileSize',
        Condition = function(self)
            return str(self.BMPColorSpace) == 'LINK' or str(self.BMPColorSpace) == 'MBED'
        end,
        Format = 'int32u',
        RawConv = function(self, val) self.BMPProfileSize = val; return val end,
    },
    -- 120 - reserved
}

-- OS/2 12-byte bitmap header (ref http://www.fileformat.info/format/bmp/egff.htm)
BMP.OS2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = 'Information extracted from OS/2-format BMP images.',
    [0] = {
        Name = 'BMPVersion',
        Format = 'int32u',
        Notes = 'again, the header size is used to determine the BMP version',
        PrintConv = {
            [12] = 'OS/2 V1',
            [64] = 'OS/2 V2',
        },
    },
    [4] = { Name = 'ImageWidth', Format = 'int16u' },
    [6] = { Name = 'ImageHeight', Format = 'int16u' },
    [8] = { Name = 'Planes', Format = 'int16u' },
    [10] = { Name = 'BitDepth', Format = 'int16u' },
}

BMP.Extra = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = 'Extra information extracted from some BMP images.',
    VARS = { ID_FMT = 'none' },
    LinkedProfileName = {},
    ICC_Profile = { SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' } },
    EmbeddedJPG = {
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    EmbeddedPNG = {
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
}

--------------------------------------------------------------------------------
-- Extract metadata from a BMP image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid BMP file
--------------------------------------------------------------------------------
function BMP.ProcessBMP(et, dirInfo)
    local raf = dirInfo.RAF

    -- verify this is a valid BMP file
    local n, buff = raf:Read(18)
    if n ~= 18 or buff:sub(1, 2) ~= 'BM' then return 0 end
    ExifTool.SetByteOrder('II')
    local len = ExifTool.Get32u(buff, 14)
    -- len = v1:12, v4:108, v5:124
    if not (len == 12 or len == 16 or (len >= 40 and len < 1000000)) then return 0 end
    if not raf:Seek(-4, 1) then return 0 end
    local n2, hdr = raf:Read(len)
    if n2 ~= len then return 0 end
    et:SetFileType() -- set the FileType tag

    -- process the BMP header
    local tagTablePtr
    if len == 12 or len == 16 or len == 64 then -- old OS/2 format BMP
        tagTablePtr = et:GetTagTable('lexiftool.BMP.OS2')
    else
        tagTablePtr = et:GetTagTable('lexiftool.BMP.Main')
    end
    et:ProcessDirectory({ DataPt = hdr, DirStart = 0, DirLen = #hdr }, tagTablePtr)

    -- extract any embedded images
    local extraTable = et:GetTagTable('lexiftool.BMP.Extra')
    if et.BMPCompression and et.BMPImageLength and
        (et.BMPCompression == 4 or et.BMPCompression == 5) then
        local tag = et.BMPCompression == 4 and 'EmbeddedJPG' or 'EmbeddedPNG'
        local val = et.ExtractBinary(et, raf:Tell(), et.BMPImageLength, tag)
        if val then et:HandleTag(extraTable, tag, val) end
    end

    -- process profile data if it exists (v5 header only)
    if len == 124 and et.BMPProfileOffset then
        local pos = et.BMPProfileOffset + 14 -- (note the 14-byte shift!)
        local size = et.BMPProfileSize
        local n3, pbuff
        if raf:Seek(pos, 0) then n3, pbuff = raf:Read(size) end
        if n3 == size then
            local tag
            if et.BMPColorSpace == 'LINK' then
                pbuff = pbuff:gsub('\0+$', '') -- remove null terminator(s)
                pbuff = et:Decode(pbuff, 'Latin') -- convert from Latin
                tag = 'LinkedProfileName'
            else
                tag = 'ICC_Profile'
            end
            et:HandleTag(extraTable, tag, pbuff, { Size = size, DataPos = pos })
        else
            et:Warn('Error loading profile data', 1)
        end
    end
    return 1
end

return BMP
