--------------------------------------------------------------------------------
-- File:         lexiftool/PSP.lua
-- Ported from:  lib/Image/ExifTool/PSP.pm
--
-- Description:  Read Paint Shop Pro meta information
--
-- Revisions:    2010/01/23 - P. Harvey Created
--
-- References:   1) http://www.jasc.com/support/kb/articles/pspspec.asp
--
-- Port notes:   complete: ProcessPSP (the main-block reader),
--               ProcessExtData (the extended sub-block reader with the
--               EXIFInfo special-case offset handling), and the Main/
--               Image/Creator/Ext tables. The composite image bank preview
--               entry (18) is commented out upstream as well.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local str = require('lexiftool.perl').str

local PSP = {}

-- PSP info (upstream %Image::ExifTool::PSP::Main)
PSP.Main = {
    GROUPS = { [2] = 'Image' },
    VARS = { ALPHA_FIRST = 1 },
    NOTES = [[
        Tags extracted from Paint Shop Pro images (PSP, PSPIMAGE, PSPFRAME,
        PSPSHAPE, PSPTUBE and TUB extensions).
    ]],
    FileVersion = {
        PrintConv = function(_self, val) return (val:gsub(' ', '.')) end,
    },
    [0] = {
        {
            Condition = function(self) return (self.PSPFileVersion or 0) > 3 end,
            Name = 'ImageInfo',
            SubDirectory = {
                TagTable = 'lexiftool.PSP.Image',
                Start = 4,
            },
        },
        {
            Name = 'ImageInfo',
            SubDirectory = {
                TagTable = 'lexiftool.PSP.Image',
            },
        },
    },
    [1] = {
        Name = 'CreatorInfo',
        SubDirectory = { TagTable = 'lexiftool.PSP.Creator' },
    },
    [10] = {
        Name = 'ExtendedInfo',
        SubDirectory = { TagTable = 'lexiftool.PSP.Ext' },
    },
    -- this is inside the composite image bank block (16), which I don't want to parse...
    --[18] = {
    --    Name = 'PreviewImage',
    --    Groups = { [2] = 'Preview' },
    --    RawConv = '$self->ValidateImage(\$val,$tag)',
    --},
}

-- the PSP image block (upstream %PSP::Image)
PSP.Image = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = { Name = 'ImageWidth', Format = 'int32u' },
    [4] = { Name = 'ImageHeight', Format = 'int32u' },
    [8] = { Name = 'ImageResolution', Format = 'double' },
    [16] = {
        Name = 'ResolutionUnit',
        Format = 'int8u',
        PrintConv = {
            [0] = 'None',
            [1] = 'inches',
            [2] = 'cm',
        },
    },
    [17] = {
        Name = 'Compression',
        Format = 'int16u',
        PrintConv = {
            [0] = 'None',
            [1] = 'RLE',
            [2] = 'LZ77',
            [3] = 'JPEG',
        },
    },
    [19] = { Name = 'BitsPerSample', Format = 'int16u' },
    [21] = { Name = 'Planes', Format = 'int16u' },
    [23] = { Name = 'NumColors', Format = 'int32u' },
}

-- the PSP creator data block (upstream %PSP::Creator)
PSP.Creator = {
    PROCESS_PROC = false, -- set below to PSP.ProcessExtData
    GROUPS = { [2] = 'Image' },
    PRIORITY = 0, -- prefer EXIF if it exists
    [0] = 'Title',
    [1] = {
        Name = 'CreateDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [2] = {
        Name = 'ModifyDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, 1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [3] = { Name = 'Artist', Groups = { [2] = 'Author' } },
    [4] = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    [5] = 'Description',
    [6] = {
        Name = 'CreatorAppID',
        Format = 'int32u',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Paint Shop Pro',
        },
    },
    [7] = {
        Name = 'CreatorAppVersion',
        Format = 'int8u',
        Count = 4,
        ValueConv = function(_self, val)
            -- (upstream `join(" ",reverse split " ", $val)` -- low byte first)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = w end
            local rev = {}
            for i = #a, 1, -1 do rev[#rev + 1] = a[i] end
            return table.concat(rev, ' ')
        end,
        PrintConv = function(_self, val) return (val:gsub(' ', '.')) end,
    },
}

-- the PSP extended data block (upstream %PSP::Ext)
PSP.Ext = {
    PROCESS_PROC = false, -- set below to PSP.ProcessExtData
    GROUPS = { [2] = 'Image' },
    [3] = {
        Name = 'EXIFInfo', -- (don't change this name, it is used in the code)
        SubDirectory = { TagTable = 'lexiftool.Exif.Main' },
    },
}

--------------------------------------------------------------------------------
-- Extract information from the extended data block (upstream ProcessExtData)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function PSP.ProcessExtData(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirLen = dirInfo.DirLen
    local pos = 0
    -- loop through sub-blocks
    while pos + 10 < dirLen do
        if substr(dataPt, pos, 4) ~= '~FL\0' then
            et:Warn('Lost synchronization while reading sub blocks')
            break
        end
        local tag = ExifTool.Get16u(dataPt, pos + 4)
        local len = ExifTool.Get32u(dataPt, pos + 6)
        pos = pos + 10 + len
        if pos > dirLen then
            et:Warn('Truncated sub block ID=' .. tag .. ' len=' .. len)
            break
        end
        if tagTablePtr[tag] then
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if tagInfo then
                local start = pos - len
                if tagInfo.Name ~= 'EXIFInfo' then
                    et:HandleTag(tagTablePtr, tag, nil, {
                        TagInfo = tagInfo,
                        DataPt = dataPt,
                        DataPos = dirInfo.DataPos,
                        DataLen = #dataPt,
                        Start = start,
                        Size = len,
                    })
                elseif len > 14 and substr(dataPt, pos - len, 6) == 'Exif\0\0' then
                    -- validate EXIF block header and set byte order
                    if ExifTool.SetByteOrder(substr(dataPt, start + 6, 2)) then
                        -- This is REALLY annoying...  They use a standard TIFF offset
                        -- to point to the first IFD, but after that the offsets are
                        -- relative to the start of the IFD instead of the TIFF base,
                        -- which means that I must handle it as a special case.  Dumb,
                        -- dumb...
                        local exifStart = start + 14
                        local dirInfo2 = {
                            DirName = 'IFD0', -- (upstream rewrites EXIF->IFD0 internally)
                            Parent = 'PSP',
                            DataPt = dataPt,
                            DataPos = -exifStart, -- data position relative to Base
                            DataLen = #dataPt,
                            DirStart = exifStart,
                            Base = exifStart + dirInfo.DataPos, -- absolute base offset
                            Multi = 0,
                        }
                        local exifTable = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                        require('lexiftool.Exif').ProcessExif(et, dirInfo2, exifTable)
                        ExifTool.SetByteOrder('II')
                    end
                end
            end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a PSP file (upstream ProcessPSP)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid PSP file
--------------------------------------------------------------------------------
function PSP.ProcessPSP(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(32)
    if n ~= 32 or buff ~= 'Paint Shop Pro Image File\10\26\0\0\0\0\0' then return 0 end
    local n2, ver = raf:Read(4)
    if n2 ~= 4 then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('II')
    local tagTablePtr = et:GetTagTable('lexiftool.PSP.Main')
    local a = {}
    for w in ver:gmatch('.') do a[#a + 1] = str(w:byte()) end
    -- (upstream `unpack('v*', $buff)` gives little-endian words; PSP version
    --  words are written low-byte-first)
    local a1 = a[1] + a[2] * 256
    local a2 = a[3] + a[4] * 256
    -- figure out block header length for this format PSP file
    local hlen = a1 > 3 and 10 or 14
    et.PSPFileVersion = a1 -- save for use in Condition
    et:HandleTag(tagTablePtr, 'FileVersion', a1 .. ' ' .. a2)
    -- loop through blocks in file
    local pos = 36
    local err
    local tag, len
    while true do
        local n3, hdr = raf:Read(hlen)
        if n3 ~= hlen then break end
        if hdr:sub(1, 4) ~= '~BK\0' then
            et:Warn('Lost synchronization while reading main PSP blocks')
            break
        end
        tag = ExifTool.Get16u(hdr, 4)
        len = ExifTool.Get32u(hdr, hlen - 4)
        pos = pos + hlen + len
        if tagTablePtr[tag] then
            local n4, dbuf = raf:Read(len)
            if n4 ~= len then err = 1 break end
            et:HandleTag(tagTablePtr, tag, dbuf, {
                DataPt = dbuf,
                DataPos = pos - len,
                Size = len,
            })
        elseif not raf:Seek(len, 1) then
            err = 1
            break
        end
    end
    if err then et:Warn('Truncated main block ID=' .. tag .. ' len=' .. len) end
    return 1
end

-- (PROCESS_PROC set here so the tables can reference ProcessExtData)
PSP.Creator.PROCESS_PROC = PSP.ProcessExtData
PSP.Ext.PROCESS_PROC = PSP.ProcessExtData

return PSP