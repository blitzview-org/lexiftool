--------------------------------------------------------------------------------
-- File:         lexiftool/Kandao.lua
-- Ported from:  lib/Image/ExifTool/Kandao.pm
--
-- Description:  Read Kandao MP4 metadata
--
-- Revisions:    2025-12-10 - P. Harvey Created
--
-- Notes:        Tested with videos from the Kandao QooCam 3 Ultra
--
-- Port notes:   complete: all five tables (Main, GPS, GPSX, IMU, FrameISP),
--               ProcessKandao and ProcessKVAR.  Wired where upstream wires
--               it: the KVAR file-type dispatch in lexiftool.lua and the
--               'kvar'/'kfix'/'kstb' atoms in QuickTime.Main (which also
--               needed ProcessMOV to pass a BlockInfo along for
--               BlockExtract tags, as upstream does).
--               Perl scalar references map onto this port's
--               `{ref='SCALAR', value=...}` tuple (the U8[x] block values).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
-- (GPS is required at the point of use, not at the top: a top-level require
--  would load it for every file that loads this module, and
--  BuildCompositeTags derives its worklist from `package.loaded`)
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local Get32u = ExifTool.Get32u
local ReadValue = ExifTool.ReadValue
local SetByteOrder = ExifTool.SetByteOrder
local perlTruthy = ExifTool.perlTruthy

local Kandao = {}

-- Kandao format codes
local format = {
    CHAR = 'string',
    BOOL = 'int8u',
    U8   = 'int8u',
    U16  = 'int16u',
    U32  = 'int32u',
    U64  = 'int64u',
    S8   = 'int8s',
    S16  = 'int16s',
    S32  = 'int32s',
    S64  = 'int64s',
    FLOAT = 'float',
    DOUBLE = 'double',
}

-- Kandao 'kvar' and 'kfix' information
Kandao.Main = {
    GROUPS = { [0] = 'Kandao', [1] = 'KVAR', [2] = 'Camera' },
    VARS = { NO_LOOKUP = 1 },
    NOTES = [[
        Tags extracted from Kandao KVAR files and the 'kvar', 'kfix' and 'kstb'
        atoms in Kandao MP4 videos, with a family 1 group name of KVAR, KFIX or KSTB
        depending on their location.
    ]],
    PROCESS_PROC = false, -- predeclaration, see below for implementation
--
-- 'kvar' tags
--
    CPU_TEMP = { Name = 'CPUTemperature', ValueConv = function(_self, val) return val / 10 end }, -- U32[1]
    BAT_TEMP = 'BatteryTemperature', -- U32[1]
    PTS_UNIT = { -- U32[1]
        Name = 'TimeStampUnit',
        PrintConv = { [0] = 'ms', [1] = 'Subtle', [2] = 'ns' },
    },
    TOTAL_FRAME = 'TotalFrames', -- U32[1]
    TOTAL_TIME_MS = { -- U32[1]
        Name = 'TotalTime',
        ValueConv = function(_self, val) return val / 1000 end,
    },
    LENS = 'LensData', -- CHAR[534]
    DASHBOARD = 'Dashboard', -- U8[1]
    PROJECTION   = 'Projection', -- CHAR[16]
    CENTER_SHIFT = 'CenterShift', -- DOUBLE[1]
    DISTORTION   = 'Distortion', -- DOUBLE[1]
    INFO = 'Info', -- CHAR[239]
    PTS = {
        Name = 'PresentationTimeStamp',
        Notes = 'TimeStamp for each frame',
        Format = 'undef', -- U64[x]
        Binary = 1,
    },
    LENS_SN0 = 'Lens0SerialNumber', -- CHAR[15]
    LENS_SN1 = 'Lens1SerialNumber', -- CHAR[15]
    LENS_OTP_ID0 = 'Lens0OTP_ID', -- U8[1]
    LENS_OTP_ID1 = 'Lens1OTP_ID', -- U8[1]
    IMU = {
        RecordSize = 20,
        SubDirectory = { TagTable = 'lexiftool.Kandao.IMU' },
    },
    GPS = {{
        Condition = function(_self, val) return (perl.matches(val, [[^\xff{4}]])) end,
        RecordSize = 28,
        SubDirectory = {
            TagTable = 'lexiftool.Kandao.GPS',
            Start = 4,
        },
    },{
        RecordSize = 20,
        SubDirectory = {
            TagTable = 'lexiftool.Kandao.GPS',
        },
    }},
    GPSX = {
        RecordSize = 36,
        SubDirectory = { TagTable = 'lexiftool.Kandao.GPSX' },
    },
    EXP = { -- U8[x]
        -- actually int64u - monotonically increasing
        Name = 'Exp',
    },
    -- (ISP = Image Signal Processor)
    ISP = 'ISP', -- U8 - 46-byte records (not very interesting looking)
    FRAME_ISP = {
        -- U8 - 12-byte records: int32u-ts, float, float
        RecordSize = 12,
        SubDirectory = { TagTable = 'lexiftool.Kandao.FrameISP' },
    },
    GAINMAP0 = 'GainMap0',
    GAINMAP1 = 'GainMap1',
--
-- 'kfix' tags
--
    PRODUCT = 'Model',
    PROJECT = 'Project',
    SN = 'SerialNumber',
    PR_VER = 'ProductVersion',
    SW_VER = 'SoftwareVersion',
    HW_VER = 'HardwareVersion',
    VIDEO_CAPTIME = {
        Name = 'VideoCaptureTime',
        Notes = 'local camera time',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return perl.subst(val, [[^(\d{4})-(\d{2})-]], '$1:$2:') end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    GPS_CAPTIME = {
        Name = 'GPSCaptureTime',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val / 1000, 0, 3) .. 'Z' end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    LENS_INDEX = { Name = 'LensIndex', Format = 'int16u' },
    NEED_LSC = 'NeedLDSC',
    -- (also in 'kvar') CPU_TEMP => { Name => 'CPUTemperature', ValueConv => '$val / 10' },
    -- (also in 'kvar') BAT_TEMP => 'BatteryTemperature',
    INPUT_INSERT = 'InputInsert',
    VIDEO_RESOLUTION = 'VideoResolution',
    VIDEO_CODECTYPE = 'VideoCodec',
    VIDEO_BITRATE = { Name = 'VideoBitrate',
        PrintConv = function(_self, val) return ExifTool.NumStr(val / 1e6) .. ' Mbps' end },
    VIDEO_FORMAT = 'VideoFormat',
    OUTPUT_INSERT = 'OutputInsert',
    DYNAMIC_RANGE = 'DynamicRange',
    AWB_CCT = 'AWB_CCT',
    EV = 'EV',
    ISO = 'ISO',
    SHUTTER = 'Shutter',
    IMAGE_STYLE = 'ImageStyle',
    AE_METERING = 'AEMetering',
    CAPTURE_MODE = 'CaptureMode',
    HDR = 'HDR',
    STITCHED = 'Stitched',
    COVER_MODE = 'CoverMode',
    STEREO = 'Stereo',
    FOV = 'FOV',
    AE_MODE = 'AEMode',
    AF_FN = 'AF_FN',
    AWB_MODE = 'AWBMode',
    AUDIO_GAIN = 'AudioGain',
    INTERVAL = 'Interval',
    ISP_VER = 'ISPVersion',
    YAW = 'Yaw',
    FAN_LEVEL = 'FanLevel',
    FAN_MODE = 'FanMode',
    CUSTOMIZED = 'Customized',
}

Kandao.GPS = {
    GROUPS = { [0] = 'Kandao', [1] = 'KVAR', [2] = 'Location' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = [[
        These tags are in the family 1 KVAR group instead of a GPS group to allow
        them to be distinguished from the duplicate GPS tags in the GPSX table.
    ]],
    [0] = { Name = 'TimeStamp', Format = 'int32u' },
    [4] = {
        Name = 'GPSLatitude',
        Format = 'double',
        ValueConv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1) end,
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [12] = {
        Name = 'GPSLongitude',
        Format = 'double',
        ValueConv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1) end,
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [20] = { -- (optional)
        Name = 'GPSAltitude',
        Format = 'double',
        PrintConv = function(_self, val)
            local _ = sprintf('%.6f', val)
            _ = perl.subst(_, [[\.?0+$]], '')
            return _ .. ' m'
        end,
    },
}

Kandao.GPSX = {
    GROUPS = { [0] = 'Kandao', [1] = 'GPS', [2] = 'Location' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = [[
        These tags are in the family 1 GPS group.  They are duplicates of the tags
        in the Kandao GPS table with the addition of GPSDateTime.
    ]],
    [0] = { Name = 'TimeStamp', Format = 'int32u' },
    [4] = {
        Name = 'GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        Format = 'int64u',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val / 1000, 0, 3) .. 'Z' end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [12] = {
        Name = 'GPSLatitude',
        Format = 'double',
        ValueConv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1) end,
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'N') end,
    },
    [20] = {
        Name = 'GPSLongitude',
        Format = 'double',
        ValueConv = function(_self, val) return require('lexiftool.GPS').ToDegrees(val, 1) end,
        PrintConv = function(self, val) return require('lexiftool.GPS').ToDMS(self, val, 1, 'E') end,
    },
    [28] = {
        Name = 'GPSAltitude',
        Format = 'double',
        PrintConv = function(_self, val)
            local _ = sprintf('%.6f', val)
            _ = perl.subst(_, [[\.?0+$]], '')
            return _ .. ' m'
        end,
    },
}

-- IMU gyroscope data
Kandao.IMU = {
    GROUPS = { [0] = 'Kandao', [1] = 'KVAR', [2] = 'Location' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0] = { Name = 'TimeStamp',     Format = 'int64u' },
    [8] = { Name = 'Gyroscope',     Format = 'int16s[3]' }, -- 2G max range
    [14]= { Name = 'Accelerometer', Format = 'int16s[3]' }, -- 2000 deg/sec max range
    -- (Kandao docs mention optional 6-byte Magnetometer data here, but
    --  with no way to determine if it exists, and it isn't in my samples)
}

-- (ISP = Image Signal Processor?)
Kandao.FrameISP = {
    GROUPS = { [0] = 'Kandao', [1] = 'KVAR', [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0] = { Name = 'TimeStamp',  Format = 'int32u',   Unknown = 1 },
    [4] = { Name = 'FrameISP_4', Format = 'float[2]', Unknown = 1 },
}

--------------------------------------------------------------------------------
-- Extract information from a Kandao 'kfix' and 'kvar' atoms
-- Inputs: 0) ExifTool ref, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function Kandao.ProcessKandao(et, dirInfo, tagTbl)
    local raf = dirInfo.RAF
    if not raf then raf = require('lexiftool.RandomAccess').new(dirInfo.DataPt) end
    local dirName = dirInfo.DirName
    local dataPos = (dirInfo.DataPos or 0) + (dirInfo.Base or 0)
    local verbose = et:Options('Verbose')
    local ee = et:Options('ExtractEmbedded')
    -- extract as a block from MP4 if specified
    if dirInfo.BlockInfo then
        local blockName = dirInfo.BlockInfo.Name
        local blockExtract = et:Options('BlockExtract')
        if blockExtract or (et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lc(blockName)]) or
            (et.TAGS_FROM_FILE and not (et.EXCL_TAG_LOOKUP and et.EXCL_TAG_LOOKUP[lc(blockName)]))
        then
            et:FoundTag(dirInfo.BlockInfo, dirInfo.DataPt)
            if blockExtract and blockExtract > 1 then return 1 end
        end
    end
    local buff, err, fmt
    SetByteOrder('II')
    local n0, hdr = raf:Read(4)
    if n0 ~= 4 then return 0 end
    buff = hdr
    local n = Get32u(buff, 0)
    et:VerboseDir(dirName, n)
    for i = 0, n - 1 do
        local nr
        nr, buff = raf:Read(0x2c)
        if nr ~= 0x2c then err = '' break end
        local tag = perl.subst(substr(buff, 0, 0x20), [[\0+$]], '')
        fmt = perl.subst(substr(buff, 0x20, 8), [[\0+$]], '')
        local fmtName = format[fmt]
        if not fmtName then err = "Unknown Kandao format '" .. fmt .. "'" break end
        local num = Get32u(buff, 0x28)
        local size = num * ExifTool.FormatSize(fmtName)
        -- (upstream's %parms holds a REFERENCE to $buff, so it picks up the
        --  value bytes read on the next line; DataPos is the file position
        --  of those bytes, i.e. Tell() before the read)
        local parms = {
            DataPt  = nil,
            DataPos = dataPos + raf:Tell(),
            Index   = i,
            Format  = fmtName,
        }
        local nd
        nd, buff = raf:Read(size)
        if nd ~= size then err = '' break end
        parms.DataPt = buff
        local tagInfo = et:GetTagInfo(tagTbl, tag, buff)
        if not tagInfo then
            local name = ucfirst(lc(tag))
            name = perl.subst(name, [[_([a-z])]], function(c) return '_' .. uc(c) end, 'g')
            name = ExifTool.MakeTagName(name)
            et:VPrint(0, et.INDENT .. '[adding ' .. dirName .. " '" .. tag .. "']\n")
            tagInfo = et:AddTagToTable(tagTbl, tag, { Name = name })
        end
        local recLen = tagInfo.RecordSize
        if recLen then
            if perlTruthy(verbose) then et:VerboseInfo(tag, tagInfo, parms) end
            local tbl = et:GetTagTable(tagInfo.SubDirectory.TagTable)
            local pt = tagInfo.SubDirectory.Start or 0
            local subDirInfo = {
                DataPt  = buff,
                DataPos = parms.DataPos,
                DirLen  = recLen,
                DirName = tag,
            }
            local nLimit = 10000
            local sizeLimit = size
            if perlTruthy(ee) and (size - pt) // recLen > nLimit and
                perlTruthy(et:Warn('Extracting only the first ' .. nLimit .. ' ' .. tagInfo.Name .. ' records', 2))
            then
                sizeLimit = pt + recLen * nLimit
            end
            while pt + recLen <= sizeLimit do
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                subDirInfo.DirStart = pt
                et:ProcessDirectory(subDirInfo, tbl)
                if not perlTruthy(ee) then
                    et:Warn('Use the ExtractEmbedded option to extract all timed metadata', 7)
                    break
                end
                pt = pt + recLen
            end
            et.DOC_NUM = nil
        else
            local val
            if fmt == 'U8' and num > 1 and not tagInfo.Format then
                val = { ref = 'SCALAR', value = buff }
            else
                -- override format if necessary
                if tagInfo.Format then
                    fmtName = tagInfo.Format
                    parms.Format = parms.Format .. ' read as ' .. fmtName
                    num = size // ExifTool.FormatSize(fmtName)
                end
                val = ReadValue(buff, 0, fmtName, num, size)
            end
            local key = et:HandleTag(tagTbl, tag, val, parms)
            if dirName ~= 'KVAR' then et:SetGroup(key, dirName) end
        end
    end
    if err ~= nil then et:Warn(err ~= '' and err or ('Truncated ' .. dirName .. ' record')) end
    return 1
end

--------------------------------------------------------------------------------
-- Process Kandao KVAR file
-- Inputs: 0) ExifTool ref, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid KVAR file
--------------------------------------------------------------------------------
function Kandao.ProcessKVAR(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, tagTablePtr

    -- verify this is a valid KVAR file
    local nr
    nr, buff = raf:Read(44)
    if nr ~= 44 then return 0 end
    if not perl.matches(buff, [[(?s)^.{2}\0\0[A-Z].{31}(CHAR|BOOL|[US](8|16|32|64)|FLOAT|DOUBLE)\0]]) then return 0 end
    et:SetFileType('KVAR', 'application/x-kandaostudio')
    if not raf:Seek(0, 0) then et:Warn('Seek error') return 1 end
    dirInfo.DirName = 'KVAR'
    tagTablePtr = et:GetTagTable('lexiftool.Kandao.Main')
    return et:ProcessDirectory(dirInfo, tagTablePtr)
end

Kandao.Main.PROCESS_PROC = Kandao.ProcessKandao

return Kandao
