--------------------------------------------------------------------------------
-- File:         lexiftool/AES.lua
-- Ported from:  lib/Image/ExifTool/AES.pm
--
-- Description:  AES encryption with cipher-block chaining
--
-- Revisions:    2010/10/14 - P. Harvey Created
--
-- References:   1) http://www.hoozi.com/Articles/AESEncryption.htm
--               2) http://www.csrc.nist.gov/publications/fips/fips197/fips-197.pdf
--               3) http://www.faqs.org/rfcs/rfc3602.html
--
-- Port notes:   faithful port of the cipher core and the Crypt entry point;
--               the sbox/rsbox/rcon tables are mechanically extracted from
--               the upstream source verbatim (0-based Lua arrays standing in
--               for Perl's 0-based lists). API adaptation for Lua: Crypt
--               takes the data string directly and returns (data, err) --
--               upstream mutates the caller's scalar reference in place and
--               returns only an error string. Random-IV encryption seeds
--               math.random from the current time alone (upstream also mixes
--               in the process id, which has no Lua equivalent).
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local substr = perl.substr
local length = perl.length
local truthy = perl.truthy

local AES = {}

local seeded -- flag set if we already seeded random number generator
local nr     -- number of rounds in AES cipher
local cbc = {}   -- cipher-block chaining bytes

-- arrays (all unsigned character) to hold intermediate results during encryption
local state = { [0] = {}, {}, {}, {} } -- the 2-dimensional state array (0-based rows)
local RoundKey = {}              -- round keys

local sbox = {
    [0] = 0x63, [1] = 0x7c, [2] = 0x77, [3] = 0x7b, [4] = 0xf2, [5] = 0x6b, [6] = 0x6f, [7] = 0xc5,
    [8] = 0x30, [9] = 0x01, [10] = 0x67, [11] = 0x2b, [12] = 0xfe, [13] = 0xd7, [14] = 0xab, [15] = 0x76,
    [16] = 0xca, [17] = 0x82, [18] = 0xc9, [19] = 0x7d, [20] = 0xfa, [21] = 0x59, [22] = 0x47, [23] = 0xf0,
    [24] = 0xad, [25] = 0xd4, [26] = 0xa2, [27] = 0xaf, [28] = 0x9c, [29] = 0xa4, [30] = 0x72, [31] = 0xc0,
    [32] = 0xb7, [33] = 0xfd, [34] = 0x93, [35] = 0x26, [36] = 0x36, [37] = 0x3f, [38] = 0xf7, [39] = 0xcc,
    [40] = 0x34, [41] = 0xa5, [42] = 0xe5, [43] = 0xf1, [44] = 0x71, [45] = 0xd8, [46] = 0x31, [47] = 0x15,
    [48] = 0x04, [49] = 0xc7, [50] = 0x23, [51] = 0xc3, [52] = 0x18, [53] = 0x96, [54] = 0x05, [55] = 0x9a,
    [56] = 0x07, [57] = 0x12, [58] = 0x80, [59] = 0xe2, [60] = 0xeb, [61] = 0x27, [62] = 0xb2, [63] = 0x75,
    [64] = 0x09, [65] = 0x83, [66] = 0x2c, [67] = 0x1a, [68] = 0x1b, [69] = 0x6e, [70] = 0x5a, [71] = 0xa0,
    [72] = 0x52, [73] = 0x3b, [74] = 0xd6, [75] = 0xb3, [76] = 0x29, [77] = 0xe3, [78] = 0x2f, [79] = 0x84,
    [80] = 0x53, [81] = 0xd1, [82] = 0x00, [83] = 0xed, [84] = 0x20, [85] = 0xfc, [86] = 0xb1, [87] = 0x5b,
    [88] = 0x6a, [89] = 0xcb, [90] = 0xbe, [91] = 0x39, [92] = 0x4a, [93] = 0x4c, [94] = 0x58, [95] = 0xcf,
    [96] = 0xd0, [97] = 0xef, [98] = 0xaa, [99] = 0xfb, [100] = 0x43, [101] = 0x4d, [102] = 0x33, [103] = 0x85,
    [104] = 0x45, [105] = 0xf9, [106] = 0x02, [107] = 0x7f, [108] = 0x50, [109] = 0x3c, [110] = 0x9f, [111] = 0xa8,
    [112] = 0x51, [113] = 0xa3, [114] = 0x40, [115] = 0x8f, [116] = 0x92, [117] = 0x9d, [118] = 0x38, [119] = 0xf5,
    [120] = 0xbc, [121] = 0xb6, [122] = 0xda, [123] = 0x21, [124] = 0x10, [125] = 0xff, [126] = 0xf3, [127] = 0xd2,
    [128] = 0xcd, [129] = 0x0c, [130] = 0x13, [131] = 0xec, [132] = 0x5f, [133] = 0x97, [134] = 0x44, [135] = 0x17,
    [136] = 0xc4, [137] = 0xa7, [138] = 0x7e, [139] = 0x3d, [140] = 0x64, [141] = 0x5d, [142] = 0x19, [143] = 0x73,
    [144] = 0x60, [145] = 0x81, [146] = 0x4f, [147] = 0xdc, [148] = 0x22, [149] = 0x2a, [150] = 0x90, [151] = 0x88,
    [152] = 0x46, [153] = 0xee, [154] = 0xb8, [155] = 0x14, [156] = 0xde, [157] = 0x5e, [158] = 0x0b, [159] = 0xdb,
    [160] = 0xe0, [161] = 0x32, [162] = 0x3a, [163] = 0x0a, [164] = 0x49, [165] = 0x06, [166] = 0x24, [167] = 0x5c,
    [168] = 0xc2, [169] = 0xd3, [170] = 0xac, [171] = 0x62, [172] = 0x91, [173] = 0x95, [174] = 0xe4, [175] = 0x79,
    [176] = 0xe7, [177] = 0xc8, [178] = 0x37, [179] = 0x6d, [180] = 0x8d, [181] = 0xd5, [182] = 0x4e, [183] = 0xa9,
    [184] = 0x6c, [185] = 0x56, [186] = 0xf4, [187] = 0xea, [188] = 0x65, [189] = 0x7a, [190] = 0xae, [191] = 0x08,
    [192] = 0xba, [193] = 0x78, [194] = 0x25, [195] = 0x2e, [196] = 0x1c, [197] = 0xa6, [198] = 0xb4, [199] = 0xc6,
    [200] = 0xe8, [201] = 0xdd, [202] = 0x74, [203] = 0x1f, [204] = 0x4b, [205] = 0xbd, [206] = 0x8b, [207] = 0x8a,
    [208] = 0x70, [209] = 0x3e, [210] = 0xb5, [211] = 0x66, [212] = 0x48, [213] = 0x03, [214] = 0xf6, [215] = 0x0e,
    [216] = 0x61, [217] = 0x35, [218] = 0x57, [219] = 0xb9, [220] = 0x86, [221] = 0xc1, [222] = 0x1d, [223] = 0x9e,
    [224] = 0xe1, [225] = 0xf8, [226] = 0x98, [227] = 0x11, [228] = 0x69, [229] = 0xd9, [230] = 0x8e, [231] = 0x94,
    [232] = 0x9b, [233] = 0x1e, [234] = 0x87, [235] = 0xe9, [236] = 0xce, [237] = 0x55, [238] = 0x28, [239] = 0xdf,
    [240] = 0x8c, [241] = 0xa1, [242] = 0x89, [243] = 0x0d, [244] = 0xbf, [245] = 0xe6, [246] = 0x42, [247] = 0x68,
    [248] = 0x41, [249] = 0x99, [250] = 0x2d, [251] = 0x0f, [252] = 0xb0, [253] = 0x54, [254] = 0xbb, [255] = 0x16,
};

local rsbox = {
    [0] = 0x52, [1] = 0x09, [2] = 0x6a, [3] = 0xd5, [4] = 0x30, [5] = 0x36, [6] = 0xa5, [7] = 0x38,
    [8] = 0xbf, [9] = 0x40, [10] = 0xa3, [11] = 0x9e, [12] = 0x81, [13] = 0xf3, [14] = 0xd7, [15] = 0xfb,
    [16] = 0x7c, [17] = 0xe3, [18] = 0x39, [19] = 0x82, [20] = 0x9b, [21] = 0x2f, [22] = 0xff, [23] = 0x87,
    [24] = 0x34, [25] = 0x8e, [26] = 0x43, [27] = 0x44, [28] = 0xc4, [29] = 0xde, [30] = 0xe9, [31] = 0xcb,
    [32] = 0x54, [33] = 0x7b, [34] = 0x94, [35] = 0x32, [36] = 0xa6, [37] = 0xc2, [38] = 0x23, [39] = 0x3d,
    [40] = 0xee, [41] = 0x4c, [42] = 0x95, [43] = 0x0b, [44] = 0x42, [45] = 0xfa, [46] = 0xc3, [47] = 0x4e,
    [48] = 0x08, [49] = 0x2e, [50] = 0xa1, [51] = 0x66, [52] = 0x28, [53] = 0xd9, [54] = 0x24, [55] = 0xb2,
    [56] = 0x76, [57] = 0x5b, [58] = 0xa2, [59] = 0x49, [60] = 0x6d, [61] = 0x8b, [62] = 0xd1, [63] = 0x25,
    [64] = 0x72, [65] = 0xf8, [66] = 0xf6, [67] = 0x64, [68] = 0x86, [69] = 0x68, [70] = 0x98, [71] = 0x16,
    [72] = 0xd4, [73] = 0xa4, [74] = 0x5c, [75] = 0xcc, [76] = 0x5d, [77] = 0x65, [78] = 0xb6, [79] = 0x92,
    [80] = 0x6c, [81] = 0x70, [82] = 0x48, [83] = 0x50, [84] = 0xfd, [85] = 0xed, [86] = 0xb9, [87] = 0xda,
    [88] = 0x5e, [89] = 0x15, [90] = 0x46, [91] = 0x57, [92] = 0xa7, [93] = 0x8d, [94] = 0x9d, [95] = 0x84,
    [96] = 0x90, [97] = 0xd8, [98] = 0xab, [99] = 0x00, [100] = 0x8c, [101] = 0xbc, [102] = 0xd3, [103] = 0x0a,
    [104] = 0xf7, [105] = 0xe4, [106] = 0x58, [107] = 0x05, [108] = 0xb8, [109] = 0xb3, [110] = 0x45, [111] = 0x06,
    [112] = 0xd0, [113] = 0x2c, [114] = 0x1e, [115] = 0x8f, [116] = 0xca, [117] = 0x3f, [118] = 0x0f, [119] = 0x02,
    [120] = 0xc1, [121] = 0xaf, [122] = 0xbd, [123] = 0x03, [124] = 0x01, [125] = 0x13, [126] = 0x8a, [127] = 0x6b,
    [128] = 0x3a, [129] = 0x91, [130] = 0x11, [131] = 0x41, [132] = 0x4f, [133] = 0x67, [134] = 0xdc, [135] = 0xea,
    [136] = 0x97, [137] = 0xf2, [138] = 0xcf, [139] = 0xce, [140] = 0xf0, [141] = 0xb4, [142] = 0xe6, [143] = 0x73,
    [144] = 0x96, [145] = 0xac, [146] = 0x74, [147] = 0x22, [148] = 0xe7, [149] = 0xad, [150] = 0x35, [151] = 0x85,
    [152] = 0xe2, [153] = 0xf9, [154] = 0x37, [155] = 0xe8, [156] = 0x1c, [157] = 0x75, [158] = 0xdf, [159] = 0x6e,
    [160] = 0x47, [161] = 0xf1, [162] = 0x1a, [163] = 0x71, [164] = 0x1d, [165] = 0x29, [166] = 0xc5, [167] = 0x89,
    [168] = 0x6f, [169] = 0xb7, [170] = 0x62, [171] = 0x0e, [172] = 0xaa, [173] = 0x18, [174] = 0xbe, [175] = 0x1b,
    [176] = 0xfc, [177] = 0x56, [178] = 0x3e, [179] = 0x4b, [180] = 0xc6, [181] = 0xd2, [182] = 0x79, [183] = 0x20,
    [184] = 0x9a, [185] = 0xdb, [186] = 0xc0, [187] = 0xfe, [188] = 0x78, [189] = 0xcd, [190] = 0x5a, [191] = 0xf4,
    [192] = 0x1f, [193] = 0xdd, [194] = 0xa8, [195] = 0x33, [196] = 0x88, [197] = 0x07, [198] = 0xc7, [199] = 0x31,
    [200] = 0xb1, [201] = 0x12, [202] = 0x10, [203] = 0x59, [204] = 0x27, [205] = 0x80, [206] = 0xec, [207] = 0x5f,
    [208] = 0x60, [209] = 0x51, [210] = 0x7f, [211] = 0xa9, [212] = 0x19, [213] = 0xb5, [214] = 0x4a, [215] = 0x0d,
    [216] = 0x2d, [217] = 0xe5, [218] = 0x7a, [219] = 0x9f, [220] = 0x93, [221] = 0xc9, [222] = 0x9c, [223] = 0xef,
    [224] = 0xa0, [225] = 0xe0, [226] = 0x3b, [227] = 0x4d, [228] = 0xae, [229] = 0x2a, [230] = 0xf5, [231] = 0xb0,
    [232] = 0xc8, [233] = 0xeb, [234] = 0xbb, [235] = 0x3c, [236] = 0x83, [237] = 0x53, [238] = 0x99, [239] = 0x61,
    [240] = 0x17, [241] = 0x2b, [242] = 0x04, [243] = 0x7e, [244] = 0xba, [245] = 0x77, [246] = 0xd6, [247] = 0x26,
    [248] = 0xe1, [249] = 0x69, [250] = 0x14, [251] = 0x63, [252] = 0x55, [253] = 0x21, [254] = 0x0c, [255] = 0x7d,
};

local rcon = {
    [0] = 0x8d, [1] = 0x01, [2] = 0x02, [3] = 0x04, [4] = 0x08, [5] = 0x10, [6] = 0x20, [7] = 0x40,
    [8] = 0x80, [9] = 0x1b, [10] = 0x36, [11] = 0x6c, [12] = 0xd8, [13] = 0xab, [14] = 0x4d, [15] = 0x9a,
    [16] = 0x2f, [17] = 0x5e, [18] = 0xbc, [19] = 0x63, [20] = 0xc6, [21] = 0x97, [22] = 0x35, [23] = 0x6a,
    [24] = 0xd4, [25] = 0xb3, [26] = 0x7d, [27] = 0xfa, [28] = 0xef, [29] = 0xc5, [30] = 0x91, [31] = 0x39,
    [32] = 0x72, [33] = 0xe4, [34] = 0xd3, [35] = 0xbd, [36] = 0x61, [37] = 0xc2, [38] = 0x9f, [39] = 0x25,
    [40] = 0x4a, [41] = 0x94, [42] = 0x33, [43] = 0x66, [44] = 0xcc, [45] = 0x83, [46] = 0x1d, [47] = 0x3a,
    [48] = 0x74, [49] = 0xe8, [50] = 0xcb, [51] = 0x8d, [52] = 0x01, [53] = 0x02, [54] = 0x04, [55] = 0x08,
    [56] = 0x10, [57] = 0x20, [58] = 0x40, [59] = 0x80, [60] = 0x1b, [61] = 0x36, [62] = 0x6c, [63] = 0xd8,
    [64] = 0xab, [65] = 0x4d, [66] = 0x9a, [67] = 0x2f, [68] = 0x5e, [69] = 0xbc, [70] = 0x63, [71] = 0xc6,
    [72] = 0x97, [73] = 0x35, [74] = 0x6a, [75] = 0xd4, [76] = 0xb3, [77] = 0x7d, [78] = 0xfa, [79] = 0xef,
    [80] = 0xc5, [81] = 0x91, [82] = 0x39, [83] = 0x72, [84] = 0xe4, [85] = 0xd3, [86] = 0xbd, [87] = 0x61,
    [88] = 0xc2, [89] = 0x9f, [90] = 0x25, [91] = 0x4a, [92] = 0x94, [93] = 0x33, [94] = 0x66, [95] = 0xcc,
    [96] = 0x83, [97] = 0x1d, [98] = 0x3a, [99] = 0x74, [100] = 0xe8, [101] = 0xcb, [102] = 0x8d, [103] = 0x01,
    [104] = 0x02, [105] = 0x04, [106] = 0x08, [107] = 0x10, [108] = 0x20, [109] = 0x40, [110] = 0x80, [111] = 0x1b,
    [112] = 0x36, [113] = 0x6c, [114] = 0xd8, [115] = 0xab, [116] = 0x4d, [117] = 0x9a, [118] = 0x2f, [119] = 0x5e,
    [120] = 0xbc, [121] = 0x63, [122] = 0xc6, [123] = 0x97, [124] = 0x35, [125] = 0x6a, [126] = 0xd4, [127] = 0xb3,
    [128] = 0x7d, [129] = 0xfa, [130] = 0xef, [131] = 0xc5, [132] = 0x91, [133] = 0x39, [134] = 0x72, [135] = 0xe4,
    [136] = 0xd3, [137] = 0xbd, [138] = 0x61, [139] = 0xc2, [140] = 0x9f, [141] = 0x25, [142] = 0x4a, [143] = 0x94,
    [144] = 0x33, [145] = 0x66, [146] = 0xcc, [147] = 0x83, [148] = 0x1d, [149] = 0x3a, [150] = 0x74, [151] = 0xe8,
    [152] = 0xcb, [153] = 0x8d, [154] = 0x01, [155] = 0x02, [156] = 0x04, [157] = 0x08, [158] = 0x10, [159] = 0x20,
    [160] = 0x40, [161] = 0x80, [162] = 0x1b, [163] = 0x36, [164] = 0x6c, [165] = 0xd8, [166] = 0xab, [167] = 0x4d,
    [168] = 0x9a, [169] = 0x2f, [170] = 0x5e, [171] = 0xbc, [172] = 0x63, [173] = 0xc6, [174] = 0x97, [175] = 0x35,
    [176] = 0x6a, [177] = 0xd4, [178] = 0xb3, [179] = 0x7d, [180] = 0xfa, [181] = 0xef, [182] = 0xc5, [183] = 0x91,
    [184] = 0x39, [185] = 0x72, [186] = 0xe4, [187] = 0xd3, [188] = 0xbd, [189] = 0x61, [190] = 0xc2, [191] = 0x9f,
    [192] = 0x25, [193] = 0x4a, [194] = 0x94, [195] = 0x33, [196] = 0x66, [197] = 0xcc, [198] = 0x83, [199] = 0x1d,
    [200] = 0x3a, [201] = 0x74, [202] = 0xe8, [203] = 0xcb, [204] = 0x8d, [205] = 0x01, [206] = 0x02, [207] = 0x04,
    [208] = 0x08, [209] = 0x10, [210] = 0x20, [211] = 0x40, [212] = 0x80, [213] = 0x1b, [214] = 0x36, [215] = 0x6c,
    [216] = 0xd8, [217] = 0xab, [218] = 0x4d, [219] = 0x9a, [220] = 0x2f, [221] = 0x5e, [222] = 0xbc, [223] = 0x63,
    [224] = 0xc6, [225] = 0x97, [226] = 0x35, [227] = 0x6a, [228] = 0xd4, [229] = 0xb3, [230] = 0x7d, [231] = 0xfa,
    [232] = 0xef, [233] = 0xc5, [234] = 0x91, [235] = 0x39, [236] = 0x72, [237] = 0xe4, [238] = 0xd3, [239] = 0xbd,
    [240] = 0x61, [241] = 0xc2, [242] = 0x9f, [243] = 0x25, [244] = 0x4a, [245] = 0x94, [246] = 0x33, [247] = 0x66,
    [248] = 0xcc, [249] = 0x83, [250] = 0x1d, [251] = 0x3a, [252] = 0x74, [253] = 0xe8, [254] = 0xcb,
};


--------------------------------------------------------------------------------
-- This function produces 4*($nr+1) round keys.
-- The round keys are used in each round to encrypt the states.
-- Inputs: 0) key string (must be 16, 24 or 32 bytes long)
function AES.KeyExpansion(key)
    local nk = math.floor(#key / 4)     -- number of 32-bit words in the key
    nr = nk + 6                         -- number of rounds

    -- The first round key is the key itself.
    local i = 0
    while i < nk do
        for j = 0, 3 do
            RoundKey[i * 4 + j] = key:byte(i * 4 + j + 1)
        end
        i = i + 1
    end
    -- All other round keys are found from the previous round keys.
    while i < (4 * (nr + 1)) do
        local temp = {}
        for j = 0, 3 do temp[j] = RoundKey[(i - 1) * 4 + j] end

        if i % nk == 0 then
            -- rotate the 4 bytes in a word to the left once
            -- [a0,a1,a2,a3] becomes [a1,a2,a3,a0]
            temp[0], temp[1], temp[2], temp[3] = temp[1], temp[2], temp[3], temp[0]

            -- take a four-byte input word and apply the S-box
            -- to each of the four bytes to produce an output word.
            for j = 0, 3 do temp[j] = sbox[temp[j]] end

            temp[0] = temp[0] ~ rcon[i / nk]

        elseif nk > 6 and i % nk == 4 then
            for j = 0, 3 do temp[j] = sbox[temp[j]] end
        end
        RoundKey[i * 4 + 0] = RoundKey[(i - nk) * 4 + 0] ~ temp[0]
        RoundKey[i * 4 + 1] = RoundKey[(i - nk) * 4 + 1] ~ temp[1]
        RoundKey[i * 4 + 2] = RoundKey[(i - nk) * 4 + 2] ~ temp[2]
        RoundKey[i * 4 + 3] = RoundKey[(i - nk) * 4 + 3] ~ temp[3]
        i = i + 1
    end
end

--------------------------------------------------------------------------------
-- This function adds the round key to state.
-- The round key is added to the state by an XOR function.
local function AddRoundKey(round)
    for i = 0, 3 do
        local k = round * 16 + i * 4
        for j = 0, 3 do
            state[j][i] = state[j][i] ~ RoundKey[k + j]
        end
    end
end

--------------------------------------------------------------------------------
-- Substitute the values in the state matrix with values in an S-box
local function SubBytes()
    for i = 0, 3 do
        for j = 0, 3 do
            state[i][j] = sbox[state[i][j]]
        end
    end
end

local function InvSubBytes()
    for i = 0, 3 do
        for j = 0, 3 do
            state[i][j] = rsbox[state[i][j]]
        end
    end
end

--------------------------------------------------------------------------------
-- Shift the rows in the state to the left.
-- Each row is shifted with different offset.
-- Offset = Row number. So the first row is not shifted.
local function ShiftRows()
    -- rotate first row 1 columns to left
    state[1][0], state[1][1], state[1][2], state[1][3] =
        state[1][1], state[1][2], state[1][3], state[1][0]

    -- rotate second row 2 columns to left
    state[2][0], state[2][1], state[2][2], state[2][3] =
        state[2][2], state[2][3], state[2][0], state[2][1]

    -- rotate third row 3 columns to left
    state[3][0], state[3][1], state[3][2], state[3][3] =
        state[3][3], state[3][0], state[3][1], state[3][2]
end

local function InvShiftRows()
    -- rotate first row 1 columns to right
    state[1][0], state[1][1], state[1][2], state[1][3] =
        state[1][3], state[1][0], state[1][1], state[1][2]

    -- rotate second row 2 columns to right
    state[2][0], state[2][1], state[2][2], state[2][3] =
        state[2][2], state[2][3], state[2][0], state[2][1]

    -- rotate third row 3 columns to right
    state[3][0], state[3][1], state[3][2], state[3][3] =
        state[3][1], state[3][2], state[3][3], state[3][0]
end

--------------------------------------------------------------------------------
-- Find the product of {02} and the argument to xtime modulo 0x1b
-- Note: returns an integer which may need to be trimmed to 8 bits
local function xtime(x)
    return (x << 1) ~ ((x >> 7 & 1) * 0x1b)
end

--------------------------------------------------------------------------------
-- Multiply numbers in the field GF(2^8)
local function Mult(x, y)
    return ((y & 1) * x) ~
           ((y >> 1 & 1) * xtime(x)) ~
           ((y >> 2 & 1) * xtime(xtime(x))) ~
           ((y >> 3 & 1) * xtime(xtime(xtime(x)))) ~
           ((y >> 4 & 1) * xtime(xtime(xtime(xtime(x)))))
end

--------------------------------------------------------------------------------
-- Mix the columns of the state matrix
local function MixColumns()
    for i = 0, 3 do
        local t0 = state[0][i]
        local t2 = state[0][i] ~ state[1][i] ~ state[2][i] ~ state[3][i]
        local t1 = state[0][i] ~ state[1][i]; t1 = xtime(t1) & 0xff; state[0][i] = state[0][i] ~ t1 ~ t2
        t1 = state[1][i] ~ state[2][i];       t1 = xtime(t1) & 0xff; state[1][i] = state[1][i] ~ t1 ~ t2
        t1 = state[2][i] ~ state[3][i];       t1 = xtime(t1) & 0xff; state[2][i] = state[2][i] ~ t1 ~ t2
        t1 = state[3][i] ~ t0;                t1 = xtime(t1) & 0xff; state[3][i] = state[3][i] ~ t1 ~ t2
    end
end

local function InvMixColumns()
    for i = 0, 3 do
        local a = state[0][i]
        local b = state[1][i]
        local c = state[2][i]
        local d = state[3][i]
        state[0][i] = (Mult(a, 0x0e) ~ Mult(b, 0x0b) ~ Mult(c, 0x0d) ~ Mult(d, 0x09)) & 0xff
        state[1][i] = (Mult(a, 0x09) ~ Mult(b, 0x0e) ~ Mult(c, 0x0b) ~ Mult(d, 0x0d)) & 0xff
        state[2][i] = (Mult(a, 0x0d) ~ Mult(b, 0x09) ~ Mult(c, 0x0e) ~ Mult(d, 0x0b)) & 0xff
        state[3][i] = (Mult(a, 0x0b) ~ Mult(b, 0x0d) ~ Mult(c, 0x09) ~ Mult(d, 0x0e)) & 0xff
    end
end

--------------------------------------------------------------------------------
-- Encrypt (Cipher) or decrypt (InvCipher) a block of data with CBC
-- Inputs: 0) string to cipher (must be 16 bytes long)
-- Returns: cipher'd string
function AES.Cipher(input)
    -- copy the input PlainText to state array and apply the CBC
    for i = 0, 3 do
        for j = 0, 3 do
            local k = i * 4 + j
            state[j][i] = input:byte(k + 1) ~ cbc[k]
        end
    end

    -- add the First round key to the state before starting the rounds
    AddRoundKey(0)

    -- there will be $nr rounds; the first $nr-1 rounds are identical
    local round = 1
    while true do
        SubBytes()
        ShiftRows()
        if round < nr then
            MixColumns()
            AddRoundKey(round)
        else
            -- MixColumns() is not used in the last round
            AddRoundKey(nr)
            break
        end
        round = round + 1
    end

    -- the encryption process is over
    -- copy the state array to output array (and save for CBC)
    local out = {}
    for i = 0, 3 do
        for j = 0, 3 do
            cbc[i * 4 + j] = state[j][i]
            out[i * 4 + j + 1] = cbc[i * 4 + j]
        end
    end
    return string.char(table.unpack(out)) -- return packed ciphertext
end

function AES.InvCipher(input)
    -- copy the input CipherText to state array
    for i = 0, 3 do
        for j = 0, 3 do
            state[j][i] = input:byte(i * 4 + j + 1)
        end
    end

    -- add the First round key to the state before starting the rounds
    AddRoundKey(nr)

    -- there will be $nr rounds; the first $nr-1 rounds are identical
    local round = nr - 1
    while true do
        InvShiftRows()
        InvSubBytes()
        AddRoundKey(round)
        -- InvMixColumns() is not used in the last round
        if round <= 0 then break end
        InvMixColumns()
        round = round - 1
    end

    -- copy the state array to output array and reverse the CBC
    local out = {}
    for i = 0, 3 do
        for j = 0, 3 do
            local k = i * 4 + j
            out[k + 1] = state[j][i] ~ cbc[k]
        end
    end
    for i = 0, 15 do
        cbc[i] = input:byte(i + 1) -- update CBC for next block
    end
    return string.char(table.unpack(out)) -- return packed plaintext
end

--------------------------------------------------------------------------------
-- Encrypt/Decrypt using AES-CBC algorithm (with fixed 16-byte blocks)
-- Inputs: 0) data string (with leading 16-byte initialization vector when
--            decrypting)
--         1) encryption key (16, 24 or 32 bytes for AES-128, AES-192 or
--            AES-256)
--         2) encrypt flag (false for decryption, true with length 16 bytes
--            to encrypt using this as the CBC IV, or true with other length
--            to encrypt with a randomly-generated IV)
--         3) flag to disable padding
-- Returns: data string, then error string on failure (nil error on success).
-- Notes: upstream encrypts/decrypts data in place through a scalar
-- reference; Lua strings are immutable, so the updated data string is
-- returned instead. Encrypted data comes back with the leading IV.
function AES.Crypt(data, key, encrypt, noPad)

    -- validate key length
    local keyLen = #key
    if keyLen ~= 16 and keyLen ~= 24 and keyLen ~= 32 then
        return nil, 'Invalid AES key length (' .. keyLen .. ')'
    end
    local partLen = #data % 16
    local pos
    if truthy(encrypt) then
        if length(encrypt) == 16 then
            for i = 0, 15 do cbc[i] = encrypt:byte(i + 1) end
        else
            -- generate a random 16-byte CBC initialization vector
            -- (upstream seeds Perl's srand with time() and the process id;
            -- Lua has no process id, so seed from the current time alone)
            if not seeded then
                math.randomseed(os.time())
                seeded = true
            end
            local iv = {}
            for i = 0, 15 do
                cbc[i] = math.random(0, 255)
                iv[i + 1] = cbc[i]
            end
            encrypt = string.char(table.unpack(iv))
        end
        data = encrypt .. data -- add IV to the start of the data
        -- add required padding so we can recover the
        -- original string length after decryption
        -- (padding bytes have value set to padding length)
        local padLen = 16 - partLen
        if not (padLen == 16 and truthy(noPad)) then
            data = data .. string.char(padLen):rep(padLen)
        end
        pos = 16      -- start encrypting at byte 16 (after the IV)
    elseif partLen ~= 0 then
        return nil, 'Invalid AES ciphertext length'
    elseif #data >= 32 then
        -- take the CBC initialization vector from the start of the data
        for i = 0, 15 do cbc[i] = data:byte(i + 1) end
        data = substr(data, 16)
        pos = 0       -- start decrypting from byte 0 (now that IV is removed)
    else
        return ''     -- empty text
    end
    -- the KeyExpansion routine must be called before encryption
    AES.KeyExpansion(key)

    -- loop through the data and convert in blocks
    local dataLen = #data
    local last = dataLen - 16
    local func = truthy(encrypt) and AES.Cipher or AES.InvCipher
    local blocks = {}
    while pos <= last do
        -- cipher this block
        blocks[#blocks + 1] = func(substr(data, pos, 16))
        pos = pos + 16
    end
    data = table.concat(blocks)
    if truthy(encrypt) then
        -- upstream encrypts in place through the scalar reference, so the
        -- IV prepended above stays put at the start of the returned data;
        -- rebuild that layout here (encrypted data comes back with the IV)
        data = encrypt .. data
    end
    if not truthy(encrypt) and not truthy(noPad) then
        -- remove padding if necessary (padding byte value gives length of padding)
        local padLen = data:byte(-1)
        if padLen > 16 then return nil, 'AES decryption error (invalid pad byte)' end
        data = substr(data, 0, dataLen - padLen)
    end
    return data
end

return AES
