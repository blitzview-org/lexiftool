--------------------------------------------------------------------------------
-- File:         lexiftool/Garmin.lua
-- Ported from:  lib/Image/ExifTool/Garmin.pm
--
-- Description:  Read Garmin FIT files
--
-- Revisions:    2026-04-09 - P. Harvey Created
--
-- References:   1) https://developer.garmin.com/fit/overview/
--               2) https://developer.garmin.com/fit/protocol/
--               3) https://github.com/garmin/fit-sdk-tools/blob/main/Profile.xlsx
--               4) https://docs.google.com/spreadsheets/d/1x34eRAZ45nbi3U3GyANotgmoQfj0fR49wBxmL-oLogc/
--               5) https://forums.garmin.com/developer/fit-sdk/f/discussion/254469/list-of-undocumented-mesg_num/1223595
--
-- Port notes:   read-only port. All 173 upstream tag tables and all 151
--               enumerated-type lookups are carried in full, extracted
--               mechanically so key order and the section comments transfer
--               verbatim; ProcessFIT is ported in full (header parse,
--               definition/data/compressed-timestamp-header records, the
--               Common/Unknown-field dispatch, DOC_NUM/DOC_COUNT
--               sub-document numbering keyed on new-timestamp detection --
--               the same mechanism used by MRC.lua/ZIP.lua -- and the
--               developer-field dynamic-tag-creation path keyed off
--               DeveloperDataID(207)/FieldDescription(206)), as is the
--               post-table loop that sets the Unknown flag on every
--               unsupported FIT message.
--               The %latInfo/%lonInfo/%timeInfo/%localTime/%altInfo/
--               %speedInfo Perl hash slices become helpers (conventions.md
--               §2), applied as `[N] = timeInfo { ... }`.  The many repeated
--               `ValueConv => '$val / N'` / `PrintConv => '"$val UNIT"'`
--               entries go through the local `d(n)`/`u(unit)` factories
--               rather than hundreds of near-identical closures -- the only
--               deliberate shape difference from the original.
--               CRC and @crc_table are ported (upstream itself marks them
--               "unused here").
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local GPS = require('lexiftool.GPS')
local perl = require('lexiftool.perl')
local str = perl.str
local lc, uc = perl.lc, perl.uc

local Garmin = {}

-- ExifTool and FIT format names and invalid values for each FIT base type
local baseType = {
    [0x00] = { 'int8u', 'enum', 0xff },
    [0x01] = { 'int8s', 'sint8', 0x7f },
    [0x02] = { 'int8u', 'uint8', 0xff },
    [0x83] = { 'int16s', 'sing16', 0x7fff },
    [0x84] = { 'int16u', 'uint16', 0xffff },
    [0x85] = { 'int32s', 'sint32', 0x7fffffff },
    [0x86] = { 'int32u', 'unit32', 0xffffffff },
    [0x07] = { 'string', 'string', '' },
    [0x88] = { 'float', 'float32', 'nan' },
    [0x89] = { 'double', 'float64', 'nan' },
    [0x0a] = { 'int8u', 'uint8z', 0 },
    [0x8b] = { 'int16u', 'uint16z', 0 },
    [0x8c] = { 'int32u', 'uint32z', 0 },
    [0x0d] = { 'undef', 'byte', 0xff },
    [0x8e] = { 'int64s', 'sint64', 9223372036854775807 },
    [0x8f] = { 'int64u', 'uint64', 18446744073709551615 },
    [0x90] = { 'int64u', 'uint64z', 0 },
}

local function latInfo(t)
    t.RawConv = function(_self, val) if val == 0x7fffffff then return nil end return val end -- ignore invalid value
    t.ValueConv = function(_self, val) return val * 180 / 0x80000000 end
    t.PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end
    return t
end

local function lonInfo(t)
    t.RawConv = function(_self, val) if val == 0x7fffffff then return nil end return val end
    t.ValueConv = function(_self, val) return val * 180 / 0x80000000 end
    t.PrintConv = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end
    return t
end

local function timeInfo(t)
    -- add seconds between Jan 1, 1970 and epoch of Dec 31, 1989
    t.ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val + 631065600, 1) end
    t.PrintConv = function(self, val) return self:ConvertDateTime(val) end
    return t
end

local function localTime(t)
    -- add seconds between Jan 1, 1970 and epoch of Dec 31, 1989
    t.ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val + 631065600) end
    t.PrintConv = function(self, val) return self:ConvertDateTime(val) end
    return t
end

local function altInfo(t)
    t.ValueConv = function(_self, val) return val / 5 - 500 end -- convert to metres
    t.PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' m' end
    return t
end

local function speedInfo(t)
    t.ValueConv = function(_self, val) return val * 3.6 / 1000 end -- convert to km/h from mm/s
    t.PrintConv = function(_self, val) return ExifTool.NumStr(val) .. ' km/h' end
    return t
end

-- small helpers for the many repeated `ValueConv => '$val / N'` /
-- `PrintConv => '"$val UNIT"'` entries below (same 1:1 story as upstream,
-- factored to avoid hundreds of near-identical closures)
local function d(n)
    return function(_self, val) return val / n end
end
local function u(unit)
    return function(_self, val) return ExifTool.NumStr(val) .. ' ' .. unit end
end

--
-- All variables and tables below generated by "update_garmin" script
--
------------------------------------------------------------------------
-- FIT enumerated types.  First we start with the documented types (ref 2)
--
local file = {
    [1] = 'Device',
    [2] = 'Settings',
    [3] = 'Sport',
    [4] = 'Activity',
    [5] = 'Workout',
    [6] = 'Course',
    [7] = 'Schedules',
    [8] = 'Locations', --4
    [9] = 'Weight',
    [10] = 'Totals',
    [11] = 'Goals',
    [14] = 'Blood Pressure',
    [15] = 'Monitoring A',
    [20] = 'Activity Summary',
    [28] = 'Monitoring Daily',
    [29] = 'Records', --4
    [32] = 'Monitoring B',
    [33] = 'Multi Sport', --4
    [34] = 'Segment',
    [35] = 'Segment List',
    [37] = 'Clubs', --4
    [38] = 'Score Card', --4
    [40] = 'Exd Configuration',
    [44] = 'Metrics', --4
    [49] = 'Sleep', --4
    [54] = 'Chrono Shot Session', --4
    [56] = 'Pace Band', --4
    [61] = 'ECG', --4
    [65] = 'Calendar', --4
    [68] = 'HRV Status', --4
    [72] = 'LHA Backup', --4
    [74] = 'PTD Backup', --4
    [77] = 'Schedule', --4
}

local mesgNum = {
    [0] = 'FileID',
    [1] = 'Capabilities',
    [2] = 'DeviceSettings',
    [3] = 'UserProfile',
    [4] = 'HRMProfile',
    [5] = 'SDMProfile',
    [6] = 'BikeProfile',
    [7] = 'ZonesTarget',
    [8] = 'HRZone',
    [9] = 'PowerZone',
    [10] = 'MetZone',
    [12] = 'Sport',
    [13] = 'TrainingSettings',
    [14] = 'DataScreen', --4
    [15] = 'Goal',
    [16] = 'Alert', --4
    [17] = 'RangeAlert', --4
    [18] = 'Session',
    [19] = 'Lap',
    [20] = 'Record',
    [21] = 'Event',
    [22] = 'DeviceUsed', --4
    [23] = 'DeviceInfo',
    [26] = 'Workout',
    [27] = 'WorkoutStep',
    [28] = 'Schedule',
    [29] = 'Location', --4
    [30] = 'WeightScale',
    [31] = 'Course',
    [32] = 'CoursePoint',
    [33] = 'Totals',
    [34] = 'Activity',
    [35] = 'Software',
    [37] = 'FileCapabilities',
    [38] = 'MesgCapabilities',
    [39] = 'FieldCapabilities',
    [49] = 'FileCreator',
    [51] = 'BloodPressure',
    [53] = 'SpeedZone',
    [55] = 'Monitoring',
    [70] = 'MapLayer', --4
    [71] = 'Routing', --4
    [72] = 'TrainingFile',
    [78] = 'HRV',
    [79] = 'UserMetrics', --4
    [80] = 'AntRx',
    [81] = 'AntTx',
    [82] = 'AntChannelID',
    [89] = 'OpenWaterEvent', --4
    [101] = 'Length',
    [103] = 'MonitoringInfo',
    [104] = 'DeviceStatus', --4
    [105] = 'Pad',
    [106] = 'SlaveDevice',
    [113] = 'BestEffort', --4
    [114] = 'PersonalRecord', --4
    [127] = 'Connectivity',
    [128] = 'WeatherConditions',
    [129] = 'WeatherAlert',
    [131] = 'CadenceZone',
    [132] = 'HR',
    [140] = 'ActivityMetrics', --4
    [141] = 'EPOStatus', --4
    [142] = 'SegmentLap',
    [143] = 'MultisportSettings', --4
    [144] = 'MultisportActivity', --4
    [145] = 'MemoGlob',
    [147] = 'SensorSettings', --4
    [148] = 'SegmentID',
    [149] = 'SegmentLeaderboardEntry',
    [150] = 'SegmentPoint',
    [151] = 'SegmentFile',
    [152] = 'Metronome', --4
    [158] = 'WorkoutSession',
    [159] = 'WatchfaceSettings',
    [160] = 'GPSMetadata',
    [161] = 'CameraEvent',
    [162] = 'TimeStampCorrelation',
    [164] = 'GyroscopeData',
    [165] = 'AccelerometerData',
    [167] = 'ThreeDSensorCalibration',
    [169] = 'VideoFrame',
    [170] = 'ConnectIQField', --4
    [173] = 'Clubs', --4
    [174] = 'OBDIIData',
    [177] = 'NMEASentence',
    [178] = 'AviationAttitude',
    [184] = 'Video',
    [185] = 'VideoTitle',
    [186] = 'VideoDescription',
    [187] = 'VideoClip',
    [188] = 'OHRSettings',
    [189] = 'WaypointHandling', --4
    [190] = 'GolfCourse', --4
    [191] = 'GolfStats', --4
    [192] = 'Score', --4
    [193] = 'Hole', --4
    [194] = 'Shot', --4
    [200] = 'ExdScreenConfiguration',
    [201] = 'ExdDataFieldConfiguration',
    [202] = 'ExdDataConceptConfiguration',
    [206] = 'FieldDescription',
    [207] = 'DeveloperDataID',
    [208] = 'MagnetometerData',
    [209] = 'BarometerData',
    [210] = 'OneDSensorCalibration',
    [211] = 'MonitoringHRData',
    [216] = 'TimeInZone',
    [222] = 'AlarmSettings', --4
    [225] = 'Set',
    [227] = 'StressLevel',
    [229] = 'MaxMetData',
    [243] = 'MusicInfo', --4
    [258] = 'DiveSettings',
    [259] = 'DiveGas',
    [262] = 'DiveAlarm',
    [264] = 'ExerciseTitle',
    [268] = 'DiveSummary',
    [269] = 'SPO2Data',
    [273] = 'SleepDataInfo', --4
    [275] = 'SleepLevel',
    [285] = 'Jump',
    [289] = 'AADAccelFeatures',
    [290] = 'BeatIntervals',
    [297] = 'RespirationRate',
    [302] = 'HSAAccelerometerData',
    [304] = 'HSAStepData',
    [305] = 'HSA_SPO2Data',
    [306] = 'HSAStressData',
    [307] = 'HSARespirationData',
    [308] = 'HSAHeartRateData',
    [309] = 'MtbCx', --4
    [310] = 'Race', --4
    [311] = 'SplitTime', --4
    [312] = 'Split',
    [313] = 'SplitSummary',
    [314] = 'HSABodyBatteryData',
    [315] = 'HSAEvent',
    [317] = 'ClimbPro',
    [319] = 'TankUpdate',
    [321] = 'PowerMode', --4
    [323] = 'TankSummary',
    [326] = 'GPSEvent', --4
    [336] = 'ECGSummary', --4
    [337] = 'ECGRawSample', --4
    [338] = 'ECGSmoothSample', --4
    [346] = 'SleepAssessment',
    [356] = 'FunctionalMetrics', --4
    [358] = 'RaceEvent', --4
    [369] = 'TrainingReadiness', --4
    [370] = 'HRVStatusSummary',
    [371] = 'HRVValue',
    [372] = 'RawBBI',
    [375] = 'DeviceAuxBatteryInfo',
    [376] = 'HSAGyroscopeData',
    [378] = 'TrainingLoad', --4
    [379] = 'SleepSchedule', --4
    [382] = 'SleepRestlessMoments', --4
    [387] = 'ChronoShotSession',
    [388] = 'ChronoShotData',
    [389] = 'HSAConfigurationData',
    [393] = 'DiveApneaAlarm',
    [394] = 'CPEStatus', --4
    [398] = 'SkinTempOvernight',
    [402] = 'HillScore', --4
    [403] = 'EnduranceScore', --4
    [409] = 'HSAWristTemperatureData',
    [412] = 'NapEvent',
    [428] = 'WorkoutSchedule', --4
    [470] = 'SleepDisruptionSeverityPeriod',
    [471] = 'SleepDisruptionOvernightSeverity',
}

local fileFlags = {
    BITMASK = {
        [1] = 'Read',
        [2] = 'Write',
        [3] = 'Erase',
    },
}

local mesgCount = {
    [0] = 'Num Per File',
    [1] = 'Max Per File',
    [2] = 'Max Per File Type',
}

local gender = {
    [0] = 'Female',
    [1] = 'Male',
}

local language = {
    [0] = 'English',
    [1] = 'French',
    [2] = 'Italian',
    [3] = 'German',
    [4] = 'Spanish',
    [5] = 'Croatian',
    [6] = 'Czech',
    [7] = 'Danish',
    [8] = 'Dutch',
    [9] = 'Finnish',
    [10] = 'Greek',
    [11] = 'Hungarian',
    [12] = 'Norwegian',
    [13] = 'Polish',
    [14] = 'Portuguese',
    [15] = 'Slovakian',
    [16] = 'Slovenian',
    [17] = 'Swedish',
    [18] = 'Russian',
    [19] = 'Turkish',
    [20] = 'Latvian',
    [21] = 'Ukrainian',
    [22] = 'Arabic',
    [23] = 'Farsi',
    [24] = 'Bulgarian',
    [25] = 'Romanian',
    [26] = 'Chinese',
    [27] = 'Japanese',
    [28] = 'Korean',
    [29] = 'Taiwanese',
    [30] = 'Thai',
    [31] = 'Hebrew',
    [32] = 'Brazilian Portuguese',
    [33] = 'Indonesian',
    [34] = 'Malaysian',
    [35] = 'Vietnamese',
    [36] = 'Burmese',
    [37] = 'Mongolian',
    [254] = 'Custom',
}

local displayMeasure = {
    [0] = 'Metric',
    [1] = 'Statute',
    [2] = 'Nautical',
}

local displayHeart = {
    [0] = 'BPM',
    [1] = 'Max',
    [2] = 'Reserve',
}

local displayPower = {
    [0] = 'W',
    [1] = 'Percent Ftp',
}

local displayPosition = {
    [0] = 'Degree',
    [1] = 'Degree Minute',
    [2] = 'Degree Minute Second',
    [3] = 'Austrian Grid',
    [4] = 'British Grid',
    [5] = 'Dutch Grid',
    [6] = 'Hungarian Grid',
    [7] = 'Finnish Grid',
    [8] = 'German Grid',
    [9] = 'Icelandic Grid',
    [10] = 'Indonesian Equatorial',
    [11] = 'Indonesian Irian',
    [12] = 'Indonesian Southern',
    [13] = 'India Zone 0',
    [14] = 'India Zone IA',
    [15] = 'India Zone IB',
    [16] = 'India Zone IIA',
    [17] = 'India Zone IIB',
    [18] = 'India Zone IIIA',
    [19] = 'India Zone IIIB',
    [20] = 'India Zone IVA',
    [21] = 'India Zone IVB',
    [22] = 'Irish Transverse',
    [23] = 'Irish Grid',
    [24] = 'Loran',
    [25] = 'Maidenhead Grid',
    [26] = 'Mgrs Grid',
    [27] = 'New Zealand Grid',
    [28] = 'New Zealand Transverse',
    [29] = 'Qatar Grid',
    [30] = 'Modified Swedish Grid',
    [31] = 'Swedish Grid',
    [32] = 'South African Grid',
    [33] = 'Swiss Grid',
    [34] = 'Taiwan Grid',
    [35] = 'United States Grid',
    [36] = 'Utm Ups Grid',
    [37] = 'West Malayan',
    [38] = 'Borneo RSO',
    [39] = 'Estonian Grid',
    [40] = 'Latvian Grid',
    [41] = 'Swedish Ref 99 Grid',
}

local switch = {
    [0] = 'Off',
    [1] = 'On',
    [2] = 'Auto',
}

local sportEnum = {
    [0] = 'Generic',
    [1] = 'Running',
    [2] = 'Cycling',
    [3] = 'Transition',
    [4] = 'Fitness Equipment',
    [5] = 'Swimming',
    [6] = 'Basketball',
    [7] = 'Soccer',
    [8] = 'Tennis',
    [9] = 'American Football',
    [10] = 'Training',
    [11] = 'Walking',
    [12] = 'Cross Country Skiing',
    [13] = 'Alpine Skiing',
    [14] = 'Snowboarding',
    [15] = 'Rowing',
    [16] = 'Mountaineering',
    [17] = 'Hiking',
    [18] = 'Multisport',
    [19] = 'Paddling',
    [20] = 'Flying',
    [21] = 'E Biking',
    [22] = 'Motorcycling',
    [23] = 'Boating',
    [24] = 'Driving',
    [25] = 'Golf',
    [26] = 'Hang Gliding',
    [27] = 'Horseback Riding',
    [28] = 'Hunting',
    [29] = 'Fishing',
    [30] = 'Inline Skating',
    [31] = 'Rock Climbing',
    [32] = 'Sailing',
    [33] = 'Ice Skating',
    [34] = 'Sky Diving',
    [35] = 'Snowshoeing',
    [36] = 'Snowmobiling',
    [37] = 'Stand Up Paddleboarding',
    [38] = 'Surfing',
    [39] = 'Wakeboarding',
    [40] = 'Water Skiing',
    [41] = 'Kayaking',
    [42] = 'Rafting',
    [43] = 'Windsurfing',
    [44] = 'Kitesurfing',
    [45] = 'Tactical',
    [46] = 'Jumpmaster',
    [47] = 'Boxing',
    [48] = 'Floor Climbing',
    [49] = 'Baseball',
    [53] = 'Diving',
    [56] = 'Shooting',
    [58] = 'Winter Sport',
    [59] = 'Grinding',
    [62] = 'Hiit',
    [63] = 'Video Gaming',
    [64] = 'Racket',
    [65] = 'Wheelchair Push Walk',
    [66] = 'Wheelchair Push Run',
    [67] = 'Meditation',
    [68] = 'Para Sport',
    [69] = 'Disc Golf',
    [70] = 'Team Sport',
    [71] = 'Cricket',
    [72] = 'Rugby',
    [73] = 'Hockey',
    [74] = 'Lacrosse',
    [75] = 'Volleyball',
    [76] = 'Water Tubing',
    [77] = 'Wakesurfing',
    [78] = 'Water Sport',
    [79] = 'Archery',
    [80] = 'Mixed Martial Arts',
    [81] = 'Motor Sports',
    [82] = 'Snorkeling',
    [83] = 'Dance',
    [84] = 'Jump Rope',
    [85] = 'Pool Apnea',
    [86] = 'Mobility',
    [87] = 'Geocaching',
    [88] = 'Canoeing',
    [254] = 'All',
}

local subSport = {
    [0] = 'Generic',
    [1] = 'Treadmill',
    [2] = 'Street',
    [3] = 'Trail',
    [4] = 'Track',
    [5] = 'Spin',
    [6] = 'Indoor Cycling',
    [7] = 'Road',
    [8] = 'Mountain',
    [9] = 'Downhill',
    [10] = 'Recumbent',
    [11] = 'Cyclocross',
    [12] = 'Hand Cycling',
    [13] = 'Track Cycling',
    [14] = 'Indoor Rowing',
    [15] = 'Elliptical',
    [16] = 'Stair Climbing',
    [17] = 'Lap Swimming',
    [18] = 'Open Water',
    [19] = 'Flexibility Training',
    [20] = 'Strength Training',
    [21] = 'Warm Up',
    [22] = 'Match',
    [23] = 'Exercise',
    [24] = 'Challenge',
    [25] = 'Indoor Skiing',
    [26] = 'Cardio Training',
    [27] = 'Indoor Walking',
    [28] = 'E-Bike Fitness',
    [29] = 'Bmx',
    [30] = 'Casual Walking',
    [31] = 'Speed Walking',
    [32] = 'Bike To Run Transition',
    [33] = 'Run To Bike Transition',
    [34] = 'Swim To Bike Transition',
    [35] = 'Atv',
    [36] = 'Motocross',
    [37] = 'Backcountry',
    [38] = 'Resort',
    [39] = 'Rc Drone',
    [40] = 'Wingsuit',
    [41] = 'Whitewater',
    [42] = 'Skate Skiing',
    [43] = 'Yoga',
    [44] = 'Pilates',
    [45] = 'Indoor Running',
    [46] = 'Gravel Cycling',
    [47] = 'E-Bike Mountain',
    [48] = 'Commuting',
    [49] = 'Mixed Surface',
    [50] = 'Navigate',
    [51] = 'Track Me',
    [52] = 'Map',
    [53] = 'Single Gas Diving',
    [54] = 'Multi Gas Diving',
    [55] = 'Gauge Diving',
    [56] = 'Apnea Diving',
    [57] = 'Apnea Hunting',
    [58] = 'Virtual Activity',
    [59] = 'Obstacle',
    [62] = 'Breathing',
    [63] = 'CCR Diving',
    [65] = 'Sail Race',
    [66] = 'Expedition',
    [67] = 'Ultra',
    [68] = 'Indoor Climbing',
    [69] = 'Bouldering',
    [70] = 'Hiit',
    [71] = 'Indoor Grinding',
    [72] = 'Hunting With Dogs',
    [73] = 'Amrap',
    [74] = 'Emom',
    [75] = 'Tabata',
    [77] = 'Esport',
    [78] = 'Triathlon',
    [79] = 'Duathlon',
    [80] = 'Brick',
    [81] = 'Swim Run',
    [82] = 'Adventure Race',
    [83] = 'Trucker Workout',
    [84] = 'Pickleball',
    [85] = 'Padel',
    [86] = 'Indoor Wheelchair Walk',
    [87] = 'Indoor Wheelchair Run',
    [88] = 'Indoor Hand Cycling',
    [90] = 'Field',
    [91] = 'Ice',
    [92] = 'Ultimate',
    [93] = 'Platform',
    [94] = 'Squash',
    [95] = 'Badminton',
    [96] = 'Racquetball',
    [97] = 'Table Tennis',
    [98] = 'Overland',
    [99] = 'Trolling Motor',
    [110] = 'Fly Canopy',
    [111] = 'Fly Paraglide',
    [112] = 'Fly Paramotor',
    [113] = 'Fly Pressurized',
    [114] = 'Fly Navigate',
    [115] = 'Fly Timer',
    [116] = 'Fly Altimeter',
    [117] = 'Fly Wx',
    [118] = 'Fly Vfr',
    [119] = 'Fly Ifr',
    [121] = 'Dynamic Apnea',
    [123] = 'Enduro',
    [124] = 'Rucking',
    [125] = 'Rally',
    [126] = 'Pool Triathlon',
    [127] = 'E-Bike Enduro',
    [254] = 'All',
}

local sportEvent = {
    [0] = 'Uncategorized',
    [1] = 'Geocaching',
    [2] = 'Fitness',
    [3] = 'Recreation',
    [4] = 'Race',
    [5] = 'Special Event',
    [6] = 'Training',
    [7] = 'Transportation',
    [8] = 'Touring',
}

local activityEnum = {
    [0] = 'Manual',
    [1] = 'Auto Multi Sport',
}

local intensity = {
    [0] = 'Active',
    [1] = 'Rest',
    [2] = 'Warmup',
    [3] = 'Cooldown',
    [4] = 'Recovery',
    [5] = 'Interval',
    [6] = 'Other',
}

local sessionTrigger = {
    [0] = 'Activity End',
    [1] = 'Manual',
    [2] = 'Auto Multi Sport',
    [3] = 'Fitness Equipment',
}

local lapTrigger = {
    [0] = 'Manual',
    [1] = 'time',
    [2] = 'Distance',
    [3] = 'Position Start',
    [4] = 'Position Lap',
    [5] = 'Position Waypoint',
    [6] = 'Position Marked',
    [7] = 'Session End',
    [8] = 'Fitness Equipment',
}

local backlightMode = {
    [0] = 'Off',
    [1] = 'Manual',
    [2] = 'Key And Messages',
    [3] = 'Auto Brightness',
    [4] = 'Smart Notifications',
    [5] = 'Key And Messages Night',
    [6] = 'Key And Messages And Smart Notifications',
}

local dateMode = {
    [0] = 'Day Month',
    [1] = 'Month Day',
}

local backlightTimeout = {
    [0] = 'Infinite',
}

local eventEnum = {
    [0] = 'Timer',
    [3] = 'Workout',
    [4] = 'Workout Step',
    [5] = 'Power Down',
    [6] = 'Power Up',
    [7] = 'Off Course',
    [8] = 'Session',
    [9] = 'Lap',
    [10] = 'Course Point',
    [11] = 'Battery',
    [12] = 'Virtual Partner Pace',
    [13] = 'HR High Alert',
    [14] = 'HR Low Alert',
    [15] = 'Speed High Alert',
    [16] = 'Speed Low Alert',
    [17] = 'Cad High Alert',
    [18] = 'Cad Low Alert',
    [19] = 'Power High Alert',
    [20] = 'Power Low Alert',
    [21] = 'Recovery HR',
    [22] = 'Battery Low',
    [23] = 'Time Duration Alert',
    [24] = 'Distance Duration Alert',
    [25] = 'Calorie Duration Alert',
    [26] = 'Activity',
    [27] = 'Fitness Equipment',
    [28] = 'Length',
    [32] = 'User Marker',
    [33] = 'Sport Point',
    [36] = 'Calibration',
    [39] = 'Performance Condition Alert', --4
    [42] = 'Front Gear Change',
    [43] = 'Rear Gear Change',
    [44] = 'Rider Position Change',
    [45] = 'Elev High Alert',
    [46] = 'Elev Low Alert',
    [47] = 'Comm Timeout',
    [54] = 'Auto Activity Detect',
    [56] = 'Dive Alert',
    [57] = 'Dive Gas Switched',
    [71] = 'Tank Pressure Reserve',
    [72] = 'Tank Pressure Critical',
    [73] = 'Tank Lost',
    [74] = 'Sleep Event', --4
    [75] = 'Radar Threat Alert',
    [76] = 'Tank Battery Low',
    [81] = 'Tank Pod Connected',
    [82] = 'Tank Pod Disconnected',
}

local eventType = {
    [0] = 'Start',
    [1] = 'Stop',
    [2] = 'Consecutive Depreciated',
    [3] = 'Marker',
    [4] = 'Stop All',
    [5] = 'Begin Depreciated',
    [6] = 'End Depreciated',
    [7] = 'End All Depreciated',
    [8] = 'Stop Disable',
    [9] = 'Stop Disable All',
}

local tone = {
    [0] = 'Off',
    [1] = 'Tone',
    [2] = 'Vibrate',
    [3] = 'Tone And Vibrate',
}

local activityClass = {
    [100] = 'Level Max',
}

local hRZoneCalc = {
    [0] = 'Custom',
    [1] = 'Percent Max HR',
    [2] = 'Percent HRr',
    [3] = 'Percent Lthr',
}

local pwrZoneCalc = {
    [0] = 'Custom',
    [1] = 'Percent Ftp',
}

local wktStepDuration = {
    [0] = 'time',
    [1] = 'Distance',
    [2] = 'HR Less Than',
    [3] = 'HR Greater Than',
    [4] = 'Calories',
    [5] = 'Open',
    [6] = 'Repeat Until Steps Cmplt',
    [7] = 'Repeat Until Time',
    [8] = 'Repeat Until Distance',
    [9] = 'Repeat Until Calories',
    [10] = 'Repeat Until HR Less Than',
    [11] = 'Repeat Until HR Greater Than',
    [12] = 'Repeat Until Power Less Than',
    [13] = 'Repeat Until Power Greater Than',
    [14] = 'Power Less Than',
    [15] = 'Power Greater Than',
    [16] = 'Training Peaks Tss',
    [17] = 'Repeat Until Power Last Lap Less Than',
    [18] = 'Repeat Until Max Power Last Lap Less Than',
    [19] = 'Power 3s Less Than',
    [20] = 'Power 10s Less Than',
    [21] = 'Power 30s Less Than',
    [22] = 'Power 3s Greater Than',
    [23] = 'Power 10s Greater Than',
    [24] = 'Power 30s Greater Than',
    [25] = 'Power Lap Less Than',
    [26] = 'Power Lap Greater Than',
    [27] = 'Repeat Until Training Peaks Tss',
    [28] = 'Repetition Time',
    [29] = 'Reps',
    [31] = 'Time Only',
}

local wktStepTarget = {
    [0] = 'Speed',
    [1] = 'Heart Rate',
    [2] = 'Open',
    [3] = 'Cadence',
    [4] = 'Power',
    [5] = 'Grade',
    [6] = 'Resistance',
    [7] = 'Power 3s',
    [8] = 'Power 10s',
    [9] = 'Power 30s',
    [10] = 'Power Lap',
    [11] = 'Swim Stroke',
    [12] = 'Speed Lap',
    [13] = 'Heart Rate Lap',
}

local goalEnum = {
    [0] = 'time',
    [1] = 'Distance',
    [2] = 'Calories',
    [3] = 'Frequency',
    [4] = 'Steps',
    [5] = 'Ascent',
    [6] = 'Active Minutes',
}

local goalRecurrence = {
    [0] = 'Off',
    [1] = 'Daily',
    [2] = 'Weekly',
    [3] = 'Monthly',
    [4] = 'Yearly',
    [5] = 'Custom',
}

local goalSource = {
    [0] = 'Auto',
    [1] = 'Community',
    [2] = 'User',
}

local scheduleEnum = {
    [0] = 'Workout',
    [1] = 'Course',
}

local coursePointEnum = {
    [0] = 'Generic',
    [1] = 'Summit',
    [2] = 'Valley',
    [3] = 'Water',
    [4] = 'Food',
    [5] = 'Danger',
    [6] = 'Left',
    [7] = 'Right',
    [8] = 'Straight',
    [9] = 'First Aid',
    [10] = 'Fourth Category',
    [11] = 'Third Category',
    [12] = 'Second Category',
    [13] = 'First Category',
    [14] = 'Hors Category',
    [15] = 'Sprint',
    [16] = 'Left Fork',
    [17] = 'Right Fork',
    [18] = 'Middle Fork',
    [19] = 'Slight Left',
    [20] = 'Sharp Left',
    [21] = 'Slight Right',
    [22] = 'Sharp Right',
    [23] = 'U Turn',
    [24] = 'Segment Start',
    [25] = 'Segment End',
    [27] = 'Campsite',
    [28] = 'Aid Station',
    [29] = 'Rest Area',
    [30] = 'General Distance',
    [31] = 'Service',
    [32] = 'Energy Gel',
    [33] = 'Sports Drink',
    [34] = 'Mile Marker',
    [35] = 'Checkpoint',
    [36] = 'Shelter',
    [37] = 'Meeting Spot',
    [38] = 'Overlook',
    [39] = 'Toilet',
    [40] = 'Shower',
    [41] = 'Gear',
    [42] = 'Sharp Curve',
    [43] = 'Steep Incline',
    [44] = 'Tunnel',
    [45] = 'Bridge',
    [46] = 'Obstacle',
    [47] = 'Crossing',
    [48] = 'Store',
    [49] = 'Transition',
    [50] = 'Navaid',
    [51] = 'Transport',
    [52] = 'Alert',
    [53] = 'Info',
}

local manufacturer = {
    [1] = 'Garmin',
    [2] = 'Garmin FR405 ANTFS',
    [3] = 'Zephyr',
    [4] = 'Dayton',
    [5] = 'IDT',
    [6] = 'SRM',
    [7] = 'Quarq',
    [8] = 'Ibike',
    [9] = 'Saris',
    [10] = 'Spark Hk',
    [11] = 'Tanita',
    [12] = 'Echowell',
    [13] = 'Dynastream Oem',
    [14] = 'Nautilus',
    [15] = 'Dynastream',
    [16] = 'Timex',
    [17] = 'Metrigear',
    [18] = 'Xelic',
    [19] = 'Beurer',
    [20] = 'Cardiosport',
    [21] = 'A And D',
    [22] = 'Hmm',
    [23] = 'Suunto',
    [24] = 'Thita Elektronik',
    [25] = 'Gpulse',
    [26] = 'Clean Mobile',
    [27] = 'Pedal Brain',
    [28] = 'Peaksware',
    [29] = 'Saxonar',
    [30] = 'Lemond Fitness',
    [31] = 'Dexcom',
    [32] = 'Wahoo Fitness',
    [33] = 'Octane Fitness',
    [34] = 'Archinoetics',
    [35] = 'The Hurt Box',
    [36] = 'Citizen Systems',
    [37] = 'Magellan',
    [38] = 'Osynce',
    [39] = 'Holux',
    [40] = 'Concept2',
    [41] = 'Shimano',
    [42] = 'One Giant Leap',
    [43] = 'Ace Sensor',
    [44] = 'Brim Brothers',
    [45] = 'Xplova',
    [46] = 'Perception Digital',
    [47] = 'Bf1systems',
    [48] = 'Pioneer',
    [49] = 'Spantec',
    [50] = 'Metalogics',
    [51] = '4iiiis',
    [52] = 'Seiko Epson',
    [53] = 'Seiko Epson Oem',
    [54] = 'Ifor Powell',
    [55] = 'Maxwell Guider',
    [56] = 'Star Trac',
    [57] = 'Breakaway',
    [58] = 'Alatech Technology Ltd',
    [59] = 'Mio Technology Europe',
    [60] = 'Rotor',
    [61] = 'Geonaute',
    [62] = 'ID Bike',
    [63] = 'Specialized',
    [64] = 'Wtek',
    [65] = 'Physical Enterprises',
    [66] = 'North Pole Engineering',
    [67] = 'Bkool',
    [68] = 'Cateye',
    [69] = 'Stages Cycling',
    [70] = 'Sigmasport',
    [71] = 'Tomtom',
    [72] = 'Peripedal',
    [73] = 'Wattbike',
    [76] = 'Moxy',
    [77] = 'Ciclosport',
    [78] = 'Powerbahn',
    [79] = 'Acorn Projects Aps',
    [80] = 'Lifebeam',
    [81] = 'Bontrager',
    [82] = 'Wellgo',
    [83] = 'Scosche',
    [84] = 'Magura',
    [85] = 'Woodway',
    [86] = 'Elite',
    [87] = 'Nielsen Kellerman',
    [88] = 'Dk City',
    [89] = 'Tacx',
    [90] = 'Direction Technology',
    [91] = 'Magtonic',
    [92] = '1partcarbon',
    [93] = 'Inside Ride Technologies',
    [94] = 'Sound Of Motion',
    [95] = 'Stryd',
    [96] = 'ICG',
    [97] = 'MiPulse',
    [98] = 'BSX Athletics',
    [99] = 'Look',
    [100] = 'Campagnolo Srl',
    [101] = 'Body Bike Smart',
    [102] = 'Praxisworks',
    [103] = 'Limits Technology',
    [104] = 'Topaction Technology',
    [105] = 'Cosinuss',
    [106] = 'Fitcare',
    [107] = 'Magene',
    [108] = 'Giant Manufacturing Co',
    [109] = 'Tigrasport',
    [110] = 'Salutron',
    [111] = 'Technogym',
    [112] = 'Bryton Sensors',
    [113] = 'Latitude Limited',
    [114] = 'Soaring Technology',
    [115] = 'iGPSPORT',
    [116] = 'Thinkrider',
    [117] = 'Gopher Sport',
    [118] = 'Waterrower',
    [119] = 'Orangetheory',
    [120] = 'Inpeak',
    [121] = 'Kinetic',
    [122] = 'Johnson Health Tech',
    [123] = 'Polar Electro',
    [124] = 'Seesense',
    [125] = 'Nci Technology',
    [126] = 'IQsquare',
    [127] = 'Leomo',
    [128] = 'Ifit Com',
    [129] = 'Coros Byte',
    [130] = 'Versa Design',
    [131] = 'Chileaf',
    [132] = 'Cycplus',
    [133] = 'Gravaa Byte',
    [134] = 'Sigeyi',
    [135] = 'Coospo',
    [136] = 'Geoid',
    [137] = 'Bosch',
    [138] = 'Kyto',
    [139] = 'Kinetic Sports',
    [140] = 'Decathlon Byte',
    [141] = 'Tq Systems',
    [142] = 'Tag Heuer',
    [143] = 'Keiser Fitness',
    [144] = 'Zwift Byte',
    [145] = 'Porsche EP',
    [146] = 'Blackbird',
    [147] = 'Meilan Byte',
    [148] = 'Ezon',
    [149] = 'Laisi',
    [150] = 'Myzone',
    [151] = 'Abawo',
    [152] = 'Bafang',
    [153] = 'Luhong Technology',
    [255] = 'Development',
    [257] = 'Healthandlife',
    [258] = 'Lezyne',
    [259] = 'Scribe Labs',
    [260] = 'Zwift',
    [261] = 'Watteam',
    [262] = 'Recon',
    [263] = 'Favero Electronics',
    [264] = 'Dynovelo',
    [265] = 'Strava',
    [266] = 'Precor',
    [267] = 'Bryton',
    [268] = 'Sram',
    [269] = 'Navman',
    [270] = 'Cobi',
    [271] = 'Spivi',
    [272] = 'Mio Magellan',
    [273] = 'Evesports',
    [274] = 'Sensitivus Gauge',
    [275] = 'Podoon',
    [276] = 'Life Time Fitness',
    [277] = 'Falco E Motors',
    [278] = 'Minoura',
    [279] = 'Cycliq',
    [280] = 'Luxottica',
    [281] = 'Trainer Road',
    [282] = 'The Sufferfest',
    [283] = 'Fullspeedahead',
    [284] = 'Virtualtraining',
    [285] = 'Feedbacksports',
    [286] = 'Omata',
    [287] = 'VDO',
    [288] = 'Magneticdays',
    [289] = 'Hammerhead',
    [290] = 'Kinetic By Kurt',
    [291] = 'Shapelog',
    [292] = 'Dabuziduo',
    [293] = 'Jetblack',
    [294] = 'Coros',
    [295] = 'Virtugo',
    [296] = 'Velosense',
    [297] = 'Cycligentinc',
    [298] = 'Trailforks',
    [299] = 'Mahle Ebikemotion',
    [300] = 'Nurvv',
    [301] = 'Microprogram',
    [302] = 'Zone5cloud',
    [303] = 'Greenteg',
    [304] = 'Yamaha Motors',
    [305] = 'Whoop',
    [306] = 'Gravaa',
    [307] = 'Onelap',
    [308] = 'Monark Exercise',
    [309] = 'Form',
    [310] = 'Decathlon',
    [311] = 'Syncros',
    [312] = 'Heatup',
    [313] = 'Cannondale',
    [314] = 'True Fitness',
    [315] = 'RGT Cycling',
    [316] = 'Vasa',
    [317] = 'Race Republic',
    [318] = 'Fazua',
    [319] = 'Oreka Training',
    [320] = 'LSEC',
    [321] = 'Lululemon Studio',
    [322] = 'Shanyue',
    [323] = 'Spinning MDA',
    [324] = 'Hilldating',
    [325] = 'Aero Sensor',
    [326] = 'Nike',
    [327] = 'Magicshine',
    [328] = 'Ictrainer',
    [329] = 'Absolute Cycling',
    [330] = 'Eo Swimbetter',
    [331] = 'Mywhoosh',
    [332] = 'Ravemen',
    [333] = 'Tektro Racing Products',
    [334] = 'Darad Innovation Corporation',
    [335] = 'Cycloptim',
    [337] = 'Runna',
    [339] = 'Zepp',
    [340] = 'Peloton',
    [341] = 'Carv',
    [342] = 'Tissot',
    [345] = 'Real Velo',
    [346] = 'Wetech',
    [347] = 'Jespr',
    [348] = 'Huawei',
    [349] = 'Gotoes',
    [5759] = 'ActiGraph Corp',
}

local antNetwork = {
    [0] = 'Public',
    [1] = 'Antplus',
    [2] = 'Antfs',
    [3] = 'Private',
}

local workoutCapabilities = {
    BITMASK = {
        [0] = 'Interval',
        [1] = 'Custom',
        [2] = 'Fitness Equipment',
        [3] = 'Firstbeat',
        [4] = 'New Leaf',
        [5] = 'Tcx',
        [7] = 'Speed',
        [8] = 'Heart Rate',
        [9] = 'Distance',
        [10] = 'Cadence',
        [11] = 'Power',
        [12] = 'Grade',
        [13] = 'Resistance',
        [14] = 'Protected',
    },
}

local batteryStatus = {
    [1] = 'New',
    [2] = 'Good',
    [3] = 'Ok',
    [4] = 'Low',
    [5] = 'Critical',
    [6] = 'Charging',
    [7] = 'Unknown',
}

local hRType = {
    [0] = 'Normal',
    [1] = 'Irregular',
}

local courseCapabilities = {
    BITMASK = {
        [0] = 'Processed',
        [1] = 'Valid',
        [2] = 'time',
        [3] = 'Distance',
        [4] = 'Position',
        [5] = 'Heart Rate',
        [6] = 'Power',
        [7] = 'Cadence',
        [8] = 'Training',
        [9] = 'Navigation',
        [10] = 'Bikeway',
        [12] = 'Aviation',
    },
}

local bpStatus = {
    [0] = 'No Error',
    [1] = 'Error Incomplete Data',
    [2] = 'Error No Measurement',
    [3] = 'Error Data Out Of Range',
    [4] = 'Error Irregular Heart Rate',
}

local swimStroke = {
    [0] = 'Freestyle',
    [1] = 'Backstroke',
    [2] = 'Breaststroke',
    [3] = 'Butterfly',
    [4] = 'Drill',
    [5] = 'Mixed',
    [6] = 'Im',
    [7] = 'Im By Round',
    [8] = 'Rimo',
}

local activityType = {
    [0] = 'Generic',
    [1] = 'Running',
    [2] = 'Cycling',
    [3] = 'Transition',
    [4] = 'Fitness Equipment',
    [5] = 'Swimming',
    [6] = 'Walking',
    [8] = 'Sedentary',
    [254] = 'All',
}

local activitySubtype = {
    [0] = 'Generic',
    [1] = 'Treadmill',
    [2] = 'Street',
    [3] = 'Trail',
    [4] = 'Track',
    [5] = 'Spin',
    [6] = 'Indoor Cycling',
    [7] = 'Road',
    [8] = 'Mountain',
    [9] = 'Downhill',
    [10] = 'Recumbent',
    [11] = 'Cyclocross',
    [12] = 'Hand Cycling',
    [13] = 'Track Cycling',
    [14] = 'Indoor Rowing',
    [15] = 'Elliptical',
    [16] = 'Stair Climbing',
    [17] = 'Lap Swimming',
    [18] = 'Open Water',
    [254] = 'All',
}

local activityLevel = {
    [0] = 'Low',
    [1] = 'Medium',
    [2] = 'High',
}

local side = {
    [0] = 'Right',
    [1] = 'Left',
}

local lengthType = {
    [0] = 'Idle',
    [1] = 'Active',
}

local dayOfWeek = {
    [0] = 'Sunday',
    [1] = 'Monday',
    [2] = 'Tuesday',
    [3] = 'Wednesday',
    [4] = 'Thursday',
    [5] = 'Friday',
    [6] = 'Saturday',
}

local connectivityCapabilities = {
    BITMASK = {
        [0] = 'Bluetooth',
        [1] = 'Bluetooth Le',
        [2] = 'Ant',
        [3] = 'Activity Upload',
        [4] = 'Course Download',
        [5] = 'Workout Download',
        [6] = 'Live Track',
        [7] = 'Weather Conditions',
        [8] = 'Weather Alerts',
        [9] = 'GPS Ephemeris Download',
        [10] = 'Explicit Archive',
        [11] = 'Setup Incomplete',
        [12] = 'Continue Sync After Software Update',
        [13] = 'Connect IQ App Download',
        [14] = 'Golf Course Download',
        [15] = 'Device Initiates Sync',
        [16] = 'Connect IQ Watch App Download',
        [17] = 'Connect IQ Widget Download',
        [18] = 'Connect IQ Watch Face Download',
        [19] = 'Connect IQ Data Field Download',
        [20] = 'Connect IQ App Managment',
        [21] = 'Swing Sensor',
        [22] = 'Swing Sensor Remote',
        [23] = 'Incident Detection',
        [24] = 'Audio Prompts',
        [25] = 'Wifi Verification',
        [26] = 'True Up',
        [27] = 'Find My Watch',
        [28] = 'Remote Manual Sync',
        [29] = 'Live Track Auto Start',
        [30] = 'Live Track Messaging',
        [31] = 'Instant Input',
    },
}

local weatherReport = {
    [0] = 'Current',
    [1] = 'Hourly Forecast',
    [2] = 'Daily Forecast',
}

local weatherStatus = {
    [0] = 'Clear',
    [1] = 'Partly Cloudy',
    [2] = 'Mostly Cloudy',
    [3] = 'Rain',
    [4] = 'Snow',
    [5] = 'Windy',
    [6] = 'Thunderstorms',
    [7] = 'Wintry Mix',
    [8] = 'Fog',
    [11] = 'Hazy',
    [12] = 'Hail',
    [13] = 'Scattered Showers',
    [14] = 'Scattered Thunderstorms',
    [15] = 'Unknown Precipitation',
    [16] = 'Light Rain',
    [17] = 'Heavy Rain',
    [18] = 'Light Snow',
    [19] = 'Heavy Snow',
    [20] = 'Light Rain Snow',
    [21] = 'Heavy Rain Snow',
    [22] = 'Cloudy',
}

local weatherSeverity = {
    [0] = 'Unknown',
    [1] = 'Warning',
    [2] = 'Watch',
    [3] = 'Advisory',
    [4] = 'Statement',
}

local weatherSevereType = {
    [0] = 'Unspecified',
    [1] = 'Tornado',
    [2] = 'Tsunami',
    [3] = 'Hurricane',
    [4] = 'Extreme Wind',
    [5] = 'Typhoon',
    [6] = 'Inland Hurricane',
    [7] = 'Hurricane Force Wind',
    [8] = 'Waterspout',
    [9] = 'Severe Thunderstorm',
    [10] = 'Wreckhouse Winds',
    [11] = 'Les Suetes Wind',
    [12] = 'Avalanche',
    [13] = 'Flash Flood',
    [14] = 'Tropical Storm',
    [15] = 'Inland Tropical Storm',
    [16] = 'Blizzard',
    [17] = 'Ice Storm',
    [18] = 'Freezing Rain',
    [19] = 'Debris Flow',
    [20] = 'Flash Freeze',
    [21] = 'Dust Storm',
    [22] = 'High Wind',
    [23] = 'Winter Storm',
    [24] = 'Heavy Freezing Spray',
    [25] = 'Extreme Cold',
    [26] = 'Wind Chill',
    [27] = 'Cold Wave',
    [28] = 'Heavy Snow Alert',
    [29] = 'Lake Effect Blowing Snow',
    [30] = 'Snow Squall',
    [31] = 'Lake Effect Snow',
    [32] = 'Winter Weather',
    [33] = 'Sleet',
    [34] = 'Snowfall',
    [35] = 'Snow And Blowing Snow',
    [36] = 'Blowing Snow',
    [37] = 'Snow Alert',
    [38] = 'Arctic Outflow',
    [39] = 'Freezing Drizzle',
    [40] = 'Storm',
    [41] = 'Storm Surge',
    [42] = 'Rainfall',
    [43] = 'Areal Flood',
    [44] = 'Coastal Flood',
    [45] = 'Lakeshore Flood',
    [46] = 'Excessive Heat',
    [47] = 'Heat',
    [48] = 'Weather',
    [49] = 'High Heat And Humidity',
    [50] = 'Humidex And Health',
    [51] = 'Humidex',
    [52] = 'Gale',
    [53] = 'Freezing Spray',
    [54] = 'Special Marine',
    [55] = 'Squall',
    [56] = 'Strong Wind',
    [57] = 'Lake Wind',
    [58] = 'Marine Weather',
    [59] = 'Wind',
    [60] = 'Small Craft Hazardous Seas',
    [61] = 'Hazardous Seas',
    [62] = 'Small Craft',
    [63] = 'Small Craft Winds',
    [64] = 'Small Craft Rough Bar',
    [65] = 'High Water Level',
    [66] = 'Ashfall',
    [67] = 'Freezing Fog',
    [68] = 'Dense Fog',
    [69] = 'Dense Smoke',
    [70] = 'Blowing Dust',
    [71] = 'Hard Freeze',
    [72] = 'Freeze',
    [73] = 'Frost',
    [74] = 'Fire Weather',
    [75] = 'Flood',
    [76] = 'Rip Tide',
    [77] = 'High Surf',
    [78] = 'Smog',
    [79] = 'Air Quality',
    [80] = 'Brisk Wind',
    [81] = 'Air Stagnation',
    [82] = 'Low Water',
    [83] = 'Hydrological',
    [84] = 'Special Weather',
}

local strokeType = {
    [0] = 'No Event',
    [1] = 'Other',
    [2] = 'Serve',
    [3] = 'Forehand',
    [4] = 'Backhand',
    [5] = 'Smash',
}

local bodyLocation = {
    [0] = 'Left Leg',
    [1] = 'Left Calf',
    [2] = 'Left Shin',
    [3] = 'Left Hamstring',
    [4] = 'Left Quad',
    [5] = 'Left Glute',
    [6] = 'Right Leg',
    [7] = 'Right Calf',
    [8] = 'Right Shin',
    [9] = 'Right Hamstring',
    [10] = 'Right Quad',
    [11] = 'Right Glute',
    [12] = 'Torso Back',
    [13] = 'Left Lower Back',
    [14] = 'Left Upper Back',
    [15] = 'Right Lower Back',
    [16] = 'Right Upper Back',
    [17] = 'Torso Front',
    [18] = 'Left Abdomen',
    [19] = 'Left Chest',
    [20] = 'Right Abdomen',
    [21] = 'Right Chest',
    [22] = 'Left Arm',
    [23] = 'Left Shoulder',
    [24] = 'Left Bicep',
    [25] = 'Left Tricep',
    [26] = 'Left Brachioradialis',
    [27] = 'Left Forearm Extensors',
    [28] = 'Right Arm',
    [29] = 'Right Shoulder',
    [30] = 'Right Bicep',
    [31] = 'Right Tricep',
    [32] = 'Right Brachioradialis',
    [33] = 'Right Forearm Extensors',
    [34] = 'Neck',
    [35] = 'Throat',
    [36] = 'Waist Mid Back',
    [37] = 'Waist Front',
    [38] = 'Waist Left',
    [39] = 'Waist Right',
}

local segmentLapStatus = {
    [0] = 'End',
    [1] = 'Fail',
}

local segmentLeaderboardType = {
    [0] = 'Overall',
    [1] = 'Personal Best',
    [2] = 'Connections',
    [3] = 'Group',
    [4] = 'Challenger',
    [5] = 'Kom',
    [6] = 'Qom',
    [7] = 'Pr',
    [8] = 'Goal',
    [9] = 'Carrot',
    [10] = 'Club Leader',
    [11] = 'Rival',
    [12] = 'Last',
    [13] = 'Recent Best',
    [14] = 'Course Record',
}

local segmentDeleteStatus = {
    [0] = 'Do Not Delete',
    [1] = 'Delete One',
    [2] = 'Delete All',
}

local segmentSelectionType = {
    [0] = 'Starred',
    [1] = 'Suggested',
}

local sourceType = {
    [0] = 'Ant',
    [1] = 'Antplus',
    [2] = 'Bluetooth',
    [3] = 'Bluetooth Low Energy',
    [4] = 'Wifi',
    [5] = 'Local',
}

local displayOrientation = {
    [0] = 'Auto',
    [1] = 'Portrait',
    [2] = 'Landscape',
    [3] = 'Portrait Flipped',
    [4] = 'Landscape Flipped',
}

local workoutEquipment = {
    [0] = 'None',
    [1] = 'Swim Fins',
    [2] = 'Swim Kickboard',
    [3] = 'Swim Paddles',
    [4] = 'Swim Pull Buoy',
    [5] = 'Swim Snorkel',
}

local watchfaceMode = {
    [0] = 'Digital',
    [1] = 'Analog',
    [2] = 'Connect IQ',
    [3] = 'Disabled',
}

local cameraEventType = {
    [0] = 'Video Start',
    [1] = 'Video Split',
    [2] = 'Video End',
    [3] = 'Photo Taken',
    [4] = 'Video Second Stream Start',
    [5] = 'Video Second Stream Split',
    [6] = 'Video Second Stream End',
    [7] = 'Video Split Start',
    [8] = 'Video Second Stream Split Start',
    [11] = 'Video Pause',
    [12] = 'Video Second Stream Pause',
    [13] = 'Video Resume',
    [14] = 'Video Second Stream Resume',
}

local sensorType = {
    [0] = 'Accelerometer',
    [1] = 'Gyroscope',
    [2] = 'Compass',
    [3] = 'Barometer',
    [4] = 'Speed', --4
    [5] = 'Speed Cadence', --4
    [6] = 'Tempe', --4
    [8] = 'Shimano Di2', --4
    [10] = 'Edge Remote', --4
    [12] = 'Smart Trainer', --4
    [13] = 'Lights', --4
    [14] = 'Radar', --4
    [15] = 'Extended Display', --4
    [16] = 'Shifting', --4
    [17] = 'Muscle O2', --4
    [18] = 'Rd Pod', --4
    [22] = 'Headphones', --4
    [28] = 'Tank Pressure', --4
}

local cameraOrientationType = {
    [0] = 'Camera Orientation 0',
    [1] = 'Camera Orientation 90',
    [2] = 'Camera Orientation 180',
    [3] = 'Camera Orientation 270',
}

local autoSyncFrequency = {
    [0] = 'Never',
    [1] = 'Occasionally',
    [2] = 'Frequent',
    [3] = 'Once A Day',
    [4] = 'Remote',
}

local exdLayout = {
    [0] = 'Full Screen',
    [1] = 'Half Vertical',
    [2] = 'Half Horizontal',
    [3] = 'Half Vertical Right Split',
    [4] = 'Half Horizontal Bottom Split',
    [5] = 'Full Quarter Split',
    [6] = 'Half Vertical Left Split',
    [7] = 'Half Horizontal Top Split',
    [8] = 'Dynamic',
}

local exdDisplayType = {
    [0] = 'Numerical',
    [1] = 'Simple',
    [2] = 'Graph',
    [3] = 'Bar',
    [4] = 'Circle Graph',
    [5] = 'Virtual Partner',
    [6] = 'Balance',
    [7] = 'String List',
    [8] = 'String',
    [9] = 'Simple Dynamic Icon',
    [10] = 'Gauge',
}

local exdDataUnits = {
    [0] = 'No Units',
    [1] = 'laps',
    [2] = 'mph',
    [3] = 'km/h',
    [4] = 'ft/h',
    [5] = 'm/h',
    [6] = 'C',
    [7] = 'F',
    [8] = 'Zone',
    [9] = 'Gear',
    [10] = 'RPM',
    [11] = 'BPM',
    [12] = 'degrees',
    [13] = 'mm',
    [14] = 'm',
    [15] = 'km',
    [16] = 'ft',
    [17] = 'yards',
    [18] = 'kilofeet',
    [19] = 'miles',
    [20] = 'time',
    [21] = 'Enum Turn Type',
    [22] = '%',
    [23] = 'W',
    [24] = 'W/kg',
    [25] = 'Enum Battery Status',
    [26] = 'Enum Bike Light Beam Angle Mode',
    [27] = 'Enum Bike Light Battery Status',
    [28] = 'Enum Bike Light Network Config Type',
    [29] = 'Lights',
    [30] = 's',
    [31] = 'minutes',
    [32] = 'hours',
    [33] = 'Calories',
    [34] = 'kJ',
    [35] = 'ms',
    [36] = 's/mile',
    [37] = 's/km',
    [38] = 'cm',
    [39] = 'Enum Course Point',
    [40] = 'bradians',
    [41] = 'Enum Sport',
    [42] = 'inches Hg',
    [43] = 'mm Hg',
    [44] = 'mbar',
    [45] = 'hPa',
    [46] = 'ft/min',
    [47] = 'm/min',
    [48] = 'm/s',
    [49] = 'Eight Cardinal',
}

local exdQualifiers = {
    [0] = 'No Qualifier',
    [1] = 'Instantaneous',
    [2] = 'Average',
    [3] = 'Lap',
    [4] = 'Maximum',
    [5] = 'Maximum Average',
    [6] = 'Maximum Lap',
    [7] = 'Last Lap',
    [8] = 'Average Lap',
    [9] = 'To Destination',
    [10] = 'To Go',
    [11] = 'To Next',
    [12] = 'Next Course Point',
    [13] = 'Total',
    [14] = 'Three Second Average',
    [15] = 'Ten Second Average',
    [16] = 'Thirty Second Average',
    [17] = 'Percent Maximum',
    [18] = 'Percent Maximum Average',
    [19] = 'Lap Percent Maximum',
    [20] = 'Elapsed',
    [21] = 'Sunrise',
    [22] = 'Sunset',
    [23] = 'Compared To Virtual Partner',
    [24] = 'Maximum 24h',
    [25] = 'Minimum 24h',
    [26] = 'Minimum',
    [27] = 'First',
    [28] = 'Second',
    [29] = 'Third',
    [30] = 'Shifter',
    [31] = 'Last Sport',
    [32] = 'Moving',
    [33] = 'Stopped',
    [34] = 'Estimated Total',
    [242] = 'Zone 9',
    [243] = 'Zone 8',
    [244] = 'Zone 7',
    [245] = 'Zone 6',
    [246] = 'Zone 5',
    [247] = 'Zone 4',
    [248] = 'Zone 3',
    [249] = 'Zone 2',
    [250] = 'Zone 1',
}

local exdDescriptors = {
    [0] = 'Bike Light Battery Status',
    [1] = 'Beam Angle Status',
    [2] = 'Batery Level',
    [3] = 'Light Network Mode',
    [4] = 'Number Lights Connected',
    [5] = 'Cadence',
    [6] = 'Distance',
    [7] = 'Estimated Time Of Arrival',
    [8] = 'Heading',
    [9] = 'time',
    [10] = 'Battery Level',
    [11] = 'Trainer Resistance',
    [12] = 'Trainer Target Power',
    [13] = 'Time Seated',
    [14] = 'Time Standing',
    [15] = 'Elevation',
    [16] = 'Grade',
    [17] = 'Ascent',
    [18] = 'Descent',
    [19] = 'Vertical Speed',
    [20] = 'Di2 Battery Level',
    [21] = 'Front Gear',
    [22] = 'Rear Gear',
    [23] = 'Gear Ratio',
    [24] = 'Heart Rate',
    [25] = 'Heart Rate Zone',
    [26] = 'Time In Heart Rate Zone',
    [27] = 'Heart Rate Reserve',
    [28] = 'Calories',
    [29] = 'GPS Accuracy',
    [30] = 'GPS Signal Strength',
    [31] = 'Temperature',
    [32] = 'Time Of Day',
    [33] = 'Balance',
    [34] = 'Pedal Smoothness',
    [35] = 'Power',
    [36] = 'Functional Threshold Power',
    [37] = 'Intensity Factor',
    [38] = 'Work',
    [39] = 'Power Ratio',
    [40] = 'Normalized Power',
    [41] = 'Training Stress Score',
    [42] = 'Time On Zone',
    [43] = 'Speed',
    [44] = 'laps',
    [45] = 'Reps',
    [46] = 'Workout Step',
    [47] = 'Course Distance',
    [48] = 'Navigation Distance',
    [49] = 'Course Estimated Time Of Arrival',
    [50] = 'Navigation Estimated Time Of Arrival',
    [51] = 'Course Time',
    [52] = 'Navigation Time',
    [53] = 'Course Heading',
    [54] = 'Navigation Heading',
    [55] = 'Power Zone',
    [56] = 'Torque Effectiveness',
    [57] = 'Timer Time',
    [58] = 'Power Weight Ratio',
    [59] = 'Left Platform Center Offset',
    [60] = 'Right Platform Center Offset',
    [61] = 'Left Power Phase Start Angle',
    [62] = 'Right Power Phase Start Angle',
    [63] = 'Left Power Phase Finish Angle',
    [64] = 'Right Power Phase Finish Angle',
    [65] = 'Gears',
    [66] = 'Pace',
    [67] = 'Training Effect',
    [68] = 'Vertical Oscillation',
    [69] = 'Vertical Ratio',
    [70] = 'Ground Contact Time',
    [71] = 'Left Ground Contact Time Balance',
    [72] = 'Right Ground Contact Time Balance',
    [73] = 'Stride Length',
    [74] = 'Running Cadence',
    [75] = 'Performance Condition',
    [76] = 'Course Type',
    [77] = 'Time In Power Zone',
    [78] = 'Navigation Turn',
    [79] = 'Course Location',
    [80] = 'Navigation Location',
    [81] = 'Compass',
    [82] = 'Gear Combo',
    [83] = 'Muscle Oxygen',
    [84] = 'Icon',
    [85] = 'Compass Heading',
    [86] = 'GPS Heading',
    [87] = 'GPS Elevation',
    [88] = 'Anaerobic Training Effect',
    [89] = 'Course',
    [90] = 'Off Course',
    [91] = 'Glide Ratio',
    [92] = 'Vertical Distance',
    [93] = 'Vmg',
    [94] = 'Ambient Pressure',
    [95] = 'Pressure',
    [96] = 'Vam',
}

local fitBaseType = {
    [0] = 'enum',
    [1] = 'sint8',
    [2] = 'uint8',
    [7] = 'string',
    [10] = 'uint8z',
    [13] = 'byte',
    [131] = 'sint16',
    [132] = 'uint16',
    [133] = 'sint32',
    [134] = 'uint32',
    [136] = 'float32',
    [137] = 'float64',
    [139] = 'uint16z',
    [140] = 'uint32z',
    [142] = 'sint64',
    [143] = 'uint64',
    [144] = 'uint64z',
}

local fitBaseUnit = {
    [0] = 'Other',
    [1] = 'Kilogram',
    [2] = 'Pound',
}

local setType = {
    [0] = 'Rest',
    [1] = 'Active',
}

local maxMetCategory = {
    [0] = 'Generic',
    [1] = 'Cycling',
}

local exerciseCategory = {
    [0] = 'Bench Press',
    [1] = 'Calf Raise',
    [2] = 'Cardio',
    [3] = 'Carry',
    [4] = 'Chop',
    [5] = 'Core',
    [6] = 'Crunch',
    [7] = 'Curl',
    [8] = 'Deadlift',
    [9] = 'Flye',
    [10] = 'Hip Raise',
    [11] = 'Hip Stability',
    [12] = 'Hip Swing',
    [13] = 'Hyperextension',
    [14] = 'Lateral Raise',
    [15] = 'Leg Curl',
    [16] = 'Leg Raise',
    [17] = 'Lunge',
    [18] = 'Olympic Lift',
    [19] = 'Plank',
    [20] = 'Plyo',
    [21] = 'Pull Up',
    [22] = 'Push Up',
    [23] = 'Row',
    [24] = 'Shoulder Press',
    [25] = 'Shoulder Stability',
    [26] = 'Shrug',
    [27] = 'Sit Up',
    [28] = 'Squat',
    [29] = 'Total Body',
    [30] = 'Triceps Extension',
    [31] = 'Warm Up',
    [32] = 'Run',
    [33] = 'Bike',
    [34] = 'Cardio Sensors',
    [35] = 'Move',
    [36] = 'Pose',
    [37] = 'Banded Exercises',
    [38] = 'Battle Rope',
    [39] = 'Elliptical',
    [40] = 'Floor Climb',
    [41] = 'Indoor Bike',
    [42] = 'Indoor Row',
    [43] = 'Ladder',
    [44] = 'Sandbag',
    [45] = 'Sled',
    [46] = 'Sledge Hammer',
    [47] = 'Stair Stepper',
    [49] = 'Suspension',
    [50] = 'Tire',
    [52] = 'Run Indoor',
    [53] = 'Bike Outdoor',
    [65534] = 'Unknown',
}

local waterType = {
    [0] = 'Fresh',
    [1] = 'Salt',
    [2] = 'En13319',
    [3] = 'Custom',
}

local tissueModelType = {
    [0] = 'Zhl 16c',
}

local diveGasStatus = {
    [0] = 'Disabled',
    [1] = 'Enabled',
    [2] = 'Backup Only',
}

local diveAlarmType = {
    [0] = 'Depth',
    [1] = 'time',
    [2] = 'Speed',
}

local diveBacklightMode = {
    [0] = 'At Depth',
    [1] = 'Always On',
}

local sleepLevelEnum = {
    [0] = 'Unmeasurable',
    [1] = 'Awake',
    [2] = 'Light',
    [3] = 'Deep',
    [4] = 'Rem',
}

local sPO2MeasurementType = {
    [0] = 'Off Wrist',
    [1] = 'Spot Check',
    [2] = 'Continuous Check',
    [3] = 'Periodic',
}

local cCRSetpointSwitchMode = {
    [0] = 'Manual',
    [1] = 'Automatic',
}

local diveGasMode = {
    [0] = 'Open Circuit',
    [1] = 'Closed Circuit Diluent',
}

local projectileType = {
    [0] = 'Arrow',
    [1] = 'Rifle Cartridge',
    [2] = 'Pistol Cartridge',
    [3] = 'Shotshell',
    [4] = 'Air Rifle Pellet',
    [5] = 'Other',
}

local splitType = {
    [1] = 'Ascent Split',
    [2] = 'Descent Split',
    [3] = 'Interval Active',
    [4] = 'Interval Rest',
    [5] = 'Interval Warmup',
    [6] = 'Interval Cooldown',
    [7] = 'Interval Recovery',
    [8] = 'Interval Other',
    [9] = 'Climb Active',
    [10] = 'Climb Rest',
    [11] = 'Surf Active',
    [12] = 'Run Active',
    [13] = 'Run Rest',
    [14] = 'Workout Round',
    [17] = 'Rwd Run',
    [18] = 'Rwd Walk',
    [21] = 'Windsurf Active',
    [22] = 'Rwd Stand',
    [23] = 'Transition',
    [28] = 'Ski Lift Split',
    [29] = 'Ski Run Split',
}

local climbProEvent = {
    [0] = 'Approach',
    [1] = 'Start',
    [2] = 'Complete',
}

local gasConsumptionRateType = {
    [0] = 'Pressure Sac',
    [1] = 'Volume Sac',
    [2] = 'Rmv',
}

local tapSensitivity = {
    [0] = 'High',
    [1] = 'Medium',
    [2] = 'Low',
}

local radarThreatLevelType = {
    [0] = 'Threat Unknown',
    [1] = 'Threat None',
    [2] = 'Threat Approaching',
    [3] = 'Threat Approaching Fast',
}

local sleepDisruptionSeverity = {
    [0] = 'None',
    [1] = 'Low',
    [2] = 'Medium',
    [3] = 'High',
}

local napPeriodFeedback = {
    [0] = 'None',
    [1] = 'Multiple Naps During Day',
    [2] = 'Jetlag Ideal Timing Ideal Duration',
    [3] = 'Jetlag Ideal Timing Long Duration',
    [4] = 'Jetlag Late Timing Ideal Duration',
    [5] = 'Jetlag Late Timing Long Duration',
    [6] = 'Ideal Timing Ideal Duration Low Need',
    [7] = 'Ideal Timing Ideal Duration High Need',
    [8] = 'Ideal Timing Long Duration Low Need',
    [9] = 'Ideal Timing Long Duration High Need',
    [10] = 'Late Timing Ideal Duration Low Need',
    [11] = 'Late Timing Ideal Duration High Need',
    [12] = 'Late Timing Long Duration Low Need',
    [13] = 'Late Timing Long Duration High Need',
    [14] = 'Ideal Duration Low Need',
    [15] = 'Ideal Duration High Need',
    [16] = 'Long Duration Low Need',
    [17] = 'Long Duration High Need',
}

local napSource = {
    [0] = 'Automatic',
    [1] = 'Manual Device',
    [2] = 'Manual Gc',
}

local maxMetSpeedSource = {
    [0] = 'Onboard GPS',
    [1] = 'Connected GPS',
    [2] = 'Cadence',
}

local maxMetHeartRateSource = {
    [0] = 'Whr',
    [1] = 'HRM',
}

local hRVStatus = {
    [0] = 'None',
    [1] = 'Poor',
    [2] = 'Low',
    [3] = 'Unbalanced',
    [4] = 'Balanced',
}

local noFlyTimeMode = {
    [0] = 'Standard',
    [1] = 'Flat 24 Hours',
}

------------------------------------------------------------------------
-- Undocumented enumerated types (ref 4)
--
local alarmLabel = {
    [0] = 'None',
    [1] = 'Wake Up',
    [2] = 'Workout',
    [3] = 'Reminder',
    [4] = 'Appointment',
    [5] = 'Training',
    [6] = 'Class',
    [7] = 'Meditate',
    [8] = 'Bedtime',
}

local alarmRepeat = {
    BITMASK = {
        [0] = 'Mon',
        [1] = 'Tue',
        [2] = 'Wed',
        [3] = 'Thu',
        [4] = 'Fri',
        [5] = 'Sat',
        [6] = 'Sun',
        [7] = 'Once',
    },
}

local alertMetric = {
    [0] = 'time',
    [1] = 'Distance',
    [2] = 'Calories',
    [3] = 'Ascent',
    [4] = 'Descent',
    [5] = 'Reps',
    [7] = 'Smart',
    [8] = 'Pacing',
}

local alertZone = {
    [0] = 'Off',
    [1] = 'Custom',
    [101] = 'Zone 1',
    [102] = 'Zone 2',
    [103] = 'Zone 3',
    [104] = 'Zone 4',
    [105] = 'Zone 5',
}

local allow = {
    [0] = 'Do Not Allow',
    [1] = 'Allow',
}

local autoLapMode = {
    [0] = 'time',
    [1] = 'Distance',
    [2] = 'Position',
    [6] = 'Manual Only',
}

local autoPauseSetting = {
    [0] = 'Off',
    [1] = 'When Stopped',
    [2] = 'Custom',
}

local autoScrollMode = {
    [0] = 'Off',
    [1] = 'Slow',
    [2] = 'Medium',
    [3] = 'Fast',
}

local avoidances = {
    BITMASK = {
        [0] = 'U Turns',
        [1] = 'Toll Roads',
        [2] = 'Major Highways',
        [3] = 'Unpaved Roads',
        [4] = 'Carpool Lanes',
        [5] = 'Interstate Hwy',
        [6] = 'Ferries',
        [7] = 'Narrow Trails',
        [8] = 'Climbing Paths',
    },
}

local benefit = {
    [0] = 'No Benefit',
    [1] = 'Recovery',
    [2] = 'Base',
    [3] = 'Tempo',
    [4] = 'Threshold',
    [5] = 'VO2 Max',
    [6] = 'Anaerobic',
    [7] = 'Sprint',
}

local calculationMethod = {
    [0] = 'Minimize Time',
    [1] = 'Minimize Distance',
    [3] = 'Minimize Ascent',
}

local climbDetection = {
    [1] = 'Cat 4',
    [2] = 'Cat 3',
    [3] = 'Cat 2',
    [4] = 'Cat 1',
    [5] = 'Hc',
    [6] = 'Uncategorized',
}

local climbProMode = {
    [1] = 'When Navigating',
    [2] = 'Always',
}

local climbProTerrain = {
    [0] = 'Paved',
    [1] = 'Unpaved',
    [3] = 'Mixed',
}

local connectionType = {
    [0] = 'Antplus',
    [1] = 'Bluetooth Low Energy',
    [2] = 'Bluetooth',
}

local courseRecalculation = {
    [0] = 'Auto Pause',
    [1] = 'Auto Reroute',
    [2] = 'Prompt Only',
    [3] = 'Prompt With Auto Reroute',
}

local courses = {
    [0] = 'Follow Course',
    [1] = 'Use Map',
}

local dataFields = {
    [0] = 'Total Calories',
    [3] = 'Cadence',
    [4] = 'Avg Cadence',
    [5] = 'Lap Cadence',
    [6] = 'Distance',
    [7] = 'Lap Distance',
    [9] = 'Altitude',
    [11] = 'Grade',
    [12] = 'Heading',
    [13] = 'Heart Rate',
    [14] = 'Avg HR',
    [15] = 'Lap HR',
    [16] = 'HR Max',
    [17] = 'Avg HR Max',
    [18] = 'Lap HR Max',
    [19] = 'HRr',
    [20] = 'Avg HRr',
    [21] = 'Lap HRr',
    [22] = 'HR Zone',
    [23] = 'HR Gauge',
    [24] = 'laps',
    [28] = 'Ete',
    [29] = 'Distance To Next',
    [30] = 'Time To Next',
    [31] = 'Dest Wpt',
    [32] = 'Next Wpt',
    [33] = 'Pace',
    [34] = 'Avg Pace',
    [35] = 'Lap Pace',
    [36] = 'Power',
    [37] = 'Avg Power',
    [39] = 'Lap Power',
    [40] = 'Max Power',
    [43] = 'Power Zone',
    [45] = 'Steps',
    [48] = 'Speed',
    [49] = 'Avg Speed',
    [50] = 'Lap Speed',
    [53] = 'Sunrise',
    [54] = 'Sunset',
    [55] = 'Elapsed Time',
    [56] = 'Timer',
    [57] = 'Avg Lap Time',
    [58] = 'Lap Time',
    [59] = 'Time Of Day',
    [60] = 'Total Ascent',
    [61] = 'Total Descent',
    [63] = 'Time Ahead',
    [67] = 'Repetition',
    [77] = 'Vert Spd',
    [78] = 'Temperature',
    [80] = '30 S Power',
    [84] = 'Last Lap Distance',
    [85] = 'Last Lap Pace',
    [86] = 'Last Lap Speed',
    [87] = 'Last Lap Time',
    [91] = 'Maximum Speed',
    [92] = 'Bearing',
    [93] = 'Eta',
    [94] = 'Eta At Next',
    [96] = 'Battery Pct',
    [97] = 'GPS',
    [99] = 'Aerobic Te',
    [100] = 'Last Lap Power',
    [108] = 'Last Lap Cadence',
    [165] = 'Last Lap HR',
    [170] = 'Vertical Oscillation',
    [171] = 'Avg Vert Osc',
    [172] = 'Lap Vert Osc',
    [173] = 'Ground Contact Time',
    [174] = 'Avg Gct',
    [175] = 'Lap Gct',
    [187] = 'Last Lap HR Max',
    [188] = 'Last Lap HRr',
    [197] = 'Dist Remaining',
    [199] = 'Time In HR Zone 1',
    [200] = 'Time In HR Zone 2',
    [201] = 'Time In HR Zone 3',
    [202] = 'Time In HR Zone 4',
    [203] = 'Time In HR Zone 5',
    [214] = '24 Hour Max',
    [215] = '24 Hour Min',
    [216] = 'Connect IQ Field',
    [219] = 'Avg Ascent',
    [220] = 'Avg Descent',
    [221] = 'Max Ascent',
    [222] = 'Max Descent',
    [223] = 'Lap Ascent',
    [224] = 'Lap Descent',
    [225] = 'Last Lap Ascent',
    [226] = 'Last Lap Descent',
    [227] = 'Min Altitude',
    [228] = 'Max Altitude',
    [229] = 'GPS Altitude',
    [230] = 'Vert Dist To Dest',
    [231] = 'Ambient Press',
    [233] = 'Glide Ratio',
    [234] = 'Glide Ratio Dest',
    [235] = 'Vert Speed To Tgt',
    [236] = 'Course',
    [237] = 'GPS Heading',
    [238] = 'Compass Hdg',
    [239] = 'Off Course',
    [240] = 'Location',
    [241] = 'Dest Location',
    [242] = 'Lat Lon',
    [243] = 'Vel Made Good',
    [245] = 'Active Calories',
    [246] = 'Next Fork',
    [302] = 'Step Distance',
    [303] = 'Step Time',
    [304] = 'Step Speed',
    [305] = 'Step Pace',
    [307] = 'Gct Balance',
    [308] = 'Avg Gct Bal',
    [309] = 'Lap Gct Bal',
    [310] = 'Vertical Ratio',
    [311] = 'Avg Vert Ratio',
    [312] = 'Lap Vert Ratio',
    [313] = 'Stride Length',
    [314] = 'Avg Stride Len',
    [315] = 'Lap Stride Len',
    [320] = 'Perform Cond',
    [395] = 'Battery Hours',
    [423] = 'Muscle O2 Sat',
    [424] = 'Total Hemaglobin',
    [433] = 'Anaerobic Te',
    [452] = 'Resp Rate',
    [455] = 'Total Time',
    [462] = 'Est Total Dist',
    [478] = 'Load',
    [511] = 'Workout Comparison',
    [512] = 'Cadence Gauge',
    [520] = 'Primary Target',
    [522] = 'Duration',
    [524] = 'Vert Osc Gauge',
    [525] = 'Vert Ratio Gauge',
    [526] = 'Ground Contact Time Gauge',
    [527] = 'Gct Balance Gauge',
    [528] = 'Power Gauge',
    [529] = 'Compass Gauge',
    [530] = 'Te Gauge',
    [531] = 'Asc Des Gauge',
    [532] = 'Overall Ahead Behind',
    [578] = 'Secondary Target',
    [580] = 'Stamina Potential',
    [581] = 'Stamina',
    [582] = 'Distance Remaining',
    [583] = 'Time Remaining',
    [585] = 'Gauge Dist',
    [586] = 'Altitude Chart',
    [587] = 'Barometer Chart',
    [588] = 'Heart Rate Chart',
    [589] = 'Pace Chart',
    [590] = 'Speed Chart',
    [591] = 'Power Chart',
    [597] = 'Gauge Time',
    [610] = 'HR Zones Ratio',
    [616] = 'Time Of Day Seconds',
    [656] = 'Grade Adjusted Pace',
}

local enduranceScoreLevel = {
    [1] = 'Recreational',
    [2] = 'Intermediate',
    [3] = 'Trained',
    [4] = 'Well-trained',
    [5] = 'Expert',
    [6] = 'Superior',
    [7] = 'Elite',
}

local ePOCPEStatus = {
    [0] = 'Expired',
    [1] = 'Current',
}

local fairway = {
    [0] = 'Left',
    [1] = 'Right',
    [2] = 'Hit',
}

local genderX = {
    [0] = 'Female',
    [1] = 'Male',
    [2] = 'Not Specified',
}

local gPSType = {
    [11] = 'Ultra Trac Trigger',
    [49] = 'Mode Change',
}

local guideText = {
    [0] = 'Never Display',
    [1] = 'Always Display',
    [2] = 'When Navigating',
}

local hillScoreLevel = {
    [1] = 'Recreational',
    [2] = 'Challenger',
    [3] = 'Trained',
    [4] = 'Skilled',
    [5] = 'Expert',
    [6] = 'Elite',
}

local lightSectorsStatus = {
    [0] = 'Off',
    [1] = 'On',
    [2] = 'Auto',
}

local mapSymbol = {
    [0] = 'Airport',
    [1] = 'Amusement Park',
    [2] = 'Anchor',
    [3] = 'Ball Park',
    [4] = 'Bank',
    [5] = 'Bar',
    [6] = 'Block Blue',
    [7] = 'Boat Ramp',
    [8] = 'Bowling',
    [9] = 'Bridge',
    [10] = 'Building',
    [11] = 'Campground',
    [12] = 'Car',
    [13] = 'Car Rental',
    [14] = 'Car Repair',
    [15] = 'Cemetery',
    [16] = 'Church',
    [17] = 'City Large',
    [18] = 'City Medium',
    [19] = 'City Small',
    [20] = 'Civil',
    [21] = 'Controlled Area',
    [22] = 'Convenience Store',
    [23] = 'Crossing',
    [24] = 'Dam',
    [25] = 'Skull And Crossbones',
    [26] = 'Danger Area',
    [27] = 'Department Store',
    [28] = 'Diver Down Flag 1',
    [29] = 'Diver Down Flag 2',
    [30] = 'Drinking Water',
    [32] = 'Fast Food',
    [33] = 'Fishing Area',
    [34] = 'Fitness Center',
    [35] = 'Forest',
    [36] = 'Gas Station',
    [37] = 'Glider Area',
    [38] = 'Golf Course',
    [39] = 'Lodging',
    [40] = 'Hunting Area',
    [41] = 'Information',
    [42] = 'Live Theater',
    [43] = 'Light',
    [44] = 'Man Overboard',
    [45] = 'Hospital 2',
    [46] = 'Mine',
    [47] = 'Movie Theater',
    [48] = 'Museum',
    [49] = 'Oil Field',
    [50] = 'Parachute Area',
    [51] = 'Park',
    [52] = 'Parking 2',
    [53] = 'Pharmacy',
    [54] = 'Picnic Area',
    [55] = 'Pizza',
    [56] = 'Post Office',
    [57] = 'Rv Park',
    [58] = 'Residence',
    [59] = 'Restricted Area',
    [60] = 'Restaurant',
    [61] = 'Restroom',
    [62] = 'Scales',
    [63] = 'Scenic Area',
    [64] = 'School',
    [65] = 'Shipwreck',
    [66] = 'Shopping Center',
    [67] = 'Short Tower',
    [68] = 'Shower',
    [69] = 'Skiing Area',
    [70] = 'Stadium',
    [71] = 'Summit',
    [72] = 'Swimming Area',
    [73] = 'Tall Tower',
    [74] = 'Telephone',
    [75] = 'Toll Booth',
    [76] = 'Trail Head',
    [77] = 'Truck Stop',
    [78] = 'Tunnel',
    [79] = 'Ultralight Area',
    [80] = 'Zoo',
    [81] = 'Geocache',
    [82] = 'Geocache Found',
    [83] = 'Flag Blue',
    [84] = 'Pin Blue',
    [85] = 'Bike Trail',
    [86] = 'Ice Skating',
    [88] = 'Beacon',
    [89] = 'Horn',
    [90] = 'Beach',
    [91] = 'Buoy White',
    [92] = 'Wrecker',
    [93] = 'Navaid Amber',
    [94] = 'Navaid Black',
    [95] = 'Navaid Blue',
    [96] = 'Navaid Green White',
    [97] = 'Navaid Green',
    [98] = 'Navaid Green Red',
    [99] = 'Navaid Orange',
    [100] = 'Navaid Red Green',
    [101] = 'Navaid Red White',
    [102] = 'Navaid Red',
    [103] = 'Navaid Violet',
    [104] = 'Navaid White',
    [105] = 'Navaid White Green',
    [106] = 'Navaid White Red',
    [108] = 'Bell',
    [109] = 'Block Green',
    [110] = 'Block Red',
    [111] = 'Food Source',
    [116] = 'Flag Green',
    [117] = 'Flag Red',
    [118] = 'Pin Green',
    [119] = 'Pin Red',
    [120] = 'Atv',
    [121] = 'Big Game',
    [122] = 'Blind',
    [123] = 'Blood Trail',
    [124] = 'Cover',
    [125] = 'Covey',
    [127] = 'Furbearer',
    [128] = 'Lodge',
    [129] = 'Small Game',
    [130] = 'Animal Tracks',
    [131] = 'Treed Quarry',
    [132] = 'Tree Stand',
    [133] = 'Truck',
    [134] = 'Upland Game',
    [135] = 'Waterfowl',
    [136] = 'Water Source',
}

local navigationPrompt = {
    [1] = 'Text Only',
    [2] = 'Map',
}

local openWaterEventType = {
    [44] = 'Change Stroke',
}

local orientation = {
    [0] = 'North Up',
    [1] = 'Track Up',
}

local powerAveraging = {
    [0] = 'Include Zeros',
    [1] = 'Do Not Include Zeros',
}

local powerSaveTimeout = {
    [0] = 'Normal',
    [1] = 'Extended',
}

local recordMetric = {
    [0] = 'time',
    [1] = 'Distance',
    [2] = 'Ascent',
    [3] = 'Power',
}

local reliefShading = {
    [0] = 'Default',
    [1] = 'Off',
    [2] = 'On',
}

local routeRecalculation = {
    [0] = 'Automatic',
    [1] = 'Off',
    [2] = 'Prompted',
}

local routingMode = {
    [0] = 'Automobile Driving',
    [1] = 'Road Cycling',
    [2] = 'Pedestrian',
    [4] = 'Mountain Biking',
    [5] = 'Straight Line',
    [6] = 'Motorcycle Driving',
    [11] = 'Gravel Cycling',
    [12] = 'Mixed Surface Cycling',
}

local routingType = {
    [0] = 'Bearing',
    [1] = 'Course',
}

local runningPowerMode = {
    [0] = 'Off',
    [1] = 'Accessory Mode',
    [2] = 'Wrist Only',
    [3] = 'Smart Mode',
}

local satellites = {
    [0] = 'Off',
    [1] = 'GPS Only',
    [2] = 'GPS Glonass',
    [3] = 'Ultra Trac',
    [5] = 'GPS Galileo',
    [7] = 'All Systems',
    [8] = 'All Multi Band',
    [9] = 'Auto Select',
}

local screenType = {
    [21] = 'Clock',
    [22] = 'HR Gauge',
    [25] = 'Map',
    [26] = 'Virtual Partner',
    [27] = 'Run Dynamics',
    [30] = 'Music',
    [32] = 'Custom Lap Banner',
    [35] = 'Compass',
    [38] = 'Workout',
    [44] = 'Altitude',
    [56] = 'Segment',
    [57] = 'Group Track List',
    [74] = 'Lap Summary',
    [104] = 'Climb Pro',
    [109] = 'Track Laps',
    [122] = 'Track Summary',
    [127] = 'Stamina',
    [162] = 'Group Ride',
}

local selfEvaluationStatus = {
    [0] = 'Off',
    [1] = 'Workouts Only',
    [2] = 'Always',
}

local soundAndVibe = {
    [0] = 'Off',
    [1] = 'Tone',
    [2] = 'Vibration',
    [3] = 'Tone And Vibe',
}

local sportChange = {
    [0] = 'Manual Only',
    [1] = 'On',
}

local touchStatus = {
    [0] = 'Off',
    [1] = 'On',
    [2] = 'System',
    [3] = 'Map Only',
}

local trainingReadinessLevel = {
    [1] = 'Poor',
    [2] = 'Low',
    [3] = 'Moderate',
    [4] = 'High',
    [5] = 'Prime',
}

local useStatus = {
    [0] = 'Off',
    [1] = 'Indoor',
    [2] = 'Always',
}

local visibilityStatus = {
    [0] = 'Hide',
    [1] = 'Show',
}

local volume = {
    [1] = 'Ounces',
    [2] = 'Milliliters',
}

local waypointAction = {
    [0] = 'Add To Existing',
    [1] = 'Replace Existing',
    [2] = 'Delete All',
}

local windDataStatus = {
    [0] = 'Disabled',
    [1] = 'Enabled',
}

local yesNo = {
    [0] = 'No',
    [1] = 'Yes',
}

local zoneMetric = {
    [0] = 'Heart Rate',
    [1] = 'Speed',
    [2] = 'Cadence',
    [3] = 'Power',
    [4] = 'Elevation',
}

------------------------------------------------------------------------
-- Table of all supported Garmin FIT messages
--
Garmin.FIT = {
    GROUPS = { [0] = 'Garmin', [1] = 'File', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1, ALPHA_FIRST = 1 },
    NOTES = [[
        Information extracted from Garmin FIT (Flexible and Interoperable data
        Transfer) files.  The main reason for adding FIT support was to allow
        geotagging directly from FIT files using the -geotag option.  For this
        reason, only timestamps and GPS-related FIT messages are decoded by default,
        and the rest are marked as Unknown to be extracted only if the L<Unknown|../ExifTool.html#Unknown>
        (-u) option is used. And unless the L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> (-ee) option is used,
        only the first FIT message of each type is extracted. When both of these
        options are used, a significant amount of information may be extracted, and
        processing times may be lengthy. The family 1 group names of the extracted
        tags correspond to the FIT message names. The first table below lists the
        FIT messages, and subsequent tables list the extracted tags. See
        L<https://developer.garmin.com/fit/> for the specification.
    ]],
    vers = { Name = 'ProtocolVersion', Notes = 'from the FIT file header' },
    Common = { Name = 'Common', SubDirectory = { TagTable = 'lexiftool.Garmin.Common' }, Hidden = 2 },
    [0] = { Name = 'FileID', SubDirectory = { TagTable = 'lexiftool.Garmin.FileID' }, Unknown = 1 },
    [1] = { Name = 'Capabilities', SubDirectory = { TagTable = 'lexiftool.Garmin.Capabilities' }, Unknown = 1 },
    [2] = { Name = 'DeviceSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.DeviceSettings' }, Unknown = 1 },
    [3] = { Name = 'UserProfile', SubDirectory = { TagTable = 'lexiftool.Garmin.UserProfile' }, Unknown = 1 },
    [4] = { Name = 'HRMProfile', SubDirectory = { TagTable = 'lexiftool.Garmin.HRMProfile' }, Unknown = 1 },
    [5] = { Name = 'SDMProfile', SubDirectory = { TagTable = 'lexiftool.Garmin.SDMProfile' }, Unknown = 1 },
    [6] = { Name = 'BikeProfile', SubDirectory = { TagTable = 'lexiftool.Garmin.BikeProfile' }, Unknown = 1 },
    [7] = { Name = 'ZonesTarget', SubDirectory = { TagTable = 'lexiftool.Garmin.ZonesTarget' }, Unknown = 1 },
    [8] = { Name = 'HRZone', SubDirectory = { TagTable = 'lexiftool.Garmin.HRZone' }, Unknown = 1 },
    [9] = { Name = 'PowerZone', SubDirectory = { TagTable = 'lexiftool.Garmin.PowerZone' }, Unknown = 1 },
    [10] = { Name = 'MetZone', SubDirectory = { TagTable = 'lexiftool.Garmin.MetZone' }, Unknown = 1 },
    [12] = { Name = 'Sport', SubDirectory = { TagTable = 'lexiftool.Garmin.Sport' }, Unknown = 1 },
    [13] = { Name = 'TrainingSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.TrainingSettings' }, Unknown = 1 },
    [14] = { Name = 'DataScreen', SubDirectory = { TagTable = 'lexiftool.Garmin.DataScreen' }, Unknown = 1 }, --4
    [15] = { Name = 'Goal', SubDirectory = { TagTable = 'lexiftool.Garmin.Goal' }, Unknown = 1 },
    [16] = { Name = 'Alert', SubDirectory = { TagTable = 'lexiftool.Garmin.Alert' }, Unknown = 1 }, --4
    [17] = { Name = 'RangeAlert', SubDirectory = { TagTable = 'lexiftool.Garmin.RangeAlert' }, Unknown = 1 }, --4
    [18] = { Name = 'Session', SubDirectory = { TagTable = 'lexiftool.Garmin.Session' } },
    [19] = { Name = 'Lap', SubDirectory = { TagTable = 'lexiftool.Garmin.Lap' } },
    [20] = { Name = 'Record', SubDirectory = { TagTable = 'lexiftool.Garmin.Record' } },
    [21] = { Name = 'Event', SubDirectory = { TagTable = 'lexiftool.Garmin.Event' }, Unknown = 1 },
    [22] = { Name = 'DeviceUsed', SubDirectory = { TagTable = 'lexiftool.Garmin.DeviceUsed' }, Unknown = 1 }, --4
    [23] = { Name = 'DeviceInfo', SubDirectory = { TagTable = 'lexiftool.Garmin.DeviceInfo' }, Unknown = 1 },
    [26] = { Name = 'Workout', SubDirectory = { TagTable = 'lexiftool.Garmin.Workout' }, Unknown = 1 },
    [27] = { Name = 'WorkoutStep', SubDirectory = { TagTable = 'lexiftool.Garmin.WorkoutStep' }, Unknown = 1 },
    [28] = { Name = 'Schedule', SubDirectory = { TagTable = 'lexiftool.Garmin.Schedule' }, Unknown = 1 },
    [29] = { Name = 'Location', SubDirectory = { TagTable = 'lexiftool.Garmin.Location' }, Unknown = 1 }, --4
    [30] = { Name = 'WeightScale', SubDirectory = { TagTable = 'lexiftool.Garmin.WeightScale' }, Unknown = 1 },
    [31] = { Name = 'Course', SubDirectory = { TagTable = 'lexiftool.Garmin.Course' }, Unknown = 1 },
    [32] = { Name = 'CoursePoint', SubDirectory = { TagTable = 'lexiftool.Garmin.CoursePoint' } },
    [33] = { Name = 'Totals', SubDirectory = { TagTable = 'lexiftool.Garmin.Totals' }, Unknown = 1 },
    [34] = { Name = 'Activity', SubDirectory = { TagTable = 'lexiftool.Garmin.Activity' }, Unknown = 1 },
    [35] = { Name = 'Software', SubDirectory = { TagTable = 'lexiftool.Garmin.Software' }, Unknown = 1 },
    [37] = { Name = 'FileCapabilities', SubDirectory = { TagTable = 'lexiftool.Garmin.FileCapabilities' }, Unknown = 1 },
    [38] = { Name = 'MesgCapabilities', SubDirectory = { TagTable = 'lexiftool.Garmin.MesgCapabilities' }, Unknown = 1 },
    [39] = { Name = 'FieldCapabilities', SubDirectory = { TagTable = 'lexiftool.Garmin.FieldCapabilities' }, Unknown = 1 },
    [49] = { Name = 'FileCreator', SubDirectory = { TagTable = 'lexiftool.Garmin.FileCreator' }, Unknown = 1 },
    [51] = { Name = 'BloodPressure', SubDirectory = { TagTable = 'lexiftool.Garmin.BloodPressure' }, Unknown = 1 },
    [53] = { Name = 'SpeedZone', SubDirectory = { TagTable = 'lexiftool.Garmin.SpeedZone' }, Unknown = 1 },
    [55] = { Name = 'Monitoring', SubDirectory = { TagTable = 'lexiftool.Garmin.Monitoring' }, Unknown = 1 },
    [70] = { Name = 'MapLayer', SubDirectory = { TagTable = 'lexiftool.Garmin.MapLayer' }, Unknown = 1 }, --4
    [71] = { Name = 'Routing', SubDirectory = { TagTable = 'lexiftool.Garmin.Routing' }, Unknown = 1 }, --4
    [72] = { Name = 'TrainingFile', SubDirectory = { TagTable = 'lexiftool.Garmin.TrainingFile' }, Unknown = 1 },
    [78] = { Name = 'HRV', SubDirectory = { TagTable = 'lexiftool.Garmin.HRV' }, Unknown = 1 },
    [79] = { Name = 'UserMetrics', SubDirectory = { TagTable = 'lexiftool.Garmin.UserMetrics' }, Unknown = 1 }, --4
    [80] = { Name = 'AntRx', SubDirectory = { TagTable = 'lexiftool.Garmin.AntRx' }, Unknown = 1 },
    [81] = { Name = 'AntTx', SubDirectory = { TagTable = 'lexiftool.Garmin.AntTx' }, Unknown = 1 },
    [82] = { Name = 'AntChannelID', SubDirectory = { TagTable = 'lexiftool.Garmin.AntChannelID' }, Unknown = 1 },
    [89] = { Name = 'OpenWaterEvent', SubDirectory = { TagTable = 'lexiftool.Garmin.OpenWaterEvent' }, Unknown = 1 }, --4
    [101] = { Name = 'Length', SubDirectory = { TagTable = 'lexiftool.Garmin.Length' }, Unknown = 1 },
    [103] = { Name = 'MonitoringInfo', SubDirectory = { TagTable = 'lexiftool.Garmin.MonitoringInfo' }, Unknown = 1 },
    [104] = { Name = 'DeviceStatus', SubDirectory = { TagTable = 'lexiftool.Garmin.DeviceStatus' }, Unknown = 1 }, --4
    [105] = 'Pad',
    [106] = { Name = 'SlaveDevice', SubDirectory = { TagTable = 'lexiftool.Garmin.SlaveDevice' }, Unknown = 1 },
    [113] = { Name = 'BestEffort', SubDirectory = { TagTable = 'lexiftool.Garmin.BestEffort' }, Unknown = 1 }, --4
    [114] = { Name = 'PersonalRecord', SubDirectory = { TagTable = 'lexiftool.Garmin.PersonalRecord' }, Unknown = 1 }, --4
    [127] = { Name = 'Connectivity', SubDirectory = { TagTable = 'lexiftool.Garmin.Connectivity' }, Unknown = 1 },
    [128] = { Name = 'WeatherConditions', SubDirectory = { TagTable = 'lexiftool.Garmin.WeatherConditions' } },
    [129] = { Name = 'WeatherAlert', SubDirectory = { TagTable = 'lexiftool.Garmin.WeatherAlert' }, Unknown = 1 },
    [131] = { Name = 'CadenceZone', SubDirectory = { TagTable = 'lexiftool.Garmin.CadenceZone' }, Unknown = 1 },
    [132] = { Name = 'HR', SubDirectory = { TagTable = 'lexiftool.Garmin.HR' }, Unknown = 1 },
    [140] = { Name = 'ActivityMetrics', SubDirectory = { TagTable = 'lexiftool.Garmin.ActivityMetrics' }, Unknown = 1 }, --4
    [141] = { Name = 'EPOStatus', SubDirectory = { TagTable = 'lexiftool.Garmin.EPOStatus' }, Unknown = 1 }, --4
    [142] = { Name = 'SegmentLap', SubDirectory = { TagTable = 'lexiftool.Garmin.SegmentLap' } },
    [143] = { Name = 'MultisportSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.MultisportSettings' }, Unknown = 1 }, --4
    [144] = { Name = 'MultisportActivity', SubDirectory = { TagTable = 'lexiftool.Garmin.MultisportActivity' }, Unknown = 1 }, --4
    [145] = { Name = 'MemoGlob', SubDirectory = { TagTable = 'lexiftool.Garmin.MemoGlob' }, Unknown = 1 },
    [147] = { Name = 'SensorSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.SensorSettings' }, Unknown = 1 }, --4
    [148] = { Name = 'SegmentID', SubDirectory = { TagTable = 'lexiftool.Garmin.SegmentID' }, Unknown = 1 },
    [149] = { Name = 'SegmentLeaderboardEntry', SubDirectory = { TagTable = 'lexiftool.Garmin.SegmentLeaderboardEntry' }, Unknown = 1 },
    [150] = { Name = 'SegmentPoint', SubDirectory = { TagTable = 'lexiftool.Garmin.SegmentPoint' } },
    [151] = { Name = 'SegmentFile', SubDirectory = { TagTable = 'lexiftool.Garmin.SegmentFile' }, Unknown = 1 },
    [152] = { Name = 'Metronome', SubDirectory = { TagTable = 'lexiftool.Garmin.Metronome' }, Unknown = 1 }, --4
    [158] = { Name = 'WorkoutSession', SubDirectory = { TagTable = 'lexiftool.Garmin.WorkoutSession' }, Unknown = 1 },
    [159] = { Name = 'WatchfaceSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.WatchfaceSettings' }, Unknown = 1 },
    -- gps_metadata
    [160] = { Name = 'GPS', SubDirectory = { TagTable = 'lexiftool.Garmin.GPS' } },
    [161] = { Name = 'CameraEvent', SubDirectory = { TagTable = 'lexiftool.Garmin.CameraEvent' }, Unknown = 1 },
    -- timestamp_correlation
    [162] = { Name = 'TimeStampCorrelation', SubDirectory = { TagTable = 'lexiftool.Garmin.TimeStampCorrelation' }, Unknown = 1 },
    [164] = { Name = 'GyroscopeData', SubDirectory = { TagTable = 'lexiftool.Garmin.GyroscopeData' }, Unknown = 1 },
    [165] = { Name = 'AccelerometerData', SubDirectory = { TagTable = 'lexiftool.Garmin.AccelerometerData' }, Unknown = 1 },
    [167] = { Name = 'ThreeDSensorCalibration', SubDirectory = { TagTable = 'lexiftool.Garmin.ThreeDSensorCalibration' }, Unknown = 1 },
    [169] = { Name = 'VideoFrame', SubDirectory = { TagTable = 'lexiftool.Garmin.VideoFrame' }, Unknown = 1 },
    [170] = { Name = 'ConnectIQField', SubDirectory = { TagTable = 'lexiftool.Garmin.ConnectIQField' }, Unknown = 1 }, --4
    [173] = { Name = 'Clubs', SubDirectory = { TagTable = 'lexiftool.Garmin.Clubs' }, Unknown = 1 }, --4
    [174] = { Name = 'OBDIIData', SubDirectory = { TagTable = 'lexiftool.Garmin.OBDIIData' }, Unknown = 1 },
    [177] = { Name = 'NMEASentence', SubDirectory = { TagTable = 'lexiftool.Garmin.NMEASentence' }, Unknown = 1 },
    [178] = { Name = 'AviationAttitude', SubDirectory = { TagTable = 'lexiftool.Garmin.AviationAttitude' }, Unknown = 1 },
    [184] = { Name = 'Video', SubDirectory = { TagTable = 'lexiftool.Garmin.Video' }, Unknown = 1 },
    [185] = { Name = 'VideoTitle', SubDirectory = { TagTable = 'lexiftool.Garmin.VideoTitle' }, Unknown = 1 },
    [186] = { Name = 'VideoDescription', SubDirectory = { TagTable = 'lexiftool.Garmin.VideoDescription' }, Unknown = 1 },
    [187] = { Name = 'VideoClip', SubDirectory = { TagTable = 'lexiftool.Garmin.VideoClip' }, Unknown = 1 },
    [188] = { Name = 'OHRSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.OHRSettings' }, Unknown = 1 },
    [189] = { Name = 'WaypointHandling', SubDirectory = { TagTable = 'lexiftool.Garmin.WaypointHandling' }, Unknown = 1 }, --4
    [190] = { Name = 'GolfCourse', SubDirectory = { TagTable = 'lexiftool.Garmin.GolfCourse' }, Unknown = 1 }, --4
    [191] = { Name = 'GolfStats', SubDirectory = { TagTable = 'lexiftool.Garmin.GolfStats' }, Unknown = 1 }, --4
    [192] = { Name = 'Score', SubDirectory = { TagTable = 'lexiftool.Garmin.Score' }, Unknown = 1 }, --4
    [193] = { Name = 'Hole', SubDirectory = { TagTable = 'lexiftool.Garmin.Hole' }, Unknown = 1 }, --4
    [194] = { Name = 'Shot', SubDirectory = { TagTable = 'lexiftool.Garmin.Shot' }, Unknown = 1 }, --4
    [200] = { Name = 'ExdScreenConfiguration', SubDirectory = { TagTable = 'lexiftool.Garmin.ExdScreenConfiguration' }, Unknown = 1 },
    [201] = { Name = 'ExdDataFieldConfiguration', SubDirectory = { TagTable = 'lexiftool.Garmin.ExdDataFieldConfiguration' }, Unknown = 1 },
    [202] = { Name = 'ExdDataConceptConfiguration', SubDirectory = { TagTable = 'lexiftool.Garmin.ExdDataConceptConfiguration' }, Unknown = 1 },
    [206] = { Name = 'FieldDescription', SubDirectory = { TagTable = 'lexiftool.Garmin.FieldDescription' }, Unknown = 1 },
    [207] = { Name = 'DeveloperDataID', SubDirectory = { TagTable = 'lexiftool.Garmin.DeveloperDataID' }, Unknown = 1 },
    [208] = { Name = 'MagnetometerData', SubDirectory = { TagTable = 'lexiftool.Garmin.MagnetometerData' }, Unknown = 1 },
    [209] = { Name = 'BarometerData', SubDirectory = { TagTable = 'lexiftool.Garmin.BarometerData' }, Unknown = 1 },
    [210] = { Name = 'OneDSensorCalibration', SubDirectory = { TagTable = 'lexiftool.Garmin.OneDSensorCalibration' }, Unknown = 1 },
    [211] = { Name = 'MonitoringHRData', SubDirectory = { TagTable = 'lexiftool.Garmin.MonitoringHRData' }, Unknown = 1 },
    [216] = { Name = 'TimeInZone', SubDirectory = { TagTable = 'lexiftool.Garmin.TimeInZone' }, Unknown = 1 },
    [222] = { Name = 'AlarmSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.AlarmSettings' }, Unknown = 1 }, --4
    [225] = { Name = 'Set', SubDirectory = { TagTable = 'lexiftool.Garmin.Set' }, Unknown = 1 },
    [227] = { Name = 'StressLevel', SubDirectory = { TagTable = 'lexiftool.Garmin.StressLevel' }, Unknown = 1 },
    [229] = { Name = 'MaxMetData', SubDirectory = { TagTable = 'lexiftool.Garmin.MaxMetData' }, Unknown = 1 },
    [243] = { Name = 'MusicInfo', SubDirectory = { TagTable = 'lexiftool.Garmin.MusicInfo' }, Unknown = 1 }, --4
    [258] = { Name = 'DiveSettings', SubDirectory = { TagTable = 'lexiftool.Garmin.DiveSettings' }, Unknown = 1 },
    [259] = { Name = 'DiveGas', SubDirectory = { TagTable = 'lexiftool.Garmin.DiveGas' }, Unknown = 1 },
    [262] = { Name = 'DiveAlarm', SubDirectory = { TagTable = 'lexiftool.Garmin.DiveAlarm' }, Unknown = 1 },
    [264] = { Name = 'ExerciseTitle', SubDirectory = { TagTable = 'lexiftool.Garmin.ExerciseTitle' }, Unknown = 1 },
    [268] = { Name = 'DiveSummary', SubDirectory = { TagTable = 'lexiftool.Garmin.DiveSummary' }, Unknown = 1 },
    [269] = { Name = 'SPO2Data', SubDirectory = { TagTable = 'lexiftool.Garmin.SPO2Data' }, Unknown = 1 },
    [273] = { Name = 'SleepDataInfo', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepDataInfo' }, Unknown = 1 }, --4
    [275] = { Name = 'SleepLevel', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepLevel' }, Unknown = 1 },
    [285] = { Name = 'Jump', SubDirectory = { TagTable = 'lexiftool.Garmin.Jump' } },
    [289] = { Name = 'AADAccelFeatures', SubDirectory = { TagTable = 'lexiftool.Garmin.AADAccelFeatures' }, Unknown = 1 },
    [290] = { Name = 'BeatIntervals', SubDirectory = { TagTable = 'lexiftool.Garmin.BeatIntervals' }, Unknown = 1 },
    [297] = { Name = 'RespirationRate', SubDirectory = { TagTable = 'lexiftool.Garmin.RespirationRate' }, Unknown = 1 },
    [302] = { Name = 'HSAAccelerometerData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAAccelerometerData' }, Unknown = 1 },
    [304] = { Name = 'HSAStepData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAStepData' }, Unknown = 1 },
    [305] = { Name = 'HSA_SPO2Data', SubDirectory = { TagTable = 'lexiftool.Garmin.HSA_SPO2Data' }, Unknown = 1 },
    [306] = { Name = 'HSAStressData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAStressData' }, Unknown = 1 },
    [307] = { Name = 'HSARespirationData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSARespirationData' }, Unknown = 1 },
    [308] = { Name = 'HSAHeartRateData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAHeartRateData' }, Unknown = 1 },
    [309] = { Name = 'MtbCx', SubDirectory = { TagTable = 'lexiftool.Garmin.MtbCx' }, Unknown = 1 }, --4
    [310] = { Name = 'Race', SubDirectory = { TagTable = 'lexiftool.Garmin.Race' }, Unknown = 1 }, --4
    [311] = { Name = 'SplitTime', SubDirectory = { TagTable = 'lexiftool.Garmin.SplitTime' }, Unknown = 1 }, --4
    [312] = { Name = 'Split', SubDirectory = { TagTable = 'lexiftool.Garmin.Split' } },
    [313] = { Name = 'SplitSummary', SubDirectory = { TagTable = 'lexiftool.Garmin.SplitSummary' }, Unknown = 1 },
    [314] = { Name = 'HSABodyBatteryData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSABodyBatteryData' }, Unknown = 1 },
    [315] = { Name = 'HSAEvent', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAEvent' }, Unknown = 1 },
    [317] = { Name = 'ClimbPro', SubDirectory = { TagTable = 'lexiftool.Garmin.ClimbPro' } },
    [319] = { Name = 'TankUpdate', SubDirectory = { TagTable = 'lexiftool.Garmin.TankUpdate' }, Unknown = 1 },
    [321] = { Name = 'PowerMode', SubDirectory = { TagTable = 'lexiftool.Garmin.PowerMode' }, Unknown = 1 }, --4
    [323] = { Name = 'TankSummary', SubDirectory = { TagTable = 'lexiftool.Garmin.TankSummary' }, Unknown = 1 },
    [326] = { Name = 'GPSEvent', SubDirectory = { TagTable = 'lexiftool.Garmin.GPSEvent' }, Unknown = 1 }, --4
    [336] = { Name = 'ECGSummary', SubDirectory = { TagTable = 'lexiftool.Garmin.ECGSummary' }, Unknown = 1 }, --4
    [337] = { Name = 'ECGRawSample', SubDirectory = { TagTable = 'lexiftool.Garmin.ECGRawSample' }, Unknown = 1 }, --4
    [338] = { Name = 'ECGSmoothSample', SubDirectory = { TagTable = 'lexiftool.Garmin.ECGSmoothSample' }, Unknown = 1 }, --4
    [346] = { Name = 'SleepAssessment', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepAssessment' }, Unknown = 1 },
    [356] = { Name = 'FunctionalMetrics', SubDirectory = { TagTable = 'lexiftool.Garmin.FunctionalMetrics' }, Unknown = 1 }, --4
    [358] = { Name = 'RaceEvent', SubDirectory = { TagTable = 'lexiftool.Garmin.RaceEvent' }, Unknown = 1 }, --4
    [369] = { Name = 'TrainingReadiness', SubDirectory = { TagTable = 'lexiftool.Garmin.TrainingReadiness' }, Unknown = 1 }, --4
    [370] = { Name = 'HRVStatusSummary', SubDirectory = { TagTable = 'lexiftool.Garmin.HRVStatusSummary' }, Unknown = 1 },
    [371] = { Name = 'HRVValue', SubDirectory = { TagTable = 'lexiftool.Garmin.HRVValue' }, Unknown = 1 },
    [372] = { Name = 'RawBBI', SubDirectory = { TagTable = 'lexiftool.Garmin.RawBBI' }, Unknown = 1 },
    [375] = { Name = 'DeviceAuxBatteryInfo', SubDirectory = { TagTable = 'lexiftool.Garmin.DeviceAuxBatteryInfo' }, Unknown = 1 },
    [376] = { Name = 'HSAGyroscopeData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAGyroscopeData' }, Unknown = 1 },
    [378] = { Name = 'TrainingLoad', SubDirectory = { TagTable = 'lexiftool.Garmin.TrainingLoad' }, Unknown = 1 }, --4
    [379] = { Name = 'SleepSchedule', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepSchedule' }, Unknown = 1 }, --4
    [382] = { Name = 'SleepRestlessMoments', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepRestlessMoments' }, Unknown = 1 }, --4
    [387] = { Name = 'ChronoShotSession', SubDirectory = { TagTable = 'lexiftool.Garmin.ChronoShotSession' }, Unknown = 1 },
    [388] = { Name = 'ChronoShotData', SubDirectory = { TagTable = 'lexiftool.Garmin.ChronoShotData' }, Unknown = 1 },
    [389] = { Name = 'HSAConfigurationData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAConfigurationData' }, Unknown = 1 },
    [393] = { Name = 'DiveApneaAlarm', SubDirectory = { TagTable = 'lexiftool.Garmin.DiveApneaAlarm' }, Unknown = 1 },
    [394] = { Name = 'CPEStatus', SubDirectory = { TagTable = 'lexiftool.Garmin.CPEStatus' }, Unknown = 1 }, --4
    [398] = { Name = 'SkinTempOvernight', SubDirectory = { TagTable = 'lexiftool.Garmin.SkinTempOvernight' }, Unknown = 1 },
    [402] = { Name = 'HillScore', SubDirectory = { TagTable = 'lexiftool.Garmin.HillScore' }, Unknown = 1 }, --4
    [403] = { Name = 'EnduranceScore', SubDirectory = { TagTable = 'lexiftool.Garmin.EnduranceScore' }, Unknown = 1 }, --4
    [409] = { Name = 'HSAWristTemperatureData', SubDirectory = { TagTable = 'lexiftool.Garmin.HSAWristTemperatureData' }, Unknown = 1 },
    [412] = { Name = 'NapEvent', SubDirectory = { TagTable = 'lexiftool.Garmin.NapEvent' }, Unknown = 1 },
    [428] = { Name = 'WorkoutSchedule', SubDirectory = { TagTable = 'lexiftool.Garmin.WorkoutSchedule' }, Unknown = 1 }, --4
    [470] = { Name = 'SleepDisruptionSeverityPeriod', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepDisruptionSeverityPeriod' }, Unknown = 1 },
    [471] = { Name = 'SleepDisruptionOvernightSeverity', SubDirectory = { TagTable = 'lexiftool.Garmin.SleepDisruptionOvernightSeverity' }, Unknown = 1 },
    -- 0xff00 => 'MfgRangeMin',
    -- 0xfffe => 'MfgRangeMax',
}

Garmin.Common = {
    GROUPS = { [0] = 'Garmin', [1] = 'File', [2] = 'Unknown' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    TAG_PREFIX = '',
    NOTES = 'Tags listed here are common to all FIT messages (ie. all tag tables below).',
    [250] = 'PartIndex',
    [253] = timeInfo { Name = 'TimeStamp', Groups = { [2] = 'Time' } },
    [254] = 'MessageIndex',
    -- 255 - invalid
}

-- developer data tags (filled in at runtime)
Garmin.Dev = {
    GROUPS = { [0] = 'Garmin', [1] = 'Developer', [2] = 'Unknown' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
}

------------------------------------------------------------------------
-- This first group of tables are from the offical Garmin documentation (ref 2)
--
Garmin.FileID = {
    GROUPS = { [0] = 'Garmin', [1] = 'FileID', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'FITFileType', PrintConv = file, SeparateTable = 'File' },
    [1] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [2] = 'Product',
    [3] = 'SerialNumber',
    [4] = timeInfo { Name = 'TimeCreated', Groups = { [2] = 'Time' } },
    [5] = 'Number',
    [8] = 'ProductName',
}

Garmin.FileCreator = {
    GROUPS = { [0] = 'Garmin', [1] = 'FileCreator', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'SoftwareVersion',
    [1] = 'HardwareVersion',
}

Garmin.TimeStampCorrelation = {
    GROUPS = { [0] = 'Garmin', [1] = 'TSCorrelation', [2] = 'Time' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'FractionalTimeStamp', ValueConv = d(32768), PrintConv = u('s') },
    [1] = timeInfo { Name = 'SystemTimeStamp', Groups = { [2] = 'Time' } },
    [2] = { Name = 'FractionalSystemTimeStamp', ValueConv = d(32768), PrintConv = u('s') },
    [3] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [4] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [5] = { Name = 'SystemTimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
}

Garmin.Software = {
    GROUPS = { [0] = 'Garmin', [1] = 'Software', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [3] = { Name = 'Version', ValueConv = d(100) },
    [5] = 'PartNumber',
}

Garmin.SlaveDevice = {
    GROUPS = { [0] = 'Garmin', [1] = 'SlaveDevice', [2] = 'Device' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [1] = 'Product',
}

Garmin.Capabilities = {
    GROUPS = { [0] = 'Garmin', [1] = 'Capabilities', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Languages', -- [N]
    [1] = 'Sports', -- [N]
    [21] = { Name = 'WorkoutsSupported', PrintConv = workoutCapabilities, SeparateTable = 'WorkoutCapabilities' },
    [23] = { Name = 'ConnectivitySupported', PrintConv = connectivityCapabilities },
}

Garmin.FileCapabilities = {
    GROUPS = { [0] = 'Garmin', [1] = 'FileCaps', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'FileCapabilitiesType', PrintConv = file, SeparateTable = 'File' },
    [1] = { Name = 'Flags', PrintConv = fileFlags },
    [2] = 'Directory',
    [3] = 'MaxCount',
    [4] = { Name = 'MaxSize', PrintConv = u('bytes') },
}

Garmin.MesgCapabilities = {
    GROUPS = { [0] = 'Garmin', [1] = 'MesgCaps', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'File', PrintConv = file, SeparateTable = 'File' },
    [1] = { Name = 'MesgNum', PrintConv = mesgNum, SeparateTable = 'MesgNum' },
    [2] = { Name = 'CountType', PrintConv = mesgCount },
    [3] = 'Count',
}

Garmin.FieldCapabilities = {
    GROUPS = { [0] = 'Garmin', [1] = 'FieldCaps', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'File', PrintConv = file, SeparateTable = 'File' },
    [1] = { Name = 'MesgNum', PrintConv = mesgNum, SeparateTable = 'MesgNum' },
    [2] = 'FieldNum',
    [3] = 'Count',
}

Garmin.DeviceSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'DeviceSettings', [2] = 'Device' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ActiveTimeZone',
    [1] = 'UtcOffset',
    [2] = 'TimeOffset', -- [N] s
    [4] = 'TimeMode', -- [N]
    [5] = 'TimeZoneOffset', -- [N] / 4 hr
    [8] = 'AlarmsTime', --4 [N] s
    [12] = { Name = 'BacklightMode', PrintConv = backlightMode },
    [28] = 'AlarmsEnabled', --4 [N]
    [36] = 'ActivityTrackerEnabled',
    [39] = timeInfo { Name = 'ClockTime', Groups = { [2] = 'Time' } },
    [40] = 'PagesEnabled', -- [N]
    [46] = 'MoveAlertEnabled',
    [47] = { Name = 'DateMode', PrintConv = dateMode },
    [55] = { Name = 'DisplayOrientation', PrintConv = displayOrientation, SeparateTable = 'DisplayOrientation' },
    [56] = { Name = 'MountingSide', PrintConv = side },
    [57] = 'DefaultPage', -- [N]
    [58] = { Name = 'AutosyncMinSteps', PrintConv = u('steps') },
    [59] = { Name = 'AutosyncMinTime', PrintConv = u('minutes') },
    [80] = 'LactateThresholdAutodetectEnabled',
    [86] = 'BleAutoUploadEnabled',
    [89] = { Name = 'AutoSyncFrequency', PrintConv = autoSyncFrequency },
    [90] = 'AutoActivityDetect',
    [92] = 'AlarmsRepeat', --4 [N]
    [94] = 'NumberOfScreens',
    [95] = { Name = 'SmartNotificationDisplayOrientation', PrintConv = displayOrientation, SeparateTable = 'DisplayOrientation' },
    [134] = { Name = 'TapInterface', PrintConv = switch, SeparateTable = 'Switch' },
    [174] = { Name = 'TapSensitivity', PrintConv = tapSensitivity },
}

Garmin.UserProfile = {
    GROUPS = { [0] = 'Garmin', [1] = 'UserProfile', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'FriendlyName',
    [1] = { Name = 'Gender', PrintConv = gender, SeparateTable = 'Gender' },
    [2] = { Name = 'Age', PrintConv = u('years') },
    [3] = { Name = 'Height', ValueConv = d(100), PrintConv = u('m') },
    [4] = { Name = 'Weight', ValueConv = d(10), PrintConv = u('kg') },
    [5] = { Name = 'Language', PrintConv = language, PrintConvColumns = 2 },
    [6] = { Name = 'ElevSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [7] = { Name = 'WeightSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [8] = { Name = 'RestingHeartRate', PrintConv = u('bpm') },
    [9] = { Name = 'DefaultMaxRunningHeartRate', PrintConv = u('bpm') },
    [10] = { Name = 'DefaultMaxBikingHeartRate', PrintConv = u('bpm') },
    [11] = { Name = 'DefaultMaxHeartRate', PrintConv = u('bpm') },
    [12] = { Name = 'HRSetting', PrintConv = displayHeart },
    [13] = { Name = 'SpeedSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [14] = { Name = 'DistSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [16] = { Name = 'PowerSetting', PrintConv = displayPower },
    [17] = { Name = 'ActivityClass', PrintConv = activityClass },
    [18] = { Name = 'PositionSetting', PrintConv = displayPosition, PrintConvColumns = 2 },
    [21] = { Name = 'TemperatureSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [22] = 'LocalID',
    [23] = 'GlobalID', -- [6]
    [24] = { Name = 'YearOfBirth', ValueConv = function(_self, val) return val + 1900 end }, --4
    [28] = 'WakeTime',
    [29] = 'SleepTime',
    [30] = { Name = 'HeightSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [31] = { Name = 'UserRunningStepLength', ValueConv = d(1000), PrintConv = u('m') },
    [32] = { Name = 'UserWalkingStepLength', ValueConv = d(1000), PrintConv = u('m') },
    [37] = { Name = 'Ltspeed', ValueConv = d(10), PrintConv = u('km/h') }, --4
    [41] = timeInfo { Name = 'TimeLast-LthrUpdate', Groups = { [2] = 'Time' } }, --4
    [47] = { Name = 'DepthSetting', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [49] = 'DiveCount',
    [62] = { Name = 'GenderX', PrintConv = genderX }, --4
}

Garmin.HRMProfile = {
    GROUPS = { [0] = 'Garmin', [1] = 'HRMProfile', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Enabled',
    [1] = 'HRMAntID',
    [2] = 'LogHRV',
    [3] = 'HRMAntIDTransType',
}

Garmin.SDMProfile = {
    GROUPS = { [0] = 'Garmin', [1] = 'SDMProfile', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Enabled',
    [1] = 'SDMAntID',
    [2] = { Name = 'SDMCalFactor', ValueConv = d(10), PrintConv = u('%') },
    [3] = { Name = 'Odometer', ValueConv = d(100), PrintConv = u('m') },
    [4] = 'SpeedSource',
    [5] = 'SDMAntIDTransType',
    [7] = 'OdometerRollover',
}

Garmin.BikeProfile = {
    GROUPS = { [0] = 'Garmin', [1] = 'BikeProfile', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'BikeProfileName',
    [1] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [2] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [3] = { Name = 'Odometer', ValueConv = d(100), PrintConv = u('m') },
    [4] = 'BikeSpdAntID',
    [5] = 'BikeCadAntID',
    [6] = 'BikeSpdcadAntID',
    [7] = 'BikePowerAntID',
    [8] = { Name = 'CustomWheelsize', ValueConv = d(1000), PrintConv = u('m') },
    [9] = { Name = 'AutoWheelsize', ValueConv = d(1000), PrintConv = u('m') },
    [10] = { Name = 'BikeWeight', ValueConv = d(10), PrintConv = u('kg') },
    [11] = { Name = 'PowerCalFactor', ValueConv = d(10), PrintConv = u('%') },
    [12] = 'AutoWheelCal',
    [13] = 'AutoPowerZero',
    [14] = 'ID',
    [15] = 'SpdEnabled',
    [16] = 'CadEnabled',
    [17] = 'SpdcadEnabled',
    [18] = 'PowerEnabled',
    [19] = { Name = 'CrankLength', ValueConv = function(_self, val) return val / 2 + 110 end, PrintConv = u('mm') },
    [20] = 'Enabled',
    [21] = 'BikeSpdAntIDTransType',
    [22] = 'BikeCadAntIDTransType',
    [23] = 'BikeSpdcadAntIDTransType',
    [24] = 'BikePowerAntIDTransType',
    [37] = 'OdometerRollover',
    [38] = 'FrontGearNum',
    [39] = 'FrontGear', -- [N]
    [40] = 'RearGearNum',
    [41] = 'RearGear', -- [N]
    [44] = 'ShimanoDi2Enabled',
}

Garmin.Connectivity = {
    GROUPS = { [0] = 'Garmin', [1] = 'Connectivity', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'BluetoothEnabled',
    [1] = 'BluetoothLeEnabled',
    [2] = 'AntEnabled',
    [3] = 'ConnectivityName',
    [4] = 'LiveTrackingEnabled',
    [5] = 'WeatherConditionsEnabled',
    [6] = 'WeatherAlertsEnabled',
    [7] = 'AutoActivityUploadEnabled',
    [8] = 'CourseDownloadEnabled',
    [9] = 'WorkoutDownloadEnabled',
    [10] = 'GPSEphemerisDownloadEnabled',
    [11] = 'IncidentDetectionEnabled',
    [12] = 'GrouptrackEnabled',
}

Garmin.WatchfaceSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'WatchfaceSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Mode', PrintConv = watchfaceMode },
    [1] = 'Layout',
}

Garmin.OHRSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'OHRSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Enabled', PrintConv = switch, SeparateTable = 'Switch' },
}

Garmin.TimeInZone = {
    GROUPS = { [0] = 'Garmin', [1] = 'TimeInZone', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ReferenceMesg', PrintConv = mesgNum, SeparateTable = 'MesgNum' },
    [1] = 'ReferenceIndex',
    [2] = 'TimeInHRZone', -- [N] / 1000 s
    [3] = 'TimeInSpeedZone', -- [N] / 1000 s
    [4] = 'TimeInCadenceZone', -- [N] / 1000 s
    [5] = 'TimeInPowerZone', -- [N] / 1000 s
    [6] = 'HRZoneHighBoundary', -- [N] bpm
    [7] = 'SpeedZoneHighBoundary', -- [N] / 1000 m/s
    [8] = 'CadenceZoneHighBondary', -- [N] rpm
    [9] = 'PowerZoneHighBoundary', -- [N] watts
    [10] = { Name = 'HRCalcType', PrintConv = hRZoneCalc, SeparateTable = 'HRZoneCalc' },
    [11] = 'MaxHeartRate',
    [12] = 'RestingHeartRate',
    [13] = 'ThresholdHeartRate',
    [14] = { Name = 'PwrCalcType', PrintConv = pwrZoneCalc, SeparateTable = 'PwrZoneCalc' },
    [15] = 'FunctionalThresholdPower',
}

Garmin.ZonesTarget = {
    GROUPS = { [0] = 'Garmin', [1] = 'ZonesTarget', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'MaxHeartRate',
    [2] = 'ThresholdHeartRate',
    [3] = 'FunctionalThresholdPower',
    [5] = { Name = 'HRCalcType', PrintConv = hRZoneCalc, SeparateTable = 'HRZoneCalc' },
    [7] = { Name = 'PwrCalcType', PrintConv = pwrZoneCalc, SeparateTable = 'PwrZoneCalc' },
}

Garmin.Sport = {
    GROUPS = { [0] = 'Garmin', [1] = 'Sport', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [1] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [3] = 'SportName',
    [15] = { Name = 'PopularityRouting', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [17] = { Name = 'NavigationPrompt', PrintConv = navigationPrompt }, --4
    [18] = { Name = 'SharpBendWarnings', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [21] = { Name = 'WorkoutVideos', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [22] = { Name = 'HighTrafficRoadWarnings', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [23] = { Name = 'RoadHazardWarnings', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [24] = { Name = 'UnpavedRoadWarnings', PrintConv = switch, SeparateTable = 'Switch' }, --4
}

Garmin.HRZone = {
    GROUPS = { [0] = 'Garmin', [1] = 'HRZone', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'HighBpm', PrintConv = u('bpm') },
    [2] = 'HRZoneName',
}

Garmin.SpeedZone = {
    GROUPS = { [0] = 'Garmin', [1] = 'SpeedZone', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'HighValue', ValueConv = d(1000), PrintConv = u('m/s') },
    [1] = 'SpeedZoneName',
}

Garmin.CadenceZone = {
    GROUPS = { [0] = 'Garmin', [1] = 'CadenceZone', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'HighValue', PrintConv = u('rpm') },
    [1] = 'CadenceZoneName',
}

Garmin.PowerZone = {
    GROUPS = { [0] = 'Garmin', [1] = 'PowerZone', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'HighValue', PrintConv = u('watts') },
    [2] = 'PowerZoneName',
}

Garmin.MetZone = {
    GROUPS = { [0] = 'Garmin', [1] = 'MetZone', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'HighBpm',
    [2] = { Name = 'Calories', ValueConv = d(10), PrintConv = u('kcal / min') },
    [3] = { Name = 'FatCalories', ValueConv = d(10), PrintConv = u('kcal / min') },
}

Garmin.TrainingSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'TrainingSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [2] = { Name = 'VirtualPartnerPace', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [3] = { Name = 'AutoLapMode', PrintConv = autoLapMode }, --4
    [4] = { Name = 'AutoLapDistance', ValueConv = d(100), PrintConv = u('m') }, --4
    [7] = { Name = 'AutoPause', PrintConv = autoPauseSetting }, --4
    [8] = { Name = 'AutoPauseThreshold', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [12] = { Name = 'PowerAveraging', PrintConv = powerAveraging }, --4
    [15] = { Name = 'AutoScroll', PrintConv = autoScrollMode }, --4
    [18] = { Name = 'TimerStartPrompt', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [22] = { Name = 'PoolLength', ValueConv = d(100), PrintConv = u('m') }, --4
    [25] = { Name = 'AutoSleep', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [27] = { Name = 'Satellites', PrintConv = satellites }, --4
    [31] = { Name = 'TargetDistance', ValueConv = d(100), PrintConv = u('m') },
    [32] = { Name = 'TargetSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [33] = { Name = 'TargetTime', PrintConv = u('s') },
    [35] = { Name = 'ThreeDSpeed', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [36] = { Name = 'ThreeDDistance', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [37] = { Name = 'AutoClimb', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [40] = { Name = 'AutoClimbInvertColors', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [41] = { Name = 'AutoClimbVerticalSpeed', ValueConv = d(27.778), PrintConv = u('m/h') }, --4
    [42] = { Name = 'AutoClimbModeSwitch', PrintConv = u('s') }, --4
    [46] = { Name = 'LapKey', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [50] = { Name = 'WorkoutTargetAlerts', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [51] = { Name = 'TimerStartAuto', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [52] = { Name = 'TimerStartSpeed', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [53] = { Name = 'SegmentAlerts', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [57] = { Name = 'CountdownStart', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [63] = { Name = 'ClimbPro', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [67] = { Name = 'TrackConsumption', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [69] = 'BottleSize', --4
    [70] = { Name = 'Volume', PrintConv = volume }, --4
    [80] = { Name = 'MinimumRideDuration', PrintConv = u('s') }, --4
    [86] = 'LaneNumber', --4
    [87] = { Name = 'BroadcastHeartRate', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [93] = { Name = 'SelfEvaluation', PrintConv = selfEvaluationStatus }, --4
    [102] = { Name = 'SpeedPro', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [103] = { Name = 'Touch', PrintConv = touchStatus }, --4
    [106] = { Name = 'RecordTemperature', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [109] = { Name = 'RunningPowerMode', PrintConv = runningPowerMode }, --4
    [110] = { Name = 'AccountForWind', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [111] = { Name = 'ClimbProMode', PrintConv = climbProMode }, --4
    [117] = { Name = 'ClimbDetection', PrintConv = climbDetection }, --4
    [119] = { Name = 'ClimbProTerrain', PrintConv = climbProTerrain }, --4
    [153] = { Name = 'PreciseTargetSpeed', ValueConv = d(1000000), PrintConv = u('m/s') },
    [1001] = { Name = 'GPS', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [1002] = { Name = 'Glonass', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [1003] = { Name = 'Galileo', PrintConv = switch, SeparateTable = 'Switch' }, --4
    [1004] = { Name = 'Beidou', PrintConv = switch, SeparateTable = 'Switch' }, --4
}

Garmin.DiveSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'DiveSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'DiveSettingsName',
    [1] = { Name = 'Model', PrintConv = tissueModelType },
    [2] = { Name = 'GfLow', PrintConv = u('%') },
    [3] = { Name = 'GfHigh', PrintConv = u('%') },
    [4] = { Name = 'WaterType', PrintConv = waterType },
    [5] = { Name = 'WaterDensity', PrintConv = u('kg/m^3') },
    [6] = { Name = 'PO2Warn', ValueConv = d(100), PrintConv = u('%') },
    [7] = { Name = 'PO2Critical', ValueConv = d(100), PrintConv = u('%') },
    [8] = { Name = 'PO2Deco', ValueConv = d(100), PrintConv = u('%') },
    [9] = 'SafetyStopEnabled',
    [10] = 'BottomDepth',
    [11] = 'BottomTime',
    [12] = 'ApneaCountdownEnabled',
    [13] = 'ApneaCountdownTime',
    [14] = { Name = 'BacklightMode', PrintConv = diveBacklightMode },
    [15] = 'BacklightBrightness',
    [16] = { Name = 'BacklightTimeout', PrintConv = backlightTimeout },
    [17] = { Name = 'RepeatDiveInterval', ValueConv = d(1), PrintConv = u('s') },
    [18] = { Name = 'SafetyStopTime', ValueConv = d(1), PrintConv = u('s') },
    [19] = { Name = 'HeartRateSourceType', PrintConv = sourceType, SeparateTable = 'SourceType' },
    [20] = 'HeartRateSource',
    [21] = 'TravelGas',
    [22] = { Name = 'CCRLowSetpointSwitchMode', PrintConv = cCRSetpointSwitchMode, SeparateTable = 'CCRSetpointSwitchMode' },
    [23] = { Name = 'CCRLowSetpoint', ValueConv = d(100), PrintConv = u('%') },
    [24] = { Name = 'CCRLowSetpointDepth', ValueConv = d(1000), PrintConv = u('m') },
    [25] = { Name = 'CCRHighSetpointSwitchMode', PrintConv = cCRSetpointSwitchMode, SeparateTable = 'CCRSetpointSwitchMode' },
    [26] = { Name = 'CCRHighSetpoint', ValueConv = d(100), PrintConv = u('%') },
    [27] = { Name = 'CCRHighSetpointDepth', ValueConv = d(1000), PrintConv = u('m') },
    [29] = { Name = 'GasConsumptionDisplay', PrintConv = gasConsumptionRateType },
    [30] = 'UpKeyEnabled',
    [35] = { Name = 'DiveSounds', PrintConv = tone, SeparateTable = 'Tone' },
    [36] = { Name = 'LastStopMultiple', ValueConv = d(10) },
    [37] = { Name = 'NoFlyTimeMode', PrintConv = noFlyTimeMode },
}

Garmin.DiveAlarm = {
    GROUPS = { [0] = 'Garmin', [1] = 'DiveAlarm', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Depth', ValueConv = d(1000), PrintConv = u('m') },
    [1] = { Name = 'Time', ValueConv = d(1), PrintConv = u('s') },
    [2] = 'Enabled',
    [3] = { Name = 'AlarmType', PrintConv = diveAlarmType, SeparateTable = 'DiveAlarmType' },
    [4] = { Name = 'Sound', PrintConv = tone, SeparateTable = 'Tone' },
    [5] = 'DiveTypes', -- [N]
    [6] = 'ID',
    [7] = 'PopupEnabled',
    [8] = 'TriggerOnDescent',
    [9] = 'TriggerOnAscent',
    [10] = 'Repeating',
    [11] = { Name = 'Speed', ValueConv = d(1000), PrintConv = u('mps') },
}

Garmin.DiveApneaAlarm = {
    GROUPS = { [0] = 'Garmin', [1] = 'DiveApneaAlarm', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Depth', ValueConv = d(1000), PrintConv = u('m') },
    [1] = { Name = 'Time', ValueConv = d(1), PrintConv = u('s') },
    [2] = 'Enabled',
    [3] = { Name = 'AlarmType', PrintConv = diveAlarmType, SeparateTable = 'DiveAlarmType' },
    [4] = { Name = 'Sound', PrintConv = tone, SeparateTable = 'Tone' },
    [5] = 'DiveTypes', -- [N]
    [6] = 'ID',
    [7] = 'PopupEnabled',
    [8] = 'TriggerOnDescent',
    [9] = 'TriggerOnAscent',
    [10] = 'Repeating',
    [11] = { Name = 'Speed', ValueConv = d(1000), PrintConv = u('mps') },
}

Garmin.DiveGas = {
    GROUPS = { [0] = 'Garmin', [1] = 'DiveGas', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'HeliumContent', PrintConv = u('%') },
    [1] = { Name = 'OxygenContent', PrintConv = u('%') },
    [2] = { Name = 'Status', PrintConv = diveGasStatus },
    [3] = { Name = 'Mode', PrintConv = diveGasMode },
}

Garmin.Goal = {
    GROUPS = { [0] = 'Garmin', [1] = 'Goal', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [1] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [2] = timeInfo { Name = 'StartDate', Groups = { [2] = 'Time' } },
    [3] = timeInfo { Name = 'EndDate', Groups = { [2] = 'Time' } },
    [4] = { Name = 'GoalType', PrintConv = goalEnum },
    [5] = 'Value',
    [6] = 'Repeat',
    [7] = 'TargetValue',
    [8] = { Name = 'Recurrence', PrintConv = goalRecurrence },
    [9] = 'RecurrenceValue',
    [10] = 'Enabled',
    [11] = { Name = 'Source', PrintConv = goalSource },
}

Garmin.Activity = {
    GROUPS = { [0] = 'Garmin', [1] = 'Activity', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [1] = 'NumSessions',
    [2] = { Name = 'ActivityType', PrintConv = activityEnum },
    [3] = { Name = 'Event', PrintConv = eventEnum, SeparateTable = 'EventEnum' },
    [4] = { Name = 'EventType', PrintConv = eventType, SeparateTable = 'EventType' },
    [5] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [6] = 'EventGroup',
}

Garmin.Session = {
    GROUPS = { [0] = 'Garmin', [1] = 'Session', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Event', PrintConv = eventEnum, SeparateTable = 'EventEnum' },
    [1] = { Name = 'EventType', PrintConv = eventType, SeparateTable = 'EventType' },
    [2] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'start_time', IsTimeStamp = 1 },
    [3] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'start_position_lat' },
    [4] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'start_position_long' },
    [5] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [6] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [7] = { Name = 'TotalElapsedTime', ValueConv = d(1000), PrintConv = u('s') },
    [8] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [9] = { Name = 'TotalDistance', ValueConv = d(100), PrintConv = u('m') },
    [10] = { Name = 'TotalCycles', PrintConv = u('cycles') },
    [11] = { Name = 'TotalCalories', PrintConv = u('kcal') },
    [13] = { Name = 'TotalFatCalories', PrintConv = u('kcal') },
    [14] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [15] = { Name = 'MaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [16] = { Name = 'AvgHeartRate', PrintConv = u('bpm') },
    [17] = { Name = 'MaxHeartRate', PrintConv = u('bpm') },
    [18] = { Name = 'AvgCadence', PrintConv = u('rpm') },
    [19] = { Name = 'MaxCadence', PrintConv = u('rpm') },
    [20] = { Name = 'AvgPower', PrintConv = u('watts') },
    [21] = { Name = 'MaxPower', PrintConv = u('watts') },
    [22] = { Name = 'TotalAscent', PrintConv = u('m') },
    [23] = { Name = 'TotalDescent', PrintConv = u('m') },
    [24] = { Name = 'TotalTrainingEffect', ValueConv = d(10) },
    [25] = 'FirstLapIndex',
    [26] = 'NumLaps',
    [27] = 'EventGroup',
    [28] = { Name = 'Trigger', PrintConv = sessionTrigger },
    [29] = latInfo { Name = 'NECLatitude', Groups = { [2] = 'Location' } },
    [30] = lonInfo { Name = 'NECLongitude', Groups = { [2] = 'Location' } },
    [31] = latInfo { Name = 'SWCLatitude', Groups = { [2] = 'Location' } },
    [32] = lonInfo { Name = 'SWCLongitude', Groups = { [2] = 'Location' } },
    [33] = { Name = 'NumLengths', PrintConv = u('lengths') },
    [34] = { Name = 'NormalizedPower', PrintConv = u('watts') },
    [35] = { Name = 'TrainingStressScore', ValueConv = d(10), PrintConv = u('tss') },
    [36] = { Name = 'IntensityFactor', ValueConv = d(1000), PrintConv = u('if') },
    [37] = 'LeftRightBalance',
    [38] = latInfo { Name = 'GPSDestLatitude', Groups = { [2] = 'Location' }, Notes = 'end_position_lat' },
    [39] = lonInfo { Name = 'GPSDestLongitude', Groups = { [2] = 'Location' }, Notes = 'end_position_long' },
    [41] = { Name = 'AvgStrokeCount', ValueConv = d(10), PrintConv = u('strokes/lap') },
    [42] = { Name = 'AvgStrokeDistance', ValueConv = d(100), PrintConv = u('m') },
    [43] = { Name = 'SwimStroke', PrintConv = swimStroke, SeparateTable = 'SwimStroke' },
    [44] = { Name = 'PoolLength', ValueConv = d(100), PrintConv = u('m') },
    [45] = { Name = 'ThresholdPower', PrintConv = u('watts') },
    [46] = { Name = 'PoolLengthUnit', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [47] = { Name = 'NumActiveLengths', PrintConv = u('lengths') },
    [48] = { Name = 'TotalWork', PrintConv = u('J') },
    [49] = { Name = 'AvgAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [50] = { Name = 'MaxAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [51] = { Name = 'GPSAccuracy', PrintConv = u('m') },
    [52] = { Name = 'AvgGrade', ValueConv = d(100), PrintConv = u('%') },
    [53] = { Name = 'AvgPosGrade', ValueConv = d(100), PrintConv = u('%') },
    [54] = { Name = 'AvgNegGrade', ValueConv = d(100), PrintConv = u('%') },
    [55] = { Name = 'MaxPosGrade', ValueConv = d(100), PrintConv = u('%') },
    [56] = { Name = 'MaxNegGrade', ValueConv = d(100), PrintConv = u('%') },
    [57] = { Name = 'AvgTemperature', PrintConv = u('C') },
    [58] = { Name = 'MaxTemperature', PrintConv = u('C') },
    [59] = { Name = 'TotalMovingTime', ValueConv = d(1000), PrintConv = u('s') },
    [60] = { Name = 'AvgPosVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [61] = { Name = 'AvgNegVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [62] = { Name = 'MaxPosVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [63] = { Name = 'MaxNegVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [64] = { Name = 'MinHeartRate', PrintConv = u('bpm') },
    [65] = 'TimeInHRZone', -- [N] / 1000 s
    [66] = 'TimeInSpeedZone', -- [N] / 1000 s
    [67] = 'TimeInCadenceZone', -- [N] / 1000 s
    [68] = 'TimeInPowerZone', -- [N] / 1000 s
    [69] = { Name = 'AvgLapTime', ValueConv = d(1000), PrintConv = u('s') },
    [70] = 'BestLapIndex',
    [71] = { Name = 'MinAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [78] = { Name = 'WorkTime', ValueConv = d(1000), PrintConv = u('s') }, --4
    [79] = { Name = 'AvgSwimCadence', ValueConv = d(10), PrintConv = u('strokes/length') }, --4
    [80] = 'AvgSwolf', --4
    [82] = 'PlayerScore',
    [83] = 'OpponentScore',
    [84] = 'OpponentName',
    [85] = 'StrokeCount', -- [N] counts
    [86] = 'ZoneCount', -- [N] counts
    [87] = { Name = 'MaxBallSpeed', ValueConv = d(100), PrintConv = u('m/s') },
    [88] = { Name = 'AvgBallSpeed', ValueConv = d(100), PrintConv = u('m/s') },
    [89] = { Name = 'AvgVerticalOscillation', ValueConv = d(10), PrintConv = u('mm') },
    [90] = { Name = 'AvgStanceTimePercent', ValueConv = d(100), PrintConv = u('%') },
    [91] = { Name = 'AvgStanceTime', ValueConv = d(10), PrintConv = u('ms') },
    [92] = { Name = 'AvgFractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [93] = { Name = 'MaxFractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [94] = { Name = 'TotalFractionalCycles', ValueConv = d(128), PrintConv = u('cycles') },
    [95] = 'AvgTotalHemoglobinConc', -- [N] / 100 g/dL
    [96] = 'MinTotalHemoglobinConc', -- [N] / 100 g/dL
    [97] = 'MaxTotalHemoglobinConc', -- [N] / 100 g/dL
    [98] = 'AvgSaturatedHemoglobinPercent', -- [N] / 10 %
    [99] = 'MinSaturatedHemoglobinPercent', -- [N] / 10 %
    [100] = 'MaxSaturatedHemoglobinPercent', -- [N] / 10 %
    [101] = { Name = 'AvgLeftTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [102] = { Name = 'AvgRightTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [103] = { Name = 'AvgLeftPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [104] = { Name = 'AvgRightPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [105] = { Name = 'AvgCombinedPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [110] = 'SportProfileName',
    [111] = 'SportIndex',
    [112] = { Name = 'TimeStanding', ValueConv = d(1000), PrintConv = u('s') },
    [113] = 'StandCount',
    [114] = { Name = 'AvgLeftPco', PrintConv = u('mm') },
    [115] = { Name = 'AvgRightPco', PrintConv = u('mm') },
    [116] = 'AvgLeftPowerPhase', -- [N] / 0.7111111 degrees
    [117] = 'AvgLeftPowerPhasePeak', -- [N] / 0.7111111 degrees
    [118] = 'AvgRightPowerPhase', -- [N] / 0.7111111 degrees
    [119] = 'AvgRightPowerPhasePeak', -- [N] / 0.7111111 degrees
    [120] = 'AvgPowerPosition', -- [N] watts
    [121] = 'MaxPowerPosition', -- [N] watts
    [122] = 'AvgCadencePosition', -- [N] rpm
    [123] = 'MaxCadencePosition', -- [N] rpm
    [124] = { Name = 'EnhancedAvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [125] = { Name = 'EnhancedMaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [126] = { Name = 'EnhancedAvgAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [127] = { Name = 'EnhancedMinAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [128] = { Name = 'EnhancedMaxAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [129] = { Name = 'AvgLevMotorPower', PrintConv = u('watts') },
    [130] = { Name = 'MaxLevMotorPower', PrintConv = u('watts') },
    [131] = { Name = 'LevBatteryConsumption', ValueConv = d(2), PrintConv = u('%') },
    [132] = { Name = 'AvgVerticalRatio', ValueConv = d(100), PrintConv = u('%') },
    [133] = { Name = 'AvgStanceTimeBalance', ValueConv = d(100), PrintConv = u('%') },
    [134] = { Name = 'AvgStepLength', ValueConv = d(10), PrintConv = u('mm') },
    [137] = { Name = 'TotalAnaerobicTrainingEffect', ValueConv = d(10) },
    [139] = { Name = 'AvgVam', ValueConv = d(1000), PrintConv = u('m/s') },
    [140] = { Name = 'AvgDepth', ValueConv = d(1000), PrintConv = u('m') },
    [141] = { Name = 'MaxDepth', ValueConv = d(1000), PrintConv = u('m') },
    [142] = { Name = 'SurfaceInterval', ValueConv = d(1), PrintConv = u('s') },
    [143] = { Name = 'StartCns', ValueConv = d(1), PrintConv = u('%') },
    [144] = { Name = 'EndCns', ValueConv = d(1), PrintConv = u('%') },
    [145] = { Name = 'StartN2', ValueConv = d(1), PrintConv = u('%') },
    [146] = { Name = 'EndN2', ValueConv = d(1), PrintConv = u('%') },
    [147] = 'AvgRespirationRate',
    [148] = 'MaxRespirationRate',
    [149] = 'MinRespirationRate',
    [150] = { Name = 'MinTemperature', PrintConv = u('C') },
    [151] = 'TotalSets', --4
    [152] = { Name = 'Volume', ValueConv = d(100), PrintConv = u('kg') }, --4
    [155] = { Name = 'O2Toxicity', PrintConv = u('OTUs') },
    [156] = 'DiveNumber',
    [168] = { Name = 'TrainingLoadPeak', ValueConv = d(65536) },
    [169] = { Name = 'EnhancedAvgRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [170] = { Name = 'EnhancedMaxRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [177] = 'CaloriesConsumed', --4
    [178] = { Name = 'EstSweatLoss', PrintConv = u('ml') }, --4
    [179] = { Name = 'FluidConsumed', PrintConv = u('ml') }, --4
    [180] = { Name = 'EnhancedMinRespirationRate', ValueConv = d(100) },
    [181] = { Name = 'TotalGrit', PrintConv = u('kGrit') },
    [182] = { Name = 'TotalFlow', PrintConv = u('Flow') },
    [183] = 'JumpCount',
    [185] = { Name = 'ExecutionScore', PrintConv = u('%') }, --4
    [186] = { Name = 'AvgGrit', PrintConv = u('kGrit') },
    [187] = { Name = 'AvgFlow', PrintConv = u('Flow') },
    [188] = { Name = 'PrimaryBenefit', PrintConv = benefit, SeparateTable = 'Benefit' }, --4
    [192] = 'WorkoutFeel',
    [193] = 'WorkoutRpe',
    [194] = { Name = 'AvgSPO2', PrintConv = u('%') },
    [195] = { Name = 'AvgStress', PrintConv = u('%') },
    [196] = { Name = 'MetabolicCalories', PrintConv = u('kcal') },
    [197] = { Name = 'SDRRHRV', PrintConv = u('mS') },
    [198] = { Name = 'RMSSD_HRV', PrintConv = u('mS') },
    [199] = { Name = 'TotalFractionalAscent', ValueConv = d(100), PrintConv = u('m') },
    [200] = { Name = 'TotalFractionalDescent', ValueConv = d(100), PrintConv = u('m') },
    [202] = 'RecoveryHeartRate', --4
    [205] = 'BeginningPotential', --4
    [206] = 'EndingPotential', --4
    [207] = 'MinStamina', --4
    [208] = { Name = 'AvgCoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [209] = { Name = 'MinCoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [210] = { Name = 'MaxCoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [211] = { Name = 'GradeAdjustedSpeed', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [212] = { Name = 'WindData', PrintConv = windDataStatus }, --4
    [215] = 'BeginningBodyBattery', --4
    [216] = 'EndingBodyBattery', --4
    [220] = { Name = 'PackWeight', ValueConv = d(10), PrintConv = u('kg') }, --4
    [222] = { Name = 'StepSpeedLossDistance', ValueConv = d(100), PrintConv = u('cm/s') }, --4
    [223] = { Name = 'StepSpeedLossPercent', ValueConv = d(100), PrintConv = u('%') }, --4
    [224] = { Name = 'AvgForce', ValueConv = d(1000), PrintConv = u('N') }, --4
    [225] = { Name = 'MaxForce', ValueConv = d(1000), PrintConv = u('N') }, --4
    [226] = { Name = 'NormalizedForce', ValueConv = d(1000), PrintConv = u('N') }, --4
}

Garmin.Lap = {
    GROUPS = { [0] = 'Garmin', [1] = 'Lap', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Event', PrintConv = eventEnum, SeparateTable = 'EventEnum' },
    [1] = { Name = 'EventType', PrintConv = eventType, SeparateTable = 'EventType' },
    [2] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'start_time', IsTimeStamp = 1 },
    [3] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'start_position_lat' },
    [4] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'start_position_long' },
    [5] = latInfo { Name = 'GPSDestLatitude', Groups = { [2] = 'Location' }, Notes = 'end_position_lat' },
    [6] = lonInfo { Name = 'GPSDestLongitude', Groups = { [2] = 'Location' }, Notes = 'end_position_long' },
    [7] = { Name = 'TotalElapsedTime', ValueConv = d(1000), PrintConv = u('s') },
    [8] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [9] = { Name = 'TotalDistance', ValueConv = d(100), PrintConv = u('m') },
    [10] = { Name = 'TotalCycles', PrintConv = u('cycles') },
    [11] = { Name = 'TotalCalories', PrintConv = u('kcal') },
    [12] = { Name = 'TotalFatCalories', PrintConv = u('kcal') },
    [13] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [14] = { Name = 'MaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [15] = { Name = 'AvgHeartRate', PrintConv = u('bpm') },
    [16] = { Name = 'MaxHeartRate', PrintConv = u('bpm') },
    [17] = { Name = 'AvgCadence', PrintConv = u('rpm') },
    [18] = { Name = 'MaxCadence', PrintConv = u('rpm') },
    [19] = { Name = 'AvgPower', PrintConv = u('watts') },
    [20] = { Name = 'MaxPower', PrintConv = u('watts') },
    [21] = { Name = 'TotalAscent', PrintConv = u('m') },
    [22] = { Name = 'TotalDescent', PrintConv = u('m') },
    [23] = { Name = 'Intensity', PrintConv = intensity, SeparateTable = 'Intensity' },
    [24] = { Name = 'LapTrigger', PrintConv = lapTrigger },
    [25] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [26] = 'EventGroup',
    [27] = latInfo { Name = 'NECLatitude', Groups = { [2] = 'Location' } }, --4
    [28] = lonInfo { Name = 'NECLongitude', Groups = { [2] = 'Location' } }, --4
    [29] = latInfo { Name = 'SWCLatitude', Groups = { [2] = 'Location' } }, --4
    [30] = lonInfo { Name = 'SWCLongitude', Groups = { [2] = 'Location' } }, --4
    [32] = { Name = 'NumLengths', PrintConv = u('lengths') },
    [33] = { Name = 'NormalizedPower', PrintConv = u('watts') },
    [34] = 'LeftRightBalance',
    [35] = 'FirstLengthIndex',
    [37] = { Name = 'AvgStrokeDistance', ValueConv = d(100), PrintConv = u('m') },
    [38] = { Name = 'SwimStroke', PrintConv = swimStroke, SeparateTable = 'SwimStroke' },
    [39] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [40] = { Name = 'NumActiveLengths', PrintConv = u('lengths') },
    [41] = { Name = 'TotalWork', PrintConv = u('J') },
    [42] = { Name = 'AvgAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [43] = { Name = 'MaxAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [44] = { Name = 'GPSAccuracy', PrintConv = u('m') },
    [45] = { Name = 'AvgGrade', ValueConv = d(100), PrintConv = u('%') },
    [46] = { Name = 'AvgPosGrade', ValueConv = d(100), PrintConv = u('%') },
    [47] = { Name = 'AvgNegGrade', ValueConv = d(100), PrintConv = u('%') },
    [48] = { Name = 'MaxPosGrade', ValueConv = d(100), PrintConv = u('%') },
    [49] = { Name = 'MaxNegGrade', ValueConv = d(100), PrintConv = u('%') },
    [50] = { Name = 'AvgTemperature', PrintConv = u('C') },
    [51] = { Name = 'MaxTemperature', PrintConv = u('C') },
    [52] = { Name = 'TotalMovingTime', ValueConv = d(1000), PrintConv = u('s') },
    [53] = { Name = 'AvgPosVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [54] = { Name = 'AvgNegVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [55] = { Name = 'MaxPosVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [56] = { Name = 'MaxNegVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [57] = 'TimeInHRZone', -- [N] / 1000 s
    [58] = 'TimeInSpeedZone', -- [N] / 1000 s
    [59] = 'TimeInCadenceZone', -- [N] / 1000 s
    [60] = 'TimeInPowerZone', -- [N] / 1000 s
    [61] = 'RepetitionNum',
    [62] = { Name = 'MinAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [63] = { Name = 'MinHeartRate', PrintConv = u('bpm') },
    [71] = 'WktStepIndex',
    [73] = 'AvgSwolf', --4
    [74] = 'OpponentScore',
    [75] = 'StrokeCount', -- [N] counts
    [76] = 'ZoneCount', -- [N] counts
    [77] = { Name = 'AvgVerticalOscillation', ValueConv = d(10), PrintConv = u('mm') },
    [78] = { Name = 'AvgStanceTimePercent', ValueConv = d(100), PrintConv = u('%') },
    [79] = { Name = 'AvgStanceTime', ValueConv = d(10), PrintConv = u('ms') },
    [80] = { Name = 'AvgFractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [81] = { Name = 'MaxFractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [82] = { Name = 'TotalFractionalCycles', ValueConv = d(128), PrintConv = u('cycles') },
    [83] = 'PlayerScore',
    [84] = 'AvgTotalHemoglobinConc', -- [N] / 100 g/dL
    [85] = 'MinTotalHemoglobinConc', -- [N] / 100 g/dL
    [86] = 'MaxTotalHemoglobinConc', -- [N] / 100 g/dL
    [87] = 'AvgSaturatedHemoglobinPercent', -- [N] / 10 %
    [88] = 'MinSaturatedHemoglobinPercent', -- [N] / 10 %
    [89] = 'MaxSaturatedHemoglobinPercent', -- [N] / 10 %
    [91] = { Name = 'AvgLeftTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [92] = { Name = 'AvgRightTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [93] = { Name = 'AvgLeftPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [94] = { Name = 'AvgRightPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [95] = { Name = 'AvgCombinedPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [98] = { Name = 'TimeStanding', ValueConv = d(1000), PrintConv = u('s') },
    [99] = 'StandCount',
    [100] = { Name = 'AvgLeftPco', PrintConv = u('mm') },
    [101] = { Name = 'AvgRightPco', PrintConv = u('mm') },
    [102] = 'AvgLeftPowerPhase', -- [N] / 0.7111111 degrees
    [103] = 'AvgLeftPowerPhasePeak', -- [N] / 0.7111111 degrees
    [104] = 'AvgRightPowerPhase', -- [N] / 0.7111111 degrees
    [105] = 'AvgRightPowerPhasePeak', -- [N] / 0.7111111 degrees
    [106] = 'AvgPowerPosition', -- [N] watts
    [107] = 'MaxPowerPosition', -- [N] watts
    [108] = 'AvgCadencePosition', -- [N] rpm
    [109] = 'MaxCadencePosition', -- [N] rpm
    [110] = { Name = 'EnhancedAvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [111] = { Name = 'EnhancedMaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [112] = { Name = 'EnhancedAvgAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [113] = { Name = 'EnhancedMinAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [114] = { Name = 'EnhancedMaxAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [115] = { Name = 'AvgLevMotorPower', PrintConv = u('watts') },
    [116] = { Name = 'MaxLevMotorPower', PrintConv = u('watts') },
    [117] = { Name = 'LevBatteryConsumption', ValueConv = d(2), PrintConv = u('%') },
    [118] = { Name = 'AvgVerticalRatio', ValueConv = d(100), PrintConv = u('%') },
    [119] = { Name = 'AvgStanceTimeBalance', ValueConv = d(100), PrintConv = u('%') },
    [120] = { Name = 'AvgStepLength', ValueConv = d(10), PrintConv = u('mm') },
    [121] = { Name = 'AvgVam', ValueConv = d(1000), PrintConv = u('m/s') },
    [122] = { Name = 'AvgDepth', ValueConv = d(1000), PrintConv = u('m') },
    [123] = { Name = 'MaxDepth', ValueConv = d(1000), PrintConv = u('m') },
    [124] = { Name = 'MinTemperature', PrintConv = u('C') },
    [136] = { Name = 'EnhancedAvgRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [137] = { Name = 'EnhancedMaxRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [145] = 'EstSweatLoss', --4
    [147] = 'AvgRespirationRate',
    [148] = 'MaxRespirationRate',
    [149] = { Name = 'TotalGrit', PrintConv = u('kGrit') },
    [150] = { Name = 'TotalFlow', PrintConv = u('Flow') },
    [151] = 'JumpCount',
    [152] = { Name = 'ExecutionScore', PrintConv = u('%') }, --4
    [153] = { Name = 'AvgGrit', PrintConv = u('kGrit') },
    [154] = { Name = 'AvgFlow', PrintConv = u('Flow') },
    [155] = { Name = 'RestingCalories', PrintConv = u('kcal') }, --4
    [156] = { Name = 'TotalFractionalAscent', ValueConv = d(100), PrintConv = u('m') },
    [157] = { Name = 'TotalFractionalDescent', ValueConv = d(100), PrintConv = u('m') },
    [158] = { Name = 'AvgCoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [159] = { Name = 'MinCoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [160] = { Name = 'MaxCoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [161] = { Name = 'GradeAdjustedSpeed', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [163] = { Name = 'Unpaved', PrintConv = u('%') }, --4
    [164] = { Name = 'StepSpeedLossDistance', ValueConv = d(100), PrintConv = u('cm/s') }, --4
    [165] = { Name = 'StepSpeedLossPercentage', ValueConv = d(100), PrintConv = u('%') }, --4
    [166] = { Name = 'AvgForce', ValueConv = d(1000), PrintConv = u('N') }, --4
    [167] = { Name = 'MaxForce', ValueConv = d(1000), PrintConv = u('N') }, --4
    [168] = { Name = 'NormalizedForce', ValueConv = d(1000), PrintConv = u('N') }, --4
}

Garmin.Length = {
    GROUPS = { [0] = 'Garmin', [1] = 'Length', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Event', PrintConv = eventEnum, SeparateTable = 'EventEnum' },
    [1] = { Name = 'EventType', PrintConv = eventType, SeparateTable = 'EventType' },
    [2] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [3] = { Name = 'TotalElapsedTime', ValueConv = d(1000), PrintConv = u('s') },
    [4] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [5] = { Name = 'TotalStrokes', PrintConv = u('strokes') },
    [6] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [7] = { Name = 'SwimStroke', PrintConv = swimStroke, SeparateTable = 'SwimStroke' },
    [9] = { Name = 'AvgSwimmingCadence', PrintConv = u('strokes/min') },
    [10] = 'EventGroup',
    [11] = { Name = 'TotalCalories', PrintConv = u('kcal') },
    [12] = { Name = 'LengthType', PrintConv = lengthType },
    [18] = 'PlayerScore',
    [19] = 'OpponentScore',
    [20] = 'StrokeCount', -- [N] counts
    [21] = 'ZoneCount', -- [N] counts
    [22] = { Name = 'EnhancedAvgRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [23] = { Name = 'EnhancedMaxRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [24] = 'AvgRespirationRate',
    [25] = 'MaxRespirationRate',
}

Garmin.Record = {
    GROUPS = { [0] = 'Garmin', [1] = 'Record', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'position_lat' },
    [1] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'position_long' },
    [2] = altInfo { Name = 'GPSAltitude', Groups = { [2] = 'Location' }, Notes = 'altitude' },
    [3] = { Name = 'HeartRate', PrintConv = u('bpm') },
    [4] = { Name = 'Cadence', PrintConv = u('rpm') },
    [5] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [6] = speedInfo { Name = 'GPSSpeed', Groups = { [2] = 'Location' }, Notes = 'speed' },
    [7] = { Name = 'Power', PrintConv = u('watts') },
    [8] = 'CompressedSpeedDistance', -- [3] / 100,16 m/s,m
    [9] = { Name = 'Grade', ValueConv = d(100), PrintConv = u('%') },
    [10] = 'Resistance',
    [11] = { Name = 'TimeFromCourse', ValueConv = d(1000), PrintConv = u('s') },
    [12] = { Name = 'CycleLength', ValueConv = d(100), PrintConv = u('m') },
    [13] = { Name = 'Temperature', PrintConv = u('C') },
    [17] = 'Speed_1s', -- [N] / 16 m/s
    [18] = { Name = 'Cycles', PrintConv = u('cycles') },
    [19] = { Name = 'TotalCycles', PrintConv = u('cycles') },
    [28] = { Name = 'CompressedAccumulatedPower', PrintConv = u('watts') },
    [29] = { Name = 'AccumulatedPower', PrintConv = u('watts') },
    [30] = 'LeftRightBalance',
    [31] = { Name = 'GPSAccuracy', PrintConv = u('m') },
    [32] = { Name = 'VerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [33] = { Name = 'Calories', PrintConv = u('kcal') },
    [39] = { Name = 'VerticalOscillation', ValueConv = d(10), PrintConv = u('mm') },
    [40] = { Name = 'StanceTimePercent', ValueConv = d(100), PrintConv = u('%') },
    [41] = { Name = 'StanceTime', ValueConv = d(10), PrintConv = u('ms') },
    [42] = { Name = 'ActivityType', PrintConv = activityType, SeparateTable = 'ActivityType' },
    [43] = { Name = 'LeftTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [44] = { Name = 'RightTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [45] = { Name = 'LeftPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [46] = { Name = 'RightPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [47] = { Name = 'CombinedPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [48] = { Name = 'Time128', ValueConv = d(128), PrintConv = u('s') },
    [49] = { Name = 'StrokeType', PrintConv = strokeType },
    [50] = 'Zone',
    [51] = { Name = 'BallSpeed', ValueConv = d(100), PrintConv = u('m/s') },
    [52] = { Name = 'Cadence256', ValueConv = d(256), PrintConv = u('rpm') },
    [53] = { Name = 'FractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [54] = { Name = 'TotalHemoglobinConc', ValueConv = d(100), PrintConv = u('g/dL') },
    [55] = { Name = 'TotalHemoglobinConcMin', ValueConv = d(100), PrintConv = u('g/dL') },
    [56] = { Name = 'TotalHemoglobinConcMax', ValueConv = d(100), PrintConv = u('g/dL') },
    [57] = { Name = 'SaturatedHemoglobinPercent', ValueConv = d(10), PrintConv = u('%') },
    [58] = { Name = 'SaturatedHemoglobinPercentMin', ValueConv = d(10), PrintConv = u('%') },
    [59] = { Name = 'SaturatedHemoglobinPercentMax', ValueConv = d(10), PrintConv = u('%') },
    [62] = 'DeviceIndex',
    [67] = { Name = 'LeftPco', PrintConv = u('mm') },
    [68] = { Name = 'RightPco', PrintConv = u('mm') },
    [69] = 'LeftPowerPhase', -- [N] / 0.7111111 degrees
    [70] = 'LeftPowerPhasePeak', -- [N] / 0.7111111 degrees
    [71] = 'RightPowerPhase', -- [N] / 0.7111111 degrees
    [72] = 'RightPowerPhasePeak', -- [N] / 0.7111111 degrees
    [73] = speedInfo { Name = 'GPSSpeed', Groups = { [2] = 'Location' }, Notes = 'enhanced_speed' },
    [78] = altInfo { Name = 'GPSAltitude', Groups = { [2] = 'Location' }, Notes = 'enhanced_altitude' },
    [81] = { Name = 'BatterySoc', ValueConv = d(2), PrintConv = u('%') },
    [82] = { Name = 'MotorPower', PrintConv = u('watts') },
    [83] = { Name = 'VerticalRatio', ValueConv = d(100), PrintConv = u('%') },
    [84] = { Name = 'StanceTimeBalance', ValueConv = d(100), PrintConv = u('%') },
    [85] = { Name = 'StepLength', ValueConv = d(10), PrintConv = u('mm') },
    [87] = { Name = 'CycleLength16', ValueConv = d(100), PrintConv = u('m') },
    [90] = 'PerformanceCondition', --4
    [91] = { Name = 'AbsolutePressure', PrintConv = u('Pa') },
    [92] = { Name = 'Depth', ValueConv = d(1000), PrintConv = u('m') },
    [93] = { Name = 'NextStopDepth', ValueConv = d(1000), PrintConv = u('m') },
    [94] = { Name = 'NextStopTime', ValueConv = d(1), PrintConv = u('s') },
    [95] = { Name = 'TimeToSurface', ValueConv = d(1), PrintConv = u('s') },
    [96] = { Name = 'NdlTime', ValueConv = d(1), PrintConv = u('s') },
    [97] = { Name = 'CnsLoad', PrintConv = u('%') },
    [98] = { Name = 'N2Load', ValueConv = d(1), PrintConv = u('%') },
    [99] = { Name = 'RespirationRate', ValueConv = d(1), PrintConv = u('s') },
    [108] = { Name = 'EnhancedRespirationRate', ValueConv = d(100), PrintConv = u('Breaths/min') },
    [114] = 'Grit',
    [115] = 'Flow',
    [116] = { Name = 'CurrentStress', ValueConv = d(100) },
    [117] = { Name = 'EbikeTravelRange', PrintConv = u('km') },
    [118] = { Name = 'EbikeBatteryLevel', PrintConv = u('%') },
    [119] = { Name = 'EbikeAssistMode', PrintConv = u('depends on sensor') },
    [120] = { Name = 'EbikeAssistLevelPercent', PrintConv = u('%') },
    [121] = { Name = 'TotalAscent', PrintConv = u('m') }, --4
    [123] = { Name = 'AirTimeRemaining', PrintConv = u('s') },
    [124] = { Name = 'PressureSac', ValueConv = d(100), PrintConv = u('bar/min') },
    [125] = { Name = 'VolumeSac', ValueConv = d(100), PrintConv = u('L/min') },
    [126] = { Name = 'Rmv', ValueConv = d(100), PrintConv = u('L/min') },
    [127] = { Name = 'AscentRate', ValueConv = d(1000), PrintConv = u('m/s') },
    [129] = { Name = 'PO2', ValueConv = d(100), PrintConv = u('%') },
    [136] = { Name = 'WristHeartRate', PrintConv = u('bpm') }, --4
    [137] = 'StaminaPotential', --4
    [138] = 'Stamina', --4
    [139] = { Name = 'CoreTemperature', ValueConv = d(100), PrintConv = u('C') },
    [140] = { Name = 'GradeAdjustedSpeed', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [143] = 'BodyBattery', --4
    [144] = { Name = 'ExternalHeartRate', PrintConv = u('bpm') }, --4
    [146] = { Name = 'StepSpeedLossDistance', ValueConv = d(100), PrintConv = u('cm/s') }, --4
    [147] = { Name = 'StepSpeedLossPercentage', ValueConv = d(100), PrintConv = u('%') }, --4
    [148] = { Name = 'Force', ValueConv = d(1000), PrintConv = u('N') }, --4
}

Garmin.Event = {
    GROUPS = { [0] = 'Garmin', [1] = 'Event', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Event', PrintConv = eventEnum, SeparateTable = 'EventEnum' },
    [1] = { Name = 'EventType', PrintConv = eventType, SeparateTable = 'EventType' },
    [2] = 'Data16',
    [3] = 'Data',
    [4] = 'EventGroup',
    [7] = 'Score',
    [8] = 'OpponentScore',
    [9] = 'FrontGearNum',
    [10] = 'FrontGear',
    [11] = 'RearGearNum',
    [12] = 'RearGear',
    [13] = 'DeviceIndex',
    [14] = { Name = 'ActivityType', PrintConv = activityType, SeparateTable = 'ActivityType' },
    [15] = timeInfo { Name = 'StartTimeStamp', Groups = { [2] = 'Time' } },
    [21] = { Name = 'RadarThreatLevelMax', PrintConv = radarThreatLevelType },
    [22] = 'RadarThreatCount',
    [23] = { Name = 'RadarThreatAvgApproachSpeed', ValueConv = d(10), PrintConv = u('m/s') },
    [24] = { Name = 'RadarThreatMaxApproachSpeed', ValueConv = d(10), PrintConv = u('m/s') },
}

Garmin.DeviceInfo = {
    GROUPS = { [0] = 'Garmin', [1] = 'DeviceInfo', [2] = 'Device' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'DeviceIndex',
    [1] = 'DeviceType',
    [2] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [3] = 'SerialNumber',
    [4] = 'Product',
    [5] = { Name = 'SoftwareVersion', ValueConv = d(100) },
    [6] = 'HardwareVersion',
    [7] = { Name = 'CumOperatingTime', PrintConv = u('s') },
    [10] = { Name = 'BatteryVoltage', ValueConv = d(256), PrintConv = u('V') },
    [11] = { Name = 'BatteryStatus', PrintConv = batteryStatus, SeparateTable = 'BatteryStatus' },
    [18] = { Name = 'SensorPosition', PrintConv = bodyLocation, PrintConvColumns = 2 },
    [19] = 'Descriptor',
    [20] = 'AntTransmissionType',
    [21] = 'AntDeviceNumber',
    [22] = { Name = 'AntNetwork', PrintConv = antNetwork },
    [24] = 'AntID', --4
    [25] = { Name = 'SourceType', PrintConv = sourceType, SeparateTable = 'SourceType' },
    [27] = 'ProductName',
    [32] = { Name = 'BatteryLevel', PrintConv = u('%') },
}

Garmin.DeviceAuxBatteryInfo = {
    GROUPS = { [0] = 'Garmin', [1] = 'AuxBattery', [2] = 'Device' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'DeviceIndex',
    [1] = { Name = 'BatteryVoltage', ValueConv = d(256), PrintConv = u('V') },
    [2] = { Name = 'BatteryStatus', PrintConv = batteryStatus, SeparateTable = 'BatteryStatus' },
    [3] = 'BatteryIdentifier',
}

Garmin.TrainingFile = {
    GROUPS = { [0] = 'Garmin', [1] = 'TrainingFile', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TrainingFileType', PrintConv = file, SeparateTable = 'File' },
    [1] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [2] = 'Product',
    [3] = 'SerialNumber',
    [4] = timeInfo { Name = 'TimeCreated', Groups = { [2] = 'Time' } },
}

Garmin.WeatherConditions = {
    GROUPS = { [0] = 'Garmin', [1] = 'WeatherConditions', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'WeatherReport', PrintConv = weatherReport },
    [1] = { Name = 'Temperature', PrintConv = u('C') },
    [2] = { Name = 'Condition', PrintConv = weatherStatus },
    [3] = { Name = 'WindDirection', PrintConv = u('degrees') },
    [4] = { Name = 'WindSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [5] = 'PrecipitationProbability',
    [6] = { Name = 'TemperatureFeelsLike', PrintConv = u('C') },
    [7] = 'RelativeHumidity',
    [8] = 'Location',
    [9] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'observed_at_time', IsTimeStamp = 1 },
    [10] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'observed_location_lat' },
    [11] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'observed_location_long' },
    [12] = { Name = 'DayOfWeek', PrintConv = dayOfWeek },
    [13] = { Name = 'HighTemperature', PrintConv = u('C') },
    [14] = { Name = 'LowTemperature', PrintConv = u('C') },
}

Garmin.WeatherAlert = {
    GROUPS = { [0] = 'Garmin', [1] = 'WeatherAlert', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ReportID',
    [1] = timeInfo { Name = 'IssueTime', Groups = { [2] = 'Time' } },
    [2] = timeInfo { Name = 'ExpireTime', Groups = { [2] = 'Time' } },
    [3] = { Name = 'Severity', PrintConv = weatherSeverity },
    [4] = { Name = 'WeatherAlertType', PrintConv = weatherSevereType, PrintConvColumns = 2 },
}

Garmin.GPS = {
    GROUPS = { [0] = 'Garmin', [1] = 'GPS', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = latInfo { Name = 'GPSLatitude', Notes = 'position_lat' },
    [2] = lonInfo { Name = 'GPSLongitude', Notes = 'position_long' },
    [3] = altInfo { Name = 'GPSAltitude', Notes = 'enhanced_altitude' },
    [4] = speedInfo { Name = 'GPSSpeed', Notes = 'enhanced_speed' },
    [5] = { Name = 'GPSTrack', ValueConv = d(100), Notes = 'heading' }, -- (deg)
    [6] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'utc_timestamp', IsTimeStamp = 1 },
    [7] = {
        Name = 'Velocity',
        Notes = 'm/s in longitude, latitude and altitude directions',
        ValueConv = function(_self, val)
            local a = perl.split(' ', str(val))
            for i = 1, #a do a[i] = ExifTool.NumStr(tonumber(a[i]) / 100) end
            return perl.join(' ', a)
        end,
    },
}

Garmin.CameraEvent = {
    GROUPS = { [0] = 'Garmin', [1] = 'CameraEvent', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = { Name = 'CameraEventType', PrintConv = cameraEventType },
    [2] = 'CameraFileUUID',
    [3] = { Name = 'CameraOrientation', PrintConv = cameraOrientationType },
}

Garmin.GyroscopeData = {
    GROUPS = { [0] = 'Garmin', [1] = 'GyroData', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'SampleTimeOffset', -- [N] ms
    [2] = 'GyroX', -- [N] counts
    [3] = 'GyroY', -- [N] counts
    [4] = 'GyroZ', -- [N] counts
    [5] = 'CalibratedGyroX', -- [N] deg/s
    [6] = 'CalibratedGyroY', -- [N] deg/s
    [7] = 'CalibratedGyroZ', -- [N] deg/s
}

Garmin.AccelerometerData = {
    GROUPS = { [0] = 'Garmin', [1] = 'AccelData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'SampleTimeOffset', -- [N] ms
    [2] = 'AccelX', -- [N] counts
    [3] = 'AccelY', -- [N] counts
    [4] = 'AccelZ', -- [N] counts
    [5] = 'CalibratedAccelX', -- [N] g
    [6] = 'CalibratedAccelY', -- [N] g
    [7] = 'CalibratedAccelZ', -- [N] g
    [8] = 'CompressedCalibratedAccelX', -- [N] mG
    [9] = 'CompressedCalibratedAccelY', -- [N] mG
    [10] = 'CompressedCalibratedAccelZ', -- [N] mG
}

Garmin.MagnetometerData = {
    GROUPS = { [0] = 'Garmin', [1] = 'MagData', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'SampleTimeOffset', -- [N] ms
    [2] = 'MagX', -- [N] counts
    [3] = 'MagY', -- [N] counts
    [4] = 'MagZ', -- [N] counts
    [5] = 'CalibratedMagX', -- [N] G
    [6] = 'CalibratedMagY', -- [N] G
    [7] = 'CalibratedMagZ', -- [N] G
}

Garmin.BarometerData = {
    GROUPS = { [0] = 'Garmin', [1] = 'Barometer', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'SampleTimeOffset', -- [N] ms
    [2] = 'BaroPres', -- [N] Pa
}

Garmin.ThreeDSensorCalibration = {
    GROUPS = { [0] = 'Garmin', [1] = 'ThreeDSensorCal', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'SensorType', PrintConv = sensorType, SeparateTable = 'SensorType' },
    [1] = 'CalibrationFactor',
    [2] = { Name = 'CalibrationDivisor', PrintConv = u('counts') },
    [3] = 'LevelShift',
    [4] = 'OffsetCal', -- [3]
    [5] = 'OrientationMatrix', -- [9] / 65535
}

Garmin.OneDSensorCalibration = {
    GROUPS = { [0] = 'Garmin', [1] = 'OneDSensorCal', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'SensorType', PrintConv = sensorType, SeparateTable = 'SensorType' },
    [1] = 'CalibrationFactor',
    [2] = { Name = 'CalibrationDivisor', PrintConv = u('counts') },
    [3] = 'LevelShift',
    [4] = 'OffsetCal',
}

Garmin.VideoFrame = {
    GROUPS = { [0] = 'Garmin', [1] = 'VideoFrame', [2] = 'Video' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'FrameNumber',
}

Garmin.OBDIIData = {
    GROUPS = { [0] = 'Garmin', [1] = 'OBDIIData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'TimeOffset', -- [N] ms
    [2] = 'Pid',
    [3] = 'RawData', -- [N]
    [4] = 'PidDataSize', -- [N]
    [5] = 'SystemTime', -- [N]
    [6] = timeInfo { Name = 'StartTimeStamp', Groups = { [2] = 'Time' } },
    [7] = { Name = 'StartTimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
}

Garmin.NMEASentence = {
    GROUPS = { [0] = 'Garmin', [1] = 'NMEA', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'Sentence', -- eventually could decode this, but a sample would be helpful
}

Garmin.AviationAttitude = {
    GROUPS = { [0] = 'Garmin', [1] = 'AviationAttitude', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'SystemTime', -- [N] ms
    [2] = 'Pitch', -- [N] / 10430.38 radians
    [3] = 'Roll', -- [N] / 10430.38 radians
    [4] = 'AccelLateral', -- [N] / 100 m/s^2
    [5] = 'AccelNormal', -- [N] / 100 m/s^2
    [6] = 'TurnRate', -- [N] / 1024 radians/second
    [7] = 'Stage', -- [N]
    [8] = 'AttitudeStageComplete', -- [N] %
    [9] = 'Track', -- [N] / 10430.38 radians
    [10] = 'Validity', -- [N]
}

Garmin.Video = {
    GROUPS = { [0] = 'Garmin', [1] = 'Video', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'URL',
    [1] = 'HostingProvider',
    [2] = { Name = 'Duration', PrintConv = u('ms') },
}

Garmin.VideoTitle = {
    GROUPS = { [0] = 'Garmin', [1] = 'VideoTitle', [2] = 'Video' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'MessageCount',
    [1] = 'Text',
}

Garmin.VideoDescription = {
    GROUPS = { [0] = 'Garmin', [1] = 'VideoDescr', [2] = 'Video' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'MessageCount',
    [1] = 'Text',
}

Garmin.VideoClip = {
    GROUPS = { [0] = 'Garmin', [1] = 'VideoClip', [2] = 'Video' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ClipNumber',
    [1] = timeInfo { Name = 'StartTimeStamp', Groups = { [2] = 'Time' } },
    [2] = 'StartTimeStamp_ms',
    [3] = timeInfo { Name = 'EndTimeStamp', Groups = { [2] = 'Time' } },
    [4] = 'EndTimeStamp_ms',
    [6] = { Name = 'ClipStart', PrintConv = u('ms') },
    [7] = { Name = 'ClipEnd', PrintConv = u('ms') },
}

Garmin.Set = {
    GROUPS = { [0] = 'Garmin', [1] = 'Set', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Duration', ValueConv = d(1000), PrintConv = u('s') },
    [3] = 'Repetitions',
    [4] = { Name = 'Weight', ValueConv = d(16), PrintConv = u('kg') },
    [5] = { Name = 'SetType', PrintConv = setType },
    [6] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [7] = 'Category', -- [N]
    [8] = 'CategorySubtype', -- [N]
    [9] = { Name = 'WeightDisplayUnit', PrintConv = fitBaseUnit, SeparateTable = 'FitBaseUnit' },
    [10] = 'MessageIndex',
    [11] = 'WktStepIndex',
}

Garmin.Jump = {
    GROUPS = { [0] = 'Garmin', [1] = 'Jump', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Distance', PrintConv = u('m') },
    [1] = { Name = 'Height', PrintConv = u('m') },
    [2] = 'Rotations',
    [3] = { Name = 'HangTime', PrintConv = u('s') },
    [4] = 'Score',
    [5] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'position_lat' },
    [6] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'position_long' },
    [7] = speedInfo { Name = 'GPSSpeed', Groups = { [2] = 'Location' }, Notes = 'speed' },
    [8] = speedInfo { Name = 'GPSSpeed', Groups = { [2] = 'Location' }, Notes = 'enhanced_speed' },
}

Garmin.Split = {
    GROUPS = { [0] = 'Garmin', [1] = 'Split', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'SplitType', PrintConv = splitType, SeparateTable = 'SplitType' },
    [1] = { Name = 'TotalElapsedTime', ValueConv = d(1000), PrintConv = u('s') },
    [2] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [3] = { Name = 'TotalDistance', ValueConv = d(100), PrintConv = u('m') },
    [4] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [7] = { Name = 'StartDistance', ValueConv = d(100), PrintConv = u('m') }, --4
    [9] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'start_time', IsTimeStamp = 1 },
    [11] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' }, --4
    [12] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' }, --4
    [13] = { Name = 'TotalAscent', PrintConv = u('m') },
    [14] = { Name = 'TotalDescent', PrintConv = u('m') },
    [15] = { Name = 'AvgHeartRate', PrintConv = u('bpm') }, --4
    [16] = { Name = 'MaxHeartRate', PrintConv = u('bpm') }, --4
    [21] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'start_position_lat' },
    [22] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'start_position_long' },
    [23] = latInfo { Name = 'GPSDestLatitude', Groups = { [2] = 'Location' }, Notes = 'end_position_lat' },
    [24] = lonInfo { Name = 'GPSDestLongitude', Groups = { [2] = 'Location' }, Notes = 'end_position_long' },
    [25] = { Name = 'MaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [26] = { Name = 'AvgVertSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [27] = timeInfo { Name = 'EndTime', Groups = { [2] = 'Time' } },
    [28] = { Name = 'TotalCalories', PrintConv = u('kcal') },
    [32] = { Name = 'AvgTemperature', PrintConv = u('C') }, --4
    [33] = { Name = 'MaxTemperature', PrintConv = u('C') }, --4
    [34] = { Name = 'MinTemperature', PrintConv = u('C') }, --4
    [35] = { Name = 'AvgVerticalOscillation', ValueConv = d(10), PrintConv = u('mm') }, --4
    [36] = { Name = 'AvgVerticalRatio', ValueConv = d(100), PrintConv = u('%') }, --4
    [37] = { Name = 'AvgStanceTime', ValueConv = d(10), PrintConv = u('ms') }, --4
    [38] = { Name = 'AvgStanceTimeBalance', ValueConv = d(100), PrintConv = u('%') }, --4
    [39] = { Name = 'AvgStepLength', ValueConv = d(10), PrintConv = u('mm') }, --4
    [40] = { Name = 'AvgPower', PrintConv = u('watts') }, --4
    [41] = { Name = 'MaxPower', PrintConv = u('watts') }, --4
    [42] = { Name = 'NormalizedPower', PrintConv = u('watts') }, --4
    [67] = 'LapIndex', --4
    [74] = { Name = 'StartElevation', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [79] = { Name = 'RestingCalories', PrintConv = u('kcal') }, --4
    [93] = { Name = 'GradeAdjustedSpeed', ValueConv = d(1000), PrintConv = u('m/s') }, --4
    [107] = 'BeginningPotential', --4
    [108] = 'EndingPotential', --4
    [109] = 'MinStamina', --4
    [110] = { Name = 'TotalMovingTime', ValueConv = d(1000), PrintConv = u('s') },
    [130] = { Name = 'StepSpeedLossDistance', ValueConv = d(100), PrintConv = u('cm/s') }, --4
    [131] = { Name = 'StepSpeedLossPercentage', ValueConv = d(100), PrintConv = u('%') }, --4
}

Garmin.SplitSummary = {
    GROUPS = { [0] = 'Garmin', [1] = 'SplitSummary', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'SplitType', PrintConv = splitType, SeparateTable = 'SplitType' },
    [3] = 'NumSplits',
    [4] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [5] = { Name = 'TotalDistance', ValueConv = d(100), PrintConv = u('m') },
    [6] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [7] = { Name = 'MaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [8] = { Name = 'TotalAscent', PrintConv = u('m') },
    [9] = { Name = 'TotalDescent', PrintConv = u('m') },
    [10] = { Name = 'AvgHeartRate', PrintConv = u('bpm') },
    [11] = { Name = 'MaxHeartRate', PrintConv = u('bpm') },
    [12] = { Name = 'AvgVertSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [13] = { Name = 'TotalCalories', PrintConv = u('kcal') },
    [20] = { Name = 'AvgVerticalOscillation', ValueConv = d(10), PrintConv = u('mm') }, --4
    [21] = { Name = 'AvgVerticalRatio', ValueConv = d(100), PrintConv = u('%') }, --4
    [22] = { Name = 'AvgStanceTime', ValueConv = d(10), PrintConv = u('ms') }, --4
    [24] = { Name = 'AvgStepLength', ValueConv = d(10), PrintConv = u('mm') }, --4
    [25] = { Name = 'AvgPower', PrintConv = u('watts') }, --4
    [26] = { Name = 'MaxPower', PrintConv = u('watts') }, --4
    [27] = { Name = 'NormalizedPower', PrintConv = u('watts') }, --4
    [60] = { Name = 'MaxSplitDistance', ValueConv = d(100), PrintConv = u('m') }, --4
    [64] = { Name = 'RestingCalories', PrintConv = u('kcal') }, --4
    [77] = { Name = 'TotalMovingTime', ValueConv = d(1000), PrintConv = u('s') },
    [79] = timeInfo { Name = 'FirstStartTime', Groups = { [2] = 'Time' } }, --4
    [83] = { Name = 'StepSpeedLossDistance', ValueConv = d(100), PrintConv = u('cm/s') }, --4
    [84] = { Name = 'StepSpeedLossPercentage', ValueConv = d(100), PrintConv = u('%') }, --4
}

Garmin.ClimbPro = {
    GROUPS = { [0] = 'Garmin', [1] = 'ClimbPro', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'position_lat' },
    [1] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'position_long' },
    [2] = { Name = 'ClimbProEvent', PrintConv = climbProEvent },
    [3] = 'ClimbNumber',
    [4] = 'ClimbCategory',
    [5] = { Name = 'CurrentDist', PrintConv = u('m') },
}

Garmin.FieldDescription = {
    GROUPS = { [0] = 'Garmin', [1] = 'FieldDescr', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    NOTES = 'Tags used to define custom developer fields.',
    [0] = 'DeveloperDataIndex',
    [1] = 'FieldDefinitionNumber',
    [2] = { Name = 'FitBaseTypeID', PrintConv = fitBaseType },
    [3] = 'FieldName', -- [N]
    [4] = 'Array',
    [5] = 'Components',
    [6] = 'Scale',
    [7] = 'Offset',
    [8] = 'Units', -- [N]
    [9] = 'Bits',
    [10] = 'Accumulate',
    [13] = { Name = 'FitBaseUnitID', PrintConv = fitBaseUnit, SeparateTable = 'FitBaseUnit' },
    [14] = { Name = 'NativeMesgNum', PrintConv = mesgNum, SeparateTable = 'MesgNum' },
    [15] = 'NativeFieldNum',
}

Garmin.DeveloperDataID = {
    GROUPS = { [0] = 'Garmin', [1] = 'DevDataID', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    NOTES = 'Developer identification tags.',
    [0] = 'DeveloperID', -- [N]
    [1] = 'ApplicationID', -- [N]
    [2] = { Name = 'ManufacturerID', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [3] = 'DeveloperDataIndex',
    [4] = 'ApplicationVersion',
}

Garmin.Course = {
    GROUPS = { [0] = 'Garmin', [1] = 'Course', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [4] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [5] = 'CourseName',
    [6] = { Name = 'Capabilities', PrintConv = courseCapabilities },
    [7] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
}

Garmin.CoursePoint = {
    GROUPS = { [0] = 'Garmin', [1] = 'CoursePoint', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'timestamp', IsTimeStamp = 1 },
    [2] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'position_lat' },
    [3] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'position_long' },
    [4] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [5] = { Name = 'CoursePointType', PrintConv = coursePointEnum },
    [6] = 'CoursePointName',
    [8] = 'Favorite',
}

Garmin.SegmentID = {
    GROUPS = { [0] = 'Garmin', [1] = 'SegmentID', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'SegmentIDName',
    [1] = 'UUID',
    [2] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [3] = 'Enabled',
    [4] = 'UserProfilePrimaryKey',
    [5] = 'DeviceID',
    [6] = 'DefaultRaceLeader',
    [7] = { Name = 'DeleteStatus', PrintConv = segmentDeleteStatus },
    [8] = { Name = 'SelectionType', PrintConv = segmentSelectionType },
}

Garmin.SegmentLeaderboardEntry = {
    GROUPS = { [0] = 'Garmin', [1] = 'SegLeaderboard', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'SegmentLeaderboardName',
    [1] = { Name = 'SegLeaderboardType', PrintConv = segmentLeaderboardType, SeparateTable = 'SegmentLeaderboardType' },
    [2] = 'GroupPrimaryKey',
    [3] = 'ActivityID',
    [4] = { Name = 'SegmentTime', ValueConv = d(1000), PrintConv = u('s') },
    [5] = 'ActivityIDString',
}

Garmin.SegmentPoint = {
    GROUPS = { [0] = 'Garmin', [1] = 'SegPoint', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'position_lat' },
    [2] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'position_long' },
    [3] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [4] = altInfo { Name = 'GPSAltitude', Groups = { [2] = 'Location' }, Notes = 'altitude' },
    [5] = 'LeaderTime', -- [N] / 1000 s
    [6] = altInfo { Name = 'GPSAltitude', Groups = { [2] = 'Location' }, Notes = 'enhanced_altitude' },
}

Garmin.SegmentLap = {
    GROUPS = { [0] = 'Garmin', [1] = 'SegLap', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Event', PrintConv = eventEnum, SeparateTable = 'EventEnum' },
    [1] = { Name = 'EventType', PrintConv = eventType, SeparateTable = 'EventType' },
    [2] = timeInfo { Name = 'GPSDateTime', Groups = { [2] = 'Time' }, Notes = 'start_time', IsTimeStamp = 1 },
    [3] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'start_position_lat' },
    [4] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'start_position_long' },
    [5] = latInfo { Name = 'GPSDestLatitude', Groups = { [2] = 'Location' }, Notes = 'end_position_lat' },
    [6] = lonInfo { Name = 'GPSDestLongitude', Groups = { [2] = 'Location' }, Notes = 'end_position_long' },
    [7] = { Name = 'TotalElapsedTime', ValueConv = d(1000), PrintConv = u('s') },
    [8] = { Name = 'TotalTimerTime', ValueConv = d(1000), PrintConv = u('s') },
    [9] = { Name = 'TotalDistance', ValueConv = d(100), PrintConv = u('m') },
    [10] = { Name = 'TotalCycles', PrintConv = u('cycles') },
    [11] = { Name = 'TotalCalories', PrintConv = u('kcal') },
    [12] = { Name = 'TotalFatCalories', PrintConv = u('kcal') },
    [13] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [14] = { Name = 'MaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [15] = { Name = 'AvgHeartRate', PrintConv = u('bpm') },
    [16] = { Name = 'MaxHeartRate', PrintConv = u('bpm') },
    [17] = { Name = 'AvgCadence', PrintConv = u('rpm') },
    [18] = { Name = 'MaxCadence', PrintConv = u('rpm') },
    [19] = { Name = 'AvgPower', PrintConv = u('watts') },
    [20] = { Name = 'MaxPower', PrintConv = u('watts') },
    [21] = { Name = 'TotalAscent', PrintConv = u('m') },
    [22] = { Name = 'TotalDescent', PrintConv = u('m') },
    [23] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [24] = 'EventGroup',
    [25] = latInfo { Name = 'NECLatitude', Groups = { [2] = 'Location' } },
    [26] = lonInfo { Name = 'NECLongitude', Groups = { [2] = 'Location' } },
    [27] = latInfo { Name = 'SWCLatitude', Groups = { [2] = 'Location' } },
    [28] = lonInfo { Name = 'SWCLongitude', Groups = { [2] = 'Location' } },
    [29] = 'SegmentLapName',
    [30] = { Name = 'NormalizedPower', PrintConv = u('watts') },
    [31] = 'LeftRightBalance',
    [32] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [33] = { Name = 'TotalWork', PrintConv = u('J') },
    [34] = { Name = 'AvgAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [35] = { Name = 'MaxAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [36] = { Name = 'GPSAccuracy', PrintConv = u('m') },
    [37] = { Name = 'AvgGrade', ValueConv = d(100), PrintConv = u('%') },
    [38] = { Name = 'AvgPosGrade', ValueConv = d(100), PrintConv = u('%') },
    [39] = { Name = 'AvgNegGrade', ValueConv = d(100), PrintConv = u('%') },
    [40] = { Name = 'MaxPosGrade', ValueConv = d(100), PrintConv = u('%') },
    [41] = { Name = 'MaxNegGrade', ValueConv = d(100), PrintConv = u('%') },
    [42] = { Name = 'AvgTemperature', PrintConv = u('C') },
    [43] = { Name = 'MaxTemperature', PrintConv = u('C') },
    [44] = { Name = 'TotalMovingTime', ValueConv = d(1000), PrintConv = u('s') },
    [45] = { Name = 'AvgPosVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [46] = { Name = 'AvgNegVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [47] = { Name = 'MaxPosVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [48] = { Name = 'MaxNegVerticalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [49] = 'TimeInHRZone', -- [N] / 1000 s
    [50] = 'TimeInSpeedZone', -- [N] / 1000 s
    [51] = 'TimeInCadenceZone', -- [N] / 1000 s
    [52] = 'TimeInPowerZone', -- [N] / 1000 s
    [53] = 'RepetitionNum',
    [54] = { Name = 'MinAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [55] = { Name = 'MinHeartRate', PrintConv = u('bpm') },
    [56] = { Name = 'ActiveTime', ValueConv = d(1000), PrintConv = u('s') },
    [57] = 'WktStepIndex',
    [58] = { Name = 'SportEvent', PrintConv = sportEvent },
    [59] = { Name = 'AvgLeftTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [60] = { Name = 'AvgRightTorqueEffectiveness', ValueConv = d(2), PrintConv = u('%') },
    [61] = { Name = 'AvgLeftPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [62] = { Name = 'AvgRightPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [63] = { Name = 'AvgCombinedPedalSmoothness', ValueConv = d(2), PrintConv = u('%') },
    [64] = { Name = 'Status', PrintConv = segmentLapStatus },
    [65] = 'UUID',
    [66] = { Name = 'AvgFractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [67] = { Name = 'MaxFractionalCadence', ValueConv = d(128), PrintConv = u('rpm') },
    [68] = { Name = 'TotalFractionalCycles', ValueConv = d(128), PrintConv = u('cycles') },
    [69] = 'FrontGearShiftCount',
    [70] = 'RearGearShiftCount',
    [71] = { Name = 'TimeStanding', ValueConv = d(1000), PrintConv = u('s') },
    [72] = 'StandCount',
    [73] = { Name = 'AvgLeftPco', PrintConv = u('mm') },
    [74] = { Name = 'AvgRightPco', PrintConv = u('mm') },
    [75] = 'AvgLeftPowerPhase', -- [N] / 0.7111111 degrees
    [76] = 'AvgLeftPowerPhasePeak', -- [N] / 0.7111111 degrees
    [77] = 'AvgRightPowerPhase', -- [N] / 0.7111111 degrees
    [78] = 'AvgRightPowerPhasePeak', -- [N] / 0.7111111 degrees
    [79] = 'AvgPowerPosition', -- [N] watts
    [80] = 'MaxPowerPosition', -- [N] watts
    [81] = 'AvgCadencePosition', -- [N] rpm
    [82] = 'MaxCadencePosition', -- [N] rpm
    [83] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [84] = { Name = 'TotalGrit', PrintConv = u('kGrit') },
    [85] = { Name = 'TotalFlow', PrintConv = u('Flow') },
    [86] = { Name = 'AvgGrit', PrintConv = u('kGrit') },
    [87] = { Name = 'AvgFlow', PrintConv = u('Flow') },
    [89] = { Name = 'TotalFractionalAscent', ValueConv = d(100), PrintConv = u('m') },
    [90] = { Name = 'TotalFractionalDescent', ValueConv = d(100), PrintConv = u('m') },
    [91] = { Name = 'EnhancedAvgAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [92] = { Name = 'EnhancedMaxAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [93] = { Name = 'EnhancedMinAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
}

Garmin.SegmentFile = {
    GROUPS = { [0] = 'Garmin', [1] = 'SegFile', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'FileUUID',
    [3] = 'Enabled',
    [4] = 'UserProfilePrimaryKey',
    [7] = 'LeaderType', -- [N]
    [8] = 'LeaderGroupPrimaryKey', -- [N]
    [9] = 'LeaderActivityID', -- [N]
    [10] = 'LeaderActivityIDString', -- [N]
    [11] = 'DefaultRaceLeader',
}

Garmin.Workout = {
    GROUPS = { [0] = 'Garmin', [1] = 'Workout', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [4] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [5] = { Name = 'Capabilities', PrintConv = workoutCapabilities, SeparateTable = 'WorkoutCapabilities' },
    [6] = 'NumValidSteps',
    [8] = 'WorkoutName',
    [9] = { Name = 'DurationType', PrintConv = wktStepDuration, SeparateTable = 'WktStepDuration' }, --4
    [10] = 'DurationValue', --4
    [11] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [14] = { Name = 'PoolLength', ValueConv = d(100), PrintConv = u('m') },
    [15] = { Name = 'PoolLengthUnit', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
    [17] = 'WorkoutDescription',
    [20] = 'WorkoutIndex', --4
    [21] = { Name = 'Time', ValueConv = d(1000), PrintConv = u('s') }, --4
    [22] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') }, --4
}

Garmin.WorkoutSession = {
    GROUPS = { [0] = 'Garmin', [1] = 'WorkoutSess', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [1] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [2] = 'NumValidSteps',
    [3] = 'FirstStepIndex',
    [4] = { Name = 'PoolLength', ValueConv = d(100), PrintConv = u('m') },
    [5] = { Name = 'PoolLengthUnit', PrintConv = displayMeasure, SeparateTable = 'DisplayMeasure' },
}

Garmin.WorkoutStep = {
    GROUPS = { [0] = 'Garmin', [1] = 'WorkoutStep', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'WktStepName',
    [1] = { Name = 'DurationType', PrintConv = wktStepDuration, SeparateTable = 'WktStepDuration' },
    [2] = 'DurationValue',
    [3] = { Name = 'TargetType', PrintConv = wktStepTarget, SeparateTable = 'WktStepTarget' },
    [4] = 'TargetValue',
    [5] = 'CustomTargetValueLow',
    [6] = 'CustomTargetValueHigh',
    [7] = { Name = 'Intensity', PrintConv = intensity, SeparateTable = 'Intensity' },
    [8] = 'Notes',
    [9] = { Name = 'Equipment', PrintConv = workoutEquipment },
    [10] = { Name = 'ExerciseCategory', PrintConv = exerciseCategory, SeparateTable = 'ExerciseCategory' },
    [11] = 'ExerciseName',
    [12] = { Name = 'ExerciseWeight', ValueConv = d(100), PrintConv = u('kg') },
    [13] = { Name = 'WeightDisplayUnit', PrintConv = fitBaseUnit, SeparateTable = 'FitBaseUnit' },
    [18] = { Name = 'SkipLastRecover', PrintConv = yesNo, SeparateTable = 'YesNo' }, --4
    [19] = { Name = 'SecondaryTargetType', PrintConv = wktStepTarget, SeparateTable = 'WktStepTarget' },
    [20] = 'SecondaryTargetValue',
    [21] = 'SecondaryCustomTargetValueLow',
    [22] = 'SecondaryCustomTargetValueHigh',
    [31] = 'WorkoutIndex', --4
}

Garmin.ExerciseTitle = {
    GROUPS = { [0] = 'Garmin', [1] = 'ExerciseTitle', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ExerciseCategory', PrintConv = exerciseCategory, SeparateTable = 'ExerciseCategory' },
    [1] = 'ExerciseName',
    [2] = 'WktStepName', -- [N]
}

Garmin.Schedule = {
    GROUPS = { [0] = 'Garmin', [1] = 'Schedule', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [1] = 'Product',
    [2] = 'SerialNumber',
    [3] = timeInfo { Name = 'TimeCreated', Groups = { [2] = 'Time' } },
    [4] = 'Completed',
    [5] = { Name = 'ScheduleType', PrintConv = scheduleEnum },
    [6] = localTime { Name = 'ScheduledTime', Groups = { [2] = 'Time' } },
}

Garmin.Totals = {
    GROUPS = { [0] = 'Garmin', [1] = 'Totals', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimerTime', PrintConv = u('s') },
    [1] = { Name = 'Distance', PrintConv = u('m') },
    [2] = { Name = 'Calories', PrintConv = u('kcal') },
    [3] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [4] = { Name = 'ElapsedTime', PrintConv = u('s') },
    [5] = 'Sessions',
    [6] = { Name = 'ActiveTime', PrintConv = u('s') },
    [9] = 'SportIndex',
    [10] = 'ActivityProfile', --4
}

Garmin.WeightScale = {
    GROUPS = { [0] = 'Garmin', [1] = 'WeightScale', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Weight', ValueConv = d(100), PrintConv = u('kg') },
    [1] = { Name = 'PercentFat', ValueConv = d(100), PrintConv = u('%') },
    [2] = { Name = 'PercentHydration', ValueConv = d(100), PrintConv = u('%') },
    [3] = { Name = 'VisceralFatMass', ValueConv = d(100), PrintConv = u('kg') },
    [4] = { Name = 'BoneMass', ValueConv = d(100), PrintConv = u('kg') },
    [5] = { Name = 'MuscleMass', ValueConv = d(100), PrintConv = u('kg') },
    [7] = { Name = 'BasalMet', ValueConv = d(4), PrintConv = u('kcal/day') },
    [8] = 'PhysiqueRating',
    [9] = { Name = 'ActiveMet', ValueConv = d(4), PrintConv = u('kcal/day') },
    [10] = { Name = 'MetabolicAge', PrintConv = u('years') },
    [11] = 'VisceralFatRating',
    [12] = 'UserProfileIndex',
    [13] = { Name = 'Bmi', ValueConv = d(10), PrintConv = u('kg/m^2') },
}

Garmin.BloodPressure = {
    GROUPS = { [0] = 'Garmin', [1] = 'BloodPress', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'SystolicPressure', PrintConv = u('mmHg') },
    [1] = { Name = 'DiastolicPressure', PrintConv = u('mmHg') },
    [2] = { Name = 'MeanArterialPressure', PrintConv = u('mmHg') },
    [3] = { Name = 'Map_3SampleMean', PrintConv = u('mmHg') },
    [4] = { Name = 'MapMorningValues', PrintConv = u('mmHg') },
    [5] = { Name = 'MapEveningValues', PrintConv = u('mmHg') },
    [6] = { Name = 'HeartRate', PrintConv = u('bpm') },
    [7] = { Name = 'HeartRateType', PrintConv = hRType },
    [8] = { Name = 'Status', PrintConv = bpStatus },
    [9] = 'UserProfileIndex',
}

Garmin.MonitoringInfo = {
    GROUPS = { [0] = 'Garmin', [1] = 'MonitorInfo', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [1] = 'ActivityType', -- [N]
    [3] = 'CyclesToDistance', -- [N] / 5000 m/cycle
    [4] = 'CyclesToCalories', -- [N] / 5000 kcal/cycle
    [5] = { Name = 'RestingMetabolicRate', PrintConv = u('kcal / day') },
}

Garmin.Monitoring = {
    GROUPS = { [0] = 'Garmin', [1] = 'Monitoring', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'DeviceIndex',
    [1] = { Name = 'Calories', PrintConv = u('kcal') },
    [2] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [3] = { Name = 'Cycles', ValueConv = d(2), PrintConv = u('cycles') },
    [4] = { Name = 'ActiveTime', ValueConv = d(1000), PrintConv = u('s') },
    [5] = { Name = 'ActivityType', PrintConv = activityType, SeparateTable = 'ActivityType' },
    [6] = { Name = 'ActivitySubtype', PrintConv = activitySubtype },
    [7] = { Name = 'ActivityLevel', PrintConv = activityLevel },
    [8] = { Name = 'Distance_16', PrintConv = u('100 * m') },
    [9] = { Name = 'Cycles_16', PrintConv = u('2 * cycles (steps)') },
    [10] = { Name = 'ActiveTime_16', PrintConv = u('s') },
    [11] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [12] = { Name = 'Temperature', ValueConv = d(100), PrintConv = u('C') },
    [14] = { Name = 'TemperatureMin', ValueConv = d(100), PrintConv = u('C') },
    [15] = { Name = 'TemperatureMax', ValueConv = d(100), PrintConv = u('C') },
    [16] = 'ActivityTime', -- [8] minutes
    [19] = { Name = 'ActiveCalories', PrintConv = u('kcal') },
    [24] = 'CurrentActivityTypeIntensity',
    [25] = { Name = 'TimeStampMin_8', PrintConv = u('min') },
    [26] = { Name = 'TimeStamp_16', PrintConv = u('s') },
    [27] = { Name = 'HeartRate', PrintConv = u('bpm') },
    [28] = { Name = 'Intensity', ValueConv = d(10) },
    [29] = { Name = 'DurationMin', PrintConv = u('min') },
    [30] = { Name = 'Duration', PrintConv = u('s') },
    [31] = { Name = 'Ascent', ValueConv = d(1000), PrintConv = u('m') },
    [32] = { Name = 'Descent', ValueConv = d(1000), PrintConv = u('m') },
    [33] = { Name = 'ModerateActivityMinutes', PrintConv = u('minutes') },
    [34] = { Name = 'VigorousActivityMinutes', PrintConv = u('minutes') },
}

Garmin.MonitoringHRData = {
    GROUPS = { [0] = 'Garmin', [1] = 'MonitorHRData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'RestingHeartRate', PrintConv = u('bpm') },
    [1] = { Name = 'CurrentDayRestingHeartRate', PrintConv = u('bpm') },
}

Garmin.SPO2Data = {
    GROUPS = { [0] = 'Garmin', [1] = 'SPO2Data', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ReadingSPO2', ValueConv = d(1), PrintConv = u('%') },
    [1] = { Name = 'ReadingConfidence', ValueConv = d(1) },
    [2] = { Name = 'Mode', PrintConv = sPO2MeasurementType },
}

Garmin.HR = {
    GROUPS = { [0] = 'Garmin', [1] = 'HR', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'FractionalTimeStamp', ValueConv = d(32768), PrintConv = u('s') },
    [1] = { Name = 'Time256', ValueConv = d(256), PrintConv = u('s') },
    [6] = 'FilteredBpm', -- [N] bpm
    [9] = 'EventTimeStamp', -- [N] / 1024 s
    [10] = 'EventTimeStamp_12', -- [N] / 1024 s
}

Garmin.StressLevel = {
    GROUPS = { [0] = 'Garmin', [1] = 'StressLevel', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'StressLevelValue',
    [1] = timeInfo { Name = 'StressLevelTime', Groups = { [2] = 'Time' } },
    [3] = 'BodyBattery', --4
}

Garmin.MaxMetData = {
    GROUPS = { [0] = 'Garmin', [1] = 'MaxMetData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = timeInfo { Name = 'UpdateTime', Groups = { [2] = 'Time' } },
    [2] = { Name = 'VO2Max', ValueConv = d(10), PrintConv = u('mL/kg/min') },
    [5] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [6] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [8] = { Name = 'MaxMetCategory', PrintConv = maxMetCategory },
    [9] = 'CalibratedData',
    [12] = { Name = 'HRSource', PrintConv = maxMetHeartRateSource },
    [13] = { Name = 'SpeedSource', PrintConv = maxMetSpeedSource },
}

Garmin.HSABodyBatteryData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSABodyBattery', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'Level', -- [N] percent
    [2] = 'Charged', -- [N]
    [3] = 'Uncharged', -- [N]
}

Garmin.HSAEvent = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAEvent', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'EventID',
}

Garmin.HSAAccelerometerData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAAccelData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = { Name = 'SamplingInterval', PrintConv = u('ms') },
    [2] = 'AccelX', -- [N] / 1.024 mG
    [3] = 'AccelY', -- [N] / 1.024 mG
    [4] = 'AccelZ', -- [N] / 1.024 mG
    [5] = 'TimeStamp_32k',
}

Garmin.HSAGyroscopeData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAGyroData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = { Name = 'SamplingInterval', PrintConv = u('1/32768 s') },
    [2] = 'GyroX', -- [N] / 28.57143 deg/s
    [3] = 'GyroY', -- [N] / 28.57143 deg/s
    [4] = 'GyroZ', -- [N] / 28.57143 deg/s
    [5] = { Name = 'TimeStamp_32k', PrintConv = u('1/32768 s') },
}

Garmin.HSAStepData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAStepData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'Steps', -- [N] / 1 steps
}

Garmin.HSA_SPO2Data = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSA_SPO2Data', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'ReadingSPO2', -- [N] percent
    [2] = 'Confidence', -- [N]
}

Garmin.HSAStressData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAStressData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'StressLevel', -- [N] / 1 s
}

Garmin.HSARespirationData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSARespirData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'RespirationRate', -- [N] / 100 breaths/min
}

Garmin.HSAHeartRateData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSA_HRData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'Status',
    [2] = 'HeartRate', -- [N] / 1 bpm
}

Garmin.HSAConfigurationData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAConfigData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Data', -- [N]
    [1] = 'DataSize',
}

Garmin.HSAWristTemperatureData = {
    GROUPS = { [0] = 'Garmin', [1] = 'HSAWristTemp', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ProcessingInterval', PrintConv = u('s') },
    [1] = 'Value', -- [N] / 1000 degC
}

Garmin.MemoGlob = {
    GROUPS = { [0] = 'Garmin', [1] = 'MemoGlob', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Memo', -- [N]
    [1] = { Name = 'MesgNum', PrintConv = mesgNum, SeparateTable = 'MesgNum' },
    [2] = 'ParentIndex',
    [3] = 'FieldNum',
    [4] = 'Data', -- [N]
}

Garmin.SleepLevel = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepLevel', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'SleepLevel', PrintConv = sleepLevelEnum },
}

Garmin.AntChannelID = {
    GROUPS = { [0] = 'Garmin', [1] = 'AntChannelID', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ChannelNumber',
    [1] = 'DeviceType',
    [2] = 'DeviceNumber',
    [3] = 'TransmissionType',
    [4] = 'DeviceIndex',
}

Garmin.AntRx = {
    GROUPS = { [0] = 'Garmin', [1] = 'AntRx', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'FractionalTimeStamp', ValueConv = d(32768), PrintConv = u('s') },
    [1] = 'MesgID',
    [2] = 'MesgData', -- [N]
    [3] = 'ChannelNumber',
    [4] = 'Data', -- [N]
}

Garmin.AntTx = {
    GROUPS = { [0] = 'Garmin', [1] = 'AntTx', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'FractionalTimeStamp', ValueConv = d(32768), PrintConv = u('s') },
    [1] = 'MesgID',
    [2] = 'MesgData', -- [N]
    [3] = 'ChannelNumber',
    [4] = 'Data', -- [N]
}

Garmin.ExdScreenConfiguration = {
    GROUPS = { [0] = 'Garmin', [1] = 'ExdScreenConfig', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ScreenIndex',
    [1] = 'FieldCount',
    [2] = { Name = 'Layout', PrintConv = exdLayout },
    [3] = 'ScreenEnabled',
}

Garmin.ExdDataFieldConfiguration = {
    GROUPS = { [0] = 'Garmin', [1] = 'ExdDataFieldConfig', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ScreenIndex',
    [1] = 'ConceptField',
    [2] = 'FieldID',
    [3] = 'ConceptCount',
    [4] = { Name = 'DisplayType', PrintConv = exdDisplayType },
    [5] = 'Title', -- [32]
}

Garmin.ExdDataConceptConfiguration = {
    GROUPS = { [0] = 'Garmin', [1] = 'ExdDataConceptConfig', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'ScreenIndex',
    [1] = 'ConceptField',
    [2] = 'FieldID',
    [3] = 'ConceptIndex',
    [4] = 'DataPage',
    [5] = 'ConceptKey',
    [6] = 'Scaling',
    [8] = { Name = 'DataUnits', PrintConv = exdDataUnits, PrintConvColumns = 2 },
    [9] = { Name = 'Qualifier', PrintConv = exdQualifiers, PrintConvColumns = 2 },
    [10] = { Name = 'Descriptor', PrintConv = exdDescriptors, PrintConvColumns = 2 },
    [11] = 'IsSigned',
}

Garmin.DiveSummary = {
    GROUPS = { [0] = 'Garmin', [1] = 'DiveSummary', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ReferenceMesg', PrintConv = mesgNum, SeparateTable = 'MesgNum' },
    [1] = 'ReferenceIndex',
    [2] = { Name = 'AvgDepth', ValueConv = d(1000), PrintConv = u('m') },
    [3] = { Name = 'MaxDepth', ValueConv = d(1000), PrintConv = u('m') },
    [4] = { Name = 'SurfaceInterval', ValueConv = d(1), PrintConv = u('s') },
    [5] = { Name = 'StartCns', ValueConv = d(1), PrintConv = u('%') },
    [6] = { Name = 'EndCns', ValueConv = d(1), PrintConv = u('%') },
    [7] = { Name = 'StartN2', ValueConv = d(1), PrintConv = u('%') },
    [8] = { Name = 'EndN2', ValueConv = d(1), PrintConv = u('%') },
    [9] = { Name = 'O2Toxicity', PrintConv = u('OTUs') },
    [10] = 'DiveNumber',
    [11] = { Name = 'BottomTime', ValueConv = d(1000), PrintConv = u('s') },
    [12] = { Name = 'AvgPressureSac', ValueConv = d(100), PrintConv = u('bar/min') },
    [13] = { Name = 'AvgVolumeSac', ValueConv = d(100), PrintConv = u('L/min') },
    [14] = { Name = 'AvgRmv', ValueConv = d(100), PrintConv = u('L/min') },
    [15] = { Name = 'DescentTime', ValueConv = d(1000), PrintConv = u('s') },
    [16] = { Name = 'AscentTime', ValueConv = d(1000), PrintConv = u('s') },
    [17] = { Name = 'AvgAscentRate', ValueConv = d(1000), PrintConv = u('m/s') },
    [22] = { Name = 'AvgDescentRate', ValueConv = d(1000), PrintConv = u('m/s') },
    [23] = { Name = 'MaxAscentRate', ValueConv = d(1000), PrintConv = u('m/s') },
    [24] = { Name = 'MaxDescentRate', ValueConv = d(1000), PrintConv = u('m/s') },
    [25] = { Name = 'HangTime', ValueConv = d(1000), PrintConv = u('s') },
}

Garmin.AADAccelFeatures = {
    GROUPS = { [0] = 'Garmin', [1] = 'AADAccelFeatures', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Time', PrintConv = u('s') },
    [1] = 'EnergyTotal',
    [2] = 'ZeroCrossCnt',
    [3] = 'Instance',
    [4] = { Name = 'TimeAboveThreshold', ValueConv = d(25), PrintConv = u('s') },
}

Garmin.HRV = {
    GROUPS = { [0] = 'Garmin', [1] = 'HRV', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Time', -- [N] / 1000 s
}

Garmin.BeatIntervals = {
    GROUPS = { [0] = 'Garmin', [1] = 'BeatIntervals', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'Time', -- [N] ms
}

Garmin.HRVStatusSummary = {
    GROUPS = { [0] = 'Garmin', [1] = 'HRVStatusSummary', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'WeeklyAverage', ValueConv = d(128), PrintConv = u('ms') },
    [1] = { Name = 'LastNightAverage', ValueConv = d(128), PrintConv = u('ms') },
    [2] = { Name = 'LastNight_5MinHigh', ValueConv = d(128), PrintConv = u('ms') },
    [3] = { Name = 'BaselineLowUpper', ValueConv = d(128), PrintConv = u('ms') },
    [4] = { Name = 'BaselineBalancedLower', ValueConv = d(128), PrintConv = u('ms') },
    [5] = { Name = 'BaselineBalancedUpper', ValueConv = d(128), PrintConv = u('ms') },
    [6] = { Name = 'Status', PrintConv = hRVStatus },
}

Garmin.HRVValue = {
    GROUPS = { [0] = 'Garmin', [1] = 'HRVValue', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Value', ValueConv = d(128), PrintConv = u('ms') },
}

Garmin.RawBBI = {
    GROUPS = { [0] = 'Garmin', [1] = 'RawBBI', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'TimeStamp_ms', PrintConv = u('ms'), Groups = { [2] = 'Time' } },
    [1] = 'Data', -- [N]
    [2] = 'Time', -- [N] ms
    [3] = 'Quality', -- [N]
    [4] = 'Gap', -- [N]
}

Garmin.RespirationRate = {
    GROUPS = { [0] = 'Garmin', [1] = 'RespirationRate', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'RespirationRate', ValueConv = d(100), PrintConv = u('breaths/min') },
}

Garmin.ChronoShotSession = {
    GROUPS = { [0] = 'Garmin', [1] = 'ChronoShotSession', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'MinSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [1] = { Name = 'MaxSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [2] = { Name = 'AvgSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [3] = 'ShotCount',
    [4] = { Name = 'ProjectileType', PrintConv = projectileType },
    [5] = { Name = 'GrainWeight', ValueConv = d(10), PrintConv = u('gr') },
    [6] = { Name = 'StandardDeviation', ValueConv = d(1000), PrintConv = u('m/s') },
}

Garmin.ChronoShotData = {
    GROUPS = { [0] = 'Garmin', [1] = 'ChronoShotData', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'ShotSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [1] = 'ShotNum',
}

Garmin.TankUpdate = {
    GROUPS = { [0] = 'Garmin', [1] = 'TankUpdate', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Sensor',
    [1] = { Name = 'Pressure', ValueConv = d(100), PrintConv = u('bar') },
}

Garmin.TankSummary = {
    GROUPS = { [0] = 'Garmin', [1] = 'TankSummary', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Sensor',
    [1] = { Name = 'StartPressure', ValueConv = d(100), PrintConv = u('bar') },
    [2] = { Name = 'EndPressure', ValueConv = d(100), PrintConv = u('bar') },
    [3] = { Name = 'VolumeUsed', ValueConv = d(100), PrintConv = u('L') },
}

Garmin.SleepAssessment = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepAssessment', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'CombinedAwakeScore',
    [1] = 'AwakeTimeScore',
    [2] = 'AwakeningsCountScore',
    [3] = 'DeepSleepScore',
    [4] = 'SleepDurationScore',
    [5] = 'LightSleepScore',
    [6] = 'OverallSleepScore',
    [7] = 'SleepQualityScore',
    [8] = 'SleepRecoveryScore',
    [9] = 'RemSleepScore',
    [10] = 'SleepRestlessnessScore',
    [11] = 'AwakeningsCount',
    [14] = 'InterruptionsScore',
    [15] = { Name = 'AverageStressDuringSleep', ValueConv = d(100) },
}

Garmin.SleepDisruptionSeverityPeriod = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepDisruptPeriod', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Severity', PrintConv = sleepDisruptionSeverity, SeparateTable = 'SleepDisruptionSeverity' },
}

Garmin.SleepDisruptionOvernightSeverity = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepDisruptOvernight', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Severity', PrintConv = sleepDisruptionSeverity, SeparateTable = 'SleepDisruptionSeverity' },
}

Garmin.NapEvent = {
    GROUPS = { [0] = 'Garmin', [1] = 'NapEvent', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [1] = { Name = 'StartTimezoneOffset', PrintConv = u('minutes') },
    [2] = timeInfo { Name = 'EndTime', Groups = { [2] = 'Time' } },
    [3] = { Name = 'EndTimezoneOffset', PrintConv = u('minutes') },
    [4] = { Name = 'Feedback', PrintConv = napPeriodFeedback },
    [5] = 'IsDeleted',
    [6] = { Name = 'Source', PrintConv = napSource },
    [7] = timeInfo { Name = 'UpdateTimeStamp', Groups = { [2] = 'Time' } },
}

Garmin.SkinTempOvernight = {
    GROUPS = { [0] = 'Garmin', [1] = 'SkinTempOvernight', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [1] = 'AverageDeviation',
    [2] = 'Average_7DayDeviation',
    [4] = 'NightlyValue',
}

------------------------------------------------------------------------
-- None of the messages below appear in the offical Garmin documentation
-- (they were obtained from ref 4)
--
Garmin.DataScreen = {
    GROUPS = { [0] = 'Garmin', [1] = 'DataScreen', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [3] = 'NrFields',
    [7] = { Name = 'DataFields', PrintConv = dataFields, PrintConvColumns = 2 },
    [8] = 'Layout',
    [9] = 'Position',
    [10] = { Name = 'ScreenType', PrintConv = screenType },
}

Garmin.Alert = {
    GROUPS = { [0] = 'Garmin', [1] = 'Alert', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'Metric', PrintConv = alertMetric },
    [2] = 'Value',
    [3] = { Name = 'Status', PrintConv = switch, SeparateTable = 'Switch' },
    [4] = 'Message',
    [5] = { Name = 'Repeat', PrintConv = switch, SeparateTable = 'Switch' },
}

Garmin.RangeAlert = {
    GROUPS = { [0] = 'Garmin', [1] = 'RangeAlert', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'Metric', PrintConv = zoneMetric },
    [2] = { Name = 'LowStatus', PrintConv = alertZone, SeparateTable = 'AlertZone' },
    [3] = 'LowValue',
    [4] = { Name = 'HighStatus', PrintConv = alertZone, SeparateTable = 'AlertZone' },
    [5] = 'HighValue',
}

Garmin.DeviceUsed = {
    GROUPS = { [0] = 'Garmin', [1] = 'DeviceUsed', [2] = 'Device' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'DevSpeed',
    [1] = 'DevDistance',
    [2] = 'DevCadence',
    [3] = 'DevElevation',
    [4] = 'DevHeartRate',
    [6] = 'DevPower',
}

Garmin.Location = {
    GROUPS = { [0] = 'Garmin', [1] = 'Location', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'LocationName',
    [1] = latInfo { Name = 'GPSLatitude', Groups = { [2] = 'Location' }, Notes = 'position_lat' }, --4
    [2] = lonInfo { Name = 'GPSLongitude', Groups = { [2] = 'Location' }, Notes = 'position_long' }, --4
    [3] = { Name = 'LocationSymbol', PrintConv = mapSymbol, PrintConvColumns = 2 },
    [4] = altInfo { Name = 'GPSAltitude', Groups = { [2] = 'Location' }, Notes = 'altitude' },
    [5] = { Name = 'EnhancedAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [6] = 'LocationDescription',
}

Garmin.MapLayer = {
    GROUPS = { [0] = 'Garmin', [1] = 'MapLayer', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [2] = { Name = 'ReliefShading', PrintConv = reliefShading },
    [11] = { Name = 'Orientation', PrintConv = orientation },
    [13] = { Name = 'UserLocations', PrintConv = visibilityStatus, SeparateTable = 'VisibilityStatus' },
    [14] = { Name = 'AutoZoom', PrintConv = switch, SeparateTable = 'Switch' },
    [15] = { Name = 'GuideText', PrintConv = guideText },
    [16] = { Name = 'TrackLog', PrintConv = visibilityStatus, SeparateTable = 'VisibilityStatus' },
    [20] = { Name = 'Courses', PrintConv = courses },
    [23] = { Name = 'SpotSoundings', PrintConv = switch, SeparateTable = 'Switch' },
    [24] = { Name = 'LightSectors', PrintConv = lightSectorsStatus },
    [27] = { Name = 'Segments', PrintConv = visibilityStatus, SeparateTable = 'VisibilityStatus' },
    [28] = { Name = 'Contours', PrintConv = visibilityStatus, SeparateTable = 'VisibilityStatus' },
    [29] = 'SomeLabel',
    [31] = { Name = 'Popularity', PrintConv = switch, SeparateTable = 'Switch' },
}

Garmin.Routing = {
    GROUPS = { [0] = 'Garmin', [1] = 'Routing', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'RoutingMode', PrintConv = routingMode },
    [1] = { Name = 'CalculationMethod', PrintConv = calculationMethod },
    [2] = { Name = 'LockOnRoad', PrintConv = switch, SeparateTable = 'Switch' },
    [3] = { Name = 'Avoidances', PrintConv = avoidances },
    [4] = { Name = 'RouteRecalculation', PrintConv = routeRecalculation },
    [5] = { Name = 'RoutingType', PrintConv = routingType },
    [7] = { Name = 'CourseRecalculation', PrintConv = courseRecalculation },
}

Garmin.UserMetrics = {
    GROUPS = { [0] = 'Garmin', [1] = 'UserMetrics', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'VO2Max', ValueConv = d(292.5714286), PrintConv = u('ml/kg/min') },
    [1] = { Name = 'Age', PrintConv = u('yrs') },
    [2] = { Name = 'Height', ValueConv = d(100), PrintConv = u('m') },
    [3] = { Name = 'Weight', ValueConv = d(10), PrintConv = u('kg') },
    [4] = { Name = 'Gender', PrintConv = gender, SeparateTable = 'Gender' },
    [6] = { Name = 'MaxHR', PrintConv = u('bpm') },
    [8] = { Name = 'RemainingRecoveryTime', PrintConv = u('min') },
    [11] = { Name = 'Lthr', PrintConv = u('bpm') },
    [12] = { Name = 'Ltpower', PrintConv = u('watts') },
    [13] = { Name = 'Ltspeed', ValueConv = d(10), PrintConv = u('km/h') },
    [15] = 'BeginningBodyBattery',
    [16] = timeInfo { Name = 'StartOfActivity', Groups = { [2] = 'Time' } },
    [19] = { Name = 'FirstVO2Max', ValueConv = d(18724.57143), PrintConv = u('ml/kg/min') },
    [32] = 'BeginningPotential',
    [35] = timeInfo { Name = 'EndOfPreviousActivity', Groups = { [2] = 'Time' } },
    [39] = timeInfo { Name = 'WakeUpTime', Groups = { [2] = 'Time' } },
}

Garmin.DeviceStatus = {
    GROUPS = { [0] = 'Garmin', [1] = 'DeviceStatus', [2] = 'Device' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'BatteryVoltage', ValueConv = d(1000), PrintConv = u('V') },
    [2] = { Name = 'BatteryLevel', PrintConv = u('%') },
    [3] = { Name = 'Temperature', PrintConv = u('C') },
}

Garmin.BestEffort = {
    GROUPS = { [0] = 'Garmin', [1] = 'BestEffort', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [2] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [3] = { Name = 'Time', ValueConv = d(1000), PrintConv = u('s') },
    [4] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [5] = { Name = 'PersonalRecord', PrintConv = yesNo, SeparateTable = 'YesNo' },
}

Garmin.PersonalRecord = {
    GROUPS = { [0] = 'Garmin', [1] = 'PersonalRecord', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Metric', PrintConv = recordMetric },
    [1] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [2] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [5] = 'Record',
}

Garmin.ActivityMetrics = {
    GROUPS = { [0] = 'Garmin', [1] = 'ActivityMetrics', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'NewHRMax',
    [4] = { Name = 'AerobicTrainingEffect', ValueConv = d(10) },
    [7] = { Name = 'VO2Max', ValueConv = d(18724.57143), PrintConv = u('ml/kg/min') },
    [9] = { Name = 'RecoveryTime', PrintConv = u('min') },
    [11] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [14] = { Name = 'Lthr', PrintConv = u('bpm') },
    [15] = { Name = 'Ltpower', PrintConv = u('watts') },
    [16] = { Name = 'Ltspeed', ValueConv = d(10), PrintConv = u('km/h') },
    [17] = 'EndingPerformanceCondition',
    [20] = { Name = 'AnaerobicTrainingEffect', ValueConv = d(10) },
    [25] = 'EndingBodyBattery',
    [29] = { Name = 'FirstVO2Max', ValueConv = d(18724.57143), PrintConv = u('ml/kg/min') },
    [41] = { Name = 'PrimaryBenefit', PrintConv = benefit, SeparateTable = 'Benefit' },
    [48] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [50] = 'EndingPotential',
    [60] = { Name = 'TotalAscent', PrintConv = u('m') },
    [61] = { Name = 'TotalDescent', PrintConv = u('m') },
    [62] = { Name = 'AveragePower', PrintConv = u('watts') },
    [63] = { Name = 'AverageHeartRate', PrintConv = u('bpm') },
}

Garmin.MultisportSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'MultisportSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'MultisportSettingsName',
    [1] = { Name = 'Transitions', PrintConv = switch, SeparateTable = 'Switch' },
    [2] = 'NumberOfActivities',
    [3] = { Name = 'AutoPause', PrintConv = allow, SeparateTable = 'Allow' },
    [4] = { Name = 'Alerts', PrintConv = allow, SeparateTable = 'Allow' },
    [5] = { Name = 'AutoLap', PrintConv = allow, SeparateTable = 'Allow' },
    [6] = { Name = 'PowerSaveTimeout', PrintConv = powerSaveTimeout },
    [7] = { Name = 'AutoScroll', PrintConv = allow, SeparateTable = 'Allow' },
    [8] = { Name = 'Repeat', PrintConv = switch, SeparateTable = 'Switch' },
    [10] = { Name = 'SportChange', PrintConv = sportChange },
}

Garmin.MultisportActivity = {
    GROUPS = { [0] = 'Garmin', [1] = 'MultisportActivity', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [1] = { Name = 'SubSport', PrintConv = subSport, SeparateTable = 'SubSport' },
    [2] = { Name = 'LockDevice', PrintConv = switch, SeparateTable = 'Switch' },
    [3] = 'MultisportActivityName',
}

Garmin.SensorSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'SensorSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'AntID',
    [2] = 'SensorSettingsName',
    [10] = { Name = 'WheelSizeManual', PrintConv = u('mm') },
    [11] = { Name = 'CalibrationFactor', ValueConv = d(10) },
    [21] = { Name = 'WheelSizeAuto', PrintConv = u('mm') },
    [32] = 'Product',
    [33] = { Name = 'Manufacturer', PrintConv = manufacturer, SeparateTable = 'Manufacturer' },
    [45] = { Name = 'UseForSpeed', PrintConv = useStatus, SeparateTable = 'UseStatus' },
    [46] = { Name = 'UseForDistance', PrintConv = useStatus, SeparateTable = 'UseStatus' },
    [51] = { Name = 'ConnectionType', PrintConv = connectionType },
    [52] = { Name = 'SensorType', PrintConv = sensorType, SeparateTable = 'SensorType' },
    [91] = 'ProductName',
}

Garmin.Metronome = {
    GROUPS = { [0] = 'Garmin', [1] = 'Metronome', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Enabled', PrintConv = switch, SeparateTable = 'Switch' },
    [1] = { Name = 'BeatsPerMinute', PrintConv = u('bpm') },
    [2] = 'AlertFrequency',
    [3] = { Name = 'SoundAndVibe', PrintConv = soundAndVibe, SeparateTable = 'SoundAndVibe' },
}

Garmin.ConnectIQField = {
    GROUPS = { [0] = 'Garmin', [1] = 'ConnectIQField', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'AppID', -- [N]
    [2] = 'DataField',
    [100] = 'ScreenID',
    [101] = 'FieldBits',
}

Garmin.Clubs = {
    GROUPS = { [0] = 'Garmin', [1] = 'Clubs', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [6] = { Name = 'AverageDistance', ValueConv = d(100), PrintConv = u('m') },
    [19] = { Name = 'MaxDistance', ValueConv = d(100), PrintConv = u('m') },
}

Garmin.WaypointHandling = {
    GROUPS = { [0] = 'Garmin', [1] = 'WaypointHandling', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Action', PrintConv = waypointAction },
}

Garmin.GolfCourse = {
    GROUPS = { [0] = 'Garmin', [1] = 'GolfCourse', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'CourseID',
    [1] = 'GolfCourseName',
    [2] = localTime { Name = 'LocalTime', Groups = { [2] = 'Time' } },
    [3] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [4] = timeInfo { Name = 'EndTime', Groups = { [2] = 'Time' } },
    [8] = 'Out',
    [9] = 'In',
    [10] = 'Total',
    [11] = 'Tee',
    [12] = 'Slope',
    [21] = 'Rating',
}

Garmin.GolfStats = {
    GROUPS = { [0] = 'Garmin', [1] = 'GolfStats', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'GolfStatsName',
    [2] = 'Out',
    [3] = 'In',
    [4] = 'Total',
    [7] = 'FairwayHit',
    [8] = 'Gir',
    [9] = 'Putts',
}

Garmin.Score = {
    GROUPS = { [0] = 'Garmin', [1] = 'Score', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'HoleNumber',
    [2] = 'Score',
    [5] = 'Putts',
    [6] = { Name = 'Fairway', PrintConv = fairway },
}

Garmin.Hole = {
    GROUPS = { [0] = 'Garmin', [1] = 'Hole', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'HoleNumber',
    [1] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [2] = 'Par',
    [3] = 'Handicap',
    [4] = latInfo { Name = 'PositionLat', Groups = { [2] = 'Location' } }, -- position_lat
    [5] = lonInfo { Name = 'PositionLong', Groups = { [2] = 'Location' } }, -- position_long
}

Garmin.Shot = {
    GROUPS = { [0] = 'Garmin', [1] = 'Shot', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'HoleNumber',
    [2] = latInfo { Name = 'StartPositionLat', Groups = { [2] = 'Location' } }, -- start_position_lat
    [3] = lonInfo { Name = 'StartPositionLong', Groups = { [2] = 'Location' } }, -- start_position_long
    [4] = latInfo { Name = 'EndPositionLat', Groups = { [2] = 'Location' } }, -- end_position_lat
    [5] = lonInfo { Name = 'EndPositionLong', Groups = { [2] = 'Location' } }, -- end_position_long
    [7] = 'ClubType',
}

Garmin.AlarmSettings = {
    GROUPS = { [0] = 'Garmin', [1] = 'AlarmSettings', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Time', PrintConv = u('min') },
    [1] = { Name = 'Repeat', PrintConv = alarmRepeat },
    [2] = { Name = 'Enabled', PrintConv = switch, SeparateTable = 'Switch' },
    [3] = { Name = 'Sound', PrintConv = soundAndVibe, SeparateTable = 'SoundAndVibe' },
    [4] = { Name = 'Backlight', PrintConv = switch, SeparateTable = 'Switch' },
    [5] = timeInfo { Name = 'TimeCreated', Groups = { [2] = 'Time' } },
    [8] = { Name = 'Label', PrintConv = alarmLabel },
    [11] = timeInfo { Name = 'TimeUpdated', Groups = { [2] = 'Time' } },
}

Garmin.MusicInfo = {
    GROUPS = { [0] = 'Garmin', [1] = 'MusicInfo', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [2] = 'Title',
    [3] = 'Artist',
    [4] = 'Genre',
    [5] = { Name = 'Duration', PrintConv = u('s') },
}

Garmin.SleepDataInfo = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepDataInfo', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'SampleLength', PrintConv = u('s') },
    [2] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [4] = 'Version',
}

Garmin.MtbCx = {
    GROUPS = { [0] = 'Garmin', [1] = 'MtbCx', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = { Name = 'GritFlowJumpRecording', PrintConv = switch, SeparateTable = 'Switch' },
    [2] = { Name = 'JumpAlerts', PrintConv = switch, SeparateTable = 'Switch' },
}

Garmin.Race = {
    GROUPS = { [0] = 'Garmin', [1] = 'Race', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [3] = { Name = 'GoalTime', ValueConv = d(1000), PrintConv = u('s') },
    [4] = { Name = 'GoalSpeed', ValueConv = d(1000), PrintConv = u('m/s') },
    [5] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [7] = { Name = 'SplitDistance', ValueConv = d(100), PrintConv = u('m') },
}

Garmin.SplitTime = {
    GROUPS = { [0] = 'Garmin', [1] = 'SplitTime', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Time', ValueConv = d(1000), PrintConv = u('s') },
    [1] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [2] = { Name = 'SplitTime', ValueConv = d(1000), PrintConv = u('s') },
    [3] = { Name = 'SplitDistance', ValueConv = d(100), PrintConv = u('m') },
    [4] = { Name = 'SplitSpeeds', ValueConv = d(1000), PrintConv = u('m/s') },
    [9] = latInfo { Name = 'StartPositionLat', Groups = { [2] = 'Location' } }, -- start_position_lat
    [10] = lonInfo { Name = 'StartPositionLong', Groups = { [2] = 'Location' } }, -- start_position_long
    [11] = latInfo { Name = 'EndPositionLat', Groups = { [2] = 'Location' } }, -- end_position_lat
    [12] = lonInfo { Name = 'EndPositionLong', Groups = { [2] = 'Location' } }, -- end_position_long
    [13] = { Name = 'StartAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
    [14] = { Name = 'EndAltitude', ValueConv = function(_self, val) return val / 5 - 500 end, PrintConv = u('m') },
}

Garmin.PowerMode = {
    GROUPS = { [0] = 'Garmin', [1] = 'PowerMode', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'LowBatteryAlert', PrintConv = u('s') },
    [1] = 'DefaultMode',
    [3] = { Name = 'AutoEnableTime', PrintConv = u('s') },
}

Garmin.GPSEvent = {
    GROUPS = { [0] = 'Garmin', [1] = 'GPSEvent', [2] = 'Location' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'EventType', PrintConv = gPSType },
    [1] = 'Data',
    [100] = { Name = 'GPS_1', PrintConv = switch, SeparateTable = 'Switch' },
    [101] = { Name = 'Glonass', PrintConv = switch, SeparateTable = 'Switch' },
    [102] = 'Unknown_1',
    [104] = { Name = 'Qzss_1', PrintConv = switch, SeparateTable = 'Switch' },
    [105] = 'Unknown_2',
    [106] = { Name = 'Galileo_1', PrintConv = switch, SeparateTable = 'Switch' },
    [107] = { Name = 'Beidou_1', PrintConv = switch, SeparateTable = 'Switch' },
    [108] = { Name = 'AutoSelect', PrintConv = switch, SeparateTable = 'Switch' },
    [109] = 'Unknown_3',
    [110] = 'GPSgalileobeidou_5',
    [113] = { Name = 'Qzss_5', PrintConv = switch, SeparateTable = 'Switch' },
}

Garmin.FunctionalMetrics = {
    GROUPS = { [0] = 'Garmin', [1] = 'FunctionalMetrics', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [4] = { Name = 'FunctionalThresholdPower', PrintConv = u('watts') },
    [7] = { Name = 'RunningLactateThresholdPower', PrintConv = u('watts') },
    [8] = { Name = 'RunningLactateThresholdHR', PrintConv = u('bpm') },
    [9] = { Name = 'CyclingLactaceThresholdHR', PrintConv = u('bpm') },
}

Garmin.RaceEvent = {
    GROUPS = { [0] = 'Garmin', [1] = 'RaceEvent', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'EventID',
    [2] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [3] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [4] = 'RaceEventName',
    [5] = 'Location',
    [6] = latInfo { Name = 'StartPointLat', Groups = { [2] = 'Location' } }, -- start_point_lat
    [7] = lonInfo { Name = 'StartPointLong', Groups = { [2] = 'Location' } }, -- start_point_long
    [10] = { Name = 'Distance', ValueConv = d(100), PrintConv = u('m') },
    [12] = { Name = 'TargetTime', ValueConv = d(1000), PrintConv = u('s') },
    [24] = 'City',
    [26] = 'Country',
}

Garmin.TrainingReadiness = {
    GROUPS = { [0] = 'Garmin', [1] = 'TrainingReadiness', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'TrainingReadiness',
    [1] = { Name = 'Level', PrintConv = trainingReadinessLevel },
    [20] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
}

Garmin.TrainingLoad = {
    GROUPS = { [0] = 'Garmin', [1] = 'TrainingLoad', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [3] = 'AcuteTrainingLoad',
    [4] = 'ChronicTrainingLoad',
}

Garmin.SleepSchedule = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepSchedule', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'BedTime', PrintConv = u('s') },
    [1] = { Name = 'WakeTime', PrintConv = u('s') },
}

Garmin.SleepRestlessMoments = {
    GROUPS = { [0] = 'Garmin', [1] = 'SleepRestlessMoments', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'RestlessMomentsCount',
    [2] = { Name = 'Durations', PrintConv = u('s') },
}

Garmin.WorkoutSchedule = {
    GROUPS = { [0] = 'Garmin', [1] = 'WorkoutSchedule', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [1] = 'WorkoutIndex',
    [3] = { Name = 'EstBenefit', PrintConv = benefit, SeparateTable = 'Benefit' },
    [5] = { Name = 'EstAerobicTe', ValueConv = d(10) },
    [6] = { Name = 'EstAnaerTe', ValueConv = d(10) },
    [7] = { Name = 'Sport', PrintConv = sportEnum, SeparateTable = 'SportEnum' },
    [9] = { Name = 'Duration', ValueConv = d(1000), PrintConv = u('s') },
}

Garmin.EPOStatus = {
    GROUPS = { [0] = 'Garmin', [1] = 'EPOStatus', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Status', PrintConv = ePOCPEStatus, SeparateTable = 'EPOCPEStatus' },
    [1] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [2] = timeInfo { Name = 'EndTime', Groups = { [2] = 'Time' } },
}

Garmin.OpenWaterEvent = {
    GROUPS = { [0] = 'Garmin', [1] = 'OpenWaterEvent', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'EventType', PrintConv = openWaterEventType },
    [5] = { Name = 'SwimStroke', PrintConv = swimStroke, SeparateTable = 'SwimStroke' },
}

Garmin.ECGSummary = {
    GROUPS = { [0] = 'Garmin', [1] = 'ECGSummary', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [2] = 'RawSampleRate',
    [3] = 'SmoothSampleRate',
    [4] = timeInfo { Name = 'ECGTimeStamp', Groups = { [2] = 'Time' } },
    [5] = localTime { Name = 'LocalTimeStamp', Groups = { [2] = 'Time' } },
    [7] = { Name = 'AverageHeartRate', PrintConv = u('bpm') },
    [11] = { Name = 'SampleTime', PrintConv = u('s') },
    [12] = { Name = 'SDRRHRV', PrintConv = u('ms') },
}

Garmin.ECGRawSample = {
    GROUPS = { [0] = 'Garmin', [1] = 'ECGRawSample', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Value',
}

Garmin.ECGSmoothSample = {
    GROUPS = { [0] = 'Garmin', [1] = 'ECGSmoothSample', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'Value',
}

Garmin.CPEStatus = {
    GROUPS = { [0] = 'Garmin', [1] = 'CPEStatus', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = { Name = 'Status', PrintConv = ePOCPEStatus, SeparateTable = 'EPOCPEStatus' },
    [1] = timeInfo { Name = 'StartTime', Groups = { [2] = 'Time' } },
    [2] = timeInfo { Name = 'EndTime', Groups = { [2] = 'Time' } },
}

Garmin.HillScore = {
    GROUPS = { [0] = 'Garmin', [1] = 'HillScore', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'HillScore',
    [1] = 'HillStrength',
    [2] = 'HillEndurance',
    [4] = { Name = 'Level', PrintConv = hillScoreLevel },
}

Garmin.EnduranceScore = {
    GROUPS = { [0] = 'Garmin', [1] = 'EnduranceScore', [2] = 'Other' },
    VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
    [0] = 'EnduranceScore',
    [1] = { Name = 'Level', PrintConv = enduranceScoreLevel },
    [3] = 'LowerBoundIntermediate',
    [4] = 'LowerBoundTrained',
    [5] = 'LowerBoundWellTrained',
    [6] = 'LowerBoundExpert',
    [7] = 'LowerBoundSuperior',
    [8] = 'LowerBoundElite',
}

------------------------------------------------------------------------------
-- set Unknown flag for all unsupported FIT messages
for _, k in ipairs(ExifTool.TagTableKeys(Garmin.FIT)) do
    if type(Garmin.FIT[k]) ~= 'table' then
        Garmin.FIT[k] = {
            Name = Garmin.FIT[k],
            Unknown = 1,
        }
    end
end

--------------------------------------------------------------------------------
-- Calculate CRC for each byte
-- Inputs: 0) running CRC, 1) byte value
-- Returns: updated CRC
-- - unused here, but included in case it may be helpful later
local crc_table = {
    0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401,
    0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400
}
function Garmin.CRC(crc, byte)
    local tmp
    -- compute checksum of lower four bits of byte
    tmp = crc_table[(crc & 0xf) + 1]
    crc = (crc >> 4) & 0x0fff
    crc = crc ~ tmp ~ crc_table[(byte & 0xf) + 1]
    -- now compute checksum of upper four bits of byte
    tmp = crc_table[(crc & 0xf) + 1]
    crc = (crc >> 4) & 0x0fff
    crc = crc ~ tmp ~ crc_table[((byte >> 4) & 0xf) + 1]
    return crc
end

--------------------------------------------------------------------------------
-- Read Garmin FIT file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Return: true on success
function Garmin.ProcessFIT(et, dirInfo)
    local raf = dirInfo.RAF
    local unknown = et.OPTIONS.Unknown
    local verbose = et.OPTIONS.Verbose
    local ee = et.OPTIONS.ExtractEmbedded
    if not perl.truthy(unknown) and perl.truthy(verbose) then unknown = 1 end

    -- verify this is a valid Garmin FIT file
    local n0, buff = raf:Read(12)
    if n0 ~= 12 or buff:sub(9, 12) ~= '.FIT' then return 0 end
    et:SetFileType()
    local tagTbl = et:GetTagTable('lexiftool.Garmin.FIT')
    local common = et:GetTagTable('lexiftool.Garmin.Common')
    local devTbl = et:GetTagTable('lexiftool.Garmin.Dev')
    -- clear out old developer tags
    for k in pairs(devTbl) do
        if not ExifTool.specialTags[k] and k ~= '_SETUP' then devTbl[k] = nil end
    end
    -- (extra parens truncate Get8u's (value, nextPos) return pair to the
    -- value alone -- spliced inline as the last call argument the position
    -- would land in HandleTag's parms slot)
    et:HandleTag(tagTbl, 'vers', (ExifTool.Get8u(buff, 1)))
    if not perl.truthy(ee) then et:Warn('Use ExtractEmbedded option to extract all timed metadata', 3) end
    local hdrLen, dataLen = perl.unpack('Cx3V', buff)
    if hdrLen > 12 then raf:Read(hdrLen - 12) end
    local timestamp = 0
    local msg = {} -- per-local-message-number definition/state
    local done = {} -- (non-ExtractEmbedded) message numbers already extracted once
    local devData = {} -- developer field descriptors, keyed by developer data index
    local err

    while true do
        local msgStart = raf:Tell()
        if msgStart >= hdrLen + dataLen then break end
        local n1, b1 = raf:Read(1)
        if n1 ~= 1 then break end
        local flags = b1:byte(1)
        local localNum
        if flags & 0x80 ~= 0 then -- compressed header
            localNum = (flags >> 5) & 0x03
            -- update current timestamp
            local timeOffset = flags & 0x1f
            if timeOffset ~= 0 then
                -- the FIT specification is stupid here. The offset should have
                -- been defined as a simple difference from the previous timestamp
                -- instead of the lower 5 bits with a wrap-around.  Dumb.  All the
                -- resulting bit gymnastics are totally unnecessary:
                local lowBits = timestamp & 0x1f
                local ts = (timestamp & 0xffffffe0) + timeOffset
                if timeOffset < lowBits then ts = ts + 0x20 end
                msg[localNum] = msg[localNum] or {}
                msg[localNum].TS = { Num = 253, NewTimestamp = ts } -- [num, new timestamp]
            end
        else -- normal header
            localNum = flags & 0x0f
            if flags & 0x40 ~= 0 then
                --
                -- Process the definition message
                --
                local n5, b5 = raf:Read(5)
                if n5 ~= 5 then
                    if raf:Tell() ~= hdrLen + dataLen + 2 then -- (+2 for checksum)
                        err = 'Unexpected end of file'
                    end
                    break
                end
                ExifTool.SetByteOrder(ExifTool.Get8u(b5, 1) ~= 0 and 'MM' or 'II')
                local msgNum = ExifTool.Get16u(b5, 2)
                local nFields = ExifTool.Get8u(b5, 4)
                local len = nFields * 3
                local theMsg = {} -- start new message definition
                msg[localNum] = theMsg
                theMsg.ByteOrder = ExifTool.GetByteOrder()
                theMsg.MessageNum = msgNum
                local tagInfo = tagTbl[msgNum]
                local msgName
                if tagInfo then
                    msgName = tagInfo.Name
                    theMsg.Name = msgName
                else
                    msgName = 'Unknown' .. msgNum
                    theMsg.Name = msgName
                    tagInfo = { Name = msgName, Unknown = 1 }
                    et:AddTagToTable(tagTbl, msgNum, tagInfo)
                end
                if not tagInfo.SubDirectory then
                    -- construct table for this subdirectory
                    Garmin[msgName] = {
                        GROUPS = { [0] = 'Garmin', [1] = msgName, [2] = 'Unknown' },
                        VARS = { ID_FMT = 'dec', NO_LOOKUP = 1 },
                    }
                    tagInfo.SubDirectory = { TagTable = 'lexiftool.Garmin.' .. msgName }
                end
                local subTbl = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                et:VPrint(1, '  + [' .. msgName .. ' definition message (local ' .. str(localNum) .. ')]')
                local n6, b6 = raf:Read(len)
                if n6 ~= len then err = 'Truncated definition message'; break end
                local totSize = 0
                local fieldInfo
                if not (tagInfo.Unknown and not perl.truthy(unknown)) then
                    fieldInfo = {}
                    theMsg.FieldInfo = fieldInfo
                end
                -- loop through the message field definitions
                local pos = 0
                while pos < len do
                    local num, size, type_ = b6:byte(pos + 1), b6:byte(pos + 2), b6:byte(pos + 3)
                    if baseType[type_] then
                        -- remember offset of timestamp if this message has one
                        if num == 253 or (type(subTbl[num]) == 'table' and not theMsg.TS and subTbl[num].IsTimeStamp) then
                            theMsg.TS = { Num = num, Size = size, Type = type_, Pos = totSize }
                        end
                        -- save field definitions for fields we care about
                        if fieldInfo then fieldInfo[#fieldInfo + 1] = { num, size, type_ } end
                    else
                        et:Warn('Unknown field type ' .. str(type_))
                    end
                    totSize = totSize + size
                    pos = pos + 3
                end
                local nDev
                if flags & 0x20 ~= 0 then -- developer data flag
                    local n7, b7 = raf:Read(1)
                    if n7 ~= 1 then err = 'Missing developer definition'; break end
                    nDev = b7:byte(1)
                    len = nDev * 3
                    local n8, b8 = raf:Read(len)
                    if n8 ~= len then err = 'Truncated developer definition'; break end
                    -- loop through the developer fields
                    for i = 0, nDev - 1 do
                        local p = i * 3
                        local num, size, idx = b8:byte(p + 1), b8:byte(p + 2), b8:byte(p + 3)
                        -- fieldInfo[4] is flag for developer field
                        if fieldInfo then fieldInfo[#fieldInfo + 1] = { num, size, idx, 1 } end
                        totSize = totSize + size
                    end
                end
                theMsg.Size = totSize
                if perl.num(verbose) > 2 then
                    local n = raf:Tell() - msgStart
                    local nr, b9
                    if raf:Seek(-n, 1) then nr, b9 = raf:Read(n) end
                    if nr ~= n then err = 'Seek error'; break end
                    local nDev2 = n - 6 - 3 * nFields
                    if nDev2 ~= 0 then nDev2 = (nDev2 - 1) / 3 end
                    et:VPrint(1, '    (' .. str(nFields) .. ' data + ' .. str(nDev2) .. ' developer fields)')
                    et:VerboseDump(b9, { DataPos = raf:Tell() - n })
                end
                goto continue
            end
        end
        --
        -- Process the data message
        --
        do
            local theMsg = msg[localNum]
            if not theMsg then err = 'Missing definition for local message ' .. str(localNum); break end
            local dataPos = raf:Tell()
            local msgSize = theMsg.Size
            local msgNum = theMsg.MessageNum
            ExifTool.SetByteOrder(theMsg.ByteOrder)
            if not perl.truthy(ee) then
                if done[msgNum] then
                    if not raf:Seek(msgSize, 1) then err = 'Seek error'; break end
                    goto continue
                else
                    done[msgNum] = true
                end
            end
            local n9, buff2 = raf:Read(msgSize)
            if n9 ~= msgSize then err = 'Truncated data message'; break end
            local fieldInfo = theMsg.FieldInfo
            local msgName = theMsg.Name
            local tagInfo = tagTbl[msgNum]
            local subTbl = et:GetTagTable(tagInfo.SubDirectory.TagTable)
            local oldIndent = et.INDENT
            et.INDENT = et.INDENT .. '| '
            local comp = (flags & 0x80) ~= 0 and 'compressed header, ' or ''
            et:VerboseDir(tagInfo.Name, nil, '(local ' .. str(localNum) .. ') ' .. comp .. str(msgSize))
            if perl.num(verbose) > 2 then
                local tmp = string.char(flags) .. buff2
                et:VerboseDump(tmp, { DataPos = raf:Tell() - msgSize - 1 })
            end
            local ts = theMsg.TS
            if ts and ts.Num == 253 then
                local val
                if ts.Type then
                    val = ExifTool.ReadValue(buff2, ts.Pos, baseType[ts.Type][1], 1, ts.Size)
                else
                    val = ts.NewTimestamp
                end
                if timestamp ~= val then
                    timestamp = val
                    -- increment document number for GPS data or any message with a new timestamp
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    if not (fieldInfo and ts.Type) then
                        local parms
                        if ts.Type then
                            parms = {
                                DataPt = buff2,
                                DataPos = dataPos,
                                Start = ts.Pos,
                                Size = ts.Size,
                                Format = baseType[ts.Type][1] .. ' "' .. baseType[ts.Type][2] .. '"',
                            }
                        end
                        -- set group 1 to message name
                        et.SET_GROUP1 = subTbl.GROUPS[1]
                        et:HandleTag(common, ts.Num, val, parms)
                        et.SET_GROUP1 = nil
                    end
                end
            end
            -- ignore this message unless it contains something else we care about
            if not fieldInfo then et.INDENT = oldIndent goto continue end
            local i, pos = 0, 0
            local fieldValue = {}
            for _, field in ipairs(fieldInfo) do
                local num, size, type_ = field[1], field[2], field[3]
                local tbl
                if not field[4] then -- standard field
                    tbl = subTbl
                    if not tbl[num] then
                        if common[num] then
                            tbl = common
                            et.SET_GROUP1 = subTbl.GROUPS[1]
                        else
                            et:AddTagToTable(tbl, num, { Name = msgName .. '_' .. num, Unknown = 1 })
                        end
                    end
                else -- developer field
                    --
                    -- Example layout of developer messages:
                    --
                    -- DevData: app=A idx=0
                    -- DevData: app=B idx=1
                    -- FieldDescr: idx=0 (app A) num=0 type=uint8  name="speed" units="km/h"
                    -- FieldDescr: idx=1 (app B) num=0 type=uint16 name="elev" units="m"
                    -- FieldDescr: idx=1 (app B) num=1 type=string name="model" units=""
                    -- Message XX definition:
                    --   Fields (2)
                    --     num=0 size=2 type=uint16 (for example)
                    --     num=1 size=4 type=uint32 (for example)
                    --   DevFields (2)
                    --     num=0 size=1 idx=0 (app A speed)
                    --     num=0 size=2 idx=1 (app B elev)
                    --     num=1 size=5 idx=1 (app B model)
                    -- Message XX data:
                    --     uint16 uint32 unit8(speed) uint16(elev) "A380\0"(model)
                    --
                    tbl = devTbl
                    local idx = type_
                    local dev = devData[idx]
                    if dev and dev[num] and dev[num][2] ~= nil and dev[num][3] ~= nil and dev.ID and dev.ID[1] ~= nil then
                        local id = (perl.unpack('H*', dev.ID[1])) .. '_' .. str(dev[num][1])
                        if not tbl[id] then
                            local name = str(dev[num][3])
                            name = name:gsub('_([a-z])', function(c) return uc(c) end)
                            name = ExifTool.MakeTagName(name)
                            local newTagInfo = { Name = name }
                            local units = dev[num][8]
                            if units and units ~= '' then
                                units = units:gsub('[^%-_a-zA-Z0-9/+*]', '')
                                newTagInfo.PrintConv = u(units)
                            end
                            et:AddTagToTable(tbl, id, newTagInfo)
                        end
                        type_ = dev[num][2]
                        num = id
                    else
                        if perl.truthy(unknown) then et:Warn('Incomplete developer field definition') end
                        pos = pos + size
                        goto continueField
                    end
                end
                if baseType[type_] then
                    local fmt = baseType[type_][1]
                    local fmtSize = ExifTool.FormatSize(fmt) or 1
                    local count = size / fmtSize
                    if count == math.floor(count) then
                        local val = ExifTool.ReadValue(buff2, pos, fmt, count, size)
                        -- ignore invalid values
                        -- (NAN may be 'NaN' or 'nan' on different systems, so lowercasing is
                        -- required; a Lua number NaN additionally prints as '-nan' when the
                        -- sign bit is set (FIT's all-ones 0xffffffff pattern), so numbers
                        -- are NaN-tested via self-inequality instead of stringified)
                        local invalid = baseType[type_][3]
                        local isInvalid
                        if type(val) == 'number' and val ~= val then
                            isInvalid = lc(invalid) == 'nan'
                        else
                            isInvalid = lc(val) == lc(invalid)
                        end
                        if not isInvalid then
                            if not field[4] then fieldValue[num] = val end
                            local fmtStr = fmt .. ' "' .. baseType[type_][2] .. '"'
                            if field[4] then fmtStr = fmtStr .. ', devIdx=' .. str(field[3]) end
                            et:HandleTag(tbl, num, fmt == 'undef' and { ref = 'SCALAR', value = val } or val, {
                                DataPt = buff2,
                                DataPos = dataPos,
                                Start = pos,
                                Size = size,
                                Index = i,
                                Format = fmtStr,
                            })
                            i = i + 1
                        end
                    else
                        et:Warn('Bad count for ' .. fmt .. ' ' .. msgName .. ' field ' .. str(num))
                    end
                else
                    et:Warn('Unknown field type ' .. str(type_))
                end
                et.SET_GROUP1 = nil
                pos = pos + size
                ::continueField::
            end
            et.INDENT = oldIndent
            -- save messages required to decode developer fields
            if msgNum == 207 then -- DeveloperDataID
                local idx = fieldValue[3] -- DeveloperDataIndex
                if idx ~= nil then
                    devData[idx] = devData[idx] or {}
                    devData[idx].ID = fieldValue
                end
            elseif msgNum == 206 then -- FieldDescription
                local idx = fieldValue[0] -- DeveloperDataIndex
                local fnum = fieldValue[1]
                if idx ~= nil and fnum ~= nil then
                    devData[idx] = devData[idx] or {}
                    devData[idx][fnum] = fieldValue
                end
            end
        end
        ::continue::
    end
    if err then et:Warn(err) end
    et.DOC_NUM = nil
    return 1
end

return Garmin
