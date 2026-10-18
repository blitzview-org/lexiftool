--------------------------------------------------------------------------------
-- File:         lexiftool/Matroska.lua
-- Ported from:  lib/Image/ExifTool/Matroska.pm
--
-- Description:  Read meta information from Matroska multimedia files
--
-- Revisions:    05/26/2010 - P. Harvey Created
--
-- References:   1) http://www.matroska.org/technical/specs/index.html
--               2) https://www.matroska.org/technical/tagging.html
--
-- Port notes:   read port. Ported in full: the EBML element walker
--               (ProcessMKV incl. the 64 kB sliding-buffer reads, the
--               directory-end stack, SeekHead-based jump to Tags past the
--               first Cluster, SimpleTag struct collection + HandleStruct),
--               GetVInt, and the Main/Projection/StdTag tables with the
--               custom signed/unsigned/float/date/string/utf8 formats.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local substr = require('lexiftool.perl').substr
local split = require('lexiftool.perl').split
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str
local lc = require('lexiftool.perl').lc
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst

local Matroska = {}

local noYes = { [0] = 'No', [1] = 'Yes' }

-- (port: upstream spreads %dateInfo into each entry; this builds the entry
--  from its Name and any further fields of it)
local function dateInfo(name, more)
    local t = {
        Name = name,
        Groups = { [2] = 'Time' },
        -- the spec says to use "-" as a date separator, but my only sample uses ":",
        -- so convert to ":" if necessary (upstream ValueConv)
        ValueConv = function(_self, val)
            return (str(val):gsub('^(%d%d%d%d)%-(%d%d)%-', '%1:%2:'))
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    }
    for k, v in pairs(more or {}) do t[k] = v end
    return t
end

local uidInfo = {
    Format = 'string',
    ValueConv = function(_self, val)
        local out = {}
        for i = 1, #val do out[#out + 1] = string.format('%02x', val:byte(i)) end
        return table.concat(out)
    end,
}

-- merge the shared UID fields into a tag entry
local function uidTag(name, extra)
    local t = { Name = name, Format = uidInfo.Format, ValueConv = uidInfo.ValueConv }
    if extra then
        for k, v in pairs(extra) do t[k] = v end
    end
    return t
end

-- Matroska tags
-- Note: The tag ID's in the Matroska documentation include the length designation
--       (the upper bits), which is not included in the tag ID's below
Matroska.Main = {
    GROUPS = { [2] = 'Video' },
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        The following tags are extracted from Matroska multimedia container files.
        This container format is used by file types such as MKA, MKV, MKS and WEBM.
        For speed, by default ExifTool extracts tags only up to the first Cluster
        unless a Seek element specifies the position of a Tags element after this.
        However, the L<Verbose|../ExifTool.html#Verbose> (-v) and L<Unknown|../ExifTool.html#Unknown> = 2 (-U) options force processing of
        Cluster data, and the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option skips over Clusters to
        read subsequent tags.  See
        L<http://www.matroska.org/technical/specs/index.html> for the official
        Matroska specification.
    ]],
    -- supported Format's: signed, unsigned, float, date, string, utf8
    -- (or undef by default)
--
-- EBML Header
--
    [0x0a45dfa3] = {
        Name = 'EBMLHeader',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x286] = { Name = 'EBMLVersion',       Format = 'unsigned' },
    [0x2f7] = { Name = 'EBMLReadVersion',   Format = 'unsigned' },
    [0x2f2] = { Name = 'EBMLMaxIDLength',   Format = 'unsigned', Unknown = 1 },
    [0x2f3] = { Name = 'EBMLMaxSizeLength', Format = 'unsigned', Unknown = 1 },
    [0x282] = {
        Name = 'DocType',
        Format = 'string',
        -- override FileType for "webm" files
        RawConv = function(self, val)
            if val == 'webm' then self:OverrideFileType('WEBM') end
            return val
        end,
    },
    [0x287] = { Name = 'DocTypeVersion',    Format = 'unsigned' },
    [0x285] = { Name = 'DocTypeReadVersion',Format = 'unsigned' },
--
-- General
--
    [0x3f]  = { Name = 'CRC-32',            Format = 'unsigned', Unknown = 1 },
    [0x6c]  = { Name = 'Void',              NoSave = 1, Unknown = 1 },
--
-- Signature
--
    [0x0b538667] = {
        Name = 'SignatureSlot',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x3e8a] = { Name = 'SignatureAlgo',    Format = 'unsigned' },
    [0x3e9a] = { Name = 'SignatureHash',    Format = 'unsigned' },
    [0x3ea5] = { Name ='SignaturePublicKey',Binary = 1, Unknown = 1 },
    [0x3eb5] = { Name = 'Signature',        Binary = 1, Unknown = 1 },
    [0x3e5b] = {
        Name = 'SignatureElements',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x3e7b] = {
        Name = 'SignatureElementList',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x2532] = { Name = 'SignedElement',    Binary = 1, Unknown = 1 },
--
-- Segment
--
    [0x08538067] = {
        Name = 'SegmentHeader',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x14d9b74] = {
        Name = 'SeekHead',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0xdbb] = {
        Name = 'Seek',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x13ab] = {
        Name = 'SeekID',
        Unknown = 1,
        SeekInfo = 'ID',        -- save seek ID's
        -- (note: converted from VInt internally)
        PrintConv = function(_self, val)
            local tagInfo = Matroska.Main[val]
            local out = sprintf('0x%x', val)
            if type(tagInfo) == 'table' and tagInfo.Name then out = out .. ' (' .. tagInfo.Name .. ')' end
            return out
        end,
    },
    [0x13ac] = {
        Name = 'SeekPosition',
        Format = 'unsigned',
        Unknown = 1,
        SeekInfo = 'Position',  -- save seek positions
        RawConv = function(self, val) return val + (self.SeekHeadOffset or 0) end,
    },
--
-- Segment Info
--
    [0x0549a966] = {
        Name = 'Info',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x33a4] = uidTag('SegmentUID', { Unknown = 1 }),
    [0x3384] = { Name = 'SegmentFileName',  Format = 'utf8' },
    [0x1cb923] = uidTag('PrevUID', { Unknown = 1 }),
    [0x1c83ab] = { Name = 'PrevFileName',   Format = 'utf8' },
    [0x1eb923] = uidTag('NextUID', { Unknown = 1 }),
    [0x1e83bb] = { Name = 'NextFileName',   Format = 'utf8' },
    [0x0444] = { Name = 'SegmentFamily',    Binary = 1, Unknown = 1 },
    [0x2924] = {
        Name = 'ChapterTranslate',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x29fc] = uidTag('ChapterTranslateEditionUID', { Unknown = 1 }),
    [0x29bf] = {
        Name = 'ChapterTranslateCodec',
        Format = 'unsigned',
        PrintConv = { [0] = 'Matroska Script', [1] = 'DVD Menu' },
    },
    [0x29a5] = { Name = 'ChapterTranslateID',Binary = 1, Unknown = 1 },
    [0xad7b1] = {
        Name = 'TimecodeScale',
        Format = 'unsigned',
        RawConv = function(self, val) self.TimecodeScale = val return val end,
        ValueConv = function(_self, val) return val / 1e9 end,
        PrintConv = function(_self, val) return ExifTool.NumStr(val * 1000) .. ' ms' end,
    },
    [0x489] = {
        Name = 'Duration',
        Format = 'float',
        ValueConv = function(self, val)
            return self.TimecodeScale and val * self.TimecodeScale / 1e9 or val / 1000
        end,
        PrintConv = function(self, val)
            return self.TimecodeScale and ExifTool.ConvertDuration(val) or val
        end,
    },
    [0x461] = {
        Name = 'DateTimeOriginal', -- called "DateUTC" by the spec
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Format = 'date',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [0x3ba9] = { Name = 'Title',            Format = 'utf8' },
    [0xd80] = { Name = 'MuxingApp',         Format = 'utf8' },
    [0x1741] = { Name = 'WritingApp',       Format = 'utf8' },
--
-- Cluster
--
    [0x0f43b675] = {
        Name = 'Cluster',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x67] = {
        Name = 'TimeCode',
        Format = 'unsigned',
        Unknown = 1,
        ValueConv = function(self, val)
            return self.TimecodeScale and val * self.TimecodeScale / 1e9 or val
        end,
        PrintConv = function(self, val)
            return self.TimecodeScale and ExifTool.ConvertDuration(val) or val
        end,
    },
    [0x1854] = {
        Name = 'SilentTracks',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x18d7] = { Name = 'SilentTrackNumber',Format = 'unsigned' },
    [0x27]  = { Name = 'Position',          Format = 'unsigned' },
    [0x2b]  = { Name = 'PrevSize',          Format = 'unsigned' },
    [0x23]  = { Name = 'SimpleBlock',       NoSave = 1, Unknown = 1 },
    [0x20] = {
        Name = 'BlockGroup',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x21]  = { Name = 'Block',             NoSave = 1, Unknown = 1 },
    [0x22]  = { Name = 'BlockVirtual',      NoSave = 1, Unknown = 1 },
    [0x35a1] = {
        Name = 'BlockAdditions',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x26] = {
        Name = 'BlockMore',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x6e]  = { Name = 'BlockAddID',        Format = 'unsigned', Unknown = 1 },
    [0x25]  = { Name = 'BlockAdditional',   NoSave = 1, Unknown = 1 },
    [0x1b] = {
        Name = 'BlockDuration',
        Format = 'unsigned',
        Unknown = 1,
        ValueConv = function(self, val)
            return self.TimecodeScale and val * self.TimecodeScale / 1e9 or val
        end,
        PrintConv = function(self, val) return self.TimecodeScale and (val .. ' s') or val end,
    },
    [0x7a]  = { Name = 'ReferencePriority',Format = 'unsigned', Unknown = 1 },
    [0x7b] = {
        Name = 'ReferenceBlock',
        Format = 'signed',
        Unknown = 1,
        ValueConv = function(self, val)
            return self.TimecodeScale and val * self.TimecodeScale / 1e9 or val
        end,
        PrintConv = function(self, val) return self.TimecodeScale and (val .. ' s') or val end,
    },
    [0x7d]  = { Name = 'ReferenceVirtual',  Format = 'signed', Unknown = 1 },
    [0x24]  = { Name = 'CodecState',        Binary = 1, Unknown = 1 },
    [0x0e] = {
        Name = 'Slices',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x68] = {
        Name = 'TimeSlice',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x4c]  = { Name = 'LaceNumber',        Format = 'unsigned', Unknown = 1 },
    [0x4d]  = { Name = 'FrameNumber',       Format = 'unsigned', Unknown = 1 },
    [0x4b]  = { Name = 'BlockAdditionalID', Format = 'unsigned', Unknown = 1 },
    [0x4e]  = { Name = 'Delay',             Format = 'unsigned', Unknown = 1 },
    [0x4f]  = { Name = 'ClusterDuration',   Format = 'unsigned', Unknown = 1 },
    [0x2f]  = { Name = 'EncryptedBlock',    NoSave = 1, Unknown = 1 },
--
-- Tracks
--
    [0x0654ae6b] = {
        Name = 'Tracks',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x2e] = {
        Name = 'TrackEntry',
        -- reset TrackType member at the start of each track
        Condition = function(self) self.TrackType = nil return true end,
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x57]  = { Name = 'TrackNumber',       Format = 'unsigned' },
    [0x33c5] = uidTag('TrackUID'),
    [0x03] = {
        Name = 'TrackType',
        Format = 'unsigned',
        PrintHex = 1,
        -- remember types of all tracks encountered, as well as the current track type
        RawConv = function(self, val)
            self.TrackTypes[val] = true
            self.TrackType = val
            return val
        end,
        PrintConv = {
            [0x01] = 'Video',
            [0x02] = 'Audio',
            [0x03] = 'Complex', -- (audio+video)
            [0x10] = 'Logo',
            [0x11] = 'Subtitle',
            [0x12] = 'Buttons',
            [0x20] = 'Control',
        },
    },
    [0x39]  = { Name = 'TrackUsed',         Format = 'unsigned', PrintConv = noYes },
    [0x08]  = { Name = 'TrackDefault',      Format = 'unsigned', PrintConv = noYes },
    [0x15aa] = { Name = 'TrackForced',      Format = 'unsigned', PrintConv = noYes },
    [0x1c] = {
        Name = 'TrackLacing',
        Format = 'unsigned',
        Unknown = 1,
        PrintConv = noYes,
    },
    [0x2de7] = { Name = 'MinCache',         Format = 'unsigned', Unknown = 1 },
    [0x2df8] = { Name = 'MaxCache',         Format = 'unsigned', Unknown = 1 },
    [0x3e383] = {
        {
            Name = 'VideoFrameRate',
            Condition = function(self) return self.TrackType ~= nil and self.TrackType == 0x01 end,
            Format = 'unsigned',
            ValueConv = function(_self, val) return val ~= 0 and 1e9 / val or 0 end,
            PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
        },{
            Name = 'DefaultDuration',
            Format = 'unsigned',
            ValueConv = function(_self, val) return val / 1e9 end,
            PrintConv = function(_self, val) return ExifTool.NumStr(val * 1000) .. ' ms' end,
        }
    },
    [0x3314f] = { Name = 'TrackTimecodeScale',Format = 'float' },
    [0x137f] = { Name = 'TrackOffset',        Format = 'signed', Unknown = 1 },
    [0x15ee] = { Name = 'MaxBlockAdditionID', Format = 'unsigned', Unknown = 1 },
    [0x136e] = { Name = 'TrackName',          Format = 'utf8' },
    [0x2b59c] = { Name = 'TrackLanguage',     Format = 'string' },
    [0x2b59d] = { Name = 'TrackLanguageIETF', Format = 'string' },
    [0x06] = {
        {
            Name = 'VideoCodecID',
            Condition = function(self) return self.TrackType ~= nil and self.TrackType == 0x01 end,
            Format = 'string',
        },{
            Name = 'AudioCodecID',
            Condition = function(self) return self.TrackType ~= nil and self.TrackType == 0x02 end,
            Format = 'string',
        },{
            Name = 'CodecID',
            Format = 'string',
        }
    },
    [0x23a2] = { Name = 'CodecPrivate',     Binary = 1, Unknown = 1 },
    [0x58688] = {
        {
            Name = 'VideoCodecName',
            Condition = function(self) return self.TrackType ~= nil and self.TrackType == 0x01 end,
            Format = 'utf8',
        },{
            Name = 'AudioCodecName',
            Condition = function(self) return self.TrackType ~= nil and self.TrackType == 0x02 end,
            Format = 'utf8',
        },{
            Name = 'CodecName',
            Format = 'utf8',
        }
    },
    [0x3446] = uidTag('TrackAttachmentUID'),
    [0x1a9697]= { Name = 'CodecSettings',   Format = 'utf8' },
    [0x1b4040]= { Name = 'CodecInfoURL',    Format = 'string' },
    [0x6b240] = { Name = 'CodecDownloadURL',Format = 'string' },
    [0x2a]  = { Name = 'CodecDecodeAll',    Format = 'unsigned', PrintConv = noYes },
    [0x2fab] = { Name = 'TrackOverlay',     Format = 'unsigned', Unknown = 1 },
    [0x2624] = {
        Name = 'TrackTranslate',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x26fc] = uidTag('TrackTranslateEditionUID', { Unknown = 1 }),
    [0x26bf] = {
        Name = 'TrackTranslateCodec',
        Format = 'unsigned',
        PrintConv = { [0] = 'Matroska Script', [1] = 'DVD Menu' },
    },
    [0x26a5] = { Name = 'TrackTranslateTrackID', Binary = 1, Unknown = 1 },
--
-- Video
--
    [0x60] = {
        Name = 'Video',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x1a] = {
        Name = 'VideoScanType',
        Format = 'unsigned',
        PrintConv = {
            [0] = 'Undetermined',
            [1] = 'Interlaced',
            [2] = 'Progressive',
        },
    },
    [0x13b8] = {
        Name = 'Stereo3DMode',
        Format = 'unsigned',
        -- (upstream has a typo here: `Printconv` instead of `PrintConv`, so
        --  the lookup never applies -- kept verbatim, inert as upstream)
        Printconv = {
            [0] = 'Mono',
            [1] = 'Right Eye',
            [2] = 'Left Eye',
            [3] = 'Both Eyes',
        },
    },
    [0x30]  = { Name = 'ImageWidth',        Format = 'unsigned' },
    [0x3a]  = { Name = 'ImageHeight',       Format = 'unsigned' },
    [0x14aa] = { Name = 'CropBottom',       Format = 'unsigned' },
    [0x14bb] = { Name = 'CropTop',          Format = 'unsigned' },
    [0x14cc] = { Name = 'CropLeft',         Format = 'unsigned' },
    [0x14dd] = { Name = 'CropRight',        Format = 'unsigned' },
    [0x14b0] = { Name = 'DisplayWidth',     Format = 'unsigned' },
    [0x14ba] = { Name = 'DisplayHeight',    Format = 'unsigned' },
    [0x14b2] = {
        Name = 'DisplayUnit',
        Format = 'unsigned',
        PrintConv = {
            [0] = 'Pixels',
            [1] = 'cm',
            [2] = 'inches',
            [3] = 'Display Aspect Ratio',
            [4] = 'Unknown',
        },
    },
    [0x14b3] = {
        Name = 'AspectRatioType',
        Format = 'unsigned',
        PrintConv = {
            [0] = 'Free Resizing',
            [1] = 'Keep Aspect Ratio',
            [2] = 'Fixed',
        },
    },
    [0xeb524] = { Name = 'ColorSpace',      Binary = 1, Unknown = 1 },
    [0xfb523] = { Name = 'Gamma',           Format = 'float' },
    [0x383e3] = { Name = 'FrameRate',       Format = 'float' },
--
-- Audio
--
    [0x61] = {
        Name = 'Audio',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x35]  = { Name = 'AudioSampleRate',   Format = 'float',     Groups = { [2] = 'Audio' } },
    [0x38b5] = { Name = 'OutputAudioSampleRate',Format = 'float', Groups = { [2] = 'Audio' } },
    [0x1f]  = { Name = 'AudioChannels',     Format = 'unsigned',  Groups = { [2] = 'Audio' } },
    [0x3d7b] = {
        Name = 'ChannelPositions',
        Binary = 1,
        Unknown = 1,
        Groups = { [2] = 'Audio' },
    },
    [0x2264] = { Name = 'AudioBitsPerSample',   Format = 'unsigned', Groups = { [2] = 'Audio' } },
--
-- Content Encoding
--
    [0x2d80] = {
        Name = 'ContentEncodings',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x2240] = {
        Name = 'ContentEncoding',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x1031] = { Name = 'ContentEncodingOrder', Format = 'unsigned', Unknown = 1 },
    [0x1032] = { Name = 'ContentEncodingScope', Format = 'unsigned', Unknown = 1 },
    [0x1033] = {
        Name = 'ContentEncodingType',
        Format = 'unsigned',
        PrintConv = { [0] = 'Compression', [1] = 'Encryption' },
    },
    [0x1034] = {
        Name = 'ContentCompression',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x254] = {
        Name = 'ContentCompressionAlgorithm',
        Format = 'unsigned',
        PrintConv = {
            [0] = 'zlib',
            [1] = 'bzlib',
            [2] = 'lzo1x',
            [3] = 'Header Stripping',
        },
    },
    [0x255] = { Name = 'ContentCompressionSettings',Binary = 1, Unknown = 1 },
    [0x1035] = {
        Name = 'ContentEncryption',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x7e1] = {
        Name = 'ContentEncryptionAlgorithm',
        Format = 'unsigned',
        PrintConv = {
            [0] = 'Not Encrypted',
            [1] = 'DES',
            [2] = '3DES',
            [3] = 'Twofish',
            [4] = 'Blowfish',
            [5] = 'AES',
        },
    },
    [0x7e2] = { Name = 'ContentEncryptionKeyID',Binary = 1, Unknown = 1 },
    [0x7e3] = { Name = 'ContentSignature',      Binary = 1, Unknown = 1 },
    [0x7e4] = { Name = 'ContentSignatureKeyID', Binary = 1, Unknown = 1 },
    [0x7e5] = {
        Name = 'ContentSignatureAlgorithm',
        Format = 'unsigned',
        PrintConv = { [0] = 'Not Signed', [1] = 'RSA' },
    },
    [0x7e6] = {
        Name = 'ContentSignatureHashAlgorithm',
        Format = 'unsigned',
        PrintConv = {
            [0] = 'Not Signed',
            [1] = 'SHA1-160',
            [2] = 'MD5',
        },
    },
--
-- Cues
--
    [0x0c53bb6b] = {
        Name = 'Cues',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x3b] = {
        Name = 'CuePoint',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x33] = {
        Name = 'CueTime',
        Format = 'unsigned',
        Unknown = 1,
        ValueConv = function(self, val)
            return self.TimecodeScale and val * self.TimecodeScale / 1e9 or val
        end,
        PrintConv = function(self, val)
            return self.TimecodeScale and ExifTool.ConvertDuration(val) or val
        end,
    },
    [0x37] = {
        Name = 'CueTrackPositions',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x77]  = { Name = 'CueTrack',          Format = 'unsigned', Unknown = 1 },
    [0x71]  = { Name = 'CueClusterPosition',Format = 'unsigned', Unknown = 1 },
    [0x1378] = { Name = 'CueBlockNumber',   Format = 'unsigned', Unknown = 1 },
    [0x6a]  = { Name = 'CueCodecState',     Format = 'unsigned', Unknown = 1 },
    [0x5b] = {
        Name = 'CueReference',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x16] = {
        Name = 'CueRefTime',
        Format = 'unsigned',
        Unknown = 1,
        ValueConv = function(self, val)
            return self.TimecodeScale and val * self.TimecodeScale / 1e9 or val
        end,
        PrintConv = function(self, val)
            return self.TimecodeScale and ExifTool.ConvertDuration(val) or val
        end,
    },
    [0x17]  = { Name = 'CueRefCluster',     Format = 'unsigned', Unknown = 1 },
    [0x135f]= { Name = 'CueRefNumber',      Format = 'unsigned', Unknown = 1 },
    [0x6b]  = { Name = 'CueRefCodecState',  Format = 'unsigned', Unknown = 1 },
--
-- Attachments
--
    [0x0941a469] = {
        Name = 'Attachments',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x21a7] = {
        Name = 'AttachedFile',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x67e] = { Name = 'AttachedFileDescription',Format = 'utf8' },
    [0x66e] = { Name = 'AttachedFileName',      Format = 'utf8' },
    [0x660] = { Name = 'AttachedFileMIMEType',  Format = 'string' },
    [0x65c] = { Name = 'AttachedFileData',      Binary = 1 },
    [0x6ae] = uidTag('AttachedFileUID'),
    [0x675] = { Name = 'AttachedFileReferral',  Binary = 1, Unknown = 1 },
--
-- Chapters
--
    [0x043a770] = {
        Name = 'Chapters',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x5b9] = {
        Name = 'EditionEntry',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x5bc] = uidTag('EditionUID', { Unknown = 1 }),
    [0x5bd] = { Name = 'EditionFlagHidden', Format = 'unsigned', Unknown = 1 },
    [0x5db] = { Name = 'EditionFlagDefault',Format = 'unsigned', Unknown = 1 },
    [0x5dd] = { Name = 'EditionFlagOrdered',Format = 'unsigned', Unknown = 1 },
    [0x36] = {
        Name = 'ChapterAtom',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x33c4] = uidTag('ChapterUID', { Unknown = 1 }),
    [0x11] = {
        Name = 'ChapterTimeStart',
        Groups = { [1] = 'Chapter#' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return val / 1e9 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [0x12] = {
        Name = 'ChapterTimeEnd',
        Format = 'unsigned',
        ValueConv = function(_self, val) return val / 1e9 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [0x18]  = { Name = 'ChapterFlagHidden', Format = 'unsigned', Unknown = 1 },
    [0x598] = { Name = 'ChapterFlagEnabled',Format = 'unsigned', Unknown = 1 },
    [0x2e67]= uidTag('ChapterSegmentUID', { Unknown = 1 }),
    [0x2ebc]= uidTag('ChapterSegmentEditionUID', { Unknown = 1 }),
    [0x23c3] = {
        Name = 'ChapterPhysicalEquivalent',
        Format = 'unsigned',
        PrintConv = {
            [10] = 'Index',
            [20] = 'Track',
            [30] = 'Session',
            [40] = 'Layer',
            [50] = 'Side',
            [60] = 'CD / DVD',
            [70] = 'Set / Package',
        },
    },
    [0x0f] = {
        Name = 'ChapterTrack',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x09] = { Name = 'ChapterTrackNumber', Format = 'unsigned', Unknown = 1 },
    [0x00] = {
        Name = 'ChapterDisplay',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x05]  = { Name = 'ChapterString',     Format = 'utf8' },
    [0x37c] = { Name = 'ChapterLanguage',   Format = 'string' },
    [0x37e] = { Name = 'ChapterCountry',    Format = 'string' },
    [0x2944] = {
        Name = 'ChapterProcess',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x2955] = {
        Name = 'ChapterProcessCodecID',
        Format = 'unsigned',
        Unknown = 1,
        PrintConv = { [0] = 'Matroska', [1] = 'DVD' },
    },
    [0x50d] = { Name = 'ChapterProcessPrivate', Binary = 1, Unknown = 1 },
    [0x2911] = {
        Name = 'ChapterProcessCommand',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x2922] = {
        Name = 'ChapterProcessTime',
        Format = 'unsigned',
        Unknown = 1,
        PrintConv = {
            [0] = 'For Duration of Chapter',
            [1] = 'Before Chapter',
            [2] = 'After Chapter',
        },
    },
    [0x2933] = { Name = 'ChapterProcessData',   Binary = 1, Unknown = 1 },
--
-- Tags
--
    [0x0254c367] = {
        Name = 'Tags',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x3373] = {
        Name = 'Tag',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
    [0x23c0] = {
        Name = 'Targets',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
        -- Targets elements
        [0x28ca] = {
            Name = 'TargetTypeValue',
            Format = 'unsigned',
            PrintConv = {
                [10] = 'Shot',
                [20] = 'Scene/Subtrack',
                [30] = 'Chapter/Track',
                [40] = 'Session',
                [50] = 'Movie/Album',
                [60] = 'Season/Edition',
                [70] = 'Collection',
            },
        },
        [0x23ca] = { Name = 'TargetType',       Format = 'string' },
        [0x23c5] = uidTag('TagTrackUID'),
        [0x23c9] = uidTag('TagEditionUID'),
        [0x23c4] = uidTag('TagChapterUID'),
        [0x23c6] = uidTag('TagAttachmentUID'),
    [0x27c8] = {
        Name = 'SimpleTag',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Main' },
    },
        -- SimpleTag elements
        [0x5a3] = { Name = 'TagName',           Format = 'utf8' },
        -- (upstream lists key 0x47a twice -- TagLanguage then
        --  TagLanguageBCP47, the latter winning in both languages; the port
        --  keeps only the effective entry)
        [0x47a] = { Name = 'TagLanguageBCP47',  Format = 'string' },
        [0x484] = { Name = 'TagDefault',        Format = 'unsigned', PrintConv = noYes },
        [0x487] = { Name = 'TagString',         Format = 'utf8' },
        [0x485] = { Name = 'TagBinary',         Binary = 1 },
--
-- Spherical Video V2 (untested)
--
    [0x7670] = {
        Name = 'Projection',
        SubDirectory = { TagTable = 'lexiftool.Matroska.Projection' },
    },
--
-- other
--
    [0x5345414c] = { -- ('SEAL' in hex)
        Name = 'SEAL',
        NotEBML = 1,    -- don't process SubDirectory as EBML elements
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    },
}

-- Spherical video v2 projection tags (ref https://github.com/google/spatial-media/blob/master/docs/spherical-video-v2-rfc.md)
Matroska.Projection = {
    GROUPS = { [2] = 'Video' },
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        Projection tags defined by the Spherical Video V2 specification.  See
        L<https://github.com/google/spatial-media/blob/master/docs/spherical-video-v2-rfc.md>
        for the specification.
    ]],
    [0x7671] = {
        Name = 'ProjectionType',
        Format = 'unsigned',
        DataMember = 'ProjectionType',
        RawConv = function(self, val) self.ProjectionType = val return val end,
        PrintConv = {
            [0] = 'Rectangular',
            [1] = 'Equirectangular',
            [2] = 'Cubemap',
            [3] = 'Mesh',
        },
    },
    -- ProjectionPrivate in the spec
    [0x7672] = {
        {
            Name = 'EquirectangularProj',
            Condition = function(self) return self.ProjectionType == 1 end,
            SubDirectory = { TagTable = 'lexiftool.QuickTime.equi' },
        },{
            Name = 'CubemapProj',
            Condition = function(self) return self.ProjectionType == 2 end,
            SubDirectory = { TagTable = 'lexiftool.QuickTime.cbmp' },
        },{ -- (don't decode 3 because it is a PITA)
            Name = 'ProjectionPrivate',
            Binary = 1,
        },
    },
    [0x7673] = { Name = 'ProjectionPoseYaw',   Format = 'float' },
    [0x7674] = { Name = 'ProjectionPosePitch', Format = 'float' },
    [0x7675] = { Name = 'ProjectionPoseRoll',  Format = 'float' },
}

-- standardized tag names (ref 2)
Matroska.StdTag = {
    GROUPS = { [2] = 'Video' },
    PRIORITY = 0, -- (don't want named tags to override numbered tags, eg. "DURATION")
    VARS = { LONG_TAGS = 3 },
    NOTES = [[
        Standardized Matroska tags, stored in a SimpleTag structure (see
        L<https://www.matroska.org/technical/tagging.html>).
    ]],
    ORIGINAL    = 'Original',   -- struct
    SAMPLE      = 'Sample',     -- struct
    COUNTRY     = 'Country',    -- struct (should deal with this properly!)
    TOTAL_PARTS = 'TotalParts',
    PART_NUMBER = 'PartNumber',
    PART_OFFSET = 'PartOffset',
    TITLE       = 'Title',
    SUBTITLE    = 'Subtitle',
    URL         = 'URL',        -- nested
    SORT_WITH   = 'SortWith',   -- nested
    INSTRUMENTS = {             -- nested
        Name = 'Instruments',
        IsList = 1,
        ValueConv = function(_self, val) local a = split([[,\s?]], val) return a end,
    },
    EMAIL       = 'Email',      -- nested
    ADDRESS     = 'Address',    -- nested
    FAX         = 'FAX',        -- nested
    PHONE       = 'Phone',      -- nested
    ARTIST      = 'Artist',
    LEAD_PERFORMER = 'LeadPerformer',
    ACCOMPANIMENT = 'Accompaniment',
    COMPOSER    = 'Composer',
    ARRANGER    = 'Arranger',
    LYRICS      = 'Lyrics',
    LYRICIST    = 'Lyricist',
    CONDUCTOR   = 'Conductor',
    DIRECTOR    = 'Director',
    ASSISTANT_DIRECTOR      = 'AssistantDirector',
    DIRECTOR_OF_PHOTOGRAPHY = 'DirectorOfPhotography',
    SOUND_ENGINEER          = 'SoundEngineer',
    ART_DIRECTOR            = 'ArtDirector',
    PRODUCTION_DESIGNER     = 'ProductionDesigner',
    CHOREGRAPHER            = 'Choregrapher',
    COSTUME_DESIGNER        = 'CostumeDesigner',
    ACTOR       = 'Actor',
    CHARACTER   = 'Character',
    WRITTEN_BY  = 'WrittenBy',
    SCREENPLAY_BY = 'ScreenplayBy',
    EDITED_BY   = 'EditedBy',
    PRODUCER    = 'Producer',
    COPRODUCER  = 'Coproducer',
    EXECUTIVE_PRODUCER  = 'ExecutiveProducer',
    DISTRIBUTED_BY      = 'DistributedBy',
    MASTERED_BY         = 'MasteredBy',
    ENCODED_BY  = 'EncodedBy',
    MIXED_BY    = 'MixedBy',
    REMIXED_BY  = 'RemixedBy',
    PRODUCTION_STUDIO = 'ProductionStudio',
    THANKS_TO   = 'ThanksTo',
    PUBLISHER   = 'Publisher',
    LABEL       = 'Label',
    GENRE       = 'Genre',
    MOOD        = 'Mood',
    ORIGINAL_MEDIA_TYPE = 'OriginalMediaType',
    CONTENT_TYPE = 'ContentType',
    SUBJECT     = 'Subject',
    DESCRIPTION = 'Description',
    KEYWORDS    = {
        Name = 'Keywords',
        IsList = 1,
        ValueConv = function(_self, val) local a = split([[,\s?]], val) return a end,
    },
    SUMMARY     = 'Summary',
    SYNOPSIS    = 'Synopsis',
    INITIAL_KEY = 'InitialKey',
    PERIOD      = 'Period',
    LAW_RATING  = 'LawRating',
    DATE_RELEASED   = dateInfo('DateReleased'),
    DATE_RECORDED   = dateInfo('DateTimeOriginal', { Description = 'Date/Time Original' }),
    DATE_ENCODED    = dateInfo('DateEncoded'),
    DATE_TAGGED     = dateInfo('DateTagged'),
    DATE_DIGITIZED  = dateInfo('CreateDate'),
    DATE_WRITTEN    = dateInfo('DateWritten'),
    DATE_PURCHASED  = dateInfo('DatePurchased'),
    RECORDING_LOCATION   = 'RecordingLocation',
    COMPOSITION_LOCATION = 'CompositionLocation',
    COMPOSER_NATIONALITY = 'ComposerNationality',
    COMMENT     = 'Comment',
    PLAY_COUNTER = 'PlayCounter',
    RATING      = 'Rating',
    ENCODER     = 'Encoder',
    ENCODER_SETTINGS = 'EncoderSettings',
    BPS         = 'BPS',
    FPS         = 'FPS',
    BPM         = 'BPM',
    MEASURE     = 'Measure',
    TUNING      = 'Tuning',
    REPLAYGAIN_GAIN = 'ReplaygainGain',
    REPLAYGAIN_PEAK = 'ReplaygainPeak',
    ISRC        = 'ISRC',
    MCDI        = 'MCDI',
    ISBN        = 'ISBN',
    BARCODE     = 'Barcode',
    CATALOG_NUMBER = 'CatalogNumber',
    LABEL_CODE  = 'LabelCode',
    LCCN        = 'Lccn',
    IMDB        = 'IMDB',
    TMDB        = 'TMDB',
    TVDB        = 'TVDB',
    PURCHASE_ITEM   = 'PurchaseItem',
    PURCHASE_INFO   = 'PurchaseInfo',
    PURCHASE_OWNER  = 'PurchaseOwner',
    PURCHASE_PRICE  = 'PurchasePrice',
    PURCHASE_CURRENCY = 'PurchaseCurrency',
    COPYRIGHT   = 'Copyright',
    PRODUCTION_COPYRIGHT = 'ProductionCopyright',
    LICENSE     = 'License',
    TERMS_OF_USE = 'TermsOfUse',
    -- (the following are untested)
    ['spherical-video'] = { --https://github.com/google/spatial-media/blob/master/docs/spherical-video-rfc.md
        Name = 'SphericalVideoXML',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
            ProcessProc = function(...) return require('lexiftool.XMP').ProcessGSpherical(...) end,
        },
    },
    ['SPHERICAL-VIDEO'] = { --https://github.com/google/spatial-media/blob/master/docs/spherical-video-rfc.md
        Name = 'SphericalVideoXML',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
            ProcessProc = function(...) return require('lexiftool.XMP').ProcessGSpherical(...) end,
        },
    },
--
-- other tags seen
--
    _STATISTICS_WRITING_DATE_UTC = dateInfo('StatisticsWritingDateUTC'),
    _STATISTICS_WRITING_APP = 'StatisticsWritingApp',
    _STATISTICS_TAGS = 'StatisticsTags',
    DURATION = 'Duration',
    NUMBER_OF_FRAMES = 'NumberOfFrames',
    NUMBER_OF_BYTES = 'NumberOfBytes',
}

--------------------------------------------------------------------------------
-- Handle MKV SimpleTag structure
-- Inputs: 0) ExifTool ref, 1) structure ref, 2) parent tag ID, 3) parent tag Name,
--         4) language code, 5) country code
--------------------------------------------------------------------------------
local function HandleStruct(et, struct, pid, pname, lang, ctry)
    local tagTbl = et:GetTagTable('lexiftool.Matroska.StdTag')
    local tag = struct.TagName
    local tagInfo = tag and tagTbl[tag] or nil
    -- create tag if necessary
    if type(tagInfo) ~= 'table' then
        local name = tag and lc(tag) or ''
        name = ucfirst(name)
        name = name:gsub('[^0-9a-zA-Z_]', '')
        name = name:gsub('_([a-z])', function(c) return uc(c) end)
        if #name < 2 then name = 'Tag_' .. name end
        et:VPrint(0, '  [adding ' .. str(tag) .. ' = ' .. name .. ']\n')
        tagInfo = { Name = name }
        tagTbl[tag] = tagInfo
    end
    local id, nm
    if pid then
        id = pid .. '/' .. tag
        nm = pname .. '/' .. tagInfo.Name
        if not tagTbl[id] then
            local copy = {}
            for k, v in pairs(tagInfo) do copy[k] = v end
            copy.Name = nm
            et:VPrint(0, '  [adding ' .. id .. ' = ' .. nm .. ']\n')
            tagInfo = copy
            tagTbl[id] = tagInfo
        else
            tagInfo = tagTbl[id]
        end
    else
        id, nm = tag, tagInfo.Name
    end
    if struct.TagString ~= nil or struct.TagBinary ~= nil then
        local val = struct.TagString ~= nil and struct.TagString or { ref = 'SCALAR', value = struct.TagBinary }
        lang = struct.TagLanguageBCP47 or struct.TagLanguage or lang
        -- (Note: not currently handling TagDefault attribute)
        local code
        if ctry then
            code = (lang and (lang .. '-' .. ctry)) or ('eng-' .. ctry) -- ('eng' is default lang)
        end
        if code then
            tagInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, code)
            et:HandleTag(tagTbl, tagInfo.TagID, val)
        else
            et:HandleTag(tagTbl, id, val)
        end
        -- COUNTRY is handled as an attribute for contained tags
        if tag == 'COUNTRY' then
            ctry = val
            id, nm = pid, pname
        end
    end
    if struct.struct then
        -- step into each contained structure
        for _, sub in ipairs(struct.struct) do
            HandleStruct(et, sub, id, nm, lang, ctry)
        end
    end
end

--------------------------------------------------------------------------------
-- Get variable-length Matroska integer
-- Inputs: 0) data buffer, 1) position in data
-- Returns: integer value and updates position, -1 for unknown/reserved value,
--          or undef if no data left
-- Notes: Increments position pointer
--------------------------------------------------------------------------------
local function GetVInt(buff, posRef)
    if posRef.pos >= #buff then return nil end
    local val = buff:byte(posRef.pos + 1)
    posRef.pos = posRef.pos + 1
    local num = 0
    if val == 0 or val == nil then
        if posRef.pos >= #buff then return nil end
        val = buff:byte(posRef.pos + 1)
        posRef.pos = posRef.pos + 1
        if not val or val == 0 then return nil end -- can't be this large!
        num = num + 7 -- 7 more bytes to read (we just read one)
    end
    local mask = 0x7f
    while val == (val & mask) do
        mask = mask >> 1
        num = num + 1
    end
    val = val & mask
    local unknown = (val == mask)
    if posRef.pos + num > #buff then return nil end
    while num > 0 do
        local b = buff:byte(posRef.pos + 1)
        posRef.pos = posRef.pos + 1
        if b ~= 0xff then unknown = false end
        val = val * 256 + b
        num = num - 1
    end
    return unknown and -1 or val
end

--------------------------------------------------------------------------------
-- Read information from a Matroska multimedia file (MKV, MKA, MKS)
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid Matroska file
--------------------------------------------------------------------------------
function Matroska.ProcessMKV(et, dirInfo)
    local raf = dirInfo.RAF
    local dirEnd = {}
    local trackIndent
    local trackTypes = {}
    local trackNum = {}
    local struct
    local seekInfo = {}
    local seek = {}

    local n, buff = raf:Read(4)
    if n ~= 4 then return 0 end
    if buff ~= '\x1a\x45\xdf\xa3' then return 0 end

    -- read in 64kB blocks (already read 4 bytes); note $buff is replaced,
    -- so it holds the file from offset 4 onward ($dataPos accounts for it)
    local n2, rest = raf:Read(65532)
    if not n2 or n2 == 0 then return 0 end
    buff = rest
    local dataLen = #buff
    local pos = 0
    local dataPos = 4
    local posRef = { pos = pos }

    -- verify header length
    local hlen = GetVInt(buff, posRef)
    if not hlen or hlen <= 0 then return 0 end
    pos = posRef.pos
    if pos + hlen > dataLen then et:Warn('Truncated Matroska header') return 1 end
    et:SetFileType()
    ExifTool.SetByteOrder('MM')
    local tagTablePtr = et:GetTagTable('lexiftool.Matroska.Main')

    -- set flag to process entire file (otherwise we stop at the first Cluster)
    local verbose = et:Options('Verbose')
    local processAll = (perlTruthy(verbose) or (et:Options('Unknown') or 0) > 1) and 2 or 0
    if et:Options('ExtractEmbedded') then processAll = processAll + 1 end
    et.TrackTypes = trackTypes -- store Track types reference
    et.SeekHeadOffset = 0
    local oldIndent = et.INDENT
    local chapterNum = 0
    local dirName = 'MKV' -- luacheck: ignore 311

    -- loop over all Matroska elements
    while true do
        -- (shared per-element state, declared up front so 'goto continue'
        --  never jumps into a local's scope)
        local tag, size, unknownSize, seekInfoOnly, tagName, tagInfo, val
        local advancePos = false -- true only on the normal element path
        local parms
        while #dirEnd > 0 do
            if pos + dataPos >= dirEnd[#dirEnd][1] then
                if dirEnd[#dirEnd][2] == 'Seek' then
                    -- save seek info
                    if seekInfo.ID and seekInfo.Position then
                        local seekTag = tagTablePtr[seekInfo.ID]
                        if type(seekTag) == 'table' and seekTag.Name then
                            seek[seekTag.Name] = seekInfo.Position + (et.SeekHeadOffset or 0)
                        end
                    end
                    seekInfo = {}
                end
                table.remove(dirEnd)
                if struct then
                    if #dirEnd > 0 and dirEnd[#dirEnd][3] then
                        -- save this nested structure
                        dirEnd[#dirEnd][3].struct = dirEnd[#dirEnd][3].struct or {}
                        table.insert(dirEnd[#dirEnd][3].struct, struct)
                        struct = dirEnd[#dirEnd][3]
                    else
                        -- handle completed structures now
                        HandleStruct(et, struct)
                        struct = nil
                    end
                end
                dirName = #dirEnd > 0 and dirEnd[#dirEnd][2] or 'MKV' -- luacheck: ignore 311
                -- use INDENT to decide whether or not we are done this Track element
                if trackIndent and trackIndent == et.INDENT then et.SET_GROUP1 = nil end
                et.INDENT = substr(et.INDENT, 0, -2)
                table.remove(et.PATH)
            else
                dirName = dirEnd[#dirEnd][2] -- luacheck: ignore 311
                break
            end
        end
        -- read more if we are getting close to the end of our buffer
        -- (24 more bytes should be enough to read this element header)
        if pos + 24 > dataLen and select(1, raf:Read(65536)) then
            local buf2 = select(2, raf:Read(65536))
            buff = buff:sub(pos + 1) .. buf2
            dataPos = dataPos + pos
            dataLen = #buff
            pos = 0
        end
        posRef.pos = pos
        tag = GetVInt(buff, posRef)
        pos = posRef.pos
        if not tag or tag < 0 then break end
        if tag == 0x14d9b74 then et.SeekHeadOffset = pos end -- save offset of seek head
        size = GetVInt(buff, posRef)
        pos = posRef.pos
        if not size then break end
        if size < 0 then unknownSize = true; size = 1e20 end
        if #dirEnd > 0 and pos + dataPos + size > dirEnd[#dirEnd][1] then
            et:Warn('Invalid or corrupted ' .. dirEnd[#dirEnd][2] .. ' master element')
            pos = dirEnd[#dirEnd][1] - dataPos
            if pos < 0 or pos > dataLen then
                buff = ''
                dataPos = dataPos + pos
                dataLen = 0
                pos = 0
                if not raf:Seek(dataPos, 0) then break end
            end
            goto continue
        end
        tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not tagInfo and type(tagTablePtr[tag]) == 'table' and tagTablePtr[tag].SeekInfo then
            tagInfo = tagTablePtr[tag]
            seekInfoOnly = true
        end
        if tagInfo then
            tagName = tagInfo.Name
            if tagInfo.SubDirectory and not tagInfo.NotEBML then
                -- stop processing at first cluster unless we are using -v -U or -ee
                -- or there are Tags after this
                if tagName == 'Cluster' and processAll < 2 then
                    -- jump to Tags if possible
                    if not processAll then
                        if seek.Tags and seek.Tags > pos + dataPos and raf:Seek(seek.Tags, 0) then
                            buff = ''
                            dataPos = seek.Tags
                            pos = 0
                            dataLen = 0
                            goto continue
                        end
                        break
                    end
                    tagInfo = nil -- just skip the Cluster when -ee is used
                else
                    -- just fall through into the contained EBML elements
                    et.INDENT = (et.INDENT or '') .. '| '
                    dirName = tagName
                    et:VerboseDir(dirName, nil, size)
                    table.insert(et.PATH, dirName)
                    table.insert(dirEnd, { pos + dataPos + size, dirName, struct })
                    if dirName == 'SimpleTag' then struct = {} end -- keep track of SimpleTag elements
                    -- set Chapter# and Info family 1 group names
                    if tagName == 'ChapterAtom' then
                        chapterNum = chapterNum + 1
                        et.SET_GROUP1 = 'Chapter' .. chapterNum
                        trackIndent = et.INDENT
                    elseif tagName == 'Info' and not et.SET_GROUP1 then
                        et.SET_GROUP1 = 'Info'
                        trackIndent = et.INDENT
                    end
                    goto continue
                end
            end
        elseif perlTruthy(verbose) then
            et:VPrint(0, sprintf('%s- Tag 0x%x (Unknown, %d bytes)\n', et.INDENT or '', tag, size))
        end
        if unknownSize then break end
        if pos + size > dataLen then
            -- how much more do we need to read?
            local more = pos + size - dataLen
            -- just skip unknown and large data blocks
            if not tagInfo or more > 10000000 then
                -- don't try to skip very large blocks unless LargeFileSupport is enabled
                if more >= 0x80000000 then
                    if not et:Options('LargeFileSupport') then break end
                    if et:Options('LargeFileSupport') == '2' or et:Options('LargeFileSupport') == 2 then
                        et:Warn('Processing large block (LargeFileSupport is 2)')
                    end
                end
                if not raf:Seek(more, 1) then break end
                buff = ''
                dataPos = dataPos + dataLen + more
                dataLen = 0
                pos = 0
                goto continue
            else
                -- read data in multiples of 64kB
                more = (math.floor(more / 65536) + 1) * 65536
                local nr, buf2 = raf:Read(more)
                if nr and nr > 0 then
                    buff = buff:sub(pos + 1) .. buf2
                    dataPos = dataPos + pos
                    dataLen = #buff
                    pos = 0
                end
                if pos + size > dataLen then break end
            end
        end
        if not tagInfo then
            -- ignore the element
            pos = pos + size
            goto continue
        end
        advancePos = true
        if tagInfo.Format then
            local fmt = tagInfo.Format
            if fmt == 'string' or fmt == 'utf8' then
                val = substr(buff, pos, size):gsub('\0.*', '', 1)
                if fmt == 'utf8' then val = et:Decode(val, 'UTF8') end
            elseif fmt == 'float' then
                if size == 4 then
                    val = ExifTool.GetFloat(buff, pos)
                elseif size == 8 then
                    val = ExifTool.GetDouble(buff, pos)
                else
                    et:Warn('Illegal float size (' .. size .. ')')
                end
            else
                val = 0
                local over = 1
                for i = 1, size do
                    local b = buff:byte(pos + i) or 0
                    val = val * 256 + b
                    over = over * 256
                end
                -- interpret negative numbers
                if (buff:byte(pos + 1) or 0) & 0x80 ~= 0 then val = val - over end
                -- convert dates (nanoseconds since 2001:01:01)
                if fmt == 'date' then
                    local t = val / 1e9
                    -- (8 leap days between 1970 and 2001)
                    t = t + (((2001-1970)*365+8)*24*3600)
                    val = ExifTool.ConvertUnixTime(t, nil, -9) .. 'Z'
                end
            end
            if tagName == 'TrackNumber' then
                -- set Track# family 1 group name for tags directly in the track
                et.SET_GROUP1 = 'Track' .. val
                trackIndent = et.INDENT
            elseif tagName == 'TrackUID' and et.SET_GROUP1 then
                -- save the Track# group associated with this TrackUID
                trackNum[val] = et.SET_GROUP1
            elseif tagName == 'TagTrackUID' and trackNum[val] then
                -- set Track# group for associated SimpleTags tags
                et.SET_GROUP1 = trackNum[val]
                -- we're already one deeper than the level where we want to
                -- reset the group name, so trigger at one indent level higher
                trackIndent = substr(et.INDENT or '', 0, -2)
            end
        end
        parms = {
            DataPt  = buff,
            DataPos = dataPos,
            Start   = pos,
            Size    = size,
        }
        if tagInfo.NoSave or struct then
            if perlTruthy(verbose) then et:VerboseInfo(tag, tagInfo, val, parms) end
            if struct then struct[tagName] = val end
        elseif tagInfo.SeekInfo then
            local p = { pos = pos }
            if not val then val = GetVInt(buff, p) end
            seekInfo[tagInfo.SeekInfo] = val
            if not seekInfoOnly then
                et:HandleTag(tagTablePtr, tag, val, parms)
            end
        else
            et:HandleTag(tagTablePtr, tag, val, parms)
        end
        ::continue::
        if advancePos then pos = pos + size end -- step to next element
    end
    et.INDENT = oldIndent
    et.SET_GROUP1 = nil
    -- override file type if necessary based on existing track types
    if not trackTypes[0x01] and not trackTypes[0x03] then -- video or complex?
        if trackTypes[0x02] then                          -- audio?
            et:OverrideFileType('MKA')
        elseif trackTypes[0x11] then                      -- subtitle?
            et:OverrideFileType('MKS')
        end
    end
    return 1
end

return Matroska
