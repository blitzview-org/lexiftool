--------------------------------------------------------------------------------
-- File:         lexiftool/ASF.lua
-- Ported from:  lib/Image/ExifTool/ASF.pm
--
-- Description:  Read ASF/WMA/WMV meta information
--
-- Revisions:    12/23/2005 - P. Harvey Created
--
-- References:   1) http://www.microsoft.com/windows/windowsmedia/format/asfspec.aspx
--               2) http://www.adobe.com/devnet/xmp/pdfs/XMPSpecificationPart3.pdf (Oct 2008)
--
-- Port notes:   read subset: ProcessASF (the GUID-keyed object walker) and
--               the Main/Header/HeaderExtension/ContentDescr/
--               ContentBranding/ExtendedDescr/Picture/FileProperties/
--               StreamProperties/CodecList tables (upstream ASF.pm has no
--               write path), including ProcessASF's verbose output and its
--               LargeFileSupport handling of objects over 2 GB.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local RIFF = require('lexiftool.RIFF')
local perl = require('lexiftool.perl')
local substr = perl.substr
local perlStr = perl.str
local uc = perl.uc
local isMatch = perl.isMatch
local subst = perl.subst
local pack, unpack = perl.pack, perl.unpack
local perlTruthy = perl.truthy
local push = perl.push
local join = perl.join
local GetTagTable = ExifTool.GetTagTable
local ReadValue = ExifTool.ReadValue
local Get16u, Get32u = ExifTool.Get16u, ExifTool.Get32u
local shift = perl.shift
local matches = perl.matches
local length = perl.length

local ASF = {}

-- GUID definitions
local errorCorrection = {
    ['20FB5700-5B55-11CF-A8FD-00805F5C442B'] = 'No Error Correction',
    ['BFC3CD50-618F-11CF-8BB2-00AA00B4E220'] = 'Audio Spread',
}

local streamType = {
    ['F8699E40-5B4D-11CF-A8FD-00805F5C442B'] = 'Audio',
    ['BC19EFC0-5B4D-11CF-A8FD-00805F5C442B'] = 'Video',
    ['59DACFC0-59E6-11D0-A3AC-00A0C90348F6'] = 'Command',
    ['B61BE100-5B4E-11CF-A8FD-00805F5C442B'] = 'JFIF',
    ['35907DE0-E415-11CF-A917-00805F5C442B'] = 'Degradable JPEG',
    ['91BD222C-F21C-497A-8B6D-5AA86BFC0185'] = 'File Transfer',
    ['3AFB65E2-47EF-40F2-AC2C-70A90D71D343'] = 'Binary',
}

--------------------------------------------------------------------------------
-- Generate GUID from 16 bytes of binary data
-- Inputs: 0) data
-- Returns: GUID
function ASF.GetGUID(val)
    -- must do some byte swapping
    if perl.length(val) ~= 16 then return val end
    local buff = unpack('H*',pack('NnnNN',unpack('VvvNN',val)))
    buff = subst(buff, '(.{8})(.{4})(.{4})(.{4})', '$1-$2-$3-$4-')
    return uc(buff)
end

-- ASF top level objects
ASF.Main = {
    PROCESS_PROC = false, -- set below (forward reference)
    NOTES = [[
        The ASF format is used by Windows WMA and WMV files, and DIVX videos.  Tag
        ID's aren't listed because they are huge 128-bit GUID's that would ruin the
        formatting of this table.
    ]],
    ['75B22630-668E-11CF-A6D9-00AA0062CE6C'] = {
        Name = 'Header',
        SubDirectory = { TagTable = 'lexiftool.ASF.Header', Size = 6 },
    },
    ['75B22636-668E-11CF-A6D9-00AA0062CE6C'] = 'Data',
    ['33000890-E5B1-11CF-89F4-00A0C90349CB'] = 'SimpleIndex',
    ['D6E229D3-35DA-11D1-9034-00A0C90349BE'] = 'Index',
    ['FEB103F8-12AD-4C64-840F-2A1D2F7AD48C'] = 'MediaIndex',
    ['3CB73FD0-0C4A-4803-953D-EDF7B6228F0C'] = 'TimecodeIndex',
    ['BE7ACFCB-97A9-42E8-9C71-999491E3AFAC'] = { --#2
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

-- ASF header objects
ASF.Header = {
    PROCESS_PROC = false, -- set below (forward reference)
    ['8CABDCA1-A947-11CF-8EE4-00C00C205365'] = {
        Name = 'FileProperties',
        SubDirectory = { TagTable = 'lexiftool.ASF.FileProperties' },
    },
    ['B7DC0791-A9B7-11CF-8EE6-00C00C205365'] = {
        Name = 'StreamProperties',
        SubDirectory = { TagTable = 'lexiftool.ASF.StreamProperties' },
    },
    ['5FBF03B5-A92E-11CF-8EE3-00C00C205365'] = {
        Name = 'HeaderExtension',
        SubDirectory = { TagTable = 'lexiftool.ASF.HeaderExtension', Size = 22 },
    },
    ['86D15240-311D-11D0-A3A4-00A0C90348F6'] = {
        Name = 'CodecList',
        SubDirectory = { TagTable = 'lexiftool.ASF.CodecList' },
    },
    ['1EFB1A30-0B62-11D0-A39B-00A0C90348F6'] = 'ScriptCommand',
    ['F487CD01-A951-11CF-8EE6-00C00C205365'] = 'Marker',
    ['D6E229DC-35DA-11D1-9034-00A0C90349BE'] = 'BitrateMutualExclusion',
    ['75B22635-668E-11CF-A6D9-00AA0062CE6C'] = 'ErrorCorrection',
    ['75B22633-668E-11CF-A6D9-00AA0062CE6C'] = {
        Name = 'ContentDescription',
        SubDirectory = { TagTable = 'lexiftool.ASF.ContentDescr' },
    },
    ['2211B3FA-BD23-11D2-B4B7-00A0C955FC6E'] = {
        Name = 'ContentBranding',
        SubDirectory = { TagTable = 'lexiftool.ASF.ContentBranding' },
    },
    ['D2D0A440-E307-11D2-97F0-00A0C95EA850'] = {
        Name = 'ExtendedContentDescr',
        SubDirectory = { TagTable = 'lexiftool.ASF.ExtendedDescr' },
    },
    ['7BF875CE-468D-11D1-8D82-006097C9A2B2'] = 'StreamBitrateProps',
    ['2211B3FB-BD23-11D2-B4B7-00A0C955FC6E'] = 'ContentEncryption',
    ['298AE614-2622-4C17-B935-DAE07EE9289C'] = 'ExtendedContentEncryption',
    ['2211B3FC-BD23-11D2-B4B7-00A0C955FC6E'] = 'DigitalSignature',
    ['1806D474-CADF-4509-A4BA-9AABCB96AAE8'] = 'Padding',
}

ASF.ContentDescr = {
    PROCESS_PROC = false, -- set below (forward reference)
    GROUPS = { [2] = 'Video' },
    [0] = 'Title',
    [1] = { Name = 'Author', Groups = { [2] = 'Author' } },
    [2] = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    [3] = 'Description',
    [4] = 'Rating',
}

ASF.ContentBranding = {
    PROCESS_PROC = false, -- set below (forward reference)
    GROUPS = { [2] = 'Author' },
    [0] = {
        Name = 'BannerImageType',
        PrintConv = {
            [0] = 'None',
            [1] = 'Bitmap',
            [2] = 'JPEG',
            [3] = 'GIF',
        },
    },
    [1] = { Name = 'BannerImage', Groups = { [2] = 'Preview' }, Binary = 1 },
    [2] = 'BannerImageURL',
    [3] = 'CopyrightURL',
}

-- Note: Many of these tags are similar to those in Image::ExifTool::Microsoft::Xtra
--       and Image::ExifTool::WTV::Metadata
-- (tags in this table may have a leading "WM/" removed)
ASF.ExtendedDescr = {
    PROCESS_PROC = false, -- set below (forward reference)
    GROUPS = { [2] = 'Video' },
    ASFLeakyBucketPairs = { Binary = 1 },
    AspectRatioX = {},
    AspectRatioY = {},
    Author = { Groups = { [2] = 'Author' } },
    AverageLevel = {},
    BannerImageData = {},
    BannerImageType = {},
    BannerImageURL = {},
    Bitrate = { PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    Broadcast = {},
    BufferAverage = {},
    Can_Skip_Backward = {},
    Can_Skip_Forward = {},
    Copyright = { Groups = { [2] = 'Author' } },
    CopyrightURL = { Groups = { [2] = 'Author' } },
    CurrentBitrate = { PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    Description = {},
    DRM_ContentID = {},
    DRM_DRMHeader_ContentDistributor = {},
    DRM_DRMHeader_ContentID = {},
    DRM_DRMHeader_IndividualizedVersion = {},
    DRM_DRMHeader_KeyID = {},
    DRM_DRMHeader_LicenseAcqURL = {},
    DRM_DRMHeader_SubscriptionContentID = {},
    DRM_DRMHeader = {},
    DRM_IndividualizedVersion = {},
    DRM_KeyID = {},
    DRM_LASignatureCert = {},
    DRM_LASignatureLicSrvCert = {},
    DRM_LASignaturePrivKey = {},
    DRM_LASignatureRootCert = {},
    DRM_LicenseAcqURL = {},
    DRM_V1LicenseAcqURL = {},
    Duration = { PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end },
    FileSize = {},
    HasArbitraryDataStream = {},
    HasAttachedImages = {},
    HasAudio = {},
    HasFileTransferStream = {},
    HasImage = {},
    HasScript = {},
    HasVideo = {},
    Is_Protected = {},
    Is_Trusted = {},
    IsVBR = {},
    NSC_Address = {},
    NSC_Description = {},
    NSC_Email = {},
    NSC_Name = {},
    NSC_Phone = {},
    NumberOfFrames = {},
    OptimalBitrate = { PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    PeakValue = {},
    Rating = {},
    Seekable = {},
    Signature_Name = {},
    Stridable = {},
    Title = {},
    VBRPeak = {},
    -- "WM/" tags...
    AlbumArtist = {},
    AlbumCoverURL = {},
    AlbumTitle = {},
    ASFPacketCount = {},
    ASFSecurityObjectsSize = {},
    AudioFileURL = {},
    AudioSourceURL = {},
    AuthorURL = { Groups = { [2] = 'Author' } },
    BeatsPerMinute = {},
    Category = {},
    Codec = {},
    Composer = {},
    Conductor = {},
    ContainerFormat = {},
    ContentDistributor = {},
    ContentGroupDescription = {},
    Director = {},
    DRM = {},
    DVDID = {},
    EncodedBy = {},
    EncodingSettings = {},
    EncodingTime = {
        Groups = { [2] = 'Time' },
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Genre = {},
    GenreID = {},
    InitialKey = {},
    ISRC = {},
    Language = {},
    Lyrics = {},
    Lyrics_Synchronised = {},
    MCDI = {},
    MediaClassPrimaryID = { ValueConv = function(_self, val) return ASF.GetGUID(val) end },
    MediaClassSecondaryID = { ValueConv = function(_self, val) return ASF.GetGUID(val) end },
    MediaCredits = {},
    MediaIsDelay = {},
    MediaIsFinale = {},
    MediaIsLive = {},
    MediaIsPremiere = {},
    MediaIsRepeat = {},
    MediaIsSAP = {},
    MediaIsStereo = {},
    MediaIsSubtitled = {},
    MediaIsTape = {},
    MediaNetworkAffiliation = {},
    MediaOriginalBroadcastDateTime = {
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return (val:gsub('[-T]', ' ')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    MediaOriginalChannel = {},
    MediaStationCallSign = {},
    MediaStationName = {},
    ModifiedBy = {},
    Mood = {},
    OriginalAlbumTitle = {},
    OriginalArtist = {},
    OriginalFilename = 'OriginalFileName',
    OriginalLyricist = {},
    OriginalReleaseTime = {
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return (val:gsub('[-T]', ' ')) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    OriginalReleaseYear = { Groups = { [2] = 'Time' } },
    ParentalRating = {},
    ParentalRatingReason = {},
    PartOfSet = {},
    PeakBitrate = { PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
    Period = {},
    Picture = {
        SubDirectory = { TagTable = 'lexiftool.ASF.Picture' },
    },
    PlaylistDelay = {},
    Producer = {},
    PromotionURL = {},
    ProtectionType = {},
    Provider = {},
    ProviderCopyright = {},
    ProviderRating = {},
    ProviderStyle = {},
    Publisher = {},
    RadioStationName = {},
    RadioStationOwner = {},
    SharedUserRating = {},
    StreamTypeInfo = {},
    SubscriptionContentID = {},
    SubTitle = 'Subtitle',
    SubTitleDescription = 'SubtitleDescription',
    Text = {},
    ToolName = {},
    ToolVersion = {},
    Track = {},
    TrackNumber = {},
    UniqueFileIdentifier = {},
    UserWebURL = {},
    VideoClosedCaptioning = {},
    VideoFrameRate = {},
    VideoHeight = {},
    VideoWidth = {},
    WMADRCAverageReference = {},
    WMADRCAverageTarget = {},
    WMADRCPeakReference = {},
    WMADRCPeakTarget = {},
    WMCollectionGroupID = {},
    WMCollectionID = {},
    WMContentID = {},
    Writer = { Groups = { [2] = 'Author' } },
    Year = { Groups = { [2] = 'Time' } },
}

ASF.Picture = {
    PROCESS_PROC = false, -- set below (forward reference)
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'PictureType',
        PrintConv = { -- (Note: Duplicated in ID3, ASF and FLAC modules!)
            [0] = 'Other',
            [1] = '32x32 PNG Icon',
            [2] = 'Other Icon',
            [3] = 'Front Cover',
            [4] = 'Back Cover',
            [5] = 'Leaflet',
            [6] = 'Media',
            [7] = 'Lead Artist',
            [8] = 'Artist',
            [9] = 'Conductor',
            [10] = 'Band',
            [11] = 'Composer',
            [12] = 'Lyricist',
            [13] = 'Recording Studio or Location',
            [14] = 'Recording Session',
            [15] = 'Performance',
            [16] = 'Capture from Movie or Video',
            [17] = 'Bright(ly) Colored Fish',
            [18] = 'Illustration',
            [19] = 'Band Logo',
            [20] = 'Publisher Logo',
        },
    },
    [1] = 'PictureMIMEType',
    [2] = 'PictureDescription',
    [3] = {
        Name = 'Picture',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
}

ASF.FileProperties = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    [0] = {
        Name = 'FileID',
        Format = 'binary[16]',
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
    },
    [16] = { Name = 'FileLength', Format = 'int64u' },
    [24] = {
        Name = 'CreationDate',
        Format = 'int64u',
        Groups = { [2] = 'Time' },
        -- time is in 100 ns intervals since 0:00 UTC Jan 1, 1601
        -- (89 leap years between 1601 and 1970)
        ValueConv = function(_self, val)
            local t = val / 1e7 - (((1970 - 1601) * 365 + 89) * 24 * 3600)
            return ExifTool.ConvertUnixTime(t) .. 'Z'
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [32] = { Name = 'DataPackets', Format = 'int64u' },
    [40] = {
        Name = 'Duration',
        Format = 'int64u',
        Notes = 'called PlayDuration by the ASF spec',
        Priority = 0,
        ValueConv = function(_self, val) return val / 1e7 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [48] = {
        Name = 'SendDuration',
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e7 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    [56] = { Name = 'Preroll', Format = 'int64u' },
    [64] = { Name = 'Flags', Format = 'int32u' },
    [68] = { Name = 'MinPacketSize', Format = 'int32u' },
    [72] = { Name = 'MaxPacketSize', Format = 'int32u' },
    [76] = { Name = 'MaxBitrate', Format = 'int32u', PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end },
}

ASF.StreamProperties = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    NOTES = 'Tags with index 54 and greater are conditional based on the StreamType.',
    [0] = {
        Name = 'StreamType',
        Format = 'binary[16]',
        -- set ASF_STREAM_TYPE for use in conditional tags
        RawConv = function(self, val)
            self.ASF_STREAM_TYPE = streamType[ASF.GetGUID(val)] or ''
            return val
        end,
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
        PrintConv = streamType,
    },
    [16] = {
        Name = 'ErrorCorrectionType',
        Format = 'binary[16]',
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
        PrintConv = errorCorrection,
    },
    [32] = {
        Name = 'TimeOffset',
        Format = 'int64u',
        ValueConv = function(_self, val) return val / 1e7 end,
        PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' s' end,
    },
    [48] = {
        Name = 'StreamNumber',
        Format = 'int16u',
        PrintConv = function(_self, val)
            return (val & 0x7f) .. (val & 0x8000 ~= 0 and ' (encrypted)' or '')
        end,
    },
    [54] = {
        {
            Condition = function(self) return self.ASF_STREAM_TYPE == 'Audio' end,
            Name = 'AudioCodecID',
            Format = 'int16u',
            PrintHex = 1,
            SeparateTable = 'RIFF AudioEncoding',
            PrintConv = RIFF.audioEncoding,
        },
        {
            Condition = function(self)
                return self.ASF_STREAM_TYPE == 'Video' or self.ASF_STREAM_TYPE == 'JFIF' or
                    self.ASF_STREAM_TYPE == 'Degradable JPEG'
            end,
            Name = 'ImageWidth',
            Format = 'int32u',
        },
    },
    [56] = {
        Condition = function(self) return self.ASF_STREAM_TYPE == 'Audio' end,
        Name = 'AudioChannels',
        Format = 'int16u',
    },
    [58] = {
        {
            Condition = function(self) return self.ASF_STREAM_TYPE == 'Audio' end,
            Name = 'AudioSampleRate',
            Format = 'int32u',
        },
        {
            Condition = function(self)
                return self.ASF_STREAM_TYPE == 'Video' or self.ASF_STREAM_TYPE == 'JFIF' or
                    self.ASF_STREAM_TYPE == 'Degradable JPEG'
            end,
            Name = 'ImageHeight',
            Format = 'int32u',
        },
    },
}

ASF.HeaderExtension = {
    PROCESS_PROC = false, -- set below (forward reference)
    ['14E6A5CB-C672-4332-8399-A96952065B5A'] = 'ExtendedStreamProps',
    ['A08649CF-4775-4670-8A16-6E35357566CD'] = 'AdvancedMutualExcl',
    ['D1465A40-5A79-4338-B71B-E36B8FD6C249'] = 'GroupMutualExclusion',
    ['D4FED15B-88D3-454F-81F0-ED5C45999E24'] = 'StreamPrioritization',
    ['A69609E6-517B-11D2-B6AF-00C04FD908E9'] = 'BandwidthSharing',
    ['7C4346A9-EFE0-4BFC-B229-393EDE415C85'] = 'LanguageList',
    ['C5F8CBEA-5BAF-4877-8467-AA8C44FA4CCA'] = {
        Name = 'Metadata',
        SubDirectory = {
            -- have seen some tags same as ExtendedDescr, so use this table - PH
            TagTable = 'lexiftool.ASF.ExtendedDescr',
            ProcessProc = false, -- set below (forward reference)
        },
    },
    ['44231C94-9498-49D1-A141-1D134E457054'] = {
        Name = 'MetadataLibrary',
        SubDirectory = {
            -- have seen some tags same as ExtendedDescr, so use this table - PH
            TagTable = 'lexiftool.ASF.ExtendedDescr',
            ProcessProc = false, -- set below (forward reference)
        },
    },
    ['D6E229DF-35DA-11D1-9034-00A0C90349BE'] = 'IndexParameters',
    ['6B203BAD-3F11-48E4-ACA8-D7613DE2CFA7'] = 'TimecodeIndexParms',
    ['75B22630-668E-11CF-A6D9-00AA0062CE6C'] = 'Compatibility',
    ['43058533-6981-49E6-9B74-AD12CB86D58C'] = 'AdvancedContentEncryption',
    ['ABD3D211-A9BA-11cf-8EE6-00C00C205365'] = 'Reserved1',
}

ASF.CodecList = {
    PROCESS_PROC = false, -- set below (forward reference)
    VideoCodecName = {},
    VideoCodecDescription = {},
    AudioCodecName = {},
    AudioCodecDescription = {},
    OtherCodecName = {},
    OtherCodecDescription = {},
}

--------------------------------------------------------------------------------
-- Process ASF content description
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function ASF.ProcessContentDescription(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    if dirLen < 10 then return 0 end
    local len_a = { unpack('v5', dataPt) }
    local pos = 10
    for tag = 0, 4 do
        local len = shift(len_a)
        if perlTruthy(len) then
            if pos + len > dirLen then return 0 end
            local val = et:Decode(substr(dataPt,pos,len),'UTF16','II')
            et:HandleTag(tagTablePtr, tag, val)
            pos = pos + len
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process ASF content branding
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function ASF.ProcessContentBranding(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    if dirLen < 40 then return 0 end
    -- decode banner image type
    et:HandleTag(tagTablePtr, 0, (unpack('V', dataPt)))
    -- decode banner image, banner URL and copyright URL
    local pos = 4
    for tag = 1, 3 do
        if pos + 4 > dirLen then return 0 end
        local size = unpack('x' .. pos .. 'V', dataPt)
        pos = pos + 4
        if perlTruthy(size) then
            if pos + size > dirLen then return 0 end
            local val = substr(dataPt, pos, size)
            et:HandleTag(tagTablePtr, tag, val)
            pos = pos + size
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Read ASF value
-- Inputs: 0) ExifTool object ref, 1) data reference, 2) value offset,
--         3) format number, 4) size
-- Returns: converted value
local function ReadASF(et, dataPt, pos, format, size)
    local vals = {}
    if format == 0 then -- unicode string
        vals[1] = et:Decode(substr(dataPt,pos,size),'UTF16','II')
    elseif format == 2 then -- 4-byte boolean
        vals = ReadValue(dataPt, pos, 'int32u', nil, size, nil, true)
        for i = 1, #vals do
            vals[i] = perlTruthy(vals[i]) and 'True' or 'False'
        end
    elseif format == 3 then -- int32u
        vals = ReadValue(dataPt, pos, 'int32u', nil, size, nil, true)
    elseif format == 4 then -- int64u
        vals = ReadValue(dataPt, pos, 'int64u', nil, size, nil, true)
    elseif format == 5 then -- int16u
        vals = ReadValue(dataPt, pos, 'int16u', nil, size, nil, true)
    else -- any other format (including 1, byte array): return raw data
        vals[1] = substr(dataPt,pos,size)
    end
    return join(' ', vals)
end

--------------------------------------------------------------------------------
-- Process extended content description
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function ASF.ProcessExtendedContentDescription(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    if dirLen < 2 then return 0 end
    local count = Get16u(dataPt, 0)
    et:VerboseDir(dirInfo, count)
    local pos = 2
    local i = 0
    while i < count do
        if pos + 6 > dirLen then return 0 end
        local nameLen = unpack('x' .. pos .. 'v', dataPt)
        pos = pos + 2
        if pos + nameLen + 4 > dirLen then return 0 end
        local tag = ExifTool.Decode(nil,substr(dataPt,pos,nameLen),'UTF16','II','Latin')
        tag = subst(tag, [[^WM\/]], '') -- remove leading "WM/"
        pos = pos + nameLen
        local dType, dLen = unpack('x' .. pos .. 'v2', dataPt)
        pos = pos + 4
        if pos + dLen > dirLen then return 0 end
        local val = ReadASF(et,dataPt,pos,dType,dLen)
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            Start  = pos,
            Size   = dLen,
        })
        pos = pos + dLen
        i = i + 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process ASF metadata library (similar to ProcessExtendedContentDescription above)
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function ASF.ProcessMetadata(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    if dirLen < 2 then return 0 end
    local count = Get16u(dataPt, 0)
    et:VerboseDir(dirInfo, count)
    local pos = 2
    local i = 0
    while i < count do
        if pos + 12 > dirLen then return 0 end
        local index, stream, nameLen, dType, dLen = unpack('x' .. pos .. 'v4V', dataPt) -- luacheck: ignore 211
        pos = pos + 12
        if pos + nameLen + dLen > dirLen then return 0 end
        local tag = ExifTool.Decode(nil,substr(dataPt,pos,nameLen),'UTF16','II','Latin')
        tag = subst(tag, [[^WM\/]], '') -- remove leading "WM/"
        pos = pos + nameLen
        local val = ReadASF(et,dataPt,pos,dType,dLen)
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            Start  = pos,
            Size   = dLen,
        })
        pos = pos + dLen
        i = i + 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process WM/Picture preview
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function ASF.ProcessPicture(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    if dirLen <= 9 then return 0 end
    -- extract picture type and length
    local type_, picLen = unpack('x' .. perlStr(dirStart) .. 'CV', dataPt)
    et:VerboseDir('Picture')
    et:HandleTag(tagTablePtr, 0, type_)
    -- extract mime type and description strings (null-terminated unicode strings)
    local n = dirLen - 5 - picLen
    if n & 0x01 ~= 0 or n < 4 then return 0 end
    local str = substr(dataPt, dirStart+5, n)
    local mime, desc = matches(str, [[(?s)^((?:..)*?)\0\0((?:..)*?)\0\0]])
    if mime ~= nil then
        et:HandleTag(tagTablePtr, 1, et:Decode(mime,'UTF16','II'))
        if length(desc) > 0 then et:HandleTag(tagTablePtr, 2, et:Decode(desc,'UTF16','II')) end
    end
    et:HandleTag(tagTablePtr, 3, substr(dataPt, dirStart+5+n, picLen))
    return 1
end

--------------------------------------------------------------------------------
-- Process codec list
-- Inputs: 0) ExifTool object reference, 1) dirInfo ref, 2) tag table reference
-- Returns: 1 on success
--------------------------------------------------------------------------------
function ASF.ProcessCodecList(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    if dirLen < 20 then return 0 end
    local count = Get32u(dataPt, 16)
    et:VerboseDir(dirInfo, count)
    local pos = 20
    local i = 0
    local codecType = { [1] = 'Video', [2] = 'Audio' }
    while i < count do
        if pos + 8 > dirLen then return 0 end
        local type_ = (codecType[Get16u(dataPt, pos)] or 'Other') .. 'Codec'
        -- stupid Windows programmers: these lengths are in characters (others are in bytes)
        local nameLen = Get16u(dataPt, pos + 2) * 2
        pos = pos + 4
        if pos + nameLen + 2 > dirLen then return 0 end
        local name = et:Decode(substr(dataPt,pos,nameLen),'UTF16','II')
        et:HandleTag(tagTablePtr, type_ .. 'Name', name)
        local descLen = Get16u(dataPt, pos + nameLen) * 2
        pos = pos + nameLen + 2
        if pos + descLen + 2 > dirLen then return 0 end
        local desc = et:Decode(substr(dataPt,pos,descLen),'UTF16','II')
        et:HandleTag(tagTablePtr, type_ .. 'Description', desc)
        local infoLen = Get16u(dataPt, pos + descLen)
        pos = pos + descLen + 2 + infoLen
        i = i + 1
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a ASF file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success, 0 if this wasn't a valid ASF file
--------------------------------------------------------------------------------
function ASF.ProcessASF(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local rtnVal = 0
    local pos = 0
    local buff, err, n
    local parentTable, childEnd = {}, {}

    while true do
        n, buff = raf:Read(24)
        if n ~= 24 then break end
        pos = pos + 24
        local tag = ASF.GetGUID(substr(buff,0,16))
        if not tagTablePtr then
            -- verify this is a valid ASF file
            if tag ~= '75B22630-668E-11CF-A6D9-00AA0062CE6C' then break end
            local fileType = et.FILE_EXT
            if not (perlTruthy(fileType) and isMatch(fileType, [[^(ASF|WMV|WMA|DIVX)$]])) then fileType = 'ASF' end
            et:SetFileType(fileType)
            ExifTool.SetByteOrder('II')
            tagTablePtr = GetTagTable(nil, 'lexiftool.ASF.Main')
            rtnVal = 1
        end
        local size = ExifTool.Get64u(buff, 16) - 24
        if size < 0 then
            err = 'Invalid ASF object size'
            break
        end
        if size > 0x7fffffff then
            if size > 0x7fffffff * 4294967296 then
                err = 'Invalid ASF object size'
            elseif perlTruthy(et:Options('LargeFileSupport')) then
                if perlStr(et:Options('LargeFileSupport')) == '2' then
                    et:Warn('Skipping large ASF object (LargeFileSupport is 2)')
                end
                if raf:Seek(size, 1) then
                    et:VPrint(0, "  Skipped large ASF object (" .. perlStr(size) .. " bytes)\n")
                    pos = pos + size
                    goto next
                end
                err = 'Error seeking past large ASF object'
            else
                err = 'Large ASF objects not supported (LargeFileSupport not set)'
            end
            break
        end
        -- go back to parent tag table if done with previous children
        if #childEnd > 0 and pos >= childEnd[#childEnd] then
            table.remove(childEnd)
            tagTablePtr = table.remove(parentTable)
            et.INDENT = substr(et.INDENT,0,-2)
        end
        do
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if perlTruthy(verbose) then et:VerboseInfo(tag, tagInfo) end
            if tagInfo then
                local subdir = tagInfo.SubDirectory
                if subdir then
                    local subTable = GetTagTable(nil, subdir.TagTable)
                    if subTable.PROCESS_PROC == ASF.ProcessASF then
                        if subdir.Size ~= nil then
                            local s = subdir.Size
                            if perl.num(verbose) > 2 then
                                n, buff = raf:Read(s)
                                if n ~= s then err = 'Truncated file'; break end
                                et:VerboseDump(buff)
                            elseif not raf:Seek(s, 1) then
                                err = 'Seek error'
                                break
                            end
                            -- continue processing linearly using subTable
                            push(parentTable, tagTablePtr)
                            push(childEnd, pos + size)
                            tagTablePtr = subTable
                            pos = pos + subdir.Size
                            if perlTruthy(verbose) then
                                et.INDENT = et.INDENT .. '| '
                                et:VerboseDir(tagInfo.Name)
                            end
                            goto next
                        end
                    else
                        n, buff = raf:Read(size)
                        if n == size then
                            local subdirInfo = {
                                DataPt = buff,
                                DirStart = 0,
                                DirLen = size,
                                DirName = tagInfo.Name,
                            }
                            if perl.num(verbose) > 2 then et:VerboseDump(buff) end
                            if not perlTruthy(et:ProcessDirectory(subdirInfo, subTable, subdir.ProcessProc)) then
                                et:Warn("Error processing " .. perlStr(tagInfo.Name) .. " directory")
                            end
                            pos = pos + size
                            goto next
                        else
                            err = 'Unexpected end of file'
                            break
                        end
                    end
                end
            end
        end
        if perl.num(verbose) > 2 then
            n, buff = raf:Read(size)
            if n ~= size then err = 'Truncated file'; break end
            et:VerboseDump(buff)
        elseif not raf:Seek(size, 1) then -- skip the block
            err = 'Seek error'
            break
        end
        pos = pos + size
        ::next::
    end
    if err then et:Warn(err) end
    return rtnVal
end

-- (PROCESS_PROC fields are set here so the tables can reference the
-- functions defined above)
ASF.Main.PROCESS_PROC = ASF.ProcessASF
ASF.Header.PROCESS_PROC = ASF.ProcessASF
ASF.HeaderExtension.PROCESS_PROC = ASF.ProcessASF
ASF.HeaderExtension['C5F8CBEA-5BAF-4877-8467-AA8C44FA4CCA'].SubDirectory.ProcessProc = ASF.ProcessMetadata
ASF.HeaderExtension['44231C94-9498-49D1-A141-1D134E457054'].SubDirectory.ProcessProc = ASF.ProcessMetadata
ASF.ContentDescr.PROCESS_PROC = ASF.ProcessContentDescription
ASF.ContentBranding.PROCESS_PROC = ASF.ProcessContentBranding
ASF.ExtendedDescr.PROCESS_PROC = ASF.ProcessExtendedContentDescription
ASF.Picture.PROCESS_PROC = ASF.ProcessPicture
ASF.CodecList.PROCESS_PROC = ASF.ProcessCodecList

return ASF
