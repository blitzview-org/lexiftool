--------------------------------------------------------------------------------
-- File:         lexiftool/WTV.lua
-- Ported from:  lib/Image/ExifTool/WTV.pm
--
-- Description:  Read WTV meta information
--
-- Revisions:    2018-05-30 - P. Harvey Created
--
-- References:   1) https://wiki.multimedia.cx/index.php?title=WTV
--
-- Port notes:   read subset. Ported: ProcessWTV (the 0x60-byte header
--               validation + WTV-directory chunk loop with the per-chunk
--               sector reading), ProcessMetadata (the \x5a\xfe...\x14\x53
--               metadata-record reader with dynamic tag creation and the
--               int32u/boolean32/string/GUID/int64u format dispatch), and
--               ReadSectors.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local tr = perl.tr
local subst = perl.subst
local isMatch = perl.isMatch
local unpack = perl.unpack
local sprintf = perl.sprintf
local perlTruthy = perl.truthy
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local SetByteOrder = ExifTool.SetByteOrder
local Get32u = ExifTool.Get32u
local Get32s = ExifTool.Get32s
local Get64u = ExifTool.Get64u

local WTV = {}

-- (port helper: copy the shared hash into the entry, as Perl's `%hash`
--  spread does -- explicit fields of the entry win)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

local timeInfo = {
    -- time looks like 100 ns intervals since 0:00 UTC Jan 1, 0001 (ref PH)
    ValueConv = function(_self, val) -- (719162 days from 0001:01:01 to 1970:01:01)
        local t = val / 1e7 - 719162*24*3600
        return ExifTool.ConvertUnixTime(t) .. 'Z'
    end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

local bool = { PrintConv = { [0] = 'No', [1] = 'Yes' }, PrintConvColumns = 2 }

-- WTV chunks
WTV.Main = {
    GROUPS = { [0] = 'WTV', [1] = 'WTV', [2] = 'Video' },
    NOTES = 'Tags found in Windows recorded TV (WTV) videos.',
  -- 'timeline.table.0.header.Events' (not decoded)
  -- 'timeline.table.0.entries.Events' (not decoded)
  -- 'timeline' (not decoded)
  -- 'table.0.header.legacy_attrib' (not decoded)
    ['table.0.entries.legacy_attrib'] = {
        Name = 'Metdata',
        SubDirectory = { TagTable = 'lexiftool.WTV.Metadata' },
    },
  -- 'table.0.redirector.legacy_attrib' (not decoded)
  -- 'table.0.header.time' (not decoded)
  -- 'table.0.entries.time' (not decoded)
}

-- Note: Many of these tags are similar to those found in Image::ExifTool::Microsoft::Xtra
--       and Image::ExifTool::ASF::ExtendedDescr
WTV.Metadata = {
    GROUPS = { [0] = 'WTV', [1] = 'WTV', [2] = 'Video' },
    PROCESS_PROC = false, -- predeclaration, see below (ProcessMetadata)
    NOTES = 'ExifTool will extract any tag found, even if not in this table.',
    VARS = { ID_FMT = 'none' },
    ['Duration']  = {
        Name = 'Duration',
        ValueConv = function(_self, val) return val/1e7 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    ['Title']     = { },
    ['WM/Genre']  = 'Genre',
    ['WM/Language']               = 'Language',
    ['WM/MediaClassPrimaryID']    = 'MediaClassPrimaryID',
    ['WM/MediaClassSecondaryID']  = 'MediaClassSecondaryID',
    ['WM/MediaCredits']           = 'MediaCredits',
    ['WM/MediaIsDelay']           = spread(bool) { Name = 'MediaIsDelay'    },
    ['WM/MediaIsFinale']          = spread(bool) { Name = 'MediaIsFinale'   },
    ['WM/MediaIsLive']            = spread(bool) { Name = 'MediaIsLive'     },
    ['WM/MediaIsMovie']           = spread(bool) { Name = 'MediaIsMovie'    },
    ['WM/MediaIsPremiere']        = spread(bool) { Name = 'MediaIsPremiere' },
    ['WM/MediaIsRepeat']          = spread(bool) { Name = 'MediaIsRepeat'   },
    ['WM/MediaIsSAP']             = spread(bool) { Name = 'MediaIsSAP'      },
    ['WM/MediaIsSport']           = spread(bool) { Name = 'MediaIsSport'    },
    ['WM/MediaIsStereo']          = spread(bool) { Name = 'MediaIsStereo',   Groups = { [2] = 'Audio' } },
    ['WM/MediaIsSubtitled']       = spread(bool) { Name = 'MediaIsSubtitled' },
    ['WM/MediaIsTape']            = spread(bool) { Name = 'MediaIsTape'     },
    ['WM/MediaNetworkAffiliation'] = 'MediaNetworkAffiliation',
    ['WM/MediaOriginalBroadcastDateTime'] = {
        Name = 'MediaOriginalBroadcastDateTime',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) val = tr(val, '-T', ': '); return val end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['WM/MediaOriginalChannel']   = { Name = 'MediaOriginalChannel' },
    ['WM/MediaOriginalChannelSubNumber']  = { Name = 'MediaOriginalChannelSubNumber' },
    ['WM/MediaOriginalRunTime']   = {
        Name = 'MediaOriginalRunTime',
        ValueConv = function(_self, val) return val / 1e7 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    ['WM/MediaStationCallSign']   = 'MediaStationCallSign',
    ['WM/MediaStationName']       = 'MediaStationName',
    ['WM/MediaThumbAspectRatioX'] = 'MediaThumbAspectRatioX',
    ['WM/MediaThumbAspectRatioY'] = 'MediaThumbAspectRatioY',
    ['WM/MediaThumbHeight']       = 'MediaThumbHeight',
    ['WM/MediaThumbRatingAttributes']     = { Name = 'MediaThumbRatingAttributes' },
    ['WM/MediaThumbRatingLevel']  = 'MediaThumbRatingLevel',
    ['WM/MediaThumbRatingSystem'] = 'MediaThumbRatingSystem',
    ['WM/MediaThumbRet']          = 'MediaThumbRet',
    ['WM/MediaThumbStride']       = 'MediaThumbStride',
    ['WM/MediaThumbTimeStamp']    = { Name = 'MediaThumbTimeStamp', Notes = 'unknown units', Unknown = 1 },
    ['WM/MediaThumbWidth']        = 'MediaThumbWidth',
    ['WM/OriginalReleaseTime']    = {
        Name = 'OriginalReleaseTime',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) val = tr(val, '-T', ': '); return val end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ['WM/ParentalRating']         = 'ParentalRating',
    ['WM/ParentalRatingReason']   = 'ParentalRatingReason',
    ['WM/Provider']               = 'Provider',
    ['WM/ProviderCopyright']      = 'ProviderCopyright',
    ['WM/ProviderRating']         = 'ProviderRating',
    ['WM/SubTitle']               = 'Subtitle',
    ['WM/SubTitleDescription']    = 'SubtitleDescription',
    ['WM/VideoClosedCaptioning']  = spread(bool) { Name = 'VideoClosedCaptioning' },
    ['WM/WMRVATSCContent']        = spread(bool) { Name = 'ATSCContent' },
    ['WM/WMRVActualSoftPostPadding']  = 'ActualSoftPostPadding',
    ['WM/WMRVActualSoftPrePadding']   = 'ActualSoftPrePadding',
    ['WM/WMRVBitrate']            = { Name = 'Bitrate', Notes = 'unknown units', Unknown = 1 },
    ['WM/WMRVBrandingImageID']    = 'BrandingImageID',
    ['WM/WMRVBrandingName']       = 'BrandingName',
    ['WM/WMRVContentProtected']   = spread(bool) { Name = 'ContentProtected' },
    ['WM/WMRVContentProtectedPercent'] = 'ContentProtectedPercent',
    ['WM/WMRVDTVContent']         = spread(bool) { Name = 'DTVContent' },
    ['WM/WMRVEncodeTime']         = spread(timeInfo) { Name = 'EncodeTime',     Groups = { [2] = 'Time' } },
    ['WM/WMRVEndTime']            = spread(timeInfo) { Name = 'EndTime',        Groups = { [2] = 'Time' } },
    ['WM/WMRVExpirationDate']     = spread(timeInfo) { Name = 'ExpirationDate', Groups = { [2] = 'Time' }, Unknown = 1 },
    ['WM/WMRVExpirationSpan']     = { Name = 'ExpirationSpan', Notes = 'unknown units', Unknown = 1 },
    ['WM/WMRVHDContent']          = spread(bool) { Name = 'HDContent' },
    ['WM/WMRVHardPostPadding']    = 'HardPostPadding',
    ['WM/WMRVHardPrePadding']     = 'HardPrePadding',
    ['WM/WMRVInBandRatingAttributes'] = 'InBandRatingAttributes',
    ['WM/WMRVInBandRatingLevel']  = 'InBandRatingLevel',
    ['WM/WMRVInBandRatingSystem'] = 'InBandRatingSystem',
    ['WM/WMRVKeepUntil']          = 'KeepUntil',
    ['WM/WMRVOriginalSoftPostPadding'] = 'OriginalSoftPostPadding',
    ['WM/WMRVOriginalSoftPrePadding'] = 'OriginalSoftPrePadding',
    ['WM/WMRVProgramID']          = 'ProgramID',
    ['WM/WMRVQuality']            = 'Quality',
    ['WM/WMRVRequestID']          = 'RequestID',
    ['WM/WMRVScheduleItemID']     = 'ScheduleItemID',
    ['WM/WMRVSeriesUID']          = 'SeriesUID',
    ['WM/WMRVServiceID']          = 'ServiceID',
    ['WM/WMRVWatched']            = spread(bool) { Name = 'Watched' },
}

--------------------------------------------------------------------------------
-- Read specified sectors from the file (upstream ReadSectors)
-- Inputs: 0) raf ref, 1) sector table ref, 2) offset in sector table,
--         3) sector size
-- Returns: Data or nil on error
--------------------------------------------------------------------------------
local function ReadSectors(raf, secPt, pos, secSize)
    local data, buff, n
    while pos <= #secPt - 4 do
        local sec = Get32u(secPt, pos)
        if sec == 0xffff then return nil end -- (just in case)
        if sec == 0 then break end   -- a null marks the end of the sector table
        if data ~= nil then data = data .. buff else data = buff end
        if not raf:Seek(sec*secSize,0) then return nil end
        n, buff = raf:Read(secSize)
        if n ~= secSize then return nil end
        pos = pos + 4
    end
    if data ~= nil then return data .. buff end
    return buff
end

--------------------------------------------------------------------------------
-- Process WTV metadata
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function WTV.ProcessMetadata(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = 0
    local end_ = #dataPt
    et:VerboseDir('WTV Metadata', nil, end_)
    while pos + 0x18 < end_ do
        if substr(dataPt,pos,16) ~= "\x5a\xfe\xd7\x6d\xc8\x1d\x8f\x4a\x99\x22\xfa\xb1\x1c\x38\x14\x53" then break end
        local fmt = Get32u(dataPt, pos + 0x10)
        local len = Get32u(dataPt, pos + 0x14)
        local str = ''
        pos = pos + 0x18
        while true do
            if pos + 2 > end_ then et:Warn('Corrupt metadata directory'); break end
            local ch = substr(dataPt, pos, 2)
            pos = pos + 2
            if ch == "\0\0" then break end
            str = str .. ch
        end
        if pos + len > end_ then break end
        local tag = et:Decode(str, 'UTF16', nil, 'UTF8')
        local dat = substr(dataPt, pos, len)
        -- add tag if not already there
        if not tagTablePtr[tag] then
            local name = tag
            name = subst(name, [[^(WTV_Metadata_)?WM/(WMRV)?]], '')
            AddTagToTable(nil, tagTablePtr, tag, name)
            et:VPrint(0, et.INDENT, "[adding WTV:" .. name .. "]\n")
        end
        local val
        if fmt==0 or fmt==3 then   -- int32u or boolean32
            val = Get32s(dat, 0)
        elseif fmt == 1 then       -- string
            val = et:Decode(dat, 'UTF16')
        elseif fmt == 6 then       -- GUID
            val = unpack('H*', dat)
        elseif fmt == 4 then       -- int64u (date/time values use this)
            val = Get64u(dat, 0)
        else
            val = dat
            fmt = "Unknown(" .. fmt .. ")"
        end
        et:HandleTag(tagTablePtr, tag, val, {
            Format = "format " .. fmt,
            Size = #dat,
        })
        et:VerboseDump(dat)
        pos = pos + len
    end
end

--------------------------------------------------------------------------------
-- Extract information from a WTV video
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid WTV file
--------------------------------------------------------------------------------
function WTV.ProcessWTV(et, dirInfo)
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local buff, tagTablePtr, pos, len, num

    -- verify this is a valid WTV file
    num, buff = raf:Read(0x60)
    if num ~= 0x60 then return 0 end
    if not isMatch(buff, [[^\xb7\xd8\x00\x20\x37\x49\xda\x11\xa6\x4e\x00\x07\xe9\x5e\xad\x8d]]) then return 0 end
    et:SetFileType()
    SetByteOrder('II')
    -- 0x28 - int32u: sector size? (=0x1000) (PH NC)
    -- 0x38 - int32u: sector number for main WTV directory (PH assume this is a sector table, NC)
    -- 0x58 - int32u: total number of sectors in file
    local secSize = Get32u(buff, 0x28)
    -- in case I'm wrong about this, constrain sector size to
    -- either 0x1000 (standard) or 0x100 (ExifTool test file) - PH
    if not (secSize == 0x1000 or secSize == 0x100) then secSize = 0x1000 end
    buff = ReadSectors(raf, buff, 0x38, secSize)  -- read the WTV directory
    if buff == nil then return 0 end
    tagTablePtr = GetTagTable(nil, 'lexiftool.WTV.Main')
    -- parse the WTV directory
    et:VerboseDir('WTV')
    pos = 0
    while pos < #buff-0x28 do
        if substr(buff,pos,0x10) ~= "\x92\xb7\x74\x91\x59\x70\x70\x44\x88\xdf\x06\x3b\x82\xcc\x21\x3d" then
            if pos == 0 then et:Warn("WTV directory wasn't at expected location") end
            break
        end
        len = Get32u(buff, pos+0x10)
        if pos + len > #buff then break end
        local n = Get32u(buff, pos + 0x20)
        if 0x28 + n*2 + 8 > len then et:Warn('WTV directory error'); break end
        local tag = et:Decode(substr(buff,pos+0x28,n*2), 'UTF16', nil, 'UTF8')
        local ptr = pos + 0x28 + n * 2
        local flg = Get32u(buff, ptr + 4)
        if perlTruthy(verbose) then
            local s = Get32s(buff, ptr)
            if s >= 0 then s = sprintf('0x%x', s) end
            et:VPrint(1,"- Tag '" .. tag .. "' (sector=" .. s .. ", flag=" .. flg .. ")")
        end
        if not (tagTablePtr[tag] and (flg == 0 or flg == 1)) then goto next end
        do
            local sec = substr(buff, ptr, 4)
            local data = ReadSectors(raf, sec, 0, secSize)
            if data == nil then break end
            -- read sectors from table if necessary (flag=1 indicates a sector table)
            if flg == 1 then data = ReadSectors(raf, data, 0, secSize) end
            if data == nil then et:Warn("Error fetching data for " .. tag); goto next end
            et:HandleTag(tagTablePtr, tag, data)
        end
        ::next::
        pos = pos + len
    end
    return 1
end

-- (PROCESS_PROC set here so the table can reference ProcessMetadata)
WTV.Metadata.PROCESS_PROC = WTV.ProcessMetadata

return WTV