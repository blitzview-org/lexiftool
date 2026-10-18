--------------------------------------------------------------------------------
-- File:         lexiftool/M2TS.lua
-- Ported from:  lib/Image/ExifTool/M2TS.pm
--
-- Description:  Read M2TS (AVCHD) meta information
--
-- Revisions:    2009/07/03 - P. Harvey Created
--
-- References:   1) http://neuron2.net/library/mpeg2/iso13818-1.pdf
--               2) http://www.blu-raydisc.com/Assets/Downloadablefile/BD-RE_Part3_V2.1_WhitePaper_080406-15271.pdf
--               3) http://www.videohelp.com/forum/archive/reading-avchd-playlist-files-bdmv-playlist-mpl-t358888.html
--               4) http://en.wikipedia.org/wiki/MPEG_transport_stream
--               5) http://www.dunod.com/documents/9782100493463/49346_DVB.pdf
--               6) http://trac.handbrake.fr/browser/trunk/libhb/stream.c
--               7) http://ieeexplore.ieee.org/stamp/stamp.jsp?arnumber=04560141
--               8) http://www.w6rz.net/xport.zip
--               9) https://en.wikipedia.org/wiki/Program-specific_information
--
-- Notes:        Variable names containing underlines are the same as in ref 1.
--
-- Glossary:     PES = Packetized Elementary Stream
--               PAT = Program Association Table
--               PMT = Program Map Table
--               PCR = Program Clock Reference
--               PID = Packet Identifier
--
-- To Do:        - parse PCR to obtain average bitrates?
--
-- Port notes:   read subset covering the vendored test files (M2TS.mts):
--               the streamType/tableID/noSyntax lookups, the Main/AC3 tag
--               tables, ParseAC3Audio/ParseAC3Descriptor, ParsePID (the
--               MPEG/H264/AC-3/MISB branches plus the type 6 / PID 0x0300
--               LIGOGPSINFO and Viidure branches; all type<0
--               dashcam-GPS branches are deferred), and ProcessM2TS
--               (the full packet walker incl. PAT/PMT parsing, PCR-based
--               Duration, the end-of-file partial-PID pass and the
--               LIGOGPSINFO trailer check). Deferred: the ExtractEmbedded>2
--               GPS scan, and verbose-only output beyond VerboseDir.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local matches = perl.matches
local sprintf = perl.sprintf
local tsort = perl.tsort

local M2TS = {}

-- program map table "stream_type" lookup (ref 6/1/9)
local streamType = {
    [0x00] = 'Reserved',
    [0x01] = 'MPEG-1 Video',
    [0x02] = 'MPEG-2 Video',
    [0x03] = 'MPEG-1 Audio',
    [0x04] = 'MPEG-2 Audio',
    [0x05] = 'ISO 13818-1 private sections',
    [0x06] = 'ISO 13818-1 PES private data',
    [0x07] = 'ISO 13522 MHEG',
    [0x08] = 'ISO 13818-1 DSM-CC',
    [0x09] = 'ISO 13818-1 auxiliary',
    [0x0A] = 'ISO 13818-6 multi-protocol encap',
    [0x0B] = 'ISO 13818-6 DSM-CC U-N msgs',
    [0x0C] = 'ISO 13818-6 stream descriptors',
    [0x0D] = 'ISO 13818-6 sections',
    [0x0E] = 'ISO 13818-1 auxiliary',
    [0x0F] = 'MPEG-2 AAC Audio',
    [0x10] = 'MPEG-4 Video',
    [0x11] = 'MPEG-4 LATM AAC Audio',
    [0x12] = 'MPEG-4 generic',
    [0x13] = 'ISO 14496-1 SL-packetized',
    [0x14] = 'ISO 13818-6 Synchronized Download Protocol',
    [0x15] = 'Packetized metadata',
    [0x16] = 'Sectioned metadata',
    [0x17] = 'ISO/IEC 13818-6 DSM CC Data Carousel metadata',
    [0x18] = 'ISO/IEC 13818-6 DSM CC Object Carousel metadata',
    [0x19] = 'ISO/IEC 13818-6 Synchronized Download Protocol metadata',
    [0x1a] = 'ISO/IEC 13818-11 IPMP',
    [0x1b] = 'H.264 (AVC) Video',
    [0x1c] = 'ISO/IEC 14496-3 (MPEG-4 raw audio)',
    [0x1d] = 'ISO/IEC 14496-17 (MPEG-4 text)',
    [0x1e] = 'ISO/IEC 23002-3 (MPEG-4 auxiliary video)',
    [0x1f] = 'ISO/IEC 14496-10 SVC (MPEG-4 AVC sub-bitstream)',
    [0x20] = 'ISO/IEC 14496-10 MVC (MPEG-4 AVC sub-bitstream)',
    [0x21] = 'ITU-T Rec. T.800 and ISO/IEC 15444 (JPEG 2000 video)',
    [0x24] = 'H.265 (HEVC) Video', --PH
    [0x42] = 'Chinese Video Standard',
    [0x7f] = 'ISO/IEC 13818-11 IPMP (DRM)',
    [0x80] = 'DigiCipher II Video',
    [0x81] = 'A52/AC-3 Audio',
    [0x82] = 'HDMV DTS Audio',
    [0x83] = 'LPCM Audio',
    [0x84] = 'SDDS Audio',
    [0x85] = 'ATSC Program ID',
    [0x86] = 'DTS-HD Audio',
    [0x87] = 'E-AC-3 Audio',
    [0x8a] = 'DTS Audio',
    [0x90] = 'Presentation Graphic Stream (subtitle)', --https://en.wikipedia.org/wiki/Program-specific_information
    [0x91] = 'A52b/AC-3 Audio',
    [0x92] = 'DVD_SPU vls Subtitle',
    [0x94] = 'SDDS Audio',
    [0xa0] = 'MSCODEC Video',
    [0xea] = 'Private ES (VC-1)',
}

-- "table_id" values (ref 5)
local tableID = {
    [0x00] = 'Program Association',
    [0x01] = 'Conditional Access',
    [0x02] = 'Program Map',
    [0x03] = 'Transport Stream Description',
    [0x40] = 'Actual Network Information',
    [0x41] = 'Other Network Information',
    [0x42] = 'Actual Service Description',
    [0x46] = 'Other Service Description',
    [0x4a] = 'Bouquet Association',
    [0x4e] = 'Actual Event Information - Present/Following',
    [0x4f] = 'Other Event Information - Present/Following',
    [0x50] = 'Actual Event Information - Schedule', --(also 0x51-0x5f)
    [0x60] = 'Other Event Information - Schedule', -- (also 0x61-0x6f)
    [0x70] = 'Time/Date',
    [0x71] = 'Running Status',
    [0x72] = 'Stuffing',
    [0x73] = 'Time Offset',
    [0x7e] = 'Discontinuity Information',
    [0x7f] = 'Selection Information',
}

-- PES stream ID's for which a syntax field does not exist
local noSyntax = {
    [0xbc] = true, -- program_stream_map
    [0xbe] = true, -- padding_stream
    [0xbf] = true, -- private_stream_2
    [0xf0] = true, -- ECM_stream
    [0xf1] = true, -- EMM_stream
    [0xf2] = true, -- DSMCC_stream
    [0xf8] = true, -- ITU-T Rec. H.222.1 type E stream
    [0xff] = true, -- program_stream_directory
}

-- information extracted from the MPEG-2 transport stream
M2TS.Main = {
    GROUPS = { [2] = 'Video' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        The MPEG-2 transport stream is used as a container for many different
        audio/video formats (including AVCHD).  This table lists information
        extracted from M2TS files.
    ]],
    VideoStreamType = {
        PrintHex = 1,
        PrintConv = streamType,
    },
    AudioStreamType = {
        PrintHex = 1,
        PrintConv = streamType,
    },
    Duration = {
        Notes = [[
            the -fast option may be used to avoid scanning to the end of file to
            calculate the Duration
        ]],
        ValueConv = function(_self, val) return val / 27000000 end, -- (clock is 27MHz)
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    -- the following tags are for documentation purposes only
    -- (they are also how Writer's LoadAllTables reaches M2TS::AC3, H264::Main
    --  and MISB::Main -- ParsePID dispatches to those tables itself, so the
    --  recursion has nothing else to follow; same shape as JPEG.lua's Main)
    _AC3  = { SubDirectory = { TagTable = 'lexiftool.M2TS.AC3' } },
    _H264 = { SubDirectory = { TagTable = 'lexiftool.H264.Main' } },
    _MISB = { SubDirectory = { TagTable = 'lexiftool.MISB.Main' } },
}

-- information extracted from AC-3 audio streams
M2TS.AC3 = {
    GROUPS = { [1] = 'AC3', [2] = 'Audio' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Tags extracted from AC-3 audio streams.',
    AudioSampleRate = {
        PrintConv = {
            [0] = '48000',
            [1] = '44100',
            [2] = '32000',
        },
    },
    AudioBitrate = {
        ValueConv = {
            [0] = 32000,
            [1] = 40000,
            [2] = 48000,
            [3] = 56000,
            [4] = 64000,
            [5] = 80000,
            [6] = 96000,
            [7] = 112000,
            [8] = 128000,
            [9] = 160000,
            [10] = 192000,
            [11] = 224000,
            [12] = 256000,
            [13] = 320000,
            [14] = 384000,
            [15] = 448000,
            [16] = 512000,
            [17] = 576000,
            [18] = 640000,
            [32] = '32000 max',
            [33] = '40000 max',
            [34] = '48000 max',
            [35] = '56000 max',
            [36] = '64000 max',
            [37] = '80000 max',
            [38] = '96000 max',
            [39] = '112000 max',
            [40] = '128000 max',
            [41] = '160000 max',
            [42] = '192000 max',
            [43] = '224000 max',
            [44] = '256000 max',
            [45] = '320000 max',
            [46] = '384000 max',
            [47] = '448000 max',
            [48] = '512000 max',
            [49] = '576000 max',
            [50] = '640000 max',
        },
        PrintConv = function(_self, val) return ExifTool.ConvertBitrate(val) end,
    },
    SurroundMode = {
        PrintConv = {
            [0] = 'Not indicated',
            [1] = 'Not Dolby surround',
            [2] = 'Dolby surround',
        },
    },
    AudioChannels = {
        PrintConv = {
            [0] = '1 + 1',
            [1] = 1,
            [2] = 2,
            [3] = 3,
            [4] = '2/1',
            [5] = '3/1',
            [6] = '2/2',
            [7] = '3/2',
            [8] = 1,
            [9] = '2 max',
            [10] = '3 max',
            [11] = '4 max',
            [12] = '5 max',
            [13] = '6 max',
        },
    },
}

--------------------------------------------------------------------------------
-- Extract information from AC-3 audio stream
-- Inputs: 0) ExifTool ref, 1) data string
-- Reference: http://www.atsc.org/standards/a_52b.pdf
local function ParseAC3Audio(et, data)
    -- upstream regex /\x0b\x77..(.)/s : sync word, skip 2 bytes, capture one
    -- byte (manual scan -- a Lua pattern cannot capture a raw NUL-containing
    -- byte cleanly)
    local cap
    local n = #data
    local i = 1
    while i <= n - 4 do
        if data:byte(i) == 0x0b and data:byte(i + 1) == 0x77 then
            cap = data:sub(i + 4, i + 4)
            break
        end
        i = i + 1
    end
    if cap then
        local sampleRate = cap:byte() >> 6
        local tagTablePtr = et:GetTagTable('lexiftool.M2TS.AC3')
        et:HandleTag(tagTablePtr, 'AudioSampleRate', sampleRate)
    end
end

--------------------------------------------------------------------------------
-- Extract information from AC-3 stream descriptor
-- Inputs: 0) ExifTool ref, 1) data string
-- Reference: http://www.atsc.org/standards/a_52b.pdf
-- Note: This information is duplicated in the Audio stream, but it
--       is somewhat easier to extract it from the descriptor instead
local function ParseAC3Descriptor(et, data)
    if #data < 3 then return end
    local _, v2, v3 = data:byte(1, 3)
    local tagTablePtr = et:GetTagTable('lexiftool.M2TS.AC3')
    et:HandleTag(tagTablePtr, 'AudioBitrate', v2 >> 2)
    et:HandleTag(tagTablePtr, 'SurroundMode', v2 & 0x03)
    et:HandleTag(tagTablePtr, 'AudioChannels', (v3 >> 1) & 0x0f)
    -- don't (yet) decode any more (language codes, etc)
end

M2TS.ParseAC3Descriptor = ParseAC3Descriptor

--------------------------------------------------------------------------------
-- Parse PID stream data
-- Inputs: 0) ExifTool ref, 1) PID number, 2) PID type, 3) PID name, 4) data string
-- Returns: 0=stream parsed OK,
--          1=stream parsed but we want to parse more of these,
--          -1=can't parse yet because we don't know the type
local function ParsePID(et, pid, type_, pidName, data)
    -- can't parse until we know the type (Program Map Table may be later in the stream)
    if type_ == nil then return -1 end
    local verbose = et:Options('Verbose')
    if verbose and verbose > 1 then
        local out = et:Options('TextOut') or io.stdout
        out:write(sprintf('Parsing stream 0x%.4x (%s) %d bytes\n', pid, pidName or '', #data))
        et:VerboseDump(data)
    end
    local more = false
    if type_ == 0x01 or type_ == 0x02 then
        -- MPEG-1/MPEG-2 Video
        require('lexiftool.MPEG').ParseMPEGAudioVideo(et, data)
    elseif type_ == 0x03 or type_ == 0x04 then
        -- MPEG-1/MPEG-2 Audio
        require('lexiftool.MPEG').ParseMPEGAudio(et, data)
    elseif type_ == 6 and pid == 0x0300 then
        -- LIGOGPSINFO
        -- unknown dashcam (../testpics/gps_video/Wrong Way pass.ts, 160 bytes, not fuzzed)
        -- Pruveeo D90 dashcam (../testpics/gps_video/20260216_101326F.ts, 200 bytes, fuzzed)
        if matches(data, [[(?s)^LIGOGPSINFO]]) then
            local tbl = et:GetTagTable('lexiftool.QuickTimeStream.Stream')
            local dirInfo = { DataPt = data, DirName = 'Ligo0x0300' }
            require('lexiftool.LigoGPS').ProcessLigoGPS(et, dirInfo, tbl, #data ~= 200 and 1 or nil)
            et.FoundGoodGPS = 1
            more = 1
        else
            local v = { matches(data, [[(?s)^Viidure(20\d{2})/(\d{2})/(\d{2}) (\d{2}:\d{2}:\d{2}) ([NS]):(\S+) ]] ..
                [[([EW]):(\S+) (\S+) km/h (\S+) (\S+) (\S+) x:(\S+) y:(\S+) z:(\S+)]]) }
            if #v > 0 then
                -- (Innovv N2 dashcam)
                -- 0000: 56 69 69 64 75 72 65 32 30 32 36 2f 30 34 2f 31 [Viidure2026/04/1]
                -- 0010: 36 20 30 31 3a 30 31 3a 30 32 20 4e 3a 34 32 2e [6 01:01:02 N:42.]
                -- 0020: 32 31 31 34 32 34 20 57 3a 38 38 2e 33 32 30 39 [211424 W:88.3209]
                -- 0030: 37 35 20 38 39 2e 31 20 6b 6d 2f 68 20 32 36 37 [75 89.1 km/h 267]
                -- 0040: 2e 33 38 20 32 33 37 2e 38 30 20 31 30 20 78 3a [.38 237.80 10 x:]
                -- 0050: 2d 30 2e 30 30 31 20 79 3a 2d 30 2e 30 30 31 20 [-0.001 y:-0.001 ]
                -- 0060: 7a 3a 2d 30 2e 30 30 31 00 00 00 00 00 00 00 00 [z:-0.001........]
                local tbl = et:GetTagTable('lexiftool.QuickTimeStream.Stream')
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                local time = v[1] .. ':' .. v[2] .. ':' .. v[3] .. ' ' .. v[4] .. 'Z'
                et:HandleTag(tbl, 'GPSDateTime',  time)
                et:HandleTag(tbl, 'GPSLatitude',  perl.num(v[6]) * ((v[5] == 'S') and -1 or 1))
                et:HandleTag(tbl, 'GPSLongitude', perl.num(v[8]) * ((v[7] == 'W') and -1 or 1))
                et:HandleTag(tbl, 'GPSSpeed',     v[9])
                et:HandleTag(tbl, 'GPSTrack',     v[10])
                et:HandleTag(tbl, 'GPSAltitude',  v[11])
                -- (not sure what $12 is -- was a constant "10" in my sample)
                et:HandleTag(tbl, 'Accelerometer', v[13] .. ' ' .. v[14] .. ' ' .. v[15])
                et.FoundGoodGPS = 1
                more = 1
                et.DOC_NUM = nil
            end
        end
    elseif type_ == 0x1b then
        -- H.264 Video
        more = require('lexiftool.H264').ParseH264Video(et, data)
        -- force parsing additional H264 frames with ExtractEmbedded option
        if et.OPTIONS.ExtractEmbedded then
            more = 1
        elseif not et.OPTIONS.Validate then
            et:Warn('The ExtractEmbedded option may find more tags in the video data', 1)
        end
    elseif type_ == 0x81 or type_ == 0x87 or type_ == 0x91 then
        -- AC-3 audio
        ParseAC3Audio(et, data)
    elseif type_ == 0x15 then
        -- packetized metadata (look for MISB code starting after 5-byte header)
        if matches(data, [[(?s)^.{5}\x06\x0e\x2b\x34]]) then
            more = require('lexiftool.MISB').ParseMISB(et, data, et:GetTagTable('lexiftool.MISB.Main'))
            if not ExifTool.perlTruthy(et.OPTIONS.ExtractEmbedded) then
                more = 0  -- extract from only the first packet unless ExtractEmbedded is used
            elseif perl.num(et.OPTIONS.ExtractEmbedded) > 2 then
                more = 1  -- read past unknown 0x15 packets if ExtractEmbedded > 2
            end
        end
    end
    -- (upstream's type<0 dashcam-GPS branches are deferred -- no vendored
    --  test image exercises them through this port)
    return more
end

M2TS.ParsePID = ParsePID

--------------------------------------------------------------------------------
-- Extract information from a M2TS file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid M2TS file
function M2TS.ProcessM2TS(et, dirInfo)
    local raf = dirInfo.RAF
    local buff
    local eof
    local pLen, readSize
    local pmt = {}         -- pid -> program number
    local pidType = {}
    local pidName = {}
    local needPID = { [0] = 1 } -- lookup for stream PID's that we still need to parse
    local data = {}
    local sectLen = {}
    local packLen = {}
    local fromStart = {}
    local startTime, endTime, fwdTime, backScan, maxBack
    local verbose = et:Options('Verbose') or 0
    local out = et:Options('TextOut') or io.stdout

    -- read enough to guarantee 2 sync bytes
    local n
    n, buff = raf:Read(383)
    if n ~= 383 then return 0 end
    -- test for magic number (sync byte is the only thing we can safely check)
    -- (upstream regex /^(.{0,190}?)\x47(.{187}|.{191})\x47/s -- lazy prefix,
    --  then one 187- or 191-byte gap to the next sync; $tcLen is the gap
    --  minus 187, i.e. 0 for no timecode or 4 with one; $start is the sync
    --  position shifted back over a partial leading timecode)
    local first = buff:find('\71', 1, true) -- first 0x47 ('G')
    local start, tcLen
    while first and first <= 191 do
        if buff:byte(first + 188) == 0x47 then -- (187-byte gap tried first)
            tcLen = 0
            break
        elseif buff:byte(first + 192) == 0x47 then
            tcLen = 4
            break
        end
        first = buff:find('\71', first + 1, true)
    end
    if not tcLen then return 0 end
    start = (first - 1) - tcLen
    repeat
        if start < 0 then start = start + 192 end -- (if all or part of first timecode was missing)
        pLen = 188 + tcLen
        readSize = 64 * pLen -- size of our read buffer
        raf:Seek(start, 0) -- rewind to start
        n, buff = raf:Read(readSize)
        if not n or n < pLen * 4 then return 0 end -- require at least 4 packets
        -- validate the sync byte in the next 3 packets
        local j = 1
        while j < 4 do
            if buff:byte(tcLen + pLen * j + 1) == 0x47 then
                j = j + 1 -- next
            else
                if tcLen ~= 0 then return 0 end
                tcLen = 4
                start = start - 4
                goto retry -- (upstream `next Try`)
            end
        end
        break -- success!
        ::retry::
    until false
    -- (use M2T instead of M2TS just as an indicator that there is no timecode)
    et:SetFileType(tcLen ~= 0 and 'M2TS' or 'M2T')
    if start ~= 0 then et:Warn("File doesn't begin with the start of a packet") end
    ExifTool.SetByteOrder('MM')
    local tagTablePtr = et:GetTagTable('lexiftool.M2TS.Main')

    -- (upstream initializes %didPID with PIDs 1/2/0x1fff set to 0 so their
    --  fixed-purpose packets are never parsed as elementary streams; the
    --  port folds that into the lookup below)
    local didPID = { [1] = 0, [2] = 0, [0x1fff] = 0 }
    -- PID's that may contain GPS info
    local gpsPID = {
        [0x0300] = 1,    -- Novatek INNOVV, DOD_LS600W
        [0x01e4] = 1,    -- vsys a6l dashcam
        [0x0e1b] = 1,    -- Jomise T860S-GM dashcam GPS
        [0x0e1a] = 1,    -- Jomise T860S-GM dashcam accelerometer
    }
    local pEnd = 0

    -- scan entire file for GPS programs if ExtractEmbedded option is 3 or higher
    -- (some dashcams write these programs but don't include it in the PMT)
    if (perl.num(et:Options('ExtractEmbedded') or 0)) > 2 then
        for k in pairs(gpsPID) do
            needPID[k] = 1
            pidType[k] = -1
            pidName[k] = 'unregistered dashcam GPS'
        end
    end

    -- parse packets from MPEG-2 Transport Stream
    while true do
        if next(needPID) == nil then
            if startTime == nil then break end
            -- reconfigure to seek backwards for last PCR
            if backScan == nil then
                local saveTime = endTime
                endTime = nil
                if et:Options('FastScan') then break end
                if verbose > 0 then out:write('[Starting backscan for last PCR]\n') end
                -- remember how far we got when reading forward through the file
                local fwdPos = raf:Tell() - #buff + pEnd
                -- determine the position of the last packet relative to the EOF
                if not raf:Seek(0, 2) then break end
                local fsize = raf:Tell()
                backScan = math.floor(fsize / pLen) * pLen - fsize
                -- set limit on how far back we will go
                maxBack = fwdPos - fsize
                -- scan back a maximum of 512k (have seen last PCR at -276k)
                local nMax = math.floor(512000 / pLen) -- max packets to backscan
                if nMax < math.floor(-maxBack / pLen) then
                    maxBack = backScan - nMax * pLen
                else
                    -- use this time if none found in all remaining packets
                    fwdTime = saveTime
                end
                pEnd = 0
            end
        end
        local pos
        -- read more if necessary
        if backScan ~= nil then
            if endTime ~= nil then break end
            pEnd = pEnd - 2 * pLen -- step back to previous packet
            if pEnd < 0 then
                -- read another buffer from end of file
                if backScan <= maxBack then break end
                local buffLen = backScan - maxBack
                if buffLen > readSize then buffLen = readSize end
                backScan = backScan - buffLen
                if not raf:Seek(backScan, 2) then break end
                local bn
                bn, buff = raf:Read(buffLen)
                if bn ~= buffLen then break end
                pos = buffLen - pLen
                pEnd = pos
            end
        else
            pos = pEnd
            if pos + pLen > #buff then
                local bn
                bn, buff = raf:Read(readSize)
                if not bn or bn < pLen then
                    eof = true
                    break
                end
                pos = 0
                pEnd = 0
            end
        end
        pEnd = pEnd + pLen
        -- decode the packet prefix
        pos = pos + tcLen
        local prefix = ExifTool.Get32u(buff, pos)
        -- validate sync byte
        if (prefix & 0xff000000) ~= 0x47000000 then
            if backScan == nil then et:Warn('M2TS synchronization error') end
            break
        end
        local payloadUnitStartIndicator = prefix & 0x00400000
        local pid = (prefix & 0x001fff00) >> 8 -- packet ID
        local adaptationFieldExists = prefix & 0x00000020
        local payloadDataExists = prefix & 0x00000010
        if verbose > 1 then
            local i = (raf:Tell() - #buff + pEnd) / pLen - 1
            out:write('Transport packet ' .. i .. ':\n')
            local vopts = { Len = pLen, Addr = i * pLen, Start = pos - tcLen }
            -- (upstream passes Start => $pos-$tcLen; our HexDump opts use the
            --  same names)
            ExifTool.HexDump(buff, nil, vopts)
            local str = pidName[pid] and (' (' .. pidName[pid] .. ')') or ' <not in Program Map Table!>'
            out:write(sprintf('  Timecode:   0x%.4x\n', ExifTool.Get32u(buff, pos - tcLen)))
            out:write(sprintf('  Packet ID:  0x%.4x%s\n', pid, str))
            out:write(sprintf('  Start Flag: %s\n', payloadUnitStartIndicator ~= 0 and 'Yes' or 'No'))
        end

        pos = pos + 4
        -- handle adaptation field
        if adaptationFieldExists ~= 0 then
            local lenA = buff:byte(pos + 1)
            pos = pos + 1
            if pos + lenA > pEnd then
                et:Warn('Invalid adaptation field length')
                break
            end
            -- read PCR value for calculation of Duration
            if lenA > 6 then
                local flags = buff:byte(pos + 1)
                if flags & 0x10 ~= 0 then -- PCR_flag
                    -- combine 33-bit program_clock_reference_base and 9-bit extension
                    local pcrBase = ExifTool.Get32u(buff, pos + 1)
                    local pcrExt = ExifTool.Get16u(buff, pos + 5)
                    -- ignore separate programs (PID's) and store just the
                    -- first and last timestamps found in the file (is this OK?)
                    endTime = 300 * (2 * pcrBase + (pcrExt >> 15)) + (pcrExt & 0x01ff)
                    if startTime == nil then startTime = endTime end
                end
            end
            pos = pos + lenA
        end

        -- all done with this packet unless it carries a payload
        -- or if we are just looking for the last timestamp
        if payloadDataExists ~= 0 and backScan == nil then

            -- decode payload data
            if pid == 0 or pmt[pid] then -- program association / program map table(s)
                -- must interpret pointer field if payload_unit_start_indicator is set
                local buf2
                if payloadUnitStartIndicator ~= 0 then
                    -- skip to start of section
                    local pointerField = buff:byte(pos + 1)
                    pos = pos + 1 + pointerField
                    if pos >= pEnd then
                        et:Warn('Bad pointer field')
                        break
                    end
                    buf2 = substr(buff, pEnd - pLen, pLen)
                    pos = pos - (pEnd - pLen)
                else
                    -- not the start of a section
                    if sectLen[pid] == nil or sectLen[pid] == 0 then goto nextpacket end
                    local moreN = sectLen[pid] - #data[pid]
                    local size = pLen - pos
                    if size > moreN then size = moreN end
                    data[pid] = data[pid] .. substr(buff, pos, size)
                    if size ~= moreN then goto nextpacket end
                    -- we have the complete section now, so put into buf2 for parsing
                    buf2 = data[pid]
                    pos = 0
                    data[pid] = nil
                    fromStart[pid] = nil
                    sectLen[pid] = nil
                end
                local slen = #buf2 -- section length
                if pos + 8 > slen then
                    et:Warn('Truncated payload')
                    break
                end
                -- validate table ID
                local tableId = buf2:byte(pos + 1)
                local name = (tableID[tableId] or sprintf('Unknown (0x%x)', tableId)) .. ' Table'
                local expectedID = (pid ~= 0) and 0x02 or 0x00
                if tableId ~= expectedID then
                    if verbose > 1 then out:write('  (skipping ' .. name .. ')\n') end
                    needPID[pid] = nil
                    didPID[pid] = 1
                    goto nextpacket
                end
                -- validate section syntax indicator for parsed tables (PAT, PMT)
                local sectionSyntaxIndicator = buf2:byte(pos + 2) & 0xc0
                if sectionSyntaxIndicator ~= 0x80 then
                    et:Warn('Bad ' .. name)
                    break
                end
                local sectionLength = ExifTool.Get16u(buf2, pos + 1) & 0x0fff
                if sectionLength > 1021 then
                    et:Warn('Invalid ' .. name .. ' length')
                    break
                end
                if slen < sectionLength + 3 then -- (3 bytes for table_id + section_length)
                    -- must wait until we have the full section
                    data[pid] = substr(buf2, pos)
                    sectLen[pid] = sectionLength + 3
                    goto nextpacket
                end
                local programNumber = ExifTool.Get16u(buf2, pos + 3)
                local sectionNumber = buf2:byte(pos + 7)
                local lastSectionNumber = buf2:byte(pos + 8)
                if verbose > 1 then
                    out:write('  ' .. name .. ' length: ' .. sectionLength .. '\n')
                    if pid ~= 0 then
                        out:write('  Program No: ' .. programNumber .. '\n')
                    else
                        out:write(sprintf('  Stream ID:  0x%x\n', programNumber))
                    end
                    out:write('  Section No: ' .. sectionNumber .. '\n')
                    out:write('  Last Sect.: ' .. lastSectionNumber .. '\n')
                end
                local endSec = pos + sectionLength + 3 - 4 -- (don't read 4-byte CRC)
                pos = pos + 8
                if pid == 0 then
                    -- decode PAT (Program Association Table)
                    while pos <= endSec - 4 do
                        local progNum = ExifTool.Get16u(buf2, pos)
                        local programMapPID = ExifTool.Get16u(buf2, pos + 2) & 0x1fff
                        pmt[programMapPID] = progNum -- save our PMT PID's
                        local str = 'Program ' .. progNum .. ' Map'
                        pidName[programMapPID] = str
                        if didPID[programMapPID] == nil then needPID[programMapPID] = 1 end
                        if verbose > 0 then
                            out:write(sprintf('  PID(0x%.4x) --> %s\n', programMapPID, str))
                        end
                        pos = pos + 4
                    end
                else
                    -- decode PMT (Program Map Table)
                    if pos + 4 > slen then
                        et:Warn('Truncated PMT')
                        break
                    end
                    local pcrPid = ExifTool.Get16u(buf2, pos) & 0x1fff
                    local programInfoLength = ExifTool.Get16u(buf2, pos + 2) & 0x0fff
                    local str = 'Program ' .. programNumber .. ' Clock Reference'
                    pidName[pcrPid] = str
                    if verbose > 0 then
                        out:write(sprintf('  PID(0x%.4x) --> %s\n', pcrPid, str))
                    end
                    pos = pos + 4
                    if pos + programInfoLength > slen then
                        et:Warn('Truncated program info')
                        break
                    end
                    -- (upstream dumps program information descriptors here
                    --  when verbose > 1; deferred)
                    pos = pos + programInfoLength -- skip descriptors (for now)
                    while pos <= endSec - 5 do
                        local streamTypeV = buf2:byte(pos + 1)
                        local elementaryPid = ExifTool.Get16u(buf2, pos + 1) & 0x1fff
                        local esInfoLength = ExifTool.Get16u(buf2, pos + 3) & 0x0fff
                        local str2 = streamType[streamTypeV]
                        if not str2 then
                            str2 = (streamTypeV < 0x7f) and 'Reserved' or 'Private'
                        end
                        str2 = sprintf('%s (0x%.2x)', str2, streamTypeV)
                        str2 = 'Program ' .. programNumber .. ' ' .. str2
                        if verbose > 0 then
                            out:write(sprintf('  PID(0x%.4x) --> %s\n', elementaryPid, str2))
                        end
                        local group = str2:match('(Audio)') or str2:match('(Video)')
                        if group then
                            if pidName[elementaryPid] == nil then
                                et:HandleTag(tagTablePtr, group .. 'StreamType', streamTypeV)
                            end
                            -- we want to parse all Audio and Video streams
                            if didPID[elementaryPid] == nil then needPID[elementaryPid] = 1 end
                        end
                        -- save PID type and name string
                        pidName[elementaryPid] = str2
                        pidType[elementaryPid] = streamTypeV
                        pos = pos + 5
                        if pos + esInfoLength > slen then
                            -- upstream also sets $pos = $end here, but the
                            -- value is never read again after this loop
                            et:Warn('Truncated ES info')
                            break
                        end
                        -- parse elementary stream descriptors
                        local j = 0
                        while j < esInfoLength - 2 do
                            local descriptorTag = buf2:byte(pos + j + 1)
                            local descriptorLength = buf2:byte(pos + j + 2)
                            j = j + 2
                            if j + descriptorLength > esInfoLength then break end
                            local desc = substr(buf2, pos + j, descriptorLength)
                            j = j + descriptorLength
                            -- (upstream dumps ES descriptors when verbose > 1)
                            -- parse type-specific descriptor information (once)
                            if not didPID[pid] then
                                if descriptorTag == 0x81 then -- AC-3
                                    ParseAC3Descriptor(et, desc)
                                end
                            end
                        end
                        pos = pos + esInfoLength
                    end
                end
                -- $pos = $end + 4; -- skip CRC
            elseif didPID[pid] == nil then
                -- save data from the start of each elementary stream
                if payloadUnitStartIndicator ~= 0 then
                    if data[pid] then
                        -- we must have a whole section, so parse now
                        local moreP = ParsePID(et, pid, pidType[pid], pidName[pid], data[pid])
                        -- start fresh even if we couldn't process this PID yet
                        data[pid] = nil
                        fromStart[pid] = nil
                        if not moreP or moreP == 0 then
                            needPID[pid] = nil
                            didPID[pid] = 1
                            goto nextpacket
                        end
                        -- set flag indicating we found this PID but we still want more
                        needPID[pid] = -1
                    end
                    -- check for a PES header
                    if pos + 6 <= pEnd then
                        local startCode = ExifTool.Get32u(buff, pos)
                        if (startCode & 0xffffff00) == 0x00000100 then
                            local streamId = startCode & 0xff
                            local pesPacketLength = ExifTool.Get16u(buff, pos + 4)
                            if verbose > 1 then
                                out:write(sprintf('  Stream ID:  0x%.2x\n', streamId))
                                out:write('  Packet Len: ' .. pesPacketLength .. '\n')
                            end
                            pos = pos + 6
                            local skipPes = false
                            if not noSyntax[streamId] then
                                if pos + 3 > pEnd then skipPes = true end
                                if not skipPes then
                                    -- validate PES syntax
                                    local syntax = buff:byte(pos + 1) & 0xc0
                                    if syntax ~= 0x80 then
                                        -- upstream warns and takes `next`
                                        et:Warn('Bad PES syntax')
                                        skipPes = true
                                    else
                                        -- skip PES header
                                        local pesHeaderDataLength = buff:byte(pos + 3)
                                        pos = pos + 3 + pesHeaderDataLength
                                        if pos >= pEnd then skipPes = true end
                                    end
                                end
                            end
                            if not skipPes then
                                data[pid] = substr(buff, pos, pEnd - pos)
                                -- set flag that we read this payload from the start
                                fromStart[pid] = true
                                -- save the packet length
                                if pesPacketLength > 8 then
                                    packLen[pid] = pesPacketLength - 8 -- (where are the 8 extra bytes? - PH)
                                else
                                    packLen[pid] = nil
                                end
                            end
                        end
                    end
                else
                    if data[pid] == nil then
                        -- (vsys a6l dashcam GPS record doesn't have a start indicator)
                        if not gpsPID[pid] then goto nextpacket end
                        data[pid] = ''
                    end
                    -- accumulate data for each elementary stream
                    data[pid] = data[pid] .. substr(buff, pos, pEnd - pos)
                end
                -- save only the first 256 bytes of most streams, except for
                -- unknown, H.264 or metadata streams where we save up to 1 kB
                local saveLen
                if pidType[pid] == nil or pidType[pid] == 0 or pidType[pid] == 0x1b then
                    saveLen = 1024
                elseif pidType[pid] == 0x15 then
                    -- use 1024 or actual size of metadata packet if smaller
                    saveLen = 1024
                    if packLen[pid] and saveLen > packLen[pid] then saveLen = packLen[pid] end
                else
                    saveLen = 256
                end
                if #data[pid] >= saveLen then
                    local moreP = ParsePID(et, pid, pidType[pid], pidName[pid], data[pid])
                    if moreP and moreP < 0 then goto nextpacket end -- wait for program map table
                    -- don't stop parsing if we weren't successful and may have missed the start
                    if (not moreP or moreP == 0) and not fromStart[pid] then moreP = 1 end
                    data[pid] = nil
                    fromStart[pid] = nil
                    if moreP and moreP ~= 0 then
                        needPID[pid] = -1 -- parse more of these
                        goto nextpacket
                    end
                    needPID[pid] = nil
                    didPID[pid] = 1
                end
                goto nextpacket
            end
            if needPID[pid] then
                -- we found and parsed a section with this PID, so
                -- delete from our lookup of PID's we still need to parse
                needPID[pid] = nil
                didPID[pid] = 1
            end
        end
        ::nextpacket::
    end

    -- calculate Duration if available
    if endTime == nil then endTime = fwdTime end
    if startTime ~= nil and endTime ~= nil then
        if startTime > endTime then endTime = endTime + 0x80000000 * 1200 end -- handle 33-bit wrap
        et:HandleTag(tagTablePtr, 'Duration', endTime - startTime)
    end

    if verbose > 0 then
        local needList = {}
        for k, v in pairs(needPID) do
            if v and v > 0 then needList[#needList + 1] = sprintf('0x%.2x', k) end
        end
        if #needList > 0 then
            tsort(needList)
            out:write('End of file.  Missing PID(s): ' .. table.concat(needList, ' ') .. '\n')
        else
            local what = eof and 'of file' or 'scan'
            out:write('End ' .. what .. ".  All PID's parsed.\n")
        end
    end

    -- parse any remaining partial PID streams
    local remaining = {}
    for k in pairs(data) do remaining[#remaining + 1] = k end
    tsort(remaining)
    for _, pidR in ipairs(remaining) do
        ParsePID(et, pidR, pidType[pidR], pidName[pidR], data[pidR])
        data[pidR] = nil
    end

    -- look for LIGOGPSINFO trailer
    if ExifTool.perlTruthy(et:Options('ExtractEmbedded')) and raf:Seek(-8, 2) then
        local n2, buff2 = raf:Read(8)
        if n2 == 8 and matches(buff2, [[^&&&&]]) then
            local len = perl.unpack('x4N', buff2)
            if len < raf:Tell() and raf:Seek(-len, 2) then
                n2, buff2 = raf:Read(len)
                if n2 == len then
                    local tbl = et:GetTagTable('lexiftool.QuickTimeStream.Stream')
                    local dirInfo2 = { DataPt = buff2, DirStart = 8, DirName = 'LigoTrailer' }
                    require('lexiftool.LigoGPS').ProcessLigoGPS(et, dirInfo2, tbl)
                end
            end
        end
    end

    return 1
end

return M2TS
