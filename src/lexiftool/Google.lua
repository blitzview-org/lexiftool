--------------------------------------------------------------------------------
-- File:         lexiftool/Google.lua
-- Ported from:  lib/Image/ExifTool/Google.pm
--
-- Description:  Google maker notes and XMP tags
--
-- Revisions:    2025-09-17 - P. Harvey Created
--
-- References:   1) https://github.com/jakiki6/ruminant/blob/master/ruminant/modules/images.py
--
-- Port notes:   the eight XMP namespace tables XMP::Main points at are
--               carried complete, each at its upstream position: GAudio,
--               GImage, GPano, GSpherical, GDepth, GFocus, GCreations and
--               Device, together with the %sPose/%sEarthPose/%sVendorInfo/
--               %sAppInfo structures they share and Device's own nested
--               Container/Profiles/Cameras/Planes struct trees (struct fields
--               reach the read path through XMP.AddFlattenedTags).  They
--               spread %Image::ExifTool::XMP::xmpTableDefaults, applied here
--               as XMP.xmpTableDefaults { ... }, so their WRITE_PROC is set
--               when the table is built and needs no late assignment; GDepth
--               does not spread it upstream and so has none here either.
--               The DecodeBase64 ValueConvs carry the scalar-reference
--               wrapper that makes the data print as "(Binary data N bytes)",
--               and %Image::ExifTool::XMP::dateTimeInfo is spread the way
--               XMP.lua spreads it (explicit Writable/Shift/PrintConv).
--               All tag tables (GCamera, HDRPlusMakerNote, ShotLogData,
--               HDRPMakerNote, PortraitReq) and both subs (ProcessHDRPMakerNote
--               for the ver-2 text format, ProcessHDRP: base64 -> HDRP header
--               check -> xorshift64*-style key stream decrypt -> gunzip ->
--               protobuf or text) are ported in upstream order.  The upstream
--               32-bit hi/lo arithmetic in ProcessHDRP's key rotation is
--               ported using Lua 5.4 native 64-bit integer bitwise ops
--               (identical results, see inline notes).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local XMP = require('lexiftool.XMP')
local substr = require('lexiftool.perl').substr
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local sprintf = perl.sprintf
local GetTagTable = ExifTool.GetTagTable

local Google = {}

local sPose = {
    STRUCT_NAME = 'Google Pose',
    NAMESPACE = { Pose = 'http://ns.google.com/photos/dd/1.0/pose/' },
    PositionX = { Writable = 'real', Groups = { [2] = 'Location' } },
    PositionY = { Writable = 'real', Groups = { [2] = 'Location' } },
    PositionZ = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationX = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationY = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationZ = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationW = { Writable = 'real', Groups = { [2] = 'Location' } },
    Timestamp = {
        Name = 'TimeStamp',
        Writable = 'integer',
        Shift = 'Time',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val / 1000, 1, 3) end,
        ValueConvInv = function(_self, val) return perl.int(ExifTool.GetUnixTime(val, 1) * 1000) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val, nil, 1) end,
    },
}
local sEarthPose = {
    STRUCT_NAME = 'Google EarthPose',
    NAMESPACE = { EarthPose = 'http://ns.google.com/photos/dd/1.0/earthpose/' },
    Latitude  = {
        Writable = 'real',
        Groups = { [2] = 'Location' },
        ValueConv    = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1) end,
        ValueConvInv = function(_self, val) return val end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
        PrintConvInv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1, 'lat') end,
    },
    Longitude = {
        Writable = 'real',
        Groups = { [2] = 'Location' },
        ValueConv    = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1) end,
        ValueConvInv = function(_self, val) return val end,
        PrintConv    = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
        PrintConvInv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1, 'lon') end,
    },
    Altitude  = {
        Writable = 'real',
        Groups = { [2] = 'Location' },
        PrintConv = function(_self, val) return perl.str(val) .. ' m' end,
        PrintConvInv = function(_self, val) return (perl.subst(val, [[\s*m$]], '')) end,
    },
    RotationX = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationY = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationZ = { Writable = 'real', Groups = { [2] = 'Location' } },
    RotationW = { Writable = 'real', Groups = { [2] = 'Location' } },
    Timestamp = {
        Name = 'TimeStamp',
        Writable = 'integer',
        Shift = 'Time',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val / 1000, 1, 3) end,
        ValueConvInv = function(_self, val) return perl.int(ExifTool.GetUnixTime(val, 1) * 1000) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val, nil, 1) end,
    },
}
local sVendorInfo = {
    STRUCT_NAME = 'Google VendorInfo',
    NAMESPACE   = { VendorInfo = 'http://ns.google.com/photos/dd/1.0/vendorinfo/' },
    Model = { },
    Manufacturer = { },
    Notes = { },
}
local sAppInfo = {
    STRUCT_NAME = 'Google AppInfo',
    NAMESPACE   = { AppInfo = 'http://ns.google.com/photos/dd/1.0/appinfo/' },
    Application = { },
    Version = { },
    ItemURI = { },
}

-- Google audio namespace
Google.GAudio = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GAudio', [2] = 'Audio' },
    NAMESPACE = 'GAudio',
    Data = {
        Name = 'AudioData',
        -- (upstream DecodeBase64 returns \$dat -- the scalar ref is what makes
        --  this print as "(Binary data ...)", so it is carried here)
        ValueConv = function(_self, val) return { ref = 'SCALAR', value = XMP.DecodeBase64(val) } end,
        ValueConvInv = function(_self, val) return XMP.EncodeBase64(val) end,
    },
    Mime = { Name = 'AudioMimeType' },
}

-- Google image namespace
Google.GImage = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GImage', [2] = 'Image' },
    NAMESPACE = 'GImage',
    Data = {
        Name = 'ImageData',
        ValueConv = function(_self, val) return { ref = 'SCALAR', value = XMP.DecodeBase64(val) } end,
        ValueConvInv = function(_self, val) return XMP.EncodeBase64(val) end,
    },
    Mime = { Name = 'ImageMimeType' },
}

-- Google panorama namespace properties
-- (ref https://exiftool.org/forum/index.php/topic,4569.0.html)
Google.GPano = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GPano', [2] = 'Image' },
    NAMESPACE = 'GPano',
    NOTES = [[
        Panorama tags written by Google Photosphere. See
        L<https://developers.google.com/streetview/spherical-metadata> for the
        specification.
    ]],
    UsePanoramaViewer               = { Writable = 'boolean' },
    CaptureSoftware                 = { },
    StitchingSoftware               = { },
    ProjectionType                  = { },
    PoseHeadingDegrees              = { Writable = 'real' },
    PosePitchDegrees                = { Writable = 'real' },
    PoseRollDegrees                 = { Writable = 'real' },
    InitialViewHeadingDegrees       = { Writable = 'real' },
    InitialViewPitchDegrees         = { Writable = 'real' },
    InitialViewRollDegrees          = { Writable = 'real' },
    InitialHorizontalFOVDegrees     = { Writable = 'real' },
    InitialVerticalFOVDegrees       = { Writable = 'real' },
    FirstPhotoDate                  = { Writable = 'date', Shift = 'Time', Validate = XMP.dateTimeInfo.Validate, PrintConv = XMP.dateTimeInfo.PrintConv,
                                        PrintConvInv = XMP.dateTimeInfo.PrintConvInv, Groups = { [2] = 'Time' } },
    LastPhotoDate                   = { Writable = 'date', Shift = 'Time', Validate = XMP.dateTimeInfo.Validate, PrintConv = XMP.dateTimeInfo.PrintConv,
                                        PrintConvInv = XMP.dateTimeInfo.PrintConvInv, Groups = { [2] = 'Time' } },
    SourcePhotosCount               = { Writable = 'integer' },
    ExposureLockUsed                = { Writable = 'boolean' },
    CroppedAreaImageWidthPixels     = { Writable = 'real' },
    CroppedAreaImageHeightPixels    = { Writable = 'real' },
    FullPanoWidthPixels             = { Writable = 'real' },
    FullPanoHeightPixels            = { Writable = 'real' },
    CroppedAreaLeftPixels           = { Writable = 'real' },
    CroppedAreaTopPixels            = { Writable = 'real' },
    InitialCameraDolly              = { Writable = 'real' },
    -- (the following have been observed, but are not in the specification)
    LargestValidInteriorRectLeft    = { Writable = 'real' },
    LargestValidInteriorRectTop     = { Writable = 'real' },
    LargestValidInteriorRectWidth   = { Writable = 'real' },
    LargestValidInteriorRectHeight  = { Writable = 'real' },
}

-- Google Spherical Images namespace (ref https://github.com/google/spatial-media/blob/master/docs/spherical-video-rfc.md)
Google.GSpherical = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GSpherical', [2] = 'Image' },
    WRITE_GROUP = 'GSpherical', -- write in special location for video files
    NAMESPACE = 'GSpherical',
    AVOID = 1,
    NOTES = [[
        Not actually XMP.  These RDF/XML tags are used in Google spherical MP4
        videos.  These tags are written into the video track of MOV/MP4 files, and
        not at the top level like other XMP tags.  See
        L<https://github.com/google/spatial-media/blob/master/docs/spherical-video-rfc.md>
        for the specification.
    ]],
    -- (avoid due to conflicts with XMP-GPano tags)
    Spherical                   = { Writable = 'boolean' },
    Stitched                    = { Writable = 'boolean' },
    StitchingSoftware           = { },
    ProjectionType              = { },
    StereoMode                  = { },
    SourceCount                 = { Writable = 'integer' },
    InitialViewHeadingDegrees   = { Writable = 'real' },
    InitialViewPitchDegrees     = { Writable = 'real' },
    InitialViewRollDegrees      = { Writable = 'real' },
    Timestamp                   = {
        Name = 'TimeStamp',
        Groups = { [2] = 'Time' },
        Writable = 'integer',
        Shift = 'Time',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end, -- (NC)
        ValueConvInv = function(_self, val) return ExifTool.GetUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    FullPanoWidthPixels         = { Writable = 'integer' },
    FullPanoHeightPixels        = { Writable = 'integer' },
    CroppedAreaImageWidthPixels = { Writable = 'integer' },
    CroppedAreaImageHeightPixels= { Writable = 'integer' },
    CroppedAreaLeftPixels       = { Writable = 'integer' },
    CroppedAreaTopPixels        = { Writable = 'integer' },
}

-- Google depthmap information (ref https://developers.google.com/depthmap-metadata/reference)
Google.GDepth = {
    GROUPS      = { [0] = 'XMP', [1] = 'XMP-GDepth', [2] = 'Image' },
    NAMESPACE   = 'GDepth',
    AVOID       = 1, -- (too many potential tag name conflicts)
    NOTES       = [[
        Google depthmap information. See
        L<https://developers.google.com/depthmap-metadata/> for the specification.
    ]],
    WRITABLE    = 'string', -- (default to string-type tags)
    PRIORITY    = 0,
    Format = {
        PrintConv = {
            RangeInverse = 'RangeInverse',
            RangeLinear  = 'RangeLinear',
        },
    },
    Near        = { Writable = 'real' },
    Far         = { Writable = 'real' },
    Mime        = { },
    Data = {
        Name = 'DepthImage',
        ValueConv = function(_self, val) return { ref = 'SCALAR', value = XMP.DecodeBase64(val) } end,
        ValueConvInv = function(_self, val) return XMP.EncodeBase64(val) end,
    },
    Units       = { },
    MeasureType = {
        PrintConv = {
            OpticalAxis = 'OpticalAxis',
            OpticalRay  = 'OpticalRay',
        },
    },
    ConfidenceMime  = { },
    Confidence = {
        ValueConv = function(_self, val) return { ref = 'SCALAR', value = XMP.DecodeBase64(val) } end,
        ValueConvInv = function(_self, val) return XMP.EncodeBase64(val) end,
    },
    Manufacturer= { },
    Model       = { },
    Software    = { },
    ImageWidth  = { Writable = 'real' },
    ImageHeight = { Writable = 'real' },
}

-- Google focus namespace
Google.GFocus = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GFocus', [2] = 'Image' },
    NAMESPACE = 'GFocus',
    NOTES = 'Focus information found in Google depthmap images.',
    BlurAtInfinity  = { Writable = 'real' },
    FocalDistance   = { Writable = 'real' },
    FocalPointX     = { Writable = 'real' },
    FocalPointY     = { Writable = 'real' },
}

-- Google camera namespace (ref PH)
Google.GCamera = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GCamera', [2] = 'Camera' },
    NAMESPACE = 'GCamera',
    NOTES = 'Camera information found in Google panorama images.',
    BurstID         = { },
    BurstPrimary    = { },
    -- luacheck: push ignore 314
    PortraitNote    = { },
    PortraitRequest = {
        Writable = 'string', -- (writable in encoded format)
        Binary = 1,
        SubDirectory = { TagTable = 'lexiftool.Google.HDRPMakerNote' },
    },
    PortraitVersion = { },
    SpecialTypeID   = { List = 'Bag' },
    PortraitNote    = { },
    -- luacheck: pop
    DisableAutoCreation = { List = 'Bag' },
    DisableSuggestedAction = { List = 'Bag' }, -- #forum16147
    hdrp_makernote = {
        Name = 'HDRPMakerNote',
        Writable = 'string', -- (writable in encoded format)
        Binary = 1,
        SubDirectory = { TagTable = 'lexiftool.Google.HDRPMakerNote' },
    },
    MicroVideo          = { Writable = 'integer' },
    MicroVideoVersion   = { Writable = 'integer' },
    MicroVideoOffset    = { Writable = 'integer' },
    MicroVideoPresentationTimestampUs = { Writable = 'integer' },
    shot_log_data = { -- #forum14108
        Name = 'ShotLogData',
        Writable = 'string', -- (writable in encoded format)
        IsProtobuf = 1,
        Binary = 1,
        SubDirectory = { TagTable = 'lexiftool.Google.ShotLogData' },
    },
    HdrPlusMakernote = {
        Name = 'HDRPlusMakerNote',
        Writable = 'string', -- (writable in encoded format)
        Binary = 1,
        SubDirectory = { TagTable = 'lexiftool.Google.HDRPlusMakerNote' },
    },
    MotionPhoto        = { Writable = 'integer' },
    MotionPhotoVersion = { Writable = 'integer' },
    MotionPhotoPresentationTimestampUs = { Writable = 'integer' },
}

-- Google creations namespace (ref PH)
Google.GCreations = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GCreations', [2] = 'Camera' },
    NAMESPACE = 'GCreations',
    NOTES = 'Google creations tags.',
    CameraBurstID  = { },
    Type = { Avoid = 1 },
}

-- Google depth-map Device namespace (ref 13)
Google.Device = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-Device', [2] = 'Camera' },
    NAMESPACE = { Device = 'http://ns.google.com/photos/dd/1.0/device/' },
    NOTES = [[
        Google depth-map Device tags.  See
        L<https://developer.android.com/training/camera2/Dynamic-depth-v1.0.pdf> for
        the specification.
    ]],
    Container = {
        Struct = {
            STRUCT_NAME = 'Google DeviceContainer',
            NAMESPACE   = { Container = 'http://ns.google.com/photos/dd/1.0/container/' },
            Directory = {
                List = 'Seq',
                Struct = {
                    STRUCT_NAME = 'Google DeviceDirectory',
                    NAMESPACE   = { Container = 'http://ns.google.com/photos/dd/1.0/container/' },
                    Item = {
                        Struct = {
                            STRUCT_NAME = 'Google DeviceItem',
                            NAMESPACE = { Item = 'http://ns.google.com/photos/dd/1.0/item/' },
                            -- use this as a key to process Google trailer
                            Mime    = { RawConv = function(self, val) self.ProcessGoogleTrailer = val; return val end },
                            Length  = { Writable = 'integer' },
                            Padding = { Writable = 'integer' },
                            DataURI = { },
                        },
                    },
                },
            }
        },
    },
    Profiles = {
        List = 'Seq',
        FlatName = '',
        Struct = {
            STRUCT_NAME = 'Google DeviceProfiles',
            NAMESPACE = { Device = 'http://ns.google.com/photos/dd/1.0/device/' },
            Profile = {
                Struct = {
                    STRUCT_NAME = 'Google DeviceProfile',
                    NAMESPACE = { Profile = 'http://ns.google.com/photos/dd/1.0/profile/' },
                    CameraIndices = { List = 'Seq', Writable = 'integer' },
                    Type = { },
                },
            },
        },
    },
    Cameras = {
        List = 'Seq',
        FlatName = '',
        Struct = {
            STRUCT_NAME = 'Google DeviceCameras',
            NAMESPACE = { Device = 'http://ns.google.com/photos/dd/1.0/device/' },
            Camera = {
                Struct = {
                    STRUCT_NAME = 'Google DeviceCamera',
                    NAMESPACE = { Camera = 'http://ns.google.com/photos/dd/1.0/camera/' },
                    DepthMap = {
                        Struct = {
                            STRUCT_NAME = 'Google DeviceDepthMap',
                            NAMESPACE = { DepthMap = 'http://ns.google.com/photos/dd/1.0/depthmap/' },
                            ConfidenceURI = { },
                            DepthURI    = { },
                            Far         = { Writable = 'real' },
                            Format      = { },
                            ItemSemantic= { },
                            MeasureType = { },
                            Near        = { Writable = 'real' },
                            Units       = { },
                            Software    = { },
                            FocalTableEntryCount = { Writable = 'integer' },
                            FocalTable  = { }, -- (base64)
                        },
                    },
                    Image = {
                        Struct = {
                            STRUCT_NAME = 'Google DeviceImage',
                            NAMESPACE = { Image = 'http://ns.google.com/photos/dd/1.0/image/' },
                            ItemSemantic= { },
                            ItemURI     = { },
                        },
                    },
                    ImagingModel = {
                        Struct = {
                            STRUCT_NAME = 'Google DeviceImagingModel',
                            NAMESPACE = { ImagingModel = 'http://ns.google.com/photos/dd/1.0/imagingmodel/' },
                            Distortion      = { }, -- (base64)
                            DistortionCount = { Writable = 'integer' },
                            FocalLengthX    = { Writable = 'real' },
                            FocalLengthY    = { Writable = 'real' },
                            ImageHeight     = { Writable = 'integer' },
                            ImageWidth      = { Writable = 'integer' },
                            PixelAspectRatio= { Writable = 'real' },
                            PrincipalPointX = { Writable = 'real' },
                            PrincipalPointY = { Writable = 'real' },
                            Skew            = { Writable = 'real' },
                        },
                    },
                    PointCloud = {
                        Struct = {
                            STRUCT_NAME = 'Google DevicePointCloud',
                            NAMESPACE = { PointCloud = 'http://ns.google.com/photos/dd/1.0/pointcloud/' },
                            PointCloud  = { Writable = 'integer' },
                            Points      = { },
                            Metric      = { Writable = 'boolean' },
                        },
                    },
                    Pose = { Struct = sPose },
                    LightEstimate = {
                        Struct = {
                            STRUCT_NAME = 'Google DeviceLightEstimate',
                            NAMESPACE = { LightEstimate = 'http://ns.google.com/photos/dd/1.0/lightestimate/' },
                            ColorCorrectionR = { Writable = 'real' },
                            ColorCorrectionG = { Writable = 'real' },
                            ColorCorrectionB = { Writable = 'real' },
                            PixelIntensity   = { Writable = 'real' },
                        },
                    },
                    VendorInfo = { Struct = sVendorInfo },
                    AppInfo    = { Struct = sAppInfo },
                    Trait = { },
                },
            },
        },
    },
    VendorInfo  = { Struct = sVendorInfo },
    AppInfo     = { Struct = sAppInfo },
    EarthPos    = { Struct = sEarthPose },
    Pose        = { Struct = sPose },
    Planes = {
        List = 'Seq',
        FlatName = '',
        Struct = {
            STRUCT_NAME = 'Google DevicePlanes',
            NAMESPACE = { Device = 'http://ns.google.com/photos/dd/1.0/device/' },
            Plane = {
                Struct = {
                    STRUCT_NAME = 'Google DevicePlane',
                    NAMESPACE = { Plane = 'http://ns.google.com/photos/dd/1.0/plane/' },
                    Pose    = { Struct = sPose },
                    ExtentX = { Writable = 'real' },
                    ExtentZ = { Writable = 'real' },
                    BoundaryVertexCount = { Writable = 'integer' },
                    Boundary = { },
                },
            },
        },
    },
}

-- Google container tags (ref https://developer.android.com/guide/topics/media/platform/hdr-image-format)
-- NOTE: The namespace prefix used by ExifTool is 'GContainer' instead of 'Container'
-- dueo to a conflict with Google's depth-map Device 'Container' namespace!
Google.GContainer = XMP.xmpTableDefaults {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-GContainer', [2] = 'Image' },
    NAMESPACE = 'GContainer',
    NOTES = [[
        Google Container namespace.  ExifTool uses the prefix 'GContainer' instead
        of 'Container' to avoid a conflict with the Google Device Container
        namespace.
    ]],
    Directory = {
        Name = 'ContainerDirectory',
        FlatName = 'Directory',
        List = 'Seq',
        Struct = {
            STRUCT_NAME = 'Google Directory',
            Item = {
                Namespace = 'GContainer',
                Struct = {
                    STRUCT_NAME = 'Google Item',
                    -- (use 'GItem' to avoid conflict with Google Device Container Item)
                    NAMESPACE = { GItem = 'http://ns.google.com/photos/1.0/container/item/' },
                    -- use this as a key to process Google trailer
                    Mime     = { RawConv = function(self, val) self.ProcessGoogleTrailer = val; return val end },
                    Semantic = {},
                    Length   = { Writable = 'integer' },
                    Label    = {},
                    Padding  = { Writable = 'integer' },
                    URI      = {},
                },
            },
        },
    },
}

-- DHRP maker notes (ref PH)
Google.HDRPlusMakerNote = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    TAG_PREFIX = 'HDRPlusMakerNote',
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return Google.ProcessHDRP(et, dirInfo, tagTablePtr) end,
    VARS = {
        ID_FMT = 'str',
        SORT_PROC = function(a, b)
            a = subst(a, '(\\d+)', function(d) return sprintf('%.3d', d) end, 'g')
            b = subst(b, '(\\d+)', function(d) return sprintf('%.3d', d) end, 'g')
            return perl.cmp(a, b)  -- ($a cmp $b)
        end,
    },
    NOTES = [[
        Google protobuf-format HDR-Plus maker notes.  Tag ID's are hierarchical
        protobuf field numbers.  Stored as base64-encoded, encrypted and gzipped
        Protobuf data.  Much of this metadata is still unknown, but is extracted
        using the Unknown option.
    ]],
    ['1-1'] = 'ImageName',
    ['1-2'] = { Name = 'ImageData',   Format = 'undef', Binary = 1 },
    ['2']   = { Name = 'TimeLogText', Binary = 1 },
    ['3']   = { Name = 'SummaryText', Binary = 1 },
    ['9-3'] = { Name = 'FrameCount',  Format = 'unsigned' },
   -- 9-4 - smaller for larger focal lengths
    ['9-36-1'] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        Priority = 0, -- (to give EXIF priority)
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['12-1'] = { Name = 'DeviceMake',     Groups = { [2] = 'Device' } },
    ['12-2'] = { Name = 'DeviceModel',    Groups = { [2] = 'Device' } },
    ['12-3'] = { Name = 'DeviceCodename', Groups = { [2] = 'Device' } },
    ['12-4'] = { Name = 'DeviceHardwareRevision', Groups = { [2] = 'Device' } },
    ['12-6'] = { Name = 'HDRPSoftware',   Groups = { [2] = 'Device' } },
    ['12-7'] = { Name = 'AndroidRelease', Groups = { [2] = 'Device' } },
    ['12-8'] = {
        Name = 'SoftwareDate',
        Groups = { [2] = 'Time' },
        Format = 'unsigned',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val / 1000, 1, 3) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['12-9']  = { Name = 'Application', Groups = { [2] = 'Device' } },
    ['12-10'] = { Name = 'AppVersion',  Groups = { [2] = 'Device' } },
    ['12-12-1'] = {
        Name = 'ExposureTimeMin',
        Groups = { [2] = 'Camera' },
        Format = 'float',
        ValueConv = function(_self, val) return val / 1000 end,
    },
    ['12-12-2'] = {
        Name = 'ExposureTimeMax',
        Groups = { [2] = 'Camera' },
        Format = 'float',
        ValueConv = function(_self, val) return val / 1000 end,
    },
    ['12-13-1'] = { Name = 'ISOMin', Format = 'float', Groups = { [2] = 'Camera' } }, -- (NC)
    ['12-13-2'] = { Name = 'ISOMax', Format = 'float', Groups = { [2] = 'Camera' } }, -- (NC)
    ['12-14'] = { Name = 'MaxAnalogISO', Format = 'float', Groups = { [2] = 'Camera' } }, -- (NC)
}

Google.ShotLogData = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    TAG_PREFIX = 'ShotLogData',
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return Google.ProcessHDRP(et, dirInfo, tagTablePtr) end,
    VARS = { ID_FMT = 'str' },
    NOTES = 'Stored as base64-encoded, encrypted and gzipped Protobuf data.',
    ['2'] = { Name = 'MeteringFrameCount', Format = 'unsigned' }, -- (NC)
    ['3'] = { Name = 'OriginalPayloadFrameCount', Format = 'unsigned' }, -- (NC)
    -- 1-6 - pure_fraction_of_pixels_from_long_exposure?
    -- 1-7 - weighted_fraction_of_pixels_from_long_exposure?
}

Google.HDRPMakerNote = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    TAG_PREFIX = '',
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return Google.ProcessHDRP(et, dirInfo, tagTablePtr) end,
    VARS = { LONG_TAGS = 1 },
    NOTES = [[
        Google text-based HDRP maker note tags.  Stored as base64-encoded,
        encrypted and gzipped text.
    ]],
    ['InitParams']        = { Name = 'InitParamsText',      Binary = 1 },
    ['Logging metadata']  = { Name = 'LoggingMetadataText', Binary = 1 },
    ['Merged image']      = { Name = 'MergedImage',         Binary = 1 },
    ['Finished image']    = { Name = 'FinishedImage',       Binary = 1 },
    ['Payload frame']     = { Name = 'PayloadFrame',        Binary = 1 },
    ['Payload metadata']  = { Name = 'PayloadMetadataText', Binary = 1 },
    ['ShotLogData']       = { Name = 'ShotLogDataText',     Binary = 1 },
    ['ShotParams']        = { Name = 'ShotParamsText',      Binary = 1 },
    ['StaticMetadata']    = { Name = 'StaticMetadataText',  Binary = 1 },
    ['Summary']           = { Name = 'SummaryText',         Binary = 1 },
    ['Time log']          = { Name = 'TimeLogText',         Binary = 1 },
    ['Unused logging metadata'] = { Name = 'UnusedLoggingMetadata', Binary = 1 },
    ['Rectiface']         = { Name = 'RectifaceText',       Binary = 1 },
    ['GoudaRequest']      = { Name = 'GoudaRequestText',    Binary = 1 },
    ProcessingNotes = { },
}

Google.PortraitReq = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    TAG_PREFIX = '',
    PROCESS_PROC = function(et, dirInfo, tagTablePtr) return Google.ProcessHDRP(et, dirInfo, tagTablePtr) end,
    NOTES = [[
        Google text-based PortraitRequest information.  Stored as base64-encoded,
        encrypted and gzipped text.
    ]],
}

--------------------------------------------------------------------------------
-- Read HDRP text-format maker note version 2
-- Inputs: 0) ExifTool ref, 1) data ref
function Google.ProcessHDRPMakerNote(et, dataPt)
    local tag, pos
    local tagTbl = GetTagTable(nil, 'lexiftool.Google.HDRPMakerNote')
    local gpos = 0  -- (Lua: pos($$dataPt) of the //mg match below)
    while true do
        local end_, last
        local m1, mEnd = matches(dataPt, '(?m)^ ?([A-Z].*)$', gpos)
        if mEnd then
            gpos = mEnd
            end_ = gpos - #m1
        else
            end_ = #dataPt
            last = true
        end
        if tag then
            local len = end_ - (pos + 1)
            if len <= 0 then break end -- (just to be safe)
            et:HandleTag(tagTbl, tag, substr(dataPt, pos + 1, len), { MakeTagInfo = 1 })
        end
        if last then break end
        tag = m1
        if not (isMatch(tag, ':') or isMatch(tag, '^\\w+$')) then
            et:HandleTag(tagTbl, 'ProcessingNotes', tag)
            tag = nil
        else
            pos = gpos
            local b64, dat = matches(tag, '( \\(base64\\))?: ?(.*)')
            if dat ~= nil then tag = subst(tag, '( \\(base64\\))?: ?(.*)', '') end
            if perl.truthy(dat) then
                -- (upstream DecodeBase64 returns a scalar ref)
                if b64 then dat = { ref = 'SCALAR', value = XMP.DecodeBase64(dat) } end
                et:HandleTag(tagTbl, tag, dat, { MakeTagInfo = 1 })
                tag = nil
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Decode HDRP maker notes (ref https://github.com/jakiki6/ruminant/blob/master/ruminant/modules/images.py)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: decoded+decrypted+gunzipped data string, or nil on error
-- - also extracts protobuf info as separate tags when Unknown used if
--   tagInfo.IsProtobuf is set
function Google.ProcessHDRP(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local tagInfo = dirInfo.TagInfo
    local tagName = tagInfo and tagInfo.Name or ''
    local verbose = et:Options('Verbose') or 0
    local fast = et:Options('FastScan') or 0
    local ver, valPt

    if fast > 1 then return nil end

    -- upstream Perl truthiness: `if ($$dirInfo{DirStart})`
    if dirInfo.DirStart ~= nil and dirInfo.DirStart ~= 0 then
        dataPt = substr(dataPt, dirInfo.DirStart, dirInfo.DirLen or #dataPt)
    end
    if perl.matches(dataPt, '^HDRP[\x02\x03]') then
        valPt = dataPt
    else
        et:VerboseDir(tagName, nil, #dataPt)
        if verbose > 2 then et:VerboseDump(dataPt) end
        valPt = XMP.DecodeBase64(dataPt)
        if verbose > 2 then
            et:VerboseDir('Base64-decoded ' .. tagName, nil, #valPt)
            et:VerboseDump(valPt)
        end
    end
    local verStr = perl.matches(valPt, '^HDRP([\x02\x03])')
    if verStr then
        ver = verStr:byte(1)
        valPt = valPt:sub(6)
    else
        et:Warn('Unrecognized HDRP format')
        return nil
    end
    -- pad to an even 8 bytes
    local pad = (8 - (#valPt % 8)) & 0x07
    if pad > 0 then valPt = valPt .. string.rep('\0', pad) end
    -- unpack little-endian 32-bit words
    local words = { perl.unpack('V*', valPt) }
    -- my $key = 0x2515606b4a7791cd;
    local key = 0x2515606b4a7791cd
    local i = 1 -- (Lua: words array is 1-based; upstream Perl 0-based)
    while i <= #words - 1 do
        -- rotate the key for each new 64-bit word
        -- $key ^= $key >> 12;
        key = key ~ (key >> 12)
        -- $key ^= ($key << 25) & 0xffffffffffffffff;
        -- (Lua's << already discards the bits shifted out, like the mask)
        key = key ~ (key << 25)
        -- $key ^= $key >> 27;
        key = key ~ (key >> 27)
        -- $key = ($key * 0x2545f4914f6cdd1d) & 0xffffffffffffffff;
        -- (Lua integer multiplication wraps modulo 2^64, exactly the masked
        --  low 64 bits upstream keeps; the hi/lo split of upstream's 32-bit
        --  backward-compatible math reproduces the same two XOR operands)
        key = key * 0x2545f4914f6cdd1d
        -- apply the key to this 64-bit word (lo first: 'V*' unpack order)
        words[i] = words[i] ~ (key & 0xffffffff)
        words[i + 1] = words[i + 1] ~ (key >> 32)
        i = i + 2
    end
    -- repack and remove padding
    local val = perl.pack('V*', table.unpack(words, 1, #words))
    if pad > 0 then val = substr(val, 0, -pad) end
    if verbose > 2 then
        et:VerboseDir('Decrypted ' .. tagName, nil, #val)
        et:VerboseDump(val)
    end
    local result
    if et:hasZlib() then
        local ok, buff = pcall(function() return (et:gunzip(val)) end)
        if ok and buff then
            if verbose > 2 then
                et:VerboseDir('Gunzipped ' .. tagName, nil, #buff)
                et:VerboseDump(buff)
            end
            if ver == 3 or (tagInfo and tagInfo.IsProtobuf) then
                local subDir = {
                    DataPt = buff,
                    DirName = tagName,
                }
                require('lexiftool.Protobuf').ProcessProtobuf(et, subDir, tagTbl)
            else
                Google.ProcessHDRPMakerNote(et, buff)
            end
            result = buff
        else
            et:Warn('Error inflating stream')
        end
    else
        et:Warn('Install IO::Uncompress::Gunzip to decode HDRP makernote')
    end
    return result
end

return Google
