--------------------------------------------------------------------------------
-- File:         lexiftool/ITC.lua
-- Ported from:  lib/Image/ExifTool/ITC.pm
--
-- Description:  Read iTunes Cover Flow meta information
--
-- Revisions:    01/12/2008 - P. Harvey Created
--
-- References:   1) http://www.waldoland.com/dev/Articles/ITCFileFormat.aspx
--               2) http://www.falsecognate.org/2007/01/deciphering_the_itunes_itc_fil/
--
-- Port notes:   read port: the Main/Header/Item tables plus ProcessITC.
--               Upstream ITC.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local uc = perl.uc

local ITC = {}

-- tags used in ITC files
ITC.Main = {
    NOTES = 'This information is found in iTunes Cover Flow data files.',
    itch = { SubDirectory = { TagTable = 'lexiftool.ITC.Header' } },
    item = { SubDirectory = { TagTable = 'lexiftool.ITC.Item' } },
    data = {
        Name = 'ImageData',
        Notes = 'embedded JPEG or PNG image, depending on ImageType',
    },
}

-- ITC header information
ITC.Header = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0x10] = {
        Name = 'DataType',
        Format = 'undef[4]',
        PrintConv = { artw = 'Artwork' },
    },
}

-- ITC item information
ITC.Item = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'LibraryID',
        Format = 'undef[8]',
        ValueConv = function(_self, val) return uc(perl.unpack('H*', val)) end,
    },
    [2] = {
        Name = 'TrackID',
        Format = 'undef[8]',
        ValueConv = function(_self, val) return uc(perl.unpack('H*', val)) end,
    },
    [4] = {
        Name = 'DataLocation',
        Format = 'undef[4]',
        PrintConv = {
            down = 'Downloaded Separately',
            locl = 'Local Music File',
        },
    },
    [5] = {
        Name = 'ImageType',
        Format = 'undef[4]',
        -- (not PrintConv because the unconverted JPEG value is nasty)
        ValueConv = {
            ['PNGf'] = 'PNG',
            ['\0\0\0\x0d'] = 'JPEG',
        },
    },
    [7] = 'ImageWidth',
    [8] = 'ImageHeight',
}

--------------------------------------------------------------------------------
-- Process an iTunes Cover Flow (ITC) file
-- Inputs: 0) ExifTool object reference, 1) Directory information reference
-- Returns: 1 on success, 0 if this wasn't a valid ITC file
--------------------------------------------------------------------------------
function ITC.ProcessITC(et, dirInfo)
    local raf = dirInfo.RAF
    local rtnVal = 0
    local err

    -- loop through all blocks in this image
    while true do
        -- read the block header
        local n, buff = raf:Read(8)
        if n ~= 8 then
            -- no error if we reached the EOF normally
            if n == 0 then err = nil end
            break
        end
        local size = ExifTool.Get32u(buff, 0)
        local tag = buff:sub(5, 8)
        if rtnVal ~= 0 then
            if not (size >= 8 and size < 0x80000000) then break end
        else
            -- check to be sure this is a valid ITC image
            -- (first block must be 'itch')
            if tag ~= 'itch' then break end
            if not (size >= 0x1c and size < 0x10000) then break end
            et:SetFileType()
            ExifTool.SetByteOrder('MM')
            rtnVal = 1 -- this is an ITC file
            err = 1 -- format error unless we read to EOF
        end
        if tag == 'itch' then
            local pos = raf:Tell()
            size = size - 8 -- size of remaining data in block
            local n2, hbuf = raf:Read(size)
            if n2 ~= size then break end
            -- extract header information
            local subdirInfo = { DirName = 'ITC Header', DataPt = hbuf, DataPos = pos }
            local tagTablePtr = et:GetTagTable('lexiftool.ITC.Header')
            et:ProcessDirectory(subdirInfo, tagTablePtr)
        elseif tag == 'item' then
            -- don't want to read the entire item data (includes image)
            if size <= 12 then break end
            local n3, lbuf = raf:Read(4)
            if n3 ~= 4 then break end
            local len = ExifTool.Get32u(lbuf, 0)
            if not (len >= 0xd0 and len <= size) then break end
            size = size - len -- size of data after item header
            len = len - 12 -- length of remaining item header
            -- read in 4-byte blocks until we find the null terminator
            -- (this is just a guess about how to parse this variable-length part)
            while len >= 4 do
                local n4, ibuf = raf:Read(4)
                if n4 ~= 4 then break end
                len = len - 4
                if ibuf == '\0\0\0\0' then break end
            end
            if len < 4 then break end
            local pos = raf:Tell()
            local n5, ibuf2 = raf:Read(len)
            if n5 ~= len then break end
            if not (len >= 0xb4 and ibuf2:sub(0xb1, 0xb4) == 'data') then
                et:Warn('Parsing error. Please submit this ITC file for testing')
                break
            end
            local subdirInfo = { DirName = 'ITC Item', DataPt = ibuf2, DataPos = pos }
            local tagTablePtr = et:GetTagTable('lexiftool.ITC.Item')
            et:ProcessDirectory(subdirInfo, tagTablePtr)
            -- extract embedded image
            pos = pos + len
            if size > 0 then
                local mainTable = et:GetTagTable('lexiftool.ITC.Main')
                local tagInfo = et:GetTagInfo(mainTable, 'data')
                local image = et.ExtractBinary(et, pos, size, tagInfo.Name)
                et:FoundTag(tagInfo, { ref = 'SCALAR', value = image })
                -- skip the rest of the block if necessary
                if not raf:Seek(pos + size, 0) then break end
            elseif size < 0 then
                break
            end
        else
            et:VPrint(0, 'Unknown ' .. tag .. ' block (' .. size .. ' bytes)\n')
            if not raf:Seek(size - 8, 1) then break end
        end
    end
    if err then et:Warn('ITC file format error') end
    return rtnVal
end

return ITC
