--------------------------------------------------------------------------------
-- File:         lexiftool/ID3.lua
-- Ported from:  lib/Image/ExifTool/ID3.pm
--
-- Description:  Read ID3 and Lyrics3 meta information
--
-- Revisions:    09/12/2005 - P. Harvey Created
--               09/08/2020 - PH Added Lyrics3 support
--
-- References:   1) http://www.id3.org/ (now https://id3.org)
--               2) http://www.mp3-tech.org/
--               3) http://www.fortunecity.com/underworld/sonic/3/id3tag.html
--               4) https://id3.org/Lyrics3
--
-- Port notes:   Complete port of ID3.pm: every table, lookup and sub, in
--               upstream order.  The %id3v2_common/%dateTimeConv spreads are
--               a `spread` helper that copies each tagInfo (GetTagTable stores
--               Table/TagID per tagInfo, which is also why upstream copies
--               the common hashes for v2_4).  DecodeString is forward-
--               declared so ProcessSynText, which upstream defines before it,
--               can call it, and it returns the list of strings (the scalar
--               context join is done by the callers).  %genre is keyed by
--               number, so PrintGenre maps a digit string with leading zeros
--               to its own (string) key as Perl's hash does.  The pos()-based
--               Lyrics3 v2.00 field walk tracks the match offset explicitly.
--               Not yet: the `Extra` (frame flags) verbose detail on the final
--               HandleTag of ProcessID3v2.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local subst = perl.subst
local eachMatch = perl.eachMatch
local isMatch = perl.isMatch
local matches = perl.matches
local truthy = perl.truthy
local tsort = perl.tsort
local perlStr = perl.str
local GetTagTable = ExifTool.GetTagTable
local RandomAccess = require('lexiftool.RandomAccess')
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst

local ID3 = {}

-- audio formats that we process after an ID3v2 header (in order)
local audioFormats = { 'APE', 'MPC', 'FLAC', 'OGG', 'MP3' }

-- audio formats where the processing proc is in a differently-named module
local audioModule = {
    MP3 = 'ID3',
    OGG = 'Ogg',
}

-- picture types for 'PIC' and 'APIC' tags
-- (Note: Duplicated in ID3, ASF and FLAC modules!)
local pictureType = {
    [0] = 'Other',
    [1] = '32x32 PNG Icon',
    [2] = 'Other Icon',
    [3] = 'Front Cover',
    [4] = 'Back Cover',
    [5] = 'Leaflet',
    [6] = 'Media',
    [7] = 'Lead Artist',
    [8] = 'Artist',
    [9] = 'Conductor',
    [10] = 'Band',
    [11] = 'Composer',
    [12] = 'Lyricist',
    [13] = 'Recording Studio or Location',
    [14] = 'Recording Session',
    [15] = 'Performance',
    [16] = 'Capture from Movie or Video',
    [17] = 'Bright(ly) Colored Fish',
    [18] = 'Illustration',
    [19] = 'Band Logo',
    [20] = 'Publisher Logo',
}

-- (port helper: copy a shared hash into a table, as a Perl `%hash` spread
--  does -- explicit entries win; table values are copied one level deep, since
--  GetTagTable stores Table/TagID in every tagInfo of the table it sets up)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then
                if type(v) == 'table' then
                    local c = {}
                    for k2, v2 in pairs(v) do c[k2] = v2 end
                    -- must also copy Groups hash if it exists
                    if type(c.Groups) == 'table' then
                        local groups = {}
                        for k2, v2 in pairs(c.Groups) do groups[k2] = v2 end
                        c.Groups = groups
                    end
                    v = c
                end
                t[k] = v
            end
        end
        return t
    end
end

local dateTimeConv = spread {
    ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- patch for names of user-defined tags which don't automatically generate very well
local userTagName = {
    ALBUMARTISTSORT = 'AlbumArtistSort',
    ASIN = 'ASIN',
}

-- This table is just for documentation purposes
ID3.Main = {
    VARS = { ID_FMT = 'none' },
    PROCESS_PROC = function(...) return ID3.ProcessID3Dir(...) end, -- (used to process 'id3 ' chunk in WAV files)
    NOTES = [[
        ExifTool extracts ID3 and Lyrics3 information from MP3, MPEG, WAV, WV, AIFF,
        OGG, FLAC, APE, DSF, MPC and RealAudio files.  ID3v2 tags which support
        multiple languages (eg. Comment and Lyrics) are extracted by specifying the
        tag name, followed by a dash ('-'), then a 3-character ISO 639-2 language
        code (eg. "Comment-spa"). See L<https://id3.org/> for the official ID3
        specification and L<http://www.loc.gov/standards/iso639-2/php/code_list.php>
        for a list of ISO 639-2 language codes.
    ]],
    ID3v1 = {
        Name = 'ID3v1',
        SubDirectory = { TagTable = 'lexiftool.ID3.v1' },
    },
    ID3v1Enh = {
        Name = 'ID3v1_Enh',
        SubDirectory = { TagTable = 'lexiftool.ID3.v1_Enh' },
    },
    ID3v22 = {
        Name = 'ID3v2_2',
        SubDirectory = { TagTable = 'lexiftool.ID3.v2_2' },
    },
    ID3v23 = {
        Name = 'ID3v2_3',
        SubDirectory = { TagTable = 'lexiftool.ID3.v2_3' },
    },
    ID3v24 = {
        Name = 'ID3v2_4',
        SubDirectory = { TagTable = 'lexiftool.ID3.v2_4' },
    },
}

-- Lyrics3 tags (ref 4)
ID3.Lyrics3 = {
    GROUPS = { [1] = 'Lyrics3', [2] = 'Audio' },
    NOTES = [[
        ExifTool extracts Lyrics3 version 1.00 and 2.00 tags from any file that
        supports ID3.  See L<https://id3.org/Lyrics3> for the specification.
    ]],
    IND = 'Indications',
    LYR = 'Lyrics',
    INF = 'AdditionalInfo',
    AUT = { Name = 'Author', Groups = { [2] = 'Author' } },
    EAL = 'ExtendedAlbumName',
    EAR = 'ExtendedArtistName',
    ETT = 'ExtendedTrackTitle',
    IMG = 'AssociatedImageFile',
    CRC = 'CRC', -- #PH
}

-- Mapping for ID3v1 Genre numbers
local genre = {
    [0] = 'Blues',
    [1] = 'Classic Rock',
    [2] = 'Country',
    [3] = 'Dance',
    [4] = 'Disco',
    [5] = 'Funk',
    [6] = 'Grunge',
    [7] = 'Hip-Hop',
    [8] = 'Jazz',
    [9] = 'Metal',
    [10] = 'New Age',
    [11] = 'Oldies',
    [12] = 'Other',
    [13] = 'Pop',
    [14] = 'R&B',
    [15] = 'Rap',
    [16] = 'Reggae',
    [17] = 'Rock',
    [18] = 'Techno',
    [19] = 'Industrial',
    [20] = 'Alternative',
    [21] = 'Ska',
    [22] = 'Death Metal',
    [23] = 'Pranks',
    [24] = 'Soundtrack',
    [25] = 'Euro-Techno',
    [26] = 'Ambient',
    [27] = 'Trip-Hop',
    [28] = 'Vocal',
    [29] = 'Jazz+Funk',
    [30] = 'Fusion',
    [31] = 'Trance',
    [32] = 'Classical',
    [33] = 'Instrumental',
    [34] = 'Acid',
    [35] = 'House',
    [36] = 'Game',
    [37] = 'Sound Clip',
    [38] = 'Gospel',
    [39] = 'Noise',
    [40] = 'Alt. Rock', -- (was AlternRock)
    [41] = 'Bass',
    [42] = 'Soul',
    [43] = 'Punk',
    [44] = 'Space',
    [45] = 'Meditative',
    [46] = 'Instrumental Pop',
    [47] = 'Instrumental Rock',
    [48] = 'Ethnic',
    [49] = 'Gothic',
    [50] = 'Darkwave',
    [51] = 'Techno-Industrial',
    [52] = 'Electronic',
    [53] = 'Pop-Folk',
    [54] = 'Eurodance',
    [55] = 'Dream',
    [56] = 'Southern Rock',
    [57] = 'Comedy',
    [58] = 'Cult',
    [59] = 'Gangsta Rap', -- (was Gansta)
    [60] = 'Top 40',
    [61] = 'Christian Rap',
    [62] = 'Pop/Funk',
    [63] = 'Jungle',
    [64] = 'Native American',
    [65] = 'Cabaret',
    [66] = 'New Wave',
    [67] = 'Psychedelic', -- (was misspelt)
    [68] = 'Rave',
    [69] = 'Showtunes',
    [70] = 'Trailer',
    [71] = 'Lo-Fi',
    [72] = 'Tribal',
    [73] = 'Acid Punk',
    [74] = 'Acid Jazz',
    [75] = 'Polka',
    [76] = 'Retro',
    [77] = 'Musical',
    [78] = 'Rock & Roll',
    [79] = 'Hard Rock',
    -- The following genres are Winamp extensions
    [80] = 'Folk',
    [81] = 'Folk-Rock',
    [82] = 'National Folk',
    [83] = 'Swing',
    [84] = 'Fast-Fusion', -- (was Fast Fusion)
    [85] = 'Bebop', -- (was misspelt)
    [86] = 'Latin',
    [87] = 'Revival',
    [88] = 'Celtic',
    [89] = 'Bluegrass',
    [90] = 'Avantgarde',
    [91] = 'Gothic Rock',
    [92] = 'Progressive Rock',
    [93] = 'Psychedelic Rock',
    [94] = 'Symphonic Rock',
    [95] = 'Slow Rock',
    [96] = 'Big Band',
    [97] = 'Chorus',
    [98] = 'Easy Listening',
    [99] = 'Acoustic',
    [100] = 'Humour',
    [101] = 'Speech',
    [102] = 'Chanson',
    [103] = 'Opera',
    [104] = 'Chamber Music',
    [105] = 'Sonata',
    [106] = 'Symphony',
    [107] = 'Booty Bass',
    [108] = 'Primus',
    [109] = 'Porn Groove',
    [110] = 'Satire',
    [111] = 'Slow Jam',
    [112] = 'Club',
    [113] = 'Tango',
    [114] = 'Samba',
    [115] = 'Folklore',
    [116] = 'Ballad',
    [117] = 'Power Ballad',
    [118] = 'Rhythmic Soul',
    [119] = 'Freestyle',
    [120] = 'Duet',
    [121] = 'Punk Rock',
    [122] = 'Drum Solo',
    [123] = 'A Cappella', -- (was Acapella)
    [124] = 'Euro-House',
    [125] = 'Dance Hall',
    -- ref http://yar.hole.ru/MP3Tech/lamedoc/id3.html
    [126] = 'Goa',
    [127] = 'Drum & Bass',
    [128] = 'Club-House',
    [129] = 'Hardcore',
    [130] = 'Terror',
    [131] = 'Indie',
    [132] = 'BritPop',
    [133] = 'Afro-Punk', -- (was Negerpunk)
    [134] = 'Polsk Punk',
    [135] = 'Beat',
    [136] = 'Christian Gangsta Rap', -- (was Christian Gangsta)
    [137] = 'Heavy Metal',
    [138] = 'Black Metal',
    [139] = 'Crossover',
    [140] = 'Contemporary Christian', -- (was Contemporary C)
    [141] = 'Christian Rock',
    [142] = 'Merengue',
    [143] = 'Salsa',
    [144] = 'Thrash Metal',
    [145] = 'Anime',
    [146] = 'JPop',
    [147] = 'Synthpop', -- (was SynthPop)
    -- ref http://alicja.homelinux.com/~mats/text/Music/MP3/ID3/Genres.txt
    -- (also used to update some Genres above)
    [148] = 'Abstract',
    [149] = 'Art Rock',
    [150] = 'Baroque',
    [151] = 'Bhangra',
    [152] = 'Big Beat',
    [153] = 'Breakbeat',
    [154] = 'Chillout',
    [155] = 'Downtempo',
    [156] = 'Dub',
    [157] = 'EBM',
    [158] = 'Eclectic',
    [159] = 'Electro',
    [160] = 'Electroclash',
    [161] = 'Emo',
    [162] = 'Experimental',
    [163] = 'Garage',
    [164] = 'Global',
    [165] = 'IDM',
    [166] = 'Illbient',
    [167] = 'Industro-Goth',
    [168] = 'Jam Band',
    [169] = 'Krautrock',
    [170] = 'Leftfield',
    [171] = 'Lounge',
    [172] = 'Math Rock',
    [173] = 'New Romantic',
    [174] = 'Nu-Breakz',
    [175] = 'Post-Punk',
    [176] = 'Post-Rock',
    [177] = 'Psytrance',
    [178] = 'Shoegaze',
    [179] = 'Space Rock',
    [180] = 'Trop Rock',
    [181] = 'World Music',
    [182] = 'Neoclassical',
    [183] = 'Audiobook',
    [184] = 'Audio Theatre',
    [185] = 'Neue Deutsche Welle',
    [186] = 'Podcast',
    [187] = 'Indie Rock',
    [188] = 'G-Funk',
    [189] = 'Dubstep',
    [190] = 'Garage Rock',
    [191] = 'Psybient',
    [255] = 'None',
    -- ID3v2 adds some text short forms...
    CR = 'Cover',
    RX = 'Remix',
}

-- Tags for ID3v1
ID3.v1 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'ID3v1', [2] = 'Audio' },
    PRIORITY = 0, -- let ID3v2 tags replace these if they come later
    [3] = {
        Name = 'Title',
        Format = 'string[30]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [33] = {
        Name = 'Artist',
        Groups = { [2] = 'Author' },
        Format = 'string[30]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [63] = {
        Name = 'Album',
        Format = 'string[30]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [93] = {
        Name = 'Year',
        Groups = { [2] = 'Time' },
        Format = 'string[4]',
    },
    [97] = {
        Name = 'Comment',
        Format = 'string[30]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [125] = { -- ID3v1.1 (ref http://en.wikipedia.org/wiki/ID3#Layout)
        Name = 'Track',
        Format = 'int8u[2]',
        Notes = 'v1.1 addition -- last 2 bytes of v1.0 Comment field',
        RawConv = function(_self, val)
            -- (upstream `($val =~ s/^0 // and $val) ? $val : undef` -- an
            --  ID3v1.0 file has no track byte, so "0 0" (or "0 N") must be
            --  dropped; the surviving "0" after stripping "0 " is Perl-falsy
            --  so only a non-zero track number survives)
            local s = perlStr(val)
            if not s:match('^0 ') then return nil end
            s = s:sub(3)
            if s == '' or s == '0' then return nil end
            return s
        end,
    },
    [127] = {
        Name = 'Genre',
        Notes = 'CR and RX are ID3v2 only',
        Format = 'int8u',
        PrintConv = genre,
        PrintConvColumns = 3,
    },
}

-- ID3v1 "Enhanced TAG" information (ref 3)
ID3.v1_Enh = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [1] = 'ID3v1_Enh', [2] = 'Audio' },
    NOTES = 'ID3 version 1 "Enhanced TAG" information (not part of the official spec).',
    PRIORITY = 0,  -- let ID3v2 tags replace these if they come later
    [4] = {
        Name = 'Title2',
        Format = 'string[60]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [64] = {
        Name = 'Artist2',
        Groups = { [2] = 'Author' },
        Format = 'string[60]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [124] = {
        Name = 'Album2',
        Format = 'string[60]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [184] = {
        Name = 'Speed',
        Format = 'int8u',
        PrintConv = {
            [1] = 'Slow',
            [2] = 'Medium',
            [3] = 'Fast',
            [4] = 'Hardcore',
        },
    },
    [185] = {
        Name = 'Genre',
        Format = 'string[30]',
        ValueConv = function(self, val) return ID3.ConvertID3v1Text(self, val) end,
    },
    [215] = {
        Name = 'StartTime',
        Format = 'string[6]',
    },
    [221] = {
        Name = 'EndTime',
        Format = 'string[6]',
    },
}

-- ID3 version 2.2 tags.  (These are the tags written by iTunes 5.0.)
ID3.v2_2 = {
    PROCESS_PROC = function(...) return ID3.ProcessID3v2(...) end,
    GROUPS = { [1] = 'ID3v2_2', [2] = 'Audio' },
    NOTES = [[
        ExifTool extracts mainly text-based tags from ID3v2 information.  The tags
        in the tables below are those extracted by ExifTool, and don't represent a
        complete list of available ID3v2 tags.

        ID3 version 2.2 tags.  (These are the tags written by iTunes 5.0.)
    ]],
    CNT = 'PlayCounter',
    COM = 'Comment',
    IPL = 'InvolvedPeople',
    PIC = {
        Name = 'Picture',
        Groups = { [2] = 'Preview' },
        Binary = 1,
        Notes = 'the 3 tags below are also extracted from this PIC frame',
    },
    ['PIC-1'] = { Name = 'PictureFormat', Groups = { [2] = 'Image' } },
    ['PIC-2'] = {
        Name = 'PictureType',
        Groups = { [2] = 'Image' },
        PrintConv = pictureType,
        SeparateTable = 1,
    },
    ['PIC-3'] = { Name = 'PictureDescription', Groups = { [2] = 'Image' } },
    POP = {
        Name = 'Popularimeter',
        PrintConv = function(_self, val)
            local email, rating, cnt = perlStr(val):match('^(.*) (%d+) (%d+)$')
            if email then return email .. ' Rating=' .. rating .. ' Count=' .. cnt end
            return val
        end,
    },
    SLT = {
        Name = 'SynLyrics',
        SubDirectory = { TagTable = 'lexiftool.ID3.SynLyrics' },
    },
    TAL = 'Album',
    TBP = 'BeatsPerMinute',
    TCM = 'Composer',
    TCO = {
        Name = 'Genre',
        Notes = 'uses same lookup table as ID3v1 Genre',
        PrintConv = function(_self, val) return ID3.PrintGenre(val) end,
    },
    TCP = { Name = 'Compilation', PrintConv = { [0] = 'No', [1] = 'Yes' } }, -- iTunes
    TCR = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    TDA = { Name = 'Date', Groups = { [2] = 'Time' } },
    TDY = 'PlaylistDelay',
    TEN = 'EncodedBy',
    TFT = 'FileType',
    TIM = { Name = 'Time', Groups = { [2] = 'Time' } },
    TKE = 'InitialKey',
    TLA = 'Language',
    TLE = 'Length',
    TMT = 'Media',
    TOA = { Name = 'OriginalArtist', Groups = { [2] = 'Author' } },
    TOF = 'OriginalFileName',
    TOL = 'OriginalLyricist',
    TOR = 'OriginalReleaseYear',
    TOT = 'OriginalAlbum',
    TP1 = { Name = 'Artist', Groups = { [2] = 'Author' } },
    TP2 = 'Band',
    TP3 = 'Conductor',
    TP4 = 'InterpretedBy',
    TPA = 'PartOfSet',
    TPB = 'Publisher',
    TRC = 'ISRC', -- (international standard recording code)
    TRD = 'RecordingDates',
    TRK = 'Track',
    TSI = 'Size',
    TSS = 'EncoderSettings',
    TT1 = 'Grouping',
    TT2 = 'Title',
    TT3 = 'Subtitle',
    TXT = 'Lyricist',
    TXX = 'UserDefinedText',
    TYE = { Name = 'Year', Groups = { [2] = 'Time' } },
    ULT = 'Lyrics',
    WAF = 'FileURL',
    WAR = { Name = 'ArtistURL', Groups = { [2] = 'Author' } },
    WAS = 'SourceURL',
    WCM = 'CommercialURL',
    WCP = { Name = 'CopyrightURL', Groups = { [2] = 'Author' } },
    WPB = 'PublisherURL',
    WXX = 'UserDefinedURL',
    -- the following written by iTunes 10.5 (ref PH)
    RVA = 'RelativeVolumeAdjustment',
    TST = 'TitleSortOrder',
    TSA = 'AlbumSortOrder',
    TSP = 'PerformerSortOrder',
    TS2 = 'AlbumArtistSortOrder',
    TSC = 'ComposerSortOrder',
    ITU = { Name = 'iTunesU', Description = 'iTunes U', Binary = 1, Unknown = 1 },
    PCS = { Name = 'Podcast', Binary = 1, Unknown = 1 },
    GP1 = 'Grouping', --github142 (NC)
    MVN = 'MovementName', --github142 (NC)
    MVI = 'MovementNumber', --github142 (NC)
}

-- tags common to ID3v2.3 and ID3v2.4
local id3v2_common = {
  -- AENC => 'AudioEncryption', # Owner, preview start, preview length, encr data
    APIC = {
        Name = 'Picture',
        Groups = { [2] = 'Preview' },
        Binary = 1,
        Notes = 'the 3 tags below are also extracted from this APIC frame',
    },
    ['APIC-1'] = { Name = 'PictureMIMEType',    Groups = { [2] = 'Image' } },
    ['APIC-2'] = {
        Name = 'PictureType',
        Groups = { [2] = 'Image' },
        PrintConv = pictureType,
        SeparateTable = 1,
    },
    ['APIC-3'] = { Name = 'PictureDescription', Groups = { [2] = 'Image' } },
    COMM = 'Comment',
  -- COMR => 'Commercial',
  -- ENCR => 'EncryptionMethod',
  -- ETCO => 'EventTimingCodes',
    GEOB = {
        Name = 'GeneralEncapsulatedObject',
        SubDirectory = { TagTable = 'lexiftool.ID3.GEOB' },
    },
  -- GRID => 'GroupIdentification',
  -- LINK => 'LinkedInformation',
    MCDI = { Name = 'MusicCDIdentifier', Binary = 1 },
  -- MLLT => 'MPEGLocationLookupTable',
    OWNE = 'Ownership',
    PCNT = 'PlayCounter',
    POPM = {
        Name = 'Popularimeter',
        PrintConv = function(_self, val) val = perl.subst(val, [[(?s)^(.*?) (\d+) (\d+)$]], '$1 Rating=$2 Count=$3') return val end,
    },
  -- POSS => 'PostSynchronization',
    PRIV = {
        Name = 'Private',
        SubDirectory = { TagTable = 'lexiftool.ID3.Private' },
    },
  -- RBUF => 'RecommendedBufferSize',
  -- RVRB => 'Reverb',
    SYLT = {
        Name = 'SynLyrics',
        SubDirectory = { TagTable = 'lexiftool.ID3.SynLyrics' },
    },
  -- SYTC => 'SynchronizedTempoCodes',
    TALB = 'Album',
    TBPM = 'BeatsPerMinute',
    TCMP = { Name = 'Compilation', PrintConv = { [0] = 'No', [1] = 'Yes' } }, -- #PH (iTunes)
    TCOM = 'Composer',
    TCON ={
        Name = 'Genre',
        Notes = 'uses same lookup table as ID3v1 Genre',
        PrintConv = function(_self, val) return ID3.PrintGenre(val) end,
    },
    TCOP = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    TDLY = 'PlaylistDelay',
    TENC = 'EncodedBy',
    TEXT = 'Lyricist',
    TFLT = 'FileType',
    TIT1 = 'Grouping',
    TIT2 = 'Title',
    TIT3 = 'Subtitle',
    TKEY = 'InitialKey',
    TLAN = 'Language',
    TLEN = {
        Name = 'Length',
        ValueConv = function(_self, val) return perl.num(val) / 1000 end, -- (a text frame: Perl numifies)
        PrintConv = function(_self, val) return perlStr(val) .. ' s' end,
    },
    TMED = 'Media',
    TOAL = 'OriginalAlbum',
    TOFN = 'OriginalFileName',
    TOLY = 'OriginalLyricist',
    TOPE = { Name = 'OriginalArtist', Groups = { [2] = 'Author' } },
    TOWN = 'FileOwner',
    TPE1 = { Name = 'Artist', Groups = { [2] = 'Author' } },
    TPE2 = 'Band',
    TPE3 = 'Conductor',
    TPE4 = 'InterpretedBy',
    TPOS = 'PartOfSet',
    TPUB = 'Publisher',
    TRCK = 'Track',
    TRSN = 'InternetRadioStationName',
    TRSO = 'InternetRadioStationOwner',
    TSRC = 'ISRC', -- (international standard recording code)
    TSSE = 'EncoderSettings',
    TXXX = 'UserDefinedText',
  -- UFID => 'UniqueFileID', (not extracted because it is long and nasty and not very useful)
    USER = 'TermsOfUse',
    USLT = 'Lyrics',
    WCOM = 'CommercialURL',
    WCOP = 'CopyrightURL',
    WOAF = 'FileURL',
    WOAR = { Name = 'ArtistURL', Groups = { [2] = 'Author' } },
    WOAS = 'SourceURL',
    WORS = 'InternetRadioStationURL',
    WPAY = 'PaymentURL',
    WPUB = 'PublisherURL',
    WXXX = 'UserDefinedURL',
--
-- non-standard frames
--
    -- the following are written by iTunes 10.5 (ref PH)
    TSO2 = 'AlbumArtistSortOrder',
    TSOC = 'ComposerSortOrder',
    ITNU = { Name = 'iTunesU', Description = 'iTunes U', Binary = 1, Unknown = 1 },
    PCST = { Name = 'Podcast', Binary = 1, Unknown = 1 },
    -- other proprietary Apple tags (ref http://help.mp3tag.de/main_tags.html)
    TDES = 'PodcastDescription',
    TGID = 'PodcastID',
    WFED = 'PodcastURL',
    TKWD = 'PodcastKeywords',
    TCAT = 'PodcastCategory',
    -- more non-standard tags (ref http://eyed3.nicfit.net/compliance.html)
    -- NCON - unknown MusicMatch binary data
    XDOR = dateTimeConv { Name = 'OriginalReleaseTime',Groups = { [2] = 'Time' } },
    XSOA = 'AlbumSortOrder',
    XSOP = 'PerformerSortOrder',
    XSOT = 'TitleSortOrder',
    XOLY = {
        Name = 'OlympusDSS',
        SubDirectory = { TagTable = 'lexiftool.Olympus.DSS' },
    },
    GRP1 = 'Grouping',
    MVNM = 'MovementName', -- (NC)
    MVIN = 'MovementNumber', -- (NC)
}

ID3.GEOB = {
    GROUPS = { [1] = 'ID3v2_3', [2] = 'Other' },
    PROCESS_PROC = function(...) return ID3.ProcessGEOB(...) end,
    ['application/x-c2pa-manifest-store'] = {
        Name = 'JUMBF',
        SubDirectory = {
            TagTable = 'lexiftool.Jpeg2000.Main',
            ByteOrder = 'BigEndian',
        },
    },
    ['GEOB-Mime'] = { },
    ['GEOB-File'] = { },
    ['GEOB-Desc'] = { },
    ['GEOB-Data'] = { },
}

-- Tags for ID3v2.3 (http://www.id3.org/id3v2.3.0)
ID3.v2_3 = spread(id3v2_common) {
    PROCESS_PROC = function(...) return ID3.ProcessID3v2(...) end,
    GROUPS = { [1] = 'ID3v2_3', [2] = 'Audio' },
    NOTES = [[
        ID3 version 2.3 tags.  Includes some non-standard tags written by other
        software.
    ]],
    -- %id3v2_common,  -- include common tags (spread by the helper above)
  -- EQUA => 'Equalization',
    IPLS = 'InvolvedPeople',
  -- RVAD => 'RelativeVolumeAdjustment',
    TDAT = { Name = 'Date', Groups = { [2] = 'Time' } },
    TIME = { Name = 'Time', Groups = { [2] = 'Time' } },
    TORY = 'OriginalReleaseYear',
    TRDA = 'RecordingDates',
    TSIZ = 'Size',
    TYER = { Name = 'Year', Groups = { [2] = 'Time' } },
}

-- Tags for ID3v2.4 (http://www.id3.org/id3v2.4.0-frames)
ID3.v2_4 = spread(id3v2_common) {
    PROCESS_PROC = function(...) return ID3.ProcessID3v2(...) end,
    GROUPS = { [1] = 'ID3v2_4', [2] = 'Audio' },
    NOTES = [[
        ID3 version 2.4 tags.  Includes some non-standard tags written by other
        software.
    ]],
    -- %id3v2_common,  -- include common tags (spread by the helper above)
  -- EQU2 => 'Equalization',
    RVA2 = 'RelativeVolumeAdjustment',
  -- SEEK => 'Seek',
  -- SIGN => 'Signature',
    TDEN = dateTimeConv { Name = 'EncodingTime',       Groups = { [2] = 'Time' } },
    TDOR = dateTimeConv { Name = 'OriginalReleaseTime',Groups = { [2] = 'Time' } },
    TDRC = dateTimeConv { Name = 'RecordingTime',      Groups = { [2] = 'Time' } },
    TDRL = dateTimeConv { Name = 'ReleaseTime',        Groups = { [2] = 'Time' } },
    TDTG = dateTimeConv { Name = 'TaggingTime',        Groups = { [2] = 'Time' } },
    TIPL = 'InvolvedPeople',
    TMCL = 'MusicianCredits',
    TMOO = 'Mood',
    TPRO = 'ProducedNotice',
    TSOA = 'AlbumSortOrder',
    TSOP = 'PerformerSortOrder',
    TSOT = 'TitleSortOrder',
    TSST = 'SetSubtitle',
}

-- Synchronized lyrics/text
ID3.SynLyrics = {
    GROUPS = { [1] = 'ID3', [2] = 'Audio' },
    VARS = { ID_FMT = 'none' },
    PROCESS_PROC = function(...) return ID3.ProcessSynText(...) end,
    NOTES = 'The following tags are extracted from synchronized lyrics/text frames.',
    desc = { Name = 'SynchronizedLyricsDescription' },
    type = {
        Name = 'SynchronizedLyricsType',
        PrintConv = {
            [0] = 'Other',
            [1] = 'Lyrics',
            [2] = 'Text Transcription',
            [3] = 'Movement/part Name',
            [4] = 'Events',
            [5] = 'Chord',
            [6] = 'Trivia/"pop-up" Information',
            [7] = 'Web Page URL',
            [8] = 'Image URL',
        },
    },
    text = {
        Name = 'SynchronizedLyricsText',
        List = 1,
        Notes = [[
            each list item has a leading time stamp in square brackets.  Time stamps may
            be in seconds with format [MM:SS.ss], or MPEG frames with format [FFFF],
            depending on how this information was stored
        ]],
        PrintConv = function(_self, val) return ID3.ConvertTimeStamp(val) end,
    },
}

-- ID3 PRIV tags (ref PH)
ID3.Private = {
    PROCESS_PROC = function(...) return ID3.ProcessPrivate(...) end,
    GROUPS = { [1] = 'ID3', [2] = 'Audio' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        ID3 private (PRIV) tags.  ExifTool will decode any private tags found, even
        if they do not appear in this table.
    ]],
    XMP = {
        SubDirectory = {
            DirName = 'XMP',
            TagTable = 'lexiftool.XMP.Main',
        },
    },
    PeakValue = {
        ValueConv = function(_self, val) if perl.length(val) == 4 then return (perl.unpack('V', val)) end return { ref = 'SCALAR', value = val } end,
    },
    AverageLevel = {
        ValueConv = function(_self, val) if perl.length(val) == 4 then return (perl.unpack('V', val)) end return { ref = 'SCALAR', value = val } end,
    },
    -- Windows Media attributes ("/" in tag ID is converted to "_" by ProcessPrivate)
    WM_WMContentID = {
        Name = 'WM_ContentID',
        ValueConv = function(_self, val) return require('lexiftool.ASF').GetGUID(val) end,
    },
    WM_WMCollectionID = {
        Name = 'WM_CollectionID',
        ValueConv = function(_self, val) return require('lexiftool.ASF').GetGUID(val) end,
    },
    WM_WMCollectionGroupID = {
        Name = 'WM_CollectionGroupID',
        ValueConv = function(_self, val) return require('lexiftool.ASF').GetGUID(val) end,
    },
    WM_MediaClassPrimaryID = {
        ValueConv = function(_self, val) return require('lexiftool.ASF').GetGUID(val) end,
    },
    WM_MediaClassSecondaryID = {
        ValueConv = function(_self, val) return require('lexiftool.ASF').GetGUID(val) end,
    },
    WM_Provider = {
        ValueConv = function(self, val) return self:Decode(val, 'UTF16', 'II') end, -- #PH (NC)
    },
    -- there are lots more WM tags that could be decoded if I had samples or documentation - PH
    -- WM/AlbumArtist
    -- WM/AlbumTitle
    -- WM/Category
    -- WM/Composer
    -- WM/Conductor
    -- WM/ContentDistributor
    -- WM/ContentGroupDescription
    -- WM/EncodingTime
    -- WM/Genre
    -- WM/GenreID
    -- WM/InitialKey
    -- WM/Language
    -- WM/Lyrics
    -- WM/MCDI
    -- WM/MediaClassPrimaryID
    -- WM/MediaClassSecondaryID
    -- WM/Mood
    -- WM/ParentalRating
    -- WM/Period
    -- WM/ProtectionType
    -- WM/Provider
    -- WM/ProviderRating
    -- WM/ProviderStyle
    -- WM/Publisher
    -- WM/SubscriptionContentID
    -- WM/SubTitle
    -- WM/TrackNumber
    -- WM/UniqueFileIdentifier
    -- WM/WMCollectionGroupID
    -- WM/WMCollectionID
    -- WM/WMContentID
    -- WM/Writer
    -- WM/Year
}

-- lookup to check for existence of tags in other ID3 versions
local otherTable = {
    [ID3.v2_4] = 'lexiftool.ID3.v2_3',
    [ID3.v2_3] = 'lexiftool.ID3.v2_4',
}



-- ID3 Composite tags
ID3.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Image' },
    DateTimeOriginal = {
        TagID = 'ID3-DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Priority = 0,
        Desire = {
            [0] = 'ID3:RecordingTime',
            [1] = 'ID3:Year',
            [2] = 'ID3:Date',
            [3] = 'ID3:Time',
        },
        ValueConv = function(_self, val)
            if val[0] and val[0] ~= '' then return val[0] end
            if not (val[1] and val[1] ~= '') then return nil end
            local y1, y2
            if val[2] then y1, y2 = val[2]:match('^(%d%d)(%d%d)$') end
            if not y1 then return val[1] end
            local result = val[1] .. ':' .. y1 .. ':' .. y2
            local h1, h2
            if val[3] then h1, h2 = val[3]:match('^(%d%d)(%d%d)$') end
            if not h1 then return result end
            return result .. ' ' .. h1 .. ':' .. h2
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.ID3', nil, ID3)

--------------------------------------------------------------------------------
-- Make tag name for user-defined tag
-- Inputs: 0) User defined tag description
-- Returns: Tag name
--------------------------------------------------------------------------------
local function MakeTagName(name)
    if userTagName[name] then return userTagName[name] end
    if not name:match('[a-z]') then -- convert all uppercase to mixed case
        name = ucfirst(lc(name))
    end
    name = name:gsub('([a-z])[_ ]([a-z])', function(a, b) return a .. uc(b) end)
    return ExifTool.MakeTagName(name)
end

--------------------------------------------------------------------------------
-- Convert ID3v1 text to exiftool character set
-- Inputs: 0) ExifTool object ref, 1) text string
-- Returns: converted text
function ID3.ConvertID3v1Text(et, val)
    return et:Decode(val, et.OPTIONS.CharsetID3)
end

-- (forward declaration: DecodeString is defined further down, at its
--  upstream position, but ProcessSynText above it calls it)
local DecodeString

--------------------------------------------------------------------------------
-- Re-format time stamp in synchronized lyrics
-- Inputs: 0) synchronized lyrics entry (eg. "[84.030]Da do do do")
-- Returns: entry with formatted timestamp (eg. "[01:24.03]Da do do do")
function ID3.ConvertTimeStamp(val)
    -- do nothing if this isn't a time stamp (frame count doesn't contain a decimal)
    local time, pos = perl.matches(val, [==[^\[(\d+\.\d+)\]]==])
    if not time then return val end
    -- print hours only if more than 60 minutes
    local h = perl.int(time / 3600)
    if h ~= 0 then
        time = time - h * 3600
        h = h .. ':'
    else
        h = ''
    end
    local m = perl.int(time / 60)
    local s = time - m * 60
    local ss = sprintf('%05.2f', s)
    if perl.num(ss) >= 60 then
        ss = '00.00'
        m = m + 1
        if m >= 60 then
            m = m - 60
            h = perl.num(h) + 1
        end
    end
    return sprintf('[%s%.2d:%s]', h, m, ss) .. substr(val, pos)
end

--------------------------------------------------------------------------------
-- Process ID3 synchronized lyrics/text
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
function ID3.ProcessSynText(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt

    et:VerboseDir('SynLyrics', 0, perl.length(dataPt))
    if perl.length(dataPt) <= 6 then return end

    local enc, lang, timeCode, type_ = perl.unpack('Ca3CC', dataPt)
    lang = lc(lang)
    if not perl.matches(lang, [[^[a-z]{3}$]]) or lang == 'eng' then lang = nil end
    local p = 6 -- (upstream pos($$dataPt))
    local termLen, pat, ok
    if enc == 1 or enc == 2 then
        -- (upstream /\G(..)*?\0\0/sg -- the group is non-capturing here, the
        --  facade only reports the end offset, which is what is used)
        ok, p = perl.matches(dataPt, [[(?s)\G(?:..)*?\0\0]], p)
        if not ok then return end
        termLen = 2
        pat = [[(?s)\G(?:..)*?\0\0(....)]]
    else
        ok, p = perl.matches(dataPt, [[\0]], p)
        if not ok then return end
        termLen = 1
        pat = [[(?s)\0(....)]]
    end
    local desc = substr(dataPt, 6, p - 6 - termLen)
    desc = table.concat(DecodeString(et, desc, enc), '/')

    local tagInfo = et:GetTagInfo(tagTablePtr, 'desc')
    if lang then tagInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, lang) end
    et:HandleTag(tagTablePtr, 'type', type_)
    et:HandleTag(tagTablePtr, 'desc', desc, { TagInfo = tagInfo })
    tagInfo = et:GetTagInfo(tagTablePtr, 'text')
    if lang then tagInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, lang) end

    while true do
        local pos = p
        local tm
        tm, p = perl.matchesDyn(dataPt, pat, p)
        if not tm then break end
        local time = perl.unpack('N', tm)
        local text = substr(dataPt, pos, p - pos - 4 - termLen)
        text = table.concat(DecodeString(et, text, enc), '/')
        local timeStr
        if timeCode == 2 then -- time in ms
            timeStr = sprintf('%.3f', time / 1000)
        else                  -- time in MPEG frames
            timeStr = sprintf('%.4d', time)
            if timeCode ~= 1 then timeStr = timeStr .. '?' end
        end
        et:HandleTag(tagTablePtr, 'text', '[' .. timeStr .. ']' .. text, { TagInfo = tagInfo })
    end
end

--------------------------------------------------------------------------------
-- Process ID3 PRIV data
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
function ID3.ProcessPrivate(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local tag, start
    et:VerboseDir('PRIV', 0, perl.length(dataPt))
    local t = perl.matches(dataPt, [[(?s)^(.*?)\0]])
    if t then
        tag = t
        start = perl.length(tag) + 1
    else
        tag = ''
        start = 0
    end
    if not tagTablePtr[tag] then
        tag = perl.tr(tag, '/ ', '_', 'd') -- translate '/' to '_' and remove spaces
        if not perl.matches(tag, [[^[-\w]{1,24}$]]) then tag = 'private' end
        if not tagTablePtr[tag] then
            et:AddTagToTable(tagTablePtr, tag,
                { Name = (tag:gsub('^[a-z]', uc)), Binary = 1 })
        end
    end
    local key = et:HandleTag(tagTablePtr, tag, nil, {
        Size  = perl.length(dataPt) - start,
        Start = start,
        DataPt = dataPt,
    })
    -- set group1 name
    if key then et:SetGroup(key, et.ID3_Ver) end
end

--------------------------------------------------------------------------------
-- Print ID3v2 Genre
-- Inputs: TCON or TCO frame data
-- Returns: Content type with decoded genre numbers
--------------------------------------------------------------------------------
function ID3.PrintGenre(val)
    -- (Lua: %genre has numeric keys; a Perl hash key is the digit string, so
    --  a number with leading zeros is its own key)
    local function gkey(d) local n = tonumber(d) if perlStr(n) == d then return n end return d end
    -- make sure that %genre has an entry for all numbers we are interested in
    -- (genre numbers are in brackets for ID3v2.2 and v2.3)
    for d in eachMatch(val, [[\((\d+)\)]]) do
        if not genre[gkey(d)] then genre[gkey(d)] = "Unknown (" .. d .. ")" end
    end
    -- (genre numbers are separated by nulls in ID3v2.4,
    --  but nulls are converted to '/' by DecodeString())
    for d in eachMatch(val, [[(?:^|\/)(\d+)(\/|$)]]) do
        if not genre[gkey(d)] then genre[gkey(d)] = "Unknown (" .. d .. ")" end
    end
    val = subst(val, [[\((\d+)\)]], function(d) return "(" .. (genre[gkey(d)] or '') .. ")" end, 'g')
    val = subst(val, [[(^|\/)(\d+)(?=\/|$)]], function(c1, d) return (c1 or '') .. (genre[gkey(d)] or '') end, 'g')
    val = subst(val, [[^\(([^)]+)\)\1?$]], '$1') -- clean up by removing brackets and duplicates
    return val
end

--------------------------------------------------------------------------------
-- Get Genre ID
-- Inputs: 0) Genre name
-- Returns: genre ID number, or undef
function ID3.GetGenreID(name)
    return (require('lexiftool.Writer').ReverseLookup(name, genre))
end

--------------------------------------------------------------------------------
-- Decode ID3 string
-- Inputs: 0) ExifTool object reference
--         1) string beginning with encoding byte unless specified as argument
--         2) optional encoding (0=ISO-8859-1, 1=UTF-16 BOM, 2=UTF-16BE, 3=UTF-8)
-- Returns: list of decoded strings (Perl: list in list context, joined by
--          '/' in scalar context -- callers here join explicitly when a
--          scalar was wanted)
--------------------------------------------------------------------------------
function DecodeString(et, val, enc) -- (assigns the forward-declared local)
    if #val == 0 then return {} end
    if enc == nil then
        enc = ExifTool.Get8u(val, 0)
        val = substr(val, 1) -- remove encoding byte
    end
    local vals = {}
    if enc == 0 or enc == 3 then -- ISO 8859-1 or UTF-8
        val = val:gsub('\0+$', '') -- remove any null padding
        -- (must split before converting because conversion routines truncate at null)
        local start = 1
        while true do
            local i = val:find('\0', start, true)
            if not i then
                vals[#vals + 1] = val:sub(start)
                break
            end
            vals[#vals + 1] = val:sub(start, i - 1)
            start = i + 1
        end
        while #vals > 0 and vals[#vals] == '' do vals[#vals] = nil end
        for i, v in ipairs(vals) do
            vals[i] = et:Decode(v, enc ~= 0 and 'UTF8' or 'Latin')
        end
    elseif enc == 1 or enc == 2 then -- UTF-16 with BOM, or UTF-16BE
        local order = { ['\254\255'] = 'MM', ['\255\254'] = 'II' }
        local bom = '\254\255'
        while true do
            local v
            -- split string at null terminators on word boundaries
            local pos = 1
            local found
            while pos + 1 <= #val do
                if val:byte(pos) == 0 and val:byte(pos + 1) == 0 then found = pos break end
                pos = pos + 2
            end
            if found then
                v = val:sub(1, found - 1)
                val = val:sub(found + 2)
            else
                if #val <= 1 then break end
                v = val
                val = ''
            end
            local b = v:sub(1, 2)
            if order[b] then bom = b v = v:sub(3) end
            vals[#vals + 1] = et:Decode(v, 'UTF16', order[bom])
        end
    else
        val = val:gsub('\0+$', '')
        return { '<Unknown encoding ' .. enc .. '> ' .. val }
    end
    return vals
end

--------------------------------------------------------------------------------
-- Convert sync-safe integer to a number we can use
-- Inputs: 0) int32u sync-safe value
-- Returns: actual number or nil on invalid value
--------------------------------------------------------------------------------
function ID3.UnSyncSafe(val)
    if val & 0x80808080 ~= 0 then return nil end
    return (val & 0x0000007f) |
          ((val & 0x00007f00) >> 1) |
          ((val & 0x007f0000) >> 2) |
          ((val & 0x7f000000) >> 3)
end

--------------------------------------------------------------------------------
-- Process ID3v2 information
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
--------------------------------------------------------------------------------
function ID3.ProcessID3v2(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local offset = dirInfo.DirStart
    local size = dirInfo.DirLen
    local vers = dirInfo.Version
    local verbose = et:Options('Verbose')
    local otherTbl -- (upstream $otherTable: the other ID3v2 version's table)

    et:VerboseDir(tagTablePtr.GROUPS[1], 0, size)
    et:VerboseDump(dataPt, { Len = size, Start = offset })

    while true do
        local id, len, flags
        if vers < 0x0300 then
            -- version 2.2 frame header is 6 bytes
            if offset + 6 > size then break end
            local hi
            id, hi, len = perl.unpack('a3Cn', dataPt, offset)
            if id == '\0\0\0' then break end
            len = len + (hi << 16)
            offset = offset + 6
        else
            -- version 2.3/2.4 frame header is 10 bytes
            if offset + 10 > size then break end
            id, len, flags = perl.unpack('a4Nn', dataPt, offset)
            if id == '\0\0\0\0' then break end
            offset = offset + 10
            -- length is a "sync-safe" integer by the ID3v2.4 specification, but
            -- reportedly some versions of iTunes write this as a normal integer
            -- (ref http://www.id3.org/iTunes)
            -- luacheck: ignore 512 (upstream: "while" was really a "goto" in disguise)
            while vers >= 0x0400 and len > 0x7f and (len & 0x80808080) == 0 do
                local oldLen = len
                len = ID3.UnSyncSafe(len)
                local lenOrZero = len or 0
                if len == nil or offset + lenOrZero + 10 > size then
                    if offset + lenOrZero == size then
                        et:Warn('Missing ID3 terminating frame', 1)
                    else
                        et:Warn('Invalid ID3 frame size')
                    end
                    len = lenOrZero
                    break
                end
                -- check next ID to see if it makes sense
                local nextID = substr(dataPt, offset + len, 4)
                if tagTablePtr[nextID] then break end
                -- try again with the incorrect length word (patch for iTunes bug)
                if offset + oldLen + 10 > size then break end
                nextID = substr(dataPt, offset + len, 4)
                if tagTablePtr[nextID] then len = oldLen end
                break -- yes, "while" was really a "goto" in disguise
            end
        end
        if offset + len > size then break end

        repeat -- (upstream per-frame 'next' == Lua 'break' out of this block)
            local tagInfo = et:GetTagInfo(tagTablePtr, id)
            if not tagInfo then
                if not otherTbl and otherTable[tagTablePtr] then
                    otherTbl = et:GetTagTable(otherTable[tagTablePtr])
                end
                if otherTbl then tagInfo = et:GetTagInfo(otherTbl, id) end
                if tagInfo then
                    et:Warn("Frame '" .. id .. "' is not valid for this ID3 version", 1)
                else
                    if not (truthy(verbose) or truthy(et:Options('Unknown'))) then break end
                    local cleanID = id:gsub('[^A-Za-z0-9_%-]', '')
                    if cleanID == '' then cleanID = 'unknown' end
                    if not tagTablePtr[cleanID] then
                        tagInfo = { Name = 'ID3_' .. cleanID, Binary = 1 }
                        et:AddTagToTable(tagTablePtr, cleanID, tagInfo)
                    end
                end
            end
            -- decode v2.3 and v2.4 flags
            local frameFlags = {}
            if flags and flags ~= 0 then
                if vers < 0x0400 then
                    -- version 2.3 flags
                    if flags & 0x80 ~= 0 then frameFlags.Compress = 1 end
                    if flags & 0x40 ~= 0 then frameFlags.Encrypt = 1 end
                    if flags & 0x20 ~= 0 then frameFlags.GroupID = 1 end
                else
                    -- version 2.4 flags
                    if flags & 0x40 ~= 0 then frameFlags.GroupID = 1 end
                    if flags & 0x08 ~= 0 then frameFlags.Compress = 1 end
                    if flags & 0x04 ~= 0 then frameFlags.Encrypt = 1 end
                    if flags & 0x02 ~= 0 then frameFlags.Unsync = 1 end
                    if flags & 0x01 ~= 0 then frameFlags.DataLen = 1 end
                end
            end
            if frameFlags.Encrypt then
                et:Warn('Encrypted frames currently not supported')
                break
            end
            -- extract the value
            local val = substr(dataPt, offset, len)

            -- reverse the unsynchronization
            if frameFlags.Unsync then val = val:gsub('\255\0', '\255') end

            -- read grouping identity
            if frameFlags.GroupID then
                if #val < 1 then et:Warn('Short ' .. id .. ' frame') break end
                val = substr(val, 1) -- (ignore it)
            end
            -- read data length
            local dataLen
            if frameFlags.DataLen or frameFlags.Compress then
                if #val < 4 then et:Warn('Short ' .. id .. ' frame') break end
                dataLen = perl.unpack('N', val) -- save the data length word
                val = substr(val, 4)
            end
            -- uncompress data
            if frameFlags.Compress then
                if ExifTool.hasZlib() then   -- (`eval { require Compress::Zlib }`)
                    local buff, stat = et:inflate(val)
                    if stat then   -- (`$stat == Compress::Zlib::Z_STREAM_END()`)
                        val = buff
                    else
                        et:Warn('Error inflating ' .. id .. ' frame')
                        break
                    end
                else
                    et:Warn('Install Compress::Zlib to decode compressed frames')
                    break
                end
            end
            -- validate data length
            if dataLen ~= nil then
                dataLen = ID3.UnSyncSafe(dataLen)
                if dataLen == nil then et:Warn('Invalid length for ' .. id .. ' frame') break end
                if dataLen ~= #val then et:Warn('Wrong length for ' .. id .. ' frame') break end
            end
            if not tagInfo then
                if not truthy(verbose) then break end
                local extra
                if next(frameFlags) then
                    local names = {}
                    for k in pairs(frameFlags) do names[#names + 1] = k end
                    tsort(names)
                    extra = ', Flags=' .. table.concat(names, ',')
                end
                et:VerboseInfo(id, tagInfo, {
                    Table = tagTablePtr,
                    Value = val,
                    DataPt = dataPt,
                    DataPos = dirInfo.DataPos,
                    Size = len,
                    Start = offset,
                    Extra = extra,
                })
                break
            end
--
-- decode data in this frame (it is bad form to hard-code these, but the ID3 frame formats
-- are so variable that it would be more work to define format types for each of them)
--
            local lang
            local valLen = #val
            if id == 'TXX' or id == 'TXXX' then
                -- two encoded strings separated by a null
                local vals = DecodeString(et, val)
                vals[1] = vals[1] or ''
                vals[2] = vals[2] or ''
                if #vals[1] > 0 then
                    id = id .. '_' .. vals[1]
                    tagInfo = tagTablePtr[id] or et:AddTagToTable(tagTablePtr, id, MakeTagName(vals[1]))
                end
                val = vals[2]
            -- upstream: `$id =~ /^T/ or $id =~ /^(IPL|IPLS|GP1|MVI|MVN)$/`
            -- (second check via PCRE2 -- Lua patterns have no alternation)
            elseif id:match('^T') or perl.matches(id, '^(IPL|IPLS|GP1|MVI|MVN)$') then
                val = table.concat(DecodeString(et, val), '/')
            elseif id == 'WXX' or id == 'WXXX' then
                -- one encoded string and one Latin string separated by a null
                local enc = ExifTool.Get8u(val, 0)
                local tag, url
                if enc == 1 or enc == 2 then
                    local pos = 2
                    local found
                    while pos + 1 <= #val do
                        if val:byte(pos) == 0 and val:byte(pos + 1) == 0 then found = pos break end
                        pos = pos + 2
                    end
                    if found then
                        tag = val:sub(1, found - 1)
                        url = val:sub(found + 2)
                    end
                else
                    local z = val:find('\0', 2, true)
                    if z then
                        tag = val:sub(1, z - 1)
                        url = val:sub(z + 1)
                    end
                end
                if not (tag and url) then et:Warn('Invalid ' .. id .. ' frame') break end
                tag = table.concat(DecodeString(et, tag), '/')
                if #tag > 0 then
                    id = id .. '_' .. tag
                    local nameSrc = tag
                    if not lc(tag):find('url', 1, true) then nameSrc = tag .. '_URL' end
                    tagInfo = tagTablePtr[id] or et:AddTagToTable(tagTablePtr, id, MakeTagName(nameSrc))
                end
                url = url:gsub('\0.*', '')
                val = et:Decode(url, 'Latin')
            elseif id:match('^W') then
                val = val:gsub('\0.*', '') -- truncate at null
            elseif id == 'COM' or id == 'COMM' or id == 'ULT' or id == 'USLT' then
                if valLen <= 4 then et:Warn('Short ' .. id .. ' frame') break end
                lang = substr(val, 1, 3)
                local vals = DecodeString(et, substr(val, 4), ExifTool.Get8u(val, 0))
                vals[1] = vals[1] or ''
                vals[2] = vals[2] or ''
                val = #vals[1] > 0 and ('(' .. vals[1] .. ') ' .. vals[2]) or vals[2]
            elseif id == 'USER' then
                if valLen <= 4 then et:Warn('Short ' .. id .. ' frame') break end
                lang = substr(val, 1, 3)
                val = table.concat(DecodeString(et, substr(val, 4), ExifTool.Get8u(val, 0)), '/')
            elseif id == 'CNT' or id == 'PCNT' then
                if valLen < 4 then et:Warn('Short ' .. id .. ' frame') break end
                local nums = { perl.unpack('NC*', val) }
                local cnt = nums[1]
                for i = 2, #nums do cnt = (cnt << 8) + nums[i] end
                val = cnt
            elseif id == 'PIC' or id == 'APIC' then
                if valLen < 4 then et:Warn('Short ' .. id .. ' frame') break end
                local enc = ExifTool.Get8u(val, 0)
                local fmt, pos
                if id == 'PIC' then
                    fmt = val:sub(2, 4) -- 3-char image format
                    pos = 5
                else
                    local z = val:find('\0', 2, true)
                    if not z then et:Warn('Invalid ' .. id .. ' frame') break end
                    fmt = val:sub(2, z - 1) -- MIME type
                    pos = z + 1
                end
                if pos > valLen then et:Warn('Invalid ' .. id .. ' frame') break end
                local picType = ExifTool.Get8u(val, pos - 1)
                pos = pos + 1
                -- description, null-terminated (double-null / word-aligned for UTF-16)
                local descEnd
                if enc == 1 or enc == 2 then
                    local p = pos
                    while p + 1 <= valLen do
                        if val:byte(p) == 0 and val:byte(p + 1) == 0 then descEnd = p break end
                        p = p + 2
                    end
                else
                    descEnd = val:find('\0', pos, true)
                end
                if not descEnd then et:Warn('Invalid ' .. id .. ' frame') break end
                local descTermLen = (enc == 1 or enc == 2) and 2 or 1
                local desc = table.concat(DecodeString(et, val:sub(pos, descEnd - 1), enc), '/')
                local attrs = { fmt, picType, desc }
                for i, attr in ipairs(attrs) do
                    et:HandleTag(tagTablePtr, id .. '-' .. i, attr)
                end
                val = val:sub(descEnd + descTermLen)
            elseif id == 'POP' or id == 'POPM' then
                -- _email, 00, rating(1), counter(4-N)
                local email, dat = val:match('^([^\0]*)\0(.*)$')
                if not (dat and #dat > 0) then et:Warn('Invalid ' .. id .. ' frame') break end
                local nums = { perl.unpack('C*', dat) }
                local rating = nums[1]
                local cnt = 0
                for i = 2, #nums do cnt = (cnt << 8) + nums[i] end
                val = email .. ' ' .. rating .. ' ' .. cnt
            elseif id == 'OWNE' then
                -- enc(1), _price, 00, _date(8), Seller
                local strs = DecodeString(et, val)
                if strs[2] then
                    strs[2] = strs[2]:gsub('^(%d%d%d%d)(%d%d)(%d%d)', '%1:%2:%3 ')
                end
                val = table.concat(strs, ' ')
            elseif id == 'RVA' or id == 'RVAD' then
                local dat = { perl.unpack('C*', val) }
                local flag = table.remove(dat, 1)
                local bits = table.remove(dat, 1)
                if not bits then et:Warn('Short ' .. id .. ' frame') break end
                local bytes = (bits + 7) // 8
                local parse = {
                    { 'Right', 0, 2, 0x01 }, { 'Left', 1, 3, 0x02 },
                    { 'Back-right', 4, 6, 0x04 }, { 'Back-left', 5, 7, 0x08 },
                    { 'Center', 8, 9, 0x10 }, { 'Bass', 10, 11, 0x20 },
                }
                local parts = {}
                for _, elem in ipairs(parse) do
                    local j = elem[3] * bytes
                    if #dat < j + bytes then break end
                    local i = elem[2] * bytes
                    local rel, pk = 0, 0
                    for b = 0, bytes - 1 do
                        rel = rel * 256 + dat[i + b + 1]
                        pk = pk * 256 + dat[j + b + 1] -- (peak - not used in printout)
                    end
                    if flag & elem[4] == 0 then rel = -rel end
                    parts[#parts + 1] = sprintf('%+.1f%% %s', 100 * rel / ((1 << bits) - 1), elem[1])
                end
                val = table.concat(parts, ', ')
            elseif id == 'RVA2' then
                local rvaId, pos
                local zi = val:find('\0', 1, true)
                if zi then
                    rvaId = val:sub(1, zi - 1)
                    pos = zi
                else
                    rvaId = ''
                    pos = 0
                end
                local channelName = {
                    [0] = 'Other', [1] = 'Master', [2] = 'Front-right', [3] = 'Front-left',
                    [4] = 'Back-right', [5] = 'Back-left', [6] = 'Front-centre',
                    [7] = 'Back-centre', [8] = 'Subwoofer',
                }
                local parts = {}
                while pos + 4 <= valLen do
                    local typ = ExifTool.Get8u(val, pos)
                    local str = channelName[typ] or ('Unknown(' .. typ .. ')')
                    local db = ExifTool.Get16s(val, pos + 1) / 512
                    -- convert dB to percent as displayed by iTunes 10.5
                    -- (not sure why I need to divide by 20 instead of 10 as expected - PH)
                    parts[#parts + 1] = sprintf('%+.1f%% %s', 10 ^ (db / 20 + 2) - 100, str)
                    -- step to next channel (ignoring peak volume)
                    pos = pos + 4 + ((ExifTool.Get8u(val, pos + 3) + 7) // 8)
                end
                val = table.concat(parts, ', ')
                if rvaId ~= '' then val = val .. ' (' .. rvaId .. ')' end
            elseif id == 'PRIV' then
                -- save version number to set group1 name for tag later
                et.ID3_Ver = tagTablePtr.GROUPS[1]
                et:HandleTag(tagTablePtr, id, val)
                break
            elseif tagInfo.Format or tagInfo.SubDirectory then
                et:HandleTag(tagTablePtr, id, nil, { DataPt = val })
                break
            elseif id == 'GRP1' or id == 'MVNM' or id == 'MVIN' then
                val = val:gsub('^\0+', ''):gsub('\0+$', '') -- (PH guess)
            elseif not tagInfo.Binary then
                et:Warn("Don't know how to handle " .. id .. ' frame')
                break
            end
            if lang and perl.matches(lang, [[(?i)^[a-z]{3}$]]) and lang ~= 'eng' then
                tagInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, lc(lang))
            end
            et:HandleTag(tagTablePtr, id, val, {
                TagInfo = tagInfo,
                DataPt = dataPt,
                DataPos = dirInfo.DataPos,
                Size = len,
                Start = offset,
            })
        until true

        offset = offset + len
    end
end

--------------------------------------------------------------------------------
-- Extract ID3 information from an audio file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this file didn't contain ID3 information
-- - also processes audio data if any ID3 information was found
-- - sets ExifTool DoneID3 to 1 when called, or to trailer size if an ID3v1 trailer exists
function ID3.ProcessID3(et, dirInfo)
    if truthy(et.DoneID3) then return 0 end   -- avoid infinite recursion
    et.DoneID3 = 1

    -- allow this to be called with either RAF or DataPt
    local raf = dirInfo.RAF or RandomAccess.new(dirInfo.DataPt)
    local dataPos = dirInfo.DataPos or 0
    local buff, id3Header, id3Trailer, hBuff, tBuff, eBuff, tagTablePtr, n
    local rtnVal = 0
    local hdrEnd = 0
    local id3Len = 0

    -- read first 3 bytes of file
    raf:Seek(0, 0)
    n, buff = raf:Read(3)
    if n ~= 3 then return 0 end
--
-- identify ID3v2 header
--
    while isMatch(buff, '^ID3') do -- luacheck: ignore 512
        rtnVal = 1
        n, hBuff = raf:Read(7)
        if n ~= 7 then et:Warn('Short ID3 header') break end
        local vers, flags, size = perl.unpack('nCN', hBuff)
        size = ID3.UnSyncSafe(size)
        if size == nil then et:Warn('Invalid ID3 header') break end
        local verStr = sprintf("2.%d.%d", vers >> 8, vers & 0xff)
        if vers >= 0x0500 then
            et:Warn("Unsupported ID3 version: " .. verStr)
            break
        end
        n, hBuff = raf:Read(size)
        if n ~= size then
            et:Warn('Truncated ID3 data')
            break
        end
        -- this flag only indicates use of unsynchronized frames in ID3v2.4
        if flags & 0x80 ~= 0 and vers < 0x0400 then
            -- reverse the unsynchronization
            hBuff = subst(hBuff, [[\xff\x00]], "\xff", 'g')
        end
        local pos = 10
        if flags & 0x40 ~= 0 then
            -- skip the extended header
            if size < 4 then et:Warn('Bad ID3 extended header') break end
            local len = ID3.UnSyncSafe((perl.unpack('N', hBuff)))
            if len > #hBuff then
                et:Warn('Truncated ID3 extended header')
                break
            end
            hBuff = substr(hBuff, len)
            pos = pos + len
        end
        if flags & 0x10 ~= 0 then
            -- ignore v2.4 footer (10 bytes long)
            raf:Seek(10, 1)
        end
        id3Header = {
            DataPt   = hBuff,
            DataPos  = dataPos + pos,
            DirStart = 0,
            DirLen   = #hBuff,
            Version  = vers,
            DirName  = "ID3v" .. verStr,
        }
        id3Len = id3Len + #hBuff + 10
        if vers >= 0x0400 then
            tagTablePtr = GetTagTable(nil, 'lexiftool.ID3.v2_4')
        elseif vers >= 0x0300 then
            tagTablePtr = GetTagTable(nil, 'lexiftool.ID3.v2_3')
        else
            tagTablePtr = GetTagTable(nil, 'lexiftool.ID3.v2_2')
        end
        hdrEnd = raf:Tell()
        break
    end
--
-- read ID3v1 trailer if it exists
--
    local trailSize = 0
    if raf:Seek(-128, 2) then
        n, tBuff = raf:Read(128)
    end
    if n == 128 and isMatch(tBuff, '^TAG') then
        trailSize = 128
        id3Trailer = {
            DataPt   = tBuff,
            DataPos  = dataPos + raf:Tell() - 128,
            DirStart = 0,
            DirLen   = #tBuff,
        }
        id3Len = id3Len + #tBuff
        rtnVal = 1
        -- load 'Enhanced TAG' information if available
        local eSize = 227   -- size of ID3 Enhanced TAG info
        if raf:Seek(-trailSize - eSize, 2) then
            n, eBuff = raf:Read(eSize)
            if n == eSize and isMatch(eBuff, '^TAG+') then
                id3Trailer.EnhancedTAG = eBuff
                trailSize = trailSize + eSize
            end
        end
        et.DoneID3 = trailSize  -- save trailer size
    end
--
-- read Lyrics3 trailer if it exists
--
    n = 0
    if raf:Seek(-trailSize - 15, 2) then n, buff = raf:Read(15) end
    local isLyr, l1, ver = false, nil, nil
    if n == 15 then isLyr, l1, ver = isMatch(buff, [[^(.{6})LYRICS(END|200)$]]) end
    if isLyr then
        -- (ver: Lyrics3 version ('END' for version 1))
        local len = (ver == 'END') and 5100 or perl.num(l1) + 15 -- max Lyrics3 length
        local tbl = GetTagTable(nil, 'lexiftool.ID3.Lyrics3')
        if len > raf:Tell() then len = raf:Tell() end
        local ok, e = false, nil
        if raf:Seek(-len, 1) then
            n, buff = raf:Read(len)
            if n == len then
                local m
                m, e = matches(buff, 'LYRICSBEGIN')
                ok = m ~= nil
            end
        end
        if ok then
            local pos = e
            et.DoneID3 = trailSize + len - pos + 11 -- update trailer length
            local oldIndent = et.INDENT
            et.INDENT = et.INDENT .. '| '
            if truthy(et:Options('Verbose')) then
                et:VPrint(0, "Lyrics3:\n")
                et:VerboseDir('Lyrics3', nil, len)
                if pos > 11 then
                    buff = substr(buff, pos - 11)
                    pos = 11
                end
                et:VerboseDump(buff)
            end
            if ver == 'END' then
                -- Lyrics3 v1.00
                local val = substr(buff, pos, len - pos - 9)
                et:HandleTag(tbl, 'LYR', et:Decode(val, 'Latin'))
            else
                -- Lyrics3 v2.00
                local gpos = pos    -- (pos($buff))
                while true do
                    -- (note: the size field is 5 digits,, not 6 as per the documentation)
                    local tag, size, e2 = matches(buff, [[\G(.{3})(\d{5})]], gpos)
                    if tag == nil then break end
                    gpos = e2 -- luacheck: ignore 311
                    size = perl.num(size)
                    pos = pos + 8
                    if pos + size > #buff then break end
                    if not tbl[tag] then
                        ExifTool.AddTagToTable(nil, tbl, tag, { Name = ExifTool.MakeTagName("Lyrics3_" .. tag) })
                    end
                    et:HandleTag(tbl, tag, et:Decode(substr(buff, pos, size), 'Latin'))
                    pos = pos + size
                    gpos = pos
                end
                if pos ~= #buff - 15 then et:Warn('Malformed Lyrics3 v2.00 block') end
            end
            et.INDENT = oldIndent
        else
            et:Warn('Error reading Lyrics3 trailer')
        end
    end
--
-- process the information
--
    if rtnVal ~= 0 then
        -- first process audio data if it exists
        if dirInfo.RAF then
            local oldType = et.FILE_TYPE    -- save file type
            -- check current file type first
            local types = {}
            for _, t in ipairs(audioFormats) do if t == oldType then types[#types + 1] = t end end
            for _, t in ipairs(audioFormats) do if t ~= oldType then types[#types + 1] = t end end
            for _, type_ in ipairs(types) do
                -- seek to end of ID3 header
                raf:Seek(hdrEnd, 0)
                -- set type for this file if we are successful
                et.FILE_TYPE = type_
                local module = audioModule[type_] or type_
                local mod = require('lexiftool.' .. module)
                local func = mod['Process' .. type_]
                -- process the file
                if truthy(func(et, dirInfo)) then break end
            end
            et.FILE_TYPE = oldType      -- restore original file type
        end
        -- set file type to MP3 if we didn't find audio data
        et:SetFileType('MP3')
        -- record the size of the ID3 metadata
        et:FoundTag('ID3Size', id3Len)
        -- process ID3v2 header if it exists
        if id3Header then
            et:VPrint(0, id3Header.DirName .. ":\n")
            et:ProcessDirectory(id3Header, tagTablePtr)
        end
        -- process ID3v1 trailer if it exists
        if id3Trailer then
            et:VPrint(0, "ID3v1:\n")
            ExifTool.SetByteOrder('MM')
            tagTablePtr = GetTagTable(nil, 'lexiftool.ID3.v1')
            et:ProcessDirectory(id3Trailer, tagTablePtr)
            -- process "Enhanced TAG" information if available
            if id3Trailer.EnhancedTAG then
                et:VPrint(0, "ID3v1 Enhanced TAG:\n")
                tagTablePtr = GetTagTable(nil, 'lexiftool.ID3.v1_Enh')
                id3Trailer.DataPt = id3Trailer.EnhancedTAG
                id3Trailer.DataPos = id3Trailer.DataPos - 227 -- (227 = length of Enhanced TAG block)
                id3Trailer.DirLen = 227
                et:ProcessDirectory(id3Trailer, tagTablePtr)
            end
        end
    end
    -- return file pointer to start of file to read audio data if necessary
    raf:Seek(0, 0)
    return rtnVal
end

--------------------------------------------------------------------------------
-- Process ID3 directory
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) dummy tag table ref
--------------------------------------------------------------------------------
function ID3.ProcessID3Dir(et, dirInfo, _tagTablePtr)
    et:VerboseDir('ID3', nil, #dirInfo.DataPt)
    return ID3.ProcessID3(et, dirInfo)
end

--------------------------------------------------------------------------------
-- Process ID3 General Encapsulated Object
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function ID3.ProcessGEOB(et, dirInfo, tagTablePtr)
    et:VerboseDir('GEOB', nil, perl.length(dirInfo.DataPt))
    local dataPt = dirInfo.DataPt
    local len = perl.length(dataPt)
    if len < 4 then et:Warn('Short GEOB frame') return 0 end
    local hdr
    local enc = perl.unpack('C', dataPt)
    if enc == 1 or enc == 2 then
        hdr = [[.(.*?)\0((?:..)*?)\0\0((?:..)*?)\0\0]]
    else
        hdr = [[.(.*?)\0(.*?)\0(.*?)\0]]
    end
    -- remove header (encoding, mime, filename, description)
    local mime, file, desc, e = perl.matchesDyn(dataPt, '(?s)^' .. hdr)
    if not mime then et:Warn('Invalid GEOB frame') return 0 end
    dataPt = substr(dataPt, e)
    file = table.concat(DecodeString(et, file, enc), '/')
    desc = table.concat(DecodeString(et, desc, enc), '/')
    if perl.length(mime) > 0 then et:HandleTag(tagTablePtr, 'GEOB-Mime', mime) end
    if perl.length(file) > 0 then et:HandleTag(tagTablePtr, 'GEOB-File', file) end
    if perl.length(desc) > 0 then et:HandleTag(tagTablePtr, 'GEOB-Desc', desc) end
    if tagTablePtr[mime] then
        et:HandleTag(tagTablePtr, mime, nil, {
            DataPt = dataPt,
            Start  = 0,
            Size   = perl.length(dataPt),
        })
    else
        et:HandleTag(tagTablePtr, 'GEOB-Data', { ref = 'SCALAR', value = dataPt })
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract ID3 information from an MP3 audio file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid MP3 file
function ID3.ProcessMP3(et, dirInfo)
    local rtnVal = 0

    -- must first check for leading/trailing ID3 information
    -- (and process the rest of the file if found)
    if not truthy(et.DoneID3) then
        rtnVal = ID3.ProcessID3(et, dirInfo)
    end

    -- check for MPEG A/V data if not already processed above
    if not truthy(rtnVal) then
        local raf = dirInfo.RAF
        local buff, n
--
-- extract information from first audio/video frame headers
-- (if found in the first $scanLen bytes)
--
        -- scan further into a file that should be an MP3
        local scanLen = (et.FILE_EXT and et.FILE_EXT == 'MP3') and 8192 or 256
        n, buff = raf:Read(scanLen)
        if truthy(n) then
            local MPEG = require('lexiftool.MPEG')
            if isMatch(buff, [[\0\0\x01(\xb3|\xc0)]]) then
                -- look for A/V headers in first 64kB
                local n2, buf2 = raf:Read(0x10000 - scanLen)
                if truthy(n2) then buff = buff .. buf2 end
                if truthy(MPEG.ParseMPEGAudioVideo(et, buff)) then rtnVal = 1 end
            else
                -- look for audio frame sync in first $scanLen bytes
                -- (set MP3 flag to 1 so this will fail unless layer 3 audio)
                local ext = et.FILE_EXT or ''
                local mp3 = (ext == 'MUS') and 0 or 1   -- MUS files are MP2
                if truthy(MPEG.ParseMPEGAudio(et, buff, mp3)) then rtnVal = 1 end
            end
        end
    end

    -- check for an APE trailer if this was a valid A/V file and we haven't already done it
    if truthy(rtnVal) and not truthy(et.DoneAPE) then
        require('lexiftool.APE').ProcessAPE(et, dirInfo)
    end
    return rtnVal
end

return ID3
