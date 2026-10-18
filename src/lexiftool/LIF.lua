--------------------------------------------------------------------------------
-- File:         lexiftool/LIF.lua
-- Ported from:  lib/Image/ExifTool/LIF.pm
--
-- Description:  Read LIF (Leica Image File) files
--
-- Revisions:    2021-06-21 - P. Harvey Created
--
-- Port notes:   ported in full: the `Main` table, `ShortenTagNames` and
--               `ProcessLIF`. Upstream LIF.pm is read-only.
--               ShortenTagNames goes through `perl.subst` for every rule
--               rather than Lua's `gsub`: Perl's `s///` replaces only the
--               first occurrence (and only the one rule here that carries
--               `/g` replaces all), while `gsub` always replaces all -- and
--               four of the rules use an optional capture group
--               (`(Master)?`, `(List)?`, `(ROI)?`, `(Roi)?`), which Lua
--               patterns cannot express at all.
--               `Decode` takes no target-charset argument in this port (it
--               always produces UTF-8), so upstream's trailing 'UTF8' has no
--               counterpart in the call.
--               No vendored test image is a LIF file.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local uv = perl.uv
local XMP = require('lexiftool.XMP')
local matches = perl.matches
local subst = perl.subst
local substr = perl.substr
local str = perl.str

local LIF = {}

LIF.Main = {
    GROUPS = { [0] = 'XML', [1] = 'XML', [2] = 'Image' },
    PROCESS_PROC = XMP.ProcessXMP,
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Tags extracted from Leica Image Format (LIF) imaging files.  As well as the
        tags listed below, all available information is extracted from the
        XML-format metadata in the LIF header.
    ]],
    TimeStampList = {
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            local unixTimeZero = 134774 * 24 * 3600
            local vals = perl.split(' ', str(val))
            for i = 1, #vals do
                local v = vals[i]
                if matches(v, [==[(?i)[^0-9a-f]]==]) then
                    v = '0000:00:00 00:00:00'
                elseif #v > 8 then
                    local lo = tonumber(substr(v, -8), 16)
                    local hi = tonumber(substr(v, 0, -8), 16)
                    v = 1e-7 * uv(hi * 4294967296 + lo)
                else
                    v = 1e-7 * tonumber(v, 16)
                end
                -- shift from Jan 1, 1601 to Jan 1, 1970
                -- (upstream applies this to the '0000:00:00 00:00:00' branch too, where
                --  Perl numifies the string to 0 -- perl.num does the same here)
                v = ExifTool.ConvertUnixTime(perl.num(v) - unixTimeZero)
                vals[i] = v
            end
            return vals
        end,
    },
}

--------------------------------------------------------------------------------
-- Shorten obscenely long LIF tag names
-- Inputs: Tag name
-- Returns: Shortened tag name
function LIF.ShortenTagNames(name)
    local s = name
    s = subst(s, [[DescriptionDimensionsDimensionDescription]], 'Dimensions')
    s = subst(s, [[DescriptionChannelsChannelDescription]], 'Channel')
    s = subst(s, [[ShutterListShutter]], 'Shutter')
    s = subst(s, [[SettingDefinition]], 'Setting')
    s = subst(s, [[AdditionalZPositionListAdditionalZPosition]], 'AdditionalZPosition')
    s = subst(s, [[LMSDataContainerHeader]], '', 'g')
    s = subst(s, [[FilterWheelWheel]], 'FilterWheel')
    s = subst(s, [[FilterWheelFilter]], 'FilterWheel')
    s = subst(s, [[DetectorListDetector]], 'Detector')
    s = subst(s, [[OnlineDyeSeparationOnlineDyeSeparation]], 'OnlineDyeSeparation')
    s = subst(s, [[AotfListAotf]], 'Aotf')
    s = subst(s, [[SettingAotfLaserLineSetting]], 'SettingAotfLaser')
    s = subst(s, [[DataROISetROISet]], 'DataROISet')
    s = subst(s, [[AdditionalZPosition]], 'AddZPos')
    s = subst(s, [[FRAPplusBlock_FRAPBlock_FRAP_PrePost_Info]], 'FRAP_')
    s = subst(s, [[FRAPplusBlock_FRAPBlock_FRAP_(Master)?]], 'FRAP_')
    s = subst(s, [[LDM_Block_SequentialLDM_Block_Sequential_]], 'LDM_')
    s = subst(s, [[ATLConfocalSetting]], 'ATLConfocal')
    s = subst(s, [[LaserArrayLaser]], 'Laser')
    s = subst(s, [[LDM_Master]], 'LDM_')
    s = subst(s, [[(List)?ATLConfocal]], 'ATL_')
    s = subst(s, [[Separation]], 'Sep')
    s = subst(s, [[BleachPointsElement]], 'BleachPoint')
    s = subst(s, [[BeamPositionBeamPosition]], 'BeamPosition')
    s = subst(s, [[DataROISetPossible(ROI)?]], 'DataROISet')
    s = subst(s, [[RoiElementChildrenElementDataROISingle(Roi)?]], 'Roi')
    s = subst(s, [[InfoLaserLineSettingArrayLaserLineSetting]], 'LastLineSetting')
    s = subst(s, [[FilterWheelWheelNameFilterName]], 'FilterWheelFilterName')
    s = subst(s, [[LUT_ListLut]], 'Lut')
    s = subst(s, [[ROI_ListRoiRoidata]], 'ROI_')
    s = subst(s, [[LaserLineSettingArrayLaserLineSetting]], 'LaserLineSetting')
    return s
end

--------------------------------------------------------------------------------
-- Extract metadata from a LIF image
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid LIF file
function LIF.ProcessLIF(et, dirInfo)
    local raf = dirInfo.RAF
    local buff

    -- verify this is a valid LIF file
    local n
    n, buff = raf:Read(15)
    if n ~= 15 or not matches(buff, [[(?s)^\x70\0{3}.{4}\x2a.{4}<\0]]) then return 0 end

    et:SetFileType()
    ExifTool.SetByteOrder('II')

    local size = ExifTool.Get32u(buff, 4)        -- XML chunk size
    local len = ExifTool.Get32u(buff, 9) * 2     -- XML data length

    if size < len then et:Error('Corrupted LIF XML block') return 1 end
    if size > 100000000 then et:Error('LIF XML block too large') return 1 end

    local n2
    if raf:Seek(-2, 1) then n2, buff = raf:Read(len) end
    if n2 ~= len then et:Error('Truncated LIF XML block') return 1 end

    local tagTablePtr = et:GetTagTable('lexiftool.LIF.Main')

    -- convert from UTF16 to UTF8
    local xml = et:Decode(buff, 'UTF16', 'II')

    local dirInfo2 = { DataPt = xml }

    et.XmpIgnoreProps = { 'LMSDataContainerHeader', 'Element', 'Children', 'Data', 'Image', 'Attachment' }
    et.ShortenXmpTags = LIF.ShortenTagNames

    et:ProcessDirectory(dirInfo2, tagTablePtr)

    return 1
end

return LIF
