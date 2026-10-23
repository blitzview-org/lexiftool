--------------------------------------------------------------------------------
-- File:         lexiftool/GIMP.lua
-- Ported from:  lib/Image/ExifTool/GIMP.pm
--
-- Description:  Read meta information from GIMP XCF images
--
-- Revisions:    2010/10/05 - P. Harvey Created
--               2018/08/21 - PH Updated to current XCF specification (v013)
--
-- References:   1) GIMP source code
--               2) https://gitlab.gnome.org/GNOME/gimp/blob/master/devel-docs/xcf.txt
--
-- Port notes:   read port: the Main/Header/Resolution/Parasite tables plus
--               ProcessXCF and ProcessParasites. Upstream GIMP.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local str = require('lexiftool.perl').str
local uc = require('lexiftool.perl').uc
local ucfirst = require('lexiftool.perl').ucfirst

local GIMP = {}

-- GIMP XCF properties (ref 2) (upstream %Image::ExifTool::GIMP::Main)
GIMP.Main = {
    GROUPS = { [2] = 'Image' },
    VARS = { ALPHA_FIRST = 1 },
    NOTES = [[
        The GNU Image Manipulation Program (GIMP) writes these tags in its native
        XCF (eXperimental Computing Facilty) images.
    ]],
    header = { SubDirectory = { TagTable = 'lexiftool.GIMP.Header' } },
    -- recognized properties
    -- 1 - ColorMap
    -- 17 - SamplePoints? (doc says 17 is also "PROP_SAMPLE_POINTS"??)
    [17] = {
        Name = 'Compression',
        Format = 'int8u',
        PrintConv = {
            [0] = 'None',
            [1] = 'RLE Encoding',
            [2] = 'Zlib',
            [3] = 'Fractal',
        },
    },
    -- 18 - Guides
    [19] = {
        Name = 'Resolution',
        SubDirectory = { TagTable = 'lexiftool.GIMP.Resolution' },
    },
    [20] = {
        Name = 'Tattoo',
        Format = 'int32u',
    },
    [21] = {
        Name = 'Parasites',
        SubDirectory = { TagTable = 'lexiftool.GIMP.Parasite' },
    },
    [22] = {
        Name = 'Units',
        Format = 'int32u',
        PrintConv = {
            [1] = 'Inches',
            [2] = 'mm',
            [3] = 'Points',
            [4] = 'Picas',
        },
    },
    -- 23 Paths
    -- 24 UserUnit
    -- 25 Vectors
}

-- information extracted from the XCF file header (ref 2)
-- (upstream %Image::ExifTool::GIMP::Header)
GIMP.Header = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [9] = {
        Name = 'XCFVersion',
        Format = 'string[5]',
        DataMember = 'XCFVersion',
        RawConv = function(self, val) self.XCFVersion = val return val end,
        PrintConv = {
            file = '0',
            v001 = '1',
            v002 = '2',
            OTHER = function(val) return (str(val):gsub('^v0*', '')) end,
        },
    },
    [14] = { Name = 'ImageWidth', Format = 'int32u' },
    [18] = { Name = 'ImageHeight', Format = 'int32u' },
    [22] = {
        Name = 'ColorMode',
        Format = 'int32u',
        PrintConv = {
            [0] = 'RGB Color',
            [1] = 'Grayscale',
            [2] = 'Indexed Color',
        },
    },
    -- 26 - [XCF 4 or later] Precision
}

-- XCF resolution data (property type 19) (ref 2)
-- (upstream %Image::ExifTool::GIMP::Resolution)
GIMP.Resolution = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    FORMAT = 'float',
    [0] = 'XResolution',
    [1] = 'YResolution',
}

-- XCF "Parasite" data (property type 21) (ref 1/PH)
-- (upstream %Image::ExifTool::GIMP::Parasite)
GIMP.Parasite = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = nil, -- (set below, ProcessParasites is defined after this table)
    ['gimp-comment'] = {
        Name = 'Comment',
        Format = 'string',
    },
    ['exif-data'] = {
        Name = 'ExifData',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            Start = 6, -- starts after "Exif\0\0" header
        },
    },
    ['jpeg-exif-data'] = { -- (deprecated, untested)
        Name = 'JPEGExifData',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            Start = 6,
        },
    },
    ['iptc-data'] = { -- (untested)
        Name = 'IPTCData',
        SubDirectory = { TagTable = 'lexiftool.IPTC.Main' },
    },
    ['icc-profile'] = {
        Name = 'ICC_Profile',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    ['icc-profile-name'] = {
        Name = 'ICCProfileName',
        Format = 'string',
    },
    ['gimp-metadata'] = {
        Name = 'XMP',
        SubDirectory = {
            TagTable = 'lexiftool.XMP.Main',
            Start = 10, -- starts after "GIMP_XMP_1" header
        },
    },
    ['gimp-image-metadata'] = {
        Name = 'XML',
        SubDirectory = { TagTable = 'lexiftool.XMP.XML' },
    },
    -- Seen, but not yet decoded:
    --  gimp-image-grid
    --  jpeg-settings
}

--------------------------------------------------------------------------------
-- Read information in a GIMP XCF parasite data (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function GIMP.ProcessParasites(et, dirInfo, tagTablePtr)
    local unknown = perlTruthy(et:Options('Unknown')) and et:Options('Unknown') or et:Options('Verbose')
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart or 0
    local endPos = #dataPt
    et:VerboseDir('Parasites', nil, endPos)
    while true do
        if pos + 4 > endPos then break end
        local size = ExifTool.Get32u(dataPt, pos) -- length of tag string
        pos = pos + 4
        if pos + size + 8 > endPos then break end
        local tag = dataPt:sub(pos + 1, pos + size)
        pos = pos + size
        tag = tag:gsub('\0.*', '') -- trim at null terminator
        -- local flags = ExifTool.Get32u(dataPt, pos) (ignore flags)
        size = ExifTool.Get32u(dataPt, pos + 4) -- length of data
        pos = pos + 8
        if pos + size > endPos then break end
        if not tagTablePtr[tag] and perlTruthy(unknown) then
            local name = tag:gsub('[^%-_A-Za-z%d]', '')
            name = name:gsub('^gimp%-', '')
            if #name > 0 then
                name = ucfirst(name)
                name = name:gsub('([a-z])%-([a-z])', function(a, b) return a .. uc(b) end)
                if #name <= 1 then name = 'GIMP-' .. name end
                et:AddTagToTable(tagTablePtr, tag, { Name = name, Unknown = 1 })
            end
        end
        et:HandleTag(tagTablePtr, tag, nil, {
            DataPt = dataPt,
            Start = pos,
            Size = size,
        })
        pos = pos + size
    end
    return 1
end

GIMP.Parasite.PROCESS_PROC = GIMP.ProcessParasites

--------------------------------------------------------------------------------
-- Read information in a GIMP XCF document
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid XCF file
--------------------------------------------------------------------------------
function GIMP.ProcessXCF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(26)
    if n ~= 26 then return 0 end
    if not buff:match('^gimp xcf ') then return 0 end

    local tagTablePtr = et:GetTagTable('lexiftool.GIMP.Main')
    local verbose = et:Options('Verbose')
    et:SetFileType()
    ExifTool.SetByteOrder('MM')

    -- process the XCF header
    et:HandleTag(tagTablePtr, 'header', buff)

    -- skip over precision for XCF version 4 or later
    local ver = et.XCFVersion and et.XCFVersion:match('^v0*(%d+)')
    if ver and tonumber(ver) >= 4 then raf:Seek(4, 1) end

    -- loop through image properties
    while true do
        n, buff = raf:Read(8)
        if n ~= 8 then break end
        local tag = ExifTool.Get32u(buff, 0)
        if tag == 0 then break end
        local size = ExifTool.Get32u(buff, 4)
        if perlTruthy(verbose) then et:VPrint(0, string.format('XCF property %d (%d bytes):\n', tag, size)) end
        if not tagTablePtr[tag] then
            raf:Seek(size, 1)
        else
            n, buff = raf:Read(size)
            if n ~= size then break end
            et:HandleTag(tagTablePtr, tag, nil, {
                DataPt = buff,
                DataPos = raf:Tell() - size,
                Size = size,
            })
        end
    end
    return 1
end

return GIMP
