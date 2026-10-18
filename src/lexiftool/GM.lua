--------------------------------------------------------------------------------
-- File:         lexiftool/GM.lua
-- Ported from:  lib/Image/ExifTool/GM.pm
--
-- Description:  Read GM PDR metadata from automobile videos
--
-- Revisions:    2024-04-01 - P. Harvey Created
--
-- References:   1) https://exiftool.org/forum/index.php?topic=11335
--
-- Port notes:   complete: all four tables (mrlh, mrlv, mrld, marl), the
--               %channelStruct structure definition and PrintCSV,
--               Process_mrlv, Process_mrld and Process_marl.
--               Deviations forced by Lua:
--               - Perl's sparse arrays (@$gmDict, @$csv, @$vals -- all
--                 indexed by channel number, starting at 0) become plain
--                 tables with an explicit `n` = highest index + 1, since
--                 `#t` is undefined for a table with holes.
--               - upstream's unqualified `PrintableTagID` call in
--                 Process_mrlv resolves to nothing (the sub lives in
--                 QuickTime.pm and is not imported), so that error branch
--                 dies in Perl; this port calls the helper that this port
--                 keeps in GoPro.lua, lazily so loading GM never drags
--                 GoPro's Composite table into BuildCompositeTags.
--               - a running channel number that leaves the dictionary's
--                 range is simply skipped here; Perl's negative array index
--                 would wrap around and read a channel from the END of
--                 @$gmDict instead.  Only reachable on malformed data.
--               Wired where upstream wires it: the 'mrlh'/'mrlv'/'mrld'
--               atoms of QuickTime.OtherSampleDesc (a table this port only
--               gained now) and the 'marl' entry plus the 'ctbx' handler
--               type in QuickTimeStream.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local GPS = require('lexiftool.GPS')
local perl = require('lexiftool.perl')
local uv = perl.uv
local unpack_ = perl.unpack
local sprintf = perl.sprintf
local perlStr = perl.str
local GetDouble = ExifTool.GetDouble
local Get64u = ExifTool.Get64u

local GM = {}

-- Perl `int()` truncates toward zero (unlike Lua's math.floor, which rounds
-- down for negative values)
local function int(v)
    if v >= 0 then return math.floor(v) end
    return math.ceil(v)
end

-- rename some units strings
local convertUnits = {
    ["\xc2\xb0"] = 'deg',
    ["\xc2\xb0C"] = 'C',
    ["\xc2\xb0/sec"] = 'deg/sec',
    ltr = 'L',
}

local pi = 3.141592653589793

-- offsets and scaling factors to convert to reasonable units
local changeOffset = {
    C = -273.15,           -- K to C
}
local changeScale = {
    G = 1 / 9.80665,       -- m/s2 to G
    kph = 3.6,             -- m/s to km/h
    deg = 180 / pi,        -- radians to degrees
    ['deg/sec'] = 180 / pi, -- rad/s to deg/s
    ['%'] = 100,           -- decimal to %
    kPa = 1/1000,          -- Pa to kPa
    rpm = 10,              -- ? (arbitrary factor of 10)
    km = 1/1000,           -- m to km
    L = 1000,              -- m3 to L
    mm = 1000,             -- m to mm
}

-- default print conversions for various types of units
local printConv = {
    rpm = function(_self, val) return sprintf('%.2f rpm', val) end,
    ['%'] = function(_self, val) return sprintf('%.2f %%', val) end,
    kPa = function(_self, val) return sprintf('%.2f kPa', val) end,
    G   = function(_self, val) return sprintf('%.3f G', val) end,
    km  = function(_self, val) return sprintf('%.3f km', val) end,
    kph = function(_self, val) return sprintf('%.2f km/h', val) end,
    deg = function(_self, val) return sprintf('%.2f deg', val) end,
    ['deg/sec'] = function(_self, val) return sprintf('%.2f deg/sec', val) end,
}

-- channel parameters extracted from marl dictionary
local channel = {
    'ID', 'Type', 'Num', 'Units', 'Flags', 'Interval', 'Min', 'Max', 'DispMin', 'DispMax', 'Multiplier', 'Offset',
    'Name', 'Description',
}
local channelStruct = {
    STRUCT_NAME = 'GM Channel',
    NOTES = 'Information stored for each channel in the Marlin dictionary.',
    SORT_ORDER = channel,
    ID      = { Writable = 0, Notes = 'channel ID number' },
    Type    = { Writable = 0, Notes = 'measurement type' },
    Num     = { Writable = 0, Notes = 'units ID number' },
    Units   = { Writable = 0, Notes = 'units string' },
    Flags   = { Writable = 0, Notes = 'channel flags' },
    Interval= { Writable = 0, Notes = 'measurement interval', ValueConv = function(_self, val) return val / 1e7 end,
        PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' s' end },
    Min     = { Writable = 0, Notes = 'raw value minimum' },
    Max     = { Writable = 0, Notes = 'raw value maximum' },
    DispMin = { Writable = 0, Notes = 'displayed value minimum' },
    DispMax = { Writable = 0, Notes = 'displayed value maximum' },
    Multiplier={Writable = 0, Notes = 'multiplier for raw value' },
    Offset  = { Writable = 0, Notes = 'offset for scaled value' },
    Name    = { Writable = 0, Notes = 'channel name' },
    Description={Writable= 0, Notes = 'channel description' },
}

-- tags found in the 'mrlh' (marl header) atom
GM.mrlh = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'The Marlin PDR header.',
    [0] = { Name = 'MarlinDataVersion', Format = 'int16u[2]',
        PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '.')) end },
}

-- tags found in the 'mrlv' (Marlin values) atom
GM.mrlv = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    FORMAT = 'string',
    NOTES = [[Tags found in the 'mrlv' (Marlin values) box.]],
    ['time']= { Name = 'Time1', Groups = { [2] = 'Time' }, ValueConv = function(_self, val) return (val:gsub('%-', ':')) end },
    date = { Name = 'Date1', Groups = { [2] = 'Time' }, ValueConv = function(_self, val) return (val:gsub('%-', ':')) end },
    ltim = { Name = 'Time2', Groups = { [2] = 'Time' }, ValueConv = function(_self, val) return (val:gsub('%-', ':')) end },
    ldat = { Name = 'Date2', Groups = { [2] = 'Time' }, ValueConv = function(_self, val) return (val:gsub('%-', ':')) end },
    tstm = {
        Name = 'StartTime',
        Groups = { [2] = 'Time' },
        Format = 'int64u',
        RawConv = function(self, val) self.GMStartTime = val / 1e7 return self.GMStartTime end,
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val, nil, 6) end, -- (likely UTC, but not sure so don't add time zone)
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    zone = { Name = 'TimeZone', Groups = { [2] = 'Time' } },
    lang = 'Language',
    unit = { Name = 'Units', PrintConv = { usim = 'U.S. Imperial' } },
    swvs = 'SoftwareVersion',
    -- id   ? ""
    -- cntr ? ""
    -- flap ? ""
}

-- tags found in the 'mrld' (Marlin dictionary) atom
GM.mrld = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    VARS = { ADD_FLATTENED = 1 },
    WRITABLE = 0,
    NOTES = [[
        The Marlin dictionary.  Only one channel is listed but all available
        channels are extracted.  Use the -struct (L<API Struct|../ExifTool.html#Struct>) option to extract the
        channel information as structures.
    ]],
    Channel01 = { Struct = channelStruct },
}

-- tags found in 'marl' ctbx timed metadata
GM.marl = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Other' },
    VARS = { ID_FMT = 'none', NO_LOOKUP = 1 },
    NOTES = [[
        Tags extracted from the 'ctbx' 'marl' (Marlin) box of timed PDR metadata
        from GM cars.  Use the -ee (L<API ExtractEmbedded|../ExifTool.html#ExtractEmbedded>) option to extract this
        information, or the L<API PrintCSV|../ExifTool.html#PrintCSV> option to output in CSV format.
    ]],
    TimeStamp = { -- (the marl timestamp)
        Groups = { [2] = 'Time' },
        Notes = [[
            the numerical value is seconds since start of video, but the print
            conversion adds StartTime to provide a date/time value.  Extracted as
            GPSDateTime if requested
        ]],
        ValueConv = function(_self, val) return val / 1e7 end,
        PrintConv = function(self, val)
            if not self.GMStartTime then return ExifTool.NumStr(val) .. ' s' end
            return self:ConvertDateTime(ExifTool.ConvertUnixTime(val + self.GMStartTime, nil, 6))
        end,
    },
    GPSDateTime = { -- (alternative for TimeStamp)
        Groups = { [2] = 'Time' },
        Notes = 'generated from the TimeStamp only if specifically requested',
        RawConv = function(self, val) if self.GMStartTime then return val end return nil end,
        ValueConv = function(self, val) return ExifTool.ConvertUnixTime(val / 1e7 + self.GMStartTime) .. 'Z' end,
        PrintConv = function(self, val) return self:ConvertDateTime(val, nil, 6) end,
    },
    Latitude = {
        Name = 'GPSLatitude',
        Description = 'GPS Latitude', -- (need description so we don't set it from the mrld)
        Groups = { [2] = 'Location' },
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    },
    Longitude = {
        Name = 'GPSLongitude',
        Description = 'GPS Longitude',
        Groups = { [2] = 'Location' },
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    },
    Altitude = {
        Name = 'GPSAltitude',
        Description = 'GPS Altitude',
        Groups = { [2] = 'Location' },
    },
    Heading = {
        Name = 'GPSTrack',
        Description = 'GPS Track',
        Groups = { [2] = 'Location' },
        PrintConv = function(_self, val) if val > 360 then return 'n/a' end return sprintf('%.2f', val) end, -- (seen 655.35)
    },
    ABSActive = { },
    AccelPos = { },
    BatteryVoltage = { },
    Beacon = { },
    BoostPressureInd = { },
    BrakePos = { },
    ClutchPos = { },
    CoolantTemp = { },
    CornerExitSetting = { },
    CPUFree = { },
    CPUIO = { },
    CPUIRQ = { },
    CPUSystem = { },
    CPUUser = { },
    DiskReadOperations = { },
    DiskReadRate = { },
    DiskReadTime = { },
    DiskWriteOperations = { },
    DiskWriteRate = { },
    DiskWriteTime = { },
    Distance = { },
    DriverPerformanceMode = { },
    EngineSpeedRequest = { },
    EngineTorqureReq = { },
    FuelCapacity = { },
    FuelLevel = { },
    Gear = {
        Notes = [[
            in the PrintCSV output, the value for Neutral is set to -1, and Reverse to
            -100 for compatibility with RaceRender
        ]],
        CSVConv = { [13] = -1, [14] = -100 },
        PrintConv = { [1]=1, [2]=2, [3]=3, [4]=4, [5]=5, [6]=6, [13]='N', [14]='R' }
    },
    GPSFix = { },
    InfotainOpMode = { },
    IntakeAirTemperature = { },
    IntakeBoostPressure = { },
    LateralAcceleration = { },
    LFTyrePressure = { },
    LFTyreTemp = { },
    LongitudinalAcceleration = { },
    LRTyrePressure = { },
    LRTyreTemp = { },
    OilPressure = { },
    OilTemp = { },
    OutsideAirTemperature = { },
    RecordingEventOdometer = { },
    RFTyrePressure = { },
    RFTyreTemp = { },
    RPM = { },
    RRTyrePressure = { },
    RRTyreTemp = { },
    Speed = { Groups = { [2] = 'Location' } },
    SpeedControlResponse = { },
    SpeedRequestIntervention = { },
    Steering1Switch = { },
    Steering2Switch = { },
    SteeringAngle = { },
    SuspensionDisplacementLeftFront = { },
    SuspensionDisplacementLeftRear = { },
    SuspensionDisplacementRightFront = { },
    SuspensionDisplacementRightRear = { },
    SystemBackupPowerEnabled = { },
    SystemBackupPowerMode = { },
    SystemPowerMode = { },
    TractionControlActive = { },
    TransOilTemp = { },
    TransportStorageMode = { },
    ValetMode = { },
    VehicleStabilityActive = { },
    VerticalAcceleration = { },
    WheelspeedLeftDriven = { },
    ['WheelspeedLeftNon-Driven'] = { },
    WheelspeedRightDriven = { },
    ['WheelspeedRightNon-Driven'] = { },
    YawRate = { },
}

--------------------------------------------------------------------------------
-- Print a CSV row
-- Inputs: 0) ExifTool ref, 1) time stamp
function GM.PrintCSV(et, ts)
    local csv = et.GMCsv
    if not csv then return end -- get the list of channels with measurements
    if #csv == 0 then return end
    local vals = et.GMVals
    local gmDict = et.GMDictionary
    local items = {}
    for i = 0, gmDict.n - 1 do items[i] = '' end
    items[0] = (ExifTool.perlTruthy(ts) and ts or et.GMMaxTS) / 1e7
    -- fill in scaled measurements for this TimeStamp
    for _, chan in ipairs(csv) do
        local gmChan = gmDict[chan]
        items[chan] = vals[chan] * gmChan.Mult + gmChan.Off
        -- apply CSV conversion if applicable (ie. Gear)
        if gmChan.Conv and gmChan.Conv[items[chan]] ~= nil then
            items[chan] = gmChan.Conv[items[chan]]
        end
    end
    local out = et.OPTIONS.TextOut or io.stdout
    local strs = {}
    for i = 0, gmDict.n - 1 do strs[i + 1] = ExifTool.NumStr(items[i]) end
    out:write(table.concat(strs, ','), '\n')
    -- clear the channel list (in place: upstream's `@$csv = ()` empties the
    --  very array that Process_marl still holds a reference to)
    for i = #csv, 1, -1 do csv[i] = nil end
end

--------------------------------------------------------------------------------
-- Process GM Marlin values ('mrlv' box)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function GM.Process_mrlv(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dirLen = #dataPt
    local pos = 0
    -- data lengths for known formats
    local fmtLen = {
        strs = 64, lang = 64, strl = 256, ['time'] = 32, date = 32,
        tmzn = 32, tstm = 8, focc = 4, ["kvp\0"] = 64+256,
    }
    et:VerboseDir('mrlv', nil, dirLen)
    while pos + 8 <= dirLen do
        local tag = perl.substr(dataPt, pos, 4)
        local fmt = perl.substr(dataPt, pos + 4, 4)
        local len = fmtLen[fmt]
        if not len then
            local PrintableTagID = require('lexiftool.GoPro').PrintableTagID
            tag, fmt = PrintableTagID(tag), PrintableTagID(fmt)
            et:Warn('Unknown format (' .. fmt .. ') for tag ' .. tag)
            break
        end
        if pos + 8 + len > dirLen then et:Warn('Truncated mrlv data') break end
        et:HandleTag(tagTablePtr, tag, nil, {
            DataPt  = dataPt,
            DataPos = dataPos,
            Start   = pos + 8,
            Size    = len,
        })
        pos = pos + 8 + len
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process GM Marlin dictionary ('mrld' box)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function GM.Process_mrld(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local _ = dirInfo.DataPos  -- (upstream's $dataPos is unused here as well)
    local dirLen = #dataPt
    local struct = perl.num(et:Options('Struct') or 0)
    local gmDict = { n = 0 }
    et.GMDictionary = gmDict
    local marl = et:GetTagTable('lexiftool.GM.marl')
    local pos, csv

    et:VerboseDir('mrld', nil, dirLen)
    local XMP = require('lexiftool.XMP')
    XMP.AddFlattenedTags(tagTablePtr, nil, nil, 1)
    if ExifTool.perlTruthy(et:Options('PrintCSV')) then csv = { n = 0 } end

    pos = 0
    while pos + 448 <= dirLen do
        -- unpack 448-byte records:
        -- 0. int32u - channel number
        -- 1. int32u - measurement type
        -- 2. int32u - units number
        -- 3. string[64] - units string
        -- 4. int32u - flags (0.visible, 1.linear conversion, 2.interpolation OK)
        -- 5. int64u - interval
        -- 6. int32s - min reading
        -- 7. int32s - max reading
        -- 8. double - disp min
        -- 9. double - disp max
        -- 10. double - multiplier
        -- 11. double - offset
        -- 12. string[64] - channel name
        -- 13. string[64] - channel description
        local a = { unpack_('x' .. ExifTool.NumStr(pos) .. 'NNNZ64Na8N2a8a8a8a8Z64Z64', dataPt) }
        local units = convertUnits[a[4]] or a[4]
        a[4] = et:Decode(a[4], 'UTF8')                        -- convert from UTF8
        for _, i in ipairs({ 7, 8 }) do                       -- convert signed ints
            if a[i] & 0x8000000 ~= 0 then a[i] = a[i] - 4294967296 end
        end
        for _, i in ipairs({ 9, 10, 11, 12 }) do a[i] = GetDouble(a[i], 0) end -- convert doubles
        a[6] = Get64u(a[6], 0)                                -- convert 64-bit int
        local chan = a[1]
        local tag = sprintf('Channel%.2d', chan)
        local tagInfo = tagTablePtr[tag]
        local hash = {}
        for i = 2, #a do hash[channel[i]] = a[i] end
        if not tagInfo then
            tagInfo = ExifTool.AddTagToTable(et, tagTablePtr, tag, { Name = tag, Struct = channelStruct })
            XMP.AddFlattenedTags(tagTablePtr, tag, nil, 1)
        end
        -- extract channel structure if specified
        if struct ~= 0 then
            local ordered = {}
            for i = 2, #channel do ordered[#ordered + 1] = channel[i] end
            hash._ordered_keys_ = ordered
            et:FoundTag(tagInfo, hash)
        end
        -- extract flattened channel elements
        if struct == 0 or struct == 2 then
            for i = 2, #a do et:HandleTag(tagTablePtr, tag .. channel[i], a[i]) end
        end
        -- add corresponding tag to marl table
        local name = ExifTool.MakeTagName(a[13])
        tagInfo = marl[name]
        if not tagInfo then
            et:VPrint(0, et.INDENT .. '[adding ' .. name .. ']\n')
            tagInfo = ExifTool.AddTagToTable(et, marl, name, { })
        end
        if not tagInfo.Description then tagInfo.Description = a[14] end
        if not tagInfo.PrintConv then
            -- add a default print conversion
            tagInfo.PrintConv = printConv[units] or
                function(_self, val) return ExifTool.NumStr(val) .. ' ' .. units end
        end
        -- adjust multiplier/offset as necessary to scale to more appropriate units
        -- (ie. to the units actually specified in this dictionary -- d'oh)
        local mult = a[11] * (changeScale[units] or 1)
        local off =  a[12] * (changeScale[units] or 1) + (changeOffset[units] or 0)
        local init = int((a[7] + a[8]) / 2) -- initial value for difference readings
        -- save information about this channel necessary for processing the marl data
        gmDict[chan] = { Name = name, Mult = mult, Off = off, Init = init }
        gmDict[chan].Conv = tagInfo.CSVConv
        if chan + 1 > gmDict.n then gmDict.n = chan + 1 end
        if csv then
            csv[chan] = a[13] .. (a[4] ~= '' and (' (' .. a[4] .. ')') or '')
            if chan + 1 > csv.n then csv.n = chan + 1 end
        end
        pos = pos + 448
    end
    -- channel 0 must not be defined because we use it for the TimeStamp
    if gmDict[0] ~= nil then
        et:Warn('Internal error: PDR channel 0 is used')
        et.GMDictionary = nil
    elseif csv then
        csv[0] = 'Time (s)'
        local strs = {}
        for i = 0, csv.n - 1 do strs[i + 1] = csv[i] or '' end
        local out = et.OPTIONS.TextOut or io.stdout
        out:write(table.concat(strs, ','), '\n')
        et.GMCsv = { }
    end
    et:AddCleanup(GM.PrintCSV) -- print last CSV line when we are done
    -- initialize variables for processing marl box
    et.GMVals = { }
    et.GMMaxTS = 0
    et.GMBadChan = 0
    return 1
end

--------------------------------------------------------------------------------
-- Process GM 'marl' ctbx data (ref PH)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
-- (see https://exiftool.org/forum/index.php?topic=11335.msg61393#msg61393)
function GM.Process_marl(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = (dirInfo.DataPos or 0) + (dirInfo.Base or 0)
    local dataLen = #dataPt
    local vals = et.GMVals -- running values for each channel (0=TimeStamp)
    local chan = et.GMChan -- running channel number
    local gmDict = et.GMDictionary
    local csv = et.GMCsv
    local maxTS = et.GMMaxTS
    local reqGPSDateTime = et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP.gpsdatetime
    local reqTimeStamp
    if reqGPSDateTime then reqTimeStamp = et.REQ_TAG_LOOKUP.timestamp else reqTimeStamp = 1 end
    local pos, verbose2

    et:VerboseDir('marl', nil, dataLen)
    if not gmDict then et:Warn('Missing marl dictionary') return 0 end
    local _ = gmDict.n - 1  -- (upstream's $maxChan is unused as well)
    if perl.num(et:Options('Verbose') or 0) > 1 then verbose2 = 1 end
    if vals[0] == nil then vals[0] = -1 end     -- (we use the 0th channel for the TimeStamp)
    local ts = vals[0]

    pos = 0
    while pos + 8 <= dataLen do
        local a = { unpack_('x' .. ExifTool.NumStr(pos) .. 'NN', dataPt) }
        local ah = a[1] >> 24
        local a2 = ah & 0xc0
        local val, chanDiff, valDiff, tsRec, gmChan
        local skip = false
        local stop = false
        if a2 == 0xc0 then          -- 16-byte full record?
            if ah == 0xff then break end    -- exit at first empty record
            chan = a[1] & 0x0fffffff
            gmChan = gmDict[chan]
            if not gmChan then skip = true end  -- (shouldn't happen)
            if not skip then
                val = a[2] - ((a[2] & 0x80000000) ~= 0 and 4294967296 or 0)
                vals[chan] = val
                if pos + 16 > dataLen then stop = true end   -- (shouldn't happen)
                if not stop then
                    pos = pos + 8                            -- point at time stamp
                    tsRec = { unpack_('x' .. ExifTool.NumStr(pos) .. 'NN', dataPt) }
                    ts = uv(tsRec[1] * 4294967296 + tsRec[2])
                end
            end
        elseif a2 == 0x40 then      -- 8-byte difference record?
            if chan == nil then skip = true end -- (shouldn't happen)
            if not skip then
                ts = ts + a[2]                      -- increment time stamp
                chanDiff = (ah & 0x3f) - ((ah & 0x20) ~= 0 and 0x40 or 0)
                chan = chan + chanDiff              -- increment the running channel number
                gmChan = gmDict[chan]
                if not gmChan then skip = true end  -- (shouldn't happen)
                if not skip then
                    if vals[chan] == nil then vals[chan] = gmChan.Init end -- init if necessary
                    valDiff = (a[1] & 0x00ffffff) - ((a[1] & 0x00800000) ~= 0 and 0x01000000 or 0)
                    vals[chan] = vals[chan] + valDiff   -- increment the running value for this channel
                    val = vals[chan]
                end
            end
        else
            skip = true -- (shouldn't happen)
        end
        if stop then break end
        if not skip then
            -- ensure that the timestamps are monotonically increasing
            -- (have seen backward steps up to 0.033 sec, so fudge these)
            if ts > maxTS then
                if csv then
                    GM.PrintCSV(et, maxTS)
                else
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    if ExifTool.perlTruthy(reqTimeStamp) then et:HandleTag(tagTablePtr, 'TimeStamp', ts) end
                    if ExifTool.perlTruthy(reqGPSDateTime) then et:HandleTag(tagTablePtr, 'GPSDateTime', ts) end
                end
                maxTS = ts
            end
            if csv then
                csv[#csv + 1] = chan
            else
                local scaled = val * gmChan.Mult + gmChan.Off
                et:HandleTag(tagTablePtr, gmChan.Name, scaled)
                if verbose2 then
                    local str = ' * ' .. ExifTool.NumStr(gmChan.Mult) .. ' + ' .. ExifTool.NumStr(gmChan.Off) ..
                        ' = ' .. ExifTool.NumStr(scaled)
                    local p0 = dataPos + pos - (a2 == 0xc0 and 8 or 0)
                    local cd, vd
                    if tsRec then
                        cd, vd = '', ''
                    else
                        cd, vd = sprintf('%+d', chanDiff), sprintf('%+d', valDiff)
                    end
                    perl.print(io.stdout, sprintf('| %8.4x: %.8x %.8x chan' .. cd .. '=%.2d ' .. gmChan.Name .. vd ..
                        ' = ' .. ExifTool.NumStr(val) .. str .. '\n', p0, a[1], a[2], chan))
                    if tsRec then
                        perl.print(io.stdout, sprintf('| %8.4x: %.8x %.8x         TimeStamp = %.6f sec\n',
                            dataPos + pos, tsRec[1], tsRec[2], ts / 1e7))
                    end
                end
            end
        end
        pos = pos + 8
    end
    vals[0] = ts        -- save last timestamp
    et.GMChan = chan    -- save last channel number
    et.GMMaxTS = ts
    et.DOC_NUM = nil
    return 1
end

GM.mrlv.PROCESS_PROC = GM.Process_mrlv
GM.mrld.PROCESS_PROC = GM.Process_mrld
GM.marl.PROCESS_PROC = GM.Process_marl

return GM
