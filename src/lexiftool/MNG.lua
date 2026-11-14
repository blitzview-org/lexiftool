--------------------------------------------------------------------------------
-- File:         lexiftool/MNG.lua
-- Ported from:  lib/Image/ExifTool/MNG.pm
--
-- Description:  MNG and JNG meta information tags
--
-- Revisions:    06/23/2005 - P. Harvey Created
--
-- References:   1) http://www.libpng.org/pub/mng/
--
-- Port notes:   complete: MNG.pm is a pure tag-table module (no subs, no
--               writable tags and no WRITE_PROC), so there is no write path
--               of its own to port -- MNG/JNG chunks are read and written
--               through PNG.ProcessPNG/PNG.FoundPNG, which dispatch to
--               MNG.Main for the non-PNG signatures.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local join = perl.join
local unpack_ = perl.unpack
local findAll = perl.findAll
local subst = perl.subst
local sprintf = perl.sprintf

local MNG = {}

-- MNG chunks
MNG.Main = {
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        This table contains definitions for tags found in MNG and JNG images.  MNG
        is a superset of PNG and JNG, so a MNG image may contain any of these tags
        as well as any PNG tags.  Conversely, only some of these tags are valid for
        JNG images.
    ]],
    BACK = {
        Name = 'Background',
        SubDirectory = { TagTable = 'lexiftool.MNG.Background' },
    },
    BASI = {
        Name = 'BasisObject',
        SubDirectory = { TagTable = 'lexiftool.MNG.BasisObject' },
    },
    CLIP = {
        Name = 'ClipObjects',
        SubDirectory = { TagTable = 'lexiftool.MNG.ClipObjects' },
    },
    CLON = {
        Name = 'CloneObject',
        SubDirectory = { TagTable = 'lexiftool.MNG.CloneObject' },
    },
    DBYK = {
        Name = 'DropByKeyword',
        Binary = 1,
    },
    DEFI = {
        Name = 'DefineObject',
        SubDirectory = { TagTable = 'lexiftool.MNG.DefineObject' },
    },
    DHDR = {
        Name = 'DeltaPNGHeader',
        SubDirectory = { TagTable = 'lexiftool.MNG.DeltaPNGHeader' },
    },
    DISC = {
        Name = 'DiscardObjects',
        ValueConv = function(_self, val) return join(' ', { unpack_('n*', val) }) end,
    },
    DROP = {
        Name = 'DropChunks',
        ValueConv = function(_self, val) return join(' ', findAll(val, [[....]])) end,
    },
--   ENDL
    eXPi = {
        Name = 'ExportImage',
        SubDirectory = { TagTable = 'lexiftool.MNG.ExportImage' },
    },
    fPRI = {
        Name = 'FramePriority',
        SubDirectory = { TagTable = 'lexiftool.MNG.FramePriority' },
    },
    FRAM = {
        Name = 'Frame',
        Binary = 1,
    },
--   IJNG
--   IPNG
--   JDAA (JNG)
--   JDAT (JNG)
    JHDR = { -- (JNG)
        Name = 'JNGHeader',
        SubDirectory = { TagTable = 'lexiftool.MNG.JNGHeader' },
    },
--   JSEP (JNG)
    LOOP = {
        Name = 'Loop',
        SubDirectory = { TagTable = 'lexiftool.MNG.Loop' },
    },
    MAGN = {
        Name = 'MagnifyObject',
        SubDirectory = { TagTable = 'lexiftool.MNG.MagnifyObject' },
    },
--   MEND
    MHDR = {
        Name = 'MNGHeader',
        SubDirectory = { TagTable = 'lexiftool.MNG.MNGHeader' },
    },
    MOVE = {
        Name = 'MoveObjects',
        SubDirectory = { TagTable = 'lexiftool.MNG.MoveObjects' },
    },
    nEED = {
        Name = 'ResourcesNeeded',
        Binary = 1,
    },
    ORDR = {
        Name = 'OrderingRestrictions',
        Binary = 1,
    },
    PAST = {
        Name = 'PasteImage',
        SubDirectory = { TagTable = 'lexiftool.MNG.PasteImage' },
    },
    pHYg = {
        Name = 'GlobalPixelSize',
        SubDirectory = { TagTable = 'lexiftool.PNG.PhysicalPixel' },
    },
    PPLT = {
        Name = 'PartialPalette',
        Binary = 1,
    },
    PROM = {
        Name = 'PromoteParent',
        SubDirectory = { TagTable = 'lexiftool.MNG.PromoteParent' },
    },
    SAVE = {
        Name = 'SaveObjects',
        Binary = 1,
    },
    SEEK = {
        Name = 'SeekPoint',
        ValueConv = function(_self, val) val = subst(val, [[(?s)\0.*]], ''); return val end,
    },
    SHOW = {
        Name = 'ShowObjects',
        SubDirectory = { TagTable = 'lexiftool.MNG.ShowObjects' },
    },
    TERM = {
        Name = 'TerminationAction',
        SubDirectory = { TagTable = 'lexiftool.MNG.TerminationAction' },
    },
}

-- MNG MHDR chunk
MNG.MNGHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int32u',
    [0] = 'ImageWidth',
    [1] = 'ImageHeight',
    [2] = 'TicksPerSecond',
    [3] = 'NominalLayerCount',
    [4] = 'NominalFrameCount',
    [5] = 'NominalPlayTime',
    [6] = {
        Name = 'SimplicityProfile',
        PrintConv = function(_self, val) return sprintf('0x%.8x', val) end,
    },
}

-- MNG BASI chunk
MNG.BasisObject = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'ImageWidth',
        Format = 'int32u',
    },
    [4] = {
        Name = 'ImageHeight',
        Format = 'int32u',
    },
    [8] = 'BitDepth',
    [9] = {
        Name = 'ColorType',
        RawConv = function(_self, val)
            require('lexiftool.PNG').colorType = val
            return val
        end,
        PrintConv = {
            [0] = 'Grayscale',
            [2] = 'RGB',
            [3] = 'Palette',
            [4] = 'Grayscale with Alpha',
            [6] = 'RGB with Alpha',
        },
    },
    [10] = {
        Name = 'Compression',
        PrintConv = { [0] = 'Deflate/Inflate' },
    },
    [11] = {
        Name = 'Filter',
        PrintConv = { [0] = 'Adaptive' },
    },
    [12] = {
        Name = 'Interlace',
        PrintConv = { [0] = 'Noninterlaced', [1] = 'Adam7 Interlace' },
    },
    [13] = {
        Name = 'RedSample',
        Format = 'int32u',
    },
    [17] = {
        Name = 'GreenSample',
        Format = 'int32u',
    },
    [21] = {
        Name = 'BlueSample',
        Format = 'int32u',
    },
    [25] = {
        Name = 'AlphaSample',
        Format = 'int32u',
    },
    [26] = 'Viewable',
}

-- MNG LOOP chunk
MNG.Loop = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = 'NestLevel',
    [1] = {
        Name = 'IterationCount',
        Format = 'int32u',
    },
    [5] = {
        Name = 'TerminationCondition',
        PrintConv = {
            [0] = 'Deterministic, not cacheable',
            [1] = 'Decoder discretion, not cacheable',
            [2] = 'User discretion, not cacheable',
            [3] = 'External signal, not cacheable',
            [4] = 'Deterministic, cacheable',
            [5] = 'Decoder discretion, cacheable',
            [6] = 'User discretion, cacheable',
            [7] = 'External signal, cacheable',
        },
    },
    [6] = {
        Name = 'IterationMinMax',
        Format = 'int32u[2]',
    },
    [14] = {
        Name = 'SignalNumber',
        Format = 'int32u',
    },
}

-- MNG DEFI chunk
MNG.DefineObject = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'ObjectID',
        Format = 'int16u',
    },
    [2] = 'DoNotShow',
    [3] = 'ConcreteFlag',
    [4] = {
        Name = 'XYLocation',
        Format = 'int32u[2]',
    },
    [12] = {
        Name = 'ClippingBoundary',
        Format = 'int32u[4]',
    },
}

-- MNG CLON chunk
MNG.CloneObject = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'SourceID',
        Format = 'int16u',
    },
    [2] = {
        Name = 'CloneID',
        Format = 'int16u',
    },
    [4] = {
        Name = 'CloneType',
        PrintConv = { [0] = 'Full', [1] = 'Parital', [2] = 'Renumber object' },
    },
    [5] = 'DoNotShow',
    [6] = 'ConcreteFlag',
    [7] = {
        Name = 'LocalDeltaType',
        PrintConv = { [0] = 'Absolute', [1] = 'Relative' },
    },
    [8] = {
        Name = 'DeltaXY',
        Format = 'int32u[2]',
    },
}

-- MNG PAST chunk
MNG.PasteImage = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'DestinationID',
        Format = 'int16u',
    },
    [2] = {
        Name = 'TargetDeltaType',
        PrintConv = { [0] = 'Absolute', [1] = 'Relative' },
    },
    [3] = {
        Name = 'TargetXY',
        Format = 'int32u[2]',
    },
    [11] = {
        Name = 'SourceID',
        Format = 'int16u',
    },
    [13] = {
        Name = 'CompositionMode',
        PrintConv = { [0] = 'Over', [1] = 'Replace', [2] = 'Under' },
    },
    [14] = {
        Name = 'Orientation',
        PrintConv = {
            [0] = 'Same as source',
            [2] = 'Flipped left-right, then up-down',
            [4] = 'Flipped left-right',
            [6] = 'Flipped up-down',
            [8] = 'Tiled',
        },
    },
    [15] = {
        Name = 'OffsetOrigin',
        PrintConv = { [0] = 'Desination Origin', [1] = 'Target Origin' },
    },
    [16] = {
        Name = 'OffsetXY',
        Format = 'int32u[2]',
    },
    [24] = {
        Name = 'BoundaryOrigin',
        PrintConv = { [0] = 'Desination Origin', [1] = 'Target Origin' },
    },
    [25] = {
        Name = 'PastClippingBoundary',
        Format = 'int32u[4]',
    },
}

local magMethod = {
    [0] = 'No Magnification',
    [1] = 'Pixel Replication',
    [2] = 'Linear Interpolation',
    [3] = 'Closest Pixel',
    [4] = 'Color Linear Interpolation and Alpha Closest Pixel',
    [5] = 'Color Closest Pixel and Alpha Linear Interpolation',
}

-- MNG MAGN chunk
MNG.MagnifyObject = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'FirstObjectID',
        Format = 'int16u',
    },
    [2] = {
        Name = 'LastObjectID',
        Format = 'int16u',
    },
    [4] = {
        Name = 'XMethod',
        PrintConv = magMethod,
    },
    [5] = {
        Name = 'XMag',
        Format = 'int16u',
    },
    [7] = {
        Name = 'YMag',
        Format = 'int16u',
    },
    [9] = {
        Name = 'LeftMag',
        Format = 'int16u',
    },
    [11] = {
        Name = 'RightMag',
        Format = 'int16u',
    },
    [13] = {
        Name = 'TopMag',
        Format = 'int16u',
    },
    [15] = {
        Name = 'BottomMag',
        Format = 'int16u',
    },
    [17] = {
        Name = 'YMethod',
        PrintConv = magMethod,
    },
}

-- MNG TERM chunk
MNG.TerminationAction = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'TerminationAction',
        PrintConv = {
            [0] = 'Show Last Frame',
            [1] = 'Display Nothing',
            [2] = 'Show First Frame',
            [3] = 'Repeat Sequence',
        },
    },
    [1] = {
        Name = 'IterationEndAction',
        PrintConv = {
            [0] = 'Show Last Frame',
            [1] = 'Display Nothing',
            [2] = 'Show First Frame',
        },
    },
    [2] = {
        Name = 'Delay',
        Format = 'int32u',
    },
    [6] = {
        Name = 'IterationMax',
        Format = 'int32u',
    },
}

-- MNG BACK chunk
MNG.Background = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'BackgroundColor',
        Format = 'int16u[3]',
    },
    [6] = {
        Name = 'MandatoryBackground',
        PrintConv = {
            [0] = 'Color and Image Advisory',
            [1] = 'Color Mandatory, Image Advisory',
            [2] = 'Color Advisory, Image Mandatory',
            [3] = 'Color and Image Mandatory',
        },
    },
    [7] = {
        Name = 'BackgroundImageID',
        Format = 'int16u',
    },
    [9] = {
        Name = 'BackgroundTiling',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
}

-- MNG MOVE chunk
MNG.MoveObjects = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'FirstObject',
        Format = 'int16u',
    },
    [2] = {
        Name = 'LastObject',
        Format = 'int16u',
    },
    [4] = {
        Name = 'DeltaType',
        PrintConv = { [0] = 'Absolute', [1] = 'Relative' },
    },
    [5] = {
        Name = 'DeltaXY',
        Format = 'int32u[2]',
    },
}

-- MNG CLIP chunk
MNG.ClipObjects = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'FirstObject',
        Format = 'int16u',
    },
    [2] = {
        Name = 'LastObject',
        Format = 'int16u',
    },
    [4] = {
        Name = 'DeltaType',
        PrintConv = { [0] = 'Absolute', [1] = 'Relative' },
    },
    [5] = {
        Name = 'ClipBoundary',
        Format = 'int32u[4]',
    },
}

-- MNG SHOW chunk
MNG.ShowObjects = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'FirstObject',
        Format = 'int16u',
    },
    [2] = {
        Name = 'LastObject',
        Format = 'int16u',
    },
    [4] = 'ShowMode',
}

-- MNG eXPI chunk
MNG.ExportImage = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'SnapshotID',
        Format = 'int16u',
    },
    [2] = {
        Name = 'SnapshotName',
        Format = 'string',
    },
}

-- MNG fPRI chunk
MNG.FramePriority = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'DeltaType',
        PrintConv = { [0] = 'Absolute', [1] = 'Relative' },
    },
    [2] = 'Priority',
}

-- MNG DHDR chunk
MNG.DeltaPNGHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'ObjectID',
        Format = 'int16u',
    },
    [2] = {
        Name = 'ImageType',
        PrintConv = {
            [0] = 'Unspecified',
            [1] = 'PNG',
            [2] = 'JNG',
        },
    },
    [3] = {
        Name = 'DeltaType',
        PrintConv = {
            [0] = 'Full Replacement',
            [1] = 'Pixel Addition',
            [2] = 'Alpha Addition',
            [3] = 'Color Addition',
            [4] = 'Pixel Replacement',
            [5] = 'Alpha Replacement',
            [6] = 'Color Replacement',
            [7] = 'No Change',
        },
    },
    [4] = {
        Name = 'BlockSize',
        Format = 'int32u[2]',
    },
    [12] = {
        Name = 'BlockLocation',
        Format = 'int32u[2]',
    },
}

-- MNG PROM chunk
MNG.PromoteParent = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = 'NewColorType',
    [1] = 'NewBitDepth',
    [2] = {
        Name = 'FillMethod',
        PrintConv = { [0] = 'Bit Replication', [1] = 'Zero Fill' },
    },
}

-- JNG JHDR chunk
MNG.JNGHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'ImageWidth',
        Format = 'int32u',
    },
    [4] = {
        Name = 'ImageHeight',
        Format = 'int32u',
    },
    [8] = {
        Name = 'ColorType',
        PrintConv = {
            [8] = 'Gray',
            [10] = 'Color',
            [12] = 'Gray Alpha',
            [14] = 'Color Alpha',
        },
    },
    [9] = 'BitDepth',
    [10] = {
        Name = 'Compression',
        PrintConv = { [8] = 'Huffman-coded baseline JPEG' },
    },
    [11] = {
        Name = 'Interlace',
        PrintConv = { [0] = 'Sequential', [8] = 'Progressive' },
    },
    [12] = 'AlphaBitDepth',
    [13] = {
        Name = 'AlphaCompression',
        PrintConv = {
            [0] = 'MNG Grayscale IDAT',
            [8] = 'JNG 8-bit Grayscale JDAA',
        },
    },
    [14] = {
        Name = 'AlphaFilter',
        PrintConv = { [0] = 'Adaptive MNG (N/A for JPEG)' },
    },
    [15] = {
        Name = 'AlphaInterlace',
        PrintConv = { [0] = 'Noninterlaced' },
    },
}

return MNG
