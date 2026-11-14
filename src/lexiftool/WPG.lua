--------------------------------------------------------------------------------
-- File:         lexiftool/WPG.lua
-- Ported from:  lib/Image/ExifTool/WPG.pm
--
-- Description:  Read WordPerfect Graphics meta information
--
-- Revisions:    2023-05-01 - P. Harvey Created
--
-- References:   1) https://www.fileformat.info/format/wpg/egff.htm
--               2) https://archive.org/details/mac_Graphics_File_Formats_Second_Edition_1996/page/n991/mode/2up
--               3) http://libwpg.sourceforge.net/
--
-- Port notes:   complete (read-only module).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf, split, hget, ord, unpack = perl.sprintf, perl.split, perl.hget, perl.ord, perl.unpack
local isMatch, perlTruthy = perl.isMatch, perl.truthy
local GetTagTable, SetByteOrder, Get32u, ReadValue = ExifTool.GetTagTable, ExifTool.SetByteOrder, ExifTool.Get32u, ExifTool.ReadValue

local WPG = {}

--------------------------------------------------------------------------------
-- Print record type
-- Inputs: 0) record type and count, 1) inverse flag, 2) PrintConv hash ref
-- Returns: converted record name
local function PrintRecord(val, _inv, printConv)
    local type_, count = table.unpack(split('x', val))
    local prt = hget(printConv, type_)
    if not perlTruthy(prt) then prt = sprintf('Unknown (0x%.2x)', type_) end
    if perlTruthy(count) then prt = prt .. ' x ' .. count end
    return prt
end

-- WPG metadata
WPG.Main = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Tags extracted from WordPerfect Graphics (WPG) images.',
    WPGVersion = {},
    ImageWidthInches = { PrintConv = function(_self, val) return sprintf('%.2f', val) end },
    ImageHeightInches = { PrintConv = function(_self, val) return sprintf('%.2f', val) end },
    Records = {
        Notes = 'records for version 1.0 files',
        List = 1,
        PrintHex = 2,
        PrintConvColumns = 2,
        PrintConv = {
            OTHER = PrintRecord,
            [0x01] = 'Fill Attributes',
            [0x02] = 'Line Attributes',
            [0x03] = 'Marker Attributes',
            [0x04] = 'Polymarker',
            [0x05] = 'Line',
            [0x06] = 'Polyline',
            [0x07] = 'Rectangle',
            [0x08] = 'Polygon',
            [0x09] = 'Ellipse',
            [0x0a] = 'Reserved',
            [0x0b] = 'Bitmap (Type 1)',
            [0x0c] = 'Graphics Text (Type 1)',
            [0x0d] = 'Graphics Text Attributes',
            [0x0e] = 'Color Map',
            [0x0f] = 'Start WPG (Type 1)',
            [0x10] = 'End WPG',
            [0x11] = 'PostScript Data (Type 1)',
            [0x12] = 'Output Attributes',
            [0x13] = 'Curved Polyline',
            [0x14] = 'Bitmap (Type 2)',
            [0x15] = 'Start Figure',
            [0x16] = 'Start Chart',
            [0x17] = 'PlanPerfect Data',
            [0x18] = 'Graphics Text (Type 2)',
            [0x19] = 'Start WPG (Type 2)',
            [0x1a] = 'Graphics Text (Type 3)',
            [0x1b] = 'PostScript Data (Type 2)',
        },
    },
    RecordsV2 = {
        Notes = 'records for version 2.0 files',
        List = 1,
        PrintHex = 2,
        PrintConvColumns = 2,
        PrintConv = {
            OTHER = PrintRecord,
            [0x00] = 'End Marker',
            [0x01] = 'Start WPG',
            [0x02] = 'End WPG',
            [0x03] = 'Form Settings',
            [0x04] = 'Ruler Settings',
            [0x05] = 'Grid Settings',
            [0x06] = 'Layer',
            [0x08] = 'Pen Style Definition',
            [0x09] = 'Pattern Definition',
            [0x0a] = 'Comment',
            [0x0b] = 'Color Transfer',
            [0x0c] = 'Color Palette',
            [0x0d] = 'DP Color Palette',
            [0x0e] = 'Bitmap Data',
            [0x0f] = 'Text Data',
            [0x10] = 'Chart Style',
            [0x11] = 'Chart Data',
            [0x12] = 'Object Image',
            [0x15] = 'Polyline',
            [0x16] = 'Polyspline',
            [0x17] = 'Polycurve',
            [0x18] = 'Rectangle',
            [0x19] = 'Arc',
            [0x1a] = 'Compound Polygon',
            [0x1b] = 'Bitmap',
            [0x1c] = 'Text Line',
            [0x1d] = 'Text Block',
            [0x1e] = 'Text Path',
            [0x1f] = 'Chart',
            [0x20] = 'Group',
            [0x21] = 'Object Capsule',
            [0x22] = 'Font Settings',
            [0x25] = 'Pen Fore Color',
            [0x26] = 'DP Pen Fore Color',
            [0x27] = 'Pen Back Color',
            [0x28] = 'DP Pen Back Color',
            [0x29] = 'Pen Style',
            [0x2a] = 'Pen Pattern',
            [0x2b] = 'Pen Size',
            [0x2c] = 'DP Pen Size',
            [0x2d] = 'Line Cap',
            [0x2e] = 'Line Join',
            [0x2f] = 'Brush Gradient',
            [0x30] = 'DP Brush Gradient',
            [0x31] = 'Brush Fore Color',
            [0x32] = 'DP Brush Fore Color',
            [0x33] = 'Brush Back Color',
            [0x34] = 'DP Brush Back Color',
            [0x35] = 'Brush Pattern',
            [0x36] = 'Horizontal Line',
            [0x37] = 'Vertical Line',
            [0x38] = 'Poster Settings',
            [0x39] = 'Image State',
            [0x3a] = 'Envelope Definition',
            [0x3b] = 'Envelope',
            [0x3c] = 'Texture Definition',
            [0x3d] = 'Brush Texture',
            [0x3e] = 'Texture Alignment',
            [0x3f] = 'Pen Texture ',
        },
    },
}

--------------------------------------------------------------------------------
-- Read variable-length integer
-- Inputs: 0) RAF ref
-- Returns: integer value
local function ReadVarInt(raf)
    local n, buff
    n, buff = raf:Read(1)
    if not perlTruthy(n) then return 0 end
    local val = ord(buff)
    if val == 0xff then
        n, buff = raf:Read(2)
        if n ~= 2 then return 0 end
        val = unpack('v', buff)
        if (val & 0x8000) ~= 0 then
            n, buff = raf:Read(2)
            if n ~= 2 then return 0 end
            val = ((val & 0x7fff) << 16) | unpack('v', buff)
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Read WPG version 1 or 2 image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid WPG file
function WPG.ProcessWPG(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, lastType, count
    local n

    -- verify this is a valid WPG file
    n, buff = raf:Read(16)
    if n ~= 16 then return 0 end
    if not isMatch(buff, [[^\xff\x57\x50\x43]]) then return 0 end
    et:SetFileType()
    SetByteOrder('II')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.WPG.Main')
    local offset = Get32u(buff, 4)
    local ver, rev = unpack('x10CC', buff)
    et:HandleTag(tagTablePtr, 'WPGVersion', ver .. '.' .. rev)
    if ver < 1 or ver > 2 then
        -- currently support only version 1 and 2 formats
        et:Warn('Unsupported WPG version')
        return 1
    end
    local tag = ver == 1 and 'Records' or 'RecordsV2'
    if offset > 16 then
        if not perlTruthy(raf:Seek(offset - 16, 1)) then return 1 end
    end
    -- loop through records
    while true do
        local type_, len, getSize
        n, buff = raf:Read(ver)
        if n == ver then  -- read 1 or 2 bytes, based on version
            if ver == 1 then
                -- read version 1 record header
                type_ = ord(buff)
                len = ReadVarInt(raf)
                if type_ == 0x0f then getSize = 1 end  -- Start WPG (Type 1)
            else
                -- read version 2 record header
                type_ = unpack('xC', buff)
                ReadVarInt(raf)   -- skip extensions
                len = ReadVarInt(raf)
                if type_ == 0x01 then getSize = 1 end  -- Start WPG
                if type_ > 0x3f then type_ = nil end
            end
            if getSize then
                -- read Start record to obtain image size
                n, buff = raf:Read(len)
                if n ~= len then et:Warn('File format error') break end
                local w, h, xres, yres, err
                if ver == 1 then
                    if len < 6 then
                        err = ''
                    else
                        w, h = unpack('x2vv', buff)
                    end
                else
                    local precision, format
                    xres, yres, precision = unpack('vvC', buff)
                    if precision == 0 and len >= 21 then
                        if len < 13+2*4 then err = '' end
                        format = 'int16s'
                    elseif precision == 1 and len >= 29 then
                        if len < 13+4*4 then err = '' end
                        format = 'int32s'
                    else
                        err = 'Invalid integer precision'
                    end
                    if err == nil then
                        local x1,y1,x2,y2 = table.unpack(ReadValue(buff, 13, format, 4, len-13, nil, true))
                        w = math.abs(x2 - x1)
                        h = math.abs(y2 - y1)
                    end
                end
                if err ~= nil then
                    et:Warn(perlTruthy(err) and err or 'Truncated start record')
                else
                    et:HandleTag(tagTablePtr, 'ImageWidthInches', w / (perlTruthy(xres) and xres or 1200))
                    et:HandleTag(tagTablePtr, 'ImageHeightInches', h / (perlTruthy(yres) and yres or 1200))
                end
            else
                -- skip to the next record
                if not perlTruthy(raf:Seek(len, 1)) then et:Warn('Truncated record') break end
            end
        end
        -- go to some trouble to collapse identical sequential entries in record list
        -- (trying to keep the length of the list managable for complex images)
        if perlTruthy(lastType) and perlTruthy(type_) and type_ == lastType then count = count + 1 goto next end
        if perlTruthy(lastType) then
            local val = count > 1 and lastType .. 'x' .. count or lastType
            et:HandleTag(tagTablePtr, tag, val)
        end
        if not perlTruthy(type_) then break end
        lastType = type_
        count = 1
        ::next::
    end
    return 1
end

return WPG
