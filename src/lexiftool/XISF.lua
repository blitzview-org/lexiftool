--------------------------------------------------------------------------------
-- File:         lexiftool/XISF.lua
-- Ported from:  lib/Image/ExifTool/XISF.pm
--
-- Description:  Read Extensible Image Serialization Format metadata
--
-- Revisions:    2023-10-10 - P. Harvey Created
--
-- References:   1) https://pixinsight.com/doc/docs/XISF-1.0-spec/XISF-1.0-spec.html
--
-- Port notes:   read port: the Main table plus HandleXISFAttrs and ProcessXISF.
--               Upstream XISF.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local XMP = require('lexiftool.XMP')
local perl = require('lexiftool.perl')

local XISF = {}

local dateInfo = {
    Groups = { [2] = 'Time' },
    ValueConv = function(_self, val) return XMP.ConvertXMPDate(val) end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- XISF tags (ref 1)
XISF.Main = {
    GROUPS = { [0] = 'XML', [1] = 'XML', [2] = 'Image' },
    VARS = { LONG_TAGS = 1 },
    NOTES = [[
        This table lists some standard Extensible Image Serialization Format (XISF)
        tags, but ExifTool will extract any other tags found.  See
        L<https://pixinsight.com/xisf/> for the specification.
    ]],
    ImageGeometry = {},
    ImageSampleFormat = {},
    ImageBounds = {},
    ImageImageType = { Name = 'ImageType' },
    ImageColorSpace = { Name = 'ColorSpace' },
    ImageLocation = {},
    ImageResolutionHorizontal = 'XResolution',
    ImageResolutionVertical = 'YResolution',
    ImageResolutionUnit = 'ResolutionUnit',
    ImageICCProfile = {
        Name = 'ICC_Profile',
        ValueConv = function(_self, val) return XMP.DecodeBase64(val) end,
        Binary = 1,
    },
    ImageICCProfileLocation = { Name = 'ICCProfileLocation' },
    ImagePixelStorage = {},
    ImageOffset = { Name = 'ImagePixelOffset' },
    ImageOrientation = { Name = 'Orientation' },
    ImageId = { Name = 'ImageID' },
    ImageUuid = { Name = 'UUID' },
    ImageData = { Binary = 1 },
    CreationTime = { Name = 'CreateDate', Shift = 'Time', Groups = dateInfo.Groups, ValueConv = dateInfo.ValueConv, PrintConv = dateInfo.PrintConv },
    CreatorApplication = {},
    Abstract = {},
    AccessRights = {},
    Authors = { Groups = { [2] = 'Author' } },
    BibliographicReferences = {},
    BriefDescription = {},
    CompressionLevel = {},
    CompressionCodecs = {},
    Contributors = { Groups = { [2] = 'Author' } },
    Copyright = { Groups = { [2] = 'Author' } },
    CreatorModule = {},
    CreatorOS = {},
    Description = {},
    Keywords = {},
    Languages = {},
    License = {},
    OriginalCreationTime = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Shift = 'Time',
        Groups = dateInfo.Groups,
        ValueConv = dateInfo.ValueConv,
        PrintConv = dateInfo.PrintConv,
    },
    RelatedResources = {},
    Title = {},
}

--------------------------------------------------------------------------------
-- Handle properties in XISF metadata structures
-- Inputs: 0) attribute list, 1) attribute table, 2) property name, 3) value
-- Returns: 0) true if the value was changed, 1) property name, 2) value
--------------------------------------------------------------------------------
local function HandleXISFAttrs(attrList, attrs, prop, val)
    if attrs.id == nil then return false, prop, val end
    -- use "id" as the tag name, "value" as the value, and ignore "type"
    local newProp = (attrs.id:gsub('^XISF:', ''))
    local valChanged = false
    local newVal = val
    if attrs.value ~= nil then
        newVal = attrs.value
        valChanged = true
    end
    local kept = {}
    for _, a in ipairs(attrList) do
        if a == 'id' or a == 'value' or a == 'type' then
            attrs[a] = nil
        else
            kept[#kept + 1] = a
        end
    end
    for i = #attrList, 1, -1 do attrList[i] = nil end
    for i, a in ipairs(kept) do attrList[i] = a end
    return valChanged, newProp, newVal
end

--------------------------------------------------------------------------------
-- Read information in a XISF document
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid XISF file
--------------------------------------------------------------------------------
function XISF.ProcessXISF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(16)
    if not (n == 16 and buff:sub(1, 8) == 'XISF0100') then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('II')
    local tagTablePtr = et:GetTagTable('lexiftool.XISF.Main')
    local hdrLen = ExifTool.Get32u(buff, 8)
    local n2
    n2, buff = raf:Read(hdrLen)
    if n2 ~= hdrLen then
        et:Warn('Error reading XISF header')
        return 1
    end
    et:FoundTag('XML', buff)
    XMP.ProcessXMP(et, {
        DataPt = buff,
        IgnoreProp = { xisf = 1, Metadata = 1, Property = 1 },
        XMPParseOpts = { AttrProc = HandleXISFAttrs },
    }, tagTablePtr)
    local geo = et.VALUE.ImageGeometry
    if geo then
        -- split /:/, $geo (no limit): trailing empty fields dropped, so
        -- "100" or "100:200" (no NumPlanes/height) must NOT fail to match
        local parts = perl.split(':', geo)
        et:FoundTag('ImageWidth', parts[1])
        et:FoundTag('ImageHeight', parts[2])
        et:FoundTag('NumPlanes', parts[3])
    end
    return 1
end

return XISF
