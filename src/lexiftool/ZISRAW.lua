--------------------------------------------------------------------------------
-- File:         lexiftool/ZISRAW.lua
-- Ported from:  lib/Image/ExifTool/ZISRAW.pm
--
-- Description:  Read ZISRAW (CZI) meta information
--
-- Revisions:    2020-08-07 - P. Harvey Created
--
-- References:   1) https://www.zeiss.com/microscopy/us/products/microscope-software/zen/czi.html
--
-- Port notes:   read port: the Main table plus ShortenTagNames and ProcessCZI.
--               The local collapseRunTail and collapseDevicesDevice helpers
--               implement the repeated-path collapsing that Perl does with in-
--               place regex substitutions. Upstream ZISRAW.pm is read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local str = require('lexiftool.perl').str

local ZISRAW = {}

-- ZISRAW info (upstream %Image::ExifTool::ZISRAW::Main)
ZISRAW.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Image' },
    NOTES = [[
        As well as the header information listed below, ExifTool also extracts the
        top-level XML-based metadata from Zeiss Integrated Software RAW (ZISRAW) CZI
        files.
    ]],
    [0x20] = {
        Name = 'ZISRAWVersion',
        Format = 'int32u[2]',
        PrintConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [0x30] = {
        Name = 'PrimaryFileGUID',
        Format = 'undef[16]',
        ValueConv = function(_self, val)
            return (val:gsub('.', function(c) return string.format('%02x', c:byte()) end))
        end,
    },
    [0x40] = {
        Name = 'FileGUID',
        Format = 'undef[16]',
        ValueConv = function(_self, val)
            return (val:gsub('.', function(c) return string.format('%02x', c:byte()) end))
        end,
    },
}

--------------------------------------------------------------------------------
-- Collapse a run of one-or-more consecutive `unit` occurrences immediately
-- followed by `tail` into `tail` (Lua patterns have no `(x)+y` quantified
-- capture group, unlike upstream's regex; used for e.g.
-- `s/(ApoTomeDepthInfo)+Element/ApoTomeDepth/`). Pass tail = '' to collapse
-- a bare `(unit)+` run (e.g. `s/(BeamPathNode)+/BeamPathNode/`) to `unit`.
--------------------------------------------------------------------------------
local function collapseRunTail(s, unit, tail, repl)
    local ulen = #unit
    local start = 1
    while true do
        local a = s:find(unit, start, true)
        if not a then return s end
        local pos = a + ulen
        while s:sub(pos, pos + ulen - 1) == unit do pos = pos + ulen end
        if s:sub(pos, pos + #tail - 1) == tail then
            return s:sub(1, a - 1) .. repl .. s:sub(pos + #tail)
        end
        start = a + 1
    end
end

--------------------------------------------------------------------------------
-- Collapse upstream's `s/(Devices?)+Device/Device/` (a repeated group
-- alternating "Device"/"Devices", greedy on the trailing "s", followed by a
-- literal "Device" tail) -- another `(x)+` case Lua patterns can't express.
--------------------------------------------------------------------------------
local function collapseDevicesDevice(s)
    local start = 1
    while true do
        local a = s:find('Device', start, true)
        if not a then return s end
        local ends = { a - 1 }
        local pos = a
        while true do
            if s:sub(pos, pos + 6) == 'Devices' then
                pos = pos + 7
            elseif s:sub(pos, pos + 5) == 'Device' then
                pos = pos + 6
            else
                break
            end
            ends[#ends + 1] = pos - 1
        end
        for k = #ends, 2, -1 do
            local e = ends[k]
            if s:sub(e + 1, e + 6) == 'Device' then
                return s:sub(1, a - 1) .. 'Device' .. s:sub(e + 6 + 1)
            end
        end
        start = a + 1
    end
end

--------------------------------------------------------------------------------
-- Shorten obscenely long CZI tag names
-- Inputs: Tag name
-- Returns: Shortened tag name
--------------------------------------------------------------------------------
function ZISRAW.ShortenTagNames(name)
    local s = name
    s = s:gsub('^HardwareSetting', '')
    s = s:gsub('^DevicesDevice', 'Device')
    s = s:gsub('LightPathNode', '')
    s = s:gsub('Successors', '')
    s = s:gsub('ExperimentExperiment', 'Experiment')
    s = s:gsub('ObjectivesObjective', 'Objective')
    s = s:gsub('ChannelsChannel', 'Channel')
    s = s:gsub('TubeLensesTubeLens', 'TubeLens')
    s = s:gsub('^ExperimentHardwareSettingsPoolHardwareSetting', 'HardwareSetting')
    s = s:gsub('SharpnessMeasureSetSharpnessMeasure', 'Sharpness')
    s = s:gsub('FocusSetupAutofocusSetup', 'Autofocus')
    s = s:gsub('TracksTrack', 'Track')
    s = s:gsub('ChannelRefsChannelRef', 'ChannelRef')
    s = s:gsub('ChangerChanger', 'Changer')
    s = s:gsub('ElementsChangerElement', 'Changer')
    s = s:gsub('ChangerElements', 'Changer')
    s = s:gsub('ContrastChangerContrast', 'Contrast')
    s = s:gsub('KeyFunctionsKeyFunction', 'KeyFunction')
    s = s:gsub('ManagerContrastManagerContrast', 'ManagerContrast')
    s = s:gsub('ManagerContrastManager', 'ManagerContrast')
    s = s:gsub('ObjectiveChangerObjective', 'ObjectiveChanger')
    s = s:gsub('ManagerLightManager', 'ManagerLight')
    s = s:gsub('WavelengthAreasWavelengthArea', 'WavelengthArea')
    s = s:gsub('ReflectorChangerReflector', 'ReflectorChanger')
    s = s:gsub('^StageStageAxesStageAxis', 'StageAxis')
    s = s:gsub('ShutterChangerShutter', 'ShutterChanger')
    s = s:gsub('OnOffChangerOnOff', 'OnOffChanger')
    s = s:gsub('UnsharpMaskStateUnsharpMask', 'UnsharpMask')
    s = s:gsub('Acquisition', 'Acq')
    s = s:gsub('Continuous', 'Cont')
    s = s:gsub('Resolution', 'Res')
    s = s:gsub('Experiment', 'Expt')
    s = s:gsub('Threshold', 'Thresh')
    s = s:gsub('Reference', 'Ref')
    s = s:gsub('Magnification', 'Mag')
    s = s:gsub('Original', 'Orig')
    s = s:gsub('FocusSetupFocusStrategySetup', 'Focus')
    s = s:gsub('ParametersParameter', 'Parameter')
    s = s:gsub('IntervalInfo', 'Interval')
    s = s:gsub('ExptBlocksAcqBlock', 'AcqBlock')
    s = s:gsub('MicroscopesMicroscope', 'Microscope')
    s = s:gsub('TimeSeriesInterval', 'TimeSeries')
    s = s:gsub('Interval(.*Interval)', '%1')
    s = s:gsub('SingleTileRegionsSingleTileRegion', 'SingleTileRegion')
    s = s:gsub('AcquisitionMode', '')
    s = s:gsub('DetectorsDetector', 'Detector')
    s = s:gsub('Setup', '')
    s = s:gsub('Setting', '')
    s = s:gsub('TrackTrack', 'Track')
    s = s:gsub('AnalogOutMaximumsAnalogOutMaximum', 'AnalogOutMaximum')
    s = s:gsub('AnalogOutMinimumsAnalogOutMinimum', 'AnalogOutMinimum')
    s = s:gsub('DigitalOutLabelsDigitalOutLabelLabel', 'DigitalOutLabelLabel')
    s = collapseRunTail(s, 'VivaTomeOpticalSectionInformation', 'VivaTomeOpticalSectionInformation', 'VivaTomeOpticalSectionInformation')
    s = s:gsub('FocusDefiniteFocus', 'FocusDefinite')
    s = s:gsub('ChangerChanger', 'Changer')
    s = s:gsub('Calibration', 'Cal')
    s = s:gsub('LightSwitchChangerRLTLSwitch', 'LightSwitchChangerRLTL')
    s = s:gsub('Parameters', '')
    s = s:gsub('Fluorescence', 'Fluor')
    s = s:gsub('CameraGeometryCameraGeometry', 'CameraGeometry')
    s = s:gsub('CameraCamera', 'Camera')
    s = s:gsub('DetectorsCamera', 'Camera')
    s = s:gsub('FilterChangerLeftChangerEmissionFilter', 'LeftChangerEmissionFilter')
    s = s:gsub('SwitchingStatesSwitchingState', 'SwitchingState')
    s = s:gsub('Information', 'Info')
    s = s:gsub('SubDimensions?', '')
    s = s:gsub('Setups?', '')
    s = s:gsub('Parameters?', '')
    s = s:gsub('Calculate', 'Calc')
    s = s:gsub('Visibility', 'Vis')
    s = s:gsub('Orientation', 'Orient')
    s = s:gsub('ListItems', 'Items')
    s = s:gsub('Increment', 'Incr')
    s = s:gsub('Parameter', 'Param')
    s = collapseRunTail(s, 'ParfocalParcentralValues', 'ParfocalParcentralValue', 'Parcentral')
    s = s:gsub('ParcentralParcentral', 'Parcentral')
    s = s:gsub('CorrFocusCorrection', 'FocusCorr')
    s = collapseRunTail(s, 'ApoTomeDepthInfo', 'Element', 'ApoTomeDepth')
    s = collapseRunTail(s, 'ApoTomeClickStopInfo', 'Element', 'ApoTomeClickStop')
    s = s:gsub('DepthDepth', 'Depth')
    s = collapseDevicesDevice(s)
    s = collapseRunTail(s, 'BeamPathNode', '', 'BeamPathNode')
    s = s:gsub('BeamPathsBeamPath', 'BeamPath')
    s = s:gsub('BeamPathBeamPath', 'BeamPath')
    s = s:gsub('Configuration', 'Config')
    s = s:gsub('StageAxesStageAxis', 'StageAxis')
    s = s:gsub('RangesRange', 'Range')
    -- (Lua patterns have no `(x)?` optional capture group; try the longer
    -- literal alternative first, then the shorter one)
    s = s:gsub('DataGridDatasGridDataGrid', 'DataGrid')
    s = s:gsub('DataGridDatasGridData', 'DataGrid')
    s = s:gsub('DataMicroscopeDatasMicroscopeDataMicroscope', 'DataMicroscope')
    s = s:gsub('DataMicroscopeDatasMicroscopeData', 'DataMicroscope')
    s = s:gsub('DataWegaDatasWegaData', 'DataWega')
    s = s:gsub('ClickStopPositionsClickStopPosition', 'ClickStopPosition')
    -- (Lua patterns have no `(x)?` optional capture group; enumerate the
    -- longest-first literal alternatives for the two optional groups)
    for _, prefix in ipairs({ 'LightSourcess', 'LightSources' }) do
        s = s:gsub(prefix .. 'LightSourceSettingsLightSource', 'LightSource')
        s = s:gsub(prefix .. 'LightSourceSettings', 'LightSource')
        s = s:gsub(prefix .. 'LightSourceLightSource', 'LightSource')
        s = s:gsub(prefix .. 'LightSource', 'LightSource')
    end
    s = s:gsub('FilterSetsFilterSet', 'FilterSet')
    s = s:gsub('EmissionFiltersEmissionFilter', 'EmissionFilter')
    s = s:gsub('ExcitationFiltersExcitationFilter', 'ExcitationFilter')
    s = s:gsub('FiltersFilter', 'Filter')
    s = s:gsub('DichroicsDichroic', 'Dichronic')
    s = s:gsub('WavelengthsWavelength', 'Wavelength')
    s = s:gsub('MultiTrackSetup', 'MultiTrack')
    s = s:gsub('TrackTrack', 'Track')
    s = s:gsub('DataGrabberSetup', 'DataGrabber')
    s = s:gsub('CameraFrameSetup', 'CameraFrame')
    -- (Lua patterns have no alternation)
    s = s:gsub('TimeSeriesTimeSeries', 'TimeSeries')
    s = s:gsub('TimeSeriesSetups', 'TimeSeries')
    s = s:gsub('FocusFocus', 'Focus')
    s = s:gsub('FocusAutofocus', 'Autofocus')
    -- (Lua patterns have no alternation or `(x)+` quantified capture group;
    -- the following "AutofocusAutofocus" rule mops up any residual repeat)
    s = s:gsub('FocusHardwareAutofocus', 'AutofocusHardware')
    s = s:gsub('FocusSoftwareAutofocus', 'AutofocusSoftware')
    s = s:gsub('AutofocusAutofocus', 'Autofocus')
    return s
end

--------------------------------------------------------------------------------
-- Extract metadata from a ZISRAW (CZI) image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid CZI file
--------------------------------------------------------------------------------
function ZISRAW.ProcessCZI(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(100)
    if n ~= 100 then return 0 end
    if not buff:match('^ZISRAWFILE\0\0\0\0\0\0') then return 0 end
    et:SetFileType()
    ExifTool.SetByteOrder('II')
    local d = {
        DataPt = buff,
        DirStart = 0,
        DirLen = #buff,
    }
    local tagTablePtr = et:GetTagTable('lexiftool.ZISRAW.Main')
    et:ProcessDirectory(d, tagTablePtr)

    -- read the metadata section
    local pos = ExifTool.Get64u(buff, 92)
    if not pos or pos == 0 then return 1 end
    if not raf:Seek(pos, 0) then et:Warn('Error seeking to metadata') return 0 end
    n, buff = raf:Read(288)
    if n ~= 288 then et:Warn('Error reading metadata header') return 0 end
    if not buff:match('^ZISRAWMETADATA\0\0') then et:Warn('Invalid metadata header') return 0 end
    local len = ExifTool.Get32u(buff, 32)
    if len >= 200000000 then et:Warn('Metadata section too large. Ignoring') return 0 end
    n, buff = raf:Read(len)
    if not buff or n == 0 then et:Warn('Error reading XML metadata') return 0 end
    et:FoundTag('XML', buff) -- extract as a block
    tagTablePtr = et:GetTagTable('lexiftool.XMP.XML')
    d.DataPt = buff
    d.DirLen = #buff
    -- shorten tag names somewhat by removing 'ImageDocumentMetadata' prefix from all
    et.XmpIgnoreProps = { 'ImageDocument', 'Metadata', 'Information' }
    et.ShortenXmpTags = ZISRAW.ShortenTagNames

    et:ProcessDirectory(d, tagTablePtr)

    return 1
end

return ZISRAW
