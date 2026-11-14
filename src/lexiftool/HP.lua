--------------------------------------------------------------------------------
-- File:         lexiftool/HP.lua
-- Ported from:  lib/Image/ExifTool/HP.pm
--
-- Description:  Hewlett-Packard maker notes tags
--
-- Revisions:    2007-05-03 - P. Harvey Created
--
-- Port notes:   ported in full: all five tables (`Main`, `Type2`, `Type4`,
--               `Type6`, `TDHD`) plus `ProcessTDHD` and `ProcessHP`.
--               Upstream HP.pm is read-only.
--               No vendored test image carries HP maker notes or an APP6
--               "TDHD" segment.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local tsort = perl.tsort
local Exif = require('lexiftool.Exif')
local matches = perl.matches
local matchesDyn = perl.matchesDyn
local substr = perl.substr
local str = perl.str
local perlTruthy = ExifTool.perlTruthy

local HP = {}

-- HP EXIF-format maker notes (or is it Vivitar?)
HP.Main = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        These tables list tags found in the maker notes of some Hewlett-Packard
        camera models.

        The first table lists tags found in the EXIF-format maker notes of the
        PhotoSmart 720 (also used by the Vivitar ViviCam 3705, 3705B and 3715).
    ]],
    [0x0e00] = {
        Name = 'PrintIM',
        Description = 'Print Image Matching',
        SubDirectory = {
            TagTable = 'lexiftool.PrintIM.Main',
        },
    },
}

-- other types of HP maker notes
HP.Type2 = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'These tags are used by the PhotoSmart E427.',
    ['PreviewImage'] = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        -- upstream passes a scalar *reference* (`\$val`) into ValidateImage and
        -- returns the reference, which makes the value binary; this port's
        -- ValidateImage takes and returns the plain string, so the SCALAR-ref
        -- tuple is built here (same shape as Exif.lua's ExtractImage)
        RawConv = function(self, val, tag)
            local img = self:ValidateImage(val, tag)
            if img == nil then return nil end
            return { ref = 'SCALAR', value = img }
        end,
    },
    ['Serial Number'] = 'SerialNumber',
    ['Lens Shading']  = 'LensShading',
}

HP.Type4 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'These tags are used by the PhotoSmart M627.',
    [0x0c] = {
        Name = 'MaxAperture',
        Format = 'int16u',
        ValueConv = function(_self, val) return val / 10 end,
    },
    [0x10] = {
        Name = 'ExposureTime',
        Format = 'int32u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x14] = {
        Name = 'CameraDateTime',
        Groups = { [2] = 'Time' },
        Format = 'string[20]',
    },
    [0x34] = {
        Name = 'ISO',
        Format = 'int16u',
    },
    [0x5c] = {
        Name = 'SerialNumber',
        Format = 'string[26]',
        RawConv = function(_self, val)
            local s, n = str(val):gsub('^SERIAL NUMBER:', '', 1)
            return n > 0 and s or nil
        end,
    },
}

HP.Type6 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'These tags are used by the PhotoSmart M425, M525 and M527.',
    [0x0c] = {
        Name = 'FNumber',
        Format = 'int16u',
        ValueConv = function(_self, val) return val / 10 end,
    },
    [0x10] = {
        Name = 'ExposureTime',
        Format = 'int32u',
        ValueConv = function(_self, val) return val / 1e6 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x14] = {
        Name = 'CameraDateTime',
        Groups = { [2] = 'Time' },
        Format = 'string[20]',
    },
    [0x34] = {
        Name = 'ISO',
        Format = 'int16u',
    },
    [0x58] = {
        Name = 'SerialNumber',
        Format = 'string[26]',
        RawConv = function(_self, val)
            local s, n = str(val):gsub('^SERIAL NUMBER:', '', 1)
            return n > 0 and s or nil
        end,
    },
}

-- proprietary format TDHD data written by Photosmart R837 (ref PH)
HP.TDHD = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        These tags are extracted from the APP6 "TDHD" segment of Photosmart R837
        JPEG images.  Many other unknown tags exist in is data, and can be seen with
        the L<Unknown|../ExifTool.html#Unknown> (-u) option.
    ]],
    -- (all subdirectories except TDHD and LSLV are automatically recognized
    -- by their "type" word of 0x10001)
    TDHD = {
        Name = 'TDHD',
        SubDirectory = { TagTable = 'lexiftool.HP.TDHD' },
    },
    LSLV = {
        Name = 'LSLV',
        SubDirectory = { TagTable = 'lexiftool.HP.TDHD' },
    },
    FWRV = 'FirmwareVersion',
    CMSN = 'SerialNumber', -- (unverified)
    -- LTEM - some temperature?
}

--------------------------------------------------------------------------------
-- Process HP APP6 TDHD metadata (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function HP.ProcessTDHD(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local pos = dirInfo.DirStart
    local dirEnd = pos + dirInfo.DirLen
    local unknown = perlTruthy(et:Options('Unknown')) or perlTruthy(et:Options('Verbose'))
    et:VerboseDir('TDHD', nil, dirInfo.DirLen)
    ExifTool.SetByteOrder('II')
    while pos + 12 < dirEnd do
        local tag = substr(dataPt, pos, 4)
        local type_ = ExifTool.Get32u(dataPt, pos + 4)
        local size = ExifTool.Get32u(dataPt, pos + 8)
        pos = pos + 12
        if size < 0 or pos + size > dirEnd then break end
        if type_ == 0x10001 then
            -- this is a subdirectory containing more tags
            local dirInfo2 = {
                DataPt   = dataPt,
                DataPos  = dataPos,
                DirStart = pos,
                DirLen   = size,
            }
            et:ProcessDirectory(dirInfo2, tagTablePtr)
        else
            if not tagTablePtr[tag] and unknown then
                local name = tag
                name = name:gsub('[^%-_A-Za-z0-9]', '')   -- remove invalid characters
                local tagInfo = {
                    Name = 'HP_TDHD_' .. name,
                    Unknown = 1,
                }
                -- guess format based on data size
                if size == 1 then
                    tagInfo.Format = 'int8u'
                elseif size == 2 then
                    tagInfo.Format = 'int16u'
                elseif size == 4 then
                    tagInfo.Format = 'int32s'
                elseif size > 80 then
                    tagInfo.Binary = 1
                end
                et:AddTagToTable(tagTablePtr, tag, tagInfo)
            end
            et:HandleTag(tagTablePtr, tag, nil, {
                DataPt  = dataPt,
                DataPos = dataPos,
                Start   = pos,
                Size    = size,
            })
        end
        pos = pos + size
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process HP maker notes
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function HP.ProcessHP(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataLen = dirInfo.DataLen
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (dataLen - dirStart)

    -- look for known text-type tags
    if perlTruthy(dirStart) or dirLen ~= #dataPt then
        local buff = substr(dataPt, dirStart, dirLen)
        dataPt = buff
    end
    -- brute-force scan for PreviewImage
    if tagTablePtr.PreviewImage then
        local m1, endPos = matches(dataPt, [[(?s)(\xff\xd8\xff\xdb.*\xff\xd9)]])
        if m1 then
            et:HandleTag(tagTablePtr, 'PreviewImage', m1)
            -- truncate preview to speed subsequent tag scans
            local buff = substr(dataPt, 0, endPos - #m1)
            dataPt = buff
        end
    end
    -- scan for other tag ID's
    local keys = ExifTool.TagTableKeys(tagTablePtr)
    tsort(keys, function(a, b) return perl.lt(str(a), str(b)) end)
    for _, tagID in ipairs(keys) do
        if tagID ~= 'PreviewImage' then
            local m = matchesDyn(dataPt, '(?i)' .. str(tagID) .. [[:\s*([\x20-\x7e]+)]])
            if m then et:HandleTag(tagTablePtr, tagID, m) end
        end
    end
    return 1
end

HP.Type2.PROCESS_PROC = HP.ProcessHP
HP.TDHD.PROCESS_PROC = HP.ProcessTDHD

return HP
