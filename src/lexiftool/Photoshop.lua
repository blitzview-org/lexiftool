--------------------------------------------------------------------------------
-- File:         lexiftool/Photoshop.lua
-- Ported from:  lib/Image/ExifTool/Photoshop.pm
--
-- Description:  Read/write Photoshop IRB meta information
--
-- Revisions:    02/06/2004 - P. Harvey Created
--               02/25/2004 - P. Harvey Added hack for problem with old photoshops
--               10/04/2004 - P. Harvey Added a bunch of tags (ref Image::MetaData::JPEG)
--                            but left most of them commented out until I have enough
--                            information to write PrintConv routines for them to
--                            display something useful
--               07/08/2005 - P. Harvey Added support for reading PSD files
--               01/07/2006 - P. Harvey Added PSD write support
--               11/04/2006 - P. Harvey Added handling of resource name
--
-- References:   1) http://www.fine-view.com/jp/lab/doc/ps6ffspecsv2.pdf
--               2) http://www.ozhiker.com/electronics/pjmt/jpeg_info/irb_jpeg_qual.html
--               3) Matt Mueller private communication (tests with PS CS2)
--               4) http://www.fileformat.info/format/psd/egff.htm
--               5) http://www.telegraphics.com.au/svn/psdparse/trunk/resources.c
--               6) http://libpsd.graphest.com/files/Photoshop%20File%20Formats.pdf
--               7) http://www.adobe.com/devnet-apps/photoshop/fileformatashtml/
--
-- Port notes:   Complete port of Photoshop.pm: every table, lookup and sub, in
--               upstream order.  The predeclared subs are locals at the top,
--               the tables reach them through closures; WritePhotoshop and
--               SetResourceName (WritePhotoshop.pl) live in
--               WritePhotoshop.lua and are bound here as AUTOLOAD closures.
--               The %thumbnailInfo/%unicodeString spreads are helper calls in
--               front of the entry, as in MacOS.lua.  ConvertPascalString
--               decodes with the CharsetPhotoshop option as upstream.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local tsort = perl.tsort
local carray = require('carray')
local isMatch = perl.isMatch
local findAll = perl.findAll
local subst = perl.subst
local split = perl.split
local join = perl.join
local lc = perl.lc
local ord = perl.ord
local length = perl.length
local substr = perl.substr
local sprintf = perl.sprintf
local unpack = perl.unpack
local pack = perl.pack
local truthy = perl.truthy
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get16s = ExifTool.Get16s
local Get32u = ExifTool.Get32u
local Get64u = ExifTool.Get64u
local SetByteOrder = ExifTool.SetByteOrder
local GetByteOrder = ExifTool.GetByteOrder
local GetTagTable = ExifTool.GetTagTable

local Photoshop = {}

-- (upstream's predeclarations; the subs below assign to them)
local ProcessPhotoshop, WritePhotoshop, ProcessLayers, ProcessChannelOptions

-- (WritePhotoshop and SetResourceName are the subs of WritePhotoshop.pl, which
--  upstream AUTOLOADs -- DoAutoLoad loads it on the first call.  Here both are
--  bound to closures that load WritePhotoshop.lua on first use)
for _, name in ipairs({ 'SetResourceName', 'WritePhotoshop' }) do
    Photoshop[name] = function(...) return require('lexiftool.WritePhotoshop')[name](...) end
end
WritePhotoshop = Photoshop.WritePhotoshop

-- (port helper: Perl's `{ %hash, ... }` -- the entries of hash are added to
--  the tagInfo; explicit fields win as in Perl, see MacOS.lua)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end


-- PrintFlags bit definitions (ref forum13785)
Photoshop.printFlags = {
    [0] = 'Labels',
    [1] = 'Corner crop marks',
    [2] = 'Color bars', -- (deprecated)
    [3] = 'Registration marks',
    [4] = 'Negative',
    [5] = 'Emulsion down',
    [6] = 'Interpolate', -- (deprecated)
    [7] = 'Description',
    [8] = 'Print flags',
}

-- map of where information is stored in PSD image
local psdMap = {
    IPTC         = 'Photoshop',
    XMP          = 'Photoshop',
    EXIFInfo     = 'Photoshop',
    IFD0         = 'EXIFInfo',
    IFD1         = 'IFD0',
    ICC_Profile  = 'Photoshop',
    ExifIFD      = 'IFD0',
    GPS          = 'IFD0',
    SubIFD       = 'IFD0',
    GlobParamIFD = 'IFD0',
    PrintIM      = 'IFD0',
    InteropIFD   = 'ExifIFD',
    MakerNotes   = 'ExifIFD',
}

-- tag information for PhotoshopThumbnail and PhotoshopBGRThumbnail
local thumbnailInfo = spread {
    Writable = 'undef',
    Protected = 1,
    RawConv = function(self, val, tag)
        local img = substr(val, 0x1c)
        -- (upstream ValidateImage gets and returns the scalar ref \$img)
        img = self:ValidateImage(img, tag)
        return img ~= nil and { ref = 'SCALAR', value = img } or nil
    end,
    ValueConvInv = function(_self, val)
        local et = ExifTool.new()
        local tags = { 'ImageWidth', 'ImageHeight', 'FileType' }
        local info = et:ImageInfo({ ref = 'SCALAR', value = val }, tags)
        local w, h, type_ = info.ImageWidth, info.ImageHeight, info.FileType
        if not (truthy(w) and truthy(h) and truthy(type_) and type_ == 'JPEG') then
            error("Not a valid JPEG image\n", 0)   -- (upstream: warn(...), return undef)
        end
        local wbytes = perl.int((w * 24 + 31) / 32) * 4
        return pack('N6n2', 1, w, h, wbytes, wbytes * h, #val, 24, 1) .. val
    end,
}

-- tag info to decode Photoshop Unicode string
local unicodeString = spread {
    ValueConv = function(et, val)
        if #val < 4 then return '<err>' end
        local len = unpack('N', val) * 2
        if #val < 4 + len then return '<err>' end
        return et:Decode(substr(val, 4, len), 'UTF16', 'MM')
    end,
    ValueConvInv = function(et, val)
        return pack('N', #val) .. et:Encode(val, 'UTF16', 'MM')
    end,
}

-- Photoshop APP13 tag table
-- (set Unknown flag for information we don't want to display normally)
Photoshop.Main = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = function(...) return ProcessPhotoshop(...) end,
    WRITE_PROC = WritePhotoshop,
    [0x03e8] = { Unknown = 1, Name = 'Photoshop2Info' },
    [0x03e9] = { Unknown = 1, Name = 'MacintoshPrintInfo' },
    [0x03ea] = { Unknown = 1, Name = 'XMLData', Binary = 1 }, -- #PH
    [0x03eb] = { Unknown = 1, Name = 'Photoshop2ColorTable' },
    [0x03ed] = {
        Name = 'ResolutionInfo',
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.Resolution',
        },
    },
    [0x03ee] = {
        Name = 'AlphaChannelsNames',
        ValueConv = function(self, val) return Photoshop.ConvertPascalString(self, val) end,
    },
    [0x03ef] = { Unknown = 1, Name = 'DisplayInfo' },
    [0x03f0] = { Unknown = 1, Name = 'PStringCaption' },
    [0x03f1] = { Unknown = 1, Name = 'BorderInformation' },
    [0x03f2] = { Unknown = 1, Name = 'BackgroundColor' },
    [0x03f3] = {
        Unknown = 1,
        Name = 'PrintFlags',
        Format = 'int8u',
        PrintConv = function(_self, val)
            local byte = 0
            local bits = findAll(val, [[\d+]])
            for i = #bits, 1, -1 do byte = (byte << 1) | (truthy(bits[i]) and 1 or 0) end
            return ExifTool.DecodeBits(byte, Photoshop.printFlags)
        end,
    },
    [0x03f4] = { Unknown = 1, Name = 'BW_HalftoningInfo' },
    [0x03f5] = { Unknown = 1, Name = 'ColorHalftoningInfo' },
    [0x03f6] = { Unknown = 1, Name = 'DuotoneHalftoningInfo' },
    [0x03f7] = { Unknown = 1, Name = 'BW_TransferFunc' },
    [0x03f8] = { Unknown = 1, Name = 'ColorTransferFuncs' },
    [0x03f9] = { Unknown = 1, Name = 'DuotoneTransferFuncs' },
    [0x03fa] = { Unknown = 1, Name = 'DuotoneImageInfo' },
    [0x03fb] = { Unknown = 1, Name = 'EffectiveBW', Format = 'int8u' },
    [0x03fc] = { Unknown = 1, Name = 'ObsoletePhotoshopTag1' },
    [0x03fd] = { Unknown = 1, Name = 'EPSOptions' },
    [0x03fe] = { Unknown = 1, Name = 'QuickMaskInfo' },
    [0x03ff] = { Unknown = 1, Name = 'ObsoletePhotoshopTag2' },
    [0x0400] = { Unknown = 1, Name = 'TargetLayerID', Format = 'int16u' }, -- (LayerStateInfo)
    [0x0401] = { Unknown = 1, Name = 'WorkingPath' },
    [0x0402] = { Unknown = 1, Name = 'LayersGroupInfo', Format = 'int16u' },
    [0x0403] = { Unknown = 1, Name = 'ObsoletePhotoshopTag3' },
    [0x0404] = {
        Name = 'IPTCData',
        SubDirectory = {
            DirName = 'IPTC',
            TagTable = 'lexiftool.IPTC.Main',
        },
    },
    [0x0405] = { Unknown = 1, Name = 'RawImageMode' },
    [0x0406] = { -- #2
        Name = 'JPEG_Quality',
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.JPEG_Quality',
        },
    },
    [0x0408] = { Unknown = 1, Name = 'GridGuidesInfo' },
    [0x0409] = thumbnailInfo {
        Name = 'PhotoshopBGRThumbnail',
        Notes = 'this is a JPEG image, but in BGR format instead of RGB',
        Groups = { [2] = 'Preview' },
    },
    [0x040a] = {
        Name = 'CopyrightFlag',
        Writable = 'int8u',
        Groups = { [2] = 'Author' },
        ValueConv = function(_self, val) return join(" ", { unpack("C*", val) }) end,
        ValueConvInv = function(_self, val) return pack("C*", table.unpack(split(" ", val))) end,
        PrintConv = { -- #3
            [0] = 'False',
            [1] = 'True',
        },
    },
    [0x040b] = {
        Name = 'URL',
        Writable = 'string',
        Groups = { [2] = 'Author' },
    },
    [0x040c] = thumbnailInfo {
        Name = 'PhotoshopThumbnail',
        Groups = { [2] = 'Preview' },
    },
    [0x040d] = {
        Name = 'GlobalAngle',
        Writable = 'int32u',
        ValueConv = function(_self, val) return (unpack("N", val)) end,
        ValueConvInv = function(_self, val) return pack("N", val) end,
    },
    [0x040e] = { Unknown = 1, Name = 'ColorSamplersResource' },
    [0x040f] = {
        Name = 'ICC_Profile',
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    [0x0410] = { Unknown = 1, Name = 'Watermark', Format = 'int8u' },
    [0x0411] = { Unknown = 1, Name = 'ICC_Untagged', Format = 'int8u' },
    [0x0412] = { Unknown = 1, Name = 'EffectsVisible', Format = 'int8u' },
    [0x0413] = { Unknown = 1, Name = 'SpotHalftone' },
    [0x0414] = { Unknown = 1, Name = 'IDsBaseValue', Description = 'IDs Base Value', Format = 'int32u' },
    [0x0415] = { Unknown = 1, Name = 'UnicodeAlphaNames' },
    [0x0416] = { Unknown = 1, Name = 'IndexedColorTableCount', Format = 'int16u' },
    [0x0417] = { Unknown = 1, Name = 'TransparentIndex', Format = 'int16u' },
    [0x0419] = {
        Name = 'GlobalAltitude',
        Writable = 'int32u',
        ValueConv = function(_self, val) return (unpack("N", val)) end,
        ValueConvInv = function(_self, val) return pack("N", val) end,
    },
    [0x041a] = {
        Name = 'SliceInfo',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.SliceInfo' },
    },
    [0x041b] = unicodeString { Name = 'WorkflowURL' },
    [0x041c] = { Unknown = 1, Name = 'JumpToXPEP' },
    [0x041d] = { Unknown = 1, Name = 'AlphaIdentifiers' },
    [0x041e] = {
        Name = 'URL_List',
        List = 1,
        Writable = 1,
        ValueConv = function(et, val)
            if #val < 4 then return '<err>' end
            local num = unpack('N', val)
            local vals = {}
            local pos = 4
            for _ = 0, num - 1 do
                pos = pos + 8   -- (skip word and ID)
                if #val < pos + 4 then break end
                local len = unpack("x" .. pos .. "N", val) * 2
                if #val < pos + 4 + len then break end
                vals[#vals + 1] = et:Decode(substr(val, pos + 4, len), 'UTF16', 'MM')
                pos = pos + 4 + len
            end
            return vals
        end,
        -- (this is tricky to make writable)
    },
    [0x0421] = {
        Name = 'VersionInfo',
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.VersionInfo',
        },
    },
    [0x0422] = {
        Name = 'EXIFInfo', -- #PH (Found in EPS and PSD files)
        SubDirectory = {
            TagTable= 'lexiftool.Exif.Main',
            -- (port: the EXIF block is a self-contained TIFF whose offsets
            --  are relative to its own header, so this port's ProcessTIFF
            --  needs Base 0 here -- upstream's ProcessTIFF ignores the
            --  containing block's Base for this case)
            ProcessProc = function(et, dirInfo, tagTablePtr) dirInfo.Base = 0 return ExifTool.ProcessTIFF(et, dirInfo, tagTablePtr) end,
            WriteProc = function(...) return ExifTool.WriteTIFF(...) end,
        },
    },
    [0x0423] = { Unknown = 1, Name = 'ExifInfo2', Binary = 1 }, -- #5
    [0x0424] = {
        Name = 'XMP',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
        },
    },
    [0x0425] = {
        Name = 'IPTCDigest',
        Writable = 'string',
        Protected = 1,
        Notes = [[
            this tag indicates provides a way for XMP-aware applications to indicate
            that the XMP is synchronized with the IPTC.  The MWG recommendation is to
            ignore the XMP if IPTCDigest exists and doesn't match the CurrentIPTCDigest.
            When writing, special values of "new" and "old" represent the digests of the
            IPTC from the edited and original files respectively, and are undefined if
            the IPTC does not exist in the respective file.  Set this to "new" as an
            indication that the XMP is synchronized with the IPTC
        ]],
        -- also note the 'new' feature requires that the IPTC comes before this tag is written
        ValueConv = function(_self, val) return (unpack("H*", val)) end,
        ValueConvInv = function(_self, val)
            if lc(val) == 'new' or lc(val) == 'old' then
                if ExifTool.hasMD5() then return lc(val) end
                error("Digest::MD5 must be installed\n", 0)
            end
            if isMatch(val, '(?i)^[0-9a-f]{32}$') then return pack('H*', val) end
            error("Value must be 'new', 'old' or 32 hexadecimal digits\n", 0)
        end,
    },
    [0x0426] = {
        Name = 'PrintScaleInfo',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.PrintScaleInfo' },
    },
    [0x0428] = {
        Name = 'PixelInfo',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.PixelInfo' },
    },
    [0x0429] = { Unknown = 1, Name = 'LayerComps' }, -- #5
    [0x042a] = { Unknown = 1, Name = 'AlternateDuotoneColors' }, -- #5
    [0x042b] = { Unknown = 1, Name = 'AlternateSpotColors' }, -- #5
    [0x042d] = { -- #7
        Name = 'LayerSelectionIDs',
        Description = 'Layer Selection IDs',
        Unknown = 1,
        ValueConv = function(_self, val)
            local a = { unpack("nN*", val) }
            local n = table.remove(a, 1)
            if n ~= nil and n > #a then for i = #a + 1, n do a[i] = '' end end   -- ($#a = $n - 1 extends with undef)
            return join(' ', a)
        end,
    },
    [0x042e] = { Unknown = 1, Name = 'HDRToningInfo' }, -- #7
    [0x042f] = { Unknown = 1, Name = 'PrintInfo' }, -- #7
    [0x0430] = { Unknown = 1, Name = 'LayerGroupsEnabledID', Format = 'int8u' }, -- #7
    [0x0431] = { Unknown = 1, Name = 'ColorSamplersResource2' }, -- #7
    [0x0432] = { Unknown = 1, Name = 'MeasurementScale' }, -- #7
    [0x0433] = { Unknown = 1, Name = 'TimelineInfo' }, -- #7
    [0x0434] = { Unknown = 1, Name = 'SheetDisclosure' }, -- #7
    [0x0435] = {
        Name = 'ChannelOptions', -- #7/forum16762
        SubDirectory = {
            TagTable = 'lexiftool.Photoshop.ChannelOptions',
            Start = 4,
        },
    },
    [0x0436] = { Unknown = 1, Name = 'OnionSkins' }, -- #7
    [0x0438] = { Unknown = 1, Name = 'CountInfo' }, -- #7
    [0x043a] = { Unknown = 1, Name = 'PrintInfo2' }, -- #7
    [0x043b] = { Unknown = 1, Name = 'PrintStyle' }, -- #7
    [0x043c] = { Unknown = 1, Name = 'MacintoshNSPrintInfo' }, -- #7
    [0x043d] = { Unknown = 1, Name = 'WindowsDEVMODE' }, -- #7
    [0x043e] = { Unknown = 1, Name = 'AutoSaveFilePath' }, -- #7
    [0x043f] = { Unknown = 1, Name = 'AutoSaveFormat' }, -- #7
    [0x0440] = { Unknown = 1, Name = 'PathSelectionState' }, -- #7
    -- 0x07d0-0x0bb6 Path information
    [0x0bb7] = {
        Name = 'ClippingPathName',
        -- convert from a Pascal string (ignoring 6 bytes of unknown data after string)
        ValueConv = function(self, val)
            local len = ord(val)
            if len < #val then val = substr(val, 0, len + 1) end
            return Photoshop.ConvertPascalString(self, val)
        end,
    },
    [0x0bb8] = { Unknown = 1, Name = 'OriginPathInfo' }, -- #7
    -- 0x0fa0-0x1387 - plug-in resources (ref 7)
    [0x1b58] = { Unknown = 1, Name = 'ImageReadyVariables' }, -- #7
    [0x1b59] = { Unknown = 1, Name = 'ImageReadyDataSets' }, -- #7
    [0x1f40] = { Unknown = 1, Name = 'LightroomWorkflow' }, -- #7
    [0x2710] = { Unknown = 1, Name = 'PrintFlagsInfo' },
}

-- Photoshop channel options (ref forum16762)
Photoshop.ChannelOptions = {
    PROCESS_PROC = function(...) return ProcessChannelOptions(...) end,
    VARS = { IS_BINARY = 1 },
    GROUPS = { [2] = 'Image' },
    NOTES = 'These tags relate only to the appearance of a channel.',
    [0] = {
        Name = 'ChannelColorSpace',
        Format = 'int16u',
        PrintConv = {
            [0] = 'RGB',
            [1] = 'HSB',
            [2] = 'CMYK',
            [7] = 'Lab',
            [8] = 'Grayscale',
        },
    },
    [2] = {
        Name = 'ChannelColorData',
        Format = 'int16u[4]',
    },
    [11] = {
        Name = 'ChannelOpacity',
        PrintConv = function(_self, val) return perl.str(val) .. "%" end,
    },
    [12] = {
        Name = 'ChannelColorIndicates',
        PrintConv = {
            [0] = 'Selected Areas',
            [1] = 'Masked Areas',
            [2] = 'Spot Color',
        },
    },
}

-- Photoshop JPEG quality record (ref 2)
Photoshop.JPEG_Quality = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    DATAMEMBER = { 1 },
    FORMAT = 'int16s',
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'PhotoshopQuality',
        Writable = 1,
        PrintConv = function(_self, val) return val + 4 end,
        PrintConvInv = function(_self, val) return val - 4 end,
    },
    [1] = {
        Name = 'PhotoshopFormat',
        RawConv = function(self, val) self.PhotoshopFormat = val return val end,
        PrintConv = {
            [0x0000] = 'Standard',
            [0x0001] = 'Optimized',
            [0x0101] = 'Progressive',
        },
    },
    [2] = {
        Name = 'ProgressiveScans',
        Condition = function(self) return self.PhotoshopFormat == 0x0101 end,
        PrintConv = {
            [1] = '3 Scans',
            [2] = '4 Scans',
            [3] = '5 Scans',
        },
    },
}

-- Photoshop Slices
Photoshop.SliceInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [20] = { Name = 'SlicesGroupName', Format = 'var_ustr32' },
    [24] = { Name = 'NumSlices',       Format = 'int32u' },
}

-- Photoshop resolution information #PH
Photoshop.Resolution = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    FORMAT = 'int16u',
    FIRST_ENTRY = 0,
    WRITABLE = 1,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'XResolution',
        Format = 'int32u',
        Priority = 0,
        ValueConv = function(_self, val) return val / 0x10000 end,
        ValueConvInv = function(_self, val) return perl.int(val * 0x10000 + 0.5) end,
        PrintConv = function(_self, val) return perl.int(val * 100 + 0.5) / 100 end,
        PrintConvInv = function(_self, val) return val end,
    },
    [2] = {
        Name = 'DisplayedUnitsX',
        PrintConv = {
            [1] = 'inches',
            [2] = 'cm',
        },
    },
    [4] = {
        Name = 'YResolution',
        Format = 'int32u',
        Priority = 0,
        ValueConv = function(_self, val) return val / 0x10000 end,
        ValueConvInv = function(_self, val) return perl.int(val * 0x10000 + 0.5) end,
        PrintConv = function(_self, val) return perl.int(val * 100 + 0.5) / 100 end,
        PrintConvInv = function(_self, val) return val end,
    },
    [6] = {
        Name = 'DisplayedUnitsY',
        PrintConv = {
            [1] = 'inches',
            [2] = 'cm',
        },
    },
}

-- Photoshop version information
Photoshop.VersionInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    FIRST_ENTRY = 0,
    GROUPS = { [2] = 'Image' },
    -- (always 1) 0 => { Name => 'PhotoshopVersion', Format => 'int32u' },
    [4] = { Name = 'HasRealMergedData', Format = 'int8u', PrintConv = { [0] = 'No', [1] = 'Yes' } },
    [5] = { Name = 'WriterName', Format = 'var_ustr32' },
    [9] = { Name = 'ReaderName', Format = 'var_ustr32' },
    -- (always 1) 13 => { Name => 'FileVersion', Format => 'int32u' },
}

-- Print Scale
Photoshop.PrintScaleInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    FIRST_ENTRY = 0,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'PrintStyle',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Centered',
            [1] = 'Size to Fit',
            [2] = 'User Defined',
        },
    },
    [2]  = { Name = 'PrintPosition', Format = 'float[2]' },
    [10] = { Name = 'PrintScale',    Format = 'float' },
}

-- Pixel Aspect Ratio
Photoshop.PixelInfo = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    FIRST_ENTRY = 0,
    GROUPS = { [2] = 'Image' },
    -- 0 - version
    [4] = { Name = 'PixelAspectRatio', Format = 'double' },
}

-- Photoshop PSD file header
Photoshop.Header = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'int16u',
    GROUPS = { [2] = 'Image' },
    NOTES = 'This information is found in the PSD file header.',
    [6] = 'NumChannels',
    [7] = { Name = 'ImageHeight', Format = 'int32u' },
    [9] = { Name = 'ImageWidth', Format = 'int32u' },
    [11] = 'BitDepth',
    [12] = {
        Name = 'ColorMode',
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
}

-- Layer information
Photoshop.Layers = {
    PROCESS_PROC = function(...) return ProcessLayers(...) end,
    GROUPS = { [2] = 'Image' },
    NOTES = 'Tags extracted from Photoshop layer information.',
    -- tags extracted from layer information
    -- (tag ID's are for convenience only)
    _xcnt = { Name = 'LayerCount', Format = 'int16u' },
    _xrct = {
        Name = 'LayerRectangles',
        Format = 'int32u',
        Count = 4,
        List = 1,
        Notes = 'top left bottom right',
    },
    _xnam = { Name = 'LayerNames',
        Format = 'string',
        List = 1,
        ValueConv = function(self, val)
            local charset = self:Options('CharsetPhotoshop') or 'Latin'
            return self:Decode(val, charset)
        end,
    },
    _xbnd = {
        Name = 'LayerBlendModes',
        Format = 'undef',
        List = 1,
        RawConv = function(_self, val) if ExifTool.GetByteOrder() == "II" then return pack("N*", unpack("V*", val)) end return val end,
        PrintConv = {
            pass = 'Pass Through',
            norm = 'Normal',
            diss = 'Dissolve',
            dark = 'Darken',
           ['mul ']= 'Multiply',
            idiv = 'Color Burn',
            lbrn = 'Linear Burn',
            dkCl = 'Darker Color',
            lite = 'Lighten',
            scrn = 'Screen',
           ['div ']= 'Color Dodge',
            lddg = 'Linear Dodge',
            lgCl = 'Lighter Color',
            over = 'Overlay',
            sLit = 'Soft Light',
            hLit = 'Hard Light',
            vLit = 'Vivid Light',
            lLit = 'Linear Light',
            pLit = 'Pin Light',
            hMix = 'Hard Mix',
            diff = 'Difference',
            smud = 'Exclusion',
            fsub = 'Subtract',
            fdiv = 'Divide',
           ['hue ']= 'Hue',
           ['sat ']= 'Saturation',
            colr = 'Color',
           ['lum ']= 'Luminosity',
        },
    },
    _xopc  = {
        Name = 'LayerOpacities',
        Format = 'int8u',
        List = 1,
        ValueConv = function(_self, val) return 100 * val / 255 end,
        PrintConv = function(_self, val) return sprintf("%d%%", val) end,
    },
    _xvis  = {
        Name = 'LayerVisible',
        Format = 'int8u',
        List = 1,
        ValueConv = function(_self, val) return val & 0x02 end,
        PrintConv = { [0x02] = 'No', [0x00] = 'Yes' },
    },
    -- tags extracted from additional layer information (tag ID's are real)
    -- - must be able to accommodate a blank entry to preserve the list ordering
    luni = {
        Name = 'LayerUnicodeNames',
        List = 1,
        RawConv = function(self, val)
            if #val < 4 then return '' end
            local len = ExifTool.Get32u(val, 0)
            return self:Decode(substr(val, 4, len * 2), 'UTF16')
        end,
    },
    lyid = {
        Name = 'LayerIDs',
        Description = 'Layer IDs',
        Format = 'int32u',
        List = 1,
        Unknown = 1,
    },
    lclr = {
        Name = 'LayerColors',
        Format = 'int16u',
        Count = 1,
        List = 1,
        PrintConv = {
            [0]='None',  [1]='Red',  [2]='Orange', [3]='Yellow',
            [4]='Green', [5]='Blue', [6]='Violet', [7]='Gray',
        },
    },
    shmd = { -- layer metadata (undocumented structure)
        -- (for now, only extract layerTime.  May also contain "layerXMP" --
        --  it would be nice to decode this but I need a sample)
        Name = 'LayerModifyDates',
        Groups = { [2] = 'Time' },
        List = 1,
        RawConv = function(_self, val)
            local isT, _, tmp = isMatch(val, [[(?s)layerTime(doub|buod)(.{8})]])
            if not isT then return '' end
            return ExifTool.GetDouble(tmp, 0)
        end,
        ValueConv = function(_self, val) if truthy(length(val)) then return ExifTool.ConvertUnixTime(val, 1) end return "" end,
        PrintConv = function(self, val) if truthy(length(val)) then return self:ConvertDateTime(val) end return "" end,
    },
    lsct = {
        Name = 'LayerSections',
        Format = 'int32u',
        Count = 1,
        List = 1,
        PrintConv = { [0] = 'Layer', [1] = 'Folder (open)', [2] = 'Folder (closed)', [3] = 'Divider' },
    },
}

-- tags extracted from ImageSourceData found in TIFF images (ref PH)
Photoshop.DocumentData = {
    PROCESS_PROC = function(...) return Photoshop.ProcessDocumentData(...) end,
    GROUPS = { [2] = 'Image' },
    Layr = {
        Name = 'Layers',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Layers' },
    },
    Lr16 = { -- (NC)
        Name = 'Layers',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Layers' },
    },
}

-- image data
Photoshop.ImageData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'Compression',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Uncompressed',
            [1] = 'RLE',
            [2] = 'ZIP without prediction',
            [3] = 'ZIP with prediction',
        },
    },
}

-- tags for unknown resource types
Photoshop.Unknown = {
    GROUPS = { [2] = 'Unknown' },
}

-- define reference to IPTCDigest tagInfo hash for convenience
Photoshop.iptcDigestInfo = Photoshop.Main[0x0425]


--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WritePhotoshop.pl -- its subs are bound
--  to loader closures at the predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Convert pascal string(s) to something we can use
-- Inputs: 1) Pascal string data
-- Returns: Strings, concatenated with ', '
function Photoshop.ConvertPascalString(et, inStr)
    local outStr = ''
    local len = length(inStr)
    local i = 0
    while i < len do
        local n = ord(substr(inStr, i, 1))
        if i + n >= len then break end
        if i ~= 0 then outStr = outStr .. ', ' end
        outStr = outStr .. substr(inStr, i + 1, n)
        i = i + n + 1
    end
    local charset = et:Options('CharsetPhotoshop') or 'Latin'
    return et:Decode(outStr, charset)
end

--------------------------------------------------------------------------------
-- Process Photoshop layers and mask information section of PSD/PSB file
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success (and seeks to the end of this section)
function Photoshop.ProcessLayersAndMask(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local fileType = et.FileType
    local data, nr

    if not (fileType == 'PSD' or fileType == 'PSB') then return 0 end -- (no layer section in CS1 files)

    -- (some words are 4 bytes in PSD files and 8 bytes in PSB)
    local psb, psiz
    if fileType == 'PSB' then psb, psiz = 1, 8 else psb, psiz = nil, 4 end

    -- read the layer information header
    local n = psiz * 2 + 2
    nr, data = raf:Read(n)
    if nr ~= n then return 0 end
    local tot = psb and Get64u(data, 0) or Get32u(data, 0) -- length of layer and mask info
    if tot == 0 then return 1 end
    local end_ = raf:Tell() - psiz - 2 + tot
    data = substr(data, psiz)
    local len = psb and Get64u(data, 0) or Get32u(data, 0) -- length of layer info section
    local num = Get16s(data, psiz)
    -- check for Lr16 block if layers length is 0 (ref https://forums.adobe.com/thread/1540914)
    if len == 0 and num == 0 then
        nr, data = raf:Read(10)
        if nr ~= 10 then return 0 end
        if isMatch(data, [[(?s)^..8BIMLr16]]) then
            nr, data = raf:Read(psiz + 2)
            if nr ~= psiz + 2 then return 0 end
            len = psb and Get64u(data, 0) or Get32u(data, 0)
        elseif isMatch(data, [[(?s)^..8BIMMt16]]) then -- (have seen Mt16 before Lr16, ref PH)
            nr, data = raf:Read(psiz) -- luacheck: ignore 311
            if nr ~= psiz then return 0 end
            nr, data = raf:Read(8)
            if nr ~= 8 then return 0 end
            if data == '8BIMLr16' then
                nr, data = raf:Read(psiz + 2)
                if nr ~= psiz + 2 then return 0 end
                len = psb and Get64u(data, 0) or Get32u(data, 0)
            else
                if not raf:Seek(-18 - psiz, 1) then return 0 end
            end
        else
            if not raf:Seek(-10, 1) then return 0 end
        end
    end
    len = len + 2   -- include layer count with layer info section
    if not raf:Seek(-2, 1) then return 0 end
    local dinfo = {
        RAF = raf,
        DirLen = len,
    }
    et.IsPSB = psb  -- set PSB flag
    ProcessLayers(et, dinfo, tagTablePtr)

    -- seek to the end of this section and return success flag
    return raf:Seek(end_, 0) and 1 or 0
end

--------------------------------------------------------------------------------
-- Process Photoshop channel options (ref forum16762)
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ProcessChannelOptions(et, dirInfo, tagTablePtr)
    local end_ = dirInfo.DirStart  + dirInfo.DirLen
    dirInfo.DirLen = 13
    local i = 0
    while dirInfo.DirStart + 13 <= end_ do
        et.SET_GROUP1 = "Channel" .. i
        et:ProcessBinaryData(dirInfo, tagTablePtr)
        dirInfo.DirStart = dirInfo.DirStart + 13
        i = i + 1
    end
    et.SET_GROUP1 = nil
    return 1
end
Photoshop.ProcessChannelOptions = ProcessChannelOptions

--------------------------------------------------------------------------------
-- Process Photoshop layers (beginning with layer count)
-- Inputs: 0) ExifTool ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Notes: Uses ExifTool IsPSB member to determine whether file is PSB format
function ProcessLayers(et, dirInfo, tagTablePtr)
    local n, buff, buf2, nr
    local count = {}
    local raf = dirInfo.RAF
    local dirLen = dirInfo.DirLen
    local verbose = et.OPTIONS.Verbose
    -- (Lua: the scalar ref \$buff is refreshed in %dinfo after each read)
    local dinfo = { Base = raf:Tell() }
    local function hTag(tag, val, parms)
        local p = { DataPt = buff, Base = dinfo.Base, DataPos = dinfo.DataPos }
        for k, v in pairs(parms or {}) do p[k] = v end
        return et:HandleTag(tagTablePtr, tag, val, p)
    end
    local pos = 0
    if dirLen < 2 then return 0 end
    nr, buff = raf:Read(2)
    if nr ~= 2 then return 0 end
    local num = Get16s(buff, 0)     -- number of layers
    if num < 0 then num = -num end  -- (first channel is transparency data if negative)
    et:VerboseDir('Layers', num, dirLen)
    hTag('_xcnt', num, { Start = pos, Size = 2 }) -- LayerCount
    local oldIndent = et.INDENT
    et.INDENT = et.INDENT .. '| '
    pos = pos + 2
    local psb = et.IsPSB    -- is PSB format?
    local psiz = psb and 8 or 4
    for i = 0, num - 1 do  -- process each layer
        et:VPrint(0, oldIndent .. '+ [Layer ' .. (i + 1) .. " of " .. num .. "]\n")
        if pos + 18 > dirLen then break end
        nr, buff = raf:Read(18)
        if nr ~= 18 then break end
        dinfo.DataPos = pos
        -- save the layer rectangle
        hTag('_xrct', nil, { Start = 0, Size = 16 })
        local numChannels = Get16u(buff, 16)
        n = (2 + psiz) * numChannels    -- size of channel information
        if not raf:Seek(n, 1) then break end
        pos = pos + 18 + n
        if pos + 20 > dirLen then break end
        nr, buff = raf:Read(20)
        if nr ~= 20 then break end
        dinfo.DataPos = pos
        local sig = substr(buff, 0, 4)
        if not isMatch(sig, '^(8BIM|MIB8)$') then break end -- verify signature
        hTag('_xbnd', nil, { Start = 4, Size = 4 })
        hTag('_xopc', nil, { Start = 8, Size = 1 })
        hTag('_xvis', nil, { Start = 10, Size = 1 })
        local nxt = pos + 16 + Get32u(buff, 12)
        n = Get32u(buff, 16)            -- get size of layer mask data
        pos = pos + 20 + n              -- skip layer mask data
        if pos + 4 > dirLen then break end
        if not raf:Seek(n, 1) then break end
        nr, buff = raf:Read(4)
        if nr ~= 4 then break end
        n = Get32u(buff, 0)             -- get size of layer blending ranges
        pos = pos + 4 + n               -- skip layer blending ranges data
        if pos + 1 > dirLen then break end
        if not raf:Seek(n, 1) then break end
        nr, buff = raf:Read(1)
        if nr ~= 1 then break end
        n = Get8u(buff, 0)              -- get length of layer name
        if pos + 1 + n > dirLen then break end
        nr, buff = raf:Read(n)
        if nr ~= n then break end
        dinfo.DataPos = pos + 1
        hTag('_xnam', nil, { Start = 0, Size = n })
        local frag = (n + 1) & 0x3
        if frag ~= 0 then
            if not raf:Seek(4 - frag, 1) then break end
        end
        n = (n + 4) & 0xfffffffc        -- +1 for length byte then pad to multiple of 4 bytes
        pos = pos + n
        -- process additional layer info
        while pos + 12 <= nxt do
            nr, buff = raf:Read(12)
            if nr ~= 12 then break end
            local dat = substr(buff, 0, 8)
            if GetByteOrder() == 'II' then dat = pack('N*', unpack('V*', dat)) end
            sig = substr(dat, 0, 4)
            if not (sig == '8BIM' or sig == '8B64') then break end -- verify signature
            local tag = substr(dat, 4, 4)
            -- (some structures have an 8-byte size word [augh!]
            -- --> it would be great if '8B64' indicated a 64-bit version, and this may well
            -- be the case, but it is not mentioned in the Photoshop file format specification)
            if psb and isMatch(tag, '^(LMsk|Lr16|Lr32|Layr|Mt16|Mt32|Mtrn|Alph|FMsk|lnk2|FEid|FXid|PxSD)$') then
                if pos + 16 > nxt then break end
                nr, buf2 = raf:Read(4)
                if nr ~= 4 then break end
                buff = buff .. buf2
                n = Get64u(buff, 8)
                pos = pos + 4
            else
                n = Get32u(buff, 8)
            end
            pos = pos + 12
            if pos + n > nxt then break end
            frag = n & 0x3
            if tagTablePtr[tag] or truthy(verbose) then
                -- pad with empty entries if necessary to keep the same index for each item in the layer
                if count[tag] == nil then count[tag] = 0 end
                nr, buff = raf:Read(n)
                if nr ~= n then break end
                dinfo.DataPos = pos
                while count[tag] < i do
                    et:HandleTag(tagTablePtr, tag, tag == 'lsct' and 0 or '')
                    count[tag] = count[tag] + 1
                end
                hTag(tag, nil, { Start = 0, Size = n })
                count[tag] = count[tag] + 1
                if frag ~= 0 then
                    if not raf:Seek(4 - frag, 1) then break end
                    n = n + 4 - frag    -- pad to multiple of 4 bytes (PH NC)
                end
            else
                if frag ~= 0 then n = n + 4 - frag end
                if not raf:Seek(n, 1) then break end
            end
            pos = pos + n   -- step to start of next structure
        end
        pos = nxt
    end
    -- pad lists if necessary to have an entry for each layer
    local tags = {}
    for k in pairs(count) do tags[#tags + 1] = k end
    tsort(tags)
    for _, tag in ipairs(tags) do
        while count[tag] < num do
            et:HandleTag(tagTablePtr, tag, tag == 'lsct' and 0 or '')
            count[tag] = count[tag] + 1
        end
    end
    et.INDENT = oldIndent
    return 1
end
Photoshop.ProcessLayers = ProcessLayers

--------------------------------------------------------------------------------
-- Process Photoshop ImageSourceData
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function Photoshop.ProcessDocumentData(et, dirInfo, tagTablePtr)
    local verbose = et.OPTIONS.Verbose
    local raf = dirInfo.RAF
    local dirLen = dirInfo.DirLen
    local pos = 36  -- length of header
    local buff, n, err, nr

    et:VerboseDir('Photoshop Document Data', nil, dirLen)
    if not raf then
        local dataPt = dirInfo.DataPt
        local start = dirInfo.DirStart or 0
        raf = require('lexiftool.RandomAccess').new(dataPt)
        if start ~= 0 then raf:Seek(start, 0) end
        if dirLen == nil then dirLen = length(dataPt) - start end
        et:VerboseDump(dataPt, { Start = start, Len = dirLen, Base = dirInfo.Base })
    end
    nr, buff = raf:Read(pos)
    local isDD, ver = false, nil
    if nr == pos then isDD, ver = isMatch(buff, '^Adobe Photoshop Document Data (Block|V0002)\0') end
    if not isDD then
        et:Warn('Invalid Photoshop Document Data')
        return 0
    end
    local psb = (ver == 'V0002')
    -- (Lua: %dinfo's DataPt is refreshed from each read, since a Lua string
    --  is a value)
    local dinfo = { DataPt = buff }
    et.IsPSB = psb  -- set PSB flag (needed when handling Layers directory)
    while pos + 12 <= dirLen do
        nr, buff = raf:Read(8)
        if nr ~= 8 then err = 'Error reading document data' break end
        -- set byte order according to byte order of first signature
        if pos == 36 then SetByteOrder(isMatch(buff, '^(8BIM|8B64)') and 'MM' or 'II') end
        if GetByteOrder() == 'II' then buff = pack('N*', unpack('V*', buff)) end
        local sig = substr(buff, 0, 4)
        if not (sig == '8BIM' or sig == '8B64') then err = 'Bad photoshop resource' break end -- verify signature
        local tag = substr(buff, 4, 4)
        if psb and isMatch(tag, '^(LMsk|Lr16|Lr32|Layr|Mt16|Mt32|Mtrn|Alph|FMsk|lnk2|FEid|FXid|PxSD)$') then
            if pos + 16 > dirLen then err = 'Short PSB resource' break end
            nr, buff = raf:Read(8)
            if nr ~= 8 then err = 'Error reading PSB resource' break end
            n = Get64u(buff, 0)
            pos = pos + 4
        else
            nr, buff = raf:Read(4)
            if nr ~= 4 then err = 'Error reading PSD resource' break end
            n = Get32u(buff, 0)
        end
        pos = pos + 12
        if pos + n > dirLen then err = 'Truncated photoshop resource' break end
        local pad = (4 - (n & 3)) & 3   -- number of padding bytes
        local tagInfo = tagTablePtr[tag]
        if tagInfo or truthy(verbose) then
            if tagInfo and tagInfo.SubDirectory then
                local fpos = raf:Tell() + n + pad
                local subTable = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                et:ProcessDirectory({ RAF = raf, DirLen = n }, subTable)
                if not raf:Seek(fpos, 0) then err = 'Seek error' break end
            else
                dinfo.DataPos = raf:Tell()
                dinfo.Start = 0
                dinfo.Size = n
                nr, buff = raf:Read(n)
                if nr ~= n then err = 'Error reading photoshop resource' break end
                dinfo.DataPt = buff
                et:HandleTag(tagTablePtr, tag, nil, dinfo)
                if not raf:Seek(pad, 1) then err = 'Seek error' break end
            end
        else
            if not raf:Seek(n + pad, 1) then err = 'Seek error' break end
        end
        pos = pos + n + pad     -- step to start of next structure
    end
    if err then et:Warn(err) end
    return 1
end

--------------------------------------------------------------------------------
-- Process Photoshop APP13 record
-- Inputs: 0) ExifTool object reference, 1) Reference to directory information
--         2) Tag table reference
-- Returns: 1 on success
function ProcessPhotoshop(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local dirEnd = pos + dirInfo.DirLen
    local verbose = et:Options('Verbose')
    local success = 0

    -- ignore non-standard XMP while in strict MWG compatibility mode
    if (truthy(ExifTool.MWGstrict()) or truthy(et:Options('Validate'))) and
        isMatch(et.FILE_TYPE, '^(JPEG|TIFF|PSD)$')
    then
        local path = et:MetadataPath()
        if not isMatch(path, '^(JPEG-APP13-Photoshop|TIFF-IFD0-Photoshop|PSD)$') then
            if truthy(ExifTool.MWGstrict()) then
                et:Warn("Ignored non-standard Photoshop at " .. path)
                return 1
            else
                et:Warn("Non-standard Photoshop at " .. path, 1)
            end
        end
    end
    if et.FILE_TYPE == 'JPEG' and dirInfo.Parent ~= 'APP13' then
        et.LOW_PRIORITY_DIR['*'] = 1    -- lower priority of all these tags
    end
    SetByteOrder('MM')  -- Photoshop is always big-endian
    if truthy(verbose) then et:VerboseDir('Photoshop', 0, dirInfo.DirLen) end

    -- scan through resource blocks:
    -- Format: 0) Type, 4 bytes - '8BIM' (or the rare 'PHUT', 'DCSR', 'AgHg' or 'MeSa')
    --         1) TagID,2 bytes
    --         2) Name, pascal string padded to even no. bytes
    --         3) Size, 4 bytes - N
    --         4) Data, N bytes
    while pos + 8 < dirEnd do
        local type_ = substr(dataPt, pos, 4)
        local ttPtr, extra, val, name
        if type_ == '8BIM' then
            ttPtr = tagTablePtr
        elseif isMatch(type_, '^(PHUT|DCSR|AgHg|MeSa)$') then -- (PHUT~ImageReady, MeSa~PhotoDeluxe)
            ttPtr = GetTagTable(nil, 'lexiftool.Photoshop.Unknown')
        else
            type_ = subst(type_, [[([^\w])]], function(c) return sprintf("\\x%.2x", ord(c)) end, 'g')
            et:Warn('Bad Photoshop IRB resource "' .. type_ .. '"')
            break
        end
        local tag = Get16u(dataPt, pos + 4)
        pos = pos + 6   -- point to start of name
        local nameLen = Get8u(dataPt, pos)
        pos = pos + 1
        local namePos = pos
        -- skip resource block name (pascal string, padded to an even # of bytes)
        pos = pos + nameLen
        if nameLen & 0x01 == 0 then pos = pos + 1 end
        if pos + 4 > dirEnd then
            et:Warn("Bad Photoshop resource block")
            break
        end
        local size = Get32u(dataPt, pos)
        pos = pos + 4
        if size + pos > dirEnd then
            et:Warn("Bad Photoshop resource data size " .. size)
            break
        end
        success = 1
        if nameLen ~= 0 then
            name = substr(dataPt, namePos, nameLen)
            extra = ', Name="' .. name .. '"'
        else
            name = ''
        end
        local tagInfo = et:GetTagInfo(ttPtr, tag)
        -- append resource name to value if requested (braced by "/#...#/")
        if tagInfo and tagInfo.SetResourceName ~= nil and
            perl.str(tagInfo.SetResourceName) == '1' and not isMatch(name, '/#')
        then
            val = substr(dataPt, pos, size) .. '/#' .. name .. '#/'
        end
        et:HandleTag(ttPtr, tag, val, {
            TagInfo = tagInfo,
            Extra   = extra,
            DataPt  = dataPt,
            DataPos = dirInfo.DataPos,
            Size    = size,
            Start   = pos,
            Base    = dirInfo.Base,
            Parent  = dirInfo.DirName,
        })
        if size & 0x01 ~= 0 then size = size + 1 end -- size is padded to an even # bytes
        pos = pos + size
    end
    -- warn about incorrect IPTCDigest
    if truthy(et.VALUE.IPTCDigest) and truthy(et.VALUE.CurrentIPTCDigest) and
        et.VALUE.IPTCDigest ~= et.VALUE.CurrentIPTCDigest
    then
        et:Warn('IPTCDigest is not current. XMP may be out of sync')
    end
    et.LOW_PRIORITY_DIR['*'] = nil
    return success
end
Photoshop.ProcessPhotoshop = ProcessPhotoshop

--------------------------------------------------------------------------------
-- extract information from Photoshop PSD file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 if this was a valid PSD file, -1 on write error
function Photoshop.ProcessPSD(et, dirInfo)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local data, err, tagTablePtr, nr
    local Write = function(...) return require('lexiftool.Writer').Write(...) end

    nr, data = raf:Read(30)
    if nr ~= 30 then return 0 end
    local isPSD, v = isMatch(data, [[^8BPS\0([\x01\x02])]])
    if not isPSD then return 0 end
    SetByteOrder('MM')
    et:SetFileType(v == "\x01" and 'PSD' or 'PSB') -- set the FileType tag
    local dirInfo2 = {
        DataPt = data,
        DirStart = 0,
        DirName = 'Photoshop',
    }
    local len = Get32u(data, 26)
    if outfile then
        if not Write(outfile, data) then err = 1 end
        nr, data = raf:Read(len)
        if nr ~= len then return -1 end
        if not Write(outfile, data) then err = 1 end -- write color mode data
        -- initialize map of where things are written
        require('lexiftool.Writer').InitWriteDirs(et, psdMap)
    else
        -- process the header
        tagTablePtr = GetTagTable(nil, 'lexiftool.Photoshop.Header')
        dirInfo2.DirLen = 30
        et:ProcessDirectory(dirInfo2, tagTablePtr)
        if not raf:Seek(len, 1) then err = 1 end -- skip over color mode data
    end
    -- read image resource section
    nr, data = raf:Read(4)
    if nr ~= 4 then err = 1 end
    len = Get32u(data, 0)
    nr, data = raf:Read(len)
    if nr ~= len then err = 1 end
    dirInfo2.DataPt = data
    tagTablePtr = GetTagTable(nil, 'lexiftool.Photoshop.Main')
    dirInfo2.DirLen = len
    local rtnVal = 1
    if outfile then
        -- rewrite IRB resources
        data = WritePhotoshop(et, dirInfo2, tagTablePtr)
        if truthy(data) then
            len = ExifTool.Put32u(length(data))
            if not Write(outfile, len, data) then err = 1 end
            -- look for trailer and edit if necessary
            local trailInfo = et:IdentifyTrailer(raf)
            if trailInfo then
                local tbuf = carray.new('char')
                trailInfo.OutFile = { value = tbuf }    -- rewrite trailer(s)
                -- rewrite all trailers to buffer
                if truthy(et:ProcessTrailers(trailInfo)) then
                    local copyBytes = (trailInfo.DataPos or 0) - raf:Tell()  -- (undef DataPos numifies to 0)
                    if copyBytes >= 0 then
                        -- copy remaining PSD file up to start of trailer
                        while copyBytes > 0 do
                            local n = (copyBytes > 65536) and 65536 or copyBytes
                            nr, data = raf:Read(n)
                            if nr ~= n then err = 1 end
                            if not Write(outfile, data) then err = 1 end
                            copyBytes = copyBytes - n
                        end
                        -- write the trailer (or not)
                        if not require('lexiftool.Writer').WriteTrailerBuffer(et, trailInfo, outfile) then err = 1 end
                    else
                        et:Warn('Overlapping trailer')
                        trailInfo = nil
                    end
                else
                    trailInfo = nil
                end
            end
            if not trailInfo then
                -- copy over the rest of the file
                while true do
                    nr, data = raf:Read(65536)
                    if not truthy(nr) then break end
                    if not Write(outfile, data) then err = 1 end
                end
            end
        else
            err = 1
        end
        if err then rtnVal = -1 end
    elseif err then
        et:Warn('File format error')
    else
        -- read IRB resources
        ProcessPhotoshop(et, dirInfo2, tagTablePtr)
        -- read layer and mask information section
        dirInfo2.RAF = raf
        tagTablePtr = GetTagTable(nil, 'lexiftool.Photoshop.Layers')
        local oldIndent = et.INDENT
        et.INDENT = et.INDENT .. '| '
        if truthy(Photoshop.ProcessLayersAndMask(et, dirInfo2, tagTablePtr)) then
            -- read compression mode from image data section
            nr, data = raf:Read(2)
            if nr == 2 then
                local dirInfo3 = {
                    DataPt  = data,
                    DataPos = raf:Tell() - 2,
                }
                tagTablePtr = GetTagTable(nil, 'lexiftool.Photoshop.ImageData')
                et:ProcessDirectory(dirInfo3, tagTablePtr)
            end
        end
        et.INDENT = oldIndent
        -- process trailers if they exist
        local trailInfo = et:IdentifyTrailer(raf)
        if trailInfo then et:ProcessTrailers(trailInfo) end
    end
    return rtnVal
end

return Photoshop
