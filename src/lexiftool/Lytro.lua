--------------------------------------------------------------------------------
-- File:         lexiftool/Lytro.lua
-- Ported from:  lib/Image/ExifTool/Lytro.pm
--
-- Description:  Read Lytro LFP files
--
-- Revisions:    2014-07-17 - P. Harvey Created
--
-- References:   1) http://optics.miloush.net/lytro/TheFileFormat.aspx
--
-- Port notes:   read port: the Main table plus ExtractTags and ProcessLFP.
--               Upstream Lytro.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Import = require('lexiftool.Import')
local Exif = require('lexiftool.Exif')
local sprintf = require('lexiftool.perl').sprintf
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst
-- (XMP is required at the point of use, not at the top: a top-level require
--  would load it for every file that loads this module, and
--  BuildCompositeTags derives its worklist from `package.loaded`)

local Lytro = {}

-- Lytro LFP tags (ref PH)
Lytro.Main = {
    GROUPS = { [2] = 'Camera' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Tag definitions for Lytro Light Field Picture (LFP) files.  ExifTool
        extracts the full JSON metadata blocks, as well as breaking them down into
        individual tags.  All available tags are extracted from the JSON metadata,
        even if they don't appear in the table below.
    ]],
    JSONMetadata = {
        Notes = 'the full JSON-format metadata blocks',
        Binary = 1,
        List = 1,
    },
    EmbeddedImage = {
        Notes = 'JPEG image embedded in LFP files written by Lytro Desktop',
        Groups = { [2] = 'Preview' },
        Binary = 1,
    },
    Type = { Name = 'CameraType' },
    CameraMake = { Name = 'Make' },
    CameraModel = { Name = 'Model', Description = 'Camera Model Name' },
    CameraSerialNumber = { Name = 'SerialNumber' },
    CameraFirmware = { Name = 'FirmwareVersion' },
    DevicesAccelerometerSampleArrayTime = { Name = 'AccelerometerTime' },
    DevicesAccelerometerSampleArrayX = { Name = 'AccelerometerX' },
    DevicesAccelerometerSampleArrayY = { Name = 'AccelerometerY' },
    DevicesAccelerometerSampleArrayZ = { Name = 'AccelerometerZ' },
    DevicesClockZuluTime = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    DevicesLensFNumber = {
        Name = 'FNumber',
        PrintConv = function(_self, val) return Exif.PrintFNumber(val) end,
    },
    DevicesLensFocalLength = {
        Name = 'FocalLength',
        ValueConv = function(_self, val) return val * 1000 end, -- convert from metres to mm
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
    },
    DevicesLensTemperature = {
        Name = 'LensTemperature',
        PrintConv = function(_self, val) return sprintf('%.1f C', val) end,
    },
    DevicesSocTemperature = {
        Name = 'SocTemperature',
        PrintConv = function(_self, val) return sprintf('%.1f C', val) end,
    },
    DevicesShutterFrameExposureDuration = {
        Name = 'FrameExposureTime',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    DevicesShutterPixelExposureDuration = {
        Name = 'ExposureTime',
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    DevicesSensorPixelPitch = {
        Name = 'FocalPlaneXResolution',
        Notes = 'Y resolution is the same as X resolution',
        ValueConv = function(_self, val) return 25.4 / val / 1000 end, -- convert from metres to pixels/inch
    },
    DevicesSensorSensorSerial = { Name = 'SensorSerialNumber' },
    DevicesSensorIso = { Name = 'ISO' },
    ImageLimitExposureBias = { Groups = { [2] = 'Image' }, PrintConv = function(_self, val) return sprintf('%+.1f', val) end },
    ImageModulationExposureBias = { Groups = { [2] = 'Image' }, PrintConv = function(_self, val) return sprintf('%+.1f', val) end },
    ImageOrientation = {
        Name = 'Orientation',
        Groups = { [2] = 'Image' },
        PrintConv = { [1] = 'Horizontal (normal)' },
    },
}

--------------------------------------------------------------------------------
-- Extract tags from a parsed JSON hash
-- Inputs: 0) ExifTool ref, 1) tag hash, 2) base tag name
--------------------------------------------------------------------------------
local function ExtractTags(et, meta, parent)
    if type(meta) ~= 'table' or meta._ordered_keys_ == nil then
        et:Warn('Invalid LFP metadata')
        return
    end
    local tagTablePtr
    for _, key in ipairs(ExifTool.OrderedKeys(meta)) do
        local tag = parent .. ucfirst(key)
        local mval = meta[key]
        local isArray = type(mval) == 'table' and mval._ordered_keys_ == nil
        local values = isArray and mval or { mval }
        for _, val in ipairs(values) do
            if type(val) == 'table' and val._ordered_keys_ ~= nil then
                ExtractTags(et, val, tag)
            else
                if not tagTablePtr then tagTablePtr = et:GetTagTable('lexiftool.Lytro.Main') end
                if not tagTablePtr[tag] then
                    local name = tag:gsub('[^%-_a-zA-Z0-9](.?)', function(c) return uc(c) end)
                    name = name:gsub('ParametersVendorContentComLytroTags', '')
                    local tagInfo = {}
                    local stripped, count = name:gsub('^Devices', '')
                    if count > 0 then
                        name = stripped
                    else
                        tagInfo.Groups = { [2] = 'Image' }
                    end
                    if isArray then tagInfo.List = 1 end
                    tagInfo.Name = name
                    et:AddTagToTable(tagTablePtr, tag, tagInfo)
                end
                et:HandleTag(tagTablePtr, tag, val)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Process segments from a Lytro LFP image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid Lytro image
--------------------------------------------------------------------------------
function Lytro.ProcessLFP(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(16)
    if not (n == 16 and buff:sub(1, 8) == '\137LFP\13\10\26\10') then return 0 end
    et:SetFileType() -- set the FileType tag
    ExifTool.SetByteOrder('MM')
    local tagTablePtr = et:GetTagTable('lexiftool.Lytro.Main')
    while true do
        local n2
        n2, buff = raf:Read(16)
        if n2 ~= 16 then break end
        if buff:sub(1, 3) ~= '\137LF' then
            et:Warn('LFP format error')
            break
        end
        local size = ExifTool.Get32u(buff, 12)
        if size & 0x80000000 ~= 0 then
            et:Warn('Invalid LFP segment size')
            break
        end
        local nid = raf:Read(80)
        if nid ~= 80 then
            et:Warn('Truncated LFP segment')
            break
        end
        if size > 20000000 then
            if not raf:Seek(size, 1) then
                et:Warn('Seek error in LFP file')
                break
            end
        else
            local n3
            n3, buff = raf:Read(size)
            if n3 ~= size then
                et:Warn('Truncated LFP data')
                break
            end
            if buff:match('^{[ \t\n\r\f\v]+"') then -- JSON metadata?
                et:HandleTag(tagTablePtr, 'JSONMetadata', buff)
                local meta = Import.ReadJSONObject(nil, { data = buff, pos = 0 })
                ExtractTags(et, meta, '')
            elseif buff:sub(1, 3) == '\255\216\255' then -- embedded JPEG image?
                et:HandleTag(tagTablePtr, 'EmbeddedImage', buff)
            end
        end
        -- skip padding if necessary
        local pad = 16 - (size % 16)
        if pad ~= 16 then raf:Seek(pad, 1) end
    end
    return 1
end

return Lytro
