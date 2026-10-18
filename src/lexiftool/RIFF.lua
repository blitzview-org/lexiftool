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
-- Port notes:   read subset. Ported: the `audioEncoding` "TwoCC" lookup
--               (shared between RIFF and ASF files, used by ASF.lua's
--               StreamProperties), ProcessRIFF (the top-level chunk
--               walker), ProcessChunks (the sub-chunk walker), the Main/
--               Info/Exif/Hdrl/Stream/StreamData/OpenDML/AudioFormat/
--               BroadcastExt/DS64/Sampler/Instrument/CSET/AVIHeader/
--               StreamHeader/ExtAVIHdr/VP8/VP8L/VP8X/ANIM/ANMF/ALPH/
--               Acidizer/UserText tables, and the Composite tags
--               (Duration/Duration2 via CalcDuration). The JUNK
--               conditional list carries all of upstream's branches
--               (Olympus/Casio/Ricoh/Pentax/Pentax2/Lucas/TextJunk), as does
--               the WebP `EXIF` list, and ProcessSGLT/ProcessSLLT/
--               ProcessLucas are ported.
--               Deferred (not exercised by the vendored images):
--               MBWF/RF64 and verbose per-chunk dumps.  The write-include
--               WriteRIFF.pl is lexiftool/WriteRIFF.lua, bound here as an
--               AUTOLOAD closure (see the predeclaration). ProcessRIFF's
--               "minimal support for a few obscure lossless audio formats"
--               branch (LA/OFR/PAC/WavPack) is ported -- WavPack.lua's
--               ProcessWV hands the file here after reading its own header.
--------------------------------------------------------------------------------

local RIFF = {}
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local uv = perl.uv
local substr = perl.substr
local matches, subst = perl.matches, perl.subst
local sprintf = perl.sprintf
local perlStr = perl.str
local unpack, join = perl.unpack, perl.join
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local loadModule = ExifTool.loadModule

-- (upstream's predeclaration `sub WriteRIFF($$);`: WriteRIFF is the sub of
--  WriteRIFF.pl, which upstream AUTOLOADs -- DoAutoLoad loads it on the
--  first call.  Here it is bound to a closure that loads WriteRIFF.lua on
--  first use)
function RIFF.WriteRIFF(...) return require('lexiftool.WriteRIFF').WriteRIFF(...) end

RIFF.audioEncoding = { -- #2
    Notes = 'These "TwoCC" audio encoding codes are used in RIFF and ASF files.',
    [0x01] = 'Microsoft PCM',
    [0x02] = 'Microsoft ADPCM',
    [0x03] = 'Microsoft IEEE float',
    [0x04] = 'Compaq VSELP',
    [0x05] = 'IBM CVSD',
    [0x06] = 'Microsoft a-Law',
    [0x07] = 'Microsoft u-Law',
    [0x08] = 'Microsoft DTS',
    [0x09] = 'DRM',
    [0x0a] = 'WMA 9 Speech',
    [0x0b] = 'Microsoft Windows Media RT Voice',
    [0x10] = 'OKI-ADPCM',
    [0x11] = 'Intel IMA/DVI-ADPCM',
    [0x12] = 'Videologic Mediaspace ADPCM',
    [0x13] = 'Sierra ADPCM',
    [0x14] = 'Antex G.723 ADPCM',
    [0x15] = 'DSP Solutions DIGISTD',
    [0x16] = 'DSP Solutions DIGIFIX',
    [0x17] = 'Dialoic OKI ADPCM',
    [0x18] = 'Media Vision ADPCM',
    [0x19] = 'HP CU',
    [0x1a] = 'HP Dynamic Voice',
    [0x20] = 'Yamaha ADPCM',
    [0x21] = 'SONARC Speech Compression',
    [0x22] = 'DSP Group True Speech',
    [0x23] = 'Echo Speech Corp.',
    [0x24] = 'Virtual Music Audiofile AF36',
    [0x25] = 'Audio Processing Tech.',
    [0x26] = 'Virtual Music Audiofile AF10',
    [0x27] = 'Aculab Prosody 1612',
    [0x28] = 'Merging Tech. LRC',
    [0x30] = 'Dolby AC2',
    [0x31] = 'Microsoft GSM610',
    [0x32] = 'MSN Audio',
    [0x33] = 'Antex ADPCME',
    [0x34] = 'Control Resources VQLPC',
    [0x35] = 'DSP Solutions DIGIREAL',
    [0x36] = 'DSP Solutions DIGIADPCM',
    [0x37] = 'Control Resources CR10',
    [0x38] = 'Natural MicroSystems VBX ADPCM',
    [0x39] = 'Crystal Semiconductor IMA ADPCM',
    [0x3a] = 'Echo Speech ECHOSC3',
    [0x3b] = 'Rockwell ADPCM',
    [0x3c] = 'Rockwell DIGITALK',
    [0x3d] = 'Xebec Multimedia',
    [0x40] = 'Antex G.721 ADPCM',
    [0x41] = 'Antex G.728 CELP',
    [0x42] = 'Microsoft MSG723',
    [0x43] = 'IBM AVC ADPCM',
    [0x45] = 'ITU-T G.726',
    [0x50] = 'Microsoft MPEG',
    [0x51] = 'RT23 or PAC',
    [0x52] = 'InSoft RT24',
    [0x53] = 'InSoft PAC',
    [0x55] = 'MP3',
    [0x59] = 'Cirrus',
    [0x60] = 'Cirrus Logic',
    [0x61] = 'ESS Tech. PCM',
    [0x62] = 'Voxware Inc.',
    [0x63] = 'Canopus ATRAC',
    [0x64] = 'APICOM G.726 ADPCM',
    [0x65] = 'APICOM G.722 ADPCM',
    [0x66] = 'Microsoft DSAT',
    [0x67] = 'Microsoft DSAT DISPLAY',
    [0x69] = 'Voxware Byte Aligned',
    [0x70] = 'Voxware AC8',
    [0x71] = 'Voxware AC10',
    [0x72] = 'Voxware AC16',
    [0x73] = 'Voxware AC20',
    [0x74] = 'Voxware MetaVoice',
    [0x75] = 'Voxware MetaSound',
    [0x76] = 'Voxware RT29HW',
    [0x77] = 'Voxware VR12',
    [0x78] = 'Voxware VR18',
    [0x79] = 'Voxware TQ40',
    [0x7a] = 'Voxware SC3',
    [0x7b] = 'Voxware SC3',
    [0x80] = 'Soundsoft',
    [0x81] = 'Voxware TQ60',
    [0x82] = 'Microsoft MSRT24',
    [0x83] = 'AT&T G.729A',
    [0x84] = 'Motion Pixels MVI MV12',
    [0x85] = 'DataFusion G.726',
    [0x86] = 'DataFusion GSM610',
    [0x88] = 'Iterated Systems Audio',
    [0x89] = 'Onlive',
    [0x8a] = 'Multitude, Inc. FT SX20',
    [0x8b] = 'Infocom ITS A/S G.721 ADPCM',
    [0x8c] = 'Convedia G729',
    [0x8d] = 'Not specified congruency, Inc.',
    [0x91] = 'Siemens SBC24',
    [0x92] = 'Sonic Foundry Dolby AC3 APDIF',
    [0x93] = 'MediaSonic G.723',
    [0x94] = 'Aculab Prosody 8kbps',
    [0x97] = 'ZyXEL ADPCM',
    [0x98] = 'Philips LPCBB',
    [0x99] = 'Studer Professional Audio Packed',
    [0xa0] = 'Malden PhonyTalk',
    [0xa1] = 'Racal Recorder GSM',
    [0xa2] = 'Racal Recorder G720.a',
    [0xa3] = 'Racal G723.1',
    [0xa4] = 'Racal Tetra ACELP',
    [0xb0] = 'NEC AAC NEC Corporation',
    [0xff] = 'AAC',
    [0x100] = 'Rhetorex ADPCM',
    [0x101] = 'IBM u-Law',
    [0x102] = 'IBM a-Law',
    [0x103] = 'IBM ADPCM',
    [0x111] = 'Vivo G.723',
    [0x112] = 'Vivo Siren',
    [0x120] = 'Philips Speech Processing CELP',
    [0x121] = 'Philips Speech Processing GRUNDIG',
    [0x123] = 'Digital G.723',
    [0x125] = 'Sanyo LD ADPCM',
    [0x130] = 'Sipro Lab ACEPLNET',
    [0x131] = 'Sipro Lab ACELP4800',
    [0x132] = 'Sipro Lab ACELP8V3',
    [0x133] = 'Sipro Lab G.729',
    [0x134] = 'Sipro Lab G.729A',
    [0x135] = 'Sipro Lab Kelvin',
    [0x136] = 'VoiceAge AMR',
    [0x140] = 'Dictaphone G.726 ADPCM',
    [0x150] = 'Qualcomm PureVoice',
    [0x151] = 'Qualcomm HalfRate',
    [0x155] = 'Ring Zero Systems TUBGSM',
    [0x160] = 'Microsoft Audio1',
    [0x161] = 'Windows Media Audio V2 V7 V8 V9 / DivX audio (WMA) / Alex AC3 Audio',
    [0x162] = 'Windows Media Audio Professional V9',
    [0x163] = 'Windows Media Audio Lossless V9',
    [0x164] = 'WMA Pro over S/PDIF',
    [0x170] = 'UNISYS NAP ADPCM',
    [0x171] = 'UNISYS NAP ULAW',
    [0x172] = 'UNISYS NAP ALAW',
    [0x173] = 'UNISYS NAP 16K',
    [0x174] = 'MM SYCOM ACM SYC008 SyCom Technologies',
    [0x175] = 'MM SYCOM ACM SYC701 G726L SyCom Technologies',
    [0x176] = 'MM SYCOM ACM SYC701 CELP54 SyCom Technologies',
    [0x177] = 'MM SYCOM ACM SYC701 CELP68 SyCom Technologies',
    [0x178] = 'Knowledge Adventure ADPCM',
    [0x180] = 'Fraunhofer IIS MPEG2AAC',
    [0x190] = 'Digital Theater Systems DTS DS',
    [0x200] = 'Creative Labs ADPCM',
    [0x202] = 'Creative Labs FASTSPEECH8',
    [0x203] = 'Creative Labs FASTSPEECH10',
    [0x210] = 'UHER ADPCM',
    [0x215] = 'Ulead DV ACM',
    [0x216] = 'Ulead DV ACM',
    [0x220] = 'Quarterdeck Corp.',
    [0x230] = 'I-Link VC',
    [0x240] = 'Aureal Semiconductor Raw Sport',
    [0x241] = 'ESST AC3',
    [0x250] = 'Interactive Products HSX',
    [0x251] = 'Interactive Products RPELP',
    [0x260] = 'Consistent CS2',
    [0x270] = 'Sony SCX',
    [0x271] = 'Sony SCY',
    [0x272] = 'Sony ATRAC3',
    [0x273] = 'Sony SPC',
    [0x280] = 'TELUM Telum Inc.',
    [0x281] = 'TELUMIA Telum Inc.',
    [0x285] = 'Norcom Voice Systems ADPCM',
    [0x300] = 'Fujitsu FM TOWNS SND',
    [0x301] = 'Fujitsu (not specified)',
    [0x302] = 'Fujitsu (not specified)',
    [0x303] = 'Fujitsu (not specified)',
    [0x304] = 'Fujitsu (not specified)',
    [0x305] = 'Fujitsu (not specified)',
    [0x306] = 'Fujitsu (not specified)',
    [0x307] = 'Fujitsu (not specified)',
    [0x308] = 'Fujitsu (not specified)',
    [0x350] = 'Micronas Semiconductors, Inc. Development',
    [0x351] = 'Micronas Semiconductors, Inc. CELP833',
    [0x400] = 'Brooktree Digital',
    [0x401] = 'Intel Music Coder (IMC)',
    [0x402] = 'Ligos Indeo Audio',
    [0x450] = 'QDesign Music',
    [0x500] = 'On2 VP7 On2 Technologies',
    [0x501] = 'On2 VP6 On2 Technologies',
    [0x680] = 'AT&T VME VMPCM',
    [0x681] = 'AT&T TCP',
    [0x700] = 'YMPEG Alpha (dummy for MPEG-2 compressor)',
    [0x8ae] = 'ClearJump LiteWave (lossless)',
    [0x1000] = 'Olivetti GSM',
    [0x1001] = 'Olivetti ADPCM',
    [0x1002] = 'Olivetti CELP',
    [0x1003] = 'Olivetti SBC',
    [0x1004] = 'Olivetti OPR',
    [0x1100] = 'Lernout & Hauspie',
    [0x1101] = 'Lernout & Hauspie CELP codec',
    [0x1102] = 'Lernout & Hauspie SBC codec',
    [0x1103] = 'Lernout & Hauspie SBC codec',
    [0x1104] = 'Lernout & Hauspie SBC codec',
    [0x1400] = 'Norris Comm. Inc.',
    [0x1401] = 'ISIAudio',
    [0x1500] = 'AT&T Soundspace Music Compression',
    [0x181c] = 'VoxWare RT24 speech codec',
    [0x181e] = 'Lucent elemedia AX24000P Music codec',
    [0x1971] = 'Sonic Foundry LOSSLESS',
    [0x1979] = 'Innings Telecom Inc. ADPCM',
    [0x1c07] = 'Lucent SX8300P speech codec',
    [0x1c0c] = 'Lucent SX5363S G.723 compliant codec',
    [0x1f03] = 'CUseeMe DigiTalk (ex-Rocwell)',
    [0x1fc4] = 'NCT Soft ALF2CD ACM',
    [0x2000] = 'FAST Multimedia DVM',
    [0x2001] = 'Dolby DTS (Digital Theater System)',
    [0x2002] = 'RealAudio 1 / 2 14.4',
    [0x2003] = 'RealAudio 1 / 2 28.8',
    [0x2004] = 'RealAudio G2 / 8 Cook (low bitrate)',
    [0x2005] = 'RealAudio 3 / 4 / 5 Music (DNET)',
    [0x2006] = 'RealAudio 10 AAC (RAAC)',
    [0x2007] = 'RealAudio 10 AAC+ (RACP)',
    [0x2500] = 'Reserved range to 0x2600 Microsoft',
    [0x3313] = 'makeAVIS (ffvfw fake AVI sound from AviSynth scripts)',
    [0x4143] = 'Divio MPEG-4 AAC audio',
    [0x4201] = 'Nokia adaptive multirate',
    [0x4243] = 'Divio G726 Divio, Inc.',
    [0x434c] = 'LEAD Speech',
    [0x564c] = 'LEAD Vorbis',
    [0x5756] = 'WavPack Audio',
    [0x674f] = 'Ogg Vorbis (mode 1)',
    [0x6750] = 'Ogg Vorbis (mode 2)',
    [0x6751] = 'Ogg Vorbis (mode 3)',
    [0x676f] = 'Ogg Vorbis (mode 1+)',
    [0x6770] = 'Ogg Vorbis (mode 2+)',
    [0x6771] = 'Ogg Vorbis (mode 3+)',
    [0x7000] = '3COM NBX 3Com Corporation',
    [0x706d] = 'FAAD AAC',
    [0x7a21] = 'GSM-AMR (CBR, no SID)',
    [0x7a22] = 'GSM-AMR (VBR, including SID)',
    [0xa100] = 'Comverse Infosys Ltd. G723 1',
    [0xa101] = 'Comverse Infosys Ltd. AVQSBC',
    [0xa102] = 'Comverse Infosys Ltd. OLDSBC',
    [0xa103] = 'Symbol Technologies G729A',
    [0xa104] = 'VoiceAge AMR WB VoiceAge Corporation',
    [0xa105] = 'Ingenient Technologies Inc. G726',
    [0xa106] = 'ISO/MPEG-4 advanced audio Coding',
    [0xa107] = 'Encore Software Ltd G726',
    [0xa109] = 'Speex ACM Codec xiph.org',
    [0xdfac] = 'DebugMode SonicFoundry Vegas FrameServer ACM Codec',
    [0xe708] = 'Unknown -',
    [0xf1ac] = 'Free Lossless Audio Codec FLAC',
    [0xfffe] = 'Extensible',
    [0xffff] = 'Development',
}

-- RIFF chunks containing image data (to include in ImageDataHash digest)
local isImageData = {
    LIST_movi = 1, -- (AVI: contains ##db, ##dc, ##wb)
    data = 1,      -- (WAV)
    ['VP8 ']=1, VP8L=1, ANIM=1, ANMF=1, ALPH=1, -- (WebP)
}

-- recognized RIFF variants (upstream %riffType)
local riffType = {
    ['WAVE'] = 'WAV', ['AVI '] = 'AVI', ['WEBP'] = 'WEBP',
    ['LA02'] = 'LA',  ['LA03'] = 'LA',  ['LA04'] = 'LA',
    ['OFR '] = 'OFR', ['LPAC'] = 'PAC', ['wvpk'] = 'WV',
}

-- MIME types of recognized RIFF-format files (upstream %riffMimeType)
local riffMimeType = {
    WAV  = 'audio/x-wav',
    AVI  = 'video/x-msvideo',
    WEBP = 'image/webp',
    LA   = 'audio/x-nspaudio',
    OFR  = 'audio/x-ofr',
    PAC  = 'audio/x-lpac',
    WV   = 'audio/x-wavpack',
}

-- character sets for recognized Windows code pages (upstream %code2charset)
local code2charset = {
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

-- RIFF main table (upstream %Image::ExifTool::RIFF::Main, read subset)
RIFF.Main = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
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
    ['fmt '] = {
        Name = 'AudioFormat',
        SubDirectory = { TagTable = 'lexiftool.RIFF.AudioFormat' },
    },
    bext = {
        Name = 'BroadcastExtension',
        SubDirectory = { TagTable = 'lexiftool.RIFF.BroadcastExt' },
    },
    ds64 = { -- #15
        Name = 'DataSize64',
        SubDirectory = { TagTable = 'lexiftool.RIFF.DS64' },
    },
    list = 'ListType', -- #15
    labl = { -- #16 (in 'adtl' chunk)
        Name = 'CuePointLabel',
        Priority = 0, -- (so they are stored in sequence)
        ValueConv = function(_self, val)
            local str = substr(val, 4)
            str = str:gsub('\0+$', '')
            return ExifTool.Get32u(val, 0) .. ' ' .. str
        end,
    },
    note = { -- #16 (in 'adtl' chunk)
        Name = 'CuePointNote',
        Priority = 0, -- (so they are stored in sequence)
        ValueConv = function(_self, val)
            local str = substr(val, 4)
            str = str:gsub('\0+$', '')
            return ExifTool.Get32u(val, 0) .. ' ' .. str
        end,
    },
    ltxt = { -- #16 (in 'adtl' chunk)
        Name = 'LabeledText',
        Notes = 'CuePointID Length Purpose Country Language Dialect Codepage Text',
        Priority = 0, -- (so they are stored in sequence)
        ValueConv = function(_self, val)
            local cuePointID = ExifTool.Get32u(val, 0)
            local sampleLength = ExifTool.Get32u(val, 4)
            local purpose = "'" .. val:sub(9, 12) .. "'"
            local country = ExifTool.Get16u(val, 12)
            local language = ExifTool.Get16u(val, 14)
            local dialect = ExifTool.Get16u(val, 16)
            local codepage = ExifTool.Get16u(val, 18)
            local txt = substr(val, 18)
            txt = txt:gsub('\0+$', '')
            return table.concat({ cuePointID, sampleLength, purpose, country, language, dialect, codepage, txt }, ' ')
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
            -- (ProcessProc set below -- see the PROCESS_PROC assignments)
        },
    },
    LIST_hydt = { -- #PH (Pentax metadata)
        Name = 'PentaxData',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.AVI',
            -- (ProcessProc set below -- see the PROCESS_PROC assignments)
        },
    },
    LIST_pntx = { -- Andras Salamon (Q-S1 AVI)
        Name = 'PentaxData2',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.AVI',
            -- (ProcessProc set below -- see the PROCESS_PROC assignments)
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
            Condition = function(_self, valPt)
                return perl.matches(valPt or '', '^OLYMDigital Camera') ~= nil
            end,
            SubDirectory = { TagTable = 'lexiftool.Olympus.AVI' },
        },
        {
            Name = 'CasioJunk',
            Condition = function(_self, valPt) return perl.matches(valPt or '', '^QVMI') ~= nil end,
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
            Condition = function(_self, valPt) return perl.matches(valPt or '', '^ucmt') ~= nil end,
            SubDirectory = {
                TagTable = 'lexiftool.Ricoh.AVI',
                ProcessProc = function(...) return RIFF.ProcessChunks(...) end,
            },
        },
        {
            Name = 'PentaxJunk', -- (Optio RS1000)
            Condition = function(_self, valPt)
                return perl.matches(valPt or '', '^IIII\\x01\\0') ~= nil
            end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.Junk' },
        },
        {
            Name = 'PentaxJunk2', -- (Optio RZ18)
            Condition = function(_self, valPt)
                return perl.matches(valPt or '', '^PENTDigital Camera') ~= nil
            end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.Junk2' },
        },
        {
            Name = 'LucasJunk', -- (Lucas LK-7900 Ace)
            Condition = function(_self, valPt) return matches(valPt, [[^0G(DA|PS)]]) ~= nil end,
            SubDirectory = {
                TagTable = 'lexiftool.QuickTimeStream.Stream',
                ProcessProc = function(...) return RIFF.ProcessLucas(...) end,
            },
        },
        {
            Name = 'TextJunk',
            -- try to interpret unknown junk as an ASCII string
            RawConv = function(_self, val)
                local s = val
                if s:match('^[^\0-\31\127-\255]+') and s:gsub('\0', ''):match('^[^\0-\31\127-\255]*$') then
                    return s:gsub('\0+$', '')
                end
                return nil
            end,
        },
    },
    _PMX = { -- #PH (Adobe CS3 Bridge)
        Name = 'XMP',
        Notes = 'AVI and WAV files',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    JUNQ = { -- #PH (Adobe CS3 Bridge)
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
        RawConv = function(_self, val) return ExifTool.Get32u(val, 0) end,
    },
   ['cue '] = {
        Name = 'CuePoints',
        Binary = 1,
        Notes = [[
            config_files/cutepointlist.config from full distribution will decode this
            and generate a list of cue points with labels
        ]],
    },
    plst = { Name = 'Playlist', Binary = 1 }, -- #16
    afsp = {},
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
        Condition = function(_self, val)
            return val and (val:sub(1, 4) == 'II\42\0' or val:sub(1, 4) == 'MM\0\42')
        end,
        Notes = 'WebP files',
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
        },
    }, { -- (WebP) - have also seen with "Exif\0\0" header - PH
        Name = 'EXIF',
        Condition = function(self, val)
            -- (upstream `... and ($self->Warn("Improper EXIF header",1) or 1)`)
            if matches(val, [[^Exif\0\0(II\x2a\0|MM\0\x2a)]]) == nil then return false end
            self:Warn('Improper EXIF header', 1)
            return true
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = ExifTool.ProcessTIFF,
            Start = 6,
        },
    }, {
        Name = 'UnknownEXIF',
        Binary = 1,
    } },
    ['XMP '] = { -- #14 (WebP)
        Name = 'XMP',
        Notes = 'WebP files',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    ICCP = { -- #14 (WebP)
        Name = 'ICC_Profile',
        Notes = 'WebP files',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    ['VP8 '] = { -- (WebP lossy)
        Name = 'VP8Bitstream',
        Condition = function(_self, val)
            return val and val:sub(4, 4) == '\157' and val:sub(5, 5) == '\1' and val:sub(6, 6) == '\42'
        end,
        SubDirectory = { TagTable = 'lexiftool.RIFF.VP8' },
    },
    VP8L = { -- #14 (WebP lossless)
        Name = 'VP8L',
        Condition = function(_self, val)
            return val and val:sub(1, 1) == '\47'
        end,
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
    iXML = {
        SubDirectory = { TagTable = 'lexiftool.XMP.XML' },
    },
    aXML = {
        SubDirectory = { TagTable = 'lexiftool.XMP.XML' },
    },
    acid = {   -- writen by Acidizer
        Name = 'Acidizer',
        SubDirectory = { TagTable = 'lexiftool.RIFF.Acidizer' },
    },
    guan = 'Guano', -- #forum14831
}

-- the maker notes used by some digital cameras (upstream %RIFF::Junk)
RIFF.Junk = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Audio' },
}

-- Format and Audio Stream Format chunk data (upstream %RIFF::AudioFormat)
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
    [7] = 'BitsPerSample',
}

-- Broadcast Audio Extension 'bext' information (upstream %RIFF::BroadcastExt, ref 13)
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
            local s = val:gsub('%-', ':')
            s = s:gsub('^(%d%d%d%d:%d%d:%d%d) ', '%1 ')
            return s
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [338] = {
        Name = 'TimeReference',
        Notes = 'first sample count since midnight',
        Format = 'int32u[2]',
        ValueConv = function(_self, val)
            local lo = ExifTool.Get32u(val, 0)
            local hi = ExifTool.Get32u(val, 4)
            return uv(lo + hi * 4294967296)
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
            local s = (val:gsub('.', function(c) return string.format('%02x', c:byte()) end))
            s = s:gsub('0+$', '')
            return uc(s)
        end,
    },
    [602] = {
        Name = 'CodingHistory',
        Format = 'string[$size-602]',
    },
}

-- 64-bit chunk sizes (upstream %RIFF::DS64, ref 15)
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
        PrintConv = ExifTool.ConvertFileSize,
    },
    [1] = {
        Name = 'DataSize64',
        DataMember = 'DataSize64',
        RawConv = function(self, val)
            self.DataSize64 = val
            return val
        end,
        PrintConv = ExifTool.ConvertFileSize,
    },
    [2] = 'NumberOfSamples64',
}

-- Sampler chunk (upstream %RIFF::Sampler, ref 16)
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
            local str = sprintf('%.8x', val)
            str = str:gsub('^(%x%x)(%x%x)(%x%x)(%x%x)$', '%1:%2:%3:%4')
            return str
        end,
    },
    [7] = 'NumSampleLoops',
    [8] = 'SamplerDataLen',
    [9] = { Name = 'SamplerData', Format = 'undef[$size-40]', Binary = 1 },
}

-- Instrument chunk (upstream %RIFF::Instrument, ref 16)
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

-- Sub chunks of INFO LIST chunk (upstream %RIFF::Info)
RIFF.Info = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
    GROUPS = { [2] = 'Audio' },
    FORMAT = 'string',
    NOTES = [[
        RIFF INFO tags found in AVI video and WAV audio files.  Tags which are part
        of the EXIF 2.3 specification have an underlined Tag Name in the HTML
        version of this documentation.  Other tags are found in AVI files generated
        by some software.
    ]],
    IARL = 'ArchivalLocation',
    IART = { Name = 'Artist', Groups = { [2] = 'Author' } },
    ICMS = 'Commissioned',
    ICMT = 'Comment',
    ICOP = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    ICRD = {
        Name = 'DateCreated',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return (val:gsub('%-', ':')) end,
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
            local s = val
            s = s:gsub('([ \t\n\r\f\v]*%z)+$', '')
            s = s:gsub('[ \t\n\r\f\v]*%z', ', ', 1)
            s = s:gsub('%z+', '')
            return s
        end,
    },
    ISHP = 'Sharpness',
    ISRC = 'Source',
    ISRF = 'SourceForm',
    ITCH = 'Technician',
    -- 3rd party tags
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
    TLEN = { Name = 'Length', ValueConv = function(_self, val) return val / 1000 end, PrintConv = function(_self, val) return '"' .. val .. ' s"' end },
    TRCK = 'TrackNumber',
    TURL = 'URL',
    TVER = 'Version',
    LOCA = 'Location',
    TORG = 'Organization',
    -- Sony Vegas AVI tags (ref 11)
    TAPE = {
        Name = 'TapeName',
        Groups = { [2] = 'Video' },
    },
    TCOD = {
        Name = 'StartTimecode',
        Groups = { [2] = 'Video' },
        ValueConv = function(_self, val) return val * 1e-7 end,
        PrintConv = function(_self, val) return RIFF.ConvertTimecode(val) end,
    },
    TCDO = {
        Name = 'EndTimecode',
        Groups = { [2] = 'Video' },
        ValueConv = function(_self, val) return val * 1e-7 end,
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
            function(_self, val) return perlStr(val) .. ' frames captured' end,
            function(_self, val) return perlStr(val) .. ' dropped' end,
            function(_self, val) return 'Data rate ' .. val end,
            { [0] = 'Bad', [1] = 'OK' }, -- capture OK?
        },
    },
    DTIM = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            local v0, v1 = val:match('^([^ \t\n\r\f\v]+) ([^ \t\n\r\f\v]+)$')
            if not v0 then return nil end
            if val:match('^%d%d%d%d:%d%d:%d%d %d%d:%d%d:%d%d$') then return val end
            local n = 1e-7 * uv(tonumber(v0) * 4294967296 + tonumber(v1))
            n = n - 134774 * 24 * 3600
            if n == 0 then return val end
            return ExifTool.ConvertUnixTime(n)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    IDIT = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return RIFF.ConvertRIFFDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ISMP = 'TimeCode',
}

-- Sub chunks of EXIF LIST chunk (upstream %RIFF::Exif)
RIFF.Exif = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
    GROUPS = { [2] = 'Audio' },
    NOTES = 'These tags are part of the EXIF 2.3 specification for WAV audio files.',
    ever = 'ExifVersion',
    erel = 'RelatedImageFile',
    etim = { Name = 'TimeCreated', Groups = { [2] = 'Time' } },
    ecor = { Name = 'Make', Groups = { [2] = 'Camera' } },
    emdl = { Name = 'Model', Groups = { [2] = 'Camera' }, Description = 'Camera Model Name' },
    emnt = { Name = 'MakerNotes', Binary = 1 },
    eucm = {
        Name = 'UserComment',
        PrintConv = function(self, val) return loadModule('Exif').ConvertExifText(self, val, 'RIFF:UserComment') end,
    },
}

-- Sub chunks of hdrl LIST chunk (upstream %RIFF::Hdrl)
RIFF.Hdrl = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
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

-- Sub chunks of Tdat LIST chunk (upstream %RIFF::Tdat, ref PH)
RIFF.Tdat = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
    GROUPS = { [2] = 'Video' },
}

-- RIFF character set chunk (upstream %RIFF::CSET)
RIFF.CSET = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    FORMAT = 'int16u',
    [0] = {
        Name = 'CodePage',
        RawConv = function(self, val)
            self.CodePage = val
            return val
        end,
    },
    [1] = 'CountryCode',
    [2] = 'LanguageCode',
    [3] = 'Dialect',
}

-- AVI main header (upstream %RIFF::AVIHeader)
RIFF.AVIHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    [0] = {
        Name = 'FrameRate',
        -- (must use RawConv because raw value used in Composite tag)
        RawConv = function(_self, val) return val ~= 0 and 1e6 / val or nil end,
        PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
    },
    [1] = {
        Name = 'MaxDataRate',
        Notes = [[
            converted using SI byte prefixes unles the API ByteUnit option is set to
            "Binary"
        ]],
        PrintConv = function(self, val)
            local binary = self.OPTIONS.ByteUnit == 'Binary'
            local unit = binary and 'KiB/s' or 'kB/s'
            local div = binary and 1024 or 1000
            local tmp = val / div
            if tmp > 9999 then
                tmp = tmp / div
                unit = unit:gsub('^.', 'M')
            end
            return sprintf('%.4g %s', tmp, unit)
        end,
    },
    [4] = 'FrameCount',
    [6] = 'StreamCount',
    [8] = 'ImageWidth',
    [9] = 'ImageHeight',
}

-- AVI stream table (upstream %RIFF::Stream)
RIFF.Stream = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
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
                if not self.OPTIONS.ExtractEmbedded then
                    self:Warn('Use ExtractEmbedded option to extract timed text', 3)
                end
                return nil
            end,
        },
    },
}

-- Open DML tags (upstream %RIFF::OpenDML)
RIFF.OpenDML = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessChunks
    GROUPS = { [2] = 'Video' },
    dmlh = {
        Name = 'ExtendedAVIHeader',
        SubDirectory = { TagTable = 'lexiftool.RIFF.ExtAVIHdr' },
    },
}

-- Extended AVI Header tags (upstream %RIFF::ExtAVIHdr)
RIFF.ExtAVIHdr = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    [0] = 'TotalFrameCount',
}

-- AVI stream header (upstream %RIFF::StreamHeader)
RIFF.StreamHeader = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Video' },
    FORMAT = 'int32u',
    FIRST_ENTRY = 0,
    PRIORITY = 0, -- so we get values from the first stream
    [0] = {
        Name = 'StreamType',
        Format = 'string[4]',
        RawConv = function(self, val)
            self.RIFFStreamNum = (self.RIFFStreamNum or 0) + 1
            self.RIFFStreamType = val
            return val
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
            RawConv = function(self, val)
                self.RIFFStreamCodec = self.RIFFStreamCodec or {}
                self.RIFFStreamCodec[self.RIFFStreamNum - 1] = val
                return val
            end,
            Format = 'string[4]',
        },
        {
            Name = 'VideoCodec',
            Condition = function(self) return self.RIFFStreamType == 'vids' end,
            RawConv = function(self, val)
                self.RIFFStreamCodec = self.RIFFStreamCodec or {}
                self.RIFFStreamCodec[self.RIFFStreamNum - 1] = val
                return val
            end,
            Format = 'string[4]',
        },
        {
            Name = 'Codec',
            Format = 'string[4]',
            RawConv = function(self, val)
                self.RIFFStreamCodec = self.RIFFStreamCodec or {}
                self.RIFFStreamCodec[self.RIFFStreamNum - 1] = val
                return val
            end,
        },
    },
    [5] = {
        {
            Name = 'AudioSampleRate',
            Condition = function(self) return self.RIFFStreamType == 'auds' end,
            Format = 'rational64u',
            ValueConv = function(_self, val) return val ~= 0 and 1 / val or 0 end,
            PrintConv = function(_self, val) return math.floor(val * 100 + 0.5) / 100 end,
        },
        {
            Name = 'VideoFrameRate',
            Condition = function(self) return self.RIFFStreamType == 'vids' end,
            Format = 'rational64u',
            -- (must use RawConv because raw value used in Composite tag)
            RawConv = function(_self, val) return val ~= 0 and 1 / val or nil end,
            PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
        },
        {
            Name = 'StreamSampleRate',
            Format = 'rational64u',
            ValueConv = function(_self, val) return val ~= 0 and 1 / val or 0 end,
            PrintConv = function(_self, val) return math.floor(val * 1000 + 0.5) / 1000 end,
        },
    },
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
    [10] = {
        Name = 'Quality',
        PrintConv = function(_self, val) return val == 0xffffffff and 'Default' or perlStr(val) end,
    },
    [11] = {
        Name = 'SampleSize',
        PrintConv = function(_self, val)
            return val ~= 0 and (val .. ' byte' .. (val == 1 and '' or 's')) or 'Variable'
        end,
    },
}

-- AVI stream data (upstream %RIFF::StreamData)
RIFF.StreamData = {
    PROCESS_PROC = false, -- set below to RIFF.ProcessStreamData
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
    Zora = 'VendorName', -- (Samsung PL90 AVI files)
    unknown = {
        Name = 'UnknownData',
        RawConv = function(_self, val)
            if val:match('^[^\0-\31\127-\255]+$') then return val end
            return nil
        end,
    },
}

-- VP8 bitstream (upstream %RIFF::VP8, ref http://www.rfc-editor.org/rfc/pdfrfc/rfc6386.txt.pdf)
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

-- WebP lossless info (upstream %RIFF::VP8L, ref 14)
RIFF.VP8L = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'This chunk is found in lossless WebP files.',
    GROUPS = { [2] = 'Image' },
    [1] = {
        Name = 'ImageWidth',
        Format = 'int16u',
        Priority = 0,
        RawConv = function(self, val)
            self:OverrideFileType((self.VALUE.FileType or 'WEBP') .. ' (lossless)', nil, 'webp')
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

-- WebP extended info (upstream %RIFF::VP8X, ref 14)
RIFF.VP8X = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    NOTES = 'This chunk is found in extended WebP files.',
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
        } },
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

-- WebP animation info (upstream %RIFF::ANIM, ref 14)
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
        PrintConv = function(_self, val) return val == 0 and 'inf' or perlStr(val) end,
    },
}

-- WebP animation frame info (upstream %RIFF::ANMF, ref 14)
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
                self.VALUE.Duration = self.VALUE.Duration + (val & 0x0fff)
                return nil
            end
            return val & 0x0fff
        end,
        ValueConv = function(_self, val) return val / 1000 end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
}

-- WebP alpha info (upstream %RIFF::ALPH, ref 14)
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

-- Acidizer information (upstream %RIFF::Acidizer)
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
        } },
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
        PrintConv = function(_self, val)
            local a, b = val:match('(%d+) (%d+)')
            if a and b then return b .. '/' .. a end -- denominator comes first, so swap them
            return val
        end,
    },
    [20] = {
        Name = 'Tempo',
        Format = 'float',
    },
}

-- streamed USER txts written by Momento M6 dashcam (upstream %RIFF::UserText,
-- extracted only if the ExtractEmbedded option is used)
RIFF.UserText = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Location' },
    NOTES = [[
        Tags decoded from the USER-format txts stream written by Momento M6 dashcam.
        Extracted only if the ExtractEmbedded option is used.
    ]],
    [28] = { Name = 'GPSAltitude', Format = 'int32u', ValueConv = function(_self, val) return val / 10 end }, -- (NC)
    [40] = { Name = 'Accelerometer', Format = 'float[3]' },
    [56] = { Name = 'GPSSpeed', Format = 'float' }, -- km/h
    [60] = {
        Name = 'GPSLatitude',
        Format = 'float',
        ValueConv = function(_self, val)
            local deg = math.floor(val / 100)
            return deg + (val - deg * 100) / 60
        end,
        PrintConv = function(self, val) return loadModule('GPS').ToDMS(self, val, 1, 'N') end,
    },
    [64] = {
        Name = 'GPSLongitude',
        Format = 'float',
        ValueConv = function(_self, val)
            local deg = math.floor(val / 100)
            return -(deg + (val - deg * 100) / 60)
        end,
        PrintConv = function(self, val) return loadModule('GPS').ToDMS(self, val, 1, 'E') end,
    },
    [68] = {
        Name = 'GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        Format = 'int32u',
        ValueConv = function(_self, val) return ExifTool.ConvertUnixTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

-- RIFF composite tags (upstream %Image::ExifTool::RIFF::Composite)
RIFF.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Other' },
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
        -- upstream computes the whole value in RawConv (its return value IS
        -- the composite's raw value; BuildCompositeTags uses a RawConv result
        -- as the value when no ValueConv exists)
        RawConv = function(_self, vals)
            return RIFF.CalcDuration(vals)
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
    Duration2 = {
        Name = 'Duration',
        TagID = 'RIFF-Duration2',
        Require = {
            [0] = 'RIFF:AvgBytesPerSec',
        },
        Desire = {
            [1] = 'FileSize', -- (only used if 'data' length isn't available)
            [2] = 'FrameCount',
            [3] = 'VideoFrameCount',
        },
        -- upstream computes the whole value in RawConv (rejected values leave
        -- NO trace at all -- no duplicate-tag displacement); BuildCompositeTags
        -- uses a RawConv result as the value when no ValueConv exists
        RawConv = function(et, vals)
            -- (can't calculate duration like this for compressed audio types)
            if perl.matches(et.FileType or '', '^(LA|OFR|PAC|WV)$') then return nil end
            if vals[2] and vals[2] ~= 0 then return nil end
            if vals[3] and vals[3] ~= 0 then return nil end
            -- Perl truthiness: RIFFDataLen=0 (a zero-length data chunk, as in
            -- this fixture) must fall back to FileSize, matching upstream's
            -- `$$self{RIFFDataLen} || $val[1]`
            local dataLen = et.RIFFDataLen
            if not dataLen or dataLen == 0 then dataLen = vals[1] end
            if not (vals[0] and vals[0] ~= 0 and dataLen) then return nil end
            return dataLen / vals[0]
        end,
        PrintConv = function(_self, val) return ExifTool.ConvertDuration(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.RIFF', nil, RIFF)

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WriteRIFF.pl -- WriteRIFF is bound to a
--  loader closure at its predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Convert RIFF date to EXIF format (upstream ConvertRIFFDate)
-- Inputs: 0) date string
-- Returns: EXIF date string
--------------------------------------------------------------------------------
local monthNum = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}
function RIFF.ConvertRIFFDate(val)
    local part0, part1, part2, part3, part4 = val:match('^([^ \t\n\r\f\v]+) ([^ \t\n\r\f\v]+) ([^ \t\n\r\f\v]+) ([^ \t\n\r\f\v]+) ([^ \t\n\r\f\v]+)')
    if part0 and part1 and part2 and part3 and part4 then
        local m = monthNum[ucfirst(lc(part1))]
        if m then
            -- the standard AVI date format (eg. "Mon Mar 10 15:04:43 2003")
            return sprintf('%.4d:%.2d:%.2d %s', tonumber(part4), m, tonumber(part2), part3)
        end
    end
    local y1, m1, d1, h1, mi1, pm = val:match('(%d%d%d%d)/[ \t\n\r\f\v]*(%d+)/[ \t\n\r\f\v]*(%d+)/?[ \t\n\r\f\v]+(%d+):[ \t\n\r\f\v]*(%d+)[ \t\n\r\f\v]*(P?)')
    if y1 then
        -- the Casio QV-3EX writes dates like "2001/ 1/27  1:42PM",
        -- and the Casio EX-Z30 writes "2005/11/28/ 09:19"... doh!
        return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:00', tonumber(y1), tonumber(m1), tonumber(d1), tonumber(h1) + (pm ~= '' and 12 or 0), tonumber(mi1))
    end
    local y2, m2, d2, t2 = val:match('(%d%d%d%d)[%-/](%d+)[%-/](%d+)[ \t\n\r\f\v]+(%d+:%d+:%d+)')
    if y2 then
        -- the Konica KD500Z writes "2002-12-16  15:35:01\0\0"
        return table.concat({ y2, m2, d2 }, ':') .. ' ' .. t2
    end
    return val
end

--------------------------------------------------------------------------------
-- Print time (upstream ConvertTimecode)
-- Inputs: 0) time in seconds
-- Returns: time string
--------------------------------------------------------------------------------
function RIFF.ConvertTimecode(val)
    local hr = math.floor(val / 3600)
    val = val - hr * 3600
    local min = math.floor(val / 60)
    val = val - min * 60
    local ss = sprintf('%05.2f', val)
    if tonumber(ss) >= 60 then -- handle round-off problems
        ss = '00.00'
        min = min + 1
        if min >= 60 then
            min = min - 60
            hr = hr + 1
        end
    end
    return sprintf('%d:%.2d:%s', hr, min, ss)
end

--------------------------------------------------------------------------------
-- Calculate duration of RIFF (upstream CalcDuration, read subset without
-- the sub-document loop -- concatenated multi-RIFF AVI files are not
-- exercised by any vendored image)
-- Inputs: 0) ExifTool object, 1) values list [FrameRate, FrameCount, VideoFrameRate, VideoFrameCount]
-- Returns: Duration in seconds or undef
--------------------------------------------------------------------------------
function RIFF.CalcDuration(vals)
    local dur1
    if vals[0] and vals[0] ~= 0 then
        dur1 = vals[1] / vals[0]
    end
    if vals[2] and vals[2] ~= 0 and vals[3] and vals[3] ~= 0 then
        local dur2 = vals[3] / vals[2]
        local rat = dur1 / dur2
        if rat > 1.9 and rat < 3.1 then
            dur1 = dur2
        end
    end
    return dur1
end

--------------------------------------------------------------------------------
-- Make tag information hash for unknown tag (upstream MakeTagInfo)
-- Inputs: 0) tag table ref, 1) tag ID
-- Port note: takes the ExifTool object as well, since AddTagToTable is a
-- method here (upstream's is a plain sub exported from Image::ExifTool)
--------------------------------------------------------------------------------
local function MakeTagInfo(et, tagTablePtr, tag)
    local name = tag
    local n = 0
    name = name:gsub('[\0-\31\127-\255]', function(c)
        n = n + 1
        return 'x' .. string.format('%02x', c:byte())
    end)
    if n > 2 then
        -- print in hex if tag is numerical
        name = sprintf('0x%.4x', ExifTool.Get32u(tag, 0))
    end
    et:AddTagToTable(tagTablePtr, tag, {
        Name = 'Unknown_' .. name,
        Description = 'Unknown ' .. name,
        Unknown = 1,
        Binary = 1,
    })
end

--------------------------------------------------------------------------------
-- Process RIFF chunks (upstream ProcessChunks; read subset without the
-- Base-adjust eval and verbose per-entry dumps)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function RIFF.ProcessChunks(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart or 0
    local size = dirInfo.DirLen
    local endPos = start + size
    local base = dirInfo.Base or 0
    local verbose = et.OPTIONS.Verbose
    local unknown = et.OPTIONS.Unknown
    local charset = et.OPTIONS.CharsetRIFF

    if not perl.truthy(charset) then
        if et.CodePage then
            charset = code2charset[et.CodePage]
        elseif charset and charset == '0' then
            charset = 'Latin'
        end
    end

    if perl.truthy(verbose) then
        et:VerboseDir(dirInfo.DirName, 0, size)
    end

    while start + 8 <= endPos do
        local tag = substr(dataPt, start, 4)
        local len = ExifTool.Get32u(dataPt, start + 4)
        start = start + 8
        if start + len > endPos then
            et:Warn('Bad ' .. tag .. ' chunk')
            return 0
        end
        if tag == 'LIST' and len >= 4 then
            tag = tag .. '_' .. substr(dataPt, start, 4)
            len = len - 4
            start = start + 4
        end
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        local val
        local baseShift = 0
        if tagInfo then
            if tagInfo.SubDirectory then
                -- adjust base if necessary (needed for maker notes in AVI
                -- videos, e.g. Pentax's `Base => '$start'` -- upstream
                -- RIFF.pm evaluates `Base` with $start as the absolute
                -- chunk-data address)
                local newBase = tagInfo.SubDirectory.Base
                if newBase ~= nil then
                    local absStart = start + base
                    if type(newBase) == 'function' then
                        newBase = newBase(et, nil, absStart)
                    else
                        newBase = tonumber(newBase)
                    end
                    baseShift = newBase - base
                end
            elseif not tagInfo.Binary then
                local format = tagInfo.Format or tagTablePtr.FORMAT
                if format and format == 'string' then
                    val = substr(dataPt, start, len)
                    val = val:gsub('\0+$', '') -- remove trailing nulls from strings
                    if perl.truthy(charset) then val = et:Decode(val, charset) end
                end
            end
        elseif perl.truthy(verbose) or perl.truthy(unknown) then
            MakeTagInfo(et, tagTablePtr, tag)
        end
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            DataPos = dirInfo.DataPos - baseShift,
            Start = start,
            Size = len,
            Base = base + baseShift,
            Addr = base + baseShift + start,
        })
        if len & 0x01 == 0x01 then len = len + 1 end -- must account for padding if odd number of bytes
        start = start + len
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process stream data (upstream ProcessStreamData; read subset: only the
-- non-SubDirectory 'unknown' branch is exercised by a vendored image)
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function RIFF.ProcessStreamData(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local start = dirInfo.DirStart or 0
    local size = dirInfo.DirLen
    if size < 4 then return 0 end
    if perl.truthy(et.OPTIONS.Verbose) then
        et:VerboseDir(dirInfo.DirName, 0, size)
    end
    local tag = substr(dataPt, start, 4)
    local tagInfo = et:GetTagInfo(tagTablePtr, tag)
    if not tagInfo then
        tagInfo = et:GetTagInfo(tagTablePtr, 'unknown')
        if not tagInfo then return 1 end
    end
    local subdir = tagInfo.SubDirectory
    if tagInfo.SubDirectory then
        local offset = subdir.Start or 0
        local baseShift = dirInfo.DataPos + dirInfo.DirStart + offset
        local subdirInfo = {
            DataPt   = dataPt,
            DataPos  = dirInfo.DataPos - baseShift,
            Base     = (dirInfo.Base or 0) + baseShift,
            DataLen  = dirInfo.DataLen,
            DirStart = dirInfo.DirStart + offset,
            DirLen   = dirInfo.DirLen - offset,
            DirName  = subdir.DirName,
            Parent   = dirInfo.DirName,
        }
        if offset == 0 then
            -- allow processing of 2nd directory at the same address
            local addr = subdirInfo.DirStart + subdirInfo.DataPos + subdirInfo.Base
            if et.PROCESSED then et.PROCESSED[addr] = nil end
        end
        -- (we could set FIRST_EXIF_POS to $subdirInfo{Base} here to make
        --  htmlDump offsets relative to EXIF base if we wanted...)
        local subTable = et:GetTagTable(subdir.TagTable)
        et:ProcessDirectory(subdirInfo, subTable)
    else
        et:HandleTag(tagTablePtr, tag, nil, {
            DataPt = dataPt,
            DataPos = dirInfo.DataPos,
            Start = start,
            Size = size,
            TagInfo = tagInfo,
        })
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process BikeBro SGLT chunk (accelerometer data) (ref PH)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function RIFF.ProcessSGLT(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = #dataPt
    local ee = et:Options('ExtractEmbedded')
    local pos
    -- example accelerometer record:
    -- 0           1  2  3           4  5           6  7
    -- 00 00 00 24 02 00 00 01 17 04 00 00 00 00 00 00 00 00 9b 02
    -- frame------ ?? Xs X---------- Ys Y---------- Zs Z----------
    et.SET_GROUP0 = 'RIFF'
    et.SET_GROUP1 = 'RIFF'
    pos = 0
    while pos <= dataLen - 20 do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        local buff = substr(dataPt, pos)
        local a = { unpack('NCCNCNCN', buff) }
        local acc = { a[4] * (perl.truthy(a[3]) and -1 or 1) / 1e5, a[6] * (perl.truthy(a[5]) and -1 or 1) / 1e5, a[8] * (perl.truthy(a[7]) and -1 or 1) / 1e5 }
        et:HandleTag(tagTbl, 'FrameNumber', a[1])
        et:HandleTag(tagTbl, 'Accelerometer', join(' ', acc))
        if not perl.truthy(ee) then
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
--------------------------------------------------------------------------------
function RIFF.ProcessSLLT(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = #dataPt
    local ee = et:Options('ExtractEmbedded')
    local pos
    -- example GPS record:
    -- 0           1  2     3           4     5           6     7     8  9  10 11    12 13 14 15
    -- 00 00 00 17 01 00 00 03 fa 21 ec 00 35 01 6e c0 06 00 08 00 62 10 0b 1b 07 e2 03 0e 57 4e
    -- frame------ ?? lonDD lonDDDDDDDD latDD latDDDDDDDD alt-- spd-- hr mn sc yr--- mn dy EW NS
    et.SET_GROUP0 = 'RIFF'
    et.SET_GROUP1 = 'RIFF'
    pos = 0
    while pos <= dataLen - 30 do
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        local buff = substr(dataPt, pos)
        local a = { unpack('NCnNnNnnCCCnCCaa', buff) }
        -- - is $a[1] perhaps GPSStatus? (only seen 1, or perhaps record type 1=GPS, 2=acc?)
        local time = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2dZ', a[12], a[13], a[14], a[9], a[10], a[11])
        et:HandleTag(tagTbl, 'FrameNumber', a[1])
        et:HandleTag(tagTbl, 'GPSDateTime', time)
        et:HandleTag(tagTbl, 'GPSLatitude', (a[5] + a[6] / 1e8) * (a[16] == 'S' and -1 or 1))
        et:HandleTag(tagTbl, 'GPSLongitude', (a[3] + a[4] / 1e8) * (a[15] == 'W' and -1 or 1))
        et:HandleTag(tagTbl, 'GPSAltitude', a[7])
        et:HandleTag(tagTbl, 'GPSSpeed', a[8])
        et:HandleTag(tagTbl, 'GPSSpeedRef', 'K')
        if not perl.truthy(ee) then
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
--------------------------------------------------------------------------------
function RIFF.ProcessLucas(et, dirInfo, tagTbl)
    local dataPt = dirInfo.DataPt
    local dataLen = #dataPt

    if not perl.truthy(et:Options('ExtractEmbedded')) then
        et:Warn('Use ExtractEmbedded option to extract timed GPS', 3)
        return 1
    end
    local recLen = {    -- record lengths (not including 4-byte ID)
        ['0GDA'] = 24,
        ['0GPS'] = 48,
    }
    local date, time, lat, lon, alt, spd, sat, dop, ew, ns
    et.SET_GROUP0 = 'RIFF'
    et.SET_GROUP1 = 'RIFF'
    -- (`pos $$dataPt`, the position the /g loop below resumes from)
    local dataPtPos = 0
    while true do
        local rec, pos = matches(dataPt, [[(0GDA|0GPS)]], dataPtPos)
        if not rec then break end
        if pos + recLen[rec] > dataLen then et:Warn('Truncated ' .. rec .. ' record') break end
        et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
        et.DOC_NUM = et.DOC_COUNT
        -- records start with int64u sample date/time in ms since 1970
        et:HandleTag(tagTbl, 'SampleDateTime', ExifTool.Get64u(dataPt, pos) / 1000)
        if rec == '0GPS' then
            local len = ExifTool.Get32u(dataPt, pos + 8)
            local endPos = pos + recLen[rec] + len
            if endPos > dataLen then et:Warn('Truncated 0GPS record') break end
            local buff = substr(dataPt, pos + recLen[rec], len)
            -- (`pos $buff`, likewise; a failed /g match resets it to 0)
            local buffPos = 0
            while true do
                local gc, t, p = matches(buff, [[\$(GC|GA),(\d+),]], buffPos)
                if not gc then break end
                buffPos = p
                time = t
                if gc == 'GC' then
                    --     time   date   dist    ? sat dop alt  A
                    -- $GC,052350,180914,0000955,1,08,1.1,0017,,A*45\x0d\x0a\0
                    local d, sa, dp, al, e = matches(buff, [[\G(\d+),\d*,\d*,(\d+),([-\d.]+),(\d+),\d*,A]], buffPos)
                    if d then
                        date, sat, dop, alt = d, sa, dp, al
                        buffPos = e
                    else
                        buffPos = 0
                    end
                else
                    --     time   A lat       lon        spd N W
                    -- $GA,052351,A,0949.6626,07635.4439,049,N,E,*4C\x0d\x0a\0
                    local la, lo, sp, n, w, e = matches(buff, [[\GA,([\d.]+),([\d.]+),(\d+),([NS]),([EW])]], buffPos)
                    if la then
                        lat, lon, spd, ns, ew = la, lo, sp, n, w
                        buffPos = e
                        -- lat/long are in DDDMM.MMMM format
                        local deg = math.floor(lat / 100)
                        lat = deg + (lat - deg * 100) / 60
                        deg = math.floor(lon / 100)
                        lon = deg + (lon - deg * 100) / 60
                        if ns == 'S' then lat = lat * -1 end
                        if ew == 'W' then lon = lon * -1 end
                    else
                        buffPos = 0
                    end
                end
                -- look ahead to next NMEA-like sentence, and store the fix
                -- now only if the next sentence is not at the same time
                if not perl.isMatchDyn(buff, '\\$(GC|GA),' .. time .. ',', buffPos) then
                    dataPtPos = endPos -- luacheck: ignore 311 (upstream dead store: reset below)
                    local gc2 = matches(dataPt, [[\$(GC|GA),(\d+)]])
                    if not gc2 or gc2 ~= time then
                        time = subst(time, [[(\d{2})(\d{2})(\d{2})]], '$1:$2:$3Z')
                        if date then
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
                buffPos = p
            end
            pos = pos + len
        else -- this is an accelerometer (0GDA) record
            -- record has 4 more int32s values (the last is always 57 or 58 --
            -- maybe related to sample time in ms? -- not extracted)
            local acc = { perl.unpack('x' .. (pos + 8) .. 'V3', dataPt) }
            -- change to signed integer and divide by 256
            for i = 1, #acc do
                if acc[i] >= 0x80000000 then acc[i] = acc[i] - 4294967296 end
                acc[i] = ExifTool.NumStr(acc[i] / 256)
            end
            et:HandleTag(tagTbl, 'Accelerometer', perl.join(' ', acc))
        end
        dataPtPos = pos + recLen[rec]
    end
    et.SET_GROUP0 = nil
    et.SET_GROUP1 = nil
    et.DOC_NUM = 0
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a RIFF file (upstream ProcessRIFF, read subset:
-- no MBWF/RF64, no LargeFileSupport/LIST_movi error-recovery, no verbose
-- dumps)
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid RIFF file
--------------------------------------------------------------------------------
function RIFF.ProcessRIFF(et, dirInfo)
    local raf = dirInfo.RAF
    local verbose = et.OPTIONS.Verbose
    local unknown = et.OPTIONS.Unknown
    local fastScan = et.OPTIONS.FastScan
    local validate = et.OPTIONS.Validate
    local ee = et:Options('ExtractEmbedded')
    local hash = rawget(et, 'ImageDataHash')    -- (the member, not the method of that name)
    local base = 0
    local riffFileType
    local err

    -- verify this is a valid RIFF file
    local n, buff = raf:Read(12)
    if n ~= 12 then return 0 end
    if buff:sub(1, 4) == 'RIFF' then
        riffFileType = riffType[buff:sub(9, 12)]
        if not riffFileType then return 0 end
    elseif buff:sub(1, 4) == 'RF64' then
        return 0 -- (MBWF/RF64 deferred, not exercised by a vendored image)
    else
        -- minimal support for a few obscure lossless audio formats...
        local sig = buff:sub(1, 4)
        if not (sig == 'LA02' or sig == 'LA03' or sig == 'LA04' or
                sig == 'OFR ' or sig == 'LPAC' or sig == 'wvpk') then
            return 0
        end
        local n2, buf2 = raf:Read(1024)
        if not n2 or n2 == 0 then return 0 end
        riffFileType = riffType[sig]
        buff = buff .. buf2
        -- (upstream matches /WAVE(.{4})?(junk|fmt )/sg and then seeks to
        --  pos($buff) - 4, i.e. to the start of that junk/fmt word. The
        --  facade appends that same 0-based end offset after the captures)
        local _, _, pos_ = perl.matches(buff, [[(?s)WAVE(.{4})?(junk|fmt )]])
        if not pos_ then return 0 end
        if not raf:Seek(pos_ - 4, 0) then return 0 end
        base = pos_ - 16
    end
    local mime = riffFileType and riffMimeType[riffFileType]
    et:SetFileType(riffFileType, mime)
    et.RIFFStreamType = '' -- initialize stream type
    et.RIFFStreamCodec = {}
    ExifTool.SetByteOrder('II')
    local riffEnd = ExifTool.Get32u(buff, 4) + 8
    if riffEnd & 0x01 == 0x01 then riffEnd = riffEnd + 1 end -- (account for padding)
    local tagTablePtr = et:GetTagTable('lexiftool.RIFF.Main')
    local pos = 12

    -- read chunks in RIFF image
    while true do
        local num, chunkHdr = raf:Read(8)
        if num < 8 then
            err = num > 0 -- (a partial read is an error; clean EOF is not)
            if validate and pos ~= riffEnd then
                et:Warn('Incorrect RIFF chunk size' .. ' ' .. pos .. ' vs. ' .. riffEnd)
            end
            break
        end
        pos = pos + 8
        local tag = chunkHdr:sub(1, 4)
        local len = ExifTool.Get32u(chunkHdr, 4)
        -- tweak WEBP type if this is an extended WebP
        if tag == 'VP8X' and riffFileType == 'WEBP' then
            et:OverrideFileType('Extended WEBP', nil, 'webp')
        end
        -- special case: construct new tag name from specific LIST type
        if tag == 'LIST' then
            local n4, listType = raf:Read(4)
            if n4 ~= 4 then
                err = 1
                break
            end
            pos = pos + 4
            tag = tag .. '_' .. listType
            len = len - 4 -- already read 4 bytes (the LIST type)
        elseif tag == 'data' then
            et.RIFFDataLen = (et.RIFFDataLen or 0) + len
        end
        if len <= 0 then
            if len < 0 then
                et:Warn('Invalid chunk length')
            elseif tag == '\0\0\0\0' then
                -- avoid reading through corrupted files filled with nulls
                -- because it takes forever
                et:Warn('Encountered empty null chunk. Processing aborted')
            else
                -- (a zero-length chunk other than a null chunk is not an
                -- error; skip it and continue, matching upstream's `next`)
                goto continueLoop
            end
            break
        end
        -- stop when we hit the audio data or AVI index or AVI movie data
        -- (FastScan option only; normally we keep reading, since e.g. Adobe
        -- Bridge stores XMP after the movie data)
        if fastScan and (tag == 'data' or tag == 'idx1' or tag == 'LIST_movi') then
            break
        end
        -- RIFF chunks are padded to an even number of bytes
        local len2 = len + (len & 0x01)
        -- change name of stream txts data depending on the Codec
        local isTx, txNum = perl.isMatch(tag, [[^(\d{2})tx$]])
        if perl.truthy(ee) and isTx then
            tag = 'tx_' .. (et.RIFFStreamCodec[tonumber(txNum)] or 'Unknown')
            if tagTablePtr[tag] == nil then tag = 'tx_Unknown' end
            et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
            et.DOC_NUM = et.DOC_COUNT
        end
        local tagInfo = tagTablePtr[tag]
        -- (in LIST_movi chunk: ##db = uncompressed DIB, ##dc = compressed DIB, ##wb = audio data)
        -- upstream: `$tag !~ /^(data|idx1|LIST_movi|RIFF|\d{2}(db|dc|wb))$/`
        -- (PCRE2 via the facade -- Lua patterns have no alternation)
        local isSkippedChunk = perl.matches(tag, '^(data|idx1|LIST_movi|RIFF|\\d{2}(db|dc|wb))$')
        if tagInfo or ((perl.truthy(verbose) or perl.truthy(unknown)) and not isSkippedChunk) then
            local n2, dbuf = raf:Read(len2)
            if n2 < len then
                err = 1
                goto continueLoop
            end
            if n2 ~= len2 then
                et:Warn('No padding on odd-sized ' .. tag .. ' chunk')
            end
            if hash and isImageData[tag] then
                hash:add(dbuf)
                et:VPrint(0, et.INDENT .. "(ImageDataHash: '" .. tag .. "' chunk, " .. len2 .. ' bytes)\n')
            end
            local setGroups
            -- resolve conditional lists (e.g. the WebP EXIF chunk, whose
            -- entries gate on the raw value `^(II\x2a\0|MM\0\x2a)`) against
            -- the chunk value itself; HandleTag would otherwise re-resolve
            -- with no value and the condition could never match
            if tagInfo then
                tagInfo = et:GetTagInfo(tagTablePtr, tag, dbuf)
                if tagInfo and tagInfo.SetGroups then
                    et.SET_GROUP0 = tagInfo.SetGroups
                    et.SET_GROUP1 = tagInfo.SetGroups
                    setGroups = true
                end
            end
            if not tagInfo and (perl.truthy(verbose) or perl.truthy(unknown)) then
                MakeTagInfo(et, tagTablePtr, tag)
            end
            et:HandleTag(tagTablePtr, tag, dbuf, {
                DataPt = dbuf,
                DataPos = 0, -- (relative to Base)
                Start = 0,
                Size = len,
                Base = pos + base,
                TagInfo = tagInfo,
            })
            if setGroups then
                et.SET_GROUP0 = nil
                et.SET_GROUP1 = nil
            end
        else
            local rewind
            -- do hash if required
            if hash and isImageData[tag] then
                rewind = raf:Tell()
                et:ImageDataHash(raf, len2, "'" .. tag .. "' chunk")
            end
            if not rewind then
                if not raf:Seek(len2, 1) then
                    err = 1
                    goto continueLoop
                end
            end
        end
        pos = pos + len2
        ::continueLoop::
    end
    if err then et:Warn('Error reading RIFF file (corrupted?)') end
    return 1
end

-- (PROCESS_PROC fields are set here so the tables can reference the
-- functions defined above; the RIFF.Main LIST_ncdt/LIST_hydt/LIST_pntx
-- SubDirectory ProcessProc entries point at RIFF.ProcessChunks too, so
-- those are filled in here as well rather than in the table literal)
RIFF.Main.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Main.LIST_ncdt.SubDirectory.ProcessProc = RIFF.ProcessChunks
RIFF.Main.LIST_hydt.SubDirectory.ProcessProc = RIFF.ProcessChunks
RIFF.Main.LIST_pntx.SubDirectory.ProcessProc = RIFF.ProcessChunks
RIFF.Info.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Exif.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Hdrl.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Tdat.PROCESS_PROC = RIFF.ProcessChunks
RIFF.Stream.PROCESS_PROC = RIFF.ProcessChunks
RIFF.OpenDML.PROCESS_PROC = RIFF.ProcessChunks
RIFF.StreamData.PROCESS_PROC = RIFF.ProcessStreamData

return RIFF
