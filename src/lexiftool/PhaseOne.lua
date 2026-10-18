--------------------------------------------------------------------------------
-- File:         lexiftool/PhaseOne.lua
-- Ported from:  lib/Image/ExifTool/PhaseOne.pm
--
-- Description:  Phase One maker notes tags
--
-- Revisions:    2013-02-17 - P. Harvey Created
--
-- References:   1) http://www.cybercom.net/~dcoffin/dcraw/
--
-- Port notes:   Complete port of PhaseOne.pm: every table and sub, in
--               upstream order.  The predeclared ProcessPhaseOne/WritePhaseOne
--               are locals at the top; the tables reach them through
--               closures.  WritePhaseOne patches its header and directory
--               buffers in a carray, as the other writers do.  The inverse
--               conversions (ValueConvInv/PrintConvInv) are not carried, as
--               for most read-ported tables (see the Conv-forms check).
--               The maker notes reach WritePhaseOne through the IsPhaseOne
--               flag of MakerNotes.Main and its branch in ProcessExif, as
--               upstream.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local isMatch = perl.isMatch
local substr = perl.substr
local sprintf = perl.sprintf
local length = perl.length
local tr = perl.tr
local int = perl.int
local str = perl.str
local Get32u = ExifTool.Get32u
local Set32u = ExifTool.Set32u
local Put32u = ExifTool.Put32u
local SetByteOrder = ExifTool.SetByteOrder
local ReadValue = ExifTool.ReadValue
local GetTagTable = ExifTool.GetTagTable

local PhaseOne = {}

-- (upstream's predeclarations; the subs below assign to them)
local WritePhaseOne, ProcessPhaseOne

-- default formats based on PhaseOne format size
-- (upstream @formatName is 0-based: 0=undef, 1=string, 2=int16s, 3=undef,
--  4=int32s; Lua tables are 1-based, so index with fcode+1)
local formatName = { nil, 'string', 'int16s', nil, 'int32s' }

PhaseOne.Main = {
    PROCESS_PROC = function(...) return ProcessPhaseOne(...) end,
    WRITE_PROC = function(...) return WritePhaseOne(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = '1',
    FORMAT = 'int32s',
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    VARS = { ENTRY_SIZE = 16 }, -- (entries contain a format field)
    NOTES = 'These tags are extracted from the maker notes of Phase One images.',
    [0x0100] = { -- #1
        Name = 'CameraOrientation',
        ValueConv = function(_self, val) return val & 0x03 end, -- ignore other bits for now
        PrintConv = {
            [0] = 'Horizontal (normal)',
            [1] = 'Rotate 90 CW',
            [2] = 'Rotate 270 CW',
            [3] = 'Rotate 180',
        },
    },
    -- 0x0101 - int32u: 96,160,192,256,544 (same as 0x0213)
    [0x0102] = { Name = 'SerialNumber', Format = 'string' },
    -- 0x0103 - int32u: 19,20,59769034
    -- 0x0104 - int32u: 50,200
    [0x0105] = 'ISO',
    [0x0106] = {
        Name = 'ColorMatrix1',
        Format = 'float',
        Count = 9,
        PrintConv = function(_self, val)
            local out = {}
            for v in str(val):gmatch('[^ \t\n\r\f\v]+') do out[#out + 1] = sprintf('%.3f', tonumber(v)) end
            return table.concat(out, ' ')
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0107] = { Name = 'WB_RGBLevels', Format = 'float', Count = 3 },
    [0x0108] = 'SensorWidth',
    [0x0109] = 'SensorHeight',
    [0x010a] = 'SensorLeftMargin', -- #1
    [0x010b] = 'SensorTopMargin', -- #1
    [0x010c] = 'ImageWidth',
    [0x010d] = 'ImageHeight',
    [0x010e] = { -- #1
        Name = 'RawFormat',
        -- 1 = raw bit mask 0x5555 (>1 mask 0x1354)
        -- >2 = compressed
        -- 5 = non-linear
        PrintConv = { -- #PH
            [0] = 'Uncompressed', --https://github.com/darktable-org/darktable/issues/7308
            [1] = 'RAW 1', --? (encrypted)
            [2] = 'RAW 2', --? (encrypted)
            [3] = 'IIQ L', -- (now "L14", ref IB)
            -- 4?
            [5] = 'IIQ S',
            [6] = 'IIQ Sv2', -- (now "S14" for "IIQ 14 Smart" and "IIQ 14 Sensor+", ref IB)
            [8] = 'IIQ L16', --IB ("IIQ 16 Extended" and "IIQ 16 Large")
        },
    },
    [0x010f] = {
        Name = 'RawData',
        Format = 'undef', -- (actually 2-byte integers, but don't convert)
        Binary = 1,
        IsImageData = 1,
        PutFirst = 1,
        Writable = 0,
        Drop = 1, -- don't copy to other file types
    },
    [0x0110] = { -- #1
        Name = 'SensorCalibration',
        SubDirectory = { TagTable = 'lexiftool.PhaseOne.SensorCalibration' },
    },
    [0x0112] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Format = 'int32u',
        Writable = 0, -- (don't write because this is an encryption key for RawFormat 1 and 2)
        Priority = 0,
        Shift = 'Time',
        Groups = { [2] = 'Time' },
        Notes = 'may be used as a key to encrypt the raw data', -- #1
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end,
        ValueConvInv = function(_self, val) return ExifTool.GetUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    [0x0113] = 'ImageNumber', -- (NC)
    [0x0203] = { Name = 'Software', Format = 'string' },
    [0x0204] = { Name = 'System', Format = 'string' },
    -- 0x020b - int32u: 0,1
    -- 0x020c - int32u: 1,2
    -- 0x020e - int32u: 1,3
    [0x0210] = { -- (NC) (used in linearization formula - ref 1)
        Name = 'SensorTemperature',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.2f C', val) end,
        PrintConvInv = function(_self, val) return (perl.subst(val, ' ?C', '')) end,
    },
    [0x0211] = { -- (NC)
        Name = 'SensorTemperature2',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.2f C', val) end,
        PrintConvInv = function(_self, val) return (perl.subst(val, ' ?C', '')) end,
    },
    [0x0212] = {
        Name = 'UnknownDate',
        Format = 'int32u',
        Groups = { [2] = 'Time' },
        -- (this time is within about 10 minutes before or after 0x0112)
        Unknown = 1,
        Shift = 'Time',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end,
        ValueConvInv = function(_self, val) return ExifTool.GetUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    -- 0x0213 - int32u: 96,160,192,256,544 (same as 0x0101)
    -- 0x0215 - int32u: 4,5
    -- 0x021a - used by dcraw
    [0x021c] = { Name = 'StripOffsets', Binary = 1, Writable = 0 },
    [0x021d] = 'BlackLevel', -- #1
    -- 0x021e - int32u: 1
    -- 0x0220 - int32u: 32
    -- 0x0221 - float: 0-271
    [0x0222] = 'SplitColumn', -- #1
    [0x0223] = { Name = 'BlackLevelData', Format = 'int16u', Count = -1, Binary = 1 }, -- #1
    -- 0x0224 - int32u: 1688,2748,3372
    [0x0225] = {
        Name = 'PhaseOne_0x0225',
        Format = 'int16s',
        Count = -1,
        Flags = { 'Unknown', 'Hidden' },
        PrintConv = function(self, val) return ExifTool.LimitLongValues(val, self) end,
    },
    [0x0226] = {
        Name = 'ColorMatrix2',
        Format = 'float',
        Count = 9,
        PrintConv = function(_self, val)
            local out = {}
            for v in str(val):gmatch('[^ \t\n\r\f\v]+') do out[#out + 1] = sprintf('%.3f', tonumber(v)) end
            return table.concat(out, ' ')
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- 0x0227 - int32u: 0,1
    -- 0x0228 - int32u: 1,2
    -- 0x0229 - int32s: -2,0
    [0x0267] = { -- #PH
        Name = 'AFAdjustment',
        Format = 'float',
    },
    [0x022b] = { -- #PH
        Name = 'PhaseOne_0x022b',
        Format = 'float',
        Flags = { 'Unknown', 'Hidden' },
    },
    -- 0x0242 - int32u: 55
    -- 0x0244 - int32u: 102
    -- 0x0245 - float: 1.2
    [0x0258] = { -- #PH
        Name = 'PhaseOne_0x0258',
        Format = 'int16s',
        Flags = { 'Unknown', 'Hidden' },
        PrintConv = function(self, val) return ExifTool.LimitLongValues(val, self) end,
    },
    [0x025a] = { -- #PH
        Name = 'PhaseOne_0x025a',
        Format = 'int16s',
        Flags = { 'Unknown', 'Hidden' },
        PrintConv = function(self, val) return ExifTool.LimitLongValues(val, self) end,
    },
    [0x0262] = { Name = 'SequenceID', Format = 'string' },
    [0x0263] = {
        Name = 'SequenceKind',
        PrintConv = {
            [0] = 'Bracketing: Shutter Speed',
            [1] = 'Bracketing: Aperture',
            [2] = 'Bracketing: ISO',
            [3] = 'Hyperfocal',
            [4] = 'Time Lapse',
            [5] = 'HDR',
            [6] = 'Focus Stacking',
        },
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0264] = 'SequenceFrameNumber',
    [0x0265] = 'SequenceFrameCount',
    -- 0x0300 - int32u: 100,101,102
    [0x0301] = { Name = 'FirmwareVersions', Format = 'string' },
    -- 0x0304 - int32u: 8,3073,3076
    [0x0400] = {
        Name = 'ShutterSpeedValue',
        Format = 'float',
        ValueConv = function(_self, val)
            return math.abs(val) < 100 and (2 ^ (-val)) or 0
        end,
        ValueConvInv = function(_self, val)
            if perl.num(val) > 0 then return -perl.log(val) / math.log(2) end
            return -100
        end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.Exif').ConvertFraction(val) end,
    },
    [0x0401] = {
        Name = 'ApertureValue',
        Format = 'float',
        ValueConv = function(_self, val) return 2 ^ (val / 2) end,
        ValueConvInv = function(_self, val)
            if perl.num(val) > 0 then return 2 * perl.log(val) / math.log(2) end
            return 0
        end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0402] = {
        Name = 'ExposureCompensation',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.3f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0403] = {
        Name = 'FocalLength',
        Format = 'float',
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
        PrintConvInv = function(_self, val) return (perl.subst(val, [[\s*mm$]], '')) end,
    },
    -- 0x0404 - int32u: 0,3
    -- 0x0405 - int32u? (big numbers)
    -- 0x0406 - int32u: 1
    -- 0x0407 - float: -0.333 (exposure compensation again?)
    -- 0x0408-0x0409 - int32u: 1
    [0x0410] = { Name = 'CameraModel', Format = 'string' },
    -- 0x0411 - int32u: 33556736
    [0x0412] = { Name = 'LensModel', Format = 'string' },
    [0x0414] = {
        Name = 'MaxApertureValue',
        Format = 'float',
        ValueConv = function(_self, val) return 2 ^ (val / 2) end,
        ValueConvInv = function(_self, val)
            if perl.num(val) > 0 then return 2 * perl.log(val) / math.log(2) end
            return 0
        end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0415] = {
        Name = 'MinApertureValue',
        Format = 'float',
        ValueConv = function(_self, val) return 2 ^ (val / 2) end,
        ValueConvInv = function(_self, val)
            if perl.num(val) > 0 then return 2 * perl.log(val) / math.log(2) end
            return 0
        end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- 0x0416 - float: (min focal length? ref LR, Credo50) (but looks more like an int32u date for the 645DF - PH)
    -- 0x0417 - float: 80 (max focal length? ref LR)
    [0x0455] = { -- #PH
        Name = 'Viewfinder',
        Format = 'string',
    },
}

-- Phase One metadata (ref 1)
PhaseOne.SensorCalibration = {
    PROCESS_PROC = function(...) return ProcessPhaseOne(...) end,
    WRITE_PROC = function(...) return WritePhaseOne(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    TAG_PREFIX = 'SensorCalibration',
    WRITE_GROUP = 'PhaseOne',
    VARS = { ENTRY_SIZE = 12 }, -- (entries do not contain a format field)
    [0x0400] = {
        Name = 'SensorDefects',
        -- list of defects. each defect is 4 x int16u values:
        -- 0=column, 1=row, 2=type (129=bad pixel, 131=bad column), 3=?
        -- (but it isn't really worth the time decoding this -- it can be a few hundred kB)
        Format = 'undef',
        Binary = 1,
    },
    [0x0401] = {
        Name = 'AllColorFlatField1',
        Format = 'undef',
        Flags = { 'Unknown', 'Binary' },
    },
    [0x0404] = { -- #PH
        Name = 'SensorCalibration_0x0404',
        Format = 'string',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x0405] = { -- #PH
        Name = 'SensorCalibration_0x0405',
        Format = 'string',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x0406] = { -- #PH
        Name = 'SensorCalibration_0x0406',
        Format = 'string',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x0407] = { -- #PH
        Name = 'SerialNumber',
        Format = 'string',
        Writable = 1,
    },
    [0x0408] = { -- #PH
        Name = 'SensorCalibration_0x0408',
        Format = 'float',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x040b] = {
        Name = 'RedBlueFlatField',
        Format = 'undef',
        Flags = { 'Unknown', 'Binary' },
    },
    [0x040f] = { -- #PH
        Name = 'SensorCalibration_0x040f',
        Format = 'undef',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x0410] = {
        Name = 'AllColorFlatField2',
        Format = 'undef',
        Flags = { 'Unknown', 'Binary' },
    },
    -- 0x0412 - used by dcraw
    [0x0413] = { -- #PH
        Name = 'SensorCalibration_0x0413',
        Format = 'double',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x0414] = { -- #PH
        Name = 'SensorCalibration_0x0414',
        Format = 'undef',
        Flags = { 'Unknown', 'Hidden' },
        ValueConv = function(_self, val)
            local order = ExifTool.GetByteOrder()
            if #val >= 8 and ExifTool.SetByteOrder(substr(val, 0, 2)) then
                val = ExifTool.ReadValue(val, 2, 'int16u', 1, #val - 2) .. ' ' ..
                      ExifTool.ReadValue(val, 4, 'float', nil, #val - 4)
                ExifTool.SetByteOrder(order)
            end
            return val
        end,
    },
    [0x0416] = {
        Name = 'AllColorFlatField3',
        Format = 'undef',
        Flags = { 'Unknown', 'Binary' },
    },
    [0x0418] = { -- #PH
        Name = 'SensorCalibration_0x0418',
        Format = 'undef',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x0419] = {
        Name = 'LinearizationCoefficients1',
        Format = 'float',
        PrintConv = function(_self, val)
            local out = {}
            for v in str(val):gmatch('[^ \t\n\r\f\v]+') do out[#out + 1] = sprintf('%.5g', tonumber(v)) end
            return table.concat(out, ' ')
        end,
    },
    [0x041a] = {
        Name = 'LinearizationCoefficients2',
        Format = 'float',
        PrintConv = function(_self, val)
            local out = {}
            for v in str(val):gmatch('[^ \t\n\r\f\v]+') do out[#out + 1] = sprintf('%.5g', tonumber(v)) end
            return table.concat(out, ' ')
        end,
    },
    [0x041c] = { -- #PH
        Name = 'SensorCalibration_0x041c',
        Format = 'float',
        Flags = { 'Unknown', 'Hidden' },
    },
    [0x041e] = { -- #PH
        Name = 'SensorCalibration_0x041e',
        Format = 'undef',
        Flags = { 'Unknown', 'Hidden' },
        ValueConv = function(_self, val)
            local order = ExifTool.GetByteOrder()
            if #val >= 8 and ExifTool.SetByteOrder(substr(val, 0, 2)) then
                val = ExifTool.ReadValue(val, 2, 'int16u', 1, #val - 2) .. ' ' ..
                      ExifTool.ReadValue(val, 4, 'float', nil, #val - 4)
                ExifTool.SetByteOrder(order)
            end
            return val
        end,
    },
}

--------------------------------------------------------------------------------
-- Do HTML dump of an IFD entry
-- Inputs: 0) ExifTool ref, 1) tag table ref, 3) tag ID, 4) tag value,
--         5) IFD entry offset, 6) IFD entry size, 7) parameter hash
function PhaseOne.HtmlDump(et, tagTablePtr, tagID, value, entry, entryLen, parms)
    local dirName, index, formatStr, dataPos, base, size, valuePtr =
        parms.DirName, parms.Index, parms.Format, parms.DataPos, parms.Base, parms.Size, parms.Start
    local tagInfo = et:GetTagInfo(tagTablePtr, tagID)
    local tagName, colName, subdir
    local count = perl.truthy(parms.Count) and parms.Count or size
    if base == nil then base = 0 end
    if tagInfo then
        tagName = tagInfo.Name
        subdir = tagInfo.SubDirectory
        if tagInfo.Format then
            formatStr = tagInfo.Format
            count = size / ExifTool.FormatSize(formatStr)
        end
    else
        tagName = sprintf("Tag 0x%.4x", tagID)
    end
    local dname = sprintf(dirName .. "-%.2d", index)
    -- build our tool tip
    local fstr = formatStr .. "[" .. perl.str(count) .. "]"
    local tip = sprintf("Tag ID: 0x%.4x\n", tagID) ..
              "Format: " .. fstr .. "\nSize: " .. size .. " bytes\n"
    if size > 4 then
        tip = tip .. sprintf("Value offset: 0x%.4x\n", valuePtr - base)
        tip = tip .. sprintf("Actual offset: 0x%.4x\n", valuePtr + dataPos)
        tip = tip .. sprintf("Offset base: 0x%.4x\n", dataPos + base)
        colName = "<span class=F>" .. tagName .. "</span>"
    else
        colName = tagName
    end
    if type(value) ~= 'table' then
        value = perl.str(value)
        local tval = length(value) > 32 and substr(value, 0, 28) .. '[...]' or value
        tval = tr(tval, '\x00-\x1f\x7f-\xff', '.')
        tip = tip .. "Value: " .. tval
    end
    et:HDump(entry + dataPos, entryLen, dname .. " " .. colName, tip, 1)
    if size > 4 then
        local dumpPos = valuePtr + dataPos
        -- add value data block
        et:HDump(dumpPos, size, tagName .. " value", 'SAME', subdir and 0x04 or 0)
    end
end

--------------------------------------------------------------------------------
-- Write PhaseOne maker notes (both types of PhaseOne IFD)
-- Inputs: 0) ExifTool object ref, 1) source dirInfo ref, 2) tag table ref
-- Returns: data block or undef on error
function WritePhaseOne(et, dirInfo, tagTablePtr)
    if not et then return 1 end   -- allow dummy access to autoload this package
    local Writer = require('lexiftool.Writer')
    local carray = require('carray')

    -- nothing to do if we aren't changing any PhaseOne tags
    local newTags = Writer.GetNewTagInfoHash(et, tagTablePtr)
    if not (next(newTags) ~= nil or perl.truthy(et.DropTags) or (et.EDIT_DIRS and et.EDIT_DIRS.PhaseOne)) then return nil end

    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dirLen = perl.truthy(dirInfo.DirLen) and dirInfo.DirLen or ((dirInfo.DataLen or #dataPt) - dirStart)
    local dirName = dirInfo.DirName

    if dirLen < 12 then return nil end
    if not (tagTablePtr.VARS and tagTablePtr.VARS.ENTRY_SIZE) then
        et:Warn("No ENTRY_SIZE for " .. str(tagTablePtr.TABLE_NAME))
        return nil
    end
    local entrySize = tagTablePtr.VARS.ENTRY_SIZE
    local ifdType = tagTablePtr.TAG_PREFIX or 'PhaseOne'
    local hdr = substr(dataPt, dirStart, 12)
    if entrySize == 16 then
        if not isMatch(hdr, [[(?s)^(IIII.waR|MMMMRaw.)]]) then return nil end
    elseif not isMatch(hdr, [[(?s)^(IIII\x01\0\0\0|MMMM\0\0\0\x01)]]) then
        et:Warn("Unrecognized " .. ifdType .. " directory version")
        return nil
    end
    SetByteOrder(substr(hdr, 0, 2))
    -- get offset to start of PhaseOne directory
    local ifdStart = Get32u(hdr, 8)
    if ifdStart + 8 > dirLen then return nil end
    -- initialize output directory buffer with (fixed) number of entries plus 4-byte padding
    local dirBuff = carray.new('char')
    dirBuff:append(substr(dataPt, dirStart + ifdStart, 8))
    -- get number of entries in PhaseOne directory
    local numEntries = Get32u(dirBuff, 0)
    local ifdEnd = ifdStart + 8 + entrySize * numEntries
    if numEntries < 2 or numEntries > 300 or ifdEnd > dirLen then return nil end
    local hdrBuff = hdr
    local valBuff = ''  -- buffer for value data
    local fixup = require('lexiftool.Fixup').new()
    for index = 0, numEntries - 1 do
        local entry = dirStart + ifdStart + 8 + entrySize * index
        local tagID = Get32u(dataPt, entry)
        local size = Get32u(dataPt, entry + entrySize - 8)
        local formatSize, formatStr
        if entrySize == 16 then
            formatSize = Get32u(dataPt, entry + 4)
            formatStr = formatName[formatSize + 1]
            if not formatStr then
                et:Warn("Possibly invalid " .. ifdType .. " IFD entry " .. index, 1)
                newTags[tagID] = nil    -- make sure we don't try to change this one
            end
        else
            -- (no format code for SensorCalibration IFD entries)
            formatSize = 1  -- luacheck: ignore 311
            formatStr = 'undef'
        end
        local valuePtr = entry + entrySize - 4
        if size > 4 then
            if size > 0x7fffffff then
                et:Error("Invalid size for " .. ifdType .. " IFD entry " .. index, 1)
                return nil
            end
            valuePtr = Get32u(dataPt, valuePtr)
            if valuePtr + size > dirLen then
                et:Error(sprintf("Invalid offset 0x%.4x for " .. ifdType .. " IFD entry " .. index, valuePtr), 1)
                return nil
            end
            valuePtr = valuePtr + dirStart
        end
        local value = substr(dataPt, valuePtr, size)
        local tagInfo = newTags[tagID] or tagTablePtr[tagID]
        if tagInfo and type(tagInfo) ~= 'table' then tagInfo = et:GetTagInfo(tagTablePtr, tagID) end
        if newTags[tagID] then
            if tagInfo.Format then formatStr = tagInfo.Format end
            local count = int(size / ExifTool.FormatSize(formatStr))
            local val = ReadValue(value, 0, formatStr, count, size)
            local nvHash = Writer.GetNewValueHash(et, tagInfo)
            if perl.truthy(Writer.IsOverwriting(et, nvHash, val)) then
                local newVal = Writer.GetNewValue(et, nvHash)
                -- allow count to change for string and undef types only
                if formatStr == 'string' or formatStr == 'undef' then count = nil end
                local newValue = Writer.WriteValue(newVal, formatStr, count)
                if newValue ~= nil then
                    value = newValue
                    size = length(newValue)
                    et:VerboseValue("- " .. dirName .. ":" .. tagInfo.Name, val)
                    et:VerboseValue("+ " .. dirName .. ":" .. tagInfo.Name, newVal)
                    et.CHANGED = (et.CHANGED or 0) + 1
                end
            end
        elseif tagInfo and tagInfo.SubDirectory then
            local subTable = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
            local subdirInfo = {
                DirName = tagInfo.Name,
                DataPt  = value,
                DataLen = length(value),
            }
            local newValue = Writer.WriteDirectory(et, subdirInfo, subTable)
            if newValue ~= nil and perl.truthy(length(newValue)) then
                value = newValue
                size = length(newValue)
            end
        elseif perl.truthy(et.DropTags) and ((tagInfo and tagInfo.Drop) or size > 8192) then
            -- decrease the number of entries in the directory
            Set32u(dirBuff, 0, Get32u(dirBuff, 0) - 1)
            goto next_  -- drop this tag
        end
        -- add the tagID, possibly format size, and size to this directory entry
        dirBuff:append(substr(dataPt, entry, entrySize - 8) .. Put32u(size))

        -- pad value to an even 4-byte boundary just in case
        if size & 0x03 ~= 0 or size == 0 then value = value .. string.rep("\0", 4 - (size & 0x03)) end
        if size <= 4 then
            -- store value in place of the IFD value pointer (already padded to 4 bytes)
            dirBuff:append(value)
        elseif tagInfo and tagInfo.PutFirst then
            -- store value immediately after header
            dirBuff:append(Put32u(length(hdrBuff)))
            hdrBuff = hdrBuff .. value
        else
            -- store value at end of value buffer
            fixup:AddFixup(length(dirBuff))
            dirBuff:append(Put32u(length(valBuff)))
            valBuff = valBuff .. value
        end
        ::next_::
    end
    -- apply necessary fixup to offsets in PhaseOne directory
    fixup.Shift = length(hdrBuff)
    dirBuff = fixup:ApplyFixup(dirBuff)
    -- set pointer to PhaseOneIFD in header
    local hdrBuf = carray.new('char')
    hdrBuf:append(hdrBuff)
    Set32u(hdrBuf, 8, length(hdrBuff) + length(valBuff))
    return hdrBuf:tostring() .. valBuff .. dirBuff:tostring()
end
PhaseOne.WritePhaseOne = WritePhaseOne

--------------------------------------------------------------------------------
-- Read Phase One maker notes
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- Notes: This routine processes both the main PhaseOne IFD type (with 16 bytes
--        per entry), and the SensorCalibration IFD type (12 bytes per entry)
function ProcessPhaseOne(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = (dirInfo.DataPos or 0) + (dirInfo.Base or 0)
    local dirStart = dirInfo.DirStart or 0
    local dirLen = perl.truthy(dirInfo.DirLen) and dirInfo.DirLen or ((dirInfo.DataLen or #dataPt) - dirStart)
    local binary = et:Options('Binary')
    local verbose = et:Options('Verbose')
    local hash = rawget(et, 'ImageDataHash')  -- (rawget: also the name of a method)
    local htmlDump = et.HTML_DUMP

    if dirLen < 12 then return 0 end
    if not (tagTablePtr.VARS and tagTablePtr.VARS.ENTRY_SIZE) then
        et:Warn("No ENTRY_SIZE for " .. str(tagTablePtr.TABLE_NAME))
        return nil
    end
    local entrySize = tagTablePtr.VARS.ENTRY_SIZE
    local ifdType = tagTablePtr.TAG_PREFIX or 'PhaseOne'

    local hdr = substr(dataPt, dirStart, 12)
    if entrySize == 16 then
        if not isMatch(hdr, [[(?s)^(IIII.waR|MMMMRaw.)]]) then return 0 end
    elseif not isMatch(hdr, [[(?s)^(IIII\x01\0\0\0|MMMM\0\0\0\x01)]]) then
        et:Warn("Unrecognized " .. ifdType .. " directory version")
        return 0
    end
    SetByteOrder(substr(hdr, 0, 2))
    -- get offset to start of PhaseOne directory
    local ifdStart = Get32u(hdr, 8)
    if ifdStart + 8 > dirLen then return 0 end
    -- get number of entries in PhaseOne directory
    local numEntries = Get32u(dataPt, dirStart + ifdStart)
    local ifdEnd = ifdStart + 8 + entrySize * numEntries
    if numEntries < 2 or numEntries > 300 or ifdEnd > dirLen then return 0 end
    et:VerboseDir(ifdType, numEntries)
    if htmlDump then
        et:HDump(dirStart + dataPos, 8, ifdType .. " header")
        et:HDump(dirStart + dataPos + 8, 4, ifdType .. " IFD offset")
        et:HDump(dirStart + dataPos + ifdStart, 4, ifdType .. " entries",
                   "Entry count: " .. numEntries)
        et:HDump(dirStart + dataPos + ifdStart + 4, 4, '[unused]')
    end
    for index = 0, numEntries - 1 do
        local entry = dirStart + ifdStart + 8 + entrySize * index
        local tagID = Get32u(dataPt, entry)
        local size = Get32u(dataPt, entry + entrySize - 8)
        local valuePtr = entry + entrySize - 4
        local formatSize, formatStr, value
        if entrySize == 16 then
            -- (format code only for the 16-byte IFD entry)
            formatSize = Get32u(dataPt, entry + 4)
            formatStr = formatName[formatSize + 1]
            if not formatStr then
                et:Warn("Unrecognized " .. ifdType .. " format size " .. formatSize, 1)
                formatSize = 1  -- luacheck: ignore 311
                formatStr = 'undef'
            end
        elseif size % 4 ~= 0 then
            formatSize = 1  -- luacheck: ignore 311
            formatStr = 'undef'
        else
            formatSize = 4  -- luacheck: ignore 311
            formatStr = 'int32s'
        end
        if size > 4 then
            if size > 0x7fffffff then
                et:Warn("Invalid size for " .. ifdType .. " IFD entry " .. index)
                return 0
            end
            valuePtr = Get32u(dataPt, valuePtr)
            if valuePtr + size > dirLen then
                et:Warn(sprintf("Invalid offset 0x%.4x for " .. ifdType .. " IFD entry " .. index, valuePtr))
                return 0
            end
            valuePtr = valuePtr + dirStart
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, tagID)
        if tagInfo then
            if tagInfo.Format then formatStr = tagInfo.Format end
        else
            if not (perl.truthy(verbose) or htmlDump) then goto next_ end
        end
        do
            local count = int(size / ExifTool.FormatSize(formatStr))
            if count > 100000 and not perl.truthy(binary) then
                value = { ref = 'SCALAR', value = "Binary data " .. size .. " bytes" }
            else
                value = ReadValue(dataPt, valuePtr, formatStr, count, size)
                -- try to distinguish between the various format types
                if formatStr == 'int32s' then
                    local val = perl.split(' ', value)[1]
                    if val ~= nil then
                        -- get floating point exponent (has bias of 127)
                        local exp = (int(val) & 0x7f800000) >> 23
                        if exp > 120 and exp < 140 then
                            formatStr = 'float'
                            value = ReadValue(dataPt, valuePtr, formatStr, count, size)
                        end
                    end
                end
            end
            if hash and tagInfo and tagInfo.IsImageData then
                local pos, len = valuePtr, size
                while len > 0 do
                    local n = len > 65536 and 65536 or len
                    local tmp = substr(dataPt, pos, n)
                    hash:add(tmp)
                    len = len - n
                    pos = pos + n
                end
                et:VPrint(0, et.INDENT .. "(ImageDataHash: " .. size .. " bytes of PhaseOne:" .. tagInfo.Name .. ")\n")
            end
            local parms = {
                DirName = ifdType,
                Index   = index,
                DataPt  = dataPt,
                DataPos = dataPos,
                Size    = size,
                Start   = valuePtr,
                Format  = formatStr,
                Count   = count
            }
            if htmlDump then
                local hparms = { Base = dirStart }
                for k, v in pairs(parms) do hparms[k] = v end
                PhaseOne.HtmlDump(et, tagTablePtr, tagID, value, entry, entrySize, hparms)
            end
            et:HandleTag(tagTablePtr, tagID, value, parms)
        end
        ::next_::
    end
    return 1
end
PhaseOne.ProcessPhaseOne = ProcessPhaseOne

return PhaseOne
