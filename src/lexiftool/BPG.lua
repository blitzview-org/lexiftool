--------------------------------------------------------------------------------
-- File:         lexiftool/BPG.lua
-- Ported from:  lib/Image/ExifTool/BPG.pm
--
-- Description:  Read BPG meta information
--
-- Revisions:    2016-07-05 - P. Harvey Created
--
-- References:   1) http://bellard.org/bpg/
--
-- Port notes:   read port: the Main and Extensions tables plus Get_ue7 and
--               ProcessBPG. Upstream BPG.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local matches = require('lexiftool.perl').matches
local num = require('lexiftool.perl').num

local BPG = {}

-- BPG information
BPG.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = [[
        The information listed below is extracted from BPG (Better Portable
        Graphics) images.  See L<http://bellard.org/bpg/> for the specification.
    ]],
    [4] = {
        Name = 'PixelFormat',
        Format = 'int16u',
        Mask = 0xe000,
        PrintConv = {
            [0] = 'Grayscale',
            [1] = '4:2:0 (chroma at 0.5, 0.5)',
            [2] = '4:2:2 (chroma at 0.5, 0)',
            [3] = '4:4:4',
            [4] = '4:2:0 (chroma at 0, 0.5)',
            [5] = '4:2:2 (chroma at 0, 0)',
        },
    },
    [4.1] = {
        Name = 'Alpha',
        Format = 'int16u',
        Mask = 0x1004,
        BitShift = 0,
        PrintHex = 1,
        PrintConv = {
            [0x0000] = 'No Alpha Plane',
            [0x1000] = 'Alpha Exists (color not premultiplied)',
            [0x1004] = 'Alpha Exists (color premultiplied)',
            [0x0004] = 'Alpha Exists (W color component)',
        },
    },
    [4.2] = {
        Name = 'BitDepth',
        Format = 'int16u',
        Mask = 0x0f00,
        ValueConv = function(_self, val) return val + 8 end,
    },
    [4.3] = {
        Name = 'ColorSpace',
        Format = 'int16u',
        Mask = 0x00f0,
        PrintConv = {
            [0] = 'YCbCr (BT 601)',
            [1] = 'RGB',
            [2] = 'YCgCo',
            [3] = 'YCbCr (BT 709)',
            [4] = 'YCbCr (BT 2020)',
            [5] = 'BT 2020 Constant Luminance',
        },
    },
    [4.4] = {
        Name = 'Flags',
        Format = 'int16u',
        Mask = 0x000b,
        PrintConv = { BITMASK = {
            [0] = 'Animation',
            [1] = 'Limited Range',
            [3] = 'Extension Present',
        } },
    },
    [6] = { Name = 'ImageWidth', Format = 'var_ue7' },
    [7] = { Name = 'ImageHeight', Format = 'var_ue7' },
    -- length of image data or 0 to EOF
    -- (must be decoded so we know where the extension data starts)
    [8] = { Name = 'ImageLength', Format = 'var_ue7' },
}

BPG.Extensions = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    VARS = { ALPHA_FIRST = 1 },
    [1] = {
        Name = 'EXIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
        },
    },
    [2] = {
        Name = 'ICC_Profile',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    [3] = {
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    [4] = {
        Name = 'ThumbnailBPG',
        Binary = 1,
    },
    [5] = {
        Name = 'AnimationControl',
        Binary = 1,
        Unknown = 1,
    },
}

--------------------------------------------------------------------------------
-- Get ue7 integer from binary data (max 32 bits)
-- Inputs: 0) data string, 1) 0-based position in data (0 if omitted)
-- Returns: 0) ue7 as integer or nil on error, 1) length of ue7 in bytes
--------------------------------------------------------------------------------
function BPG.Get_ue7(dataPt, pos)
    pos = pos or 0
    local size = #dataPt
    local val = 0
    local i = 0
    while true do
        if pos + i >= size or i >= 5 then return nil end
        local byte = dataPt:byte(pos + i + 1)
        val = (val << 7) | (byte & 0x7f)
        if byte & 0x80 == 0 then
            if i == 4 and byte & 0x70 ~= 0 then return nil end -- error if bits 32-34 are set
            break -- this was the last byte
        end
        if i == 0 and byte == 0x80 then return nil end -- error if first byte is 0x80
        i = i + 1 -- step to the next byte
    end
    return val, i + 1
end

--------------------------------------------------------------------------------
-- Extract EXIF information from a BPG image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid BPG file
--------------------------------------------------------------------------------
function BPG.ProcessBPG(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(21) -- (21 bytes is maximum header length)
    if n ~= 21 then return 0 end
    if buff:sub(1, 4) ~= 'BPG\251' then return 0 end
    et:SetFileType() -- set the FileType tag

    ExifTool.SetByteOrder('MM')
    local mainDirInfo = {
        DataPt = buff,
        DirStart = 0,
        DirLen = #buff,
        VarFormatData = {},
    }
    et:ProcessDirectory(mainDirInfo, et:GetTagTable('lexiftool.BPG.Main'))

    if num(et.VALUE.Flags) & 0x0008 == 0 then return 1 end -- all done unless extension flag is set

    -- add varSize from last entry in VarFormatData to determine
    -- the current read position in the file
    local lastVar = mainDirInfo.VarFormatData[#mainDirInfo.VarFormatData]
    local dataPos = 9 + (lastVar and lastVar[2] or 0)
    -- read extension length
    local n5
    if not raf:Seek(dataPos, 0) then
        et:Warn('Missing BPG extension data')
        return 1
    end
    n5, buff = raf:Read(5)
    if n5 ~= 5 then
        et:Warn('Missing BPG extension data')
        return 1
    end
    local size, n6 = BPG.Get_ue7(buff)
    if size == nil then
        et:Warn('Corrupted BPG extension length')
        return 1
    end
    dataPos = dataPos + n6
    if size > 10000000 then
        et:Warn('BPG extension is too large')
        return 1
    end
    local nSize
    if not raf:Seek(dataPos, 0) then
        et:Warn('Truncated BPG extension')
        return 1
    end
    nSize, buff = raf:Read(size)
    if nSize ~= size then
        et:Warn('Truncated BPG extension')
        return 1
    end
    local tagTablePtr = et:GetTagTable('lexiftool.BPG.Extensions')
    -- loop through the individual extensions
    local pos = 0
    while pos < size do
        local extType = ExifTool.Get8u(buff, pos)
        pos = pos + 1
        local len, n7 = BPG.Get_ue7(buff, pos)
        if len == nil then
            et:Warn('Corrupted BPG extension')
            break
        end
        pos = pos + n7 -- point to start of data for this extension
        if pos + len > size then
            et:Warn('Invalid BPG extension size')
            break
        end
        if not tagTablePtr[extType] then
            et:Warn('Unrecognized BPG extension ' .. extType .. ' (' .. len .. ' bytes)', 1)
        else
            -- libbpg (in my opinion) incorrectly copies the padding byte after the
            -- "EXIF\0" APP1 header to the start of the BPG EXIF extension, so issue a
            -- minor warning and ignore the padding if we find it before the TIFF header
            if extType == 1 and len > 3 and matches(buff:sub(pos + 1, pos + 3), '(?s)^.(II|MM)') then
                et:Warn('Ignored extra byte at start of EXIF extension', 1)
                pos = pos + 1
                len = len - 1
            end
            et:HandleTag(tagTablePtr, extType, nil, {
                DataPt = buff,
                DataPos = dataPos,
                Start = pos,
                Size = len,
                Parent = 'BPG',
            })
        end
        pos = pos + len
    end
    return 1
end

return BPG
