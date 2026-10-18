--------------------------------------------------------------------------------
-- File:         lexiftool/MinoltaRaw.lua
-- Ported from:  lib/Image/ExifTool/MinoltaRaw.pm
--
-- Description:  Read/write Konica-Minolta RAW (MRW) meta information
--
-- Revisions:    03/11/2006 - P. Harvey Split out from Minolta.pm
--
-- References:   1) http://www.cybercom.net/~dcoffin/dcraw/
--               2) http://www.chauveau-central.net/mrw-format/
--               3) Igal Milchtaich private communication (A100)
--
-- Port notes:   read-only subset.  `Main` dispatches the four MRW segments
--               (TTW/PRD/WBG/RIF); the TTW (embedded TIFF/EXIF) segment is
--               handed to the generic ProcessTIFF.  PRD/WBG/RIF are
--               ProcessBinaryData tables carrying only the entries the
--               vendored Minolta.mrw golden exercises (DiMAGE A2), except
--               that the conditional lists (WBG 4, RIF 7) carry all their
--               branches, as upstream; the other Sony A100/A200/A700
--               conditional entries are not ported.
--               WriteMRW is ported, the segment tables carry upstream's
--               WRITE_PROC/CHECK_PROC.  `PreviewImageStart`/`PreviewImageLength`
--               in RIF use the established IsOffset/DataTag pattern picked up
--               by the generic Exif.Composite.PreviewImage.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local matches = require('lexiftool.perl').matches
local isMatch = require('lexiftool.perl').isMatch
local perlTruthy = require('lexiftool.perl').truthy
local length = require('lexiftool.perl').length
local str = require('lexiftool.perl').str
local carray = require('carray')

local MinoltaRaw = {}

-- Minolta MRW tags
MinoltaRaw.Main = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'These tags are used in Minolta RAW format (MRW) images.',
    ['\0TTW'] = { -- TIFF Tags
        Name = 'MinoltaTTW',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            -- this EXIF information starts with a TIFF header
            ProcessProc = ExifTool.ProcessTIFF,
            -- (upstream Image::ExifTool::WriteTIFF -- this port has the
            --  directory-level TIFF writer in Writer, since ExifTool.WriteTIFF
            --  is already the file-level one)
            WriteProc = function(et, dirInfo, tagTablePtr)
                return require('lexiftool.Writer').WriteTIFF(et, dirInfo, tagTablePtr)
            end,
        },
    },
    ['\0PRD'] = { -- Raw Picture Dimensions
        Name = 'MinoltaPRD',
        SubDirectory = { TagTable = 'lexiftool.MinoltaRaw.PRD' },
    },
    ['\0WBG'] = { -- White Balance Gains
        Name = 'MinoltaWBG',
        SubDirectory = { TagTable = 'lexiftool.MinoltaRaw.WBG' },
    },
    ['\0RIF'] = { -- Requested Image Format
        Name = 'MinoltaRIF',
        SubDirectory = { TagTable = 'lexiftool.MinoltaRaw.RIF' },
    },
    -- "\0CSA" is padding
}

-- Minolta MRW PRD information (ref 2)
MinoltaRaw.PRD = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    DATAMEMBER = { 0 },
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'FirmwareID',
        Format = 'string[8]',
        RawConv = function(self, val)
            if self.FILE_TYPE == 'MRW' then self.MinoltaPRD = 1 end -- used in decoding RIF info
            return val
        end,
    },
    [8] = { Name = 'SensorHeight', Format = 'int16u' },
    [10] = { Name = 'SensorWidth', Format = 'int16u' },
    [12] = { Name = 'ImageHeight', Format = 'int16u' },
    [14] = { Name = 'ImageWidth', Format = 'int16u' },
    [16] = { Name = 'RawDepth', Format = 'int8u' },
    [17] = { Name = 'BitDepth', Format = 'int8u' },
    [18] = {
        Name = 'StorageMethod',
        Format = 'int8u',
        PrintConv = {
            [82] = 'Padded',
            [89] = 'Linear',
        },
    },
    [23] = {
        Name = 'BayerPattern',
        Format = 'int8u',
        PrintConv = {
            -- 0 - seen in some Sony A850 ARW images
            [1] = 'RGGB',
            [4] = 'GBRG',
        },
    },
}

-- Minolta MRW WBG information (ref 2)
MinoltaRaw.WBG = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'WBScale',
        Format = 'int8u[4]',
    },
    [4] = {
        {
            Condition = function(self) return matches(self.Model, [[DiMAGE A200\b]]) ~= nil end,
            Name = 'WB_GBRGLevels',
            Format = 'int16u[4]',
            Notes = 'DiMAGE A200',
        },
        {
            Name = 'WB_RGGBLevels',
            Format = 'int16u[4]',
            Notes = 'other models',
        },
    },
}

-- Minolta MRW RIF information (ref 2)
-- Port notes: entries exercised by the vendored Minolta.mrw golden (DiMAGE
-- A2); the Sony A100/A200/A700-conditional entries are not ported.
MinoltaRaw.RIF = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FIRST_ENTRY = 0,
    [1] = { Name = 'Saturation', Format = 'int8s' },
    [2] = { Name = 'Contrast', Format = 'int8s' },
    [3] = { Name = 'Sharpness', Format = 'int8s' },
    [4] = {
        Name = 'WBMode',
        PrintConv = function(_self, val) return MinoltaRaw.ConvertWBMode(val) end,
    },
    [5] = {
        Name = 'ProgramMode',
        PrintConv = {
            [0] = 'None',
            [1] = 'Portrait',
            [2] = 'Text',
            [3] = 'Night Portrait',
            [4] = 'Sunset',
            [5] = 'Sports',
        },
    },
    [6] = {
        Name = 'ISOSetting',
        RawConv = function(_self, val) if val == 255 then return nil end return val end,
        PrintConv = {
            [0] = 'Auto',
            [48] = 100,
            [56] = 200,
            [64] = 400,
            [72] = 800,
            [80] = 1600,
            [174] = '80 (Zone Matching Low)',
            [184] = '200 (Zone Matching High)',
            OTHER = function(val, _inv)
                return math.floor(2 ^ ((val - 48) / 8) * 100 + 0.5)
            end,
        },
    },
    [7] = {
        {
            Name = 'ColorMode',
            Condition = function(self) return not str(self.Make or ''):match('^SONY') end,
            Priority = 0,
            Writable = 1,
            PrintConv = require('lexiftool.Minolta').minoltaColorMode,
        },
        { -- #3
            Name = 'ColorMode',
            Condition = function(self) return self.Model == 'DSLR-A100' end,
            Writable = 1,
            Notes = 'Sony A100',
            Priority = 0,
            PrintHex = 1,
            PrintConv = require('lexiftool.Minolta').sonyColorMode,
        },
    },
    [8] = { -- #3
        Name = 'WB_RBLevelsTungsten',
        Condition = function(self) return self.Model == 'DSLR-A100' or self.MinoltaPRD end,
        Format = 'int16u[2]',
        Notes = 'these WB_RBLevels currently decoded only for the Sony A100',
    },
    [12] = {
        Name = 'WB_RBLevelsDaylight',
        Condition = function(self) return self.Model == 'DSLR-A100' or self.MinoltaPRD end,
        Format = 'int16u[2]',
    },
    [16] = {
        Name = 'WB_RBLevelsCloudy',
        Condition = function(self) return self.Model == 'DSLR-A100' or self.MinoltaPRD end,
        Format = 'int16u[2]',
    },
    [20] = {
        Name = 'WB_RBLevelsCoolWhiteF',
        Condition = function(self) return self.Model == 'DSLR-A100' or self.MinoltaPRD end,
        Format = 'int16u[2]',
    },
    [24] = {
        Name = 'WB_RBLevelsFlash',
        Condition = function(self) return self.Model == 'DSLR-A100' or self.MinoltaPRD end,
        Format = 'int16u[2]',
    },
    [28] = {
        Name = 'WB_RBLevelsCustom',
        Condition = function(self) return self.Model == 'DSLR-A100' or self.MinoltaPRD end,
        Format = 'int16u[2]',
    },
    [32] = { -- #3
        Name = 'WB_RBLevelsShade',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [36] = { -- #3
        Name = 'WB_RBLevelsDaylightF',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [40] = { -- #3
        Name = 'WB_RBLevelsDayWhiteF',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [44] = { -- #3
        Name = 'WB_RBLevelsWhiteF',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [56] = {
        Name = 'ColorFilter',
        Condition = function(self) return not str(self.Make or ''):match('^SONY') end,
        Format = 'int8s',
        Notes = 'Minolta models',
    },
    [57] = 'BWFilter',
    [58] = {
        Name = 'ZoneMatching',
        Condition = function(self) return not str(self.Make or ''):match('^SONY') end,
        Priority = 0,
        Notes = 'Minolta models',
        PrintConv = {
            [0] = 'ISO Setting Used',
            [1] = 'High Key',
            [2] = 'Low Key',
        },
    },
    [59] = {
        Name = 'Hue',
        Format = 'int8s',
    },
    [60] = {
        Name = 'ColorTemperature',
        Condition = function(self) return not str(self.Make or ''):match('^SONY') end,
        Notes = 'Minolta models',
        ValueConv = function(_self, val) return val * 100 end,
        ValueConvInv = function(_self, val) return val / 100 end,
    },
    [74] = { -- #3
        Name = 'ZoneMatching',
        Condition = function(self) return str(self.Make or ''):match('^SONY') ~= nil end,
        Priority = 0,
        Notes = 'Sony models',
        PrintConv = {
            [0] = 'ISO Setting Used',
            [1] = 'High Key',
            [2] = 'Low Key',
        },
    },
    [76] = { -- #3
        Name = 'ColorTemperature',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Notes = 'A100',
        ValueConv = function(_self, val) return val * 100 end,
        ValueConvInv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) if perlTruthy(val) then return val end return 'Auto' end,
        PrintConvInv = function(_self, val) if isMatch(val, [[(?i)Auto]]) then return 0 end return val end,
    },
    [77] = { -- #3
        Name = 'ColorFilter',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Notes = 'A100',
    },
    [78] = { -- #3
        Name = 'ColorTemperature',
        Condition = function(self) return isMatch(self.Model, [[^DSLR-A(200|700)$]]) end,
        Notes = 'A200 and A700',
        ValueConv = function(_self, val) return val * 100 end,
        ValueConvInv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) if perlTruthy(val) then return val end return 'Auto' end,
        PrintConvInv = function(_self, val) if isMatch(val, [[(?i)Auto]]) then return 0 end return val end,
    },
    [79] = { -- #3
        Name = 'ColorFilter',
        Condition = function(self) return isMatch(self.Model, [[^DSLR-A(200|700)$]]) end,
        Notes = 'A200 and A700',
    },
    [80] = { -- #3
        Name = 'RawDataLength',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int32u',
        Notes = 'A100',
        Writable = 0,
    },
}

-- PrintConv for WBMode
function MinoltaRaw.ConvertWBMode(val)
    local mrwWB = {
        [0] = 'Auto',
        [1] = 'Daylight',
        [2] = 'Cloudy',
        [3] = 'Tungsten',
        [4] = 'Flash/Fluorescent',
        [5] = 'Fluorescent',
        [6] = 'Shade',
        [7] = 'User 1',
        [8] = 'User 2',
        [9] = 'User 3',
        [10] = 'Temperature',
    }
    local lo = val & 0x0f
    local wbstr = mrwWB[lo] or ('Unknown (' .. lo .. ')')
    local hi = val >> 4
    if hi >= 6 and hi <= 12 then wbstr = wbstr .. ' (' .. (hi - 8) .. ')' end
    return wbstr
end

--------------------------------------------------------------------------------
-- Write MRW file (upstream WriteMRW)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: MRW data or undef on error
--------------------------------------------------------------------------------
function MinoltaRaw.WriteMRW(et, dirInfo, tagTablePtr)
    if not et then return 1 end     -- allow dummy access
    local buff = carray.new('char')
    dirInfo.OutFile = { value = buff }
    if MinoltaRaw.ProcessMRW(et, dirInfo, tagTablePtr) <= 0 then return nil end
    return buff:tostring()
end

-- Read or write Minolta MRW file (upstream ProcessMRW)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) optional tag table ref
-- Returns: 1 on success, 0 if this wasn't a valid MRW file, or -1 on write error
-- Notes: File pointer must be set to start of MRW in RAF upon entry
function MinoltaRaw.ProcessMRW(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local err, outBuff
    local n, data = raf:Read(8)
    if n ~= 8 then return 0 end
    -- "\0MRM" for big-endian (MRW images), and
    -- "\0MRI" for little-endian (MRWInfo in ARW images)
    local t = data:sub(2, 4)
    if not (t == 'MRM' or t == 'MRI') then return 0 end
    local hdr = '\0MR' .. t:sub(3, 3)
    local order = t:sub(3, 3) == 'M' and 'MM' or 'II'
    ExifTool.SetByteOrder(order)
    et:SetFileType()
    tagTablePtr = tagTablePtr or et:GetTagTable('lexiftool.MinoltaRaw.Main')
    local Writer = require('lexiftool.Writer')
    if outfile then
        Writer.InitWriteDirs(et, 'TIFF') -- use same write dirs as TIFF
        outBuff = carray.new('char')
    end
    local pos = raf:Tell()
    local offset = ExifTool.Get32u(data, 4) + pos
    local rtnVal = 1
    -- loop through MRW segments (ref 1)
    while pos < offset do
        local n2, data2 = raf:Read(8)
        if n2 ~= 8 then err = 1 break end
        pos = pos + 8
        local tag = data2:sub(1, 4)
        local len = ExifTool.Get32u(data2, 4)
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo and tagInfo.SubDirectory then
            local subTable = et:GetTagTable(tagInfo.SubDirectory.TagTable)
            -- save shift for values stored with wrong base offset
            et.MRW_WrongBase = -(raf:Tell())
            local n3, buff = raf:Read(len)
            if n3 ~= len then err = 1 break end
            local subdirInfo = {
                DataPt = buff,
                DataLen = len,
                DataPos = pos,
                DirStart = 0,
                DirLen = len,
                DirName = tagInfo.Name,
                Parent = 'MRW',
                -- the TTW segment's TIFF pointers are relative to the segment
                -- start, but IsOffset tag values (PreviewImageStart etc.) are
                -- absolute file offsets -- so Base must be 0 (the MRW offset
                -- the segment starts at is not an offset base to add; it would
                -- double-count it in the IsOffset adjustment)
                Base = 0,
                NoTiffEnd = 1, -- no end-of-TIFF check
            }
            if outfile then
                local writeProc = tagInfo.SubDirectory.WriteProc
                local val = Writer.WriteDirectory(et, subdirInfo, subTable, writeProc)
                if val ~= nil and #val > 0 then
                    -- pad to an even 4 bytes (can't hurt, and it seems to be the standard)
                    if (#val & 0x03) ~= 0 then
                        val = val .. string.rep('\0', 4 - (#val & 0x03))
                    end
                    outBuff:append(tag .. ExifTool.Put32u(#val) .. val)
                elseif val == nil then
                    outBuff:append(data2 .. buff) -- copy over original information
                end
            else
                et:ProcessDirectory(subdirInfo, subTable, tagInfo.SubDirectory.ProcessProc)
            end
        elseif outfile then
            -- add this segment to the output buffer
            local n3, buff = raf:Read(len)
            if n3 ~= len then err = 1 break end
            outBuff:append(data2 .. buff)
        else
            -- skip this segment
            if not raf:Seek(pos + len, 0) then err = 1 break end
        end
        pos = pos + len
    end
    if pos ~= offset then err = 1 end -- meta information length check

    if outfile then
        -- write the file header then the buffered meta information
        if not Writer.Write(outfile, hdr, ExifTool.Put32u(length(outBuff)), outBuff) then rtnVal = -1 end
        -- copy over image data
        while true do
            local n4, chunk = raf:Read(65536)
            if n4 == 0 then break end
            if not Writer.Write(outfile, chunk) then rtnVal = -1 end
        end
        -- Sony IDC utility corrupts MRWInfo when writing ARW images,
        -- so make this a minor error for these images
        if err then et:Error('MRW format error', et.TIFF_TYPE == 'ARW') end
    else
        if err then et:Warn('MRW format error') end
        if not perlTruthy(et.A100DataOffset) then et:ImageDataHash(raf, nil, 'raw') end
    end
    return rtnVal
end

-- (PROCESS_PROC/WRITE_PROC are set here so the table can reference the
-- functions above; upstream has them inline in the table)
MinoltaRaw.Main.PROCESS_PROC = MinoltaRaw.ProcessMRW
MinoltaRaw.Main.WRITE_PROC = MinoltaRaw.WriteMRW

return MinoltaRaw
