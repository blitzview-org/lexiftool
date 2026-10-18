--------------------------------------------------------------------------------
-- File:         lexiftool/MPF.lua
-- Ported from:  lib/Image/ExifTool/MPF.pm
--
-- Description:  Read Multi-Picture Format information
--
-- Revisions:    06/12/2009 - P. Harvey Created
--
-- References:   1) http://www.cipa.jp/std/documents/e/DC-007_E.pdf
--
-- Port notes:   read subset: Main / MPImage tables, ProcessMPImageList and
--               the MPF composite; processed through the main module's
--               ProcessTIFF / ProcessBinaryData.
--------------------------------------------------------------------------------

-- Frequently used library functions as local aliases.
local tconcat = table.concat

local ExifTool = require('lexiftool')
local str = require('lexiftool.perl').str
local MPF = {}

-- ExifTool MPF version (mirror of $Image::ExifTool::MPF::VERSION)
MPF.VERSION = '1.16'

-- Process MP Entry list
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function MPF.ProcessMPImageList(et, dirInfo, tagTablePtr)
    local num = math.floor(dirInfo.DirLen / 16) -- (16 bytes per MP Entry)
    dirInfo.DirLen = 16
    local success
    local oldG1 = et.SET_GROUP1
    for i = 0, num - 1 do
        et.SET_GROUP1 = '+' .. (i + 1)
        success = et:ProcessBinaryData(dirInfo, tagTablePtr)
        dirInfo.DirStart = dirInfo.DirStart + 16
    end
    et.SET_GROUP1 = oldG1
    return success
end

-- Extract all MP images
-- Inputs: 0) ExifTool object ref
-- Returns: nil
function MPF.ExtractMPImages(et)
    local ee = et:Options('ExtractEmbedded')
    local saveBinary = et:Options('Binary')
    local didPreview
    local xtra
    local i = 1
    -- run through MP images in the same order they were extracted
    -- (loop while xtra is undefined (first pass) or non-empty; an empty string
    --  is truthy in Lua, so the upstream `$xtra or not defined $xtra` must be
    --  spelled out explicitly)
    while xtra == nil or xtra ~= '' do
        xtra = et.VALUE['MPImageStart (' .. i .. ')'] ~= nil and (' (' .. i .. ')') or ''
        local off = tonumber(et:GetValue('MPImageStart' .. xtra, 'ValueConv'))
        local len = tonumber(et:GetValue('MPImageLength' .. xtra, 'ValueConv'))
        -- (Perl truthiness: 0 offsets are skipped)
        if off ~= nil and len ~= nil and off ~= 0 and len ~= 0 then
            local type_ = tonumber(et:GetValue('MPImageType' .. xtra, 'ValueConv'))
            local tag = 'MPImage' .. i
            -- store first "Large Thumbnail" as a PreviewImage
            if not didPreview and type_ and (type_ & 0x0f0000) == 0x010000 then
                tag = 'PreviewImage'
                didPreview = 1
            end
            -- with -ee the image data is really read (and really extracted
            -- from below), not replaced by the "Binary data N bytes" stand-in
            if ee then et:Options('Binary', 1) end
            local val = require('lexiftool.Exif').ExtractImage(et, off, len, tag)
            if ee then et:Options('Binary', saveBinary) end
            if val ~= nil then
                -- add the tag to the Extra table if necessary (upstream
                -- AddTagToTable so the tag ID and groups are defined)
                local extra = et:GetTagTable('lexiftool.ExifTool.Extra')
                if not et:GetTagInfo(extra, tag) then
                    et:AddTagToTable(extra, tag, {
                        Name = tag,
                        Groups = { [0] = 'Composite', [1] = 'Composite', [2] = 'Preview' },
                    })
                end
                local key = et:FoundTag(tag, val,
                    et:GetGroup('MPImageStart' .. xtra, 0),
                    et:GetGroup('MPImageStart' .. xtra, 1))
                if not key then return nil end
                -- extract information from MP images if ExtractEmbedded option used
                if ee then
                    local oldBase = et.BASE
                    et.BASE = off
                    et.DOC_NUM = i
                    et:ExtractInfo(val, { ReEntry = 1 })
                    et.DOC_NUM = nil
                    et.BASE = oldBase
                end
            end
        end
        i = i + 1
    end
    return nil
end

-- Tags found in APP2 MPF segment in JPEG images
MPF.Main = {
    GROUPS = { [0] = 'MPF', [1] = 'MPF0', [2] = 'Image' },
    NOTES = [[
        These tags are part of the CIPA Multi-Picture Format specification, and are
        found in the APP2 "MPF" segment of JPEG images.  MPImage data referenced
        from this segment is stored as a JPEG trailer.  The MPF tags are not
        writable, however the MPF segment may be deleted as a group (with "MPF:All")
        but then the JPEG trailer should also be deleted (with "Trailer:All").  See
        L<https://web.archive.org/web/20190713230858/http://www.cipa.jp/std/documents/e/DC-007_E.pdf>
        for the official specification.
    ]],
    [0xb000] = 'MPFVersion',
    [0xb001] = 'NumberOfImages',
    [0xb002] = {
        Name = 'MPImageList',
        SubDirectory = {
            TagTable = 'lexiftool.MPF.MPImage',
            ProcessProc = MPF.ProcessMPImageList,
        },
    },
    [0xb003] = {
        Name = 'ImageUIDList',
        Binary = 1,
    },
    [0xb004] = 'TotalFrames',
    [0xb101] = 'MPIndividualNum',
    [0xb201] = {
        Name = 'PanOrientation',
        PrintHex = 1,
        Notes = 'long integer is split into 4 bytes',
        ValueConv = function(_self, val)
            local out = {}
            for i = 3, 0, -1 do
                out[#out + 1] = str((val >> (8 * i)) & 0xff)
            end
            return tconcat(out, ' ')
        end,
        PrintConv = {
            function(_self, val) return str(val) .. ' rows' end,
            function(_self, val) return str(val) .. ' columns' end,
            {
                [0] = '[unused]',
                [1] = 'Start at top right',
                [2] = 'Start at top left',
                [3] = 'Start at bottom left',
                [4] = 'Start at bottom right',
            },
            {
                [0x01] = 'Left to right',
                [0x02] = 'Right to left',
                [0x03] = 'Top to bottom',
                [0x04] = 'Bottom to top',
                [0x10] = 'Clockwise',
                [0x20] = 'Counter clockwise',
                [0x30] = 'Zigzag (row start)',
                [0x40] = 'Zigzag (column start)',
            },
        },
    },
    [0xb202] = 'PanOverlapH',
    [0xb203] = 'PanOverlapV',
    [0xb204] = 'BaseViewpointNum',
    [0xb205] = 'ConvergenceAngle',
    [0xb206] = 'BaselineLength',
    [0xb207] = 'VerticalDivergence',
    [0xb208] = 'AxisDistanceX',
    [0xb209] = 'AxisDistanceY',
    [0xb20a] = 'AxisDistanceZ',
    [0xb20b] = 'YawAngle',
    [0xb20c] = 'PitchAngle',
    [0xb20d] = 'RollAngle',
}

-- Tags found in MPImage structure
MPF.MPImage = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MPF', [1] = 'MPImage', [2] = 'Image' },
    NOTES = [[
        The first MPF "Large Thumbnail" image is extracted as PreviewImage, and the
        rest of the embedded MPF images are extracted as MPImage#.  The
        L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option may be used to extract information from these
        embedded images.
    ]],
    ['0.1'] = {
        Name = 'MPImageFlags',
        Format = 'int32u',
        Mask = 0xf8000000,
        PrintConv = { BITMASK = {
            [2] = 'Representative image',
            [3] = 'Dependent child image',
            [4] = 'Dependent parent image',
        } },
    },
    ['0.2'] = {
        Name = 'MPImageFormat',
        Format = 'int32u',
        Mask = 0x07000000,
        PrintConv = {
            [0] = 'JPEG',
        },
    },
    ['0.3'] = {
        Name = 'MPImageType',
        Format = 'int32u',
        Mask = 0x00ffffff,
        PrintHex = 1,
        PrintConv = {
            [0x000000] = 'Undefined',
            [0x010001] = 'Large Thumbnail (VGA equivalent)',
            [0x010002] = 'Large Thumbnail (full HD equivalent)',
            [0x010003] = 'Large Thumbnail (4K equivalent)',
            [0x010004] = 'Large Thumbnail (8K equivalent)',
            [0x010005] = 'Large Thumbnail (16K equivalent)',
            [0x020001] = 'Multi-frame Panorama',
            [0x020002] = 'Multi-frame Disparity',
            [0x020003] = 'Multi-angle',
            [0x030000] = 'Baseline MP Primary Image',
            [0x040000] = 'Original Preservation Image', -- (Exif 3.0)
            [0x050000] = 'Gain Map Image',
        },
    },
    [4] = {
        Name = 'MPImageLength',
        Format = 'int32u',
    },
    [8] = {
        Name = 'MPImageStart',
        Format = 'int32u',
        IsOffset = '$val',
    },
    [12] = {
        Name = 'DependentImage1EntryNumber',
        Format = 'int16u',
    },
    [14] = {
        Name = 'DependentImage2EntryNumber',
        Format = 'int16u',
    },
}

-- extract MP Images as composite tags
MPF.Composite = {
    GROUPS = { [2] = 'Preview' },
    MPImage = {
        TagID = 'MPF-MPImage',
        Require = {
            [0] = 'MPImageStart',
            [1] = 'MPImageLength',
            [2] = 'MPImageType',
        },
        Notes = [[
            the first MPF "Large Thumbnail" is extracted as PreviewImage, and the rest
            of the embedded MPF images are extracted as MPImage#.  The L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded>
            option may be used to extract information from these embedded images.
        ]],
        -- extract all MPF images (not just one); upstream runs this in
        -- RawConv (its return value IS the composite's raw value; a nil
        -- result leaves no trace at all)
        RawConv = function(self, _vals)
            return MPF.ExtractMPImages(self)
        end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.MPF', nil, MPF)

return MPF
