--------------------------------------------------------------------------------
-- File:         lexiftool/Font.lua
-- Ported from:  lib/Image/ExifTool/Font.pm
--
-- Description:  Read meta information from font files
--
-- Revisions:    2010/01/15 - P. Harvey Created
--
-- References:   1) http://developer.apple.com/textfonts/TTRefMan/RM06/Chap6.html
--               2) http://www.microsoft.com/typography/otspec/otff.htm
--               3) http://partners.adobe.com/public/developer/opentype/index_font_file.html
--               4) http://partners.adobe.com/public/developer/en/font/5178.PFM.pdf
--               5) http://opensource.adobe.com/svn/opensource/flex/sdk/trunk/modules/compiler/src/java/flex2/compiler/util/MimeMappings.java
--               6) http://www.adobe.com/devnet/font/pdfs/5004.AFM_Spec.pdf
--               7) https://www.w3.org/TR/WOFF/
--               8) https://www.w3.org/TR/WOFF2/
--
-- Port notes:   Complete port of Font.pm: every table, lookup and sub, in
--               upstream order (Font.pm is read-only).  Deviations forced by
--               Lua:
--               - The predeclaration `sub ProcessOTF($$);` is a local at the
--                 top; the sub below assigns to it.  %ttLang is exported as
--                 Font.ttLang (QuickTime.lua reads it, as upstream).
--               - @knownTags is a Lua list read 0-based through perl.at.
--               - Uncompress/Unbrotli return the uncompressed data as a
--                 second value instead of replacing $$dataPt; zlib comes from
--                 the optional `zlib` module (ExifTool:inflate), Brotli from
--                 IO::Uncompress::Brotli, i.e. the optional rock lbrotli
--                 (perl.evalRequire) -- without it WOFF2
--                 warns as upstream does without the Perl module.
--               - ProcessAFM reads with PostScript.GetInputRecordSeparator's
--                 separator passed to RandomAccess:ReadLine (Perl's
--                 `local $/`); an undefined separator (slurp mode upstream)
--                 falls back to "\n".
--               - Image::ExifTool::GetLangInfo is Writer.GetLangInfo.
--               - The read-and-compare steps inside ProcessFont's PFM
--                 condition use two small local readers (Read/Read2).
--------------------------------------------------------------------------------


local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local isMatch = perl.isMatch
local subst = perl.subst
local tr = perl.tr
local lc = perl.lc
local uc = perl.uc
local ord = perl.ord
local at = perl.at
local length = perl.length
local substr = perl.substr
local unpack = perl.unpack
local sprintf = perl.sprintf
local num_ = perl.num
local str = perl.str
local truthy = perl.truthy
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable

local Font = {}


-- (upstream's predeclaration; the sub below assigns to it)
local ProcessOTF

-- OTF tags to process (skip all others)
local processTag = { name = 1, C2PA = 1 }

-- TrueType 'name' platform codes
local ttPlatform = {
    [0] = 'Unicode',
    [1] = 'Macintosh',
    [2] = 'ISO',
    [3] = 'Windows',
    [4] = 'Custom',
}

-- convert TrueType 'name' character encoding to ExifTool Charset (ref 1/2)
local ttCharset = {
  Macintosh = {
    [0] = 'MacRoman',      [17] = 'MacMalayalam',
    [1] = 'MacJapanese',   [18] = 'MacSinhalese',
    [2] = 'MacChineseTW',  [19] = 'MacBurmese',
    [3] = 'MacKorean',     [20] = 'MacKhmer',
    [4] = 'MacArabic',     [21] = 'MacThai',
    [5] = 'MacHebrew',     [22] = 'MacLaotian',
    [6] = 'MacGreek',      [23] = 'MacGeorgian',
    [7] = 'MacCyrillic',   [24] = 'MacArmenian', -- 7=Russian
    [8] = 'MacRSymbol',    [25] = 'MacChineseCN',
    [9] = 'MacDevanagari', [26] = 'MacTibetan',
   [10] = 'MacGurmukhi',   [27] = 'MacMongolian',
   [11] = 'MacGujarati',   [28] = 'MacGeez',
   [12] = 'MacOriya',      [29] = 'MacCyrillic', -- 29=Slavic
   [13] = 'MacBengali',    [30] = 'MacVietnam',
   [14] = 'MacTamil',      [31] = 'MacSindhi',
   [15] = 'MacTelugu',     [32] = '', -- 32=uninterpreted
   [16] = 'MacKannada',
  },
  Windows = {
    [0] = 'Symbol',         [4] = 'Big5',
    [1] = 'UCS2',           [5] = 'Wansung',
    [2] = 'ShiftJIS',       [6] = 'Johab',
    [3] = 'PRC',           [10] = 'UCS4',
  },
  Unicode = {
    -- (we don't currently handle the various Unicode flavours)
    [0] = 'UCS2', -- Unicode 1.0 semantics
    [1] = 'UCS2', -- Unicode 1.1 semantics
    [2] = 'UCS2', -- ISO 10646 semantics
    [3] = 'UCS2', -- Unicode 2.0 and onwards semantics, Unicode BMP only.
    [4] = 'UTF16', -- Unicode 2.0 and onwards semantics, Unicode full repertoire.
    -- 5 => Unicode Variation Sequences (not used in Naming table)
  },
  ISO = { -- (deprecated)
    [0] = 'UTF8',  -- (7-bit ASCII)
    [1] = 'UCS2',  -- ISO 10646
    [2] = 'Latin', -- ISO 8859-1
  },
  Custom = { },
}

-- convert TrueType 'name' language code to ExifTool language code
local ttLang = {
  -- Macintosh language codes (also used by QuickTime.pm)
  -- oddities:
  --   49 - Cyrillic version    83 - Roman
  --   50 - Arabic version     84 - Arabic
  --  146 - with dot above
  Macintosh = {
    [0] = 'en',     [24] = 'lt',    [48] = 'kk',    [72] = 'ml',    [129] = 'eu',
    [1] = 'fr',     [25] = 'pl',    [49] = 'az',    [73] = 'kn',    [130] = 'ca',
    [2] = 'de',     [26] = 'hu',    [50] = 'az',    [74] = 'ta',    [131] = 'la',
    [3] = 'it',     [27] = 'et',    [51] = 'hy',    [75] = 'te',    [132] = 'qu',
    [4] = 'nl-NL',  [28] = 'lv',    [52] = 'ka',    [76] = 'si',    [133] = 'gn',
    [5] = 'sv',     [29] = 'smi',   [53] = 'ro',    [77] = 'my',    [134] = 'ay',
    [6] = 'es',     [30] = 'fo',    [54] = 'ky',    [78] = 'km',    [135] = 'tt',
    [7] = 'da',     [31] = 'fa',    [55] = 'tg',    [79] = 'lo',    [136] = 'ug',
    [8] = 'pt',     [32] = 'ru',    [56] = 'tk',    [80] = 'vi',    [137] = 'dz',
    [9] = 'no',     [33] = 'zh-CN', [57] = 'mn-MN', [81] = 'id',    [138] = 'jv',
    [10] = 'he',    [34] = 'nl-BE', [58] = 'mn-CN', [82] = 'tl',    [139] = 'su',
    [11] = 'ja',    [35] = 'ga',    [59] = 'ps',    [83] = 'ms-MY', [140] = 'gl',
    [12] = 'ar',    [36] = 'sq',    [60] = 'ku',    [84] = 'ms-BN', [141] = 'af',
    [13] = 'fi',    [37] = 'ro',    [61] = 'ks',    [85] = 'am',    [142] = 'br',
    [14] = 'el',    [38] = 'cs',    [62] = 'sd',    [86] = 'ti',    [144] = 'gd',
    [15] = 'is',    [39] = 'sk',    [63] = 'bo',    [87] = 'om',    [145] = 'gv',
    [16] = 'mt',    [40] = 'sl',    [64] = 'ne',    [88] = 'so',    [146] = 'ga',
    [17] = 'tr',    [41] = 'yi',    [65] = 'sa',    [89] = 'sw',    [147] = 'to',
    [18] = 'hr',    [42] = 'sr',    [66] = 'mr',    [90] = 'rw',    [148] = 'el',
    [19] = 'zh-TW', [43] = 'mk',    [67] = 'bn',    [91] = 'rn',    [149] = 'kl',
    [20] = 'ur',    [44] = 'bg',    [68] = 'as',    [92] = 'ny',    [150] = 'az',
    [21] = 'hi',    [45] = 'uk',    [69] = 'gu',    [93] = 'mg',
    [22] = 'th',    [46] = 'be',    [70] = 'pa',    [94] = 'eo',
    [23] = 'ko',    [47] = 'uz',    [71] = 'or',   [128] = 'cy',
  },
  -- Windows language codes (http://msdn.microsoft.com/en-us/library/0h88fahh(VS.85).aspx)
  -- Notes: This isn't an exact science.  The reference above gives language codes
  -- which are different from some ISO 639-1 numbers.  Also, some Windows language
  -- codes don't appear to have ISO 639-1 equivalents.
  --  0x0428 - fa by ref above
  --  0x048c - no ISO equivalent
  --  0x081a/0x83c - sr-SP
  --  0x0c0a - modern?
  --  0x2409 - Caribbean country code not found in ISO 3166-1
  Windows = {
    [0x0401] = 'ar-SA', [0x0438] = 'fo',    [0x0481] = 'mi',    [0x1409] = 'en-NZ',
    [0x0402] = 'bg',    [0x0439] = 'hi',    [0x0482] = 'oc',    [0x140a] = 'es-CR',
    [0x0403] = 'ca',    [0x043a] = 'mt',    [0x0483] = 'co',    [0x140c] = 'fr-LU',
    [0x0404] = 'zh-TW', [0x043b] = 'se-NO', [0x0484] = 'gsw',   [0x141a] = 'bs-BA',
    [0x0405] = 'cs',    [0x043c] = 'gd',    [0x0485] = 'sah',   [0x143b] = 'smj-SE',
    [0x0406] = 'da',    [0x043d] = 'yi',    [0x0486] = 'ny',    [0x1801] = 'ar-MA',
    [0x0407] = 'de-DE', [0x043e] = 'ms-MY', [0x0487] = 'rw',    [0x1809] = 'en-IE',
    [0x0408] = 'el',    [0x043f] = 'kk',    [0x048c] = 'Dari',  [0x180a] = 'es-PA',
    [0x0409] = 'en-US', [0x0440] = 'ky',    [0x0801] = 'ar-IQ', [0x180c] = 'fr-MC',
    [0x040a] = 'es-ES', [0x0441] = 'sw',    [0x0804] = 'zh-CN', [0x181a] = 'sr-BA',
    [0x040b] = 'fi',    [0x0442] = 'tk',    [0x0807] = 'de-CH', [0x183b] = 'sma-NO',
    [0x040c] = 'fr-FR', [0x0443] = 'uz-UZ', [0x0809] = 'en-GB', [0x1c01] = 'ar-TN',
    [0x040d] = 'he',    [0x0444] = 'tt',    [0x080a] = 'es-MX', [0x1c09] = 'en-ZA',
    [0x040e] = 'hu',    [0x0445] = 'bn-IN', [0x080c] = 'fr-BE', [0x1c0a] = 'es-DO',
    [0x040f] = 'is',    [0x0446] = 'pa',    [0x0810] = 'it-CH', [0x1c1a] = 'sr-BA',
    [0x0410] = 'it-IT', [0x0447] = 'gu',    [0x0813] = 'nl-BE', [0x1c3b] = 'sma-SE',
    [0x0411] = 'ja',    [0x0448] = 'wo',    [0x0814] = 'nn',    [0x2001] = 'ar-OM',
    [0x0412] = 'ko',    [0x0449] = 'ta',    [0x0816] = 'pt-PT', [0x2009] = 'en-JM',
    [0x0413] = 'nl-NL', [0x044a] = 'te',    [0x0818] = 'ro-MO', [0x200a] = 'es-VE',
    [0x0414] = 'no-NO', [0x044b] = 'kn',    [0x0819] = 'ru-MO', [0x201a] = 'bs-BA',
    [0x0415] = 'pl',    [0x044c] = 'ml',    [0x081a] = 'sr-RS', [0x203b] = 'sms',
    [0x0416] = 'pt-BR', [0x044d] = 'as',    [0x081d] = 'sv-FI', [0x2401] = 'ar-YE',
    [0x0417] = 'rm',    [0x044e] = 'mr',    [0x082c] = 'az-AZ', [0x2409] = 'en-CB',
    [0x0418] = 'ro',    [0x044f] = 'sa',    [0x082e] = 'dsb',   [0x240a] = 'es-CO',
    [0x0419] = 'ru',    [0x0450] = 'mn-MN', [0x083b] = 'se-SE', [0x243b] = 'smn',
    [0x041a] = 'hr',    [0x0451] = 'bo',    [0x083c] = 'ga',    [0x2801] = 'ar-SY',
    [0x041b] = 'sk',    [0x0452] = 'cy',    [0x083e] = 'ms-BN', [0x2809] = 'en-BZ',
    [0x041c] = 'sq',    [0x0453] = 'km',    [0x0843] = 'uz-UZ', [0x280a] = 'es-PE',
    [0x041d] = 'sv-SE', [0x0454] = 'lo',    [0x0845] = 'bn-BD', [0x2c01] = 'ar-JO',
    [0x041e] = 'th',    [0x0456] = 'gl',    [0x0850] = 'mn-CN', [0x2c09] = 'en-TT',
    [0x041f] = 'tr',    [0x0457] = 'kok',   [0x085d] = 'iu-CA', [0x2c0a] = 'es-AR',
    [0x0420] = 'ur',    [0x045a] = 'syr',   [0x085f] = 'tmh',   [0x3001] = 'ar-LB',
    [0x0421] = 'id',    [0x045b] = 'si',    [0x086b] = 'qu-EC', [0x3009] = 'en-ZW',
    [0x0422] = 'uk',    [0x045d] = 'iu-CA', [0x0c01] = 'ar-EG', [0x300a] = 'es-EC',
    [0x0423] = 'be',    [0x045e] = 'am',    [0x0c04] = 'zh-HK', [0x3401] = 'ar-KW',
    [0x0424] = 'sl',    [0x0461] = 'ne',    [0x0c07] = 'de-AT', [0x3409] = 'en-PH',
    [0x0425] = 'et',    [0x0462] = 'fy',    [0x0c09] = 'en-AU', [0x340a] = 'es-CL',
    [0x0426] = 'lv',    [0x0463] = 'ps',    [0x0c0a] = 'es-ES', [0x3801] = 'ar-AE',
    [0x0427] = 'lt',    [0x0464] = 'fil',   [0x0c0c] = 'fr-CA', [0x380a] = 'es-UY',
    [0x0428] = 'tg',    [0x0465] = 'dv',    [0x0c1a] = 'sr-RS', [0x3c01] = 'ar-BH',
    [0x042a] = 'vi',    [0x0468] = 'ha',    [0x0c3b] = 'se-FI', [0x3c0a] = 'es-PY',
    [0x042b] = 'hy',    [0x046a] = 'yo',    [0x0c6b] = 'qu-PE', [0x4001] = 'ar-QA',
    [0x042c] = 'az-AZ', [0x046b] = 'qu-BO', [0x1001] = 'ar-LY', [0x4009] = 'en-IN',
    [0x042d] = 'eu',    [0x046c] = 'st',    [0x1004] = 'zh-SG', [0x400a] = 'es-BO',
    [0x042e] = 'hsb',   [0x046d] = 'ba',    [0x1007] = 'de-LU', [0x4409] = 'en-MY',
    [0x042f] = 'mk',    [0x046e] = 'lb',    [0x1009] = 'en-CA', [0x440a] = 'es-SV',
    [0x0430] = 'st',    [0x046f] = 'kl',    [0x100a] = 'es-GT', [0x4809] = 'en-SG',
    [0x0431] = 'ts',    [0x0470] = 'ig',    [0x100c] = 'fr-CH', [0x480a] = 'es-HN',
    [0x0432] = 'tn',    [0x0478] = 'yi',    [0x101a] = 'hr-BA', [0x4c0a] = 'es-NI',
    [0x0434] = 'xh',    [0x047a] = 'arn',   [0x103b] = 'smj-NO',[0x500a] = 'es-PR',
    [0x0435] = 'zu',    [0x047c] = 'moh',   [0x1401] = 'ar-DZ', [0x540a] = 'es-US',
    [0x0436] = 'af',    [0x047e] = 'br',    [0x1404] = 'zh-MO',
    [0x0437] = 'ka',    [0x0480] = 'ug',    [0x1407] = 'de-LI',
  },
  Unicode = { },
  ISO     = { },
  Custom  = { },
}
Font.ttLang = ttLang

-- the 63 known WOFF2 tags
local knownTags = {
    'cmap', 'head', 'hhea', 'hmtx', 'maxp', 'name', 'OS/2', 'post', 'cvt',
    'fpgm', 'glyf', 'loca', 'prep', 'CFF',  'VORG', 'EBDT', 'EBLC', 'gasp',
    'hdmx', 'kern', 'LTSH', 'PCLT', 'VDMX', 'vhea', 'vmtx', 'BASE', 'GDEF',
    'GPOS', 'GSUB', 'EBSC', 'JSTF', 'MATH', 'CBDT', 'CBLC', 'COLR', 'CPAL',
    'SVG',  'sbix', 'acnt', 'avar', 'bdat', 'bloc', 'bsln', 'cvar', 'fdsc',
    'feat', 'fmtx', 'fvar', 'gvar', 'hsty', 'just', 'lcar', 'mort', 'morx',
    'opbd', 'prop', 'trak', 'Zapf', 'Silf', 'Glat', 'Gloc', 'Feat', 'Sill',
}

-- eclectic table of tags for various format font files
Font.Main = {
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        This table contains a collection of tags found in font files of various
        formats.  ExifTool current recognizes OTF, TTF, TTC, DFONT, PFA, PFB, PFM,
        AFM, ACFM, AMFM, WOFF and WOFF2 font files.
    ]],
    name = {
        SubDirectory = { TagTable = 'lexiftool.Font.Name' },
    },
    C2PA = {
        SubDirectory = { TagTable = 'lexiftool.Jpeg2000.Main', Start = 20 },
    },
    PFM  = {
        Name = 'PFMHeader',
        SubDirectory = { TagTable = 'lexiftool.Font.PFM' },
    },
    PSInfo = {
        Name = 'PSFontInfo',
        SubDirectory = { TagTable = 'lexiftool.Font.PSInfo' },
    },
    AFM = {
        Name = 'AFM',
        SubDirectory = { TagTable = 'lexiftool.Font.AFM' },
    },
    numfonts = 'NumFonts',
    fontname = 'FontName',
    postfont = {
        Name = 'PostScriptFontName',
        Description = 'PostScript Font Name',
    },
    -- for WOFF files
    WOFFVersion = { },
    XML = {
        SubDirectory = {
            TagTable = 'lexiftool.Font.XML',
            IgnoreProp = { metadata = 1 },
        },
    },
}

-- TrueType name tags (ref 1/2)
Font.Name = {
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        The following tags are extracted from the TrueType font "name" table found
        in OTF, TTF, TTC, DFONT, WOFF and WOFF2 files.  These tags support localized
        languages by adding a hyphen followed by a language code to the end of the
        tag name (eg. "Copyright-fr" or "License-en-US").  Tags with no language
        code use the default language of "en".
    ]],
    [0] = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    [1] = 'FontFamily',
    [2] = 'FontSubfamily',
    [3] = 'FontSubfamilyID',
    [4] = 'FontName', -- full name
    [5] = 'NameTableVersion',
    [6] = { Name = 'PostScriptFontName', Description = 'PostScript Font Name' },
    [7] = 'Trademark',
    [8] = 'Manufacturer',
    [9] = 'Designer',
    [10] = 'Description',
    [11] = 'VendorURL',
    [12] = 'DesignerURL',
    [13] = 'License',
    [14] = 'LicenseInfoURL',
    [16] = 'PreferredFamily',
    [17] = 'PreferredSubfamily',
    [18] = 'CompatibleFontName',
    [19] = 'SampleText',
    [20] = {
        Name = 'PostScriptFontName',
        Description = 'PostScript Font Name',
    },
    [21] = 'WWSFamilyName',
    [22] = 'WWSSubfamilyName',
}

-- PostScript Font Metric file header (ref 4)
Font.PFM = {
    GROUPS = { [2] = 'Document' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'Tags extracted from the PFM file header.',
    [0] = {
        Name = 'PFMVersion',
        Format = 'int16u',
        PrintConv = function(_self, val) return sprintf("%x.%.2x",val>>8,val&0xff) end,
    },
    [6]  = { Name = 'Copyright',       Format = 'string[60]', Groups = { [2] = 'Author' } },
    [66] = { Name = 'FontType',        Format = 'int16u' },
    [68] = { Name = 'PointSize',       Format = 'int16u' },
    [70] = { Name = 'YResolution',     Format = 'int16u' },
    [72] = { Name = 'XResolution',     Format = 'int16u' },
    [74] = { Name = 'Ascent',          Format = 'int16u' },
    [76] = { Name = 'InternalLeading', Format = 'int16u' },
    [78] = { Name = 'ExternalLeading', Format = 'int16u' },
    [80] = { Name = 'Italic' },
    [81] = { Name = 'Underline' },
    [82] = { Name = 'Strikeout' },
    [83] = { Name = 'Weight',          Format = 'int16u' },
    [85] = { Name = 'CharacterSet' },
    [86] = { Name = 'PixWidth',        Format = 'int16u' },
    [88] = { Name = 'PixHeight',       Format = 'int16u' },
    [90] = { Name = 'PitchAndFamily' },
    [91] = { Name = 'AvgWidth',        Format = 'int16u' },
    [93] = { Name = 'MaxWidth',        Format = 'int16u' },
    [95] = { Name = 'FirstChar' },
    [96] = { Name = 'LastChar' },
    [97] = { Name = 'DefaultChar' },
    [98] = { Name = 'BreakChar' },
    [99] = { Name = 'WidthBytes',      Format = 'int16u' },
   -- 101 => { Name => 'DeviceTypeOffset', Format => 'int32u' },
   -- 105 => { Name => 'FontNameOffset',   Format => 'int32u' },
   -- 109 => { Name => 'BitsPointer',      Format => 'int32u' },
   -- 113 => { Name => 'BitsOffset',       Format => 'int32u' },
}

-- PostScript FontInfo attributes (PFA, PFB) (ref PH)
Font.PSInfo = {
    GROUPS = { [2] = 'Document' },
    NOTES = 'Tags extracted from PostScript font files (PFA and PFB).',
    FullName    = { },
    FamilyName  = { Name = 'FontFamily' },
    Weight      = { },
    ItalicAngle = { },
    isFixedPitch= { },
    UnderlinePosition  = { },
    UnderlineThickness = { },
    Copyright   = { Groups = { [2] = 'Author' } },
    Notice      = { Groups = { [2] = 'Author' } },
    version     = { },
    FontName    = { },
    FontType    = { },
    FSType      = { },
}

-- Adobe Font Metrics tags (AFM) (ref 6)
Font.AFM = {
    GROUPS = { [2] = 'Document' },
    NOTES = 'Tags extracted from Adobe Font Metrics files (AFM, ACFM and AMFM).',
   ['Creation Date'] = { Name = 'CreateDate', Groups = { [2] = 'Time' } },
    FontName    = { },
    FullName    = { },
    FamilyName = { Name = 'FontFamily' },
    Weight      = { },
    Version     = { },
    Notice      = { Groups = { [2] = 'Author' } },
    EncodingScheme = { },
    MappingScheme  = { },
    EscChar     = { },
    CharacterSet= { },
    Characters  = { },
    IsBaseFont  = { },
   -- VVector     => { },
    IsFixedV    = { },
    CapHeight   = { },
    XHeight     = { },
    Ascender    = { },
    Descender   = { },
}

-- WOFF XML
Font.XML = {
    GROUPS = { [1] = 'XML', [2] = 'Document' },
    PROCESS_PROC = function(...) return require('lexiftool.XMP').ProcessXMP(...) end,
    NOTES = 'Tags found in WOFF and WOFF2 XML metadata.',
    version             = { },
    uniqueidId          = { Name = 'UniqueID' },
    vendorName          = { },
    vendorUrl           = { Name = 'VendorURL' },
    vendorDir           = { },
    vendorClass         = { },
    creditsCreditName   = { Name = 'CreditName' },
    creditsCreditUrl    = { Name = 'CreditURL' },
    creditsCreditRole   = { Name = 'CreditRole' },
    creditsCreditDir    = { Name = 'CreditDir' },
    creditsCreditClass  = { Name = 'CreditClass' },
    descriptionUrl      = { },
    descriptionText     = { Name = 'Description' },
    licenseUrl          = { Name = 'LicenseURL' },
    licenseId           = { Name = 'LicenseID' },
    licenseText         = { Name = 'License' },
    copyrightText       = { Name = 'Copyright', Groups = { [2] = 'Author' } },
    trademarkText       = { Name = 'Trademark' },
    licenseeDir         = { },
    licenseeName        = { },
    licenseeClass       = { },
    extensionId         = { Name = 'ExtensionID' },
    extensionName       = { },
    extensionItemId     = { Name = 'ExtensionItemID' },
    extensionItemName   = { },
    extensionItemValue  = { },
}

--------------------------------------------------------------------------------
-- Read information from a TrueType font collection (TTC) (refs 2,3)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid TrueType font collection
local function ProcessTTC(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff

    n, buff = raf:Read(12)
    if n ~= 12 then return 0 end
    if not isMatch(buff, [[^ttcf\0[\x01\x02]\0\0]]) then return 0 end
    SetByteOrder('MM')
    local num = Get32u(buff, 8)
    -- might as well put a limit on the number of fonts we will parse (< 256)
    if num < 0x100 then n, buff = raf:Read(num * 4) end
    if not (num < 0x100 and n == num * 4) then return 0 end
    et:SetFileType('TTC')
    if truthy(et.OPTIONS.FastScan) and num_(et.OPTIONS.FastScan) == 3 then return 1 end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Font.Main')
    et:HandleTag(tagTablePtr, 'numfonts', num)
    -- loop through all fonts in the collection
    for i = 0, num - 1 do
        local n_ = i + 1
        et:VPrint(0, "Font " .. n_ .. ":\n")
        et.SET_GROUP1 = "+" .. n_
        local offset = Get32u(buff, i * 4)
        if not raf:Seek(offset, 0) then break end
        if not truthy(ProcessOTF(et, dirInfo)) then break end
    end
    et.SET_GROUP1 = nil
    return 1
end
Font.ProcessTTC = ProcessTTC

--------------------------------------------------------------------------------
-- Process an OTF tag table entry (refs 1,2)
-- Inputs: 0) ExifTool ref, 1) entry index, 2) tag, 3) data ref,
--         4) offset if uncompressed, 5) true to skip because data is transformed
-- Returns: undef on success, 0 to stop processing table, or error string otherwise
local function ProcessTableEntry(et, idx, tag, dataPt, offset, transformed)
    local verbose = et:Options('Verbose')
    local size = length(dataPt)

    if not truthy(offset) then offset = 0 end
    if truthy(verbose) then
        tag = subst(tag, '([\\0-\\x1f\\x7f-\\xff])', function(c) return sprintf('\\x%.2x',ord(c)) end, 'g')
        local str_ = sprintf("%s%d) Tag '%s' (offset 0x%.4x, %d bytes)\n",
                          et.INDENT, idx, tag, offset, size)
        et:VPrint(0, str_)
        if verbose > 2 then et:VerboseDump(dataPt, { Addr = offset }) end
        if not processTag[tag] then return nil end
    end
    if truthy(transformed) or size < 8 then return nil end
    if tag ~= 'name' then
        local tagTablePtr = GetTagTable(nil, 'lexiftool.Font.Main')
        et:HandleTag(tagTablePtr, tag, nil, { DataPt = dataPt, Size = length(dataPt) })
        return nil
    end
    -- process the 'name' tag
    local entries = Get16u(dataPt, 2)
    local recEnd = 6 + entries * 12
    if recEnd > size then
        et:Warn('Truncated name record')
        return 0
    end
    local strStart = Get16u(dataPt, 4)
    if strStart < recEnd or strStart > size then
        et:Warn('Invalid string offset')
        return 0
    end
    -- parse language-tag record (in format 1 Naming table only) (ref 2)
    local langTag = {}
    if Get16u(dataPt, 0) == 1 and recEnd + 2 <= size then
        local langTags = Get16u(dataPt, recEnd)
        if langTags ~= 0 and recEnd + 2 + langTags * 4 < size then
            for i = 0, langTags - 1 do
                local pt = recEnd + 2 + i * 4
                local langLen = Get16u(dataPt, pt)
                -- make sure the language string length is reasonable (UTF-16BE)
                if langLen == 0 or (langLen & 0x01) ~= 0 or langLen > 40 then break end
                local langPt = Get16u(dataPt, pt + 2) + strStart
                if langPt + langLen > size then break end
                local lang = substr(dataPt, langPt, langLen)
                lang = et:Decode(lang,'UCS2','MM','UTF8')
                lang = tr(lang, '-_a-zA-Z0-9', '', 'dc')    -- remove naughty characters
                langTag[i + 0x8000] = lang
            end
        end
    end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Font.Name')
    local oldIndent = et.INDENT
    et.INDENT = et.INDENT .. '| '
    if truthy(verbose) then et:VerboseDir('Name', entries) end
    for i = 0, entries - 1 do
        local pt = 6 + i * 12
        local platform = Get16u(dataPt, pt)
        local encoding = Get16u(dataPt, pt + 2)
        local langID   = Get16u(dataPt, pt + 4)
        local nameID   = Get16u(dataPt, pt + 6)
        local strLen   = Get16u(dataPt, pt + 8)
        local strPt    = Get16u(dataPt, pt + 10) + strStart
        if strPt + strLen <= size then
            local val = substr(dataPt, strPt, strLen)
            local lang, charset, extra
            local sys = ttPlatform[platform]
            -- translate from specified encoding
            if sys then
                lang = ttLang[sys][langID] or langTag[langID]
                charset = ttCharset[sys][encoding]
                if not truthy(charset) then
                    if charset == nil and not truthy(et.FontWarn) then
                        et:Warn("Unknown " .. sys .. " character set (" .. encoding .. ")")
                        et.FontWarn = 1
                    end
                else
                    -- translate to ExifTool character set
                    val = et:Decode(val, charset)
                end
            else
                et:Warn("Unknown platform (" .. platform .. ") for name " .. nameID)
            end
            -- get the tagInfo for our specific language (use 'en' for default)
            local tagInfo = et:GetTagInfo(tagTablePtr, nameID)
            if tagInfo and truthy(lang) and lang ~= 'en' then
                local langInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, lang)
                if langInfo then tagInfo = langInfo end
            end
            if truthy(verbose) then
                if langID > 0x400 then langID = sprintf('0x%x', langID) end
                extra = ", Plat=" .. platform .. "/" .. (sys or 'Unknown') .. ', ' ..
                           "Enc=" .. encoding .. "/" .. (truthy(charset) and charset or 'Unknown') .. ', ' ..
                           "Lang=" .. langID .. "/" .. (truthy(lang) and lang or 'Unknown')
            end
            et:HandleTag(tagTablePtr, nameID, val, {
                TagInfo = tagInfo,
                DataPt  = dataPt,
                DataPos = offset,
                Start   = strPt,
                Size    = strLen,
                Index   = i,
                Extra   = extra,
            })
        end
    end
    et.INDENT = oldIndent
    if truthy(verbose) then return nil end
    return 0
end
Font.ProcessTableEntry = ProcessTableEntry

--------------------------------------------------------------------------------
-- Read information from a TrueType font file (OTF or TTF) (refs 1,2)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid TrueType font file
function ProcessOTF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, tbl, buff
    local base = dirInfo.Base or 0

    n, buff = raf:Read(12)
    if n ~= 12 then return 0 end
    local ok, c1 = isMatch(buff, [=[^(\0\x01\0\0|OTTO|true|typ1|\xa5(kbd|lst))[\0\x01]]=])
    if not ok then return 0 end

    et:SetFileType(c1 == 'OTTO' and 'OTF' or 'TTF')
    if truthy(et.OPTIONS.FastScan) and num_(et.OPTIONS.FastScan) == 3 then return 1 end
    SetByteOrder('MM')
    local numTables = Get16u(buff, 4)
    if not (numTables > 0 and numTables < 0x200) then return 0 end
    local len = numTables * 16
    n, tbl = raf:Read(len)
    if n ~= len then return 0 end

    local verbose = et:Options('Verbose')

    local i = 0
    for pos = 0, len - 1, 16 do
        -- look for tags to process
        local tag = substr(tbl, pos, 4)
        if not (processTag[tag] or truthy(verbose)) then goto continue end
        do
            local offset = Get32u(tbl, pos + 8)
            local size   = Get32u(tbl, pos + 12)
            local seekOK = raf:Seek(offset+base, 0)
            if seekOK then n, buff = raf:Read(size) end
            if not (seekOK and n == size) then
                et:Warn("Error reading '" .. tag .. "' data")
                goto continue
            end
            local err = ProcessTableEntry(et, i, tag, buff, offset)
            if truthy(err) then et:Warn(err) break end
            if err ~= nil then break end
        end
        ::continue::
        i = i + 1
    end
    return 1
end
Font.ProcessOTF = ProcessOTF

--------------------------------------------------------------------------------
-- Read information from an Adobe Font Metrics file (AFM, ACFM, AMFM) (ref 6)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a recognized AFM-type file
local function ProcessAFM(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff, comment

    local PostScript = require('lexiftool.PostScript')
    local rs = PostScript.GetInputRecordSeparator(raf)  -- (upstream `local $/ = ...`)
    buff = select(2, raf:ReadLine(rs))
    local ok, c1 = isMatch(buff, [[^Start(Comp|Master)?FontMetrics\s+\d+]])
    if not ok then return 0 end
    local ftyp = c1 and (c1 == 'Comp' and 'ACFM' or 'AMFM') or 'AFM'
    et:SetFileType(ftyp, 'application/x-font-afm')
    if truthy(et.OPTIONS.FastScan) and num_(et.OPTIONS.FastScan) == 3 then return 1 end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Font.AFM')

    while true do
        n, buff = raf:ReadLine(rs)
        if not truthy(n) then break end
        if comment ~= nil and not isMatch(buff, [[^Comment\s]]) then
            et:FoundTag('Comment', comment)
            comment = nil
        end
        local ok2, tag, val = isMatch(buff, [=[^(\w+)\s+(.*?)[\x0d\x0a]]=])
        if not ok2 then goto continue end
        do
            local ok3, t3, v3 = isMatch(val, [[^(Creation Date):\s+(.*)]])
            if tag == 'Comment' and ok3 then
                tag, val = t3, v3
            end
            val = subst(val, [[^\((.*)\)$]], '$1')   -- (some values may be in brackets)
            if tag == 'Comment' then
                -- concatinate all comments into a single value
                comment = comment ~= nil and comment .. "\n" .. val or val
                goto continue
            end
            if not et:HandleTag(tagTablePtr, tag, val) then
                -- end parsing if we start any subsection
                if isMatch(tag, '^Start') and tag ~= 'StartDirection' then break end
            end
        end
        ::continue::
    end
    return 1
end
Font.ProcessAFM = ProcessAFM

--------------------------------------------------------------------------------
-- Read WOFF2 255UInt16 integer (ref 8)
-- Inputs: 0) raf ref
-- Returns: value, or undef on error
local function Read255UInt16(raf)
    local n, buff
    n, buff = raf:Read(1)
    if not truthy(n) then return nil end
    local val = unpack('C', buff)
    if val == 253 then
        n, buff = raf:Read(2)
        if n ~= 2 then return nil end
        val = unpack('n', buff)
    elseif val == 254 then
        n, buff = raf:Read(1)
        if not truthy(n) then return nil end
        val = unpack('C', buff) + 253 * 2
    elseif val == 255 then
        n, buff = raf:Read(1)
        if not truthy(n) then return nil end
        val = unpack('C', buff) + 253
    end
    return val
end
Font.Read255UInt16 = Read255UInt16

--------------------------------------------------------------------------------
-- Read WOFF2 UIntBase128 integer (ref 8)
-- Inputs: 0) raf ref
-- Returns: value, or undef on error
local function ReadUIntBase128(raf)
    local n, buff
    local val = 0
    for i = 0, 4 do
        n, buff = raf:Read(1)
        if not truthy(n) then return nil end
        local byte = unpack('C', buff)
        if i == 0 and byte == 0x80 then return nil end
        if (val & 0xfe000000) ~= 0 then return nil end
        val = (val << 7) | (byte & 0x7f)
        if (byte & 0x80) == 0 then return val end
    end
    return nil   -- can't be longer than 5 bytes
end
Font.ReadUIntBase128 = ReadUIntBase128

--------------------------------------------------------------------------------
-- Uncompress data
-- Inputs: 0) ExifTool ref, 1) data ref
-- Returns: true on success
-- (port: returns the uncompressed data as a second value, where upstream
--  replaces $$dataPt)
local function Uncompress(et, dataPt)
    if not et:hasZlib() then
        et:Warn('Install Compress::Zlib to read compressed metadata')
        return 0
    end
    local out, stat = et:inflate(dataPt)
    if not stat then
        et:Warn('Error uncompressing metadata')
        return 0
    end
    return 1, out
end
Font.Uncompress = Uncompress

--------------------------------------------------------------------------------
-- Brotli uncompress data
-- Inputs: 0) ExifTool ref, 1) data ref
-- Returns: true on success
-- (port: the uncompressed data is a second return value)
local function Unbrotli(et, dataPt)
    local haveBrotli, IO_Uncompress_Brotli = perl.evalRequire('IO::Uncompress::Brotli')
    if not haveBrotli then
        et:Warn('Install IO::Compress::Brotli to decode Brotli-compressed metadata')
        return 0
    end
    local ok, out = pcall(IO_Uncompress_Brotli.unbro, dataPt, 100000000)
    if not ok then
        et:Warn('Error decoding metadata')
        et:Warn('Try updating to IO::Uncompress::Brotli 0.004 or later')
        return 0
    end
    return 1, out
end
Font.Unbrotli = Unbrotli

--------------------------------------------------------------------------------
-- Read information from WOFF/WOFF2 font files
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a recognized WOFF file
local function ProcessWOFF(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff, tbl, okC
    local seekOK = raf:Seek(0,0)
    if seekOK then n, buff = raf:Read(48) end
    if not (seekOK and n == 48) then return 0 end
    local ok, c1 = isMatch(buff, '^(wOF[F2])')
    if not ok then return 0 end
    local type_, off
    if c1 == 'wOFF' then type_, off = 'woff' , 20 else type_, off = 'woff2', 24 end
    et:SetFileType(uc(type_), "font/" .. type_)
    SetByteOrder('MM')
    local flavor = substr(buff, 4, 4)
    local numTables = Get16u(buff, 12)
    local vh, vl, metaPos, metaLen = unpack("x" .. off .. "nnNN", buff)
    local verbose = et:Options('Verbose')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.Font.Main')
    et:HandleTag(tagTablePtr, 'WOFFVersion', vh .. "." .. vl)
--
-- read font table
--
    if type_ == 'woff' then
        seekOK = raf:Seek(off+24,0)
        if seekOK then n, tbl = raf:Read(numTables*20) end
        if not (seekOK and n==numTables*20) then
            et:Warn('Error reading font table')
            return 1
        end
        for i = 0, numTables - 1 do
            local pt = i * 20
            local tag, pos, compLen, len = unpack("x" .. pt .. "a4N3", tbl)
            if not (processTag[tag] or truthy(verbose)) then goto continue end
            do
                seekOK = raf:Seek(pos,0)
                if seekOK then n, buff = raf:Read(compLen) end
                if not (seekOK and n==compLen) then et:Warn('Bad font table entry') return 1 end
                local dataPos
                if str(compLen) == str(len) then
                    dataPos = pos
                else
                    okC, buff = Uncompress(et, buff)
                    if not truthy(okC) then goto continue end
                end
                local err = ProcessTableEntry(et, i, tag, buff, dataPos)
                if truthy(err) then et:Warn(err) return 1 end
                if err ~= nil then break end
            end
            ::continue::
        end
    else -- WOFF2
        local compSize = Get32u(buff, 20)
        local err
        local entry = {}
        if not raf:Seek(off+24,0) then et:Warn('Error seeking to font table') return 1 end
        for i = 0, numTables - 1 do
            n, buff = raf:Read(1)
            if not truthy(n) then err = 1 break end
            local flags = unpack('C', buff)
            local tag = at(knownTags, flags & 0x3f)
            if not truthy(tag) then
                n, tag = raf:Read(4)
                if n ~= 4 then err = 1 break end
            end
            local len = ReadUIntBase128(raf)
            if len == nil then err = 1 break end
            local transformed
            if (tag == 'glyf' or tag == 'loca') ~= ((flags & 0xc0) ~= 0) then
                -- a non-null transform was used
                len = ReadUIntBase128(raf)
                transformed = 1
            end
            -- save information about this entry for later
            entry[#entry + 1] = { i, tag, len, transformed }
        end
        if truthy(err) then et:Warn('Error reading font table') return 1 end
        -- skip the collection table if necessary
        if flavor == 'ttcf' then
            if not raf:Seek(4, 1) then et:Warn('Seek error') return 1 end
            local n_ = Read255UInt16(raf)
            if not (n_ ~= nil and raf:Seek(4,1)) then et:Warn('Error reading collection table') return 1 end
            if not raf:Seek(4, 1) then err = 1 end
            if not err then
                for _ = 0, n_ - 1 do
                    if Read255UInt16(raf) == nil then err = 1 break end
                end
            end
            if truthy(err) then et:Warn('Error reading collection directory') return 1 end
        end
        n, buff = raf:Read(compSize)
        if n ~= compSize then et:Warn('Error reading font data') return 1 end
        okC, buff = Unbrotli(et, buff)
        if not truthy(okC) then return 1 end
        -- after all that exhausting and frankly unnecessary work (poor file design),
        -- we finally have the uncompressed font data so we can process the table entries
        local pos = 0
        for _, ent in ipairs(entry) do
            local i, tag, len, transformed = ent[1], ent[2], ent[3], ent[4]
            if processTag[tag] or truthy(verbose) then
                local dat = substr(buff, pos, len)
                local err2 = ProcessTableEntry(et, i, tag, dat, nil, transformed)
                if truthy(err2) then et:Warn(err2) return 1 end
                if err2 ~= nil then break end
            end
            pos = pos + len
        end
    end
--
-- read compressed XML-format metadata (NC)
--
    if truthy(metaLen) then
        seekOK = raf:Seek(metaPos,0)
        if seekOK then n, buff = raf:Read(metaLen) end
        if not (seekOK and n==metaLen) then
            et:Warn('Error reading metadata')
            return 1
        end
        if type_ == 'woff' then
            okC, buff = Uncompress(et, buff)
            if not truthy(okC) then return 1 end
        else -- WOFF2
            okC, buff = Unbrotli(et, buff)
            if not truthy(okC) then return 1 end
        end
        -- (we don't properly support XML structures)
        local oldStruct = et:Options('Struct')
        et:Options('Struct', 0)
        et:HandleTag(tagTablePtr, 'XML', buff)
        et:Options('Struct', oldStruct)
    end
    return 1
end
Font.ProcessWOFF = ProcessWOFF

--------------------------------------------------------------------------------
-- Read information from various format font files
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a recognized Font file
function Font.ProcessFont(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff, buf2, rtnVal
    -- (port: Perl's `$raf->Read($buff, N) == N` inside the condition chain
    --  below, as a reader that sets buff/buf2 and returns the count)
    local function Read(len) n, buff = raf:Read(len) return n end
    local function Read2(len) local n2; n2, buf2 = raf:Read(len) return n2 end
    if not (truthy(Read(24)) and raf:Seek(0,0)) then return 0 end
    local isPS, ps1 = isMatch(buff, [[(?s)^(.{6})?%!(PS-(AdobeFont-|Bitstream )|FontType1-)]])
    if isMatch(buff, [=[^(\0\x01\0\0|OTTO|true|typ1)[\0\x01]]=]) then        -- OTF, TTF
        rtnVal = ProcessOTF(et, dirInfo)
    elseif isMatch(buff, [[^ttcf\0[\x01\x02]\0\0]]) then                  -- TTC
        rtnVal = ProcessTTC(et, dirInfo)
    elseif isMatch(buff, [[(?s)^Start(Comp|Master)?FontMetrics\s+\d+]]) then -- AFM
        rtnVal = ProcessAFM(et, dirInfo)
    elseif isPS then -- PFA, PFB
        if ps1 and raf:Seek(6,0) then et:SetFileType('PFB') end
        local PostScript = require('lexiftool.PostScript')
        rtnVal = PostScript.ProcessPS(et, dirInfo)
    elseif isMatch(buff, [=[^\0[\x01\x02]]=]) and raf:Seek(0, 2) and    -- PFM
             -- validate file size
             raf:Tell() > 117 and raf:Tell() == unpack('x2V',buff) and
             -- read PFM header
             raf:Seek(0,0) and Read(117) == 117 and
             -- validate "DeviceType" string (must be "PostScript\0")
             SetByteOrder('II') and raf:Seek(Get32u(buff, 101), 0) and
             -- the DeviceType should be "PostScript\0", but FontForge
             -- incorrectly writes "Postscript\0", so ignore case
             Read2(11) == 11 and lc(buf2) == "postscript\0"
    then
        et:SetFileType('PFM')
        if truthy(et.OPTIONS.FastScan) and num_(et.OPTIONS.FastScan) == 3 then return 1 end
        SetByteOrder('II')
        local tagTablePtr = GetTagTable(nil, 'lexiftool.Font.Main')
        -- process the PFM header
        et:HandleTag(tagTablePtr, 'PFM', buff)
        -- extract the font names
        local nameOff = Get32u(buff, 105)
        local ok, f1, f2
        if raf:Seek(nameOff, 0) and truthy(Read(256)) then
            ok, f1, f2 = isMatch(buff, [[^([\x20-\xff]+)\0([\x20-\xff]+)\0]])
        end
        if ok then
            et:HandleTag(tagTablePtr, 'fontname', f1)
            et:HandleTag(tagTablePtr, 'postfont', f2)
        end
        rtnVal = 1
    elseif isMatch(buff, '^(wOF[F2])') then
        rtnVal = ProcessWOFF(et, dirInfo)
    else
        rtnVal = 0
    end
    return rtnVal
end

return Font
