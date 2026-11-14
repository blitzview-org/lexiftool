--------------------------------------------------------------------------------
-- File:         lexiftool/RIFF.lua
-- Ported from:  lib/Image/ExifTool/RIFF.pm
--
-- Description:  Read RIFF/AVI/WAV meta information
--
-- Revisions:    09/14/2005 - P. Harvey Created
--               06/28/2017 - PH Added MBWF/RF64 support
--
-- References:   1) http://www.exif.org/Exif2-2.PDF
--               2) http://www.vlsi.fi/datasheets/vs1011.pdf
--               3) http://www.music-center.com.br/spec_rif.htm
--               4) http://www.codeproject.com/audio/wavefiles.asp
--               5) http://msdn.microsoft.com/archive/en-us/directx9_c/directx/htm/avirifffilereference.asp
--               6) http://research.microsoft.com/invisible/tests/riff.h.htm
--               7) http://www.onicos.com/staff/iz/formats/wav.html
--               8) http://graphics.cs.uni-sb.de/NMM/dist-0.9.1/Docs/Doxygen/html/mmreg_8h-source.html
--               9) http://developers.videolan.org/vlc/vlc/doc/doxygen/html/codecs_8h-source.html
--              10) http://wiki.multimedia.cx/index.php?title=TwoCC
--              11) Andreas Winter (SCLive) private communication
--              12) http://abcavi.kibi.ru/infotags.htm
--              13) http://tech.ebu.ch/docs/tech/tech3285.pdf
--              14) https://developers.google.com/speed/webp/docs/riff_container
--              15) https://tech.ebu.ch/docs/tech/tech3306-2009.pdf
--              16) https://sites.google.com/site/musicgapi/technical-documents/wav-file-format
--
-- Port notes:   RIFF.pm in full: every table and sub in upstream order.  The
--               write-include WriteRIFF.pl is lexiftool/WriteRIFF.lua; the
--               AUTOLOAD that loads it is a closure at the predeclaration of
--               WriteRIFF.  Lua forms:
--               - Code refs to subs defined further down (PROCESS_PROC,
--                 ProcessProc) are `false` predeclarations assigned at the
--                 end of the file, or closures calling the later function.
--               - The string ProcessProc of gps0/gsen
--                 ('Image::ExifTool::QuickTime::Process_gps0') is a closure
--                 calling that function of QuickTime.lua.
--               - The Base eval of ProcessChunks calls the SubDirectory's
--                 Base function with $start as its third argument.
--               - CalcDuration takes the Composite's @val as the 0-based
--                 list it is handed.
--               - $$et{RIFFStreamCodec} is a table with 0-based keys.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local substr, length, ord = perl.substr, perl.length, perl.ord
local sprintf = perl.sprintf
local str, num, int, uv = perl.str, perl.num, perl.int, perl.uv
local matches, isMatch, isMatchDyn = perl.matches, perl.isMatch, perl.isMatchDyn
local subst, substN, tr = perl.subst, perl.substN, perl.tr
local split, join, map = perl.split, perl.join, perl.map
local unpack = perl.unpack
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local Get32u, Get64u = ExifTool.Get32u, ExifTool.Get64u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ConvertUnixTime = ExifTool.ConvertUnixTime
local ConvertDuration = ExifTool.ConvertDuration
local type_ = type     -- (upstream has a `$type` variable in ProcessRIFF)

local RIFF = {}

-- (upstream predeclarations `sub ConvertTimecode($); sub ProcessSGLT($$$);
--  sub ProcessSLLT($$$); sub ProcessLucas($$$);` -- the tables reach them
--  through closures over RIFF.X)
-- (`sub WriteRIFF($$);`: WriteRIFF is the sub of WriteRIFF.pl, which
--  upstream AUTOLOADs -- DoAutoLoad loads it on the first call.  Here it is a
--  closure that loads WriteRIFF.lua on first use)
function RIFF.WriteRIFF(...) return require('lexiftool.WriteRIFF').WriteRIFF(...) end

-- RIFF chunks containing image data (to include in ImageDataHash digest)
local isImageData = {
    LIST_movi = 1, -- (AVI: contains ##db, ##dc, ##wb)
    data = 1,      -- (WAV)
    ['VP8 ']=1, VP8L=1, ANIM=1, ANMF=1, ALPH=1, -- (WebP)
}

-- recognized RIFF variants
local riffType = {
    ['WAVE'] = 'WAV', ['AVI '] = 'AVI', ['WEBP'] = 'WEBP',
    ['LA02'] = 'LA',  ['LA03'] = 'LA',  ['LA04'] = 'LA',
    ['OFR '] = 'OFR', ['LPAC'] = 'PAC', ['wvpk'] = 'WV',
}

-- MIME types of recognized RIFF-format files
local riffMimeType = {
    WAV  = 'audio/x-wav',
    AVI  = 'video/x-msvideo',
    WEBP = 'image/webp',
    LA   = 'audio/x-nspaudio',
    OFR  = 'audio/x-ofr',
    PAC  = 'audio/x-lpac',
    WV   = 'audio/x-wavpack',
}

-- character sets for recognized Windows code pages
local code2charset = { -- luacheck: ignore 211 (unused upstream as well)
    [0]     = 'Latin',
    [65001] = 'UTF8',
    [1252]  = 'Latin',
    [1250]  = 'Latin2',
    [1251]  = 'Cyrillic',
    [1253]  = 'Greek',
    [1254]  = 'Turkish',
    [1255]  = 'Hebrew',
    [1256]  = 'Arabic',
    [1257]  = 'Baltic',
    [1258]  = 'Vietnam',
    [874]   = 'Thai',
    [10000] = 'MacRoman',
    [10029] = 'MacLatin2',
    [10007] = 'MacCyrillic',
    [10006] = 'MacGreek',
    [10081] = 'MacTurkish',
    [10010] = 'MacRomanian',
    [10079] = 'MacIceland',
    [10082] = 'MacCroatian',
}

RIFF.audioEncoding = { -- #2
    Notes = 'These "TwoCC" audio encoding codes are used in RIFF and ASF files.',
    [0x01] = 'Microsoft PCM',
    [0x02] = 'Microsoft ADPCM',
    [0x03] = 'Microsoft IEEE float',
    [0x04] = 'Compaq VSELP', -- #4
    [0x05] = 'IBM CVSD', -- #4
    [0x06] = 'Microsoft a-Law',
    [0x07] = 'Microsoft u-Law',
    [0x08] = 'Microsoft DTS', -- #4
    [0x09] = 'DRM', -- #4
    [0x0a] = 'WMA 9 Speech', -- #9
    [0x0b] = 'Microsoft Windows Media RT Voice', -- #10
    [0x10] = 'OKI-ADPCM',
    [0x11] = 'Intel IMA/DVI-ADPCM',
    [0x12] = 'Videologic Mediaspace ADPCM', -- #4
    [0x13] = 'Sierra ADPCM', -- #4
    [0x14] = 'Antex G.723 ADPCM', -- #4
    [0x15] = 'DSP Solutions DIGISTD',
    [0x16] = 'DSP Solutions DIGIFIX',
    [0x17] = 'Dialoic OKI ADPCM', -- #6
    [0x18] = 'Media Vision ADPCM', -- #6
    [0x19] = 'HP CU', -- #7
    [0x1a] = 'HP Dynamic Voice', -- #10
    [0x20] = 'Yamaha ADPCM', -- #6
    [0x21] = 'SONARC Speech Compression', -- #6
    [0x22] = 'DSP Group True Speech', -- #6
    [0x23] = 'Echo Speech Corp.', -- #6
    [0x24] = 'Virtual Music Audiofile AF36', -- #6
    [0x25] = 'Audio Processing Tech.', -- #6
    [0x26] = 'Virtual Music Audiofile AF10', -- #6
    [0x27] = 'Aculab Prosody 1612', -- #7
    [0x28] = 'Merging Tech. LRC', -- #7
    [0x30] = 'Dolby AC2',
    [0x31] = 'Microsoft GSM610',
    [0x32] = 'MSN Audio', -- #6
    [0x33] = 'Antex ADPCME', -- #6
    [0x34] = 'Control Resources VQLPC', -- #6
    [0x35] = 'DSP Solutions DIGIREAL', -- #6
    [0x36] = 'DSP Solutions DIGIADPCM', -- #6
    [0x37] = 'Control Resources CR10', -- #6
    [0x38] = 'Natural MicroSystems VBX ADPCM', -- #6
    [0x39] = 'Crystal Semiconductor IMA ADPCM', -- #6
    [0x3a] = 'Echo Speech ECHOSC3', -- #6
    [0x3b] = 'Rockwell ADPCM',
    [0x3c] = 'Rockwell DIGITALK',
    [0x3d] = 'Xebec Multimedia', -- #6
    [0x40] = 'Antex G.721 ADPCM',
    [0x41] = 'Antex G.728 CELP',
    [0x42] = 'Microsoft MSG723', -- #7
    [0x43] = 'IBM AVC ADPCM', -- #10
    [0x45] = 'ITU-T G.726', -- #9
    [0x50] = 'Microsoft MPEG',
    [0x51] = 'RT23 or PAC', -- #7
    [0x52] = 'InSoft RT24', -- #4
    [0x53] = 'InSoft PAC', -- #4
    [0x55] = 'MP3',
    [0x59] = 'Cirrus', -- #7
    [0x60] = 'Cirrus Logic', -- #6
    [0x61] = 'ESS Tech. PCM', -- #6
    [0x62] = 'Voxware Inc.', -- #6
    [0x63] = 'Canopus ATRAC', -- #6
    [0x64] = 'APICOM G.726 ADPCM',
    [0x65] = 'APICOM G.722 ADPCM',
    [0x66] = 'Microsoft DSAT', -- #6
    [0x67] = 'Microsoft DSAT DISPLAY', -- #6
    [0x69] = 'Voxware Byte Aligned', -- #7
    [0x70] = 'Voxware AC8', -- #7
    [0x71] = 'Voxware AC10', -- #7
    [0x72] = 'Voxware AC16', -- #7
    [0x73] = 'Voxware AC20', -- #7
    [0x74] = 'Voxware MetaVoice', -- #7
    [0x75] = 'Voxware MetaSound', -- #7
    [0x76] = 'Voxware RT29HW', -- #7
    [0x77] = 'Voxware VR12', -- #7
    [0x78] = 'Voxware VR18', -- #7
    [0x79] = 'Voxware TQ40', -- #7
    [0x7a] = 'Voxware SC3', -- #10
    [0x7b] = 'Voxware SC3', -- #10
    [0x80] = 'Soundsoft', -- #6
    [0x81] = 'Voxware TQ60', -- #7
    [0x82] = 'Microsoft MSRT24', -- #7
    [0x83] = 'AT&T G.729A', -- #7
    [0x84] = 'Motion Pixels MVI MV12', -- #7
    [0x85] = 'DataFusion G.726', -- #7
    [0x86] = 'DataFusion GSM610', -- #7
    [0x88] = 'Iterated Systems Audio', -- #7
    [0x89] = 'Onlive', -- #7
    [0x8a] = 'Multitude, Inc. FT SX20', -- #10
    [0x8b] = 'Infocom ITS A/S G.721 ADPCM', -- #10
    [0x8c] = 'Convedia G729', -- #10
    [0x8d] = 'Not specified congruency, Inc.', -- #10
    [0x91] = 'Siemens SBC24', -- #7
    [0x92] = 'Sonic Foundry Dolby AC3 APDIF', -- #7
    [0x93] = 'MediaSonic G.723', -- #8
    [0x94] = 'Aculab Prosody 8kbps', -- #8
    [0x97] = 'ZyXEL ADPCM', -- #7,
    [0x98] = 'Philips LPCBB', -- #7
    [0x99] = 'Studer Professional Audio Packed', -- #7
    [0xa0] = 'Malden PhonyTalk', -- #8
    [0xa1] = 'Racal Recorder GSM', -- #10
    [0xa2] = 'Racal Recorder G720.a', -- #10
    [0xa3] = 'Racal G723.1', -- #10
    [0xa4] = 'Racal Tetra ACELP', -- #10
    [0xb0] = 'NEC AAC NEC Corporation', -- #10
    [0xff] = 'AAC', -- #10
    [0x100] = 'Rhetorex ADPCM', -- #6
    [0x101] = 'IBM u-Law', -- #3
    [0x102] = 'IBM a-Law', -- #3
    [0x103] = 'IBM ADPCM', -- #3
    [0x111] = 'Vivo G.723', -- #7
    [0x112] = 'Vivo Siren', -- #7
    [0x120] = 'Philips Speech Processing CELP', -- #10
    [0x121] = 'Philips Speech Processing GRUNDIG', -- #10
    [0x123] = 'Digital G.723', -- #7
    [0x125] = 'Sanyo LD ADPCM', -- #8
    [0x130] = 'Sipro Lab ACEPLNET', -- #8
    [0x131] = 'Sipro Lab ACELP4800', -- #8
    [0x132] = 'Sipro Lab ACELP8V3', -- #8
    [0x133] = 'Sipro Lab G.729', -- #8
    [0x134] = 'Sipro Lab G.729A', -- #8
    [0x135] = 'Sipro Lab Kelvin', -- #8
    [0x136] = 'VoiceAge AMR', -- #10
    [0x140] = 'Dictaphone G.726 ADPCM', -- #8
    [0x150] = 'Qualcomm PureVoice', -- #8
    [0x151] = 'Qualcomm HalfRate', -- #8
    [0x155] = 'Ring Zero Systems TUBGSM', -- #8
    [0x160] = 'Microsoft Audio1', -- #8
    [0x161] = 'Windows Media Audio V2 V7 V8 V9 / DivX audio (WMA) / Alex AC3 Audio', -- #10
    [0x162] = 'Windows Media Audio Professional V9', -- #10
    [0x163] = 'Windows Media Audio Lossless V9', -- #10
    [0x164] = 'WMA Pro over S/PDIF', -- #10
    [0x170] = 'UNISYS NAP ADPCM', -- #10
    [0x171] = 'UNISYS NAP ULAW', -- #10
    [0x172] = 'UNISYS NAP ALAW', -- #10
    [0x173] = 'UNISYS NAP 16K', -- #10
    [0x174] = 'MM SYCOM ACM SYC008 SyCom Technologies', -- #10
    [0x175] = 'MM SYCOM ACM SYC701 G726L SyCom Technologies', -- #10
    [0x176] = 'MM SYCOM ACM SYC701 CELP54 SyCom Technologies', -- #10
    [0x177] = 'MM SYCOM ACM SYC701 CELP68 SyCom Technologies', -- #10
    [0x178] = 'Knowledge Adventure ADPCM', -- #10
    [0x180] = 'Fraunhofer IIS MPEG2AAC', -- #10
    [0x190] = 'Digital Theater Systems DTS DS', -- #10
    [0x200] = 'Creative Labs ADPCM', -- #6
    [0x202] = 'Creative Labs FASTSPEECH8', -- #6
    [0x203] = 'Creative Labs FASTSPEECH10', -- #6
    [0x210] = 'UHER ADPCM', -- #8
    [0x215] = 'Ulead DV ACM', -- #10
    [0x216] = 'Ulead DV ACM', -- #10
    [0x220] = 'Quarterdeck Corp.', -- #6
    [0x230] = 'I-Link VC', -- #8
    [0x240] = 'Aureal Semiconductor Raw Sport', -- #8
    [0x241] = 'ESST AC3', -- #10
    [0x250] = 'Interactive Products HSX', -- #8
    [0x251] = 'Interactive Products RPELP', -- #8
    [0x260] = 'Consistent CS2', -- #8
    [0x270] = 'Sony SCX', -- #8
    [0x271] = 'Sony SCY', -- #10
    [0x272] = 'Sony ATRAC3', -- #10
    [0x273] = 'Sony SPC', -- #10
    [0x280] = 'TELUM Telum Inc.', -- #10
    [0x281] = 'TELUMIA Telum Inc.', -- #10
    [0x285] = 'Norcom Voice Systems ADPCM', -- #10
    [0x300] = 'Fujitsu FM TOWNS SND', -- #6
    [0x301] = 'Fujitsu (not specified)', -- #10
    [0x302] = 'Fujitsu (not specified)', -- #10
    [0x303] = 'Fujitsu (not specified)', -- #10
    [0x304] = 'Fujitsu (not specified)', -- #10
    [0x305] = 'Fujitsu (not specified)', -- #10
    [0x306] = 'Fujitsu (not specified)', -- #10
    [0x307] = 'Fujitsu (not specified)', -- #10
    [0x308] = 'Fujitsu (not specified)', -- #10
    [0x350] = 'Micronas Semiconductors, Inc. Development', -- #10
    [0x351] = 'Micronas Semiconductors, Inc. CELP833', -- #10
    [0x400] = 'Brooktree Digital', -- #6
    [0x401] = 'Intel Music Coder (IMC)', -- #10
    [0x402] = 'Ligos Indeo Audio', -- #10
    [0x450] = 'QDesign Music', -- #8
    [0x500] = 'On2 VP7 On2 Technologies', -- #10
    [0x501] = 'On2 VP6 On2 Technologies', -- #10
    [0x680] = 'AT&T VME VMPCM', -- #7
    [0x681] = 'AT&T TCP', -- #8
    [0x700] = 'YMPEG Alpha (dummy for MPEG-2 compressor)', -- #10
    [0x8ae] = 'ClearJump LiteWave (lossless)', -- #10
    [0x1000] = 'Olivetti GSM', -- #6
    [0x1001] = 'Olivetti ADPCM', -- #6
    [0x1002] = 'Olivetti CELP', -- #6
    [0x1003] = 'Olivetti SBC', -- #6
    [0x1004] = 'Olivetti OPR', -- #6
    [0x1100] = 'Lernout & Hauspie', -- #6
    [0x1101] = 'Lernout & Hauspie CELP codec', -- #10
    [0x1102] = 'Lernout & Hauspie SBC codec', -- #10
    [0x1103] = 'Lernout & Hauspie SBC codec', -- #10
    [0x1104] = 'Lernout & Hauspie SBC codec', -- #10
    [0x1400] = 'Norris Comm. Inc.', -- #6
    [0x1401] = 'ISIAudio', -- #7
    [0x1500] = 'AT&T Soundspace Music Compression', -- #7
    [0x181c] = 'VoxWare RT24 speech codec', -- #10
    [0x181e] = 'Lucent elemedia AX24000P Music codec', -- #10
    [0x1971] = 'Sonic Foundry LOSSLESS', -- #10
    [0x1979] = 'Innings Telecom Inc. ADPCM', -- #10
    [0x1c07] = 'Lucent SX8300P speech codec', -- #10
    [0x1c0c] = 'Lucent SX5363S G.723 compliant codec', -- #10
    [0x1f03] = 'CUseeMe DigiTalk (ex-Rocwell)', -- #10
    [0x1fc4] = 'NCT Soft ALF2CD ACM', -- #10
    [0x2000] = 'FAST Multimedia DVM', -- #7
    [0x2001] = 'Dolby DTS (Digital Theater System)', -- #10
    [0x2002] = 'RealAudio 1 / 2 14.4', -- #10
    [0x2003] = 'RealAudio 1 / 2 28.8', -- #10
    [0x2004] = 'RealAudio G2 / 8 Cook (low bitrate)', -- #10
    [0x2005] = 'RealAudio 3 / 4 / 5 Music (DNET)', -- #10
    [0x2006] = 'RealAudio 10 AAC (RAAC)', -- #10
    [0x2007] = 'RealAudio 10 AAC+ (RACP)', -- #10
    [0x2500] = 'Reserved range to 0x2600 Microsoft', -- #10
    [0x3313] = 'makeAVIS (ffvfw fake AVI sound from AviSynth scripts)', -- #10
    [0x4143] = 'Divio MPEG-4 AAC audio', -- #10
    [0x4201] = 'Nokia adaptive multirate', -- #10
    [0x4243] = 'Divio G726 Divio, Inc.', -- #10
    [0x434c] = 'LEAD Speech', -- #10
    [0x564c] = 'LEAD Vorbis', -- #10
    [0x5756] = 'WavPack Audio', -- #10
    [0x674f] = 'Ogg Vorbis (mode 1)', -- #10
    [0x6750] = 'Ogg Vorbis (mode 2)', -- #10
    [0x6751] = 'Ogg Vorbis (mode 3)', -- #10
    [0x676f] = 'Ogg Vorbis (mode 1+)', -- #10
    [0x6770] = 'Ogg Vorbis (mode 2+)', -- #10
    [0x6771] = 'Ogg Vorbis (mode 3+)', -- #10
    [0x7000] = '3COM NBX 3Com Corporation', -- #10
    [0x706d] = 'FAAD AAC', -- #10
    [0x7a21] = 'GSM-AMR (CBR, no SID)', -- #10
    [0x7a22] = 'GSM-AMR (VBR, including SID)', -- #10
    [0xa100] = 'Comverse Infosys Ltd. G723 1', -- #10
    [0xa101] = 'Comverse Infosys Ltd. AVQSBC', -- #10
    [0xa102] = 'Comverse Infosys Ltd. OLDSBC', -- #10
    [0xa103] = 'Symbol Technologies G729A', -- #10
    [0xa104] = 'VoiceAge AMR WB VoiceAge Corporation', -- #10
    [0xa105] = 'Ingenient Technologies Inc. G726', -- #10
    [0xa106] = 'ISO/MPEG-4 advanced audio Coding', -- #10
    [0xa107] = 'Encore Software Ltd G726', -- #10
    [0xa109] = 'Speex ACM Codec xiph.org', -- #10
    [0xdfac] = 'DebugMode SonicFoundry Vegas FrameServer ACM Codec', -- #10
    [0xe708] = 'Unknown -', -- #10
    [0xf1ac] = 'Free Lossless Audio Codec FLAC', -- #10
    [0xfffe] = 'Extensible', -- #7
    [0xffff] = 'Development', -- #4
}


RIFF.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = [[
        The RIFF container format is used various types of fines including AVI, WAV,
        WEBP, LA, OFR, PAC and WV.  According to the EXIF specification, Meta
        information is embedded in two types of RIFF C<LIST> chunks: C<INFO> and
        C<exif>, and information about the audio content is stored in the C<fmt >
        chunk.  As well as this information, some video information and proprietary
        manufacturer-specific information is also extracted.

        Large AVI videos may be a concatenation of two or more RIFF chunks.  For
        these files, information is extracted from subsequent RIFF chunks as
        sub-documents, but the Duration is calculated for the full video.

        ExifTool currently has the ability to write EXIF, XMP and ICC_Profile
        metadata to WEBP images, but can't yet write to other RIFF-based formats.
    ]],
    -- (not 100% sure that the concatenation technique mentioned above is valid - PH)
    ['fmt '] = {
        Name = 'AudioFormat',
        SubDirectory = { TagTable = 'lexiftool.RIFF.AudioFormat' },
    },
    ['bext'] = {
        Name = 'BroadcastExtension',
        SubDirectory = { TagTable = 'lexiftool.RIFF.BroadcastExt' },
    },
    ds64 = { -- #15
        Name = 'DataSize64',
        SubDirectory = { TagTable = 'lexiftool.RIFF.DS64' },
    },
    list = 'ListType',  -- #15
    labl = { -- #16 (in 'adtl' chunk)
        Name = 'CuePointLabel',
        Priority = 0, -- (so they are stored in sequence)
        ValueConv = function(_self, val)
            local str_ = substr(val, 4); str_ = subst(str_, [[\0+$]], ''); return str(unpack('V', val)) .. ' ' .. str_
        end,
    },
    note = { -- #16 (in 'adtl' chunk)
        Name = 'CuePointNote',
        Priority = 0, -- (so they are stored in sequence)
        ValueConv = function(_self, val)
            local str_ = substr(val, 4); str_ = subst(str_, [[\0+$]], ''); return str(unpack('V', val)) .. ' ' .. str_
        end,
    },
    ltxt = { -- #16 (in 'adtl' chunk)
        Name = 'LabeledText',
        Notes = 'CuePointID Length Purpose Country Language Dialect Codepage Text',
        Priority = 0, -- (so they are stored in sequence)
        ValueConv = function(_self, val)
            local a = { unpack('VVa4vvvv', val) }
            a[3] = "'" .. a[3] .. "'"
            local txt = substr(val, 18)
            txt = subst(txt, [[\0+$]], '')   -- remove null terminator
            a[#a + 1] = txt
            return join(' ', a)
        end,
    },
    smpl = { -- #16
        Name = 'Sampler',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Sampler' },
    },
    inst = { -- #16
        Name = 'Instrument',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Instrument' },
    },
    LIST_INFO = {
        Name = 'Info',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Info' },
    },
    LIST_exif = {
        Name = 'Exif',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Exif' },
    },
    LIST_hdrl = { -- AVI header LIST chunk
        Name = 'Hdrl',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Hdrl' },
    },
    LIST_Tdat = { -- #PH (Adobe CS3 Bridge)
        Name = 'Tdat',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Tdat' },
    },
    LIST_ncdt = { -- #PH (Nikon metadata)
        Name = 'NikonData',
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.AVI',
            -- define ProcessProc here so we don't need to load RIFF.pm from Nikon.pm
            ProcessProc = function(...) return RIFF.ProcessChunks(...) end,
        },
    },
    LIST_hydt = { -- #PH (Pentax metadata)
        Name = 'PentaxData',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.AVI',
            ProcessProc = function(...) return RIFF.ProcessChunks(...) end,
        },
    },
    LIST_pntx = { -- #Andras Salamon (Q-S1 AVI)
        Name = 'PentaxData2',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.AVI',
            ProcessProc = function(...) return RIFF.ProcessChunks(...) end,
        },
    },
    LIST_adtl = { -- #PH (ref 16, forum12387)
        Name = 'AssociatedDataList',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Main' },
    },
    -- seen LIST_JUNK
    JUNK = {
        {
            Name = 'OlympusJunk',
            Condition = function(_self, valPt) return isMatch(valPt, [[^OLYMDigital Camera]]) end,
            SubDirectory = { TagTable = 'lexiftool.Olympus.AVI' },
        },
        {
            Name = 'CasioJunk',
            Condition = function(_self, valPt) return isMatch(valPt, [[^QVMI]]) end,
            -- Casio stores standard EXIF-format information in AVI videos (EX-S600)
            SubDirectory = {
                TagTable = 'lexiftool.Exif.Main',
                DirName = 'IFD0',
                Multi = 0, -- (IFD1 is not written)
                Start = 10,
                ByteOrder = 'BigEndian',
            },
        },
        {
            Name = 'RicohJunk',
            -- the Ricoh Caplio GX stores sub-chunks in here
            Condition = function(_self, valPt) return isMatch(valPt, [[^ucmt]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.Ricoh.AVI',
                ProcessProc = function(...) return RIFF.ProcessChunks(...) end,
            },
        },
        {
            Name = 'PentaxJunk', -- (Optio RS1000)
            Condition = function(_self, valPt) return isMatch(valPt, [[^IIII\x01\0]]) end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.Junk' },
        },
        {
            Name = 'PentaxJunk2', -- (Optio RZ18)
            Condition = function(_self, valPt) return isMatch(valPt, [[^PENTDigital Camera]]) end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.Junk2' },
        },
        {
            Name = 'LucasJunk', -- (Lucas LK-7900 Ace)
            Condition = function(_self, valPt) return isMatch(valPt, [[^0G(DA|PS)]]) end,
            SubDirectory = {
                TagTable = 'lexiftool.QuickTimeStream.Stream',
                ProcessProc = function(...) return RIFF.ProcessLucas(...) end,
            },
        },
        {
            Name = 'TextJunk',
            -- try to interpret unknown junk as an ASCII string
            RawConv = function(_self, val)
                local ok, c1 = isMatch(val, [[^([^\0-\x1f\x7f-\xff]+)\0*$]]); if ok then return c1 end; return nil
            end,
        }
    },
    _PMX = { -- #PH (Adobe CS3 Bridge)
        Name = 'XMP',
        Notes = 'AVI and WAV files',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    JUNQ = { -- #PH (Adobe CS3 Bridge)
        -- old XMP is preserved when metadata is replaced in Bridge
        Name = 'OldXMP',
        Binary = 1,
    },
    C2PA = { -- #https://c2pa.org/specifications/
        Name = 'JUMBF',
        Deletable = 1,
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main' },
    },
    olym = {
        Name = 'Olym',
        SubDirectory = { TagTable = 'lexiftool.Olympus.WAV' },
    },
    fact = {
        Name = 'NumberOfSamples',
        RawConv = function(_self, val) return Get32u(val, 0) end,
    },
    ['cue '] = {
        Name = 'CuePoints',
        Binary = 1,
        Notes = [[
            config_files/cutepointlist.config from full distribution will decode this
            and generate a list of cue points with labels
        ]],
    },
    plst = { Name = 'Playlist',  Binary = 1 }, -- #16
    afsp = { },
    IDIT = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return RIFF.ConvertRIFFDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    CSET = {
        Name = 'CharacterSet',
        SubDirectory = { TagTable = 'lexiftool.RIFF.CSET' },
    },
    -- tx_ tags are generated based on the Codec used for the txts stream
    tx_USER = {
        Name = 'UserText',
        SubDirectory = { TagTable = 'lexiftool.RIFF.UserText' },
    },
    tx_Unknown = { -- (untested)
        Name = 'Text',
        Notes = 'streamed text, extracted when the ExtractEmbedded option is used',
    },
    ['id3 '] = {
        Name = 'ID3',
        SubDirectory = { TagTable = 'lexiftool.ID3.Main' },
    },
    ['ID3 '] = { -- (NC)
        Name = 'ID3-2',
        SubDirectory = { TagTable = 'lexiftool.ID3.Main' },
    },
--
-- WebP-specific tags
--
    EXIF = { { -- (WebP)
        Name = 'EXIF',
        Condition = function(_self, valPt) return isMatch(valPt, [[^(II\x2a\0|MM\0\x2a)]]) end,
        Notes = 'WebP files',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
        },
    },{ -- (WebP) - have also seen with "Exif\0\0" header - PH
        Name = 'EXIF',
        Condition = function(self, valPt)
            return isMatch(valPt, [[^Exif\0\0(II\x2a\0|MM\0\x2a)]]) and (perlTruthy(self:Warn('Improper EXIF header',1)) or 1)
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            Start = 6,
        },
    },{
        Name = 'UnknownEXIF',
        Binary = 1,
    } },
    ['XMP '] = { -- #14 (WebP)
        Name = 'XMP',
        Notes = 'WebP files',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    ["XMP\0"] = {
        Name = 'XMP',
        Notes = 'incorrectly written WebP files',
        Condition = function(self) return perlTruthy(self:Warn('Incorrect XMP tag ID', 1)) or 1 end,
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    ICCP = { -- #14 (WebP)
        Name = 'ICC_Profile',
        Notes = 'WebP files',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    ['VP8 '] = { -- (WebP lossy)
        Name = 'VP8Bitstream',
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^...\x9d\x01\x2a]]) end,
        SubDirectory = { TagTable = 'lexiftool.RIFF.VP8' },
    },
    VP8L = { -- #14 (WebP lossless)
        Name = 'VP8L',
        Condition = function(_self, valPt) return isMatch(valPt, [[^\x2f]]) end,
        SubDirectory = { TagTable = 'lexiftool.RIFF.VP8L' },
    },
    VP8X = { -- #14 (WebP extended)
        Name = 'VP8X',
        SubDirectory = { TagTable = 'lexiftool.RIFF.VP8X' },
    },
    ANIM = { -- #14 (WebP animation)
        Name = 'ANIM',
        SubDirectory = { TagTable = 'lexiftool.RIFF.ANIM' },
    },
    ANMF = { -- #14 (WebP animation frame)
        Name = 'ANMF',
        SubDirectory = { TagTable = 'lexiftool.RIFF.ANMF' },
    },
    ALPH = { -- #14 (WebP alpha)
        Name = 'ALPH',
        SubDirectory = { TagTable = 'lexiftool.RIFF.ALPH' },
    },
    SGLT = { -- #PH (BikeBro)
        Name = 'BikeBroAccel',
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return RIFF.ProcessSGLT(...) end,
        },
    },
    SLLT = { -- #PH (BikeBro)
        Name = 'BikeBroGPS',
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return RIFF.ProcessSLLT(...) end,
        },
    },
    iXML = { -- #PH
        SubDirectory = { TagTable = 'lexiftool.XMP.XML' },
    },
    aXML = { -- #PH
        SubDirectory = { TagTable = 'lexiftool.XMP.XML' },
    },
--
-- tags found in an AlphaImagingTech AVI video - PH
--
    LIST_INF0 = {  -- ('0' instead of 'O' -- odd)
        Name = 'Info',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Info' },
    },
    gps0 = {
        Name = 'GPSTrack',
        SetGroups = 'RIFF', -- (moves "QuickTime" tags to the "RIFF" group)
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            -- (don't use code ref here or get "Prototype mismatch" warning with some Perl versions)
            ProcessProc = function(...) return require('lexiftool.QuickTime').Process_gps0(...) end,
        },
    },
    gsen = {
        Name = 'GSensor',
        SetGroups = 'RIFF', -- (moves "QuickTime" tags to the "RIFF" group)
        SubDirectory = {
            TagTable = 'lexiftool.QuickTimeStream.Stream',
            ProcessProc = function(...) return require('lexiftool.QuickTime').Process_gsen(...) end,
        },
    },
    -- gpsa - seen hex "01 20 00 00", same as QuickTime
    -- gsea - 16 bytes hex "04 08 02 00 20 02 00 00 1f 03 00 00 01 00 00 00"

    acid = {   -- writen by Acidizer
        Name = 'Acidizer',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Acidizer' },
    },
    guan = 'Guano', -- #forum14831
    SEAL = {
        Name = 'SEAL',
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
    },
    -- LGWV - written by Logic Pro
    -- minf, elm1, regn, umid, DGDA - written by Pro Tools
    -- MXrt, muma, chrp - written by Sequoia Pro
}

-- the maker notes used by some digital cameras
RIFF.Junk = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
}

-- Format and Audio Stream Format chunk data
RIFF.AudioFormat = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'int16u',
    [0] = {
        Name = 'Encoding',
        PrintHex = 1,
        PrintConv = RIFF.audioEncoding,
        SeparateTable = 'AudioEncoding',
    },
    [1] = 'NumChannels',
    [2] = {
        Name = 'SampleRate',
        Format = 'int32u',
    },
    [4] = {
        Name = 'AvgBytesPerSec',
        Format = 'int32u',
    },
   -- uninteresting
   -- 6 => 'BlockAlignment',
    [7] = 'BitsPerSample',
}

-- Broadcast Audio Extension 'bext' information (ref 13)
RIFF.BroadcastExt = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        Information found in the Broadcast Audio Extension chunk (see
        L<http://tech.ebu.ch/docs/tech/tech3285.pdf>).
    ]],
    [0] = {
        Name = 'Description',
        Format = 'string[256]',
    },
    [256] = {
        Name = 'Originator',
        Format = 'string[32]',
    },
    [288] = {
        Name = 'OriginatorReference',
        Format = 'string[32]',
    },
    [320] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Format = 'string[18]',
        ValueConv = function(_self, val)
            local _ = val; _ = tr(_, '-', ':'); _ = subst(_, [[^(\d{4}:\d{2}:\d{2})]], '$1 '); return _
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [338] = {
        Name = 'TimeReference',
        Notes = 'first sample count since midnight',
        Format = 'int32u[2]',
        ValueConv = function(_self, val)
            local v = split(' ', val); return uv(num(v[1]) + num(v[2]) * 4294967296)
        end,
    },
    [346] = {
        Name = 'BWFVersion',
        Format = 'int16u',
    },
    [348] = {
        Name = 'BWF_UMID',
        Format = 'undef[64]',
        ValueConv = function(_self, val)
            local _ = unpack('H*', val); _ = subst(_, '0{64}$', ''); return uc(_)
        end,
    },
    -- 412 - int8u[190] - reserved
    [602] = {
        Name = 'CodingHistory',
        Format = 'string[$size-602]',
    },
}

-- 64-bit chunk sizes (ref 15)
RIFF.DS64 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'int64u',
    NOTES = [[
        64-bit data sizes for MBWF/RF64 files.  See
        L<https://tech.ebu.ch/docs/tech/tech3306-2009.pdf> for the specification.
    ]],
    [0] = {
        Name = 'RIFFSize64',
        PrintConv = function(self, val) return ExifTool.ConvertFileSize(val, self) end,
    },
    [1] = {
        Name = 'DataSize64',
        DataMember = 'DataSize64',
        RawConv = function(self, val) self.DataSize64 = val; return val end,
        PrintConv = function(self, val) return ExifTool.ConvertFileSize(val, self) end,
    },
    [2] = 'NumberOfSamples64',
    -- (after this comes a table of size overrides for chunk
    --  types other than 'data', but since these are currently
    --  very unlikely, support for these is not yet implemented)
}

-- Sampler chunk (ref 16)
RIFF.Sampler = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'int32u',
    [0] = 'Manufacturer',
    [1] = 'Product',
    [2] = 'SamplePeriod',
    [3] = 'MIDIUnityNote',
    [4] = 'MIDIPitchFraction',
    [5] = {
        Name = 'SMPTEFormat',
        PrintConv = {
            [0] = 'none',
            [24] = '24 fps',
            [25] = '25 fps',
            [29] = '29 fps',
            [30] = '30 fps',
        },
    },
    [6] = {
        Name = 'SMPTEOffset',
        Notes = 'HH:MM:SS:FF',
        ValueConv = function(_self, val)
            local str_ = sprintf('%.8x', val)
            str_ = subst(str_, '(..)(..)(..)(..)', '$1:$2:$3:$4')
            return str_
        end,
    },
    [7] = 'NumSampleLoops',
    [8] = 'SamplerDataLen',
    [9] = { Name = 'SamplerData', Format = 'undef[$size-40]', Binary = 1 },
}

-- Instrument chunk (ref 16)
RIFF.Instrument = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'int8s',
    [0] = 'UnshiftedNote',
    [1] = 'FineTune',
    [2] = 'Gain',
    [3] = 'LowNote',
    [4] = 'HighNote',
    [5] = 'LowVelocity',
    [6] = 'HighVelocity',
}

-- Sub chunks of INFO LIST chunk
RIFF.Info = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'string',
    NOTES = [[
        RIFF INFO tags found in AVI video and WAV audio files.  Tags which are part
        of the EXIF 2.3 specification have an underlined Tag Name in the HTML
        version of this documentation.  Other tags are found in AVI files generated
        by some software.
    ]],
    IARL = 'ArchivalLocation',
    IART = { Name = 'Artist',    Groups = { [2] = 'Author' } },
    ICMS = 'Commissioned',
    ICMT = 'Comment',
    ICOP = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    ICRD = {
        Name = 'DateCreated',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) local _ = val; _ = subst(_, '-', ':', 'g'); return _ end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ICRP = 'Cropped',
    IDIM = 'Dimensions',
    IDPI = 'DotsPerInch',
    IENG = 'Engineer',
    IGNR = 'Genre',
    IKEY = 'Keywords',
    ILGT = 'Lightness',
    IMED = 'Medium',
    INAM = 'Title',
    ITRK = 'TrackNumber',
    IPLT = 'NumColors',
    IPRD = 'Product',
    ISBJ = 'Subject',
    ISFT = {
        Name = 'Software',
        -- remove trailing nulls/spaces and split at first null
        -- (Casio writes "CASIO" in unicode after the first null)
        ValueConv = function(_self, val)
            local _ = val; _ = subst(_, [[(\s*\0)+$]], ''); _ = subst(_, [[(\s*\0)]], ', '); _ = subst(_, [[\0+]], '', 'g'); return _
        end,
    },
    ISHP = 'Sharpness',
    ISRC = 'Source',
    ISRF = 'SourceForm',
    ITCH = 'Technician',
--
-- 3rd party tags
--
    -- internet movie database (ref 12)
    ISGN = 'SecondaryGenre',
    IWRI = 'WrittenBy',
    IPRO = 'ProducedBy',
    ICNM = 'Cinematographer',
    IPDS = 'ProductionDesigner',
    IEDT = 'EditedBy',
    ICDS = 'CostumeDesigner',
    IMUS = 'MusicBy',
    ISTD = 'ProductionStudio',
    IDST = 'DistributedBy',
    ICNT = 'Country',
    ILNG = 'Language',
    IRTD = 'Rating',
    ISTR = 'Starring',
    -- MovieID (ref12)
    TITL = 'Title',
    DIRC = 'Directory',
    YEAR = 'Year',
    GENR = 'Genre',
    COMM = 'Comments',
    LANG = 'Language',
    AGES = 'Rated',
    STAR = 'Starring',
    CODE = 'EncodedBy',
    PRT1 = 'Part',
    PRT2 = 'NumberOfParts',
    -- Morgan Multimedia INFO tags (ref 12)
    IAS1 = 'FirstLanguage',
    IAS2 = 'SecondLanguage',
    IAS3 = 'ThirdLanguage',
    IAS4 = 'FourthLanguage',
    IAS5 = 'FifthLanguage',
    IAS6 = 'SixthLanguage',
    IAS7 = 'SeventhLanguage',
    IAS8 = 'EighthLanguage',
    IAS9 = 'NinthLanguage',
    ICAS = 'DefaultAudioStream',
    IBSU = 'BaseURL',
    ILGU = 'LogoURL',
    ILIU = 'LogoIconURL',
    IWMU = 'WatermarkURL',
    IMIU = 'MoreInfoURL',
    IMBI = 'MoreInfoBannerImage',
    IMBU = 'MoreInfoBannerURL',
    IMIT = 'MoreInfoText',
    -- GSpot INFO tags (ref 12)
    IENC = 'EncodedBy',
    IRIP = 'RippedBy',
    -- Sound Forge Pro tags
    DISP = 'SoundSchemeTitle',
    TLEN = { Name = 'Length', ValueConv = function(_self, val) return num(val, '/')/1000 end, PrintConv = function(_self, val) return str(val) .. ' s' end },
    TRCK = 'TrackNumber',
    TURL = 'URL',
    TVER = 'Version',
    LOCA = 'Location',
    TORG = 'Organization',
    -- Sony Vegas AVI tags, also used by SCLive and Adobe Premier (ref 11)
    TAPE = {
        Name = 'TapeName',
        Groups = { [2] = 'Video' },
    },
    TCOD = {
        Name = 'StartTimecode',
        -- this is the tape time code for the start of the video
        Groups = { [2] = 'Video' },
        ValueConv = function(_self, val) return num(val, '*') * 1e-7 end,
        PrintConv = function(_self, val) return RIFF.ConvertTimecode(val) end,
    },
    TCDO = {
        Name = 'EndTimecode',
        Groups = { [2] = 'Video' },
        ValueConv = function(_self, val) return num(val, '*') * 1e-7 end,
        PrintConv = function(_self, val) return RIFF.ConvertTimecode(val) end,
    },
    VMAJ = {
        Name = 'VegasVersionMajor',
        Groups = { [2] = 'Video' },
    },
    VMIN = {
        Name = 'VegasVersionMinor',
        Groups = { [2] = 'Video' },
    },
    CMNT = {
        Name = 'Comment',
        Groups = { [2] = 'Video' },
    },
    RATE = {
        Name = 'Rate', --? (video? units?)
        Groups = { [2] = 'Video' },
    },
    STAT = {
        Name = 'Statistics',
        Groups = { [2] = 'Video' },
        -- ("7318 0 3.430307 1", "0 0 3500.000000 1", "7 0 3.433228 1")
        PrintConv = {
            function(_self, val) return str(val) .. ' frames captured' end,
            function(_self, val) return str(val) .. ' dropped' end,
            function(_self, val) return 'Data rate ' .. str(val) end,
            { [0] = 'Bad', [1] = 'OK' }, -- capture OK?
        },
    },
    DTIM = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            local v = split(' ', val)
            if #v ~= 2 then return nil end
            -- the Kodak EASYSHARE Sport stores this incorrectly as a string:
            if isMatch(val, [[^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$]]) then return val end
            -- get time in seconds
            val = 1e-7 * (num(v[1]) * 4294967296 + num(v[2]))
            -- shift from Jan 1, 1601 to Jan 1, 1970
            if val ~= 0 then val = val - 134774 * 24 * 3600 end
            return ConvertUnixTime(val)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- not observed, but apparently part of the standard:
    IDIT = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return RIFF.ConvertRIFFDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ISMP = 'TimeCode',
}

-- Sub chunks of EXIF LIST chunk
RIFF.Exif = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Audio' },
    NOTES = 'These tags are part of the EXIF 2.3 specification for WAV audio files.',
    ever = 'ExifVersion',
    erel = 'RelatedImageFile',
    etim = { Name = 'TimeCreated', Groups = { [2] = 'Time' } },
    ecor = { Name = 'Make',        Groups = { [2] = 'Camera' } },
    emdl = { Name = 'Model',       Groups = { [2] = 'Camera' }, Description = 'Camera Model Name' },
    emnt = { Name = 'MakerNotes',  Binary = 1 },
    eucm = {
        Name = 'UserComment',
        PrintConv = function(self, val) return require('lexiftool.Exif').ConvertExifText(self,val,'RIFF:UserComment') end,
    },
}

-- Sub chunks of hdrl LIST chunk
RIFF.Hdrl = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    avih = {
        Name = 'AVIHeader',
        SubDirectory = { TagTable = 'lexiftool.RIFF.AVIHeader' },
    },
    IDIT = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return RIFF.ConvertRIFFDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ISMP = 'TimeCode',
    LIST_strl = {
        Name = 'Stream',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Stream' },
    },
    LIST_odml = {
        Name = 'OpenDML',
        SubDirectory = { TagTable = 'lexiftool.RIFF.OpenDML' },
    },
}

-- Sub chunks of Tdat LIST chunk (ref PH)
RIFF.Tdat = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Video' },
    -- (have seen tc_O, tc_A, rn_O and rn_A)
}

-- RIFF character set chunk
RIFF.CSET = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int16u',
    [0] = {
        Name = 'CodePage',
        RawConv = function(self, val) self.CodePage = val; return val end,
    },
    [1] = 'CountryCode',
    [2] = 'LanguageCode',
    [3] = 'Dialect',
}

RIFF.AVIHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'FrameRate',
        -- (must use RawConv because raw value used in Composite tag)
        RawConv = function(_self, val) if perlTruthy(val) then return 1e6 / val end; return nil end,
        PrintConv = function(_self, val) return int(val * 1000 + 0.5) / 1000 end,
    },
    [1] = {
        Name = 'MaxDataRate',
        Notes = [[
            converted using SI byte prefixes unles the API ByteUnit option is set to
            "Binary"
        ]],
        PrintConv = function(self, val)
            local unit, div
            if self:Options('ByteUnit') == 'Binary' then unit, div = 'KiB/s',1024 else unit, div = 'kB/s',1000 end
            local tmp = val / div
            if tmp > 9999 then tmp = tmp / div; unit = subst(unit, '^.', 'M') end
            return sprintf('%.4g %s', tmp, unit)
        end,
    },
  -- 2 => 'PaddingGranularity',
  -- 3 => 'Flags',
    [4] = 'FrameCount',
  -- 5 => 'InitialFrames',
    [6] = 'StreamCount',
  -- 7 => 'SuggestedBufferSize',
    [8] = 'ImageWidth',
    [9] = 'ImageHeight',
}

RIFF.Stream = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    strh = {
        Name = 'StreamHeader',
        SubDirectory = { TagTable = 'lexiftool.RIFF.StreamHeader' },
    },
    strn = 'StreamName',
    strd = { -- #PH
        Name = 'StreamData',
        SubDirectory = { TagTable = 'lexiftool.RIFF.StreamData' },
    },
    strf = {
        {
            Name = 'AudioFormat',
            Condition = function(self) return self.RIFFStreamType == 'auds' end,
            SubDirectory = { TagTable = 'lexiftool.RIFF.AudioFormat' },
        },
        {
            Name = 'VideoFormat',
            Condition = function(self) return self.RIFFStreamType == 'vids' end,
            SubDirectory = { TagTable = 'lexiftool.BMP.Main' },
        },
        {
            Name = 'TextFormat',
            Condition = function(self) return self.RIFFStreamType == 'txts' end,
            Hidden = 1,
            RawConv = function(self)
                if not perlTruthy(self:Options('ExtractEmbedded')) then self:Warn('Use ExtractEmbedded option to extract timed text',3) end; return nil
            end,
        },
    },
}

-- Open DML tags (ref http://www.morgan-multimedia.com/download/odmlff2.pdf)
RIFF.OpenDML = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Video' },
    dmlh = {
        Name = 'ExtendedAVIHeader',
        SubDirectory = { TagTable = 'lexiftool.RIFF.ExtAVIHdr' },
    },
}

-- Extended AVI Header tags (ref http://www.morgan-multimedia.com/download/odmlff2.pdf)
RIFF.ExtAVIHdr = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    [0] = 'TotalFrameCount',
}

RIFF.StreamHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    PRIORITY = 0,  -- so we get values from the first stream
    [0] = {
        Name = 'StreamType',
        Format = 'string[4]',
        RawConv = function(self, val)
            self.RIFFStreamNum = (perlTruthy(self.RIFFStreamNum) and self.RIFFStreamNum or 0) + 1; self.RIFFStreamType = val; return val
        end,
        PrintConv = {
            auds = 'Audio',
            mids = 'MIDI',
            txts = 'Text',
            vids = 'Video',
            iavs = 'Interleaved Audio+Video',
        },
    },
    [1] = {
        {
            Name = 'AudioCodec',
            Condition = function(self) return self.RIFFStreamType == 'auds' end,
            RawConv = function(self, val) self.RIFFStreamCodec[self.RIFFStreamNum-1] = val; return val end,
            Format = 'string[4]',
        },
        {
            Name = 'VideoCodec',
            Condition = function(self) return self.RIFFStreamType == 'vids' end,
            RawConv = function(self, val) self.RIFFStreamCodec[self.RIFFStreamNum-1] = val; return val end,
            Format = 'string[4]',
        },
        {
            Name = 'Codec',
            Format = 'string[4]',
            RawConv = function(self, val) self.RIFFStreamCodec[self.RIFFStreamNum-1] = val; return val end,
        },
    },
  -- 2 => 'StreamFlags',
  -- 3 => 'StreamPriority',
  -- 3.5 => 'Language',
  -- 4 => 'InitialFrames',
    [5] = {
        {
            Name = 'AudioSampleRate',
            Condition = function(self) return self.RIFFStreamType == 'auds' end,
            Format = 'rational64u',
            ValueConv = function(_self, val) if perlTruthy(val) then return 1/num(val, '/') end; return 0 end,
            PrintConv = function(_self, val) return int(val * 100 + 0.5) / 100 end,
        },
        {
            Name = 'VideoFrameRate',
            Condition = function(self) return self.RIFFStreamType == 'vids' end,
            Format = 'rational64u',
            -- (must use RawConv because raw value used in Composite tag)
            RawConv = function(_self, val) if perlTruthy(val) then return 1/num(val, '/') end; return nil end,
            PrintConv = function(_self, val) return int(val * 1000 + 0.5) / 1000 end,
        },
        {
            Name = 'StreamSampleRate',
            Format = 'rational64u',
            ValueConv = function(_self, val) if perlTruthy(val) then return 1/num(val, '/') end; return 0 end,
            PrintConv = function(_self, val) return int(val * 1000 + 0.5) / 1000 end,
        },
    },
  -- 7 => 'Start',
    [8] = {
        {
            Name = 'AudioSampleCount',
            Condition = function(self) return self.RIFFStreamType == 'auds' end,
        },
        {
            Name = 'VideoFrameCount',
            Condition = function(self) return self.RIFFStreamType == 'vids' end,
        },
        {
            Name = 'StreamSampleCount',
        },
    },
  -- 9 => 'SuggestedBufferSize',
    [10] = {
        Name = 'Quality',
        PrintConv = function(_self, val) if str(val) == '4294967295' then return 'Default' end; return val end, -- ($val eq 0xffffffff)
    },
    [11] = {
        Name = 'SampleSize',
        PrintConv = function(_self, val)
            if perlTruthy(val) then return str(val) .. ' byte' .. (num(val, '==')==1 and '' or 's') end; return 'Variable'
        end,
    },
  -- 12 => { Name => 'Frame', Format => 'int16u[4]' },
}

RIFF.StreamData = { -- #PH
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Video' },
    NOTES = [[
        This chunk is used to store proprietary information in AVI videos from some
        cameras.  The first 4 characters of the data are used as the Tag ID below.
    ]],
    AVIF = {
        Name = 'AVIF',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            DirName = 'IFD0',
            Start = 8,
            ByteOrder = 'LittleEndian',
        },
    },
    CASI = { -- (used by Casio GV-10)
        Name = 'CasioData',
        SubDirectory = { TagTable = 'lexiftool.Casio.AVI' },
    },
    Zora = 'VendorName',   -- (Samsung PL90 AVI files)
    unknown = {
        Name = 'UnknownData',
        -- try to interpret unknown stream data as a string
        RawConv = function(_self, val)
            local _ = val; if isMatch(_, [[^[^\0-\x1f\x7f-\xff]+$]]) then return _ end; return nil
        end,
    },
}

-- VP8 bitstream (ref http://www.rfc-editor.org/rfc/pdfrfc/rfc6386.txt.pdf)
RIFF.VP8 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        This chunk is found in simple-format (lossy) WebP files. See
        L<https://developers.google.com/speed/webp/docs/riff_container> for the WebP
        container specification.
    ]],
    [0] = {
        Name = 'VP8Version',
        Mask = 0x0e,
        PrintConv = {
            [0] = '0 (bicubic reconstruction, normal loop)',
            [1] = '1 (bilinear reconstruction, simple loop)',
            [2] = '2 (bilinear reconstruction, no loop)',
            [3] = '3 (no reconstruction, no loop)',
        },
    },
    [6] = {
        Name = 'ImageWidth',
        Format = 'int16u',
        Mask = 0x3fff,
        Priority = 0,
    },
    [6.1] = {
        Name = 'HorizontalScale',
        Format = 'int16u',
        Mask = 0xc000,
    },
    [8] = {
        Name = 'ImageHeight',
        Format = 'int16u',
        Mask = 0x3fff,
        Priority = 0,
    },
    [8.1] = {
        Name = 'VerticalScale',
        Format = 'int16u',
        Mask = 0xc000,
    },
}

-- WebP lossless info (ref 14)
RIFF.VP8L = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'This chunk is found in lossless WebP files.',
    GROUPS = { [2] = 'Image' },
    [1] = {
        Name = 'ImageWidth',
        Format = 'int16u',
        Priority = 0,
        -- add " (lossless)" to FileType since image has a VP8L (lossless) chunk
        RawConv = function(self, val)
            self:OverrideFileType(str(self.VALUE.FileType) .. ' (lossless)', nil, 'webp')
            return val
        end,
        ValueConv = function(_self, val) return (val & 0x3fff) + 1 end,
    },
    [2] = {
        Name = 'ImageHeight',
        Format = 'int32u',
        Priority = 0,
        ValueConv = function(_self, val) return ((val >> 6) & 0x3fff) + 1 end,
    },
    [4] = {
        Name = 'AlphaIsUsed',
        Mask = 0x10,
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
}

-- WebP extended info (ref 14)
RIFF.VP8X = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'This chunk is found in extended WebP files.',
    -- 0 - bitmask: 2=ICC, 3=alpha, 4=EXIF, 5=XMP, 6=animation
    [0] = {
        Name = 'WebP_Flags',
        Description = 'WebP Flags',
        Notes = 'flags used in Extended WebP images',
        Format = 'int32u',
        PrintConv = { BITMASK = {
            [1] = 'Animation',
            [2] = 'XMP',
            [3] = 'EXIF',
            [4] = 'Alpha',
            [5] = 'ICC Profile',
        }},
    },
    [4] = {
        Name = 'ImageWidth',
        Format = 'int32u',
        ValueConv = function(_self, val) return (val & 0xffffff) + 1 end,
    },
    [6] = {
        Name = 'ImageHeight',
        Format = 'int32u',
        ValueConv = function(_self, val) return (val >> 8) + 1 end,
    },
}

-- WebP animation info (ref 14)
RIFF.ANIM = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'WebP animation chunk.',
    [0] = {
        Name = 'BackgroundColor',
        Format = 'int8u[4]',
    },
    [4] = {
        Name = 'AnimationLoopCount',
        PrintConv = function(_self, val) if perlTruthy(val) then return val end; return 'inf' end,
    },
}

-- WebP animation frame info (ref 14)
RIFF.ANMF = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'WebP animation frame chunk.',
    [12] = {
        Name = 'Duration',
        Format = 'int32u',
        Notes = 'extracted as the sum of durations of all animation frames',
        RawConv = function(self, val)
            if self.VALUE.Duration ~= nil then
                self.VALUE.Duration = num(self.VALUE.Duration) + (val & 0x0fff)
                return nil
            end
            return val & 0x0fff
        end,
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
}

-- (port helper: the conversions below call Image::ExifTool::GPS::ToDMS
--  without loading GPS.pm, so in Perl the call dies with "Undefined
--  subroutine" unless another module has loaded it)
local function GPS_ToDMS(...)
    local GPS = package.loaded['lexiftool.GPS']
    if not GPS then perl.die('Undefined subroutine &Image::ExifTool::GPS::ToDMS called') end
    return GPS.ToDMS(...)
end

-- streamed USER txts written by Momento M6 dashcam (ref PH)
RIFF.UserText = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = [[
        Tags decoded from the USER-format txts stream written by Momento M6 dashcam.
        Extracted only if the ExtractEmbedded option is used.
    ]],
    -- (little-endian)
  --  0 - int32u: 32
  --  4 - int32u: sample number (starting from unknown offset)
  --  8 - int8u[4]: "w x y z" ? (w 0=front cam, 1=rear cam, z mostly 5-8)
  -- 12 - int8u[4]: "0 x 1 0" ? (x incrementing once per second)
  -- 16 - int8u[4]: "0 32 0 x" ?
  -- 20 - int32u: 100-150(mostly), 250-300(once per second)
  -- 24 - int8u[4]: "0 x y 0" ?
    [28] = { Name = 'GPSAltitude', Format = 'int32u', ValueConv = function(_self, val) return val / 10 end }, -- (NC)
  -- 32 - int32u: 0(mostly), 23(once per second)
  -- 36 - int32u: 0
    [40] = { Name = 'Accelerometer', Format = 'float[3]' },
  -- 52 - int32u: 1
    [56] = { Name = 'GPSSpeed',      Format = 'float' }, -- km/h
    [60] = {
        Name = 'GPSLatitude',
        Format = 'float',
        -- Note: these values are unsigned and I don't know where the hemisphere is stored,
        -- but my only sample is from the U.S., so assume a positive latitude (for now)
        ValueConv = function(_self, val) local deg = int(val / 100); return deg + (val - deg * 100) / 60 end,
        PrintConv = function(self, val) return GPS_ToDMS(self, val, 1, 'N') end,
    },
    [64] = {
        Name = 'GPSLongitude',
        Format = 'float',
        -- Note: these values are unsigned and I don't know where the hemisphere is stored,
        -- but my only sample is from the U.S., so assume a negative longitude (for now)
        ValueConv = function(_self, val) local deg = int(val / 100); return -(deg + (val - deg * 100) / 60) end,
        PrintConv = function(self, val) return GPS_ToDMS(self, val, 1, 'E') end,
    },
    [68] = {
        Name = 'GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        Format = 'int32u',
        ValueConv = function(_self, val) return ConvertUnixTime(val) end,
        -- (likely local time, but clock seemed off by 3 hours in my sample)
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

-- WebP alpha info (ref 14)
RIFF.ALPH = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'WebP alpha chunk.',
    [0] = {
        Name = 'AlphaPreprocessing',
        Mask = 0x03,
        PrintConv = {
            [0] = 'none',
            [1] = 'Level Reduction',
        },
    },
    [0.1] = {
        Name = 'AlphaFiltering',
        Mask = 0x03,
        PrintConv = {
            [0] = 'none',
            [1] = 'Horizontal',
            [2] = 'Vertical',
            [3] = 'Gradient',
        },
    },
    [0.2] = {
        Name = 'AlphaCompression',
        Mask = 0x03,
        PrintConv = {
            [0] = 'none',
            [1] = 'Lossless',
        },
    },
}

-- Acidizer information (ref https://forums.cockos.com/showthread.php?t=227118)
RIFF.Acidizer = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
    [0] = {
        Name = 'AcidizerFlags',
        Format = 'int32u',
        PrintConv = { BITMASK = {
            [0] = 'One shot',
            [1] = 'Root note set',
            [2] = 'Stretch',
            [3] = 'Disk-based',
            [4] = 'High octave',
        }},
    },
    [4] = {
        Name = 'RootNote',
        Format = 'int16u',
        PrintConv = {
            [0x30] = 'C',    [0x3c] = 'High C',
            [0x31] = 'C#',   [0x3d] = 'High C#',
            [0x32] = 'D',    [0x3e] = 'High D',
            [0x33] = 'D#',   [0x3f] = 'High D#',
            [0x34] = 'E',    [0x40] = 'High E',
            [0x35] = 'F',    [0x41] = 'High F',
            [0x36] = 'F#',   [0x42] = 'High F#',
            [0x37] = 'G',    [0x43] = 'High G',
            [0x38] = 'G#',   [0x44] = 'High G#',
            [0x39] = 'A',    [0x45] = 'High A',
            [0x3a] = 'A#',   [0x46] = 'High A#',
            [0x3b] = 'B',    [0x47] = 'High B',
        },
    },
    [12] = {
        Name = 'Beats',
        Format = 'int32u',
    },
    [16] = {
        Name = 'Meter',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) val = subst(val, [[(\d+) (\d+)]], '$2/$1'); return val end, -- denominator comes first, so swap them
    },
    [20] = {
        Name = 'Tempo',
        Format = 'float',
    },
}

-- RIFF composite tags
RIFF.Composite = {
    Duration = {
        TagID = 'RIFF-Duration',
        Require = {
            [0] = 'RIFF:FrameRate',
            [1] = 'RIFF:FrameCount',
        },
        Desire = {
            [2] = 'VideoFrameRate',
            [3] = 'VideoFrameCount',
        },
        RawConv = function(self, val) return RIFF.CalcDuration(self, val) end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
    Duration2 = {
        Name = 'Duration',
        TagID = 'RIFF-Duration2',
        Require = {
            [0] = 'RIFF:AvgBytesPerSec',
        },
        Desire = {
            [1] = 'FileSize', -- (only used if 'data' length isn't available)
            -- check FrameCount because this calculation only applies
            -- to audio-only files (eg. WAV)
            [2] = 'FrameCount',
            [3] = 'VideoFrameCount',
        },
        -- (can't calculate duration like this for compressed audio types)
        RawConv = function(self, val)
            if isMatch(self.FileType, [[^(LA|OFR|PAC|WV)$]]) or perlTruthy(val[2]) or perlTruthy(val[3]) then return nil end
            if not (perlTruthy(val[0]) and (perlTruthy(self.RIFFDataLen) or perlTruthy(val[1]))) then return nil end
            return((perlTruthy(self.RIFFDataLen) and self.RIFFDataLen or val[1]) / val[0])
        end,
        PrintConv = function(_self, val) return ConvertDuration(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.RIFF', nil, RIFF)

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream's AUTOLOAD calls DoAutoLoad for WriteRIFF.pl; here RIFF.WriteRIFF
--  at the predeclarations loads WriteRIFF.lua itself)

--------------------------------------------------------------------------------
-- Convert RIFF date to EXIF format
local monthNum = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10,Nov=11,Dec=12
}
function RIFF.ConvertRIFFDate(val)
    local part = split(' ', val)
    local mon
    if #part >= 5 then mon = monthNum[ucfirst(lc(part[2]))] end
    if mon then
        -- the standard AVI date format (eg. "Mon Mar 10 15:04:43 2003")
        val = sprintf('%.4d:%.2d:%.2d %s', part[5],
                       mon, part[3], part[4])
    else
        local ok, c1, c2, c3, c4, c5, c6 = isMatch(val, [[(\d{4})/\s*(\d+)/\s*(\d+)/?\s+(\d+):\s*(\d+)\s*(P?)]])
        if ok then
            -- but the Casio QV-3EX writes dates like "2001/ 1/27  1:42PM",
            -- and the Casio EX-Z30 writes "2005/11/28/ 09:19"... doh!
            val = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:00',c1,c2,c3,num(c4)+(perlTruthy(c6) and 12 or 0),c5)
        else
            ok, c1, c2, c3, c4 = isMatch(val, [[(\d{4})[-/](\d+)[-/](\d+)\s+(\d+:\d+:\d+)]])
            if ok then
                -- the Konica KD500Z writes "2002-12-16  15:35:01\0\0"
                val = c1 .. ':' .. c2 .. ':' .. c3 .. ' ' .. c4
            end
        end
    end
    return val
end

--------------------------------------------------------------------------------
-- Print time
-- Inputs: 0) time in seconds
-- Returns: time string
function RIFF.ConvertTimecode(val)
    local hr = int(val / 3600)
    val = val - hr * 3600
    local min = int(val / 60)
    val = val - min * 60
    local ss = sprintf('%05.2f', val)
    if num(ss) >= 60 then    -- handle round-off problems
        ss = '00.00'
        min = min + 1; if min >= 60 then min = min - 60; hr = hr + 1 end
    end
    return sprintf('%d:%.2d:%s', hr, min, ss)
end

--------------------------------------------------------------------------------
-- Calculate duration of RIFF
-- Inputs: 0) ExifTool ref, 1/2) RIFF:FrameRate/Count, 2/3) VideoFrameRate/Count
-- Returns: Duration in seconds or undef
-- Notes: Sums duration of all sub-documents (concatenated AVI files)
function RIFF.CalcDuration(et, val)
    local totalDuration = 0
    local subDoc = 0
    local keyList = { }
    while true do
        -- this is annoying.  Apparently (although I couldn't verify this), FrameCount
        -- in the RIFF header includes multiple video tracks if they exist (eg. with the
        -- FujiFilm REAL 3D AVI's), but the video stream information isn't reliable for
        -- some cameras (eg. Olympus FE models), so use the video stream information
        -- only if the RIFF header duration is 2 to 3 times longer
        -- (also see https://github.com/exiftool/exiftool/issues/371)
        local dur1
        if perlTruthy(val[0]) then dur1 = num(val[1]) / num(val[0]) end
        if perlTruthy(val[2]) and perlTruthy(val[3]) then
            local dur2 = num(val[3]) / num(val[2])
            local rat = num(dur1) / dur2
            if rat > 1.9 and rat < 3.1 then dur1 = dur2 end
        end
        if dur1 ~= nil then totalDuration = totalDuration + dur1 end
        local more = subDoc < num(et.DOC_COUNT); subDoc = subDoc + 1
        if not more then break end
        -- get tag values for next sub-document
        local tags = { 'FrameRate', 'FrameCount', 'VideoFrameRate', 'VideoFrameCount' }
        local rawValue = et.VALUE
        local key, keys
        for i = 0, #tags - 1 do
            if subDoc == 1 then
                -- generate list of available keys for each tag
                keys = { }; keyList[i] = keys
                local j = 0
                while true do
                    key = tags[i + 1]
                    if j ~= 0 then key = key .. ' (' .. j .. ')' end
                    if rawValue[key] == nil then break end
                    keys[#keys + 1] = key
                    j = j + 1
                end
            else
                keys = keyList[i]
            end
            -- find key for tag in this sub-document
            local grp = 'Doc' .. subDoc
            if i < 2 then grp = grp .. ':RIFF' end -- (tags 0 and 1 also in RIFF group)
            key = et:GroupMatches(grp, keys)
            if key then val[i] = rawValue[key] else val[i] = nil end
        end
        if not (val[0] ~= nil and val[1] ~= nil) then break end -- (Require'd tags)
    end
    return totalDuration
end

--------------------------------------------------------------------------------
-- Process stream data
-- Inputs: 0) ExifTool object ref, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success
function RIFF.ProcessStreamData(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart
    local size = dirInfo.DirLen
    if size < 4 then return 0 end
    if perlTruthy(et:Options('Verbose')) then
        et:VerboseDir(dirInfo.DirName, 0, size)
    end
    local tag = substr(dataPt, start, 4)
    local tagInfo = et:GetTagInfo(tagTbl, tag)
    if not tagInfo then
        tagInfo = et:GetTagInfo(tagTbl, 'unknown')
        if not tagInfo then return 1 end
    end
    local subdir = tagInfo.SubDirectory
    if tagInfo.SubDirectory then
        local offset = perlTruthy(subdir.Start) and subdir.Start or 0
        local baseShift = dirInfo.DataPos + dirInfo.DirStart + offset
        local subdirInfo = {
            DataPt  = dataPt,
            DataPos = dirInfo.DataPos - baseShift,
            Base    = (perlTruthy(dirInfo.Base) and dirInfo.Base or 0) + baseShift,
            DataLen = dirInfo.DataLen,
            DirStart= dirInfo.DirStart + offset,
            DirLen  = dirInfo.DirLen - offset,
            DirName = subdir.DirName,
            Parent  = dirInfo.DirName,
        }
        if offset == 0 then
            -- allow processing of 2nd directory at the same address
            local addr = subdirInfo.DirStart + subdirInfo.DataPos + subdirInfo.Base
            et.PROCESSED[addr] = nil
        end
        -- (we could set FIRST_EXIF_POS to $subdirInfo{Base} here to make
        --  htmlDump offsets relative to EXIF base if we wanted...)
        local subTable = GetTagTable(nil, subdir.TagTable)
        et:ProcessDirectory(subdirInfo, subTable)
    else
        et:HandleTag(tagTbl, tag, nil, {
            DataPt  = dataPt,
            DataPos = dirInfo.DataPos,
            Start   = start,
            Size    = size,
            TagInfo = tagInfo,
        })
    end
    return 1
end

--------------------------------------------------------------------------------
-- Make tag information hash for unknown tag
-- Inputs: 0) Tag table ref, 1) tag ID
local function MakeTagInfo(tagTbl, tag)
    local name = tag
    local n
    name, n = substN(name, [[([\x00-\x1f\x7f-\xff])]], function(c1) return 'x' .. unpack('H*',c1) end, 'g')
    -- print in hex if tag is numerical
    if num(n) > 2 then name = sprintf('0x%.4x',unpack('N',tag)) end
    AddTagToTable(nil, tagTbl, tag, {
        Name = 'Unknown_' .. name,
        Description = 'Unknown ' .. name,
        Unknown = 1,
        Binary = 1,
    })
end
RIFF.MakeTagInfo = MakeTagInfo

--------------------------------------------------------------------------------
-- Process RIFF chunks
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function RIFF.ProcessChunks(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart
    local size = dirInfo.DirLen
    local end_ = start + size
    local base = perlTruthy(dirInfo.Base) and dirInfo.Base or 0
    local verbose = et:Options('Verbose')
    local unknown = et:Options('Unknown')
    local charset = et:Options('CharsetRIFF')

    if not perlTruthy(charset) then
        if perlTruthy(et.CodePage) then
            charset = et.CodePage
        elseif charset ~= nil and str(charset) == '0' then
            charset = 'Latin'
        end
    end

    if perlTruthy(verbose) then et:VerboseDir(dirInfo.DirName, 0, size) end

    while start + 8 < end_ do
        local tag = substr(dataPt, start, 4)
        local len = Get32u(dataPt, start + 4)
        start = start + 8
        if start + len > end_ then
            et:Warn('Bad ' .. tag .. ' chunk')
            return 0
        end
        if tag == 'LIST' and len >= 4 then
            tag = tag .. '_' .. substr(dataPt, start, 4)
            len = len - 4
            start = start + 4
        end
        local tagInfo = et:GetTagInfo(tagTbl, tag)
        local baseShift = 0
        local val
        if tagInfo then
            if tagInfo.SubDirectory then
                -- adjust base if necessary (needed for Ricoh maker notes)
                local newBase = tagInfo.SubDirectory.Base
                if newBase ~= nil then
                    -- different than your average Base eval...
                    -- here we use an absolute $start address
                    start = start + base
                    --### eval Base ($start)
                    newBase = num(newBase(et, nil, start))
                    baseShift = newBase - base
                    start = start - base
                end
            elseif not perlTruthy(tagInfo.Binary) then
                local format = tagInfo.Format or tagTbl.FORMAT
                if format and format == 'string' then
                    val = substr(dataPt, start, len)
                    val = subst(val, [[\0+$]], '')   -- remove trailing nulls from strings
                    -- decode if necessary
                    if perlTruthy(charset) then val = et:Decode(val, charset) end
                end
            end
        elseif perlTruthy(verbose) or perlTruthy(unknown) then
            MakeTagInfo(tagTbl, tag)
        end
        et:HandleTag(tagTbl, tag, val, {
            DataPt  = dataPt,
            DataPos = dirInfo.DataPos - baseShift,
            Start   = start,
            Size    = len,
            Base    = base + baseShift,
            Addr    = base + baseShift + start,
        })
        if len & 0x01 ~= 0 then len = len + 1 end  -- must account for padding if odd number of bytes
        start = start + len
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process BikeBro SGLT chunk (accelerometer data) (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function RIFF.ProcessSGLT(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)
    local ee = et:Options('ExtractEmbedded')
    local pos
    -- example accelerometer record:
    -- 0           1  2  3           4  5           6  7
    -- 00 00 00 24 02 00 00 01 17 04 00 00 00 00 00 00 00 00 9b 02
    -- frame------ ?? Xs X---------- Ys Y---------- Zs Z----------
    et.SET_GROUP0 = 'RIFF'; et.SET_GROUP1 = 'RIFF'
    pos = 0
    while pos <= dataLen - 20 do
        et.DOC_COUNT = num(et.DOC_COUNT) + 1; et.DOC_NUM = et.DOC_COUNT
        local buff = substr(dataPt, pos)
        local a = { unpack('NCCNCNCN', buff) }
        local acc = { a[4]*(perlTruthy(a[3]) and -1 or 1)/1e5, a[6]*(perlTruthy(a[5]) and -1 or 1)/1e5, a[8]*(perlTruthy(a[7]) and -1 or 1)/1e5 }
        et:HandleTag(tagTbl, 'FrameNumber',   a[1])
        et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
        if not perlTruthy(ee) then
            et:Warn('Use ExtractEmbedded option to extract all accelerometer data', 3)
            break
        end
        pos = pos + 20
    end
    et.SET_GROUP0 = nil
    et.SET_GROUP1 = nil
    et.DOC_NUM = 0
    return 0
end

--------------------------------------------------------------------------------
-- Process BikeBro SLLT chunk (GPS information) (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function RIFF.ProcessSLLT(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)
    local ee = et:Options('ExtractEmbedded')
    local pos
    -- example GPS record:
    -- 0           1  2     3           4     5           6     7     8  9  10 11    12 13 14 15
    -- 00 00 00 17 01 00 00 03 fa 21 ec 00 35 01 6e c0 06 00 08 00 62 10 0b 1b 07 e2 03 0e 57 4e
    -- frame------ ?? lonDD lonDDDDDDDD latDD latDDDDDDDD alt-- spd-- hr mn sc yr--- mn dy EW NS
    et.SET_GROUP0 = 'RIFF'; et.SET_GROUP1 = 'RIFF'
    pos = 0
    while pos <= dataLen - 30 do
        et.DOC_COUNT = num(et.DOC_COUNT) + 1; et.DOC_NUM = et.DOC_COUNT
        local buff = substr(dataPt, pos)
        local a = { unpack('NCnNnNnnCCCnCCaa', buff) }
        -- - is $a[1] perhaps GPSStatus? (only seen 1, or perhaps record type 1=GPS, 2=acc?)
        local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', a[12], a[13], a[14], a[9], a[10], a[11])
        et:HandleTag(tagTbl, 'FrameNumber',  a[1])
        et:HandleTag(tagTbl, 'GPSDateTime',  time)
        et:HandleTag(tagTbl, 'GPSLatitude',  (a[5] + a[6]/1e8) * (a[16] == 'S' and -1 or 1))
        et:HandleTag(tagTbl, 'GPSLongitude', (a[3] + a[4]/1e8) * (a[15] == 'W' and -1 or 1))
        et:HandleTag(tagTbl, 'GPSAltitude',  a[7])
        et:HandleTag(tagTbl, 'GPSSpeed',     a[8])
        et:HandleTag(tagTbl, 'GPSSpeedRef',  'K')
        if not perlTruthy(ee) then
            et:Warn('Use ExtractEmbedded option to extract timed GPS', 3)
            break
        end
        pos = pos + 30
    end
    et.SET_GROUP0 = nil
    et.SET_GROUP1 = nil
    et.DOC_NUM = 0
    return 1
end

--------------------------------------------------------------------------------
-- Process Lucas streaming GPS information (Lucas LK-7900 Ace) (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function RIFF.ProcessLucas(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)

    if not perlTruthy(et:Options('ExtractEmbedded')) then
        et:Warn('Use ExtractEmbedded option to extract timed GPS', 3)
        return 1
    end
    local recLen = {  -- record lengths (not including 4-byte ID)
        ['0GDA'] = 24,
        ['0GPS'] = 48,
    }
    local date,time,lat,lon,alt,spd,sat,dop,ew,ns
    et.SET_GROUP0 = 'RIFF'; et.SET_GROUP1 = 'RIFF'
    -- (posDataPt is `pos $$dataPt`, posBuff `pos $buff`: where the next /g
    --  match starts; a failed /g match resets it to 0)
    local posDataPt = 0
    while true do
        local rec, pos = matches(dataPt, [[(0GDA|0GPS)]], posDataPt)
        if not rec then break end
        if pos + recLen[rec] > dataLen then et:Warn('Truncated ' .. rec .. ' record') break end
        et.DOC_COUNT = num(et.DOC_COUNT) + 1; et.DOC_NUM = et.DOC_COUNT
        -- records start with int64u sample date/time in ms since 1970
        et:HandleTag(tagTbl, 'SampleDateTime', Get64u(dataPt, pos) / 1000)
        if rec == '0GPS' then
            local len = Get32u(dataPt, pos+8)
            local endPos = pos + recLen[rec] + len
            if endPos > dataLen then et:Warn('Truncated 0GPS record') break end
            local buff = substr(dataPt, pos+recLen[rec], len)
            local posBuff = 0
            while true do
                local c1, c2, p = matches(buff, [[\$(GC|GA),(\d+),]], posBuff)
                if not c1 then break end
                posBuff = p
                time = c2
                if c1 == 'GC' then
                    --     time   date   dist    ? sat dop alt  A
                    -- $GC,052350,180914,0000955,1,08,1.1,0017,,A*45\x0d\x0a\0
                    local d1, d2, d3, d4, e = matches(buff, [[\G(\d+),\d*,\d*,(\d+),([-\d.]+),(\d+),\d*,A]], posBuff)
                    if d1 then
                        date,sat,dop,alt = d1,d2,d3,d4
                        posBuff = e
                    else
                        posBuff = 0
                    end
                else
                    --     time   A lat       lon        spd N W
                    -- $GA,052351,A,0949.6626,07635.4439,049,N,E,*4C\x0d\x0a\0
                    local d1, d2, d3, d4, d5, e = matches(buff, [[\GA,([\d.]+),([\d.]+),(\d+),([NS]),([EW])]], posBuff)
                    if d1 then
                        lat,lon,spd,ns,ew = d1,d2,d3,d4,d5
                        posBuff = e
                        -- lat/long are in DDDMM.MMMM format
                        local deg = int(lat / 100)
                        lat = deg + (lat - deg * 100) / 60
                        deg = int(lon / 100)
                        lon = deg + (lon - deg * 100) / 60
                        if ns == 'S' then lat = lat * -1 end
                        if ew == 'W' then lon = lon * -1 end
                    else
                        posBuff = 0
                    end
                end
                -- look ahead to next NMEA-like sentence, and store the fix
                -- now only if the next sentence is not at the same time
                if not isMatchDyn(buff, [[\$(GC|GA),]] .. time .. ',', posBuff) then
                    posDataPt = endPos -- luacheck: ignore 311 (set again at the end of the loop, as upstream)
                    local ok, c1_ = isMatch(dataPt, [[\$(GC|GA),(\d+)]])
                    if not ok or c1_ ~= time then
                        time = subst(time, [[(\d{2})(\d{2})(\d{2})]], '$1:$2:$3Z')
                        if perlTruthy(date) then
                            date = subst(date, [[(\d{2})(\d{2})(\d{2})]], '20$3:$2:$1')
                            et:HandleTag(tagTbl, 'GPSDateTime', date .. ' ' .. time)
                        else
                            et:HandleTag(tagTbl, 'GPSTimeStamp', time)
                        end
                        if lat ~= nil then
                            et:HandleTag(tagTbl, 'GPSLatitude', lat)
                            et:HandleTag(tagTbl, 'GPSLongitude', lon)
                            et:HandleTag(tagTbl, 'GPSSpeed', spd)
                        end
                        if alt ~= nil then
                            et:HandleTag(tagTbl, 'GPSAltitude', alt)
                            et:HandleTag(tagTbl, 'GPSSatellites', sat)
                            et:HandleTag(tagTbl, 'GPSDOP', dop)
                        end
                        lat = nil
                        alt = nil
                    end
                end
                posBuff = p
            end
            pos = pos + len
        else -- this is an accelerometer (0GDA) record
            -- record has 4 more int32s values (the last is always 57 or 58 --
            -- maybe related to sample time in ms? -- not extracted)
            local acc = { unpack('x'..(pos+8)..'V3', dataPt) }
            -- change to signed integer and divide by 256
            acc = map(function(_) if _ >= 0x80000000 then _ = _ - 4294967296 end; _ = _ / 256; return _ end, acc)
            et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
        end
        posDataPt = pos + recLen[rec]
    end
    et.SET_GROUP0 = nil
    et.SET_GROUP1 = nil
    et.DOC_NUM = 0
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a RIFF file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid RIFF file
function RIFF.ProcessRIFF(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2, type, mime, err, rf64, moviEnd, n
    local verbose = et:Options('Verbose')
    local unknown = et:Options('Unknown')
    local validate = et:Options('Validate')
    local ee = et:Options('ExtractEmbedded')
    local hash = rawget(et, 'ImageDataHash')    -- (the member, not the method of that name)
    local base = 0

    -- verify this is a valid RIFF file
    n, buff = raf:Read(12)
    if n ~= 12 then return 0 end
    local m1, m2 = matches(buff, [[(?s)^(RIFF|RF64)....(.{4})]])
    if m1 then
        type = riffType[m2]
        if m1 == 'RF64' then rf64 = 1 end
    else
        -- minimal support for a few obscure lossless audio formats...
        m1 = matches(buff, [[^(LA0[234]|OFR |LPAC|wvpk)]])
        if m1 then n, buf2 = raf:Read(1024) end
        if not (m1 and perlTruthy(n)) then return 0 end
        type = riffType[m1]
        buff = buff .. buf2
        -- (the facade appends pos($buff), the 0-based end offset of the
        --  match, after the captures)
        local _, _, posBuff = matches(buff, [[(?s)WAVE(.{4})?(junk|fmt )]])
        if not (posBuff and raf:Seek(posBuff - 4, 0)) then return 0 end
        base = posBuff - 16
    end
    if perlTruthy(et:Options('FastScan')) then raf.NoBuffer = 1 end -- disable buffering in FastScan mode
    if type then mime = riffMimeType[type] end
    et:SetFileType(type, mime)
    if rf64 and perlTruthy(et.VALUE.FileType) then et.VALUE.FileType = et.VALUE.FileType .. ' (RF64)' end
    et.RIFFStreamType = ''      -- initialize stream type
    et.RIFFStreamCodec = {}     -- initialize codec array
    SetByteOrder('II')
    local riffEnd = Get32u(buff, 4) + 8
    riffEnd = riffEnd + (riffEnd & 0x01)    -- (account for padding)
    local tagTbl = GetTagTable(nil, 'lexiftool.RIFF.Main')
    local pos = 12
--
-- Read chunks in RIFF image
--
    while true do
        if err then
            if not moviEnd then break end
            -- we arrived here because there was a problem parsing the movie data
            -- so seek to the end to continue processing
            if moviEnd > 0x7fffffff then
                if not perlTruthy(et:Options('LargeFileSupport')) then
                    et:Warn('Possibly corrupt LIST_movi data')
                    et:Warn('Stopped parsing at large LIST_movi chunk (LargeFileSupport not set)')
                    err = nil
                    break
                end
                if str(et:Options('LargeFileSupport')) == '2' then
                    et:Warn('Processing large chunk (LargeFileSupport is 2)')
                end
            end
            if perlTruthy(validate) then
                -- (must actually try to read something after seeking to detect error)
                if raf:Seek(moviEnd - 1, 0) then n, buff = raf:Read(1) else n = nil end -- luacheck: ignore 311
                if n ~= 1 then break end
            else
                if not raf:Seek(moviEnd, 0) then break end
            end
            pos = moviEnd
            et:Warn('Possibly corrupt LIST_movi data')
            err = nil
            moviEnd = nil
        end
        if perlTruthy(moviEnd) then
            if pos > moviEnd then err = 1 goto next end     -- error if we parsed past the end of the movie data
            if pos == moviEnd then moviEnd = nil end        -- parsed all movie data?
        end
        do
        local num -- luacheck: ignore 431 (upstream $num, the num alias is not used in this block)
        num, buff = raf:Read(8)
        if num < 8 then
            if perlTruthy(moviEnd) then err = 1 goto next end
            if perlTruthy(num) then err = 1 end
            if perlTruthy(validate) and pos ~= riffEnd then et:Warn('Incorrect RIFF chunk size' .. " " .. pos .. " vs. " .. riffEnd) end
            break
        end
        pos = pos + 8
        local tag, len = unpack('a4V', buff)
        -- tweak WEBP type if this is an extended WebP
        if tag == 'VP8X' and type == 'WEBP' then et:OverrideFileType('Extended WEBP', nil, 'webp') end
        -- special case: construct new tag name from specific LIST type
        if tag == 'LIST' then
            n, buff = raf:Read(4)
            if n ~= 4 then err = 1 goto next end
            pos = pos + 4
            tag = tag .. "_" .. buff
            len = len - 4  -- already read 4 bytes (the LIST type)
        elseif tag == 'data' then
            if len == 0xffffffff and perlTruthy(et.DataSize64) then len = et.DataSize64 end
            et.RIFFDataLen = (perlTruthy(et.RIFFDataLen) and et.RIFFDataLen or 0) + len
        end
        et:VPrint(0, "RIFF '" .. tag .. "' chunk (" .. len .. " bytes of data):\n")
        if len <= 0 then
            if perlTruthy(moviEnd) then err = 1 goto next end
            if len < 0 then
                et:Warn('Invalid chunk length')
            elseif tag == "\0\0\0\0" then
                -- avoid reading through corupted files filled with nulls because it takes forever
                et:Warn('Encountered empty null chunk. Processing aborted')
            else
                goto next
            end
            break
        end
        -- stop when we hit the audio data or AVI index or AVI movie data
        -- --> no more because Adobe Bridge stores XMP after this!!
        -- (so now we only do this on the FastScan option)
        if perlTruthy(et:Options('FastScan')) and (tag == 'data' or tag == 'idx1' or
            (tag == 'LIST_movi' and not perlTruthy(ee)))
        then
            et:VPrint(0, "(end of parsing)\n")
            break
        end
        -- RIFF chunks are padded to an even number of bytes
        local len2 = len + (len & 0x01)
        -- change name of stream txts data depending on the Codec
        if perlTruthy(ee) then
            local txNum = matches(tag, [[^(\d{2})tx$]])
            if txNum then
                tag = 'tx_' .. (perlTruthy(et.RIFFStreamCodec[perl.num(txNum)]) and et.RIFFStreamCodec[perl.num(txNum)] or 'Unknown')
                if tagTbl[tag] == nil then tag = "tx_Unknown" end
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT
            end
        end
        local tagInfo = tagTbl[tag]
        -- (in LIST_movi chunk: ##db = uncompressed DIB, ##dc = compressed DIB, ##wb = audio data)
        if tagInfo or ((perlTruthy(verbose) or perlTruthy(unknown)) and not isMatch(tag, [[^(data|idx1|LIST_movi|RIFF|\d{2}(db|dc|wb))$]])) then
            n, buff = raf:Read(len2)
            if n < len then err = 1 goto next end
            if length(buff) ~= len2 then et:Warn("No padding on odd-sized " .. tag .. " chunk") end
            if hash and isImageData[tag] then
                hash:add(buff)
                et:VPrint(0, et.INDENT .. "(ImageDataHash: '" .. tag .. "' chunk, " .. len2 .. " bytes)\n")
            end
            local setGroups
            if tagInfo and type_(tagInfo) == 'table' and tagInfo.SetGroups then
                setGroups = tagInfo.SetGroups
                et.SET_GROUP0 = setGroups
                et.SET_GROUP1 = setGroups
            end
            if not tagInfo and (perlTruthy(verbose) or perlTruthy(unknown)) then MakeTagInfo(tagTbl, tag) end
            et:HandleTag(tagTbl, tag, buff, {
                DataPt  = buff,
                DataPos = 0,   -- (relative to Base)
                Start   = 0,
                Size    = len,
                Base    = pos + base,
            })
            if setGroups then
                et.SET_GROUP0 = nil
                et.SET_GROUP1 = nil
            end
            if perlTruthy(ee) then et.DOC_NUM = nil end
        elseif tag == 'RIFF' then
            if perlTruthy(validate) and pos - 8 ~= riffEnd then et:Warn('Incorrect RIFF chunk size') end
            riffEnd = riffEnd + len2 + 8
            -- don't read into RIFF chunk (eg. concatenated video file)
            n, buff = raf:Read(4) -- luacheck: ignore 311
            if n ~= 4 then err = 1 goto next end    -- (skip RIFF type word)
            pos = pos + 4
            -- extract information from remaining file as an embedded file
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
            goto next -- (must not increment $pos)
        else
            local rewind
            -- do hash if required
            if hash and isImageData[tag] then
                rewind = raf:Tell()
                et:ImageDataHash(raf, len2, "'" .. tag .. "' chunk")
            end
            if tag == 'LIST_movi' and perlTruthy(ee) then
                if perlTruthy(rewind) and not raf:Seek(rewind, 0) then err = 1 goto next end
                -- save end-of-movie offset so we can seek there if we get errors parsing the movie data
                moviEnd = raf:Tell() + len2
                goto next -- parse into movi chunk
            elseif not perlTruthy(rewind) then
                if len > 0x7fffffff then
                    if not perlTruthy(et:Options('LargeFileSupport')) then
                        tag = subst(tag, [[([\0-\x1f\x7f-\xff])]], function(c) return sprintf('\\x%.2x', ord(c)) end, 'g')
                        et:Warn("Stopped parsing at large " .. tag .. " chunk (LargeFileSupport not set)")
                        break
                    end
                    if str(et:Options('LargeFileSupport')) == '2' then
                        et:Warn('Processing large chunk (LargeFileSupport is 2)')
                    end
                end
                if perlTruthy(validate) and perlTruthy(len2) then
                    -- (must actually try to read something after seeking to detect error)
                    if raf:Seek(len2 - 1, 1) then n, buff = raf:Read(1) else n = nil end -- luacheck: ignore 311
                    if n ~= 1 then err = 1 goto next end
                else
                    if not raf:Seek(len2, 1) then err = 1 goto next end
                end
            end
        end
        pos = pos + len2
        end
        ::next::
    end
    et.DOC_NUM = nil
    if err then et:Warn('Error reading RIFF file (corrupted?)') end
    return 1
end


RIFF.Main.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Info.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Exif.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Hdrl.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Tdat.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Stream.PROCESS_PROC = RIFF.ProcessChunks
RIFF.OpenDML.PROCESS_PROC = RIFF.ProcessChunks
RIFF.StreamData.PROCESS_PROC = RIFF.ProcessStreamData

return RIFF -- end
