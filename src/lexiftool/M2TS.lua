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
-- Port notes:   the whole module (read-only, as upstream).  Data refs
--               (\$data{$pid}, \$desc) are passed as strings; raf:Read
--               returns the byte count and the data, so `$raf->Read($buff,
--               N) == N` reads `n, buff = raf:Read(N)` first.  The labelled
--               `next Try` and the packet loop's `next` are gotos to labels
--               at the end of the loop bodies.  In ParsePID, an elsif that
--               tests a match and then reads its captures calls an inline
--               function that assigns them.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local isMatch, eachMatch, split, tr = perl.isMatch, perl.eachMatch, perl.split, perl.tr
local length, unpack, pack, join, abs = perl.length, perl.unpack, perl.pack, perl.join, math.abs
local num, lt, int = perl.num, perl.lt, perl.int
local subst, ord, at = perl.subst, perl.ord, perl.at
local print, printf, perlStr = perl.print, perl.printf, perl.str
local push, sort, keys = perl.push, perl.sort, perl.keys
local Get8u, Get16u, Get32u = ExifTool.Get8u, ExifTool.Get16u, ExifTool.Get32u
local perlTruthy = ExifTool.perlTruthy
local GetTagTable = ExifTool.GetTagTable
local SetByteOrder, GetFloat = ExifTool.SetByteOrder, ExifTool.GetFloat

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

local knotsToKph = 1.852     -- knots --> km/h

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
-- Inputs: 0) ExifTool ref, 1) data ref
-- Reference: http://www.atsc.org/standards/a_52b.pdf
local function ParseAC3Audio(et, dataPt)
    local ok, c1 = isMatch(dataPt, [[(?s)\x0b\x77..(.)]])
    if ok then
        local sampleRate = ord(c1) >> 6
        local tagTablePtr = GetTagTable(nil, 'lexiftool.M2TS.AC3')
        et:HandleTag(tagTablePtr, 'AudioSampleRate', sampleRate)
    end
end

--------------------------------------------------------------------------------
-- Extract information from AC-3 stream descriptor
-- Inputs: 0) ExifTool ref, 1) data ref
-- Reference: http://www.atsc.org/standards/a_52b.pdf
-- Note: This information is duplicated in the Audio stream, but it
--       is somewhat easier to extract it from the descriptor instead
local function ParseAC3Descriptor(et, dataPt)
    if length(dataPt) < 3 then return end
    local v = { unpack('C3', dataPt) }
    local tagTablePtr = GetTagTable(nil, 'lexiftool.M2TS.AC3')
    -- $et->HandleTag($tagTablePtr, 'AudioSampleRate', $v[0] >> 5);
    et:HandleTag(tagTablePtr, 'AudioBitrate', at(v, 1) >> 2)
    et:HandleTag(tagTablePtr, 'SurroundMode', at(v, 1) & 0x03)
    et:HandleTag(tagTablePtr, 'AudioChannels', (at(v, 2) >> 1) & 0x0f)
    -- don't (yet) decode any more (language codes, etc)
end

M2TS.ParseAC3Descriptor = ParseAC3Descriptor

--------------------------------------------------------------------------------
-- Parse PID stream data
-- Inputs: 0) ExifTool ref, 1) PID number, 2) PID type, 3) PID name, 4) data string
-- Returns: 0=stream parsed OK,
--          1=stream parsed but we want to parse more of these,
--          -1=can't parse yet because we don't know the type
local function ParsePID(et, pid, type_, pidName, dataPt)
    -- can't parse until we know the type (Program Map Table may be later in the stream)
    if type_ == nil then return -1 end
    local verbose = et:Options('Verbose')
    if num(verbose) > 1 then
        local out = et:Options('TextOut')
        perl.printf(out, "Parsing stream 0x%.4x (%s) %d bytes\n", pid, pidName, length(dataPt))
        et:VerboseDump(dataPt)
    end
    local more = 0
    if type_ == 0x01 or type_ == 0x02 then
        -- MPEG-1/MPEG-2 Video
        require('lexiftool.MPEG').ParseMPEGAudioVideo(et, dataPt)
    elseif type_ == 0x03 or type_ == 0x04 then
        -- MPEG-1/MPEG-2 Audio
        require('lexiftool.MPEG').ParseMPEGAudio(et, dataPt)
    elseif type_ == 6 and pid == 0x0300 then
        -- LIGOGPSINFO
        -- unknown dashcam (../testpics/gps_video/Wrong Way pass.ts, 160 bytes, not fuzzed)
        -- Pruveeo D90 dashcam (../testpics/gps_video/20260216_101326F.ts, 200 bytes, fuzzed)
        local ok, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, _, m13, m14, m15
        if isMatch(dataPt, [[(?s)^LIGOGPSINFO]]) then
            local tbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            local dirInfo = { DataPt = dataPt, DirName = 'Ligo0x0300' }
            require('lexiftool.LigoGPS').ProcessLigoGPS(et, dirInfo, tbl, (length(dataPt) ~= 200) and 1 or '') -- (Perl's != gives 1 or '')
            et.FoundGoodGPS = 1
            more = 1
        elseif (function()
                ok, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, _, m13, m14, m15 = isMatch(dataPt,
                    [[(?s)^Viidure(20\d{2})/(\d{2})/(\d{2}) (\d{2}:\d{2}:\d{2}) ([NS]):(\S+) ]] ..
                    [[([EW]):(\S+) (\S+) km/h (\S+) (\S+) (\S+) x:(\S+) y:(\S+) z:(\S+)]])
                return ok
            end)() then
            -- (Innovv N2 dashcam)
            -- 0000: 56 69 69 64 75 72 65 32 30 32 36 2f 30 34 2f 31 [Viidure2026/04/1]
            -- 0010: 36 20 30 31 3a 30 31 3a 30 32 20 4e 3a 34 32 2e [6 01:01:02 N:42.]
            -- 0020: 32 31 31 34 32 34 20 57 3a 38 38 2e 33 32 30 39 [211424 W:88.3209]
            -- 0030: 37 35 20 38 39 2e 31 20 6b 6d 2f 68 20 32 36 37 [75 89.1 km/h 267]
            -- 0040: 2e 33 38 20 32 33 37 2e 38 30 20 31 30 20 78 3a [.38 237.80 10 x:]
            -- 0050: 2d 30 2e 30 30 31 20 79 3a 2d 30 2e 30 30 31 20 [-0.001 y:-0.001 ]
            -- 0060: 7a 3a 2d 30 2e 30 30 31 00 00 00 00 00 00 00 00 [z:-0.001........]
            local tbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            local time = m1 .. ':' .. m2 .. ':' .. m3 .. ' ' .. m4 .. 'Z'
            et:HandleTag(tbl, 'GPSDateTime',  time)
            et:HandleTag(tbl, 'GPSLatitude',  num(m6) * ((m5 == 'S') and -1 or 1))
            et:HandleTag(tbl, 'GPSLongitude', num(m8) * ((m7 == 'W') and -1 or 1))
            et:HandleTag(tbl, 'GPSSpeed',     m9)
            et:HandleTag(tbl, 'GPSTrack',     m10)
            et:HandleTag(tbl, 'GPSAltitude',  m11)
            -- (not sure what $12 is -- was a constant "10" in my sample)
            et:HandleTag(tbl, 'Accelerometer', m13 .. ' ' .. m14 .. ' ' .. m15)
            et.FoundGoodGPS = 1
            more = 1
            et.DOC_NUM = nil
        end
    elseif type_ == 0x1b then
        -- H.264 Video
        more = require('lexiftool.H264').ParseH264Video(et, dataPt)
        -- force parsing additional H264 frames with ExtractEmbedded option
        if perlTruthy(et.OPTIONS.ExtractEmbedded) then
            more = 1
        elseif not perlTruthy(et.OPTIONS.Validate) then
            et:Warn('The ExtractEmbedded option may find more tags in the video data',7)
        end
    elseif type_ == 0x81 or type_ == 0x87 or type_ == 0x91 then
        -- AC-3 audio
        ParseAC3Audio(et, dataPt)
    elseif type_ == 0x15 then
        -- packetized metadata (look for MISB code starting after 5-byte header)
        if isMatch(dataPt, [[(?s)^.{5}\x06\x0e\x2b\x34]]) then
            more = require('lexiftool.MISB').ParseMISB(et, dataPt, GetTagTable(nil, 'lexiftool.MISB.Main'))
            if not perlTruthy(et.OPTIONS.ExtractEmbedded) then
                more = 0  -- extract from only the first packet unless ExtractEmbedded is used
            elseif num(et.OPTIONS.ExtractEmbedded) > 2 then
                more = 1  -- read past unknown 0x15 packets if ExtractEmbedded > 2
            end
        end
-- still have a lot of questions about how to decode this...
-- (see https://exiftool.org/forum/index.php?topic=16486 and ../testpics/gps_video/forum16486.ts)
--    } elsif ($type == 6) {
--        my @a = unpack('x17x2NNx2nx2nx2nx2Cx2a4x2a5x2Nx2Nx2nx2Nx2Nx2Nx2nx2nx2Nx2nx2n', $$dataPt . "        ");
--        my $hi = shift @a;
--        $a[0] = Image::ExifTool::ConvertUnixTime(($a[0] + $hi * 4294967296) * 1e-6, undef, 6);
--        print "@a\n";
--        $more = 1;
    elseif type_ < 0 then
        local ok, c1, c2, c3
        if (function()
                ok, c1 = isMatch(dataPt, [=[(?s)^(.{164})?(.{24})A[NS][EW]]=])
                return ok
            end)() then
            -- (Blueskysea B4K, Novatek NT96670)
            -- 0000: 01 00 ff 00 30 31 32 33 34 35 37 38 61 62 63 64 [....01234578abcd]
            -- 0010: 65 66 67 0a 00 00 00 00 00 00 00 00 00 00 00 00 [efg.............]
            -- 0020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
            -- 0030: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
            -- 0040: 00 00 00 00 30 31 32 33 34 35 37 38 71 77 65 72 [....01234578qwer]
            -- 0050: 74 79 75 69 6f 70 0a 00 00 00 00 00 00 00 00 00 [tyuiop..........]
            -- 0060: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
            -- 0070: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [................]
            -- 0080: 00 00 00 00 63 38 61 61 32 35 63 66 34 35 65 65 [....c8aa25cf45ee]
            -- 0090: 61 39 65 32 34 34 32 66 61 65 62 35 65 30 39 39 [a9e2442faeb5e099]
            -- 00a0: 30 37 64 34 15 00 00 00 10 00 00 00 1b 00 00 00 [07d4............]
            -- 00b0: 15 00 00 00 01 00 00 00 09 00 00 00 41 4e 57 00 [............ANW.]
            -- 00c0: 82 9a 57 45 98 b2 00 46 66 66 e4 41 d7 e3 14 43 [..WE...Fff.A...C]
            -- 00d0: 01 00 02 00 03 00 04 00 05 00 06 00             [............]
            -- (Viofo A119V3)
            -- 0000: 08 00 00 00 07 00 00 00 18 00 00 00 15 00 00 00 [................]
            -- 0010: 03 00 00 00 0b 00 00 00 41 4e 45 00 01 f2 ac 45 [........ANE....E]
            -- 0020: 2d 7f 6e 45 b8 1e 97 41 d7 23 46 43 00 00 00 00 [-.nE...A.#FC....]
            -- pad with dummy header and parse with existing FreeGPS code (minimum 92 bytes)
            local dat = ("\0"):rep(16) .. substr(dataPt, length(c1 or '')) .. ("\0"):rep(20)
            local tbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            require('lexiftool.QuickTimeStream').ProcessFreeGPS(et, { DataPt = dat }, tbl)
            more = 1
        elseif isMatch(dataPt, [[(?s)^(V00|A([NS])([EW]))\0]]) then
            -- INNOVV TS video (same format as INNOVV MP4)
            SetByteOrder('II')
            local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            for dat, d2 in eachMatch(dataPt, [[(?s)((V00|A[NS][EW])\0.{28})]]) do
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                if d2 ~= 'V00' then
                    local lat = abs(GetFloat(dat, 4)) -- (abs just to be safe)
                    local lon = abs(GetFloat(dat, 8)) -- (abs just to be safe)
                    local spd = GetFloat(dat, 12) * knotsToKph
                    local trk = GetFloat(dat, 16)
                    lat, lon = require('lexiftool.QuickTimeStream').ConvertLatLon(lat, lon)
                    et:HandleTag(tagTbl, 'GPSLatitude',  abs(lat) * (substr(dat,1,1) == 'S' and -1 or 1))
                    et:HandleTag(tagTbl, 'GPSLongitude', abs(lon) * (substr(dat,2,1) == 'W' and -1 or 1))
                    et:HandleTag(tagTbl, 'GPSSpeed',     spd)
                    et:HandleTag(tagTbl, 'GPSSpeedRef',  'K')
                    et:HandleTag(tagTbl, 'GPSTrack',     trk)
                    et:HandleTag(tagTbl, 'GPSTrackRef',  'T')
                end
                local acc = { unpack('x20V3', dat) }
                for i, v in ipairs(acc) do if v >= 0x80000000 then acc[i] = v - 4294967296 end end
                et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
            end
            SetByteOrder('MM')
            et.FoundGoodGPS = 1 -- (necessary to skip over empty/unknown INNOV records)
            more = 1
        elseif isMatch(dataPt, [[^\$(GPSINFO|GSNRINFO),]]) then
            -- $GPSINFO,0x0004,2021.08.09 13:27:36,2341.54561,12031.70135,8.0,51,153,0,0,\x0d
            -- $GSNRINFO,0.01,0.04,0.25\0
            dataPt = tr(dataPt, '\x0d', '\x0a')
            dataPt = tr(dataPt, '\0', '', 'd')
            local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            local lines = split([[\x0a]], dataPt)
            local lastTime
            for _, line in ipairs(lines) do
                if isMatch(line, [[^\$GPSINFO]]) then
                    local a = split(',', lines[1])
                    if #a <= 7 then goto nextLine end
                    -- ignore duplicate fixes
                    if perlTruthy(lastTime) and a[3] == lastTime then goto nextLine end
                    lastTime = a[3]
                    et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                    et.DOC_NUM = et.DOC_COUNT
                    a[3] = tr(a[3], '.', ':')
                    -- (untested, and probably doesn't work for S/W hemispheres)
                    local lat, lon = a[4], a[5]
                    lat, lon = require('lexiftool.QuickTimeStream').ConvertLatLon(num(lat), num(lon))
                    -- $a[0] - flags? values: '0x0001','0x0004','0x0008','0x0010'
                    et:HandleTag(tagTbl, 'GPSDateTime',  a[3])
                    et:HandleTag(tagTbl, 'GPSLatitude',  lat)
                    et:HandleTag(tagTbl, 'GPSLongitude', lon)
                    et:HandleTag(tagTbl, 'GPSSpeed',     a[6])
                    et:HandleTag(tagTbl, 'GPSSpeedRef',  'K')
                    -- $a[6] - values: 48-60
                    et:HandleTag(tagTbl, 'GPSTrack',     a[8])
                    et:HandleTag(tagTbl, 'GPSTrackRef',  'T')
                    -- #a[8,9] - always 0
                elseif isMatch(line, [[^\$GSNRINFO]]) then
                    local a = split(',', line)
                    perl.shift(a)
                    et:HandleTag(tagTbl, 'Accelerometer', join(' ', a))
                end
                ::nextLine::
            end
            more = 1
        elseif isMatch(dataPt, [[\$GPRMC,]]) then
            -- Jomise T860S-GM dashcam
            -- $GPRMC,hhmmss.ss,A,ddmm.mmmmm,N,dddmm.mmmmm,W,spd-kts,dir-dg,DDMMYY,,M*cs - lat,lon,spd from video
            -- $GPRMC,172255.00,A,:985.95194,N,17170.14674,W,029.678,170.68,240822,,,D*7B - N47.70428,W122.15338,35mph
            -- $GPRMC,192643.00,A,:987.94979,N,17171.07268,W,010.059,079.61,111122,,,A*73 - N47.71862,W122.16437,12mph
            -- $GPRMC,192743.00,A,:988.72110,N,17171.04873,W,017.477,001.03,111122,,,A*78 - N47.72421,W122.16408,20mph
            -- $GPRMC,192844.00,A,:989.43771,N,17171.03538,W,016.889,001.20,111122,,,A*7B - N47.72932,W122.16393,19mph
            -- $GPRMC,005241.00,A,:987.70873,N,17171.81293,W,000.284,354.78,141122,,,A*7F - N47.71687,W122.17318,0mph
            -- $GPRMC,005341.00,A,:987.90851,N,17171.85380,W,000.080,349.36,141122,,,A*7C - N47.71832,W122.17367,0mph
            -- $GPRMC,005441.00,A,:987.94538,N,17171.21783,W,029.686,091.09,141122,,,A*7A - N47.71859,W122.16630,35mph
            -- $GPRMC,002816.00,A,6820.67273,N,13424.26599,W,000.045,000.00,261122,,,A*79 - N29.52096,W95.55953,0mph (seattle)
            -- $GPRMC,035136.00,A,:981.47322,N,17170.14105,W,024.594,180.50,291122,,,D*79 - N47.67180,W122.15328,28mph
            local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            for m1, m2, m3, _, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15 in eachMatch(dataPt,
                    [[\$[A-Z]{2}RMC,(\d{2})(\d{2})(\d+(\.\d*)?),A?,(.{2})(\d{2}\.\d+),([NS]),(.{3})(\d{2}\.\d+),([EW]),]] ..
                    [[(\d*\.?\d*),(\d*\.?\d*),(\d{2})(\d{2})(\d+)]]) do
                -- do some basic sanity checks on the date
                if not (num(m13) <= 31 and num(m14) <= 12 and num(m15) <= 99) then break end
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                local year = m15 + (num(m15) >= 70 and 1900 or 2000)
                et:HandleTag(tagTbl, 'GPSDateTime', sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', year, m14, m13, m1, m2, m3))
                --(not this simple)
                --$et->HandleTag($tagTbl, GPSLatitude => (($5 || 0) + $6/60) * ($7 eq 'N' ? 1 : -1));
                --$et->HandleTag($tagTbl, GPSLongitude => (($8 || 0) + $9/60) * ($10 eq 'E' ? 1 : -1));
                if length(m11) ~= 0 then et:HandleTag(tagTbl, 'GPSSpeed', m11 * knotsToKph) end
                if length(m12) ~= 0 then et:HandleTag(tagTbl, 'GPSTrack', m12) end
                -- it looks like maybe the degrees are xor-ed with something,
                -- and the minutes have some scaling factor and offset?
                -- (the code below is approximately correct for my only sample)
                local chars = { unpack('C*', m5 .. m8) }
                local xor = { 0x0e,0x0e,0x00,0x05,0x03 } -- (empirical based on 1 sample; may be completely off base)
                local bad
                for i = 1, #chars do
                    chars[i] = chars[i] ~ (perl.shift(xor) or 0)
                    if chars[i] < 0x30 or chars[i] > 0x39 then bad = 1 end
                end
                if bad then
                    et:Warn('Error decrypting GPS degrees')
                else
                    local la = pack('C*', chars[1], chars[2])
                    local lo = pack('C*', chars[3], chars[4], chars[5])
                    et:Warn('Decryption of this GPS is highly experimental. More testing samples are required')
                    et:HandleTag(tagTbl, 'GPSLatitude',
                        ((perlTruthy(la) and num(la) or 0) + ((m6-85.95194)/2.43051724137931+42.2568)/60) * (m7 == 'N' and 1 or -1))
                    et:HandleTag(tagTbl, 'GPSLongitude',
                        ((perlTruthy(lo) and num(lo) or 0) + ((m9-70.14674)/1.460987654320988+9.2028)/60) * (m10 == 'E' and 1 or -1))
                end
            end
        elseif (function()
                ok, c1, c2, c3 = isMatch(dataPt, [[\$GSENSORD,\s*(\d+),\s*(\d+),\s*(\d+),]])
                return ok
            end)() then
            -- Jomise T860S-GM dashcam
            local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            et.DOC_NUM = et.DOC_COUNT
            et:HandleTag(tagTbl, 'Accelerometer', c1 .. ' ' .. c2 .. ' ' .. c3) -- (NC - values range from 0 to 6)
        elseif (function()
                ok, c1, c2 = isMatch(dataPt, [[(?s)^.{44}A\0{3}.{4}([NS])\0{3}.{4}([EW])\0{3}]])
                return ok
            end)() and length(dataPt) >= 84 then
            --forum11320
            SetByteOrder('II')
            local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            local lat = abs(GetFloat(dataPt, 48)) -- (abs just to be safe)
            local lon = abs(GetFloat(dataPt, 56)) -- (abs just to be safe)
            local spd = GetFloat(dataPt, 64)
            local trk = GetFloat(dataPt, 68)
            et:Warn('GPSLatitude/Longitude encryption is not yet known, so these will be wrong')
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            local date = { unpack('x32V3x28V3', dataPt) }
            date[4] = date[4] + 2000
            et:HandleTag(tagTbl, 'GPSDateTime',  sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d', date[4], date[5], date[6], date[1], date[2], date[3]))
            et:HandleTag(tagTbl, 'GPSLatitude',  abs(lat) * (c1 == 'S' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSLongitude', abs(lon) * (c2 == 'W' and -1 or 1))
            et:HandleTag(tagTbl, 'GPSSpeed',     spd)
            et:HandleTag(tagTbl, 'GPSSpeedRef',  'K')
            et:HandleTag(tagTbl, 'GPSTrack',     trk)
            et:HandleTag(tagTbl, 'GPSTrackRef',  'T')
            SetByteOrder('MM')
            more = 1
        elseif length(dataPt) >= 64 and substr(dataPt, 32, 2) == '$S' then
            -- DOD_LS600W.TS
            local tagTbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            -- find the earliest sample time in the cyclical list
            local n, last = 32, "\0"
            local i = 32
            while i < length(dataPt)-32 do
                if substr(dataPt, n, 2) ~= '$S' then break end
                local dateTime = substr(dataPt, i+6, 8)
                if lt(dateTime, last) then n = i break end -- earliest sample if time goes backwards
                last = dateTime
                i = i + 32
            end
            i = 32
            while i < length(dataPt)-32 do
                if n > length(dataPt)-32 then n = 32 end
                if substr(dataPt, n, 2) ~= '$S' then break end
                local a = { unpack('x' .. n .. 'nnnnCCCCnCNNC', dataPt) }
                a[9] = a[9] / 10    -- 1/10 sec
                if a[3] & 0x8000 ~= 0 then a[3] = a[3] + (36000 - 65536) end -- convert signed integer into range 0-36000
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
                et:HandleTag(tagTbl, 'GPSDateTime',  sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%04.1fZ', a[4], a[5], a[6], a[7], a[8], a[9]))
                et:HandleTag(tagTbl, 'GPSLatitude',  a[11] * 1e-7)
                et:HandleTag(tagTbl, 'GPSLongitude', a[12] * 1e-7)
                et:HandleTag(tagTbl, 'GPSSpeed',     a[2] * 0.036) -- convert from metres per 100 s
                et:HandleTag(tagTbl, 'GPSTrack',     a[3] / 100)
                i, n = i + 32, n + 32
            end
            -- Note: 10 bytes after last GPS record look like a single 3-axis accelerometer reading:
            -- eg. fd ff 00 00 ff ff 00 00 01 00
            et.FoundGoodGPS = 1 -- so we skip over unrecognized packets
            more = 1
        elseif isMatch(dataPt, [[(?s)^skip.{4}LIGOGPSINFO\0]]) then
            -- (this record contains 2 copies of the same 'skip' atom in my sample --
            --  only extract data from the first one)
            local tbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            local dirInfo = { DataPt = dataPt, DirStart = 8, DirName = sprintf('Ligo0x%.4x',pid) }
            require('lexiftool.LigoGPS').ProcessLigoGPS(et, dirInfo, tbl, 1)
            et.FoundGoodGPS = 1
        elseif perlTruthy(et.FoundGoodGPS) then
            more = 1
        end
        et.DOC_NUM = nil
    end
    return more
end

M2TS.ParsePID = ParsePID

--------------------------------------------------------------------------------
-- Extract information from a M2TS file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid M2TS file
function M2TS.ProcessM2TS(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, j, eof, pLen, readSize
    local pmt, pidType, data, sectLen, packLen, fromStart = {}, {}, {}, {}, {}, {}
    local startTime, endTime, fwdTime, backScan, maxBack
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local n     -- (byte count of each raf:Read -- Perl's Read returns it and fills $buff)

    -- read enough to guarantee 2 sync bytes
    n, buff = raf:Read(383); if n ~= 383 then return 0 end
    -- test for magic number (sync byte is the only thing we can safely check)
    local ok, c1, c2 = isMatch(buff, [[(?s)^(.{0,190}?)\x47(.{187}|.{191})\x47]])
    if not ok then return 0 end
    local tcLen = length(c2) - 187 -- (length of timecode = 0 or 4 bytes)
    local start = length(c1) - tcLen
    -- we may need to try the validation twice to handle the edge case
    -- where the first byte of a timecode is 0x47 and we were fooled
    -- into thinking there was no timecode
    while true do -- Try:
        if start < 0 then start = start + 192 end -- (if all or part of first timecode was missing)
        pLen = 188 + tcLen
        readSize = 64 * pLen      -- size of our read buffer
        raf:Seek(start, 0)        -- rewind to start
        n, buff = raf:Read(readSize); if n < pLen * 4 then return 0 end  -- require at least 4 packets
        -- validate the sync byte in the next 3 packets
        j = 1
        while j < 4 do
            if substr(buff, tcLen + pLen * j, 1) ~= 'G' then -- (0x47)
                if tcLen ~= 0 then return 0 end
                tcLen = 4
                start = start - 4
                goto Try    -- (next Try)
            end
            j = j + 1
        end
        break   -- success!
        ::Try::
    end
    -- (use M2T instead of M2TS just as an indicator that there is no timecode)
    et:SetFileType(tcLen ~= 0 and 'M2TS' or 'M2T')
    if start ~= 0 then et:Warn("File doesn't begin with the start of a packet") end
    SetByteOrder('MM')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.M2TS.Main')

    -- PID lookup strings (will add to this with entries from program map table)
    local pidName = {
        [0] = 'Program Association Table',
        [1] = 'Conditional Access Table',
        [2] = 'Transport Stream Description Table',
        [0x1fff] = 'Null Packet',
    }
    local didPID = { [1] = 0, [2] = 0, [0x1fff] = 0 }
    local needPID = { [0] = 1 }       -- lookup for stream PID's that we still need to parse
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
    if num(et:Options('ExtractEmbedded') or 0) > 2 then
        for k in pairs(gpsPID) do
            needPID[k] = 1
            pidType[k] = -1
            pidName[k] ='unregistered dashcam GPS'
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
                if perlTruthy(et:Options('FastScan')) then break end
                if perlTruthy(verbose) then print(out, "[Starting backscan for last PCR]\n") end
                -- remember how far we got when reading forward through the file
                local fwdPos = raf:Tell() - length(buff) + pEnd
                -- determine the position of the last packet relative to the EOF
                if not raf:Seek(0, 2) then break end
                local fsize = raf:Tell()
                backScan = int(fsize / pLen) * pLen - fsize
                -- set limit on how far back we will go
                maxBack = fwdPos - fsize
                -- scan back a maximum of 512k (have seen last PCR at -276k)
                local nMax = int(512000 / pLen)     -- max packets to backscan
                if nMax < int(-maxBack / pLen) then
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
            pEnd = pEnd - 2 * pLen; pos = pEnd  -- step back to previous packet
            if pos < 0 then
                -- read another buffer from end of file
                if backScan <= maxBack then break end
                local buffLen = backScan - maxBack
                if buffLen > readSize then buffLen = readSize end
                backScan = backScan - buffLen
                if not raf:Seek(backScan, 2) then break end
                n, buff = raf:Read(buffLen); if n ~= buffLen then break end
                pEnd = buffLen - pLen; pos = pEnd
            end
        else
            pos = pEnd
            if pos + pLen > length(buff) then
                n, buff = raf:Read(readSize); if n < pLen then eof = 1; break end
                pEnd = 0; pos = pEnd
            end
        end
        pEnd = pEnd + pLen
        -- decode the packet prefix
        pos = pos + tcLen
        local prefix = unpack('x' .. pos .. 'N', buff) -- (use unpack instead of Get32u for speed)
        -- validate sync byte
        if (prefix & 0xff000000) ~= 0x47000000 then
            if backScan == nil then et:Warn('M2TS synchronization error') end
            break
        end
      -- my $transport_error_indicator    = $prefix & 0x00800000;
        local payload_unit_start_indicator = prefix & 0x00400000
      -- my $transport_priority           = $prefix & 0x00200000;
        local pid                          =(prefix & 0x001fff00) >> 8 -- packet ID
      -- my $transport_scrambling_control = $prefix & 0x000000c0;
        local adaptation_field_exists      = prefix & 0x00000020
        local payload_data_exists          = prefix & 0x00000010
      -- my $continuity_counter           = $prefix & 0x0000000f;
        if verbose > 1 then
            local i = (raf:Tell() - length(buff) + pEnd) / pLen - 1
            print(out, "Transport packet " .. perlStr(i) .. ":\n")
            et:VerboseDump(buff, { Len = pLen, Addr = i * pLen, Start = pos - tcLen })
            local str = perlTruthy(pidName[pid]) and " (" .. pidName[pid] .. ")" or ' <not in Program Map Table!>'
            if pLen == 192 then printf(out, "  Timecode:   0x%.4x\n", Get32u(buff, pos - tcLen)) end
            printf(out, "  Packet ID:  0x%.4x" .. str .. "\n", pid)
            printf(out, "  Start Flag: %s\n", payload_unit_start_indicator ~= 0 and 'Yes' or 'No')
        end

        pos = pos + 4
        -- handle adaptation field
        if adaptation_field_exists ~= 0 then
            local len = Get8u(buff, pos); pos = pos + 1
            if pos + len > pEnd then et:Warn('Invalid adaptation field length'); break end
            -- read PCR value for calculation of Duration
            if len > 6 then
                local flags = Get8u(buff, pos)
                if flags & 0x10 ~= 0 then -- PCR_flag
                    -- combine 33-bit program_clock_reference_base and 9-bit extension
                    local pcrBase = Get32u(buff, pos + 1)
                    local pcrExt  = Get16u(buff, pos + 5)
                    -- ignore separate programs (PID's) and store just the
                    -- first and last timestamps found in the file (is this OK?)
                    endTime = 300 * (2 * pcrBase + (pcrExt >> 15)) + (pcrExt & 0x01ff)
                    if startTime == nil then startTime = endTime end
                end
            end
            pos = pos + len
        end

        -- all done with this packet unless it carries a payload
        -- or if we are just looking for the last timestamp
        if not (payload_data_exists ~= 0 and backScan == nil) then goto next end

       -- decode payload data
        if pid == 0 or              -- program association table
            pmt[pid] ~= nil         -- program map table(s)
        then
            -- must interpret pointer field if payload_unit_start_indicator is set
            local buf2
            if payload_unit_start_indicator ~= 0 then
                -- skip to start of section
                local pointer_field = Get8u(buff, pos)
                pos = pos + 1 + pointer_field
                if pos >= pEnd then et:Warn('Bad pointer field'); break end
                buf2 = substr(buff, pEnd-pLen, pLen)
                pos = pos - (pEnd - pLen)
            else
                -- not the start of a section
                if not perlTruthy(sectLen[pid]) then goto next end
                local more = sectLen[pid] - length(data[pid])
                local size = pLen - pos
                if size > more then size = more end
                data[pid] = data[pid] .. substr(buff, pos, size)
                if size ~= more then goto next end
                -- we have the complete section now, so put into $buf2 for parsing
                buf2 = data[pid]
                pos = 0
                data[pid] = nil
                fromStart[pid] = nil
                sectLen[pid] = nil
            end
            local slen = length(buf2)   -- section length
            if pos + 8 > slen then et:Warn('Truncated payload'); break end
            -- validate table ID
            local table_id = Get8u(buf2, pos)
            local name = (tableID[table_id] or sprintf('Unknown (0x%x)',table_id)) .. ' Table'
            local expectedID = pid ~= 0 and 0x02 or 0x00
            if table_id ~= expectedID then
                if verbose > 1 then print(out, "  (skipping " .. name .. ")\n") end
                needPID[pid] = nil
                didPID[pid] = 1
                goto next
            end
            -- validate section syntax indicator for parsed tables (PAT, PMT)
            local section_syntax_indicator = Get8u(buf2, pos + 1) & 0xc0
            if section_syntax_indicator ~= 0x80 then et:Warn("Bad " .. name); break end
            local section_length = Get16u(buf2, pos + 1) & 0x0fff
            if section_length > 1021 then et:Warn("Invalid " .. name .. " length"); break end
            if slen < section_length + 3 then -- (3 bytes for table_id + section_length)
                -- must wait until we have the full section
                data[pid] = substr(buf2, pos)
                sectLen[pid] = section_length + 3
                goto next
            end
            local program_number = Get16u(buf2, pos + 3)
            local section_number = Get8u(buf2, pos + 6)
            local last_section_number = Get8u(buf2, pos + 7)
            if verbose > 1 then
                print(out, "  " .. name .. " length: " .. section_length .. "\n")
                if pid ~= 0 then print(out, "  Program No: " .. program_number .. "\n") end
                if pid == 0 then printf(out, "  Stream ID:  0x%x\n", program_number) end
                print(out, "  Section No: " .. section_number .. "\n")
                print(out, "  Last Sect.: " .. last_section_number .. "\n")
            end
            local end_ = pos + section_length + 3 - 4 -- (don't read 4-byte CRC)
            pos = pos + 8
            if pid == 0 then
                -- decode PAT (Program Association Table)
                while pos <= end_ - 4 do
                    local program_number = Get16u(buf2, pos) -- luacheck: ignore 421
                    local program_map_PID = Get16u(buf2, pos + 2) & 0x1fff
                    pmt[program_map_PID] = program_number -- save our PMT PID's
                    local str = "Program " .. program_number .. " Map"
                    pidName[program_map_PID] = str
                    if not perlTruthy(didPID[program_map_PID]) then needPID[program_map_PID] = 1 end
                    if perlTruthy(verbose) then printf(out, "  PID(0x%.4x) --> " .. str .. "\n", program_map_PID) end
                    pos = pos + 4
                end
            else
                -- decode PMT (Program Map Table)
                if pos + 4 > slen then et:Warn('Truncated PMT'); break end
                local pcr_pid = Get16u(buf2, pos) & 0x1fff
                local program_info_length = Get16u(buf2, pos + 2) & 0x0fff
                local str = "Program " .. program_number .. " Clock Reference"
                pidName[pcr_pid] = str
                if perlTruthy(verbose) then printf(out, "  PID(0x%.4x) --> " .. str .. "\n", pcr_pid) end
                pos = pos + 4
                if pos + program_info_length > slen then et:Warn('Truncated program info'); break end
                -- dump program information descriptors if verbose
                if verbose > 1 then j = 0; while j<program_info_length-2 do
                    local descriptor_tag = Get8u(buf2, pos + j)
                    local descriptor_length = Get8u(buf2, pos + j + 1)
                    j = j + 2
                    if j + descriptor_length > program_info_length then break end
                    local desc = substr(buf2, pos+j, descriptor_length)
                    j = j + descriptor_length
                    desc = subst(desc, [[([\x00-\x1f\x7f-\xff])]], function(c) return sprintf("\\x%.2x",ord(c)) end, 'g')
                    printf(out, "    Program Descriptor: Type=0x%.2x \"" .. desc .. "\"\n", descriptor_tag)
                end end
                pos = pos + program_info_length -- skip descriptors (for now)
                while pos <= end_ - 5 do
                    local stream_type = Get8u(buf2, pos)
                    local elementary_pid = Get16u(buf2, pos + 1) & 0x1fff
                    local es_info_length = Get16u(buf2, pos + 3) & 0x0fff
                    local str = streamType[stream_type] -- luacheck: ignore 421
                    if not perlTruthy(str) then str = (stream_type < 0x7f and 'Reserved' or 'Private') end
                    str = sprintf('%s (0x%.2x)', str, stream_type)
                    str = "Program " .. program_number .. " " .. str
                    if perlTruthy(verbose) then printf(out, "  PID(0x%.4x) --> " .. str .. "\n", elementary_pid) end
                    local isAV, av = isMatch(str, [[(Audio|Video)]])
                    if isAV then
                        if not perlTruthy(pidName[elementary_pid]) then
                            et:HandleTag(tagTablePtr, av .. 'StreamType', stream_type)
                        end
                        -- we want to parse all Audio and Video streams
                        if not perlTruthy(didPID[elementary_pid]) then needPID[elementary_pid] = 1 end
                    end
                    -- save PID type and name string
                    pidName[elementary_pid] = str
                    pidType[elementary_pid] = stream_type
                    pos = pos + 5
                    if pos + es_info_length > slen then et:Warn('Truncated ES info'); pos = end_; break end -- luacheck: ignore 311
                    -- parse elementary stream descriptors
                    j = 0
                    while j<es_info_length-2 do
                        local descriptor_tag = Get8u(buf2, pos + j)
                        local descriptor_length = Get8u(buf2, pos + j + 1)
                        j = j + 2
                        if j + descriptor_length > es_info_length then break end
                        local desc = substr(buf2, pos+j, descriptor_length)
                        j = j + descriptor_length
                        if verbose > 1 then
                            local dstr = desc
                            dstr = subst(dstr, [[([\x00-\x1f\x7f-\xff])]], function(c) return sprintf("\\x%.2x",ord(c)) end, 'g')
                            printf(out, "    ES Descriptor: Type=0x%.2x \"" .. dstr .. "\"\n", descriptor_tag)
                        end
                        -- parse type-specific descriptor information (once)
                        if not perlTruthy(didPID[pid]) then
                            if descriptor_tag == 0x81 then  -- AC-3
                                ParseAC3Descriptor(et, desc)
                            end
                        end
                    end
                    pos = pos + es_info_length
                end
            end
            -- $pos = $end + 4; # skip CRC

        elseif didPID[pid] == nil then

            -- save data from the start of each elementary stream
            if payload_unit_start_indicator ~= 0 then
                if data[pid] ~= nil then
                    -- we must have a whole section, so parse now
                    local more = ParsePID(et, pid, pidType[pid], pidName[pid], data[pid])
                    -- start fresh even if we couldn't process this PID yet
                    data[pid] = nil
                    fromStart[pid] = nil
                    if not perlTruthy(more) then
                        needPID[pid] = nil
                        didPID[pid] = 1
                        goto next
                    end
                    -- set flag indicating we found this PID but we still want more
                    needPID[pid] = -1
                end
                -- check for a PES header
                if pos + 6 > pEnd then goto next end
                local start_code = Get32u(buff, pos)
                if (start_code & 0xffffff00) ~= 0x00000100 then goto next end
                local stream_id = start_code & 0xff
                local pes_packet_length = Get16u(buff, pos + 4)
                if verbose > 1 then
                    printf(out, "  Stream ID:  0x%.2x\n", stream_id)
                    print(out, "  Packet Len: " .. pes_packet_length .. "\n")
                end
                pos = pos + 6
                if not noSyntax[stream_id] then
                    if pos + 3 > pEnd then goto next end
                    -- validate PES syntax
                    local syntax = Get8u(buff, pos) & 0xc0
                    if syntax ~= 0x80 then et:Warn('Bad PES syntax'); goto next end
                    -- skip PES header
                    local pes_header_data_length = Get8u(buff, pos + 2)
                    pos = pos + 3 + pes_header_data_length
                    if pos >= pEnd then goto next end
                end
                data[pid] = substr(buff, pos, pEnd-pos)
                -- set flag that we read this payload from the start
                fromStart[pid] = 1
                -- save the packet length
                if pes_packet_length > 8 then
                    packLen[pid] = pes_packet_length - 8 -- (where are the 8 extra bytes? - PH)
                else
                    packLen[pid] = nil
                end
            else
                if data[pid] == nil then
                    -- (vsys a6l dashcam GPS record doesn't have a start indicator)
                    if not gpsPID[pid] then goto next end
                    data[pid] = ''
                end
                -- accumulate data for each elementary stream
                data[pid] = data[pid] .. substr(buff, pos, pEnd-pos)
            end
            -- save only the first 256 bytes of most streams, except for
            -- unknown, H.264 or metadata streams where we save up to 1 kB
            local saveLen
            if not perlTruthy(pidType[pid]) or pidType[pid] == 0x1b then
                saveLen = 1024
            elseif pidType[pid] == 0x15 then
                -- use 1024 or actual size of metadata packet if smaller
                saveLen = 1024
                if packLen[pid] ~= nil and saveLen > packLen[pid] then saveLen = packLen[pid] end
            else
                saveLen = 256
            end
            if length(data[pid]) >= saveLen then
                local more = ParsePID(et, pid, pidType[pid], pidName[pid], data[pid])
                if more < 0 then goto next end  -- wait for program map table (hopefully not too long)
                -- don't stop parsing if we weren't successful and may have missed the start
                if not perlTruthy(more) and not perlTruthy(fromStart[pid]) then more = 1 end
                data[pid] = nil
                fromStart[pid] = nil
                if perlTruthy(more) then needPID[pid] = -1; goto next end -- parse more of these
                needPID[pid] = nil
                didPID[pid] = 1
            end
            goto next
        end
        if perlTruthy(needPID[pid]) then
            -- we found and parsed a section with this PID, so
            -- delete from the lookup of PID's we still need to parse
            needPID[pid] = nil
            didPID[pid] = 1
        end
        ::next::
    end

    -- calculate Duration if available
    if endTime == nil then endTime = fwdTime end
    if startTime ~= nil and endTime ~= nil then
        if startTime > endTime then endTime = endTime + 0x80000000 * 1200 end -- handle 33-bit wrap
        et:HandleTag(tagTablePtr, 'Duration', endTime - startTime)
    end

    if perlTruthy(verbose) then
        local need = {}
        for k in pairs(needPID) do
            if needPID[k] > 0 then push(need, sprintf('0x%.2x',k)) end
        end
        if #need > 0 then
            need = sort(need)
            print(out, "End of file.  Missing PID(s): " .. join(' ', need) .. "\n")
        else
            local what = perlTruthy(eof) and 'of file' or 'scan'
            print(out, "End " .. what .. ".  All PID's parsed.\n")
        end
    end

    -- parse any remaining partial PID streams
    for _, pid in ipairs(sort(keys(data))) do
        ParsePID(et, pid, pidType[pid], pidName[pid], data[pid])
        data[pid] = nil
    end

    -- look for LIGOGPSINFO trailer
    if perlTruthy(et:Options('ExtractEmbedded')) and
        raf:Seek(-8, 2) and (function() n, buff = raf:Read(8); return n end)() == 8 and
        isMatch(buff, [[^&&&&]])
    then
        local len = unpack('x4N', buff)
        if len < raf:Tell() and raf:Seek(-len, 2) and (function() n, buff = raf:Read(len); return n end)() == len then
            local tbl = GetTagTable(nil, 'lexiftool.QuickTimeStream.Stream')
            local dirInfo_h = { DataPt = buff, DirStart = 8, DirName = 'LigoTrailer' }
            require('lexiftool.LigoGPS').ProcessLigoGPS(et, dirInfo_h, tbl)
        end
    end

    return 1
end

return M2TS

