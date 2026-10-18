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
-- Port notes:   read port: the Main table plus PrintRecord, ReadVarInt and
--               ProcessWPG. Upstream WPG.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf
local str = require('lexiftool.perl').str

local WPG = {}

--------------------------------------------------------------------------------
-- Print record type (upstream PrintRecord; used as the `OTHER` PrintConv
-- fallback for collapsed "TYPExCOUNT" list entries)
--------------------------------------------------------------------------------
local function PrintRecord(val, _inv, printConv)
    local typeStr, countStr = str(val):match('^(%d+)x(%d+)$')
    local typeNum = tonumber(typeStr) or tonumber(val)
    local prt = printConv[typeNum] or sprintf('Unknown (0x%.2x)', typeNum)
    if countStr then prt = prt .. ' x ' .. countStr end
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
--------------------------------------------------------------------------------
local function ReadVarInt(raf)
    local n, buff = raf:Read(1)
    if n ~= 1 then return 0 end
    local val = buff:byte(1)
    if val == 0xff then
        local n2, b2 = raf:Read(2)
        if n2 ~= 2 then return 0 end
        val = ExifTool.Get16u(b2, 0)
        if val & 0x8000 ~= 0 then
            local n3, b3 = raf:Read(2)
            if n3 ~= 2 then return 0 end
            val = ((val & 0x7fff) << 16) | ExifTool.Get16u(b3, 0)
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Read WPG version 1 or 2 image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid WPG file
--------------------------------------------------------------------------------
function WPG.ProcessWPG(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(16)
    if n ~= 16 then return 0 end
    -- verify this is a valid WPG file
    if not (buff:byte(1) == 0xff and buff:sub(2, 4) == 'WPC') then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('II')
    local tagTablePtr = et:GetTagTable('lexiftool.WPG.Main')
    local offset = ExifTool.Get32u(buff, 4)
    local ver, rev = buff:byte(11), buff:byte(12)
    et:HandleTag(tagTablePtr, 'WPGVersion', ver .. '.' .. rev)
    if ver < 1 or ver > 2 then
        -- currently support only version 1 and 2 formats
        et:Warn('Unsupported WPG version')
        return 1
    end
    local tag = ver == 1 and 'Records' or 'RecordsV2'
    if offset > 16 then
        if not raf:Seek(offset - 16, 1) then return 1 end
    end
    -- loop through records
    local lastType, count
    while true do
        local recType, len, getSize
        local n2, hbuf = raf:Read(ver) -- read 1 or 2 bytes, based on version
        if n2 == ver then
            if ver == 1 then
                -- read version 1 record header
                recType = hbuf:byte(1)
                len = ReadVarInt(raf)
                if recType == 0x0f then getSize = true end -- Start WPG (Type 1)
            else
                -- read version 2 record header
                recType = hbuf:byte(2)
                ReadVarInt(raf) -- skip extensions
                len = ReadVarInt(raf)
                if recType == 0x01 then getSize = true end -- Start WPG
                if recType > 0x3f then recType = nil end
            end
            if getSize then
                -- read Start record to obtain image size
                local n3, sbuf = raf:Read(len)
                if n3 ~= len then
                    et:Warn('File format error')
                    break
                end
                local w, h, xres, yres, err
                if ver == 1 then
                    if len < 6 then
                        err = ''
                    else
                        w = ExifTool.Get16u(sbuf, 2)
                        h = ExifTool.Get16u(sbuf, 4)
                    end
                else
                    xres = ExifTool.Get16u(sbuf, 0)
                    yres = ExifTool.Get16u(sbuf, 2)
                    local precision = sbuf:byte(5)
                    local format
                    if precision == 0 and len >= 21 then
                        if len < 13 + 2 * 4 then err = '' end
                        format = 'int16s'
                    elseif precision == 1 and len >= 29 then
                        if len < 13 + 4 * 4 then err = '' end
                        format = 'int32s'
                    else
                        err = 'Invalid integer precision'
                    end
                    if err == nil then
                        local x1, y1, x2, y2 = ExifTool.ReadValue(sbuf, 13, format, 4, len - 13):match(
                            '([^ \t\n\r\f\v]+)[ \t\n\r\f\v]+([^ \t\n\r\f\v]+)[ \t\n\r\f\v]+([^ \t\n\r\f\v]+)[ \t\n\r\f\v]+([^ \t\n\r\f\v]+)')
                        w = math.abs(tonumber(x2) - tonumber(x1))
                        h = math.abs(tonumber(y2) - tonumber(y1))
                    end
                end
                if err ~= nil then
                    et:Warn(err ~= '' and err or 'Truncated start record')
                else
                    et:HandleTag(tagTablePtr, 'ImageWidthInches', w / (xres ~= 0 and xres or 1200))
                    et:HandleTag(tagTablePtr, 'ImageHeightInches', h / (yres ~= 0 and yres or 1200))
                end
            else
                -- skip to the next record
                if not raf:Seek(len, 1) then
                    et:Warn('Truncated record')
                    break
                end
            end
        end
        -- go to some trouble to collapse identical sequential entries in record list
        -- (trying to keep the length of the list managable for complex images)
        if lastType and recType and recType == lastType then
            count = count + 1
            goto continueLoop
        end
        if lastType then
            local val = count > 1 and (lastType .. 'x' .. count) or lastType
            et:HandleTag(tagTablePtr, tag, val)
        end
        if not recType then break end
        lastType = recType
        count = 1
        ::continueLoop::
    end
    return 1
end

return WPG
