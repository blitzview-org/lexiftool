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
-- Port notes:   complete.  `Main` dispatches the four MRW segments
--               (TTW/PRD/WBG/RIF); the TTW (embedded TIFF/EXIF) segment is
--               handed to the generic ProcessTIFF.  ProcessMRW also reads MRW
--               information held in memory (`DataPt`: the MRWInfo directory
--               and the A100 MRW block of Sony ARW images, Sony.ProcessSR2).
--               WriteMRW is ported, the segment tables carry upstream's
--               WRITE_PROC/CHECK_PROC.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local matches = require('lexiftool.perl').matches
local isMatch = require('lexiftool.perl').isMatch
local perlTruthy = require('lexiftool.perl').truthy
local length = require('lexiftool.perl').length
local int = require('lexiftool.perl').int
local num = require('lexiftool.perl').num
local log = require('lexiftool.perl').log
local substr = require('lexiftool.perl').substr
local printf = require('lexiftool.perl').printf
local print = require('lexiftool.perl').print
local carray = require('carray')
local RandomAccess = require('lexiftool.RandomAccess')
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder = ExifTool.SetByteOrder
local Get32u = ExifTool.Get32u
local Put32u = ExifTool.Put32u   -- (Perl's one-argument Set32u)

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
            if self.FILE_TYPE == 'MRW' then self.MinoltaPRD = 1 end
            return val
        end,  -- used in decoding RIF info
    },
    [8] = {
        Name = 'SensorHeight',
        Format = 'int16u',
    },
    [10] = {
        Name = 'SensorWidth',
        Format = 'int16u',
    },
    [12] = {
        Name = 'ImageHeight',
        Format = 'int16u',
    },
    [14] = {
        Name = 'ImageWidth',
        Format = 'int16u',
    },
    [16] = {
        Name = 'RawDepth',
        Format = 'int8u',
    },
    [17] = {
        Name = 'BitDepth',
        Format = 'int8u',
    },
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
            Condition = function(self) return isMatch(self.Model, [[DiMAGE A200\b]]) end,
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
MinoltaRaw.RIF = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = function(...) return require('lexiftool.Writer').CheckBinaryData(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FIRST_ENTRY = 0,
    [1] = {
        Name = 'Saturation',
        Format = 'int8s',
    },
    [2] = {
        Name = 'Contrast',
        Format = 'int8s',
    },
    [3] = {
        Name = 'Sharpness',
        Format = 'int8s',
    },
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
            -- have seen these values in Sony ARW images: - PH
            -- 7, 128, 129, 160
        },
    },
    [6] = {
        Name = 'ISOSetting',
        RawConv = function(_self, val) if val == 255 then return nil end return val end,
        PrintConv = { --#3
            [0] = 'Auto',
            [48] = 100,
            [56] = 200,
            [64] = 400,
            [72] = 800,
            [80] = 1600,
            [174] = '80 (Zone Matching Low)',
            [184] = '200 (Zone Matching High)',
            OTHER = function(val, inv)
                if not inv then return int(2 ^ ((val - 48) / 8) * 100 + 0.5) end
                -- (must check for zero below in inverse conversion)
                if ExifTool.IsFloat(val) and num(val) ~= 0 then return 48 + 8 * log(val / 100) / log(2) end
                return nil
            end,
        },
        --ValueConv = '2 ** (($val-48)/8) * 100',
        --ValueConvInv = '48 + 8*log($val/100)/log(2)',
        --PrintConv = 'int($val + 0.5)',
        --PrintConvInv = '$val',
    },
    [7] = {
        {
            Name = 'ColorMode',
            Condition = function(self) return not isMatch(self.Make, [[^SONY]]) end,
            Priority = 0,
            Writable = 1,
            PrintConv = require('lexiftool.Minolta').minoltaColorMode,
        },
        { --#3
            Name = 'ColorMode',
            Condition = function(self) return self.Model == 'DSLR-A100' end,
            Writable = 1,
            Notes = 'Sony A100',
            Priority = 0,
            PrintHex = 1,
            PrintConv = require('lexiftool.Minolta').sonyColorMode,
        },
    },
    -- NOTE: WB_RBLevels up to Custom also apply to Minolta models which write PRD info (ref IB)
    [8]  = { --#3
        Name = 'WB_RBLevelsTungsten',
        Condition = function(self) return self.Model == 'DSLR-A100' or perlTruthy(self.MinoltaPRD) end,
        Format = 'int16u[2]',
        Notes = 'these WB_RBLevels currently decoded only for the Sony A100',
    },
    [12] = { --#3
        Name = 'WB_RBLevelsDaylight',
        Condition = function(self) return self.Model == 'DSLR-A100' or perlTruthy(self.MinoltaPRD) end,
        Format = 'int16u[2]',
    },
    [16] = { --#3
        Name = 'WB_RBLevelsCloudy',
        Condition = function(self) return self.Model == 'DSLR-A100' or perlTruthy(self.MinoltaPRD) end,
        Format = 'int16u[2]',
    },
    [20] = { --#3
        Name = 'WB_RBLevelsCoolWhiteF',
        Condition = function(self) return self.Model == 'DSLR-A100' or perlTruthy(self.MinoltaPRD) end,
        Format = 'int16u[2]',
    },
    [24] = { --#3
        Name = 'WB_RBLevelsFlash',
        Condition = function(self) return self.Model == 'DSLR-A100' or perlTruthy(self.MinoltaPRD) end,
        Format = 'int16u[2]',
    },
    [28] = { --#3
        Name = 'WB_RBLevelsCustom', --#IB
        Condition = function(self) return self.Model == 'DSLR-A100' or perlTruthy(self.MinoltaPRD) end,
        Format = 'int16u[2]',
    },
    [32] = { --#3
        Name = 'WB_RBLevelsShade',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [36] = { --#3
        Name = 'WB_RBLevelsDaylightF',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [40] = { --#3
        Name = 'WB_RBLevelsDayWhiteF',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [44] = { --#3
        Name = 'WB_RBLevelsWhiteF',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Format = 'int16u[2]',
    },
    [56] = {
        Name = 'ColorFilter',
        Condition = function(self) return not isMatch(self.Make, [[^SONY]]) end,
        Format = 'int8s',
        Notes = 'Minolta models',
    },
    [57] = 'BWFilter',
    [58] = {
        Name = 'ZoneMatching',
        Condition = function(self) return not isMatch(self.Make, [[^SONY]]) end,
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
        Condition = function(self) return not isMatch(self.Make, [[^SONY]]) end,
        Notes = 'Minolta models',
        ValueConv = function(_self, val) return val * 100 end,
        ValueConvInv = function(_self, val) return val / 100 end,
    },
    [74] = { --#3
        Name = 'ZoneMatching',
        Condition = function(self) return isMatch(self.Make, [[^SONY]]) end,
        Priority = 0,
        Notes = 'Sony models',
        PrintConv = {
            [0] = 'ISO Setting Used',
            [1] = 'High Key',
            [2] = 'Low Key',
        },
    },
    [76] = { --#3
        Name = 'ColorTemperature',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Notes = 'A100',
        ValueConv = function(_self, val) return val * 100 end,
        ValueConvInv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) if perlTruthy(val) then return val end return 'Auto' end,
        PrintConvInv = function(_self, val) if isMatch(val, [[(?i)Auto]]) then return 0 end return val end,
    },
    [77] = { --#3
        Name = 'ColorFilter',
        Condition = function(self) return self.Model == 'DSLR-A100' end,
        Notes = 'A100',
    },
    [78] = { --#3
        Name = 'ColorTemperature',
        Condition = function(self) return isMatch(self.Model, [[^DSLR-A(200|700)$]]) end,
        Notes = 'A200 and A700',
        ValueConv = function(_self, val) return val * 100 end,
        ValueConvInv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) if perlTruthy(val) then return val end return 'Auto' end,
        PrintConvInv = function(_self, val) if isMatch(val, [[(?i)Auto]]) then return 0 end return val end,
    },
    [79] = { --#3
        Name = 'ColorFilter',
        Condition = function(self) return isMatch(self.Model, [[^DSLR-A(200|700)$]]) end,
        Notes = 'A200 and A700',
    },
    [80] = { --#3
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
function MinoltaRaw.ProcessMRW(et, dirInfo, tagTablePtr) -- luacheck: ignore tagTablePtr
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local data, err, outBuff, n
    local Writer = require('lexiftool.Writer')   -- (Writer.pl, autoloaded upstream)

    if perlTruthy(dirInfo.DataPt) then
        -- make a RAF object for MRW information extracted from other file types
        raf = RandomAccess.new(dirInfo.DataPt)
        -- MRW information in DNG images may not start at beginning of data block
        if perlTruthy(dirInfo.DirStart) then raf:Seek(dirInfo.DirStart, 0) end
    end
    n, data = raf:Read(8)
    if n ~= 8 then return 0 end
    -- "\0MRM" for big-endian (MRW images), and
    -- "\0MRI" for little-endian (MRWInfo in ARW images)
    local m1 = matches(data, [[^\0MR([MI])]])
    if not m1 then return 0 end
    local hdr = '\0MR' .. m1
    SetByteOrder(m1 .. m1)
    et:SetFileType()
    tagTablePtr = GetTagTable(et, 'lexiftool.MinoltaRaw.Main')
    if outfile then
        Writer.InitWriteDirs(et, 'TIFF') -- use same write dirs as TIFF
        outBuff = carray.new('char')
    end
    local pos = raf:Tell()
    local offset = Get32u(data, 4) + pos
    local rtnVal = 1
    if perlTruthy(verbose) then printf(out, "  [MRW Data Offset: 0x%x]\n", offset) end
    -- loop through MRW segments (ref 1)
    while pos < offset do
        n, data = raf:Read(8)
        if n ~= 8 then err = 1 break end
        pos = pos + 8
        local tag = substr(data, 0, 4)
        local len = Get32u(data, 4)
        if perlTruthy(verbose) then
            print(out, "MRW ", et:Printable(tag), " segment (", len, " bytes):\n")
            if num(verbose) > 2 then
                n, data = raf:Read(len)
                if not (n == len and raf:Seek(pos, 0)) then err = 1 break end
                et:VerboseDump(data)
            end
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if tagInfo and tagInfo.SubDirectory then
            local subTable = GetTagTable(et, tagInfo.SubDirectory.TagTable)
            local buff
            -- save shift for values stored with wrong base offset
            et.MRW_WrongBase = -(raf:Tell())
            n, buff = raf:Read(len)
            if n ~= len then err = 1 break end
            local subdirInfo = {
                DataPt = buff,
                DataLen = len,
                DataPos = pos,
                DirStart = 0,
                DirLen = len,
                DirName = tagInfo.Name,
                Parent = 'MRW',
                NoTiffEnd = 1, -- no end-of-TIFF check
            }
            if outfile then
                local writeProc = tagInfo.SubDirectory.WriteProc
                local val = Writer.WriteDirectory(et, subdirInfo, subTable, writeProc)
                if val ~= nil and length(val) > 0 then
                    -- pad to an even 4 bytes (can't hurt, and it seems to be the standard)
                    if (length(val) & 0x03) ~= 0 then val = val .. ('\0'):rep(4 - (length(val) & 0x03)) end
                    outBuff:append(tag .. Put32u(length(val)) .. val)
                elseif val == nil then
                    outBuff:append(data .. buff)  -- copy over original information
                end
            else
                local processProc = tagInfo.SubDirectory.ProcessProc
                et:ProcessDirectory(subdirInfo, subTable, processProc)
            end
        elseif outfile then
            -- add this segment to the output buffer
            local buff
            n, buff = raf:Read(len)
            if n ~= len then err = 1 break end
            outBuff:append(data .. buff)
        else
            -- skip this segment
            if not raf:Seek(pos + len, 0) then err = 1 break end
        end
        pos = pos + len
    end
    if pos ~= offset then err = 1 end    -- meta information length check

    if outfile then
        -- write the file header then the buffered meta information
        if not Writer.Write(outfile, hdr, Put32u(length(outBuff)), outBuff) then rtnVal = -1 end
        -- copy over image data
        while true do
            n, outBuff = raf:Read(65536)
            if not perlTruthy(n) then break end
            if not Writer.Write(outfile, outBuff) then rtnVal = -1 end
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
