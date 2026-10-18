--------------------------------------------------------------------------------
-- File:         lexiftool/Ricoh.lua
-- Ported from:  lib/Image/ExifTool/Ricoh.pm
--
-- Description:  Ricoh EXIF maker notes tags
--
-- Revisions:    03/28/2005 - P. Harvey Created
--
-- References:   1) http://www.ozhiker.com/electronics/pjmt/jpeg_info/ricoh_mn.html
--               2) http://homepage3.nifty.com/kamisaka/makernote/makernote_ricoh.htm
--               3) Tim Gray private communication (GR)
--               4) https://github.com/atotto/ricoh-theta-tools/
--               5) https://github.com/ricohapi/theta-api-specs/blob/main/theta-metadata/README.md
--               IB) Iliah Borg private communication (LibRaw)
--
-- Port notes:   complete: all eighteen tag tables, %ricohLensIDs, the
--               Composite tags and all three process procs.
--
--               Write side as upstream: WRITE_PROC/CHECK_PROC on the
--               tables, `ImageInfo`'s IS_OFFSET/OffsetPair bookkeeping for
--               the maker-note preview.
--
--               `ProcessRicohRMETA`'s non-zero-`rmetaNum` branch (the
--               G700SE audio/barcode segments) is still stubbed: no
--               vendored image carries one, which is how the original M2
--               port left it.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local unpack = perl.unpack
local subst = perl.subst
local substr = perl.substr
local sprintf = perl.sprintf
local str = perl.str
local uc = perl.uc
local perlTruthy = ExifTool.perlTruthy

local Ricoh = {}

-- lens types for Ricoh GXR
local ricohLensIDs = {
    Notes = [[
        Lens units available for the GXR, used by the Ricoh Composite LensID tag.  Note
        that unlike lenses for all other makes of cameras, the focal lengths in these
        model names have already been scaled to include the 35mm crop factor.
    ]],
    -- (the exact lens model names used by Ricoh, except for a change in case)
    RL1 = 'GR Lens A12 50mm F2.5 Macro',
    RL2 = 'Ricoh Lens S10 24-70mm F2.5-4.4 VC',
    RL3 = 'Ricoh Lens P10 28-300mm F3.5-5.6 VC',
    RL5 = 'GR Lens A12 28mm F2.5',
    RL8 = 'Mount A12',
    RL6 = 'Ricoh Lens A16 24-85mm F3.5-5.5',
}

-- upstream `$format ne "int16u"` / `$format eq "int16u"`, the fork that tells
-- the old Caplio tags from the GR ones sharing a tag ID
local function notInt16u(_self, _val, format)
    return format ~= 'int16u'
end

local function isInt16u(_self, _val, format)
    return format == 'int16u'
end

-- upstream `$self->{Model} !~ /^Caplio RR1\b/`
local function notCaplioRR1(self)
    return matches(self.Model, [[^Caplio RR1\b]]) == nil
end

-- upstream `$val =~ /^\[Ricoh Camera Info\]/`
local function validateRicohSubdir(_self, val)
    return matches(str(val), [=[^\[Ricoh Camera Info\]]=]) ~= nil
end

-- upstream `$val * 1e-9` -- the RDT* atoms count nanoseconds
local function nanoToSec(_self, val)
    return perl.num(val) * 1e-9
end

Ricoh.Main = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = 1,
    [0x0001] = { Name = 'MakerNoteType', Writable = 'string' },
    [0x0002] = { --PH
        Name = 'FirmwareVersion',
        Writable = 'string',
        -- eg. "Rev0113" is firmware version 1.13
        PrintConv = function(_self, val)
            local rev = matches(str(val), [[^Rev(\d+)$]])
            if rev then return sprintf('%.2f', perl.num(rev) / 100) end
            return val
        end,
        PrintConvInv = function(_self, val)
            local a, b = matches(val, [[^(\d+)\.(\d+)$]])
            if a then return sprintf('Rev%.2d%.2d', a, b) end
            return val
        end,
    },
    [0x0005] = { --PH
        {
            Condition = function(_self, val) return matches(str(val), [[^[-\w ]+$]]) ~= nil end,
            Name = 'SerialNumber', -- (verified for GXR)
            Writable = 'undef',
            Count = 16,
            Notes = [[
                the serial number stamped on the camera begins with 2 model-specific letters
                followed by the last 8 digits of this value.  For the GXR, this is the
                serial number of the lens unit
            ]],
            PrintConv = function(_self, val)
                return subst(str(val), [[^(.*)(.{8})$]], '($1)$2')
            end,
            PrintConvInv = function(_self, val) return (perl.tr(val, '()', '', 'd')) end,
        },
        {
            Name = 'InternalSerialNumber',
            Writable = 'undef',
            Count = 16,
            ValueConv = function(_self, val) return unpack('H*', str(val)) end,
            ValueConvInv = function(_self, val) return perl.pack('H*', val) end,
        },
    },
    [0x0e00] = {
        Name = 'PrintIM',
        Writable = 0,
        Description = 'Print Image Matching',
        SubDirectory = { TagTable = 'lexiftool.PrintIM.Main' },
    },
    [0x1000] = { --3
        Name = 'RecordingFormat',
        Writable = 'int16u',
        PrintConv = {
            [2] = 'JPEG',
            [3] = 'DNG',
        },
    },
    [0x1001] = {
        {
            Name = 'ImageInfo',
            Condition = notInt16u,
            SubDirectory = { TagTable = 'lexiftool.Ricoh.ImageInfo' },
        },
        { --3
            Name = 'ExposureProgram',
            Writable = 'int16u',
            Notes = 'GR',
            PrintConv = {
                [1] = 'Auto',
                [2] = 'Program AE',
                [3] = 'Aperture-priority AE',
                [4] = 'Shutter speed priority AE',
                [5] = 'Shutter/aperture priority AE', -- TAv
                [6] = 'Manual',
                [7] = 'Movie', --PH
            },
        },
    },
    [0x1002] = { --3
        Name = 'DriveMode',
        Condition = isInt16u,
        Notes = 'valid only for some models',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Single-frame',
            [1] = 'Continuous',
            [8] = 'AF-priority Continuous',
        },
    },
    [0x1003] = {
        {
            Name = 'Sharpness',
            Condition = notInt16u,
            Writable = 'int32u',
            PrintConv = {
                [0] = 'Sharp',
                [1] = 'Normal',
                [2] = 'Soft',
            },
        },
        { --3
            Name = 'WhiteBalance',
            Writable = 'int16u',
            Notes = 'GR',
            PrintConv = {
                [0] = 'Auto',
                [1] = 'Multi-P Auto',
                [2] = 'Daylight',
                [3] = 'Cloudy',
                [4] = 'Incandescent 1',
                [5] = 'Incandescent 2',
                [6] = 'Daylight Fluorescent',
                [7] = 'Neutral White Fluorescent',
                [8] = 'Cool White Fluorescent',
                [9] = 'Warm White Fluorescent',
                [10] = 'Manual',
                [11] = 'Kelvin',
                [12] = 'Shade', --IB
            },
        },
    },
    [0x1004] = { --3
        Name = 'WhiteBalanceFineTune',
        Condition = isInt16u,
        Format = 'int16s',
        Writable = 'int16u',
        Notes = [[
            2 numbers: amount of adjustment towards Amber and Green.  Not valid for all
            models
        ]],
    },
    -- 0x1005 int16u - 5
    [0x1006] = { --3
        Name = 'FocusMode',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Manual',
            [2] = 'Multi AF',
            [3] = 'Spot AF',
            [4] = 'Snap',
            [5] = 'Infinity',
            [7] = 'Face Detect', --PH
            [8] = 'Subject Tracking',
            [9] = 'Pinpoint AF',
            [10] = 'Movie', --PH
        },
    },
    [0x1007] = { --3
        Name = 'AutoBracketing',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [9] = 'AE',
            [11] = 'WB',
            [16] = 'DR', -- (dynamic range)
            [17] = 'Contrast',
            [18] = 'WB2', -- (selects two different WB presets besides normal)
            [19] = 'Effect',
        },
    },
    [0x1009] = { --3
        Name = 'MacroMode',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x100a] = { --3
        Name = 'FlashMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Auto, Fired',
            [2] = 'On',
            [3] = 'Auto, Fired, Red-eye reduction',
            [4] = 'Slow Sync',
            [5] = 'Manual',
            [6] = 'On, Red-eye reduction',
            [7] = 'Synchro, Red-eye reduction',
            [8] = 'Auto, Did not fire',
        },
    },
    [0x100b] = { --3
        Name = 'FlashExposureComp',
        Writable = 'rational64s',
        PrintConv = function(_self, val)
            if perlTruthy(val) then return sprintf('%+.1f', perl.num(val)) end
            return 0
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x100c] = { --3
        Name = 'ManualFlashOutput',
        Writable = 'rational64s',
        PrintConv = {
            [0]    = 'Full',
            [-24]  = '1/1.4',
            [-48]  = '1/2',
            [-72]  = '1/2.8',
            [-96]  = '1/4',
            [-120] = '1/5.6',
            [-144] = '1/8',
            [-168] = '1/11',
            [-192] = '1/16',
            [-216] = '1/22',
            [-240] = '1/32',
            [-288] = '1/64',
        },
    },
    [0x100d] = { --3
        Name = 'FullPressSnap',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x100e] = { --3
        Name = 'DynamicRangeExpansion',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [3] = 'Weak',
            [4] = 'Medium',
            [5] = 'Strong',
        },
    },
    [0x100f] = { --3
        Name = 'NoiseReduction',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Weak',
            [2] = 'Medium',
            [3] = 'Strong',
        },
    },
    [0x1010] = { --3
        Name = 'ImageEffects',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Standard',
            [1] = 'Vivid',
            [3] = 'Black & White',
            [5] = 'B&W Toning Effect',
            [6] = 'Setting 1',
            [7] = 'Setting 2',
            [9] = 'High-contrast B&W',
            [10] = 'Cross Process',
            [11] = 'Positive Film',
            [12] = 'Bleach Bypass',
            [13] = 'Retro',
            [15] = 'Miniature',
            [17] = 'High Key',
        },
    },
    [0x1011] = { --3
        Name = 'Vignetting',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Low',
            [2] = 'Medium',
            [3] = 'High',
        },
    },
    [0x1012] = { --PH
        Name = 'Contrast',
        Writable = 'int32u',
        Format = 'int32s', --3 (high-contrast B&W also has -1 and -2 settings)
        PrintConv = {
            OTHER = function(val) return val end,
            [2147483647] = 'MAX', --3 (high-contrast B&W effect MAX setting)
        },
    },
    [0x1013] = { Name = 'Saturation', Writable = 'int32u' }, --PH
    [0x1014] = { Name = 'Sharpness',  Writable = 'int32u' }, --3
    [0x1015] = { --3
        Name = 'ToningEffect',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Sepia',
            [2] = 'Red',
            [3] = 'Green',
            [4] = 'Blue',
            [5] = 'Purple',
            [6] = 'B&W',
            [7] = 'Color',
        },
    },
    [0x1016] = { --3
        Name = 'HueAdjust',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Basic',
            [2] = 'Magenta',
            [3] = 'Yellow',
            [4] = 'Normal',
            [5] = 'Warm',
            [6] = 'Cool',
        },
    },
    [0x1017] = { --3
        Name = 'WideAdapter',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Not Attached',
            [2] = 'Attached', -- (21mm)
        },
    },
    [0x1018] = { --3
        Name = 'CropMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On (35mm)',
            [2] = 'On (47mm)', --IB
        },
    },
    [0x1019] = { --3
        Name = 'NDFilter',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x101a] = { Name = 'WBBracketShotNumber', Writable = 'int16u' }, --3
    -- 0x1100 - related to DR correction (ref 3)
    [0x1307] = { Name = 'ColorTempKelvin',     Writable = 'int32u' }, --3
    [0x1308] = { Name = 'ColorTemperature',    Writable = 'int32u' }, --3
    [0x1500] = { --3
        Name = 'FocalLength',
        Writable = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f mm', perl.num(val)) end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*mm$]], '')) end,
    },
    [0x1200] = { --3
        Name = 'AFStatus',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Out of Focus',
            [1] = 'In Focus',
        },
    },
    -- 0x1201-0x1204 - related to focus points (ref 3)
    [0x1201] = { --PH (NC)
        Name = 'AFAreaXPosition1',
        Writable = 'int32u',
        Notes = 'manual AF area position in a 1280x864 image',
    },
    [0x1202] = { Name = 'AFAreaYPosition1', Writable = 'int32u' }, --PH (NC)
    [0x1203] = { --PH (NC)
        Name = 'AFAreaXPosition',
        Writable = 'int32u',
        Notes = 'manual AF area position in the full image',
        -- (coordinates change to correspond with smaller image
        --  when recording reduced-size JPEG)
    },
    [0x1204] = { Name = 'AFAreaYPosition', Writable = 'int32u' }, --PH (NC)
    [0x1205] = { --3
        Name = 'AFAreaMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Auto',
            [2] = 'Manual',
        },
    },
    [0x1601] = { Name = 'SensorWidth',  Writable = 'int32u' }, --3
    [0x1602] = { Name = 'SensorHeight', Writable = 'int32u' }, --3
    [0x1603] = { Name = 'CroppedImageWidth',  Writable = 'int32u' }, --3
    [0x1604] = { Name = 'CroppedImageHeight', Writable = 'int32u' }, --3
    -- 0x1700 - Composite? (0=normal image, 1=interval composite, 2=multi-exposure composite) (ref 3)
    -- 0x1703 - 0=normal, 1=final composite (ref 3)
    -- 0x1704 - 0=normal, 2=final composite (ref 3)
    [0x2001] = {
        {
            Name = 'RicohSubdir',
            Condition = function(self, _val, format, count)
                return notCaplioRR1(self)
                    and (format ~= 'int32u' or count ~= 1)
            end,
            SubDirectory = {
                Validate = validateRicohSubdir,
                TagTable = 'lexiftool.Ricoh.Subdir',
                Start = function(_et, _val, valuePtr) return valuePtr + 20 end,
                ByteOrder = 'BigEndian',
            },
        },
        {
            Name = 'RicohSubdirIFD',
            -- the CX6 and GR Digital 4 write an int32u pointer in AVI videos -- doh!
            Condition = notCaplioRR1,
            Flags = 'SubIFD',
            SubDirectory = {
                TagTable = 'lexiftool.Ricoh.Subdir',
                Start = function(_et, val, _valuePtr) return perl.num(val) + 20 end, -- (skip over "[Ricoh Camera Info]\0" header)
                ByteOrder = 'BigEndian',
            },
        },
        {
            Name = 'RicohRR1Subdir',
            SubDirectory = {
                Validate = validateRicohSubdir,
                TagTable = 'lexiftool.Ricoh.Subdir',
                Start = function(_et, _val, valuePtr) return valuePtr + 20 end,
                ByteOrder = 'BigEndian',
                -- the Caplio RR1 uses a different base address -- doh!
                Base = function(_et, _val, start) return start - 20 end,
            },
        },
    },
    [0x4001] = {
        Name = 'ThetaSubdir',
        Groups = { [1] = 'MakerNotes' },    -- SubIFD needs group 1 set
        Flags = 'SubIFD',
        SubDirectory = {
            TagTable = 'lexiftool.Ricoh.ThetaSubdir',
            Start = function(_et, val, _valuePtr) return perl.num(val) end,
        },
    },
}

-- Ricoh type 2 maker notes (ref PH)
-- (similar to Kodak::Type11 and GE::Main)
Ricoh.Type2 = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        Tags written by models such as the Ricoh HZ15 and the Pentax XG-1.  These
        are not writable due to numerous formatting errors as written by these
        cameras.
    ]],
    -- 0x104 - int32u: 1
    -- 0x200 - int32u[3]: 0 0 0
    -- 0x202 - int16u: 0 (GE Macro?)
    -- 0x203 - int16u: 0,3 (Kodak PictureEffect?)
    -- 0x204 - rational64u: 0/10
    -- 0x205 - rational64u: 150/1
    -- 0x206 - float[6]: (not really float because size should be 2 bytes)
    [0x207] = {
        Name = 'RicohModel',
        Writable = 'string',
    },
    [0x300] = {
        -- brutal.  There are lots of errors in the XG-1 maker notes.  For the XG-1,
        -- 0x300 has a value of "XG-1Pentax".  The "XG-1" part is likely an improperly
        -- stored 0x207 RicohModel, resulting in an erroneous 4-byte offset for this tag
        Name = 'RicohMake',
        Writable = 'undef',
        ValueConv = function(_self, val) return subst(str(val), [[ *$]], '') end,
    },
    -- 0x306 - int16u: 1
    -- 0x500 - int16u: 0,1
    -- 0x501 - int16u: 0
    -- 0x502 - int16u: 0
    -- 0x9c9c - int8u[6]: ?
    -- 0xadad - int8u[20480]: ?
}

-- Ricoh image info (ref 2)
Ricoh.ImageInfo = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    PRIORITY = 0,
    FORMAT = 'int8u',
    FIRST_ENTRY = 0,
    IS_OFFSET = { 28 },   -- tag 28 is 'IsOffset'
    [0] = {
        Name = 'RicohImageWidth',
        Format = 'int16u',
    },
    [2] = {
        Name = 'RicohImageHeight',
        Format = 'int16u',
    },
    [6] = {
        Name = 'RicohDate',
        Groups = { [2] = 'Time' },
        Format = 'int8u[7]',
        -- (what an insane way to encode the date)
        -- upstream: `sprintf("%.2x%.2x:%.2x:%.2x %.2x:%.2x:%.2x",
        --                    split(' ', $val))` -- Perl numifies each field
        --  on the way into sprintf, Lua's string.format will not
        ValueConv = function(_self, val)
            local v = perl.split(' ', str(val))
            for i = 1, #v do v[i] = perl.num(v[i]) end
            return sprintf('%.2x%.2x:%.2x:%.2x %.2x:%.2x:%.2x', table.unpack(v))
        end,
        ValueConvInv = function(_self, val)
            local vals = perl.findAll(val, [[(\d{1,2})]])
            if #vals < 7 then vals[#vals + 1] = 0 end
            for i = 1, #vals do vals[i] = perl.hex(vals[i]) end
            return perl.join(' ', vals)
        end,
    },
    [28] = {
        Name = 'PreviewImageStart',
        Format = 'int16u', -- ha!  (only the lower 16 bits, even if > 0xffff)
        Flags = 'IsOffset',
        OffsetPair = 30,   -- associated byte count tagID
        DataTag = 'PreviewImage',
        Protected = 2,
        WriteGroup = 'MakerNotes',
        RawConvInv = function(self, val)
            if self.FILE_TYPE == 'JPEG' then return val end
            perl.warn("\n") -- suppress warning
            return nil
        end,
    },
    [30] = {
        Name = 'PreviewImageLength',
        Format = 'int16u',
        OffsetPair = 28,   -- point to associated offset
        DataTag = 'PreviewImage',
        Protected = 2,
        WriteGroup = 'MakerNotes',
        RawConvInv = function(self, val)
            if self.FILE_TYPE == 'JPEG' then return val end
            perl.warn("\n") -- suppress warning
            return nil
        end,
    },
    [32] = {
        Name = 'FlashMode',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Auto', --PH
            [2] = 'On',
        },
    },
    [33] = {
        Name = 'Macro',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [34] = {
        Name = 'Sharpness',
        PrintConv = {
            [0] = 'Sharp',
            [1] = 'Normal',
            [2] = 'Soft',
        },
    },
    [38] = {
        Name = 'WhiteBalance',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Daylight',
            [2] = 'Cloudy',
            [3] = 'Tungsten',
            [4] = 'Fluorescent',
            [5] = 'Manual', --PH (GXR)
            [7] = 'Detail',
            [9] = 'Multi-pattern Auto', --PH (GXR)
        },
    },
    [39] = {
        Name = 'ISOSetting',
        PrintConv = {
            [0] = 'Auto',
            [1] = 64,
            [2] = 100,
            [4] = 200,
            [6] = 400,
            [7] = 800,
            [8] = 1600,
            [9] = 'Auto', --PH (? CX3)
            [10] = 3200, --PH (A16)
            [11] = '100 (Low)', --PH (A16)
        },
    },
    [40] = {
        Name = 'Saturation',
        PrintConv = {
            [0] = 'High',
            [1] = 'Normal',
            [2] = 'Low',
            [3] = 'B&W',
            [6] = 'Toning Effect', --PH (GXR Sepia,Red,Green,Blue,Purple)
            [9] = 'Vivid', --PH (GXR)
            [10] = 'Natural', --PH (GXR)
        },
    },
}

-- Ricoh subdirectory tags (ref PH)
-- NOTE: this subdir is currently not writable because the offsets would require
-- special code to handle the funny start location and base offset
Ricoh.Subdir = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    -- the significance of the following 2 dates is not known.  They are usually
    -- within a month of each other, but I have seen differences of nearly a year.
    -- Sometimes the first is more recent, and sometimes the second.
    -- 0x0003 - int32u[1]
    [0x0004] = { -- (NC)
        Name = 'ManufactureDate1',
        Groups = { [2] = 'Time' },
        Writable = 'string',
        Count = 20,
    },
    [0x0005] = { -- (NC)
        Name = 'ManufactureDate2',
        Groups = { [2] = 'Time' },
        Writable = 'string',
        Count = 20,
    },
    -- 0x0006 - undef[16] ?
    -- 0x0007 - int32u[1] ?
    -- 0x000c - int32u[2] 1st number is a counter (file number? shutter count?) - PH
    -- 0x0014 - int8u[338] could contain some data related to face detection? - PH
    -- 0x0015 - int8u[2]: related to noise reduction?
    [0x001a] = { --PH
        Name = 'FaceInfo',
        SubDirectory = { TagTable = 'lexiftool.Ricoh.FaceInfo' },
    },
    [0x0029] = {
        Name = 'FirmwareInfo',
        SubDirectory = { TagTable = 'lexiftool.Ricoh.FirmwareInfo' },
    },
    [0x002a] = {
        Name = 'NoiseReduction',
        -- this is the applied value if NR is set to "Auto"
        Writable = 'int32u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'Weak',
            [2] = 'Strong',
            [3] = 'Max',
        },
    },
    [0x002c] = { -- (GXR)
        Name = 'SerialInfo',
        SubDirectory = { TagTable = 'lexiftool.Ricoh.SerialInfo' },
    },
    -- 0x000E ProductionNumber? (ref 2) [no. zero for most models - PH]
}

-- Ricoh Theta subdirectory tags - Contains orientation information (ref 4)
Ricoh.ThetaSubdir = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    -- 0x0001 - int16u[1] ?
    -- 0x0002 - int16u[1] ?
    [0x0003] = {
        Name = 'Accelerometer',
        Writable = 'rational64s',
        Count = 2,
    },
    [0x0004] = {
        Name = 'Compass',
        Writable = 'rational64u',
    },
    -- 0x0005 - int16u[1] ?
    -- 0x0006 - int16u[1] ?
    -- 0x0007 - int16u[1] ?
    -- 0x0008 - int16u[1] ?
    -- 0x0009 - int16u[1] ?
    [0x000a] = {
        Name = 'TimeZone',
        Writable = 'string',
    },
    -- 0x0101 - int16u[4] ISO (why 4 values?)
    -- 0x0102 - rational64s[2] FNumber (why 2 values?)
    -- 0x0103 - rational64u[2] ExposureTime (why 2 values?)
    -- 0x0104 - string[9] SerialNumber?
    -- 0x0105 - string[9] SerialNumber?
}

-- face detection information (ref PH, CX4)
Ricoh.FaceInfo = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    FIRST_ENTRY = 0,
    DATAMEMBER = { 181 },
    [0xb5] = { -- (should be int16u at 0xb4?)
        Name = 'FacesDetected',
        DataMember = 'FacesDetected',
        RawConv = function(self, val) self.FacesDetected = val return val end,
    },
    [0xb6] = {
        Name = 'FaceDetectFrameSize',
        Format = 'int16u[2]',
    },
    [0xbc] = {
        Name = 'Face1Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 1 end,
        Format = 'int16u[4]',
        Notes = [[
            left, top, width and height of detected face in coordinates of
            FaceDetectFrameSize with increasing Y downwards
        ]],
    },
    [0xc8] = {
        Name = 'Face2Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 2 end,
        Format = 'int16u[4]',
    },
    [0xd4] = {
        Name = 'Face3Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 3 end,
        Format = 'int16u[4]',
    },
    [0xe0] = {
        Name = 'Face4Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 4 end,
        Format = 'int16u[4]',
    },
    [0xec] = {
        Name = 'Face5Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 5 end,
        Format = 'int16u[4]',
    },
    [0xf8] = {
        Name = 'Face6Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 6 end,
        Format = 'int16u[4]',
    },
    [0x104] = {
        Name = 'Face7Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 7 end,
        Format = 'int16u[4]',
    },
    [0x110] = {
        Name = 'Face8Position',
        Condition = function(self) return perl.num(self.FacesDetected) >= 8 end,
        Format = 'int16u[4]',
    },
}

-- firmware version information (ref PH)
Ricoh.FirmwareInfo = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    [0x00] = {
        Name = 'FirmwareRevision',
        Format = 'string[12]',
    },
    [0x0c] = {
        Name = 'FirmwareRevision2',
        Format = 'string[12]',
    },
}

-- serial/version number information written by GXR (ref PH)
Ricoh.SerialInfo = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    NOTES = 'This information is found in images from the GXR.',
    [0] = {
        Name = 'BodyFirmware', --(NC)
        Format = 'string[16]',
        -- observed: "RS1 :V00560000" --> FirmwareVersion "Rev0056"
        --           "RS1 :V01020200" --> FirmwareVersion "Rev0102"
    },
    [16] = {
        Name = 'BodySerialNumber',
        Format = 'string[16]',
        -- observed: "SID:00100056" --> "WD00100056" on plate
    },
    [32] = {
        Name = 'LensFirmware', --(NC)
        Format = 'string[16]',
        -- observed: "RL1 :V00560000", "RL1 :V01020200" - A12 50mm F2.5 Macro
        --           "RL2 :V00560000", "RL2 :V01020300" - S10 24-70mm F2.5-4.4 VC
        -- --> used in a Composite tag to determine LensType
    },
    [48] = {
        Name = 'LensSerialNumber',
        Format = 'string[16]',
        -- observed: (S10) "LID:00010024" --> "WF00010024" on plate
        --           (A12) "LID:00010054" --> "WE00010029" on plate??
    },
}

-- upstream `$val=~/^\d+$/ ? sprintf("%.2f",$val/100) : $val`, shared by the
-- two spellings (Rev/Rv) of the text maker notes' firmware tag
local function textFirmwareVersion(_self, val)
    if matches(str(val), [[^\d+$]]) then
        return sprintf('%.2f', perl.num(val) / 100)
    end
    return val
end

-- Ricoh text-type maker notes (PH)
Ricoh.Text = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        Some Ricoh DC and RDC models use a text-based format for their maker notes
        instead of the IFD format used by the Caplio models.  Below is a list of known
        tags in this information.
    ]],
    Rev = {
        Name = 'FirmwareVersion',
        PrintConv = textFirmwareVersion,
        PrintConvInv = function(_self, val)
            local a, b = matches(val, [[^(\d+)\.(\d+)$]])
            if a then return sprintf('%.2d%.2d', a, b) end
            return val
        end,
    },
    Rv = {
        Name = 'FirmwareVersion',
        PrintConv = textFirmwareVersion,
        PrintConvInv = function(_self, val)
            local a, b = matches(val, [[^(\d+)\.(\d+)$]])
            if a then return sprintf('%.2d%.2d', a, b) end
            return val
        end,
    },
    Rg = 'RedGain',
    Gg = 'GreenGain',
    Bg = 'BlueGain',
}

-- Ricoh RMETA APP5 (ref PH)
Ricoh.RMETA = {
    GROUPS = { [0] = 'APP5', [1] = 'RMETA', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        The Ricoh Caplio Pro G3 has the ability to add custom fields to the APP5
        "RMETA" segment of JPEG images.  While only a few observed tags have been
        defined below, ExifTool will extract any information found here.
    ]],
    ['Sign type'] = { Name = 'SignType', PrintConv = {
        [1] = 'Directional',
        [2] = 'Warning',
        [3] = 'Information',
    } },
    Location = { PrintConv = {
        [1] = 'Verge',
        [2] = 'Gantry',
        [3] = 'Central reservation',
        [4] = 'Roundabout',
    } },
    Lit = { PrintConv = {
        [1] = 'Yes',
        [2] = 'No',
    } },
    Condition = { PrintConv = {
        [1] = 'Good',
        [2] = 'Fair',
        [3] = 'Poor',
        [4] = 'Damaged',
    } },
    Azimuth = { PrintConv = {
        [1] = 'N',
        [2] = 'NNE',
        [3] = 'NE',
        [4] = 'ENE',
        [5] = 'E',
        [6] = 'ESE',
        [7] = 'SE',
        [8] = 'SSE',
        [9] = 'S',
        [10] = 'SSW',
        [11] = 'SW',
        [12] = 'WSW',
        [13] = 'W',
        [14] = 'WNW',
        [15] = 'NW',
        [16] = 'NNW',
    } },
    _audio = {
        Name = 'SoundFile',
        Notes = 'audio data recorded in JPEG images by the G700SE',
    },
    _barcode = { Name = 'Barcodes', List = 1 },
}

-- information stored in Ricoh AVI images (ref PH)
Ricoh.AVI = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Video' },
    ucmt = {
        Name = 'Comment',
        -- Ricoh writes a "Unicode" header even when text is ASCII (spaces anyway)
        ValueConv = function(_self, val)
            local s = subst(str(val), [[^(Unicode\0|ASCII\0\0\0)]], '')
            s = s:gsub('\0', '')
            return subst(s, [[\s+$]], '')
        end,
    },
    mnrt = {
        Name = 'MakerNoteRicoh',
        SubDirectory = {
            TagTable = 'lexiftool.Ricoh.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'BigEndian',
            Base = function(_self, _val, _start) return 8 end,
        },
    },
    rdc2 = {
        Name = 'RicohRDC2',
        Unknown = 1,
        ValueConv = function(_self, val) return unpack('H*', str(val)) end,
        -- have seen values like 0a000444 and 00000000 - PH
    },
    thum = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
}

-- real-time metadata in RDTA atom (ref 5)
Ricoh.RDTA = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Location' },
    [0] = { Name = 'Accelerometer', Format = 'float[3]' },
    [16] = { Name = 'TimeStamp', Format = 'int64u', ValueConv = nanoToSec },
}

-- real-time metadata in RDTB atom (ref 5)
Ricoh.RDTB = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Location' },
    [0] = { Name = 'Gyroscope', Format = 'float[3]', Notes = 'rad/s' },
    [16] = { Name = 'TimeStamp', Format = 'int64u', ValueConv = nanoToSec },
}

-- real-time metadata in RDTC atom (ref 5)
Ricoh.RDTC = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Location' },
    [0] = { Name = 'MagneticField', Format = 'float[3]' },
    [16] = { Name = 'TimeStamp', Format = 'int64u', ValueConv = nanoToSec },
}

-- real-time metadata in RDTG atom (ref 5)
Ricoh.RDTG = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Video' },
    [0] = { Name = 'TimeStamp', Format = 'int64u', ValueConv = nanoToSec },
    [100] = { Name = 'FrameNumber', Notes = 'generated internally' },
}

-- real-time metadata in RDTL atom (ref 5)
Ricoh.RDTL = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Location' },
    [0] = {
        Name = 'GPSDateTime',
        Groups = { [2] = 'Time' },
        Format = 'double',
        ValueConv = function(_self, val) -- (NC -- what is the epoch?)
            return ExifTool.ConvertUnixTime(perl.num(val) * 1e-9, 1, 9)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [8] = {
        Name = 'GPSLatitude',
        Format = 'double',
        PrintConv = function(self, val)
            return require('lexiftool.GPS').ToDMS(self, val, 1)
        end,
    },
    [16] = {
        Name = 'GPSLongitude',
        Format = 'double',
        PrintConv = function(self, val)
            return require('lexiftool.GPS').ToDMS(self, val, 1)
        end,
    },
    [24] = {
        Name = 'GPSAltitude',
        Format = 'double',
        PrintConv = function(_self, val)
            -- upstream tests the substitution itself: a leading '-' is
            -- stripped and turns "Above" into "Below"
            local s = str(val)
            local stripped = subst(s, [[^-]], '')
            return (stripped ~= s and (stripped .. ' m Below') or (s .. ' m Above')) ..
                   ' Sea Level'
        end,
    },
}

-- Ricoh composite tags
Ricoh.Composite = {
    GROUPS = { [2] = 'Camera' },
    LensID = {
        SeparateTable = 'Ricoh LensID',
        Require = 'Ricoh:LensFirmware',
        RawConv = function(_self, val)
            if perlTruthy(val[0]) then return val[0] end
            return nil
        end,
        ValueConv = function(_self, val) return subst(perl.str(val), [[\s*:.*]], '') end,
        PrintConv = ricohLensIDs,
    },
    RicohPitch = {
        Require = 'Ricoh:Accelerometer',
        ValueConv = function(_self, val)
            local v = perl.split(' ', val[0])
            return v[2]
        end,
    },
    RicohRoll = {
        Require = 'Ricoh:Accelerometer',
        ValueConv = function(_self, val)
            local v = perl.split(' ', val[0])
            return perl.num(v[1]) <= 180 and v[1] or perl.num(v[1]) - 360
        end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.Ricoh', nil, Ricoh)

--------------------------------------------------------------------------------
-- Process Ricoh RDT* real-time metadata
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function Ricoh.ProcessRicohRDT(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local dirName = dirInfo.DirName
    local rdtg
    if dirLen < 16 then return 0 end
    local ee = perl.num(et:Options('ExtractEmbedded') or 0)
    if not perlTruthy(et:Options('ExtractEmbedded')) then
        et:Warn('Use ExtractEmbedded option to read Ricoh real-time metadata', 3)
        return 1
    end
    local endian = substr(dataPt, 8, 2)
    et.SetByteOrder(endian == '\x23\x01' and 'II' or 'MM')
    local count = et.Get32u(dataPt, 0)
    local len = et.Get16u(dataPt, 6)
    if dirName == 'RicohRDTG' then
        if ee < 2 then
            et:Warn('Set ExtractEmbedded option to 2 or higher to extract frame timestamps', 3)
            return 1
        end
        rdtg = 0
        if len > 8 then et:Warn('Unexpected RDTG record length') end
    end
    if count * len + 16 > dirLen then
        et:Warn('Truncated ' .. dirName .. ' data')
        count = (dirLen - 16) // len
    end
    et:VerboseDir(dirName)
    dirInfo.DirStart = 16
    dirInfo.DirLen = len
    for _ = 0, count - 1 do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        if rdtg ~= nil then
            et:HandleTag(tagTablePtr, 100, rdtg)
            rdtg = rdtg + 1
        end
        et:ProcessBinaryData(dirInfo, tagTablePtr)
        dirInfo.DirStart = dirInfo.DirStart + len
    end
    et.DOC_NUM = nil
    return 1
end

--------------------------------------------------------------------------------
-- Process Ricoh text-based maker notes
-- Inputs: 0) ExifTool object reference
--         1) Reference to directory information hash
--         2) Pointer to tag table for this directory
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function Ricoh.ProcessRicohText(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataLen = dirInfo.DataLen
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (dataLen - dirStart)
    local verbose = et:Options('Verbose')

    local data = substr(dataPt, dirStart, dirLen)
    if matches(data, [[^\0]]) then return 1 end     -- blank Ricoh maker notes
    et:VerboseDir('RicohText', nil, dirLen)
    -- validate text maker notes
    if not matches(data, [[^(Rev|Rv)]]) then
        et:Warn('Bad Ricoh maker notes')
        return 0
    end
    for tag, val in perl.eachMatch(data, [[(?s)([A-Z][a-z]{1,2})([0-9A-F]+);]]) do
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if perlTruthy(verbose) then
            et:VerboseInfo(tag, tagInfo, {
                Table  = tagTablePtr,
                Value  = val,
            })
        end
        if not tagInfo then
            if perlTruthy(et.OPTIONS.Unknown) then
                tagInfo = {
                    Name = 'Ricoh_Text_' .. tag,
                    Unknown = 1,
                    PrintConv = function(self, v) return ExifTool.LimitLongValues(v, self) end,
                }
                -- add tag information to table
                et:AddTagToTable(tagTablePtr, tag, tagInfo)
                et:FoundTag(tagInfo, val)
            end
        else
            et:FoundTag(tagInfo, val)
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process Ricoh APP5 RMETA information
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function Ricoh.ProcessRicohRMETA(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dataLen = #dataPt
    local dirLen = dataLen - dirStart
    local verbose = et:Options('Verbose')

    if perlTruthy(verbose) then et:VerboseDir('Ricoh RMETA') end
    if dirLen < 20 then
        et:Warn('Truncated Ricoh RMETA data', 1)
        return 0
    end
    local byteOrder = substr(dataPt, dirStart, 2)
    if byteOrder == '\0\0' then byteOrder = et.GetByteOrder() end -- (same order as container)
    if not et.SetByteOrder(byteOrder) then
        et:Warn('Bad Ricoh RMETA data', 1)
        return 0
    end
    -- get the RMETA segment number
    local rmetaNum = et.Get16u(dataPt, dirStart + 4)
    if rmetaNum ~= 0 then
        -- (audio/barcode RMETA segments are not handled in the ported subset)
        return 1
    end
    -- decode standard RMETA tag directory
    local tags = {}
    local vals = {}
    local nums
    local valPos
    local numPos
    local pos = dirStart + et.Get16u(dataPt, dirStart + 8)
    local numEntries = et.Get16u(dataPt, pos)
    if numEntries > 100 then
        et:Warn('Bad RMETA entry count')
        return 0
    end
    pos = pos + 10 -- start of first RMETA section
    -- loop through RMETA sections
    while pos <= dataLen - 4 do
        local type_ = et.Get16u(dataPt, pos)
        local size = et.Get16u(dataPt, pos + 2)
        if size == 0 then break end
        pos = pos + 4
        size = size - 2
        if size < 0 or pos + size > dataLen then
            et:Warn('Corrupted Ricoh RMETA data', 1)
            break
        end
        local dat = substr(dataPt, pos, size)
        if perlTruthy(verbose) then
            et:VPrint(2, et.INDENT .. 'RMETA section type=' .. type_ .. ' size=' .. size .. '\n')
            et:VerboseDump(dat, { Addr = (dirInfo.DataPos or 0) + pos })
        end
        if type_ == 1 then -- section 1: tag names
            -- save the tag names
            local i = 1
            while i <= #dat and #tags < numEntries do
                local e = dat:find('\0', i, true)
                if not e then break end
                tags[#tags + 1] = dat:sub(i, e - 1)
                i = e + 1
            end
        elseif type_ == 2 or type_ == 18 then -- section 2/18: string values
            -- save the tag values (assume "ASCII\0" encoding since others never seen)
            local i = 1
            while i <= #dat and #vals < numEntries do
                local e = dat:find('\0', i, true)
                if not e then break end
                vals[#vals + 1] = dat:sub(i, e - 1)
                i = e + 1
            end
            valPos = pos -- save position of first string value
        elseif type_ == 3 then -- section 3: numerical values
            if size < numEntries * 2 then
                et:Warn('Truncated RMETA section 3')
            else
                -- save the numerical tag values
                nums = { unpack((byteOrder == 'MM' and 'n' or 'v') .. numEntries, dat) }
                numPos = pos -- save position of numerical values
            end
        elseif type_ ~= 16 then
            et:Warn('Unrecognized RMETA section (type ' .. type_ .. ', len ' .. size .. ')')
        end
        pos = pos + size
    end
    if #tags == 0 and #vals == 0 then return 1 end
    valPos = valPos or 0 -- (just in case there was no value section)
    -- find next tag in null-delimited list
    for i = 1, numEntries do
        local tag = tags[i]
        local val = vals[i] or ''
        if not (tag and #tag > 0) then
            if #val == 0 then
                valPos = valPos + 1 -- (skip empty entries)
                goto continue
            end
            tag = ''
        end
        local name
        if tag and #tag > 0 then
            name = subst(tag, [[\b([a-z])]], function(c) return uc(c) end, 'g') -- capitalize all words
            name = subst(name, [[ (\w)]], function(c) return uc(c) end, 'g') -- remove special characters
        end
        if not name or #name == 0 then name = 'RMETA_Unknown' end
        local num = nums and nums[i]
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo then
            -- make sure print conversion is defined
            if type(tagInfo.PrintConv) ~= 'table' then tagInfo.PrintConv = {} end
        else
            -- create tagInfo hash
            tagInfo = { Name = name, PrintConv = {} }
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        -- use string value directly if no numerical value
        if num == nil then num = val end
        -- add conversion for this value (replacing any existing entry)
        tagInfo.PrintConv[num] = (#val > 0 and val or num)
        if perlTruthy(verbose) then
            local datParms
            if #val > 0 then
                datParms = { Start = valPos, Size = #val, Format = 'string' }
            elseif numPos then
                datParms = { Start = numPos + (i - 1) * 2, Size = 2, Format = 'int16u' }
            end
            if datParms then
                datParms.DataPt = dataPt
                datParms.DataPos = dirInfo.DataPos
            else
                datParms = {}
            end
            datParms.Table = tagTablePtr
            datParms.Value = num
            et:VerboseInfo(tag, tagInfo, datParms)
        end
        et:FoundTag(tagInfo, num)
        valPos = valPos + #val + 1
        ::continue::
    end
    return 1
end

-- (PROCESS_PROCs are set here so the tables can reference the functions above)
Ricoh.Text.PROCESS_PROC = Ricoh.ProcessRicohText
Ricoh.RMETA.PROCESS_PROC = Ricoh.ProcessRicohRMETA
Ricoh.RDTA.PROCESS_PROC = Ricoh.ProcessRicohRDT
Ricoh.RDTB.PROCESS_PROC = Ricoh.ProcessRicohRDT
Ricoh.RDTC.PROCESS_PROC = Ricoh.ProcessRicohRDT
Ricoh.RDTG.PROCESS_PROC = Ricoh.ProcessRicohRDT

return Ricoh
