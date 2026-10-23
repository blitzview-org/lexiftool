--------------------------------------------------------------------------------
-- File:         lexiftool/DPX.lua
-- Ported from:  lib/Image/ExifTool/DPX.pm
--
-- Description:  Read DPX meta information
--
-- Revisions:    2013-09-19 - P. Harvey created
--
-- References:   1) http://www.cineon.com/ff_draft.php
--               2) Harry Mallon private communication
--
-- Port notes:   complete: ProcessDPX and the Main table.  `AspectRatio`'s
--               PrintConv calls Writer.Rationalize (Writer.pl's `Rationalize`,
--               autoloaded upstream).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf
local isMatch = require('lexiftool.perl').isMatch
local split = require('lexiftool.perl').split
local join = require('lexiftool.perl').join
local num = require('lexiftool.perl').num

local DPX = {}

-- DPX tags
DPX.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = 'Tags extracted from DPX (Digital Picture Exchange) images.',
    [0]   = { Name = 'ByteOrder',     Format = 'undef[4]', PrintConv = { SDPX = 'Big-endian', XPDS = 'Little-endian' } },
    [8]   = { Name = 'HeaderVersion', Format = 'string[8]' },
    -- [24] = { Name = 'GenericHeaderSize', Format = 'int32u' }, -- = 1664
    -- [28] = { Name = 'IndustryStandardHeaderSize', Format = 'int32u' }, -- = 384
    [16]  = { Name = 'DPXFileSize',   Format = 'int32u' },
    [20]  = { Name = 'DittoKey',      Format = 'int32u', PrintConv = { [0] = 'Same', [1] = 'New' } },
    [36]  = { Name = 'ImageFileName', Format = 'string[100]' },
    [136] = {
        Name = 'CreateDate',
        Format = 'string[24]',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return (val:gsub('(%d%d%d%d:%d%d:%d%d):', '%1 ', 1)) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [160] = { Name = 'Creator',       Format = 'string[100]', Groups = { [2] = 'Author' } },
    [260] = { Name = 'Project',       Format = 'string[200]' },
    [460] = { Name = 'Copyright',     Format = 'string[200]', Groups = { [2] = 'Author' } },
    [660] = { Name = 'EncryptionKey', Format = 'int32u', PrintConv = function(_self, val) return sprintf('%.8x', val) end },
    [768] = {
        Name = 'Orientation',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Horizontal (normal)',
            [1] = 'Mirror vertical',
            [2] = 'Mirror horizontal',
            [3] = 'Rotate 180',
            [4] = 'Mirror horizontal and rotate 270 CW',
            [5] = 'Rotate 90 CW',
            [6] = 'Rotate 270 CW',
            [7] = 'Mirror horizontal and rotate 90 CW',
        },
    },
    [770] = { Name = 'ImageElements', Format = 'int16u' },
    [772] = { Name = 'ImageWidth',    Format = 'int32u' },
    [776] = { Name = 'ImageHeight',   Format = 'int32u' },
    [780] = { Name = 'DataSign',      Format = 'int32u', PrintConv = { [0] = 'Unsigned', [1] = 'Signed' } },
    [800] = {
        Name = 'ComponentsConfiguration',
        Format = 'int8u',
        PrintConv = {
            [0] = 'User-defined single component',
            [1] = 'Red (R)',
            [2] = 'Green (G)',
            [3] = 'Blue (B)',
            [4] = 'Alpha (matte)',
            [6] = 'Luminance (Y)',
            [7] = 'Chrominance (Cb, Cr, subsampled by two)',
            [8] = 'Depth (Z)',
            [9] = 'Composite video',
            [50] = 'R, G, B',
            [51] = 'R, G, B, Alpha',
            [52] = 'Alpha, B, G, R',
            [100] = 'Cb, Y, Cr, Y (4:2:2)',
            [101] = 'Cb, Y, A, Cr, Y, A (4:2:2:4)',
            [102] = 'Cb, Y, Cr (4:4:4)',
            [103] = 'Cb, Y, Cr, A (4:4:4:4)',
            [150] = 'User-defined 2 component element',
            [151] = 'User-defined 3 component element',
            [152] = 'User-defined 4 component element',
            [153] = 'User-defined 5 component element',
            [154] = 'User-defined 6 component element',
            [155] = 'User-defined 7 component element',
            [156] = 'User-defined 8 component element',
        },
    },
    [801] = { --#2
        Name = 'TransferCharacteristic',
        Format = 'int8u',
        PrintConv = {
            [0] = 'User-defined',
            [1] = 'Printing density',
            [2] = 'Linear',
            [3] = 'Logarithmic',
            [4] = 'Unspecified video',
            [5] = 'SMPTE 274M',
            [6] = 'ITU-R 709-4',
            [7] = 'ITU-R 601-5 system B or G (625)',
            [8] = 'ITU-R 601-5 system M (525)',
            [9] = 'Composite video (NTSC)',
            [10] = 'Composite video (PAL)',
            [11] = 'Z (depth) - linear',
            [12] = 'Z (depth) - homogeneous',
            [13] = 'SMPTE ADX',
            [14] = 'ITU-R 2020 NCL',
            [15] = 'ITU-R 2020 CL',
            [16] = 'IEC 61966-2-4 xvYCC',
            [17] = 'ITU-R 2100 NCL/PQ',
            [18] = 'ITU-R 2100 ICtCp/PQ',
            [19] = 'ITU-R 2100 NCL/HLG',
            [20] = 'ITU-R 2100 ICtCp/HLG',
            [21] = 'RP 431-2:2011 Gama 2.6',
            [22] = 'IEC 61966-2-1 sRGB',
        },
    },
    [802] = { --#2
        Name = 'ColorimetricSpecification',
        Format = 'int8u',
        PrintConv = {
            [0] = 'User-defined',
            [1] = 'Printing density',
            [4] = 'Unspecified video',
            [5] = 'SMPTE 274M',
            [6] = 'ITU-R 709-4',
            [7] = 'ITU-R 601-5 system B or G (625)',
            [8] = 'ITU-R 601-5 system M (525)',
            [9] = 'Composite video (NTSC)',
            [10] = 'Composite video (PAL)',
            [13] = 'SMPTE ADX',
            [14] = 'ITU-R 2020',
            [15] = 'P3D65',
            [16] = 'P3DCI',
            [17] = 'P3D60',
            [18] = 'ACES',
        },
    },
    [803] = { Name = 'BitDepth', Format = 'int8u' },
    [820] = { Name = 'ImageDescription',   Format = 'string[32]' },
    [892] = { Name = 'Image2Description',  Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    [964] = { Name = 'Image3Description',  Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    [1036] = { Name = 'Image4Description', Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    [1108] = { Name = 'Image5Description', Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    [1180] = { Name = 'Image6Description', Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    [1252] = { Name = 'Image7Description', Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    [1324] = { Name = 'Image8Description', Format = 'string[32]', RawConv = function(_self, val) return val:find('[^\255]') and val or nil end },
    -- [1408] = { Name = 'XOffset',           Format = 'int32u' },
    -- [1412] = { Name = 'YOffset',           Format = 'int32u' },
    -- [1416] = { Name = 'XCenter',           Format = 'float' },
    -- [1420] = { Name = 'YCenter',           Format = 'float' },
    -- [1424] = { Name = 'XOriginalSize',     Format = 'int32u' },
    -- [1428] = { Name = 'YOriginalSize',     Format = 'int32u' },
    [1432] = { Name = 'SourceFileName',   Format = 'string[100]' },
    [1532] = { Name = 'SourceCreateDate', Format = 'string[24]' },
    [1556] = { Name = 'InputDeviceName',  Format = 'string[32]' },
    [1588] = { Name = 'InputDeviceSerialNumber', Format = 'string[32]' },
    -- [1620] = { Name = 'Border',            Format = 'int16u[4]' },
    [1628] = {
        Name = 'AspectRatio',
        Format = 'int32u[2]',
        RawConv = function(_self, val)
            if isMatch(val, [[4294967295]]) then return nil end
            return val
        end, -- ignore undefined values
        PrintConv = function(_self, val)
            if val == '0 0' then return 'undef' end
            if isMatch(val, [[ 0$]]) then return 'inf' end
            local a = split(' ', val)
            return join(':', { require('lexiftool.Writer').Rationalize(num(a[1]) / num(a[2])) })
        end,
    },
    [1724] = { Name = 'OriginalFrameRate', Format = 'float' },
    [1728] = { --#2
        Name = 'ShutterAngle',
        Format = 'float',
        -- (one line upstream; the Lua closure does not fit the 160-column limit)
        RawConv = function(_self, val)
            if isMatch(val, [[\d]]) and not isMatch(val, [[(?i)nan]]) then return val end
            return nil
        end,
    },
    [1732] = { Name = 'FrameID',           Format = 'string[32]' },
    [1764] = { Name = 'SlateInformation',  Format = 'string[100]' },
    [1920] = { Name = 'TimeCode',          Format = 'int32u' }, --#2
    [1940] = { --#2
        Name = 'FrameRate',
        Format = 'float',
        -- (one line upstream; the Lua closure does not fit the 160-column limit)
        RawConv = function(_self, val)
            if isMatch(val, [[\d]]) and not isMatch(val, [[(?i)nan]]) then return val end
            return nil
        end,
    },
    [1972] = { Name = 'Reserved5',         Format = 'string[76]', Unknown = 1 },
    [2048] = { Name = 'UserID',            Format = 'string[32]' },
}

--------------------------------------------------------------------------------
-- Extract EXIF information from a DPX image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid DPX file
--------------------------------------------------------------------------------
function DPX.ProcessDPX(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(2080)
    if n ~= 2080 then return 0 end
    -- verify this is a valid DPX file
    local sig = buff:sub(1, 4)
    if sig ~= 'SDPX' and sig ~= 'XPDS' then return 0 end
    ExifTool.SetByteOrder(sig == 'SDPX' and 'MM' or 'II')
    et:SetFileType() -- set the FileType tag
    local hdrLen = ExifTool.Get32u(buff, 24) + ExifTool.Get32u(buff, 28)
    if hdrLen ~= 2048 then et:Warn('Unexpected DPX header length (' .. hdrLen .. ')') end
    local subdirInfo = { DataPt = buff, DirStart = 0, DirLen = #buff }
    local tagTablePtr = et:GetTagTable('lexiftool.DPX.Main')
    et:ProcessDirectory(subdirInfo, tagTablePtr)

    return 1
end

return DPX
