--------------------------------------------------------------------------------
-- File:         lexiftool/PICT.lua
-- Ported from:  lib/Image/ExifTool/PICT.pm
--
-- Description:  Read PICT meta information
--
-- Revisions:    10/10/2005 - P. Harvey Created
--
-- Notes:        Extraction of PICT opcodes is still experimental
--
-- - size difference in PixPat color table?? (imagemagick reads only 1 long per entry)
-- - other differences in the way imagemagick reads 16-bit images
--
-- References:   1) http://developer.apple.com/documentation/mac/QuickDraw/QuickDraw-2.html
--               2) http://developer.apple.com/documentation/QuickTime/INMAC/QT/iqImageCompMgr.a.htm
--
-- Port notes:   Complete port of PICT.pm: every table, lookup and sub, in
--               upstream order.  Deviations forced by Lua:
--               - The count expressions of %structs ('binary[$val{dataSize}]')
--                 and the GetPixData code refs are Perl source that upstream
--                 runs through `eval`; Lua has no eval for them, so
--                 evalPict maps each expression string, verbatim, to a Lua
--                 function of (%val, $raf).
--               - A code ref format (`\ 'GetPixData(...)'`) is
--                 { ref = 'SCALAR', value = '...' }, as are binary values.
--               - ReadValue's list result for a count > 1 is joined with
--                 spaces, as upstream's scalar-context ReadValue.
--               - The unused %commentKind lookup is carried verbatim.
--------------------------------------------------------------------------------
-- luacheck: ignore 211/commentKind

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local isMatch = perl.isMatch
local subst = perl.subst
local unpack = perl.unpack
local ord = perl.ord
local substr = perl.substr
local length = perl.length
local sprintf = perl.sprintf
local truthy = perl.truthy
local int = perl.int
local str = perl.str
local ReadValue = ExifTool.ReadValue
local HexDump = ExifTool.HexDump
local SetByteOrder = ExifTool.SetByteOrder
local GetFixed32s = ExifTool.GetFixed32s
local GetTagTable = ExifTool.GetTagTable

local PICT = {}

-- (upstream's predeclaration; the sub below assigns to it)
local ReadPictValue
local GetPixData

local vers, extended    -- PICT version number, and extended flag
local verbose, out, indent -- used in verbose mode

-- ranges of reserved opcodes.
-- opcodes at the start of each range must be defined in the tag table
local reserved = {
    0x0017, 0x0019, 0x0024, 0x0027, 0x0035, 0x0037, 0x003d, 0x003f,
    0x0045, 0x0047, 0x004d, 0x004f, 0x0055, 0x0057, 0x005d, 0x005f,
    0x0065, 0x0067, 0x006d, 0x006f, 0x0075, 0x0077, 0x007d, 0x007f,
    0x0085, 0x0087, 0x008d, 0x008f, 0x0092, 0x0097, 0x00a2, 0x00af,
    0x00b0, 0x00cf, 0x00d0, 0x00fe, 0x0100, 0x01ff, 0x0300, 0x0bfe,
    0x0c01, 0x7eff, 0x7f00, 0x7fff, 0x8000, 0x80ff, 0x8100, 0x81ff,
    0x8201, 0xffff,
}

-- Apple data structures in PICT images
local structs = {
    Arc = {
        'rect', 'Rect',
        'startAng', 'int16s',
        'arcAng', 'int16s',
    },
    BitMap = {
        -- (no baseAddr)
        'rowBytes', 'int16u',
        'bounds', 'Rect',
    },
    -- BitsRect data for PICT version 1
    BitsRect1 = {
        'bitMap', 'BitMap',
        'srcRect', 'Rect',
        'dstRect', 'Rect',
        'mode', 'int16u',
        'dataSize', 'int16u',
        'bitData', 'binary[$val{dataSize}]',
    },
    -- BitsRect data for PICT version 2
    BitsRect2 = {
        'pixMap', 'PixMap',
        'colorTable', 'ColorTable',
        'srcRect', 'Rect',
        'dstRect', 'Rect',
        'mode', 'int16u',
        'pixData', { ref = 'SCALAR', value = 'GetPixData($val{pixMap}, $raf)' },
    },
    -- BitsRgn data for PICT version 1
    BitsRgn1 = {
        'bitMap', 'BitMap',
        'srcRect', 'Rect',
        'dstRect', 'Rect',
        'mode', 'int16u',
        'maskRgn', 'Rgn',
        'dataSize', 'int16u',
        'bitData', 'binary[$val{dataSize}]',
    },
    -- BitsRgn data for PICT version 2
    BitsRgn2 = {
        'pixMap', 'PixMap',
        'colorTable', 'ColorTable',
        'srcRect', 'Rect',
        'dstRect', 'Rect',
        'mode', 'int16u',
        'maskRgn', 'Rgn',
        'pixData', { ref = 'SCALAR', value = 'GetPixData($val{pixMap}, $raf)' },
    },
    ColorSpec = {
        'value', 'int16u',
        'rgb', 'RGBColor',
    },
    ColorTable = {
        'ctSeed', 'int32u',
        'ctFlags', 'int16u',
        'ctSize', 'int16u',
        'ctTable', 'ColorSpec[$val{ctSize}+1]',
    },
    -- http://developer.apple.com/documentation/QuickTime/INMAC/QT/iqImageCompMgr.a.htm
    CompressedQuickTime = {
        'size', 'int32u',   -- size NOT including size word
        'version', 'int16u',
        'matrix', 'int32u[9]',
        'matteSize', 'int32u',
        'matteRect', 'Rect',
        'mode', 'int16u',
        'srcRect', 'Rect',
        'accuracy', 'int32u',
        'maskSize', 'int32u',
        'matteDescr', 'Int32uData[$val{matteSize} ? 1 : 0]',
        'matteData', 'int8u[$val{matteSize}]',
        'maskRgn', 'int8u[$val{maskSize}]',
        'imageDescr', 'ImageDescription',
        -- size should be $val{imageDescr}->{dataSize}, but this is unreliable
        'imageData', [=[binary[$val{size} - 68 - $val{maskSize} - $val{imageDescr}->{size} -
                    ($val{matteSize} ? $val{mattSize} + $val{matteDescr}->{size} : 0)]
        ]=],
    },
    DirectBitsRect = {
        'baseAddr', 'int32u',
        'pixMap', 'PixMap',
        'srcRect', 'Rect',
        'dstRect', 'Rect',
        'mode', 'int16u',
        'pixData', { ref = 'SCALAR', value = 'GetPixData($val{pixMap}, $raf)' },
    },
    DirectBitsRgn = {
        'baseAddr', 'int32u',
        'pixMap', 'PixMap',
        'srcRect', 'Rect',
        'dstRect', 'Rect',
        'mode', 'int16u',
        'maskRgn', 'Rgn',
        'pixData', { ref = 'SCALAR', value = 'GetPixData($val{pixMap}, $raf)' },
    },
    -- http://developer.apple.com/technotes/qd/qd_01.html
    FontName = {
        'size', 'int16u',   -- size NOT including size word
        'oldFontID', 'int16u',
        'nameLen', 'int8u',
        'fontName', 'string[$val{nameLen}]',
        'padding', 'binary[$val{size} - $val{nameLen} - 3]',
    },
    -- http://developer.apple.com/documentation/QuickTime/APIREF/imagedescription.htm
    ImageDescription = {
        'size', 'int32u',   -- size INCLUDING size word
        'cType', 'string[4]',
        'res1', 'int32u',
        'res2', 'int16u',
        'dataRefIndex', 'int16u',
        'version', 'int16u',
        'revision', 'int16u',
        'vendor', 'string[4]',
        'temporalQuality', 'int32u',
        'quality', 'int32u',
        'width', 'int16u',
        'height', 'int16u',
        'hRes', 'fixed32u',
        'vRes', 'fixed32u',
        'dataSize', 'int32u',
        'frameCount', 'int16u',
        'nameLen', 'int8u',
        'compressor', 'string[31]',
        'depth', 'int16u',
        'clutID', 'int16u',
        'clutData', 'binary[$val{size}-86]',
    },
    Int8uText = {
        'val', 'int8u',
        'count', 'int8u',
        'text', 'string[$val{count}]',
    },
    Int8u2Text = {
        'val', 'int8u[2]',
        'count', 'int8u',
        'text', 'string[$val{count}]',
    },
    Int16Data = {
        'size', 'int16u',   -- size NOT including size word
        'data', 'int8u[$val{size}]',
    },
    Int32uData = {
        'size', 'int32u',   -- size NOT including size word
        'data', 'int8u[$val{size}]',
    },
    LongComment = {
        'kind', 'int16u',
        'size', 'int16u',   -- size of data only
        'data', 'binary[$val{size}]',
    },
    PixMap = {
        -- Note: does not contain baseAddr
        -- (except for DirectBits opcodes in which it is loaded separately)
        'rowBytes', 'int16u',
        'bounds', 'Rect',
        'pmVersion', 'int16u',
        'packType', 'int16u',
        'packSize', 'int32u',
        'hRes', 'fixed32s',
        'vRes', 'fixed32s',
        'pixelType', 'int16u',
        'pixelSize', 'int16u',
        'cmpCount', 'int16u',
        'cmpSize', 'int16u',
        'planeBytes', 'int32u',
        'pmTable', 'int32u',
        'pmReserved', 'int32u',
    },
    PixPat = {
        'patType', 'int16u',    -- 1 = non-dithered, 2 = dithered
        'pat1Data', 'int8u[8]',
        -- dithered PixPat has RGB entry
        'RGB', 'RGBColor[$val{patType} == 2 ? 1 : 0]',
        -- non-dithered PixPat has other stuff instead
        'nonDithered', 'PixPatNonDithered[$val{patType} == 2 ? 0 : 1]',
    },
    PixPatNonDithered = {
        'pixMap', 'PixMap',
        'colorTable', 'ColorTable',
        'pixData', { ref = 'SCALAR', value = 'GetPixData($val{pixMap}, $raf)' },
    },
    Point = {
        'v', 'int16s',
        'h', 'int16s',
    },
    PointText = {
        'txLoc', 'Point',
        'count', 'int8u',
        'text', 'string[$val{count}]',
    },
    Polygon = {
        'polySize', 'int16u',
        'polyBBox', 'Rect',
        'polyPoints', 'int16u[($val{polySize}-10)/2]',
    },
    Rect = {
        'topLeft', 'Point',
        'botRight', 'Point',
    },
    RGBColor = {
        'red', 'int16u',
        'green', 'int16u',
        'blue', 'int16u',
    },
    Rgn = {
        'rgnSize', 'int16u',
        'rgnBBox', 'Rect',
        'data', 'int8u[$val{rgnSize}-10]',
    },
    ShortLine = {
        'pnLoc', 'Point',
        'dh', 'int8s',
        'dv', 'int8s',
    },
    -- http://developer.apple.com/documentation/QuickTime/INMAC/QT/iqImageCompMgr.a.htm
    UncompressedQuickTime = {
        'size', 'int32u',   -- size NOT including size word
        'version', 'int16u',
        'matrix', 'int32u[9]',
        'matteSize', 'int32u',
        'matteRect', 'Rect',
        'matteDescr', 'Int32uData[$val{matteSize} ? 1 : 0]',
        'matteData', 'binary[$val{matteSize}]',
        'subOpcodeData', '\n' .. [=[
            binary[ $val{size} - 50 -
                    ($val{matteSize} ? $val{mattSize} + $val{matteDescr}->{size} : 0)]
        ]=],
    },
}

-- (port: Perl's `eval` of the count expressions and code refs in %structs
--  above -- each upstream expression string maps to a Lua function of
--  (%val, $raf); an undefined hash element numifies to 0 as in Perl)
local function n(v) return v == nil and 0 or perl.num(v) end
-- luacheck: push no max line length
local evalPict = {
    ['$val{dataSize}'] = function(val) return n(val.dataSize) end,
    ['GetPixData($val{pixMap}, $raf)'] = function(val, raf) return GetPixData(val.pixMap, raf) end,
    ['$val{ctSize}+1'] = function(val) return n(val.ctSize) + 1 end,
    ['$val{matteSize} ? 1 : 0'] = function(val) return truthy(val.matteSize) and 1 or 0 end,
    ['$val{matteSize}'] = function(val) return n(val.matteSize) end,
    ['$val{maskSize}'] = function(val) return n(val.maskSize) end,
    ['$val{size} - 68 - $val{maskSize} - $val{imageDescr}->{size} -\n                    ($val{matteSize} ? $val{mattSize} + $val{matteDescr}->{size} : 0)'] = function(val)
        return n(val.size) - 68 - n(val.maskSize) - n(val.imageDescr.size) -
                    (truthy(val.matteSize) and n(val.mattSize) + n(val.matteDescr.size) or 0)
    end,
    ['$val{nameLen}'] = function(val) return n(val.nameLen) end,
    ['$val{size} - $val{nameLen} - 3'] = function(val) return n(val.size) - n(val.nameLen) - 3 end,
    ['$val{size}-86'] = function(val) return n(val.size) - 86 end,
    ['$val{count}'] = function(val) return n(val.count) end,
    ['$val{size}'] = function(val) return n(val.size) end,
    ['$val{patType} == 2 ? 1 : 0'] = function(val) return n(val.patType) == 2 and 1 or 0 end,
    ['$val{patType} == 2 ? 0 : 1'] = function(val) return n(val.patType) == 2 and 0 or 1 end,
    ['($val{polySize}-10)/2'] = function(val) return (n(val.polySize) - 10) / 2 end,
    ['$val{rgnSize}-10'] = function(val) return n(val.rgnSize) - 10 end,
    [' $val{size} - 50 -\n                    ($val{matteSize} ? $val{mattSize} + $val{matteDescr}->{size} : 0)'] = function(val)
        return n(val.size) - 50 -
                    (truthy(val.matteSize) and n(val.mattSize) + n(val.matteDescr.size) or 0)
    end,
}
-- luacheck: pop

-- PICT image opcodes
PICT.Main = {
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
The PICT format contains no true meta information, except for the possible
exception of the LongComment opcode.  By default, only ImageWidth,
ImageHeight and X/YResolution are extracted from a PICT image.  Tags in the
following table represent image opcodes.  Extraction of these tags is
experimental, and is only enabled with the Verbose or Unknown options.
    ]],
    [0x0000] = {
        Name = 'Nop',
        Description = 'No Operation',
        Format = 'null',
    },
    [0x0001] = {
        Name = 'ClipRgn',
        Description = 'Clipping Region',
        Format = 'Rgn',
    },
    [0x0002] = {
        Name = 'BkPat',
        Description = 'Background Pattern',
        Format = 'int8u[8]',
    },
    [0x0003] = {
        Name = 'TxFont',
        Description = 'Font Number',
        Format = 'int16u',
    },
    [0x0004] = {
        Name = 'TxFace',
        Description = 'Text Font Style',
        Format = 'int8u',
    },
    [0x0005] = {
        Name = 'TxMode',
        Description = 'Text Source Mode',
        Format = 'int16u',
    },
    [0x0006] = {
        Name = 'SpExtra',
        Description = 'Extra Space',
        Format = 'fixed32s',
    },
    [0x0007] = {
        Name = 'PnSize',
        Description = 'Pen Size',
        Format = 'Point',
    },
    [0x0008] = {
        Name = 'PnMode',
        Description = 'Pen Mode',
        Format = 'int16u',
    },
    [0x0009] = {
        Name = 'PnPat',
        Description = 'Pen Pattern',
        Format = 'int8u[8]',
    },
    [0x000a] = {
        Name = 'FillPat',
        Description = 'Fill Pattern',
        Format = 'int8u[8]',
    },
    [0x000b] = {
        Name = 'OvSize',
        Description = 'Oval Size',
        Format = 'Point',
    },
    [0x000c] = {
        Name = 'Origin',
        Format = 'Point',
    },
    [0x000d] = {
        Name = 'TxSize',
        Description = 'Text Size',
        Format = 'int16u',
    },
    [0x000e] = {
        Name = 'FgColor',
        Description = 'Foreground Color',
        Format = 'int32u',
    },
    [0x000f] = {
        Name = 'BkColor',
        Description = 'Background Color',
        Format = 'int32u',
    },
    [0x0010] = {
        Name = 'TxRatio',
        Description = 'Text Ratio',
        Format = 'Rect',
    },
    [0x0011] = {
        Name = 'VersionOp',
        Description = 'Version',
        Format = 'int8u',
    },
    [0x0012] = {
        Name = 'BkPixPat',
        Description = 'Background Pixel Pattern',
        Format = 'PixPat',
    },
    [0x0013] = {
        Name = 'PnPixPat',
        Description = 'Pen Pixel Pattern',
        Format = 'PixPat',
    },
    [0x0014] = {
        Name = 'FillPixPat',
        Description = 'Fill Pixel Pattern',
        Format = 'PixPat',
    },
    [0x0015] = {
        Name = 'PnLocHFrac',
        Description = 'Fractional Pen Position',
        Format = 'int16u',
    },
    [0x0016] = {
        Name = 'ChExtra',
        Description = 'Added Width for NonSpace Characters',
        Format = 'int16u',
    },
    [0x0017] = {
        Name = 'Reserved',
        Format = 'Unknown',
    },
    [0x001a] = {
        Name = 'RGBFgCol',
        Description = 'Foreground Color',
        Format = 'RGBColor',
    },
    [0x001b] = {
        Name = 'RGBBkCol',
        Description = 'Background Color',
        Format = 'RGBColor',
    },
    [0x001c] = {
        Name = 'HiliteMode',
        Description = 'Highlight Mode Flag',
        Format = 'null',
    },
    [0x001d] = {
        Name = 'HiliteColor',
        Description = 'Highlight Color',
        Format = 'RGBColor',
    },
    [0x001e] = {
        Name = 'DefHilite',
        Description = 'Use Default Highlight Color',
        Format = 'null',
    },
    [0x001f] = {
        Name = 'OpColor',
        Format = 'RGBColor',
    },
    [0x0020] = {
        Name = 'Line',
        Format = 'Rect',
    },
    [0x0021] = {
        Name = 'LineFrom',
        Format = 'Point',
    },
    [0x0022] = {
        Name = 'ShortLine',
        Format = 'ShortLine',
    },
    [0x0023] = {
        Name = 'ShortLineFrom',
        Format = 'int8u[2]',
    },
    [0x0024] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x0028] = {
        Name = 'LongText',
        Format = 'PointText',
    },
    [0x0029] = {
        Name = 'DHText',
        Format = 'Int8uText',
    },
    [0x002a] = {
        Name = 'DVText',
        Format = 'Int8uText',
    },
    [0x002b] = {
        Name = 'DHDVText',
        Format = 'Int8u2Text',
    },
    [0x002c] = {
        Name = 'FontName',
        Format = 'FontName',
    },
    [0x002d] = {
        Name = 'LineJustify',
        Format = 'int8u[10]',
    },
    [0x002e] = {
        Name = 'GlyphState',
        Format = 'int8u[8]',
    },
    [0x002f] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x0030] = {
        Name = 'FrameRect',
        Format = 'Rect',
    },
    [0x0031] = {
        Name = 'PaintRect',
        Format = 'Rect',
    },
    [0x0032] = {
        Name = 'EraseRect',
        Format = 'Rect',
    },
    [0x0033] = {
        Name = 'InvertRect',
        Format = 'Rect',
    },
    [0x0034] = {
        Name = 'FillRect',
        Format = 'Rect',
    },
    [0x0035] = {
        Name = 'Reserved',
        Format = 'Rect',
    },
    [0x0038] = {
        Name = 'FrameSameRect',
        Format = 'null',
    },
    [0x0039] = {
        Name = 'PaintSameRect',
        Format = 'null',
    },
    [0x003a] = {
        Name = 'EraseSameRect',
        Format = 'null',
    },
    [0x003b] = {
        Name = 'InvertSameRect',
        Format = 'null',
    },
    [0x003c] = {
        Name = 'FillSameRect',
        Format = 'null',
    },
    [0x003d] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x0040] = {
        Name = 'FrameRRect',
        Format = 'Rect',
    },
    [0x0041] = {
        Name = 'PaintRRect',
        Format = 'Rect',
    },
    [0x0042] = {
        Name = 'EraseRRect',
        Format = 'Rect',
    },
    [0x0043] = {
        Name = 'InvertRRect',
        Format = 'Rect',
    },
    [0x0044] = {
        Name = 'FillRRect',
        Format = 'Rect',
    },
    [0x0045] = {
        Name = 'Reserved',
        Format = 'Rect',
    },
    [0x0048] = {
        Name = 'FrameSameRRect',
        Format = 'null',
    },
    [0x0049] = {
        Name = 'PaintSameRRect',
        Format = 'null',
    },
    [0x004a] = {
        Name = 'EraseSameRRect',
        Format = 'null',
    },
    [0x004b] = {
        Name = 'InvertSameRRect',
        Format = 'null',
    },
    [0x004c] = {
        Name = 'FillSameRRect',
        Format = 'null',
    },
    [0x004d] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x0050] = {
        Name = 'FrameOval',
        Format = 'Rect',
    },
    [0x0051] = {
        Name = 'PaintOval',
        Format = 'Rect',
    },
    [0x0052] = {
        Name = 'EraseOval',
        Format = 'Rect',
    },
    [0x0053] = {
        Name = 'InvertOval',
        Format = 'Rect',
    },
    [0x0054] = {
        Name = 'FillOval',
        Format = 'Rect',
    },
    [0x0055] = {
        Name = 'Reserved',
        Format = 'Rect',
    },
    [0x0058] = {
        Name = 'FrameSameOval',
        Format = 'null',
    },
    [0x0059] = {
        Name = 'PaintSameOval',
        Format = 'null',
    },
    [0x005a] = {
        Name = 'EraseSameOval',
        Format = 'null',
    },
    [0x005b] = {
        Name = 'InvertSameOval',
        Format = 'null',
    },
    [0x005c] = {
        Name = 'FillSameOval',
        Format = 'null',
    },
    [0x005d] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x0060] = {
        Name = 'FrameArc',
        Format = 'Arc',
    },
    [0x0061] = {
        Name = 'PaintArc',
        Format = 'Arc',
    },
    [0x0062] = {
        Name = 'EraseArc',
        Format = 'Arc',
    },
    [0x0063] = {
        Name = 'InvertArc',
        Format = 'Arc',
    },
    [0x0064] = {
        Name = 'FillArc',
        Format = 'Arc',
    },
    [0x0065] = {
        Name = 'Reserved',
        Format = 'Arc',
    },
    [0x0068] = {
        Name = 'FrameSameArc',
        Format = 'Point',
    },
    [0x0069] = {
        Name = 'PaintSameArc',
        Format = 'Point',
    },
    [0x006a] = {
        Name = 'EraseSameArc',
        Format = 'Point',
    },
    [0x006b] = {
        Name = 'InvertSameArc',
        Format = 'Point',
    },
    [0x006c] = {
        Name = 'FillSameArc',
        Format = 'Point',
    },
    [0x006d] = {
        Name = 'Reserved',
        Format = 'int32u',
    },
    [0x0070] = {
        Name = 'FramePoly',
        Format = 'Polygon',
    },
    [0x0071] = {
        Name = 'PaintPoly',
        Format = 'Polygon',
    },
    [0x0072] = {
        Name = 'ErasePoly',
        Format = 'Polygon',
    },
    [0x0073] = {
        Name = 'InvertPoly',
        Format = 'Polygon',
    },
    [0x0074] = {
        Name = 'FillPoly',
        Format = 'Polygon',
    },
    [0x0075] = {
        Name = 'Reserved',
        Format = 'Polygon',
    },
    [0x0078] = {
        Name = 'FrameSamePoly',
        Format = 'null',
    },
    [0x0079] = {
        Name = 'PaintSamePoly',
        Format = 'null',
    },
    [0x007a] = {
        Name = 'EraseSamePoly',
        Format = 'null',
    },
    [0x007b] = {
        Name = 'InvertSamePoly',
        Format = 'null',
    },
    [0x007c] = {
        Name = 'FillSamePoly',
        Format = 'null',
    },
    [0x007d] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x0080] = {
        Name = 'FrameRgn',
        Format = 'Rgn',
    },
    [0x0081] = {
        Name = 'PaintRgn',
        Format = 'Rgn',
    },
    [0x0082] = {
        Name = 'EraseRgn',
        Format = 'Rgn',
    },
    [0x0083] = {
        Name = 'InvertRgn',
        Format = 'Rgn',
    },
    [0x0084] = {
        Name = 'FillRgn',
        Format = 'Rgn',
    },
    [0x0085] = {
        Name = 'Reserved',
        Format = 'Rgn',
    },
    [0x0088] = {
        Name = 'FrameSameRgn',
        Format = 'null',
    },
    [0x0089] = {
        Name = 'PaintSameRgn',
        Format = 'null',
    },
    [0x008a] = {
        Name = 'EraseSameRgn',
        Format = 'null',
    },
    [0x008b] = {
        Name = 'InvertSameRgn',
        Format = 'null',
    },
    [0x008c] = {
        Name = 'FillSameRgn',
        Format = 'null',
    },
    [0x008d] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x0090] = {
        Name = 'BitsRect',
        Description = 'CopyBits with Clipped Rectangle',
        Format = 'BitsRect#', -- (version-dependent format)
    },
    [0x0091] = {
        Name = 'BitsRgn',
        Description = 'CopyBits with Clipped Region',
        Format = 'BitsRgn#', -- (version-dependent format)
    },
    [0x0092] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x0098] = {
        Name = 'PackBitsRect',
        Description = 'Packed CopyBits with Clipped Rectangle',
        Format = 'BitsRect#', -- (version-dependent format)
    },
    [0x0099] = {
        Name = 'PackBitsRgn',
        Description = 'Packed CopyBits with Clipped Region',
        Format = 'BitsRgn#', -- (version-dependent format)
    },
    [0x009a] = {
        Name = 'DirectBitsRect',
        Format = 'DirectBitsRect',
    },
    [0x009b] = {
        Name = 'DirectBitsRgn',
        Format = 'DirectBitsRgn',
    },
    [0x009c] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x009d] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x009e] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x009f] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x00a0] = {
        Name = 'ShortComment',
        Format = 'int16u',
    },
    [0x00a1] = {
        -- this list for documentation only [currently not extracted]
        {
            -- (not actually a full Photohop IRB record it appears, but it does start
            --  with '8BIM', and does contain resolution information at offset 0x0a)
            Name = 'LongComment', -- kind = 498
            Format = 'LongComment',
            SubDirectory = { TagTable = 'lexiftool.Photoshop.Main' },
        },
        {
            Name = 'LongComment', -- kind = 224
            Format = 'LongComment',
            SubDirectory = {
                TagTable = 'lexiftool.ICC_Profile.Main',
                Start = function(_self, _val, start) return start + 4 end,
            },
        },
    },
    [0x00a2] = {
        Name = 'Reserved',
        Format = 'Int16Data',
    },
    [0x00b0] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x00d0] = {
        Name = 'Reserved',
        Format = 'Int32uData',
    },
    [0x00ff] = {
        Name = 'OpEndPic',
        Description = 'End of picture',
        Format = 'null', -- 2 for version 2!?
    },
    [0x0100] = {
        Name = 'Reserved',
        Format = 'int16u',
    },
    [0x0200] = {
        Name = 'Reserved',
        Format = 'int32u',
    },
    [0x02ff] = {
        Name = 'Version',
        Description = 'Version number of picture',
        Format = 'int16u',
    },
    [0x0300] = {
        Name = 'Reserved',
        Format = 'int16u',
    },
    [0x0bff] = {
        Name = 'Reserved',
        Format = 'int8u[22]',
    },
    [0x0c00] = {
        Name = 'HeaderOp',
        Format = 'int16u[12]',
    },
    [0x0c01] = {
        Name = 'Reserved',
        Format = 'int8u[24]',
    },
    [0x7f00] = {
        Name = 'Reserved',
        Format = 'int8u[254]',
    },
    [0x8000] = {
        Name = 'Reserved',
        Format = 'null',
    },
    [0x8100] = {
        Name = 'Reserved',
        Format = 'Int32uData',
    },
    [0x8200] = {
        Name = 'CompressedQuickTime',
        Format = 'CompressedQuickTime',
    },
    [0x8201] = {
        Name = 'UncompressedQuickTime',
        Format = 'Int32uData',
    },
    [0xffff] = {
        Name = 'Reserved',
        Format = 'Int32uData',
    },
}

-- picture comment 'kind' codes
-- http://developer.apple.com/technotes/qd/qd_10.html
local commentKind = {
    [150] = 'TextBegin',
    [151] = 'TextEnd',
    [152] = 'StringBegin',
    [153] = 'StringEnd',
    [154] = 'TextCenter',
    [155] = 'LineLayoutOff',
    [156] = 'LineLayoutOn',
    [157] = 'ClientLineLayout',
    [160] = 'PolyBegin',
    [161] = 'PolyEnd',
    [163] = 'PolyIgnore',
    [164] = 'PolySmooth',
    [165] = 'PolyClose',
    [180] = 'DashedLine',
    [181] = 'DashedStop',
    [182] = 'SetLineWidth',
    [190] = 'PostScriptBegin',
    [191] = 'PostScriptEnd',
    [192] = 'PostScriptHandle',
    [193] = 'PostScriptFile',
    [194] = 'TextIsPostScript',
    [195] = 'ResourcePS',
    [196] = 'PSBeginNoSave',
    [197] = 'SetGrayLevel',
    [200] = 'RotateBegin',
    [201] = 'RotateEnd',
    [202] = 'RotateCenter',
    [210] = 'FormsPrinting',
    [211] = 'EndFormsPrinting',
    [224] = '<ICC Profile>',
    [498] = '<Photoshop Data>',
    [1000] = 'BitMapThinningOff',
    [1001] = 'BitMapThinningOn',
}

--------------------------------------------------------------------------------
-- Get PixData data
-- Inputs: 0) reference to PixMap, 1) RAF reference
-- Returns: reference to PixData or undef on error
function GetPixData(pixMap, raf)
    local packType = pixMap.packType
    local rowBytes = pixMap.rowBytes & 0x3fff   -- remove flags bits
    local height = pixMap.bounds.botRight.v -
                   pixMap.bounds.topLeft.v
    local data, size, buff, n_

    if packType == 1 or rowBytes < 8 then   -- unpacked data
        size = rowBytes * height
        n_, data = raf:Read(size)
        if n_ ~= size then return nil end
    elseif packType == 2 then               -- pad byte dropped
        size = int(rowBytes * height * 3 / 4 + 0.5)
        n_, data = raf:Read(size)
        if n_ ~= size then return nil end
    else
        data = ''
        for _ = 0, height - 1 do
            if rowBytes > 250 then
                n_, buff = raf:Read(2)
                if n_ ~= 2 then return nil end
                size = unpack('n', buff)
            else
                n_, buff = raf:Read(1)
                if n_ ~= 1 then return nil end
                size = unpack('C', buff)
            end
            data = data .. buff
            n_, buff = raf:Read(size)
            if n_ ~= size then return nil end
            data = data .. buff
        end
    end
    return { ref = 'SCALAR', value = data }
end
PICT.GetPixData = GetPixData

--------------------------------------------------------------------------------
-- Read value from PICT file
-- Inputs: 0) RAF reference, 1) tag, 2) format, 3) optional count
-- Returns: value, reference to structure hash, or undef on error
function ReadPictValue(raf, tag, format, count)
    if not truthy(format) then return nil end
    if count == nil then
        local isCnt, f1, f2 = isMatch(format, [=[(?s)(.+)\[(.+)\]]=])
        if isCnt then
            format = f1
            count = f2
        else
            count = 1 -- count undefined: assume 1
        end
    end
    local cntStr = (perl.num(count) == 1) and '' or "[" .. perl.str(count) .. "]"
    -- no size if count is 0
    local size
    if truthy(count) then size = ExifTool.FormatSize(format) else size = 0 end
    if size ~= nil or format == 'null' then
        local val
        if truthy(size) then
            local buff, n_
            size = size * count
            n_, buff = raf:Read(size)
            if n_ ~= size then return nil end
            val = ReadValue(buff, 0, format, count, size)
        else
            val = ''
        end
        if truthy(verbose) then
            out:write(indent .. tag .. " (" .. format .. cntStr .. ")")
            if truthy(size) then
                if val == nil then
                    out:write(" = <undef>\n")
                elseif format == 'binary' then
                    out:write(" = <binary data>\n")
                    if perl.num(verbose) > 2 then
                        local parms = { Out = out }
                        if perl.num(verbose) < 4 then parms.MaxLen = 96 end
                        HexDump(val, nil, parms)
                    end
                else
                    out:write(" = " .. perl.str(val) .. "\n")
                end
            else
                out:write("\n")
            end
        end
        if format == 'binary' and val ~= nil then return { ref = 'SCALAR', value = val } end
        return val
    end
    if truthy(verbose) then out:write(indent .. tag .. " (" .. format .. cntStr .. "):\n") end
    local struct = structs[format]
    if not struct then return nil end
    local vals = {}
    for _ = 0, count - 1 do
        local val = {}
        local i = 0
        while true do
            local tag_ = struct[i + 1]
            if not tag_ then break end
            local fmt = struct[i + 2]
            local cnt, v
            indent = indent .. '  '
            if type(fmt) == 'table' then
                v = evalPict[fmt.value](val, raf)
                if truthy(verbose) and v ~= nil then
                    out:write(sprintf(indent .. tag_ .. " (binary[%d]) = <binary data>\n", length(v.value)))
                    if perl.num(verbose) > 2 then
                        local parms = { Out = out }
                        if perl.num(verbose) < 4 then parms.MaxLen = 96 end
                        HexDump(v.value, nil, parms)
                    end
                end
            else
                local isCnt, f1, f2 = isMatch(fmt, [=[(?s)(.+)\[(.+)\]]=])
                if isCnt then
                    fmt = f1
                    -- (a plain number like '9' evaluates to itself)
                    if isMatch(f2, [[^\d+$]]) then cnt = perl.num(f2) else cnt = evalPict[f2](val, raf) end
                    v = ReadPictValue(raf, tag_, fmt, cnt)
                else
                    v = ReadPictValue(raf, tag_, fmt)
                end
            end
            indent = substr(indent, 2)
            if v == nil then return nil end
            val[tag_] = v
            i = i + 2
        end
        if perl.num(count) == 1 then return val end
        vals[#vals + 1] = val
    end
    return vals
end
PICT.ReadPictValue = ReadPictValue

--------------------------------------------------------------------------------
-- Extract meta information from a PICT image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PICT image
function PICT.ProcessPICT(et, dirInfo)
    local raf = dirInfo.RAF
    verbose = et:Options('Verbose')
    out = et:Options('TextOut') or io.stdout
    indent = ''
    local buff, tried, hdr, op, hRes, vRes, n_

    -- recognize both PICT files and PICT resources (PICT files have a
    -- 512-byte header that we ignore, but PICT resources do not)
    while true do
        n_, buff = raf:Read(12)
        if n_ ~= 12 then return 0 end
        hdr = { unpack('x2n5', buff) }
        op = table.remove(hdr)
        -- check for PICT version 1 format
        if op == 0x1101 then
            vers = 1
            extended = nil
            break
        end
        -- check for PICT version 2 format
        if op == 0x0011 then
            n_, buff = raf:Read(28)
            if n_ ~= 28 then return 0 end
            if isMatch(buff, [[^\x02\xff\x0c\x00\xff\xff]]) then
                vers = 2
                extended = nil
                break
            end
            if isMatch(buff, [[^\x02\xff\x0c\x00\xff\xfe]]) then
                vers = 2
                extended = 1
                hRes, vRes = unpack('x8N2', buff)
                break
            end
        end
        if tried then return 0 end
        tried = 1
        if not raf:Seek(512, 0) then return 0 end
    end
    -- make the bounding rect signed
    for i = 1, #hdr do
        if hdr[i] >= 0x8000 then hdr[i] = hdr[i] - 0x10000 end
    end
    local w = hdr[4] - hdr[2]
    local h = hdr[3] - hdr[1]
    if not (w > 0 and h > 0) then return 0 end

    SetByteOrder('MM')

    if extended then
        -- extended version 2 pictures contain resolution information
        -- and image bounds are in 72-dpi equivalent units
        hRes = GetFixed32s(buff, 8)
        vRes = GetFixed32s(buff, 12)
        if not (truthy(hRes) and truthy(vRes)) then return 0 end
        w = int(w * hRes / 72 + 0.5)
        h = int(h * vRes / 72 + 0.5)
    end
    et:SetFileType()
    et:FoundTag('ImageWidth', w)
    et:FoundTag('ImageHeight', h)
    if truthy(hRes) then et:FoundTag('XResolution', hRes) end
    if truthy(vRes) then et:FoundTag('YResolution', vRes) end

    -- don't extract image opcodes unless verbose
    if not (truthy(verbose) or truthy(et:Options('Unknown'))) then return 1 end

    if truthy(verbose) then out:write(sprintf("PICT version " .. vers .. "%s\n", extended and ' extended' or '')) end

    local tagTablePtr = GetTagTable(nil, 'lexiftool.PICT.Main')

    local success
    while true do
        if vers == 1 then
            n_, buff = raf:Read(1)
            if n_ ~= 1 then break end
            op = ord(buff)
        else
            -- must start version 2 opcode on an even byte
            if raf:Tell() & 0x01 ~= 0 then raf:Read(1) end
            n_, buff = raf:Read(2)
            if n_ ~= 2 then break end
            op = unpack('n', buff)
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, op)
        if not tagInfo then
            -- search for reserved tag info
            for i = 0, #reserved - 1, 2 do
                if op >= reserved[i + 1] then
                    if op > reserved[i + 2] then break end
                    tagInfo = et:GetTagInfo(tagTablePtr, reserved[i + 1])
                    break
                end
            end
            if not tagInfo then break end
        end
        if op == 0xff then
            if truthy(verbose) then out:write("End of picture\n") end
            success = 1
            break
        end
        local format = tagInfo.Format
        if not truthy(format) then
            et:Warn("Missing format for " .. tagInfo.Name)
            break
        end
        -- replace version number for version-dependent formats
        format = subst(format, '#$', str(vers))
        local wid = vers * 2
        if truthy(verbose) then out:write(sprintf("Tag 0x%." .. wid .. "x, ", op)) end
        local val = ReadPictValue(raf, tagInfo.Name, format)
        if val == nil then
            et:Warn("Error reading " .. tagInfo.Name .. " information")
            break
        end
        if type(val) == 'table' and val.ref == nil and val[1] == nil and next(val) ~= nil then
            -- extract JPEG image from CompressedQuickTime imageData
            local imageDescr = val.imageDescr
            if tagInfo.Name == 'CompressedQuickTime' and
                type(imageDescr) == 'table' and imageDescr.ref == nil and imageDescr[1] == nil and
                truthy(imageDescr.compressor) and
                imageDescr.compressor == 'Photo - JPEG' and
                type(val.imageData) == 'table' and val.imageData.ref == 'SCALAR' and
                et:ValidateImage(val.imageData, 'PreviewImage')
            then
                et:FoundTag('PreviewImage', val.imageData)
            end
        else -- luacheck: ignore 542
            -- $et->FoundTag($tagInfo, $val);
        end
    end
    if not success then et:Warn('End of picture not found') end
    return 1
end

return PICT
